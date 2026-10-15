extends RefCounted

# THE SMALL CRUISER in ink (Track SH, the warship, 2026-10-10): the unit sheet's small cruiser (reference/mockups/unit_sheet.html
# genCruiser / buildCruiser / drawCruiserGround / drawCruiserUpper, Alex's "as proposed" in decision unit-sheet-choices), ported
# to the drawing layer the way unit_marker_art.gd ports the planes and the tank and unit_marker_art_static.gd the batteries, and
# BAKED ONCE into textures. unit_marker_art.gd reaches this file with load() (never a preload: it preloads that one).
#
#   sheet                         here
#   genCruiser(rng)               gen_cruiser(rng)             parameters, metres, every draw in the sheet's order
#   buildCruiser(p)               build_cruiser(p)             geometry, metres
#   drawCruiserGround/Upper       draw_cruiser(g, M, V, ink, accent)
#   (G.wake: three ink lines)     the INK V wake of decision boat-wake (scripts/render/boat_art.gd draw_wake, the very code the
#                                 boats' board drew it with), baked into a texture of its own so a ship at anchor has none
#
# THE FRAME is the sheet's: x to starboard, y aft, the bow toward -y, metres; the marker rotates the sprite as it does a plane.
# Colour is a ROLE of the style's palette (Ink: roof = the hull's roof_lit, fill = the cream of the upper works, fill_shaded its
# shade, sd the shadow side) and the side's accent is on ONE zone, the painted recognition panel on the quarterdeck: hue is reserved
# for paper, ink, shadow and the accents; lightness is a ramp off paper; material is linework (planks, hatching, stipple). No hex.
#
# THE SIZE. The sheet's cruiser is 112 to 128 m (data/units/cruiser.json size_m 120), drawn at the planes' scale (decision
# water-layer): the same pixels per metre as a plane, so at the marker's true scale a 120 m ship is 13 light fighters long.
#
# THE SHADOW. A ship's shadow on the sea is the sheet's castShadows rule: a part h metres above the water throws its footprint
# h x the sun's length away from the sun. The marker casts one shadow from one mask, offset by one height, so the mask here is the
# hull's silhouette and the cast height (Art.cast_height_m) is the hull's freeboard: the marker layer lifts the shadow that far,
# the tall upper works' longer shadow is not drawn (a proposed simplification; BoatFrame draws the full prism shadow on its board).

