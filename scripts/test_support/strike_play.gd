extends RefCounted

# SCRIPTED PLAY FOR THE STRIKE (Track A2, test support -- the gate does not run scripts/test_support).
# A World built from data/scenarios/strike.json with its AI (the patrolling fighter) and its Mission
# attached the way the sandbox does it on a host or locally, and ways of playing the players' side
# without a human, so that a test and the shot script can show the scenario can be won, lost and
# played to a result:
#
#   "idle"      nobody plans anything: every plane carries on (the bomber flies over the village without a
#               drop and out of the map; the game ends at the turn limit).
#   "bomb"      the BOMBER flies a bombing run on the tower and the FIGHTERS escort it. The run, from the
#               World's true state (the script is omniscient; the players are not):
#                 run         aim at the tower; every step of the plan whose RELEASE ERROR for the tower is
#                             small (World.drop_spread: r <= release_r_max, the aim not clamped) gets a drop,
#                             as long as the bomber has drops left, at most `drops_per_pass` a turn
#                 egress      past the tower (or too close to turn on it), straight on until `egress_m` away
#                 turn        aim at the tower again from there (the turn round, which is the bomber's own
#                             turn radius, 487 m); it runs again once it is lined up on the tower
#               (reposition = turn: aim at the tower again, no drops, until the bomber is lined up on it)
#               The fighters hold a station beside the bomber and, when the patrol fighter is near the bomber or
#               near them, chase it (lead pursuit, matching its band: the same steering as intercept_play.gd).
#   "bomb_alone"  as "bomb" but the fighters carry on (the bomber's run without an escort).
#
#   var game := StrikePlay.new("strike", 3)           # scenario id, World.rng_seed (-1: the scenario's own)
#   var result := game.play("bomb", 30)               # {state, reason, turn, t, turns, log}
#   game.world, game.ai, game.mission                 # the parts, for a test to look into
#   game.events, game.snaps                           # every event (with its "turn"), per-turn end states
#   StrikePlay.for_world(some_world).plan_players()   # just the planner, for a World someone else owns
#
# Only the World's public API plans (AiSteer does, as for the AI), so a run is something a player's hands
# could have done.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const AiSteer = preload("res://scripts/sim/ai_steer.gd")
const AiCone = preload("res://scripts/sim/ai_cone.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")
const JsMath = preload("res://scripts/core/js_math.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")

const TOWER := "radio_tower_1"
const BOMBER := "bomber_1"
const PATROL := "patrol_1"

# The run's numbers (this script's, not the game's): all proposed, test support only.
var release_r_max := 0.5         # a step is dropped on when its release error is at most this fraction of the cone
var drops_per_pass := 2          # at most this many drops a turn
var egress_m := 800.0            # straight on past the tower until this far from it, then turn round
var aligned_deg := 18.0          # the turn is over when the tower is this close to dead ahead
var pass_end_m := 250.0          # nearer than this to the tower the run is over: it cannot be turned on at this range
var guard_m := 1300.0            # the escort chases the patrol when it is within this of the bomber ...
var self_guard_m := 900.0        # ... or this of the fighter itself
var station_m := 220.0           # a fighter's station beside the bomber

var scenario: SandboxScenario = null
var world: World = null
var ai: RefCounted = null
var mission: Mission = null
var steer: AiSteer = null
var player := "local"
var params: AiParams = null
var errors: Array[String] = []
var lines: Array[String] = []
var events: Array = []              # every event of every turn, in order (each with its "turn")
var paths: Dictionary = {}          # unit id -> Array[Vector2]: every step-end position of every resolved turn
var snaps: Array[Dictionary] = []   # per resolved turn: {turn, units: {id: {x, y, health, down, fate, band}}, events}
var continue_after_result := false  # keep beginning turns after the mission is decided (to watch the bombs fall)
var drops_made := 0
var phase := "run"                  # the bomber's: run | egress | turn

