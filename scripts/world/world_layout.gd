extends RefCounted

# THE WORLD LAYOUT (Track W, 2026-10-10): the coarse plan of the strike's map, made ONCE from the
# seed -- where the village is, the street through it, the road from it to a map edge, the fields
# round it, the radio tower's site in a walled compound and two anti-aircraft battery sites near
# the tower. Pure and deterministic: a function of (seed, data/world/layout.json, the terrain's
# height field), nothing else, so every machine and every bake order sees the same plan. All
# rules and numbers are data (data/world/layout.json, every value a PROPOSED record); the only
# thing Alex has decided is the plan itself (strike-target, strike-plan, 2026-10-10).
#
#   const WorldLayout = preload("res://scripts/world/world_layout.gd")
#   var layout := WorldLayout.new(20261009)          # makes its own Terrain for level queries
#   var layout := WorldLayout.new(20261009, terrain)  # ... or uses the one you have (any Terrain
#                                                     # of this seed: the layout never keeps it)
#   layout.sites() -> {"radio_tower": Vector2, "aa_battery": [Vector2, Vector2]}      metres
#   layout.village() -> Dictionary                    the village (see below)
#   layout.road() -> PackedVector2Array               the road, metres, a point every road.sample_m
#   layout.fields() -> Array[PackedVector2Array]      field polygons, metres (convex quadrilaterals)
#   layout.field_info(i) -> {angle, kind, seed}       how field i is worked (its crop rows' direction)
#   layout.ok() / layout.errors / layout.diagnostics  what happened (search steps, build ms, ...)
#
# village() returns {
#   "centre": Vector2,            the village's middle (on the street)
#   "axis": float,                the street's direction, radians (x right, y down); the road leaves along +axis
#   "street": PackedVector2Array  [far end, centre, front end]: the straight street
#   "half_length_m", "half_width_m",
#   "polygon": PackedVector2Array its outline (a rounded block)
#   "compound": {"site": Vector2, "rot": float, "reserve_radius_m": float, "fort_seed": int},
#   "house_slots": [{"pos": Vector2, "rot": float, "seed": int, "row": "front"|"back"}, ...]
#                                  where houses may stand (scripts/world/village.gd makes the
#                                  houses at them, in map px, dropping any that would overlap)
# }
# The tower's site is the middle of the open cell of the walled compound (the prototype's fort:
# a ring, a divider and a smaller ring in the left cell); the village builds the compound round it.
#
# HOW IT IS MADE (the whole of it, so a reader need not guess):
# 1. A coarse grid of the terrain's own field (grid.step_m) over the map. Candidate centres on a
#    lattice (village.search.*) that are inside the edge margin and the preferred distance band
#    from the map centre, and whose clear disc is low ground by the grid, are ordered by a seeded
#    hash; the first whose finished village polygon passes the EXACT level_at check wins (the
#    search relaxes, never settles for a village on the hills).
# 2. The road: the village faces a map edge; the road runs from the street's front end to the
#    edge by a weighted A* over the grid (high ground costs a lot, wiggle noise makes it wander),
#    straightened where straight is clear, rounded by Chaikin, resampled, given a slow lateral
#    wander and carried past the edge. Its first part is the straight street itself.
# 3. Houses' slots along both sides of the street and a back row; the compound's site.
# 4. Fields: dart-thrown convex quadrilaterals round the village, clear of the village, the road,
#    each other, the compound and every cliff.
# 5. Battery sites: seeded darts round the tower on open level-0 ground, clear of the village,
#    the road and the fields, far enough from each other.
#
# CYCLE NOTE: terrain.gd preloads this script, so this one never preloads terrain.gd: when it must
# make its own Terrain it load()s it at run time.

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/render/fast_noise.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const TerrainData = preload("res://scripts/world/terrain_data.gd")

const DEFAULT_PATH := "res://data/world/layout.json"
const TERRAIN_SCRIPT := "res://scripts/world/terrain.gd"
const TERRAIN_DATA := "res://data/terrain/terrain.json"

# Salts for the layout's streams (code constants, not tunables).
const S_VILLAGE := 11
const S_STREET := 12
const S_COMPOUND := 13
const S_HOUSES := 14
const S_ROAD := 15
const S_FIELDS := 16
const S_BATTERY := 17

# Layouts are immutable once built: Terrain instances of one seed (the map's, the fog's, the
# sandbox's) share one, keyed by seed and the text of the two data files.
static var _cache: Dictionary = {}
static var _cache_mutex := Mutex.new()

var seed_value: int
var data: TerrainData
var errors: Array[String] = []
var diagnostics: Dictionary = {}

# --- the plan ----------------------------------------------------------------------------------
var _centre := Vector2.ZERO
var _axis := 0.0
var _street := PackedVector2Array()
var _polygon := PackedVector2Array()
var _site := Vector2.ZERO
var _compound_rot := 0.0
var _fort_seed := 0
var _slots: Array = []
var _road := PackedVector2Array()
var _fields: Array[PackedVector2Array] = []
var _field_info: Array = []
var _batteries: Array[Vector2] = []

