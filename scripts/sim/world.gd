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
# THE GUNS (Track SH, the warship, proposed 2026-10-10; Alex's decision mixed-warfare: the warship's big guns are specials,
# "fired by hand with a long reload, aimed with the target selection", at a target the side has SPOTTED -- shared spotting,
# "Yes": any friendly unit's sight counts). A unit's special is the bomb drop (above) OR a gun salvo: a step request may carry
# {"fire": {"special": "main_guns", "target": {"unit": id} | {"point": [x, y]}}} (guns.gd has the model, gun_rules.gd the numbers
# in data/sim/guns.json, spotting.gd the sight). gun_check() answers the interface: whether the special can be switched on in a step
# for a target and why not (reloading, out of range, unspotted, ...); plan_step() accepts any well-formed fire and the step's
# "fire" analysis says whether it would go off. At resolve the salvo is fired at the moment fire_at of its step IF the target is
# still spotted and in range then (else a gun_hold event and nothing is spent); its shells fly for seconds, may land in a LATER turn
# (shells_in_flight, carried like the bombs and handed to a client by apply_resolution) and hurt ANY unit at the surface near the
# impact by the blast table of data/sim/guns.json. The scatter grows with the range and shrinks with the time the target has been
# spotted (spot_memory) and the salvos already fired at it (gun_memory, the bracketing). The sight rules are the fog's and the AI's;
# line of sight is a seam (set_sight_los), as the water and the ground are.
#
# THE WATER (Track WS, proposed 2026-10-10; Alex's decisions water-layer and boat-looks: boats and bridges are
# units, part of the environment). A SEA unit (data/units: domain "sea", with a draught_m) sails only on water.
# The World does not know the generator: it is GIVEN a water query, as a Callable, and without one the rule is
# off (the sim stays testable on its own):
#
#   world.set_water(Callable(water_gen, "depth_at"))   # (x, y) -> metres of water; 0 or less on land
#   world.afloat_at(x, y, heading, unit_id)            # would this unit's hull be over water deep enough there
#   world.unit_afloat(unit_id)                         # ... is it, now
#
# Water at least draught_m deep must lie under the unit's centre and both ends of its hull (data/sim/sea.json
# hull_fraction) all along every step it plans. A step that would leave the water is CLAMPED the way the
# envelope clamps, not refused: the same turn at slower and slower end speeds (down to the floor of the step's
# speed window), and if even the slowest would leave the water the unit is HELD (it stays where it is, speed
# 0); either way the step reports clamped and the limit "shore" (Envelope.LIMIT_SHORE). add_unit refuses to
# put a sea unit where it would not float. The AI never plans onto land (ai_pilot.gd, role "sail"); the clamp
# is the rule for a human's plan and the net under the AI's.
#
# THE GROUND (Track TK2, proposed 2026-10-11; data/sim/ground.json, scripts/sim/ground_rules.gd): a GROUND unit that moves (data/units:
# domain "ground", mobility "mobile": the tank) stays on dry land, never crosses a height step except on a road (Alex, decision
# terrain-passability A: every height step is a cliff, ramps do not exist yet), crosses a river only over an INTACT bridge unit
# (data/units/bridge.json; a destroyed bridge is water again), and drives faster on a road than off it (a speed factor on its top
# speed; woods slower again, never a block). Like the water the World is GIVEN its eyes, as Callables, and without them the rule is off:
#
#   world.set_ground(level_fn, road_fn, woods_fn, path_fn)   # (x, y) -> level int; -> metres to the road; -> tree density 0..1;
#                                                            # (from, to) -> the road between two points (scripts/world/ground_map.gd)
#   world.ground_ok_at(x, y, heading, unit_id)               # may this unit's hull stand there (no water, no cliff)
#   world.ground_on_road(x, y)                               # is a point on the road (or an intact bridge's deck)
#
# A step that would break the rule is CLAMPED like a sea unit's: slowed, else held, with the limit "cliff", "water" (or "terrain" where
# the going only slowed it). The AI never plans such a step (ai_drive.gd); the clamp is the rule for a human's plan and the net under
# the AI's. And THE PLANNER sees the same rules: reachable() clips the fan of a ground unit by the ground rule and of a sea unit by the
# water rule, so a player sees where a tank or a ship can go and cannot place a step it cannot make.
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
const SeaRules = preload("res://scripts/sim/sea_rules.gd")
const Guns = preload("res://scripts/sim/guns.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")
const Spotting = preload("res://scripts/sim/spotting.gd")
const GroundRules = preload("res://scripts/sim/ground_rules.gd")
const JsMath = preload("res://scripts/core/js_math.gd")

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
# The water rule's numbers (data/sim/sea.json) and the water query a sea unit is kept afloat by (set_water); an
# invalid Callable means no water: sea units move as any unit does.
var sea: SeaRules
var water_depth: Callable = Callable()
# The big-gun specials (Track SH; data/sim/guns.json), the shells still in the air (guns.gd header has the record; carried across turns
# by resolve(), handed to a client by apply_resolution()), shared spotting, and what a side remembers between turns: spot_memory
# {side: {enemy unit id: seconds it has been spotted without a break, at the turn's end}} (the ranging in) and gun_memory (the
# bracketing: Guns.bracket_after has the records).
var guns: GunRules
var shells_in_flight: Array = []
var spotting: Spotting
var spot_memory: Dictionary = {}
var gun_memory: Array = []
# The ground rule's numbers (data/sim/ground.json) and the queries a ground unit is kept on dry, level land by (set_ground), which
# also holds the rule itself (ground_rules.gd). Without queries (and without water) ground units move as any unit does.
var ground: GroundRules
var _fan_cache: Dictionary = {}   # key -> PackedVector2Array: the ruled fans asked for lately (_ruled_outline)

