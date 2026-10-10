extends "res://scripts/test_support/test_case.gd"

# THE TARGET SELECTION IN THE INTERFACE (Track T, 2026-10-10). Alex, decision special-targeting: "when you have a friendly unit
# selected, you can also select either an enemy unit or a point on the map. The only thing it does is show on the side view and
# it is the target that the special will use if activated. Non-specials don't need targets because they autofire." "No target set
# means you can't activate special." "The special is active and targeted for the step" (a unit "could have two targets for
# different specials across two steps"). Set by "left-click an enemy unit, right-click a point on the map -- fine for now. Right
# click drag is awkward so we will change later". A target outside the step's cone: the special cannot be activated and the card
# says why; dragging a step's aim marker moves that step's target. Then (on a moving target): a unit target follows the unit.
# And on a target that leaves the cone: data/sim/bombs.json outside_cone_mode ("hold" or "poor_shot"), tested in both settings.
# Headless, on the real World, mounted through UnitUI as the assembly mounts it:
#
#   1. the style data and the seam (UiTarget, UnitUI.target, MotionPlanner.step_target)
#   2. THE CLICKS: left on an enemy sets the target and keeps the friendly selected; with no friendly selected it selects the
#      enemy; left on a friendly selects it; right press-and-release without movement sets a point (or the enemy under the
#      pointer); a right DRAG sets nothing (it pans); Esc clears the target before anything else; the target clears when the
#      friendly selection changes
#   3. DROP'S ENABLE RULES: no target, a target outside the step's cone, a target inside -- and the card says why
#   4. THE STEP'S TARGET: activation stores it (a unit's id, or a point) with the aim on it; two steps, two targets; the target
#      selection changing later changes nothing already activated; dragging the aim makes the step's target a point
#   5. A STEP MOVED: it keeps its drop and its target, it is MARKED when its cone leaves the target ("will not release" under
#      hold, "poor shot" under poor_shot) -- the card, the map's mark and the step's lettering -- and the sim releases nothing
#      (hold) or a poor stick (poor_shot)
#   6. ON THE MAP: the target's mark is drawn (unit and point), a unit out of sight keeps the place it was last seen, a unit in
#      sight is followed; another player's drop shows its target as a small mark; an enemy's targets are never read or drawn
#   7. THE WIRE: the step's target crosses with the plan and survives the snapshot

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiTarget = preload("res://scripts/ui/ui_target.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const CombatResolver = preload("res://scripts/sim/combat_resolver.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const TargetArt = preload("res://scripts/ui/target_art.gd")

const PPM := 0.5
const ORIGIN := Vector2(1300.0, 1900.0)

var _w: World
var _ui: UnitUI
var _pl: MotionPlanner
var _xf: Transform2D
var _st: UiStyle

func setup(_main) -> void:
	timeout_seconds = 120.0
	_st = UiStyle.new()
	_check_data(_st)
	_w = _make_world()
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		finish()
		return
	_xf = Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, _xf, "local")
	_ui.auto_resolve = false
	_pl = _ui.planner
	eq(_seam(), true, "1. the seam part ran to its end")
	eq(_clicks(), true, "2. the click part ran to its end")
	eq(_enable_rules(), true, "3. the enable-rules part ran to its end")
	eq(_step_target(), true, "4. the step-target part ran to its end")
	eq(_step_moved("hold"), true, "5. the moved-step part (hold) ran to its end")
	eq(_step_moved("poor_shot"), true, "5. the moved-step part (poor_shot) ran to its end")
	eq(await _on_the_map(), true, "6. the map part ran to its end")
	eq(_wire(), true, "7. the wire part ran to its end")
	finish()

# A fresh World and a fresh interface on it (a resolved turn leaves the old ones changed).
func _rebuild() -> void:
	if _ui != null:
		remove_child(_ui)
		_ui.queue_free()
	_w = _make_world()
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, _xf, "local")
	_ui.auto_resolve = false
	_pl = _ui.planner

func _make_world() -> World:
	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0, "altitude_band": "high"})
	w.add_unit({"id": "b2", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2900.0, "heading": 0.0, "altitude_band": "medium"})
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2000.0, "heading": 0.0})
	w.add_unit({"id": "eb", "type": "bomber", "side": "axis", "controller": "ai", "x": 2400.0, "y": 2000.0, "heading": PI, "altitude_band": "high"})
	w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 2785.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2600.0, "y": 2700.0, "heading": 0.4})
	return w

# --- helpers --------------------------------------------------------------------------------------

func _s(p: Vector2) -> Vector2:
	return _xf * p

