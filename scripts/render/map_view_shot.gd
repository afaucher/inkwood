extends SceneTree

# A look at the map view (Track V), without main.gd. WINDOWED ONLY -- under
# --headless nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/render/map_view_shot.gd -- 20261009 tmp/mapview
#
# Optional key=value after the two: provider=terrain|scene, pool=1 (tree
# pool on), ppm=<px per metre; default data/terrain/terrain.json's>,
# at=<x>,<y> (metres: the zoom-1 spot; default a scarp near the centre),
# only=zoom1 (stop after the first view),
# what=views|pen|pool|all (default views), pan_s=<seconds of the pan run,
# default 20>, pan_m_s=<metres per second, default 100: a fighter's 500 m per
# 5 s turn>.
#
# what=views writes, through a 1280x720 SubViewport holding a MapView:
#   view_zoom1.png      zoom 1 on a scarp near the map centre (cold bake)
#   view_border.png     zoom 1 centred on a chunk corner: two borders cross the
#                       middle of the frame and must not show (seam metric printed)
#   view_zoomed_out.png the furthest zoom allowed (map_view.zoom.min)
# and runs a PAN at pan_m_s for pan_s seconds from the border view, printing
# how long and how much of the view was ever unbaked, and the worst frame.
# what=pen writes pen_side_by_side.png: a tree stand, the fort and a terrain
# scarp at zoom 1, the even pen (left) against the shadow-side pen (right).
# what=pool writes pool_side_by_side.png: per-tree sprites (left) against the
# tree pool (right), and the bake timings of both.
# what=scale switches ONE MapView through 1, 2, 3 and 4 px/m at runtime
# (set_px_per_m: a rebake, no restart), over the same metres, writing
# scale_<n>.png and the time each took to fill the view.

