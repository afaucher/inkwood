extends SceneTree

# THE TANKS AT THE BRIDGE, IN THE RUNNING BUILD (Track TK2, 2026-10-11). WINDOWED ONLY -- under --headless nothing is drawn
# (scripts/tests/test_tank.gd and test_tank_ui.gd are the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/ui/tank_shot.gd -- [out=tmp/tanks] [window=1280x720]
#
# The Strike's map (its seed, water, village, road and bridge) with the Strike's units swapped for TANKS, by the scenario's own overrides
# (SandboxScenario.new("strike", false, {...}); nothing is written to data/scenarios): two player tanks on the road at the bridge and an
# enemy tank driving down the road to them under the AI's drive role (a wave: it starts at turn 2). Saved, at the window's size:
#
#   01_two_tanks_planning_zoom.png   the two tanks on the road at the bridge at the PLANNING zoom (the data's 0.35, 0.7 px a metre)
#   02_two_tanks_zoom_1.png          the same at zoom 1 (2 px a metre)
#   03_plan_and_fan.png              one tank selected, a step placed toward the bridge and the next step's fan, at zoom 2
#   04_fan_at_a_cliff.png            a tank beside the road 22 m from a height step: its fan stops at the step (the cliff rule)
#   05_fan_at_the_river.png          a tank beside the road short of the river: its fan stops at the water
#   06_after_the_turn.png            the turn played through the real flow (Ready, the host-side resolve, the playback): the tanks on the road
#   07_bridge_down_fan.png           the bridge destroyed: a tank on the road at the bank, and where its fan ends

const World = preload("res://scripts/sim/world.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")

