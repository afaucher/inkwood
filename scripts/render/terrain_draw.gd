extends RefCounted

# Drawing the terrain's levels in ink (Track T). ALL PROPOSED: the design doc
# leaves "how height reads in ink (contours, hachures or shading)" open, so
# this is a FIRST OPTION with an alternative behind a data switch
# (data/terrain/terrain.json draw.style):
#
#   "hachures" (default)  the level boundary as one contour at the scarp top,
#                         plus short ink strokes running down the slope from
#                         it -- alternating long and short (the cartographer's
#                         escarpment sign), broken by thresholded noise like
#                         the prototype's rut lines, leaning and varying in
#                         length by noise (the hand), tapered wedges or plain
#                         hairlines (draw.hachures.shape).
#   "contours"            the scarp as 2-3 nested contours down the slope,
#                         fading and breaking like the wall crest lines.
#
# Each level's PAPER is the paper lifted by one fill-ramp step per level in OK
# lightness, chroma eased (palette proposal: lightness is a ramp off paper,
# never a new hue). It is added over whatever ground is already drawn, so the
# paper's noise, specks and dirt stay.
#
#   var td := TerrainDraw.new(terrain)                       # reads draw.* from terrain.json
#   var masks := td.level_masks(view, size)                  # RENDERS (windowed): one per threshold
#   td.draw_level_fill(frame, masks)                         # after the ground, before any shadow
#   td.draw_linework(frame, view, rect)                      # contours / hachures, still ground
#
# `view` maps world pixels to frame pixels (zoom and pan); `rect` is the world
# pixel rectangle being drawn (the frame through the inverse view, or a baked
# chunk's rect). Line widths scale with the view, as the prototype's would
# under a canvas transform.
#
# PASS ORDER (proposed, for Track R's renderer and Track V's chunk bake):
#   1 paper ground   1a draw_level_fill   1b draw_linework   (2 road)
#   2.5 terrain shadows (terrain_shadows.gd)   3 prop shadows ... 7 tree shadows
#   (terrain_shadows.gd for trees on raised ground) 8 trees (sorted by base + h,
#   then y) 9 grain.
# Linework sits under every shadow: like the road ruts, it is part of the ground.
#
# Colours, ink and the line-weight table come from data/params/render_defaults.json
# (RenderParams); the weights are NAMED from its linework table in terrain.json,
# so no hex and no weight literal lives here.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Terrain = preload("res://scripts/world/terrain.gd")

# Noise-stream salts for the linework (code constants, not tunables).
const SALT_WOBBLE := 501
const SALT_BREAK := 613
const SALT_LENGTH := 727
const SALT_ANGLE := 839

