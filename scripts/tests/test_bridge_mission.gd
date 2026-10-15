extends "res://scripts/test_support/test_case.gd"

# HOLD THE BRIDGE (Track BM, 2026-10-11; proposed -- Alex's mission idea and his go-ahead are decisions mixed-warfare and bridge-mission, the rest is
# the lead's plan and this track's numbers, every one a PROPOSED record in data/scenarios/bridge.json). The first MIXED mission: two player tanks at a
# river bridge, the player's cruiser offshore at the far end of its gun range, the tanks the only spotters for the cruiser's Main Guns Fire, and
# waves of enemy tanks driving down the road on the AI's drive role. "Capture and hold a bridge, but you are at the far end of ship range so your
# shots need to be really on point to hit" (Alex). Headless, in the sandbox itself where it matters; pixels are scripts/app/bridge_shot.gd's.
#
#   1. THE SEED          scripts/test_support/bridge_seed_search.gd is the scenario's justification, re-run on its seed: a road bridge, a sea the cruiser
#                        can sail in no nearer than 2.3 km, a station in reach of the road from the bridge to 300 m beyond it (the river is the water
#                        the coastal strip's rule wants); the Strike's own seed does not fit
#   2. THE SCENARIO      stands up: 10 units where the data says (tanks on the road on the player's side, the cruiser afloat 2.4 to 3 km off, the waves
#                        300 to 415 m out on the far side, the bridge the player's), the drive orders with their start turns, the mission, the ring
#   3. THE CONDITIONS    mission.gd's two new types, turn_reached (a win at a turn) and side_past (a loss when a unit of a side gets past a line), and
#                        the scenario's sites for them (road_m, road_to_site, point_site); synthetic worlds
#   4. THE WAVES         wait, then drive: a wave does not move before its start turn and drives at its start turn; the first crosses at about turn 9
#   5. THE SPOTTING      the cruiser cannot see its targets (1,000 m of sight against 2.7 km): without the tanks it cannot fire at the waves; with them
#                        it can, at the far end of its reach and no farther
#   6. A DEFENCE WINS    a scripted defence (the cruiser fires at what the tanks spot, and creeps nearer; the tanks hold) wins on a dice seed found at
#                        test time, with the bridge standing and no enemy across; the win rate over a batch is printed
#   7. DOING NOTHING LOSES  the waves cross, on every seed
#   8. THE OTHER ENDS    the bridge down is a loss (and the cruiser's own shells can do it), both tanks down is a loss, each in the card's words
#   9. A LATE JOINER     the snapshot carries the shells in the air and the sides' memory of what they spotted
#  10. LOCAL, THROUGH THE MENU   the selector lists the mission in words; Local starts it
#  11. OVER THE NET      a host and a client, each a complete sandbox, played to the end: the same result, the same World; a late player joins in the middle
#
# Port 28786 (CLAUDE.md: one port per networked test).

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const Guns = preload("res://scripts/sim/guns.gd")
const Sandbox = preload("res://scripts/app/sandbox.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const BridgePlay = preload("res://scripts/test_support/bridge_play.gd")
const BridgeSeedSearch = preload("res://scripts/test_support/bridge_seed_search.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const ResultCard = preload("res://scripts/ui/result_card.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const PORT := 28786
const SEEDS := 60            # how many dice seeds the scripted defence may try before the test calls the mission unwinnable
const BATCH := 16            # the batch the win rate is measured on
const BRIDGE_IDX := 4        # the scenario knob's index of "bridge"
const TANK1 := "tank_1"
const TANK2 := "tank_2"
const SHIP := "cruiser_1"
const BRIDGE := "bridge_1"
const WAVE1: Array[String] = ["tank_e1", "tank_e2"]
const WAVE2: Array[String] = ["tank_e3"]
const WAVE3: Array[String] = ["tank_e4"]
const RELIEF := 26

var _main: Node = null
var _saved_scenario := 0
var _saved_speed := 0
var rig: NetRig = null
var _won_seed := -1
var _won_turn := 0
var _won_salvos := 0
var _sections := 0

func setup(main) -> void:
	timeout_seconds = 600.0
	_main = main
	_saved_scenario = DebugSettings.get_choice("scenario")
	_saved_speed = DebugSettings.get_choice("playback_speed")
	DebugSettings.set_choice("scenario", BRIDGE_IDX)
	DebugSettings.set_choice("playback_speed", 4)
	main.get_window().size = Vector2i(1280, 720)
	for part: Script in [NetRig, WorldSync, World, Mission, AiPilot, Guns, Sandbox, SandboxScenario, BridgePlay, BridgeSeedSearch, GroundMap, WaterGen, ResultCard]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	check(DebugSettings.get_choice_name("scenario") == "bridge", "the scenario knob has 'bridge' at index %d" % BRIDGE_IDX)
	_seed()
	_scenario()
	_conditions()
	_waves()
	_spotting()
	_defence_wins()
	_idle_loses()
	_other_ends()
	_late_joiner()
	var local_ok: Variant = await _local()
	check(local_ok == true, "the local part ran to its last line (a runtime error would have ended it silently)")
	rig = NetRig.new()
	add_child(rig)
	var net_ok: Variant = await _net()
	check(net_ok == true, "the network part ran to its last line (a runtime error would have ended it silently)")
	eq(_sections, 9, "the pure-simulation sections all ran to their last line")
	DebugSettings.set_choice("scenario", _saved_scenario)
	DebugSettings.set_choice("playback_speed", _saved_speed)
	finish()

# --- helpers ---------------------------------------------------------------------------------------------

func _down(u: Unit, at: float) -> void:
	u.health = 0
	u.down = true
	u.down_at = at
	u.fate = Unit.FATE_EXPLODED if u.def.domain == "air" else Unit.FATE_DESTROYED

func _until(cond: Callable, max_frames: int = 3000) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()

func _pos(w: World, id: String) -> Vector2:
	return Vector2((w.units[id] as Unit).x, (w.units[id] as Unit).y)

# A scenario's World with the AI and the mission attached, no scripted play: {play: BridgePlay}.
func _game(rng_seed: int = 7) -> BridgePlay:
	var g := BridgePlay.new(rng_seed)
	if not g.ok():
		fail("the game did not stand up: %s" % str(g.errors))
	return g

# --- 1. The seed -------------------------------------------------------------------------------------------

func _seed() -> void:
	var sc := SandboxScenario.new("bridge", true)
	if not check(sc.ok(), "1. the scenario reads: %s" % str(sc.errors)):
		return
	var r := BridgeSeedSearch.evaluate(int(sc.seed_value))
	check(bool(r["ok"]), "1. seed %d has a river across the road: %s" % [int(sc.seed_value), str(r["why"])])
	check(bool(r["fits"]), "1. and the search says it fits the mission: %s" % BridgeSeedSearch.report(r))
	check(float(r["d_min"]) >= BridgeSeedSearch.D_MIN_LO_M and float(r["d_min"]) <= BridgeSeedSearch.D_MIN_HI_M, "1. the ship can come no nearer the bridge than %.0f m (the far end of its 3,000 m: %.0f to %.0f)" % [float(r["d_min"]), BridgeSeedSearch.D_MIN_LO_M, BridgeSeedSearch.D_MIN_HI_M])
	check(int(r["nav_cells"]) >= BridgeSeedSearch.MIN_SEA_CELLS, "1. in a sea of %d cells of %.0f m" % [int(r["nav_cells"]), BridgeSeedSearch.CELL_M])
	check(float(r["station_d"]) >= 2300.0 and float(r["station_d"]) <= 3000.0, "1. its station is %.0f m from the bridge" % float(r["station_d"]))
	eq(int(r["station_missing"]), 0, "1. from it every spot of the road from the bridge to 300 m beyond is in the guns' reach, the coastal strip's rule included")
	# the scenario's cruiser is that station's neighbour: afloat, in the band, in reach
	var cruiser: Dictionary = {}
	for spec: Dictionary in sc.units:
		if str(spec["id"]) == SHIP:
			cruiser = spec
	var bridge := Vector2(float(r["bridge"].x), float(r["bridge"].y))
	var at := Vector2(float(cruiser["x"]), float(cruiser["y"]))
	check(at.distance_to(bridge) >= 2300.0 and at.distance_to(bridge) <= 3000.0, "1. the scenario's cruiser stands %.0f m from the bridge" % at.distance_to(bridge))
	check(at.distance_to(r["station"]) < 1.0, "1. at the station the search found")
	# the Strike's own seed does not (the ship could sail to within 1.6 km of its bridge: the shallows would not keep it out)
	var strike := BridgeSeedSearch.evaluate(20261009)
	check(not bool(strike["fits"]), "1. the Strike's seed does not fit (%s)" % BridgeSeedSearch.report(strike).substr(0, 140))
	_sections += 1

# --- 2. The scenario ---------------------------------------------------------------------------------------

func _scenario() -> void:
	var sc := SandboxScenario.new("bridge", true)
	if not check(sc.ok(), "2. the scenario reads cleanly: %s" % str(sc.errors)):
		return
	eq(sc.ai_kind, SandboxScenario.AI_PILOT, "2. it asks for the pilot AI")
	check(sc.water_on, "2. with the water on")
	eq(sc.units.size(), 8, "2. eight units: two tanks, the cruiser, four enemy tanks, the bridge")
	eq(sc.turn_limit(), RELIEF, "2. the clock counts to relief: turn %d" % RELIEF)
	check(sc.briefing.contains("turn %d" % RELIEF), "2. and the briefing says it: %s" % sc.briefing)
	var w := World.new()
	w.quiet = true
	var ids := sc.populate(w)
	check(not ids.has(""), "2. every unit is placed: %s" % w.last_error)
	var water: RefCounted = sc.water()
	var layout: RefCounted = water.layout()
	var road: PackedVector2Array = layout.road()
	var site: Dictionary = sc.water_site("bridge")
	var idx := int(site["road_index"])
	var bridge: Vector2 = site["pos"]
	var bu := w.units[BRIDGE] as Unit
	near(_pos(w, BRIDGE).distance_to(bridge), 0.0, 1e-6, "2. the bridge stands on the water's bridge site")
	eq(bu.side, "allies", "2. the player's side holds it")
	check(bu.def.is_static() and bu.health == 14, "2. a static bridge of 14 pips (Alex, bridge-durability)")
	var dir_far := (BridgeSeedSearch.road_point(road, idx, 100.0) - BridgeSeedSearch.road_point(road, idx, -100.0)).normalized()   # toward the enemy's end
	for id: String in [TANK1, TANK2]:
		var u := w.units[id] as Unit
		eq(u.controller, "player", "2. %s is the player's" % id)
		eq(u.type, "tank", "2. %s is a tank" % id)
		eq(u.speed, 0.0, "2. %s starts at rest" % id)
		check(w.unit_grounded(id), "2. %s stands on legal ground" % id)
		var p := _pos(w, id)
		check(layout.road().size() > 0 and GroundMap.shared(int(sc.seed_value), water).road_dist(p.x, p.y) <= 8.0, "2. %s is on the road" % id)
		check((p - bridge).dot(dir_far) < -30.0 and p.distance_to(bridge) < 120.0, "2. %s is on the PLAYER's side of the river, %.0f m from the bridge's middle" % [id, p.distance_to(bridge)])
		check((Vector2.from_angle(u.heading)).dot((bridge - p).normalized()) > 0.9, "2. %s faces the bridge" % id)
		check(u.callsign != "", "2. %s has a callsign from Alex's pool (%s)" % [id, u.callsign])
	var s := w.units[SHIP] as Unit
	eq(s.controller, "player", "2. the cruiser is the player's")
	eq(s.type, "cruiser", "2. a cruiser")
	check(w.afloat_at(s.x, s.y, s.heading, SHIP), "2. afloat where it starts")
	var d_ship := _pos(w, SHIP).distance_to(bridge)
	check(d_ship >= 2400.0 and d_ship <= 3000.0, "2. %.0f m from the bridge: the far end of its 3,000 m" % d_ship)
	eq(s.speed, 0.0, "2. at rest")
	# PLAYTEST-4 (Alex, 2026-10-14; builder ORD): "the cruiser starts pointing east-west, along the coast" -- west, with the main turrets already trained on the bridge
	var to_bridge := (bridge - _pos(w, SHIP))
	check(absf(sin(s.heading)) < 0.01, "2. pointing east-west, along the coast (heading %.4f)" % s.heading)
	check(absf(Vector2.from_angle(s.heading).dot(to_bridge.normalized())) < 0.35, "2. so the bridge is abeam, not ahead (%.2f)" % Vector2.from_angle(s.heading).dot(to_bridge.normalized()))
	near(float(s.turret), wrapf(to_bridge.angle() - s.heading, -PI, PI), 0.01, "2. and its main turrets are trained on the bridge road (%.1f degrees off the bow)" % rad_to_deg(s.turret))
	eq(s.callsign, "Old Smoky", "2. named from Alex's small-cruiser pool")
	var starts: Array[int] = []
	var expected := {"tank_e1": [570.0, 1], "tank_e2": [585.0, 1], "tank_e3": [620.0, 6], "tank_e4": [670.0, 11]}
	for id: String in expected:
		var u := w.units[id] as Unit
		eq(u.side, "axis", "2. %s is the enemy's" % id)
		eq(u.controller, "ai", "2. %s is the AI's" % id)
		eq(u.speed, 0.0, "2. %s waits at rest" % id)
		var want: Vector2 = BridgeSeedSearch.road_point(road, idx, float(expected[id][0]))
		near(_pos(w, id).distance_to(want), 0.0, 1e-3, "2. %s stands %.0f m along the road beyond the bridge" % [id, float(expected[id][0])])
		check(w.unit_grounded(id), "2. %s stands on legal ground" % id)
		check(Vector2.from_angle(u.heading).dot((bridge - _pos(w, id)).normalized()) > 0.9, "2. %s faces the bridge" % id)
		var orders: Dictionary = sc.ai_assignments[id]
		eq(orders["role"], "drive", "2. %s takes the drive role" % id)
		eq(int(orders["start_turn"]), int(expected[id][1]), "2. %s starts at turn %d" % [id, int(expected[id][1])])
		var to: Array = orders["to"]
		var past := Vector2(float(to[0]), float(to[1]))
		check((past - bridge).dot(dir_far) < -60.0 and past.distance_to(BridgeSeedSearch.road_point(road, idx, -90.0)) < 0.01, "2. %s drives to the road 90 m past the bridge on the player's side" % id)
		starts.append(int(orders["start_turn"]))
	eq(starts, [1, 1, 6, 11] as Array[int], "2. three waves (2, 1 and 1 tanks), five turns apart")
	# PLAYTEST-4 (Alex: "the enemy tanks start OUTSIDE the player's sight"): from turn 1 nobody on the player's side sees an enemy tank
	for id: String in expected:
		check(not w.spotted_now("allies", {"unit": id}), "2. %s starts outside the player's sight" % id)
		for pid: String in [TANK1, TANK2, SHIP]:
			var pu := w.units[pid] as Unit
			check(_pos(w, id).distance_to(_pos(w, pid)) > float(pu.def.sight_range_m), "2. %s is %.0f m from %s, whose sight is %.0f m" % [id, _pos(w, id).distance_to(_pos(w, pid)), pid, float(pu.def.sight_range_m)])
	# the mission and the ring
	var m := sc.make_mission(w)
	check(m != null and m.ok(), "2. the mission builds: %s" % str(m.errors if m != null else "null"))
	eq(m.spec["win"].size(), 1, "2. one way to win")
	eq(m.spec["win"][0]["type"], "turn_reached", "2. holding until relief")
	eq(m.spec["lose"].size(), 3, "2. three ways to lose")
	var lose_types: Array = (m.spec["lose"] as Array).map(func(c: Dictionary) -> String: return str(c["type"]))
	eq(lose_types, ["side_past", "all_down", "unit_down"], "2. an enemy across, both tanks down, the bridge down")
	var line: Dictionary = m.spec["lose"][0]
	check(not line.has("point_site") and (line["point"] as Array).size() == 2 and (line["toward"] as Array).size() == 2, "2. the line's place and direction are plain numbers once the scenario has read its sites")
	var line_at := Vector2(float(line["point"][0]), float(line["point"][1]))
	near(line_at.distance_to(BridgeSeedSearch.road_point(road, idx, -30.0)), 0.0, 1e-6, "2. the line is 30 m from the bridge's middle, on the player's side")
	check(Vector2(float(line["toward"][0]), float(line["toward"][1])).normalized().dot(-dir_far) > 0.99, "2. crossed in the direction of the village")
	var ring := sc.objective()
	eq(ring["label"], "BRIDGE", "2. the ring says BRIDGE")
	near((ring["point"] as Vector2).distance_to(bridge), 0.0, 1e-3, "2. it is round the bridge")
	# every placement and number is a proposal with its reason
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenarios/bridge.json"))
	for u: Variant in (raw["units"] as Array) + (raw["water_units"] as Array):
		var ud := u as Dictionary
		check(ud.get("_proposed", false) == true and str(ud.get("_reason", "")).length() > 40, "2. %s is a PROPOSED placement with its reason" % str(ud["id"]))
	for k: String in (raw["ai"]["assignments"] as Dictionary):
		check(str(raw["ai"]["assignments"][k].get("_reason", "")).length() > 40, "2. %s's orders carry their reason" % k)
	check(str(raw["_about"]).contains("bridge-mission") and str(raw["_about"]).contains("far end of ship range"), "2. the file quotes Alex's decision and his idea")
	check((raw["mission"]["win"][0] as Dictionary).has("_reason") and (raw["mission"]["lose"][0] as Dictionary).has("_reason"), "2. the mission's win and its first loss say why")
	# the sites: road_m and road_from_site
	var over := {"units": [{"id": "x", "type": "tank", "side": "side_a", "controller": "player", "site": "water.bridge", "road_m": 200.0, "heading": "road_from_site", "speed": 0.0}],
		"ai": {"kind": "pilot", "assignments": {"x": {"role": "idle"}}}}
	var sc2 := SandboxScenario.new("bridge", true, over)
	check(sc2.ok(), "2. road_from_site reads: %s" % str(sc2.errors))
	if sc2.ok():
		var xs: Dictionary = sc2.units[0]
		var xp := Vector2(float(xs["x"]), float(xs["y"]))
		near(xp.distance_to(BridgeSeedSearch.road_point(road, idx, 200.0)), 0.0, 1e-3, "2. a unit 200 m along the road")
		check(Vector2.from_angle(float(xs["heading"])).dot((xp - bridge).normalized()) > 0.9, "2. road_from_site faces away from the bridge, the way the road runs")
	_sections += 1

# --- 3. The conditions -------------------------------------------------------------------------------------

# A World of tanks on a plain (no water, no ground: nothing to stop them) and a mission over it.
func _plain(units: Array, spec: Dictionary, attach: bool = true) -> Array:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	for u: Dictionary in units:
		var d := {"type": "tank", "controller": "player", "heading": 0.0, "speed": 10.0}
		d.merge(u, true)
		if w.add_unit(d) == "":
			fail("unit %s not added: %s" % [str(u), w.last_error])
	var m := Mission.new(w, spec, "res://data/sim/ai.json", true)
	if attach:
		m.attach()
	return [w, m]

func _step(w: World) -> Dictionary:
	w.commit("local")
	var res := w.resolve()
	w.begin_turn()
	return res

func _conditions() -> void:
	# turn_reached: the end of turn 3, a win; before it nothing
	var spec := {"win": [{"type": "turn_reached", "turn": 3, "reason": "relief"}], "lose": [{"type": "all_down", "side": "axis"}]}
	var pm := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 0.0}, {"id": "e", "side": "axis", "x": 0.0, "y": 500.0}], spec)
	var w: World = pm[0]
	var m: Mission = pm[1]
	check(m.ok(), "3. a mission of a win at a turn is valid: %s" % str(m.errors))
	_step(w)
	_step(w)
	eq(m.state, Mission.PLAYING, "3. turn_reached: nothing before the turn (two turns played)")
	_step(w)
	eq(m.state, Mission.WON, "3. ... a win when turn 3 has been played")
	eq(m.reason, "relief", "3. ... in the words the data gave")
	near(m.time, 5.0, 1e-9, "3. ... at the END of the turn")
	var pm2 := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 0.0}], {"win": [{"type": "turn_reached", "turn": 1}], "lose": []})
	_step(pm2[0] as World)
	eq((pm2[1] as Mission).reason, "turn 1 was reached", "3. the default words")
	# side_past: a line 100 m along x, crossed in +x
	var line := {"type": "side_past", "side": "axis", "point": [105.0, 0.0], "toward": [3.0, 0.0], "label": "the line"}
	var pl := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 200.0}, {"id": "e", "side": "axis", "x": 0.0, "y": 0.0}], {"win": [], "lose": [line]})
	w = pl[0]
	m = pl[1]
	check(m.ok(), "3. side_past is valid: %s" % str(m.errors))
	_step(w)
	_step(w)
	eq(m.state, Mission.PLAYING, "3. side_past: a tank 100 m on has not crossed a line 105 m ahead")
	_step(w)
	eq(m.state, Mission.LOST, "3. ... and has in the third turn")
	eq(m.reason, "e got past the line", "3. ... the unit and the label are in the words: %s" % m.reason)
	check(m.time >= 0.4 and m.time <= 0.8, "3. ... at the sampled moment it crossed (%.2f s into the turn: 5 m at 10 m/s)" % m.time)
	# the other direction: the line crossed toward -x is never crossed by a tank driving +x
	var back := {"type": "side_past", "side": "axis", "point": [105.0, 0.0], "toward": [-1.0, 0.0]}
	var pb := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 200.0}, {"id": "e", "side": "axis", "x": 500.0, "y": 0.0}], {"win": [], "lose": [back]})
	for i in 5:
		_step(pb[0] as World)
	eq((pb[1] as Mission).state, Mission.PLAYING, "3. a line to be crossed the other way (toward -x): a tank on the +x side driving away from it never crosses it")
	# a tank already past it when the game begins is past at once (t = 0): it holds from the first look
	var pa := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 200.0}, {"id": "e", "side": "axis", "x": 500.0, "y": 0.0}], {"win": [], "lose": [line]})
	_step(pa[0] as World)
	eq((pa[1] as Mission).state, Mission.LOST, "3. a unit that starts beyond the line is past it")
	near((pa[1] as Mission).time, 0.0, 1e-9, "3. ... from the first look (t = 0)")
	# only the side: the other side's tanks may cross freely
	var po := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 0.0}, {"id": "e", "side": "axis", "x": 0.0, "y": 200.0, "heading": PI}], {"win": [], "lose": [line]})
	for i in 5:
		_step(po[0] as World)
	eq((po[1] as Mission).state, Mission.PLAYING, "3. a tank of the other side driving over it is not what the line is for")
	# a tank shot down before it crossed does not count; one shot down after it crossed does; one down since an earlier turn does not
	var pd := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 0.0}, {"id": "e", "side": "axis", "x": 60.0, "y": 0.0}], {"win": [], "lose": [line]}, false)
	w = pd[0]
	m = pd[1]
	var eu := w.units["e"] as Unit
	w.commit("local")
	w.resolve()
	# (the tank was going to cross within this turn: 60 + 50 = 110 m at the turn's end; it was destroyed at 0.1 s, long before it got there)
	_down(eu, 0.1)
	m.evaluate({"turn": w.turn})
	check(m.state == Mission.PLAYING, "3. a tank that went down before the line does not count (%s)" % m.reason)
	var pe := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 0.0}, {"id": "e", "side": "axis", "x": 60.0, "y": 0.0}], {"win": [], "lose": [line]}, false)
	w = pe[0]
	m = pe[1]
	w.commit("local")
	w.resolve()
	_down(w.units["e"] as Unit, 4.9)
	m.evaluate({"turn": w.turn})
	check(m.state == Mission.LOST, "3. ... and one that crossed and was shot down after it does (%s)" % m.reason)
	# the static ones never cross (a static unit of the side is not a mover)
	var pst := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 0.0}, {"id": "b", "type": "bridge", "side": "axis", "controller": "ai", "x": 500.0, "y": 0.0, "speed": 0.0}], {"win": [], "lose": [line]})
	_step(pst[0] as World)
	eq((pst[1] as Mission).state, Mission.PLAYING, "3. a static unit beyond the line is not past it (it never got there)")
	# a win and a loss in the same turn: the one that held earlier decides
	var both := {"win": [{"type": "turn_reached", "turn": 3}], "lose": [line]}
	var pw := _plain([{"id": "a", "side": "allies", "x": 0.0, "y": 200.0}, {"id": "e", "side": "axis", "x": 0.0, "y": 0.0}], both)
	for i in 3:
		_step(pw[0] as World)
	eq((pw[1] as Mission).state, Mission.LOST, "3. relief at the end of turn 3 does not beat a tank that crossed earlier in turn 3")
	# validation
	var bad_cases := [
		[{"type": "side_past", "point": [0.0, 0.0], "toward": [1.0, 0.0]}, "no selector"],
		[{"type": "side_past", "side": "axis", "units": ["e"], "point": [0.0, 0.0], "toward": [1.0, 0.0]}, "two selectors"],
		[{"type": "side_past", "side": "axis", "point": [0.0, 0.0], "toward": [0.0, 0.0]}, "toward [0, 0]"],
		[{"type": "side_past", "side": "axis", "point": [0.0], "toward": [1.0, 0.0]}, "a point of one number"],
		[{"type": "side_past", "side": "axis", "point": [0.0, 0.0], "toward": "east"}, "toward as text"],
		[{"type": "side_past", "units": ["ghost"], "point": [0.0, 0.0], "toward": [1.0, 0.0]}, "a unit that is not there"],
		[{"type": "side_past", "side": "axis", "point": [0.0, 0.0], "toward": [1.0, 0.0], "label": ""}, "an empty label"],
		[{"type": "turn_reached", "turn": 0}, "turn 0"],
		[{"type": "turn_reached", "turn": 2.5}, "a turn and a half"],
		[{"type": "turn_reached", "turn": 3, "reason": 7}, "a reason that is not words"],
	]
	var wv := World.new()
	wv.quiet = true
	wv.add_player("local")
	wv.add_unit({"id": "e", "type": "tank", "side": "axis", "controller": "ai", "x": 0.0, "y": 0.0, "heading": 0.0})
	for bc: Array in bad_cases:
		var key := "win" if (bc[0] as Dictionary)["type"] == "turn_reached" else "lose"
		var mm := Mission.new(wv, {"win": [bc[0]] if key == "win" else [], "lose": [bc[0]] if key == "lose" else []}, "res://data/sim/ai.json", true)
		check(not mm.ok(), "3. refused: %s" % str(bc[1]))
	check(Mission.TYPES.has("turn_reached") and Mission.TYPES.has("side_past"), "3. both types are in the vocabulary")
	_sections += 1

