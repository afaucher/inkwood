extends "res://scripts/test_support/test_case.gd"

# THE WATER'S UNITS AND SITES (Track WS, 2026-10-10; proposed -- the boats and the bridge are Alex's, their numbers and
# places are the track's): everything BELOW THE DRAWING of the boats and the bridge, headless.
#
#   1. DATA          the sites records of data/world/water.json are proposals with reasons; the sea rule's numbers (data/sim/sea.json)
#                    and the sail role's (data/sim/ai.json) load.
#   2. THE SITES     seed 20261009's water gives a bridge at the river's crossing of the road (the road's heading), a patrol loop
#                    and a supply route: every point of them on water deep enough for the boat that sails them, clear of the
#                    shore by their margin on an independent probe, off the river, near its mouth; the same on a second build and
#                    through WaterGen.shared; on other seeds whatever sites there are hold to the same rules.
#   3. THE UNITS     patrol_boat, supply_boat and bridge load; domain, mobility, draught, numbers, the boat's two mounts of light AA
#                    guns, the barge unarmed, no bombs, no specials.
#   4. THE WATER RULE  (a synthetic shore, no generator): a sea unit cannot be put on land, a step that would leave the water is
#                    CLAMPED (slowed, and held when even the slowest leaves it) with the limit "shore", a boat left to carry on stops
#                    short of the shore and is afloat at every turn's end, it can back away; a plane ignores the water; with no
#                    water the rule is off.
#   5. THE AI        on the real water the patrol boat sails its loop for a lap (30 turns) and the barge its route out and back
#                    without a step the World had to clamp, afloat all the time; a boat put at the shore backs away and stays afloat.
#   6. THE GUNS      the patrol boat's guns fire at a plane in range (low band), never at the medium band, can hurt it; the barge
#                    is unarmed.
#   7. THE BRIDGE    destroyed like the radio tower: by bombs landed on it (three direct hits leave it standing, four bring it down,
#                    fate "destroyed", it stays in World.units), and by a bomber's run (some seed of 1..40 does it).
#   8. THE STRIKE    with the scenario's water switch OFF (as it ships) it is exactly today's Strike, whatever water keys the file
#                    carries; with it ON the Strike stands up with the bridge, the patrol boat on its loop and the barge on its
#                    route, on the defending side, the mission is the same and judges the tower and the bomber only, the world is
#                    given the water, the AI sails the boats, and a game played to the turn limit has them afloat all the time.
#
# The numbers measured are printed as [water-units] lines for the report.

