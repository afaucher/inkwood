extends SceneTree

# SMOKE, MADE CONSISTENT, IN THE RUNNING BUILD (builder SMOKE, 2026-10-11; decisions smoke-consistency and impact-by-round-and-target; the audit is
# docs/proposals/smoke-audit.md). WINDOWED ONLY -- under --headless nothing is drawn (scripts/tests/test_smoke_consistency.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/smoke_shot.gd -- [out=tmp/smoke] [window=1600x900]
#
# Starts Hold the bridge as the menu does (the Main scene, the scenario knob on the bridge mission, the Local button), hurts the first tank and the
# bridge to half their pips, plays three turns through the REAL turn flow, and saves a PNG per moment at the window's NATIVE size:
#
#   00_before_bridge_disc.png     what Alex saw: the damage smoke sized by the bridge's 40 m length, under every marker (reproduced by calling the layer
#                                 with the old arguments; the tank's own smoke is the new one)
#   01_bridge_hit_no_smoke.png    the bridge at 7 of 14 pips, as hurt as the tank beside it: no smoke at all (damage_smoke.enabled false)
#   02_tank_smoke_above.png       the damaged tank close: its smoke from the small engine-deck source, over the tank and its shadow, leaning downwind
#   03_damaged_plane.png          a damaged fighter flying over that tank's smoke: its trail under it, the tank's smoke under both
#   04_bomb_in_water.png          a bomb and a cruiser shell that land in the river (a splash of ink rings, no smoke, no crater) beside a bomb on land
#                                 (the blast, the smoke, the crater)

const World = preload("res://scripts/sim/world.gd")

const BRIDGE_IDX := 4   # the scenario knob's index of "bridge"
const BRIDGE := "bridge_1"
const TANK1 := "tank_1"
const TANK2 := "tank_2"
const FIGHTER := "smoke_fighter"

