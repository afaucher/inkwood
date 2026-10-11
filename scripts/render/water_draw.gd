extends RefCounted

# DRAWING WATER (Track WB, 2026-10-10): the board variants/water/ draws the generator's water
# (scripts/world/water_gen.gd) with the game's own drawing layer. The FRAME functions below (make_masks, draw_wash,
# draw_halo, draw_lines: the board's, all six options) are the prototype; the CHUNK functions at the end of the file (chunk_geometry,
# chunk_masks, draw_chunk_wash, draw_chunk_lines, chunk_step_lines) are what the live map runs in the chunk baker
# (scripts/render/chunk_terrain_provider.gd, the stages `water` and `water_masks`) and what the contour map's water
# (scripts/render/fog_topo.gd) takes its rings and lines from: look A only (Alex's choice), in the chunk's own px_per_m.
# WINDOWED ONLY -- the masks and washes are rendered.
#
#   var wd := WaterDraw.new(P)                         # reads data/world/water.json (draw.*)
#   var opt := wd.option("A")                          # the option's switches (data draw.options)
#   var fm := WaterDraw.FrameMasks.new(water, view, size)   # the frame's masks, shared by every option
#   wd.draw_halo(g, opt, fm, paper)                    # the pale band on the land (C, E)   -- before the wash
#   wd.draw_wash(g, opt, fm, up_mask, paper)           # the stepped (or smooth) blue wash  -- over the ground
#   wd.draw_lines(g, opt, water, fm, rect_px)          # ink at the steps / shore, ripples, pale edges
#
# `view` maps world px to frame px, as terrain_draw.gd's; `rect_px` is the world-pixel rectangle the
# frame shows. THE PASS ORDER (the board's, proposed for Track R / V when a look is chosen):
#   paper ground (+ road, fields) -> halo -> WASH -> level fill -> water lines -> contours and
#   hachures (terrain_draw.gd) -> shadows (terrain_shadows.gd: the water is level 0, nothing changes)
#   -> structures -> trees (never on water) -> grain.
#
# THE WASH IS A SHADER OVER THE FRAME: three masks (the region where the depth is at least each step's
# start, the generator's rings and river ribbons filled white on black), the uplands' mask (an upland
# is never water) and the paper tint (so the wash keeps the paper's own mottle: a wash on paper, not
# a flat digital fill). The stepped look picks the step's colour; the smooth look blurs the masks, so
# the steps run into one another and the shore melts into the ground (the reference's gradient).
#
# COLOURS ARE ROLES: the water hue is one number, the steps are lightness BELOW THE PAPER'S and a
# chroma each (data draw.palette), resolved here in OKLab -- no hex in this file (CLAUDE.md rule 6).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const TerrainData = preload("res://scripts/world/terrain_data.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const ValueNoise = preload("res://scripts/core/noise.gd")

const WATER_PATH := "res://data/world/water.json"
const WASH_SHADER = preload("res://scripts/render/shaders/water_wash.gdshader")

# The wash: the step colour by mask, over everything, through the upland cut, with the paper's mottle. Each step's
# mask is the sea's and the river's, whichever covers more (the river keeps a sharper edge than the sea's soft shore).
const _WASH_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
uniform sampler2D s0 : filter_linear;
uniform sampler2D s1 : filter_linear;
uniform sampler2D s2 : filter_linear;
uniform sampler2D r0 : filter_linear;
uniform sampler2D r1 : filter_linear;
uniform sampler2D r2 : filter_linear;
uniform sampler2D up : filter_nearest;
uniform sampler2D paper : filter_linear;
uniform vec3 c0;
uniform vec3 c1;
uniform vec3 c2;
uniform vec3 paper_ref;
uniform float alpha = 1.0;
uniform float mottle = 0.85;
void fragment() {
	float a0 = max(texture(s0, UV).r, texture(r0, UV).r);
	float a1 = max(texture(s1, UV).r, texture(r1, UV).r);
	float a2 = max(texture(s2, UV).r, texture(r2, UV).r);
	float u = texture(up, UV).r;
	vec3 col = mix(c0, c1, a1);
	col = mix(col, c2, a2);
	float cov = a0 * (1.0 - u) * alpha;
	vec3 p = texture(paper, UV).rgb;
	float m = dot(p, vec3(0.299, 0.587, 0.114)) / dot(paper_ref, vec3(0.299, 0.587, 0.114));
	col *= mix(1.0, m, mottle);
	COLOR = vec4(col * cov, cov);
}
"""

# The pale band on the land at the water's edge: the blurred water mask where the soft water is not.
const _HALO_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
uniform sampler2D wide_s : filter_linear;
uniform sampler2D wide_r : filter_linear;
uniform sampler2D near_s : filter_linear;
uniform sampler2D near_r : filter_linear;
uniform sampler2D up : filter_nearest;
uniform vec3 pale;
uniform float alpha = 0.9;
void fragment() {
	float b = max(texture(wide_s, UV).r, texture(wide_r, UV).r);
	float n = max(texture(near_s, UV).r, texture(near_r, UV).r);
	float u = texture(up, UV).r;
	float h = smoothstep(0.03, 0.42, b) * (1.0 - smoothstep(0.35, 0.75, n)) * (1.0 - u) * alpha;
	COLOR = vec4(pale * h, h);
}
"""

