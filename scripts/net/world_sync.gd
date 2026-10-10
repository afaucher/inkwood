extends Node

# WorldSync -- the networked co-op turn (Track N, "the first fight").
#
# One node per machine, at the SAME path on every machine, holding that
# machine's World. It carries the co-op rules Alex decided (2026-10-09) over any
# MultiplayerAPI -- the node's own `multiplayer`, so the same code runs over
# Steam (what ships), ENet (two windows on one machine) and the test gate's
# several peers in one process:
#
#   - Every machine runs the same scenario World (same data, same unit ids).
#     Only the HOST's World resolves; it sends every player the whole of
#     World.resolve()'s result and each client calls World.apply_resolution().
#   - No unit belongs to a player. Each player is a World player named after the
#     peer ("peer_<id>"); all of them ready up; drop-in, drop-out.
#   - A plan edit is the unit's WHOLE plan, sent to the host, applied there in
#     ARRIVAL ORDER (so the last edit wins) and sent on to everyone. Everybody
#     sees every plan live. AI-controlled units' plans are never sent: a client's
#     AI unit has an empty plan, always.
#   - An edit after Ready takes that player's Ready back (the host agrees, not
#     only the editor's UI). The last Ready resolves. No orders = fly on.
#
# USAGE (what scripts/app/sandbox_session.gd and the tests do):
#
#   var sync := WorldSync.new(); sync.name = "WorldSync"
#   parent.add_child(sync)                       # same path on every machine
#   sync.setup(world, "sandbox", "local")        # swaps the scenario's "local" player for ours
#   ui.setup(world, mapping, sync.local_player(), ...)
#   ui.auto_resolve = false                      # the HOST resolves, through this node
#   sync.start()                                 # a client says hello; the host starts serving
#
# THE MESSAGES (all reliable, one channel, so the order of sending is the order
# of arrival; every payload is plain Variants -- floats keep their bits):
#
#   client -> host (any_peer)
#     rpc_hello(proto, scenario, unit_ids, display)    "I am here, with this scenario"
#     rpc_req_plan(turn, unit, plan, seq)              the unit's whole plan, from the sender
#     rpc_req_ready(turn, is_ready, seq)               the sender's own Ready, set or taken back
#     rpc_req_snapshot()                               "send me everything again" (after a desync)
#   host -> clients (authority)
#     rpc_welcome(snapshot)                            the answer to hello: the state of the game
#     rpc_refuse(reason)                               the answer to a hello that cannot join
#     rpc_plan_set(turn, unit, plan, from, seq)        the host's plan for a unit; `from` is the
#                                                      peer whose edit it is, `seq` that peer's
#                                                      request number: the echo that acknowledges it
#     rpc_ready_set(turn, player, is_ready, from, seq) one player's Ready flag (the AI's too)
#     rpc_turn_result(result)                          World.resolve()'s whole result
#     rpc_player_joined(player, display) / rpc_player_left(player)
#
# EVERY message that changes the game carries a `turn`. A machine applies it only
# when its World is planning that same turn; one from the NEXT turn is HELD (the
# sender's playback finished first) and applied when this World begins that turn;
# one from an earlier turn is dropped (its sender's plan was cleared by the
# resolve anyway). Held messages keep their order (one inbox, first in first out).
#
# CONVERGENCE UNDER SIMULTANEOUS EDITS. The host applies requests in arrival
# order and sends every plan on to everyone, the sender included (an echo). A
# client does not apply a plan for a unit it has an edit in flight for (sent, not
# yet echoed): the host will apply that edit after, so the host's last edit is
# every machine's final state, and a dragged step never flickers back to an
# older plan. The same goes for the player's own Ready flag.
#
# Everything here that is not a rule of the game is a knob or a constant:
# PROTOCOL is the message set's version; the player naming is a constant.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")

# The game's players are known to the World by these names. (The AI keeps
# World.AI_PLAYER.)
const PLAYER_PREFIX := "peer_"
const PROTOCOL := 1
const HOST_ID := 1
const TRACE_MAX := 600

