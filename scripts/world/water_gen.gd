extends RefCounted

# THE WATER GENERATOR (Track WB, 2026-10-10) -- a PROTOTYPE for the board variants/water/. Pure and
# deterministic: a function of (seed, data/world/water.json, the terrain's height field and the
# world layout), nothing else, so every machine sees the same sea and the same river. NOT wired into
# the chunk baker or the terrain provider (Track P is changing those): the board draws it on its own.
#
#   const WaterGen = preload("res://scripts/world/water_gen.gd")
#   var water := WaterGen.new(20261009)                   # makes its own Terrain and layout
#   var water := WaterGen.new(20261009, terrain)          # ... or uses a Terrain of this seed
#   water.s_at(x, y)        metres of water over the seabed at a metre point (> 0 wet, <= 0 dry)
#   water.step_at(x, y)     -1 dry, 0 shallows, 1 shelf, 2 deep -- WATER ONLY: it does not know the
#                           uplands (see is_wet)
#   water.is_wet(x, y)      water at (x, y): s > 0 AND the terrain there is level 0 (an upland is
#                           never water: where the sea meets one it is a coastal cliff, out in the
#                           sea an islet). The one answer trees, houses and the drawing use.
#   water.sea_rings(rect, k) / water.river_runs(rect, k)     the drawing's geometry (see below)
#   water.ok() / errors / diagnostics / signature()
#
# THE SAME HEIGHT SYSTEM (Alex). The land's levels are cut from the terrain's height field at
# thresholds; the sea is a signed field `s` in metres of depth cut at 0 / 6 / 18 m into three steps
# (shallows, shelf, deep; seabed heights -3 / -10 / -30 m). The water SURFACE is flat at sea level, so
# every shadow lands on it as on level 0 land (scripts/render/terrain_shadows.gd needs no change); the
# steps are the wash beneath.
#
# HOW IT IS MADE
#  1. THE SEA. Landness L(x, y) = base + w_n (noise - 0.5) + w_t (terrain field - 0.5) - strength x
#     bias. The noise is a large-scale fbm (a lattice every 1,250 m), the terrain field is the very
#     field the land's levels are cut from (so the coast follows the same bays and spurs and the
#     relief is one relief), and `bias` is 1 at a SEA EDGE and falls linearly to 0 `reach` metres in:
#     the map is part of an island with a coast on one or two of its edges. The sea is where L < 0;
#     its depth is s = -L x depth_per_unit_m. The sea edges are picked by seed from the edges the
#     village's road does NOT leave by (a road into the sea would need a harbour).
#  2. THE KEEP-DRY SET. From the world layout: the village's outline, the fields, the radio tower
#     (its compound), the two anti-aircraft battery sites and the road (but for the crossing). If a
#     sea would flood any of them its reach is shrunk (adapt_shrink), then the offending edge is
#     dropped; a seed whose layout leaves no room has no sea. diagnostics.sea says what happened and
#     whether the FIRST choice (no adapting) was already dry: the survey's number.
#  3. THE RIVER. It crosses the road at a point `crossing.min_m` to `max_m` from the village, square
#     across it (routed through two waypoints along the road's normal), from a spring at the foot of
#     high ground (low ground just beside an upland) down to the sea. The routing is weighted A* on a
#     40 m grid that avoids the keep-dry set, climbs no scarp and prefers low ground; the route is
#     rounded (Chaikin), resampled, given meanders (none at the crossing or the spring) and a width
#     and centre depth that grow from spring to mouth. The section is a parabola, so a brook is
#     shallows all through and the lower river has a shelf in its middle. If the river would flood the
#     keep-dry set another crossing is tried; if none works the seed has no river that crosses the
#     road (diagnostics.river says why).
#
# THE DRAWING'S GEOMETRY
#   sea_rings(rect, k)    the closed rings (marching squares on an 8 m grid, Chaikin, resampled) of the
#                         sea where depth >= step k's start: [{pts: PackedVector2Array (metres), area}],
#                         outer rings positive (clockwise on screen), holes negative
#   river_runs(rect, k)   the river as ribbons: the stretches of the course in rect (grown) where step
#                         k exists, [{c: PackedVector2Array centre, h: PackedFloat64Array half widths}];
#                         k = 0 is the whole channel, k = 1 and 2 the inner parabola where it is deeper
#                         than the step (the shelf, the deep)
# A river is NOT on the contour grid: a brook of 5 m does not fit an 8 m grid.
#
# EVERY NUMBER IS DATA (data/world/water.json, all proposed but the three depths).

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/render/fast_noise.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const TerrainData = preload("res://scripts/world/terrain_data.gd")
const WaterContour = preload("res://scripts/world/water_contour.gd")

const DEFAULT_PATH := "res://data/world/water.json"
const TERRAIN_SCRIPT := "res://scripts/world/terrain.gd"

# Salts for the water's streams (code constants, not tunables).
const S_EDGES := 1
const S_COUNT := 2
const S_CROSS := 3
const S_ROUTE := 4
const S_SOURCE := 5
const S_MEANDER := 6
const S_JITTER := 7

# s returned where no river is near (far under any depth).
const DRY := -1000.0
const BUCKET_M := 64.0

var seed_value: int
var data: TerrainData
var errors: Array[String] = []
var diagnostics: Dictionary = {}

# --- the sea -------------------------------------------------------------------------------------
var sea_edges: Array[int] = []            # 0 west, 1 east, 2 north, 3 south (the layout's numbering)
var sea_reach := PackedFloat64Array()     # metres, per entry of sea_edges
var step_from := PackedFloat64Array()     # depth at which each step begins, metres
var heights_m := PackedFloat64Array()     # the seabed height of each step, metres (negative)
var step_names: Array[String] = []

# --- the river -----------------------------------------------------------------------------------
var river_pts := PackedVector2Array()     # the course, spring to mouth, metres
var river_hw := PackedFloat64Array()      # half width at each point
var river_dmax := PackedFloat64Array()    # centre depth at each point
var river_t := PackedFloat64Array()       # fraction of the course
var river_length := 0.0
var river_crossing := Vector2(INF, INF)   # where it crosses the road (INF: it does not)
var river_source := Vector2(INF, INF)
var river_mouth := Vector2(INF, INF)

