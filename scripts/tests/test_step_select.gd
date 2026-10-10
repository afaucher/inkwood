extends "res://scripts/test_support/test_case.gd"

# STEP SELECTION AND THE DROP (Track B, 2026-10-10). Alex's Strike playtest: "The bomb controls are wildly bad. It is VERY hard to see what is
# happening. Dropping the bomb shouldn't be a separate control scheme ... nothing connects 'I am selecting the bomb special on step 2' with this
# red blob. And it moves with subsequent steps?? What is happening?" "The UI says '3 of 3 steps planned' - I can move them but can I replan
# them? I actually want to be able to set my motion and come back to step 2/3 and tell it to drop the bomb then." "Selecting the node should
# select that step in the plan." "Lets prioritize onscreen buttons. No keyboard mapping." "it should SAY in the step metadata the name of the
# special and the action. So Radio On, Bomb Drop, Turret Fire." "maybe we could have a clickable indicator for the steps that let you select the
# step from there and also see which steps are planned. You can only click an already planned step or the next unplanned."
# Headless, on the real World, mounted through UnitUI as the assembly mounts it:
#
#   1. a click on a node SELECTS its step (real mouse events), moves nothing, takes no Ready back; the card names the step; Dive / Level /
#      Climb act on it -- for every unit
#   2. placing a step selects it; a drag moves a node and selects it; a drag inside the slop is a click
#   3. the drop on step 2 after three steps are placed: Drop toggles, with its pressed state; the lettering says "Bomb Drop" at that step only
#   4. the drop's picture is PINNED to its step: it does not move when step 3 (or step 1) moves; one picture for each step with a drop
#   5. no big wash: the cone is an outline only while the pointer is on the button or a landing point is dragged; the old preview is off
#   6. the target in words on the card (always for a unit with a special); Drop's disabled reasons in plain words
#   7. the step strip: one mark per step of the turn, its states, the click rules, and the strip and the map's selection agreeing both ways
#   8. the special's words come from the unit's DATA (change them and the lettering, the button and the card follow); no new key was added

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")
const BombAimArt = preload("res://scripts/ui/bomb_aim_art.gd")

const PPM := 0.5
const ORIGIN := Vector2(1300.0, 1900.0)
const LABEL := "Bomb Drop"

var _w: World
var _ui: UnitUI
var _pl: MotionPlanner
var _xf: Transform2D
var _st: UiStyle

func setup(_main) -> void:
	timeout_seconds = 120.0
	_st = UiStyle.new()
	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0, "altitude_band": "high"})
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2000.0, "heading": 0.0})
	_w.add_unit({"id": "eb", "type": "bomber", "side": "axis", "controller": "ai", "x": 2400.0, "y": 2000.0, "heading": PI, "altitude_band": "high"})
	_w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 2785.0, "y": 2400.0, "heading": 0.0})
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		finish()
		return
	_xf = Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, _xf, "local")
	_ui.auto_resolve = false
	_pl = _ui.planner
	eq(_clicks(), true, "1. the click part ran to its end")
	eq(_place_and_drag(), true, "2. the place-and-drag part ran to its end")
	eq(_drop_on_step_two(), true, "3. the drop part ran to its end")
	eq(await _pinned(), true, "4. the pinned-picture part ran to its end")
	eq(_outline(), true, "5. the cone-outline part ran to its end")
	eq(_words(), true, "6. the words part ran to its end")
	eq(_strip(), true, "7. the strip part ran to its end")
	eq(_data_words(), true, "8. the data-words part ran to its end")
	finish()

# --- helpers -------------------------------------------------------------------------------------------------------------------

func _mouse(button: int, pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	return ev

func _motion(pos: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	return ev

# A left click as the engine delivers it: the press (unhandled by the GUI), then the release.
func _click(screen_pt: Vector2) -> void:
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true, screen_pt))
	_ui._input(_mouse(MOUSE_BUTTON_LEFT, false, screen_pt))
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false, screen_pt))

# A press, a move to each of `path`, a release at the last (the drag is taken in _input once it is going).
func _drag(from: Vector2, path: Array) -> void:
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true, from))
	for p: Vector2 in path:
		_ui._input(_motion(p))
	_ui._input(_mouse(MOUSE_BUTTON_LEFT, false, path[path.size() - 1]))
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false, path[path.size() - 1]))

func _fresh(id: String = "b1") -> void:
	_ui.select("")
	_ui.select(id)
	_pl.clear()
	_ui.target.clear()
	_pl.set_drop_hover(false)

# Three steps along the bomber's heading, 142 m apart.
func _three() -> void:
	var u = _w.units["b1"]
	for k in 3:
		_pl.place_point(Vector2(float(u.x) + 142.0 * float(k + 1), float(u.y)))

func _node(k: int) -> Vector2:
	return _pl.node_screen(k)

func _btn(name: String) -> Dictionary:
	return _ui.orders.buttons()[name]

