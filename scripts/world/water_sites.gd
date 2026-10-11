extends RefCounted

# THE SIMULATION'S SEA SITES (Track WS, 2026-10-10): where the patrol boat patrols and the supply boat sails, fitted to
# the water a WaterGen made. Pure and deterministic: a function of the water (so of the seed and data/world/water.json)
# and of the `sites` records there, with no randomness at all -- candidates are ordered by distance and ties broken by
# position, so every machine finds the same loop. WaterGen.sites() is the way in:
#
#   water.sites().patrol_loop.points         the loop's four corners, metres
#   water.sites().supply_route.points         the route's waypoints, from its first point to its last
#
# HOW (the whole of it):
#  1. A CLEARANCE GRID over the map inset by sites.map_inset_m, every sites.grid_m metres: a cell is OPEN water where the
#     water query (WaterGen.depth_at) says at least sites.nav_depth_m, and its CLEARANCE is the distance to the nearest
#     cell that is not (a shore, a shoal, an island, the inset edge): a two-pass chamfer distance, in metres, less half a
#     cell (the shore lies between the cells). clear_at() reads it bilinearly. A second distance, the COAST's, leaves the
#     inset edge out: how far the real shore is. The grid is good to about half a cell, so a place passes it with
#     sites.grid_slack_m more clearance than the margin the exact check will ask.
#  2. THE ANCHOR is the river's mouth (the estuary), or with no river the radio tower: the boats work the coast near it.
#  3. THE PATROL LOOP: centres are the open cells with clearance for the loop's margin, nearest the anchor first. At each
#     one the loop is a rectangle (four corners, clockwise on screen), tried at the longest of patrol.half_lengths_m first
#     and, for each length, at the orientations that run ALONG THE COAST (the clearance field's gradient points away from
#     the shore; the loop's long axis is square to it), fanning out by orientation_step_deg to tangent_span_deg; in open
#     water, where there is no coast to run along, at every orientation. The first rectangle every sample of which has the
#     margin on the grid AND passes the exact check wins. Its first point is its corner nearest the anchor.
#  4. THE SUPPLY ROUTE: a Dijkstra over the open cells that have the barge's margin (and are sites.supply.loop_gap_m from the
#     patrol loop), from the open cell nearest the anchor that is clear of the loop and has a way of supply.min_length_m.
#     Its far end is a cell the water reaches in at most supply.length_m that HUGS THE COAST (within the margin plus
#     coast_slack_m of the real shore), the farthest, the one farther from the loop among equals; the way to it is
#     straightened (Douglas-Peucker to simplify_m) to waypoints, every leg checked exactly. A route shorter than
#     supply.min_length_m is no route.
#  THE EXACT CHECK: every sample (every sites.sample_m along a leg) must be over water at least nav_depth deep AND have, in
#  sixteen directions at the margin's radius, water at least nav_depth deep inside the inset map. The grid only finds
#  room; this decides.

const JsMath = preload("res://scripts/core/js_math.gd")

const RING_PROBES := 16
const GRADIENT_MIN := 0.35

var _w: Object
var _p: Dictionary
var _g := 50.0
var _inset := Rect2()
var _cols := 0
var _rows := 0
var _nav_depth := 3.0
var _open := PackedByteArray()
var _clear := PackedFloat64Array()      # chamfer distance (metres) from each open cell to the nearest cell that is not open (the grid's edge is a shore)
var _coast := PackedFloat64Array()      # the same with only REAL shore (the grid's edge is not): how far the coast is
var _ring_dirs: Array[Vector2] = []
var _avoid: Array[Vector2] = []         # a closed polyline the supply route keeps `_avoid_gap` away from (the patrol loop)
var _avoid_gap := 0.0

func _init(water: Object, params: Dictionary) -> void:
	_w = water
	_p = params
	for k in RING_PROBES:
		var a := TAU * float(k) / float(RING_PROBES)
		_ring_dirs.append(Vector2(JsMath.cos(a), JsMath.sin(a)))

func _f(key: String) -> float:
	return float(_p[key])

