extends "res://scripts/test_support/test_case.gd"

# THE NODE HOVER (Track U2; Alex 2026-10-10: "we also need a visual indicator for
# selecting path nodes. It is hard to tell when you are close enough."). Headless:
# the planner is fed pointer positions (set_pointer, or the mouse motion UnitUI
# receives) and says what a press would do; what it DRAWS for each state is the
# board's business (variants/node-hover/), what it ASKS FOR is checked here.
#
#   1. the data: planner.hover.* exists, the mode names known effects, the
#      cursor names known shapes, the roles exist
#   2. the state follows the pointer's distance to the nearest planned handle:
#      far (none) -> near (within near_factor x handle_px, approach 0..1) ->
#      range (within handle_px, approach 1)
#   3. the NEAREST handle wins when handles crowd (it was the last step within
#      the radius), for the hover and for the press
#   4. dragging keeps the handle lit wherever the pointer goes; releasing ends it
#   5. the mouse cursor: pointing hand to grab, grabbing while dragging, a cross
#      where a press places the next step, the arrow otherwise; reset when the
#      pointer leaves, the plan closes, nobody can take orders, or the planner
#      leaves the tree
#   6. press_action says what press() does (grab / place / nothing)
#   7. nothing hovers for a down unit, an AI unit, or during the playback
#   8. the real input path: mouse motion through UnitUI; a card under the pointer
#      or the pointer leaving the window clears it

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")

const PPM := 3.8
const ORIGIN := Vector2(1400.0, 2200.0)

var _w: World
var _ui: UnitUI
var _pl: MotionPlanner
var _xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
var _r := 0.0       # the pick radius
var _near := 0.0    # the approach radius