func _mouse(button: int, pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = button
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	return ev

func _motion(pos: Vector2, rel: Vector2) -> InputEventMouseMotion:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.relative = rel
	ev.button_mask = MOUSE_BUTTON_MASK_RIGHT
	return ev

# A left click as the engine delivers it: the press, then the release, both unhandled by the GUI.
func _left_click(screen_pt: Vector2) -> void:
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true, screen_pt))
	_ui._input(_mouse(MOUSE_BUTTON_LEFT, false, screen_pt))
	_ui._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false, screen_pt))

func _right_click(screen_pt: Vector2) -> void:
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, true, screen_pt))
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, false, screen_pt))

func _esc() -> bool:
	var key := InputEventKey.new()
	key.keycode = KEY_ESCAPE
	key.pressed = true
	return _ui._key(key)

# The tower where the first step's ideal aim is, so the cone holds it.
func _tower_on_ideal(k: int = 0, id: String = "b1") -> Vector2:
	var ideal: Vector2 = _pl.bombs.cone(id, k)["ideal_aim"]
	_w.units["tower"].x = ideal.x
	_w.units["tower"].y = ideal.y
	_ui.marker_layer.update_poses()
	return ideal

func _fresh(id: String = "b1") -> void:
	_ui.select("")
	_ui.select(id)
	_pl.clear()
	_ui.target.clear()

# --- 1 ---------------------------------------------------------------------------------------------

func _check_data(st: UiStyle) -> void:
	for n: String in ["target.right_click.slop_px", "target.aim_drag_slop_px", "target.unit.pad_px", "target.unit.min_half_px", "target.unit.arm_px",
			"target.unit.line_px", "target.unit.halo_px", "target.point.r_px", "target.point.line_px", "target.point.dot_px", "target.point.halo_px",
			"target.unseen_alpha", "target.quiet.k", "target.quiet.alpha", "target.blocked.slash_px", "target.blocked.line_px", "target.blocked.label_px"]:
		check(st.lookup(n) is float or st.lookup(n) is int, "ui.json has a number at '%s'" % n)
	for n: String in ["bombs.text.no_target", "bombs.text.target_outside", "bombs.text.wont_release", "bombs.text.poor_shot", "bombs.text.step_tag_blocked",
			"bombs.text.step_tag_poor", "bombs.text.expected_on", "keys.clear_target"]:
		check(st.lookup(n) is String, "ui.json has a string at '%s'" % n)
	for n: String in ["target.role", "target.halo_role"]:
		check(st.lookup(n) is Dictionary, "%s is a palette role (no hex in draw code)" % n)
	eq(st.text("keys.clear_target"), "Escape", "1. Esc clears the target")
	# Readable at both zooms: the marks are screen px, not metres.
	check(st.num("target.point.r_px") >= 6.0 and st.num("target.unit.min_half_px") >= 10.0, "1. the marks are big enough to read at the planning zoom (screen px)")
	eq(st.errors.size(), 0, "no style lookups failed: %s" % str(st.errors))

func _seam() -> bool:
	check(_ui.target != null and _ui.target is UiTarget, "1. UnitUI.target is a UiTarget")
	check(_ui.target == _pl.target, "1. shared with the planner")
	var t := UiTarget.new()
	var seen := [0]
	t.changed.connect(func() -> void: seen[0] += 1)
	eq(t.is_set(), false, "1. nothing set to begin with")
	eq(t.kind, "", "1. kind is empty")
	eq(t.position_m(_w), Vector2.INF, "1. and has no place")
	t.set_unit("tower", Vector2(10.0, 20.0))
	eq([t.kind, t.unit_id, t.point_m], ["unit", "tower", Vector2(10.0, 20.0)], "1. a unit target: kind, unit_id and the place it was seen")
	t.set_point(Vector2(5.0, 6.0))
	eq([t.kind, t.unit_id, t.point_m], ["point", "", Vector2(5.0, 6.0)], "1. a point target: kind point, no unit")
	eq(t.position_m(_w), Vector2(5.0, 6.0), "1. position_m of a point is the point")
	t.clear()
	eq(t.is_set(), false, "1. clear()")
	eq(seen[0], 3, "1. changed() fired once for each change (and not for the same clear twice)")
	t.clear()
	eq(seen[0], 3, "1. and not for clearing nothing")
	t.set_unit("tower", Vector2(1.0, 1.0))
	eq(t.position_m(_w), Vector2(2785.0, 2400.0), "1. a unit's position is read from the World (it follows the unit)")
	_w.units["tower"].x = 2800.0
	eq(t.position_m(_w), Vector2(2800.0, 2400.0), "1. and moves with it")
	_w.units["tower"].x = 2785.0
	eq(t.prune(_w), false, "1. a unit that is up is kept")
	_w.units["tower"].down = true
	eq(t.prune(_w), true, "1. a unit that is down is let go")
	_w.units["tower"].down = false
	# step_target on a plan.
	_fresh()
	eq(_pl.step_target(0), {}, "1. step_target of a step with no drop is {}")
	return true

