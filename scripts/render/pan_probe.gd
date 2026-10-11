extends SceneTree

# THE PAUSED-PAN PROBE (Track P, map and fog performance, 2026-10-10). A tool, not a test: it needs a
# window. It builds the REAL sandbox (the Strike unless INKWOOD_SCENARIO says otherwise), times
# Local -> playable, and then, with the game PAUSED (planning, no playback), pans and zooms around the
# whole map like a player would, recording every frame:
#
#   WINDOWED, the console build, a window of the size asked for:
#     INKWOOD_STEAM=off Godot_v4.7-stable_win64_console.exe --path . --script res://scripts/render/pan_probe.gd -- size=1920x1080 out=tmp/perf/pan_1080.json
#
# Options (key=value after --):
#   size=WxH     the window (default 1280x720)
#   settle=S     seconds to wait after "playable" before the first move (default 0: the worst case, a
#                player who pans the moment the card goes). Frames while waiting are recorded as phase "settle".
#   vsync=0      vsync off (the frame time is then the CPU+GPU work, not the display's 16.7 ms steps)
#   speed=N      pan speed, screen px per second (default 1800: a fast drag)
#   out=PATH     write every frame's row as JSON
#   phases=a,b   which phases to run (default all): pan_start, zoom, pan_mid, pan_close, overview
#   phase_s=N    longest a phase may take, seconds (default 60): a route stops there
#   noground=1   no map chunks are baked (time the fog's whole-map bake alone); fogmode=demand: the fog bakes only what the view needs
#   without=fog|ui|map|scale  take that part away after loading (to see which one a hitch belongs to)
#   max_jobs=N bake_budget_loading_ms=N max_worker_tasks=N sprite_pages_per_frame=N sprite_cache_max=N max_cached_chunks=N   override those map_view settings for the run
#   loadshot=DIR save the loading card as a PNG at 5, 10 and 15 s into the load
#   phases=rescale,repen   the map scale knob to 3 px/m, then the pen knob: the frames while the map is redrawn
#   phases=playback   n turns played back with the camera still (turns=N, default 2); bgyield=0: the background bake does not wait
#   loadwhole=1  the loading card waits for EVERY chunk of the map (background_bake.load_whole_map)
#   twins=N      the fog's recorder threads (FogLayer.twin_count), overriding the data; inflight=N its max_inflight
#
# Per frame (rows in the JSON, one array per phase): dt (ms), the script process time, the main-thread ms the
# baker and the fog's pipeline spent, the fog mask / draw ms, bakes finished, how many chunks of the view are
# NOT painted (fog: no texture at all, or only another level of detail's; map: not baked and not under the fog),
# the render times the engine measured for the root viewport, and workers busy.
#
# The summary per phase: frames, median, p95, p99, worst, frames over 33 ms / 50 ms / 100 ms, frames with any
# unpainted chunk. Run it before and after a change and diff.

var opts: Dictionary = {}
var sb: Node = null
var rows: Dictionary = {}          # phase -> Array of Array
var phase := "load"
var _last_us := 0
var _prev: Dictionary = {}
var _rid: RID
var _phase_t0 := 0
var _phase_cap_s := 60.0
var _next_report_ms := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

var _snap: Dictionary = {}

# Prints what the baker did on the main thread since the last phase began (its stage times, in ms), then notes where this one starts.
# One line of the loading timeline: what is baked and what is not, every 2 seconds.
func _timeline(ms: int) -> void:
	var mv = sb.get("map_view")
	var fog = sb.get("fog")
	var fogs := "fog %d/%d" % [fog.bake_done(), fog.bake_total()] if fog.has_method("bake_done") else "fog bakes %d" % int(fog.stats.bakes)
	var sighted: int = mv.missing_sighted() if mv.has_method("missing_sighted") else mv.missing_in_view(true)
	var trees := ""
	if mv.baker.has_method("pool_total") and mv.baker.pool_total() > 0:
		trees = ", tree set %d/%d" % [mv.baker.pool_done(), mv.baker.pool_total()]
	print("[pan]   load %5.1f s: map chunks baked %d, missing in sight %d, %s%s, map jobs busy %d" % [ms / 1000.0, mv.chunk_count(), sighted, fogs, trees, int(mv.baker.get("_busy"))])

