extends RefCounted

# The water rule's constants, read from data/sim/sea.json (Track WS, proposed 2026-10-10; every value
# there carries its reason). Same rules as the other sim data (records.gd): a missing field is an error,
# never a default; a tunable without a provenance is an error. The rule itself is World's
# (set_water, _afloat_step); this only holds its numbers.
#
#   var rules := SeaRules.new()
#   if not rules.ok(): ...                 # rules.errors says what is wrong
#   rules.hull_fraction, rules.sample_m, rules.slow_tries
#
# `source` may also be an already-parsed Dictionary (tests build variants that way without writing files).

const Records = preload("res://scripts/sim/records.gd")

const PATH := "res://data/sim/sea.json"

var hull_fraction: float = NAN   # the hull's ends are checked this share of size_m fore and aft of the centre
var sample_m: float = NAN        # a step's arc is sampled at least this often
var slow_tries: int = 0          # slower end speeds tried before a step is held
var errors: Array[String] = []

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<sea dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a sea source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		hull_fraction = r.number(d, "hull_fraction", "hull_fraction", 0.0, 1.0)
		sample_m = r.number(d, "sample_m", "sample_m", 0.1)
		slow_tries = r.integer(d, "slow_tries", "slow_tries", 0)
		for key: Variant in d:
			var k := str(key)
			if not k.begins_with("_") and not ["hull_fraction", "sample_m", "slow_tries"].has(k):
				r.err("unknown field '%s' (misspelt?)" % k)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()