# --- values read from data ---------------------------------------------------------------------
var _salt: int
var _grid_m: float
var _edge_margin: float
var _search_step: float
var _dist_band := PackedFloat64Array()
var _search_road_tries: int
var _clear_radius: float
var _clear_margin: float
var _relax_factor: float
var _relax_steps: int
var _street_half: float
var _street_jitter: float
var _edge_slack: float
var _ext_half_len: float
var _ext_half_wid: float
var _ext_exp: float
var _ext_points: int
var _ext_wobble: float
var _verify_step: float
var _village_cliff: float
var _comp_frac: float
var _comp_offset: float
var _comp_reserve: float
var _comp_tilt: float
var _house_offset: float
var _house_offset_jit: float
var _house_spacing: float
var _house_spacing_jit: float
var _house_skip: float
var _house_end: float
var _house_back_count: int
var _house_back := PackedFloat64Array()
var _house_rot_jit: float
var _road_clear: float
var _road_margin: float
var _road_scales := PackedFloat64Array()
var _road_cliff: float
var _road_upland: float
var _road_wiggle: float
var _road_wiggle_f: float
var _road_goals: int
var _road_goal_spread: float
var _road_simplify: float
var _road_smooth: int
var _road_sample: float
var _road_wander: float
var _road_wander_wl: float
var _road_beyond: float
var _f_count: int
var _f_attempts: int
var _f_ring := PackedFloat64Array()
var _f_long := PackedFloat64Array()
var _f_ratio := PackedFloat64Array()
var _f_jitter: float
var _f_gap: float
var _f_village_gap: float
var _f_road_gap: float
var _f_cliff: float
var _f_step: float
var _f_kinds: int
var _f_turn: float
var _f_margin: float
var _b_count: int
var _b_dist := PackedFloat64Array()
var _b_angle := PackedFloat64Array()
var _b_apart: float
var _b_open: float
var _b_cliff: float
var _b_village_gap: float
var _b_road_gap: float
var _b_field_gap: float
var _b_margin: float
var _b_attempts: int
var tree_gain_in_village: float

# --- terrain facts, copied at construction (the terrain itself is not kept) --------------------
var _t: Variant = null     # the Terrain, only while building
var _map := Rect2()
var _thr0: float
var _gcols := 0
var _grows := 0
var _gf := PackedFloat64Array()

