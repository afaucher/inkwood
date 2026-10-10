extends "res://scripts/test_support/test_case.gd"

# THE BOMB DROP IN THE INTERFACE (Track U3, the strike, 2026-10-10; Alex: bombing is "per step,
# just like diving. You set the intent in the cone." Accuracy follows the release angle and the
# height; several drops; the enemy's plan is never shown). Headless, on the real World (Track S2's
# bombs: World.bombs_left / drop_cone / drop_spread), mounted through UnitUI as the assembly mounts it:
#
#   1. the style data: every key the bomb UI reads exists, the four looks are named
#   2. the Drop control: disabled for a fighter, with no step placed, with no drops left; enabled
#      with a bomber and a step; pressed it puts {"drop": {"aim": [x, y]}} in the step with the aim
#      INSIDE the step's cone (World.drop_cone) and the sim takes it; pressed again it comes off; the
#      key B does the same; the card's line says what it does
#   3. the aim: placed inside the cone it is taken, outside it is REFUSED (the plan as it was, the
#      point marked); dragged it is held inside the cone; undo / clear / last edit wins / Ready take
#      it like any step edit (a Ready is taken back)
#   4. the aim handle: hover (near, in range, dragging) and the press act on it like a step's, the
#      nearest handle winning; the mouse cursor says so
#   5. the step the card is about: the last placed step, or the step whose handle was grabbed
#   6. a step moved keeps its drop, and the aim is kept inside the new cone
#   7. the node that draws the cone: the marks (cone, aim, spread, quality, release) in all four
#      looks, every draw reaching its end; a small mark for another player's drop
#   8. THE ENEMY'S DROP IS NEVER DRAWN: an AI bomber's planned drop reaches no mark, selected or not
#   9. the roster: the bomber's row carries drops left and bombs a drop, the fighter's none; the
#      enemy's tower and batteries are not in it; after a resolve the marks empty as the bombs are seen
#      released, not before
#  10. the ground units on the map: markers for the tower and the batteries, the tower's shadow reaches
#      its height x the sun's length, and a destroyed tower's marker goes at the down event
#
# TRACK T (2026-10-10, Alex's decision special-targeting): Drop needs a TARGET (the selection, ui_target.gd) inside the step's
# cone, and stores it on the step; a step moved keeps its drop AND its aim (it is marked, not fitted); dragging the aim moves
# the step's target (it becomes a point); a left-click on an enemy marker targets it instead of moving the aim. The click
# rules, the enable rules and the per-step targets are test_ui_target.gd's; here every section arms Drop through _arm().

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")
const BombAim = preload("res://scripts/ui/bomb_aim.gd")
const BombAimArt = preload("res://scripts/ui/bomb_aim_art.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const UiFate = preload("res://scripts/ui/ui_fate.gd")
const Unit = preload("res://scripts/sim/unit.gd")

const PPM := 0.5

var _w: World
var _ui: UnitUI
var _pl: MotionPlanner
var _xf: Transform2D
var _st: UiStyle

func setup(_main) -> void:
	timeout_seconds = 90.0
	_st = UiStyle.new()
	_check_data(_st)

	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0, "altitude_band": "high"})
	_w.add_unit({"id": "b2", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2900.0, "heading": 0.0, "altitude_band": "medium"})
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 1900.0, "heading": 0.0})
	_w.add_unit({"id": "eb", "type": "bomber", "side": "axis", "controller": "ai", "x": 3500.0, "y": 1500.0, "heading": PI, "altitude_band": "high"})
	_w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 3300.0, "y": 2400.0, "heading": 0.0})
	_w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 3100.0, "y": 2300.0, "heading": 0.4})
	_w.add_unit({"id": "aa2", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 3500.0, "y": 2550.0, "heading": -0.6})
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		finish()
		return
	_xf = Transform2D(0.0, Vector2(PPM, PPM), 0.0, -Vector2(1300.0, 1900.0) * PPM)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, _xf, "local")
	_ui.auto_resolve = false   # a Ready in sections 3 must not resolve the turn
	_pl = _ui.planner
	eq(_pl.bombs.available(), true, "the World answers bomb questions (S2's bombs_left / drop_cone / drop_spread are in)")

	_check_control()
	_check_aim()
	_check_handle()
	_check_focus()
	_check_edit_keeps()
	await _check_marks()
	_check_enemy_never()
	_check_roster_static()
	_check_ground()
	await _check_playback()
	finish()

# --- 1 -------------------------------------------------------------------------

func _check_data(st: UiStyle) -> void:
	for n: String in ["bombs.aim.rim_px", "bombs.aim.mark.r_px", "bombs.aim.mark.tick_px", "bombs.aim.mark.gap_px", "bombs.aim.mark.line_px",
			"bombs.aim.mark.dot_px", "bombs.aim.mark.halo_px", "bombs.aim.ideal.size_px", "bombs.aim.ideal.line_px", "bombs.aim.release.dot_px",
			"bombs.aim.release.tie_dash_px", "bombs.aim.release.tie_gap_px", "bombs.aim.release.tie_px", "bombs.aim.spread.sigma_k",
			"bombs.aim.spread.line_px", "bombs.aim.spread.dash_px", "bombs.aim.quiet.mark_k", "bombs.aim.quiet.alpha", "bombs.aim.label.px",
			"bombs.aim.label.halo_px", "bombs.aim.wash.steps", "bombs.aim.wash.alpha_rim", "bombs.aim.wash.alpha_centre", "bombs.aim.wash.shrink_to",
			"bombs.aim.stipple.cell_px", "bombs.aim.stipple.dot_px", "bombs.aim.stipple.alpha", "bombs.aim.stipple.gamma",
			"bombs.aim.stipple.scatter_dots", "bombs.aim.stipple.scatter_dot_px", "bombs.aim.rings.ring_every_m", "bombs.aim.rings.dash_px",
			"bombs.aim.rings.gap_px", "bombs.aim.rings.line_px", "bombs.aim.rings.alpha", "bombs.aim.rings.fill_alpha",
			"orders.drop_line_px", "roster.bombs.mark_w_px", "roster.bombs.mark_h_px", "roster.bombs.mark_gap_px", "roster.bombs.per_drop_gap_px"]:
		check(st.lookup(n) is float or st.lookup(n) is int, "ui.json has a number at '%s'" % n)
	for n: String in ["bombs.text.label", "bombs.text.place_first", "bombs.text.none_left", "bombs.text.free", "bombs.text.on", "bombs.text.step_tag",
			"roster.bombs.per_drop_text", "bombs.aim.mode", "keys.drop", "planner.hover.cursor.aim"]:
		check(st.lookup(n) is String, "ui.json has a string at '%s'" % n)
	check(st.lookup("bombs.text.no_bombs") is String, "bombs.text.no_bombs exists (it may be empty)")
	eq(st.lookup("bombs.aim.modes"), BombAimArt.MODES, "the four looks the board shows are the four the art draws")
	check(BombAimArt.MODES.has(st.text("bombs.aim.mode")), "the data names one of them as the working look")
	check(st.flag("bombs.aim.label.enabled"), "the label switch is a flag")
	eq(st.text("keys.drop"), "B", "the Drop key")
	for n: String in ["rim_role", "halo_role", "mark.role", "ideal.role", "release.role", "spread.fill_role", "spread.edge_role", "label.role"]:
		check(st.lookup("bombs.aim." + n) is Dictionary, "bombs.aim.%s is a palette role" % n)
	eq(st.errors.size(), 0, "no style lookups failed: %s" % str(st.errors))

