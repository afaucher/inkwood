extends "res://scripts/test_support/test_case.gd"

# LINES AND LETTERING (Track C, 2026-10-10; Alex's notes on the Strike playtest). Headless, on the real World, mounted through UnitUI
# as the game mounts it; the numbers behind the drawing (what a draw routine is handed) are checked, the pixels are
# scripts/ui/declutter_shot.gd's (tmp/declutter/).
#
#   1. THE DATA holds Alex's removals and the new defaults, with his words as the reasons: no leader line to the roster, no
#      whole-flight track line, no clamp mark (the little X), no side badge (the red/blue dot), no dashed overhead footprint; the
#      arcs start HIDDEN (decision side-view-views, 2026-10-11: they were shown until then); no key for the
#      arcs; the lettering is larger, upright, semibold, full ink with a firm halo
#   2. THE LEADER LINE is off by default and comes back by data
#   3. THE CLAMP MARK (the dashed line to a little X): a clamped step has none while the data says off -- clamp_marks() is what
#      _draw_clamps draws from, so the off state draws nothing -- and has one when the data says on
#   4. THE TRACK LINE is off by default, still RECORDED, and comes back by data
#   5. THE OVERHEAD FOOTPRINT: a cone with no slice at the plane's level (the dorsal turret) is not drawn by default; the data
#      brings it back; the side view's records are never dropped
#   6. THE ARCS BUTTON (the side view panel's, in its heading row: the roster header's own was removed, Alex 2026-10-11 "Yes, remove
#      the extra"; Alex: "Lets prioritize onscreen buttons. No keyboard mapping."): "Arcs: on" / "Arcs: off", a click shows every cone
#      on the map and a second hides them, it stays as set (another selection, another overlay), and there is NO key for it
#   7. THE LETTERING: the labels are drawn at the data's size in the data's face; the node lettering and the unit labels agree
#   8. THE SIDE BADGE (the red/blue roundel beside every unit and the thin line tying it to the plane; Alex 2026-10-11, the second
#      playtest: "The red/blue indicator dot for each unit (planes at least) with the dotted line. We can remove that. The tail
#      serves this purpose well." Then: "No badge on units. We can figure something else out of we need it."): off for every
#      unit by default, the selection ring unchanged, and the switch's other settings (non_air, all) work

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiLabels = preload("res://scripts/ui/ui_labels.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const SideView = preload("res://scripts/ui/side_view.gd")
const SandboxTracks = preload("res://scripts/app/sandbox_tracks.gd")
const UiSelection = preload("res://scripts/ui/ui_selection.gd")

const PPM := 0.7   # the planning zoom (0.35 of 2 px/m)

class FakePlayback extends RefCounted:
	func is_playing() -> bool:
		return false

var _st: UiStyle
var _w: World
var _ui: UnitUI
var _sentinel := false
var _sections: Array[String] = []

func setup(_main) -> void:
	_st = UiStyle.shared() as UiStyle
	ConeOverlay.reset_view_setting()
	_check_data()
	_w = World.new()
	_w.add_player("local")
	_w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": 1500.0, "y": 2800.0, "heading": 0.0})
	_w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	_w.add_unit({"id": "e1", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 3200.0, "y": 2400.0, "heading": PI})
	if not check(_w.ok(), "the world loads: %s" % str(_w.errors)):
		finish()
		return
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -Vector2(1300.0, 2000.0) * PPM)
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, xf, "local")
	_ui.auto_resolve = false
	_check_leader()
	_check_clamps()
	_check_track_line()
	_check_overhead()
	await _check_arcs_button()
	await _check_badge()
	_check_lettering()
	_sentinel = true
	ConeOverlay.reset_view_setting()
	print("[test] sections run: %s" % ", ".join(_sections))
	eq(_sections.size(), 8, "all eight sections ran")
	check(_sentinel, "the test ran to its end (a runtime error would have ended it early, leaving every assertion above unrun)")
	finish()

