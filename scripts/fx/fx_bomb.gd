extends RefCounted

# THE MARKS OF A BOMB (Track X2, the strike layer, 2026-10-10): the crater that stays, the clods
# thrown up, and the bomb itself falling. Everything is drawn through the drawing layer (InkCanvas)
# so the pen, the supersampling and the premultiplied alpha match the map; colours are roles
# (FxStyle); sizes are metres x the drawn scale. No fire (Alex 2026-10-10: "No fire for now. Just
# smoke."): the flash is the knock-out step of the palette (fx_flash.gd), the crater is DIRT and INK.
#
# THE CRATER (the art plan's terrain.burnt with a pit): an irregular pit wash in the ink at a low alpha,
# dirt stipple thick in the middle and thinning out, short ink hatch on the inner wall that faces the
# light (the far wall is in shade), an ink ring on the lip, a few flecks of earth thrown out.
# Three forms (data: fx.json bomb options, `crater` group):
#   ringed   all of that, with the ring
#   blot     stipple and hatch only, no ring (the scar's language: a burnt blot)
#   rimmed   a pale lip of thrown earth round the ring (the lightest step of the fills), the pit dark
# Whatever the form, the same seed draws the same crater at every scale.
#
# THE CLOD: a small flat polygon of earth with a thin ink outline (and a white mask for its ground
# shadow); the bomb: a dark teardrop with fins, drawn pointing +x and turned by the layer.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")

class BombSet:
	var craters: Array = []          # Texture2D, the mark that stays
	var crater_origin := Vector2.ZERO
	var crater_radius_px: float = 0.0
	var clods: Array = []            # Texture2D, a piece of earth in flight or lying
	var clod_masks: Array = []       # Texture2D, white, for its shadow
	var clod_origin: Array = []      # Vector2
	var bomb: Texture2D = null       # the falling bomb, pointing +x
	var bomb_mask: Texture2D = null
	var bomb_origin := Vector2.ZERO
	var ppm: float = 1.0
	var blast_m: float = 0.0

# --- Baking -----------------------------------------------------------------------------------------------------------

# Every sprite a bomb option needs at one scale, for a blast of `blast_m` metres. `crater` is the option's crater
# group, `deb` its debris group, `fall` its falling-bomb group.
static func bake_set(st: FxStyle, crater: Dictionary, deb: Dictionary, fall: Dictionary, blast_m: float, ppm: float, seed_v: int) -> BombSet:
	if not FxBake.can_bake():
		return null
	var bs := BombSet.new()
	bs.ppm = ppm
	bs.blast_m = blast_m
	var canvases: Array = []
	var kinds: Array = []
	var Rc := maxf(FxData.f(crater, "radius_frac") * blast_m * ppm, 5.0)
	var half := int(ceil(Rc * 1.9 + 4.0))
	bs.crater_origin = Vector2(half, half)
	bs.crater_radius_px = Rc
	for k in FxData.i(crater, "variants"):
		var g := InkCanvas.new(Vector2i(half * 2, half * 2))
		g.line_cap = "round"
		draw_crater(g, st, crater, FxBake.seed_of("crater", k, seed_v), Rc, Vector2(half, half))
		canvases.append(g)
		kinds.append("crater")
	for k in FxData.i(deb, "clod_variants"):
		var sp := maxf(FxData.f(deb, "clod_frac") * blast_m * ppm, 1.8)
		var shalf := int(ceil(sp * 1.2 + 3.0))
		var g := InkCanvas.new(Vector2i(shalf * 2, shalf * 2))
		g.line_cap = "round"
		draw_clod(g, st, deb, FxBake.seed_of("clod", k, seed_v), sp, Vector2(shalf, shalf), false)
		canvases.append(g)
		kinds.append("clod")
		bs.clod_origin.append(Vector2(shalf, shalf))
		var gm := InkCanvas.new(Vector2i(shalf * 2, shalf * 2))
		draw_clod(gm, st, deb, FxBake.seed_of("clod", k, seed_v), sp, Vector2(shalf, shalf), true)
		canvases.append(gm)
		kinds.append("clod_mask")
	var bl := maxf(FxData.f(fall, "bomb_len_m") * ppm, FxData.f(fall, "min_px"))
	var bhalf := int(ceil(bl * 0.75 + 3.0))
	bs.bomb_origin = Vector2(bhalf, bhalf)
	var gb := InkCanvas.new(Vector2i(bhalf * 2, bhalf * 2))
	gb.line_cap = "round"
	draw_bomb(gb, st, fall, bl, Vector2(bhalf, bhalf), false)
	canvases.append(gb)
	kinds.append("bomb")
	var gbm := InkCanvas.new(Vector2i(bhalf * 2, bhalf * 2))
	draw_bomb(gbm, st, fall, bl, Vector2(bhalf, bhalf), true)
	canvases.append(gbm)
	kinds.append("bomb_mask")
	var imgs := FxBake.render(canvases)
	for k in kinds.size():
		match kinds[k]:
			"crater":
				bs.craters.append(FxBake.texture(imgs[k], false))
			"clod":
				bs.clods.append(FxBake.texture(imgs[k], false))
			"clod_mask":
				bs.clod_masks.append(FxBake.texture(imgs[k], true))
			"bomb":
				bs.bomb = FxBake.texture(imgs[k], false)
			"bomb_mask":
				bs.bomb_mask = FxBake.texture(imgs[k], true)
	return bs

