extends RefCounted

# World metres <-> screen pixels, TAKEN FROM THE HOST. No UI piece holds a
# pixels-per-metre of its own: the map scale is an open question for Alex, and
# the map view (Track V) owns the camera. A host passes one of:
#
#   a Transform2D     world metres -> screen px (fixed until set_mapping again)
#   an Object         with world_to_screen(Vector2) -> Vector2 and
#                     screen_to_world(Vector2) -> Vector2 -- live: a camera that
#                     moves or zooms is followed every frame with no call
#   a UiMapping       (this) -- passed through
#
#   var m := UiMapping.from(host)
#   m.world_to_screen(Vector2(1500, 2400))   # px in the UI node's parent space
#   m.px_per_m(at)                           # the local scale, for sprite size
#   m.screen_angle(at, heading)              # a world heading as a screen angle
#
# "Screen" means the coordinate space of the node the UI is mounted in. Mount
# the UI's map layers in a screen-space parent (a CanvasLayer, or a Node2D with
# an identity canvas transform) so its ink lines stay true pixel widths at any
# zoom; the mapping does the zooming.

const PROBE_M := 100.0

var _xf := Transform2D.IDENTITY
var _inv := Transform2D.IDENTITY
var _host: Object = null

static func from(host: Variant) -> RefCounted:
	var m: RefCounted = load("res://scripts/ui/ui_mapping.gd").new()
	m.set_host(host)
	return m

func set_host(host: Variant) -> void:
	_host = null
	if host is Transform2D:
		_xf = host
		_inv = _xf.affine_inverse()
	elif host is Object and host != null and (host as Object).has_method("world_to_screen") \
			and (host as Object).has_method("screen_to_world"):
		if (host as Object).get_script() == get_script():
			_xf = host._xf
			_inv = host._inv
			_host = host._host
		else:
			_host = host
	else:
		push_error("UiMapping: a host mapping is a Transform2D or an object with world_to_screen/screen_to_world, got %s" % str(host))

func is_live() -> bool:
	return _host != null

func world_to_screen(p: Vector2) -> Vector2:
	if _host != null:
		return _host.world_to_screen(p)
	return _xf * p

func screen_to_world(p: Vector2) -> Vector2:
	if _host != null:
		return _host.screen_to_world(p)
	return _inv * p

# Screen pixels per world metre around `at` (the mean of the two axes, so a
# rotated or mildly anisotropic view still gets one scale).
func px_per_m(at: Vector2 = Vector2.ZERO) -> float:
	if _host == null:
		return sqrt(absf(_xf.determinant()))
	# A live host: finite differences over PROBE_M (float32 screen points lose
	# about a thousandth of a pixel; over 100 m that is noise).
	var o := world_to_screen(at)
	var ex := (world_to_screen(at + Vector2(PROBE_M, 0.0)) - o) / PROBE_M
	var ey := (world_to_screen(at + Vector2(0.0, PROBE_M)) - o) / PROBE_M
	return sqrt(absf(ex.cross(ey)))

# The screen angle of a world heading at `at` (heading 0 = world +x, positive
# clockwise on screen, as unit.gd defines it).
func screen_angle(at: Vector2, heading: float) -> float:
	var dir := Vector2(cos(heading), sin(heading))
	if _host == null:
		return _xf.basis_xform(dir).angle()
	return (world_to_screen(at + dir * PROBE_M) - world_to_screen(at)).angle()

# A world-space offset (metres) as a screen-space offset (px) at `at`.
func screen_delta(at: Vector2, d: Vector2) -> Vector2:
	if _host == null:
		return _xf.basis_xform(d)
	return world_to_screen(at + d) - world_to_screen(at)
