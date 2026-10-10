extends Node

# NetRig -- several peers in ONE process, over real ENet sockets (Track N).
# Test and development support, not game code: the gate's networking tests
# (scripts/tests/test_world_sync.gd, test_net_sandbox.gd) stand their peers up
# with it, and a tool that wants a host and two clients on one machine can too.
#
# HOW: a SceneTree holds several MultiplayerAPI instances, each rooted at a
# different node (SceneTree.set_multiplayer; test_enet_loopback.gd is the
# proof). Everything under "Host" sees the host's API, everything under
# "Client1" the first client's -- so a WorldSync node at "Host/WorldSync" and
# another at "Client1/WorldSync" are the same RPC address, and the call crosses
# the socket between them.
#
#   var rig := NetRig.new()
#   add_child(rig)                         # the rig must be in the tree first
#   var host := rig.add_host(28779)        # a World + AiDumb + WorldSync, started
#   var a: NetRig.Peer = await rig.add_client(28779, "Ann")   # connected, hello sent
#   await rig.wait_until(func() -> bool: return a.sync.is_joined())
#
# THE PEERS' WORLDS are built from the sandbox scenario (data/scenarios/
# sandbox.json), the way the sandbox builds them; the scenario's "local" player
# is swapped for the peer's own. Only the host has the AI.
#
# TIMING: a message takes real time over a socket and a headless run does frames
# as fast as it can, so wait for a CONDITION (wait_until), never for N frames. To
# prove that something did NOT arrive, send something that must arrive after it,
# on the same ordered channel, and wait for that.

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")

const SCENARIO_ID := "sandbox"

class Peer extends RefCounted:
	var label := ""
	var root: Node = null
	var mp: SceneMultiplayer = null
	var enet: ENetMultiplayerPeer = null
	var world: World = null
	var ai: AiDumb = null
	var sync: WorldSync = null  # the WorldSync
	var resolved: Array[int] = []  # the turns this peer's World announced (turn_resolved)
	var joined_count := 0          # times its WorldSync said it was welcomed

	func id() -> int:
		return mp.get_unique_id()

	func player() -> String:
		return sync.local_player()

var host: Peer = null
var clients: Array = []

# The host: binds `port`, builds its World (with the AI), starts serving.
func add_host(port: int, display: String = "Host", with_game: bool = true) -> Peer:
	var p := Peer.new()
	p.label = "Host"
	_make_root(p)
	p.enet = ENetMultiplayerPeer.new()
	var err := p.enet.create_server(port, 8)
	if err != OK:
		push_error("NetRig: could not bind port %d (error %d)" % [port, err])
		return null
	p.mp.multiplayer_peer = p.enet
	if with_game:
		_make_game(p, display, true)
	host = p
	return p

# A client: connects to the host on this machine, builds its World, says hello.
# Awaitable; null if the connection never came up.
func add_client(port: int, display: String = "", with_game: bool = true) -> Peer:
	var p := Peer.new()
	p.label = "Client%d" % (clients.size() + 1)
	_make_root(p)
	p.enet = ENetMultiplayerPeer.new()
	var err := p.enet.create_client("127.0.0.1", port)
	if err != OK:
		push_error("NetRig: could not open a client socket to port %d (error %d)" % [port, err])
		return null
	p.mp.multiplayer_peer = p.enet
	var up: bool = await wait_until(func() -> bool:
		return p.enet.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED)
	if not up:
		push_error("NetRig: %s never connected to port %d" % [p.label, port])
		return null
	if with_game:
		_make_game(p, display if display != "" else p.label, false)
	clients.append(p)
	return p

# Close one peer's connection and take its nodes out (a player leaving).
func drop(p: Peer) -> void:
	if p.enet != null:
		p.enet.close()
	p.mp.multiplayer_peer = null
	clients.erase(p)
	p.root.queue_free()

func close_all() -> void:
	for p: Peer in clients.duplicate():
		drop(p)
	if host != null:
		host.enet.close()
		host.mp.multiplayer_peer = null
		host.root.queue_free()
		host = null

# Wait (frames, with a millisecond of real time each, so sockets get their turn)
# until `cond` holds. False if it never did.
func wait_until(cond: Callable, max_frames: int = 1500) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().process_frame
		OS.delay_msec(1)
	return cond.call()

# Every peer, the host first.
func peers() -> Array:
	var out: Array = []
	if host != null:
		out.append(host)
	out.append_array(clients)
	return out

# True when every peer's World holds exactly the host's game: turn, phase, every
# unit's net state and history, every player unit's plan, the players and the
# ready flags. Returns "" when it does, else the first difference.
func differences_from_host(p: Peer) -> String:
	var h: World = host.world
	var w: World = p.world
	if w.turn != h.turn:
		return "turn %d against %d" % [w.turn, h.turn]
	if w.phase != h.phase:
		return "phase %s against %s" % [w.phase, h.phase]
	var hp: Array = h.players.duplicate()
	var wp: Array = w.players.duplicate()
	hp.sort()
	wp.sort()
	if hp != wp:
		return "players %s against %s" % [str(wp), str(hp)]
	for who: String in h.participants():
		if w.is_ready(who) != h.is_ready(who):
			return "ready flag of %s: %s against %s" % [who, str(w.is_ready(who)), str(h.is_ready(who))]
	for id: String in h.units:
		var hu = h.units[id]
		var wu = w.units[id]
		if not WorldSync.same(hu.net_state(), wu.net_state()):
			return "%s's state: %s against %s" % [id, str(wu.net_state()), str(hu.net_state())]
		if not WorldSync.same(hu.history, wu.history):
			return "%s's history differs" % id
		if hu.controller == World.CONTROLLER_PLAYER and not WorldSync.same(hu.plan, wu.plan):
			return "%s's plan: %s against %s" % [id, str(wu.plan), str(hu.plan)]
	return ""

# --- Building ------------------------------------------------------------------------------------

func _make_root(p: Peer) -> void:
	p.root = Node.new()
	p.root.name = p.label
	add_child(p.root)
	p.mp = SceneMultiplayer.new()
	get_tree().set_multiplayer(p.mp, p.root.get_path())

func _make_game(p: Peer, display: String, is_host: bool) -> void:
	p.world = World.new()
	p.world.quiet = false
	var scenario := SandboxScenario.new(SCENARIO_ID)
	scenario.populate(p.world)
	p.world.turn_resolved.connect(func(turn: int, _h: Dictionary, _e: Array) -> void: p.resolved.append(turn))
	p.sync = WorldSync.new()
	p.sync.name = "WorldSync"
	p.sync.display_name = display
	p.root.add_child(p.sync)
	p.sync.setup(p.world, SCENARIO_ID, scenario.local_player)
	p.sync.joined.connect(func() -> void: p.joined_count += 1)
	if is_host:
		p.ai = AiDumb.new(p.world)
		p.ai.attach()
	p.sync.start()