func _tower_on_ideal(k: int) -> Vector2:
	var ideal: Vector2 = _pl.bombs.cone("b1", k)["ideal_aim"]
	_w.units["tower"].x = ideal.x
	_w.units["tower"].y = ideal.y
	_ui.marker_layer.update_poses()
	return ideal

func _pin(k: int) -> Dictionary:
	for m: Dictionary in _pl.bomb_marks():
		if int(m["step"]) == k and bool(m.get("pin", false)):
			return m
	return {}

func _band_of(k: int) -> String:
	return str(_pl.states()[k]["altitude_band"])

# --- 1 -------------------------------------------------------------------------------------------------------------------------

func _clicks() -> bool:
	_fresh()
	_three()
	eq(_pl.planned_count(), 3, "1. three steps are planned")
	eq(_pl.focus_step(), 2, "1. the step just placed is the selected one")
	var plan_before: Array = (_w.units["b1"].plan as Array).duplicate(true)
	var xs: Array = [float(_pl.states()[0]["x"]), float(_pl.states()[1]["x"]), float(_pl.states()[2]["x"])]
	# A click on step 1's node (the real mouse events through UnitUI).
	var edits := [0]
	_pl.plan_edited.connect(func(_id: String) -> void: edits[0] += 1)
	_click(_node(0))
	eq(_pl.focus_step(), 0, "1. a press and release on step 1's node selects step 1")
	eq(_pl.selected_step(), 0, "1. (selected_step is the same)")
	eq(_w.units["b1"].plan, plan_before, "1. and changed nothing in the plan")
	eq(edits[0], 0, "1. no edit was made")
	eq([float(_pl.states()[0]["x"]), float(_pl.states()[1]["x"]), float(_pl.states()[2]["x"])], xs, "1. no node moved")
	check(not _pl.edit_was_moved(), "1. the planner says it was a click")
	# A click 5 px off the node's centre is still the node's (the pick radius), and still moves nothing.
	_click(_node(1) + Vector2(5.0, 3.0))
	eq(_pl.focus_step(), 1, "1. a click near step 2's node selects step 2")
	eq(_w.units["b1"].plan, plan_before, "1. and moved nothing (the press was off the node's centre)")
	# The card names it.
	eq(_ui.orders._selected_line("b1", 3, 3), _st.text("orders.text.selected") % [2, 3], "1. the card's header says 'step 2 of 3'")
	eq(_st.text("orders.text.selected") % [2, 3], "step 2 of 3", "1. in those words")
	# Alex: a full plan says a step can be selected to change it.
	check(_st.text("orders.text.hint_full").contains("click a node"), "1. the full plan's hint says a node can be clicked to change a step: '%s'" % _st.text("orders.text.hint_full"))
	eq(_ui.orders._altitude_caption().begins_with("altitude, step 2:"), true, "1. the altitude line is about step 2 too")
	# Dive / Level / Climb act on the selected step.
	eq(_band_of(1), "high", "1. step 2 starts in the high band")
	eq(_btn("dive")["enabled"], true, "1. Dive is on offer")
	check(_ui.orders.press_button("dive"), "1. Dive, pressed on the card")
	eq(_band_of(1), "medium", "1. dived step 2 (the selected step), not the last one")
	eq(_band_of(0), "high", "1. step 1 is untouched")
	eq((_w.units["b1"].plan[0] as Dictionary).has("altitude_band"), false, "1. its request has no band of its own")
	check(_ui.orders.press_button("level"), "1. Level, pressed")
	eq(_band_of(1), "high", "1. level puts step 2 back")
	_click(_node(2))
	eq(_pl.focus_step(), 2, "1. step 3's node selects step 3")
	check(_ui.orders.press_button("dive"), "1. Dive on step 3")
	eq([_band_of(0), _band_of(1), _band_of(2)], ["high", "high", "medium"], "1. only step 3 dived")
	_pl.set_step_band(2, "high")
	# A click takes no Ready back (selecting is not an edit).
	_w.commit("ai")
	check(_ui.orders.press_button("ready"), "1. Ready")
	eq(_w.is_ready("local"), true, "1. the player is ready")
	_click(_node(0))
	eq(_w.is_ready("local"), true, "1. a click on a node does not take the Ready back")
	eq(_pl.focus_step(), 0, "1. though it selected the step")
	_w.withdraw("ai")
	_w.withdraw("local")
	# A click on the empty map selects nothing new.
	_click(_s(Vector2(1300.0, 2900.0)))
	eq(_pl.focus_step(), 0, "1. a click on the empty map leaves the selection")
	# For every unit: the fighter.
	_ui.select("p1")
	var fx := Vector2(1500.0, 2000.0)
	for k in 3:
		_pl.place_point(fx + Vector2(100.0 * float(k + 1), 0.0))
	eq(_pl.focus_step(), 2, "1. [fighter] the third step placed is selected")
	_click(_node(0))
	eq(_pl.focus_step(), 0, "1. [fighter] a click on its step 1 selects it")
	eq(_ui.orders._selected_line("p1", 3, 5), _st.text("orders.text.selected") % [1, 5], "1. [fighter] and the card says 'step 1 of 5'")
	var band0 := _band_of(0)
	var res: Dictionary = _pl.change_band(1)
	check(not res.is_empty() or _band_of(0) == band0, "1. [fighter] Climb acts on step 1 (or is refused there)")
	eq(_pl.focus_step(), 0, "1. [fighter] the selection stays on step 1")
	_pl.clear()
	# The selection ends with the unit: back on the bomber, its last step is selected again.
	_ui.select("b1")
	eq(_pl.focus_step(), 2, "1. the unit changed and came back: the last placed step is selected (no per-unit memory)")
	# ... and with the plan's shape.
	_click(_node(0))
	eq(_pl.focus_step(), 0, "1. step 1 selected")
	_pl.undo()
	eq(_pl.focus_step(), 1, "1. undo changes the plan's shape: the last placed step is selected")
	_click(_node(0))
	_pl.place_point(Vector2(1926.0, 2400.0))
	eq(_pl.focus_step(), 2, "1. a step placed: the new step is the selected one")
	_click(_node(0))
	_pl.clear()
	eq(_pl.focus_step(), -1, "1. cleared: nothing is selected")
	return true

