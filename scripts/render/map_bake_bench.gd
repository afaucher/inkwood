extends SceneTree

# THE MAP'S BAKE ALONE (Track P2, 2026-10-10): how long the ground, structures and trees of the map's chunks take,
# with the global tree set (map_view.tree_pool) on and off, with nothing else going on (no fog, no units, no UI).
# A tool, not a test (windowed: the bake needs drawn frames).
#
#   INKWOOD_STEAM=off Godot_console.exe --path . --script res://scripts/render/map_bake_bench.gd -- pool=on chunks=all
#
#   pool=on|off     the global tree set (on: made first, then every chunk stamps sprites from it) or a sprite per tree
#   chunks=all|N    every chunk of the map, or the N nearest the map's centre (default 21: the sandbox's first view)
#   variants=N      override tree_pool.variants (the size of the set is variants x the buckets)
#   boost=1         the loading card's budget (map_view.bake_budget_loading_ms, 14 ms a frame; the default)
#   timeout=S       give up after S seconds (default 900)
#
# Prints the seconds until the set was made, until the first chunk, until every chunk asked for, the mean chunk time
# (a job's first stage to its texture, so it includes waiting for a worker), the workers' time by stage, the main
# thread's time in the baker and its worst frame, the sprites built and held, and the video memory taken.

const MapView = preload("res://scripts/render/map_view.gd")

var opts: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	root.size = Vector2i(1280, 720)
	await process_frame
	await process_frame
	var vram0 := float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	root.add_child(vp)
	var view = MapView.new(20261009, Rect2(), 0.0, "terrain")
	view.input_enabled = false
	view.bake_enabled = false   # (this tool asks for the chunks itself)
	var pool_on := str(opts.get("pool", "on")) == "on"
	var tp: Dictionary = view.cfg.get("tree_pool", {})
	tp["enabled"] = pool_on
	if opts.has("variants"):
		tp["variants"] = int(opts["variants"])
	view.baker.apply_config(view.cfg)
	vp.add_child(view)
	var mr: Rect2 = view.map_rect()
	var cp: float = view.chunk_px
	var all: Array = []
	for cy in range(floori(mr.position.y / cp), ceili(mr.end.y / cp)):
		for cx in range(floori(mr.position.x / cp), ceili(mr.end.x / cp)):
			all.append(Vector2i(cx, cy))
	var centre := mr.get_center() / cp
	all.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return (Vector2(a) + Vector2(0.5, 0.5)).distance_to(centre) < (Vector2(b) + Vector2(0.5, 0.5)).distance_to(centre))
	var want: int = all.size() if str(opts.get("chunks", "21")) == "all" else mini(int(opts.get("chunks", "21")), all.size())
	var set_n := 0
	if pool_on:
		set_n = view.prebuild_pool()
	for i in want:
		view.baker.request(all[i], float(i), true)
	var t0 := Time.get_ticks_msec()
	var timeout := float(opts.get("timeout", "900"))
	var t_set := -1.0
	var t_first := -1.0
	var frames := 0
	var worst := 0.0
	var last := Time.get_ticks_usec()
	var budget_us := int(float(view.cfg.get("bake_budget_loading_ms", 14.0)) * 1000.0)
	while (view.chunk_count() < want) and (Time.get_ticks_msec() - t0) / 1000.0 < timeout:
		await process_frame
		frames += 1
		var now := Time.get_ticks_usec()
		worst = maxf(worst, (now - last) / 1000.0)
		last = now
		for r: Dictionary in view.baker.step(budget_us):
			view._show(r.c, r.texture)
		if t_set < 0.0 and pool_on and view.baker.pool_ready():
			t_set = (Time.get_ticks_msec() - t0) / 1000.0
		if t_first < 0.0 and view.chunk_count() > 0:
			t_first = (Time.get_ticks_msec() - t0) / 1000.0
	var secs := (Time.get_ticks_msec() - t0) / 1000.0
	var st: Dictionary = view.baker.stats
	var chunks := int(st.chunks)
	var wk: Dictionary = st.worker_ms
	var parts: Array[String] = []
	for k: String in wk:
		parts.append("%s %.1f" % [k, float(wk[k]) / 1000.0])
	var vram1 := float(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)) / 1048576.0
	print("[mapbench] pool %s%s: %d chunks in %.1f s (first chunk %.1f s, tree set made %.1f s); mean job %.0f ms, max %.0f ms; %d frames (mean %.1f ms, worst %.1f ms)" % [
		"on" if pool_on else "off", " (%d trees)" % set_n if pool_on else "", chunks, secs, t_first, t_set, float(st.chunk_ms_total) / maxf(chunks, 1), float(st.chunk_ms_max), frames, secs * 1000.0 / maxf(frames, 1), worst])
	print("[mapbench]   worker threads, seconds in all, by stage: %s | sprite pages %d, sprites built %d, held %d, recording %.1f s" % [
		", ".join(parts), int(st.pages), int(st.sprites_built), view.baker.sprite_count(), float(st.page_record_ms) / 1000.0])
	print("[mapbench]   main thread in the baker %.1f s (worst frame %.1f ms); video memory +%.0f MB" % [float(st.main_ms) / 1000.0, float(st.main_ms_max_frame), vram1 - vram0])
	view.baker.clear()
	vp.queue_free()
	await process_frame
	quit(0)
