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
#              against the unit's actual state. Motion does not depend on
#              combat. Then COMBAT (Track C; scripts/sim/combat.gd documents the
#              model and the event shapes) walks the turn at a fixed tick over
#              the histories just built, rolls every weapon with seeded
#              Mulberry32 streams (rng_seed; the only randomness in the sim, and
#              only the host's World resolves) and adds fire / hit / down events.
#              Resolution is a pure function of (unit states, plans, rng_seed).
#              A unit at 0 health is DOWN with a fate (Unit.fate): it explodes
#              and stays put, or goes out of control -- the sim flies it down
#              in a spiral, across turns, to a crash (events "down" and "crash").
#              Down units cannot be planned (plan_step / clear_plan refuse
#              them), fire or are fired at; they stay in `units` and do not hold
#              up the ready-up.
#   resolved   histories are on the units and in turn_resolved; plans are
#              consumed. begin_turn() starts the next planning phase.
#
# THE STRIKE (Track S2, proposed 2026-10-10; Alex's decisions strike-target, bomb-release,
# bomb-load, strike-plan). Two things join the turn loop:
#   STATIC UNITS (data/units: mobility "static" -- a radio tower, an anti-aircraft battery) never
#              move, turn or plan: plan_step refuses them, their one step a turn stands still, and
#              they do not hold up the ready-up (an AI side made only of static units has no one
#              to wait for; participants() leaves the AI out). They fire (flak, aimed up: combat.gd)
#              and are fired at and bombed; at 0 health they are DOWN with the fate "destroyed".
#   BOMBS      a step request may carry {"drop": {"aim": [x, y], "target": {...}}} (envelope.gd; the
#              physics, the cone and the events are in bombs.gd). drop_cone() / drop_spread() answer the
#              interface, bombs_left() the load, plan_step() reports the drop in the returned
#              state's "drop". A bomb falls for seconds and may land in a LATER turn: the bombs
#              still falling are `bombs_in_flight`, carried by resolve() and handed to a client
#              by apply_resolution (the result's "bombs"). THE TARGET (Track T): the drop may carry the
#              target it was activated with, a unit or a point; it is the step's, it travels with the plan
#              and shows in the step's "drop" and the bomb_release event. A UNIT target FOLLOWS the unit
#              (Alex: "Targeting a moving unit like a tank should follow the unit. We need to pick the release
#              point for bombs and things dynamically."): at resolve the aim is the unit's position at the
#              release, led by its velocity (_resolve_followed_drops); a point target is fixed. A drop whose
#              target is outside its step's cone does what data/sim/bombs.json outside_cone_mode says: "hold"
#              releases nothing and spends no bombs, "poor_shot" releases a poor stick (bombs.gd).
#              drop_expected() answers the expected-damage line.
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
const CombatRules = preload("res://scripts/sim/combat_rules.gd")
const CombatResolver = preload("res://scripts/sim/combat_resolver.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombExpect = preload("res://scripts/sim/bomb_expect.gd")

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
# The game's seed for every random roll (combat's hit rolls; design doc: hits
# are random-ish). A scenario sets it. In a networked game only the host's
# World resolves, so only the host rolls.
var rng_seed: int = 0
var combat: CombatRules         # data/sim/combat.json: the tick, the odds factors, the fall
var bombs: BombRules            # data/sim/bombs.json: the fall, the cone, the spread, the blast
# Bombs released and not yet landed (bombs.gd header has the record): carried across turns by
# resolve(), handed to a client by apply_resolution(), read by the effects and the interface.
var bombs_in_flight: Array = []

var _combat_resolver: CombatResolver

func _init(turn_path: String = SimRules.TURN_PATH, altitude_path: String = SimRules.ALTITUDE_PATH, unit_dir: String = UnitDef.UNITS_DIR, combat_path: String = CombatRules.PATH, bombs_path: String = BombRules.PATH) -> void:
	rules = SimRules.new(turn_path, altitude_path)
	units_dir = unit_dir
	errors.append_array(rules.errors)
	bounds = rules.bounds
	combat = CombatRules.new(combat_path)
	errors.append_array(combat.errors)
	bombs = BombRules.new(bombs_path)
	errors.append_array(bombs.errors)
	_combat_resolver = CombatResolver.new(combat, bombs)

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
# optional id (default "<type>_<n>"), callsign (default none; a scenario takes
# it from data/names/callsigns.json), speed (default the type's cruise) and
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
	u.callsign = str(spec.get("callsign", ""))
	u.type = type_id
	u.def = def
	u.side = side
	u.controller = controller
	u.x = float(spec["x"])
	u.y = float(spec["y"])
	u.heading = Envelope.wrap_angle(float(spec["heading"]))
	u.speed = float(speed)
	u.altitude_band = band
	u.health = def.health
	u.drops_left = def.bomb_drops
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
	if u.down:
		return _fail_d("plan_step: unit '%s' is down (%s) and takes no orders" % [unit_id, u.fate if u.fate != "" else "down"])
	if u.def.is_static():
		return _fail_d("plan_step: unit '%s' is a static %s and takes no orders" % [unit_id, u.type])
	if phase != PHASE_PLANNING:
		return _fail_d("plan_step: plans change only in the planning phase (phase is %s)" % phase)
	var n := u.def.actions_per_turn
	if step_index < 0 or step_index >= n:
		return _fail_d("plan_step: a %s has steps 0..%d this turn, got %d" % [u.type, n - 1, step_index])
	var problem := Envelope.request_error(request)
	if problem != "":
		return _fail_d("plan_step: " + problem)
	var req: Dictionary = Envelope.normalize_request(request).duplicate(true)
	if req.has("drop"):
		# A drop (bombs.gd): only a unit with bombs, and no more drops in the turn than it has left.
		if not u.def.carries_bombs():
			return _fail_d("plan_step: a %s carries no bombs" % u.type)
		var used := 0
		for i in u.plan.size():
			if i != step_index and (u.plan[i] as Dictionary).has("drop"):
				used += 1
		if used + 1 > u.drops_left:
			return _fail_d("plan_step: unit '%s' has %d drop(s) left and %d already planned this turn" % [unit_id, u.drops_left, used])
		var tgt := Envelope.drop_target(req)
		if tgt.has("unit") and not units.has(str(tgt["unit"])):
			return _fail_d("plan_step: the drop's target unit '%s' does not exist" % str(tgt["unit"]))
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
	if u.down:
		_fail("clear_plan: unit '%s' is down (%s) and takes no orders" % [unit_id, u.fate if u.fate != "" else "down"])
		return
	if u.def.is_static():
		return   # a static unit has no plan to clear (plan_step refuses it)
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

# --- Bombs: what the interface asks (Track S2; bombs.gd has the model) ---------------------------

# The unit's bomb load: {drops_left (passes it can still make, as the turn began), drops_max (and
# drops_total: the type's), per_drop (bombs in a stick), planned (drops in the current plan), carries}.
# All zeros and false for a unit that carries no bombs.
func bombs_left(unit_id: String) -> Dictionary:
	var u := _unit(unit_id)
	if u == null:
		return {}
	var planned := 0
	for st: Variant in u.plan:
		if (st as Dictionary).has("drop"):
			planned += 1
	return {
		"drops_left": u.drops_left, "drops_max": u.def.bomb_drops, "drops_total": u.def.bomb_drops,
		"per_drop": u.def.bomb_per_drop, "planned": planned, "carries": u.def.carries_bombs(),
	}

# THE CONE OF A STEP: where bombs released on step `step_index` of the unit's current plan can land
# (the step as it is planned now: plan its motion first, then ask). Returns {} (and last_error) for a
# unit with no bombs, a down unit or a step out of range. Otherwise:
#   ok            true
#   polygon       PackedVector2Array, metres: the region the aim point may be placed in (the union of the
#                 cone's footprint at each moment of the step); an aim outside it is moved inside it
#   ideal_aim     Vector2 (also under "ideal"): the ideal aim point -- where a bomb released at the middle
#                 of the step lands, release error 0 there
#   ideal_curve   PackedVector2Array: the ideal point for each moment of the step (aiming along it is
#                 ideal whatever the moment)
#   release_path  PackedVector2Array: the bomber's positions through the step
#   height_m, speed, heading   the bomber in the middle of the step
#   range_m, fall_s, ideal_deg  the ideal ground range, fall time and release angle (degrees below the
#                 horizon) there
#   half_across_deg, half_height_deg   the cone's size
#   spread_ideal_m, spread_rim_m   one bomb's scatter (sigma, metres) at the ideal aim and on the rim
#   drops_left, per_drop
#   aim_info      when `aim` (a Vector2 or [x, y]) is given: drop_spread()'s answer for it
func drop_cone(unit_id: String, step_index: int, aim: Variant = null) -> Dictionary:
	var ctx := _drop_context("drop_cone", unit_id, step_index)
	if ctx.is_empty():
		return {}
	var u: Unit = ctx["unit"]
	var samples: Array = ctx["samples"]
	var mid := Bombs.sample_at(samples, 0.5 * (float((samples[0] as Dictionary)["t"]) + float((samples[samples.size() - 1] as Dictionary)["t"])))
	var rng := Bombs.ideal_range(float(mid["speed"]), float(mid["height_m"]), bombs.gravity)
	var path := PackedVector2Array()
	for sm: Dictionary in samples:
		path.append(Vector2(float(sm["x"]), float(sm["y"])))
	var ideal := Bombs.ideal_point(samples, bombs)
	var out := {
		"ok": true, "unit": unit_id, "step": step_index,
		"polygon": Bombs.cone_polygon(samples, bombs),
		"ideal_aim": ideal, "ideal": ideal,
		"ideal_curve": Bombs.impact_curve(samples, bombs),
		"release_path": path,
		"height_m": float(mid["height_m"]), "speed": float(mid["speed"]), "heading": float(mid["heading"]),
		"range_m": rng, "fall_s": Bombs.fall_time(float(mid["height_m"]), bombs.gravity),
		"ideal_deg": rad_to_deg(Bombs.ideal_depression(float(mid["speed"]), float(mid["height_m"]), bombs.gravity)),
		"half_across_deg": bombs.cone_half_across_deg, "half_height_deg": bombs.cone_half_height_deg,
		"spread_ideal_m": Bombs.spread_m(float(mid["height_m"]), 1.0, bombs),
		"spread_rim_m": Bombs.spread_m(float(mid["height_m"]), Bombs.accuracy(1.0, bombs), bombs),
		"drops_left": u.drops_left, "per_drop": u.def.bomb_per_drop,
	}
	if aim != null:
		out["aim_info"] = drop_spread(unit_id, step_index, aim)
	return out

# WHAT AN AIM POINT GETS in a step (Bombs.plan_drop): {} on the errors drop_cone() has, or
#   ok, aim (Vector2: the point moved inside the cone if it was outside -- what the interface shows; the
#   World does NOT bomb there, see "outside"), requested (Vector2),
#   clamped (bool), outside (bool: the requested aim is outside the cone: what happens is outside_cone_mode,
#   Track T), releases (bool: a drop planned there would release -- inside the cone, or outside with "poor_shot"),
#   poor_shot (bool: it would be a poor shot, accuracy and spread as such), requested_r (its release error, 1 is the rim),
#   spread {radius_m, along_m, across_m, heading} (one bomb's scatter, sigma, metres;
#   heading the bomber's at the release), spread_m, quality (also "accuracy": 0..1, the weapons' centre
#   factor of the release error; 1 at the ideal release angle), r (the release error as a fraction of
#   the cone: 1 is the rim), release (Vector2, where the bomber is when the stick goes), release_t
#   (seconds into the turn), release_height_m, fall_s, range_m (the ideal ground range), ideal_deg,
#   depression_deg (the angle below the horizon the aim point is seen at the release), error_deg
#   (depression minus ideal), across_deg (the aim's bearing off the bomber's heading), impact_t
#   (seconds after the start of this turn at which the stick's centre lands), lands_in_turn,
#   stick_length_m, per_drop.
func drop_spread(unit_id: String, step_index: int, aim: Variant) -> Dictionary:
	var a := _aim_point(aim)
	if a.is_empty():
		return _fail_d("drop_spread: the aim is a Vector2 or [x, y] of finite numbers, got %s" % str(aim))
	var ctx := _drop_context("drop_spread", unit_id, step_index)
	if ctx.is_empty():
		return {}
	var u: Unit = ctx["unit"]
	var d := Bombs.plan_drop(ctx["samples"], float(a[0]), float(a[1]), bombs)
	var rd := Bombs.release_rule(d, bombs)
	var releases: bool = rd.get("ok", false) == true
	if releases:
		d = rd   # a poor shot's accuracy and scatter (outside_cone_mode); inside the cone it is plan_drop's own
	var rel: Dictionary = d["release"]
	var sigma := float(d["spread_m"])
	var impact_t := float(d["impact_t"])
	return {
		"ok": true,
		"aim": Vector2(float((d["aim"] as Array)[0]), float((d["aim"] as Array)[1])),
		"requested": Vector2(float(a[0]), float(a[1])),
		"clamped": d["clamped"], "outside": d["outside"], "requested_r": d["requested_r"], "releases": releases,
		"poor_shot": bool(d.get("poor_shot", false)),
		"spread": {"radius_m": sigma, "along_m": sigma, "across_m": sigma, "heading": float(rel["heading"])},
		"spread_m": sigma, "quality": d["accuracy"], "accuracy": d["accuracy"], "r": d["r"],
		"release": Vector2(float(rel["x"]), float(rel["y"])), "release_t": d["release_t"], "release_height_m": rel["height_m"],
		"fall_s": d["fall_s"], "range_m": d["range_m"], "ideal_deg": d["ideal_deg"], "depression_deg": d["depression_deg"],
		"error_deg": d["error_deg"], "across_deg": d["across_deg"], "impact_t": impact_t,
		"lands_in_turn": turn + int(floorf(impact_t / rules.turn_seconds + 1e-9)),
		"stick_length_m": float(maxi(u.def.bomb_per_drop - 1, 0)) * float(rel["speed"]) * bombs.release_interval_s,
		"per_drop": u.def.bomb_per_drop,
	}

# THE EXPECTED DAMAGE of a drop at `aim` on step `step_index` of the unit's current plan (Track T; bomb_expect.gd):
# the ground units (blast_height_m or lower) the stick can reach, each with the pips it is expected to lose and the
# chance it is destroyed, the most affected first. Every unit is listed whatever its side and whatever the fog: the
# interface filters what the player may see. [] for an aim outside the cone (nothing releases) or a unit that cannot
# drop. Each record: {unit, mean (pips, capped at its health), mean_raw, p_destroy, health, distance_m (from the aim)}.
func drop_expected(unit_id: String, step_index: int, aim: Variant) -> Array:
	var a := _aim_point(aim)
	if a.is_empty():
		_fail("drop_expected: the aim is a Vector2 or [x, y] of finite numbers, got %s" % str(aim))
		return []
	var ctx := _drop_context("drop_expected", unit_id, step_index)
	if ctx.is_empty():
		return []
	var u: Unit = ctx["unit"]
	var d := Bombs.release_rule(Bombs.plan_drop(ctx["samples"], float(a[0]), float(a[1]), bombs), bombs)
	if d.get("ok", false) != true:
		return []   # outside the cone and "hold": nothing is released, so nothing is hurt
	var centre := Vector2(float((d["aim"] as Array)[0]), float((d["aim"] as Array)[1]))
	var reach := BombExpect.reach_m(d, u.def.bomb_per_drop, bombs)
	var out: Array = []
	for id: String in units:
		var t: Unit = units[id]
		if t.down or id == unit_id:
			continue
		var h := _state_height(_start_state(t))
		if h > bombs.blast_height_m:
			continue
		var at := Vector2(t.x, t.y)
		var dist := at.distance_to(centre)
		if dist > reach:
			continue
		var e := BombExpect.damage(d, u.def.bomb_per_drop, bombs, at, t.health, h)
		if float(e["mean_raw"]) <= 0.0:
			continue
		out.append({"unit": id, "mean": e["mean"], "mean_raw": e["mean_raw"], "p_destroy": e["p_destroy"], "health": t.health, "distance_m": dist})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool:
		if float(x["mean"]) != float(y["mean"]):
			return float(x["mean"]) > float(y["mean"])
		return str(x["unit"]) < str(y["unit"]))
	return out

