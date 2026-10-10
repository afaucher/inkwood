extends RefCounted

# A scenario file (data/scenarios/<id>.json) read and checked: the seed, the
# sides, the units with their callsigns, and the view values the sandbox shows
# it with. Pure data -- no nodes -- so the gate can read a scenario without
# standing a game up (scripts/tests/test_sandbox.gd).
#
#   var sc := SandboxScenario.new("sandbox")
#   if not sc.ok(): ...                     # sc.errors lists every problem at once
#   sc.populate(world)                      # add_player + add_unit for each unit
#   sc.view_value("plane_px")               # a value record's value
#
# A MISSING FIELD IS AN ERROR, NEVER A DEFAULT (working rule 4, as in
# scripts/sim/records.gd): a getter returns a harmless placeholder and records
# the problem, so every one shows in a single run.
#
# CALLSIGNS (Alex 2026-10-09, data/names/callsigns.json): a unit's "callsign" is
# a string, or "pool" -- the first name in its side's pool for its type that no
# earlier unit of the scenario took. A scenario never invents a name.
#
# THE FIRST FIGHT (Track A, proposed): a scenario also says which AI flies its
# AI-controlled units and which mission judges the game --
#
#   "rng_seed": 7                          the World's combat seed (World.rng_seed); populate() sets it
#   "briefing": "..."                      (optional) the line the sandbox shows at the start
#   "ai": {"kind": "dumb"}                 the old sandbox's AiDumb (scripts/sim/ai_dumb.gd), or
#   "ai": {"kind": "pilot", "assignments": {"bomber_1": {"role": "strike", "route": [[x, y], ...],
#          "target": [x, y]}, "escort_1": {"role": "escort", "protect": "bomber_1"}}}
#                                          AiPilot (scripts/sim/ai_pilot.gd): the assignments are
#                                          its attach() argument; each names a unit by an explicit id
#   "mission": {win/lose spec}             (optional) scripts/sim/mission.gd's spec, e.g. Intercept's;
#                                          none = no mission, the game never ends (the old sandbox)
#
#   var ai := sc.make_ai(world)            # an AiDumb or AiPilot for `world`, NOT attached
#   sc.ai_attach(ai, world)                # the caller attaches: on the host or locally, never on a client
#   var mission := sc.make_mission(world)  # a Mission for `world`, NOT attached, or null
#
# Keys that begin with "_" (_proposed, _reason, ...) are notes and are dropped from the
# ai and mission blocks.

const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")
const Mission = preload("res://scripts/sim/mission.gd")

const SCENARIO_DIR := "res://data/scenarios"
const CALLSIGNS_PATH := "res://data/names/callsigns.json"
const AI_DUMB := "dumb"
const AI_PILOT := "pilot"

var id: String = ""
var path: String = ""
var seed_value: int = 0
var rng_seed: int = 0                 # the World's combat seed
var briefing: String = ""             # (optional) the line shown at the start
var ai_kind: String = ""              # AI_DUMB or AI_PILOT
var ai_assignments: Dictionary = {}   # unit id -> orders, for AI_PILOT
var mission_spec: Dictionary = {}     # scripts/sim/mission.gd's spec; {} = no mission
var local_player: String = ""
var sides: Dictionary = {}            # scenario side -> {world_side, callsign_pool}
var units: Array[Dictionary] = []     # World.add_unit specs, callsigns resolved
var view: Dictionary = {}             # name -> value (value records flattened)
var errors: Array[String] = []

func _init(scenario_id: String = "sandbox", quiet: bool = false) -> void:
	id = scenario_id
	path = "%s/%s.json" % [SCENARIO_DIR, scenario_id]
	var raw: Variant = _read(path, quiet)
	if not (raw is Dictionary):
		return
	var d: Dictionary = raw
	seed_value = int(_num(d, "seed", quiet))
	rng_seed = int(_num(d, "rng_seed", quiet))
	local_player = _str(d, "local_player", quiet)
	if d.has("briefing"):
		briefing = _str(d, "briefing", quiet)
	var sd: Variant = d.get("sides")
	if sd is Dictionary:
		for k: String in sd:
			if k.begins_with("_"):
				continue
			var s: Variant = (sd as Dictionary)[k]
			if s is Dictionary and (s as Dictionary).get("world_side") is String and (s as Dictionary).get("callsign_pool") is String:
				sides[k] = s
			else:
				_err("sides.%s needs world_side and callsign_pool strings" % k, quiet)
	else:
		_err("no 'sides' object", quiet)
	var pools: Variant = _read(CALLSIGNS_PATH, quiet)
	var taken: Dictionary = {}
	var ul: Variant = d.get("units")
	if not (ul is Array) or (ul as Array).is_empty():
		_err("'units' must be a non-empty list", quiet)
	else:
		for i in (ul as Array).size():
			var u: Variant = (ul as Array)[i]
			if u is Dictionary:
				units.append(_unit_spec(u, i, pools, taken, quiet))
			else:
				_err("units[%d] is not an object" % i, quiet)
	_read_ai(d, quiet)
	if d.has("mission"):
		var md: Variant = d["mission"]
		if md is Dictionary:
			mission_spec = _strip(md)
		else:
			_err("'mission' must be an object", quiet)
	var vd: Variant = d.get("view")
	if vd is Dictionary:
		for k: String in vd:
			if k.begins_with("_"):
				continue
			var v: Variant = (vd as Dictionary)[k]
			view[k] = (v as Dictionary).get("value") if v is Dictionary and (v as Dictionary).has("value") else v
	else:
		_err("no 'view' object", quiet)

