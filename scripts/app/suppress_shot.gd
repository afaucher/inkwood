extends SceneTree

# SUPPRESS, IN THE RUNNING BUILD (Track M2L, 2026-10-11). WINDOWED ONLY -- under --headless nothing is drawn
# (scripts/tests/test_suppress.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/suppress_shot.gd -- [out=tmp/suppress] [window=1600x900] [seed=N]
#
# Starts the game as the menu does (the Main scene, the scenario knob on Suppress, the Local button) and plays it through the REAL turn
# flow (Ready, the host-side resolve, the markers' playback) with the players flown by the scripted bombing run
# (scripts/test_support/suppress_play.gd, coming down to the low band at once, where the mobile guns reach), saving a PNG per moment at the
# window's NATIVE size:
#
#   00_menu.png              the menu with the scenario selector on Suppress
#   01_opening.png           the opening view: the players, the complex's ring, the village's side of the map
#   02_gun_revealed.png      a gun the moment it fires at a plane: the patch of fog it opens, its marker, the fire
#   02b_after_the_shot.png   the planning phase after it: the gun still marked, the open patch
#   02c_last_seen.png        later, the gun gone from its place: the fading "last seen" ring (when a turn shows one)
#   03_bombers_run.png       the bomber's stick in the air over the complex
#
# `ring=1` plays a different game for ONE picture: the planes come down to the low band on turn 1 and then fly on with no orders, the guns fire
# at them as they pass and scoot, and the shot is 02c_last_seen.png, the fading ring where a gun was (with `sight=0.3`, so that the planes'
# sight does not cover the guns). It stops there.
#   04_result_card.png       the end-of-mission card
#
# WHICH SEED. The dice are PROPOSED numbers, so no seed is written down: the script first plays the scripted run headless in-process over
# seeds 1..SEED_SEARCH (the same World, the same plans, so the same result) and takes the first that WINS; `seed=N` forces one. That
# simulation also says which turn a gun first fires in and where, so the camera is put there before the turn plays.

const World = preload("res://scripts/sim/world.gd")
const SuppressPlay = preload("res://scripts/test_support/suppress_play.gd")
const Reveal = preload("res://scripts/sim/reveal.gd")

const SEED_SEARCH := 40
const SUPPRESS_IDX := 3
const BOMBER := "bomber_1"
const COMPLEX := "military_complex_1"
const GUNS := ["mobile_aa_1", "mobile_aa_2", "mobile_aa_3"]

var out_dir := "tmp/suppress"
var opts: Dictionary = {}
var size := Vector2i(1600, 900)
var main: Node = null
var sb: Node = null
var dbg: Node = null
var _failures := 0
var _events: Array = []
var _frame_no := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[suppress-shot] needs a windowed run: under --headless nothing is drawn")
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
	print("[suppress-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[suppress-shot] FAIL  " + msg)

func _wait_view(max_s: float = 90.0) -> float:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[suppress-shot] view not complete after %.0f s" % max_s)
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

# --- The seed, from a headless run of the same game -------------------------------------------------------------

func _knowledge(g: RefCounted, s: int, r: Dictionary) -> Dictionary:
	var info := {"seed": s, "state": str(r["state"]), "win_turn": int(r["turn"]), "gun_fire": {}, "release": {}}
	for ev: Dictionary in g.events:
		var t := str(ev["type"])
		if t == "fire" and GUNS.has(str(ev.get("unit", ""))) and info["gun_fire"].is_empty():
			info["gun_fire"] = ev
		elif t == "bomb_release" and info["release"].is_empty():
			info["release"] = ev
	return info

func _pick_seed() -> Dictionary:
	var forced := int(opts.get("seed", -1))
	var seeds: Array = [forced] if forced >= 0 else range(1, SEED_SEARCH + 1)
	var first_win: Dictionary = {}
	for s: int in seeds:
		var g := SuppressPlay.new(s)
		g.dive_band = "low"
		var r: Dictionary = g.play("bomb", 30)
		if str(r["state"]) != "won" and forced < 0:
			continue
		var info := _knowledge(g, s, r)
		if first_win.is_empty():
			first_win = info
		if not info["gun_fire"].is_empty() and not info["release"].is_empty():
			return info
	return first_win