# Makes the layout. `terrain` is any Terrain of this seed (the layout reads its field and level_at
# and does not keep it); null makes one.
func _init(seed_v: int, terrain: Variant = null, path: String = DEFAULT_PATH) -> void:
	seed_value = seed_v
	data = TerrainData.new(path)
	if not data.ok():
		errors.append_array(data.errors)
		return
	_t = terrain
	if _t == null:
		_t = (load(TERRAIN_SCRIPT) as GDScript).new(seed_v)
	var t0 := Time.get_ticks_usec()
	_read()
	if errors.is_empty():
		_map = Rect2(float(_t.map_x), float(_t.map_y), float(_t.map_w), float(_t.map_h))
		_thr0 = float(_t.thresholds[0])
		_grid()
		_build()
	diagnostics["build_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	_t = null

func ok() -> bool:
	return errors.is_empty() and data.ok()

# The shared instance for (seed, data, terrain data); built on first use.
static func shared(seed_v: int, terrain: Variant = null, path: String = DEFAULT_PATH) -> RefCounted:
	var key := "%d|%s|%d|%d" % [seed_v, path, FileAccess.get_file_as_string(path).hash(),
		FileAccess.get_file_as_string(TERRAIN_DATA).hash()]
	_cache_mutex.lock()
	var hit: Variant = _cache.get(key)
	_cache_mutex.unlock()
	if hit != null:
		return hit
	var made: RefCounted = (load("res://scripts/world/world_layout.gd") as GDScript).new(seed_v, terrain, path)
	_cache_mutex.lock()
	if not _cache.has(key):
		_cache[key] = made
	made = _cache[key]
	_cache_mutex.unlock()
	return made

# --- the API -----------------------------------------------------------------------------------

func sites() -> Dictionary:
	var b: Array[Vector2] = _batteries.duplicate()
	return {"radio_tower": _site, "aa_battery": b}

func village() -> Dictionary:
	return {
		"centre": _centre, "axis": _axis, "street": _street.duplicate(),
		"half_length_m": _ext_half_len, "half_width_m": _ext_half_wid, "polygon": _polygon.duplicate(),
		"compound": {"site": _site, "rot": _compound_rot, "reserve_radius_m": _comp_reserve, "fort_seed": _fort_seed},
		"house_slots": _slots.duplicate(true),
	}

func road() -> PackedVector2Array:
	return _road.duplicate()

func fields() -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for p in _fields:
		out.append(p.duplicate())
	return out

func field_info(i: int) -> Dictionary:
	return (_field_info[i] as Dictionary).duplicate()

func field_count() -> int:
	return _fields.size()

# The road's half width the layout keeps clear (metres), for the drawing side's clearance.
func road_clear_half_m() -> float:
	return _road_clear

# A string that changes when anything in the plan does (tests compare layouts with it).
func signature() -> String:
	var parts: Array[String] = ["%.3f,%.3f,%.5f" % [_centre.x, _centre.y, _axis], "%.3f,%.3f" % [_site.x, _site.y]]
	for b in _batteries:
		parts.append("%.3f,%.3f" % [b.x, b.y])
	parts.append(str(_road.size()))
	if _road.size() > 0:
		parts.append("%.3f,%.3f" % [_road[_road.size() / 2].x, _road[_road.size() / 2].y])
	for p in _fields:
		parts.append("%.3f,%.3f" % [p[0].x, p[0].y])
	for s: Dictionary in _slots:
		parts.append("%d" % int(s.seed))
	return "|".join(parts)

# Whether metre point p is inside the village polygon.
func in_village(p: Vector2) -> bool:
	return _polygon.size() >= 3 and Geometry2D.is_point_in_polygon(p, _polygon)

# --- reading data --------------------------------------------------------------------------------

func _read() -> void:
	var d := data
	_salt = d.integer("seed.salt")
	_grid_m = d.num("grid.step_m")
	_edge_margin = d.num("village.search.edge_margin_m")
	_search_step = d.num("village.search.step_m")
	_dist_band = d.floats("village.search.centre_distance_m")
	_clear_radius = d.num("village.search.clear_radius_m")
	_clear_margin = d.num("village.search.clear_margin")
	_relax_factor = d.num("village.search.relax_factor")
	_relax_steps = d.integer("village.search.relax_steps")
	_search_road_tries = d.integer("village.search.road_tries")
	_street_half = d.num("village.street.half_length_m")
	_street_jitter = d.num("village.street.jitter_rad")
	_edge_slack = d.num("village.street.edge_slack_m")
	_ext_half_len = d.num("village.extent.half_length_m")
	_ext_half_wid = d.num("village.extent.half_width_m")
	_ext_exp = d.num("village.extent.exponent")
	_ext_points = d.integer("village.extent.points")
	_ext_wobble = d.num("village.extent.wobble")
	_verify_step = d.num("village.extent.verify_step_m")
	_village_cliff = d.num("village.extent.cliff_clear_m")
	_comp_frac = d.num("compound.along_frac")
	_comp_offset = d.num("compound.offset_m")
	_comp_reserve = d.num("compound.reserve_radius_m")
	_comp_tilt = d.num("compound.tilt_rad")
	d.num("compound.fort_size_px")   # the village's (scripts/world/village.gd), read there
	_house_offset = d.num("houses.offset_m")
	_house_offset_jit = d.num("houses.offset_jitter_m")
	_house_spacing = d.num("houses.spacing_m")
	_house_spacing_jit = d.num("houses.spacing_jitter_m")
	_house_skip = d.num("houses.skip_chance")
	_house_end = d.num("houses.end_margin_m")
	_house_back_count = d.integer("houses.back_count")
	_house_back = d.floats("houses.back_offset_m")
	_house_rot_jit = d.num("houses.rot_jitter_rad")
	d.num("houses.min_gap_px")       # the village's
	_road_clear = d.num("road.clear_half_m")
	_road_margin = d.num("road.margin")
	_road_scales = d.floats("road.margin_scales")
	_road_cliff = d.num("road.cliff_clear_m")
	_road_upland = d.num("road.upland_weight")
	_road_wiggle = d.num("road.wiggle")
	_road_wiggle_f = d.num("road.wiggle_noise_per_cell")
	_road_goals = d.integer("road.goal_count")
	_road_goal_spread = d.num("road.goal_spread_m")
	_road_simplify = d.num("road.simplify_step_m")
	_road_smooth = d.integer("road.smooth_passes")
	_road_sample = d.num("road.sample_m")
	_road_wander = d.num("road.wander_m")
	_road_wander_wl = d.num("road.wander_wavelength_m")
	_road_beyond = d.num("road.beyond_edge_m")
	_f_count = d.integer("fields.count")
	_f_attempts = d.integer("fields.attempts")
	_f_ring = d.floats("fields.ring_m")
	_f_long = d.floats("fields.long_m")
	_f_ratio = d.floats("fields.ratio")
	_f_jitter = d.num("fields.corner_jitter")
	_f_gap = d.num("fields.gap_m")
	_f_village_gap = d.num("fields.village_gap_m")
	_f_road_gap = d.num("fields.road_gap_m")
	_f_cliff = d.num("fields.cliff_clear_m")
	_f_step = d.num("fields.sample_step_m")
	_f_kinds = d.integer("fields.kind_count")
	_f_turn = d.num("fields.turn_chance")
	_f_margin = d.num("fields.map_margin_m")
	_b_count = d.integer("batteries.count")
	_b_dist = d.floats("batteries.distance_m")
	_b_angle = d.floats("batteries.angle_apart_rad")
	_b_apart = d.num("batteries.apart_min_m")
	_b_open = d.num("batteries.open_radius_m")
	_b_cliff = d.num("batteries.cliff_clear_m")
	_b_village_gap = d.num("batteries.village_gap_m")
	_b_road_gap = d.num("batteries.road_gap_m")
	_b_field_gap = d.num("batteries.field_gap_m")
	_b_margin = d.num("batteries.map_margin_m")
	_b_attempts = d.integer("batteries.attempts")
	tree_gain_in_village = d.num("clearance.tree_gain_in_village")
	errors.append_array(d.errors)
	for pair in [[_dist_band, 2, "village.search.centre_distance_m"], [_house_back, 2, "houses.back_offset_m"],
			[_f_ring, 2, "fields.ring_m"], [_f_long, 2, "fields.long_m"], [_f_ratio, 2, "fields.ratio"],
			[_b_dist, 2, "batteries.distance_m"], [_b_angle, 2, "batteries.angle_apart_rad"]]:
		if (pair[0] as PackedFloat64Array).size() != pair[1]:
			errors.append("%s needs %d numbers" % [pair[2], pair[1]])

# A stream of the layout: hashed from the seed, the salt, the stream's name and up to two integers.
func _stream(name_salt: int, a: int = 0, b: int = 0) -> Mulberry32:
	return Mulberry32.new(_stream_seed(name_salt, a, b))

func _stream_seed(name_salt: int, a: int = 0, b: int = 0) -> int:
	return int(ValueNoise.hash2(a, b, (seed_value ^ (_salt * 7919) ^ (name_salt * 104729)) & 0x7FFFFFFF) * 2147483647.0)

# --- the coarse grid ------------------------------------------------------------------------------

func _grid() -> void:
	_gcols = int(floor(_map.size.x / _grid_m)) + 1
	_grows = int(floor(_map.size.y / _grid_m)) + 1
	_gf.resize(_gcols * _grows)
	for j in _grows:
		for i in _gcols:
			_gf[j * _gcols + i] = float(_t.field_at(_map.position.x + i * _grid_m, _map.position.y + j * _grid_m))

func _gp(i: int, j: int) -> Vector2:
	return Vector2(_map.position.x + i * _grid_m, _map.position.y + j * _grid_m)

# --- build ---------------------------------------------------------------------------------------

func _build() -> void:
	if not _pick_village():
		errors.append("no site for a village with a road to the edge: every candidate failed (searched %s)" % [diagnostics.get("search", [])])
		return
	_make_slots()
	_make_fields()
	_make_batteries()

# --- 1. the village -------------------------------------------------------------------------------

func _pick_village() -> bool:
	var centre := _map.get_center()
	var search_log: Array = []
	var radius := _clear_radius
	var best: Dictionary = {}
	var best_cross := 1 << 30
	var road_tries := 0
	for step in _relax_steps + 1:
		if step > 0:
			radius *= _relax_factor
		var banded := step < 2
		var cands: Array = []
		var y := _map.position.y + _edge_margin
		while y <= _map.end.y - _edge_margin + 0.001:
			var x := _map.position.x + _edge_margin
			while x <= _map.end.x - _edge_margin + 0.001:
				var p := Vector2(x, y)
				var dc := p.distance_to(centre)
				if (not banded or (dc >= _dist_band[0] and dc <= _dist_band[1])) and _clear_disc(p, radius):
					cands.append([ValueNoise.hash2(int(x), int(y), _stream_seed(S_VILLAGE)), p])
				x += _search_step
			y += _search_step
		cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
		var tried := 0
		for c: Array in cands:
			if road_tries >= _search_road_tries:
				break
			tried += 1
			for edge: int in _edge_order(c[1]):
				if not _try_village(c[1], edge) or not _route_road():
					continue
				road_tries += 1
				var crossings: int = int(diagnostics.get("road_crossings", 1 << 30))
				if crossings < best_cross:
					best_cross = crossings
					best = _snapshot()
				if crossings == 0 or road_tries >= _search_road_tries:
					break
			if best_cross == 0:
				break
		search_log.append({"step": step, "radius_m": radius, "banded": banded, "candidates": cands.size(), "tried": tried})
		if best_cross == 0 or road_tries >= _search_road_tries:
			break
	diagnostics["search"] = search_log
	diagnostics["road_tries"] = road_tries
	if best.is_empty():
		return false
	_restore(best)
	return true

# The plan so far, to put back after trying others.
func _snapshot() -> Dictionary:
	return {"centre": _centre, "axis": _axis, "street": _street, "polygon": _polygon, "site": _site,
		"rot": _compound_rot, "fort_seed": _fort_seed, "road": _road, "diag": diagnostics.duplicate(true)}

func _restore(s: Dictionary) -> void:
	_centre = s.centre
	_axis = s.axis
	_street = s.street
	_polygon = s.polygon
	_site = s.site
	_compound_rot = s.rot
	_fort_seed = s.fort_seed
	_road = s.road
	for k: String in s.diag:
		if k != "search" and k != "road_tries":
			diagnostics[k] = s.diag[k]

# The map edges a village at c may send its road to: the nearest and any not much further, in a
# seeded order.
func _edge_order(c: Vector2) -> Array[int]:
	var edges: Array = [
		[c.x - _map.position.x, 0], [_map.end.x - c.x, 1], [c.y - _map.position.y, 2], [_map.end.y - c.y, 3]]
	edges.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var allowed: Array = []
	for e: Array in edges:
		if e[0] <= edges[0][0] + _edge_slack:
			allowed.append([ValueNoise.hash2(e[1], int(c.x) + int(c.y) * 7919, _stream_seed(S_STREET)), e[1]])
	allowed.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var out: Array[int] = []
	for e: Array in allowed:
		out.append(int(e[1]))
	return out

# Whether every coarse sample within `radius` of p is low ground with the margin.
func _clear_disc(p: Vector2, radius: float) -> bool:
	var limit := _thr0 - _clear_margin
	var r := radius + _grid_m * 0.5
	var i0 := maxi(0, int(floor((p.x - r - _map.position.x) / _grid_m)))
	var i1 := mini(_gcols - 1, int(ceil((p.x + r - _map.position.x) / _grid_m)))
	var j0 := maxi(0, int(floor((p.y - r - _map.position.y) / _grid_m)))
	var j1 := mini(_grows - 1, int(ceil((p.y + r - _map.position.y) / _grid_m)))
	var r2 := r * r
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			if _gp(i, j).distance_squared_to(p) <= r2 and _gf[j * _gcols + i] >= limit:
				return false
	return true

# Builds the village round candidate c with its street facing map edge `edge` (street, polygon,
# compound) and checks it against the exact terrain; on success stores it.
func _try_village(c: Vector2, edge: int) -> bool:
	var rs := _stream(S_STREET, int(c.x), int(c.y))
	var foot: Vector2 = [Vector2(_map.position.x, c.y), Vector2(_map.end.x, c.y), Vector2(c.x, _map.position.y), Vector2(c.x, _map.end.y)][edge]
	var dir := (foot - c).normalized().rotated((rs.next() * 2.0 - 1.0) * _street_jitter)
	var axis := dir.angle()
	var perp := Vector2(-dir.y, dir.x)
	var street := PackedVector2Array([c - dir * _street_half, c, c + dir * _street_half])
	# the outline: a superellipse with a seeded radial wobble, in the village's frame
	var poly := PackedVector2Array()
	var ex := 2.0 / _ext_exp
	for k in _ext_points:
		var th := TAU * k / _ext_points
		var ct := cos(th)
		var st := sin(th)
		var wob := 1.0 + (ValueNoise.vnoise(k * 0.55, 3.1, _stream_seed(S_VILLAGE, 1)) * 2.0 - 1.0) * _ext_wobble
		var u := signf(ct) * pow(absf(ct), ex) * _ext_half_len * wob
		var v := signf(st) * pow(absf(st), ex) * _ext_half_wid * wob
		poly.append(c + dir * u + perp * v)
	# the exact check: low ground and clear of cliffs at samples across the polygon
	var rect := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	var checked := 0
	var y := rect.position.y
	while y <= rect.end.y:
		var x := rect.position.x
		while x <= rect.end.x:
			var q := Vector2(x, y)
			if Geometry2D.is_point_in_polygon(q, poly):
				checked += 1
				if int(_t.level_at(q.x, q.y)) != 0 or float(_t.boundary_distance(q.x, q.y, 0, _village_cliff)) < _village_cliff:
					return false
			x += _verify_step
		y += _verify_step
	# the compound's site, on a seeded side of the street
	var rc := _stream(S_COMPOUND, int(c.x), int(c.y))
	var side := -1.0 if rc.next() < 0.5 else 1.0
	var site := c + dir * (_comp_frac * _street_half) + perp * (side * _comp_offset)
	var tilt := (rc.next() * 2.0 - 1.0) * _comp_tilt
	if int(_t.level_at(site.x, site.y)) != 0 or not Geometry2D.is_point_in_polygon(site, poly):
		return false
	_centre = c
	_axis = axis
	_street = street
	_polygon = poly
	_site = site
	_compound_rot = axis + tilt
	_fort_seed = rc.next_seed()
	diagnostics["edge"] = edge
	diagnostics["village_samples_checked"] = checked
	return true

# --- 2. the road ---------------------------------------------------------------------------------

func _edge_point(edge: int, along: float) -> Vector2:
	match edge:
		0: return Vector2(_map.position.x, along)
		1: return Vector2(_map.end.x, along)
		2: return Vector2(along, _map.position.y)
	return Vector2(along, _map.end.y)

func _edge_normal(edge: int) -> Vector2:
	match edge:
		0: return Vector2(-1, 0)
		1: return Vector2(1, 0)
		2: return Vector2(0, -1)
	return Vector2(0, 1)

# Tries the road with the clearance margin scaled up until no point of it comes near a cliff (the
# margin is in field units: a bigger one keeps the route further from every scarp); the best
# attempt stands if none is clean, and diagnostics.road_crossings says how many of its points are
# on or near high ground.
func _route_road() -> bool:
	var best := PackedVector2Array()
	var best_cross := 1 << 30
	var attempts: Array = []
	for scale in _road_scales:
		var r: Dictionary = _route_with(scale)
		if r.is_empty():
			continue
		attempts.append({"scale": scale, "crossings": r.crossings, "wander": r.wander})
		if r.crossings < best_cross:
			best_cross = r.crossings
			best = r.road
			diagnostics["road_wander"] = r.wander
			diagnostics["road_margin_scale"] = scale
		if best_cross == 0:
			break
	diagnostics["road_attempts"] = attempts
	if best.is_empty():
		return false
	_road = best
	diagnostics["road_crossings"] = best_cross
	diagnostics["road_length_m"] = _polyline_length(_road)
	diagnostics["road_points"] = _road.size()
	diagnostics["road_edge"] = int(diagnostics.get("edge", 1))
	return true

# One road for the margin scale `scale`: {road, crossings, wander}, or {} when there is no route.
func _route_with(scale: float) -> Dictionary:
	var edge: int = int(diagnostics.get("edge", 1))
	var front := _street[2]
	var limit := _thr0 - _road_margin * scale
	var wn_seed := _stream_seed(S_ROAD, 1)
	# the grid, weighted
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, _gcols, _grows)
	astar.cell_size = Vector2(_grid_m, _grid_m)
	astar.offset = _map.position
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ALWAYS
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	astar.update()
	var weight := PackedFloat64Array()
	weight.resize(_gcols * _grows)
	for j in _grows:
		for i in _gcols:
			var w := 1.0 + _road_wiggle * ValueNoise.vnoise(i * _road_wiggle_f, j * _road_wiggle_f, wn_seed)
			if _gf[j * _gcols + i] >= limit:
				w *= _road_upland
			weight[j * _gcols + i] = w
			astar.set_point_weight_scale(Vector2i(i, j), w)
	var start := Vector2i(clampi(roundi((front.x - _map.position.x) / _grid_m), 0, _gcols - 1),
		clampi(roundi((front.y - _map.position.y) / _grid_m), 0, _grows - 1))
	# goals along the chosen edge, around the point the street faces
	var foot_along := front.y if edge < 2 else front.x
	var best_path: Array[Vector2i] = []
	var best_cost := INF
	for g in _road_goals:
		var off := 0.0 if _road_goals == 1 else (float(g) / float(_road_goals - 1) * 2.0 - 1.0) * _road_goal_spread
		var gp := _edge_point(edge, foot_along + off)
		var goal := Vector2i(clampi(roundi((gp.x - _map.position.x) / _grid_m), 0, _gcols - 1),
			clampi(roundi((gp.y - _map.position.y) / _grid_m), 0, _grows - 1))
		var path: Array[Vector2i] = astar.get_id_path(start, goal)
		if path.size() < 2:
			continue
		var cost := 0.0
		for k in range(1, path.size()):
			cost += Vector2(path[k] - path[k - 1]).length() * weight[path[k].y * _gcols + path[k].x]
		if cost < best_cost:
			best_cost = cost
			best_path = path
	if best_path.is_empty():
		return {}
	var route: Array[Vector2] = [front]
	for k in range(1, best_path.size()):
		route.append(_gp(best_path[k].x, best_path[k].y))
	# straighten: from each vertex reach as far as a straight line stays on clear ground
	var simple: Array[Vector2] = [route[0]]
	var i0 := 0
	while i0 < route.size() - 1:
		var j := i0 + 1
		while j + 1 < route.size() and _line_clear(route[i0], route[j + 1], limit):
			j += 1
		simple.append(route[j])
		i0 = j
	# the end: carry it past the edge
	var last: Vector2 = simple[simple.size() - 1]
	simple.append(last + _edge_normal(edge) * _road_beyond)
	# the whole road: the street, then the route; rounded and resampled
	var flat := PackedFloat64Array([_street[0].x, _street[0].y, _street[1].x, _street[1].y])
	for p in simple:
		flat.append(p.x)
		flat.append(p.y)
	var smooth := flat
	for _k in _road_smooth:
		smooth = Geometry.chaikin_f64(smooth, false)
	var even := Geometry.resample_f64(smooth, _road_sample, false)
	# a long, slow drift off the straight, nothing within the village's street; dropped if it
	# would put the road nearer a cliff than the plain road is
	var drift := _drift(even)
	var wander := _count_near_cliffs(drift) <= _count_near_cliffs(even)
	if not wander:
		drift = even
	var out := PackedVector2Array()
	for k in drift.size() / 2:
		out.append(Vector2(drift[k * 2], drift[k * 2 + 1]))
	return {"road": out, "crossings": _count_near_cliffs(drift), "wander": wander}

