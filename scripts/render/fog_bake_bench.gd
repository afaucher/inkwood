extends SceneTree

# THE FOG'S WHOLE-MAP BAKE ALONE (Track P, 2026-10-10): how long the contour map of the whole map takes at
# every level of detail with N recorder threads, with nothing else going on. A tool, not a test (windowed:
# the pipeline needs drawn frames).
#
#   INKWOOD_STEAM=off Godot_console.exe --path . --script res://scripts/render/fog_bake_bench.gd -- twins=1,2,4,8 inflight=16
#
# For each count: seconds until FogLayer.bake_complete(), the recording time the workers spent, the main
# thread's time in the pipeline, the frames it took and their worst, and the textures' memory.

const Terrain = preload("res://scripts/world/terrain.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")

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
	for ts in str(opts.get("twins", "1,2,4,8")).split(","):
		var vram0 := float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)) / 1048576.0
		var vp := SubViewport.new()
		vp.size = Vector2i(1280, 720)
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.disable_3d = true
		root.add_child(vp)
		var terrain := Terrain.new(20261009)
		var fog := FogLayer.new()
		fog.setup(terrain)
		fog.twin_count = int(ts)
		if opts.has("inflight"):
			fog.max_inflight = int(opts["inflight"])
		if opts.has("budget"):
			fog.main_budget_loading_ms = float(opts["budget"])
		fog.bake_boost = true
		var cam := Camera2D.new()
		vp.add_child(cam)
		vp.add_child(fog)
		cam.make_current()
		cam.position = terrain.map_rect_px().get_center()
		cam.zoom = Vector2(0.3, 0.3)
		var t0 := Time.get_ticks_msec()
		var frames := 0
		var worst := 0.0
		var last := Time.get_ticks_usec()
		var timeout := float(opts.get("timeout", "240"))
		while not fog.bake_complete() and (Time.get_ticks_msec() - t0) / 1000.0 < timeout:
			await process_frame
			frames += 1
			var now := Time.get_ticks_usec()
			worst = maxf(worst, (now - last) / 1000.0)
			last = now
		var secs := (Time.get_ticks_msec() - t0) / 1000.0
		var vram1 := float(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)) / 1048576.0
		print("[fogbench] twins %s inflight %d: %d chunks (%d levels) in %.1f s, %d frames (mean %.1f ms, worst %.1f ms); worker recording %.1f s in all (max %.1f ms); main thread %.0f ms in the pipeline (worst frame %.1f ms); textures +%.0f MB" % [
			ts, fog.max_inflight, fog.bake_total(), fog.topo.lods.size(), secs, frames, secs * 1000.0 / maxf(frames, 1), worst,
			float(fog._baker.stats.record_ms_sum) / 1000.0, float(fog._baker.stats.record_ms_max), float(fog.stats.main_ms), float(fog.stats.main_ms_max_frame), vram1 - vram0])
		fog.shutdown()
		vp.queue_free()
		await process_frame
		await process_frame
	quit(0)
