extends Node2D

# THE FOG COMPOSITOR, first option (Track F, exit criterion 7). Mounted over
# the full render (Track V's MapView), it shows Track T's terrain as a rough
# topographic map wherever the players' units cannot see, and everywhere at
# far zoom when data/view/camera.json far_zoom.mode is "overview_topo".
# Alex's rule (design doc decision log): "a rough topographic map resolves to
# the full render near units; target markers drawn above both layers;
# terrain, trees and buildings block sight" (the last clause is data
# vision.line_of_sight: "none" | "terrain" | "terrain_trees", see below).
#
#   var fog := FogLayer.new()
#   fog.setup(terrain)                    # reads data/view/fog.json and camera.json
#   map_world.add_child(fog)              # AFTER the map's chunks, BEFORE units / unit shadows
#   fog.controller = ctl                  # optional: overview amount from the CameraController
#   fog.vision.update_from_world(world, t)  # whenever units move (each animation frame)
#   fog.vision.is_visible(p_m)            # the query, metres
#   fog.vision.set_line_of_sight("terrain_trees")   # sight blocked by terrain and trees (run time switch)
#   ui.marker_layer.unit_visible = fog.vision.unit_visible(world)   # Track U's hook
#   fog.markers.add_child(target_marker)  # THE SLOT above both layers (mission targets)
#
# SPACE: the node's local space is MAP PX (metres x terrain.px_per_m, origin at
# the world origin) -- the space V's chunks are drawn in -- under the Camera2D's
# canvas transform. Keep the node at the origin with no scale. px_per_m is a
# live knob: when terrain.px_per_m changes the layer rebuilds its topographic
# layer and re-bakes (set_terrain() does the same for a new Terrain object).
#
# HOW IT DRAWS, every frame:
#   1 MASK. A SubViewport at mask.scale of the screen runs fog_mask.gdshader:
#     a clamped signed distance field of the vision circles (fog_vision.gd
#     mask_circles(), through this node's canvas transform). Sub-viewports draw
#     before their parent, so the mask is this frame's.
#     LINE OF SIGHT (vision.line_of_sight not "none"): a unit with a viewshed
#     (fog_viewshed.gd) is drawn as a SHAPE, not a circle. The mask viewport then
#     runs three passes in tree order: (a) the shapes, each unit's viewshed
#     straight from a texture of per-ray visible runs, in the child viewport
#     "VisionShapes" (fog_los_shape.gdshader; a child viewport draws before its
#     parent); (b) the columns of an exact distance transform of that coverage
#     (fog_los_cols.gdshader), (c) the rows, plus the plain circles of the units
#     without a viewshed, joined by max (fog_mask_los.gdshader, reading (b)
#     through the viewport's screen texture). The result is the same clamped
#     signed distance field, so the compositor does not change. With no shape
#     the old circle pass runs alone.
#   2 OVERLAY. _draw() puts the topographic chunks of the view (fog_topo.gd,
#     the level of detail for the zoom) as textured quads in map px, with
#     fog_composite.gdshader as this node's material: topographic map outside
#     vision, nothing inside, the edge treatment between (edge.mode "inked" or
#     "soft"), the overview amount from the zoom. A chunk not baked yet draws
#     as the plain map sheet; a chunk wholly inside vision is skipped.
#   3 BAKE. Missing chunks are recorded (GDScript) and submitted to the GPU a
#     few per frame (topo.bakes_per_frame) and collected after the frame draws
#     (InkCanvas.submit / RenderingServer.frame_post_draw): no forced frames
#     mid-game. Track V's baker can take this over: set auto_bake = false and
#     hand textures in with set_topo_chunk(c, lod, texture) from FogTopo's
#     provider (record_chunk / bake_topo_chunk). prebake() bakes synchronously
#     (loading, shots).

