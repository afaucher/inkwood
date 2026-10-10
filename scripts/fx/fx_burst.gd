extends RefCounted

# The flash, the burst and what stays, drawn through the drawing layer
# (InkCanvas). FOUR FORMS, one per crash option (data/fx/fx.json crash.options):
#
#   stipple    the art plan's proposed treatment: a fire disc with a cream core, an
#              ink scallop outline, short radial hatch strokes, and ink stipple
#              flung outward that settles and thins very slowly
#   lobed      a fireball built like a smoke puff: lobes that start in the fire
#              accent, cool through pale fire to the smoke's cream and cling on as
#              the first puffs of the plume
#   starburst  a ruled spiky star in the fire accent, a hollow inked star after it,
#              a dashed shock ring and long radial hatch rays (a woodcut blast)
#   ring       the restrained one: a small flash, one thin ink ring, a few dots
#
# FAST FLASHES WITH A VERY SLOW DECAY (Alex): every form is at full strength in
# its first ~0.12 s, the fire is gone in under a second, and what is left (ink
# dots, hatch, ring) thins over many seconds; the smoke and the mark that stay
# are the plume's (fx_field.gd) and the scar's.
#
# A burst is a FLIPBOOK: a few frames (data: frames_s) drawn once per (option,
# scale, plane size) and shown by age, hard cut to hard cut, like stop-motion on
# paper. The same draw function makes every frame from the same seed, so the dots
# and rays of one frame are the same dots and rays in the next.
#
# Also here: the flame that rides on an out-of-control plane, its embers, the
# debris shards of a mid-air explosion, and the scar (burnt ground: dirt stipple
# and ink hatch, no fill -- the art plan's terrain.burnt).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")

class BurstSet:
	var frames: Array = []        # [{t: float, tex: Texture2D}] in time order
	var origin := Vector2.ZERO    # the burst's centre in every frame's texture
	var end_s: float = 0.0        # the flipbook is shown until this age
	var radius_px: float = 0.0
	var ppm: float = 1.0

class PartsSet:
	var flame: Array = []         # Texture2D, tail flame, nose-up, origin below
	var flame_origin := Vector2.ZERO
	var ember: Texture2D = null
	var ember_origin := Vector2.ZERO
	var shards: Array = []        # Texture2D
	var shard_masks: Array = []   # Texture2D, white, for the shard's shadow
	var shard_origin: Array = []  # Vector2
	var scars: Array = []         # Texture2D
	var scar_origin := Vector2.ZERO
	var scar_radius_px: float = 0.0
	var ppm: float = 1.0

# --- Curves ---------------------------------------------------------------------------------------

# Piecewise-linear [[x, y], ...] (x ascending), held flat past the ends.
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

# The flipbook frame shown at `age` seconds: its index, or -1 before the flash and after the end.
static func frame_index(frames_s: Array, end_s: float, age: float) -> int:
	if age < 0.0 or age >= end_s or frames_s.is_empty():
		return -1
	var k := 0
	for j in frames_s.size():
		if age >= float(frames_s[j]):
			k = j
	return k

# --- Baking ----------------------------------------------------------------------------------------

# The burst of one phase ("midair" or "impact") as a flipbook. `b` is the option's burst
# group; `radius_m` the burst's radius in metres.
static func bake_burst(st: FxStyle, b: Dictionary, radius_m: float, ppm: float, ground: bool, seed_v: int) -> BurstSet:
	if not FxBake.can_bake():
		return null
	var out := BurstSet.new()
	var R := maxf(radius_m * ppm, 4.0)
	var half := int(ceil(R * 1.75 + 6.0))
	var frames_s := FxData.arr(b, "frames_s")
	out.origin = Vector2(half, half)
	out.end_s = FxData.f(b, "end_s")
	out.radius_px = R
	out.ppm = ppm
	var canvases: Array = []
	for t in frames_s:
		var g := InkCanvas.new(Vector2i(half * 2, half * 2))
		g.line_cap = "round"
		draw_burst(g, st, b, float(t), seed_v, R, Vector2(half, half), ground)
		canvases.append(g)
	var imgs := FxBake.render(canvases)
	for k in frames_s.size():
		out.frames.append({"t": float(frames_s[k]), "tex": FxBake.texture(imgs[k], false)})
	return out

