extends RefCounted

# THE SIDE VIEW'S DRAWING (Track V, 2026-10-10): what side_view.gd's model looks like on paper.
# Pure static functions over a model dictionary and the style -- no nodes, no World -- so a test or a
# board can draw a model anywhere. Every colour is a palette role (data/ui/ui.json side_view), every
# size px from the same block.
#
# ALEX (decision side-view-look): the colour wash, in the top-down map's own style; the plane, the
# tower and the rest reduced to INDICATORS, no side-view art. So nothing here is a silhouette:
#   the cones      cone_overlay.gd's own draw_cones, fed side-on records -- the same wash, the same
#                  odds shading, the same fade past the effective range, the same rim and hardpoint
#                  dots (no lettering: planner.cones.label is off and a side-on record skips it)
#   the ground     one inked line
#   the plane      a small disc in its side's accent with an ink rim and a pitch tick
#   a plane target a dot in its side's accent (a ring when its bearing is off every gun's arc)
#   a ground unit  a tick standing on the ground line
#   a point        a small ink cross
#   beyond the picture   an arrow on the edge, toward it
#   a drop         the fall arc, where it lands and the spread on the ground
#
# The model (side_view.gd model()) holds px positions in the PICTURE's own space: (0, 0) its top-left.
# Each sub-draw returns true as its last act, so a runtime error that ends one early is counted
# (paint() returns how many did not reach their end).

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiRoles = preload("res://scripts/ui/ui_roles.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")

# Draws the model on `ci` and returns how many sub-draws did not reach their end (0: all did).
static func paint(ci: CanvasItem, m: Dictionary, st: UiStyle) -> int:
	var failed := 0
	var size: Vector2 = m["size"]
	ci.draw_rect(Rect2(Vector2.ZERO, size), _role(st, "paper_role"))
	failed += 0 if _ground(ci, m, st) else 1
	if str(m["mode"]) == "drop":
		failed += 0 if _drop(ci, m, st) else 1
	else:
		failed += ConeOverlay.draw_cones(ci, m["cones"], st, st.text("side_view.cone_mode"), "all")
	failed += 0 if _target(ci, m, st) else 1
	failed += 0 if _mark(ci, m, st) else 1
	failed += 0 if _frame(ci, m, st) else 1
	return failed

static func _role(st: UiStyle, key: String) -> Color:
	return UiRoles.resolve(st, st.lookup("side_view." + key), "side_view." + key)

static func _ground(ci: CanvasItem, m: Dictionary, st: UiStyle) -> bool:
	var gy: float = m["ground_y"]
	var size: Vector2 = m["size"]
	if not is_finite(gy) or gy < 0.0 or gy > size.y:
		return true
	var col := _role(st, "ground.role")
	UiInk.ink_line(ci, PackedVector2Array([Vector2(0.0, gy), Vector2(size.x, gy)]), false, col, st.num("side_view.ground.px"), 11, 0.5)
	return true

static func _frame(ci: CanvasItem, m: Dictionary, st: UiStyle) -> bool:
	var size: Vector2 = m["size"]
	UiInk.ink_line(ci, UiInk.rect_pts(Rect2(Vector2(0.5, 0.5), size - Vector2.ONE)), true, _role(st, "frame_role"), st.num("side_view.frame_px"), 3, 0.3)
	return true

# --- the plane --------------------------------------------------------------------------------

static func _mark(ci: CanvasItem, m: Dictionary, st: UiStyle) -> bool:
	var o: Vector2 = m["origin"]
	var r: float = st.num("side_view.mark.r_px")
	var accent: Color = st.side_color(str(m["side"]))
	var rim := _role(st, "mark.rim_role")
	# The pitch tick: the nose, tilted by the step's pitch (the plane always faces right on this page).
	var pitch: float = float((m["pose"] as Dictionary)["pitch"])
	var dir := Vector2(cos(pitch), -sin(pitch))
	var tick: float = st.num("side_view.mark.pitch_tick_px")
	ci.draw_line(o + dir * (r + 0.5), o + dir * (r + tick), rim, st.num("side_view.mark.pitch_tick_line_px"), true)
	ci.draw_circle(o, r, accent, true, -1.0, true)
	ci.draw_circle(o, r, rim, false, st.num("side_view.mark.rim_px"), true)
	return true

# --- the target -------------------------------------------------------------------------------

