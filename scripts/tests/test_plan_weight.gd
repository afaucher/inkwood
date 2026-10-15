extends "res://scripts/test_support/test_case.gd"

# THE WEIGHT OF THE PLAN INDICATORS (board plan-weight, backlog A8; builder BP, 2026-10-14). Alex (decision plan-indicators-bold): "We need to
# make the plan indicators on the map much bolder to be visible. There is too much visual noise to see a thin dashed lines and tiny dots."
# ONE data switch, data/ui/ui.json planner.weight.preset (P0 .. P4), is read by the planner (scripts/ui/plan_weight.gd). Here:
#
#   1. the data: five presets, P0 the default and EMPTY (today's look), the others much bolder, and the other units' plans a step quieter
#   2. PlanWeight reads them: P0 gives the plain planner numbers, a preset its own
#   3. every preset DRAWS, to the end, the selected unit's plan, another unit's, and the fan with the preset's rim
#   4. the default is unchanged: after the loop the switch is back on P0 and P0 draws the plain numbers

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const PlanWeight = preload("res://scripts/ui/plan_weight.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")

const PPM := 0.5
const ORIGIN := Vector2(400.0, 2100.0)

var _w: World
var _ui: UnitUI
var _pl: MotionPlanner

func setup(_main) -> void:
	timeout_seconds = 120.0
	var st: UiStyle = UiStyle.shared() as UiStyle
	eq(_data(st), true, "1. the data part ran to its end")
	_w = GunWorlds.world(3)
	_w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": 1500.0, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM), "local")
	_ui.auto_resolve = false
	_pl = _ui.planner
	eq(_reads(st), true, "2. the reading part ran to its end")
	eq(await _draws(st), true, "3. the drawing part ran to its end")
	eq(await _default_back(st), true, "4. the default part ran to its end")
	finish()

func _data(st: UiStyle) -> bool:
	var presets: Variant = st.lookup("planner.weight.presets")
	check(presets is Array and (presets as Array).size() == 5, "1. five presets are listed")
	eq(st.text("planner.weight.preset"), "P0", "1. the default is P0 (today's look)")
	var p0: Variant = st.lookup("planner.weight.P0")
	check(p0 is Dictionary and (p0 as Dictionary).is_empty(), "1. P0 names nothing")
	var plain_path := st.num("planner.path_line_px")
	var plain_dot := st.num("planner.step_dot_px")
	var plain_rim := st.num("planner.fan.wash_rim.rim_px")
	for n: String in ["P1", "P2", "P3", "P4"]:
		var d: Variant = st.lookup("planner.weight." + n)
		check(d is Dictionary, "1. %s is a record" % n)
		if not (d is Dictionary):
			continue
		var p: Dictionary = d
		for k: String in ["path_line_px", "carry_line_px", "dash_px", "gap_px", "step_dot_px", "others_line_px", "others_carry_line_px", "others_dot_px", "fan_rim_px"]:
			check(p.get(k) is float or p.get(k) is int, "1. %s has a number at '%s'" % [n, k])
		check(float(p.get("path_line_px", 0.0)) >= plain_path * 1.9, "1. %s: the selected path is at least about twice today's (%.1f of %.1f px)" % [n, float(p.get("path_line_px", 0.0)), plain_path])
		check(float(p.get("step_dot_px", 0.0)) >= plain_dot * 1.9, "1. %s: the nodes are at least about twice today's" % n)
		check(float(p.get("fan_rim_px", 0.0)) >= plain_rim * 1.9, "1. %s: the range of motion's rim scales with the path" % n)
		check(float(p.get("others_line_px", 9.0)) < float(p.get("path_line_px", 0.0)), "1. %s: the other units' plans are a step thinner" % n)
		check(float(p.get("others_dot_px", 9.0)) < float(p.get("step_dot_px", 0.0)), "1. %s: ... with smaller nodes" % n)
		if n != "P1":
			check(float(p.get("halo_px", 0.0)) > 0.0 and float(p.get("node_rim_px", 0.0)) > 0.0, "1. %s: a paper halo under the line and a rim round the nodes" % n)
	check(st.has_role("path_halo"), "1. the role path_halo exists")
	eq(st.errors.size(), 0, "1. no style lookups failed: %s" % str(st.errors))
	return true

func _reads(st: UiStyle) -> bool:
	var pw := PlanWeight.new(st)
	eq(pw.preset, "P0", "2. the switch reads P0")
	check(pw.is_today(), "2. P0 changes nothing")
	near(pw.num("path_line_px"), st.num("planner.path_line_px"), 1e-9, "2. P0 gives the plain path width")
	near(pw.num("others_dot_px"), st.num("planner.others_dot_px"), 1e-9, "2. ... and the plain others' dot")
	near(pw.num_or("halo_px", 0.0), 0.0, 1e-9, "2. ... and no halo")
	st.ui["planner"]["weight"]["preset"] = "P2"
	pw.refresh()
	eq(pw.preset, "P2", "2. the switch reads P2 after it is changed")
	near(pw.num("path_line_px"), 3.2, 1e-9, "2. P2 gives its own path width")
	check(pw.num_or("halo_px", 0.0) > 0.0, "2. ... and a halo")
	check(not pw.flag("carry_dashed", true), "2. ... a solid carry-on")
	st.ui["planner"]["weight"]["preset"] = "P0"
	return true

func _draws(st: UiStyle) -> bool:
	_ui.select("")
	_ui.select("cruiser")
	_pl.clear()
	_pl.place_point(Vector2(700.0, 2500.0))
	_pl.place_point(Vector2(800.0, 2520.0))
	_w.plan_step("bomber", 0, {"turn": 0.05, "speed": 85.0})
	check(_pl.plan_shown("bomber"), "3. the other unit's plan is shown")
	for n: String in st.lookup("planner.weight.presets"):
		st.ui["planner"]["weight"]["preset"] = n
		var before := _pl.curve_draws
		_pl.queue_redraw()
		await get_tree().process_frame
		await get_tree().process_frame
		check(_pl.curve_draws - before >= 2, "3. %s: the selected plan and the other unit's both drew to their end (%d curves)" % [n, _pl.curve_draws - before])
		eq(_pl._pw().preset, n, "3. %s: the planner reads it" % n)
	st.ui["planner"]["weight"]["preset"] = "P0"
	eq(st.errors.size(), 0, "3. no style lookups failed while drawing: %s" % str(st.errors))
	return true

func _default_back(st: UiStyle) -> bool:
	eq(st.text("planner.weight.preset"), "P0", "4. the default is P0 again")
	var before := _pl.curve_draws
	_pl.queue_redraw()
	await get_tree().process_frame
	await get_tree().process_frame
	check(_pl.curve_draws - before >= 2, "4. P0 still draws both plans")
	check(_pl._pw().is_today(), "4. and changes nothing")
	return true
