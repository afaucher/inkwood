extends "res://scripts/test_support/test_case.gd"

# THE SPECIAL'S TARGET OVER THE WIRE (Track T, 2026-10-10). Alex, decision special-targeting: "The special is active and
# targeted for the step" -- the target is stored ON THE STEP when the special is activated there, so it is part of the step's
# request and crosses with the plan: to the host, to the other players (the co-op preview shows another player's drop with its
# target), to a player who joins later, and back in the host's resolved histories. A host and clients in ONE process over real
# ENet sockets (scripts/net/net_rig.gd), each with its own World built from the sandbox scenario; the scenario's bomber is the
# AI's, so here it is flipped to a player's on every World (the strike's bomber is a player's).
#
#   1. A PLAN WITH TARGETS   Ann plans two drops, one on a unit and one on a point; the host and Bob hold exactly her plan
#   2. LAST EDIT WINS        Bob retargets step 1 to a point; everyone holds his plan
#   3. THE HOST'S GUARD      a malformed target is refused, a good one is not (and the counters say so)
#   4. A LATE JOINER         Cat joins from the snapshot and holds the plan, targets and all
#   5. THE RESOLVE           the host resolves; every World holds the same histories, the target in the drop of the step
#
# Port 28784 (CLAUDE.md: one port per networked test).

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")

const PORT := 28784
const BOMBER := "bomber_1"
const FIGHTER := "light_fighter_1"
const HEAVY := "heavy_fighter_1"

var rig: NetRig = null
var host: NetRig.Peer = null
var ann: NetRig.Peer = null
var bob: NetRig.Peer = null

func setup(_main) -> void:
	timeout_seconds = 120.0
	for part: Script in [NetRig, WorldSync, World]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	rig = NetRig.new()
	add_child(rig)
	var completed: Variant = await _run()
	check(completed == true, "the test ran to its last line (a runtime error would have ended it silently)")
	rig.close_all()
	finish()

func _wait(cond: Callable, what: String) -> bool:
	var ok: bool = await rig.wait_until(cond)
	check(ok, "timed out waiting for: " + what)
	return ok

func _everywhere(plan: Array, peers: Array) -> bool:
	for p: NetRig.Peer in peers:
		if not WorldSync.same(p.world.units[BOMBER].plan, plan):
			return false
	return true

