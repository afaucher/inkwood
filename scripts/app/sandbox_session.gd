extends Node

# THE SANDBOX IN A SESSION (Track N, proposed): what the sandbox hands its World
# and its UnitUI to when it was started as a HOST or a CLIENT instead of Local.
# A node, a child of the sandbox, that owns the WorldSync (scripts/net/world_sync.gd)
# and the small things around it. Local never creates one, so Local is untouched.
#
# THE SANDBOX CALLS (scripts/app/sandbox.gd, in this order):
#
#   session.begin(sandbox, "host" | "client")   after the World is populated: the scenario's
#                                               "local" player becomes "peer_<id>"; read `player`
#   session.attach_ui(ui)                       after UnitUI.setup: the host resolves, not the UI
#   session.on_playable()                       when the first view is baked: a client says hello
#   session.shutdown()                          on the way out
#
# THE RULES THAT ARE SET UP HERE (Alex 2026-10-09: the HOST resolves each turn and
# sends every player the result): UnitUI.auto_resolve is off on every machine, so
# a Ready that completes the set no longer resolves on whichever machine pressed
# it; WorldSync resolves, on the host only, and sends the result. UnitUI's own
# auto_begin_turn stays on: every machine begins the next turn after its own
# playback of this one. The AI runs on the host only (sandbox.gd does not attach
# it on a client).
#
# THE TWO-WINDOW CHECK (run_check): INKWOOD_AUTOSTART=host_shot / join_shot runs it
# in each of two windows -- see scripts/app/main.gd and the report that came with it.

const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")

signal status_changed(text: String)

var sandbox: Node = null
var role := ""
var sync: WorldSync = null
var player := ""
var ui: Node = null
var refusal := ""                 # why the host would not have us, "" if it did

var _label: Label = null
var _layer: CanvasLayer = null
var _down := false

func begin(sb: Node, as_role: String) -> void:
	sandbox = sb
	role = as_role
	name = "Session"
	sync = WorldSync.new()
	sync.name = "WorldSync"
	sync.display_name = NetworkManager.steam_display_name()
	add_child(sync)
	sync.setup(sb.get("world"), str(sb.get("scenario").id), str(sb.get("scenario").local_player))
	player = sync.local_player()
	sync.players_changed.connect(_refresh)
	sync.joined.connect(_refresh)
	sync.refused.connect(func(why: String) -> void:
		refusal = why
		_refresh())
	sync.host_lost.connect(_refresh)

func attach_ui(unit_ui: Node) -> void:
	ui = unit_ui
	ui.set("auto_resolve", false)
	_layer = CanvasLayer.new()
	_layer.name = "SessionLayer"
	_layer.layer = 4
	add_child(_layer)
	_label = Label.new()
	_label.name = "SessionStatus"
	_label.position = Vector2(14.0, 8.0)
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(0.18, 0.13, 0.08, 0.8))
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_label)
	if role == "host":
		sync.start()
	_refresh()

# The first view is baked: a client can play, so it says hello (the host's turn
# waits for every player it has let in, so a joiner is let in when it can play).
func on_playable() -> void:
	if role == "client":
		sync.start()
	_refresh()

func shutdown() -> void:
	_down = true

# --- Play again, for everyone (Track A, proposed) ----------------------------------------------------
#
# The simplest correct way to restart a networked game: a restart is a NEW sandbox on every
# machine (the map is rebuilt, which is the 10-15 s the first view takes), joined the way a
# game is joined the first time -- so it needs no new rule in WorldSync. Whoever presses Play
# again on the result card asks the host (a client by rpc_request_restart; the host just does
# it); the host rebuilds its sandbox and, once the new one exists, tells every client
# (rpc_restart), each of which rebuilds its own and says hello to the new host World when its
# first view is baked. Both RPCs are on THIS node, so the new sandbox's Session (the same path
# on every machine) receives them. The sandbox emits restart_requested; whoever owns the
# sandboxes (scripts/app/main.gd) replaces them.