func ok() -> bool:
	return errors.is_empty()

# The value of one 'view' record. Missing is an error and returns `null`.
func view_value(name: String) -> Variant:
	if not view.has(name):
		_err("view.%s is missing" % name, false)
		return null
	return view[name]

func view_num(name: String) -> float:
	var v: Variant = view_value(name)
	if v is float or v is int:
		return float(v)
	_err("view.%s is not a number" % name, false)
	return NAN

func view_flag(name: String) -> bool:
	var v: Variant = view_value(name)
	if v is bool:
		return v
	_err("view.%s is not true/false" % name, false)
	return false

# Fill a World: the local player and every unit (side names translated to the
# World's), and the combat seed. Returns the unit ids in scenario order, "" for one
# that failed.
func populate(world: Object) -> Array[String]:
	var ids: Array[String] = []
	world.rng_seed = rng_seed
	world.add_player(local_player)
	for spec: Dictionary in units:
		ids.append(str(world.add_unit(spec)))
	return ids

# The AI the scenario asks for, built for `world` and NOT attached (the caller attaches
# it, on the host or locally only: a client's World must never plan the enemy). An AiDumb
# or an AiPilot; attach it with ai_attach().
func make_ai(world: Object) -> RefCounted:
	if ai_kind == AI_PILOT:
		return AiPilot.new()
	return AiDumb.new(world)

# Attach `ai` (from make_ai) to `world`: the AI plans now if the world is planning, and
# every turn after. Returns whether it took command cleanly.
func ai_attach(ai: RefCounted, world: Object) -> bool:
	if ai is AiPilot:
		return (ai as AiPilot).attach(world, ai_assignments)
	(ai as AiDumb).attach()
	return (ai as AiDumb).ok()

# The mission the scenario asks for, built for `world` and NOT attached, or null when
# the scenario has none. Check ok() / errors on the result.
func make_mission(world: Object) -> Mission:
	if mission_spec.is_empty():
		return null
	return Mission.new(world, mission_spec)

# The mission's target as the map shows it: {point: Vector2 (metres), radius_m: float}, or {}
# when the mission names no target. The radius is the first "unit_within ... of target"
# condition's own, else data/sim/ai.json mission.target_radius_m.
func objective() -> Dictionary:
	var t: Variant = mission_spec.get("target")
	if not (t is Array and (t as Array).size() == 2):
		return {}
	var radius := -1.0
	var lose: Variant = mission_spec.get("lose")
	if lose is Array:
		for c: Variant in (lose as Array):
			if c is Dictionary and str((c as Dictionary).get("type", "")) == Mission.TYPE_UNIT_WITHIN and (c as Dictionary).has("radius_m"):
				radius = float((c as Dictionary)["radius_m"])
				break
	if radius <= 0.0:
		radius = AiParams.new(AiParams.DATA_PATH, true).num("mission", "target_radius_m")
	return {"point": Vector2(float((t as Array)[0]), float((t as Array)[1])), "radius_m": radius}

# --- internals --------------------------------------------------------------------------

