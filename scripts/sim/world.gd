extends RefCounted

# The simulation World: units, the map bounds, and the turn loop -- plan,
# commit (ready up), resolve (execution plan components 8 and 12; the
# interface Track U and Track A are written against, docs/proposals/
# demo-plan.md "S exposes"). Headless: no nodes, no drawing. A RefCounted with
# signals, so a test or a scene can own one.
#
#   var world := World.new()                  # reads data/sim/*.json
#   world.add_player("local")                 # every active human player
#   var id := world.add_unit({"type": "light_fighter", "side": "allies",
#       "controller": "player", "x": 1000.0, "y": 2500.0, "heading": 0.0})
#   world.plan_step(id, 0, {"turn": 0.3, "speed": 120.0})   # -> clamped state
#   world.plan_step(id, 1, Vector2(1300, 2450))              # or steer for a point
#   if world.commit("local"):                 # true once everyone is ready
#       world.resolve()                       # -> turn_resolved(turn, histories, events)
#   world.begin_turn()                        # resolved -> planning, turn + 1
#
# THE TURN (design doc, Co-op and turns; proposed details by Track S):
#   planning   players and the AI fill plans; plan_step validates every step
#              through the unit's envelope and returns where it lands. Steps
#              left unplanned are "carry on" -- straight, holding speed: an
#              empty plan is inertia, not a stop.
#   commit     every participant readies up: each active human player, plus
#              the AI (AI_PLAYER) when any unit is AI-controlled. Units belong
#              to nobody, so a ready flag is per player, not per unit; locally
#              one human readies for every player plane. commit() returns
#              whether everyone is ready; it does not resolve by itself, so the
#              owner decides when (an animation may still be playing).
#   resolve    planning -> resolving -> resolved. Every unit advances step by
#              step in TIME ORDER across the whole world (a 5-step fighter's
#              steps interleave with a 3-step bomber's), re-clamping each step
#              against the unit's actual state. Units do not interact yet, so
#              the order cannot change anything today; it is the order combat
#              will need. Resolution is a pure function of (unit states,
#              plans): no randomness anywhere in the sim -- anything that ever
#              needs it takes a seeded Mulberry32 (scripts/core/mulberry32.gd).
#   resolved   histories are on the units and in turn_resolved; plans are
#              consumed. begin_turn() starts the next planning phase.
#
# LEAVING THE MAP is an event, not an error: the step state carries
# out_of_bounds, a "left_bounds" / "returned_to_bounds" event goes into the
# turn's events, and unit_left_bounds fires. What should happen to such a unit
# is an open question for Alex; for now it simply flies on.
#
# ERRORS in calls (an unknown unit, a step past the turn, a call in the wrong
# phase) return an empty result, set last_error and push_error unless `quiet`.

signal phase_changed(phase: String)
signal ready_changed(player: String, is_ready: bool)
signal plan_changed(unit_id: String)
signal turn_resolved(turn: int, histories: Dictionary, events: Array)
signal unit_left_bounds(unit_id: String, turn: int, step_index: int)

const SimRules = preload("res://scripts/sim/sim_rules.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")

const PHASE_PLANNING := "planning"
const PHASE_RESOLVING := "resolving"
const PHASE_RESOLVED := "resolved"
# The AI's seat in the ready-up: it commits like a player once it has planned.
const AI_PLAYER := "ai"
const CONTROLLER_PLAYER := Unit.CONTROLLER_PLAYER
const CONTROLLER_AI := Unit.CONTROLLER_AI

var rules: SimRules
var units_dir: String
var defs: Dictionary = {}       # type id -> UnitDef, loaded on first use
var units: Dictionary = {}      # unit id -> Unit, in the order they were added
var bounds: Rect2 = Rect2()     # metres; rules.bounds
var turn: int = 1               # the turn being planned or just resolved
var phase: String = PHASE_PLANNING
var players: Array[String] = [] # active human players
var ready: Dictionary = {}      # participant -> bool
var errors: Array[String] = []  # load errors (rules); see ok()
var last_error: String = ""
var quiet: bool = false

func _init(turn_path: String = SimRules.TURN_PATH, altitude_path: String = SimRules.ALTITUDE_PATH, unit_dir: String = UnitDef.UNITS_DIR) -> void:
	rules = SimRules.new(turn_path, altitude_path)
	units_dir = unit_dir
	errors.append_array(rules.errors)
	bounds = rules.bounds

func ok() -> bool:
	return errors.is_empty()

# --- Unit types --------------------------------------------------------------

# The validated definition of a unit type, or null (with last_error) if its
# file is missing or invalid. Loaded once, on first use.
func unit_def(type_id: String) -> UnitDef:
	if defs.has(type_id):
		return defs[type_id]
	var def := UnitDef.new(UnitDef.path_for(type_id, units_dir), rules.band_ids, quiet)
	if not def.ok():
		_fail("unit type '%s' does not load: %s" % [type_id, "; ".join(def.errors)])
		return null
	defs[type_id] = def
	return def

