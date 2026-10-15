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
# HOW IT DRAWS (Track P rework, 2026-10-10: a pan or a zoom composites textures that already exist):
#   1 SIGHT. The vision circles (fog_vision.gd) are handed to fog_composite.gdshader as uniforms in
#     MAP px, and the shader takes the clamped signed distance to the union of the circles per fragment
#     (mask.mode "analytic", the default): there is no mask to render, so a pan costs no mask pass
#     and a change of sight costs one uniform update. mask.mode "texture" is the old way: a SubViewport
#     at mask.scale of the screen runs fog_mask.gdshader every frame (a clamped signed distance field
#     of the circles through this node's canvas transform) and the compositor reads it back through
#     SCREEN_UV; tests and fog_shot.gd use it to hold the shader to the CPU formula.
#     LINE OF SIGHT (vision.line_of_sight not "none"): a unit with a viewshed
#     (fog_viewshed.gd) is drawn as a SHAPE, not a circle. The mask viewport then
#     runs three passes in tree order, EVERY FRAME (the mask is in screen px; a world-anchored
#     shape mask is a later step): (a) the shapes, each unit's viewshed
#     straight from a texture of per-ray visible runs, in the child viewport
#     "VisionShapes" (fog_los_shape.gdshader; a child viewport draws before its
#     parent); (b) the columns of an exact distance transform of that coverage
#     (fog_los_cols.gdshader), (c) the rows, plus the plain circles of the units
#     without a viewshed, joined by max (fog_mask_los.gdshader, reading (b)
#     through the viewport's screen texture). The result is the same clamped
#     signed distance field, so the compositor does not change. With no shape
#     the circles are evaluated as above.
#   2 OVERLAY. _draw() puts the topographic chunks of the view (fog_topo.gd,
#     the level of detail for the zoom) as textured quads in map px, with
#     fog_composite.gdshader as this node's material: topographic map outside
#     vision, nothing inside, the edge treatment between (edge.mode "inked" or
#     "soft"), the overview amount from the zoom. _draw() runs again only when
#     what it draws changes (the chunks in view, the level of detail, the circles,
#     a new texture), never on a plain pan: the quads live in map px under the camera.
#     A chunk not baked yet draws as the plain map sheet; a chunk wholly inside vision is skipped.
#   3 WHOLE-MAP BAKE. The whole map is baked at every level of detail AHEAD OF PLAY (topo.whole_map):
#     scripts/render/fog_topo_baker.gd records the chunks on topo.twins worker threads (each a private
#     twin of the terrain), submits them in a slice of the main thread's frame, reads the pixels back
#     asynchronously and makes the textures; the order is the current zoom's level first, nearest the
#     view's centre first. The sandbox waits for it behind the loading card (bake_remaining()).
#     The old demand baking (topo.whole_map false) asks the same pipeline for the view's chunks only.
#     At most topo.max_inflight chunks are past the queue at once, topo.bakes_per_frame recordings begin
#     a frame, and the main thread spends topo.main_budget_ms a frame on it (main_budget_loading_ms
#     while `bake_boost` is set: a card is up). shutdown() waits for the workers, and runs on leaving
#     the tree: a quit with a worker task still running GDScript crashes the engine.
#     Track V's baker can take the bakes over instead: set auto_bake = false and
#     hand textures in with set_topo_chunk(c, lod, texture) from FogTopo's
#     provider (record_chunk / bake_topo_chunk). prebake() bakes synchronously
#     (shots).
#
# THE FLOOR (Track P2, 2026-10-10; Alex: "showing a stale map seems better then a plain brown square"): no area
# of the screen is ever left unpainted; it shows the best thing already made for that place.
#   - The contour map is made for the whole map at every level of detail before play. A chunk's own level is
#     drawn when it is there, else the nearest other level (_best): the coarsest, 32 texels a chunk, is the
#     whole-map overview, the first thing baked of each chunk and never evicted.
#   - Where the MAP under a chunk is not baked yet (map_ready says no: sight reached a place faster than the baker,
#     or a rebake is under way and nothing stale covers it) the chunk is drawn FORCED: the contour map shows
#     there even inside vision (a one-texel-per-chunk mask, forced_mask, which fog_composite.gdshader reads).
#     The swap to the real ground is the map layer's chunk landing (map_serial moves, the mask is made again).
#   - A change that alters the look (the map's scale, the pen: set_terrain) keeps the earlier contour textures as
#     STALE, drawn wherever the new ones are not made yet, and drops them when the whole new set is.
#   unpainted_in_view() counts the chunks in view where none of this holds: 0, always (test_fog, pan_probe.gd).
#
# HIDDEN CHUNKS: rect_under_fog(rect_px) says whether a map-px rectangle lies wholly
# under the opaque topographic layer (no vision circle within the edge's reach of
# it, and the overview off). MapView bakes such chunks after the visible ones
# (map_view.hidden_test).

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
const FogTopoBaker = preload("res://scripts/render/fog_topo_baker.gd")