const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")
const CameraController = preload("res://scripts/world/camera_controller.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const FogTopo = preload("res://scripts/render/fog_topo.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")
const MASK_SHADER = preload("res://scripts/render/fog_mask.gdshader")
const COMPOSITE_SHADER = preload("res://scripts/render/fog_composite.gdshader")
const LOS_SHAPE_SHADER = preload("res://scripts/render/fog_los_shape.gdshader")
const LOS_COLS_SHADER = preload("res://scripts/render/fog_los_cols.gdshader")
const LOS_MASK_SHADER = preload("res://scripts/render/fog_mask_los.gdshader")
const FogViewshed = preload("res://scripts/render/fog_viewshed.gd")

const EDGE_INKED := "inked"
const EDGE_SOFT := "soft"

var terrain: Terrain
var P: RenderParams
var fog_data: CameraData
var cam_data: CameraData
var vision: FogVision
var topo: FogTopo
var controller: Node = null     # a CameraController gives the overview amount; else the zoom does
var markers: Node2D             # THE SLOT: drawn above the map and the fog
var errors: Array = []

var edge_mode: String
var mask_scale: float
var range_px: float
var bakes_per_frame: int
var cache_cap: int
var overview_edge: bool
var far_mode: String
var topo_below: float
var full_above: float
var overview_override := -1.0   # >= 0 forces the overview amount (shots, tests)
var auto_bake := true

# Timings and counts for the report: mask_us (last mask update, CPU side),
# draw_us (last _draw, CPU side), record_ms / bakes (chunk recording,
# GDScript), draw_chunks (quads last frame).
var stats := {"mask_us": 0, "draw_us": 0, "record_ms": 0.0, "bakes": 0, "draw_chunks": 0, "los_us": 0, "los_uploads": 0, "los_shapes": 0}

var _mask_vp: SubViewport
var _mask_rect: ColorRect
var _mask_mat: ShaderMaterial
var _los_vp: SubViewport            # the units' viewsheds as white shapes (a child of the mask viewport)
var _cols_rect: ColorRect
var _copy: BackBufferCopy
var _final_rect: ColorRect
var _cols_mat: ShaderMaterial
var _final_mat: ShaderMaterial
var _los_items := {}                # circle id -> {rect, mat, tex, serial}
var _mat: ShaderMaterial
var _cache := {}                # Vector3i(cx, cy, lod) -> ImageTexture
var _pending: Array = []        # [[key, InkCanvas]] submitted, collected after the frame
var _xf := Transform2D.IDENTITY # local (map px) -> screen px, this frame
var _zoom := 1.0
var _overview := 0.0

func setup(t: Terrain, params: RenderParams = null, fog: CameraData = null, cam: CameraData = null) -> void:
	terrain = t
	P = params if params != null else RenderParams.new()
	fog_data = fog if fog != null else CameraData.new(CameraData.FOG_PATH)
	cam_data = cam if cam != null else CameraData.new(CameraData.CAMERA_PATH)
	vision = FogVision.new(fog_data)
	vision.attach_terrain(t)
	topo = FogTopo.new(t, fog_data, P)
	errors.append_array(vision.errors)
	errors.append_array(topo.errors)
	mask_scale = fog_data.num("mask.scale")
	range_px = fog_data.num("mask.range_px")
	bakes_per_frame = fog_data.integer("topo.bakes_per_frame")
	cache_cap = fog_data.integer("topo.cache_chunks")
	overview_edge = fog_data.flag("overview.vision_edge")
	far_mode = cam_data.text("far_zoom.mode")
	topo_below = cam_data.num("far_zoom.topo_below_zoom")
	full_above = cam_data.num("far_zoom.full_above_zoom")
	_mask_mat = ShaderMaterial.new()
	_mask_mat.shader = MASK_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = COMPOSITE_SHADER
	_apply_style()
	set_edge_mode(fog_data.text("edge.mode"))

	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	material = _mat
	_mask_vp = SubViewport.new()
	_mask_vp.name = "VisionMask"
	_mask_vp.disable_3d = true
	_mask_vp.transparent_bg = false
	_mask_vp.use_hdr_2d = true            # float precision for the distance field
	_mask_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_mask_vp.size = Vector2i(2, 2)
	_mask_rect = ColorRect.new()
	_mask_rect.material = _mask_mat
	_mask_rect.size = Vector2(2, 2)
	_mask_vp.add_child(_mask_rect)
	_build_los()
	add_child(_mask_vp)
	_mat.set_shader_parameter("mask", _mask_vp.get_texture())
	markers = Node2D.new()
	markers.name = "Markers"
	add_child(markers)

# A new Terrain, or the same one at a new scale (px_per_m is a live knob):
# rebuild the topographic layer for it and drop every baked chunk (their px
# sizes are the old scale's). Vision is in metres and does not change.
func set_terrain(t: Terrain) -> void:
	terrain = t
	vision.attach_terrain(t)
	topo = FogTopo.new(t, fog_data, P)
	errors.append_array(topo.errors)
	_apply_style()
	for item: Array in _pending:
		(item[1] as InkCanvas).discard()
	_pending.clear()
	_cache.clear()
	queue_redraw()

func _ready() -> void:
	process_priority = 100   # after the camera has moved this frame

func ok() -> bool:
	return errors.is_empty() and vision.ok() and topo.ok() and fog_data.ok() and cam_data.ok()

func _err(message: String) -> void:
	errors.append(message)
	push_error("FogLayer: " + message)

# Every uniform that comes from data: widths, noise, colours (resolved roles).
func _apply_style() -> void:
	var d := fog_data
	var m := _mat
	m.set_shader_parameter("range_px", range_px)
	m.set_shader_parameter("outside_color", topo.outside)
	m.set_shader_parameter("line_color", FogStyle.resolve(d.value("edge.inked.line_role"), P, errors))
	m.set_shader_parameter("line_px", d.num("edge.inked.line_px"))
	m.set_shader_parameter("wobble_px", d.num("edge.inked.wobble_px"))
	m.set_shader_parameter("wobble_freq", d.num("edge.inked.wobble_per_px"))
	m.set_shader_parameter("band_px", d.num("edge.inked.band_px"))
	m.set_shader_parameter("hatch_color", FogStyle.resolve(d.value("edge.inked.hatch_role"), P, errors))
	m.set_shader_parameter("hatch_spacing", d.num("edge.inked.hatch_spacing_px"))
	m.set_shader_parameter("hatch_width", d.num("edge.inked.hatch_width_px"))
	var a := deg_to_rad(d.num("edge.inked.hatch_angle_deg"))
	m.set_shader_parameter("hatch_dir", Vector2(-sin(a), cos(a)))   # across the lines
	m.set_shader_parameter("feather_px", d.num("edge.soft.feather_px"))
	m.set_shader_parameter("soft_wobble_px", d.num("edge.soft.wobble_px"))
	m.set_shader_parameter("soft_wobble_freq", d.num("edge.soft.wobble_per_px"))
	# The mask must hold every edge effect: past range_px it is saturated.
	var inked := d.num("edge.inked.band_px") + d.num("edge.inked.wobble_px") + d.num("edge.inked.line_px")
	var soft := d.num("edge.soft.feather_px") * 0.5 + 1.5 * d.num("edge.soft.wobble_px")
	if range_px < maxf(inked, soft):
		_err("mask.range_px (%s) must cover the widest edge effect (%s screen px)" % [range_px, maxf(inked, soft)])

func set_edge_mode(mode: String) -> void:
	if mode != EDGE_INKED and mode != EDGE_SOFT:
		_err("edge.mode must be '%s' or '%s', not '%s'" % [EDGE_INKED, EDGE_SOFT, mode])
		return
	edge_mode = mode
	_mat.set_shader_parameter("edge_mode", 0 if mode == EDGE_INKED else 1)

# The overview amount at the current zoom (camera.json far_zoom), 0..1.
func overview_amount() -> float:
	if overview_override >= 0.0:
		return overview_override
	if controller != null and controller.has_method("overview_amount") and controller.camera != null:
		return controller.overview_amount()
	return CameraController.overview_amount_for(far_mode, topo_below, full_above, _zoom)

# --- per frame ------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if topo == null or not is_inside_tree():
		return
	if terrain.px_per_m != topo.ppm:
		set_terrain(terrain)
	var vsize := get_viewport().get_visible_rect().size
	_xf = get_global_transform_with_canvas()
	_zoom = _xf.x.length()
	_overview = overview_amount()
	update_mask(vsize)
	_mat.set_shader_parameter("zoom", _zoom)
	_mat.set_shader_parameter("overview", _overview)
	_mat.set_shader_parameter("show_edge", 1.0 if overview_edge else 1.0 - _overview)
	if auto_bake:
		_schedule()
	queue_redraw()

# The mask's size and uniforms for a screen of `vsize`: the circles in mask px.
func update_mask(vsize: Vector2) -> void:
	var t0 := Time.get_ticks_usec()
	var msize := Vector2i(maxi(1, roundi(vsize.x * mask_scale)), maxi(1, roundi(vsize.y * mask_scale)))
	if _mask_vp.size != msize:
		_mask_vp.size = msize
		_mask_rect.size = Vector2(msize)
	var k := float(msize.x) / maxf(vsize.x, 1.0)
	var mc := vision.mask_circles(terrain.px_per_m, _xf, k)
	var count := mc.size()
	mc.resize(FogVision.MAX_SHADER_CIRCLES)
	for m: ShaderMaterial in [_mask_mat, _final_mat]:
		m.set_shader_parameter("count", count)
		m.set_shader_parameter("circles", mc)
		m.set_shader_parameter("range_mask", range_px * k)
		m.set_shader_parameter("mask_size", Vector2(msize))
	_update_los(msize, k)
	stats.mask_us = Time.get_ticks_usec() - t0

# --- line of sight: the shapes and the distance transform ---------------------------------

# Builds the nodes of the three passes inside the mask viewport (hidden until a
# unit has a viewshed). Tree order is draw order: the circle pass, then the
# shapes' child viewport (drawn before this one whatever its place), the
# columns, the screen-texture copy, the rows.
func _build_los() -> void:
	_los_vp = SubViewport.new()
	_los_vp.name = "VisionShapes"
	_los_vp.disable_3d = true
	_los_vp.transparent_bg = true
	_los_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_los_vp.size = Vector2i(2, 2)
	_mask_vp.add_child(_los_vp)
	_cols_mat = ShaderMaterial.new()
	_cols_mat.shader = LOS_COLS_SHADER
	_cols_mat.set_shader_parameter("shape", _los_vp.get_texture())
	_cols_rect = ColorRect.new()
	_cols_rect.name = "DistanceColumns"
	_cols_rect.material = _cols_mat
	_cols_rect.size = Vector2(2, 2)
	_cols_rect.visible = false
	_mask_vp.add_child(_cols_rect)
	_copy = BackBufferCopy.new()
	_copy.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	_copy.visible = false
	_mask_vp.add_child(_copy)
	_final_mat = ShaderMaterial.new()
	_final_mat.shader = LOS_MASK_SHADER
	_final_rect = ColorRect.new()
	_final_rect.name = "DistanceRows"
	_final_rect.material = _final_mat
	_final_rect.size = Vector2(2, 2)
	_final_rect.visible = false
	_mask_vp.add_child(_final_rect)

# Per frame: which passes run, the shapes' textures and uniforms. `k` is the
# mask's size over the screen's.
func _update_los(msize: Vector2i, k: float) -> void:
	var t0 := Time.get_ticks_usec()
	var los := vision.los_circles()
	var active := not los.is_empty()
	_mask_rect.visible = not active
	_cols_rect.visible = active
	_copy.visible = active
	_final_rect.visible = active
	_los_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if active else SubViewport.UPDATE_DISABLED
	stats.los_shapes = los.size()
	if not active:
		for item: Dictionary in _los_items.values():
			(item.rect as ColorRect).visible = false
		stats.los_us = Time.get_ticks_usec() - t0
		return
	if _los_vp.size != msize:
		_los_vp.size = msize
	var sz := Vector2(msize)
	_cols_rect.size = sz
	_final_rect.size = sz
	var reach := ceili(range_px * k) + 1
	var texel := Vector2(1.0 / sz.x, 1.0 / sz.y)
	_cols_mat.set_shader_parameter("reach", reach)
	_cols_mat.set_shader_parameter("texel", texel)
	_final_mat.set_shader_parameter("reach", reach)
	_final_mat.set_shader_parameter("texel", texel)
	# mask px -> metres: screen px = mask px / k; map px = canvas^-1 (screen px); metres = map px / ppm
	var inv := _xf.affine_inverse()
	var s := 1.0 / (k * terrain.px_per_m)
	var ax := inv.x * s
	var ay := inv.y * s
	var base := inv.origin / terrain.px_per_m
	var used := {}
	var i := 0
	for c: Dictionary in los:
		var key: String = c.id if c.id != "" else "#%d" % i
		i += 1
		used[key] = true
		var shed: FogViewshed.Shed = c.shed
		var item: Dictionary = _los_items.get(key, {})
		if item.is_empty():
			var new_mat := ShaderMaterial.new()
			new_mat.shader = LOS_SHAPE_SHADER
			var new_rect := ColorRect.new()
			new_rect.material = new_mat
			_los_vp.add_child(new_rect)
			item = {"rect": new_rect, "mat": new_mat, "tex": null, "serial": -1}
			_los_items[key] = item
		var rect: ColorRect = item.rect
		var mat: ShaderMaterial = item.mat
		if item.serial != shed.serial:
			var img := Image.create_from_data(shed.n, FogViewshed.RUN_ROWS, false, Image.FORMAT_RGBAF, shed.texture_bytes())
			var tex: ImageTexture = item.tex
			if tex != null and tex.get_width() == shed.n:
				tex.update(img)
			else:
				tex = ImageTexture.create_from_image(img)
				item.tex = tex
				mat.set_shader_parameter("runs", tex)
			item.serial = shed.serial
			mat.set_shader_parameter("rays", shed.n)
			mat.set_shader_parameter("dtheta", shed.dtheta)
			mat.set_shader_parameter("eye", shed.eye)
			mat.set_shader_parameter("range_m", shed.range_m)
			stats.los_uploads += 1
		mat.set_shader_parameter("ax", ax)
		mat.set_shader_parameter("ay", ay)
		mat.set_shader_parameter("base_m", base)
		rect.size = sz
		rect.visible = true
	for key: String in _los_items.keys():
		if not used.has(key):
			var item: Dictionary = _los_items[key]
			(item.rect as ColorRect).queue_free()
			_los_items.erase(key)
	stats.los_us = Time.get_ticks_usec() - t0

func mask_texture() -> ViewportTexture:
	return _mask_vp.get_texture()

func mask_viewport() -> SubViewport:
	return _mask_vp

# The map-px rectangle on screen this frame.
func view_rect_px() -> Rect2:
	var vsize := get_viewport().get_visible_rect().size
	var inv := _xf.affine_inverse()
	var r := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	for p: Vector2 in [Vector2(vsize.x, 0.0), Vector2(0.0, vsize.y), vsize]:
		r = r.expand(inv * p)
	return r

func _draw() -> void:
	if topo == null:
		return
	var t0 := Time.get_ticks_usec()
	var lod := topo.lod_for_zoom(_zoom)
	var n := 0
	for c in terrain.chunks_in_rect_px(view_rect_px()):
		if _overview <= 0.0 and _inside_vision(c):
			continue
		var r := topo.chunk_rect_px(c)
		var tex: Texture2D = _best(c, lod)
		if tex != null:
			draw_texture_rect(tex, r, false)
		else:
			draw_rect(r, topo.paper_levels[0])
		n += 1
	stats.draw_chunks = n
	stats.draw_us = Time.get_ticks_usec() - t0

# Is chunk c wholly inside one vision circle, with the mask's whole range to
# spare (so no edge effect can reach it)?
func _inside_vision(c: Vector2i) -> bool:
	var r := topo.chunk_rect_px(c).grow(range_px / maxf(_zoom, 1e-6))
	var ppm := terrain.px_per_m
	for circ: Dictionary in vision.circles:
		if circ.has("shed"):
			continue   # a shape, not a circle: the chunk can be inside the circle and out of sight
		var cx: float = circ.x * ppm
		var cy: float = circ.y * ppm
		var rr: float = circ.r * ppm
		var all_in := true
		for p: Vector2 in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
			if (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) > rr * rr:
				all_in = false
				break
		if all_in:
			return true
	return false

# The baked texture for c at `lod`, else the nearest other level that is baked.
func _best(c: Vector2i, lod: int) -> Texture2D:
	var hit: Variant = _cache.get(Vector3i(c.x, c.y, lod))
	if hit != null:
		return hit
	for d in range(1, topo.lods.size()):
		for l: int in [lod + d, lod - d]:
			if l >= 0 and l < topo.lods.size():
				hit = _cache.get(Vector3i(c.x, c.y, l))
				if hit != null:
					return hit
	return null

# --- baking ----------------------------------------------------------------------------------

# A texture baked elsewhere (Track V's baker) for chunk c at level `lod`.
func set_topo_chunk(c: Vector2i, lod: int, tex: Texture2D) -> void:
	_cache[Vector3i(c.x, c.y, lod)] = tex
	queue_redraw()

func has_topo_chunk(c: Vector2i, lod: int) -> bool:
	return _cache.has(Vector3i(c.x, c.y, lod))

# Bake every map chunk `rect_px` touches at level `lod`, NOW (forces frames:
# loading screens and shots). Returns {count, record_ms, render_ms}.
func prebake(rect_px: Rect2, lod: int, batch: int = 48) -> Dictionary:
	var todo: Array[Vector2i] = []
	for c in terrain.chunks_in_rect_px(rect_px):
		if not _cache.has(Vector3i(c.x, c.y, lod)):
			todo.append(c)
	var s: float = topo.lods[lod]
	var rec := 0.0
	var ren := 0.0
	for b in range(0, todo.size(), batch):
		var part := todo.slice(b, b + batch)
		var canvases: Array = []
		var t0 := Time.get_ticks_usec()
		for c: Vector2i in part:
			canvases.append(topo.make_canvas(c, s))
		var t1 := Time.get_ticks_usec()
		var imgs := InkCanvas.render_all(canvases)
		for i in imgs.size():
			var c: Vector2i = part[i]
			_cache[Vector3i(c.x, c.y, lod)] = FogTopo.texture_from(imgs[i])
		var t2 := Time.get_ticks_usec()
		rec += (t1 - t0) / 1000.0
		ren += (t2 - t1) / 1000.0
	queue_redraw()
	return {"count": todo.size(), "record_ms": rec, "render_ms": ren}

func _schedule() -> void:
	if not _pending.is_empty() or bakes_per_frame <= 0:
		return
	var lod := topo.lod_for_zoom(_zoom)
	var view := view_rect_px()
	var centre := view.get_center()
	var want: Array[Vector2i] = []
	for c in terrain.chunks_in_rect_px(view.grow(topo.chunk_px)):
		if _cache.has(Vector3i(c.x, c.y, lod)):
			continue
		if _overview <= 0.0 and _inside_vision(c):
			continue
		want.append(c)
	if want.is_empty():
		return
	want.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return topo.chunk_rect_px(a).get_center().distance_squared_to(centre) < topo.chunk_rect_px(b).get_center().distance_squared_to(centre))
	var s: float = topo.lods[lod]
	var canvases: Array = []
	var t0 := Time.get_ticks_usec()
	for i in mini(bakes_per_frame, want.size()):
		var c: Vector2i = want[i]
		var g := topo.make_canvas(c, s)
		_pending.append([Vector3i(c.x, c.y, lod), g])
		canvases.append(g)
	stats.record_ms = (Time.get_ticks_usec() - t0) / 1000.0
	InkCanvas.submit(canvases)
	RenderingServer.frame_post_draw.connect(_collect, CONNECT_ONE_SHOT)

func _collect() -> void:
	for item: Array in _pending:
		var img: Image = (item[1] as InkCanvas).collect_image()
		if img != null and not img.is_empty():
			_cache[item[0]] = FogTopo.texture_from(img)
			stats.bakes += 1
	_pending.clear()
	_evict()
	queue_redraw()

# Over the cap: drop the chunks farthest from the view, finer levels first.
func _evict() -> void:
	if _cache.size() <= cache_cap:
		return
	var centre := view_rect_px().get_center()
	var keys := _cache.keys()
	keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		if a.z != b.z:
			return a.z < b.z
		var ca := topo.chunk_rect_px(Vector2i(a.x, a.y)).get_center().distance_squared_to(centre)
		var cb := topo.chunk_rect_px(Vector2i(b.x, b.y)).get_center().distance_squared_to(centre)
		return ca > cb)
	var i := 0
	while _cache.size() > cache_cap and i < keys.size():
		_cache.erase(keys[i])
		i += 1