# --- Players and units -------------------------------------------------------

func add_player(player: String) -> void:
	if player == "" or player == AI_PLAYER or players.has(player):
		return
	players.append(player)
	ready[player] = false

# Drop-out: a player who leaves no longer holds up the turn.
func remove_player(player: String) -> void:
	players.erase(player)
	ready.erase(player)

# spec: {type, side, controller ("player" | "ai"), x, y, heading (rad)} plus
# optional id (default "<type>_<n>"), speed (default the type's cruise) and
# altitude_band (default the type's start band) -- defaults that come from the
# unit's data, not from code. Returns the new unit's id, or "" on error.
func add_unit(spec: Dictionary) -> String:
	if phase == PHASE_RESOLVING:
		return _fail_s("add_unit: not while a turn is resolving")
	var type_id := str(spec.get("type", ""))
	var def := unit_def(type_id)
	if def == null:
		return ""
	var side := str(spec.get("side", ""))
	if side == "":
		return _fail_s("add_unit: 'side' is required")
	var controller := str(spec.get("controller", ""))
	if controller != CONTROLLER_PLAYER and controller != CONTROLLER_AI:
		return _fail_s("add_unit: 'controller' must be '%s' or '%s', got '%s'" % [CONTROLLER_PLAYER, CONTROLLER_AI, controller])
	for k: String in ["x", "y", "heading"]:
		if not _is_finite_number(spec.get(k)):
			return _fail_s("add_unit: '%s' must be a finite number" % k)
	var speed: Variant = spec.get("speed", def.envelope.speed_cruise)
	if not _is_finite_number(speed):
		return _fail_s("add_unit: 'speed' must be a finite number")
	var band := str(spec.get("altitude_band", def.envelope.start_band))
	if not def.envelope.bands.has(band):
		return _fail_s("add_unit: a %s cannot be in band '%s' (its bands: %s)" % [type_id, band, str(def.envelope.bands)])
	var id := str(spec.get("id", ""))
	if id == "":
		var n := 1
		while units.has("%s_%d" % [type_id, n]):
			n += 1
		id = "%s_%d" % [type_id, n]
	if units.has(id):
		return _fail_s("add_unit: id '%s' is already in use" % id)

	var u := Unit.new()
	u.id = id
	u.type = type_id
	u.def = def
	u.side = side
	u.controller = controller
	u.x = float(spec["x"])
	u.y = float(spec["y"])
	u.heading = Envelope.wrap_angle(float(spec["heading"]))
	u.speed = float(speed)
	u.altitude_band = band
	u.out_of_bounds = not in_bounds(u.x, u.y)
	units[id] = u
	if controller == CONTROLLER_AI and not ready.has(AI_PLAYER):
		ready[AI_PLAYER] = false
	return id

func steps_per_turn(unit_id: String) -> int:
	var u := _unit(unit_id)
	return u.def.actions_per_turn if u != null else 0

func step_dt(unit_id: String) -> float:
	var u := _unit(unit_id)
	return rules.step_dt(u.def.actions_per_turn) if u != null else NAN

# --- Planning ----------------------------------------------------------------

# Set step `step_index` of a unit's plan to `request` (a Dictionary or a Vector2
# target point; envelope.gd describes the shape) and return the state the
# unit will be in after that step, clamped into its envelope. Steps before it
# that were never planned are filled with "carry on"; steps after it keep
# their requests and are re-clamped from the new path. Returns {} on error.
func plan_step(unit_id: String, step_index: int, request: Variant) -> Dictionary:
	var u := _unit(unit_id)
	if u == null:
		return {}
	if phase != PHASE_PLANNING:
		return _fail_d("plan_step: plans change only in the planning phase (phase is %s)" % phase)
	var n := u.def.actions_per_turn
	if step_index < 0 or step_index >= n:
		return _fail_d("plan_step: a %s has steps 0..%d this turn, got %d" % [u.type, n - 1, step_index])
	var problem := Envelope.request_error(request)
	if problem != "":
		return _fail_d("plan_step: " + problem)
	var req: Dictionary = Envelope.normalize_request(request).duplicate(true)
	while u.plan.size() < step_index:
		u.plan.append({})
	if step_index < u.plan.size():
		u.plan[step_index] = req
	else:
		u.plan.append(req)
	var states := _run_plan(u)
	plan_changed.emit(u.id)
	return (states[step_index] as Dictionary).duplicate(true)

func clear_plan(unit_id: String) -> void:
	var u := _unit(unit_id)
	if u == null:
		return
	if phase != PHASE_PLANNING:
		_fail("clear_plan: plans change only in the planning phase (phase is %s)" % phase)
		return
	u.plan.clear()
	plan_changed.emit(u.id)

