extends Node

# THE CAMERA CONTROLLER, first option (Track F, exit criterion 7): pan (drag
# and keys), wheel zoom about the cursor, a hard zoom range, follow-selected-
# unit and frame-this-plan. Every number is in data/view/camera.json, all
# proposed.
#
# It DRIVES A Camera2D IT IS GIVEN (Track V's MapView has its own; the
# controller never makes one inside it):
#
#   var ctl := CameraController.new()
#   ctl.setup(terrain.map_rect_px(), terrain.px_per_m)      # or setup_from_terrain(terrain)
#   ctl.bind(map_view_camera)                               # takes over its position and zoom
#   some_node.add_child(ctl)                                # anywhere in the camera's viewport
#   ctl.follow_unit(world, "light_fighter_1")               # or follow(func() -> Variant: ...)
#   ctl.frame_plan(world, "light_fighter_1")                # fit its planned curve
#   ctl.world_to_screen(Vector2(x_m, y_m))                  # metres <-> screen px: the
#   ctl.screen_to_world(screen_px)                          #   host Track U's UiMapping takes
#
# bind() sets what the maths below needs on the camera: anchor DRAG_CENTER,
# no offset, no position smoothing, no Camera2D limits (the clamps are ours),
# rotation ignored. From then on the controller owns the camera's position and
# zoom; anything else that moves the camera should go through set_view().
#
# SPACES. The camera's parent space is MAP PX: world metres x px_per_m (data/
# terrain/terrain.json scale.px_per_m; read, never assumed), the space Track
# V's MapView draws its chunks in. Zoom is Camera2D's: screen px per map px,
# uniform. "Screen" is the camera's viewport's pixels.
#
# THE SCALE IS A LIVE KNOB (Alex, 2026-10-09: px_per_m 1, 2, 3 or 4 at run
# time). set_scale(map_px, ppm) -- or nothing, when the controller was set up
# from a Terrain: it watches terrain.px_per_m each frame -- keeps the view on
# the same point in METRES and keeps the ZOOM, because the render's detail
# (trees, linework) is drawn in map px at any scale: what changes is how many
# metres the same-looking view covers. Limits in metres (pan.map_margin_m) and
# the fit_map zoom-out limit follow; zoom.max and far_zoom stay in map px.
#
# INPUT (_unhandled_input, so the roster and the planner see events first).
# THE LEFT BUTTON IS TRACK U'S (click and drag inside a plane's fan plans its
# motion): the controller never pans on it. Wheel and trackpad magnify zoom
# about the cursor; the drag buttons (data: middle, right) and a trackpad pan
# drag the map; held keys (data: WASD and arrows, Q/E and -/=) pan at a
# screen speed and zoom about the view centre. A manual pan stops following
# (follow.break_on_pan).
#
# FAR ZOOM (far_zoom.mode, proposed "overview_topo"): overview_amount() is how
# much of the topographic overview should show at the current zoom (0..1);
# the fog layer reads it. In "full_render" mode it is always 0 and the hard
# zoom-out limit rises to far_zoom.full_render_min_zoom (Alex: "may limit
# zoom-out and have players scroll the map").

signal view_changed

const CameraData = preload("res://scripts/world/camera_data.gd")
const TERRAIN_PATH := "res://data/terrain/terrain.json"

const FAR_OVERVIEW := "overview_topo"
const FAR_FULL := "full_render"
const _BUTTONS := {"middle": MOUSE_BUTTON_MIDDLE, "right": MOUSE_BUTTON_RIGHT}
const _KEY_ACTIONS := ["left", "right", "up", "down", "zoom_in", "zoom_out"]

var data: CameraData
var errors: Array[String] = []
var px_per_m: float = NAN
var map_rect_px := Rect2()
var camera: Camera2D = null
var terrain: Object = null        # when set up from a Terrain: its px_per_m is watched