# --- 2 -------------------------------------------------------------------------

# Track T: Drop is armed with a target. The target selection is cleared when the friendly selection changes, so it is set
# AFTER the selecting; by default at the step's ideal aim (a point), where the cone holds it.
func _arm(k: int, at: Variant = null) -> Dictionary:
	var id: String = _ui.selection.unit_id
	var cone: Dictionary = _pl.bombs.cone(id, k)
	var p: Vector2 = at if at != null else cone["ideal_aim"]
	_ui.target.set_point(p)
	return _pl.set_step_drop(k, true)

func _btn(name: String) -> Dictionary:
	return _ui.orders.buttons()[name]

func _poly(k: int, id: String = "b1") -> PackedVector2Array:
	return _pl.bombs.cone(id, k)["polygon"]

func _check_control() -> void:
	eq(_btn("drop")["enabled"], false, "2. nothing selected: Drop is off")
	_ui.select("p1")
	_pl.place_point(Vector2(1800.0, 1900.0))
	eq(_btn("drop")["enabled"], false, "2. a fighter with a step placed: Drop is off (no bombs)")
	eq(_ui.orders.bomb_caption(), "", "2. and the card says nothing about bombs")
	_ui.select("b1")
	eq(_btn("drop")["enabled"], false, "2. a bomber with no step placed: Drop is off")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.place_first"), "2. and the card says to place a step first")
	var s0 := _pl.place_point(Vector2(1650.0, 2400.0))
	check(not s0.is_empty(), "2. a first step is placed")
	eq(_btn("drop")["enabled"], false, "2. with a step placed but NO TARGET the Drop control is off (Alex: no target, no activation)")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.no_target"), "2. and the card says to set a target")
	_ui.target.set_point(_pl.bombs.cone("b1", 0)["ideal_aim"])
	eq(_btn("drop")["enabled"], true, "2. with a target in the step's cone it is on offer")
	eq(_btn("drop")["on"], false, "2. and not yet on")
	var carried := _pl.bombs.bombs_left("b1")
	eq([carried["drops_left"], carried["drops_max"], carried["per_drop"]], [3, 3, 4], "2. the bomber carries 3 drops of 4 (data/units/bomber.json)")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.free") % [3, 3, 4], "2. the card says the drops free")
	eq(_pl.drop_options()["available"], true, "2. drop_options agrees")
	var cone := _pl.bombs.cone("b1", 0)
	check(bool(cone["ok"]) and (cone["polygon"] as PackedVector2Array).size() >= 3, "2. the step has a bomb cone (%d points)" % (cone["polygon"] as PackedVector2Array).size())
	check(BombSource.inside(cone["polygon"], cone["ideal_aim"]), "2. the ideal aim lies inside it")
	# Pressed: on, the aim inside the cone.
	check(_ui.orders.press_button("drop"), "2. the Drop button is pressed")
	eq(_btn("drop")["on"], true, "2. and is on")
	var plan0: Dictionary = _w.units["b1"].plan[0]
	check(plan0.has("drop") and (plan0["drop"] as Dictionary).has("aim"), "2. the step's request carries {drop: {aim}}: %s" % str(plan0))
	var aim: Vector2 = _pl.step_aim(0)
	check(aim.is_finite() and BombSource.inside(_poly(0), aim), "2. the aim lies inside the cone")
	check((plan0["drop"]["aim"] as Array).size() == 2, "2. and is an [x, y] pair")
	var ps: Dictionary = _w.planned_states("b1")[0]
	check(ps.has("drop") and bool((ps["drop"] as Dictionary).get("ok", false)), "2. the sim takes the drop (planned_states says ok): %s" % str((ps.get("drop", {}) as Dictionary).get("reason", "")))
	check(_ui.orders.bomb_caption().begins_with("drop, step 1:"), "2. the card says what it does: '%s'" % _ui.orders.bomb_caption())
	eq(_pl.bombs.drops_free("b1"), 2, "2. two drops remain to plan")
	# Off again.
	check(_ui.orders.press_button("drop"), "2. pressed again")
	eq(_btn("drop")["on"], false, "2. it is off")
	check(not (_w.units["b1"].plan[0] as Dictionary).has("drop"), "2. and the request carries no drop")
	# The key.
	var key := InputEventKey.new()
	key.keycode = KEY_B
	key.pressed = true
	check(_ui._key(key), "2. the B key")
	check(_pl.step_has_drop(0), "2. puts the drop on")
	eq(_pl.step_target(0)["unit"], "", "2. (a point target)")
	check(_ui._key(key), "2. and again")
	check(not _pl.step_has_drop(0), "2. takes it off")
	# No drops left.
	_w.units["b1"].drops_left = 1
	_pl.place_point(Vector2(1800.0, 2400.0))
	_pl.set_focus_step(0)
	check(_pl.toggle_drop().size() > 0, "2. with one drop left, step 1 takes it")
	_ui.target.set_point(_pl.bombs.cone("b1", 1)["ideal_aim"])
	_pl.set_focus_step(1)
	eq(_btn("drop")["enabled"], false, "2. the one drop is planned: Drop is off for step 2")
	eq(_ui.orders.bomb_caption(), _st.text("bombs.text.none_left"), "2. and the card says none is left")
	eq(_pl.toggle_drop(), {}, "2. toggling it does nothing")
	_pl.set_focus_step(0)
	eq(_btn("drop")["enabled"], true, "2. step 1 can still take its own drop off")
	_pl.toggle_drop()
	_w.units["b1"].drops_left = 0
	_pl.set_focus_step(0)
	eq(_btn("drop")["enabled"], false, "2. no drops left at all: Drop is off")
	_w.units["b1"].drops_left = 3
	_pl.clear()

