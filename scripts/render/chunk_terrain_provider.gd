extends "res://scripts/render/chunk_provider.gd"

# Chunk content from Track T's terrain (scripts/world/terrain.gd): height
# levels, hachured scarps, groves per level and height-respecting shadows,
# composed in T's pass order (T's report, 2026-10-09):
#
#   paper ground (+ the village's fields and road: Track W) -> level fill -> linework
#   -> TERRAIN shadow class (the shade) -> STRUCTURE shadow class (the village's houses and
#   walls, cut to level 0 and out of the shade) -> structures -> TREE shadow class (cut by the
#   shade) -> trees sorted by (base + h), then y -> grain
#
# T's TerrainDraw / TerrainShadows render as they go when called whole
# (level_masks, cast_terrain, cast_trees each force a frame). Here the same
# work is split into the baker's stages so the game never waits on it: T's
# RECORD-ONLY functions (add_terrain_silhouettes, add_tree_silhouettes,
# cut_to_receiver, draw_level_fill, draw_linework) do the drawing, and the
# baker renders between stages with the engine's own frames:
#
#   gather        (worker, terrain lane) T generates every chunk the bake touches; the trees
#                 whose shadows or canopies reach this chunk, copied and sorted
#   sprites       (baker) a sprite per tree (atlas pages, cached across chunks)
#   ground        (worker, parallel) paper, specks, fibres, dirt -- at WORLD
#                 coordinates (chunk_provider.gd)
#   levels        (main) the level masks: T's level_masks, recorded here
#                 without its forced render (_record_level_masks)
#   terrain_sil   (worker) scarp prisms per receiver level
#   terrain_cut   (main) each cut to its receiver -> rendered
#   terrain_merge (main) summed into one class mask (T's merge shader) -> the shade
#   struct_sil    (worker) the village's prisms (Track W): a house or a wall casts like the
#                 prototype's castShadows, onto level 0 only (the village stands on it)
#   struct_cut    (main) cut to level 0 and out of the shade -> rendered
#   struct_merge  (main) -> the structure class mask
#   tree_sil      (worker) trunks and stretched canopies per receiver level
#   tree_cut      (main) each cut to its receiver and out of the shade -> rendered
#   tree_merge    (main) summed -> the tree class mask
#   fill          (main) T's level fill onto the ground (its materials)
#   linework      (worker) T's contours and hachures
#   frame         (main) the shade, the structure class, the structures, the tree class, the
#                 trees, grain -> the chunk
#
# THE VILLAGE (Track W, 2026-10-10; scripts/world/village.gd, world_layout.gd): its houses and
# walls (the prototype's makeHouse and makeFort, drawn by ink_structs.gd through the baker's
# sprite stage like trees), its road and its fields (village_draw.gd, on the ground canvas) and
# the hedge trees along some field edges (the tree layer). A chunk's share of all of it is a
# function of the village and the chunk's rectangle alone, so bake order never changes a pixel;
# a chunk the village does not reach takes none of the new branches and bakes exactly as before.
#
# T's caches are not thread-safe, so every call into the Terrain object holds
# _tmutex: workers wait for it, main-thread stages only try it (a stage that
# finds it held returns null and runs next frame), so a main frame never
# blocks on generation. The worker stages that call T run in the baker's
# "terrain" LANE, one at a time, so none holds a worker slot while it waits
# for the lock; and warm_chunk() generates the next ring ahead of the camera
# whenever that lane is idle.
#
# SCALE: px_per_m comes from data/terrain/terrain.json (T's scale.px_per_m)
# unless the MapView overrides it; set_px_per_m() regenerates from scratch
# (the baker's clear() then rebakes).