# Client: the host's snapshot has been applied -- this World is the host's game.
signal joined()
# Client: the host would not have us (a different scenario or message version).
signal refused(reason: String)
# Either side: a player came or went (or the whole player list was replaced).
signal players_changed()
# Host: a turn was resolved and its result sent to every member.
signal turn_sent(turn: int)
# Client: the host's state could not be applied; a new snapshot was asked for.
signal desynced(reason: String)
# Client: the host went away.
signal host_lost()

var world: World = null
var scenario_id := ""
# What the other players see for this player (the Steam name, when there is one).
var display_name := ""
# player -> display name, for every player in the game.
var names: Dictionary = {}
# Counters by what happened ("sent_plan_set", "dropped_stale", ...): the tests'
# window on the wire, and the HUD's.
var stats: Dictionary = {}
# When on, every message this node sends is appended to `trace` as a Dictionary
# {kind, to, unit?, ...}: the proof that some things never cross the wire.
var trace_enabled := false
var trace: Array = []

var _started := false
var _joined := false                       # host: always true after setup; client: after welcome
var _members: Array[int] = []              # host: the peers in the game (1 first)
var _hellos: Array = []                    # host: [{from, display}] waiting for the planning phase
var _applying := 0                         # > 0 while this node is changing the World itself
var _outbox: Array[String] = []            # units whose plan changed locally and is not sent yet, in order
var _inbox: Array = []                     # messages that cannot be applied yet, first in first out
var _draining := false
var _plan_sent: Dictionary = {}            # unit -> requests sent (client)
var _plan_acked: Dictionary = {}           # unit -> the highest of them the host has echoed
var _ready_sent := 0
var _ready_acked := 0
var _connect_hooked := false

# --- Names -------------------------------------------------------------------------------------

static func player_for(peer_id: int) -> String:
	return "%s%d" % [PLAYER_PREFIX, peer_id]

# The peer id behind a player name, or 0 for the AI or anything else.
static func peer_of(player: String) -> int:
	if not player.begins_with(PLAYER_PREFIX):
		return 0
	var tail := player.substr(PLAYER_PREFIX.length())
	return tail.to_int() if tail.is_valid_int() else 0

func local_player() -> String:
	return player_for(multiplayer.get_unique_id())

func is_host() -> bool:
	return multiplayer.is_server()

func is_joined() -> bool:
	return _joined

# What a player is called on screen: their display name, else the World's name.
func name_of(player: String) -> String:
	var n := str(names.get(player, ""))
	return n if n != "" else player

# The peers in the game other than the host (host only; empty on a client).
func remote_members() -> Array[int]:
	var out: Array[int] = []
	var live := multiplayer.get_peers()
	for m: int in _members:
		if m != HOST_ID and live.has(m):
			out.append(m)
	return out

# Messages held for a turn this World has not begun (or for the planning phase).
func pending_count() -> int:
	return _inbox.size()

# Host: hellos waiting for the planning phase.
func pending_hellos() -> int:
	return _hellos.size()

# One line for a HUD or a log.
func status_text() -> String:
	if world == null:
		return "no world"
	var n := world.players.size()
	var who := "host" if is_host() else ("client" if _joined else "joining")
	return "%s %s, turn %d, %d player%s" % [who, local_player(), world.turn, n, "" if n == 1 else "s"]

# --- Setup -----------------------------------------------------------------------------------------

# Hand this node the World. Call after add_child (the node needs its
# multiplayer). `scenario_local_player` is the player name the scenario put in
# the World ("local"): it is swapped for this peer's own.
func setup(w: World, scenario: String, scenario_local_player: String = "") -> void:
	world = w
	scenario_id = scenario
	if scenario_local_player != "":
		world.remove_player(scenario_local_player)
	world.add_player(local_player())
	names[local_player()] = display_name
	if is_host():
		_members = [HOST_ID]
		_joined = true
	world.plan_changed.connect(_on_plan_changed)
	world.ready_changed.connect(_on_ready_changed)
	world.phase_changed.connect(_on_phase_changed)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# A client says hello to the host (and gets the game in answer); the host starts
# letting players in. Call it when this machine can play: the host's turn waits for
# every player it has let in.
func start() -> void:
	if _started or world == null:
		return
	_started = true
	names[local_player()] = display_name
	if is_host():
		_serve_hellos()
		return
	if multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		if not _connect_hooked:
			_connect_hooked = true
			multiplayer.connected_to_server.connect(_send_hello, CONNECT_ONE_SHOT)
		return
	_send_hello()