# --- 3 -------------------------------------------------------------------------

func _check_aim() -> void:
	_ui.select("b1")
	_pl.clear()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_arm(0)
	var poly := _poly(0)
	var c := BombSource._centroid(poly)
	# Inside the cone: taken.
	var inside_pt := c + Vector2(20.0, 10.0)
	check(BombSource.inside(poly, inside_pt), "3. (the test point is inside the cone)")
	var r := _pl.place_aim(0, inside_pt)
	check(not r.is_empty(), "3. an aim inside the cone is taken")
	check(_pl.step_aim(0).distance_to(inside_pt) < 1e-3, "3. and stored as asked (%s)" % str(_pl.step_aim(0)))
	eq(_pl.step_target(0)["unit"], "", "3. the step's target is now that point (Alex: the aim marker moves the step's target)")
	check((_pl.step_target(0)["point"] as Vector2).distance_to(inside_pt) < 1e-3, "3. which is where the aim is")
	var info: Dictionary = (_w.planned_states("b1")[0]["drop"] as Dictionary)
	check(bool(info.get("ok", false)) and not bool(info.get("clamped", true)), "3. the sim does not clamp it")
	# Outside: refused, the plan as it was.
	var before: Array = (_w.units["b1"].plan as Array).duplicate(true)
	var out_pt := c + Vector2(4000.0, 0.0)
	eq(BombSource.inside(poly, out_pt), false, "3. (the far point is outside)")
	eq(_pl.place_aim(0, out_pt), {}, "3. an aim outside the cone is REFUSED")
	eq(_w.units["b1"].plan, before, "3. the plan is as it was")
	check(_pl.refused_aim.distance_to(out_pt) < 1e-3, "3. the refused point is marked")
	eq(_pl.place_aim(1, inside_pt), {}, "3. no aim for a step with no drop")
	# Dragged: held inside.
	var s := _pl.begin_aim(0, c)
	check(not s.is_empty() and _pl.is_aiming() and _pl.is_dragging(), "3. begin_aim takes hold of the aim")
	_pl.drag_aim(out_pt)
	var held := _pl.step_aim(0)
	check(BombSource.inside(poly, held), "3. dragged far outside, the aim is held inside the cone (%s)" % str(held))
	check(held.distance_to(out_pt) < out_pt.distance_to(c), "3. at the cone's edge nearest the pointer")
	_pl.drag_aim(c)
	check(_pl.step_aim(0).distance_to(c) < 1.0, "3. and follows the pointer back in")
	_pl.end_aim()
	check(not _pl.is_aiming() and not _pl.is_dragging(), "3. end_aim lets go")
	# Undo takes the step and its drop; the request survives an undo of a later step.
	_pl.place_point(Vector2(1800.0, 2400.0))
	check(_pl.step_has_drop(0), "3. step 1's drop is in the plan")
	check(_pl.undo(), "3. undo drops the last step")
	check(_pl.step_has_drop(0) and BombSource.inside(_poly(0), _pl.step_aim(0)), "3. and leaves step 1's drop as it was")
	# Ready, then an edit of the aim takes the Ready back (Alex 2026-10-09: the last Ready plays the turn).
	_w.commit("ai")
	check(_ui.orders.press_button("ready"), "3. Ready")
	eq(_w.is_ready("local"), true, "3. the player is ready")
	_pl.place_aim(0, c + Vector2(-15.0, 5.0))
	eq(_w.is_ready("local"), false, "3. an aim edit takes the Ready back")
	# Clear takes it all.
	_pl.clear()
	eq(_pl.bombs.drop_steps("b1").size(), 0, "3. clear leaves no drop")
	_w.withdraw("ai")

# --- 4 -------------------------------------------------------------------------

func _aim_screen(k: int) -> Vector2:
	return _xf * _pl.step_aim(k)

func _check_handle() -> void:
	_ui.select("b1")
	_pl.clear()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_arm(0)
	var r: float = _st.num("planner.handle_px")
	var near: float = r * _st.num("planner.hover.near_factor")
	var a := _aim_screen(0)
	_pl.set_pointer(a + Vector2(near * 1.5, 0.0))
	eq(_pl.hover()["state"], "none", "4. far from the aim: nothing hovers")
	_pl.set_pointer(a + Vector2(near * 0.8, 0.0))
	eq(_pl.hover()["state"], "near", "4. approaching the aim handle: near")
	eq(_pl.hover()["kind"], "aim", "4. and it is the AIM's handle")
	eq(_pl.hover()["step"], 0, "4. of step 1")
	check(float(_pl.hover()["approach"]) > 0.0 and float(_pl.hover()["approach"]) < 1.0, "4. the approach is between 0 and 1")
	_pl.set_pointer(a + Vector2(r * 0.5, 0.0))
	eq(_pl.hover()["state"], "range", "4. within the pick radius: in range")
	eq(_pl.hover()["action"], "grab", "4. a press would grab")
	check((_pl.hover()["handle_screen"] as Vector2).distance_to(a) < 1e-3, "4. and it says where the handle is")
	eq(_pl.cursor_shape, Input.CURSOR_POINTING_HAND, "4. the cursor is the pointing hand")
	eq(_pl.grab_at(a + Vector2(2.0, 0.0))["kind"], "aim", "4. grab_at finds the aim")
	eq(_pl.handle_at(a), -1, "4. handle_at is the steps' alone: the aim is not a step")
	# A press grabs it and a drag moves it (through UnitUI, as the mouse does).
	check(_ui.map_press(a), "4. a press on the aim handle is taken")
	check(_pl.is_aiming(), "4. and starts an aim drag")
	check(_pl.step_aim(0).distance_to(_xf.affine_inverse() * a) < 1e-3, "4. which holds the handle where it is (nothing moves until the pointer leaves the slop)")
	eq(_pl.hover()["state"], "drag", "4. the handle is lit while dragged")
	eq(_pl.cursor_shape, Input.CURSOR_DRAG, "4. the cursor is the grabbing hand")
	var poly_px := PackedVector2Array()
	for q in _poly(0):
		poly_px.append(_xf * q)
	var mid := BombSource._centroid(poly_px)
	check(_ui.map_drag(mid), "4. a drag moves the aim")
	check(_pl.step_aim(0).distance_to(_xf.affine_inverse() * mid) < 1.0, "4. to the pointer")
	check(_ui.map_release(mid + Vector2(5000.0, 0.0)), "4. a release far outside")
	check(BombSource.inside(_poly(0), _pl.step_aim(0)), "4. leaves the aim inside the cone")
	check(not _pl.is_dragging(), "4. and the drag over")
	# Inside the cone, away from every handle: a press there moves the aim (the fan is far away).
	var elsewhere := mid + Vector2(10.0, -6.0)
	eq(_pl.press_action(elsewhere), "aim", "4. a press in the cone, off every handle, would move the aim")
	_pl.set_pointer(elsewhere)
	eq(_pl.hover()["action"], "aim", "4. and the hover says so")
	eq(_pl.cursor_shape, Input.CURSOR_CROSS, "4. with a cross")
	check(_ui.map_press(elsewhere), "4. the press is taken")
	_ui.map_release(elsewhere)
	check(_pl.step_aim(0).distance_to(_xf.affine_inverse() * elsewhere) < 1.0, "4. the aim is there")
	# A step handle still wins where it is nearest.
	var h0 := _xf * Vector2(float(_pl.states()[0]["x"]), float(_pl.states()[0]["y"]))
	eq(_pl.grab_at(h0)["kind"], "step", "4. a step's handle is still a step's")
	_pl.clear_pointer()
	eq(_pl.cursor_shape, Input.CURSOR_ARROW, "4. the cursor is back to the arrow")
	_pl.clear()