# The bombs still falling, for a joining client (WorldSync's snapshot should carry them) and its twin.
func net_bombs() -> Array:
	return bombs_in_flight.duplicate(true)

func apply_net_bombs(list: Array) -> void:
	bombs_in_flight = list.duplicate(true)

static func _aim_point(v: Variant) -> Array:
	if v is Vector2:
		return [(v as Vector2).x, (v as Vector2).y] if (v as Vector2).is_finite() else []
	if v is Array and (v as Array).size() >= 2 and _is_finite_number(v[0]) and _is_finite_number(v[1]):
		return [float(v[0]), float(v[1])]
	return []

# --- Ready-up ----------------------------------------------------------------

# Everyone whose ready flag holds up the turn: the active human players, and
# the AI if any MOBILE unit is AI-controlled (a static unit has no plan to make, so an AI
# side that is only towers and batteries has nothing to wait for).
func participants() -> Array[String]:
	var out: Array[String] = players.duplicate()
	for id: String in units:
		var u: Unit = units[id]
		if u.controller == CONTROLLER_AI and not u.def.is_static():
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
# Array of states}, events: Array, units: {unit id -> Unit.net_state()}}, or
# {} if not everyone is ready. The whole result is what a host sends its
# clients (apply_resolution).
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
		# A unit that is already down is not reported leaving or entering the map.
		if not u.down and bool(s["out_of_bounds"]) != bool(prev["out_of_bounds"]):
			events.append({
				"type": "left_bounds" if s["out_of_bounds"] else "returned_to_bounds",
				"unit": id, "turn": turn, "step": k, "t": s["t"], "x": s["x"], "y": s["y"],
			})
		(histories[id] as Array).append(s)
		cursor[id] = s

	# COMBAT, after motion (which it does not change; Track C, combat.gd). The
	# sampler reads the histories just built, so they go on the units first. The
	# bombers' drops are counted against their loads first (bombs.gd), and the
	# resolver releases and lands the bombs on its ticks.
	for id: String in units:
		(units[id] as Unit).history = histories[id]
	_resolve_followed_drops(histories)
	for id: String in units:
		_apply_drop_limits(units[id], histories[id], 1)
	var fight := _combat_resolver.run(units, histories, turn, rng_seed, rules.turn_seconds,
		func(uid: String, t: float) -> Dictionary: return sample(uid, t, "history"),
		func(band: String) -> float: return band_height(band), bombs_in_flight)
	var down_at: Dictionary = fight["down_at"]
	var fates: Dictionary = fight["fates"]
	bombs_in_flight = fight["bombs"]
	for id: String in units:
		var u: Unit = units[id]
		u.health = int(fight["health"][id])
		u.down_at = NAN
		u.drops_left = maxi(u.drops_left - int((fight["released"] as Dictionary).get(id, 0)), 0)
	# Units that went down this turn: their fate. An exploded unit is gone at
	# down_at. An out-of-control one is flown on from there: its path after
	# down_at is rebuilt as a fall (the states before are untouched).
	for id: String in down_at:
		var u: Unit = units[id]
		u.down = true
		u.down_at = float(down_at[id])
		u.fate = str((fates[id] as Dictionary)["fate"])
		if u.fate == Unit.FATE_OUT_OF_CONTROL:
			u.fall_dir = int((fates[id] as Dictionary)["spin"])
			histories[id] = _begin_fall(u, histories[id], u.down_at)
			u.history = histories[id]
	# What a unit did after it went down is not reported: its bounds events past
	# down_at describe a path it no longer flies.
	if not down_at.is_empty():
		events = events.filter(func(ev: Dictionary) -> bool:
			return not (down_at.has(str(ev.get("unit", ""))) and float(ev.get("t", 0.0)) > float(down_at[str(ev["unit"])])))
	# Out-of-control units that reach the ground this turn (the ones that fell
	# into it from an earlier turn, and the ones that went down in this one).
	var crash_at := {}
	var crash_events: Array = []
	for id: String in units:
		var u: Unit = units[id]
		if u.fate != Unit.FATE_OUT_OF_CONTROL:
			continue
		var tc := _crash_time(histories[id])
		if is_nan(tc):
			continue
		crash_at[id] = tc
		var at := sample(id, tc, "history")
		crash_events.append({"type": "crash", "turn": turn, "unit": id, "t": tc, "x": at["x"], "y": at["y"]})
	crash_events.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["t"]) < float(b["t"]))
	events = CombatResolver.merge_events(CombatResolver.merge_events(events, fight["events"]), crash_events)

	for id: String in units:
		var u: Unit = units[id]
		var h: Array = histories[id]
		var last: Dictionary = h[h.size() - 1]
		if crash_at.has(id) or (down_at.has(id) and (u.fate == Unit.FATE_EXPLODED or u.fate == Unit.FATE_DESTROYED)):
			# It stops where it exploded or struck the ground, not where its path
			# would have ended the turn.
			var stop: float = float(crash_at[id]) if crash_at.has(id) else float(down_at[id])
			var at := sample(id, stop, "history")
			at["speed"] = 0.0
			u.apply_state(at)
			u.out_of_bounds = not in_bounds(float(at["x"]), float(at["y"]))
			if crash_at.has(id):
				u.fate = Unit.FATE_CRASHED
				u.fall_height_m = 0.0
				u.fall_dir = 0
		else:
			u.apply_state(last)
			u.out_of_bounds = bool(last["out_of_bounds"])
			if u.fate == Unit.FATE_OUT_OF_CONTROL:
				u.fall_height_m = float(last["fall_height_m"])
		u.plan.clear()

	_set_phase(PHASE_RESOLVED)
	for ev: Dictionary in events:
		if ev["type"] == "left_bounds":
			unit_left_bounds.emit(str(ev["unit"]), turn, int(ev["step"]))
	turn_resolved.emit(turn, histories, events)
	return {"turn": turn, "histories": histories, "events": events, "units": _net_states(), "bombs": bombs_in_flight.duplicate(true)}