func _send_hello() -> void:
	var ids: Array = world.units.keys()
	_note("hello", HOST_ID)
	rpc_hello.rpc_id(HOST_ID, PROTOCOL, scenario_id, ids, display_name)

# --- Frame: the local edits go out ------------------------------------------------------------

func _process(_delta: float) -> void:
	flush()

# Send what the local player did since the last flush, in the order it happened.
# Plans are read NOW (a drag that changed a unit's plan ten times is one message).
func flush() -> void:
	if _outbox.is_empty():
		return
	var units: Array[String] = _outbox
	_outbox = []
	for unit_id: String in units:
		_send_local_plan(unit_id)

func _send_local_plan(unit_id: String) -> void:
	if world == null or not world.units.has(unit_id) or world.phase != World.PHASE_PLANNING:
		return
	if is_host():
		# The host's own edit: it takes the host player's Ready back, and goes to everyone.
		_unready(local_player())
		_broadcast_plan(unit_id, HOST_ID, 0)
		return
	var seq: int = int(_plan_sent.get(unit_id, 0)) + 1
	_plan_sent[unit_id] = seq
	var plan: Array = (world.units[unit_id].plan as Array).duplicate(true)
	_note("req_plan", HOST_ID, unit_id)
	rpc_req_plan.rpc_id(HOST_ID, world.turn, unit_id, plan, seq)

# --- World -> wire: what the local player does -------------------------------------------------

func _live() -> bool:
	return world != null and _applying == 0 and _joined and _started

func _on_plan_changed(unit_id: String) -> void:
	if not _live() or world.phase != World.PHASE_PLANNING:
		return
	var u: Variant = world.units.get(unit_id)
	# The AI's plans are the enemy's plans: they never leave the host.
	if u == null or (u as Unit).controller != World.CONTROLLER_PLAYER:
		return
	# One pending send per unit: it reads the plan as it is when it goes out.
	if not _outbox.has(unit_id):
		_outbox.append(unit_id)

func _on_ready_changed(player: String, is_ready: bool) -> void:
	# A reset at begin_turn comes in the resolved phase; remote changes are applied
	# under _applying and announced by the code that applied them.
	if not _live() or world.phase != World.PHASE_PLANNING:
		return
	# An edit made before this Ready reaches the host (and so everyone) before it.
	flush()
	if is_host():
		_broadcast_ready(world.turn, player, is_ready, HOST_ID, 0)
		_maybe_resolve.call_deferred()
	elif player == local_player():
		_ready_sent += 1
		_note("req_ready", HOST_ID, "", {"ready": is_ready})
		rpc_req_ready.rpc_id(HOST_ID, world.turn, is_ready, _ready_sent)

func _on_phase_changed(phase: String) -> void:
	if phase != World.PHASE_PLANNING or world == null:
		return
	_drain()
	if is_host():
		_serve_hellos()
		_maybe_resolve.call_deferred()

# --- The inbox: messages wait for the turn they are for -----------------------------------------

func _enqueue(msg: Dictionary) -> void:
	# (A client that has not been welcomed has no game for a message to be about.)
	if world == null or not _joined:
		return
	_inbox.append(msg)
	_drain()

func _drain() -> void:
	if _draining:
		return
	_draining = true
	while not _inbox.is_empty():
		var m: Dictionary = _inbox[0]
		var turn: int = int(m["turn"])
		if turn < world.turn:
			_inbox.pop_front()
			_count("dropped_stale")
			continue
		if turn > world.turn or world.phase != World.PHASE_PLANNING:
			_count("held")
			break
		_inbox.pop_front()
		_handle(m)
	_draining = false

func _handle(m: Dictionary) -> void:
	match str(m["kind"]):
		"req_plan":
			_host_apply_plan_request(m)
		"req_ready":
			_host_apply_ready_request(m)
		"plan_set":
			_client_apply_plan_set(m)
		"ready_set":
			_client_apply_ready_set(m)
		"result":
			_client_apply_result(m)

