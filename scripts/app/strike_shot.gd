extends SceneTree

# THE STRIKE, IN THE RUNNING BUILD (Track A2, 2026-10-10). WINDOWED ONLY -- under --headless nothing is
# drawn (scripts/tests/test_strike.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/strike_shot.gd -- [out=tmp/strike] [window=1920x1080] [seed=N]
#
# Starts the game exactly as the menu does (the Main scene, its menu, the Local button: scripts/app/main.gd,
# the Strike being the scenario knob's default) and plays it through the REAL turn flow (Ready, the host-side
# resolve, the markers' playback) with the players flown by the scripted bombing run
# (scripts/test_support/strike_play.gd), saving one PNG per moment at the window's NATIVE size:
#
#   00_menu.png              the menu with the scenario selector (Strike chosen)
#   01_opening.png           the opening view: the players, the target ring, the village's side of the map
#   02_village_in_sight.png  the village and the radio tower once a fighter has them in sight
#   03_drop_planned.png      the bomber's drop planned: the cone, the aim, the spread, the orders card
#   04_turn_flak.png         a turn playing back with the batteries' flak bursting
#   05_bombs_falling.png     the stick in the air
#   06_bomb_impacts.png      the bombs landing round the tower
#   07_tower_ruin.png        the tower's ruin, its crater and its smoke
#   08_result_card.png       the end-of-mission card
#   09_zoomed_out_tracks.png fully zoomed out: the whole map, the flown tracks, the sidebar clear of the map
#
# WHICH SEED. The dice are PROPOSED numbers, so no seed is written down: the script first PLAYS the scripted run
# headless in-process over seeds 1..SEED_SEARCH (the same World, the same plans, so the same result) and takes the
# first that WINS with the bomber hit by flak on the way (so the flak shot has a hit); `seed=N` forces one. That
# simulation also says which turn has the flak, the release, the impacts and the tower's fall, so the camera is put
# there before the turn plays. It prints what the report needs: the time from Local to the first playable frame, and
# the frame times by what the game was doing, over the fly-in and over the village.

const World = preload("res://scripts/sim/world.gd")
const StrikePlay = preload("res://scripts/test_support/strike_play.gd")

const SEED_SEARCH := 60
const BOMBER := "bomber_1"
const TOWER := "radio_tower_1"
const BATTERIES := ["aa_battery_1", "aa_battery_2"]

var out_dir := "tmp/strike"
var opts: Dictionary = {}
var size := Vector2i(1920, 1080)
var main: Node = null
var sb: Node = null
var dbg: Node = null
var _failures := 0
var _t0 := 0
var _events: Array = []           # [{ev, frame}] this turn's playback events as the UI fired them
var _frame_no := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[strike-shot] needs a windowed run: under --headless nothing is drawn")
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
		_frame_no += 1

func _say(msg: String) -> void:
	print("[strike-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[strike-shot] FAIL  " + msg)

# Waits until the map under the view is baked (the hidden chunks do not count) and so is the fog's
# topographic layer over it (no bake in flight, none still wanted), then a few frames.
func _wait_view(max_s: float = 90.0) -> float:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[strike-shot] view not complete after %.0f s (%d missing, fog busy %s)" % [max_s, sb.map_view.missing_in_view(true), str(_fog_busy())])
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

# --- The seed, from a headless run of the same game ---------------------------------------------------