# How many points of a (flat pairs) polyline, inside the map, are on high ground or within the
# road's cliff clearance of a height boundary: the exact terrain's answer.
func _count_near_cliffs(flat: PackedFloat64Array) -> int:
	var n := 0
	for k in flat.size() / 2:
		var p := Vector2(flat[k * 2], flat[k * 2 + 1])
		if _map.has_point(p) and (int(_t.level_at(p.x, p.y)) != 0 or float(_t.boundary_distance(p.x, p.y, 0, _road_cliff)) < _road_cliff):
			n += 1
	return n

func _line_clear(a: Vector2, b: Vector2, limit: float) -> bool:
	var n := maxi(1, int(ceil(a.distance_to(b) / _road_simplify)))
	for k in range(1, n + 1):
		var p := a.lerp(b, float(k) / n)
		if float(_t.field_at(p.x, p.y)) >= limit:
			return false
	return true

# Lateral drift along a resampled polyline (flat pairs): an offset along the local normal that
# grows from nothing over the street's length.
func _drift(flat: PackedFloat64Array) -> PackedFloat64Array:
	if _road_wander <= 0.0:
		return flat
	var out := PackedFloat64Array()
	var n := flat.size() / 2
	var s := 0.0
	var seed_n := _stream_seed(S_ROAD, 2)
	var street_len := _street_half * 2.0
	for k in n:
		var a := Vector2(flat[maxi(k - 1, 0) * 2], flat[maxi(k - 1, 0) * 2 + 1])
		var b := Vector2(flat[mini(k + 1, n - 1) * 2], flat[mini(k + 1, n - 1) * 2 + 1])
		var tg := b - a
		var nrm := Vector2(-tg.y, tg.x).normalized() if tg.length() > 0.0 else Vector2.ZERO
		if k > 0:
			s += Vector2(flat[k * 2] - flat[k * 2 - 2], flat[k * 2 + 1] - flat[k * 2 - 1]).length()
		var taper := clampf((s - street_len) / 120.0, 0.0, 1.0)
		# the road's end (past the map edge) is left alone so it still meets it
		var w := (ValueNoise.vnoise(s / _road_wander_wl, 7.7, seed_n) * 2.0 - 1.0) * _road_wander * taper
		var p := Vector2(flat[k * 2], flat[k * 2 + 1]) + nrm * w
		out.append(p.x)
		out.append(p.y)
	return out

