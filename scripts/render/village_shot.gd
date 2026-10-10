extends SceneTree

# A LOOK AT THE VILLAGE (Track W, 2026-10-10), through the real map: the world layout's village
# baked by the game's own MapView and photographed at native size. WINDOWED ONLY -- under
# --headless nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/render/village_shot.gd -- 20261009 tmp/village
#
# Optional key=value after the two: style=rows|hedgerow|stipple|mixed (the fields' look; default
# the data's working default), what=shots|board (default shots), ppm=<px per metre>.
#
# what=shots writes, 1280 x 720, native size, into the output folder:
#   village_play.png      the village at PLAY zoom (0.35: the camera's start zoom, a planning view)
#   village_far.png       the village at FAR zoom (0.2: the full render, a little above where the
#                         topographic overview takes over, data/view/camera.json far_zoom)
#   village_close.png     zoom 1.0 on the village: houses, the compound, the road, trees, fields
#   village_compound.png  zoom 2.0 (the furthest the camera allows) on the radio tower's compound
#   village_road.png      zoom 1.0 on the road a few hundred metres out of the village
#   village_fields.png    zoom 1.0 on the fields beside the village
# what=board is scripts/render/fields_board.gd's: this file holds the shared helpers it uses.
#
# A frame is baked by requesting exactly the chunks the view shows (no prefetch ring) and
# photographing the SubViewport when they are all in.

const MapView = preload("res://scripts/render/map_view.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

const SIZE := Vector2i(1280, 720)
const PLAY_ZOOM := 0.35
const FAR_ZOOM := 0.2

var out_dir := "tmp/village"
var seed_value := 20261009
var opts: Dictionary = {}

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[village-shot] needs a windowed run: under --headless nothing is drawn")
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

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _run() -> void:
	var code := await _shots()
	quit(code)

# --- helpers (shared with fields_board.gd) ----------------------------------------------------------

# A SubViewport of SIZE holding a MapView that bakes only what we ask for.
static func make_view(tree_root: Node, seed_v: int, ppm: float, style: String) -> Array:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	tree_root.add_child(vp)
	var view = MapView.new(seed_v, Rect2(), ppm, "terrain", RenderParams.new())
	view.input_enabled = false
	view.bake_enabled = false
	if style != "":
		view.provider.vd.style = style
	vp.add_child(view)
	return [vp, view]

# Bakes every chunk the view shows (the camera and zoom already set) and returns the seconds. The
# camera's transform only takes hold a frame after it moves, so the chunks wanted are worked out
# again every frame and the missing ones requested (once each).
func bake_view(view) -> float:
	var t0 := Time.get_ticks_msec()
	await _frames(3)
	var last_report := t0
	var asked := 0
	while true:
		var r: Rect2 = view.view_rect().intersection(view.map_rect())
		var cp: int = view.chunk_px
		var centre: Vector2 = view.view_rect().get_center() / float(cp)
		for cy in range(floori(r.position.y / cp), floori((r.end.y - 0.001) / cp) + 1):
			for cx in range(floori(r.position.x / cp), floori((r.end.x - 0.001) / cp) + 1):
				var c := Vector2i(cx, cy)
				if not view.has_chunk(c) and not view.baker.is_busy(c):
					view.baker.request(c, (Vector2(c) + Vector2(0.5, 0.5)).distance_to(centre), true)
					asked += 1
		for res: Dictionary in view.baker.step(8000):
			view._show(res.c, res.texture)
		if view.missing_in_view() == 0:
			break
		await process_frame
		if Time.get_ticks_msec() - last_report > 15000:
			last_report = Time.get_ticks_msec()
			print("[village-shot] ... %d chunks still missing after %.0f s: %s" % [view.missing_in_view(), (last_report - t0) / 1000.0, view.baker.debug_state()])
		if Time.get_ticks_msec() - t0 > 400000:
			printerr("[village-shot] bake did not finish: ", view.baker.debug_state())
			break
	await _frames(4)
	print("[village-shot] %d chunks baked for this view in %.1f s" % [asked, (Time.get_ticks_msec() - t0) / 1000.0])
	return (Time.get_ticks_msec() - t0) / 1000.0

func save_frame(vp: SubViewport, path: String) -> Image:
	var img := vp.get_texture().get_image()
	img.save_png(path)
	print("[village-shot] saved ", path)
	return img

func look(view, p_m: Vector2, zoom: float) -> void:
	view.set_zoom(zoom)
	view.look_at_m(p_m)

# --- the shots ----------------------------------------------------------------------------------------

func _shots() -> int:
	var style := str(opts.get("style", ""))
	var made := make_view(root, seed_value, float(opts.get("ppm", "0")), style)
	var vp: SubViewport = made[0]
	var view = made[1]
	if not view.errors().is_empty():
		printerr("[village-shot] errors: ", view.errors())
		return 1
	var layout = view.provider.terrain.layout()
	if not layout.ok():
		printerr("[village-shot] layout errors: ", layout.errors)
		return 1
	var v: Dictionary = layout.village()
	var sites: Dictionary = layout.sites()
	var tower: Vector2 = sites.radio_tower
	print("[village-shot] seed %d, style %s: village at %s, tower %s, %d fields, road %d points, layout built in %.0f ms" % [
		seed_value, view.provider.vd.style, v.centre, tower, layout.field_count(), layout.road().size(), layout.diagnostics.get("build_ms", 0.0)])
	await _frames(3)
	# FAR first: it bakes the most chunks, and the closer frames need none of their own
	look(view, v.centre, FAR_ZOOM)
	var s_far := await bake_view(view)
	print("[village-shot] far view baked in %.1f s" % s_far)
	save_frame(vp, out_dir.path_join("village_far.png"))
	look(view, v.centre, PLAY_ZOOM)
	await bake_view(view)
	save_frame(vp, out_dir.path_join("village_play.png"))
	look(view, v.centre, 1.0)
	await bake_view(view)
	save_frame(vp, out_dir.path_join("village_close.png"))
	look(view, tower, 2.0)
	await bake_view(view)
	save_frame(vp, out_dir.path_join("village_compound.png"))
	# the road a little way out: the point of the road about 450 m from the village's centre
	var road: PackedVector2Array = layout.road()
	var at := road[road.size() / 2]
	for p in road:
		if p.distance_to(v.centre) > 450.0:
			at = p
			break
	look(view, at, 1.0)
	await bake_view(view)
	save_frame(vp, out_dir.path_join("village_road.png"))
	# fields: the nearest field's middle
	var fields: Array[PackedVector2Array] = layout.fields()
	if not fields.is_empty():
		var best := 0
		var best_d := INF
		for i in fields.size():
			var c := Vector2.ZERO
			for q in fields[i]:
				c += q
			c /= 4.0
			var d := c.distance_to(v.centre)
			if d < best_d:
				best_d = d
				best = i
		var fc := Vector2.ZERO
		for q in fields[best]:
			fc += q
		look(view, fc / 4.0, 1.0)
		await bake_view(view)
		save_frame(vp, out_dir.path_join("village_fields.png"))
	vp.queue_free()
	await _frames(2)
	return 0