# --- values read from data -------------------------------------------------------------------------
var _salt: int
var _sea_np: float
var _sea_oct: int
var _sea_wn: float
var _sea_wt: float
var _sea_base: float
var _sea_strength: float
var _sea_reach_m: float
var _sea_reach_jit: float
var _sea_counts := PackedFloat64Array()
var _sea_dpu: float
var _sea_seed: int
var _sea_shrink: float
var _sea_adapt: int
var _river_on: bool
var _x_min: float
var _x_max: float
var _x_margin: float
var _x_cliff: float
var _x_batt: float
var _x_wp: float
var _x_exempt: float
var _x_gap_max: float
var _x_len_max: float
var _x_len_good: float
var _sh_wref: float
var _x_tries: int
var _r_step: float
var _r_upland: float
var _r_low: float
var _r_wiggle: float
var _r_wiggle_f: float
var _r_vgap: float
var _r_fgap: float
var _r_cgap: float
var _r_bgap: float
var _r_rcorr: float
var _r_rw: float
var _s_min: float
var _s_max: float
var _s_band := PackedFloat64Array()
var _s_cands: int
var _m_depth: float
var _m_extend: float
var _m_goals: int
var _sh_smooth: int
var _sh_sample: float
var _sh_meander := PackedFloat64Array()
var _sh_wl: float
var _sh_taper: float
var _sh_staper: float
var _sh_hw := PackedFloat64Array()
var _sh_hwp: float
var _sh_hwx: float
var _sh_dm := PackedFloat64Array()
var _sh_dmp: float
var _kd_village: float
var _kd_field: float
var _kd_tower: float
var _kd_batt: float
var _kd_sample: float
var _kd_road: float
var _cell_m: float
var _chaikin: int
var _resample: float

# --- terrain facts ---------------------------------------------------------------------------------
var _t: Variant = null          # the Terrain (kept: field_at and level_at are the water's eyes)
var _lay: Variant = null        # the WorldLayout
var _map := Rect2()
var _thr0: float

# --- the keep-dry set --------------------------------------------------------------------------------
var _kd_pts := PackedVector2Array()
var _kd_road_t := PackedByteArray()      # 1 where the point is a road sample (exempt near the crossing)
var _kd_kind: Array[String] = []

var _rbuckets: Dictionary = {}           # Vector2i -> PackedInt32Array of segment indices
var _grid_cache: Dictionary = {}

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
	if not errors.is_empty():
		return
	if not _t.ok():
		errors.append("the terrain does not build: %s %s" % [_t.errors, _t.data.errors])
		return
	_lay = _t.layout()
	if not (_lay as RefCounted).ok():
		errors.append("the world layout does not build: %s" % [(_lay as RefCounted).errors])
		return
	_map = Rect2(float(_t.map_x), float(_t.map_y), float(_t.map_w), float(_t.map_h))
	_thr0 = float(_t.thresholds[0])
	_build_keep_dry()
	_build_sea()
	if _river_on:
		_build_river()
	else:
		diagnostics["river"] = {"made": false, "why": "disabled in data"}
	diagnostics["build_ms"] = (Time.get_ticks_usec() - t0) / 1000.0
	var all_dry := _dry_check(river_crossing, _x_exempt)
	diagnostics["keep_dry_ok"] = all_dry["ok"]
	diagnostics["keep_dry_samples"] = _kd_pts.size()
	if not all_dry["ok"]:
		errors.append("the sea or the river floods the layout's keep-dry set at %s (%s)" % [all_dry["at"], all_dry["kind"]])

func ok() -> bool:
	return errors.is_empty() and data.ok()

# --- reading data ----------------------------------------------------------------------------------

func _read() -> void:
	var d := data
	_salt = d.integer("seed.salt")
	_sea_np = d.num("sea.noise_per_m")
	_sea_oct = d.integer("sea.octaves")
	_sea_wn = d.num("sea.noise_weight")
	_sea_wt = d.num("sea.terrain_weight")
	_sea_base = d.num("sea.base_land")
	_sea_strength = d.num("sea.strength")
	_sea_reach_m = d.num("sea.reach_m")
	_sea_reach_jit = d.num("sea.reach_jitter")
	_sea_counts = d.floats("sea.edge_count")
	_sea_dpu = d.num("sea.depth_per_unit_m")
	_sea_seed = seed_value % 9973 + d.integer("sea.seed_offset")
	_sea_shrink = d.num("sea.adapt_shrink")
	_sea_adapt = d.integer("sea.adapt_steps")
	step_from = d.floats("levels.step_from_m")
	heights_m = d.floats("levels.heights_m")
	for n: Variant in d.list("levels.names"):
		step_names.append(str(n))
	_river_on = bool(d.value("river.enabled"))
	_x_min = d.num("river.crossing.min_m")
	_x_max = d.num("river.crossing.max_m")
	_x_margin = d.num("river.crossing.map_margin_m")
	_x_cliff = d.num("river.crossing.cliff_clear_m")
	_x_batt = d.num("river.crossing.battery_gap_m")
	_x_wp = d.num("river.crossing.waypoint_m")
	_x_exempt = d.num("river.crossing.exempt_m")
	_x_gap_max = d.num("river.crossing.gap_max_m")
	_x_len_max = d.num("river.crossing.length_max_m")
	_x_len_good = d.num("river.crossing.length_good_m")
	_x_tries = d.integer("river.crossing.tries")
	_r_step = d.num("river.route.step_m")
	_r_upland = d.num("river.route.upland_weight")
	_r_low = d.num("river.route.low_weight")
	_r_wiggle = d.num("river.route.wiggle")
	_r_wiggle_f = d.num("river.route.wiggle_noise_per_cell")
	_r_vgap = d.num("river.route.village_gap_m")
	_r_fgap = d.num("river.route.field_gap_m")
	_r_cgap = d.num("river.route.compound_gap_m")
	_r_bgap = d.num("river.route.battery_gap_m")
	_r_rcorr = d.num("river.route.road_corridor_m")
	_r_rw = d.num("river.route.road_weight")
	_s_min = d.num("river.source.min_m")
	_s_max = d.num("river.source.max_m")
	_s_band = d.floats("river.source.foot_band")
	_s_cands = d.integer("river.source.candidates")
	_m_depth = d.num("river.mouth.depth_m")
	_m_extend = d.num("river.mouth.extend_m")
	_m_goals = d.integer("river.mouth.goals")
	_sh_smooth = d.integer("river.shape.smooth_passes")
	_sh_sample = d.num("river.shape.sample_m")
	_sh_meander = d.floats("river.shape.meander_m")
	_sh_wl = d.num("river.shape.meander_wavelength_m")
	_sh_taper = d.num("river.shape.meander_taper_m")
	_sh_staper = d.num("river.shape.source_taper_m")
	_sh_hw = d.floats("river.shape.half_width_m")
	_sh_hwp = d.num("river.shape.half_width_power")
	_sh_hwx = d.num("river.shape.crossing_half_width_m")
	_sh_dm = d.floats("river.shape.centre_depth_m")
	_sh_dmp = d.num("river.shape.centre_depth_power")
	_kd_village = d.num("keep_dry.village_margin_m")
	_kd_field = d.num("keep_dry.field_margin_m")
	_kd_tower = d.num("keep_dry.tower_ring_m")
	_kd_batt = d.num("keep_dry.battery_ring_m")
	_kd_sample = d.num("keep_dry.sample_m")
	_kd_road = d.num("keep_dry.road_sample_m")
	_cell_m = d.num("draw.grid_cell_m")
	_chaikin = d.integer("draw.chaikin_passes")
	_resample = d.num("draw.resample_m")
	errors.append_array(d.errors)
	for pair in [[_sea_counts, 2, "sea.edge_count"], [step_from, 3, "levels.step_from_m"], [heights_m, 3, "levels.heights_m"],
			[_s_band, 2, "river.source.foot_band"], [_sh_meander, 2, "river.shape.meander_m"], [_sh_hw, 2, "river.shape.half_width_m"],
			[_sh_dm, 2, "river.shape.centre_depth_m"]]:
		if (pair[0] as PackedFloat64Array).size() != pair[1]:
			errors.append("%s needs %d numbers" % [pair[2], pair[1]])
	if step_names.size() != 3:
		errors.append("levels.names needs 3 names")