const Terrain = preload("res://scripts/world/terrain.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")
const VillageDraw = preload("res://scripts/render/village_draw.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const TERRAIN_DATA_PATH := "res://data/terrain/terrain.json"

var terrain: Terrain
var td: TerrainDraw
var ts: TerrainShadows
var vd: VillageDraw
var errors: Array[String] = []

var _tmutex := Mutex.new()
var _merge_mat_shader: Shader

func _init(seed_v: int, params: RenderParams, view_cfg: Dictionary, px_per_m: float = 0.0) -> void:
	seed_value = seed_v
	P = params
	P.L["road"] = false
	chunk_px = int(view_cfg.get("chunk_px", 1024))
	terrain = Terrain.new(seed_v, TERRAIN_DATA_PATH, P)
	if px_per_m > 0.0:
		terrain.px_per_m = px_per_m
	td = TerrainDraw.new(terrain, P)
	ts = TerrainShadows.new(terrain, P)
	vd = VillageDraw.new(terrain, P)
	if not terrain.ok():
		errors.append_array(terrain.errors)
		errors.append_array(terrain.data.errors)
	errors.append_array(td.errors)
	errors.append_array(vd.errors)

func ok() -> bool:
	return errors.is_empty()

func prepare() -> void:
	super.prepare()
	_merge_mat_shader = Shader.new()
	_merge_mat_shader.code = TerrainShadows._MERGE_SHADER
	# T's cut and fill shaders are made on their first (main-thread) use.
	# The world layout and the village are made here, on the main thread, before any worker asks.
	_tmutex.lock()
	terrain.village()
	_tmutex.unlock()

# The village at the current scale (null when there is none), made under the terrain lock.
func village() -> RefCounted:
	_tmutex.lock()
	var v: RefCounted = terrain.village()
	_tmutex.unlock()
	return v

func px_per_m() -> float:
	return terrain.px_per_m

# The map in world px.
func map_rect_px() -> Rect2:
	return terrain.map_rect_px()

# A new scale: everything T generated is dropped (it is generated in px).
func set_px_per_m(v: float) -> void:
	_tmutex.lock()
	terrain.px_per_m = v
	terrain.clear_cache()
	vd.forget()
	_tmutex.unlock()

func clear_cache() -> void:
	_tmutex.lock()
	terrain.clear_cache()
	vd.forget()
	_tmutex.unlock()

func reach_px() -> float:
	return ts.reach_px()

# Generation ahead of need (chunk_baker.gd warm): T's trees for chunk c and
# its reach, in T's lane so it never waits behind -- or holds up -- a bake.
func warm_lane() -> String:
	return "terrain"

# One of T's own chunks per lock hold (T generates per chunk_m, 256 m), so a
# warm task never keeps the lock -- or a waiting bake -- for long.
func warm_chunk(c: Vector2i) -> void:
	_tmutex.lock()
	var cells := terrain.chunks_in_rect_px(chunk_rect(c).grow(ts.reach_px()))
	_tmutex.unlock()
	for t in cells:
		_tmutex.lock()
		terrain.trees_in_chunk(t.x, t.y)
		_tmutex.unlock()

func stages() -> Array:
	return [
		{"name": "gather", "thread": "worker", "lane": "terrain", "fn": _gather},
		{"builtin": "sprites"},
		{"name": "ground", "thread": "worker", "parallel": true, "fn": _ground},
		{"name": "levels", "thread": "main", "fn": _levels},
		{"name": "terrain_sil", "thread": "worker", "lane": "terrain", "fn": _terrain_sil},
		{"name": "terrain_cut", "thread": "main", "fn": _terrain_cut},
		{"name": "terrain_merge", "thread": "main", "fn": _terrain_merge},
		{"name": "struct_sil", "thread": "worker", "fn": _struct_sil},
		{"name": "struct_cut", "thread": "main", "fn": _struct_cut},
		{"name": "struct_merge", "thread": "main", "fn": _struct_merge},
		{"name": "tree_sil", "thread": "worker", "lane": "terrain", "fn": _tree_sil},
		{"name": "tree_cut", "thread": "main", "fn": _tree_cut},
		{"name": "tree_merge", "thread": "main", "fn": _tree_merge},
		{"name": "fill", "thread": "main", "join": true, "fn": _fill},
		{"name": "linework", "thread": "worker", "lane": "terrain", "fn": _linework},
		{"name": "frame", "thread": "main", "final": true, "fn": _frame},
	]

# The trees whose centre lies in the chunk grown by reach_px(), sorted as
# T draws them: base + h, then y, then x -- the terrain's own and the hedge trees of the fields
# (Track W) -- and the village's structures that reach it. Pure in (seed, chunk).
func chunk_content(c: Vector2i) -> Dictionary:
	var grown := chunk_rect(c).grow(ts.reach_px())
	_tmutex.lock()
	var trees: Array = terrain.trees_in_rect_px(grown)
	var vil: RefCounted = terrain.village()
	var hedges: Array = vd.hedge_trees(vil) if vil != null else []
	_tmutex.unlock()
	var copies: Array = []
	for t: Dictionary in trees:
		copies.append(t.duplicate())
	for t: Dictionary in hedges:
		if grown.has_point(Vector2(t.x, t.y)):
			copies.append(t.duplicate())
	copies.sort_custom(tree_less)
	var structs: Array = []
	if vil != null:
		for s: Dictionary in vil.structs_in_rect(grown):
			structs.append(s.duplicate())
	return {"trees": copies, "structs": structs, "village": vil}

static func tree_less(a: Dictionary, b: Dictionary) -> bool:
	var ha: float = a.base + a.h
	var hb: float = b.base + b.h
	if ha != hb:
		return ha < hb
	if a.y != b.y:
		return a.y < b.y
	return a.x < b.x

# --- stages ---------------------------------------------------------------------------------

func _gather(job: Dictionary) -> Dictionary:
	var c: Vector2i = job.c
	var rect: Rect2 = job.rect
	var content := chunk_content(c)
	# Warm T's caches for everything the later stages touch, so the main-thread
	# stages only read them.
	var scarp := terrain.scarp_m * terrain.px_per_m
	_tmutex.lock()
	for ch in terrain.chunks_in_rect_px(rect.grow(maxf(ts.reach_px(), scarp * 2.0))):
		for k in terrain.thresholds.size():
			terrain.chains_px(ch.x, ch.y, k)
			terrain.polys_px(ch.x, ch.y, k)
	_tmutex.unlock()
	var sprite_objects: Array = (content.trees as Array).duplicate()
	sprite_objects.append_array(content.structs)
	return {"data": {"trees": content.trees, "structs": content.structs, "village": content.village,
		"sprite_objects": sprite_objects}}

func _ground(job: Dictionary) -> Dictionary:
	var g := record_ground(job.view, job.rect, job.size, job.c)
	# the village's fields and road (Track W): a chunk it does not reach draws nothing more
	var vil: Variant = job.data.get("village")
	if vil != null:
		vd.draw_ground(g, vil, job.rect)
		g.set_transform_matrix(job.view)
	return {"data": {"g": g}}

# T's level_masks without its render_all: one canvas per threshold, white
# where the level is k+1 or more, black elsewhere (terrain_draw.gd,
# level_masks -- the same fills in the same order).
func _levels(job: Dictionary) -> Variant:
	if not _tmutex.try_lock():
		return null
	var view: Transform2D = job.view
	var size: Vector2i = job.size
	var chunks := terrain.chunks_in_rect_px(TerrainDraw.view_rect(view, size))
	var out: Array = []
	for k in terrain.thresholds.size():
		var g := InkCanvas.new(size)
		g.fill_color = Color.BLACK
		g.fill_rect(0.0, 0.0, float(size.x), float(size.y))
		g.set_transform_matrix(view)
		g.fill_color = Color.WHITE
		g.begin_path()
		var rings: Array = []
		var any := false
		for ch in chunks:
			for poly: Dictionary in terrain.polys_px(ch.x, ch.y, k):
				if poly.border:
					TerrainDraw._add_poly(g, poly.pts)
					any = true
				else:
					rings.append(poly)
		if any:
			g.fill()
		rings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return absf(a.area) > absf(b.area))
		for ring: Dictionary in rings:
			g.fill_color = Color.WHITE if ring.area > 0.0 else Color.BLACK
			g.begin_path()
			TerrainDraw._add_poly(g, ring.pts)
			g.fill()
		out.append(g)
	_tmutex.unlock()
	return out

