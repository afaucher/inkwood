extends SceneTree

# HOLD THE BRIDGE, IN THE RUNNING BUILD (Track BM, 2026-10-11). WINDOWED ONLY -- under --headless nothing is drawn
# (scripts/tests/test_bridge_mission.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/bridge_shot.gd -- [out=tmp/bridge_mission] [window=1600x900] [seed=N]
#
# Starts the game as the menu does (the Main scene, the scenario knob on the bridge mission, the Local button) and plays it through the REAL turn flow
# (Ready, the host-side resolve, the markers' playback) with the cruiser run by the scripted defence (scripts/test_support/bridge_play.gd: it fires the
# Main Guns at what the tanks spot, and creeps the ship nearer; the tanks hold and shoot on their own), saving a PNG per moment at the window's NATIVE size:
#
#   00_menu.png              the menu with the scenario selector on HOLD THE BRIDGE
#   01_opening.png           the opening view as the game frames it: the two tanks, the cruiser at the far end of its range, the bridge's ring
#   01b_the_bridge.png       the same, close: the two tanks on the road, the bridge, the first wave forming on the road beyond it
#   02_wave_arriving.png     a wave on the road near the bridge, the planning phase before it arrives
#   03_fire_planned.png      the cruiser selected with its Main Guns set on a wave tank: the card, the target, the spread
#   04_salvo_falling.png     the cruiser's salvo landing near the bridge
#   05_result_card.png       the end-of-mission card
#
# WHICH SEED. The dice are PROPOSED numbers, so no seed is written down: the script first plays the scripted defence headless in-process over seeds
# 1..SEED_SEARCH (the same World, the same plans, so the same result) and takes the first that WINS; `seed=N` forces one (`lose=1`: the first that
# LOSES by the bridge going down, to show that card). That simulation also says which turn a wave is near the bridge and where and when the first salvo
# lands, so the camera is put there before the turn plays.

const World = preload("res://scripts/sim/world.gd")
const BridgePlay = preload("res://scripts/test_support/bridge_play.gd")

const SEED_SEARCH := 40
const BRIDGE_IDX := 4
const SHIP := "cruiser_1"
const BRIDGE := "bridge_1"
const TANK1 := "tank_1"
const WAVE_NEAR_M := 170.0

var out_dir := "tmp/bridge_mission"
var opts: Dictionary = {}
var size := Vector2i(1600, 900)
var main: Node = null
var sb: Node = null
var dbg: Node = null
var _failures := 0
var _frame_no := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[bridge-shot] needs a windowed run: under --headless nothing is drawn")
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
		_frame_no += 1

func _say(msg: String) -> void:
	print("[bridge-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[bridge-shot] FAIL  " + msg)

