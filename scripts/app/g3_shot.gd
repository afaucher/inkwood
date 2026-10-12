extends SceneTree

# GUNFIRE G3, LIVE, IN THE RUNNING BUILD (builder G3, 2026-10-12; decisions gunfire-looks (G3, the W1 soft puffs), round-model, damage-looks, and
# smoke-consistency (planes' trails climb)). WINDOWED ONLY -- under --headless nothing is drawn (scripts/tests/test_gunfire.gd and test_rounds.gd are the
# headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/g3_shot.gd -- part=bridge|strike|trail [out=tmp/g3] [window=1600x900]
#
# Every part starts the game as the menu does (the Main scene, the scenario knob, the Local button) and plays the REAL turn flow; the playback is
# FROZEN (Engine.time_scale 0) at a moment worth keeping, so the same instant is saved at more than one zoom (the map's chunks are baked while it waits).
# PNGs are at the window's native size.
#
#   part=bridge  HOLD THE BRIDGE (seed 55). The two wave tanks are moved up to the far bank (55 and 70 m past the bridge) so that the first turn is a duel
#                across the river; the cruiser's Main Guns are set on the first of them.
#                  duel_z1.0.png, duel_z3.0.png          the moment two or more muzzle puffs and an impact are live: the tanks' muzzle smoke and the
#                                                         impacts on the bridge, the ground and the river, at zoom 1.0 and 3.0
#                  duel_z3.0_<material>.png              the first moment an impact on metal / stone / earth / water is a little old (zoom 3.0)
#                  salvo_z1.6.png                        the cruiser's salvo leaving: six large muzzle puffs from its barrels
#   part=strike  THE STRIKE. The bomber is flown to the first flak battery: the battery's flak and light flak muzzle smoke (and the F2 bursts), zoom 1.0, 1.6
#   part=trail   a damaged fighter's trail, climbing at 4 m/s (now) and not (before Alex's answer, rise_mps 0), the same sky, the same wind (fog=off)

const World = preload("res://scripts/sim/world.gd")

const SCENARIO_BRIDGE := 4
const SCENARIO_STRIKE := 2
const BRIDGE := "bridge_1"
const TANK1 := "tank_1"
const TANK2 := "tank_2"
const SHIP := "cruiser_1"

var out_dir := "tmp/g3"
var opts: Dictionary = {}
var size := Vector2i(1600, 900)
var main: Node = null
var sb: Node = null
var _failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[g3-shot] needs a windowed run: under --headless nothing is drawn")
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
	print("[g3-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[g3-shot] FAIL  " + msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[g3-shot] view not complete after %.0f s" % max_s)
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

func _pos(id: String) -> Vector2:
	return Vector2(float(sb.world.units[id].x), float(sb.world.units[id].y))

func _planning(turn_no: int) -> bool:
	return sb.world.phase == World.PHASE_PLANNING and not sb.ui.is_playing() and sb.world.turn == turn_no

# The camera at `centre_m` (metres) and `zoom`, the map waited for.
func _view(centre_m: Vector2, zoom: float) -> void:
	sb.ui.selection.clear()
	sb.ctl.stop_follow()
	sb.ctl.set_view(centre_m * sb.ctl.px_per_m, zoom)
	await _wait_view()

func _start(scenario_idx: int, want_id: String) -> bool:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	root.get_node("DebugSettings").set_choice("scenario", scenario_idx)
	if str(opts.get("fog", "")) == "off":
		root.get_node("DebugSettings").set_choice("fog", 2)   # the fog layer off (a shot of smoke in the open sky)
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[g3-shot] Local did not start the sandbox")
		return false
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable and sb.scenario.id == want_id, "%s is playable (load_ms %.0f)" % [want_id, sb.load_ms])
	sb.scenario.view["result_card_delay_s"] = 9999.0
	return sb.is_playable

# The live records of the gunfire book at the layer's time.
func _live(kind: String = "") -> Array:
	var fx = sb.ui.fx
	var out: Array = []
	for r: Dictionary in fx.gunfire.records:
		if (kind == "" or str(r["kind"]) == kind) and fx.now >= float(r["t0"]) and fx.now <= fx.gunfire.end_of(r):
			out.append(r)
	return out