var out_dir := "tmp/smoke"
var opts: Dictionary = {}
var size := Vector2i(1600, 900)
var main: Node = null
var sb: Node = null
var _failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[smoke-shot] needs a windowed run: under --headless nothing is drawn")
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
	print("[smoke-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[smoke-shot] FAIL  " + msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[smoke-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(12)

func _shot(file: String) -> void:
	await _frames(2)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join(file)
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
	return true

func _ring(at: Vector2, r: float) -> Array:
	var pts: Array = []
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		pts.append(at + corner * r)
	return pts

func _look(pts: Array, max_zoom: float) -> void:
	sb.ui.selection.clear()
	sb.ctl.frame_max_zoom = max_zoom
	sb.ctl.frame_points(pts)
	sb.ctl.stop_follow()
	await _wait_view()

func _pos(id: String) -> Vector2:
	return Vector2(float(sb.world.units[id].x), float(sb.world.units[id].y))

func _planning(turn_no: int) -> bool:
	return sb.world.phase == World.PHASE_PLANNING and not sb.ui.is_playing() and sb.world.turn == turn_no

# One turn through the real flow: Ready, the resolve, the playback to its end.
func _play_turn() -> void:
	var turn_no: int = sb.world.turn
	var ok := await _until(func() -> bool: return _planning(turn_no), 180000)
	_check(ok, "turn %d is being planned" % turn_no)
	sb.ui.press_ready()
	var start := Time.get_ticks_msec()
	while (sb.world.turn == turn_no or sb.ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
		await process_frame
	await _frames(2)

# The nearest point to `near_pt` (within 20 to `max_r` m of it) whose water is at least `min_depth` deep, or whose depth is 0 (a dry point) with `dry`.
func _find(near_pt: Vector2, lo_r: float, max_r: float, min_depth: float, dry: bool) -> Vector2:
	var w: World = sb.world
	var r := lo_r
	while r <= max_r:
		for k in 48:
			var p := near_pt + Vector2.from_angle(float(k) / 48.0 * TAU) * r
			var d: float = w.water_depth_at(p.x, p.y)
			if (dry and d <= 0.0) or (not dry and d >= min_depth):
				return p
		r += 5.0
	return Vector2(NAN, NAN)

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	root.get_node("DebugSettings").set_choice("scenario", BRIDGE_IDX)
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[smoke-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable and sb.scenario.id == "bridge", "Hold the bridge is playable (load_ms %.0f)" % sb.load_ms)
	var w: World = sb.world
	var ui = sb.ui
	var fx = ui.fx
	sb.scenario.view["result_card_delay_s"] = 9999.0
	_check(fx.air_node.get_parent() == ui.marker_layer.smoke_slot(), "the smoke is mounted in the marker layer's smoke slot")
	var bridge := _pos(BRIDGE)
	var bheading := float(w.units[BRIDGE].heading)
	var tank1 := _pos(TANK1)
	var tdir := Vector2.from_angle(float(w.units[TANK1].heading))   # tank 1 faces the bridge
	_say("the bridge at %s (heading %.2f), tank 1 at %s facing %.2f, %d pips of %d; the bridge %d of %d" % [str(bridge), bheading, str(tank1),
		float(w.units[TANK1].heading), int(w.units[TANK1].health), int(w.units[TANK1].def.health), int(w.units[BRIDGE].health), int(w.units[BRIDGE].def.health)])

	# the tank and the bridge are half hurt: the shown health is the one the turn finds (UiHealth snapshots when planning starts)
	w.units[TANK1].health = 3
	w.units[BRIDGE].health = 7
	ui.health.snapshot()
	var close_pts: Array = _ring(bridge, 75.0)
	close_pts.append_array(_ring(tank1, 30.0))
	close_pts.append_array(_ring(_pos(TANK2), 20.0))
	await _look(close_pts, 2.0)
	await _play_turn()
	await _play_turn()
	await _look(close_pts, 2.0)
	var smoking := {}
	for p: Dictionary in fx.field.puffs:
		smoking[p["unit"]] = int(smoking.get(p["unit"], 0)) + 1
	_check(not smoking.has(BRIDGE), "the bridge, at 7 of 14, has left no puff of smoke (puffs by unit: %s)" % str(smoking))
	_check(int(smoking.get(TANK1, 0)) > 10, "tank 1, at half, smokes (%d puffs)" % int(smoking.get(TANK1, 0)))
	await _shot("01_bridge_hit_no_smoke.png")

	# what Alex saw: the same layer called as the feed used to call it, with the bridge's 40 m length, under every marker
	var now: float = ui.game_time()
	var sampler := func(_tg: float) -> Dictionary: return {"x": bridge.x, "y": bridge.y, "height_m": 0.0, "heading": bheading}
	fx.air_node.reparent(fx, false)
	fx.emit_path("old_bridge", sampler, now - 12.0, now, 0.5, float(w.units[BRIDGE].def.size_m))
	fx.queue_redraws()
	await _frames(6)
	await _shot("00_before_bridge_disc.png")
	for k in range(fx.field.puffs.size() - 1, -1, -1):
		if str(fx.field.puffs[k]["unit"]) == "old_bridge":
			fx.field.puffs.remove_at(k)
	fx.mount_smoke(ui.marker_layer.smoke_slot())
	fx.queue_redraws()

	await _look(_ring(tank1, 16.0), 3.0)
	await _shot("02_tank_smoke_above.png")

	# a damaged fighter flies over that tank's smoke along the road, low
	var fstart := tank1 - tdir * 340.0
	var fid: String = w.add_unit({"id": FIGHTER, "type": "light_fighter", "side": str(w.units[TANK1].side), "controller": "player", "x": fstart.x, "y": fstart.y,
		"heading": float(w.units[TANK1].heading), "speed": 85.0, "altitude_band": "low"})
	_check(fid == FIGHTER, "the fighter is added: %s" % w.last_error)
	w.units[FIGHTER].health = 1
	ui.marker_layer.sync_units()
	ui.health.snapshot()
	var plane_pts: Array = _ring(tank1 - tdir * 20.0, 55.0)
	plane_pts.append_array(_ring(tank1 + tdir * 60.0, 40.0))
	await _look(plane_pts, 1.8)
	var turn_no: int = w.turn
	var ok := await _until(func() -> bool: return _planning(turn_no), 180000)
	_check(ok, "turn %d is being planned" % turn_no)
	ui.press_ready()
	var shot_taken := false
	var start := Time.get_ticks_msec()
	while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
		await process_frame
		if not shot_taken and ui.is_playing() and ui.playback_time() >= 4.05:
			shot_taken = true
			await _shot("03_damaged_plane.png")
			_say("the fighter at %s at %.2f s, tank 1 at %s" % [str(_pos(FIGHTER)), ui.playback_time(), str(_pos(TANK1))])
	_check(shot_taken, "the damaged-plane shot was taken during the playback")
	await _frames(2)

	# a bomb and a shell in the river, a bomb on land
	var turn_after: int = w.turn
	ok = await _until(func() -> bool: return _planning(turn_after), 180000)
	var wet := _find(bridge, 25.0, 140.0, 4.0, false)
	_check(is_finite(wet.x), "water at least 4 m deep found near the bridge: %s (%.1f m)" % [str(wet), w.water_depth_at(wet.x, wet.y)])
	var wet2 := _find(wet + Vector2(34.0, 18.0), 0.0, 60.0, 4.0, false)
	var dry := _find(wet + Vector2(0.0, 60.0), 40.0, 160.0, 0.0, true)
	_check(is_finite(dry.x), "dry ground found beside it: %s" % str(dry))
	var tn := turn_after - 1
	var feed = ui.feed
	feed.on_event({"type": "bomb_impact", "unit": TANK1, "turn": tn, "t": 3.7, "x": wet.x, "y": wet.y, "blast_m": 45.0, "drop_index": 0, "bomb": 0})
	if is_finite(wet2.x):
		feed.on_event({"type": "shell_impact", "unit": TANK1, "turn": tn, "t": 3.9, "x": wet2.x, "y": wet2.y, "blast_m": 20.0, "step": 0, "shell": 0})
	feed.on_event({"type": "bomb_impact", "unit": TANK1, "turn": tn, "t": 3.7, "x": dry.x, "y": dry.y, "blast_m": 45.0, "drop_index": 1, "bomb": 0})
	var c: Dictionary = fx.stats()
	_say("effects after the three impacts: %s; splashes %d; craters %d" % [str(c), fx.field.splashes.size(), fx.field.craters.size()])
	_check(fx.field.splashes.size() == (2 if is_finite(wet2.x) else 1) and fx.field.craters.size() == 1, "two splashes (bomb and shell) in the river, one crater on land")
	await _look([wet + Vector2(-90.0, -60.0), wet + Vector2(90.0, 120.0), dry + Vector2(-50.0, 50.0)], 2.2)
	await _shot("04_bomb_in_water.png")

	_say("failures %d" % _failures)
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)
