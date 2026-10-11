extends SceneTree

# THE BOATS AND THE BRIDGE, IN THE RUNNING STRIKE (Track BB, 2026-10-11). WINDOWED ONLY -- under --headless nothing is drawn
# (scripts/tests/test_boats_live.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"; $env:INKWOOD_FOG = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/boats_live_shot.gd -- [out=tmp/boats_live] [window=1600x900]
#
# Starts the game as the menu does (the Main scene, the scenario knob on the Strike, the Local button: water on) and photographs, at the
# window's NATIVE size, the units the water layer added as the game draws them:
#
#   01_cutter_z1.png        the patrol boat on its loop (a light fighter beside it for the scale), zoom 1
#   02_cutter_plan.png      the same at the planning zoom 0.35
#   03_barge_z1.png         the supply boat on its route, zoom 1
#   04_barge_plan.png       the planning zoom
#   05_bridge_z1.png        the bridge at the road, zoom 1
#   06_bridge_plan.png      the bridge at the planning zoom
#   07_bridge_z2.png        the bridge at zoom 2 (the camera's closest)
#   08_bridge_ruin.png      the bridge destroyed (the world's wreck put back, as a late joiner sees it), zoom 1
#   09_bridge_ruin_plan.png the planning zoom
#
# THE SINKING (Alex, decision ship-sinks; the same Strike, a ship or a plane put below the surface by the sim's own fields -- fate and
# fall_height_m -- exactly as World._fall_step leaves them; what the screen shows is the marker's, the layer's and the effects layer's):
#
#   10_ship_half_sunk.png      a patrol boat halfway to the floor of deep water
#   11_ship_floor_deep.png     a patrol boat on the floor of deep water (zoom 1), 11b_ship_floor_deep_plan.png the planning zoom
#   12_ship_floor_shallows.png a patrol boat on the floor of the shallows
#   13_plane_floor.png         a light fighter on the floor of the shelf (7 to 16 m of water), 14_plane_floor_deep.png in deep water
#   15_ladder_deep.png         five patrol boats side by side in deep water at 0, 2, 5, 10 m under and on the floor (left to right)
#   16_ladder_shallows.png     four in the shallows at 0, 1, 2 m under and on the floor
#   17_splash.png              the standard down flash and the rings of the splash, 0.8 s old, over a boat going down
#
# `fog` is off for these shots (INKWOOD_FOG=off): the units are drawn wherever the camera looks.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")

