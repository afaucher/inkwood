extends RefCounted

# THE LINES OF FIRE IN COMBAT (builder LOF2, stage 2, 2026-10-12; decision line-of-fire, tank-accuracy; every number PROPOSED, in
# data/sim/line_of_fire.json). The glue between the combat resolver (scripts/sim/combat_resolver.gd) and the height grid, the line check and
# the odds. The resolver holds one of these only when the switch is on (data/sim/line_of_fire.json `enabled`, or a World given one by hand);
# with none, combat is exactly what it was.
#
#   var lines := CombatLines.new(grid)            # grid: a HeightGrid (HeightGrid.shared(seed, water)); its rules are used
#   lines.applies(weapon)                         # is this weapon's round a straight one with a spread in the data (bullets and cannon)?
#   lines.sync(units)                             # the static units' shapes (a battery's sandbags, the bridge's parapets) stamped as they stand
#   var a := lines.assess(shooter, sstate, pose, weapon, geo, target, tstate, key)
#       a.visible   false: no part of the target is in view and the gun HOLDS (the resolver skips the target)
#       a.odds      the chance of a hit this roll: the share of the round's spread on the visible parts x the cone's other factors
#       a.share, a.s   the target's visible share, and the spread in metres at that distance
#   var where := lines.landing(a, hit, roll_seed, j)   # where roll j of a hardpoint's tick went (the roll's own stream)
#
# WHAT THE OLD ODDS BECOME. base_hit_chance is replaced, for these weapons, by the share of the spread on the visible parts (each weapon's
# spread is calibrated so a still, fully exposed target at its typical range keeps the old base chance); the centre, range and crossing_rate
# factors of data/sim/combat.json still multiply it.
#
# HEIGHTS. A surface unit stands on the grid's stand height (the ground, the water, the bridge's deck); a plane is at its band's absolute
# height, which the sim already carries in `height_m`. A hardpoint's height is added to the base.

const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const LineOfFire = preload("res://scripts/sim/line_of_fire.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const Odds = preload("res://scripts/sim/line_of_fire_odds.gd")
const Combat = preload("res://scripts/sim/combat.gd")

var rules: Rules
var grid: Object
var lof: LineOfFire
# counters since creation (the tests and the proofs read them)
var assessed: int = 0
var held: int = 0

func _init(grid_v: Object, rules_v: Rules = null) -> void:
	grid = grid_v
	rules = rules_v if rules_v != null else grid_v.rules
	lof = LineOfFire.new(grid_v, rules)

# Does the weapon take the line-of-fire odds (it fires a straight round and has a spread in the data)?
func applies(weapon: Object) -> bool:
	return rules.has_spread(str(weapon.id))

# Stamp every static unit that stands, unstamp every one that is down, and take out the stamps of units this World does not have.
func sync(units: Dictionary) -> void:
	grid.sync_statics(units, true)

# Build the grid chunks round the units (and the reach of their guns), so the first shot of a battle does not pay for the map.
func prebuild(units: Dictionary, margin_m: float = 450.0) -> int:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for id: String in units:
		var u: Object = units[id]
		lo = Vector2(minf(lo.x, float(u.x)), minf(lo.y, float(u.y)))
		hi = Vector2(maxf(hi.x, float(u.x)), maxf(hi.y, float(u.y)))
	if lo.x == INF:
		return 0
	return grid.build_rect(Rect2(lo - Vector2(margin_m, margin_m), (hi - lo) + Vector2(margin_m, margin_m) * 2.0))

# The height a unit's body stands on at (x, y): a plane's band height, or the ground, water or deck plus the sim's own height (0 for the surface).
func base_z(unit: Object, x: float, y: float, height_m: float) -> float:
	if str(unit.def.domain) == "air":
		return height_m
	return float(grid.stand_z(x, y)) + height_m

# The target's boxes where it is.
func boxes_of(unit: Object, state: Dictionary) -> Array:
	var x := float(state["x"])
	var y := float(state["y"])
	return Shapes.world_boxes(unit.def, rules, x, y, float(state["heading"]), base_z(unit, x, y, float(state["height_m"])))

# The muzzle of a hardpoint in the world: the pose's x, y and z, with the ground the shooter stands on added for a surface unit.
func muzzle_of(shooter: Object, sstate: Dictionary, pose: Dictionary) -> PackedFloat64Array:
	var zoff := 0.0
	if str(shooter.def.domain) != "air":
		zoff = float(grid.stand_z(float(sstate["x"]), float(sstate["y"])))
	return PackedFloat64Array([float(pose["x"]), float(pose["y"]), float(pose["z"]) + zoff])

# The key the trees' rolls on a shot's lines are made from: the hardpoint's roll seed through the data's salt.
func key_of(roll_seed: int) -> int:
	return (roll_seed ^ rules.odds_roll_key_salt) & 0x3FFFFFFF

# One weapon against one target, from where its hardpoint is: see the header. `pose` is Combat.pose(...) of the hardpoint, `geo` the cone's
# answer for this target (Combat.evaluate_pose: its in_cone is true, its `factors` are the data's), `roll_seed` the hardpoint's seed for the tick.
func assess(shooter: Object, sstate: Dictionary, pose: Dictionary, weapon: Object, geo: Dictionary, target: Object, tstate: Dictionary, roll_seed: int) -> Dictionary:
	assessed += 1
	var spec: Dictionary = rules.spreads[str(weapon.id)]
	var m := muzzle_of(shooter, sstate, pose)
	var ex := lof.exposure_xyz(m[0], m[1], m[2], boxes_of(target, tstate), key_of(roll_seed), false, true)
	if not bool(ex["visible"]):
		held += 1
		return {"visible": false, "share": 0.0}
	var ev := Odds.assess(ex, m[0], m[1], m[2], float(spec["spread_mrad"]), rules.odds_aim)
	if not bool(ev["visible"]):
		held += 1
		return {"visible": false, "share": 0.0}
	var f := 1.0
	for v: Variant in (geo["factors"] as Dictionary).values():
		f *= float(v)
	return {"visible": true, "odds": clampf(float(ev["p"]) * f, 0.0, 1.0), "p_share": float(ev["p"]), "share": float(ex["share"]), "s": float(ev["s"]), "ev": ev}

# Where roll `j` of the hardpoint's tick went: the fields the resolver adds to the fire event. The stream is the roll's own (the hardpoint's roll
# seed through two mixes), never the combat dice.
func landing(a: Dictionary, hit: bool, roll_seed: int, j: int) -> Dictionary:
	var out := {"vis": float(a["share"]), "spread_m": float(a["s"])}
	var seed2 := Combat.mix32(Combat.mix32(roll_seed, rules.odds_landing_salt), j)
	out.merge(Odds.land(a["ev"], hit, seed2, lof, rules.odds_landing_attempts, rules.odds_miss_run_m))
	return out
