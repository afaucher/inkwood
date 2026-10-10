extends RefCounted

# THE ROUGH TOPOGRAPHIC LAYER (Track F, first option): what the map shows
# outside vision, and everywhere at far zoom (data/view/camera.json far_zoom).
# Alex's rule (design doc decision log): "a rough topographic map resolves to
# the full render near units". Built from Track T's terrain alone: its height
# levels as tones on a paler map sheet, its level boundaries as bundles of
# contour lines (top, middle and foot of the scarp), and a map grid. Paper
# only: no trees, no shadows, no grain. Every value is in data/view/fog.json
# (topo.*), every colour a role (fog_style.gd); all of it proposed.
#
# SCALE: every px value here is made from metres x terrain.px_per_m when the
# FogTopo is built; px_per_m is a live knob (1-4), so a FogTopo is for ONE
# scale (`ppm`) -- FogLayer rebuilds it and drops its baked chunks when the
# terrain's scale changes. Line widths are in texels and do not change.
#
# BAKED PER CHUNK, like the main map (Track V's chunks: Terrain's chunk_m x
# px_per_m world px, chunk (cx, cy) at (cx, cy) x chunk_px). The provider entry
# points, for V's baker or anyone else:
#
#   var topo := FogTopo.new(terrain)                         # reads data/view/fog.json
#   topo.record_chunk(g, c, view)       # RECORD onto an InkCanvas -- no rendering, so
#                                       # a worker thread may call it (see THREADS)
#   topo.make_canvas(c, texels_per_px) -> InkCanvas          # sized + recorded, unrendered
#   topo.bake_chunk(c, texels_per_px) -> ImageTexture        # main thread; forces a frame
#   FogTopo.bake_topo_chunk(terrain, c, view) -> ImageTexture   # the one-call form
#
# `view` maps world px to chunk-canvas px: scale s = texels per world px, then
# minus the chunk's origin (view_for()). The layer keeps several levels of
# detail (topo.lods) and shows each near 1:1, so line widths are given in
# TEXELS of the bake (topo.lines.width_texels) and divided by s here: a map line
# stays about a screen pixel wide at every zoom instead of thinning to nothing.
#
# THREADS: record_chunk calls only Terrain's chunk queries (chains_px,
# polys_px, chunks_in_rect_px) and records an InkCanvas, as Track T's own
# TerrainDraw.draw_linework does. Terrain caches chunk geometry in plain
# Dictionaries with no lock, and the main thread queries the same Terrain
# (the vision, the viewshed, the units' heights), so a worker must never
# touch THAT one. make_canvas_threaded() is the worker entry point: it records
# on a private TWIN of this layer built over its own Terrain (same seed, data
# and scale, so the same geometry bit for bit), one chunk at a time under a
# mutex (Terrain's caches are not thread-safe within the twin either).
# prepare_threaded() builds the twin and MUST be called on the main thread
# first (it reads the shared CameraData, which records what it hands out).
# The cost is that the twin generates the terrain chunks it records a second
# time (once per terrain chunk, on a worker); sharing one Terrain between the
# map, the fog and the interface needs a thread-safe Terrain (proposed).
#
# Textures come back with mipmaps (the layer minifies a level up to 1/lod_ratio).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

const SALT_WOBBLE := 4111   # noise-stream salt (a code constant, not a tunable)

var terrain: Terrain
var P: RenderParams
var data: CameraData
var errors: Array = []

var chunk_px: float
var ppm: float                        # the terrain's px_per_m these px values were made for
var paper_levels: Array[Color] = []   # the map sheet per height level
var outside: Color                    # wash over the map outside vision (the layer's shader)
var line_color: Color
var line_w: float                     # texels
var offsets_px := PackedFloat64Array()
var alphas := PackedFloat64Array()
var wobble_px: float
var wobble_per_px: float
var grid_px: float                    # 0: no grid
var grid_color: Color
var grid_w: float                     # texels
var lods := PackedFloat64Array()      # texels per world px, finest first
var lod_ratio: float
var noise_seed: int

