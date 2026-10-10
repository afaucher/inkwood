extends RefCounted

# FLASHES WITHOUT FIRE, and the ragged puff (Track X2, the strike layer, 2026-10-10).
#
# Alex: "No fire for now. Just smoke." and "fast flashes with a very slow decay". The flash of a
# flak shell, a bomb or the radio tower going up is therefore not fire: it is LIGHT, the knock-out
# step of the palette (the lightest value on the map, role burst.core, no new hue) with ink round
# it -- hatch rays, flung dots, a dust ring -- as the stipple burst of the crash board was drawn
# with the fire off. A flash is a FLIPBOOK (a few frames, hard cut to hard cut, baked once per
# scale and size by FxBurst.bake_burst, drawn here); every frame comes from the same seed, so the
# rays and dots of one frame are the same rays and dots in the next.
#
# THREE FORMS (data: fx.json flak / bomb / ruin options, `flash` group, `form`):
#   knockout   a ragged paper-light disc with the pen's shadow-side outline, ink hatch rays and
#              flung dots round it, a dust ring on the ground
#   star       a ruled jagged star, filled knock-out for the first frames and hollow ink after,
#              long rays, a dashed shock ring
#   ringpop    the restrained one: a small knock-out core and one expanding broken ring
# (the crash board's `stipple`, `starburst` and `ring` forms are drawn by FxBurst, and work here too.)
#
# AND the RAGGED PUFF: flak's dark burst, a jagged-edged cloud (spikes, not scallops) in stepped
# ink washes that lighten as it ages, with a few thin ink streamers trailing out of it. It is a
# form of FxPuff (draw_puff / draw_mask dispatch here); the field places and fades it like any smoke.
#
# Colours are roles (FxStyle); sizes are metres x the drawn scale, in px here.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")

const FORMS := ["knockout", "star", "ringpop"]

static func handles(form: String) -> bool:
	return FORMS.has(form)

# --- Curves (the same helpers FxBurst has; here so this file needs nothing of it) ------------------

static func curve(points: Array, x: float) -> float:
	var n := points.size()
	if n == 0:
		return 0.0
	if x <= float(points[0][0]):
		return float(points[0][1])
	for k in range(1, n):
		var x1 := float(points[k][0])
		if x <= x1:
			var x0 := float(points[k - 1][0])
			var t := (x - x0) / maxf(x1 - x0, 1e-9)
			return lerpf(float(points[k - 1][1]), float(points[k][1]), t)
	return float(points[n - 1][1])

static func ease_out(x: float) -> float:
	x = clampf(x, 0.0, 1.0)
	return 1.0 - pow(1.0 - x, 3.0)

# --- Small shapes -------------------------------------------------------------------------------------

static func _blob(st: FxStyle, rng: Mulberry32, cx: float, cy: float, r: float, n: int) -> PackedVector2Array:
	var amps := PackedFloat64Array()
	for _i in n:
		amps.push_back(0.1 + rng.next() * 0.1)
	var out: Array = InkSprites.scallop(cx, cy, maxf(r, 0.5), n, rng.next() * PI, amps, st.wobble(), int(rng.next() * 1e6))
	return out[0]

static func _dots(g: InkCanvas, pts: PackedVector2Array, r: float, col: Color) -> void:
	if pts.is_empty():
		return
	g.fill_color = col
	g.begin_path()
	for p in pts:
		g.move_to(p.x + r, p.y)
		g.arc(p.x, p.y, r, 0.0, TAU)
	g.fill()

# A ring of dust dots running outward over the ground, then still (the crash board's, with its own seed).
static func _dust_ring(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, R: float, at: Vector2, seed_v: int) -> void:
	if not FxData.b(b, "ground_ring"):
		return
	var reach := ease_out(u / FxData.f(b, "ring_s"))
	var keep := curve(FxData.arr(b, "ring_keep"), u)
	if reach <= 0.02 or keep <= 0.02:
		return
	var rng := Mulberry32.new(seed_v)
	var r := R * lerpf(0.5, FxData.f(b, "ring_r"), reach)
	var n := 34
	var pts := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU + (rng.next() - 0.5) * 0.14
		var rr := r * (1.0 + (rng.next() - 0.5) * 0.08)
		if rng.next() > keep:
			continue
		pts.push_back(Vector2(at.x + cos(a) * rr, at.y + sin(a) * rr))
	_dots(g, pts, FxData.f(b, "dot_px") * 0.9, st.color(FxData.s(b, "dot_soft_role")))

# --- The flash, frame by frame ---------------------------------------------------------------------------