const WaterGen = preload("res://scripts/world/water_gen.gd")
const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const AiSteer = preload("res://scripts/sim/ai_steer.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const JsMath = preload("res://scripts/core/js_math.gd")

const SEED := 20261009
const OTHER_SEEDS := [1, 2, 3, 4, 5, 6]
const PATROL := "patrol_boat_1"
const SUPPLY := "supply_boat_1"
const BRIDGE := "bridge_1"
const TOWER := "radio_tower_1"
const BOMBER := "bomber_1"

var _water: WaterGen = null
var _sites: Dictionary = {}

func setup(_main) -> void:
	timeout_seconds = 300.0
	var t0 := Time.get_ticks_usec()
	for part: Script in [WaterGen, World, AiPilot, SandboxScenario, BombWorlds]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	eq(_body(), "done", "the water-units test ran to its end (a runtime error in a dependency would stop it silently)")
	print("[water-units] test total %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	finish()

func _body() -> String:
	_water = WaterGen.shared(SEED) as WaterGen
	if not check(_water.ok(), "the water of seed %d builds: %s" % [SEED, _water.errors]):
		return "build failed"
	var t0 := Time.get_ticks_usec()
	_sites = _water.sites()
	print("[water-units] sites of seed %d made in %.0f ms" % [SEED, (Time.get_ticks_usec() - t0) / 1000.0])
	_data()
	_site_checks()
	_units()
	_rule()
	_sailing()
	_guns()
	_bridge()
	_strike_off()
	_strike_on()
	return "done"

# --- helpers ------------------------------------------------------------------------------------------------------

static func _def(type_id: String) -> UnitDef:
	var w := World.new()
	w.quiet = true
	return w.unit_def(type_id)

# One turn of a world with the player "local": begin it if the last was resolved, ready up, resolve.
static func _turn(w: World) -> Dictionary:
	if w.phase == World.PHASE_RESOLVED:
		w.begin_turn()
	w.commit("local")
	return w.resolve()

# The samples of a polyline every `step` metres (the corners included), closed or not.
static func _samples(pts: Array, closed: bool, step: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var n := pts.size() if closed else pts.size() - 1
	for i in n:
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[(i + 1) % pts.size()]
		var count := maxi(1, ceili(a.distance_to(b) / step))
		for k in count:
			out.append(a.lerp(b, float(k) / float(count)))
	if not closed:
		out.append(pts[pts.size() - 1])
	return out

static func _distance_to_polyline(p: Vector2, pts: Array, closed: bool) -> float:
	var best := INF
	var n := pts.size() if closed else pts.size() - 1
	for i in n:
		var c := Geometry2D.get_closest_point_to_segment(p, pts[i], pts[(i + 1) % pts.size()])
		best = minf(best, c.distance_to(p))
	return best

# Signed area by the shoelace sum: positive is clockwise ON SCREEN (x right, y down).
static func _clockwise_area(pts: Array) -> float:
	var a := 0.0
	for i in pts.size():
		var p: Vector2 = pts[i]
		var q: Vector2 = pts[(i + 1) % pts.size()]
		a += p.x * q.y - q.x * p.y
	return 0.5 * a

# An INDEPENDENT check of a site's polyline: at every sample (every 10 m) the water is at least `draught` deep, and at 24
# directions round it, ring_m out, too and inside the map. Returns {samples, min_depth, min_ring_depth, bad}.
func _probe(rec: Dictionary, closed: bool, draught: float, ring_m: float) -> Dictionary:
	var map := _water.map_rect()
	var min_depth := INF
	var min_ring := INF
	var bad := 0
	var samples := _samples(rec["points"], closed, 10.0)
	for p in samples:
		var d := _water.depth_at(p.x, p.y)
		min_depth = minf(min_depth, d)
		if d < draught:
			bad += 1
		for k in 24:
			var a := TAU * float(k) / 24.0
			var q := p + Vector2(cos(a), sin(a)) * ring_m
			var dq := _water.depth_at(q.x, q.y) if map.has_point(q) else -1.0
			min_ring = minf(min_ring, dq)
			if dq < draught:
				bad += 1
	return {"samples": samples.size(), "min_depth": min_depth, "min_ring_depth": min_ring, "bad": bad}

# --- 1. data ------------------------------------------------------------------------------------------------------

func _data() -> void:
	var water_json: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/water.json"))
	var leaves := 0
	var bare: Array[String] = []
	var stack: Array = [["sites", (water_json as Dictionary)["sites"]]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var node: Variant = item[1]
		if node is Dictionary and (node as Dictionary).has("value"):
			leaves += 1
			var rec: Dictionary = node
			if not (rec.get("_proposed", false) == true and str(rec.get("_reason", "")).strip_edges() != ""):
				bare.append(str(item[0]))
		elif node is Dictionary:
			for k: String in (node as Dictionary):
				if not k.begins_with("_"):
					stack.append(["%s.%s" % [item[0], k], (node as Dictionary)[k]])
	check(leaves >= 15, "water.json has a sites section of value records (%d)" % leaves)
	eq(bare, [] as Array[String], "every sites record is a proposal with a reason")
	var w := World.new()
	check(w.ok(), "the World loads data/sim/sea.json with the rest: %s" % [w.errors])
	check(w.sea.hull_fraction > 0.0 and w.sea.sample_m > 0.0 and w.sea.slow_tries >= 1, "the sea rule's numbers are there")
	var ai := AiPilot.new("res://data/sim/ai.json", true)
	check(ai.ok(), "data/sim/ai.json loads with its sail section: %s" % [ai.errors])
	check(ai.params.num("sail", "capture_radius_m") > 0.0, "the sail role's numbers are there")

# --- 2. the sites ---------------------------------------------------------------------------------------------------------

func _site_checks() -> void:
	var bridge: Dictionary = _sites["bridge"]
	var loop: Dictionary = _sites["patrol_loop"]
	var route: Dictionary = _sites["supply_route"]
	check(bridge.get("ok", false) == true, "seed %d has a bridge site: %s" % [SEED, _sites["why"]])
	check(loop.get("ok", false) == true, "seed %d has a patrol loop: %s" % [SEED, _sites["why"]])
	check(route.get("ok", false) == true, "seed %d has a supply route: %s" % [SEED, _sites["why"]])
	if bridge.is_empty() or loop.is_empty() or route.is_empty():
		return
	# --- the bridge: the river's crossing of the road, with the road's heading there
	var at: Vector2 = bridge["pos"]
	eq(at, _water.river_crossing, "the bridge is at the river's crossing of the road")
	check(_water.s_at(at.x, at.y) > 0.0, "it is over water")
	var road: PackedVector2Array = _water.layout().road()
	var nearest := INF
	var idx := 0
	for i in road.size():
		if road[i].distance_to(at) < nearest:
			nearest = road[i].distance_to(at)
			idx = i
	check(nearest < 1.0, "it is on the road (%.2f m from a road point)" % nearest)
	var tg := (road[mini(idx + 6, road.size() - 1)] - road[maxi(idx - 6, 0)]).normalized()
	check(absf(Vector2.from_angle(float(bridge["heading"])).dot(tg)) > 0.995, "its heading is the road's (%.1f deg off)" % rad_to_deg(absf(Vector2.from_angle(float(bridge["heading"])).angle_to(tg))))
	check(absf(Vector2.from_angle(float(bridge["heading"])).dot(Vector2.from_angle(float(bridge["flow_heading"])))) < 0.35, "the river runs square across the road at the bridge")
	check(absf(float(bridge["river_width_m"]) - 26.0) < 2.0, "the river is about 26 m wide there (Alex): %.1f m" % float(bridge["river_width_m"]))
	check(float(bridge["gap_m"]) > 5.0 and float(bridge["gap_m"]) <= 60.0, "the road's wet gap is a bridge's length (%.1f m)" % float(bridge["gap_m"]))
	# --- the patrol loop
	var patrol := _def("patrol_boat")
	var pts: Array = loop["points"]
	eq(pts.size(), 4, "the patrol loop has four corners")
	check(_clockwise_area(pts) > 0.0, "the loop runs clockwise on screen")
	var pr := _probe(loop, true, patrol.draught_m, 0.9 * float(loop["margin_m"]))
	eq(int(pr["bad"]), 0, "every point of the loop and a ring of %.0f m round it is on water at least the patrol boat's draught (%.1f m) deep (%d samples, shallowest %.1f m, ring %.1f m)" % [0.9 * float(loop["margin_m"]), patrol.draught_m, pr["samples"], pr["min_depth"], pr["min_ring_depth"]])
	check(float(loop["min_depth_m"]) >= patrol.draught_m, "and the site says so (%.1f m)" % float(loop["min_depth_m"]))
	check(float(loop["length_m"]) >= 800.0, "a loop worth a patrol: %.0f m round" % float(loop["length_m"]))
	for i in pts.size():
		var q: Vector2 = pts[(i + 1) % pts.size()]
		var off := absf(Envelope.wrap_angle(JsMath.atan2(q.y - (pts[i] as Vector2).y, q.x - (pts[i] as Vector2).x) - float((loop["headings"] as Array)[i])))
		check(off < 1e-6, "corner %d's heading is its bearing to the next" % i)
	var mouth := _water.river_mouth
	check((loop["centre"] as Vector2).distance_to(mouth) < 1500.0, "the loop is by the river's mouth (%.0f m from it)" % (loop["centre"] as Vector2).distance_to(mouth))
	# --- the supply route
	var supply := _def("supply_boat")
	var sr := _probe(route, false, supply.draught_m, 0.9 * float(route["margin_m"]))
	eq(int(sr["bad"]), 0, "every point of the supply route and a ring of %.0f m round it is on water at least the barge's draught (%.1f m) deep (%d samples, shallowest %.1f m, ring %.1f m)" % [0.9 * float(route["margin_m"]), supply.draught_m, sr["samples"], sr["min_depth"], sr["min_ring_depth"]])
	check(float(route["length_m"]) >= 700.0, "a route worth a run: %.0f m" % float(route["length_m"]))
	check((route["points"] as Array).size() >= 2, "two ends at least")
	check((route["points"][0] as Vector2).distance_to(mouth) < 1500.0, "it starts by the river's mouth (%.0f m from it)" % (route["points"][0] as Vector2).distance_to(mouth))
	# --- the boats keep to the coast and the estuary, not up the river
	var upstream := int(float(_water.river_pts.size()) * 0.8)
	var closest := INF
	for site: Dictionary in [loop, route]:
		for p in _samples(site["points"], site["kind"] == "loop", 20.0):
			for i in range(0, upstream, 4):
				closest = minf(closest, p.distance_to(_water.river_pts[i]))
	check(closest > 200.0, "no boat site comes within 200 m of the river's upper four fifths (%.0f m)" % closest)
	print("[water-units] bridge %s heading %.1f deg, river %.1f m wide; patrol loop centre %s, %d x %d m (half %.0f x %.0f), margin %.0f m, shallowest %.1f m, %.0f m round; supply route %d points %.0f m, margin %.0f m, shallowest %.1f m" % [
		bridge["pos"], rad_to_deg(float(bridge["heading"])), bridge["river_width_m"], loop["centre"], 2.0 * float(loop["half_length_m"]), 2.0 * float(loop["half_width_m"]),
		loop["half_length_m"], loop["half_width_m"], loop["margin_m"], loop["min_depth_m"], loop["length_m"], (route["points"] as Array).size(), route["length_m"], route["margin_m"], route["min_depth_m"]])
	print("[water-units] patrol loop points %s; supply route points %s" % [loop["points"], route["points"]])
	# --- deterministic: a second build, and the shared one, give the same sites
	var again := WaterGen.new(SEED)
	var other_sites := again.sites()
	eq(JSON.stringify(_sites, "", true, true), JSON.stringify(other_sites, "", true, true), "a second water of the seed gives the same sites")
	eq(JSON.stringify(_sites, "", true, true), JSON.stringify((WaterGen.shared(SEED) as WaterGen).sites(), "", true, true), "and so does the shared one")
	# --- other seeds: whatever sites they have hold to the same rules; a seed with none says why
	var with_loop := 0
	var with_route := 0
	var with_bridge := 0
	for sd: int in OTHER_SEEDS:
		var wg := WaterGen.new(sd)
		if not wg.ok():
			continue
		var s := wg.sites()
		var why: Dictionary = s["why"]
		for key: String in ["bridge", "patrol_loop", "supply_route"]:
			if (s[key] as Dictionary).is_empty():
				check(why.has(key), "seed %d: no %s, and it says why" % [sd, key])
		if not (s["bridge"] as Dictionary).is_empty():
			with_bridge += 1
			eq((s["bridge"]["pos"] as Vector2), wg.river_crossing, "seed %d: the bridge is at the river's crossing" % sd)
		for key: String in ["patrol_loop", "supply_route"]:
			var rec: Dictionary = s[key]
			if rec.is_empty():
				continue
			if key == "patrol_loop":
				with_loop += 1
			else:
				with_route += 1
			var boat := patrol if key == "patrol_loop" else supply
			var ok_water := _probe_with(wg, rec, rec["kind"] == "loop", boat.draught_m, 0.9 * float(rec["margin_m"]))
			eq(int(ok_water["bad"]), 0, "seed %d: every point of the %s is on water deep enough for its boat, clear of the shore" % [sd, key])
			check(float(ok_water["min_depth"]) >= boat.draught_m, "seed %d: %s: shallowest %.1f m" % [sd, key, float(ok_water["min_depth"])])
	print("[water-units] other seeds %s: %d with a bridge, %d with a patrol loop, %d with a supply route" % [OTHER_SEEDS, with_bridge, with_loop, with_route])
	check(with_loop >= 1, "at least one of the other seeds has a patrol loop")

func _probe_with(wg: WaterGen, rec: Dictionary, closed: bool, draught: float, ring_m: float) -> Dictionary:
	var keep := _water
	_water = wg
	var out := _probe(rec, closed, draught, ring_m)
	_water = keep
	return out

# --- 3. the units ---------------------------------------------------------------------------------------------------------

func _units() -> void:
	var w := World.new()
	w.quiet = true
	for id: String in ["patrol_boat", "supply_boat", "bridge"]:
		var def := w.unit_def(id)
		if not check(def != null, "data/units/%s.json loads: %s" % [id, w.last_error]):
			continue
		eq(def.bomb_drops, 0, "%s drops nothing" % id)
		eq(def.bomb_per_drop, 0, "%s: no bombs per drop" % id)
		eq(def.specials, [], "%s has no specials" % id)
	var p := w.unit_def("patrol_boat")
	var s := w.unit_def("supply_boat")
	var b := w.unit_def("bridge")
	eq([p.domain, p.mobility, s.domain, s.mobility, b.domain, b.mobility], ["sea", "mobile", "sea", "mobile", "ground", "static"], "the boats are mobile sea units, the bridge a static ground unit")
	eq(p.size_m, 27.0, "the patrol boat is the P1 Cutter's 27 m (Alex)")
	eq(s.size_m, 34.0, "the supply boat is the S2 barge's 34 m (Alex)")
	check(p.draught_m > 0.0 and s.draught_m > 0.0 and b.draught_m == 0.0, "the boats have a draught, the bridge none (%s, %s m)" % [p.draught_m, s.draught_m])
	check(p.envelope.speed_cruise <= 15.0 and s.envelope.speed_cruise < p.envelope.speed_cruise, "boats are slow, the barge slower than the cutter (%s and %s m/s)" % [p.envelope.speed_cruise, s.envelope.speed_cruise])
	check(p.envelope.turn_radius(p.envelope.speed_cruise) < 120.0 and p.envelope.turn_radius(p.envelope.speed_cruise) > 20.0, "the cutter turns slowly: a radius of %.0f m at cruise" % p.envelope.turn_radius(p.envelope.speed_cruise))
	eq(p.weapons.size(), 1, "the patrol boat has one weapon")
	eq(p.weapons[0].hardpoints.size(), 2, "...on two mounts")
	eq(s.weapons.size(), 0, "the supply boat is unarmed")
	eq(b.weapons.size(), 0, "the bridge has no weapons")
	check(b.health >= 8, "the bridge is at least as tough as the radio tower (%d pips)" % b.health)
	eq(p.actions_per_turn, 2, "the patrol boat plans two points a turn")
	print("[water-units] patrol_boat: %s m, draught %s m, %d pips, cruise %s m/s (max %s), turn radius %.0f m, steps %d; supply_boat: %s m, draught %s m, %d pips, cruise %s m/s; bridge: %s m, %d pips" % [
		p.size_m, p.draught_m, p.health, p.envelope.speed_cruise, p.envelope.speed_max, p.envelope.turn_radius(p.envelope.speed_cruise), p.actions_per_turn,
		s.size_m, s.draught_m, s.health, s.envelope.speed_cruise, b.size_m, b.health])

# --- 4. the water rule --------------------------------------------------------------------------------------------------------

# A straight shore: water 8 m deep east of x = 1000, land west of it.
static func _shore(x: float, _y: float) -> float:
	return 8.0 if x > 1000.0 else 0.0

func _shore_world(with_water: bool = true) -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	if with_water:
		w.set_water(Callable(self, "_shore"))
	return w

func _boat(w: World, x: float, heading: float, speed: float, type_id: String = "patrol_boat") -> String:
	return w.add_unit({"id": "boat", "type": type_id, "side": "allies", "controller": "player", "x": x, "y": 2500.0, "heading": heading, "speed": speed})

func _rule() -> void:
	# a sea unit is not put on land, nor where its hull would hang over it; a plane is put anywhere
	var w := _shore_world()
	eq(_boat(w, 900.0, PI, 0.0), "", "a patrol boat is not put on land")
	check(w.last_error.contains("float"), "...and the refusal says it would not float: %s" % w.last_error)
	eq(_boat(w, 1010.0, 0.0, 0.0), "", "nor with its stern over the shore (the hull's ends are asked too)")
	eq(_boat(w, 1030.0, 0.0, 0.0), "boat", "but with its stern 3.5 m of water out it is")
	check(w.unit_afloat("boat"), "...and it is afloat")
	# a plan that would leave the water is slowed ...
	w = _shore_world()
	_boat(w, 1035.0, PI, 10.0)
	var st := w.plan_step("boat", 0, {"speed": 10.0})
	check(bool(st["clamped"]) and (st["limits"] as Array).has(Envelope.LIMIT_SHORE), "a step onto the beach is clamped with the limit 'shore': %s" % [st["limits"]])
	check(float(st["speed"]) < 10.0 and float(st["speed"]) > 0.0, "...slowed (%.2f m/s), not held" % float(st["speed"]))
	check(w.afloat_at(float(st["x"]), float(st["y"]), float(st["heading"]), "boat"), "...and it ends afloat (x %.1f)" % float(st["x"]))
	# ... and held when even the slowest leaves it
	w = _shore_world()
	_boat(w, 1020.0, PI, 10.0)
	st = w.plan_step("boat", 0, {"speed": 10.0})
	check(bool(st["clamped"]) and (st["limits"] as Array).has(Envelope.LIMIT_SHORE), "closer in, the step is still clamped")
	eq([st["x"], st["y"], st["speed"]], [1020.0, 2500.0, 0.0], "...held where it is, speed 0")
	var again := w.planned_states("boat")
	check(again.all(func(s: Dictionary) -> bool: return w.afloat_at(float(s["x"]), float(s["y"]), float(s["heading"]), "boat")), "the whole plan stays afloat, step after step")
	# a boat that carries on (no plan) comes to rest short of the shore, afloat at every turn's end
	w = _shore_world()
	_boat(w, 1400.0, PI, 10.0)
	var limited := 0
	var afloat_all := true
	for turn_no in 14:
		var res := _turn(w)
		for state: Dictionary in (res["histories"]["boat"] as Array):
			if (state.get("limits", []) as Array).has(Envelope.LIMIT_SHORE):
				limited += 1
		afloat_all = afloat_all and w.unit_afloat("boat")
	check(afloat_all, "left to carry on toward the shore, the boat is afloat at the end of every turn")
	check(limited >= 1, "...the rule clamped it (%d steps with the limit)" % limited)
	var u: Unit = w.units["boat"]
	check(u.speed == 0.0 and u.x > 1000.0 + 13.5 and u.x < 1150.0, "...and it lay to short of the shore at x = %.1f" % u.x)
	# it can back away
	w.begin_turn()
	st = w.plan_step("boat", 0, {"speed": -2.0})
	check(not bool(st["clamped"]) and float(st["x"]) > u.x, "it backs away from the beach (x %.1f to %.1f)" % [u.x, float(st["x"])])
	# determinism: the same plan twice, the same states
	var w2 := _shore_world()
	_boat(w2, 1400.0, PI, 10.0)
	for turn_no in 14:
		_turn(w2)
	eq([(w2.units["boat"] as Unit).x, (w2.units["boat"] as Unit).y, (w2.units["boat"] as Unit).speed], [u.x, u.y, u.speed], "the same world plays out the same")
	# a plane ignores the water; with no water a boat is not clamped either
	w = _shore_world()
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1020.0, "y": 2000.0, "heading": PI, "speed": 100.0})
	st = w.plan_step("fighter", 0, {"speed": 100.0})
	check(not (st["limits"] as Array).has(Envelope.LIMIT_SHORE) and float(st["x"]) < 1000.0, "a plane flies over the shore: the rule is for sea units")
	w = _shore_world(false)
	check(not w.has_water(), "a World with no water says so")
	eq(_boat(w, 900.0, PI, 10.0), "boat", "with no water a boat can be put anywhere (the sim stays testable on its own)")
	st = w.plan_step("boat", 0, {"speed": 10.0})
	check(not (st["limits"] as Array).has(Envelope.LIMIT_SHORE) and float(st["x"]) < 900.0, "...and is never clamped")
	print("[water-units] the water rule: a step that leaves the water is slowed, then held (limit 'shore'); the boat that carried on stopped at x = %.1f of a shore at 1000 after %d clamped steps" % [u.x, limited])

# --- 5. the AI sails ---------------------------------------------------------------------------------------------------------

# A World on the REAL water with one boat on its site's route; returns {world, ai, id}.
func _sail_world(type_id: String, site_key: String, mode: String) -> Dictionary:
	var rec: Dictionary = _sites[site_key]
	var w := World.new()
	w.quiet = true
	w.set_water(Callable(_water, "depth_at"))
	w.add_player("local")
	var pts: Array = rec["points"]
	var id := w.add_unit({"id": "boat", "type": type_id, "side": "axis", "controller": "ai", "x": (pts[0] as Vector2).x, "y": (pts[0] as Vector2).y, "heading": float((rec["headings"] as Array)[0])})
	var route: Array = []
	for p: Vector2 in pts:
		route.append([p.x, p.y])
	var ai := AiPilot.new("res://data/sim/ai.json", true)
	check(ai.attach(w, {"boat": {"role": "sail", "mode": mode, "route": route}}), "the pilot takes the %s's sail orders: %s" % [type_id, ai.errors])
	return {"world": w, "ai": ai, "id": id, "route": route}

func _sailing() -> void:
	# the patrol boat: a lap of its loop (30 turns)
	var g := _sail_world("patrol_boat", "patrol_loop", "loop")
	var w: World = g["world"]
	var ai: AiPilot = g["ai"]
	var route: Array = g["route"]
	var u: Unit = w.units["boat"]
	var visited: Dictionary = {}
	var clamped := 0
	var aground := 0
	var far := 0.0
	var path_m := 0.0
	var last := Vector2(u.x, u.y)
	for turn_no in 30:
		var res := _turn(w)
		visited[int(ai.info("boat")["wp"])] = true
		for state: Dictionary in (res["histories"]["boat"] as Array):
			if (state.get("limits", []) as Array).has(Envelope.LIMIT_SHORE):
				clamped += 1
			if not w.afloat_at(float(state["x"]), float(state["y"]), float(state["heading"]), "boat"):
				aground += 1
			far = maxf(far, _distance_to_polyline(Vector2(float(state["x"]), float(state["y"])), route.map(func(p: Array) -> Vector2: return Vector2(p[0], p[1])), true))
		path_m += last.distance_to(Vector2(u.x, u.y))
		last = Vector2(u.x, u.y)
	eq(aground, 0, "the patrol boat never touched land in a lap of its loop (30 turns, every 2.5 s step)")
	eq(clamped, 0, "...and the World never had to clamp it: the AI never plans onto land")
	check(far < 100.0, "...it kept to its loop (never more than %.0f m off it)" % far)
	eq(visited.size(), 4, "...and it came to all four corners (%s)" % [visited.keys()])
	check(path_m > 30.0 * 5.0 * 8.0, "...at about its cruise speed (%.0f m in 30 turns of 5 s)" % path_m)
	print("[water-units] the patrol boat sailed %.0f m of its loop in 30 turns, never more than %.0f m off it, no clamped step, visited %s" % [path_m, far, visited.keys()])
	# the supply boat: its route out and back (the far end 1,700 m off at 5 m/s: 190 turns cover both ways and the turns)
	g = _sail_world("supply_boat", "supply_route", "shuttle")
	w = g["world"]
	ai = g["ai"]
	route = g["route"]
	var poly: Array = route.map(func(p: Array) -> Vector2: return Vector2(p[0], p[1]))
	u = w.units["boat"]
	var far_end: Vector2 = poly[poly.size() - 1]
	var first: Vector2 = poly[0]
	var best_far := INF
	var back_home := INF
	var flips := 0
	var dir := 1
	aground = 0
	clamped = 0
	far = 0.0
	for turn_no in 190:
		var res := _turn(w)
		for state: Dictionary in (res["histories"]["boat"] as Array):
			if (state.get("limits", []) as Array).has(Envelope.LIMIT_SHORE):
				clamped += 1
		if not w.unit_afloat("boat"):
			aground += 1
		var at := Vector2(u.x, u.y)
		far = maxf(far, _distance_to_polyline(at, poly, false))
		best_far = minf(best_far, at.distance_to(far_end))
		if flips >= 1:
			back_home = minf(back_home, at.distance_to(first))
		var d := int(ai.info("boat")["dir"])
		if d != dir:
			flips += 1
			dir = d
	eq(aground, 0, "the supply boat was afloat at the end of every one of 190 turns")
	eq(clamped, 0, "...and never needed the clamp")
	check(far < float(_sites["supply_route"]["margin_m"]), "...it kept to its route (never more than %.0f m off it: its margin from the shore is %.0f m, and a turn back swings it 114 m wide)" % [far, float(_sites["supply_route"]["margin_m"])])
	check(best_far < 100.0, "...it reached the far end of its route (%.0f m from it at the nearest)" % best_far)
	check(flips >= 2, "...turned round there, went back (%d turnings of the shuttle) ..." % flips)
	check(back_home < 150.0, "...and came home (%.0f m from the start at the nearest on the way back)" % back_home)
	print("[water-units] the supply boat reached %.0f m from the far end of its route, and was %.0f m from its first point on the way back (%d turnings); never more than %.0f m off the route" % [best_far, back_home, flips, far])
	# the boat put at the shore backs away: 45 m off the beach, bow to it
	var loop: Dictionary = _sites["patrol_loop"]
	var c: Vector2 = (loop["points"] as Array)[0]
	var x := c.x
	while _water.depth_at(x, c.y) >= 3.0 and x > 0.0:
		x -= 10.0
	var shore_at := x
	var w3 := World.new()
	w3.quiet = true
	w3.set_water(Callable(_water, "depth_at"))
	w3.add_player("local")
	var id := w3.add_unit({"id": "boat2", "type": "patrol_boat", "side": "axis", "controller": "ai", "x": shore_at + 70.0, "y": c.y, "heading": PI, "speed": 8.0})
	check(id == "boat2", "a boat can be put 70 m off the beach: %s" % w3.last_error)
	var ai3 := AiPilot.new("res://data/sim/ai.json", true)
	var loop_route: Array = []
	for p: Vector2 in loop["points"]:
		loop_route.append([p.x, p.y])
	check(ai3.attach(w3, {"boat2": {"role": "sail", "mode": "loop", "route": loop_route}}), "the pilot takes its orders: %s" % [ai3.errors])
	aground = 0
	var escaped := 0
	clamped = 0
	for turn_no in 40:
		var res := _turn(w3)
		for state: Dictionary in (res["histories"]["boat2"] as Array):
			if (state.get("limits", []) as Array).has(Envelope.LIMIT_SHORE):
				clamped += 1
		if not w3.unit_afloat("boat2"):
			aground += 1
		if bool(ai3.info("boat2").get("escaped", false)):
			escaped += 1
	eq(aground, 0, "a boat driven at the beach is afloat at the end of every one of 40 turns")
	var u3: Unit = w3.units["boat2"]
	check(Vector2(u3.x, u3.y).distance_to((loop["centre"] as Vector2)) < 700.0, "...and it got back to its loop (%.0f m from its middle)" % Vector2(u3.x, u3.y).distance_to((loop["centre"] as Vector2)))
	print("[water-units] a boat put 70 m off the beach heading at it: %d clamped steps, %d turns escaping, afloat at every turn's end, %.0f m from the loop's middle at the 40th" % [clamped, escaped, Vector2(u3.x, u3.y).distance_to((loop["centre"] as Vector2))])
	# the AI's orders are checked: a plane cannot sail, a sail needs a route and a mode
	var w4 := World.new()
	w4.quiet = true
	w4.add_unit({"id": "boat", "type": "patrol_boat", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	w4.add_unit({"id": "plane", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 2000.0, "y": 2000.0, "heading": 0.0})
	var ai4 := AiPilot.new("res://data/sim/ai.json", true)
	check(ai4.attach(w4, {}), "an empty attach")
	var cases: Array = [
		["a plane given a sail", "plane", {"role": "sail", "mode": "loop", "route": [[1.0, 1.0], [2.0, 2.0]]}],
		["a sail with no route", "boat", {"role": "sail", "mode": "loop"}],
		["a sail with one point", "boat", {"role": "sail", "mode": "loop", "route": [[1.0, 1.0]]}],
		["a sail with no mode", "boat", {"role": "sail", "route": [[1.0, 1.0], [2.0, 2.0]]}],
		["a sail with a mode nobody knows", "boat", {"role": "sail", "mode": "orbit", "route": [[1.0, 1.0], [2.0, 2.0]]}],
		["a sail whose route is not points", "boat", {"role": "sail", "mode": "loop", "route": [[1.0], [2.0]]}],
	]
	for cs: Array in cases:
		check(not ai4.assign(str(cs[1]), cs[2]), "%s is refused" % cs[0])
	check(ai4.assign("boat", {"role": "sail", "mode": "shuttle", "route": [[2400.0, 2500.0], [2800.0, 2500.0]]}), "a shuttle of two points is accepted")

# --- 6. the guns --------------------------------------------------------------------------------------------------------------

# A patrol boat (axis) at (2500, 2500) and a light fighter (allies) crossing 60 m north of it, in `band`, from the west.
func _gun_world(seed_value: int, band: String, boat_type: String = "patrol_boat") -> World:
	var w := World.new()
	w.quiet = true
	w.rng_seed = seed_value
	w.add_player("local")
	w.add_unit({"id": "boat", "type": boat_type, "side": "axis", "controller": "player", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": "player", "x": 2250.0, "y": 2440.0, "heading": 0.0, "speed": 100.0, "altitude_band": band})
	return w

func _guns() -> void:
	var fired := 0
	var mounts: Dictionary = {}
	var hits := 0
	var hit_seed := -1
	for sd in range(1, 31):
		var w := _gun_world(sd, "low")
		var res := _turn(w)
		for ev: Dictionary in res["events"]:
			if ev["type"] == "fire" and ev["unit"] == "boat":
				fired += 1
				mounts[int(ev["hardpoint"])] = true
				eq(ev["weapon"], "aa_guns", "the boat's guns are its aa_guns")
				eq(ev["target"], "fighter", "...and they fire at the plane")
			if ev["type"] == "hit" and ev["by"] == "boat":
				hits += 1
				if hit_seed < 0:
					hit_seed = sd
	check(fired > 0, "the patrol boat's guns fire at a plane crossing in the low band (%d shots over 30 seeds)" % fired)
	eq(mounts.keys().size(), 2, "...from both mounts (%s)" % [mounts.keys()])
	check(hits > 0, "...and they can hurt it (%d hits over 30 seeds; the first on seed %d)" % [hits, hit_seed])
	var medium := 0
	for sd in range(1, 11):
		var w := _gun_world(sd, "medium")
		var res := _turn(w)
		for ev: Dictionary in res["events"]:
			if ev["type"] == "fire" and ev["unit"] == "boat":
				medium += 1
	eq(medium, 0, "the boat's light guns do not reach a plane in the medium band (the battery's light flak does not either)")
	var barge := 0
	for sd in range(1, 11):
		var w := _gun_world(sd, "low", "supply_boat")
		var res := _turn(w)
		for ev: Dictionary in res["events"]:
			if ev["type"] == "fire" and ev["unit"] == "boat":
				barge += 1
	eq(barge, 0, "the supply boat is unarmed: it never fires")
	print("[water-units] the patrol boat fired %d shots at a low plane over 30 seeds (%d hits), none at medium; the barge none" % [fired, hits])

# --- 7. the bridge -----------------------------------------------------------------------------------------------------------

# A bridge at the water's site, a bomber far to the west (allies).
func _bridge_world(seed_value: int) -> World:
	var site: Dictionary = _sites["bridge"]
	var w := World.new()
	w.quiet = true
	w.rng_seed = seed_value
	w.add_player("local")
	var at: Vector2 = site["pos"]
	w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": at.x - 2500.0, "y": at.y, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
	w.add_unit({"id": BRIDGE, "type": "bridge", "side": "axis", "controller": "ai", "x": at.x, "y": at.y, "heading": float(site["heading"])})
	return w

func _bridge() -> void:
	var site: Dictionary = _sites["bridge"]
	var at: Vector2 = site["pos"]
	var w := _bridge_world(1)
	var br: Unit = w.units[BRIDGE]
	eq([br.health, br.down, br.fate], [10, false, ""], "the bridge stands with its 10 pips")
	check(not w.units[BRIDGE].def.carries_bombs() and w.units[BRIDGE].def.is_static(), "a static unit")
	# bombs landed on it: three direct hits are 9 pips and leave it standing
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, at.x, at.y, 1.0, 0), BombWorlds.record(w, at.x, at.y, 2.0, 1), BombWorlds.record(w, at.x, at.y, 3.0, 2)])
	var res := _turn(w)
	eq([br.health, br.down], [1, false], "three direct bombs (3 pips each) leave the bridge with 1 pip")
	# the fourth brings it down, in the next turn
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, at.x + 5.0, at.y, 1.0, 3)])
	res = _turn(w)
	check(br.down and br.health == 0, "a fourth bomb brings the bridge down")
	eq(br.fate, Unit.FATE_DESTROYED, "...its fate is 'destroyed', as the tower's")
	var downs: Array = (res["events"] as Array).filter(func(ev: Dictionary) -> bool: return ev["type"] == "down" and ev["unit"] == BRIDGE)
	eq(downs.size(), 1, "...exactly one 'down' event")
	eq(str(downs[0]["fate"]) if downs.size() > 0 else "", "destroyed", "...saying 'destroyed'")
	check(w.units.has(BRIDGE), "it stays in World.units (the dice are seeded by index: nothing is ever deleted)")
	_turn(w)
	check(w.units.has(BRIDGE) and (w.units[BRIDGE] as Unit).down, "...and stays down")
	# a bomber's run on it: some dice seed in 1..40 brings it down within eight turns
	var won_seed := -1
	var won_turn := 0
	var sticks := 0
	var control_down := false
	for sd in range(1, 41):
		var rw := _bridge_world(sd)
		var steer := AiSteer.new(rw, 1.5)
		for turn_no in 8:
			if rw.phase == World.PHASE_RESOLVED:
				rw.begin_turn()
			var target: Unit = rw.units[BRIDGE]
			var bomber: Unit = rw.units["bomber"]
			var tp := Vector2(target.x, target.y)
			steer.fly(bomber.id, func(_i: int, _at: Dictionary, _t: float) -> Dictionary:
				return {"aim": func(s: Dictionary) -> float: return JsMath.atan2(tp.y - float(s["y"]), tp.x - float(s["x"])), "speed": 85.0})
			var planned := 0
			for k in rw.steps_per_turn(bomber.id):
				if planned >= bomber.drops_left or bomber.plan.size() <= k:
					break
				var info := rw.drop_spread(bomber.id, k, tp)
				if info.is_empty() or bool(info["clamped"]) or float(info["r"]) > 0.5:
					continue
				var req: Dictionary = (bomber.plan[k] as Dictionary).duplicate(true)
				req["drop"] = {"aim": [tp.x, tp.y], "target": {"unit": BRIDGE}}
				if not rw.plan_step(bomber.id, k, req).is_empty():
					planned += 1
			sticks += planned
			rw.commit("local")
			rw.resolve()
			if target.down:
				break
		if (rw.units[BRIDGE] as Unit).down:
			won_seed = sd
			won_turn = rw.turn
			break
	check(won_seed > 0, "a bomber's run brings the bridge down on some dice seed of 1..40 (seed %d, turn %d, %d drops planned)" % [won_seed, won_turn, sticks])
	# nothing falls on it, nothing happens to it
	var quiet := _bridge_world(1)
	for turn_no in 6:
		_turn(quiet)
	control_down = (quiet.units[BRIDGE] as Unit).down
	check(not control_down, "a bridge nobody bombs stands (the control)")
	print("[water-units] the bridge: 3 direct bombs leave 1 pip, the 4th destroys it; a bomber's run destroyed it on dice seed %d at turn %d" % [won_seed, won_turn])