func _set_phase(name: String) -> void:
	_report_baker_delta()
	phase = name
	_phase_t0 = Time.get_ticks_msec()

func _report_baker_delta() -> void:
	if sb == null or sb.get("map_view") == null:
		return
	var mv = sb.get("map_view")
	var bs: Dictionary = mv.baker.stats
	var now := {"stage": (bs.stage_ms as Dictionary).duplicate(), "worker": (bs.worker_ms as Dictionary).duplicate(), "main": float(bs.main_ms),
		"chunks": int(bs.chunks), "sprites": int(bs.sprites_built), "pages": int(bs.pages)}
	if not _snap.is_empty():
		var wparts: Array[String] = []
		var wk: Dictionary = now.worker
		for k: String in wk:
			var dw := float(wk[k]) - float((_snap.worker as Dictionary).get(k, 0.0))
			if dw >= 100.0:
				wparts.append("%s %.0f" % [k, dw])
		print("[pan] phase '%s' baker worker-thread time by stage (ms, summed over threads): %s" % [phase, ", ".join(wparts)])
		var parts: Array[String] = []
		var st: Dictionary = now.stage
		for k: String in st:
			var dv := float(st[k]) - float((_snap.stage as Dictionary).get(k, 0.0))
			if dv >= 20.0:
				parts.append("%s %.0f" % [k, dv])
		print("[pan] phase '%s' baker: %d chunks, %d sprite pages, %d sprites, main %.0f ms; main-thread stages (ms): %s; worst single action %s %.0f ms" % [
			phase, int(now.chunks) - int(_snap.chunks), int(now.pages) - int(_snap.pages), int(now.sprites) - int(_snap.sprites),
			float(now.main) - float(_snap.main), ", ".join(parts), str(bs.get("worst_action", "")), float(bs.get("worst_action_ms", 0.0))])
		bs.worst_action_ms = 0.0
	_snap = now

func _phase_over() -> bool:
	return (Time.get_ticks_msec() - _phase_t0) / 1000.0 > _phase_cap_s

func _tick() -> void:
	# Called once per frame, after the frame: records the row for the current phase.
	var now := Time.get_ticks_usec()
	var dt := (now - _last_us) / 1000.0 if _last_us > 0 else 0.0
	_last_us = now
	if sb == null or sb.get("map_view") == null:
		return
	var mv = sb.get("map_view")
	var fog = sb.get("fog")
	var baker_main: float = mv.baker.stats.main_ms
	var fog_main: float = fog.stats.main_ms
	var fog_bakes: int = fog.stats.bakes
	var base_chunks: int = mv.baker.stats.chunks
	var row := [dt,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		baker_main - float(_prev.get("bm", baker_main)),
		fog_main - float(_prev.get("fm", fog_main)),
		float(fog.stats.mask_us) / 1000.0,
		float(fog.stats.draw_us) / 1000.0,
		(fog_bakes - int(_prev.get("fb", fog_bakes))) + (base_chunks - int(_prev.get("bc", base_chunks))),
		0, 0,   # unpainted fog chunks, unpainted map chunks (below)
		RenderingServer.viewport_get_measured_render_time_cpu(_rid),
		RenderingServer.viewport_get_measured_render_time_gpu(_rid),
		int(mv.baker.get("_busy")) + int(fog.bakes_in_flight()),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)), 0]
	_prev = {"bm": baker_main, "fm": fog_main, "fb": fog_bakes, "bc": base_chunks}
	if phase != "load":
		var un := _unpainted(mv, fog)
		row[7] = un[0]
		row[8] = un[1]
		row[13] = un[2]
	if not rows.has(phase):
		rows[phase] = []
	(rows[phase] as Array).append(row)
	var now_ms := Time.get_ticks_msec()
	if now_ms >= _next_report_ms:
		_next_report_ms = now_ms + 5000
		var ctl = sb.get("ctl")
		print("[pan]   ... %s: %d frames, last %.1f ms, zoom %.3f at %s" % [phase, (rows[phase] as Array).size(), dt, ctl.zoom_level(), ctl.center().round()])