# THE NETWORK CONTRACT (proposed by the lead for the first fight, 2026-10-09;
# Alex: the host resolves each turn and sends the result): a World that did
# not resolve this turn itself -- a client -- applies the host's resolve()
# result as if it had. From the planning phase, for this World's own turn,
# with exactly this World's units; otherwise it changes nothing and returns
# false. Ready flags are left for begin_turn() to reset, as after a resolve;
# plans are consumed. Emits what resolve() emits, in the same order, so the
# interface plays it back unchanged.
func apply_resolution(result: Dictionary) -> bool:
	if phase != PHASE_PLANNING:
		_fail("apply_resolution: only from the planning phase (phase is %s)" % phase)
		return false
	for k: String in ["turn", "histories", "events", "units"]:
		if not result.has(k):
			_fail("apply_resolution: the result has no '%s'" % k)
			return false
	if int(result["turn"]) != turn:
		_fail("apply_resolution: the result is for turn %d, this world is on turn %d" % [int(result["turn"]), turn])
		return false
	var states: Dictionary = result["units"]
	var histories: Dictionary = result["histories"]
	if states.size() != units.size():
		_fail("apply_resolution: the result has %d units, this world %d" % [states.size(), units.size()])
		return false
	for id: String in units:
		if not states.has(id) or not histories.has(id):
			_fail("apply_resolution: the result has no state or history for '%s'" % id)
			return false
	_set_phase(PHASE_RESOLVING)
	for id: String in units:
		var u: Unit = units[id]
		u.apply_net_state(states[id])
		u.history = (histories[id] as Array).duplicate(true)
		u.plan.clear()
	# The bombs still falling after this turn (a result without them has none).
	bombs_in_flight = (result.get("bombs", []) as Array).duplicate(true)
	_set_phase(PHASE_RESOLVED)
	var events: Array = (result["events"] as Array).duplicate(true)
	for ev: Dictionary in events:
		if ev["type"] == "left_bounds":
			unit_left_bounds.emit(str(ev["unit"]), turn, int(ev["step"]))
	turn_resolved.emit(turn, histories.duplicate(true), events)
	return true

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

