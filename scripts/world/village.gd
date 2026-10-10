extends RefCounted

# THE VILLAGE, IN MAP PIXELS (Track W, 2026-10-10): what scripts/world/world_layout.gd plans in
# metres, made with the prototype's own generators (structures.gd) at the map's scale -- the
# walled compound round the radio tower's site (makeFort: a ring, a divider, often a smaller
# ring), the houses along the street (makeHouse) and the road as the prototype's road samples
# (buildRoad's {x, y, nx, ny}, one every 3 px), plus the fields as pixel polygons and the
# answers the terrain's trees and the chunk bake need ("is this spot taken?").
#
#   var village := Village.new(layout, P, px_per_m)
#   village.structs            world-px structure dictionaries (walls and houses), geometry
#                              synced (Structures.sync_struct), the compound's first; each also
#                              has role = "compound" | "house"
#   village.road_pts / road_xy the road's samples (px), as scene_gen.roadPts
#   village.fields             [{poly: PackedVector2Array px, rect: Rect2, info: {angle, kind, seed}}]
#   village.structs_in_rect(rect) / fields_in_rect(rect) / road_runs_in_rect(rect, margin)
#   village.blocks_tree(x, y, c) -> bool   a tree of collision radius c at world px (x, y) would
#                              stand on a house, a wall, the compound's yard, the road or a field
#   village.in_village(x, y) -> bool       inside the village's outline (the tree density factor)
#
# WHAT IS SCALE-DEPENDENT: the layout is in metres, but the prototype's structures are a fixed
# number of PIXELS (a house is about 42 x 22 px, the road's half width 16 px), so at another
# px_per_m the houses are bigger or smaller on the ground and the village is rebuilt (house slots
# that would then overlap are turned half round, and failing that dropped). The compound is built round the tower's site so the site
# stays in the middle of its open cell at every scale (the tower is a unit, placed from
# WorldLayout.sites() in metres).
#
# Pure: everything here is a function of (layout, P, px_per_m). Built once, read-only afterwards,
# so a worker thread may call any query.

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const Geometry = preload("res://scripts/core/geometry.gd")
const Structures = preload("res://scripts/world/structures.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

# The lookup grid (px): a structure, field or road sample is listed in every cell it, grown by
# REACH, touches, so a tree's cell holds everything within REACH px of it.
const CELL := 128.0
const REACH := 64.0

var layout: RefCounted
var P: RenderParams
var ppm: float
var errors: Array[String] = []

var structs: Array = []
var compound: Dictionary = {}
var road_pts: Array = []
var road_xy := PackedFloat64Array()
var fields: Array = []
var polygon_px := PackedVector2Array()
var polygon_rect := Rect2()
var bounds_px := Rect2()
var tree_gain: float
var tree_clear: float
var min_gap_px: float
var fort_size_px: float

var _grid: Dictionary = {}          # Vector2i -> {structs: [], fields: [], road: PackedInt32Array}
var _enclosures: Array = []         # [{poly: PackedVector2Array, rect: Rect2}]: the compound's yards

func _init(layout_v: RefCounted, params: RenderParams, px_per_m: float) -> void:
	layout = layout_v
	P = params
	ppm = px_per_m
	var d: Variant = layout.data
	tree_gain = d.num("clearance.tree_gain_in_village")
	tree_clear = d.num("clearance.tree_clear_cr")
	min_gap_px = d.num("houses.min_gap_px")
	fort_size_px = d.num("compound.fort_size_px")
	errors.append_array(d.errors)
	if not layout.ok():
		errors.append_array(layout.errors)
		return
	var v: Dictionary = layout.village()
	for p: Vector2 in v.polygon:
		polygon_px.append(p * ppm)
	polygon_rect = Rect2(polygon_px[0], Vector2.ZERO)
	for p in polygon_px:
		polygon_rect = polygon_rect.expand(p)
	_build_road()
	_index_road()
	_build_compound(v)
	_build_houses(v)
	_build_fields()
	_index()

# --- the road --------------------------------------------------------------------------------------

# buildRoad on the layout's road: a Catmull-Rom spline through its points, sampled every 3 px,
# then a unit normal per sample from its neighbours (scene_gen.build_road).
func _build_road() -> void:
	var c := PackedFloat64Array()
	for p: Vector2 in layout.road():
		c.append(p.x * ppm)
		c.append(p.y * ppm)
	if c.size() < 6:
		return
	var xy := Geometry.catmull_rom_f64(c, 3.0)
	xy.append(c[c.size() - 2])    # the spline stops one sample short of its last point
	xy.append(c[c.size() - 1])
	var n := xy.size() / 2
	for i in n:
		var a := maxi(i - 1, 0) * 2
		var b := mini(i + 1, n - 1) * 2
		var tx: float = xy[b] - xy[a]
		var ty: float = xy[b + 1] - xy[a + 1]
		var l := sqrt(tx * tx + ty * ty)
		if l == 0.0:
			l = 1.0
		road_pts.append({"x": xy[i * 2], "y": xy[i * 2 + 1], "nx": -ty / l, "ny": tx / l})
	road_xy = xy

# --- the compound ------------------------------------------------------------------------------------

func _build_compound(v: Dictionary) -> void:
	var comp: Dictionary = v.compound
	var site: Vector2 = comp.site * ppm
	var rot: float = comp.rot
	var fseed: int = comp.fort_seed
	# the divider's seeded position says where the open (right) cell's middle is, in the fort's
	# own frame: build once at the origin to read it, then again with the cell's middle on the site
	var probe := Structures.make_fort(Mulberry32.new(fseed), 0.0, 0.0, fort_size_px, rot, P)
	var lx: float = (probe[1].gen as Dictionary).lx
	var cell_x := (lx + fort_size_px / 2.0) / 2.0
	var cx := site.x - cell_x * cos(rot)
	var cy := site.y - cell_x * sin(rot)
	var walls := Structures.make_fort(Mulberry32.new(fseed), cx, cy, fort_size_px, rot, P)
	for w: Dictionary in walls:
		Structures.sync_struct(w, P)
		w["role"] = "compound"
		structs.append(w)
	# the yard: the outer ring's centre line, a polygon trees keep out of
	var ring: Array = (walls[0] as Dictionary).pts
	var yard := PackedVector2Array()
	for p: Array in ring:
		yard.append(Vector2(p[0], p[1]))
	var rect := Rect2(yard[0], Vector2.ZERO)
	for p in yard:
		rect = rect.expand(p)
	_enclosures.append({"poly": yard, "rect": rect})
	compound = {"site": site, "rot": rot, "centre": Vector2(cx, cy), "walls": walls, "yard": yard, "cell_x": cell_x}

# --- the houses ----------------------------------------------------------------------------------------

func _build_houses(v: Dictionary) -> void:
	var dropped := 0
	var turned := 0
	for slot: Dictionary in v.house_slots:
		var pos: Vector2 = slot.pos * ppm
		# the slot's own turn first; a house whose wing would reach the road or a neighbour is
		# turned half round (its wing then points the other way) before it is given up
		var placed := false
		for half_turn in 2:
			var h := Structures.make_house(Mulberry32.new(int(slot.seed)), pos.x, pos.y, float(slot.rot) + PI * half_turn)
			Structures.sync_struct(h, P)
			h["role"] = "house"
			if _house_ok(h):
				structs.append(h)
				placed = true
				turned += half_turn
				break
		if not placed:
			dropped += 1
	compound["houses_dropped"] = dropped
	compound["houses_turned"] = turned

# The points of a house the gap test looks at: each part's centre, corners and edge midpoints.
static func _house_points(h: Dictionary) -> Array:
	var out: Array = []
	for part: Dictionary in h.geo:
		out.append([part.cx, part.cy])
		var cs: Array = part.corners
		for k in 4:
			out.append(cs[k])
			var a: Array = cs[k]
			var b: Array = cs[(k + 1) % 4]
			out.append([(a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5])
	return out

func _house_ok(h: Dictionary) -> bool:
	var mine := _house_points(h)
	for s: Dictionary in structs:
		for p: Array in mine:
			if _struct_dist(s, p[0], p[1]) < min_gap_px:
				return false
		if s.kind == "house":
			for p: Array in _house_points(s):
				if _struct_dist(h, p[0], p[1]) < min_gap_px:
					return false
	for p: Array in mine:
		if road_dist(p[0], p[1]) < P.ROAD_HALF + min_gap_px:
			return false
	return true

# The prototype's sDist with plain float math (a decision for a tree or a slot, not for the
# bit-exact port): a wall's nearest centre-line sample less its half width, a house's box SDF.
func _struct_dist(s: Dictionary, x: float, y: float) -> float:
	if s.kind == "wall":
		var m := 1e18
		for p: Array in s.pts:
			var dx: float = p[0] - x
			var dy: float = p[1] - y
			var d := dx * dx + dy * dy
			if d < m:
				m = d
		return sqrt(m) - s.hw
	var best := 1e18
	for p: Dictionary in s.geo:
		var dx: float = x - p.cx
		var dy: float = y - p.cy
		var lx: float = dx * p.cc + dy * p.ss
		var ly: float = -dx * p.ss + dy * p.cc
		var qx: float = absf(lx) - float(p.w) / 2.0
		var qy: float = absf(ly) - float(p.d) / 2.0
		var d: float = sqrt(maxf(qx, 0.0) * maxf(qx, 0.0) + maxf(qy, 0.0) * maxf(qy, 0.0)) + minf(maxf(qx, qy), 0.0)
		if d < best:
			best = d
	return best

# --- the fields ----------------------------------------------------------------------------------------------

func _build_fields() -> void:
	for i in layout.field_count():
		var poly := PackedVector2Array()
		for p: Vector2 in layout.fields()[i]:
			poly.append(p * ppm)
		var rect := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			rect = rect.expand(p)
		fields.append({"poly": poly, "rect": rect, "info": layout.field_info(i), "index": i})

# --- the lookup grid -----------------------------------------------------------------------------------------

func _cell_of(x: float, y: float) -> Vector2i:
	return Vector2i(floori(x / CELL), floori(y / CELL))

func _cell(key: Vector2i) -> Dictionary:
	var e: Variant = _grid.get(key)
	if e == null:
		e = {"structs": [], "fields": [], "enclosures": [], "road": PackedInt32Array()}
		_grid[key] = e
	return e

func _cells_over(rect: Rect2, grow: float) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var a := _cell_of(rect.position.x - grow, rect.position.y - grow)
	var b := _cell_of(rect.end.x + grow, rect.end.y + grow)
	for cy in range(a.y, b.y + 1):
		for cx in range(a.x, b.x + 1):
			out.append(Vector2i(cx, cy))
	return out

func _index_road() -> void:
	var reach := P.ROAD_HALF + REACH
	for i in road_pts.size():
		var p: Dictionary = road_pts[i]
		var c0 := _cell_of(p.x - reach, p.y - reach)
		var c1 := _cell_of(p.x + reach, p.y + reach)
		for cy in range(c0.y, c1.y + 1):
			for cx in range(c0.x, c1.x + 1):
				# a packed array held in a dictionary is a copy when cast: take it, add, put it back
				var e := _cell(Vector2i(cx, cy))
				var ids: PackedInt32Array = e.road
				ids.append(i)
				e.road = ids

func _index() -> void:
	for i in structs.size():
		var s: Dictionary = structs[i]
		for k in _cells_over(Rect2(s.bx, s.by, s.bw, s.bh), REACH):
			(_cell(k).structs as Array).append(i)
	for i in fields.size():
		for k in _cells_over(fields[i].rect, 0.0):
			(_cell(k).fields as Array).append(i)
	for i in _enclosures.size():
		for k in _cells_over(_enclosures[i].rect, 0.0):
			(_cell(k).enclosures as Array).append(i)
	bounds_px = polygon_rect
	for f: Dictionary in fields:
		bounds_px = bounds_px.merge(f.rect)

# --- queries (read-only: any thread) ----------------------------------------------------------------------------------

func ok() -> bool:
	return errors.is_empty()

func in_village(x: float, y: float) -> bool:
	return polygon_rect.has_point(Vector2(x, y)) and Geometry2D.is_point_in_polygon(Vector2(x, y), polygon_px)

# Distance (px) from (x, y) to the nearest road sample within REACH + ROAD_HALF; INF when none.
func road_dist(x: float, y: float) -> float:
	var e: Variant = _grid.get(_cell_of(x, y))
	if e == null:
		return INF
	var ids: PackedInt32Array = e.road
	var best := INF
	for i in ids:
		var dx: float = road_xy[i * 2] - x
		var dy: float = road_xy[i * 2 + 1] - y
		var d := dx * dx + dy * dy
		if d < best:
			best = d
	return sqrt(best) if best != INF else INF

# Whether a tree of collision radius c at world px (x, y) would stand on a house or a wall, in the
# compound's yard, on the road or in a field: the prototype's canPlace rule with the clearance
# widened to clearance.tree_clear_cr (data) collision radii instead of 0.6 (clear of a structure by
# that much; off the road by ROAD_HALF plus that much).
func blocks_tree(x: float, y: float, c: float) -> bool:
	var e: Variant = _grid.get(_cell_of(x, y))
	if e == null:
		return false
	var m := c * tree_clear
	for i in (e.structs as Array):
		var s: Dictionary = structs[i]
		if x < s.bx - m or x > s.bx + s.bw + m or y < s.by - m or y > s.by + s.bh + m:
			continue
		if _struct_dist(s, x, y) < m:
			return true
	var pt := Vector2(x, y)
	for i in (e.enclosures as Array):
		var z: Dictionary = _enclosures[i]
		if (z.rect as Rect2).has_point(pt) and Geometry2D.is_point_in_polygon(pt, z.poly):
			return true
	for i in (e.fields as Array):
		var f: Dictionary = fields[i]
		if (f.rect as Rect2).has_point(pt) and Geometry2D.is_point_in_polygon(pt, f.poly):
			return true
	var limit := P.ROAD_HALF + m
	var ids: PackedInt32Array = e.road
	var l2 := limit * limit
	for i in ids:
		var dx: float = road_xy[i * 2] - x
		var dy: float = road_xy[i * 2 + 1] - y
		if dx * dx + dy * dy < l2:
			return true
	return false

# The structures whose sprite bounds touch `rect` (world px).
func structs_in_rect(rect: Rect2) -> Array:
	var out: Array = []
	for s: Dictionary in structs:
		if rect.intersects(Rect2(s.bx, s.by, s.bw, s.bh)):
			out.append(s)
	return out

# The fields whose bounds touch `rect`.
func fields_in_rect(rect: Rect2) -> Array:
	var out: Array = []
	for f: Dictionary in fields:
		if rect.intersects(f.rect):
			out.append(f)
	return out

# Runs [i0, i1] (inclusive sample indices) of the road that lie within `margin` px of `rect`,
# in road order: the samples a chunk has to draw.
func road_runs_in_rect(rect: Rect2, margin: float) -> Array:
	var r := rect.grow(margin)
	var runs: Array = []
	var start := -1
	for i in road_pts.size():
		var p: Dictionary = road_pts[i]
		var inside := r.has_point(Vector2(p.x, p.y))
		if inside and start < 0:
			start = i
		elif not inside and start >= 0:
			runs.append([start, i - 1])
			start = -1
	if start >= 0:
		runs.append([start, road_pts.size() - 1])
	return runs