func _flip(path: String, value: Variant) -> Variant:
	var parts := path.split(".")
	var cur: Dictionary = _st.ui
	for i in parts.size() - 1:
		cur = cur[parts[i]]
	var old: Variant = cur[parts[parts.size() - 1]]
	cur[parts[parts.size() - 1]] = value
	return old

# --- 1 -------------------------------------------------------------------------

func _check_data() -> void:
	_sections.append("data")
	check(_st.ok(), "the UI style data loads: %s" % str(_st.errors))
	eq(_st.flag("marker.leader_to_roster"), false, "1. no leader line to the roster by default")
	eq(_st.flag("marker.trails.whole_flight_line"), false, "1. no whole-flight track line by default")
	eq(_st.flag("planner.clamp_marks"), false, "1. no clamp mark (the dashed line to a little X) by default")
	eq(_st.text("marker.side_badge.drawn_for"), "none", "1. no side badge (the red/blue dot and its line) on any unit by default (Alex)")
	eq(_st.lookup("marker.side_badge.modes"), ["none", "non_air", "all"], "1. the side badge's scope has three settings")
	eq(_st.flag("planner.cones.overhead_footprint"), false, "1. no dashed overhead footprint by default")
	eq(_st.flag("planner.cones.shown"), false, "1. the weapon arcs start hidden (decision side-view-views: the side view's strips show them)")
	# Alex's words are kept beside the switches he asked for.
	check(_st.text("marker._leader_to_roster").contains("thin black line"), "1. the leader line's reason quotes Alex")
	check(_st.text("marker.trails._whole_flight_line").contains("extremely thin red/blue line"), "1. the track line's reason quotes Alex")
	check(_st.text("planner._clamp_marks").contains("The little X is where I left the mouse"), "1. the clamp mark's reason quotes Alex")
	check(_st.text("marker._side_badge").contains("The tail serves this purpose well") and _st.text("marker._side_badge").contains("PROPOSED"), "1. the side badge's reason quotes Alex and says what is proposed")
	check(_st.text("planner.cones._shown").contains("No keyboard mapping"), "1. the arcs button's reason quotes Alex")
	# No key for the arcs: not in the keys block.
	var keys: Dictionary = _st.lookup("keys")
	for k: String in keys:
		check(not (k.contains("arc") or k.contains("cone") or str(keys[k]) == "C"), "1. keys.%s is not a key for the arcs" % k)
	# The lettering.
	check(UiLabels.px(_st) >= 13.0 and UiLabels.px(_st) >= _st.num("fonts.small_px"), "1. the labels are at least as large as the card's small print (%s px; Track L: it is 14 now, not the 11 it was)" % str(UiLabels.px(_st)))
	var f := _st.label_font() as SystemFont
	if check(f != null, "1. the label face is a system font"):
		eq(f.font_italic, false, "1. an upright face, not the thin italic")
		check(f.font_weight >= 500, "1. a regular-to-semibold weight (%d)" % f.font_weight)
	eq(_st.color("label_ink").a, 1.0, "1. full ink")
	check(_st.color("label_halo").a >= 0.95, "1. a firm paper halo (alpha %s)" % str(_st.color("label_halo").a))
	check(_st.num("labels.halo_px") >= 4.0, "1. and a wide one")
	check(_st.color("label_carry").a >= 0.7, "1. a carry-on node's lettering is quieter but readable (alpha %s)" % str(_st.color("label_carry").a))
	eq(_st.errors.size(), 0, "1. no style lookups failed: %s" % str(_st.errors))

# --- 2 -------------------------------------------------------------------------