# The whole turn as it will resolve if nothing changes: one state per step
# (actions_per_turn of them), explicit steps and "carry on" steps alike, each
# with step, t, planned (whether a request was given), clamped, limits and
# out_of_bounds. The UI's preview path and end-of-turn ghost.
func planned_states(unit_id: String) -> Array:
	var u := _unit(unit_id)
	if u == null:
		return []
	return _run_plan(u)

# What the unit can do at step `step_index`, from where its plan leaves it
# after the steps before: envelope.gd's reachable() (turn_max, speed window,
# bands, the outline of reachable end points, the turn radius).
func reachable(unit_id: String, step_index: int) -> Dictionary:
	var u := _unit(unit_id)
	if u == null:
		return {}
	var n := u.def.actions_per_turn
	if step_index < 0 or step_index >= n:
		return _fail_d("reachable: a %s has steps 0..%d this turn, got %d" % [u.type, n - 1, step_index])
	var from: Dictionary = u.state()
	if step_index > 0:
		from = _run_plan(u)[step_index - 1]
	return u.def.envelope.reachable(from, rules.step_dt(n))

# --- Ready-up ----------------------------------------------------------------

# Everyone whose ready flag holds up the turn: the active human players, and
# the AI if any unit is AI-controlled.
func participants() -> Array[String]:
	var out: Array[String] = players.duplicate()
	for id: String in units:
		if (units[id] as Unit).controller == CONTROLLER_AI:
			out.append(AI_PLAYER)
			break
	return out

func is_ready(player: String) -> bool:
	return ready.get(player, false) == true

func all_ready() -> bool:
	var p := participants()
	if p.is_empty():
		return false
	for who: String in p:
		if not is_ready(who):
			return false
	return true

# Ready `player` up. Returns whether every participant is now ready.
func commit(player: String) -> bool:
	if phase != PHASE_PLANNING:
		_fail("commit: only during planning (phase is %s)" % phase)
		return false
	if not participants().has(player):
		_fail("commit: '%s' is not playing (participants: %s)" % [player, str(participants())])
		return false
	if not is_ready(player):
		ready[player] = true
		ready_changed.emit(player, true)
	return all_ready()

# Take a ready flag back (changed one's mind, wants to re-plan).
func withdraw(player: String) -> void:
	if phase == PHASE_PLANNING and is_ready(player):
		ready[player] = false
		ready_changed.emit(player, false)

# --- Resolution --------------------------------------------------------------

# Advance every unit through its plan. Returns {turn, histories: {unit id ->
# Array of states}, events: Array}, or {} if not everyone is ready.
func resolve() -> Dictionary:
	if phase != PHASE_PLANNING:
		return _fail_d("resolve: only from the planning phase (phase is %s)" % phase)
	if not all_ready():
		var waiting: Array[String] = []
		for who: String in participants():
			if not is_ready(who):
				waiting.append(who)
		return _fail_d("resolve: waiting for %s to ready up" % str(waiting))
	_set_phase(PHASE_RESOLVING)

	var histories := {}
	var cursor := {}
	# Every step of every unit, keyed by the time it ends: (k + 1) / n of the
	# turn. Compared as fractions in integers, so a 4-step and a 2-step unit's
	# steps tie exactly; ties go to the unit added first.
	var schedule: Array = []
	var order := 0
	for id: String in units:
		var u: Unit = units[id]
		var start := _start_state(u)
		histories[id] = [start]
		cursor[id] = start
		for k in u.def.actions_per_turn:
			schedule.append([k + 1, u.def.actions_per_turn, order, id])
		order += 1
	schedule.sort_custom(func(a: Array, b: Array) -> bool:
		var l: int = int(a[0]) * int(b[1])
		var r: int = int(b[0]) * int(a[1])
		if l != r:
			return l < r
		return int(a[2]) < int(b[2]))

	var events: Array = []
	for item: Array in schedule:
		var id: String = item[3]
		var u: Unit = units[id]
		var k: int = int(item[0]) - 1
		var prev: Dictionary = cursor[id]
		var s := _step(u, k, prev)
		if bool(s["out_of_bounds"]) != bool(prev["out_of_bounds"]):
			events.append({
				"type": "left_bounds" if s["out_of_bounds"] else "returned_to_bounds",
				"unit": id, "turn": turn, "step": k, "t": s["t"], "x": s["x"], "y": s["y"],
			})
		(histories[id] as Array).append(s)
		cursor[id] = s

	for id: String in units:
		var u: Unit = units[id]
		var last: Dictionary = cursor[id]
		u.apply_state(last)
		u.out_of_bounds = bool(last["out_of_bounds"])
		u.history = histories[id]
		u.plan.clear()

	_set_phase(PHASE_RESOLVED)
	for ev: Dictionary in events:
		if ev["type"] == "left_bounds":
			unit_left_bounds.emit(str(ev["unit"]), turn, int(ev["step"]))
	turn_resolved.emit(turn, histories, events)
	return {"turn": turn, "histories": histories, "events": events}

