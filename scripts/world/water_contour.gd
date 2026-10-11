extends RefCounted

# Marching squares on a regular grid for the water layer (Track WB, 2026-10-10): the closed rings
# of the region where a field is at or above a threshold. Pure and deterministic (float64 in, no
# nodes), a close cousin of scripts/world/terrain.gd's `_contour` -- the same cell rules, the same
# edge keys, the same orientation (the region on the RIGHT of every segment in screen coordinates,
# y down: an outer ring runs clockwise on screen, a hole anticlockwise) -- minus the chunk
# borders: the grid's outermost ring of nodes is forced OUTSIDE, so every contour closes inside the
# grid. A caller makes the grid larger than the view by a few cells and the false shoreline that
# forcing makes lies outside the view.
#
#   var rings := WaterContour.rings(vals, cols, rows, x0, y0, cell, thr, 2, 1.0)
#   # -> [{"pts": PackedVector2Array (metres, closed, not repeated), "area": float}]
#
# `vals` is row by row, node (i, j) at (x0 + i * cell, y0 + j * cell). Chaikin (`passes`) and
# arc-length resampling (`resample_m`, 0: none) turn the polyline into the hand-drawn curve the
# terrain's boundaries are.

const Geometry = preload("res://scripts/core/geometry.gd")

# How far under the threshold a forced-outside border node counts, for the crossing's position.
const PAD_DEPTH := 1.0

static func rings(vals: PackedFloat64Array, cols: int, rows: int, x0: float, y0: float, cell: float,
		thr: float, passes: int, resample_m: float) -> Array:
	var out: Array = []
	if cols < 3 or rows < 3:
		return out
	var n := cols * rows
	var ins := PackedByteArray()
	ins.resize(n)
	var v := PackedFloat64Array()   # the values the crossings use (border nodes pushed under)
	v.resize(n)
	for j in rows:
		for i in cols:
			var idx := j * cols + i
			var border := i == 0 or j == 0 or i == cols - 1 or j == rows - 1
			if border:
				v[idx] = minf(vals[idx], thr - PAD_DEPTH)
				ins[idx] = 0
			else:
				v[idx] = vals[idx]
				ins[idx] = 1 if vals[idx] >= thr else 0
	var next_of: Dictionary = {}
	var corner := [0, 0, 0, 0]
	var ek := [0, 0, 0, 0]
	for j in rows - 1:
		for i in cols - 1:
			corner[0] = ins[j * cols + i]
			corner[1] = ins[j * cols + i + 1]
			corner[2] = ins[(j + 1) * cols + i + 1]
			corner[3] = ins[(j + 1) * cols + i]
			var code: int = corner[0] | (corner[1] << 1) | (corner[2] << 2) | (corner[3] << 3)
			if code == 0 or code == 15:
				continue
			ek[0] = _ekey(cols, i, j, 0)
			ek[1] = _ekey(cols, i + 1, j, 1)
			ek[2] = _ekey(cols, i, j + 1, 0)
			ek[3] = _ekey(cols, i, j, 1)
			if code == 5 or code == 10:
				var mean := (v[j * cols + i] + v[j * cols + i + 1] + v[(j + 1) * cols + i + 1] + v[(j + 1) * cols + i]) / 4.0
				var centre_in := mean >= thr
				for k in 4:
					if centre_in and corner[k] == 0:
						next_of[ek[(k + 3) % 4]] = ek[k]
					elif not centre_in and corner[k] == 1:
						next_of[ek[k]] = ek[(k + 3) % 4]
			else:
				var s := 0
				while not (corner[s] == 1 and corner[(s + 3) % 4] == 0):
					s += 1
				var e := s
				while corner[(e + 1) % 4] == 1:
					e = (e + 1) % 4
				next_of[ek[e]] = ek[(s + 3) % 4]
	var seen: Dictionary = {}
	var starts: Array = next_of.keys()
	starts.sort()
	for s: int in starts:
		if seen.has(s):
			continue
		var raw := PackedFloat64Array()
		var cur: int = s
		var guard := 0
		while not seen.has(cur) and guard < 4 * n:
			seen[cur] = true
			_edge_point(raw, v, cols, x0, y0, cell, thr, cur)
			guard += 1
			if not next_of.has(cur):
				raw = PackedFloat64Array()   # an open chain cannot happen with a forced-outside border
				break
			cur = next_of[cur]
		if raw.size() < 6:
			continue
		var p := raw
		for _k in passes:
			p = Geometry.chaikin_f64(p, true)
		if resample_m > 0.0:
			var r := Geometry.resample_f64(p, resample_m, true)
			if r.size() >= 6:
				p = r
		var pts := PackedVector2Array()
		pts.resize(p.size() / 2)
		for q in pts.size():
			pts[q] = Vector2(p[q * 2], p[q * 2 + 1])
		out.append({"pts": pts, "area": area(pts)})
	return out

# Edge keys: H(i, j) joins nodes (i, j)-(i+1, j); V(i, j) joins (i, j)-(i, j+1).
static func _ekey(cols: int, i: int, j: int, dir: int) -> int:
	return (j * cols + i) * 2 + dir

static func _edge_point(out: PackedFloat64Array, v: PackedFloat64Array, cols: int, x0: float, y0: float,
		cell: float, thr: float, key: int) -> void:
	var dir := key & 1
	var node := key >> 1
	var i := node % cols
	var j := node / cols
	var va: float = v[node]
	var vb: float = v[node + 1] if dir == 0 else v[node + cols]
	var t := 0.5
	if vb != va:
		t = clampf((thr - va) / (vb - va), 0.0, 1.0)
	var xa := x0 + float(i) * cell
	var ya := y0 + float(j) * cell
	out.append(xa + (cell * t if dir == 0 else 0.0))
	out.append(ya + (cell * t if dir == 1 else 0.0))

# Shoelace area, positive for clockwise on screen (y down).
static func area(p: PackedVector2Array) -> float:
	var a := 0.0
	var n := p.size()
	for i in n:
		var j := (i + 1) % n
		a += p[i].x * p[j].y - p[j].x * p[i].y
	return a * 0.5
