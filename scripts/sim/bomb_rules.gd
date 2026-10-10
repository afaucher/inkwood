extends RefCounted

# The bombing model's constants, read from data/sim/bombs.json (Track S2, proposed
# 2026-10-10; every value there carries its reason). Same rules as the other sim
# data (records.gd): a missing field is an error, never a default; a tunable
# without a provenance is an error. The model itself is documented at the top of
# scripts/sim/bombs.gd.
#
#   var rules := BombRules.new()
#   if not rules.ok(): ...                 # rules.errors says what is wrong
#   rules.gravity, rules.cone_half_across (rad), rules.blast_pips(distance_m)
#
# `source` may also be an already-parsed Dictionary (tests build variants that way).

const Records = preload("res://scripts/sim/records.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")

const PATH := "res://data/sim/bombs.json"

var gravity: float = NAN                 # m/s^2
var cone_half_across_deg: float = NAN
var cone_half_across: float = NAN        # radians
var cone_half_height_deg: float = NAN
var cone_half_height: float = NAN        # radians
var cone_max_range_factor: float = NAN   # the cone reaches no farther than this x the ideal ground range
var rim_accuracy_factor: float = NAN
var falloff_exponent: float = NAN
var release_samples: int = 0
var spread_base_m: float = NAN
var spread_per_height: float = NAN
var stick_error_fraction: float = NAN
var release_interval_s: float = NAN
var blast_distances: PackedFloat64Array = PackedFloat64Array()   # ascending
var blast_pips: PackedFloat64Array = PackedFloat64Array()        # pips within the same index's distance
var blast_height_m: float = NAN
var blast_hits_own_side: bool = true
var errors: Array[String] = []

# The accuracy factor is the weapons' centre factor (Combat.centre_factor) applied to the
# release error, so it is evaluated through a CombatWeapon that carries just the two numbers.
var accuracy_weapon: CombatWeapon = null

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<bombs dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a bombs source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		gravity = r.number(d, "gravity_mps2", "gravity_mps2", 0.1, 1000.0)
		cone_half_across_deg = r.number(d, "cone_half_across_deg", "cone_half_across_deg", 0.1, 89.0)
		cone_half_across = deg_to_rad(cone_half_across_deg)
		cone_half_height_deg = r.number(d, "cone_half_height_deg", "cone_half_height_deg", 0.1, 60.0)
		cone_half_height = deg_to_rad(cone_half_height_deg)
		cone_max_range_factor = r.number(d, "cone_max_range_factor", "cone_max_range_factor", 1.0, 20.0)
		rim_accuracy_factor = r.number(d, "rim_accuracy_factor", "rim_accuracy_factor", 0.01, 1.0)
		falloff_exponent = r.number(d, "falloff_exponent", "falloff_exponent", 0.1, 10.0)
		release_samples = r.integer(d, "release_samples", "release_samples", 2)
		spread_base_m = r.number(d, "spread_base_m", "spread_base_m", 0.0)
		spread_per_height = r.number(d, "spread_per_height", "spread_per_height", 0.0)
		stick_error_fraction = r.number(d, "stick_error_fraction", "stick_error_fraction", 0.0, 1.0)
		release_interval_s = r.number(d, "release_interval_s", "release_interval_s", 0.0, 5.0)
		var curve := r.curve(d, "blast_pips_by_distance", "blast_pips_by_distance")
		blast_distances = curve[0]
		blast_pips = curve[1]
		blast_height_m = r.number(d, "blast_height_m", "blast_height_m", 0.0)
		blast_hits_own_side = r.boolean(d, "blast_hits_own_side", "blast_hits_own_side")
		for key: Variant in d:
			var k := str(key)
			if not k.begins_with("_") and not KEYS.has(k):
				r.err("unknown field '%s' (misspelt?)" % k)
	errors = r.errors
	accuracy_weapon = CombatWeapon.new({
		"id": "release", "rim_odds_factor": rim_accuracy_factor if is_finite(rim_accuracy_factor) else 1.0,
		"falloff_exponent": falloff_exponent if is_finite(falloff_exponent) else 1.0,
	})

const KEYS := ["gravity_mps2", "cone_half_across_deg", "cone_half_height_deg", "cone_max_range_factor", "rim_accuracy_factor", "falloff_exponent",
	"release_samples", "spread_base_m", "spread_per_height", "stick_error_fraction", "release_interval_s",
	"blast_pips_by_distance", "blast_height_m", "blast_hits_own_side"]

func ok() -> bool:
	return errors.is_empty()

# Pips a blast does to a unit whose centre is `distance_m` from the impact: the first tier
# (smallest distance first) that reaches it, 0 beyond the last.
func blast_damage(distance_m: float) -> int:
	for i in blast_distances.size():
		if distance_m <= blast_distances[i]:
			return int(round(blast_pips[i]))
	return 0

# The farthest distance at which a blast hurts anything (the last tier's), metres.
func blast_radius_m() -> float:
	if blast_distances.is_empty():
		return 0.0
	return blast_distances[blast_distances.size() - 1]