# What the simulation says about a seed's run: its result, and the first of each thing the shots are about.
func _knowledge(g: RefCounted, s: int, r: Dictionary) -> Dictionary:
	var info := {"seed": s, "state": str(r["state"]), "win_turn": int(r["turn"]), "flak": {}, "flak_hit": {}, "release": {}, "impact": {}, "down": {},
		"flak_turn": 99, "flak_count": 0, "fall_turn": 99, "fall": {}}
	var per_turn: Dictionary = {}
	for ev: Dictionary in g.events:
		var t := str(ev["type"])
		if t == "fire" and str(ev.get("weapon", "")) == "flak":
			per_turn[int(ev["turn"])] = int(per_turn.get(int(ev["turn"]), 0)) + 1
			if info["flak"].is_empty():
				info["flak"] = ev
		elif t == "hit" and str(ev.get("weapon", "")) == "flak" and str(ev.get("unit", "")) == BOMBER and info["flak_hit"].is_empty():
			info["flak_hit"] = ev
		elif t == "bomb_release" and info["release"].is_empty():
			info["release"] = ev
		elif t == "bomb_impact" and info["impact"].is_empty():
			info["impact"] = ev
		elif t == "down" and str(ev.get("unit", "")) == TOWER and info["down"].is_empty():
			info["down"] = ev
	# The turn with the most flak rolls (before the end) is the flak shot's; a release in another turn is the falling bombs'.
	for k: int in per_turn:
		if int(per_turn[k]) > int(info["flak_count"]) or (int(per_turn[k]) == int(info["flak_count"]) and k < int(info["flak_turn"])):
			info["flak_count"] = int(per_turn[k])
			info["flak_turn"] = k
	for ev: Dictionary in g.events:
		if str(ev["type"]) == "bomb_release" and int(ev["turn"]) != int(info["flak_turn"]) and info["fall"].is_empty():
			info["fall"] = ev
			info["fall_turn"] = int(ev["turn"])
	return info

func _pick_seed() -> Dictionary:
	var first_win: Dictionary = {}
	var forced := int(opts.get("seed", -1))
	var seeds: Array = [forced] if forced >= 0 else range(1, SEED_SEARCH + 1)
	for s: int in seeds:
		var g := StrikePlay.new("strike", s)
		var r: Dictionary = g.play("bomb", 24)
		if str(r["state"]) != "won" and forced < 0:
			continue
		var info := _knowledge(g, s, r)
		if first_win.is_empty():
			first_win = info
		if not info["flak_hit"].is_empty() and not info["release"].is_empty() and not info["down"].is_empty():
			return info
	return first_win