# [fog chunks of the view with no texture at the level of detail the zoom wants (a fallback to another level or
# the plain sheet), map chunks of the view not baked and not wholly under the fog, BLANK]. The first two are the
# paint-in the player sees (something else, or nothing, shows meanwhile). BLANK is Alex's rule (2026-10-10:
# "showing a stale map seems better then a plain brown square"): the chunks of the view where NOTHING made shows --
# no contour texture at any level, fresh or stale, and no ground either. With FogLayer.unpainted_in_view() it is
# that; without (the code before the floor) it is the fog chunks the layer draws as a plain square plus the map
# chunks in sight that are not baked (paper shows there).
func _unpainted(mv, fog) -> Array:
	var bad_fog := 0
	var blank := 0
	if fog.topo != null and fog.visible:
		var lod: int = fog.topo.lod_for_zoom(fog._zoom)
		for c in fog.terrain.chunks_in_rect_px(fog.view_rect_px()):
			if fog._overview <= 0.0 and fog._inside_vision(c):
				continue
			if not fog.has_topo_chunk(c, lod):
				bad_fog += 1
			if not fog.has_method("unpainted_in_view") and fog._best(c, lod) == null:
				blank += 1
		if fog.has_method("unpainted_in_view"):
			blank = fog.unpainted_in_view()
	var bad_map: int = mv.missing_in_view(true) if mv.bake_enabled else 0
	if not fog.has_method("unpainted_in_view"):
		blank += bad_map
	return [bad_fog, bad_map, blank]

func _frame() -> void:
	await process_frame
	_tick()

func _frames(n: int) -> void:
	for _i in n:
		await _frame()