# One pass of a separable gaussian (the taps are one texel apart: the blur runs on a quarter-size mask).
const _BLUR_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
uniform vec2 dir = vec2(1.0, 0.0);
uniform float sigma = 4.0;
void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	float acc = 0.0;
	float ws = 0.0;
	int n = int(ceil(sigma * 3.0));
	for (int i = -n; i <= n; i++) {
		float x = float(i);
		float w = exp(-0.5 * x * x / (sigma * sigma));
		acc += w * texture(TEXTURE, UV + dir * px * x).r;
		ws += w;
	}
	float v = acc / ws;
	COLOR = vec4(v, v, v, 1.0);
}
"""

var data: TerrainData
var P: RenderParams
var errors: Array[String] = []

var ppm: float
var hue_deg: float
var steps: Array[Color] = []
var halo_color: Color
var halo_alpha := 0.9
var wash_alpha: float
var mottle: float
var options: Dictionary = {}
var working_default: String
var variants: Array = []
var paper_lab := Vector3.ZERO

var _l_below := PackedFloat64Array()
var _chroma := PackedFloat64Array()
var _halo_lift: float
var _halo_chroma: float

var ink_weight: float
var ink_alpha: float
var step_weight: float
var step_alphas := PackedFloat64Array()
var line_wobble: float
var line_wobble_f: float
var pale_alpha: float
var pale_lift: float
var pale_width: float
var soft_blur_m: float
var halo_m: float
var river_blur_m: float
var river_halo_m: float
var gradient_blur_m := PackedFloat64Array()
var ripple_offsets := PackedFloat64Array()
var ripple_alphas := PackedFloat64Array()
var ripple_weight: float
var ripple_break_f: float
var ripple_break_thr := PackedFloat64Array()

var mask_ssaa: int
var clip_px: float

var _wash_mat: ShaderMaterial
var _halo_mat: ShaderMaterial
var _blur_shader: Shader
var _white: ImageTexture

func _init(params: RenderParams, hue_override: float = -1.0, path: String = WATER_PATH) -> void:
	P = params
	data = TerrainData.new(path)
	if not data.ok():
		errors.append_array(data.errors)
		return
	ppm = data.num("draw.px_per_m")
	hue_deg = data.num("draw.palette.hue_deg") if hue_override < 0.0 else hue_override
	_l_below = data.floats("draw.palette.lightness_below_paper")
	_chroma = data.floats("draw.palette.chroma")
	wash_alpha = data.num("draw.palette.wash_alpha")
	mottle = data.num("draw.palette.paper_mottle")
	_halo_lift = data.num("draw.palette.halo_lift")
	_halo_chroma = data.num("draw.palette.halo_chroma_scale")
	var lw := P.linework
	ink_weight = _named(lw, data.text("draw.line.ink_weight"))
	ink_alpha = data.num("draw.line.ink_alpha")
	step_weight = _named(lw, data.text("draw.line.step_weight"))
	step_alphas = data.floats("draw.line.step_alphas")
	line_wobble = data.num("draw.line.wobble")
	line_wobble_f = data.num("draw.line.wobble_noise_per_px")
	pale_alpha = data.num("draw.line.pale_alpha")
	pale_lift = data.num("draw.line.pale_lift")
	pale_width = data.num("draw.line.pale_width_px")
	soft_blur_m = data.num("draw.soft.blur_m")
	halo_m = data.num("draw.soft.halo_m")
	river_blur_m = data.num("draw.soft.river_blur_m")
	river_halo_m = data.num("draw.soft.river_halo_m")
	gradient_blur_m = data.floats("draw.soft.gradient_blur_m")
	ripple_offsets = data.floats("draw.ripples.offsets_m")
	ripple_alphas = data.floats("draw.ripples.alphas")
	ripple_weight = _named(lw, data.text("draw.ripples.weight"))
	ripple_break_f = data.num("draw.ripples.break_noise_per_px")
	ripple_break_thr = data.floats("draw.ripples.break_threshold")
	options = data.dict("draw.options")
	working_default = data.text("draw.working_default")
	variants = data.list("draw.palette_variants")
	data.value("draw.grid_cell_m")
	data.value("draw.chaikin_passes")
	data.value("draw.resample_m")
	mask_ssaa = data.integer("draw.chunk.mask_ssaa")
	clip_px = data.num("draw.chunk.clip_px")
	errors.append_array(data.errors)
	for pair in [[_l_below, 3, "draw.palette.lightness_below_paper"], [_chroma, 3, "draw.palette.chroma"], [step_alphas, 3, "draw.line.step_alphas"],
			[gradient_blur_m, 3, "draw.soft.gradient_blur_m"], [ripple_offsets, 3, "draw.ripples.offsets_m"], [ripple_alphas, 3, "draw.ripples.alphas"],
			[ripple_break_thr, 3, "draw.ripples.break_threshold"]]:
		if (pair[0] as PackedFloat64Array).size() != pair[1]:
			errors.append("%s needs %d numbers" % [pair[2], pair[1]])
	_resolve_colours()

func ok() -> bool:
	return errors.is_empty()

func _named(table: Dictionary, name: String) -> float:
	if table.has(name):
		return float(table[name])
	errors.append("linework multiplier '%s' is not in %s" % [name, P.source_path])
	return 1.0

# --- colour roles --------------------------------------------------------------------------------------

func _resolve_colours() -> void:
	paper_lab = TerrainDraw.to_oklab(P.PAPER)
	steps.clear()
	for k in 3:
		steps.append(oklch_color(paper_lab.x - _l_below[k], _chroma[k], hue_deg))
	halo_color = TerrainDraw.lift(P.PAPER, _halo_lift, _halo_chroma)

# OKLCH (L, C, hue in degrees) -> a clamped sRGB colour.
static func oklch_color(L: float, C: float, h_deg: float) -> Color:
	return TerrainDraw.from_oklab(L, C * cos(deg_to_rad(h_deg)), C * sin(deg_to_rad(h_deg)))

# Whether (L, C, h) is inside sRGB without clamping (the board's palette strip and the test check it).
static func in_gamut(L: float, C: float, h_deg: float) -> bool:
	var a := C * cos(deg_to_rad(h_deg))
	var b := C * sin(deg_to_rad(h_deg))
	var l := L + 0.3963377774 * a + 0.2158037573 * b
	var m := L - 0.1055613458 * a - 0.0638541728 * b
	var s := L - 0.0894841775 * a - 1.2914855480 * b
	l = l * l * l
	m = m * m * m
	s = s * s * s
	var rgb := [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s, -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
	for v: float in rgb:
		if v < -0.002 or v > 1.002:
			return false
	return true

func option(letter: String) -> Dictionary:
	if options.has(letter):
		return options[letter]
	errors.append("no water option '%s'" % letter)
	return {}

# --- the frame's masks ---------------------------------------------------------------------------------------

# The masks of one frame (one view of one water), made once and shared by every option: the sharp ones
# (full size, three steps), and the blurred ones on demand (a quarter size, blurred, kept by sigma).
class FrameMasks:
	var water: RefCounted
	var view: Transform2D
	var size: Vector2i
	var rect_px: Rect2
	var sea: Array = []            # ImageTexture x 3, white where the SEA's depth is at least the step's start
	var river: Array = []          # the same for the river's ribbons
	var _low: Dictionary = {}      # "sea|k" / "river|k" -> ImageTexture at a quarter size (made on demand)
	var _blurred: Dictionary = {}  # "sea|k|sigma" -> ImageTexture

	func _init(w: RefCounted, v: Transform2D, s: Vector2i, r: Rect2) -> void:
		water = w
		view = v
		size = s
		rect_px = r

# Makes the sharp masks (RENDERS: windowed).
func make_masks(water: RefCounted, view: Transform2D, size: Vector2i, rect_px: Rect2) -> FrameMasks:
	var fm := FrameMasks.new(water, view, size, rect_px)
	var canvases: Array = []
	for part in ["sea", "river"]:
		for k in 3:
			canvases.append(_mask_canvas(water, view, size, rect_px, part, k, 4))
	var imgs := InkCanvas.render_all(canvases)
	for q in 3:
		fm.sea.append(ImageTexture.create_from_image(imgs[q]))
		fm.river.append(ImageTexture.create_from_image(imgs[3 + q]))
	return fm

# The mask of step k, of the "sea" (its rings: outer white, holes black, largest first) or the "river" (its ribbons,
# white), on black.
func _mask_canvas(water: RefCounted, view: Transform2D, size: Vector2i, rect_px: Rect2, part: String, k: int, ssaa: int) -> InkCanvas:
	var g := InkCanvas.new(size, ssaa)
	g.fill_color = Color.BLACK
	g.fill_rect(0.0, 0.0, float(size.x), float(size.y))
	g.set_transform_matrix(view)
	var rect_m := Rect2(rect_px.position / ppm, rect_px.size / ppm)
	if part == "sea":
		var rings: Array = water.sea_rings(rect_m, k)
		rings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return absf(a["area"]) > absf(b["area"]))
		for ring: Dictionary in rings:
			g.fill_color = Color.WHITE if float(ring["area"]) > 0.0 else Color.BLACK
			g.begin_path()
			var pts: PackedVector2Array = ring["pts"]
			g.move_to(pts[0].x * ppm, pts[0].y * ppm)
			for i in range(1, pts.size()):
				g.line_to(pts[i].x * ppm, pts[i].y * ppm)
			g.close_path()
			g.fill()
	else:
		g.fill_color = Color.WHITE
		g.begin_path()
		var any := false
		for run: Dictionary in water.river_runs(rect_m, k):
			_ribbon(g, run["c"], run["h"])
			any = true
		if any:
			g.fill()
	return g

# A ribbon as quads and discs (the union is filled once, so a fold in a bend cannot leave a hole).
func _ribbon(g: InkCanvas, c: PackedVector2Array, h: PackedFloat64Array, scale: float = -1.0) -> void:
	var sc := ppm if scale < 0.0 else scale
	var n := c.size()
	var nrm := PackedVector2Array()
	nrm.resize(n)
	for i in n:
		var t := (c[mini(i + 1, n - 1)] - c[maxi(i - 1, 0)]).normalized()
		nrm[i] = Vector2(-t.y, t.x)
	for i in n - 1:
		var a0 := (c[i] + nrm[i] * h[i]) * sc
		var a1 := (c[i + 1] + nrm[i + 1] * h[i + 1]) * sc
		var b1 := (c[i + 1] - nrm[i + 1] * h[i + 1]) * sc
		var b0 := (c[i] - nrm[i] * h[i]) * sc
		g.move_to(a0.x, a0.y)
		g.line_to(a1.x, a1.y)
		g.line_to(b1.x, b1.y)
		g.line_to(b0.x, b0.y)
		g.close_path()
	for i in n:
		if h[i] < 0.5:
			continue
		var r := h[i] * sc
		var p := c[i] * sc
		var seg := 12
		for q in seg:
			var ang := float(q) / float(seg) * TAU
			if q == 0:
				g.move_to(p.x + cos(ang) * r, p.y + sin(ang) * r)
			else:
				g.line_to(p.x + cos(ang) * r, p.y + sin(ang) * r)
		g.close_path()

# The mask of step k of the "sea" or the "river" blurred by `sigma_m` metres, at a quarter size (a texture to sample with
# a linear filter).
func blurred(fm: FrameMasks, part: String, k: int, sigma_m: float) -> ImageTexture:
	var key := "%s|%d|%s" % [part, k, str(sigma_m)]
	if fm._blurred.has(key):
		return fm._blurred[key]
	var scale := 4.0
	var lsize := Vector2i(ceili(fm.size.x / scale), ceili(fm.size.y / scale))
	var lview := Transform2D(fm.view.x / scale, fm.view.y / scale, fm.view.origin / scale)
	var lk := "%s|%d" % [part, k]
	if not fm._low.has(lk):
		fm._low[lk] = _mask_canvas(fm.water, lview, lsize, fm.rect_px, part, k, 4).finish_texture()
	var sigma_px := maxf(sigma_m * ppm * fm.view.get_scale().x / scale, 0.5)
	var t1 := _blur_pass(fm._low[lk], lsize, Vector2(1.0, 0.0), sigma_px)
	var t2 := _blur_pass(t1, lsize, Vector2(0.0, 1.0), sigma_px)
	fm._blurred[key] = t2
	return t2

func _blur_pass(tex: Texture2D, size: Vector2i, dir: Vector2, sigma_px: float) -> ImageTexture:
	if _blur_shader == null:
		_blur_shader = Shader.new()
		_blur_shader.code = _BLUR_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = _blur_shader
	mat.set_shader_parameter("dir", dir)
	mat.set_shader_parameter("sigma", sigma_px)
	var g := InkCanvas.new(size, 1)
	g.draw_image_with_material(tex, 0.0, 0.0, float(size.x), float(size.y), mat)
	return g.finish_texture()

# --- the wash and the halo ---------------------------------------------------------------------------------------

func _wash_material() -> ShaderMaterial:
	if _wash_mat == null:
		var sh := Shader.new()
		sh.code = _WASH_SHADER
		_wash_mat = ShaderMaterial.new()
		_wash_mat.shader = sh
	return _wash_mat

# The blue wash onto `g` (frame space), under the option's mode: stepped (the three sharp masks, the shore
# softened when the option says so) or smooth (the masks blurred by data draw.soft.gradient_blur_m).
func draw_wash(g: InkCanvas, opt: Dictionary, fm: FrameMasks, up_mask: Texture2D, paper: Texture2D) -> void:
	var sea: Array = fm.sea.duplicate()
	var river: Array = fm.river.duplicate()
	if str(opt.get("mode", "stepped")) == "smooth":
		for k in 3:
			sea[k] = blurred(fm, "sea", k, gradient_blur_m[k])
			river[k] = blurred(fm, "river", k, river_blur_m)
	elif bool(opt.get("soft", false)):
		sea[0] = blurred(fm, "sea", 0, soft_blur_m)
		river[0] = blurred(fm, "river", 0, river_blur_m)
	var mat := ShaderMaterial.new()
	mat.shader = _wash_material().shader
	for k in 3:
		mat.set_shader_parameter("s%d" % k, sea[k])
		mat.set_shader_parameter("r%d" % k, river[k])
	mat.set_shader_parameter("up", up_mask)
	mat.set_shader_parameter("paper", paper)
	mat.set_shader_parameter("c0", _v3(steps[0]))
	mat.set_shader_parameter("c1", _v3(steps[1]))
	mat.set_shader_parameter("c2", _v3(steps[2]))
	mat.set_shader_parameter("paper_ref", _v3(P.PAPER))
	mat.set_shader_parameter("alpha", wash_alpha)
	mat.set_shader_parameter("mottle", mottle)
	g.save()
	g.reset_transform()
	g.global_alpha = 1.0
	g.draw_image_with_material(fm.sea[0], 0.0, 0.0, float(fm.size.x), float(fm.size.y), mat)
	g.restore()

# The pale band on the land (options C and E), before the wash.
func draw_halo(g: InkCanvas, opt: Dictionary, fm: FrameMasks, up_mask: Texture2D) -> void:
	if not bool(opt.get("halo", false)):
		return
	var sh := Shader.new()
	sh.code = _HALO_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("wide_s", blurred(fm, "sea", 0, halo_m))
	mat.set_shader_parameter("wide_r", blurred(fm, "river", 0, river_halo_m))
	mat.set_shader_parameter("near_s", blurred(fm, "sea", 0, soft_blur_m))
	mat.set_shader_parameter("near_r", blurred(fm, "river", 0, river_blur_m))
	mat.set_shader_parameter("up", up_mask)
	mat.set_shader_parameter("pale", _v3(halo_color))
	mat.set_shader_parameter("alpha", halo_alpha)
	g.save()
	g.reset_transform()
	g.global_alpha = 1.0
	g.draw_image_with_material(fm.sea[0], 0.0, 0.0, float(fm.size.x), float(fm.size.y), mat)
	g.restore()

static func _v3(c: Color) -> Vector3:
	return Vector3(c.r, c.g, c.b)

# --- ink on the water ---------------------------------------------------------------------------------------------------

# The lines of the option: ink at each depth step and the shore (A), the shore alone (B), ripples along the shore (D),
# pale step edges (F). `g` is under no transform (this sets the view). Lines are the water's own ground marks: they
# go under the terrain's contours and under every shadow.
func draw_lines(g: InkCanvas, opt: Dictionary, water: RefCounted, view: Transform2D, rect_px: Rect2) -> void:
	var rect_m := Rect2(rect_px.position / ppm, rect_px.size / ppm)
	var ter: Variant = water.terrain()
	var ns := int(water.seed_value) % 9973 + 977
	g.save()
	g.set_transform_matrix(view)
	g.line_cap = "round"
	if bool(opt.get("shore_line", false)) or bool(opt.get("step_lines", false)):
		var top := 3 if bool(opt.get("step_lines", false)) else 1
		for k in top:
			var lines := _step_lines(water, ter, rect_m, k)
			g.stroke_color = P.INK
			g.line_width = P.lw * (ink_weight if k == 0 else step_weight)
			g.global_alpha = ink_alpha if k == 0 else step_alphas[k]
			_stroke_lines(g, lines, ns + k * 31, 0.0, 0.0, 0.0)
	if bool(opt.get("pale_edges", false)):
		for k in range(1, 3):
			var lines := _step_lines(water, ter, rect_m, k)
			g.stroke_color = oklch_color(paper_lab.x - _l_below[k - 1] + pale_lift, _chroma[k - 1], hue_deg)
			g.line_width = maxf(pale_width / maxf(view.get_scale().x, 0.01), 0.6)
			g.global_alpha = pale_alpha
			_stroke_lines(g, lines, ns + k * 31, 0.0, 0.0, 0.0)
	if bool(opt.get("ripples", false)):
		for r in 3:
			var lines := _ripple_lines(water, ter, rect_m, ripple_offsets[r])
			g.stroke_color = P.INK
			g.line_width = P.lw * ripple_weight
			g.global_alpha = ripple_alphas[r]
			_stroke_lines(g, lines, ns + 400 + r * 17, ripple_break_f, ripple_break_thr[r], 0.0)
	g.global_alpha = 1.0
	g.restore()

# The polylines (world px, with a `skip` mask applied: broken where the line is under an upland or inside the other
# water) of step k's boundary: the sea's rings and the river's banks.
func _step_lines(water: RefCounted, ter: Variant, rect_m: Rect2, k: int) -> Array:
	var thr: float = water.step_from[k]
	var out: Array = []
	for ring: Dictionary in water.sea_rings(rect_m, k):
		var pts: PackedVector2Array = ring["pts"]
		out.append(_pieces(pts, true, func(p: Vector2) -> bool: return _keep(water, ter, p, thr, true)))
	for edge: Dictionary in water.river_edges(rect_m, k):
		for side: String in ["l", "r"]:
			var pts: PackedVector2Array = edge[side]
			out.append(_pieces(pts, false, func(p: Vector2) -> bool: return _keep(water, ter, p, thr, false)))
	var flat: Array = []
	for pieces: Array in out:
		flat.append_array(pieces)
	return flat

# Whether the water's line at `p` (metres) is seen: not under an upland and not inside the other body of water.
func _keep(water: RefCounted, ter: Variant, p: Vector2, thr: float, is_sea: bool) -> bool:
	if int(ter.level_at(p.x, p.y)) != 0:
		return false
	if is_sea:
		return water.river_s(p.x, p.y) <= thr + 0.4
	return water.sea_s(p.x, p.y) <= thr + 0.4

# Cuts a polyline into the runs where `keep` holds; each run is {pts: PackedVector2Array (world px), closed: bool}.
func _pieces(pts: PackedVector2Array, closed: bool, keep: Callable, scale: float = -1.0) -> Array:
	var sc := ppm if scale < 0.0 else scale
	var out: Array = []
	var n := pts.size()
	if n < 2:
		return out
	var flags := PackedByteArray()
	flags.resize(n)
	var all := true
	for i in n:
		flags[i] = 1 if keep.call(pts[i]) else 0
		if flags[i] == 0:
			all = false
	if all:
		var px := PackedVector2Array()
		for p in pts:
			px.append(p * sc)
		out.append({"pts": px, "closed": closed})
		return out
	# start at a dropped vertex so a closed ring's run is not split by the seam
	var start := 0
	for i in n:
		if flags[i] == 0:
			start = i
			break
	var cur := PackedVector2Array()
	var lim := n if closed else n
	for q in range(1, lim + 1):
		var i := (start + q) % n
		if not closed and start + q >= n:
			break
		if flags[i] == 1:
			cur.append(pts[i] * sc)
		elif cur.size() >= 2:
			out.append({"pts": cur, "closed": false})
			cur = PackedVector2Array()
		else:
			cur = PackedVector2Array()
	if cur.size() >= 2:
		out.append({"pts": cur, "closed": false})
	if not closed and start > 0:
		# the open line's stretch before the first dropped vertex
		var head := PackedVector2Array()
		for i in start:
			if flags[i] == 1:
				head.append(pts[i] * sc)
			elif head.size() >= 2:
				out.append({"pts": head, "closed": false})
				head = PackedVector2Array()
			else:
				head = PackedVector2Array()
		if head.size() >= 2:
			out.append({"pts": head, "closed": false})
	return out

# The shore's lines `offset_m` into the water (D): the sea's outer rings and holes and the river's banks, kept where
# that point is water and not under an upland.
func _ripple_lines(water: RefCounted, ter: Variant, rect_m: Rect2, offset_m: float) -> Array:
	var out: Array = []
	for ring: Dictionary in water.sea_rings(rect_m, 0):
		var pts: PackedVector2Array = ring["pts"]
		var n := pts.size()
		if n < 4:
			continue
		var moved := PackedVector2Array()
		moved.resize(n)
		for i in n:
			var t := (pts[(i + 1) % n] - pts[(i - 1 + n) % n]).normalized()
			moved[i] = pts[i] + Vector2(-t.y, t.x) * offset_m     # the water is on the right (y down)
		out.append_array(_pieces(moved, true, func(p: Vector2) -> bool: return _wet_seen(water, ter, p, offset_m)))
	for edge: Dictionary in water.river_edges(rect_m, 0):
		var run_c: PackedVector2Array = edge["l"]
		var run_r: PackedVector2Array = edge["r"]
		for side in 2:
			var bank: PackedVector2Array = run_c if side == 0 else run_r
			var other: PackedVector2Array = run_r if side == 0 else run_c
			var n := bank.size()
			var moved := PackedVector2Array()
			moved.resize(n)
			for i in n:
				var inward := (other[i] - bank[i])
				var w := inward.length()
				# a ripple that would cross the middle of a narrow river is not drawn
				moved[i] = bank[i] + inward.normalized() * minf(offset_m, w * 0.42) if w > 0.5 else bank[i]
			out.append_array(_pieces(moved, false, func(p: Vector2) -> bool: return _wet_seen(water, ter, p, offset_m)))
	return out

func _wet_seen(water: RefCounted, ter: Variant, p: Vector2, _offset_m: float) -> bool:
	return water.s_at(p.x, p.y) > 0.2 and int(ter.level_at(p.x, p.y)) == 0

# Strokes the pieces: each is wobbled along its normal like the terrain's contours and, when `break_f` > 0, broken
# where noise falls under `break_thr` (the pen lifts: dashes).
func _stroke_lines(g: InkCanvas, pieces: Array, ns: int, break_f: float, break_thr: float, _unused: float) -> void:
	g.begin_path()
	var any := false
	for piece: Dictionary in pieces:
		var pts: PackedVector2Array = piece["pts"]
		var n := pts.size()
		if n < 2:
			continue
		var closed: bool = piece["closed"]
		var lim := n + 1 if closed else n
		var pen := false
		for q in lim:
			var i := q % n
			var p := pts[i]
			if break_f > 0.0 and ValueNoise.vnoise(p.x * break_f, p.y * break_f, ns + 613) < break_thr:
				pen = false
				continue
			var a := pts[maxi(i - 1, 0)] if not closed else pts[(i - 1 + n) % n]
			var b := pts[mini(i + 1, n - 1)] if not closed else pts[(i + 1) % n]
			var t := (b - a).normalized()
			var nr := Vector2(-t.y, t.x)
			var w := (ValueNoise.vnoise(p.x * line_wobble_f, p.y * line_wobble_f, ns + 501) - 0.5) * 2.6 * (0.35 + P.wob) * line_wobble
			var o := p + nr * w
			if pen:
				g.line_to(o.x, o.y)
			else:
				g.move_to(o.x, o.y)
				pen = true
				any = true
	if any:
		g.stroke()

# --- the live map's chunks (Track WB, 2026-10-10) ------------------------------------------------------------------------
#
# THE WATER IN THE CHUNK PIPELINE (scripts/render/chunk_terrain_provider.gd; look A, Alex's choice). A chunk's water is made in
# three steps, split across the baker's stages by what each may touch:
#
#   chunk_geometry(water, rect_px, scale)   WORKER, no engine state: the sea's rings for every step and the river's runs over the
#                                           chunk, in metres ({} for a chunk with no water at all)
#   chunk_masks(geo, view, size)            WORKER: two InkCanvases to render, the sea's and the river's mask (grey levels 1/3,
#                                           2/3, 1 for the three steps, nested; shaders/water_wash.gdshader decodes them)
#   draw_chunk_wash(g, sea, river, up, ..)  MAIN (it makes a material): the wash onto the chunk's ground canvas, under the
#                                           terrain's level fill
#   draw_chunk_lines(g, ter, water, geo, ..) WORKER, with the terrain's lock held (it asks the bundle's terrain what is an
#                                           upland): the ink at each step -- the shore, the shelf's edge, the deep's edge
#
# Lines are never cut at the chunk, only dropped when they lie wholly outside it (draw.chunk.clip_px), so a ring keeps its pen,
# its closed or open weight and its wobble (a function of the world position) whichever chunk draws it, and two chunks draw
# the same line to the pixel on either side of their border.

# The level of a mask's grey ramp: nominal 8-bit value k/3 (85, 170, 255), painted a quarter step over so that a store that
# truncates and one that rounds read back the same integer (the GPU's does not round to nearest: CLAUDE.md).
static func _grey(level: int) -> Color:
	var v := minf((roundf(255.0 * float(level) / 3.0) + 0.25) / 255.0, 1.0)
	return Color(v, v, v)

func chunk_geometry(water: RefCounted, rect_px: Rect2, scale: float) -> Dictionary:
	var rect_m := Rect2(rect_px.position / scale, rect_px.size / scale)
	var rings: Array = water.sea_rings_all(rect_m)
	var runs: Array = []
	var any := false
	for k in 3:
		var r: Array = water.river_runs(rect_m, k)
		runs.append(r)
		any = any or not r.is_empty() or not (rings[k] as Array).is_empty()
	if not any:
		return {}
	return {"rings": rings, "runs": runs, "scale": scale}

func _black(size: Vector2i, ssaa: int) -> InkCanvas:
	var g := InkCanvas.new(size, ssaa)
	g.fill_color = Color.BLACK
	g.fill_rect(0.0, 0.0, float(size.x), float(size.y))
	return g

# [the sea's mask canvas, the river's], black where dry; unrendered.
func chunk_masks(geo: Dictionary, view: Transform2D, size: Vector2i) -> Array:
	var scale: float = geo["scale"]
	var all: Array = []
	for k in 3:
		for ring: Dictionary in geo["rings"][k]:
			all.append({"pts": ring["pts"], "area": ring["area"], "k": k})
	var sea: InkCanvas
	if all.is_empty():
		sea = _black(size, 1)
	else:
		sea = _black(size, mask_ssaa)
		sea.set_transform_matrix(view)
		# largest first: a ring is painted in the level of the water INSIDE it (an outer ring of step k: k + 1; a hole in step k's
		# region holds what step k - 1 holds there, and a smaller ring, painted later, refines it)
		all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return absf(a["area"]) > absf(b["area"]))
		for ring: Dictionary in all:
			sea.fill_color = _grey(int(ring["k"]) + (1 if float(ring["area"]) > 0.0 else 0))
			sea.begin_path()
			var pts: PackedVector2Array = ring["pts"]
			sea.move_to(pts[0].x * scale, pts[0].y * scale)
			for i in range(1, pts.size()):
				sea.line_to(pts[i].x * scale, pts[i].y * scale)
			sea.close_path()
			sea.fill()
	var has_river := false
	for k in 3:
		has_river = has_river or not (geo["runs"][k] as Array).is_empty()
	var river: InkCanvas
	if not has_river:
		river = _black(size, 1)
	else:
		river = _black(size, mask_ssaa)
		river.set_transform_matrix(view)
		for k in 3:     # the ribbons nest (a deeper step is the narrower), so the deeper is painted over
			var runs: Array = geo["runs"][k]
			if runs.is_empty():
				continue
			river.fill_color = _grey(k + 1)
			river.begin_path()
			for run: Dictionary in runs:
				_ribbon(river, run["c"], run["h"], scale)
			river.fill()
	return [sea, river]

# The wash onto `g` (the chunk's ground canvas): the three step colours by the masks, the paper's mottle kept, the uplands
# (`up`: the terrain's level-1 mask) left out.
func draw_chunk_wash(g: InkCanvas, sea: Texture2D, river: Texture2D, up: Texture2D, rect_px: Rect2, size: Vector2i) -> void:
	var mat := ShaderMaterial.new()
	mat.shader = WASH_SHADER
	mat.set_shader_parameter("sea", sea)
	mat.set_shader_parameter("river", river)
	mat.set_shader_parameter("up", up)
	for k in 3:
		mat.set_shader_parameter("c%d" % k, _v3(steps[k]))
	mat.set_shader_parameter("paper", Vector3(P.PAPER.r8, P.PAPER.g8, P.PAPER.b8))
	mat.set_shader_parameter("origin", rect_px.position)
	mat.set_shader_parameter("extent", rect_px.size)
	mat.set_shader_parameter("alpha", wash_alpha)
	mat.set_shader_parameter("mottle", mottle)
	g.save()
	g.reset_transform()
	g.global_alpha = 1.0
	g.draw_image_with_material(sea, 0.0, 0.0, float(size.x), float(size.y), mat)
	g.restore()

# The ink at each step of look A (the working default's shore_line and step_lines switches) onto `g` under `view`. `ter` is
# the chunk's bundle terrain and its lock must be held by the caller (level_at fills its caches).
func draw_chunk_lines(g: InkCanvas, ter: Variant, water: RefCounted, geo: Dictionary, view: Transform2D, rect_px: Rect2) -> void:
	var opt: Dictionary = options.get(working_default, {})
	if not (bool(opt.get("shore_line", false)) or bool(opt.get("step_lines", false))):
		return
	var scale: float = geo["scale"]
	var ns := int(water.seed_value) % 9973 + 977
	var near := rect_px.grow(clip_px)
	g.save()
	g.set_transform_matrix(view)
	g.line_cap = "round"
	var top := 3 if bool(opt.get("step_lines", false)) else 1
	for k in top:
		var lines := chunk_step_lines(water, ter, geo, k, scale, near)
		if lines.is_empty():
			continue
		g.stroke_color = P.INK
		g.line_width = P.lw * (ink_weight if k == 0 else step_weight)
		g.global_alpha = ink_alpha if k == 0 else step_alphas[k]
		_stroke_lines(g, lines, ns + k * 31, 0.0, 0.0, 0.0)
	g.global_alpha = 1.0
	g.restore()

# step k's lines of a chunk's geometry as _step_lines makes them (world px, cut where under an upland or inside the other
# water), the pieces wholly outside `near` (world px) left out.
#
# A RING is looked at every SAMPLE_STRIDE-th vertex first (8 m): a ring none of whose samples is cut -- the common case, and
# every ring deeper than the cap's reach (water.ring_may_meet_upland) can only be cut by the river -- is one closed line, made
# by one transform, and not asked about at every metre. A ring with a cut sample goes through _pieces vertex by vertex (what
# the board did). An upland sliver or a river mouth narrower than the stride can be missed: the line then runs over it.
const SAMPLE_STRIDE := 8

func chunk_step_lines(water: RefCounted, ter: Variant, geo: Dictionary, k: int, scale: float, near: Rect2) -> Array:
	var thr: float = water.step_from[k]
	var upland: bool = water.ring_may_meet_upland(k)
	var xf := Transform2D(Vector2(scale, 0.0), Vector2(0.0, scale), Vector2.ZERO)
	var out: Array = []
	for ring: Dictionary in geo["rings"][k]:
		var pts: PackedVector2Array = ring["pts"]
		var n := pts.size()
		if n < 3:
			continue
		var near_hit := false
		var cut := false
		for i in range(0, n, SAMPLE_STRIDE):
			var p := pts[i]
			if not near_hit and near.has_point(p * scale):
				near_hit = true
			if not cut:
				if upland:
					cut = not _keep(water, ter, p, thr, true)
				else:
					cut = water.river_s(p.x, p.y) > thr + 0.4
		if not near_hit:
			continue
		if not cut:
			out.append({"pts": xf * pts, "closed": true})
		elif upland:
			out.append_array(_touching(_pieces(pts, true, func(p: Vector2) -> bool: return _keep(water, ter, p, thr, true), scale), near))
		else:
			out.append_array(_touching(_pieces(pts, true, func(p: Vector2) -> bool: return water.river_s(p.x, p.y) <= thr + 0.4, scale), near))
	var runs: Array = geo["runs"][k]
	if not runs.is_empty():
		for edge: Dictionary in water.edges_of_runs(runs):
			for side: String in ["l", "r"]:
				var pts: PackedVector2Array = edge[side]
				out.append_array(_touching(_pieces(pts, false, func(p: Vector2) -> bool: return _keep(water, ter, p, thr, false), scale), near))
	return out

# The pieces that come within `near` (world px): a sample of each, every SAMPLE_STRIDE-th point.
func _touching(pieces: Array, near: Rect2) -> Array:
	var out: Array = []
	for piece: Dictionary in pieces:
		var pp: PackedVector2Array = piece["pts"]
		var hit := false
		for i in range(0, pp.size(), SAMPLE_STRIDE):
			if near.has_point(pp[i]):
				hit = true
				break
		if not hit and pp.size() > 0 and near.has_point(pp[pp.size() - 1]):
			hit = true
		if hit:
			out.append(piece)
	return out