# Only the falling bomb, at one scale (it does not depend on the size of the blast).
static func bake_drop(st: FxStyle, fall: Dictionary, ppm: float) -> BombSet:
	if not FxBake.can_bake():
		return null
	var bs := BombSet.new()
	bs.ppm = ppm
	var bl := maxf(FxData.f(fall, "bomb_len_m") * ppm, FxData.f(fall, "min_px"))
	var bhalf := int(ceil(bl * 0.75 + 3.0))
	bs.bomb_origin = Vector2(bhalf, bhalf)
	var gb := InkCanvas.new(Vector2i(bhalf * 2, bhalf * 2))
	gb.line_cap = "round"
	draw_bomb(gb, st, fall, bl, Vector2(bhalf, bhalf), false)
	var gbm := InkCanvas.new(Vector2i(bhalf * 2, bhalf * 2))
	draw_bomb(gbm, st, fall, bl, Vector2(bhalf, bhalf), true)
	var imgs := FxBake.render([gb, gbm])
	bs.bomb = FxBake.texture(imgs[0], false)
	bs.bomb_mask = FxBake.texture(imgs[1], true)
	return bs

# --- The crater ------------------------------------------------------------------------------------------------------------

static func _blob(st: FxStyle, rng: Mulberry32, cx: float, cy: float, r: float, n: int, amp: float) -> PackedVector2Array:
	var amps := PackedFloat64Array()
	for _i in n:
		amps.push_back(amp * (0.5 + rng.next() * 0.5))
	var out: Array = InkSprites.scallop(cx, cy, maxf(r, 0.5), n, rng.next() * PI, amps, st.wobble(), int(rng.next() * 1e6))
	return out[0]

