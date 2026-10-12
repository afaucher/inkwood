extends RefCounted

# THE HEIGHT GRID (builder LOF1, stage 1 of the lines of fire, 2026-10-11; decision line-of-fire, option b). A grid of TOP HEIGHTS
# and MATERIALS over the whole map, built once from the map's generation -- the seed's terrain, its water and its village --
# and the same on every peer. Straight lines are walked across it (scripts/sim/line_of_fire.gd); nothing here is a 3D mesh
# (the agreed method: 2.5D). Not used by combat yet (data/sim/line_of_fire.json `enabled` is false).
#
#   var grid := HeightGrid.shared(seed, water)          # the one of a seed (water: WaterGen.shared(seed), or null for none)
#   grid.top_at(x, y)        -> float   the top of the cell at (x, y) metres: ground, a wall, a house, the sandbags, the deck
#   grid.material_at(x, y)   -> int     its material id (data/sim/line_of_fire.json `materials`: ground, water, stone, timber, earthworks)
#   grid.stand_z(x, y)       -> float   the height a unit at (x, y) stands on: the ground, the water's surface, or the bridge's deck
#                                       (never the top of a house or a wall it happens to be over)
#   grid.stamp(owner, boxes) / unstamp(owner)           a static unit's shapes (the sandbag ring, the deck) put in, and taken out
#   grid.sync_statics(units)                            every static unit of a World's `units` stamped while it stands, unstamped when down
#   grid.canopies_near(x, y, r) -> Array                the trees as canopies {id, x, y, r, zb, zt}
#   grid.build_rect(rect_m) / build_all() / signature(rect_m) / memory_bytes() / stats()
#
# WHAT A CELL HOLDS: the top in metres above sea level and a material id; both from layers written in this order, each only ever
# raising the cell (scripts/sim/height_grid_build.gd): the terrain's levels (0, 12, 24 m: data/terrain/terrain.json), the water
# (height 0, material water), the village's houses and walls (the structures' own `h` over the map scale, so the scenery-heights
# board's pick flows in). THE STAMP LAYER on top of the map is a static unit's shape (data/units/<id>.json `shape`): the
# battery's sandbag ring and the bridge's deck, while the unit stands.
#
# TREES ARE NOT CELLS. A tree is a canopy: a disc (centre, radius) and a band (base, top height), from the map's own tree set
# (Terrain.trees_in_chunk, the trees the map draws). Canopies are indexed by the coarse block they overlap. A canopy THINS a line;
# it does not wall it (data canopy.stop_chance).
#
# CHUNKS ARE BUILT WHEN FIRST ASKED FOR (a chunk is the terrain's 256 m square: the same chunk whenever and wherever it is made) and
# kept: a battle in one corner of the 5 km map never pays for the rest. build_all() makes the lot. Most of a map is UNIFORM (open
# sea, plain) and holds no arrays. A cell outside the map is flat ground at 0 m.
#
# PURE AND DETERMINISTIC: a function of (seed, the terrain's data, the water, the village, line_of_fire.json, the stamps). Not
# thread safe (the terrain caches chunks): the sim's thread only, like GroundMap.

const Chunk = preload("res://scripts/sim/height_chunk.gd")
const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const Build = preload("res://scripts/sim/height_grid_build.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")

const KEY_OFFSET := 1024      # block coordinates are shifted by this to make a positive key
const KEY_WIDTH := 8192

static var _shared: Dictionary = {}

var rules: Rules
var terrain: Object
var water: Object = null
var seed_value: int = 0
var chunk_m: float = 256.0
var cell_m: float = 1.0
var block_m: float = 16.0
var n: int = 0                 # cells per chunk side
var nb: int = 0                # blocks per chunk side
var block_cells: int = 0       # cells per block side
var ppm: float = 2.0
var errors: Array[String] = []
# Whether building a chunk also loads the canopies round it (the map's trees). Off for a tool that wants the cells alone and quickly.
var with_trees := true

# the canopies, one entry per tree (float64), and their index by block
var can_x := PackedFloat64Array()
var can_y := PackedFloat64Array()
var can_r := PackedFloat64Array()
var can_zb := PackedFloat64Array()
var can_zt := PackedFloat64Array()
var can_blocks: Dictionary = {}       # block key -> PackedInt32Array of canopy ids