# --- Host: requests from players ---------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func rpc_req_plan(turn: int, unit_id: String, plan: Array, seq: int) -> void:
	var from := multiplayer.get_remote_sender_id()
	if not is_host() or not _members.has(from):
		return
	_enqueue({"kind": "req_plan", "turn": turn, "from": from, "unit": unit_id, "plan": plan, "seq": seq})

@rpc("any_peer", "call_remote", "reliable")
func rpc_req_ready(turn: int, is_ready: bool, seq: int) -> void:
	var from := multiplayer.get_remote_sender_id()
	if not is_host() or not _members.has(from):
		return
	_enqueue({"kind": "req_ready", "turn": turn, "from": from, "ready": is_ready, "seq": seq})

func _host_apply_plan_request(m: Dictionary) -> void:
	var from: int = int(m["from"])
	var unit_id: String = str(m["unit"])
	var plan: Array = m["plan"]
	if not _members.has(from) or not world.units.has(unit_id):
		return
	var problem := _plan_problem(unit_id, plan)
	if problem != "":
		# Refused: the sender is told what the host really has, so its screen agrees.
		push_warning("WorldSync: peer %d's plan for %s refused: %s" % [from, unit_id, problem])
		_count("refused_plan")
		# (Never for an AI unit: the host's plan for it is the enemy's, and stays here.)
		if (world.units[unit_id] as Unit).controller == World.CONTROLLER_PLAYER:
			_send_plan_to(from, unit_id, from, int(m["seq"]))
		return
	_set_plan(unit_id, plan)
	_unready(player_for(from))    # the edit takes the editor's Ready back, here too
	_broadcast_plan(unit_id, from, int(m["seq"]))

func _host_apply_ready_request(m: Dictionary) -> void:
	var from: int = int(m["from"])
	var player := player_for(from)
	if not _members.has(from):
		return
	_applying += 1
	if world.participants().has(player):
		if bool(m["ready"]):
			world.commit(player)
		else:
			world.withdraw(player)
	_applying -= 1
	_broadcast_ready(world.turn, player, world.is_ready(player), from, int(m["seq"]))
	_maybe_resolve.call_deferred()

# "" if the host can apply this plan for this unit, else why not.
func _plan_problem(unit_id: String, plan: Array) -> String:
	var u: Unit = world.units[unit_id]
	if u.controller != World.CONTROLLER_PLAYER:
		return "not a player unit"
	if u.down:
		return "the unit is down"
	if plan.size() > u.def.actions_per_turn:
		return "%d steps, a %s has %d" % [plan.size(), u.type, u.def.actions_per_turn]
	for r: Variant in plan:
		if not (r is Dictionary):
			return "a step is not a Dictionary"
		var e := Envelope.request_error(r)
		if e != "":
			return e
	return ""

# --- Host: sending ----------------------------------------------------------------------------------

func _broadcast_plan(unit_id: String, from: int, seq: int) -> void:
	for peer: int in remote_members():
		_send_plan_to(peer, unit_id, from, seq)

func _send_plan_to(peer: int, unit_id: String, from: int, seq: int) -> void:
	var plan: Array = (world.units[unit_id].plan as Array).duplicate(true)
	_note("plan_set", peer, unit_id)
	rpc_plan_set.rpc_id(peer, world.turn, unit_id, plan, from, seq)

func _broadcast_ready(turn: int, player: String, is_ready: bool, from: int, seq: int) -> void:
	for peer: int in remote_members():
		_note("ready_set", peer, "", {"player": player, "ready": is_ready})
		rpc_ready_set.rpc_id(peer, turn, player, is_ready, from, seq)

# The edit-after-Ready rule, on the host: a readied player who edits is not ready.
func _unready(player: String) -> void:
	if world.phase == World.PHASE_PLANNING and world.is_ready(player):
		world.withdraw(player)    # (announced to everyone by _on_ready_changed)

# Resolve once everyone is ready: the host's World, the host's call, the host's
# result -- sent whole to every member. (UnitUI's own auto_resolve is off.)
func _maybe_resolve() -> void:
	if not is_host() or world == null or not _joined or world.phase != World.PHASE_PLANNING:
		return
	if world.players.is_empty() or not world.all_ready():
		return
	flush()
	var result := world.resolve()
	if result.is_empty():
		return
	_outbox.clear()
	_count("resolved")
	for peer: int in remote_members():
		_note("turn_result", peer)
		rpc_turn_result.rpc_id(peer, result)
	turn_sent.emit(int(result["turn"]))