# --- 2 ---------------------------------------------------------------------------------------------

func _clicks() -> bool:
	var tower_s := _s(Vector2(_w.units["tower"].x, _w.units["tower"].y))
	var eb_s := _s(Vector2(_w.units["eb"].x, _w.units["eb"].y))
	_ui.marker_layer.update_poses()
	# No friendly selected: an enemy is selected as before.
	_ui.select("")
	_left_click(tower_s)
	eq(_ui.selection.unit_id, "tower", "2. no friendly selected: a left click on an enemy selects it (as it always did)")
	eq(_ui.target.is_set(), false, "2. and sets no target")
	# A friendly selected: an enemy click is a target and the friendly stays.
	_ui.select("b1")
	_left_click(tower_s)
	eq(_ui.selection.unit_id, "b1", "2. a friendly selected: the click keeps it selected")
	eq([_ui.target.kind, _ui.target.unit_id], ["unit", "tower"], "2. and the tower is the target")
	eq(_ui.target.point_m, Vector2(2785.0, 2400.0), "2. (seen where it stands)")
	_left_click(_s(Vector2(_w.units["aa1"].x, _w.units["aa1"].y)))
	eq(_ui.target.unit_id, "aa1", "2. another enemy clicked: the target moves to it")
	eq(_ui.selection.unit_id, "b1", "2. b1 is still the selected unit")
	_left_click(eb_s)
	eq(_ui.target.unit_id, "eb", "2. an enemy PLANE is a target too (a special may follow it)")
	# Non-specials need no targets: a fighter selected can have one (it shows on the side view), and autofires regardless.
	_ui.select("p1")
	eq(_ui.target.is_set(), false, "2. the friendly selection changed: the target is cleared (no per-unit memory)")
	_left_click(tower_s)
	eq([_ui.selection.unit_id, _ui.target.unit_id], ["p1", "tower"], "2. a fighter selected takes a target as well")
	# A friendly's marker selects it (and clears the target).
	_left_click(_s(Vector2(_w.units["b1"].x, _w.units["b1"].y)))
	eq(_ui.selection.unit_id, "b1", "2. a left click on a friendly selects it")
	eq(_ui.target.is_set(), false, "2. and the target is cleared")
	_ui.select("")
	eq(_ui.target.is_set(), false, "2. nothing selected, no target")
	# Right click: a point on the map.
	var empty_s := _s(Vector2(1900.0, 2900.0))
	_right_click(empty_s)
	eq(_ui.target.is_set(), false, "2. no friendly selected: a right click sets nothing")
	_ui.select("b1")
	_right_click(empty_s)
	eq(_ui.target.kind, "point", "2. a friendly selected: a right press and release without movement sets a POINT target")
	check(_ui.target.point_m.distance_to(Vector2(1900.0, 2900.0)) < 1e-3, "2. where the pointer was (%s)" % str(_ui.target.point_m))
	# A right click on an enemy is that enemy.
	_right_click(tower_s)
	eq([_ui.target.kind, _ui.target.unit_id], ["unit", "tower"], "2. a right click on an enemy marker targets the enemy")
	# A right DRAG is the camera's pan: no target.
	_ui.target.clear()
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, true, empty_s))
	_ui._input(_motion(empty_s + Vector2(30.0, 0.0), Vector2(30.0, 0.0)))
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, false, empty_s + Vector2(30.0, 0.0)))
	eq(_ui.target.is_set(), false, "2. a right DRAG (it pans) sets no target")
	# A wobble inside the slop is still a click.
	var slop: float = _st.num("target.right_click.slop_px")
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, true, empty_s))
	_ui._input(_motion(empty_s + Vector2(slop * 0.5, 0.0), Vector2(slop * 0.5, 0.0)))
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, false, empty_s + Vector2(slop * 0.5, 0.0)))
	eq(_ui.target.kind, "point", "2. a press and release that moved less than the slop (%.0f px) is a click" % slop)
	# The press must be the same button's: a left release does not finish a right click.
	_ui.target.clear()
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, true, empty_s))
	_ui._input(_mouse(MOUSE_BUTTON_LEFT, false, empty_s))
	eq(_ui.target.is_set(), false, "2. a left release is not a right click")
	_ui._input(_mouse(MOUSE_BUTTON_RIGHT, false, empty_s))
	eq(_ui.target.kind, "point", "2. the right release is")
	# A card under the pointer is clicked, not targeted through.
	_ui.target.clear()
	var on_card: Vector2 = _ui.roster.get_global_rect().get_center()
	_right_click(on_card)
	eq(_ui.target.is_set(), false, "2. a right click on the roster sets nothing")
	# Outside the map: nothing.
	_right_click(Vector2(-6000.0, 100.0))
	eq(_ui.target.is_set(), false, "2. a right click off the map sets nothing")
	# A destroyed enemy is not a target.
	_w.units["aa1"].down = true
	eq(_ui.set_target_unit("aa1"), false, "2. a unit that is down cannot be targeted")
	_w.units["aa1"].down = false
	eq(_ui.set_target_unit("b2"), false, "2. nor a friendly unit")
	# Esc.
	_ui.target.set_point(Vector2(2000.0, 2000.0))
	eq(_esc(), true, "2. Esc with a target clears it and is taken")
	eq(_ui.target.is_set(), false, "2. the target is gone")
	eq(_ui.selection.unit_id, "b1", "2. and the selection is not (Esc clears the target before anything else)")
	eq(_esc(), false, "2. Esc with no target is not taken (it goes on to the menu)")
	return true

