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
#            the limit to full_render_min_zoom; THE VIEW STOPS AT THE MAP'S EDGE
#            (Alex, 2026-10-11, decision pan-stops-at-edge): it shows at most
#            pan.edge_overscroll_m past it, and is centred on an axis where it
#            is wider than the map and that band.
#   CURSOR   zoom about the cursor keeps the map point under the cursor (by
#            zoom_at and by a wheel event), and the controller's transform is
#            the one the engine's Camera2D actually applies (the viewport's
#            canvas transform, after a frame).
#   WHEEL    (Alex, 2026-10-11, decision zoom-anchors) the wheel and the pinch zoom
#            IN toward the cursor and OUT about the centre of the map area
#            (zoom_centre: the view less the HUD insets), so out-and-back-in at a
#            spot pans toward it: the centre moves by (step - 1) x the cursor's
#            offset / zoom; held keys zoom about zoom_centre.
#   PAN      a middle drag moves the map with the pointer; a right drag does not
#            (Alex, 2026-10-11, decision pan-right-drag-off: right-click is the
#            target alone); a left drag does nothing here (GRAB is the left's own
#            pan); a pan stops following.
#   GRAB     (Alex, 2026-10-11, decision pan-left-drag) a left press the interface
#            hands over (begin_grab: nothing on the map under it) pans once the
#            pointer has moved past pan.left_drag_slop_px -- not before, so a click
#            stays a click -- with the point pressed kept under the pointer; the
#            release ends it; with input off nothing is taken.
#   FRAME    frame_plan fits every planned point of a unit's turn inside the
#            framing rectangle (with and without a HUD inset), no closer than
#            frame.max_zoom; a set too big for the zoom-out limit reports false.
#   FOLLOW   following eases toward the unit and snaps with smoothing 0.
#   JUDDER   (builder CAM, 2026-10-11, decision playtest-3 zoom_judder, "like there's two systems fighting each other for
#            deciding the view") ONE OWNER OF THE VIEW: a scripted wheel zoom all the way in and back out, with a follow
#            running every frame, never moves the zoom backwards and never moves the anchored point (the one under the
#            cursor going in, the map area's centre coming out) by a frame; the zoom reaches the closest zoom, which is
#            past the old 2.0 (tanks too small); a zoom that changes the zoom ends the follow (follow.break_on_zoom), a
#            notch at the limit does not; with that switch off the fight is there to be seen (the test can fail).
#   FAR      overview_amount is 1 below topo_below_zoom, 0 above
#            full_above_zoom, 0 always in "full_render" mode.
#   INSETS   (first fight, rough edge "the roster clear of the map at full zoom-out")
#            the HUD insets: "fit_map" fits the map into the free area (the view less
#            the insets), the zoom-out view is centred on it -- pos = map centre -
#            (left - right, top - bottom) / (2 zoom) -- so the sidebar does not cover
#            the map; the pan clamp is on the free area's centre; no insets, no change.

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
	_grab()
	_frame()
	_follow()
	_judder()
	_far()
	_scale_knob()
	_insets()
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
	var lim := _ctl.map_rect_px.grow(_ctl.edge_overscroll_px)
	var vr := _ctl.visible_rect_px()
	near(vr.position.x, lim.position.x, 1e-3, "the view stops at the map's west edge plus pan.edge_overscroll_m")
	near(vr.end.y, lim.end.y, 1e-3, "and at its south edge plus it")
	_ctl.set_view(Vector2(1e6, -1e6), 1.0)
	_ctl.pan_screen(Vector2(-400.0, 300.0))   # dragging the map further out moves nothing
	vr = _ctl.visible_rect_px()
	near(vr.end.x, lim.end.x, 1e-3, "zoom 1, pushed and dragged past the north-east corner: the view stops at the east edge plus the band")
	near(vr.position.y, lim.position.y, 1e-3, "and at the north edge plus it")
	# Between the zoom-out limit and the zoom where the view fits inside the map: wider than the map one way.
	var zw := SIZE.x / lim.size.x * 0.9
	if check(zw > _ctl.zoom_limit_min() and SIZE.y / zw < lim.size.y, "(a zoom %.4f where the view is wider than the map but not taller)" % zw):
		_ctl.set_view(Vector2(-1e6, -1e6), zw)
		near(_ctl.center().x, _ctl.map_rect_px.get_center().x, 1e-3, "wider than the map and its band: the view is centred across it")
		near(_ctl.visible_rect_px().position.y, lim.position.y, 1e-3, "and still stops at the north edge plus the band")

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
	var c_in := _ctl.center()
	_ctl._unhandled_input(ev)
	near(_ctl.zoom_level(), 0.35, 1e-6, "a notch back zooms out again")
	near(_ctl.center().distance_to(c_in), 0.0, 1e-6, "WHEEL: a notch out zooms about the centre (no HUD insets: the view's), not the cursor")
	_wheel()
	# Round trip, metres.
	var p := Vector2(1234.5, 3210.25)
	near(_ctl.screen_to_world(_ctl.world_to_screen(p)).distance_to(p), 0.0, 1e-3, "world_to_screen and screen_to_world are inverses (metres)")

