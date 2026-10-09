extends SceneTree

# A look at the fog of war and the zoom (Track F, first option) without
# touching main.gd. WINDOWED ONLY -- under --headless the renderer is a dummy:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/render/fog_shot.gd -- [key=value ...]
#
# Writes tmp/fog/*.png (1280 x 720), each the real compositor (fog_layer.gd,
# its mask and composite shaders, fog_topo.gd's baked chunks) under a
# CameraController-driven Camera2D, over a STAND-IN for Track V's MapView: a
# full render of the same spot made by Track T's terrain_shot.gd (run as a
# child process the first time, cached in tmp/fog/cache by seed, scale, spot
# and zoom). Units are Track S's World units; their markers here are
# STAND-INS (an accent disc in an ink ring), as is the one target marker in
# the fog layer's marker slot (an ink diamond).
#
#   fog_z1_inked / fog_z1_soft       zoom 1 on the spot where two units' vision
#                                    edges cross: both edge treatments
#   fog_wide_inked / fog_wide_soft   the same spot zoomed out (zoom= , 0.25)
#   fog_overview                     the zoom-out limit (fit_map): the far-zoom
#                                    overview, topographic everywhere with the
#                                    vision edges on it
#   fog_short_sight                  vision.sight_range_scale 0.3 at the wide zoom:
#                                    a shorter sight radius, whole circles in view
#   fog_topo_only                    no vision at all at the wide zoom: the bare map
#
# Options: seed=<n> x=<m> y=<m> (the spot, metres) zoom=<wide zoom> only=<name,...>
# Prints timings (topographic chunk bakes per level of detail, a whole-map
# overview bake, per-frame CPU and GPU cost of the fog) and checks the GPU
# mask against fog_vision.gd's CPU formula at sample pixels.

const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const World = preload("res://scripts/sim/world.gd")
const CameraController = preload("res://scripts/world/camera_controller.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")
const FogTopo = preload("res://scripts/render/fog_topo.gd")

const SIZE := Vector2i(1280, 720)
const SPOT_M := Vector2(2519.6, 3389.1)   # a lee-facing scarp near the map centre (terrain_shot's pick)
const WIDE_ZOOM := 0.25

# Stand-in markers: a disc in an ink ring, constant screen size.
class Marks extends Node2D:
	var items: Array = []     # [{p: Vector2 map px, fill: Color, kind: "unit"|"target"}]
	var ink: Color
	var zoom := 1.0
	func _draw() -> void:
		for it: Dictionary in items:
			var r := 7.0 / zoom
			var p: Vector2 = it.p
			if it.kind == "target":
				var pts := PackedVector2Array([p + Vector2(0, -r * 1.4), p + Vector2(r * 1.4, 0), p + Vector2(0, r * 1.4), p + Vector2(-r * 1.4, 0), p + Vector2(0, -r * 1.4)])
				draw_colored_polygon(pts, it.fill)
				draw_polyline(pts, ink, 1.6 / zoom, true)
			else:
				draw_circle(p, r, it.fill, true, -1.0, true)
				draw_arc(p, r, 0.0, TAU, 32, ink, 1.6 / zoom, true)

var terrain: Terrain
var P: RenderParams
var vp: SubViewport
var cam: Camera2D
var ctl: CameraController
var fog: FogLayer
var backdrop: Sprite2D
var full: Sprite2D
var live: Marks
var target: Marks
var world: World
var opts := {}
var out_dir := ""

func _initialize() -> void:
	_main()

func _main() -> void:
	var code := await _run()
	quit(code)