func _s(p: Vector2) -> Vector2:
	return _xf * p

# --- 2 -------------------------------------------------------------------------------------------------------------------------

func _place_and_drag() -> bool:
	_fresh()
	var u = _w.units["b1"]
	var at := Vector2(float(u.x), float(u.y))
	# Placing, by a real press and drag in the fan.
	var fan_mid := Vector2.ZERO
	var outline := _pl.fan_outline_world()
	for q: Vector2 in outline:
		fan_mid += q
	fan_mid /= float(outline.size())
	_drag(_s(fan_mid), [_s(fan_mid + Vector2(0.0, 6.0))])
	eq(_pl.planned_count(), 1, "2. a press, drag and release in the fan places a step")
	eq(_pl.focus_step(), 0, "2. which is selected")
	_pl.place_point(at + Vector2(284.0, 0.0))
	eq(_pl.focus_step(), 1, "2. the next one placed is selected, not step 1")
	_click(_node(0))
	eq(_pl.focus_step(), 0, "2. step 1 selected by a click")
	# A drag inside the slop is still a click.
	var slop: float = _st.num("planner.select.slop_px")
	var x0: float = float(_pl.states()[1]["x"])
	_click(_node(1))
	_drag(_node(1), [_node(1) + Vector2(slop * 0.5, 0.0)])
	near(float(_pl.states()[1]["x"]), x0, 1e-9, "2. a drag that stayed inside the slop (%.0f px) moved nothing" % slop)
	eq(_pl.focus_step(), 1, "2. and selected the step")
	# A drag moves the node, and selects it.
	_click(_node(0))
	eq(_pl.focus_step(), 0, "2. step 1 selected")
	var before_y: float = float(_pl.states()[1]["y"])
	var to := _node(1) + Vector2(0.0, 30.0)
	_drag(_node(1), [_node(1) + Vector2(0.0, 12.0), to])
	check(absf(float(_pl.states()[1]["y"]) - before_y) > 5.0, "2. a drag still moves the node (%.1f m)" % (float(_pl.states()[1]["y"]) - before_y))
	eq(_pl.focus_step(), 1, "2. and the dragged step is the selected one")
	check(_pl.edit_was_moved(), "2. the planner says it was a drag")
	# The old API: begin_edit with a point moves at once and selects.
	_click(_node(0))
	_pl.begin_edit(1, Vector2(at.x + 284.0, at.y + 20.0))
	_pl.end_step()
	eq(_pl.focus_step(), 1, "2. begin_edit(k, point) selects k and steers there at once, as it always did")
	_pl.clear()
	return true

# --- 3 -------------------------------------------------------------------------------------------------------------------------