# --- 4. The waves ------------------------------------------------------------------------------------------

func _waves() -> void:
	var g := _game()
	var w := g.world
	var start: Dictionary = {}
	for id: String in WAVE1 + WAVE2 + WAVE3:
		start[id] = _pos(w, id)
	var first_move: Dictionary = {}
	var crossed_turn := -1
	var moved_before: Array[String] = []
	for t in 24:
		var res := g.turn("idle")
		var turn_no := int(res["turn"])
		for id: String in WAVE1 + WAVE2 + WAVE3:
			var u := w.units[id] as Unit
			var moved := _pos(w, id).distance_to(start[id]) > 0.5
			if moved and not first_move.has(id):
				first_move[id] = turn_no
		if g.mission.state != Mission.PLAYING and crossed_turn < 0:
			crossed_turn = turn_no
			break
	eq(int(first_move.get("tank_e1", -1)), 1, "4. wave 1 drives from turn 1")
	eq(int(first_move.get("tank_e2", -1)), 1, "4. (both tanks of it)")
	eq(int(first_move.get("tank_e3", -1)), 6, "4. wave 2 sits still through turn 5 and drives in turn 6")
	check(not first_move.has("tank_e4") or int(first_move["tank_e4"]) == 11, "4. wave 3 drives in turn 11 (or the game is over before)")
	check(crossed_turn >= 11 and crossed_turn <= 17, "4. unopposed by the guns, wave 1 is across at turn %d (the game is over)" % crossed_turn)
	eq(g.mission.state, Mission.LOST, "4. ... and it is a loss")
	check(g.mission.reason.ends_with("got past the bridge") or g.mission.reason == "bridge_1 is down", "4. in those words (an enemy across, or, with the enemy's guns an order they use on the nearest thing, the bridge shot down): %s" % g.mission.reason)
	# the waves keep their order and their spacing on the road: nobody drove off it
	var gm := GroundMap.shared(int(g.scenario.seed_value), g.scenario.water())
	for id: String in WAVE1:
		var p := _pos(w, id)
		check(gm.road_dist(p.x, p.y) <= 10.0, "4. %s drove down the road (%.1f m from its centre line)" % [id, gm.road_dist(p.x, p.y)])
	for id: String in WAVE1 + WAVE2 + WAVE3:
		check(w.unit_grounded(id), "4. %s is on legal ground (the bridge held it up)" % id)
	_sections += 1

