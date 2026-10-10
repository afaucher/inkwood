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
const FxFlash = preload("res://scripts/fx/fx_flash.gd")

const TONES := 3

class PuffSet:
	var tex: Array = []          # tone -> Array[Texture2D]  (straight alpha)
	var mask: Array = []         # tone -> Array[Texture2D]  (white)
	var origin: Array = []       # tone -> Vector2: the puff's centre in texture px
	var radius_px: Array = []    # tone -> float: the radius the tone was baked at
	var ppm: float = 1.0
	var size_m: float = 9.0
	var variants: int = 0
	var stages: int = 1          # age stages: tex[tone] holds variants x stages sprites, index = variant + variants x stage

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
	a *= FxData.f(o, "peak_alpha")
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

# The age stage a puff is drawn in at age fraction u: a puff whose rings thin and break as it
# ages is baked in `stages` drawings and shows the one its age has reached.
static func stage_of(o: Dictionary, u: float) -> int:
	var n := FxData.i(o, "stages")
	if n <= 1:
		return 0
	var e := FxData.arr(o, "stage_edges")
	var k := 0
	for x in e:
		if u >= float(x):
			k += 1
	return mini(k, n - 1)

# Whether a puff of this tone casts a ground shadow (thick smoke does; Alex 2026-10-10).
static func casts_shadow(o: Dictionary, tone: int) -> bool:
	return FxData.b(o, "ground_shadow") and tone >= FxData.i(o, "shadow_min_tone")

# The puff drawing's stretch along the way it was flying: (x, y) scales, area kept roughly the
# same: x along the flight path, which the layer turns to the puff's `dir`.
static func stretch_xy(o: Dictionary) -> Vector2:
	var s := FxData.f(o, "stretch")
	if absf(s - 1.0) < 1e-6:
		return Vector2.ONE
	return Vector2(pow(s, 0.6), pow(s, -0.4))

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
	ps.stages = maxi(FxData.i(o, "stages"), 1)
	if not FxBake.can_bake():
		return null
	var canvases: Array = []
	var meta: Array = []
	var margin := 3.0
	var sv := stretch_xy(o)
	for tone in TONES:
		var r_px := maxf(radius_m(o, tone_intensity(o, tone), size_m) * ppm, 2.5)
		var half_x := int(ceil(r_px * sv.x * 1.12 + margin))
		var half_y := int(ceil(r_px * sv.y * 1.12 + margin))
		ps.radius_px.append(r_px)
		ps.origin.append(Vector2(half_x, half_y))
		ps.tex.append([])
		ps.mask.append([])
		for stage in ps.stages:
			for v in ps.variants:
				var seed_v := FxBake.seed_of(FxData.s(o, "form"), tone * 97 + v, int(size_m * 10.0))
				var g := InkCanvas.new(Vector2i(half_x * 2, half_y * 2))
				g.line_cap = "round"
				draw_puff(g, st, o, tone, seed_v, r_px, Vector2(half_x, half_y), stage)
				canvases.append(g)
				meta.append([tone, v, stage, false])
				if stage == 0:
					var m := InkCanvas.new(Vector2i(half_x * 2, half_y * 2))
					draw_mask(m, st, o, tone, seed_v, r_px, Vector2(half_x, half_y))
					canvases.append(m)
					meta.append([tone, v, stage, true])
	var imgs := FxBake.render(canvases)
	for k in meta.size():
		var tone: int = meta[k][0]
		if bool(meta[k][3]):
			(ps.mask[tone] as Array).append(FxBake.texture(imgs[k], true))
		else:
			(ps.tex[tone] as Array).append(FxBake.texture(imgs[k], false))
	return ps

# --- Drawing --------------------------------------------------------------------------------------------

