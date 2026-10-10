extends SceneTree

# THE FIRST FIGHT, IN THE RUNNING BUILD (Track A, 2026-10-10). WINDOWED ONLY -- under
# --headless nothing is drawn (scripts/tests/test_intercept.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/app/intercept_shot.gd -- [out=tmp/intercept] [window=1920x1080] [seed=N]
#
# Starts Intercept exactly as the menu's Local button does (scripts/app/sandbox.gd) and plays
# it through the REAL turn flow (Ready, the host-side resolve, the markers' playback) with the
# players flown by a scripted lead-pursuit chase (scripts/test_support/intercept_play.gd), saving
# one PNG per moment at the window's NATIVE size:
#
#   01_opening.png               the opening view: the players, the target ring, the fog
#   02_first_contact_fog.png     the bomber's first turn in sight, the rest of the map still fog
#   03_cones_selected_plane.png  the selected plane's cones while planning (a colour wash)
#   04_turn_playing_hits.png     a turn playing back, a moment after a hit
#   05_damaged_plane_smoking.png a damaged plane trailing smoke, a turn after it was hit
#   06_crash.png                 a plane that went down out of control, at the crash
#   06b_crash_wreck.png          the same spot about a second later: the scar and the smoke column
#   07_result_card.png           the end-of-mission card
#   08_zoomed_out_roster_clear.png  fully zoomed out: the whole map is left of the roster sidebar
#
# WHICH SEED. Combat's odds are still being tuned (Track C), so no seed is written down: the
# script first PLAYS the chase headless in-process over seeds 1..SEED_SEARCH (the same World,
# the same plans, so the same result) and takes the first that WINS and, among those, one in which
# something crashes; `seed=N` forces one. That simulation also says which turn has the first hit,
# a damaged plane still flying, and the crash, so the camera is put there before the turn plays.
# It prints what the report needs: the time from Local to the first playable frame and the frame
# times by what the game was doing.

const World = preload("res://scripts/sim/world.gd")
const InterceptPlay = preload("res://scripts/test_support/intercept_play.gd")

const SEED_SEARCH := 80
const BOMBER := "bomber_1"
const ESCORT := "escort_1"

var out_dir := "tmp/intercept"
var opts: Dictionary = {}
var size := Vector2i(1920, 1080)
var sb: Node = null
var dbg: Node = null
var _failures := 0
var _t0 := 0
var _events: Array = []           # [{ev, frame}] this turn's playback events as the UI fired them
var _frame_no := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[intercept-shot] needs a windowed run: under --headless nothing is drawn")
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
	print("[intercept-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[intercept-shot] FAIL  " + msg)

# Waits until the map under the view is baked (the hidden chunks do not count) and so is the fog's
# topographic layer over it (no bake in flight, none still wanted), then a few frames.
func _wait_view(max_s: float = 90.0) -> float:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[intercept-shot] view not complete after %.0f s (%d missing, fog busy %s)" % [max_s, sb.map_view.missing_in_view(true), str(_fog_busy())])
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

# --- The seed, from a headless run of the same game ---------------------------------------------------

# Plays the scripted chase headless over seeds until one wins; prefers one in which a plane crashes.
func _pick_seed() -> Dictionary:
	var first_win: Dictionary = {}
	var forced := int(opts.get("seed", -1))
	var seeds: Array = [forced] if forced >= 0 else range(1, SEED_SEARCH + 1)
	for s: int in seeds:
		var g := InterceptPlay.new("intercept", s)
		var r: Dictionary = g.play("chase", 18)
		if str(r["state"]) != "won" and forced < 0:
			continue
		var won_turn := int(r["turn"])
		g.continue_after_result = true
		g.play("chase", 4)   # watch the wreck fall
		var info := _knowledge(g, s, won_turn, str(r["state"]))
		if first_win.is_empty():
			first_win = info
		if bool(info["crash"].size() > 0):
			return info
	return first_win