# A player pressed Play again on the result card.
func request_restart() -> void:
	if role == "client":
		if multiplayer.multiplayer_peer != null and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			rpc_request_restart.rpc_id(WorldSync.HOST_ID)
	else:
		sandbox.call("ask_restart")

# The host, from the sandbox that REPLACED the finished one: every client rebuilds too.
func announce_restart() -> void:
	if role == "host" and multiplayer.multiplayer_peer != null:
		rpc_restart.rpc()

@rpc("any_peer", "call_remote", "reliable")
func rpc_request_restart() -> void:
	if role != "host" or _down:
		return
	# Only a finished game is restarted on a request: a second player's press arriving after the host
	# already restarted (the new game is "playing") is a stale one.
	if bool(sandbox.call("result_decided")):
		sandbox.call("ask_restart")

@rpc("authority", "call_remote", "reliable")
func rpc_restart() -> void:
	if role != "client" or _down or multiplayer.get_remote_sender_id() != WorldSync.HOST_ID:
		return
	sandbox.call("ask_restart")

func _process(_delta: float) -> void:
	if not _down:
		_refresh()

func status_text() -> String:
	if sync == null:
		return ""
	if refusal != "":
		return "Refused by the host: " + refusal
	var names: Array[String] = []
	for p: String in sync.world.players:
		names.append(sync.name_of(p) + (" (you)" if p == player else ""))
	var who := "HOST" if role == "host" else ("CLIENT" if sync.is_joined() else "CLIENT, joining...")
	return "%s  %s  turn %d  players: %s" % [who, player, sync.world.turn, ", ".join(names)]

func _refresh() -> void:
	if _label == null:
		return
	var t := status_text()
	if _label.text != t:
		_label.text = t
		status_changed.emit(t)

# --- The two-window check ---------------------------------------------------------------------

# Run in each of two windows (host_shot in one, join_shot in the other). Waits for
# the other window, plans one plane each through the UnitUI's planner (the real
# input path), waits until this window shows the OTHER window's plan too, saves a
# frame, then readies, waits for the host's resolve and the next turn, saves a
# second frame. Returns "" on success, else what went wrong. `out` is a PNG path;
# the second frame goes next to it with "_turn2" before the extension.
func run_check(out: String, timeout_s: float = 90.0) -> String:
	var t0 := Time.get_ticks_msec()
	var w: World = sync.world
	var players_ids: Array[String] = []
	for id: String in w.units:
		if w.units[id].controller == World.CONTROLLER_PLAYER:
			players_ids.append(id)
	if players_ids.size() < 2:
		return "the scenario has fewer than two player planes"
	var mine: String = players_ids[0] if role == "host" else players_ids[1]
	var theirs: String = players_ids[1] if role == "host" else players_ids[0]

	if not await _until(func() -> bool: return sync.is_joined() and w.players.size() >= 2, t0, timeout_s):
		return "the other window never joined (players: %s, joined: %s)" % [str(w.players), str(sync.is_joined())]
	# Both windows are in; let the first view settle.
	for i in 40:
		await get_tree().process_frame

	ui.call("select", mine)
	var u = w.units[mine]
	var here := Vector2(float(u.x), float(u.y))
	for k in 3:
		var a: float = float(u.heading) + (0.35 if role == "host" else -0.35) * float(k)
		var step_pt := here + Vector2(cos(a), sin(a)) * 320.0 * float(k + 1)
		ui.get("planner").call("place_point", step_pt)
	if (w.units[mine].plan as Array).size() < 3:
		return "the planner placed %d of 3 steps for %s" % [(w.units[mine].plan as Array).size(), mine]

	if not await _until(func() -> bool: return (w.units[theirs].plan as Array).size() >= 3, t0, timeout_s):
		return "never saw the other window's plan for %s" % theirs
	for i in 40:
		await get_tree().process_frame
	var err := _save(out)
	if err != "":
		return err

	# Both ready: the host resolves, sends the result, both play it back.
	var turn: int = w.turn
	ui.call("press_ready")
	if not await _until(func() -> bool: return w.turn > turn, t0, timeout_s):
		return "turn %d never ended (ready: %s)" % [turn, str(w.ready)]
	for i in 40:
		await get_tree().process_frame
	return _save(out.get_basename() + "_turn2." + out.get_extension())

