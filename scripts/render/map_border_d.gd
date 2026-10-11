extends "res://scripts/render/map_border_base.gd"

# OPTION D, "Sheet on a table" (builder, map-border board, 2026-10-11; PROPOSED). The map is a sheet of paper with a slightly ragged
# (deckle) edge and a lifted shadow, lying on a darker surface that fills everything outside it.
#
#   THE TABLE: the outside fill (the paper's tint function, the map's grain) in a darker colour, NO NEW HUE: a role that steps the
#     paper down toward the ink (data d.table.role; a step toward the shadow tint is a one-line change there). Its boards are told
#     by faint seam lines (material is linework, not colour), drawn in screen px by the screen-pinned node.
#   THE DECKLE EDGE: the table's colour bitten INWARD over the map along its edge, a few metres deep, by value noise of the
#     position along it (two octaves): a ragged outline for the sheet. It also hides the last chunk's 120 m that stick out past the
#     5,000 m bounds on the right and bottom, since the table is drawn over them. A thin pale lip (the paper's thickness catching
#     the light) runs just inside it.
#   THE LIFTED SHADOW: the sheet's silhouette moved away from the sun (the map's own sun, south-east) by d.shadow.lift_m, flat, at the
#     map's shadow tint and strength with no blur -- the cards' lifted-shadow language -- laid on the table only (the part of the
#     moved silhouette outside the sheet's own).
#
# The ragged edge, the lip and the shadow are static geometry in map px, recorded ONCE (and again for a new scale); the table's
# seams repaint with the camera, like option B's rules.

