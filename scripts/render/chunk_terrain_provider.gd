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
# its mutex: workers wait for it, main-thread stages only try it (a stage that
# finds it held returns null and runs next frame), so a main frame never
# blocks on generation. The worker stages that call T run in the baker's
# "terrain" LANE, one at a time, so none holds a worker slot while it waits
# for the lock; and warm_chunk() generates the next ring ahead of the camera
# whenever that lane is idle.
#
# SEVERAL TERRAINS, SEVERAL LANES (Track P, 2026-10-10; data map_view.terrain_lanes). One lane was the
# serial part of every bake: 255 ms of generation and 190 of silhouettes and linework per chunk, the
# critical path of the first view (11 s of the 24 chunks' 22 s). Terrain is deterministic in (seed,
# chunk) and its caches are private, so the provider keeps K BUNDLES -- a Terrain with its own
# TerrainDraw, TerrainShadows, VillageDraw and mutex -- and deals the map's chunk ROWS to them in
# bands (each bundle generates its own rows and the margin its neighbours reach into, once). Each
# bundle is a lane of its own ("terrain0", "terrain1", ...: lane_for), so K chunks generate side by
# side. The same seed and data give the same geometry bit for bit, so a chunk's pixels do not depend
# on which bundle made it (test_map_view's determinism checks and scripts/render/map_look_hash.gd hold
# that). `terrain`, `td`, `ts`, `vd` are bundle 0's, for tools and tests that look at one.
#
# SCALE: px_per_m comes from data/terrain/terrain.json (T's scale.px_per_m)
# unless the MapView overrides it; set_px_per_m() regenerates from scratch
# (the baker's clear() then rebakes).
#
# BURNT-OUT TREES (track 'Forest fire', decision forest-fire, 2026-10-11): set_burnt_trees() takes the places (metres) of the trees
# that have burnt down to their trunks. A chunk's content then holds those trees in `trunks` instead of `trees`: no canopy sprite, no
# canopy shadow; the linework stage inks each trunk and its scorch (fire_trunk.gd) and the tree-class shadow gets the trunk's own small
# one. A tree is matched by PLACE (within burnt_tolerance_m, forest_fire.map.match_tolerance_m), never by an id, so the sim's id format
# does not matter. set_burnt_trees() returns the chunks whose content changed -- every chunk whose reach_px()-grown rectangle holds the
# tree, which is exactly where chunk_content() finds it -- for MapView to bake again. Pure in (seed, chunk, the burnt set); the set is
# swapped whole under a mutex, so a worker never sees a half-made one, and each bake records the set's serial (burn_current()).

