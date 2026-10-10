extends RefCounted

# HOW THE BOMB CONE AND THE AIM MARK ARE DRAWN (Track U3, the strike, 2026-10-10): the four
# looks of variants/bomb-aim/, as statics over a RECORD, so the game's node (bomb_aim.gd) and
# a board (scripts/ui/bomb_aim_board_shot.gd) draw the very same marks. EVERY LOOK AND VALUE
# IS PROPOSED; Alex chooses from the board. Data: data/ui/ui.json bombs.aim.
#
#   BombAimArt.draw(canvas_item, rec, style, mode)    # mode "" = the data's (bombs.aim.mode)
#
# THE RECORD, all in the canvas item's (screen px) space:
#   cone      PackedVector2Array   the step's bomb cone: where its release can put the bombs
#   aim       Vector2              the aim point (inside the cone)
#   ideal     Vector2              the ideal aim (INF: none)
#   release   Vector2              where on the step's path the bomb leaves for this aim (INF: none)
#   spread    {a, b, angle}        the expected spread: semi-axes in px, `a` along `angle`
#   quality   float 0..1           how close the release is to the ideal (1: ideal)
#   side      String               the unit's side (the interior's accent)
#   ppm       float                screen px per metre where the cone is (the rings' scale)
#   seed      int                  a stable seed (the stipple and the scatter do not shimmer)
#   quiet     bool                 only a small mark: a step that is not the card's, another player's drop
#   label     String               lettering at the aim ("" none)
#
# THE LOOKS (bombs.aim.mode in data/ui/ui.json):
#   outline   an inked rim, a dotted fall line from the release to the aim, a dashed spread
#             ellipse: all linework, nothing filled
#   wash      the cone as a wash in the side colour, deeper toward the ideal aim; a faint inked
#             spread ellipse on it (the cone wash Alex chose for guns, used for bombs)
#   stipple   the cone in dots, thinner away from the ideal aim; the spread as a scatter of
#             dots, the places bombs may land
#   rings     range rings from the release point through the cone, the aim's own ring solid;
#             a faint wash and a solid spread ellipse
# COMMON TO ALL: the rim, the dotted fall line, the ideal mark (a small diamond), the crosshair
# at the aim. Colour: the interior is the unit's side accent, everything else is ink or paper
# (hue is reserved for paper, ink, shadow and the side accents).
#
# draw() returns how many of its parts did not reach their end (0 when all did): a runtime
# error ends a GDScript function early and silently, so a test counts on this.

