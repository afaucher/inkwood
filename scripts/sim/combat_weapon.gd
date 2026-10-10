extends RefCounted

# One weapon of a unit type, as unit_def.gd parses it from the type's
# "weapons" list (data/units/_schema.json says what each field means). A typed
# record: a unit's `def.weapons` is an Array of these, and combat.gd reads them.
#
# Angles are DEGREES in data and RADIANS at runtime; both are kept (mount_deg
# and mount, ...) so the interface can label a cone in degrees and draw it in
# radians without converting. Distances are metres. A hardpoint is a Vector3 of
# [forward, right, up] metres from the unit's centre, in the airframe's own
# axes (forward along the nose, right the right-hand wing, up above the wing).
# Vector3 is float32: plenty for an offset in metres, and exactly reproducible.
#
# Built from the plain values unit_def.gd validated, or by hand in a test:
#
#   var w := CombatWeapon.new({"id": "gun", "mount_deg": 0.0, ...})   # data form
#   w.values()                                                         # back to it
#
# Missing keys take harmless placeholders; unit_def.gd (not this class) is what
# rejects an incomplete file, so a hand-built weapon in a test is the caller's
# responsibility.

const KINDS: Array[String] = ["fixed", "flexible", "turret"]

var id: String = ""
var name: String = ""
var kind: String = ""
var hardpoints: Array[Vector3] = []
var mount_deg: float = 0.0           # cone centre relative to the nose: 0 forward, 180 rearward, + clockwise (right)
var half_across_deg: float = 1.0     # half the cone's width, in azimuth
var elevation_deg: float = 0.0       # cone centre above level
var half_height_deg: float = 1.0     # half the cone's height, in elevation
var range_m: float = 0.0
var base_hit_chance: float = 0.0     # odds per roll at the cone's centre, before any other factor
var rim_odds_factor: float = 1.0     # the centre factor at the cone's rim: 1 = flat, less = peaked
var falloff_exponent: float = 1.0    # shape of the fall from centre to rim
var damage_pips: int = 1
var rolls_per_second: float = 1.0
# Radians, derived from the degrees above.
var mount: float = 0.0
var half_across: float = 0.0
var elevation: float = 0.0
var half_height: float = 0.0

func _init(v: Dictionary = {}) -> void:
	id = str(v.get("id", ""))
	name = str(v.get("name", ""))
	kind = str(v.get("kind", ""))
	var pts: Variant = v.get("hardpoints", [])
	hardpoints = []
	if pts is Array:
		for p: Variant in pts:
			if p is Vector3:
				hardpoints.append(p)
			elif p is Array and (p as Array).size() == 3:
				hardpoints.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	mount_deg = float(v.get("mount_deg", mount_deg))
	half_across_deg = float(v.get("half_across_deg", half_across_deg))
	elevation_deg = float(v.get("elevation_deg", elevation_deg))
	half_height_deg = float(v.get("half_height_deg", half_height_deg))
	range_m = float(v.get("range_m", range_m))
	base_hit_chance = float(v.get("base_hit_chance", base_hit_chance))
	rim_odds_factor = float(v.get("rim_odds_factor", rim_odds_factor))
	falloff_exponent = float(v.get("falloff_exponent", falloff_exponent))
	damage_pips = int(v.get("damage_pips", damage_pips))
	rolls_per_second = float(v.get("rolls_per_second", rolls_per_second))
	mount = deg_to_rad(mount_deg)
	half_across = deg_to_rad(half_across_deg)
	elevation = deg_to_rad(elevation_deg)
	half_height = deg_to_rad(half_height_deg)

# The data form (degrees, hardpoints as Vector3s), for building a changed copy:
# CombatWeapon.new(w.values() with one key replaced).
func values() -> Dictionary:
	return {
		"id": id, "name": name, "kind": kind,
		"hardpoints": hardpoints.duplicate(),
		"mount_deg": mount_deg, "half_across_deg": half_across_deg,
		"elevation_deg": elevation_deg, "half_height_deg": half_height_deg,
		"range_m": range_m, "base_hit_chance": base_hit_chance,
		"rim_odds_factor": rim_odds_factor, "falloff_exponent": falloff_exponent,
		"damage_pips": damage_pips, "rolls_per_second": rolls_per_second,
	}
