extends RefCounted

# WHAT THE FOUR BORDER OPTIONS SHARE (builder, map-border board, 2026-10-11; PROPOSED). An option is a RefCounted the border
# (map_border.gd) makes with `new(border)` and drives:
#
#   build()                make its nodes (children of the border: z_index >= 1) and read every field of its data section
#   frame(xf, zoom, vp)    the camera changed (called when the canvas transform or the viewport's size did, never otherwise):
#                          xf maps map px to screen px, zoom is its scale, vp the viewport's size in px
#   tick()                 every frame: the option's bake, if it has one
#   is_ready() / pending() whether every piece is made, and how many are not
#   dispose()              the border frees the option's nodes itself; this is for the rest (threads, textures)
#   shutdown()             the node left the tree: stop any worker (a quit with a task running GDScript crashes the engine)

const Fill = preload("res://scripts/render/map_border_fill.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")

var b: Node2D                 # the border
var fill: Fill = null
var band_m := 100.0           # reach.band_m

func _init(border: Node2D) -> void:
	b = border

func build() -> void:
	pass

func frame(_xf: Transform2D, _zoom: float, _vp: Vector2) -> void:
	pass

func tick() -> void:
	pass

func is_ready() -> bool:
	return true

func pending() -> int:
	return 0

func dispose() -> void:
	pass

func shutdown() -> void:
	pass

# The outside fill, with the shared fields read (reach.*, paper.*). `edge`: the fill also reaches into the map under an edge line
# and cuts it at the map's rectangle with the shader's edge logic; false: a plain fill outside the rectangle (the table).
func make_fill(edge: bool, paper_colour: Color) -> Fill:
	var d: CameraData = b.data
	band_m = d.num("reach.band_m")
	var outside := d.num("reach.outside_px")
	var inset := d.num("reach.inset_px")
	var grain_on := d.flag("paper.grain")
	fill = Fill.new()
	b.add_child(fill)
	fill.setup(b.map_rect_px, outside, inset if edge else 0.0, b.grain_texture() if grain_on else null, b.P.grain, b.grain_tile_px() if grain_on else 1024.0)
	fill.set_paper(paper_colour)
	return fill

# The role colour as the shader takes it: straight RGBA.
static func vec4(c: Color) -> Vector4:
	return Vector4(c.r, c.g, c.b, c.a)
