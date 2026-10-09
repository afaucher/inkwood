extends RefCounted

# Terrain: height levels and the vegetation on them (Track T; exit criterion 4).
# Pure and seeded -- no nodes, no engine RNG, nothing drawn here. Generated in
# METRES; the vegetation is scene_gen's own tree records, in world PIXELS, so
# the renderer draws them exactly as it draws the prototype's trees.
#
#   var terrain := Terrain.new(20261009)           # reads data/terrain/terrain.json
#   terrain.level_at(x_m, y_m) -> int              # 0 = low ground, 1 = upland, 2 = top
#   terrain.height_at(x_m, y_m) -> float           # that level's height, metres
#   terrain.chunk(cx, cy) -> Dictionary            # the chunk's field and boundaries (metres)
#   terrain.trees_in_chunk(cx, cy) -> Array        # scene-gen tree records (px) + level, base, base_m
#   terrain.trees_in_rect_px(rect) / chunks_in_rect_px(rect) / chains_px(cx, cy, k)
#
# EVERYTHING IS PROPOSED. The design doc leaves the form of height open (the
# demo plan names "a plateau from thresholded fbm" as one option, and that is
# what this is); every number is in data/terrain/terrain.json with its reason.
#
# --- HOW A CHUNK IS MADE (from seed and chunk coordinates alone) -------------
#
# 1. FIELD. A height field h = fbm(x * noise_per_m, y * noise_per_m, seed', octaves)
#    sampled on a cell_m grid. Node (ix, iy) is a GLOBAL lattice index, so the
#    nodes on a chunk border are computed identically by both chunks.
# 2. LEVELS. Thresholds t_1 < t_2 cut the field into levels: level = how many
#    thresholds the field reaches. Level k stands at level_heights_m[k].
# 3. BOUNDARIES. Marching squares per threshold, the saddle decided by the
#    cell's mean, every segment ORIENTED with the higher level on its RIGHT
#    (screen coordinates, y down): an outer boundary runs clockwise on screen,
#    a hole (low ground ringed by upland) anticlockwise. Segments are chained
#    by edge identity. A chain that meets the chunk border stops there; its
#    end point is computed from the same two global nodes by the chunk on the
#    other side, so the two halves meet exactly. Then Chaikin (two passes) and
#    arc-length resampling (scripts/core/geometry.gd, float64), with an open
#    chain's border end points kept exactly.
# 4. REGIONS. Each threshold's region inside the chunk is a set of closed
#    polygons: every closed ring, plus the open chains joined into polygons by
#    walking the chunk border clockwise from each chain's end to the next
#    chain's start (or the whole square when the chunk is all upland). Regions
#    are what level_at tests (even-odd over the rings, so holes and islands in
#    holes are right) and what the drawing fills.
#    level_at is EXACT against the drawn polylines: a cell whose four corners
#    agree is never crossed by a smoothed boundary (Chaikin and resampling keep
#    every point inside the cells the raw chain crossed), so it answers from
#    the corners; a mixed cell answers by ray parity against the polygons.
# 5. VEGETATION. The prototype's own density rule (newScene's tree loop): darts
#    over the chunk, `f = fbm(x*.006, y*.006, seed%9973+3, 3)` in world pixels,
#    `if (f < thr || rng() > (f - thr) * gain) continue`, then makeTree,
#    syncTree and canPlace -- scene_gen's own make_tree / sync_tree / can_place
#    and spatial hash, on a SceneGen covering the chunk. thr and gain are per
#    LEVEL (data); a dart on the slope band below a scarp, or right at a scarp
#    top, is dropped. Every tree carries its level and the base height of that
#    level (`base` in px, the unit of `h`, and `base_m`).
#    CHUNK BORDERS: pre(X) is X's trees placed as above with no regard to any
#    neighbour. The chunk's final trees are pre(X) minus every tree that
#    overlaps a tree of pre(L) for the four neighbours that come BEFORE X in
#    (cy, cx) order (W, NW, N, NE). Removal never admits a tree pre(X) lacked,
#    so final(L) is a subset of pre(L); X avoided all of pre(L), so no two
#    final trees of neighbouring chunks overlap, and final(X) depends on
#    pre(X) and four pre(L) only -- pure functions of seed and coordinates.
#    pre() is cached, so a run of chunks costs about one placement per chunk.
#
# PRECISION: float64 throughout (GDScript floats, PackedFloat64Array); no
# Vector2 on any path that decides something. *_px helpers convert at the end
# for the drawing layer.

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
# core/noise.gd's hash2 / fbm, BIT FOR BIT (scripts/tests/test_render_layer.gd checks it), inlined
# and ~5x faster: every dart of every chunk calls fbm, which was about half of generation
# (a cold view 1.25 s -> 0.49 s, measured 2026-10-09). Output is unchanged to the bit, so a
# chunk is the same alone or among neighbours and the same as core/noise.gd gave (test_terrain).
const ValueNoise = preload("res://scripts/render/fast_noise.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const SceneGen = preload("res://scripts/world/scene_gen.gd")
const TerrainData = preload("res://scripts/world/terrain_data.gd")

# Salt for the per-chunk dart stream (a code constant, not a tunable).
const CHUNK_SALT := 0x7E44A1

var seed_value: int
var data: TerrainData
var P: RenderParams          # tree sizes, collision radii (its own instance: road switched off)
var errors: Array[String] = []

var px_per_m: float
var chunk_m: float
var cell_m: float
var cells: int               # cells per chunk side
var map_x: float             # map bounds, metres
var map_y: float
var map_w: float
var map_h: float
var bounds_source: String    # which file the bounds came from
var noise_per_m: float
var octaves: int
var height_seed: int
var thresholds := PackedFloat64Array()
var heights_m := PackedFloat64Array()
var chaikin_passes: int
var resample_m: float
var scarp_m: float
var dart_area_px: float
var density_per_px: float
var density_octaves: int
var density_seed: int
var veg_threshold := PackedFloat64Array()
var veg_gain := PackedFloat64Array()
var clearance_below_cr: float
var clearance_above_cr: float

var timings: Dictionary = {}   # name -> ms (last measured)

var _geo: Dictionary = {}      # Vector2i -> chunk geometry
var _pre: Dictionary = {}      # Vector2i -> Array of trees (pre-border)
var _final: Dictionary = {}    # Vector2i -> Array of trees
var _px: Dictionary = {}       # Vector3i(cx, cy, k) -> chains in px
var _sg: SceneGen              # cr() / max_cr() for the border pass

func _init(seed_v: int, data_path: String = TerrainData.DEFAULT_PATH, params: RenderParams = null) -> void:
	seed_value = seed_v
	data = TerrainData.new(data_path)
	# Always its own RenderParams, even when given a caller's: the road switch
	# below must never reach a renderer that shares the object.
	P = RenderParams.new(params.source_path) if params != null else RenderParams.new()
	# Terrain trees ignore the prototype's demo road (it is a stage-relative
	# spline, not part of the world); collision with other trees stays on.
	P.L["road"] = false
	_load()
	_sg = SceneGen.new(1.0, 1.0, P)

func ok() -> bool:
	return errors.is_empty() and data.ok() and P.ok()

func _load() -> void:
	px_per_m = data.num("scale.px_per_m")
	chunk_m = data.num("chunks.chunk_m")
	cell_m = data.num("chunks.cell_m")
	cells = roundi(chunk_m / cell_m)
	if not (cells > 0 and float(cells) * cell_m == chunk_m):
		_err("chunks.chunk_m (%s) is not a whole number of chunks.cell_m (%s)" % [chunk_m, cell_m])
	var fallback: Dictionary = data.dict("map.fallback_bounds_m")
	var src := data.text("map.bounds_source")
	var bounds: Dictionary = fallback
	bounds_source = "data/terrain/terrain.json#map.fallback_bounds_m"
	if FileAccess.file_exists(src):
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(src))
		if raw is Dictionary and (raw as Dictionary).get("map_bounds_m") is Dictionary:
			var rec: Dictionary = (raw as Dictionary)["map_bounds_m"]
			if rec.get("value") is Dictionary:
				bounds = rec["value"]
				bounds_source = src + "#map_bounds_m"
	map_x = float(bounds.get("x", 0.0))
	map_y = float(bounds.get("y", 0.0))
	map_w = float(bounds.get("width", 0.0))
	map_h = float(bounds.get("height", 0.0))
	if not (map_w > 0.0 and map_h > 0.0):
		_err("map bounds have no area (%s)" % bounds_source)
	noise_per_m = data.num("height.noise_per_m")
	octaves = data.integer("height.octaves")
	height_seed = seed_value % 9973 + data.integer("height.seed_offset")
	thresholds = data.floats("height.thresholds")
	heights_m = data.floats("height.level_heights_m")
	if heights_m.size() != thresholds.size() + 1:
		_err("height.level_heights_m needs one entry per threshold plus the low ground")
	for k in range(1, thresholds.size()):
		if not (thresholds[k] > thresholds[k - 1]):
			_err("height.thresholds must increase")
	chaikin_passes = data.integer("boundary.chaikin_passes")
	resample_m = data.num("boundary.resample_m")
	scarp_m = data.num("scarp.width_m")
	dart_area_px = data.num("vegetation.dart_area_px")
	density_per_px = data.num("vegetation.density_noise_per_px")
	density_octaves = data.integer("vegetation.density_octaves")
	density_seed = seed_value % 9973 + data.integer("vegetation.density_seed_offset")
	for e: Variant in data.list("vegetation.levels"):
		var d: Dictionary = e if e is Dictionary else {}
		var thr: Variant = d.get("threshold")
		var gain: Variant = d.get("gain")
		if not ((thr is float or thr is int) and (gain is float or gain is int)):
			_err("vegetation.levels entries need a numeric threshold and gain: %s" % [e])
		veg_threshold.append(float(thr) if thr != null else NAN)
		veg_gain.append(float(gain) if gain != null else NAN)
	if veg_threshold.size() != heights_m.size():
		_err("vegetation.levels needs one entry per level")
	clearance_below_cr = data.num("vegetation.clearance_below_cr")
	clearance_above_cr = data.num("vegetation.clearance_above_cr")