# --- Host: players coming and going ------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func rpc_hello(proto: int, scenario: String, unit_ids: Array, display: String) -> void:
	if not is_host() or world == null:
		return
	var from := multiplayer.get_remote_sender_id()
	if proto != PROTOCOL:
		_refuse(from, "this host speaks message version %d, not %d" % [PROTOCOL, proto])
		return
	if scenario != scenario_id:
		_refuse(from, "this host plays scenario '%s', not '%s'" % [scenario_id, scenario])
		return
	if not _same_ids(world.units.keys(), unit_ids):
		_refuse(from, "this host's units are not yours: %s against %s" % [str(world.units.keys()), str(unit_ids)])
		return
	_hellos = _hellos.filter(func(h: Dictionary) -> bool: return int(h["from"]) != from)
	_hellos.append({"from": from, "display": display})
	_serve_hellos()

@rpc("any_peer", "call_remote", "reliable")
func rpc_req_snapshot() -> void:
	var from := multiplayer.get_remote_sender_id()
	if is_host() and _members.has(from):
		_hellos.append({"from": from, "display": str(names.get(player_for(from), ""))})
		_serve_hellos()

func _refuse(peer: int, reason: String) -> void:
	_note("refuse", peer)
	rpc_refuse.rpc_id(peer, reason)

# Let waiting players in -- only between turns' resolutions, in the planning phase,
# so the snapshot is a whole game state.
func _serve_hellos() -> void:
	if not is_host() or world == null or world.phase != World.PHASE_PLANNING or _hellos.is_empty():
		return
	var waiting: Array = _hellos
	_hellos = []
	for h: Dictionary in waiting:
		var peer: int = int(h["from"])
		if not multiplayer.get_peers().has(peer):
			continue
		var player := player_for(peer)
		if not _members.has(peer):
			_members.append(peer)
			_applying += 1
			world.add_player(player)
			_applying -= 1
			names[player] = str(h["display"])
			for other: int in remote_members():
				if other != peer:
					_note("player_joined", other, "", {"player": player})
					rpc_player_joined.rpc_id(other, player, str(h["display"]))
			players_changed.emit()
		_note("welcome", peer)
		rpc_welcome.rpc_id(peer, snapshot())

func _on_peer_disconnected(id: int) -> void:
	if not is_host() or world == null:
		return
	_hellos = _hellos.filter(func(h: Dictionary) -> bool: return int(h["from"]) != id)
	if not _members.has(id):
		return
	_members.erase(id)
	var player := player_for(id)
	_remove_player(player)
	for other: int in remote_members():
		_note("player_left", other, "", {"player": player})
		rpc_player_left.rpc_id(other, player)
	# The one who left no longer holds the turn up.
	_maybe_resolve.call_deferred()

func _remove_player(player: String) -> void:
	_applying += 1
	world.remove_player(player)
	names.erase(player)
	# remove_player() emits nothing, and the ready marks on the orders card redraw on
	# ready_changed: say so for the one who is gone, so every listener redraws.
	world.ready_changed.emit(player, false)
	_applying -= 1
	players_changed.emit()

func _on_server_disconnected() -> void:
	host_lost.emit()

# The whole game as a joining peer needs it (host, planning phase). AI-controlled
# units carry NO plan: the enemy's plans do not leave the host.
func snapshot() -> Dictionary:
	var units := {}
	for id: String in world.units:
		var u: Unit = world.units[id]
		units[id] = {
			"net": u.net_state(),
			"history": u.history.duplicate(true),
			"plan": u.plan.duplicate(true) if u.controller == World.CONTROLLER_PLAYER else [],
		}
	return {
		"proto": PROTOCOL, "scenario": scenario_id, "turn": world.turn, "seed": world.rng_seed,
		"players": world.players.duplicate(), "names": names.duplicate(),
		"ready": world.ready.duplicate(), "units": units,
	}

# --- Client: messages from the host ----------------------------------------------------------------

@rpc("authority", "call_remote", "reliable")
func rpc_welcome(snap: Dictionary) -> void:
	if is_host() or multiplayer.get_remote_sender_id() != HOST_ID or world == null:
		return
	apply_snapshot(snap)

