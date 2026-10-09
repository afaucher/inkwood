extends RefCounted

# A Canvas-2D-like drawing surface covering EXACTLY the subset of the HTML
# Canvas API the prototype draws with (reference/inkwood-renderer.html), so its
# routines -- drawLobe, buildTreeSprite, buildPropSprite, drawWall, drawHouse,
# drawRoad, buildGround, castShadows, render -- port line for line:
#
#   g.beginPath()  g.moveTo  g.lineTo  g.closePath  g.arc  g.rect
#   g.fill()  g.stroke()  g.fillRect  g.drawImage(img, x, y, w, h)
#   g.drawImage(img, sx, sy, sw, sh, x, y, w, h)          (draw_image_region)
#   g.lineWidth  g.lineCap  g.strokeStyle  g.fillStyle  g.globalAlpha
#   g.save  g.restore  g.translate  g.rotate  g.scale  g.setTransform
#
# plus fill_band(), the strip between two wall edges (the prototype's
# even-odd wall outline), and draw_image_with_material() for the two compositing
# passes Canvas does with globalCompositeOperation (shadow_pass.gd, grain.gd).
#
# Usage, mirroring the prototype's offscreen canvas per object:
#
#   var tex := InkCanvas.render_to_texture(Vector2i(size, size), func(g) -> void:
#       g.set_transform(1, 0, 0, 1, half, half)
#       g.begin_path(); g.arc(0, 0, 5, 0, TAU); g.fill_color = cream; g.fill(); g.stroke())
#
# or hold one:  var g = InkCanvas.new(size)  ...  var img := g.finish_image()
# and render many in ONE engine frame with InkCanvas.render_all([g1, g2, ...]),
# or without forcing a frame: InkCanvas.submit([...]) now, then collect_image()
# on each once the engine has drawn a frame (RenderingServer.frame_post_draw).
#
# --- HOW IT DRAWS ------------------------------------------------------------
#
# GEOMETRY IS TESSELLATED HERE, IN GDSCRIPT, into device-space triangles. Each
# fill / stroke / drawImage is RECORDED as plain data; nothing touches the
# RenderingServer until the canvas is rendered (render_all / submit). So a
# canvas can be recorded on a worker thread (WorkerThreadPool) and rendered on
# the main thread -- the map view's chunk baker does exactly that. At render
# time each recorded call becomes canvas items on a private viewport. No nodes,
# no scene tree, no _draw(). The same calls make the same triangles, and the
# same triangles rasterize to the same pixels -- deterministic.
#
# BATCHED SUBMISSION: consecutive paint calls that composite directly (opaque
# or unable to overlap themselves: fillRect, a dot, an opaque fill) are merged
# into ONE canvas item with per-vertex colours, and consecutive drawImage calls
# of one texture (an atlas page of sprites) into one item of textured
# triangles. Triangles within one item are blended in submission order exactly
# as separate items are, so the pixels do not change; a ground with 20,000
# specks, or a chunk with 400 trees, costs one item instead of thousands.
# An AtlasTexture draws as its region of its atlas.
#
# ANTIALIASING IS SUPERSAMPLING: the viewport is SSAA x the canvas size, the
# triangles rasterize aliased at that size, and a second viewport box-filters
# every SSAA x SSAA block into one pixel. At 4 that is 16 coverage levels, the
# same count as Skia's CPU supersampler, and it is plain area coverage, which is
# what every Skia path renderer approximates. Not MSAA: canvas groups (next
# paragraph) render into the backbuffer, which is never multisampled.
#
# COVERAGE ONCE PER PAINT CALL. Canvas rasterizes a whole fill or stroke into
# ONE coverage mask and composites it once, so a semi-transparent stroke never
# darkens where its own pieces overlap (round joins, a closed ring's seam, two
# subpaths crossing). These triangles DO overlap, so a paint call that is both
# translucent and able to overlap itself is drawn inside a canvas group
# (CANVAS_GROUP_MODE_TRANSPARENT): its pieces go opaque into the backbuffer,
# where overlaps merge, and the group composites once at the call's alpha.
# Measured: two overlapping 50% quads read back 0.498 in a group and 0.749
# without. Opaque calls are drawn directly -- opaque overlaps are already a union.
#
# HAIRLINES. Skia -- Chrome's canvas, CPU (SkDrawTreatAsHairline) and GPU
# (GrIsStrokeHairlineOrEquivalent) alike -- strokes any antialiased line whose
# DEVICE width is <= 1 px as a 1 px hairline with its alpha multiplied by the
# width. At the prototype's default line weight (0.8) the largest multiplier is
# 1.25, so EVERY ink line in the default scene is a hairline: thin lines are a
# full pixel wide and lighter, not thinner. Reproduced: width 1, alpha x width.
# The GPU flavour is modelled (coverage across the line's normal); Skia's CPU
# hairline measures coverage along the minor axis instead, which makes 45-degree
# lines about 30% lighter than horizontal ones. Which one a given browser uses
# depends on whether it accelerates that canvas.
#
# THE PEN (data/params/render_defaults.json linework.pen; Alex 2026-10-09,
# decision pen-line, option C "shadow side"). Every INK stroke goes through it
# without the caller asking: a stroke whose colour is the palette's ink and
# whose path has no arc() or rect() in it is drawn as a filled RIBBON whose
# width varies along it, instead of an even line:
#   closed subpath   width factor lit + (shadow - lit) x max(0, n . s): n the
#                    outward normal (from the sign of the subpath's signed
#                    area), s the shadow direction -- heavy on the edges that
#                    face away from the sun, thin on the lit side;
#   open subpath     open_line_factor, and both ends taper with smoothstep over
#                    min(end_taper_px, end_taper_max_fraction x length) down to
#                    end_floor of the width. A run between two breaks is its own
#                    subpath, so it tapers too. Closed loops have no ends.
# Width = lineWidth x factor (lineWidth already carries line weight x element
# multiplier). The reference is ribbon() in reference/mockups/unit_sheet.html
# ("THE PEN LINE"); one difference, deliberate: the ribbon is built in DEVICE
# space, so the shadow side is the WORLD's (a canvas is assumed world-aligned --
# sprites are drawn unrotated into the world, so a rotated prop's outline is
# still heavy on its true shadow side). Where the ribbon is thinner than one
# device pixel it is the hairline rule again: one pixel wide, alpha x width.
# Its pieces are merged in a canvas group (each subsample keeps the ribbon's
# own alpha; overlaps at sharp turns never darken). Shadow masks (black), the
# wall slope tone and other tints are not ink and are untouched; so are arcs
# (barrels, pebbles, stipple) and rects (crates), as in the reference.
#   Mode "even" is the prototype's line (pen_mode "even"; --parity selects it
#   through linework.pen.prototype_default). The config is read once from data;
#   InkCanvas.configure_pen(P) follows a RenderParams (sun azimuth, ink) and
#   set_pen_mode(mode) switches it for every canvas recorded afterwards.
#
# PREMULTIPLIED ALPHA. A transparent viewport accumulates premultiplied colour
# under Godot's MIX blend (measured: 50% green over transparent reads back
# (0, .5, 0, .5)), which is also how Canvas stores pixels, so render_to_texture
# returns PREMULTIPLIED textures and draw_image composites with
# blend_premul_alpha. An opaque texture (the ground, the grain) is the same
# either way; a straight-alpha texture with partial alpha must go through
# Image.premultiply_alpha() before it is drawn here.
#
# IMAGES UNDER SUPERSAMPLING are sampled NEAREST at the supersampled size, so
# the box filter gives back an exact copy at an integer offset and linear
# interpolation (quantised to 1/SSAA px) at a fractional one -- what Canvas's
# smoothed drawImage does with an unscaled sprite. A draw that MAGNIFIES (the
# canopy shadow's stretch, an upscale) samples LINEAR. At ssaa 1, LINEAR always.
#
# WHAT IS NOT CANVAS, deliberately:
#   - fill() fills the UNION of the subpaths. That is the nonzero rule whenever
#     subpaths do not overlap or wind the same way, which covers every fill in
#     the prototype (scallops, rocks and hulls are simple polygons). The wall's
#     even-odd outline goes through fill_band() instead.
#   - lineJoin is always round; lineCap is "round" (default) or "butt" -- the
#     prototype uses nothing else (drawWall's slope tone is its one butt cap).
#   - A stroke under a NON-UNIFORM scale uses the mean scale for its width; the
#     prototype only stretches images (castShadows), never strokes.
#   - No globalCompositeOperation: "source-in" + globalAlpha is shadow_pass.gd,
#     "multiply" is grain.gd, both as shaders on draw_image_with_material().
#   - Device pixel ratio is 1 throughout (the capture page forces the browser to
#     1 as well -- reference/port_check/make_capture_page.js).