var _combat_resolver: CombatResolver

func _init(turn_path: String = SimRules.TURN_PATH, altitude_path: String = SimRules.ALTITUDE_PATH, unit_dir: String = UnitDef.UNITS_DIR, combat_path: String = CombatRules.PATH, bombs_path: String = BombRules.PATH, sea_path: String = SeaRules.PATH, guns_path: String = GunRules.PATH) -> void:
	rules = SimRules.new(turn_path, altitude_path)
	units_dir = unit_dir
	errors.append_array(rules.errors)
	bounds = rules.bounds
	combat = CombatRules.new(combat_path)
	errors.append_array(combat.errors)
	bombs = BombRules.new(bombs_path)
	errors.append_array(bombs.errors)
	sea = SeaRules.new(sea_path)
	errors.append_array(sea.errors)
	ground = GroundRules.new()
	errors.append_array(ground.errors)
	guns = GunRules.new(guns_path)
	errors.append_array(guns.errors)
	spotting = Spotting.new()
	_combat_resolver = CombatResolver.new(combat, bombs, guns)

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

# --- Water (Track WS; the header's THE WATER) ----------------------------------------

# Give the World its water: `depth_fn` is a Callable (x: float, y: float) -> float, the metres of water at a point
# (0 or less where there is none, an upland included). An invalid Callable takes the water away again.
func set_water(depth_fn: Callable) -> void:
	water_depth = depth_fn
	_fan_cache.clear()

func has_water() -> bool:
	return water_depth.is_valid()

# Metres of water at a point; 0.0 when the World has no water.
func water_depth_at(px: float, py: float) -> float:
	if not water_depth.is_valid():
		return 0.0
	return float(water_depth.call(px, py))

# Would a hull of this unit's type, centred at (px, py) and pointing along `heading`, float there: water at
# least its draught deep under the centre and under both ends. True when the World has no water or the unit
# does not float (domain other than sea).
func afloat_at(px: float, py: float, heading: float, unit_id: String) -> bool:
	var u := _unit(unit_id)
	if u == null:
		return false
	return _afloat_pose(u.def, px, py, heading)

# Is the unit afloat where it is now?
func unit_afloat(unit_id: String) -> bool:
	var u := _unit(unit_id)
	return u != null and _afloat_pose(u.def, u.x, u.y, u.heading)

# --- Ground (Track TK2; the header's THE GROUND) ------------------------------------------------------

# Give the World the ground's eyes (any of them; an invalid Callable switches that part of the rule off): `level_fn` (x, y) -> the
# height level (int), `road_fn` (x, y) -> metres to the nearest road centre line (INF when none), `woods_fn` (x, y) -> the tree density
# 0..1, `path_fn` (from: Vector2, to: Vector2) -> PackedVector2Array, the road between two points (the AI's "drive" role asks for it).
func set_ground(level_fn: Callable, road_fn: Callable = Callable(), woods_fn: Callable = Callable(), path_fn: Callable = Callable()) -> void:
	ground.set_queries(level_fn, road_fn, woods_fn, path_fn)
	_fan_cache.clear()