func setup(_main) -> void:
	var st := UiStyle.new()
	if not check(st.ok(), "the UI style data loads: %s" % str(st.errors)):
		finish()
		return
	_check_data(st)
	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	_w.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2700.0, "heading": 0.0})
	_w.add_unit({"id": "ai1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 3500.0, "y": 1800.0, "heading": PI})
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, _xf, "local")
	_pl = _ui.planner
	_r = st.num("planner.handle_px")
	_near = _r * st.num("planner.hover.near_factor")
	_ui.select("p1")
	# Three straight steps of 100 m: handles 380 px apart on screen, in a line.
	for k in 3:
		_w.plan_step("p1", k, {"turn": 0.0, "speed": 100.0})
	_check_states()
	_check_nearest()
	_check_drag()
	_check_cursor()
	_check_actions()
	_check_no_hover()
	_check_input()
	_check_exit()
	finish()

func _hp(k: int) -> Vector2:
	var s: Dictionary = _pl.states()[k]
	return _xf * Vector2(float(s["x"]), float(s["y"]))

# --- 1 -------------------------------------------------------------------------

func _check_data(st: UiStyle) -> void:
	for n: String in ["planner.handle_px", "planner.hover.near_factor", "planner.hover.place_mark_px",
			"planner.hover.grow.near_px", "planner.hover.grow.range_px", "planner.hover.grow.drag_px", "planner.hover.grow.line_px",
			"planner.hover.ring.near_line_px", "planner.hover.ring.range_line_px", "planner.hover.ring.near_alpha",
			"planner.hover.ring.second_gap_px", "planner.hover.ring.dash_px", "planner.hover.ring.tick_px",
			"planner.hover.halo.soft_px", "planner.hover.halo.ring_px",
			"planner.hover.magnet.dot_px", "planner.hover.magnet.line_px", "planner.hover.magnet.near_alpha",
			"planner.hover.magnet.snap_ring_px", "planner.hover.magnet.dash_px", "planner.hover.label.pad_px"]:
		check(st.lookup(n) is float or st.lookup(n) is int, "ui.json has a number at '%s'" % n)
	check(st.flag("planner.hover.cursor.enabled"), "the cursor feedback is on in the data")
	var shapes := ["arrow", "pointing_hand", "cross", "drag", "move", "can_drop"]
	for k: String in ["grab", "drag", "place"]:
		check(shapes.has(st.text("planner.hover.cursor." + k)), "cursor.%s names a known shape (%s)" % [k, st.text("planner.hover.cursor." + k)])
	var mode := st.text("planner.hover.mode")
	check(not mode.is_empty(), "a hover mode is set")
	for fx: String in mode.split("+", false):
		check(MotionPlanner.HOVER_EFFECTS.has(fx), "hover effect '%s' is one the planner draws" % fx)
	check(st.has_role("hover_ink") and st.has_role("hover_paper"), "the hover's roles exist")
	check(st.num("planner.hover.near_factor") > 1.0, "the approach zone is wider than the pick radius")
	check(st.num("planner.handle_px") >= 12.0, "the pick radius is not smaller than the old 12 px")
	eq(st.errors.size(), 0, "no style lookups failed: %s" % str(st.errors))

# --- 2 -------------------------------------------------------------------------

func _check_states() -> void:
	eq(_pl.hover()["state"], "none", "2. no pointer, no hover")
	var h1 := _hp(1)
	_pl.set_pointer(h1 + Vector2(_near * 1.5, 0.0))
	eq(_pl.hover()["state"], "none", "2. far from every handle: nothing")
	_pl.set_pointer(h1 + Vector2(_near + 0.5, 0.0))
	eq(_pl.hover()["state"], "none", "2. just outside the approach zone: nothing")
	var last := 0.0
	for f: float in [0.95, 0.8, 0.6, 0.45, 0.3]:
		_pl.set_pointer(h1 + Vector2(_near * f + 0.0, 0.0).rotated(0.6))
		var h := _pl.hover()
		var d: float = _near * f
		if d > _r:
			eq(h["state"], "near", "2. %.0f px away (zone is %.0f): approaching" % [d, _near])
			check(float(h["approach"]) > last and float(h["approach"]) < 1.0, "2. approach grows as the pointer closes in (%.2f after %.2f)" % [float(h["approach"]), last])
			last = float(h["approach"])
		else:
			eq(h["state"], "range", "2. %.0f px away (radius %.0f): in range" % [d, _r])
			near(float(h["approach"]), 1.0, 1e-9, "2. in range the approach is 1")
		eq(h["step"], 1, "2. it is step 2's handle")
		check((h["handle_screen"] as Vector2).distance_to(h1) < 1e-3, "2. and it says where the handle is")
	_pl.set_pointer(h1 + Vector2(_r * 0.999, 0.0))
	eq(_pl.hover()["state"], "range", "2. just inside the radius: in range")
	_pl.set_pointer(h1 + Vector2(_r * 1.01, 0.0))
	eq(_pl.hover()["state"], "near", "2. just outside it: approaching")
	_pl.set_pointer(h1)
	eq(_pl.hover()["action"], "grab", "2. on the handle a press grabs")
	_pl.set_pointer(_hp(0) + Vector2(_r * 0.5, 0.0))
	eq(_pl.hover()["step"], 0, "2. the hover follows to another handle")
	_pl.clear_pointer()
	eq(_pl.hover()["state"], "none", "2. no pointer on the map: nothing")

# --- 3 -------------------------------------------------------------------------

func _check_nearest() -> void:
	# Zoomed out until the three handles are 10 px apart: all inside one radius.
	var xf2 := Transform2D(0.0, Vector2(0.1, 0.1), 0.0, -ORIGIN * 0.1 + Vector2(300.0, 300.0))
	_ui.set_mapping(xf2)
	var hp := func(k: int) -> Vector2:
		var s: Dictionary = _pl.states()[k]
		return xf2 * Vector2(float(s["x"]), float(s["y"]))
	check((hp.call(1) as Vector2).distance_to(hp.call(0)) < _r and (hp.call(1) as Vector2).distance_to(hp.call(2)) < _r, "3. the handles crowd: each neighbour is inside the radius (%.1f px apart)" % (hp.call(1) as Vector2).distance_to(hp.call(0)))
	var at1: Vector2 = hp.call(1) + Vector2(-2.0, 0.0)
	eq(_pl.handle_at(at1), 1, "3. the nearest handle is picked (the last one within the radius used to be)")
	_pl.set_pointer(at1)
	eq(_pl.hover()["step"], 1, "3. and it is the one the hover lights")
	var at0: Vector2 = hp.call(0) + Vector2(-3.0, 1.0)
	eq(_pl.handle_at(at0), 0, "3. beside the first handle: the first")
	eq(_pl.handle_at(hp.call(2) + Vector2(4.0, 0.0)), 2, "3. beyond the last: the last")
	# Between two: the closer.
	var mid: Vector2 = (hp.call(0) as Vector2).lerp(hp.call(1), 0.4)
	eq(_pl.handle_at(mid), 0, "3. 40% of the way from the first to the second: the first")
	check(_pl.press(at1), "3. a press there")
	eq(_pl.hover()["step"], 1, "3. grabs the nearest handle")
	check(_pl.is_dragging(), "3. (a drag of it)")
	_pl.release(at1)
	_ui.set_mapping(_xf)
	_w.clear_plan("p1")
	for k in 3:
		_w.plan_step("p1", k, {"turn": 0.0, "speed": 100.0})
	eq(_pl.nearest_handle(Vector2(-5000.0, -5000.0), _r), {}, "3. nothing within the radius: no handle")
	eq(_pl.handle_at(Vector2(-5000.0, -5000.0)), -1, "3. handle_at says -1")

# --- 4 -------------------------------------------------------------------------

func _check_drag() -> void:
	var h2 := _hp(2)
	_pl.set_pointer(h2 + Vector2(5.0, 0.0))
	check(_pl.press(h2 + Vector2(5.0, 0.0)), "4. press on step 3's handle")
	var h := _pl.hover()
	eq(h["state"], "drag", "4. dragging")
	eq(h["step"], 2, "4. that handle")
	_pl.set_pointer(h2 + Vector2(_near * 4.0, 60.0))
	eq(_pl.hover()["state"], "drag", "4. the pointer far away: still lit")
	eq(_pl.hover()["step"], 2, "4. still that handle")
	check((_pl.hover()["handle_screen"] as Vector2).is_finite(), "4. and where it is")
	_pl.drag(h2 + Vector2(40.0, 30.0))
	eq(_pl.hover()["state"], "drag", "4. after a drag move")
	_pl.release(h2 + Vector2(40.0, 30.0))
	check(not _pl.is_dragging(), "4. released")
	eq(_pl.hover()["state"], "none", "4. the pointer is far from every handle now: nothing lit")
	_pl.clear_pointer()
	# Re-plan the three straight steps (the drag moved step 3).
	_w.clear_plan("p1")
	for k in 3:
		_w.plan_step("p1", k, {"turn": 0.0, "speed": 100.0})

# --- 5 -------------------------------------------------------------------------

func _engine_cursor() -> int:
	return int(Input.get_current_cursor_shape())

func _check_cursor() -> void:
	# Does the engine report the shape set (a headless run may not)?
	Input.set_default_cursor_shape(Input.CURSOR_HELP)
	var engine_reports := _engine_cursor() == Input.CURSOR_HELP
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	print("[test] the engine reports the default cursor shape headless: %s" % str(engine_reports))
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "5. the arrow to begin with")
	var h1 := _hp(1)
	_pl.set_pointer(h1 + Vector2(_r * 0.5, 0.0))
	eq(_pl.cursor_shape, Input.CURSOR_POINTING_HAND, "5. in range of a handle: a pointing hand")
	if engine_reports:
		eq(_engine_cursor(), Input.CURSOR_POINTING_HAND, "5. and the engine has it")
	_pl.set_pointer(h1 + Vector2(_r * 1.5, 0.0))
	check(_pl.cursor_shape != Input.CURSOR_POINTING_HAND, "5. only approaching: not yet the hand (%d)" % _pl.cursor_shape)
	_pl.set_pointer(h1 + Vector2(_r * 0.5, 0.0))
	check(_pl.press(h1 + Vector2(_r * 0.5, 0.0)), "5. press")
	eq(_pl.cursor_shape, Input.CURSOR_DRAG, "5. dragging: the grabbing hand")
	if engine_reports:
		eq(_engine_cursor(), Input.CURSOR_DRAG, "5. and the engine has it")
	_pl.set_pointer(h1 + Vector2(500.0, 500.0))
	eq(_pl.cursor_shape, Input.CURSOR_DRAG, "5. still, wherever the pointer goes")
	_pl.release(h1 + Vector2(_r * 0.5, 0.0))
	_pl.set_pointer(h1 + Vector2(_r * 0.5, 0.0))
	eq(_pl.cursor_shape, Input.CURSOR_POINTING_HAND, "5. released over the handle: the hand again")
	_pl.clear_pointer()
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "5. the pointer left: the arrow")
	if engine_reports:
		eq(_engine_cursor(), Input.CURSOR_ARROW, "5. and the engine has it")
	# A cross where a press places the next step.
	var fan := _pl.fan_outline_world()
	var mid := _xf * ((fan[fan.size() / 4] + fan[fan.size() - 1 - fan.size() / 4]) * 0.5)
	_pl.set_pointer(mid)
	eq(_pl.hover()["action"], "place", "5. inside the next step's fan: a press places")
	eq(_pl.cursor_shape, Input.CURSOR_CROSS, "5. a cross")
	# The plan closes: the cursor goes back.
	_ui.select("")
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "5. nothing selected: the arrow")
	_ui.select("p1")
	_pl.set_pointer(h1)
	eq(_pl.cursor_shape, Input.CURSOR_POINTING_HAND, "5. selected again: the hand")
	_pl.clear_pointer()