# --- 3 ---------------------------------------------------------------------------------------------

func _btn(name: String) -> Dictionary:
	return _ui.orders.buttons()[name]

func _enable_rules() -> bool:
	_fresh()
	_pl.place_point(Vector2(1650.0, 2400.0))
	var cone: Dictionary = _pl.bombs.cone("b1", 0)
	eq(_btn("drop")["enabled"], false, "3. a step placed, NO TARGET: Drop is disabled")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.no_target"), "3. and the card's line says why: '%s'" % _ui.orders.bomb_caption())
	eq(_pl.drop_options()["available"], false, "3. drop_options agrees")
	eq(_pl.toggle_drop(), {}, "3. B does nothing")
	# A target outside the cone.
	var far: Vector2 = cone["ideal_aim"] + Vector2(0.0, 900.0)
	check(not BombSource.inside(cone["polygon"], far), "3. (the far point is outside the cone)")
	_ui.target.set_point(far)
	eq(_btn("drop")["enabled"], false, "3. a target OUTSIDE the step's cone: Drop is disabled")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.target_outside") % 1, "3. and the card says the target is outside step 1's cone: '%s'" % _ui.orders.bomb_caption())
	eq(_pl.toggle_drop(), {}, "3. B does nothing there either")
	eq(_pl.step_has_drop(0), false, "3. no drop was planned")
	# Inside.
	_ui.target.set_point(cone["ideal_aim"])
	eq(_btn("drop")["enabled"], true, "3. a target inside the cone: Drop is enabled")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.free") % [3, 3, 4], "3. the card shows the drops free")
	# The cone is the STEP's: a second step whose cone does not hold it.
	_pl.place_point(Vector2(1800.0, 2400.0))
	_ui.target.set_point(_pl.bombs.cone("b1", 0)["ideal_aim"] - Vector2(400.0, 0.0))
	_pl.set_focus_step(1)
	var in0 := BombSource.inside(_pl.bombs.cone("b1", 0)["polygon"], _ui.target.point_m)
	var in1 := BombSource.inside(_pl.bombs.cone("b1", 1)["polygon"], _ui.target.point_m)
	eq(_pl.drop_options(1)["available"], in1, "3. step 2's Drop follows step 2's cone (%s)" % str(in1))
	eq(_pl.drop_options(0)["available"], in0, "3. step 1's follows step 1's (%s)" % str(in0))
	# No drops left says so before it says anything about the target.
	_ui.target.set_point(_pl.bombs.cone("b1", 0)["ideal_aim"])
	_w.units["b1"].drops_left = 0
	_pl.set_focus_step(0)
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.none_left"), "3. no drops left is said first")
	_w.units["b1"].drops_left = 3
	# A fighter has no Drop at all, target or not.
	_ui.select("p1")
	_ui.target.set_point(Vector2(2000.0, 2000.0))
	_pl.place_point(Vector2(1700.0, 2000.0))
	eq(_btn("drop")["enabled"], false, "3. a fighter has no Drop whatever the target (guns never take one)")
	eq(_ui.orders.bomb_caption(), "", "3. and the card says nothing of bombs")
	_pl.clear()
	return true

# --- 4 ---------------------------------------------------------------------------------------------

