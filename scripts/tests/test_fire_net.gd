extends "res://scripts/test_support/test_case.gd"

# THE FOREST FIRE OVER THE WIRE (decision forest-fire, 2026-10-11; the host resolves and rolls, a client only applies). The fire is part of the turn result
# (World.resolve adds "fire", World.apply_resolution applies it) and of the snapshot a joiner is given (WorldSync.snapshot / apply_snapshot): net_fire() and
# apply_net_fire(), the twin of net_bombs / net_guns. Nothing else crosses: the dice, the trees' source and the AI's plans stay on the host.
#
#   1. THE RESULT, IN ONE PROCESS   a host World's result, through var_to_bytes as the wire does, applied to a client World: the same fire (feed, state), the same
#                                   events (fire_ignite, fire_damage, hit, down, fire_out), the same unit that lost its last pip, destroyed where it stood
#   2. A CLIENT WITHOUT THE FIRE    one whose fire knob differs from the host's takes the host's fire (without the terrain) and judges its smoke the same
#   3. FIRE OFF                     a host with no fire sends no "fire"; a client with none stays without
#   4. THE SNAPSHOT, OVER ENET      a host with a fire lit mid-game, a client that joins: it is given the fire; a turn resolves on the host and the client has
#                                   the host's fire and events; a client that joins after the turn is given the whole fire
#
# One port per networked test (CLAUDE.md): 28787.

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const FireFakes = preload("res://scripts/test_support/fire_fakes.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const FireTrees = preload("res://scripts/sim/fire_trees.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")

const PORT := 28787
const SEED := 20261009

var _src: FireTrees = null
var _grove := Vector2.ZERO
var rig: NetRig = null

func setup(_main) -> void:
	timeout_seconds = 180.0
	for part: Script in [NetRig, WorldSync, World, FireFakes, BombWorlds, FireTrees, GroundMap]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	var gm: RefCounted = GroundMap.shared(SEED, WaterGen.shared(SEED))
	_src = FireTrees.new(gm.terrain)
	_grove = FireFakes.grove_point(gm, _src, WorldLayout.shared(SEED).sites()["radio_tower"])
	if not check(_grove != Vector2.INF, "a grove was found"):
		finish()
		return
	eq(_pure(), true, "1-3. the in-process part ran to its end")
	rig = NetRig.new()
	add_child(rig)
	var completed: Variant = await _net()
	check(completed == true, "4. the network part ran to its last line (a runtime error would have ended it silently)")
	rig.close_all()
	finish()

# --- 1 to 3. One process ----------------------------------------------------------------------------------------------------

# A World with a bomber, the tower far away, a one-pip tank rolling past a burning tree, a bomb that lands in the grove at 2 s; with the fire (a source for
# the host, none for a client) when `fire_src` is not the string "off".
func _world(seed_v: int, with_fire: bool, source: Object) -> World:
	var w := BombWorlds.world(seed_v)
	w.add_unit({"id": "tank", "type": "tank", "side": "allies", "controller": "player", "x": 100.0, "y": 2500.0, "heading": 0.0, "speed": 5.0})
	(w.units["tank"] as Unit).health = 1
	if with_fire:
		w.enable_fire(source)
		w.fire.add_lit(FireFakes.tree(1, 112.0, 2500.0, 8.0), 1, 0.0, "bomb")
		BombWorlds.drop_bombs(w, [BombWorlds.record(w, _grove.x, _grove.y, 2.0)])
	return w

func _pure() -> bool:
	# a seed on which the grove catches AND the tank loses its pip, so the one result holds every kind of fire event
	var host: World = null
	var res: Dictionary = {}
	var seed_used := 0
	for s in range(1, 200):
		var h := _world(s, true, _src)
		var r := BombWorlds.turn(h)
		if r.is_empty():
			continue
		var types := {}
		for e: Dictionary in r["events"]:
			types[str(e["type"])] = true
		if types.has("fire_ignite") and types.has("fire_damage"):
			host = h
			res = r
			seed_used = s
			break
	if not check(host != null, "1. some seed ignites the grove and hurts the tank"):
		return false
	var wire: Dictionary = bytes_to_var(var_to_bytes(res)) as Dictionary
	# 1. a client with the fire (no terrain: a client does not need it)
	var client := _world(seed_used, true, null)
	check(client.apply_resolution(wire), "1. the client applies the host's result: %s" % client.last_error)
	check(WorldSync.same(client.net_fire(), host.net_fire()), "1. and holds the host's fire")
	check(WorldSync.same(client.fire.feed(), host.fire.feed()), "1. whose feed is the host's, in the same order")
	check(host.fire.lit_count() >= 2, "1. (%d trees lit: the bomb's and the tank's)" % host.fire.lit_count())
	for rec: Dictionary in client.fire.feed():
		eq(typeof(rec["lit_turn"]), TYPE_INT, "1. lit_turn is still a whole number after the wire")
		eq(typeof(rec["out_turn"]), TYPE_INT, "1. out_turn too")
		eq(typeof(rec["lit_t"]), TYPE_FLOAT, "1. lit_t a float")
	check(WorldSync.same(client.units["tank"].net_state(), host.units["tank"].net_state()), "1. the tank is in the host's state")
	var ct: Unit = client.units["tank"]
	check(ct.down and ct.health == 0 and ct.fate == Unit.FATE_DESTROYED, "1. destroyed by the fire on the client too")
	var heard: Array = []   # (a lambda keeps its own copy of a local: the events go into a shared Array)
	var client2 := _world(seed_used, true, null)
	client2.turn_resolved.connect(func(_t: int, _h: Dictionary, e: Array) -> void: heard.append(e))
	client2.apply_resolution(wire)
	var got: Array = heard[0] if heard.size() == 1 else []
	check(WorldSync.same(got, res["events"]), "1. the client's turn_resolved carries the host's events, the fire's among them")
	var kinds := {}
	for e: Dictionary in got:
		kinds[str(e["type"])] = true
	for k: String in ["fire_ignite", "fire_damage", "hit", "down"]:
		check(kinds.has(k), "1. the event list holds a %s" % k)
	# the smoke is judged the same on both
	for t in [0.0, 2.0, 4.9]:
		eq(client.tracking_denied("tank", t), host.tracking_denied("tank", t), "1. the tank is in the smoke at %.1f s on the client as on the host" % t)
	# the roll is the host's: a client never resolves
	check(not client.apply_resolution(wire), "1. a result is applied once (a second application is refused)")
	# 2. a client that has no fire takes the host's
	var bare := _world(seed_used, false, null)
	check(bare.fire == null, "2. (the client has no fire)")
	check(bare.apply_resolution(wire), "2. and applies the host's result: %s" % bare.last_error)
	check(bare.fire != null and WorldSync.same(bare.net_fire(), host.net_fire()), "2. it takes the host's fire")
	check(bare.fire.source == null, "2. without the terrain (it only shows and judges the smoke)")
	eq(bare.tracking_denied("tank", 0.0), host.tracking_denied("tank", 0.0), "2. and judges the smoke the same")
	# the snapshot pair
	var joiner := _world(seed_used, false, null)
	joiner.apply_net_fire(host.net_fire())
	check(WorldSync.same(joiner.net_fire(), host.net_fire()), "2. a joiner takes net_fire() whole")
	joiner.apply_net_fire({})
	check(WorldSync.same(joiner.net_fire(), host.net_fire()), "2. an empty net_fire changes nothing for a World that has a fire")
	# 3. fire off
	var off := _world(seed_used, false, null)
	var roff := BombWorlds.turn(off)
	check(not roff.has("fire") and off.fire == null, "3. a host with no fire sends no fire and holds none")
	var c3 := _world(seed_used, false, null)
	check(c3.apply_resolution(bytes_to_var(var_to_bytes(roff)) as Dictionary), "3. the client applies it")
	check(c3.fire == null and c3.net_fire().is_empty(), "3. and has no fire")
	var w0 := World.new()
	eq(w0.net_fire(), {}, "3. net_fire() of a World without one is empty")
	w0.apply_net_fire({})
	check(w0.fire == null, "3. and applying an empty one makes none")
	return true

# --- 4. Over ENet ----------------------------------------------------------------------------------------------------------

func _wait(cond: Callable, what: String) -> bool:
	var ok: bool = await rig.wait_until(cond)
	check(ok, "timed out waiting for: " + what)
	return ok

func _net() -> bool:
	var host := rig.add_host(PORT, "Hal")
	if not check(host != null, "4. the host binds port %d" % PORT):
		return false
	# a fire lit before anyone joins (the host's World is the sandbox's: two player planes and a bomber), and a bomb in the air that will light more
	check(host.world.enable_fire(_src), "4. the host takes the fire")
	host.world.fire.add_lit(FireFakes.tree(1, 100.0, 100.0, 8.0), 1, 1.0, "bomb")
	var ann: NetRig.Peer = await rig.add_client(PORT, "Ann")
	if not check(ann != null, "4. a client connects"):
		return false
	if not await _wait(func() -> bool: return ann.sync.is_joined(), "Ann welcomed"):
		return false
	check(ann.world.fire != null, "4. the joiner has a fire (the snapshot made it)")
	check(WorldSync.same(ann.world.net_fire(), host.world.net_fire()), "4. and it is the host's: %s" % str(ann.world.net_fire()))
	eq(ann.world.fire.lit_count(), 1, "4. one tree burning")
	# bombs: a stick lands in the grove at 2 s of the turn; the host resolves when everyone is ready
	host.world.bombs_in_flight.append(BombWorlds.record(host.world, _grove.x, _grove.y, 2.0, 0, "bomber_1"))
	var heard_host: Array = []
	var heard_ann: Array = []
	host.world.turn_resolved.connect(func(_t: int, _h: Dictionary, e: Array) -> void: heard_host.append(e))
	ann.world.turn_resolved.connect(func(_t: int, _h: Dictionary, e: Array) -> void: heard_ann.append(e))
	ann.world.commit(ann.player())
	host.world.commit(host.player())
	if not await _wait(func() -> bool: return host.resolved.size() == 1 and ann.resolved.size() == 1, "the turn resolved on both"):
		return false
	var ignited := host.world.fire.lit_count() - 1
	check(ignited >= 1, "4. the bomb lit %d more trees on the host" % ignited)
	check(WorldSync.same(ann.world.net_fire(), host.world.net_fire()), "4. the client holds the host's fire after the turn")
	check(WorldSync.same(ann.world.fire.feed(), host.world.fire.feed()), "4. feed for feed")
	eq(rig.differences_from_host(ann), "", "4. and every unit alike")
	var ev_host: Array = heard_host[0] if heard_host.size() == 1 else []
	var ev_ann: Array = heard_ann[0] if heard_ann.size() == 1 else []
	var fire_events := 0
	for e: Dictionary in ev_host:
		if str(e["type"]).begins_with("fire_"):
			fire_events += 1
	check(fire_events >= 1 and WorldSync.same(ev_ann, ev_host), "4. the events the client played are the host's (%d of them the fire's)" % fire_events)
	host.world.begin_turn()
	ann.world.begin_turn()
	# a late joiner is given the whole fire (the snapshot)
	var bob: NetRig.Peer = await rig.add_client(PORT, "Bob")
	if not check(bob != null, "4. a second client connects"):
		return false
	if not await _wait(func() -> bool: return bob.sync.is_joined(), "Bob welcomed"):
		return false
	check(bob.world.fire != null and WorldSync.same(bob.world.net_fire(), host.world.net_fire()), "4. a late joiner is given the whole fire")
	check(WorldSync.same(bob.world.fire.feed(), host.world.fire.feed()), "4. feed for feed")
	var snap: Dictionary = host.sync.snapshot()
	check(snap.has("fire") and (snap["fire"] as Dictionary).has("trees"), "4. the snapshot has a fire")
	# the smoke is judged the same by all three at a point inside the first tree's smoke
	for p: NetRig.Peer in rig.peers():
		check(p.world.fire.smoke_at(100.0, 100.0, p.world.fire.game_time(2, 0.0)), "4. %s: a point at the first tree is in smoke in turn 2" % p.label)
	return true
