extends RefCounted

# THE DIRECT KIND OF GUN SPECIAL, the geometry (builder ORD, 2026-10-14; data/sim/guns.json "tank_gun", scripts/sim/guns.gd "THE DIRECT KIND"). Pure
# functions shared by the planning side (World.gun_check) and the resolver (combat_resolver.gd): the weapon an order fires, and its odds at a given turret
# bearing -- the weapon's own cone, range and crossing factors (scripts/sim/combat.gd), so an ordered shot is the old roll with the same arithmetic.
#
# THE FRAME. The weapon's cone is built on the hull (mount_deg 0, half_across_deg 85: the tank's 170 degree forward arc), but an ordered shot leaves along
# the TURRET's bearing, which the turret has turned to the target. So the odds are asked in the turret's frame: the hardpoint's place from the hull, the
# axes from the bearing, and a copy of the weapon whose azimuth is all round (the arc was judged by the turret's limits: scripts/sim/turret.gd). What is left
# of the cone is its height (a level cone, a few degrees up and down: a tank never answers a plane) and the range factors.

const Combat = preload("res://scripts/sim/combat.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")

# The unit type's weapon with this id, or null.
static func weapon_of(def: Object, weapon_id: String) -> CombatWeapon:
	for w: CombatWeapon in def.weapons:
		if w.id == weapon_id:
			return w
	return null

# The index of that weapon in the type's weapon list (the roll seed folds it in), or -1.
static func weapon_index(def: Object, weapon_id: String) -> int:
	for i in def.weapons.size():
		if (def.weapons[i] as CombatWeapon).id == weapon_id:
			return i
	return -1

# A copy of the weapon whose cone takes any azimuth: only its height, its range and its crossing factors remain.
static func all_round(weapon: CombatWeapon) -> CombatWeapon:
	var v := weapon.values()
	v["mount_deg"] = 0.0
	v["half_across_deg"] = 180.0
	return CombatWeapon.new(v)

# The pose of the hardpoint for a hull state {x, y, heading, height_m, vx, vy, ...} and a turret pointing at `abs_bearing`: the place is the hull's,
# the axes the bearing's.
static func aimed_pose(hull: Dictionary, hardpoint: Vector3, abs_bearing: float) -> Dictionary:
	var p := Combat.pose(hull, hardpoint)
	var axes := Combat.pose({"x": 0.0, "y": 0.0, "heading": abs_bearing, "height_m": 0.0}, Vector3.ZERO)
	for k: String in ["fx", "fy", "fz", "rx", "ry", "ux", "uy", "uz"]:
		p[k] = axes[k]
	return p

# Combat.evaluate_pose of the aimed weapon (see all_round) from the turret's pose at `target` {x, y, height_m, vx?, vy?, vz?}.
static func evaluate(hull: Dictionary, weapon: CombatWeapon, aimed: CombatWeapon, abs_bearing: float, target: Dictionary, factors: Array, params: Dictionary) -> Dictionary:
	var p := aimed_pose(hull, weapon.hardpoints[0], abs_bearing)
	return Combat.evaluate_pose(p, aimed, target, factors, params)