var _twin: RefCounted = null          # a FogTopo over a private Terrain, for worker threads
var _twin_lock := Mutex.new()

func _init(t: Terrain, fog_data: CameraData = null, params: RenderParams = null) -> void:
	terrain = t
	P = params if params != null else RenderParams.new()
	data = fog_data if fog_data != null else CameraData.new(CameraData.FOG_PATH)
	ppm = terrain.px_per_m
	chunk_px = terrain.chunk_m * ppm
	var sheet := FogStyle.resolve(data.value("topo.paper_role"), P, errors)
	var step := data.num("topo.level_lift")
	var chroma := data.num("topo.level_chroma")
	for k in terrain.level_count():
		paper_levels.append(TerrainDraw.lift(sheet, step * k, pow(chroma, k)))
	outside = FogStyle.resolve(data.value("topo.outside_role"), P, errors)
	line_color = FogStyle.resolve(data.value("topo.lines.role"), P, errors)
	line_w = data.num("topo.lines.width_texels")
	for o in data.floats("topo.lines.offsets_m"):
		offsets_px.append(o * ppm)
	alphas = data.floats("topo.lines.alphas")
	if alphas.size() != offsets_px.size():
		_err("topo.lines.alphas needs one entry per topo.lines.offsets_m")
	wobble_px = data.num("topo.lines.wobble_m") * ppm
	wobble_per_px = data.num("topo.lines.wobble_per_m") / ppm
	grid_px = data.num("topo.grid.spacing_m") * ppm
	grid_color = FogStyle.resolve(data.value("topo.grid.role"), P, errors)
	grid_w = data.num("topo.grid.width_texels")
	lods = data.floats("topo.lods")
	for i in lods.size():
		if not (lods[i] > 0.0) or (i > 0 and lods[i] >= lods[i - 1]):
			_err("topo.lods must be positive and finest first, got %s" % [lods])
			break
	lod_ratio = data.num("topo.lod_ratio")
	noise_seed = terrain.seed_value % 9973 + SALT_WOBBLE

func ok() -> bool:
	return errors.is_empty() and data.ok()

func _err(message: String) -> void:
	errors.append(message)
	push_error("FogTopo: " + message)

# --- chunks and levels of detail ------------------------------------------------------

func chunk_rect_px(c: Vector2i) -> Rect2:
	return Rect2(c.x * chunk_px, c.y * chunk_px, chunk_px, chunk_px)

# World px -> chunk-canvas px at `texels_per_px`.
func view_for(c: Vector2i, texels_per_px: float) -> Transform2D:
	var o := chunk_rect_px(c).position
	return Transform2D(Vector2(texels_per_px, 0.0), Vector2(0.0, texels_per_px), -o * texels_per_px)

func canvas_size(texels_per_px: float) -> Vector2i:
	var n := maxi(1, ceili(chunk_px * texels_per_px - 1e-6))
	return Vector2i(n, n)

# The level of detail the layer shows at `zoom` (screen px per world px): the
# coarsest whose texels per world px are still >= lod_ratio x zoom, so it is
# never magnified past 1 / lod_ratio; the finest when none is.
func lod_for_zoom(zoom: float) -> int:
	for i in range(lods.size() - 1, -1, -1):
		if lods[i] >= lod_ratio * zoom:
			return i
	return 0

# --- the provider --------------------------------------------------------------------

static func bake_topo_chunk(t: Terrain, chunk: Vector2i, view: Transform2D) -> ImageTexture:
	var topo = load("res://scripts/render/fog_topo.gd").new(t)
	var s := view.x.length()
	var g := InkCanvas.new(topo.canvas_size(s))
	topo.record_chunk(g, chunk, view)
	return texture_from(g.finish_image())

