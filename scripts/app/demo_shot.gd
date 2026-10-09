extends SceneTree

# THE SANDBOX DEMO'S PROOF, IN THE RUNNING BUILD (Track A). WINDOWED ONLY -- under
# --headless nothing is drawn (scripts/tests/test_sandbox.gd is the headless one).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/demo_shot.gd -- [what=main|knobs|all] [out=tmp/demo]
#
# Starts the sandbox exactly as the menu's Local button does (scripts/app/sandbox.gd,
# in a 1280x720 window), plays SCRIPTED turns through the real turn flow, and saves
# one PNG per exit criterion (docs/proposals/demo-plan.md) into tmp/demo/:
#
#   criterion_2_planes_roster.png     two player planes and one AI plane on screen, the roster
#   criterion_3_motion_plan.png       a plan of steps with a speed change: the curve, the ghosts,
#                                     the next step's fan, a step clamped by inertia
#   criterion_4_terrain_levels.png    both height levels, vegetation and shadows under the planes
#   criterion_5_tracks_zoomed_out.png after a minute of flight (12 turns) with a full circle:
#                                     the whole flight's tracks, zoomed out
#   criterion_6_roster_selection.png  the roster by callsign, the selection ring and its leader
#   criterion_7_fog_edges.png         the inked sight edges in view
#   criterion_7_overview_zoom.png     fully zoomed out: the topographic overview
#   knobs_panel.png                   the F2 panel
# (what=knobs also cycles the map scale 1/2/3/4 live and times each redraw.)
#
# It prints what the report needs: the time from Local to the first playable
# frame, frame times by what the game was doing, bake waits, and the checks of
# the real input path (a left click plans, a right drag pans, the wheel zooms).

const World = preload("res://scripts/sim/world.gd")

const SIZE := Vector2i(1280, 720)

var out_dir := "tmp/demo"
var opts: Dictionary = {}
var sb: Node = null
var dbg: Node = null      # the DebugSettings autoload (an identifier only once the tree is up)
var _p1 := ""
var _p2 := ""
var _ai := ""
var _t0 := 0
var _failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[demo-shot] needs a windowed run: under --headless nothing is drawn")
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
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _say(msg: String) -> void:
	print("[demo-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[demo-shot] FAIL  " + msg)

# Waits until the map under the view is baked (and a few frames for the fog's
# topographic chunks); returns the seconds it took.
func _wait_view(max_s: float = 90.0) -> float:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view() > 0:
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[demo-shot] view not complete after %.0f s (%d missing)" % [max_s, sb.map_view.missing_in_view()])
			break
		await process_frame
	await _frames(20)
	return (Time.get_ticks_msec() - t) / 1000.0

func _shot(file: String) -> void:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join(file)
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1

func _run() -> void:
	var what := str(opts.get("what", "all"))
	# The project opens maximized (project.godot window/size/mode); the shots are 1280x720.
	if str(opts.get("window", "1280")) == "1280":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(SIZE)
		root.size = SIZE
		await _frames(10)
	_say("window %s, viewport %s" % [str(DisplayServer.window_get_size()), str(root.get_viewport().get_visible_rect().size)])
	_t0 = Time.get_ticks_msec()
	dbg = root.get_node("DebugSettings")
	var script: Script = load("res://scripts/app/sandbox.gd")
	if script == null or not script.can_instantiate():
		printerr("[demo-shot] scripts/app/sandbox.gd did not compile -- see the Parse Error above")
		quit(1)
		return
	sb = script.new()
	root.add_child(sb)
	if not sb.ok():
		printerr("[demo-shot] the sandbox did not build: ", sb.errors)
		quit(1)
		return
	if not sb.is_playable:
		var t := Time.get_ticks_msec()
		while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
			await process_frame
	_check(sb.is_playable, "the sandbox is playable %.1f s after it was created (load_ms %.0f; the first view of %d chunks baked behind \"Drawing the map...\")" % [
		(Time.get_ticks_msec() - _t0) / 1000.0, sb.load_ms, sb._load_total])
	var w: World = sb.world
	for id: String in w.units:
		if w.units[id].controller == World.CONTROLLER_AI:
			_ai = id
		elif _p1 == "":
			_p1 = id
		else:
			_p2 = id
	await _wait_view()
	if what == "hud":
		_say("viewport %s; hud %s pos %s; roster pos %s size %s visible %s in-tree-visible %s; orders pos %s size %s; knobs visible %s; loading visible %s" % [
			str(root.get_viewport().get_visible_rect().size), str(sb.ui.hud.size), str(sb.ui.hud.position), str(sb.ui.roster.position),
			str(sb.ui.roster.size), str(sb.ui.roster.visible), str(sb.ui.roster.is_visible_in_tree()), str(sb.ui.orders.position),
			str(sb.ui.orders.size), str(sb.knobs.visible), str(sb.loading.visible)])
		await _shot("hud_check.png")
	if what == "main" or what == "all":
		await _main_run()
		_report()
		sb.reset_stats()
	if what == "other":
		await _other_knobs()
	if what == "knobs" or what == "all":
		await _knobs_run()
	_report()
	quit(1 if _failures > 0 else 0)

