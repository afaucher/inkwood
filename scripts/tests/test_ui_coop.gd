extends "res://scripts/test_support/test_case.gd"

# THE CO-OP INTERFACE (Track U2, "the first fight", part 1). Alex 2026-10-09:
# co-op plan editing is last-edit-wins with a full preview so every player
# sees what has plans and what does not; no unit belongs to a player; players
# never learn the enemy's plans. Headless; the UI is mounted through UnitUI as
# the sandbox mounts it and driven through its public methods. The draw
# dispatch is checked FOR REAL: a planner subclass records which unit each
# draw routine is called for while the engine runs _draw frame after frame.
#
#   1. the style data of the new pieces loads
#   2. health pips on every row (Unit.health of def.health), the callsign first
#   3. plan status: has a plan / no plan (flies on), live on World.plan_changed
#      for an edit that did not go through this UI (the network's), the header
#      counts who needs orders
#   4. a down unit: its row greyed, no selection by row, marker, Tab or code,
#      no planning; its fate (exploded / out of control / crashed) shown; a
#      marker that still moves
#   5. a selected unit that goes down is let go when planning starts again
#   6. health follows the PLAYBACK, not the resolve (no spoiled hits)
#   7. every player unit's plan on the map, all the time; NEVER an AI unit's
#      (path, ghosts, fan, clamps, labels): checked against what _draw
#      really calls, and against a tripwire on who reads plans
#   8. the speed each planned step ends at is in its label
#   9. the hooks for part 2: an overlay layer above the markers, a unit's
#      screen position at a time of the playback, the playback clock and the
#      events as the clock passes them
#  10. the sidebar's width is readable by the camera, and the column fits
#  11. a remote edit to a unit leaves the local player's Ready set (Alex
#      2026-10-09: other players' edits do not unready you); a local edit takes
#      it back, as before
#  12. GROUP BY (Alex: "a group by for needs orders"): the control cycles the
#      modes; headings with counts; and the rule that keeps rows still -- a
#      change is held while the pointer is over the roster, the selected unit's
#      row keeps its group, planning starting, a mode change and new units apply
#      at once, the playback holds the layout; a per-player view setting that is
#      not in the World

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiHealth = preload("res://scripts/ui/ui_health.gd")
const UiSelection = preload("res://scripts/ui/ui_selection.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")

const PPM := 3.8
const ORIGIN := Vector2(1400.0, 2300.0)

# A planner that draws nothing and records which unit every draw routine was
# asked to draw: the engine calls its real _draw.
class _RecPlanner extends MotionPlanner:
	var calls: Array = []
	func _draw_curve(id: String, _alpha: float, quiet: bool = false) -> void:
		calls.append(["curve", id, quiet])
	func _draw_ghosts(id: String) -> void:
		calls.append(["ghosts", id])
	func _draw_fan() -> void:
		calls.append(["fan", unit_id()])
	func _draw_clamps(id: String) -> void:
		calls.append(["clamps", id])

# A stand-in for a unit that has (or has not) Track C's fate.
class _WithFate extends RefCounted:
	var fate: String = ""

class _NoFate extends RefCounted:
	var health: int = 1

var _xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)

# The frame-driven part (a second world).
var _w2: World
var _ui2: UnitUI
var _rec: _RecPlanner
var _sel2: UiSelection
var _stage := 0
var _frames := 0
var _roster_draws := 0
var _draws_seen := 0