func _run() -> bool:
	host = rig.add_host(PORT, "Hal")
	if not check(host != null, "the host binds port %d" % PORT):
		return false
	ann = await rig.add_client(PORT, "Ann")
	bob = await rig.add_client(PORT, "Bob")
	if not check(ann != null and bob != null, "two clients connect"):
		return false
	if not await _wait(func() -> bool: return ann.sync.is_joined() and bob.sync.is_joined(), "both clients welcomed"):
		return false
	# The bomber is a player's here (the strike's is). The host's AI planned it before; Ann's plan replaces that.
	for p: NetRig.Peer in rig.peers():
		p.world.units[BOMBER].controller = World.CONTROLLER_PLAYER
	host.world.clear_plan(BOMBER)
	await _wait(func() -> bool: return _everywhere([], rig.peers()), "the bomber's plan cleared everywhere")

	# 1. A plan with targets -------------------------------------------------------------------------------------
	var s0 := ann.world.plan_step(BOMBER, 0, {"turn": 0.0, "speed": 85.0, "drop": {"aim": [3000.0, 2400.0], "target": {"unit": HEAVY}}})
	var s1 := ann.world.plan_step(BOMBER, 1, {"turn": 0.0, "speed": 85.0, "drop": {"aim": [3050.0, 2410.0], "target": {"point": [3050.0, 2410.0]}}})
	check(not s0.is_empty() and not s1.is_empty(), "1. Ann plans two drops: %s" % ann.world.last_error)
	var plan: Array = (ann.world.units[BOMBER].plan as Array).duplicate(true)
	await _wait(func() -> bool: return _everywhere(plan, [host, bob]), "Ann's two drops on the host and on Bob")
	eq(((host.world.units[BOMBER].plan[0] as Dictionary)["drop"] as Dictionary)["target"], {"unit": HEAVY}, "1. the host holds step 1's unit target")
	eq(((bob.world.units[BOMBER].plan[1] as Dictionary)["drop"] as Dictionary)["target"], {"point": [3050.0, 2410.0]}, "1. Bob holds step 2's point target")
	for p: NetRig.Peer in [host, bob]:
		var st: Dictionary = (p.world.planned_states(BOMBER)[0] as Dictionary)["drop"]
		eq(st.get("target"), {"unit": HEAVY}, "1. %s's own analysis of step 1 carries the target" % p.label)
	check(int(host.sync.stats.get("refused_plan", 0)) == 0, "1. the host refused nothing")

	# 2. Last edit wins -------------------------------------------------------------------------------------------
	bob.world.plan_step(BOMBER, 0, {"turn": 0.0, "speed": 85.0, "drop": {"aim": [3010.0, 2395.0], "target": {"point": [3010.0, 2395.0]}}})
	var bobs: Array = (bob.world.units[BOMBER].plan as Array).duplicate(true)
	await _wait(func() -> bool: return _everywhere(bobs, rig.peers()), "Bob's retargeted step on all three")
	eq(((ann.world.units[BOMBER].plan[0] as Dictionary)["drop"] as Dictionary)["target"], {"point": [3010.0, 2395.0]}, "2. the later edit won: step 1's target is Bob's point, on Ann's machine too")
	eq(((ann.world.units[BOMBER].plan[1] as Dictionary)["drop"] as Dictionary)["target"], {"point": [3050.0, 2410.0]}, "2. and step 2's is untouched")

	# 3. The host's guard -----------------------------------------------------------------------------------------
	var good := [{"turn": 0.0, "drop": {"aim": [1.0, 2.0], "target": {"unit": FIGHTER}}}]
	eq(host.sync._plan_problem(BOMBER, good), "", "3. a plan with a good target is accepted")
	for bad: Variant in [5, {}, {"unit": FIGHTER, "point": [1.0, 2.0]}, {"unit": ""}, {"point": [1.0]}, {"point": [INF, 0.0]}, {"unit": FIGHTER, "extra": 1}]:
		check(host.sync._plan_problem(BOMBER, [{"drop": {"aim": [1.0, 2.0], "target": bad}}]) != "", "3. a target of %s is refused" % str(bad))

	# 4. A late joiner -------------------------------------------------------------------------------------------
	var cat: NetRig.Peer = await rig.add_client(PORT, "Cat")
	if not check(cat != null, "4. a third client connects"):
		return false
	if not await _wait(func() -> bool: return cat.sync.is_joined(), "Cat welcomed"):
		return false
	# (Her World is built from the scenario, where the bomber is the AI's: a snapshot only fills in a player unit's plan, so the bomber
	# is flipped and the host's snapshot -- through the engine's own encoder -- applied again, as the join would have in the strike.)
	cat.world.units[BOMBER].controller = World.CONTROLLER_PLAYER
	var snap: Dictionary = host.sync.snapshot()
	check(WorldSync.same(snap, bytes_to_var(var_to_bytes(snap))), "4. the snapshot with the targets in it survives the encoder exactly")
	cat.sync.apply_snapshot(bytes_to_var(var_to_bytes(snap)) as Dictionary)
	check(WorldSync.same(cat.world.units[BOMBER].plan, bobs), "4. Cat, joining from the snapshot, holds the plan with its targets")
	eq(((cat.world.units[BOMBER].plan[1] as Dictionary)["drop"] as Dictionary)["target"], {"point": [3050.0, 2410.0]}, "4. step 2's target among them")

	# 5. The resolve ----------------------------------------------------------------------------------------------
	for p: NetRig.Peer in [ann, bob, cat]:
		p.world.commit(p.player())
	host.world.commit(host.player())
	await _wait(func() -> bool: return host.resolved.size() == 1 and ann.resolved.size() == 1 and bob.resolved.size() == 1 and cat.resolved.size() == 1, "the turn resolved on all four")
	for p: NetRig.Peer in rig.peers():
		var hist: Array = p.world.units[BOMBER].history
		check(hist.size() >= 3, "5. %s has the bomber's history" % p.label)
		if hist.size() >= 3:
			var d1: Dictionary = (hist[1] as Dictionary).get("drop", {})
			eq(d1.get("target"), {"point": [3010.0, 2395.0]}, "5. %s: step 1's drop carries its target in the resolved history" % p.label)
			eq(((hist[2] as Dictionary).get("drop", {}) as Dictionary).get("target"), {"point": [3050.0, 2410.0]}, "5. %s: and step 2's" % p.label)
	for p: NetRig.Peer in [ann, bob, cat]:
		check(WorldSync.same(p.world.units[BOMBER].history, host.world.units[BOMBER].history), "5. %s holds the host's history of the bomber exactly" % p.label)
	return true