# --- The run ---------------------------------------------------------------------------------------------------------

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	dbg = root.get_node("DebugSettings")
	dbg.set_choice("scenario", SUPPRESS_IDX)
	_say("the scenario knob says: %s (the units: %s)" % [dbg.get_choice_name("scenario"), "stand-ins" if SuppressPlay.standin() else "the units track's files"])
	if SuppressPlay.standin():
		printerr("[suppress-shot] the units track's files (mobile_aa, military_complex) are not there: the sandbox needs the real ones")
		quit(1)
		return

	var t_sim := Time.get_ticks_msec()
	var info := _pick_seed()
	if info.is_empty():
		printerr("[suppress-shot] no seed in 1..%d won the scripted run: nothing to show" % SEED_SEARCH)
		quit(1)
		return
	var gf: Dictionary = info["gun_fire"]
	_say("seed %d: the run %s on turn %d (found in %.1f s of headless play); a gun first fires in turn %s (%s at %.0f, %.0f), first release turn %s" % [
		int(info["seed"]), str(info["state"]), int(info["win_turn"]), (Time.get_ticks_msec() - t_sim) / 1000.0,
		str(gf.get("turn", "none")), str(gf.get("unit", "")), float(gf.get("x", 0.0)), float(gf.get("y", 0.0)), str(info["release"].get("turn", "none"))])

	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	await _shot("00_menu.png")
	if not main.start_sandbox():
		printerr("[suppress-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable, "Suppress is playable (load_ms %.0f)" % sb.load_ms)
	_check(sb.scenario.id == "suppress", "Local started Suppress")
	# 'sight=0.3': the fog's sight scale (data/view/fog.json vision.sight_range_scale). The units track's mobile AA reach 384 m and a plane sees 800 m,
	# so at the data's sight every gun that can fire at a plane is already in its sight and the reveal changes little; a shorter sight shows what
	# the rule does for a gun that fires from outside it.
	if float(opts.get("sight", 1.0)) != 1.0:
		sb.fog.vision.sight_scale = float(opts["sight"])
		_say("the fog's sight scale is %.2f" % sb.fog.vision.sight_scale)
	var w: World = sb.world
	w.rng_seed = int(info["seed"])
	sb.scenario.view["result_card_delay_s"] = 9999.0   # the card waits for its own shot
	var planner = SuppressPlay.for_world(w)
	planner.dive_band = "low"
	var ui = sb.ui
	ui.playback_event.connect(func(ev: Dictionary) -> void: _events.append({"ev": ev, "frame": _frame_no}))
	await _wait_view()
	await _shot("01_opening.png")

	var rv = Reveal.of(w)
	var ring_mode := str(opts.get("ring", "")) == "1"
	var done := {"gun": false, "after": false, "ghost": false, "run": false}
	if ring_mode:
		done["gun"] = true
		done["after"] = true
		done["run"] = true
	var gun_turn := int(gf.get("turn", 99))
	var gun_at := Vector2(float(gf.get("x", 0.0)), float(gf.get("y", 0.0)))
	for turn_no in range(1, 24 if ring_mode else int(info["win_turn"]) + 3):
		var ok := await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == turn_no), 180000)
		if not ok:
			printerr("[suppress-shot] turn %d never came" % turn_no)
			_failures += 1
			break
		if sb.result_decided():
			break
		# The planning phase after the shot: the gun is marked, the fog open on it.
		if done["gun"] and not done["after"]:
			var live: Array = rv.marks("allies", rv.now_s(w))
			if not live.is_empty():
				done["after"] = true
				var m: Dictionary = live[0]
				ui.selection.clear()
				sb.ctl.frame_max_zoom = 1.6
				sb.ctl.frame_points(_ring(Vector2(float(m["x"]), float(m["y"])), 330.0))
				sb.ctl.stop_follow()
				await _wait_view()
				await _shot("02b_after_the_shot.png")
				_say("after the shot: %d mark(s), %d ring(s) drawn, %s revealed" % [live.size(), sb.reveal_marks.rings().size(), str(live[0]["unit"])])
		# The 'last seen' ring: a gun that is no longer where it fired from.
		if done["gun"] and not done["ghost"] and not sb.reveal_marks.rings().is_empty():
			done["ghost"] = true
			var ring: Dictionary = sb.reveal_marks.rings()[0]
			var gu = w.units[str(ring["unit"])]
			ui.selection.clear()
			sb.ctl.frame_max_zoom = 1.6
			var pts: Array = _ring(Vector2(float(gu.x), float(gu.y)), 330.0)
			for mk: Dictionary in sb.fog.vision.reveal_list:
				if str(mk["unit"]) == str(ring["unit"]):
					pts.append_array(_ring(Vector2(float(mk["x"]), float(mk["y"])), 120.0))
			sb.ctl.frame_points(pts)
			sb.ctl.stop_follow()
			await _wait_view()
			await _shot("02c_last_seen.png")
			_say("a 'last seen' ring for %s, alpha %.2f" % [str(ring["unit"]), float(ring["alpha"])])
			if ring_mode:
				main.stop_sandbox()
				quit(1 if _failures > 0 else 0)
				return
		if ring_mode:
			if turn_no == 1:
				planner.plan_players()   # (turn 1: the dive to the low band, and the run the planes would make; later turns carry on)
		else:
			planner.plan_players()
		# The camera for this turn.
		var focus: Array = []
		if not done["gun"] and turn_no == gun_turn:
			focus = _ring(gun_at, 420.0)
			sb.ctl.frame_max_zoom = 1.6
		else:
			var r_all: bool = turn_no >= int(info["win_turn"]) - 1
			for id: String in w.units:
				var u = w.units[id]
				if u.controller != World.CONTROLLER_PLAYER or u.down:
					continue
				if r_all and id != BOMBER:
					continue
				focus.append(Vector2(float(u.x), float(u.y)))
				for st: Dictionary in w.planned_states(id):
					focus.append(Vector2(float(st["x"]), float(st["y"])))
			if r_all:
				focus.append_array(_ring(Vector2(float(w.units[COMPLEX].x), float(w.units[COMPLEX].y)), 250.0))
			sb.ctl.frame_max_zoom = 1.0
		sb.ctl.frame_points(focus)
		sb.ctl.stop_follow()
		await _wait_view()
		_events.clear()
		var shot_gun: bool = not done["gun"] and turn_no == gun_turn
		var air_before := not w.bombs_in_flight.is_empty()
		ui.press_ready()
		var start := Time.get_ticks_msec()
		var gun_frame := -1
		var release_frame := -1
		while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
			await process_frame
			_frame_no += 1
			for e: Dictionary in _events:
				var ev: Dictionary = e["ev"]
				var ty := str(ev.get("type", ""))
				if ty == "fire" and GUNS.has(str(ev.get("unit", ""))) and gun_frame < 0:
					gun_frame = int(e["frame"])
				elif ty == "bomb_release" and release_frame < 0:
					release_frame = int(e["frame"])
			if shot_gun and gun_frame >= 0 and _frame_no - gun_frame >= 6 and not done["gun"]:
				done["gun"] = true
				await _shot("02_gun_revealed.png")
				_say("a gun fires: playback at %.1f s; revealed now: %s" % [ui.playback_time(), str(rv.marks("allies", rv.game_time(w.turn, ui.playback_time())).map(func(m: Dictionary) -> String: return str(m["unit"])))])
			# The stick in the air: close on the bomber, two seconds into a turn in which bombs are falling.
			var falling: bool = ui.is_playing() and ui.playback_time() >= 2.2 and (air_before or (release_frame >= 0 and _frame_no - release_frame >= 40))
			if not done["run"] and not shot_gun and falling:
				done["run"] = true
				var pose: Dictionary = ui.marker_layer.pose_of(BOMBER)
				sb.ctl.set_view(Vector2(float(pose["x"]), float(pose["y"])) * sb.map_view.px_per_m, 1.6)
				sb.follow_unit(BOMBER)
				await _frames(30)
				await _shot("03_bombers_run.png")
				_say("the bomber's run: playback at %.1f s, %d bombs in flight" % [ui.playback_time(), w.bombs_in_flight.size()])
				sb.ctl.stop_follow()
		await _frames(2)
		if sb.result_decided():
			break
	# The ruin and the card.
	sb.scenario.view["result_card_delay_s"] = 0.1
	var shown := await _until(func() -> bool: return sb.result_card_shown(), 30000)
	_check(shown and ui.result_card != null and ui.result_card.is_showing(), "the result card is up: %s" % str(sb.result))
	await _frames(20)
	await _shot("04_result_card.png")
	_check(done["gun"], "the gun-revealed shot was taken")
	_check(done["run"], "the bomber's-run shot was taken")
	_say("failures %d" % _failures)
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)