# --- 5 -------------------------------------------------------------------------

func _check_focus() -> void:
	_ui.select("b1")
	_pl.clear()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_pl.place_point(Vector2(1800.0, 2400.0))
	eq(_pl.focus_step(), 1, "5. the card is about the last placed step")
	_arm(0)
	eq(_pl.focus_step(), 0, "5. a drop set on step 1 puts the card on step 1")
	check(_ui.orders.bomb_caption().begins_with("drop, step 1:"), "5. the card says step 1")
	eq(_btn("drop")["on"], true, "5. Drop is on for the step the card is about")
	_pl.begin_edit(1, Vector2(1800.0, 2400.0))
	_pl.end_step()
	eq(_pl.focus_step(), 1, "5. grabbing step 2's handle puts the card on step 2")
	eq(_btn("drop")["on"], false, "5. Drop is off there")
	var dived := _pl.change_band(-1)
	eq(dived.get("altitude_band", ""), "medium", "5. Dive acts on the same step: step 2 from high to medium")
	eq(_pl.states()[1]["altitude_band"], "medium", "5. in the plan")
	eq(_pl.states()[0]["altitude_band"], "high", "5. and step 1 is untouched")
	_pl.place_point(Vector2(1950.0, 2400.0))
	eq(_pl.focus_step(), 2, "5. a new step is the last placed: the card follows it")
	_ui.select("p1")
	eq(_pl.focus_step(), _pl.planned_count() - 1, "5. another unit selected: its last placed step")
	_ui.select("b1")
	eq(_pl.focus_step(), 2, "5. back on the bomber the card is about its last placed step again")
	_pl.clear()
	eq(_pl.focus_step(), -1, "5. nothing placed, no step")

# --- 6 -------------------------------------------------------------------------

func _check_edit_keeps() -> void:
	_ui.select("b1")
	_pl.clear()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_arm(0)
	_pl.place_point(Vector2(1800.0, 2400.0))
	_arm(1)
	check(_pl.step_has_drop(0) and _pl.step_has_drop(1), "6. two steps carry a drop")
	check(_pl.step_target(0)["point"] != _pl.step_target(1)["point"], "6. each with a target of its own (Alex: two targets across two steps)")
	# Move step 1 hard to one side: its cone moves. Its drop and its TARGET stay and its aim stays where it was (Track T: a step
	# moved is MARKED when its cone leaves the target, never fitted behind the player's back).
	var old_aim := _pl.step_aim(0)
	var old_target: Dictionary = _pl.step_target(0)
	_pl.begin_edit(0, Vector2(1660.0, 2330.0))
	_pl.end_step()
	check(_pl.step_has_drop(0), "6. a step moved keeps its drop")
	check(_pl.step_aim(0).distance_to(old_aim) < 1e-3, "6. and its aim, which is not moved into the new cone")
	eq(_pl.step_target(0), old_target, "6. and its target")
	eq(_pl.drop_blocked(0), not BombSource.inside(_poly(0), old_aim), "6. the step is marked exactly when the new cone does not hold the target (%s)" % str(_pl.drop_blocked(0)))
	check(_pl.step_has_drop(1), "6. step 2 keeps its drop too")
	# A band change moves the cone (the height is the throw): the drop and the target stay, and it is marked if the cone left them.
	_pl.set_focus_step(1)
	var cone_before := PackedVector2Array(_poly(1))
	var aim_before := _pl.step_aim(1)
	var lowered := _pl.change_band(-1)
	check(not lowered.is_empty(), "6. step 2 dives a band")
	check(_pl.step_has_drop(1) and _pl.step_aim(1).distance_to(aim_before) < 1e-3, "6. the drop stays and so does its aim")
	check(_poly(1) != cone_before, "6. a dive changes the cone (the throw shortens as the bomber comes down)")
	eq(_pl.drop_blocked(1), not BombSource.inside(_poly(1), _pl.step_aim(1)), "6. and the step is marked exactly when the cone left the aim")
	var tag: String = _st.text("bombs.text.step_tag")
	eq(_pl.step_labels()[1].has(tag), true, "6. the step's lettering says 'drop'")
	eq(_pl.step_labels()[1].has(_st.text("bombs.text.step_tag_blocked")), _pl.drop_blocked(1) and _pl.bombs.outside_mode() == "hold", "6. and 'will not release' when it is marked (hold)")
	_pl.clear()

# --- 7 -------------------------------------------------------------------------