static func draw_crater(g: InkCanvas, st: FxStyle, c: Dictionary, seed_v: int, R: float, at: Vector2) -> void:
	var rng := Mulberry32.new(seed_v)
	var form := FxData.s(c, "form")
	var light := st.detail_light
	var stretch := FxData.f(c, "stretch")
	var skew := Vector2(rng.next() - 0.5, rng.next() - 0.5) * R * 0.12
	var ctr := at + skew
	# an irregular outline: a few random harmonics round the circle
	var p2 := rng.next() * TAU
	var p3 := rng.next() * TAU
	var p5 := rng.next() * TAU
	var pit := _blob(st, rng, ctr.x, ctr.y, R * 0.92, 11, FxData.f(c, "lobe_amp"))
	if stretch != 1.0:
		for i in pit.size():
			pit[i] = Vector2(ctr.x + (pit[i].x - ctr.x) * stretch, ctr.y + (pit[i].y - ctr.y) / sqrt(stretch))
	# the pale lip of thrown earth, first (the pit sits over its inner edge)
	if form == "rimmed":
		var lip := PackedVector2Array()
		for i in pit.size():
			var d := (pit[i] - ctr)
			lip.push_back(ctr + d * FxData.f(c, "rim_out"))
		InkSprites.trace_path(g, lip)
		g.fill_color = st.color(FxData.s(c, "rim_role"))
		g.fill()
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("tree_inner_rings") * 0.9
		g.global_alpha = 0.55
		g.stroke()
		g.global_alpha = 1.0
	# the pit: an ink wash
	InkSprites.trace_path(g, pit)
	g.fill_color = st.color(FxData.s(c, "pit_role"))
	g.fill()
	# dirt stipple, thick in the middle
	var dots := PackedVector2Array()
	var soft := PackedVector2Array()
	var n := roundi(PI * R * R * FxData.f(c, "dots_per_px2"))
	for i in n:
		var a := rng.next() * TAU
		var f := clampf(1.0 + 0.18 * sin(2.0 * a + p2) + 0.12 * sin(3.0 * a + p3) + 0.08 * sin(5.0 * a + p5), 0.55, 1.35)
		var d := pow(rng.next(), FxData.f(c, "core_bias")) * R * f * 0.95
		var p := Vector2(ctr.x + cos(a) * d * stretch, ctr.y + sin(a) * d / sqrt(stretch))
		if rng.next() < 0.35:
			soft.push_back(p)
		else:
			dots.push_back(p)
	_dots(g, dots, FxData.f(c, "dot_px"), st.color(FxData.s(c, "dot_role")))
	_dots(g, soft, FxData.f(c, "dot_px") * 1.2, st.color(FxData.s(c, "dot_soft_role")))
	# hatch on the inner wall that faces the light (it is the far wall that is in shade, so the wall
	# toward the light is the one the eye sees dark: short strokes there, thinning toward the middle)
	g.stroke_color = st.color(FxData.s(c, "hatch_role"))
	g.line_width = st.line_weight() * st.lw("cusp_ticks") * FxData.f(c, "hatch_weight")
	g.begin_path()
	var made := 0
	var tries := 0
	var hn := FxData.i(c, "hatch")
	while made < hn and tries < hn * 12:
		tries += 1
		var a := rng.next() * TAU
		var d := lerpf(0.45, 0.96, sqrt(rng.next())) * R
		var dx := cos(a)
		var dy := sin(a)
		if dx * light.x + dy * light.y < 0.1:
			continue
		var len := R * (0.16 + rng.next() * 0.2)
		var p := Vector2(ctr.x + dx * d * stretch, ctr.y + dy * d / sqrt(stretch))
		g.move_to(p.x, p.y)
		g.line_to(p.x + len * 0.7071, p.y + len * 0.7071)
		made += 1
	g.stroke()
	# the ink ring on the lip: a closed outline in the palette's ink, so the pen draws it heavy on the edge that faces away
	# from the sun and thin on the lit edge (the same rule as every outline on the map)
	if FxData.b(c, "ring") and pit.size() > 4:
		g.stroke_color = st.ink()
		g.line_width = st.line_weight() * st.lw("tree_outline") * FxData.f(c, "ring_weight")
		g.global_alpha = FxData.f(c, "ring_alpha")
		InkSprites.trace_path(g, pit)
		g.stroke()
		g.global_alpha = 1.0
	# flecks of earth thrown out round the lip
	var fl := PackedVector2Array()
	for i in FxData.i(c, "flecks"):
		var a := rng.next() * TAU
		var d := R * (1.05 + rng.next() * 0.75)
		fl.push_back(Vector2(ctr.x + cos(a) * d * stretch, ctr.y + sin(a) * d / sqrt(stretch)))
	_dots(g, fl, FxData.f(c, "dot_px") * 1.1, st.color(FxData.s(c, "dot_role")))

