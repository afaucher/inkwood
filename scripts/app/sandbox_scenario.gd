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
#   "briefing": "..."                      (optional) the line the sandbox shows at the start; "{turn_limit}" in it
#                                          becomes the mission's turn limit (the strike's), so the number is written once
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
#
# THE STRIKE (Track A2, 2026-10-10): a scenario can place a unit, or a route point, ON THE WORLD LAYOUT's
# sites (scripts/world/world_layout.gd: WorldLayout.shared(seed).sites()) instead of at copied numbers, so
# the tower and the batteries stand where the village is whatever the layout rules say --
#
#   "site": "radio_tower"                  a unit's position (x and y are then read from the layout; give no x, y)
#   "site": "aa_battery", "site_index": 1  the layout's list sites have several: the second battery
#   "dx": 40.0, "dy": -20.0                (optional) metres added to the site
#   {"site": "radio_tower", "dx": 650.0, "dy": -100.0}   in place of an [x, y] pair in a route or a target
#
# and an "objective" block says what the map marks for the players (the strike's mission names a unit, not a
# point, so it has no 'target' for objective() to read):
#
#   "objective": {"unit": "radio_tower_1", "radius_m": 120.0, "frame_m": 300.0, "label": "TARGET"}
#                                          the ring is drawn at that unit's position; frame_m (optional) is how
#                                          far round it the opening view must reach; label (optional) the word

const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")

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
var objective_spec: Dictionary = {}   # the "objective" block: {unit, radius_m, frame_m, label}; {} = none
var local_player: String = ""
var sides: Dictionary = {}            # scenario side -> {world_side, callsign_pool}
var units: Array[Dictionary] = []     # World.add_unit specs, callsigns resolved
var view: Dictionary = {}             # name -> value (value records flattened)
var errors: Array[String] = []

var _sites: Dictionary = {}           # the world layout's sites, read on first use (a scenario with no "site" never loads it)
var _sites_read := false

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
	briefing = briefing.replace("{turn_limit}", str(turn_limit()))
	if d.has("objective"):
		_read_objective(d["objective"], quiet)
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

# The mission's turn limit (a "turn_limit" condition of its lose list), or 0 when it has none.
func turn_limit() -> int:
	var lose: Variant = mission_spec.get("lose")
	if lose is Array:
		for c: Variant in (lose as Array):
			if c is Dictionary and str((c as Dictionary).get("type", "")) == Mission.TYPE_TURN_LIMIT:
				return int((c as Dictionary).get("turn", 0))
	return 0

# The mission's target as the map shows it: {point: Vector2 (metres), radius_m: float, frame_m: float,
# label: String, unit: String}, or {} when the scenario names none. Two sources: an "objective" block (the
# strike: the ring is round a UNIT's position, e.g. the radio tower) or else the mission's "target" point (the
# first fight). frame_m is how far round the point the opening view must reach (0 = the ring's own size);
# label "" = the map's default word. For a mission "target" the radius is the first
# "unit_within ... of target" condition's own, else data/sim/ai.json mission.target_radius_m.
func objective() -> Dictionary:
	if not objective_spec.is_empty():
		return objective_spec.duplicate()
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
	return {"point": Vector2(float((t as Array)[0]), float((t as Array)[1])), "radius_m": radius, "frame_m": 0.0, "label": "", "unit": ""}

# The world layout's site `key` (and `index` for a list site) as a Vector2 in metres, plus (dx, dy); NAN, NAN
# and an error when the layout has no such site.
func site_point(key: String, index: int = 0, dx: float = 0.0, dy: float = 0.0, quiet: bool = false) -> Vector2:
	if not _sites_read:
		_sites_read = true
		var layout: RefCounted = WorldLayout.shared(seed_value)
		if layout == null or not layout.ok():
			_err("the world layout of seed %d did not load: %s" % [seed_value, str(layout.errors) if layout != null else "null"], quiet)
		else:
			_sites = layout.sites()
	var v: Variant = _sites.get(key)
	if v is Array and index >= 0 and index < (v as Array).size() and (v as Array)[index] is Vector2:
		return ((v as Array)[index] as Vector2) + Vector2(dx, dy)
	if v is Vector2 and index == 0:
		return (v as Vector2) + Vector2(dx, dy)
	_err("the world layout has no site '%s' [%d]" % [key, index], quiet)
	return Vector2(NAN, NAN)

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
			var cleaned: Dictionary = _strip(orders)
			if cleaned.has("route"):
				cleaned["route"] = _points(cleaned["route"], "ai.assignments.%s.route" % k, quiet)
			if cleaned.has("target"):
				cleaned["target"] = _point(cleaned["target"], "ai.assignments.%s.target" % k, quiet)
			ai_assignments[k] = cleaned

# A route: a list of [x, y] pairs and/or {"site": ...} points, as a list of [x, y] pairs.
func _points(v: Variant, label: String, quiet: bool) -> Array:
	var out: Array = []
	if not (v is Array):
		_err("%s must be a list of points" % label, quiet)
		return out
	for p: Variant in (v as Array):
		out.append(_point(p, label, quiet))
	return out

# One point: an [x, y] pair, or {"site": key, "site_index": i, "dx": .., "dy": ..} on the world layout.
func _point(v: Variant, label: String, quiet: bool) -> Variant:
	if v is Dictionary and (v as Dictionary).has("site"):
		var d: Dictionary = v
		var at := site_point(str(d["site"]), int(d.get("site_index", 0)), float(d.get("dx", 0.0)), float(d.get("dy", 0.0)), quiet)
		return [at.x, at.y]
	if v is Array and (v as Array).size() == 2:
		return v
	_err("%s: a point is [x, y] or {\"site\": ...}" % label, quiet)
	return [NAN, NAN]

# The "objective" block: {unit, radius_m, frame_m?, label?}. The ring's centre is that unit's position.
func _read_objective(v: Variant, quiet: bool) -> void:
	if not (v is Dictionary):
		_err("'objective' must be an object", quiet)
		return
	var d: Dictionary = v
	var unit_id := _str(d, "unit", quiet, "objective")
	var at := Vector2(NAN, NAN)
	for spec: Dictionary in units:
		if str(spec.get("id", "")) == unit_id:
			at = Vector2(float(spec["x"]), float(spec["y"]))
	if is_nan(at.x):
		_err("objective.unit '%s' is not a unit of the scenario (give the unit an explicit \"id\")" % unit_id, quiet)
		return
	var radius := _num(d, "radius_m", quiet, "objective")
	if not (radius > 0.0):
		_err("objective.radius_m must be a positive number", quiet)
		return
	objective_spec = {"point": at, "radius_m": radius, "frame_m": float(d.get("frame_m", 0.0)), "label": str(d.get("label", "")), "unit": unit_id}

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
	if u.has("site"):
		var at := site_point(str(u["site"]), int(u.get("site_index", 0)), float(u.get("dx", 0.0)), float(u.get("dy", 0.0)), quiet)
		spec["x"] = at.x
		spec["y"] = at.y
		spec["heading"] = _num(u, "heading", quiet, label)
	else:
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
