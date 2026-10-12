extends SceneTree

# THE THIRD PLAYTEST'S CARD, ROSTER AND TANK ASKS, ON SCREEN (builder CARD, 2026-10-11, decision playtest-3). WINDOWED ONLY -- under --headless
# nothing is drawn (the tests are the headless proof: test_ui_roster, test_step_select, test_side_view, test_tank_ui, test_tank, test_ui_guns).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/playtest3_shot.gd -- [out=tmp/playtest3] [window=1920x1080]
#
# HOLD THE BRIDGE (the menu's scenario selector on it, as bridge_shot.gd does), at the window's NATIVE size, a PNG per moment:
#
#   01_tank_card.png          a tank selected with a step placed: the orders card with its big step strip (no 'step 1 of 2', no hint line),
#                             'no special: weapons fire on their own' under the target line, the Special button off; the roster beside it with the
#                             plan glyph and pips and no 'plan: 1 of 2 steps'; the views card under the orders card
#   <name>_column.png         for each shot below, the sidebar column alone (roster, orders, views), cropped from the same frame
#   02_tank_arc.png           the same tank with the arcs on: its gun's FORWARD arc of 170 degrees on the map, and the Top strip of the views card
#   03_special_refused.png    the cruiser selected, a step placed and no target: the special refused, with its reason on the card
#   04_special_set.png        the cruiser with Main Guns Fire SET on a spotted enemy tank: the button pressed, the strip's mark, 'step 1: Main Guns Fire'
#   05_special_reloading.png  the turn after: the guns are reloading, and the card says for how long
#
# The cruiser is run by the scripted defence (scripts/test_support/bridge_play.gd), as bridge_shot.gd does.

const World = preload("res://scripts/sim/world.gd")
const BridgePlay = preload("res://scripts/test_support/bridge_play.gd")

const BRIDGE_IDX := 4
const SHIP := "cruiser_1"
const BRIDGE := "bridge_1"
const TANK1 := "tank_1"
const TANK2 := "tank_2"