static func _polyline_length(p: PackedVector2Array) -> float:
	var l := 0.0
	for k in range(1, p.size()):
		l += p[k].distance_to(p[k - 1])
	return l

# Distance from p to the road's polyline (INF when there is none).
func _road_dist(p: Vector2) -> float:
	var best := INF
	for k in range(1, _road.size()):
		best = minf(best, _seg_dist(p, _road[k - 1], _road[k]))
	return best

static func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)

# --- 3. houses -------------------------------------------------------------------------------------

func _make_slots() -> void:
	var rh := _stream(S_HOUSES, int(_centre.x), int(_centre.y))
	var dir := Vector2.from_angle(_axis)
	var perp := Vector2(-dir.y, dir.x)
	_slots.clear()
	for side in [-1.0, 1.0]:
		var u := -_street_half + _house_end + rh.next() * _house_spacing_jit
		while u <= _street_half - _house_end:
			var v: float = side * (_house_offset + (rh.next() * 2.0 - 1.0) * _house_offset_jit)
			var skip := rh.next() < _house_skip
			var pos := _centre + dir * u + perp * v
			var rot := _axis + (0.0 if side < 0.0 else PI) + (rh.next() * 2.0 - 1.0) * _house_rot_jit
			var sd := rh.next_seed()
			if not skip and pos.distance_to(_site) > _comp_reserve and int(_t.level_at(pos.x, pos.y)) == 0:
				_slots.append({"pos": pos, "rot": rot, "seed": sd, "row": "front"})
			u += _house_spacing + (rh.next() * 2.0 - 1.0) * _house_spacing_jit
	var placed := 0
	var tries := 0
	while placed < _house_back_count and tries < 200:
		tries += 1
		var u := (rh.next() * 2.0 - 1.0) * (_street_half - _house_end)
		var side := -1.0 if rh.next() < 0.5 else 1.0
		var v: float = side * (_house_back[0] + rh.next() * (_house_back[1] - _house_back[0]))
		var pos := _centre + dir * u + perp * v
		var rot := _axis + (0.0 if side < 0.0 else PI) + (rh.next() * 2.0 - 1.0) * _house_rot_jit * 3.0
		var sd := rh.next_seed()
		if pos.distance_to(_site) <= _comp_reserve or not Geometry2D.is_point_in_polygon(pos, _polygon):
			continue
		var clear := true
		for s: Dictionary in _slots:
			if (s.pos as Vector2).distance_to(pos) < _house_spacing * 0.75:
				clear = false
		if clear and int(_t.level_at(pos.x, pos.y)) == 0:
			_slots.append({"pos": pos, "rot": rot, "seed": sd, "row": "back"})
			placed += 1

