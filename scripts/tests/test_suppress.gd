extends "res://scripts/test_support/test_case.gd"

# SUPPRESS, THE SECOND MISSION (Track M2L, 2026-10-11): data/scenarios/suppress.json behind the menu -- a bomber and two fighters against
# a military complex, three hidden mobile AA guns that SHOOT AND SCOOT and GIVE THEMSELVES AWAY WHEN THEY FIRE, and two escort fighters --
# played to a result, locally and over a real ENet socket. Alex's words are "Clear mobile Aa units and their escorts to enable a bombing run
# of a military complex"; the fun (hidden, moving, self-revealing guns) is the lead's PROPOSAL, and so is every number. Headless, so no
# pixels (scripts/app/suppress_shot.gd is the windowed proof). The dice are PROPOSED numbers, so nothing here depends on a seed: the
# winning run looks for one at run time, in a bounded range, and asserts that one exists.
#
#   1. THE SCENARIO STANDS UP    reads cleanly; nine units (3 players, 2 escorts, 3 guns, the complex); the complex and the escorts' loops
#      are anchored to the world layout's site; every gun starts on the first of its hide points and every hide point is dry, level ground;
#      the players start far out and out of sight; the mission is the Strike's rules on the complex; the objective is the complex.
#   2. REVEAL ON FIRING          a gun that fires is revealed to the side it fired at, from the moment of the shot (not before), at its place,
#      even outside that side's sight; the fog opens a patch there and shows its marker; hidden again after reveal_s, a fading "last seen"
#      mark for fade_s more, then nothing; never shown to its own side; the enemy AI's knowledge follows the same rule.
#   3. THE ROAM ROLE             a gun holds still while a plane is in its reach, never relocates before it has fired, relocates once the delay
#      has passed and no plane is near, and arrives at its next hide point; every leg of every gun's list is drivable.
#   4. A BOMBING RUN CAN WIN     a scripted bomber with its fighters wins on some seed in 1..SEEDS (drops, bombs landing, the guns firing, exactly
#      one 'down' event for the complex); the same seed plays out the same way twice.
#   5. THE OTHER ENDS            the bomber down is a loss; the complex down a win (a tie goes to the players); the turn limit a loss, worded
#      for the complex; doing nothing loses.
#   6. A LATE JOINER             the snapshot carries the reveal: a World that takes it holds the host's records and its fog shows the
#      same patches.
#   6b. A DIVE CAN STRAFE        (a finding for the lead, asserted so it stays true) the engine does not forbid air-to-ground fire: a fighter that DIVES a
#      band in one step tilts its cones down (data/sim/combat.json max_pitch_deg) and its wing guns fire at a gun on the ground; level at
#      the low band they never reach it. How much it takes off a gun (a fraction of a pip a pass) is the report's, not an assertion.
#   6c. CONCEALMENT              (proposed, data/sim/concealment.json) a mobile gun in a grove is seen only inside 200 m, by the player's fog, the enemy AI
#      and shared spotting alike, and seen at any range right after it fires; a gun in the open, or a World with no ground eyes, is as before
#   7. LOCAL, THROUGH THE MENU   (the units track's real files needed) the selector lists Suppress; Local starts it; the pilot, the mission, the
#      ring, the briefing and the clock; the fog hides the enemy; a gun that fires at the players is shown on the map and ringed when it goes.
#   8. OVER THE NET              (the real files needed) a host and a client, each a complete sandbox, played to the end: the same result, the
#      same reveal records at every turn end, a joiner in the middle sees the revealed guns as the others do.
#
# Port 28785 (CLAUDE.md: one port per networked test).

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const AiRoam = preload("res://scripts/sim/ai_roam.gd")
const AiSense = preload("res://scripts/sim/ai_sense.gd")
const Reveal = preload("res://scripts/sim/reveal.gd")
const Sandbox = preload("res://scripts/app/sandbox.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const SuppressPlay = preload("res://scripts/test_support/suppress_play.gd")
const SuppressWorlds = preload("res://scripts/test_support/suppress_worlds.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const RevealMarks = preload("res://scripts/ui/reveal_marks.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")
const ResultCard = preload("res://scripts/ui/result_card.gd")
const SandboxClock = preload("res://scripts/app/sandbox_clock.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const ConcealRules = preload("res://scripts/sim/concealment.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")

const PORT := 28785
const SEEDS := 40          # how many dice seeds the scripted run may try before the test calls the mission unwinnable
const BOMBER := "bomber_1"
const LIGHT := "light_fighter_1"
const HEAVY := "heavy_fighter_1"
const ESCORT1 := "escort_1"
const ESCORT2 := "escort_2"
const COMPLEX := "military_complex_1"
const GUNS: Array[String] = ["mobile_aa_1", "mobile_aa_2", "mobile_aa_3"]
const SUPPRESS := 3        # the scenario knob's index of "suppress"
# The players' planes start in the LOW band: the units track's mobile AA reach 384 m, the low band only (a plane at 400 m is never fired at),
# so a scripted run that is to meet the guns has to come down to them.
const LOW := {"bomber_1": {"altitude_band": "low"}, "light_fighter_1": {"altitude_band": "low"}, "heavy_fighter_1": {"altitude_band": "low"}}

var _main: Node = null
var _saved_scenario := 0
var _saved_speed := 0
var rig: NetRig = null
var _boxes: Dictionary = {}
var _limit := 0
var _won_seed := -1
var _won_turn := 0
var _won_drops := 0

func setup(main) -> void:
	timeout_seconds = 400.0
	_main = main
	_saved_scenario = DebugSettings.get_choice("scenario")
	_saved_speed = DebugSettings.get_choice("playback_speed")
	DebugSettings.set_choice("scenario", SUPPRESS)
	DebugSettings.set_choice("playback_speed", 4)
	main.get_window().size = Vector2i(1280, 720)
	for part: Script in [NetRig, WorldSync, World, Sandbox, SandboxScenario, SuppressPlay, SuppressWorlds, Reveal, AiRoam, AiSense, FogVision, RevealMarks, WorldLayout, ResultCard, SandboxClock, ConcealRules, GroundMap]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	print("[test] the units track's files: %s" % ("REAL (data/units/mobile_aa.json, military_complex.json)" if SuppressWorlds.real_units() else "NOT THERE YET -- stand-ins in tmp/suppress/units (sections 7 and 8 need the real ones and are skipped)"))
	_scenario()
	_reveal()
	_ai_reveal()
	_roam()
	_legs()
	_bombing_run_wins()
	_other_ends()
	_late_joiner()
	_strafe()
	_concealment()
	if SuppressWorlds.real_units():
		var local_ok: Variant = await _local()
		check(local_ok == true, "the local part ran to its last line (a runtime error would have ended it silently)")
		rig = NetRig.new()
		add_child(rig)
		var net_ok: Variant = await _net()
		check(net_ok == true, "the network part ran to its last line (a runtime error would have ended it silently)")
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

# The first 'fire' event time of a unit in a resolve result, or NAN.
func _first_fire_t(res: Dictionary, uid: String) -> float:
	var best := NAN
	for ev: Variant in (res["events"] as Array):
		var e: Dictionary = ev
		if str(e.get("type", "")) == "fire" and str(e.get("unit", "")) == uid and (is_nan(best) or float(e["t"]) < best):
			best = float(e["t"])
	return best

func _last_shot_s(rv: RefCounted, key: String) -> float:
	var rec: Dictionary = rv.records.get(key, {})
	if rec.is_empty():
		return NAN
	var shots: Array = rec["shots"]
	return float((shots[shots.size() - 1] as Array)[4])

# --- 1. The scenario -------------------------------------------------------------------------------------

func _scenario() -> void:
	var sc := SandboxScenario.new("suppress")
	if not check(sc.ok(), "1. the Suppress scenario reads cleanly: %s" % str(sc.errors)):
		return
	eq(sc.ai_kind, SandboxScenario.AI_PILOT, "1. it asks for the pilot AI")
	eq(sc.units.size(), 9, "1. nine units: bomber, two fighters, two escorts, three guns, the complex (the water has no boat or bridge here)")
	check(sc.water_on, "1. with the water on (the map's river and sea, and the ground rule's no-go)")
	var by_id: Dictionary = {}
	var pools: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SandboxScenario.CALLSIGNS_PATH))
	var seen: Dictionary = {}
	var bounds := World.new().bounds
	for spec: Dictionary in sc.units:
		by_id[str(spec["id"])] = spec
		check(bounds.has_point(Vector2(float(spec["x"]), float(spec["y"]))), "1. %s starts on the map" % spec["id"])
		if spec.has("callsign"):
			var pool_name := ""
			for k: String in sc.sides:
				if (sc.sides[k] as Dictionary)["world_side"] == spec["side"]:
					pool_name = str((sc.sides[k] as Dictionary)["callsign_pool"])
			check((pools[pool_name] as Dictionary).get(spec["type"], []).has(spec["callsign"]), "1. %s's callsign comes from the %s pool" % [spec["id"], pool_name])
			check(not seen.has("%s|%s" % [pool_name, spec["callsign"]]), "1. no callsign twice")
			seen["%s|%s" % [pool_name, spec["callsign"]]] = true
	for id: String in [BOMBER, LIGHT, HEAVY, ESCORT1, ESCORT2, COMPLEX] + GUNS:
		check(by_id.has(id), "1. the scenario has %s" % id)
	eq(by_id[BOMBER]["type"], "bomber", "1. the players' bomber")
	eq(by_id[LIGHT]["type"], "light_fighter", "1. a light fighter")
	eq(by_id[HEAVY]["type"], "heavy_fighter", "1. and a heavy one")
	eq(by_id[ESCORT1]["type"], "light_fighter", "1. two escort fighters")
	eq(by_id[ESCORT2]["type"], "light_fighter", "1. (the second)")
	eq(by_id[COMPLEX]["type"], "military_complex", "1. the target is a military complex")
	for g: String in GUNS:
		eq(by_id[g]["type"], "mobile_aa", "1. %s is a mobile AA" % g)
		eq(by_id[g]["controller"], "ai", "1. the enemy's")
		near(float(by_id[g]["speed"]), 0.0, 1e-9, "1. standing still at the start")
	for id: String in [BOMBER, LIGHT, HEAVY]:
		eq(by_id[id]["controller"], "player", "1. %s is a player's" % id)
		eq(by_id[id]["altitude_band"], "medium", "1. %s starts in the medium band" % id)
	eq(by_id[BOMBER]["side"], by_id[LIGHT]["side"], "1. the players are one side")
	check(by_id[BOMBER]["side"] != by_id[COMPLEX]["side"], "1. the complex is the other")
	# The complex is at the layout's radio-tower site, by key; the escorts' loops and the guns' hide points are offsets from it.
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenarios/suppress.json"))
	var raw_units: Dictionary = {}
	for u: Variant in (raw["units"] as Array):
		raw_units[str((u as Dictionary)["id"])] = u
	for id: String in [COMPLEX, ESCORT1, ESCORT2] + GUNS:
		check((raw_units[id] as Dictionary).has("site") and not (raw_units[id] as Dictionary).has("x"), "1. %s names a world-layout site and carries no coordinates" % id)
	var layout: RefCounted = WorldLayout.shared(int(sc.seed_value))
	check(layout.ok(), "1. the world layout loads")
	var site: Vector2 = layout.sites()["radio_tower"]
	near(Vector2(float(by_id[COMPLEX]["x"]), float(by_id[COMPLEX]["y"])).distance_to(site), 0.0, 1e-6, "1. the complex stands on the layout's radio-tower site")
	check(Geometry2D.is_point_in_polygon(site, layout.village()["polygon"]), "1. inside the village")
	# The AI: patrols for the escorts, roams for the guns.
	for id: String in [ESCORT1, ESCORT2]:
		var orders: Dictionary = sc.ai_assignments[id]
		eq(str(orders["role"]), "patrol", "1. %s patrols" % id)
		eq((orders["route"] as Array).size(), 4, "1. a loop of four waypoints")
		for p: Variant in (orders["route"] as Array):
			var d := Vector2(float((p as Array)[0]), float((p as Array)[1])).distance_to(site)
			check(d > 400.0 and d < 900.0, "1. a waypoint is %.0f m from the complex: a loop round the village" % d)
		var start := Vector2(float(by_id[id]["x"]), float(by_id[id]["y"]))
		near(start.distance_to(Vector2(float((orders["route"][0] as Array)[0]), float((orders["route"][0] as Array)[1]))), 0.0, 1e-6, "1. %s starts on its first waypoint" % id)
	for g: String in GUNS:
		var orders: Dictionary = sc.ai_assignments[g]
		eq(str(orders["role"]), "roam", "1. %s roams" % g)
		var hide: Array = orders["route"]
		check(hide.size() >= 2 and hide.size() <= 4, "1. among a few hide points (%d)" % hide.size())
		var at := Vector2(float(by_id[g]["x"]), float(by_id[g]["y"]))
		near(at.distance_to(Vector2(float((hide[0] as Array)[0]), float((hide[0] as Array)[1]))), 0.0, 1e-6, "1. %s starts on the first of them" % g)
		for p: Variant in hide:
			var d := Vector2(float((p as Array)[0]), float((p as Array)[1])).distance_to(site)
			check(d < 700.0, "1. a hide point is %.0f m from the complex: near it" % d)
	# The players start far out and out of sight of everything the village has.
	var sight := 0.0
	var probe := SuppressWorlds.new_world()
	for id: String in [ESCORT1, ESCORT2, COMPLEX] + GUNS:
		sight = maxf(sight, probe.unit_def(str(by_id[id]["type"])).sight_range_m)
	for id: String in [BOMBER, LIGHT, HEAVY]:
		var p := Vector2(float(by_id[id]["x"]), float(by_id[id]["y"]))
		check(p.distance_to(site) > 1800.0, "1. %s starts %.0f m from the complex: the players must fly in" % [id, p.distance_to(site)])
		for e: String in [ESCORT1, ESCORT2] + GUNS:
			check(p.distance_to(Vector2(float(by_id[e]["x"]), float(by_id[e]["y"]))) > sight, "1. and out of sight (%.0f m) of %s" % [sight, e])
	var heading := float(by_id[BOMBER]["heading"])
	var bearing := (site - Vector2(float(by_id[BOMBER]["x"]), float(by_id[BOMBER]["y"]))).angle()
	check(absf(wrapf(heading - bearing, -PI, PI)) < deg_to_rad(5.0), "1. the bomber starts heading at the complex")
	# The mission: the Strike's rules on the complex, with a turn limit in the data (no new condition type).
	var limit_cond: Dictionary = {}
	for c: Variant in (sc.mission_spec["lose"] as Array):
		if str((c as Dictionary).get("type", "")) == Mission.TYPE_TURN_LIMIT:
			limit_cond = c
	check(not limit_cond.is_empty(), "1. the mission has a turn limit")
	_limit = int(limit_cond.get("turn", 0))
	check(_limit >= 15 and _limit <= 40, "1. of %d turns" % _limit)
	eq(JSON.stringify(sc.mission_spec["win"]), JSON.stringify([{"type": "unit_down", "unit": COMPLEX}]), "1. won when the complex is down")
	var lose_types: Array = []
	for c: Variant in (sc.mission_spec["lose"] as Array):
		lose_types.append(str((c as Dictionary).get("type", "")) + ":" + str((c as Dictionary).get("unit", "")))
	check(lose_types.has("unit_down:%s" % BOMBER) and lose_types.has("turn_limit:%s" % COMPLEX), "1. lost when the bomber is down or at the limit: %s" % str(lose_types))
	var obj := sc.objective()
	check(not obj.is_empty(), "1. the scenario has an objective")
	if not obj.is_empty():
		near((obj["point"] as Vector2).distance_to(site), 0.0, 1e-6, "1. it is the complex")
		eq(str(obj["unit"]), COMPLEX, "1. naming the unit")
	check(sc.briefing.contains("SUPPRESS") and sc.briefing.contains("turn %d" % _limit) and not sc.briefing.contains("{"), "1. a briefing line with the turn limit: %s" % sc.briefing)
	eq(sc.turn_limit(), _limit, "1. the scenario reports its turn limit")
	# Standing up: the World, the pilot (every assignment accepted) and the mission.
	var g := SuppressPlay.new(7)
	if not check(g.ok(), "1. the scenario stands up as a game: %s" % str(g.errors)):
		return
	eq(g.world.units.size(), 9, "1. the World has nine units")
	eq(g.player_ids().size(), 3, "1. three of them the players'")
	check(g.ai is AiPilot, "1. the AI is the pilot")
	check(g.ai.ok() and g.ai.warnings.is_empty(), "1. every assignment accepted, no warning: %s %s" % [str(g.ai.errors), str(g.ai.warnings)])
	eq(g.ai.state_of(ESCORT1), AiPilot.S_PATROL, "1. the escorts patrol")
	for id: String in GUNS:
		eq(g.ai.state_of(id), AiRoam.S_HIDE, "1. %s hides" % id)
	check(g.world.is_ready(World.AI_PLAYER), "1. the AI has planned and readied")
	check((g.world.units[COMPLEX] as Unit).def.is_static(), "1. the complex is a static unit")
	check(not (g.world.units[GUNS[0]] as Unit).def.is_static(), "1. a gun is not")
	check(g.mission != null and g.mission.ok() and g.mission.state == Mission.PLAYING, "1. the mission is attached and playing")
	eq(g.world.rng_seed, 7, "1. the dice seed is the one asked for")
	# Every hide point is dry, level ground (the ground rule's eyes are the scenario's).
	check(g.world.has_water() and g.world.has_ground(), "1. the World has the water and the ground")
	for id: String in GUNS:
		for p: Variant in sc.ai_assignments[id]["route"]:
			var px := float((p as Array)[0])
			var py := float((p as Array)[1])
			check(g.world.water_depth_at(px, py) <= 0.0, "1. %s: a hide point (%.0f, %.0f) is dry" % [id, px, py])
			check(g.world.ground_ok_at(px, py, 0.0, id) and g.world.ground_ok_at(px, py, PI * 0.5, id), "1. and a hull can stand there, whichever way it faces (no cliff, no water)")
			check(ConcealRules.shared().in_cover(g.world, px, py), "1. and it is in cover: woods (the tree density %.2f)" % float((g.world.ground.woods_fn as Callable).call(px, py)))
	# The turn clock is the Strike's, over the limit.
	var clk := SandboxClock.new()
	add_child(clk)
	clk.setup(UiStyle.shared(), g.world, _limit)
	eq(clk.line(), "turn 1 of %d" % _limit, "1. the clock reads: turn 1 of %d" % _limit)
	clk.queue_free()

# --- 2. Reveal on firing --------------------------------------------------------------------------------------

# The lowest band of a unit type whose height a gun reaches (slant, from the gun's first hardpoint), and the ground distance at which the gun
# reaches a plane in it at `frac` of its reach: {band, gd}, or {} when the gun reaches no band of the type.
func _reachable_band(w: World, gun: Unit, plane_type: String, frac: float) -> Dictionary:
	var reach := AiRoam.reach_m(w, gun)
	var z := 0.0
	if not gun.def.weapons.is_empty() and not gun.def.weapons[0].hardpoints.is_empty():
		z = gun.def.weapons[0].hardpoints[0].z
	for band: String in w.unit_def(plane_type).envelope.bands:
		var dz := w.band_height(band) - z
		if dz < reach * 0.95:
			return {"band": band, "gd": frac * sqrt(maxf(reach * reach - dz * dz, 0.0))}
	return {}

# A one-gun world: a mobile AA of the enemy's and a player's heavy fighter in the lowest band the gun reaches, at 75 percent of the gun's reach
# on the ground, flying tangentially, so the gun fires at it for the start of the turn from OUTSIDE the fighter's sight (the fog's sight scale
# is set to half that distance here).
func _reveal() -> void:
	var w := SuppressWorlds.new_world()
	w.add_player("local")
	var aa_id := w.add_unit({"id": "aa", "type": "mobile_aa", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	if not check(aa_id != "", "2. a mobile AA stands up: %s" % w.last_error):
		return
	var geo := _reachable_band(w, w.units["aa"], "heavy_fighter", 0.75)
	if not check(not geo.is_empty(), "2. the gun reaches some band of a heavy fighter (reach %.0f m)" % AiRoam.reach_m(w, w.units["aa"])):
		return
	var d: float = geo["gd"]
	var band: String = geo["band"]
	w.add_unit({"id": "fighter", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 2500.0 + d, "y": 2500.0, "heading": PI * 0.5, "altitude_band": band})
	print("[test] reveal: the gun reaches the %s band (%.0f m); the fighter starts %.0f m away on the ground" % [band, AiRoam.reach_m(w, w.units["aa"]), d])
	var sight_scale := 0.5 * d / float(w.unit_def("heavy_fighter").sight_range_m)
	var rv := Reveal.of(w)
	check(rv.ok(), "2. data/sim/reveal.json loads: %s" % str(rv.errors))
	var aa: Unit = w.units["aa"]
	var vis := FogVision.new()
	vis.sight_scale = sight_scale
	var off := FogVision.new()
	off.sight_scale = sight_scale
	off.reveal_enabled = false
	vis.update_from_world(w)
	check(not vis.shows_unit(w, "aa"), "2. before anything: the gun is outside the fighter's sight, so the fog hides it")
	check((vis.reveal_list as Array).is_empty(), "2. and nothing is revealed")
	w.commit("local")
	w.commit(World.AI_PLAYER)
	var res := w.resolve()
	var t0: float = _first_fire_t(res, "aa")
	if not check(not is_nan(t0), "2. the gun fired at the fighter in the turn (a 'fire' event of the gun)"):
		return
	check(rv.records.has("aa|allies"), "2. a record of the gun fired at the allies")
	check(not rv.records.has("aa|axis"), "2. and none for its own side")
	var shot_s: float = _last_shot_s(rv, "aa|allies")
	check(not is_nan(shot_s), "2. the record has shots")
	# Not before the shot, from the moment of it.
	eq(rv.marks("allies", rv.game_time(1, t0 - 0.05)).size(), 0, "2. a moment before its first shot (%.2f s) the gun is not revealed" % t0)
	var at_shot: Array = rv.marks("allies", rv.game_time(1, t0 + 0.01))
	eq(at_shot.size(), 1, "2. at its first shot it is")
	if at_shot.size() == 1:
		check(bool(at_shot[0]["revealed"]), "2. revealed (the fog opens)")
		near(float(at_shot[0]["x"]), aa.x, 3.0, "2. at its place (x)")
		near(float(at_shot[0]["y"]), aa.y, 3.0, "2. at its place (y)")
	eq(rv.marks("axis", rv.now_s(w)).size(), 0, "2. never shown to its own side")
	# The fog, at the playback moment.
	vis.update_from_world(w, t0 - 0.05, "history")
	check(not vis.shows_unit(w, "aa"), "2. the fog hides the gun a moment before it fires")
	vis.update_from_world(w, t0 + 0.05, "history")
	check(vis.shows_unit(w, "aa"), "2. and shows it once it has fired, though it is outside the fighter's sight")
	var patch := false
	for c: Dictionary in vis.circles:
		if str(c["id"]) == "reveal:aa":
			patch = true
			near(float(c["r"]), rv.radius_m, 1e-9, "2. the patch has the data's radius")
			check(not c.has("shed"), "2. and is a circle (no viewshed)")
	check(patch, "2. as a patch of its own in the fog")
	check(vis.is_visible(Vector2(aa.x, aa.y)), "2. the ground it stands on is in sight")
	eq((vis.reveal_list as Array).size(), 1, "2. one mark for the 'last seen' ring")
	off.update_from_world(w, t0 + 0.05, "history")
	check(not off.shows_unit(w, "aa"), "2. (with the rule off the gun stays hidden)")
	# The turns after: revealed for reveal_s, a fading mark for fade_s, then nothing.
	var saw_revealed := false
	var saw_fading := false
	var saw_gone := false
	var shown_fading := false
	for k in 14:
		w.begin_turn()
		var now: float = rv.now_s(w)
		var last: float = _last_shot_s(rv, "aa|allies")
		var age: float = now - last
		var ms: Array = rv.marks("allies", now)
		vis.update_from_world(w)
		var shown := vis.shows_unit(w, "aa")
		if age <= rv.reveal_s:
			saw_revealed = true
			check(ms.size() == 1 and bool(ms[0]["revealed"]) and shown, "2. at %.1f s after its last shot (turn %d) it is still revealed and shown" % [age, w.turn])
		elif age <= rv.reveal_s + rv.fade_s:
			saw_fading = true
			check(ms.size() == 1 and not bool(ms[0]["revealed"]) and float(ms[0]["alpha"]) > 0.0 and float(ms[0]["alpha"]) < 1.0, "2. at %.1f s only the fading mark is left (turn %d)" % [age, w.turn])
			check(not shown, "2. and the fog is closed on the gun again")
			if (vis.reveal_list as Array).size() == 1:
				shown_fading = true
		else:
			saw_gone = true
			check(ms.is_empty() and not shown and (vis.reveal_list as Array).is_empty(), "2. at %.1f s nothing is left (turn %d)" % [age, w.turn])
		w.commit("local")
		w.commit(World.AI_PLAYER)
		if w.resolve().is_empty():
			fail("2. turn %d did not resolve: %s" % [w.turn, w.last_error])
			return
	check(saw_revealed and saw_fading and saw_gone, "2. the three stages were all seen (revealed %s, fading %s, gone %s)" % [saw_revealed, saw_fading, saw_gone])
	check(shown_fading, "2. and the fading mark was in the fog's list while it faded")
	# A down gun is not shown (a ruin is the effects layer's).
	var w2 := SuppressWorlds.new_world()
	w2.add_player("local")
	w2.add_unit({"id": "aa", "type": "mobile_aa", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w2.add_unit({"id": "fighter", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 2500.0 + d, "y": 2500.0, "heading": PI * 0.5, "altitude_band": band})
	var rv2 := Reveal.of(w2)
	w2.commit("local")
	w2.commit(World.AI_PLAYER)
	w2.resolve()
	check(rv2.marks("allies", rv2.now_s(w2)).size() == 1, "2. (a second world: revealed)")
	_down(w2.units["aa"], NAN)
	eq(rv2.marks("allies", rv2.now_s(w2)).size(), 0, "2. a gun that is down is no longer shown")

# The enemy AI's knowledge: a PLAYER's gun that fires at the AI is known at its place of firing, outside any of the AI's sight circles.
func _ai_reveal() -> void:
	var w := SuppressWorlds.new_world()
	w.add_player("local")
	w.add_unit({"id": "pgun", "type": "mobile_aa", "side": "allies", "controller": "player", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	var geo := _reachable_band(w, w.units["pgun"], "bomber", 0.7)
	if not check(not geo.is_empty(), "2. (the AI) the gun reaches some band of a bomber"):
		return
	var d: float = geo["gd"]
	w.add_unit({"id": "enemy", "type": "bomber", "side": "axis", "controller": "ai", "x": 2500.0 + d, "y": 2500.0, "heading": PI * 0.5, "altitude_band": str(geo["band"])})
	# (the AI's bomber is made short-sighted -- 40 percent of the distance, in this World only -- so that the gun that fires at it is outside its sight)
	(w.units["enemy"].def as RefCounted).set("sight_range_m", 0.4 * d)
	var sense := AiSense.new()
	sense.update(w, 3)
	check(not sense.knows("pgun"), "2. (the AI) the gun is outside every AI sight circle: not known")
	w.commit("local")
	w.commit(World.AI_PLAYER)
	var res := w.resolve()
	check(not is_nan(_first_fire_t(res, "pgun")), "2. (the AI) the gun fired at the AI's bomber")
	w.begin_turn()
	sense.update(w, 3)
	check(sense.knows("pgun") and sense.is_visible("pgun"), "2. (the AI) now the AI knows it, and sees it this turn")
	var e := sense.entry("pgun")
	if not e.is_empty():
		near(float(e["x"]), (w.units["pgun"] as Unit).x, 3.0, "2. (the AI) where it fired from (x)")
		near(float(e["y"]), (w.units["pgun"] as Unit).y, 3.0, "2. (the AI) and (y)")
	var sense_off := AiSense.new()
	Reveal.of(w).clear()
	sense_off.update(w, 3)
	check(not sense_off.knows("pgun"), "2. (the AI) with the records gone it knows nothing again (the knowledge is the reveal's)")

# --- 3. The roam role -----------------------------------------------------------------------------------------

# The scenario's world, the players flying on (idle): the guns fire at them as they pass, and the roam role runs.
func _roam() -> void:
	var g := SuppressPlay.new(5, LOW.duplicate(true))
	if not check(g.ok(), "3. the game stands up: %s" % str(g.errors)):
		return
	g.continue_after_result = true
	var rules := AiRoam.rules()
	var held_ok := true
	var holds := 0
	var states_seen: Dictionary = {}
	var turn_no := 0
	for n in 120:
		# the states the AI planned for the turn about to be played, and where each gun stands
		var start: Dictionary = {}
		var state: Dictionary = {}
		for id: String in GUNS:
			var u: Unit = g.world.units[id]
			start[id] = Vector2(u.x, u.y)
			state[id] = g.ai.state_of(id)
			states_seen[state[id]] = true
		var res := g.turn("idle")
		if res.is_empty():
			break
		turn_no += 1
		for id: String in GUNS:
			var u: Unit = g.world.units[id]
			if state[id] == AiRoam.S_FIRE:
				holds += 1
				# (a gun that was moving brakes inside the step: a few metres)
				if Vector2(u.x, u.y).distance_to(start[id]) > 6.0:
					held_ok = false
		var settled := 0
		for t: Dictionary in g.ai.transitions:
			if GUNS.has(str(t["unit"])) and str(t["reason"]) == AiRoam.R_SETTLED:
				settled += 1
		if settled >= 3 and n > 30:
			break
	check(g.errors.is_empty(), "3. the game ran: %s" % str(g.errors))
	# Per gun, from the pilot's transitions and the turns' events.
	var first_fire: Dictionary = {}
	var shots_by_turn: Dictionary = {}      # gun -> {turn: true}
	for ev: Variant in g.events:
		var e: Dictionary = ev
		if str(e.get("type", "")) == "fire" and GUNS.has(str(e.get("unit", ""))):
			var gid := str(e["unit"])
			if not first_fire.has(gid):
				first_fire[gid] = int(e["turn"])
			if not shots_by_turn.has(gid):
				shots_by_turn[gid] = {}
			shots_by_turn[gid][int(e["turn"])] = true
	var drove: Dictionary = {}              # gun -> the turn its first relocation was planned
	var settled_at: Dictionary = {}         # gun -> the turn it first settled at a new point
	var rules_ok := true
	for t: Dictionary in g.ai.transitions:
		var gid := str(t["unit"])
		if not GUNS.has(gid):
			continue
		if str(t["to"]) == "drive" and not drove.has(gid):
			drove[gid] = int(t["turn"])
			# it had fired before, and not in the turn just before the delay allows
			var last_before := -99
			for k: Variant in shots_by_turn.get(gid, {}):
				if int(k) < int(t["turn"]):
					last_before = maxi(last_before, int(k))
			if last_before < 1 or int(t["turn"]) - last_before < rules.relocate_delay_turns:
				rules_ok = false
				fail("3. %s began to relocate in turn %d, its last shot before that was in turn %d (delay %d)" % [gid, int(t["turn"]), last_before, rules.relocate_delay_turns])
		if str(t["reason"]) == AiRoam.R_SETTLED and not settled_at.has(gid):
			settled_at[gid] = int(t["turn"])
	check(first_fire.size() >= 2, "3. at least two of the guns fired at the planes flying by (first shots in turns %s)" % str(first_fire))
	check(states_seen.has(AiRoam.S_HIDE) and states_seen.has(AiRoam.S_FIRE) and states_seen.has("drive"), "3. the guns hid, held to fire and drove: %s" % str(states_seen.keys()))
	check(holds >= 2, "3. a gun was held to fire in %d gun-turns" % holds)
	check(held_ok, "3. a gun that was told to fire did not move while it did (it stops for the planes)")
	check(rules_ok, "3. no gun relocated before it had fired, or in the turn after its last shot sooner than the delay allows")
	check(drove.size() >= 1, "3. a gun relocated after it had fired (%s)" % str(drove))
	for id: String in drove:
		check(int(drove[id]) > int(first_fire.get(id, 999)), "3. %s relocated (turn %d) after its first shot (turn %d)" % [id, int(drove[id]), int(first_fire.get(id, -1))])
		check(Reveal.of(g.world).last_fire_turn(id) >= int(first_fire.get(id, 999)), "3. and its shots are on record")
	# A gun that relocated settled at one of its other hide points, hiding again.
	check(settled_at.size() >= 1, "3. at least one gun arrived at its next hide point (turns %s)" % str(settled_at))
	for id: String in settled_at:
		var hide: Array = g.ai.assignments[id]["route"]
		var info: Dictionary = g.ai.info(id)
		var u: Unit = g.world.units[id]
		var best := INF
		for p: Variant in hide:
			best = minf(best, Vector2(u.x, u.y).distance_to(Vector2(float((p as Array)[0]), float((p as Array)[1]))))
		if int(info.get("dest", -1)) == -1 and str(info.get("state", "")) == AiRoam.S_HIDE:
			check(best <= 40.0, "3. %s hides at a point of its list (%.0f m from the nearest)" % [id, best])
	print("[test] roam: guns first fired in turns %s; first relocation planned in turns %s; first settled in turns %s (%d turns played, %s)" % [str(first_fire), str(drove), str(settled_at), turn_no, "stand-in guns" if SuppressWorlds.standin_in_use() else "the real guns"])

# Every leg of every gun's list, driven: the three guns are made to scoot in step (each round the records say they have just fired and
# the planes are far away), three rounds, so every hide point is left for the next one and the list is gone round once.
func _legs() -> void:
	var far := {BOMBER: {"x": 4900.0, "y": 4900.0, "heading": 0.0}, LIGHT: {"x": 4900.0, "y": 4800.0, "heading": 0.0}, HEAVY: {"x": 4900.0, "y": 4700.0, "heading": 0.0}}
	var g := SuppressPlay.new(5, far)
	if not check(g.ok(), "3. (legs) the game stands up: %s" % str(g.errors)):
		return
	g.continue_after_result = true
	var rv := Reveal.of(g.world)
	var sc: SandboxScenario = g.scenario
	g.turn("idle")   # (turn 2: the guns settled in turn 1, so a shot "in turn 1" counts as fired since they settled)
	for round_no in 3:
		var want: Dictionary = {}
		for id: String in GUNS:
			var hide: Array = sc.ai_assignments[id]["route"]
			want[id] = Vector2(float((hide[(round_no + 1) % hide.size()] as Array)[0]), float((hide[(round_no + 1) % hide.size()] as Array)[1]))
		# they have just fired: the AI plans this turn again with that known
		for id: String in GUNS:
			rv.last_fire[id] = {"turn": g.world.turn - 1, "time": 0.0}
		g.world.phase = World.PHASE_PLANNING
		g.ai.plan_turn()
		var done := false
		var turns := 0
		var arrived: Dictionary = {}
		while turns < 150 and not done:
			var res := g.turn("idle")
			if res.is_empty():
				break
			turns += 1
			for id: String in GUNS:
				var u: Unit = g.world.units[id]
				if Vector2(u.x, u.y).distance_to(want[id]) <= 25.0 and not arrived.has(id):
					arrived[id] = turns
			done = arrived.size() == GUNS.size()
		check(done, "3. (legs) round %d: every gun reached its next hide point (%s of %d in %d turns)" % [round_no + 1, str(arrived), GUNS.size(), turns])
		print("[test] legs round %d: arrived after %s turns (%s)" % [round_no + 1, str(arrived), "stand-in guns" if SuppressWorlds.standin_in_use() else "the real guns"])
		if not done:
			return
		# let them settle (the AI notices an arrival at its next planning), then one turn more
		var settle := 0
		while settle < 12:
			var all_hid := true
			for id: String in GUNS:
				if g.ai.state_of(id) != AiRoam.S_HIDE:
					all_hid = false
			if all_hid:
				break
			g.turn("idle")
			settle += 1
		g.turn("idle")

# --- 4. A bombing run can win ----------------------------------------------------------------------------------

func _bombing_run_wins() -> void:
	var wins := 0
	var lost_bomber := 0
	var lost_limit := 0
	var t0 := Time.get_ticks_msec()
	var first: SuppressPlay = null
	for s in range(1, SEEDS + 1):
		var g := SuppressPlay.new(s)
		if not g.ok():
			fail("4. the game did not stand up: %s" % str(g.errors))
			return
		g.dive_band = "low"
		var r: Dictionary = g.play("bomb", _limit + 2)
		match str(r["state"]):
			Mission.WON:
				wins += 1
				if _won_seed < 0:
					_won_seed = s
					_won_turn = int(r["turn"])
					_won_drops = g.events.filter(func(e: Dictionary) -> bool: return str(e["type"]) == "bomb_release").size()
					first = g
			Mission.LOST:
				if g.world.units[BOMBER].down:
					lost_bomber += 1
				else:
					lost_limit += 1
		if _won_seed >= 0 and s >= 12:
			break   # a win found, and a few more seeds seen for the report
	print("[test] suppress run (%s): %d won, %d lost with the bomber down, %d lost at the limit over the seeds tried; first win on seed %d (turn %d, %d drops); %.1f s" % [
		"stand-ins" if SuppressWorlds.standin_in_use() else "real units", wins, lost_bomber, lost_limit, _won_seed, _won_turn, _won_drops, (Time.get_ticks_msec() - t0) / 1000.0])
	if not check(_won_seed >= 0, "4. the scripted bombing run wins on some seed in 1..%d (it won on none: the mission cannot be won, or the numbers moved it out of reach)" % SEEDS):
		return
	var w: World = first.world
	check(w.units[COMPLEX].down and w.units[COMPLEX].health <= 0, "4. the complex is down, with no health left")
	eq(w.units[COMPLEX].fate, Unit.FATE_DESTROYED, "4. destroyed (a ground unit's fate)")
	check(not w.units[BOMBER].down, "4. the bomber is still up")
	var releases := 0
	var impacts := 0
	var complex_downs := 0
	var gun_fire := 0
	var gun_fire_by: Dictionary = {}
	var hits_on_complex := 0
	for ev: Dictionary in first.events:
		match str(ev["type"]):
			"bomb_release":
				releases += 1
				check(str(ev["unit"]) == BOMBER, "4. a stick released by the bomber")
			"bomb_impact":
				impacts += 1
			"hit":
				if str(ev.get("unit", "")) == COMPLEX and str(ev.get("weapon", "")) == "bomb":
					hits_on_complex += 1
			"down":
				if str(ev.get("unit", "")) == COMPLEX:
					complex_downs += 1
			"fire":
				if GUNS.has(str(ev.get("unit", ""))):
					gun_fire += 1
					gun_fire_by[str(ev["unit"])] = true
	check(releases >= 1 and releases <= w.units[BOMBER].def.bomb_drops, "4. the bomber dropped %d stick(s)" % releases)
	check(impacts >= 4 * releases - 4, "4. the bombs landed (%d impacts for %d sticks)" % [impacts, releases])
	check(hits_on_complex >= 1, "4. the complex was hit by bombs (%d hits)" % hits_on_complex)
	eq(complex_downs, 1, "4. and exactly one 'down' event for it")
	check(gun_fire > 0, "4. the guns fired (%d rolls by %d guns)" % [gun_fire, gun_fire_by.size()])
	check(Reveal.of(w).records.size() >= 1, "4. and gave themselves away (%d records)" % Reveal.of(w).records.size())
	check(str(first.mission.reason).contains(COMPLEX), "4. the mission's reason: %s" % first.mission.reason)
	check(_won_turn >= 4 and _won_turn <= _limit, "4. decided on turn %d (the bomber starts 5.5 turns out; the limit is %d)" % [_won_turn, _limit])
	var again := SuppressPlay.new(_won_seed)
	again.dive_band = "low"
	var r2: Dictionary = again.play("bomb", _limit + 2)
	eq(r2["state"], Mission.WON, "4. the same seed wins again")
	eq(int(r2["turn"]), _won_turn, "4. on the same turn")
	near(float(r2["t"]), float(first.mission.time), 1e-9, "4. at the same moment")
	eq(again.events.size(), first.events.size(), "4. with the same events")
	check(WorldSync.same(Reveal.of(again.world).net_state(), Reveal.of(first.world).net_state()), "4. and the same guns revealed, where and when")
	check(WorldSync.same(again.ai.transitions, first.ai.transitions), "4. and the AI makes the same transitions")

# --- 5. The other ends -----------------------------------------------------------------------------------------

func _other_ends() -> void:
	var style := UiStyle.shared()
	# The bomber down: lost, on the first resolve that sees it.
	var g := SuppressPlay.new(7)
	_down(g.world.units[BOMBER], NAN)
	var r: Dictionary = g.play("idle", 3)
	eq(r["state"], Mission.LOST, "5. the bomber down: lost")
	eq(int(r["turn"]), 1, "5. on the first resolve that sees it")
	check(str(r["reason"]).contains(BOMBER) and str(r["reason"]).contains("down"), "5. the reason names it: %s" % str(r["reason"]))
	eq(ResultCard.reason_words(style, g.world, str(r["reason"])), "bomber down", "5. the card says: bomber down")
	# The bomber shot down by the guns (a real kill; it has one pip left and flies the run low, through the ring of guns): a loss too.
	var shot := 0
	for s in range(1, 41):
		var gs := SuppressPlay.new(s)
		gs.dive_band = "low"
		gs.world.units[BOMBER].health = 1
		var rs: Dictionary = gs.play("bomb", _limit + 2)
		if str(rs["state"]) == Mission.LOST and gs.world.units[BOMBER].down:
			shot += 1
			check(str(rs["reason"]).contains(BOMBER), "5. seed %d: the bomber shot down by the guns or the escorts: lost (%s)" % [s, str(rs["reason"])])
			if shot >= 1:
				break
	check(shot >= 1, "5. on some seed of the first 40 the one-pip bomber is shot down and the mission is lost")
	# A fighter down, a gun down, an escort down: none is the end.
	var g1 := SuppressPlay.new(7)
	_down(g1.world.units[LIGHT], NAN)
	eq(g1.play("idle", 2)["state"], Mission.PLAYING, "5. a fighter down: still playing")
	var g2 := SuppressPlay.new(7)
	_down(g2.world.units[GUNS[0]], NAN)
	_down(g2.world.units[ESCORT1], NAN)
	eq(g2.play("idle", 2)["state"], Mission.PLAYING, "5. a gun and an escort down: still playing")
	# The complex down: won.
	var g3 := SuppressPlay.new(7)
	_down(g3.world.units[COMPLEX], NAN)
	var r3: Dictionary = g3.play("idle", 3)
	eq(r3["state"], Mission.WON, "5. the complex down: won")
	check(str(r3["reason"]).contains(COMPLEX), "5. the reason names it: %s" % str(r3["reason"]))
	check(ResultCard.reason_words(style, g3.world, str(r3["reason"])).contains("destroyed"), "5. the card says: %s" % ResultCard.reason_words(style, g3.world, str(r3["reason"])))
	# Both in one turn: a tie goes to the players.
	var g4 := SuppressPlay.new(7)
	_down(g4.world.units[COMPLEX], NAN)
	_down(g4.world.units[BOMBER], NAN)
	eq(g4.play("idle", 3)["state"], Mission.WON, "5. the complex and the bomber down together: a win, the tie goes to the players")
	# Doing nothing: lost (shot down on the way, or at the limit).
	var by_limit := 0
	var won := 0
	var words_ok := false
	for s in range(1, 7):
		var gi := SuppressPlay.new(s)
		var ri: Dictionary = gi.play("idle", _limit + 5)
		if str(ri["state"]) == Mission.WON:
			won += 1
			continue
		eq(ri["state"], Mission.LOST, "5. seed %d: nobody drops anything: lost" % s)
		if gi.world.units[BOMBER].down:
			continue
		by_limit += 1
		eq(int(ri["turn"]), _limit, "5. seed %d: lost at the turn limit, turn %d" % [s, _limit])
		check(str(ri["reason"]).contains(COMPLEX) and str(ri["reason"]).contains("still stands"), "5. the reason names the complex: %s" % str(ri["reason"]))
		check(ResultCard.reason_words(style, gi.world, str(ri["reason"])).contains("still stands"), "5. and the card words it: %s" % ResultCard.reason_words(style, gi.world, str(ri["reason"])))
		words_ok = true
	eq(won, 0, "5. doing nothing never wins")
	print("[test] idle games: %d of 6 ran to the turn limit (the others lost the bomber to the guns)" % by_limit)
	# One turn short of the limit it is still playing (a game where nothing has been lost earlier).
	var gl := SuppressPlay.new(7, {BOMBER: {"x": 4900.0, "y": 4900.0, "heading": 0.0}, LIGHT: {"x": 4900.0, "y": 4800.0, "heading": 0.0}, HEAVY: {"x": 4900.0, "y": 4700.0, "heading": 0.0}})
	var rl: Dictionary = gl.play("idle", _limit - 1)
	eq(rl["state"], Mission.PLAYING, "5. the game is still playing one turn short of the limit (the planes out of the way)")
	eq(int(rl["turns"]), _limit - 1, "5. %d turns played" % (_limit - 1))
	var rl2: Dictionary = gl.play("idle", 3)
	eq(rl2["state"], Mission.LOST, "5. and lost at the limit")
	eq(int(rl2["turn"]), _limit, "5. on turn %d" % _limit)
	check(words_ok or str(rl2["reason"]).contains("still stands"), "5. worded for the complex: %s" % str(rl2["reason"]))

# --- 6. A late joiner ------------------------------------------------------------------------------------------

# The snapshot the host sends a joiner carries the reveal: a World that takes it holds the host's records and its fog shows the same
# patches. (No socket: WorldSync.snapshot() and apply_snapshot() are the two ends; the sockets are section 8.)
func _late_joiner() -> void:
	var g := SuppressPlay.new(5, LOW.duplicate(true))
	if not check(g.ok(), "6. the game stands up: %s" % str(g.errors)):
		return
	var rv := Reveal.of(g.world)
	var found := false
	for n in 20:
		g.turn("idle")
		if not rv.marks("allies", rv.now_s(g.world)).is_empty() and g.world.phase == World.PHASE_PLANNING:
			found = true
			break
	if not check(found, "6. a gun fired at the players (revealed at a planning phase)"):
		return
	var host_sync := WorldSync.new()
	host_sync.name = "HostSync"
	add_child(host_sync)
	host_sync.setup(g.world, "suppress", g.scenario.local_player)
	var snap := host_sync.snapshot()
	check(snap.has("reveal") and not (snap["reveal"]["records"] as Dictionary).is_empty(), "6. the snapshot carries the reveal records")
	# A fresh World for the joiner: the scenario's units, no AI, no history.
	var cw := SuppressWorlds.new_world()
	var sc2 := SandboxScenario.new("suppress")
	sc2.populate(cw)
	var client_sync := WorldSync.new()
	client_sync.name = "ClientSync"
	add_child(client_sync)
	client_sync.setup(cw, "suppress", sc2.local_player)
	var crv := Reveal.of(cw)
	check(crv.records.is_empty(), "6. the joiner starts knowing nothing")
	client_sync.apply_snapshot(snap)
	check(WorldSync.same(crv.net_state(), rv.net_state()), "6. after the snapshot it holds the host's records, shot for shot")
	eq(cw.turn, g.world.turn, "6. on the same turn")
	var now: float = rv.now_s(g.world)
	check(WorldSync.same(crv.marks("allies", now), rv.marks("allies", now)), "6. and sees the same marks")
	var hv := FogVision.new()
	hv.update_from_world(g.world)
	var cv := FogVision.new()
	cv.update_from_world(cw)
	var host_patches: Array = []
	var client_patches: Array = []
	for c: Dictionary in hv.circles:
		if c.has("reveal"):
			host_patches.append([str(c["id"]), snappedf(float(c["x"]), 0.001), snappedf(float(c["y"]), 0.001)])
	for c: Dictionary in cv.circles:
		if c.has("reveal"):
			client_patches.append([str(c["id"]), snappedf(float(c["x"]), 0.001), snappedf(float(c["y"]), 0.001)])
	check(not host_patches.is_empty(), "6. the fog has a patch for a revealed gun")
	check(host_patches == client_patches, "6. the joiner's fog has the same patches: %s against %s" % [str(client_patches), str(host_patches)])
	for m: Dictionary in rv.marks("allies", now):
		if bool(m["revealed"]):
			check(cv.shows_unit(cw, str(m["unit"])) == hv.shows_unit(g.world, str(m["unit"])), "6. %s is shown on both" % str(m["unit"]))
	check(WorldSync.same(Reveal.of(cw).last_fire, rv.last_fire), "6. the guns' last shots too (the roam role reads them on the host)")
	host_sync.queue_free()
	client_sync.queue_free()

# --- 6b. A dive can strafe ------------------------------------------------------------------------------------------

# A fighter flying straight at a mobile gun: LEVEL in the low band it never fires at it (its cone is level, the ground is 120 m below);
# DIVING from the medium band to the low band in one step its cones tilt down (combat.gd, THE TILT) and the guns roll at the gun. The
# engine allows air-to-ground fire; the geometry gives it a step of a dive and a few hundred metres of range.
func _strafe() -> void:
	var rolls_level := 0
	var rolls_dive := 0
	var pips_dive := 0
	var trials := 12
	for s in range(1, trials + 1):
		for variant: String in ["level", "dive"]:
			var w := SuppressWorlds.new_world()
			w.add_player("local")
			w.rng_seed = s
			w.add_unit({"id": "aa", "type": "mobile_aa", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
			var d0 := 300.0 if variant == "level" else 500.0
			w.add_unit({"id": "f", "type": "light_fighter", "side": "allies", "controller": "player", "x": 2500.0 - d0, "y": 2500.0, "heading": 0.0, "altitude_band": "low" if variant == "level" else "medium"})
			var n := w.steps_per_turn("f")
			for k in n:
				var req := {"speed": (w.units["f"] as Unit).speed, "turn": 0.0}
				if variant == "dive" and k == 2:
					req["altitude_band"] = "low"
				w.plan_step("f", k, req)
			w.commit("local")
			w.commit(World.AI_PLAYER)
			var res := w.resolve()
			for ev: Variant in (res["events"] as Array):
				var e: Dictionary = ev
				if str(e["type"]) == "fire" and str(e["unit"]) == "f" and str(e["target"]) == "aa":
					if variant == "level":
						rolls_level += 1
					else:
						rolls_dive += 1
				elif str(e["type"]) == "hit" and str(e["unit"]) == "aa" and variant == "dive":
					pips_dive += int(e["damage"])
	eq(rolls_level, 0, "6b. a fighter level in the low band never fires at a gun on the ground")
	check(rolls_dive >= trials, "6b. a fighter diving a band in one step fires at the gun (%d rolls in %d dives)" % [rolls_dive, trials])
	print("[test] strafe: %d rolls and %.2f pips of the gun's %d per dive pass (the light fighter, 500 m out, diving on step 2; %d trials)" % [rolls_dive, float(pips_dive) / trials, int((SuppressWorlds.new_world().unit_def("mobile_aa") as RefCounted).get("health")), trials])

# --- 6c. Concealment --------------------------------------------------------------------------------------------------

# A World with the scenario's ground eyes (the tree density, the road, the levels: scripts/world/ground_map.gd) holding a mobile gun at `at` and a
# plane in the LOW band `d` metres east of it, heading east (away). `with_ground` false: no ground eyes (what the Strike's World has).
func _cover_world(gun_side: String, gun_ctrl: String, plane_side: String, plane_ctrl: String, at: Vector2, d: float, with_ground: bool = true) -> World:
	var w := SuppressWorlds.new_world()
	w.add_player("local")
	if with_ground:
		var gm: RefCounted = GroundMap.shared(20261009, WaterGen.shared(20261009))
		gm.attach(w)
	Reveal.of(w)
	w.add_unit({"id": "gun", "type": "mobile_aa", "side": gun_side, "controller": gun_ctrl, "x": at.x, "y": at.y, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "plane", "type": "light_fighter", "side": plane_side, "controller": plane_ctrl, "x": at.x + d, "y": at.y, "heading": 0.0, "altitude_band": "low"})
	return w

func _open_point(gm: RefCounted, c: Vector2) -> Vector2:
	for r: float in [450.0, 500.0, 550.0, 600.0]:
		for k in 16:
			var p := c + Vector2.from_angle(TAU * float(k) / 16.0) * r
			if float(gm.woods_at(p.x, p.y)) < 0.05 and int(gm.level_at(p.x, p.y)) == 0:
				return p
	return c

func _concealment() -> void:
	var rule: RefCounted = ConcealRules.shared()
	if not check(rule.ok() and rule.on, "6c. data/sim/concealment.json loads and is on: %s" % str(rule.errors)):
		return
	check(rule.radius_m >= 150.0 and rule.radius_m < 400.0, "6c. the radius (%.0f m) is between the test's 150 m and 400 m" % rule.radius_m)
	var seed_v := 20261009
	var site: Vector2 = WorldLayout.shared(seed_v).sites()["radio_tower"]
	var grove := site + Vector2(60.0, 220.0)       # the first hide point of the south gun: a grove
	var gm: RefCounted = GroundMap.shared(seed_v, WaterGen.shared(seed_v))
	var open_at := _open_point(gm, site)
	check(float(gm.woods_at(grove.x, grove.y)) >= rule.cover_density_min, "6c. the grove is woods (density %.2f)" % float(gm.woods_at(grove.x, grove.y)))
	check(float(gm.woods_at(open_at.x, open_at.y)) < 0.05, "6c. and the open point is open (%.2f)" % float(gm.woods_at(open_at.x, open_at.y)))
	# --- the player's fog: an enemy gun and a player's plane
	var wf := _cover_world("axis", "ai", "allies", "player", grove, 400.0)
	var vis := FogVision.new()
	vis.update_from_world(wf)
	check(not vis.shows_unit(wf, "gun"), "6c. (fog) a gun in a grove is NOT seen at 400 m, though the plane's sight is 800 m")
	(wf.units["plane"] as Unit).x = grove.x + 150.0
	vis.update_from_world(wf)
	check(vis.shows_unit(wf, "gun"), "6c. (fog) but it is seen at 150 m")
	(wf.units["plane"] as Unit).x = grove.x + 400.0
	var wo := _cover_world("axis", "ai", "allies", "player", open_at, 400.0)
	var vis_o := FogVision.new()
	vis_o.update_from_world(wo)
	check(vis_o.shows_unit(wo, "gun"), "6c. (fog) a gun in the open IS seen at 400 m")
	var wn := _cover_world("axis", "ai", "allies", "player", grove, 400.0, false)
	var vis_n := FogVision.new()
	vis_n.update_from_world(wn)
	check(vis_n.shows_unit(wn, "gun"), "6c. (fog) with no ground eyes in the World (the Strike's) a gun in a grove is seen at 400 m as it always was")
	# it fires at the plane: seen at 400 m (and a bit more) at once
	for p: String in wf.participants():
		wf.commit(p)
	var res := wf.resolve()
	var t0: float = _first_fire_t(res, "gun")
	if not check(not is_nan(t0), "6c. the gun fired at the plane 400 m off (inside its reach)"):
		return
	vis.update_from_world(wf, maxf(t0 - 0.05, 0.0), "history")
	check(not vis.shows_unit(wf, "gun"), "6c. (fog) a moment before the shot it is still unseen")
	vis.update_from_world(wf, t0 + 0.05, "history")
	check(vis.shows_unit(wf, "gun"), "6c. (fog) right after it fires it is seen at 400 m (the plane is %.0f m away)" % ((wf.units["plane"] as Unit).x - grove.x))
	# --- the enemy AI: a player's gun and an AI plane
	var wa := _cover_world("allies", "player", "axis", "ai", grove, 400.0)
	var sense := AiSense.new()
	sense.update(wa, 3)
	check(not sense.knows("gun"), "6c. (AI) a player's gun in a grove is not known at 400 m")
	(wa.units["plane"] as Unit).x = grove.x + 150.0
	var sense2 := AiSense.new()
	sense2.update(wa, 3)
	check(sense2.knows("gun") and sense2.is_visible("gun"), "6c. (AI) known at 150 m")
	(wa.units["plane"] as Unit).x = grove.x + 400.0
	var wao := _cover_world("allies", "player", "axis", "ai", open_at, 400.0)
	var sense_o := AiSense.new()
	sense_o.update(wao, 3)
	check(sense_o.knows("gun"), "6c. (AI) a gun in the open is known at 400 m")
	# --- shared spotting: the same pair
	check(not wa.spotted_now("axis", {"unit": "gun"}), "6c. (spotting) the gun in the grove is not spotted at 400 m")
	(wa.units["plane"] as Unit).x = grove.x + 150.0
	check(wa.spotted_now("axis", {"unit": "gun"}), "6c. (spotting) it is at 150 m")
	(wa.units["plane"] as Unit).x = grove.x + 400.0
	check(wao.spotted_now("axis", {"unit": "gun"}), "6c. (spotting) a gun in the open is spotted at 400 m")
	check(wa.spotted_now("axis", {"point": [grove.x, grove.y]}), "6c. (spotting) the ground there, as a point, is (a point is not a unit in cover)")
	# it fires at the AI's plane
	for p: String in wa.participants():
		wa.commit(p)
	var res_a := wa.resolve()
	var t0a: float = _first_fire_t(res_a, "gun")
	if not check(not is_nan(t0a), "6c. (AI, spotting) the player's gun fired at the AI's plane"):
		return
	check(not wa.spotting.spotted_at(wa, "axis", {"unit": "gun"}, maxf(t0a - 0.05, 0.0)), "6c. (spotting) a moment before the shot it is not spotted at 400 m")
	check(wa.spotting.spotted_at(wa, "axis", {"unit": "gun"}, t0a + 0.05), "6c. (spotting) and a moment after it is, at 400 m: the shot waives the cover")
	wa.begin_turn()
	var sense3 := AiSense.new()
	sense3.update(wa, 3)
	check(sense3.knows("gun") and sense3.is_visible("gun"), "6c. (AI) right after it fires the AI knows it, from beyond 200 m (the plane is %.0f m off)" % ((wa.units["plane"] as Unit).x - grove.x))
	# and it hides again once the reveal has run out
	var rv: RefCounted = Reveal.of(wa)
	var guard := 0
	while guard < 12 and not rv.marks("axis", rv.now_s(wa)).is_empty():
		for p: String in wa.participants():
			wa.commit(p)
		wa.resolve()
		wa.begin_turn()
		guard += 1
	(wa.units["plane"] as Unit).x = grove.x + 400.0
	(wa.units["plane"] as Unit).y = grove.y
	check(not wa.spotted_now("axis", {"unit": "gun"}), "6c. (spotting) once the reveal has run out it is not spotted at 400 m again")

# --- 7. Local, through the menu ----------------------------------------------------------------------------------

func _local() -> bool:
	_main.setup_menu()
	var sel: OptionButton = _main.scenario_select
	if not check(sel != null, "7. the menu has a scenario selector"):
		return false
	var at := -1
	for i in sel.item_count:
		if str(sel.get_item_metadata(i)) == "suppress":
			at = i
	if not check(at >= 0, "7. it lists Suppress"):
		return false
	check(sel.get_item_text(at).begins_with("SUPPRESS"), "7. in words: %s" % sel.get_item_text(at))
	sel.select(at)
	sel.item_selected.emit(at)
	eq(_main.selected_scenario(), "suppress", "7. choosing it on the menu sets the scenario knob")
	check(_main.start_sandbox(), "7. Local builds the sandbox")
	var sb: Node = _main.sandbox
	if sb == null:
		return false
	eq(sb.scenario.id, "suppress", "7. Local starts Suppress")
	sb.scenario.view["result_card_delay_s"] = 0.1
	var playable := await _until(func() -> bool: return sb.is_playable)
	if not check(playable, "7. the sandbox becomes playable"):
		return false
	var w: World = sb.world
	eq(w.units.size(), 9, "7. nine units")
	# The planes' drawn size is relative to the smallest PLANE: a mobile gun (6.5 m) is smaller than a light fighter (9 m) and must not be the reference.
	var smallest_air := INF
	for uid: String in w.units:
		if (w.units[uid] as Unit).def.domain == "air":
			smallest_air = minf(smallest_air, float((w.units[uid] as Unit).def.size_m))
	near(float(sb._ref_size), smallest_air, 1e-9, "7. the planes' reference size is the smallest air unit's (%.1f m)" % smallest_air)
	check(float(sb._ref_size) > float(w.unit_def("mobile_aa").size_m), "7. not the mobile gun's %.1f m" % float(w.unit_def("mobile_aa").size_m))
	check(sb.ai is AiPilot, "7. Local attaches the pilot")
	check(sb.mission != null and sb.mission.state == Mission.PLAYING, "7. and the mission, playing")
	check(sb.objective != null and sb.objective.label == "COMPLEX", "7. the ring is on the map, with its word")
	eq(sb.ui.roster.rows().size(), 3, "7. the roster lists the three player units")
	check(sb.hint.headline.contains("SUPPRESS") and sb.hint.headline.contains("turn %d" % _limit), "7. the briefing is in the hint card, with the turn limit")
	eq(sb.clock.line(), "turn 1 of %d" % _limit, "7. the turn clock reads: %s" % sb.clock.line())
	check(sb.reveal_marks != null, "7. the 'last seen' marks are mounted")
	sb.ui.marker_layer.update_poses()
	for id in [BOMBER, LIGHT, HEAVY]:
		check(sb.ui.marker_layer.marker(id).visible, "7. %s is shown" % id)
	for id in [ESCORT1, ESCORT2, COMPLEX] + GUNS:
		check(not sb.ui.marker_layer.marker(id).visible, "7. %s is in the fog" % id)
	# Played through the interface until a gun gives itself away.
	w.rng_seed = _won_seed if _won_seed >= 0 else 5
	var planner: RefCounted = SuppressPlay.for_world(w)
	planner.dive_band = "low"
	var rv := Reveal.of(w)
	var last_turn := 0
	var gun_id := ""
	for n in 12:
		var ready_for_orders := await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not sb.ui.is_playing() and w.turn > last_turn))
		if not ready_for_orders or sb.result_decided():
			break
		var live: Array = rv.marks("allies", rv.now_s(w))
		if not live.is_empty():
			gun_id = str(live[0]["unit"])
			break
		last_turn = w.turn
		planner.plan_players()
		sb.ui.press_ready()
	if not check(gun_id != "", "7. a gun fired at the players and is on the map (turn %d)" % w.turn):
		_main.stop_sandbox()
		return false
	await get_tree().physics_frame
	await get_tree().physics_frame
	var patch := false
	for c: Dictionary in sb.fog.vision.circles:
		if str(c["id"]) == "reveal:%s" % gun_id:
			patch = true
	check(patch, "7. the fog has a patch where %s fired from" % gun_id)
	sb.ui.marker_layer.update_poses()
	check(sb.ui.marker_layer.marker(gun_id).visible, "7. and its marker is shown, though it is outside every player's sight")
	check(sb.reveal_marks.rings().is_empty() or not sb.reveal_marks.rings().any(func(r: Dictionary) -> bool: return str(r["unit"]) == gun_id), "7. (no ring over a marker that is shown)")
	# The gun scoots: put it elsewhere (as if it had driven off) and the ring is what is left.
	var gu: Unit = w.units[gun_id]
	var ox := gu.x
	var oy := gu.y
	gu.x = 4800.0
	gu.y = 4800.0
	await get_tree().physics_frame
	await get_tree().physics_frame
	sb.ui.marker_layer.update_poses()
	check(not sb.ui.marker_layer.marker(gun_id).visible, "7. a gun that has moved away is hidden again")
	var ring_ok := false
	for r: Dictionary in sb.reveal_marks.rings():
		if str(r["unit"]) == gun_id:
			ring_ok = float(r["alpha"]) > 0.0
	check(ring_ok, "7. and its 'last seen' ring is on the map")
	gu.x = ox
	gu.y = oy
	_main.stop_sandbox()
	check(_main.menu.visible, "7. Esc brings the menu back")
	return true

# --- 8. Over the net ------------------------------------------------------------------------------------------------

func _net() -> bool:
	if _won_seed < 0:
		fail("8. no seed won the scripted run, so there is no game to play over the net")
		return false
	var h: NetRig.Peer = rig.add_host(PORT, "Hal", false)
	if not check(h != null, "8. the host binds port %d" % PORT):
		return false
	var c: NetRig.Peer = await rig.add_client(PORT, "Cy", false)
	if not check(c != null, "8. the client connects"):
		return false
	var sb_h: Node = Sandbox.new()
	sb_h.set("net_role", "host")
	var sb_c: Node = Sandbox.new()
	sb_c.set("net_role", "client")
	sb_h.scenario.view["result_card_delay_s"] = 0.1
	sb_c.scenario.view["result_card_delay_s"] = 0.1
	h.root.add_child(sb_h)
	c.root.add_child(sb_c)
	if not check(bool(sb_h.ok()) and bool(sb_c.ok()), "8. both sandboxes build: %s %s" % [str(sb_h.errors), str(sb_c.errors)]):
		return false
	sb_h.world.rng_seed = _won_seed
	h.world = sb_h.world
	h.sync = sb_h.session.sync
	c.world = sb_c.world
	c.sync = sb_c.session.sync
	eq(sb_h.scenario.id, "suppress", "8. Host starts Suppress")
	eq(sb_c.scenario.id, "suppress", "8. and so does Join")
	check(sb_h.ai is AiPilot and sb_c.ai == null, "8. the pilot flies the enemy on the host only")
	for gid: String in GUNS:
		eq((sb_c.world.units[gid].plan as Array).size(), 0, "8. and the client never gets a gun's plan")
	var joined: bool = await rig.wait_until(func() -> bool: return sb_c.session.sync.is_joined() and sb_h.world.players.size() == 2)
	if not check(joined, "8. the client is welcomed"):
		return false
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "8. the client holds the host's game")
	var planner: RefCounted = SuppressPlay.for_world(sb_h.world)
	planner.dive_band = "low"
	var guard := 0
	var last := 0
	var late_done := false
	var same_every_turn := true
	while guard < _limit + 2 and not (sb_h.result_decided() and sb_c.result_decided()):
		guard += 1
		var up: bool = await rig.wait_until(func() -> bool:
			return (sb_h.result_decided() and sb_c.result_decided()) or (sb_h.world.phase == World.PHASE_PLANNING and sb_c.world.phase == World.PHASE_PLANNING \
				and sb_h.world.turn == sb_c.world.turn and sb_h.world.turn > last and not sb_h.ui.is_playing() and not sb_c.ui.is_playing()), 4000)
		if not check(up, "8. both machines reach the planning phase of the turn after %d" % last):
			return false
		var rh := Reveal.of(sb_h.world)
		var rc := Reveal.of(sb_c.world)
		if not WorldSync.same(rh.net_state(), rc.net_state()):
			same_every_turn = false
			fail("8. turn %d: the host's and the client's reveal records differ: %s against %s" % [last, str(rc.net_state()), str(rh.net_state())])
		if sb_h.result_decided() and sb_c.result_decided():
			break
		# A player joins in the middle, while a gun is revealed: she sees what the others see.
		if not late_done and not rh.marks("allies", rh.now_s(sb_h.world)).is_empty():
			late_done = true
			var dee: NetRig.Peer = await rig.add_client(PORT, "Dee", false)
			if check(dee != null, "8. a late player connects"):
				var sb_d: Node = Sandbox.new()
				sb_d.set("net_role", "client")
				dee.root.add_child(sb_d)
				dee.world = sb_d.world
				dee.sync = sb_d.session.sync
				var dee_in: bool = await rig.wait_until(func() -> bool: return sb_d.session.sync.is_joined(), 4000)
				check(dee_in, "8. who is welcomed in the middle of the game")
				if dee_in:
					check(WorldSync.same(Reveal.of(sb_d.world).net_state(), rh.net_state()), "8. and holds the host's reveal records")
					var live: Array = rh.marks("allies", rh.now_s(sb_h.world))
					check(not live.is_empty(), "8. a gun is revealed")
					await get_tree().physics_frame
					await get_tree().physics_frame
					for m: Dictionary in live:
						if bool(m["revealed"]):
							var patch := false
							for cc: Dictionary in sb_d.fog.vision.circles:
								if str(cc["id"]) == "reveal:%s" % str(m["unit"]):
									patch = true
							check(patch, "8. her fog has the patch where %s fired from" % str(m["unit"]))
				sb_d.shutdown()
				sb_d.queue_free()
				rig.drop(dee)
				var gone: bool = await rig.wait_until(func() -> bool: return sb_h.world.players.size() == 2, 2000)
				check(gone, "8. (she leaves again)")
		last = sb_h.world.turn
		planner.plan_players()
		var planned: bool = await rig.wait_until(func() -> bool:
			for id: String in [BOMBER, LIGHT, HEAVY]:
				if not WorldSync.same(sb_h.world.units[id].plan, sb_c.world.units[id].plan):
					return false
			return true, 2000)
		if not check(planned, "8. the client sees the plans for turn %d" % last):
			return false
		sb_c.ui.press_ready()
		sb_h.ui.press_ready()
	var both: bool = await rig.wait_until(func() -> bool: return sb_h.result_decided() and sb_c.result_decided(), 4000)
	if not check(both, "8. the mission ends on both machines"):
		return false
	check(late_done, "8. a gun was revealed in the middle of the game, so the late player was tried")
	check(same_every_turn, "8. the reveal records were the same on both machines at every turn end")
	eq(sb_c.result["state"], sb_h.result["state"], "8. the client ends in the host's state")
	eq(sb_c.result["state"], Mission.WON, "8. (won: the scripted run on the winning seed)")
	eq(sb_c.result["turn"], sb_h.result["turn"], "8. on the same turn")
	eq(int(sb_h.result["turn"]), _won_turn, "8. which is the turn the run without a network won on")
	near(float(sb_c.result["t"]), float(sb_h.result["t"]), 1e-9, "8. at the same moment")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "8. the Worlds are the same at the end")
	check(WorldSync.same(Reveal.of(sb_c.world).net_state(), Reveal.of(sb_h.world).net_state()), "8. and the reveal records")
	for id: String in GUNS + [COMPLEX, ESCORT1, ESCORT2, BOMBER, LIGHT, HEAVY]:
		eq(sb_c.world.units[id].health, sb_h.world.units[id].health, "8. %s has the same health on both machines" % id)
	var cards: bool = await rig.wait_until(func() -> bool: return sb_h.result_card_shown() and sb_c.result_card_shown(), 4000)
	check(cards, "8. both machines put the card up")
	check(sb_c.ui.result_card.reason_text().contains("destroyed"), "8. the client's card says why: %s" % sb_c.ui.result_card.reason_text())
	for role: Node in [sb_c, sb_h]:
		role.shutdown()
		role.queue_free()
	rig.close_all()
	await get_tree().process_frame
	return true
