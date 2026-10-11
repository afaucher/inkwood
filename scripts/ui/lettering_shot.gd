extends SceneTree

# LETTERING SHOTS (Track L, 2026-10-10; Alex: step labels on two lines with no step number, and every piece of lettering readable or
# left off). WINDOWED ONLY, at the window's native size. The REAL Strike, started as the menu starts it (the Main scene, Local).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --script res://scripts/ui/lettering_shot.gd `
#       -- [out=tmp/lettering] [window=1280x720] [phase=after]
#
# The same states under both phases (run "before" on the code as it stood, "after" on the new one); every file is
# <width>x<height>_<name>_<phase>.png:
#
#   planning  the whole window at the planning view: the bomber with THREE STEPS planned, Bomb Drop on step 2 (on the radio tower), the
#             tower's TARGET ring, the turn clock, the roster and the orders card with its side view
#   cards     the roster and the orders card, cropped, magnified 2x
#   clock     the turn clock, 2x, and (clock_warn) with "2 turns left", 2x
#   target    the TARGET ring and its word, 2x
#   hint      the key hint card (the first seconds of the game), 2x
#   knobs     the F2 knob panel, 2x
#   result    the end-of-mission card (a won result), the window
#   loading   the blocking loading card, the window
#   refused   the "off the map" mark a step refused for leaving the map leaves, 2x

const World = preload("res://scripts/sim/world.gd")

const BOMBER := "bomber_1"
const TOWER := "radio_tower_1"
const DROP_STEP := 1

