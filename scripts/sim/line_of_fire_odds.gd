extends RefCounted

# THE ODDS OF A STRAIGHT ROUND, FROM WHAT IS VISIBLE, AND WHERE IT LANDS (builder LOF2, stage 2 of the lines of fire, 2026-10-12;
# decision line-of-fire, tank-accuracy; every number is PROPOSED and lives in data/sim/line_of_fire.json `odds`). Pure functions on plain
# floats and Dictionaries: no nodes, no engine RNG, no combat stream. The model, in words:
#
#   THE SPREAD. A round fired at an aim point on the target lands somewhere in a two-dimensional normal curve about it, in the plane across
#   the line of fire. Its standard deviation is the weapon's angular spread times the distance: s = spread_mrad / 1000 x metres.
#   THE TARGET is the cells the sample lines are traced to (LineOfFire.exposure_xyz with_cells: columns across, rows up each box, hull and
#   turret apart), each a rectangle in that plane; a cell is VISIBLE when its line reached it.
#   THE CHANCE of a hit is the share of the curve that falls in the visible cells: the sum over them of
#   [Phi(right) - Phi(left)] x [Phi(top) - Phi(bottom)], each edge measured from the aim in units of s. A far or small target gets a small
#   share of the curve (accuracy falls with range, rises with size: decision tank-accuracy); a tank behind a wall is the share on its turret;
#   a target with no visible cell has chance 0 and is HELD by the caller. The AIM is the centroid of the visible cells (a gunner aims at what
#   he can see) or, by data, the middle of the whole silhouette.
#   A HIT lands on one visible cell, chosen by its share of the curve: the box it names (hull, turret) and a point on it.
#   A MISS is a draw from the curve that falls OUTSIDE the visible cells (bounded rejection sampling), and the line through it is followed
#   on to the first thing it meets: a cell's top, a canopy, the ground or the water (LineOfFire.trace), so a round that falls short lands in
#   the wall in front of the tank, one that goes high or wide lands in the ground behind it. Both are drawn from a stream of the roll's own.
#
#   var ev := Odds.assess(exposure, mx, my, mz, spread_mrad, rules)   # exposure from exposure_xyz(..., with_cells = true)
#   ev.visible, ev.p (the chance of a hit), ev.s (metres), ev.cells, ev.aim ...
#   var where := Odds.land(ev, hit, seed, lof, rules)                  # {hit_part, hx, hy, hz} or {mx, my, mz, m_material, m_kind}

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

# --- the normal curve ----------------------------------------------------------------------------------------------

# The error function, Abramowitz and Stegun 7.1.26 (absolute error under 1.5e-7). Pure arithmetic and exp, so every peer gets the same.
static func erf(x: float) -> float:
	var sgn := 1.0
	var ax := x
	if x < 0.0:
		sgn = -1.0
		ax = -x
	var t := 1.0 / (1.0 + 0.3275911 * ax)
	var poly := ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t
	return sgn * (1.0 - poly * exp(-ax * ax))

# The standard normal distribution function.
static func phi(x: float) -> float:
	return 0.5 * (1.0 + erf(x * 0.7071067811865476))

# The share of a normal curve of deviation s, centred on (cx, cy), that falls in the rectangle [x0, x1] x [y0, y1].
static func rect_mass(cx: float, cy: float, s: float, x0: float, x1: float, y0: float, y1: float) -> float:
	var inv := 1.0 / maxf(s, 1e-6)
	var mx := phi((x1 - cx) * inv) - phi((x0 - cx) * inv)
	var my := phi((y1 - cy) * inv) - phi((y0 - cy) * inv)
	return maxf(mx, 0.0) * maxf(my, 0.0)

# --- the frame across the line of fire -----------------------------------------------------------------------------