func make_canvas(c: Vector2i, texels_per_px: float) -> InkCanvas:
	var g := InkCanvas.new(canvas_size(texels_per_px))
	record_chunk(g, c, view_for(c, texels_per_px))
	return g

# MAIN THREAD, once: the private twin make_canvas_threaded() records on.
func prepare_threaded() -> void:
	if _twin != null:
		return
	var twin_terrain := Terrain.new(terrain.seed_value, terrain.data.source_path, terrain.P)
	twin_terrain.px_per_m = terrain.px_per_m
	_twin = load("res://scripts/render/fog_topo.gd").new(twin_terrain, data, P)

func has_twin() -> bool:
	return _twin != null

# WORKER-THREAD SAFE make_canvas: the same canvas, recorded on the twin (the
# same calls on the same geometry give the same paint calls: test_fog compares
# them). Blocks while another thread records on the twin.
func make_canvas_threaded(c: Vector2i, texels_per_px: float) -> InkCanvas:
	_twin_lock.lock()
	var g: InkCanvas = _twin.make_canvas(c, texels_per_px)
	_twin_lock.unlock()
	return g

func bake_chunk(c: Vector2i, texels_per_px: float) -> ImageTexture:
	return texture_from(make_canvas(c, texels_per_px).finish_image())

static func texture_from(img: Image) -> ImageTexture:
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# Records chunk `c` onto `g` through `view` (world px -> canvas px). Pass order:
# the sheet, the level tones, the grid, the contours.
func record_chunk(g: InkCanvas, c: Vector2i, view: Transform2D) -> void:
	var s := view.x.length()
	var rect := chunk_rect_px(c)
	g.save()
	g.reset_transform()
	g.global_alpha = 1.0
	g.fill_color = paper_levels[0]
	g.fill_rect(0.0, 0.0, float(g.size.x), float(g.size.y))
	g.set_transform_matrix(view)
	if terrain.chunk_in_map(c.x, c.y):
		_level_tones(g, c)
	_grid(g, rect, s)
	if terrain.chunk_in_map(c.x, c.y):
		_contours(g, rect, s)
	g.restore()

# Each level's sheet tone, painted level by level: threshold k's border
# polygons in one fill (no seam between them), then its closed rings largest
# first -- an upland ring in level k+1's tone, a hole in level k's -- which
# paints any nesting right because rings never cross (Track T's level_masks
# does the same in black and white).
func _level_tones(g: InkCanvas, c: Vector2i) -> void:
	for k in terrain.thresholds.size():
		var hi: Color = paper_levels[k + 1]
		var lo: Color = paper_levels[k]
		var rings: Array = []
		g.fill_color = hi
		g.begin_path()
		var any := false
		for poly: Dictionary in terrain.polys_px(c.x, c.y, k):
			if poly.border:
				_add_poly(g, poly.pts)
				any = true
			else:
				rings.append(poly)
		if any:
			g.fill()
		rings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return absf(a.area) > absf(b.area))
		for ring: Dictionary in rings:
			g.fill_color = hi if ring.area > 0.0 else lo
			g.begin_path()
			_add_poly(g, ring.pts)
			g.fill()

static func _add_poly(g: InkCanvas, pts: PackedVector2Array) -> void:
	g.move_to(pts[0].x, pts[0].y)
	for i in range(1, pts.size()):
		g.line_to(pts[i].x, pts[i].y)
	g.close_path()

# Grid lines at whole multiples of the spacing from the world origin, so they
# run on across chunks; a line on a chunk border is drawn half by each side.
func _grid(g: InkCanvas, rect: Rect2, s: float) -> void:
	if grid_px <= 0.0:
		return
	var pad := grid_w / s
	var map := terrain.map_rect_px()
	var r := rect.grow(pad).intersection(map.grow(pad))
	if not r.has_area():
		return
	g.stroke_color = grid_color
	g.line_width = grid_w / s
	g.line_cap = "butt"
	g.begin_path()
	var x := ceilf((r.position.x) / grid_px) * grid_px
	while x <= r.end.x:
		g.move_to(x, maxf(r.position.y, map.position.y))
		g.line_to(x, minf(r.end.y, map.end.y))
		x += grid_px
	var y := ceilf((r.position.y) / grid_px) * grid_px
	while y <= r.end.y:
		g.move_to(maxf(r.position.x, map.position.x), y)
		g.line_to(minf(r.end.x, map.end.x), y)
		y += grid_px
	g.stroke()
	g.line_cap = "round"