func _net_states() -> Dictionary:
	var out := {}
	for id: String in units:
		out[id] = (units[id] as Unit).net_state()
	return out

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
		s["height_m"] = u.fall_height_m if is_finite(u.fall_height_m) else band_height(u.altitude_band)
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
	# Height: the band heights, or for a falling unit (its states carry
	# fall_height_m) the continuous fall height, never below the ground.
	var ha := _state_height(a)
	var hb := _state_height(b)
	p["height_m"] = ha + (hb - ha) * f
	if a.has("fall_height_m") or b.has("fall_height_m"):
		p["height_m"] = maxf(float(p["height_m"]), 0.0)
	return p

# --- Internals ---------------------------------------------------------------

# The plan's states for every step of the turn, from the unit's current state.
func _run_plan(u: Unit) -> Array:
	var out: Array = []
	var cur: Dictionary = _start_state(u)
	for k in u.def.actions_per_turn:
		cur = _step(u, k, cur)
		out.append(cur)
	_apply_drop_limits(u, out, 0)
	return out

# One step: the unit's request for step k (or "carry on"), clamped from `prev`.
# The ONLY place a step is computed, so the preview and the resolve agree.
func _step(u: Unit, k: int, prev: Dictionary) -> Dictionary:
	var n := u.def.actions_per_turn
	# A unit that is down takes no orders. Out of control, the sim flies it
	# (a spiral that loses height); exploded or crashed, it stays where it is.
	if u.fate == Unit.FATE_OUT_OF_CONTROL:
		var fs := _fall_step(u, prev, rules.step_dt(n), u.fall_dir)
		fs["step"] = k
		fs["t"] = rules.turn_seconds * float(k + 1) / float(n)
		return fs
	# A unit that is down takes no orders and a static one never had any: it stands where it is.
	if u.down or u.def.is_static():
		var ws := prev.duplicate(true)
		ws["speed"] = 0.0
		ws["turn"] = 0.0
		ws["clamped"] = false
		ws["limits"] = []
		ws["planned"] = false
		ws["step"] = k
		ws["t"] = rules.turn_seconds * float(k + 1) / float(n)
		return ws
	var planned := k < u.plan.size() and not (u.plan[k] as Dictionary).is_empty()
	var req: Variant = u.plan[k] if k < u.plan.size() else {}
	var s := u.def.envelope.clamp_step(prev, req, rules.step_dt(n))
	s["step"] = k
	s["t"] = rules.turn_seconds * float(k + 1) / float(n)
	s["planned"] = planned
	s["out_of_bounds"] = not in_bounds(float(s["x"]), float(s["y"]))
	if req is Dictionary and (req as Dictionary).has("drop"):
		s["drop"] = _drop_state(u, k, prev, s, req)
	return s