# {anchor, patrol_loop, supply_route, why, grid_cells}
func build() -> Dictionary:
	var why: Dictionary = {}
	_nav_depth = _f("nav_depth_m")
	_g = _f("grid_m")
	_inset = (_w.map_rect() as Rect2).grow(-_f("map_inset_m"))
	_build_grid()
	var anchor := _anchor()
	var open_cells := 0
	for v in _open:
		open_cells += int(v)
	var out := {"anchor": anchor, "patrol_loop": {}, "supply_route": {}, "why": why, "grid_cells": open_cells}
	if open_cells == 0:
		why["patrol_loop"] = "the seed has no open water (nowhere is %s m deep, clear of the shore)" % str(_nav_depth)
		why["supply_route"] = why["patrol_loop"]
		return out
	var loop := _fit_loop(anchor, why)
	out["patrol_loop"] = loop
	out["supply_route"] = _fit_route(anchor, loop, why)
	return out

# --- the clearance grid ---------------------------------------------------------------------------------------------

func _cell_pos(i: int, j: int) -> Vector2:
	return _inset.position + Vector2(float(i) * _g, float(j) * _g)

func _build_grid() -> void:
	_cols = int(_inset.size.x / _g) + 1
	_rows = int(_inset.size.y / _g) + 1
	_open = PackedByteArray()
	_open.resize(_cols * _rows)
	for j in _rows:
		for i in _cols:
			var p := _cell_pos(i, j)
			_open[j * _cols + i] = 1 if float(_w.depth_at(p.x, p.y)) >= _nav_depth else 0
	_clear = _chamfer(true)
	_coast = _chamfer(false)

# The distance (metres, centre to centre) from each open cell to the nearest cell that is not open: a two-pass chamfer
# (1 and 1.414 cells). `border_blocked`: the grid's edge (the inset map's edge) counts as a shore, as the clearance wants;
# not: only real shore does (a shoal, an island, the land), as the coast-hugging wants.
func _chamfer(border_blocked: bool) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(_cols * _rows)
	for idx in out.size():
		out[idx] = 1.0e9 if _open[idx] == 1 else 0.0
	var miss := 0.0 if border_blocked else 1.0e9
	var diag := _g * 1.41421356
	# forward: west, north-west, north, north-east
	for j in _rows:
		for i in _cols:
			var idx := j * _cols + i
			if _open[idx] == 0:
				continue
			var d: float = out[idx]
			d = minf(d, (out[idx - 1] if i > 0 else miss) + _g)
			d = minf(d, (out[idx - _cols] if j > 0 else miss) + _g)
			d = minf(d, (out[idx - _cols - 1] if i > 0 and j > 0 else miss) + diag)
			d = minf(d, (out[idx - _cols + 1] if i < _cols - 1 and j > 0 else miss) + diag)
			out[idx] = d
	# backward: east, south-east, south, south-west
	for j in range(_rows - 1, -1, -1):
		for i in range(_cols - 1, -1, -1):
			var idx := j * _cols + i
			if _open[idx] == 0:
				continue
			var d: float = out[idx]
			d = minf(d, (out[idx + 1] if i < _cols - 1 else miss) + _g)
			d = minf(d, (out[idx + _cols] if j < _rows - 1 else miss) + _g)
			d = minf(d, (out[idx + _cols + 1] if i < _cols - 1 and j < _rows - 1 else miss) + diag)
			d = minf(d, (out[idx + _cols - 1] if i > 0 and j < _rows - 1 else miss) + diag)
			out[idx] = d
	return out

# Clearance (metres) at a point, read bilinearly off the grid; negative where there is none (outside the grid, or
# within half a cell of a cell that is not open water).
func clear_at(p: Vector2) -> float:
	var fx := (p.x - _inset.position.x) / _g
	var fy := (p.y - _inset.position.y) / _g
	if fx < 0.0 or fy < 0.0 or fx > float(_cols - 1) or fy > float(_rows - 1):
		return -1.0
	var i0 := mini(int(floorf(fx)), _cols - 2)
	var j0 := mini(int(floorf(fy)), _rows - 2)
	var tx := fx - float(i0)
	var ty := fy - float(j0)
	var a: float = _clear[j0 * _cols + i0]
	var b: float = _clear[j0 * _cols + i0 + 1]
	var c: float = _clear[(j0 + 1) * _cols + i0]
	var d: float = _clear[(j0 + 1) * _cols + i0 + 1]
	return lerpf(lerpf(a, b, tx), lerpf(c, d, tx), ty) - 0.5 * _g

# The clearance grid's gradient at a point (it points away from the shore), by central differences.
func _gradient(p: Vector2) -> Vector2:
	var h := _g
	return Vector2(clear_at(p + Vector2(h, 0.0)) - clear_at(p - Vector2(h, 0.0)), clear_at(p + Vector2(0.0, h)) - clear_at(p - Vector2(0.0, h))) / (2.0 * h)