# One frame of the flipbook at age `u` seconds. `b` is the option's flash group (a copy with "hit": true
# for a hit); R the flash radius in px; `at` its centre in the canvas.
static func draw(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, seed_v: int, R: float, at: Vector2, ground: bool) -> void:
	var rng := Mulberry32.new(seed_v)
	match FxData.s(b, "form"):
		"knockout":
			_knockout(g, st, b, u, rng, R, at, ground)
		"star":
			_star(g, st, b, u, rng, R, at, ground)
		"ringpop":
			_ringpop(g, st, b, u, rng, R, at, ground)
		_:
			push_error("FxFlash: unknown form '%s'" % FxData.s(b, "form"))

static func _rays(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2) -> void:
	var n := FxData.i(b, "hatch")
	var hl := FxData.arr(b, "hatch_len")
	var alpha := curve(FxData.arr(b, "hatch_alpha"), u)
	var reach := ease_out(u / maxf(FxData.f(b, "hatch_s"), 1e-6))
	var r_in := FxData.f(b, "hatch_in")
	g.stroke_color = st.color(FxData.s(b, "hatch_role"))
	g.line_width = st.line_weight() * st.lw("cusp_ticks") * FxData.f(b, "hatch_weight")
	g.begin_path()
	var any := false
	for j in n:
		var a := (float(j) + rng.next() * 0.8) / float(n) * TAU
		var r1 := R * lerpf(float(hl[0]), float(hl[1]), rng.next())
		var r0 := R * r_in
		var rb := lerpf(r0, r1, reach)
		if alpha > 0.01 and reach > 0.01 and rb - r0 > 0.5:
			g.move_to(at.x + cos(a) * r0, at.y + sin(a) * r0)
			g.line_to(at.x + cos(a) * rb, at.y + sin(a) * rb)
			any = true
	if any:
		g.global_alpha = alpha
		g.stroke()
		g.global_alpha = 1.0

static func _flung(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2) -> void:
	var n := FxData.i(b, "dots")
	var keep := curve(FxData.arr(b, "dot_keep"), u)
	var spd := ease_out(u / maxf(FxData.f(b, "dot_s"), 1e-6))
	var pts := PackedVector2Array()
	var soft := PackedVector2Array()
	for i in n:
		var a := rng.next() * TAU
		var v := 0.3 + rng.next() * 0.7
		var survive := rng.next()
		var heavy := rng.next() < 0.3
		if survive > keep:
			continue
		var d := R * FxData.f(b, "spread") * v * spd
		var p := Vector2(at.x + cos(a) * d, at.y + sin(a) * d)
		if heavy:
			soft.push_back(p)
		else:
			pts.push_back(p)
	_dots(g, pts, FxData.f(b, "dot_px"), st.color(FxData.s(b, "dot_role")))
	_dots(g, soft, FxData.f(b, "dot_px") * 1.15, st.color(FxData.s(b, "dot_soft_role")))

# A hit's fragments: short heavy ink dashes thrown out of the flash.
static func _fragments(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2) -> void:
	var n := FxData.i(b, "frag")
	var hit := bool(b.get("hit", false))
	var keep := curve(FxData.arr(b, "frag_keep"), u)
	var reach := ease_out(u / maxf(FxData.f(b, "frag_s"), 1e-6))
	g.stroke_color = st.ink()
	g.line_width = st.line_weight() * st.lw("cusp_ticks") * FxData.f(b, "frag_weight")
	g.begin_path()
	var any := false
	for j in n:
		var a := rng.next() * TAU
		var d0 := R * (0.5 + rng.next() * 0.4)
		var d1 := R * (1.05 + rng.next() * 0.9)
		var ln := R * (0.12 + rng.next() * 0.14)
		var survive := rng.next()
		if not hit or survive > keep or reach < 0.02:
			continue
		var d := lerpf(d0, d1, reach)
		g.move_to(at.x + cos(a) * d, at.y + sin(a) * d)
		g.line_to(at.x + cos(a) * (d + ln), at.y + sin(a) * (d + ln))
		any = true
	if any:
		g.stroke()

static func _knockout(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2, ground: bool) -> void:
	var rc := R * curve(FxData.arr(b, "core_curve"), u)
	# every random draw is made in a fixed order, whatever the frame, so the rays and dots do not jump
	var disc := _blob(st, rng, at.x, at.y, maxf(rc, 1.0), 9)
	_rays(g, st, b, u, rng, R, at)
	_flung(g, st, b, u, rng, R, at)
	_fragments(g, st, b, u, rng, R, at)
	if ground:
		_dust_ring(g, st, b, u, R, at, 12345)
	if rc >= 1.0:
		InkSprites.trace_path(g, disc)
		g.fill_color = st.color(FxData.s(b, "core_role"))
		g.fill()
		var oa := curve(FxData.arr(b, "outline_alpha"), u)
		if oa > 0.02:
			g.stroke_color = st.ink()
			g.line_width = st.line_weight() * st.lw("tree_outline") * FxData.f(b, "outline_scale")
			g.global_alpha = oa
			g.stroke()
			g.global_alpha = 1.0