# Does the ground rule have anything to judge by: a ground query, or water (no ground unit drives into water)?
func has_ground() -> bool:
	return ground.has_queries() or water_depth.is_valid()

# Is the point on the road (its centre line within road_half_m) or on the deck of an intact bridge?
func ground_on_road(px: float, py: float) -> bool:
	return ground.road_dist(px, py) <= ground.road_half_m or ground.on_span(ground.spans(units), px, py)

# The road between two points as a polyline (empty without a road query or a road).
func ground_road_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	return ground.road_path(from, to)

# May a hull of this unit's type, centred at (px, py) and pointing along `heading`, stand there: no water under it (but for an
# intact bridge) and no height step under it off a road. True when the rule has nothing to judge by or the unit is not a ground unit
# that moves.
func ground_ok_at(px: float, py: float, heading: float, unit_id: String) -> bool:
	var u := _unit(unit_id)
	if u == null:
		return false
	return _grounded_pose(u.def, px, py, heading)

# Is the unit on legal ground where it is now?
func unit_grounded(unit_id: String) -> bool:
	var u := _unit(unit_id)
	return u != null and _grounded_pose(u.def, u.x, u.y, u.heading)

# Does the ground rule apply to this unit type: a ground unit that moves, in a World that can judge?
func _ground_rule_on(def: UnitDef) -> bool:
	return def.domain == "ground" and not def.is_static() and has_ground()

func _grounded_pose(def: UnitDef, px: float, py: float, heading: float) -> bool:
	if not _ground_rule_on(def):
		return true
	return ground.pose_ok(def.size_m, px, py, heading, ground.spans(units), water_depth)

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
	if def.domain == "sea" and water_depth.is_valid() and not _afloat_pose(def, float(spec["x"]), float(spec["y"]), float(spec["heading"])):
		return _fail_s("add_unit: a %s needs water %.1f m deep under it and would not float at (%.0f, %.0f)" % [type_id, def.draught_m, float(spec["x"]), float(spec["y"])])
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
	if req.has("fire"):
		var fire_problem := _fire_request_problem(u, step_index, req)
		if fire_problem != "":
			return _fail_d("plan_step: " + fire_problem)
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
	var out := u.def.envelope.reachable(from, rules.step_dt(n))
	if _ruled(u.def) and not u.down:
		out["outline"] = _ruled_outline(u, from, rules.step_dt(n))   # the fan, clipped by the water or ground rule (Track TK2)
	return out

# Is the unit's type one the World keeps somewhere: a sea unit on water, a ground unit on dry level land?
func _ruled(def: UnitDef) -> bool:
	return (def.domain == "sea" and water_depth.is_valid()) or _ground_rule_on(def)

# THE FAN UNDER A RULE (Track TK2): the envelope's outline of reachable end points, where every sample's end is the end of the step
# the World would really make for it: the far edge (the fastest step at each turn) and the near edge (the slowest), each put through
# the water or the ground rule, which slows it short of a shore, a cliff or a river and holds it (the apex) where even the slowest
# would break it. So a point inside the fan is a step the unit can make, and a click outside it is clamped by the same rule anyway.
# The same sampling as Envelope.reachable (9 turns), the same shape (the far edge left to right, then the near edge back).
func _ruled_outline(u: Unit, from: Dictionary, dt: float, samples: int = 9) -> PackedVector2Array:
	var env := u.def.envelope
	var v0 := float(from["speed"])
	var turn_max := env.turn_rate(v0) * dt
	var spans: Array = ground.spans(units) if u.def.domain == "ground" else []
	# A fan costs a few dozen milliseconds (eighteen steps, each looked at a few times along its arc) and the planner asks for it as often
	# as the pointer moves, so the fans asked for lately are kept, by unit, start state and the bridges that stand.
	var key := "%s|%d|%.9f|%.9f|%.12f|%.9f|%d" % [u.id, samples, float(from["x"]), float(from["y"]), float(from["heading"]), v0, hash(str(spans))]
	if _fan_cache.has(key):
		return _fan_cache[key]
	var far := PackedVector2Array()
	var near := PackedVector2Array()
	var count := maxi(samples, 2)
	for i in count:
		var t := -turn_max + 2.0 * turn_max * float(i) / float(count - 1)
		var w := env.speed_window(v0, dt, env.turn_loss(t, turn_max, dt), env.speed_max)
		for edge in 2:
			var c := env.clamp_step(from, {"turn": t, "speed": w[1] if edge == 0 else w[0]}, dt)
			if u.def.domain == "sea":
				c = _keep_afloat(u, from, c, dt)
			else:
				c = ground.keep(u.def, from, c, dt, spans, water_depth)
			var p := Vector2(float(c["x"]), float(c["y"]))
			if edge == 0:
				far.append(p)
			else:
				near.append(p)
	near.reverse()
	far.append_array(near)
	if _fan_cache.size() >= 64:
		_fan_cache.clear()
	_fan_cache[key] = far
	return far

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