# --- Bombs (Track S2; scripts/sim/bombs.gd has the model) -----------------------------------------

# The analysis of the drop a step's request carries (Bombs.plan_drop), for the step that goes from
# `prev` to `cur`; {"ok": false, "reason": ...} when it cannot happen (a unit with no bombs).
# Drop limits (no drops left) are applied by _apply_drop_limits once the whole turn's states exist.
func _drop_state(u: Unit, k: int, prev: Dictionary, cur: Dictionary, req: Variant) -> Dictionary:
	var aim := Envelope.drop_aim(req)
	if aim.is_empty():
		return {"ok": false, "reason": "no_aim"}
	if not u.def.carries_bombs():
		return {"ok": false, "reason": "no_bombs", "requested": aim}
	var d := Bombs.release_rule(Bombs.plan_drop(_drop_samples(u, k, prev, cur), float(aim[0]), float(aim[1]), bombs), bombs)
	var target := Envelope.drop_target(req)
	if not target.is_empty():
		d["target"] = target
	return d

# THE FOLLOWED UNITS (Track T; Alex: "Targeting a moving unit like a tank should follow the unit. We need to pick the
# release point for bombs and things dynamically."). A step's drop whose target is a UNIT was analysed by _step for the
# aim the request names (the unit where the planning player saw it: the preview, no projection of the enemy's motion).
# Now that every unit's history of the turn exists, that drop is analysed again with the aim as a function of the release
# moment: the target's position at t, led by its velocity at t times the fall time of a bomb released at t (bombs.gd,
# followed_aim -- PROPOSED), the release at the moment of the step with the smallest release error for that aim. The
# outside-the-cone switch applies as for any drop (release_rule). A point target and a drop with no target are untouched.
# `histories` is the turn just built and is on the units (sample() reads it).
func _resolve_followed_drops(histories: Dictionary) -> void:
	for id: String in units:
		var u: Unit = units[id]
		if not u.def.carries_bombs():
			continue
		var h: Array = histories[id]
		for i in range(1, h.size()):
			var st: Dictionary = h[i]
			var d: Variant = st.get("drop")
			if not (d is Dictionary) or not (d as Dictionary).has("target"):
				continue
			var target: Dictionary = (d as Dictionary)["target"]
			var reason := str((d as Dictionary).get("reason", ""))
			if not target.has("unit") or not units.has(str(target["unit"])) or reason == "no_aim" or reason == "no_bombs":
				continue
			var samples := _drop_samples(u, int(st["step"]), h[i - 1], st)
			var followed_id := str(target["unit"])
			var aim_at := func(t: float) -> Vector2:
				var bomber := Bombs.sample_at(samples, t)
				return Bombs.followed_aim(sample(followed_id, t, "history"), float(bomber["height_m"]), bombs)
			var rec := Bombs.release_rule(Bombs.plan_drop_moving(samples, aim_at, bombs), bombs)
			rec["target"] = target
			rec["followed"] = true
			st["drop"] = rec