func _drop_on_step_two() -> bool:
	_fresh()
	_three()
	_tower_on_ideal(1)
	# Set the motion, come back to step 2 and tell it to drop the bomb (Alex's own flow): click step 2, target the tower, Drop.
	_click(_node(1))
	eq(_pl.focus_step(), 1, "3. step 2 is selected")
	eq(_btn("drop")["enabled"], false, "3. Drop is off with no target")
	_ui.set_target_unit("tower")
	eq(_btn("drop")["enabled"], true, "3. with the tower targeted (inside step 2's cone) Drop is on offer")
	eq(_btn("drop")["on"], false, "3. and not pressed")
	eq(_btn("drop")["label"], LABEL, "3. the button wears the special's words from data")
	check(_ui.orders.press_button("drop"), "3. Drop, pressed on the card")
	eq(_pl.bombs.drop_steps("b1"), [1] as Array[int], "3. step 2 -- not the last step -- carries the drop")
	eq(_pl.step_target(1)["unit"], "tower", "3. with the tower as its target")
	eq(_btn("drop")["on"], true, "3. the button's pressed state is on")
	eq(_pl.focus_step(), 1, "3. step 2 is still the selected step")
	# The lettering at the step says the special's name and action, and only there.
	var labels := _pl.step_labels()
	eq(labels[1].has(LABEL), true, "3. step 2's lettering says '%s'" % LABEL)
	eq(labels[0].has(LABEL) or labels[2].has(LABEL), false, "3. and steps 1 and 3 say nothing about it")
	eq(labels[1].has("drop"), false, "3. (not the bare 'drop' tag)")
	# Another step selected: the button is not pressed there; the drop stays on step 2.
	_click(_node(2))
	eq(_btn("drop")["on"], false, "3. step 3 selected: its Drop is not pressed")
	eq(_pl.step_has_drop(1), true, "3. while step 2 keeps its drop")
	_click(_node(1))
	eq(_btn("drop")["on"], true, "3. back on step 2 it is pressed again")
	# Off again from the same step.
	check(_ui.orders.press_button("drop"), "3. pressed again")
	eq(_pl.bombs.drop_steps("b1").size(), 0, "3. it toggles off")
	eq(_pl.step_labels()[1].has(LABEL), false, "3. and the lettering goes with it")
	# The existing B key still does what it did, on the selected step; nothing new was added (section 8).
	var key := InputEventKey.new()
	key.keycode = KEY_B
	key.pressed = true
	_ui.set_target_unit("tower")
	check(_ui._key(key), "3. the existing B key drops on the selected step")
	eq(_pl.bombs.drop_steps("b1"), [1] as Array[int], "3. step 2's")
	_pl.clear()
	return true

# --- 4 -------------------------------------------------------------------------------------------------------------------------

func _pinned() -> bool:
	_fresh()
	_three()
	_tower_on_ideal(1)
	_click(_node(1))
	_ui.set_target_unit("tower")
	_ui.orders.press_button("drop")
	var pin := _pin(1)
	eq(pin.is_empty(), false, "4. step 2's picture is pinned")
	eq([pin["pin"], pin["selected"], pin["num"], pin["quiet"]], [true, true, 2, false], "4. a full picture for step 2, the selected step")
	check((pin["node"] as Vector2).distance_to(_node(1)) < 1e-3, "4. its line starts at step 2's node")
	check((pin["lands"] as Vector2).is_finite() and (pin["lands"] as Vector2).distance_to(_node(1)) > 50.0, "4. and ends at where the bombs land, away from the node")
	check(not (pin["aoe"] as Dictionary).is_empty() and (pin["aoe"]["tiers"] as Array).size() > 0, "4. ending in the area of effect (the sim's blast tiers)")
	eq(pin["target"]["unit"], "tower", "4. at the target")
	eq((pin["cone"] as PackedVector2Array).size(), 0, "4. with no cone wash in it")
	# Step 3 selected and MOVED: step 2's picture does not move.
	var node_b: Vector2 = pin["node"]
	var lands_b: Vector2 = pin["lands"]
	var aim_b: Vector2 = pin["aim"]
	var tiers_b: Array = (pin["aoe"]["tiers"] as Array).duplicate(true)
	_click(_node(2))
	_drag(_node(2), [_node(2) + Vector2(0.0, 20.0), _node(2) + Vector2(0.0, 60.0)])
	eq(_pl.focus_step(), 2, "4. step 3 is the selected step")
	var moved := _pin(1)
	check((moved["node"] as Vector2).distance_to(node_b) < 1e-3, "4. step 2's line still starts at its node (step 3 moved)")
	check((moved["lands"] as Vector2).distance_to(lands_b) < 1e-3 and (moved["aim"] as Vector2).distance_to(aim_b) < 1e-3, "4. and still ends where it did")
	eq(moved["aoe"]["tiers"], tiers_b, "4. with the same area of effect")
	eq([moved["selected"], moved["pin"]], [false, true], "4. now an unselected step's picture (quieter), still drawn")
	# Placing and undoing other steps: the same.
	_pl.undo()
	_pl.place_point(Vector2(1926.0, 2400.0))
	check((_pin(1)["lands"] as Vector2).distance_to(lands_b) < 1e-3, "4. a step undone and placed again: step 2's landing has not moved")
	# Moving the step BEFORE it keeps the target where it was (the picture's end), whatever the step's node does.
	_click(_node(0))
	_drag(_node(0), [_node(0) + Vector2(0.0, 8.0)])
	check((_pin(1)["lands"] as Vector2).distance_to(lands_b) < 1.0 or _pl.drop_blocked(1), "4. step 1 moved a little: the landing stays on the target (or the step is marked)")
	# One picture for each step with a drop.
	_pl.clear()
	_three()
	_click(_node(1))
	_tower_on_ideal(1)
	_ui.set_target_unit("tower")
	_ui.orders.press_button("drop")
	_click(_node(2))
	var c3: Dictionary = _pl.bombs.cone("b1", 2)
	_ui.set_target_point(c3["ideal_aim"])
	check(_ui.orders.press_button("drop"), "4. step 3 drops on a point of its own")
	var marks: Array = _pl.bomb_marks()
	var pins := marks.filter(func(m: Dictionary) -> bool: return bool(m.get("pin", false)))
	eq(pins.size(), 2, "4. one picture for each of the player's steps with a drop")
	var sel_n := 0
	for m: Dictionary in pins:
		if bool(m["selected"]):
			sel_n += 1
			eq(m["num"], 3, "4. the selected one is step 3's")
	eq(sel_n, 1, "4. exactly one is the selected step's")
	# Every look of the pinned picture is drawn to the end (a runtime error ends a draw silently: the node counts them).
	var node: Node = _ui.bomb_aim
	node.refresh()
	var drawn: int = node.draw_count
	await get_tree().process_frame
	await get_tree().process_frame
	check(node.draw_count > drawn and node.marks_draw_count > 0, "4. the bomb node drew the pictures (%d, %d)" % [node.draw_count, node.marks_draw_count])
	eq(node.failed_draws, 0, "4. every part of the pictures ran to its end")
	# The node's own bomb mark: the planner draws one beside each step with its special on (a record is the step list).
	eq(_pl.bombs.drop_steps("b1"), [1, 2] as Array[int], "4. steps 2 and 3 carry the little bomb at their nodes")
	# The picture of a drop is never the enemy's (the plan-read rule).
	_ui.select("eb")
	for m: Dictionary in _pl.bomb_marks():
		check(m["unit"] != "eb", "4. no mark is the enemy's")
	_fresh()
	return true