func _check_leader() -> void:
	_sections.append("leader")
	_ui.select("p1")
	var ml = _ui.marker_layer
	ml.update_poses()
	var m = ml.marker("p1")
	eq(ml.leader_points(m).size(), 0, "2. no leader line to the roster row is drawn by default")
	var old: Variant = _flip("marker.leader_to_roster", true)
	var line: PackedVector2Array = ml.leader_points(m)
	eq(line.size(), 2, "2. the data's switch brings it back: a line from the ring to the row")
	if line.size() == 2:
		check((line[0] as Vector2).distance_to(m.position) > ml.ring_radius(m), "2. it starts outside the ring")
	_flip("marker.leader_to_roster", old)
	eq(ml.leader_points(m).size(), 0, "2. and off again")

# --- 3 -------------------------------------------------------------------------

func _check_clamps() -> void:
	_sections.append("clamps")
	_ui.select("p1")
	var pl = _ui.planner
	pl.clear()
	var u = _w.units["p1"]
	var far := Vector2(float(u.x), float(u.y)) + Vector2(900.0, 120.0)   # past anything one step reaches
	var s: Dictionary = pl.place_point(far)
	check(not s.is_empty() and bool(s["clamped"]), "3. a step asked for far outside the envelope is clamped")
	eq(pl.clamp_marks("p1").size(), 0, "3. no clamp mark by default: the draw routine is handed nothing")
	var old: Variant = _flip("planner.clamp_marks", true)
	var marks: Array = pl.clamp_marks("p1")
	eq(marks.size(), 1, "3. with the data's switch on the clamped step has its mark")
	if marks.size() == 1:
		check((marks[0]["asked"] as Vector2).distance_to(marks[0]["put"] as Vector2) > 3.0, "3. from the point asked for to where the envelope put the step")
		eq(int(marks[0]["step"]), 0, "3. and it is step 1's")
	# An AI unit's plan is never marked, even with the switch on.
	eq(pl.clamp_marks("e1").size(), 0, "3. an enemy's plan is never marked")
	_flip("planner.clamp_marks", old)
	eq(pl.clamp_marks("p1").size(), 0, "3. off again: nothing")
	pl.clear()

# --- 4 -------------------------------------------------------------------------

func _check_track_line() -> void:
	_sections.append("track")
	var host := Node2D.new()
	add_child(host)
	var tracks := SandboxTracks.new()
	add_child(tracks)
	tracks.setup(_w, host, FakePlayback.new(), _st, 0.25, 1.6)
	var u = _w.units["p1"]
	_w.commit("local")
	_w.commit(World.AI_PLAYER)
	_w.resolve()
	_w.begin_turn()
	eq(tracks.line_shown(), false, "4. the whole-flight line is not drawn by default")
	check(tracks.point_count("p1") > 10 and tracks.length_m("p1") > 100.0, "4. but it is still recorded (%d points, %.0f m): the data's switch brings the whole flight back" % [tracks.point_count("p1"), tracks.length_m("p1")])
	var old: Variant = _flip("marker.trails.whole_flight_line", true)
	eq(tracks.line_shown(), true, "4. on by data")
	eq(tracks.drawn_points("p1"), tracks.point_count("p1"), "4. every recorded point is drawn then")
	_flip("marker.trails.whole_flight_line", old)
	eq(tracks.line_shown(), false, "4. off again")
	check(u != null, "4. (the unit flew)")
	tracks.queue_free()
	host.queue_free()

# --- 5 -------------------------------------------------------------------------

