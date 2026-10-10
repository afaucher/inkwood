extends "res://scripts/test_support/test_case.gd"

# THE WIRE FORMAT, WITHOUT A SOCKET (Track N): what WorldSync sends is plain
# Variants, and the engine's own encoder (the one RPCs use: var_to_bytes) must
# hand them back bit for bit. Two Worlds built from the sandbox scenario, no
# network, no ports:
#
#   1. NAMES         a player is "peer_<id>"; the AI keeps its own name
#   2. EQUALITY      WorldSync.same: an int is not a float, NaN is NaN, content not identity
#   3. THE RESULT    a resolve() result survives the encoder exactly (floats, NaN, ints,
#                    Vector2) and a second World that applies it ends identical
#   4. THE SNAPSHOT  what a joining peer gets: turn, every unit's state and history, the
#                    players' plans, the players and the Ready flags -- survives the
#                    encoder and rebuilds the same game; the AI unit's plan is NOT in it
#   5. THE GUARDS    a snapshot for other units is refused, not applied

const World = preload("res://scripts/sim/world.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")

const FIGHTER := "light_fighter_1"
const HEAVY := "heavy_fighter_1"
const BOMBER := "bomber_1"

func setup(_main) -> void:
	# A script that does not compile still loads (CLAUDE.md) and a runtime error ends a function
	# silently, so each part says it reached its last line.
	for part: Script in [WorldSync, World, SandboxScenario, AiDumb]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	eq(_names(), true, "1. the names part ran to its end")
	eq(_equality(), true, "2. the equality part ran to its end")
	eq(_result_and_snapshot(), true, "3-5. the snapshot, result and guard parts ran to their end")
	finish()

func _names() -> bool:
	eq(WorldSync.player_for(1), "peer_1", "1. the host is peer_1")
	eq(WorldSync.player_for(2087359998), "peer_2087359998", "1. a Steam-sized id is a name")
	eq(WorldSync.peer_of("peer_42"), 42, "1. and back")
	eq(WorldSync.peer_of(World.AI_PLAYER), 0, "1. the AI is no peer")
	eq(WorldSync.peer_of("local"), 0, "1. neither is anything else")
	return true

func _equality() -> bool:
	check(WorldSync.same(1, 1), "2. equal ints")
	check(not WorldSync.same(1, 1.0), "2. an int is not a float (the wire keeps ints ints)")
	check(WorldSync.same(NAN, NAN), "2. NaN is NaN (a unit's down_at)")
	check(not WorldSync.same(NAN, 0.0), "2. but not zero")
	check(WorldSync.same({"a": [1, 2.5, {"b": "c"}]}, {"a": [1, 2.5, {"b": "c"}]}), "2. nested content")
	check(not WorldSync.same({"a": [1, 2.5]}, {"a": [1, 2.6]}), "2. a different float")
	check(not WorldSync.same([1, 2], [1, 2, 3]), "2. a different length")
	check(not WorldSync.same({"a": 1}, {"b": 1}), "2. a different key")
	check(WorldSync.same(Vector2(1.5, 2.5), Vector2(1.5, 2.5)), "2. a Vector2")
	return true

func _make(player_name: String, with_ai: bool) -> World:
	var w := World.new()
	var sc := SandboxScenario.new("sandbox")
	sc.populate(w)
	w.remove_player(sc.local_player)
	w.add_player(player_name)
	if with_ai:
		AiDumb.new(w).attach()
	return w

# The wire: encode as an RPC would, decode on the other side.
func _wire(v: Variant) -> Variant:
	return bytes_to_var(var_to_bytes(v))

