extends RefCounted

# One puff of smoke, drawn through the drawing layer (InkCanvas), so the pen,
# the supersampling and the premultiplied alpha match the map. Four FORMS, one
# per damage-smoke option (data/fx/fx.json smoke.options):
#
#   lobed    the art plan's proposed treatment: the tree generator's lobes
#            (scripts/render/ink_sprites.gd scallop), a paper-light fill, an ink
#            scallop outline, a shadow-tint underside on the side away from the
#            light, a little stipple there. Three tones climb toward the dirt ink
#   stipple  no fill and no outline: ink dots thicker on the shadow side and
#            short hatch strokes, over a faint pale patch
#   rings    the tree's nested broken contour rings, no fill: see-through smoke
#   wash     lobes filled with the ink at the palette's alpha steps, outlined
#
# A puff is baked once per (option, scale, plane size) as a small set of sprites
# (3 tones x N variants, each with a white mask for the ground shadow) and
# placed, scaled and faded by the layer. Colours are roles (FxStyle); sizes are
# metres x the plane's drawn px per metre (the planes are drawn at their own
# scale, so is their smoke).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")

const TONES := 3

class PuffSet:
	var tex: Array = []          # tone -> Array[Texture2D]  (straight alpha)
	var mask: Array = []         # tone -> Array[Texture2D]  (white)
	var origin: Array = []       # tone -> Vector2: the puff's centre in texture px
	var radius_px: Array = []    # tone -> float: the radius the tone was baked at
	var ppm: float = 1.0
	var size_m: float = 9.0
	var variants: int = 0

# --- Intensity -> what a puff is ------------------------------------------------------------------

# Damage d = 1 - health fraction (0 none .. 1 dead) -> the smoke intensity 0..1:
# nothing at full health, `intensity_floor` at the first lost pip, rising linearly.
static func intensity(o: Dictionary, health_fraction: float) -> float:
	if health_fraction >= 1.0:
		return 0.0
	var d := clampf(1.0 - health_fraction, 0.0, 1.0)
	var fl := FxData.f(o, "intensity_floor")
	return clampf(fl + (1.0 - fl) * d, 0.0, 1.0)

static func tone_of(o: Dictionary, i: float) -> int:
	var e := FxData.arr(o, "tone_edges")
	var t := 0
	for k in e.size():
		if i >= float(e[k]):
			t = k + 1
	return mini(t, TONES - 1)

# The puff's radius in metres for a plane of `size_m`, at intensity i.
static func radius_m(o: Dictionary, i: float, size_m: float) -> float:
	return FxData.lerp_pair(o, "radius_frac", i) * size_m

static func interval_s(o: Dictionary, i: float) -> float:
	return FxData.lerp_pair(o, "interval_s", i)

static func life_s(o: Dictionary, i: float) -> float:
	return FxData.lerp_pair(o, "life_s", i)

# Scale of the puff (1 = as baked) and its alpha at age fraction u (0 born .. 1 gone).
static func grow_at(o: Dictionary, u: float) -> float:
	var tau := maxf(FxData.f(o, "grow_tau"), 1e-3)   # it swells fast, then hangs
	var e := (1.0 - exp(-clampf(u, 0.0, 1.0) / tau)) / (1.0 - exp(-1.0 / tau))
	return FxData.lerp_pair(o, "grow", e)