# --- The run -------------------------------------------------------------------------------------------------

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	_say("window %s, viewport %s" % [str(DisplayServer.window_get_size()), str(root.get_viewport().get_visible_rect().size)])
	dbg = root.get_node("DebugSettings")
	_say("the scenario knob says: %s" % dbg.get_choice_name("scenario"))

	var t_sim := Time.get_ticks_msec()
	var info := _pick_seed()
	if info.is_empty():
		printerr("[strike-shot] no seed in 1..%d won the scripted run: nothing to show" % SEED_SEARCH)
		quit(1)
		return
	_say("seed %d: the run %s on turn %d (found in %.1f s of headless play); first flak turn %s, the most flak in turn %s (%d rolls), a flak hit on the bomber turn %s, first release turn %s t=%.1f, the falling-bombs shot in turn %s, first impact turn %s, the tower down turn %s" % [
		int(info["seed"]), str(info["state"]), int(info["win_turn"]), (Time.get_ticks_msec() - t_sim) / 1000.0,
		str(info["flak"].get("turn", "none")), str(info["flak_turn"]), int(info["flak_count"]), str(info["flak_hit"].get("turn", "none")), str(info["release"].get("turn", "none")),
		float(info["release"].get("t", 0.0)), str(info["fall_turn"]), str(info["impact"].get("turn", "none")), str(info["down"].get("turn", "none"))])

	# The menu, then Local: the game as a player starts it.
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	await _shot("00_menu.png")
	_t0 = Time.get_ticks_msec()
	if not main.start_sandbox():
		printerr("[strike-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable, "the Strike is playable %.1f s after Local (load_ms %.0f; building the parts %.0f ms; the first view of %d chunks baked behind \"Drawing the map...\")" % [
		(Time.get_ticks_msec() - _t0) / 1000.0, sb.load_ms, sb.build_ms, sb._load_total])
	_check(sb.scenario.id == "strike", "Local started the Strike")
	var w: World = sb.world
	w.rng_seed = int(info["seed"])
	sb.scenario.view["result_card_delay_s"] = 9999.0   # the card waits for its own shot
	var planner = StrikePlay.for_world(w)
	var ui = sb.ui
	ui.playback_event.connect(func(ev: Dictionary) -> void: _events.append({"ev": ev, "frame": _frame_no}))
	await _wait_view()
	await _shot("01_opening.png")
	sb.reset_stats()

	var done := {"village": false, "drop": false, "flak": false, "falling": false, "impact": false}
	var fly_stats := ""
	var village_stats_started := false
	for turn_no in range(1, int(info["win_turn"]) + 3):
		var ok := await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == turn_no), 180000)
		if not ok:
			printerr("[strike-shot] turn %d never came" % turn_no)
			_failures += 1
			break
		if sb.result_decided():
			break
		planner.plan_players()

		# 02. The first time a player's plane has the tower in its sight: the village, close.
		var tower_m := Vector2(float(w.units[TOWER].x), float(w.units[TOWER].y))
		if not done["village"] and _nearest_player_m(w, tower_m) < 650.0:
			done["village"] = true
			_say("the village is in sight on turn %d (the nearest player plane %.0f m from the tower)" % [turn_no, _nearest_player_m(w, tower_m)])
			ui.selection.clear()
			sb.ctl.frame_max_zoom = 1.0
			sb.ctl.frame_points(_ring(tower_m, 330.0))
			sb.ctl.stop_follow()
			await _wait_view()
			await _shot("02_village_in_sight.png")
			fly_stats = _stats_line()
			sb.reset_stats()
			village_stats_started = true

		# 03. The first turn with a drop planned: the bomber selected, the cone and the aim for the drop's step.
		var bl: Dictionary = w.bombs_left(BOMBER)
		if not done["drop"] and int(bl.get("planned", 0)) > 0:
			done["drop"] = true
			var step := -1
			for k in w.steps_per_turn(BOMBER):
				if (w.units[BOMBER].plan[k] as Dictionary).has("drop"):
					step = k
					break
			ui.select(BOMBER)
			ui.planner.set_focus_step(step)
			var b := Vector2(float(w.units[BOMBER].x), float(w.units[BOMBER].y))
			var pts: Array = _ring(b, 200.0)
			pts.append_array(_ring(tower_m, 200.0))
			for st: Dictionary in w.planned_states(BOMBER):
				pts.append(Vector2(float(st["x"]), float(st["y"])))
			sb.ctl.frame_max_zoom = 1.0
			sb.ctl.frame_points(pts)
			sb.ctl.stop_follow()
			await _wait_view()
			await _shot("03_drop_planned.png")
			_say("a drop planned on step %d of turn %d: %s" % [step, turn_no, str(ui.planner.drop_info(step).get("quality", "?"))])
			ui.selection.clear()

		# The camera for this turn: the bomber's flight, the batteries and the tower when they matter; on the flak
		# turn close on the bomber (its bursts are what the shot is about).
		var focus: Array = _focus(w, turn_no, info)
		sb.ctl.frame_max_zoom = 1.3 if turn_no == int(info["flak_turn"]) else 1.0
		sb.ctl.frame_points(focus)
		sb.ctl.stop_follow()
		await _wait_view()
		var air_before := not w.bombs_in_flight.is_empty()   # a stick released in an earlier turn is still falling

		_events.clear()
		var shot_flak: bool = not done["flak"] and turn_no == int(info["flak_turn"])
		var flak_seen := 0
		ui.press_ready()
		var start := Time.get_ticks_msec()
		var flak_frame := -1          # the frame of the flak roll that makes the shot (about half-way through the turn's rolls)
		var release_frame := -1
		var impact_frame := -1
		while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 120000:
			await process_frame
			_frame_no += 1
			for e: Dictionary in _events:
				var ev: Dictionary = e["ev"]
				var ty := str(ev.get("type", ""))
				if ty == "bomb_release" and release_frame < 0:
					release_frame = int(e["frame"])
				elif ty == "bomb_impact" and impact_frame < 0:
					impact_frame = int(e["frame"])
			if shot_flak and flak_frame < 0:
				flak_seen = 0
				for e2: Dictionary in _events:
					var ev2: Dictionary = e2["ev"]
					if str(ev2.get("type", "")) == "fire" and str(ev2.get("weapon", "")) == "flak":
						flak_seen += 1
						if flak_seen >= maxi(int(info["flak_count"]) / 2, 1):
							flak_frame = int(e2["frame"])
							break
			if shot_flak and flak_frame >= 0 and _frame_no - flak_frame >= 4 and not done["flak"]:
				done["flak"] = true
				await _shot("04_turn_flak.png")
			# The stick in the air: the camera goes close on the bomber and follows it (a stick falls under the plane
			# that dropped it), two seconds into a turn in which bombs are falling, the flak shot (if this turn's) first.
			var falling_moment: bool = ui.is_playing() and ui.playback_time() >= 2.2 and (air_before or (release_frame >= 0 and _frame_no - release_frame >= 40))
			if not done["falling"] and (not shot_flak or done["flak"]) and falling_moment and not _impacts_seen():
				done["falling"] = true
				var pose: Dictionary = ui.marker_layer.pose_of(BOMBER)
				sb.ctl.set_view(Vector2(float(pose["x"]), float(pose["y"])) * sb.map_view.px_per_m, 2.0)
				sb.follow_unit(BOMBER)
				await _frames(30)
				await _shot("05_bombs_falling.png")
				_say("bombs falling shot: playback at %.1f s, %d bombs in flight" % [ui.playback_time(), w.bombs_in_flight.size()])
				sb.ctl.stop_follow()
			if not done["impact"] and impact_frame >= 0 and _frame_no - impact_frame >= 6:
				done["impact"] = true
				await _shot("06_bomb_impacts.png")
		await _frames(2)
		_say("turn %d played: %s" % [turn_no, _summary(w)])
		if sb.result_decided():
			break
	var village_stats := _stats_line()

	# The tower's ruin: close, one more turn on. The smoke belongs to the game's clock, which runs only while a turn
	# plays back, so the cloud of the blast is as thick as it was until another turn is played: the planes carry on
	# (the game is decided; the card waits for its own shot), and the frame is taken at the end of that turn.
	var tower_m2 := Vector2(float(w.units[TOWER].x), float(w.units[TOWER].y))
	sb.ctl.frame_max_zoom = 1.4
	sb.ctl.frame_points(_ring(tower_m2, 200.0))
	sb.ctl.stop_follow()
	var after := await _until(func() -> bool: return w.phase == World.PHASE_PLANNING and not ui.is_playing(), 60000)
	if after:
		var next_turn := w.turn
		ui.press_ready()
		await _until(func() -> bool: return w.turn > next_turn and not ui.is_playing() and w.phase == World.PHASE_PLANNING, 90000)
	await _wait_view()
	await _frames(20)
	await _shot("07_tower_ruin.png")

	# The result card.
	sb.scenario.view["result_card_delay_s"] = 0.1
	var shown := await _until(func() -> bool: return sb.result_card_shown(), 20000)
	_check(shown and ui.result_card != null and ui.result_card.is_showing(), "the result card is up: %s" % str(sb.result))
	await _frames(20)
	await _shot("08_result_card.png")

	# Fully zoomed out: the whole map, the tracks, the roster clear of the map.
	ui.hide_result()
	sb.ctl.set_view(sb.terrain.map_rect_px().get_center(), 0.001)
	await _frames(10)
	var tl: Vector2 = sb.ctl.world_px_to_screen(sb.terrain.map_rect_px().position)
	var br: Vector2 = sb.ctl.world_px_to_screen(sb.terrain.map_rect_px().end)
	var side: Rect2 = ui.sidebar_rect()
	_check(br.x <= side.position.x + 0.5, "the whole map (x %.0f to %.0f) is left of the sidebar (from x %.0f)" % [tl.x, br.x, side.position.x])
	var topo_ok := await _until(func() -> bool: return _overview_cached() >= _overview_total(), 90000)
	_say("the overview filled in (%s)" % str(topo_ok))
	await _frames(20)
	await _shot("09_zoomed_out_tracks.png")

	_check(done["village"], "the village shot was taken")
	_check(done["drop"], "the drop-planned shot was taken")
	_check(done["flak"], "the flak shot was taken")
	_check(done["falling"], "the bombs-falling shot was taken")
	_check(done["impact"], "the impacts shot was taken")
	_say("FRAME TIMES BY ACTIVITY, the fly-in (%s window): %s" % [str(size), fly_stats])
	_say("FRAME TIMES BY ACTIVITY, over the village and to the end: %s" % village_stats)
	_say("sandbox load_ms %.0f, failures %d" % [sb.load_ms, _failures])
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)

