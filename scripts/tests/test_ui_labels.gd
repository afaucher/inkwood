extends "res://scripts/test_support/test_case.gd"

# HEIGHT AND SPEED LABELS (Track U3, 2026-10-10; Alex: "make sure that every unit and every node has a height
# and speed label" -- height is hard to read from above). Headless, on the real World, mounted through UnitUI:
#
#   1. the data: every key the labels read exists
#   2. EVERY UNIT has a label, own or enemy, BY ITS KIND (decisions labels-by-type, playtest-4: every number carries its unit; ships and tanks
#      drop the altitude): an aircraft "400 m . 100 m/s"; a tank "8 m/s" (its speed alone); a static ground unit (the tower, a battery) none
#      (PROPOSED: labels.unit_static ""); it follows the unit through a playback (a climb)
#   3. EVERY NODE has one: TWO LINES, the speed over the height ("76 m/s" over "400 m"), no step number (Track L, 2026-10-10,
#      Alex: "2 lines. Remove the step # as well"), the same for a planned step and a carry-on one; the band's metres, the
#      simulation's
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
	_w.add_unit({"id": "et1", "type": "tank", "side": "axis", "controller": "ai", "x": 2700.0, "y": 2700.0, "heading": 0.0, "speed": 8.0})
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
	for n: String in ["labels.hide_below_px_per_m", "labels.below_px", "labels.halo_px", "labels.px", "labels.line_gap_px", "labels.font.weight"]:
		check(_st.lookup(n) is float or _st.lookup(n) is int, "ui.json has a number at '%s'" % n)
	for n: String in ["labels.unit", "labels.unit_surface", "labels.unit_static", "labels.node_speed", "labels.node_height", "labels.height_ref"]:
		check(_st.lookup(n) is String, "ui.json has a string at '%s'" % n)
	check(_st.flag("labels.enabled"), "the labels are on in the data")
	check(_st.lookup("labels.band_change_line") is bool, "the band line has its switch (proposed off)")
	check(_st.lookup("labels.node_suffix") == null and _st.lookup("labels.node_carry") == null, "the one-line formats are gone from the data")
	check(["sim", "ground"].has(_st.text("labels.height_ref")), "the height reference is one the code knows")
	check(_st.has_role("label_ink") and _st.has_role("label_carry") and _st.has_role("label_halo"), "the label roles exist")
	check(_st.lookup("labels.font.serif") is Array and not (_st.lookup("labels.font.serif") as Array).is_empty(), "the label face names its families (readable lettering, Track C)")
	check(_st.lookup("labels.font.italic") is bool, "and says whether it is italic")
	eq(_st.errors.size(), 0, "no style lookups failed: %s" % str(_st.errors))

# --- 2 -------------------------------------------------------------------------

func _unit_want(id: String) -> String:
	var u = _w.units[id]
	var h := _w.band_height(str(u.altitude_band))
	if u.def.is_static():
		return ""
	if str(u.def.domain) != "air":
		return _st.text("labels.unit_surface") % [roundi(float(u.speed)), _st.text("roster.speed_unit")]
	return _st.text("labels.unit") % [roundi(h), roundi(float(u.speed)), _st.text("roster.speed_unit")]

