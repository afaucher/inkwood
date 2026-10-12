extends "res://scripts/test_support/test_case.gd"

# THE WARSHIP'S MAIN GUNS IN THE INTERFACE (Track SH, the warship, proposed 2026-10-10). Alex, decisions special-targeting,
# target-follows-unit, step-selection: a special is active and targeted for its step; the target is an enemy unit or a point; with no
# target, or one out of reach, the special cannot be activated and the card says why; a unit target is followed; the step lettering
# names the special and its action ("Main Guns Fire"). The special plumbing is the bomb drop's, GENERALISED: the same button, the same
# toggle, the same step selection, the same card lines, with the sim's reasons (World.gun_check). Headless, on the real World, mounted
# through UnitUI as the assembly mounts it:
#
#   1. the style data (words and marks)
#   2. THE CARD: the button wears "Main Guns Fire"; no step, no target, each reason in plain words; a good target enables it
#   3. THE STEP: toggling stores the target and the aim on the step ("fire"), the step is lettered "Main Guns Fire", the strip marks it,
#      a second step is refused (one salvo a turn), off removes it; moving the step keeps its fire
#   4. THE SIM AGREES: the planned step's analysis, the held fire (the target leaves the sight) marked "will not fire"
#   5. THE RELOAD on the card, after a resolve
#   6. THE BOMB DROP is as it was: a bomber's button says "Bomb Drop" and drops
#   7. THE WIRE: the fire crosses with the plan (WorldSync) and a bad one is refused
#   9. THE SIDE VIEW: a step with Main Guns Fire shows the shell's flight to the target (guns.gd's arc), the scatter and the indicator
#   8. THE PLAYBACK: the salvo's shells are drawn as the bombs are, each from the guns to where it lands, and each landing is a blast

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")
const Guns = preload("res://scripts/sim/guns.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")

const PPM := 0.5
const ORIGIN := Vector2(400.0, 2100.0)
const LABEL := "Main Guns Fire"

var _w: World
var _ui: UnitUI
var _pl: MotionPlanner
var _xf: Transform2D
var _st: UiStyle

func setup(_main) -> void:
	timeout_seconds = 120.0
	_st = UiStyle.new()
	_check_data(_st)
	_rebuild()
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		finish()
		return
	eq(_card(), true, "2. the card part ran to its end")
	eq(_step(), true, "3. the step part ran to its end")
	eq(_sim_agrees(), true, "4. the sim part ran to its end")
	eq(_reload(), true, "5. the reload part ran to its end")
	eq(_bomb_drop(), true, "6. the bomb part ran to its end")
	eq(_wire(), true, "7. the wire part ran to its end")
	eq(_side_view(), true, "9. the side-view part ran to its end")
	eq(await _playback(), true, "8. the playback part ran to its end")
	finish()

func _rebuild() -> void:
	if _ui != null:
		remove_child(_ui)
		_ui.queue_free()
	_w = GunWorlds.world(3)
	_w.add_unit({"id": "aa_far", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 1900.0, "y": 3300.0, "heading": 0.0})
	_w.add_unit({"id": "aa_in", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 3200.0, "y": 2500.0, "heading": 0.0})
	_w.add_unit({"id": "aa_edge", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 4800.0, "y": 2500.0, "heading": 0.0})
	_w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": 1500.0, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
	_w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 1900.0, "y": 1500.0, "heading": 0.0})
	_xf = Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, _xf, "local")
	_ui.auto_resolve = false
	_pl = _ui.planner

func _fresh(id: String = "cruiser") -> void:
	_ui.select("")
	_ui.select(id)
	_pl.clear()
	_ui.target.clear()

func _btn(name: String) -> Dictionary:
	return _ui.orders.buttons()[name]

# --- 1 ------------------------------------------------------------------------------------------------