# `overrides`: scenario unit id -> {x, y, heading, ...} applied to the unit specs before the World is built.
func _init(scenario_id: String = "strike", rng_seed: int = -1, overrides: Dictionary = {}) -> void:
	if scenario_id == "":
		return   # bare: for_world() fills in the planner
	scenario = SandboxScenario.new(scenario_id)
	errors.append_array(scenario.errors)
	if not scenario.ok():
		return
	for spec: Dictionary in scenario.units:
		var uid := str(spec.get("id", ""))
		if overrides.has(uid):
			for k: Variant in (overrides[uid] as Dictionary):
				spec[k] = (overrides[uid] as Dictionary)[k]
	world = World.new()
	world.quiet = true
	var ids := scenario.populate(world)
	if ids.has(""):
		errors.append("the scenario's units did not all load: %s" % world.last_error)
		return
	if rng_seed >= 0:
		world.rng_seed = rng_seed
	player = scenario.local_player
	params = AiParams.new(AiParams.DATA_PATH, true)
	steer = AiSteer.new(world, params.num("common", "edge_margin_turn_radii"))
	ai = scenario.make_ai(world)
	if not scenario.ai_attach(ai, world):
		errors.append("the AI did not attach: %s" % str(ai.get("errors")))
	mission = scenario.make_mission(world)
	if mission != null:
		if not mission.ok():
			errors.append("the mission is not valid: %s" % str(mission.errors))
		mission.attach()
	world.turn_resolved.connect(func(turn: int, hist: Dictionary, evs: Array) -> void:
		var snap := {"turn": turn, "units": {}, "events": evs.duplicate(true)}
		for uid: String in world.units:
			var su: Unit = world.units[uid]
			snap["units"][uid] = {"x": su.x, "y": su.y, "health": su.health, "down": su.down, "fate": su.fate, "band": su.altitude_band}
		snaps.append(snap)
		for ev: Variant in evs:
			var e: Dictionary = (ev as Dictionary).duplicate()
			e["turn"] = turn
			events.append(e)
			if str(e.get("type", "")) == "bomb_release":
				drops_made += 1
		for uid: Variant in hist:
			if not paths.has(uid):
				paths[uid] = []
			for st: Variant in (hist[uid] as Array):
				(paths[uid] as Array).append(Vector2(float((st as Dictionary)["x"]), float((st as Dictionary)["y"]))))

# Only the planner, over a World someone else built (the shot script's sandbox, the net test's host).
static func for_world(w: World) -> RefCounted:
	var g: RefCounted = (load("res://scripts/test_support/strike_play.gd") as GDScript).new("")
	g.world = w
	g.params = AiParams.new(AiParams.DATA_PATH, true)
	g.steer = AiSteer.new(w, g.params.num("common", "edge_margin_turn_radii"))
	return g

func ok() -> bool:
	return errors.is_empty()

func player_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in world.units:
		if (world.units[id] as Unit).controller == World.CONTROLLER_PLAYER:
			out.append(id)
	return out

func tower_pos() -> Vector2:
	var t: Unit = world.units[TOWER]
	return Vector2(t.x, t.y)

# The nearest any of the unit's step-end positions came to `p` (metres), INF if it never flew.
func nearest_pass(unit_id: String, p: Vector2) -> float:
	var best := INF
	for q: Vector2 in paths.get(unit_id, []):
		best = minf(best, q.distance_to(p))
	return best

# Plan one turn the way `mode` plays it, ready the player and resolve (the AI already planned and readied
# itself when the turn began). Returns the resolve's result.
func turn(mode: String) -> Dictionary:
	if world.phase == World.PHASE_RESOLVED:
		world.begin_turn()   # (a game that went on after its result: the last turn was left resolved)
	if mode == "bomb" or mode == "bomb_alone":
		plan_players(mode == "bomb")
	world.commit(player)
	var res := world.resolve()
	if res.is_empty():
		errors.append("turn %d did not resolve: %s" % [world.turn, world.last_error])
		return res
	if mission == null or mission.state == Mission.PLAYING or continue_after_result:
		world.begin_turn()
	return res