# The unit and the bomber through step `step_index` of its current plan, for drop_cone and
# drop_spread: {unit, samples}, or {} with last_error for a unit with no bombs, a down unit or a
# step out of range.
func _drop_context(who: String, unit_id: String, step_index: int) -> Dictionary:
	var u := _unit(unit_id)
	if u == null:
		return {}
	if not u.def.carries_bombs():
		return _fail_d("%s: a %s carries no bombs" % [who, u.type])
	if u.down:
		return _fail_d("%s: unit '%s' is down" % [who, unit_id])
	var n := u.def.actions_per_turn
	if step_index < 0 or step_index >= n:
		return _fail_d("%s: a %s has steps 0..%d this turn, got %d" % [who, u.type, n - 1, step_index])
	var states := _run_plan(u)
	var prev: Dictionary = _start_state(u) if step_index == 0 else states[step_index - 1]
	return {"unit": u, "samples": _drop_samples(u, step_index, prev, states[step_index])}

# The bomber through step k, from `prev` to `cur` (bombs.gd make_samples).
func _drop_samples(u: Unit, k: int, prev: Dictionary, cur: Dictionary) -> Array:
	var n := u.def.actions_per_turn
	var t0 := rules.turn_seconds * float(k) / float(n)
	var t1 := rules.turn_seconds * float(k + 1) / float(n)
	return Bombs.make_samples(prev, cur, t0, t1, _state_height(prev), _state_height(cur), bombs.release_samples)