const Screen = preload("res://scripts/render/map_border_screen.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

# The table's bites into the sheet: drawn with the FILL'S material, so they are the table's own tint and grain to the pixel.
class Bites extends Node2D:
	var polys: Array[PackedVector2Array] = []

	func _init() -> void:
		name = "Bites"
		z_index = 2

	func _draw() -> void:
		for poly: PackedVector2Array in polys:
			draw_colored_polygon(poly, Color.WHITE)

# The sheet's lifted shadow (on the table) and the lip of its edge.
class Sheet extends Node2D:
	var lip: Color
	var lip_w := 5.0
	var shadow: Color
	var lips: Array[PackedVector2Array] = []      # per side: the polyline of the lip
	var shadow_polys: Array[PackedVector2Array] = []

	func _init() -> void:
		name = "Sheet"
		z_index = 2

	func _draw() -> void:
		for poly: PackedVector2Array in shadow_polys:
			draw_colored_polygon(poly, shadow)
		for line: PackedVector2Array in lips:
			draw_polyline(line, lip, lip_w, true)

var _sheet: Sheet
var _bites: Bites
var _screen: Screen
var _xf := Transform2D()
var _vp := Vector2(1280, 720)
var _table: Color
var _seam_c: Color
var _seam_w := 1.0
var _board_m := 650.0
var _seam_phase := 0.37
var _amp_m := 7.0
var _step_m := 9.0
var _per_m := 0.045
var _seed := 41
var drawn := {"bite_vertices": 0, "shadow_polys": 0, "seams": 0}

func build() -> void:
	var d: CameraData = b.data
	d.text("d.name")
	_table = b.role("d.table.role")
	_seam_c = b.role("d.table.seam_role")
	_seam_w = d.num("d.table.seam_px")
	_board_m = d.num("d.table.board_m")
	_seam_phase = d.num("d.table.seam_phase")
	_amp_m = d.num("d.deckle.amplitude_m")
	_step_m = d.num("d.deckle.step_m")
	_per_m = d.num("d.deckle.per_m")
	_seed = d.integer("d.deckle.seed")
	var lip_c: Color = b.role("d.lip.role")
	var lip_w_m := d.num("d.lip.width_m")
	var shadow_c: Color = b.role("d.shadow.role")
	var lift_m := d.num("d.shadow.lift_m")
	var strength_scale := d.num("d.shadow.strength_scale")
	d.value("paper.role")   # (read, not used: the paper role tints A, B and C; D's fill is the table)
	make_fill(false, _table)
	_bites = Bites.new()
	_bites.material = fill.mat
	b.add_child(_bites)
	_sheet = Sheet.new()
	_sheet.lip = lip_c
	_sheet.lip_w = lip_w_m * b.px_per_m
	_sheet.shadow = Color(shadow_c.r, shadow_c.g, shadow_c.b, b.P.shadowStr * strength_scale)
	b.add_child(_sheet)
	_edge(lift_m)
	if _board_m > 0.0:
		_screen = Screen.new()
		_screen.z_index = 1   # over the fill (same z, later in the tree), under the sheet's shadow and edge (z 2)
		_screen.painter = Callable(self, "_paint_seams")
		b.add_child(_screen)

# The four ragged sides, the lip, the bites and the shadow, in map px.
func _edge(lift_m: float) -> void:
	var ppm: float = b.px_per_m
	var r: Rect2 = b.map_rect_px
	var step := maxf(_step_m * ppm, 2.0)
	var amp := _amp_m * ppm
	var per_px := _per_m / ppm
	var tops := PackedVector2Array()
	var rights := PackedVector2Array()
	var bots := PackedVector2Array()
	var lefts := PackedVector2Array()
	var nx := maxi(int(ceil(r.size.x / step)), 1)
	var ny := maxi(int(ceil(r.size.y / step)), 1)
	for i in nx + 1:
		var x := minf(r.position.x + float(i) * step, r.end.x)
		tops.append(Vector2(x, r.position.y + _bite(x, 0, per_px, amp)))
		bots.append(Vector2(x, r.end.y - _bite(x, 2, per_px, amp)))
	for j in ny + 1:
		var y := minf(r.position.y + float(j) * step, r.end.y)
		lefts.append(Vector2(r.position.x + _bite(y, 3, per_px, amp), y))
		rights.append(Vector2(r.end.x - _bite(y, 1, per_px, amp), y))
	# the bites: a strip of table colour from a little outside the rectangle to the ragged line
	var o := 2.0 * ppm
	_bites.polys.clear()
	_bites.polys.append(_strip(tops, true, r.position.y - o))
	_bites.polys.append(_strip(bots, true, r.end.y + o))
	_bites.polys.append(_strip(lefts, false, r.position.x - o))
	_bites.polys.append(_strip(rights, false, r.end.x + o))
	# the lip: just inside the ragged line, half its width in
	_sheet.lips.clear()
	var half := _sheet.lip_w * 0.5
	_sheet.lips.append(_shift(tops, Vector2(0, half)))
	_sheet.lips.append(_shift(bots, Vector2(0, -half)))
	_sheet.lips.append(_shift(lefts, Vector2(half, 0)))
	_sheet.lips.append(_shift(rights, Vector2(-half, 0)))
	# the sheet's outline, clockwise on screen: top left to right, right top to bottom, bottom right to left, left bottom to top
	var outline := PackedVector2Array()
	outline.append_array(tops)
	outline.append_array(rights)
	var bots_rev := bots.duplicate()
	bots_rev.reverse()
	outline.append_array(bots_rev)
	var lefts_rev := lefts.duplicate()
	lefts_rev.reverse()
	outline.append_array(lefts_rev)
	var shift: Vector2 = UiStyle.shared().shadow_dir() * lift_m * ppm
	var moved := PackedVector2Array()
	for p: Vector2 in outline:
		moved.append(p + shift)
	_sheet.shadow_polys.clear()
	for poly: PackedVector2Array in Geometry2D.clip_polygons(moved, outline):
		if poly.size() >= 3:
			_sheet.shadow_polys.append(poly)   # (a difference of two near-equal outlines has no holes; keep whatever comes back)
	drawn["bite_vertices"] = tops.size() + bots.size() + lefts.size() + rights.size()
	drawn["shadow_polys"] = _sheet.shadow_polys.size()
	_sheet.queue_redraw()
	_bites.queue_redraw()

# How deep the sheet is bitten at position `t` (map px) along side `side`: two octaves, mostly small, with the odd deeper nick.
func _bite(t: float, side: int, per_px: float, amp: float) -> float:
	var n1 := ValueNoise.vnoise(t * per_px, 0.5 + float(side), _seed + side)
	var n2 := ValueNoise.vnoise(t * per_px * 4.3, 9.5 + float(side), _seed + 7 + side)
	var v := 0.55 * n1 + 0.45 * n2
	return amp * clampf(1.7 * v * v, 0.0, 1.0)

# The polygon between the ragged line `pts` and the straight line `far` (a y for a top or bottom side, an x for a left or right one),
# which lies outside the rectangle.
static func _strip(pts: PackedVector2Array, horizontal: bool, far: float) -> PackedVector2Array:
	var poly := PackedVector2Array()
	poly.append_array(pts)
	for i in range(pts.size() - 1, -1, -1):
		poly.append(Vector2(pts[i].x, far) if horizontal else Vector2(far, pts[i].y))
	return poly

func _shift(pts: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in pts:
		out.append(p + by)
	return out

# --- the table's seams -----------------------------------------------------------------------------

func stats() -> Dictionary:
	return drawn.duplicate()

func frame(xf: Transform2D, zoom: float, vp: Vector2) -> void:
	_xf = xf
	_vp = vp
	fill.set_zoom(zoom)
	if _screen != null:
		var view: Node2D = b.view
		_screen.pin(xf * view.get_global_transform().affine_inverse())
		_screen.repaint()

# Seams along the map's x axis every board_m metres, on the table only (never across the sheet), with a little world-anchored wobble.
func _paint_seams(ci: CanvasItem) -> void:
	var r: Rect2 = b.map_rect_px
	var ppm: float = b.px_per_m
	var z: float = _xf.get_scale().x
	var step_px := _board_m * ppm
	var lo := _xf.affine_inverse() * Vector2(-20.0, -20.0)
	var hi := _xf.affine_inverse() * (_vp + Vector2(20.0, 20.0))
	var phase_px := _seam_phase * step_px
	var k := floori((lo.y - phase_px) / step_px)
	var n := 0
	var sheet_a: Vector2 = _xf * r.position
	var sheet_e: Vector2 = _xf * r.end
	while float(k) * step_px + phase_px <= hi.y:
		var wy := float(k) * step_px + phase_px
		var sy: float = (_xf * Vector2(0.0, wy)).y
		var inside_y := wy > r.position.y and wy < r.end.y
		var spans: Array = []
		if inside_y:
			spans.append([-20.0, sheet_a.x])
			spans.append([sheet_e.x, _vp.x + 20.0])
		else:
			spans.append([-20.0, _vp.x + 20.0])
		for sp: Array in spans:
			var x0: float = maxf(float(sp[0]), -20.0)
			var x1: float = minf(float(sp[1]), _vp.x + 20.0)
			if x1 <= x0:
				continue
			var pts := PackedVector2Array()
			var x := x0
			while true:
				var wob := (ValueNoise.vnoise(x / z * 0.004, float(k), 313) - 0.5) * 2.0 * 3.0
				pts.append(Vector2(x, sy + wob))
				if x >= x1:
					break
				x = minf(x + 24.0, x1)
			ci.draw_polyline(pts, _seam_c, _seam_w, true)
			n += 1
		k += 1
	drawn["seams"] = n
