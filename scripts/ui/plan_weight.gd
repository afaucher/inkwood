extends RefCounted

# THE WEIGHT OF THE PLAN INDICATORS (board plan-weight, backlog A8; builder BP, 2026-10-14).
#
# Alex (decision plan-indicators-bold, 2026-10-13): "We need to make the plan indicators on the map much bolder to be visible. There is
# too much visual noise to see a thin dashed lines and tiny dots." DECIDED: much bolder; HOW MUCH is the board's question
# (variants/plan-weight/). ONE data switch, planner.weight.preset (P0 .. P4), picks a set of overrides; planner.weight.<preset> holds
# them. A key a preset does not name falls back to the plain planner.<key> number (which is today's), so P0 (an empty preset) is the
# game as it was. EVERY PRESET AND NUMBER IS PROPOSED by builder BP; nothing is chosen.
#
#   var pw := PlanWeight.new(style)
#   pw.num("path_line_px")          # the preset's number, else planner.path_line_px
#   pw.flag("carry_dashed")         # the preset's true/false, else the default given
#
# Keys (screen px): path_line_px, carry_line_px, dash_px, gap_px, step_dot_px (a node's radius), others_line_px, others_carry_line_px,
# others_dot_px, halo_px / carry_halo_px / others_halo_px (a paper halo each side of a line, 0: none), node_rim_px (a paper rim round a
# node, 0: none), fan_rim_px (the range of motion's rim; absent: planner.fan.wash_rim.rim_px); carry_dashed (the selected unit's
# carry-on path is dashed, else solid and fainter), others_carry_dashed.

const NAME_PATH := "planner.weight.preset"

var style: RefCounted = null
var preset: String = "P0"
var _over: Dictionary = {}

func _init(st: RefCounted) -> void:
	style = st
	refresh()

# Reads the switch again (a board changes the preset at run time and asks the planner to redraw).
func refresh() -> void:
	var v: Variant = style.lookup(NAME_PATH)
	preset = str(v) if v is String else "P0"
	var d: Variant = style.lookup("planner.weight.%s" % preset)
	_over = d if d is Dictionary else {}

func presets() -> Array:
	var v: Variant = style.lookup("planner.weight.presets")
	return v if v is Array else []

# The preset's number for `key`, else the plain planner.<key> (today's).
func num(key: String) -> float:
	var v: Variant = _over.get(key)
	if v is float or v is int:
		return float(v)
	return style.num("planner." + key)

# A number the plain data does not have: the preset's, else `dflt`.
func num_or(key: String, dflt: float) -> float:
	var v: Variant = _over.get(key)
	if v is float or v is int:
		return float(v)
	return dflt

func flag(key: String, dflt: bool) -> bool:
	var v: Variant = _over.get(key)
	return v if v is bool else dflt

# True when the preset changes nothing (P0): the planner then draws exactly as before.
func is_today() -> bool:
	return _over.is_empty()
