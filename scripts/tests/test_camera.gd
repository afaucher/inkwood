extends "res://scripts/test_support/test_case.gd"

# Track F's camera controller (scripts/world/camera_controller.gd), headless,
# driving a plain Camera2D in a 1280 x 720 SubViewport -- the way it will drive
# Track V's MapView camera.
#
#   DATA     data/view/camera.json parses and every field is read (unused()
#            is empty); every key name resolves; the left button is never a
#            drag button (Track U's planner owns it).
#   CLAMPS   zoom stops at zoom.max and at the zoom-out limit; "fit_map" puts
#            the whole map in view at the limit; far_zoom "full_render" raises
#            the limit to full_render_min_zoom; the centre stays within the
#            map plus pan.map_margin_m.
#   CURSOR   zoom about the cursor keeps the map point under the cursor (by
#            zoom_at and by a wheel event), and the controller's transform is
#            the one the engine's Camera2D actually applies (the viewport's
#            canvas transform, after a frame).
#   PAN      a drag (middle or right button) moves the map with the pointer; a
#            left drag does nothing; a pan stops following.
#   FRAME    frame_plan fits every planned point of a unit's turn inside the
#            framing rectangle (with and without a HUD inset), no closer than
#            frame.max_zoom; a set too big for the zoom-out limit reports false.
#   FOLLOW   following eases toward the unit and snaps with smoothing 0.
#   FAR      overview_amount is 1 below topo_below_zoom, 0 above
#            full_above_zoom, 0 always in "full_render" mode.

const Terrain = preload("res://scripts/world/terrain.gd")
const World = preload("res://scripts/sim/world.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")
const CameraController = preload("res://scripts/world/camera_controller.gd")

const SEED := 20261009
const SIZE := Vector2i(1280, 720)

var _terrain: Terrain
var _vp: SubViewport
var _cam2d: Camera2D
var _ctl: CameraController
var _frames := 0
var _anchor := Vector2(900.0, 210.0)
var _anchor_world := Vector2.ZERO

func setup(_main) -> void:
	timeout_seconds = 60.0
	_terrain = Terrain.new(SEED)
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.disable_3d = true
	add_child(_vp)
	_ctl = _make()
	if not check(_ctl.ok(), "the controller loads cleanly: %s %s" % [_ctl.errors, _ctl.data.errors]):
		finish()
		return
	_data()
	_clamps()
	_cursor()
	_pan()
	_frame()
	_follow()
	_far()
	_scale_knob()
	# The last check needs a drawn frame: the engine's canvas transform.
	_ctl.set_view(_at(0.45, 0.55), 0.4)
	_ctl.zoom_at(0.9, _anchor)
	_anchor_world = _ctl.screen_to_world_px(_anchor)

# A fresh Camera2D and controller (the previous pair is freed).
func _make(cam_data: CameraData = null) -> CameraController:
	for n: Node in [_ctl, _cam2d]:
		if n != null:
			_vp.remove_child(n)
			n.free()
	_ctl = null
	_cam2d = Camera2D.new()
	_vp.add_child(_cam2d)
	_cam2d.make_current()
	var c := CameraController.new()
	c.setup_from_terrain(_terrain, cam_data)
	c.bind(_cam2d)
	c.input_enabled = true
	_vp.add_child(c)
	return c

# A point of the map in map px, by fractions of its width and height (the map's
# size in px depends on px_per_m, which is data).
func _at(fx: float, fy: float) -> Vector2:
	var m := _terrain.map_rect_px()
	return m.position + m.size * Vector2(fx, fy)

# --- data -------------------------------------------------------------------------

func _data() -> void:
	var unused := _ctl.data.unused()
	check(unused.is_empty(), "every field of camera.json is read; unused: %s" % [unused])
	print("[camera] camera.json: %d fields read, %d unused" % [_ctl.data._used.size(), unused.size()])
	for action: String in _ctl.key_codes:
		check(not (_ctl.key_codes[action] as Array).is_empty(), "pan.keys.%s names real keys" % action)
	check(not _ctl.drag_buttons.has(MOUSE_BUTTON_LEFT), "the left button never drags the map (Track U's planner owns it)")
	var d := CameraData.new(CameraData.CAMERA_PATH)
	d.root["pan"]["drag_buttons"]["value"] = ["left", "middle"]
	var bad := CameraController.new()
	bad.setup_from_terrain(_terrain, d)
	check(not bad.errors.is_empty() and not bad.drag_buttons.has(MOUSE_BUTTON_LEFT), "a data file naming the left button is an error, and the button is not bound")
	bad.free()
	near(CameraController.terrain_px_per_m(), _terrain.px_per_m, 0.0, "px_per_m is read from data/terrain/terrain.json")
	check(_cam2d.anchor_mode == Camera2D.ANCHOR_MODE_DRAG_CENTER and not _cam2d.position_smoothing_enabled, "bind() sets the camera up for the controller's maths")