# --- 4. fields -------------------------------------------------------------------------------------

func _make_fields() -> void:
	var rf := _stream(S_FIELDS, int(_centre.x), int(_centre.y))
	var fixed := Geometry2D.offset_polygon(_polygon, _f_village_gap, Geometry2D.JOIN_ROUND)
	var village_grown: PackedVector2Array = fixed[0] if fixed.size() > 0 else _polygon
	_fields.clear()
	_field_info.clear()
	var grown: Array = []   # each accepted field grown by the gap, for the overlap test
	var attempts := 0
	while _fields.size() < _f_count and attempts < _f_attempts:
		attempts += 1
		var rho := sqrt(lerpf(_f_ring[0] * _f_ring[0], _f_ring[1] * _f_ring[1], rf.next()))
		var th := rf.next() * TAU
		var centre := _centre + Vector2.from_angle(th) * rho
		var long_m := lerpf(_f_long[0], _f_long[1], rf.next())
		var short_m := long_m * lerpf(_f_ratio[0], _f_ratio[1], rf.next())
		var rot := _axis + (0.0 if rf.next() < 0.5 else PI * 0.5) + (rf.next() * 2.0 - 1.0) * 0.15
		var jit := _f_jitter * short_m
		var poly := PackedVector2Array()
		for kq: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var corner := Vector2(kq.x * long_m * 0.5, kq.y * short_m * 0.5)
			corner += Vector2((rf.next() * 2.0 - 1.0) * jit, (rf.next() * 2.0 - 1.0) * jit)
			poly.append(centre + corner.rotated(rot))
		var turn := rf.next() < _f_turn
		var kind := mini(int(rf.next() * _f_kinds), _f_kinds - 1)
		var fseed := rf.next_seed()
		if not _field_ok(poly, village_grown, grown):
			continue
		_fields.append(poly)
		# crop rows run along the long side, or across it
		_field_info.append({"angle": rot + (PI * 0.5 if turn else 0.0), "kind": kind, "seed": fseed})
		var g := Geometry2D.offset_polygon(poly, _f_gap, Geometry2D.JOIN_MITER)
		grown.append(g[0] if g.size() > 0 else poly)
	diagnostics["field_attempts"] = attempts