func _wait_view(max_s: float = 90.0) -> float:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[bridge-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(12)
	return (Time.get_ticks_msec() - t) / 1000.0

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

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
		_frame_no += 1
	return true

func _ring(at: Vector2, r: float) -> Array:
	var pts: Array = []
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		pts.append(at + corner * r)
	return pts

# --- The seed, from a headless run of the same game ---------------------------------------------------------------

# What the simulation says about a seed's run: its result, the first turn a wave tank stands within WAVE_NEAR_M of the bridge at the START of the
# turn (the planning phase before it arrives), and the first of the cruiser's salvos that lands within 150 m of the bridge (its turn, time and place).
func _knowledge(g: RefCounted, s: int, r: Dictionary) -> Dictionary:
	var info := {"seed": s, "state": str(r["state"]), "reason": str(r["reason"]), "end_turn": int(r["turn"]), "near_turn": 99, "fire": {}, "impact": {}, "near_impact": {}}
	var bridge: Vector2 = g.bridge_pos()
	for snap: Dictionary in g.snaps:
		for id: String in g.ENEMIES:
			var su: Dictionary = (snap["units"] as Dictionary)[id]
			if not bool(su["down"]) and Vector2(float(su["x"]), float(su["y"])).distance_to(bridge) < WAVE_NEAR_M and int(snap["turn"]) + 1 < int(info["near_turn"]):
				info["near_turn"] = int(snap["turn"]) + 1
	for ev: Dictionary in g.events:
		var t := str(ev["type"])
		if t == "shell_fire" and info["fire"].is_empty():
			info["fire"] = ev
		elif t == "shell_impact":
			if info["impact"].is_empty():
				info["impact"] = ev
			if info["near_impact"].is_empty() and Vector2(float(ev["x"]), float(ev["y"])).distance_to(bridge) < 150.0:
				info["near_impact"] = ev
	return info

func _pick_seed() -> Dictionary:
	var forced := int(opts.get("seed", -1))
	var want_loss := str(opts.get("lose", "")) == "1"
	var seeds: Array = [forced] if forced >= 0 else range(1, SEED_SEARCH + 1)
	var first: Dictionary = {}
	for s: int in seeds:
		var g := BridgePlay.new(s)
		var r: Dictionary = g.play("defend", 30)
		var ok: bool = (str(r["state"]) == "lost" and str(r["reason"]).contains("bridge_1")) if want_loss else str(r["state"]) == "won"
		if not ok and forced < 0:
			continue
		var info := _knowledge(g, s, r)
		if first.is_empty():
			first = info
		if not info["near_impact"].is_empty() and int(info["near_turn"]) < 90:
			return info
	return first

# --- The run -----------------------------------------------------------------------------------------------------

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	dbg = root.get_node("DebugSettings")
	dbg.set_choice("scenario", BRIDGE_IDX)
	_say("the scenario knob says: %s" % dbg.get_choice_name("scenario"))
	var t_sim := Time.get_ticks_msec()
	var info := _pick_seed()
	if info.is_empty():
		printerr("[bridge-shot] no seed in 1..%d gave the game asked for: nothing to show" % SEED_SEARCH)
		quit(1)
		return
	var ni: Dictionary = info["near_impact"]
	_say("seed %d: the run %s on turn %d (%s; found in %.1f s of headless play); a wave is near the bridge from turn %d; the first salvo fires in turn %s and a shell lands near the bridge in turn %s at t=%.1f" % [
		int(info["seed"]), str(info["state"]), int(info["end_turn"]), str(info["reason"]), (Time.get_ticks_msec() - t_sim) / 1000.0, int(info["near_turn"]),
		str(info["fire"].get("turn", "none")), str(ni.get("turn", "none")), float(ni.get("t", 0.0))])

	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	await _shot("00_menu.png")
	if not main.start_sandbox():
		printerr("[bridge-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable, "Hold the bridge is playable (load_ms %.0f)" % sb.load_ms)
	_check(sb.scenario.id == "bridge", "Local started the bridge mission")
	var w: World = sb.world
	w.rng_seed = int(info["seed"])
	sb.scenario.view["result_card_delay_s"] = 9999.0   # the card waits for its own shot
	var planner = BridgePlay.for_world(w)
	var ui = sb.ui
	var bridge := Vector2(float(w.units[BRIDGE].x), float(w.units[BRIDGE].y))
	await _wait_view()
	await _shot("01_opening.png")
	# the same, close
	ui.selection.clear()
	sb.ctl.frame_max_zoom = 1.6
	var close_pts: Array = _ring(bridge, 120.0)
	close_pts.append_array(_ring(Vector2(float(w.units["tank_e1"].x), float(w.units["tank_e1"].y)), 60.0))
	sb.ctl.frame_points(close_pts)
	sb.ctl.stop_follow()
	await _wait_view()
	await _shot("01b_the_bridge.png")

	var done := {"arriving": false, "fire": false, "salvo": false}
	var impact_turn := int(ni.get("turn", 99))
	var impact_t := float(ni.get("t", 0.0))
	var impact_at := Vector2(float(ni.get("x", 0.0)), float(ni.get("y", 0.0)))
	for turn_no in range(1, int(info["end_turn"]) + 3):
		var ok := await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == turn_no), 180000)
		if not ok:
			printerr("[bridge-shot] turn %d never came" % turn_no)
			_failures += 1
			break
		if sb.result_decided():
			break
		var focus: Array = []
		# a wave on the road near the bridge, before it arrives
		if not done["arriving"] and turn_no >= int(info["near_turn"]):
			done["arriving"] = true
			ui.selection.clear()
			var lead := Vector2.ZERO
			var lead_d := INF
			for id: String in planner.ENEMIES:
				var eu = w.units[id]
				if eu.down:
					continue
				var d := Vector2(float(eu.x), float(eu.y)).distance_to(bridge)
				if d < lead_d:
					lead_d = d
					lead = Vector2(float(eu.x), float(eu.y))
			var pts: Array = _ring(bridge, 90.0)
			pts.append_array(_ring(lead, 80.0))
			sb.ctl.frame_max_zoom = 1.4
			sb.ctl.frame_points(pts)
			sb.ctl.stop_follow()
			await _wait_view()
			await _shot("02_wave_arriving.png")
			_say("a wave arrives: turn %d, its lead %.0f m from the bridge" % [turn_no, lead_d])
		planner.plan_players()
		# the cruiser's guns set on a wave tank: the card and the spread
		if not done["fire"] and planner.salvos > 0:
			done["fire"] = true
			var fire_target := str(planner._target)
			ui.select(SHIP)
			ui.set_target_unit(fire_target)   # the card and the side view show the target (a change of selection clears it)
			var tgt = w.units.get(fire_target)
			var fpts: Array = _ring(bridge, 90.0)
			if tgt != null:
				fpts.append_array(_ring(Vector2(float(tgt.x), float(tgt.y)), 70.0))
			sb.ctl.frame_max_zoom = 1.4
			sb.ctl.frame_points(fpts)
			sb.ctl.stop_follow()
			await _wait_view()
			await _shot("03_fire_planned.png")
			_say("the guns are set on %s (turn %d)" % [fire_target, turn_no])
			ui.selection.clear()
		# the camera for the turn: round the first shell to land near the bridge
		if not done["salvo"] and turn_no == impact_turn:
			focus = _ring(impact_at, 70.0)
			focus.append_array(_ring(bridge, 70.0))
			sb.ctl.frame_max_zoom = 1.6
			sb.ctl.frame_points(focus)
			sb.ctl.stop_follow()
			await _wait_view()
		var shoot_salvo: bool = not done["salvo"] and turn_no == impact_turn
		ui.press_ready()
		var start := Time.get_ticks_msec()
		while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
			await process_frame
			_frame_no += 1
			if shoot_salvo and not done["salvo"] and ui.is_playing() and ui.playback_time() >= impact_t + 0.35:
				done["salvo"] = true
				await _shot("04_salvo_falling.png")
				_say("a shell lands near the bridge: playback at %.1f s (it lands at %.1f s), %d shells in flight" % [ui.playback_time(), impact_t, w.shells_in_flight.size()])
		await _frames(2)
		if sb.result_decided():
			break
	sb.scenario.view["result_card_delay_s"] = 0.1
	var shown := await _until(func() -> bool: return sb.result_card_shown(), 30000)
	_check(shown and ui.result_card != null and ui.result_card.is_showing(), "the result card is up: %s" % str(sb.result))
	await _frames(20)
	await _shot("05_result_card.png")
	_check(done["arriving"], "the wave-arriving shot was taken")
	_check(done["fire"], "the fire-planned shot was taken")
	_check(done["salvo"], "the salvo-falling shot was taken")
	_say("failures %d" % _failures)
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)