static func bake_parts(st: FxStyle, crash: Dictionary, size_m: float, ppm: float, plane_mask: Variant, seed_v: int) -> PartsSet:
	if not FxBake.can_bake():
		return null
	var ps := PartsSet.new()
	ps.ppm = ppm
	var fall := FxData.grp(crash, "falling")
	var fl := FxData.grp(fall, "flame")
	var imp := FxData.grp(crash, "impact")
	var sc := FxData.grp(imp, "scar")
	var mid := FxData.grp(crash, "midair")
	var deb := FxData.grp(mid, "debris")
	var canvases: Array = []
	var kinds: Array = []
	# flame frames, nose up: the flame trails toward +y (aft), its base at the origin
	var L := maxf(FxData.f(fl, "length_frac") * size_m * ppm, 5.0)
	var W := L * FxData.f(fl, "width_frac")
	var fhalf := int(ceil(maxf(L, W) + 5.0))
	ps.flame_origin = Vector2(fhalf, 3.0)
	for k in (FxData.i(fl, "frames") if st.fire_on else 0):
		var g := InkCanvas.new(Vector2i(fhalf * 2, int(ceil(L + 8.0))))
		g.line_cap = "round"
		draw_flame(g, st, fl, FxBake.seed_of("flame", k, seed_v), L, W, Vector2(fhalf, 3.0))
		canvases.append(g)
		kinds.append("flame")
	# the ember
	var er := maxf(FxData.f(fl, "ember_px"), 1.0)
	var ehalf := int(ceil(er + 3.0))
	ps.ember_origin = Vector2(ehalf, ehalf)
	if st.fire_on:
		var ge := InkCanvas.new(Vector2i(ehalf * 2, ehalf * 2))
		draw_ember(ge, st, fl, er, Vector2(ehalf, ehalf))
		canvases.append(ge)
		kinds.append("ember")
	# debris shards
	for k in FxData.i(deb, "shard_variants"):
		var sp := maxf(FxData.f(deb, "shard_frac") * size_m * ppm, 2.5)
		var shalf := int(ceil(sp * 1.2 + 3.0))
		var g := InkCanvas.new(Vector2i(shalf * 2, shalf * 2))
		g.line_cap = "round"
		draw_shard(g, st, deb, FxBake.seed_of("shard", k, seed_v), sp, Vector2(shalf, shalf))
		canvases.append(g)
		kinds.append("shard")
		ps.shard_origin.append(Vector2(shalf, shalf))
		var gm := InkCanvas.new(Vector2i(shalf * 2, shalf * 2))
		draw_shard(gm, st, deb, FxBake.seed_of("shard", k, seed_v), sp, Vector2(shalf, shalf), true)
		canvases.append(gm)
		kinds.append("shard_mask")
	# scars
	var Rs := maxf(FxData.f(sc, "radius_frac") * size_m * ppm, 5.0)
	var shalf2 := int(ceil(Rs * 1.5 + 4.0))
	ps.scar_origin = Vector2(shalf2, shalf2)
	ps.scar_radius_px = Rs
	for k in FxData.i(sc, "variants"):
		var g := InkCanvas.new(Vector2i(shalf2 * 2, shalf2 * 2))
		g.line_cap = "round"
		draw_scar(g, st, sc, FxBake.seed_of("scar", k, seed_v), Rs, Vector2(shalf2, shalf2), size_m * ppm)
		canvases.append(g)
		kinds.append("scar")
	var imgs := FxBake.render(canvases)
	for k in kinds.size():
		var tex := FxBake.texture(imgs[k], false)
		match kinds[k]:
			"flame":
				ps.flame.append(tex)
			"ember":
				ps.ember = tex
			"shard":
				ps.shards.append(tex)
			"shard_mask":
				ps.shard_masks.append(FxBake.texture(imgs[k], true))
			"scar":
				ps.scars.append(tex)
	return ps