func _field_ok(poly: PackedVector2Array, village_grown: PackedVector2Array, grown: Array) -> bool:
	# convex (a counter- or clockwise turn throughout)
	var sign_seen := 0.0
	for k in 4:
		var a := poly[k]
		var b := poly[(k + 1) % 4]
		var c := poly[(k + 2) % 4]
		var cr := (b - a).cross(c - b)
		if sign_seen == 0.0:
			sign_seen = signf(cr)
		elif signf(cr) != sign_seen or cr == 0.0:
			return false
	var inner := _map.grow(-_f_margin)
	for p in poly:
		if not inner.has_point(p):
			return false
	if not Geometry2D.intersect_polygons(poly, village_grown).is_empty():
		return false
	if _site.distance_to(_nearest_on_polygon(poly, _site)) < _comp_reserve:
		return false
	for g: PackedVector2Array in grown:
		if not Geometry2D.intersect_polygons(poly, g).is_empty():
			return false
	# keep off the road (its clearance plus the gap): the road's points inside the grown polygon,
	# and the polygon's own edge points near the road
	var wide := Geometry2D.offset_polygon(poly, _road_clear + _f_road_gap, Geometry2D.JOIN_MITER)
	if wide.size() > 0:
		for p in _road:
			if Geometry2D.is_point_in_polygon(p, wide[0]):
				return false
	# the exact terrain: corners, edge midpoints and a lattice inside
	var pts: Array[Vector2] = []
	for k in 4:
		pts.append(poly[k])
		pts.append((poly[k] + poly[(k + 1) % 4]) * 0.5)
	var rect := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	var y := rect.position.y + _f_step * 0.5
	while y < rect.end.y:
		var x := rect.position.x + _f_step * 0.5
		while x < rect.end.x:
			if Geometry2D.is_point_in_polygon(Vector2(x, y), poly):
				pts.append(Vector2(x, y))
			x += _f_step
		y += _f_step
	for p in pts:
		if int(_t.level_at(p.x, p.y)) != 0 or float(_t.boundary_distance(p.x, p.y, 0, _f_cliff)) < _f_cliff:
			return false
	return true