# --- Guns: what the interface asks, and the model (Track SH, the warship, proposed 2026-10-10; guns.gd, spotting.gd) -----------------

# The ids of the gun specials a unit has: the specials of its type (data/units/<id>.json) that have a record in data/sim/guns.json.
func gun_specials(unit_id: String) -> Array[String]:
	var out: Array[String] = []
	if not units.has(unit_id):
		return out
	for sp: Variant in (units[unit_id] as Unit).def.specials:
		var sid := str((sp as Dictionary).get("id", ""))
		if guns.has_special(sid):
			out.append(sid)
	return out

func has_guns(unit_id: String) -> bool:
	return not gun_specials(unit_id).is_empty()

# Does any unit of the world have a gun special (so the spotting memory is worth keeping)?
func _has_gun_units() -> bool:
	for id: String in units:
		if not gun_specials(id).is_empty():
			return true
	return false

# Turns until the unit's guns are loaded: 0 when they are loaded now (a salvo fired in turn N is ready in turn N + reload_turns + 1).
# Counted from the turn being planned: once a turn is resolved it is counted from the next one, so the roster does not say 'reload 3'
# for the turn that has just been fired in.
func gun_reload_left(unit_id: String, special_id: String) -> int:
	if not units.has(unit_id):
		return 0
	var from_turn := turn if phase == PHASE_PLANNING else turn + 1
	return maxi(0, (units[unit_id] as Unit).gun_ready_turn(special_id) - from_turn)

# Hand the World a line-of-sight query for the spotting (spotting.gd header: the same query the fog uses, where it uses one). An
# invalid Callable takes it away: sight is the circle alone, which is the fog's own default (data/view/fog.json).
func set_sight_los(los: Callable) -> void:
	spotting.los = los
	spotting.forget()

# The sight radius scale (the fog's sight_range_scale knob, 1.0), for the spotting.
func set_sight_scale(scale: float) -> void:
	spotting.sight_scale = scale
	spotting.forget()

# Is the target ({"unit": id} | {"point": [x, y]}) spotted by `side` as the world stands (the planning phase), by any unit of the side?
func spotted_now(side: String, target: Dictionary) -> bool:
	return spotting.spotted_now(self, side, target)

# The units of `side` that see the target now, in World order.
func spotters_now(side: String, target: Dictionary) -> Array[String]:
	return spotting.spotters_now(self, side, target)