const UiInk = preload("res://scripts/ui/ui_ink.gd")
const UiRoles = preload("res://scripts/ui/ui_roles.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const MODES := ["outline", "wash", "stipple", "rings"]

# TWO LAYERS, as the cone overlay has: the interior, the rim, the fall line, the spread and the ideal mark
# go UNDER the planes ("under"), the crosshair, its lettering and its hover go OVER them ("marks"): an aim on
# the tower would otherwise be covered by the tower's own drawing. `layer` "all" draws both (a board's sheet).
static func draw(ci: CanvasItem, rec: Dictionary, st: UiStyle, mode: String = "", layer: String = "all") -> int:
	var m := mode if mode != "" else st.text("bombs.aim.mode")
	var failed := 0
	var under := layer == "all" or layer == "under"
	var over := layer == "all" or layer == "marks"
	if bool(rec.get("quiet", false)):
		if under:
			failed += 0 if _quiet_under(ci, rec, st) else 1
		if over:
			failed += 0 if _crosshair(ci, rec["aim"], st, st.num("bombs.aim.quiet.mark_k"), st.num("bombs.aim.quiet.alpha")) else 1
		return failed
	if under:
		var cone: PackedVector2Array = rec["cone"]
		var accent: Color = st.side_color(str(rec.get("side", "allies")))
		if cone.size() >= 3:
			match m:
				"wash":
					failed += 0 if _wash(ci, rec, accent, st) else 1
				"stipple":
					failed += 0 if _stipple_cone(ci, rec, accent, st) else 1
				"rings":
					failed += 0 if _rings(ci, rec, accent, st) else 1
			failed += 0 if _rim(ci, rec, st) else 1
		failed += 0 if _fall_line(ci, rec, st) else 1
		failed += 0 if _spread(ci, rec, m, st) else 1
		failed += 0 if _ideal(ci, rec, st) else 1
	if over:
		failed += 0 if _crosshair(ci, rec["aim"], st, 1.0, 1.0) else 1
		failed += 0 if _label(ci, rec, st) else 1
	return failed

# The aim handle's hover, the grow-and-fill Alex picked for the step handles (planner.hover.grow): the
# handle's dot grows as the pointer comes in and fills, with a rule round it, in range; held, a core in the
# unit's side accent. `state` "near" | "range" | "drag", `approach` 0..1 (the planner's hover()).
static func draw_hover(ci: CanvasItem, c: Vector2, state: String, approach: float, side: String, st: UiStyle) -> bool:
	var ink := _role(st, "bombs.aim.mark.role")
	var paper := _role(st, "bombs.aim.halo_role")
	var dot: float = st.num("planner.step_dot_px")
	var r: float
	match state:
		"near":
			r = lerpf(dot, st.num("planner.hover.grow.near_px"), approach)
		"range":
			r = st.num("planner.hover.grow.range_px")
		_:
			r = st.num("planner.hover.grow.drag_px")
	ci.draw_circle(c, r + 1.6, paper, true, -1.0, true)
	ci.draw_circle(c, r, ink, true, -1.0, true)
	if state != "near":
		var lw: float = st.num("planner.hover.grow.line_px")
		ci.draw_arc(c, r * 0.55, 0.0, TAU, 28, paper, 1.0, true)
		ci.draw_arc(c, r + 3.2, 0.0, TAU, 40, ink, lw, true)
		if state == "drag":
			ci.draw_circle(c, r * 0.36, st.side_color(side), true, -1.0, true)
	return true

# --- Pieces ----------------------------------------------------------------------------------------

static func _role(st: UiStyle, path: String) -> Color:
	return UiRoles.resolve(st, st.lookup(path), path)

static func _ok(poly: PackedVector2Array) -> bool:
	return poly.size() >= 3 and not Geometry2D.triangulate_polygon(poly).is_empty()

static func _rim(ci: CanvasItem, rec: Dictionary, st: UiStyle) -> bool:
	var cone: PackedVector2Array = rec["cone"]
	UiInk.ink_line(ci, cone, true, _role(st, "bombs.aim.rim_role"), st.num("bombs.aim.rim_px"), int(rec.get("seed", 1)) & 0xFFFF, 0.5)
	return true

# The cone as nested copies shrunk toward the ideal aim: the more copies a point is under, the closer
# the release is to ideal there.
static func _wash(ci: CanvasItem, rec: Dictionary, accent: Color, st: UiStyle) -> bool:
	var cone: PackedVector2Array = rec["cone"]
	var ideal: Vector2 = rec["ideal"] if (rec["ideal"] as Vector2).is_finite() else _centroid(cone)
	var steps := maxi(int(st.num("bombs.aim.wash.steps")), 1)
	var a0: float = st.num("bombs.aim.wash.alpha_rim")
	var a1: float = st.num("bombs.aim.wash.alpha_centre")
	var shrink: float = st.num("bombs.aim.wash.shrink_to")
	var prev := 0.0
	for i in steps:
		var f := float(i) / float(maxi(steps - 1, 1))
		var target := lerpf(a0, a1, f)
		var inc := clampf((target - prev) / maxf(1.0 - prev, 1e-6), 0.0, 1.0)
		prev = target
		var poly := PackedVector2Array()
		var s := lerpf(1.0, shrink, f)
		for q in cone:
			poly.append(ideal + (q - ideal) * s)
		if _ok(poly):
			ci.draw_colored_polygon(poly, Color(accent.r, accent.g, accent.b, accent.a * inc))
	return true

static func _stipple_cone(ci: CanvasItem, rec: Dictionary, accent: Color, st: UiStyle) -> bool:
	var cone: PackedVector2Array = rec["cone"]
	var ideal: Vector2 = rec["ideal"] if (rec["ideal"] as Vector2).is_finite() else _centroid(cone)
	var cell: float = st.num("bombs.aim.stipple.cell_px")
	var dot: float = st.num("bombs.aim.stipple.dot_px")
	var gamma: float = st.num("bombs.aim.stipple.gamma")
	var col := Color(accent.r, accent.g, accent.b, accent.a * st.num("bombs.aim.stipple.alpha"))
	var reach := 1.0
	for q in cone:
		reach = maxf(reach, q.distance_to(ideal))
	var lo := cone[0]
	var hi := cone[0]
	for q in cone:
		lo = lo.min(q)
		hi = hi.max(q)
	var seed_value := int(rec.get("seed", 1))
	var nx := ceili((hi.x - lo.x) / cell)
	var ny := ceili((hi.y - lo.y) / cell)
	if nx * ny > 6000:
		cell *= sqrt(float(nx * ny) / 6000.0)   # a huge cone at a large scale: coarser, never slower
		nx = ceili((hi.x - lo.x) / cell)
		ny = ceili((hi.y - lo.y) / cell)
	for j in ny:
		for i in nx:
			var p := lo + Vector2((float(i) + _h01(i, j, seed_value)) * cell, (float(j) + _h01(i, j, seed_value + 7)) * cell)
			if not Geometry2D.is_point_in_polygon(p, cone):
				continue
			var closeness := pow(clampf(1.0 - p.distance_to(ideal) / reach, 0.0, 1.0), gamma)
			if _h01(i, j, seed_value + 13) < closeness:
				ci.draw_circle(p, dot, col, true, -1.0, true)
	return true

# Rings about the release point: where the range from the release to the cone is, how far the aim is.
static func _rings(ci: CanvasItem, rec: Dictionary, accent: Color, st: UiStyle) -> bool:
	var cone: PackedVector2Array = rec["cone"]
	if _ok(cone):
		ci.draw_colored_polygon(cone, Color(accent.r, accent.g, accent.b, accent.a * st.num("bombs.aim.rings.fill_alpha")))
	var rel: Vector2 = rec["release"]
	if not rel.is_finite():
		return true
	var step_px: float = st.num("bombs.aim.rings.ring_every_m") * float(rec.get("ppm", 1.0))
	if step_px < 6.0:
		step_px = 6.0
	var lo := INF
	var hi := 0.0
	for q in cone:
		lo = minf(lo, q.distance_to(rel))
		hi = maxf(hi, q.distance_to(rel))
	var ink := _role(st, "bombs.aim.rim_role")
	var col := Color(ink.r, ink.g, ink.b, ink.a * st.num("bombs.aim.rings.alpha"))
	var w: float = st.num("bombs.aim.rings.line_px")
	var d := ceilf(lo / step_px) * step_px
	var guard := 0
	while d <= hi and guard < 60:
		guard += 1
		_arc_in(ci, rel, d, cone, col, w, true, st)
		d += step_px
	var aim: Vector2 = rec["aim"]
	_arc_in(ci, rel, aim.distance_to(rel), cone, ink, st.num("bombs.aim.rim_px") + 0.4, false, st)
	return true

# The part of the circle (c, r) inside `poly`, as polylines (dashed or solid).
static func _arc_in(ci: CanvasItem, c: Vector2, r: float, poly: PackedVector2Array, col: Color, w: float, dashed: bool, st: UiStyle) -> void:
	if r < 2.0:
		return
	var n := clampi(ceili(TAU * r / 5.0), 24, 720)
	var run := PackedVector2Array()
	for i in n + 1:
		var a := TAU * float(i) / float(n)
		var p := c + Vector2(cos(a), sin(a)) * r
		if Geometry2D.is_point_in_polygon(p, poly):
			run.append(p)
		else:
			_flush(ci, run, col, w, dashed, st)
			run = PackedVector2Array()
	_flush(ci, run, col, w, dashed, st)

static func _flush(ci: CanvasItem, run: PackedVector2Array, col: Color, w: float, dashed: bool, st: UiStyle) -> void:
	if run.size() < 2:
		return
	if dashed:
		UiInk.dashed(ci, run, col, w, st.num("bombs.aim.rings.dash_px"), st.num("bombs.aim.rings.gap_px"))
	else:
		ci.draw_polyline(run, col, w, true)

# The release: a dot on the step's path and a dotted line to the aim (where the bomb falls).
static func _fall_line(ci: CanvasItem, rec: Dictionary, st: UiStyle) -> bool:
	var rel: Vector2 = rec["release"]
	if not rel.is_finite():
		return true
	var aim: Vector2 = rec["aim"]
	var col := _role(st, "bombs.aim.release.role")
	UiInk.dashed(ci, PackedVector2Array([rel, aim]), col, st.num("bombs.aim.release.tie_px"), st.num("bombs.aim.release.tie_dash_px"), st.num("bombs.aim.release.tie_gap_px"))
	ci.draw_circle(rel, st.num("bombs.aim.release.dot_px") + 1.2, _role(st, "bombs.aim.halo_role"), true, -1.0, true)
	ci.draw_circle(rel, st.num("bombs.aim.release.dot_px"), col, true, -1.0, true)
	return true

static func ellipse_pts(c: Vector2, a: float, b: float, angle: float, n: int = 40) -> PackedVector2Array:
	var out := PackedVector2Array()
	var ca := cos(angle)
	var sa := sin(angle)
	for i in n:
		var t := TAU * float(i) / float(n)
		var x := cos(t) * a
		var y := sin(t) * b
		out.append(c + Vector2(x * ca - y * sa, x * sa + y * ca))
	return out

static func _spread(ci: CanvasItem, rec: Dictionary, mode: String, st: UiStyle) -> bool:
	var sp: Dictionary = rec["spread"]
	var a := maxf(float(sp.get("a", 0.0)), 0.8)
	var b := maxf(float(sp.get("b", 0.0)), 0.8)
	var ang := float(sp.get("angle", 0.0))
	var aim: Vector2 = rec["aim"]
	var pts := ellipse_pts(aim, a, b, ang)
	var edge := _role(st, "bombs.aim.spread.edge_role")
	var fill := _role(st, "bombs.aim.spread.fill_role")
	var w: float = st.num("bombs.aim.spread.line_px")
	match mode:
		"outline":
			var closed_pts := UiInk.closed(pts)
			UiInk.dashed(ci, closed_pts, edge, w, st.num("bombs.aim.spread.dash_px"), st.num("bombs.aim.spread.dash_px"))
		"wash":
			if _ok(pts):
				ci.draw_colored_polygon(pts, fill)
			UiInk.ink_line(ci, pts, true, edge, w, int(rec.get("seed", 1)) & 0xFFFF, 0.35)
		"stipple":
			var n := int(st.num("bombs.aim.stipple.scatter_dots"))
			var dot: float = st.num("bombs.aim.stipple.scatter_dot_px")
			var seed_value := int(rec.get("seed", 1))
			var ca := cos(ang)
			var sa := sin(ang)
			for i in n:
				# a disc-biased scatter, deterministic: radius ~ sqrt(u), angle uniform
				var r := sqrt(_h01(i, 3, seed_value)) * (0.55 + 0.45 * _h01(i, 5, seed_value))
				var t := TAU * _h01(i, 9, seed_value)
				var x := cos(t) * r * a
				var y := sin(t) * r * b
				ci.draw_circle(aim + Vector2(x * ca - y * sa, x * sa + y * ca), dot, edge, true, -1.0, true)
		_:
			UiInk.ink_line(ci, pts, true, edge, w + 0.3, int(rec.get("seed", 1)) & 0xFFFF, 0.35)
	return true

# A small diamond where the release would be ideal.
static func _ideal(ci: CanvasItem, rec: Dictionary, st: UiStyle) -> bool:
	var p: Vector2 = rec["ideal"]
	var aim: Vector2 = rec["aim"]
	if not p.is_finite() or p.distance_to(aim) < st.num("bombs.aim.mark.r_px") * 1.6:
		return true
	var s: float = st.num("bombs.aim.ideal.size_px")
	var col := _role(st, "bombs.aim.ideal.role")
	var pts := PackedVector2Array([p + Vector2(0, -s), p + Vector2(s, 0), p + Vector2(0, s), p + Vector2(-s, 0)])
	ci.draw_colored_polygon(pts, _role(st, "bombs.aim.halo_role"))
	ci.draw_polyline(UiInk.closed(pts), col, st.num("bombs.aim.ideal.line_px"), true)
	return true

# The aim: a ring with four ticks and a dot, a paper pool under it so it reads on busy ground.
static func _crosshair(ci: CanvasItem, aim: Vector2, st: UiStyle, k: float, alpha: float) -> bool:
	var r: float = st.num("bombs.aim.mark.r_px") * k
	var tick: float = st.num("bombs.aim.mark.tick_px") * k
	var gap: float = st.num("bombs.aim.mark.gap_px") * k
	var ink := _role(st, "bombs.aim.mark.role")
	ink.a *= alpha
	var halo := _role(st, "bombs.aim.halo_role")
	halo.a *= alpha
	var w: float = st.num("bombs.aim.mark.line_px")
	ci.draw_circle(aim, r + st.num("bombs.aim.mark.halo_px") * k, halo, true, -1.0, true)
	ci.draw_arc(aim, r, 0.0, TAU, 36, ink, w, true)
	for dir: Vector2 in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		ci.draw_line(aim + dir * (r - gap), aim + dir * (r + tick), ink, w, true)
	ci.draw_circle(aim, st.num("bombs.aim.mark.dot_px") * k, ink, true, -1.0, true)
	return true

# Another step's drop, or another player's: a small crosshair and a faint spread outline.
static func _quiet_under(ci: CanvasItem, rec: Dictionary, st: UiStyle) -> bool:
	var al: float = st.num("bombs.aim.quiet.alpha")
	var sp: Dictionary = rec.get("spread", {})
	if float(sp.get("a", 0.0)) > 1.0:
		var edge := _role(st, "bombs.aim.spread.edge_role")
		edge.a *= al * 0.7
		var pts := ellipse_pts(rec["aim"], float(sp["a"]), float(sp.get("b", sp["a"])), float(sp.get("angle", 0.0)), 28)
		UiInk.dashed(ci, UiInk.closed(pts), edge, st.num("bombs.aim.spread.line_px") * 0.8, 3.0, 3.0)
	return true

static func _label(ci: CanvasItem, rec: Dictionary, st: UiStyle) -> bool:
	var txt := str(rec.get("label", ""))
	if txt == "" or not st.flag("bombs.aim.label.enabled"):
		return true
	var aim: Vector2 = rec["aim"]
	var px: int = int(st.num("bombs.aim.label.px"))
	var font: Font = st.font(true)
	var pos := aim + Vector2(st.num("bombs.aim.mark.r_px") + st.num("bombs.aim.mark.tick_px") + 3.0, -st.num("bombs.aim.mark.r_px") - 2.0)
	ci.draw_string_outline(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px, int(st.num("bombs.aim.label.halo_px")), _role(st, "bombs.aim.halo_role"))
	ci.draw_string(font, pos, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, px, _role(st, "bombs.aim.label.role"))
	return true

# --- Helpers --------------------------------------------------------------------------------------------

static func _centroid(poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for q in poly:
		c += q
	return c / float(maxi(poly.size(), 1))

# 0..1 from integers: the same cell always draws the same mark.
static func _h01(i: int, j: int, salt: int) -> float:
	var h := (i * 73856093) ^ (j * 19349663) ^ (salt * 83492791)
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xFFFFFF) / 16777216.0
