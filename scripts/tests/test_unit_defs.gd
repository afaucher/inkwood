extends "res://scripts/test_support/test_case.gd"

# THE UNIT DATA CHECK (Track S): every data/units/*.json loads and validates
# against data/units/_schema.json; every schema field is present in every
# file; every tunable says where it came from; broken files are REJECTED, not
# defaulted; and data/sim/turn.json's map is still big enough for its own
# derivation with the units as they are tuned today.
#
# The negative cases matter as much as the positive: a loader that accepts
# everything passes the positive half of this test too.

const SimRules = preload("res://scripts/sim/sim_rules.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")
const Records = preload("res://scripts/sim/records.gd")

# The demo's air units (design doc, Initial unit roster). More files may exist;
# these must.
const REQUIRED := ["light_fighter", "heavy_fighter", "bomber"]

func setup(_main) -> void:
	var rules := SimRules.new()
	if not check(rules.ok(), "data/sim/turn.json and altitude.json load: %s" % str(rules.errors)):
		finish()
		return
	eq(rules.band_ids, ["surface", "low", "medium", "high"] as Array[String], "altitude bands, bottom first")
	check(rules.turn_seconds > 0.0, "turn length is positive")

	var schema: Variant = Records.new("schema").read_json(UnitDef.SCHEMA_PATH)
	if not check(schema is Dictionary and (schema as Dictionary).get("fields") is Dictionary, "the unit schema parses and has fields"):
		finish()
		return
	var fields: Dictionary = (schema as Dictionary)["fields"]
	for f: String in ["id", "name", "domain", "size_m", "actions_per_turn", "health", "sight_range_m", "drawing", "envelope"]:
		check(fields.has(f), "schema lists '%s'" % f)
	var env_fields: Dictionary = (fields.get("envelope", {}) as Dictionary).get("fields", {})
	for f: String in ["speed_min_mps", "speed_max_mps", "accel_mps2", "decel_mps2", "turn_rate_curve_dps", "turn_bleed_mps2", "climb_speed_cost_mps", "dive_speed_gain_mps", "altitude_bands", "reverse_from_stop"]:
		check(env_fields.has(f), "schema lists envelope.%s" % f)

	# --- Every unit file -------------------------------------------------------
	var found: Array[String] = []
	for file: String in DirAccess.get_files_at(UnitDef.UNITS_DIR):
		if not file.ends_with(".json") or file.begins_with("_"):
			continue
		var path := "%s/%s" % [UnitDef.UNITS_DIR, file]
		var def := UnitDef.new(path, rules.band_ids)
		found.append(def.id)
		if not check(def.ok(), "%s validates: %s" % [file, "; ".join(def.errors)]):
			continue
		eq(def.id, file.get_basename(), "%s: id matches the file name" % file)
		check(def.envelope != null, "%s: has an envelope" % file)
		check(def.actions_per_turn >= 1, "%s: at least one step per turn" % file)
		# Every schema field is present in the raw file -- the walk above already
		# errors on a missing one; this states it independently of the loader.
		var raw: Variant = Records.new(path).read_json(path)
		_check_present(fields, raw, file + ":")
		print("  %-14s %-6s steps %d  speed %s..%s m/s (cruise %s)  turn %s..%s deg/s  bands %s" % [
			def.id, def.domain, def.actions_per_turn,
			def.envelope.speed_min, def.envelope.speed_max, def.envelope.speed_cruise,
			snappedf(rad_to_deg(def.envelope.turn_rate(def.envelope.speed_max)), 0.1),
			snappedf(rad_to_deg(def.envelope.turn_rate(def.envelope.speed_min)), 0.1),
			str(def.envelope.bands)])
	for id: String in REQUIRED:
		check(found.has(id), "data/units/%s.json exists" % id)

	# --- Broken files are rejected, each for its own reason --------------------
	var good: Dictionary = Records.new("lf").read_json(UnitDef.path_for("light_fighter"))
	# [how it is broken, a phrase the error must contain] -- so each case is
	# rejected for ITS reason, not because some other check happened to fire.
	var cases: Array = [
		["missing envelope.accel_mps2", "missing field 'envelope.accel_mps2'"],
		["missing health", "missing field 'health'"],
		["a record with no provenance", "'size_m' says neither where it came from"],
		["a bare number instead of a record", "'size_m' is not a value record"],
		["an unknown (misspelt) key", "unknown field 'envelope.speed_mx_mps'"],
		["an unknown band", "stratosphere"],
		["speeds out of order", "speed_min <= speed_cruise <= speed_max"],
		["a curve whose speeds do not increase", "strictly increase"],
		["a domain outside the roster's", "'domain' = 'space'"],
		["zero steps per turn", "'actions_per_turn' = 0 is below 1"],
	]
	for c: Array in cases:
		var what: String = c[0]
		var d: Dictionary = good.duplicate(true)
		_break(d, what)
		var bad := UnitDef.new(d, rules.band_ids, true, "broken light_fighter (%s)" % what)
		var all_errors := "; ".join(bad.errors)
		check(not bad.ok(), "rejected: %s" % what)
		check(all_errors.contains(str(c[1])), "rejected for its own reason: %s -- errors were: %s" % [what, all_errors])
		check(bad.envelope == null, "no envelope is built from a file with %s" % what)
	# A decision id is as good as a reason: the record shape for a value Alex chose.
	var decided: Dictionary = good.duplicate(true)
	decided["size_m"] = {"value": 9, "decision": "light-fighter-size"}
	check(UnitDef.new(decided, rules.band_ids, true, "decided").ok(), "a record carrying a decision id instead of _proposed is accepted")

	# --- The map is big enough (turn.json's _derivation, recomputed) ------------
	# Side >= S + 2 r_c + 2 r_max for every air unit, where a minute at cruise
	# is a racetrack lap with one full turn at the cruise radius r_c, S each
	# straight, and r_max the top-speed radius.
	var need := 0.0
	for id: String in found:
		var def := UnitDef.new(UnitDef.path_for(id), rules.band_ids, true)
		if not def.ok() or def.domain != "air":
			continue
		var e := def.envelope
		var r_c := e.turn_radius(e.speed_cruise)
		var r_max := e.turn_radius(e.speed_max)
		var lap := 60.0 * e.speed_cruise
		var straight := (lap - TAU * r_c) * 0.5
		check(straight >= 0.0, "%s can fly a full circle at cruise inside a minute" % id)
		var side := straight + 2.0 * r_c + 2.0 * r_max
		print("  map rule %-14s r_c %.1f  r_max %.1f  straight %.1f  side >= %.1f m" % [id, r_c, r_max, straight, side])
		need = maxf(need, side)
	check(rules.bounds.size.x >= need and rules.bounds.size.y >= need,
		"map %s x %s m holds a minute of flight with full turns for every air unit (needs %.1f m)" % [rules.bounds.size.x, rules.bounds.size.y, need])
	finish()