# --- 5. The spotting ---------------------------------------------------------------------------------------

func _spotting() -> void:
	var g := _game()
	var w := g.world
	var ship := w.units[SHIP] as Unit
	check(float(ship.def.sight_range_m) < _pos(w, SHIP).distance_to(_pos(w, "tank_e1")) - 1000.0, "5. the cruiser's own sight (%.0f m) is nowhere near its targets (%.0f m)" % [float(ship.def.sight_range_m), _pos(w, SHIP).distance_to(_pos(w, "tank_e1"))])
	# at the start the waves are outside the tanks' sight (playtest-4): nobody sees them and the guns cannot be switched on at them
	check(w.spotters_now("allies", {"unit": "tank_e1"}).is_empty(), "5. at the start nobody sees the first wave")
	eq(str(w.gun_check(SHIP, 0, {"unit": "tank_e1"})["reason"]), Guns.WHY_OUT_OF_RANGE, "5. and it is out of the guns' reach as well")
	# the first wave driven in to 300 and 315 m along the road beyond the bridge (the old starts): the tanks see it, and the guns' far end reaches it
	for pair: Array in [["tank_e1", 300.0], ["tank_e2", 315.0]]:
		var q := g.scenario.site_point("water.bridge", 0, 0.0, 0.0, true, float(pair[1]))
		(w.units[str(pair[0])] as Unit).x = q.x
		(w.units[str(pair[0])] as Unit).y = q.y
	w.spotting.forget()
	var spotters := w.spotters_now("allies", {"unit": "tank_e1"})
	check(spotters.has(TANK1) and spotters.has(TANK2) and not spotters.has(SHIP), "5. the tanks are the ones who see the first wave once it is in their sight: %s" % str(spotters))
	var chk := w.gun_check(SHIP, 0, {"unit": "tank_e1"})
	check(bool(chk["ok"]), "5. so the guns can be switched on at it (%s)" % str(chk.get("reason")))
	check(float(chk["range_m"]) > 2900.0 and float(chk["range_m"]) <= 3000.0, "5. at %.0f m: the far end of the 3,000" % float(chk["range_m"]))
	# the second tank of the wave starts 15 m farther: past the guns' reach until it has driven a little
	var far := w.gun_check(SHIP, 0, {"unit": "tank_e2"})
	check(not bool(far["ok"]) and str(far["reason"]) == Guns.WHY_OUT_OF_RANGE, "5. %s: the next tank, 15 m farther, is out of reach (%.0f m)" % [str(far["reason"]), float(far["range_m"])])
	var third := w.gun_check(SHIP, 0, {"unit": "tank_e4"})
	check(not bool(third["ok"]) and str(third["reason"]) == Guns.WHY_OUT_OF_RANGE, "5. and the last wave is out of reach at its start (%s)" % str(third["reason"]))
	# without the tanks the guns are blind (the cruiser's 1,000 m of sight sees nothing at 2.7 km)
	_down(w.units[TANK1] as Unit, 0.0)
	_down(w.units[TANK2] as Unit, 0.0)
	w.spotting.forget()
	var blind := w.gun_check(SHIP, 0, {"unit": "tank_e1"})
	check(not bool(blind["ok"]) and str(blind["reason"]) == Guns.WHY_UNSPOTTED, "5. with both tanks down the guns cannot be switched on: %s" % str(blind["reason"]))
	# the coastal strip: the river is the water (a tank on the PLAYER's bank would be inland, one across the river is not): the far bank is fine
	var g2 := _game()
	var spec := g2.world.guns.special("main_guns")
	var depth := g2.world.water_depth
	var bridge := g2.bridge_pos()
	var road_far: Vector2 = g2.scenario.site_point("water.bridge", 0, 0.0, 0.0, true, 300.0)   # (where the first wave comes into the guns' reach; it starts farther out)
	eq(Guns.reach_error(g2.pos_of(SHIP), road_far, spec, depth), "", "5. the first wave's road is on the coastal strip (the river is the water within 600 m)")
	check(Guns.reach_error(g2.pos_of(SHIP), g2.pos_of(TANK1), spec, depth) == Guns.WHY_INLAND, "5. while the player's own bank is 'inland' to the guns (an enemy there has crossed)")
	# every salvo of the scripted defence is aimed at a spotted target, not a poor shot: see section 6
	_sections += 1