# A stream of the water: hashed from the seed, the salt, the stream's name and up to two integers.
func _stream_seed(name_salt: int, a: int = 0, b: int = 0) -> int:
	return int(ValueNoise.hash2(a, b, (seed_value ^ (_salt * 7919) ^ (name_salt * 104729)) & 0x7FFFFFFF) * 2147483647.0)

func _stream(name_salt: int, a: int = 0, b: int = 0) -> Mulberry32:
	return Mulberry32.new(_stream_seed(name_salt, a, b))

# --- the fields ---------------------------------------------------------------------------------------

func _edge_dist(edge: int, x: float, y: float) -> float:
	match edge:
		0: return x - _map.position.x
		1: return _map.end.x - x
		2: return y - _map.position.y
	return _map.end.y - y

func _bias(x: float, y: float) -> float:
	var b := 0.0
	for k in sea_edges.size():
		b = maxf(b, clampf(1.0 - _edge_dist(sea_edges[k], x, y) / sea_reach[k], 0.0, 1.0))
	return b

# Landness: above zero is land, below is sea.
func landness(x: float, y: float) -> float:
	var cn := ValueNoise.fbm(x * _sea_np, y * _sea_np, _sea_seed, _sea_oct)
	var f: float = _t.field_at(x, y)
	return _sea_base + _sea_wn * (cn - 0.5) + _sea_wt * (f - 0.5) - _sea_strength * _bias(x, y)

# The sea's s: metres of water (> 0) or minus the land's elevation proxy.
func sea_s(x: float, y: float) -> float:
	return -landness(x, y) * _sea_dpu

# The river's s at a point: the deepest of the channels near it (the parabola of the section), DRY far from it.
func river_s(x: float, y: float) -> float:
	if river_pts.size() < 2:
		return DRY
	var cell: Variant = _rbuckets.get(Vector2i(floori(x / BUCKET_M), floori(y / BUCKET_M)))
	if cell == null:
		return DRY
	var best := DRY
	var p := Vector2(x, y)
	for si: int in (cell as PackedInt32Array):
		var a := river_pts[si]
		var b := river_pts[si + 1]
		var ab := b - a
		var l2 := ab.length_squared()
		var u := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		var d := p.distance_to(a + ab * u)
		var hw := lerpf(river_hw[si], river_hw[si + 1], u)
		if d < hw and hw > 0.0:
			var q := d / hw
			best = maxf(best, lerpf(river_dmax[si], river_dmax[si + 1], u) * (1.0 - q * q))
	return best

func s_at(x: float, y: float) -> float:
	return maxf(sea_s(x, y), river_s(x, y))

# The depth step of a point of WATER (s > 0): 0 shallows, 1 shelf, 2 deep; -1 when dry. The uplands are not
# considered: is_wet() is the answer for a place.
func step_of(s: float) -> int:
	if s <= 0.0:
		return -1
	var k := 0
	for q in range(1, step_from.size()):
		if s >= step_from[q]:
			k = q
	return k

func step_at(x: float, y: float) -> int:
	return step_of(s_at(x, y))

func is_wet(x: float, y: float) -> bool:
	return s_at(x, y) > 0.0 and int(_t.level_at(x, y)) == 0

func terrain() -> Variant:
	return _t

func layout() -> Variant:
	return _lay

func map_rect() -> Rect2:
	return _map

# --- the keep-dry set ------------------------------------------------------------------------------------

func _build_keep_dry() -> void:
	_kd_pts = PackedVector2Array()
	_kd_road_t = PackedByteArray()
	_kd_kind = []
	var v: Dictionary = _lay.village()
	var poly: PackedVector2Array = v.polygon
	var grown := _grow(poly, _kd_village)
	_sample_poly(grown, "village")
	for p in grown:
		_kd_add(p, "village")
	for f: PackedVector2Array in _lay.fields():
		var g := _grow(f, _kd_field)
		_sample_poly(g, "field")
		for p in g:
			_kd_add(p, "field")
	var site: Vector2 = _lay.sites().radio_tower
	_kd_ring(site, _kd_tower, "tower")
	for b: Vector2 in _lay.sites().aa_battery:
		_kd_ring(b, _kd_batt, "battery")
	var road: PackedVector2Array = _lay.road()
	var acc := 0.0
	for i in road.size():
		if i > 0:
			acc += road[i].distance_to(road[i - 1])
		if (i == 0 or acc >= _kd_road) and _map.grow(-1.0).has_point(road[i]):
			acc = 0.0
			_kd_add(road[i], "road", true)

func _grow(poly: PackedVector2Array, by: float) -> PackedVector2Array:
	var g := Geometry2D.offset_polygon(poly, by, Geometry2D.JOIN_ROUND)
	return g[0] if g.size() > 0 else poly

func _kd_add(p: Vector2, kind: String, is_road: bool = false) -> void:
	_kd_pts.append(p)
	_kd_road_t.append(1 if is_road else 0)
	_kd_kind.append(kind)

func _sample_poly(poly: PackedVector2Array, kind: String) -> void:
	var rect := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	var y := rect.position.y + _kd_sample * 0.5
	while y < rect.end.y:
		var x := rect.position.x + _kd_sample * 0.5
		while x < rect.end.x:
			if Geometry2D.is_point_in_polygon(Vector2(x, y), poly):
				_kd_add(Vector2(x, y), kind)
			x += _kd_sample
		y += _kd_sample

