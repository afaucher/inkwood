extends RefCounted

# SCRIPTED PLAY FOR SUPPRESS (Track M2L, test support -- the gate does not run scripts/test_support).
# A World built from data/scenarios/suppress.json with its AI (the escorts' patrols, the mobile guns' roam) and its Mission attached
# the way the sandbox does it on a host or locally, and ways of playing the players' side without a human, so that a test and the shot
# script can show the scenario can be won, lost and played to a result:
#
#   "idle"   nobody plans anything: every plane carries on (the game is lost at the turn limit, or sooner if the guns shoot the bomber down)
#   "bomb"   the BOMBER flies a bombing run on the military complex and the FIGHTERS escort it, chasing an escort fighter that comes near
#            (the Strike's scripted pilot, scripts/test_support/strike_play.gd: omniscient, the World's public API only). It does not bait
#            or hunt the guns: whether a human can is the playtest's business, this only shows the mission can be won.
#
#   var game := SuppressPlay.new(3)                 # World.rng_seed (-1: the scenario's own)
#   var result := game.play("bomb", 30)             # {state, reason, turn, t, turns, log}
#   game.world, game.ai, game.mission               # the parts, for a test to look into
#   game.events, game.snaps                         # every event (with its "turn"), per-turn end states
#   SuppressPlay.for_world(some_world).plan_players()   # just the planner, for a World someone else owns (the sandbox's, a net peer's)
#
# THE UNITS TRACK'S FILES (data/units/mobile_aa.json, military_complex.json): until both exist the World is built from stand-ins
# (scripts/test_support/suppress_worlds.gd); SuppressPlay.standin() says which.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const SuppressWorlds = preload("res://scripts/test_support/suppress_worlds.gd")
const StrikePlay = preload("res://scripts/test_support/strike_play.gd")

const COMPLEX := "military_complex_1"
const BOMBER := "bomber_1"
const ESCORTS: Array[String] = ["escort_1", "escort_2"]
const GUNS: Array[String] = ["mobile_aa_1", "mobile_aa_2", "mobile_aa_3"]

var scenario: SandboxScenario = null
var world: World = null
var ai: RefCounted = null
var mission: Mission = null
var planner: RefCounted = null            # a StrikePlay over this World (its bomber's run and the fighters' stations)
var player := "local"
var errors: Array[String] = []
var lines: Array[String] = []
var events: Array = []                    # every event of every turn, in order (each with its "turn")
var snaps: Array[Dictionary] = []         # per resolved turn: {turn, units: {id: {x, y, health, down, fate}}, events}
var continue_after_result := false
# "low": on the first turn it plans, every player unit asks for this band on its first step (the mobile AA of the real units track reach 384 m,
# the LOW band only: a plane at medium is never fired at, so a scripted run that is to meet the guns has to come down). "" (default): none.
var dive_band := ""
var _dived := false

# `overrides`: scenario unit id -> {x, y, heading, ...} applied to the unit specs before the World is built.
func _init(rng_seed: int = -1, overrides: Dictionary = {}, scenario_id: String = "suppress") -> void:
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
	world = SuppressWorlds.new_world()
	var ids := scenario.populate(world)
	if ids.has(""):
		errors.append("the scenario's units did not all load: %s" % world.last_error)
		return
	if rng_seed >= 0:
		world.rng_seed = rng_seed
	player = scenario.local_player
	planner = StrikePlay.for_world(world)
	planner.target_id = COMPLEX
	ai = scenario.make_ai(world)
	if not scenario.ai_attach(ai, world):
		errors.append("the AI did not attach: %s" % str(ai.get("errors")))
	mission = scenario.make_mission(world)
	if mission != null:
		if not mission.ok():
			errors.append("the mission is not valid: %s" % str(mission.errors))
		mission.attach()
	world.turn_resolved.connect(func(turn: int, _hist: Dictionary, evs: Array) -> void:
		var snap := {"turn": turn, "units": {}, "events": evs.duplicate(true)}
		for uid: String in world.units:
			var su: Unit = world.units[uid]
			snap["units"][uid] = {"x": su.x, "y": su.y, "health": su.health, "down": su.down, "fate": su.fate}
		snaps.append(snap)
		for ev: Variant in evs:
			var e: Dictionary = (ev as Dictionary).duplicate()
			e["turn"] = turn
			events.append(e))

# Only the planner, over a World someone else built (the shot script's sandbox, the net test's host).
static func for_world(w: World) -> RefCounted:
	var g: RefCounted = (load("res://scripts/test_support/suppress_play.gd") as GDScript).new(-1, {}, "")
	g.world = w
	g.planner = StrikePlay.for_world(w)
	g.planner.target_id = COMPLEX
	return g

static func standin() -> bool:
	return SuppressWorlds.standin_in_use()

func ok() -> bool:
	return errors.is_empty()

func player_ids() -> Array[String]:
	var out: Array[String] = []
	for id: String in world.units:
		if (world.units[id] as Unit).controller == World.CONTROLLER_PLAYER:
			out.append(id)
	return out

func complex_pos() -> Vector2:
	var t: Unit = world.units[COMPLEX]
	return Vector2(t.x, t.y)

# Plan one turn the way `mode` plays it, ready the player and resolve (the AI already planned and readied itself when the turn began).
func turn(mode: String) -> Dictionary:
	if world.phase == World.PHASE_RESOLVED:
		world.begin_turn()
	if mode == "bomb":
		plan_players()
	world.commit(player)
	var res := world.resolve()
	if res.is_empty():
		errors.append("turn %d did not resolve: %s" % [world.turn, world.last_error])
		return res
	if mission == null or mission.state == Mission.PLAYING or continue_after_result:
		world.begin_turn()
	return res

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
	st["turn"] = int(st["turn"])
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

# --- The players' side -------------------------------------------------------------------------------------

# Plan this turn for every living player unit: the bomber's run on the complex, the fighters' escort.
func plan_players() -> void:
	var b: Unit = world.units.get(BOMBER)
	var target: Unit = world.units.get(COMPLEX)
	var chased := nearest_escort(b)
	for id: String in player_ids():
		var u: Unit = world.units[id]
		if u.down:
			continue
		if u.type == "bomber":
			planner.plan_bomber(u, target)
		elif b != null and not b.down:
			planner.plan_fighter(u, b, chased)
	if dive_band != "" and not _dived:
		_dived = true
		for id: String in player_ids():
			var du: Unit = world.units[id]
			if du.down or not du.def.envelope.bands.has(dive_band) or du.altitude_band == dive_band:
				continue
			var req: Dictionary = {}
			if du.plan.size() > 0 and du.plan[0] is Dictionary:
				req = (du.plan[0] as Dictionary).duplicate(true)
			req["altitude_band"] = dive_band
			world.plan_step(id, 0, req)

# The living escort fighter nearest to `from` (null when both are down).
func nearest_escort(from: Unit) -> Unit:
	var best: Unit = null
	var best_d := INF
	for id: String in ESCORTS:
		var e: Unit = world.units.get(id)
		if e == null or e.down or from == null:
			continue
		var d := Vector2(e.x, e.y).distance_to(Vector2(from.x, from.y))
		if d < best_d:
			best_d = d
			best = e
	return best