# --- 6. A defence wins -------------------------------------------------------------------------------------

func _defence_wins() -> void:
	var wins := 0
	var played := 0
	var reasons: Dictionary = {}
	for s in range(1, SEEDS + 1):
		var g := BridgePlay.new(s)
		if not g.ok():
			fail("6. the game did not stand up: %s" % str(g.errors))
			return
		var r := g.play("defend", RELIEF + 4)
		played += 1
		var key := str(r["state"]) + ": " + str(r["reason"]).substr(0, 40)
		reasons[key] = int(reasons.get(key, 0)) + 1
		if r["state"] == Mission.WON:
			wins += 1
			if _won_seed < 0:
				_won_seed = s
				_won_turn = int(r["turn"])
				_won_salvos = g.salvos
				# the win means what it says
				eq(r["reason"], "relief arrives: the bridge held through turn %d" % RELIEF, "6. the win is relief at turn %d" % RELIEF)
				eq(_won_turn, RELIEF, "6. on turn %d" % RELIEF)
				var bridge := g.world.units[BRIDGE] as Unit
				check(not bridge.down and bridge.health > 0, "6. with the bridge standing (%d pips of 14)" % bridge.health)
				var across := 0
				for id: String in WAVE1 + WAVE2 + WAVE3:
					var eu := g.world.units[id] as Unit
					if not eu.down and (_pos(g.world, id) - g.bridge_pos()).dot((_pos(g.world, TANK1) - g.bridge_pos()).normalized()) > 30.0:
						across += 1
				eq(across, 0, "6. and no live enemy tank across it")
				check((g.world.units[TANK1] as Unit).health > 0 or (g.world.units[TANK2] as Unit).health > 0, "6. a tank of the player's left")
				check(g.salvos >= 2, "6. the cruiser fired %d salvos" % g.salvos)
				var fired := g.events.filter(func(e: Dictionary) -> bool: return e["type"] == "shell_fire" and e["unit"] == SHIP)
				var impacts := g.events.filter(func(e: Dictionary) -> bool: return e["type"] == "shell_impact" and e["unit"] == SHIP)
				check(fired.size() >= 2 and impacts.size() >= 6 * 2 - 4, "6. its shells fell (%d salvos, %d impacts)" % [fired.size(), impacts.size()])
				var poor := fired.filter(func(e: Dictionary) -> bool: return bool(e.get("poor_shot", false)))
				eq(poor.size(), 0, "6. none of them a poor shot: every one was at a target the tanks were spotting")
				var hurt := g.events.filter(func(e: Dictionary) -> bool: return e["type"] == "hit" and e.get("weapon", "") == "main_guns" and str(e["unit"]).begins_with("tank_e"))
				check(not hurt.is_empty(), "6. and some of them hurt the enemy (%d hits)" % hurt.size())
				var spotted_by_tanks := true
				for fe: Dictionary in fired:
					var tgt: Dictionary = fe.get("target", {})
					if not tgt.has("unit") or not str(tgt["unit"]).begins_with("tank_e"):
						spotted_by_tanks = false
				check(spotted_by_tanks, "6. all at the enemy's tanks")
		if _won_seed >= 0 and played >= BATCH:
			break
	check(_won_seed >= 0, "6. the scripted defence wins on some dice seed in 1..%d (it found %d in %d games: %s)" % [SEEDS, wins, played, str(reasons)])
	print("[test] the scripted defence won %d of the first %d dice seeds; the first win is seed %d (turn %d, %d salvos); outcomes: %s" % [wins, played, _won_seed, _won_turn, _won_salvos, str(reasons)])
	_sections += 1