# --- 5 -------------------------------------------------------------------------------------------------------------------------

func _outline() -> bool:
	_fresh()
	_three()
	_tower_on_ideal(1)
	_click(_node(1))
	_ui.set_target_unit("tower")
	# No drop, a target, the pointer nowhere: nothing is drawn of the cone (the faint preview wash is off).
	eq(_st.flag("bombs.aim.preview_cone"), false, "5. the faint preview cone is off by default")
	eq(_pl.bomb_marks().size(), 0, "5. a target and no drop: no mark at all (no big blob)")
	# The pointer on the Drop button (through the card's own mouse handling): the selected step's cone, as a thin outline.
	var drop_rect: Rect2 = _btn("drop")["rect"]
	_ui.orders._gui_input(_motion(drop_rect.get_center()))
	eq(_ui.orders.hover_button(), "drop", "5. the card knows the pointer is on the button")
	eq(_pl.drop_hover(), true, "5. and tells the planner")
	var out: Array = _pl.bomb_marks()
	eq(out.size(), 1, "5. one record: the selected step's cone")
	if out.size() == 1:
		eq([out[0]["preview"], out[0]["outline"], out[0]["step"]], [true, true, 1], "5. an outline alone, for step 2")
		check((out[0]["cone"] as PackedVector2Array).size() >= 3, "5. with the cone's points")
	# Even with Drop off (no target): the outline says where the target has to be.
	_ui.target.clear()
	eq(_btn("drop")["enabled"], false, "5. (Drop is off: no target)")
	eq(_pl.bomb_marks().size(), 1, "5. and the outline still shows while the pointer is on the button")
	# The pointer leaves the button: gone.
	_ui.orders._gui_input(_motion(Vector2(5.0, 5.0)))
	eq(_pl.drop_hover(), false, "5. the pointer left the button")
	eq(_pl.bomb_marks().size(), 0, "5. the outline is gone")
	# On another button: no outline.
	_ui.orders._gui_input(_motion(_btn("dive")["rect"].get_center()))
	eq(_pl.drop_hover(), false, "5. the pointer on Dive does not show the cone")
	_ui.orders._gui_input(_motion(Vector2(5.0, 5.0)))
	# A drop on, the pointer away: the picture without the cone; on the button: the same with the outline in it.
	_ui.set_target_unit("tower")
	_ui.orders.press_button("drop")
	eq((_pin(1)["cone"] as PackedVector2Array).size(), 0, "5. a drop on: its picture carries no cone")
	_pl.set_drop_hover(true)
	check((_pin(1)["cone"] as PackedVector2Array).size() >= 3, "5. the pointer on the button: the selected step's picture carries the outline")
	_pl.set_drop_hover(false)
	# Another step's picture never carries a cone, hovered or not.
	_click(_node(2))
	_pl.set_drop_hover(true)
	eq((_pin(1)["cone"] as PackedVector2Array).size(), 0, "5. step 2's picture is not the selected step's: no cone in it (step 3 selected)")
	_pl.set_drop_hover(false)
	# Dragging a landing point shows the cone while it is held.
	_click(_node(1))
	var handle: Vector2 = _pin(1)["aim"]
	eq((_pin(1)["cone"] as PackedVector2Array).size(), 0, "5. before the drag: no cone")
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true, handle))
	eq(_pl.is_aiming(), true, "5. a press on the landing point takes hold of it")
	eq(_pl.focus_step(), 1, "5. and selects its step")
	check((_pin(1)["cone"] as PackedVector2Array).size() >= 3, "5. held: the cone shows as an outline")
	_ui._input(_motion(handle + Vector2(10.0, 4.0)))
	_ui._input(_mouse(MOUSE_BUTTON_LEFT, false, handle + Vector2(10.0, 4.0)))
	eq(_pl.is_aiming(), false, "5. let go")
	eq((_pin(1)["cone"] as PackedVector2Array).size(), 0, "5. and the cone is gone again")
	eq(_pl.step_target(1)["unit"], "", "5. (dragging the landing moved the step's target: it is a point now)")
	# The old looks stay selectable in data.
	var pin_cfg: Dictionary = ((UiStyle.shared() as UiStyle).ui["bombs"] as Dictionary)["pin"]
	var aim_cfg: Dictionary = ((UiStyle.shared() as UiStyle).ui["bombs"] as Dictionary)["aim"]
	pin_cfg["enabled"] = false
	var legacy: Array = _pl.bomb_marks()
	eq(legacy.size(), 1, "5. [pin off] the old look: one mark")
	eq(bool(legacy[0].get("pin", false)), false, "5. [pin off] not a pinned picture")
	check((legacy[0]["cone"] as PackedVector2Array).size() >= 3, "5. [pin off] the card's step has its cone, as before")
	pin_cfg["enabled"] = true
	aim_cfg["preview_cone"] = true
	_pl.set_focus_step(2)
	_ui.set_target_unit("tower")
	check(_pl.bomb_marks().any(func(m: Dictionary) -> bool: return bool(m.get("preview", false)) and not bool(m.get("outline", false))), "5. [preview_cone on] the old faint preview comes back from the data")
	aim_cfg["preview_cone"] = false
	_fresh()
	return true

