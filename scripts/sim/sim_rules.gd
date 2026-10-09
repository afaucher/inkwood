extends RefCounted

# The simulation's world-wide constants, read from data/sim/turn.json (turn
# length, the step rule, the map bounds) and data/sim/altitude.json (the
# altitude bands, bottom to top). Every value there is PROPOSED by Track S
# (2026-10-09) and carries its reason; this file only reads them.
#
#   var rules := SimRules.new()
#   if not rules.ok(): ...                      # rules.errors says what is wrong
#   rules.turn_seconds, rules.bounds, rules.band_ids, rules.band_height_m["low"]
#
# Missing or malformed values are recorded in `errors` (records.gd), never
# defaulted.

const Records = preload("res://scripts/sim/records.gd")

const TURN_PATH := "res://data/sim/turn.json"
const ALTITUDE_PATH := "res://data/sim/altitude.json"

# The only step rule the sim implements: each unit type splits the turn into
# its own actions_per_turn equal steps (the design doc's proposal under Turn
# length and action counts). Another rule in the data is an error, not a
# silent fallback to this one.
const STEP_RULE_FIXED_PER_TYPE := "fixed_per_type"

var turn_seconds: float = NAN
var step_rule: String = ""
# Metres, origin top-left, y down. Rect2 is float32, which is exact for the
# whole-metre bounds the data holds; positions themselves stay float64.
var bounds: Rect2 = Rect2()
var band_ids: Array[String] = []          # vertical order, bottom first
var band_height_m: Dictionary = {}        # id -> float
var band_reference: Dictionary = {}       # id -> "terrain" | "sea_level"
var errors: Array[String] = []

func _init(turn_path: String = TURN_PATH, altitude_path: String = ALTITUDE_PATH, quiet: bool = false) -> void:
	var r := Records.new(turn_path, quiet)
	var turn: Variant = r.read_json(turn_path)
	if turn is Dictionary:
		var t: Dictionary = turn
		turn_seconds = r.number(t, "turn_seconds", "turn_seconds", 0.001)
		step_rule = r.id_value(t, "step_rule", "step_rule", [STEP_RULE_FIXED_PER_TYPE])
		var b: Variant = r.record(t, "map_bounds_m", "map_bounds_m")
		if b is Dictionary:
			var bd: Dictionary = b
			var vals: Array[float] = []
			for k: String in ["x", "y", "width", "height"]:
				var v: Variant = bd.get(k)
				if Records.is_number(v):
					vals.append(float(v))
				else:
					r.err("map_bounds_m.value.%s must be a number" % k)
					vals.append(0.0)
			bounds = Rect2(vals[0], vals[1], vals[2], vals[3])
			if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
				r.err("map_bounds_m must have a positive width and height")
		elif typeof(b) != TYPE_NIL:
			r.err("map_bounds_m.value must be an object {x, y, width, height}")
	errors.append_array(r.errors)

	var a := Records.new(altitude_path, quiet)
	var alt: Variant = a.read_json(altitude_path)
	if alt is Dictionary:
		var bands: Variant = (alt as Dictionary).get("bands")
		if not (bands is Array) or (bands as Array).is_empty():
			a.err("missing list 'bands'")
		else:
			for i in (bands as Array).size():
				var entry: Variant = bands[i]
				if not (entry is Dictionary):
					a.err("bands[%d] is not an object" % i)
					continue
				var e: Dictionary = entry
				var id := a.text(e, "id", "bands[%d].id" % i)
				if id == "":
					continue
				if band_ids.has(id):
					a.err("band '%s' is listed twice" % id)
					continue
				var ref := a.text(e, "reference", "bands[%d].reference" % i)
				if ref != "terrain" and ref != "sea_level":
					a.err("bands[%d].reference must be 'terrain' or 'sea_level', got '%s'" % [i, ref])
				band_ids.append(id)
				band_reference[id] = ref
				band_height_m[id] = a.number(e, "height_m", "bands[%d].height_m" % i, 0.0)
	errors.append_array(a.errors)

func ok() -> bool:
	return errors.is_empty()

# Steps per turn and their length for a unit type, under the step rule.
func step_dt(actions_per_turn: int) -> float:
	return turn_seconds / float(actions_per_turn)