var _cx0: int = 0
var _cy0: int = 0
var _cw: int = 0
var _chh: int = 0
var _flat: Array = []
var _outside: Chunk
var _trees_loaded: Dictionary = {}    # chunk key -> true
var _stamps: Dictionary = {}          # owner -> Array of world boxes (line_of_fire_shapes.gd)
var _river_chunks: Dictionary = {}    # chunk key -> PackedInt32Array of river segment indices
var _river_ready := false
var _timings := {"chunks": 0, "chunk_ms": 0.0, "trees_ms": 0.0, "stamp_ms": 0.0, "worst_chunk_ms": 0.0}

# `terrain_v`: a Terrain (scripts/world/terrain.gd) or the water's capped one (water.make_terrain()), the one the map is drawn from.
# `water_v`: the seed's WaterGen, or null (a dry map).
func _init(terrain_v: Object, water_v: Object = null, rules_v: Rules = null) -> void:
	terrain = terrain_v
	water = water_v
	rules = rules_v if rules_v != null else Rules.new()
	if not rules.ok():
		errors.append_array(rules.errors)
		return
	if not terrain.ok():
		errors.append("the terrain did not build")
		return
	seed_value = int(terrain.seed_value)
	chunk_m = float(terrain.chunk_m)
	cell_m = rules.cell_m
	block_m = rules.block_m
	ppm = float(terrain.px_per_m)
	var cells := chunk_m / cell_m
	var blocks := chunk_m / block_m
	if absf(cells - roundf(cells)) > 1e-9 or absf(blocks - roundf(blocks)) > 1e-9 or absf(block_m / cell_m - roundf(block_m / cell_m)) > 1e-9:
		errors.append("the chunk (%s m) is not a whole number of cells (%s m) and blocks (%s m)" % [str(chunk_m), str(cell_m), str(block_m)])
		return
	n = roundi(cells)
	nb = roundi(blocks)
	block_cells = roundi(block_m / cell_m)
	var r: Rect2i = terrain.map_chunk_range()
	_cx0 = r.position.x
	_cy0 = r.position.y
	_cw = r.size.x
	_chh = r.size.y
	_flat.resize(_cw * _chh)
	_outside = Chunk.new()
	_outside.n = n
	_outside.nb = nb
	_outside.uniform = true
	_outside.uh = 0.0
	_outside.um = Rules.GROUND
	_outside.bmax = PackedFloat32Array()
	_outside.bmax.resize(nb * nb)

func ok() -> bool:
	return errors.is_empty()

# The grid of a seed (made on first use). `water_v`: WaterGen.shared(seed) or null, as GroundMap.shared takes it. With water the terrain is
# the WATER'S OWN (WaterGen.terrain(): the raw terrain with the coast's cap, the one WaterGen.depth_at judges by, the same ground GroundMap
# gives the World, made by the same maker), so the water and the cells share one cache of chunk geometry. NOT GroundMap.shared(...).terrain:
# a headless process that calls village() on that terrain, or on WaterGen.raw_terrain(), ends with an access violation (exit code
# -1073741819) while quitting; water.terrain() and a fresh water.make_terrain() do not (found by builder LOF1, 2026-10-11, with
# scripts/tests/test_line_of_fire.gd: the cause is not in this file, reported to the lead).
static func shared(seed_v: int, water_v: Object = null) -> RefCounted:
	var key := "%d|%s" % [seed_v, "w" if water_v != null else "raw"]
	if not _shared.has(key):
		var t: Object = water_v.terrain() if water_v != null else (load("res://scripts/world/terrain.gd") as GDScript).new(seed_v)
		_shared[key] = (load("res://scripts/sim/height_grid.gd") as GDScript).new(t, water_v)
	return _shared[key]

# --- chunks -------------------------------------------------------------------------------------------------

func chunk_of(x: float, y: float) -> Vector2i:
	return Vector2i(floori(x / chunk_m), floori(y / chunk_m))