var out_dir := "tmp/playtest3"
var opts: Dictionary = {}
var size := Vector2i(1920, 1080)
var main: Node = null
var sb: Node = null
var dbg: Node = null
var _failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[playtest3-shot] needs a windowed run: under --headless nothing is drawn")
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
	var win := str(opts.get("window", "1920x1080")).split("x")
	if win.size() == 2:
		size = Vector2i(int(win[0]), int(win[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _say(msg: String) -> void:
	print("[playtest3-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[playtest3-shot] FAIL  " + msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[playtest3-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(14)

func _shot(file: String, crop_column: bool = false) -> void:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join(file)
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1
	if crop_column:
		var r: Rect2 = sb.ui.sidebar_rect()
		var rect := Rect2i(int(r.position.x), 0, int(r.size.x), mini(int(r.end.y) + 12, img.get_height()))
		var col := img.get_region(rect)
		var cpath := out_dir.path_join(file.get_basename() + "_column.png")
		col.save_png(cpath)
		_say("saved %s (%s)" % [cpath, str(col.get_size())])

func _until(cond: Callable, max_ms: int) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t > max_ms:
			return false
		await process_frame
	return true

func _ring(at: Vector2, r: float) -> Array:
	var pts: Array = []
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		pts.append(at + corner * r)
	return pts

func _frame(points: Array, max_zoom: float) -> void:
	sb.ctl.frame_max_zoom = max_zoom
	sb.ctl.frame_points(points)
	sb.ctl.stop_follow()
	await _wait_view()

func _unit_at(w: World, id: String) -> Vector2:
	return Vector2(float(w.units[id].x), float(w.units[id].y))

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	dbg = root.get_node("DebugSettings")
	dbg.set_choice("scenario", BRIDGE_IDX)
	_say("the scenario knob says: %s" % dbg.get_choice_name("scenario"))
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[playtest3-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable, "Hold the bridge is playable")
	var w: World = sb.world
	var ui = sb.ui
	sb.scenario.view["result_card_delay_s"] = 9999.0
	var planner = BridgePlay.for_world(w)
	await _wait_view()
	var ok := await _until(func() -> bool: return w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == 1, 180000)
	if not ok:
		printerr("[playtest3-shot] turn 1 never came")
		quit(1)
		return

	# --- 01: a tank, a step placed ahead of it --------------------------------------------------------------------------------------
	var tank_at := _unit_at(w, TANK1)
	var bridge_at := _unit_at(w, BRIDGE)
	ui.selection.clear()
	ui.select(TANK1)
	var heading := float(w.units[TANK1].heading)
	var ahead := tank_at + Vector2.from_angle(heading) * 40.0
	var st: Dictionary = ui.planner.place_point(ahead)
	_check(not st.is_empty(), "a step is placed for the tank")
	var pts: Array = _ring(bridge_at, 120.0)
	pts.append_array(_ring(tank_at, 60.0))
	pts.append_array(_ring(_unit_at(w, TANK2), 60.0))
	await _frame(pts, 2.2)
	ui.set_arcs(false)
	var state: Dictionary = ui.orders.special_state()
	_check(not bool(state["has"]) and str(state["reason"]) == "no special: weapons fire on their own", "the tank's card says: '%s'" % str(state["reason"]))
	await _shot("01_tank_card.png", true)

	# --- 02: the arcs on: the forward 170 degrees ------------------------------------------------------------------------------------
	ui.set_arcs(true)
	await _frames(6)
	await _shot("02_tank_arc.png", true)
	ui.set_arcs(false)
	ui.planner.clear()   # (the tank holds the road: its step was for the picture)

	# --- 03: the cruiser, a step placed, no target: the special refused -------------------------------------------------------------------
	ui.selection.clear()
	ui.select(SHIP)
	var ship_at := _unit_at(w, SHIP)
	var sh := float(w.units[SHIP].heading)
	_check(not ui.planner.place_point(ship_at + Vector2.from_angle(sh) * 60.0).is_empty(), "a step is placed for the cruiser")
	var ss: Dictionary = ui.orders.special_state()
	_say("the cruiser's special, no target: %s" % str(ss))
	_check(bool(ss["has"]) and not bool(ss["engaged"]) and str(ss["reason"]) != "", "the cruiser's special is refused with a reason: '%s'" % str(ss["reason"]))
	await _frame(pts, 2.2)
	await _shot("03_special_refused.png", true)
	ui.planner.clear()

	# --- 04, 05: play turns until the scripted defence has a spotted target for the guns --------------------------------------------------
	var got_set := false
	for turn_no in range(1, 12):
		ok = await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == turn_no), 180000)
		if not ok or sb.result_decided():
			break
		planner.plan_players()
		if not got_set and planner.salvos > 0:
			got_set = true
			var target := str(planner._target)
			ui.selection.clear()
			ui.select(SHIP)
			ui.set_target_unit(target)
			ui.planner.set_focus_step(0)
			await _frames(4)
			var tpos := _unit_at(w, target)
			var fpts: Array = _ring(bridge_at, 90.0)
			fpts.append_array(_ring(tpos, 70.0))
			await _frame(fpts, 1.6)
			var on: Dictionary = ui.orders.special_state()
			_say("the cruiser's special, set on %s: %s" % [target, str(on)])
			_check(bool(on["engaged"]) and bool(on["will_fire"]), "Main Guns Fire is SET on %s and will fire" % target)
			await _shot("04_special_set.png", true)
			ui.press_ready()
			var start := Time.get_ticks_msec()
			while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
				await process_frame
			continue
		if got_set:
			# the turn after: the guns are reloading
			var tgt2 := "tank_e1"
			ui.selection.clear()
			ui.select(SHIP)
			var s2 := _unit_at(w, SHIP)
			ui.planner.clear()
			ui.planner.place_point(s2 + Vector2.from_angle(float(w.units[SHIP].heading)) * 60.0)
			ui.set_target_unit(tgt2)
			ui.planner.set_focus_step(0)
			await _frames(4)
			var rs: Dictionary = ui.orders.special_state()
			_say("the cruiser's special, a turn after: %s" % str(rs))
			var fpts2: Array = _ring(bridge_at, 90.0)
			fpts2.append_array(_ring(_unit_at(w, tgt2), 70.0))
			await _frame(fpts2, 1.6)
			await _shot("05_special_reloading.png", true)
			_check(not bool(rs["engaged"]) and str(rs["reason"]) != "", "refused again, with its reason: '%s'" % str(rs["reason"]))
			break
		ui.press_ready()
		var start2 := Time.get_ticks_msec()
		while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start2 < 120000:
			await process_frame
	_check(got_set, "the scripted defence planned a salvo within eleven turns")
	_say("failures %d" % _failures)
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)
