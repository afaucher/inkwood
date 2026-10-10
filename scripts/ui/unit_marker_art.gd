extends RefCounted

# The planes and the tank in ink, as the unit sheet draws them (reference/mockups/
# unit_sheet.html), ported to the drawing layer and BAKED ONCE into textures.
# THE TANK (Track F's line-of-sight shots, 2026-10-09): genTank / buildTank /
# drawTankGround + drawTankUpper -> gen_tank / build_tank / draw_tank, on top of
# the same pen and helpers, plus the few the tank needs that the planes did not
# (rrect, hatchLines, accentPanel, stipple's `away`, a fill clipped to an outline).
# The sheet draws a ground unit in two layers with its shadow between; here both
# are one texture (the marker layer casts the shadow from art.mask, the footprint).
# The tank's variant is unit_art.variant.tank when ui.json has it (it does not yet:
# proposed, Track U to add) and 0, the sheet's default view, when it does not.
#
#   sheet                         here
#   unitSeed(ui, v)               unit_seed(scene_seed, ui, v)
#   genPlane(kind, rng)           gen_plane(kind, rng)          parameters, metres
#   buildPlane(p)                 build_plane(p)                geometry, metres
#   drawPlane(g, I)               draw_plane(g, G, p, V, ...)   onto an InkCanvas
#   inkPath / pen / strokePts /   ink_path / Pen / stroke_pts / wobble / subdivide
#     wobble / subdivide
#   stipple / shadeSide /         stipple / shade_side / shade_axis / edge_hatch /
#     shadeAxis / edgeHatch /       rivets / roundel
#     rivets / roundel
#   maskOps "air" silhouette      the mask texture: G.sil filled, for the shadow
#
#   var art := UnitMarkerArt.art_for(style, "light_fighter", accent, ppm)
#   art.texture   the plane, STRAIGHT alpha, nose up (-y), unit centre at art.origin
#   art.mask      its silhouette (white, straight alpha) for the shadow
#
# THE SHEET'S FRAME: x to starboard, y aft, nose toward -y, metres; a View maps
# metres to pixels at `ppm` (no rotation here: the marker rotates the sprite).
# The pen works in PIXELS, as the prototype's does, so a texture is baked AT
# the host's scale and re-baked only when the host zooms past the data's
# rebake_ratio -- never per frame. Same seed, same plane: the model comes from
# the sheet's own unitSeed(ui, variant) on the scene seed, so the variant the
# data names (ui.json unit_art.variant) is the plane Alex saw on the sheet.
#
# DEPARTURES FROM THE SHEET (all deliberate):
#   - Canvas clip() has no InkCanvas equivalent. shadeSide's clipped half-plane
#     fill is a polygon intersection (Geometry2D.intersect_polygons), and
#     stipple's clipped dots are kept only when their centre is inside the
#     outline; the rng stream is drawn exactly as the sheet draws it.
#   - Stipple dots go into one fill() per stipple call (the canvas draws one
#     fill per dot): overlapping dots merge instead of darkening twice.
#   - Device pixel ratio is 1.
#   - Baked lighting turns with the sprite: the shaded half, stipple and edge
#     hatching are drawn for a plane heading north under the map's sun, and a
#     plane flying south shows them on the sunny side. Proposed fix if Alex
#     wants it: bake per heading bucket (eight would do at this size).
#   - The pen line is the drawing layer's (Alex chose the shadow-side pen; the
#     render track puts it into InkCanvas for every caller). Outlines here stay
#     ordinary closed paths so that pen can tell which side faces the sun.
#
# HEADLESS: the dummy renderer produces no image, so can_bake() is false and
# art_for() returns null; markers keep working without pixels.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

const MASK32 := 0xFFFFFFFF
# silhouette id (data/units/<type>.json drawing.silhouette) -> [the sheet's
# UNITS index, genPlane kind]. The index feeds unitSeed, as on the sheet.
const PLANES := {
	"light_fighter": [0, "light"],
	"heavy_fighter": [1, "heavy"],
	"bomber": [2, "bomber"],
}

# silhouette id -> the sheet's UNITS index (feeds unitSeed). Ground units drawn so far.
const TANKS := {
	"tank": 3,
}

class Art:
	var texture: Texture2D = null   # the plane, straight alpha
	var mask: Texture2D = null      # the silhouette, white, straight alpha
	var origin := Vector2.ZERO      # the unit's centre in texture px
	var ppm: float = 1.0            # the scale it was baked at
	var size_px := Vector2i.ZERO
	var extent_m: float = 0.0       # largest distance from the centre to any part, metres

class Model:
	var silhouette: String
	var variant: int
	var seed: int
	var p: Dictionary
	var G: Dictionary