# The chunk (cx, cy), built if it is not yet; flat ground for a chunk outside the map.
func chunk_at(cx: int, cy: int) -> Chunk:
	if cx < _cx0 or cy < _cy0 or cx >= _cx0 + _cw or cy >= _cy0 + _chh:
		return _outside
	var c: Variant = _flat[(cy - _cy0) * _cw + (cx - _cx0)]
	if c != null:
		return c
	return _build(cx, cy)

func is_built(cx: int, cy: int) -> bool:
	if cx < _cx0 or cy < _cy0 or cx >= _cx0 + _cw or cy >= _cy0 + _chh:
		return true
	return _flat[(cy - _cy0) * _cw + (cx - _cx0)] != null

func built_count() -> int:
	var k := 0
	for c: Variant in _flat:
		if c != null:
			k += 1
	return k

func map_chunk_rect() -> Rect2i:
	return Rect2i(_cx0, _cy0, _cw, _chh)

func _build(cx: int, cy: int) -> Chunk:
	var t0 := Time.get_ticks_usec()
	var c: Chunk = Build.new(self, cx, cy).run()
	_flat[(cy - _cy0) * _cw + (cx - _cx0)] = c
	var t1 := Time.get_ticks_usec()
	# the canopies that can reach this chunk: its own trees and its neighbours' (a crown reaches over a border)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			_load_trees(cx + dx, cy + dy)
	var t2 := Time.get_ticks_usec()
	_apply_stamps_to(c)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_timings["chunks"] = int(_timings["chunks"]) + 1
	_timings["chunk_ms"] = float(_timings["chunk_ms"]) + (t1 - t0) / 1000.0
	_timings["trees_ms"] = float(_timings["trees_ms"]) + (t2 - t1) / 1000.0
	_timings["stamp_ms"] = float(_timings["stamp_ms"]) + (Time.get_ticks_usec() - t2) / 1000.0
	_timings["worst_chunk_ms"] = maxf(float(_timings["worst_chunk_ms"]), ms)
	c.stats["total_ms"] = ms
	return c

# Every chunk the rectangle (metres) touches, and the canopies round them.
func build_rect(rect_m: Rect2) -> int:
	var made := 0
	for cy in range(floori(rect_m.position.y / chunk_m), floori(rect_m.end.y / chunk_m) + 1):
		for cx in range(floori(rect_m.position.x / chunk_m), floori(rect_m.end.x / chunk_m) + 1):
			if not is_built(cx, cy):
				chunk_at(cx, cy)
				made += 1
	return made

func build_all() -> int:
	return build_rect(Rect2(_cx0 * chunk_m, _cy0 * chunk_m, _cw * chunk_m, _chh * chunk_m))

# --- cells --------------------------------------------------------------------------------------------------

func top_at(x: float, y: float) -> float:
	var cx := floori(x / chunk_m)
	var cy := floori(y / chunk_m)
	var c := chunk_at(cx, cy)
	return c.top(clampi(floori((x - float(cx) * chunk_m) / cell_m), 0, n - 1), clampi(floori((y - float(cy) * chunk_m) / cell_m), 0, n - 1))

# The material id of the cell (0..): ground, water, stone, timber, earthworks. The deck flag is not in it (is_deck).
func material_at(x: float, y: float) -> int:
	return _byte_at(x, y) & Rules.MATERIAL_MASK

func is_deck(x: float, y: float) -> bool:
	return (_byte_at(x, y) & Rules.FLAG_DECK) != 0

# The cell's material byte: the id in the low four bits (Rules.MATERIAL_MASK), Rules.FLAG_DECK set for a deck.
func cell_byte(x: float, y: float) -> int:
	return _byte_at(x, y)

func _byte_at(x: float, y: float) -> int:
	var cx := floori(x / chunk_m)
	var cy := floori(y / chunk_m)
	var c := chunk_at(cx, cy)
	return c.material_byte(clampi(floori((x - float(cx) * chunk_m) / cell_m), 0, n - 1), clampi(floori((y - float(cy) * chunk_m) / cell_m), 0, n - 1))

