extends RefCounted

# One unit TYPE, loaded from data/units/<id>.json and validated against
# data/units/_schema.json (execution plan component 4, the unit data model).
#
#   var def := UnitDef.new("res://data/units/light_fighter.json", rules.band_ids)
#   if not def.ok(): ...                 # def.errors lists every problem at once
#   def.actions_per_turn, def.envelope.turn_rate(100.0), ...
#
# `source` may also be an already-parsed Dictionary (tests build broken and
# ship-shaped units that way without writing files).
#
# VALIDATION IS SCHEMA-DRIVEN: the schema's `fields` say which keys exist and
# of what kind; this walks them, so a field added to the schema is required of
# every unit file from then on without touching this code. A field missing
# from a file is an error, never a default (working rule 4); an unknown key is
# an error too, because a misspelt key is otherwise a value nobody reads.
# Every tunable must say where it came from -- _proposed with a reason, or a
# decision id (records.gd). The semantic checks the schema cannot express
# (speed ordering, the start band being one of the unit's bands, the id
# matching the file name) follow the walk.

const Records = preload("res://scripts/sim/records.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")

const UNITS_DIR := "res://data/units"
const SCHEMA_PATH := "res://data/units/_schema.json"

var source: String = ""
var id: String = ""
var name: String = ""
var domain: String = ""
# "mobile" or "static" (data/units/_schema.json "mobility"). A static unit (a radio
# tower, an anti-aircraft battery) never moves, turns or plans; see is_static().
var mobility: String = ""
var size_m: float = NAN
var actions_per_turn: int = 0
var health: int = 0
var sight_range_m: float = NAN
var silhouette: String = ""
# The validated envelope section as plain values (the curve as [speeds, deg/s]),
# and the Envelope built from it. envelope is null when the file is not ok().
var envelope_values: Dictionary = {}
var envelope: Envelope = null
# The unit's weapons (data/units/_schema.json "weapons"): one record per cone,
# each with one or more hardpoints. Empty when the file is not ok().
var weapons: Array[CombatWeapon] = []
var weapon_values: Array = []     # the validated weapons section as plain values (an Array of Dictionaries)
# What the unit can drop (data/units/_schema.json "bomb_load"): separate drops (passes) and
# bombs in a drop. 0 and 0 for a unit that carries no bombs.
var bomb_drops: int = 0
var bomb_per_drop: int = 0
var errors: Array[String] = []

static func path_for(type_id: String, units_dir: String = UNITS_DIR) -> String:
	return "%s/%s.json" % [units_dir, type_id]

# `band_order`: every band id bottom first, from data/sim/altitude.json
# (SimRules.band_ids). Band names in the unit file are checked against it.
func _init(unit_source: Variant, band_order: Array, quiet: bool = false, label: String = "") -> void:
	var data: Variant = null
	var stem := ""
	if unit_source is String:
		source = unit_source
		stem = (unit_source as String).get_file().get_basename()
	else:
		source = label if label != "" else "<unit dictionary>"
	var r := Records.new(source, quiet)
	if unit_source is String:
		data = r.read_json(unit_source)
	elif unit_source is Dictionary:
		data = unit_source
	else:
		r.err("a unit source is a path or a Dictionary, got %s" % type_string(typeof(unit_source)))
	var schema: Variant = Records.new(SCHEMA_PATH, quiet).read_json(SCHEMA_PATH)
	if not (schema is Dictionary) or not ((schema as Dictionary).get("fields") is Dictionary):
		r.err("the unit schema %s is missing or has no 'fields'" % SCHEMA_PATH)
	if data is Dictionary and schema is Dictionary and (schema as Dictionary).get("fields") is Dictionary:
		var v := _walk(r, (schema as Dictionary)["fields"], data, "", band_order)
		id = str(v.get("id", ""))
		name = str(v.get("name", ""))
		domain = str(v.get("domain", ""))
		mobility = str(v.get("mobility", ""))
		size_m = float(v.get("size_m", NAN))
		actions_per_turn = int(v.get("actions_per_turn", 0))
		health = int(v.get("health", 0))
		sight_range_m = float(v.get("sight_range_m", NAN))
		silhouette = str((v.get("drawing", {}) as Dictionary).get("silhouette", ""))
		envelope_values = v.get("envelope", {})
		weapon_values = v.get("weapons", [])
		var bomb_section: Dictionary = v.get("bomb_load", {})
		bomb_drops = int(bomb_section.get("drops", 0))
		bomb_per_drop = int(bomb_section.get("per_drop", 0))
		_check(r, stem)
	errors = r.errors
	if errors.is_empty():
		envelope = Envelope.new(envelope_values, band_order)
		for w: Dictionary in weapon_values:
			weapons.append(CombatWeapon.new(w))

func ok() -> bool:
	return errors.is_empty()

# A static unit never moves, turns or plans (the World refuses its plans and does not
# wait for it in the ready-up).
func is_static() -> bool:
	return mobility == "static"

# Does the unit carry bombs (a bomb_load with drops)?
func carries_bombs() -> bool:
	return bomb_drops > 0