# From the muzzle (mx, my, mz) to the point (cx, cy, cz): the forward unit vector f, the lateral e1 (horizontal, across the line) and the
# vertical e2 (up in the plane across it), as [fx, fy, fz, e1x, e1y, e2x, e2y, e2z, distance].
static func frame(mx: float, my: float, mz: float, cx: float, cy: float, cz: float) -> PackedFloat64Array:
	var dx := cx - mx
	var dy := cy - my
	var dz := cz - mz
	var dist := sqrt(dx * dx + dy * dy + dz * dz)
	if dist < 1e-9:
		return PackedFloat64Array([1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1e-9])
	var fx := dx / dist
	var fy := dy / dist
	var fz := dz / dist
	var hl := sqrt(fx * fx + fy * fy)
	var e1x := 0.0
	var e1y := 1.0
	if hl > 1e-9:
		e1x = -fy / hl
		e1y = fx / hl
	# e2 = f x e1 (up when f is level): (fy*0 - fz*e1y, fz*e1x - fx*0, fx*e1y - fy*e1x)
	var e2x := -fz * e1y
	var e2y := fz * e1x
	var e2z := fx * e1y - fy * e1x
	if e2z < 0.0:
		e2x = -e2x
		e2y = -e2y
		e2z = -e2z
	return PackedFloat64Array([fx, fy, fz, e1x, e1y, e2x, e2y, e2z, dist])

# --- the assessment -----------------------------------------------------------------------------------------------

# The odds of one straight round from the muzzle (mx, my, mz), against an exposure made with cells. `spread_mrad`: the weapon's. `aim_mode`:
# "visible_centroid" | "silhouette_centre". Returns {visible, p, s, distance, aim_lat, aim_v, cells: [...], frame, p_all}; cells are
# {part, box, x, y, z, lat0, lat1, v0, v1, reach, m (its share of the curve)}. When nothing is visible: {visible: false, p: 0.0}.
static func assess(exposure: Dictionary, mx: float, my: float, mz: float, spread_mrad: float, aim_mode: String) -> Dictionary:
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	var n := 0
	var boxes: Array = exposure["boxes"]
	for b: Dictionary in boxes:
		for c: Dictionary in b["cells"]:
			sx += float(c["x"])
			sy += float(c["y"])
			sz += float(c["z"])
			n += 1
	if n == 0 or not bool(exposure["visible"]):
		return {"visible": false, "p": 0.0}
	var fr := frame(mx, my, mz, sx / n, sy / n, sz / n)
	var e1x := fr[3]
	var e1y := fr[4]
	var e2x := fr[5]
	var e2y := fr[6]
	var e2z := fr[7]
	var dist := fr[8]
	var cells: Array = []
	var bi := 0
	var vis_area := 0.0
	var vis_lat := 0.0
	var vis_v := 0.0
	var all_area := 0.0
	var all_lat := 0.0
	var all_v := 0.0
	for b: Dictionary in boxes:
		var hw := float(b["col_w"]) * 0.5
		for c: Dictionary in b["cells"]:
			var px := float(c["x"]) - mx
			var py := float(c["y"]) - my
			var pz := float(c["z"]) - mz
			var lat := px * e1x + py * e1y
			var v := px * e2x + py * e2y + pz * e2z
			var z := float(c["z"])
			var v0 := v + (float(c["zlo"]) - z) * e2z
			var v1 := v + (float(c["zhi"]) - z) * e2z
			var cell := {"part": str(b["part"]), "box": bi, "x": float(c["x"]), "y": float(c["y"]), "z": z, "lat0": lat - hw, "lat1": lat + hw, "v0": v0, "v1": v1,
				"reach": bool(c["reach"]), "m": 0.0}
			var area := (2.0 * hw) * (v1 - v0)
			var cl := lat
			var cv := (v0 + v1) * 0.5
			all_area += area
			all_lat += area * cl
			all_v += area * cv
			if bool(c["reach"]):
				vis_area += area
				vis_lat += area * cl
				vis_v += area * cv
			cells.append(cell)
		bi += 1
	var aim_lat: float
	var aim_v: float
	if aim_mode == "silhouette_centre" and all_area > 0.0:
		aim_lat = all_lat / all_area
		aim_v = all_v / all_area
	else:
		aim_lat = vis_lat / vis_area
		aim_v = vis_v / vis_area
	var s := spread_mrad * 0.001 * dist
	var p := 0.0
	var p_all := 0.0
	for cell: Dictionary in cells:
		var m := rect_mass(aim_lat, aim_v, s, float(cell["lat0"]), float(cell["lat1"]), float(cell["v0"]), float(cell["v1"]))
		p_all += m
		if bool(cell["reach"]):
			cell["m"] = m
			p += m
	return {"visible": true, "p": clampf(p, 0.0, 1.0), "p_all": p_all, "s": s, "distance": dist, "aim_lat": aim_lat, "aim_v": aim_v, "cells": cells, "frame": fr,
		"muzzle": PackedFloat64Array([mx, my, mz])}