# --- The burst, form by form --------------------------------------------------------------------------------

static func draw_burst(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, seed_v: int, R: float, at: Vector2, ground: bool) -> void:
	var rng := Mulberry32.new(seed_v)
	match FxData.s(b, "form"):
		"stipple":
			_stipple_burst(g, st, b, u, rng, R, at, ground)
		"lobed":
			_lobed_burst(g, st, b, u, rng, R, at, ground)
		"starburst":
			_star_burst(g, st, b, u, rng, R, at, ground)
		"ring":
			_ring_burst(g, st, b, u, rng, R, at, ground)
		_:
			push_error("FxBurst: unknown form '%s'" % FxData.s(b, "form"))

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

# The fire disc, cream core and ink outline, shared by the stipple and ring forms.
static func _fire_disc(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2) -> void:
	if not st.fire_on:
		return   # no fire: Alex 2026-10-10
	var rf := R * curve(FxData.arr(b, "fire_curve"), u)
	var rc := R * curve(FxData.arr(b, "core_curve"), u)
	var disc := _blob(st, rng, at.x, at.y, rf, 9)
	var core := _blob(st, rng, at.x, at.y, rc, 7)
	if rf >= 1.0:
		var pale := u > FxData.f(b, "flash_s") * 2.0
		InkSprites.trace_path(g, disc)
		g.fill_color = st.color(FxData.s(b, "pale_role") if pale else FxData.s(b, "fire_role"))
		g.fill()
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("tree_outline") * FxData.f(b, "outline_scale")
		g.stroke()
	if rc >= 1.0:
		InkSprites.trace_path(g, core)
		g.fill_color = st.color(FxData.s(b, "core_role"))
		g.fill()

static func _stipple_burst(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2, ground: bool) -> void:
	var n := FxData.i(b, "dots")
	var spread := FxData.f(b, "spread")
	var dot_s := FxData.f(b, "dot_s")
	var keep := curve(FxData.arr(b, "dot_keep"), u)
	var hatch_alpha := curve(FxData.arr(b, "hatch_alpha"), u)
	var hatch_reach := ease_out(u / FxData.f(b, "hatch_s"))
	# short radial hatch strokes, first so the fire sits over them
	var nh := FxData.i(b, "hatch")
	var hl := FxData.arr(b, "hatch_len")
	g.stroke_color = st.color(FxData.s(b, "hatch_role"))
	g.line_width = st.line_weight() * st.lw("cusp_ticks") * FxData.f(b, "hatch_weight")
	g.begin_path()
	for j in nh:
		var a := (float(j) + rng.next() * 0.8) / float(nh) * TAU
		var r0 := R * lerpf(float(hl[0]), float(hl[1]), rng.next()) * 0.78
		var r1 := R * lerpf(float(hl[0]), float(hl[1]), rng.next()) * (1.0 + 0.25 * rng.next())
		if hatch_alpha <= 0.01 or hatch_reach <= 0.01:
			continue
		var rb := lerpf(r0, r1, hatch_reach)
		if rb - r0 > 0.5:
			g.move_to(at.x + cos(a) * r0, at.y + sin(a) * r0)
			g.line_to(at.x + cos(a) * rb, at.y + sin(a) * rb)
	if hatch_alpha > 0.01:
		g.global_alpha = hatch_alpha
		g.stroke()
		g.global_alpha = 1.0
	# the stipple flung out
	var pts := PackedVector2Array()
	var soft := PackedVector2Array()
	var spd := ease_out(u / dot_s)
	for i in n:
		var a := rng.next() * TAU
		var v := 0.3 + rng.next() * 0.7
		var survive := rng.next()
		var heavy := rng.next() < 0.3
		if survive > keep:
			continue
		var d := R * spread * v * spd
		var p := Vector2(at.x + cos(a) * d, at.y + sin(a) * d)
		if heavy:
			soft.push_back(p)
		else:
			pts.push_back(p)
	_dots(g, pts, FxData.f(b, "dot_px"), st.color(FxData.s(b, "dot_role")))
	_dots(g, soft, FxData.f(b, "dot_px") * 1.15, st.color(FxData.s(b, "dot_soft_role")))
	_fire_disc(g, st, b, u, rng, R, at)
	if ground:
		_dust_ring(g, st, b, u, R, at, Mulberry32.new(12345))

