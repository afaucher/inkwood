extends RefCounted

# Reads the simulation's data files (data/units/*.json, data/sim/*.json) and
# records what is wrong with them. Shared by unit_def.gd, sim_rules.gd and
# ai_dumb.gd so every sim file is read under the same rules:
#
#   - A MISSING FIELD IS AN ERROR, NEVER A DEFAULT. Working rule 4 puts values
#     in data; a default in code is a value in code that nobody can see is
#     being used. Each getter returns a harmless placeholder (NAN, "", []) so the
#     caller can keep going and report EVERY problem in one pass, and `errors`
#     says the result must not be used.
#   - EVERY TUNABLE IS A VALUE RECORD: {"value": v, "_proposed": true,
#     "_reason": "..."} while it is a placeholder, {"value": v, "decision":
#     "<id>"} once data/decisions/decisions.json holds the choice. A record with
#     neither is an error, so a number cannot enter the game without saying
#     where it came from (working rules 2 and 3). See data/units/_schema.json.
#
# `quiet` suppresses push_error for the tests that feed it broken data on
# purpose, so their .err.log is not full of expected noise; the errors are
# still recorded.

var source: String
var quiet: bool = false
var errors: Array[String] = []

func _init(source_label: String, quiet_errors: bool = false) -> void:
	source = source_label
	quiet = quiet_errors

func ok() -> bool:
	return errors.is_empty()

func err(message: String) -> void:
	var line := "%s: %s" % [source, message]
	errors.append(line)
	if not quiet:
		push_error(line)

# The parsed JSON at `path`, or null (with an error recorded) if it is missing
# or does not parse to an object.
func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		err("file missing: %s" % path)
		return null
	var root: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (root is Dictionary):
		err("does not parse as a JSON object: %s" % path)
		return null
	return root

# --- Plain fields ------------------------------------------------------------

func section(d: Dictionary, key: String, label: String) -> Dictionary:
	var v: Variant = d.get(key)
	if v is Dictionary:
		return v
	err("missing section '%s'" % label)
	return {}

func text(d: Dictionary, key: String, label: String) -> String:
	var v: Variant = d.get(key)
	if v is String and v != "":
		return v
	err("missing text '%s'" % label)
	return ""

# --- Value records -----------------------------------------------------------

# The value inside the record at d[key], or null. Checks the record's
# provenance: _proposed with a reason, or a decision id.
func record(d: Dictionary, key: String, label: String) -> Variant:
	if not d.has(key):
		err("missing field '%s'" % label)
		return null
	var rec: Variant = d[key]
	if not (rec is Dictionary) or not (rec as Dictionary).has("value"):
		err("'%s' is not a value record ({\"value\": ..., \"_proposed\": true, \"_reason\": ...})" % label)
		return null
	var r: Dictionary = rec
	var flag: Variant = r.get("_proposed", false)
	var proposed: bool = flag is bool and flag
	var reason: Variant = r.get("_reason", "")
	var decision: Variant = r.get("decision", "")
	var has_reason: bool = reason is String and (reason as String).strip_edges() != ""
	var has_decision: bool = decision is String and (decision as String).strip_edges() != ""
	if not has_decision and not (proposed and has_reason):
		err("'%s' says neither where it came from nor why: needs \"_proposed\": true with a \"_reason\", or a \"decision\" id" % label)
	return r["value"]

static func is_number(v: Variant) -> bool:
	return v is float or v is int

func number(d: Dictionary, key: String, label: String, min_value: float = -INF, max_value: float = INF) -> float:
	var v: Variant = record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return NAN
	if not is_number(v):
		err("'%s' must be a number, got %s" % [label, type_string(typeof(v))])
		return NAN
	var f := float(v)
	if f < min_value or f > max_value:
		err("'%s' = %s is outside [%s, %s]" % [label, str(f), str(min_value), str(max_value)])
	return f

func integer(d: Dictionary, key: String, label: String, min_value: int = 0) -> int:
	var v: Variant = record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return 0
	# JSON numbers may arrive as float; a whole float is a whole number.
	if not is_number(v) or float(v) != floorf(float(v)):
		err("'%s' must be a whole number, got %s" % [label, str(v)])
		return 0
	var i := int(v)
	if i < min_value:
		err("'%s' = %d is below %d" % [label, i, min_value])
	return i

func boolean(d: Dictionary, key: String, label: String) -> bool:
	var v: Variant = record(d, key, label)
	if v is bool:
		return v
	if typeof(v) != TYPE_NIL:
		err("'%s' must be true or false, got %s" % [label, str(v)])
	return false

# [[x, y], ...] with x strictly increasing and y >= 0 -- the turn-rate curve.
# Returned as two parallel PackedFloat64Arrays [xs, ys].
func curve(d: Dictionary, key: String, label: String) -> Array:
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var v: Variant = record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return [xs, ys]
	if not (v is Array) or (v as Array).is_empty():
		err("'%s' must be a non-empty list of [speed, value] points" % label)
		return [xs, ys]
	for p: Variant in v:
		if not (p is Array) or (p as Array).size() != 2 or not is_number(p[0]) or not is_number(p[1]):
			err("'%s' has a point that is not [number, number]: %s" % [label, str(p)])
			continue
		var px := float(p[0])
		var py := float(p[1])
		if not xs.is_empty() and px <= xs[xs.size() - 1]:
			err("'%s' speeds must strictly increase (%s after %s)" % [label, str(px), str(xs[xs.size() - 1])])
		if py < 0.0:
			err("'%s' values must be >= 0, got %s" % [label, str(py)])
		xs.append(px)
		ys.append(py)
	return [xs, ys]

# A list of ids, each one of `allowed` (vertical order of data/sim/altitude.json),
# no repeats.
func id_list(d: Dictionary, key: String, label: String, allowed: Array) -> Array[String]:
	var out: Array[String] = []
	var v: Variant = record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		err("'%s' must be a non-empty list" % label)
		return out
	for item: Variant in v:
		var s := str(item)
		if not (item is String) or not allowed.has(s):
			err("'%s' names '%s', which is not one of %s" % [label, s, str(allowed)])
		elif out.has(s):
			err("'%s' names '%s' twice" % [label, s])
		else:
			out.append(s)
	return out

func id_value(d: Dictionary, key: String, label: String, allowed: Array) -> String:
	var v: Variant = record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return ""
	if not (v is String) or not allowed.has(v):
		err("'%s' = '%s' is not one of %s" % [label, str(v), str(allowed)])
		return ""
	return v