func _check_overhead() -> void:
	_sections.append("overhead")
	_ui.select("b1")
	_ui.set_arcs(true)   # (the map's arcs start off now: this section is about which cones the map draws once they are on)
	var cones: Array = _ui.cones.collect()
	var dorsal := 0
	var with_slice := 0
	for c: Dictionary in cones:
		if float(c["half"]) <= 0.0:
			dorsal += 1
		else:
			with_slice += 1
	eq(dorsal, 1, "5. the bomber's dorsal turret has no slice at its level (it covers what is above)")
	eq(with_slice, 2, "5. the nose gun and the tail turret do")
	var shown: Array = ConeOverlay.drawn_cones(cones, _st)
	eq(shown.size(), 2, "5. only the two with a slice are drawn: no dashed footprint, no hardpoint dot for the dorsal turret")
	for c: Dictionary in shown:
		check(float(c["half"]) > 0.0, "5. %s is drawn with a slice" % str((c["weapon"] as Object).id))
	var old: Variant = _flip("planner.cones.overhead_footprint", true)
	eq(ConeOverlay.drawn_cones(cones, _st).size(), 3, "5. the data's switch brings the dashed footprint back")
	_flip("planner.cones.overhead_footprint", old)
	# The side view's records are side-on: their `half` is an elevation and none is dropped.
	var side_on := [{"half": 0.0, "side_view": true}, {"half": 0.4, "side_view": true}]
	eq(ConeOverlay.drawn_cones(side_on, _st).size(), 2, "5. a side-on record is never dropped")
	ConeOverlay.reset_view_setting()   # (back to the data's starting state for the next section)

# --- 6 -------------------------------------------------------------------------

func _click(c: Control, at: Vector2) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = true
	ev.position = at
	c._gui_input(ev)

# The weapon-arcs button is the side view panel's (decision side-view-views; Alex: "Yes, remove the extra" -- the roster header's own is gone).
func _check_arcs_button() -> void:
	_sections.append("arcs")
	var ro: Roster = _ui.roster
	var pl = _ui.planner
	_ui.select("b1")
	var sv: Control = _ui.get_meta("side_view")
	sv.refresh()
	check(sv.is_active() and sv.has_arcs_button(), "6. the side view panel has the weapon-arcs button")
	eq(ro.has_method("arcs_button_rect") or ro.has_method("press_arcs"), false, "6. and the roster header has none")
	var g: Rect2 = ro.group_button_rect()
	check(g.position.y >= _st.num("roster.header_px") and g.end.y <= ro.list_top(), "6. the roster's bar holds its group-by button alone")
	eq(g.size.x, _st.num("roster.group.button_w_px"), "6. at its own width")
	var r: Rect2 = sv.arcs_button_rect()
	check(r.position.y >= 0.0 and r.end.y <= _st.num("side_view.section.gap_px") + _st.num("side_view.section.head_px") + 1e-6 and r.end.x <= sv.size.x + 1e-6, "6. in the panel's heading row, at the right")
	check(r.size.x >= 60.0 and r.size.y >= 16.0, "6. big enough to hit (%s)" % str(r.size))
	eq(sv.arcs_label(), "Arcs: off", "6. it reads 'Arcs: off' to start with")
	eq(_ui.arcs_shown(), false, "6. the arcs are hidden to start with")
	eq(_ui.cones.collect().size(), 0, "6. and the map draws no cones")
	eq(sv._get_tooltip(r.get_center()), _st.text("side_view.arcs.tooltip"), "6. it has a tooltip")
	eq(sv._get_tooltip(Vector2(5.0, 40.0)), "", "6. and only it")
	# A click on the roster's group-by button is not a click on it.
	_click(ro, g.get_center())
	eq(_ui.arcs_shown(), false, "6. the group-by button does not touch the arcs")
	ro.set_group_by("none")
	# The click.
	_click(sv, r.get_center())
	eq(_ui.arcs_shown(), true, "6. a click shows the arcs")
	eq(sv.arcs_label(), "Arcs: on", "6. and it reads 'Arcs: on'")
	check(_ui.cones.collect().size() > 0, "6. and the selected bomber's cones are on the map")
	await get_tree().process_frame
	await get_tree().process_frame
	check(_ui.cones._cones.size() > 0, "6. and the overlay has noticed: the cones are handed to the draw routines")
	# It stays as set: another selection, the next turn's planning, another overlay.
	_ui.select("p1")
	check(_ui.cones.collect().size() > 0, "6. it stays on when another unit is selected")
	var other := ConeOverlay.new()
	add_child(other)
	other.setup(_w, Transform2D.IDENTITY, UiSelection.new(), _st)
	eq(other.arcs_shown(), true, "6. and for another overlay of the same session")
	other.queue_free()
	# The second click.
	sv.refresh()
	_click(sv, sv.arcs_button_rect().get_center())
	eq(_ui.arcs_shown(), false, "6. a second click hides them again")
	eq(sv.arcs_label(), "Arcs: off", "6. 'Arcs: off'")
	eq(_ui.cones.collect().size(), 0, "6. every cone of the map is gone")
	# The calls the button stands for.
	_ui.set_arcs(true)
	eq(sv.arcs_label(), "Arcs: on", "6. UnitUI.set_arcs(true) is the same switch")
	_ui.toggle_arcs()
	eq(_ui.arcs_shown(), false, "6. and toggle_arcs()")
	# NO KEY (Alex: "No keyboard mapping"): C, or any key, does not touch it.
	for code: Key in [KEY_C, KEY_A, KEY_R, KEY_V]:
		var ev := InputEventKey.new()
		ev.keycode = code
		ev.pressed = true
		check(not _ui._key(ev), "6. %s is not taken by the interface" % OS.get_keycode_string(code))
	eq(_ui.arcs_shown(), false, "6. no key changed the arcs")
	# A panel on its own (no cone overlay behind it) has no such button, and pressing where it would be does nothing.
	var alone := SideView.new()
	add_child(alone)
	alone.setup(_w, pl, UiSelection.new(), _st)
	eq(alone.has_arcs_button(), false, "6. a panel with no overlay behind it has no arcs button")
	eq(alone.press_arcs(), false, "6. (and pressing it does nothing)")
	alone.queue_free()
	# The frames: both settings draw to their end.
	_ui.set_arcs(false)
	await get_tree().process_frame
	await get_tree().process_frame
	_ui.set_arcs(true)
	await get_tree().process_frame
	await get_tree().process_frame
	eq(_ui.cones.failed_draws, 0, "6. every sub-draw ran to its end, shown and hidden")
	eq(pl.unit_id(), "p1", "6. (the selection is where the test left it)")