# The ground's answer to an impact: a ring of dust dots running outward, then still.
static func _dust_ring(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, R: float, at: Vector2, rng: Mulberry32) -> void:
	if not FxData.b(b, "ground_ring"):
		return
	var reach := ease_out(u / FxData.f(b, "ring_s"))
	var keep := curve(FxData.arr(b, "ring_keep"), u)
	if reach <= 0.02 or keep <= 0.02:
		return
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

static func _lobed_burst(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2, ground: bool) -> void:
	# a fireball is a puff whose lobes are fire coloured: the generator is the smoke's
	var pb := FxData.grp(b, "puff")
	if not st.fire_on:
		# no fire: the ball is the smoke's own tones, thick from the first frame
		pb = pb.duplicate()
		pb["lit_roles"] = FxData.arr(pb, "lit_roles_nofire")
		pb["shade_roles"] = FxData.arr(pb, "shade_roles_nofire")
	var edges := FxData.arr(b, "stage_edges_s")
	var stage := 0
	for k in edges.size():
		if u >= float(edges[k]):
			stage = k + 1
	var grow := curve(FxData.arr(b, "grow_curve"), u)
	var seed_v := int(rng.next() * 2147483647.0)
	if grow > 0.02:
		FxPuff.draw_puff(g, st, pb, stage, seed_v, R * grow, at)
	# embers thrown off while it is hot
	var keep := curve(FxData.arr(b, "ember_keep"), u)
	var pts := PackedVector2Array()
	for i in FxData.i(b, "embers"):
		var a := rng.next() * TAU
		var d := R * (1.0 + rng.next() * 0.55) * ease_out(u / 0.3) * grow
		if rng.next() < keep:
			pts.push_back(Vector2(at.x + cos(a) * d, at.y + sin(a) * d))
	if st.fire_on:
		_dots(g, pts, FxData.f(b, "ember_px"), st.color(FxData.s(b, "fire_role")))
	if ground:
		_dust_ring(g, st, b, u, R, at, Mulberry32.new(54321))

