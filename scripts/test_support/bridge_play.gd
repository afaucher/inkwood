extends RefCounted

# SCRIPTED PLAY FOR HOLD THE BRIDGE (Track BM, 2026-10-11; test support -- the gate does not run scripts/test_support).
# A World built from data/scenarios/bridge.json with its AI (the waves on the drive role) and its Mission attached the way the sandbox does it on
# a host or locally, and ways of playing the players' side without a human, so that a test and the shot script can show the mission can be won,
# lost and played to a result (the shape of scripts/test_support/suppress_play.gd):
#
#   "idle"    nobody plans anything: the two tanks hold their ground and (their gun being an ORDER now: builder ORD, 2026-10-14, Alex's tank-gun-orders)
#             do not fire, the cruiser lies at rest (the waves, unopposed, get across: the game is lost, sooner or later)
#   "defend"  the CRUISER's Main Guns fire whenever they are loaded at a SPOTTED enemy tank (plan_players), and each TANK orders its gun at the
#             nearest enemy the card would let it fire at (plan_tanks), as a player would. It is omniscient only in the way the interface is not:
#             it asks the World's own gun_check, so it can fire exactly
#             what a player could switch on (spotted, in reach, loaded), never the unspotted. It keeps to its target while that is up and
#             in reach (each salvo at the same spotted target is better aimed than the last: bracketing, ranging in), else takes the enemy
#             tank farthest down the road (nearest the bridge) that is at least SAFE_M from the bridge's middle: a salvo near the span
#             would be the cruiser's own shells on the bridge (a loss).
#
#   var game := BridgePlay.new(3)                  # World.rng_seed (-1: the scenario's own)
#   var result := game.play("defend", 30)          # {state, reason, turn, t, turns, log}
#   game.world, game.ai, game.mission              # the parts, for a test to look into
#   game.events, game.snaps                        # every event (with its "turn"), per-turn end states
#   BridgePlay.for_world(some_world).plan_players()    # just the planner, for a World someone else owns (the sandbox's, a net peer's)

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")

const CRUISER := "cruiser_1"
const BRIDGE := "bridge_1"
const TANKS: Array[String] = ["tank_1", "tank_2"]
const ENEMIES: Array[String] = ["tank_e1", "tank_e2", "tank_e3", "tank_e4"]
const SPECIAL := "main_guns"
const TANK_SPECIAL := "tank_gun"
# Where the defence puts its tanks (metres along the road from the bridge's middle toward the enemy; negative is the village's side): FORWARD, at and just beyond
# the bridge's far end. With the tanks' guns an order (builder ORD, 2026-10-14) and the waves starting outside the player's sight, the tanks on the village side
# (the scenario's start, 45 and 80 m short) are not the nearest target of a wave coming down the road: the bridge is, and it falls to their guns in about twelve
# turns while the tanks have hardly begun (0 wins in 20 dice seeds). Forward, the wave meets the tanks first, inside the cruiser's reach, and the bridge is spared.
const STATIONS := {"tank_1": -45.0, "tank_2": -80.0}
# Never fire at an enemy nearer the bridge's middle than this: a shell's blast reaches 20 m and its scatter at this range is tens of metres.
const SAFE_M := 110.0

var scenario: SandboxScenario = null
var world: World = null
var ai: RefCounted = null
var mission: Mission = null
var player := "local"
var errors: Array[String] = []
var lines: Array[String] = []
var events: Array = []                    # every event of every turn, in order (each with its "turn")
var snaps: Array[Dictionary] = []         # per resolved turn: {turn, units: {id: {x, y, health, down, fate}}, events}
var continue_after_result := false
var salvos := 0                           # how many salvos the defence has planned
# The defence also SAILS the cruiser toward the bridge at its cruise speed, every step of every turn: the shallows (the sea rule) hold it at
# the nearest water it can float in, which is the "far end" of the mission (the start is the station the search found, a little farther). Off:
# it lies where it starts. (The ship starts at rest facing the bridge: a ship has no turn rate at rest.)
var advance := true
var _target := ""

# `overrides`: scenario unit id -> {x, y, heading, ...} applied to the unit specs before the World is built.
func _init(rng_seed: int = -1, overrides: Dictionary = {}, scenario_id: String = "bridge") -> void:
	if scenario_id == "":
		return   # bare: for_world() fills in the World
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
	var g: RefCounted = (load("res://scripts/test_support/bridge_play.gd") as GDScript).new(-1, {}, "")
	g.world = w
	return g

func ok() -> bool:
	return errors.is_empty()