# Count a turn's drops against the unit's load: the first drops_left drops stand, the rest are refused
# ({"ok": false, "reason": "no_drops"}). `states` are the step states in order, `first` the index of
# the first step in the array (1 in a history, whose entry 0 is the start of the turn).
func _apply_drop_limits(u: Unit, states: Array, first: int) -> void:
	var used := 0
	for i in range(first, states.size()):
		var d: Variant = (states[i] as Dictionary).get("drop")
		if not (d is Dictionary) or (d as Dictionary).get("ok", false) != true:
			continue
		if used >= u.drops_left:
			var refused: Dictionary = {"ok": false, "reason": "no_drops", "requested": (d as Dictionary).get("requested", [])}
			if (d as Dictionary).has("target"):
				refused["target"] = (d as Dictionary)["target"]
			(states[i] as Dictionary)["drop"] = refused
		else:
			used += 1

func _start_state(u: Unit) -> Dictionary:
	var s := u.state()
	s["step"] = -1
	s["t"] = 0.0
	s["turn"] = 0.0
	s["planned"] = false
	s["clamped"] = false
	s["limits"] = []
	s["out_of_bounds"] = u.out_of_bounds
	if is_finite(u.fall_height_m):
		s["fall_height_m"] = u.fall_height_m
	return s

