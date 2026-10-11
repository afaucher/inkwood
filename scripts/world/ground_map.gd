extends RefCounted

# THE GROUND'S EYES (Track TK2, proposed 2026-10-11): what the World's ground rule (scripts/sim/ground_rules.gd) is given to
# judge a tank's step by, answered from the game's own terrain and world layout, so the sim never learns the generators:
#
#   var gm := GroundMap.shared(seed, water)         # the one of a seed (the water: WaterGen.shared(seed), or null for none)
#   gm.attach(world)                                # world.set_ground(level_at, road_dist, woods_at, road_path)
#   gm.level_at(x, y)    -> int     the height level (0 low ground, 1 upland, 2 top); the same terrain the map draws (with the water's
#                                   cap on its height field when there is water), asked at the nearest point of the map outside it
#   gm.road_dist(x, y)   -> float   metres to the nearest road centre line; INF when none is within REACH_M
#   gm.woods_at(x, y)    -> float   the tree density 0..1: terrain.gd's own rule, "the chance a dart becomes a tree"
#                                   ((f - threshold) x gain on the level, f the grove field), so what the rule calls woods is where the
#                                   map draws groves; the water, the village and the road keep trees off, which only makes it denser
#                                   in the density than on the map: a road is judged first, so the road wins
#   gm.road_path(a, b)   -> PackedVector2Array   the road between the road points nearest a and b: the polyline, a's foot first
#
# The road is the world layout's (scripts/world/world_layout.gd road(): one polyline, metres, from the village to the map's edge).
# A second road would need a graph; there is one. Not thread safe (the terrain caches chunks): the sim's thread only, which is also
# the only one that asks. Not for the baker or the drawing: they have their own terrains.

const Terrain = preload("res://scripts/world/terrain.gd")
const ValueNoise = preload("res://scripts/render/fast_noise.gd")

const CELL_M := 64.0     # the road's bucket grid
const REACH_M := 32.0    # road_dist looks this far (a segment is 10 m long, so its ends are inside the 3 x 3 cells round the point)

static var _shared: Dictionary = {}

var seed_value: int = 0
var terrain: Variant = null
var road := PackedVector2Array()
var errors: Array[String] = []

var _cells: Dictionary = {}          # Vector2i -> PackedInt32Array: the segments (index of their first point) with an end in the cell
var _lo := Vector2.ZERO
var _hi := Vector2.ZERO

# The one of a seed (made on first use). `water` (WaterGen.shared(seed)) puts the water's cap on the terrain, as the map has it; null:
# the raw terrain.
static func shared(seed_v: int, water: RefCounted = null) -> RefCounted:
	var key := "%d|%s" % [seed_v, "w" if water != null else "raw"]
	if not _shared.has(key):
		_shared[key] = (load("res://scripts/world/ground_map.gd") as GDScript).new(seed_v, water)
	return _shared[key]

func _init(seed_v: int, water: RefCounted = null) -> void:
	seed_value = seed_v
	if water != null:
		if not water.ok():
			errors.append("the water of seed %d did not build: %s" % [seed_v, str(water.errors)])
		terrain = water.make_terrain()
	else:
		terrain = Terrain.new(seed_v)
	if not terrain.ok():
		errors.append("the terrain of seed %d did not build" % seed_v)
		return
	_lo = Vector2(terrain.map_x, terrain.map_y)
	_hi = Vector2(terrain.map_x + terrain.map_w - 0.01, terrain.map_y + terrain.map_h - 0.01)
	var lay: RefCounted = terrain.layout()
	if lay == null or not lay.ok():
		errors.append("the world layout of seed %d did not build" % seed_v)
		return
	road = lay.road()
	_index_road()

func ok() -> bool:
	return errors.is_empty()