func _check_marks() -> void:
	_ui.select("b1")
	_pl.clear()
	_pl.place_point(Vector2(1650.0, 2400.0))
	_arm(0)
	_pl.place_aim(0, BombSource._centroid(_poly(0)) + Vector2(25.0, -10.0))
	var marks: Array = _pl.bomb_marks()
	eq(marks.size(), 1, "7. one mark: the selected bomber's drop")
	if marks.size() != 1:
		return
	var m: Dictionary = marks[0]
	eq(m["quiet"], false, "7. a full one (cone and aim)")
	check((m["cone"] as PackedVector2Array).size() >= 3, "7. with the cone in screen px")
	check((m["cone"] as PackedVector2Array)[0].distance_to(_xf * _poly(0)[0]) < 1e-3, "7. through the host's mapping")
	check((m["aim"] as Vector2).distance_to(_aim_screen(0)) < 1e-3, "7. the aim in screen px")
	var sp: Dictionary = m["spread"]
	check(float(sp["a"]) > 0.0 and float(sp["b"]) > 0.0, "7. a spread to draw (%.1f x %.1f px)" % [float(sp["a"]), float(sp["b"])])
	check(float(sp["a"]) >= float(sp["b"]), "7. longer along the stick than across it")
	var info: Dictionary = _pl.bombs.aim_info("b1", 0, _pl.step_aim(0))
	near(float(sp["b"]), float((info["spread"] as Dictionary)["across_m"]) * PPM, 0.05, "7. its size is the sim's spread x sigma_k x the scale")
	check(float(m["quality"]) > 0.35 - 1e-6 and float(m["quality"]) <= 1.0, "7. the accuracy is in the sim's range (%.2f)" % float(m["quality"]))
	check((m["release"] as Vector2).is_finite(), "7. the release point is on the map")
	check((m["ideal"] as Vector2).is_finite(), "7. and the ideal aim")
	var di: Dictionary = _pl.drop_info()
	check(not di.is_empty() and float(di["quality"]) == float(m["quality"]), "7. drop_info says the same as the mark")
	# The ideal aim has the best accuracy; the rim a worse one.
	var best: Dictionary = _pl.bombs.aim_info("b1", 0, _pl.bombs.cone("b1", 0)["ideal_aim"])
	check(float(best["quality"]) >= float(info["quality"]) - 1e-9, "7. the ideal aim is the most accurate")
	near(float(best["quality"]), 1.0, 0.02, "7. 1.0 at the ideal release angle")
	# The node draws it, in every look, to the end (a runtime error in a draw ends it silently:
	# BombAim counts the draws that did not reach their end).
	var node: BombAim = _ui.bomb_aim
	node.refresh()
	eq(node.marks.size(), 1, "7. the bomb node holds the mark")
	for mode: String in BombAimArt.MODES:
		node.mode_override = mode
		var drawn := node.draw_count
		await get_tree().process_frame
		await get_tree().process_frame
		check(node.draw_count > drawn, "7. the '%s' look is drawn (draw %d)" % [mode, node.draw_count])
	node.mode_override = ""
	check(node.marks_draw_count > 0, "7. the marks layer (over the planes) is drawn too (%d draws)" % node.marks_draw_count)
	# The aim handle's hover is drawn over the aim, by the same node (the grow-and-fill).
	var before_marks := node.marks_draw_count
	_pl.set_pointer(_aim_screen(0) + Vector2(4.0, 0.0))
	eq(_pl.hover()["kind"], "aim", "7. the pointer is on the aim handle")
	await get_tree().process_frame
	await get_tree().process_frame
	check(node.marks_draw_count > before_marks, "7. the hover redraws the marks layer")
	check(not node._marks.is_queued_for_deletion() and node._marks.z_index == 1, "7. which sits over the planes (z 1)")
	_pl.clear_pointer()
	# A second mark: another player's bomber with a drop shows as a small mark, no cone.
	_ui.select("b2")
	_pl.place_point(Vector2(1650.0, 2900.0))
	_arm(0)
	_ui.select("b1")
	var two: Array = _pl.bomb_marks()
	eq(two.size(), 2, "7. another player's drop is a second mark (the co-op preview)")
	var quiet := 0
	for t: Dictionary in two:
		if bool(t["quiet"]):
			quiet += 1
			eq((t["cone"] as PackedVector2Array).size(), 0, "7. with no cone")
			eq(t["unit"], "b2", "7. it is b2's")
			eq(t["target"]["kind"], "point", "7. and carries b2's target (a small mark, as the aim's crosshair is)")
	eq(quiet, 1, "7. one of them quiet")
	var drawn2 := node.draw_count
	await get_tree().process_frame
	await get_tree().process_frame
	check(node.draw_count > drawn2, "7. the cone and the quiet mark are drawn together")
	eq(node.failed_draws, 0, "7. every part of every look ran to its end")
	_ui.select("b2")
	_pl.clear()
	_ui.select("b1")
	_pl.clear()
	await get_tree().process_frame
	await get_tree().process_frame
	eq(node.marks.size(), 0, "7. a plan cleared leaves no mark")

# --- 8 -------------------------------------------------------------------------

func _check_enemy_never() -> void:
	# The enemy bomber plans a drop of its own (the sim takes any unit's plan).
	var eb: Unit = _w.units["eb"]
	var st := _w.plan_step("eb", 0, {"turn": 0.0, "speed": 85.0})
	check(not st.is_empty(), "8. the enemy bomber has a plan")
	var cone: Dictionary = _w.drop_cone("eb", 0)
	check(bool(cone.get("ok", false)), "8. and a cone")
	var ideal: Vector2 = cone["ideal_aim"]
	_w.plan_step("eb", 0, {"turn": 0.0, "speed": 85.0, "drop": {"aim": [ideal.x, ideal.y], "target": {"point": [ideal.x, ideal.y]}}})
	check((eb.plan[0] as Dictionary).has("drop"), "8. a drop is in the enemy's plan")
	_ui.select("eb")
	eq(_pl.plan_shown("eb"), false, "8. the enemy's plan may not be shown")
	for m: Dictionary in _pl.bomb_marks():
		check(m["unit"] != "eb", "8. no mark is the enemy's (selected)")
	_ui.select("b1")
	for m: Dictionary in _pl.bomb_marks():
		check(m["unit"] != "eb", "8. no mark is the enemy's (not selected)")
	eq(_pl.step_labels("eb"), [], "8. no lettering for it")
	eq(_pl.step_target(0, "eb"), {}, "8. and no target to read (Track T: the enemy's targets are never shown)")
	_ui.select("eb")
	eq(_pl.drop_info(0), {}, "8. nothing for the card (the enemy is selected: its plan may not be shown)")
	eq(_pl.drop_options()["available"], false, "8. the Drop control does nothing for an enemy unit")
	eq(_btn("drop")["enabled"], false, "8. and is off on the card")
	eq(_ui.orders.bomb_caption(), "", "8. with no caption")
	eq(_pl.toggle_drop(), {}, "8. toggling it does nothing")
	_ui.bomb_aim.refresh()
	for m: Dictionary in _ui.bomb_aim.marks:
		check(m["unit"] != "eb", "8. the node holds none of the enemy's")
	_ui.select("b1")
	_w.clear_plan("eb")

# --- 9 -------------------------------------------------------------------------