func _recent(kind: String, lo: float, hi: float) -> Array:
	var fx = sb.ui.fx
	var out: Array = []
	for r: Dictionary in _live(kind):
		var age: float = fx.now - float(r["t0"])
		if age >= lo and age <= hi:
			out.append(r)
	return out

func _freeze() -> void:
	Engine.time_scale = 0.0

func _thaw() -> void:
	Engine.time_scale = 1.0

func _run() -> void:
	var part := str(opts.get("part", "bridge"))
	match part:
		"bridge":
			await _bridge()
		"strike":
			await _strike()
		"trail":
			await _trail()
		_:
			printerr("[g3-shot] part is bridge, strike or trail")
			quit(1)
			return
	_thaw()
	_say("failures %d" % _failures)
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)

# --- Hold the bridge: the duel and the salvo ------------------------------------------------------------------------------------

func _bridge() -> void:
	if not await _start(SCENARIO_BRIDGE, "bridge"):
		quit(1)
		return
	var w: World = sb.world
	var ui = sb.ui
	var fx = ui.fx
	var bridge := _pos(BRIDGE)
	var tdir := Vector2.from_angle(float(w.units[TANK1].heading))   # tank 1 faces the bridge, so this points across it to the far bank
	var side := Vector2(-tdir.y, tdir.x)
	# the first wave on the far bank, facing the bridge and the player's tanks
	for k in 2:
		var id := "tank_e%d" % (k + 1)
		var p := bridge + tdir * (55.0 + 15.0 * float(k)) + side * (9.0 if k == 0 else -9.0)
		w.units[id].x = p.x
		w.units[id].y = p.y
		w.units[id].heading = tdir.angle() + PI
		w.units[id].speed = 0.0
	ui.marker_layer.sync_units()
	ui.health.snapshot()
	_say("the bridge at %s, the road runs %s; tank_1 at %s, tank_2 at %s, the first wave at %s and %s; the cruiser at %s" % [str(bridge), str(tdir), str(_pos(TANK1)), str(_pos(TANK2)), str(_pos("tank_e1")), str(_pos("tank_e2")), str(_pos(SHIP))])
	# the cruiser's Main Guns on the first wave tank
	var st: Dictionary = w.plan_step(SHIP, 0, {"fire": {"special": "main_guns", "target": {"unit": "tank_e1"}}})
	_check(not st.is_empty(), "the cruiser's Main Guns are planned on tank_e1 (%s)" % w.last_error)
	var centre := bridge + tdir * 5.0
	await _view(centre, 1.0)
	var turn_no: int = w.turn
	_check(await _until(func() -> bool: return _planning(turn_no), 180000), "turn %d is being planned" % turn_no)
	ui.press_ready()
	var got := {"duel": false, "salvo": false}
	var mats := {}
	var start := Time.get_ticks_msec()
	while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
		await process_frame
		if not ui.is_playing():
			continue
		# the moment: muzzles and impacts both live
		var muz := _recent("muzzle", 0.2, 1.2)
		var imp := _recent("impact", 0.15, 1.2)
		if not got["duel"] and muz.size() >= 2 and imp.size() >= 1:
			got["duel"] = true
			_freeze()
			_say("THE DUEL at playback %.2f s: %d muzzles, %d impacts live (%s)" % [ui.playback_time(), _live("muzzle").size(), _live("impact").size(), str(_live("impact").map(func(r: Dictionary) -> String: return "%s/%s" % [r["mat"], r["cls"]]))])
			await _shot("duel_z1.0.png")
			await _view(centre, 3.0)
			await _shot("duel_z3.0.png")
			await _view(centre, 1.0)
			_thaw()
		# each material the first time it is a little old
		for r: Dictionary in _recent("impact", 0.2, 0.9):
			var m := str(r["mat"])
			if not mats.has(m):
				mats[m] = true
				_freeze()
				var at: Vector2 = (r["centre"] as Vector2) + (r["off"] as Vector2) * fx.true_scale
				_say("an impact on %s at %s (shot %s, age %.2f s)" % [m, str(at), str(r["shot"]), fx.now - float(r["t0"])])
				await _view(at, 3.0)
				await _shot("duel_z3.0_%s.png" % m)
				await _view(centre, 1.0)
				_thaw()
				break
		# the salvo: six large muzzles from the cruiser's barrels
		if not got["salvo"]:
			var big := _recent("muzzle", 0.3, 2.0).filter(func(r: Dictionary) -> bool: return str(r["cls"]) == "large")
			if big.size() >= 3:
				got["salvo"] = true
				_freeze()
				_say("THE SALVO at playback %.2f s: %d large muzzles live; the ship at %s" % [ui.playback_time(), big.size(), str(_pos(SHIP))])
				await _view(_pos(SHIP), 1.6)
				await _shot("salvo_z1.6.png")
				await _view(_pos(SHIP), 0.6)
				await _shot("salvo_z0.6.png")
				await _view(centre, 1.0)
				_thaw()
	_check(got["duel"], "a moment with muzzles and impacts live was found in turn %d" % turn_no)
	_check(got["salvo"], "the cruiser's salvo was seen leaving")
	_say("impact materials seen in turn %d: %s; records now %d" % [turn_no, str(mats.keys()), fx.gunfire.records.size()])