# Give a World these eyes.
func attach(world: Object) -> void:
	world.set_ground(Callable(self, "level_at"), Callable(self, "road_dist"), Callable(self, "woods_at"), Callable(self, "road_path"))
	world.set_meta("ground_map", self)   # (a Callable does not keep a RefCounted alive)

# --- The queries ----------------------------------------------------------------------------------

func level_at(x: float, y: float) -> int:
	return int(terrain.level_at(clampf(x, _lo.x, _hi.x), clampf(y, _lo.y, _hi.y)))

func woods_at(x: float, y: float) -> float:
	var lev := level_at(x, y)
	var k: float = terrain.px_per_m * terrain.density_per_px
	var f := ValueNoise.fbm(x * k, y * k, terrain.density_seed, terrain.density_octaves)
	return clampf((f - float(terrain.veg_threshold[lev])) * float(terrain.veg_gain[lev]), 0.0, 1.0)

func road_dist(x: float, y: float) -> float:
	if road.size() < 2:
		return INF
	var cx := floori(x / CELL_M)
	var cy := floori(y / CELL_M)
	var p := Vector2(x, y)
	var best := INF
	for j in range(cy - 1, cy + 2):
		for i in range(cx - 1, cx + 2):
			var segs: Variant = _cells.get(Vector2i(i, j))
			if segs == null:
				continue
			for k: int in (segs as PackedInt32Array):
				best = minf(best, _seg_dist(p, road[k], road[k + 1]))
	return best if best <= REACH_M else INF

# The road between the points of it nearest `a` and `b`: [a's foot, the road's vertices between, b's foot].
func road_path(a: Vector2, b: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if road.size() < 2:
		return out
	var fa := _foot(a)
	var fb := _foot(b)
	out.append(fa["p"])
	var ka: int = fa["k"]
	var kb: int = fb["k"]
	if ka < kb or (ka == kb and float(fa["t"]) <= float(fb["t"])):
		for k in range(ka + 1, kb + 1):
			out.append(road[k])
	else:
		for k in range(ka, kb, -1):
			out.append(road[k])
	out.append(fb["p"])
	return out

# The point `m` metres along a road polyline from its point `idx`: forward (m > 0) is toward higher indexes (away from the village,
# index 0, to the map's edge), negative toward the village. Vector2(INF, INF) when the road ends first. (Track BM: a scenario places
# a unit "road_m" metres along the road from the bridge.)
static func road_point(road: PackedVector2Array, idx: int, m: float) -> Vector2:
	var step := 1 if m >= 0.0 else -1
	var left := absf(m)
	var i := clampi(idx, 0, road.size() - 1)
	var p := road[i]
	while left > 0.0:
		var j := i + step
		if j < 0 or j >= road.size():
			return Vector2(INF, INF)
		var seg := road[j].distance_to(road[i])
		if seg >= left:
			return road[i].lerp(road[j], left / seg)
		left -= seg
		i = j
		p = road[j]
	return p

# --- The road's index -------------------------------------------------------------------------------

func _index_road() -> void:
	_cells.clear()
	for k in road.size() - 1:
		for q: Vector2 in [road[k], road[k + 1]]:
			var key := Vector2i(floori(q.x / CELL_M), floori(q.y / CELL_M))
			if not _cells.has(key):
				_cells[key] = PackedInt32Array()
			var arr: PackedInt32Array = _cells[key]
			if arr.is_empty() or arr[arr.size() - 1] != k:
				arr.append(k)
				_cells[key] = arr

# The nearest point of the road to `p`: {k: the segment (road[k] to road[k + 1]), t: along it 0..1, p: the point}.
func _foot(p: Vector2) -> Dictionary:
	var best := INF
	var out := {"k": 0, "t": 0.0, "p": road[0]}
	for k in road.size() - 1:
		var a := road[k]
		var ab := road[k + 1] - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var q := a + ab * t
		var d := p.distance_squared_to(q)
		if d < best:
			best = d
			out = {"k": k, "t": t, "p": q}
	return out

static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