func _step_target() -> bool:
	_fresh()
	_pl.place_point(Vector2(1650.0, 2400.0))
	var ideal := _tower_on_ideal(0)
	# A unit target.
	_ui.set_target_unit("tower")
	check(_pl.step_target(0).is_empty(), "4. before activation the step has no target")
	check(not _pl.toggle_drop().is_empty(), "4. Drop with the tower as the target is taken")
	var st: Dictionary = _pl.step_target(0)
	eq(st["unit"], "tower", "4. the step's target is the tower")
	check((st["point"] as Vector2).distance_to(ideal) < 1e-3, "4. its point is where the tower is shown")
	var req: Dictionary = _w.units["b1"].plan[0]
	eq((req["drop"] as Dictionary)["target"], {"unit": "tower"}, "4. the request carries {unit}: %s" % str(req["drop"]))
	check(_pl.step_aim(0).distance_to(ideal) < 1e-3, "4. and the aim sits on it")
	var ps: Dictionary = (_w.planned_states("b1")[0] as Dictionary)["drop"]
	check(bool(ps.get("ok", false)) and ps.get("target") == {"unit": "tower"}, "4. the sim takes it and carries it")
	# A second step with a POINT target: one unit, two targets.
	_pl.place_point(Vector2(1800.0, 2400.0))
	var c1: Dictionary = _pl.bombs.cone("b1", 1)
	var pt: Vector2 = c1["ideal_aim"] + Vector2(0.0, 15.0)
	check(BombSource.inside(c1["polygon"], pt), "4. (a point inside step 2's cone)")
	_ui.target.set_point(pt)
	check(not _pl.toggle_drop().is_empty(), "4. step 2 takes a point target")
	var st1: Dictionary = _pl.step_target(1)
	eq(st1["unit"], "", "4. step 2's target is a point")
	check((st1["point"] as Vector2).distance_to(pt) < 1e-3, "4. that point")
	eq(_pl.step_target(0)["unit"], "tower", "4. and step 1's is still the tower: two targets across two steps")
	# The selection changing afterwards changes nothing already activated.
	_ui.target.set_unit("aa1", Vector2(2600.0, 2700.0))
	eq(_pl.step_target(0)["unit"], "tower", "4. a new target selection does not touch step 1's")
	check((_pl.step_target(1)["point"] as Vector2).distance_to(pt) < 1e-3, "4. nor step 2's")
	_ui.target.clear()
	eq(_pl.step_target(1)["unit"], "", "4. nor does clearing it (Esc)")
	eq(_pl.bombs.drop_steps("b1"), [0, 1] as Array[int], "4. both drops stand")
	# Switching a drop off needs no target.
	_pl.set_focus_step(1)
	check(not _pl.toggle_drop().is_empty() and not _pl.step_has_drop(1), "4. a drop is switched off with no target set")
	eq(_pl.step_target(1), {}, "4. and its target goes with it")
	# Another unit selected and back: no per-unit memory of the target, the plan keeps its steps'.
	_ui.select("p1")
	_ui.select("b1")
	eq(_ui.target.is_set(), false, "4. the selection round trip left no target")
	eq(_pl.step_target(0)["unit"], "tower", "4. but step 1's is in the plan")
	# Dragging step 1's aim marker moves ITS target: it becomes a point, held inside the cone.
	var handle := _s(_pl.step_aim(0))
	check(_ui.map_press(handle), "4. a press on the aim handle is taken")
	check(_pl.is_aiming(), "4. an aim drag")
	eq(_pl.step_target(0)["unit"], "tower", "4. a press alone moves nothing and leaves the unit target")
	var poly0: PackedVector2Array = _pl.bombs.cone("b1", 0)["polygon"]
	var to := _s(BombSource._centroid(poly0) + Vector2(20.0, -8.0))
	_ui.map_drag(to)
	var moved: Dictionary = _pl.step_target(0)
	eq(moved["unit"], "", "4. dragged: the step's target is now a point")
	check((moved["point"] as Vector2).distance_to(_pl.step_aim(0)) < 1e-3, "4. at the aim")
	check(BombSource.inside(poly0, moved["point"]), "4. inside the cone")
	_ui.map_drag(_s(BombSource._centroid(poly0) + Vector2(4000.0, 0.0)))
	check(BombSource.inside(poly0, _pl.step_target(0)["point"]), "4. dragged far outside it is held inside the cone")
	_ui.map_release(_s(BombSource._centroid(poly0)))
	check(not _pl.is_aiming(), "4. released")
	eq((_w.units["b1"].plan[0]["drop"] as Dictionary)["target"].keys(), ["point"], "4. and the request says {point}")
	# Ready, then a target edit takes the Ready back like any plan edit; setting the SELECTION's target is not an edit.
	_w.commit("ai")
	check(_ui.orders.press_button("ready"), "4. Ready")
	_ui.target.set_point(Vector2(2000.0, 2000.0))
	eq(_w.is_ready("local"), true, "4. setting the target selection is no plan edit: the Ready stands")
	_w.withdraw("ai")
	_w.withdraw("local")
	_fresh()
	return true

