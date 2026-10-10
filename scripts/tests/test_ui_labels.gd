extends "res://scripts/test_support/test_case.gd"

# HEIGHT AND SPEED LABELS (Track U3, 2026-10-10; Alex: "make sure that every unit and every node has a height
# and speed label" -- height is hard to read from above). Headless, on the real World, mounted through UnitUI:
#
#   1. the data: every key the labels read exists
#   2. EVERY UNIT has a label, own or enemy: "400 m . 100" (height in metres, speed in m/s) in the data's format;
#      a static unit (the tower, a battery) "0 m" and no speed; it follows the unit through a playback (a climb)
#   3. EVERY NODE has one: a planned step's line gains the height ("2 . 76 m/s . 400 m"), a carry-on step has its
#      own ("76 m/s . 400 m"); the band's metres, the simulation's
#   4. NEVER AN ENEMY'S PLAN: no node lettering for an AI unit, whatever it has planned; its current state is labelled
#   5. WHAT HEIGHT MEANS is data: "ground" subtracts the terrain under the unit (both for units and for nodes)
#   6. THE FAR ZOOM hides them (labels.hide_below_px_per_m), and the data's switch does

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")

const PPM := 1.0

var _w: World
var _ui: UnitUI
var _st: UiStyle

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	_check_data()
	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	_w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2800.0, "heading": 0.0, "altitude_band": "high"})
	_w.add_unit({"id": "e1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 2300.0, "y": 2300.0, "heading": PI, "altitude_band": "low"})
	_w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 3000.0, "y": 2500.0, "heading": 0.0})
	_w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2900.0, "y": 2400.0, "heading": 0.4})
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		finish()
		return
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -Vector2(1300.0, 2000.0) * PPM)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, xf, "local")
	_ui.auto_resolve = false
	_check_units()
	_check_nodes()
	_check_enemy_plan()
	_check_ground_ref()
	_check_far_zoom()
	await _check_playback()
	finish()

# --- 1 -------------------------------------------------------------------------

func _check_data() -> void:
	for n: String in ["labels.hide_below_px_per_m", "labels.below_px", "labels.halo_px"]:
		check(_st.lookup(n) is float or _st.lookup(n) is int, "ui.json has a number at '%s'" % n)
	for n: String in ["labels.unit", "labels.unit_static", "labels.node_suffix", "labels.node_carry", "labels.height_ref"]:
		check(_st.lookup(n) is String, "ui.json has a string at '%s'" % n)
	check(_st.flag("labels.enabled"), "the labels are on in the data")
	check(["sim", "ground"].has(_st.text("labels.height_ref")), "the height reference is one the code knows")
	check(_st.has_role("label_ink") and _st.has_role("label_carry") and _st.has_role("label_halo"), "the label roles exist")
	eq(_st.errors.size(), 0, "no style lookups failed: %s" % str(_st.errors))

# --- 2 -------------------------------------------------------------------------

func _unit_want(id: String) -> String:
	var u = _w.units[id]
	var h := _w.band_height(str(u.altitude_band))
	if u.def.is_static():
		return _st.text("labels.unit_static") % roundi(h)
	return _st.text("labels.unit") % [roundi(h), roundi(float(u.speed))]