const EDGE_INKED := "inked"
const EDGE_SOFT := "soft"
const MASK_ANALYTIC := "analytic"
const MASK_TEXTURE := "texture"

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
var mask_mode: String           # "analytic": the shader takes the circles' distance itself; "texture": the mask viewport (see the header)
var mask_scale: float
var range_px: float
var bakes_per_frame: int        # recordings STARTED per frame (0: no baking)
var max_inflight: int           # bakes in the pipeline at once
var worker_recording: bool      # record on worker threads (else on the main thread)
var main_budget_ms: float       # main-thread ms a frame the pipeline may spend (submission, textures)
var main_budget_loading_ms: float   # ... while bake_boost is set (a loading card is up)
var load_share: float           # the share of the loading card's bar the whole-map bake has (the rest is the map's chunks)
var whole_map: bool             # bake the whole map at every level of detail ahead of play (else only what the view needs)
var twin_count: int             # recorder threads, each with a private Terrain
var cache_cap: int
var overview_edge: bool
var far_mode: String
var topo_below: float
var full_above: float
var overview_override := -1.0   # >= 0 forces the overview amount (shots, tests)
var auto_bake := true
var terrain_maker: Callable = Callable()   # see set_terrain_maker()
var water: RefCounted = null              # see set_water()
# (rect_px: Rect2) -> bool: does the map layer show something (fresh or stale) over this map-px rectangle? And
# () -> int, moving when that changes (MapView.covers_px, MapView.chunk_serial). Unset: the map is taken as there.
var map_ready: Callable = Callable()
var map_serial: Callable = Callable()
# The sandbox sets this while its loading card is up: the pipeline then spends main_budget_loading_ms of
# main-thread time a frame instead of main_budget_ms (nobody is playing, so a long frame costs nothing).
var bake_boost := false
# THE FOG-EDGE BOARD (builder BF, 2026-10-14; PROPOSED, Alex has not picked): the inked edge's look is a row of
# data/view/fog.json edge.inked.looks (edge.inked.look, "e0" = today) laid over the keys it names. look_override: a
# look id set at run time (set_look) in place of the data's. los_interp: viewshed.interp, the line-of-sight shapes
# blend the two nearest rays (set_los_interp).
var look_override := ""
var edge_look := "e0"
var los_interp := false
var los_interp_spread := 2.0
var _look_over: Dictionary = {}