# --- 7. Doing nothing loses ----------------------------------------------------------------------------------

func _idle_loses() -> void:
	var lost := 0
	var turns: Array[int] = []
	for s in range(1, 13):
		var g := BridgePlay.new(s)
		var r := g.play("idle", RELIEF)
		if r["state"] == Mission.LOST:
			lost += 1
			turns.append(int(r["turn"]))
		check(g.mission.reason.ends_with("got past the bridge") or str(g.mission.reason).contains("down"), "7. (seed %d) %s" % [s, str(g.mission.reason)])
	eq(lost, 12, "7. no orders: lost on all twelve dice seeds (the tanks alone cannot stop a wave); turns %s" % str(turns))
	var latest := 0
	for t: int in turns:
		latest = maxi(latest, t)
	check(latest < RELIEF - 8, "7. and long before relief (the last at turn %d)" % latest)
	_sections += 1

# --- 8. The other ends ----------------------------------------------------------------------------------------

func _other_ends() -> void:
	# the bridge destroyed: a loss, in the card's words
	var g := _game()
	_down(g.world.units[BRIDGE] as Unit, 1.0)
	var r := g.play("idle", 1)
	eq(r["state"], Mission.LOST, "8. the bridge down is a loss")
	eq(r["reason"], "bridge_1 is down", "8. %s" % str(r["reason"]))
	var style := UiStyle.shared() as UiStyle
	eq(ResultCard.reason_words(style, g.world, "bridge_1 is down"), "the bridge is destroyed", "8. the card says: the bridge is destroyed")
	eq(ResultCard.reason_words(style, g.world, "tank_e1 got past the bridge"), "an enemy tank got across the bridge", "8. an enemy across: the card says so")
	eq(ResultCard.reason_words(style, g.world, "all of [\"tank_1\", \"tank_2\"] are down"), "both tanks are lost", "8. both tanks lost: the card says so")
	eq(ResultCard.reason_words(style, g.world, "relief arrives: the bridge held through turn 26"), "relief arrives: the bridge held", "8. relief: the card says so")
	# both tanks down
	var g2 := _game()
	_down(g2.world.units[TANK1] as Unit, 2.0)
	_down(g2.world.units[TANK2] as Unit, 3.0)
	var r2 := g2.play("idle", 1)
	eq(r2["state"], Mission.LOST, "8. both tanks down is a loss")
	check(str(r2["reason"]).contains("tank_1") and str(r2["reason"]).ends_with("down"), "8. %s" % str(r2["reason"]))
	# one tank down is not
	var g3 := _game()
	_down(g3.world.units[TANK1] as Unit, 2.0)
	g3.play("idle", 1)
	eq(g3.mission.state, Mission.PLAYING, "8. one tank down is not")
	# the cruiser's own shells can destroy the bridge ("own shells included"): salvos at the bridge's middle, the tanks spotting it, no waves
	var destroyed_by_shells := false
	var tank_pips_lost := 0
	for s in range(1, 9):
		var g4 := BridgePlay.new(s)
		for id: String in WAVE1 + WAVE2 + WAVE3:   # no enemy: only the cruiser's shells are in the game
			(g4.world.units[id] as Unit).health = 1
			_down(g4.world.units[id] as Unit, 0.0)
		var bu := g4.world.units[BRIDGE] as Unit
		var n := 0
		while not bu.down and n < 24:
			n += 1
			if g4.world.gun_reload_left(SHIP, "main_guns") == 0:
				g4.world.plan_step(SHIP, 0, {"fire": {"special": "main_guns", "target": {"point": [bu.x, bu.y]}}})
			g4.world.commit("local")
			if g4.world.participants().has(World.AI_PLAYER):
				g4.world.commit(World.AI_PLAYER)
			var rr := g4.world.resolve()
			if rr.is_empty():
				break
			if not bu.down:
				g4.world.begin_turn()
		if bu.down:
			destroyed_by_shells = true
			var shell_pips := 0
			for ev: Dictionary in g4.events:
				if ev["type"] == "hit" and ev["unit"] == BRIDGE and ev.get("weapon", "") == "main_guns":
					shell_pips += int(ev["damage"])
			check(shell_pips >= 14, "8. (seed %d) the bridge fell to the cruiser's shells alone: %d pips of them in %d turns" % [s, shell_pips, n])
			g4.mission.evaluate({"turn": g4.world.turn})
			eq(g4.mission.state, Mission.LOST, "8. and that is a loss")
			break
	check(destroyed_by_shells, "8. the cruiser's own shells can bring the bridge down (Alex: 'own shells included')")
	_sections += 1