func _check_units() -> void:
	var ml = _ui.marker_layer
	eq(ml.unit_label("p1"), "400 m · 100", "2. a light fighter at medium, 100 m/s: height and speed, compact")
	eq(ml.unit_label("b1"), "1000 m · 85", "2. a bomber at high, 85 m/s")
	eq(ml.unit_label("e1"), _unit_want("e1"), "2. an ENEMY plane is labelled too (its current state is visible state)")
	check(ml.unit_label("e1").begins_with("120 m"), "2. at low, 120 m (%s)" % ml.unit_label("e1"))
	eq(ml.unit_label("tower"), "0 m", "2. a static unit: its height above the ground, no speed")
	eq(ml.unit_label("aa1"), "0 m", "2. a battery too")
	for id: String in ["p1", "b1", "e1", "tower", "aa1"]:
		check(ml.label_shown(id), "2. %s's label is drawn" % id)
	eq(ml.unit_label("nobody"), "", "2. no unit, no label")
	# Not for a unit that is not on the map (out of sight, gone).
	ml.unit_visible = func(id: String) -> bool: return id != "e1"
	ml.update_poses()
	eq(ml.label_shown("e1"), false, "2. an enemy out of sight has no label (nothing of it is drawn)")
	ml.unit_visible = Callable()
	ml.update_poses()
	eq(ml.label_shown("e1"), true, "2. in sight again, it has")

# --- 3 -------------------------------------------------------------------------

func _check_nodes() -> void:
	_ui.select("p1")
	var pl = _ui.planner
	pl.clear()
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 130.0})
	_w.plan_step("p1", 1, {"turn": 0.0, "speed": 60.0})
	var st: Array = pl.states("p1")
	var labels: Array = pl.step_labels("p1")
	eq(labels.size(), 5, "3. a label slot for every step")
	for k in 5:
		check(not (labels[k] as PackedStringArray).is_empty(), "3. step %d has lettering" % (k + 1))
	for k in 2:
		var want := "%d · %d m/s" % [k + 1, roundi(float(st[k]["speed"]))] + _st.text("labels.node_suffix") % 400
		eq((labels[k] as PackedStringArray)[0], want, "3. a planned step says its number, its speed and its height")
	for k in range(2, 5):
		var want2 := _st.text("labels.node_carry") % [roundi(float(st[k]["speed"])), 400]
		eq((labels[k] as PackedStringArray)[0], want2, "3. a carry-on step says its speed and height")
	# A climb changes the node's height, and the band line stays.
	var up: Dictionary = pl.change_band(1)
	check(not up.is_empty(), "3. step 2 climbs")
	var l2: PackedStringArray = pl.step_labels("p1")[1]
	check((l2[0] as String).ends_with(_st.text("labels.node_suffix") % 1000), "3. the climbing node is 1000 m (%s)" % l2[0])
	eq(l2[1], "climb to high", "3. the band line is as it was")
	var l3: PackedStringArray = pl.step_labels("p1")[2]
	check((l3[0] as String).ends_with(" m") and (l3[0] as String).contains("1000"), "3. and the carry-on nodes after it are at 1000 m (%s)" % l3[0])
	pl.clear()

# --- 4 -------------------------------------------------------------------------

func _check_enemy_plan() -> void:
	_w.plan_step("e1", 0, {"turn": 0.0, "speed": 120.0})
	_w.plan_step("e1", 1, {"turn": 0.1, "speed": 120.0})
	check(not (_w.units["e1"].plan as Array).is_empty(), "4. the enemy has a plan in the world")
	eq(_ui.planner.step_labels("e1"), [], "4. no node lettering for it, whatever it has planned")
	_ui.select("e1")
	eq(_ui.planner.step_labels(), [], "4. not even when it is selected")
	eq(_ui.marker_layer.unit_label("e1"), _unit_want("e1"), "4. its current height and speed are labelled all the same")
	_ui.select("p1")
	_w.clear_plan("e1")

# --- 5 -------------------------------------------------------------------------

func _check_ground_ref() -> void:
	var ml = _ui.marker_layer
	ml.ground_height = func(_x: float, _y: float) -> float: return 100.0
	_st.ui["labels"]["height_ref"] = "ground"
	eq(ml.unit_label("p1"), "300 m · 100", "5. 'ground': the height above the terrain under it (400 over a 100 m ground)")
	eq(ml.unit_label("tower"), "0 m", "5. a static unit stays 0 m")
	_ui.select("p1")
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	var l: PackedStringArray = _ui.planner.step_labels("p1")[0]
	check((l[0] as String).ends_with(_st.text("labels.node_suffix") % 300), "5. and so is a node's (%s)" % l[0])
	_st.ui["labels"]["height_ref"] = "sim"
	check((_ui.planner.step_labels("p1")[0][0] as String).ends_with(_st.text("labels.node_suffix") % 400), "5. 'sim' (the default): the band's metres, the simulation's")
	ml.ground_height = Callable()
	_ui.planner.clear()