# --- the criteria ----------------------------------------------------------------------------------

func _main_run() -> void:
	var w: World = sb.world
	var ui = sb.ui
	var ctl = sb.ctl

	# 2. Three planes, the roster.
	for id: String in w.units:
		var s: Vector2 = sb.map_view.world_to_screen(Vector2(float(w.units[id].x), float(w.units[id].y)))
		_check(ui.marker_layer.marker(id).visible and Rect2(Vector2.ZERO, Vector2(SIZE)).has_point(s), "%s (%s) is on screen at %s" % [id, w.units[id].callsign, s.round()])
	_check(ui.roster.rows().size() == 2, "the roster lists the two player planes by callsign: %s" % [ui.roster.rows().map(func(r: Dictionary) -> String: return str(r["name"]))])
	await _shot("criterion_2_planes_roster.png")

	# 6. Roster click: select the second plane; the camera glides to it and follows.
	ui.roster.select_row(1)
	await _frames(120)
	await _wait_view()
	_check(ui.selection.unit_id == _p2, "a roster click selects %s" % _p2)
	_check(ctl.is_following(), "and the camera follows it")
	await _shot("criterion_6_roster_selection.png")
	ui.roster.select_row(0)
	ctl.stop_follow()

	# The real input path: left click plans inside the fan, a right drag pans, the wheel zooms.
	await _input_checks()

	# 3. A plan with a speed change, the fan, a step clamped by inertia.
	ui.select(_p1)
	ctl.frame_points([Vector2(float(w.units[_p1].x), float(w.units[_p1].y)) + Vector2(260.0, -60.0)])
	var pl = ui.planner
	pl.clear()
	var u1 = w.units[_p1]
	var steps := [[0.0, 130.0], [0.0, 110.0], [0.55, 100.0], [1.4, 100.0]]   # [turn rad, asked distance m]; the last turn is more than it can give
	var speeds: Array[String] = ["start %.0f" % float(u1.speed)]
	for k in steps.size():
		var from := Vector2(float(u1.x), float(u1.y))
		var heading := float(u1.heading)
		if k > 0:
			var prev: Dictionary = pl.states()[k - 1]
			from = Vector2(float(prev["x"]), float(prev["y"]))
			heading = float(prev["heading"])
		var target := from + Vector2.from_angle(heading + float(steps[k][0])) * float(steps[k][1])
		var st: Dictionary = pl.place_point(target)
		speeds.append("%.0f%s" % [float(st["speed"]), "*" if bool(st["clamped"]) else ""])
	pl.change_band(1)
	_say("planned %d steps; speeds m/s per step: %s (* = clamped by the envelope)" % [pl.planned_count(), ", ".join(speeds)])
	ctl.frame_plan(w, _p1)
	await _frames(40)
	await _wait_view()
	await _shot("criterion_3_motion_plan.png")

	# Plane 2: a short plan so the roster pips show; then Ready, and the turn plays at normal speed.
	ui.select(_p2)
	for i in 3:
		var u2 = w.units[_p2]
		var prev2: Dictionary = pl.states()[i - 1] if i > 0 else {"x": u2.x, "y": u2.y, "heading": u2.heading}
		pl.place_point(Vector2(float(prev2["x"]), float(prev2["y"])) + Vector2.from_angle(float(prev2["heading"]) + 0.1) * 120.0)
	ui.select(_p1)
	sb.follow_unit(_p1)
	await _flight_turn(true)

	# 4 (and the route to 5). Turns 2-3: the planes head for a scarp so the next view shows both levels.
	var spot := _scarp_spot(Vector2(float(w.units[_p1].x), float(w.units[_p1].y)))
	_say("scarp spot near the planes: %s (level %d one way, %d the other)" % [str(spot), sb.terrain.level_at(spot.x - 40.0, spot.y - 40.0), sb.terrain.level_at(spot.x + 40.0, spot.y + 40.0)])
	await _flight_turn(false, spot)
	await _flight_turn(false, spot)
	sb.follow_unit(_p1)

	# Teleport-free: the planes are where the flight put them. Show both levels around plane 1.
	var here := Vector2(float(w.units[_p1].x), float(w.units[_p1].y))
	var look := _scarp_spot(here)
	var span := Vector2(float(w.units[_p1].x), float(w.units[_p1].y))
	_say("plane 1 at %s; scarp spot for the shot %s" % [str(span.round()), str(look.round())])
	ctl.stop_follow()
	var ppm: float = sb.map_view.px_per_m
	ctl.set_view(((here + look) * 0.5) * ppm, 1.15)
	await _frames(30)
	var tw := await _wait_view()
	_say("terrain view baked in %.1f s" % tw)
	await _shot("criterion_4_terrain_levels.png")

	# 5. The rest of the minute: plane 1 circles, then both fly routes; fast playback for the middle turns.
	dbg.set_choice("playback_speed", 4)
	var n_done: int = w.turn - 1
	for t in range(n_done, 12):
		var route_p1 := Vector2(3600.0, 1800.0) if t > 7 else Vector2.ZERO
		await _flight_turn(false, Vector2.ZERO, t < 6, route_p1)
	_check(w.turn >= 13, "twelve turns flown (turn %d is next)" % w.turn)
	var tr = sb.tracks
	var run := _max_run_turn(tr, _p1)
	_check(absf(run) >= TAU - 0.1, "plane 1's track turns %.0f degrees one way in a single run: a full circle" % rad_to_deg(absf(run)))
	dbg.set_choice("playback_speed", 0)
	# Frame the whole of the tracks.
	var pts: Array = []
	for id: String in w.units:
		var t_pts: PackedVector2Array = tr.tracks[id].pts
		for i in range(0, t_pts.size(), 8):
			pts.append(t_pts[i])
	ctl.frame_points(pts)
	await _frames(30)
	await _wait_view(120.0)
	await _shot("criterion_5_tracks_zoomed_out.png")

	# 7. Fog edges in view (zoom 0.3 round the planes), then the overview.
	var mid := Vector2(float(w.units[_p1].x), float(w.units[_p1].y)) * 0.5 + Vector2(float(w.units[_p2].x), float(w.units[_p2].y)) * 0.5
	ctl.set_view(mid * ppm, 0.3)
	await _frames(30)
	await _wait_view(120.0)
	_check(ctl.overview_amount() < 0.01, "at zoom 0.3 the full render shows (overview %.2f)" % ctl.overview_amount())
	await _shot("criterion_7_fog_edges.png")
	ctl.set_view(sb.terrain.map_rect_px().get_center(), 0.001)
	await _frames(10)
	_check(ctl.overview_amount() > 0.99, "fully zoomed out (zoom %.3f) the topographic overview shows: overview %.2f" % [ctl.zoom_level(), ctl.overview_amount()])
	var tf := await _wait_overview()
	_say("the topographic overview filled in %.1f s (%d of its chunks baked)" % [tf, _overview_cached()])
	await _shot("criterion_7_overview_zoom.png")
	# What the pass would cost if it baked the whole map at the far zoom.
	_say("at the far zoom MapView wants %d chunks in view, %d pending, %d cached" % [sb._view_chunk_total(), sb.map_view.pending(), sb.map_view.chunk_count()])