# The height a unit at (x, y) stands on. Ground, water or the deck: the cell's top. Over a house, a wall or the sandbags: the
# ground under it (a vehicle that was driven over a house stands on the ground there, never on its roof).
func stand_z(x: float, y: float) -> float:
	var b := _byte_at(x, y)
	var mat := b & Rules.MATERIAL_MASK
	if mat == Rules.GROUND or mat == Rules.WATER or (b & Rules.FLAG_DECK) != 0:
		return top_at(x, y)
	return float(terrain.height_at(x, y))

# The terrain's own height at a point (no structure, no stamp): the level's height.
func ground_z(x: float, y: float) -> float:
	return float(terrain.height_at(x, y))

# --- canopies -----------------------------------------------------------------------------------------------

static func block_key(bx: int, by: int) -> int:
	return (by + KEY_OFFSET) * KEY_WIDTH + (bx + KEY_OFFSET)

func canopy_count() -> int:
	return can_x.size()

func canopy(id: int) -> Dictionary:
	return {"id": id, "x": can_x[id], "y": can_y[id], "r": can_r[id], "zb": can_zb[id], "zt": can_zt[id]}

func _load_trees(cx: int, cy: int) -> void:
	if not with_trees:
		return
	var key := Vector2i(cx, cy)
	if _trees_loaded.has(key):
		return
	_trees_loaded[key] = true
	if not terrain.chunk_in_map(cx, cy):
		return
	for t: Dictionary in terrain.trees_in_chunk(cx, cy):
		var id := can_x.size()
		var tx: float = float(t.x) / ppm
		var ty: float = float(t.y) / ppm
		var r: float = float(t.r) / ppm
		var base: float = float(t.base_m)
		var top: float = base + float(t.h) / ppm
		can_x.append(tx)
		can_y.append(ty)
		can_r.append(r)
		can_zb.append(base + rules.canopy_base_frac * (top - base))
		can_zt.append(top)
		var bx0 := floori((tx - r) / block_m)
		var bx1 := floori((tx + r) / block_m)
		var by0 := floori((ty - r) / block_m)
		var by1 := floori((ty + r) / block_m)
		for by in range(by0, by1 + 1):
			for bx in range(bx0, bx1 + 1):
				var k := block_key(bx, by)
				# a Packed array read out of a Dictionary is a copy: take it out, add, put it back
				var ids: PackedInt32Array = can_blocks.get(k, PackedInt32Array())
				ids.append(id)
				can_blocks[k] = ids

# The canopies whose disc touches the circle (x, y, r), loading the trees round it if need be.
func canopies_near(x: float, y: float, r: float) -> Array:
	var cx0 := floori((x - r) / chunk_m)
	var cx1 := floori((x + r) / chunk_m)
	var cy0 := floori((y - r) / chunk_m)
	var cy1 := floori((y + r) / chunk_m)
	for cy in range(cy0 - 1, cy1 + 2):
		for cx in range(cx0 - 1, cx1 + 2):
			_load_trees(cx, cy)
	var out: Array = []
	var seen: Dictionary = {}
	for by in range(floori((y - r) / block_m), floori((y + r) / block_m) + 1):
		for bx in range(floori((x - r) / block_m), floori((x + r) / block_m) + 1):
			var ids: Variant = can_blocks.get(block_key(bx, by))
			if ids == null:
				continue
			for id: int in (ids as PackedInt32Array):
				if seen.has(id):
					continue
				seen[id] = true
				var dx := can_x[id] - x
				var dy := can_y[id] - y
				var rr := can_r[id] + r
				if dx * dx + dy * dy <= rr * rr:
					out.append(canopy(id))
	return out

# --- the stamp layer ----------------------------------------------------------------------------------------

# Puts a unit's boxes (Shapes.world_boxes) in; only the ones that stamp (a ring, a deck). Replaces the owner's earlier stamp.
func stamp(owner: String, boxes: Array) -> void:
	var t0 := Time.get_ticks_usec()
	if _stamps.has(owner):
		unstamp(owner)
	var mine: Array = []
	for b: Dictionary in boxes:
		if bool(b.get("stamp", false)):
			mine.append(b)
	if mine.is_empty():
		return
	_stamps[owner] = mine
	for b: Dictionary in mine:
		var r: Rect2 = Shapes.bounds(b)
		for cy in range(floori(r.position.y / chunk_m), floori(r.end.y / chunk_m) + 1):
			for cx in range(floori(r.position.x / chunk_m), floori(r.end.x / chunk_m) + 1):
				if is_built(cx, cy) and not (cx < _cx0 or cy < _cy0 or cx >= _cx0 + _cw or cy >= _cy0 + _chh):
					_apply_box(chunk_at(cx, cy), b)
	_timings["stamp_ms"] = float(_timings["stamp_ms"]) + (Time.get_ticks_usec() - t0) / 1000.0