# --- 6 -------------------------------------------------------------------------

func _check_far_zoom() -> void:
	var ml = _ui.marker_layer
	var edge: float = _st.num("labels.hide_below_px_per_m")
	check(UiLabels.shown(_st, edge), "6. labels show at the data's scale (%.2f px/m)" % edge)
	check(not UiLabels.shown(_st, edge - 0.01), "6. and hide just below it")
	# At the planning zoom (0.35 of 2 px/m = 0.7 px/m) they show; zoomed out to 0.3 px/m they do not.
	_ui.set_mapping(Transform2D(0.0, Vector2(0.7, 0.7), 0.0, -Vector2(1300.0, 2000.0) * 0.7))
	ml.update_poses()
	check(ml.label_shown("p1"), "6. at the planning zoom (0.7 px/m) a unit's label is drawn")
	_ui.set_mapping(Transform2D(0.0, Vector2(0.3, 0.3), 0.0, -Vector2(1300.0, 2000.0) * 0.3))
	ml.update_poses()
	for id: String in ["p1", "b1", "e1", "tower"]:
		check(not ml.label_shown(id), "6. at the far zoom (0.3 px/m) %s's label is hidden" % id)
	# (the node lettering follows the same rule: ghost scale is the mapping's)
	check(not UiLabels.shown(_st, _ui.mapping.px_per_m(Vector2(1500.0, 2400.0))), "6. and a node's, by the same rule")
	_ui.set_mapping(Transform2D(0.0, Vector2(PPM, PPM), 0.0, -Vector2(1300.0, 2000.0) * PPM))
	ml.update_poses()
	check(ml.label_shown("p1"), "6. back in, it is back")
	_st.ui["labels"]["enabled"] = false
	check(not ml.label_shown("p1"), "6. the data's switch turns them off")
	_ui.select("p1")
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	eq((_ui.planner.step_labels("p1")[0] as PackedStringArray)[0], "1 · 100 m/s", "6. and the node line is as it was before the labels")
	_st.ui["labels"]["enabled"] = true
	_ui.planner.clear()

# --- the playback --------------------------------------------------------------------------

func _check_playback() -> void:
	# A climb flown: the label's height follows the pose the marker is drawn at, from 400 up to 1000 m.
	var ml = _ui.marker_layer
	_ui.select("p1")
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0, "altitude_band": "high"})
	_w.commit("ai")
	_w.commit("local")
	_w.resolve()
	ml.playback_paused = true
	ml.set_playback_time(0.0)
	var h0 := _label_height(ml.unit_label("p1"))
	ml.set_playback_time(0.5)
	var h1 := _label_height(ml.unit_label("p1"))
	ml.set_playback_time(2.5)
	var h2 := _label_height(ml.unit_label("p1"))
	print("[test] a climb played: label heights %d, %d, %d m at 0, 0.5, 2.5 s (%s)" % [h0, h1, h2, ml.unit_label("p1")])
	check(h0 <= 410 and h0 >= 399, "7. the label starts at 400 m (%d)" % h0)
	check(h1 > h0 and h1 < 1000, "7. it rises through the climb (%d m at 0.5 s)" % h1)
	check(h2 == 1000, "7. and ends at 1000 m (%d)" % h2)
	check(ml.label_shown("p1"), "7. it is drawn during the playback")
	ml.playback_paused = false
	await get_tree().process_frame

func _label_height(label: String) -> int:
	return int(label.split(" m")[0])
