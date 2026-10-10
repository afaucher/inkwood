extends RefCounted

# data/fx/fx.json, read (working rule 4: gameplay and style values live in data).
# EVERY VALUE IN THAT FILE IS A PROPOSED VALUE RECORD ({"value", "_proposed": true,
# "_reason"}), made by Track X on 2026-10-09 for the variant boards
# variants/damage-smoke/ and variants/crash-explosion/; none is a decision until
# Alex chooses and data/decisions/decisions.json records it.
#
#   var d := FxData.shared()
#   d.common("max_puffs")                  # a number from fx.json common
#   var o := d.smoke_option("A")           # one option's parameters, UNWRAPPED
#   var c := d.crash_option("A")           # {"midair": {...}, "falling": {...}, "impact": {...}}
#   FxData.f(o, "interval_s")              # a required number: a missing key is an ERROR
#
# A key the code asks for that the file does not hold is an error (recorded in
# `errors` and pushed once), never a default in code: the getter returns 0 / ""
# / [] so the caller can go on and every problem shows in one run.

const FX_PATH := "res://data/fx/fx.json"

var raw: Dictionary = {}
var errors: Array[String] = []

static var _shared: RefCounted = null
static var _warned: Dictionary = {}

static func shared() -> RefCounted:
	if _shared == null:
		_shared = load("res://scripts/fx/fx_data.gd").new()
	return _shared

func _init(path: String = FX_PATH) -> void:
	if not FileAccess.file_exists(path):
		_err("file missing: %s" % path)
		return
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (v is Dictionary):
		_err("does not parse as a JSON object: %s" % path)
		return
	raw = v

func ok() -> bool:
	return errors.is_empty()

# --- Unwrapping ---------------------------------------------------------------------------

# A value record gives its "value"; a group is unwrapped member by member, its
# "_" keys (about, reason, proposed) dropped.
static func unwrap(v: Variant) -> Variant:
	if v is Dictionary:
		var d: Dictionary = v
		if d.has("value"):
			return d["value"]
		var out := {}
		for k: String in d:
			if not k.begins_with("_"):
				out[k] = unwrap(d[k])
		return out
	return v

func common(key: String) -> Variant:
	var sec: Variant = raw.get("common")
	if sec is Dictionary and (sec as Dictionary).has(key):
		return unwrap((sec as Dictionary)[key])
	_err_once("common:" + key, "fx.json common has no '%s'" % key)
	return 0.0

func common_num(key: String) -> float:
	return float(common(key))

# The role record of a colour role (raw: FxStyle resolves it).
func role(name: String) -> Dictionary:
	var sec: Variant = raw.get("roles")
	if sec is Dictionary and (sec as Dictionary).get(name) is Dictionary:
		return (sec as Dictionary)[name]
	return {}

func role_names() -> Array:
	var out: Array = []
	var sec: Variant = raw.get("roles")
	if sec is Dictionary:
		for k: String in sec:
			if not k.begins_with("_"):
				out.append(k)
	return out

# The fire machinery's switch (Alex 2026-10-10: "No fire for now. Just smoke."). Off: no flash, flames, embers or
# fireball are drawn or made; a mid-air explosion and a crash are smoke events. The machinery stays in the code.
func fire_enabled() -> bool:
	var sec: Variant = raw.get("fire_switch")
	if sec is Dictionary:
		var v: Variant = unwrap((sec as Dictionary).get("enabled"))
		if v is bool:
			return v
	_err_once("fire_switch", "fx.json fire_switch.enabled is not true/false")
	return false

func fire_oklch() -> Array:
	var acc: Variant = raw.get("accents")
	if acc is Dictionary and (acc as Dictionary).get("fire") is Dictionary:
		var f: Variant = unwrap(((acc as Dictionary)["fire"] as Dictionary).get("oklch"))
		if f is Array and (f as Array).size() == 3:
			return f
	_err_once("fire", "fx.json accents.fire.oklch is not [L, C, h]")
	return [0.7, 0.14, 56.0]

func smoke_option_names() -> Array:
	return _option_names("smoke")

# Round 2 of the damage smoke (variants/damage-smoke-r2/): C0 is round 1's option C as it was,
# C1..C6 change what makes it read as a tree. smoke_option() finds them by name too.
func smoke_r2_option_names() -> Array:
	return _option_names("smoke_r2")

func crash_option_names() -> Array:
	return _option_names("crash")

