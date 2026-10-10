extends RefCounted

# HOW A TARGET IS DRAWN (Track T, 2026-10-10): the mark of the target selection and of a step's target, as statics over
# plain values so the map's node (target_marks.gd), the bomb node (bomb_aim_art.gd: the small mark of another step's or
# another player's target) and a board draw the very same marks. Ink with a paper pool under it, both PALETTE ROLES from
# data/ui/ui.json target.* (no hex here; hue stays reserved for paper, ink, shadow and the side accents), sizes in
# screen px, so the mark reads at the planning zoom 0.35 and at zoom 1.
#
#   a UNIT target   four corner brackets round the unit's marker: half a side = the marker's radius + pad_px (never less
#                   than min_half_px), arms arm_px long. Distinct from the aim's crosshair (a ring with ticks) which it
#                   surrounds when a drop is aimed at the unit.
#   a POINT target  a diamond with a dot at its centre, r_px from the centre to a corner.
#   a BLOCKED mark  a slash across the mark (a drop whose target lies outside its cone), and the word beside it.
#
#   TargetArt.draw(canvas_item, "unit" | "point", screen_pt, style, radius_px, k, alpha)
#   TargetArt.slash(canvas_item, screen_pt, style, k)

const UiRoles = preload("res://scripts/ui/ui_roles.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

static func role(st: UiStyle, path: String) -> Color:
	return UiRoles.resolve(st, st.lookup(path), path)

# Draws a target mark at `at`. `radius_px` is the unit marker's screen radius (a unit target only); `k` scales the mark
# (1 the selection's, target.quiet.k another step's), `alpha` fades it (a unit out of sight, a quiet mark).
static func draw(ci: CanvasItem, kind: String, at: Vector2, st: UiStyle, radius_px: float = 0.0, k: float = 1.0, alpha: float = 1.0) -> bool:
	if not at.is_finite():
		return false
	var ink := role(st, "target.role")
	ink.a *= alpha
	var halo := role(st, "target.halo_role")
	halo.a *= alpha
	if kind == "unit":
		var half := maxf(st.num("target.unit.min_half_px"), radius_px + st.num("target.unit.pad_px")) * k
		var arm := st.num("target.unit.arm_px") * k
		var w := st.num("target.unit.line_px")
		var hw := w + 2.0 * st.num("target.unit.halo_px")
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				var pts := PackedVector2Array([
					at + Vector2(sx * half, sy * (half - arm)),
					at + Vector2(sx * half, sy * half),
					at + Vector2(sx * (half - arm), sy * half),
				])
				ci.draw_polyline(pts, halo, hw, true)
		for sx: float in [-1.0, 1.0]:
			for sy: float in [-1.0, 1.0]:
				var pts2 := PackedVector2Array([
					at + Vector2(sx * half, sy * (half - arm)),
					at + Vector2(sx * half, sy * half),
					at + Vector2(sx * (half - arm), sy * half),
				])
				ci.draw_polyline(pts2, ink, w, true)
		return true
	var r := st.num("target.point.r_px") * k
	var lw := st.num("target.point.line_px")
	var diamond := PackedVector2Array([at + Vector2(0.0, -r), at + Vector2(r, 0.0), at + Vector2(0.0, r), at + Vector2(-r, 0.0)])
	ci.draw_colored_polygon(diamond, halo)
	var closed := diamond.duplicate()
	closed.append(diamond[0])
	ci.draw_polyline(closed, halo, lw + 2.0 * st.num("target.point.halo_px"), true)
	ci.draw_polyline(closed, ink, lw, true)
	ci.draw_circle(at, st.num("target.point.dot_px") * k, ink, true, -1.0, true)
	return true

# A slash across a mark: the drop it belongs to will not release as aimed (or is a poor shot).
static func slash(ci: CanvasItem, at: Vector2, st: UiStyle, k: float = 1.0) -> bool:
	if not at.is_finite():
		return false
	var s := st.num("target.blocked.slash_px") * k
	var ink := role(st, "target.role")
	var halo := role(st, "target.halo_role")
	var w := st.num("target.blocked.line_px")
	ci.draw_line(at + Vector2(-s, s), at + Vector2(s, -s), halo, w + 3.0, true)
	ci.draw_line(at + Vector2(-s, s), at + Vector2(s, -s), ink, w, true)
	return true
