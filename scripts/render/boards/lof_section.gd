extends Node2D

# A SIDE VIEW OF A REAL LINE OF FIRE (builder LOF1, stage 1 of the lines of fire, 2026-10-11; proof 1). A DEBUGGING AID drawn from the
# real height grid, not game art: a vertical strip along the line from a gun to its target, the same cells and the same lines the
# check used. (scripts/test_support/lof_cases.gd builds a case; scripts/app/lof_shot.gd saves it.)
#
#   var s := LofSection.new()
#   s.setup(case)                  # a case dictionary (lof_cases.gd)
#   s.size_px                      # the strip's size, native
#
# WHAT IS DRAWN, left to right = metres along the line from the gun to the target, bottom to top = metres above sea level. The two
# axes have different scales (written on the strip: the tank strips stretch heights about three times so a 1.35 m wall can be seen).
#   the ground         the grid's top along the CENTRE line, a column per cell, coloured by material: ground tan, water blue, stone grey,
#                      timber brown, earthworks green; the bridge's deck purple
#   crowns             a tree whose crown the centre line goes through: a green box from its base to its top over the chord
#   the units          their boxes: hull and turret (tanks), a plane's body, the battery's guns; the gun's muzzle is the dot at the left
#   the lines          one for every sample point on the target's boxes, from the muzzle: GREEN where it reached its point, RED where it was
#                      stopped, ending in a cross at the stop, with what stopped it written once
# The strip is the centre line; the columns of samples lie up to a metre or two to its side, so a stop can be on a cell the centre line
# does not cross (it is drawn at its distance along the line).

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")

const MARGIN_L := 70.0
const MARGIN_R := 60.0
const MARGIN_T := 150.0
const MARGIN_B := 96.0
const MIN_WIDTH := 1100.0

var case: Dictionary = {}
var size_px := Vector2(800, 500)

var _grid: Object
var _origin := Vector2.ZERO   # the muzzle's x, y
var _u := Vector2.RIGHT       # the line's direction
var _len := 0.0               # to the farthest target's middle
var _d0 := 0.0                # the range drawn: from _d0 to _d1 metres along the line
var _d1 := 0.0
var _z_lo := -1.5
var _z_hi := 10.0
var _hs := 10.0
var _vs := 20.0

func setup(c: Dictionary) -> void:
	case = c
	_grid = c["grid"]
	var sh: Dictionary = c["shooter"]
	_origin = Vector2(float(sh["x"]), float(sh["y"]))
	var far := Vector2.ZERO
	var last_t: Dictionary = (c["targets"] as Array)[(c["targets"] as Array).size() - 1]
	far = Vector2(float(last_t["x"]), float(last_t["y"]))
	_u = (far - _origin).normalized()
	_len = (far - _origin).length()
	_d0 = -8.0
	_d1 = _len + 14.0
	_hs = float(c["hscale"])
	_vs = float(c["vscale"])
	# the height range: the muzzle, every box, the ground along the line
	_z_hi = float(sh["z"]) + 1.0
	for t: Dictionary in c["targets"]:
		for b: Dictionary in t["boxes"]:
			_z_hi = maxf(_z_hi, float(b["z1"]) + 1.0)
	var d := _d0
	while d <= _d1:
		_z_hi = maxf(_z_hi, float(_grid.top_at(_origin.x + _u.x * d, _origin.y + _u.y * d)) + 1.5)
		d += 1.0
	_z_lo = -1.5
	size_px = Vector2(maxf(MARGIN_L + (_d1 - _d0) * _hs + MARGIN_R, MIN_WIDTH), MARGIN_T + (_z_hi - _z_lo) * _vs + MARGIN_B)
	queue_redraw()

func _x(d: float) -> float:
	return MARGIN_L + (d - _d0) * _hs

func _y(z: float) -> float:
	return MARGIN_T + (_z_hi - z) * _vs