# --- the anchor ----------------------------------------------------------------------------------------------------------

func _anchor() -> Vector2:
	var mouth: Vector2 = _w.river_mouth
	if mouth.is_finite():
		return mouth
	return (_w.layout().sites() as Dictionary)["radio_tower"]

# --- the exact check -----------------------------------------------------------------------------------------------------

# Is `p` open water with `margin` of open water round it (sixteen probes at that radius), all inside the inset map?
func clear_exact(p: Vector2, margin: float) -> bool:
	if not _inset.has_point(p) or float(_w.depth_at(p.x, p.y)) < _nav_depth:
		return false
	for dir in _ring_dirs:
		var q := p + dir * margin
		if not _inset.has_point(q) or float(_w.depth_at(q.x, q.y)) < _nav_depth:
			return false
	return true

# The samples of a polyline every sample_m (the corners included), closed or not.
func _samples(pts: Array[Vector2], closed: bool) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var step := _f("sample_m")
	var n := pts.size() if closed else pts.size() - 1
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % pts.size()]
		var count := maxi(1, ceili(a.distance_to(b) / step))
		for k in count:
			out.append(a.lerp(b, float(k) / float(count)))
	if not closed:
		out.append(pts[pts.size() - 1])
	return out

# The grid's quick check of a polyline: every sample has the margin on the clearance grid.
func _grid_ok(pts: Array[Vector2], closed: bool, margin: float) -> bool:
	for s in _samples(pts, closed):
		if clear_at(s) < margin + _f("grid_slack_m"):
			return false
	return true

# The exact check of a polyline: every sample passes clear_exact(margin).
func _exact_ok(pts: Array[Vector2], closed: bool, margin: float) -> bool:
	for s in _samples(pts, closed):
		if not clear_exact(s, margin):
			return false
	return true

func _min_depth(pts: Array[Vector2], closed: bool) -> float:
	var best := INF
	for s in _samples(pts, closed):
		best = minf(best, float(_w.depth_at(s.x, s.y)))
	return best

# --- candidates ---------------------------------------------------------------------------------------------------------

# The open cells whose clearance is at least `need`, nearest `anchor` first (ties: by cell index), as cell centres.
func _centres(anchor: Vector2, need: float) -> Array[Vector2]:
	var keyed: Array = []
	for j in _rows:
		for i in _cols:
			var idx := j * _cols + i
			if _open[idx] == 1 and _clear[idx] - 0.5 * _g >= need + _f("grid_slack_m"):
				keyed.append([_cell_pos(i, j).distance_squared_to(anchor), idx])
	keyed.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	var out: Array[Vector2] = []
	for k: Array in keyed:
		var idx: int = k[1]
		out.append(_cell_pos(idx % _cols, idx / _cols))
	return out

# The orientations (angles in [0, PI): a loop's long axis) to try at `at`: along the coast first (the clearance's gradient
# points away from the shore; the axis is square to it) and fanning out to `span` either side; every orientation at `step`
# where no coast can be told (open water).
func _angles(at: Vector2, step: float, span: float) -> Array[float]:
	var out: Array[float] = []
	var g := _gradient(at)
	if g.length() >= GRADIENT_MIN:
		var t := fposmod(JsMath.atan2(g.y, g.x) + PI * 0.5, PI)
		var k := 0
		while float(k) * step <= span + 1e-9:
			out.append(fposmod(t + float(k) * step, PI))
			if k > 0:
				out.append(fposmod(t - float(k) * step, PI))
			k += 1
	else:
		var n := int(round(PI / step))
		for k in n:
			out.append(float(k) * step)
	return out

# --- the patrol loop ------------------------------------------------------------------------------------------------------

func _fit_loop(anchor: Vector2, why: Dictionary) -> Dictionary:
	var margin := _f("patrol.margin_m")
	var w := _f("patrol.half_width_m")
	var lengths: PackedFloat64Array = _p["patrol.half_lengths_m"]
	var step := deg_to_rad(_f("patrol.orientation_step_deg"))
	var span := deg_to_rad(_f("patrol.tangent_span_deg"))
	var tried := 0
	for c in _centres(anchor, margin):
		if tried >= int(_f("patrol.max_candidates")):
			break
		tried += 1
		var angles := _angles(c, step, span)
		for a in lengths:
			for th in angles:
				var pts := _rectangle(c, th, a, w)
				if _grid_ok(pts, true, margin) and _exact_ok(pts, true, margin):
					return _loop_record(pts, c, th, a, w, margin, anchor)
	why["patrol_loop"] = "no rectangle of %s to %s m fits in water %s m deep with %s m of margin within %d centres of the anchor" % [str(lengths[lengths.size() - 1] * 2.0), str(lengths[0] * 2.0), str(_nav_depth), str(margin), tried]
	return {}