func _option_names(kind: String) -> Array:
	var out: Array = []
	var sec: Variant = raw.get(kind)
	if sec is Dictionary and (sec as Dictionary).get("options") is Dictionary:
		for k: String in (sec as Dictionary)["options"]:
			if not k.begins_with("_"):
				out.append(k)
	return out

# The option the layer runs until Alex chooses. NOT a decision.
func working_default(kind: String) -> String:
	var sec: Variant = raw.get("working_default")
	if sec is Dictionary and (sec as Dictionary).has(kind):
		return str(unwrap((sec as Dictionary)[kind]))
	_err_once("wd:" + kind, "fx.json working_default has no '%s'" % kind)
	return "A"

func smoke_option(name: String) -> Dictionary:
	if _has_option("smoke_r2", name) and not _has_option("smoke", name):
		return _option("smoke_r2", name)
	return _option("smoke", name)

func _has_option(kind: String, name: String) -> bool:
	var sec: Variant = raw.get(kind)
	return sec is Dictionary and (sec as Dictionary).get("options") is Dictionary and ((sec as Dictionary)["options"] as Dictionary).has(name)

func crash_option(name: String) -> Dictionary:
	return _option("crash", name)

func option_label(kind: String, name: String) -> String:
	if kind == "smoke" and _has_option("smoke_r2", name) and not _has_option("smoke", name):
		kind = "smoke_r2"
	var sec: Variant = raw.get(kind)
	if sec is Dictionary and (sec as Dictionary).get("options") is Dictionary:
		var o: Variant = ((sec as Dictionary)["options"] as Dictionary).get(name)
		if o is Dictionary:
			return str((o as Dictionary).get("_label", name))
	return name

func option_note(kind: String, name: String) -> String:
	if kind == "smoke" and _has_option("smoke_r2", name) and not _has_option("smoke", name):
		kind = "smoke_r2"
	var sec: Variant = raw.get(kind)
	if sec is Dictionary and (sec as Dictionary).get("options") is Dictionary:
		var o: Variant = ((sec as Dictionary)["options"] as Dictionary).get(name)
		if o is Dictionary:
			return str((o as Dictionary).get("_note", ""))
	return ""

func _option(kind: String, name: String) -> Dictionary:
	var sec: Variant = raw.get(kind)
	if sec is Dictionary and (sec as Dictionary).get("options") is Dictionary:
		var o: Variant = ((sec as Dictionary)["options"] as Dictionary).get(name)
		if o is Dictionary:
			return unwrap(o)
	_err_once("opt:%s:%s" % [kind, name], "fx.json %s has no option '%s'" % [kind, name])
	return {}

# --- Required getters over an unwrapped option ----------------------------------------------

static func f(o: Dictionary, key: String) -> float:
	var v: Variant = o.get(key)
	if v is float or v is int:
		return float(v)
	_missing(key, "number")
	return 0.0

static func i(o: Dictionary, key: String) -> int:
	return int(f(o, key))

static func b(o: Dictionary, key: String) -> bool:
	var v: Variant = o.get(key)
	if v is bool:
		return v
	_missing(key, "true/false")
	return false

static func s(o: Dictionary, key: String) -> String:
	var v: Variant = o.get(key)
	if v is String:
		return v
	_missing(key, "string")
	return ""

static func arr(o: Dictionary, key: String) -> Array:
	var v: Variant = o.get(key)
	if v is Array:
		return v
	_missing(key, "list")
	return []

static func grp(o: Dictionary, key: String) -> Dictionary:
	var v: Variant = o.get(key)
	if v is Dictionary:
		return v
	_missing(key, "group")
	return {}

# A [lo, hi] pair of an option, lerped at t.
static func lerp_pair(o: Dictionary, key: String, t: float) -> float:
	var a := arr(o, key)
	if a.size() != 2:
		_missing(key, "[lo, hi]")
		return 0.0
	return lerpf(float(a[0]), float(a[1]), t)

static func _missing(key: String, what: String) -> void:
	var k := "missing:" + key + what
	if _warned.has(k):
		return
	_warned[k] = true
	push_error("FxData: fx.json option has no %s '%s'" % [what, key])
	(shared() as RefCounted).errors.append("option has no %s '%s'" % [what, key])

func _err(message: String) -> void:
	errors.append(message)
	push_error("FxData: " + message)

func _err_once(key: String, message: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	_err(message)
