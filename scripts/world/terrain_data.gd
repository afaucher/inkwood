extends RefCounted

# Reads data/terrain/terrain.json (working rule 4: values live in data, code
# reads them) and RECORDS EVERY FIELD IT HANDS OUT, so the gate can prove that
# the file carries nothing the code ignores (scripts/tests/test_terrain.gd:
# `unused()` must come back empty once Terrain and TerrainDraw have both read
# their sections).
#
# Record shape, shared with data/sim/turn.json: a tunable is
#   { "value": <number | string | array | object>, "_proposed": true, "_reason": "..." }
# and keys starting with "_" are documentation, never read. A path is
# dot-separated: "height.thresholds", "draw.hachures.spacing_px".
#
# A missing or mistyped field is recorded in `errors` (and pushed), never
# defaulted in code -- the same contract as RenderParams.

const DEFAULT_PATH := "res://data/terrain/terrain.json"

var source_path: String
var root: Dictionary = {}
var errors: Array[String] = []
var _used: Dictionary = {}  # path -> true

func _init(path: String = DEFAULT_PATH) -> void:
	source_path = path
	if not FileAccess.file_exists(path):
		_err("terrain data file missing: %s" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		_err("terrain data does not parse as a JSON object: %s" % path)
		return
	root = parsed

func ok() -> bool:
	return errors.is_empty()

# The record's value at `path` (the record itself when it is a plain value).
func value(path: String) -> Variant:
	var node: Variant = root
	for part in path.split("."):
		if not (node is Dictionary) or not (node as Dictionary).has(part):
			_err("missing field '%s' in %s" % [path, source_path])
			return null
		node = (node as Dictionary)[part]
	_used[path] = true
	if node is Dictionary and (node as Dictionary).has("value"):
		return (node as Dictionary)["value"]
	return node

func num(path: String) -> float:
	var v: Variant = value(path)
	if v is float or v is int:
		return float(v)
	_err("field '%s' is not a number in %s" % [path, source_path])
	return NAN

func integer(path: String) -> int:
	var v: Variant = value(path)
	if (v is float or v is int) and float(v) == floorf(float(v)):
		return int(v)
	_err("field '%s' is not an integer in %s" % [path, source_path])
	return 0

func text(path: String) -> String:
	var v: Variant = value(path)
	if v is String:
		return v
	_err("field '%s' is not a string in %s" % [path, source_path])
	return ""

func list(path: String) -> Array:
	var v: Variant = value(path)
	if v is Array:
		return v
	_err("field '%s' is not an array in %s" % [path, source_path])
	return []

func dict(path: String) -> Dictionary:
	var v: Variant = value(path)
	if v is Dictionary:
		return v
	_err("field '%s' is not an object in %s" % [path, source_path])
	return {}

func floats(path: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for v: Variant in list(path):
		if v is float or v is int:
			out.append(float(v))
		else:
			_err("field '%s' holds a non-number in %s" % [path, source_path])
	return out

# Every leaf path in the file -- a value record or a plain value, keys with a
# leading "_" skipped -- that nobody has read.
func unused() -> Array[String]:
	var all: Array[String] = []
	_leaves(root, "", all)
	var out: Array[String] = []
	for p in all:
		if not _used.has(p):
			out.append(p)
	return out

static func _leaves(node: Variant, prefix: String, out: Array[String]) -> void:
	if node is Dictionary:
		var d: Dictionary = node
		if d.has("value") and prefix != "":
			out.append(prefix)
			return
		for k: String in d:
			if k.begins_with("_"):
				continue
			_leaves(d[k], k if prefix == "" else prefix + "." + k, out)
	elif prefix != "":
		out.append(prefix)

func _err(message: String) -> void:
	errors.append(message)
	push_error("TerrainData: " + message)