# The four corners of a rectangle centred on c, its long axis along angle `th`, half length a and half width w, clockwise on
# screen (the axis, then the axis turned a quarter clockwise).
func _rectangle(c: Vector2, th: float, a: float, w: float) -> Array[Vector2]:
	var u := Vector2(JsMath.cos(th), JsMath.sin(th))
	var v := Vector2(-u.y, u.x)
	var pts: Array[Vector2] = [c - u * a - v * w, c + u * a - v * w, c + u * a + v * w, c - u * a + v * w]
	return pts

func _loop_record(pts: Array[Vector2], c: Vector2, th: float, a: float, w: float, margin: float, anchor: Vector2) -> Dictionary:
	# the first point is the corner nearest the anchor; the loop is the same order, clockwise
	var first := 0
	var best := INF
	for i in pts.size():
		var d := pts[i].distance_squared_to(anchor)
		if d < best:
			best = d
			first = i
	var ordered: Array[Vector2] = []
	for k in pts.size():
		ordered.append(pts[(first + k) % pts.size()])
	var headings: Array[float] = []
	var perimeter := 0.0
	for i in ordered.size():
		var q := ordered[(i + 1) % ordered.size()]
		headings.append(JsMath.atan2(q.y - ordered[i].y, q.x - ordered[i].x))
		perimeter += ordered[i].distance_to(q)
	return {
		"ok": true, "kind": "loop", "points": ordered, "headings": headings, "centre": c, "orientation": th,
		"half_length_m": a, "half_width_m": w, "margin_m": margin, "length_m": perimeter, "min_depth_m": _min_depth(ordered, true),
	}

static func _pair(a: Vector2, b: Vector2) -> Array[Vector2]:
	var out: Array[Vector2] = [a, b]
	return out

# --- the supply route -----------------------------------------------------------------------------------------------------

# From the open cell nearest the anchor (with the barge's margin) the way by water (a Dijkstra over the cells that have the
# margin, eight neighbours, no corner cut) is found to every cell; the route's far end is a cell about length_m away by that
# way that hugs the coast; the way to it is straightened to a few waypoints, each leg checked exactly.
func _fit_route(anchor: Vector2, loop: Dictionary, why: Dictionary) -> Dictionary:
	var margin := _f("supply.margin_m")
	var loop_pts: Array[Vector2] = []
	var loop_centre := anchor
	if not loop.is_empty():
		loop_centre = loop["centre"]
		for p: Vector2 in loop["points"]:
			loop_pts.append(p)
	var min_length := _f("supply.min_length_m")
	_avoid = loop_pts
	_avoid_gap = _f("supply.loop_gap_m")
	var starts: Array[Vector2] = []
	for c0 in _centres(anchor, margin):
		if loop_pts.is_empty() or _distance_to_loop(c0, loop_pts) >= _avoid_gap:
			starts.append(c0)
	if starts.is_empty():
		why["supply_route"] = "no open water with %s m of margin, %s m from the patrol loop" % [str(margin), str(_f("supply.loop_gap_m"))]
		return {}
	# the start: the open cell nearest the anchor (and clear of the patrol loop) from which the water has a way of
	# min_length (a pocket the sea does not reach with this margin is skipped); the next such cell if that start has no
	# end whose way passes the exact check, up to supply.start_tries of them
	var seen := PackedByteArray()
	seen.resize(_cols * _rows)
	var longest := 0.0
	var tried_starts := 0
	for c0 in starts:
		var s_idx := _cell_index(c0)
		if seen[s_idx] == 1:
			continue
		var way := _ways(s_idx, margin)
		var d_all: PackedFloat64Array = way["dist"]
		var reach := 0.0
		for k in d_all.size():
			if d_all[k] < 1.0e8:
				reach = maxf(reach, d_all[k])
		# a start's farthest cell is at least half the water's own length away: a pocket with a reach under half the
		# minimum is too small whatever the start, so none of its cells is tried again
		if reach < 0.5 * min_length:
			for k in d_all.size():
				if d_all[k] < 1.0e8:
					seen[k] = 1
		longest = maxf(longest, reach)
		if reach < min_length:
			continue
		var found := _route_from(s_idx, way, loop_centre, margin)
		if not found.is_empty():
			return found
		tried_starts += 1
		if tried_starts >= int(_f("supply.start_tries")):
			break
	if tried_starts == 0:
		why["supply_route"] = "no open water with %s m of margin has a way of %s m (the longest is %s m)" % [str(margin), str(min_length), str(snappedf(longest, 1.0))]
	else:
		why["supply_route"] = "no end of the %d starts tried had a way that passes the exact check" % tried_starts
	return {}