# CAN THE SPECIAL BE SWITCHED ON in step `step_index` of the unit's current plan, for `target` ({"unit": id} | {"point": [x, y]})?
# Plan the step's motion first (the guns fire from where the step puts the ship), then ask. Returns {} (and last_error) for an
# unknown unit or a step out of range; otherwise a record whose "ok" says yes or no and "reason" why not, a word of Guns (WHY_*):
# "reloading", "already_planned" (another step fires this special: one salvo a turn), "no_target", "target_down", "own_side",
# "too_close", "out_of_range", "unspotted", "not_a_gun", "unit_down"; checked in that order. The rest is what the card and the map
# show, always filled in when it can be:
#   special, step, target (normalised), target_pos Vector2 (where the target is now), from Vector2 (the guns at the moment of
#   fire), fire_t (seconds into the turn), range_m, range_min_m, range_max_m, spotted (bool), by (the first unit that sees it, or ""),
#   spotters (all of them), spotted_s (the seconds it will have been spotted at the moment of fire if it stays so: the ranging),
#   salvos (the bracketing: salvos already fired at it), spread_m (one shell's scatter, sigma, expected), aim_factor, flight_s,
#   impact_t (seconds after the start of THIS turn the shells land), lands_in_turn, reload_left, ready_turn.
# The target's motion is NOT projected at planning (as for the bombs: the card shows where it is seen); at resolve the salvo leads it.
func gun_check(unit_id: String, step_index: int, target: Variant, special_id: String = "") -> Dictionary:
	var u := _unit(unit_id)
	if u == null:
		return {}
	var ids := gun_specials(unit_id)
	if special_id == "":
		if ids.is_empty():
			return {"ok": false, "reason": Guns.WHY_NOT_A_GUN, "special": "", "step": step_index}
		special_id = ids[0]
	if not ids.has(special_id):
		return {"ok": false, "reason": Guns.WHY_NOT_A_GUN, "special": special_id, "step": step_index}
	var n := u.def.actions_per_turn
	if step_index < 0 or step_index >= n:
		return _fail_d("gun_check: a %s has steps 0..%d this turn, got %d" % [u.type, n - 1, step_index])
	if u.down:
		return {"ok": false, "reason": Guns.WHY_UNIT_DOWN, "special": special_id, "step": step_index}
	var tgt := Guns.normal_target(target)
	if tgt.is_empty():
		return {"ok": false, "reason": Guns.WHY_NO_TARGET, "special": special_id, "step": step_index}
	var states := _run_plan(u)
	var prev: Dictionary = _start_state(u) if step_index == 0 else states[step_index - 1]
	return _gun_analysis(u, guns.special(special_id), tgt, step_index, prev, states[step_index])

# The fire a step's request carries, as the step state records it (plain values; the resolver reads special, target and fire_t):
# {special, target, aim?, fire_t, ok, reason, range_m, spotted, spread_m, flight_s, from: [x, y]}.
func _fire_state(u: Unit, k: int, prev: Dictionary, cur: Dictionary, req: Dictionary) -> Dictionary:
	var sid := Guns.fire_special(req)
	var tgt := Guns.fire_target(req)
	var out := {"special": sid, "target": tgt}
	var aim := Guns.fire_aim(req)
	if not aim.is_empty():
		out["aim"] = aim
	if not gun_specials(u.id).has(sid) or tgt.is_empty():
		out["ok"] = false
		out["reason"] = Guns.WHY_NOT_A_GUN if tgt.size() > 0 else Guns.WHY_NO_TARGET
		out["fire_t"] = rules.turn_seconds * float(k + 1) / float(u.def.actions_per_turn)
		return out
	var a := _gun_analysis(u, guns.special(sid), tgt, k, prev, cur)
	out["ok"] = a["ok"]
	out["reason"] = a["reason"]
	out["fire_t"] = a["fire_t"]
	out["range_m"] = a["range_m"]
	out["spotted"] = a["spotted"]
	out["spread_m"] = a["spread_m"]
	out["flight_s"] = a["flight_s"]
	out["from"] = [(a["from"] as Vector2).x, (a["from"] as Vector2).y]
	return out