# One puff at `at` (canvas px) with extent radius r_px, in age stage `stage` (the rings thin and
# break as it ages; stage 0 is the fresh drawing).
static func draw_puff(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, seed_v: int, r_px: float, at: Vector2, stage: int = 0) -> void:
	var form := FxData.s(o, "form")
	var rng := Mulberry32.new(seed_v)
	var sv := stretch_xy(o)
	var c := at
	if sv != Vector2.ONE:
		g.save()
		g.translate(at.x, at.y)
		g.scale(sv.x, sv.y)
		c = Vector2.ZERO
	match form:
		"lobed", "wash":
			_draw_lobes(g, st, o, tone, rng, r_px, c, form == "wash", false, seed_v, stage)
		"rings":
			_draw_lobes(g, st, o, tone, rng, r_px, c, false, false, seed_v, stage)
		"soft":
			_draw_lobes(g, st, o, tone, rng, r_px, c, false, false, seed_v, stage)
		"arcs":
			_draw_arcs(g, st, o, tone, rng, r_px, c, seed_v, stage)
		"stipple":
			_draw_stipple(g, st, o, tone, rng, r_px, c)
		"ragged":
			FxFlash.draw_ragged(g, st, o, tone, rng, r_px, c, false, stage)
		_:
			push_error("FxPuff: unknown form '%s'" % form)
	if sv != Vector2.ONE:
		g.restore()

# The silhouette, white, for the puff's ground shadow.
static func draw_mask(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, seed_v: int, r_px: float, at: Vector2) -> void:
	var form := FxData.s(o, "form")
	var rng := Mulberry32.new(seed_v)
	var sv := stretch_xy(o)
	var c := at
	if sv != Vector2.ONE:
		g.save()
		g.translate(at.x, at.y)
		g.scale(sv.x, sv.y)
		c = Vector2.ZERO
	match form:
		"lobed", "wash", "rings", "soft":
			_draw_lobes(g, st, o, tone, rng, r_px, c, false, true, seed_v, 0)
		"ragged":
			FxFlash.draw_ragged(g, st, o, tone, rng, r_px, c, true, 0)
		_:
			# stipple, arcs: the patch they sit on
			var pts := _patch(st, o, rng, r_px, c)
			InkSprites.trace_path(g, pts)
			g.fill_color = Color.WHITE
			g.fill()
	if sv != Vector2.ONE:
		g.restore()

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