# The route from a start whose ways by water are known ({dist, parent}): its far end is a cell the water reaches in at
# least min_length and at most length_m that hugs the coast (the farthest of those, the one farther from the loop among
# equals; else the farthest cell there is); the way to it is straightened and checked exactly. {} if none of the
# supply.tries best ends has a way that passes.
func _route_from(start_idx: int, way: Dictionary, loop_centre: Vector2, margin: float) -> Dictionary:
	var dist: PackedFloat64Array = way["dist"]
	var parent: PackedInt32Array = way["parent"]
	var length := _f("supply.length_m")
	var min_length := _f("supply.min_length_m")
	var hug := margin + _f("supply.coast_slack_m") + _f("supply.coast_tolerance_m")
	var ends: Array = []
	for idx in dist.size():
		if dist[idx] < 1.0e8 and dist[idx] >= min_length and dist[idx] <= length + 1e-6 and idx != start_idx:
			var c := _cell_pos(idx % _cols, idx / _cols)
			var hugs := 0 if _coast[idx] - 0.5 * _g <= hug else 1
			ends.append([hugs, -dist[idx], -c.distance_squared_to(loop_centre), idx])
	ends.sort_custom(func(a: Array, b: Array) -> bool:
		for k in 4:
			if a[k] != b[k]:
				return a[k] < b[k]
		return false)
	var tries := 0
	for e: Array in ends:
		if tries >= int(_f("supply.tries")):
			break
		tries += 1
		var chain: Array[Vector2] = []
		var at: int = e[3]
		while at != -1:
			chain.push_front(_cell_pos(at % _cols, at / _cols))
			at = parent[at]
		var pts := _straighten(chain, margin)
		if pts.size() < 2 or not _exact_ok(pts, false, margin):
			continue
		var headings: Array[float] = []
		var total := 0.0
		for i in pts.size() - 1:
			total += pts[i].distance_to(pts[i + 1])
		# the heading of a point is the bearing of the next on the way out, and of the one before the last on the way back
		for i in pts.size():
			var q := pts[i + 1] if i < pts.size() - 1 else pts[i - 1]
			headings.append(JsMath.atan2(q.y - pts[i].y, q.x - pts[i].x))
		return {"ok": true, "kind": "shuttle", "points": pts, "headings": headings, "length_m": total, "margin_m": margin, "min_depth_m": _min_depth(pts, false)}
	return {}

static func _distance_to_loop(p: Vector2, pts: Array[Vector2]) -> float:
	var best := INF
	for i in pts.size():
		best = minf(best, _point_segment(p, pts[i], pts[(i + 1) % pts.size()]))
	return best

func _cell_index(p: Vector2) -> int:
	var i := clampi(roundi((p.x - _inset.position.x) / _g), 0, _cols - 1)
	var j := clampi(roundi((p.y - _inset.position.y) / _g), 0, _rows - 1)
	return j * _cols + i

