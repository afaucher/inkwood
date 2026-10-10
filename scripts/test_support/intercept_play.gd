extends RefCounted

# SCRIPTED PLAY FOR THE INTERCEPT SCENARIO (Track A, test support -- the gate does
# not run scripts/test_support). A World built from a scenario file with its AI and
# Mission attached the way the sandbox does it on a host or locally, and two ways of
# playing the players' side without a human:
#
#   "idle"   nobody plans anything: every plane carries on (the bomber flies its route and
#            wins when it reaches the target, as a game left alone must end).
#   "chase"  a lead pursuit of the bomber for every living player plane, from the World's
#            true state (the test is omniscient; the players are not): aim at where the
#            bomber will be at the end of each step if it flies straight, hold the range
#            behind it that the plane's forward weapon likes, match its altitude band.
#            This is the scripted "play" that shows the scenario can be won.
#
#   var game := InterceptPlay.new("intercept", 3)       # scenario id, World.rng_seed (-1: the scenario's own)
#   var result := game.play("chase", 20)                # {state, reason, turn, t, turns, log}
#   game.world, game.ai, game.mission                   # the parts, for a test to look into
#   game.snaps                                          # per resolved turn: units' end states, paths, events
#   InterceptPlay.for_world(some_world).plan_chase()    # just the chase planner, for a World someone else owns
#
# Only the World's public API plans (AiSteer does, as for the AI), so a chase is something
# a player's hands could have done.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const AiSteer = preload("res://scripts/sim/ai_steer.gd")
const AiCone = preload("res://scripts/sim/ai_cone.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")
const JsMath = preload("res://scripts/core/js_math.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")

var scenario: SandboxScenario = null
var world: World = null
var ai: RefCounted = null
var mission: Mission = null
var steer: AiSteer = null
var player := "local"
var bomber_id := "bomber_1"
var params: AiParams = null
var errors: Array[String] = []
var lines: Array[String] = []
var events: Array = []              # every event of every turn, in order (each with its "turn")
var paths: Dictionary = {}          # unit id -> Array[Vector2]: every step-end position of every resolved turn
var snaps: Array[Dictionary] = []   # per resolved turn: {turn, units: {id: {x, y, health, down, fate, band}}, paths: {id: Array[Vector2]}, events}
var continue_after_result := false  # keep beginning turns after the mission is decided (to watch a wreck fall)

# `overrides`: scenario unit id -> {x, y, heading, ...} applied to the unit specs before the World is built
# (the tuning script tries start positions this way).
func _init(scenario_id: String = "intercept", rng_seed: int = -1, overrides: Dictionary = {}) -> void:
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
		var snap := {"turn": turn, "units": {}, "paths": {}, "events": evs.duplicate(true)}
		for uid: String in world.units:
			var su: Unit = world.units[uid]
			snap["units"][uid] = {"x": su.x, "y": su.y, "health": su.health, "down": su.down, "fate": su.fate, "band": su.altitude_band}
			var pl: Array = []
			for st: Variant in (hist[uid] as Array):
				pl.append(Vector2(float((st as Dictionary)["x"]), float((st as Dictionary)["y"])))
			snap["paths"][uid] = pl
		snaps.append(snap)
		for ev: Variant in evs:
			var e: Dictionary = (ev as Dictionary).duplicate()
			e["turn"] = turn
			events.append(e)
		for uid: Variant in hist:
			if not paths.has(uid):
				paths[uid] = []
			for st: Variant in (hist[uid] as Array):
				(paths[uid] as Array).append(Vector2(float((st as Dictionary)["x"]), float((st as Dictionary)["y"]))))

# Only the chase planner, over a World someone else built (the shot script's sandbox).
static func for_world(w: World) -> RefCounted:
	var g: RefCounted = (load("res://scripts/test_support/intercept_play.gd") as GDScript).new("")
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

# The nearest any of the unit's step-end positions came to `p` (metres), INF if it never flew.
func nearest_pass(unit_id: String, p: Vector2) -> float:
	var best := INF
	for q: Vector2 in paths.get(unit_id, []):
		best = minf(best, q.distance_to(p))
	return best

# Plan one turn the way `mode` plays it, ready the player and resolve (the AI already
# planned and readied itself when the turn began). Returns the resolve's result.
func turn(mode: String) -> Dictionary:
	if world.phase == World.PHASE_RESOLVED:
		world.begin_turn()   # (a game that went on after its result: the last turn was left resolved)
	if mode == "chase":
		plan_chase()
	world.commit(player)
	var res := world.resolve()
	if res.is_empty():
		errors.append("turn %d did not resolve: %s" % [world.turn, world.last_error])
		return res
	if mission == null or mission.state == Mission.PLAYING or continue_after_result:
		world.begin_turn()
	return res

# Play up to `max_turns` turns, or until the mission leaves "playing". Returns
# {state, reason, turn, t, turns (resolved), log}.
func play(mode: String, max_turns: int = 20) -> Dictionary:
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
		parts.append("%s (%.0f,%.0f) %s hp%d%s" % [id, u.x, u.y, u.altitude_band.left(1), u.health, " DOWN" if u.down else ""])
	return "  ".join(parts)

# --- The scripted chase ---------------------------------------------------------------------

# Every living player plane: lead pursuit of the bomber (if it is still up) from the World's
# true state; a plane with nothing to chase flies on.
func plan_chase() -> void:
	var b: Unit = world.units.get(bomber_id)
	for id: String in player_ids():
		var u: Unit = world.units[id]
		if u.down:
			continue
		if b == null or b.down:
			world.clear_plan(id)
			continue
		var ctrl := _chase_ctrl(u, b)
		steer.fly_safe(id, ctrl)

func _chase_ctrl(u: Unit, b: Unit) -> Callable:
	var cone := AiCone.forward_cone(u.def, u.type, params)
	var desired := params.num("escort", "engage_range_fraction") * float(cone["range_m"])
	var catchup := params.num("escort", "catchup_time_s")
	var dt := world.step_dt(u.id)
	var h := b.heading
	var vx := JsMath.cos(h) * b.speed
	var vy := JsMath.sin(h) * b.speed
	var bx := b.x
	var by := b.y
	var band := b.altitude_band
	var bands: Array[String] = u.def.envelope.bands
	var can_match := bands.has(band)
	return func(_i: int, at: Dictionary, t_end: float) -> Dictionary:
		var gap := sqrt(pow(float(at["x"]) - (bx + vx * (t_end - dt)), 2.0) + pow(float(at["y"]) - (by + vy * (t_end - dt)), 2.0))
		var ax := bx + vx * t_end
		var ay := by + vy * t_end
		var out := {
			"aim": func(s: Dictionary) -> float: return JsMath.atan2(ay - float(s["y"]), ax - float(s["x"])),
			"speed": b.speed + (gap - desired) / catchup,
		}
		if can_match:
			out["band"] = band
		return out