func _run() -> void:
	var sz := str(opts.get("size", "1280x720")).split("x")
	var size := Vector2i(int(sz[0]), int(sz[1]))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	if str(opts.get("vsync", "1")) == "0":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await process_frame
	await process_frame
	_rid = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_rid, true)
	print("[pan] window %s on screen %s, vsync %s" % [DisplayServer.window_get_size(), DisplayServer.screen_get_size(), DisplayServer.window_get_vsync_mode()])
	var script: Script = load("res://scripts/app/sandbox.gd")
	sb = script.new()
	var t0 := Time.get_ticks_msec()
	root.add_child(sb)
	var fog0 = sb.get("fog")
	if fog0 != null and opts.has("twins") and "twin_count" in fog0:
		fog0.twin_count = int(opts["twins"])   # (the pipeline is built on the first frame)
	if fog0 != null and opts.has("inflight") and "max_inflight" in fog0:
		fog0.max_inflight = int(opts["inflight"])
	var mv0 = sb.get("map_view")
	if mv0 != null:
		for k: String in ["max_jobs", "bake_budget_loading_ms", "max_worker_tasks", "sprite_pages_per_frame", "terrain_lanes", "sprite_cache_max", "max_cached_chunks"]:
			if opts.has(k):
				mv0.cfg[k] = float(opts[k])
		if str(opts.get("bgyield", "1")) == "0":
			(mv0.cfg.get("background_bake", {}) as Dictionary)["yield_to_playback"] = false
			(mv0.cfg.get("background_bake", {}) as Dictionary)["yield_to_camera_ms"] = 0
		if str(opts.get("loadwhole", "0")) == "1":
			(mv0.cfg.get("background_bake", {}) as Dictionary)["load_whole_map"] = true   # the card waits for every chunk
		mv0.baker.apply_config(mv0.cfg)
	if sb.get("map_view") != null and str(opts.get("noground", "0")) == "1":
		sb.get("map_view").bake_enabled = false   # the fog's whole-map bake alone
	if fog0 != null and str(opts.get("fogmode", "")) == "demand" and "whole_map" in fog0:
		fog0.whole_map = false
	_last_us = Time.get_ticks_usec()
	_report_baker_delta()
	var next_tl := Time.get_ticks_msec() + 2000
	var pool_t := -1
	var shot_dir := str(opts.get("loadshot", ""))   # loadshot=DIR: save the loading card at 5, 10 and 15 s of the load
	var shots_at: Array = [5000, 10000, 15000]
	while not bool(sb.get("is_playable")):
		await _frame()
		if pool_t < 0 and sb.get("map_view") != null and sb.get("map_view").baker.has_method("pool_total") and sb.get("map_view").baker.pool_total() > 0 and sb.get("map_view").baker.pool_ready():
			pool_t = Time.get_ticks_msec() - t0
			print("[pan] the global tree set (%d trees) was made %.1f s into the load" % [sb.get("map_view").baker.pool_total(), pool_t / 1000.0])
		if shot_dir != "" and not shots_at.is_empty() and Time.get_ticks_msec() - t0 >= int(shots_at[0]):
			DirAccess.make_dir_recursive_absolute(shot_dir)
			var path := "%s/loading_%ds.png" % [shot_dir, int(shots_at[0]) / 1000]
			root.get_texture().get_image().save_png(path)
			print("[pan] saved the loading card: %s" % path)
			shots_at.pop_front()
		if Time.get_ticks_msec() >= next_tl:
			next_tl += 2000
			_timeline(Time.get_ticks_msec() - t0)
		if Time.get_ticks_msec() - t0 > 600000:
			print("[pan] TIMEOUT waiting for playable")
			break
	var load_ms := Time.get_ticks_msec() - t0
	var mv = sb.get("map_view")
	var fog = sb.get("fog")
	var ctl = sb.get("ctl")
	print("[pan] LOCAL -> PLAYABLE %d ms (sandbox load_ms %s, build_ms %s); first view %d chunks; baker: %d chunks, %d sprites; fog bakes %d; pending map %d" % [
		load_ms, sb.get("load_ms"), sb.get("build_ms"), sb.get("_load_total"), mv.baker.stats.chunks, mv.baker.stats.sprites_built, fog.stats.bakes, mv.pending()])
	_report_memory("playable")
	_report_bakes("at playable")
	_phase_cap_s = float(opts.get("phase_s", "60"))
	_set_phase("settle")
	var settle := float(opts.get("settle", "0"))
	var ts := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - ts) / 1000.0 < settle:
		await _frame()
	if settle > 0.0:
		print("[pan] after %.0f s settle: pending map %d, fog bakes %d, map chunks cached %d" % [settle, mv.pending(), fog.stats.bakes, mv.chunk_count()])
		_report_memory("settled")
	_fixed_costs()
	match str(opts.get("without", "")):   # take one part away to see which one a hitch belongs to
		"fog":
			sb.call("_set_fog", false)
		"ui":
			(sb.get("ui") as Node).process_mode = Node.PROCESS_MODE_DISABLED
			for layer in ["_mount", "_hud"]:
				(sb.get(layer) as CanvasLayer).visible = false
		"map":
			(sb.get("map_view") as Node2D).visible = false
		"scale":
			sb.set("plane_px", 0.0)   # the planes keep the map's own scale: no marker re-scale on a zoom
	var want: PackedStringArray = str(opts.get("phases", "pan_start,zoom,pan_mid,pan_close,overview")).split(",")
	var speed := float(opts.get("speed", "1800"))
	var map_px: Rect2 = ctl.map_rect_px
	var start_zoom: float = ctl.zoom_level()
	var start_centre: Vector2 = ctl.center()
	print("[pan] opening view: zoom %.3f centre %s; map %s px" % [start_zoom, start_centre.round(), map_px.size])
	if want.has("pan_start"):
		_set_phase("pan_start")
		await _pan_route(ctl, _serpentine(map_px, ctl, start_zoom), start_zoom, speed)
	if want.has("zoom"):
		_set_phase("zoom")
		await _zoom_sweep(ctl, map_px)
	if want.has("pan_mid"):
		_set_phase("pan_mid")
		await _pan_route(ctl, _serpentine(map_px, ctl, 0.7), 0.7, speed)
	if want.has("pan_close"):
		_set_phase("pan_close")
		await _pan_route(ctl, _diagonals(map_px), 1.2, speed)
	if want.has("rescale"):
		_set_phase("rescale")
		await _knob_rebake("map_scale", 3)   # 3 px per metre: the whole map is redrawn
	if want.has("repen"):
		_set_phase("repen")
		await _knob_rebake("pen", 1)   # the 'even' pen: everything inked with the old one is redrawn
	if want.has("playback"):
		_set_phase("playback")
		await _playback_turns(int(opts.get("turns", "2")))
	if want.has("overview"):
		_set_phase("overview")
		await _overview_route(ctl, map_px, speed)
	_report_baker_delta()
	phase = "end"
	_report_memory("end")
	_report_bakes("end of the session")
	_summary()
	var out := str(opts.get("out", ""))
	if out != "":
		DirAccess.make_dir_recursive_absolute(out.get_base_dir())
		var f := FileAccess.open(out, FileAccess.WRITE)
		f.store_string(JSON.stringify({"load_ms": load_ms, "rows": rows, "cols": ["dt", "process_ms", "baker_main_ms", "fog_main_ms", "mask_ms", "draw_ms", "bakes", "unpainted_fog", "unpainted_map", "render_cpu_ms", "render_gpu_ms", "busy", "draw_calls", "blank"]}))
		f.close()
	sb.call("shutdown")
	if mv != null:
		mv.bake_enabled = false
		mv.baker.clear()
	await process_frame
	quit(0)