const MapView = preload("res://scripts/render/map_view.gd")
const ChunkBaker = preload("res://scripts/render/chunk_baker.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")
const ChunkSceneProvider = preload("res://scripts/render/chunk_scene_provider.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

const SIZE := Vector2i(1280, 720)

var out_dir := "tmp/mapview"
var seed_value := 20261009
var opts: Dictionary = {}

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[map-view-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		seed_value = int(args[0])
	if args.size() > 1:
		out_dir = args[1]
	for i in range(2, args.size()):
		var kv := args[i].split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()

func _run() -> void:
	var what := str(opts.get("what", "views"))
	var code := 0
	if what == "views" or what == "all":
		code = maxi(code, await _views())
	if what == "pen" or what == "all":
		code = maxi(code, await _pen())
	if what == "pool" or what == "all":
		code = maxi(code, await _pool())
	if what == "scale" or what == "all":
		code = maxi(code, await _scale())
	quit(code)

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

# --- views ---------------------------------------------------------------------------------

func _make_view(kind: String, pool: bool) -> Array:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	root.add_child(vp)
	var P := RenderParams.new()
	var view = MapView.new(seed_value, Rect2(), float(opts.get("ppm", "0")), kind, P)
	view.input_enabled = false
	if pool:
		view.baker.pool_enabled = true
	vp.add_child(view)
	return [vp, view]

var last_visible_s := 0.0   # when the view itself was complete (prefetch may still be baking)

func _wait_complete(view, max_s: float) -> float:
	var t0 := Time.get_ticks_msec()
	last_visible_s = -1.0
	await _frames(2)
	while view.missing_in_view() > 0 or view.pending() > 0:
		if last_visible_s < 0.0 and view.missing_in_view() == 0:
			last_visible_s = (Time.get_ticks_msec() - t0) / 1000.0
		if (Time.get_ticks_msec() - t0) / 1000.0 > max_s:
			printerr("[map-view-shot] view not complete after %.0f s (%d missing, %d pending)" % [max_s, view.missing_in_view(), view.pending()])
			printerr(view.baker.debug_state())
			break
		await process_frame
	var s := (Time.get_ticks_msec() - t0) / 1000.0
	if last_visible_s < 0.0:
		last_visible_s = s
	await _frames(3)
	return s

func _save(vp: SubViewport, name: String) -> Image:
	var img := vp.get_texture().get_image()
	var path := out_dir.path_join(name)
	img.save_png(path)
	print("[map-view-shot] saved ", path)
	return img

func _views() -> int:
	var kind := str(opts.get("provider", ""))
	var pool := str(opts.get("pool", "0")) == "1"
	var made := _make_view(kind, pool)
	var vp: SubViewport = made[0]
	var view = made[1]
	if not view.errors().is_empty():
		printerr("[map-view-shot] errors: ", view.errors())
		return 1
	print("[map-view-shot] provider %s, %s px/m, map %s m = %s px, chunks of %d px, pool %s, pen %s" % [
		view.provider_kind, view.px_per_m, view.bounds_m.size, view.map_rect().size, view.chunk_px, pool, InkCanvas.pen_mode()])
	var spot := _find_spot(view)
	if opts.has("at"):
		var xy: PackedStringArray = str(opts["at"]).split(",")
		spot = Vector2(float(xy[0]), float(xy[1]))
	print("[map-view-shot] zoom-1 spot (m) ", spot)
	view.look_at_m(spot)
	view.set_zoom(1.0)
	var t_cold := await _wait_complete(view, 120.0)
	_report("zoom 1, cold", view, t_cold)
	print("[map-view-shot] view rect %s px, %d chunks shown, %d missing in view" % [view.view_rect(), view.chunk_count(), view.missing_in_view()])
	_save(vp, "view_zoom1.png")
	if str(opts.get("only", "")) == "zoom1":
		vp.queue_free()
		await _frames(2)
		return 0

	# A chunk corner in the middle of the frame.
	var cpx: float = view.chunk_px
	var corner: Vector2 = (view.camera.position / cpx).round() * cpx
	view.baker.reset_stats()
	view.look_at_m(view.map_to_m(corner))
	var t_border := await _wait_complete(view, 120.0)
	_report("border view", view, t_border)
	var img := _save(vp, "view_border.png")
	_seam_metric(img)

	# The pan: a fighter's turn animation, from the border view eastward.
	var pan_s := float(opts.get("pan_s", "20"))
	var speed: float = float(opts.get("pan_m_s", "100")) * view.px_per_m
	view.baker.reset_stats()
	last_visible_s = 0.0
	var t0 := Time.get_ticks_usec()
	var last := t0
	var missing_time := 0.0
	var worst_gap := 0.0
	var gap := 0.0
	var worst_frame := 0.0
	var max_missing := 0
	var frames := 0
	while (Time.get_ticks_usec() - t0) / 1e6 < pan_s:
		await process_frame
		var now := Time.get_ticks_usec()
		var dt := (now - last) / 1e6
		last = now
		frames += 1
		worst_frame = maxf(worst_frame, dt)
		view.camera.position.x += speed * dt
		var miss: int = view.missing_in_view()
		max_missing = maxi(max_missing, miss)
		if miss > 0:
			missing_time += dt
			gap += dt
			worst_gap = maxf(worst_gap, gap)
		else:
			gap = 0.0
	print("[map-view-shot] PAN %.0f px/s (%s m/s) for %.0f s at zoom 1: %d frames, worst frame %.0f ms, view incomplete %.1f s in all (%.0f%%), longest stretch %.1f s, at most %d chunks missing" % [
		speed, opts.get("pan_m_s", "100"), pan_s, frames, worst_frame * 1000.0, missing_time, 100.0 * missing_time / pan_s, worst_gap, max_missing])
	_report("pan", view, pan_s)

	view.baker.reset_stats()
	view.look_at_m(view.bounds_m.get_center())
	view.set_zoom(view.zoom_min)
	var t_out := await _wait_complete(view, 600.0)
	_report("zoom %.2f, view of %s px" % [view.zoom_min, view.view_rect().size], view, t_out)
	_save(vp, "view_zoomed_out.png")
	vp.queue_free()
	await _frames(2)
	return 0

func _report(label: String, view, seconds: float) -> void:
	var s: Dictionary = view.baker.stats
	var n: int = s.chunks
	print("[map-view-shot] %s: view complete %.1f s, with prefetch %.1f s; %d chunks baked (mean %.0f ms, max %.0f ms from request to texture), %d sprites in %d pages (%.0f ms of worker recording), main thread %.0f ms in all, worst frame %.1f ms" % [
		label, last_visible_s, seconds, n, s.chunk_ms_total / maxf(1.0, n), s.chunk_ms_max, s.sprites_built, s.pages, s.page_record_ms,
		s.main_ms, s.main_ms_max_frame])
	var parts: Array[String] = []
	for k: String in s.stage_ms:
		parts.append("%s %.0f" % [k, s.stage_ms[k]])
	print("[map-view-shot]   main-thread stage ms: ", ", ".join(parts))
	parts.clear()
	for k: String in s.worker_ms:
		parts.append("%s %.0f" % [k, s.worker_ms[k]])
	print("[map-view-shot]   worker stage ms: ", ", ".join(parts))

# A point (metres) near the map centre with a level boundary close by, so the
# zoom-1 frame shows terrain; the centre for a provider without terrain.
func _find_spot(view) -> Vector2:
	var centre: Vector2 = view.bounds_m.get_center()
	if not view.provider is ChunkTerrainProvider:
		return centre
	var terrain = view.provider.terrain
	var best := centre
	for ring in range(0, 40):
		for k in 16:
			var a := k * TAU / 16.0
			var p := centre + Vector2(cos(a), sin(a)) * ring * 40.0
			var l0: int = terrain.level_at(p.x, p.y)
			var l1: int = terrain.level_at(p.x + 60.0, p.y + 60.0)
			if l0 != l1:
				return p
	return best

# Seams: the mean colour step across the two chunk borders in the middle of
# the frame against the mean step between neighbouring columns / rows anywhere.
func _seam_metric(img: Image) -> void:
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var cx := w / 2
	var cy := h / 2
	var step := func(ax: int, ay: int, bx: int, by: int) -> float:
		var a := img.get_pixel(ax, ay)
		var b := img.get_pixel(bx, by)
		return (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) * 255.0 / 3.0
	var seam_v := 0.0
	var other_v := 0.0
	for y in h:
		seam_v += step.call(cx - 1, y, cx, y)
		other_v += step.call(cx - 101, y, cx - 100, y) + step.call(cx + 100, y, cx + 101, y)
	var seam_h := 0.0
	var other_h := 0.0
	for x in w:
		seam_h += step.call(x, cy - 1, x, cy)
		other_h += step.call(x, cy - 101, x, cy - 100) + step.call(x, cy + 100, x, cy + 101)
	print("[map-view-shot] SEAM: vertical border step %.2f levels/px vs %.2f elsewhere; horizontal %.2f vs %.2f" % [
		seam_v / h, other_v / (2.0 * h), seam_h / w, other_h / (2.0 * w)])

# --- side-by-sides --------------------------------------------------------------------------

# Bakes one chunk through a fresh baker and returns its image.
func _bake_chunk(kind: String, c: Vector2i, pool: bool) -> Image:
	var P := RenderParams.new()
	var cfg := MapView.load_config(P.source_path)
	var provider: RefCounted
	if kind == "scene":
		provider = ChunkSceneProvider.new(seed_value, P, cfg)
	else:
		provider = ChunkTerrainProvider.new(seed_value, P, cfg)
	var baker := ChunkBaker.new(provider, P, cfg)
	baker.pool_enabled = pool
	baker.request(c, 0.0)
	var t0 := Time.get_ticks_msec()
	while true:
		await process_frame
		for r: Dictionary in baker.step(50000):
			var img: Image = (r.texture as ImageTexture).get_image()
			img.clear_mipmaps()
			print("[map-view-shot] baked %s chunk %s (pool %s, pen %s) in %.1f s: %d sprites in %d pages, %.0f ms worker recording" % [
				kind, c, pool, InkCanvas.pen_mode(), (Time.get_ticks_msec() - t0) / 1000.0, baker.stats.sprites_built,
				baker.stats.pages, baker.stats.page_record_ms])
			return img
	return null

# A chunk of the scene provider with a fort in it, near the map centre.
func _fort_chunk() -> Vector2i:
	var P := RenderParams.new()
	var prov := ChunkSceneProvider.new(seed_value, P, MapView.load_config(P.source_path))
	for ring in range(0, 8):
		for cy in range(9 - ring, 10 + ring):
			for cx in range(9 - ring, 10 + ring):
				var o: Dictionary = prov.objects(Vector2i(cx, cy))
				for s: Dictionary in o.structs:
					if s.kind == "wall":
						return Vector2i(cx, cy)
	return Vector2i(9, 9)

func _terrain_chunk() -> Array:
	var P := RenderParams.new()
	var prov := ChunkTerrainProvider.new(seed_value, P, MapView.load_config(P.source_path))
	var t = prov.terrain
	var centre := Vector2(t.map_x + t.map_w * 0.5, t.map_y + t.map_h * 0.5)
	for ring in range(0, 60):
		for k in 24:
			var a := k * TAU / 24.0
			var p := centre + Vector2(cos(a), sin(a)) * ring * 30.0
			if t.level_at(p.x, p.y) != t.level_at(p.x + 40.0, p.y + 40.0):
				var px: Vector2 = p * float(t.px_per_m)
				var c := Vector2i(floori(px.x / prov.chunk_px), floori(px.y / prov.chunk_px))
				return [c, px - Vector2(c * prov.chunk_px)]
	return [Vector2i(9, 9), Vector2(512, 512)]

static func _crop(img: Image, centre: Vector2, size: Vector2i) -> Image:
	var r := Rect2i(Vector2i(centre) - size / 2, size)
	r.position = r.position.clamp(Vector2i.ZERO, img.get_size() - size)
	return img.get_region(r)

static func _side_by_side(rows: Array, scale: int) -> Image:
	var w := 0
	var h := 0
	for row: Array in rows:
		var a: Image = row[0]
		w = maxi(w, a.get_width() * scale * 2 + 8)
		h += a.get_height() * scale + 8
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.15, 0.15, 0.15))
	var y := 0
	for row: Array in rows:
		for k in 2:
			var im: Image = (row[k] as Image).duplicate()
			im.convert(Image.FORMAT_RGBA8)
			im.resize(im.get_width() * scale, im.get_height() * scale, Image.INTERPOLATE_NEAREST)
			out.blit_rect(im, Rect2i(Vector2i.ZERO, im.get_size()), Vector2i(k * (im.get_width() + 8), y))
		y += (row[0] as Image).get_height() * scale + 8
	return out