const Terrain = preload("res://scripts/world/terrain.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")
const VillageDraw = preload("res://scripts/render/village_draw.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const FireTrunk = preload("res://scripts/render/fire_trunk.gd")
const TERRAIN_DATA_PATH := "res://data/terrain/terrain.json"
const BURNT_CELL_M := 4.0      # the grid the burnt places are looked up in (metres; larger than the match tolerance)

# One terrain with the drawing helpers bound to it and the lock its caches need.
class Bundle:
	var terrain: Terrain
	var td: TerrainDraw
	var ts: TerrainShadows
	var vd: VillageDraw
	var mutex := Mutex.new()

var terrain: Terrain           # bundle 0's, and td, ts, vd below
var td: TerrainDraw
var ts: TerrainShadows
var vd: VillageDraw
var errors: Array[String] = []
var lanes := 1                 # bundles (map_view.terrain_lanes)

var _bundles: Array = []       # Bundle; [0] holds the objects above
var _tmutex: Mutex             # bundle 0's
var _ppm0 := 0.0               # the scale the MapView asked for (0: the data's)
var _rows0 := 0                # first chunk row of the map (baker chunks) and how many rows
var _rows := 1
var _merge_mat_shader: Shader
var water: RefCounted = null     # the WaterGen whose water the map shows (null: none; the stage list is then exactly what it was)
var water_draw: WaterDraw = null
var burnt_tolerance_m := 0.5     # forest_fire.map.match_tolerance_m (PROPOSED): a tree is the burnt one when its place is this near

var _trunk_look: FireTrunk.Look = null
var _burnt_mutex := Mutex.new()
var _burnt_cells: Dictionary = {}       # Vector2i (BURNT_CELL_M cell) -> Array of Vector2: the places (metres) of the burnt-out trees
var _burnt_keys: Dictionary = {}        # Vector2i (0.25 m) -> Vector2: the same places, for the diff
var _burnt_serial := 0
var _touched_serial: Dictionary = {}    # Vector2i chunk -> the serial of the last change that touched it (main thread)
var _baked_serial: Dictionary = {}      # Vector2i chunk -> the serial its last bake read (main thread)

func _init(seed_v: int, params: RenderParams, view_cfg: Dictionary, px_per_m: float = 0.0, water_gen: RefCounted = null) -> void:
	seed_value = seed_v
	P = params
	P.L["road"] = false
	chunk_px = int(view_cfg.get("chunk_px", 1024))
	lanes = maxi(1, int(view_cfg.get("terrain_lanes", 1)))
	_ppm0 = px_per_m
	_use_water(water_gen)
	_build_bundles()

# How the provider's terrains are made: (seed, data_path, params) -> Terrain. Unset: Terrain.new. A layer that
# changes the ground a terrain stands on (the water's capped height field, scripts/world/water_gen.gd: a
# subclass with set_cap installed before its first chunk) hands the provider a maker, and EVERY bundle is made
# with it, so the bundles stay the same terrain (proposed, Track P2, 2026-10-10; water is wired in later and
# goes through here). Call it before prepare(): it makes the bundles again.
var terrain_maker: Callable = Callable()

func set_terrain_maker(fn: Callable) -> void:
	terrain_maker = fn
	_bundles.clear()
	errors.clear()
	_build_bundles()

# THE WATER (Track WB, 2026-10-10, Job 3): the map shows a WaterGen's water. Every bundle's terrain is then the water's own
# (WaterGen.make_terrain: the height field capped by the water, no tree in the water), and three things join the bake: a
# `water` stage that makes the chunk's rings and the two depth masks (worker, parallel), a `water_masks` stage that renders
# the masks (main), the wash drawn under the terrain's level fill, and the ink lines drawn before the terrain's own
# linework (scripts/render/water_draw.gd). With no water the stage list, the terrain and every pixel are what they were.
func set_water(w: RefCounted) -> void:
	_use_water(w)
	_bundles.clear()
	errors.clear()
	_build_bundles()

func _use_water(w: RefCounted) -> void:
	water = w
	water_draw = null
	terrain_maker = Callable()
	if w != null:
		water_draw = WaterDraw.new(P)
		terrain_maker = Callable(w, "make_terrain")

func _make_terrain() -> Terrain:
	var t: Terrain = terrain_maker.call(seed_value, TERRAIN_DATA_PATH, P) if terrain_maker.is_valid() else Terrain.new(seed_value, TERRAIN_DATA_PATH, P)
	if _ppm0 > 0.0:
		t.px_per_m = _ppm0
	return t

func _build_bundles() -> void:
	for i in lanes:
		var b := Bundle.new()
		b.terrain = _make_terrain()
		b.td = TerrainDraw.new(b.terrain, P)
		b.ts = TerrainShadows.new(b.terrain, P)
		b.vd = VillageDraw.new(b.terrain, P)
		_bundles.append(b)
	var b0: Bundle = _bundles[0]
	terrain = b0.terrain
	td = b0.td
	ts = b0.ts
	vd = b0.vd
	_tmutex = b0.mutex
	if not terrain.ok():
		errors.append_array(terrain.errors)
		errors.append_array(terrain.data.errors)
	errors.append_array(td.errors)
	errors.append_array(vd.errors)
	if water_draw != null:
		errors.append_array(water_draw.errors)
	_set_rows()

func ok() -> bool:
	return errors.is_empty()

func prepare() -> void:
	super.prepare()
	_trunk_look = FireTrunk.look()
	burnt_tolerance_m = _match_tolerance()
	_merge_mat_shader = Shader.new()
	_merge_mat_shader.code = TerrainShadows._MERGE_SHADER
	# T's cut and fill shaders are made on their first (main-thread) use.
	# The world layout and the village are made here, on the main thread, before any worker asks.
	for b: Bundle in _bundles:
		b.mutex.lock()
		b.terrain.village()
		b.mutex.unlock()

# The village at the current scale (null when there is none), made under the terrain lock.
func village() -> RefCounted:
	_tmutex.lock()
	var v: RefCounted = terrain.village()
	_tmutex.unlock()
	return v

# The village's drawing style, in every bundle (the tools that compare styles).
func set_village_style(style: String) -> void:
	for b: Bundle in _bundles:
		b.vd.style = style

# The map's chunk rows (baker chunks) the bands are cut from.
func _set_rows() -> void:
	var mr := terrain.map_rect_px()
	_rows0 = floori(mr.position.y / chunk_px)
	_rows = maxi(1, ceili(mr.end.y / chunk_px) - _rows0)

# The bundle for baker chunk c: bands of rows.
func bundle_index(c: Vector2i) -> int:
	return clampi((c.y - _rows0) * lanes / _rows, 0, lanes - 1)

func _bundle(c: Vector2i) -> Bundle:
	return _bundles[bundle_index(c)]

# The lane a stage runs in for chunk c: "terrain" is one lane per bundle.
func lane_for(c: Vector2i, lane: String) -> String:
	if lane == "terrain" and lanes > 1:
		return "terrain%d" % bundle_index(c)
	return lane

func px_per_m() -> float:
	return terrain.px_per_m

# The map in world px.
func map_rect_px() -> Rect2:
	return terrain.map_rect_px()

# A new scale: everything T generated is dropped (it is generated in px).
func set_px_per_m(v: float) -> void:
	_ppm0 = v
	for b: Bundle in _bundles:
		b.mutex.lock()
		b.terrain.px_per_m = v
		b.terrain.clear_cache()
		b.vd.forget()
		b.mutex.unlock()
	_set_rows()

func clear_cache() -> void:
	for b: Bundle in _bundles:
		b.mutex.lock()
		b.terrain.clear_cache()
		b.vd.forget()
		b.mutex.unlock()

func reach_px() -> float:
	return ts.reach_px()

# Generation ahead of need (chunk_baker.gd warm): T's trees for chunk c and
# its reach, in T's lane so it never waits behind -- or holds up -- a bake.
func warm_lane() -> String:
	return "terrain"

# One of T's own chunks per lock hold (T generates per chunk_m, 256 m), so a
# warm task never keeps the lock -- or a waiting bake -- for long.
func warm_chunk(c: Vector2i) -> void:
	var b := _bundle(c)
	b.mutex.lock()
	var cells := b.terrain.chunks_in_rect_px(chunk_rect(c).grow(b.ts.reach_px()))
	b.mutex.unlock()
	for t in cells:
		b.mutex.lock()
		b.terrain.trees_in_chunk(t.x, t.y)
		b.mutex.unlock()

func stages() -> Array:
	var list: Array = [
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
	if water_draw != null:
		# after the ground (both parallel: the rings are computed beside it), the masks rendered once everything else is in
		list.insert(3, {"name": "water", "thread": "worker", "parallel": true, "fn": _water})
		var at := 0
		for i in list.size():
			if (list[i] as Dictionary).get("name", "") == "fill":
				at = i
		list.insert(at, {"name": "water_masks", "thread": "main", "join": true, "fn": _water_masks})
	return list

# The trees whose centre lies in the chunk grown by reach_px(), sorted as
# T draws them: base + h, then y, then x -- the terrain's own and the hedge trees of the fields
# (Track W) -- and the village's structures that reach it. Pure in (seed, chunk).
func chunk_content(c: Vector2i) -> Dictionary:
	var b := _bundle(c)
	var grown := chunk_rect(c).grow(b.ts.reach_px())
	var burnt := _burnt_snapshot()   # (before the trees: a set at least as new as the serial recorded)
	b.mutex.lock()
	var trees: Array = b.terrain.trees_in_rect_px(grown)
	var ppm: float = b.terrain.px_per_m
	var vil: RefCounted = b.terrain.village()
	var hedges: Array = b.vd.hedge_trees(vil) if vil != null else []
	b.mutex.unlock()
	var copies: Array = []
	for t: Dictionary in trees:
		copies.append(t.duplicate())
	for t: Dictionary in hedges:
		if grown.has_point(Vector2(t.x, t.y)):
			copies.append(t.duplicate())
	copies.sort_custom(tree_less)
	# the burnt-out trees leave the canopy list and become trunks (same order): nothing changes while none has burnt
	var live: Array = copies
	var trunks: Array = []
	if not (burnt.cells as Dictionary).is_empty():
		live = []
		for t: Dictionary in copies:
			if _is_burnt(t, ppm, burnt):
				trunks.append(t)
			else:
				live.append(t)
	var structs: Array = []
	if vil != null:
		for s: Dictionary in vil.structs_in_rect(grown):
			structs.append(s.duplicate())
	return {"trees": live, "trunks": trunks, "structs": structs, "village": vil, "burn_serial": burnt.serial}

# --- The burnt-out trees (forest fire) -----------------------------------------------------------------

# Takes the places of the trees that have burnt down to their trunks ([{x_m, y_m, ...}]; the whole set every time, so it can also
# shrink). Returns the chunks whose content changed (Vector2i): every chunk that holds a tree added to or removed from the set.
func set_burnt_trees(trees: Array) -> Array:
	var keys: Dictionary = {}
	for t: Variant in trees:
		if not (t is Dictionary) or not (t as Dictionary).has("x_m") or not (t as Dictionary).has("y_m"):
			continue
		var p := Vector2(float((t as Dictionary)["x_m"]), float((t as Dictionary)["y_m"]))
		keys[Vector2i(roundi(p.x * 4.0), roundi(p.y * 4.0))] = p
	var changed: Array = []
	for k: Vector2i in keys:
		if not _burnt_keys.has(k):
			changed.append(keys[k])
	for k: Vector2i in _burnt_keys:
		if not keys.has(k):
			changed.append(_burnt_keys[k])
	if changed.is_empty():
		return []
	var cells: Dictionary = {}
	for p: Vector2 in keys.values():
		var cell := Vector2i(floori(p.x / BURNT_CELL_M), floori(p.y / BURNT_CELL_M))
		if not cells.has(cell):
			cells[cell] = []
		(cells[cell] as Array).append(p)
	_burnt_mutex.lock()
	_burnt_cells = cells
	_burnt_keys = keys
	_burnt_serial += 1
	var serial := _burnt_serial
	_burnt_mutex.unlock()
	var hit: Dictionary = {}
	for p: Vector2 in changed:
		for c: Vector2i in chunks_touched_by(p):
			hit[c] = true
			_touched_serial[c] = serial
	var out: Array = hit.keys()
	out.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y < b.y or (a.y == b.y and a.x < b.x))
	return out

func burnt_count() -> int:
	return _burnt_keys.size()

func burnt_serial() -> int:
	return _burnt_serial

# Every chunk whose content holds a tree standing at `p_m` (metres): the chunks whose rectangle grown by reach_px() (the canopy and
# the shadow reach) has the tree's place, plus the match tolerance. A superset at the border, never a miss. Within the map.
func chunks_touched_by(p_m: Vector2) -> Array:
	var ppm: float = terrain.px_per_m
	var reach: float = reach_px() + burnt_tolerance_m * ppm + 1.0
	var x := p_m.x * ppm
	var y := p_m.y * ppm
	var mr := map_rect_px()
	var m0x := floori(mr.position.x / chunk_px)
	var m0y := floori(mr.position.y / chunk_px)
	var m1x := ceili(mr.end.x / chunk_px) - 1
	var m1y := ceili(mr.end.y / chunk_px) - 1
	var out: Array = []
	for cy in range(maxi(floori((y - reach) / chunk_px), m0y), mini(floori((y + reach) / chunk_px), m1y) + 1):
		for cx in range(maxi(floori((x - reach) / chunk_px), m0x), mini(floori((x + reach) / chunk_px), m1x) + 1):
			out.append(Vector2i(cx, cy))
	return out

# Did chunk c's last bake read the burnt set as it now stands for that chunk? (False: it was baked, or was being baked, before
# a change that touched it, and MapView bakes it again.)
func burn_current(c: Vector2i) -> bool:
	return int(_baked_serial.get(c, 0)) >= int(_touched_serial.get(c, 0))

func _burnt_snapshot() -> Dictionary:
	_burnt_mutex.lock()
	var out := {"cells": _burnt_cells, "serial": _burnt_serial, "tol": burnt_tolerance_m}
	_burnt_mutex.unlock()
	return out

# Is the tree record (world px) at one of the burnt places? (The 3 x 3 cells round it, within the tolerance.)
static func _is_burnt(t: Dictionary, ppm: float, burnt: Dictionary) -> bool:
	var mx: float = float(t["x"]) / ppm
	var my: float = float(t["y"]) / ppm
	var cx := floori(mx / BURNT_CELL_M)
	var cy := floori(my / BURNT_CELL_M)
	var tol2: float = float(burnt.tol) * float(burnt.tol)
	var cells: Dictionary = burnt.cells
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var arr: Variant = cells.get(Vector2i(cx + dx, cy + dy))
			if arr == null:
				continue
			for p: Vector2 in (arr as Array):
				var ex := p.x - mx
				var ey := p.y - my
				if ex * ex + ey * ey <= tol2:
					return true
	return false

func _match_tolerance() -> float:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/fx/fx.json")) if FileAccess.file_exists("res://data/fx/fx.json") else null
	if raw is Dictionary:
		var ff: Variant = (raw as Dictionary).get("forest_fire")
		if ff is Dictionary and ((ff as Dictionary).get("map") is Dictionary):
			var rec: Variant = ((ff as Dictionary)["map"] as Dictionary).get("match_tolerance_m")
			if rec is Dictionary and ((rec as Dictionary).get("value") is float or (rec as Dictionary).get("value") is int):
				return float((rec as Dictionary)["value"])
	return burnt_tolerance_m

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
	var b := _bundle(c)
	var scarp := b.terrain.scarp_m * b.terrain.px_per_m
	b.mutex.lock()
	for ch in b.terrain.chunks_in_rect_px(rect.grow(maxf(b.ts.reach_px(), scarp * 2.0))):
		for k in b.terrain.thresholds.size():
			b.terrain.chains_px(ch.x, ch.y, k)
			b.terrain.polys_px(ch.x, ch.y, k)
	b.mutex.unlock()
	var sprite_objects: Array = (content.trees as Array).duplicate()
	sprite_objects.append_array(content.structs)
	return {"data": {"trees": content.trees, "trunks": content.trunks, "burn_serial": content.burn_serial, "structs": content.structs,
		"village": content.village, "sprite_objects": sprite_objects}}

func _ground(job: Dictionary) -> Dictionary:
	var g := record_ground(job.view, job.rect, job.size, job.c)
	# the village's fields and road (Track W): a chunk it does not reach draws nothing more
	var vil: Variant = job.data.get("village")
	if vil != null:
		_bundle(job.c).vd.draw_ground(g, vil, job.rect)
		g.set_transform_matrix(job.view)
	return {"data": {"g": g}}

# T's level_masks without its render_all: one canvas per threshold, white
# where the level is k+1 or more, black elsewhere (terrain_draw.gd,
# level_masks -- the same fills in the same order).
func _levels(job: Dictionary) -> Variant:
	var b := _bundle(job.c)
	if not b.mutex.try_lock():
		return null
	var view: Transform2D = job.view
	var size: Vector2i = job.size
	var chunks := b.terrain.chunks_in_rect_px(TerrainDraw.view_rect(view, size))
	var out: Array = []
	for k in b.terrain.thresholds.size():
		var g := InkCanvas.new(size)
		g.fill_color = Color.BLACK
		g.fill_rect(0.0, 0.0, float(size.x), float(size.y))
		g.set_transform_matrix(view)
		g.fill_color = Color.WHITE
		g.begin_path()
		var rings: Array = []
		var any := false
		for ch in chunks:
			for poly: Dictionary in b.terrain.polys_px(ch.x, ch.y, k):
				if poly.border:
					TerrainDraw._add_poly(g, poly.pts)
					any = true
				else:
					rings.append(poly)
		if any:
			g.fill()
		rings.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return absf(x.area) > absf(y.area))
		for ring: Dictionary in rings:
			g.fill_color = Color.WHITE if ring.area > 0.0 else Color.BLACK
			g.begin_path()
			TerrainDraw._add_poly(g, ring.pts)
			g.fill()
		out.append(g)
	b.mutex.unlock()
	return out