var out_dir := "tmp/boats_live"
var opts: Dictionary = {}
var size := Vector2i(1600, 900)
var main: Node = null
var sb: Node = null
var _failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[boats-live] needs a windowed run: under --headless nothing is drawn")
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
	var win := str(opts.get("window", "1600x900")).split("x")
	if win.size() == 2:
		size = Vector2i(int(win[0]), int(win[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _say(msg: String) -> void:
	print("[boats-live] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[boats-live] FAIL  " + msg)

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0:
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[boats-live] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(16)

func _shot(file: String) -> void:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join(file)
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1

func _at(id: String) -> Vector2:
	var u = sb.world.units[id]
	return Vector2(float(u.x), float(u.y))

func _look(center: Vector2, zoom: float) -> void:
	sb.ui.selection.clear()
	sb.ctl.stop_follow()
	sb.ctl.set_view(center * float(sb.map_view.px_per_m), zoom)   # (the camera's centre is in map px)
	await _wait_view()

func _marker_report(id: String) -> void:
	var m = sb.ui.marker_layer.marker(id)
	if m == null:
		_failures += 1
		printerr("[boats-live] no marker for ", id)
		return
	_say("%s: art %s, wake %s (underway %s), screen %.2f px/m, shadow parts %d, map_scale %s" % [id, str(m.has_art()), str(m.art != null and m.art.wake != null),
		str(m.underway), m.screen_ppm, m.art.shadow_parts.size() if m.art != null else -1, str(m.map_scale)])

func _destroy(id: String) -> void:
	var u = sb.world.units[id]
	u.health = 0
	u.down = true
	u.fate = Unit.FATE_DESTROYED
	u.down_at = NAN
	sb.ui.marker_layer.update_poses()
	var n: int = sb.ui.restore_wrecks(true)   # a late joiner's wrecks: every destroyed unit's ruin comes back from the world
	_say("%s destroyed: %d wreck(s) put back" % [id, n])

# The nearest point to `near_pt` whose water is between lo and hi metres deep along `run_m` metres of x (for a row of boats).
func _find_water(near_pt: Vector2, lo: float, hi: float, run_m: float) -> Vector2:
	var w: World = sb.world
	var best := Vector2(NAN, NAN)
	var best_d := INF
	for iy in range(-60, 61):
		for ix in range(-60, 61):
			var p := near_pt + Vector2(float(ix), float(iy)) * 50.0
			var d2 := p.distance_squared_to(near_pt)
			if d2 >= best_d:
				continue
			var ok := true
			var k := 0.0
			while k <= run_m:
				var dd: float = w.water_depth_at(p.x + k, p.y)
				if dd < lo or dd > hi:
					ok = false
					break
				k += 20.0
			if ok:
				best = p
				best_d = d2
	return best

# A unit of `type` put at `pos` in the water's state the sim leaves it in: height `h` metres (0 or below) with `floor_depth` of water under it.
func _put(id: String, type: String, pos: Vector2, h: float, floor_depth: float) -> void:
	var w: World = sb.world
	var side: String = str(w.units["patrol_boat_1"].side)
	if not w.units.has(id):
		# (spawned where the patrol boat floats, then moved: a sunk unit is not subject to the water rule for floating)
		var home := Vector2(float(w.units["patrol_boat_1"].x), float(w.units["patrol_boat_1"].y))
		var spec := {"id": id, "type": type, "side": side, "controller": "player", "x": home.x, "y": home.y, "heading": 0.0, "speed": 0.0}
		if type == "light_fighter":
			spec["altitude_band"] = "low"
		if w.add_unit(spec) == "":
			_check(false, "%s added: %s" % [id, w.last_error])
			return
	var u = w.units[id]
	u.x = pos.x
	u.y = pos.y
	if h < 0.0:
		u.health = 0
		u.down = true
		u.fate = Unit.FATE_CRASHED if h <= -floor_depth + 1e-6 else Unit.FATE_OUT_OF_CONTROL
		u.fall_height_m = h
		u.down_at = NAN
	sb.ui.marker_layer.sync_units()
	sb.ui.marker_layer.update_poses()

func _sinking(w: World, pb: Vector2, br: Vector2) -> void:
	var deep := _find_water(pb, 22.0, 400.0, 200.0)
	var shelf := _find_water(pb + Vector2(-500.0, 300.0), 7.0, 16.0, 60.0)
	var shallow := _find_water(br, 4.5, 5.9, 0.0)   # the top of the shallows step (0 to 6 m): the most water a hull in the shallows can have over it
	if not is_finite(shallow.x):
		shallow = _find_water(br, 2.0, 5.9, 0.0)
	_say("deep water at %s (%.1f m), the shelf at %s (%.1f m), the shallows at %s (%.1f m)" % [str(deep), w.water_depth_at(deep.x, deep.y),
		str(shelf), w.water_depth_at(shelf.x, shelf.y), str(shallow), w.water_depth_at(shallow.x, shallow.y)])
	_check(is_finite(deep.x) and is_finite(shelf.x) and is_finite(shallow.x), "the three kinds of water are found near the units")
	if _failures > 0:
		return
	var dd: float = w.water_depth_at(deep.x, deep.y)
	var ds: float = w.water_depth_at(shelf.x, shelf.y)
	var dh: float = w.water_depth_at(shallow.x, shallow.y)
	# a ship half-way down, then on the floor, in deep water
	_put("sunk_half", "patrol_boat", deep + Vector2(0.0, 0.0), -0.5 * dd, dd)
	await _look(deep, 1.0)
	_say("half sunk: sunk_amount %.3f" % sb.ui.marker_layer.marker("sunk_half").sunk_amount)
	await _shot("10_ship_half_sunk.png")
	_put("sunk_deep", "patrol_boat", deep + Vector2(60.0, 0.0), -dd, dd)
	await _look(deep + Vector2(60.0, 0.0), 1.0)
	var md = sb.ui.marker_layer.marker("sunk_deep")
	_say("on the floor of deep water (%.1f m): sunk_amount %.3f, wash %s (as 8-bit %s), material %s, amount uniform %s, modulate %s" % [dd, md.sunk_amount, str(md.sunk_color),
		str(md.sunk_color.to_html(false)), str(md.plane.material), str((md.plane.material as ShaderMaterial).get_shader_parameter("amount")) if md.plane.material != null else "-", str(md.plane.modulate)])
	await _shot("11_ship_floor_deep.png")
	await _look(deep + Vector2(60.0, 0.0), 0.35)
	await _shot("11b_ship_floor_deep_plan.png")
	_put("sunk_shallow", "patrol_boat", shallow, -dh, dh)
	await _look(shallow, 1.0)
	_say("on the floor of the shallows (%.1f m): sunk_amount %.3f" % [dh, sb.ui.marker_layer.marker("sunk_shallow").sunk_amount])
	await _shot("12_ship_floor_shallows.png")
	_put("sunk_plane", "light_fighter", shelf, -ds, ds)
	await _look(shelf, 1.0)
	_say("a plane on the floor of the shelf (%.1f m): sunk_amount %.3f" % [ds, sb.ui.marker_layer.marker("sunk_plane").sunk_amount])
	await _shot("13_plane_floor.png")
	_put("sunk_plane_deep", "light_fighter", deep + Vector2(0.0, 80.0), -dd, dd)
	await _look(deep + Vector2(0.0, 80.0), 1.0)
	await _shot("14_plane_floor_deep.png")
	# the ladders: the same boat at 0 m, then lower, then on the floor
	var deep_row := deep + Vector2(0.0, -200.0)
	var rows: Array = [_find_water(deep_row, 22.0, 400.0, 260.0), _find_water(shallow, 1.0, 5.9, 180.0)]
	if is_finite((rows[0] as Vector2).x):
		var o: Vector2 = rows[0]
		var d0: float = w.water_depth_at(o.x, o.y)
		var hs: Array = [0.0, -2.0, -5.0, -10.0, -d0]
		for i in hs.size():
			_put("ladder_d%d" % i, "patrol_boat", o + Vector2(60.0 * float(i), 0.0), float(hs[i]), d0)
		await _look(o + Vector2(120.0, 0.0), 1.0)
		await _shot("15_ladder_deep.png")
	else:
		_check(false, "a deep row was found")
	if is_finite((rows[1] as Vector2).x):
		var o: Vector2 = rows[1]
		var d1: float = w.water_depth_at(o.x, o.y)
		var hs: Array = [0.0, -1.0, -2.5, -d1]
		for i in hs.size():
			_put("ladder_s%d" % i, "patrol_boat", o + Vector2(60.0 * float(i), 0.0), float(hs[i]), d1)
		await _look(o + Vector2(90.0, 0.0), 1.0)
		await _shot("16_ladder_shallows.png")
	else:
		_check(false, "a shallow row was found")
	# the moment it goes down: the standard flash and the splash's rings, 0.8 s old, over a boat at the surface
	var fx = sb.ui.fx
	var at := deep + Vector2(0.0, 300.0)
	if w.water_depth_at(at.x, at.y) < 10.0:
		at = deep
	_put("going_down", "patrol_boat", at, 0.0, dd)
	var size_m: float = float(w.units["going_down"].def.size_m)
	fx.down_flash("going_down", at, sb.ui.game_time() - 0.8, size_m * 0.7)
	fx.splash("going_down", at, sb.ui.game_time() - 0.8, size_m)
	await _look(at, 1.0)
	await _frames(4)
	await _shot("17_splash.png")

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[boats-live] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable, "the Strike is playable")
	_check(sb.scenario.id == "strike", "Local started the Strike")
	var w: World = sb.world
	for id: String in ["patrol_boat_1", "supply_boat_1", "bridge_1"]:
		_check(w.units.has(id), "the Strike has %s (water on)" % id)
	if _failures > 0:
		quit(1)
		return
	if not opts.has("hud"):
		sb.ui.hud.visible = false   # the roster and the card cover a quarter of the picture: hud=1 keeps them
		sb.hint.visible = false
		sb.clock.visible = false
	# the boats are under way (their wakes are shown while they make way): the sim's speeds are the units' own
	_say("patrol boat speed %.1f, supply boat speed %.1f" % [float(w.units["patrol_boat_1"].speed), float(w.units["supply_boat_1"].speed)])
	var pb := _at("patrol_boat_1")
	var sup := _at("supply_boat_1")
	var br := _at("bridge_1")
	_say("patrol boat %s, supply boat %s, bridge %s heading %.2f rad" % [str(pb), str(sup), str(br), float(w.units["bridge_1"].heading)])
	await _look(pb, 1.0)
	await _marker_report("patrol_boat_1")
	await _shot("01_cutter_z1.png")
	await _look(pb, 0.35)
	await _shot("02_cutter_plan.png")
	await _look(sup, 1.0)
	await _marker_report("supply_boat_1")
	await _shot("03_barge_z1.png")
	await _look(sup, 0.35)
	await _shot("04_barge_plan.png")
	await _look(br, 1.0)
	await _marker_report("bridge_1")
	await _shot("05_bridge_z1.png")
	await _look(br, 0.35)
	await _shot("06_bridge_plan.png")
	await _look(br, 2.0)
	await _shot("07_bridge_z2.png")
	_destroy("bridge_1")
	await _look(br, 1.0)
	await _shot("08_bridge_ruin.png")
	await _look(br, 0.35)
	await _shot("09_bridge_ruin_plan.png")
	await _sinking(w, pb, br)
	sb.shutdown()
	await _frames(2)
	_say("done, %d failure(s)" % _failures)
	quit(1 if _failures > 0 else 0)