func _check_units() -> void:
	var ml = _ui.marker_layer
	eq(ml.unit_label("p1"), "400 m · 100 m/s", "2. a light fighter at medium, 100 m/s: height and speed, each with its unit")
	eq(ml.unit_label("b1"), "1000 m · 85 m/s", "2. a bomber at high, 85 m/s")
	eq(ml.unit_label("e1"), _unit_want("e1"), "2. an ENEMY plane is labelled too (its current state is visible state)")
	check(ml.unit_label("e1").begins_with("120 m"), "2. at low, 120 m (%s)" % ml.unit_label("e1"))
	eq(ml.unit_label("et1"), "8 m/s", "2. a tank: its speed alone, with the unit; no altitude (labels-by-type)")
	check(not ml.unit_label("et1").contains(" m · "), "2. ...no height in it, and no 'm - 0' of the playtest")
	eq(ml.unit_label("tower"), "", "2. a static ground unit has no label (labels.unit_static is empty: PROPOSED)")
	eq(ml.unit_label("aa1"), "", "2. a battery too")
	for id: String in ["p1", "b1", "e1", "et1"]:
		check(ml.label_shown(id), "2. %s's label is drawn" % id)
	for id: String in ["tower", "aa1"]:
		check(not ml.label_shown(id), "2. %s has no label to draw" % id)
	# a ship under the water keeps its depth (the aircraft's format, depth then speed)
	eq(UiLabels.unit_text(_st, -12.0, 0.0, false, false, true), "-12 m · 0 m/s", "2. a sunk ship keeps its depth label")
	eq(UiLabels.unit_text(_st, 400.0, 100.0, false, true), "400 m · 100 m/s", "2. an aircraft: height and speed")
	eq(UiLabels.unit_text(_st, 0.0, 12.0, false, false), "12 m/s", "2. a ship: its speed alone")
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
		var lines: PackedStringArray = labels[k]
		eq(lines.size(), 2, "3. step %d has two lines of lettering (speed over height)" % (k + 1))
		eq(lines[0], "%d m/s" % roundi(float(st[k]["speed"])), "3. the first is the speed the step ends at (step %d), in the data's format" % (k + 1))
		eq(lines[1], _st.text("labels.node_height") % 400, "3. the second is the height, the band's metres (step %d)" % (k + 1))
		for ln: String in lines:
			check(not ln.contains("·") and not ln.begins_with(str(k + 1) + " "), "3. no step number, no separator in '%s'" % ln)
	check(roundi(float(st[0]["speed"])) != roundi(float(st[1]["speed"])), "3. (the two planned steps end at different speeds)")
	# A climb changes the node's height; the band line is off by default (proposed removal) and comes back with its switch.
	var up: Dictionary = pl.change_band(1)
	check(not up.is_empty(), "3. step 2 climbs")
	var l2: PackedStringArray = pl.step_labels("p1")[1]
	eq(l2.size(), 2, "3. the climbing step still has two lines (the band line is off by default)")
	eq(l2[1], _st.text("labels.node_height") % 1000, "3. the climbing node is 1000 m (%s)" % l2[1])
	_st.ui["labels"]["band_change_line"] = true
	var l2b: PackedStringArray = pl.step_labels("p1")[1]
	eq(l2b.size(), 3, "3. with the switch on, the band line is a third line")
	eq(l2b[2], "climb to high", "3. 'climb to high', as it was")
	_st.ui["labels"]["band_change_line"] = false
	var l3: PackedStringArray = pl.step_labels("p1")[2]
	eq(l3[1], _st.text("labels.node_height") % 1000, "3. and the carry-on nodes after it are at 1000 m (%s)" % l3[1])
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
	eq(ml.unit_label("p1"), "300 m · 100 m/s", "5. 'ground': the height above the terrain under it (400 over a 100 m ground)")
	eq(ml.unit_label("et1"), "8 m/s", "5. a tank's label has no height to change")
	_ui.select("p1")
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	var l: PackedStringArray = _ui.planner.step_labels("p1")[0]
	eq(l[1], _st.text("labels.node_height") % 300, "5. and so is a node's (%s)" % l[1])
	_st.ui["labels"]["height_ref"] = "sim"
	eq(_ui.planner.step_labels("p1")[0][1], _st.text("labels.node_height") % 400, "5. 'sim' (the default): the band's metres, the simulation's")
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
	for id: String in ["p1", "b1", "e1", "et1"]:
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
	eq(_ui.planner.step_labels("p1")[0], PackedStringArray(["100 m/s"]), "6. and the node says only its speed (no height line)")
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