func _kd_ring(c: Vector2, r: float, kind: String) -> void:
	_kd_add(c, kind)
	for k in 8:
		_kd_add(c + Vector2.from_angle(float(k) * TAU / 8.0) * r, kind)

# Whether every point of the keep-dry set is dry (s <= 0), the road within `exempt` of `crossing` excepted.
# {ok, at, kind}.
func _dry_check(crossing: Vector2, exempt: float) -> Dictionary:
	for i in _kd_pts.size():
		var p := _kd_pts[i]
		if _kd_road_t[i] == 1 and crossing.is_finite() and p.distance_to(crossing) <= exempt:
			continue
		if s_at(p.x, p.y) > 0.0:
			return {"ok": false, "at": p, "kind": _kd_kind[i]}
	return {"ok": true, "at": Vector2.ZERO, "kind": ""}

# --- 1. the sea --------------------------------------------------------------------------------------------

func _build_sea() -> void:
	var road_edge := int(_lay.diagnostics.get("road_edge", -1))
	var cands: Array = []
	for e in 4:
		if e != road_edge:
			cands.append([ValueNoise.hash2(e, 7, _stream_seed(S_EDGES)), e])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var rc := _stream(S_COUNT)
	var want := 1 if rc.next() * (_sea_counts[0] + _sea_counts[1]) < _sea_counts[0] else 2
	want = mini(want, cands.size())
	var rj := _stream(S_JITTER)
	var base_edges: Array[int] = []
	var base_reach := PackedFloat64Array()
	for k in want:
		var e := int(cands[k][1])
		# a second sea edge is ADJACENT to the first (a corner of sea, an island's coast), never the opposite one
		if k == 1 and (e >> 1) == (base_edges[0] >> 1):
			var found := false
			for c: Array in cands:
				if (int(c[1]) >> 1) != (base_edges[0] >> 1):
					e = int(c[1])
					found = true
					break
			if not found:
				break
		base_edges.append(e)
		base_reach.append(_sea_reach_m * (1.0 + _sea_reach_jit * (rj.next() * 2.0 - 1.0)))
	# The first choice, undisturbed: is it already dry? (the survey's number)
	sea_edges = base_edges.duplicate()
	sea_reach = base_reach.duplicate()
	var first_ok: bool = _dry_check(Vector2(INF, INF), 0.0)["ok"]
	var trail: Array = []
	var scale := 1.0
	var adapted := 0
	var dropped: Array[int] = []
	while not _dry_check(Vector2(INF, INF), 0.0)["ok"]:
		adapted += 1
		if scale > pow(_sea_shrink, _sea_adapt) * 0.999 and not sea_edges.is_empty():
			scale *= _sea_shrink
			for k in sea_reach.size():
				sea_reach[k] = base_reach[k] * scale
		elif not sea_edges.is_empty():
			dropped.append(sea_edges[sea_edges.size() - 1])
			sea_edges.remove_at(sea_edges.size() - 1)
			base_reach.remove_at(base_reach.size() - 1)
			sea_reach = base_reach.duplicate()
			scale = 1.0
		else:
			break
		trail.append({"scale": snappedf(scale, 0.001), "edges": sea_edges.duplicate()})
		if adapted > 200:
			break
	diagnostics["sea"] = {"road_edge": road_edge, "edges_wanted": base_edges.size() + dropped.size(), "edges": sea_edges.duplicate(),
		"dropped": dropped, "reach_scale": snappedf(scale, 0.001), "dry_first_try": first_ok, "adapt_steps": adapted}

# --- 3. the river ------------------------------------------------------------------------------------------

func _build_river() -> void:
	var road: PackedVector2Array = _lay.road()
	var v: Dictionary = _lay.village()
	var centre: Vector2 = v.centre
	var rec := {"made": false, "why": ""}
	diagnostics["river"] = rec
	if road.size() < 4:
		rec["why"] = "no road"
		return
	# the crossing candidates: road points in the distance band, on low ground, clear of the batteries
	var cands: Array = []
	var batts: Array[Vector2] = _lay.sites().aa_battery
	for i in range(2, road.size() - 2):
		var p := road[i]
		var dc := p.distance_to(centre)
		if dc < _x_min or dc > _x_max or not _map.grow(-_x_margin).has_point(p):
			continue
		var near_batt := false
		for b in batts:
			if p.distance_to(b) < _x_batt:
				near_batt = true
		if near_batt:
			continue
		cands.append([ValueNoise.hash2(i, 3, _stream_seed(S_CROSS)), i])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	rec["crossing_candidates"] = cands.size()
	if cands.is_empty():
		rec["why"] = "no road point %d to %d m from the village on the map" % [int(_x_min), int(_x_max)]
		return
	var grid := _route_grid()
	var tried: Array = []
	var n_try := 0
	var best: Dictionary = {}
	for c: Array in cands:
		if n_try >= _x_tries:
			break
		var i: int = c[1]
		var p := road[i]
		if int(_t.level_at(p.x, p.y)) != 0 or float(_t.boundary_distance(p.x, p.y, 0, _x_cliff)) < _x_cliff:
			continue
		n_try += 1
		var res := _try_crossing(grid, road, i)
		tried.append({"road_index": i, "ok": res["ok"], "why": res["why"], "length_m": snappedf(float(res["length"]), 1.0) if res["ok"] else 0.0, "sea": bool(res["sea"]) if res["ok"] else false})
		if res["ok"]:
			res["index"] = i
			if best.is_empty() or (bool(res["sea"]) and not bool(best["sea"])) or (bool(res["sea"]) == bool(best["sea"]) and float(res["length"]) < float(best["length"])):
				best = res
			if bool(best["sea"]) and best_enough(best):
				break
	rec["tried"] = tried
	if best.is_empty():
		rec["why"] = "no crossing in %d tries kept the layout dry" % n_try
		_clear_river()
		return
	river_pts = best["pts"]
	river_hw = best["hw"]
	river_dmax = best["dmax"]
	river_t = best["t"]
	river_length = best["length"]
	river_crossing = best["x"]
	river_source = river_pts[0]
	river_mouth = river_pts[river_pts.size() - 1]
	_index_river()
	rec["made"] = true
	rec["why"] = ""
	rec["crossing_index"] = best["index"]
	rec["length_m"] = snappedf(river_length, 0.1)
	rec["crossing"] = river_crossing
	rec["half_width_at_crossing_m"] = snappedf(_hw_at(river_crossing), 0.1)
	rec["source"] = river_source
	rec["mouth"] = river_mouth
	rec["ends_in"] = "sea" if sea_s(river_mouth.x, river_mouth.y) > 0.0 else "map edge"

