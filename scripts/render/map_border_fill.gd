extends Node2D

# THE OUTSIDE FILL (builder, map-border board, 2026-10-11; PROPOSED). Four rectangles round the map's rectangle, drawn with
# map_border_edge.gdshader: the paper (or, option D, the table) at world coordinates with the map's grain, an optional edge line,
# fine rule and hatch band. One node, one material, four quads: it costs the same at any size and nothing is baked.
#
# WHERE IT SITS: z_index 1, i.e. ABOVE the map's chunks and the fog's topographic quads (both z 0), and only outside the map's
# rectangle (the rectangles reach `inset_px` INTO the map under an edge line, transparent but for the ink). Above, not below,
# because the map layer and the fog reach past the 5,000 m bounds: the baker's chunks are whole 512 m squares and the fog's whole
# 256 m ones, so on the right and the bottom they show 120 m of terrain beyond the edge. The fill hides that sliver, so the
# map ends where its bounds say and the border begins there. (The screen-space layers -- the markers, the tracks, the roster --
# are separate canvas layers and stay above it.)

const SHADER = preload("res://scripts/render/map_border_edge.gdshader")

var mat: ShaderMaterial
var _rects: Array[Rect2] = []

func _init() -> void:
	name = "Fill"
	z_index = 1
	mat = ShaderMaterial.new()
	mat.shader = SHADER
	material = mat

# `map_rect`: the map in map px. `outside_px`: how far the fill goes. `inset_px`: how far it reaches into the map (0: it does not;
# then it is a plain fill outside the rectangle and the shader's edge logic is off). `grain`: the tile (null: none).
func setup(map_rect: Rect2, outside_px: float, inset_px: float, grain: Texture2D, grain_strength: float, grain_tile: float) -> void:
	var edge_on := inset_px > 0.0
	mat.set_shader_parameter("edge_on", edge_on)
	mat.set_shader_parameter("map_rect", Vector4(map_rect.position.x, map_rect.position.y, map_rect.end.x, map_rect.end.y))
	mat.set_shader_parameter("grain_tile", grain_tile)
	if grain != null:
		mat.set_shader_parameter("grain", grain)
		mat.set_shader_parameter("grain_strength", grain_strength)
	else:
		mat.set_shader_parameter("grain_strength", 0.0)
	var L := outside_px
	var a := map_rect.position
	var b := map_rect.end
	var i := inset_px
	_rects = [
		Rect2(a.x - L, a.y - L, (b.x - a.x) + 2.0 * L, L + i),                                   # top, corners included
		Rect2(a.x - L, b.y - i, (b.x - a.x) + 2.0 * L, L + i),                                   # bottom
		Rect2(a.x - L, a.y + i, L + i, (b.y - a.y) - 2.0 * i),                                   # left
		Rect2(b.x - i, a.y + i, L + i, (b.y - a.y) - 2.0 * i),                                   # right
	]
	queue_redraw()

# The colour the paper is tinted from (0..255 channels, as the map's shader takes it).
func set_paper(c: Color) -> void:
	mat.set_shader_parameter("paper", Vector3(c.r8, c.g8, c.b8))

func set_zoom(z: float) -> void:
	mat.set_shader_parameter("zoom", z)

func set_param(name_: String, v: Variant) -> void:
	mat.set_shader_parameter(name_, v)

func _draw() -> void:
	for r: Rect2 in _rects:
		draw_rect(r, Color.WHITE)