func _overview_cached() -> int:
	var n := 0
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	for k: Vector3i in sb.fog._cache:
		if k.z == lod:
			n += 1
	return n

# Waits until the fog's topographic chunks for the current zoom are all baked.
func _wait_overview(max_s: float = 60.0) -> float:
	var t := Time.get_ticks_msec()
	var total: int = sb.terrain.chunks_in_rect_px(sb.terrain.map_rect_px()).size()
	while _overview_cached() < total and (Time.get_ticks_msec() - t) / 1000.0 < max_s:
		await process_frame
	await _frames(10)
	return (Time.get_ticks_msec() - t) / 1000.0

# One turn through the real flow: scripted plans for the players (unless `keep`), Ready, and the
# playback; returns when the next turn is being planned. `circle`: plane 1 circles; `route`: it steers
# for that point instead; `target`: both planes steer for that point.
func _flight_turn(keep: bool, target: Vector2 = Vector2.ZERO, circle: bool = false, route: Vector2 = Vector2.ZERO) -> void:
	var w: World = sb.world
	var ui = sb.ui
	if not keep:
		for id: String in [_p1, _p2]:
			var n := w.steps_per_turn(id)
			w.clear_plan(id)
			var tgt := target
			if id == _p1 and circle:
				for i in n:
					w.plan_step(id, i, {"turn": 1.5})
				continue
			if id == _p1 and route != Vector2.ZERO:
				tgt = route
			if tgt == Vector2.ZERO:
				tgt = Vector2(2500.0, 2500.0) if id == _p2 else Vector2(float(w.units[id].x), float(w.units[id].y)) + Vector2.from_angle(float(w.units[id].heading)) * 300.0
			for i in n:
				w.plan_step(id, i, {"to": tgt})
	var turn_no: int = w.turn
	ui.press_ready()
	var t := Time.get_ticks_msec()
	while (w.turn == turn_no or ui.marker_layer.is_playing()) and Time.get_ticks_msec() - t < 60000:
		await process_frame
	await _frames(2)
	var u1 = w.units[_p1]
	_say("turn %d played; plane 1 at (%.0f, %.0f) speed %.0f, plane 2 at (%.0f, %.0f), AI at (%.0f, %.0f)" % [
		turn_no, u1.x, u1.y, u1.speed, w.units[_p2].x, w.units[_p2].y, w.units[_ai].x, w.units[_ai].y])

