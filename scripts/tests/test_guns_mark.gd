extends "res://scripts/test_support/test_case.gd"

# THE MAIN GUNS' FIRE MARK (board guns-mark, backlog D8; builder BP, 2026-10-14). Alex (decision no-ink-marks): "The main guns fire mark is not,
# we need a better option." One data switch, data/ui/ui.json guns.marks.mode (G0 .. G4), read by the planner (scripts/ui/gun_marks.gd). Here:
#
#   1. the data: five modes, G0 the default (today's marks), each other mode's numbers and the roles it draws with
#   2. G0 draws today's marks and none of the new ones
#   3. every other mode DRAWS to its end, for a unit target on land and for a point on the water (spray, not dust)
#   4. the default is back on G0 at the end

const World = preload("res://scripts/sim/world.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const MotionPlanner = preload("res://scripts/ui/motion_planner.gd")
const GunMarks = preload("res://scripts/ui/gun_marks.gd")
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
	_ui = UnitUI.new()
	add_child(_ui)
	_ui.setup(_w, Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM), "local")
	_ui.auto_resolve = false
	_pl = _ui.planner
	_ui.select("cruiser")
	_pl.place_point(Vector2(700.0, 2500.0))
	_ui.set_target_unit("aa")
	_pl.set_focus_step(0)
	check(not _pl.toggle_drop().is_empty(), "the Main Guns fire is planned on a unit on the land: %s" % _w.last_error)
	eq(await _modes(st, "land"), true, "2/3. the unit target part ran to its end")
	# A point on the water that the tower sees (the sea is x < 1700 here): spray, not dust.
	_pl.set_focus_step(0)
	_pl.toggle_drop()
	_ui.target.set_point(Vector2(1600.0, 2500.0))
	check(not _pl.toggle_drop().is_empty(), "the fire is planned on a point on the water: %s" % _w.last_error)
	check(_w.water_depth_at(1600.0, 2500.0) > 0.0, "(that point is water)")
	eq(await _modes(st, "water"), true, "3. the water target part ran to its end")
	eq(GunMarks.mode_of(st), "G0", "4. the default is G0 again")
	finish()

func _num(st: UiStyle, path: String) -> bool:
	var v: Variant = st.lookup(path)
	return v is float or v is int

func _data(st: UiStyle) -> bool:
	eq(st.text("guns.marks.mode"), "G0", "1. the default is G0 (today's marks)")
	var modes: Variant = st.lookup("guns.marks.modes")
	check(modes is Array and (modes as Array) == GunMarks.MODES, "1. five modes are listed, the code's own")
	for m: String in ["G1", "G2", "G3", "G4"]:
		check(st.lookup("guns.marks." + m) is Dictionary, "1. %s has a record" % m)
	for k: String in ["line_px", "halo_px", "line_alpha", "rim_px", "direct_r_px"]:
		check(_num(st, "guns.marks.G1." + k), "1. G1 has a number at '%s'" % k)
	for k: String in ["from_px", "to_px", "from_alpha", "to_alpha", "halo_px", "bulge", "enter", "rim_px", "direct_r_px"]:
		check(_num(st, "guns.marks.G2." + k), "1. G2 has a number at '%s'" % k)
	for k: String in ["count", "spread_k", "puff_r_m", "puff_min_px", "alpha_k", "outline_k", "outline_px", "direct_r_px", "lobe_amp"]:
		check(_num(st, "guns.marks.G3." + k), "1. G3 has a number at '%s'" % k)
	for k: String in ["from_px", "to_px", "count", "spread_k", "puff_r_m", "rim_px", "direct_r_px", "alpha_k", "outline_k", "outline_px", "lobe_amp"]:
		check(_num(st, "guns.marks.G4." + k), "1. G4 has a number at '%s'" % k)
	for r: String in ["fan_wash", "fan_rim", "path_halo", "gun_puff_dust", "gun_puff_water", "gun_puff_rim"]:
		check(st.has_role(r), "1. the role %s exists" % r)
	eq(st.errors.size(), 0, "1. no style lookups failed: %s" % str(st.errors))
	return true

func _modes(st: UiStyle, label: String) -> bool:
	for m: String in GunMarks.MODES:
		st.ui["guns"]["marks"]["mode"] = m
		var before := _pl.fire_mark_draws
		var curves := _pl.curve_draws
		_pl.queue_redraw()
		await get_tree().process_frame
		await get_tree().process_frame
		check(_pl.curve_draws > curves, "%s %s: the planner drew" % [label, m])
		if m == "G0":
			eq(_pl.fire_mark_draws, before, "%s G0: today's marks are drawn by the old path, none of the new ones" % label)
		else:
			check(_pl.fire_mark_draws > before, "%s %s: the mark drew to its end" % [label, m])
	st.ui["guns"]["marks"]["mode"] = "G0"
	eq(st.errors.size(), 0, "%s: no style lookups failed while drawing: %s" % [label, str(st.errors)])
	return true
