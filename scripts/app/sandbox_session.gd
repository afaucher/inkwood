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

func _until(cond: Callable, t0: int, timeout_s: float) -> bool:
	while not cond.call():
		if float(Time.get_ticks_msec() - t0) / 1000.0 > timeout_s:
			return false
		await get_tree().process_frame
	return true

func _save(path: String) -> String:
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path).get_base_dir())
	var err := img.save_png(path)
	print("[Session] %s frame %s -> %s (%s)" % [role, str(img.get_size()), ProjectSettings.globalize_path(path), error_string(err)])
	return "" if err == OK else "could not save %s: %s" % [path, error_string(err)]