# What the simulation says about the game: the first hit, a damaged plane still up, the crash.
func _knowledge(g: RefCounted, s: int, result_turn: int, state: String) -> Dictionary:
	var info := {"seed": s, "state": state, "result_turn": result_turn, "hit": {}, "smoke": {}, "crash": {}, "paths": {}}
	for ev: Dictionary in g.events:
		if info["hit"].is_empty() and ev["type"] == "hit" and float(ev["t"]) <= 4.0:
			info["hit"] = ev   # (a hit at the very end of a turn fires as the playback ends: no moment to catch)
		if info["crash"].is_empty() and ev["type"] == "crash":
			info["crash"] = ev
	for snap: Dictionary in g.snaps:
		if not info["smoke"].is_empty():
			break
		for id: String in snap["units"]:
			var u: Dictionary = snap["units"][id]
			var def_health: int = g.world.units[id].def.health
			if not bool(u["down"]) and int(u["health"]) > 0 and int(u["health"]) < def_health:
				info["smoke"] = {"turn": int(snap["turn"]) + 1, "unit": id}
				break
	var paths: Dictionary = {}
	for snap: Dictionary in g.snaps:
		paths[int(snap["turn"])] = snap["paths"]
	info["paths"] = paths
	return info

# --- The run -------------------------------------------------------------------------------------------------

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	_say("window %s, viewport %s" % [str(DisplayServer.window_get_size()), str(root.get_viewport().get_visible_rect().size)])
	dbg = root.get_node("DebugSettings")
	dbg.set_choice("scenario", 0)   # intercept

	var t_sim := Time.get_ticks_msec()
	var info := _pick_seed()
	if info.is_empty():
		printerr("[intercept-shot] no seed in 1..%d won the scripted chase: nothing to show" % SEED_SEARCH)
		quit(1)
		return
	_say("seed %d: the chase %s on turn %d (found in %.1f s of headless play); first hit %s; a damaged plane up from turn %s; crash %s" % [
		int(info["seed"]), str(info["state"]), int(info["result_turn"]), (Time.get_ticks_msec() - t_sim) / 1000.0,
		("turn %d t=%.1f %s hit by %s" % [int(info["hit"]["turn"]), float(info["hit"]["t"]), str(info["hit"]["unit"]), str(info["hit"]["by"])]) if not info["hit"].is_empty() else "none",
		str(info["smoke"].get("turn", "none")),
		("turn %d t=%.1f %s" % [int(info["crash"]["turn"]), float(info["crash"]["t"]), str(info["crash"]["unit"])]) if not info["crash"].is_empty() else "none"])

	_t0 = Time.get_ticks_msec()
	var script: Script = load("res://scripts/app/sandbox.gd")
	if script == null or not script.can_instantiate():
		printerr("[intercept-shot] scripts/app/sandbox.gd did not compile -- see the Parse Error above")
		quit(1)
		return
	sb = script.new()
	root.add_child(sb)
	if not sb.ok():
		printerr("[intercept-shot] the sandbox did not build: ", sb.errors)
		quit(1)
		return
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable, "Intercept is playable %.1f s after Local (load_ms %.0f; building the parts %.0f ms; the first view of %d chunks baked behind \"Drawing the map...\")" % [
		(Time.get_ticks_msec() - _t0) / 1000.0, sb.load_ms, sb.build_ms, sb._load_total])
	var w: World = sb.world
	w.rng_seed = int(info["seed"])
	sb.scenario.view["result_card_delay_s"] = 9999.0   # the card waits for its own shot
	var planner = InterceptPlay.for_world(w)
	var ui = sb.ui
	ui.playback_event.connect(func(ev: Dictionary) -> void: _events.append({"ev": ev, "frame": _frame_no}))
	await _wait_view()
	await _shot("01_opening.png")

	var done := {"contact": false, "cones": false, "hit": false, "smoke": false, "crash": false}
	var fly_turns := int(info["result_turn"]) + 5
	for turn_no in range(1, fly_turns + 1):
		var ok := await _until(func() -> bool: return w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == turn_no, 120000)
		if not ok:
			printerr("[intercept-shot] turn %d never came" % turn_no)
			_failures += 1
			break
		# The players' chase for this turn (the enemy plans itself on the host).
		planner.plan_chase()

		# 02 / 03. The first turn the bomber is in sight: the fog around it, then the cones.
		var marker = ui.marker_layer.marker(BOMBER)
		if not done["contact"] and marker != null and marker.visible:
			done["contact"] = true
			_say("first contact: the bomber is in sight on turn %d" % turn_no)
			var pts: Array = []
			for id: String in w.units:
				if w.units[id].controller == World.CONTROLLER_PLAYER or ui.marker_layer.marker(id).visible:
					for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
						pts.append(Vector2(float(w.units[id].x), float(w.units[id].y)) + corner * 1000.0)   # (room round them for the edge of sight)
			sb.ctl.frame_max_zoom = 0.4
			sb.ctl.frame_points(pts)
			sb.ctl.stop_follow()
			await _wait_view()
			await _shot("02_first_contact_fog.png")
			var near_id := _nearest_player_to_bomber(w)
			ui.select(near_id)
			var cone_pts: Array = [Vector2(float(w.units[near_id].x), float(w.units[near_id].y)), Vector2(float(w.units[BOMBER].x), float(w.units[BOMBER].y))]
			for st: Dictionary in w.planned_states(near_id):
				cone_pts.append(Vector2(float(st["x"]), float(st["y"])))
			sb.ctl.frame_max_zoom = 1.0
			sb.ctl.frame_points(cone_pts)
			await _wait_view()
			await _shot("03_cones_selected_plane.png")
			done["cones"] = true

		# The camera for this turn: where the shot of this turn will be.
		var focus: Array = _focus(w, ui, info, turn_no, done)
		sb.ctl.frame_max_zoom = 1.2 if focus.size() < 12 else 1.0
		sb.ctl.frame_points(focus)
		sb.ctl.stop_follow()
		await _wait_view()

		_events.clear()
		var want_hit: bool = not done["hit"] and not info["hit"].is_empty() and int(info["hit"]["turn"]) == turn_no
		var want_smoke: bool = not done["smoke"] and not info["smoke"].is_empty() and int(info["smoke"]["turn"]) == turn_no
		var want_crash: bool = not done["crash"] and not info["crash"].is_empty() and int(info["crash"]["turn"]) == turn_no
		ui.press_ready()
		var start := Time.get_ticks_msec()
		var hit_frame := -1
		var crash_frame := -1
		var crash_t := 0.0
		while (w.turn == turn_no or ui.is_playing()) and Time.get_ticks_msec() - start < 90000:
			await process_frame
			_frame_no += 1
			for e: Dictionary in _events:
				var ev: Dictionary = e["ev"]
				if str(ev.get("type", "")) == "hit" and hit_frame < 0:
					hit_frame = int(e["frame"])
				if str(ev.get("type", "")) == "crash" and crash_frame < 0:
					crash_frame = int(e["frame"])
					crash_t = float(ev["t"])
			if want_hit and hit_frame >= 0 and _frame_no - hit_frame >= 4 and not done["hit"]:
				done["hit"] = true
				await _shot("04_turn_playing_hits.png")
			if want_smoke and not done["smoke"] and ui.is_playing() and ui.playback_time() >= 3.4:
				done["smoke"] = true
				await _shot("05_damaged_plane_smoking.png")
			if want_crash and crash_frame >= 0 and _frame_no - crash_frame >= 3 and not done["crash"]:
				done["crash"] = true
				await _shot("06_crash.png")
			if done["crash"] and not done.get("wreck", false) and _frame_no - crash_frame >= 30:
				done["wreck"] = true
				await _shot("06b_crash_wreck.png")
		await _frames(2)
		_say("turn %d played: %s" % [turn_no, _summary(w)])
		var finished: bool = sb.result_decided() and (done["crash"] or info["crash"].is_empty() or turn_no >= int(info["result_turn"]) + 4)
		if finished:
			break

	# The result card.
	sb.scenario.view["result_card_delay_s"] = 0.1
	var shown := await _until(func() -> bool: return sb.result_card_shown(), 20000)
	_check(shown and ui.result_card != null and ui.result_card.is_showing(), "the result card is up: %s" % str(sb.result))
	await _frames(20)
	await _shot("07_result_card.png")

	# Fully zoomed out: the roster must not cover the map.
	ui.hide_result()
	sb.ctl.set_view(sb.terrain.map_rect_px().get_center(), 0.001)
	await _frames(10)
	_check(sb.ctl.overview_amount() > 0.99, "fully zoomed out the topographic overview shows (zoom %.3f)" % sb.ctl.zoom_level())
	var tl: Vector2 = sb.ctl.world_px_to_screen(sb.terrain.map_rect_px().position)
	var br: Vector2 = sb.ctl.world_px_to_screen(sb.terrain.map_rect_px().end)
	var side: Rect2 = ui.sidebar_rect()
	_check(br.x <= side.position.x + 0.5, "the whole map (x %.0f to %.0f) is left of the sidebar (from x %.0f)" % [tl.x, br.x, side.position.x])
	var topo_ok := await _until(func() -> bool: return _overview_cached() >= _overview_total(), 90000)
	_say("the overview filled in (%s)" % str(topo_ok))
	await _frames(20)
	await _shot("08_zoomed_out_roster_clear.png")

	_check(done["hit"], "the hit shot was taken")
	_check(done["smoke"], "the damaged-plane shot was taken")
	_check(done["crash"], "the crash shot was taken")
	_check(done["contact"] and done["cones"], "the first-contact and cone shots were taken")
	_report()
	quit(1 if _failures > 0 else 0)