func setup(_main) -> void:
	var st := UiStyle.new()
	if not check(st.ok(), "the UI style data loads: %s" % str(st.errors)):
		finish()
		return
	_check_style_keys(st)
	_check_fate_text()
	_check_plan_readers()

	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "callsign": "Wizard",
		"x": 1500.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player",
		"x": 1520.0, "y": 2460.0, "heading": 0.0, "altitude_band": "low"})
	w.add_unit({"id": "p3", "type": "heavy_fighter", "side": "allies", "controller": "player",
		"x": 1700.0, "y": 2700.0, "heading": 0.0})
	w.add_unit({"id": "ai1", "type": "bomber", "side": "axis", "controller": "ai", "x": 3500.0, "y": 1800.0, "heading": PI})
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, _xf, "local")
	var ai := AiDumb.new(w)
	ai.attach()   # the AI plans (and readies) now: it has a plan the players must never see

	_check_health_rows(w, ui)
	_check_plan_status(w, ui)
	_check_speed_labels(w, ui)
	_check_ai_plan_hidden(w, ui)
	_check_down_unit(w, ui)
	_check_layout(w, ui)
	_check_turn_and_hooks(w, ui)
	_check_grouping()

	# The frame-driven part: a world of its own with a recording planner.
	_w2 = World.new()
	_w2.add_player("local")
	_w2.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	_w2.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1520.0, "y": 2460.0, "heading": 0.0})
	_w2.add_unit({"id": "ai1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 1900.0, "y": 2600.0, "heading": PI})
	_w2.plan_step("p1", 0, {"to": Vector2(1620.0, 2400.0)})
	_w2.plan_step("ai1", 0, {"to": Vector2(1800.0, 2600.0)})
	_w2.plan_step("ai1", 1, {"to": Vector2(1700.0, 2560.0)})
	_ui2 = UnitUI.new()
	add_child(_ui2)
	_ui2.setup(_w2, _xf, "local")
	_sel2 = UiSelection.new()
	_rec = _RecPlanner.new()
	add_child(_rec)
	_rec.setup(_w2, _xf, _sel2, "local", UiStyle.shared())
	_sel2.select("ai1")   # the enemy plane selected: nothing of its plan may be drawn
	_ui2.roster.draw.connect(func() -> void: _roster_draws += 1)

# --- 1. Style data -----------------------------------------------------------

func _check_style_keys(st: UiStyle) -> void:
	for r: String in ["health_pip", "health_pip_empty", "ring_health", "ring_health_empty", "row_down"]:
		check(st.has_role(r), "ui.json has role '%s'" % r)
	for n: String in ["health.pip_w_px", "health.pip_h_px", "health.pip_gap_px", "health.max_w_px", "health.ring_arc.span_deg",
			"health.ring_arc.gap_deg", "health.ring_arc.outside_px", "health.ring_arc.line_px", "health.ring_arc.empty_line_px",
			"roster.plan_glyph_px", "roster.plan_glyph_dot_px", "roster.name_clip_gap_px",
			"planner.others_alpha", "planner.others_line_px", "planner.others_carry_line_px", "planner.others_dot_px"]:
		var v: Variant = st.lookup(n)
		check(v is float or v is int, "ui.json has a number at '%s'" % n)
	for n: String in ["roster.group.bar_px", "roster.group.button_w_px", "roster.group.button_h_px", "roster.group.heading_px"]:
		check(st.lookup(n) is float or st.lookup(n) is int, "ui.json has a number at '%s'" % n)
	for t: String in ["roster.group.default", "roster.group.label", "roster.group.heading.needs_orders", "roster.group.heading.planned", "roster.group.heading.down"]:
		check(st.lookup(t) is String, "ui.json has the text %s" % t)
	var modes: Variant = st.lookup("roster.group.modes")
	check(modes is Array and (modes as Array).size() >= 2, "ui.json lists the group-by modes")
	for f: String in ["health.ring_arc.enabled", "planner.speed_labels"]:
		check(st.lookup(f) is bool, "ui.json has a flag at '%s'" % f)
	for t: String in ["has_plan", "no_plan", "flying", "down", "fate_exploded", "fate_out_of_control", "fate_crashed",
			"needs_orders_one", "needs_orders_many", "all_planned"]:
		check(st.lookup("roster.text." + t) is String, "ui.json has the text roster.text.%s" % t)
	check(st.num("planner.others_line_px") < st.num("planner.path_line_px"), "other units' plans are drawn thinner than the selected unit's")
	eq(st.errors.size(), 0, "no style lookups failed: %s" % str(st.errors))

# The wording of a downed unit's state, and Unit.fate read defensively (Track C's
# property may not exist): the row text for each fate.
func _check_fate_text() -> void:
	var st := UiStyle.shared() as UiStyle
	var r := Roster.new()
	r.style = st
	for case: Array in [["", "down"], ["exploded", "destroyed"], ["out_of_control", "out of control"], ["crashed", "crashed"], ["not_a_fate", "down"]]:
		eq(r.status_text({"status": "down", "fate": case[0], "planned": 0, "steps": 5}), case[1], "a down row with fate '%s' reads '%s'" % [case[0], case[1]])
	eq(r.status_text({"status": "none", "fate": "", "planned": 0, "steps": 5}), "no plan (flies on)", "a live unit with no plan flies on")
	eq(r.status_text({"status": "plan", "fate": "", "planned": 3, "steps": 5}), "plan: 3 of 5 steps", "a planned unit says how many steps")
	eq(r.status_text({"status": "flying", "fate": "", "planned": 0, "steps": 5}), "flying the turn", "after planning a live unit is flying the turn")
	r.free()
	var wf := _WithFate.new()
	wf.fate = "out_of_control"
	eq(UiHealth.fate_of(wf), "out_of_control", "a unit with a fate property gives it")
	eq(UiHealth.fate_of(_NoFate.new()), "", "a unit with no fate property (Track C's not landed) gives ''")
	eq(UiHealth.fate_of(null), "", "and no unit gives ''")

# The plan-reading tripwire: in scripts/ui and scripts/fx (the effects layer part 2
# will draw with) only the planner (and the roster, which counts the steps of player
# units) read a plan or its preview. A new file that does must be looked at (is it a
# unit the players control? is the phase planning?) before it is added here.
func _check_plan_readers() -> void:
	var rx := RegEx.new()
	rx.compile("\\.plan\\b|planned_states\\(|\"plan\"\\)|\\.reachable\\(")
	# (node_hover_board_shot.gd: a windowed board that saves and restores the plan of the
	# light fighter, a player unit, it plays itself.)
	var allowed := ["motion_planner.gd", "roster.gd", "node_hover_board_shot.gd"]
	var checked := 0
	for root: String in ["res://scripts/ui", "res://scripts/fx"]:
		for f: String in _gd_files(root):
			checked += 1
			var src := FileAccess.get_file_as_string(f)
			var hits := 0
			for line: String in src.split("\n"):
				if line.strip_edges().begins_with("#"):
					continue
				if rx.search(line) != null:
					hits += 1
			if allowed.has(f.get_file()):
				continue
			eq(hits, 0, "%s reads a plan or its preview: add it to this test's allow-list only after checking an AI unit's plan cannot reach the screen through it" % f)
	check(checked > 8, "the tripwire looked at the ui and fx folders (%d scripts)" % checked)

func _gd_files(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f: String in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	for sub: String in d.get_directories():
		out.append_array(_gd_files(dir_path.path_join(sub)))
	return out

# --- 2. Health pips -------------------------------------------------------------

func _check_health_rows(w: World, ui: UnitUI) -> void:
	var rows: Array[Dictionary] = ui.roster.rows()
	eq(rows.size(), 3, "three player rows (the AI's is not listed)")
	eq(rows[0]["name"], "Wizard", "2. the callsign is the row's name")
	eq(rows[0]["type"], "Light fighter", "2. and the type comes second")
	eq(rows[0]["health"], 3, "2. a light fighter shows 3 of its pips")
	eq(rows[0]["health_max"], 3, "2. out of 3")
	eq(rows[2]["health_max"], 5, "2. a heavy fighter has 5 pips")
	w.units["p1"].health = 1
	eq(ui.roster.rows()[0]["health"], 1, "2. a damaged unit shows the pips it has left")
	eq(ui.roster.rows()[0]["health_max"], 3, "2. out of the same 3")
	w.units["p1"].health = 3

# --- 3. Plan status -----------------------------------------------------------------

func _check_plan_status(w: World, ui: UnitUI) -> void:
	var r: Roster = ui.roster
	for row: Dictionary in r.rows():
		eq(row["status"], "none", "3. %s starts with no plan" % row["id"])
		check(bool(row["needs_orders"]) and not bool(row["has_plan"]), "3. and needs orders")
	eq(r.needs_orders_count(), 3, "3. three units need orders")
	check(r.header_status().contains("3 need orders"), "3. the header says so: '%s'" % r.header_status())
	eq(r.status_text(r.rows()[1]), "no plan (flies on)", "3. the row says no plan (flies on)")
	# This player plans p1 through the UI...
	ui.select("p1")
	ui.planner.place_point(Vector2(1600.0, 2400.0))
	eq(r.rows()[0]["status"], "plan", "3. p1 has a plan")
	check(not bool(r.rows()[0]["needs_orders"]), "3. and no longer needs orders")
	eq(r.status_text(r.rows()[0]), "plan: 1 of 5 steps", "3. the row counts the steps")
	# ... another player plans p2 and p3 over the network: straight through the World.
	var seen: Array[String] = []
	w.plan_changed.connect(func(id: String) -> void: seen.append(id))
	w.plan_step("p2", 0, {"to": Vector2(1640.0, 2440.0)})
	w.plan_step("p2", 1, {"to": Vector2(1780.0, 2440.0)})
	eq(r.rows()[1]["planned"], 2, "3. an edit made through the World shows on the row at once")
	eq(r.rows()[1]["status"], "plan", "3. p2 has a plan")
	eq(r.needs_orders_count(), 1, "3. one unit left that needs orders")
	check(r.header_status().contains("1 needs orders"), "3. the header: '%s'" % r.header_status())
	w.plan_step("p3", 0, {"to": Vector2(1900.0, 2700.0)})
	eq(r.needs_orders_count(), 0, "3. everyone has a plan")
	check(r.header_status().contains("all planned"), "3. the header: '%s'" % r.header_status())
	check(seen.has("p2") and seen.has("p3"), "3. World.plan_changed fired for the network's edits")
	# Last edit wins: another player clears what this one planned.
	w.clear_plan("p1")
	eq(r.rows()[0]["status"], "none", "3. a plan cleared by another player shows as no plan")
	eq(ui.planner.planned_count("p1"), 0, "3. and the planner agrees")
	# Row order never depends on plans (no row moves under a pointer).
	eq(r.rows().map(func(row: Dictionary) -> String: return row["id"]), ["p1", "p2", "p3"], "3. the rows keep their order whoever planned")
	# Every player unit's plan is on the map (the planner's curves), the unplanned one dashed.
	var cp2: Array = ui.planner.path_world("p2")
	check(cp2.size() == 5 and bool(cp2[0][1]) and bool(cp2[1][1]) and not bool(cp2[2][1]), "3. p2's two planned steps and three carry-on steps are all in its curve")
	var cp1: Array = ui.planner.path_world("p1")
	check(cp1.size() == 5 and not bool(cp1[0][1]), "3. p1, with no plan, still has its dashed carry-on flight")
	for id: String in ["p2", "p3"]:
		check(ui.planner.plan_shown(id), "3. %s's plan is shown" % id)
	w.clear_plan("p2")
	w.clear_plan("p3")

# --- 8. Speed per step -----------------------------------------------------------------

func _check_speed_labels(w: World, ui: UnitUI) -> void:
	ui.select("p1")
	var pl: MotionPlanner = ui.planner
	pl.clear()
	w.plan_step("p1", 0, {"turn": 0.0, "speed": 130.0})
	w.plan_step("p1", 1, {"turn": 0.0, "speed": 60.0})
	var st := pl.states("p1")
	var labels := pl.step_labels("p1")
	eq(labels.size(), 5, "8. a label slot per step")
	for k in 2:
		var want := "%d · %d m/s" % [k + 1, roundi(float(st[k]["speed"]))]
		eq((labels[k] as PackedStringArray)[0] if not (labels[k] as PackedStringArray).is_empty() else "", want, "8. step %d's label is its number and the speed it ends at" % (k + 1))
	check(roundi(float(st[0]["speed"])) != roundi(float(st[1]["speed"])), "8. the two steps end at different speeds (%d, %d)" % [roundi(float(st[0]["speed"])), roundi(float(st[1]["speed"]))])
	check((labels[2] as PackedStringArray).is_empty(), "8. a carry-on step has no label")
	var up := pl.change_band(1)
	check(not up.is_empty(), "8. step 2 climbs")
	var l2: PackedStringArray = pl.step_labels("p1")[1]
	eq(l2.size(), 2, "8. a climbing step has its speed line and a band line")
	eq(l2[1], "climb to high", "8. the band line")
	var spd: Variant = UiStyle.shared().lookup("planner.speed_labels")
	eq(spd, true, "8. speed labels are on in the data")
	pl.clear()

# --- 7. An AI unit's plan is never shown ----------------------------------------------------

func _check_ai_plan_hidden(w: World, ui: UnitUI) -> void:
	var pl: MotionPlanner = ui.planner
	check(not (w.units["ai1"].plan as Array).is_empty(), "7. the AI has a plan in the world (the host's)")
	check(not pl.plan_shown("ai1"), "7. an AI unit's plan is not to be shown")
	check(pl.plan_shown("p1") and pl.plan_shown("p2"), "7. a player unit's is")
	eq(pl.path_world("ai1"), [], "7. no path for the AI unit")
	eq(pl.step_labels("ai1"), [], "7. no step labels (ghosts) for the AI unit")
	# Selected, it still shows nothing and takes no orders.
	ui.select("ai1")
	eq(ui.selection.unit_id, "ai1", "7. the AI unit can be selected (to look at)")
	check(not pl.can_plan("ai1"), "7. but it takes no orders")
	eq(pl.fan_outline_world().size(), 0, "7. no fan")
	eq(pl.place_point(Vector2(3400.0, 1800.0)), {}, "7. a step cannot be placed")
	eq(pl.step_labels(), [], "7. and its labels (the selected unit's) are empty")
	# The marker layer shows where the AI unit is, never where its plan takes it.
	var pose: Dictionary = ui.marker_layer.pose_of("ai1")
	near(float(pose["x"]), 3500.0, 1e-9, "7. the AI marker is where the unit is (x), not on its plan")
	near(float(pose["y"]), 1800.0, 1e-9, "7. (y)")
	check(not ui.marker_layer.is_playing(), "7. no playback: no trails (the marker layer draws a unit's flown history only)")
	ui.select("p1")

# --- 4. A down unit -----------------------------------------------------------------------------

func _check_down_unit(w: World, ui: UnitUI) -> void:
	var r: Roster = ui.roster
	ui.select("p1")
	var picked: Array[String] = []
	var focused: Array[String] = []
	r.down_unit_picked.connect(func(id: String) -> void: picked.append(id))
	ui.unit_focus_requested.connect(func(id: String, _p: Vector2) -> void: focused.append(id))
	var p3 = w.units["p3"]
	p3.health = 0
	p3.down = true
	var row: Dictionary = r.rows()[2]
	check(bool(row["down"]), "4. a down unit's row says down")
	eq(row["status"], "down", "4. its status")
	eq(row["health"], 0, "4. no pips left")
	eq(row["health_max"], 5, "4. of 5")
	check(not bool(row["needs_orders"]) and not bool(row["has_plan"]), "4. it neither needs orders nor has a plan")
	eq(r.needs_orders_count(), 2, "4. so p1 and p2 are all that need orders")
	eq(r.selectable_ids().size(), 2, "4. two rows can be selected")
	check(not r.selectable_ids().has("p3"), "4. not the down one")
	check(r.ordered_ids().has("p3"), "4. though it is still listed")
	eq(r.select_row(2), false, "4. a down unit's row cannot be selected")
	eq(ui.selection.unit_id, "p1", "4. the selection stays")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = r.row_rect(2).get_center()
	r._gui_input(click)
	eq(ui.selection.unit_id, "p1", "4. a click on it changes nothing either")
	eq(picked, ["p3", "p3"] as Array[String], "4. down_unit_picked fired for both")
	eq(focused, ["p3", "p3"] as Array[String], "4. and the host is asked to look at it")
	ui.select("p3")
	eq(ui.selection.unit_id, "p1", "4. nor by code")
	var marker = ui.marker_layer.marker("p3")
	check(marker != null and marker.visible, "4. its marker stays on the map")
	ui.map_press(marker.position)
	eq(ui.selection.unit_id, "p1", "4. a press on its marker does not select it")
	var tab := InputEventKey.new()
	tab.keycode = OS.find_keycode_from_string(ui.style.text("keys.next_unit"))
	tab.pressed = true
	var order: Array[String] = []
	for i in 4:
		ui._key(tab)
		order.append(ui.selection.unit_id)
	eq(order, ["p2", "p1", "p2", "p1"] as Array[String], "4. Tab walks the units that take orders, skipping the down one")
	check(not ui.planner.can_plan("p3"), "4. no planning for it")
	check(not ui.planner.plan_shown("p3"), "4. and its plan is not shown")
	eq(ui.planner.path_world("p3"), [], "4. no curve")
	# A down unit cannot hold the turn up by flying off the map.
	p3.x = w.bounds.end.x - 50.0
	p3.heading = 0.0
	check(ui.planner.ready_blocker().is_empty(), "4. a down unit does not block Ready")
	p3.x = 1700.0
	# The marker keeps moving while the unit does (a plane out of control still flies).
	var before: Vector2 = marker.position
	p3.x += 100.0
	ui.marker_layer.update_poses()
	check(marker.position.distance_to(before) > 100.0 * PPM * 0.9, "4. a down unit's marker follows the unit")
	check(ui.marker_layer.unit_at(marker.position) == "p3", "4. and it is still a thing on the map")
	p3.x -= 100.0
	ui.marker_layer.update_poses()
	# The fate, when the Unit has one.
	if "fate" in p3:
		p3.set("fate", "out_of_control")
		eq(r.rows()[2]["fate"], "out_of_control", "4. the row carries the unit's fate")
		eq(r.status_text(r.rows()[2]), "out of control", "4. out of control")
		p3.set("fate", "exploded")
		eq(r.status_text(r.rows()[2]), "destroyed", "4. exploded reads destroyed")
		p3.set("fate", "crashed")
		eq(r.status_text(r.rows()[2]), "crashed", "4. crashed")
		p3.set("fate", "")
	else:
		print("[test] Unit.fate does not exist yet: the fate wording is checked through stand-ins only")
	p3.health = 5
	p3.down = false
	eq(r.selectable_ids().size(), 3, "4. a unit that is up again can be selected")
	ui.select("p1")

# --- 10. Layout ----------------------------------------------------------------------------------------

func _check_layout(_w: World, ui: UnitUI) -> void:
	var st: UiStyle = ui.style
	var vp := Vector2(1280.0, 720.0)
	ui.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)   # (a full-rect HUD would override the size we set)
	ui.hud.size = vp
	ui.layout()
	var inset: Dictionary = ui.hud_insets()
	near(float(inset["right"]), st.num("roster.width_px") + 2.0 * st.num("card.margin_px"), 1e-9, "10. the right inset is the card and its two margins")
	eq([inset["left"], inset["top"], inset["bottom"]], [0.0, 0.0, 0.0], "10. nothing on the other sides")
	near(ui.sidebar_width_px(), float(inset["right"]), 1e-9, "10. sidebar_width_px is the same number")
	var col := ui.sidebar_rect()
	near(col.end.x, vp.x, 1e-6, "10. the column ends at the window's edge")
	near(col.size.x, ui.sidebar_width_px(), 1e-6, "10. and is that wide")
	check(Rect2(ui.roster.position, ui.roster.size).end.x <= col.end.x + 1e-6 and ui.roster.position.x >= col.position.x, "10. the roster lies inside the column")
	check(Rect2(ui.orders.position, ui.orders.size).end.x <= col.end.x + 1e-6 and ui.orders.position.x >= col.position.x, "10. so does the orders card")
	check(ui.orders.position.y + ui.orders.size.y <= vp.y, "10. three units: the orders card is on screen at 720 px (%.0f)" % (ui.orders.position.y + ui.orders.size.y))
	# How many player units the column holds in a window of 720 px: the free
	# room is what is left under the header, the orders card and the margins.
	var m: float = st.num("card.margin_px")
	var fixed: float = m + st.num("roster.header_px") + st.num("roster.group.bar_px") + st.num("card.pad_px") + st.num("card.gap_px") + st.num("orders.height_px") + m
	var fits := floori((vp.y - fixed) / st.num("roster.row_px"))
	var grouped := floori((vp.y - fixed - 3.0 * st.num("roster.group.heading_px")) / st.num("roster.row_px"))
	print("[test] the sidebar column holds %d player units at 720 px (%d under three group headings), %d at 1080 px" % [fits, grouped, floori((1080.0 - fixed) / st.num("roster.row_px"))])
	check(fits >= 4, "10. the column holds at least four player units in a 720 px window (it holds %d)" % fits)
	check(grouped >= 3, "10. and three under all three group headings (%d)" % grouped)

# --- 5, 6, 9. The turn, the playback, the hooks --------------------------------------------------------------

func _check_turn_and_hooks(w: World, ui: UnitUI) -> void:
	# The layers: the overlay sits above the markers, the health arc in it.
	var parent := ui.marker_layer.get_parent()
	check(ui.overlay != null and ui.overlay.get_parent() == parent, "9. the overlay layer is in the same screen space as the markers")
	check(ui.overlay.get_index() > ui.marker_layer.get_index(), "9. and above them")
	check(ui.health_arc != null and ui.health_arc.get_parent() == ui.overlay, "9. the ring's health arc is its first child")
	check(ui.hud != null and ui.hud.get_parent() != parent, "9. the HUD (roster, orders) is a layer above")
	# The turn: p2 selected; p1 and p2 will fly on.
	ui.select("p2")
	for id: String in ["p1", "p2"]:
		w.plan_step(id, 0, {"to": Vector2(1640.0, 2420.0)})
	ui.press_ready()
	eq(w.phase, World.PHASE_RESOLVED, "the turn resolved (the AI had readied)")
	check(ui.is_playing(), "the playback runs")
	for row: Dictionary in ui.roster.rows():
		eq(row["status"], "flying", "3. during the turn %s is flying: its plan is consumed, not missing" % row["id"])
		check(not bool(row["needs_orders"]) and not bool(row["has_plan"]), "3. so it neither needs orders nor has a plan")
	eq(ui.roster.needs_orders_count(), 0, "3. nobody needs orders while the turn plays")
	check(ui.roster.header_status().contains("playing"), "3. the header says so: '%s'" % ui.roster.header_status())
	near(ui.playback_time(), 0.0, 1e-9, "9. playback_time is 0 at the start")
	# 9. A unit's screen position at a time of the playback.
	for t: float in [0.0, 1.7, 5.0]:
		var s := w.sample("p1", t, "history")
		var want: Vector2 = _xf * Vector2(float(s["x"]), float(s["y"]))
		check(ui.screen_pos_at("p1", t).distance_to(want) < 1e-3, "9. screen_pos_at(p1, %.1f) is where the mapping puts the sample" % t)
		check(ui.world_pos_at("p1", t).distance_to(Vector2(float(s["x"]), float(s["y"]))) < 1e-9, "9. world_pos_at (metres)")
	var pose := ui.screen_pose_at("p1", 2.5)
	for k: String in ["x", "y", "heading", "speed", "altitude_band", "height_m", "screen", "screen_heading", "px_per_m"]:
		check(pose.has(k), "9. screen_pose_at carries '%s'" % k)
	near(float(pose["px_per_m"]), PPM, 1e-4, "9. and the scale the mapping gives there")
	check(not ui.world_pos_at("nobody", 1.0).is_finite(), "9. an unknown unit is INF")
	ui.marker_layer.playback_paused = true
	ui.marker_layer.set_playback_time(2.5)
	check(ui.screen_pos_now("p1").distance_to(ui.screen_pos_at("p1", 2.5)) < 1e-3, "9. screen_pos_now is the marker, at the playback's pose")

	# 6. Health follows the playback. The resolve wrote the end state; combat will
	# have lowered p1 to 1 pip and downed p2 (here: by hand, as combat would).
	w.units["p1"].health = 1
	w.units["p2"].health = 0
	w.units["p2"].down = true
	var rows := ui.roster.rows()
	eq(rows[0]["health"], 3, "6. during the playback p1 still shows the health it began the turn with (no spoiled hit)")
	check(not bool(rows[1]["down"]), "6. and p2 is not yet shown down")
	eq(ui.selection.unit_id, "p2", "6. the selection is on p2 (it can still be selected: it has not visibly fallen)")
	ui.show_health("p1", 2)
	eq(ui.roster.rows()[0]["health"], 2, "6. show_health drops the pips as a hit passes")

	# 9. The clock and the events (the events combat sends; shapes in scripts/sim/combat.gd).
	var events: Array = [
		{"type": "hit", "unit": "p1", "t": 2.0, "health": 1, "damage": 1, "by": "ai1"},
		{"type": "fire", "unit": "ai1", "t": 0.5},
		{"type": "note"},
		{"type": "down", "unit": "p2", "t": 2.0},
		{"type": "end", "t": 5.0},
	]
	var fired: Array[String] = []
	var frames: Array[float] = []
	ui.playback_event.connect(func(ev: Dictionary) -> void: fired.append(str(ev["type"])))
	ui.playback_frame.connect(func(t: float, _turn: int) -> void: frames.append(t))
	w.turn_resolved.emit(w.turn, {}, events)   # the events arrive as World sends them; the playback restarts
	ui.marker_layer.playback_paused = true
	ui.marker_layer.set_playback_time(0.0)
	ui.poll_playback()
	eq(fired, ["note"] as Array[String], "9. at t = 0 the event with no time fires")
	ui.poll_playback()
	eq(fired.size(), 1, "9. polling again at the same time fires nothing twice")
	ui.marker_layer.set_playback_time(1.0)
	ui.poll_playback()
	eq(fired, ["note", "fire"] as Array[String], "9. the clock passing 0.5 fires the fire event")
	ui.marker_layer.set_playback_time(3.0)
	ui.poll_playback()
	eq(fired, ["note", "fire", "hit", "down"] as Array[String], "9. in time order, ties in World's order")
	eq(ui.roster.rows()[0]["health"], 1, "6. the hit event dropped p1's pips to the event's own number")
	check(bool(ui.roster.rows()[1]["down"]), "6. the down event shows p2 down")
	eq(ui.selection.can_select("p2"), false, "6. and it can no longer be selected")
	check(frames.size() >= 3 and is_equal_approx(frames[frames.size() - 1], 3.0), "9. playback_frame follows the clock (%s)" % str(frames))
	# The playback runs out: what the clock never reached fires, the frame reads the turn's length, the health is the unit's own.
	ui.marker_layer.playback_paused = false
	var guard := 0
	while ui.is_playing() and guard < 2000:
		ui.marker_layer.advance_playback(1.0 / 20.0)
		ui.poll_playback()
		guard += 1
	check(guard < 2000, "the playback ends")
	eq(fired, ["note", "fire", "hit", "down", "end"] as Array[String], "9. every event fired exactly once, the last as the playback ended")
	near(frames[frames.size() - 1], w.rules.turn_seconds, 1e-9, "9. the last frame reads the turn's length")
	eq(w.phase, World.PHASE_PLANNING, "the next turn began")
	eq(w.units["p1"].health, 1, "6. after the playback Unit.health is what shows")
	eq(ui.roster.rows()[0]["health"], 1, "6. (the row)")
	# 5. p2 went down while selected: let go when planning started.
	eq(ui.selection.unit_id, "", "5. a selected unit that went down is let go when planning starts")
	check(bool(ui.roster.rows()[1]["down"]), "5. and its row is down")

# --- 11, 12. Ready after a remote edit, and GROUP BY ---------------------------------------------------------

func _group_world() -> UnitUI:
	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1520.0, "y": 2460.0, "heading": 0.0})
	w.add_unit({"id": "p3", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 1700.0, "y": 2700.0, "heading": 0.0})
	w.add_unit({"id": "ai1", "type": "bomber", "side": "axis", "controller": "ai", "x": 3500.0, "y": 1800.0, "heading": PI})
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, _xf, "local")
	AiDumb.new(w).attach()
	return ui