# Walk one level of the schema: read every listed field by its kind, then
# reject keys the schema does not list. Returns the plain values.
static func _walk(r: Records, fields: Dictionary, data: Dictionary, prefix: String, band_order: Array) -> Dictionary:
	var out := {}
	for key: String in fields:
		var spec: Dictionary = fields[key]
		var label := prefix + key
		var kind := str(spec.get("kind", ""))
		match kind:
			"section":
				if data.get(key) is Dictionary:
					out[key] = _walk(r, spec.get("fields", {}), data[key], label + ".", band_order)
				else:
					r.err("missing section '%s'" % label)
			"text":
				out[key] = r.text(data, key, label)
			"enum":
				var s := r.text(data, key, label)
				var allowed: Array = spec.get("values", [])
				if s != "" and not allowed.has(s):
					r.err("'%s' = '%s' is not one of %s" % [label, s, str(allowed)])
				out[key] = s
			"number":
				out[key] = r.number(data, key, label, float(spec.get("min", -INF)), float(spec.get("max", INF)))
			"integer":
				out[key] = r.integer(data, key, label, int(spec.get("min", 0)))
			"bool":
				out[key] = r.boolean(data, key, label)
			"curve":
				out[key] = r.curve(data, key, label)
			"band_list":
				out[key] = r.id_list(data, key, label, band_order)
			"band":
				out[key] = r.id_value(data, key, label, band_order)
			"points3":
				out[key] = _points3(r, data, key, label)
			"list":
				# A list of objects, each walked against the schema's item_fields
				# (the weapons). The list itself is structure, not a tunable.
				var items: Array = []
				var raw: Variant = data.get(key)
				if raw is Array:
					for i in (raw as Array).size():
						if raw[i] is Dictionary:
							items.append(_walk(r, spec.get("item_fields", {}), raw[i], "%s[%d]." % [label, i], band_order))
						else:
							r.err("'%s[%d]' is not an object" % [label, i])
				else:
					r.err("missing list '%s'" % label)
				out[key] = items
			_:
				r.err("the schema gives '%s' an unknown kind '%s'" % [label, kind])
	for key: Variant in data:
		var k := str(key)
		if not k.begins_with("_") and not fields.has(k):
			r.err("unknown field '%s' (not in %s -- misspelt?)" % [prefix + k, SCHEMA_PATH])
	return out

# A value record holding a non-empty list of [forward, right, up] points, metres
# (a weapon's hardpoints). Finite numbers only.
static func _points3(r: Records, data: Dictionary, key: String, label: String) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var v: Variant = r.record(data, key, label)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		r.err("'%s' must be a non-empty list of [forward, right, up] points in metres" % label)
		return out
	for p: Variant in v:
		if not (p is Array) or (p as Array).size() != 3 or not Records.is_number(p[0]) or not Records.is_number(p[1]) or not Records.is_number(p[2]) \
				or not is_finite(float(p[0])) or not is_finite(float(p[1])) or not is_finite(float(p[2])):
			r.err("'%s' has a point that is not [forward, right, up] in finite numbers: %s" % [label, str(p)])
			continue
		out.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	return out

func _check(r: Records, stem: String) -> void:
	if stem != "" and id != "" and id != stem:
		r.err("id '%s' does not match the file name '%s.json'" % [id, stem])
	var e := envelope_values
	var vmin := float(e.get("speed_min_mps", NAN))
	var vcr := float(e.get("speed_cruise_mps", NAN))
	var vmax := float(e.get("speed_max_mps", NAN))
	var vdive := float(e.get("dive_speed_max_mps", NAN))
	if not (vmin <= vcr and vcr <= vmax and vmax <= vdive):
		r.err("envelope speeds must satisfy speed_min <= speed_cruise <= speed_max <= dive_speed_max, got %s <= %s <= %s <= %s" % [vmin, vcr, vmax, vdive])
	if mobility == "static":
		# A static unit has nothing to fly: every speed and rate is zero, it cannot change band.
		for k: String in ["speed_min_mps", "speed_cruise_mps", "speed_max_mps", "dive_speed_max_mps", "accel_mps2", "decel_mps2", "turn_bleed_mps2"]:
			var kv := float(e.get(k, 0.0))
			if not is_nan(kv) and kv != 0.0:
				r.err("a static unit never moves: envelope.%s must be 0, got %s" % [k, str(e.get(k))])
		if int(e.get("bands_per_step", 0)) != 0:
			r.err("a static unit never changes band: envelope.bands_per_step must be 0")
		var curve: Array = e.get("turn_rate_curve_dps", [PackedFloat64Array(), PackedFloat64Array()])
		for rate: float in (curve[1] as PackedFloat64Array):
			if rate != 0.0:
				r.err("a static unit never turns: envelope.turn_rate_curve_dps must be all 0, got %s" % str(rate))
	# Bombs (Alex 2026-10-10, decision bomb-load): a unit that drops anything has at least two
	# drops, and a drop of at least one bomb; one that drops nothing has neither.
	if bomb_drops == 1:
		r.err("bomb_load.drops = 1: a bomber has at least two drops (Alex 2026-10-10: multiple passes, everything gets at least two)")
	if (bomb_drops > 0) != (bomb_per_drop > 0):
		r.err("bomb_load: drops (%d) and per_drop (%d) are both 0 or both above 0" % [bomb_drops, bomb_per_drop])
	var bands: Array = e.get("altitude_bands", [])
	var start := str(e.get("start_band", ""))
	if start != "" and not bands.has(start):
		r.err("envelope.start_band '%s' is not one of the unit's altitude_bands %s" % [start, str(bands)])
	var seen: Array[String] = []
	for w: Variant in weapon_values:
		var wid := str((w as Dictionary).get("id", ""))
		if wid != "" and seen.has(wid):
			r.err("weapons: id '%s' is used twice" % wid)
		seen.append(wid)