# resolved -> planning: the next turn. Ready flags reset; plans start empty.
func begin_turn() -> void:
	if phase != PHASE_RESOLVED:
		_fail("begin_turn: only after a resolve (phase is %s)" % phase)
		return
	turn += 1
	for who: Variant in ready.keys():
		if ready[who] == true:
			ready[who] = false
			ready_changed.emit(str(who), false)
	_set_phase(PHASE_PLANNING)

# --- Queries -----------------------------------------------------------------

func in_bounds(px: float, py: float) -> bool:
	return px >= bounds.position.x and px <= bounds.end.x and py >= bounds.position.y and py <= bounds.end.y

func bounds_center() -> Vector2:
	return bounds.get_center()

# Height of a band in metres (data/sim/altitude.json): above sea level for air
# bands, above the terrain for "surface". NAN for an unknown band.
func band_height(band: String) -> float:
	return float(rules.band_height_m.get(band, NAN))

# Where a unit is `t` seconds into the turn, on the same arcs resolve() used:
# {x, y, heading, speed, altitude_band, height_m}. `source` "history" is the
# last resolve (for animating it); "plan" is the current plan's preview.
func sample(unit_id: String, t: float, source: String = "history") -> Dictionary:
	var u := _unit(unit_id)
	if u == null:
		return {}
	var path: Array = []
	if source == "plan":
		path = [_start_state(u)]
		path.append_array(_run_plan(u))
	elif source == "history":
		path = u.history
	else:
		return _fail_d("sample: source is 'history' or 'plan', got '%s'" % source)
	# No resolve yet (or a path of one state): the unit is where it is.
	if path.size() < 2:
		var s := u.state()
		s["height_m"] = band_height(u.altitude_band)
		return s
	var tt := clampf(t, 0.0, rules.turn_seconds)
	var k := 0
	while k < path.size() - 2 and float(path[k + 1]["t"]) < tt:
		k += 1
	var a: Dictionary = path[k]
	var b: Dictionary = path[k + 1]
	var dt := float(b["t"]) - float(a["t"])
	var f := clampf((tt - float(a["t"])) / dt, 0.0, 1.0) if dt > 0.0 else 1.0
	var p := Envelope.point_on_step(a, b, dt, f)
	var band_a := str(a["altitude_band"])
	var band_b := str(b["altitude_band"])
	p["altitude_band"] = band_b if f >= 0.5 else band_a
	p["height_m"] = band_height(band_a) + (band_height(band_b) - band_height(band_a)) * f
	return p

# --- Internals ---------------------------------------------------------------

# The plan's states for every step of the turn, from the unit's current state.
func _run_plan(u: Unit) -> Array:
	var out: Array = []
	var cur: Dictionary = _start_state(u)
	for k in u.def.actions_per_turn:
		cur = _step(u, k, cur)
		out.append(cur)
	return out

# One step: the unit's request for step k (or "carry on"), clamped from `prev`.
# The ONLY place a step is computed, so the preview and the resolve agree.
func _step(u: Unit, k: int, prev: Dictionary) -> Dictionary:
	var n := u.def.actions_per_turn
	var planned := k < u.plan.size() and not (u.plan[k] as Dictionary).is_empty()
	var req: Variant = u.plan[k] if k < u.plan.size() else {}
	var s := u.def.envelope.clamp_step(prev, req, rules.step_dt(n))
	s["step"] = k
	s["t"] = rules.turn_seconds * float(k + 1) / float(n)
	s["planned"] = planned
	s["out_of_bounds"] = not in_bounds(float(s["x"]), float(s["y"]))
	return s

func _start_state(u: Unit) -> Dictionary:
	var s := u.state()
	s["step"] = -1
	s["t"] = 0.0
	s["turn"] = 0.0
	s["planned"] = false
	s["clamped"] = false
	s["limits"] = []
	s["out_of_bounds"] = u.out_of_bounds
	return s

func _set_phase(p: String) -> void:
	phase = p
	phase_changed.emit(p)

func _unit(unit_id: String) -> Unit:
	if not units.has(unit_id):
		_fail("no unit '%s'" % unit_id)
		return null
	return units[unit_id]

static func _is_finite_number(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))

func _fail(message: String) -> void:
	last_error = message
	if not quiet:
		push_error("World: " + message)

func _fail_s(message: String) -> String:
	_fail(message)
	return ""

func _fail_d(message: String) -> Dictionary:
	_fail(message)
	return {}