# --- 8. the Strike -----------------------------------------------------------------------------------------------------------

# A snapshot of a World's units for comparing two runs: id -> [x, y, heading, speed, health, down], rounded.
static func _snapshot(w: World) -> Dictionary:
	var out := {}
	for id: String in w.units:
		var u: Unit = w.units[id]
		out[id] = [snappedf(u.x, 0.0001), snappedf(u.y, 0.0001), snappedf(u.heading, 0.000001), snappedf(u.speed, 0.0001), u.health, u.down]
	return out

# A World of the scenario, played with idle players (the AI and the mission attached the way the sandbox does it).
func _play_strike(sc: SandboxScenario, turns: int) -> Dictionary:
	var w := World.new()
	w.quiet = true
	sc.populate(w)
	var ai := sc.make_ai(w)
	check(sc.ai_attach(ai, w), "the scenario's AI attaches: %s" % [ai.get("errors")])
	var mission := sc.make_mission(w)
	mission.attach()
	var afloat := true
	var clamped := 0
	for t in turns:
		if mission.state != Mission.PLAYING:
			break
		var res := _turn(w)
		if res.is_empty():
			fail("turn %d did not resolve: %s" % [w.turn, w.last_error])
			break
		for id: String in w.units:
			var u: Unit = w.units[id]
			if u.def.domain == "sea":
				afloat = afloat and w.unit_afloat(id)
				for state: Dictionary in (res["histories"][id] as Array):
					if (state.get("limits", []) as Array).has(Envelope.LIMIT_SHORE):
						clamped += 1
	return {"world": w, "ai": ai, "mission": mission, "afloat": afloat, "clamped": clamped}