# --- 6 -------------------------------------------------------------------------------------------------------------------------

func _words() -> bool:
	_fresh()
	eq(_ui.orders.target_caption(), _st.text("bombs.text.target_none"), "6. the target line is there with no step placed: '%s'" % _ui.orders.target_caption())
	eq(_st.text("bombs.text.target_none"), "no target: click an enemy or right-click the map", "6. in the lead's words")
	_three()
	_tower_on_ideal(1)
	_click(_node(1))
	eq(_ui.orders.target_caption(), "no target: click an enemy or right-click the map", "6. no target: the card says what to click")
	eq(_ui.orders.bomb_caption(), "Bomb Drop needs a target", "6. and why Drop is off, in plain words: '%s'" % _ui.orders.bomb_caption())
	eq(_btn("drop")["enabled"], false, "6. (Drop is off)")
	_ui.set_target_unit("tower")
	eq(_ui.orders.target_caption(), "target: radio tower", "6. a unit target: 'target: radio tower'")
	_ui.set_target_point(Vector2(2000.0, 2900.0))
	eq(_ui.orders.target_caption(), "target: a point on the map", "6. a point target: '%s'" % _ui.orders.target_caption())
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.target_outside") % 2, "6. outside step 2's cone: '%s'" % _ui.orders.bomb_caption())
	# The step's own target once its special is on, with the accuracy.
	_ui.set_target_unit("tower")
	_ui.orders.press_button("drop")
	check(_ui.orders.target_caption().begins_with("target: radio tower") and _ui.orders.target_caption().contains("accuracy"), "6. with the drop on: '%s'" % _ui.orders.target_caption())
	check(_ui.orders.bomb_caption().begins_with("step 2: %s" % LABEL), "6. and the card's line names the step and the special: '%s'" % _ui.orders.bomb_caption())
	# The step selected has no drop: the target line is the selection's again.
	_ui.target.clear()
	_click(_node(2))
	eq(_ui.orders.target_caption(), _st.text("bombs.text.target_none"), "6. step 3 has no drop and nothing is targeted: no target")
	_click(_node(1))
	check(_ui.orders.target_caption().begins_with("target: radio tower"), "6. step 2 selected: its own target, though the selection is empty")
	# No step placed, no drops left.
	_pl.clear()
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.place_first") % LABEL, "6. nothing placed: '%s'" % _ui.orders.bomb_caption())
	# A fighter has no special: no target line, no bomb line.
	_ui.select("p1")
	_pl.place_point(Vector2(1600.0, 2000.0))
	eq(_ui.orders.target_caption(), "", "6. a fighter: no target line")
	eq(_ui.orders.bomb_caption(), "", "6. and no line about bombs")
	eq(_btn("drop")["label"], _st.text("bombs.text.label"), "6. its special button is the neutral one")
	eq(_btn("drop")["enabled"], false, "6. and off")
	_pl.clear()
	# An enemy selected: nothing.
	_ui.select("eb")
	eq(_ui.orders.target_caption(), "", "6. an enemy unit selected: no target line")
	_fresh()
	return true

