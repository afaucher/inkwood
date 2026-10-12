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
const UnitSunk = preload("res://scripts/ui/unit_sunk.gd")

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
# DRAWN AT THE MAP'S SCALE (Track BB, the bridge): true makes the marker's drawn scale exactly the map's (k = 1, whatever the planes' rule
# is at this zoom), by keeping base_scale and draw_scale at 1 / marker.true_scale every pose. Set by the layer for a silhouette that
# UnitMarkerArt.is_map_scale names.
var map_scale: bool = false
# BELOW THE WATER'S SURFACE (Track BB, decision ship-sinks): a unit that has gone under is drawn intact under the water layer's own depth
# wash (UnitSunk): `sunk_amount` of the way to `sunk_color` (the map's step colour at its floor), 0 at or above the surface. Set by the layer
# each pose (set_sunk); a unit that is under has no shadow and no wake.
var sunk_amount: float = 0.0
var sunk_color := Color.WHITE
var ring: Dictionary = {}
var _shapes: Array = []        # UnitStandout.Shape nodes, in the layer's under node
var _under_parent: Node = null

var art: UnitMarkerArt.Art = null
var plane: Sprite2D
# A SHIP's ink V wake (Track SH, the warship): a sprite under the plane's, made when the art carries one and shown while the ship is
# under way (`underway`, set by the layer from the unit's speed: data unit_art.ship.underway_mps).
var wake: Sprite2D = null
var underway: bool = false
var shadow: Sprite2D           # lives in the layer's shadow group, not under this node
# The extra shadow copies of a boat's parts (Art.shadow_parts; Track BB), in the same group as `shadow`.
var _shadow_parent: Node = null
var _part_sprites: Array = []

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
var _scale_changed_ms: int = 0   # when the scale (the host's ppm or marker.true_scale) last changed: Time.get_ticks_msec()
var _art_deferred := false       # a rebake was put off (see _may_wait); set_pose asks again each frame until it is not
var _style: UiStyle
var _fallback_ink := Color.BLACK

func setup(style: RefCounted, id: String, silhouette_id: String, size: float, side_accent: Color, shadow_parent: Node, under_parent: Node = null) -> void:
	_style = style as UiStyle
	_under_parent = under_parent
	_shadow_parent = shadow_parent
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
	for s: Variant in _part_sprites:
		if is_instance_valid(s):
			(s as Node).queue_free()
	_part_sprites.clear()
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
	if map_scale:
		base_scale = 1.0 / maxf(_style.num("marker.true_scale"), 1e-6)
		draw_scale = base_scale
	var k: float = _style.num("marker.true_scale") * draw_scale
	# The art is baked for ppm x true_scale (x the stand-out scale, 1.0 unless
	# "larger" is on), so a change of ANY of them re-checks it
	# (the plane-size knob changes only true_scale: the art stayed blurry, or
	# coarse, until the next zoom).
	if absf(ppm - screen_ppm) > 1e-6 or k != _checked_k:
		screen_ppm = ppm
		_checked_k = k
		_scale_changed_ms = Time.get_ticks_msec()
		_ensure_art()
	elif art == null:
		_ensure_art()
	elif _art_deferred:
		_ensure_art()   # (the zoom has settled? the marker is back on screen? Cheap while the answer is still no)
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
		UnitSunk.apply(plane, sunk_color, sunk_amount)
		shadow.texture = art.mask
		shadow.offset = -art.origin
		shadow.rotation = sprite_rot
		shadow.scale = sc
		shadow.position = screen_pos + shadow_offset_px
		shadow.visible = visible and sunk_amount <= 0.0   # (under the water it casts none)
		_pose_wake(sc, sprite_rot)
		_pose_shadow_parts(sc, sprite_rot, screen_pos, shadow_offset_px)
	else:
		shadow.visible = false
		_pose_shadow_parts(Vector2.ONE, 0.0, screen_pos, shadow_offset_px)
		if wake != null:
			wake.visible = false
	_pose_shapes()
	queue_redraw()

# The layer tells the marker how far under the water it lies: `amount` of the way to the water's `color` (UnitSunk.wash), 0 at or above the surface.
func set_sunk(color: Color, amount: float) -> void:
	sunk_color = color
	sunk_amount = amount