# The whole answer for a salvo from step `step` (prev -> cur) at `tgt` (a normalised target) as the world stands.
func _gun_analysis(u: Unit, spec: GunRules.Spec, tgt: Dictionary, step: int, prev: Dictionary, cur: Dictionary) -> Dictionary:
	var n := u.def.actions_per_turn
	var dt := rules.step_dt(n)
	var fire_t := rules.turn_seconds * float(step) / float(n) + spec.fire_at * dt
	var pose := Envelope.point_on_step(prev, cur, dt, spec.fire_at)
	var from := Vector2(float(pose["x"]), float(pose["y"]))
	var why := ""
	var ready_turn := u.gun_ready_turn(spec.id)
	if ready_turn > turn:
		why = Guns.WHY_RELOADING
	for i in u.plan.size():
		if why == "" and i != step and (u.plan[i] as Dictionary).has("fire") and Guns.fire_special(u.plan[i]) == spec.id:
			why = Guns.WHY_ALREADY_PLANNED
	var tpos := Vector2.ZERO
	var target_problem := ""
	if tgt.has("unit"):
		var tid := str(tgt["unit"])
		if not units.has(tid):
			target_problem = Guns.WHY_NO_TARGET
		else:
			var tu: Unit = units[tid]
			tpos = Vector2(tu.x, tu.y)
			if tu.side == u.side:
				target_problem = Guns.WHY_OWN_SIDE
			elif tu.down:
				target_problem = Guns.WHY_TARGET_DOWN
	else:
		var tp: Array = tgt["point"]
		tpos = Vector2(float(tp[0]), float(tp[1]))
	if why == "" and target_problem != "":
		why = target_problem
	var range_m := from.distance_to(tpos)
	var range_why := Guns.reach_error(from, tpos, spec, water_depth)
	if why == "" and range_why != "":
		why = range_why
	var spotters: Array[String] = []
	if target_problem == "":
		spotters = spotting.spotters_now(self, u.side, tgt)
	var spotted := not spotters.is_empty()
	if why == "" and not spotted:
		why = Guns.WHY_UNSPOTTED
	var carry := 0.0
	if tgt.has("unit"):
		carry = float((spot_memory.get(u.side, {}) as Dictionary).get(str(tgt["unit"]), 0.0))
	var spotted_s := (carry + fire_t) if spotted else 0.0
	var salvos := Guns.bracket_salvos(gun_memory, u.side, tgt, turn, spec) if spotted else 0
	var spotter_ratio := spotting.closeness_in(self, u.side, tgt, spotting.frame_at(self, -1.0)) if spotted else 1.0
	var flight := Guns.flight_time(range_m, spec)
	var impact_t := fire_t + flight
	return {
		"ok": why == "", "reason": why, "special": spec.id, "step": step, "target": tgt, "target_pos": tpos, "from": from, "fire_t": fire_t,
		"range_m": range_m, "range_min_m": spec.range_min_m, "range_max_m": spec.range_max_m,
		"spotted": spotted, "by": spotters[0] if spotted else "", "spotters": spotters, "spotted_s": spotted_s, "salvos": salvos,
		"spotter_ratio": spotter_ratio,
		"spread_m": Guns.sigma_m(range_m, spotted_s, spec, salvos, spotter_ratio), "aim_factor": Guns.aim_factor(spotted_s, spec),
		"flight_s": flight, "impact_t": impact_t, "lands_in_turn": turn + int(floorf(impact_t / rules.turn_seconds + 1e-9)),
		"reload_left": maxi(0, ready_turn - turn), "ready_turn": ready_turn,
	}

# "" if the request's fire can be planned in this step of this unit, else what is wrong with it. The activation rules (reload, range,
# spotted) are NOT checked here (gun_check says; the interface refuses; a plan whose earlier step moved is not refused after the
# fact, as a drop is not): only that the request is well formed and the unit can fire it.
func _fire_request_problem(u: Unit, step_index: int, req: Dictionary) -> String:
	var e := Guns.request_error(req["fire"])
	if e != "":
		return e
	if req.has("drop"):
		return "a step has one special: this step already drops bombs"
	var sid := Guns.fire_special(req)
	if not guns.has_special(sid):
		return "'%s' is not a gun special (data/sim/guns.json)" % sid
	if u.def.special(sid).is_empty():
		return "a %s has no special '%s'" % [u.type, sid]
	var tgt := Guns.fire_target(req)
	if tgt.has("unit") and not units.has(str(tgt["unit"])):
		return "the fire's target unit '%s' does not exist" % str(tgt["unit"])
	for i in u.plan.size():
		if i != step_index and (u.plan[i] as Dictionary).has("fire") and Guns.fire_special(u.plan[i]) == sid:
			return "unit '%s' has %s planned on step %d already: one salvo a turn" % [u.id, sid, i]
	return ""

# The resolver's question during the combat walk: is the target spotted by `side` at t seconds into this turn, for how long without a
# break (the target's run from the start of the turn, plus what it had at the turn's start), how many salvos has the side
# already fired at it (the bracketing), and how close its nearest spotter is (the share of its sight). {spotted, run_s, salvos, spotter_ratio}.
func _spot_result(side: String, target: Dictionary, t: float, downs: Dictionary, special_id: String) -> Dictionary:
	var carry := 0.0
	if target.has("unit"):
		carry = float((spot_memory.get(side, {}) as Dictionary).get(str(target["unit"]), 0.0))
	var r := spotting.run_at(self, side, target, t, carry, guns.spot_step_s, downs)
	var spec := guns.special(special_id)
	r["salvos"] = Guns.bracket_salvos(gun_memory, side, target, turn, spec) if spec != null and bool(r["spotted"]) else 0
	r["spotter_ratio"] = spotting.closeness_in(self, side, target, spotting.frame_at(self, t), t, downs) if bool(r["spotted"]) else 1.0
	return r