# The "ai" block: its kind, and for a pilot every assignment (each names a unit by an
# explicit id in 'units', and a role).
func _read_ai(d: Dictionary, quiet: bool) -> void:
	var a: Variant = d.get("ai")
	if not (a is Dictionary):
		_err("no 'ai' object (kind: \"dumb\" or \"pilot\")", quiet)
		return
	ai_kind = _str(a, "kind", quiet, "ai")
	if ai_kind != AI_DUMB and ai_kind != AI_PILOT:
		_err("ai.kind must be \"%s\" or \"%s\", got \"%s\"" % [AI_DUMB, AI_PILOT, ai_kind], quiet)
		return
	if ai_kind == AI_DUMB:
		return
	var asg: Variant = (a as Dictionary).get("assignments")
	if not (asg is Dictionary) or (asg as Dictionary).is_empty():
		_err("ai.assignments must be a non-empty object (unit id -> orders)", quiet)
		return
	var explicit: Dictionary = {}
	var ul: Variant = d.get("units")
	if ul is Array:
		for u: Variant in (ul as Array):
			if u is Dictionary and (u as Dictionary).has("id"):
				explicit[str((u as Dictionary)["id"])] = true
	for k: String in (asg as Dictionary):
		if k.begins_with("_"):
			continue
		var orders: Variant = (asg as Dictionary)[k]
		if not explicit.has(k):
			_err("ai.assignments.%s: no unit with that id in 'units' (give the unit an explicit \"id\")" % k, quiet)
		elif not (orders is Dictionary) or str((orders as Dictionary).get("role", "")) == "":
			_err("ai.assignments.%s needs a \"role\"" % k, quiet)
		else:
			ai_assignments[k] = _strip(orders)

# A copy of a JSON value without the "_" note keys (at every depth).
static func _strip(v: Variant) -> Variant:
	if v is Dictionary:
		var out := {}
		for k: Variant in (v as Dictionary):
			if not str(k).begins_with("_"):
				out[k] = _strip((v as Dictionary)[k])
		return out
	if v is Array:
		var arr := []
		for e: Variant in (v as Array):
			arr.append(_strip(e))
		return arr
	return v

func _unit_spec(u: Dictionary, i: int, pools: Variant, taken: Dictionary, quiet: bool) -> Dictionary:
	var label := "units[%d]" % i
	var type_id := _str(u, "type", quiet, label)
	var side := _str(u, "side", quiet, label)
	var spec := {"type": type_id, "controller": _str(u, "controller", quiet, label)}
	for k: String in ["x", "y", "heading"]:
		spec[k] = _num(u, k, quiet, label)
	if u.has("altitude_band"):
		spec["altitude_band"] = str(u["altitude_band"])
	if u.has("speed"):
		spec["speed"] = float(u["speed"])
	if u.has("id"):
		spec["id"] = str(u["id"])
	if not sides.has(side):
		_err("%s: side '%s' is not in 'sides'" % [label, side], quiet)
		spec["side"] = side
	else:
		spec["side"] = str((sides[side] as Dictionary)["world_side"])
	var cs := str(u.get("callsign", ""))
	if cs == "pool":
		cs = _take_callsign(pools, str((sides.get(side, {}) as Dictionary).get("callsign_pool", "")), type_id, taken, label, quiet)
	if cs != "":
		spec["callsign"] = cs
	return spec

# The first name of pools[pool][type] nobody took yet.
func _take_callsign(pools: Variant, pool: String, type_id: String, taken: Dictionary, label: String, quiet: bool) -> String:
	if not (pools is Dictionary) or not ((pools as Dictionary).get(pool) is Dictionary):
		_err("%s: no callsign pool '%s' in %s" % [label, pool, CALLSIGNS_PATH], quiet)
		return ""
	var names: Variant = ((pools as Dictionary)[pool] as Dictionary).get(type_id)
	if not (names is Array):
		_err("%s: pool '%s' has no list for type '%s'" % [label, pool, type_id], quiet)
		return ""
	for n: Variant in (names as Array):
		var key := "%s|%s" % [pool, str(n)]
		if not taken.has(key):
			taken[key] = true
			return str(n)
	_err("%s: the '%s' %s callsigns are used up" % [label, pool, type_id], quiet)
	return ""

func _read(p: String, quiet: bool) -> Variant:
	if not FileAccess.file_exists(p):
		_err("file missing: %s" % p, quiet)
		return null
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (v is Dictionary):
		_err("does not parse as a JSON object: %s" % p, quiet)
		return null
	return v

func _num(d: Dictionary, key: String, quiet: bool, label: String = "") -> float:
	var v: Variant = d.get(key)
	if v is float or v is int:
		return float(v)
	_err("%s%s must be a number" % [label + ": " if label != "" else "", key], quiet)
	return NAN

func _str(d: Dictionary, key: String, quiet: bool, label: String = "") -> String:
	var v: Variant = d.get(key)
	if v is String and v != "":
		return v
	_err("%s%s must be a non-empty string" % [label + ": " if label != "" else "", key], quiet)
	return ""

func _err(message: String, quiet: bool) -> void:
	var line := "%s: %s" % [path, message]
	errors.append(line)
	if not quiet:
		push_error(line)