func _along(p: Vector2) -> float:
	return (p - _origin).dot(_u)

func _mat_color(byte: int) -> Color:
	if (byte & Rules.FLAG_DECK) != 0:
		return Color(0.55, 0.35, 0.8)
	match byte & Rules.MATERIAL_MASK:
		Rules.WATER:
			return Color(0.45, 0.65, 0.95)
		Rules.STONE:
			return Color(0.62, 0.62, 0.68)
		Rules.TIMBER:
			return Color(0.72, 0.45, 0.28)
		Rules.EARTHWORKS:
			return Color(0.45, 0.72, 0.3)
	return Color(0.84, 0.76, 0.58)

func _draw() -> void:
	if case.is_empty():
		return
	var font := ThemeDB.fallback_font
	draw_rect(Rect2(Vector2.ZERO, size_px), Color(0.96, 0.94, 0.88))
	# the ground along the centre line, column by column (a column a pixel or two wide)
	var step := maxf(0.25, 1.5 / _hs)
	var d := _d0
	var floor_y := _y(_z_lo)
	while d < _d1:
		var p := _origin + _u * (d + step * 0.5)
		var top: float = _grid.top_at(p.x, p.y)
		var byte: int = _grid.cell_byte(p.x, p.y)
		var x0 := _x(d)
		var w := step * _hs + 0.6
		draw_rect(Rect2(x0, _y(top), w, floor_y - _y(top)), _mat_color(byte))
		d += step
	# the surface line and the zero line
	draw_line(Vector2(_x(_d0), _y(0.0)), Vector2(_x(_d1), _y(0.0)), Color(0.3, 0.25, 0.15, 0.55), 1.0)
	# crowns the centre line goes through
	var mid := _origin + _u * (_len * 0.5)
	for cn: Dictionary in _grid.canopies_near(mid.x, mid.y, _len * 0.5 + 25.0):
		var rel := Vector2(float(cn["x"]), float(cn["y"])) - _origin
		var along := rel.dot(_u)
		var side := rel.cross(_u)
		var r := float(cn["r"])
		if absf(side) >= r:
			continue
		var half := sqrt(r * r - side * side)
		var a := along - half
		var b := along + half
		if b < _d0 or a > _d1:
			continue
		var rc := Rect2(_x(a), _y(float(cn["zt"])), (b - a) * _hs, (float(cn["zt"]) - float(cn["zb"])) * _vs)
		draw_rect(rc, Color(0.1, 0.55, 0.15, 0.28))
		draw_rect(rc, Color(0.05, 0.4, 0.1, 0.9), false, 1.5)
	# the units' boxes
	_draw_boxes(case["shooter_boxes"], Color(0.35, 0.4, 0.5))
	for t: Dictionary in case["targets"]:
		_draw_boxes(t["boxes"], Color(0.55, 0.3, 0.3))
		# a label over each target
		var tp := Vector2(float(t["x"]), float(t["y"]))
		var ex: Dictionary = t["exposure"]
		var top_z := -1000.0
		for b2: Dictionary in t["boxes"]:
			top_z = maxf(top_z, float(b2["z1"]))
		var txt := "%s: %.0f%% in view" % [t["label"], float(ex["share"]) * 100.0]
		draw_string(font, Vector2(minf(_x(_along(tp)) - 40.0, size_px.x - 250.0), _y(top_z) - 10.0), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.2, 0.1, 0.1))
	# the lines
	var sh: Dictionary = case["shooter"]
	var mx := _x(0.0)
	var my := _y(float(sh["z"]))
	var named: Dictionary = {}
	for t: Dictionary in case["targets"]:
		for bx: Dictionary in (t["exposure"]["boxes"] as Array):
			for ln: Dictionary in (bx["lines"] as Array):
				var to3: Vector3 = ln["to"]
				var end := Vector2(_x(_along(Vector2(to3.x, to3.y))), _y(to3.z))
				if bool(ln["reach"]):
					draw_line(Vector2(mx, my), end, Color(0.0, 0.62, 0.15, 0.8), 1.4)
					draw_circle(end, 2.5, Color(0.0, 0.62, 0.15))
				else:
					var stop: Dictionary = ln["stop"]
					var sp := Vector2(_x(_along(Vector2(float(stop["x"]), float(stop["y"])))), _y(float(stop["z"])))
					draw_line(Vector2(mx, my), sp, Color(0.85, 0.05, 0.05, 0.8), 1.4)
					draw_line(sp + Vector2(-4, -4), sp + Vector2(4, 4), Color(0.85, 0.05, 0.05), 2.0)
					draw_line(sp + Vector2(-4, 4), sp + Vector2(4, -4), Color(0.85, 0.05, 0.05), 2.0)
					var key := "%s/%s" % [stop["kind"], stop["material_name"]]
					if not named.has(key):
						named[key] = true
						var what := "a tree's crown, hit %.1f m up" % float(stop["z"])
						if stop["kind"] == "cell":
							what = "%s, %.1f m high, hit %.1f m up" % [stop["material_name"], float(stop["top"]), float(stop["z"])]
						draw_string(font, sp + Vector2(6, -6 - 13.0 * float(named.size() - 1)), "stopped by " + what, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.6, 0.0, 0.0))
	draw_circle(Vector2(mx, my), 4.0, Color(0.1, 0.1, 0.1))
	draw_string(font, Vector2(mx - 6.0, my - 10.0), "%s's gun, %.1f m" % [sh["name"], float(sh["z"])], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.1, 0.1, 0.1))
	_draw_frame(font)