# Waits (frames) until `cond` or `max_ms` real time.
func _until(cond: Callable, max_ms: int) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t > max_ms:
			return false
		await process_frame
		_frame_no += 1
	return true

func _overview_cached() -> int:
	var n := 0
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	for k: Vector3i in sb.fog._cache:
		if k.z == lod:
			n += 1
	return n

func _overview_total() -> int:
	return sb.terrain.chunks_in_rect_px(sb.terrain.map_rect_px()).size()

func _nearest_player_to_bomber(w: World) -> String:
	var best := ""
	var best_d := INF
	for id: String in w.units:
		var u = w.units[id]
		if u.controller == World.CONTROLLER_PLAYER and not u.down:
			var d: float = Vector2(float(u.x), float(u.y)).distance_to(Vector2(float(w.units[BOMBER].x), float(w.units[BOMBER].y)))
			if d < best_d:
				best_d = d
				best = id
	return best

# What the camera frames before this turn plays: the planes in sight and where this turn takes them,
# narrowed to the unit the shot of the turn is about.
func _focus(w: World, ui: Node, info: Dictionary, turn_no: int, done: Dictionary) -> Array:
	var ids: Array[String] = []
	if not done["smoke"] and not info["smoke"].is_empty() and int(info["smoke"]["turn"]) == turn_no:
		ids.append(str(info["smoke"]["unit"]))
	elif not done["crash"] and not info["crash"].is_empty() and int(info["crash"]["turn"]) == turn_no:
		ids.append(str(info["crash"]["unit"]))
	elif not done["hit"] and not info["hit"].is_empty() and int(info["hit"]["turn"]) == turn_no:
		ids.append(str(info["hit"]["unit"]))
		ids.append(str(info["hit"]["by"]))
	if ids.is_empty():
		for id: String in w.units:
			if w.units[id].controller == World.CONTROLLER_PLAYER or ui.marker_layer.marker(id).visible:
				ids.append(id)
	var pts: Array = []
	if ids.size() == 1 and not info["crash"].is_empty() and int(info["crash"]["turn"]) == turn_no and ids[0] == str(info["crash"]["unit"]):
		var at := Vector2(float(info["crash"]["x"]), float(info["crash"]["y"]))
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			pts.append(at + corner * 280.0)   # close on the impact, not the long fall
		return pts
	var crash_paths: Dictionary = info["paths"].get(turn_no, {})
	for id: String in ids:
		if not w.units.has(id):
			continue
		var u = w.units[id]
		pts.append(Vector2(float(u.x), float(u.y)))
		# Where it ends the turn: its own plan (the shot script is omniscient), or the simulation's path for a wreck.
		for st: Dictionary in w.planned_states(id):
			pts.append(Vector2(float(st["x"]), float(st["y"])))
		for p: Variant in crash_paths.get(id, []):
			pts.append(p)
	if pts.is_empty():
		pts.append(Vector2(2800.0, 3000.0))
	return pts

func _summary(w: World) -> String:
	var parts: Array[String] = []
	for id: String in w.units:
		var u = w.units[id]
		parts.append("%s (%.0f,%.0f) hp%d%s" % [id, u.x, u.y, u.health, " DOWN(%s)" % u.fate if u.down else ""])
	return "  ".join(parts)

func _stats_line() -> String:
	var parts: Array[String] = []
	for cat: String in sb.stats:
		var s: Dictionary = sb.stats[cat]
		parts.append("%s n=%d mean %.1f ms max %.1f ms (>33 ms: %d, >100 ms: %d)" % [
			cat, s.n, s.sum_ms / maxf(float(s.n), 1.0), s.max_ms, s.over33, s.over100])
	return " | ".join(parts)

func _report() -> void:
	_say("FRAME TIMES BY ACTIVITY (%s window): %s" % [str(size), _stats_line()])
	_say("sandbox load_ms %.0f, failures %d" % [sb.load_ms, _failures])
