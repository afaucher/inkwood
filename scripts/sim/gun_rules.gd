extends RefCounted

# The big-gun specials' constants, read from data/sim/guns.json (Track SH, the warship, proposed 2026-10-10; every value
# there carries its reason). Same rules as the other sim data (records.gd): a missing field is an error, never a default;
# a tunable without a provenance is an error. The model is documented at the top of scripts/sim/guns.gd.
#
#   var rules := GunRules.new()
#   if not rules.ok(): ...                       # rules.errors says what is wrong
#   rules.has_special("main_guns")               # is this special id a gun special (else it is the bomb drop, or unknown)
#   var g: GunRules.Spec = rules.special("main_guns")
#   g.range_max_m, g.shells, g.reload_turns, g.blast_damage(distance_m), g.poor_shot_factor, ...
#   rules.unspotted_mode                         # "poor_shot" (the default; Alex, outside-cone-release) | "hold": a salvo whose target is
#                                                # no longer spotted or in reach when it fires (data/sim/guns.json gun_unspotted_mode)
#
# A Spec also answers the four questions the combat resolver's blast asks of a bomb's rules (blast_damage,
# blast_radius_m, blast_height_m, blast_hits_own_side), so a landing shell goes through the very code a landing bomb does.
#
# `source` may also be an already-parsed Dictionary (tests build variants that way without writing files).

const Records = preload("res://scripts/sim/records.gd")

const PATH := "res://data/sim/guns.json"

# One gun special's numbers.
class Spec:
	var id: String = ""
	var range_max_m: float = NAN
	var range_min_m: float = NAN
	var inland_max_m: float = NAN        # a target farther than this from the shore (along the line of fire) is inland: out of reach
	var inland_step_m: float = NAN
	var shells: int = 0
	var salvo_interval_s: float = NAN
	var reload_turns: int = 0
	var fire_at: float = NAN
	var shell_speed_mps: float = NAN
	var min_flight_s: float = NAN
	var apex_per_range: float = NAN
	var lead_target: bool = true
	var spread_base_m: float = NAN
	var spread_per_range: float = NAN
	var unranged_factor: float = NAN
	var ranged_factor: float = NAN
	var ranging_s: float = NAN
	var salvo_error_fraction: float = NAN
	var poor_shot_factor: float = NAN     # a POOR SHOT's scatter is multiplied by this (Alex, outside-cone-release: 'Fire a poorer one')
	var poor_shot_min_sigma_m: float = NAN   # ... and is never tighter than this (one shell, one standard deviation per ground axis)
	var spotter_far_factor: float = NAN   # the scatter's multiplier for a target at the very edge of its nearest spotter's sight (1 at the spotter)
	var bracket_factor: float = NAN       # the scatter's multiplier for each earlier salvo at the same spotted target
	var bracket_floor: float = NAN        # ... never below this
	var bracket_turns: int = 0            # a target not fired at for this many turns is a new target
	var bracket_point_m: float = NAN      # a point target within this of an earlier salvo's aim is the same target
	var blast_distances: PackedFloat64Array = PackedFloat64Array()   # ascending
	var blast_pips: PackedFloat64Array = PackedFloat64Array()        # pips within the same index's distance
	var blast_height_m: float = NAN
	var blast_hits_own_side: bool = true

	# Pips a landing shell does to a unit whose centre is `distance_m` from the impact: the first tier (smallest distance
	# first) that reaches it, 0 beyond the last (the same lookup as BombRules.blast_damage).
	func blast_damage(distance_m: float) -> int:
		for i in blast_distances.size():
			if distance_m <= blast_distances[i]:
				return int(round(blast_pips[i]))
		return 0

	# The farthest distance at which a shell hurts anything (the last tier's), metres.
	func blast_radius_m() -> float:
		if blast_distances.is_empty():
			return 0.0
		return blast_distances[blast_distances.size() - 1]

var spot_step_s: float = NAN         # spotting is judged this far apart through a resolve
var unspotted_mode: String = ""      # "hold" | "poor_shot": what a salvo does when its target is no longer spotted or in reach at the fire moment
var specials: Dictionary = {}        # special id -> Spec
var errors: Array[String] = []