class View:
	var x: float
	var y: float
	var ppm: float
	var c: float
	var s: float
	func _init(px: float, py: float, scale_ppm: float, rot: float) -> void:
		x = px
		y = py
		ppm = scale_ppm
		c = cos(rot)
		s = sin(rot)
	func tp(p: Vector2) -> Vector2:
		var xx := p.x * ppm
		var yy := p.y * ppm
		return Vector2(x + xx * c - yy * s, y + xx * s + yy * c)
	func tv(d: Vector2) -> Vector2:
		return Vector2(d.x * c - d.y * s, d.x * s + d.y * c)
	func tps(pts: PackedVector2Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		out.resize(pts.size())
		for i in pts.size():
			out[i] = tp(pts[i])
		return out

# The drawing constants one bake needs, resolved from the style once.
class Ink:
	var lw: float
	var wob: float
	var stip: float
	var ink: Color
	var fill: Color
	var fill_shaded: Color
	var glass_lit: Color
	var glass_shaded: Color
	var rock: Color         # ROCK: the track links' fill
	var slope: Color        # slope(CREAM): a sloped plate away from the sun
	var sd: Vector2         # shadowDir()
	var light: Vector2      # LX, LY

# pen(g, V, seed): deterministic seeds, a fresh rng per material. State only;
# path / line / r are the outer statics _path / _line / _rng (an inner class
# reaching outer statics is avoided on purpose).
class Pen:
	var g
	var V
	var ink
	var seed: int
	var k: int = 0
	func _init(canvas, view, ink_values, seed_value: int) -> void:
		g = canvas
		V = view
		ink = ink_values
		seed = seed_value
	# next=()=>(seed+(++k)*7919)|0
	func next() -> int:
		k += 1
		return (((seed + k * 7919) & 0xFFFFFFFF) ^ 0x80000000) - 0x80000000

static var _models: Dictionary = {}
static var _art: Dictionary = {}

# --- Public ----------------------------------------------------------------------

static func can_bake() -> bool:
	return DisplayServer.get_name() != "headless"

static func is_plane(silhouette: String) -> bool:
	return PLANES.has(silhouette)

static func is_tank(silhouette: String) -> bool:
	return TANKS.has(silhouette)

# The sheet's variant index for a silhouette: ui.json unit_art.variant.<silhouette>;
# a silhouette ui.json does not list yet (the tank) takes the sheet's default view, 0.
static func _variant_of(st: RefCounted, silhouette: String) -> int:
	var v: Variant = st.lookup("unit_art.variant." + silhouette)
	if v is float or v is int:
		return int(v)
	if is_tank(silhouette):
		return 0
	return int(st.num("unit_art.variant." + silhouette))

# The baked art for a silhouette in a side's accent at `ppm`, from the cache or
# baked now (one InkCanvas frame). null when it cannot be drawn (headless, or a
# silhouette the sheet has no generator for).
static func art_for(st: RefCounted, silhouette: String, accent: Color, ppm: float) -> Art:
	if not (is_plane(silhouette) or is_tank(silhouette)):
		return null
	var lo: float = st.num("unit_art.min_bake_ppm")
	var hi: float = st.num("unit_art.max_bake_ppm")
	var q := snappedf(clampf(ppm, lo, hi), 0.01)
	var variant := _variant_of(st, silhouette)
	# The pen is part of the art (outlines go through InkCanvas's pen), so it is part of the key.
	var key := "%s|%d|%s|%.2f|%s" % [silhouette, variant, accent.to_html(), q, InkCanvas.pen_key()]
	if _art.has(key):
		var hit: Art = _art[key]
		_art.erase(key)   # LRU: a hit moves to the back, the front is evicted first
		_art[key] = hit
		return hit
	if not can_bake():
		return null
	var art := _bake(st, model_for(st, silhouette), accent, q)
	_art[key] = art
	_trim(int(st.num("unit_art.cache_max")))
	return art

# The cache is bounded (unit_art.cache_max, data): a zoom bakes a new scale now
# and then, and a cache that never evicts grew by one entry per zoom step
# (measured 2026-10-09: 128 bakes in 120 frames of planning-time zooming, when
# the ghosts asked for their own art every frame). Evicts the least recently
# used; an art a marker holds stays alive through that reference.
static func _trim(limit: int) -> void:
	while _art.size() > maxi(limit, 1):
		_art.erase(_art.keys()[0])

static func cache_size() -> int:
	return _art.size()

# The sheet's model for a silhouette and variant: parameters and geometry, metres.
static func model_for(st: RefCounted, silhouette: String, variant: int = -1) -> Model:
	if variant < 0:
		variant = _variant_of(st, silhouette)
	var key := "%s|%d|%d" % [silhouette, variant, st.scene_seed]
	if _models.has(key):
		return _models[key]
	var m := Model.new()
	m.silhouette = silhouette
	m.variant = variant
	if is_tank(silhouette):
		m.seed = unit_seed(st.scene_seed, int(TANKS[silhouette]), variant)
		m.p = gen_tank(Mulberry32.new(m.seed))
		m.G = build_tank(m.p)
	else:
		var spec: Array = PLANES[silhouette]
		m.seed = unit_seed(st.scene_seed, int(spec[0]), variant)
		m.p = gen_plane(str(spec[1]), Mulberry32.new(m.seed))
		m.G = build_plane(m.p)
	_models[key] = m
	return m

# Forgets every baked art (a pen change makes them stale; a sandbox that ends
# leaves none behind). Markers keep the art they hold until they ask again.
static func clear_cache() -> void:
	_art.clear()

# --- unitSeed --------------------------------------------------------------------

# function unitSeed(ui,v){let h=(P.seed^Math.imul(ui+1,0x9E3779B1))|0;
#   h=Math.imul(h^(h>>>15),0x85EBCA77); h^=Math.imul(v+1,0xC2B2AE35); h^=h>>>13;
#   return (h>>>0)%2147483647;}   -- in the unsigned 32-bit representation throughout.
static func unit_seed(scene_seed: int, ui: int, v: int) -> int:
	var h := (scene_seed ^ Mulberry32.imul(ui + 1, 0x9E3779B1)) & MASK32
	h = Mulberry32.imul(h ^ (h >> 15), 0x85EBCA77)
	h = (h ^ Mulberry32.imul(v + 1, 0xC2B2AE35)) & MASK32
	h ^= h >> 13
	return h % 2147483647

# --- genPlane --------------------------------------------------------------------

# R2=v=>Math.round(v*100)/100; rnd=rng=>(a,b)=>R2(a+rng()*(b-a))
static func _r(rng: Mulberry32, a: float, b: float) -> float:
	return floorf((a + rng.next() * (b - a)) * 100.0 + 0.5) / 100.0

static func _b(rng: Mulberry32, pr: float) -> bool:
	return rng.next() < pr

static func _pick_w(rng: Mulberry32, opts: Array) -> Variant:
	var u := rng.next()
	var acc := 0.0
	for o: Array in opts:
		acc += float(o[1])
		if u < acc:
			return o[0]
	return (opts[opts.size() - 1] as Array)[0]

# Object literals evaluate left to right: every rng draw below is in the
# sheet's order (short-circuit draws included).
static func gen_plane(kind: String, rng: Mulberry32) -> Dictionary:
	var p := {}
	if kind == "light":
		p.span = _r(rng, 8.6, 10.2); p.length = _r(rng, 7.6, 9.0); p.fuse_w = _r(rng, 1.0, 1.25)
		p.nose = _r(rng, 0.1, 0.16); p.tail_w = _r(rng, 0.2, 0.3); p.body_max = _r(rng, 0.36, 0.44)
		p.root_chord = _r(rng, 1.9, 2.4); p.tip_chord = _r(rng, 0.85, 1.3); p.wing_at = _r(rng, 0.24, 0.31)
		p.sweep = _r(rng, 0.05, 0.5)
		p.ellip = _r(rng, 0.6, 1.0) if _b(rng, 0.34) else _r(rng, 0.0, 0.25)
		p.tip_round = _r(rng, 0.4, 1.0)
		p.tail_span = _r(rng, 2.8, 3.6); p.tail_root = _r(rng, 0.85, 1.15); p.tail_tip = _r(rng, 0.45, 0.7)
		p.engines = 1; p.prop_dia = _r(rng, 2.8, 3.3)
		p.canopy_at = _r(rng, 0.36, 0.44); p.canopy_len = _r(rng, 1.5, 2.1); p.canopy_w = _r(rng, 0.55, 0.7)
		p.wing_guns = 2 if _b(rng, 0.5) else 4
		p.nose_guns = 0
		p.frames = 2 + int(floorf(rng.next() * 3.0))
		p.rivets = _b(rng, 0.7)
		p.booms = false; p.twin_fin = false; p.glazed_nose = false; p.dorsal = false; p.tail_gun = false
		return p
	if kind == "heavy":
		var booms := _b(rng, 0.34)
		p.span = _r(rng, 11.2, 13.0); p.length = _r(rng, 9.5, 11.4); p.fuse_w = _r(rng, 1.2, 1.5)
		p.nose = _r(rng, 0.14, 0.2); p.tail_w = _r(rng, 0.25, 0.35); p.body_max = _r(rng, 0.38, 0.48)
		p.root_chord = _r(rng, 2.4, 3.0); p.tip_chord = _r(rng, 1.0, 1.4); p.wing_at = _r(rng, 0.3, 0.36)
		p.sweep = _r(rng, 0.1, 0.5); p.ellip = _r(rng, 0.0, 0.3); p.tip_round = _r(rng, 0.3, 0.9)
		p.tail_span = _r(rng, 4.2, 5.2); p.tail_root = _r(rng, 1.0, 1.3); p.tail_tip = _r(rng, 0.55, 0.8)
		p.engines = 2; p.nac_at = _r(rng, 0.3, 0.38); p.nac_len = _r(rng, 3.6, 4.6); p.nac_w = _r(rng, 0.85, 1.05)
		p.prop_dia = _r(rng, 3.0, 3.4)
		p.canopy_at = _r(rng, 0.2, 0.28); p.canopy_len = _r(rng, 2.4, 3.4); p.canopy_w = _r(rng, 0.6, 0.75)
		p.wing_guns = 0
		p.nose_guns = 2 if _b(rng, 0.5) else 4
		p.frames = 3 + int(floorf(rng.next() * 3.0))
		p.rivets = _b(rng, 0.6)
		p.booms = booms
		p.twin_fin = booms or _b(rng, 0.3)
		p.glazed_nose = false; p.dorsal = false; p.tail_gun = false
		return p
	var engines: int = int(_pick_w(rng, [[2, 0.55], [3, 0.25], [4, 0.2]]))
	p.span = _r(rng, 19.0, 21.5); p.length = _r(rng, 15.0, 17.5); p.fuse_w = _r(rng, 1.7, 2.1)
	p.nose = _r(rng, 0.12, 0.18); p.tail_w = _r(rng, 0.35, 0.5); p.body_max = _r(rng, 0.5, 0.6)
	p.root_chord = _r(rng, 3.4, 4.2); p.tip_chord = _r(rng, 1.4, 2.0); p.wing_at = _r(rng, 0.3, 0.36)
	p.sweep = _r(rng, 0.1, 0.6); p.ellip = _r(rng, 0.0, 0.2); p.tip_round = _r(rng, 0.3, 0.8)
	p.tail_span = _r(rng, 6.4, 7.6); p.tail_root = _r(rng, 1.5, 1.9); p.tail_tip = _r(rng, 0.9, 1.2)
	p.engines = engines
	p.nac_at = _r(rng, 0.26, 0.34); p.nac_len = _r(rng, 4.4, 5.4); p.nac_w = _r(rng, 1.3, 1.6)
	p.prop_dia = _r(rng, 3.2, 3.6)
	p.canopy_at = _r(rng, 0.18, 0.24); p.canopy_len = _r(rng, 1.8, 2.4); p.canopy_w = _r(rng, 0.9, 1.1)
	p.wing_guns = 0; p.nose_guns = 0
	p.frames = 4 + int(floorf(rng.next() * 4.0))
	p.rivets = _b(rng, 0.6)
	p.booms = false
	p.twin_fin = _b(rng, 0.5)
	p.glazed_nose = engines != 3 and _b(rng, 0.8)
	p.glaze_len = _r(rng, 1.4, 2.0)
	p.dorsal = _b(rng, 0.7)
	p.dorsal_at = _r(rng, 0.4, 0.48)
	p.dorsal_dir = _r(rng, 60.0, 120.0)
	p.tail_gun = _b(rng, 0.6)
	return p

# --- buildPlane ------------------------------------------------------------------

static func body_profile(w: float, nose: float, tail_w: float, max_at: float, nose_r: float) -> Callable:
	return func(t: float) -> float:
		if t < nose:
			var u := t / nose
			return w / 2.0 * (nose_r + (1.0 - nose_r) * sqrt(1.0 - (1.0 - u) * (1.0 - u)))
		if t <= max_at:
			return w / 2.0
		var v := (t - max_at) / (1.0 - max_at)
		var sm := v * v * (3.0 - 2.0 * v)
		return w / 2.0 + (tail_w / 2.0 - w / 2.0) * sm

static func body_poly(length: float, y0: float, hw: Callable, n: int, cx: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var r0: float = hw.call(0.0)
	var r1: float = hw.call(1.0)
	for k in range(1, 6):
		var a := PI + float(k) / 6.0 * PI
		out.append(Vector2(cx + cos(a) * r0, y0 + sin(a) * r0 * 1.1))
	for i in n + 1:
		var t := float(i) / float(n)
		out.append(Vector2(cx + float(hw.call(t)), y0 + t * length))
	for k in range(1, 6):
		var a := float(k) / 6.0 * PI
		out.append(Vector2(cx + cos(a) * r1, y0 + length + sin(a) * r1))
	for i in range(n, -1, -1):
		var t := float(i) / float(n)
		out.append(Vector2(cx - float(hw.call(t)), y0 + t * length))
	return out

# u -> [x, le, c, te]: the chord blends a trapezoid and an ellipse; the
# quarter-chord line carries the sweep.
static func wing_fn(s: float, y_le: float, cr: float, ct: float, sweep: float, ellip: float) -> Callable:
	return func(u: float) -> PackedFloat64Array:
		var ctr := cr + (ct - cr) * u
		var cel := maxf(ct * 0.4, cr * sqrt(maxf(0.0, 1.0 - u * u)))
		var c := ctr + (cel - ctr) * ellip
		var le := y_le + sweep * u + (cr - c) * 0.25
		return PackedFloat64Array([u * s, le, c, le + c])

static func wing_poly(at: Callable, tip_round: float) -> PackedVector2Array:
	var n := 16
	var le := PackedVector2Array()
	var te := PackedVector2Array()
	for i in n + 1:
		var q: PackedFloat64Array = at.call(float(i) / float(n))
		le.append(Vector2(q[0], q[1]))
		te.append(Vector2(q[0], q[3]))
	var t: PackedFloat64Array = at.call(1.0)
	var cy := (t[1] + t[3]) / 2.0
	var ry := (t[3] - t[1]) / 2.0
	var rx := ry * (0.3 + 0.7 * tip_round)
	var right := PackedVector2Array(le)
	for k in range(1, 6):
		var a := -PI / 2.0 + float(k) / 6.0 * PI
		right.append(Vector2(t[0] + cos(a) * rx, cy + sin(a) * ry))
	te.reverse()
	right.append_array(te)
	var left := _mir(right)
	left.reverse()
	right.append_array(left)
	return right

static func _mir(q: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(q.size())
	for i in q.size():
		out[i] = Vector2(-q[i].x, q[i].y)
	return out

static func _band(fn: Callable, u0: float, u1: float, f0: float) -> PackedVector2Array:
	var a := PackedVector2Array()
	var b := PackedVector2Array()
	for i in 9:
		var q: PackedFloat64Array = fn.call(u0 + (u1 - u0) * float(i) / 8.0)
		a.append(Vector2(q[0], q[1] + q[2] * f0))
		b.append(Vector2(q[0], q[3]))
	b.reverse()
	a.append_array(b)
	return a

static func _line_at(at: Callable, u0: float, u1: float, f: float, n: int = 6) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n + 1:
		var q: PackedFloat64Array = at.call(u0 + (u1 - u0) * float(i) / float(n))
		out.append(Vector2(q[0], q[1] + q[2] * f))
	return out

static func _fin(cx: float, ya: float, yb: float, w: float) -> PackedVector2Array:
	var r := PackedVector2Array()
	var l := PackedVector2Array()
	for i in 9:
		var t := float(i) / 8.0
		var h := w * (sqrt(t / 0.25) if t < 0.25 else 1.0 - (t - 0.25) / 0.75 * 0.55)
		r.append(Vector2(cx + h, ya + (yb - ya) * t))
		l.append(Vector2(cx - h, ya + (yb - ya) * t))
	l.reverse()
	r.append_array(l)
	return r

static func _seg(a: Vector2, b: Vector2) -> PackedVector2Array:
	return PackedVector2Array([a, b])

static func build_plane(p: Dictionary) -> Dictionary:
	var L: float = p.length
	var s: float = p.span / 2.0
	var y0 := -L / 2.0
	var G := {"y0": y0}
	var engines: int = p.engines
	var booms: bool = p.booms
	var nose_eng := engines == 1 or engines == 3
	var body_l := L * 0.62 if booms else L
	var nose_r := 0.42 if nose_eng else (0.32 if p.glazed_nose else 0.24)
	var hw := body_profile(p.fuse_w, p.nose, p.fuse_w * 0.5 if booms else p.tail_w, p.body_max, nose_r)
	G.hw = hw
	G.bodyL = body_l
	G.fus = body_poly(body_l, y0, hw, 30, 0.0)
	var ctip: float = p.tip_chord * (1.0 - 0.6 * p.ellip)
	var rx: float = ctip / 2.0 * (0.3 + 0.7 * p.tip_round)
	var sw := s - rx
	var y_le: float = y0 + p.wing_at * L
	var at := wing_fn(sw, y_le, p.root_chord, p.tip_chord, p.sweep, p.ellip)
	G.wing = wing_poly(at, p.tip_round)
	var ail := _band(at, 0.56, 0.93, 0.72)
	G.ailerons = [ail, _mir(ail)]
	var ur := minf(0.4, (p.fuse_w / 2.0 + 0.06) / sw)
	var fl := _line_at(at, ur, 0.52, 0.74)
	G.flaps = [fl, _mir(fl)]
	var sp := _line_at(at, ur, 0.9, 0.3, 8)
	G.spars = [sp, _mir(sp)]
	var ribs: Array = []
	var frames_n: int = p.frames
	for i in frames_n + 1:
		var u := ur + 0.06 + (0.88 - ur - 0.06) * float(i) / float(frames_n)
		var q: PackedFloat64Array = at.call(u)
		var f1 := 0.7 if (u > 0.56 and u < 0.93) else 0.72
		for sx: float in [1.0, -1.0]:
			ribs.append(_seg(Vector2(sx * q[0], q[1] + q[2] * 0.07), Vector2(sx * q[0], q[1] + q[2] * f1)))
	G.ribs = ribs
	var nacs: Array = []
	var props: Array = []
	if nose_eng:
		props.append({"c": Vector2(0.0, y0 - float(hw.call(0.0)) * 1.1 - 0.1), "d": p.prop_dia, "sp": maxf(0.17, p.fuse_w * 0.19)})
	var us: Array = []
	if engines == 2 or engines == 3:
		us = [p.nac_at]
	elif engines == 4:
		us = [p.nac_at * 0.72, p.nac_at * 1.5]
	for u: float in us:
		var q: PackedFloat64Array = at.call(u)
		var front: float = q[1] - p.nac_len * 0.42
		var len: float = L / 2.0 - front + 0.1 if booms else p.nac_len
		var w: float = p.nac_w
		var nh := body_profile(w, 0.2 / (len / p.nac_len), w * 0.5 if booms else w * 0.22, 0.25 if booms else 0.42, 0.46)
		for sx: float in [1.0, -1.0]:
			nacs.append({"poly": body_poly(len, front, nh, 20, sx * q[0]), "x": sx * q[0], "front": front, "len": len, "hw": nh})
			props.append({"c": Vector2(sx * q[0], front - float(nh.call(0.0)) * 1.1 - 0.08), "d": p.prop_dia, "sp": w * 0.2})
	G.nacs = nacs
	G.props = props
	var t_s: float = p.tail_span / 2.0
	var t_y: float = y0 + L - p.tail_root - 0.2
	if booms:
		var q0: PackedFloat64Array = at.call(us[0])
		t_s = q0[0] + 0.45
		t_y = L / 2.0 - p.tail_root - 0.15
	var tat := wing_fn(t_s * 0.95, t_y, p.tail_root, p.tail_root * 0.92 if booms else p.tail_tip,
		0.0 if booms else 0.22, 0.0 if booms else 0.3)
	G.tail = wing_poly(tat, 0.5)
	var el := _band(tat, 0.04 if booms else 0.12, 0.9, 0.62)
	G.elevators = [el, _mir(el)]
	var fins: Array = []
	if booms:
		for n: Dictionary in nacs:
			fins.append(_fin(n.x, t_y - p.tail_root * 0.3, L / 2.0 + 0.25, maxf(0.14, p.nac_w * 0.17)))
	elif p.twin_fin:
		for sx: float in [1.0, -1.0]:
			fins.append(_fin(sx * t_s * 0.95, t_y - p.tail_root * 0.32, t_y + p.tail_root * 1.08, 0.17))
	else:
		fins.append(_fin(0.0, t_y - p.tail_root * 0.5, y0 + body_l + float(hw.call(1.0)) * 0.7, maxf(0.12, p.tail_w * 0.34)))
	G.fins = fins
	var cy0: float = y0 + p.canopy_at * L
	var cl: float = p.canopy_len
	var cw: float = p.canopy_w
	var ch := func(t: float) -> float:
		return cw / 2.0 * pow(sin(PI * pow(t, 0.8)), 0.55)
	var cr := PackedVector2Array()
	var cll := PackedVector2Array()
	for i in 13:
		var t := float(i) / 12.0
		cr.append(Vector2(ch.call(t), cy0 + cl * t))
		cll.append(Vector2(-float(ch.call(t)), cy0 + cl * t))
	cll.reverse()
	cr.append_array(cll)
	G.canopy = cr
	var cframes: Array = []
	for f: float in [0.34, 0.64]:
		var h: float = float(ch.call(f)) * 0.96
		var y := cy0 + cl * f
		cframes.append(_seg(Vector2(-h, y), Vector2(h, y)))
	G.canopyFrames = cframes
	if p.glazed_nose:
		var tg: float = p.glaze_len / body_l
		var r0: float = hw.call(0.0)
		var gp := PackedVector2Array()
		for k in range(1, 6):
			var a := PI + float(k) / 6.0 * PI
			gp.append(Vector2(cos(a) * r0, y0 + sin(a) * r0 * 1.1))
		for i in 7:
			var t := tg * float(i) / 6.0
			gp.append(Vector2(hw.call(t), y0 + t * body_l))
		for i in range(6, -1, -1):
			var t := tg * float(i) / 6.0
			gp.append(Vector2(-float(hw.call(t)), y0 + t * body_l))
		G.glaze = gp
		var gf: Array = [_seg(Vector2(0.0, y0 - r0 * 1.05), Vector2(0.0, y0 + tg * body_l))]
		for f: float in [0.4, 0.75]:
			var t := tg * f
			var h: float = float(hw.call(t)) * 0.95
			gf.append(_seg(Vector2(-h, y0 + t * body_l), Vector2(h, y0 + t * body_l)))
		G.glazeFrames = gf
	var turrets: Array = []
	if p.dorsal:
		turrets.append({"c": Vector2(0.0, y0 + p.dorsal_at * L), "r": p.fuse_w * 0.3, "dir": p.dorsal_dir * PI / 180.0, "gun": 1.4})
	if p.tail_gun:
		turrets.append({"c": Vector2(0.0, y0 + body_l - 0.1), "r": maxf(0.3, p.tail_w * 0.8), "dir": PI / 2.0, "gun": 1.0})
	G.turrets = turrets
	var guns: Array = []
	if p.wing_guns:
		var ug: Array = [0.4] if p.wing_guns == 2 else [0.34, 0.44]
		for u: float in ug:
			var q: PackedFloat64Array = at.call(u)
			for sx: float in [1.0, -1.0]:
				guns.append(_seg(Vector2(sx * q[0], q[1] + 0.25), Vector2(sx * q[0], q[1] - 0.5)))
	if p.nose_guns:
		var xs: Array = [-0.14, 0.14] if p.nose_guns == 2 else [-0.3, -0.1, 0.1, 0.3]
		for x: float in xs:
			guns.append(_seg(Vector2(x, y0 + 0.4), Vector2(x, y0 - 0.55)))
	G.guns = guns
	var qr: PackedFloat64Array = at.call(0.66)
	G.roundels = [
		{"c": Vector2(qr[0], qr[1] + qr[2] * 0.46), "r": qr[2] * 0.36},
		{"c": Vector2(-qr[0], qr[1] + qr[2] * 0.46), "r": qr[2] * 0.36},
	]
	var frames: Array = []
	if nose_eng:
		frames.append(p.nose + 0.05)
	for k in range(1, frames_n + 1):
		frames.append(0.14 + float(k) / float(frames_n + 1) * 0.8)
	G.frames = frames
	var exh: Array = []
	if nose_eng:
		for k in 3:
			var t: float = p.nose * 0.9 + 0.028 * float(k) * (10.0 / L)
			var y := y0 + t * body_l
			var hwt: float = hw.call(t)
			for sx: float in [1.0, -1.0]:
				exh.append(_seg(Vector2(sx * hwt * 0.98, y), Vector2(sx * (hwt + 0.14), y + 0.24)))
	G.exh = exh
	var sil: Array = [G.wing, G.tail, G.fus]
	for n: Dictionary in nacs:
		sil.append(n.poly)
	sil.append_array(fins)
	G.sil = sil
	var ext: Array = sil.duplicate()
	for pr: Dictionary in props:
		var c: Vector2 = pr.c
		ext.append(_seg(Vector2(c.x - pr.d / 2.0, c.y), Vector2(c.x + pr.d / 2.0, c.y)))
	G.ext = ext
	return G

# --- The ink pipeline (the sheet's, in pixels) ---------------------------------------

static func _i32(v: int) -> int:
	return ((v & MASK32) ^ 0x80000000) - 0x80000000

static func _rng(pn: Pen) -> Mulberry32:
	return Mulberry32.new(pn.next())

# _path(pn, pts, o): inkPath with the next seed.
static func _path(pn: Pen, pts: PackedVector2Array, o: Dictionary = {}) -> PackedVector2Array:
	var oo := o.duplicate()
	oo["seed"] = pn.next()
	return _ink_path(pn.g, pn.V, pn.ink, pts, oo)

# _line(pn, pts, o): an open stroke, weight .55, alpha .6 unless o says otherwise.
static func _line(pn: Pen, pts: PackedVector2Array, o: Dictionary = {}) -> PackedVector2Array:
	var oo := {"closed": false, "weight": 0.55, "alpha": 0.6}
	oo.merge(o, true)
	oo["seed"] = pn.next()
	return _ink_path(pn.g, pn.V, pn.ink, pts, oo)

static func subdivide(pts: PackedVector2Array, closed: bool, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	var lim := n if closed else n - 1
	for i in lim:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		var k := maxi(1, ceili(a.distance_to(b) / step))
		for j in k:
			var t := float(j) / float(k)
			out.append(a + (b - a) * t)
	if not closed:
		out.append(pts[n - 1])
	return out

static func perim(pts: PackedVector2Array, closed: bool) -> float:
	var s := 0.0
	for i in range(1, pts.size()):
		s += pts[i].distance_to(pts[i - 1])
	if closed and pts.size() > 1:
		s += pts[pts.size() - 1].distance_to(pts[0])
	return s

static func wobble(pts: PackedVector2Array, closed: bool, amp: float, seed_value: int) -> PackedVector2Array:
	var n := pts.size()
	if amp <= 0.0 or n < 3:
		return pts
	var per := perim(pts, closed)
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

static func add_poly(g, p: PackedVector2Array, closed: bool) -> void:
	if p.is_empty():
		return
	g.move_to(p[0].x, p[0].y)
	for i in range(1, p.size()):
		g.line_to(p[i].x, p[i].y)
	if closed:
		g.close_path()

# strokePts: the pen lifts where a noise value along the stroke falls under `breaks`.
static func stroke_pts(g, pts: PackedVector2Array, closed: bool, breaks: float, seed_value: int, freq: float) -> void:
	g.begin_path()
	if breaks == 0.0:
		add_poly(g, pts, closed)
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

# inkPath(g, pointsInMetres, {V, closed, fill, weight, alpha, breaks, wob, seed, step, freq})
static func _ink_path(g, V: View, ink: Ink, pts_m: PackedVector2Array, o: Dictionary) -> PackedVector2Array:
	var closed: bool = o.get("closed", true) != false
	var pts := subdivide(V.tps(pts_m), closed, float(o.get("step", 2.4)))
	var per := perim(pts, closed)
	var seed_value := _i32(int(o.get("seed", 0)))
	pts = wobble(pts, closed, ink.wob * float(o.get("wob", 1.0)) * 1.05 * minf(1.0, per / 90.0), seed_value)
	if o.has("fill"):
		g.begin_path()
		var clip: PackedVector2Array = o.get("clip", PackedVector2Array())
		for part: PackedVector2Array in _fillable(pts, closed):
			if clip.size() >= 3:
				# clipTo(outline): the fill only where it lies inside the outline
				for piece: PackedVector2Array in Geometry2D.intersect_polygons(part, clip):
					add_poly(g, piece, true)
			else:
				add_poly(g, part, closed)
		g.fill_color = o["fill"]
		g.fill()
	var w := float(o.get("weight", 1.2))
	if w > 0.0:
		g.stroke_color = ink.ink
		g.line_width = w * ink.lw
		g.global_alpha = float(o.get("alpha", 1.0))
		stroke_pts(g, pts, closed, float(o.get("breaks", 0.0)), seed_value + 11, float(o.get("freq", 0.07)))
		g.global_alpha = 1.0
	return pts

# A wobbled outline can cross itself where the shape is thinner than the
# wobble (a wingtip a pixel or two deep). Canvas fills that with the nonzero
# rule; InkCanvas fills simple polygons, so a crossed outline is untangled
# into simple ones first (its union), rather than left to InkCanvas's fan.
static func _fillable(pts: PackedVector2Array, closed: bool) -> Array:
	if not closed:
		return [pts]
	var p := PackedVector2Array()
	for q in pts:
		if p.is_empty() or (q - p[p.size() - 1]).length_squared() > 1e-12:
			p.append(q)
	if p.size() > 1 and (p[0] - p[p.size() - 1]).length_squared() <= 1e-12:
		p.remove_at(p.size() - 1)
	if p.size() < 3 or not Geometry2D.triangulate_polygon(p).is_empty():
		return [pts]
	# Holes come back wound the other way from outer boundaries: keep the
	# parts wound like the largest one.
	var parts := Geometry2D.merge_polygons(p, PackedVector2Array())
	if parts.is_empty():
		return [pts]
	var best := 0
	var best_area := -1.0
	for i in parts.size():
		var a := absf(_signed_area(parts[i]))
		if a > best_area:
			best_area = a
			best = i
	var outer_cw := Geometry2D.is_polygon_clockwise(parts[best])
	var out: Array = []
	for part: PackedVector2Array in parts:
		if Geometry2D.is_polygon_clockwise(part) == outer_cw:
			out.append(part)
	return out

static func _signed_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		a += p[i].cross(p[(i + 1) % p.size()])
	return a * 0.5

static func stroke_o(g, ink: Ink, pts: PackedVector2Array, w: float, alpha: float = 1.0) -> void:
	g.stroke_color = ink.ink
	g.line_width = w * ink.lw
	g.global_alpha = alpha
	g.begin_path()
	add_poly(g, pts, true)
	g.stroke()
	g.global_alpha = 1.0

static func circ(c: Vector2, r: float, n: int = 20) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU
		out.append(Vector2(c.x + cos(a) * r, c.y + sin(a) * r))
	return out

static func _bbox(o: PackedVector2Array) -> Rect2:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for p in o:
		lo = lo.min(p)
		hi = hi.max(p)
	return Rect2(lo, hi - lo)

static func _cen(o: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for p in o:
		c += p
	return c / float(maxi(1, o.size()))

# Dots of radius r: drawLobe's stipple. opt: rng, density, r, alpha, half {c, n, min}.
static func stipple(g, ink: Ink, o: PackedVector2Array, opt: Dictionary) -> void:
	var rng: Mulberry32 = opt["rng"]
	var bb := _bbox(o)
	var cnt := roundi(bb.size.x * bb.size.y * float(opt["density"]) / 100.0 * ink.stip)
	if cnt < 1:
		return
	var r := float(opt.get("r", 0.45))
	var half: Dictionary = opt.get("half", {})
	g.fill_color = ink.ink
	g.global_alpha = float(opt.get("alpha", 0.55))
	g.begin_path()
	var any := false
	for _i in cnt:
		var x := bb.position.x + rng.next() * bb.size.x
		var y := bb.position.y + rng.next() * bb.size.y
		if opt.has("away"):
			# dots only on the side away from the detail light, from the dome's centre
			var ac: Vector2 = opt["away"]
			var adx := x - ac.x
			var ady := y - ac.y
			var ad := sqrt(adx * adx + ady * ady)
			if ad == 0.0:
				ad = 1.0
			if (adx * ink.light.x + ady * ink.light.y) / ad > -0.15:
				continue
		if not half.is_empty():
			var hc: Vector2 = half["c"]
			var hn: Vector2 = half["n"]
			if (x - hc.x) * hn.x + (y - hc.y) * hn.y < float(half["min"]):
				continue
		if not Geometry2D.is_point_in_polygon(Vector2(x, y), o):
			continue  # clipTo(o)
		g.move_to(x + r, y)
		g.arc(x, y, r, 0.0, TAU)
		any = true
	if any:
		g.fill()
	g.global_alpha = 1.0

# The shaded half: the part of outline `o` on the side (p - c).n > 0.
static func shade_side(g, o: PackedVector2Array, c: Vector2, n: Vector2, col: Color) -> void:
	var B := 5000.0
	var t := Vector2(-n.y, n.x)
	var quad := PackedVector2Array([c + t * B, c + t * B + n * B, c - t * B + n * B, c - t * B])
	var parts := Geometry2D.intersect_polygons(o, quad)
	if parts.is_empty():
		return
	g.begin_path()
	for part: PackedVector2Array in parts:
		add_poly(g, part, true)
	g.fill_color = col
	g.fill()

# A cylinder along the unit's axis: the half whose normal points away from the sun.
static func shade_axis(g, ink: Ink, o: PackedVector2Array, V: View, cx: Vector2, col: Color) -> Vector2:
	var n := V.tv(Vector2(1.0, 0.0))
	var nn := n if n.dot(ink.sd) >= 0.0 else -n
	shade_side(g, o, V.tp(cx), nn, col)
	return nn

static func away_n(ink: Ink, V: View) -> Vector2:
	var n := V.tv(Vector2(1.0, 0.0))
	return -n if n.dot(ink.light) > 0.0 else n

# The prototype's slope hatching: short strokes inward from edges facing away from the sun.
static func edge_hatch(g, ink: Ink, o: PackedVector2Array, len: float, rng: Mulberry32, every: int = 2) -> void:
	var c := _cen(o)
	var n := o.size()
	if len < 1.2:
		return
	g.stroke_color = ink.ink
	g.line_width = 0.55 * ink.lw
	g.global_alpha = 0.5
	g.begin_path()
	for i in range(0, n, every):
		var a := o[(i - 1 + n) % n]
		var b := o[(i + 1) % n]
		var tx := b.x - a.x
		var ty := b.y - a.y
		var l := sqrt(tx * tx + ty * ty)
		if l == 0.0:
			l = 1.0
		var nx := -ty / l
		var ny := tx / l
		if (o[i].x - c.x) * nx + (o[i].y - c.y) * ny < 0.0:
			nx = -nx
			ny = -ny
		var f := nx * ink.sd.x + ny * ink.sd.y
		if f < 0.2 or rng.next() > 0.85:
			continue
		var ln := len * (0.28 + rng.next() * 0.3) * minf(1.0, f + 0.3)
		g.move_to(o[i].x, o[i].y)
		g.line_to(o[i].x - nx * ln, o[i].y - ny * ln)
	g.stroke()
	g.global_alpha = 1.0

# Rivet dot rows along a seam; only where the drawing is big enough to carry them.
static func rivets(g, ink: Ink, V: View, pts_m: PackedVector2Array, rng: Mulberry32, sp: float = 2.6) -> void:
	if V.ppm < 7.0:
		return
	var pts := V.tps(pts_m)
	g.fill_color = ink.ink
	g.global_alpha = 0.6
	var acc := sp * 0.5
	g.begin_path()
	var any := false
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var l := a.distance_to(b)
		var t := acc
		while t < l:
			if rng.next() > 0.1:
				var q := a + (b - a) * t / l
				g.move_to(q.x + 0.45, q.y)
				g.arc(q.x, q.y, 0.45, 0.0, TAU)
				any = true
			t += sp
		acc = t - l
	if any:
		g.fill()
	g.global_alpha = 1.0

static func roundel(pn: Pen, c: Vector2, r: float, accent: Color) -> void:
	var rp: float = r * pn.V.ppm
	if rp < 0.7:
		return
	_path(pn, circ(c, r, 24), {"fill": accent, "weight": minf(0.85, rp * 0.3)})
	if rp > 2.4:
		_path(pn, circ(c, r * 0.4, 16), {"fill": pn.ink.fill, "weight": minf(0.6, rp * 0.12)})

# --- drawPlane -------------------------------------------------------------------------

static func draw_plane(g, M: Model, V: View, ink: Ink, accent: Color) -> void:
	var G := M.G
	var p := M.p
	var pn := Pen.new(g, V, ink, M.seed + 3)
	var ppm := V.ppm
	var cream := ink.fill
	# wings and tailplane: flat surfaces take the object fill; fabric control surfaces a canvas stipple
	var wing := _path(pn, G.wing, {"fill": cream, "weight": 0.0})
	for a: PackedVector2Array in G.ailerons:
		stipple(g, ink, V.tps(a), {"rng": _rng(pn), "density": 6.0, "r": 0.45})
	for a: PackedVector2Array in G.ailerons:
		_line(pn, a.slice(0, 9), {"alpha": 0.7, "weight": 0.6})
	for f: PackedVector2Array in G.flaps:
		_line(pn, f, {"alpha": 0.55, "breaks": 0.25})
	if ppm > 6.0:
		for r: PackedVector2Array in G.ribs:
			_line(pn, r, {"alpha": 0.4, "weight": 0.5, "breaks": 0.3, "freq": 0.12})
	if p.rivets:
		for s: PackedVector2Array in G.spars:
			rivets(g, ink, V, s, _rng(pn))
	stroke_o(g, ink, wing, 1.2)
	for r: Dictionary in G.roundels:
		roundel(pn, r.c, r.r, accent)
	var tail := _path(pn, G.tail, {"fill": cream, "weight": 0.0})
	for e: PackedVector2Array in G.elevators:
		stipple(g, ink, V.tps(e), {"rng": _rng(pn), "density": 6.0, "r": 0.45})
		_line(pn, e.slice(0, 9), {"alpha": 0.7, "weight": 0.55})
	stroke_o(g, ink, tail, 1.1)
	# nacelles and booms: cylinders, shaded half on the side away from the sun
	for nc: Dictionary in G.nacs:
		var o := _path(pn, nc.poly, {"fill": cream, "weight": 0.0})
		shade_axis(g, ink, o, V, Vector2(nc.x, 0.0), ink.fill_shaded)
		stipple(g, ink, o, {"rng": _rng(pn), "density": 2.8,
			"half": {"c": V.tp(Vector2(nc.x, 0.0)), "n": away_n(ink, V), "min": p.nac_w * 0.18 * ppm}})
		edge_hatch(g, ink, o, minf(5.0, p.nac_w * 0.5 * ppm), _rng(pn))
		var yc: float = nc.front + 0.8
		var h: float = float((nc.hw as Callable).call(0.8 / nc.len)) * 0.92
		_line(pn, PackedVector2Array([Vector2(nc.x - h, yc), Vector2(nc.x + h, yc)]), {"alpha": 0.6})
		stroke_o(g, ink, o, 1.1)
	# fuselage
	var fus := _path(pn, G.fus, {"fill": cream, "weight": 0.0})
	shade_axis(g, ink, fus, V, Vector2.ZERO, ink.fill_shaded)
	stipple(g, ink, fus, {"rng": _rng(pn), "density": 2.8,
		"half": {"c": V.tp(Vector2.ZERO), "n": away_n(ink, V), "min": p.fuse_w * 0.16 * ppm}})
	edge_hatch(g, ink, fus, minf(6.0, p.fuse_w * 0.5 * ppm), _rng(pn))
	if p.fuse_w * ppm > 5.0:
		for t: float in G.frames:
			var y: float = G.y0 + t * G.bodyL
			var h: float = float((G.hw as Callable).call(t)) * 0.9
			_line(pn, PackedVector2Array([Vector2(-h, y), Vector2(h, y)]), {"alpha": 0.55, "breaks": 0.18})
			if p.rivets:
				rivets(g, ink, V, PackedVector2Array([Vector2(-h, y + 0.14), Vector2(h, y + 0.14)]), _rng(pn))
	for e: PackedVector2Array in G.exh:
		_line(pn, e, {"alpha": 0.8, "weight": 0.7})
	stroke_o(g, ink, fus, 1.2)
	for f: PackedVector2Array in G.fins:
		_path(pn, f, {"fill": cream, "weight": 0.9})
	# glass: canopy and glazed nose take the two shade steps of the roof fill
	if G.has("glaze"):
		var o := _path(pn, G.glaze, {"fill": ink.glass_lit, "weight": 0.0})
		shade_axis(g, ink, o, V, Vector2.ZERO, ink.glass_shaded)
		if ppm > 5.0:
			for f: PackedVector2Array in G.glazeFrames:
				_line(pn, f, {"alpha": 0.7, "weight": 0.5})
		stroke_o(g, ink, o, 0.85)
	var can := _path(pn, G.canopy, {"fill": ink.glass_lit, "weight": 0.0})
	shade_axis(g, ink, can, V, Vector2.ZERO, ink.glass_shaded)
	if p.canopy_w * ppm > 5.0:
		for f: PackedVector2Array in G.canopyFrames:
			_line(pn, f, {"alpha": 0.75, "weight": 0.5})
	stroke_o(g, ink, can, 0.85)
	for t: Dictionary in G.turrets:
		var tc: Vector2 = t.c
		var o := _path(pn, circ(tc, t.r, 16), {"fill": ink.glass_lit, "weight": 0.0})
		shade_side(g, o, V.tp(tc), ink.sd, ink.glass_shaded)  # shadeDome
		stroke_o(g, ink, o, 0.8)
		var dx := cos(float(t.dir))
		var dy := sin(float(t.dir))
		for off: float in [-0.09, 0.09]:
			_line(pn, PackedVector2Array([
				Vector2(tc.x - dy * off + dx * t.r * 0.3, tc.y + dx * off + dy * t.r * 0.3),
				Vector2(tc.x - dy * off + dx * t.gun, tc.y + dx * off + dy * t.gun)]), {"alpha": 0.85, "weight": 0.7})
	for gseg: PackedVector2Array in G.guns:
		_line(pn, gseg, {"alpha": 0.85, "weight": 0.7})
	# propellers: a spinning disc seen edge-on is one thin broken line; spinner on top
	for pr: Dictionary in G.props:
		var c: Vector2 = pr.c
		_line(pn, PackedVector2Array([Vector2(c.x - pr.d / 2.0, c.y), Vector2(c.x + pr.d / 2.0, c.y)]),
			{"alpha": 0.55, "weight": 0.6, "breaks": 0.2, "freq": 0.3})
		_path(pn, circ(c, pr.sp, 12), {"fill": cream, "weight": 0.75})

# --- the tank ---------------------------------------------------------------------------

# rrect(cx, cy, w, h, r, n): a rounded rectangle, n steps a corner, metres.
static func rrect(cx: float, cy: float, w: float, h: float, r: float, n: int = 3) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var hx := w / 2.0
	var hy := h / 2.0
	var rr := minf(r, minf(hx, hy))
	var corners: Array = [[cx + hx - rr, cy - hy + rr, -PI / 2.0], [cx + hx - rr, cy + hy - rr, 0.0],
		[cx - hx + rr, cy + hy - rr, PI / 2.0], [cx - hx + rr, cy - hy + rr, PI]]
	for c: Array in corners:
		for k in n + 1:
			var a: float = float(c[2]) + float(k) / float(n) * PI / 2.0
			pts.append(Vector2(float(c[0]) + cos(a) * rr, float(c[1]) + sin(a) * rr))
	return pts

static func rect_p(x0: float, y0: float, x1: float, y1: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)])

# genTank(rng): every draw in the sheet's order (the object literal's).
static func gen_tank(rng: Mulberry32) -> Dictionary:
	var p := {}
	p.length = _r(rng, 5.6, 6.6)
	p.width = _r(rng, 2.9, 3.3)
	p.track_w = _r(rng, 0.5, 0.66)
	p.glacis = _r(rng, 0.55, 0.95)
	p.deck = _r(rng, 1.7, 2.1)
	p.turret = _pick_w(rng, [["round", 0.34], ["cast", 0.33], ["welded", 0.33]])
	p.turret_r = _r(rng, 1.0, 1.2)
	p.turret_y = _r(rng, -0.55, -0.2)
	p.gun_len = _r(rng, 2.8, 4.2)
	p.gun_r = _r(rng, 0.075, 0.11)
	p.muzzle_brake = rng.next() < 0.5
	p.cupola = rng.next() < 0.8
	p.stowage = int(floorf(rng.next() * 3.0))
	p.hull_h = _r(rng, 1.5, 1.8)
	p.turret_h = _r(rng, 0.75, 0.95)
	p.rivets = rng.next() < 0.6
	return p

# buildTank(p): the geometry, metres, nose toward -y.
static func build_tank(p: Dictionary) -> Dictionary:
	var L: float = p.length
	var W: float = p.width
	var tw: float = p.track_w
	var y0 := -L / 2.0
	var G := {}
	G.tracks = [rrect(W / 2.0 - tw / 2.0, 0.03, tw, L - 0.1, 0.2), rrect(-(W / 2.0 - tw / 2.0), 0.03, tw, L - 0.1, 0.2)]
	var hx := W / 2.0 - tw * 0.86
	var cf := 0.32
	var cy: float = p.glacis * 0.55
	G.hx = hx
	G.trackGuides = [
		PackedVector2Array([Vector2(W / 2.0 - tw / 2.0, -L / 2.0 + 0.25), Vector2(W / 2.0 - tw / 2.0, L / 2.0 - 0.2)]),
		PackedVector2Array([Vector2(-(W / 2.0 - tw / 2.0), -L / 2.0 + 0.25), Vector2(-(W / 2.0 - tw / 2.0), L / 2.0 - 0.2)])]
	G.hull = PackedVector2Array([Vector2(-hx + cf, y0), Vector2(hx - cf, y0), Vector2(hx, y0 + cy), Vector2(hx, L / 2.0 - 0.18),
		Vector2(hx - 0.18, L / 2.0), Vector2(-hx + 0.18, L / 2.0), Vector2(-hx, L / 2.0 - 0.18), Vector2(-hx, y0 + cy)])
	G.glacis = PackedVector2Array([Vector2(-hx + cf, y0), Vector2(hx - cf, y0), Vector2(hx, y0 + cy), Vector2(hx, y0 + p.glacis),
		Vector2(-hx, y0 + p.glacis), Vector2(-hx, y0 + cy)])
	G.glacisLine = PackedVector2Array([Vector2(-hx, y0 + p.glacis), Vector2(hx, y0 + p.glacis)])
	var dy0: float = L / 2.0 - p.deck
	G.deckLine = PackedVector2Array([Vector2(-hx + 0.1, dy0), Vector2(hx - 0.1, dy0)])
	var gy0 := dy0 + 0.16
	var gy1: float = gy0 + p.deck * 0.36
	G.grilles = [rrect((-hx + 0.28 - 0.16) / 2.0, (gy0 + gy1) / 2.0, hx - 0.44, gy1 - gy0, 0.06),
		rrect((hx - 0.28 + 0.16) / 2.0, (gy0 + gy1) / 2.0, hx - 0.44, gy1 - gy0, 0.06)]
	G.panel = rect_p(-hx * 0.66, gy1 + 0.16, hx * 0.66, L / 2.0 - 0.28)   # accent zone: the air-recognition panel lashed across the engine deck
	G.driver = rrect(-hx * 0.45, y0 + p.glacis + 0.36, 0.6, 0.46, 0.12)
	G.bowMG = circ(Vector2(hx * 0.42, y0 + p.glacis * 0.62), 0.13, 10)
	G.exhaust = [circ(Vector2(-hx * 0.62, L / 2.0 - 0.14), 0.12, 10), circ(Vector2(hx * 0.62, L / 2.0 - 0.14), 0.12, 10)]
	var stow: Array = []
	for k in int(p.stowage):
		var sx := -1.0 if (k % 2) == 1 else 1.0
		stow.append(rrect(sx * (W / 2.0 - tw / 2.0), (-L * 0.08) if k > 0 else (L * 0.16), tw * 0.84, 0.75, 0.06))
	G.stow = stow
	G.seams = [PackedVector2Array([Vector2(-hx + 0.2, y0 + p.glacis + 0.15), Vector2(-hx + 0.2, dy0 - 0.1)]),
		PackedVector2Array([Vector2(hx - 0.2, y0 + p.glacis + 0.15), Vector2(hx - 0.2, dy0 - 0.1)])]
	var tR: float = p.turret_r
	var ty: float = p.turret_y
	var T := PackedVector2Array()
	if p.turret == "round":
		T = circ(Vector2(0.0, ty), tR, 28)
	elif p.turret == "cast":
		for i in 28:
			var a := float(i) / 28.0 * TAU
			T.append(Vector2(cos(a) * tR * (1.0 + 0.07 * sin(a)), ty + sin(a) * tR * 1.1))
	else:
		T = PackedVector2Array([Vector2(-tR * 0.6, ty - tR), Vector2(tR * 0.6, ty - tR), Vector2(tR, ty - tR * 0.32), Vector2(tR, ty + tR * 0.72),
			Vector2(tR * 0.74, ty + tR * 1.06), Vector2(-tR * 0.74, ty + tR * 1.06), Vector2(-tR, ty + tR * 0.72), Vector2(-tR, ty - tR * 0.32)])
	G.turret = T
	G.tc = Vector2(0.0, ty)
	var front: float = ty - tR * 1.1 if p.turret == "cast" else ty - tR
	G.mantlet = rrect(0.0, front - 0.1, 0.95, 0.42, 0.12)
	var g0 := front - 0.28
	var g1: float = front - p.gun_len
	G.gun = rect_p(-p.gun_r, g1, p.gun_r, g0)
	G.muzzle = rect_p(-p.gun_r * 1.8, g1 - 0.05, p.gun_r * 1.8, g1 + 0.32) if p.muzzle_brake else PackedVector2Array()
	G.cupola = circ(Vector2(tR * 0.42, ty + tR * 0.34), 0.32, 16) if p.cupola else PackedVector2Array()
	G.hatch = rrect(-tR * 0.4, ty + tR * 0.3, 0.48, 0.6, 0.1)
	var foot := rect_p(-W / 2.0, y0, W / 2.0, L / 2.0)
	G.base = foot
	G.ext = [foot, G.gun, T]
	# The footprint for the shadow mask: tracks, hull, turret and gun, unwobbled.
	G.sil = [G.tracks[0], G.tracks[1], G.hull, T, G.gun]
	return G

# hatchLines(g, o, dir, sp, opt): parallel lines across an outline, clipped to it
# (track links, grilles). `o` is in pixels, dir a unit vector in pixels.
static func hatch_lines(g, ink: Ink, o: PackedVector2Array, dir: Vector2, sp: float, opt: Dictionary) -> void:
	var rng: Mulberry32 = opt["rng"] if opt.has("rng") else Mulberry32.new(1)
	if sp < 0.6:
		return
	var bb := _bbox(o)
	var c := bb.position + bb.size * 0.5
	var R := sqrt(bb.size.x * bb.size.x + bb.size.y * bb.size.y) / 2.0 + 1.0
	var nx := -dir.y
	var ny := dir.x
	var skip: float = float(opt.get("skip", 0.0))
	var jit: float = float(opt.get("jit", 0.0))
	g.stroke_color = ink.ink
	g.line_width = float(opt.get("weight", 0.55)) * ink.lw
	g.global_alpha = float(opt.get("alpha", 0.5))
	g.begin_path()
	var d := -R
	while d <= R:
		if skip > 0.0 and rng.next() < skip:
			d += sp
			continue
		var j := (rng.next() - 0.5) * jit
		var px := c.x + nx * (d + j)
		var py := c.y + ny * (d + j)
		var seg := PackedVector2Array([Vector2(px - dir.x * R, py - dir.y * R), Vector2(px + dir.x * R, py + dir.y * R)])
		for part: PackedVector2Array in Geometry2D.clip_polyline_with_polygon(seg, o):
			if part.size() < 2:
				continue
			g.move_to(part[0].x, part[0].y)
			for qi in range(1, part.size()):
				g.line_to(part[qi].x, part[qi].y)
		d += sp
	g.stroke()
	g.global_alpha = 1.0

# accentPanel(pn, poly, side): the side's recognition panel with a lashing point at each corner.
static func accent_panel(pn: Pen, poly_m: PackedVector2Array, accent: Color) -> void:
	var o := _path(pn, poly_m, {"fill": accent, "weight": 0.75})
	var g = pn.g
	g.fill_color = pn.ink.ink
	g.global_alpha = 0.8
	if perim(o, true) > 14.0:
		g.begin_path()
		for q in pn.V.tps(poly_m):
			g.move_to(q.x + 0.55, q.y)
			g.arc(q.x, q.y, 0.55, 0.0, TAU)
		g.fill()
	g.global_alpha = 1.0

# drawTankGround + drawTankUpper, one after the other onto one canvas.
static func draw_tank(g, M: Model, V: View, ink: Ink, accent: Color) -> void:
	_draw_tank_ground(g, M, V, ink, accent)
	_draw_tank_upper(g, M, V, ink)

static func _draw_tank_ground(g, M: Model, V: View, ink: Ink, accent: Color) -> void:
	var G := M.G
	var p := M.p
	var pn := Pen.new(g, V, ink, M.seed + 5)
	var ppm := V.ppm
	var cream := ink.fill
	var along := V.tv(Vector2(1.0, 0.0))
	for t: PackedVector2Array in G.tracks:
		var o := _path(pn, t, {"fill": ink.rock, "weight": 0.0})
		hatch_lines(g, ink, o, along, maxf(1.5, 0.12 * ppm), {"alpha": 0.72, "weight": 0.6, "rng": _rng(pn), "jit": 0.25})   # track links
		stroke_o(g, ink, o, 1.1)
	if ppm > 6.0:
		for t: PackedVector2Array in G.trackGuides:
			_line(pn, t, {"alpha": 0.5, "weight": 0.5, "breaks": 0.2})
	var hull_o := _path(pn, G.hull, {"fill": cream, "weight": 0.0})
	var gn := V.tv(Vector2(0.0, -1.0))
	if gn.dot(ink.sd) > 0.2:   # the sloped plate away from the sun
		_path(pn, G.glacis, {"fill": ink.slope, "weight": 0.0, "clip": hull_o})
	_line(pn, G.glacisLine, {"alpha": 0.7, "weight": 0.65, "breaks": 0.12})
	_line(pn, G.deckLine, {"alpha": 0.6, "breaks": 0.15})
	for gr: PackedVector2Array in G.grilles:
		var o := _path(pn, gr, {"weight": 0.6, "alpha": 0.8})
		hatch_lines(g, ink, o, along, maxf(1.5, 0.13 * ppm), {"alpha": 0.55, "weight": 0.5, "rng": _rng(pn)})
	if p.rivets:
		for sm: PackedVector2Array in G.seams:
			rivets(g, ink, V, sm, _rng(pn))
	_path(pn, G.driver, {"fill": cream, "weight": 0.65})
	_path(pn, G.bowMG, {"fill": cream, "weight": 0.6})
	for e: PackedVector2Array in G.exhaust:
		_path(pn, e, {"fill": cream, "weight": 0.6})
	edge_hatch(g, ink, hull_o, minf(4.0, 0.4 * ppm), _rng(pn))
	accent_panel(pn, G.panel, accent)
	stroke_o(g, ink, hull_o, 1.2)
	for sw: PackedVector2Array in G.stow:
		_path(pn, sw, {"fill": cream, "weight": 0.85})
		if ppm > 8.0:
			var cc := _cen(sw)
			_line(pn, PackedVector2Array([Vector2(cc.x - 0.3, cc.y), Vector2(cc.x + 0.3, cc.y)]), {"alpha": 0.5})

static func _draw_tank_upper(g, M: Model, V: View, ink: Ink) -> void:
	var G := M.G
	var p := M.p
	var pn := Pen.new(g, V, ink, M.seed + 9)
	var ppm := V.ppm
	var cream := ink.fill
	var t_o := _path(pn, G.turret, {"fill": cream, "weight": 0.0})
	shade_side(g, t_o, V.tp(G.tc), ink.sd, ink.fill_shaded)   # shadeDome
	stipple(g, ink, t_o, {"rng": _rng(pn), "density": 2.6, "away": V.tp(G.tc)})
	edge_hatch(g, ink, t_o, minf(5.0, p.turret_r * 0.45 * ppm), _rng(pn))
	stroke_o(g, ink, t_o, 1.2)
	_path(pn, G.hatch, {"weight": 0.6, "alpha": 0.85})
	if G.cupola.size() > 0:
		_path(pn, G.cupola, {"fill": cream, "weight": 0.8})
		if ppm > 9.0:
			var cc := _cen(G.cupola)
			_path(pn, circ(cc, 0.2, 12), {"weight": 0.5, "alpha": 0.7, "breaks": 0.25})
	var m_o := _path(pn, G.mantlet, {"fill": cream, "weight": 0.0})
	shade_side(g, m_o, _cen(m_o), ink.sd, ink.fill_shaded)
	stroke_o(g, ink, m_o, 0.95)
	var g_o := _path(pn, G.gun, {"fill": cream, "weight": 0.0})
	shade_axis(g, ink, g_o, V, Vector2.ZERO, ink.fill_shaded)
	stroke_o(g, ink, g_o, 0.9)
	if G.muzzle.size() > 0:
		_path(pn, G.muzzle, {"fill": cream, "weight": 0.85})

# --- The bake ---------------------------------------------------------------------------

static func ink_consts(st: RefCounted) -> Ink:
	var ink := Ink.new()
	ink.lw = st.param("line_weight")
	ink.wob = st.param("hand_wobble")
	ink.stip = st.num("unit_art.stipple")
	ink.ink = st.color("art_ink")
	ink.fill = st.color("art_fill")
	ink.fill_shaded = st.color("art_fill_shaded")
	ink.glass_lit = st.color("art_glass_lit")
	ink.glass_shaded = st.color("art_glass_shaded")
	# ROCK is the palette's rock_fill; slope(CREAM) the object fill with the wall-slope
	# share of the shadow tint mixed in (the prototype's mix(shadowCol, fill, .7)).
	ink.rock = st.palette["rock_fill"]
	ink.slope = UiStyle.mix8(st.palette["shadow"], st.palette["object_fill"], 1.0 - float(st.mixes["wall_slope_shadow_mix"]))
	ink.sd = st.shadow_dir()
	ink.light = st.detail_light
	return ink

# The drawn wing's half-span in the art's own metres: the largest |x| of the wing outline
# (x to starboard, nose up). A wingtip is that far from the centre line on the drawn plane,
# whatever the zoom: a screen distance of half_span_m x px-per-metre x marker.true_scale.
# 0 for a silhouette with no wing (a tank). Wingtip trails start here.
static func half_span_m(st: RefCounted, silhouette: String) -> float:
	if not is_plane(silhouette):
		return 0.0
	var m := model_for(st, silhouette)
	var hx := 0.0
	for q: Vector2 in m.G.wing:
		hx = maxf(hx, absf(q.x))
	return hx

# Where the model reaches, metres, nose up: G.ext's bounding box.
static func extent_box(M: Model) -> Rect2:
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for poly: PackedVector2Array in M.G.ext:
		for q in poly:
			lo = lo.min(q)
			hi = hi.max(q)
	return Rect2(lo, hi - lo)

static func _bake(st: RefCounted, M: Model, accent: Color, ppm: float) -> Art:
	var margin: float = st.num("unit_art.bake_margin_px")
	var box := extent_box(M)
	var size := Vector2i(ceili(box.size.x * ppm + 2.0 * margin), ceili(box.size.y * ppm + 2.0 * margin))
	var V := View.new(-box.position.x * ppm + margin, -box.position.y * ppm + margin, ppm, 0.0)
	var ink := ink_consts(st)
	var art_canvas = InkCanvas.new(size)
	art_canvas.line_cap = "round"
	if is_tank(M.silhouette):
		draw_tank(art_canvas, M, V, ink, accent)
	else:
		draw_plane(art_canvas, M, V, ink, accent)
	# The "air" shadow mask: the silhouettes, unwobbled, filled as one.
	var mask_canvas = InkCanvas.new(size)
	mask_canvas.begin_path()
	for poly: PackedVector2Array in M.G.sil:
		add_poly(mask_canvas, V.tps(poly), true)
	mask_canvas.fill_color = Color.WHITE  # a mask, not a drawn colour: the shadow role tints it
	mask_canvas.fill()
	var imgs := InkCanvas.render_all([art_canvas, mask_canvas])
	var art := Art.new()
	art.ppm = ppm
	art.origin = Vector2(V.x, V.y)
	art.size_px = size
	var far := 0.0
	for poly: PackedVector2Array in M.G.ext:
		for q in poly:
			far = maxf(far, q.length())
	art.extent_m = far
	if imgs.size() == 2 and imgs[0] != null and not imgs[0].is_empty():
		art.texture = ImageTexture.create_from_image(_straight(imgs[0], false))
		art.mask = ImageTexture.create_from_image(_straight(imgs[1], true))
	return art

# InkCanvas images are PREMULTIPLIED; a Sprite2D wants straight alpha. A mask
# keeps only its coverage (white).
static func _straight(img: Image, white: bool) -> Image:
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	for i in range(0, data.size(), 4):
		var a := data[i + 3]
		if a == 0:
			continue
		if white:
			data[i] = 255
			data[i + 1] = 255
			data[i + 2] = 255
		elif a < 255:
			data[i] = mini(255, roundi(data[i] * 255.0 / a))
			data[i + 1] = mini(255, roundi(data[i + 1] * 255.0 / a))
			data[i + 2] = mini(255, roundi(data[i + 2] * 255.0 / a))
	return Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, data)