# A serpentine over the whole map at zoom z: rows a view-height apart (a little overlap), alternating direction.
func _serpentine(map_px: Rect2, ctl, z: float) -> Array:
	var vs: Vector2 = ctl.view_size() / z
	var pts: Array = []
	var x0 := map_px.position.x + vs.x * 0.5 - 200.0
	var x1 := map_px.end.x - vs.x * 0.5 + 200.0
	if x1 < x0:
		x0 = map_px.get_center().x
		x1 = x0
	var y := map_px.position.y + vs.y * 0.5 - 200.0
	var ye := map_px.end.y - vs.y * 0.5 + 200.0
	var left := true
	var step := maxf(vs.y * 0.9, 1.0)
	while true:
		pts.append(Vector2(x0 if left else x1, y))
		pts.append(Vector2(x1 if left else x0, y))
		if y >= ye:
			break
		y = minf(y + step, ye)
		left = not left
	return pts

func _diagonals(map_px: Rect2) -> Array:
	return [map_px.position + map_px.size * 0.1, map_px.position + map_px.size * 0.9,
		map_px.position + Vector2(map_px.size.x * 0.9, map_px.size.y * 0.1), map_px.position + Vector2(map_px.size.x * 0.1, map_px.size.y * 0.9)]

# Pan through points at a constant screen speed at zoom z.
func _pan_route(ctl, pts: Array, z: float, speed_px_s: float) -> void:
	ctl.set_view(pts[0] if not pts.is_empty() else ctl.center(), z)
	await _frames(3)
	var t_last := Time.get_ticks_usec()
	for i in range(1, pts.size()):
		var target: Vector2 = pts[i]
		while ctl.center().distance_to(target) > 1.0:
			if _phase_over():
				return
			var now := Time.get_ticks_usec()
			var dt := minf((now - t_last) / 1e6, 0.1)
			t_last = now
			var step: float = speed_px_s * dt / z
			var to: Vector2 = target - ctl.center()
			var moved: Vector2 = to if to.length() <= step else to.normalized() * step
			ctl.set_view(ctl.center() + moved, z)
			await _frame()

# Zoom from the zoom-out limit to 1.5 and back in notches, about the view centre and about corners.
func _zoom_sweep(ctl, map_px: Rect2) -> void:
	var lim: float = ctl.zoom_limit_min()
	var anchors: Array = [ctl.view_size() * 0.5, ctl.view_size() * 0.2, ctl.view_size() * 0.8]
	ctl.set_view(map_px.get_center(), lim)
	await _frames(5)
	for a: Vector2 in anchors:
		for _n in 30:
			if ctl.zoom_level() >= 1.5 or _phase_over():
				break
			ctl.zoom_by(1.15, a)
			await _frames(6)
		for _n in 30:
			if ctl.zoom_level() <= lim * 1.01 or _phase_over():
				break
			ctl.zoom_by(1.0 / 1.15, a)
			await _frames(6)
		ctl.set_view(map_px.get_center() + Vector2(randf_range(-1, 1), randf_range(-1, 1)) * map_px.size * 0.3, ctl.zoom_level())

