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
	"autostart": {
		"section": "Diagnostics",
		"label": "Autostart",
		"choices": ["off", "local", "local_shot", "host", "join", "host_shot", "join_shot", "host_game", "join_game"],
		"default": 0,
		"help": "'local' presses the menu's Local button at launch; 'local_shot' also saves one frame of the running sandbox (INKWOOD_SHOT_OUT, else user://autostart.png) once it is playable, and quits. For checking an exported build without a tool that drives the window. 'host' / 'join' press Host / Join the same way (the transport is the 'net' knob); 'host_shot' / 'join_shot' also run the two-window check (proposed, Track N): wait for the other window, plan one plane each, wait until each window shows the other's plan, save a frame to INKWOOD_SHOT_OUT and quit. 'host_game' / 'join_game' (Track A, proposed) play the first fight to its END in the two windows (a frame of the result card in each), then Play again from the joiner, and a frame of the new game.",
	},
	# --- Network (Track N, proposed) -----------------------------------------------
	"net": {
		"section": "Network",
		"label": "Transport",
		"choices": ["steam", "enet"],
		"default": 0,
		"help": "What Host and Join use. 'steam' is what ships (a Steam lobby; Join takes the first global lobby it finds). 'enet' is plain UDP: two windows on one machine, no Steam client needed. INKWOOD_NET=enet; Join connects to INKWOOD_NET_ADDRESS (default 127.0.0.1) on the 'net_port' knob.",
	},
	"net_port": {
		"section": "Network",
		"label": "ENet port",
		"kind": "int",
		"default": 27015,
		"min": 1024,
		"max": 65535,
		"help": "The UDP port Host binds and Join connects to when the transport is 'enet' (NetworkManager.DEFAULT_PORT). INKWOOD_NET_PORT=28790.",
	},
	# --- Scenario (Track A, first fight; Track A2 added the strike, proposed) ---------------
	"scenario": {
		"section": "Sandbox",
		"label": "Scenario",
		"choices": ["intercept", "sandbox", "strike"],
		"default": 2,
		"help": "Which data/scenarios/<id>.json Local, Host and Join start. 'strike' (the default, proposed: the newest layer) is the bombing mission: a bomber and two fighters against a radio tower in a village, its two flak batteries and a patrolling fighter; 'intercept' is the first fight (an AI bomber and its escort); 'sandbox' is the old flight toy (AiDumb, no mission). The menu's selector sets this knob. Read when a game is built, so set it before pressing Local: INKWOOD_SCENARIO=intercept. Not a live knob (it is not on the F2 panel). Indexes 0 and 1 are the two older scenarios, in the order the tests set them.",
	},
	# --- Sandbox knobs (Track A; the F2 panel shows them) ---------------------------
	# Index 0 is always "data": whatever the data files say (data/scenarios/
	# sandbox.json view, data/terrain/terrain.json, data/view/*.json,
	# render_defaults.json), so no default is written twice. INKWOOD_<KEY>=<choice
	# name> sets one from the command line. All view-only.
	"map_scale": {
		"section": "Sandbox",
		"label": "Map scale (px per m)",
		"choices": ["data", "1", "2", "3", "4"],
		"default": 0,
		"view_only": true,
		"help": "Map pixels per metre, live: the map is redrawn (8-11 s) with no restart. data = data/terrain/terrain.json (2, Alex's starting value).",
	},
	"plane_size": {
		"section": "Sandbox",
		"label": "Plane size (px)",
		"choices": ["data", "true", "24", "36", "54", "72"],
		"default": 0,
		"view_only": true,
		"help": "How big a light fighter draws at zoom 1 whatever the map scale, in px; 'true' draws planes at the map's own scale. The other types follow in proportion. data = scenario view.plane_px.",
	},
	"fog": {
		"section": "Sandbox",
		"label": "Fog of war",
		"choices": ["data", "on", "off"],
		"default": 0,
		"view_only": true,
		"help": "The fog layer and the hiding of units outside sight. data = scenario view.fog.",
	},
	"fog_edge": {
		"section": "Sandbox",
		"label": "Fog edge",
		"choices": ["data", "inked", "soft"],
		"default": 0,
		"view_only": true,
		"help": "How the edge of sight is drawn. data = data/view/fog.json edge.mode (inked, Alex's choice).",
	},
	"line_of_sight": {
		"section": "Sandbox",
		"label": "Line of sight",
		"choices": ["data", "none", "terrain"],
		"default": 0,
		"view_only": true,
		"help": "What blocks sight: nothing, or terrain. Trees do not block sight for now (Alex 2026-10-09: data/view/fog.json vision.trees_block is false, so terrain_trees would behave as terrain and is not offered). data = data/view/fog.json vision.line_of_sight (none).",
	},
	"pen": {
		"section": "Sandbox",
		"label": "Pen line",
		"choices": ["data", "even", "shadow_side"],
		"default": 0,
		"view_only": true,
		"help": "Ink line width along a stroke; the map is redrawn after a change. data = render_defaults.json linework.pen.mode (shadow_side, Alex's choice).",
	},
	"far_zoom": {
		"section": "Sandbox",
		"label": "Far zoom",
		"choices": ["data", "overview_topo", "full_render"],
		"default": 0,
		"view_only": true,
		"help": "What the map shows fully zoomed out: the topographic overview, or the full render with zoom-out limited. data = data/view/camera.json far_zoom.mode.",
	},
	"tree_pool": {
		"section": "Sandbox",
		"label": "Tree pool",
		"choices": ["data", "off", "on"],
		"default": 0,
		"view_only": true,
		"help": "Shared tree sprites instead of one per tree (changes the look; the map is redrawn). data = render_defaults.json map_view.tree_pool.enabled.",
	},
	"playback_speed": {
		"section": "Sandbox",
		"label": "Turn playback speed",
		"choices": ["data", "1", "2", "4", "8"],
		"default": 0,
		"view_only": true,
		"help": "Turn-seconds played per real second when a turn resolves. data = data/ui/ui.json marker.playback_speed.",
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