# --- The Strike: the battery's flak -----------------------------------------------------------------------------------------------

func _strike() -> void:
	if not await _start(SCENARIO_STRIKE, "strike"):
		quit(1)
		return
	var w: World = sb.world
	var ui = sb.ui
	var fx = ui.fx
	var battery := ""
	for id: String in w.units:
		if str(w.units[id].def.id) == "anti_aircraft_battery":
			battery = id
			break
	_check(battery != "", "the Strike has a battery (%s)" % battery)
	var bat := _pos(battery)
	var bomber := ""
	for id: String in w.units:
		if str(w.units[id].def.id) == "bomber" and str(w.units[id].side) != str(w.units[battery].side):
			bomber = id
			break
	# the player's bomber, flown to 330 m west of the battery, heading east, at the speed it has
	var p := bat + Vector2(-330.0, 40.0)
	w.units[bomber].x = p.x
	w.units[bomber].y = p.y
	w.units[bomber].heading = 0.0
	ui.marker_layer.sync_units()
	ui.health.snapshot()
	_say("the battery %s at %s, the bomber %s flown to %s" % [battery, str(bat), bomber, str(p)])
	await _view(bat + Vector2(-150.0, 20.0), 1.0)
	var turn_no: int = w.turn
	_check(await _until(func() -> bool: return _planning(turn_no), 180000), "turn %d is being planned" % turn_no)
	ui.press_ready()
	var done := false
	var start := Time.get_ticks_msec()
	while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
		await process_frame
		if not ui.is_playing() or done:
			continue
		var muz := _recent("muzzle", 0.15, 1.5)
		if muz.size() >= 2:
			done = true
			_freeze()
			var classes := {}
			for r: Dictionary in _live("muzzle"):
				classes[str(r["cls"])] = int(classes.get(str(r["cls"]), 0)) + 1
			_say("THE BATTERY at playback %.2f s: muzzles live %s; flak bursts %d" % [ui.playback_time(), str(classes), fx.field.bursts.size()])
			await _shot("flak_z1.0.png")
			await _view(bat + Vector2(-60.0, 10.0), 1.6)
			await _shot("flak_z1.6.png")
			await _view(bat, 3.0)
			await _shot("flak_z3.0.png")
			_thaw()
	_check(done, "the battery's muzzle smoke was seen")

# --- A damaged plane's trail climbing ------------------------------------------------------------------------------------------------