# THE TWO-WINDOW GAME (INKWOOD_AUTOSTART=host_game / join_game, Track A, proposed): the first fight
# played to its END across two windows. Each turn the HOST plans both fighters to circle in place (any
# player edits any plan: the plans go to the client over the wire), and once this window shows those
# plans both windows ready; nobody fights, so the bomber reaches the target (a loss) in about twelve turns.
# Then it waits for this window's result card and saves a frame of it to `out`. Returns "" on success.
func run_game(out: String, timeout_s: float = 900.0) -> String:
	var t0 := Time.get_ticks_msec()
	var w: World = sync.world
	if not await _until(func() -> bool: return sync.is_joined() and w.players.size() >= 2, t0, timeout_s):
		return "the other window never joined (players: %s, joined: %s)" % [str(w.players), str(sync.is_joined())]
	for i in 40:
		await get_tree().process_frame
	var last := 0
	while not bool(sandbox.call("result_decided")):
		var came: bool = await _until(func() -> bool: return bool(sandbox.call("result_decided")) \
			or (w.phase == World.PHASE_PLANNING and not bool(ui.call("is_playing")) and w.turn > last), t0, timeout_s)
		if not came:
			return "the turn after %d never came (phase %s, ready: %s)" % [last, w.phase, str(w.ready)]
		if bool(sandbox.call("result_decided")):
			break
		last = w.turn
		print("[Session] %s: planning turn %d" % [role, last])
		if role == "host":
			for id: String in w.units:
				if w.units[id].controller == World.CONTROLLER_PLAYER and not w.units[id].down:
					for i in w.steps_per_turn(id):
						w.plan_step(id, i, {"turn": 1.5})
		# Two frames for the edits to go out BEFORE the Ready: WorldSync takes the host player's Ready back when the
		# flush of an edit made in the same frame runs inside the Ready (a human cannot do both in one frame).
		await get_tree().process_frame
		await get_tree().process_frame
		var planned: bool = await _until(func() -> bool:
			for id: String in w.units:
				if w.units[id].controller == World.CONTROLLER_PLAYER and not w.units[id].down and (w.units[id].plan as Array).is_empty():
					return false
			return true, t0, timeout_s)
		if not planned:
			return "never saw the host's plans for turn %d" % last
		ui.call("press_ready")
	var card: bool = await _until(func() -> bool: return bool(sandbox.call("result_card_shown")), t0, timeout_s)
	if not card:
		return "the result card never came up (result: %s)" % str(sandbox.get("result"))
	for i in 40:
		await get_tree().process_frame
	print("[Session] %s: the game ended on turn %d: %s" % [role, int(sandbox.get("result")["turn"]), str(sandbox.get("result")["reason"])])
	return _save(out)

func _until(cond: Callable, t0: int, timeout_s: float) -> bool:
	var last_say := Time.get_ticks_msec()
	while not cond.call():
		if float(Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		# A wait that lasts is said aloud every ten seconds, so a stalled two-window run says where.
		if Time.get_ticks_msec() - last_say > 10000:
			last_say = Time.get_ticks_msec()
			var w: World = sync.world
			print("[Session] %s still waiting: turn %d, %s, ready %s, playing %s" % [role, w.turn, w.phase, str(w.ready), str(ui != null and bool(ui.call("is_playing")))])
		await get_tree().process_frame
	return true

# A frame of this window to `path` ("" on success, else why not).
func save_frame(path: String) -> String:
	return _save(path)

func _save(path: String) -> String:
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var err := img.save_png(path)
	print("[Session] %s frame %s -> %s (%s)" % [role, str(img.get_size()), ProjectSettings.globalize_path(path), error_string(err)])
	return "" if err == OK else "could not save %s: %s" % [path, error_string(err)]
