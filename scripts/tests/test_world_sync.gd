extends "res://scripts/test_support/test_case.gd"

# THE NETWORKED CO-OP TURN (Track N): a host and clients in ONE process, over
# real ENet sockets (scripts/net/net_rig.gd), each with its own World built from
# the sandbox scenario and a WorldSync (scripts/net/world_sync.gd). The rules
# under test are Alex's (2026-10-09): every player sees every plan; the last edit
# wins; every active player readies up and the last Ready resolves; the HOST
# resolves and sends the result; drop-in, drop-out; the enemy's plans never leave
# the host; an edit after Ready takes the Ready back.
#
#   1. JOINING          host + two clients: everyone ends with the host's game
#   2. AN EDIT          reaches the host and the other client; floats keep their bits
#   3. LAST EDIT WINS   one after the other, and both in the same frame
#   4. EDIT AFTER READY takes the Ready back, on the host and everywhere
#   5. THE ENEMY        the AI's plan stays on the host: not in a message, not in a snapshot,
#                       and a client cannot set it either
#   6. READY AND RESOLVE  the host resolves exactly once, when the last Ready comes; every
#                       World holds identical states and histories
#   7. THE NEXT TURN    an edit for a turn the host has not begun is HELD, not lost; one for a
#                       turn already over is dropped
#   8. DROP-OUT         a player leaving stops holding the turn up
#   9. DROP-IN          a peer joining while the host is playing back waits for the planning
#                       phase; one joining mid-turn gets the plans and Ready flags
#  10. A HOST THAT CANNOT HAVE US (another scenario) says so

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")

# One port per networked test: the gate runs tests in parallel (CLAUDE.md).
const PORT := 28779

const FIGHTER := "light_fighter_1"
const HEAVY := "heavy_fighter_1"
const BOMBER := "bomber_1"

var rig: NetRig = null
var host: NetRig.Peer = null
var ann: NetRig.Peer = null
var bob: NetRig.Peer = null

func setup(_main) -> void:
	timeout_seconds = 120.0
	# A script that does not compile still loads (CLAUDE.md), and a runtime error ends a
	# function silently: so say first that the parts exist, and last that the test got to its end.
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