# --- 9. A late joiner -----------------------------------------------------------------------------------------

func _late_joiner() -> void:
	var g := BridgePlay.new(_won_seed if _won_seed >= 0 else 5)
	if not check(g.ok(), "9. the game stands up"):
		return
	# play until a salvo is in the air at a planning phase
	var found := false
	for n in 14:
		g.turn("defend")
		if not g.world.shells_in_flight.is_empty() and g.world.phase == World.PHASE_PLANNING and g.mission.state == Mission.PLAYING:
			found = true
			break
	if not check(found, "9. shells are in the air at a planning phase (turn %d)" % g.world.turn):
		return
	var host_sync := WorldSync.new()
	host_sync.name = "HostSync"
	add_child(host_sync)
	host_sync.setup(g.world, "bridge", g.scenario.local_player)
	var host_player := host_sync.local_player()
	var snap := host_sync.snapshot()
	check(not (snap["guns"]["shells"] as Array).is_empty(), "9. the snapshot carries the shells in the air")
	check(not (snap["guns"]["spot_memory"] as Dictionary).is_empty(), "9. and what the side has been spotting (the ranging in)")
	# a fresh World for the joiner: the scenario's units, no AI, no history
	var cw := World.new()
	cw.quiet = true
	var sc2 := SandboxScenario.new("bridge")
	sc2.populate(cw)
	var client_sync := WorldSync.new()
	client_sync.name = "ClientSync"
	add_child(client_sync)
	client_sync.setup(cw, "bridge", sc2.local_player)
	check(cw.shells_in_flight.is_empty(), "9. the joiner starts with no shells in the air")
	client_sync.apply_snapshot(snap)
	eq(cw.turn, g.world.turn, "9. on the host's turn (%d)" % g.world.turn)
	check(WorldSync.same(cw.net_guns(), g.world.net_guns()), "9. holding the host's shells and memories, to the bit")
	for id: String in g.world.units:
		check(WorldSync.same((cw.units[id] as Unit).net_state(), (g.world.units[id] as Unit).net_state()), "9. %s is as the host has it" % id)
	check(not (cw.units["tank_e1"] as Unit).down or (g.world.units["tank_e1"] as Unit).down, "9. (the enemy's)")
	# the enemy's orders never crossed: the joiner holds no plan for an enemy tank
	for id: String in WAVE1 + WAVE2 + WAVE3:
		eq(((cw.units[id] as Unit).plan as Array).size(), 0, "9. %s's plan did not cross the wire" % id)
	# and it resolves the next turn exactly as the host does, from the host's result
	g.world.plan_step(SHIP, 1, {"turn": 0.0, "speed": 6.0})
	g.world.commit(host_player)
	var res := g.world.resolve()
	check(not res.is_empty(), "9. the host resolves the next turn: %s" % g.world.last_error)
	check(cw.apply_resolution(res), "9. the joiner applies it: %s" % cw.last_error)
	check(WorldSync.same(cw.net_guns(), g.world.net_guns()), "9. and holds the host's shells after it")
	for id: String in g.world.units:
		check(WorldSync.same((cw.units[id] as Unit).net_state(), (g.world.units[id] as Unit).net_state()), "9. %s still agrees" % id)
	host_sync.queue_free()
	client_sync.queue_free()
	_sections += 1

