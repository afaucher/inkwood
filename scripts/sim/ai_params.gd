extends RefCounted

# The enemy AI's numbers, read from data/sim/ai.json (Track E, proposed,
# 2026-10-09). Every value there is a value record (records.gd): a missing one,
# a record with no provenance, or an unknown key is an error, never a default.
#
#   var p := AiParams.new()
#   if not p.ok(): ...                       # p.errors says what is wrong
#   p.num("escort", "leash_m"), p.whole("escort", "no_chance_turns"), p.flag(...)
#
# SHAPE below is names and legal ranges only -- no values (working rule 4).
# A test may change a value after loading with set_value() to isolate one rule.

const Records = preload("res://scripts/sim/records.gd")

const DATA_PATH := "res://data/sim/ai.json"

# section -> key -> [kind, min, max]; kind "n" a number, "i" a whole number
# (max is not checked), "b" true or false.
const SHAPE := {
	"knowledge": {
		"memory_turns": ["i", 0, INF],
	},
	"common": {
		"edge_margin_turn_radii": ["n", 0.0, 100.0],
	},
	"strike": {
		"capture_radius_m": ["n", 1.0, INF],
		"speed_fraction_of_cruise": ["n", 0.1, 3.0],
		"threat_radius_m": ["n", 0.0, INF],
		"evade_turns": ["i", 0, INF],
		"weave_amplitude_deg": ["n", 0.0, 90.0],
		"weave_half_period_steps": ["n", 1.0, 1000.0],
		"evade_changes_band": ["b", 0, 0],
		"evade_max_band_offset": ["i", 0, INF],
		"orbit_turn_fraction": ["n", 0.0, 1.0],
	},
	"escort": {
		"station_forward_m": ["n", -INF, INF],
		"station_right_m": ["n", -INF, INF],
		"station_tolerance_m": ["n", 1.0, INF],
		"align_range_m": ["n", 1.0, INF],
		"catchup_time_s": ["n", 0.1, INF],
		"engage_radius_protect_m": ["n", 0.0, INF],
		"engage_radius_self_m": ["n", 0.0, INF],
		"leash_m": ["n", 0.0, INF],
		"break_off_health_fraction": ["n", 0.0, 1.0],
		"no_chance_turns": ["i", 1, INF],
		"engage_range_fraction": ["n", 0.05, 1.0],
		"forward_mount_tolerance_deg": ["n", 0.0, 180.0],
		"match_band": ["b", 0, 0],
	},
	"mission": {
		"sample_dt_s": ["n", 0.01, INF],
		"target_radius_m": ["n", 1.0, INF],
	},
}

# The cone keys of a fallback weapon (the names Track C's def.weapons uses).
const CONE_KEYS := ["mount_deg", "half_across_deg", "elevation_deg", "half_height_deg", "range_m"]

var source: String = ""
var values: Dictionary = {}     # section -> key -> number or bool
var cones: Dictionary = {}      # unit type id -> {mount_deg, ..., range_m}: the fallback cones
var errors: Array[String] = []

func _init(path: String = DATA_PATH, quiet: bool = false) -> void:
	source = path
	var r := Records.new(path, quiet)
	var root_v: Variant = r.read_json(path)
	if root_v is Dictionary:
		var root: Dictionary = root_v
		for sec: String in SHAPE:
			values[sec] = _read_section(r, root, sec)
		_read_fallback_cones(r, root)
		for key: Variant in root:
			var k := str(key)
			if not k.begins_with("_") and not SHAPE.has(k) and k != "fallback_weapons":
				r.err("unknown section '%s' (misspelt?)" % k)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

func _read_section(r: Records, root: Dictionary, sec: String) -> Dictionary:
	var out := {}
	var shape: Dictionary = SHAPE[sec]
	var section := r.section(root, sec, sec)
	for key: String in shape:
		var spec: Array = shape[key]
		var label := "%s.%s" % [sec, key]
		match str(spec[0]):
			"i":
				out[key] = r.integer(section, key, label, int(spec[1]))
			"b":
				out[key] = r.boolean(section, key, label)
			_:
				out[key] = r.number(section, key, label, float(spec[1]), float(spec[2]))
	for key: Variant in section:
		var k := str(key)
		if not k.begins_with("_") and not shape.has(k):
			r.err("unknown field '%s.%s' (misspelt?)" % [sec, k])
	return out

func _read_fallback_cones(r: Records, root: Dictionary) -> void:
	var fw := r.section(root, "fallback_weapons", "fallback_weapons")
	for key: Variant in fw:
		var type_id := str(key)
		if type_id.begins_with("_"):
			continue
		if not (fw[key] is Dictionary):
			r.err("fallback_weapons.%s is not an object" % type_id)
			continue
		var section: Dictionary = fw[key]
		var cone := {}
		for ck: String in CONE_KEYS:
			cone[ck] = r.number(section, ck, "fallback_weapons.%s.%s" % [type_id, ck], -INF if ck != "range_m" else 0.0)
		for ck: Variant in section:
			var k := str(ck)
			if not k.begins_with("_") and not CONE_KEYS.has(k):
				r.err("unknown field 'fallback_weapons.%s.%s'" % [type_id, k])
		cones[type_id] = cone

# --- Access -------------------------------------------------------------------

func num(section: String, key: String) -> float:
	var s: Variant = values.get(section)
	if s is Dictionary and (s as Dictionary).has(key):
		return float((s as Dictionary)[key])
	return NAN

func whole(section: String, key: String) -> int:
	return int(num(section, key))

func flag(section: String, key: String) -> bool:
	var s: Variant = values.get(section)
	return s is Dictionary and (s as Dictionary).get(key, false) == true

# A test changes one value after loading to isolate the rule under test.
func set_value(section: String, key: String, v: Variant) -> void:
	if not values.has(section):
		values[section] = {}
	(values[section] as Dictionary)[key] = v

# The placeholder forward cone of a unit type, or {} if the file names none.
func fallback_cone(type_id: String) -> Dictionary:
	var c: Variant = cones.get(type_id)
	return (c as Dictionary).duplicate() if c is Dictionary else {}