func _strike_off() -> void:
	var file: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenarios/strike.json"))
	eq((file as Dictionary).get("water"), false, "data/scenarios/strike.json ships with \"water\": false (the drawing track turns it on)")
	check((file as Dictionary).has("water_units") and (file as Dictionary).has("water_assignments"), "...with the water units and their orders ready beside it")
	var sc := SandboxScenario.new("strike")
	check(sc.ok(), "the Strike reads: %s" % [sc.errors])
	eq(sc.water_on, false, "water is off")
	eq(sc.units.size(), 7, "the Strike has its seven units, no more")
	eq(sc.ai_assignments.keys(), ["patrol_1"] as Array, "...and the patrol fighter is the only unit with orders")
	check(sc.water() == null, "nothing of the water is loaded")
	var w := World.new()
	w.quiet = true
	sc.populate(w)
	check(not w.has_water(), "the World is given no water")
	for id: String in w.units:
		check(not (id.begins_with("bridge") or id.begins_with("patrol_boat") or id.begins_with("supply_boat")), "no water unit in the Strike (%s)" % id)
	# whatever water keys the file carries, it plays out as the same game with them stripped
	var stripped := SandboxScenario.new("strike", true, {"water": false, "water_units": [], "water_assignments": {}})
	check(stripped.ok(), "the Strike with its water keys emptied reads: %s" % [stripped.errors])
	var a := _play_strike(sc, 10)
	var b := _play_strike(stripped, 10)
	eq(_snapshot(a["world"]), _snapshot(b["world"]), "with water off the Strike plays out exactly as with the water keys emptied (10 turns)")
	eq((a["mission"] as Mission).state, (b["mission"] as Mission).state, "...to the same verdict")
	# a water site named with the switch off is an error, not a silent default
	var bad := SandboxScenario.new("strike", true, {"units": [{"id": "x", "type": "bridge", "side": "side_b", "controller": "ai", "site": "water.bridge", "heading": 0.0}]})
	check(not bad.ok(), "a unit on a water site with the switch off is refused: %s" % [bad.errors])