# --- 5 ---------------------------------------------------------------------------------------------

func _drag_step(k: int, to: Vector2) -> void:
	_pl.begin_edit(k, to)
	_pl.end_step()

func _set_mode(mode: String) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BombRules.PATH))
	(d["outside_cone_mode"] as Dictionary)["value"] = mode
	var r := BombRules.new(d)
	_w.bombs = r
	_w._combat_resolver = CombatResolver.new(_w.combat, r)
	_pl.bombs._cone_cache.clear()
	_pl.bombs._info_cache.clear()
	_pl.bombs._expect_cache.clear()

func _step_moved(mode: String) -> bool:
	_set_mode(mode)
	eq(_pl.bombs.outside_mode(), mode, "5. [%s] the interface reads the sim's switch" % mode)
	_fresh()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_pl.place_point(Vector2(1800.0, 2400.0))
	_tower_on_ideal(1)
	_ui.set_target_unit("tower")
	_pl.set_focus_step(1)
	check(not _pl.toggle_drop().is_empty(), "5. [%s] step 2 drops on the tower" % mode)
	eq(_pl.drop_blocked(1), false, "5. [%s] it is not marked: the cone holds the target" % mode)
	var marks: Array = _pl.bomb_marks()
	eq(marks.size(), 1, "5. [%s] one mark" % mode)
	eq(bool(marks[0]["blocked"]) or bool(marks[0]["poor"]), false, "5. [%s] a plain one" % mode)
	eq(_ui.orders.bomb_caption().begins_with("step 2:") or _ui.orders.bomb_caption().begins_with("drop, step 2"), true, "5. [%s] the card describes the drop: '%s'" % [mode, _ui.orders.bomb_caption()])
	# Both steps are dragged hard to the north: the bomber turns away at its limit for two steps, and step 2's cone, at every
	# moment of it, points away from the tower.
	var aim_before := _pl.step_aim(1)
	_drag_step(0, Vector2(1650.0, 2150.0))
	_drag_step(1, Vector2(1900.0, 2000.0))
	check(_pl.step_has_drop(1), "5. [%s] step 2 KEEPS its drop" % mode)
	eq(_pl.step_target(1)["unit"], "tower", "5. [%s] and its target" % mode)
	check(_pl.step_aim(1).distance_to(aim_before) < 1e-3, "5. [%s] and its aim: nothing moved it into the new cone" % mode)
	eq(_pl.drop_blocked(1), true, "5. [%s] the cone no longer holds the target: the step is MARKED" % mode)
	var mark: Dictionary = _pl.bomb_marks()[0]
	eq([bool(mark["blocked"]), bool(mark["poor"])], [mode == "hold", mode == "poor_shot"], "5. [%s] the map's mark says which case it is" % mode)
	var word: String = _st.text("bombs.text.wont_release") if mode == "hold" else _st.text("bombs.text.poor_shot")
	eq(_ui.orders.bomb_caption(), word, "5. [%s] the card says '%s'" % [mode, word])
	var tag: String = _st.text("bombs.text.step_tag_blocked") if mode == "hold" else _st.text("bombs.text.step_tag_poor")
	check(_pl.step_labels()[1].has(tag), "5. [%s] and so does the step's lettering ('%s')" % [mode, tag])
	var info: Dictionary = _pl.drop_info(1)
	eq([info["blocked"], info["poor_shot"]], [mode == "hold", mode == "poor_shot"], "5. [%s] drop_info agrees" % mode)
	if mode == "poor_shot":
		check((mark["lands"] as Vector2).is_finite() and (mark["lands"] as Vector2).distance_to(mark["aim"]) > 1.0, "5. [poor_shot] the stick lands at the cone's nearest point, not on the target")
	else:
		check(not (mark["lands"] as Vector2).is_finite(), "5. [hold] nothing lands")
	# The sim: hold releases nothing and spends nothing; poor_shot releases a stick.
	var ps: Dictionary = (_w.planned_states("b1")[1] as Dictionary)["drop"]
	if mode == "hold":
		eq(ps.get("ok"), false, "5. [hold] the sim does not release the drop")
		eq(ps.get("reason"), "outside_cone", "5. [hold] for want of the cone")
	else:
		eq(ps.get("ok"), true, "5. [poor_shot] the sim releases it")
		eq(ps.get("poor_shot"), true, "5. [poor_shot] as a poor shot")
	# And the drop is ON still: switching it off is allowed, and a moved step can come back.
	_drag_step(0, Vector2(1650.0, 2400.0))
	_drag_step(1, Vector2(1800.0, 2400.0))
	eq(_pl.drop_blocked(1), false, "5. [%s] the steps put back: no longer marked" % mode)
	# Resolve the blocked turn for real: released or not, spent or not.
	_drag_step(0, Vector2(1650.0, 2150.0))
	_drag_step(1, Vector2(1900.0, 2000.0))
	var left_before: int = _w.units["b1"].drops_left
	_w.commit("ai")
	_w.commit("local")
	var res := _w.resolve()
	check(not res.is_empty(), "5. [%s] the turn resolves" % mode)
	var rel: Array = (res.get("events", []) as Array).filter(func(e: Dictionary) -> bool: return e["type"] == "bomb_release" and e["unit"] == "b1")
	if mode == "hold":
		eq(rel.size(), 0, "5. [hold] nothing is released")
		eq(_w.units["b1"].drops_left, left_before, "5. [hold] no drop is spent")
	else:
		eq(rel.size(), 1, "5. [poor_shot] a stick is released")
		eq(_w.units["b1"].drops_left, left_before - 1, "5. [poor_shot] and the drop is spent")
		if rel.size() == 1:
			eq((rel[0] as Dictionary).get("poor_shot"), true, "5. [poor_shot] the event says it was a poor shot")
	_rebuild()
	return true

