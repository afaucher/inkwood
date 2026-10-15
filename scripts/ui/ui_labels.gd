extends RefCounted

const UiInk = preload("res://scripts/ui/ui_ink.gd")

# HEIGHT AND SPEED LABELS (Track U3, 2026-10-10; Alex: height is hard to read from above, "make sure that every
# unit and every node has a height and speed label"). One place for what a label SAYS, when it shows and how it is
# inked, so the unit markers (unit_marker_layer.gd) and the plan's nodes (motion_planner.gd) cannot disagree.
# Every number and string is data/ui/ui.json labels (all PROPOSED; its _reason has the rules; the size, the face and the ink are
# the readable-lettering values of Track C, 2026-10-10):
#
#   an AIRCRAFT (own or enemy, in sight)            "400 m · 100 m/s"   height in metres, speed in m/s (every number
#                                                    carries its unit: decision playtest-4)
#   a SHIP or a TANK                                 "12 m/s"            the speed alone, no altitude (decision labels-by-type)
#   a static unit that is not an aircraft            no label (labels.unit_static, PROPOSED "")
#   a step's node, planned or carry-on               "76 m/s" over "400 m"  the speed it ends at over the height, TWO LINES, no
#                                                    step number (Track L, 2026-10-10, Alex: "2 lines. Remove the step # as
#                                                    well"); a step with its special on adds the special's words ("Bomb Drop")
#                                                    as a line of its own; a carry-on node is the same, in the fainter ink
#   never anything about an ENEMY'S PLAN: its nodes are not drawn at all (MotionPlanner.plan_shown); an enemy's
#   current height and speed are visible state, as its position is
#
# WHAT HEIGHT MEANS (labels.height_ref, proposed "sim"): the height the simulation flies and bombs by, the altitude band's
# metres (between two bands during a band change), which is the number a bomb's fall time and spread are computed
# from; "ground" is the height above the terrain under the unit (what the shadow gap shows).
#
# WHEN THEY SHOW: labels.enabled, and the map's scale at the thing is at least labels.hide_below_px_per_m screen px per
# metre (the far zoom hides them: a line of lettering under every unit is noise when units are a few px apart).

# Whether labels show where the map's scale is `px_per_m` screen px per metre (the data's switch and the far-zoom rule).
static func shown(st: RefCounted, px_per_m: float) -> bool:
	if not st.flag("labels.enabled"):
		return false
	return px_per_m >= st.num("labels.hide_below_px_per_m")

# A unit's label by its kind (decisions labels-by-type and playtest-4: every number carries its unit; ships and tanks leave the altitude off).
#   an aircraft (`air`)           "400 m . 100 m/s"   height and speed
#   a ship or a tank              "12 m/s"            the speed alone; a unit UNDER the water (`under_water`) keeps its depth ("-12 m . 0 m/s")
#   a static unit that is not an aircraft   labels.unit_static (PROPOSED "" = no label)
# `static_unit`: no speed. `air` defaults true so a caller that does not say is the aircraft's, as before.
static func unit_text(st: RefCounted, height_m: float, speed_mps: float, static_unit: bool, air: bool = true, under_water: bool = false) -> String:
	var unit: String = st.text("roster.speed_unit")
	if air or under_water:
		if static_unit and not under_water:
			return _fmt1(st.text("labels.unit_static"), roundi(height_m))
		return st.text("labels.unit") % [roundi(height_m), roundi(speed_mps), unit]
	if static_unit:
		return _fmt1(st.text("labels.unit_static"), roundi(height_m))
	return st.text("labels.unit_surface") % [roundi(speed_mps), unit]

# A one-number format that may be empty ('' = no label).
static func _fmt1(fmt: String, n: int) -> String:
	if fmt == "":
		return ""
	return fmt % n

# A step node's two lines (Track L): the speed it ends at, and the height. The same for a planned step and a carry-on one.
static func node_speed_text(st: RefCounted, speed_mps: float) -> String:
	return st.text("labels.node_speed") % [roundi(speed_mps), st.text("roster.speed_unit")]

static func node_height_text(st: RefCounted, height_m: float) -> String:
	return st.text("labels.node_height") % roundi(height_m)

# The height to print for a pose ({height_m?, altitude_band, x, y}): the simulation's, or the ground's by data.
# `ground_fn`: a Callable (pose) -> height above the ground, or an invalid one (then the simulation's).
static func height_of(st: RefCounted, world: Object, pose: Dictionary, ground_fn: Callable = Callable()) -> float:
	var h := float(pose["height_m"]) if pose.has("height_m") else float(world.band_height(str(pose.get("altitude_band", ""))))
	if st.text("labels.height_ref") == "ground" and ground_fn.is_valid():
		return maxf(float(ground_fn.call({"x": pose.get("x", 0.0), "y": pose.get("y", 0.0), "height_m": h, "altitude_band": pose.get("altitude_band", "")})), 0.0)
	return h

# READABLE LETTERING (Track C, 2026-10-10; Alex: "The text next to each plane is unreadable using the small thin font - these MUST
# be read to be useful"): one size, one face and one line height for every label the map carries, from data (labels.px,
# labels.font.*, labels.line_gap_px). The planner's node lettering and the markers' labels both ask here.
static func px(st: RefCounted) -> float:
	return st.num("labels.px")

static func font(st: RefCounted) -> Font:
	return st.label_font()

# The distance between the baselines of two lines of one label.
static func line_h(st: RefCounted) -> float:
	return st.num("labels.px") + st.num("labels.line_gap_px")

# Lettering with the paper under-stroke the hover uses: `pos` is the baseline start; centred over `width` when given.
# The map's own words go through here (the halo is what makes them readable over the grove); UiInk.note records them.
static func draw(ci: CanvasItem, st: RefCounted, font: Font, pos: Vector2, s: String, px: float, ink: Color, width: float = -1.0,
		align: int = HORIZONTAL_ALIGNMENT_LEFT, kind: String = "") -> void:
	UiInk.note(ci, font, s, px, ink, true, kind, width)
	var size := int(round(px))
	ci.draw_string_outline(font, pos, s, align as HorizontalAlignment, width, size, int(st.num("labels.halo_px")), st.color("label_halo"))
	ci.draw_string(font, pos, s, align as HorizontalAlignment, width, size, ink)
