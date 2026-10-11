extends "res://scripts/test_support/test_case.gd"

# THE FAN'S LOOKS (builder BM, 2026-10-11; the range-of-motion board, variants/motion-range/; data/ui/ui.json planner.fan).
# The planner draws the region where the next step's node may be set in one of several looks (planner.fan.mode). ALEX CHOSE
# C, 'Wash and a thin inked rim' (decision motion-range-look, 2026-10-11), for every unit type: the default is 'wash_rim'.
# The other looks, 'ribs' (the look before the decision) among them, stay as switches and are PROPOSED, not chosen; the
# numbers inside C (wash 14%, rim 0.9 px at 50%) are PROPOSED too. Headless draws nothing, so this tests what a look is made of:
#
#   0. the default is the chosen look: planner.fan.mode is 'wash_rim', the block records the decision, the board records Alex's pick
#   1. the data is whole: the mode is one of `modes`, every mode has the block and the colour roles it names, and
#      every role is ink (no hue: the fan is ink at an alpha, working rule 6)
#   2. the original code draws 'ribs' (the old look, a switch): _draw_fan_mode answers false for 'ribs' and for a name it does not know
#   3. the fan's area (_fan_parts) is the outline for a real fan, and nothing for a fan with no area (a ship dead in the water)
#   4. the stipple's dots all lie INSIDE the fan, there are some, they are kept between calls and made again for another fan
#   5. the hatch's strokes all lie inside the fan (Geometry2D.clip_polyline_with_polygon is a DIFFERENCE: CLAUDE.md), run at
#      the angle asked and are spaced as asked

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const PPM := 3.8