@rpc("authority", "call_remote", "reliable")
func rpc_refuse(reason: String) -> void:
	if is_host() or multiplayer.get_remote_sender_id() != HOST_ID:
		return
	push_warning("WorldSync: the host refused us: " + reason)
	refused.emit(reason)

@rpc("authority", "call_remote", "reliable")
func rpc_plan_set(turn: int, unit_id: String, plan: Array, from: int, seq: int) -> void:
	if is_host() or multiplayer.get_remote_sender_id() != HOST_ID or world == null:
		return
	_enqueue({"kind": "plan_set", "turn": turn, "unit": unit_id, "plan": plan, "from": from, "seq": seq})

@rpc("authority", "call_remote", "reliable")
func rpc_ready_set(turn: int, player: String, is_ready: bool, from: int, seq: int) -> void:
	if is_host() or multiplayer.get_remote_sender_id() != HOST_ID or world == null:
		return
	_enqueue({"kind": "ready_set", "turn": turn, "player": player, "ready": is_ready, "from": from, "seq": seq})

@rpc("authority", "call_remote", "reliable")
func rpc_turn_result(result: Dictionary) -> void:
	if is_host() or multiplayer.get_remote_sender_id() != HOST_ID or world == null:
		return
	_enqueue({"kind": "result", "turn": int(result.get("turn", -1)), "result": result})

@rpc("authority", "call_remote", "reliable")
func rpc_player_joined(player: String, display: String) -> void:
	if is_host() or multiplayer.get_remote_sender_id() != HOST_ID or world == null:
		return
	# Not turn-bound: a player can come at any time, and a Ready that follows is held
	# for its turn like any other message.
	_applying += 1
	world.add_player(player)
	_applying -= 1
	names[player] = display
	players_changed.emit()

@rpc("authority", "call_remote", "reliable")
func rpc_player_left(player: String) -> void:
	if is_host() or multiplayer.get_remote_sender_id() != HOST_ID or world == null:
		return
	_remove_player(player)

func _client_apply_plan_set(m: Dictionary) -> void:
	var unit_id: String = str(m["unit"])
	if not world.units.has(unit_id) or (world.units[unit_id] as Unit).controller != World.CONTROLLER_PLAYER:
		return   # (the AI's plans are never on the wire; a stray one is ignored)
	var mine := int(m["from"]) == multiplayer.get_unique_id()
	if mine:
		_plan_acked[unit_id] = maxi(int(_plan_acked.get(unit_id, 0)), int(m["seq"]))
	if _plan_in_flight(unit_id):
		return   # my newer edit will reach the host after this one: its result is the final one
	var plan: Array = m["plan"]
	if not same((world.units[unit_id].plan as Array), plan):
		_count("applied_plan")
		_set_plan(unit_id, plan)

func _plan_in_flight(unit_id: String) -> bool:
	return int(_plan_sent.get(unit_id, 0)) > int(_plan_acked.get(unit_id, 0)) or _outbox.has(unit_id)

func _client_apply_ready_set(m: Dictionary) -> void:
	var player: String = str(m["player"])
	var me := local_player()
	if int(m["from"]) == multiplayer.get_unique_id():
		_ready_acked = maxi(_ready_acked, int(m["seq"]))
	if player == me and _ready_sent > _ready_acked:
		return   # my own newer Ready/withdraw is on its way
	_apply_ready(player, bool(m["ready"]))

func _apply_ready(player: String, value: bool) -> void:
	_applying += 1
	if value:
		if world.participants().has(player) and not world.is_ready(player):
			world.commit(player)
	else:
		world.withdraw(player)
	_applying -= 1

func _client_apply_result(m: Dictionary) -> void:
	var result: Dictionary = m["result"]
	_applying += 1
	var ok := world.apply_resolution(result)
	_applying -= 1
	if not ok:
		_desync("the turn %d result did not apply: %s" % [int(result.get("turn", -1)), world.last_error])
		return
	# Whatever this player had in flight was for the turn that just ended.
	_outbox.clear()
	_forget_flight()