# Timings and counts for the report: mask_us (last mask update, CPU side),
# draw_us (last _draw, CPU side), record_ms / record_ms_max (chunk recording,
# GDScript; on a worker unless topo.worker_recording is off), bakes (chunks
# baked), finished (bakes that left the pipeline, with or without pixels), main_ms /
# main_ms_max_frame (main-thread time of the bake pipeline: submission and
# textures), draw_chunks (quads last frame), draws (times _draw ran), redraws_skipped
# (frames that needed none).
var stats := {"mask_us": 0, "draw_us": 0, "record_ms": 0.0, "record_ms_max": 0.0, "bakes": 0, "finished": 0, "main_ms": 0.0,
	"main_ms_max_frame": 0.0, "draw_chunks": 0, "los_us": 0, "los_uploads": 0, "los_shapes": 0, "draws": 0, "redraws_skipped": 0}

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
var _forced := {}               # Vector2i -> true: chunks the map layer shows nothing over (the contours show there whatever the sight says)
var _forced_serial := -1        # the map_serial the set was made for
var _forced_img: Image = null
var _forced_tex: ImageTexture = null
var _stale := {}                # an earlier bake's textures (another scale or pen), kept under the new ones until they are made
# Bakes per chunk and level (Vector3i(cx, cy, lod) -> times it finished): a static piece is made ONCE per game and
# kept (Alex: "we seem to be regenerating map sections we should already have"), so a count above 1 is a bug unless
# the look changed. The pan probe and the tests read it.
var bake_counts: Dictionary = {}
var _baker: FogTopoBaker = null  # the pipeline (built on the first frame that bakes)
var _baker_topo: FogTopo = null  # the FogTopo the baker was built for (a new one means a new baker)
var _enqueued_for: FogTopo = null  # the FogTopo whose whole map has been queued
var _xf := Transform2D.IDENTITY # local (map px) -> screen px, this frame
var _zoom := 1.0
var _overview := 0.0
var _cache_serial := 0          # counts textures arriving: part of what _draw draws
var _circles_map := PackedVector4Array()   # the plain circles (map px): what the composite shader gets, analytic mode
var _circles_all := PackedVector4Array()   # every circle, viewshed units included
var _circle_serial := 0
var _hidden_serial := 0
var _redraw_sig: Array = []
var _last_analytic := false

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
	mask_mode = fog_data.text("mask.mode")
	if mask_mode != MASK_ANALYTIC and mask_mode != MASK_TEXTURE:
		_err("mask.mode must be '%s' or '%s', not '%s'" % [MASK_ANALYTIC, MASK_TEXTURE, mask_mode])
		mask_mode = MASK_TEXTURE
	bakes_per_frame = fog_data.integer("topo.bakes_per_frame")
	max_inflight = fog_data.integer("topo.max_inflight")
	worker_recording = fog_data.flag("topo.worker_recording")
	main_budget_ms = fog_data.num("topo.main_budget_ms")
	main_budget_loading_ms = fog_data.num("topo.main_budget_loading_ms")
	load_share = fog_data.num("topo.load_share")
	whole_map = fog_data.flag("topo.whole_map")
	twin_count = maxi(1, fog_data.integer("topo.twins"))
	cache_cap = fog_data.integer("topo.cache_chunks")
	overview_edge = fog_data.flag("overview.vision_edge")
	far_mode = cam_data.text("far_zoom.mode")
	topo_below = cam_data.num("far_zoom.topo_below_zoom")
	full_above = cam_data.num("far_zoom.full_above_zoom")
	_mask_mat = ShaderMaterial.new()
	_mask_mat.shader = MASK_SHADER
	_mat = ShaderMaterial.new()
	_mat.shader = COMPOSITE_SHADER
	los_interp = fog_data.flag("viewshed.interp")
	los_interp_spread = fog_data.num("viewshed.interp_spread")
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
	topo.terrain_maker = terrain_maker
	topo.set_water(water)
	errors.append_array(topo.errors)
	_apply_style()
	shutdown()   # bakes in flight are for the old layer
	_baker = null
	_baker_topo = null
	# What is on screen stays, as STALE, until its replacement is made (a chunk is the same 256 m cell at any
	# scale, so its old texture is drawn into the new rectangle). A second change before the first was made keeps
	# the fuller of the two.
	if _cache.size() >= _stale.size():
		_stale = _cache
	_cache = {}
	_cache_serial += 1
	_forced_serial = -1   # (the chunks are another size now)
	queue_redraw()

# How the recorder twins' private terrains are made, for a layer that changes the ground after a Terrain is
# constructed (the water's capped height field): (seed, data_path, params) -> Terrain, called on the main thread.
# Set it before the first frame that bakes (see FogTopo.terrain_maker). Unset: the same class as the layer's terrain.
func set_terrain_maker(fn: Callable) -> void:
	terrain_maker = fn
	topo.terrain_maker = fn

# THE WATER ON THE CONTOUR MAP (Track WB, 2026-10-10, Job 3): the map outside sight shows `w`'s water (a WaterGen: three depth steps as
# quiet washes under the level tones and their ink lines, FogTopo.set_water) and the recorder twins' terrains are the water's own
# (w.make_terrain: the same capped ground the map, the sight and the units read). `terrain` must be that capped ground too.
# Call after setup() and before the first bake; a layer already baking is rebuilt (set_terrain). Null: no water.
func set_water(w: RefCounted) -> void:
	water = w
	set_terrain_maker(Callable(w, "make_terrain") if w != null else Callable())
	topo.set_water(w)
	if _baker != null:
		set_terrain(terrain)

func _ready() -> void:
	process_priority = 100   # after the camera has moved this frame