# A course this short needs no better one (the search stops).
func best_enough(best: Dictionary) -> bool:
	return float(best["length"]) <= _x_len_good

func _clear_river() -> void:
	river_pts = PackedVector2Array()
	river_hw = PackedFloat64Array()
	river_dmax = PackedFloat64Array()
	river_t = PackedFloat64Array()
	river_length = 0.0
	river_crossing = Vector2(INF, INF)
	river_source = Vector2(INF, INF)
	river_mouth = Vector2(INF, INF)
	_rbuckets = {}

func _hw_at(p: Vector2) -> float:
	var best := 0.0
	var bd := INF
	for i in river_pts.size():
		var d := river_pts[i].distance_to(p)
		if d < bd:
			bd = d
			best = river_hw[i]
	return best

# The coarse routing grid: terrain field, landness, sea depth and the keep-out mask, once per water.
func _route_grid() -> Dictionary:
	var cols := int(floor(_map.size.x / _r_step)) + 1
	var rows := int(floor(_map.size.y / _r_step)) + 1
	var f := PackedFloat64Array()
	var land := PackedFloat64Array()
	var ss := PackedFloat64Array()
	f.resize(cols * rows)
	land.resize(cols * rows)
	ss.resize(cols * rows)
	var lmin := INF
	var lmax := -INF
	for j in rows:
		for i in cols:
			var x := _map.position.x + float(i) * _r_step
			var y := _map.position.y + float(j) * _r_step
			var idx := j * cols + i
			f[idx] = _t.field_at(x, y)
			land[idx] = landness(x, y)
			ss[idx] = -land[idx] * _sea_dpu
			lmin = minf(lmin, land[idx])
			lmax = maxf(lmax, land[idx])
	# the keep-out mask: the village, the fields, the compound and the batteries, each grown
	var solid := PackedByteArray()
	solid.resize(cols * rows)
	var v: Dictionary = _lay.village()
	_mark_poly(solid, cols, rows, _grow(v.polygon, _r_vgap))
	for fp: PackedVector2Array in _lay.fields():
		_mark_poly(solid, cols, rows, _grow(fp, _r_fgap))
	_mark_disc(solid, cols, rows, _lay.sites().radio_tower, _r_cgap)
	for b: Vector2 in _lay.sites().aa_battery:
		_mark_disc(solid, cols, rows, b, _r_bgap)
	# the road corridor: a cost, not a wall
	var corr := PackedByteArray()
	corr.resize(cols * rows)
	var road: PackedVector2Array = _lay.road()
	for i in road.size():
		_mark_disc(corr, cols, rows, road[i], _r_rcorr)
	return {"cols": cols, "rows": rows, "f": f, "land": land, "s": ss, "solid": solid, "corr": corr, "lmin": lmin, "lmax": lmax}

func _mark_poly(mask: PackedByteArray, cols: int, rows: int, poly: PackedVector2Array) -> void:
	var rect := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	var i0 := maxi(0, floori((rect.position.x - _map.position.x) / _r_step))
	var i1 := mini(cols - 1, ceili((rect.end.x - _map.position.x) / _r_step))
	var j0 := maxi(0, floori((rect.position.y - _map.position.y) / _r_step))
	var j1 := mini(rows - 1, ceili((rect.end.y - _map.position.y) / _r_step))
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			if Geometry2D.is_point_in_polygon(_map.position + Vector2(i, j) * _r_step, poly):
				mask[j * cols + i] = 1

func _mark_disc(mask: PackedByteArray, cols: int, rows: int, c: Vector2, r: float) -> void:
	var i0 := maxi(0, floori((c.x - r - _map.position.x) / _r_step))
	var i1 := mini(cols - 1, ceili((c.x + r - _map.position.x) / _r_step))
	var j0 := maxi(0, floori((c.y - r - _map.position.y) / _r_step))
	var j1 := mini(rows - 1, ceili((c.y + r - _map.position.y) / _r_step))
	var r2 := r * r
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			if (_map.position + Vector2(i, j) * _r_step).distance_squared_to(c) <= r2:
				mask[j * cols + i] = 1

func _cell_of(p: Vector2, cols: int, rows: int) -> Vector2i:
	return Vector2i(clampi(roundi((p.x - _map.position.x) / _r_step), 0, cols - 1), clampi(roundi((p.y - _map.position.y) / _r_step), 0, rows - 1))

func _cell_pos(c: Vector2i) -> Vector2:
	return _map.position + Vector2(c) * _r_step

# A weighted A* for one crossing; weights dear on high ground and along the road, cheap on low ground.
func _make_astar(grid: Dictionary, x_at: Vector2) -> AStarGrid2D:
	var cols: int = grid["cols"]
	var rows: int = grid["rows"]
	var f: PackedFloat64Array = grid["f"]
	var land: PackedFloat64Array = grid["land"]
	var solid: PackedByteArray = grid["solid"]
	var corr: PackedByteArray = grid["corr"]
	var span: float = maxf(float(grid["lmax"]) - float(grid["lmin"]), 1e-6)
	var wn_seed := _stream_seed(S_ROUTE, 1)
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, cols, rows)
	astar.cell_size = Vector2(_r_step, _r_step)
	astar.offset = _map.position
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ALWAYS
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	astar.update()
	var near_x := _x_wp * 0.8
	for j in rows:
		for i in cols:
			var idx := j * cols + i
			var w := 1.0 + _r_wiggle * ValueNoise.vnoise(float(i) * _r_wiggle_f, float(j) * _r_wiggle_f, wn_seed)
			w += _r_low * clampf((land[idx] - float(grid["lmin"])) / span, 0.0, 1.0)
			if f[idx] >= _thr0 - 0.01:
				w *= _r_upland
			var on_road := corr[idx] == 1 and _cell_pos(Vector2i(i, j)).distance_to(x_at) > near_x
			astar.set_point_weight_scale(Vector2i(i, j), w)
			# the road is a wall but at the crossing: the river crosses it once, where it is meant to
			if solid[idx] == 1 or (on_road and _r_rw > 0.0):
				astar.set_point_solid(Vector2i(i, j), true)
	return astar

func _path_cost(astar: AStarGrid2D, path: Array[Vector2i]) -> float:
	var cost := 0.0
	for k in range(1, path.size()):
		cost += Vector2(path[k] - path[k - 1]).length() * astar.get_point_weight_scale(path[k])
	return cost