# --- Helpers ----------------------------------------------------------------------------------------------------

func _impacts_seen() -> bool:
	for e: Dictionary in _events:
		if str((e["ev"] as Dictionary).get("type", "")) == "bomb_impact":
			return true
	return false

func _ring(at: Vector2, r: float) -> Array:
	var pts: Array = []
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		pts.append(at + corner * r)
	return pts

func _nearest_player_m(w: World, p: Vector2) -> float:
	var best := INF
	for id: String in w.units:
		var u = w.units[id]
		if u.controller == World.CONTROLLER_PLAYER and not u.down:
			best = minf(best, Vector2(float(u.x), float(u.y)).distance_to(p))
	return best

# What the camera frames before a turn plays: the players and where this turn takes them (the script is
# omniscient about its own plans; the camera never reads the enemy's), the village's guns once the turn is
# the flak's, and the tower once the bombs are on their way.
func _focus(w: World, turn_no: int, info: Dictionary) -> Array:
	var pts: Array = []
	if turn_no == int(info["flak_turn"]):
		var b: Vector2 = Vector2(float(w.units[BOMBER].x), float(w.units[BOMBER].y))
		pts.append_array(_ring(b, 300.0))
		for st: Dictionary in w.planned_states(BOMBER):
			pts.append_array(_ring(Vector2(float(st["x"]), float(st["y"])), 300.0))
		return pts
	for id: String in w.units:
		var u = w.units[id]
		if u.controller != World.CONTROLLER_PLAYER or u.down:
			continue
		if id != BOMBER and turn_no >= int(info["flak_turn"]) - 1:
			continue   # near the village the shot is about the bomber, the guns and the tower
		pts.append(Vector2(float(u.x), float(u.y)))
		for st: Dictionary in w.planned_states(id):
			pts.append(Vector2(float(st["x"]), float(st["y"])))
	if turn_no >= int(info["flak_turn"]) - 1:
		for id: String in BATTERIES + [TOWER]:
			pts.append(Vector2(float(w.units[id].x), float(w.units[id].y)))
	if pts.is_empty():
		pts.append(Vector2(2000.0, 1500.0))
	return pts

func _summary(w: World) -> String:
	var parts: Array[String] = []
	for id: String in w.units:
		var u = w.units[id]
		if u.def.is_static() and not u.down:
			continue
		parts.append("%s (%.0f,%.0f) hp%d%s" % [id, u.x, u.y, u.health, " DOWN(%s)" % u.fate if u.down else ""])
	return "  ".join(parts)

func _overview_cached() -> int:
	var n := 0
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	for k: Vector3i in sb.fog._cache:
		if k.z == lod:
			n += 1
	return n

func _overview_total() -> int:
	return sb.terrain.chunks_in_rect_px(sb.terrain.map_rect_px()).size()

func _stats_line() -> String:
	var parts: Array[String] = []
	for cat: String in sb.stats:
		var s: Dictionary = sb.stats[cat]
		parts.append("%s n=%d mean %.1f ms max %.1f ms (>33 ms: %d, >100 ms: %d)" % [
			cat, s.n, s.sum_ms / maxf(float(s.n), 1.0), s.max_ms, s.over33, s.over100])
	return " | ".join(parts)
