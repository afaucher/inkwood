extends RefCounted

# A Canvas-2D-like drawing surface covering EXACTLY the subset of the HTML
# Canvas API the prototype draws with (reference/inkwood-renderer.html), so its
# routines -- drawLobe, buildTreeSprite, buildPropSprite, drawWall, drawHouse,
# drawRoad, buildGround, castShadows, render -- port line for line:
#
#   g.beginPath()  g.moveTo  g.lineTo  g.closePath  g.arc  g.rect
#   g.fill()  g.stroke()  g.fillRect  g.drawImage(img, x, y, w, h)
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
# and render many in ONE engine frame with InkCanvas.render_all([g1, g2, ...]).
#
# --- HOW IT DRAWS ------------------------------------------------------------
#
# GEOMETRY IS TESSELLATED HERE, IN GDSCRIPT, into device-space triangles, and
# each fill / stroke / drawImage becomes one canvas item on a private
# RenderingServer viewport. No nodes, no scene tree, no _draw(): the frame is
# drawn synchronously with RenderingServer.force_draw() and read back with
# texture_2d_get(). The same calls make the same triangles, and the same
# triangles rasterize to the same pixels -- deterministic.
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

# Textures from render_to_texture() are premultiplied; composite them as such.
# COLOR arrives as texture x vertex colour, and the vertex colour is
# (a, a, a, a) so globalAlpha scales a premultiplied texel correctly.
const _PREMUL_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
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

var _vp_hi: RID
var _vp_lo: RID
var _canvas_hi: RID
var _canvas_lo: RID
var _items: Array[RID] = []
var _keep: Array = []  # textures and materials the items point at, alive until drawn
var _next_index := 0
var _done := false

static var _materials: Dictionary = {}

func _init(canvas_size: Vector2i, supersample: int = SSAA_DEFAULT) -> void:
	size = Vector2i(maxi(1, canvas_size.x), maxi(1, canvas_size.y))
	ssaa = maxi(1, supersample)
	while ssaa > 1 and maxi(size.x, size.y) * ssaa > MAX_TARGET_PX:
		ssaa -= 1
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

# A canvas dropped without being rendered gives its RenderingServer objects
# back here. Inline rather than a call to _free(): during PREDELETE a
# RefCounted's own methods can no longer be called (observed 2026-10-09:
# "Attempt to call function '_free' in base 'null instance'", and the RIDs
# leaked), while its members can still be read.
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
static func render_all(canvases: Array) -> Array[Image]:
	for c in canvases:
		c._activate()
	RenderingServer.force_draw(false)
	var out: Array[Image] = []
	for c in canvases:
		out.append(c._collect())
	return out

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
# user units. A device width <= 1 px is Skia's hairline (see the header).
func stroke() -> void:
	var alpha := stroke_color.a * global_alpha
	var w := line_width * _scale()
	if w <= 1.0:
		alpha *= w
		w = 1.0
	if alpha <= 0.0:
		return
	var hw := w * 0.5
	var round_cap := line_cap != "butt"
	var tris := PackedVector2Array()
	for i in _paths.size():
		_stroke_into(tris, _paths[i], _closed[i], hw, round_cap)
	_stroke_into(tris, _cur, _cur_closed, hw, round_cap)
	if not tris.is_empty():
		_paint(tris, stroke_color, alpha, true)

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
	_image_item(texture, Rect2(x, y, w, h), _material("premul", _PREMUL_SHADER), Color(ga, ga, ga, ga))

# A textured rect under the current transform, shaded by `material` instead of
# the premultiplied composite. COLOR arrives as texture x (1, 1, 1, global_alpha).
# The compositing passes (shadow_pass.gd, grain.gd) draw through this.
func draw_image_with_material(texture: Texture2D, x: float, y: float, w: float, h: float, material: Material) -> void:
	if texture == null:
		return
	_image_item(texture, Rect2(x, y, w, h), material, Color(1.0, 1.0, 1.0, global_alpha))

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

# --- Internals: the RenderingServer side ------------------------------------------

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
	# Inactive until its own render: force_draw() draws every ACTIVE viewport,
	# and a half-recorded canvas has no business in someone else's frame.
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

# One paint call. Translucent and possibly self-overlapping -> canvas group, so
# the call's coverage is composited exactly once (see the header).
func _paint(tris: PackedVector2Array, color: Color, alpha: float, may_overlap: bool) -> void:
	assert(not _done, "InkCanvas: drawing on a canvas that was already rendered")
	var item := _new_item()
	if alpha < 1.0 and may_overlap:
		RenderingServer.canvas_item_set_canvas_group_mode(item,
			RenderingServer.CANVAS_GROUP_MODE_TRANSPARENT, 0.0, true, 0.0, false)
		RenderingServer.canvas_item_set_self_modulate(item, Color(1.0, 1.0, 1.0, alpha))
		var body := _new_item(item)
		RenderingServer.canvas_item_add_triangle_array(body, PackedInt32Array(), tris,
			PackedColorArray([Color(color.r, color.g, color.b, 1.0)]))
	else:
		RenderingServer.canvas_item_add_triangle_array(item, PackedInt32Array(), tris,
			PackedColorArray([Color(color.r, color.g, color.b, alpha)]))

func _image_item(texture: Texture2D, dest: Rect2, material: Material, modulate: Color) -> void:
	assert(not _done, "InkCanvas: drawing on a canvas that was already rendered")
	var item := _new_item()
	RenderingServer.canvas_item_set_transform(item, _xf)
	RenderingServer.canvas_item_set_material(item, material.get_rid())
	var magnify := _scale() * maxf(absf(dest.size.x) / float(texture.get_width()),
		absf(dest.size.y) / float(texture.get_height()))
	var nearest := ssaa > 1 and magnify <= 1.0001
	RenderingServer.canvas_item_set_default_texture_filter(item,
		RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST if nearest else RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_LINEAR)
	RenderingServer.canvas_item_add_texture_rect(item, dest, texture.get_rid(), false, modulate)
	_keep.append(texture)
	_keep.append(material)

func _activate() -> void:
	assert(not _done, "InkCanvas: rendered twice")
	RenderingServer.viewport_set_active(_vp_hi, true)
	if _vp_lo.is_valid():
		RenderingServer.viewport_set_active(_vp_lo, true)

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