# Both ways round: the spring on either side of the road. The better course wins: one that ends in the sea, then the
# shorter. {ok, why, pts, hw, dmax, t, length, x, sea}; the river_* members are left cleared.
func _try_crossing(grid: Dictionary, road: PackedVector2Array, index: int) -> Dictionary:
	var best: Dictionary = {}
	var why := ""
	for flip in [false, true]:
		var r := _route_once(grid, road, index, flip)
		if not r["ok"]:
			why = str(r["why"]) if why == "" else why
			continue
		if best.is_empty() or (bool(r["sea"]) and not bool(best["sea"])) or (bool(r["sea"]) == bool(best["sea"]) and float(r["length"]) < float(best["length"])):
			best = r
	if best.is_empty():
		return {"ok": false, "why": why}
	return best

# One crossing with the spring on one side of the road (flip: the other); the course is checked against the keep-dry set.
func _route_once(grid: Dictionary, road: PackedVector2Array, index: int, flip: bool) -> Dictionary:
	var cols: int = grid["cols"]
	var rows: int = grid["rows"]
	var land: PackedFloat64Array = grid["land"]
	var ss: PackedFloat64Array = grid["s"]
	var solid: PackedByteArray = grid["solid"]
	var f: PackedFloat64Array = grid["f"]
	var x_at := road[index]
	var tg := (road[mini(index + 6, road.size() - 1)] - road[maxi(index - 6, 0)]).normalized()
	var nrm := Vector2(-tg.y, tg.x)
	# the spring's side first
	var w_a := x_at + nrm * _x_wp
	var w_b := x_at - nrm * _x_wp
	var c_a := _cell_of(w_a, cols, rows)
	var c_b := _cell_of(w_b, cols, rows)
	if flip:
		var tmp := w_a
		w_a = w_b
		w_b = tmp
		var tc := c_a
		c_a = c_b
		c_b = tc
	var w_up := w_a
	var w_dn := w_b
	var cu := c_a
	var cd := c_b
	if solid[cu.y * cols + cu.x] == 1 or solid[cd.y * cols + cd.x] == 1 or not _map.grow(-_r_step).has_point(w_up) or not _map.grow(-_r_step).has_point(w_dn):
		return {"ok": false, "why": "the waypoints are in a keep-out cell or off the map"}
	var astar := _make_astar(grid, x_at)
	# the river crosses the road ONCE: the spring is on the upstream side of it and the mouth on the downstream side
	var n_up := (w_up - x_at).normalized()
	# --- downstream: to the sea, or off the map ---
	var goals: Array = []
	var any_sea := false
	for j in rows:
		for i in cols:
			var idx := j * cols + i
			if ss[idx] > _m_depth and solid[idx] == 0 and (_cell_pos(Vector2i(i, j)) - x_at).dot(n_up) < 0.0:
				any_sea = true
				goals.append([_cell_pos(Vector2i(i, j)).distance_to(w_dn), Vector2i(i, j)])
	if not any_sea:
		for j in rows:
			for i in cols:
				if (i == 0 or j == 0 or i == cols - 1 or j == rows - 1) and solid[j * cols + i] == 0 and (_cell_pos(Vector2i(i, j)) - x_at).dot(n_up) < 0.0:
					goals.append([_cell_pos(Vector2i(i, j)).distance_to(w_dn), Vector2i(i, j)])
	goals.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var down: Array[Vector2i] = []
	var down_cost := INF
	for g in mini(_m_goals, goals.size()):
		var path: Array[Vector2i] = astar.get_id_path(cd, goals[g][1])
		if path.size() < 2:
			continue
		var cst := _path_cost(astar, path)
		if cst < down_cost:
			down_cost = cst
			down = path
	if down.is_empty():
		return {"ok": false, "why": "no route to the %s" % ("sea" if any_sea else "map edge")}
	# --- upstream: to a spring at the foot of high ground ---
	var thr_hi := _thr0 - _s_band[1]
	var thr_lo := _thr0 - _s_band[0]
	var springs: Array = []
	var lx: float = land[cu.y * cols + cu.x]
	for j in rows:
		for i in cols:
			var idx := j * cols + i
			if f[idx] < thr_lo or f[idx] > thr_hi or solid[idx] == 1 or land[idx] <= lx:
				continue
			var d := _cell_pos(Vector2i(i, j)).distance_to(x_at)
			if d < _s_min or d > _s_max or _road_dist(_cell_pos(Vector2i(i, j)), road) < 2.0 * _r_rcorr 					or (_cell_pos(Vector2i(i, j)) - x_at).dot(n_up) <= 0.0:
				continue
			springs.append([ValueNoise.hash2(i, j, _stream_seed(S_SOURCE, index)), Vector2i(i, j)])
	springs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var up: Array[Vector2i] = []
	var up_cost := INF
	for s in mini(_s_cands, springs.size()):
		var path: Array[Vector2i] = astar.get_id_path(cu, springs[s][1])
		if path.size() < 2:
			continue
		var cst := _path_cost(astar, path)
		if cst < up_cost:
			up_cost = cst
			up = path
	if up.is_empty():
		# no foot of high ground in reach: the course starts as far upstream as the band allows, on the way up
		var far := cu
		var best := -INF
		for j in rows:
			for i in cols:
				var idx := j * cols + i
				var d := _cell_pos(Vector2i(i, j)).distance_to(x_at)
				if solid[idx] == 0 and d >= _s_min and d <= _s_max * 1.6 and land[idx] > best and f[idx] < thr_hi 						and _road_dist(_cell_pos(Vector2i(i, j)), road) >= 2.0 * _r_rcorr and (_cell_pos(Vector2i(i, j)) - x_at).dot(n_up) > 0.0:
					best = land[idx]
					far = Vector2i(i, j)
		var path: Array[Vector2i] = astar.get_id_path(cu, far)
		if path.size() >= 2:
			up = path
	if up.is_empty():
		return {"ok": false, "why": "no route upstream"}
	# --- the course, spring to mouth ---
	var flat := PackedFloat64Array()
	for k in range(up.size() - 1, 0, -1):
		var q := _cell_pos(up[k])
		flat.append(q.x)
		flat.append(q.y)
	flat.append(w_up.x)
	flat.append(w_up.y)
	flat.append(x_at.x)
	flat.append(x_at.y)
	flat.append(w_dn.x)
	flat.append(w_dn.y)
	for k in range(1, down.size()):
		var q := _cell_pos(down[k])
		flat.append(q.x)
		flat.append(q.y)
	var built := _shape_course(flat, x_at)
	if built.is_empty():
		return {"ok": false, "why": "the course is too short once trimmed"}
	if float(built["length"]) > _x_len_max:
		return {"ok": false, "why": "the course is %d m long (at most %d)" % [int(built["length"]), int(_x_len_max)]}
	_clear_river()
	river_pts = built["pts"]
	river_hw = built["hw"]
	river_dmax = built["dmax"]
	river_t = built["t"]
	river_length = built["length"]
	river_crossing = x_at
	river_source = river_pts[0]
	river_mouth = river_pts[river_pts.size() - 1]
	_index_river()
	var chk := _dry_check(x_at, _x_exempt)
	if chk["ok"]:
		var gap := _road_gap_m(road, index)
		if gap > _x_gap_max:
			chk = {"ok": false, "at": x_at, "kind": "road for %d m (it runs along the road)" % int(gap)}
	if not chk["ok"]:
		var why := "would flood the %s at %s (%d m from the crossing; spring %s, mouth %s, %d points)" % [chk["kind"], chk["at"], int((chk["at"] as Vector2).distance_to(x_at)), river_source, river_mouth, river_pts.size()]
		_clear_river()
		return {"ok": false, "why": why}
	var rec := {"ok": true, "why": "", "pts": river_pts, "hw": river_hw, "dmax": river_dmax, "t": river_t, "length": river_length, "x": x_at,
		"sea": sea_s(river_mouth.x, river_mouth.y) > 0.0}
	_clear_river()
	return rec

