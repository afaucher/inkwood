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
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")

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
	for f: String in ["id", "name", "domain", "size_m", "actions_per_turn", "health", "sight_range_m", "drawing", "envelope", "weapons"]:
		check(fields.has(f), "schema lists '%s'" % f)
	var weapon_fields: Dictionary = (fields.get("weapons", {}) as Dictionary).get("item_fields", {})
	for f: String in ["id", "name", "kind", "hardpoints", "mount_deg", "half_across_deg", "elevation_deg", "half_height_deg", "effective_range_m", "base_hit_chance", "rim_odds_factor", "falloff_exponent", "damage_pips", "rolls_per_second"]:
		check(weapon_fields.has(f), "schema lists weapons[].%s" % f)
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
		_check_weapons(def)
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
		["a weapon missing a field", "missing field 'weapons[0].effective_range_m'"],
		["a weapon number with no provenance", "'weapons[0].effective_range_m' says neither where it came from"],
		["a misspelt weapon key", "unknown field 'weapons[0].rnage_m'"],
		["a weapon kind outside the three", "'weapons[0].kind' = 'cannon' is not one of"],
		["a weapon with no hardpoints", "'weapons[0].hardpoints' must be a non-empty list"],
		["a malformed hardpoint", "has a point that is not [forward, right, up]"],
		["odds above 1", "'weapons[0].base_hit_chance' = 1.5 is outside [0.0, 1.0]"],
		["a cone with no width", "'weapons[0].half_across_deg' = 0.0 is outside [0.1, 180.0]"],
		["a zero damage", "'weapons[0].damage_pips' = 0 is below 1"],
		["two weapons with one id", "weapons: id 'wing_guns' is used twice"],
		["no weapons list", "missing list 'weapons'"],
		["a weapon that is not an object", "'weapons[0]' is not an object"],
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
		elif spec.get("kind", "") == "list" and raw[key] is Array:
			for i in (raw[key] as Array).size():
				_check_present(spec.get("item_fields", {}), raw[key][i], "%s%s[%d]." % [prefix, key, i])

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
		"a weapon missing a field":
			(d["weapons"][0] as Dictionary).erase("effective_range_m")
		"a weapon number with no provenance":
			d["weapons"][0]["effective_range_m"] = {"value": 450}
		"a misspelt weapon key":
			d["weapons"][0]["rnage_m"] = {"value": 1, "_proposed": true, "_reason": "typo"}
		"a weapon kind outside the three":
			d["weapons"][0]["kind"] = "cannon"
		"a weapon with no hardpoints":
			d["weapons"][0]["hardpoints"] = {"value": [], "_proposed": true, "_reason": "x"}
		"a malformed hardpoint":
			d["weapons"][0]["hardpoints"] = {"value": [[1, 2]], "_proposed": true, "_reason": "x"}
		"odds above 1":
			d["weapons"][0]["base_hit_chance"] = {"value": 1.5, "_proposed": true, "_reason": "x"}
		"a cone with no width":
			d["weapons"][0]["half_across_deg"] = {"value": 0, "_proposed": true, "_reason": "x"}
		"a zero damage":
			d["weapons"][0]["damage_pips"] = {"value": 0, "_proposed": true, "_reason": "x"}
		"two weapons with one id":
			(d["weapons"] as Array).append((d["weapons"][0] as Dictionary).duplicate(true))
		"no weapons list":
			d.erase("weapons")
		"a weapon that is not an object":
			d["weapons"] = [5]
		_:
			fail("no such breakage: " + what)

# The weapons of one valid unit file: parsed into typed records, with the sanity
# the schema's ranges cannot express and the lead's proposal's anchors.
func _check_weapons(def: UnitDef) -> void:
	var ids: Array[String] = []
	for w in def.weapons:
		check(w.id != "" and not ids.has(w.id), "%s: weapon id '%s' is unique" % [def.id, w.id])
		ids.append(w.id)
		check(CombatWeapon.KINDS.has(w.kind), "%s.%s: kind '%s' is one of the three" % [def.id, w.id, w.kind])
		check(w.hardpoints.size() >= 1, "%s.%s: at least one hardpoint" % [def.id, w.id])
		check(w.half_across > 0.0 and w.half_height > 0.0 and w.effective_range_m > 0.0 and w.damage_pips >= 1 and w.rolls_per_second > 0.0, "%s.%s: a real cone, range, damage and roll rate" % [def.id, w.id])
		near(w.mount, deg_to_rad(w.mount_deg), 1e-12, "%s.%s: angles are radians at runtime" % [def.id, w.id])
		check(w.base_hit_chance > 0.0 and w.base_hit_chance <= 1.0 and w.rim_odds_factor >= 0.0 and w.rim_odds_factor <= 1.0, "%s.%s: odds are probabilities" % [def.id, w.id])
		var back := CombatWeapon.new(w.values())
		check(back.effective_range_m == w.effective_range_m and back.range_m == w.range_m and back.hardpoints == w.hardpoints and back.mount == w.mount, "%s.%s: values() rebuilds the same weapon" % [def.id, w.id])
	check(def.domain != "air" or def.weapons.size() >= 1, "%s: an air unit has a weapon" % def.id)
	print("    weapons: %s" % ", ".join(def.weapons.map(func(w: CombatWeapon) -> String: return "%s (%d hardpoint%s, %s, %s m)" % [w.id, w.hardpoints.size(), "" if w.hardpoints.size() == 1 else "s", w.kind, w.effective_range_m])))
	# The lead's proposal (variants/engagement-cones/weapons_proposed.json), 2026-10-09.
	match def.id:
		"light_fighter":
			eq(ids, ["wing_guns"] as Array[String], "light fighter: one weapon, the wing guns")
			eq(def.weapons[0].hardpoints.size(), 2, "...a pair: one hardpoint per wing")
			check(def.weapons[0].hardpoints[0].y < 0.0 and def.weapons[0].hardpoints[1].y > 0.0, "...one left, one right")
			eq(def.weapons[0].kind, "fixed", "...fixed")
		"heavy_fighter":
			eq(ids, ["nose_cannon", "rear_gunner"] as Array[String], "heavy fighter: nose cannon and rear gunner")
			eq(def.weapons[0].damage_pips, 2, "the cannon does 2 pips")
			eq(def.weapons[0].effective_range_m, 600.0, "...at 600 m")
			eq(def.weapons[1].mount_deg, 180.0, "the rear gunner points rearward")
		"bomber":
			eq(ids, ["nose_gun", "dorsal_turret", "tail_turret"] as Array[String], "bomber: nose gun, dorsal turret, tail turret")
			eq(def.weapons[2].effective_range_m, 400.0, "the tail turret's effective range is 400 m")
			eq(def.weapons[1].elevation_deg, 35.0, "the dorsal turret's cone is centred 35 deg up")