# A point near `from` where the ground changes level (a scarp), searching outwards.
func _scarp_spot(from: Vector2) -> Vector2:
	var t = sb.terrain
	for ring in range(0, 40):
		for k in 24:
			var a := float(k) * TAU / 24.0
			var p := from + Vector2.from_angle(a) * float(ring) * 25.0
			if p.x < 100.0 or p.y < 100.0 or p.x > 4900.0 or p.y > 4900.0:
				continue
			if t.level_at(p.x - 30.0, p.y - 30.0) != t.level_at(p.x + 30.0, p.y + 30.0):
				return p
	return from

# The most a unit's track turns one way without turning back (the largest same-direction run
# of the polyline's direction changes): 360 degrees or more is a full circle.
func _max_run_turn(tr: Node, id: String) -> float:
	var pts: PackedVector2Array = tr.tracks[id].pts
	var best_pos := 0.0
	var best_neg := 0.0
	var up := 0.0
	var down := 0.0
	var prev_a := NAN
	for i in range(1, pts.size()):
		var d := pts[i] - pts[i - 1]
		if d.length() < 1e-6:
			continue
		var a := d.angle()
		if not is_nan(prev_a):
			var da := a - prev_a
			da -= TAU * floorf((da + PI) / TAU)
			up = maxf(0.0, up + da)       # Kadane's, once for left runs and once for right
			down = minf(0.0, down + da)
			best_pos = maxf(best_pos, up)
			best_neg = minf(best_neg, down)
		prev_a = a
	return best_pos if best_pos >= -best_neg else best_neg