# Distance from p to the road's points (the road is sampled every 10 m).
static func _road_dist(p: Vector2, road: PackedVector2Array) -> float:
	var best := INF
	for q in road:
		best = minf(best, p.distance_squared_to(q))
	return sqrt(best)

# Length of the wet stretch of the road round road[index] (the gap where a bridge will go), metres.
func _road_gap_m(road: PackedVector2Array, index: int) -> float:
	var n := 0.0
	for dir in [-1, 1]:
		var k: int = index
		while k >= 0 and k < road.size() and s_at(road[k].x, road[k].y) > 0.0:
			if k != index:
				n += road[k].distance_to(road[k - dir])
			k += dir
	return n

# Smooths the routed polyline, trims it at the sea, meanders it and gives it widths and depths.
func _shape_course(flat: PackedFloat64Array, x_at: Vector2) -> Dictionary:
	var p := flat
	for _k in _sh_smooth:
		p = Geometry.chaikin_f64(p, false)
	var even := Geometry.resample_f64(p, _sh_sample, false)
	var n := even.size() / 2
	if n < 6:
		return {}
	# arc length and the crossing's place on it
	var s := PackedFloat64Array()
	s.resize(n)
	var acc := 0.0
	var xi := 0
	var xd := INF
	for i in n:
		if i > 0:
			acc += Vector2(even[i * 2] - even[i * 2 - 2], even[i * 2 + 1] - even[i * 2 - 1]).length()
		s[i] = acc
		var d := Vector2(even[i * 2], even[i * 2 + 1]).distance_to(x_at)
		if d < xd:
			xd = d
			xi = i
	var s_x := s[xi]
	# meanders
	var rm := _stream_seed(S_MEANDER)
	var total := acc
	var pts := PackedVector2Array()
	pts.resize(n)
	for i in n:
		var a := Vector2(even[maxi(i - 1, 0) * 2], even[maxi(i - 1, 0) * 2 + 1])
		var b := Vector2(even[mini(i + 1, n - 1) * 2], even[mini(i + 1, n - 1) * 2 + 1])
		var tg := (b - a).normalized()
		var nr := Vector2(-tg.y, tg.x)
		var tt := s[i] / maxf(total, 1.0)
		var amp := lerpf(_sh_meander[0], _sh_meander[1], tt)
		var taper := smoothstep(0.0, 1.0, minf(absf(s[i] - s_x) / _sh_taper, 1.0)) * smoothstep(0.0, 1.0, minf(s[i] / _sh_staper, 1.0))
		var w := (ValueNoise.vnoise(s[i] / _sh_wl, 4.4, rm) * 2.0 - 1.0) * amp * taper
		pts[i] = Vector2(even[i * 2], even[i * 2 + 1]) + nr * w
	# trim at the sea: from the crossing on, stop where it is deep enough, run a little way on
	var last := n - 1
	var in_sea := false
	for i in range(xi, n):
		if sea_s(pts[i].x, pts[i].y) > _m_depth:
			last = i
			in_sea = true
			break
	var cut := PackedVector2Array()
	for i in last + 1:
		cut.append(pts[i])
	var ext_n := int(round(_m_extend / _sh_sample))
	var ext_from := cut.size()
	var dirv := (cut[cut.size() - 1] - cut[maxi(cut.size() - 4, 0)]).normalized()
	for k in range(1, ext_n + 1):
		cut.append(cut[ext_from - 1] + dirv * _sh_sample * float(k))
	var m := cut.size()
	if m < 6:
		return {}
	# arc length again, then t, widths, depths
	var len2 := PackedFloat64Array()
	len2.resize(m)
	var a2 := 0.0
	for i in m:
		if i > 0:
			a2 += cut[i].distance_to(cut[i - 1])
		len2[i] = a2
	# widths and depths by distance from the spring (the channel is 2 x crossing_half_width_m wide at the crossing
	# wherever that is, and goes on widening to half_width_m[1] and deepening to centre_depth_m[1])
	var s_x2 := len2[mini(xi, m - 1)]
	var frac := clampf((_sh_hwx - _sh_hw[0]) / maxf(_sh_hw[1] - _sh_hw[0], 1e-6), 0.05, 0.95)
	var l_ref := maxf(s_x2, 200.0) / pow(frac, 1.0 / _sh_hwp)
	var hw := PackedFloat64Array()
	var dm := PackedFloat64Array()
	var ts := PackedFloat64Array()
	for i in m:
		var t := len2[i] / maxf(a2, 1.0)
		ts.append(t)
		var u := pow(clampf(len2[i] / l_ref, 0.0, 1.0), _sh_hwp)
		hw.append(lerpf(_sh_hw[0], _sh_hw[1], u))
		var d := lerpf(_sh_dm[0], _sh_dm[1], pow(u, _sh_dmp))
		if i >= ext_from and in_sea:
			d *= 1.0 - smoothstep(0.0, 1.0, float(i - ext_from + 1) / float(ext_n))
		dm.append(d)
	# a bend tighter than the channel is wide would fold the ribbon: the half width is held under 0.8 of the radius
	for i in range(1, m - 1):
		var r := _radius(cut[i - 1], cut[i], cut[i + 1])
		hw[i] = minf(hw[i], 0.8 * r)
	for _k in 2:
		var sm := hw.duplicate()
		for i in range(1, m - 1):
			sm[i] = minf(hw[i], (hw[i - 1] + hw[i] + hw[i + 1]) / 3.0)
		hw = sm
	return {"pts": cut, "hw": hw, "dmax": dm, "t": ts, "length": a2}