func _err(message: String) -> void:
	errors.append(message)
	push_error("Terrain: " + message)

# --- the field ------------------------------------------------------------------

func level_count() -> int:
	return heights_m.size()

# The field at global lattice node (ix, iy).
func field_at_node(ix: int, iy: int) -> float:
	var x: float = float(ix) * cell_m
	var y: float = float(iy) * cell_m
	return ValueNoise.fbm(x * noise_per_m, y * noise_per_m, height_seed, octaves)

# --- queries ---------------------------------------------------------------------

# The level at (x, y) in metres: 0 for the low ground, k for at or above
# threshold k. Exact against the smoothed boundaries the drawing uses.
func level_at(x: float, y: float) -> int:
	var c := chunk(floori(x / chunk_m), floori(y / chunk_m))
	var n := cells
	var i := clampi(floori((x - c.x0) / cell_m), 0, n - 1)
	var j := clampi(floori((y - c.y0) / cell_m), 0, n - 1)
	var vals: PackedFloat64Array = c.vals
	var level := 0
	for k in thresholds.size():
		var L: Dictionary = c.levels[k]
		var mixed: PackedByteArray = L.mixed
		var inside: bool
		if mixed[j * n + i] == 0:
			inside = vals[j * (n + 1) + i] >= thresholds[k]
		else:
			inside = _parity(L, j, x, y)
		if not inside:
			break
		level = k + 1
	return level