static func _star_burst(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2, ground: bool) -> void:
	var spikes := FxData.i(b, "spikes")
	var inner := FxData.f(b, "inner_frac")
	var vr := FxData.f(b, "outer_var")
	var scale := curve(FxData.arr(b, "star_curve"), u)
	var fire := curve(FxData.arr(b, "fire_curve"), u)
	# the star's points, same every frame
	var star := PackedVector2Array()
	var star2 := PackedVector2Array()
	for k in spikes * 2:
		var a := float(k) / float(spikes * 2) * TAU + (rng.next() - 0.5) * 0.12
		var outer := k % 2 == 0
		var rr := R * (1.0 + (rng.next() - 0.5) * vr) if outer else R * inner * (1.0 + (rng.next() - 0.5) * 0.2)
		star.push_back(Vector2(at.x + cos(a) * rr * scale, at.y + sin(a) * rr * scale))
		star2.push_back(Vector2(at.x + cos(a) * rr * scale * 0.55, at.y + sin(a) * rr * scale * 0.55))
	# long radial rays
	var rays := FxData.i(b, "rays")
	var ray_keep := curve(FxData.arr(b, "ray_alpha"), u)
	var ray_reach := ease_out(u / FxData.f(b, "ray_s"))
	g.stroke_color = st.color(FxData.s(b, "hatch_role"))
	g.line_width = st.line_weight() * st.lw("cusp_ticks") * FxData.f(b, "hatch_weight")
	g.begin_path()
	for j in rays:
		var a := (float(j) + rng.next() * 0.7) / float(rays) * TAU
		var r0 := R * (1.0 + 0.1 * rng.next())
		var r1 := R * (1.45 + 0.5 * rng.next()) * (0.4 + 0.6 * ray_reach)
		g.move_to(at.x + cos(a) * r0 * (0.8 + 0.2 * ray_reach), at.y + sin(a) * r0 * (0.8 + 0.2 * ray_reach))
		g.line_to(at.x + cos(a) * r1, at.y + sin(a) * r1)
	if ray_keep > 0.01 and ray_reach > 0.02:
		g.global_alpha = ray_keep
		g.stroke()
		g.global_alpha = 1.0
	# the shock ring, dashed, running out
	var rr0 := ease_out(u / FxData.f(b, "ring_s"))
	var ring_keep := curve(FxData.arr(b, "ring_keep"), u)
	if rr0 > 0.02 and ring_keep > 0.01:
		var r := R * lerpf(0.6, FxData.f(b, "ring_r"), rr0)
		g.stroke_color = st.color(FxData.s(b, "hatch_role"))
		g.line_width = st.line_weight() * st.lw("tree_inner_rings")
		g.global_alpha = ring_keep
		g.begin_path()
		var segs := 28
		for k in segs:
			if k % 3 == 2:
				continue
			var a0 := float(k) / float(segs) * TAU
			var a1 := float(k + 1) / float(segs) * TAU
			g.move_to(at.x + cos(a0) * r, at.y + sin(a0) * r)
			for q in range(1, 4):
				var a := lerpf(a0, a1, float(q) / 3.0)
				g.line_to(at.x + cos(a) * r, at.y + sin(a) * r)
		g.stroke()
		g.global_alpha = 1.0
	# the star: fire filled, then pale, then hollow ink
	if scale > 0.02:
		InkSprites.trace_path(g, star)
		if not st.fire_on:
			pass   # no fire: the star is its ink outline only
		elif fire > 0.5:
			g.fill_color = st.color(FxData.s(b, "fire_role"))
			g.fill()
		elif fire > 0.01:
			g.fill_color = st.color(FxData.s(b, "pale_role"))
			g.fill()
		var outline_a := curve(FxData.arr(b, "outline_alpha"), u)
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("tree_outline") * FxData.f(b, "outline_scale")
		g.global_alpha = outline_a
		g.stroke()
		g.global_alpha = 1.0
		var core := curve(FxData.arr(b, "core_curve"), u)
		if st.fire_on and core > 0.5:
			InkSprites.trace_path(g, star2)
			g.fill_color = st.color(FxData.s(b, "core_role"))
			g.fill()
	# debris dots
	var keep := curve(FxData.arr(b, "dot_keep"), u)
	var pts := PackedVector2Array()
	var spd := ease_out(u / FxData.f(b, "dot_s"))
	for i in FxData.i(b, "dots"):
		var a := rng.next() * TAU
		var v := 0.5 + rng.next() * 0.9
		if rng.next() < keep:
			pts.push_back(Vector2(at.x + cos(a) * R * v * 1.3 * spd, at.y + sin(a) * R * v * 1.3 * spd))
	_dots(g, pts, FxData.f(b, "dot_px"), st.color(FxData.s(b, "dot_role")))
	if ground:
		_dust_ring(g, st, b, u, R, at, Mulberry32.new(98765))

static func _ring_burst(g: InkCanvas, st: FxStyle, b: Dictionary, u: float, rng: Mulberry32, R: float, at: Vector2, ground: bool) -> void:
	var reach := ease_out(u / FxData.f(b, "ring_s"))
	var keep := curve(FxData.arr(b, "ring_keep"), u)
	if reach > 0.02 and keep > 0.01:
		var pts := _blob(st, rng, at.x, at.y, R * lerpf(0.35, FxData.f(b, "ring_r"), reach), 11)
		InkSprites.trace_path(g, pts)
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("tree_inner_rings")
		g.global_alpha = keep
		g.stroke()
		g.global_alpha = 1.0
	var kd := curve(FxData.arr(b, "dot_keep"), u)
	var spd := ease_out(u / FxData.f(b, "dot_s"))
	var d := PackedVector2Array()
	for i in FxData.i(b, "dots"):
		var a := rng.next() * TAU
		var v := 0.3 + rng.next() * 0.7
		if rng.next() < kd:
			d.push_back(Vector2(at.x + cos(a) * R * v * spd, at.y + sin(a) * R * v * spd))
	_dots(g, d, FxData.f(b, "dot_px"), st.color(FxData.s(b, "dot_role")))
	_fire_disc(g, st, b, u, rng, R, at)
	if ground:
		_dust_ring(g, st, b, u, R, at, Mulberry32.new(2468))

