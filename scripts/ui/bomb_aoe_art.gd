extends RefCounted

# HOW THE AREA OF EFFECT OF A BOMB DROP IS DRAWN (Track T, 2026-10-10): the modes of variants/bomb-aoe/, as statics over
# the bomb mark's RECORD (bomb_aim_art.gd documents it; the `aoe` part is what this needs), so the game's node and the board
# draw the very same marks. Alex: "For bombs, I expected 'area of effect' as well." HOW it is drawn is a BOARD decision --
# nothing is chosen; EVERY MODE AND VALUE IS PROPOSED. Data: data/ui/ui.json bombs.aoe.
#
#   BombAoeArt.draw(canvas_item, rec, style, mode)    # mode "" = the data's (bombs.aoe.mode); returns parts that failed
#
# THE RECORD (screen px): lands (where the stick is centred), spread {a, b, angle} (the scatter's ellipse: `a` along `angle`,
# the bomber's heading on screen, `b` across), and aoe {tiers: [[radius_px, pips], ...] (the sim's blast table at this
# scale, nearest first), count (bombs in the stick), stick_px (its length), sigma_px (one bomb's scatter), angle}.
# Nothing is drawn for a quiet mark, for a drop that will not release (blocked: no `lands`), or without the `aoe` part.
#
# THE MODES (bombs.aoe.mode):
#   none       nothing
#   rings      the blast table's rings round the lands point, on top of the scatter: the 3-pip ring solid, the others
#              dashed, each numbered with its pips
#   footprint  ONE wash: the scatter's ellipse grown by the farthest blast tier ("anything in here takes damage")
#   impacts    the stick's bombs at their nominal places along the track, each with its own blast circle
#   tiers      (proposed by Track T) the scatter grown by each blast tier: three nested washes, darker toward more pips
#
# COLOUR. The cone beside it is the side accent; the area of effect is INK: lightness is the ramp (darker is more damage),
# the lines are ink, and no second hue is spent (palette-architecture: hue is reserved for paper, ink, shadow and accents).
# This file does not preload bomb_aim_art.gd (which calls it): a preload cycle hangs the run.