func bridge_pos() -> Vector2:
	var b: Unit = world.units[BRIDGE]
	return Vector2(b.x, b.y)

func pos_of(id: String) -> Vector2:
	var u: Unit = world.units[id]
	return Vector2(u.x, u.y)

# Plan one turn the way `mode` plays it, ready the player and resolve (the AI already planned and readied itself when the turn began).
func turn(mode: String) -> Dictionary:
	if world.phase == World.PHASE_RESOLVED:
		world.begin_turn()
	if mode == "defend":
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
		parts.append("%s (%.0f,%.0f) hp%d%s" % [id, u.x, u.y, u.health, " DOWN" if u.down else ""])
	return "  ".join(parts)

# --- The players' side -------------------------------------------------------------------------------------

# The target the cruiser's salvo this turn would be at, or "" (none that is spotted, in reach, safe, with the guns loaded).
func choose_target() -> String:
	var ship: Unit = world.units.get(CRUISER)
	if ship == null or ship.down or world.gun_reload_left(CRUISER, SPECIAL) > 0:
		return ""
	var bridge := bridge_pos()
	# keep to the target while it is up, safe and can be fired at (the next salvo at it is better aimed)
	if _target != "" and world.units.has(_target):
		var tu: Unit = world.units[_target]
		if not tu.down and pos_of(_target).distance_to(bridge) >= SAFE_M and bool(world.gun_check(CRUISER, 0, {"unit": _target}).get("ok", false)):
			return _target
	var best := ""
	var best_d := INF
	for id: String in ENEMIES:
		var u: Unit = world.units.get(id)
		if u == null or u.down:
			continue
		var d := pos_of(id).distance_to(bridge)
		if d < SAFE_M or d >= best_d:
			continue
		if bool(world.gun_check(CRUISER, 0, {"unit": id}).get("ok", false)):
			best = id
			best_d = d
	return best

# Plan this turn for the living player units: the cruiser fires at choose_target() (step 0: the shells are in the air for the rest of the
# turn and land in the next). The tanks hold the road and order their guns (plan_tanks).
func plan_players() -> void:
	plan_tanks()
	var ship: Unit = world.units.get(CRUISER)
	if ship == null or ship.down:
		return
	var id := choose_target()
	_target = id
	var cruise := ship.def.envelope.speed_cruise
	for k in world.steps_per_turn(CRUISER):
		var req: Dictionary = {"turn": 0.0, "speed": cruise} if advance else {}
		if k == 0 and id != "":
			req["fire"] = {"special": SPECIAL, "target": {"unit": id}}
		if req.is_empty():
			continue
		var st := world.plan_step(CRUISER, k, req)
		if k == 0 and id != "" and not st.is_empty():
			salvos += 1

# Each living player tank with its gun loaded orders it at the nearest enemy unit the World's own gun_check lets it fire at, in the first step
# that allows it (the tank holds its place: its steps are left as they are, a hold). The tank's gun is an order since 2026-10-14.
func plan_tanks() -> void:
	for tid: String in TANKS:
		var t: Unit = world.units.get(tid)
		if t == null or t.down or world.gun_reload_left(tid, TANK_SPECIAL) > 0:
			continue
		var foes: Array = []
		for eid: String in world.units:
			var e: Unit = world.units[eid]
			if e.side != t.side and not e.down:
				foes.append([pos_of(tid).distance_to(pos_of(eid)), eid])
		foes.sort_custom(func(a: Array, b: Array) -> bool:
			if float(a[0]) != float(b[0]):
				return float(a[0]) < float(b[0])
			return str(a[1]) < str(b[1]))
		# drive to the station, then hold it
		var bu: Unit = world.units[BRIDGE]
		var station := bridge_pos() + Vector2.from_angle(bu.heading) * float(STATIONS.get(tid, 0.0))
		var arrived := pos_of(tid).distance_to(station) < 8.0
		for k in world.steps_per_turn(tid):
			if arrived:
				world.plan_step(tid, k, {"hold": true})
			else:
				world.plan_step(tid, k, station)
		var done := false
		for foe: Array in foes:
			if done or float(foe[0]) > 450.0:
				break
			for k in world.steps_per_turn(tid):
				if bool(world.gun_check(tid, k, {"unit": str(foe[1])}, TANK_SPECIAL).get("ok", false)):
					var req: Dictionary = (t.plan[k] as Dictionary).duplicate(true) if k < t.plan.size() else {"hold": true}
					req["fire"] = {"special": TANK_SPECIAL, "target": {"unit": str(foe[1])}}
					world.plan_step(tid, k, req)
					done = true
					break