# Every field the schema lists is a key in the file, recursively into sections.
func _check_present(fields: Dictionary, raw: Variant, prefix: String) -> void:
	if not check(raw is Dictionary, "%s is an object" % prefix):
		return
	for key: String in fields:
		if not check((raw as Dictionary).has(key), "%s has '%s'" % [prefix, key]):
			continue
		var spec: Dictionary = fields[key]
		if spec.get("kind", "") == "section":
			_check_present(spec.get("fields", {}), raw[key], prefix + key + ".")

# One way to break a good unit file, by name.
func _break(d: Dictionary, what: String) -> void:
	var env: Dictionary = d["envelope"]
	match what:
		"missing envelope.accel_mps2":
			env.erase("accel_mps2")
		"missing health":
			d.erase("health")
		"a record with no provenance":
			d["size_m"] = {"value": 9}
		"a bare number instead of a record":
			d["size_m"] = 9
		"an unknown (misspelt) key":
			env["speed_mx_mps"] = {"value": 1, "_proposed": true, "_reason": "typo"}
		"an unknown band":
			env["start_band"] = {"value": "stratosphere", "_proposed": true, "_reason": "x"}
		"speeds out of order":
			env["speed_cruise_mps"] = {"value": 500, "_proposed": true, "_reason": "x"}
		"a curve whose speeds do not increase":
			env["turn_rate_curve_dps"] = {"value": [[100, 20], [50, 30]], "_proposed": true, "_reason": "x"}
		"a domain outside the roster's":
			d["domain"] = "space"
		"zero steps per turn":
			d["actions_per_turn"] = {"value": 0, "_proposed": true, "_reason": "x"}
		_:
			fail("no such breakage: " + what)