# The height of the level at (x, y), metres.
func height_at(x: float, y: float) -> float:
	return heights_m[level_at(x, y)]

# Pixel-coordinate twins for the drawing layer (world px at zoom 1).
func level_at_px(x: float, y: float) -> int:
	return level_at(x / px_per_m, y / px_per_m)

func height_px_at(x: float, y: float) -> float:
	return heights_m[level_at(x / px_per_m, y / px_per_m)] * px_per_m

# Distance in metres from (x, y) to the nearest boundary of threshold k, or
# INF when none is within `reach` metres.
func boundary_distance(x: float, y: float, k: int, reach: float) -> float:
	var best := INF
	var r2 := reach * reach
	for cy in range(floori((y - reach) / chunk_m), floori((y + reach) / chunk_m) + 1):
		for cx in range(floori((x - reach) / chunk_m), floori((x + reach) / chunk_m) + 1):
			var c := chunk(cx, cy)
			var L: Dictionary = c.levels[k]
			var buckets: Dictionary = L.buckets
			if buckets.is_empty():
				continue
			var i0 := maxi(0, floori((x - reach - c.x0) / cell_m))
			var i1 := mini(cells - 1, floori((x + reach - c.x0) / cell_m))
			var j0 := maxi(0, floori((y - reach - c.y0) / cell_m))
			var j1 := mini(cells - 1, floori((y + reach - c.y0) / cell_m))
			for j in range(j0, j1 + 1):
				for i in range(i0, i1 + 1):
					var segs: Variant = buckets.get(j * cells + i)
					if segs == null:
						continue
					var s: PackedFloat64Array = segs
					for q in range(0, s.size(), 4):
						var d2 := _seg_dist2(x, y, s[q], s[q + 1], s[q + 2], s[q + 3])
						if d2 < r2 and d2 < best * best:
							best = sqrt(d2)
	return best

