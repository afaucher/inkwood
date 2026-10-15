extends "res://scripts/test_support/test_case.gd"

# HOLD SPACE TO READY (decision playtest-4, Alex: "Lets have holding space for 1s ready you up if all units have actions or 2s otherwise"; his explicit
# exception to "No keyboard mapping"). Headless, on a real World mounted through UnitUI, with a fake clock: the hold is driven by ReadyHold.tick and by
# injected key events, never by real time.
#
#   1. the data: the key is Space, the two times are 1 s and 2 s (Alex's), the wash's role exists
#   2. "has actions": every player unit that is up has a step planned; decides the time
#   3. 1 s when every unit has actions, 2 s otherwise: not ready before, ready at, the Ready control's own action (press_ready)
#   4. releasing early cancels: no ready, no wash
#   5. the wash along the Ready button grows with the hold, in the button's own rectangle
#   6. the real key events (InputEventKey): press starts, key repeat does nothing, release (in _input) cancels, a held key does not ready twice
#   7. when it cannot start: already ready, not the planning phase, the end-of-mission card up

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

var _w: World
var _ui: UnitUI
var _st: UiStyle
var _done: Array[String] = []
var _completed := 0

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	_check_data()
	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	_w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2800.0, "heading": 0.0, "altitude_band": "high"})
	_w.add_unit({"id": "e1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 2300.0, "y": 2300.0, "heading": PI, "altitude_band": "low"})
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		finish()
		return
	var xf := Transform2D(0.0, Vector2(1.0, 1.0), 0.0, -Vector2(1300.0, 2000.0))
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, xf, "local")
	_ui.auto_resolve = false
	_ui.ready_hold.completed.connect(func() -> void: _completed += 1)
	_check_mount()
	_check_has_actions()
	_check_times()
	_check_early_release()
	_check_wash()
	_check_keys()
	_check_cannot_start()
	var missing: Array[String] = []
	for k: String in ["data", "mount", "actions", "times", "early", "wash", "keys", "cannot"]:
		if not _done.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	finish()

func _reset() -> void:
	_ui.ready_hold.release()
	if _w.is_ready("local"):
		_w.withdraw("local")
	for id: String in ["p1", "b1"]:
		_w.clear_plan(id)
	_completed = 0

func _plan_all() -> void:
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	_w.plan_step("b1", 0, {"turn": 0.0, "speed": 85.0})

# --- 1 -------------------------------------------------------------------------

func _check_data() -> void:
	eq(_st.text("keys.ready_hold"), "Space", "1. the hold key is Space (Alex)")
	eq(OS.find_keycode_from_string(_st.text("keys.ready_hold")), KEY_SPACE, "1. ...and the engine knows it as the Space bar")
	near(_st.num("orders.ready_hold.all_planned_s"), 1.0, 1e-9, "1. 1 s when every unit has actions (Alex)")
	near(_st.num("orders.ready_hold.otherwise_s"), 2.0, 1e-9, "1. 2 s otherwise (Alex)")
	check(_st.has_role(_st.text("orders.ready_hold.fill_role")), "1. the wash's colour is a role the style has")
	var a: float = _st.num("orders.ready_hold.fill_alpha")
	check(a > 0.0 and a < 1.0, "1. a wash, not a block (alpha %.2f)" % a)
	eq(_st.errors.size(), 0, "1. no style lookups failed: %s" % str(_st.errors))
	_done.append("data")

func _check_mount() -> void:
	var rh = _ui.ready_hold
	check(rh != null and rh.get_parent() == _ui.orders, "the hold is a child of the orders card (it draws over the Ready button)")
	eq(rh.mouse_filter, Control.MOUSE_FILTER_IGNORE, "...and takes no mouse")
	_done.append("mount")

# --- 2 -------------------------------------------------------------------------

func _check_has_actions() -> void:
	_reset()
	check(not _ui.all_units_planned(), "2. nothing planned: not every unit has actions")
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	check(not _ui.all_units_planned(), "2. one of two planned: not every unit")
	_w.plan_step("b1", 0, {"turn": 0.0, "speed": 85.0})
	check(_ui.all_units_planned(), "2. both player units planned: every unit has actions (the enemy's plan does not count)")
	near(_ui.ready_hold.required_s(), 1.0, 1e-9, "2. ...and the hold takes 1 s")
	_w.clear_plan("b1")
	near(_ui.ready_hold.required_s(), 2.0, 1e-9, "2. a unit without a step: 2 s")
	_done.append("actions")

# --- 3 -------------------------------------------------------------------------

func _check_times() -> void:
	var rh = _ui.ready_hold
	# every unit has actions: 1 s
	_reset()
	_plan_all()
	check(rh.begin(), "3. the hold starts")
	check(rh.holding, "3. ...and runs")
	check(not rh.tick(0.5), "3. 0.5 s in, nothing yet")
	check(not _w.is_ready("local"), "3. 0.5 s: not ready")
	near(rh.progress(), 0.5, 1e-9, "3. halfway")
	check(not rh.tick(0.49), "3. 0.99 s: not yet")
	check(not _w.is_ready("local"), "3. 0.99 s: not ready")
	check(rh.tick(0.02), "3. 1.01 s: the hold completes")
	check(_w.is_ready("local"), "3. ...and the local player is ready (the Ready control's own action)")
	eq(_completed, 1, "3. completed once")
	check(not rh.holding and rh.progress() == 0.0, "3. the hold is over and the wash gone")
	check(not rh.tick(5.0) and _completed == 1, "3. a held key readies once, not again")
	check(not rh.begin(), "3. ...and does not start a new hold until the key comes up")
	rh.release()
	# some unit has no actions: 2 s
	_reset()
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	check(rh.begin(), "3. a unit without actions: the hold starts")
	rh.tick(1.0)
	rh.tick(0.9)
	check(not _w.is_ready("local"), "3. 1.9 s: not ready")
	check(rh.tick(0.2), "3. 2.1 s: ready")
	check(_w.is_ready("local"), "3. ...the local player is ready")
	rh.release()
	# the plan changes during the hold: the time follows it
	_reset()
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	rh.begin()
	rh.tick(0.5)
	_w.plan_step("b1", 0, {"turn": 0.0, "speed": 85.0})
	check(rh.tick(0.6), "3. a plan completed during the hold shortens it to the 1 s (1.1 s held)")
	rh.release()
	_done.append("times")

# --- 4 -------------------------------------------------------------------------

func _check_early_release() -> void:
	var rh = _ui.ready_hold
	_reset()
	_plan_all()
	rh.begin()
	rh.tick(0.9)
	rh.release()
	check(not rh.holding and rh.progress() == 0.0, "4. released early: the hold is over, the wash gone")
	check(not rh.tick(1.0), "4. ...and time passing readies nothing")
	check(not _w.is_ready("local") and _completed == 0, "4. the player is not ready")
	rh.begin()
	rh.tick(0.9)
	check(not _w.is_ready("local"), "4. a new hold starts from nothing (0.9 s, not 1.8)")
	rh.release()
	# 2 s case
	_reset()
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	rh.begin()
	rh.tick(1.9)
	rh.release()
	rh.tick(1.0)
	check(not _w.is_ready("local"), "4. released at 1.9 s of 2: not ready")
	_done.append("early")

# --- 5 -------------------------------------------------------------------------

func _check_wash() -> void:
	var rh = _ui.ready_hold
	_reset()
	_plan_all()
	var ready_rect: Rect2 = _ui.orders.buttons()["ready"]["rect"]
	eq(rh.fill_rect(), Rect2(), "5. no hold, no wash")
	rh.begin()
	rh.tick(0.25)
	var r: Rect2 = rh.fill_rect()
	near(r.size.x, ready_rect.size.x * 0.25, 1e-6, "5. a quarter of the hold: a quarter of the button's width")
	eq(r.position, ready_rect.position, "5. ...from the button's left edge")
	near(r.size.y, ready_rect.size.y, 1e-6, "5. ...the button's height")
	rh.tick(0.5)
	near(rh.fill_rect().size.x, ready_rect.size.x * 0.75, 1e-6, "5. three quarters")
	rh.release()
	eq(rh.fill_rect(), Rect2(), "5. released: the wash goes")
	_done.append("wash")

# --- 6 -------------------------------------------------------------------------

func _key(pressed: bool, echo: bool = false, keycode: Key = KEY_SPACE) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = keycode
	e.pressed = pressed
	e.echo = echo
	return e

func _check_keys() -> void:
	var rh = _ui.ready_hold
	_reset()
	_plan_all()
	_ui._unhandled_input(_key(true))
	check(rh.holding, "6. the Space bar going down starts a hold")
	_ui._unhandled_input(_key(true, true))
	check(rh.holding and rh.held_s == 0.0, "6. the key repeat does nothing")
	rh.tick(0.9)
	_ui._input(_key(false))
	check(not rh.holding and not _w.is_ready("local"), "6. the key coming up cancels the hold")
	# another key does nothing
	_ui._unhandled_input(_key(true, false, KEY_A))
	check(not rh.holding, "6. another key starts no hold")
	# a full hold, the key held on, then let go
	_ui._unhandled_input(_key(true))
	rh.tick(1.01)
	check(_w.is_ready("local") and _completed == 1, "6. held for 1 s: the player is ready")
	_ui._unhandled_input(_key(true))
	check(not rh.holding, "6. the key is still down: no second hold")
	_ui._input(_key(false))
	_w.withdraw("local")
	_ui._unhandled_input(_key(true))
	check(rh.holding, "6. after the key came up, the next press holds again")
	_ui._input(_key(false))
	# the other ways to ready are untouched: Enter and the Ready control still ready at once
	_reset()
	_plan_all()
	_ui.press_ready()
	check(_w.is_ready("local"), "6. the Ready control still readies at once")
	_done.append("keys")

# --- 7 -------------------------------------------------------------------------

func _check_cannot_start() -> void:
	var rh = _ui.ready_hold
	_reset()
	_plan_all()
	_w.commit("local")
	check(not rh.begin(), "7. already ready: no hold (the Space bar never withdraws)")
	_w.withdraw("local")
	_ui.show_result({"state": "won", "reason": "test", "turn": 1, "t": 0.0})
	check(_ui.input_locked(), "7. (the end-of-mission card is up)")
	check(not rh.begin(), "7. the end-of-mission card is up: no hold")
	_ui.hide_result()
	check(rh.begin(), "7. the card gone: a hold starts")
	rh.release()
	_done.append("cannot")