# A knob that redraws the map (the scale, the pen), with the camera still: the frames until the redraw note goes. The map
# and the contour layer are meant to keep showing what they showed (stale) until the new one is ready: BLANK stays 0.
func _knob_rebake(key: String, choice: int) -> void:
	var t0 := Time.get_ticks_msec()
	var dbg: Node = root.get_node("DebugSettings")   # (an autoload is not a compile-time name in a --script run)
	dbg.call("set_choice", key, choice)
	await _frames(3)
	while bool(sb.get("_rebaking")) and Time.get_ticks_msec() - t0 < 150000:
		await _frame()
	print("[pan] knob %s = %d: redrawn after %.1f s (the card said %.1f s)" % [key, choice, (Time.get_ticks_msec() - t0) / 1000.0, float(sb.get("last_rebake_s"))])
	await _frames(30)

# `n` turns played back with the camera still: ready, wait for the playback to end, a moment of planning. The frames of the
# playback are what a player watching the units fly gets while the background bake (if any) goes on.
func _playback_turns(n: int) -> void:
	for _i in n:
		sb.get("ui").press_ready()
		var t0 := Time.get_ticks_msec()
		await _frames(3)
		while sb.get("ui").is_playing() and Time.get_ticks_msec() - t0 < 40000:
			await _frame()
		await _frames(30)

# Zoomed out to the overview and panning a little at 0.1-0.2 across the map.
func _overview_route(ctl, map_px: Rect2, speed_px_s: float) -> void:
	for z: float in [0.2, 0.13, 0.09]:
		var pts: Array = [map_px.position + map_px.size * Vector2(0.2, 0.2), map_px.position + map_px.size * Vector2(0.8, 0.2),
			map_px.position + map_px.size * Vector2(0.8, 0.8), map_px.position + map_px.size * Vector2(0.2, 0.8)]
		await _pan_route(ctl, pts, z, speed_px_s)

# What a paused frame costs on the main thread in the parts this track owns, microseconds a call.
func _fixed_costs() -> void:
	var fog = sb.get("fog")
	var world = sb.get("world")
	var mv = sb.get("map_view")
	var n := 300
	var t0 := Time.get_ticks_usec()
	for _i in n:
		fog.vision.update_from_world(world, -1.0, "history")
	var a := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for _i in n:
		mv._schedule()
	var b := float(Time.get_ticks_usec() - t0) / n
	t0 = Time.get_ticks_usec()
	for _i in n:
		fog.update_mask(root.get_visible_rect().size)
	var c := float(Time.get_ticks_usec() - t0) / n
	var d := -1.0
	if mv.baker.pending() == 0:   # (a step swallows the chunks it finishes, so only when nothing is running)
		t0 = Time.get_ticks_usec()
		for _i in n:
			mv.baker.step(6000)
		d = float(Time.get_ticks_usec() - t0) / n
	print("[pan] paused frame, main thread, microseconds a call: vision.update_from_world %.0f, MapView._schedule %.0f, FogLayer.update_mask %.0f, baker.step (idle) %.0f" % [a, b, c, d])