func _run() -> int:
	if DisplayServer.get_name() == "headless":
		printerr("[fog-shot] needs a windowed run: under --headless nothing is drawn")
		return 1
	await process_frame   # the root is in the tree from the first frame on
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	var seed_value := int(opts.get("seed", "20261009"))
	var spot := Vector2(float(opts.get("x", str(SPOT_M.x))), float(opts.get("y", str(SPOT_M.y))))
	var wide := float(opts.get("zoom", str(WIDE_ZOOM)))
	var only: PackedStringArray = str(opts.get("only", "")).split(",", false)
	out_dir = ProjectSettings.globalize_path("res://tmp/fog")
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("cache"))

	P = RenderParams.new()
	terrain = Terrain.new(seed_value)
	if not terrain.ok():
		printerr("[fog-shot] terrain errors: ", terrain.errors)
		return 1
	var ppm := terrain.px_per_m
	var spot_px := spot * ppm
	print("[fog-shot] seed %d, %s px/m (data/terrain/terrain.json), spot %s m, wide zoom %.2f" % [seed_value, ppm, spot, wide])

	# Full-render stand-ins for V's MapView: Track T's terrain_shot at the spot.
	var t0 := Time.get_ticks_msec()
	var stem := "cache/full_%d_%s_%d_%d_%s" % [seed_value, ppm, roundi(spot.x), roundi(spot.y), wide]
	var full_z1 := out_dir.path_join(stem + ".png")
	var full_wide := out_dir.path_join(stem + "_wide.png")
	if not (FileAccess.file_exists(full_z1) and FileAccess.file_exists(full_wide)):
		print("[fog-shot] rendering the full-render stand-in with terrain_shot.gd (once; cached) ...")
		var output: Array = []
		var args := ["--path", ProjectSettings.globalize_path("res://"), "--script", "res://scripts/render/terrain_shot.gd", "--",
			str(seed_value), "tmp/fog/" + stem + ".png", "x=%s" % spot.x, "y=%s" % spot.y, "zoom=%s" % wide]
		var rc := OS.execute(OS.get_executable_path(), args, output, true)
		if rc != 0 or not FileAccess.file_exists(full_wide):
			printerr("[fog-shot] terrain_shot failed (%d): %s" % [rc, "".join(output)])
			return 1
		print("[fog-shot] stand-in rendered in %d ms" % (Time.get_ticks_msec() - t0))

	_build_scene()
	world = World.new()
	world.quiet = true
	world.add_player("local")
	# Two player planes whose 1,500 m vision edges cross exactly at the spot
	# (|A - spot| = |B - spot| = r), an AI enemy inside their lens and one out
	# in the fog, and a mission target out in the fog.
	var r := float(world.unit_def("light_fighter").sight_range_m)
	var off := Vector2(r * 0.8666, -r * 0.4987)
	world.add_unit({"id": "a", "type": "light_fighter", "side": "allies", "controller": "player", "x": spot.x - off.x, "y": spot.y + off.y, "heading": 0.0})
	world.add_unit({"id": "b", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": spot.x + off.x, "y": spot.y + off.y, "heading": PI})
	world.add_unit({"id": "e1", "type": "light_fighter", "side": "axis", "controller": "ai", "x": spot.x + 60.0, "y": spot.y - 260.0, "heading": 1.0})
	world.add_unit({"id": "e2", "type": "light_fighter", "side": "axis", "controller": "ai", "x": spot.x + 40.0, "y": spot.y + 420.0, "heading": 2.0})
	var target_m := spot + Vector2(-90.0, 230.0)

	# Topographic bakes: time each level of detail on the chunks around the spot.
	_bake_report(spot_px)

	var shots := [
		{"name": "fog_z1_inked", "zoom": 1.0, "edge": "inked", "full": full_z1, "full_zoom": 1.0},
		{"name": "fog_z1_soft", "zoom": 1.0, "edge": "soft", "full": full_z1, "full_zoom": 1.0},
		{"name": "fog_wide_inked", "zoom": wide, "edge": "inked", "full": full_wide, "full_zoom": wide},
		{"name": "fog_wide_soft", "zoom": wide, "edge": "soft", "full": full_wide, "full_zoom": wide},
		{"name": "fog_overview", "zoom": 0.0, "edge": "inked", "full": "", "full_zoom": 1.0},
		{"name": "fog_short_sight", "zoom": wide, "edge": "inked", "full": full_wide, "full_zoom": wide, "sight": 0.3,
			"move": {"a": Vector2(-520.0, -80.0), "b": Vector2(380.0, -220.0), "e1": Vector2(200.0, 150.0), "e2": Vector2(-150.0, 380.0)}},
		{"name": "fog_topo_only", "zoom": wide, "edge": "inked", "full": full_wide, "full_zoom": wide, "blind": true},
	]
	for s: Dictionary in shots:
		if not only.is_empty() and not only.has(s.name):
			continue
		var img: Image = await _shot(s, spot_px, target_m)
		var path := out_dir.path_join(s.name + ".png")
		img.save_png(path)
		print("[fog-shot] saved ", path)
	await _frame_cost(spot_px, wide)
	return 0

func _build_scene() -> void:
	vp = SubViewport.new()
	vp.size = SIZE
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	# The desk around the map sheet (stand-in: V decides what lies past the map).
	backdrop = Sprite2D.new()
	backdrop.centered = false
	var desk := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	desk.fill(FogStyle.resolve({"base": "paper", "toward": "ink", "t": 0.45}, P))
	backdrop.texture = ImageTexture.create_from_image(desk)
	var big := terrain.map_rect_px().grow(terrain.map_rect_px().size.x)
	backdrop.position = big.position
	backdrop.scale = big.size
	vp.add_child(backdrop)
	full = Sprite2D.new()
	full.centered = false
	full.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	vp.add_child(full)
	cam = Camera2D.new()
	vp.add_child(cam)
	cam.make_current()
	ctl = CameraController.new()
	ctl.setup_from_terrain(terrain)
	ctl.input_enabled = false
	ctl.bind(cam)
	vp.add_child(ctl)
	fog = FogLayer.new()
	fog.setup(terrain, P)
	fog.controller = ctl
	fog.auto_bake = false
	vp.add_child(fog)
	if not fog.ok():
		printerr("[fog-shot] fog errors: ", fog.errors)
	target = Marks.new()
	target.ink = P.INK
	fog.markers.add_child(target)
	live = Marks.new()
	live.ink = P.INK
	vp.add_child(live)    # above the fog, as V's live layer would be

func _bake_report(spot_px: Vector2) -> void:
	for lod in fog.topo.lods.size():
		var rect := Rect2(spot_px - Vector2(1, 1) * fog.topo.chunk_px * 1.5, Vector2(3, 3) * fog.topo.chunk_px)
		var st := fog.prebake(rect, lod)
		if st.count > 0:
			print("[fog-shot] topo bake lod %d (%d texels/chunk): %d chunks, record %.1f ms/chunk (GDScript), render+readback %.1f ms/chunk" % [
				lod, fog.topo.canvas_size(fog.topo.lods[lod]).x, st.count, st.record_ms / st.count, st.render_ms / st.count])
	# The finest level again, now that Terrain's chunk geometry is warm.
	var rect0 := Rect2(spot_px - Vector2(1, 1) * fog.topo.chunk_px * 1.5, Vector2(3, 3) * fog.topo.chunk_px)
	var cs := terrain.chunks_in_rect_px(rect0)
	var tw := Time.get_ticks_usec()
	for c in cs:
		fog.topo.make_canvas(c, fog.topo.lods[0]).discard()
	print("[fog-shot] topo record lod 0, terrain geometry warm: %.1f ms/chunk (GDScript)" % ((Time.get_ticks_usec() - tw) / 1000.0 / cs.size()))
	var t0 := Time.get_ticks_msec()
	var all := fog.prebake(terrain.map_rect_px(), fog.topo.lods.size() - 1)
	print("[fog-shot] whole-map overview bake (lod %d): %d chunks in %d ms (record %.0f ms incl. terrain geometry, render %.0f ms)" % [
		fog.topo.lods.size() - 1, all.count, Time.get_ticks_msec() - t0, all.record_ms, all.render_ms])

func _shot(s: Dictionary, spot_px: Vector2, target_m: Vector2) -> Image:
	fog.set_edge_mode(s.edge)
	fog.vision.sight_scale = float(s.get("sight", 1.0))
	# Units moved for this shot only (offsets from the spot, metres).
	var moved := {}
	var spot_m := spot_px / terrain.px_per_m
	for id: String in s.get("move", {}):
		var u: Object = world.units[id]
		moved[id] = Vector2(u.x, u.y)
		u.x = spot_m.x + s.move[id].x
		u.y = spot_m.y + s.move[id].y
	var z: float = s.zoom
	if z <= 0.0:
		ctl.set_view(terrain.map_rect_px().get_center(), 0.0)   # clamps to the zoom-out limit
	else:
		ctl.set_view(spot_px, z)
	z = ctl.zoom_level()
	if s.get("blind", false):
		fog.vision.set_circles([])
	else:
		fog.vision.update_from_world(world)
	# The stand-in full render, placed where terrain_shot framed it.
	if s.full != "":
		var img := Image.load_from_file(s.full)
		full.texture = ImageTexture.create_from_image(img)
		var fz: float = s.full_zoom
		full.position = spot_px - Vector2(SIZE) * 0.5 / fz
		full.scale = Vector2.ONE / fz
		full.visible = true
	else:
		full.visible = false
	# Markers: friends always, enemies only where vision shows them.
	live.items.clear()
	live.zoom = z
	var hidden: Array[String] = []
	for u: Object in world.units.values():
		if fog.vision.shows_unit(world, u.id):
			live.items.append({"p": Vector2(u.x, u.y) * terrain.px_per_m, "kind": "unit",
				"fill": FogStyle.resolve({"base": "side_a" if u.side == "allies" else "side_b"}, P)})
		else:
			hidden.append(u.id)
	live.queue_redraw()
	target.items = [{"p": target_m * terrain.px_per_m, "kind": "target", "fill": FogStyle.resolve({"base": "object_fill"}, P)}]
	target.zoom = z
	target.queue_redraw()
	# Bake what the view needs at its level of detail, then let it draw.
	var lod := fog.topo.lod_for_zoom(z)
	var st := fog.prebake(ctl.visible_rect_px().grow(fog.topo.chunk_px), lod)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var mismatch := _check_mask()
	for id: String in moved:
		world.units[id].x = moved[id].x
		world.units[id].y = moved[id].y
	print("[fog-shot] %s: zoom %.3f (view %.0f x %.0f m), edge %s, overview %.2f, lod %d (+%d chunks baked), %d circles, hidden %s, %d topo quads; mask vs CPU: %s" % [
		s.name, z, SIZE.x / z / terrain.px_per_m, SIZE.y / z / terrain.px_per_m, s.edge, fog.overview_amount(), lod, st.count,
		fog.vision.circles.size(), hidden, fog.stats.draw_chunks, mismatch])
	return img

# The GPU mask read back against fog_vision.gd's formula at a grid of pixels.
func _check_mask() -> String:
	var mimg := fog.mask_texture().get_image()
	var msize := Vector2(mimg.get_size())
	var k := msize.x / float(SIZE.x)
	var xf := fog.get_global_transform_with_canvas()
	var mc := fog.vision.mask_circles(terrain.px_per_m, xf, k)
	var worst := 0.0
	var n := 0
	for j in 18:
		for i in 32:
			var px := Vector2((i + 0.5) / 32.0 * msize.x, (j + 0.5) / 18.0 * msize.y).floor() + Vector2(0.5, 0.5)
			var cpu := FogVision.mask_value(mc, px, fog.range_px * k)
			var gpu := mimg.get_pixelv(Vector2i(px)).r
			worst = maxf(worst, absf(cpu - gpu))
			n += 1
	return "max |gpu - cpu| %.4f over %d pixels" % [worst, n]

# Per-frame cost of the fog: CPU (mask uniforms, quads) and GPU (the whole
# view with the fog on and off, and the mask viewport alone).
func _frame_cost(spot_px: Vector2, wide: float) -> void:
	var rid := vp.get_viewport_rid()
	var mrid := fog.mask_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	RenderingServer.viewport_set_measure_render_time(mrid, true)
	fog.vision.sight_scale = 1.0
	fog.vision.update_from_world(world)
	for z: float in [1.0, wide]:
		ctl.set_view(spot_px, z)
		var res := {}
		for on: bool in [true, false]:
			fog.visible = on
			fog.set_process(on)
			fog.mask_viewport().render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
			var gpu := 0.0
			var mgpu := 0.0
			var cpu := 0.0
			var frames := 30
			for i in 6:
				await process_frame
			for i in frames:
				await RenderingServer.frame_post_draw
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
				mgpu += RenderingServer.viewport_get_measured_render_time_gpu(mrid)
				cpu += (fog.stats.mask_us + fog.stats.draw_us) / 1000.0
			res[on] = [gpu / frames, mgpu / frames, cpu / frames]
		fog.visible = true
		fog.set_process(true)
		fog.mask_viewport().render_target_update_mode = SubViewport.UPDATE_ALWAYS
		print("[fog-shot] frame cost at zoom %.2f: view GPU %.3f ms with fog, %.3f ms without; mask viewport GPU %.3f ms; fog CPU %.3f ms/frame (mask uniforms + quads, %d quads)" % [
			z, res[true][0], res[false][0], res[true][1], res[true][2], fog.stats.draw_chunks])