# --- 7 -------------------------------------------------------------------------

func _check_lettering() -> void:
	_sections.append("lettering")
	var ml = _ui.marker_layer
	_ui.select("p1")
	var px := UiLabels.px(_st)
	check(UiLabels.font(_st) == _st.label_font(), "7. the lettering's face is the data's label face")
	near(UiLabels.line_h(_st), px + _st.num("labels.line_gap_px"), 1e-9, "7. one line height for every node's lines")
	check(UiLabels.line_h(_st) > px, "7. lines do not touch")
	# The node lettering and the unit label say what they said (the format is the data's, only the look changed).
	eq(ml.unit_label("p1"), "400 m · 100", "7. a unit's label is as it was")
	_ui.planner.clear()
	_w.plan_step("p1", 0, {"turn": 0.0, "speed": 100.0})
	eq(_ui.planner.step_labels("p1")[0], PackedStringArray(["100 m/s", "400 m"]), "7. and a node's: two lines, the speed over the height, no step number (Track L)")
	# A wider face for a wider label: the label's width follows the data's size.
	var w_big := UiLabels.font(_st).get_string_size("100 m/s", HORIZONTAL_ALIGNMENT_LEFT, -1, int(px)).x
	var w_old := UiLabels.font(_st).get_string_size("100 m/s", HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
	check(w_big > w_old, "7. at the data's size the lettering is wider than at the old 11 px (%.0f against %.0f px)" % [w_big, w_old])
	_ui.planner.clear()

# --- 8 -------------------------------------------------------------------------

func _check_badge() -> void:
	_sections.append("badge")
	var ml = _ui.marker_layer
	# A tank, a ship and a tower beside the three planes (the badge is per unit: its domain decides).
	_w.add_unit({"id": "t1", "type": "tank", "side": "allies", "controller": "player", "x": 1500.0, "y": 3300.0, "heading": 0.0})
	_w.add_unit({"id": "s1", "type": "patrol_boat", "side": "axis", "controller": "ai", "x": 3000.0, "y": 3300.0, "heading": 0.0})
	_w.add_unit({"id": "w1", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 3200.0, "y": 2800.0, "heading": 0.0})
	_ui.select("p1")
	ml.update_poses()
	var planes := ["b1", "p1", "e1"]
	var others := ["t1", "s1", "w1"]
	for id: String in planes + others:
		check(ml.marker(id) != null and ml.marker(id).visible, "8. %s is on the map" % id)
	# By default (none, Alex's): no badge on any unit, aircraft, tank, ship or static unit alike.
	for id: String in planes + others:
		eq(ml.side_badge_shown(ml.marker(id)), false, "8. %s: the layer says no badge" % id)
		eq(ml.side_badge(ml.marker(id)).size(), 0, "8. %s has no side badge by default: the draw routine is handed nothing, no roundel and no tie" % id)
	# The selection ring is not part of it: the selected unit still has its radius, ticks and ring.
	var m = ml.marker("p1")
	check(m.selected and ml.ring_radius(m) > m.radius_px(), "8. the selected unit keeps its ring (radius %.1f px)" % ml.ring_radius(m))
	check((ml.marker("t1").accent as Color).is_equal_approx(_st.side_color("allies")) and (ml.marker("e1").accent as Color).is_equal_approx(_st.side_color("axis")), "8. the roundel is the unit's side colour (red for the players, blue for the enemy)")
	await get_tree().process_frame
	await get_tree().process_frame
	# "non_air": no badge on an aircraft, the roundel and its tie on a tank, a ship and a static unit.
	var old: Variant = _flip("marker.side_badge.drawn_for", "non_air")
	for id: String in planes:
		eq(ml.side_badge(ml.marker(id)).size(), 0, "8. non_air: %s (aircraft) has no badge" % id)
	for id: String in others:
		eq(ml.side_badge_shown(ml.marker(id)), true, "8. non_air: %s (not aircraft) keeps its badge" % id)
		_check_badge_geometry(ml, id)
	# "all": the layer as it was, every unit has one.
	_flip("marker.side_badge.drawn_for", "all")
	for id: String in planes + others:
		_check_badge_geometry(ml, id)
	# An unrecognised setting draws it for all (the old look), it never hides one by mistake.
	_flip("marker.side_badge.drawn_for", "nonsense")
	_check_badge_geometry(ml, "p1")
	await get_tree().process_frame
	await get_tree().process_frame
	_flip("marker.side_badge.drawn_for", old)
	eq(ml.side_badge(m).size(), 0, "8. back to none: the plane has none again")
	eq(ml.side_badge(ml.marker("t1")).size(), 0, "8. and neither has the tank")
	await get_tree().process_frame
	await get_tree().process_frame

# A unit's badge as the draw routine is handed it: a roundel at the data's radius past the ring and a two-point tie starting at the unit.
func _check_badge_geometry(ml, id: String) -> void:
	var mk = ml.marker(id)
	var b: Dictionary = ml.side_badge(mk)
	eq(b.size(), 3, "8. %s: it has its roundel and tie" % id)
	if b.size() == 3:
		var tie: PackedVector2Array = b["tie"]
		eq(tie.size(), 2, "8. %s: a tie of two points" % id)
		near((b["centre"] as Vector2).distance_to(mk.position), ml.ring_radius(mk) + _st.num("marker.badge_offset_px"), 1e-3, "8. %s: the roundel sits past the ring" % id)
		eq(float(b["r"]), _st.num("marker.badge_r_px"), "8. %s: at the data's radius" % id)
		check(tie.size() == 2 and tie[0].distance_to(mk.position) < mk.radius_px() + 3.0, "8. %s: the tie starts at the unit" % id)