static func _dots(g: InkCanvas, pts: PackedVector2Array, r: float, col: Color) -> void:
	if pts.is_empty():
		return
	g.fill_color = col
	g.begin_path()
	for p in pts:
		g.move_to(p.x + r, p.y)
		g.arc(p.x, p.y, r, 0.0, TAU)
	g.fill()

# --- A clod -----------------------------------------------------------------------------------------------------------------------

static func draw_clod(g: InkCanvas, st: FxStyle, deb: Dictionary, seed_v: int, size: float, at: Vector2, mask: bool) -> void:
	var rng := Mulberry32.new(seed_v)
	var n := 5 + int(rng.next() * 3.0)
	var pts := PackedVector2Array()
	for i in n:
		var a := float(i) / float(n) * TAU + (rng.next() - 0.5) * 0.6
		var r := size * (0.5 + rng.next() * 0.5)
		pts.push_back(Vector2(at.x + cos(a) * r, at.y + sin(a) * r * 0.8))
	InkSprites.trace_path(g, pts)
	if mask:
		g.fill_color = Color.WHITE
		g.fill()
		return
	g.fill_color = st.color(FxData.s(deb, "clod_role"))
	g.fill()
	g.stroke_color = st.ink()
	g.line_width = st.line_weight() * st.lw("tree_inner_rings") * 0.8
	g.global_alpha = 0.8
	g.stroke()
	g.global_alpha = 1.0

# --- The bomb itself -------------------------------------------------------------------------------------------------------------------

# A teardrop pointing +x, its fins at the tail: the body in ink, a pale stripe along the side that faces the light.
static func draw_bomb(g: InkCanvas, st: FxStyle, fall: Dictionary, len_px: float, at: Vector2, mask: bool) -> void:
	var L := len_px
	var W := L * FxData.f(fall, "bomb_w_frac")
	var pts := PackedVector2Array()
	var n := 14
	for i in n:
		var a := float(i) / float(n) * TAU
		var x := cos(a)
		var y := sin(a)
		# fat toward the nose (+x), tapered to a tail
		var half_w := W * 0.5 * (0.55 + 0.45 * x)
		pts.push_back(Vector2(at.x + x * L * 0.5, at.y + y * maxf(half_w, 0.2)))
	InkSprites.trace_path(g, pts)
	if mask:
		g.fill_color = Color.WHITE
		g.fill()
		return
	g.fill_color = st.color(FxData.s(fall, "body_role"))
	g.fill()
	g.stroke_color = st.ink()
	g.line_width = st.line_weight() * st.lw("tree_inner_rings") * 0.9
	g.stroke()
	# the pale stripe on the lit (top-left) side, and the fins
	var lit := st.detail_light
	g.stroke_color = st.color(FxData.s(fall, "stripe_role"))
	g.line_width = maxf(st.line_weight() * 0.7, 0.8)
	g.begin_path()
	g.move_to(at.x - L * 0.15, at.y + lit.y * W * 0.22)
	g.line_to(at.x + L * 0.3, at.y + lit.y * W * 0.22)
	g.stroke()
	g.stroke_color = st.ink()
	g.line_width = st.line_weight() * st.lw("cusp_ticks")
	g.begin_path()
	g.move_to(at.x - L * 0.5, at.y)
	g.line_to(at.x - L * 0.72, at.y - W * 0.9)
	g.move_to(at.x - L * 0.5, at.y)
	g.line_to(at.x - L * 0.72, at.y + W * 0.9)
	g.stroke()