func _terrain_sil(job: Dictionary) -> Dictionary:
	var parts: Array = []
	var b := _bundle(job.c)
	b.mutex.lock()
	for r in b.terrain.level_count() - 1:
		var sp := ShadowPass.new(job.size)
		var n := b.ts.add_terrain_silhouettes(sp, r, job.view, job.rect)
		parts.append([r, sp, n])
	b.mutex.unlock()
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
	var b := _bundle(job.c)
	b.mutex.lock()
	for r in b.terrain.level_count():
		var sp := ShadowPass.new(job.size)
		var n := b.ts.add_tree_silhouettes(sp, job.data.trees, r, job.view)
		var trunks: Array = job.data.get("trunks", [])
		if not trunks.is_empty() and _trunk_look != null and _trunk_look.ok:
			n += FireTrunk.add_shadows(sp, trunks, r, job.view, b.ts, _trunk_look)   # the burnt-out trees' own small shadows
		parts.append([r, sp, n])
	b.mutex.unlock()
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

# The water's rings and masks of the chunk (the stage `water`, a worker beside the ground): the geometry stays in job.data for the
# linework, the mask canvases go to be rendered by `water_masks`.
func _water(job: Dictionary) -> Dictionary:
	var geo: Dictionary = water_draw.chunk_geometry(water, job.rect, px_per_m())
	if geo.is_empty():
		return {"data": {}}
	return {"data": {"water_geo": geo, "water_g": water_draw.chunk_masks(geo, job.view, job.size)}}