# Dijkstra over the cells with at least `margin` of clearance, from `start`: {dist: PackedFloat64Array (1e9 where
# unreached), parent: PackedInt32Array (-1 for the start and the unreached)}. Eight neighbours; a diagonal needs both of
# the cells it passes between.
func _ways(start: int, margin: float) -> Dictionary:
	var n := _cols * _rows
	var dist := PackedFloat64Array()
	dist.resize(n)
	dist.fill(1.0e9)
	var parent := PackedInt32Array()
	parent.resize(n)
	parent.fill(-1)
	var passable := PackedByteArray()
	passable.resize(n)
	for idx in n:
		var ok_cell := _open[idx] == 1 and _clear[idx] - 0.5 * _g >= margin + _f("grid_slack_m")
		if ok_cell and not _avoid.is_empty() and _distance_to_loop(_cell_pos(idx % _cols, idx / _cols), _avoid) < _avoid_gap:
			ok_cell = false
		passable[idx] = 1 if ok_cell else 0
	var done := PackedByteArray()
	done.resize(n)
	var heap_cost := PackedFloat64Array()
	var heap_idx := PackedInt32Array()
	dist[start] = 0.0
	_heap_push(heap_cost, heap_idx, 0.0, start)
	var diag := _g * 1.41421356
	while heap_idx.size() > 0:
		var idx := _heap_pop(heap_cost, heap_idx)
		if done[idx] == 1:
			continue   # a stale entry: the cell was already settled by a shorter one
		done[idx] = 1
		var cost: float = dist[idx]
		var ci := idx % _cols
		var cj := idx / _cols
		for dj in range(-1, 2):
			for di in range(-1, 2):
				if di == 0 and dj == 0:
					continue
				var ni := ci + di
				var nj := cj + dj
				if ni < 0 or nj < 0 or ni >= _cols or nj >= _rows:
					continue
				var nidx := nj * _cols + ni
				if passable[nidx] == 0:
					continue
				var step := _g
				if di != 0 and dj != 0:
					if passable[cj * _cols + ni] == 0 or passable[nj * _cols + ci] == 0:
						continue
					step = diag
				var nd := cost + step
				if nd < dist[nidx] - 1e-9:
					dist[nidx] = nd
					parent[nidx] = idx
					_heap_push(heap_cost, heap_idx, nd, nidx)
	return {"dist": dist, "parent": parent}

# A binary min-heap on two parallel arrays (cost, index). Ties are broken by the index, so the order is deterministic.
static func _heap_less(c: PackedFloat64Array, ix: PackedInt32Array, a: int, b: int) -> bool:
	if c[a] != c[b]:
		return c[a] < c[b]
	return ix[a] < ix[b]

static func _heap_push(c: PackedFloat64Array, ix: PackedInt32Array, cost: float, idx: int) -> void:
	c.append(cost)
	ix.append(idx)
	var k := c.size() - 1
	while k > 0:
		var up := (k - 1) / 2
		if not _heap_less(c, ix, k, up):
			break
		var tc := c[k]
		var ti := ix[k]
		c[k] = c[up]
		ix[k] = ix[up]
		c[up] = tc
		ix[up] = ti
		k = up

static func _heap_pop(c: PackedFloat64Array, ix: PackedInt32Array) -> int:
	var out := ix[0]
	var last := c.size() - 1
	c[0] = c[last]
	ix[0] = ix[last]
	c.resize(last)
	ix.resize(last)
	var k := 0
	var n := c.size()
	while true:
		var l := 2 * k + 1
		var r := l + 1
		var m := k
		if l < n and _heap_less(c, ix, l, m):
			m = l
		if r < n and _heap_less(c, ix, r, m):
			m = r
		if m == k:
			break
		var tc := c[k]
		var ti := ix[k]
		c[k] = c[m]
		ix[k] = ix[m]
		c[m] = tc
		ix[m] = ti
		k = m
	return out

# The chain of cell centres straightened to waypoints: Douglas-Peucker to simplify_m, a leg that fails the exact check
# split at the chain's point farthest from it (down to single steps).
func _straighten(chain: Array[Vector2], margin: float) -> Array[Vector2]:
	var tol := _f("supply.simplify_m")
	var keep := PackedByteArray()
	keep.resize(chain.size())
	keep[0] = 1
	keep[chain.size() - 1] = 1
	var stack: Array = [[0, chain.size() - 1]]
	while not stack.is_empty():
		var seg: Array = stack.pop_back()
		var a: int = seg[0]
		var b: int = seg[1]
		if b - a < 2:
			continue
		var far_i := -1
		var far_d := -1.0
		for i in range(a + 1, b):
			var d := _point_segment(chain[i], chain[a], chain[b])
			if d > far_d:
				far_d = d
				far_i = i
		var leg: Array[Vector2] = _pair(chain[a], chain[b])
		if far_d > tol or not _exact_ok(leg, false, margin) or not _clear_of_avoided(leg):
			keep[far_i] = 1
			stack.append([a, far_i])
			stack.append([far_i, b])
	var out: Array[Vector2] = []
	for i in chain.size():
		if keep[i] == 1:
			out.append(chain[i])
	return out

# Does a leg keep `_avoid_gap` (less a cell's slack) away from the polyline the route avoids?
func _clear_of_avoided(leg: Array[Vector2]) -> bool:
	if _avoid.is_empty():
		return true
	for p in _samples(leg, false):
		if _distance_to_loop(p, _avoid) < _avoid_gap - _f("grid_slack_m"):
			return false
	return true

static func _point_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)