# --- where the round goes ------------------------------------------------------------------------------------------

# Where a round lands, drawn from the stream seeded `seed` (the roll's own: never the combat dice). A hit: one visible cell, by its share of the
# curve: {hit_part, hx, hy, hz}. A miss: a draw outside the visible cells, followed to the first thing it meets with `lof` (a LineOfFire):
# {mx, my, mz, m_material, m_kind ("cell" | "canopy" | "air")}. `attempts` and `miss_run_m` are the data's (odds.landing_attempts, odds.miss_run_m).
static func land(ev: Dictionary, hit: bool, seed_value: int, lof: Object, attempts: int, miss_run_m: float) -> Dictionary:
	var rng := Mulberry32.new(seed_value)
	var cells: Array = ev["cells"]
	if hit:
		var total := 0.0
		for cell: Dictionary in cells:
			total += float(cell["m"])
		var pick := rng.next() * total
		var chosen: Dictionary = {}
		var acc := 0.0
		for cell: Dictionary in cells:
			if not bool(cell["reach"]):
				continue
			chosen = cell
			acc += float(cell["m"])
			if pick < acc:
				break
		if chosen.is_empty():
			return {}
		return {"hit_part": str(chosen["part"]), "hx": float(chosen["x"]), "hy": float(chosen["y"]), "hz": float(chosen["z"])}
	var s: float = ev["s"]
	var aim_lat: float = ev["aim_lat"]
	var aim_v: float = ev["aim_v"]
	var lat := aim_lat
	var v := aim_v
	var found := false
	var lat_lo := INF
	var lat_hi := -INF
	for cell: Dictionary in cells:
		lat_lo = minf(lat_lo, float(cell["lat0"]))
		lat_hi = maxf(lat_hi, float(cell["lat1"]))
	for _a in attempts:
		var u1 := maxf(rng.next(), 1e-12)
		var u2 := rng.next()
		var r := sqrt(-2.0 * log(u1))
		var cand_lat := aim_lat + s * r * cos(TAU * u2)
		var cand_v := aim_v + s * r * sin(TAU * u2)
		var inside := false
		for cell: Dictionary in cells:
			if bool(cell["reach"]) and cand_lat >= float(cell["lat0"]) and cand_lat <= float(cell["lat1"]) and cand_v >= float(cell["v0"]) and cand_v <= float(cell["v1"]):
				inside = true
				break
		if not inside:
			lat = cand_lat
			v = cand_v
			found = true
			break
	if not found:
		# every draw fell on a visible part (a spread wholly inside the target): the round goes just wide of the silhouette, on a side the stream picks
		var side := 1.0 if rng.next() < 0.5 else -1.0
		lat = (lat_hi + 1.0) if side > 0.0 else (lat_lo - 1.0)
		v = aim_v
	var fr: PackedFloat64Array = ev["frame"]
	var m: PackedFloat64Array = ev["muzzle"]
	var dist: float = fr[8]
	# the point where the round passes the target's depth, then on along the line through it
	var tx := m[0] + fr[0] * dist + fr[3] * lat + fr[5] * v
	var ty := m[1] + fr[1] * dist + fr[4] * lat + fr[6] * v
	var tz := m[2] + fr[2] * dist + fr[7] * v
	var dx := tx - m[0]
	var dy := ty - m[1]
	var dz := tz - m[2]
	var dl := sqrt(dx * dx + dy * dy + dz * dz)
	if dl < 1e-9:
		return {}
	var k := (dl + miss_run_m) / dl
	var ex := m[0] + dx * k
	var ey := m[1] + dy * k
	var ez := m[2] + dz * k
	var r2: Dictionary = lof.trace_xyz(m[0], m[1], m[2], ex, ey, ez, int(seed_value & 0x3FFFFFFF))
	if bool(r2["clear"]):
		return {"mx": ex, "my": ey, "mz": ez, "m_material": "air", "m_kind": "air"}
	return {"mx": float(r2["x"]), "my": float(r2["y"]), "mz": float(r2["z"]), "m_material": str(r2["material_name"]), "m_kind": str(r2["kind"])}