func _strike_on() -> void:
	var off := SandboxScenario.new("strike")
	var sc := SandboxScenario.new("strike", true, {"water": true})
	if not check(sc.ok(), "the Strike with water on reads: %s" % [sc.errors]):
		return
	eq(sc.water_on, true, "water is on")
	eq(sc.units.size(), 10, "ten units: the seven and the bridge, the patrol boat and the supply boat")
	var by_id: Dictionary = {}
	for spec: Dictionary in sc.units:
		by_id[str(spec["id"])] = spec
	for id in [BRIDGE, PATROL, SUPPLY]:
		check(by_id.has(id), "%s is there" % id)
		if by_id.has(id):
			eq([by_id[id]["side"], by_id[id]["controller"]], ["axis", "ai"], "%s is on the defending side, the AI's" % id)
	# the sites: on the bridge, the loop's first corner, the route's first end, with their headings
	var bridge: Dictionary = _sites["bridge"]
	var loop: Dictionary = _sites["patrol_loop"]
	var route: Dictionary = _sites["supply_route"]
	eq(Vector2(float(by_id[BRIDGE]["x"]), float(by_id[BRIDGE]["y"])), bridge["pos"] as Vector2, "the bridge stands at the water's bridge site")
	near(float(by_id[BRIDGE]["heading"]), float(bridge["heading"]), 1e-9, "...with the road's heading")
	eq(Vector2(float(by_id[PATROL]["x"]), float(by_id[PATROL]["y"])), (loop["points"] as Array)[0] as Vector2, "the patrol boat starts at the first corner of its loop")
	near(float(by_id[PATROL]["heading"]), float((loop["headings"] as Array)[0]), 1e-9, "...heading for the next")
	eq(Vector2(float(by_id[SUPPLY]["x"]), float(by_id[SUPPLY]["y"])), (route["points"] as Array)[0] as Vector2, "the supply boat starts at the first end of its route")
	# the AI: the pilot, with the boats sailing, the fighter still on patrol
	eq(sc.ai_kind, SandboxScenario.AI_PILOT, "the pilot AI")
	eq(sc.ai_assignments.keys().size(), 3, "three units with orders: the patrol fighter and the two boats")
	eq([sc.ai_assignments[PATROL]["role"], sc.ai_assignments[PATROL]["mode"], sc.ai_assignments[SUPPLY]["role"], sc.ai_assignments[SUPPLY]["mode"]], ["sail", "loop", "sail", "shuttle"], "the patrol boat sails its loop, the barge shuttles")
	eq((sc.ai_assignments[PATROL]["route"] as Array).size(), 4, "the patrol boat's route is the whole loop")
	eq((sc.ai_assignments[SUPPLY]["route"] as Array).size(), (route["points"] as Array).size(), "the barge's route is the whole supply route")
	eq(sc.ai_assignments["patrol_1"]["role"], "patrol", "the patrol fighter flies its loop round the tower as before")
	# THE MISSION IS UNCHANGED, and judges the tower and the bomber only
	eq(sc.mission_spec, off.mission_spec, "the mission is the same as with water off")
	var judged: Dictionary = {}
	var stack: Array = [sc.mission_spec]
	while not stack.is_empty():
		var node: Variant = stack.pop_back()
		if node is Dictionary:
			for k: Variant in (node as Dictionary):
				if str(k) == "unit":
					judged[str((node as Dictionary)[k])] = true
				stack.append((node as Dictionary)[k])
		elif node is Array:
			stack.append_array(node as Array)
	eq(judged.keys().size(), 2, "the mission names two units")
	check(judged.has(TOWER) and judged.has(BOMBER), "...the radio tower and the bomber (%s)" % [judged.keys()])
	eq(sc.objective()["unit"], TOWER, "the target ring is still round the tower")
	# a world of it: given the water, the boats afloat
	var w := World.new()
	w.quiet = true
	var ids := sc.populate(w)
	check(not ids.has(""), "every unit of the Strike with water loads: %s" % w.last_error)
	check(w.has_water(), "the World is given the water")
	for id in [PATROL, SUPPLY]:
		check(w.unit_afloat(id), "%s is afloat where the scenario puts it" % id)
	eq(w.units[BRIDGE].def.is_static(), true, "the bridge is a static unit")
	# knocking out every water unit changes nothing in the verdict; the tower decides
	var mission := sc.make_mission(w)
	mission.attach()
	for id in [BRIDGE, PATROL, SUPPLY]:
		var u: Unit = w.units[id]
		u.health = 0
		u.down = true
		u.fate = Unit.FATE_DESTROYED
	eq(mission.evaluate({"turn": 1})["state"], Mission.PLAYING, "with the bridge and both boats down the game is still being played")
	var tower: Unit = w.units[TOWER]
	tower.health = 0
	tower.down = true
	tower.fate = Unit.FATE_DESTROYED
	eq(mission.evaluate({"turn": 1})["state"], Mission.WON, "...and the tower's falling wins it")
	# played to the end with idle players: the boats afloat all the time, the game lost at the turn limit
	var played := _play_strike(sc, 25)
	check(played["afloat"] == true, "played to the end the boats were afloat at every turn's end")
	eq(played["clamped"], 0, "...and the World never had to clamp one")
	var m: Mission = played["mission"]
	eq(m.state, Mission.LOST, "doing nothing loses the Strike with water on, as with it off (%s)" % m.reason)
	var wp: World = played["world"]
	for id in [PATROL, SUPPLY]:
		var u: Unit = wp.units[id]
		check(Vector2(u.x, u.y).distance_to(Vector2(float(by_id[id]["x"]), float(by_id[id]["y"]))) > 20.0, "%s had sailed (now at (%.0f, %.0f))" % [id, u.x, u.y])
	print("[water-units] the Strike with water on: %d units; played %d turns idle: %s" % [sc.units.size(), (played["world"] as World).turn, m.reason])