func _terrain_sil(job: Dictionary) -> Dictionary:
	var parts: Array = []
	_tmutex.lock()
	for r in terrain.level_count() - 1:
		var sp := ShadowPass.new(job.size)
		var n := ts.add_terrain_silhouettes(sp, r, job.view, job.rect)
		parts.append([r, sp, n])
	_tmutex.unlock()
	return {"data": {"terrain_sps": parts}}

func _terrain_cut(job: Dictionary) -> Variant:
	return _cut(job.data.terrain_sps, job.data.levels, null)

func _terrain_merge(job: Dictionary) -> Variant:
	return _merge(job.data.get("terrain_cut", []), job.size)

# The village's prisms (Track W): castShadows' wall and house branch -- each footprint piece and
# the same piece shifted by (height x 1/tan elevation) along the shadow, as one hull, all filled
# into one mask. The village stands on level 0, so the one part is for receiver 0: the cut keeps
# what lands on level 0 and drops what would land on a scarp's slope or top. No terrain access
# here, so no lane. A chunk with no structure makes nothing.
func _struct_sil(job: Dictionary) -> Dictionary:
	var structs: Array = job.data.get("structs", [])
	if structs.is_empty():
		return {"data": {"struct_sps": []}}
	var sp := ShadowPass.new(job.size)
	var m := sp.canvas
	m.set_transform_matrix(job.view)
	m.fill_color = Color.BLACK
	m.begin_path()
	for o: Dictionary in structs:
		var shift := ts.dir * (float(o.h) * ts.L)
		if o.kind == "house":
			for p: Dictionary in o.geo:
				_add_prism(m, to_v2(p.corners), shift)
		else:
			var Lp := to_v2(o.L)
			var Rp := to_v2(o.R)
			var n: int = o.pts.size()
			var lim := n if o.closed else n - 1
			for i in lim:
				var j := (i + 1) % n
				_add_prism(m, PackedVector2Array([Lp[i], Lp[j], Rp[j], Rp[i]]), shift)
			for cap: Array in o.caps:
				_add_prism(m, to_v2(cap), shift)
	m.fill()
	return {"data": {"struct_sps": [[0, sp, structs.size()]]}}