# --- Flame, ember, shard --------------------------------------------------------------------------------------------

# A flame tuft trailing toward +y from `at` (nose up: the plane's tail is at +y), two or three lobes
# long, in the fire accent over a cream core, inked.
static func draw_flame(g: InkCanvas, st: FxStyle, fl: Dictionary, seed_v: int, L: float, W: float, at: Vector2) -> void:
	var rng := Mulberry32.new(seed_v)
	var n := 4
	var lobes: Array[Dictionary] = []
	for i in n:
		var t := float(i) / float(n)
		lobes.append({"x": at.x + (rng.next() - 0.5) * W * 0.5, "y": at.y + L * (0.18 + 0.75 * t) , "R": W * 0.5 * (1.0 - 0.7 * t) * (0.85 + rng.next() * 0.3)})
	for k in range(lobes.size() - 1, -1, -1):
		var Lb: Dictionary = lobes[k]
		var pts := _blob(st, rng, Lb.x, Lb.y, Lb.R, 7)
		InkSprites.trace_path(g, pts)
		g.fill_color = st.color(FxData.s(fl, "fire_role"))
		g.fill()
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("cusp_ticks") * 1.2
		g.stroke()
	var core := _blob(st, rng, at.x, at.y + L * 0.2, W * 0.28, 6)
	InkSprites.trace_path(g, core)
	g.fill_color = st.color(FxData.s(fl, "core_role"))
	g.fill()

static func draw_ember(g: InkCanvas, st: FxStyle, fl: Dictionary, r: float, at: Vector2) -> void:
	g.begin_path()
	g.move_to(at.x + r, at.y)
	g.arc(at.x, at.y, r, 0.0, TAU)
	g.fill_color = st.color(FxData.s(fl, "fire_role"))
	g.fill()

# A piece of the plane: a small ink-outlined polygon in the object fill.
static func draw_shard(g: InkCanvas, st: FxStyle, deb: Dictionary, seed_v: int, size: float, at: Vector2, mask: bool = false) -> void:
	var rng := Mulberry32.new(seed_v)
	var n := 4 + int(rng.next() * 2.0)
	var pts := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU + (rng.next() - 0.5) * 0.7
		var r := size * (0.35 + rng.next() * 0.65)
		pts.push_back(Vector2(at.x + cos(a) * r * 1.2, at.y + sin(a) * r * 0.55))
	InkSprites.trace_path(g, pts)
	if mask:
		g.fill_color = Color.WHITE
		g.fill()
		return
	g.fill_color = st.color(FxData.s(deb, "fill_role"))
	g.fill()
	g.stroke_color = st.ink()
	g.line_width = st.line_weight() * st.lw("tree_inner_rings")
	g.stroke()

# --- The scar: burnt ground ----------------------------------------------------------------------------------------------