# --- clamps -------------------------------------------------------------------------

func _clamps() -> void:
	var c := _terrain.map_rect_px().get_center()
	_ctl.set_view(c, 1000.0)
	near(_ctl.zoom_level(), _ctl.zoom_max, 1e-6, "zoom stops at zoom.max")
	_ctl.set_view(c, 1e-6)
	var lo := _ctl.zoom_limit_min()
	near(_ctl.zoom_level(), lo, 1e-6 * lo, "zoom stops at the zoom-out limit")
	var fit := minf(SIZE.x / _ctl.map_rect_px.size.x, SIZE.y / _ctl.map_rect_px.size.y) / _ctl.fit_margin
	near(lo, fit, 1e-9, "'fit_map': the limit is the whole map in the view / fit_margin")
	var vis := _ctl.visible_rect_px()
	check(vis.encloses(_ctl.map_rect_px), "at the zoom-out limit the whole map is in view (%s holds %s)" % [vis, _ctl.map_rect_px])
	print("[camera] zoom range %.4f .. %.2f (fit_map at %s px/m, %d x %d view); the whole %.0f m map spans %.0f px" % [lo, _ctl.zoom_max, _terrain.px_per_m, SIZE.x, SIZE.y, _terrain.map_w, _ctl.map_rect_px.size.y * lo])
	_ctl.set_view(Vector2(-1e6, 1e6), 0.5)
	var lim := _ctl.map_rect_px.grow(_ctl.map_margin_px)
	near(_ctl.center().x, lim.position.x, 1e-3, "the centre stops at the map's west edge plus the margin")
	near(_ctl.center().y, lim.end.y, 1e-3, "the centre stops at the map's south edge plus the margin")

	var d := CameraData.new(CameraData.CAMERA_PATH)
	d.root["far_zoom"]["mode"]["value"] = "full_render"
	_ctl = _make(d)
	_ctl.set_view(c, 1e-6)
	near(_ctl.zoom_level(), d.num("far_zoom.full_render_min_zoom"), 1e-6, "'full_render': the zoom-out limit is full_render_min_zoom")
	near(_ctl.overview_amount(), 0.0, 0.0, "'full_render': no overview at any zoom")
	_ctl = _make()

# --- zoom about the cursor --------------------------------------------------------------

func _cursor() -> void:
	var worst := 0.0
	var steps := 0
	var clamped := 0
	for start: Array in [[_at(0.5, 0.5), 0.35], [_at(0.3, 0.7), 1.0], [_at(0.6, 0.4), 0.2], [_at(0.5, 0.45), 0.08]]:
		for anchor: Vector2 in [Vector2(0.0, 0.0), Vector2(1280.0, 720.0), Vector2(200.0, 600.0), Vector2(640.0, 360.0), Vector2(1100.0, 90.0)]:
			for f: float in [1.15, 1.0 / 1.15, 3.0, 0.3]:
				_ctl.set_view(start[0], start[1])
				var before := _ctl.screen_to_world_px(anchor)
				var z0 := _ctl.zoom_level()
				var z1 := _ctl.clamp_zoom(z0 * f)
				var want := before - (anchor - Vector2(SIZE) * 0.5) / z1
				_ctl.zoom_by(f, anchor)
				if _ctl.zoom_level() == z0 or _ctl.center().distance_to(want) > 0.01 * maxf(1.0, want.length() * 1e-6):
					clamped += 1   # zoom or centre clamped: the point may move, by design
					continue
				worst = maxf(worst, _ctl.screen_to_world_px(anchor).distance_to(before))
				steps += 1
	check(steps >= 40, "most zooms in the sample were unclamped (%d of %d)" % [steps, steps + clamped])
	check(worst < 0.02, "zoom about the cursor keeps the map point under the cursor (worst %.5f map px over %d zooms)" % [worst, steps])
	# By a wheel event, as the player does it.
	_ctl.set_view(_at(0.5, 0.5), 0.35)
	var at := Vector2(1000.0, 500.0)
	var w0 := _ctl.screen_to_world_px(at)
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP
	ev.pressed = true
	ev.position = at
	ev.factor = 1.0
	_ctl._unhandled_input(ev)
	near(_ctl.zoom_level(), 0.35 * _ctl.wheel_step, 1e-6, "a wheel notch zooms in by zoom.wheel_step")
	near(_ctl.screen_to_world_px(at).distance_to(w0), 0.0, 0.02, "and keeps the point under the cursor")
	ev.button_index = MOUSE_BUTTON_WHEEL_DOWN
	_ctl._unhandled_input(ev)
	near(_ctl.zoom_level(), 0.35, 1e-6, "a notch back zooms out again")
	# Round trip, metres.
	var p := Vector2(1234.5, 3210.25)
	near(_ctl.screen_to_world(_ctl.world_to_screen(p)).distance_to(p), 0.0, 1e-3, "world_to_screen and screen_to_world are inverses (metres)")