# --- A unit going down out of control (Track C; combat.gd, WHAT A KILL DOES) -----
#
# The fall is flown by the sim, not planned: a spiral at a fixed turn rate in the
# direction the fate roll picked (spin), holding or gaining speed, losing height
# at a fixed rate (data/sim/combat.json fall_*). Its states carry
# fall_height_m, metres above the ground (0 m; no terrain), unclamped: it goes
# negative in the step that reaches the ground, and sample() clamps at 0. The
# crash is the moment the height crosses 0 (_crash_time).

# The state `d` seconds on from `prev` (a falling unit's state with fall_height_m),
# as an arc like any step: the caller sets step and t.
func _fall_step(u: Unit, prev: Dictionary, d: float, spin: int) -> Dictionary:
	var v0 := float(prev["speed"])
	var v1 := minf(v0 + combat.fall_speed_gain * d, maxf(v0, u.def.envelope.dive_speed_max))
	var turn := float(spin) * combat.fall_turn_rate * d
	var h0 := float(prev["heading"])
	var end := Envelope.advance(float(prev["x"]), float(prev["y"]), h0, turn, (v0 + v1) * 0.5 * d)
	var h1 := float(prev["fall_height_m"]) - combat.fall_descent * d
	return {
		"x": end[0], "y": end[1], "heading": Envelope.wrap_angle(h0 + turn), "speed": v1,
		"altitude_band": _nearest_band(u, maxf(h1, 0.0)),
		"turn": turn, "clamped": false, "limits": [], "planned": false,
		"out_of_bounds": not in_bounds(float(end[0]), float(end[1])),
		"fall_height_m": h1,
	}

# `hist` (a unit's history this turn, as motion built it) with the unit set to
# fall from t_d: the states before t_d stay as they are, a state AT t_d is
# inserted (unless a step already ends there) carrying the height it had, and
# every later state is the fall. The inserted state keeps the step's end speed
# and takes the share of its turn up to t_d, so the arc into it is the old arc
# exactly: nothing before t_d moves. The unit's fate and fall_dir are already
# set. `u.history` must still be `hist`.
func _begin_fall(u: Unit, hist: Array, t_d: float) -> Array:
	const EPS := 1e-9
	var k := 1
	while k < hist.size() - 1 and float(hist[k]["t"]) < t_d - EPS:
		k += 1
	var out: Array = []
	for i in k:
		out.append(hist[i])
	var b: Dictionary = hist[k]
	var at := sample(u.id, t_d, "history")
	var c: Dictionary
	var first_after := k
	if absf(float(b["t"]) - t_d) <= EPS:
		c = b.duplicate(true)
		first_after = k + 1
	else:
		var a: Dictionary = hist[k - 1]
		var f := (t_d - float(a["t"])) / (float(b["t"]) - float(a["t"]))
		c = {
			"x": at["x"], "y": at["y"], "heading": at["heading"], "speed": float(b["speed"]),
			"altitude_band": at["altitude_band"], "turn": float(b["turn"]) * f,
			"step": b["step"], "t": t_d, "planned": b["planned"], "clamped": false, "limits": [],
			"out_of_bounds": not in_bounds(float(at["x"]), float(at["y"])),
		}
	c["fall_height_m"] = float(at["height_m"])
	out.append(c)
	var prev := c
	for i in range(first_after, hist.size()):
		var old: Dictionary = hist[i]
		var s := _fall_step(u, prev, float(old["t"]) - float(prev["t"]), u.fall_dir)
		s["step"] = old["step"]
		s["t"] = old["t"]
		out.append(s)
		prev = s
	return out

# When, in seconds into the turn, a falling unit's path reaches the ground: the
# height is linear between states, so the crossing is exact. NAN if it does not
# this turn.
func _crash_time(path: Array) -> float:
	for i in range(1, path.size()):
		var a: Dictionary = path[i - 1]
		var b: Dictionary = path[i]
		if not a.has("fall_height_m") or not b.has("fall_height_m"):
			continue
		var ha := float(a["fall_height_m"])
		var hb := float(b["fall_height_m"])
		if ha <= 0.0:
			return float(a["t"])
		if hb <= 0.0:
			return float(a["t"]) + (float(b["t"]) - float(a["t"])) * ha / (ha - hb)
	return NAN

# The band of the unit's own (low, medium, high) nearest to a height: what a
# falling unit's altitude_band reads.
func _nearest_band(u: Unit, height: float) -> String:
	var best := ""
	var best_d := INF
	for band: String in u.def.envelope.bands:
		var d := absf(band_height(band) - height)
		if d < best_d:
			best_d = d
			best = band
	return best

# A state's height: the continuous fall height while falling, else its band's.
func _state_height(s: Dictionary) -> float:
	if s.has("fall_height_m"):
		return float(s["fall_height_m"])
	return band_height(str(s["altitude_band"]))

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