# --- 10. Local, through the menu -------------------------------------------------------------------------------

func _local() -> bool:
	_main.setup_menu()
	var sel: OptionButton = _main.scenario_select
	if not check(sel != null, "10. the menu has a scenario selector"):
		return false
	var at := -1
	for i in sel.item_count:
		if str(sel.get_item_metadata(i)) == "bridge":
			at = i
	if not check(at >= 0, "10. it lists the bridge mission"):
		return false
	eq(sel.get_item_text(at), "HOLD THE BRIDGE: tanks and the cruiser against waves", "10. in words")
	sel.select(at)
	sel.item_selected.emit(at)
	eq(_main.selected_scenario(), "bridge", "10. choosing it on the menu sets the scenario knob")
	check(_main.start_sandbox(), "10. Local builds the sandbox")
	var sb: Node = _main.sandbox
	if sb == null:
		return false
	eq(sb.scenario.id, "bridge", "10. Local starts Hold the bridge")
	sb.scenario.view["result_card_delay_s"] = 0.1
	var playable := await _until(func() -> bool: return sb.is_playable)
	if not check(playable, "10. the sandbox becomes playable"):
		return false
	var w: World = sb.world
	eq(w.units.size(), 8, "10. eight units")
	check(sb.ai is AiPilot, "10. Local attaches the pilot")
	check(sb.mission != null and sb.mission.state == Mission.PLAYING, "10. and the mission, playing")
	check(sb.objective != null and sb.objective.label == "BRIDGE", "10. the ring is on the map, with its word")
	eq(sb.ui.roster.rows().size(), 3, "10. the roster lists the two tanks and the cruiser")
	var rows: Array[Dictionary] = sb.ui.roster.rows()
	eq(rows.map(func(r: Dictionary) -> String: return str(r["type"])), ["Tank", "Tank", "Small cruiser"], "10. by their names")
	check(sb.hint.headline.contains("HOLD THE BRIDGE") and sb.hint.headline.contains("turn %d" % RELIEF), "10. the briefing is in the hint card, with the relief turn")
	eq(sb.clock.line(), "turn 1 of %d" % RELIEF, "10. the turn clock reads: %s" % sb.clock.line())
	sb.ui.marker_layer.update_poses()
	for id in [TANK1, TANK2, SHIP]:
		check(sb.ui.marker_layer.marker(id).visible, "10. %s is shown" % id)
	check(not sb.ui.marker_layer.marker("tank_e1").visible, "10. the first wave is NOT shown: it starts outside the tanks' sight (playtest-4)")
	# the first wave driven in to 300 m beyond the bridge: the tanks see it, and it is shown
	var q: Vector2 = sb.scenario.site_point("water.bridge", 0, 0.0, 0.0, true, 300.0)
	(w.units["tank_e1"] as Unit).x = q.x
	(w.units["tank_e1"] as Unit).y = q.y
	w.spotting.forget()
	sb.ui.marker_layer.update_poses()
	check(sb.ui.marker_layer.marker("tank_e1").visible, "10. the first wave is shown once it is in the tanks' sight (345 m)")
	# the cruiser's guns are on its card: it can be told to fire at the first wave
	sb.ui.select(SHIP)
	var chk := w.gun_check(SHIP, 0, {"unit": "tank_e1"})
	check(bool(chk["ok"]), "10. the interface's own question says the first wave can be fired at: %s" % str(chk.get("reason")))
	# the scripted defence plays the first turns through the interface
	var planner: RefCounted = BridgePlay.for_world(w)
	w.rng_seed = _won_seed if _won_seed >= 0 else 5
	var last_turn := 0
	var salvos_fired: Array[int] = [0]
	w.turn_resolved.connect(func(_t: int, _h: Dictionary, evs: Array) -> void:
		for ev: Variant in evs:
			if (ev as Dictionary).get("type", "") == "shell_fire" and (ev as Dictionary).get("unit", "") == SHIP:
				salvos_fired[0] += 1)
	for n in 3:
		var ready := await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not sb.ui.is_playing() and w.turn > last_turn))
		if not ready or sb.result_decided():
			break
		last_turn = w.turn
		planner.plan_players()
		sb.ui.press_ready()
	check(last_turn >= 2, "10. three turns were played through the interface (to turn %d)" % w.turn)
	check(salvos_fired[0] >= 1 or not w.shells_in_flight.is_empty() or not w.gun_memory.is_empty(), "10. and the cruiser fired (%d salvos)" % salvos_fired[0])
	_main.stop_sandbox()
	check(_main.menu.visible, "10. Esc brings the menu back")
	return true