var out_dir := "tmp/tanks"
var opts: Dictionary = {}
var size := Vector2i(1280, 720)
var sb: Node = null
var _failures := 0
var _frame_no := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[tank-shot] needs a windowed run: under --headless nothing is drawn")
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
	var win := str(opts.get("window", "1280x720")).split("x")
	if win.size() == 2:
		size = Vector2i(int(win[0]), int(win[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame
		_frame_no += 1

func _say(msg: String) -> void:
	print("[tank-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[tank-shot] FAIL  " + msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

# Waits until the map under the view is baked and so is the fog's topographic layer over it, then a few frames.
func _wait_view(max_s: float = 120.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[tank-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(14)

func _shot(file: String) -> void:
	await _frames(2)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join(file)
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1

# Looks at (metres) at a zoom.
func _look(at_m: Vector2, zoom: float) -> void:
	var ppm: float = sb.ctl.px_per_m
	sb.ctl.stop_follow()
	sb.ctl.set_view(at_m * ppm, zoom)

func _scenario_over() -> Dictionary:
	var a := TankWorlds.road(104)
	var b := TankWorlds.road(100)
	var e := TankWorlds.road(180)
	var to := TankWorlds.road(96)
	return {
		"units": [
			{"id": "tank_1", "type": "tank", "side": "side_a", "controller": "player", "callsign": "pool", "x": a.x, "y": a.y, "heading": TankWorlds.toward(104, 94), "speed": 8.0},
			{"id": "tank_2", "type": "tank", "side": "side_a", "controller": "player", "callsign": "pool", "x": b.x, "y": b.y, "heading": TankWorlds.toward(100, 94), "speed": 8.0},
			{"id": "tank_e1", "type": "tank", "side": "side_b", "controller": "ai", "callsign": "pool", "x": e.x, "y": e.y, "heading": TankWorlds.toward(180, 96), "speed": 0.0},
		],
		"water_units": [{"id": "bridge_1", "type": "bridge", "side": "side_a", "controller": "ai", "site": "water.bridge", "heading": "site"}],
		"water_assignments": {},
		"ai": {"kind": "pilot", "assignments": {"tank_e1": {"role": "drive", "to": [to.x, to.y], "start_turn": 2}}},
		"objective": {"unit": "tank_1", "radius_m": 60.0, "label": "BRIDGE"},
		"mission": {"id": "tank_look", "win": [{"type": "unit_down", "unit": "tank_e1"}], "lose": [{"type": "unit_down", "unit": "tank_1"}, {"type": "turn_limit", "turn": 60}]},
		"briefing": "TWO TANKS AT THE BRIDGE (Track TK2's look, not the mission).",
	}

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	var script: GDScript = load("res://scripts/app/sandbox.gd")
	sb = script.new("strike")
	sb.scenario = SandboxScenario.new("strike", false, _scenario_over())
	if not sb.scenario.ok():
		printerr("[tank-shot] the scenario does not read: ", sb.scenario.errors)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	root.add_child(sb)
	if not sb.ok():
		printerr("[tank-shot] the sandbox did not start: ", sb.errors)
		quit(1)
		return
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 300000:
		await process_frame
	_check(sb.is_playable, "the tanks' scenario is playable %.1f s after it was added" % ((Time.get_ticks_msec() - t0) / 1000.0))
	var w: World = sb.world
	_check(w.ground.has_queries() and w.has_water(), "the World has the ground and the water")
	var ui = sb.ui
	sb.scenario.view["result_card_delay_s"] = 9999.0
	var bridge := TankWorlds.bridge_site()["pos"] as Vector2

	# 01 / 02: the two tanks at the bridge, the planning zoom and zoom 1
	var mid := (TankWorlds.road(104) + TankWorlds.road(94)) * 0.5
	sb.ctl.frame_max_zoom = 1.0
	_look(mid, 0.35)
	await _wait_view()
	ui.selection.clear()
	await _shot("01_two_tanks_planning_zoom.png")
	_look(mid, 1.0)
	await _wait_view()
	await _shot("02_two_tanks_zoom_1.png")

	# 03: a plan and its fan (zoom 2, the closest the camera goes: a tank's step is 20 m)
	ui.select("tank_1")
	_look((TankWorlds.road(104) + TankWorlds.road(98)) * 0.5, 2.0)
	await _wait_view()
	var s1: Dictionary = ui.planner.place_point(TankWorlds.road(101))
	_say("step 1: %s" % str(s1))
	var sel_fan: PackedVector2Array = ui.planner.fan_outline_world()
	_check(sel_fan.size() >= 6, "the next step's fan is up (%d points)" % sel_fan.size())
	await _frames(6)
	await _shot("03_plan_and_fan.png")
	ui.planner.clear()

	# 04: a tank beside the road short of a height step: the fan stops at the step
	var u1 = w.units["tank_1"]
	var cliff := _find_run("level", 80.0, 170.0)
	if not cliff.is_empty():
		var start: Vector2 = (cliff["point"] as Vector2) + (cliff["dir"] as Vector2) * (float(cliff["d"]) - 22.0)
		u1.x = start.x
		u1.y = start.y
		u1.heading = float(cliff["heading"])
		u1.speed = 8.0
		ui.select("tank_1")
		_look(start + (cliff["dir"] as Vector2) * 8.0, 2.0)
		await _wait_view()
		var fan: PackedVector2Array = ui.planner.fan_outline_world()
		_say("the cliff fan: %d points, tank at %s, the step %.0f m ahead" % [fan.size(), str(start), 22.0])
		await _shot("04_fan_at_a_cliff.png")
	else:
		_check(false, "a height step within reach of the road was found")

	# 05: and short of the river
	var river := _find_run("water", 80.0, 170.0)
	if not river.is_empty():
		var start2: Vector2 = (river["point"] as Vector2) + (river["dir"] as Vector2) * (float(river["d"]) - 22.0)
		u1.x = start2.x
		u1.y = start2.y
		u1.heading = float(river["heading"])
		u1.speed = 8.0
		ui.select("tank_1")
		_look(start2 + (river["dir"] as Vector2) * 8.0, 2.0)
		await _wait_view()
		await _shot("05_fan_at_the_river.png")
	else:
		_check(false, "a river within reach of the road was found")

	# 07 (before the turn is played, while the tank is placed by hand): the bridge destroyed, a tank on the road at the bank
	var bank := TankWorlds.road(BRIDGE_ROAD + 4)
	u1.x = bank.x
	u1.y = bank.y
	u1.heading = TankWorlds.toward(BRIDGE_ROAD + 4, BRIDGE_ROAD)
	u1.speed = 5.0
	(w.units["bridge_1"] as Object).down = true
	(w.units["bridge_1"] as Object).fate = "destroyed"
	(w.units["bridge_1"] as Object).health = 0
	ui.select("tank_1")
	_look(bridge + Vector2(20.0, -6.0), 2.0)
	await _wait_view()
	var dfan: PackedVector2Array = ui.planner.fan_outline_world()
	var over_water := 0
	for p in dfan:
		if sb.water.depth_at(p.x, p.y) > 0.0:
			over_water += 1
	_check(over_water == 0, "with the bridge down no point of the fan is over the river (%d points)" % dfan.size())
	await _shot("07_bridge_down_fan.png")
	(w.units["bridge_1"] as Object).down = false
	(w.units["bridge_1"] as Object).fate = ""
	(w.units["bridge_1"] as Object).health = 10

	# 06: back on the road at the bridge, the turn played through the real flow
	var a := TankWorlds.road(104)
	u1.x = a.x
	u1.y = a.y
	u1.heading = TankWorlds.toward(104, 94)
	u1.speed = 0.0
	ui.select("tank_1")
	ui.planner.place_point(TankWorlds.road(100))
	ui.planner.place_point(TankWorlds.road(97))
	ui.selection.clear()
	_look(mid, 1.0)
	await _wait_view()
	ui.press_ready()
	var played := await _until(func() -> bool: return w.turn >= 2 and w.phase == World.PHASE_PLANNING and not ui.is_playing(), 90000)
	_check(played, "the turn resolved and played back through the real flow (turn %d, phase %s)" % [w.turn, w.phase])
	var u_after = w.units["tank_1"]
	_check(Vector2(u_after.x, u_after.y).distance_to(a) > 20.0, "the tank drove its planned steps (%.1f m)" % Vector2(u_after.x, u_after.y).distance_to(a))
	await _wait_view()
	await _shot("06_after_the_turn.png")
	_say("failures %d" % _failures)
	sb.queue_free()
	await _frames(4)
	quit(1 if _failures > 0 else 0)

const BRIDGE_ROAD := 94

func _until(cond: Callable, max_ms: int) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t > max_ms:
			return false
		await process_frame
		_frame_no += 1
	return true

# The first place along the road where a straight run to one side meets a height step ("level") or water first, between min_d and
# max_d metres from the road (the same search as test_tank.gd): {point, dir, heading, d}, or {}.
func _find_run(kind: String, min_d: float, max_d: float) -> Dictionary:
	var gm: RefCounted = TankWorlds.ground()
	var water: RefCounted = TankWorlds.water()
	var road: PackedVector2Array = gm.road
	for i in range(4, road.size() - 5, 3):
		var p := road[i]
		var tang := (road[i + 1] - road[i - 1]).normalized()
		for side: int in [1, -1]:
			var n: Vector2 = Vector2(-tang.y, tang.x) * float(side)
			var lv0: int = gm.level_at(p.x, p.y)
			var d := 24.0
			var first_level := INF
			var first_water := INF
			while d <= max_d + 40.0:
				var q: Vector2 = p + n * d
				if first_level == INF and gm.level_at(q.x, q.y) != lv0:
					first_level = d
				if first_water == INF and water.depth_at(q.x, q.y) > 0.0:
					first_water = d
				if first_level != INF or first_water != INF:
					break
				d += 2.0
			var hit := first_level if kind == "level" else first_water
			var other := first_water if kind == "level" else first_level
			if hit >= min_d and hit <= max_d and other == INF:
				return {"point": p, "dir": n, "heading": n.angle(), "d": hit}
	return {}