# --- 6 ---------------------------------------------------------------------------------------------

func _on_the_map() -> bool:
	_fresh()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_tower_on_ideal(0)
	var marks_node = _ui.target_marks
	check(marks_node != null, "6. UnitUI mounts the target marks")
	# A unit target.
	_ui.set_target_unit("tower")
	await get_tree().process_frame
	await get_tree().process_frame
	var sh: Dictionary = marks_node.shown()
	eq(sh.get("kind"), "unit", "6. the unit target is shown as a unit's")
	check((sh["at"] as Vector2).distance_to(_s(Vector2(_w.units["tower"].x, _w.units["tower"].y))) < 1e-3, "6. at the tower's place on the screen")
	check(float(sh["radius_px"]) > 0.0, "6. clear of the tower's marker (radius %.1f px)" % float(sh["radius_px"]))
	eq(marks_node.drawn_kind, "unit", "6. and drawn")
	eq(marks_node.failed_draws, 0, "6. every part of it ran to its end")
	# A point target, drawn over the fog (the map layers are above the map).
	_ui.target.set_point(Vector2(1900.0, 2900.0))
	await get_tree().process_frame
	await get_tree().process_frame
	eq(marks_node.drawn_kind, "point", "6. a point target is drawn")
	check(marks_node.drawn_at.distance_to(_s(Vector2(1900.0, 2900.0))) < 1e-3, "6. at its place")
	check(not (_ui.target_marks.get_parent() as Node).is_class("SubViewport"), "6. in the map layer, above the map and its fog")
	# The fog: a unit out of sight is held where it was last seen and never gives its place away.
	_ui.set_target_unit("eb")
	var seen_at := _ui.target.point_m
	eq(seen_at, Vector2(2400.0, 2000.0), "6. the enemy plane seen at its place")
	_ui.marker_layer.unit_visible = func(id: String) -> bool: return id != "eb"
	_w.units["eb"].x = 2000.0
	eq(_ui.target.position_m(_w), seen_at, "6. out of sight it is held at the place it was last seen")
	eq(_ui.target.in_sight(), false, "6. and says it is not in sight")
	await get_tree().process_frame
	eq(marks_node.shown().get("in_sight"), false, "6. the mark knows (it is drawn fainter)")
	_ui.marker_layer.unit_visible = Callable()
	eq(_ui.target.position_m(_w), Vector2(2000.0, _w.units["eb"].y), "6. in sight again it is followed to where it is")
	_w.units["eb"].x = 2400.0
	# A unit target follows the unit through the playback pose.
	_ui.target.clear()
	# Another player's drop shows its target as a small mark; the enemy's targets are never read.
	_ui.select("b2")
	_pl.place_point(Vector2(1650.0, 2900.0))
	var ideal2: Vector2 = _pl.bombs.cone("b2", 0)["ideal_aim"]
	_ui.target.set_point(ideal2)
	check(not _pl.toggle_drop().is_empty(), "6. b2 drops on a point")
	_ui.select("b1")
	_pl.place_point(Vector2(1650.0, 2400.0))
	_tower_on_ideal(0)
	_ui.set_target_unit("tower")
	check(not _pl.toggle_drop().is_empty(), "6. b1 drops on the tower")
	var recs: Array = _pl.bomb_marks()
	eq(recs.size(), 2, "6. two marks")
	for r: Dictionary in recs:
		var tg: Dictionary = r["target"]
		if r["unit"] == "b2":
			eq(r["quiet"], true, "6. b2's is the quiet one (another player's drop)")
			eq(tg["kind"], "point", "6. with its target in it")
		else:
			eq(tg["kind"], "unit", "6. b1's target is a unit")
			eq(tg["unit"], "tower", "6. the tower")
	var eb_plan := _w.plan_step("eb", 0, {"turn": 0.0, "speed": 85.0, "drop": {"aim": [2000.0, 2000.0], "target": {"point": [2000.0, 2000.0]}}})
	check(not eb_plan.is_empty(), "6. the enemy bomber has a drop with a target of its own")
	for r: Dictionary in _pl.bomb_marks():
		check(r["unit"] != "eb", "6. no mark is the enemy's")
	eq(_pl.step_target(0, "eb"), {}, "6. step_target gives nothing for it")
	_ui.select("eb")
	eq(_pl.step_target(0), {}, "6. selected, still nothing (plan_shown)")
	eq(_ui.set_target_unit("tower"), false, "6. and an enemy selected can set no target")
	_w.clear_plan("eb")
	# The marks are drawn through the bomb node without failing.
	_ui.select("b1")
	_ui.target.clear()
	_pl.place_point(Vector2(1650.0, 2400.0))
	var node = _ui.bomb_aim
	node.refresh()
	for i in 3:
		await get_tree().process_frame
	eq(node.failed_draws, 0, "6. the bomb node's marks ran to their end with the targets in them")
	# The marks themselves: units and points, small and big, blocked, at both zooms' sizes.
	var probe := _Probe.new()
	probe.st = _st
	add_child(probe)
	probe.queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	check(probe.draws > 0, "6. the probe was drawn (%d)" % probe.draws)
	eq(probe.results, [true, true, true, true, true, true, false], "6. a unit mark, a point mark and the slash draw at both scales; a mark with no place does not")
	probe.queue_free()
	return true