# --- the wheel: in toward the cursor, out about the centre (Alex, decision zoom-anchors) -------------

func _wheel() -> void:
	var step := _ctl.wheel_step
	var mid := Vector2(SIZE) * 0.5
	# Out and back in at a spot moves the view toward it: the centre by (step - 1) x offset / zoom.
	for at: Vector2 in [Vector2(1000.0, 500.0), Vector2(150.0, 90.0), Vector2(640.0, 360.0)]:
		_ctl.set_view(_at(0.5, 0.5), 0.35)
		var c0 := _ctl.center()
		_wheel_event(MOUSE_BUTTON_WHEEL_DOWN, at)
		_wheel_event(MOUSE_BUTTON_WHEEL_UP, at)
		near(_ctl.zoom_level(), 0.35, 1e-6, "WHEEL: out and back in returns to the zoom")
		var want := c0 + (at - mid) * (step - 1.0) / 0.35
		near(_ctl.center().distance_to(want), 0.0, 1e-3, "WHEEL: out and back in at %s moves the view toward it by (step - 1) x offset / zoom" % at)
	# Five notches out (the cursor anywhere) and five in on a target: it ends 1 / step^5 as far from the centre.
	_ctl.set_view(_at(0.5, 0.5), 0.35)
	var target := _ctl.screen_to_world_px(Vector2(1100.0, 600.0))
	var d0 := _ctl.world_px_to_screen(target).distance_to(mid)
	for i in 5:
		_wheel_event(MOUSE_BUTTON_WHEEL_DOWN, Vector2(5.0, 5.0))
	var on_target := _ctl.world_px_to_screen(target)
	for i in 5:
		_wheel_event(MOUSE_BUTTON_WHEEL_UP, on_target)
	var d1 := _ctl.world_px_to_screen(target).distance_to(mid)
	near(d1 / d0, 1.0 / pow(step, 5.0), 1e-6, "WHEEL: five notches out and five in on a target bring it %.0f%% closer to the centre" % (100.0 * (1.0 - 1.0 / pow(step, 5.0))))
	print("[camera] wheel out-and-in: a target %.0f px from the centre ends %.0f px from it (step %.2f, five notches)" % [d0, d1, step])
	# The pinch: in toward the fingers, out about the centre.
	_ctl.set_view(_at(0.5, 0.5), 0.35)
	var pinch_at := Vector2(1000.0, 200.0)
	var w := _ctl.screen_to_world_px(pinch_at)
	var mg := InputEventMagnifyGesture.new()
	mg.position = pinch_at
	mg.factor = 1.2
	_ctl._unhandled_input(mg)
	near(_ctl.screen_to_world_px(pinch_at).distance_to(w), 0.0, 0.02, "WHEEL: a pinch in keeps the point under the fingers")
	var c1 := _ctl.center()
	mg.factor = 1.0 / 1.2
	_ctl._unhandled_input(mg)
	near(_ctl.center().distance_to(c1), 0.0, 1e-6, "WHEEL: a pinch out zooms about the centre")
	# With the HUD on the right, out is about the centre of the map area, not of the window.
	_ctl.set_insets(0.0, 0.0, 354.0, 0.0)
	_ctl.set_view(_at(0.5, 0.5), 0.35)
	near(_ctl.zoom_centre().distance_to(Vector2((1280.0 - 354.0) * 0.5, 360.0)), 0.0, 1e-9, "WHEEL: zoom_centre is the centre of the view less the HUD insets")
	var wc := _ctl.screen_to_world_px(_ctl.zoom_centre())
	_wheel_event(MOUSE_BUTTON_WHEEL_DOWN, Vector2(1200.0, 700.0))
	near(_ctl.screen_to_world_px(_ctl.zoom_centre()).distance_to(wc), 0.0, 1e-3, "WHEEL: with a HUD inset a notch out keeps the map area's centre")
	_ctl.set_insets(0.0, 0.0, 0.0, 0.0)