static func alpha_at(o: Dictionary, u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	var hold := FxData.f(o, "hold")
	var a := 1.0
	if u > hold:
		a = pow(1.0 - (u - hold) / maxf(1.0 - hold, 1e-6), FxData.f(o, "fade_power"))
	var steps := FxData.arr(o, "alpha_steps")
	if steps.size() > 0:
		# The fade in the palette's alpha steps (listed high to low): the smallest step still at or above `a`.
		if a <= 0.0:
			return 0.0
		var best := float(steps[0])
		for s in steps:
			if float(s) >= a - 1e-6:
				best = float(s)
		a = best
	return a

# --- Baking ---------------------------------------------------------------------------------------------

# The nominal intensity a tone is baked at (the middle of its band).
static func tone_intensity(o: Dictionary, tone: int) -> float:
	var e := FxData.arr(o, "tone_edges")
	var lo := FxData.f(o, "intensity_floor") if tone == 0 else float(e[tone - 1])
	var hi := 1.0 if tone >= e.size() else float(e[tone])
	return (lo + hi) * 0.5

static func bake_set(st: FxStyle, o: Dictionary, ppm: float, size_m: float) -> PuffSet:
	var ps := PuffSet.new()
	ps.ppm = ppm
	ps.size_m = size_m
	ps.variants = FxData.i(o, "variants")
	if not FxBake.can_bake():
		return null
	var canvases: Array = []
	var meta: Array = []
	var margin := 3.0
	for tone in TONES:
		var r_px := maxf(radius_m(o, tone_intensity(o, tone), size_m) * ppm, 2.5)
		var half := int(ceil(r_px * 1.12 + margin))
		ps.radius_px.append(r_px)
		ps.origin.append(Vector2(half, half))
		ps.tex.append([])
		ps.mask.append([])
		for v in ps.variants:
			var seed_v := FxBake.seed_of(FxData.s(o, "form"), tone * 97 + v, int(size_m * 10.0))
			var g := InkCanvas.new(Vector2i(half * 2, half * 2))
			g.line_cap = "round"
			draw_puff(g, st, o, tone, seed_v, r_px, Vector2(half, half))
			var m := InkCanvas.new(Vector2i(half * 2, half * 2))
			draw_mask(m, st, o, tone, seed_v, r_px, Vector2(half, half))
			canvases.append(g)
			canvases.append(m)
			meta.append([tone, v])
	var imgs := FxBake.render(canvases)
	for k in meta.size():
		var tone: int = meta[k][0]
		(ps.tex[tone] as Array).append(FxBake.texture(imgs[2 * k], false))
		(ps.mask[tone] as Array).append(FxBake.texture(imgs[2 * k + 1], true))
	return ps

# --- Drawing --------------------------------------------------------------------------------------------

# One puff at `at` (canvas px) with extent radius r_px.
static func draw_puff(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, seed_v: int, r_px: float, at: Vector2) -> void:
	var form := FxData.s(o, "form")
	var rng := Mulberry32.new(seed_v)
	match form:
		"lobed", "wash":
			_draw_lobes(g, st, o, tone, rng, r_px, at, form == "wash", false)
		"rings":
			_draw_rings(g, st, o, tone, rng, r_px, at)
		"stipple":
			_draw_stipple(g, st, o, tone, rng, r_px, at)
		_:
			push_error("FxPuff: unknown form '%s'" % form)

# The silhouette, white, for the puff's ground shadow.
static func draw_mask(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, seed_v: int, r_px: float, at: Vector2) -> void:
	var form := FxData.s(o, "form")
	var rng := Mulberry32.new(seed_v)
	match form:
		"lobed", "wash", "rings":
			_draw_lobes(g, st, o, tone, rng, r_px, at, false, true)
		_:
			# stipple: the pale patch it sits on
			var pts := _patch(st, o, rng, r_px, at)
			InkSprites.trace_path(g, pts)
			g.fill_color = Color.WHITE
			g.fill()

static func _lobe_set(o: Dictionary, rng: Mulberry32, r_px: float, at: Vector2) -> Array:
	var lx := 0.0
	var ly := 0.0
	var n := FxData.i(o, "lobes_min") + int(rng.next() * float(FxData.i(o, "lobes_max") - FxData.i(o, "lobes_min") + 1))
	var a0 := rng.next() * TAU
	var lobes: Array[Dictionary] = []
	for i in n:
		var a := a0 + float(i) / float(n) * TAU + (rng.next() - 0.5) * 0.5
		var d := r_px * (FxData.f(o, "lobe_d") + rng.next() * FxData.f(o, "lobe_d_var"))
		lobes.append({"x": at.x + cos(a) * d, "y": at.y + sin(a) * d, "R": r_px * (FxData.f(o, "lobe_r") + rng.next() * FxData.f(o, "lobe_r_var"))})
	return [lobes, lx, ly]

static func _draw_lobes(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, rng: Mulberry32, r_px: float, at: Vector2, wash: bool, mask_only: bool) -> void:
	var light := st.detail_light
	var lset := _lobe_set(o, rng, r_px, at)
	var lobes: Array[Dictionary] = lset[0]
	# far-from-light lobes first, as the tree draws them
	lobes.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return (p.x - at.x) * light.x + (p.y - at.y) * light.y < (q.x - at.x) * light.x + (q.y - at.y) * light.y)
	lobes.append({"x": at.x + (rng.next() - 0.5) * r_px * 0.12, "y": at.y + (rng.next() - 0.5) * r_px * 0.12, "R": r_px * FxData.f(o, "crown_r")})
	var roles_lit := FxData.arr(o, "lit_roles")
	var roles_shade := FxData.arr(o, "shade_roles")
	var lit: Color = st.color(str(roles_lit[tone]))
	var shade: Color = st.color(str(roles_shade[tone]))
	var ink: Color = st.color(FxData.s(o, "outline_role"))
	var underside := FxData.b(o, "underside")
	var stip_n := FxData.f(o, "stipple_per_r")
	var ticks := FxData.b(o, "ticks")
	var rings := FxData.i(o, "rings")
	var wob := st.wobble()
	var weight := st.line_weight() * st.lw(FxData.s(o, "outline_weight_of")) * FxData.f(o, "outline_scale") * clampf(r_px / FxData.f(o, "outline_ref_px"), FxData.f(o, "outline_min_scale"), 1.0)
	var soft: Color = st.color(FxData.s(o, "stipple_role"))
	var ring_col: Color = st.color(FxData.s(o, "ring_role"))
	var union := wash or lit.a < 1.0   # a translucent fill is ONE union fill, so overlapping lobes never darken twice
	var shapes: Array = []   # per lobe: [outline pts, inner pts, n, ph, amps, ns]
	for L in lobes:
		var R: float = L.R
		var n := maxi(5, roundi(FxData.f(o, "scallop_base") + R / FxData.f(o, "scallop_div")))
		var ph := rng.next() * PI
		var ns := int(rng.next() * 1e6)
		var amps := PackedFloat64Array()
		for _i in n:
			amps.push_back(FxData.f(o, "lobe_amp") + rng.next() * FxData.f(o, "lobe_amp_var"))
		var outline: Array = InkSprites.scallop(L.x, L.y, R, n, ph, amps, wob, ns)
		shapes.append([outline[0], n, ph, amps, ns])
	if mask_only:
		g.fill_color = Color.WHITE
		g.begin_path()
		for sh in shapes:
			_add_poly(g, sh[0])
		g.fill()
		return
	var k := FxData.f(o, "lit_shift")
	var outer_only := union and FxData.b(o, "outline_union")
	var outer := PackedVector2Array()
	if outer_only:
		# one outline round the merged silhouette; the lobes inside are not drawn
		var cur: PackedVector2Array = shapes[0][0]
		for j in range(1, shapes.size()):
			var res: Array = Geometry2D.merge_polygons(cur, shapes[j][0])
			var best := -1.0
			for poly: PackedVector2Array in res:
				if Geometry2D.is_polygon_clockwise(poly):
					continue   # a hole
				var area := absf(_area(poly))
				if area > best:
					best = area
					cur = poly
		outer = cur
	if union:
		g.begin_path()
		for sh in shapes:
			_add_poly(g, sh[0])
		g.fill_color = lit
		g.fill()
		if underside:
			# a second wash toward the shadow side: lobes shrunk and pushed away from the light, composited once
			var a_sh := clampf(1.0 - (1.0 - shade.a) / maxf(1.0 - lit.a, 1e-6), 0.0, 1.0)
			g.begin_path()
			for j in lobes.size():
				var L: Dictionary = lobes[j]
				var sh: Array = shapes[j]
				var R: float = L.R
				var inner: Array = InkSprites.scallop(L.x - light.x * R * k * 0.8, L.y - light.y * R * k * 0.8, R * (1.0 - k), sh[1], sh[2], sh[3], wob, sh[4])
				_add_poly(g, inner[0])
			g.fill_color = Color(shade.r, shade.g, shade.b, a_sh)
			g.fill()
	for j in lobes.size():
		var L: Dictionary = lobes[j]
		var sh: Array = shapes[j]
		var R: float = L.R
		var pts: PackedVector2Array = sh[0]
		var n: int = sh[1]
		var ph: float = sh[2]
		var amps: PackedFloat64Array = sh[3]
		var ns: int = sh[4]
		if not union:
			if underside:
				InkSprites.trace_path(g, pts)
				g.fill_color = shade
				g.fill()
				var inner: Array = InkSprites.scallop(L.x + light.x * R * k, L.y + light.y * R * k, R * (1.0 - k), n, ph, amps, wob, ns)
				InkSprites.trace_path(g, inner[0])
				g.fill_color = lit
				g.fill()
			else:
				InkSprites.trace_path(g, pts)
				g.fill_color = lit
				g.fill()
		# nested broken rings toward the light (the rings option)
		for q in range(1, rings + 1):
			var s := 1.0 - float(q) * (0.68 / (float(rings) + 0.4))
			var nk := maxi(3, n - q)
			var am := PackedFloat64Array()
			for _i in nk:
				am.push_back(0.1 + rng.next() * 0.1)
			var ring: Array = InkSprites.scallop(L.x + light.x * R * 0.1 * q, L.y + light.y * R * 0.1 * q, R * s, nk, ph + q * 0.7, am, wob, ns + q * 31)
			var rp: PackedVector2Array = ring[0]
			var ri: PackedInt32Array = ring[1]
			g.stroke_color = ring_col
			g.line_width = st.line_weight() * st.lw("tree_inner_rings")
			g.begin_path()
			var seg := -1
			var draw := false
			for jj in rp.size():
				if ri[jj] != seg:
					seg = ri[jj]
					draw = rng.next() < 0.8
					if draw:
						g.move_to(rp[jj].x, rp[jj].y)
					continue
				if draw:
					g.line_to(rp[jj].x, rp[jj].y)
			g.stroke()
		if not outer_only:
			InkSprites.trace_path(g, pts)
			g.stroke_color = ink
			g.line_width = weight
			g.stroke()
		if ticks:
			g.stroke_color = ink
			g.line_width = st.line_weight() * st.lw("cusp_ticks")
			g.begin_path()
			for m in range(1, n + 1):
				if rng.next() > 0.45:
					continue
				var th := 2.0 * (m * PI - ph) / n
				var rr := R * (1.0 - amps[m % n])
				var cx: float = L.x + cos(th) * rr
				var cy: float = L.y + sin(th) * rr
				g.move_to(cx, cy)
				g.line_to(cx - cos(th) * R * 0.15, cy - sin(th) * R * 0.15)
			g.stroke()
		# stipple on the side away from the light
		if stip_n > 0.0:
			g.fill_color = soft
			var dots := roundi(R * stip_n)
			g.begin_path()
			for _i in dots:
				var a := rng.next() * TAU
				var d := sqrt(rng.next()) * R * 0.78
				var dx := cos(a)
				var dy := sin(a)
				if dx * light.x + dy * light.y > -0.15:
					continue
				g.move_to(L.x + dx * d + 0.45, L.y + dy * d)
				g.arc(L.x + dx * d, L.y + dy * d, 0.45, 0.0, TAU)
			g.fill()
	if outer_only and outer.size() > 2:
		InkSprites.trace_path(g, outer)
		g.stroke_color = ink
		g.line_width = weight
		g.stroke()

