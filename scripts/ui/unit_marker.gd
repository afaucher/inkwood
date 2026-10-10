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
# A STATIC UNIT (the anti-aircraft battery, the radio tower; Track U3): its art is baked already
# turned by its heading (Art.screen_aligned), so the sprite and its shadow are NOT rotated here, and
# its shadow mask is the part's cast shadow (a tower's is long), not a footprint offset by height.
#
# A unit whose silhouette has no baked art (headless runs, a type the sheet
# cannot draw yet) still gets a marker: a small inked arrow from _draw, so
# every unit is on screen (exit criterion 6).

const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitStandout = preload("res://scripts/ui/unit_standout.gd")

var unit_id: String = ""
var silhouette: String = ""
var size_m: float = 10.0
var accent := Color.BLACK
var selected: bool = false

# THE STAND-OUT SWITCH (Track U1, data: marker.standout; unit_standout.gd). `own`
# is set by the layer (a player-controlled unit); `draw_scale` is the plane's
# drawn-size multiplier (1.0 unless the "larger" mode is on and the unit is
# own); `ring` is the side ring the layer draws under the plane (empty: none).
# With the default mode "none" nothing below is built and every number is
# today's.
var own: bool = false
var draw_scale: float = 1.0
# The marker's OWN drawn-size multiplier on top of the plane rule (marker.true_scale): 1.0 for a plane or
# a tank, data marker.static_scale for a static unit (the tower, a battery: Track U3), so the target and
# the flak read at the planning zoom. draw_scale carries it (and the stand-out's, for an own plane).
var base_scale: float = 1.0
var ring: Dictionary = {}
var _shapes: Array = []        # UnitStandout.Shape nodes, in the layer's under node
var _under_parent: Node = null

var art: UnitMarkerArt.Art = null
var plane: Sprite2D
var shadow: Sprite2D           # lives in the layer's shadow group, not under this node

var screen_ppm: float = 1.0    # the host's px per metre where the unit is
var screen_heading: float = 0.0
# A plane falling out of control rocks and slowly spins (data combat.fall, PROPOSED): extra
# rotation in radians on the sprite, its shadow and the stand-out shapes -- not on the unit's
# heading, which the ring, the trails and the cones read.
var wobble: float = 0.0
# The shadow's screen offset the layer last gave set_pose: the altitude cue, readable even where
# there is no baked art to place the shadow sprite (a headless run).
var shadow_offset := Vector2.ZERO
var _checked_k: float = -1.0   # the marker.true_scale the art was last checked against
var _style: UiStyle
var _fallback_ink := Color.BLACK

func setup(style: RefCounted, id: String, silhouette_id: String, size: float, side_accent: Color, shadow_parent: Node, under_parent: Node = null) -> void:
	_style = style as UiStyle
	_under_parent = under_parent
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
	_clear_shapes()

# Applies a UnitStandout spec (parse()): builds or drops the shapes under the
# plane, sets the ring and the drawn-size multiplier. Only a player-controlled
# unit takes any of it. A spec with nothing in it leaves the marker exactly as
# it was before the switch existed.
func set_standout(spec: Dictionary) -> void:
	_clear_shapes()
	if own and _under_parent != null:
		for s: Dictionary in spec["shapes"]:
			var node := UnitStandout.Shape.new()
			node.setup(s)
			_under_parent.add_child(node)
			_shapes.append(node)
	ring = (spec["ring"] as Dictionary) if own else {}
	# The drawn size takes effect at the next set_pose (k changes, so the art is looked at again).
	draw_scale = (float(spec["scale"]) if own else 1.0) * base_scale
	_pose_shapes()

func _clear_shapes() -> void:
	for n: Variant in _shapes:
		if is_instance_valid(n):
			(n as Node).queue_free()
	_shapes.clear()

func _pose_shapes() -> void:
	if _shapes.is_empty():
		return
	var show := visible and art != null and art.mask != null
	var rot := screen_heading + PI / 2.0 + wobble
	var sc := Vector2.ZERO
	if art != null:
		sc = Vector2.ONE * (screen_ppm * _style.num("marker.true_scale") * draw_scale / art.ppm)
	for n: Variant in _shapes:
		var shape := n as UnitStandout.Shape
		shape.visible = show
		if show:
			shape.pose(position, rot, sc.x, art.mask, art.origin, art.extent_m * art.ppm)

# Pose the marker: screen position of the unit, the screen angle of its
# heading, the host's px per metre there, and the shadow's screen offset. `wobble_rad`
# turns the drawn plane (and its shadow) off its heading; 0 for a plane under control.
func set_pose(screen_pos: Vector2, heading_screen: float, ppm: float, shadow_offset_px: Vector2, wobble_rad: float = 0.0) -> void:
	position = screen_pos
	screen_heading = heading_screen
	wobble = wobble_rad
	shadow_offset = shadow_offset_px
	var k: float = _style.num("marker.true_scale") * draw_scale
	# The art is baked for ppm x true_scale (x the stand-out scale, 1.0 unless
	# "larger" is on), so a change of ANY of them re-checks it
	# (the plane-size knob changes only true_scale: the art stayed blurry, or
	# coarse, until the next zoom).
	if absf(ppm - screen_ppm) > 1e-6 or k != _checked_k:
		screen_ppm = ppm
		_checked_k = k
		_ensure_art()
	elif art == null:
		_ensure_art()
	elif art.screen_aligned and absf(angle_difference(art.rot, heading_screen + PI / 2.0)) > 0.01:
		_ensure_art()   # a static unit turned (the camera or the unit): baked again for the new angle
	var rot := heading_screen + PI / 2.0 + wobble_rad  # the art's nose points to -y
	if art != null and art.texture != null:
		var sc := Vector2.ONE * (screen_ppm * k / art.ppm)
		var sprite_rot := 0.0 if art.screen_aligned else rot   # (a static unit is baked turned)
		plane.texture = art.texture
		plane.offset = -art.origin
		plane.rotation = sprite_rot
		plane.scale = sc
		shadow.texture = art.mask
		shadow.offset = -art.origin
		shadow.rotation = sprite_rot
		shadow.scale = sc
		shadow.position = screen_pos + shadow_offset_px
		shadow.visible = visible
	else:
		shadow.visible = false
	_pose_shapes()
	queue_redraw()

# Hides (or shows again) the stand-out shapes with the marker: a marker the layer hides
# (fog, a unit that exploded) is not posed any more, so its shapes follow its visibility here.
func refresh_shapes() -> void:
	_pose_shapes()

# Re-bake only when the host's scale has drifted past the data's ratio.
func _ensure_art() -> void:
	var want: float = screen_ppm * _style.num("marker.true_scale") * draw_scale
	var turn := screen_heading + PI / 2.0   # (only a static unit's art is baked for it)
	if art != null:
		var ratio := want / art.ppm
		var r: float = _style.num("unit_art.rebake_ratio")
		if ratio <= r and ratio >= 1.0 / r and not (art.screen_aligned and absf(angle_difference(art.rot, turn)) > 0.01):
			return
	var a: UnitMarkerArt.Art = UnitMarkerArt.art_for(_style, silhouette, accent, want, turn)
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
	return ext * screen_ppm * float(_style.num("marker.true_scale")) * draw_scale

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