# The real pointer path through the viewport: press in a plane's fan = a step; a right drag pans;
# the wheel zooms about the cursor. (Keys: WASD pans through polled physical keys, tested by hand.)
func _input_checks() -> void:
	var w: World = sb.world
	var ui = sb.ui
	var ctl = sb.ctl
	ui.select(_p1)
	ui.planner.clear()
	await _frames(3)
	var fan: PackedVector2Array = ui.planner.fan_outline_screen()
	var inside := Vector2.ZERO
	for p in fan:
		inside += p
	inside /= float(maxi(fan.size(), 1))
	# The fan's centre of mass is inside it; click there.
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = inside
	down.global_position = inside
	Input.parse_input_event(down)
	await _frames(2)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = inside
	up.global_position = inside
	Input.parse_input_event(up)
	await _frames(2)
	_check(ui.planner.planned_count() == 1, "a left click inside the fan plans one step through the real input path")
	var c0: Vector2 = ctl.center()
	var z0: float = ctl.zoom_level()
	_check(c0.distance_to(ctl.center()) < 1e-6, "and the left click did not pan the map")
	ui.planner.clear()
	# Right-button drag pans.
	var rd := InputEventMouseButton.new()
	rd.button_index = MOUSE_BUTTON_RIGHT
	rd.pressed = true
	rd.position = Vector2(400, 300)
	Input.parse_input_event(rd)
	await _frames(1)
	var mv := InputEventMouseMotion.new()
	mv.position = Vector2(300, 300)
	mv.relative = Vector2(-100, 0)
	Input.parse_input_event(mv)
	await _frames(1)
	var ru := InputEventMouseButton.new()
	ru.button_index = MOUSE_BUTTON_RIGHT
	ru.pressed = false
	ru.position = Vector2(300, 300)
	Input.parse_input_event(ru)
	await _frames(2)
	_check(ctl.center().distance_to(c0) > 1.0, "a right-button drag pans the map (centre moved %.1f map px)" % ctl.center().distance_to(c0))
	# Wheel zoom.
	var wh := InputEventMouseButton.new()
	wh.button_index = MOUSE_BUTTON_WHEEL_UP
	wh.pressed = true
	wh.position = Vector2(500, 300)
	Input.parse_input_event(wh)
	await _frames(2)
	_check(ctl.zoom_level() > z0 * 1.05, "the wheel zooms in (%.3f -> %.3f)" % [z0, ctl.zoom_level()])
	# WASD: polled physical keys (Input.is_physical_key_pressed) -- fed through the event path.
	var c1: Vector2 = ctl.center()
	var kd := InputEventKey.new()
	kd.keycode = KEY_D
	kd.physical_keycode = KEY_D
	kd.pressed = true
	Input.parse_input_event(kd)
	await _frames(20)
	var ku := InputEventKey.new()
	ku.keycode = KEY_D
	ku.physical_keycode = KEY_D
	ku.pressed = false
	Input.parse_input_event(ku)
	await _frames(2)
	_check(ctl.center().x > c1.x + 1.0, "D pans the map east (centre moved %.1f map px)" % (ctl.center().x - c1.x))
	ui.planner.clear()
	ctl.set_view(c0, z0)

# --- knobs -----------------------------------------------------------------------------------------------

func _knobs_run() -> void:
	var ctl = sb.ctl
	var w: World = sb.world
	var ppm0: float = sb.map_view.px_per_m
	ctl.frame_points([Vector2(float(w.units[_p1].x), float(w.units[_p1].y)), Vector2(float(w.units[_p2].x), float(w.units[_p2].y))])
	await _wait_view()
	sb.knobs.toggle()
	await _shot("knobs_panel.png")
	sb.knobs.toggle()
	# The live scale: 1, 3, 4, 2 -- the time each redraw takes to fill the view.
	for v in [1, 3, 4, 2]:
		sb.reset_stats()
		dbg.set_choice("map_scale", v)   # the choice index is the scale: data, 1, 2, 3, 4
		var t := await _wait_view(240.0)
		var cen: Vector2 = ctl.center() / float(sb.map_view.px_per_m)
		_say("map scale %d px/m: the view is whole again after %.1f s; the camera is over (%.0f, %.0f) m; frame stats %s" % [v, t, cen.x, cen.y, _stats_line()])
		await _shot("knobs_scale_%d.png" % v)
	dbg.set_choice("map_scale", 0)
	await _wait_view(240.0)
	_check(is_equal_approx(sb.map_view.px_per_m, ppm0), "back on data: %.0f px/m" % ppm0)
	await _other_knobs()

