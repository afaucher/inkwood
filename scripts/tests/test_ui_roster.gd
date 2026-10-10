extends "res://scripts/test_support/test_case.gd"

# THE ROSTER AND THE MARKERS (Track U, exit criterion 6: "something on screen
# for every unit, and the roster sidebar for selecting a unit"). Headless: the
# interface is mounted through UnitUI exactly as Track A will mount it, on the
# demo's world (two player planes, one AI plane), and driven through its public
# methods and one synthesized click. Pixels are ui_shot.gd's business.
#
#   1. the UI's style data loads, and every role, number and key the UI code
#      reads exists (a missing one is an error, never a default)
#   2. the roster lists exactly the player-controlled units, with name, type,
#      speed, band, plan status and side
#   3. selection syncs both ways: a roster row (by method and by a click)
#      selects the unit's marker; a press on a marker selects its row
#   4. every unit has a marker, posed through the HOST's mapping: a new
#      mapping moves the markers with no pixels-per-metre of the UI's own
#   5. plan status follows the plan; the side mark is the side's accent

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const Roster = preload("res://scripts/ui/roster.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

const PPM := 3.8

func setup(_main) -> void:
	# 1. Style data.
	var st := UiStyle.new()
	if not check(st.ok(), "the UI style data loads: %s" % str(st.errors)):
		finish()
		return
	_check_style_keys(st)

	var w := World.new()
	w.add_player("local")
	eq(w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0}), "p1", "player plane 1")
	eq(w.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1520.0, "y": 2460.0, "heading": 0.0, "altitude_band": "low"}), "p2", "player plane 2")
	eq(w.add_unit({"id": "ai1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 1600.0, "y": 2380.0, "heading": PI}), "ai1", "AI plane")
	var origin := Vector2(1400.0, 2300.0)
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -origin * PPM)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")

	# 2. The rows.
	var rows: Array[Dictionary] = ui.roster.rows()
	eq(rows.size(), 2, "the roster lists the two player-controlled units, not the AI's")
	eq(rows.map(func(r: Dictionary) -> String: return r["id"]), ["p1", "p2"], "rows in the world's order")
	if rows.size() == 2:
		eq(rows[0]["name"], "P1", "a row's name")
		eq(rows[0]["type"], "Light fighter", "a row's type is the unit file's name")
		near(float(rows[0]["speed"]), 100.0, 1e-9, "a row's speed is the unit's (cruise at spawn)")
		eq(rows[0]["band"], "medium", "a row's band")
		eq(rows[1]["band"], "low", "the second row's band")
		eq(rows[0]["planned"], 0, "no steps planned yet")
		eq(rows[0]["steps"], 5, "a light fighter has 5 steps per turn")
		eq(rows[0]["side"], "allies", "a row's side")
		eq(rows[0]["selected"], false, "nothing selected at start")
	eq(Roster.display_name("light_fighter_2"), "Light fighter 2", "a long id reads as words")

	# 3. Selection, roster -> marker.
	ui.roster.select_row(1)
	eq(ui.selection.unit_id, "p2", "selecting row 2 selects p2")
	check(ui.marker_layer.marker("p2").selected, "p2's marker shows selected")
	check(not ui.marker_layer.marker("p1").selected, "p1's marker does not")
	check(bool(ui.roster.rows()[1]["selected"]), "the row shows selected")
	eq(ui.planner.unit_id(), "p2", "the planner follows the selection")
	# A real click on row 1, through the roster's own input handler.
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = ui.roster.row_rect(0).get_center()
	ui.roster._gui_input(click)
	eq(ui.selection.unit_id, "p1", "a click on row 1 selects p1")
	eq(ui.roster.selected_index(), 0, "the roster's selected index follows")
	# Selection, marker -> roster: a press on p2's marker on the map.
	var p2_screen: Vector2 = ui.marker_layer.marker("p2").position
	check(ui.map_press(p2_screen), "a press on p2's marker is used")
	eq(ui.selection.unit_id, "p2", "a press on a marker selects its unit")
	eq(ui.roster.selected_index(), 1, "and its roster row")
	eq(ui.marker_layer.unit_at(p2_screen + Vector2(200.0, 200.0)), "", "a press on empty paper hits no unit")
	check(ui._leader_target("p2").is_finite(), "the selected unit's leader line has a roster row to reach")

	# 4. A marker for every unit, posed through the host's mapping.
	eq(ui.marker_layer.markers.size(), 3, "a marker for every unit, the AI's included")
	for id: String in ["p1", "p2", "ai1"]:
		var u = w.units[id]
		var want := xf * Vector2(float(u.x), float(u.y))
		check(ui.marker_layer.marker(id).position.distance_to(want) < 1e-3, "%s sits where the host's mapping puts it" % id)
	near(ui.marker_layer.marker("p1").screen_ppm, PPM, 1e-4, "the marker's scale comes from the mapping")
	var xf2 := Transform2D(0.0, Vector2(PPM * 2.0, PPM * 2.0), 0.0, Vector2(37.0, -11.0))
	ui.set_mapping(xf2)
	ui.marker_layer.update_poses()
	var u1 = w.units["p1"]
	check(ui.marker_layer.marker("p1").position.distance_to(xf2 * Vector2(float(u1.x), float(u1.y))) < 1e-3,
		"a new host mapping moves the marker; the UI holds no scale of its own")
	near(ui.marker_layer.marker("p1").screen_ppm, PPM * 2.0, 1e-4, "and rescales it")
	# A live host object works the same as a transform.
	var host := _Host.new(xf)
	ui.set_mapping(host)
	ui.marker_layer.update_poses()
	check(ui.marker_layer.marker("p1").position.distance_to(xf * Vector2(float(u1.x), float(u1.y))) < 1e-3,
		"an object with world_to_screen / screen_to_world is a host mapping too")
	# The shadow sits away from the sun by the plane's drawn height.
	var m1 = ui.marker_layer.marker("p1")
	var off: Vector2 = st.plane_shadow_offset_m(w.band_height("medium")) * PPM
	check(off.length() > 1.0, "a plane at medium casts its shadow visibly apart (%.1f px)" % off.length())
	check(off.normalized().dot(st.shadow_dir()) > 0.999, "the shadow falls away from the sun")
	check(not UnitMarkerArt.can_bake() or m1.has_art(), "with a renderer, the marker has baked art")
	# The gap follows the plane's DRAWN size (Alex, 2026-10-09, variants/plane-shadow-gap):
	# true_scale x2 draws the plane twice as large and doubles its gap with it; and a
	# host at half the px per metre with true_scale x2 (the plane drawn the same size,
	# as the sandbox's own-scale rule does) keeps the gap unchanged.
	var lst = ui.marker_layer.style
	var k0: float = lst.num("marker.true_scale")
	var wp1 := Vector2(float(u1.x), float(u1.y))
	var h_med: float = w.band_height("medium")
	var gap1: Vector2 = ui.marker_layer.shadow_offset_px(wp1, h_med)
	lst.set_num("marker.true_scale", k0 * 2.0)
	var gap2: Vector2 = ui.marker_layer.shadow_offset_px(wp1, h_med)
	near(gap2.length(), gap1.length() * 2.0, 1e-3, "the shadow gap doubles with the plane's drawn size (true_scale x2)")
	ui.set_mapping(xf.scaled_local(Vector2(0.5, 0.5)))
	var gap_half: Vector2 = ui.marker_layer.shadow_offset_px(wp1, h_med)
	near(gap_half.length(), gap1.length(), 1e-3, "at half the map scale with the plane drawn the same size, the gap is the same")
	lst.set_num("marker.true_scale", k0)
	ui.set_mapping(host)

	# 5. Plan status and side marks.
	ui.select("p1")
	ui.planner.place_point(Vector2(1600.0, 2400.0))
	eq(ui.roster.rows()[0]["planned"], 1, "a planned step shows on the roster")
	eq(m1.accent, st.side_color("allies"), "p1's mark is the allies' accent")
	eq(ui.marker_layer.marker("ai1").accent, st.side_color("axis"), "the AI's mark is the axis accent")
	check(st.side_color("allies") != st.side_color("axis"), "the two sides' marks differ")
	finish()

# Every role, number and key the UI's code reads, read once: a typo in the data
# or the code fails here, not in a frame nobody looks at.
func _check_style_keys(st: UiStyle) -> void:
	var roles := ["map_paper", "card_fill", "card_shadow", "ink", "ink_soft", "ink_faint", "row_selected",
		"button_fill", "button_on_fill", "button_on_text", "button_off_text", "pip_empty", "fan_fill", "fan_line",
		"fan_rib", "path", "path_carry", "clamp", "ring", "leader", "trail", "trail_ahead", "unit_shadow",
		"art_fill", "art_fill_shaded", "art_glass_lit", "art_glass_shaded", "art_ink"]
	for r: String in roles:
		check(st.has_role(r), "ui.json has role '%s'" % r)
	var nums := ["unit_art.stipple", "unit_art.bake_margin_px", "unit_art.rebake_ratio", "unit_art.min_bake_ppm",
		"unit_art.max_bake_ppm", "unit_art.variant.light_fighter", "unit_art.variant.heavy_fighter", "unit_art.variant.bomber",
		"fonts.title_px", "fonts.name_px", "fonts.detail_px", "fonts.button_px", "fonts.small_px",
		"card.lift_px", "card.outer_line_px", "card.inner_line_px", "card.inner_inset_px", "card.wobble_px", "card.pad_px",
		"card.gap_px", "card.margin_px", "roster.width_px", "roster.header_px", "roster.row_px", "roster.mark_r_px",
		"roster.pip_r_px", "roster.pip_gap_px", "roster.bracket_px", "orders.height_px", "orders.button_h_px",
		"orders.ready_h_px", "orders.row_gap_px", "marker.true_scale", "marker.ring_pad_px", "marker.ring_min_px",
		"marker.ring_tick_px", "marker.ring_gap_px", "marker.ring_line_px", "marker.hit_min_px", "marker.badge_r_px",
		"marker.badge_offset_px", "marker.leader_line_px", "marker.playback_speed", "marker.trail_dt_s",
		"planner.capture_px", "planner.handle_px", "planner.fan_line_px", "planner.rib_line_px", "planner.path_line_px",
		"planner.carry_line_px", "planner.dash_px", "planner.gap_px", "planner.step_dot_px", "planner.ghost_alpha",
		"planner.carry_ghost_alpha", "planner.samples_per_step", "planner.others_alpha", "shot.placeholder_px_per_m"]
	for n: String in nums:
		var v: Variant = st.lookup(n)
		check(v is float or v is int, "ui.json has a number at '%s'" % n)
	for t: String in ["roster.speed_unit", "keys.undo", "keys.clear", "keys.ready", "keys.climb", "keys.dive", "keys.next_unit"]:
		check(st.lookup(t) is String, "ui.json has a string at '%s'" % t)
	check(st.lookup("marker.leader_to_roster") is bool, "ui.json has marker.leader_to_roster")
	check(st.lookup("fonts.serif") is Array, "ui.json has a font list")
	for side: String in ["allies", "axis"]:
		var key: Variant = st.lookup("sides.accent." + side)
		check(key is String and st.palette.has(key), "side '%s' maps to a palette accent" % side)
	for p: String in ["sun_direction", "sun_elevation", "shadow_strength", "line_weight", "hand_wobble", "aircraft_shadow_altitude_scale"]:
		check(st.params.get(p) is float or st.params.get(p) is int, "render_defaults.json gives the UI '%s'" % p)
	near(st.color("unit_shadow").a, float(st.params["shadow_strength"]), 1e-6, "unit shadows are at the map's shadow strength")
	eq(st.errors.size(), 0, "no style lookups failed: %s" % str(st.errors))

# A stand-in for Track V's MapView: world_to_screen / screen_to_world.
class _Host:
	var xf: Transform2D
	func _init(t: Transform2D) -> void:
		xf = t
	func world_to_screen(p: Vector2) -> Vector2:
		return xf * p
	func screen_to_world(p: Vector2) -> Vector2:
		return xf.affine_inverse() * p