static func _add_prism(m: InkCanvas, q: PackedVector2Array, shift: Vector2) -> void:
	var all := q.duplicate()
	for p in q:
		all.push_back(p + shift)
	var hh := Geometry.hull(all)
	if hh.size() >= 3:
		m.move_to(hh[0].x, hh[0].y)
		for i in range(1, hh.size()):
			m.line_to(hh[i].x, hh[i].y)
		m.close_path()

func _struct_cut(job: Dictionary) -> Variant:
	var shade: Variant = job.data.get("terrain_merge")
	return _cut(job.data.get("struct_sps", []), job.data.levels, (shade as Array)[0] if shade is Array and not (shade as Array).is_empty() else null)

func _struct_merge(job: Dictionary) -> Variant:
	return _merge(job.data.get("struct_cut", []), job.size)

func _tree_sil(job: Dictionary) -> Dictionary:
	var parts: Array = []
	_tmutex.lock()
	for r in terrain.level_count():
		var sp := ShadowPass.new(job.size)
		var n := ts.add_tree_silhouettes(sp, job.data.trees, r, job.view)
		parts.append([r, sp, n])
	_tmutex.unlock()
	return {"data": {"tree_sps": parts}}

func _tree_cut(job: Dictionary) -> Variant:
	var shade: Variant = job.data.get("terrain_merge")
	return _cut(job.data.tree_sps, job.data.levels, (shade as Array)[0] if shade is Array and not (shade as Array).is_empty() else null)

func _tree_merge(job: Dictionary) -> Variant:
	return _merge(job.data.get("tree_cut", []), job.size)

# Each part with silhouettes cut to its receiver (and out of the shade);
# empty parts are dropped unrendered. T's cut_to_receiver makes a material,
# so this is a main-thread stage.
func _cut(parts: Array, levels: Array, shade: Texture2D) -> Variant:
	var out: Array = []
	for p: Array in parts:
		var sp: ShadowPass = p[1]
		if p[2] > 0:
			ts.cut_to_receiver(sp, levels, p[0], shade)
			out.append(sp.canvas)
		else:
			sp.canvas.discard()
	return out

# The class's receiver masks summed into one (T's composite_parts without its
# composite): a canvas rendered into the class mask, or nothing.
func _merge(parts: Variant, size: Vector2i) -> Variant:
	var list: Array = parts if parts is Array else []
	if list.is_empty():
		return []
	var mat := ShaderMaterial.new()
	mat.shader = _merge_mat_shader
	for i in list.size():
		mat.set_shader_parameter("p%d" % i, list[i])
	mat.set_shader_parameter("count", list.size())
	var m := InkCanvas.new(size)
	m.draw_image_with_material(list[0], 0.0, 0.0, float(size.x), float(size.y), mat)
	return [m]

func _fill(job: Dictionary) -> Array:
	td.draw_level_fill(job.data.g, job.data.levels)
	return []

func _linework(job: Dictionary) -> Array:
	_tmutex.lock()
	td.draw_linework(job.data.g, job.view, job.rect)
	_tmutex.unlock()
	return []

func _frame(job: Dictionary) -> Array:
	var g: InkCanvas = job.data.g
	var shade: Variant = job.data.get("terrain_merge")
	if shade is Array and not (shade as Array).is_empty():
		composite_mask(g, shade[0])
	# the village's houses and walls, and their shadows (the prototype's order: structure shadows,
	# then the structures; Track W)
	var cast: Variant = job.data.get("struct_merge")
	if cast is Array and not (cast as Array).is_empty():
		composite_mask(g, cast[0])
	g.set_transform_matrix(job.view)
	if P.L.objects:
		for o: Dictionary in job.data.get("structs", []):
			g.draw_image(o.sprite, o.bx, o.by, o.bw, o.bh)
	var cls: Variant = job.data.get("tree_merge")
	if cls is Array and not (cls as Array).is_empty():
		composite_mask(g, cls[0])
	g.set_transform_matrix(job.view)
	if P.L.objects:
		for t: Dictionary in job.data.trees:
			var s: float = t.half * 2.0
			g.draw_image(t.sprite, t.x - t.half, t.y - t.half, s, s)
	apply_grain(g)
	return [g]
