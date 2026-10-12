extends RefCounted

# UNIT SHAPES IN THE WORLD, AND SAMPLE POINTS ON THEM (builder LOF1, stage 1 of the lines of fire, 2026-10-11). A unit's body is a
# few boxes (data/units/<id>.json `shape`: scripts/sim/unit_def.gd shape_boxes); this puts them where the unit stands and picks the
# points a line of fire is traced to. Pure functions on plain Dictionaries and floats (float64), no nodes.
#
#   var boxes := Shapes.world_boxes(def, rules, x, y, heading, base_z)   # base_z: HeightGrid.stand_z, or a plane's band height
#   var m := Shapes.muzzle(hardpoint_vector3, x, y, heading, base_z)     # [x, y, z] of a weapon's hardpoint
#   var s := Shapes.samples(box, from_x, from_y, rules)                  # the points on the box's near side a shooter at from_x, from_y sees
#
# A WORLD BOX is {part, material (id), material_name, kind ("box" | "ring"), stamp, standable, cx, cy (centre, metres), cs, sn (cos and
# sin of the unit's heading), hl, hw (half length along the heading, half width across it -- a box), ro, ri (outer and inner radius -- a
# ring), z0, z1 (bottom and top, metres above sea level)}. The axes are the hardpoints': forward along the heading (cos h, sin h),
# right (-sin h, cos h): heading 0 along +x, positive turns clockwise on screen (y down).
#
# THE SAMPLES. A shooter sees a box as a silhouette: its width across the line of sight and its height. The silhouette is cut into
# columns (data sampling.col_spacing_m, at most max_cols) and rows (row_spacing_m, max_rows); a sample point sits at the middle of each
# slice, ON THE BOX'S NEAR FACE (the front point where a line parallel to the line of sight, at that column, meets the box: the
# point nearest the shooter), so a line to it is a line to a point of the box, not to the air beside a corner.

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")

# The unit's boxes as world boxes. `rules`: the line-of-fire rules (material ids).
static func world_boxes(def: Variant, rules: Object, x: float, y: float, heading: float, base_z: float) -> Array:
	var out: Array = []
	var cs := cos(heading)
	var sn := sin(heading)
	for sb: Dictionary in def.shape_boxes:
		var f := float(sb["forward_m"])
		var r := float(sb["right_m"])
		var kind := str(sb["kind"])
		var length := float(sb["length_m"])
		var wid := float(sb["width_m"])
		out.append({
			"part": str(sb["part"]), "material": rules.material_id(str(sb["material"])), "material_name": str(sb["material"]), "kind": kind,
			"stamp": bool(sb["stamp"]), "standable": bool(sb["standable"]),
			"cx": x + f * cs - r * sn, "cy": y + f * sn + r * cs, "cs": cs, "sn": sn,
			"hl": length * 0.5 if kind == "box" else 0.0, "hw": wid * 0.5 if kind == "box" else 0.0,
			"ro": length * 0.5 if kind == "ring" else 0.0, "ri": wid * 0.5 if kind == "ring" else 0.0,
			"z0": base_z + float(sb["bottom_m"]), "z1": base_z + float(sb["top_m"]),
		})
	return out

# A hardpoint [forward, right, up] on a unit: [x, y, z] in the world.
static func muzzle(hardpoint: Vector3, x: float, y: float, heading: float, base_z: float) -> PackedFloat64Array:
	var cs := cos(heading)
	var sn := sin(heading)
	var f := float(hardpoint.x)
	var r := float(hardpoint.y)
	return PackedFloat64Array([x + f * cs - r * sn, y + f * sn + r * cs, base_z + float(hardpoint.z)])

# The horizontal extent of a world box (metres), with a hair of margin.
static func bounds(b: Dictionary) -> Rect2:
	var ex: float
	var ey: float
	if str(b["kind"]) == "ring":
		ex = float(b["ro"])
		ey = ex
	else:
		ex = absf(float(b["hl"]) * float(b["cs"])) + absf(float(b["hw"]) * float(b["sn"]))
		ey = absf(float(b["hl"]) * float(b["sn"])) + absf(float(b["hw"]) * float(b["cs"]))
	return Rect2(float(b["cx"]) - ex - 0.05, float(b["cy"]) - ey - 0.05, 2.0 * ex + 0.1, 2.0 * ey + 0.1)

