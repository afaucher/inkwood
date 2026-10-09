extends Node

# Autoload singleton: DebugSettings
# ----------------------------------
# The registry of debug knobs, and the values behind them. Carried over from
# Bridge to Friendship with the same API and the knobs this project does not
# have yet removed; its debug console and replication can follow when there is a
# world for them to act on.
#
# TO ADD A KNOB: append ONE entry to OPTIONS. Nothing else. A menu that walks
# this dictionary, a replication that sends whatever is in it, and the
# environment override all work for free.
#
# THIS FILE HOLDS THE VALUES. IT DOES NOT REPLICATE THEM. An RPC on an autoload
# travels over the DEFAULT peerless MultiplayerAPI, which a net harness that
# roots each world at its own SceneMultiplayer can never reach. The world owns
# the request/broadcast pair and writes the results in here.
#
# Every knob is also settable from the environment as INKWOOD_<KEY_UPPERCASE>,
# so a headless test or a sim run can flip one with no UI at all.

signal changed(key: String, value: Variant)

const KIND_CHOICE := "choice"
const KIND_BOOL := "bool"
const KIND_FLOAT := "float"
const KIND_INT := "int"

const OPTIONS := {
	# --- Diagnostics ---------------------------------------------------------
	"steam": {
		"section": "Diagnostics",
		"label": "Steam backend",
		"choices": ["auto", "off"],
		"default": 0,
		"help": "'off' skips Steam init entirely. INKWOOD_STEAM=off for a run that must not touch the Steam client; 'auto' tries and runs offline if no client answers.",
	},
	"net_log": {
		"section": "Diagnostics",
		"label": "Network log",
		"choices": ["off", "on"],
		"default": 0,
		"help": "Per-event print for peer connect/disconnect. Turned ON automatically when you HOST a networked session -- the default stays off so the gate stays quiet.",
	},
}

var _values: Dictionary = {}

func _ready() -> void:
	for key in OPTIONS:
		_values[key] = OPTIONS[key]["default"]
	_apply_env_overrides()

# --- Reading ------------------------------------------------------------------

# The read site for a shadowed constant: `DebugSettings.tuned("key", Config.KEY)`.
# The fallback is what an unregistered key returns, so a read site whose knob is
# later deleted keeps working on the constant rather than on zero.
func tuned(key: String, fallback: float) -> float:
	if not _values.has(key):
		return fallback
	return float(_values[key])

func get_choice(key: String) -> int:
	if not _values.has(key):
		printerr("[DebugSettings] unknown key: ", key)
		return 0
	return int(_values[key])

func get_choice_name(key: String) -> String:
	if not OPTIONS.has(key):
		return ""
	if kind_of(key) != KIND_CHOICE:
		return str(_values.get(key, ""))
	return str(OPTIONS[key]["choices"][get_choice(key)])

func is_on(key: String) -> bool:
	return get_choice(key) == 1

static func kind_of(key: String) -> String:
	if not OPTIONS.has(key):
		return KIND_CHOICE
	return str(OPTIONS[key].get("kind", KIND_CHOICE))

# A view knob changes what is drawn and nothing the simulation reads, so a
# client may apply it the instant it is clicked; a simulation knob waits for the
# host to apply it on a tick boundary.
static func is_view_only(key: String) -> bool:
	return bool(OPTIONS.get(key, {}).get("view_only", false))

static func section_of(key: String) -> String:
	return str(OPTIONS.get(key, {}).get("section", "Other"))

# Every key, grouped by section and stable in order.
static func sections() -> Dictionary:
	var out: Dictionary = {}
	for key in OPTIONS:
		var s: String = section_of(str(key))
		if not out.has(s):
			out[s] = []
		out[s].append(str(key))
	return out

# --- Writing ------------------------------------------------------------------