# The level boundaries of this chunk and its neighbours (a line offset down the
# slope can reach across the border), one stroke per offset line. Only the
# runs of a chain that come near the chunk are drawn; at a coarse level of
# detail the points are thinned to about a texel apart and sub-texel wobble
# is skipped (it could not show).
func _contours(g: InkCanvas, rect: Rect2, s: float) -> void:
	var reach := 0.0
	for o in offsets_px:
		reach = maxf(reach, o)
	var near := rect.grow(reach + wobble_px + line_w / s + 2.0)
	var chunks := terrain.chunks_in_rect_px(near)
	var every := maxi(1, floori(1.0 / (s * terrain.resample_m * terrain.px_per_m)))
	var wob := wobble_px if wobble_px * s >= 0.2 else 0.0
	g.stroke_color = line_color
	g.line_width = line_w / s
	g.line_cap = "round"
	for k in terrain.thresholds.size():
		var chains: Array = []
		for cc in chunks:
			chains.append_array(terrain.chains_px(cc.x, cc.y, k))
		if chains.is_empty():
			continue
		for j in offsets_px.size():
			g.global_alpha = alphas[j] if j < alphas.size() else 1.0
			g.begin_path()
			var any := false
			for ch: Dictionary in chains:
				any = _add_offset(g, ch.pts, ch.closed, offsets_px[j], k, near, every, wob) or any
			if any:
				g.stroke()
	g.global_alpha = 1.0

# One chain `offset` px down the slope (the chain has the higher level on its
# right, y down, so down is its left: (dy, -dx)), with world-anchored wobble,
# every `every`-th point, only where it comes inside `near`. Returns whether
# anything was added.
func _add_offset(g: InkCanvas, pts: PackedVector2Array, closed: bool, offset: float, k: int,
		near: Rect2, every: int, wob: float) -> bool:
	var n := pts.size()
	if n < 2:
		return false
	var ns := noise_seed + k * 53
	var idx := PackedInt32Array()
	var lim := n if closed else n - 1
	for q in range(0, lim, every):
		idx.append(q)
	if closed:
		idx.append(0)
	elif idx[idx.size() - 1] != n - 1:
		idx.append(n - 1)
	var added := false
	var pen := false
	var m := idx.size()
	for qi in m:
		var i := idx[qi]
		# keep a point if it, or a neighbour on the path, is near the chunk
		var inside := near.has_point(pts[i]) 			or (qi > 0 and near.has_point(pts[idx[qi - 1]])) 			or (qi < m - 1 and near.has_point(pts[idx[qi + 1]]))
		if not inside:
			pen = false
			continue
		var a: Vector2 = pts[(i - 1 + n) % n] if closed else pts[maxi(i - 1, 0)]
		var b: Vector2 = pts[(i + 1) % n] if closed else pts[mini(i + 1, n - 1)]
		var d := b - a
		var l := d.length()
		var nrm := Vector2(d.y, -d.x) / l if l > 0.0 else Vector2.ZERO
		var p := pts[i]
		var w := 0.0
		if wob > 0.0:
			w = (ValueNoise.vnoise(p.x * wobble_per_px, p.y * wobble_per_px, ns) - 0.5) * 2.0 * wob
		var o := p + nrm * (offset + w)
		if pen:
			g.line_to(o.x, o.y)
		else:
			g.move_to(o.x, o.y)
			pen = true
			added = true
	return added