var out_dir := "tmp/lettering"
var opts: Dictionary = {}
var size := Vector2i(1280, 720)
var phase := "after"
var main: Node = null
var sb: Node = null
var ui: Node = null
var pl: Node = null
var w: World = null
var heading := 0.0
var start_m := Vector2.ZERO
var tower_m := Vector2.ZERO
var _failures := 0
var _saved: Array = []

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[lettering-shot] needs a windowed run: under --headless nothing is drawn")
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
	phase = str(opts.get("phase", phase))
	var win := str(opts.get("window", "1280x720")).split("x")
	if win.size() == 2:
		size = Vector2i(int(win[0]), int(win[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _say(msg: String) -> void:
	print("[lettering-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[lettering-shot] FAIL  " + msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[lettering-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(12)

func _grab() -> Image:
	await _frames(4)
	await RenderingServer.frame_post_draw
	return root.get_viewport().get_texture().get_image()

func _name(name: String) -> String:
	return "%dx%d_%s_%s.png" % [size.x, size.y, name, phase]

func _save(img: Image, name: String) -> void:
	var path := out_dir.path_join(_name(name))
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1
	_saved.append(_name(name))

# A crop of `r` (window px), magnified `k` times.
func _crop(img: Image, r: Rect2, name: String, k: int = 2) -> void:
	var ri := Rect2i(Vector2i(int(floor(r.position.x)), int(floor(r.position.y))), Vector2i(int(ceil(r.size.x)), int(ceil(r.size.y))))
	ri = ri.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	var c := img.get_region(ri)
	if k > 1:
		c.resize(c.get_width() * k, c.get_height() * k, Image.INTERPOLATE_LANCZOS)
	_save(c, name)

func _click(p: Vector2) -> bool:
	var used: bool = ui.map_press(p)
	ui.map_release(p)
	return used

func _frame_plan() -> void:
	var pts: Array = [start_m, tower_m + Vector2(80.0, 140.0), tower_m + Vector2(-80.0, -140.0)]
	for st: Dictionary in pl.states(BOMBER):
		if bool(st["planned"]):
			pts.append(Vector2(float(st["x"]), float(st["y"])))
	sb.ctl.frame_max_zoom = 1.0
	sb.ctl.frame_points(pts)
	sb.ctl.stop_follow()

func _place(layout: Dictionary) -> void:
	for id: String in layout:
		var u = w.units[id]
		var at: Vector2 = layout[id][0]
		u.x = at.x
		u.y = at.y
		u.heading = float(layout[id][1])
		u.out_of_bounds = false
	ui.marker_layer.update_poses()

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	_say("window %s, viewport %s, phase %s" % [str(DisplayServer.window_get_size()), str(root.get_viewport().get_visible_rect().size), phase])
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[lettering-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable and sb.scenario.id == "strike", "the Strike is playable")
	w = sb.world
	ui = sb.ui
	pl = ui.planner
	sb.hint.visible = false
	sb.scenario.view["result_card_delay_s"] = 9999.0

	# --- the units: the bomber where step 2's bombs fall on the tower; a fighter by the tower so it is in sight -----------------
	tower_m = Vector2(float(w.units[TOWER].x), float(w.units[TOWER].y))
	heading = 0.0 if tower_m.x >= 1700.0 else PI
	var dir := Vector2.from_angle(heading)
	var side := Vector2(-dir.y, dir.x)
	start_m = tower_m - dir * 980.0
	var corner := Vector2(4400.0 if tower_m.x < 2500.0 else 600.0, 4400.0 if tower_m.y < 2500.0 else 600.0)
	_place({BOMBER: [start_m, heading], "light_fighter_1": [tower_m - dir * 330.0 + side * 260.0, heading],
		"heavy_fighter_1": [start_m - dir * 80.0 + side * 190.0, heading], "patrol_1": [corner, heading + PI]})
	ui.select(BOMBER)
	pl.clear()
	pl.place_point(start_m + dir * 142.0)
	pl.place_point(start_m + dir * 284.0)
	pl.place_point(start_m + dir * 426.0)
	var ideal: Vector2 = pl.bombs.cone(BOMBER, DROP_STEP)["ideal_aim"]
	start_m += tower_m - ideal
	_place({BOMBER: [start_m, heading]})
	pl.clear()
	await _frames(3)
	pl.place_point(start_m + dir * 142.0)
	pl.place_point(start_m + dir * 284.0)
	pl.place_point(start_m + dir * 426.0)
	# Step 2 selected, the tower targeted, Bomb Drop pressed (the card's own buttons, a press and release on the node).
	_frame_plan()
	await _wait_view()
	_check(_click(pl.node_screen(1)), "step 2's node is clicked")
	ui.marker_layer.update_poses()
	await _frames(8)
	_check(_click(sb.map_view.world_to_screen(tower_m)), "the tower is targeted")
	_check(ui.orders.press_button("drop"), "Bomb Drop is pressed on step 2")
	_check(pl.step_has_drop(DROP_STEP), "step 2 has its drop")
	_frame_plan()
	await _wait_view()

	# --- plan: the whole window, and the cards, the clock and the TARGET ring cropped ---------------------------------------------
	var img := await _grab()
	_save(img, "planning")
	var rr: Rect2 = ui.roster.get_global_rect()
	var oo: Rect2 = ui.orders.get_global_rect()
	_crop(img, rr.merge(oo).grow(8.0), "cards")
	var cx: float = (float(size.x) - float(ui.sidebar_width_px())) * 0.5
	_crop(img, Rect2(cx - 110.0, 2.0, 220.0, 60.0), "clock")
	if sb.objective != null and sb.objective.shown():
		var ring: Dictionary = sb.objective.screen_ring()
		var c: Vector2 = ring["centre"]
		var r: float = ring["radius_px"]
		_crop(img, Rect2(c.x - r - 14.0, c.y - r - 14.0, 2.0 * r + 28.0, 2.0 * r + 56.0), "target")
	else:
		_say("the objective ring is not shown")

	# The clock with its warning (the last three turns): the world's turn put forward.
	var turn_was: int = w.turn
	w.turn = maxi(int(sb.scenario.turn_limit()) - 2, 1)
	await _frames(4)
	img = await _grab()
	_crop(img, Rect2(cx - 110.0, 2.0, 220.0, 78.0), "clock_warn")
	w.turn = turn_was
	await _frames(2)

	# The refused mark: a step asked for off the map (the mark lives REFUSED_SHOW_MS, so it is drawn and grabbed at once).
	var off_m := Vector2(float(w.units[BOMBER].x), float(w.units[BOMBER].y)) + dir * 300.0
	pl.refused_world = off_m
	pl.refused_ms = Time.get_ticks_msec()
	pl.refused_aim = off_m + side * 120.0
	pl.refused_aim_ms = Time.get_ticks_msec()
	await _frames(2)
	await RenderingServer.frame_post_draw
	img = root.get_viewport().get_texture().get_image()
	var op: Vector2 = sb.map_view.world_to_screen(off_m)
	var oa: Vector2 = sb.map_view.world_to_screen(off_m + side * 120.0)
	var both := Rect2(op, Vector2.ZERO).expand(oa).expand(oa + Vector2(150.0, 0.0)).expand(op + Vector2(120.0, 0.0))
	_crop(img, both.grow(30.0), "refused")
	pl.refused_ms = -100000
	pl.refused_aim_ms = -100000

	# --- the other cards: hint, knobs, result, loading -------------------------------------------------------------------------------
	sb.hint.visible = true
	sb.hint.start()
	await _frames(4)
	img = await _grab()
	var hint_h := 90.0 if sb.hint.headline != "" else 50.0
	_crop(img, Rect2(0.0, float(size.y) - hint_h - 24.0, minf(float(size.x) - ui.sidebar_width_px(), 760.0), hint_h + 24.0), "hint")
	sb.hint.visible = false

	sb.knobs.toggle()
	await _frames(4)
	img = await _grab()
	var kr: Rect2 = sb.knobs.get_global_rect()
	_crop(img, kr.grow(10.0), "knobs")
	sb.knobs.toggle()

	ui.show_result({"state": "won", "reason": "radio_tower_1 is down", "turn": 7, "t": 12.0})
	await _frames(4)
	img = await _grab()
	_save(img, "result")
	ui.hide_result()
	await _frames(2)

	sb.loading.visible = true
	sb.loading.set_progress(12, 27, 8.0)
	await _frames(4)
	img = await _grab()
	_save(img, "loading")
	sb.loading.visible = false

	var f := FileAccess.open(out_dir.path_join("shots_%dx%d_%s.json" % [size.x, size.y, phase]), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"saved": _saved, "failures": _failures}, "  ", false))
		f.close()
	_say("done: %d failure(s)" % _failures)
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)
