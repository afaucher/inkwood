extends Node2D

# THE TARGET RING (Track A, PROPOSED): the mission's objective drawn on the map -- a
# dashed inked ring of the capture radius round the target point, a cross at its
# centre and the word TARGET under it. The players are told where the target is (that
# is what makes it a race: shoot the bomber down before it reaches the ring); the enemy's
# route is never drawn. It is drawn in screen space through the map host's transform,
# like SandboxTracks, so its ink is a true pixel width at any zoom; and above the fog,
# because the players know where their own target is.
#
#   var obj := SandboxObjective.new()
#   mount.add_child(obj)
#   obj.setup(map_view, style, Vector2(3600, 3900), 300.0)     # metres

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiInk = preload("res://scripts/ui/ui_ink.gd")

const MIN_RADIUS_PX := 9.0
const LABEL := "TARGET"

var host: Node2D = null
var style: UiStyle = null
var point_m := Vector2.ZERO
var radius_m := 300.0

func setup(host_view: Node2D, st: RefCounted, target_m: Vector2, radius: float) -> void:
	host = host_view
	style = st as UiStyle
	point_m = target_m
	radius_m = radius
	name = "Objective"
	queue_redraw()

func _process(_delta: float) -> void:
	queue_redraw()   # the camera moves; the drawing is a ring and a word

# Where the ring's centre is on screen, and its radius in px (never under MIN_RADIUS_PX).
func screen_ring() -> Dictionary:
	if host == null:
		return {}
	var xf: Transform2D = host.get_global_transform_with_canvas()
	var ppm: float = host.px_per_m
	var c: Vector2 = xf * (point_m * ppm)
	var r: float = maxf(radius_m * ppm * xf.get_scale().x, MIN_RADIUS_PX)
	return {"centre": c, "radius_px": r}

func _draw() -> void:
	if host == null or style == null:
		return
	var ring := screen_ring()
	var c: Vector2 = ring["centre"]
	var r: float = ring["radius_px"]
	var ink: Color = style.color("ink")
	var soft: Color = style.color("ink_soft")
	# The ring: dashes, inked, with a fine ring just inside it.
	UiInk.dashed(self, UiInk.circle_pts(c, r, 72) + PackedVector2Array([c + Vector2(r, 0.0)]), Color(ink.r, ink.g, ink.b, 0.85), 1.8, 14.0, 7.0)
	UiInk.dashed(self, UiInk.circle_pts(c, r * 0.94, 72) + PackedVector2Array([c + Vector2(r * 0.94, 0.0)]), Color(soft.r, soft.g, soft.b, 0.45), 0.8, 6.0, 6.0)
	# The cross at the target point.
	var k := clampf(r * 0.22, 5.0, 14.0)
	UiInk.ink_line(self, PackedVector2Array([c + Vector2(-k, 0.0), c + Vector2(k, 0.0)]), false, ink, 1.8, 3, 0.4)
	UiInk.ink_line(self, PackedVector2Array([c + Vector2(0.0, -k), c + Vector2(0.0, k)]), false, ink, 1.8, 5, 0.4)
	# The word, under the ring.
	var font: Font = style.font(true)
	var px: float = style.num("fonts.detail_px")
	var w := UiInk.text_width(font, LABEL, px)
	UiInk.text(self, font, Vector2(c.x - w * 0.5, c.y + r + px + 4.0), LABEL, px, Color(ink.r, ink.g, ink.b, 0.9))
