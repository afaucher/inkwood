extends "res://scripts/test_support/test_case.gd"

# THE TANK (Track TK2, 2026-10-11; proposed -- every number of the tank, the ground rule and the drive role is a PROPOSED record in
# data/; Alex's are the decisions it stands on: mixed-warfare "tanks move inland and spot for a ship offshore", bridge-mission
# "build it like that", terrain-passability A "every height step is a cliff", trees-do-not-block "for now"). Headless, on the
# STRIKE SEED'S MAP (20261009: its terrain with the water's cap, its river and its road, the bridge where they cross):
#
#   1. THE TANK       data/units/tank.json: a ground unit that moves, the unit sheet's size, speed, turning, health, sight, one
#                     auto-firing turret gun that engages what stands on the ground and never a plane, no bombs, no specials
#   2. THE BRIDGE     a tank drives the road to the bridge and across it, at its road speed, on legal ground all the way
#   3. NO BRIDGE      a destroyed bridge stops it at the bank, dry, held, turn after turn; a bridge that falls under its approach too
#   4. THE MAP        off the road, the map's own height steps and river stop a tank short of them (judged by the map's queries, not
#                     the rule's own); the hull is never over a cliff or the water
#   5. THE GOING      road speed beats off-road speed; woods slow it and never block it
#   6. THE GUN        a tank fires at an enemy tank in range and damages it; out of range, at a friend and at a plane overhead it
#                     does not; it hurts a bridge of the other side; a tank at 0 pips is destroyed, stays, takes no orders
#   7. THE DRIVE ROLE waits out of sight until its start turn, then follows the road to its target and stops there; two waves;
#                     refuses what it cannot do; never plans a step the rule had to stop
#   9. THE SCENARIO   a scenario with a tank gives the World the ground (a scenario without one does not: the Strike is as it was), and
#                     the drive orders take a site for their target
#   8. CO-OP          the host's World and a client's agree through the plan, the resolve (apply_resolution) and a late joiner's
#                     snapshot; the enemy tank's plan never crosses the wire