# Play up to `max_turns` turns, or until the mission leaves "playing". Returns {state, reason, turn, t, turns, log}.
func play(mode: String, max_turns: int = 30) -> Dictionary:
	var n := 0
	while n < max_turns and (continue_after_result or mission == null or mission.state == Mission.PLAYING) and errors.is_empty():
		var t0 := world.turn
		var res := turn(mode)
		if res.is_empty():
			break
		n += 1
		lines.append("turn %d: %s" % [t0, _summary()])
	var st: Dictionary = mission.status() if mission != null else {"state": Mission.PLAYING, "reason": "", "turn": world.turn, "t": NAN}
	st["turns"] = n
	st["log"] = lines
	return st

func _summary() -> String:
	var parts: Array[String] = []
	for id: String in world.units:
		var u: Unit = world.units[id]
		if u.def.is_static() and not u.down:
			continue
		parts.append("%s (%.0f,%.0f) %s hp%d%s" % [id, u.x, u.y, u.altitude_band.left(1), u.health, " DOWN" if u.down else ""])
	return "  ".join(parts)

# --- The players' side --------------------------------------------------------------------------------

# Plan this turn for every living player unit: the bomber's run, and the fighters' escort (or, with
# `escort` false, nothing: they carry on).
func plan_players(escort: bool = true) -> void:
	var b: Unit = world.units.get(BOMBER)
	var tower: Unit = world.units.get(TOWER)
	var patrol: Unit = world.units.get(PATROL)
	for id: String in player_ids():
		var u: Unit = world.units[id]
		if u.down:
			continue
		if u.type == "bomber":
			plan_bomber(u, tower)
		elif escort and b != null and not b.down:
			plan_fighter(u, b, patrol)

func plan_bomber(b: Unit, tower: Unit) -> void:
	if tower == null or tower.down:
		steer.fly_safe(b.id, func(_i: int, _at: Dictionary, _t: float) -> Dictionary: return {"turn": 0.0})
		return
	var tp := Vector2(tower.x, tower.y)
	var pos := Vector2(b.x, b.y)
	var d := pos.distance_to(tp)
	var fwd := Vector2.from_angle(b.heading)
	var ahead := fwd.dot(tp - pos) > 0.0
	var off_deg := absf(rad_to_deg(fwd.angle_to(tp - pos)))
	# The phase, from where the bomber is now.
	match phase:
		"run":
			if d < pass_end_m or (not ahead and d < egress_m):
				phase = "egress"
		"egress":
			if d >= egress_m:
				phase = "turn"
		"turn":
			if off_deg <= aligned_deg:
				phase = "run"
	var cruise: float = b.def.envelope.speed_cruise
	var ctrl: Callable
	if phase == "egress":
		ctrl = func(_i: int, _at: Dictionary, _t: float) -> Dictionary: return {"turn": 0.0, "speed": cruise}
	else:
		ctrl = func(_i: int, _at: Dictionary, _t: float) -> Dictionary:
			return {"aim": func(s: Dictionary) -> float: return JsMath.atan2(tp.y - float(s["y"]), tp.x - float(s["x"])), "speed": cruise}
	steer.fly_safe(b.id, ctrl)
	if phase == "run":
		_plan_drops(b, tp)

# A drop on every step of the plan that the tower is in the cone of (release error small enough), up to the
# drops the bomber has left and `drops_per_pass` a turn.
func _plan_drops(b: Unit, tp: Vector2) -> void:
	var planned := 0
	for k in world.steps_per_turn(b.id):
		if planned >= drops_per_pass or planned >= b.drops_left:
			break
		var info := world.drop_spread(b.id, k, tp)
		if info.is_empty() or bool(info["clamped"]) or float(info["r"]) > release_r_max:
			continue
		if k >= b.plan.size():
			continue
		var req: Dictionary = (b.plan[k] as Dictionary).duplicate(true)
		req["drop"] = {"aim": [tp.x, tp.y]}
		if not world.plan_step(b.id, k, req).is_empty():
			planned += 1

