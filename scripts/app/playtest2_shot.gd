extends SceneTree

# PLAYTEST 2 SHOTS (builder PT2, 2026-10-11; Alex's notes on the 2026-10-10.134839 build). WINDOWED ONLY.
# The REAL Strike, started as the menu starts it (the Main scene, Local, INKWOOD_SCENARIO=strike), looked at in the
# moments the notes are about, at the window's NATIVE size:
#
#   $env:INKWOOD_STEAM = "off"; $env:INKWOOD_SCENARIO = "strike"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --script res://scripts/app/playtest2_shot.gd `
#       -- [out=tmp/playtest2] [window=1600x900] [tag=after] [legacy=<data path>,<data path>]
#
#   <tag>_t1_plan_zoom1.png      turn 1 while planning, nothing planned, nothing selected, the three players framed (zoom <= 1)
#   <tag>_t1_plan_wide.png       the same at the planning zoom (0.35)
#   <tag>_t1_selected.png        a fighter selected (its ring, its fan), nothing planned
#   <tag>_t2_plan_zoom1.png      turn 2 while planning, nothing planned
#   <tag>_t2_plan_planned.png    turn 2 while planning, the fighters' plans on the map, the bomber selected
#   <tag>_t1_play_2s5.png        turn 1 mid-playback (2.5 s into the turn)
#   <tag>_t2_play_2s5.png        turn 2 mid-playback
#
# `legacy=` puts the named ui.json booleans (dotted paths) to true after the game has loaded, so the same moment can be
# drawn with an old line back (a switch's before picture).

const World = preload("res://scripts/sim/world.gd")
const StrikePlay = preload("res://scripts/test_support/strike_play.gd")

const BOMBER := "bomber_1"

var out_dir := "tmp/playtest2"
var opts: Dictionary = {}
var size := Vector2i(1600, 900)
var tag := "after"
var main: Node = null
var sb: Node = null
var _failures := 0
var _frame_no := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[playtest2-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	out_dir = str(opts.get("out", out_dir))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	tag = str(opts.get("tag", tag))
	var win := str(opts.get("window", "1600x900")).split("x")
	if win.size() == 2:
		size = Vector2i(int(win[0]), int(win[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame
		_frame_no += 1

func _say(msg: String) -> void:
	print("[playtest2-shot] ", msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[playtest2-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(14)

func _shot(file: String) -> void:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join("%s_%s" % [tag, file])
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1

func _until(cond: Callable, max_ms: int) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t > max_ms:
			return false
		await process_frame
		_frame_no += 1
	return true

func _set_data(path: String, value: Variant) -> void:
	var st = sb.ui.style
	var parts := path.split(".")
	var cur: Dictionary = st.ui
	for i in parts.size() - 1:
		cur = cur[parts[i]]
	cur[parts[parts.size() - 1]] = value

# The players' places, to frame them: the units and where their plans take them.
func _players_m(w: World) -> Array:
	var pts: Array = []
	for id: String in w.units:
		var u = w.units[id]
		if u.controller == World.CONTROLLER_PLAYER and not u.down:
			pts.append(Vector2(float(u.x), float(u.y)))
			for st: Dictionary in w.planned_states(id):
				pts.append(Vector2(float(st["x"]), float(st["y"])))
	return pts

func _frame_players(w: World, max_zoom: float) -> void:
	var pts := _players_m(w)
	# a margin round the group, so the ribbons behind them fit
	var padded: Array = []
	for p: Vector2 in pts:
		for c: Vector2 in [Vector2(-420, -300), Vector2(420, -300), Vector2(420, 300), Vector2(-420, 300)]:
			padded.append(p + c)
	sb.ctl.frame_max_zoom = max_zoom
	sb.ctl.frame_points(padded)
	sb.ctl.stop_follow()
	await _wait_view()

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	_say("window %s, viewport %s, tag %s" % [str(DisplayServer.window_get_size()), str(root.get_viewport().get_visible_rect().size), tag])
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[playtest2-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_say("scenario %s, playable %s" % [sb.scenario.id, str(sb.is_playable)])
	var w: World = sb.world
	var ui = sb.ui
	sb.scenario.view["result_card_delay_s"] = 9999.0
	for p: String in str(opts.get("legacy", "")).split(",", false):
		_set_data(p, true)
		_say("legacy: %s = true" % p)
	await _wait_view()
	var planner = StrikePlay.for_world(w)

	# Turn 1, planning, nothing planned.
	var ok := await _until(func() -> bool: return w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == 1, 180000)
	if not ok:
		printerr("[playtest2-shot] turn 1 never came")
		quit(1)
		return
	ui.selection.clear()
	await _frame_players(w, 1.0)
	await _shot("t1_plan_zoom1.png")
	await _frame_players(w, 0.35)
	await _shot("t1_plan_wide.png")
	ui.select("light_fighter_1")
	await _frame_players(w, 1.0)
	await _shot("t1_selected.png")
	ui.selection.clear()

	# Turn 1 played back: 2.5 s in.
	planner.plan_players()
	ui.press_ready()
	await _until(func() -> bool: return ui.is_playing(), 30000)
	ui.marker_layer.playback_paused = true
	ui.marker_layer.set_playback_time(2.5)
	await _frame_players(w, 1.0)
	ui.marker_layer.set_playback_time(2.5)
	await _shot("t1_play_2s5.png")
	ui.marker_layer.playback_paused = false

	# Turn 2, planning.
	ok = await _until(func() -> bool: return w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == 2, 180000)
	if not ok:
		printerr("[playtest2-shot] turn 2 never came")
		quit(1)
		return
	ui.selection.clear()
	await _frame_players(w, 1.0)
	await _shot("t2_plan_zoom1.png")
	planner.plan_players()
	ui.select(BOMBER)
	await _frame_players(w, 1.0)
	await _shot("t2_plan_planned.png")
	ui.selection.clear()

	# Turn 2 played back: 2.5 s in.
	ui.press_ready()
	await _until(func() -> bool: return ui.is_playing(), 30000)
	ui.marker_layer.playback_paused = true
	ui.marker_layer.set_playback_time(2.5)
	await _frame_players(w, 1.0)
	ui.marker_layer.set_playback_time(2.5)
	await _shot("t2_play_2s5.png")
	ui.marker_layer.playback_paused = false

	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)