const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiRoles = preload("res://scripts/ui/ui_roles.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const MODES := ["none", "rings", "footprint", "impacts", "tiers"]

static func draw(ci: CanvasItem, rec: Dictionary, st: UiStyle, mode: String = "") -> int:
	var m := mode if mode != "" else st.text("bombs.aoe.mode")
	if m == "none" or bool(rec.get("quiet", false)) or bool(rec.get("blocked", false)) or not (rec.get("aoe") is Dictionary):
		return 0
	var lands: Vector2 = _lands(rec)
	if not lands.is_finite():
		return 0
	var aoe: Dictionary = rec["aoe"]
	var tiers: Array = aoe.get("tiers", [])
	if tiers.is_empty():
		return 0
	match m:
		"rings":
			return 0 if _rings(ci, lands, tiers, st) else 1
		"footprint":
			return 0 if _footprint(ci, lands, rec, tiers, st) else 1
		"impacts":
			return 0 if _impacts(ci, lands, aoe, tiers, st) else 1
		"tiers":
			return 0 if _tiers(ci, lands, rec, tiers, st) else 1
	return 0

static func _lands(rec: Dictionary) -> Vector2:
	var v: Variant = rec.get("lands")
	if v is Vector2 and (v as Vector2).is_finite():
		return v
	return rec.get("aim", Vector2.INF)

static func _role(st: UiStyle, path: String, alpha_k: float = 1.0) -> Color:
	var c := UiRoles.resolve(st, st.lookup(path), path)
	c.a *= alpha_k
	return c

static func _ink(st: UiStyle, alpha: float) -> Color:
	var c := _role(st, "bombs.aoe.edge_role")
	c.a = alpha
	return c

static func ellipse_pts(c: Vector2, a: float, b: float, angle: float, n: int = 48) -> PackedVector2Array:
	var out := PackedVector2Array()
	var ca := cos(angle)
	var sa := sin(angle)
	for i in n:
		var t := TAU * float(i) / float(n)
		var x := cos(t) * a
		var y := sin(t) * b
		out.append(c + Vector2(x * ca - y * sa, x * sa + y * ca))
	return out

# The scatter's ellipse (the record's spread) as a polygon round `lands`.
static func _scatter(lands: Vector2, rec: Dictionary) -> PackedVector2Array:
	var sp: Dictionary = rec.get("spread", {})
	return ellipse_pts(lands, maxf(float(sp.get("a", 0.0)), 1.0), maxf(float(sp.get("b", 0.0)), 1.0), float(sp.get("angle", 0.0)))

# The polygon grown by `r` px on every side (round joins). The first polygon of the result, or the input.
static func _grown(poly: PackedVector2Array, r: float) -> PackedVector2Array:
	var res: Array = Geometry2D.offset_polygon(poly, r, Geometry2D.JOIN_ROUND)
	var best := poly
	var best_n := 0
	for p: Variant in res:
		if p is PackedVector2Array and (p as PackedVector2Array).size() > best_n:
			best = p
			best_n = (p as PackedVector2Array).size()
	return best

static func _fill(ci: CanvasItem, poly: PackedVector2Array, col: Color) -> void:
	if poly.size() >= 3 and not Geometry2D.triangulate_polygon(poly).is_empty():
		ci.draw_colored_polygon(poly, col)

# --- The modes ---------------------------------------------------------------------------------------------

# Rings round the aim: the sim's blast table, the nearest tier solid and the others dashed, numbered with their pips.
static func _rings(ci: CanvasItem, c: Vector2, tiers: Array, st: UiStyle) -> bool:
	var w: float = st.num("bombs.aoe.line_px")
	var label_px: int = int(st.num("bombs.aoe.rings.label_px"))
	var font: Font = st.font(true)
	var halo := _role(st, "bombs.aim.halo_role")
	for i in tiers.size():
		var r := float((tiers[i] as Array)[0])
		var pips := int(round(float((tiers[i] as Array)[1])))
		var pts := UiInk.circle_pts(c, r, clampi(int(TAU * r / 4.0), 24, 160))
		pts.append(pts[0])
		if i == 0:
			var col := _ink(st, st.num("bombs.aoe.rings.solid_alpha"))
			ci.draw_polyline(pts, col, w + 0.2, true)
		else:
			UiInk.dashed(ci, pts, _ink(st, st.num("bombs.aoe.rings.dash_alpha")), w, st.num("bombs.aoe.dash_px"), st.num("bombs.aoe.dash_px"))
		if label_px > 0 and r >= st.num("bombs.aoe.rings.min_label_ring_px"):
			var pos := c + Vector2(r * 0.7071 + 2.0, -r * 0.7071 - 1.0)
			ci.draw_string_outline(font, pos, str(pips), HORIZONTAL_ALIGNMENT_LEFT, -1, label_px, 3, halo)
			ci.draw_string(font, pos, str(pips), HORIZONTAL_ALIGNMENT_LEFT, -1, label_px, _ink(st, 0.9))
	return true

# One wash: the scatter grown by the farthest tier.
static func _footprint(ci: CanvasItem, c: Vector2, rec: Dictionary, tiers: Array, st: UiStyle) -> bool:
	var reach := float((tiers[tiers.size() - 1] as Array)[0])
	var poly := _grown(_scatter(c, rec), reach)
	var fill := _role(st, "bombs.aoe.fill_role")
	fill.a = st.num("bombs.aoe.footprint.fill_alpha")
	_fill(ci, poly, fill)
	var closed := poly.duplicate()
	closed.append(poly[0])
	UiInk.dashed(ci, closed, _ink(st, st.num("bombs.aoe.tiers.outer_edge_alpha")), st.num("bombs.aoe.line_px"), st.num("bombs.aoe.dash_px"), st.num("bombs.aoe.dash_px"))
	return true

# The stick's bombs along the track, each with its own blast circle: the direct-hit ring solid, the reach faint, a dot.
static func _impacts(ci: CanvasItem, c: Vector2, aoe: Dictionary, tiers: Array, st: UiStyle) -> bool:
	var n := maxi(int(aoe.get("count", 1)), 1)
	var length := float(aoe.get("stick_px", 0.0))
	var ang := float(aoe.get("angle", 0.0))
	var dir := Vector2(cos(ang), sin(ang))
	var w: float = st.num("bombs.aoe.line_px")
	var reach := float((tiers[tiers.size() - 1] as Array)[0])
	var hit := float((tiers[0] as Array)[0])
	for i in n:
		var off := (float(i) - 0.5 * float(n - 1)) * (length / float(maxi(n - 1, 1)))
		var p := c + dir * off
		var far_pts := UiInk.circle_pts(p, reach, clampi(int(TAU * reach / 4.0), 24, 160))
		far_pts.append(far_pts[0])
		ci.draw_polyline(far_pts, _ink(st, st.num("bombs.aoe.impacts.reach_alpha")), w * 0.8, true)
	for i in n:
		var off := (float(i) - 0.5 * float(n - 1)) * (length / float(maxi(n - 1, 1)))
		var p := c + dir * off
		var hit_pts := UiInk.circle_pts(p, hit, clampi(int(TAU * hit / 3.0), 16, 96))
		hit_pts.append(hit_pts[0])
		ci.draw_polyline(hit_pts, _ink(st, st.num("bombs.aoe.impacts.hit_alpha")), w, true)
		ci.draw_circle(p, st.num("bombs.aoe.impacts.dot_px"), _ink(st, 1.0), true, -1.0, true)
	return true

# The scatter grown by each blast tier, outermost first: nested washes, darker toward more pips.
static func _tiers(ci: CanvasItem, c: Vector2, rec: Dictionary, tiers: Array, st: UiStyle) -> bool:
	var base := _scatter(c, rec)
	var alphas: Array = st.lookup("bombs.aoe.tiers.alphas")
	var fill := _role(st, "bombs.aoe.fill_role")
	var n := tiers.size()
	var inner_poly := PackedVector2Array()
	var outer_poly := PackedVector2Array()
	for k in n:
		var i := n - 1 - k   # outermost first
		var poly := _grown(base, float((tiers[i] as Array)[0]))
		fill.a = float(alphas[mini(k, alphas.size() - 1)]) if not alphas.is_empty() else 0.07
		_fill(ci, poly, fill)
		if k == 0:
			outer_poly = poly
		if i == 0:
			inner_poly = poly
	var w: float = st.num("bombs.aoe.line_px")
	if outer_poly.size() >= 3:
		var closed := outer_poly.duplicate()
		closed.append(outer_poly[0])
		UiInk.dashed(ci, closed, _ink(st, st.num("bombs.aoe.tiers.outer_edge_alpha")), w, st.num("bombs.aoe.dash_px"), st.num("bombs.aoe.dash_px"))
	if inner_poly.size() >= 3 and inner_poly != outer_poly:
		var closed2 := inner_poly.duplicate()
		closed2.append(inner_poly[0])
		ci.draw_polyline(closed2, _ink(st, st.num("bombs.aoe.tiers.inner_edge_alpha")), w, true)
	return true