# BAKES PER CHUNK (Alex: "we seem to be regenerating map sections we should already have"): how many times each map
# chunk and each fog chunk (per level of detail) finished a bake since the run began. Every static piece is meant
# to be baked ONCE and kept; "rebaked" lists those baked more than once. Stage runs: each worker stage (the map's
# layers: gather, terrain_sil, tree_sil, ground, linework) runs once per chunk bake. Sprites: tree sprites built,
# held at the end, and dropped by the cache cap.
func _report_bakes(tag: String) -> void:
	var mv = sb.get("map_view")
	var fog = sb.get("fog")
	var counts: Dictionary = mv.baker.bake_counts
	var total := 0
	var worst := 0
	for c in counts:
		total += int(counts[c])
		worst = maxi(worst, int(counts[c]))
	var re: Array = mv.baker.rebaked()
	var parts: Array[String] = []
	for e: Array in re.slice(0, 6):
		parts.append("%s x%d" % [e[0], e[1]])
	var runs: Array[String] = []
	for k: String in mv.baker.stage_runs:
		runs.append("%s %d" % [k, int(mv.baker.stage_runs[k])])
	print("[pan] bakes (%s): MAP %d chunk bakes of %d distinct chunks, most for one chunk %d, %d chunks baked more than once %s | stage runs: %s | tree sprites built %d, held %d, dropped by the cap %d" % [
		tag, total, counts.size(), worst, re.size(), "(" + ", ".join(parts) + ")" if not parts.is_empty() else "", ", ".join(runs),
		int(mv.baker.stats.sprites_built), mv.baker.sprite_count(), int(mv.baker.stats.get("sprites_evicted", 0))])
	var fc: Dictionary = fog.bake_counts
	var ftotal := 0
	var fworst := 0
	var per_lod := [0, 0, 0]
	var fre := 0
	var fparts: Array[String] = []
	for k: Vector3i in fc:
		ftotal += int(fc[k])
		fworst = maxi(fworst, int(fc[k]))
		per_lod[clampi(k.z, 0, 2)] += int(fc[k])
		if int(fc[k]) > 1:
			fre += 1
			if fparts.size() < 6:
				fparts.append("%s x%d" % [k, fc[k]])
	print("[pan] bakes (%s): FOG %d contour bakes of %d distinct (chunk, level) pieces, by level %s, most for one piece %d, %d pieces baked more than once %s" % [
		tag, ftotal, fc.size(), per_lod, fworst, fre, "(" + ", ".join(fparts) + ")" if not fparts.is_empty() else ""])

func _report_memory(tag: String) -> void:
	var vram := float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
	var tex := float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)) / 1048576.0
	var buf := float(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED)) / 1048576.0
	var stat := OS.get_static_memory_usage() / 1048576.0
	print("[pan] memory (%s): video %.0f MB (textures %.0f, buffers %.0f), static RAM %.0f MB, peak static %.0f MB" % [tag, vram, tex, buf, stat, OS.get_static_memory_peak_usage() / 1048576.0])

func _summary() -> void:
	for ph: String in rows:
		var rs: Array = rows[ph]
		if rs.size() < 2:
			continue
		var dts: Array = []
		var over33 := 0
		var over50 := 0
		var over100 := 0
		var un := 0
		var unfog := 0
		var unmap := 0
		var blank_frames := 0
		var bakes := 0
		var bm := 0.0
		var fm := 0.0
		for r: Array in rs:
			dts.append(float(r[0]))
			if r[0] > 33.4:
				over33 += 1
			if r[0] > 50.0:
				over50 += 1
			if r[0] > 100.0:
				over100 += 1
			if int(r[7]) > 0 or int(r[8]) > 0:
				un += 1
			if int(r[13]) > 0:
				blank_frames += 1
			if int(r[7]) > 0:
				unfog += 1
			if int(r[8]) > 0:
				unmap += 1
			bakes += int(r[6])
			bm += float(r[2])
			fm += float(r[3])
		dts.sort()
		var n := dts.size()
		var sum := 0.0
		for d: float in dts:
			sum += d
		print("[pan] %-9s %5d frames  mean %5.1f  median %5.1f  p95 %6.1f  p99 %6.1f  worst %7.1f ms | >33ms %4d  >50ms %4d  >100ms %3d | frames with paint-in: any %4d (fog %4d, map %4d), BLANK %4d | chunk bakes finished %3d, baker main %.0f ms, fog main %.0f ms" % [
			ph, n, sum / n, dts[n / 2], dts[int(n * 0.95)], dts[int(n * 0.99)], dts[n - 1], over33, over50, over100, un, unfog, unmap, blank_frames, bakes, bm, fm])