# Dirt stipple thick in the middle and thinning out, short ink hatch strokes thickest on
# the shadow side, a few scratches; no fill (the art plan's terrain.burnt). `crater` adds a
# broken ink ring round the blot.
static func draw_scar(g: InkCanvas, st: FxStyle, sc: Dictionary, seed_v: int, R: float, at: Vector2, plane_px: float) -> void:
	var rng := Mulberry32.new(seed_v)
	var light := st.detail_light
	var dots := PackedVector2Array()
	var soft := PackedVector2Array()
	var n := roundi(PI * R * R * FxData.f(sc, "dots_per_px2"))
	var skew := Vector2(rng.next() - 0.5, rng.next() - 0.5) * R * 0.25
	var stretch := FxData.f(sc, "stretch")
	# an irregular outline: a few random harmonics round the circle; the blot is long along the
	# plane's heading (the texture's +x), as a crash skids
	var p2 := rng.next() * TAU
	var p3 := rng.next() * TAU
	var p5 := rng.next() * TAU
	for i in n:
		var a := rng.next() * TAU
		var f := clampf(1.0 + 0.2 * sin(2.0 * a + p2) + 0.15 * sin(3.0 * a + p3) + 0.1 * sin(5.0 * a + p5), 0.55, 1.4)
		var d := pow(rng.next(), FxData.f(sc, "core_bias")) * R * f
		var p := Vector2(at.x + cos(a) * d * stretch + skew.x, at.y + sin(a) * d * 0.8 + skew.y)
		if rng.next() < 0.35:
			soft.push_back(p)
		else:
			dots.push_back(p)
	_dots(g, dots, FxData.f(sc, "dot_px"), st.color(FxData.s(sc, "dot_role")))
	_dots(g, soft, FxData.f(sc, "dot_px") * 1.2, st.color(FxData.s(sc, "dot_soft_role")))
	# hatch on the shadow side
	g.stroke_color = st.color(FxData.s(sc, "hatch_role"))
	g.line_width = st.line_weight() * st.lw("cusp_ticks") * FxData.f(sc, "hatch_weight")
	g.begin_path()
	var made := 0
	var tries := 0
	var hn := FxData.i(sc, "hatch")
	while made < hn and tries < hn * 12:
		tries += 1
		var a := rng.next() * TAU
		var d := sqrt(rng.next()) * R * 0.95
		var dx := cos(a)
		var dy := sin(a)
		if dx * light.x + dy * light.y > 0.0 and rng.next() < 0.75:
			continue
		var len := R * (0.12 + rng.next() * 0.2)
		var p := Vector2(at.x + dx * d * stretch + skew.x, at.y + dy * d * 0.8 + skew.y)
		g.move_to(p.x, p.y)
		g.line_to(p.x + len * 0.7071, p.y + len * 0.7071)
		made += 1
	g.stroke()
	if FxData.b(sc, "crater"):
		g.stroke_color = st.color(FxData.s(sc, "hatch_role"))
		g.line_width = st.line_weight() * st.lw("tree_inner_rings")
		g.begin_path()
		var segs := 24
		for k in segs:
			if rng.next() < 0.35:
				continue
			var a0 := float(k) / float(segs) * TAU
			var a1 := float(k + 1) / float(segs) * TAU
			var rr := R * (0.92 + rng.next() * 0.12)
			g.move_to(at.x + cos(a0) * rr + skew.x, at.y + sin(a0) * rr * 0.82 + skew.y)
			g.line_to(at.x + cos(a1) * rr + skew.x, at.y + sin(a1) * rr * 0.82 + skew.y)
		g.stroke()
	g.set_transform(1, 0, 0, 1, 0, 0)
	_draw_wreck(g, st, sc, rng, plane_px, R, at, stretch)

# --- The wreck ---------------------------------------------------------------------------------------------------------------------