# --- 6 -------------------------------------------------------------------------

func _check_actions() -> void:
	var h1 := _hp(1)
	eq(_pl.press_action(h1 + Vector2(3.0, 0.0)), "grab", "6. on a handle: grab")
	var fan := _pl.fan_outline_world()
	var mid := _xf * ((fan[fan.size() / 4] + fan[fan.size() - 1 - fan.size() / 4]) * 0.5)
	eq(_pl.press_action(mid), "place", "6. in the fan: place")
	eq(_pl.press_action(Vector2(-4000.0, -4000.0)), "", "6. far from both: nothing")
	var n0 := _pl.planned_count()
	check(_pl.press(mid), "6. a press there")
	_pl.release(mid)
	eq(_pl.planned_count(), n0 + 1, "6. places a step")
	n0 = _pl.planned_count()
	check(_pl.press(h1 + Vector2(3.0, 0.0)), "6. a press on a handle")
	_pl.release(h1 + Vector2(3.0, 0.0))
	eq(_pl.planned_count(), n0, "6. re-drags it, adds no step")
	check(not _pl.press(Vector2(-4000.0, -4000.0)), "6. a press far from both does nothing")
	# Back to three straight steps.
	_w.clear_plan("p1")
	for k in 3:
		_w.plan_step("p1", k, {"turn": 0.0, "speed": 100.0})