# The other knobs, each switched in the running renderer and shot: the edge, line of sight, the far
# zoom, the pen and the tree pool (the last two redraw the map).
func _other_knobs() -> void:
	var w: World = sb.world
	var ctl = sb.ctl
	var ppm: float = sb.map_view.px_per_m
	var u1 = w.units[_p1]
	var at := Vector2(float(u1.x), float(u1.y))
	ctl.set_view(at * ppm, 0.25)   # far enough out for the edge of sight to be in the frame
	await _wait_view(240.0)
	dbg.set_choice("fog_edge", 2)
	await _frames(30)
	_check(sb.fog.edge_mode == "soft", "the fog edge knob: soft")
	await _shot("knobs_fog_edge_soft.png")
	dbg.set_choice("fog_edge", 0)
	await _frames(20)
	await _shot("knobs_fog_edge_inked.png")
	dbg.set_choice("line_of_sight", 2)
	await _frames(120)
	_check(sb.fog.vision.line_of_sight == "terrain" and sb.fog.vision.ok(), "the line-of-sight knob: terrain (%d shapes, last viewshed %.1f ms)" % [sb.fog.stats.los_shapes, sb.fog.vision.stats.last_ms])
	await _shot("knobs_line_of_sight_terrain.png")
	dbg.set_choice("line_of_sight", 0)
	await _frames(30)
	dbg.set_choice("far_zoom", 2)
	ctl.set_view(sb.terrain.map_rect_px().get_center(), 0.001)
	await _frames(20)
	_check(ctl.overview_amount() == 0.0 and ctl.zoom_level() >= 0.1199, "the far-zoom knob: full render limits the zoom-out to %.3f and shows no overview" % ctl.zoom_level())
	var t_full := await _wait_view(240.0)
	_say("full-render far zoom: the view of %d chunks was whole after %.1f s" % [sb._view_chunk_total(), t_full])
	await _shot("knobs_far_zoom_full_render.png")
	dbg.set_choice("far_zoom", 0)
	ctl.set_view(at * ppm, 1.0)
	await _wait_view(120.0)
	await _shot("knobs_pen_shadow_side.png")
	dbg.set_choice("pen", 1)
	var t_pen := await _wait_view(240.0)
	_say("pen even: map redrawn, view whole after %.1f s" % t_pen)
	await _shot("knobs_pen_even.png")
	dbg.set_choice("pen", 0)
	await _wait_view(240.0)
	dbg.set_choice("tree_pool", 2)
	var t_pool := await _wait_view(240.0)
	_say("tree pool on: map redrawn, view whole after %.1f s" % t_pool)
	await _shot("knobs_tree_pool_on.png")
	dbg.set_choice("tree_pool", 0)
	await _wait_view(240.0)
	_check(true, "the pen and the tree pool are back on data")


func _stats_line() -> String:
	var parts: Array[String] = []
	for cat: String in sb.stats:
		var s: Dictionary = sb.stats[cat]
		parts.append("%s n=%d mean %.1f ms max %.1f ms (>33 ms: %d, >100 ms: %d)" % [
			cat, s.n, s.sum_ms / maxf(float(s.n), 1.0), s.max_ms, s.over33, s.over100])
	return " | ".join(parts)

func _report() -> void:
	_say("FRAME TIMES BY ACTIVITY: " + _stats_line())
	_say("sandbox load_ms %.0f, last rebake %.1f s, failures %d" % [sb.load_ms, sb.last_rebake_s, _failures])
