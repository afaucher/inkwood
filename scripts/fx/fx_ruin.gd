extends RefCounted

# THE RADIO TOWER, and what is left of it (Track X2, the strike layer, 2026-10-10).
#
# The tower is the unit sheet's (reference/mockups/unit_sheet.html genTower / buildTower /
# drawTowerGround / drawTowerUpper): a lattice mast on four footings, tapering from 5.4-6.6 m at the
# base to 1-1.8 m at the top, 23-27 m tall, five to eight sections, X or Z bracing, a small platform
# with four aerial arms, a hut beside it with the side's recognition panel on its roof. Track U3 ports
# the standing tower into the unit markers; THIS FILE ports the same model (the same seed, the same
# parameters: the sheet's unitSeed(6, variant) on the scene seed) so the ruin is made of the same
# parts, drawn with the same pen, lines and weights, and a destroyed tower reads as THAT tower broken.
# `draw_standing` draws it too, for the variant boards only (the game's standing tower is U3's).
#
# THREE THINGS ARE DRAWN HERE, each baked once per scale through the drawing layer (InkCanvas):
#
#   remains   what stays at the foot of the mast, in the tower's own frame (turned by the unit's
#             heading): the scorch and crater, the footings (some cracked and shifted, some gone),
#             the leg stumps, the hut roofless or in rubble, a snapped cable, scraps of lattice
#   lattice   the mast on the ground, in the FALL frame (+x the way it fell, the base at the origin):
#             the 3D lattice of the sheet laid down by one rotation and rolled a little, broken at one or
#             two sections (the far part turned and gapped), members missing and snapped
#   collapse  the lattice at the angles it passes through while it falls: a flipbook, in the same frame
#
# The lattice is the sheet's geometry in 3D (a leg is two points with a height), so toppling it is one
# rotation of the same lines about the base, and the plan view of the result foreshortens as it should:
# the standing tower is a set of squares inside squares, the lying one a long ladder.
#
# Colours are roles (FxStyle); every number is in data/fx/fx.json (ruin options). No fire: the mast is
# not burning, it is broken, and the ground is burnt-out dirt and ink.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxBomb = preload("res://scripts/fx/fx_bomb.gd")
const FxBurst = preload("res://scripts/fx/fx_burst.gd")

const MASK32 := 0xFFFFFFFF
const TOWER_UI := 6          # the sheet's UNITS index of the radio tower (it feeds unitSeed)

class Model:
	var seed: int = 0
	var p: Dictionary = {}
	var G: Dictionary = {}

class RuinSet:
	var remains: Array = []          # Texture2D per variant, the tower's foot, turned by the unit's heading, its centre at remains_origin
	var remains_other: Array = []    # the same for any other destroyed ground unit (a battery): scorch, crater and scraps, no tower parts
	var remains_origin := Vector2.ZERO
	var lying: Array = []            # Texture2D per variant, fall frame, the base at lying_origin
	var lying_origin := Vector2.ZERO
	var collapse: Array = []         # per variant: [{t, tex}] in time order, fall frame, base at lying_origin
	var bars: Array = []             # Texture2D: a loose bar of lattice (pointing +x), for blown-apart debris
	var bar_masks: Array = []
	var bar_origin: Array = []
	var ppm: float = 1.0

static var _models: Dictionary = {}

# --- unitSeed and the model -------------------------------------------------------------------------------------------

# function unitSeed(ui,v){let h=(P.seed^Math.imul(ui+1,0x9E3779B1))|0; h=Math.imul(h^(h>>>15),0x85EBCA77);
#   h^=Math.imul(v+1,0xC2B2AE35); h^=h>>>13; return (h>>>0)%2147483647;}
static func unit_seed(scene_seed: int, ui: int, v: int) -> int:
	var h := (scene_seed ^ Mulberry32.imul(ui + 1, 0x9E3779B1)) & MASK32
	h = Mulberry32.imul(h ^ (h >> 15), 0x85EBCA77)
	h = (h ^ Mulberry32.imul(v + 1, 0xC2B2AE35)) & MASK32
	h ^= h >> 13
	return h % 2147483647

static func _r(rng: Mulberry32, a: float, b: float) -> float:
	return floorf((a + rng.next() * (b - a)) * 100.0 + 0.5) / 100.0

# genTower(rng): every draw in the sheet's order (the object literal's).
static func gen_tower(rng: Mulberry32) -> Dictionary:
	var p := {}
	p["base"] = _r(rng, 5.4, 6.6)
	p["top"] = _r(rng, 1.0, 1.8)
	p["height"] = _r(rng, 23.0, 27.0)
	p["sections"] = 5 + int(floorf(rng.next() * 4.0))
	p["brace"] = "X" if rng.next() < 0.5 else "Z"
	p["hut_w"] = _r(rng, 3.6, 4.6)
	p["hut_d"] = _r(rng, 2.6, 3.2)
	p["hut_h"] = _r(rng, 2.6, 3.2)
	var u := rng.next()
	p["hut_side"] = "west" if u < 0.5 else "north"
	p["aerial_arm"] = _r(rng, 2.2, 3.4)
	return p

static func _rectp(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])

