extends RefCounted

# Reads one of Track F's view files -- data/view/camera.json or data/view/fog.json
# (working rule 4: values live in data, code reads them) -- and RECORDS EVERY
# FIELD IT HANDS OUT, so the gate can prove a file carries nothing the code
# ignores (test_fog / test_camera: unused() must come back empty once the
# readers have run). It lives under scripts/world/camera* because that is
# Track F's folder on this side; the fog code (scripts/render/fog*) uses it too.
#
#   var d := CameraData.new(CameraData.CAMERA_PATH)
#   d.num("zoom.max")   d.text("far_zoom.mode")   d.value("zoom.min")  # any type
#
# Record shape (shared with data/terrain/terrain.json and data/sim/turn.json):
# a tunable is { "value": ..., "_proposed": true, "_reason": "..." }; keys that
# start with "_" are documentation and never read; a path is dot-separated.
# A missing or mistyped field is recorded in `errors` (and pushed), never
# defaulted in code.

const CAMERA_PATH := "res://data/view/camera.json"
const FOG_PATH := "res://data/view/fog.json"

var source_path: String
var root: Dictionary = {}
var errors: Array[String] = []
var _used: Dictionary = {}  # path -> true

func _init(path: String) -> void:
	source_path = path
	if not FileAccess.file_exists(path):
		_err("view data file missing: %s" % path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		_err("view data does not parse as a JSON object: %s" % path)
		return
	root = parsed

func ok() -> bool:
	return errors.is_empty()

# The record's value at `path` (the node itself when it is not a record).
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

func has(path: String) -> bool:
	var node: Variant = root
	for part in path.split("."):
		if not (node is Dictionary) or not (node as Dictionary).has(part):
			return false
		node = (node as Dictionary)[part]
	return true

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

func flag(path: String) -> bool:
	var v: Variant = value(path)
	if v is bool:
		return v
	_err("field '%s' is not true/false in %s" % [path, source_path])
	return false

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

func floats(path: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for v: Variant in list(path):
		if v is float or v is int:
			out.append(float(v))
		else:
			_err("field '%s' holds a non-number in %s" % [path, source_path])
	return out

func dict(path: String) -> Dictionary:
	var v: Variant = value(path)
	if v is Dictionary:
		return v
	_err("field '%s' is not an object in %s" % [path, source_path])
	return {}

# Every record path in the file (a node with "value", or a leaf) that no read
# has asked for. Empty once every reader has run: the file holds nothing dead.
func unused() -> Array[String]:
	var out: Array[String] = []
	_walk(root, "", out)
	return out

func _walk(node: Dictionary, prefix: String, out: Array[String]) -> void:
	for k: String in node:
		if k.begins_with("_"):
			continue
		var path := k if prefix == "" else prefix + "." + k
		var child: Variant = node[k]
		if child is Dictionary and not (child as Dictionary).has("value"):
			_walk(child, path, out)
		elif not _used.has(path):
			out.append(path)

func _err(message: String) -> void:
	errors.append(message)
	push_error("CameraData: " + message)