func _check_roster_static() -> void:
	var rows: Array[Dictionary] = _ui.roster.rows()
	var ids: Array = rows.map(func(r: Dictionary) -> String: return r["id"])
	eq(ids, ["b1", "b2", "p1"], "9. the roster lists the players' units, not the enemy's tower, batteries or bomber")
	var by: Dictionary = {}
	for r: Dictionary in rows:
		by[r["id"]] = r
	eq(by["b1"]["bombs"], {"drops_left": 3, "drops_max": 3, "per_drop": 4}, "9. the bomber's row carries 3 drops of 4")
	eq(by["p1"]["bombs"], {}, "9. the fighter's row carries none")
	_w.units["b1"].drops_left = 2
	var after: Dictionary = _ui.roster.rows()[0]
	eq(after["bombs"]["drops_left"], 2, "9. one drop spent: 2 left")
	eq(after["bombs"]["drops_max"], 3, "9. of 3")
	_w.units["b1"].drops_left = 3

# --- 10 ------------------------------------------------------------------------

func _check_ground() -> void:
	for id: String in ["tower", "aa1", "aa2"]:
		var m = _ui.marker_layer.marker(id)
		check(m != null, "10. %s has a marker" % id)
		if m != null:
			check(m.visible, "10. %s is on the map" % id)
	# Through the fog like any unit: drawn only while in sight.
	_ui.marker_layer.unit_visible = func(id: String) -> bool: return id != "tower"
	_ui.marker_layer.update_poses()
	eq(_ui.marker_layer.marker("tower").visible, false, "10. a tower outside the player's sight is not drawn")
	eq(_ui.marker_layer.marker("aa1").visible, true, "10. a battery in sight is")
	_ui.marker_layer.unit_visible = Callable()
	_ui.marker_layer.update_poses()
	eq(_ui.marker_layer.marker("tower").visible, true, "10. and the tower is drawn again once it is in sight")
	# The batteries' flak cones are shown as the selected unit's are (Alex: selected only): a battery is an
	# enemy unit, so none is drawn, selected or not.
	_ui.select("aa1")
	var cone_units: Array = _ui.cones.collect().map(func(c: Dictionary) -> String: return str(c["unit"]))
	check(not cone_units.has("aa1") and not cone_units.has("aa2") and not cone_units.has("tower"), "10. no flak cone of the enemy's batteries is drawn (selected: %s)" % str(cone_units))
	_ui.select("b1")
	check(_ui.cones.collect().size() > 0, "10. while the selected bomber's own cones are (%d)" % _ui.cones.collect().size())
	check(UnitMarkerArt.is_static("radio_tower") and UnitMarkerArt.is_static("anti_aircraft_battery"), "10. both are static silhouettes")
	var k_static: float = _st.num("marker.static_scale")
	near(_ui.marker_layer.marker("tower").draw_scale, k_static, 1e-9, "10. the tower is drawn static_scale (%.1f) times the planes' rule" % k_static)
	near(_ui.marker_layer.marker("aa1").draw_scale, k_static, 1e-9, "10. and so is a battery")
	near(_ui.marker_layer.marker("b1").draw_scale, 1.0, 1e-9, "10. a plane is drawn at the plane rule")
	check(not UnitMarkerArt.is_static("bomber") and not UnitMarkerArt.is_static("tank"), "10. and the planes and the tank are not")
	# The models are the sheet's: the same seed gives the same tower.
	var mt := UnitMarkerArt.model_for(_st, "radio_tower")
	var ma := UnitMarkerArt.model_for(_st, "anti_aircraft_battery")
	check(float(mt.p["height"]) >= 23.0 and float(mt.p["height"]) <= 27.0, "10. the tower is 23 to 27 m tall (%.2f)" % float(mt.p["height"]))
	check(float(mt.p["base"]) >= 5.4 and float(mt.p["base"]) <= 6.6, "10. its base is 5.4 to 6.6 m")
	check(int(mt.p["sections"]) >= 5 and int(mt.p["sections"]) <= 8, "10. five to eight sections")
	check((mt.G["legs"] as Array).size() == 4 and (mt.G["footings"] as Array).size() == 4, "10. four legs and four footings")
	check(float(ma.p["radius"]) >= 3.7 and float(ma.p["radius"]) <= 4.3, "10. the battery's pit is 3.7 to 4.3 m in radius")
	check([1, 2, 4].has(int(ma.p["guns"])), "10. with a single, twin or quad mount")
	check((ma.G["barrels"] as Array).size() == int(ma.p["guns"]), "10. a barrel for each gun")
	eq(UnitMarkerArt.unit_seed(_st.scene_seed, 6, 0), mt.seed, "10. the tower's seed is the sheet's unitSeed(6, 0)")
	eq(UnitMarkerArt.unit_seed(_st.scene_seed, 4, 0), ma.seed, "10. the battery's is unitSeed(4, 0)")
	# One accent zone each.
	check((mt.G["hutPanel"] as PackedVector2Array).size() == 4, "10. the tower's accent zone is the hut's roof panel")
	check((ma.G["panel"] as PackedVector2Array).size() == 4, "10. the battery's is its ground panel")
	# The tower's shadow: by the existing rule, height x the sun's length, away from the sun.
	var ink := UnitMarkerArt.ink_consts(_st)
	var ppm := 2.0
	var stat = UnitMarkerArt._statics()
	var v := UnitMarkerArt.View.new(0.0, 0.0, ppm, 0.0)
	var reach := 0.0
	var h := float(mt.p["height"])
	for pr: Dictionary in stat.shadow_prims(mt, v, ink, _st, {}):
		for q: Vector2 in pr["pts"]:
			reach = maxf(reach, q.dot(ink.sd))
	var want := h * _st.sun_len() * ppm
	check(reach >= want - 1.0 and reach <= want + 12.0 * ppm, "10. the tower's shadow reaches its height x the sun's length: %.1f px for %.1f (%.0f m x %.3f x %.1f px/m)" % [reach, want, h, _st.sun_len(), ppm])
	check(reach > 10.0 * mt.p["base"] * 0.5, "10. a long shadow (%.1f px) beside a 6 m base" % reach)
	# The battery's shadow is short: a sandbag ring and a gun.
	var band: Dictionary = stat.prep_aa(ma, v, ink)
	var reach_aa := 0.0
	for pr: Dictionary in stat.shadow_prims(ma, v, ink, _st, band):
		for q: Vector2 in pr["pts"]:
			reach_aa = maxf(reach_aa, q.dot(ink.sd))
	check(reach_aa < reach, "10. the battery's shadow is shorter than the tower's")
	check(reach_aa > float(ma.p["radius"]) * ppm * 0.5, "10. but it has one")