static func _draw_lobes(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, rng: Mulberry32, r_px: float, at: Vector2, wash: bool, mask_only: bool, seed_v: int = 0, stage: int = 0) -> void:
	var light := st.detail_light
	var lset := _lobe_set(o, rng, r_px, at)
	var lobes: Array[Dictionary] = lset[0]
	# far-from-light lobes first, as the tree draws them
	lobes.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return (p.x - at.x) * light.x + (p.y - at.y) * light.y < (q.x - at.x) * light.x + (q.y - at.y) * light.y)
	lobes.append({"x": at.x + (rng.next() - 0.5) * r_px * 0.12, "y": at.y + (rng.next() - 0.5) * r_px * 0.12, "R": r_px * FxData.f(o, "crown_r")})
	var roles_lit := FxData.arr(o, "lit_roles")
	var roles_shade := FxData.arr(o, "shade_roles")
	var soft_form := FxData.s(o, "form") == "soft"
	var role_i := (stage * TONES + tone) if soft_form else tone
	var lit: Color = st.color(str(roles_lit[mini(role_i, roles_lit.size() - 1)]))
	var shade: Color = st.color(str(roles_shade[mini(role_i, roles_shade.size() - 1)]))
	var ink: Color = st.color(FxData.s(o, "outline_role"))
	var underside := FxData.b(o, "underside")
	var stip_n := FxData.f(o, "stipple_per_r")
	var ticks := FxData.b(o, "ticks")
	var rings := FxData.i(o, "rings")
	var wob := st.wobble()
	var weight := st.line_weight() * st.lw(FxData.s(o, "outline_weight_of")) * FxData.f(o, "outline_scale") * clampf(r_px / FxData.f(o, "outline_ref_px"), FxData.f(o, "outline_min_scale"), 1.0)
	var soft: Color = st.color(FxData.s(o, "stipple_role"))
	var ring_col: Color = st.color(FxData.s(o, "ring_role"))
	var ring_amp := FxData.f(o, "ring_amp")
	var ring_amp_var := FxData.f(o, "ring_amp_var")
	var dashed := FxData.s(o, "ring_style") == "dashed"
	var stage_keep := FxData.arr(o, "stage_ring_keep")
	var stage_ring_a := FxData.arr(o, "stage_ring_alpha")
	var stage_out := FxData.arr(o, "stage_outline_keep")
	var ring_keep := float(stage_keep[mini(stage, stage_keep.size() - 1)])
	var ring_alpha := float(stage_ring_a[mini(stage, stage_ring_a.size() - 1)])
	var outline_keep := float(stage_out[mini(stage, stage_out.size() - 1)])
	var brng := Mulberry32.new(seed_v + 7919)   # the outline's breaks: a stream of its own, so every stage draws the same puff
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
	if soft_form:
		# plain translucent smoke: no outline, no rings, no scallops. The lobes are filled as stepped
		# washes (the whole cloud once per step, each step a little smaller), so overlapping steps build
		# density toward the middle and the rim stays thin; the map shows through.
		var steps := maxi(FxData.i(o, "soft_steps"), 1)
		var a_each := 1.0 - pow(1.0 - lit.a, 1.0 / float(steps))
		for j in steps:
			var sc := lerpf(1.0, FxData.f(o, "soft_core"), float(j) / float(maxi(steps - 1, 1)))
			g.begin_path()
			for jj in lobes.size():
				var L: Dictionary = lobes[jj]
				var sh: Array = shapes[jj]
				var pts_s: PackedVector2Array = sh[0]
				var scaled := PackedVector2Array()
				for q in pts_s:
					scaled.push_back(Vector2(L.x + (q.x - L.x) * sc, L.y + (q.y - L.y) * sc))
				_add_poly(g, scaled)
			g.fill_color = Color(lit.r, lit.g, lit.b, a_each)
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
				am.push_back(ring_amp + rng.next() * ring_amp_var)
			var ring: Array = InkSprites.scallop(L.x + light.x * R * 0.1 * q, L.y + light.y * R * 0.1 * q, R * s, nk, ph + q * 0.7, am, wob, ns + q * 31)
			var rp: PackedVector2Array = ring[0]
			var ri: PackedInt32Array = ring[1]
			g.stroke_color = ring_col
			g.line_width = st.line_weight() * st.lw("tree_inner_rings")
			g.global_alpha = ring_alpha
			g.begin_path()
			if dashed:
				_dashed(g, rp, FxData.f(o, "dash_px"), FxData.f(o, "gap_px"), rng, ring_keep)
			else:
				var seg := -1
				var draw := false
				for jj in rp.size():
					if ri[jj] != seg:
						seg = ri[jj]
						draw = rng.next() < ring_keep
						if draw:
							g.move_to(rp[jj].x, rp[jj].y)
						continue
					if draw:
						g.line_to(rp[jj].x, rp[jj].y)
			g.stroke()
			g.global_alpha = 1.0
		if not outer_only:
			_outline(g, pts, ink, weight, outline_keep, brng)
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
		_outline(g, outer, ink, weight, outline_keep, brng)

# A closed outline, whole (keep 1) or broken: drawn in runs of a few points, each kept by its own
# draw of `brng`, so an older puff's outline has gaps where a fresh one has none.
static func _outline(g: InkCanvas, pts: PackedVector2Array, ink: Color, weight: float, keep: float, brng: Mulberry32) -> void:
	g.stroke_color = ink
	g.line_width = weight
	if keep >= 0.999:
		InkSprites.trace_path(g, pts)
		g.stroke()
		return
	var n := pts.size()
	var run := 10
	g.begin_path()
	var k := 0
	while k < n:
		var keep_it := brng.next() < keep
		var last := mini(k + run, n)
		if keep_it:
			g.move_to(pts[k].x, pts[k].y)
			for j in range(k + 1, last + 1):
				g.line_to(pts[j % n].x, pts[j % n].y)
		k += run
	g.stroke()