func _check_data(st: UiStyle) -> void:
	for n: String in ["place_first", "no_target", "reloading", "reloading_one", "already_planned", "target_down", "own_side", "too_close", "out_of_range",
			"inland", "unspotted", "unit_down", "not_a_gun", "free", "on", "wont_fire", "step_tag_blocked", "poor_unspotted", "poor_out_of_range", "poor_too_close", "poor_inland", "step_tag_poor"]:
		check(st.lookup("guns.text." + n) is String, "ui.json has a string at 'guns.text.%s'" % n)
	for n: String in ["line_alpha", "ring_alpha", "ring_line_px", "sigma_k", "ring_min_px", "target_cross_px", "reach_alpha", "reach_dash_px", "reach_gap_px"]:
		check(st.lookup("guns.marks." + n) is float or st.lookup("guns.marks." + n) is int, "ui.json has a number at 'guns.marks.%s'" % n)
	eq(st.errors.size(), 0, "no style lookups failed: %s" % str(st.errors))

# --- 2 ------------------------------------------------------------------------------------------------

func _card() -> bool:
	_fresh()
	eq(_pl.special_kind("cruiser"), "gun", "2. the cruiser's special is a gun salvo")
	eq(_pl.special_kind("bomber"), "bomb", "2. the bomber's is a bomb drop")
	eq(_pl.special_kind("spotter"), "", "2. a radio tower's is nothing")
	eq(_pl.special_label("cruiser"), LABEL, "2. the special wears its name and action")
	eq(_btn("drop")["label"], LABEL, "2. the button says '%s'" % LABEL)
	eq(_btn("drop")["enabled"], false, "2. no step placed: the button is off")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.place_first") % LABEL, "2. and the card says to place a step first: '%s'" % _ui.orders.bomb_caption())
	eq(_ui.orders.target_caption(), _st.text("bombs.text.target_none"), "2. the target line is always there for a unit with a special: '%s'" % _ui.orders.target_caption())
	# THE SPECIAL'S STATE and WHY (decision playtest-3), one record: the sim's own reasons, in the card's words.
	var ss: Dictionary = _ui.orders.special_state()
	eq([ss["has"], ss["kind"], ss["label"], ss["engaged"], ss["available"]], [true, "gun", LABEL, false, false], "2. [state] the cruiser has the Main Guns special, not engaged, not on offer")
	eq(ss["reason"], _st.text("guns.text.place_first") % LABEL, "2. [state] why: no step placed")
	_pl.place_point(Vector2(700.0, 2500.0))
	eq(_ui.orders.special_state()["reason"], _st.text("guns.text.no_target") % LABEL, "2. [state] why: no target")
	eq(_btn("drop")["enabled"], false, "2. a step placed and NO TARGET: off")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.no_target") % LABEL, "2. the card: '%s'" % _ui.orders.bomb_caption())
	eq(_pl.toggle_drop(), {}, "2. the button does nothing")
	check(not _pl.step_has_fire(0), "2. and no fire was planned")
	# Each reason, in the card's words.
	_ui.set_target_unit("aa_far")
	eq(_btn("drop")["enabled"], false, "2. an enemy no friend sees: off")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.unspotted"), "2. 'not spotted': '%s'" % _ui.orders.bomb_caption())
	eq(_ui.orders.special_state()["reason"], _st.text("guns.text.unspotted"), "2. [state] why: the target is not spotted")
	_ui.set_target_unit("aa_in")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.inland"), "2. 'inland': '%s'" % _ui.orders.bomb_caption())
	_ui.set_target_unit("aa_edge")
	check(_ui.orders.bomb_caption().begins_with("target is out of range ("), "2. 'out of range' with the numbers: '%s'" % _ui.orders.bomb_caption())
	eq(_ui.orders.special_state()["reason"], _ui.orders.bomb_caption(), "2. [state] why: the same words")
	_ui.target.set_point(Vector2(740.0, 2500.0))
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.too_close") % 150, "2. 'too close' for a point alongside: '%s'" % _ui.orders.bomb_caption())
	# A point in the fog on the coast.
	_ui.target.set_point(Vector2(1800.0, 3500.0))
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.unspotted"), "2. a point nobody sees is not spotted either (Alex: the location 'needs to be found'): '%s'" % _ui.orders.bomb_caption())
	eq(_ui.orders.target_caption(), _st.text("bombs.text.target_point"), "2. the target line names a point: '%s'" % _ui.orders.target_caption())
	# A good one.
	_ui.set_target_unit("aa")
	eq(_btn("drop")["enabled"], true, "2. a spotted enemy on the coast in range: ON")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.free") % [1, LABEL], "2. the card: '%s'" % _ui.orders.bomb_caption())
	var free: Dictionary = _ui.orders.special_state()
	eq([free["engaged"], free["available"], free["reason"]], [false, true, ""], "2. [state] a good target: free to press, nothing to explain")
	eq(_ui.orders.target_caption(), _st.text("bombs.text.target_unit") % "anti-aircraft battery", "2. the target line: '%s'" % _ui.orders.target_caption())
	# A point near the tower is spotted too.
	_ui.target.set_point(Vector2(1800.0, 2480.0))
	eq(_btn("drop")["enabled"], true, "2. so is a point the tower sees")
	_pl.clear()
	return true