func _run() -> bool:
	host = rig.add_host(PORT, "Hal")
	if not check(host != null, "the host binds port %d" % PORT):
		return false
	host.sync.trace_enabled = true
	ann = await rig.add_client(PORT, "Ann")
	bob = await rig.add_client(PORT, "Bob")
	if not check(ann != null and bob != null, "two clients connect"):
		return false
	ann.sync.trace_enabled = true
	bob.sync.trace_enabled = true

	# 1. Joining -----------------------------------------------------------------------------


	if not await _wait(func() -> bool: return ann.sync.is_joined() and bob.sync.is_joined(), "both clients welcomed"):
		return false
	await _wait(func() -> bool: return _alike(), "every World holds the host's game")
	eq(_alike_why(), "", "1. after joining every World is the host's")
	eq(host.world.players.size(), 3, "1. three players: the host and two clients")
	eq(host.sync.remote_members().size(), 2, "1. the host has two members besides itself")
	check(host.world.players.has(ann.player()) and host.world.players.has(bob.player()), "1. players are named after their peers (peer_<id>)")
	eq(ann.player(), "peer_%d" % ann.id(), "1. a player is named peer_<id>")
	eq(host.player(), "peer_1", "1. the host is peer_1")
	check(not ann.world.players.has("local"), "1. the scenario's 'local' player is gone from a client")
	eq(ann.sync.names.get(bob.player()), "Bob", "1. a client knows the others' display names")
	eq(host.sync.names.get(ann.player()), "Ann", "1. the host knows a client's display name")
	eq(ann.joined_count, 1, "1. the client's joined signal fired once")
	check(host.world.is_ready(World.AI_PLAYER), "1. the AI (on the host only) is ready")
	check(ann.world.is_ready(World.AI_PLAYER), "1. and a client's World knows it")
	eq((ann.world.units[BOMBER].plan as Array).size(), 0, "1. a client's AI unit has no plan")
	check((host.world.units[BOMBER].plan as Array).size() > 0, "1. the host's AI unit has one")

	# 2. An edit reaches the host and the other client -------------------------------------------
	# 0.1234567890123 and 117.12345678901 are not 32-bit floats: they must arrive as written.
	ann.world.plan_step(FIGHTER, 0, {"turn": 0.1234567890123, "speed": 117.12345678901})
	ann.world.plan_step(FIGHTER, 1, {"to": Vector2(3300.0, 2400.0)})
	await _wait(func() -> bool: return _plan_everywhere(FIGHTER, ann.world.units[FIGHTER].plan), "Ann's plan on the host and on Bob")
	eq(_alike_why(), "", "2. an edit reaches the host and the other client")
	var wire_plan: Array = host.world.units[FIGHTER].plan
	eq(wire_plan.size(), 2, "2. two steps arrived")
	check(WorldSync.same(wire_plan[0], {"turn": 0.1234567890123, "speed": 117.12345678901}), "2. floats keep their bits over the wire")
	check(WorldSync.same(wire_plan[1], {"to": Vector2(3300.0, 2400.0)}), "2. a Vector2 target arrives as a Vector2")
	# Nobody owns a unit: the other client may edit Ann's plane too.
	bob.world.plan_step(HEAVY, 0, {"turn": -0.2, "speed": 130.0})
	await _wait(func() -> bool: return _plan_everywhere(HEAVY, bob.world.units[HEAVY].plan), "Bob's plan for the heavy fighter everywhere")
	eq(_alike_why(), "", "2. every player's edits reach every machine")

	# 3. Last edit wins ----------------------------------------------------------------------------
	bob.world.clear_plan(FIGHTER)
	bob.world.plan_step(FIGHTER, 0, {"to": Vector2(3000.0, 2300.0)})
	var bobs: Array = (bob.world.units[FIGHTER].plan as Array).duplicate(true)
	await _wait(func() -> bool: return _plan_everywhere(FIGHTER, bobs), "Bob's later edit replaces Ann's, on all three")
	check(WorldSync.same(ann.world.units[FIGHTER].plan, bobs), "3. the later edit won on the client that made the earlier one")
	eq(_alike_why(), "", "3. one after the other: the later edit wins everywhere")
	# Both in the same frame: arrival order at the host decides, and everyone ends with the host's.
	ann.world.clear_plan(FIGHTER)
	ann.world.plan_step(FIGHTER, 0, {"to": Vector2(3100.0, 2600.0)})
	bob.world.clear_plan(FIGHTER)
	bob.world.plan_step(FIGHTER, 0, {"to": Vector2(3100.0, 2200.0)})
	bob.world.plan_step(FIGHTER, 1, {"to": Vector2(3400.0, 2200.0)})
	await _wait(func() -> bool: return _alike(), "both edits settle on one plan")
	eq(_alike_why(), "", "3. two edits in the same frame: all three end alike")
	var winner: Array = host.world.units[FIGHTER].plan
	var one := [{"to": Vector2(3100.0, 2600.0)}]
	var two := [{"to": Vector2(3100.0, 2200.0)}, {"to": Vector2(3400.0, 2200.0)}]
	check(WorldSync.same(winner, one) or WorldSync.same(winner, two), "3. and it is one of the two plans, not a mix")
	# A burst of edits (a drag): only the last of them counts, with no flicker back. The
	# frames are slowed so the host's echoes of the early positions arrive mid-drag.
	var applied_before := int(ann.sync.stats.get("applied_plan", 0))
	for i in 12:
		ann.world.plan_step(FIGHTER, 0, {"to": Vector2(3000.0 + 20.0 * i, 2500.0)})
		await get_tree().process_frame
		OS.delay_msec(4)
	var dragged: Array = (ann.world.units[FIGHTER].plan as Array).duplicate(true)
	await _wait(func() -> bool: return _plan_everywhere(FIGHTER, dragged), "the end of Ann's drag everywhere")
	eq(_alike_why(), "", "3. after a drag every machine holds its last position")
	eq(int(ann.sync.stats.get("applied_plan", 0)), applied_before, "3. the host's echoes of earlier positions were not applied back over the drag")
	# The guard itself, deterministically (a round trip over loopback takes about a frame, so
	# the race it covers is rare in one process): another player's plan that reaches Ann while
	# her own newer edit is waiting to be sent, or sent and not yet echoed, is not applied over it.
	var mine_plan := [{"to": Vector2(3050.0, 2450.0)}]
	ann.world.clear_plan(FIGHTER)
	ann.world.plan_step(FIGHTER, 0, mine_plan[0])
	var stray := {"unit": FIGHTER, "plan": [{"to": Vector2(1111.0, 2222.0)}], "from": bob.id(), "seq": 1}
	ann.sync._client_apply_plan_set(stray)
	check(WorldSync.same(ann.world.units[FIGHTER].plan, mine_plan), "3. another player's plan does not replace an edit waiting to be sent")
	ann.sync.flush()
	ann.sync._client_apply_plan_set(stray)
	check(WorldSync.same(ann.world.units[FIGHTER].plan, mine_plan), "3. nor one sent and not yet echoed")
	await _wait(func() -> bool: return _plan_everywhere(FIGHTER, mine_plan), "Ann's edit everywhere")
	eq(_alike_why(), "", "3. and the host's last word is hers on every machine")

	# 4. An edit after Ready takes the Ready back ----------------------------------------------------
	ann.world.commit(ann.player())
	await _wait(func() -> bool: return host.world.is_ready(ann.player()) and bob.world.is_ready(ann.player()), "Ann's Ready on the host and on Bob")
	check(true, "4. Ann is ready on the host and on Bob")
	ann.world.plan_step(FIGHTER, 2, {"to": Vector2(3500.0, 2500.0)})
	await _wait(func() -> bool: return not host.world.is_ready(ann.player()) and not bob.world.is_ready(ann.player()) and not ann.world.is_ready(ann.player()), "Ann's edit taking her Ready back everywhere")
	check(not host.world.is_ready(ann.player()), "4. the host agrees: an edit after Ready un-readies")
	check(not ann.world.is_ready(ann.player()), "4. and so does the editor's own World")
	check(not bob.world.is_ready(ann.player()), "4. and the other client sees it")
	eq(host.resolved.size(), 0, "4. nothing resolved yet")
	# A player's Ready does not un-ready the others.
	bob.world.commit(bob.player())
	await _wait(func() -> bool: return host.world.is_ready(bob.player()), "Bob's Ready on the host")
	ann.world.plan_step(FIGHTER, 3, {"to": Vector2(3600.0, 2500.0)})
	await _wait(func() -> bool: return _plan_everywhere(FIGHTER, ann.world.units[FIGHTER].plan), "Ann's next edit everywhere")
	check(host.world.is_ready(bob.player()), "4. Ann's edit does not take Bob's Ready back (proposed: an open question for Alex)")

	# 5. The enemy's plans stay on the host --------------------------------------------------------------
	var host_bomber_plan: Array = (host.world.units[BOMBER].plan as Array).duplicate(true)
	check(host_bomber_plan.size() > 0, "5. the AI planned on the host")
	for p: NetRig.Peer in [ann, bob]:
		eq((p.world.units[BOMBER].plan as Array).size(), 0, "5. %s's AI unit has no plan" % p.label)
	var snap: Dictionary = host.sync.snapshot()
	eq((snap["units"][BOMBER]["plan"] as Array).size(), 0, "5. the snapshot a joiner gets carries no AI plan")
	check((snap["units"][FIGHTER]["plan"] as Array).size() > 0, "5. but it carries the players' plans")
	# A client that tries to set the enemy's plan is refused, and told what the host really has.
	ann.sync.rpc_req_plan.rpc_id(1, host.world.turn, BOMBER, [{"to": Vector2(10.0, 10.0)}], 900)
	ann.world.plan_step(FIGHTER, 4, {"to": Vector2(3700.0, 2500.0)})   # the barrier: it follows the attempt on the same channel
	await _wait(func() -> bool: return _plan_everywhere(FIGHTER, ann.world.units[FIGHTER].plan), "the barrier edit everywhere")
	check(WorldSync.same(host.world.units[BOMBER].plan, host_bomber_plan), "5. a client cannot change the AI's plan")
	check(int(host.sync.stats.get("refused_plan", 0)) >= 1, "5. the host refused it")
	# Nothing about the bomber ever crossed the wire, from anyone.
	var crossed := 0
	for p: NetRig.Peer in rig.peers():
		for e: Dictionary in p.sync.trace:
			if e.get("unit", "") == BOMBER and e["kind"] in ["req_plan", "plan_set"]:
				crossed += 1
	# (the attempt above went around WorldSync.flush, by hand: it is the only one)
	eq(crossed, 0, "5. no plan message about the AI unit was sent by any peer's WorldSync")
	eq((ann.world.units[BOMBER].plan as Array).size(), 0, "5. the refusal did not give a client the AI's plan either")

	# 6. Ready and resolve --------------------------------------------------------------------------------
	ann.world.commit(ann.player())
	await _wait(func() -> bool: return host.world.is_ready(ann.player()), "Ann's Ready on the host")
	eq(host.world.phase, World.PHASE_PLANNING, "6. the host waits: it is not ready itself")
	eq(host.resolved.size(), 0, "6. two Readys of three: no resolve")
	# The host edits and readies in the same frame (the edit is still queued when Ready comes):
	# the edit came first, so the Ready stands (a bug once withdrew it re-entrantly and stalled
	# the turn while the clients were told the host was ready).
	host.world.plan_step(HEAVY, 0, {"to": Vector2(3000.0, 3000.0)})
	host.world.commit(host.player())
	check(host.world.is_ready(host.player()) or host.resolved.size() == 1, "6. the host's Ready survives sending its own edit made just before it")
	await _wait(func() -> bool: return host.resolved.size() == 1 and ann.resolved.size() == 1 and bob.resolved.size() == 1, "the turn resolved on all three")
	await _wait(func() -> bool: return _alike(), "all three Worlds alike after the resolve")
	eq(_alike_why(), "", "6. every World holds identical unit states and histories after the resolve")
	eq(host.resolved, [1] as Array[int], "6. the host resolved turn 1, once")
	eq(ann.resolved, [1] as Array[int], "6. a client applied the host's turn 1")
	eq(bob.resolved, [1] as Array[int], "6. the other client too")
	for p: NetRig.Peer in rig.peers():
		eq(p.world.phase, World.PHASE_RESOLVED, "6. %s is in the resolved phase" % p.label)
	check(int(host.sync.stats.get("resolved", 0)) == 1, "6. the host's WorldSync resolved exactly once")
	check(not ann.world.units[FIGHTER].x == 2850.0, "6. the fighter moved on a client")
	for p: NetRig.Peer in rig.peers():
		check((p.world.units[FIGHTER].history as Array).size() == 6, "6. %s has the fighter's six-state history" % p.label)
		eq((p.world.units[FIGHTER].plan as Array).size(), 0, "6. plans are consumed on %s" % p.label)

	# 7. The next turn: held and dropped -----------------------------------------------------------------------
	# Ann's playback "finishes" first and she plans turn 2 while the host is still on turn 1's playback.
	ann.world.begin_turn()
	eq(ann.world.turn, 2, "7. Ann is on turn 2")
	ann.world.plan_step(FIGHTER, 0, {"to": Vector2(3300.0, 2700.0)})
	var anns: Array = (ann.world.units[FIGHTER].plan as Array).duplicate(true)
	await _wait(func() -> bool: return host.sync.pending_count() == 1, "the host holding Ann's turn-2 edit")
	eq((host.world.units[FIGHTER].plan as Array).size(), 0, "7. the host has not applied an edit for a turn it has not begun")
	eq(host.world.turn, 1, "7. the host is still on turn 1")
	host.world.begin_turn()   # the AI replans and readies here
	await _wait(func() -> bool: return host.sync.pending_count() == 0, "the host applying the held edit")
	check(WorldSync.same(host.world.units[FIGHTER].plan, anns), "7. the held edit was applied when the host began turn 2")
	await _wait(func() -> bool: return bob.sync.pending_count() >= 1, "Bob holding the host's turn-2 messages")
	eq((bob.world.units[FIGHTER].plan as Array).size(), 0, "7. Bob, still playing turn 1 back, has not applied turn 2's plan")
	bob.world.begin_turn()
	await _wait(func() -> bool: return bob.sync.pending_count() == 0 and WorldSync.same(bob.world.units[FIGHTER].plan, anns), "Bob applying the held plan")
	check(WorldSync.same(bob.world.units[FIGHTER].plan, anns), "7. Bob has Ann's plan once he is on turn 2")
	await _wait(func() -> bool: return _alike(), "all three alike on turn 2")
	eq(_alike_why(), "", "7. turn 2: all three alike")
	check(host.world.is_ready(World.AI_PLAYER) and bob.world.is_ready(World.AI_PLAYER) and ann.world.is_ready(World.AI_PLAYER), "7. the AI's turn-2 Ready reached everyone")
	# An edit for a turn that is over is dropped.
	var before: int = int(host.sync.stats.get("dropped_stale", 0))
	bob.sync.rpc_req_plan.rpc_id(1, 1, HEAVY, [{"to": Vector2(1.0, 1.0)}], 800)
	bob.world.plan_step(HEAVY, 0, {"turn": 0.1, "speed": 120.0})   # the barrier
	await _wait(func() -> bool: return _plan_everywhere(HEAVY, bob.world.units[HEAVY].plan), "the barrier edit everywhere")
	eq(int(host.sync.stats.get("dropped_stale", 0)), before + 1, "7. a request for turn 1 is dropped on turn 2")
	check(not WorldSync.same(host.world.units[HEAVY].plan, [{"to": Vector2(1.0, 1.0)}]), "7. and changed nothing")

	# 8. Drop-out ---------------------------------------------------------------------------------------------------
	ann.world.commit(ann.player())
	host.world.commit(host.player())
	await _wait(func() -> bool: return host.world.is_ready(ann.player()) and host.world.is_ready(host.player()), "Ann and the host ready")
	eq(host.resolved.size(), 1, "8. Bob is not ready: the turn waits for him")
	var bob_player := bob.player()
	rig.drop(bob)
	await _wait(func() -> bool: return host.resolved.size() == 2, "the turn resolving without Bob")
	eq(host.world.players.size(), 2, "8. the host dropped Bob from the players")
	await _wait(func() -> bool: return ann.resolved.size() == 2, "Ann receiving turn 2")
	eq(ann.world.players.size(), 2, "8. Ann was told Bob left")
	check(not ann.world.players.has(bob_player), "8. and who")
	eq(host.resolved, [1, 2] as Array[int], "8. a leaving player stopped holding the turn up")
	bob = null

	# 9. Drop-in -------------------------------------------------------------------------------------------------------
	# The host is in the resolved phase (playing turn 2 back): a joiner waits for the planning phase.
	var cat: NetRig.Peer = await rig.add_client(PORT, "Cat")
	if not check(cat != null, "9. a third client connects"):
		return false
	cat.sync.trace_enabled = true
	await _wait(func() -> bool: return host.sync.pending_hellos() == 1, "the host holding Cats hello")
	check(not cat.sync.is_joined(), "9. a peer arriving during the playback is not welcomed yet")
	host.world.begin_turn()
	ann.world.begin_turn()
	await _wait(func() -> bool: return cat.sync.is_joined(), "Cat welcomed when the host plans again")
	cat.world.turn_resolved.connect(func(_t: int, _h: Dictionary, _e: Array) -> void: pass)
	await _wait(func() -> bool: return _alike_for([host, ann, cat]), "Cat matches the host")
	eq(_why([host, ann, cat]), "", "9. a peer that joined while the host played back matches the host at turn 3")
	eq(cat.world.turn, 3, "9. on turn 3")
	check(WorldSync.same((cat.world.units[FIGHTER].history as Array), host.world.units[FIGHTER].history), "9. with the units' histories")
	# A peer joining MID-TURN: plans, Readys and all.
	ann.world.plan_step(FIGHTER, 0, {"to": Vector2(3000.0, 2300.0)})
	ann.world.plan_step(FIGHTER, 1, {"to": Vector2(3200.0, 2200.0)})
	cat.world.plan_step(HEAVY, 0, {"turn": 0.2, "speed": 125.0})
	ann.world.commit(ann.player())
	await _wait(func() -> bool: return _plan_everywhere(FIGHTER, ann.world.units[FIGHTER].plan, [host, ann, cat]) and _plan_everywhere(HEAVY, cat.world.units[HEAVY].plan, [host, ann, cat]) and host.world.is_ready(ann.player()), "plans and Ann's Ready everywhere")
	var dan: NetRig.Peer = await rig.add_client(PORT, "Dan")
	if not check(dan != null, "9. a fourth client connects"):
		return false
	dan.sync.trace_enabled = true
	await _wait(func() -> bool: return dan.sync.is_joined(), "Dan welcomed mid-turn")
	await _wait(func() -> bool: return _alike_for([host, ann, cat, dan]), "Dan matches the host")
	eq(_why([host, ann, cat, dan]), "", "9. a peer that joined mid-turn matches the host: plans, Ready flags, players")
	check(dan.world.is_ready(ann.player()), "9. Dan sees Ann's Ready")
	check(WorldSync.same(dan.world.units[FIGHTER].plan, ann.world.units[FIGHTER].plan), "9. and Ann's plan")
	eq(dan.world.players.size(), 4, "9. four players")
	eq((dan.world.units[BOMBER].plan as Array).size(), 0, "9. and no plan for the AI unit")
	var dan_heard_bomber := 0
	for e: Dictionary in host.sync.trace:
		if e.get("unit", "") == BOMBER:
			dan_heard_bomber += 1
	eq(dan_heard_bomber, 0, "9. the host never sent anything about the AI unit to anyone")
	# The new player holds the turn until they are ready; when they are, it resolves.
	host.world.commit(host.player())
	cat.world.commit(cat.player())
	await _wait(func() -> bool: return host.world.is_ready(cat.player()), "Cat's Ready on the host")
	eq(host.resolved.size(), 2, "9. Dan is not ready: no resolve")
	dan.world.commit(dan.player())
	await _wait(func() -> bool: return host.resolved.size() == 3 and dan.resolved.size() == 1 and cat.resolved.size() == 1 and ann.resolved.size() == 3, "turn 3 resolved for everyone")
	await _wait(func() -> bool: return _alike_for([host, ann, cat, dan]), "all four alike after turn 3")
	eq(_why([host, ann, cat, dan]), "", "9. turn 3 resolved on the last Ready; all four alike")
	eq(dan.resolved, [3] as Array[int], "9. Dan applied turn 3")

	# 10. A host that cannot have us ---------------------------------------------------------------------------------------
	var refusals: Array[String] = []
	ann.sync.refused.connect(func(why: String) -> void: refusals.append(why))
	ann.sync.rpc_hello.rpc_id(1, WorldSync.PROTOCOL, "another_scenario", [], "Ann")
	await _wait(func() -> bool: return refusals.size() == 1, "the host refusing another scenario")
	check(refusals.size() == 1 and "scenario" in refusals[0], "10. a hello for another scenario is refused, with the reason")
	print("[test] host wire: ", host.sync.stats)
	print("[test] ann wire: ", ann.sync.stats)
	return true

# --- Helpers ------------------------------------------------------------------------------------------------------

func _wait(cond: Callable, what: String) -> bool:
	var ok: bool = await rig.wait_until(cond)
	check(ok, "timed out waiting for: " + what)
	return ok

# Every peer's World equals the host's?
func _alike() -> bool:
	return _alike_for(rig.peers())

func _alike_for(peers: Array) -> bool:
	return _why(peers) == ""

func _alike_why() -> String:
	return _why(rig.peers())

func _why(peers: Array) -> String:
	for p: NetRig.Peer in peers:
		if p == host:
			continue
		var d := rig.differences_from_host(p)
		if d != "":
			return "%s: %s" % [p.label, d]
	return ""

# Does `unit` hold exactly `plan` on every given peer (default: all)?
func _plan_everywhere(unit: String, plan: Array, peers: Array = []) -> bool:
	for p: NetRig.Peer in (peers if not peers.is_empty() else rig.peers()):
		if not WorldSync.same(p.world.units[unit].plan, plan):
			return false
	return true