const SSAA_DEFAULT := 4
# Largest gap, in device px, between a true arc and the chords drawn for it.
const ARC_TOLERANCE := 0.02
# The engine's texture size limit; the supersample factor drops to fit it.
const MAX_TARGET_PX := 16384

const _SELF_PATH := "res://scripts/render/ink_canvas.gd"
const PARAMS_PATH := "res://data/params/render_defaults.json"

# Textures from render_to_texture() are premultiplied; composite them as such.
# COLOR arrives as texture x vertex colour, and the vertex colour is
# (a, a, a, a) so globalAlpha scales a premultiplied texel correctly.
const _PREMUL_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
"""

# The pen ribbon's body inside its canvas group: each fragment REPLACES what is
# under it (premultiplied, as the group's backbuffer holds), so where a
# ribbon's own triangles overlap the subsample keeps the ribbon's alpha
# instead of compounding it -- the union a Canvas nonzero fill gives.
const _RIBBON_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_disabled;
void fragment() {
	COLOR = vec4(COLOR.rgb * COLOR.a, COLOR.a);
}
"""

# The SSAA resolve: average each F x F block of the supersampled target. Both
# sides are premultiplied, so a plain average is the correct area filter.
# Rounded to the nearest 8-bit step HERE because the GPU's own float-to-8-bit
# store does not round to nearest (shaders/paper_tint.gdshader has the
# measurement); an exact k/255 stores exactly.
const _BOX_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_disabled;
const int F = %d;
void fragment() {
	ivec2 lo = textureSize(TEXTURE, 0) / F;
	ivec2 px = ivec2(floor(UV * vec2(lo)));
	vec4 acc = vec4(0.0);
	for (int j = 0; j < F; j++) {
		for (int i = 0; i < F; i++) {
			acc += texelFetch(TEXTURE, px * F + ivec2(i, j), 0);
		}
	}
	COLOR = floor(acc / float(F * F) * 255.0 + 0.5) / 255.0;
}
"""

# Recorded operations.
enum { _OP_TRIS, _OP_IMAGES }

# --- Canvas state (the subset the prototype sets) ------------------------------

# Canvas ignores a lineWidth that is <= 0, NaN or infinite; so does this.
var line_width: float = 1.0:
	set(value):
		if value > 0.0 and is_finite(value):
			line_width = value
# "round" or "butt". Joins are always round.
var line_cap: String = "round"
var stroke_color: Color = Color.BLACK
var fill_color: Color = Color.BLACK
# Canvas ignores a globalAlpha outside [0, 1]; so does this.
var global_alpha: float = 1.0:
	set(value):
		if value >= 0.0 and value <= 1.0:
			global_alpha = value

var size: Vector2i
var ssaa: int

var _xf: Transform2D = Transform2D.IDENTITY
var _stack: Array[Dictionary] = []

# The path, in DEVICE space: Canvas transforms each point by the matrix current
# when the point is added, so a later transform change does not move it.
var _paths: Array[PackedVector2Array] = []
var _closed: Array[bool] = []
var _cur := PackedVector2Array()
var _cur_closed := false
# The current path has an arc() or rect() in it (the pen leaves such strokes even).
var _path_odd := false

# The recording: [_OP_TRIS, tris, colors, group_alpha (< 0: direct), ribbon]
# or [_OP_IMAGES, texture, material (Material or a built-in key String),
# nearest, points, uvs, colors] -- textured quads in DEVICE space, two
# triangles each; consecutive image draws with the same texture, material
# and filter extend the same op (one canvas item). Direct triangle paints are
# merged into _batch_tris / _batch_cols until something else is recorded.
var _ops: Array = []
var _batch_tris := PackedVector2Array()
var _batch_cols := PackedColorArray()

var _vp_hi: RID
var _vp_lo: RID
var _canvas_hi: RID
var _canvas_lo: RID
var _items: Array[RID] = []
var _keep: Array = []  # textures and materials the items point at, alive until drawn
var _next_index := 0
var _active := false
var _done := false

static var _materials: Dictionary = {}
static var _pen: Dictionary = {}
static var _pen_mutex := Mutex.new()

func _init(canvas_size: Vector2i, supersample: int = SSAA_DEFAULT) -> void:
	size = Vector2i(maxi(1, canvas_size.x), maxi(1, canvas_size.y))
	ssaa = maxi(1, supersample)
	while ssaa > 1 and maxi(size.x, size.y) * ssaa > MAX_TARGET_PX:
		ssaa -= 1

# A canvas dropped without being rendered gives its RenderingServer objects
# back here (if it ever made any: recording makes none). Inline rather than a
# call to _free(): during PREDELETE a RefCounted's own methods can no longer be
# called (observed 2026-10-09: "Attempt to call function '_free' in base 'null
# instance'", and the RIDs leaked), while its members can still be read.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _done:
		_done = true
		for i in range(_items.size() - 1, -1, -1):
			RenderingServer.free_rid(_items[i])
		for rid: RID in [_canvas_hi, _canvas_lo, _vp_hi, _vp_lo]:
			if rid.is_valid():
				RenderingServer.free_rid(rid)

# --- Rendering ---------------------------------------------------------------

# Draws every canvas in ONE engine frame and returns their images, in order.
# Each canvas is spent afterwards. Images are RGBA8, premultiplied alpha.
# MAIN THREAD ONLY (it creates the RenderingServer objects and forces a frame).
static func render_all(canvases: Array) -> Array[Image]:
	for c in canvases:
		c._activate()
	RenderingServer.force_draw(false)
	var out: Array[Image] = []
	for c in canvases:
		out.append(c._collect())
	return out

# The asynchronous form of render_all, for a caller that must not force a
# frame (the map view, mid-game): submit() creates the canvases' viewports now
# and the engine draws them with its next frame; after that frame
# (RenderingServer.frame_post_draw) collect_image() on each reads it back and
# spends it. Main thread only.
static func submit(canvases: Array) -> void:
	for c in canvases:
		c._activate()

func collect_image() -> Image:
	assert(_active and not _done, "InkCanvas.collect_image: submit() it first, and collect once")
	return _collect()

# Reads a submitted canvas back WITHOUT STALLING: call after the frame that
# drew it; `callback` receives the Image (RGBA8, premultiplied) a frame or two
# later, on the main thread, and the canvas is spent. collect_image() and
# render_all() read back synchronously, which waits for every frame the GPU
# has in flight -- measured 2026-10-09: 100-300 ms of main thread per read-back
# while chunks bake, against ~0 for this. Falls back to the synchronous read
# where there is no RenderingDevice (the Compatibility renderer).
func collect_async(callback: Callable) -> void:
	assert(_active and not _done, "InkCanvas.collect_async: submit() it first, and collect once")
	var vp := _vp_lo if _vp_lo.is_valid() else _vp_hi
	var rd := RenderingServer.get_rendering_device()
	var rd_tex := RenderingServer.texture_get_rd_texture(RenderingServer.viewport_get_texture(vp)) if rd != null else RID()
	if rd == null or not rd_tex.is_valid() or rd.texture_get_format(rd_tex).format != RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM:
		callback.call(_collect())
		return
	var w := size.x
	var h := size.y
	var me := self  # alive until the pixels arrive
	rd.texture_get_data_async(rd_tex, 0, func(data: PackedByteArray) -> void:
		me._free()
		callback.call(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, data)))

# The prototype's offscreen canvas: a fresh canvas of `canvas_size`, handed to
# `draw` (which receives this canvas), rendered and read back.
static func render_to_image(canvas_size: Vector2i, draw: Callable, supersample: int = SSAA_DEFAULT) -> Image:
	var g = load(_SELF_PATH).new(canvas_size, supersample)
	draw.call(g)
	return g.finish_image()

static func render_to_texture(canvas_size: Vector2i, draw: Callable, supersample: int = SSAA_DEFAULT) -> ImageTexture:
	return ImageTexture.create_from_image(render_to_image(canvas_size, draw, supersample))

func finish_image() -> Image:
	return render_all([self])[0]

func finish_texture() -> ImageTexture:
	return ImageTexture.create_from_image(finish_image())

# Frees the canvas without drawing it.
func discard() -> void:
	if not _done:
		_free()

# How many canvas items the recording will make (direct paints and image
# draws merge), and how many of them are canvas groups (a translucent paint
# that can overlap itself): for measuring -- a group is the costly kind.
func op_count() -> int:
	return _ops.size() + (1 if not _batch_tris.is_empty() else 0)

func group_count() -> int:
	var n := 0
	for op: Array in _ops:
		if op[0] == _OP_TRIS and float(op[3]) >= 0.0:
			n += 1
	return n

# --- State: save / restore and the transform ------------------------------------

func save() -> void:
	_stack.append({"xf": _xf, "lw": line_width, "cap": line_cap, "sc": stroke_color,
		"fc": fill_color, "ga": global_alpha})

func restore() -> void:
	if _stack.is_empty():  # Canvas: restore() on an empty stack does nothing
		return
	var s: Dictionary = _stack.pop_back()
	_xf = s["xf"]
	line_width = s["lw"]
	line_cap = s["cap"]
	stroke_color = s["sc"]
	fill_color = s["fc"]
	global_alpha = s["ga"]

# Canvas multiplies each of these onto the RIGHT of the current matrix.
func translate(x: float, y: float) -> void:
	_xf = _xf * Transform2D(0.0, Vector2(x, y))

func rotate(angle: float) -> void:
	_xf = _xf * Transform2D(angle, Vector2.ZERO)

func scale(sx: float, sy: float) -> void:
	_xf = _xf * Transform2D(Vector2(sx, 0.0), Vector2(0.0, sy), Vector2.ZERO)

func transform(a: float, b: float, c: float, d: float, e: float, f: float) -> void:
	_xf = _xf * Transform2D(Vector2(a, b), Vector2(c, d), Vector2(e, f))

# setTransform(a, b, c, d, e, f): x' = a x + c y + e, y' = b x + d y + f.
func set_transform(a: float, b: float, c: float, d: float, e: float, f: float) -> void:
	_xf = Transform2D(Vector2(a, b), Vector2(c, d), Vector2(e, f))

func reset_transform() -> void:
	_xf = Transform2D.IDENTITY

func get_transform() -> Transform2D:
	return _xf

func set_transform_matrix(xf: Transform2D) -> void:
	_xf = xf

# --- Path --------------------------------------------------------------------

func begin_path() -> void:
	_paths.clear()
	_closed.clear()
	_cur = PackedVector2Array()
	_cur_closed = false
	_path_odd = false

func move_to(x: float, y: float) -> void:
	_flush()
	_cur.push_back(_xf * Vector2(x, y))

func line_to(x: float, y: float) -> void:
	_line_to_device(_xf * Vector2(x, y))

# Canvas: marks the subpath closed; drawing on continues from its first point
# in a new subpath.
func close_path() -> void:
	if not _cur.is_empty():
		_cur_closed = true

# arc(x, y, r, start, end, anticlockwise): a straight line from the current
# point to the arc's start (or a moveTo on an empty path), then the arc,
# clockwise on screen unless anticlockwise. A sweep of 2*PI or more is the whole
# circle; otherwise the end angle is taken modulo 2*PI past the start.
func arc(cx: float, cy: float, r: float, a0: float, a1: float, anticlockwise: bool = false) -> void:
	if r < 0.0:
		push_error("InkCanvas.arc: negative radius %s (Canvas throws IndexSizeError)" % str(r))
		return
	_path_odd = true
	var sweep: float
	if not anticlockwise:
		sweep = TAU if a1 - a0 >= TAU else fposmod(a1 - a0, TAU)
	else:
		sweep = -TAU if a0 - a1 >= TAU else -fposmod(a0 - a1, TAU)
	var steps := maxi(1, ceili(absf(sweep) / _arc_step(r * _scale())))
	for i in steps + 1:
		var a := a0 + sweep * float(i) / float(steps)
		var p := _xf * Vector2(cx + cos(a) * r, cy + sin(a) * r)
		if i == 0 and _cur.is_empty():
			_cur.push_back(p)
		else:
			_line_to_device(p)

# rect(x, y, w, h): a closed four-point subpath; the next lineTo starts at (x, y).
func rect(x: float, y: float, w: float, h: float) -> void:
	_flush()
	_path_odd = true
	_cur.push_back(_xf * Vector2(x, y))
	_cur.push_back(_xf * Vector2(x + w, y))
	_cur.push_back(_xf * Vector2(x + w, y + h))
	_cur.push_back(_xf * Vector2(x, y + h))
	_cur_closed = true

# --- Painting ------------------------------------------------------------------

# fill(): every subpath, implicitly closed, in fill_color x global_alpha. The
# path is kept, as in Canvas, so a stroke() can follow.
func fill() -> void:
	var alpha := fill_color.a * global_alpha
	if alpha <= 0.0:
		return
	var tris := PackedVector2Array()
	var pieces := 0
	for i in _paths.size():
		pieces += _fill_into(tris, _paths[i])
	pieces += _fill_into(tris, _cur)
	if not tris.is_empty():
		_paint(tris, fill_color, alpha, pieces > 1)

# stroke(): every subpath with round joins and line_cap ends, line_width in
# user units. A device width <= 1 px is Skia's hairline (see the header). An
# ink stroke goes through the pen (see the header) unless the pen is "even".
func stroke() -> void:
	var alpha := stroke_color.a * global_alpha
	if alpha <= 0.0:
		return
	if not _path_odd and _pen_applies(stroke_color):
		_stroke_pen(alpha)
		return
	var w := line_width * _scale()
	if w <= 1.0:
		alpha *= w
		w = 1.0
	var hw := w * 0.5
	var round_cap := line_cap != "butt"
	var tris := PackedVector2Array()
	for i in _paths.size():
		_stroke_into(tris, _paths[i], _closed[i], hw, round_cap)
	_stroke_into(tris, _cur, _cur_closed, hw, round_cap)
	if not tris.is_empty():
		_paint(tris, stroke_color, alpha, not _single_segment())

# The path is one open two-point segment (a fibre, a tick): its quad and its
# two end caps meet only along edges, so it cannot overlap itself and needs no
# canvas group to composite once -- the pixels are the same, at a fraction of
# the cost (a ground has ~1,700 fibres).
func _single_segment() -> bool:
	var n := 0
	var only := PackedVector2Array()
	for p in _paths:
		if not p.is_empty():
			n += 1
			only = p
	if not _cur.is_empty():
		n += 1
		only = _cur
	if n != 1:
		return false
	var closed := _cur_closed if not _cur.is_empty() else _closed[_paths.size() - 1]
	return _dedupe(only, closed).size() == 2 and not closed

# fillRect(x, y, w, h) in fill_color x global_alpha. Leaves the path alone.
func fill_rect(x: float, y: float, w: float, h: float) -> void:
	var alpha := fill_color.a * global_alpha
	if alpha <= 0.0 or w == 0.0 or h == 0.0:
		return
	var a := _xf * Vector2(x, y)
	var b := _xf * Vector2(x + w, y)
	var c := _xf * Vector2(x + w, y + h)
	var d := _xf * Vector2(x, y + h)
	_paint(PackedVector2Array([a, b, c, a, c, d]), fill_color, alpha, false)

# The strip between two edge polylines, in fill_color x global_alpha -- the
# prototype's wall outline, which it fills with fill("evenodd"):
#   closed:  outline = [L, R], two rings; even-odd leaves the band between them.
#   open:    outline = [L + cap_end + reversed(R) + cap_start], one loop.
# Here the band is the union of the quads L[i] L[i+1] R[i+1] R[i] (plus the
# closing quad for a ring), and for an open band the two cap polygons
# [L[n-1]] + cap_end + [R[n-1]] and [R[0]] + cap_start + [L[0]] -- pass the
# prototype's `ce` and `cs` (s.caps without their last two points) or nothing
# for a square-ended wall. Same region as even-odd wherever the band does not
# fold over itself; where it does (a hairpin tighter than the wall), this fills
# the fold and even-odd would punch it out. Points are in user space.
func fill_band(left: PackedVector2Array, right: PackedVector2Array, closed: bool,
		cap_end: PackedVector2Array = PackedVector2Array(),
		cap_start: PackedVector2Array = PackedVector2Array()) -> void:
	var alpha := fill_color.a * global_alpha
	var n := mini(left.size(), right.size())
	if alpha <= 0.0 or n < 2:
		return
	var l := _map(left)
	var r := _map(right)
	var tris := PackedVector2Array()
	var quads := n if closed else n - 1
	for i in quads:
		var j := (i + 1) % n
		tris.push_back(l[i]); tris.push_back(l[j]); tris.push_back(r[j])
		tris.push_back(l[i]); tris.push_back(r[j]); tris.push_back(r[i])
	if not closed:
		if not cap_end.is_empty():
			var ce := PackedVector2Array([l[n - 1]])
			ce.append_array(_map(cap_end))
			ce.push_back(r[n - 1])
			_fill_into(tris, ce)
		if not cap_start.is_empty():
			var cs := PackedVector2Array([r[0]])
			cs.append_array(_map(cap_start))
			cs.push_back(l[0])
			_fill_into(tris, cs)
	_paint(tris, fill_color, alpha, true)

# drawImage(image, x, y, w, h) under the current transform and global_alpha.
# `texture` is taken as PREMULTIPLIED (what render_to_texture returns).
func draw_image(texture: Texture2D, x: float, y: float, w: float, h: float) -> void:
	if global_alpha <= 0.0 or texture == null:
		return
	var ga := global_alpha
	_image_op(texture, Rect2(x, y, w, h), Rect2(), "premul", Color(ga, ga, ga, ga))

# drawImage(image, sx, sy, sw, sh, x, y, w, h): the source rectangle (texels)
# of `texture` into the destination rectangle -- one sprite out of an atlas.
func draw_image_region(texture: Texture2D, sx: float, sy: float, sw: float, sh: float,
		x: float, y: float, w: float, h: float) -> void:
	if global_alpha <= 0.0 or texture == null or sw <= 0.0 or sh <= 0.0:
		return
	var ga := global_alpha
	_image_op(texture, Rect2(x, y, w, h), Rect2(sx, sy, sw, sh), "premul", Color(ga, ga, ga, ga))

# A textured rect under the current transform, shaded by `material` instead of
# the premultiplied composite. COLOR arrives as texture x (1, 1, 1, global_alpha).
# The compositing passes (shadow_pass.gd, grain.gd) draw through this.
func draw_image_with_material(texture: Texture2D, x: float, y: float, w: float, h: float, material: Material) -> void:
	if texture == null:
		return
	_image_op(texture, Rect2(x, y, w, h), Rect2(), material, Color(1.0, 1.0, 1.0, global_alpha))

# The same from a source rectangle of `texture` (an atlas region).
func draw_image_region_with_material(texture: Texture2D, src: Rect2, dest: Rect2, material: Material) -> void:
	if texture == null or not src.has_area():
		return
	_image_op(texture, dest, src, material, Color(1.0, 1.0, 1.0, global_alpha))

# --- The pen --------------------------------------------------------------------

# The pen as configured: mode, lit, shadow, open, taper_px, taper_frac, floor,
# ink (Color), shadow_dir (Vector2, unit, world/device space). Read from data
# on first use; thread-safe to read once loaded.
static func pen_config() -> Dictionary:
	if _pen.is_empty():
		_pen_mutex.lock()
		if _pen.is_empty():
			_pen = _load_pen()
		_pen_mutex.unlock()
	return _pen

# Overrides any of pen_config()'s keys for every canvas recorded afterwards.
static func configure_pen(overrides: Dictionary) -> void:
	var cfg := pen_config().duplicate()
	cfg.merge(overrides, true)
	_pen = cfg

static func set_pen_mode(mode: String) -> void:
	configure_pen({"mode": mode})

static func pen_mode() -> String:
	return str(pen_config().get("mode", "even"))

# What a cached sprite drawn with the pen depends on: "" for the even pen, else
# the mode and the shadow direction. Sprite caches add it to their keys.
static func pen_key() -> String:
	var cfg := pen_config()
	if str(cfg.get("mode", "even")) == "even":
		return ""
	var sd: Vector2 = cfg.get("shadow_dir", Vector2.ZERO)
	return "%s@%.4f,%.4f" % [cfg.get("mode"), sd.x, sd.y]

# Follows a RenderParams: its ink colour and its sun (the shadow direction is
# the prototype's shadowDir(): (sunAz + 90) degrees). Duck-typed: any object
# with INK (Color) and sunAz (float).
static func configure_pen_from(P: Object) -> void:
	var az := (float(P.get("sunAz")) + 90.0) * PI / 180.0
	configure_pen({"ink": P.get("INK"), "shadow_dir": Vector2(cos(az), sin(az))})

# Width factors along one subpath for the "shadow_side" pen (1.0 everywhere for
# "even"): the pen's rule, as a pure function of DEVICE-space points, so it can
# be checked headless. `taper_scale` is device px per user px (the tapers are
# given in user px).
static func pen_factors(pts: PackedVector2Array, closed: bool, cfg: Dictionary, taper_scale: float = 1.0) -> PackedFloat64Array:
	var n := pts.size()
	var out := PackedFloat64Array()
	out.resize(n)
	if str(cfg.get("mode", "even")) != "shadow_side":
		out.fill(1.0)
		return out
	var s := PackedFloat64Array()
	s.resize(n)
	s[0] = 0.0
	for i in range(1, n):
		s[i] = s[i - 1] + pts[i].distance_to(pts[i - 1])
	var L := s[n - 1] + (pts[0].distance_to(pts[n - 1]) if closed else 0.0)
	var outward := 1.0
	if closed:
		var A := 0.0
		for i in n:
			var p := pts[i]
			var q := pts[(i + 1) % n]
			A += p.x * q.y - q.x * p.y
		outward = -1.0 if A > 0.0 else 1.0  # the left normal points inward when the signed area is positive
	var sd: Vector2 = cfg.get("shadow_dir", Vector2(1, 0))
	var lit := float(cfg.get("lit", 0.42))
	var shadow := float(cfg.get("shadow", 1.87))
	var openf := float(cfg.get("open", 0.85))
	var floor_f := float(cfg.get("floor", 0.25))
	var Tl := minf(float(cfg.get("taper_px", 7.0)) * taper_scale, L * float(cfg.get("taper_frac", 0.4)))
	if Tl <= 0.0:
		Tl = 1.0  # JS: (Tl||1)
	for i in n:
		var a := pts[(i - 1 + n) % n] if closed else pts[maxi(0, i - 1)]
		var b := pts[(i + 1) % n] if closed else pts[mini(n - 1, i + 1)]
		var t := b - a
		var l := t.length()
		if l == 0.0:
			l = 1.0
		t /= l
		if closed:
			var d := (-t.y * sd.x + t.x * sd.y) * outward  # + where the edge faces away from the sun
			out[i] = lit + (shadow - lit) * maxf(0.0, d)
		else:
			var e := _smooth(minf(s[i], L - s[i]) / Tl)  # 0 at a pen landing or lift
			out[i] = openf * (floor_f + (1.0 - floor_f) * e)
	return out

static func _smooth(t: float) -> float:
	if t <= 0.0:
		return 0.0
	if t >= 1.0:
		return 1.0
	return t * t * (3.0 - 2.0 * t)

func _pen_applies(c: Color) -> bool:
	var cfg := pen_config()
	if str(cfg.get("mode", "even")) == "even":
		return false
	var ink: Color = cfg.get("ink", Color(0, 0, 0, 0))
	return c.r8 == ink.r8 and c.g8 == ink.g8 and c.b8 == ink.b8

# Ribbons for every subpath of the current path, painted as one call.
func _stroke_pen(alpha: float) -> void:
	var cfg := pen_config()
	var sc := _scale()
	var base := line_width * sc
	var tris := PackedVector2Array()
	var cols := PackedColorArray()
	var all_opaque := true
	var subs: Array = []
	for i in _paths.size():
		subs.append([_paths[i], _closed[i]])
	subs.append([_cur, _cur_closed])
	var ink := Color(stroke_color.r, stroke_color.g, stroke_color.b, 1.0)
	for sub: Array in subs:
		var pts := _dedupe_pen(sub[0], sub[1])
		var closed: bool = sub[1] and pts.size() > 2
		var n := pts.size()
		if n < 2:
			continue
		var f := pen_factors(pts, closed, cfg, sc)
		var left := PackedVector2Array()
		var right := PackedVector2Array()
		var al := PackedFloat32Array()
		left.resize(n)
		right.resize(n)
		al.resize(n)
		for i in n:
			var a := pts[(i - 1 + n) % n] if closed else pts[maxi(0, i - 1)]
			var b := pts[(i + 1) % n] if closed else pts[mini(n - 1, i + 1)]
			var t := (b - a).normalized()
			var nrm := Vector2(-t.y, t.x)
			var w := base * f[i]
			var hw := maxf(w, 1.0) * 0.5           # under a pixel: the hairline rule
			var a_i := alpha * minf(w, 1.0)
			if a_i < 1.0:
				all_opaque = false
			left[i] = pts[i] + nrm * hw
			right[i] = pts[i] - nrm * hw
			al[i] = a_i
		var segs := n if closed else n - 1
		for i in segs:
			var j := (i + 1) % n
			var ci := Color(ink.r, ink.g, ink.b, al[i])
			var cj := Color(ink.r, ink.g, ink.b, al[j])
			tris.push_back(left[i]); tris.push_back(left[j]); tris.push_back(right[j])
			cols.push_back(ci); cols.push_back(cj); cols.push_back(cj)
			tris.push_back(left[i]); tris.push_back(right[j]); tris.push_back(right[i])
			cols.push_back(ci); cols.push_back(cj); cols.push_back(ci)
	if tris.is_empty():
		return
	if all_opaque or tris.size() == 6:  # opaque, or one two-point ribbon: cannot overlap itself
		_record_direct(tris, cols)
	else:
		_flush_batch()
		_ops.append([_OP_TRIS, tris, cols, 1.0, true])

# The reference's ribbon() point cleanup: drop points within 1e-3 of the one
# before, and a closing point that repeats the first.
static func _dedupe_pen(src: PackedVector2Array, closed: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in src:
		if out.is_empty() or out[out.size() - 1].distance_to(q) > 1e-3:
			out.push_back(q)
	if closed and out.size() > 2 and out[0].distance_to(out[out.size() - 1]) < 1e-3:
		out.remove_at(out.size() - 1)
	return out

static func _load_pen() -> Dictionary:
	var cfg := {"mode": "even", "lit": 0.42, "shadow": 1.87, "open": 0.85, "taper_px": 7.0,
		"taper_frac": 0.4, "floor": 0.25, "ink": Color8(0x3d, 0x32, 0x26), "shadow_dir": Vector2(cos(PI * 0.75), sin(PI * 0.75))}
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH)) if FileAccess.file_exists(PARAMS_PATH) else null
	if not (raw is Dictionary):
		push_error("InkCanvas: %s did not load; the pen stays even" % PARAMS_PATH)
		return cfg
	var root: Dictionary = raw
	var pen: Dictionary = (root.get("linework", {}) as Dictionary).get("pen", {})
	var keys := {"mode": "mode", "lit_factor": "lit", "shadow_factor": "shadow", "open_line_factor": "open",
		"end_taper_px": "taper_px", "end_taper_max_fraction": "taper_frac", "end_floor": "floor"}
	for k: String in keys:
		if pen.has(k):
			cfg[keys[k]] = pen[k] if k == "mode" else float(pen[k])
		else:
			push_error("InkCanvas: linework.pen.%s missing in %s" % [k, PARAMS_PATH])
	var ink: Variant = (root.get("palette", {}) as Dictionary).get("ink")
	if ink is String and Color.html_is_valid(ink):
		cfg["ink"] = Color.html(ink)
	var sun: Variant = ((root.get("parameters", {}) as Dictionary).get("sun_direction", {}) as Dictionary).get("default")
	if sun is float or sun is int:
		var az := (float(sun) + 90.0) * PI / 180.0
		cfg["shadow_dir"] = Vector2(cos(az), sin(az))
	return cfg

# --- Internals: tessellation -----------------------------------------------------

func _flush() -> void:
	if not _cur.is_empty():
		_paths.append(_cur)
		_closed.append(_cur_closed)
	_cur = PackedVector2Array()
	_cur_closed = false

func _line_to_device(p: Vector2) -> void:
	if _cur.is_empty():
		_cur.push_back(p)  # Canvas: lineTo on an empty path acts as moveTo
	elif _cur_closed:
		var start := _cur[0]
		_flush()
		_cur.push_back(start)
		_cur.push_back(p)
	else:
		_cur.push_back(p)

func _scale() -> float:
	return sqrt(absf(_xf.determinant()))

func _map(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(points.size())
	for i in points.size():
		out[i] = _xf * points[i]
	return out

# Angle per chord so a circle of `device_radius` is within ARC_TOLERANCE.
static func _arc_step(device_radius: float) -> float:
	if device_radius <= ARC_TOLERANCE * 2.0:
		return PI / 4.0
	return minf(PI / 4.0, 2.0 * acos(1.0 - ARC_TOLERANCE / device_radius))

# Drops repeated points (Canvas prunes zero-length segments) and, for a closed
# outline, a last point that repeats the first.
static func _dedupe(src: PackedVector2Array, closed: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in src:
		if out.is_empty() or (q - out[out.size() - 1]).length_squared() > 1e-12:
			out.push_back(q)
	if closed and out.size() > 1 and (out[0] - out[out.size() - 1]).length_squared() <= 1e-12:
		out.remove_at(out.size() - 1)
	return out

static var _warned_triangulation := false

# Appends the triangles of one implicitly closed polygon; returns 1 if it
# drew anything. Ear clipping (Geometry2D) handles every simple polygon; a
# self-intersecting one falls back to a fan from the vertex mean, which is
# exact for anything star-shaped about that point.
static func _fill_into(tris: PackedVector2Array, src: PackedVector2Array) -> int:
	var p := _dedupe(src, true)
	if p.size() < 3:
		return 0
	var idx := Geometry2D.triangulate_polygon(p)
	if idx.is_empty():
		if not _warned_triangulation:
			_warned_triangulation = true
			push_warning("InkCanvas.fill: a polygon did not triangulate (self-intersecting?); drawing it as a fan")
		var c := Vector2.ZERO
		for q in p:
			c += q
		c /= float(p.size())
		for i in p.size():
			tris.push_back(c); tris.push_back(p[i]); tris.push_back(p[(i + 1) % p.size()])
		return 1
	for k in idx:
		tris.push_back(p[k])
	return 1

# One subpath's stroke: a quad per segment, a round wedge on the outside of
# every join, a half disc at each end (round caps). The pieces overlap on the
# inside of joins; _paint() merges them (opaque, or inside a canvas group).
func _stroke_into(tris: PackedVector2Array, src: PackedVector2Array, closed: bool, hw: float, round_cap: bool) -> void:
	var p := _dedupe(src, closed)
	var n := p.size()
	if n < 2:
		return  # Canvas: an empty or zero-length subpath strokes nothing
	if closed and n == 2:
		closed = false  # a closed two-point path is the same segment twice
	var segs := n if closed else n - 1
	var step := _arc_step(hw)
	var dirs := PackedVector2Array()
	dirs.resize(segs)
	for i in segs:
		dirs[i] = (p[(i + 1) % n] - p[i]).normalized()
	for i in segs:
		var a := p[i]
		var b := p[(i + 1) % n]
		var o := Vector2(-dirs[i].y, dirs[i].x) * hw
		tris.push_back(a + o); tris.push_back(b + o); tris.push_back(b - o)
		tris.push_back(a + o); tris.push_back(b - o); tris.push_back(a - o)
	var first := 0 if closed else 1
	var last := n if closed else n - 1
	for i in range(first, last):
		_join(tris, p[i], dirs[(i - 1 + segs) % segs], dirs[i % segs], hw, step)
	if not closed and round_cap:
		var ds := dirs[0]
		var de := dirs[segs - 1]
		_fan(tris, p[0], Vector2(-ds.y, ds.x) * hw, PI, step)      # left normal, sweeping back
		_fan(tris, p[n - 1], Vector2(de.y, -de.x) * hw, PI, step)  # right normal, sweeping forward

# The outer wedge of a round join at `c`, from the incoming segment's edge to
# the outgoing one's, on the side away from the turn.
static func _join(tris: PackedVector2Array, c: Vector2, d0: Vector2, d1: Vector2, hw: float, step: float) -> void:
	var cr := d0.cross(d1)
	var dt := d0.dot(d1)
	if dt < -0.99:
		# Doubling back: the join is the half disc ahead of `c`; draw it whole.
		_fan(tris, c, Vector2(-d0.y, d0.x) * hw, TAU, step)
		return
	if absf(cr) < 1e-7:
		return  # straight on
	var n0 := Vector2(-d0.y, d0.x)
	var n1 := Vector2(-d1.y, d1.x)
	var v0 := -n0 if cr > 0.0 else n0
	var v1 := -n1 if cr > 0.0 else n1
	_fan(tris, c, v0 * hw, atan2(v0.cross(v1), v0.dot(v1)), step)

# A fan of triangles around `c`, starting at offset `start` and turning by
# `sweep` radians (positive turns +x toward +y, i.e. clockwise on screen).
static func _fan(tris: PackedVector2Array, c: Vector2, start: Vector2, sweep: float, step: float) -> void:
	var m := maxi(1, ceili(absf(sweep) / step))
	var cs := cos(sweep / float(m))
	var sn := sin(sweep / float(m))
	var prev := start
	for k in m:
		var nxt := Vector2(prev.x * cs - prev.y * sn, prev.x * sn + prev.y * cs)
		tris.push_back(c); tris.push_back(c + prev); tris.push_back(c + nxt)
		prev = nxt

# --- Internals: recording ------------------------------------------------------------

# One paint call. Translucent and possibly self-overlapping -> canvas group, so
# the call's coverage is composited exactly once (see the header). Otherwise
# it joins the running batch of direct paints.
func _paint(tris: PackedVector2Array, color: Color, alpha: float, may_overlap: bool) -> void:
	assert(not _active, "InkCanvas: drawing on a canvas that was already rendered")
	if alpha < 1.0 and may_overlap:
		_flush_batch()
		var cols := PackedColorArray([Color(color.r, color.g, color.b, 1.0)])
		_ops.append([_OP_TRIS, tris, cols, alpha, false])
	else:
		var cols := PackedColorArray()
		cols.resize(tris.size())
		cols.fill(Color(color.r, color.g, color.b, alpha))
		_record_direct(tris, cols)

func _record_direct(tris: PackedVector2Array, cols: PackedColorArray) -> void:
	_batch_tris.append_array(tris)
	_batch_cols.append_array(cols)

func _flush_batch() -> void:
	if not _batch_tris.is_empty():
		_ops.append([_OP_TRIS, _batch_tris, _batch_cols, -1.0, false])
		_batch_tris = PackedVector2Array()
		_batch_cols = PackedColorArray()

# One textured quad: `dest` (user space, under the current transform) shows
# `src` (texels of `texture`; zero size: all of it). An AtlasTexture is drawn
# as its region of its atlas, so a sprite packed in an atlas page draws like
# a texture of its own. The quad is stored in device space with its UVs, so
# consecutive draws of the same texture share one canvas item.
func _image_op(texture: Texture2D, dest: Rect2, src: Rect2, material: Variant, modulate: Color) -> void:
	assert(not _active, "InkCanvas: drawing on a canvas that was already rendered")
	if texture is AtlasTexture and (texture as AtlasTexture).atlas != null:
		var at := texture as AtlasTexture
		var region := at.region
		if src.has_area():
			src = Rect2(region.position + src.position, src.size)
		else:
			src = region
		texture = at.atlas
	var full := Vector2(texture.get_width(), texture.get_height())
	if not src.has_area():
		src = Rect2(Vector2.ZERO, full)
	var magnify := _scale() * maxf(absf(dest.size.x) / src.size.x, absf(dest.size.y) / src.size.y)
	var nearest := ssaa > 1 and magnify <= 1.0001
	var p0 := _xf * dest.position
	var p1 := _xf * Vector2(dest.end.x, dest.position.y)
	var p2 := _xf * dest.end
	var p3 := _xf * Vector2(dest.position.x, dest.end.y)
	var u0 := src.position / full
	var u2 := src.end / full
	var u1 := Vector2(u2.x, u0.y)
	var u3 := Vector2(u0.x, u2.y)
	var op: Array
	if not _ops.is_empty() and _batch_tris.is_empty():
		var last: Array = _ops[_ops.size() - 1]
		if last[0] == _OP_IMAGES and last[1] == texture and typeof(last[2]) == typeof(material) and last[2] == material and last[3] == nearest:
			op = last
	if op.is_empty():
		_flush_batch()
		op = [_OP_IMAGES, texture, material, nearest, PackedVector2Array(), PackedVector2Array(), PackedColorArray()]
		_ops.append(op)
	# Taken out of the op while appending so the arrays are not shared (no copy per draw).
	var pts: PackedVector2Array = op[4]
	var uvs: PackedVector2Array = op[5]
	var cols: PackedColorArray = op[6]
	op[4] = null
	op[5] = null
	op[6] = null
	pts.append_array(PackedVector2Array([p0, p1, p2, p0, p2, p3]))
	uvs.append_array(PackedVector2Array([u0, u1, u2, u0, u2, u3]))
	for _k in 6:
		cols.push_back(modulate)
	op[4] = pts
	op[5] = uvs
	op[6] = cols

# --- Internals: the RenderingServer side (main thread) ------------------------------

static func _material(key: String, code: String) -> ShaderMaterial:
	if not _materials.has(key):
		var shader := Shader.new()
		shader.code = code
		var mat := ShaderMaterial.new()
		mat.shader = shader
		_materials[key] = mat
	return _materials[key]

static func _make_viewport(px: Vector2i) -> RID:
	var vp := RenderingServer.viewport_create()
	RenderingServer.viewport_set_size(vp, px.x, px.y)
	RenderingServer.viewport_set_transparent_background(vp, true)
	RenderingServer.viewport_set_disable_3d(vp, true)
	RenderingServer.viewport_set_clear_mode(vp, RenderingServer.VIEWPORT_CLEAR_ALWAYS)
	RenderingServer.viewport_set_update_mode(vp, RenderingServer.VIEWPORT_UPDATE_ALWAYS)
	RenderingServer.viewport_set_active(vp, false)
	return vp

func _new_item(parent: RID = RID()) -> RID:
	var item := RenderingServer.canvas_item_create()
	if parent.is_valid():
		RenderingServer.canvas_item_set_parent(item, parent)
	else:
		RenderingServer.canvas_item_set_parent(item, _canvas_hi)
		# Sibling order is by draw index (the engine's sort is not stable).
		RenderingServer.canvas_item_set_draw_index(item, _next_index)
		_next_index += 1
	_items.append(item)
	return item

# Creates the viewports and replays the recording into canvas items, then
# makes the viewports active for the next drawn frame.
func _activate() -> void:
	_begin_activation()
	_continue_activation(1 << 62)

var _op_i := 0

# submit() in pieces, for a caller with a frame budget: begin_submit() makes
# the (inactive) viewports, submit_some(usec) turns recorded calls into canvas
# items for about that long and returns true once all are in and the canvas
# is active -- it is then drawn with the next frame. A page of 60 tree sprites
# is ~4,000 canvas items, ~50 ms at once.
func begin_submit() -> void:
	_begin_activation()

func submit_some(budget_usec: int) -> bool:
	return _continue_activation(budget_usec)

func _begin_activation() -> void:
	assert(not _active and not _done, "InkCanvas: rendered twice")
	_flush_batch()
	_active = true
	_op_i = 0
	_vp_hi = _make_viewport(size * ssaa)
	_canvas_hi = RenderingServer.canvas_create()
	RenderingServer.viewport_attach_canvas(_vp_hi, _canvas_hi)
	if ssaa > 1:
		# Callers draw in canvas pixels; the viewport scales them up.
		RenderingServer.viewport_set_canvas_transform(_vp_hi, _canvas_hi,
			Transform2D.IDENTITY.scaled(Vector2(ssaa, ssaa)))
		_vp_lo = _make_viewport(size)
		_canvas_lo = RenderingServer.canvas_create()
		RenderingServer.viewport_attach_canvas(_vp_lo, _canvas_lo)
		var resolve := RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(resolve, _canvas_lo)
		RenderingServer.canvas_item_set_material(resolve, _material("box%d" % ssaa, _BOX_SHADER % ssaa).get_rid())
		RenderingServer.canvas_item_add_texture_rect(resolve, Rect2(Vector2.ZERO, Vector2(size)),
			RenderingServer.viewport_get_texture(_vp_hi))
		_items.append(resolve)
		# A child viewport is drawn before its parent in the same frame, so the
		# resolve reads a finished supersampled target.
		RenderingServer.viewport_set_parent_viewport(_vp_hi, _vp_lo)

func _continue_activation(budget_usec: int) -> bool:
	var t0 := Time.get_ticks_usec()
	while _op_i < _ops.size():
		var op: Array = _ops[_op_i]
		_op_i += 1
		if op[0] == _OP_TRIS:
			_submit_tris(op)
		else:
			_submit_images(op)
		if Time.get_ticks_usec() - t0 > budget_usec:
			return _op_i >= _ops.size() and _finish_activation()
	return _finish_activation()

func _finish_activation() -> bool:
	_ops.clear()
	# ONCE, not ALWAYS: a submitted canvas waits a frame or more for its
	# read-back, and an ALWAYS viewport would be drawn again every one of those
	# frames (measured: a sprite page's read-back went from ~190 ms to 1 s+
	# when collected four frames late).
	RenderingServer.viewport_set_update_mode(_vp_hi, RenderingServer.VIEWPORT_UPDATE_ONCE)
	RenderingServer.viewport_set_active(_vp_hi, true)
	if _vp_lo.is_valid():
		RenderingServer.viewport_set_update_mode(_vp_lo, RenderingServer.VIEWPORT_UPDATE_ONCE)
		RenderingServer.viewport_set_active(_vp_lo, true)
	return true

func _submit_tris(op: Array) -> void:
	var tris: PackedVector2Array = op[1]
	var cols: PackedColorArray = op[2]
	var group_alpha: float = op[3]
	var item := _new_item()
	if group_alpha >= 0.0:
		RenderingServer.canvas_item_set_canvas_group_mode(item,
			RenderingServer.CANVAS_GROUP_MODE_TRANSPARENT, 0.0, true, 0.0, false)
		RenderingServer.canvas_item_set_self_modulate(item, Color(1.0, 1.0, 1.0, group_alpha))
		var body := _new_item(item)
		if op[4]:
			RenderingServer.canvas_item_set_material(body, _material("ribbon", _RIBBON_SHADER).get_rid())
		RenderingServer.canvas_item_add_triangle_array(body, PackedInt32Array(), tris, cols)
	else:
		RenderingServer.canvas_item_add_triangle_array(item, PackedInt32Array(), tris, cols)

func _submit_images(op: Array) -> void:
	var texture: Texture2D = op[1]
	var material: Material = op[2] if op[2] is Material else _material(str(op[2]), _PREMUL_SHADER)
	var item := _new_item()
	RenderingServer.canvas_item_set_material(item, material.get_rid())
	RenderingServer.canvas_item_set_default_texture_filter(item,
		RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST if op[3] else RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_LINEAR)
	RenderingServer.canvas_item_add_triangle_array(item, PackedInt32Array(), op[4], op[6], op[5],
		PackedInt32Array(), PackedFloat32Array(), texture.get_rid())
	_keep.append(texture)
	_keep.append(material)

func _collect() -> Image:
	var vp := _vp_lo if _vp_lo.is_valid() else _vp_hi
	var img: Image = RenderingServer.texture_2d_get(RenderingServer.viewport_get_texture(vp))
	_free()
	return img

func _free() -> void:
	_done = true
	for i in range(_items.size() - 1, -1, -1):
		RenderingServer.free_rid(_items[i])
	_items.clear()
	for rid in [_canvas_hi, _canvas_lo, _vp_hi, _vp_lo]:
		if rid.is_valid():
			RenderingServer.free_rid(rid)
	_keep.clear()
	_ops.clear()
	_batch_tris = PackedVector2Array()
	_batch_cols = PackedColorArray()