# --- 3 ------------------------------------------------------------------------------------------------

func _step() -> bool:
	_fresh()
	_pl.place_point(Vector2(700.0, 2500.0))
	_pl.place_point(Vector2(800.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	var st := _pl.toggle_drop()
	check(not st.is_empty() and st.has("fire"), "3. the button plans the fire on the selected step: %s" % _w.last_error)
	check(_pl.step_has_fire(0) and _pl.step_has_special(0) and not _pl.step_has_drop(0), "3. step 1 carries a fire, not a drop")
	var f: Dictionary = _w.units["cruiser"].plan[0]["fire"]
	eq(f["special"], "main_guns", "3. the request is the special's")
	eq(f["target"], {"unit": "aa"}, "3. and carries the target (a unit: followed)")
	eq(f["aim"], [1800.0, 2500.0], "3. and the aim it was shown at")
	eq(_pl.step_target(0), {"unit": "aa", "point": Vector2(1800.0, 2500.0)}, "3. step_target reads it back (the seam the side view reads)")
	eq(_btn("drop")["on"], true, "3. the button is pressed")
	var on_state: Dictionary = _ui.orders.special_state()
	eq([on_state["engaged"], on_state["will_fire"], on_state["step"], on_state["reason"]], [true, true, 0, ""], "3. [state] ENGAGED on step 1, and it will fire")
	check(_ui.orders.bomb_caption().begins_with("step 1: %s  ·  spread " % LABEL), "3. the card shows the spread and the range: '%s'" % _ui.orders.bomb_caption())
	eq(_ui.orders.target_caption(), _st.text("bombs.text.target_unit") % "anti-aircraft battery", "3. and the step's own target: '%s'" % _ui.orders.target_caption())
	# The lettering at the step's node.
	var labels := _pl.step_labels()
	check((labels[0] as PackedStringArray).has(LABEL), "3. step 1's lettering names the special and its action: %s" % str(labels[0]))
	check(not (labels[1] as PackedStringArray).has(LABEL), "3. step 2's does not: %s" % str(labels[1]))
	# The step strip marks it.
	var marks: Array = _ui.orders.step_marks()
	eq([marks[0]["special"], marks[1]["special"]], [true, false], "3. the strip marks step 1")
	# One salvo a turn: step 2 cannot have it too.
	_pl.set_focus_step(1)
	eq(_btn("drop")["enabled"], false, "3. step 2: off (one salvo a turn)")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.already_planned") % [LABEL, 1], "3. the card: '%s'" % _ui.orders.bomb_caption())
	eq(_pl.toggle_drop(), {}, "3. and the button does nothing")
	# A step moved keeps its fire (and the lettering stays).
	_pl.set_focus_step(0)
	_pl.begin_edit(0, Vector2(700.0, 2500.0), true)
	_pl.drag_step(Vector2(730.0, 2490.0))
	_pl.end_step()
	check(_pl.step_has_fire(0), "3. a step moved keeps its fire")
	check(absf(float(_w.planned_states("cruiser")[0]["x"]) - 600.0) > 0.0 and _pl.step_target(0).has("unit"), "3. ... and its target")
	# Off.
	_pl.set_focus_step(0)
	var off := _pl.toggle_drop()
	check(not off.is_empty() and not off.has("fire"), "3. pressed again, the fire is off")
	check(not _pl.step_has_fire(0), "3. and gone from the plan")
	eq(_btn("drop")["on"], false, "3. the button is up")
	# Two different targets are not two salvos: a point target, stored as a point.
	_ui.target.set_point(Vector2(1800.0, 2480.0))
	_pl.set_focus_step(1)
	var sp := _pl.toggle_drop()
	check(not sp.is_empty() and _w.units["cruiser"].plan[1]["fire"]["target"] == {"point": [1800.0, 2480.0]}, "3. a point target is stored as a point on step 2")
	eq(_pl.step_target(1)["unit"], "", "3. (no unit)")
	_pl.clear()
	return true

# --- 4 ------------------------------------------------------------------------------------------------

func _sim_agrees() -> bool:
	_fresh()
	_pl.place_point(Vector2(700.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	_pl.toggle_drop()
	var st: Dictionary = _w.planned_states("cruiser")[0]
	eq(st["fire"]["ok"], true, "4. the step's analysis: it will fire")
	eq(_pl.fire_blocked(0), false, "4. nothing marks it")
	# The spotter leaves the sight: the fire is marked and the card and the lettering say so. Alex (decision outside-cone-release,
	# 2026-10-11): "Fire a poorer one" -- the default (data/sim/guns.json gun_unspotted_mode) is a poor shot, worded as a poor bomb is.
	_w.units["spotter"].x = 4500.0
	_w.plan_changed.emit("cruiser")
	eq(_w.guns.unspotted_mode, "poor_shot", "4. (the default mode)")
	eq(_pl.fire_blocked(0), false, "4. the target is no longer spotted: the salvo is NOT blocked, it goes off poorly")
	eq(_pl.fire_poor(0), true, "4. ... the fire is MARKED as a poor shot")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.poor_unspotted"), "4. the card: '%s'" % _ui.orders.bomb_caption())
	check(_ui.orders.bomb_caption().begins_with("poor shot: "), "4. in the words of a poor bomb")
	check((_pl.step_labels()[0] as PackedStringArray).has(_st.text("guns.text.step_tag_poor")), "4. and the lettering: %s" % str(_pl.step_labels()[0]))
	check(not (_pl.step_labels()[0] as PackedStringArray).has(_st.text("guns.text.step_tag_blocked")), "4. (not 'will not fire')")
	eq(_w.planned_states("cruiser")[0]["fire"]["reason"], "unspotted", "4. the sim's own reason")
	eq(_w.planned_states("cruiser")[0]["fire"]["poor_shot"], true, "4. and that it is a poor shot")
	near(float(_pl.fire_info(0)["spread_m"]), Guns.poor_sigma_m(float(_pl.fire_info(0)["range_m"]), 0.0, _w.guns.special("main_guns")), 1e-6, "4. the scatter the map shows is the poor one: %.1f m" % float(_pl.fire_info(0)["spread_m"]))
	# The words for each way out of reach.
	check(_pl.gun_poor_text({"reason": "out_of_range", "range_m": 3500.0, "range_max_m": 3000.0}).begins_with("poor shot: out of range"), "4. poor shot, out of range: '%s'" % _pl.gun_poor_text({"reason": "out_of_range", "range_m": 3500.0, "range_max_m": 3000.0}))
	check(_pl.gun_poor_text({"reason": "too_close", "range_min_m": 150.0}).begins_with("poor shot: "), "4. poor shot, too close")
	check(_pl.gun_poor_text({"reason": "inland"}).begins_with("poor shot: "), "4. poor shot, inland")
	# With the sim's switch on hold the old words stand: it will not fire.
	_w.guns.unspotted_mode = "hold"
	_w.plan_changed.emit("cruiser")
	eq(_pl.fire_blocked(0), true, "4. hold: the target is no longer spotted: the fire is MARKED as blocked")
	eq(_pl.fire_poor(0), false, "4. ... and not as a poor shot")
	check(_ui.orders.bomb_caption().begins_with("will not fire: "), "4. the card: '%s'" % _ui.orders.bomb_caption())
	check((_pl.step_labels()[0] as PackedStringArray).has(_st.text("guns.text.step_tag_blocked")), "4. and the lettering: %s" % str(_pl.step_labels()[0]))
	_w.guns.unspotted_mode = "poor_shot"
	_w.units["spotter"].x = 2000.0
	_w.plan_changed.emit("cruiser")
	eq(_pl.fire_blocked(0), false, "4. back in sight: unmarked")
	eq(_pl.fire_poor(0), false, "4. ... either way")
	_pl.clear()
	return true

# --- 5 ------------------------------------------------------------------------------------------------

func _reload() -> bool:
	_rebuild()
	_fresh()
	_pl.place_point(Vector2(700.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	check(not _pl.toggle_drop().is_empty(), "5. a salvo is planned")
	var res := GunWorlds.turn(_w)
	check(not res.is_empty(), "5. the turn resolves: %s" % _w.last_error)
	_w.begin_turn()
	_ui.select("")
	_ui.select("cruiser")
	_pl.place_point(Vector2(700.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	eq(_btn("drop")["enabled"], false, "5. the next turn: the guns are reloading, the button is off")
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.reloading") % [LABEL, 2], "5. the card says for how long: '%s'" % _ui.orders.bomb_caption())
	eq([_ui.orders.special_state()["engaged"], _ui.orders.special_state()["reason"]], [false, _st.text("guns.text.reloading") % [LABEL, 2]], "5. [state] not engaged, because it is reloading")
	_pl.clear()
	GunWorlds.next_turn(_w)
	_ui.select("")
	_ui.select("cruiser")
	_pl.place_point(Vector2(700.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	eq(_ui.orders.bomb_caption(), _st.text("guns.text.reloading_one") % LABEL, "5. one turn later: '%s'" % _ui.orders.bomb_caption())
	_pl.clear()
	return true

# --- 6 ------------------------------------------------------------------------------------------------

func _bomb_drop() -> bool:
	_rebuild()
	_fresh("bomber")
	eq(_btn("drop")["label"], "Bomb Drop", "6. a bomber's button says Bomb Drop")
	_pl.place_point(Vector2(700.0, 1500.0))
	var cone: Dictionary = _pl.bombs.cone("bomber", 0)
	_ui.target.set_point(cone["ideal_aim"])
	eq(_btn("drop")["enabled"], true, "6. a target in the cone: on")
	check(not _pl.toggle_drop().is_empty() and _pl.step_has_drop(0) and not _pl.step_has_fire(0), "6. the button plans a DROP")
	check(_w.units["bomber"].plan[0].has("drop") and not _w.units["bomber"].plan[0].has("fire"), "6. in the request's \"drop\"")
	check((_pl.step_labels()[0] as PackedStringArray).has("Bomb Drop"), "6. lettered 'Bomb Drop'")
	_pl.clear()
	_fresh("cruiser")
	eq(_btn("drop")["label"], LABEL, "6. and back on the cruiser the button is the guns'")
	return true

# --- 7 ------------------------------------------------------------------------------------------------

func _wire() -> bool:
	_rebuild()
	_fresh()
	_pl.place_point(Vector2(700.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	_pl.toggle_drop()
	var plan: Array = (_w.units["cruiser"].plan as Array).duplicate(true)
	var sync := WorldSync.new()
	sync.world = _w
	eq(sync._plan_problem("cruiser", plan), "", "7. the host takes the plan with the fire in it")
	var bad: Array = [{"fire": {"special": "main_guns"}}]
	check(sync._plan_problem("cruiser", bad) != "", "7. and refuses a fire with no target: '%s'" % sync._plan_problem("cruiser", bad))
	# The same plan replayed on another World gives the same step (what a co-op partner sees).
	var other := GunWorlds.world(3)
	for i in plan.size():
		if not (plan[i] as Dictionary).is_empty():
			other.plan_step("cruiser", i, plan[i])
	eq(other.planned_states("cruiser")[0]["fire"], _w.planned_states("cruiser")[0]["fire"], "7. replayed on another World it is the same step")
	var snap := _w.net_guns()
	eq(snap.keys().size(), 3, "7. the snapshot carries the shells, the spotting and the bracketing")
	sync.free()
	_pl.clear()
	return true

# --- 9 ------------------------------------------------------------------------------------------------

# THE SIDE VIEW of a step with Main Guns Fire: the shell's flight (guns.gd's arc) to the target, the scatter on the ground, the target's
# indicator -- in the drop's frame, indicators only.
func _side_view() -> bool:
	_rebuild()
	_fresh()
	var sv: Object = _ui.get_meta("side_view", null)
	if not check(sv != null, "9. the sidebar has a views card (a card of its own under the orders card: decision playtest-3)"):
		return false
	_pl.place_point(Vector2(632.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	sv.refresh()
	eq(sv.model()["mode"], "guns", "9. before the fire: the guns' cones, as ever")
	check(not _pl.toggle_drop().is_empty(), "9. the fire is planned")
	sv.refresh()
	var m: Dictionary = sv.model()
	eq(m["mode"], "fire", "9. a step with Main Guns Fire shows the shell's flight")
	check((m["cones"] as Array).is_empty(), "9. instead of the cones")
	var d: Dictionary = m["drop"]
	var chk: Dictionary = _pl.fire_check(0)
	var spec = _w.guns.special("main_guns")
	var o: Vector2 = m["origin"]
	var ppm: float = m["ppm"]
	var land_m: float = (chk["from"] as Vector2).distance_to(GunWorlds.TARGET)
	near(float(d["land_m"]), land_m, 1e-6, "9. it lands where the target is shown, %.0f m from the guns" % land_m)
	near(float(d["fall_s"]), Guns.flight_time(land_m, spec), 1e-9, "9. after the flight time guns.gd gives")
	check(bool(d["releases"]) and bool(d["fire"]), "9. a salvo the sim would fire is drawn full")
	var arc: PackedVector2Array = d["arc"]
	check(arc.size() > 4 and arc[0].is_equal_approx(o), "9. from the ship (%d points)" % arc.size())
	check(arc[arc.size() - 1].is_equal_approx(o + Vector2(land_m * ppm, 0.0)), "9. to the ground at the landing, on the one scale")
	var apex_px := o.y
	for q: Vector2 in arc:
		apex_px = minf(apex_px, q.y)
	near(o.y - apex_px, spec.apex_per_range * land_m * ppm, 0.01, "9. up to guns.gd's apex (%.0f m, %.1f px): one scale for both axes" % [spec.apex_per_range * land_m, o.y - apex_px])
	var mid := arc[arc.size() / 2]
	near(o.y - mid.y, spec.apex_per_range * land_m * ppm, 0.01, "9. at the middle of the flight")
	var band: Vector2 = d["spread_px"]
	near(band.y - band.x, 2.0 * 2.0 * float(chk["spread_m"]) * ppm, 1e-3, "9. the scatter's two sigma either side of the landing, on the ground")
	near(float(m["ground_y"]), o.y, 1e-9, "9. the ship stands on the ground line")
	var t: Dictionary = m["target"]
	check(not t.is_empty() and bool(t["inside"]) and str(t["kind"]) == "unit" and bool(t["ground"]), "9. the target's indicator: a ground unit's tick, inside the picture")
	check((t["px"] as Vector2).is_equal_approx(arc[arc.size() - 1]), "9. on the landing")
	check(str(m["line"]).begins_with("anti-aircraft battery · %d m · flies " % roundi(land_m)), "9. the quiet line: '%s'" % str(m["line"]))
	# A salvo the sim would not fire is drawn faint (its reason is on the card).
	_w.units["spotter"].x = 4500.0
	_w.plan_changed.emit("cruiser")
	sv.refresh()
	check(bool((sv.model()["drop"] as Dictionary)["releases"]) and bool((sv.model()["drop"] as Dictionary)["poor_shot"]), "9. unspotted: a poor shot still flies, drawn full and marked poor")
	_w.guns.unspotted_mode = "hold"
	_w.plan_changed.emit("cruiser")
	sv.refresh()
	check(not bool((sv.model()["drop"] as Dictionary)["releases"]), "9. unspotted with the switch on hold: the flight is drawn faint")
	_w.guns.unspotted_mode = "poor_shot"
	_w.units["spotter"].x = 2000.0
	_w.plan_changed.emit("cruiser")
	# The card's picture draws (a runtime error in a sub-draw is counted).
	var failed_before: int = sv.failed_draws
	sv.refresh()
	sv._pic.queue_redraw()
	# A point target is a cross on the ground; the fire off, the cones are back.
	_pl.set_focus_step(0)
	check(not _pl.toggle_drop().is_empty(), "9. the fire is taken off")
	sv.refresh()
	eq(sv.model()["mode"], "guns", "9. and the cones are back")
	eq(sv.failed_draws, failed_before, "9. (no sub-draw failed)")
	return true

# --- 8 ------------------------------------------------------------------------------------------------

# The effects layer's calls, recorded (the combat feed makes them only to a layer that has them).
class _FakeFx extends RefCounted:
	var calls: Array = []
	func emit_path(_u: String, _s: Callable, _t0: float, _t1: float, _f: float, _sz: float = 9.0, _back: float = NAN, _rise: float = 0.0) -> int:
		return 0
	func falling(_u: String, _p: Vector2, _h: float, _t: float, _sz: float = 9.0, _hd: float = NAN, _src: float = -1.0, _back: float = NAN, _rise: float = 0.0) -> int:
		return 0
	func explode_midair(_u: String, _p: Vector2, _h: float, _t: float, _sz: float = 9.0, _hd: float = NAN) -> void:
		pass
	func impact(_u: String, _p: Vector2, _t: float, _sz: float = 9.0, _hd: float = NAN) -> void:
		pass
	func add_scar(_u: String, _p: Vector2, _t: float, _sz: float = 9.0, _r: float = 0.0, _s: int = 0) -> void:
		pass
	func set_time(_t: float) -> void:
		pass
	func clear() -> void:
		pass
	func flak_burst(_pos: Vector2, _h: float, _t: float, _hit: bool, _shot_id: String = "", _sz: float = 0.0) -> void:
		pass
	func bomb_drop(unit_id: String, bomb_id: int, from_pos: Vector2, h: float, t_release: float, to_pos: Vector2, t_impact: float) -> void:
		calls.append({"call": "bomb_drop", "unit": unit_id, "bomb": bomb_id, "from": from_pos, "h": h, "t0": t_release, "to": to_pos, "t1": t_impact})
	func bomb_impact(pos: Vector2, t: float, blast: float = 45.0, unit_id: String = "", bomb_id: int = 0) -> void:
		calls.append({"call": "bomb_impact", "pos": pos, "t": t, "blast": blast, "unit": unit_id, "bomb": bomb_id})
	func add_crater(unit_id: String, pos: Vector2, t: float, blast: float = 45.0, _s: int = 0) -> void:
		calls.append({"call": "add_crater", "unit": unit_id, "pos": pos, "t": t, "blast": blast})
	func ruin(_u: String, _p: Vector2, _t: float, _k: String = "radio_tower", _sz: float = 12.0, _h: float = 0.0) -> void:
		pass
	func add_ruin(_u: String, _p: Vector2, _t: float, _k: String = "radio_tower", _sz: float = 12.0, _h: float = 0.0, _s: int = 0) -> void:
		pass
	func of(name: String) -> Array:
		return calls.filter(func(c: Dictionary) -> bool: return c["call"] == name)

func _play(ui: UnitUI) -> void:
	var guard := 0
	while not ui.is_playing() and guard < 5:
		await get_tree().process_frame
		guard += 1
	guard = 0
	while ui.is_playing() and guard < 900:
		await get_tree().process_frame
		guard += 1

func _row(ui: UnitUI, id: String) -> Dictionary:
	for r: Dictionary in ui.roster.rows():
		if r["id"] == id:
			return r
	return {}

func _playback() -> bool:
	_ui.queue_free()
	_ui = null
	await get_tree().process_frame
	var w := GunWorlds.world(3)
	w.spot_memory = {"allies": {"aa": 20.0}}
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, _xf, "local")
	ui.auto_begin_turn = true
	var fake := _FakeFx.new()
	ui.feed.fx = fake
	ui.select("cruiser")
	ui.planner.place_point(Vector2(632.0, 2500.0))
	ui.set_target_unit("aa")
	ui.planner.set_focus_step(0)
	check(not ui.planner.toggle_drop().is_empty(), "8. the salvo is planned")
	var row0: Dictionary = _row(ui, "cruiser")
	eq(row0["guns"], {}, "8. loaded: no reload mark on the roster row")
	eq(_row(ui, "spotter")["guns"], {}, "8. (and none on a tower's)")
	ui.press_ready()
	for _i in 3:
		await get_tree().process_frame
	check(ui.is_playing(), "8. the turn is playing")
	eq(_row(ui, "cruiser")["guns"], {}, "8. the roster shows the turn's start while it plays (a resolve does not spoil a salvo before it is seen)")
	await _play(ui)
	var row1: Dictionary = _row(ui, "cruiser")
	eq(row1["guns"], {"special": "main_guns", "left": 2}, "8. the next turn: the row says the guns are reloading, 2 turns")
	eq(_st.text("roster.text.reloading") % 2, "reload 2", "8. in the roster's words")
	var per: int = w.guns.special("main_guns").shells
	eq(fake.of("bomb_drop").size(), per, "8. turn 1: one falling-shell picture for each of the %d shells" % per)
	for c: Dictionary in fake.of("bomb_drop"):
		check(int(c["bomb"]) >= 500000 and int(c["bomb"]) < 600000, "8. its own key, apart from the bombs' (%d)" % int(c["bomb"]))
		check(float(c["t1"]) > float(c["t0"]) + 3.0, "8. flying for seconds (%.1f s)" % (float(c["t1"]) - float(c["t0"])))
		check((c["from"] as Vector2).distance_to(Vector2(w.units["cruiser"].x, w.units["cruiser"].y)) < 120.0, "8. from the ship")
		check((c["to"] as Vector2).distance_to(GunWorlds.TARGET) < 60.0, "8. to the target")
	eq(fake.of("bomb_impact").size(), 0, "8. nothing has landed yet")
	eq(w.turn, 2, "8. the next turn is being planned")
	ui.press_ready()
	await _play(ui)
	eq(_row(ui, "cruiser")["guns"], {"special": "main_guns", "left": 1}, "8. a turn later: 1 turn to go")
	var impacts := fake.of("bomb_impact")
	print("[test] playback: %d falling-shell pictures (turn 1), %d blasts (turn 2), first flight %.1f s" % [fake.of("bomb_drop").size(), impacts.size(), (float(fake.of("bomb_drop")[0]["t1"]) - float(fake.of("bomb_drop")[0]["t0"])) if not fake.of("bomb_drop").is_empty() else -1.0])
	eq(impacts.size(), per, "8. turn 2: each shell lands as a blast")
	for c: Dictionary in impacts:
		near(float(c["blast"]), w.guns.special("main_guns").blast_radius_m(), 1e-6, "8. the shell's own blast radius")
		check((c["pos"] as Vector2).distance_to(GunWorlds.TARGET) < 60.0, "8. on the target")
	return true