# A polyline as dashes: `dash` px of line, `gap` px of nothing; each dash kept by a draw of rng.
static func _dashed(g: InkCanvas, pts: PackedVector2Array, dash: float, gap: float, rng: Mulberry32, keep: float) -> void:
	var run := 0.0
	var on := true
	var keep_it := rng.next() < keep
	var prev := pts[0]
	if keep_it:
		g.move_to(prev.x, prev.y)
	for i in range(1, pts.size()):
		var p := pts[i]
		var seg := prev.distance_to(p)
		if seg < 1e-6:
			continue
		var pos := 0.0
		while pos < seg:
			var limit := (dash if on else gap) - run
			var step := minf(limit, seg - pos)
			var q := prev.lerp(p, (pos + step) / seg)
			if on and keep_it:
				g.line_to(q.x, q.y)
			pos += step
			run += step
			if run >= (dash if on else gap) - 1e-9:
				run = 0.0
				on = not on
				if on:
					keep_it = rng.next() < keep
					if keep_it:
						g.move_to(q.x, q.y)
		prev = p

# The open-contour form: a few arcs that never close, like isobars or a hand-drawn swirl, over an
# optional faint wash. No scalloped outline, no florets.
static func _draw_arcs(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, rng: Mulberry32, r_px: float, at: Vector2, _seed_v: int, stage: int) -> void:
	var core: Color = st.color(str(FxData.arr(o, "lit_roles")[tone]))
	var patch := _patch(st, o, rng, r_px, at)
	if core.a > 0.0:
		InkSprites.trace_path(g, patch)
		g.fill_color = core
		g.fill()
	var n := FxData.i(o, "arcs_min") + int(rng.next() * float(FxData.i(o, "arcs_max") - FxData.i(o, "arcs_min") + 1))
	var sweep_r := FxData.arr(o, "arc_sweep_deg")
	var spiral := FxData.f(o, "arc_spiral")
	var ring_col: Color = st.color(FxData.s(o, "ring_role"))
	var stage_keep := FxData.arr(o, "stage_ring_keep")
	var stage_a := FxData.arr(o, "stage_ring_alpha")
	var keep := float(stage_keep[mini(stage, stage_keep.size() - 1)])
	var alpha := float(stage_a[mini(stage, stage_a.size() - 1)])
	var dashed := FxData.s(o, "ring_style") == "dashed"
	var wob := st.wobble()
	g.stroke_color = ring_col
	g.line_width = st.line_weight() * st.lw("tree_inner_rings") * FxData.f(o, "arc_weight")
	g.global_alpha = alpha
	for k in n:
		var rk := r_px * (0.38 + 0.62 * (float(k) + rng.next() * 0.6) / float(n))
		var c := at + Vector2(rng.next() - 0.5, rng.next() - 0.5) * r_px * FxData.f(o, "arc_jitter")
		var a0 := rng.next() * TAU
		var sweep := deg_to_rad(lerpf(float(sweep_r[0]), float(sweep_r[1]), rng.next()))
		var steps := maxi(8, int(sweep / deg_to_rad(6.0)))
		var kept := rng.next() < keep   # the same draw at every stage: an arc that goes stays gone
		var pts := PackedVector2Array()
		var ph := rng.next() * 10.0
		for j in steps + 1:
			var f := float(j) / float(steps)
			var a := a0 + sweep * f
			var rr := rk * (1.0 + spiral * (f - 0.5)) * (1.0 + wob * 0.03 * sin(ph + a * 3.0))
			pts.push_back(Vector2(c.x + cos(a) * rr, c.y + sin(a) * rr))
		if not kept:
			continue
		g.begin_path()
		if dashed:
			_dashed(g, pts, FxData.f(o, "dash_px"), FxData.f(o, "gap_px"), rng, 1.0)
		else:
			for j in pts.size():
				if j == 0:
					g.move_to(pts[j].x, pts[j].y)
				else:
					g.line_to(pts[j].x, pts[j].y)
		g.stroke()
	g.global_alpha = 1.0

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