func _draw_boxes(boxes: Array, line_color: Color) -> void:
	var font := ThemeDB.fallback_font
	for b: Dictionary in boxes:
		var cx := float(b["cx"])
		var cy := float(b["cy"])
		var c := Vector2(cx, cy)
		var kind := str(b["kind"])
		var z0 := float(b["z0"])
		var z1 := float(b["z1"])
		var col := Color(0.4, 0.45, 0.55, 0.75) if str(b["part"]) != "turret" else Color(0.3, 0.33, 0.42, 0.85)
		if str(b["part"]) == "body" and float(b["z0"]) > 10.0:   # a plane's box (its base is its band's height)
			col = Color(0.55, 0.55, 0.6, 0.8)
		if kind == "ring":
			# the centre line through a ring: two bags walls
			var rel := c - _origin
			var along := rel.dot(_u)
			var side := rel.cross(_u)
			var ro := float(b["ro"])
			var ri := float(b["ri"])
			if absf(side) < ro:
				var ho := sqrt(ro * ro - side * side)
				var hi := sqrt(maxf(ri * ri - side * side, 0.0)) if absf(side) < ri else 0.0
				for sgn: float in [-1.0, 1.0]:
					var a0: float = along + sgn * hi
					var a1: float = along + sgn * ho
					var rc := Rect2(_x(minf(a0, a1)), _y(z1), absf(a1 - a0) * _hs, (z1 - z0) * _vs)
					draw_rect(rc, Color(0.3, 0.6, 0.2, 0.25))
					draw_rect(rc, Color(0.15, 0.4, 0.1, 0.9), false, 1.2)
			continue
		# a box: its footprint's shadow on the line
		var cs := float(b["cs"])
		var sn := float(b["sn"])
		var hl := float(b["hl"])
		var hw := float(b["hw"])
		var dmin := 1e9
		var dmax := -1e9
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				var corner := c + Vector2(cs, sn) * (sx * hl) + Vector2(-sn, cs) * (sy * hw)
				var dd := _along(corner)
				dmin = minf(dmin, dd)
				dmax = maxf(dmax, dd)
		var rc2 := Rect2(_x(dmin), _y(z1), (dmax - dmin) * _hs, (z1 - z0) * _vs)
		draw_rect(rc2, col)
		draw_rect(rc2, line_color, false, 1.5)
		if (z1 - z0) * _vs > 14.0 and (dmax - dmin) * _hs > 40.0:
			draw_string(font, Vector2(rc2.position.x + 3.0, rc2.position.y + 12.0), str(b["part"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.95))

func _draw_frame(font: Font) -> void:
	# title and notes
	draw_string(font, Vector2(14.0, 24.0), str(case["title"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.15, 0.1, 0.05))
	var y := 44.0
	for n: String in case["notes"]:
		draw_string(font, Vector2(14.0, y), n, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.25, 0.2, 0.15))
		y += 15.0
	# a result line per target
	for t: Dictionary in case["targets"]:
		var ex: Dictionary = t["exposure"]
		var parts: PackedStringArray = []
		for bx: Dictionary in ex["boxes"]:
			parts.append("%s %d of %d lines (%.0f%%)" % [bx["part"], bx["reached"], bx["samples"], float(bx["share"]) * 100.0])
		draw_string(font, Vector2(14.0, y), "%s: %s; in view %.0f%%" % [t["label"], ", ".join(parts), float(ex["share"]) * 100.0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.1, 0.1, 0.1))
		y += 16.0
	# the axes
	var axis_col := Color(0.2, 0.15, 0.1)
	draw_line(Vector2(MARGIN_L, _y(_z_lo)), Vector2(size_px.x - MARGIN_R, _y(_z_lo)), axis_col, 1.0)
	draw_line(Vector2(MARGIN_L, MARGIN_T), Vector2(MARGIN_L, _y(_z_lo)), axis_col, 1.0)
	# metres along the line
	var tick := 10.0 if _hs >= 6.0 else (25.0 if _hs >= 2.5 else 50.0)
	var dd := ceilf(_d0 / tick) * tick
	while dd <= _d1:
		draw_line(Vector2(_x(dd), _y(_z_lo)), Vector2(_x(dd), _y(_z_lo) + 5.0), axis_col, 1.0)
		draw_string(font, Vector2(_x(dd) - 12.0, _y(_z_lo) + 19.0), "%d m" % int(dd), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, axis_col)
		dd += tick
	# metres of height
	var ztick := 1.0 if _vs >= 18.0 else (5.0 if _vs >= 4.0 else 10.0)
	var zz := 0.0
	while zz <= _z_hi:
		draw_line(Vector2(MARGIN_L - 5.0, _y(zz)), Vector2(MARGIN_L, _y(zz)), axis_col, 1.0)
		draw_string(font, Vector2(MARGIN_L - 38.0, _y(zz) + 4.0), "%d m" % int(zz), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, axis_col)
		zz += ztick
	draw_string(font, Vector2(14.0, size_px.y - 12.0), "scale: %.1f px per metre along the line, %.1f px per metre up: heights stretched x%.1f. The ground is the centre line; the sample columns lie up to 1.5 m to either side." % [_hs, _vs, _vs / _hs], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, axis_col)
	# the key
	var kx := 14.0
	var ky := size_px.y - 34.0
	for k in [["ground", Rules.GROUND], ["water", Rules.WATER], ["stone", Rules.STONE], ["timber", Rules.TIMBER], ["earthworks", Rules.EARTHWORKS], ["deck", Rules.STONE | Rules.FLAG_DECK]]:
		draw_rect(Rect2(kx, ky - 10.0, 12.0, 12.0), _mat_color(int(k[1])))
		draw_string(ThemeDB.fallback_font, Vector2(kx + 16.0, ky), str(k[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, axis_col)
		kx += 78.0
	draw_rect(Rect2(kx, ky - 10.0, 12.0, 12.0), Color(0.1, 0.55, 0.15, 0.5))
	draw_string(ThemeDB.fallback_font, Vector2(kx + 16.0, ky), "crown", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, axis_col)