func _heads(r: Roster) -> Array:
	return r.headings().map(func(h: Dictionary) -> String: return "%s:%d" % [h["group"], h["count"]])

func _check_grouping() -> void:
	var ui := _group_world()
	var w := ui.world
	var r: Roster = ui.roster
	var st := ui.style
	# 11. Ready, and edits.
	w.commit("local")
	check(w.is_ready("local") and w.all_ready(), "11. the local player is Ready (and so is the AI)")
	w.plan_step("p2", 0, {"to": Vector2(1640.0, 2440.0)})   # another player's edit, applied through the World
	check(w.is_ready("local"), "11. a remote edit to a unit leaves the local player's Ready set")
	w.plan_step("p2", 1, {"to": Vector2(1780.0, 2440.0)})
	w.clear_plan("p2")
	check(w.is_ready("local"), "11. so do more of them, and a cleared plan")
	check(bool(ui.orders.buttons()["ready"]["on"]), "11. and the orders card still shows Ready pressed")
	ui.select("p1")
	ui.planner.place_point(Vector2(1600.0, 2400.0))
	check(not w.is_ready("local"), "11. the player's OWN edit takes the Ready back, as before")
	ui.planner.clear()
	ui.select("")

	# 12. The control and the modes.
	eq(r.group_by, "none", "12. the default grouping is none")
	eq(r.ordered_ids(), ["p1", "p2", "p3"] as Array[String], "12. the world's order")
	eq(r.headings().size(), 0, "12. with no headings")
	var flat_h := r.size.y
	check(not r.set_group_by("domain"), "12. a grouping the data does not offer is refused (domain, unit type and nest are not built)")
	eq(r.group_by, "none", "12. and nothing changed")
	var changed: Array[String] = []
	r.group_changed.connect(func(m: String) -> void: changed.append(m))
	var btn := r.group_button_rect()
	check(Rect2(Vector2.ZERO, r.size).encloses(btn), "12. the group-by button lies inside the roster header (%s)" % str(btn))
	check(btn.end.y <= r.list_top() and btn.position.y >= st.num("roster.header_px"), "12. between the header rule and the list")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = btn.get_center()
	r._gui_input(click)
	eq(r.group_by, "needs_orders", "12. a click on the button cycles to needs orders")
	eq(changed, ["needs_orders"] as Array[String], "12. group_changed says so")
	eq(r.group_label(), "needs orders", "12. and the button reads it")
	eq(_heads(r), ["needs_orders:3"], "12. everyone needs orders: one heading with its count")
	eq(r.headings()[0]["text"], "needs orders", "12. the heading's wording is data")
	near(r.row_rect(0).position.y, r.list_top() + st.num("roster.group.heading_px"), 1e-6, "12. the first row sits under its heading")
	near(r.size.y, flat_h + st.num("roster.group.heading_px"), 1e-6, "12. the card grows by the heading")
	ui.layout()
	check(ui.orders.position.y >= r.position.y + r.size.y, "12. the orders card is still under the roster")
	for i in r.ordered_ids().size():
		eq(r.row_at(r.row_rect(i).get_center()), i, "12. row %d is found by its own rect" % i)
	# A change by someone else, the pointer elsewhere: the rows move at once.
	w.plan_step("p2", 0, {"to": Vector2(1640.0, 2440.0)})
	eq(r.ordered_ids(), ["p1", "p3", "p2"] as Array[String], "12. p2 got a plan: it moves down to planned")
	eq(_heads(r), ["needs_orders:2", "planned:1"], "12. the headings count")
	eq(r.headings()[1]["text"], "planned", "12. second heading wording")
	var rr := r.rows()
	eq([rr[0]["group"], rr[2]["group"]], ["needs_orders", "planned"], "12. each row says which group it is under")
	# The pointer is over the roster: nothing moves; the row text is live.
	r.set_pointer_over(true)
	check(r.pointer_over(), "12. the roster knows the pointer is over it")
	w.plan_step("p1", 0, {"to": Vector2(1620.0, 2380.0)})
	eq(r.ordered_ids(), ["p1", "p3", "p2"] as Array[String], "12. HOVERED: p1 got a plan and its row did not move")
	eq(r.rows()[0]["status"], "plan", "12. though its own text is live: it says plan")
	eq(r.rows()[0]["group"], "needs_orders", "12. and its group is still the old one")
	eq(_heads(r), ["needs_orders:2", "planned:1"], "12. the counts are held too")
	r.set_pointer_over(false)
	eq(r.ordered_ids(), ["p3", "p1", "p2"] as Array[String], "12. the pointer left: the roster caught up")
	eq(_heads(r), ["needs_orders:1", "planned:2"], "12. (headings too)")
	# The selected unit's row keeps its group until another is selected.
	ui.select("p3")
	w.plan_step("p3", 0, {"to": Vector2(1900.0, 2700.0)})
	eq(r.ordered_ids(), ["p3", "p1", "p2"] as Array[String], "12. SELECTED: p3 got a plan and its row stayed")
	eq(r.rows()[0]["group"], "needs_orders", "12. under needs orders")
	eq(_heads(r), ["needs_orders:1", "planned:2"], "12. (the plane you are planning does not hop headings)")
	ui.select("p1")
	eq(r.ordered_ids(), ["p1", "p2", "p3"] as Array[String], "12. selecting another unit lets p3 catch up")
	eq(_heads(r), ["planned:3"], "12. one heading, planned")
	# Tab and clicks follow the order shown.
	w.clear_plan("p3")
	eq(r.ordered_ids(), ["p3", "p1", "p2"] as Array[String], "12. p3 cleared (not selected): back under needs orders")
	var tab := InputEventKey.new()
	tab.keycode = OS.find_keycode_from_string(st.text("keys.next_unit"))
	tab.pressed = true
	ui.select("p3")
	ui._key(tab)
	eq(ui.selection.unit_id, "p1", "12. Tab goes to the next row as SHOWN (p3's row is first)")
	click.position = r.row_rect(2).get_center()
	r._gui_input(click)
	eq(ui.selection.unit_id, "p2", "12. a click on the third row selects the third row's unit")
	# A mode change applies at once even with the pointer over the roster (the click is on the control).
	r.set_pointer_over(true)
	check(r.set_group_by("none"), "12. back to none")
	eq(r.ordered_ids(), ["p1", "p2", "p3"] as Array[String], "12. a mode change applies at once, hovered or not")
	eq(r.headings().size(), 0, "12. no headings")
	r.cycle_group()
	eq(r.group_by, "needs_orders", "12. cycle_group goes round the data's list")
	r.set_pointer_over(false)
	# New units are listed at once, hovered or not.
	r.set_pointer_over(true)
	w.add_unit({"id": "p4", "type": "bomber", "side": "allies", "controller": "player", "x": 1600.0, "y": 2900.0, "heading": 0.0})
	check(r.ordered_ids().has("p4"), "12. a unit added mid-game is listed at once, even while hovered")
	r.set_pointer_over(false)
	# Planning starting regroups at once, even with the pointer over the roster; the playback holds the layout.
	w.plan_step("p3", 0, {"to": Vector2(1900.0, 2700.0)})
	w.plan_step("p4", 0, {"to": Vector2(1700.0, 2900.0)})
	ui.select("")
	var before := r.ordered_ids()
	check(w.commit("local"), "12. everyone is ready")
	w.resolve()
	ui.marker_layer.stop_playback()
	r.set_pointer_over(true)
	w.units["p1"].down = true
	w.plan_changed.emit("p1")
	eq(r.ordered_ids(), before, "12. through the resolve the layout is held")
	w.begin_turn()
	eq(r.ordered_ids(), ["p2", "p3", "p4", "p1"] as Array[String], "12. planning started: regrouped at once although hovered, p1 (down) last")
	eq(_heads(r), ["needs_orders:3", "down:1"], "12. headings: needs orders and down (the planned group is empty: no heading)")
	eq(r.headings()[1]["text"], "down", "12. the down heading's wording")
	r.set_pointer_over(false)
	# A VIEW setting of this player: another UI on the same world has its own, and the World has none.
	var ui2 := UnitUI.new()
	add_child(ui2)
	ui2.setup(w, _xf, "other")
	eq(ui2.roster.group_by, "none", "12. another player's roster on the same world is not grouped")
	eq(r.group_by, "needs_orders", "12. and this one still is")
	check(not ("group_by" in w) and not ("group_by" in w.units["p1"]), "12. the World and its units know nothing of the grouping: nothing to send over the network")