func _trail() -> void:
	if not await _start(SCENARIO_STRIKE, "strike"):
		quit(1)
		return
	var w: World = sb.world
	var ui = sb.ui
	var fx = ui.fx
	# Two fighters of the player's with 1 pip left, flown side by side east in the coastal wind for five turns (25 s of trail): the HEAVY fighter smokes
	# as the data has it now (damage_smoke.rise_mps 4: Alex, decision smoke-consistency, "Yes to both"), the LIGHT fighter's rise is set to 0 for this
	# run only, as it was before. Both sources are 8 m, so only the climb differs; the same sky, the same wind.
	var lid := ""
	var hid := ""
	for uid: String in w.units:
		if str(w.units[uid].def.id) == "light_fighter" and lid == "":
			lid = uid
		if str(w.units[uid].def.id) == "heavy_fighter" and hid == "" and str(w.units[uid].side) == str(w.units[lid].side if lid != "" else ""):
			hid = uid
	_check(lid != "" and hid != "", "the Strike has a light fighter (%s) and a heavy fighter (%s) on one side" % [lid, hid])
	var light_smoke: Dictionary = w.units[lid].def.damage_smoke
	var saved_rise: float = float(light_smoke["rise_mps"])
	light_smoke["rise_mps"] = 0.0
	var heavy_rise := float((w.units[hid].def.damage_smoke as Dictionary)["rise_mps"])
	for pair: Array in [[lid, 3100.0], [hid, 3300.0]]:
		var id: String = pair[0]
		w.units[id].x = 900.0
		w.units[id].y = float(pair[1])
		w.units[id].heading = 0.0
		w.units[id].health = 1
		w.units[id].speed = 100.0
	ui.marker_layer.sync_units()
	ui.health.snapshot()
	fx.clear()
	await _view(Vector2(1900.0, 3200.0), 0.5)
	for k in 5:
		var turn_no: int = w.turn
		_check(await _until(func() -> bool: return _planning(turn_no), 180000), "turn %d is being planned" % turn_no)
		ui.press_ready()
		var start := Time.get_ticks_msec()
		while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
			await process_frame
		await _frames(2)
	var out := {}
	for pair: Array in [[lid, "light_fighter, rise_mps 0 (as it was)"], [hid, "heavy fighter, rise_mps %.0f (now)" % heavy_rise]]:
		var oldest := 0.0
		var top := 0.0
		var lean := 0.0
		var n := 0
		for pf: Dictionary in fx.field.puffs:
			if str(pf["unit"]) != str(pair[0]):
				continue
			var st: Dictionary = fx.field.puff_state(pf, fx.now)
			if bool(st.get("alive", false)):
				oldest = maxf(oldest, fx.now - float(pf["born"]))
				top = maxf(top, float(st["h"]))
				lean += ((st["pos"] as Vector2) - (pf["pos"] as Vector2)).length()
				n += 1
		lean = lean / maxf(float(n), 1.0)
		out[str(pair[0])] = {"oldest_s": oldest, "top_m": top, "lean_m": lean, "puffs": n}
		_say("%s: %d live puffs, the oldest %.1f s old and %.0f m up, drifted %.1f m on average" % [str(pair[1]), n, oldest, top, lean])
	var cl := CanvasLayer.new()
	cl.layer = 100
	root.add_child(cl)
	var lb := Label.new()
	var lo: Dictionary = out[lid]
	var hi: Dictionary = out[hid]
	lb.text = "TOP: the light fighter's trail with rise_mps 0 (before): oldest puff %.0f s old, %.0f m up, drifted %.0f m on average
BOTTOM: the heavy fighter's, rise_mps %.0f (now, Alex 'Yes to both'): oldest puff %.0f s old, %.0f m up, drifted %.0f m
Same source size (8 m), same wind; seen from above the climb is the longer lean downwind" % [
		float(lo["oldest_s"]), float(lo["top_m"]), float(lo["lean_m"]), heavy_rise, float(hi["oldest_s"]), float(hi["top_m"]), float(hi["lean_m"])]
	lb.add_theme_font_size_override("font_size", 17)
	lb.add_theme_color_override("font_color", Color(0.15, 0.1, 0.05))
	lb.position = Vector2(24.0, 64.0)
	var panel := Panel.new()
	panel.position = Vector2(16.0, 56.0)
	panel.size = Vector2(900.0, 150.0)
	var sbox := StyleBoxFlat.new()
	sbox.bg_color = Color(0.93, 0.89, 0.78, 0.92)
	panel.add_theme_stylebox_override("panel", sbox)
	cl.add_child(panel)
	cl.add_child(lb)
	await _view(Vector2(1500.0, 3200.0), 1.0)
	await _shot("trail_rising.png")
	cl.queue_free()
	light_smoke["rise_mps"] = saved_rise
	_check(float(hi["top_m"]) > float(lo["top_m"]) + 20.0, "the climbing trail's oldest puffs are higher than the level one's (%s)" % str(out))
	_check(float(hi["lean_m"]) > float(lo["lean_m"]), "...and have drifted further downwind (the wind picks up with height)")