func _pen() -> int:
	var fort := _fort_chunk()
	var tc: Array = _terrain_chunk()
	var rows: Array = []
	var images := {}
	for mode: String in ["even", "shadow_side"]:
		InkCanvas.set_pen_mode(mode)
		images[mode] = [await _bake_chunk("scene", fort, false), await _bake_chunk("terrain", tc[0], false)]
	InkCanvas.set_pen_mode(str(InkCanvas._load_pen().get("mode", "shadow_side")))
	var fort_centre := _struct_centre(fort)
	rows.append([_crop(images.even[0], fort_centre, Vector2i(420, 300)), _crop(images.shadow_side[0], fort_centre, Vector2i(420, 300))])
	var stand := _tree_stand(images.even[0])
	rows.append([_crop(images.even[0], stand, Vector2i(420, 240)), _crop(images.shadow_side[0], stand, Vector2i(420, 240))])
	rows.append([_crop(images.even[1], tc[1], Vector2i(420, 240)), _crop(images.shadow_side[1], tc[1], Vector2i(420, 240))])
	var out := _side_by_side(rows, 2)
	var path := out_dir.path_join("pen_side_by_side.png")
	out.save_png(path)
	print("[map-view-shot] saved ", path, " (rows: fort, tree stand, terrain scarp; left even, right shadow side)")
	return 0

