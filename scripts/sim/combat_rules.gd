extends RefCounted

# The simulation's combat constants, read from data/sim/combat.json (Track C,
# proposed 2026-10-09; every value there carries its reason). Same rules as the
# other sim data (records.gd): a missing field is an error, never a default; a
# tunable without a provenance is an error.
#
#   var rules := CombatRules.new()
#   if not rules.ok(): ...                 # rules.errors says what is wrong
#   rules.tick_seconds, rules.odds_factors, rules.max_pitch (rad)
#
# `source` may also be an already-parsed Dictionary (tests build variants that
# way without writing files).

const Records = preload("res://scripts/sim/records.gd")
const Combat = preload("res://scripts/sim/combat.gd")

const PATH := "res://data/sim/combat.json"

# The only target rule the sim implements (proposed default, NOT target
# priority). Another rule in the data is an error, not a silent fallback.
const TARGET_RULE_BEST_ODDS := "best_odds"

var tick_seconds: float = NAN
var target_rule: String = ""
var odds_factors: Array[String] = []   # names from Combat.FACTOR_NAMES, applied in this order
var max_pitch_deg: float = NAN
var max_pitch: float = NAN             # radians
# What happens to a unit at 0 health (Alex 2026-10-09: it explodes mid air or
# loses control and crashes eventually).
var explode_chance: float = NAN        # chance a kill explodes the plane; otherwise it falls out of control
var fall_turn_rate_dps: float = NAN
var fall_turn_rate: float = NAN        # radians per second; the spiral, direction from the fate roll
var fall_speed_gain: float = NAN       # m/s^2, up to the unit type's dive_speed_max_mps
var fall_descent: float = NAN          # m/s of height lost
var errors: Array[String] = []

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<combat dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a combat source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		tick_seconds = r.number(d, "tick_seconds", "tick_seconds", 0.001)
		target_rule = r.id_value(d, "target_rule", "target_rule", [TARGET_RULE_BEST_ODDS])
		odds_factors = r.id_list(d, "odds_factors", "odds_factors", Combat.FACTOR_NAMES)
		max_pitch_deg = r.number(d, "max_pitch_deg", "max_pitch_deg", 0.0, 89.0)
		max_pitch = deg_to_rad(max_pitch_deg)
		explode_chance = r.number(d, "explode_chance", "explode_chance", 0.0, 1.0)
		fall_turn_rate_dps = r.number(d, "fall_turn_rate_dps", "fall_turn_rate_dps", 0.0)
		fall_turn_rate = deg_to_rad(fall_turn_rate_dps)
		fall_speed_gain = r.number(d, "fall_speed_gain_mps2", "fall_speed_gain_mps2", 0.0)
		fall_descent = r.number(d, "fall_descent_mps", "fall_descent_mps", 0.001)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()
