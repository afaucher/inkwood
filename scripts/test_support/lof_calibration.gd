extends RefCounted

# THE REFERENCE CASE OF A STRAIGHT ROUND (builder LOF2, stage 2 of the lines of fire, 2026-10-12; test support -- the gate does not run
# scripts/test_support). A still, fully exposed target of a weapon's reference type, at its reference range and elevation, seen from eight sides
# (every 45 degrees), on the open bay of Hold the bridge's map: the chance a round of a given angular spread has of hitting it. The calibration
# script (lof_calibrate.gd) solves for the spread that gives the old base_hit_chance; test_line_of_fire_combat holds the data to it.
#
#   var cal := LofCalibration.new()                    # false-y `ok` when line_of_fire.json does not load
#   var found := cal.find_weapon("turret_gun")         # {def, weapon}
#   cal.reference_p(found, spec, spread_mrad)          # spec: rules.spreads[weapon id], or a copy with another range_m
#   cal.solve(found, spec)                             # the spread (mrad) whose reference_p is spec.odds

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const HeightGrid = preload("res://scripts/sim/height_grid.gd")
const LineOfFire = preload("res://scripts/sim/line_of_fire.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const Odds = preload("res://scripts/sim/line_of_fire_odds.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const World = preload("res://scripts/sim/world.gd")

const BAY_SEED := 55
const BAY := Vector2(3700.0, 3560.0)     # open water in Hold the bridge's bay (test_line_of_fire uses it): flat, treeless
const ASPECTS := 8

var world: World
var rules: Rules
var grid: HeightGrid
var lof: LineOfFire
var _defs: Dictionary = {}     # weapon id -> {def, weapon}

func _init(rules_v: Rules = null) -> void:
	world = World.new()
	world.quiet = true
	rules = rules_v if rules_v != null else Rules.new()
	if not rules.ok():
		return
	var water := WaterGen.shared(BAY_SEED)
	grid = HeightGrid.shared(BAY_SEED, water)
	lof = LineOfFire.new(grid, rules)
	grid.build_rect(Rect2(BAY.x - 50.0, BAY.y - 450.0, 900.0, 900.0))

func ok() -> bool:
	return rules.ok() and grid != null and grid.ok()

# The unit type that has the weapon, and the weapon: {def, weapon}; {} when none has it.
func find_weapon(wid: String) -> Dictionary:
	if _defs.has(wid):
		return _defs[wid]
	var dir := DirAccess.open("res://data/units")
	for f in dir.get_files():
		if f.ends_with(".json") and not f.begins_with("_"):
			var def: Variant = world.unit_def(f.get_basename())
			if def == null:
				continue
			for w in def.weapons:
				if w.id == wid:
					_defs[wid] = {"def": def, "weapon": w}
					return _defs[wid]
	return {}

# The chance a round of this spread has on the reference target (the mean over the eight sides): a still target fully in view on the open bay.
func reference_p(found: Dictionary, spec: Dictionary, spread_mrad: float) -> float:
	var def: Variant = found["def"]
	var w: Variant = found["weapon"]
	var air: bool = str(def.domain) == "air"
	var base_shooter := 120.0 if air else 0.0
	var hp: Vector3 = w.hardpoints[0]
	var mz := base_shooter + hp.z
	var mx := BAY.x
	var my := BAY.y
	var d: float = spec["range_m"]
	var el := deg_to_rad(float(spec["elevation_deg"]))
	var tdef: Variant = world.unit_def(str(spec["target"]))
	var tx := mx + d * cos(el)
	var tz := mz + d * sin(el)
	var sum := 0.0
	for k in ASPECTS:
		var heading := TAU * float(k) / float(ASPECTS)
		var base := tz if str(tdef.domain) == "air" else 0.0
		var boxes := Shapes.world_boxes(tdef, rules, tx, my, heading, base)
		var ex := lof.exposure_xyz(mx, my, mz, boxes, 1, false, true)
		var ev := Odds.assess(ex, mx, my, mz, spread_mrad, rules.odds_aim)
		sum += float(ev["p"]) if bool(ev["visible"]) else 0.0
	return sum / float(ASPECTS)

# The spread (mrad) at which reference_p is the reference odds: bisection on a chance that falls as the spread grows.
func solve(found: Dictionary, spec: Dictionary) -> float:
	var target: float = spec["odds"]
	var lo := 0.2
	var hi := 400.0
	for _i in 60:
		var mid := 0.5 * (lo + hi)
		if reference_p(found, spec, mid) > target:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)