const A = preload("res://scripts/ui/unit_marker_art.gd")
const S = preload("res://scripts/ui/unit_marker_art_static.gd")
const BoatArt = preload("res://scripts/render/boat_art.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

const WAKE_SEED := 7919

# genCruiser(rng): every draw in the sheet's order (the object literal's).
static func gen_cruiser(rng: Mulberry32) -> Dictionary:
	var p := {}
	p.length = A._r(rng, 112.0, 128.0)
	p.beam = A._r(rng, 12.0, 14.2)
	p.bow = A._r(rng, 0.26, 0.34)
	p.stern = A._pick_w(rng, [["transom", 0.5], ["round", 0.5]])
	p.turrets_fwd = A._pick_w(rng, [[1, 0.3], [2, 0.7]])
	p.turrets_aft = A._pick_w(rng, [[1, 0.5], [2, 0.5]])
	p.turret_r = A._r(rng, 3.4, 4.2)
	p.barrels = A._pick_w(rng, [[2, 0.6], [3, 0.4]])
	p.barrel_len = A._r(rng, 8.5, 11.5)
	p.super_len = A._r(rng, 16.0, 24.0)
	p.super_w = A._r(rng, 7.0, 9.0)
	p.funnels = A._pick_w(rng, [[1, 0.45], [2, 0.55]])
	p.funnel_len = A._r(rng, 6.0, 8.0)
	p.funnel_w = A._r(rng, 3.6, 4.6)
	p.boats = 2 + int(floorf(rng.next() * 3.0))
	p.secondaries = A._pick_w(rng, [[0, 0.3], [2, 0.4], [4, 0.3]])
	p.freeboard = A._r(rng, 4.4, 5.6)
	p.mainmast = rng.next() < 0.7
	return p

# The half beam at t (0 = the bow, 1 = the stern): the sheet's hb.
static func hb(p: Dictionary, t: float) -> float:
	var B: float = p.beam
	var bow: float = p.bow
	if t < bow:
		var u := t / bow
		return B / 2.0 * pow(sin(u * PI / 2.0), 0.78)
	var ts := 0.86
	if t <= ts:
		return B / 2.0
	var u2 := (t - ts) / (1.0 - ts)
	if p.stern == "transom":
		return B / 2.0 * (1.0 - 0.2 * u2 * u2)
	return B / 2.0 * sqrt(maxf(0.0, 1.0 - u2 * u2 * 0.85))

static func _ell(cx: float, cy: float, rx: float, ry: float, n: int = 24) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		out.append(Vector2(cx + cos(a) * rx, cy + sin(a) * ry))
	return out

# the gun house of a turret (the sheet's gh)
static func _gun_house(r: float) -> PackedVector2Array:
	var o := PackedVector2Array()
	for k in 11:
		var a := -PI / 2.0 + float(k) / 10.0 * PI
		o.append(Vector2(r * 0.25 + cos(a) * r * 0.85, sin(a) * r * 0.92))
	o.append(Vector2(-r * 0.75, r * 0.92))
	o.append(Vector2(-r * 0.95, r * 0.7))
	o.append(Vector2(-r * 0.95, -r * 0.7))
	o.append(Vector2(-r * 0.75, -r * 0.92))
	return o

# buildCruiser(p): the geometry, metres, bow toward -y.
static func build_cruiser(p: Dictionary) -> Dictionary:
	var L: float = p.length
	var B: float = p.beam
	var G := {}
	var n := 60
	var rs := PackedVector2Array()
	var cap := PackedVector2Array()
	var ls := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / float(n)
		rs.append(Vector2(hb(p, t), -L / 2.0 + t * L))
	if p.stern == "round":
		var r1 := hb(p, 1.0)
		for k in range(1, 8):
			var a := float(k) / 8.0 * PI
			cap.append(Vector2(cos(a) * r1, L / 2.0 + sin(a) * r1 * 0.8))
	for i in range(n, 0, -1):
		var t := float(i) / float(n)
		ls.append(Vector2(-hb(p, t), -L / 2.0 + t * L))
	var hull := PackedVector2Array()
	hull.append_array(rs)
	hull.append_array(cap)
	hull.append_array(ls)
	G.hull = hull
	G.deck = S.offset_poly(hull, 0.6)
	var fw: Array = [0.16, 0.235] if int(p.turrets_fwd) == 2 else [0.18]
	var af: Array = [0.775, 0.85] if int(p.turrets_aft) == 2 else [0.84]
	var turrets: Array = []
	var add_t := func(t: float, dir: float, sup: bool) -> void:
		var cy := -L / 2.0 + t * L
		var r: float = p.turret_r
		var bars: Array = []
		for k in int(p.barrels):
			var off := (float(k) - float(int(p.barrels) - 1) / 2.0) * 0.95
			bars.append(S.place(A.rect_p(r * 0.85, off - 0.22, r * 0.85 + p.barrel_len, off + 0.22), 0.0, cy, dir))
		var ears: Array = []
		for sg: float in [1.0, -1.0]:
			ears.append(S.place(A.rect_p(-r * 0.55, sg * r * 0.9 - sg * 0.05, -r * 0.15, sg * r * 1.08), 0.0, cy, dir))
		turrets.append({"c": Vector2(0.0, cy), "poly": S.place(_gun_house(r), 0.0, cy, dir), "bars": bars, "ears": ears, "sup": sup})
	for i in fw.size():
		add_t.call(float(fw[i]), -PI / 2.0, i == 1)
	for i in af.size():
		add_t.call(float(af[i]), PI / 2.0, i == 0 and af.size() == 2)
	G.turrets = turrets
	# superstructure fitted between the forward and after turrets
	var y_fw_last := -L / 2.0 + float(fw[fw.size() - 1]) * L
	var y_af_first := -L / 2.0 + float(af[0]) * L
	var s0: float = y_fw_last + p.turret_r + 3.0
	var s1: float = y_af_first - p.turret_r - 3.0
	var need: float = p.super_len + float(p.funnels) * (p.funnel_len + 3.0) + (8.0 if p.mainmast else 0.0) + 2.0
	var fit := minf(1.0, (s1 - s0) / need)   # (the sheet's k)
	var sL: float = p.super_len * fit
	var fL: float = p.funnel_len * fit
	G.deckhouse = A.rrect(0.0, s0 + sL / 2.0, p.super_w, sL, 0.6)
	G.bridge = A.rrect(0.0, s0 + sL * 0.3, p.super_w * 0.72, sL * 0.42, 0.5)
	G.bridgeWing = PackedVector2Array([Vector2(-p.super_w / 2.0 - 1.1, s0 + sL * 0.14), Vector2(p.super_w / 2.0 + 1.1, s0 + sL * 0.14)])
	var masts: Array = [{"c": Vector2(0.0, s0 + sL * 0.64), "r": 0.55, "yard": B * 0.5}]
	var yy := s0 + sL + 1.5
	var funnels: Array = []
	for i in int(p.funnels):
		funnels.append({"c": Vector2(0.0, yy + fL / 2.0), "rx": p.funnel_w / 2.0, "ry": fL / 2.0})
		yy += fL + 3.0 * fit
	G.aftHouse = PackedVector2Array()
	if p.mainmast:
		G.aftHouse = A.rrect(0.0, yy + 3.2 * fit, p.super_w * 0.66, 5.6 * fit, 0.5)
		masts.append({"c": Vector2(0.0, yy + 3.2 * fit), "r": 0.45, "yard": B * 0.4})
	G.masts = masts
	G.funnels = funnels
	var yb := yy + (7.0 * fit if p.mainmast else 1.0)
	var tb := (yb + L / 2.0) / L
	var hbl := hb(p, tb) - 0.6
	G.breakLine = PackedVector2Array([Vector2(-hbl, yb), Vector2(hbl, yb)])
	var boats: Array = []
	for i in int(p.boats):
		var sx := -1.0 if (i % 2) == 1 else 1.0
		var ybt := s0 + sL + 2.5 + float(i >> 1) * 6.5
		boats.append(_ell(sx * (B / 2.0 - 2.7), ybt, 0.9, 2.8, 16))
	G.boats = boats
	var secs: Array = []
	for i in int(p.secondaries):
		var sx := -1.0 if (i % 2) == 1 else 1.0
		var ys := s0 + sL * 0.55 + float(i >> 1) * 8.0
		var c := Vector2(sx * (B / 2.0 - 1.9), ys)
		var a := -PI / 4.0 if sx > 0.0 else -3.0 * PI / 4.0
		secs.append({"c": c, "poly": A.circ(c, 0.95, 14), "bar": S.place(A.rect_p(0.7, -0.13, 3.4, 0.13), c.x, c.y, a)})
	G.secs = secs
	# deck furniture
	var t_a: float = fw[0]
	var apex: float = -L / 2.0 + t_a * L - float(p.turret_r) - 3.4
	var ta: float = (apex + L / 2.0) / L
	G.breakwater = PackedVector2Array([Vector2(-hb(p, ta + 0.025) * 0.72, apex + 3.0), Vector2(0.0, apex), Vector2(hb(p, ta + 0.025) * 0.72, apex + 3.0)])
	var capstans: Array = []
	var chains: Array = []
	for sg: float in [-1.0, 1.0]:
		capstans.append(A.circ(Vector2(sg * 1.15, -L / 2.0 + 0.058 * L), 0.45, 12))
		chains.append(PackedVector2Array([Vector2(sg * hb(p, 0.032) * 0.8, -L / 2.0 + 0.032 * L), Vector2(sg * 1.15, -L / 2.0 + 0.058 * L), Vector2(sg * 0.9, -L / 2.0 + 0.08 * L)]))
	G.capstans = capstans
	G.chains = chains
	var bollards: Array = []
	for t: float in [0.1, 0.46, 0.62, 0.93]:
		for sg: float in [1.0, -1.0]:
			bollards.append(Vector2(sg * (hb(p, t) - 1.0), -L / 2.0 + t * L))
	G.bollards = bollards
	var y_af_last := -L / 2.0 + float(af[af.size() - 1]) * L
	var ya: float = y_af_last + p.turret_r + 2.4
	var tq := (ya + 3.0 + L / 2.0) / L
	var hq := minf(hb(p, minf(1.0, tq)), B / 2.0) * 0.6
	G.panel = A.rect_p(-hq, ya, hq, ya + 5.2)   # accent zone: the painted recognition panel on the quarterdeck
	G.base = hull
	G.ext = [hull]
	G.sil = [hull]
	return G

# drawCruiserGround + drawCruiserUpper, one after the other onto one canvas.
static func draw_cruiser(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color) -> void:
	_draw_ground(g, M, V, ink, accent)
	_draw_upper(g, M, V, ink)

static func _draw_ground(g, M: A.Model, V: A.View, ink: A.Ink, accent: Color) -> void:
	var G := M.G
	var pn := A.Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var hull_o := A._path(pn, G.hull, {"fill": ink.roof, "weight": 0.0})
	BoatArt._planks(g, ink, V.tps(G.deck), V, A._rng(pn), 2.3)
	A._path(pn, G.deck, {"weight": 0.6, "alpha": 0.55, "breaks": 0.15})
	A.edge_hatch(g, ink, hull_o, minf(5.0, 1.1 * ppm), A._rng(pn))
	A._line(pn, G.breakLine, {"alpha": 0.7, "weight": 0.65, "breaks": 0.1})
	A._line(pn, G.breakwater, {"alpha": 0.75, "weight": 0.7})
	for c: PackedVector2Array in G.chains:
		A._line(pn, c, {"alpha": 0.7, "weight": 0.6})
	for c: PackedVector2Array in G.capstans:
		A._path(pn, c, {"fill": ink.fill, "weight": 0.7})
	if ppm > 2.2:
		BoatArt._dots(g, ink, V, G.bollards, maxf(0.5, 0.25 * ppm), 0.7)
	A.accent_panel(pn, G.panel, accent)
	A.stroke_o(g, ink, hull_o, 1.2)

static func _draw_upper(g, M: A.Model, V: A.View, ink: A.Ink, with_turrets: bool = true) -> void:
	var G := M.G
	var pn := A.Pen.new(g, V, ink, M.seed + 9)
	var ppm := V.ppm
	var cream := ink.fill
	for s: Dictionary in G.secs:
		A._path(pn, s.bar, {"fill": cream, "weight": 0.7})
		var o := A._path(pn, s.poly, {"fill": cream, "weight": 0.0})
		A.shade_side(g, o, V.tp(s.c), ink.sd, ink.fill_shaded)
		A.stroke_o(g, ink, o, 0.8)
	for b: PackedVector2Array in G.boats:
		A._path(pn, b, {"fill": cream, "weight": 0.8})
		if ppm > 3.0:
			var cb := A._cen(b)
			var inner := PackedVector2Array()
			for q in b:
				inner.append(Vector2(q.x + (cb.x - q.x) * 0.3, q.y + (cb.y - q.y) * 0.18))
			A._path(pn, inner, {"weight": 0.5, "alpha": 0.6})
	var houses: Array = [G.deckhouse]
	if (G.aftHouse as PackedVector2Array).size() > 0:
		houses.append(G.aftHouse)
	for h: PackedVector2Array in houses:
		var o := A._path(pn, h, {"fill": cream, "weight": 0.0})
		A.edge_hatch(g, ink, o, minf(4.0, 0.9 * ppm), A._rng(pn))
		A.stroke_o(g, ink, o, 1.1)
		if ppm > 2.5:
			A._path(pn, S.offset_poly(h, 0.45), {"weight": 0.5, "alpha": 0.4})
	var b_o := A._path(pn, G.bridge, {"fill": ink.roof, "weight": 0.0})
	A.edge_hatch(g, ink, b_o, minf(4.0, 0.9 * ppm), A._rng(pn))
	A.stroke_o(g, ink, b_o, 1.1)
	A._line(pn, G.bridgeWing, {"weight": 0.85, "alpha": 0.9})
	for f: Dictionary in G.funnels:
		var o := A._path(pn, _ell(f.c.x, f.c.y, f.rx, f.ry, 24), {"fill": cream, "weight": 0.0})
		A.shade_side(g, o, V.tp(f.c), ink.sd, ink.fill_shaded)
		A.stroke_o(g, ink, o, 1.0)
		A._path(pn, _ell(f.c.x, f.c.y, f.rx * 0.82, f.ry * 0.86, 20), {"weight": 0.55, "alpha": 0.7})
		var mouth := A._path(pn, _ell(f.c.x, f.c.y, f.rx * 0.58, f.ry * 0.66, 18), {"weight": 0.7})   # the soot-dark mouth: cross-hatched ink
		BoatArt._hatch_inside(g, ink, mouth, V.tv(Vector2(1.0, 1.0)) / sqrt(2.0), 1.1, 0.7, 0.55)
		BoatArt._hatch_inside(g, ink, mouth, V.tv(Vector2(1.0, -1.0)) / sqrt(2.0), 1.3, 0.55, 0.5)
	for m: Dictionary in G.masts:
		A._line(pn, PackedVector2Array([Vector2(-m.yard / 2.0, m.c.y), Vector2(m.yard / 2.0, m.c.y)]), {"weight": 0.75, "alpha": 0.9})
		A._path(pn, A.circ(m.c, m.r, 10), {"fill": cream, "weight": 0.8})
	if with_turrets:
		for i in (G.turrets as Array).size():
			_draw_turret(g, M, V, ink, G.turrets[i], i)

# One main turret: its barrels, ears and gun house (builder ORD, 2026-10-14: a part of its own, so the playback can turn it to the sim's turret bearing).
static func _draw_turret(g, M: A.Model, V: A.View, ink: A.Ink, t: Dictionary, i: int) -> void:
	var pn := A.Pen.new(g, V, ink, M.seed + 9 + (i + 1) * 31)
	var cream := ink.fill
	for b: PackedVector2Array in t.bars:
		A._path(pn, b, {"fill": cream, "weight": 0.75})
	for e: PackedVector2Array in t.ears:
		A._path(pn, e, {"fill": cream, "weight": 0.6})
	var o := A._path(pn, t.poly, {"fill": cream, "weight": 0.0})
	A.shade_side(g, o, V.tp(t.c), ink.sd, ink.fill_shaded)
	A.stipple(g, ink, o, {"rng": A._rng(pn), "density": 1.2, "away": V.tp(t.c)})
	A.stroke_o(g, ink, o, 1.1)

# Where the muzzles of the main turrets are when they are trained `rel` radians from the bow (clockwise), from the drawn barrels: [{fwd, lat}] metres ahead of the
# ship's centre and to starboard, one per barrel, the fore turrets first, the barrels of a turret from port to starboard (builder ORD: the muzzle smoke starts at
# the tip of the drawn barrel, which turns with the turret). The barrel's tip is the gun house's front (turret_r x 0.85) and the barrel's length from the axis.
static func muzzles(M: A.Model, rel: float) -> Array:
	var out: Array = []
	var reach: float = float(M.p.turret_r) * 0.85 + float(M.p.barrel_len)
	var n := int(M.p.barrels)
	var d := Vector2(sin(rel), -cos(rel))     # along the bearing, in the art's frame (x starboard, y astern)
	var r := Vector2(cos(rel), sin(rel))      # to its right
	for t: Dictionary in M.G.turrets:
		for k in n:
			var off := (float(k) - float(n - 1) / 2.0) * 0.95
			var tip: Vector2 = (t.c as Vector2) + d * reach + r * off
			out.append({"fwd": -tip.y, "lat": tip.x})
	return out

# --- The wake ----------------------------------------------------------------------------------------------------

# The wake's box in the ship's frame, metres: from the bow to `wake_len` aft of the stern, as wide as the V gets.
static func wake_box(p: Dictionary, wake_len: float, spread_deg: float) -> Rect2:
	var half: float = float(p.beam) / 2.0 + 0.55 + 0.12 * float(p.length) + wake_len * tan(deg_to_rad(spread_deg)) + 1.5
	return Rect2(Vector2(-half, -float(p.length) / 2.0 - 1.0), Vector2(2.0 * half, float(p.length) + wake_len + 3.0))

# --- The bake ----------------------------------------------------------------------------------------------------

static func bake(st: RefCounted, M: A.Model, accent: Color, ppm: float) -> A.Art:
	var margin: float = st.num("unit_art.bake_margin_px")
	var box := A.extent_box(M)
	var size := Vector2i(ceili(box.size.x * ppm + 2.0 * margin), ceili(box.size.y * ppm + 2.0 * margin))
	var V := A.View.new(-box.position.x * ppm + margin, -box.position.y * ppm + margin, ppm, 0.0)
	var ink := A.ink_consts(st)
	var art_canvas = InkCanvas.new(size)
	art_canvas.line_cap = "round"
	draw_cruiser(art_canvas, M, V, ink, accent)
	var mask_canvas = InkCanvas.new(size)
	mask_canvas.begin_path()
	for poly: PackedVector2Array in M.G.sil:
		A.add_poly(mask_canvas, V.tps(poly), true)
	mask_canvas.fill_color = Color.WHITE   # a mask, not a drawn colour: the shadow role tints it
	mask_canvas.fill()
	# The wake, on a canvas of its own (under the shadow and the ship; shown only while the ship is under way).
	var wl: float = float(st.num("unit_art.ship.wake_len_m"))
	var wake_kind := str(st.text("unit_art.ship.wake"))
	var wbox := wake_box(M.p, wl, float(BoatArt.val(BoatArt.data()["wakes"]["spread_deg"])))
	var wsize := Vector2i(ceili(wbox.size.x * ppm + 2.0 * margin), ceili(wbox.size.y * ppm + 2.0 * margin))
	var WV := A.View.new(-wbox.position.x * ppm + margin, -wbox.position.y * ppm + margin, ppm, 0.0)
	var wake_canvas = InkCanvas.new(wsize)
	wake_canvas.line_cap = "round"
	if wake_kind != "none":
		var wm := BoatArt.Model.new()
		wm.kind = "patrol"
		wm.look = "small_cruiser"
		wm.seed = M.seed
		wm.p = {"length": M.p.length, "beam": M.p.beam, "bow": M.p.bow, "bow_exp": 0.78, "stern": M.p.stern, "stern_len": 0.14, "stern_taper": 0.2, "wake_len": wl}
		BoatArt.draw_wake(wake_canvas, wm, WV, ink, {}, wake_kind, M.seed + WAKE_SEED)
	# THE TURRETS AS PARTS (builder ORD): the hull and upper works without them, then each turret on a square canvas centred on its axis
	var hull_canvas = InkCanvas.new(size)
	hull_canvas.line_cap = "round"
	_draw_ground(hull_canvas, M, V, ink, accent)
	_draw_upper(hull_canvas, M, V, ink, false)
	var canvases: Array = [art_canvas, mask_canvas, wake_canvas, hull_canvas]
	var part_info: Array = []
	for i in (M.G.turrets as Array).size():
		var t: Dictionary = M.G.turrets[i]
		var pivot: Vector2 = t.c
		var r_m := 0.0
		var polys: Array = [t.poly]
		polys.append_array(t.bars)
		polys.append_array(t.ears)
		for poly: PackedVector2Array in polys:
			for q in poly:
				r_m = maxf(r_m, (q - pivot).length())
		var half_px := ceili(r_m * ppm + margin)
		var Vp := A.View.new(float(half_px) - pivot.x * ppm, float(half_px) - pivot.y * ppm, ppm, 0.0)
		var pc = InkCanvas.new(Vector2i(2 * half_px, 2 * half_px))
		pc.line_cap = "round"
		_draw_turret(pc, M, Vp, ink, t, i)
		canvases.append(pc)
		part_info.append({"origin": Vector2(half_px, half_px), "pivot_m": pivot, "built_rel": 0.0 if pivot.y < 0.0 else PI})
	var imgs: Array = InkCanvas.render_all(canvases)
	var art := A.Art.new()
	art.ppm = ppm
	art.origin = Vector2(V.x, V.y)
	art.size_px = size
	var far := 0.0
	for poly: PackedVector2Array in M.G.ext:
		for q in poly:
			far = maxf(far, q.length())
	art.extent_m = far
	art.cast_height_m = float(M.p.freeboard)
	if imgs.size() == canvases.size() and imgs[0] != null and not imgs[0].is_empty():
		art.texture = ImageTexture.create_from_image(A._straight(imgs[0], false))
		art.mask = ImageTexture.create_from_image(A._straight(imgs[1], true))
		if wake_kind != "none" and imgs[2] != null and not imgs[2].is_empty():
			art.wake = ImageTexture.create_from_image(A._straight(imgs[2], false))
			art.wake_origin = Vector2(WV.x, WV.y)
		if imgs[3] != null and not imgs[3].is_empty():
			art.hull_texture = ImageTexture.create_from_image(A._straight(imgs[3], false))
			art.hull_mask = art.mask   # (a ship's shadow is its hull: the turrets are not in it)
			for i in part_info.size():
				var img: Image = imgs[4 + i]
				if img == null or img.is_empty():
					art.turret_parts.clear()
					break
				var info: Dictionary = part_info[i]
				art.turret_parts.append({"tex": ImageTexture.create_from_image(A._straight(img, false)), "mask": null, "origin": info["origin"], "pivot_m": info["pivot_m"], "built_rel": info["built_rel"]})
	return art