# Waits for the worker tasks and drops every bake in flight and in the queue (the next frame that
# bakes queues the map again, minus what is cached). A quit with a task
# still running GDScript crashes the engine, so a quit must not skip this; it
# also runs when the layer leaves the tree. A bake whose pixels are already on
# their way keeps its canvas (the read-back frees it) and its result is dropped.
func shutdown() -> void:
	if _baker != null:
		_baker.clear()
	_enqueued_for = null

func _exit_tree() -> void:
	shutdown()

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
	_resolve_look()
	m.set_shader_parameter("wobble_px", _ink_num("wobble_px"))
	m.set_shader_parameter("wobble_freq", _ink_num("wobble_per_px"))
	var noise := _ink_text("wobble_noise")
	if noise != "value" and noise != "gradient":
		_err("edge.inked.wobble_noise must be 'value' or 'gradient', not '%s'" % noise)
		noise = "value"
	m.set_shader_parameter("wobble_noise", 1 if noise == "gradient" else 0)
	m.set_shader_parameter("cut_soft", _ink_num("cut_soft_px"))
	m.set_shader_parameter("wobble2_px", _ink_num("wobble2_px"))
	m.set_shader_parameter("wobble2_freq", _ink_num("wobble2_per_px"))
	var hatch_len := _ink_text("hatch_length")
	if hatch_len != "random" and hatch_len != "smooth":
		_err("edge.inked.hatch_length must be 'random' or 'smooth', not '%s'" % hatch_len)
		hatch_len = "random"
	m.set_shader_parameter("hatch_len_mode", 1 if hatch_len == "smooth" else 0)
	m.set_shader_parameter("hatch_len_min", _ink_num("hatch_length_min"))
	m.set_shader_parameter("hatch_len_freq", _ink_num("hatch_length_per_tick"))
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
	var inked := d.num("edge.inked.band_px") + _ink_num("wobble_px") + _ink_num("wobble2_px") + d.num("edge.inked.line_px") + 0.5 * _ink_num("cut_soft_px")
	var soft := d.num("edge.soft.feather_px") * 0.5 + 1.5 * d.num("edge.soft.wobble_px")
	if range_px < maxf(inked, soft):
		_err("mask.range_px (%s) must cover the widest edge effect (%s screen px)" % [range_px, maxf(inked, soft)])

# The look row in force: look_override, else the data's edge.inked.look. Its keys must name keys of edge.inked.
const LOOK_KEYS := ["wobble_px", "wobble_per_px", "wobble_noise", "cut_soft_px", "wobble2_px", "wobble2_per_px", "hatch_length", "hatch_length_min", "hatch_length_per_tick"]

func _resolve_look() -> void:
	edge_look = look_override if look_override != "" else fog_data.text("edge.inked.look")
	var looks: Dictionary = fog_data.dict("edge.inked.looks")
	_look_over = {}
	if not looks.has(edge_look):
		_err("edge.inked.look '%s' is not a row of edge.inked.looks (%s)" % [edge_look, looks.keys()])
		return
	var row: Variant = looks[edge_look]
	if not (row is Dictionary):
		_err("edge.inked.looks.%s is not an object" % edge_look)
		return
	for k: String in (row as Dictionary):
		if not LOOK_KEYS.has(k):
			_err("edge.inked.looks.%s names '%s', which is not one of %s" % [edge_look, k, LOOK_KEYS])
	_look_over = row

# An edge.inked number: the look row's, else the data's (always read, so the data file carries nothing unread).
func _ink_num(key: String) -> float:
	var base: float = fog_data.num("edge.inked." + key)
	var ov: Variant = _look_over.get(key)
	return float(ov) if (ov is float or ov is int) else base

func _ink_text(key: String) -> String:
	var base: String = fog_data.text("edge.inked." + key)
	var ov: Variant = _look_over.get(key)
	return str(ov) if ov is String else base

# Switch the inked edge's look at run time (a row of edge.inked.looks); "" returns to the data's. False for an unknown row.
func set_look(id: String) -> bool:
	var looks: Dictionary = fog_data.dict("edge.inked.looks")
	if id != "" and not looks.has(id):
		return false
	look_override = id
	_apply_style()
	queue_redraw()
	return true

# viewshed.interp at run time: the line-of-sight shapes blend the two rays either side of a pixel (fog_los_shape.gdshader).
func set_los_interp(on: bool) -> void:
	los_interp = on
	for item: Dictionary in _los_items.values():
		_apply_interp(item.mat)