func _forget_flight() -> void:
	for unit_id: Variant in _plan_sent:
		_plan_acked[unit_id] = _plan_sent[unit_id]
	_ready_acked = _ready_sent

func _desync(reason: String) -> void:
	push_warning("WorldSync: out of step with the host: " + reason)
	_count("desync")
	desynced.emit(reason)
	_note("req_snapshot", HOST_ID)
	rpc_req_snapshot.rpc_id(HOST_ID)

# Everything the host knows, made this World's (a client, once, when welcomed; again after a desync).
func apply_snapshot(s: Dictionary) -> void:
	var states: Dictionary = s["units"]
	var problem := ""
	if int(s.get("proto", -1)) != PROTOCOL:
		problem = "message version %s, not %d" % [str(s.get("proto")), PROTOCOL]
	elif not _same_ids(world.units.keys(), states.keys()):
		problem = "its units %s are not this World's %s" % [str(states.keys()), str(world.units.keys())]
	if problem != "":
		refused.emit(problem)
		return
	_applying += 1
	world.rng_seed = int(s["seed"])
	world.turn = int(s["turn"])
	world.phase = World.PHASE_PLANNING
	for p: String in world.players.duplicate():
		world.remove_player(p)
	for p: Variant in (s["players"] as Array):
		world.add_player(str(p))
	names = (s["names"] as Dictionary).duplicate()
	for id: String in world.units:
		var u: Unit = world.units[id]
		var us: Dictionary = states[id]
		u.apply_net_state(us["net"])
		u.history = (us["history"] as Array).duplicate(true)
		u.plan.clear()
		if u.controller == World.CONTROLLER_PLAYER:
			_set_plan(id, us["plan"])
	var flags: Dictionary = s["ready"]
	for p: Variant in flags:
		_apply_ready(str(p), bool(flags[p]))
	_applying -= 1
	_inbox.clear()
	_outbox.clear()
	_forget_flight()
	_joined = true
	# The listeners that draw from the World (the planner, the roster, the orders
	# card) refresh on a phase change; nothing else tells them a whole game arrived.
	world.phase_changed.emit(world.phase)
	players_changed.emit()
	joined.emit()

# --- Applying plans -----------------------------------------------------------------------------------

# Make a unit's plan exactly `plan` (its requests, one per step, gaps as {}).
func _set_plan(unit_id: String, plan: Array) -> void:
	_applying += 1
	world.clear_plan(unit_id)
	for i in plan.size():
		world.plan_step(unit_id, i, plan[i])
	_applying -= 1

# --- Helpers ---------------------------------------------------------------------------------------------

static func _same_ids(a: Array, b: Array) -> bool:
	var x: Array = a.map(func(v: Variant) -> String: return str(v))
	var y: Array = b.map(func(v: Variant) -> String: return str(v))
	x.sort()
	y.sort()
	return x == y

# Deep equality for wire data: same types (an int is not a float), arrays and
# dictionaries by content, and NaN equal to NaN (a unit's down_at is NaN until it goes down).
static func same(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	match typeof(a):
		TYPE_FLOAT:
			var fa: float = a
			var fb: float = b
			return fa == fb or (is_nan(fa) and is_nan(fb))
		TYPE_ARRAY:
			var xa: Array = a
			var xb: Array = b
			if xa.size() != xb.size():
				return false
			for i in xa.size():
				if not same(xa[i], xb[i]):
					return false
			return true
		TYPE_DICTIONARY:
			var da: Dictionary = a
			var db: Dictionary = b
			if da.size() != db.size():
				return false
			for k: Variant in da:
				if not db.has(k) or not same(da[k], db[k]):
					return false
			return true
		TYPE_VECTOR2:
			var va: Vector2 = a
			var vb: Vector2 = b
			return same(va.x, vb.x) and same(va.y, vb.y)
	return a == b

func _count(key: String) -> void:
	stats[key] = int(stats.get(key, 0)) + 1

func _note(kind: String, to: int, unit_id: String = "", extra: Dictionary = {}) -> void:
	_count("sent_" + kind)
	if not trace_enabled:
		return
	var e := {"kind": kind, "to": to}
	if unit_id != "":
		e["unit"] = unit_id
	e.merge(extra)
	trace.append(e)
	if trace.size() > TRACE_MAX:
		trace.pop_front()