const _FILL_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_add;
uniform vec3 inc;
void fragment() {
	COLOR = vec4(inc, texture(TEXTURE, UV).r);
}
"""

var terrain: Terrain
var P: RenderParams
var errors: Array[String] = []

var style: String
var level_paper: Array[Color] = []
var contour_weight: float
var contour_alpha: float
var contour_wobble: float
var contour_wobble_f: float
var hach_spacing: float
var hach_long: float
var hach_short: float
var hach_len_jitter: float
var hach_angle_jitter: float
var hach_weight: float
var hach_alpha: float
var hach_shape: String
var hach_wedge_w: float
var hach_break_f: float
var hach_break_thr: float
var cont_count: int
var cont_spacing: float
var cont_alphas := PackedFloat64Array()
var cont_breaks := PackedFloat64Array()
var cont_break_f: float
var cont_weight: float

var _fill_shader: Shader

func _init(t: Terrain, params: RenderParams = null) -> void:
	terrain = t
	P = params if params != null else RenderParams.new()
	var d := terrain.data
	style = d.text("draw.style")
	if style != "hachures" and style != "contours":
		_err("draw.style must be 'hachures' or 'contours', not '%s'" % style)
	var step := d.num("draw.level_fill.ok_lightness_step")
	var chroma := d.num("draw.level_fill.chroma_scale_per_step")
	for k in terrain.level_count():
		level_paper.append(lift(P.PAPER, step * k, pow(chroma, k)))
	contour_weight = _weight(d.text("draw.contour.weight"))
	contour_alpha = d.num("draw.contour.alpha")
	contour_wobble = d.num("draw.contour.wobble")
	contour_wobble_f = d.num("draw.contour.wobble_noise_per_px")
	hach_spacing = d.num("draw.hachures.spacing_px")
	hach_long = d.num("draw.hachures.long")
	hach_short = d.num("draw.hachures.short")
	hach_len_jitter = d.num("draw.hachures.length_jitter")
	hach_angle_jitter = d.num("draw.hachures.angle_jitter")
	hach_weight = _weight(d.text("draw.hachures.weight"))
	hach_alpha = d.num("draw.hachures.alpha")
	hach_shape = d.text("draw.hachures.shape")
	if hach_shape != "wedge" and hach_shape != "stroke":
		_err("draw.hachures.shape must be 'wedge' or 'stroke', not '%s'" % hach_shape)
	hach_wedge_w = d.num("draw.hachures.wedge_width_px")
	hach_break_f = d.num("draw.hachures.break_noise_per_px")
	hach_break_thr = d.num("draw.hachures.break_threshold")
	cont_count = d.integer("draw.contours.count")
	cont_spacing = d.num("draw.contours.spacing_scarp")
	cont_alphas = d.floats("draw.contours.alphas")
	cont_breaks = d.floats("draw.contours.break_thresholds")
	cont_break_f = d.num("draw.contours.break_noise_per_px")
	if cont_alphas.size() < cont_count or cont_breaks.size() < cont_count:
		_err("draw.contours.alphas and break_thresholds need draw.contours.count entries")
	cont_weight = _weight(d.text("draw.contours.weight"))

func ok() -> bool:
	return errors.is_empty()

func _err(message: String) -> void:
	errors.append(message)
	push_error("TerrainDraw: " + message)

# A named multiplier from render_defaults.json's linework table.
func _weight(name: String) -> float:
	if P.linework.has(name):
		return float(P.linework[name])
	_err("linework multiplier '%s' is not in %s" % [name, P.source_path])
	return 1.0

# --- colour: a fill-ramp step in OKLab -------------------------------------------

# `c` lifted by dL in OK lightness with its chroma scaled -- the palette
# proposal's fill ramp (fills are paper plus a lightness step, chroma eased).
static func lift(c: Color, dL: float, chroma_scale: float) -> Color:
	var lab := to_oklab(c)
	return from_oklab(lab.x + dL, lab.y * chroma_scale, lab.z * chroma_scale)

static func _lin(v: float) -> float:
	return v / 12.92 if v <= 0.04045 else pow((v + 0.055) / 1.055, 2.4)

static func _gam(v: float) -> float:
	return 12.92 * v if v <= 0.0031308 else 1.055 * pow(v, 1.0 / 2.4) - 0.055

static func to_oklab(c: Color) -> Vector3:
	var r := _lin(c.r)
	var g := _lin(c.g)
	var b := _lin(c.b)
	var l := pow(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 1.0 / 3.0)
	var m := pow(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 1.0 / 3.0)
	var s := pow(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 1.0 / 3.0)
	return Vector3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)

static func from_oklab(L: float, a: float, b: float) -> Color:
	var l := L + 0.3963377774 * a + 0.2158037573 * b
	var m := L - 0.1055613458 * a - 0.0638541728 * b
	var s := L - 0.0894841775 * a - 1.2914855480 * b
	l = l * l * l
	m = m * m * m
	s = s * s * s
	return Color(clampf(_gam(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s), 0.0, 1.0),
		clampf(_gam(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s), 0.0, 1.0),
		clampf(_gam(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), 0.0, 1.0))

# --- views ---------------------------------------------------------------------------

# The world-pixel rectangle a frame of `size` shows through `view`.
static func view_rect(view: Transform2D, size: Vector2i) -> Rect2:
	var inv := view.affine_inverse()
	var r := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	for p: Vector2 in [Vector2(size.x, 0), Vector2(0, size.y), Vector2(size)]:
		r = r.expand(inv * p)
	return r

# --- level masks (RENDERS: windowed runs only) -------------------------------------------

# One frame-sized mask per threshold k: white where the level is k+1 or more,
# black elsewhere, antialiased at the boundary. Built from the same smoothed
# polygons level_at() tests. Chunk border polygons go into ONE fill per
# threshold, so neighbouring chunks meet without an antialiasing seam; closed
# rings follow largest first, white for an upland ring and black for a hole,
# which paints any nesting correctly because rings never cross.
func level_masks(view: Transform2D, size: Vector2i) -> Array[ImageTexture]:
	var rect := view_rect(view, size)
	var chunks := terrain.chunks_in_rect_px(rect)
	var canvases: Array = []
	for k in terrain.thresholds.size():
		var g := InkCanvas.new(size)
		g.fill_color = Color.BLACK
		g.fill_rect(0.0, 0.0, float(size.x), float(size.y))
		g.set_transform_matrix(view)
		g.fill_color = Color.WHITE
		g.begin_path()
		var rings: Array = []
		var any := false
		for c in chunks:
			for poly: Dictionary in terrain.polys_px(c.x, c.y, k):
				if poly.border:
					_add_poly(g, poly.pts)
					any = true
				else:
					rings.append(poly)
		if any:
			g.fill()
		rings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return absf(a.area) > absf(b.area))
		for ring: Dictionary in rings:
			g.fill_color = Color.WHITE if ring.area > 0.0 else Color.BLACK
			g.begin_path()
			_add_poly(g, ring.pts)
			g.fill()
		canvases.append(g)
	var out: Array[ImageTexture] = []
	for img in InkCanvas.render_all(canvases):
		out.append(ImageTexture.create_from_image(img))
	return out

static func _add_poly(g: InkCanvas, pts: PackedVector2Array) -> void:
	g.move_to(pts[0].x, pts[0].y)
	for i in range(1, pts.size()):
		g.line_to(pts[i].x, pts[i].y)
	g.close_path()

# --- level fill ------------------------------------------------------------------------

# Adds each level's lightness step over the ground already on `g`, through the
# masks: level k gets paper_k - paper_0 in total, so the paper texture stays.
# Frame space (the masks are frame-sized); call before shadows and linework.
func draw_level_fill(g: InkCanvas, masks: Array) -> void:
	if _fill_shader == null:
		_fill_shader = Shader.new()
		_fill_shader.code = _FILL_SHADER
	for k in masks.size():
		var a: Color = level_paper[k]
		var b: Color = level_paper[k + 1]
		var inc := Vector3(maxf(b.r - a.r, 0.0), maxf(b.g - a.g, 0.0), maxf(b.b - a.b, 0.0))
		var mat := ShaderMaterial.new()
		mat.shader = _fill_shader
		mat.set_shader_parameter("inc", inc)
		var tex: Texture2D = masks[k]
		g.save()
		g.reset_transform()
		g.global_alpha = 1.0
		g.draw_image_with_material(tex, 0.0, 0.0, float(tex.get_width()), float(tex.get_height()), mat)
		g.restore()

# --- linework ----------------------------------------------------------------------------

# The boundaries of every chunk that `rect` (world px) touches, in ink, under `view`.
func draw_linework(g: InkCanvas, view: Transform2D, rect: Rect2) -> void:
	var scarp := terrain.scarp_m * terrain.px_per_m
	var chunks := terrain.chunks_in_rect_px(rect.grow(scarp * 2.0))
	g.save()
	g.set_transform_matrix(view)
	g.line_cap = "round"
	for k in terrain.thresholds.size():
		var chains: Array = []
		for c in chunks:
			chains.append_array(terrain.chains_px(c.x, c.y, k))
		if chains.is_empty():
			continue
		var ns := terrain.seed_value % 9973 + k * 37
		if style == "contours":
			for j in cont_count:
				var w := contour_weight if j == 0 else cont_weight
				_stroke_contour(g, chains, ns, scarp * cont_spacing * j, cont_alphas[j], w, cont_breaks[j])
		else:
			_hachures(g, chains, ns, scarp)
			_stroke_contour(g, chains, ns, 0.0, contour_alpha, contour_weight, 0.0)
	g.restore()

# Down-slope unit normals: the chain has the higher level on its right, so
# the lower level is on its left, (dy, -dx) in screen coordinates.
static func _down_normals(pts: PackedVector2Array, closed: bool) -> PackedVector2Array:
	var n := pts.size()
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		var a: Vector2 = pts[(i - 1 + n) % n] if closed else pts[maxi(i - 1, 0)]
		var b: Vector2 = pts[(i + 1) % n] if closed else pts[mini(i + 1, n - 1)]
		var d := b - a
		var l := d.length()
		out[i] = Vector2(d.y, -d.x) / l if l > 0.0 else Vector2.ZERO
	return out

# The prototype's rut wobble, (vnoise - .5) * 2.6 * (.35 + wob), scaled, at a
# world position -- so a line crossing a chunk border wobbles continuously.
func _wobble(p: Vector2, ns: int) -> float:
	return (ValueNoise.vnoise(p.x * contour_wobble_f, p.y * contour_wobble_f, ns + SALT_WOBBLE) - 0.5) \
		* 2.6 * (0.35 + P.wob) * contour_wobble

# One wobbling line `offset` px down the slope from every chain, broken where
# noise falls under `break_thr` (0: unbroken), in one stroke.
func _stroke_contour(g: InkCanvas, chains: Array, ns: int, offset: float, alpha: float, weight: float, break_thr: float) -> void:
	g.stroke_color = P.INK
	g.line_width = P.lw * weight
	g.global_alpha = alpha
	g.begin_path()
	for ch: Dictionary in chains:
		var pts: PackedVector2Array = ch.pts
		var nrm := _down_normals(pts, ch.closed)
		var n := pts.size()
		var lim := n + 1 if ch.closed else n
		var pen := false
		for q in lim:
			var i := q % n
			var p := pts[i]
			if break_thr > 0.0 and ValueNoise.vnoise(p.x * cont_break_f, p.y * cont_break_f, ns + SALT_BREAK + 17) < break_thr:
				pen = false
				continue
			var o := p + nrm[i] * (offset + _wobble(p, ns))
			if pen:
				g.line_to(o.x, o.y)
			else:
				g.move_to(o.x, o.y)
				pen = true
	g.stroke()
	g.global_alpha = 1.0

# Hachures down the slope from the contour, one paint call for all of them.
func _hachures(g: InkCanvas, chains: Array, ns: int, scarp: float) -> void:
	var wedge := hach_shape == "wedge"
	g.begin_path()
	var count := 0
	for ch: Dictionary in chains:
		var pts: PackedVector2Array = ch.pts
		var n := pts.size()
		if n < 2:
			continue
		var nrm := _down_normals(pts, ch.closed)
		var lim := n if ch.closed else n - 1
		var next_at := hach_spacing * 0.5
		var walked := 0.0
		var j := 0
		for i in lim:
			var a := pts[i]
			var b := pts[(i + 1) % n]
			var seg := a.distance_to(b)
			while next_at <= walked + seg and seg > 0.0:
				var t := (next_at - walked) / seg
				var p := a.lerp(b, t)
				var down := nrm[i].lerp(nrm[(i + 1) % n], t).normalized()
				next_at += hach_spacing
				j += 1
				if ValueNoise.vnoise(p.x * hach_break_f, p.y * hach_break_f, ns + SALT_BREAK) < hach_break_thr:
					continue
				var len_n := ValueNoise.vnoise(p.x * 0.05, p.y * 0.05, ns + SALT_LENGTH) * 2.0 - 1.0
				var ang_n := ValueNoise.vnoise(p.x * 0.04, p.y * 0.04, ns + SALT_ANGLE) * 2.0 - 1.0
				var length := scarp * (hach_long if j % 2 == 0 else hach_short) * (1.0 + hach_len_jitter * len_n)
				var dir := down.rotated(hach_angle_jitter * ang_n)
				var top := p + down * _wobble(p, ns)
				var foot := top + dir * length
				if wedge:
					var side := Vector2(-dir.y, dir.x)
					var w0 := side * hach_wedge_w * 0.5
					var w1 := side * hach_wedge_w * 0.075
					g.move_to(top.x + w0.x, top.y + w0.y)
					g.line_to(foot.x + w1.x, foot.y + w1.y)
					g.line_to(foot.x - w1.x, foot.y - w1.y)
					g.line_to(top.x - w0.x, top.y - w0.y)
					g.close_path()
				else:
					g.move_to(top.x, top.y)
					g.line_to(foot.x, foot.y)
				count += 1
			walked += seg
	if count == 0:
		return
	g.global_alpha = hach_alpha
	if wedge:
		g.fill_color = P.INK
		g.fill()
	else:
		g.stroke_color = P.INK
		g.line_width = P.lw * hach_weight
		g.stroke()
	g.global_alpha = 1.0