# --- 7 -------------------------------------------------------------------------------------------------------------------------

func _strip() -> bool:
	_fresh()
	var n: int = _w.steps_per_turn("b1")
	var marks: Array = _ui.orders.step_marks()
	eq(marks.size(), n, "7. one mark for each step of the bomber's turn (%d)" % n)
	for i in marks.size():
		eq(marks[i]["index"], i, "7. mark %d is in order" % i)
	eq(marks[0]["state"], "next", "7. nothing placed: step 1 is the next step")
	eq([marks[1]["state"], marks[2]["state"]], ["later", "later"], "7. the others are later")
	eq([marks[0]["enabled"], marks[1]["enabled"], marks[2]["enabled"]], [true, false, false], "7. only the next one is clickable")
	eq(marks[0]["selected"], true, "7. with nothing placed the next step is the current one")
	# Two steps placed.
	var u = _w.units["b1"]
	_pl.place_point(Vector2(float(u.x) + 142.0, float(u.y)))
	_pl.place_point(Vector2(float(u.x) + 284.0, float(u.y)))
	marks = _ui.orders.step_marks()
	eq(marks.size(), n, "7. still one for each step")
	eq([marks[0]["state"], marks[1]["state"], marks[2]["state"]], ["planned", "planned", "next"], "7. planned, planned, next")
	eq([marks[0]["enabled"], marks[1]["enabled"], marks[2]["enabled"]], [true, true, true], "7. a planned step and the next one are clickable")
	eq([marks[0]["selected"], marks[1]["selected"], marks[2]["selected"]], [false, true, false], "7. the step just placed is the selected one")
	eq([marks[0]["special"], marks[1]["special"]], [false, false], "7. no special on any step")
	# The strip's click selects a planned step, exactly as its node does.
	check(_ui.orders.press_button("step_0"), "7. a click on mark 1")
	eq(_pl.focus_step(), 0, "7. selects step 1 on the map")
	marks = _ui.orders.step_marks()
	eq([marks[0]["selected"], marks[1]["selected"]], [true, false], "7. and the strip shows it")
	_click(_node(1))
	marks = _ui.orders.step_marks()
	eq([marks[0]["selected"], marks[1]["selected"], marks[2]["selected"]], [false, true, false], "7. a click on step 2's NODE moves the strip's selection too")
	check(_ui.orders.press_button("step_1"), "7. and mark 2 selects step 2 again")
	eq(_pl.focus_step(), 1, "7. the same step")
	eq(_ui.orders._selected_line("b1", 2, 3), "step 2 of 3", "7. the header says so")
	# The NEXT unplanned step: clicking it selects 'the next step to place'.
	check(_ui.orders.press_button("step_2"), "7. a click on the next step's mark (3)")
	eq(_pl.focus_step(), -1, "7. no placed step is selected")
	eq(_pl.is_placing(), true, "7. the next step is the selected one: the fan places it")
	marks = _ui.orders.step_marks()
	eq([marks[0]["selected"], marks[1]["selected"], marks[2]["selected"]], [false, false, true], "7. the strip shows step 3 as the current one")
	eq(_ui.orders._selected_line("b1", 2, 3), "step 3 of 3 next", "7. the header: '%s'" % _ui.orders._selected_line("b1", 2, 3))
	eq(_pl.next_step_index(), 2, "7. the fan is for step 3, as it always was")
	eq(_pl.fan_outline_world().size() > 0, true, "7. and is there")
	eq([_btn("dive")["enabled"], _btn("climb")["enabled"], _btn("level")["enabled"]], [false, false, false], "7. Dive / Level / Climb have no step to act on")
	eq(_btn("drop")["enabled"], false, "7. nor has the special")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.place_first") % LABEL, "7. which says: '%s'" % _ui.orders.bomb_caption())
	# A later step is refused and nothing changes.
	check(not _ui.orders.press_button("step_3") or n <= 3, "7. a step beyond the next (4, if the unit has one) is refused")
	if n > 3:
		eq(_ui.orders.step_marks()[3]["enabled"], false, "7. it is shown disabled")
	eq(_pl.is_placing(), true, "7. the selection is as it was")
	check(not _ui.orders.press_button("step_9"), "7. a step the unit has not is refused")
	# Placing a step in the fan selects it, and the strip follows.
	_pl.place_point(Vector2(float(u.x) + 426.0, float(u.y)))
	eq(_pl.focus_step(), 2, "7. step 3 placed: selected")
	marks = _ui.orders.step_marks()
	eq([marks[0]["state"], marks[1]["state"], marks[2]["state"]], ["planned", "planned", "planned"], "7. all planned")
	eq(marks[2]["selected"], true, "7. and step 3 is the selected one")
	eq(_pl.next_step_index(), -1, "7. the plan is full")
	check(not _pl.select_next_step(), "7. there is no next step to select")
	# The special shows on its step's mark.
	_tower_on_ideal(1)
	_click(_node(1))
	_ui.set_target_unit("tower")
	_ui.orders.press_button("drop")
	marks = _ui.orders.step_marks()
	eq([marks[0]["special"], marks[1]["special"], marks[2]["special"]], [false, true, false], "7. step 2's mark carries the special")
	# Hit testing, the real way: a click at a mark's centre through the card's own handler.
	var c0: Vector2 = marks[0]["center"]
	eq(_ui.orders.button_at(c0), "step_0", "7. a point on mark 1 is mark 1")
	_ui.orders._gui_input(_mouse(MOUSE_BUTTON_LEFT, true, c0))
	eq(_pl.focus_step(), 0, "7. a mouse press on it selects step 1")
	_ui.orders._gui_input(_motion(marks[2]["center"]))
	eq(_ui.orders.hover_button(), "step_2", "7. the strip marks hover like the buttons")
	_ui.orders._gui_input(_motion(Vector2(5.0, 5.0)))
	# The strip is an on-screen control only: marks fit the card, and are on the header row.
	var last: Rect2 = marks[marks.size() - 1]["rect"]
	check(last.end.x <= _ui.orders.size.x and (marks[0]["rect"] as Rect2).position.x > 0.0, "7. the marks sit inside the card")
	# Locked (the end card is up): disabled.
	_ui.orders.locked = true
	for m: Dictionary in _ui.orders.step_marks():
		eq(m["enabled"], false, "7. locked: mark %d is disabled" % int(m["index"]))
	check(not _ui.orders.press_button("step_0"), "7. and refuses a click")
	_ui.orders.locked = false
	# Hidden for an enemy; nothing outside the planning phase; a fighter has its own five.
	_ui.select("eb")
	eq(_ui.orders.step_marks(), [], "7. an enemy unit selected: no strip")
	check(not _ui.orders.press_button("step_0"), "7. and no click does anything")
	_ui.select("p1")
	eq(_ui.orders.step_marks().size(), _w.steps_per_turn("p1"), "7. a fighter has one mark for each of its %d steps" % _w.steps_per_turn("p1"))
	_ui.select("")
	eq(_ui.orders.step_marks(), [], "7. nothing selected: no strip")
	_fresh()
	return true