# The effects layer's strike calls, recorded (the feed makes them only to a layer that has them).
class _FakeFx extends RefCounted:
	var calls: Array = []
	func emit_path(_u: String, _s: Callable, _t0: float, _t1: float, _f: float, _sz: float = 9.0) -> int:
		return 0
	func falling(_u: String, _p: Vector2, _h: float, _t: float, _sz: float = 9.0, _hd: float = NAN) -> int:
		return 0
	func explode_midair(_u: String, _p: Vector2, _h: float, _t: float, _sz: float = 9.0, _hd: float = NAN) -> void:
		calls.append({"call": "explode_midair"})
	func impact(_u: String, _p: Vector2, _t: float, _sz: float = 9.0, _hd: float = NAN) -> void:
		calls.append({"call": "impact"})
	func add_scar(_u: String, _p: Vector2, _t: float, _sz: float = 9.0, _r: float = 0.0, _s: int = 0) -> void:
		calls.append({"call": "add_scar"})
	func set_time(_t: float) -> void:
		pass
	func clear() -> void:
		calls.append({"call": "clear"})
	func flak_burst(pos: Vector2, h: float, t: float, hit: bool, shot_id: String = "", _sz: float = 0.0) -> void:
		calls.append({"call": "flak_burst", "pos": pos, "h": h, "t": t, "hit": hit, "shot": shot_id})
	func bomb_drop(unit_id: String, bomb_id: int, from_pos: Vector2, h: float, t_release: float, to_pos: Vector2, t_impact: float) -> void:
		calls.append({"call": "bomb_drop", "unit": unit_id, "bomb": bomb_id, "from": from_pos, "h": h, "t0": t_release, "to": to_pos, "t1": t_impact})
	func bomb_impact(pos: Vector2, t: float, blast: float = 45.0, unit_id: String = "", bomb_id: int = 0) -> void:
		calls.append({"call": "bomb_impact", "pos": pos, "t": t, "blast": blast, "unit": unit_id, "bomb": bomb_id})
	func add_crater(unit_id: String, pos: Vector2, t: float, blast: float = 45.0, _s: int = 0) -> void:
		calls.append({"call": "add_crater", "unit": unit_id, "pos": pos, "t": t, "blast": blast})
	func ruin(unit_id: String, pos: Vector2, t: float, kind: String = "radio_tower", size_m: float = 12.0, heading: float = 0.0) -> void:
		calls.append({"call": "ruin", "unit": unit_id, "pos": pos, "t": t, "kind": kind, "size": size_m, "heading": heading})
	func add_ruin(unit_id: String, pos: Vector2, t: float, kind: String = "radio_tower", size_m: float = 12.0, heading: float = 0.0, _s: int = 0) -> void:
		calls.append({"call": "add_ruin", "unit": unit_id, "pos": pos, "t": t, "kind": kind})
	func of(name: String) -> Array:
		return calls.filter(func(c: Dictionary) -> bool: return c["call"] == name)

# Plays a turn to its end, returning every frame's (t, tower visible, bomber's row drops) and the events seen.
func _play(ui: UnitUI, frames: Array, events: Array) -> void:
	var guard := 0
	while not ui.is_playing() and guard < 5:
		await get_tree().process_frame
		guard += 1
	guard = 0
	while ui.is_playing() and guard < 900:
		var t := ui.playback_time()
		var row_b: Dictionary = {}
		for r: Dictionary in ui.roster.rows():
			if r["id"] == "b1":
				row_b = r["bombs"]
		frames.append({"t": t, "tower": ui.marker_layer.marker("tower").visible, "drops": int(row_b.get("drops_left", -1)), "events": events.size()})
		await get_tree().process_frame
		guard += 1