func _wheel_event(button: int, at: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = true
	ev.position = at
	ev.factor = 1.0
	_ctl._unhandled_input(ev)

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
		elif button == MOUSE_BUTTON_RIGHT:
			near(moved.length(), 0.0, 0.0, "a RIGHT drag does not move the map (decision pan-right-drag-off)")
		else:
			near(moved.distance_to(Vector2(30.0, 25.0)), 0.0, 1e-3, "a drag with button %d moves the map with the pointer" % button)
	_ctl.follow(func() -> Variant: return Vector2(100.0, 100.0))
	_ctl.pan_screen(Vector2(5.0, 0.0))
	check(not _ctl.is_following(), "a manual pan stops following")
	# A drag in progress is followed and ended in _input (a card under the pointer
	# stops motion and swallows the release in the GUI phase): the press begins it in
	# _unhandled_input, the rest never gets there.
	check(_ctl.drag_buttons.size() == 1 and _ctl.drag_buttons[0] == MOUSE_BUTTON_MIDDLE, "the drag buttons are the middle button alone (decision pan-right-drag-off)")
	for button: int in [MOUSE_BUTTON_MIDDLE]:
		var b4 := _ctl.world_px_to_screen(w)
		var down := InputEventMouseButton.new()
		down.button_index = button
		down.pressed = true
		down.position = Vector2(400.0, 300.0)
		_ctl._unhandled_input(down)
		var mv := InputEventMouseMotion.new()
		mv.position = Vector2(430.0, 325.0)
		mv.relative = Vector2(30.0, 25.0)
		_ctl._input(mv)
		near((_ctl.world_px_to_screen(w) - b4).distance_to(Vector2(30.0, 25.0)), 0.0, 1e-3, "button %d: motion is followed in _input" % button)
		var up := InputEventMouseButton.new()
		up.button_index = button
		up.pressed = false
		up.position = mv.position
		_ctl._input(up)
		var after_up := _ctl.world_px_to_screen(w)
		mv.relative = Vector2(50.0, 0.0)
		_ctl._input(mv)
		_ctl._unhandled_input(mv)
		near(_ctl.world_px_to_screen(w).distance_to(after_up), 0.0, 1e-9, "button %d: the release in _input ended the drag (later motion does nothing)" % button)
	var idle := InputEventMouseMotion.new()
	idle.relative = Vector2(40.0, 40.0)
	var before_idle := _ctl.world_px_to_screen(w)
	_ctl._input(idle)
	near(_ctl.world_px_to_screen(w).distance_to(before_idle), 0.0, 0.0, "_input does nothing when no drag is in progress")

# --- left drag on empty map (decision pan-left-drag) ----------------------------------------------

func _grab() -> void:
	_ctl.set_view(_at(0.5, 0.5), 0.5)
	var press := Vector2(500.0, 400.0)
	var w := _ctl.screen_to_world_px(press)
	var c0 := _ctl.center()
	_ctl.begin_grab(press)
	var inside := press + Vector2(_ctl.left_drag_slop * 0.6, _ctl.left_drag_slop * 0.6)
	_move(inside)
	near(_ctl.center().distance_to(c0), 0.0, 0.0, "GRAB: within pan.left_drag_slop_px (%.0f px) the map does not move" % _ctl.left_drag_slop)
	check(not _ctl.is_grabbing(), "GRAB: and it is not a pan yet")
	for to: Vector2 in [press + Vector2(40.0, -25.0), press + Vector2(-120.0, 60.0), press + Vector2(7.0, 3.0)]:
		_move(to)
		near(_ctl.world_px_to_screen(w).distance_to(to), 0.0, 1e-3, "GRAB: past the slop the map point pressed stays under the pointer (at %s)" % to)
	check(_ctl.is_grabbing(), "GRAB: past the slop it is a pan")
	_left_up(press + Vector2(7.0, 3.0))
	check(not _ctl.is_grabbing(), "GRAB: the release ends it")
	var c1 := _ctl.center()
	_move(press + Vector2(300.0, 200.0))
	near(_ctl.center().distance_to(c1), 0.0, 0.0, "GRAB: after the release the pointer moves nothing")
	# A click on empty map: press and release without leaving the slop moves nothing.
	_ctl.begin_grab(press)
	_move(inside)
	_left_up(inside)
	_move(press + Vector2(200.0, 0.0))
	near(_ctl.center().distance_to(c1), 0.0, 0.0, "GRAB: a click on empty map moves nothing, then or after")
	# With the camera's input off a press is not taken.
	_ctl.input_enabled = false
	_ctl.begin_grab(press)
	_ctl.input_enabled = true
	_move(press + Vector2(200.0, 0.0))
	near(_ctl.center().distance_to(c1), 0.0, 0.0, "GRAB: with the camera's input off no press is taken")
	# A grab pan stops following, as any pan does.
	_ctl.follow(func() -> Variant: return Vector2(100.0, 100.0))
	_ctl.begin_grab(press)
	_move(press + Vector2(50.0, 0.0))
	_left_up(press + Vector2(50.0, 0.0))
	check(not _ctl.is_following(), "GRAB: a left-drag pan stops following")

func _move(to: Vector2) -> void:
	var mv := InputEventMouseMotion.new()
	mv.position = to
	_ctl._input(mv)

func _left_up(at: Vector2) -> void:
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = at
	_ctl._input(up)

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

# --- the judder: one owner of the view (builder CAM, decision playtest-3 zoom_judder) ----------------------------

func _judder() -> void:
	var ppm := _ctl.px_per_m
	var unit_m := _at(0.5, 0.5) / ppm
	var getter := func() -> Variant: return unit_m
	var cursor := Vector2(900.0, 300.0)
	var dt := 1.0 / 60.0
	# 1. All the way in and back out with a follow running every frame, as after a roster click (Alex's judder): three
	# frames between notches, the follow stepped in each.
	_ctl.set_view(unit_m * ppm, 0.2)
	_ctl.follow(getter)
	var held := _ctl.screen_to_world_px(cursor)
	var z_prev := _ctl.zoom_level()
	var back_in := 0
	var drift_in := 0.0
	for notch in 40:
		_wheel_event(MOUSE_BUTTON_WHEEL_UP, cursor)
		for f in 3:
			_ctl.step_follow(dt)
			var z := _ctl.zoom_level()
			if z < z_prev - 1e-12:
				back_in += 1
			z_prev = z
			drift_in = maxf(drift_in, _ctl.world_px_to_screen(held).distance_to(cursor))
	eq(back_in, 0, "JUDDER: zooming in, no frame moves the zoom backwards")
	check(drift_in < 0.02, "JUDDER: zooming in, no frame moves the point under the cursor (worst %.5f px over 120 frames)" % drift_in)
	near(_ctl.zoom_level(), _ctl.zoom_max, 1e-9, "JUDDER: the closest zoom (zoom.max %.2f) is reached" % _ctl.zoom_max)
	check(_ctl.zoom_max > 2.0, "JUDDER: and it is past the old closest zoom 2.0 (tanks were too small there)")
	check(not _ctl.is_following(), "JUDDER: the follow gave the view up at the first notch (follow.break_on_zoom)")
	_ctl.follow(getter)   # (a follow started again at the closest zoom is ended by the first notch out)
	var mid := _ctl.zoom_centre()
	var held_c := _ctl.screen_to_world_px(mid)
	var back_out := 0
	var drift_out := 0.0
	for notch in 14:
		_wheel_event(MOUSE_BUTTON_WHEEL_DOWN, cursor)
		for f in 3:
			_ctl.step_follow(dt)
			var z := _ctl.zoom_level()
			if z > z_prev + 1e-12:
				back_out += 1
			z_prev = z
			drift_out = maxf(drift_out, _ctl.world_px_to_screen(held_c).distance_to(mid))
	eq(back_out, 0, "JUDDER: zooming out, no frame moves the zoom backwards")
	check(drift_out < 0.02, "JUDDER: zooming out, no frame moves the centre of the map area (worst %.5f px)" % drift_out)
	print("[camera] judder: 40 notches in with a follow, zoom 0.2 to %.2f, the point under the cursor moved %.5f px; 14 out, the centre %.5f px" % [_ctl.zoom_max, drift_in, drift_out])

	# 2. The fight, with the switch off (so this test can fail): the follow drags the anchored point off the cursor.
	var d := CameraData.new(CameraData.CAMERA_PATH)
	d.root["follow"]["break_on_zoom"]["value"] = false
	_ctl = _make(d)
	_ctl.set_view(unit_m * ppm, 0.2)
	_ctl.follow(getter)
	held = _ctl.screen_to_world_px(cursor)
	var fight := 0.0
	for notch in 10:
		_wheel_event(MOUSE_BUTTON_WHEEL_UP, cursor)
		for f in 3:
			_ctl.step_follow(dt)
			fight = maxf(fight, _ctl.world_px_to_screen(held).distance_to(cursor))
	check(fight > 5.0, "JUDDER: with follow.break_on_zoom off the follow pulls the anchored point off the cursor (%.1f px): the old fight" % fight)
	check(_ctl.is_following(), "JUDDER: and the follow runs on through the zoom")
	_ctl = _make()

	# 3. What ends a follow and what does not.
	_ctl.set_view(unit_m * ppm, _ctl.zoom_max)
	_ctl.follow(getter)
	_wheel_event(MOUSE_BUTTON_WHEEL_UP, cursor)
	check(_ctl.is_following(), "JUDDER: a notch in at the closest zoom changes nothing and keeps the follow")
	_ctl.set_view(unit_m * ppm, 0.3)
	_ctl.follow(getter)
	_ctl.zoom_by(1.2, cursor)
	check(_ctl.is_following(), "JUDDER: a zoom made in code (framing, tools) keeps it")
	for how: String in ["wheel in", "wheel out", "pinch", "zoom key"]:
		_ctl.set_view(unit_m * ppm, 0.3)
		_ctl.follow(getter)
		match how:
			"wheel in":
				_wheel_event(MOUSE_BUTTON_WHEEL_UP, cursor)
			"wheel out":
				_wheel_event(MOUSE_BUTTON_WHEEL_DOWN, cursor)
			"pinch":
				var mg := InputEventMagnifyGesture.new()
				mg.position = cursor
				mg.factor = 1.2
				_ctl._unhandled_input(mg)
			"zoom key":
				_ctl._player_zoom(1.1, _ctl.zoom_centre())   # (what the held Q / E keys call each frame)
		check(not _ctl.is_following(), "JUDDER: a player's zoom (%s) ends the follow, as a pan does" % how)

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
		near(_ctl.edge_overscroll_px, _ctl.data.num("pan.edge_overscroll_m") * ppm, 1e-9, "px_per_m %s: the band past the edge is metres x px_per_m" % ppm)
	near(_ctl.world_to_screen(centre_m).distance_to(_ctl.view_size() * 0.5), 0.0, 0.01, "metres map to the same screen point after the round trip")

# --- the HUD insets: the roster must not cover the map at full zoom-out ---------------------------------

func _insets() -> void:
	var map := _ctl.map_rect_px
	var cases: Array = [
		# [left, top, right, bottom, why]
		[0.0, 0.0, 700.0, 0.0, "a sidebar at the right wide enough for the width to bind"],
		[0.0, 0.0, 354.0, 0.0, "the sidebar as the sandbox sets it (roster 300 + margins), height binds"],
		[120.0, 60.0, 400.0, 90.0, "insets on every side"],
	]
	for c: Array in cases:
		var L: float = c[0]
		var T: float = c[1]
		var R: float = c[2]
		var B: float = c[3]
		_ctl.set_insets(L, T, R, B)
		var v := Vector2(SIZE)
		var free := v - Vector2(L + R, T + B)
		# 1. The limit fits the map into the free area (spec: z = min(v.x / map.x, v.y / map.y) / fit_margin).
		var want := minf(free.x / map.size.x, free.y / map.size.y) / _ctl.fit_margin
		near(_ctl.zoom_limit_min(), want, 1e-9, "insets %s: 'fit_map' fits the map into the free area (%s)" % [str([L, T, R, B]), c[4]])
		# 2. Zoomed out as far as it goes, the view is centred on the free area: pos = map centre - (L - R, T - B) / (2 zoom).
		_ctl.set_view(map.get_center() + Vector2(900.0, -700.0), 1e-6)
		var z := _ctl.zoom_level()
		near(z, want, 1e-6 * want, "insets %s: zoomed right out the zoom is the limit" % str([L, T, R, B]))
		var expect := map.get_center() - Vector2(L - R, T - B) / (2.0 * z)
		near(_ctl.center().distance_to(expect), 0.0, 1e-3, "insets %s: the view is centred so that the map's centre is the free area's centre" % str([L, T, R, B]))
		# 3. And the whole map lies inside the free area (the sidebar covers none of it).
		var tl := _ctl.world_px_to_screen(map.position)
		var br := _ctl.world_px_to_screen(map.end)
		var free_rect := Rect2(L, T, free.x, free.y)
		check(free_rect.grow(0.5).has_point(tl) and free_rect.grow(0.5).has_point(br), "insets %s: the map (%s to %s) is inside the free area %s, clear of the HUD" % [str([L, T, R, B]), tl.round(), br.round(), free_rect])
		# 4. The wheel, zooming out about a corner cursor, ends at the same view.
		_ctl.set_view(_at(0.8, 0.2), 0.2)
		for i in 60:
			_ctl.zoom_by(1.0 / _ctl.wheel_step, Vector2(30.0, 30.0))
		near(_ctl.center().distance_to(expect), 0.0, 1e-3, "insets %s: zooming out with the wheel (about a corner) ends on the same centred view" % str([L, T, R, B]))
		# 5. In between, the clamp is on the free area: pushed far, it stops at the map's edge plus the band.
		_ctl.set_view(map.get_center(), 0.5)
		_ctl.set_view(Vector2(1e7, -1e7), 0.5)
		var free_c := _ctl.center() + _ctl.inset_offset() / 0.5
		var half := _ctl.free_size() * 0.5 / 0.5
		var lim := map.grow(_ctl.edge_overscroll_px)
		near(free_c.x + half.x, lim.end.x, 1e-3, "insets %s: the free area stops at the map's east edge plus the band" % str([L, T, R, B]))
		near(free_c.y - half.y, lim.position.y, 1e-3, "insets %s: and at the north edge plus it" % str([L, T, R, B]))
	# Framing is unchanged by this and still leaves the insets out.
	_ctl.set_insets(0.0, 0.0, 354.0, 0.0)
	check(_ctl.frame_rect().end.x <= SIZE.x - 354.0 + 1e-9, "frame_rect still leaves the insets out")
	# No insets: the limit and the clamp are exactly what they were.
	_ctl.set_insets(0.0, 0.0, 0.0, 0.0)
	var plain := minf(SIZE.x / map.size.x, SIZE.y / map.size.y) / _ctl.fit_margin
	near(_ctl.zoom_limit_min(), plain, 1e-12, "no insets: the plain fit_map limit")
	_ctl.set_view(map.get_center() + Vector2(500.0, 500.0), 1e-6)
	near(_ctl.center().distance_to(map.get_center()), 0.0, 1e-9, "no insets: right out, the view is centred on the map")
	# 'full_render' far mode keeps its number as the limit, insets or not, and only the clamp follows them.
	var d := CameraData.new(CameraData.CAMERA_PATH)
	d.root["far_zoom"]["mode"]["value"] = "full_render"
	_ctl = _make(d)
	_ctl.set_insets(0.0, 0.0, 354.0, 0.0)
	near(_ctl.zoom_limit_min(), d.num("far_zoom.full_render_min_zoom"), 1e-12, "'full_render' with insets: the limit is still full_render_min_zoom")
	_ctl = _make()

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