const World = preload("res://scripts/sim/world.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const GroundRules = preload("res://scripts/sim/ground_rules.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")

const BR := 94    # the road point at the bridge
var _done := 0

func setup(_main) -> void:
	timeout_seconds = 300.0
	for part: Script in [World, GroundRules, AiPilot, WorldSync, TankWorlds]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	var gm: RefCounted = TankWorlds.ground()
	if not check(gm.ok(), "the strike seed's ground builds: %s" % str(gm.errors)):
		finish()
		return
	_data()
	_bridge_crossing()
	_destroyed_bridge()
	_map_rules()
	_going()
	_gun()
	_drive_role()
	_coop()
	_scenario()
	eq(_done, 9, "the test reached its last section (a runtime error would have ended it silently)")
	finish()

# --- 1. The tank -----------------------------------------------------------------------------------------------

func _data() -> void:
	var w := World.new()
	w.quiet = true
	var d = w.unit_def("tank")
	if not check(d != null and w.ok(), "1. the tank loads: %s" % w.last_error):
		return
	eq(d.domain, "ground", "1. a ground unit")
	eq(d.mobility, "mobile", "1. that moves")
	check(not d.is_static(), "1. (not static)")
	eq(d.size_m, 6.0, "1. 6 m: the unit sheet's tank is 5.6 to 6.6 m long")
	eq(d.draught_m, 0.0, "1. draught 0: it does not float")
	eq(d.actions_per_turn, 2, "1. two steps a turn")
	eq(d.health, 6, "1. six pips")
	eq(d.sight_range_m, 600.0, "1. sees 600 m (and more than it shoots)")
	eq(d.silhouette, "tank", "1. drawn by the unit sheet's tank")
	eq(d.bomb_drops, 0, "1. no bombs (drops)")
	eq(d.bomb_per_drop, 0, "1. no bombs (per drop)")
	eq(d.specials, [], "1. no specials: the gun fires on its own")
	var env = d.envelope
	eq(env.speed_max, 10.0, "1. 10 m/s on a road")
	check(env.speed_cruise <= env.speed_max and env.speed_cruise > 0.0, "1. cruise is under the top speed (%s)" % env.speed_cruise)
	check(env.speed_min < 0.0 and env.reverse_from_stop, "1. it can reverse, once stopped")
	eq(env.turn_rate(0.0), env.turn_rate(env.speed_max), "1. pivot steering: one turn rate at any speed")
	near(rad_to_deg(env.turn_rate(5.0)), 30.0, 1e-6, "1. 30 deg/s")
	eq(env.bands, ["surface"] as Array[String], "1. on the surface band")
	eq(env.bands_per_step, 0, "1. it never changes band")
	eq(d.weapons.size(), 1, "1. one weapon")
	var g = d.weapons[0]
	eq(g.id, "turret_gun", "1. the turret gun")
	eq(g.kind, "turret", "1. a turret")
	eq(g.half_across_deg, 180.0, "1. the turret traverses all the way round")
	eq(g.elevation_deg, 0.0, "1. a level cone")
	check(g.half_height_deg >= 5.0 and g.half_height_deg < 20.0, "1. a few degrees up and down (%s)" % g.half_height_deg)
	check(g.effective_range_m < d.sight_range_m, "1. it sees further than it shoots (%s m of %s m)" % [g.effective_range_m, d.sight_range_m])
	eq(g.damage_pips, 1, "1. one pip a hit")
	# every number says it is proposed (the file is read strictly by unit_def.gd, which checks provenance); the decision is quoted
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/tank.json"))
	check(str(raw["_about"]).contains("mixed-warfare"), "1. the file quotes Alex's decision")
	for k: String in ["size_m", "actions_per_turn", "health", "sight_range_m"]:
		check((raw[k] as Dictionary).get("_proposed", false) == true, "1. %s is a PROPOSED record" % k)
	# the gun reaches another tank on the ground and not a plane
	var me := {"x": 0.0, "y": 0.0, "heading": 0.0, "height_m": 0.0}
	var on_ground := {"x": 150.0, "y": 90.0, "height_m": 0.0}
	var behind := {"x": -200.0, "y": 0.0, "height_m": 0.0}
	var plane_low := {"x": 100.0, "y": 0.0, "height_m": w.band_height("low")}
	var params: Dictionary = w.combat.factor_params()
	check(Combat.evaluate(me, g, 0, on_ground, w.combat.odds_factors, params)["in_cone"], "1. a tank 175 m away to the side is in the gun's cone (a turret turns)")
	check(Combat.evaluate(me, g, 0, behind, w.combat.odds_factors, params)["in_cone"], "1. ... and one behind it")
	check(not Combat.evaluate(me, g, 0, plane_low, w.combat.odds_factors, params)["in_cone"], "1. a plane in the low band, 100 m away, is not (a tank cannot answer an air attack)")
	var near_tank := {"x": 14.0, "y": 0.0, "height_m": 0.0}
	check(Combat.evaluate(me, g, 0, near_tank, w.combat.odds_factors, params)["in_cone"], "1. a tank 14 m away is in the cone (no dead zone round the hull)")
	_done += 1

# --- 2. The bridge -----------------------------------------------------------------------------------------------

# An AI tank driving from road point `from` to road point `to`, bridge on the side given. Returns the World, the pilot.
func _drive_world(from: int, to: int, bridge_down: bool = false, start_turn: int = 1) -> Array:
	var w := TankWorlds.world("allies", true)
	TankWorlds.tank(w, "t", "allies", "ai", TankWorlds.road(from), TankWorlds.toward(from, to), 0.0)
	if bridge_down:
		(w.units["bridge_1"] as Object).down = true
	var ai := AiPilot.new()
	var p := TankWorlds.road(to)
	if not check(ai.attach(w, {"t": {"role": "drive", "to": [p.x, p.y], "start_turn": start_turn}}), "the drive role takes its orders: %s" % str(ai.errors)):
		return [w, ai]
	return [w, ai]

func _bridge_crossing() -> void:
	var made := _drive_world(BR + 16, BR - 24)
	var w: World = made[0]
	var ai: AiPilot = made[1]
	var top := 0.0
	var on_deck := false
	var problems: Array[String] = []
	var bad_limits: Array = []
	var arrived_turn := -1
	var min_index := 999
	for i in 20:
		TankWorlds.turn(w)
		var u: Object = w.units["t"]
		top = maxf(top, u.speed)
		var why := TankWorlds.turn_problem(w, "t")
		if why != "":
			problems.append("turn %d: %s" % [i + 1, why])
		for l: Variant in TankWorlds.limits_of(w, "t"):
			if l == Envelope.LIMIT_CLIFF or l == Envelope.LIMIT_WATER:
				bad_limits.append("turn %d: %s" % [i + 1, str(l)])
		for k in 21:
			var s: Dictionary = w.sample("t", 0.25 * float(k), "history")
			if TankWorlds.water().depth_at(float(s["x"]), float(s["y"])) > 0.0:
				on_deck = true
		min_index = mini(min_index, TankWorlds.road_index_near(Vector2(u.x, u.y)))
		if str((ai._mem["t"] as Dictionary)["state"]) == "arrived" and arrived_turn < 0:
			arrived_turn = i + 1
	eq(problems, [] as Array[String], "2. every pose of the drive is on legal ground (judged by the map's own queries)")
	eq(bad_limits, [], "2. no step was stopped by a cliff or the water: the AI plans none the rule would stop")
	check(on_deck, "2. the tank drove over the river, on the bridge")
	check(top >= 9.99, "2. at its road speed (%.2f m/s)" % top)
	check(arrived_turn > 0, "2. it arrived at its target beyond the bridge (turn %d)" % arrived_turn)
	var end := Vector2(w.units["t"].x, w.units["t"].y)
	check(end.distance_to(TankWorlds.road(BR - 24)) < 16.0, "2. ... within its capture radius of it (%.1f m)" % end.distance_to(TankWorlds.road(BR - 24)))
	check(min_index <= BR - 20, "2. it went past the bridge (road point %d, the bridge at %d)" % [min_index, BR])
	check(arrived_turn <= 10, "2. 400 m of road in ten turns or fewer (%d)" % arrived_turn)
	print("[test_tank] 2. the AI tank crossed the bridge and arrived in turn %d, top speed %.2f m/s, nearest road point %d (bridge %d)" % [arrived_turn, top, min_index, BR])
	eq(w.units["t"].speed, 0.0, "2. and it stopped there")
	# A PLAYER's tank over the same bridge: a plan placed by hand, step after step, on the road
	var wp := TankWorlds.world("allies", true)
	TankWorlds.tank(wp, "p", "allies", "player", TankWorlds.road(BR + 12), TankWorlds.toward(BR + 12, BR - 6), 8.0)
	var crossed := false
	for i in 8:
		for k in 2:
			var from_state: Dictionary = wp.units["p"].state() if k == 0 else wp.planned_states("p")[k - 1]
			var at := Vector2(float(from_state["x"]), float(from_state["y"]))
			var ahead := TankWorlds.road(maxi(TankWorlds.road_index_near(at) - 3, 0))
			wp.plan_step("p", k, ahead)
		TankWorlds.turn(wp)
		crossed = crossed or TankWorlds.road_index_near(Vector2(wp.units["p"].x, wp.units["p"].y)) < BR - 4
		eq(TankWorlds.turn_problem(wp, "p"), "", "2. a hand-planned tank is on legal ground (turn %d)" % (i + 1))
	check(crossed, "2. a player's hand-planned steps take a tank over the bridge too")
	_done += 1

# --- 3. No bridge ------------------------------------------------------------------------------------------------

func _destroyed_bridge() -> void:
	var made := _drive_world(BR + 16, BR - 24, true)
	var w: World = made[0]
	var wet := ""
	var held_turns := 0
	for i in 14:
		TankWorlds.turn(w)
		var u: Object = w.units["t"]
		var why := TankWorlds.turn_problem(w, "t")
		if why != "" and wet == "":
			wet = "turn %d: %s" % [i + 1, why]
		if u.speed == 0.0 and TankWorlds.limits_of(w, "t").has(Envelope.LIMIT_WATER):
			held_turns += 1
	var u: Object = w.units["t"]
	var idx := TankWorlds.road_index_near(Vector2(u.x, u.y))
	eq(wet, "", "3. with the bridge down the tank's hull is never over the river or the wall of a cliff")
	check(idx > BR + 1, "3. it stops on the near side (road point %d, the bridge at %d)" % [idx, BR])
	var bridge := TankWorlds.bridge_site()["pos"] as Vector2
	check(Vector2(u.x, u.y).distance_to(bridge) > 10.0, "3. ... at the bank, %.1f m from the bridge's middle (the water is 10 m each way)" % Vector2(u.x, u.y).distance_to(bridge))
	check(held_turns >= 3, "3. held with the limit 'water', turn after turn (%d turns)" % held_turns)
	check(w.unit_grounded("t"), "3. standing on dry ground")
	# a bridge that falls while the tank is on its way: it is stopped from then on
	var made2 := _drive_world(BR + 20, BR - 24)
	var w2: World = made2[0]
	TankWorlds.turn(w2)
	check(TankWorlds.road_index_near(Vector2(w2.units["t"].x, w2.units["t"].y)) > BR + 1, "3. (the tank has not reached the bridge after turn 1)")
	(w2.units["bridge_1"] as Object).down = true   # (a bomb: the World counts it from the next plan on)
	for i in 8:
		TankWorlds.turn(w2)
	var u2: Object = w2.units["t"]
	check(TankWorlds.road_index_near(Vector2(u2.x, u2.y)) > BR, "3. a bridge destroyed on the way stops the tank on the near side")
	eq(TankWorlds.pose_problem(w2, u2.x, u2.y, u2.heading), "", "3. ... dry")
	# a bridge shot down by a tank of the other side: the same stop. Alex (decision bridge-durability, 2026-10-11): a tank's gun CAN bring a
	# bridge down, but "it should take a lot. Like you would have to sit there and shell it for awhile exposing yourself." One pip a hit and
	# 14 pips (data/units/bridge.json, was 10): scripts/test_support/bridge_tuning.gd measures a median of 20 turns of one tank firing steadily.
	var shot := false
	var taken: Array[int] = []
	var followed_up := false
	for seed_v in range(1, 9):
		var w3 := TankWorlds.world("axis", true)       # the bridge is the enemy's: the allied tank's gun is for it
		w3.rng_seed = seed_v
		var b := TankWorlds.bridge_site()["pos"] as Vector2
		TankWorlds.tank(w3, "gun", "allies", "player", b + Vector2(120.0, 40.0), 0.0, 0.0)
		var took := 0
		for i in 70:
			TankWorlds.turn(w3)
			took += 1
			if (w3.units["bridge_1"] as Object).down:
				break
		if not (w3.units["bridge_1"] as Object).down:
			continue
		shot = true
		taken.append(took)
		if followed_up:
			continue
		followed_up = true
		TankWorlds.tank(w3, "t", "axis", "player", TankWorlds.road(BR + 16), TankWorlds.toward(BR + 16, BR - 24), 0.0)
		for k in 2:
			w3.plan_step("t", k, {"turn": 0.0, "speed": 8.0})
		for i in 6:
			for k in 2:
				w3.plan_step("t", k, TankWorlds.road(BR - 20))
			TankWorlds.turn(w3)
		check(TankWorlds.road_index_near(Vector2(w3.units["t"].x, w3.units["t"].y)) > BR, "3. a bridge shot down by a tank's gun (seed %d) stops a tank like any other" % seed_v)
	check(shot, "3. a tank's gun can bring a bridge of the other side down (14 pips, 1 a hit)")
	var total := 0
	var fewest := 999
	for n: int in taken:
		total += n
		fewest = mini(fewest, n)
	var mean_turns := float(total) / float(maxi(taken.size(), 1))
	print("[tank] one tank shelling a bridge from 126 m brought it down in %s turns over eight dice seeds (mean %.1f)" % [str(taken), mean_turns])
	eq(taken.size(), 8, "3. every one of eight dice seeds brought it down, given time")
	check(fewest >= 8, "3. but none quickly: the fastest took %d turns of one tank firing steadily ('it should take a lot', Alex)" % fewest)
	check(mean_turns >= 14.0 and mean_turns <= 30.0, "3. about twenty turns on average (the measured median is 20): %.1f" % mean_turns)
	_done += 1

# --- 4. The map's cliffs and water ------------------------------------------------------------------------------

# Along the road, the first spot where a straight run to one side meets a height step (kind "level") or water (kind "water")
# first, within [min_d, max_d] m of the road, judged by the map's queries. Returns {i, point, dir (unit vector), heading, d}.
func _find_run(kind: String, min_d: float, max_d: float) -> Dictionary:
	var gm: RefCounted = TankWorlds.ground()
	var water: RefCounted = TankWorlds.water()
	var road: PackedVector2Array = gm.road
	for i in range(4, road.size() - 5, 3):
		var p := road[i]
		var tang := (road[i + 1] - road[i - 1]).normalized()
		for side: int in [1, -1]:
			var n: Vector2 = Vector2(-tang.y, tang.x) * float(side)
			var lv0: int = gm.level_at(p.x, p.y)
			var d := 24.0
			var first_level := INF
			var first_water := INF
			while d <= max_d + 40.0:
				var q: Vector2 = p + n * d
				if first_level == INF and gm.level_at(q.x, q.y) != lv0:
					first_level = d
				if first_water == INF and water.depth_at(q.x, q.y) > 0.0:
					first_water = d
				if first_level != INF or first_water != INF:
					break
				d += 2.0
			var hit := first_level if kind == "level" else first_water
			var other := first_water if kind == "level" else first_level
			if hit >= min_d and hit <= max_d and other == INF:
				return {"i": i, "point": p, "dir": n, "heading": n.angle(), "d": hit}
	return {}

func _map_rules() -> void:
	for kind: String in ["level", "water"]:
		var run := _find_run(kind, 40.0, 170.0)
		if not check(not run.is_empty(), "4. the map has a straight run from the road to a %s within 40 to 170 m" % ("height step" if kind == "level" else "river")):
			continue
		var w := TankWorlds.world("allies", true)
		var start: Vector2 = (run["point"] as Vector2) + (run["dir"] as Vector2) * 14.0     # 14 m off the centre line: off the road
		var heading: float = run["heading"]
		var id := TankWorlds.tank(w, "t", "allies", "player", start, heading, 0.0)
		check(id != "", "4. a tank is placed beside the road at road point %d" % int(run["i"]))
		if id == "":
			continue
		check(w.unit_grounded("t"), "4. ... on legal ground")
		var limit_seen: Array = []
		var problems: Array[String] = []
		for i in 24:
			for k in 2:
				w.plan_step("t", k, {"turn": 0.0, "speed": 10.0})
			TankWorlds.turn(w)
			var why := TankWorlds.turn_problem(w, "t")
			if why != "":
				problems.append("turn %d: %s" % [i + 1, why])
			for l: Variant in TankWorlds.limits_of(w, "t"):
				if not limit_seen.has(l):
					limit_seen.append(l)
		var u: Object = w.units["t"]
		eq(problems, [] as Array[String], "4. %s: every pose of the run is on legal ground by the map's own queries" % kind)
		var travelled := Vector2(u.x, u.y).distance_to(start)
		check(travelled > 0.5 * (float(run["d"]) - 14.0), "4. %s: it drove toward it (%.0f m of the %.0f m)" % [kind, travelled, float(run["d"]) - 14.0])
		check(travelled < float(run["d"]) - 14.0 + 1.0, "4. %s: and stopped short of it (%.1f m of %.1f m)" % [kind, travelled, float(run["d"]) - 14.0])
		eq(u.speed, 0.0, "4. %s: held" % kind)
		print("[test_tank] 4. %s: road point %d, run %.0f m to it, the tank stopped after %.1f m (hull front %.1f m short), limits %s" % [kind, int(run["i"]), float(run["d"]) - 14.0, travelled, float(run["d"]) - 14.0 - travelled - 3.0, str(limit_seen)])
		var want := Envelope.LIMIT_CLIFF if kind == "level" else Envelope.LIMIT_WATER
		check(limit_seen.has(want), "4. %s: the step reports the limit '%s' (%s)" % [kind, want, str(limit_seen)])
		# at the stop the front end is on the same level as the centre (the cliff rule) / dry
		var half := 3.0
		var fx: float = u.x + cos(u.heading) * half
		var fy: float = u.y + sin(u.heading) * half
		if kind == "level":
			eq(TankWorlds.ground().level_at(fx, fy), TankWorlds.ground().level_at(u.x, u.y), "4. level: the front end is on the centre's level")
		else:
			eq(TankWorlds.water().depth_at(fx, fy) > 0.0, false, "4. water: the front end is dry")
		# THE ROAD IS THE EXCEPTION: the same tank driving ALONG the road is not stopped by anything, to where the map ends
		var wr := TankWorlds.world("allies", true)
		TankWorlds.tank(wr, "r", "allies", "player", TankWorlds.road(180), TankWorlds.toward(180, 215), 8.0)
		var stopped := false
		for i in 4:
			for k in 2:
				var s0: Dictionary = wr.units["r"].state() if k == 0 else wr.planned_states("r")[k - 1]
				var here := TankWorlds.road_index_near(Vector2(float(s0["x"]), float(s0["y"])))
				wr.plan_step("r", k, TankWorlds.road(mini(here + 3, 232)))
			TankWorlds.turn(wr)
			if TankWorlds.limits_of(wr, "r").has(Envelope.LIMIT_CLIFF):
				stopped = true
		check(not stopped, "4. %s: along the road, none of it applies" % kind)
	_done += 1

# --- 5. The going ---------------------------------------------------------------------------------------------------

func _going() -> void:
	# ON THE ROAD: asked for its top speed on a straight stretch from rest, it gets there and holds it
	var wr := TankWorlds.world("allies", false)
	TankWorlds.tank(wr, "r", "allies", "player", TankWorlds.road(150), TankWorlds.toward(150, 175), 0.0)
	var road_top := 0.0
	var dist_road := 0.0
	var p0 := Vector2(wr.units["r"].x, wr.units["r"].y)
	for i in 5:
		for k in 2:
			var s0: Dictionary = wr.units["r"].state() if k == 0 else wr.planned_states("r")[k - 1]
			var here := TankWorlds.road_index_near(Vector2(float(s0["x"]), float(s0["y"])))
			wr.plan_step("r", k, TankWorlds.road(mini(here + 4, 232)))
		TankWorlds.turn(wr)
		road_top = maxf(road_top, wr.units["r"].speed)
	dist_road = Vector2(wr.units["r"].x, wr.units["r"].y).distance_to(p0)
	near(road_top, 10.0, 0.01, "5. on the road a tank reaches its 10 m/s")
	# OFF THE ROAD: the same drive across open ground, found on the map
	var open := _find_open_run(180.0)
	if check(not open.is_empty(), "5. the map has 180 m of open, level, dry ground (road point %s)" % str(open.get("i"))):
		var wo := TankWorlds.world("allies", false)
		TankWorlds.tank(wo, "o", "allies", "player", open["point"], open["heading"], 0.0)
		var open_top := 0.0
		var terrain_seen := false
		var po := Vector2(wo.units["o"].x, wo.units["o"].y)
		for i in 5:
			for k in 2:
				wo.plan_step("o", k, {"turn": 0.0, "speed": 10.0})
			TankWorlds.turn(wo)
			open_top = maxf(open_top, wo.units["o"].speed)
			terrain_seen = terrain_seen or TankWorlds.limits_of(wo, "o").has(Envelope.LIMIT_TERRAIN)
		var dist_open := Vector2(wo.units["o"].x, wo.units["o"].y).distance_to(po)
		check(open_top <= 5.0 + 0.01, "5. off the road it is held to half of that or less (%.2f m/s)" % open_top)
		check(open_top > 2.0, "5. ... and drives (%.2f m/s)" % open_top)
		check(road_top > 1.9 * open_top or open_top < 3.2, "5. the road is worth taking: %.1f m/s against %.1f" % [road_top, open_top])
		check(dist_road > 1.3 * dist_open, "5. in five turns it goes %.0f m on the road and %.0f m across country" % [dist_road, dist_open])
		check(terrain_seen, "5. ... the going's cap shows as the step limit 'terrain'")
		print("[test_tank] 5. five turns from rest: road %.2f m/s %.0f m, open ground %.2f m/s %.0f m" % [road_top, dist_road, open_top, dist_open])
	# WOODS: a tank that starts in them is held to a third, and gets through
	var wd := _find_woods()
	if check(not wd.is_empty(), "5. the map has woods a tank can start in (density %s)" % str(wd.get("density"))):
		var ww := TankWorlds.world("allies", false)
		TankWorlds.tank(ww, "w", "allies", "player", wd["point"], wd["heading"], 0.0)
		for k in 2:
			ww.plan_step("w", k, {"turn": 0.0, "speed": 10.0})
		var st: Dictionary = ww.planned_states("w")[1]
		check(float(st["speed"]) <= 3.0 + 0.05, "5. in woods the cap is a third of the top speed (%.2f m/s)" % float(st["speed"]))
		check(float(st["speed"]) >= 1.5, "5. ... never a block (it moves: %.2f m/s)" % float(st["speed"]))
		check((st["limits"] as Array).has(Envelope.LIMIT_TERRAIN), "5. ... limit 'terrain'")
		TankWorlds.turn(ww)
		check(Vector2(ww.units["w"].x, ww.units["w"].y).distance_to(wd["point"]) > 2.0, "5. ... and it did move through the trees")
	_done += 1

# A spot beside the road with `length` m of straight, level, dry, tree-free and road-free ground ahead of it, in some direction.
func _find_open_run(length: float) -> Dictionary:
	var gm: RefCounted = TankWorlds.ground()
	var water: RefCounted = TankWorlds.water()
	var road: PackedVector2Array = gm.road
	for i in range(4, road.size() - 5, 3):
		var p := road[i]
		var tang := (road[i + 1] - road[i - 1]).normalized()
		for side: int in [1, -1]:
			var n: Vector2 = Vector2(-tang.y, tang.x) * float(side)
			var start: Vector2 = p + n * 24.0
			var lv0: int = gm.level_at(start.x, start.y)
			var ok := true
			var d := 0.0
			while d <= length + 10.0:
				var q: Vector2 = start + n * d
				if gm.level_at(q.x, q.y) != lv0 or water.depth_at(q.x, q.y) > 0.0 or gm.woods_at(q.x, q.y) >= 0.5 \
						or TankWorlds.road_dist_brute(q) <= 12.0:
					ok = false
					break
				d += 4.0
			if ok:
				return {"i": i, "point": start, "heading": n.angle()}
	return {}

# A spot of level, dry ground, off the road, with woods under and ahead of it (density 0.5 or more for 20 m).
func _find_woods() -> Dictionary:
	var gm: RefCounted = TankWorlds.ground()
	var water: RefCounted = TankWorlds.water()
	for gy in range(400, 4600, 100):
		for gx in range(400, 4600, 100):
			var p := Vector2(gx, gy)
			var lv0: int = gm.level_at(p.x, p.y)
			var ok := true
			for h: int in [0, 1, 2, 3]:
				var dir := Vector2.from_angle(float(h) * PI * 0.5)
				var q: Vector2 = p + dir * 20.0
				if gm.woods_at(q.x, q.y) < 0.55 or water.depth_at(q.x, q.y) > 0.0 or gm.level_at(q.x, q.y) != lv0 or TankWorlds.road_dist_brute(q) <= 12.0:
					ok = false
					break
			if ok and gm.woods_at(p.x, p.y) >= 0.55 and water.depth_at(p.x, p.y) <= 0.0 and TankWorlds.road_dist_brute(p) > 12.0:
				return {"point": p, "heading": 0.0, "density": gm.woods_at(p.x, p.y)}
	return {}

# --- 6. The gun -----------------------------------------------------------------------------------------------------

func _fires(events: Array, shooter: String, target: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["type"] == "fire" and e["unit"] == shooter and e["target"] == target)

func _gun() -> void:
	var a_at := TankWorlds.road(140)
	var b_at := TankWorlds.road(160)
	var gap := a_at.distance_to(b_at)
	check(gap > 150.0 and gap < 300.0, "6. (the two tanks stand %.0f m apart on the road, inside the gun's 350 m)" % gap)
	var fires := 0
	var hits := 0
	var seeds_with_hits := 0
	var hurt: Dictionary = {}
	var ok_cone := true
	for seed_v in range(1, 31):
		var w := TankWorlds.world("allies", false)
		w.rng_seed = seed_v
		TankWorlds.tank(w, "a", "allies", "player", a_at, (b_at - a_at).angle(), 0.0)
		TankWorlds.tank(w, "b", "axis", "player", b_at, (a_at - b_at).angle(), 0.0)
		var res := TankWorlds.turn(w)
		var ev: Array = res["events"]
		var fa := _fires(ev, "a", "b")
		var fb := _fires(ev, "b", "a")
		fires += fa.size() + fb.size()
		if fa.is_empty() or fb.is_empty():
			ok_cone = false
		var seed_hits := 0
		for e: Dictionary in ev:
			if e["type"] == "hit" and e["weapon"] == "turret_gun":
				seed_hits += 1
				hits += 1
				eq(int(e["damage"]), 1, "6. a hit takes one pip")
		if seed_hits > 0:
			seeds_with_hits += 1
			hurt[seed_v] = {"a": (w.units["a"] as Object).health, "b": (w.units["b"] as Object).health, "hits": seed_hits}
	check(ok_cone, "6. both tanks fire at the other, every turn, in range (a tank 200 m off, each turn, every seed)")
	check(fires >= 30 * 2 * 4, "6. about five rolls a turn each (%d fires in 30 turns of two tanks)" % fires)
	print("[test_tank] 6. 30 seeds, two tanks %.0f m apart, one turn each: %d shots, %d hits in %d seeds" % [gap, fires, hits, seeds_with_hits])
	check(hits > 0 and seeds_with_hits > 3, "6. and they hit (%d hits in %d of 30 seeds)" % [hits, seeds_with_hits])
	var sound := true
	for k: Variant in hurt:
		var rec: Dictionary = hurt[k]
		if int(rec["a"]) + int(rec["b"]) != 12 - int(rec["hits"]):
			sound = false
	check(sound, "6. the pips lost are the hits taken: health follows the hit events")
	# OUT OF RANGE: 700 m of road between them: nobody fires
	var far_i := 140
	var far_j := 140
	for j in range(141, 233):
		if TankWorlds.road(far_i).distance_to(TankWorlds.road(j)) >= 500.0:
			far_j = j
			break
	if check(far_j > far_i, "6. (the road has two points 500 m apart)"):
		var wf := TankWorlds.world("allies", false)
		TankWorlds.tank(wf, "a", "allies", "player", TankWorlds.road(far_i), 0.0, 0.0)
		TankWorlds.tank(wf, "b", "axis", "player", TankWorlds.road(far_j), 0.0, 0.0)
		var quiet_shots := 0
		for i in 3:
			quiet_shots += (TankWorlds.turn(wf)["events"] as Array).filter(func(e: Dictionary) -> bool: return e["type"] == "fire").size()
		eq(quiet_shots, 0, "6. 500 m apart (the gun reaches 350 m, 420 with the overshoot): no shots")
	# A FRIEND, and a PLANE overhead: not shot at
	var wm := TankWorlds.world("allies", false)
	wm.rng_seed = 5
	TankWorlds.tank(wm, "a", "allies", "player", a_at, 0.0, 0.0)
	TankWorlds.tank(wm, "c", "allies", "player", b_at, 0.0, 0.0)
	wm.add_unit({"id": "p", "type": "light_fighter", "side": "axis", "controller": "ai", "x": a_at.x + 20.0, "y": a_at.y, "heading": PI, "speed": 100.0, "altitude_band": "low"})
	var all_events: Array = []
	for i in 2:
		for k in 2:
			wm.plan_step("c", k, {"turn": 0.0, "speed": 0.0})
		for k in 5:
			wm.plan_step("p", k, {"turn": 0.0, "speed": 100.0})
		for pl: String in wm.players.duplicate():
			wm.commit(pl)
		wm.commit(World.AI_PLAYER)
		all_events.append_array(wm.resolve()["events"])
		wm.begin_turn()
	eq(_fires(all_events, "a", "c").size() + _fires(all_events, "c", "a").size(), 0, "6. a tank does not shoot a friend")
	eq(_fires(all_events, "a", "p").size() + _fires(all_events, "c", "p").size(), 0, "6. nor a plane in the low band right over it (its cone is level)")
	# A DESTROYED TANK: found by seed
	var killed := false
	for seed_v in range(1, 40):
		var w2 := TankWorlds.world("allies", false)
		w2.rng_seed = seed_v
		TankWorlds.tank(w2, "a", "allies", "player", a_at, (b_at - a_at).angle(), 0.0)
		TankWorlds.tank(w2, "b", "axis", "player", b_at, (a_at - b_at).angle(), 0.0)
		for i in 40:
			TankWorlds.turn(w2)
			if (w2.units["a"] as Object).down or (w2.units["b"] as Object).down:
				break
		var dead: String = "a" if (w2.units["a"] as Object).down else ("b" if (w2.units["b"] as Object).down else "")
		if dead == "":
			continue
		killed = true
		var du: Object = w2.units[dead]
		eq(du.health, 0, "6. the tank at 0 pips is down (seed %d)" % seed_v)
		eq(du.fate, "destroyed", "6. fate 'destroyed': a tank does not explode or fall")
		check(is_finite(du.history[du.history.size() - 1]["x"]), "6. (it keeps a position)")
		var x0: float = du.x
		w2.quiet = true
		eq(w2.plan_step(dead, 0, {"turn": 0.3, "speed": 5.0}), {}, "6. a destroyed tank takes no orders")
		var alive: String = "b" if dead == "a" else "a"
		var shots_at_wreck := 0
		for i in 2:
			var ev2: Array = TankWorlds.turn(w2)["events"]
			shots_at_wreck += _fires(ev2, alive, dead).size() + _fires(ev2, dead, alive).size()
		eq(shots_at_wreck, 0, "6. nobody fires at a wreck or from one")
		eq(du.x, x0, "6. it stays where it fell")
		break
	check(killed, "6. a tank can be destroyed by another's gun within 40 turns")
	_done += 1

# --- 7. The drive role ---------------------------------------------------------------------------------------------------

func _drive_role() -> void:
	var w := TankWorlds.world("allies", true)
	TankWorlds.tank(w, "e1", "axis", "ai", TankWorlds.road(212), TankWorlds.toward(212, 150), 0.0)
	TankWorlds.tank(w, "e2", "axis", "ai", TankWorlds.road(222), TankWorlds.toward(222, 150), 0.0)
	var to := TankWorlds.road(150)
	var ai := AiPilot.new()
	var ok := ai.attach(w, {
		"e1": {"role": "drive", "to": [to.x, to.y]},
		"e2": {"role": "drive", "to": [to.x, to.y], "start_turn": 4},
	})
	check(ok, "7. the drive role takes two tanks' orders: %s" % str(ai.errors))
	# the course IS the road
	var course: PackedVector2Array = ai.drive.courses["e1"]["pts"]
	var off := 0.0
	for q in course:
		off = maxf(off, TankWorlds.road_dist_brute(q))
	check(off <= 1.0, "7. a target reached by road: the course lies on the road (farthest point %.2f m off it)" % off)
	check(course.size() > 8 and float(ai.drive.courses["e1"]["total"]) > 550.0, "7. ... %d points, %.0f m" % [course.size(), float(ai.drive.courses["e1"]["total"])])
	var e2_start := Vector2(w.units["e2"].x, w.units["e2"].y)
	var moved_early := false
	var first_moving_turn := -1
	var e1_arrived := -1
	var bad: Array = []
	for i in 22:
		TankWorlds.turn(w)
		var t := w.turn - 1
		var u2: Object = w.units["e2"]
		if t < 4 and (Vector2(u2.x, u2.y).distance_to(e2_start) > 0.01 or u2.speed != 0.0):
			moved_early = true
		if t >= 4 and first_moving_turn < 0 and Vector2(u2.x, u2.y).distance_to(e2_start) > 1.0:
			first_moving_turn = t
		if e1_arrived < 0 and str((ai._mem["e1"] as Dictionary)["state"]) == "arrived":
			e1_arrived = t
		for id: String in ["e1", "e2"]:
			for l: Variant in TankWorlds.limits_of(w, id):
				if l == Envelope.LIMIT_CLIFF or l == Envelope.LIMIT_WATER:
					bad.append("%s turn %d %s" % [id, t, str(l)])
			var why := TankWorlds.turn_problem(w, id)
			if why != "":
				bad.append("%s turn %d %s" % [id, t, why])
	check(not moved_early, "7. a unit with a start turn stays put, at rest, until it (turns 1 to 3)")
	eq(first_moving_turn, 4, "7. ... and moves in turn 4")
	print("[test_tank] 7. the first tank arrived in turn %d; the second began to move in turn %d" % [e1_arrived, first_moving_turn])
	check(e1_arrived > 0 and e1_arrived < 14, "7. the first tank arrived (turn %d)" % e1_arrived)
	eq(bad, [], "7. neither tank had a step the ground rule stopped, nor a pose off legal ground")
	var trs := ai.transitions.filter(func(t: Dictionary) -> bool: return t["unit"] == "e2")
	check(trs.size() >= 2 and trs[0]["to"] == "wait" and trs[1]["to"] == "drive" and int(trs[1]["turn"]) == 4, "7. the transitions say wait, then drive at turn 4: %s" % str(trs))
	var u1: Object = w.units["e1"]
	check(Vector2(u1.x, u1.y).distance_to(to) < 16.0 and u1.speed == 0.0, "7. the first tank is stopped at its target (%.1f m)" % Vector2(u1.x, u1.y).distance_to(to))
	# a waypoint route, then a target
	var w2 := TankWorlds.world("allies", true)
	TankWorlds.tank(w2, "e", "axis", "ai", TankWorlds.road(200), TankWorlds.toward(200, 170), 0.0)
	var wp1 := TankWorlds.road(185)
	var wp2 := TankWorlds.road(165)
	var ai2 := AiPilot.new()
	check(ai2.attach(w2, {"e": {"role": "drive", "route": [[wp1.x, wp1.y], [wp2.x, wp2.y]]}}), "7. a drive may be waypoints alone: %s" % str(ai2.errors))
	var nearest := INF
	var far_end := INF
	for i in 14:
		TankWorlds.turn(w2)
		nearest = minf(nearest, TankWorlds.nearest_to(w2, "e", wp1))
	far_end = Vector2(w2.units["e"].x, w2.units["e"].y).distance_to(wp2)
	check(nearest < 8.0, "7. it passed through the first waypoint (%.1f m at the nearest, looking every quarter second)" % nearest)
	check(far_end < 16.0, "7. and stopped at the last (%.1f m)" % far_end)
	# what it refuses
	var w3 := TankWorlds.world("allies", true)
	TankWorlds.tank(w3, "e", "axis", "ai", TankWorlds.road(200), 0.0, 0.0)
	w3.add_unit({"id": "air", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 800.0, "y": 800.0, "heading": 0.0})
	var ai3 := AiPilot.new("res://data/sim/ai.json", true)
	ai3.attach(w3, {})
	check(not ai3.assign("air", {"role": "drive", "to": [900.0, 900.0]}), "7. a plane cannot be told to drive")
	check(not ai3.assign("e", {"role": "drive"}), "7. a drive needs a route or a target")
	check(not ai3.assign("e", {"role": "drive", "to": [900.0, 900.0], "start_turn": 0}), "7. the first turn is 1")
	check(not ai3.assign("e", {"role": "drive", "to": [900.0]}), "7. a point is [x, y]")
	check(not ai3.assign("e", {"role": "drive", "route": [[1.0, 2.0], "x"]}), "7. a route is a list of points")
	check(ai3.assign("e", {"role": "drive", "to": [900.0, 900.0], "start_turn": 3}), "7. and takes a good order")
	_done += 1

# --- 8. Co-op ---------------------------------------------------------------------------------------------------------------

func _coop_game(host: bool) -> Array:
	var w := TankWorlds.world("axis", true)
	TankWorlds.tank(w, "p1", "allies", "player", TankWorlds.road(118), TankWorlds.toward(118, BR), 0.0)
	TankWorlds.tank(w, "p2", "allies", "player", TankWorlds.road(124), TankWorlds.toward(124, BR), 0.0)
	TankWorlds.tank(w, "e1", "axis", "ai", TankWorlds.road(206), TankWorlds.toward(206, 150), 0.0)
	w.rng_seed = 11
	var sync := WorldSync.new()
	sync.name = "WorldSync_%s_%d" % ["host" if host else "peer", get_child_count()]
	add_child(sync)
	sync.setup(w, "tank_test", "local")
	var ai: AiPilot = null
	if host:
		ai = AiPilot.new()
		var to := TankWorlds.road(150)
		ai.attach(w, {"e1": {"role": "drive", "to": [to.x, to.y], "start_turn": 2}})
	return [w, sync, ai]

static func _units_alike(a: World, b: World) -> String:
	for id: String in a.units:
		var ua: Object = a.units[id]
		var ub: Object = b.units.get(id)
		if ub == null:
			return "%s is missing" % id
		if not WorldSync.same(ua.net_state(), ub.net_state()):
			return "%s differs: %s against %s" % [id, str(ua.net_state()), str(ub.net_state())]
		if not WorldSync.same(ua.history, ub.history):
			return "%s's history differs" % id
	return ""

func _coop() -> void:
	var h := _coop_game(true)
	var c := _coop_game(false)
	var host: World = h[0]
	var host_sync: WorldSync = h[1]
	var client: World = c[0]
	var client_sync: WorldSync = c[1]
	# a snapshot of the host's turn-1 game makes the client's the same
	host.plan_step("p1", 0, TankWorlds.road(114))
	host.plan_step("p1", 1, TankWorlds.road(110))
	host.plan_step("p2", 0, {"turn": 0.1, "speed": 8.0})
	var snap := host_sync.snapshot()
	eq((snap["units"]["e1"]["plan"] as Array).size(), 0, "8. the snapshot carries no plan for the enemy tank")
	eq((snap["units"]["p1"]["plan"] as Array).size(), 2, "8. ... and the players' tanks' plans")
	check((host.units["e1"].plan as Array).size() > 0, "8. (the host's AI did plan it)")
	client_sync.apply_snapshot(snap)
	check(WorldSync.same(client.units["p1"].plan, host.units["p1"].plan), "8. the client has the host's plan for p1")
	check(WorldSync.same(client.units["p2"].plan, host.units["p2"].plan), "8. ... and for p2")
	eq((client.units["e1"].plan as Array).size(), 0, "8. the client's enemy tank has no plan")
	# the rule gives both the same steps: the same plan on either World is the same states, to the bit
	var hs: Array = host.planned_states("p1")
	var cs: Array = client.planned_states("p1")
	check(WorldSync.same(hs, cs), "8. the same plan on the host and the client is the same states (the ground rule is deterministic)")
	var stop_h := host.plan_step("p2", 1, Vector2(1100.0, 760.0))   # a point far off the road: clamped the same way on both
	var stop_c := client.plan_step("p2", 1, Vector2(1100.0, 760.0))
	check(WorldSync.same(stop_h, stop_c), "8. a step clamped by the rule is clamped the same on both")
	# the host resolves; the client applies the result
	host.commit(host_sync.local_player())
	var result := host.resolve()
	check(not result.is_empty(), "8. the host resolves: %s" % host.last_error)
	check(client.apply_resolution(result), "8. the client applies the result: %s" % client.last_error)
	eq(_units_alike(host, client), "", "8. after the resolve every tank agrees (states and histories)")
	host.begin_turn()
	client.begin_turn()
	# a few turns on, the enemy tank starting out at turn 2
	for i in 4:
		host.plan_step("p1", 0, TankWorlds.road(106 - i * 2))
		host.commit(host_sync.local_player())
		var res := host.resolve()
		client.apply_resolution(res)
		eq(_units_alike(host, client), "", "8. turn %d: host and client agree" % host.turn)
		host.begin_turn()
		client.begin_turn()
	check(Vector2(host.units["e1"].x, host.units["e1"].y).distance_to(TankWorlds.road(206)) > 20.0, "8. (the enemy tank has started: it is %.0f m on)" % Vector2(host.units["e1"].x, host.units["e1"].y).distance_to(TankWorlds.road(206)))
	# a late joiner: a fresh World takes the host's snapshot mid-game
	var l := _coop_game(false)
	var late: World = l[0]
	var late_sync: WorldSync = l[1]
	host.plan_step("p2", 0, TankWorlds.road(112))
	late_sync.apply_snapshot(host_sync.snapshot())
	eq(late.turn, host.turn, "8. a late joiner is on the host's turn (%d)" % host.turn)
	eq(_units_alike(host, late), "", "8. ... with every tank where the host has it, with its history")
	check(WorldSync.same(late.units["p2"].plan, host.units["p2"].plan), "8. ... and the plan the players had made")
	host.commit(host_sync.local_player())
	var res2 := host.resolve()
	check(late.apply_resolution(res2), "8. the late joiner applies the next turn: %s" % late.last_error)
	client.apply_resolution(res2)
	eq(_units_alike(host, late), "", "8. and agrees after it")
	eq(_units_alike(host, client), "", "8. as does the client that was there from the start")
	_done += 1

# --- 9. A scenario with tanks ---------------------------------------------------------------------------------------------

func _scenario() -> void:
	var plain := SandboxScenario.new("strike", true)
	var wp := World.new()
	wp.quiet = true
	plain.populate(wp)
	check(not wp.ground.has_queries(), "9. the Strike has no tank: its World is given no ground (it is exactly what it was)")
	check(wp.has_water(), "9. (it has its water)")
	var a := TankWorlds.road(112)
	var b := TankWorlds.road(207)
	var over := {
		"units": [
			{"id": "tank_p1", "type": "tank", "side": "side_a", "controller": "player", "callsign": "pool", "x": a.x, "y": a.y, "heading": TankWorlds.toward(112, BR)},
			{"id": "tank_e1", "type": "tank", "side": "side_b", "controller": "ai", "callsign": "pool", "x": b.x, "y": b.y, "heading": TankWorlds.toward(207, 150), "speed": 0.0},
		],
		"water_units": [{"id": "bridge_1", "type": "bridge", "side": "side_a", "controller": "ai", "site": "water.bridge", "heading": "site"}],
		"water_assignments": {},
		"ai": {"kind": "pilot", "assignments": {"tank_e1": {"role": "drive", "to": {"site": "radio_tower"}, "start_turn": 3}}},
		"objective": {"unit": "tank_p1", "radius_m": 100.0},
		"mission": {"id": "tanks", "win": [{"type": "unit_down", "unit": "tank_e1"}], "lose": [{"type": "unit_down", "unit": "tank_p1"}]},
	}
	var sc := SandboxScenario.new("strike", true, over)
	if not check(sc.ok(), "9. a scenario with tanks reads: %s" % str(sc.errors)):
		return
	var w := World.new()
	w.quiet = true
	var ids := sc.populate(w)
	eq(ids, ["tank_p1", "tank_e1", "bridge_1"] as Array[String], "9. its units are placed")
	check(w.ground.has_queries() and w.has_water(), "9. a scenario with a tank gives its World the ground and the water")
	check(w.unit_grounded("tank_p1") and w.unit_grounded("tank_e1"), "9. the tanks stand on legal ground")
	eq(w.units["tank_p1"].callsign != "", true, "9. the tank has a callsign from the pool (%s)" % w.units["tank_p1"].callsign)
	var ai := sc.make_ai(w)
	check(sc.ai_attach(ai, w), "9. the scenario's AI takes the drive orders: %s" % str((ai as AiPilot).errors))
	var site := sc.site_point("radio_tower")
	var course: PackedVector2Array = (ai as AiPilot).drive.courses["tank_e1"]["pts"]
	check(course[course.size() - 1].distance_to(site) < 0.01, "9. 'to' may be a site: the course ends at the radio tower")
	var start := Vector2(w.units["tank_e1"].x, w.units["tank_e1"].y)
	for i in 6:
		TankWorlds.turn(w)
		if i < 2:
			eq(Vector2(w.units["tank_e1"].x, w.units["tank_e1"].y), start, "9. the enemy tank waits for turn 3 (turn %d)" % (i + 1))
	check(Vector2(w.units["tank_e1"].x, w.units["tank_e1"].y).distance_to(start) > 100.0, "9. ... and drives from turn 3 (%.0f m on after six turns)" % Vector2(w.units["tank_e1"].x, w.units["tank_e1"].y).distance_to(start))
	print("[test_tank] 9. the scenario's tank waited for turn 3 and was %.0f m on after turn 6; its course ends %.1f m from the tower" % [Vector2(w.units["tank_e1"].x, w.units["tank_e1"].y).distance_to(start), course[course.size() - 1].distance_to(site)])
	_done += 1