static func _star(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2, ground: bool) -> void:
	var spikes := FxData.i(b, "spikes")
	var inner := FxData.f(b, "inner_frac")
	var vr := FxData.f(b, "outer_var")
	var scale := curve(FxData.arr(b, "star_curve"), u)
	var star := PackedVector2Array()
	for k in spikes * 2:
		var a := float(k) / float(spikes * 2) * TAU + (rng.next() - 0.5) * 0.12
		var outer := k % 2 == 0
		var rr := R * (1.0 + (rng.next() - 0.5) * vr) if outer else R * inner * (1.0 + (rng.next() - 0.5) * 0.2)
		star.push_back(Vector2(at.x + cos(a) * rr * scale, at.y + sin(a) * rr * scale))
	_rays(g, st, b, u, rng, R, at)
	_flung(g, st, b, u, rng, R, at)
	_fragments(g, st, b, u, rng, R, at)
	if ground:
		_dust_ring(g, st, b, u, R, at, 98765)
	if scale > 0.02:
		InkSprites.trace_path(g, star)
		if u < FxData.f(b, "fill_s"):
			g.fill_color = st.color(FxData.s(b, "core_role"))
			g.fill()
		var oa := curve(FxData.arr(b, "outline_alpha"), u)
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("tree_outline") * FxData.f(b, "outline_scale")
		g.global_alpha = oa
		g.stroke()
		g.global_alpha = 1.0

static func _ringpop(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2, ground: bool) -> void:
	var rc := R * curve(FxData.arr(b, "core_curve"), u)
	var disc := _blob(st, rng, at.x, at.y, maxf(rc, 1.0), 8)
	var reach := ease_out(u / maxf(FxData.f(b, "ring_s"), 1e-6))
	var keep := curve(FxData.arr(b, "ring_keep"), u)
	var ring_pts := _blob(st, rng, at.x, at.y, R * lerpf(0.4, FxData.f(b, "ring_r"), reach), 11)
	_flung(g, st, b, u, rng, R, at)
	_fragments(g, st, b, u, rng, R, at)
	if ground:
		_dust_ring(g, st, b, u, R, at, 2468)
	if reach > 0.02 and keep > 0.01:
		# the ring is drawn broken: every third run of points lifted
		g.stroke_color = st.color(FxData.s(b, "ring_role"))
		g.line_width = st.line_weight() * st.lw("tree_inner_rings") * FxData.f(b, "ring_weight")
		g.global_alpha = keep
		g.begin_path()
		var n := ring_pts.size()
		var run := 7
		var k := 0
		while k < n:
			if (k / run) % 3 != 2:
				g.move_to(ring_pts[k].x, ring_pts[k].y)
				for j in range(k + 1, mini(k + run, n - 1) + 1):
					g.line_to(ring_pts[j].x, ring_pts[j].y)
			k += run
		g.stroke()
		g.global_alpha = 1.0
	if rc >= 1.0:
		InkSprites.trace_path(g, disc)
		g.fill_color = st.color(FxData.s(b, "core_role"))
		g.fill()

# --- The ragged puff -------------------------------------------------------------------------------------------