# The bracketing memory after a resolve: the salvos fired this turn added (shell_fire events), then every entry kept only while it is
# still a target worth remembering: not renewed for bracket_turns -> gone; a unit that is down -> gone; a target not spotted at the
# end of the turn -> gone (the run is broken and the guns start again). `downs`: the units downed in the turn.
func _gun_memory_after(events: Array, downs: Dictionary) -> Array:
	var mem: Array = gun_memory.duplicate(true)
	for ev: Dictionary in events:
		if str(ev.get("type", "")) != "shell_fire" or not units.has(str(ev["unit"])):
			continue
		var spec := guns.special(str(ev["special"]))
		if spec == null:
			continue
		var aim: Array = ev["aim"]
		mem = Guns.bracket_after(mem, (units[str(ev["unit"])] as Unit).side, ev["target"] as Dictionary, Vector2(float(aim[0]), float(aim[1])), turn, spec)
	var longest := 0
	for sid: String in guns.specials:
		longest = maxi(longest, (guns.specials[sid] as GunRules.Spec).bracket_turns)
	var kept: Array = []
	for rec: Dictionary in mem:
		if turn - int(rec["turn"]) > longest:
			continue
		var side := str(rec["side"])
		var unit_id := str(rec["unit"])
		if unit_id != "":
			if not units.has(unit_id) or (units[unit_id] as Unit).down or downs.has(unit_id):
				continue
			if not (spot_memory.get(side, {}) as Dictionary).has(unit_id):
				continue
		else:
			var p: Array = rec["point"]
			if p.size() < 2 or not spotting.spotted_at(self, side, {"point": [float(p[0]), float(p[1])]}, rules.turn_seconds, downs):
				continue
		kept.append(rec)
	return kept

# What a joining client needs beyond the units: the shells in the air and what the sides remember (WorldSync's snapshot), and what
# resolve() adds to its result for a client that only applies it.
func net_guns() -> Dictionary:
	return {"shells": shells_in_flight.duplicate(true), "spot_memory": spot_memory.duplicate(true), "gun_memory": gun_memory.duplicate(true)}

func apply_net_guns(d: Dictionary) -> void:
	shells_in_flight = (d.get("shells", []) as Array).duplicate(true)
	spot_memory = (d.get("spot_memory", {}) as Dictionary).duplicate(true)
	gun_memory = (d.get("gun_memory", []) as Array).duplicate(true)

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
		func(band: String) -> float: return band_height(band), bombs_in_flight, shells_in_flight,
		func(side: String, target: Dictionary, t: float, downs: Dictionary, special_id: String) -> Dictionary: return _spot_result(side, target, t, downs, special_id),
		func(special_id: String, from: Vector2, to: Vector2) -> String: return Guns.reach_error(from, to, guns.special(special_id), water_depth))
	var down_at: Dictionary = fight["down_at"]
	var fates: Dictionary = fight["fates"]
	bombs_in_flight = fight["bombs"]
	# The guns (Track SH): the shells still in the air, the reload of the guns that fired, and what the sides remember of the
	# targets they have spotted and fired at -- judged from the turn's histories, before any unit is marked down (a unit that
	# went down this turn saw until down_at: spotting.gd).
	shells_in_flight = fight["shells"]
	for gid: String in (fight["fired"] as Dictionary):
		var gu: Unit = units[gid]
		for sid: Variant in (fight["fired"][gid] as Array):
			gu.gun_ready[str(sid)] = turn + (guns.special(str(sid)) as GunRules.Spec).reload_turns + 1
	if _has_gun_units():
		spot_memory = spotting.memory_after(self, spot_memory, rules.turn_seconds, guns.spot_step_s, down_at)
		gun_memory = _gun_memory_after(fight["events"], down_at)
	spotting.forget()
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
	var result := {"turn": turn, "histories": histories, "events": events, "units": _net_states(), "bombs": bombs_in_flight.duplicate(true)}
	result.merge(net_guns())
	return result

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
	apply_net_guns(result)
	spotting.forget()
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
	spotting.forget()
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
	if u.def.domain == "sea" and water_depth.is_valid():
		s = _keep_afloat(u, prev, s, rules.step_dt(n))
	elif _ground_rule_on(u.def):
		s = ground.keep(u.def, prev, s, rules.step_dt(n), ground.spans(units), water_depth)
	s["step"] = k
	s["t"] = rules.turn_seconds * float(k + 1) / float(n)
	s["planned"] = planned
	s["out_of_bounds"] = not in_bounds(float(s["x"]), float(s["y"]))
	if req is Dictionary and (req as Dictionary).has("drop"):
		s["drop"] = _drop_state(u, k, prev, s, req)
	if req is Dictionary and (req as Dictionary).has("fire"):
		s["fire"] = _fire_state(u, k, prev, s, req)
	return s