func unstamp(owner: String) -> void:
	if not _stamps.has(owner):
		return
	var mine: Array = _stamps[owner]
	_stamps.erase(owner)
	var touched: Dictionary = {}
	for b: Dictionary in mine:
		var r: Rect2 = Shapes.bounds(b)
		for cy in range(floori(r.position.y / chunk_m), floori(r.end.y / chunk_m) + 1):
			for cx in range(floori(r.position.x / chunk_m), floori(r.end.x / chunk_m) + 1):
				touched[Vector2i(cx, cy)] = true
	for k: Vector2i in touched:
		if is_built(k.x, k.y) and not (k.x < _cx0 or k.y < _cy0 or k.x >= _cx0 + _cw or k.y >= _cy0 + _chh):
			var c := chunk_at(k.x, k.y)
			c.clear_overlay()
			_apply_stamps_to(c)

func stamped_owners() -> Array:
	return _stamps.keys()

func _apply_stamps_to(c: Chunk) -> void:
	if _stamps.is_empty():
		return
	var cr := Rect2(float(c.cx) * chunk_m, float(c.cy) * chunk_m, chunk_m, chunk_m)
	for owner: String in _stamps:
		for b: Dictionary in _stamps[owner]:
			if Shapes.bounds(b).intersects(cr):
				_apply_box(c, b)

# Rasterises one box into the chunk's stamp layer: a cell is taken if any of 3 x 3 points in it is inside the shape (a thin ring
# of sandbags must not slip between two cells).
func _apply_box(c: Chunk, b: Dictionary) -> void:
	var x0 := float(c.cx) * chunk_m
	var y0 := float(c.cy) * chunk_m
	var r: Rect2 = Shapes.bounds(b)
	var ix0 := clampi(floori((r.position.x - x0) / cell_m), 0, n - 1)
	var ix1 := clampi(floori((r.end.x - x0) / cell_m), 0, n - 1)
	var iy0 := clampi(floori((r.position.y - y0) / cell_m), 0, n - 1)
	var iy1 := clampi(floori((r.end.y - y0) / cell_m), 0, n - 1)
	if r.end.x < x0 or r.position.x > x0 + chunk_m or r.end.y < y0 or r.position.y > y0 + chunk_m:
		return
	c.ensure_overlay()
	var top := float(b.z1)
	var mat := int(b.material)
	if bool(b.get("standable", false)):
		mat |= Rules.FLAG_DECK
	var oh := c.oh
	var om := c.om
	var obmax := c.obmax
	for iy in range(iy0, iy1 + 1):
		for ix in range(ix0, ix1 + 1):
			var hit := false
			for sy in 3:
				var py := y0 + (float(iy) + (float(sy) + 0.5) / 3.0) * cell_m
				for sx in 3:
					var px := x0 + (float(ix) + (float(sx) + 0.5) / 3.0) * cell_m
					if Shapes.contains(b, px, py):
						hit = true
						break
				if hit:
					break
			if hit:
				var idx := iy * n + ix
				if top > oh[idx]:
					oh[idx] = top
					om[idx] = mat
					var bi := (iy / block_cells) * nb + ix / block_cells
					if top > obmax[bi]:
						obmax[bi] = top
	c.oh = oh
	c.om = om
	c.obmax = obmax

# Every static unit of a World's `units` (Dictionary id -> Unit) that stands is stamped, every one that is down is unstamped. The unit's
# base is the ground (or the water) it stands on. Cheap to call again each turn: a unit already stamped in the same place is left.
func sync_statics(units: Dictionary) -> int:
	var count := 0
	for id: String in units:
		var u: Object = units[id]
		if u.def == null or not u.def.is_static():
			continue
		var has_stamp := false
		for sb: Dictionary in u.def.shape_boxes:
			if bool(sb.get("stamp", false)):
				has_stamp = true
		if not has_stamp:
			continue
		if u.down:
			unstamp(id)
			continue
		if _stamps.has(id):
			continue
		stamp(id, Shapes.world_boxes(u.def, rules, float(u.x), float(u.y), float(u.heading), stand_z(float(u.x), float(u.y))))
		count += 1
	return count