# --- pan -------------------------------------------------------------------------------------

func _pan() -> void:
	_ctl.set_view(_at(0.5, 0.5), 0.5)
	var w := _at(0.51, 0.49)
	var s0 := _ctl.world_px_to_screen(w)
	_ctl.pan_screen(Vector2(120.0, -40.0))
	near(_ctl.world_px_to_screen(w).distance_to(s0 + Vector2(120.0, -40.0)), 0.0, 1e-3, "pan_screen moves the map with the pointer")
	for button: int in [MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_LEFT]:
		var before := _ctl.world_px_to_screen(w)
		_drag(button, Vector2(30.0, 25.0))
		var moved := _ctl.world_px_to_screen(w) - before
		if button == MOUSE_BUTTON_LEFT:
			near(moved.length(), 0.0, 0.0, "a LEFT drag does not move the map")
		else:
			near(moved.distance_to(Vector2(30.0, 25.0)), 0.0, 1e-3, "a drag with button %d moves the map with the pointer" % button)
	_ctl.follow(func() -> Variant: return Vector2(100.0, 100.0))
	_ctl.pan_screen(Vector2(5.0, 0.0))
	check(not _ctl.is_following(), "a manual pan stops following")

func _drag(button: int, by: Vector2) -> void:
	var down := InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.position = Vector2(400.0, 300.0)
	_ctl._unhandled_input(down)
	var mv := InputEventMouseMotion.new()
	mv.position = Vector2(400.0, 300.0) + by
	mv.relative = by
	_ctl._unhandled_input(mv)
	var up := InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.position = mv.position
	_ctl._unhandled_input(up)

# --- frame-this-plan ----------------------------------------------------------------------------

func _frame() -> void:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	var id := w.add_unit({"type": "light_fighter", "side": "allies", "controller": "player", "x": 2500.0, "y": 2500.0, "heading": 0.3})
	var hb := w.add_unit({"type": "heavy_fighter", "side": "allies", "controller": "player", "x": 600.0, "y": 4400.0, "heading": -2.0})
	# A curving plan: steer each step toward a point off to the right.
	for k in w.steps_per_turn(id):
		w.plan_step(id, k, Vector2(2500.0 + 200.0 * (k + 1), 2500.0 + 160.0 * (k + 1) * (k + 1)))
	for k in w.steps_per_turn(hb):
		w.plan_step(hb, k, {"turn": -0.4, "speed": 165.0})
	for inset: float in [0.0, 320.0]:
		_ctl.set_insets(inset, 0.0, 0.0, 0.0)
		for uid: String in [id, hb]:
			_ctl.set_view(Vector2(1000.0, 1000.0), 1.5)
			var fitted := _ctl.frame_plan(w, uid)
			check(fitted, "frame_plan(%s) reports a fit (inset %.0f)" % [uid, inset])
			var fr := _ctl.frame_rect()
			var pts: Array[Vector2] = [Vector2(w.units[uid].x, w.units[uid].y)]
			for s: Dictionary in w.planned_states(uid):
				pts.append(Vector2(float(s["x"]), float(s["y"])))
			var outside := 0
			for p in pts:
				if not fr.grow(0.5).has_point(_ctl.world_to_screen(p)):
					outside += 1
			eq(outside, 0, "every one of %s's %d planned points is inside the framing rectangle %s (inset %.0f)" % [uid, pts.size(), fr, inset])
			check(_ctl.zoom_level() <= _ctl.frame_max_zoom + 1e-9, "framing never zooms past frame.max_zoom")
			print("[camera] frame_plan %s, inset %.0f: zoom %.3f, %d points in %s" % [uid, inset, _ctl.zoom_level(), pts.size(), fr])
	_ctl.set_insets(0.0, 0.0, 0.0, 0.0)
	# A single point frames at frame.max_zoom; a huge set cannot fit.
	check(_ctl.frame_points([Vector2(2000.0, 2000.0)]), "one point frames")
	near(_ctl.zoom_level(), minf(_ctl.frame_max_zoom, _ctl.zoom_max), 1e-9, "one point frames at frame.max_zoom")
	check(not _ctl.frame_points([Vector2(-50000.0, 0.0), Vector2(50000.0, 0.0)]), "a set wider than the zoom-out limit can hold reports false")