func setup(_main) -> void:
	var style: UiStyle = UiStyle.shared() as UiStyle
	# 1. The data.
	var modes: Variant = style.lookup("planner.fan.modes")
	if not check(modes is Array, "planner.fan.modes is a list"):
		finish()
		return
	var mode := style.text("planner.fan.mode")
	check((modes as Array).has(mode), "planner.fan.mode ('%s') is one of the modes" % mode)
	eq(mode, "wash_rim", "the default look is Alex's pick, C (wash and a thin inked rim), for every unit type")
	eq(style.text("planner.fan.decision"), "motion-range-look", "planner.fan names the decision that set the look")
	check((modes as Array).has("ribs"), "the old look, ribs, is still one of the modes (a switch)")
	for m0: String in ["ribs", "shade", "wash_rim", "stipple", "hatch", "rim_ticks"]:
		check((modes as Array).has(m0), "the mode '%s' is kept as a switch" % m0)
	# The board records the pick (read from the file, not from a copy).
	var board_path := "res://variants/motion-range/board.json"
	if check(FileAccess.file_exists(board_path), "the motion-range board is on disk"):
		var board: Variant = JSON.parse_string(FileAccess.get_file_as_string(board_path))
		if check(board is Dictionary, "the motion-range board parses"):
			eq(str((board as Dictionary).get("chosen", "")), "C", "the board records Alex's pick, C")
			eq(str((board as Dictionary).get("chosen_by", "")), "Alex", "the board records who chose")
			eq(str((board as Dictionary).get("decision", "")), "motion-range-look", "the board names the decision")
	var ink: Color = style.palette["ink"]
	for m: String in modes:
		if m == "ribs":
			continue
		var block: Variant = style.lookup("planner.fan.%s" % m)
		if not check(block is Dictionary, "mode '%s' has its block planner.fan.%s" % [m, m]):
			continue
		for k: String in (block as Dictionary):
			if k.ends_with("_role"):
				var role := str((block as Dictionary)[k])
				if check(style.has_role(role), "%s.%s names a role that exists ('%s')" % [m, k, role]):
					var c := style.color(role)
					check(is_equal_approx(c.r, ink.r) and is_equal_approx(c.g, ink.g) and is_equal_approx(c.b, ink.b), "role '%s' is ink (no hue) at alpha %.2f" % [role, c.a])
					check(c.a > 0.0 and c.a < 1.0, "role '%s' is ink at an alpha between 0 and 1" % role)
	for key: String in ["planner.fan.stipple.cell_px", "planner.fan.stipple.dot_px", "planner.fan.stipple.max_cells", "planner.fan.hatch.spacing_px", "planner.fan.hatch.line_px", "planner.fan.hatch.angle_deg", "planner.fan.wash_rim.rim_px", "planner.fan.rim_ticks.tick_px"]:
		check(style.num(key) > 0.0, "%s is a positive number" % key)

	# 2-5. The planner's own fan for a light fighter with one step planned.
	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	var origin := Vector2(1400.0, 2200.0)
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -origin * PPM)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")
	var pl = ui.planner
	ui.select("p1")
	pl.place_point(Vector2(1600.0, 2420.0))
	var poly: PackedVector2Array = pl.fan_outline_screen()
	if not check(poly.size() >= 6, "the next step's fan is a polygon (%d points)" % poly.size()):
		finish()
		return
	check(not pl._draw_fan_mode(poly, "ribs"), "ribs (the old look, a switch) is drawn by the original code, not _draw_fan_mode")
	check(not pl._draw_fan_mode(poly, "no such look"), "a name _draw_fan_mode does not know is left to the original code")

	var parts: Array = pl._fan_parts(poly)
	check(parts.size() >= 1, "the fan has an area (%d part)" % parts.size())
	var flat := PackedVector2Array()
	for i in 18:
		flat.append(Vector2(100.0, 100.0))
	check((pl._fan_parts(flat) as Array).is_empty(), "a fan of one repeated point has no parts")
	var line := PackedVector2Array()   # a ship dead in the water: every sampled turn ends in the same two places
	for i in 9:
		line.append(Vector2(100.0, 100.0))
	for i in 9:
		line.append(Vector2(130.0, 100.0))
	check((pl._fan_parts(line) as Array).is_empty(), "a fan with no area (a ship dead in the water) has no parts")

	var cell := 3.6
	var dots: PackedVector2Array = pl._fan_dots(poly, parts, cell, 30000)
	check(dots.size() >= 20, "the stipple has dots (%d)" % dots.size())
	var outside := 0
	for p: Vector2 in dots:
		if not Geometry2D.is_point_in_polygon(p, poly):
			outside += 1
	eq(outside, 0, "every stipple dot lies inside the fan")
	check(pl._fan_dots(poly, parts, cell, 30000) == dots, "the stipple is kept for the same fan")
	var moved := PackedVector2Array()
	for p: Vector2 in poly:
		moved.append(p + Vector2(60.0, 0.0))
	var dots2: PackedVector2Array = pl._fan_dots(moved, pl._fan_parts(moved), cell, 30000)
	check(dots2 != dots and dots2.size() >= 20, "another fan has its own dots")
	var spread := 0.0
	for p: Vector2 in dots:
		spread = maxf(spread, p.distance_to(dots[0]))
	check(spread > 15.0, "the dots spread over the fan (%.1f px)" % spread)
	check((pl._fan_dots(poly, parts, cell, 4) as PackedVector2Array).is_empty(), "a fan too big for max_cells gets no dots instead of a long wait")

	var spacing := 4.0
	var angle := PI / 4.0
	var segs: PackedVector2Array = pl._fan_hatch(poly, parts, spacing, angle)
	check(segs.size() >= 4 and segs.size() % 2 == 0, "the hatch has strokes in pairs of points (%d points)" % segs.size())
	var t := Vector2.from_angle(angle)
	var nrm := Vector2(-t.y, t.x)
	var bad_in := 0
	var bad_angle := 0
	var offsets: Array[float] = []
	for i in range(0, segs.size() - 1, 2):
		var a := segs[i]
		var b := segs[i + 1]
		if not Geometry2D.is_point_in_polygon((a + b) * 0.5, poly):
			bad_in += 1
		if a.distance_to(b) > 0.01 and absf((b - a).normalized().dot(nrm)) > 0.001:
			bad_angle += 1
		offsets.append(snappedf(a.dot(nrm), 0.01))
	eq(bad_in, 0, "every hatch stroke lies inside the fan (its middle does)")
	eq(bad_angle, 0, "every hatch stroke runs at the angle asked")
	var on_grid := 0
	for o: float in offsets:
		if absf(o / spacing - roundf(o / spacing)) < 0.01:
			on_grid += 1
	check(offsets.size() >= 2, "the hatch checks above ran over its strokes (%d)" % offsets.size())   # (a sentinel: the last thing this test reaches)
	eq(on_grid, offsets.size(), "the strokes sit on a grid %.1f px apart anchored to the screen" % spacing)
	finish()