# A fighter: chase the patrol fighter when it is near the bomber or near this fighter, else hold a station
# beside the bomber (left for the light fighter, right for the heavy), from the World's true state.
func plan_fighter(u: Unit, b: Unit, patrol: Unit) -> void:
	var chase := false
	if patrol != null and not patrol.down:
		var pp := Vector2(patrol.x, patrol.y)
		chase = pp.distance_to(Vector2(b.x, b.y)) < guard_m or pp.distance_to(Vector2(u.x, u.y)) < self_guard_m
	if chase:
		steer.fly_safe(u.id, _chase_ctrl(u, patrol))
	else:
		steer.fly_safe(u.id, _station_ctrl(u, b))

func _station_ctrl(u: Unit, b: Unit) -> Callable:
	var dt := world.step_dt(u.id)
	var h := b.heading
	var fwd := Vector2.from_angle(h)
	var right := Vector2(-fwd.y, fwd.x)
	var side := -1.0 if u.type == "light_fighter" else 1.0
	var ahead_m := 200.0 if u.type == "light_fighter" else 100.0
	var catchup := params.num("escort", "catchup_time_s")
	var bp := Vector2(b.x, b.y)
	var speed := b.speed
	var band := b.altitude_band
	var can_match: bool = (u.def.envelope.bands as Array).has(band)
	return func(_i: int, at: Dictionary, t_end: float) -> Dictionary:
		var station := bp + fwd * (speed * t_end + ahead_m) + right * (side * station_m)
		var gap := Vector2(float(at["x"]), float(at["y"])).distance_to(station)
		var ahead_of := Vector2(float(at["x"]) - station.x, float(at["y"]) - station.y).dot(fwd)
		var out := {
			"aim": func(s: Dictionary) -> float:
				var st := bp + fwd * (speed * t_end + ahead_m) + right * (side * station_m)
				return JsMath.atan2(st.y - float(s["y"]), st.x - float(s["x"])),
			"speed": speed + (gap if ahead_of < 0.0 else -gap) / catchup,
		}
		if can_match:
			out["band"] = band
		return out

# The intercept scenario's lead pursuit (scripts/test_support/intercept_play.gd), on the patrol fighter.
func _chase_ctrl(u: Unit, tgt: Unit) -> Callable:
	var cone := AiCone.forward_cone(u.def, u.type, params)
	var desired := params.num("escort", "engage_range_fraction") * float(cone.get("range_m", 450.0))
	var catchup := params.num("escort", "catchup_time_s")
	var dt := world.step_dt(u.id)
	var vx := JsMath.cos(tgt.heading) * tgt.speed
	var vy := JsMath.sin(tgt.heading) * tgt.speed
	var bx := tgt.x
	var by := tgt.y
	var band := tgt.altitude_band
	var can_match: bool = (u.def.envelope.bands as Array).has(band)
	var tspeed := tgt.speed
	return func(_i: int, at: Dictionary, t_end: float) -> Dictionary:
		var gap := sqrt(pow(float(at["x"]) - (bx + vx * (t_end - dt)), 2.0) + pow(float(at["y"]) - (by + vy * (t_end - dt)), 2.0))
		var ax := bx + vx * t_end
		var ay := by + vy * t_end
		var out := {
			"aim": func(s: Dictionary) -> float: return JsMath.atan2(ay - float(s["y"]), ax - float(s["x"])),
			"speed": tspeed + (gap - desired) / catchup,
		}
		if can_match:
			out["band"] = band
		return out
