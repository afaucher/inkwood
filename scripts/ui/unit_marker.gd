extends Node2D

# One unit on the map: the plane in ink (a Sprite2D of its baked art, rotated
# to its heading -- never re-tessellated per frame) and its shadow (a Sprite2D
# of the silhouette, in the layer's shared shadow group so overlapping shadows
# merge, as the map's shadow pass merges them). Built and posed by
# unit_marker_layer.gd; the ring, side mark and leader line are drawn by the
# layer above every plane.
#
# Positions are SCREEN pixels in the layer's space; the layer maps world metres
# through the host's mapping and calls set_pose() each frame.
#
# A unit whose silhouette has no baked art (headless runs, a type the sheet
# cannot draw yet) still gets a marker: a small inked arrow from _draw, so
# every unit is on screen (exit criterion 6).

const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

var unit_id: String = ""
var silhouette: String = ""
var size_m: float = 10.0
var accent := Color.BLACK
var selected: bool = false

var art: UnitMarkerArt.Art = null
var plane: Sprite2D
var shadow: Sprite2D           # lives in the layer's shadow group, not under this node

var screen_ppm: float = 1.0    # the host's px per metre where the unit is
var screen_heading: float = 0.0
var _checked_k: float = -1.0   # the marker.true_scale the art was last checked against
var _style: UiStyle
var _fallback_ink := Color.BLACK

func setup(style: RefCounted, id: String, silhouette_id: String, size: float, side_accent: Color, shadow_parent: Node) -> void:
	_style = style as UiStyle
	unit_id = id
	silhouette = silhouette_id
	size_m = size
	accent = side_accent
	_fallback_ink = style.color("ink")
	name = "Marker_%s" % id
	plane = Sprite2D.new()
	plane.centered = false
	plane.name = "Plane"
	add_child(plane)
	shadow = Sprite2D.new()
	shadow.centered = false
	shadow.name = "Shadow_%s" % id
	var tint: Color = style.color("unit_shadow")
	# Opaque tint inside the group; the group composites once at the shadow strength.
	shadow.modulate = Color(tint.r, tint.g, tint.b, 1.0)
	shadow_parent.add_child(shadow)

func _exit_tree() -> void:
	if is_instance_valid(shadow):
		shadow.queue_free()

# Pose the marker: screen position of the unit, the screen angle of its
# heading, the host's px per metre there, and the shadow's screen offset.
func set_pose(screen_pos: Vector2, heading_screen: float, ppm: float, shadow_offset_px: Vector2) -> void:
	position = screen_pos
	screen_heading = heading_screen
	var k: float = _style.num("marker.true_scale")
	# The art is baked for ppm x true_scale, so a change of EITHER re-checks it
	# (the plane-size knob changes only true_scale: the art stayed blurry, or
	# coarse, until the next zoom).
	if absf(ppm - screen_ppm) > 1e-6 or k != _checked_k:
		screen_ppm = ppm
		_checked_k = k
		_ensure_art()
	elif art == null:
		_ensure_art()
	var rot := heading_screen + PI / 2.0  # the art's nose points to -y
	if art != null and art.texture != null:
		var sc := Vector2.ONE * (screen_ppm * k / art.ppm)
		plane.texture = art.texture
		plane.offset = -art.origin
		plane.rotation = rot
		plane.scale = sc
		shadow.texture = art.mask
		shadow.offset = -art.origin
		shadow.rotation = rot
		shadow.scale = sc
		shadow.position = screen_pos + shadow_offset_px
		shadow.visible = visible
	else:
		shadow.visible = false
	queue_redraw()

# Re-bake only when the host's scale has drifted past the data's ratio.
func _ensure_art() -> void:
	var want: float = screen_ppm * _style.num("marker.true_scale")
	if art != null:
		var ratio := want / art.ppm
		var r: float = _style.num("unit_art.rebake_ratio")
		if ratio <= r and ratio >= 1.0 / r:
			return
	var a: UnitMarkerArt.Art = UnitMarkerArt.art_for(_style, silhouette, accent, want)
	if a != null:
		art = a

# Drops the art held and bakes it again at the current scale (the art cache was
# cleared because the pen changed, or the scale rule did).
func refresh_art() -> void:
	art = null
	_ensure_art()

# Screen radius of the plane itself (for hits and the ring).
func radius_px() -> float:
	var ext := art.extent_m if art != null else size_m * 0.5
	return ext * screen_ppm * float(_style.num("marker.true_scale"))

func has_art() -> bool:
	return art != null and art.texture != null

func _draw() -> void:
	if has_art():
		return
	# The stand-in: an inked arrow along the heading, the unit's size.
	var r := maxf(6.0, size_m * 0.5 * screen_ppm)
	var f := Vector2(cos(screen_heading), sin(screen_heading))
	var s := Vector2(-f.y, f.x)
	var pts := PackedVector2Array([f * r, -f * r * 0.6 + s * r * 0.7, -f * r * 0.3, -f * r * 0.6 - s * r * 0.7])
	draw_colored_polygon(pts, accent)
	pts.append(pts[0])
	draw_polyline(pts, _fallback_ink, 1.2, true)