# --- 7 -------------------------------------------------------------------------

func _check_no_hover() -> void:
	var h1 := _hp(1)
	_pl.set_pointer(h1)
	eq(_pl.hover()["state"], "range", "7. (in range)")
	# A down unit.
	_w.units["p1"].down = true
	_pl.set_pointer(h1)
	eq(_pl.hover()["state"], "none", "7. a down unit's handles do not hover")
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "7. the cursor is the arrow")
	eq(_pl.handle_at(h1), -1, "7. and cannot be grabbed")
	_w.units["p1"].down = false
	# An AI unit: it can be selected, never planned.
	_ui.select("ai1")
	_pl.set_pointer(_xf * Vector2(3500.0, 1800.0))
	eq(_pl.hover()["state"], "none", "7. an AI unit's: nothing")
	_ui.select("p1")
	_pl.set_pointer(h1)
	eq(_pl.hover()["state"], "range", "7. back on p1: in range")
	# The playback.
	AiDumb.new(_w).attach()
	check(_w.commit("local"), "7. everyone is ready")
	_w.resolve()
	check(_ui.is_playing(), "7. the turn plays")
	eq(_pl.hover()["state"], "none", "7. during the playback nothing hovers")
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "7. and the cursor is the arrow")
	_pl.set_pointer(_xf * Vector2(1600.0, 2400.0))
	eq(_pl.hover()["state"], "none", "7. whatever the pointer does")
	_ui.marker_layer.stop_playback()
	_w.begin_turn()
	for k in 3:
		_w.plan_step("p1", k, {"turn": 0.0, "speed": 100.0})
	_pl.clear_pointer()

# --- 8 -------------------------------------------------------------------------

func _motion(p: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = p
	return ev

func _check_input() -> void:
	_ui.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_ui.hud.size = Vector2(1280.0, 720.0)
	_ui.layout()
	var h1 := _hp(1)
	_ui._input(_motion(h1 + Vector2(4.0, 3.0)))
	eq(_pl.hover()["state"], "range", "8. a mouse motion over a handle lights it")
	eq(_pl.hover()["step"], 1, "8. (step 2)")
	_ui._input(_motion(h1 + Vector2(_near * 0.8, 0.0)))
	eq(_pl.hover()["state"], "near", "8. a motion nearby: approaching")
	var card := _ui.roster.get_global_rect().get_center()
	check(_ui.over_card(card), "8. the roster is a card")
	check(_ui.over_card(_ui.orders.get_global_rect().get_center()), "8. so is the orders card")
	check(not _ui.over_card(Vector2(5.0, 5.0)), "8. the map is not")
	_ui._input(_motion(h1))
	eq(_pl.hover()["state"], "range", "8. back on the handle")
	_ui._input(_motion(card))
	eq(_pl.hover()["state"], "none", "8. the pointer on a card: nothing hovers (a card is clicked, not planned through)")
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "8. the cursor is the arrow")
	_ui._input(_motion(h1))
	eq(_pl.hover()["state"], "range", "8. onto the handle again")
	_ui._notification(Node.NOTIFICATION_WM_MOUSE_EXIT)
	eq(_pl.hover()["state"], "none", "8. the pointer leaves the window: nothing")
	# A drag through the real path keeps it lit, over a card too.
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = h1 + Vector2(3.0, 0.0)
	_ui._input(_motion(press.position))
	_ui._unhandled_input(press)
	check(_pl.is_dragging(), "8. a press on the handle drags it")
	_ui._input(_motion(card))
	eq(_pl.hover()["state"], "drag", "8. dragged over a card: still lit")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = h1
	_ui._input(release)
	check(not _pl.is_dragging(), "8. released")
	_pl.clear_pointer()

# --- 5, at the end: leaving the tree ---------------------------------------------------

func _check_exit() -> void:
	_pl.set_pointer(_hp(1))
	eq(_pl.cursor_shape, Input.CURSOR_POINTING_HAND, "9. the hand, in range")
	remove_child(_ui)
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "9. the planner leaves the tree: the cursor goes back to the arrow")
	_ui.free()