# Is the point (px, py) inside the box's footprint (a ring: between its two radii)?
static func contains(b: Dictionary, px: float, py: float) -> bool:
	var dx := px - float(b["cx"])
	var dy := py - float(b["cy"])
	if str(b["kind"]) == "ring":
		var d2 := dx * dx + dy * dy
		var ro := float(b["ro"])
		var ri := float(b["ri"])
		return d2 <= ro * ro and d2 >= ri * ri
	var cs := float(b["cs"])
	var sn := float(b["sn"])
	var lx := dx * cs + dy * sn
	var ly := -dx * sn + dy * cs
	return absf(lx) <= float(b["hl"]) and absf(ly) <= float(b["hw"])

# The sample points on a world box for a shooter at (from_x, from_y): {pts: PackedFloat64Array [x, y, z, ...] column by column, rows,
# cols, width (the silhouette's, metres), height, area (width x height)}.
static func samples(b: Dictionary, from_x: float, from_y: float, rules: Object) -> Dictionary:
	var cx := float(b["cx"])
	var cy := float(b["cy"])
	var cs := float(b["cs"])
	var sn := float(b["sn"])
	var dx := from_x - cx
	var dy := from_y - cy
	var l := sqrt(dx * dx + dy * dy)
	if l < 1e-9:
		dx = 1.0
		dy = 0.0
	else:
		dx /= l
		dy /= l
	var ux := -dy
	var uy := dx
	var ring := str(b["kind"]) == "ring"
	var pw: float
	if ring:
		pw = float(b["ro"])
	else:
		pw = absf(float(b["hl"]) * (cs * ux + sn * uy)) + absf(float(b["hw"]) * (-sn * ux + cs * uy))
	var z0 := float(b["z0"])
	var height := float(b["z1"]) - z0
	var rows := clampi(ceili(height / rules.row_spacing_m - 1e-9), 1, rules.max_rows)
	var cols := clampi(ceili(2.0 * pw / rules.col_spacing_m - 1e-9), 1, rules.max_cols)
	var pts := PackedFloat64Array()
	for j in cols:
		var s := -pw + (float(j) + 0.5) * (2.0 * pw / float(cols))
		var t := 0.0
		if ring:
			t = sqrt(maxf(float(b["ro"]) * float(b["ro"]) - s * s, 0.0))
		else:
			# the line c + u*s + d*t in the box's own axes, against the slabs |x| <= hl and |y| <= hw; the largest t is the near face
			var p0x := ux * s
			var p0y := uy * s
			var lx0 := p0x * cs + p0y * sn
			var ly0 := -p0x * sn + p0y * cs
			var ldx := dx * cs + dy * sn
			var ldy := -dx * sn + dy * cs
			var t_lo := -INF
			var t_hi := INF
			for ax in 2:
				var p0 := lx0 if ax == 0 else ly0
				var dir := ldx if ax == 0 else ldy
				var half := float(b["hl"]) if ax == 0 else float(b["hw"])
				if absf(dir) < 1e-12:
					if absf(p0) > half:
						t_hi = -INF
				else:
					var t1 := (-half - p0) / dir
					var t2 := (half - p0) / dir
					if t1 > t2:
						var tmp := t1
						t1 = t2
						t2 = tmp
					t_lo = maxf(t_lo, t1)
					t_hi = minf(t_hi, t2)
			t = t_hi if t_hi >= t_lo and is_finite(t_hi) else 0.0
		var qx := cx + ux * s + dx * t
		var qy := cy + uy * s + dy * t
		for k in rows:
			pts.append(qx)
			pts.append(qy)
			pts.append(z0 + (float(k) + 0.5) * height / float(rows))
	return {"pts": pts, "rows": rows, "cols": cols, "width": 2.0 * pw, "height": height, "area": 2.0 * pw * height}