# --- 11. Over the net -------------------------------------------------------------------------------------------

func _net() -> bool:
	if _won_seed < 0:
		fail("11. no seed won the scripted defence, so there is no game to play over the net")
		return false
	var h: NetRig.Peer = rig.add_host(PORT, "Hal", false)
	if not check(h != null, "11. the host binds port %d" % PORT):
		return false
	var c: NetRig.Peer = await rig.add_client(PORT, "Cy", false)
	if not check(c != null, "11. the client connects"):
		return false
	var sb_h: Node = Sandbox.new()
	sb_h.set("net_role", "host")
	var sb_c: Node = Sandbox.new()
	sb_c.set("net_role", "client")
	sb_h.scenario.view["result_card_delay_s"] = 0.1
	sb_c.scenario.view["result_card_delay_s"] = 0.1
	h.root.add_child(sb_h)
	c.root.add_child(sb_c)
	if not check(bool(sb_h.ok()) and bool(sb_c.ok()), "11. both sandboxes build: %s %s" % [str(sb_h.errors), str(sb_c.errors)]):
		return false
	sb_h.world.rng_seed = _won_seed
	h.world = sb_h.world
	h.sync = sb_h.session.sync
	c.world = sb_c.world
	c.sync = sb_c.session.sync
	eq(sb_h.scenario.id, "bridge", "11. Host starts Hold the bridge")
	eq(sb_c.scenario.id, "bridge", "11. and so does Join")
	check(sb_h.ai is AiPilot and sb_c.ai == null, "11. the pilot drives the waves on the host only")
	for id: String in WAVE1 + WAVE2 + WAVE3:
		eq((sb_c.world.units[id].plan as Array).size(), 0, "11. the client never gets %s's plan" % id)
	var joined: bool = await rig.wait_until(func() -> bool: return sb_c.session.sync.is_joined() and sb_h.world.players.size() == 2)
	if not check(joined, "11. the client is welcomed"):
		return false
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "11. the client holds the host's game")
	var planner: RefCounted = BridgePlay.for_world(sb_h.world)
	var guard := 0
	var last := 0
	var late_done := false
	while guard < RELIEF + 4 and not (sb_h.result_decided() and sb_c.result_decided()):
		guard += 1
		var up: bool = await rig.wait_until(func() -> bool:
			return (sb_h.result_decided() and sb_c.result_decided()) or (sb_h.world.phase == World.PHASE_PLANNING and sb_c.world.phase == World.PHASE_PLANNING \
				and sb_h.world.turn == sb_c.world.turn and sb_h.world.turn > last and not sb_h.ui.is_playing() and not sb_c.ui.is_playing()), 4000)
		if not check(up, "11. both machines reach the planning phase of the turn after %d" % last):
			return false
		if sb_h.result_decided() and sb_c.result_decided():
			break
		# A player joins in the middle, with shells in the air: she is dealt the whole game
		if not late_done and not sb_h.world.shells_in_flight.is_empty():
			late_done = true
			var dee: NetRig.Peer = await rig.add_client(PORT, "Dee", false)
			if check(dee != null, "11. a late player connects"):
				var sb_d: Node = Sandbox.new()
				sb_d.set("net_role", "client")
				dee.root.add_child(sb_d)
				dee.world = sb_d.world
				dee.sync = sb_d.session.sync
				var dee_in: bool = await rig.wait_until(func() -> bool: return sb_d.session.sync.is_joined(), 4000)
				check(dee_in, "11. who is welcomed in the middle of the game")
				if dee_in:
					check(WorldSync.same(sb_d.world.net_guns(), sb_h.world.net_guns()), "11. and holds the shells in the air and the memories, as the host has them")
					check(rig.differences_from_host(dee) == "", "11. and the host's World: %s" % rig.differences_from_host(dee))
					for id: String in WAVE1 + WAVE2 + WAVE3:
						eq((sb_d.world.units[id].plan as Array).size(), 0, "11. no enemy plan reached her")
				sb_d.shutdown()
				sb_d.queue_free()
				rig.drop(dee)
				var gone: bool = await rig.wait_until(func() -> bool: return sb_h.world.players.size() == 2, 2000)
				check(gone, "11. (she leaves again)")
		last = sb_h.world.turn
		planner.plan_players()
		var planned: bool = await rig.wait_until(func() -> bool:
			for id: String in [SHIP]:
				if not WorldSync.same(sb_h.world.units[id].plan, sb_c.world.units[id].plan):
					return false
			return true, 2000)
		if not check(planned, "11. the client sees the plan for turn %d" % last):
			return false
		sb_c.ui.press_ready()
		sb_h.ui.press_ready()
	var both: bool = await rig.wait_until(func() -> bool: return sb_h.result_decided() and sb_c.result_decided(), 4000)
	if not check(both, "11. the mission ends on both machines"):
		return false
	check(late_done, "11. shells were in the air in the middle of the game, so the late player was tried")
	eq(sb_c.result["state"], sb_h.result["state"], "11. the client ends in the host's state")
	eq(sb_c.result["state"], Mission.WON, "11. (won: the scripted defence on the winning seed)")
	eq(sb_c.result["turn"], sb_h.result["turn"], "11. on the same turn")
	eq(int(sb_h.result["turn"]), _won_turn, "11. which is the turn the run without a network won on")
	near(float(sb_c.result["t"]), float(sb_h.result["t"]), 1e-9, "11. at the same moment")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "11. the Worlds are the same at the end")
	check(WorldSync.same(sb_c.world.net_guns(), sb_h.world.net_guns()), "11. and the gun records")
	for id: String in sb_h.world.units:
		eq(sb_c.world.units[id].health, sb_h.world.units[id].health, "11. %s has the same health on both machines" % id)
	var cards: bool = await rig.wait_until(func() -> bool: return sb_h.result_card_shown() and sb_c.result_card_shown(), 4000)
	check(cards, "11. both machines put the card up")
	check(sb_c.ui.result_card.reason_text().contains("relief"), "11. the client's card says why: %s" % sb_c.ui.result_card.reason_text())
	check(sb_h.ui.result_card.reason_text() == sb_c.ui.result_card.reason_text(), "11. and so does the host's")
	for role: Node in [sb_c, sb_h]:
		role.shutdown()
		role.queue_free()
	rig.close_all()
	await get_tree().process_frame
	return true