static func _circ(cx: float, cy: float, r: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		out.push_back(Vector2(cx + cos(a) * r, cy + sin(a) * r))
	return out

static func _cen(pts: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for q in pts:
		c += q
	return c / float(maxi(pts.size(), 1))

# offsetPoly(pts, d): inset a smooth convex outline by d metres along vertex normals (d < 0 grows it).
static func _offset_poly(pts: PackedVector2Array, d: float) -> PackedVector2Array:
	var n := pts.size()
	var c := _cen(pts)
	var out := PackedVector2Array()
	for i in n:
		var a := pts[(i - 1 + n) % n]
		var b := pts[(i + 1) % n]
		var tx := b.x - a.x
		var ty := b.y - a.y
		var l := sqrt(tx * tx + ty * ty)
		if l == 0.0:
			l = 1.0
		var nx := -ty / l
		var ny := tx / l
		if (pts[i].x - c.x) * nx + (pts[i].y - c.y) * ny > 0.0:
			nx = -nx
			ny = -ny
		out.push_back(Vector2(pts[i].x + nx * d, pts[i].y + ny * d))
	return out

# buildTower(p): the geometry in metres, plan x/y and height z; a member is [Vector3 a, Vector3 b].
static func build_tower(p: Dictionary) -> Dictionary:
	var b2: float = float(p["base"]) / 2.0
	var t2: float = float(p["top"]) / 2.0
	var H: float = float(p["height"])
	var N: int = int(p["sections"])
	var C: Array = [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var G := {}
	var levels: Array = []
	for k in N + 1:
		levels.append(H * float(k) / float(N))
	G["levels"] = levels
	var legs: Array = []
	for c: Vector2 in C:
		legs.append([Vector3(c.x * b2, c.y * b2, 0.0), Vector3(c.x * t2, c.y * t2, H)])
	G["legs"] = legs
	var girts: Array = []
	for k in range(1, N):
		var z: float = levels[k]
		var h := b2 + (t2 - b2) * z / H
		for f in 4:
			var A: Vector2 = C[f]
			var B: Vector2 = C[(f + 1) % 4]
			girts.append([Vector3(A.x * h, A.y * h, z), Vector3(B.x * h, B.y * h, z)])
	G["girts"] = girts
	var braces: Array = []
	for f in 4:
		var A: Vector2 = C[f]
		var B: Vector2 = C[(f + 1) % 4]
		for k in N:
			var z0: float = levels[k]
			var z1: float = levels[k + 1]
			var h0 := b2 + (t2 - b2) * z0 / H
			var h1 := b2 + (t2 - b2) * z1 / H
			if p["brace"] == "X" or k % 2 == 0:
				braces.append([Vector3(A.x * h0, A.y * h0, z0), Vector3(B.x * h1, B.y * h1, z1)])
			if p["brace"] == "X" or k % 2 == 1:
				braces.append([Vector3(B.x * h0, B.y * h0, z0), Vector3(A.x * h1, A.y * h1, z1)])
	G["braces"] = braces
	var base_sq := PackedVector2Array()
	for c: Vector2 in C:
		base_sq.push_back(Vector2(c.x * b2, c.y * b2))
	G["baseSq"] = base_sq
	G["platform"] = _rectp(-t2 - 0.35, -t2 - 0.35, t2 + 0.35, t2 + 0.35)
	var arms: Array = []
	var arm: float = float(p["aerial_arm"])
	for c: Vector2 in C:
		arms.append([Vector3(c.x * (t2 + 0.35), c.y * (t2 + 0.35), H + 0.4),
			Vector3(c.x * (t2 + 0.35 + arm * 0.7), c.y * (t2 + 0.35 + arm * 0.7), H + 0.4)])
	G["arms"] = arms
	var foot: Array = []
	for c: Vector2 in C:
		foot.append(_rectp(c.x * b2 - 0.45, c.y * b2 - 0.45, c.x * b2 + 0.45, c.y * b2 + 0.45))
	G["footings"] = foot
	var hut_w: float = float(p["hut_w"])
	var hut_d: float = float(p["hut_d"])
	var off := b2 + 1.9 + hut_d / 2.0
	var west: bool = p["hut_side"] == "west"
	var hut := _rectp(-off - hut_d / 2.0, -hut_w / 2.0, -off + hut_d / 2.0, hut_w / 2.0) if west else _rectp(-hut_w / 2.0, -off - hut_d / 2.0, hut_w / 2.0, -off + hut_d / 2.0)
	G["hut"] = hut
	var hc := _cen(hut)
	var hw2 := Vector2(hut_d / 2.0, hut_w / 2.0) if west else Vector2(hut_w / 2.0, hut_d / 2.0)
	G["hutPanel"] = _rectp(hc.x - hw2.x * 0.55, hc.y - hw2.y * 0.5, hc.x + hw2.x * 0.55, hc.y + hw2.y * 0.5)
	G["hutEave"] = _offset_poly(hut, 0.3)
	G["vent"] = _circ(hc.x + hw2.x * 0.68, hc.y - hw2.y * 0.68, 0.22, 10)
	G["hutCenter"] = hc
	G["cable"] = PackedVector2Array([Vector2(hc.x + hut_d / 2.0, hc.y + 0.6), Vector2(-b2, 0.6)]) if west else PackedVector2Array([Vector2(hc.x + 0.6, hc.y + hut_d / 2.0), Vector2(0.6, -b2)])
	return G

# The sheet's tower for a scene seed and variant (cached).
static func tower_model(scene_seed: int, variant: int = 0) -> Model:
	var key := "%d|%d" % [scene_seed, variant]
	if _models.has(key):
		return _models[key]
	var m := Model.new()
	m.seed = unit_seed(scene_seed, TOWER_UI, variant)
	m.p = gen_tower(Mulberry32.new(m.seed))
	m.G = build_tower(m.p)
	_models[key] = m
	return m

# --- The ink pipeline (the sheet's pen, in pixels) -----------------------------------------------------------------------

class Ink:
	var st: FxStyle
	var lw: float
	var wob: float
	var ink: Color

static func make_ink(st: FxStyle) -> Ink:
	var k := Ink.new()
	k.st = st
	k.lw = st.line_weight()
	k.wob = st.wobble()
	k.ink = st.ink()
	return k

static func _subdivide(pts: PackedVector2Array, closed: bool, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	var lim := n if closed else n - 1
	for i in lim:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var k := maxi(1, ceili(a.distance_to(b) / step))
		for j in k:
			out.append(a + (b - a) * (float(j) / float(k)))
	if not closed:
		out.append(pts[n - 1])
	return out

static func _perim(pts: PackedVector2Array, closed: bool) -> float:
	var s := 0.0
	for i in range(1, pts.size()):
		s += pts[i].distance_to(pts[i - 1])
	if closed and pts.size() > 1:
		s += pts[pts.size() - 1].distance_to(pts[0])
	return s

static func _wobble(pts: PackedVector2Array, closed: bool, amp: float, seed_value: int) -> PackedVector2Array:
	var n := pts.size()
	if amp <= 0.0 or n < 3:
		return pts
	var per := _perim(pts, closed)
	if per == 0.0:
		per = 1.0
	var R := per * 0.055 / TAU
	var out := PackedVector2Array()
	var s := 0.0
	for i in n:
		if i > 0:
			s += pts[i].distance_to(pts[i - 1])
		var a := pts[(i - 1 + n) % n] if closed else pts[maxi(i - 1, 0)]
		var b := pts[(i + 1) % n] if closed else pts[mini(i + 1, n - 1)]
		var tx := b.x - a.x
		var ty := b.y - a.y
		var l := sqrt(tx * tx + ty * ty)
		if l == 0.0:
			l = 1.0
		var nx := -ty / l
		var ny := tx / l
		var v: float
		if closed:
			v = ValueNoise.vnoise(cos(s / per * TAU) * R + 7.0, sin(s / per * TAU) * R + 7.0, seed_value)
		else:
			v = ValueNoise.vnoise(s * 0.055, 1.7, seed_value)
		var d := (v * 2.0 - 1.0) * amp
		out.append(Vector2(pts[i].x + nx * d, pts[i].y + ny * d))
	return out

static func _add_poly(g: InkCanvas, p: PackedVector2Array, closed: bool) -> void:
	if p.is_empty():
		return
	g.move_to(p[0].x, p[0].y)
	for i in range(1, p.size()):
		g.line_to(p[i].x, p[i].y)
	if closed:
		g.close_path()

# The pen lifts where a noise value along the stroke falls under `breaks`.
static func _stroke_pts(g: InkCanvas, pts: PackedVector2Array, closed: bool, breaks: float, seed_value: int, freq: float) -> void:
	g.begin_path()
	if breaks <= 0.0:
		_add_poly(g, pts, closed)
		g.stroke()
		return
	var pen := false
	var s := 0.0
	var n := pts.size()
	var lim := n + 1 if closed else n
	for k in lim:
		var p := pts[k % n]
		if k > 0:
			s += p.distance_to(pts[(k - 1) % n])
		if ValueNoise.vnoise(s * freq, 4.1, seed_value + 3) < breaks:
			pen = false
			continue
		if not pen:
			g.move_to(p.x, p.y)
			pen = true
		else:
			g.line_to(p.x, p.y)
	g.stroke()

# An open ink line through `pts` (px), the sheet's pen.line: weight x line weight, alpha, wobble, breaks.
static func _line(g: InkCanvas, k: Ink, pts: PackedVector2Array, weight: float, alpha: float, seed_value: int, breaks: float = 0.0) -> void:
	if pts.size() < 2:
		return
	var p := _subdivide(pts, false, 2.4)
	p = _wobble(p, false, k.wob * 1.05 * minf(1.0, _perim(p, false) / 90.0), seed_value)
	g.stroke_color = k.ink
	g.line_width = weight * k.lw
	g.global_alpha = alpha
	_stroke_pts(g, p, false, breaks, seed_value + 11, 0.07)
	g.global_alpha = 1.0

# A closed ink path through `pts` (px): optional fill (alpha 0 = none), then the outline.
static func _path(g: InkCanvas, k: Ink, pts: PackedVector2Array, fill: Color, weight: float, alpha: float, seed_value: int, breaks: float = 0.0) -> PackedVector2Array:
	var p := _subdivide(pts, true, 2.4)
	p = _wobble(p, true, k.wob * 1.05 * minf(1.0, _perim(p, true) / 90.0), seed_value)
	if fill.a > 0.0:
		g.begin_path()
		_add_poly(g, p, true)
		g.fill_color = fill
		g.fill()
	if weight > 0.0:
		g.stroke_color = k.ink
		g.line_width = weight * k.lw
		g.global_alpha = alpha
		_stroke_pts(g, p, true, breaks, seed_value + 11, 0.07)
		g.global_alpha = 1.0
	return p

static func _px(pts: PackedVector2Array, at: Vector2, ppm: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in pts:
		out.push_back(Vector2(at.x + q.x * ppm, at.y + q.y * ppm))
	return out

static func _hatch_in(g: InkCanvas, k: Ink, poly: PackedVector2Array, spacing: float, alpha: float, weight: float) -> void:
	# parallel strokes across a polygon, clipped to it (the platform's hatch)
	if spacing < 0.6 or poly.size() < 3:
		return
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for q in poly:
		lo = lo.min(q)
		hi = hi.max(q)
	var c := (lo + hi) * 0.5
	var R := (hi - lo).length() * 0.5 + 1.0
	g.stroke_color = k.ink
	g.line_width = weight * k.lw
	g.global_alpha = alpha
	g.begin_path()
	var d := -R
	while d <= R:
		var seg := PackedVector2Array([Vector2(c.x - R, c.y + d), Vector2(c.x + R, c.y + d)])
		for part: PackedVector2Array in Geometry2D.clip_polyline_with_polygon(seg, poly):
			if part.size() < 2:
				continue
			g.move_to(part[0].x, part[0].y)
			for qi in range(1, part.size()):
				g.line_to(part[qi].x, part[qi].y)
		d += spacing
	g.stroke()
	g.global_alpha = 1.0

# --- The standing tower (the variant boards only: the game's is Track U3's) -----------------------------------------

# The sheet's drawTowerGround + drawTowerUpper onto one canvas, the tower's centre at `at` (px) at `ppm`, turned by `rot`
# (the marker's sprite angle, heading + 90 degrees). `accent` is the side colour of the hut roof's recognition panel.
# Roles: rock (footings), roof (hut), cream (platform, vent).
static func draw_standing(g: InkCanvas, st: FxStyle, M: Model, ppm: float, at: Vector2, accent: Color, roles: Dictionary, rot: float = 0.0) -> void:
	var k := make_ink(st)
	var G := M.G
	var seed_g := M.seed + 5
	var seed_u := M.seed + 9
	var sq := _tpp(_offset_poly(G["baseSq"], -0.6), at, ppm, rot)
	# trodden earth under the base: dirt squares at .15-.40
	var rng := Mulberry32.new(seed_g)
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for q in sq:
		lo = lo.min(q)
		hi = hi.max(q)
	var cnt := roundi((hi.x - lo.x) * (hi.y - lo.y) / 100.0 * 2.6 * 1.0)
	g.fill_color = st.palette["dirt"]
	for i in cnt:
		var x := lo.x + rng.next() * (hi.x - lo.x)
		var y := lo.y + rng.next() * (hi.y - lo.y)
		var a := 0.15 + rng.next() * 0.25
		var s := 0.6 + rng.next() * 0.8
		if Geometry2D.is_point_in_polygon(Vector2(x, y), sq):
			g.global_alpha = a
			g.fill_rect(x, y, s, s)
	g.global_alpha = 1.0
	_line(g, k, _tpp(G["cable"], at, ppm, rot), 0.6, 0.6, seed_g + 7, 0.35)
	for f: PackedVector2Array in G["footings"]:
		_path(g, k, _tpp(f, at, ppm, rot), st.color(str(roles["rock"])), 0.8, 1.0, seed_g + 13)
	var hut := _tpp(G["hut"], at, ppm, rot)
	var ho := _path(g, k, hut, st.color(str(roles["roof"])), 0.0, 1.0, seed_g + 17)
	if ppm > 3.0:
		_path(g, k, _tpp(G["hutEave"], at, ppm, rot), Color(0, 0, 0, 0), 0.5, 0.4, seed_g + 19)
	var panel := _tpp(G["hutPanel"], at, ppm, rot)
	var po := _path(g, k, panel, accent, 0.75, 1.0, seed_g + 23)
	if _perim(po, true) > 14.0:
		g.fill_color = k.ink
		g.global_alpha = 0.8
		g.begin_path()
		for q in panel:
			g.move_to(q.x + 0.55, q.y)
			g.arc(q.x, q.y, 0.55, 0.0, TAU)
		g.fill()
		g.global_alpha = 1.0
	_path(g, k, _tpp(G["vent"], at, ppm, rot), st.color(str(roles["cream"])), 0.6, 1.0, seed_g + 29)
	g.stroke_color = k.ink
	g.line_width = 1.2 * k.lw
	g.begin_path()
	_add_poly(g, ho, true)
	g.stroke()
	# the upper layer
	var n := 0
	for s: Array in G["girts"]:
		n += 1
		_line(g, k, _seg_px(s, at, ppm, rot), 0.5, 0.6, seed_u + n * 7919, 0.12)
	for s: Array in G["braces"]:
		n += 1
		_line(g, k, _seg_px(s, at, ppm, rot), 0.45, 0.62, seed_u + n * 7919)
	for s: Array in G["legs"]:
		n += 1
		_line(g, k, _seg_px(s, at, ppm, rot), 0.95, 1.0, seed_u + n * 7919)
	for s: Array in G["arms"]:
		n += 1
		_line(g, k, _seg_px(s, at, ppm, rot), 0.55, 0.8, seed_u + n * 7919)
		var q := _tp(Vector2((s[1] as Vector3).x, (s[1] as Vector3).y), at, ppm, rot)
		g.fill_color = k.ink
		g.begin_path()
		g.move_to(q.x + 0.8, q.y)
		g.arc(q.x, q.y, 0.8, 0.0, TAU)
		g.fill()
	var plat := _tpp(G["platform"], at, ppm, rot)
	var pp := _path(g, k, plat, st.color(str(roles["cream"])), 0.0, 1.0, seed_u + 101)
	_hatch_in(g, k, pp, maxf(1.3, 0.2 * ppm), 0.45, 0.45)
	g.stroke_color = k.ink
	g.line_width = 0.9 * k.lw
	g.begin_path()
	_add_poly(g, pp, true)
	g.stroke()

static func _seg_px(s: Array, at: Vector2, ppm: float, rot: float = 0.0) -> PackedVector2Array:
	var a: Vector3 = s[0]
	var b: Vector3 = s[1]
	return PackedVector2Array([_tp(Vector2(a.x, a.y), at, ppm, rot), _tp(Vector2(b.x, b.y), at, ppm, rot)])

# The standing tower's shadow for the board: the hut as a prism, the lines of the mast and the platform cast along the
# sun's direction (the sheet's maskOps), white, to be tinted by the shadow tint at the map's shadow strength.
static func draw_standing_mask(g: InkCanvas, st: FxStyle, M: Model, ppm: float, at: Vector2, rot: float = 0.0) -> void:
	var G := M.G
	var sd := st.shadow_dir()
	var kk := ppm * st.sun_len()
	g.fill_color = Color.WHITE
	g.stroke_color = Color.WHITE
	g.line_cap = "round"
	# the hut: its footprint and the same shifted by its height
	var hut := _tpp(G["hut"], at, ppm, rot)
	var sh := PackedVector2Array()
	for i in hut.size():
		sh.push_back(hut[i] + sd * float(M.p["hut_h"]) * kk)
	var hull: PackedVector2Array = Geometry2D.convex_hull(hut + sh)
	g.begin_path()
	_add_poly(g, hull, true)
	g.fill()
	for group in [[G["legs"], 0.32, 1.1], [G["girts"], 0.12, 0.7], [G["braces"], 0.12, 0.7], [G["arms"], 0.08, 0.6]]:
		g.line_width = maxf(float(group[1]) * ppm, float(group[2]))
		g.begin_path()
		for s: Array in group[0]:
			var a: Vector3 = s[0]
			var b: Vector3 = s[1]
			var pa := _tp(Vector2(a.x, a.y), at, ppm, rot) + sd * a.z * kk
			var pb := _tp(Vector2(b.x, b.y), at, ppm, rot) + sd * b.z * kk
			g.move_to(pa.x, pa.y)
			g.line_to(pb.x, pb.y)
		g.stroke()
	var H: float = float(M.p["height"])
	var plat := PackedVector2Array()
	for q: Vector2 in G["platform"]:
		plat.push_back(_tp(q, at, ppm, rot) + sd * H * kk)
	g.begin_path()
	_add_poly(g, plat, true)
	g.fill()

# --- The lattice laid down ------------------------------------------------------------------------------------------------------

# A point of the standing lattice (x, y plan; z up) after the mast has rotated by `theta` about the base toward +x
# and rolled by `roll` about its own long axis: (plan x, plan y, height).
static func _fall(P: Vector3, theta: float, roll: float) -> Vector3:
	var ct := cos(theta)
	var stt := sin(theta)
	var x1 := P.x * ct + P.z * stt
	var z1 := -P.x * stt + P.z * ct
	var y1 := P.y
	var cr := cos(roll)
	var sr := sin(roll)
	return Vector3(x1, y1 * cr - z1 * sr, y1 * sr + z1 * cr)

# Draws the mast at fall angle `theta` (0 standing, PI/2 lying) into the fall frame, the base at `at`.
# `brk` (only when lying, final): {"x": [break positions along the mast in m], "turn": [radians each], "keep_m": the
# length that remains, "drop": the fraction of members lost, "snap": the fraction of the crossing ones left as
# stubs}. `seed_v` makes the same members vanish in every frame.
static func draw_lattice(g: InkCanvas, st: FxStyle, M: Model, ppm: float, at: Vector2, theta: float, roll: float, brk: Dictionary, seed_v: int, roles: Dictionary, platform_alpha: float = 1.0) -> void:
	var k := make_ink(st)
	var G := M.G
	var rng := Mulberry32.new(seed_v)
	var xs: Array = brk.get("x", [])
	var turns: Array = brk.get("turn", [])
	var keep_m: float = float(brk.get("keep_m", 1e9))
	var wk: float = float(roles.get("wk", 1.0))
	var drop: float = float(brk.get("drop", 0.0))
	var snap: float = float(brk.get("snap", 0.0))
	var n := 0
	var groups: Array = [["girts", 0.5, 0.6, 0.12], ["braces", 0.45, 0.62, 0.0], ["legs", 0.95, 1.0, 0.0], ["arms", 0.55, 0.8, 0.0]]
	var plat_pos: Array = []
	for grp: Array in groups:
		for s: Array in G[grp[0]]:
			n += 1
			var a := _fall(s[0], theta, roll)
			var b := _fall(s[1], theta, roll)
			var lost := rng.next()
			var snapped := rng.next()
			if lost < drop and grp[0] != "legs":
				continue
			var pa := Vector2(a.x, a.y)
			var pb := Vector2(b.x, b.y)
			var skip := false
			# the break: a member that crosses it is snapped (cut short on the root side, or lost) and the
			# pieces of the mast beyond it turn about it
			for bi in xs.size():
				var xb: float = float(xs[bi])
				var ang: float = float(turns[bi])
				var piv := Vector2(xb, 0.0)
				if (pa.x - xb) * (pb.x - xb) < 0.0:
					if snapped < snap:
						var root := pa if pa.x < xb else pb
						var far := pb if pa.x < xb else pa
						var tc := (xb - root.x) / (far.x - root.x)
						pa = root
						pb = root.lerp(far, clampf(tc * (0.5 + 0.4 * snapped), 0.15, 0.95))
					else:
						skip = true
					break
				elif pa.x > xb and pb.x > xb:
					pa = _turn_about(pa, piv, ang)
					pb = _turn_about(pb, piv, ang)
			if skip:
				continue
			if maxf(pa.x, pb.x) > keep_m:
				continue
			_line(g, k, PackedVector2Array([Vector2(at.x + pa.x * ppm, at.y + pa.y * ppm), Vector2(at.x + pb.x * ppm, at.y + pb.y * ppm)]),
				float(grp[1]) * wk, minf(float(grp[2]) * (1.0 + (wk - 1.0) * 0.6), 1.0), seed_v + n * 7919, float(grp[3]))
			if grp[0] == "arms":
				var q := Vector2(at.x + pb.x * ppm, at.y + pb.y * ppm)
				g.fill_color = k.ink
				g.begin_path()
				g.move_to(q.x + 0.8, q.y)
				g.arc(q.x, q.y, 0.8, 0.0, TAU)
				g.fill()
	# the platform at the top of the mast, a square riding the last section
	var H: float = float(M.p["height"])
	var plat := PackedVector2Array()
	for q: Vector2 in G["platform"]:
		var f := _fall(Vector3(q.x, q.y, H), theta, roll)
		var pq := Vector2(f.x, f.y)
		for bi in xs.size():
			var xb: float = float(xs[bi])
			if pq.x > xb:
				pq = _turn_about(pq, Vector2(xb, _break_y(M, xb, theta, roll)), float(turns[bi]))
		plat.push_back(Vector2(at.x + pq.x * ppm, at.y + pq.y * ppm))
	var pc := _cen(plat)
	if platform_alpha > 0.0 and (_cen(plat) - at).x / ppm <= keep_m + 1.0:
		var fill: Color = st.color(str(roles["cream"]))
		fill.a *= platform_alpha
		var pp := _path(g, k, plat, fill, 0.0, 1.0, seed_v + 101)
		_hatch_in(g, k, pp, maxf(1.3, 0.2 * ppm), 0.45, 0.45)
		g.stroke_color = k.ink
		g.line_width = 0.9 * k.lw
		g.begin_path()
		_add_poly(g, pp, true)
		g.stroke()
	g.global_alpha = 1.0

# The mast's centre line lies on plan y = 0 (a roll turns it about itself).
static func _break_y(_M: Model, _xb: float, _theta: float, _roll: float) -> float:
	return 0.0

static func _turn_about(p: Vector2, c: Vector2, ang: float) -> Vector2:
	var d := p - c
	var ca := cos(ang)
	var sa := sin(ang)
	return Vector2(c.x + d.x * ca - d.y * sa, c.y + d.x * sa + d.y * ca)

# --- What stays at the foot -----------------------------------------------------------------------------------------------------

# The remains at the foot of the mast, drawn in the SCREEN's frame (the tower's centre at `at`), the tower turned by `rot`
# (the sprite angle its marker has: heading + 90 degrees, as Track U3's static art is baked), so the light on every
# piece is the map's whatever the heading. `r` is the ruin option's `remains` group.
static func draw_remains(g: InkCanvas, st: FxStyle, M: Model, r: Dictionary, ppm: float, at: Vector2, seed_v: int, rot: float = 0.0, tower: bool = true) -> void:
	var k := make_ink(st)
	var G := M.G
	var rng := Mulberry32.new(seed_v)
	var sd := -st.detail_light   # shadows fall away from the light (screen axes)
	# 1. the burnt ground: dirt stipple, thick in the middle and thinning out, ink hatch on the shadow side
	var sc := FxData.grp(r, "scorch")
	FxBurst.draw_scar(g, st, sc, FxBake.seed_of("scorch", seed_v, 1), FxData.f(r, "scorch_r_m") * ppm, at, 0.0)
	# 2. the crater, where a bomb or two came down
	var cr := FxData.grp(r, "crater")
	var cat := _tp(Vector2(FxData.f(r, "crater_dx_m"), FxData.f(r, "crater_dy_m")), at, ppm, rot)
	if FxData.f(r, "crater_r_m") > 0.0:
		FxBomb.draw_crater(g, st, cr, FxBake.seed_of("tcrater", seed_v, 2), FxData.f(r, "crater_r_m") * ppm, cat)
	var drop_c: Color = st.color(FxData.s(r, "drop_role"))
	# 3. the footings: some stay, cracked and shifted, some are gone
	var keep_f := FxData.f(r, "footings_keep")
	for f: PackedVector2Array in (G["footings"] if tower else []):
		var c0 := _cen(f)
		if rng.next() > keep_f:
			continue
		var tilt := (rng.next() - 0.5) * deg_to_rad(FxData.f(r, "footing_tilt_deg")) * 2.0
		var shift := Vector2(rng.next() - 0.5, rng.next() - 0.5) * FxData.f(r, "footing_shift_m")
		var pts := PackedVector2Array()
		for q in f:
			pts.push_back(_tp(c0 + (q - c0).rotated(tilt) + shift, at, ppm, rot))
		var shadow := PackedVector2Array()
		for q in pts:
			shadow.push_back(q + sd * maxf(1.0, ppm * 0.18))
		InkSprites.trace_path(g, shadow)
		g.fill_color = drop_c
		g.fill()
		_path(g, k, pts, st.color(FxData.s(r, "rock_role")), 0.85, 1.0, seed_v + int(rng.next() * 100000.0), 0.22)
		# a crack across it
		_line(g, k, PackedVector2Array([pts[0].lerp(pts[1], 0.4 + rng.next() * 0.2), pts[3].lerp(pts[2], 0.3 + rng.next() * 0.3)]), 0.5, 0.7, seed_v + 5)
	# 4. the leg stumps: two rails bent outward, snapped
	var stump := FxData.f(r, "stump_len_m") if tower else 0.0
	var b2 := float(M.p["base"]) / 2.0
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			var base := Vector2(float(sx) * b2, float(sy) * b2)
			var out_a := atan2(float(sy), float(sx)) + (rng.next() - 0.5) * 1.1
			var L := stump * (0.45 + rng.next() * 0.55)
			var dirv := Vector2.from_angle(out_a).rotated(rot)
			var nrm := Vector2(-dirv.y, dirv.x)
			if L <= 0.2:
				continue
			var p0 := _tp(base, at, ppm, rot)
			var rail_a := PackedVector2Array([p0 + nrm * 0.16 * ppm, p0 + nrm * 0.16 * ppm + dirv * L * ppm])
			var rail_b := PackedVector2Array([p0 - nrm * 0.16 * ppm, p0 - nrm * 0.16 * ppm + dirv * L * 0.72 * ppm])
			var sw := FxData.f(r, "stump_weight")
			_line(g, k, rail_a, 0.95 * sw, 1.0, seed_v + 31 + sx * 3 + sy)
			_line(g, k, rail_b, 0.95 * sw, 1.0, seed_v + 37 + sx * 3 + sy)
			# a rung or two between the rails, and a ragged end
			for j in 2:
				var tt := 0.3 + 0.35 * float(j)
				var ca := rail_a[0].lerp(rail_a[1], tt)
				var cb := rail_b[0].lerp(rail_b[1], minf(tt, 0.95))
				_line(g, k, PackedVector2Array([ca, cb]), 0.5 * sw, 0.8, seed_v + 41 + j)
			var e := rail_a[1]
			_line(g, k, PackedVector2Array([e, e + (dirv + nrm * 0.7) * ppm * 0.35]), 0.55, 0.85, seed_v + 47)
	# 5. the hut
	var hut_mode := FxData.s(r, "hut") if tower else "gone"
	var hutp := _tpp(G["hut"], at, ppm, rot)
	var hcen := _cen(hutp)
	if hut_mode == "roofless":
		# walls standing, the floor black, a torn roof lying across the hole
		InkSprites.trace_path(g, hutp)
		g.fill_color = st.color(FxData.s(r, "char_role"))
		g.fill()
		_path(g, k, hutp, Color(0, 0, 0, 0), 1.2, 1.0, seed_v + 53, 0.28)
		_hatch_in(g, k, hutp, maxf(1.6, 0.22 * ppm), 0.35, 0.5)
		var roof := PackedVector2Array()
		var ang := (rng.next() - 0.5) * 0.7
		var off := Vector2(0.5, -0.4) * ppm * (rng.next() + 0.2)
		for q in hutp:
			roof.push_back(hcen + (q - hcen).rotated(ang) * 0.62 + off)
		_path(g, k, roof, st.color(FxData.s(r, "roof_role")), 0.9, 1.0, seed_v + 59, 0.3)
	elif hut_mode == "rubble":
		# a heap: small broken polygons where the walls were
		for j in 7:
			var a := rng.next() * TAU
			var d := sqrt(rng.next()) * 0.8
			var c := hcen + Vector2(cos(a) * d * ppm * float(M.p["hut_d"]) * 0.7, sin(a) * d * ppm * float(M.p["hut_w"]) * 0.6)
			var poly := PackedVector2Array()
			var m := 5 + int(rng.next() * 3.0)
			var rr := ppm * (0.35 + rng.next() * 0.5)
			for q in m:
				var aa := float(q) / float(m) * TAU + (rng.next() - 0.5) * 0.7
				poly.push_back(c + Vector2(cos(aa), sin(aa)) * rr * (0.55 + rng.next() * 0.45))
			var shadow := PackedVector2Array()
			for q in poly:
				shadow.push_back(q + sd * maxf(0.9, ppm * 0.12))
			InkSprites.trace_path(g, shadow)
			g.fill_color = drop_c
			g.fill()
			_path(g, k, poly, st.color(FxData.s(r, "roof_role")) if j % 2 == 0 else st.color(FxData.s(r, "rock_role")), 0.8, 1.0, seed_v + 61 + j, 0.2)
	# "gone": nothing is drawn at the hut's place but the scorch already there
	# 6. the cable, snapped
	if tower and FxData.b(r, "cable"):
		var cab := _tpp(G["cable"], at, ppm, rot)
		var mid1 := cab[0].lerp(cab[1], 0.38)
		var mid2 := cab[0].lerp(cab[1], 0.62)
		_line(g, k, PackedVector2Array([cab[0], mid1]), 0.6, 0.6, seed_v + 67)
		_line(g, k, PackedVector2Array([mid2, cab[1]]), 0.6, 0.45, seed_v + 71, 0.3)
	# 7. scraps of lattice and twisted aerial arms lying round the base
	for j in FxData.i(r, "scraps"):
		var a := rng.next() * TAU
		var d := lerpf(FxData.f(r, "scrap_min_m"), FxData.f(r, "scrap_max_m"), rng.next())
		var c := at + Vector2(cos(a), sin(a)) * d * ppm
		var ln := (0.9 + rng.next() * 2.0) * ppm
		var dir_a := rng.next() * TAU
		var e := c + Vector2.from_angle(dir_a) * ln
		_line(g, k, PackedVector2Array([c, e]), (0.7 + rng.next() * 0.3) * FxData.f(r, "stump_weight"), 0.95, seed_v + 73 + j)
		if rng.next() < 0.5:
			var e2 := c.lerp(e, 0.5) + Vector2.from_angle(dir_a + 1.0) * ln * 0.45
			_line(g, k, PackedVector2Array([c.lerp(e, 0.5), e2]), 0.5, 0.6, seed_v + 79 + j)
	# 8. one leg left standing, leaning, with a shadow
	if tower and FxData.b(r, "stub_leg"):
		var a := rng.next() * TAU
		var base := at + Vector2(cos(a), sin(a)) * b2 * ppm * 0.9
		var hgt := FxData.f(r, "stub_h_m")
		var lean := Vector2.from_angle(a + (rng.next() - 0.5) * 1.0) * 0.12 * hgt * ppm
		var tip := base + lean
		var sh_len := hgt * st.sun_len() * ppm
		var sdv := st.shadow_dir()
		var side := Vector2(-sdv.y, sdv.x)
		var strip := PackedVector2Array([base + side * 0.2 * ppm, base - side * 0.2 * ppm, tip + sdv * sh_len - side * 0.15 * ppm, tip + sdv * sh_len + side * 0.15 * ppm])
		InkSprites.trace_path(g, strip)
		g.fill_color = drop_c
		g.fill()
		_line(g, k, PackedVector2Array([base, tip]), 1.0, 1.0, seed_v + 83)
		var nrm := Vector2(-lean.y, lean.x).normalized() * 0.25 * ppm
		_line(g, k, PackedVector2Array([base + nrm, tip + nrm]), 0.8, 1.0, seed_v + 85)
		for j in 3:
			var tt := 0.25 + 0.3 * float(j)
			_line(g, k, PackedVector2Array([base.lerp(tip, tt) + nrm, base.lerp(tip, tt + 0.1)]), 0.45, 0.6, seed_v + 89 + j)
		g.fill_color = k.ink
		g.begin_path()
		g.move_to(tip.x + 0.8, tip.y)
		g.arc(tip.x, tip.y, 0.8, 0.0, TAU)
		g.fill()

# A point of the tower's own frame (metres) in the screen frame: turned by `rot`, scaled, placed at `at`.
static func _tp(p: Vector2, at: Vector2, ppm: float, rot: float) -> Vector2:
	return at + p.rotated(rot) * ppm

static func _tpp(pts: PackedVector2Array, at: Vector2, ppm: float, rot: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in pts:
		out.push_back(_tp(q, at, ppm, rot))
	return out

# A loose bar of lattice (a leg length with a rung) pointing +x, for debris; `mask` the white silhouette.
static func draw_bar(g: InkCanvas, st: FxStyle, size_px: float, seed_v: int, at: Vector2, mask: bool) -> void:
	var rng := Mulberry32.new(seed_v)
	var L := size_px * (0.7 + rng.next() * 0.6)
	var w := maxf(size_px * 0.12, 0.7)
	var a := at - Vector2(L * 0.5, 0.0)
	var b := at + Vector2(L * 0.5, 0.0)
	if mask:
		g.stroke_color = Color.WHITE
		g.line_width = maxf(w * 2.0, 1.2)
		g.line_cap = "round"
		g.begin_path()
		g.move_to(a.x, a.y)
		g.line_to(b.x, b.y)
		g.stroke()
		return
	var k := make_ink(st)
	_line(g, k, PackedVector2Array([a, b]), 0.95, 1.0, seed_v)
	_line(g, k, PackedVector2Array([a + Vector2(0, w * 1.6), b + Vector2(-L * 0.12, w * 1.6)]), 0.8, 1.0, seed_v + 3)
	for j in 3:
		var x := lerpf(a.x, b.x, 0.2 + 0.25 * float(j))
		_line(g, k, PackedVector2Array([Vector2(x, a.y), Vector2(x + L * 0.08, a.y + w * 1.6)]), 0.45, 0.7, seed_v + 7 + j)

# --- Baking ---------------------------------------------------------------------------------------------------------------------------------

# The sprites of one ruin option at one scale: `o` is the ruin option (unwrapped), `M` the tower, `variants` of each.
static func bake_set(st: FxStyle, o: Dictionary, M: Model, ppm: float, seed_v: int, rot: float = 0.0) -> RuinSet:
	if not FxBake.can_bake():
		return null
	var rs := RuinSet.new()
	rs.ppm = ppm
	var r := FxData.grp(o, "remains")
	var lat := FxData.grp(o, "lattice")
	var col := FxData.grp(o, "collapse")
	var roles := {"cream": FxData.s(lat, "cream_role"), "wk": FxData.f(lat, "weight_k")}
	var nvar := FxData.i(o, "variants")
	var H: float = float(M.p["height"])
	var margin := 8.0
	# remains canvas: the scorch is the widest thing
	var Rr := maxf(FxData.f(r, "scorch_r_m"), maxf(FxData.f(r, "crater_r_m") * 1.9, float(M.p["base"]) + 5.0)) * 1.55 * ppm + margin
	var rhalf := int(ceil(Rr))
	rs.remains_origin = Vector2(rhalf, rhalf)
	# lattice canvas: from behind the base to the end of the mast, a little over to either side
	var lx0 := 6.0 * ppm
	var lw := int(ceil((H + 8.0) * ppm + lx0 + margin * 2.0))
	var lh := int(ceil((H * 0.8 + 6.0) * ppm + margin * 2.0))
	rs.lying_origin = Vector2(lx0 + margin, float(lh) * 0.5)
	var canvases: Array = []
	var kinds: Array = []
	for v in nvar:
		var sv := FxBake.seed_of("ruin", v, seed_v)
		var g := InkCanvas.new(Vector2i(rhalf * 2, rhalf * 2))
		g.line_cap = "round"
		draw_remains(g, st, M, r, ppm, rs.remains_origin, sv, rot)
		canvases.append(g)
		kinds.append(["remains", v, 0.0])
		var go := InkCanvas.new(Vector2i(rhalf * 2, rhalf * 2))
		go.line_cap = "round"
		draw_remains(go, st, M, r, ppm, rs.remains_origin, sv, rot, false)
		canvases.append(go)
		kinds.append(["remains_other", v, 0.0])
		var brk := lattice_break(o, M, sv)
		var roll: float = float(brk["roll"])
		if FxData.b(lat, "fallen"):
			var gl := InkCanvas.new(Vector2i(lw, lh))
			gl.line_cap = "round"
			draw_lattice(gl, st, M, ppm, rs.lying_origin, PI * 0.5, roll, brk, sv, roles)
			canvases.append(gl)
			kinds.append(["lying", v, 0.0])
		if FxData.s(col, "mode") == "topple":
			for t in FxData.arr(col, "frames_s"):
				var u := clampf(float(t) / maxf(FxData.f(col, "duration_s"), 1e-6), 0.0, 1.0)
				var th := PI * 0.5 * pow(u, FxData.f(col, "ease_pow"))
				var gf := InkCanvas.new(Vector2i(lw, lh))
				gf.line_cap = "round"
				var lying := u >= 0.999
				draw_lattice(gf, st, M, ppm, rs.lying_origin, th, roll * (th / (PI * 0.5)), brk if lying else {}, sv, roles)
				canvases.append(gf)
				kinds.append(["collapse", v, float(t)])
	var bsz := FxData.f(FxData.grp(o, "debris"), "bar_frac") * H * ppm
	for k2 in FxData.i(FxData.grp(o, "debris"), "bar_variants"):
		var bh := int(ceil(bsz * 1.2 + 4.0))
		var gb := InkCanvas.new(Vector2i(bh * 2, bh * 2))
		gb.line_cap = "round"
		draw_bar(gb, st, bsz, FxBake.seed_of("bar", k2, seed_v), Vector2(bh, bh), false)
		canvases.append(gb)
		kinds.append(["bar", k2, 0.0])
		var gm := InkCanvas.new(Vector2i(bh * 2, bh * 2))
		draw_bar(gm, st, bsz, FxBake.seed_of("bar", k2, seed_v), Vector2(bh, bh), true)
		canvases.append(gm)
		kinds.append(["bar_mask", k2, 0.0])
		rs.bar_origin.append(Vector2(bh, bh))
	var imgs := FxBake.render(canvases)
	for q in nvar:
		rs.remains.append(null)
		rs.remains_other.append(null)
		rs.lying.append(null)
		rs.collapse.append([])
	for i in kinds.size():
		var kd: Array = kinds[i]
		match str(kd[0]):
			"remains":
				rs.remains[int(kd[1])] = FxBake.texture(imgs[i], false)
			"remains_other":
				rs.remains_other[int(kd[1])] = FxBake.texture(imgs[i], false)
			"lying":
				rs.lying[int(kd[1])] = FxBake.texture(imgs[i], false)
			"collapse":
				(rs.collapse[int(kd[1])] as Array).append({"t": float(kd[2]), "tex": FxBake.texture(imgs[i], false)})
			"bar":
				rs.bars.append(FxBake.texture(imgs[i], false))
			"bar_mask":
				rs.bar_masks.append(FxBake.texture(imgs[i], true))
	return rs

# How variant `v` of the mast broke: where, how far each far part turned, the roll it fell with, what was lost.
static func lattice_break(o: Dictionary, M: Model, seed_v: int) -> Dictionary:
	var lat := FxData.grp(o, "lattice")
	var rng := Mulberry32.new(FxBake.seed_of("break", seed_v, 3))
	var H: float = float(M.p["height"])
	var nb := FxData.i(lat, "breaks")
	var xs: Array = []
	var turns: Array = []
	var sec := H / float(int(M.p["sections"]))
	for i in nb:
		var at_sec := 1.0 + floorf(rng.next() * float(int(M.p["sections"]) - 2))
		xs.append(at_sec * sec * (0.8 + rng.next() * 0.4))
		var sgn := 1.0 if rng.next() < 0.5 else -1.0
		turns.append(sgn * deg_to_rad(lerpf(float(FxData.arr(lat, "break_turn_deg")[0]), float(FxData.arr(lat, "break_turn_deg")[1]), rng.next())))
	xs.sort()
	var roll := deg_to_rad(lerpf(float(FxData.arr(lat, "roll_deg")[0]), float(FxData.arr(lat, "roll_deg")[1]), rng.next()))
	if rng.next() < 0.5:
		roll = -roll
	return {"x": xs, "turn": turns, "roll": roll, "drop": FxData.f(lat, "drop"), "snap": FxData.f(lat, "snap"), "keep_m": FxData.f(lat, "keep_frac") * H}