# The wake sprite of a ship's art, posed as the plane is, shown while the ship is under way.
func _pose_wake(sc: Vector2, sprite_rot: float) -> void:
	if art == null or art.wake == null:
		if wake != null:
			wake.visible = false
		return
	if wake == null:
		wake = Sprite2D.new()
		wake.centered = false
		wake.name = "Wake"
		add_child(wake)
		move_child(wake, 0)   # under the plane's sprite
	wake.texture = art.wake
	wake.offset = -art.wake_origin
	wake.rotation = sprite_rot
	wake.scale = sc
	wake.visible = underway and sunk_amount <= 0.0

# A boat's extra shadow copies (Art.shadow_parts, Track BB): one sprite per copy, in the layer's shadow group, drawn like the marker's own
# shadow but lifted by its own height: the layer's offset is for the art's cast_height_m, so a copy at h metres is that x h / cast_height_m.
func _pose_shadow_parts(sc: Vector2, sprite_rot: float, screen_pos: Vector2, off: Vector2) -> void:
	var copies: Array = []
	if art != null and art.texture != null and art.cast_height_m > 0.0 and visible and sunk_amount <= 0.0:
		for part: Dictionary in art.shadow_parts:
			for h: Variant in (part["heights"] as Array):
				copies.append({"tex": part["tex"], "h": float(h)})
	while _part_sprites.size() < copies.size() and _shadow_parent != null:
		var spr := Sprite2D.new()
		spr.centered = false
		spr.name = "ShadowPart_%s_%d" % [unit_id, _part_sprites.size()]
		spr.modulate = shadow.modulate
		_shadow_parent.add_child(spr)
		_part_sprites.append(spr)
	for i in _part_sprites.size():
		var spr := _part_sprites[i] as Sprite2D
		if i >= copies.size():
			spr.visible = false
			continue
		var c: Dictionary = copies[i]
		spr.texture = c["tex"]
		spr.offset = -art.origin
		spr.rotation = sprite_rot
		spr.scale = sc
		spr.position = screen_pos + off * (float(c["h"]) / art.cast_height_m)
		spr.visible = true

# Hides (or shows again) the stand-out shapes with the marker: a marker the layer hides
# (fog, a unit that exploded) is not posed any more, so its shapes follow its visibility here.
func refresh_shapes() -> void:
	_pose_shapes()
	if not visible:
		for s: Variant in _part_sprites:
			(s as Sprite2D).visible = false

# Re-bake only when the host's scale has drifted past the data's ratio.
func _ensure_art() -> void:
	var want: float = screen_ppm * _style.num("marker.true_scale") * draw_scale
	var turn := screen_heading + PI / 2.0   # (only a static unit's art is baked for it)
	if art != null:
		var ratio := want / art.ppm
		var r: float = _style.num("unit_art.rebake_ratio")
		var turned: bool = art.screen_aligned and absf(angle_difference(art.rot, turn)) > 0.01
		if ratio <= r and ratio >= 1.0 / r and not turned:
			_art_deferred = false
			return
		if not turned and _may_wait(ratio):
			_art_deferred = true
			return
	_art_deferred = false
	var a: UnitMarkerArt.Art = UnitMarkerArt.art_for(_style, silhouette, accent, want, turn)
	if a != null:
		art = a

# May the rebake wait (builder CAM, 2026-10-11, decision playtest-3 zoom_judder; PROPOSED, data unit_art.rebake_settle_ms and its
# neighbours; 0 is the old behaviour)? Yes when the marker is well off the screen (nobody sees its art; it is baked when it comes into view),
# or when the scale is still changing and the art held is within unit_art.rebake_hard_ratio of the wanted one: it is drawn scaled meanwhile
# and baked once when the zoom has settled. A frame that baked every marker's art at every wheel notch froze for 40 to 180 ms.
func _may_wait(ratio: float) -> bool:
	var settle: float = _style.num("unit_art.rebake_settle_ms")
	if settle <= 0.0:
		return false
	if _off_screen():
		return true
	var hard: float = _style.num("unit_art.rebake_hard_ratio")
	if ratio > hard or ratio < 1.0 / hard:
		return false
	return Time.get_ticks_msec() - _scale_changed_ms < int(settle)

# Is the marker further than unit_art.rebake_offscreen_margin_px (plus its own radius) outside the screen it is drawn on?
func _off_screen() -> bool:
	if not is_inside_tree():
		return false
	var m: float = radius_px() + _style.num("unit_art.rebake_offscreen_margin_px")
	return not get_viewport_rect().grow(m).has_point(get_global_transform_with_canvas().origin)

# Has a rebake been put off (off screen, or the zoom still moving)? For tests and tools.
func is_art_deferred() -> bool:
	return _art_deferred

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