func _result_and_snapshot() -> bool:
	var host_world := _make("peer_1", true)
	host_world.add_player("peer_7")
	# A WorldSync only to read snapshot()/apply_snapshot() (offline, it counts as a host).
	var hs := WorldSync.new()
	add_child(hs)
	hs.setup(host_world, "sandbox")
	# Plans: non-32-bit floats, ints, a Vector2 target and a gap.
	host_world.plan_step(FIGHTER, 0, {"turn": 0.1234567890123, "speed": 117.12345678901})
	host_world.plan_step(FIGHTER, 2, {"to": Vector2(3300.0, 2400.0)})
	host_world.plan_step(HEAVY, 1, {"turn": -0.2, "speed": 130.0, "altitude_band": "high"})
	host_world.commit("peer_7")

	# 4. The snapshot, mid-turn: encoded, decoded, applied to a fresh World.
	var snap: Dictionary = hs.snapshot()
	eq((snap["units"][BOMBER]["plan"] as Array).size(), 0, "4. the snapshot has no plan for the AI unit")
	check((host_world.units[BOMBER].plan as Array).size() > 0, "4. though the AI has planned on the host")
	check(WorldSync.same(snap, _wire(snap)), "4. the snapshot survives the encoder exactly")
	var joiner_world := _make("peer_9", false)
	var js := WorldSync.new()
	add_child(js)
	js.setup(joiner_world, "sandbox")
	js.apply_snapshot(_wire(snap) as Dictionary)
	eq(_diff(host_world, joiner_world), "", "4. a joiner that applies the snapshot holds the host's game")
	check(joiner_world.is_ready("peer_7") and joiner_world.is_ready(World.AI_PLAYER) and not joiner_world.is_ready("peer_1"), "4. with the same Ready flags")
	eq((joiner_world.units[BOMBER].plan as Array).size(), 0, "4. its AI unit has no plan")

	# 3. The result of a turn: everyone ready, resolve, encode, apply on the second World.
	host_world.commit("peer_1")
	check(host_world.all_ready(), "3. everyone is ready on the host")
	var result: Dictionary = host_world.resolve()
	check(not result.is_empty(), "3. the host resolved")
	var wired: Dictionary = _wire(result)
	check(WorldSync.same(result, wired), "3. the resolve() result survives the encoder exactly")
	check(is_nan(float(wired["units"][FIGHTER]["down_at"])), "3. including a NaN down_at")
	check(joiner_world.apply_resolution(wired), "3. a second World applies it")
	eq(_diff(host_world, joiner_world), "", "3. and holds identical states and histories")
	eq(joiner_world.phase, World.PHASE_RESOLVED, "3. in the resolved phase")

	# A down unit takes no orders: the host refuses a plan for it.
	var was_down: bool = host_world.units[HEAVY].down
	host_world.units[HEAVY].down = true
	eq(hs._plan_problem(HEAVY, [{"to": Vector2(1.0, 1.0)}]), "the unit is down", "5. a plan for a down unit is refused")
	host_world.units[HEAVY].down = was_down
	eq(hs._plan_problem(HEAVY, [{"to": Vector2(1.0, 1.0)}]), "", "5. and a plan for a unit that is up is not")
	eq(hs._plan_problem(BOMBER, []), "not a player unit", "5. a plan for the AI unit is refused")
	eq(hs._plan_problem(FIGHTER, [{"to": Vector2(1.0, 1.0)}, {}, {}, {}, {}, {}]), "6 steps, a light_fighter has 5", "5. a plan with too many steps is refused")
	check(hs._plan_problem(FIGHTER, [{"speed": NAN}]).begins_with("'speed'"), "5. a plan that is not finite is refused")

	# 5. The guards: a snapshot of other units is refused and changes nothing.
	var refused := [0]
	js.refused.connect(func(_why: String) -> void: refused[0] += 1)
	var bad: Dictionary = _wire(snap)
	(bad["units"] as Dictionary).erase(HEAVY)
	var turn_before := joiner_world.turn
	js.apply_snapshot(bad)
	eq(refused[0], 1, "5. a snapshot for other units is refused")
	eq(joiner_world.turn, turn_before, "5. and applied to nothing")
	return true

# "" if the two Worlds hold the same game, else the first difference.
func _diff(a: World, b: World) -> String:
	if a.turn != b.turn:
		return "turn"
	var pa: Array = a.players.duplicate()
	var pb: Array = b.players.duplicate()
	pa.sort()
	pb.sort()
	if pa != pb:
		return "players %s %s" % [str(pa), str(pb)]
	for id: String in a.units:
		var ua = a.units[id]
		var ub = b.units[id]
		if not WorldSync.same(ua.net_state(), ub.net_state()):
			return "%s state" % id
		if not WorldSync.same(ua.history, ub.history):
			return "%s history" % id
		if ua.controller == World.CONTROLLER_PLAYER and not WorldSync.same(ua.plan, ub.plan):
			return "%s plan" % id
	return ""
