extends SceneTree

# THE LOOK PROBE (Track P, map and fog performance, 2026-10-10). A tool, not a test: it needs a window.
# Builds the REAL sandbox (the Strike), waits until every bake has finished, then saves the viewport at
# a few fixed views as PNGs. Run it on the code before a change and on the code after, then compare the
# two folders with scripts/render/look_compare.py (or by eye): a change that must not change the look
# (scheduling, caching, where the bakes run) leaves the pixels alone.
#
#   INKWOOD_STEAM=off Godot_console.exe --path . --script res://scripts/render/look_probe.gd -- size=1920x1080 out=tmp/perf/look_after
#
#   size=WxH     the window (default 1280x720)
#   out=DIR      where the PNGs go (default tmp/perf/look)
#   wait_s=N     longest wait for the bakes to finish, seconds (default 400)
#   hold_s=N     seconds to wait after they finish, so the hint card is gone (default 14)
#
# The views (centre in map px, zoom): the opening view, the village close up, the village mid-zoom,
# the fog's edge near a unit at play zoom, a far corner of the map under the fog, the whole-map overview.

var opts: Dictionary = {}
var sb: Node = null

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _busy() -> bool:
	var mv = sb.get("map_view")
	var fog = sb.get("fog")
	if mv.missing_in_view(true) > 0:
		return true
	if fog.bakes_in_flight() > 0:
		return true
	if fog.has_method("bake_complete") and not fog.bake_complete():
		return true
	var lod: int = fog.topo.lod_for_zoom(fog._zoom)
	return not fog.wanted_chunks(fog.view_rect_px(), lod).is_empty()

func _run() -> void:
	var sz := str(opts.get("size", "1280x720")).split("x")
	var size := Vector2i(int(sz[0]), int(sz[1]))
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(2)
	var script: Script = load("res://scripts/app/sandbox.gd")
	sb = script.new()
	root.add_child(sb)
	var t0 := Time.get_ticks_msec()
	while not bool(sb.get("is_playable")):
		await process_frame
		if Time.get_ticks_msec() - t0 > 900000:
			print("[look] TIMEOUT waiting for playable")
			break
	print("[look] playable after %d ms" % (Time.get_ticks_msec() - t0))
	var ctl = sb.get("ctl")
	var ui = sb.get("ui")
	var fog = sb.get("fog")
	var mv = sb.get("map_view")
	# the village and the units, in map px
	var ppm: float = mv.px_per_m
	var tower := Vector2(1000.0, 1500.0) * ppm
	var world = sb.get("world")
	for id: String in world.units:
		if str(id).begins_with("radio_tower"):
			var u = world.units[id]
			tower = Vector2(float(u.x), float(u.y)) * ppm
	var opening_c: Vector2 = ctl.center()
	var opening_z: float = ctl.zoom_level()
	var views: Array = [
		["opening", opening_c, opening_z],
		["village_close", tower, 1.0],
		["village_mid", tower, 0.5],
		["fog_edge", opening_c, 0.9],
		["far_corner", Vector2(8500.0, 8500.0), 0.35],
		["overview", Vector2(5000.0, 5000.0), 0.0],
	]
	# the densest wood within three terrain cells of the map's centre, at the planning zoom and at zoom 1 (to judge
	# whether trees repeat: Track P2's global tree set against a sprite per tree)
	var terrain = sb.get("terrain")
	var rc: Rect2i = terrain.map_chunk_range()
	var best := Vector2i(rc.position.x + rc.size.x / 2, rc.position.y + rc.size.y / 2)
	var best_n := -1
	for cy in range(best.y - 3, best.y + 4):
		for cx in range(best.x - 3, best.x + 4):
			var n: int = terrain.trees_in_chunk(cx, cy).size()
			if n > best_n:
				best_n = n
				best = Vector2i(cx, cy)
	var wood := (Vector2(best) + Vector2(0.5, 0.5)) * float(terrain.chunk_m) * ppm
	print("[look] densest wood: terrain cell %s, %d trees, at %s px" % [best, best_n, wood.round()])
	views.append(["forest_plan", wood, 0.3, "nofog"])
	views.append(["forest_close", wood, 1.0, "nofog"])
	# wait until nothing is baking (the old code bakes what the view needs, so look at each view in turn)
	var out_dir := str(opts.get("out", "tmp/perf/look"))
	DirAccess.make_dir_recursive_absolute(out_dir)
	var wait_s := float(opts.get("wait_s", "400"))
	var hold_s := float(opts.get("hold_s", "14"))
	for v: Array in views:
		var z: float = float(v[2]) if float(v[2]) > 0.0 else ctl.zoom_limit_min()
		if v.size() > 3:
			sb.call("_set_fog", false)   # the wood is out of sight: switch the fog off so the full render shows
		ctl.set_view(v[1], z)
		await _frames(3)
		var ts := Time.get_ticks_msec()
		var quiet := 0
		while quiet < 20 and (Time.get_ticks_msec() - ts) / 1000.0 < wait_s:
			await process_frame
			quiet = 0 if _busy() else quiet + 1
		var th := Time.get_ticks_msec()
		while (Time.get_ticks_msec() - th) / 1000.0 < hold_s:
			await process_frame
		await _frames(3)
		var img := root.get_texture().get_image()
		var path := "%s/%s.png" % [out_dir, str(v[0])]
		img.save_png(path)
		print("[look] %s: zoom %.3f centre %s, settled in %.1f s, saved %s (%dx%d)" % [v[0], ctl.zoom_level(), ctl.center().round(), (Time.get_ticks_msec() - ts) / 1000.0, path, img.get_width(), img.get_height()])
	sb.call("shutdown")
	if mv != null:
		mv.bake_enabled = false
		mv.baker.clear()
	await process_frame
	quit(0)