static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return a * 0.5

# Adds a polygon as its own subpath of the current path.
static func _add_poly(g: InkCanvas, pts: PackedVector2Array) -> void:
	for i in pts.size():
		if i == 0:
			g.move_to(pts[i].x, pts[i].y)
		else:
			g.line_to(pts[i].x, pts[i].y)
	g.close_path()

static func _draw_rings(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, rng: Mulberry32, r_px: float, at: Vector2) -> void:
	# A lobed puff with the fill left to the data's `fill_roles` (a faint wash, or none) and the rings on.
	_draw_lobes(g, st, o, tone, rng, r_px, at, false, false)

static func _patch(st: FxStyle, o: Dictionary, rng: Mulberry32, r_px: float, at: Vector2) -> PackedVector2Array:
	var n := 7
	var amps := PackedFloat64Array()
	for _i in n:
		amps.push_back(0.2 + rng.next() * 0.16)
	var out: Array = InkSprites.scallop(at.x, at.y, r_px * FxData.f(o, "patch_r"), n, rng.next() * PI, amps, st.wobble(), int(rng.next() * 1e6))
	return out[0]

static func _draw_stipple(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, rng: Mulberry32, r_px: float, at: Vector2) -> void:
	var light := st.detail_light
	var under: Color = st.color(FxData.s(o, "underlay_role"))
	if under.a > 0.0:
		InkSprites.trace_path(g, _patch(st, o, rng, r_px, at))
		g.fill_color = under
		g.fill()
	else:
		_patch(st, o, rng, r_px, at)   # keep the stream the same either way
	var dens: Array = FxData.arr(o, "dots_per_px2")
	var count := roundi(PI * r_px * r_px * float(dens[tone]))
	var dot_r := FxData.f(o, "dot_px")
	var dark: Color = st.color(FxData.s(o, "dot_role"))
	var soft: Color = st.color(FxData.s(o, "dot_soft_role"))
	var bias := FxData.f(o, "shadow_bias")
	g.begin_path()
	g.fill_color = dark
	var made := 0
	var tries := 0
	var soft_pts := PackedVector2Array()
	while made < count and tries < count * 8:
		tries += 1
		var a := rng.next() * TAU
		var d := pow(rng.next(), FxData.f(o, "core_bias")) * r_px * 0.95
		var dx := cos(a)
		var dy := sin(a)
		# thicker on the side away from the light
		var away := -(dx * light.x + dy * light.y)
		if rng.next() > (1.0 - bias) + bias * (0.5 + 0.5 * away):
			continue
		var p := Vector2(at.x + dx * d, at.y + dy * d)
		made += 1
		if rng.next() < 0.3:
			soft_pts.push_back(p)
			continue
		var rr := dot_r * (0.8 + rng.next() * 0.6)
		g.move_to(p.x + rr, p.y)
		g.arc(p.x, p.y, rr, 0.0, TAU)
	g.fill()
	g.begin_path()
	g.fill_color = soft
	for p in soft_pts:
		g.move_to(p.x + dot_r, p.y)
		g.arc(p.x, p.y, dot_r, 0.0, TAU)
	g.fill()
	# short hatch strokes on the shadow side
	var hatch: Array = FxData.arr(o, "hatch_count")
	var ink: Color = st.color(FxData.s(o, "hatch_role"))
	g.stroke_color = ink
	g.line_width = st.line_weight() * FxData.f(o, "hatch_weight")
	g.begin_path()
	var hn := int(hatch[tone])
	var made_h := 0
	var htries := 0
	while made_h < hn and htries < hn * 10:
		htries += 1
		var a := rng.next() * TAU
		var d := sqrt(rng.next()) * r_px * 0.8
		var dx := cos(a)
		var dy := sin(a)
		if dx * light.x + dy * light.y > 0.1:
			continue
		made_h += 1
		var len := r_px * (0.18 + rng.next() * 0.2)
		var p := Vector2(at.x + dx * d, at.y + dy * d)
		g.move_to(p.x, p.y)
		g.line_to(p.x + len * 0.7071, p.y + len * 0.7071)
	g.stroke()