func _struct_centre(c: Vector2i) -> Vector2:
	var P := RenderParams.new()
	var prov := ChunkSceneProvider.new(seed_value, P, MapView.load_config(P.source_path))
	for s: Dictionary in prov.objects(c).structs:
		if s.kind == "wall":
			return Vector2(s.bx + s.bw * 0.5, s.by + s.bh * 0.5) - Vector2(c * prov.chunk_px)
	return Vector2(512, 512)

# The densest 420x240 window of trees in a baked chunk (darkest mean -- trees
# and their shadows), on a coarse grid.
static func _tree_stand(img: Image) -> Vector2:
	var best := Vector2(512, 512)
	var best_v := INF
	for gy in range(140, 900, 64):
		for gx in range(220, 820, 64):
			var r := img.get_region(Rect2i(gx - 210, gy - 120, 420, 240))
			r.resize(42, 24, Image.INTERPOLATE_BILINEAR)
			var v := 0.0
			for y in 24:
				for x in 42:
					v += r.get_pixel(x, y).get_luminance()
			if v < best_v:
				best_v = v
				best = Vector2(gx, gy)
	return best

func _pool() -> int:
	var tc: Array = _terrain_chunk()
	var a := await _bake_chunk("terrain", tc[0], false)
	var b := await _bake_chunk("terrain", tc[0], true)
	var stand := _tree_stand(a)
	var rows := [[_crop(a, stand, Vector2i(420, 240)), _crop(b, stand, Vector2i(420, 240))],
		[_crop(a, tc[1], Vector2i(420, 240)), _crop(b, tc[1], Vector2i(420, 240))]]
	var path := out_dir.path_join("pool_side_by_side.png")
	_side_by_side(rows, 2).save_png(path)
	var full := Image.create(2056, 1024, false, Image.FORMAT_RGBA8)
	a.convert(Image.FORMAT_RGBA8)
	b.convert(Image.FORMAT_RGBA8)
	full.fill(Color(0.15, 0.15, 0.15))
	full.blit_rect(a, Rect2i(0, 0, 1024, 1024), Vector2i(0, 0))
	full.blit_rect(b, Rect2i(0, 0, 1024, 1024), Vector2i(1032, 0))
	full.save_png(out_dir.path_join("pool_chunk_full.png"))
	print("[map-view-shot] saved ", path, " (left per-tree sprites, right the pool)")
	return 0

func _scale() -> int:
	var made := _make_view(str(opts.get("provider", "")), str(opts.get("pool", "0")) == "1")
	var vp: SubViewport = made[0]
	var view = made[1]
	var spot := _find_spot(view)
	view.look_at_m(spot)
	view.set_zoom(1.0)
	for ppm: float in [2.0, 1.0, 3.0, 4.0, 2.0]:
		view.baker.reset_stats()
		view.set_px_per_m(ppm)
		view.set_zoom(1.0)
		var t := await _wait_complete(view, 180.0)
		var centre_m: Vector2 = view.screen_to_world(Vector2(SIZE) * 0.5)
		print("[map-view-shot] SCALE %s px/m: view complete %.1f s (with prefetch %.1f s), %d chunks, centre still %s m (asked %s)" % [
			ppm, last_visible_s, t, view.baker.stats.chunks, centre_m.round(), spot.round()])
		_save(vp, "scale_%d.png" % int(ppm))
	vp.queue_free()
	await _frames(2)
	return 0