func _water_masks(job: Dictionary) -> Variant:
	var g: Variant = job.data.get("water_g")
	if g is Array and not (g as Array).is_empty():
		(job.data as Dictionary).erase("water_g")   # (the canvases are rendered now, and freed after: the job no longer holds them)
		return g
	return []

func _fill(job: Dictionary) -> Array:
	var masks: Variant = job.data.get("water_masks")
	if water_draw != null and masks is Array and (masks as Array).size() == 2:
		water_draw.draw_chunk_wash(job.data.g, masks[0], masks[1], (job.data.levels as Array)[0], job.rect, job.size)
	td.draw_level_fill(job.data.g, job.data.levels)
	return []

func _linework(job: Dictionary) -> Array:
	var b := _bundle(job.c)
	b.mutex.lock()
	var geo: Variant = job.data.get("water_geo")
	if water_draw != null and geo is Dictionary:
		water_draw.draw_chunk_lines(job.data.g, b.terrain, water, geo, job.view, job.rect)   # (the water's ink goes down first: the terrain's contours and hachures cross it)
	b.td.draw_linework(job.data.g, job.view, job.rect)
	b.mutex.unlock()
	# the burnt-out trees: the scorched ground round each trunk, in ink (fire_trunk.gd), under the shadows (the trunks are drawn in the frame stage)
	var trunks: Array = job.data.get("trunks", [])
	if not trunks.is_empty() and _trunk_look != null and _trunk_look.ok:
		var tg: InkCanvas = job.data.g
		tg.set_transform_matrix(job.view)
		FireTrunk.draw_ground(tg, trunks, P, _trunk_look)
	return []

func _frame(job: Dictionary) -> Array:
	_baked_serial[job.c] = int(job.data.get("burn_serial", 0))   # (main thread: MapView asks burn_current() on the same one)
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
	var trunks: Array = job.data.get("trunks", [])
	if not trunks.is_empty() and _trunk_look != null and _trunk_look.ok:
		FireTrunk.draw_trunks(g, trunks, P, _trunk_look)   # the burnt-out trees' charred trunks: over the shadows, under the canopies
	if P.L.objects:
		for t: Dictionary in job.data.trees:
			var s: float = t.half * 2.0
			g.draw_image(t.sprite, t.x - t.half, t.y - t.half, s, s)
	apply_grain(g)
	return [g]