# Draws the marks inside its own _draw (a draw call is only allowed there).
class _Probe extends Node2D:
	var st: RefCounted = null
	var results: Array = []
	var draws: int = 0
	func _draw() -> void:
		var ta = load("res://scripts/ui/target_art.gd")
		results = []
		for k: float in [1.0, st.num("target.quiet.k")]:
			results.append(ta.draw(self, "unit", Vector2(100.0, 100.0), st, 20.0, k, 1.0))
			results.append(ta.draw(self, "point", Vector2(100.0, 100.0), st, 0.0, k, 0.5))
			results.append(ta.slash(self, Vector2(100.0, 100.0), st, k))
		results.append(ta.draw(self, "point", Vector2.INF, st))
		draws += 1

# --- 7 ---------------------------------------------------------------------------------------------

func _wire() -> bool:
	_fresh()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_tower_on_ideal(0)
	_ui.set_target_unit("tower")
	_pl.toggle_drop()
	_pl.place_point(Vector2(1800.0, 2400.0))
	var c1: Dictionary = _pl.bombs.cone("b1", 1)
	_ui.target.set_point(c1["ideal_aim"])
	_pl.set_focus_step(1)
	_pl.toggle_drop()
	var plan: Array = _w.units["b1"].plan.duplicate(true)
	check(plan.size() == 2 and (plan[0]["drop"] as Dictionary).has("target") and (plan[1]["drop"] as Dictionary).has("target"), "7. two steps, two targets in the plan")
	var wired: Variant = bytes_to_var(var_to_bytes(plan))
	check(WorldSync.same(wired, plan), "7. the plan survives the engine's own encoder exactly")
	# A second World takes the plan as a peer does (WorldSync's own apply path) and the interface reads the targets back.
	var other := _make_world()
	other.add_player("peer_2")
	var hs := WorldSync.new()
	add_child(hs)
	hs.setup(_w, "test")
	eq(hs._plan_problem("b1", plan), "", "7. the host accepts it")
	var snap: Dictionary = hs.snapshot()
	var other_sync := WorldSync.new()
	add_child(other_sync)
	other_sync.setup(other, "test")
	other_sync.apply_snapshot(bytes_to_var(var_to_bytes(snap)) as Dictionary)
	check(WorldSync.same(other.units["b1"].plan, plan), "7. a peer that joins from the snapshot holds the plan, targets and all")
	var ui2 := UnitUI.new()
	add_child(ui2)
	ui2.setup(other, _xf, "peer_2")
	ui2.select("b1")
	eq(ui2.planner.step_target(0)["unit"], "tower", "7. and reads step 1's unit target")
	eq(ui2.planner.step_target(1)["unit"], "", "7. and step 2's point")
	check((ui2.planner.step_target(1)["point"] as Vector2).distance_to(c1["ideal_aim"]) < 1e-3, "7. at the same place")
	ui2.queue_free()
	hs.queue_free()
	other_sync.queue_free()
	_fresh()
	return true