# The pieces lying in the scar (the art plan's fx.wreck, drawn generically so it needs no plane
# art): fill in the wall tone, an ink outline with gaps in it (broken), a few hatch strokes on
# the side away from the light, a drop shadow on the burnt ground, burnt metal for the engine.
# Local axes: +x is the plane's heading (the scar is turned to it).
static func _draw_wreck(g: InkCanvas, st: FxStyle, sc: Dictionary, rng: Mulberry32, plane_px: float, R: float, at: Vector2, stretch: float) -> void:
	var pieces := FxData.arr(sc, "wreck_pieces")
	if pieces.is_empty():
		return
	var S := plane_px * 0.5 * FxData.f(sc, "wreck_scale")
	var spread := FxData.f(sc, "wreck_spread")
	var fill: Color = st.color(FxData.s(sc, "wreck_fill_role"))
	var char_c: Color = st.color(FxData.s(sc, "wreck_char_role"))
	var drop: Color = st.color(FxData.s(sc, "wreck_shade_role"))
	var sd := -st.detail_light   # shadows fall away from the light
	for k in pieces.size():
		var kind := str(pieces[k])
		var a := rng.next() * TAU
		var d := 0.0 if k == 0 else (0.3 + rng.next() * 0.7) * R * spread
		var c := Vector2(at.x + cos(a) * d * stretch, at.y + sin(a) * d * 0.8)
		var rot := rng.next() * TAU
		var local := _wreck_poly(kind, S, rng)
		var pts := PackedVector2Array()
		var cs := cos(rot)
		var sn := sin(rot)
		for q in local:
			pts.push_back(Vector2(c.x + q.x * cs - q.y * sn, c.y + q.x * sn + q.y * cs))
		# drop shadow, then the piece
		var shadow_pts := PackedVector2Array()
		for q in pts:
			shadow_pts.push_back(q + sd * maxf(1.2, S * 0.05))
		InkSprites.trace_path(g, shadow_pts)
		g.fill_color = drop
		g.fill()
		InkSprites.trace_path(g, pts)
		g.fill_color = char_c if kind == "engine" else fill
		g.fill()
		# a broken outline: edges dropped at random, so the line has gaps
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("house_outline") * 1.5
		g.begin_path()
		for i in pts.size():
			if rng.next() < 0.22:
				continue
			var p0 := pts[i]
			var p1 := pts[(i + 1) % pts.size()]
			g.move_to(p0.x, p0.y)
			g.line_to(p1.x, p1.y)
		g.stroke()
		# hatch strokes from the rim toward the middle
		if kind != "engine":
			g.stroke_color = st.color("ink.hatch")
			g.line_width = st.line_weight() * st.lw("cusp_ticks")
			g.begin_path()
			for j in 3:
				var p := pts[int(rng.next() * float(pts.size())) % pts.size()]
				var toward := (c - p).normalized()
				g.move_to(p.x + toward.x * S * 0.04, p.y + toward.y * S * 0.04)
				g.line_to(p.x + toward.x * S * 0.14 + 0.5, p.y + toward.y * S * 0.14 + 0.5)
			g.stroke()

# A piece's outline in its own axes (x along its length), in px; S is half the plane's size.
static func _wreck_poly(kind: String, S: float, rng: Mulberry32) -> PackedVector2Array:
	var out := PackedVector2Array()
	match kind:
		"fuselage":
			var L := S * 0.9
			var W := S * 0.19
			var n := 14
			for i in n:
				var a := float(i) / float(n) * TAU
				var rx := L * 0.5 * (1.0 + (rng.next() - 0.5) * 0.14)
				var ry := W * 0.5 * (1.0 + (rng.next() - 0.5) * 0.3) * (1.0 - 0.35 * maxf(0.0, -cos(a)))
				out.push_back(Vector2(cos(a) * rx, sin(a) * ry))
		"wing":
			var span := S * (0.62 + rng.next() * 0.25)
			var root := S * 0.3
			var tip := S * 0.15
			out.push_back(Vector2(-root * 0.5, 0.0))
			out.push_back(Vector2(-tip * 0.5, span * (0.9 + rng.next() * 0.2)))
			out.push_back(Vector2(tip * 0.5, span * (0.75 + rng.next() * 0.25)))
			out.push_back(Vector2(root * 0.5, span * 0.35))
			out.push_back(Vector2(root * 0.5, 0.0))
		"engine":
			var n := 8
			for i in n:
				var a := float(i) / float(n) * TAU
				var r := S * 0.15 * (0.8 + rng.next() * 0.4)
				out.push_back(Vector2(cos(a) * r, sin(a) * r))
		"tail":
			out.push_back(Vector2(-S * 0.1, -S * 0.18))
			out.push_back(Vector2(S * 0.2, 0.0))
			out.push_back(Vector2(-S * 0.1, S * 0.18))
			out.push_back(Vector2(-S * 0.04, 0.0))
		_:
			var n := 6
			for i in n:
				var a := float(i) / float(n) * TAU
				out.push_back(Vector2(cos(a), sin(a)) * S * 0.2)
	return out