const UNSPOTTED_MODES := ["hold", "poor_shot"]
const SPEC_KEYS := ["range_max_m", "range_min_m", "inland_max_m", "inland_step_m", "shells", "salvo_interval_s", "reload_turns", "fire_at", "shell_speed_mps", "min_flight_s",
	"apex_per_range", "lead_target", "spread_base_m", "spread_per_range", "unranged_factor", "ranged_factor", "ranging_s", "salvo_error_fraction",
	"spotter_far_factor", "bracket_factor", "bracket_floor", "bracket_turns", "bracket_point_m", "poor_shot_factor", "poor_shot_min_sigma_m",
	"blast_pips_by_distance", "blast_height_m", "blast_hits_own_side"]

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<guns dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a guns source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		var spot := r.section(d, "spot", "spot")
		spot_step_s = r.number(spot, "step_s", "spot.step_s", 0.05, 5.0)
		unspotted_mode = r.id_value(d, "gun_unspotted_mode", "gun_unspotted_mode", UNSPOTTED_MODES)
		var all := r.section(d, "specials", "specials")
		if all.is_empty():
			r.err("'specials' has no gun special")
		for sid: Variant in all:
			var key := str(sid)
			if key.begins_with("_"):
				continue
			if not (all[sid] is Dictionary):
				r.err("specials.%s is not an object" % key)
				continue
			specials[key] = _read_spec(r, key, all[sid])
		for key: Variant in d:
			var k := str(key)
			if not k.begins_with("_") and k != "spot" and k != "specials" and k != "gun_unspotted_mode":
				r.err("unknown field '%s' (misspelt?)" % k)
	errors = r.errors

func _read_spec(r: Records, sid: String, d: Dictionary) -> Spec:
	var s := Spec.new()
	var p := "specials.%s." % sid
	s.id = sid
	s.range_max_m = r.number(d, "range_max_m", p + "range_max_m", 1.0)
	s.range_min_m = r.number(d, "range_min_m", p + "range_min_m", 0.0)
	if is_finite(s.range_max_m) and is_finite(s.range_min_m) and s.range_min_m >= s.range_max_m:
		r.err("%srange_min_m (%s) must be below range_max_m (%s)" % [p, str(s.range_min_m), str(s.range_max_m)])
	s.inland_max_m = r.number(d, "inland_max_m", p + "inland_max_m", 0.0)
	s.inland_step_m = r.number(d, "inland_step_m", p + "inland_step_m", 1.0)
	s.shells = r.integer(d, "shells", p + "shells", 1)
	s.salvo_interval_s = r.number(d, "salvo_interval_s", p + "salvo_interval_s", 0.0, 5.0)
	s.reload_turns = r.integer(d, "reload_turns", p + "reload_turns", 0)
	s.fire_at = r.number(d, "fire_at", p + "fire_at", 0.0, 1.0)
	s.shell_speed_mps = r.number(d, "shell_speed_mps", p + "shell_speed_mps", 1.0)
	s.min_flight_s = r.number(d, "min_flight_s", p + "min_flight_s", 0.0)
	s.apex_per_range = r.number(d, "apex_per_range", p + "apex_per_range", 0.0)
	s.lead_target = r.boolean(d, "lead_target", p + "lead_target")
	s.spread_base_m = r.number(d, "spread_base_m", p + "spread_base_m", 0.0)
	s.spread_per_range = r.number(d, "spread_per_range", p + "spread_per_range", 0.0)
	s.unranged_factor = r.number(d, "unranged_factor", p + "unranged_factor", 0.01)
	s.ranged_factor = r.number(d, "ranged_factor", p + "ranged_factor", 0.01)
	s.ranging_s = r.number(d, "ranging_s", p + "ranging_s", 0.1)
	s.salvo_error_fraction = r.number(d, "salvo_error_fraction", p + "salvo_error_fraction", 0.0, 1.0)
	s.poor_shot_factor = r.number(d, "poor_shot_factor", p + "poor_shot_factor", 1.0)
	s.poor_shot_min_sigma_m = r.number(d, "poor_shot_min_sigma_m", p + "poor_shot_min_sigma_m", 0.0)
	s.spotter_far_factor = r.number(d, "spotter_far_factor", p + "spotter_far_factor", 1.0)
	s.bracket_factor = r.number(d, "bracket_factor", p + "bracket_factor", 0.01, 1.0)
	s.bracket_floor = r.number(d, "bracket_floor", p + "bracket_floor", 0.01, 1.0)
	s.bracket_turns = r.integer(d, "bracket_turns", p + "bracket_turns", 1)
	s.bracket_point_m = r.number(d, "bracket_point_m", p + "bracket_point_m", 1.0)
	var curve := r.curve(d, "blast_pips_by_distance", p + "blast_pips_by_distance")
	s.blast_distances = curve[0]
	s.blast_pips = curve[1]
	s.blast_height_m = r.number(d, "blast_height_m", p + "blast_height_m", 0.0)
	s.blast_hits_own_side = r.boolean(d, "blast_hits_own_side", p + "blast_hits_own_side")
	for key: Variant in d:
		var k := str(key)
		if not k.begins_with("_") and not SPEC_KEYS.has(k):
			r.err("unknown field '%s%s' (misspelt?)" % [p, k])
	return s

func ok() -> bool:
	return errors.is_empty()

func has_special(special_id: String) -> bool:
	return specials.has(special_id)

# The Spec of a gun special, or null.
func special(special_id: String) -> Spec:
	return specials.get(special_id)