# --- the river (for the builder) -----------------------------------------------------------------------------

# The indexes of the river's segments whose reach touches the chunk.
func river_segments_near(cx: int, cy: int) -> PackedInt32Array:
	if water == null:
		return PackedInt32Array()
	if not _river_ready:
		_river_ready = true
		var pts: PackedVector2Array = water.river_pts
		var hws: PackedFloat64Array = water.river_hw
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var g := maxf(hws[i], hws[i + 1]) + 16.0
			for qy in range(floori((minf(a.y, b.y) - g) / chunk_m), floori((maxf(a.y, b.y) + g) / chunk_m) + 1):
				for qx in range(floori((minf(a.x, b.x) - g) / chunk_m), floori((maxf(a.x, b.x) + g) / chunk_m) + 1):
					var k := Vector2i(qx, qy)
					var ids: PackedInt32Array = _river_chunks.get(k, PackedInt32Array())
					ids.append(i)
					_river_chunks[k] = ids
	return _river_chunks.get(Vector2i(cx, cy), PackedInt32Array())

# --- reports ------------------------------------------------------------------------------------------------

func memory_bytes() -> int:
	var total := can_x.size() * 8 * 5
	for c: Variant in _flat:
		if c != null:
			total += (c as Chunk).bytes()
	return total

func stats() -> Dictionary:
	var uniform := 0
	var arrays := 0
	for c: Variant in _flat:
		if c != null:
			if (c as Chunk).uniform:
				uniform += 1
			else:
				arrays += 1
	return {"cell_m": cell_m, "chunks_built": uniform + arrays, "uniform_chunks": uniform, "array_chunks": arrays, "canopies": can_x.size(),
		"memory_bytes": memory_bytes(), "chunk_ms": _timings["chunk_ms"], "trees_ms": _timings["trees_ms"], "stamp_ms": _timings["stamp_ms"],
		"worst_chunk_ms": _timings["worst_chunk_ms"], "stamps": _stamps.size()}

# A fingerprint of the built map layer of the chunks the rectangle (metres) touches, for "the same on every peer": a hash of each
# chunk's heights and materials, and of the canopies in it. Builds the chunks. The stamp layer is not in it.
func signature(rect_m: Rect2) -> String:
	build_rect(rect_m)
	var parts: PackedStringArray = []
	for cy in range(floori(rect_m.position.y / chunk_m), floori(rect_m.end.y / chunk_m) + 1):
		for cx in range(floori(rect_m.position.x / chunk_m), floori(rect_m.end.x / chunk_m) + 1):
			var c := chunk_at(cx, cy)
			if c.uniform:
				parts.append("%d,%d:u:%s:%d" % [cx, cy, str(c.uh), c.um])
			else:
				parts.append("%d,%d:a:%d:%d" % [cx, cy, hash(c.h), hash(c.m)])
	# the canopies centred in those chunks, in place order (their ids depend on the order the chunks were built in, so the ids are not in it)
	var c0 := Vector2i(floori(rect_m.position.x / chunk_m), floori(rect_m.position.y / chunk_m))
	var c1 := Vector2i(floori(rect_m.end.x / chunk_m), floori(rect_m.end.y / chunk_m))
	var mine: Array = []
	for i in can_x.size():
		var cc := chunk_of(can_x[i], can_y[i])
		if cc.x >= c0.x and cc.x <= c1.x and cc.y >= c0.y and cc.y <= c1.y:
			mine.append([can_x[i], can_y[i], can_r[i], can_zb[i], can_zt[i]])
	mine.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var cs := PackedFloat64Array()
	for q: Array in mine:
		for v: float in q:
			cs.append(v)
	parts.append("canopies:%d:%d" % [mine.size(), hash(cs)])
	return "|".join(parts)