# --- 8 -------------------------------------------------------------------------------------------------------------------------

func _data_words() -> bool:
	# No key was added (Alex: on-screen buttons first, no keyboard mapping); the existing ones are as they were.
	var keys: Dictionary = _st.lookup("keys")
	var names: Array = []
	for k: String in keys:
		if not k.begins_with("_"):
			names.append(k)
	names.sort()
	var want := ["clear", "clear_target", "climb", "dive", "drop", "next_unit", "ready", "undo"]
	eq(names, want, "8. the key bindings are the ones there were: %s" % str(names))
	eq(_st.text("keys.drop"), "B", "8. B, left alone")
	# The special's words are the unit's data: change them and everything that names the special follows.
	var def = _w.units["b1"].def
	var original_name: String = str((def.specials[0] as Dictionary)["name"])
	var original_action: String = str((def.specials[0] as Dictionary)["action"])
	eq([original_name, original_action], ["Bomb", "Drop"], "8. the bomber's special is Bomb / Drop in data/units/bomber.json")
	_fresh()
	_three()
	_tower_on_ideal(1)
	_click(_node(1))
	_ui.set_target_unit("tower")
	_ui.orders.press_button("drop")
	(def.specials[0] as Dictionary)["name"] = "Radio"
	(def.specials[0] as Dictionary)["action"] = "On"
	eq(_pl.special_label("b1"), "Radio On", "8. the planner reads 'Radio On'")
	eq(_pl.step_labels()[1].has("Radio On"), true, "8. the step's lettering says 'Radio On'")
	eq(_pl.step_labels()[1].has(LABEL), false, "8. not 'Bomb Drop'")
	eq(_btn("drop")["label"], "Radio On", "8. the button wears it")
	check(_ui.orders.bomb_caption().begins_with("step 2: Radio On"), "8. and the card's line: '%s'" % _ui.orders.bomb_caption())
	(def.specials[0] as Dictionary)["name"] = "Turret"
	(def.specials[0] as Dictionary)["action"] = "Fire"
	eq(_pl.step_labels()[1].has("Turret Fire"), true, "8. 'Turret Fire' likewise")
	(def.specials[0] as Dictionary)["name"] = original_name
	(def.specials[0] as Dictionary)["action"] = original_action
	eq(_pl.step_labels()[1].has(LABEL), true, "8. put back, the step says 'Bomb Drop' again")
	_fresh()
	return true