func _apply_interp(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("interp", los_interp)
	mat.set_shader_parameter("interp_spread", los_interp_spread)

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
	_set_param("zoom", _zoom)
	_set_param("overview", _overview)
	_set_param("show_edge", 1.0 if overview_edge else 1.0 - _overview)
	if _baker != null:
		_baker.boost = bake_boost
	if auto_bake:
		_schedule()
	if _baker != null:
		_baker.step()
		_sync_stats()
		if whole_map and _enqueued_for == topo and _baker.remaining() == 0:
			_baker.release_twins()   # the whole map is made: the twins' terrains are not needed again
			if not _stale.is_empty():
				_stale = {}   # ... and nothing of the earlier bake is wanted any more
				_cache_serial += 1
	_update_forced()
	_redraw_if_changed()

var _params := {}

# A shader parameter set only when it changes: a material that is poked every frame re-uploads its
# uniforms every frame, and a paused map should cost nothing.
func _set_param(name: String, value: Variant) -> void:
	if _params.get(name) != value or not _params.has(name):
		_params[name] = value
		_mat.set_shader_parameter(name, value)

# The sight for this frame. Analytic (mask.mode "analytic", no viewshed shapes): the circles are
# uniforms of the composite shader in MAP px and the shader takes their distance itself, so nothing is
# rendered for the mask and a pan changes nothing here; only a change of sight (a unit moved, a
# plan preview, a unit downed) uploads anything. Otherwise (mask.mode "texture", or a unit with a
# viewshed) the mask viewport is sized and fed for a screen of `vsize`: the circles in mask px.
func update_mask(vsize: Vector2) -> void:
	var t0 := Time.get_ticks_usec()
	_scan_circles()
	var analytic := mask_mode == MASK_ANALYTIC and vision.los_circles().is_empty()
	if analytic != _last_analytic or not _params.has("analytic"):
		_last_analytic = analytic
		_set_param("analytic", analytic)
	var want_mode := SubViewport.UPDATE_DISABLED if analytic else SubViewport.UPDATE_ALWAYS
	if _mask_vp.render_target_update_mode != want_mode:
		_mask_vp.render_target_update_mode = want_mode
	if analytic:
		if _circles_uploaded != _circles_map:
			_circles_uploaded = _circles_map
			var padded := _circles_map.duplicate()
			padded.resize(FogVision.MAX_SHADER_CIRCLES)
			_mat.set_shader_parameter("circle_count", _circles_map.size())
			_mat.set_shader_parameter("circles", padded)
		_update_los(_mask_vp.size, 1.0)   # (hides the shape nodes, if any were up)
		stats.mask_us = Time.get_ticks_usec() - t0
		return
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

var _circles_uploaded := PackedVector4Array()

# The vision circles in MAP px (x, y, r): _circles_map the plain ones (the composite shader's), _circles_all
# every one, a unit with a viewshed shape included (what rect_under_fog and the background bake go by).
# Each has a serial that moves when its list does.
func _scan_circles() -> void:
	var plain := PackedVector4Array()
	var all := PackedVector4Array()
	var ppm := terrain.px_per_m
	var limit := mini(vision.max_circles, FogVision.MAX_SHADER_CIRCLES)
	for c: Dictionary in vision.circles:
		var v := Vector4(float(c.x) * ppm, float(c.y) * ppm, float(c.r) * ppm, 0.0)
		all.append(v)
		if plain.size() < limit and not c.has("shed"):
			plain.append(v)
	if plain != _circles_map:
		_circles_map = plain
		_circle_serial += 1
	if all != _circles_all:
		_circles_all = all
		_hidden_serial += 1

# What rect_out_of_sight() depends on, for a caller that caches its answers (MapView.sight_sig): the circles,
# the zoom (the edge's reach in map px) and the edge mode.
func hidden_signature() -> Array:
	return [_hidden_serial, _zoom, edge_mode]

# Where the units are, map px: the points the map's background bake works outward from.
func anchor_points_px() -> PackedVector2Array:
	var out := PackedVector2Array()
	for c: Vector4 in _circles_all:
		out.append(Vector2(c.x, c.y))
	return out

# The signed distance the compositor takes to the union of the circles at map-px point `p`, in SCREEN
# px, clamped to +/- range_px: positive inside. The CPU twin of the analytic branch of
# fog_composite.gdshader (test_fog holds the two mask formulas to each other).
static func analytic_sdf_px(circles_map: PackedVector4Array, p: Vector2, zoom: float, range_px_v: float) -> float:
	var best := -1.0e9
	for c: Vector4 in circles_map:
		best = maxf(best, c.z - p.distance_to(Vector2(c.x, c.y)))
	return clampf(best * zoom, -range_px_v, range_px_v)

# queue_redraw() only when what _draw draws has changed: the chunks in view, the level of detail, the
# zoom (the skip test depends on it), the circles, a texture that arrived. A plain pan changes none.
func _redraw_if_changed() -> void:
	var r := view_rect_px()
	var cs := topo.chunk_px
	var sig: Array = [floori(r.position.x / cs), floori(r.position.y / cs), floori((r.end.x - 0.001) / cs), floori((r.end.y - 0.001) / cs),
		_zoom, _overview > 0.0, _circle_serial, _cache_serial, int(map_serial.call()) if map_serial.is_valid() else 0]
	if sig != _redraw_sig:
		_redraw_sig = sig
		queue_redraw()
	else:
		stats.redraws_skipped = int(stats.redraws_skipped) + 1

func _sync_stats() -> void:
	var bs: Dictionary = _baker.stats
	stats.record_ms = bs.record_ms
	stats.record_ms_max = bs.record_ms_max
	stats.finished = bs.finished
	stats.main_ms = bs.main_ms
	stats.main_ms_max_frame = bs.main_ms_max_frame

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
			_apply_interp(new_mat)
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
	stats.draws = int(stats.draws) + 1
	var lod := topo.lod_for_zoom(_zoom)
	var n := 0
	for c in terrain.chunks_in_rect_px(view_rect_px()):
		var r := topo.chunk_rect_px(c)
		if _overview <= 0.0 and not _forced.has(c) and _inside_vision(c):
			continue
		var tex: Texture2D = _best(c, lod)
		if tex != null:
			draw_texture_rect(tex, r, false)
		else:
			draw_rect(r, topo.paper_levels[0])
		n += 1
	stats.draw_chunks = n
	stats.draw_us = Time.get_ticks_usec() - t0

# The chunks of the map the map layer shows nothing over, as a set and as the shader's mask: made again only when the
# map layer's chunks changed (map_serial), so a pan costs nothing here.
func _update_forced() -> void:
	var serial := int(map_serial.call()) if map_serial.is_valid() else 0
	if serial == _forced_serial and _forced_tex != null:
		return
	_forced_serial = serial
	var range_c: Rect2i = terrain.map_chunk_range()
	var w := maxi(range_c.size.x, 1)
	var h := maxi(range_c.size.y, 1)
	if _forced_img == null or _forced_img.get_width() != w or _forced_img.get_height() != h:
		_forced_img = Image.create(w, h, false, Image.FORMAT_R8)
		_forced_tex = null
	_forced = {}
	for cy in range(range_c.position.y, range_c.position.y + range_c.size.y):
		for cx in range(range_c.position.x, range_c.position.x + range_c.size.x):
			var c := Vector2i(cx, cy)
			var forced := map_ready.is_valid() and not bool(map_ready.call(topo.chunk_rect_px(c)))
			if forced:
				_forced[c] = true
			_forced_img.set_pixel(cx - range_c.position.x, cy - range_c.position.y, Color.WHITE if forced else Color.BLACK)
	if _forced_tex == null:
		_forced_tex = ImageTexture.create_from_image(_forced_img)
		_mat.set_shader_parameter("forced_mask", _forced_tex)
	else:
		_forced_tex.update(_forced_img)
	var o := Vector2(range_c.position) * topo.chunk_px
	_mat.set_shader_parameter("forced_rect", Vector4(o.x, o.y, w * topo.chunk_px, h * topo.chunk_px))

# Does the map layer show something over this map-px rectangle (the floor: if not, the contours show)?
func _map_there(r: Rect2) -> bool:
	return not map_ready.is_valid() or bool(map_ready.call(r))

# Chunks of the view where nothing is painted: no contour texture at any level (fresh or stale), and the map
# layer does not show the place either (inside vision with the ground baked). 0 is the rule.
func unpainted_in_view() -> int:
	if topo == null:
		return 0
	var n := 0
	for c in terrain.chunks_in_rect_px(view_rect_px()):
		if _best(c, topo.lod_for_zoom(_zoom)) != null:
			continue
		var r := topo.chunk_rect_px(c)
		if _overview <= 0.0 and _map_there(r) and _inside_vision(c):
			continue
		n += 1
	return n

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

# Is a map-px rectangle wholly under the opaque topographic layer: the overview
# is off and no vision circle comes within the edge effect's reach of it (the
# mask's whole range, as _inside_vision keeps)? A circle with a viewshed counts
# as its full circle (the shape lies inside it), so this is conservative: a
# rectangle it calls hidden is hidden. MapView bakes such chunks last.
func rect_under_fog(rect_px: Rect2) -> bool:
	if topo == null or _overview > 0.0:
		return false
	var r := rect_px.grow(range_px / maxf(_zoom, 1e-6))
	var ppm := terrain.px_per_m
	for circ: Dictionary in vision.circles:
		var cx: float = circ.x * ppm
		var cy: float = circ.y * ppm
		var rr: float = circ.r * ppm
		var q := Vector2(clampf(cx, r.position.x, r.end.x), clampf(cy, r.position.y, r.end.y))
		if (q.x - cx) * (q.x - cx) + (q.y - cy) * (q.y - cy) <= rr * rr:
			return false
	return true

# How far past the vision edge the full render can still show through the compositor, in SCREEN px: the
# inked edge cuts at the edge moved by its wobble (a 1 px antialiased cut); the soft one fades over
# feather_px with two octaves of noise on the edge. Plus a pixel of slack.
func edge_reach_px() -> float:
	if edge_mode == EDGE_SOFT:
		return fog_data.num("edge.soft.feather_px") * 0.5 + 1.5 * fog_data.num("edge.soft.wobble_px") + 1.0
	return fog_data.num("edge.inked.wobble_px") + 1.0

# Is a map-px rectangle OUT OF SIGHT: no vision circle comes within the edge's reach of it, so the full
# render can show nowhere on it (the topographic layer is opaque there)? Unlike rect_under_fog() it does not
# depend on the overview: the full render shows through the fade of the overview wherever sight reaches, so
# these are the chunks whose ground is ever seen. A circle with a viewshed counts as its full circle (the
# shape lies inside it), so this is conservative: a rectangle it calls out of sight is. MapView bakes
# everything else first and the rest in the background (map_view.hidden_test).
func rect_out_of_sight(rect_px: Rect2) -> bool:
	if topo == null:
		return false
	var r := rect_px.grow(edge_reach_px() / maxf(_zoom, 1e-6))
	var ppm := terrain.px_per_m
	for circ: Dictionary in vision.circles:
		var cx: float = circ.x * ppm
		var cy: float = circ.y * ppm
		var rr: float = circ.r * ppm
		var q := Vector2(clampf(cx, r.position.x, r.end.x), clampf(cy, r.position.y, r.end.y))
		if (q.x - cx) * (q.x - cx) + (q.y - cy) * (q.y - cy) <= rr * rr:
			return false
	return true

# The baked texture for c at `lod`, else the nearest other level that is baked, else (a rebake under way) the
# same from the earlier bake. The coarsest level, the whole-map overview, is made first, so a chunk the layer has
# anything of has it.
func _best(c: Vector2i, lod: int) -> Texture2D:
	var hit: Variant = _find(_cache, c, lod)
	if hit == null and not _stale.is_empty():
		hit = _find(_stale, c, lod)
	return hit

func _find(cache: Dictionary, c: Vector2i, lod: int) -> Variant:
	var hit: Variant = cache.get(Vector3i(c.x, c.y, lod))
	if hit != null:
		return hit
	for d in range(1, topo.lods.size()):
		for l: int in [lod + d, lod - d]:
			if l >= 0 and l < topo.lods.size():
				hit = cache.get(Vector3i(c.x, c.y, l))
				if hit != null:
					return hit
	return null

# --- baking ----------------------------------------------------------------------------------

# A texture baked elsewhere (Track V's baker) for chunk c at level `lod`.
func set_topo_chunk(c: Vector2i, lod: int, tex: Texture2D) -> void:
	_cache[Vector3i(c.x, c.y, lod)] = tex
	_cache_serial += 1
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
			_cache_serial += 1
		var t2 := Time.get_ticks_usec()
		rec += (t1 - t0) / 1000.0
		ren += (t2 - t1) / 1000.0
	queue_redraw()
	return {"count": todo.size(), "record_ms": rec, "render_ms": ren}

# The chunks to bake at `lod`, nearest the view's centre first, the view's own
# before the ring round it (a ring chunk a hair nearer the centre must not go
# first): not cached, not queued or in flight, and not wholly inside vision (the full
# render shows there, unless the overview is on).
func wanted_chunks(view: Rect2, lod: int) -> Array[Vector2i]:
	var centre := view.get_center()
	var scored: Array = []   # [distance, chunk]
	for c in terrain.chunks_in_rect_px(view.grow(topo.chunk_px)):
		var key := Vector3i(c.x, c.y, lod)
		if _cache.has(key) or (_baker != null and _baker.is_queued_or_running(key)):
			continue
		if _overview <= 0.0 and _inside_vision(c):
			continue
		var r := topo.chunk_rect_px(c)
		scored.append([r.get_center().distance_squared_to(centre) + (0.0 if view.intersects(r) else 1.0e18), c])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array[Vector2i] = []
	for e: Array in scored:
		out.append(e[1])
	return out

# The pipeline, built on the first frame that bakes. A baker belongs to one FogTopo (one scale):
# a new FogTopo (set_terrain) means new twins.
func _ensure_baker() -> void:
	if _baker != null and _baker_topo == topo:
		return
	if _baker != null:
		_baker.shutdown()
	var twins: Array = []
	for _i in (twin_count if worker_recording else 1):
		twins.append(topo.make_twin())
	_baker = FogTopoBaker.new(topo, twins, max_inflight, bakes_per_frame, main_budget_ms, main_budget_loading_ms, worker_recording)
	_baker.on_done = _on_baked
	_baker_topo = topo
	_enqueued_for = null

func _on_baked(key: Vector3i, tex: Texture2D) -> void:
	_cache[key] = tex
	bake_counts[key] = int(bake_counts.get(key, 0)) + 1
	_cache_serial += 1
	stats.bakes = int(stats.bakes) + 1
	_evict()

# Every chunk of the map at every level of detail not cached yet: the zoom's level of detail first,
# then the others by how far they are from it (the next zoom out or in); nearest the view's centre
# first within a level. (The twins deal them out in bands of rows, so each makes the terrain it needs once.)
func whole_map_keys() -> Array[Vector3i]:
	var centre := view_rect_px().get_center()
	var cur := topo.lod_for_zoom(_zoom)
	var scored: Array = []   # [lod distance, chunk distance, key]
	for c in terrain.chunks_in_rect_px(terrain.map_rect_px()):
		var d := topo.chunk_rect_px(c).get_center().distance_squared_to(centre)
		for lod in topo.lods.size():
			var key := Vector3i(c.x, c.y, lod)
			if not _cache.has(key):
				scored.append([absi(lod - cur), d, key])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var out: Array[Vector3i] = []
	for e: Array in scored:
		out.append(e[2])
	return out

# Queues what has to be baked (see the header): the whole map once, or with topo.whole_map false the
# chunks the view wants at the zoom's level of detail, as they come.
func _schedule() -> void:
	if bakes_per_frame <= 0:
		return
	_ensure_baker()
	if whole_map:
		if _enqueued_for != topo:
			_enqueued_for = topo
			_baker.enqueue(whole_map_keys())
		return
	var lod := topo.lod_for_zoom(_zoom)
	var want := wanted_chunks(view_rect_px(), lod)
	if not want.is_empty():
		var keys: Array = []
		for c in want:
			keys.append(Vector3i(c.x, c.y, lod))
		_baker.enqueue(keys)

# Bakes in the pipeline now (recording, submitting, drawing, being read back).
func bakes_in_flight() -> int:
	return 0 if _baker == null else _baker.in_flight()

# What is left of the work the layer asked for, how much there was, and how much is done: the
# loading card's numbers. With topo.whole_map, total counts every chunk at every level of detail.
func bake_remaining() -> int:
	return 0 if _baker == null else _baker.remaining()

func bake_total() -> int:
	return 0 if _baker == null else _baker.total()

func bake_done() -> int:
	return bake_total() - bake_remaining()

# Has everything been made: the whole map at every level of detail cached (topo.whole_map), or at
# least nothing waits? False before the first frame that bakes.
func bake_complete() -> bool:
	if not whole_map:
		return bake_remaining() == 0
	return _baker != null and _enqueued_for == topo and _baker.remaining() == 0

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
	var coarsest := topo.lods.size() - 1
	var i := 0
	while _cache.size() > cache_cap and i < keys.size():
		if keys[i].z != coarsest:   # the whole-map overview is the floor: never dropped
			_cache.erase(keys[i])
		i += 1