static func _seg_dist2(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
	var vx := bx - ax
	var vy := by - ay
	var wx := px - ax
	var wy := py - ay
	var l2 := vx * vx + vy * vy
	var t := 0.0
	if l2 > 0.0:
		t = clampf((wx * vx + wy * vy) / l2, 0.0, 1.0)
	var dx := wx - vx * t
	var dy := wy - vy * t
	return dx * dx + dy * dy

# --- map and chunk bookkeeping -----------------------------------------------------------

func chunk_of(x: float, y: float) -> Vector2i:
	return Vector2i(floori(x / chunk_m), floori(y / chunk_m))

func chunk_in_map(cx: int, cy: int) -> bool:
	var x0 := float(cx) * chunk_m
	var y0 := float(cy) * chunk_m
	return x0 < map_x + map_w and x0 + chunk_m > map_x and y0 < map_y + map_h and y0 + chunk_m > map_y

func map_chunk_range() -> Rect2i:
	var c0 := chunk_of(map_x, map_y)
	var c1 := chunk_of(map_x + map_w - 1e-9, map_y + map_h - 1e-9)
	return Rect2i(c0, c1 - c0 + Vector2i.ONE)

# Chunks of the map that a world-pixel rectangle touches.
func chunks_in_rect_px(rect: Rect2) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var cpx := chunk_m * px_per_m
	for cy in range(floori(rect.position.y / cpx), floori(rect.end.y / cpx) + 1):
		for cx in range(floori(rect.position.x / cpx), floori(rect.end.x / cpx) + 1):
			if chunk_in_map(cx, cy):
				out.append(Vector2i(cx, cy))
	return out

func map_rect_px() -> Rect2:
	return Rect2(map_x * px_per_m, map_y * px_per_m, map_w * px_per_m, map_h * px_per_m)

# --- chunk geometry ------------------------------------------------------------------

# The chunk's field and its boundaries, generated on first use and cached:
#   x0, y0        the chunk's top-left corner, metres
#   vals          the field at its (cells+1)^2 lattice nodes, row by row
#   levels[k]     per threshold k (the boundary between level k and k+1):
#     chains      [{pts: PackedFloat64Array (x, y pairs, metres), closed: bool}],
#                 oriented with the higher level on the right (y down)
#     polys       [{pts, area, border}]: the region at or above the threshold
#                 inside the chunk -- closed rings (border false; area < 0 for
#                 a hole) and border-closed polygons (border true)
#     mixed       PackedByteArray per cell: 1 where the corners disagree
func chunk(cx: int, cy: int) -> Dictionary:
	var key := Vector2i(cx, cy)
	var hit: Variant = _geo.get(key)
	if hit != null:
		return hit
	var t0 := Time.get_ticks_usec()
	var n := cells
	var stride := n + 1
	var gx0 := cx * n
	var gy0 := cy * n
	var vals := PackedFloat64Array()
	vals.resize(stride * stride)
	for j in stride:
		for i in stride:
			vals[j * stride + i] = field_at_node(gx0 + i, gy0 + j)
	var c := {"cx": cx, "cy": cy, "x0": float(gx0) * cell_m, "y0": float(gy0) * cell_m, "vals": vals, "levels": []}
	for k in thresholds.size():
		(c.levels as Array).append(_contour(c, thresholds[k]))
	_geo[key] = c
	timings["chunk_geometry_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return c

# Edge keys: H(i, j) joins nodes (i, j)-(i+1, j); V(i, j) joins (i, j)-(i, j+1).
func _ekey(i: int, j: int, dir: int) -> int:
	return (j * (cells + 1) + i) * 2 + dir

func _contour(c: Dictionary, thr: float) -> Dictionary:
	var n := cells
	var stride := n + 1
	var vals: PackedFloat64Array = c.vals
	var ins := PackedByteArray()
	ins.resize(stride * stride)
	for idx in stride * stride:
		ins[idx] = 1 if vals[idx] >= thr else 0
	var mixed := PackedByteArray()
	mixed.resize(n * n)
	var next_of: Dictionary = {}  # start edge -> end edge
	var ends: Dictionary = {}     # end edge -> true
	var corner := [0, 0, 0, 0]
	var ek := [0, 0, 0, 0]
	for j in n:
		for i in n:
			# corners clockwise on screen: TL, TR, BR, BL; edges: top, right, bottom, left
			corner[0] = ins[j * stride + i]
			corner[1] = ins[j * stride + i + 1]
			corner[2] = ins[(j + 1) * stride + i + 1]
			corner[3] = ins[(j + 1) * stride + i]
			var code: int = corner[0] | (corner[1] << 1) | (corner[2] << 2) | (corner[3] << 3)
			if code == 0 or code == 15:
				continue
			mixed[j * n + i] = 1
			ek[0] = _ekey(i, j, 0)
			ek[1] = _ekey(i + 1, j, 1)
			ek[2] = _ekey(i, j + 1, 0)
			ek[3] = _ekey(i, j, 1)
			# Corner k sits between edge (k+3)%4 (before it, clockwise) and edge k
			# (after it). A segment from the edge after an inside run to the edge
			# before it has that run on its right.
			if code == 5 or code == 10:
				var mean := (vals[j * stride + i] + vals[j * stride + i + 1]
					+ vals[(j + 1) * stride + i + 1] + vals[(j + 1) * stride + i]) / 4.0
				var centre_in := mean >= thr
				for k in 4:
					if centre_in and corner[k] == 0:
						_link(next_of, ends, ek[(k + 3) % 4], ek[k])   # cut off an outside corner
					elif not centre_in and corner[k] == 1:
						_link(next_of, ends, ek[k], ek[(k + 3) % 4])   # cut off an inside corner
			else:
				var s := 0
				while not (corner[s] == 1 and corner[(s + 3) % 4] == 0):
					s += 1
				var e := s
				while corner[(e + 1) % 4] == 1:
					e = (e + 1) % 4
				_link(next_of, ends, ek[e], ek[(s + 3) % 4])

	# Chains: open ones start at an edge nothing ends at (a border edge).
	var chains: Array = []
	var seen: Dictionary = {}
	var starts: Array = []
	for k: int in next_of:
		if not ends.has(k):
			starts.append(k)
	starts.sort()
	for s: int in starts:
		var keys := PackedInt64Array([s])
		var cur: int = s
		seen[cur] = true
		while next_of.has(cur):
			cur = next_of[cur]
			keys.append(cur)
			seen[cur] = true
		chains.append({"keys": keys, "closed": false})
	var rest: Array = next_of.keys()
	rest.sort()
	for s: int in rest:
		if seen.has(s):
			continue
		var keys := PackedInt64Array([s])
		seen[s] = true
		var cur: int = next_of[s]
		while cur != s:
			keys.append(cur)
			seen[cur] = true
			cur = next_of[cur]
		chains.append({"keys": keys, "closed": true})

	var out_chains: Array = []
	var open_info: Array = []  # [chain index in out_chains, s_start, s_end]
	for ch: Dictionary in chains:
		var keys: PackedInt64Array = ch.keys
		var raw := PackedFloat64Array()
		for key in keys:
			_append_edge_point(raw, c, thr, key)
		var pts := _smooth(raw, ch.closed)
		out_chains.append({"pts": pts, "closed": ch.closed})
		if not ch.closed:
			open_info.append([out_chains.size() - 1, _perimeter(c, keys[0], raw[0], raw[1]),
				_perimeter(c, keys[keys.size() - 1], raw[raw.size() - 2], raw[raw.size() - 1])])

	var polys: Array = []
	for ch: Dictionary in out_chains:
		if ch.closed:
			polys.append({"pts": ch.pts, "area": _area(ch.pts), "border": false})
	polys.append_array(_border_polys(c, out_chains, open_info, ins[0] == 1))

	var L := {"chains": out_chains, "polys": polys, "mixed": mixed}
	L["rows"] = _row_edges(c, polys)
	L["buckets"] = _segment_buckets(c, out_chains)
	return L

func _link(next_of: Dictionary, ends: Dictionary, a: int, b: int) -> void:
	if next_of.has(a) or ends.has(b):
		_err("marching squares: edge %d / %d used twice (orientation)" % [a, b])
	next_of[a] = b
	ends[b] = true

# The threshold crossing on an edge, interpolated from its lower-indexed node
# to the other -- the same two global nodes in whichever chunk asks.
func _append_edge_point(out: PackedFloat64Array, c: Dictionary, thr: float, key: int) -> void:
	var stride := cells + 1
	var dir := key & 1
	var node := key >> 1
	var i := node % stride
	var j := node / stride
	var vals: PackedFloat64Array = c.vals
	var va: float = vals[node]
	var vb: float = vals[node + 1] if dir == 0 else vals[node + stride]
	var t: float = (thr - va) / (vb - va)
	var gx: int = c.cx * cells + i
	var gy: int = c.cy * cells + j
	var xa: float = float(gx) * cell_m
	var ya: float = float(gy) * cell_m
	var xb: float = float(gx + 1) * cell_m if dir == 0 else xa
	var yb: float = ya if dir == 0 else float(gy + 1) * cell_m
	out.append(xa + (xb - xa) * t)
	out.append(ya + (yb - ya) * t)

# Chaikin, then arc-length resampling; an open chain keeps its exact end points
# (they sit on the chunk border and must meet the neighbour's).
func _smooth(raw: PackedFloat64Array, closed: bool) -> PackedFloat64Array:
	var p := raw
	for _k in chaikin_passes:
		p = Geometry.chaikin_f64(p, closed)
	var r := Geometry.resample_f64(p, resample_m, closed)
	if closed:
		return r if r.size() >= 6 else p
	var m := r.size()
	var ex: float = p[p.size() - 2]
	var ey: float = p[p.size() - 1]
	if r[m - 2] != ex or r[m - 1] != ey:
		if m >= 4 and absf(r[m - 2] - ex) + absf(r[m - 1] - ey) < resample_m * 0.5:
			r[m - 2] = ex
			r[m - 1] = ey
		else:
			r.append(ex)
			r.append(ey)
	return r

# Position along the chunk border, clockwise on screen from the top-left
# corner: top edge [0, S), right [S, 2S), bottom [2S, 3S), left [3S, 4S).
func _perimeter(c: Dictionary, key: int, x: float, y: float) -> float:
	var stride := cells + 1
	var dir := key & 1
	var node := key >> 1
	var i := node % stride
	var j := node / stride
	var S := chunk_m
	if dir == 0 and j == 0:
		return x - c.x0
	if dir == 1 and i == cells:
		return S + (y - c.y0)
	if dir == 0 and j == cells:
		return 2.0 * S + (c.x0 + S - x)
	if dir == 1 and i == 0:
		return 3.0 * S + (c.y0 + S - y)
	_err("open chain ends off the chunk border (edge %d)" % key)
	return 0.0

# Open chains joined into closed polygons along the chunk border.
func _border_polys(c: Dictionary, chains: Array, open_info: Array, corner_in: bool) -> Array:
	var S := chunk_m
	var x0: float = c.x0
	var y0: float = c.y0
	var corners := [[0.0, x0, y0], [S, x0 + S, y0], [2.0 * S, x0 + S, y0 + S], [3.0 * S, x0, y0 + S]]
	var out: Array = []
	if open_info.is_empty():
		if corner_in:
			var sq := PackedFloat64Array([x0, y0, x0 + S, y0, x0 + S, y0 + S, x0, y0 + S])
			out.append({"pts": sq, "area": _area(sq), "border": true})
		return out
	var used: Dictionary = {}
	for a in open_info.size():
		if used.has(a):
			continue
		var poly := PackedFloat64Array()
		var cur := a
		var guard := 0
		while true:
			used[cur] = true
			poly.append_array(chains[open_info[cur][0]].pts)
			var se: float = open_info[cur][2]
			var best := -1
			var best_d := INF
			for b in open_info.size():
				var d := fposmod(float(open_info[b][1]) - se, 4.0 * S)
				if d == 0.0:
					d = 4.0 * S
				if d < best_d:
					best_d = d
					best = b
			var passed: Array = []
			for q: Array in corners:
				var dc := fposmod(float(q[0]) - se, 4.0 * S)
				if dc > 0.0 and dc < best_d:
					passed.append([dc, q[1], q[2]])
			passed.sort_custom(func(u: Array, v: Array) -> bool: return u[0] < v[0])
			for q: Array in passed:
				poly.append(q[1])
				poly.append(q[2])
			guard += 1
			if best == a or guard > open_info.size():
				break
			if used.has(best):
				_err("border walk reached a used chain in chunk (%d, %d)" % [c.cx, c.cy])
				break
			cur = best
		out.append({"pts": poly, "area": _area(poly), "border": true})
	return out

# Shoelace area, positive for clockwise on screen (y down).
static func _area(p: PackedFloat64Array) -> float:
	var a := 0.0
	var n := p.size() / 2
	for i in n:
		var j := (i + 1) % n
		a += p[i * 2] * p[j * 2 + 1] - p[j * 2] * p[i * 2 + 1]
	return a * 0.5

# Polygon edges bucketed by cell row, for the parity test.
func _row_edges(c: Dictionary, polys: Array) -> Array:
	var rows: Array = []
	for r in cells:
		rows.append(PackedFloat64Array())
	for poly: Dictionary in polys:
		var p: PackedFloat64Array = poly.pts
		var n := p.size() / 2
		for i in n:
			var j := (i + 1) % n
			var ax: float = p[i * 2]
			var ay: float = p[i * 2 + 1]
			var bx: float = p[j * 2]
			var by: float = p[j * 2 + 1]
			if ay == by:
				continue  # horizontal edges never cross a horizontal ray
			var r0 := clampi(floori((minf(ay, by) - c.y0) / cell_m), 0, cells - 1)
			var r1 := clampi(floori((maxf(ay, by) - c.y0) / cell_m), 0, cells - 1)
			for r in range(r0, r1 + 1):
				var row: PackedFloat64Array = rows[r]
				row.append(ax)
				row.append(ay)
				row.append(bx)
				row.append(by)
				rows[r] = row
	return rows

# Even-odd: a ray from (x, y) toward +x, against every region edge in the row.
func _parity(L: Dictionary, row: int, x: float, y: float) -> bool:
	var e: PackedFloat64Array = L.rows[row]
	var inside := false
	for q in range(0, e.size(), 4):
		var ay: float = e[q + 1]
		var by: float = e[q + 3]
		if (ay > y) != (by > y):
			var ax: float = e[q]
			var bx: float = e[q + 2]
			var xi := ax + (y - ay) / (by - ay) * (bx - ax)
			if xi > x:
				inside = not inside
	return inside

# Chain segments bucketed by cell, for boundary_distance().
func _segment_buckets(c: Dictionary, chains: Array) -> Dictionary:
	var out: Dictionary = {}
	for ch: Dictionary in chains:
		var p: PackedFloat64Array = ch.pts
		var n := p.size() / 2
		var lim := n if ch.closed else n - 1
		for i in lim:
			var j := (i + 1) % n
			var ax: float = p[i * 2]
			var ay: float = p[i * 2 + 1]
			var bx: float = p[j * 2]
			var by: float = p[j * 2 + 1]
			var i0 := clampi(floori((minf(ax, bx) - c.x0) / cell_m), 0, cells - 1)
			var i1 := clampi(floori((maxf(ax, bx) - c.x0) / cell_m), 0, cells - 1)
			var j0 := clampi(floori((minf(ay, by) - c.y0) / cell_m), 0, cells - 1)
			var j1 := clampi(floori((maxf(ay, by) - c.y0) / cell_m), 0, cells - 1)
			for cj in range(j0, j1 + 1):
				for ci in range(i0, i1 + 1):
					var k := cj * cells + ci
					var b: PackedFloat64Array = out.get(k, PackedFloat64Array())
					b.append(ax)
					b.append(ay)
					b.append(bx)
					b.append(by)
					out[k] = b
	return out

# The chains of threshold k in world pixels, for drawing: [{pts: PackedVector2Array, closed}].
func chains_px(cx: int, cy: int, k: int) -> Array:
	var key := Vector3i(cx, cy, k)
	var hit: Variant = _px.get(key)
	if hit != null:
		return hit
	var out: Array = []
	for ch: Dictionary in chunk(cx, cy).levels[k].chains:
		out.append({"pts": _to_px(ch.pts), "closed": ch.closed})
	_px[key] = out
	return out

# The region polygons of threshold k in world pixels: [{pts, area, border}].
func polys_px(cx: int, cy: int, k: int) -> Array:
	var out: Array = []
	for poly: Dictionary in chunk(cx, cy).levels[k].polys:
		out.append({"pts": _to_px(poly.pts), "area": poly.area * px_per_m * px_per_m, "border": poly.border})
	return out

func _to_px(p: PackedFloat64Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(p.size() / 2)
	for i in out.size():
		out[i] = Vector2(p[i * 2] * px_per_m, p[i * 2 + 1] * px_per_m)
	return out

# --- vegetation ---------------------------------------------------------------------

func _chunk_seed(cx: int, cy: int) -> int:
	return int(ValueNoise.hash2(cx, cy, seed_value ^ CHUNK_SALT) * 4294967296.0)

# A dart at (x, y) metres on `level`, for a tree of collision radius c_m metres:
# false when it would stand on the slope band below a scarp or at its very top.
func _clear_of_scarps(x: float, y: float, level: int, c_m: float) -> bool:
	for k in thresholds.size():
		var below := level <= k   # boundary k is the top of a scarp above this tree
		var need := scarp_m + clearance_below_cr * c_m if below else clearance_above_cr * c_m
		if boundary_distance(x, y, k, need) < need:
			return false
	return true

# The chunk's trees with no regard to its neighbours (see the header, step 5).
func _pre_trees(cx: int, cy: int) -> Array:
	var key := Vector2i(cx, cy)
	var hit: Variant = _pre.get(key)
	if hit != null:
		return hit
	var t0 := Time.get_ticks_usec()
	var out: Array = []
	if chunk_in_map(cx, cy):
		var cpx := chunk_m * px_per_m
		var gen := SceneGen.new(cpx, cpx, P)
		var rng := Mulberry32.new(_chunk_seed(cx, cy))
		var ox := float(cx) * cpx
		var oy := float(cy) * cpx
		var levels: Array[int] = []
		var tries := roundi(cpx * cpx / dart_area_px)
		for _i in tries:
			var lx := rng.next() * cpx
			var ly := rng.next() * cpx
			var wx := ox + lx
			var wy := oy + ly
			var lev := level_at(wx / px_per_m, wy / px_per_m)
			var f := ValueNoise.fbm(wx * density_per_px, wy * density_per_px, density_seed, density_octaves)
			var thr: float = veg_threshold[lev]
			if f < thr or rng.next() > (f - thr) * veg_gain[lev]:
				continue
			var t := gen.make_tree(rng, lx, ly)
			gen.sync_tree(t)
			var c := gen.cr(t)
			if not _clear_of_scarps(wx / px_per_m, wy / px_per_m, lev, c / px_per_m):
				continue
			if gen.can_place(lx, ly, c, true):
				gen.trees.append(t)
				gen.g_add(t)
				levels.append(lev)
		for i in gen.trees.size():
			var t: Dictionary = gen.trees[i]
			var w := t.duplicate()
			w.x = ox + float(t.x)
			w.y = oy + float(t.y)
			w["level"] = levels[i]
			w["base_m"] = heights_m[levels[i]]
			w["base"] = heights_m[levels[i]] * px_per_m
			w["chunk"] = key
			out.append(w)
	_pre[key] = out
	timings["chunk_trees_pre_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return out

# The chunk's trees: scene-gen tree records in world px (kind, x, y, seed, sr,
# hr, big, r, h, key) plus level, base (px, the unit of h), base_m and chunk.
# Sorted as the prototype draws them is the renderer's business.
func trees_in_chunk(cx: int, cy: int) -> Array:
	var key := Vector2i(cx, cy)
	var hit: Variant = _final.get(key)
	if hit != null:
		return hit
	var t0 := Time.get_ticks_usec()
	var own := _pre_trees(cx, cy)
	var reach := 2.0 * _sg.max_cr()
	var cpx := chunk_m * px_per_m
	var rect := Rect2(float(cx) * cpx - reach, float(cy) * cpx - reach, cpx + 2.0 * reach, cpx + 2.0 * reach)
	var cell := reach
	var grid: Dictionary = {}
	for nb: Vector2i in [Vector2i(cx - 1, cy), Vector2i(cx - 1, cy - 1), Vector2i(cx, cy - 1), Vector2i(cx + 1, cy - 1)]:
		for b: Dictionary in _pre_trees(nb.x, nb.y):
			if rect.has_point(Vector2(b.x, b.y)):
				var k := Vector2i(floori(b.x / cell), floori(b.y / cell))
				if not grid.has(k):
					grid[k] = []
				(grid[k] as Array).append(b)
	var out: Array = []
	for t: Dictionary in own:
		if not _inside_map_px(t.x, t.y):
			continue
		var ct := _sg.cr(t)
		var gx := floori(t.x / cell)
		var gy := floori(t.y / cell)
		var clash := false
		for yy in range(gy - 1, gy + 2):
			for xx in range(gx - 1, gx + 2):
				var a: Variant = grid.get(Vector2i(xx, yy))
				if a == null:
					continue
				for b: Dictionary in a:
					var dx: float = b.x - t.x
					var dy: float = b.y - t.y
					var rr: float = ct + _sg.cr(b)
					if dx * dx + dy * dy < rr * rr:
						clash = true
						break
				if clash:
					break
			if clash:
				break
		if not clash:
			out.append(t)
	_final[key] = out
	timings["chunk_trees_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	return out

func _inside_map_px(x: float, y: float) -> bool:
	var xm := x / px_per_m
	var ym := y / px_per_m
	return xm >= map_x and xm < map_x + map_w and ym >= map_y and ym < map_y + map_h

# Every tree whose centre lies in a world-pixel rectangle.
func trees_in_rect_px(rect: Rect2) -> Array:
	var out: Array = []
	for c in chunks_in_rect_px(rect):
		for t: Dictionary in trees_in_chunk(c.x, c.y):
			if rect.has_point(Vector2(t.x, t.y)):
				out.append(t)
	return out

# Drops cached chunks (geometry and trees), e.g. to time a cold generation.
func clear_cache() -> void:
	_geo.clear()
	_pre.clear()
	_final.clear()
	_px.clear()