# Radius of the circle through three points (INF for a straight line).
static func _radius(a: Vector2, b: Vector2, c: Vector2) -> float:
	var ab := a.distance_to(b)
	var bc := b.distance_to(c)
	var ca := c.distance_to(a)
	var area2 := absf((b - a).cross(c - a))
	if area2 < 1e-6:
		return INF
	return ab * bc * ca / (2.0 * area2)

func _index_river() -> void:
	_rbuckets = {}
	var hmax := 0.0
	for h in river_hw:
		hmax = maxf(hmax, h)
	for i in river_pts.size() - 1:
		var a := river_pts[i]
		var b := river_pts[i + 1]
		var g := maxf(river_hw[i], river_hw[i + 1]) + 1.0
		var x0 := floori((minf(a.x, b.x) - g) / BUCKET_M)
		var x1 := floori((maxf(a.x, b.x) + g) / BUCKET_M)
		var y0 := floori((minf(a.y, b.y) - g) / BUCKET_M)
		var y1 := floori((maxf(a.y, b.y) + g) / BUCKET_M)
		for by in range(y0, y1 + 1):
			for bx in range(x0, x1 + 1):
				var key := Vector2i(bx, by)
				var arr: PackedInt32Array = _rbuckets.get(key, PackedInt32Array())
				arr.append(i)
				_rbuckets[key] = arr

# --- the drawing's geometry -------------------------------------------------------------------------------------

# The sea's field on a grid over `rect` grown by pad_m: {x0, y0, cols, rows, cell, vals}. Cached by the rect.
func sea_grid(rect: Rect2, pad_m: float = 64.0) -> Dictionary:
	var key := "%s|%s" % [str(rect), str(pad_m)]
	if _grid_cache.has(key):
		return _grid_cache[key]
	var x0 := floorf((rect.position.x - pad_m) / _cell_m) * _cell_m
	var y0 := floorf((rect.position.y - pad_m) / _cell_m) * _cell_m
	var cols := ceili((rect.end.x + pad_m - x0) / _cell_m) + 1
	var rows := ceili((rect.end.y + pad_m - y0) / _cell_m) + 1
	var vals := PackedFloat64Array()
	vals.resize(cols * rows)
	for j in rows:
		var y := y0 + float(j) * _cell_m
		for i in cols:
			vals[j * cols + i] = sea_s(x0 + float(i) * _cell_m, y)
	var g := {"x0": x0, "y0": y0, "cols": cols, "rows": rows, "cell": _cell_m, "vals": vals}
	if _grid_cache.size() > 6:
		_grid_cache.clear()
	_grid_cache[key] = g
	return g

# The rings of the sea where depth >= step k's start, over `rect`.
func sea_rings(rect: Rect2, k: int) -> Array:
	var g := sea_grid(rect)
	return WaterContour.rings(g["vals"], g["cols"], g["rows"], g["x0"], g["y0"], g["cell"], maxf(step_from[k], 0.0), _chaikin, _resample)

# The river's ribbons for step k over `rect` (grown a little): the contiguous stretches of the course where the
# step exists, [{c: PackedVector2Array, h: PackedFloat64Array}].
func river_runs(rect: Rect2, k: int) -> Array:
	var out: Array = []
	if river_pts.size() < 2:
		return out
	var thr := step_from[k]
	var grown := rect.grow(80.0)
	var cur_c := PackedVector2Array()
	var cur_h := PackedFloat64Array()
	for i in river_pts.size():
		var h := river_hw[i]
		if thr > 0.0:
			h *= sqrt(maxf(0.0, 1.0 - thr / maxf(river_dmax[i], 1e-6)))
		var inside := h > 0.3 and grown.has_point(river_pts[i])
		if inside:
			cur_c.append(river_pts[i])
			cur_h.append(h)
		elif cur_c.size() > 0:
			if cur_c.size() >= 2:
				out.append({"c": cur_c, "h": cur_h})
			cur_c = PackedVector2Array()
			cur_h = PackedFloat64Array()
	if cur_c.size() >= 2:
		out.append({"c": cur_c, "h": cur_h})
	return out

# The river's two banks as polylines over `rect`: [{l: PackedVector2Array, r: PackedVector2Array}] for step k.
func river_edges(rect: Rect2, k: int) -> Array:
	var out: Array = []
	for run: Dictionary in river_runs(rect, k):
		var c: PackedVector2Array = run["c"]
		var h: PackedFloat64Array = run["h"]
		var l := PackedVector2Array()
		var r := PackedVector2Array()
		for i in c.size():
			var a := c[maxi(i - 1, 0)]
			var b := c[mini(i + 1, c.size() - 1)]
			var tg := (b - a).normalized()
			var nr := Vector2(-tg.y, tg.x)
			l.append(c[i] + nr * h[i])
			r.append(c[i] - nr * h[i])
		out.append({"l": l, "r": r})
	return out

# --- reports -------------------------------------------------------------------------------------------------

# Share of the map that is water (s > 0, the uplands ignored), sampled on a coarse lattice.
func wet_fraction(step_m: float = 100.0) -> Dictionary:
	var n := 0
	var wet := PackedInt32Array([0, 0, 0])
	var y := _map.position.y + step_m * 0.5
	while y < _map.end.y:
		var x := _map.position.x + step_m * 0.5
		while x < _map.end.x:
			n += 1
			var k := step_of(s_at(x, y))
			if k >= 0:
				wet[k] += 1
			x += step_m
		y += step_m
	return {"samples": n, "shallows": float(wet[0]) / n, "shelf": float(wet[1]) / n, "deep": float(wet[2]) / n,
		"water": float(wet[0] + wet[1] + wet[2]) / n}

# A string that changes when anything in the water does (tests compare waters with it).
func signature() -> String:
	var parts: Array[String] = [",".join(sea_edges.map(func(e: int) -> String: return str(e)))]
	for r in sea_reach:
		parts.append("%.3f" % r)
	parts.append(str(river_pts.size()))
	if river_pts.size() > 0:
		var mid := river_pts[river_pts.size() / 2]
		parts.append("%.3f,%.3f" % [mid.x, mid.y])
		parts.append("%.3f,%.3f" % [river_pts[0].x, river_pts[0].y])
		parts.append("%.3f,%.3f" % [river_mouth.x, river_mouth.y])
		parts.append("%.3f" % river_hw[river_hw.size() / 2])
	for p in [Vector2(500, 500), Vector2(2500, 2500), Vector2(4500, 1000), Vector2(1200, 4300)]:
		parts.append("%.4f" % s_at(p.x, p.y))
	return "|".join(parts)