# --- The frame-driven part ---------------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _w2 == null:
		return
	_frames += 1
	if _frames < 5:
		return
	match _stage:
		0:
			# The enemy plane is selected and has a plan; the engine has drawn frames.
			check(not _rec.calls.is_empty(), "7. the engine ran the planner's _draw headless (%d calls): the checks below are not vacuous" % _rec.calls.size())
			for c: Array in _rec.calls:
				check(c[1] != "ai1", "7. nothing is drawn for the enemy plane (%s)" % str(c))
			check(_rec.calls.any(func(c: Array) -> bool: return c[0] == "curve" and c[1] == "p1" and c[2] == true), "7. p1's plan is drawn, quiet, while the enemy plane is selected")
			check(_rec.calls.any(func(c: Array) -> bool: return c[0] == "curve" and c[1] == "p2" and c[2] == true), "7. and p2's, which has no plan: only its dashed flight")
			check(not _rec.calls.any(func(c: Array) -> bool: return c[0] == "ghosts" or c[0] == "fan" or c[0] == "clamps"), "7. no ghosts, fan or clamps for the enemy plane")
			_sel2.select("p1")
			_rec.calls.clear()
			_stage = 1
			_frames = 0
		1:
			check(_rec.calls.any(func(c: Array) -> bool: return c[0] == "curve" and c[1] == "p1" and c[2] == false), "7. the selected player unit's own curve is full strength")
			check(_rec.calls.any(func(c: Array) -> bool: return c[0] == "curve" and c[1] == "p2" and c[2] == true), "7. the other player unit's is quiet")
			check(_rec.calls.any(func(c: Array) -> bool: return c[0] == "ghosts" and c[1] == "p1"), "7. the selected unit's ghosts")
			check(_rec.calls.any(func(c: Array) -> bool: return c[0] == "fan" and c[1] == "p1"), "7. and its fan")
			for c: Array in _rec.calls:
				check(c[1] != "ai1", "7. still nothing for the enemy plane (%s)" % str(c))
			# Co-op: an edit that did not go through this UI redraws the roster, and updates the plan on the map.
			check(_roster_draws > 0, "3. the roster has drawn headless (%d times)" % _roster_draws)
			_draws_seen = _roster_draws
			_w2.plan_step("p2", 0, {"to": Vector2(1640.0, 2440.0)})
			check(_rec.path_world("p2").size() == 5 and bool(_rec.path_world("p2")[0][1]), "3. and p2's planned step is in the map's curve")
			eq(_ui2.roster.rows()[1]["status"], "plan", "3. the row reads plan")
			_rec.calls.clear()
			_stage = 2
			_frames = 0
		2:
			check(_rec.calls.any(func(c: Array) -> bool: return c[0] == "curve" and c[1] == "p2" and c[2] == true), "3. the redrawn map still shows p2's curve quietly")
			check(_roster_draws > _draws_seen, "3. a plan edit from elsewhere redrew the roster (%d -> %d draws)" % [_draws_seen, _roster_draws])
			# The enemy plane's controller is not a thing a host can change by selecting: select it again.
			_sel2.select("ai1")
			_rec.calls.clear()
			_stage = 3
			_frames = 0
		3:
			for c: Array in _rec.calls:
				check(c[1] != "ai1", "7. selecting the enemy plane again draws nothing for it (%s)" % str(c))
			finish()
