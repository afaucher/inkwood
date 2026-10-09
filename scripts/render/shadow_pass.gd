extends RefCounted

# The prototype's castShadows mechanics (reference/inkwood-renderer.html):
#
#   m.clearRect(...)                                   // a frame-sized mask
#   ... silhouettes in solid black: prism hulls (m.fill), trunks (m.stroke),
#       sprites by their alpha (m.drawImage, stretched for a canopy) ...
#   m.globalCompositeOperation = "source-in"; m.fillStyle = P.shadowCol; m.fillRect(...)
#   ctx.globalAlpha = P.shadowStr; ctx.drawImage(mask, 0, 0)
#
# Every silhouette lands in ONE alpha channel first, and that channel is tinted
# and composited once, so overlapping shadows never darken twice. Here the mask
# is an InkCanvas (same antialiasing as everything else) and the last two steps
# are one shader draw (shaders/shadow_composite.gdshader).
#
#   var pass := ShadowPass.new(Vector2i(W, H))
#   pass.draw_polygon(hull)                                  // walls, houses
#   pass.draw_line(Vector2(o.x, o.y), Vector2(sx, sy), maxf(1.5, o.r * .12))   // a trunk
#   pass.draw_silhouette_texture(o.sprite, xf, Rect2(-o.half, -o.half, s, s))  // a canopy
#   pass.composite(frame, tint, strength)                   // renders the mask; clears for the next pass
#
# `canvas` is the mask itself, for anything the helpers do not cover -- the
# prototype builds all its hulls into one path and fills once; port that as
# canvas.begin_path() / move_to / line_to ... / canvas.fill() verbatim.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const COMPOSITE_SHADER = preload("res://scripts/render/shaders/shadow_composite.gdshader")

# A sprite drawn by its alpha alone, in black (the mask's colour is never read,
# but black keeps a dumped mask legible). Premultiplied, like the canvas.
const _SILHOUETTE_SHADER := """
shader_type canvas_item;
render_mode unshaded, blend_premul_alpha;
void fragment() {
	COLOR = vec4(0.0, 0.0, 0.0, COLOR.a);
}
"""

var size: Vector2i
var ssaa: int
var canvas: InkCanvas

static var _silhouette: ShaderMaterial

func _init(frame_size: Vector2i, supersample: int = InkCanvas.SSAA_DEFAULT) -> void:
	size = frame_size
	ssaa = supersample
	clear()

# A fresh, empty mask (m.clearRect). Drops anything drawn since the last composite.
func clear() -> void:
	if canvas != null:
		canvas.discard()
	canvas = InkCanvas.new(size, ssaa)
	canvas.fill_color = Color.BLACK
	canvas.stroke_color = Color.BLACK
	canvas.line_cap = "round"

# m.save(); <xform>; m.drawImage(tex, dest...); m.restore() -- the texture's
# alpha, in black, through `xform`. `dest` is drawImage's rect in xform's space;
# by default the texture's own pixel rect. The canopy shadow is
#   Transform2D(0, Vector2(sx, sy)) * Transform2D(az, Vector2.ZERO)
#     * Transform2D(Vector2(stretch, 0), Vector2(0, 1), Vector2.ZERO) * Transform2D(-az, Vector2.ZERO)
# with dest Rect2(-half, -half, s, s): translate, rotate(az), scale(stretch, 1), rotate(-az).
func draw_silhouette_texture(texture: Texture2D, xform: Transform2D, dest: Rect2 = Rect2()) -> void:
	var r := dest if dest.has_area() else Rect2(Vector2.ZERO, texture.get_size())
	canvas.save()
	canvas.set_transform_matrix(xform)
	canvas.draw_image_with_material(texture, r.position.x, r.position.y, r.size.x, r.size.y, _silhouette_material())
	canvas.restore()

# One filled polygon in solid black (a prism hull). Frame coordinates.
func draw_polygon(points: PackedVector2Array) -> void:
	if points.size() < 3:
		return
	canvas.begin_path()
	canvas.move_to(points[0].x, points[0].y)
	for i in range(1, points.size()):
		canvas.line_to(points[i].x, points[i].y)
	canvas.close_path()
	canvas.fill()

# A round-capped black stroke from a to b (a tree trunk). Frame coordinates.
func draw_line(a: Vector2, b: Vector2, width: float) -> void:
	canvas.line_width = width
	canvas.begin_path()
	canvas.move_to(a.x, a.y)
	canvas.line_to(b.x, b.y)
	canvas.stroke()

# Renders the mask and composites it onto `onto` in one tint at `strength`
# (ctx.save(); ctx.setTransform(1,0,0,1,0,0); ctx.globalAlpha = strength;
# ctx.drawImage(tinted mask, 0, 0); ctx.restore()). Then clears, ready for the
# next pass. Returns the mask texture (premultiplied black) for inspection.
func composite(onto: InkCanvas, tint: Color, strength: float) -> ImageTexture:
	var mask := canvas.finish_texture()
	canvas = null
	clear()
	var mat := ShaderMaterial.new()
	mat.shader = COMPOSITE_SHADER
	mat.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	mat.set_shader_parameter("strength", strength)
	onto.save()
	onto.reset_transform()
	onto.global_alpha = 1.0
	onto.draw_image_with_material(mask, 0.0, 0.0, float(size.x), float(size.y), mat)
	onto.restore()
	return mask

static func _silhouette_material() -> ShaderMaterial:
	if _silhouette == null:
		var shader := Shader.new()
		shader.code = _SILHOUETTE_SHADER
		_silhouette = ShaderMaterial.new()
		_silhouette.shader = shader
	return _silhouette
