extends "res://scripts/test_support/test_case.gd"

# THE STAND-OUT SWITCH (Track U1, the first fight; variants/own-units-stand-out/).
# data/ui/ui.json marker.standout.mode picks how the players' own units stand out
# on busy ground; EVERY option is proposed and Alex chooses. Headless: the
# interface is mounted through UnitUI as test_ui_roster does, and driven through
# the style's data. Pixels are the board's business (scripts/ui/boards/
# standout_board_shot.gd); this holds the rules that keep the switch honest:
#
#   1. the shipped default is "none", and in it NOTHING is built or changed: no
#      shape nodes, no ring, every drawn-size multiplier 1.0, the hit radius and
#      the shadow gap exactly today's formulas -- the default draws exactly
#      today's marker
#   2. every mode in the data parses without an error, alone and joined with '+';
#      an unknown name is an error, once, and the rest still applies
#   3. the effects apply to the player-controlled units only, never the AI's
#   4. a mode that scales ("larger") scales the hit radius and the shadow gap with
#      the drawn size; switching back restores today's numbers
#   5. colours are palette roles: the halo and the lift are paper, the rim is ink

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitStandout = preload("res://scripts/ui/unit_standout.gd")

const PPM := 3.8

func setup(_main) -> void:
	var st: UiStyle = UiStyle.shared() as UiStyle
	if not check(st.ok(), "the UI style data loads: %s" % str(st.errors)):
		finish()
		return
	var saved_mode := st.text("marker.standout.mode")
	eq(saved_mode, "none", "the shipped default is 'none': today's marker")
	var modes: Array = UnitStandout.known_modes(st)
	for m: String in ["none", "halo", "lift", "rim", "ring", "larger"]:
		check(modes.has(m), "the data lists the mode '%s'" % m)

	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "p2", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 1520.0, "y": 2460.0, "heading": 0.3, "altitude_band": "low"})
	w.add_unit({"id": "ai1", "type": "bomber", "side": "axis", "controller": "ai", "x": 1600.0, "y": 2380.0, "heading": PI})
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -Vector2(1400.0, 2300.0) * PPM)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")
	var layer = ui.marker_layer
	var under: Node2D = layer._under
	var ids := ["p1", "p2", "ai1"]

	# 1. The default builds nothing and changes nothing.
	layer.update_poses()
	eq(under.get_child_count(), 0, "mode none: the under layer holds no shape")
	check(UnitStandout.is_none(layer._standout), "mode none parses to an empty spec")
	var k: float = st.num("marker.true_scale")
	for id: String in ids:
		var m = layer.marker(id)
		eq(m.draw_scale, 1.0, "mode none: %s is drawn at the rule's size" % id)
		check(m.ring.is_empty(), "mode none: %s has no ring" % id)
		eq(m._shapes.size(), 0, "mode none: %s has no shape" % id)
		var ext: float = m.art.extent_m if m.art != null else m.size_m * 0.5
		near(m.radius_px(), ext * m.screen_ppm * k, 1e-6, "mode none: %s's radius is today's formula" % id)
	var wp := Vector2(1500.0, 2400.0)
	var h: float = w.band_height("medium")
	var gap_today: Vector2 = layer.mapping.screen_delta(wp, st.plane_shadow_offset_m(h) * k)
	check(layer.shadow_offset_px(wp, h).is_equal_approx(gap_today), "mode none: the shadow gap is today's formula")
	check(layer.shadow_offset_px(wp, h, 1.0).is_equal_approx(gap_today), "a unit scale of 1 changes nothing")

	# 2. Every mode parses; so does a sum; an unknown name is an error, once.
	var errors_before := st.errors.size()
	for m: String in modes:
		var spec: Dictionary = UnitStandout.parse(st, m)
		eq(str(spec["mode"]), m, "mode '%s' parses" % m)
	for combo: String in ["halo+ring", "lift+rim+larger", "none+ring"]:
		var spec2: Dictionary = UnitStandout.parse(st, combo)
		eq(str(spec2["mode"]), combo, "the sum '%s' parses" % combo)
	eq(st.errors.size(), errors_before, "no mode or sum raised a data error")
	# (The error line this raises in the log is the point of the check: a private style, so the
	# shared one stays clean.)
	var private := UiStyle.new()
	var bad: Dictionary = UnitStandout.parse(private, "halo+bogus")
	eq((bad["shapes"] as Array).size(), 1, "an unknown name is skipped and the halo still applies")
	eq(private.errors.size(), 1, "the unknown name is reported as an error")
	UnitStandout.parse(private, "halo+bogus")
	eq(private.errors.size(), 1, "and only once")

	# 3. The effects reach the players' units only.
	_mode(st, layer, "halo+ring")
	eq(layer.marker("p1")._shapes.size(), 1, "halo+ring: the first player plane has its halo")
	eq(layer.marker("p2")._shapes.size(), 1, "halo+ring: the second too")
	eq(layer.marker("ai1")._shapes.size(), 0, "halo+ring: the AI's bomber has none")
	check(not layer.marker("p1").ring.is_empty() and not layer.marker("p2").ring.is_empty(), "halo+ring: the players' planes have the ring")
	check(layer.marker("ai1").ring.is_empty(), "halo+ring: the AI's has no ring")
	eq(under.get_child_count(), 2, "halo+ring: two shapes in the under layer, one per own plane")
	for id: String in ["p1", "p2"]:
		eq(layer.marker(id).draw_scale, 1.0, "halo+ring does not scale %s" % id)

	# 4. "larger" scales the hit radius and the shadow gap; going back restores them.
	_mode(st, layer, "larger")
	var s: float = st.num("marker.standout.larger.scale")
	check(s > 1.0, "the larger scale is above 1 (%s)" % str(s))
	near(layer.marker("p1").draw_scale, s, 1e-9, "larger: an own plane is drawn %s x" % str(s))
	eq(layer.marker("ai1").draw_scale, 1.0, "larger: the AI's plane keeps the rule's size")
	var m1 = layer.marker("p1")
	var ext1: float = m1.art.extent_m if m1.art != null else m1.size_m * 0.5
	near(m1.radius_px(), ext1 * m1.screen_ppm * k * s, 1e-6, "larger: the hit radius follows the drawn size")
	near(layer.shadow_offset_px(wp, h, s).length(), gap_today.length() * s, 1e-6, "larger: the shadow gap follows the drawn size")
	_mode(st, layer, "none")
	eq(layer.marker("p1").draw_scale, 1.0, "back to none: the drawn size is the rule's again")
	eq(under.get_child_count(), 0, "back to none: no shape is left (after the frame frees them)")
	check(layer.marker("p1").ring.is_empty(), "back to none: no ring")

	# 5. Colours are palette roles.
	var spec_h: Dictionary = UnitStandout.parse(st, "halo")
	var col_h: Color = (spec_h["shapes"] as Array)[0]["color"]
	check(Color(col_h.r, col_h.g, col_h.b).is_equal_approx(st.palette["paper"]), "the halo is the paper colour")
	check(col_h.a > 0.0 and col_h.a < 1.0, "at an alpha the data names")
	var spec_l: Dictionary = UnitStandout.parse(st, "lift")
	var col_l: Color = (spec_l["shapes"] as Array)[0]["color"]
	check(Color(col_l.r, col_l.g, col_l.b).is_equal_approx(st.palette["paper"]), "the lift is the paper colour")
	var spec_r: Dictionary = UnitStandout.parse(st, "rim")
	var col_r: Color = (spec_r["shapes"] as Array)[0]["color"]
	check(Color(col_r.r, col_r.g, col_r.b).is_equal_approx(st.palette["ink"]), "the rim is the ink colour")
	var spec_g: Dictionary = UnitStandout.parse(st, "ring")
	var rim_c: Color = (spec_g["ring"] as Dictionary)["rim_color"]
	check(Color(rim_c.r, rim_c.g, rim_c.b).is_equal_approx(st.palette["ink"]), "the ring's hairline is the ink colour")
	check(layer.marker("p1").accent.is_equal_approx(st.side_color("allies")), "the ring will take the unit's own side accent")
	eq(st.errors.size(), errors_before, "no style error at the end")

	st.ui["marker"]["standout"]["mode"] = saved_mode
	finish()

# Sets the data's mode the way a host does, and lets the layer read it.
func _mode(st: UiStyle, layer: Node, mode: String) -> void:
	st.ui["marker"]["standout"]["mode"] = mode
	layer.apply_standout(true)
	layer.update_poses()
	# queue_free'd shapes leave the tree at the end of the frame; take them out now.
	for c: Node in layer._under.get_children():
		if c.is_queued_for_deletion():
			layer._under.remove_child(c)
			c.free()