# The point of polygon `poly` nearest to p (for a distance to its outline).
static func _nearest_on_polygon(poly: PackedVector2Array, p: Vector2) -> Vector2:
	if Geometry2D.is_point_in_polygon(p, poly):
		return p
	var best := poly[0]
	var best_d := INF
	for k in poly.size():
		var a := poly[k]
		var b := poly[(k + 1) % poly.size()]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_to(q)
		if d < best_d:
			best_d = d
			best = q
	return best

# --- 5. batteries ----------------------------------------------------------------------------------

func _make_batteries() -> void:
	var rb := _stream(S_BATTERY, int(_site.x), int(_site.y))
	var vgrown: PackedVector2Array = _polygon
	var vg := Geometry2D.offset_polygon(_polygon, _b_village_gap, Geometry2D.JOIN_ROUND)
	if vg.size() > 0:
		vgrown = vg[0]
	var fgrown: Array = []
	for f in _fields:
		var g := Geometry2D.offset_polygon(f, _b_field_gap, Geometry2D.JOIN_MITER)
		fgrown.append(g[0] if g.size() > 0 else f)
	_batteries.clear()
	var first_angle := rb.next() * TAU
	for b in _b_count:
		var found := false
		for widen in 3:
			var dmin := _b_dist[0] * (1.0 - 0.25 * widen)
			var dmax := _b_dist[1] * (1.0 + 0.25 * widen)
			var tries := 0
			while tries < _b_attempts and not found:
				tries += 1
				var ang: float
				if b == 0:
					ang = first_angle + (rb.next() * 2.0 - 1.0) * 0.5
				else:
					ang = first_angle + lerpf(_b_angle[0], _b_angle[1], rb.next()) * (1.0 if b % 2 == 1 else -1.0) * 1.0
				var p := _site + Vector2.from_angle(ang) * lerpf(dmin, dmax, rb.next())
				if _battery_ok(p, vgrown, fgrown):
					found = true
					_batteries.append(p)
			if found:
				break
		if not found:
			errors.append("no site for anti-aircraft battery %d" % b)

func _battery_ok(p: Vector2, vgrown: PackedVector2Array, fgrown: Array) -> bool:
	if not _map.grow(-_b_margin).has_point(p):
		return false
	for other in _batteries:
		if other.distance_to(p) < _b_apart:
			return false
	if Geometry2D.is_point_in_polygon(p, vgrown) or _road_dist(p) < _b_road_gap:
		return false
	for g: PackedVector2Array in fgrown:
		if Geometry2D.is_point_in_polygon(p, g):
			return false
	if int(_t.level_at(p.x, p.y)) != 0 or float(_t.boundary_distance(p.x, p.y, 0, _b_cliff)) < _b_cliff:
		return false
	for k in 4:
		var q := p + Vector2.from_angle(k * PI * 0.5) * _b_open
		if int(_t.level_at(q.x, q.y)) != 0:
			return false
	return true