# ONE SETTER FOR EVERY KIND. Out of range is treated differently by kind, on
# purpose: choice/bool is REFUSED (index 99 into a two-item list is a caller
# bug), float/int is CLAMPED (these arrive from a slider and from the network,
# where the edge of the range is exactly what "as far as it goes" means).
func set_value(key: String, value: Variant) -> void:
	if not OPTIONS.has(key):
		printerr("[DebugSettings] unknown key: ", key)
		return
	var clean: Variant = _coerce(key, value)
	if clean == null:
		printerr("[DebugSettings] value ", value, " out of range for '", key, "'")
		return
	if _values.get(key, null) == clean:
		return
	_values[key] = clean
	changed.emit(key, clean)

func get_value(key: String) -> Variant:
	return _values.get(key, OPTIONS.get(key, {}).get("default", 0))

func set_choice(key: String, value: int) -> void:
	set_value(key, value)

# Returns the value to store, or null when it is not acceptable at all.
func _coerce(key: String, value: Variant) -> Variant:
	var entry: Dictionary = OPTIONS[key]
	match kind_of(key):
		KIND_FLOAT:
			return clampf(float(value), float(entry.get("min", -INF)), float(entry.get("max", INF)))
		KIND_INT:
			# Plain literals: GDScript refuses `-1 << 30` outright, and a parse
			# error in an AUTOLOAD makes the singleton Nil everywhere.
			return clampi(int(value), int(entry.get("min", -1000000000)), int(entry.get("max", 1000000000)))
		KIND_BOOL:
			var b := int(value)
			return b if b == 0 or b == 1 else null
		_:
			var choices: Array = entry["choices"]
			var i := int(value)
			return i if i >= 0 and i < choices.size() else null

# --- The whole config, for replication ----------------------------------------

func snapshot() -> Dictionary:
	return _values.duplicate()

func apply_snapshot(values: Dictionary) -> void:
	for key in values:
		set_value(str(key), values[key])

# --- Environment overrides ----------------------------------------------------

# INKWOOD_NET_LOG=1, INKWOOD_STEAM=off. Accepts a choice NAME as well as an
# index, because remembering that "on" is 1 is exactly the kind of thing that
# goes wrong at 2am. An unknown value is reported and ignored rather than
# silently dropped.
func _apply_env_overrides() -> void:
	for key in OPTIONS:
		# Explicitly typed, not inferred: `key` comes from iterating a Dictionary
		# so it is a Variant, and `:=` on an expression built from one is a parse
		# error ("cannot infer the type"), not a runtime problem.
		var name: String = str(key)
		var env_name: String = "INKWOOD_" + name.to_upper()
		if not OS.has_environment(env_name):
			continue
		var raw := OS.get_environment(env_name).strip_edges()
		var parsed: Variant = _parse_env(name, raw)
		if parsed == null:
			printerr("[DebugSettings] ", env_name, "=", raw, " is not valid for '", name, "'")
			continue
		set_value(name, parsed)
		print("[DebugSettings] ", name, " = ", get_choice_name(name), " (from ", env_name, ")")

# Verbatim from Bridge to Friendship: a bool takes on/true/yes and off/false/no
# as well as 0/1, and a choice index is range-checked HERE so an out-of-range
# override is reported as invalid rather than refused later by set_value with
# the "applied" line already printed.
func _parse_env(key: String, raw: String) -> Variant:
	match kind_of(key):
		KIND_FLOAT:
			return float(raw) if raw.is_valid_float() else null
		KIND_INT:
			return int(raw) if raw.is_valid_int() else null
		KIND_BOOL:
			if raw in ["on", "true", "yes"]:
				return 1
			if raw in ["off", "false", "no"]:
				return 0
			return int(raw) if raw.is_valid_int() else null
		_:
			var choices: Array = OPTIONS[key]["choices"]
			var idx: int = choices.find(raw)
			if idx == -1 and raw.is_valid_int():
				idx = int(raw)
			return idx if idx >= 0 and idx < choices.size() else null