# A jagged polygon about (cx, cy): n points out and n points in, the inner ones `depth` of the way down.
static func _jag(rng: Mulberry32, cx: float, cy: float, R: float, n: int, depth: float, var_out: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var a0 := rng.next() * TAU
	for k in n * 2:
		var a := a0 + float(k) / float(n * 2) * TAU + (rng.next() - 0.5) * (TAU / float(n * 2)) * 0.7
		var rr: float
		if k % 2 == 0:
			rr = R * (1.0 - var_out * rng.next())
		else:
			rr = R * (1.0 - depth * (0.45 + 0.55 * rng.next()))
		pts.push_back(Vector2(cx + cos(a) * rr, cy + sin(a) * rr))
	return pts

# One ragged puff centred at `at`, of extent r_px: a few overlapping jagged clouds filled in stepped ink washes
# (the whole cloud once per step, each a little smaller, so overlaps build density to the middle and the rim stays
# thin), then streamers: thin ink lines trailing out of it. `stage` is the age (fresh, middle, old): the wash
# lightens through the roles, the streamers thin out. `mask_only` draws the white silhouette for the shadow.
static func draw_ragged(g: InkCanvas, st: FxStyle, o: Dictionary, tone: int, rng: Mulberry32, r_px: float, at: Vector2, mask_only: bool, stage: int) -> void:
	var n_lobes := FxData.i(o, "lobes_min") + int(rng.next() * float(FxData.i(o, "lobes_max") - FxData.i(o, "lobes_min") + 1))
	var a0 := rng.next() * TAU
	var lobes: Array[Dictionary] = []
	for i in n_lobes:
		var a := a0 + float(i) / float(n_lobes) * TAU + (rng.next() - 0.5) * 0.5
		var d := r_px * (FxData.f(o, "lobe_d") + rng.next() * FxData.f(o, "lobe_d_var"))
		lobes.append({"x": at.x + cos(a) * d, "y": at.y + sin(a) * d, "R": r_px * (FxData.f(o, "lobe_r") + rng.next() * FxData.f(o, "lobe_r_var"))})
	lobes.append({"x": at.x + (rng.next() - 0.5) * r_px * 0.12, "y": at.y + (rng.next() - 0.5) * r_px * 0.12, "R": r_px * FxData.f(o, "crown_r")})
	var shapes: Array = []
	for L in lobes:
		var n := FxData.i(o, "spikes_min") + int(rng.next() * float(FxData.i(o, "spikes_max") - FxData.i(o, "spikes_min") + 1))
		shapes.append(_jag(rng, L.x, L.y, L.R, n, FxData.f(o, "spike_depth"), FxData.f(o, "spike_var")))
	# the streamers' draws come before any colour is chosen, so every stage and the mask see the same streamers
	var n_str := FxData.i(o, "streamers")
	var streams: Array = []
	for k in n_str:
		var a := rng.next() * TAU
		var r0 := r_px * (0.7 + rng.next() * 0.25)
		var r1 := r0 + r_px * lerpf(FxData.arr(o, "streamer_len")[0], FxData.arr(o, "streamer_len")[1], rng.next())
		var bend := (rng.next() - 0.5) * 0.5
		var life := rng.next()
		streams.append([a, r0, r1, bend, life])
	if mask_only:
		g.fill_color = Color.WHITE
		g.begin_path()
		for sh in shapes:
			_add_poly(g, sh)
		g.fill()
		return
	var roles := FxData.arr(o, "lit_roles")
	var role_i := stage * 3 + tone
	var lit: Color = st.color(str(roles[mini(role_i, roles.size() - 1)]))
	var steps := maxi(FxData.i(o, "soft_steps"), 1)
	var a_each := 1.0 - pow(1.0 - lit.a, 1.0 / float(steps))
	for j in steps:
		var sc := lerpf(1.0, FxData.f(o, "soft_core"), float(j) / float(maxi(steps - 1, 1)))
		g.begin_path()
		for jj in lobes.size():
			var L: Dictionary = lobes[jj]
			var pts: PackedVector2Array = shapes[jj]
			var scaled := PackedVector2Array()
			for q in pts:
				scaled.push_back(Vector2(L.x + (q.x - L.x) * sc, L.y + (q.y - L.y) * sc))
			_add_poly(g, scaled)
		g.fill_color = Color(lit.r, lit.g, lit.b, a_each)
		g.fill()
	# streamers: thin ink, kept fewer as the puff ages
	var keep_by_stage := FxData.arr(o, "stage_streamer_keep")
	var keep := float(keep_by_stage[mini(stage, keep_by_stage.size() - 1)])
	var sc_col: Color = st.color(FxData.s(o, "streamer_role"))
	g.stroke_color = sc_col
	g.line_width = st.line_weight() * st.lw("cusp_ticks") * FxData.f(o, "streamer_weight")
	g.begin_path()
	var drawn := false
	for s in streams:
		if float(s[4]) > keep:
			continue
		var a: float = s[0]
		var r0: float = s[1]
		var r1: float = s[2]
		var bend: float = s[3]
		var p0 := Vector2(at.x + cos(a) * r0, at.y + sin(a) * r0)
		var pm := Vector2(at.x + cos(a + bend * 0.5) * (r0 + r1) * 0.5, at.y + sin(a + bend * 0.5) * (r0 + r1) * 0.5)
		var p1 := Vector2(at.x + cos(a + bend) * r1, at.y + sin(a + bend) * r1)
		g.move_to(p0.x, p0.y)
		g.line_to(pm.x, pm.y)
		g.line_to(p1.x, p1.y)
		drawn = true
	if drawn:
		g.stroke()

static func _add_poly(g: InkCanvas, pts: PackedVector2Array) -> void:
	for i in pts.size():
		if i == 0:
			g.move_to(pts[i].x, pts[i].y)
		else:
			g.line_to(pts[i].x, pts[i].y)
	g.close_path()
