extends "res://scripts/test_support/test_case.gd"

# A PLAYER WHO JOINS MID-TURN HOLDS THE TURN UNTIL THEY READY UP (Alex 2026-10-09: "All
# players must ready up, including a player who joins mid-turn: the turn waits for them").
# Several peers in one process over real ENet sockets (scripts/net/net_rig.gd; the host
# resolves, scripts/net/world_sync.gd). Three cases, each one the way a late joiner
# really arrives:
#
#   1. JOINS DURING PLANNING. The host and Ann are in; Ann is READY. Bea joins: she is a
#      participant at once, and not ready. The host readies -- everybody who was there is now
#      ready -- and the turn does NOT resolve. It resolves when Bea readies.
#   2. HELLO DURING THE PLAYBACK. After a resolve and before the next turn begins (the
#      playback), Cy says hello: the host holds him (pending_hellos) -- a snapshot is a whole
#      game state, so he is let in at the next planning phase -- and when it comes he joins that
#      turn as a participant, not ready, and the turn waits for him.
#   3. A JOINER WHO LEAVES NO LONGER HOLDS IT UP. Di joins mid-turn after everyone else
#      readied; the turn holds; she drops; it resolves.
#
# And the other half of the rule: a player who stays ready-less does not get resolved around
# (the host never resolves with a participant unready), checked by the world's own flags on
# every machine. Port 28781 (CLAUDE.md: one port per networked test).

const NetRig = preload("res://scripts/net/net_rig.gd")
const World = preload("res://scripts/sim/world.gd")

const PORT := 28781

var rig: NetRig = null

func setup(_main) -> void:
	timeout_seconds = 90.0
	rig = NetRig.new()
	add_child(rig)
	var completed: Variant = await _run()
	check(completed == true, "the test ran to its last line (a runtime error would have ended it silently)")
	rig.close_all()
	finish()

func _ready_up(p: NetRig.Peer) -> void:
	p.world.commit(p.player())

# Frames for the sockets to deliver what was sent (a message takes real time, a headless run does
# frames as fast as it can): used to show that something did NOT happen, after a message that must
# have arrived if it was going to has had every chance to.
func _settle(frames: int = 90) -> void:
	for i in frames:
		await get_tree().process_frame
		OS.delay_msec(1)

func _run() -> bool:
	var h: NetRig.Peer = rig.add_host(PORT, "Hal")
	if not check(h != null, "the host binds port %d" % PORT):
		return false
	var ann: NetRig.Peer = await rig.add_client(PORT, "Ann")
	if not check(ann != null, "Ann connects"):
		return false
	var in_game: bool = await rig.wait_until(func() -> bool: return ann.sync.is_joined() and h.world.players.size() == 2)
	if not check(in_game, "Ann is welcomed"):
		return false
	var host_player := h.player()

	# 1. Joins during planning ---------------------------------------------------------------------------
	_ready_up(ann)
	var ann_ready: bool = await rig.wait_until(func() -> bool: return h.world.is_ready(ann.player()))
	check(ann_ready, "1. Ann's Ready reaches the host")
	var bea: NetRig.Peer = await rig.add_client(PORT, "Bea")
	if not check(bea != null, "1. Bea connects"):
		return false
	var bea_in: bool = await rig.wait_until(func() -> bool: return bea.sync.is_joined() and h.world.players.size() == 3)
	if not check(bea_in, "1. Bea is welcomed mid-turn"):
		return false
	check(h.world.participants().has(bea.player()), "1. and is a participant at once")
	check(not h.world.is_ready(bea.player()), "1. who is not ready")
	check(h.world.is_ready(ann.player()), "1. Ann's Ready stands")
	# Bea's World is the host's game, her own ready flag included.
	await rig.wait_until(func() -> bool: return rig.differences_from_host(bea) == "")
	eq(rig.differences_from_host(bea), "", "1. Bea holds the host's game")
	_ready_up(h)
	await _settle()
	var anyone_unready: Array[String] = []
	for who: String in h.world.participants():
		if not h.world.is_ready(who):
			anyone_unready.append(who)
	eq(anyone_unready, [bea.player()] as Array[String], "1. everyone but Bea is ready (the AI included)")
	eq(h.world.phase, World.PHASE_PLANNING, "1. the host holds the turn: Bea has not readied")
	eq(h.world.turn, 1, "1. still turn 1")
	check(h.resolved.is_empty() and bea.resolved.is_empty() and ann.resolved.is_empty(), "1. nobody saw a resolve")
	_ready_up(bea)
	var turn1: bool = await rig.wait_until(func() -> bool: return h.resolved.has(1) and ann.resolved.has(1) and bea.resolved.has(1))
	check(turn1, "1. Bea's Ready completes the set: the host resolves and all three see turn 1 resolved")

	# 2. Hello during the playback --------------------------------------------------------------------------
	# (Turn 1 is resolved and no machine has begun turn 2: the playback.) Cy says hello now.
	var cy: NetRig.Peer = await rig.add_client(PORT, "Cy")
	if not check(cy != null, "2. Cy connects"):
		return false
	var held: bool = await rig.wait_until(func() -> bool: return h.sync.pending_hellos() == 1)
	check(held, "2. the host holds Cy's hello while the turn is being played back")
	check(not cy.sync.is_joined() and h.world.players.size() == 3, "2. Cy is not in yet")
	for p: NetRig.Peer in [h, ann, bea]:
		p.world.begin_turn()
	var cy_in: bool = await rig.wait_until(func() -> bool: return cy.sync.is_joined() and h.world.players.size() == 4)
	if not check(cy_in, "2. the next planning phase lets Cy in"):
		return false
	eq(cy.world.turn, 2, "2. Cy joined turn 2")
	check(h.world.participants().has(cy.player()) and not h.world.is_ready(cy.player()), "2. as a participant who is not ready")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(cy) == "")
	eq(rig.differences_from_host(cy), "", "2. Cy holds the host's game")
	for p: NetRig.Peer in [h, ann, bea]:
		_ready_up(p)
	await _settle()
	eq(h.world.phase, World.PHASE_PLANNING, "2. everyone else is ready and the host holds the turn for Cy")
	check(not h.resolved.has(2), "2. turn 2 has not resolved")
	_ready_up(cy)
	var turn2: bool = await rig.wait_until(func() -> bool: return h.resolved.has(2) and cy.resolved.has(2))
	check(turn2, "2. Cy's Ready completes the set: turn 2 resolves for the host and for Cy")

	# 3. A joiner who leaves no longer holds the turn up --------------------------------------------------------
	for p: NetRig.Peer in [h, ann, bea, cy]:
		p.world.begin_turn()
	var di: NetRig.Peer = await rig.add_client(PORT, "Di")
	if not check(di != null, "3. Di connects"):
		return false
	var di_in: bool = await rig.wait_until(func() -> bool: return di.sync.is_joined() and h.world.players.size() == 5)
	if not check(di_in, "3. Di is welcomed to turn 3"):
		return false
	for p: NetRig.Peer in [h, ann, bea, cy]:
		_ready_up(p)
	await _settle()
	eq(h.world.phase, World.PHASE_PLANNING, "3. the turn waits for Di")
	check(not h.resolved.has(3), "3. turn 3 has not resolved")
	var di_player := di.player()
	rig.drop(di)
	var freed: bool = await rig.wait_until(func() -> bool: return h.resolved.has(3))
	check(freed, "3. Di leaves: she no longer holds the turn up, and it resolves")
	check(not h.world.players.has(di_player) and h.world.players.has(host_player), "3. she is gone from the host's players")
	return true
