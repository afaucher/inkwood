extends RefCounted

# HEIGHT AND SPEED LABELS (Track U3, 2026-10-10; Alex: height is hard to read from above, "make sure that every
# unit and every node has a height and speed label"). One place for what a label SAYS, when it shows and how it is
# inked, so the unit markers (unit_marker_layer.gd) and the plan's nodes (motion_planner.gd) cannot disagree.
# Every number and string is data/ui/ui.json labels (all PROPOSED; its _reason has the rules):
#
#   a unit (own or enemy, whenever it is in sight)   "400 m · 100"   height in metres, speed in m/s (unit left off);
#                                                    a STATIC unit (the radio tower, a battery) "0 m": its height
#                                                    above the ground, no speed
#   a planned step's node (the existing line)        "2 · 76 m/s · 400 m"   the step, the speed it ends at, the height
#   a carry-on step's node (it had none)             "76 m/s · 400 m"       fainter
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

# A unit's label. `static_unit`: no speed.
static func unit_text(st: RefCounted, height_m: float, speed_mps: float, static_unit: bool) -> String:
	if static_unit:
		return st.text("labels.unit_static") % roundi(height_m)
	return st.text("labels.unit") % [roundi(height_m), roundi(speed_mps)]

# What a planned step's "n · speed m/s" line gains.
static func node_suffix(st: RefCounted, height_m: float) -> String:
	return st.text("labels.node_suffix") % roundi(height_m)

# A carry-on step's whole label.
static func carry_text(st: RefCounted, speed_mps: float, height_m: float) -> String:
	return st.text("labels.node_carry") % [roundi(speed_mps), roundi(height_m)]

# The height to print for a pose ({height_m?, altitude_band, x, y}): the simulation's, or the ground's by data.
# `ground_fn`: a Callable (pose) -> height above the ground, or an invalid one (then the simulation's).
static func height_of(st: RefCounted, world: Object, pose: Dictionary, ground_fn: Callable = Callable()) -> float:
	var h := float(pose["height_m"]) if pose.has("height_m") else float(world.band_height(str(pose.get("altitude_band", ""))))
	if st.text("labels.height_ref") == "ground" and ground_fn.is_valid():
		return maxf(float(ground_fn.call({"x": pose.get("x", 0.0), "y": pose.get("y", 0.0), "height_m": h, "altitude_band": pose.get("altitude_band", "")})), 0.0)
	return h

# Lettering with the paper under-stroke the hover uses: `pos` is the baseline start; centred over `width` when given.
static func draw(ci: CanvasItem, st: RefCounted, font: Font, pos: Vector2, s: String, px: float, ink: Color, width: float = -1.0,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> void:
	var size := int(round(px))
	ci.draw_string_outline(font, pos, s, align as HorizontalAlignment, width, size, int(st.num("labels.halo_px")), st.color("label_halo"))
	ci.draw_string(font, pos, s, align as HorizontalAlignment, width, size, ink)