static func _target(ci: CanvasItem, m: Dictionary, st: UiStyle) -> bool:
	var t: Dictionary = m["target"]
	if t.is_empty():
		return true
	var o: Vector2 = m["origin"]
	var inside: bool = t["inside"]
	var to: Vector2 = t["px"] if inside else t["edge"]
	UiInk.dashed(ci, PackedVector2Array([o, to]), _role(st, "line.role"), st.num("side_view.line.px"),
		st.num("side_view.line.dash_px"), st.num("side_view.line.gap_px"))
	var ink := _role(st, "target.rim_role")
	var is_unit: bool = str(t["kind"]) == "unit"
	var accent: Color = st.side_color(str(t["side"])) if is_unit else ink
	if not inside:
		_arrow(ci, to, t["dir"], accent, ink, st)
		return true
	var px: Vector2 = t["px"]
	if not is_unit:
		var c: float = st.num("side_view.target.cross_px")
		var w: float = st.num("side_view.target.cross_line_px")
		ci.draw_line(px + Vector2(-c, 0.0), px + Vector2(c, 0.0), ink, w, true)
		ci.draw_line(px + Vector2(0.0, -c), px + Vector2(0.0, c), ink, w, true)
	elif bool(t["ground"]):
		# A tick standing on the ground line: an ink under-stroke, the side's accent over it.
		var h: float = st.num("side_view.target.tick_px")
		var a := px + Vector2(0.0, -h)
		var b := px + Vector2(0.0, h * 0.35)
		ci.draw_line(a, b, ink, st.num("side_view.target.tick_under_px"), true)
		ci.draw_line(a, b, accent, st.num("side_view.target.tick_line_px"), true)
	else:
		var r: float = st.num("side_view.target.r_px")
		if bool(t["hollow"]):
			ci.draw_circle(px, r, _role(st, "paper_role"), true, -1.0, true)
			ci.draw_circle(px, r - st.num("side_view.target.hollow_ring_px") * 0.5, accent, false, st.num("side_view.target.hollow_ring_px"), true)
		else:
			ci.draw_circle(px, r, accent, true, -1.0, true)
		ci.draw_circle(px, r, ink, false, st.num("side_view.target.rim_px"), true)
	return true

# A small arrow whose tip is on the edge, pointing along `dir`.
static func _arrow(ci: CanvasItem, tip: Vector2, dir: Vector2, fill: Color, ink: Color, st: UiStyle) -> void:
	var s: float = st.num("side_view.target.arrow_px")
	var nrm := Vector2(-dir.y, dir.x)
	var back := tip - dir * s
	var tri := PackedVector2Array([tip, back + nrm * s * 0.55, back - nrm * s * 0.55])
	ci.draw_colored_polygon(tri, fill)
	ci.draw_polyline(UiInk.closed(tri), ink, st.num("side_view.target.rim_px"), true)

# --- the bombs' fall -------------------------------------------------------------------------

static func _drop(ci: CanvasItem, m: Dictionary, st: UiStyle) -> bool:
	var d: Dictionary = m["drop"]
	if d.is_empty():
		return true
	var accent: Color = st.side_color(str(m["side"]))
	var gy: float = m["ground_y"]
	# The expected spread on the ground: a slim band in the side's accent.
	var band: Vector2 = d["spread_px"]
	var bh: float = st.num("side_view.drop.spread_h_px")
	# A drop the sim would not release (its target is outside the cone and the data holds) is drawn faint.
	var k: float = 1.0 if bool(d["releases"]) else st.num("side_view.drop.unreleased_alpha_k")
	var rect := Rect2(band.x, gy - bh, maxf(band.y - band.x, 1.0), bh)
	ci.draw_rect(rect, Color(accent.r, accent.g, accent.b, st.num("side_view.drop.spread_alpha") * k), true)
	UiInk.ink_line(ci, UiInk.rect_pts(rect), true, _role(st, "line.role"), 0.8, 5, 0.2)
	# The fall: bombs.gd's own arc, level across and 1 - f^2 in height.
	var arc: PackedVector2Array = d["arc"]
	if arc.size() >= 2:
		ci.draw_polyline(arc, Color(accent.r, accent.g, accent.b, st.num("side_view.drop.arc_alpha") * k), st.num("side_view.drop.arc_px"), true)
	var land: Vector2 = d["land"]
	ci.draw_arc(land, st.num("side_view.drop.land_r_px"), 0.0, TAU, 16, _role(st, "target.rim_role"), 1.0, true)
	return true