func _check_playback() -> void:
	_ui.queue_free()
	_ui = null
	await get_tree().process_frame
	# A fresh world: a low bomber whose first step's drop is aimed at a tower that is nearly dead (one pip), a battery
	# far away so its flak is out of it. The bombs fall for five seconds from the low band, so the tower dies in turn 2.
	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 2500.0, "y": 2400.0, "heading": 0.0, "altitude_band": "low"})
	w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 3300.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 4700.0, "y": 4700.0, "heading": 0.4})
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, _xf, "local")
	var pl: MotionPlanner = ui.planner
	var fake := _FakeFx.new()
	ui.feed.fx = fake
	var events: Array = []
	ui.playback_event.connect(func(ev: Dictionary) -> void: events.append(ev))
	ui.select("b1")
	pl.place_point(Vector2(2650.0, 2400.0))
	var ideal: Vector2 = pl.bombs.cone("b1", 0)["ideal_aim"]
	w.units["tower"].x = ideal.x
	w.units["tower"].y = ideal.y
	w.units["tower"].health = 1
	var m_tower = ui.marker_layer.marker("tower")
	check(m_tower.visible, "11. the tower's marker is up before the strike")
	# TRACK T (Alex: "left-click an enemy unit" sets the target): a left-click on the tower's marker makes it the TARGET; the
	# bomber stays selected and nothing is aimed or planned by it. (It used to move the aim, as aiming at the tower was clicking
	# the tower; now the click is the target and Drop takes it.)
	ui.marker_layer.update_poses()
	var press_pt: Vector2 = m_tower.position + Vector2(m_tower.radius_px() * 0.5, 0.0)
	eq(ui.marker_layer.unit_at(press_pt), "tower", "11. the point is on the tower's marker")
	eq(pl.grab_at(press_pt), {}, "11. off every handle")
	check(ui.map_press(press_pt), "11. a left press there is taken")
	check(not pl.is_aiming(), "11. it is not an aim drag")
	eq(ui.selection.unit_id, "b1", "11. the bomber stays selected: the tower is not")
	eq(ui.target.unit_id, "tower", "11. the tower is the TARGET")
	ui.map_release(press_pt)
	check(pl.set_step_drop(0, true).size() > 0, "11. Drop takes the tower as the step's target")
	eq(pl.step_target(0)["unit"], "tower", "11. a UNIT target (it follows the unit)")
	check(pl.step_aim(0).distance_to(ideal) < 1e-3, "11. aimed at where the tower is shown")
	# The aim handle sits on the tower: a plain click on it keeps the unit target, and does not nudge the aim.
	var handle_pt: Vector2 = _xf * pl.step_aim(0)
	check(ui.map_press(handle_pt), "11. a press on the aim handle (on the tower) is taken")
	check(pl.is_aiming(), "11. as an aim drag")
	ui.map_release(handle_pt)
	eq(pl.step_target(0)["unit"], "tower", "11. a click, not a drag: the step's target is still the unit")
	check(pl.step_aim(0).distance_to(ideal) < 1e-3, "11. and the aim has not moved")
	eq(ui.roster.rows()[0]["bombs"]["drops_left"], 3, "11. the roster shows three drops")
	var sp: Dictionary = pl.bomb_marks()[0]["spread"]
	check(float(sp["b"]) > 0.0, "11. and the aim's spread")
	# Turn 1: the stick leaves; the roster's marks hold until the release is seen.
	ui.press_ready()
	var frames1: Array = []
	await _play(ui, frames1, events)
	var rel: Array = events.filter(func(e: Dictionary) -> bool: return e["type"] == "bomb_release")
	eq(rel.size(), 1, "11. turn 1: one bomb_release event (a drop of four)")
	if rel.size() == 1:
		eq(rel[0]["unit"], "b1", "11. the bomber's")
		eq(rel[0]["bombs"], 4, "11. four bombs")
	check(frames1.size() > 100, "11. the turn played (%d frames)" % frames1.size())
	eq(w.units["b1"].drops_left, 2, "11. the world has spent a drop")
	eq(int(frames1[0]["drops"]), 3, "11. the roster still shows three at the start of the playback (a resolve does not spoil a release)")
	var t_rel := float(rel[0]["t"]) if rel.size() == 1 else 99.0
	var before_ok := true
	var after_ok := true
	for f: Dictionary in frames1:
		if float(f["t"]) < t_rel - 0.05 and int(f["drops"]) != 3:
			before_ok = false
		if float(f["t"]) > t_rel + 0.05 and int(f["drops"]) != 2:
			after_ok = false
	check(before_ok, "11. three drops shown until the release is seen")
	check(after_ok, "11. two shown from the moment it is")
	eq(ui.roster.rows()[0]["bombs"]["drops_left"], 2, "11. and two after the turn")
	eq(fake.of("bomb_drop").size(), 4, "11. the feed makes four bomb_drop calls, one for each bomb")
	for c: Dictionary in fake.of("bomb_drop"):
		check(float(c["t1"]) > float(c["t0"]) + 3.0, "11. each falls for seconds (%.1f s)" % (float(c["t1"]) - float(c["t0"])))
		check(float(c["h"]) > 50.0, "11. from the low band's height above the ground (%.0f m)" % float(c["h"]))
	check(fake.of("ruin").is_empty(), "11. the tower stands after turn 1")
	check(m_tower.visible, "11. and its marker is up")
	eq(w.phase, World.PHASE_PLANNING, "11. turn 2 is being planned")
	# Turn 2: the bombs land, the tower goes down, its marker goes at the down event.
	events.clear()
	ui.press_ready()
	var frames2: Array = []
	await _play(ui, frames2, events)
	var downs: Array = events.filter(func(e: Dictionary) -> bool: return e["type"] == "down" and e["unit"] == "tower")
	eq(downs.size(), 1, "11. turn 2: the tower goes down")
	if downs.size() == 1:
		eq(downs[0]["fate"], "destroyed", "11. destroyed")
		var t_down := float(downs[0]["t"])
		var seen_up := false
		var bad_before := 0
		var bad_after := 0
		for f: Dictionary in frames2:
			if float(f["t"]) < t_down - 0.02:
				seen_up = seen_up or bool(f["tower"])
				if not bool(f["tower"]):
					bad_before += 1
			elif float(f["t"]) > t_down + 0.02 and bool(f["tower"]):
				bad_after += 1
		check(seen_up, "11. the tower's marker is up until the down event")
		eq(bad_before, 0, "11. at every frame before it")
		eq(bad_after, 0, "11. and gone at every frame from it")
		var ru: Array = fake.of("ruin")
		eq(ru.size(), 1, "11. the feed asks for the ruin once")
		if ru.size() == 1:
			eq(ru[0]["unit"], "tower", "11. the tower's")
			eq(ru[0]["kind"], "radio_tower", "11. of the radio tower kind")
			check((ru[0]["pos"] as Vector2).distance_to(ideal) < 1.0, "11. where it stood")
			near(float(ru[0]["t"]), 5.0 + t_down, 1e-6, "11. at the event's game time (turn 2)")
	check(not fake.of("bomb_impact").is_empty(), "11. the bombs' blasts are asked for")
	for c: Dictionary in fake.of("bomb_impact"):
		check(float(c["blast"]) > 10.0, "11. with the sim's blast radius (%.0f m)" % float(c["blast"]))
	print("[test] turn 1: %d frames, the bomb_release at %.2f s; turn 2: %d frames, %d bomb_impact event(s), %d bomb_impact call(s), the tower down at %.2f s" % [frames1.size(), t_rel, frames2.size(), events.filter(func(e: Dictionary) -> bool: return e["type"] == "bomb_impact").size(), fake.of("bomb_impact").size(), float(downs[0]["t"]) if downs.size() == 1 else -1.0])
	check(not m_tower.visible, "11. after the turn the tower's marker is gone")
	eq(String(w.units["tower"].fate), Unit.FATE_DESTROYED, "11. the tower is destroyed in the world")
	eq(ui.roster.rows().size(), 1, "11. the roster still holds the bomber alone")
	# A late joiner finds the ruin as a fact of the map.
	fake.calls.clear()
	ui.feed.restore_wrecks(false, ui.game_time(), true)
	eq(fake.of("add_ruin").size(), 1, "11. a late joiner's layer gets the ruin back")
	# Flak: a battery's shot at a plane becomes a burst beside the plane, in the plane's sight.
	fake.calls.clear()
	ui.feed.on_event({"type": "fire", "turn": w.turn, "tick": 3, "unit": "aa1", "target": "b1", "t": 1.0, "hit": true,
		"tx": 2600.0, "ty": 2400.0, "theight_m": 120.0, "weapon": "flak", "hardpoint": 0})
	var fl: Array = fake.of("flak_burst")
	eq(fl.size(), 1, "12. a ground unit's shot at a plane asks for a flak burst")
	if fl.size() == 1:
		eq(fl[0]["pos"], Vector2(2600.0, 2400.0), "12. at the target")
		eq(fl[0]["hit"], true, "12. a hit")
		# (The weapon is in the name since the battery got its light flak: two guns can roll on one tick.)
		eq(fl[0]["shot"], "aa1/flak/3", "12. named by the shooter, the weapon and the tick")
	fake.calls.clear()
	ui.feed.on_event({"type": "fire", "turn": w.turn, "tick": 4, "unit": "b1", "target": "aa1", "t": 1.0, "hit": false,
		"tx": 4700.0, "ty": 4700.0, "theight_m": 0.0, "weapon": "nose_gun", "hardpoint": 0})
	check(fake.of("flak_burst").is_empty(), "12. a plane's shot at a battery is no flak")
	ui.queue_free()