# --- follow ------------------------------------------------------------------------------------------

func _follow() -> void:
	var w := World.new()
	w.quiet = true
	var id := w.add_unit({"type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 1500.0, "heading": 0.0})
	_ctl.set_view(_at(0.6, 0.6), 0.5)
	_ctl.follow_unit(w, id)
	var target := Vector2(1500.0, 1500.0) * _ctl.px_per_m
	var d0 := _ctl.center().distance_to(target)
	_ctl.step_follow(0.1)
	var d1 := _ctl.center().distance_to(target)
	near(d1, d0 * exp(-_ctl.follow_rate * 0.1), 0.05, "following closes the gap at follow.smoothing_per_s")
	for i in 120:
		_ctl.step_follow(1.0 / 60.0)
	check(_ctl.center().distance_to(target) < maxf(1.0, d0 * exp(-_ctl.follow_rate * 2.1) * 2.0), "after two seconds the view is on the unit")
	w.units[id].x = 1700.0
	_ctl.follow_rate = 0.0
	_ctl.step_follow(0.016)
	near(_ctl.center().distance_to(Vector2(1700.0, 1500.0) * _ctl.px_per_m), 0.0, 1e-3, "with smoothing 0 the view snaps to the unit")
	_ctl.follow_rate = _ctl.data.num("follow.smoothing_per_s")
	_ctl.stop_follow()

# --- the scale knob ----------------------------------------------------------------------------------

func _scale_knob() -> void:
	var ppm0 := _ctl.px_per_m
	_ctl.set_view(_at(0.37, 0.61), 0.5)
	var centre_m := _ctl.center() / ppm0
	var lo0 := _ctl.zoom_limit_min()
	for ppm: float in [1.0, 3.0, 4.0, ppm0]:
		var map_px := Rect2(_terrain.map_x * ppm, _terrain.map_y * ppm, _terrain.map_w * ppm, _terrain.map_h * ppm)
		_ctl.set_scale(map_px, ppm)
		near((_ctl.center() / ppm).distance_to(centre_m), 0.0, 0.01, "px_per_m %s: the view stays on the same point in metres" % ppm)
		near(_ctl.zoom_level(), 0.5, 1e-6, "px_per_m %s: the zoom is kept" % ppm)
		near(_ctl.zoom_limit_min(), lo0 * ppm0 / ppm, 1e-9, "px_per_m %s: fit_map's zoom-out limit follows the map's size in px" % ppm)
		near(_ctl.map_margin_px, _ctl.data.num("pan.map_margin_m") * ppm, 1e-9, "px_per_m %s: the pan margin is metres x px_per_m" % ppm)
	near(_ctl.world_to_screen(centre_m).distance_to(_ctl.view_size() * 0.5), 0.0, 0.01, "metres map to the same screen point after the round trip")

# --- far zoom ---------------------------------------------------------------------------------------

func _far() -> void:
	var c := _terrain.map_rect_px().get_center()
	_ctl.set_view(c, _ctl.topo_below * 0.9)
	near(_ctl.overview_amount(), 1.0, 0.0, "overview is full below far_zoom.topo_below_zoom")
	_ctl.set_view(c, _ctl.full_above * 1.1)
	near(_ctl.overview_amount(), 0.0, 0.0, "no overview above far_zoom.full_above_zoom")
	_ctl.set_view(c, (_ctl.topo_below + _ctl.full_above) * 0.5)
	near(_ctl.overview_amount(), 0.5, 1e-6, "half way between, half the overview")

# --- the engine's own transform ------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _ctl == null or _finished:
		return
	_frames += 1
	if _frames < 3:
		return
	var xf := _vp.get_canvas_transform()
	near((xf * _anchor_world).distance_to(_anchor), 0.0, 0.05, "the Camera2D's own canvas transform puts the anchored map point back under the cursor")
	var p := _at(0.41, 0.62)
	near((xf * p).distance_to(_ctl.world_px_to_screen(p)), 0.0, 0.05, "the controller's world_px_to_screen is the engine's transform")
	finish()