var zoom_min_spec: Variant        # "fit_map" or a number
var fit_margin: float
var zoom_max: float
var zoom_start: float
var wheel_step: float
var keys_zoom_rate: float
var pan_keys_speed: float
var trackpad_px: float
var drag_buttons: Array[int] = []
var key_codes: Dictionary = {}    # action -> Array[int] of physical keycodes
var map_margin_px: float
var follow_rate: float
var break_on_pan: bool
var frame_margin: float
var frame_max_zoom: float
var insets := {"left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0}
var far_mode: String
var topo_below: float
var full_above: float
var full_render_min: float

# Tests and offscreen use: the view size to assume instead of the viewport's.
var viewport_size_override := Vector2.ZERO
# Input handling can be switched off by a host that drives the camera itself.
var input_enabled := true

var _follow: Callable = Callable()
var _drag_button := -1

# The map in map px and the scale (map px per metre). `cam_data` defaults to
# data/view/camera.json.
func setup(map_px: Rect2, ppm: float, cam_data: CameraData = null) -> void:
	data = cam_data if cam_data != null else CameraData.new(CameraData.CAMERA_PATH)
	map_rect_px = map_px
	px_per_m = ppm
	if not (ppm > 0.0):
		_err("px_per_m must be positive, got %s" % ppm)
	_load()

func setup_from_terrain(t: Object, cam_data: CameraData = null) -> void:
	terrain = t
	setup(t.map_rect_px(), t.px_per_m, cam_data)

# A new scale (map px per metre) and the map's rect in the new map px. Keeps
# the view centred on the same metres and keeps the zoom (see the header).
func set_scale(map_px: Rect2, ppm: float) -> void:
	if not (ppm > 0.0):
		_err("px_per_m must be positive, got %s" % ppm)
		return
	var centre_m := camera.position / px_per_m if camera != null else Vector2.ZERO
	px_per_m = ppm
	map_rect_px = map_px
	map_margin_px = data.num("pan.map_margin_m") * px_per_m
	if camera != null:
		set_view(centre_m * px_per_m, camera.zoom.x)

# data/terrain/terrain.json scale.px_per_m, for a host with no Terrain at hand.
static func terrain_px_per_m() -> float:
	return CameraData.new(TERRAIN_PATH).num("scale.px_per_m")

# Take over `cam`: the settings the maths needs, then the start view (the map
# centre at zoom.start) unless `keep_view`.
func bind(cam: Camera2D, keep_view: bool = false) -> void:
	camera = cam
	cam.anchor_mode = Camera2D.ANCHOR_MODE_DRAG_CENTER
	cam.offset = Vector2.ZERO
	cam.ignore_rotation = true
	cam.position_smoothing_enabled = false
	cam.rotation_smoothing_enabled = false
	cam.limit_enabled = false
	if keep_view:
		set_view(cam.position, cam.zoom.x)
	else:
		set_view(map_rect_px.get_center(), zoom_start)

func ok() -> bool:
	return errors.is_empty() and data != null and data.ok()

func _err(message: String) -> void:
	errors.append(message)
	push_error("CameraController: " + message)

func _load() -> void:
	zoom_min_spec = data.value("zoom.min")
	if not (zoom_min_spec is float or zoom_min_spec is int or (zoom_min_spec is String and zoom_min_spec == "fit_map")):
		_err("zoom.min must be a number or 'fit_map', got %s" % str(zoom_min_spec))
		zoom_min_spec = "fit_map"
	fit_margin = data.num("zoom.fit_margin")
	zoom_max = data.num("zoom.max")
	zoom_start = data.num("zoom.start")
	wheel_step = data.num("zoom.wheel_step")
	keys_zoom_rate = data.num("zoom.keys_step_per_s")
	pan_keys_speed = data.num("pan.keys_px_per_s")
	trackpad_px = data.num("pan.trackpad_px_per_unit")
	for b: Variant in data.list("pan.drag_buttons"):
		if _BUTTONS.has(str(b)):
			drag_buttons.append(_BUTTONS[str(b)])
		else:
			_err("pan.drag_buttons: '%s' is not one of %s (the left button is the planner's)" % [str(b), _BUTTONS.keys()])
	var keys: Dictionary = data.dict("pan.keys")
	for action: String in _KEY_ACTIONS:
		var codes: Array[int] = []
		for name: Variant in keys.get(action, []):
			var code := OS.find_keycode_from_string(str(name))
			if code == KEY_NONE:
				_err("pan.keys.%s: '%s' is not a key name" % [action, str(name)])
			else:
				codes.append(code)
		key_codes[action] = codes
	map_margin_px = data.num("pan.map_margin_m") * px_per_m
	follow_rate = data.num("follow.smoothing_per_s")
	break_on_pan = data.flag("follow.break_on_pan")
	frame_margin = data.num("frame.margin_px")
	frame_max_zoom = data.num("frame.max_zoom")
	var ins: Dictionary = data.dict("frame.insets_px")
	for side: String in insets:
		insets[side] = float(ins.get(side, 0.0))
	far_mode = data.text("far_zoom.mode")
	if far_mode != FAR_OVERVIEW and far_mode != FAR_FULL:
		_err("far_zoom.mode must be '%s' or '%s', not '%s'" % [FAR_OVERVIEW, FAR_FULL, far_mode])
	topo_below = data.num("far_zoom.topo_below_zoom")
	full_above = data.num("far_zoom.full_above_zoom")
	full_render_min = data.num("far_zoom.full_render_min_zoom")
	if not (topo_below < full_above):
		_err("far_zoom.topo_below_zoom must be below full_above_zoom")
	if not (wheel_step > 1.0):
		_err("zoom.wheel_step must be above 1")

# --- the view ---------------------------------------------------------------------

func view_size() -> Vector2:
	if viewport_size_override != Vector2.ZERO:
		return viewport_size_override
	return camera.get_viewport_rect().size

func zoom_level() -> float:
	return camera.zoom.x

func center() -> Vector2:
	return camera.position

# The hard zoom-out limit: the whole map in the view ("fit_map"), a number, or
# in "full_render" far mode far_zoom.full_render_min_zoom. Never above zoom_max.
func zoom_limit_min() -> float:
	var z: float
	if far_mode == FAR_FULL:
		z = full_render_min
	elif zoom_min_spec is String:
		var v := view_size()
		z = minf(v.x / maxf(map_rect_px.size.x, 1.0), v.y / maxf(map_rect_px.size.y, 1.0)) / fit_margin
	else:
		z = float(zoom_min_spec)
	return minf(z, zoom_max)

func clamp_zoom(z: float) -> float:
	return clampf(z, zoom_limit_min(), zoom_max)

# Sets centre (map px) and zoom, clamped: zoom to the range, the centre to the
# map grown by pan.map_margin_m.
func set_view(c: Vector2, z: float) -> void:
	var zz := clamp_zoom(z)
	var lim := map_rect_px.grow(map_margin_px)
	var cc := Vector2(clampf(c.x, lim.position.x, lim.end.x), clampf(c.y, lim.position.y, lim.end.y))
	if cc == camera.position and zz == camera.zoom.x:
		return
	camera.position = cc
	camera.zoom = Vector2(zz, zz)
	view_changed.emit()

# --- transforms ---------------------------------------------------------------------

func world_px_to_screen(p: Vector2) -> Vector2:
	return (p - camera.position) * camera.zoom.x + view_size() * 0.5

func screen_to_world_px(s: Vector2) -> Vector2:
	return (s - view_size() * 0.5) / camera.zoom.x + camera.position

# Metres, for the sim and the UI (Track U's UiMapping host contract).
func world_to_screen(p_m: Vector2) -> Vector2:
	return world_px_to_screen(p_m * px_per_m)

func screen_to_world(s: Vector2) -> Vector2:
	return screen_to_world_px(s) / px_per_m

# The map-px rectangle the view shows.
func visible_rect_px() -> Rect2:
	return Rect2(screen_to_world_px(Vector2.ZERO), view_size() / camera.zoom.x)

# --- zoom and pan ----------------------------------------------------------------------

# Zoom to `z` keeping the map point under `anchor` (screen px) where it is.
func zoom_at(z: float, anchor: Vector2) -> void:
	var w := screen_to_world_px(anchor)
	var zz := clamp_zoom(z)
	set_view(w - (anchor - view_size() * 0.5) / zz, zz)

func zoom_by(factor: float, anchor: Vector2) -> void:
	zoom_at(camera.zoom.x * factor, anchor)

# Drag the map by `delta` screen px (the map follows the pointer).
func pan_screen(delta: Vector2) -> void:
	if delta == Vector2.ZERO:
		return
	if break_on_pan:
		stop_follow()
	set_view(camera.position - delta / camera.zoom.x, camera.zoom.x)

# --- follow --------------------------------------------------------------------------

# Follow whatever `getter` returns each frame: a Vector2 in METRES, or null to
# hold still (the unit is gone). The resolve animation passes a getter on
# World.sample; follow_unit follows the unit's current state.
func follow(getter: Callable) -> void:
	_follow = getter

func follow_unit(world: Object, unit_id: String) -> void:
	follow(func() -> Variant:
		var u: Object = world.units.get(unit_id)
		return Vector2(u.x, u.y) if u != null else null)

func stop_follow() -> void:
	_follow = Callable()

func is_following() -> bool:
	return _follow.is_valid()

# --- framing -------------------------------------------------------------------------------

func set_insets(left: float, top: float, right: float, bottom: float) -> void:
	insets = {"left": left, "top": top, "right": right, "bottom": bottom}

# The screen rectangle framing fits into: the view minus the HUD insets and the margin.
func frame_rect() -> Rect2:
	var v := view_size()
	var r := Rect2(insets.left, insets.top, v.x - insets.left - insets.right, v.y - insets.top - insets.bottom)
	return r.grow(-frame_margin)

# Fit every point (METRES: Vector2 or {x, y}) into frame_rect(), zooming in no
# further than frame.max_zoom. Returns whether every point ended up inside
# (false when even the zoom-out limit cannot hold them).
func frame_points(points_m: Array) -> bool:
	if points_m.is_empty():
		return false
	var box := Rect2(_pt(points_m[0]) * px_per_m, Vector2.ZERO)
	for p: Variant in points_m:
		box = box.expand(_pt(p) * px_per_m)
	var fr := frame_rect()
	var z := minf(frame_max_zoom, zoom_max)
	if box.size.x > 0.0:
		z = minf(z, fr.size.x / box.size.x)
	if box.size.y > 0.0:
		z = minf(z, fr.size.y / box.size.y)
	z = clamp_zoom(z)
	set_view(box.get_center() - (fr.get_center() - view_size() * 0.5) / z, z)
	for p: Variant in points_m:
		if not fr.grow(0.5).has_point(world_to_screen(_pt(p))):
			return false
	return true

# Frame a unit's planned curve this turn: where it is now and every planned
# step (World.planned_states, explicit and "carry on" steps alike).
func frame_plan(world: Object, unit_id: String) -> bool:
	var u: Object = world.units.get(unit_id)
	if u == null:
		return false
	var pts: Array = [Vector2(u.x, u.y)]
	for s: Dictionary in world.planned_states(unit_id):
		pts.append(Vector2(float(s["x"]), float(s["y"])))
	stop_follow()
	return frame_points(pts)

static func _pt(p: Variant) -> Vector2:
	if p is Vector2:
		return p
	return Vector2(float(p["x"]), float(p["y"]))

# --- far zoom ---------------------------------------------------------------------------------

# How much of the topographic overview shows at the current zoom: 1 at or below
# far_zoom.topo_below_zoom, 0 at or above full_above_zoom, smooth between; 0
# always in "full_render" mode.
func overview_amount() -> float:
	return overview_amount_for(far_mode, topo_below, full_above, camera.zoom.x)

static func overview_amount_for(mode: String, below: float, above: float, z: float) -> float:
	if mode != FAR_OVERVIEW:
		return 0.0
	return 1.0 - smoothstep(below, above, z)

# --- input ------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled or data == null or camera == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var notches := mb.factor if mb.factor > 0.0 else 1.0
			var f := pow(wheel_step, notches)
			zoom_by(f if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / f, mb.position)
			_handled()
		elif drag_buttons.has(mb.button_index):
			if mb.pressed:
				_drag_button = mb.button_index
			elif _drag_button == mb.button_index:
				_drag_button = -1
			_handled()
	elif event is InputEventMouseMotion and _drag_button != -1:
		pan_screen((event as InputEventMouseMotion).relative)
		_handled()
	elif event is InputEventMagnifyGesture:
		var mg := event as InputEventMagnifyGesture
		zoom_by(mg.factor, mg.position)
		_handled()
	elif event is InputEventPanGesture:
		pan_screen(-(event as InputEventPanGesture).delta * trackpad_px)
		_handled()

func _handled() -> void:
	if is_inside_tree():
		get_viewport().set_input_as_handled()

func _held(action: String) -> bool:
	for code: int in key_codes.get(action, []):
		if Input.is_physical_key_pressed(code):
			return true
	return false

func _process(delta: float) -> void:
	if data == null or camera == null:
		return
	if terrain != null and terrain.px_per_m != px_per_m:
		set_scale(terrain.map_rect_px(), terrain.px_per_m)
	if input_enabled:
		var dir := Vector2(float(_held("right")) - float(_held("left")), float(_held("down")) - float(_held("up")))
		if dir != Vector2.ZERO:
			pan_screen(-dir.normalized() * pan_keys_speed * delta)
		var zdir := float(_held("zoom_in")) - float(_held("zoom_out"))
		if zdir != 0.0:
			zoom_by(pow(keys_zoom_rate, zdir * delta), view_size() * 0.5)
	step_follow(delta)

# One follow step of `delta` seconds (called every frame; public for tests).
func step_follow(delta: float) -> void:
	if not _follow.is_valid():
		return
	var target: Variant = _follow.call()
	if target is Vector2:
		var t: Vector2 = (target as Vector2) * px_per_m
		var c := t if follow_rate <= 0.0 else camera.position.lerp(t, 1.0 - exp(-follow_rate * delta))
		set_view(c, camera.zoom.x)