# --- The water rule (Track WS; the header's THE WATER) --------------------------------------------------------

# Is there water deep enough under a hull of `def` at (px, py) heading `heading`: at its centre and at both ends.
func _afloat_pose(def: UnitDef, px: float, py: float, heading: float) -> bool:
	if def.domain != "sea" or not water_depth.is_valid():
		return true
	var half := sea.hull_fraction * def.size_m
	var cx := JsMath.cos(heading) * half
	var cy := JsMath.sin(heading) * half
	var need := def.draught_m
	return float(water_depth.call(px, py)) >= need \
		and float(water_depth.call(px + cx, py + cy)) >= need \
		and float(water_depth.call(px - cx, py - cy)) >= need

# Is the arc of the step from `from` to `to` afloat all along (the start is the unit's own place and is not
# asked)? Sampled every sea.sample_m of arc, at least four times.
func _afloat_along(u: Unit, from: Dictionary, to: Dictionary, dt: float) -> bool:
	var length := absf(0.5 * (float(from["speed"]) + float(to["speed"]))) * dt
	var count := maxi(4, ceili(length / sea.sample_m))
	for i in range(1, count + 1):
		var p := Envelope.point_on_step(from, to, dt, float(i) / float(count))
		if not _afloat_pose(u.def, float(p["x"]), float(p["y"]), float(p["heading"])):
			return false
	return true

# The step `s` (clamped by the envelope) kept afloat: as it is if its arc is afloat; else slowed (the same turn
# at end speeds from the planned one down to the slowest the step's speed window allows, sea.slow_tries of them,
# the first that floats wins); else HELD where it is (speed 0). A changed step is clamped, with the limit "shore".
func _keep_afloat(u: Unit, prev: Dictionary, s: Dictionary, dt: float) -> Dictionary:
	if _afloat_along(u, prev, s, dt):
		return s
	var env := u.def.envelope
	var turn := float(s["turn"])
	# the slowest end speed the step's window allows: the one nearest zero (the window's floor going ahead, its top going astern)
	var w_lo := float(env.clamp_step(prev, {"turn": turn, "speed": -1.0e9}, dt)["speed"])
	var w_hi := float(env.clamp_step(prev, {"turn": turn, "speed": 1.0e9}, dt)["speed"])
	var v_planned := float(s["speed"])
	var v_slow := clampf(0.0, w_lo, w_hi)
	for j in range(1, sea.slow_tries + 1):
		var c := env.clamp_step(prev, {"turn": turn, "speed": lerpf(v_planned, v_slow, float(j) / float(sea.slow_tries))}, dt)
		if _afloat_along(u, prev, c, dt):
			return _shore_limited(c)
	return _shore_limited({
		"x": prev["x"], "y": prev["y"], "heading": prev["heading"], "speed": 0.0,
		"altitude_band": prev["altitude_band"], "turn": 0.0, "limits": [],
		"held": true,   # (Envelope.point_on_step: a held step goes nowhere, whatever speed the unit had; Track TK2)
	})

static func _shore_limited(c: Dictionary) -> Dictionary:
	var limits: Array = (c.get("limits", []) as Array).duplicate()
	if not limits.has(Envelope.LIMIT_SHORE):
		limits.append(Envelope.LIMIT_SHORE)
	c["limits"] = limits
	c["clamped"] = true
	return c

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
