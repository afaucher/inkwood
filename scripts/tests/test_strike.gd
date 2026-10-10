extends "res://scripts/test_support/test_case.gd"

# THE STRIKE, ASSEMBLED (Track A2, 2026-10-10): data/scenarios/strike.json behind the menu -- a bomber and
# two fighters against a radio tower in a village, two flak batteries and a patrolling fighter -- played to a
# result, locally and over a real ENet socket between a host and a client. Headless, so no pixels
# (scripts/app/strike_shot.gd is the windowed proof). Combat's and the bombs' dice are PROPOSED numbers, so
# nothing here depends on a particular seed: the winning run looks for a seed at run time, in a bounded range,
# and asserts that one exists.
#
#   1. THE SCENARIO STANDS UP    reads cleanly; three player units (the bomber and two fighters, callsigns
#      from the pools), the enemy's patrol fighter, the tower and the two batteries AT THE WORLD LAYOUT'S SITES
#      (the file names the site keys and carries no coordinates for them); the players start far out and out of
#      sight; the mission is Mission.strike's; the objective is the tower; the AI is the pilot with a patrol
#      route anchored to the tower; the mission is attached and playing.
#   2. DOING NOTHING IS A LOSS   the game ends at the turn limit, never a win; one turn short of it is still
#      playing; the card words the limit.
#   3. THE OTHER ENDS, FORCED    the bomber down is a loss; the tower down is a win; both in one turn is a win
#      (a tie goes to the players); the card words each.
#   4. A BOMBING RUN CAN WIN     a scripted bomber (scripts/test_support/strike_play.gd, omniscient) with its
#      fighters wins on some seed in 1..SEEDS: drops in the cone, bombs that land, hits on the tower by bombs,
#      the flak that fired, exactly one 'down' event for the tower; the same seed plays out the same way twice.
#   5. LOCAL, THROUGH THE MENU   the menu's selector (Strike by default) sets the scenario knob; Local starts
#      the Strike; the sandbox attaches the pilot and the mission, shows the target ring, lists the three
#      player units, frames the players and the village (never the enemy's plan), keeps the enemy and the
#      ground units in the fog, says B drops; the scripted run played through the interface wins; the card is
#      put up after the playback with the tower's words; Play again restarts the STRIKE; Menu returns.
#   6. OVER THE NET              a host and a client, each a complete sandbox: the pilot on the host only; the
#      client's mission reaches the host's verdict from the applied results; the Worlds are the same at every
#      turn end; BOMBS STILL FALLING at a turn's end are the client's too, and land the same; both put the card
#      up; the client's Play again replaces both with a new Strike.
#
# Port 28783 (CLAUDE.md: one port per networked test).

const NetRig = preload("res://scripts/net/net_rig.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const Sandbox = preload("res://scripts/app/sandbox.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const StrikePlay = preload("res://scripts/test_support/strike_play.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")
const ResultCard = preload("res://scripts/ui/result_card.gd")
const SandboxClock = preload("res://scripts/app/sandbox_clock.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const PORT := 28783
const SEEDS := 40          # how many dice seeds the scripted run may try before the test calls the strike unwinnable
const BOMBER := "bomber_1"
const LIGHT := "light_fighter_1"
const HEAVY := "heavy_fighter_1"
const PATROL := "patrol_1"
const TOWER := "radio_tower_1"
const AA1 := "aa_battery_1"
const AA2 := "aa_battery_2"
const STRIKE := 2          # the scenario knob's index of "strike"
const INTERCEPT := 0

var _main: Node = null
var _saved_scenario := 0
var _saved_speed := 0
var rig: NetRig = null
var _boxes: Dictionary = {}       # "host" | "client" -> the peer's current Sandbox (replaced by Play again)
var _roots: Dictionary = {}       # "host" | "client" -> the peer's root node
var _limit := 0                   # the scenario's turn limit
var _won_seed := -1               # a seed the scripted run wins on (found by section 4)
var _won_turn := 0
var _won_drops := 0

func setup(main) -> void:
	timeout_seconds = 300.0
	_main = main
	_saved_scenario = DebugSettings.get_choice("scenario")
	_saved_speed = DebugSettings.get_choice("playback_speed")
	DebugSettings.set_choice("scenario", STRIKE)
	DebugSettings.set_choice("playback_speed", 4)    # x8: the knob only changes how fast the markers animate
	main.get_window().size = Vector2i(1280, 720)
	for part: Script in [NetRig, WorldSync, World, Sandbox, SandboxScenario, StrikePlay, WorldLayout, ResultCard, SandboxClock]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	_scenario()
	_idle_is_a_loss()
	_forced_ends()
	_bombing_run_wins()
	var local_ok: Variant = await _local()
	check(local_ok == true, "the local part ran to its last line (a runtime error would have ended it silently)")
	rig = NetRig.new()
	add_child(rig)
	var net_ok: Variant = await _net()
	check(net_ok == true, "the network part ran to its last line (a runtime error would have ended it silently)")
	DebugSettings.set_choice("scenario", _saved_scenario)
	DebugSettings.set_choice("playback_speed", _saved_speed)
	finish()

# --- 1. The scenario -----------------------------------------------------------------------------

func _scenario() -> void:
	var sc := SandboxScenario.new("strike")
	if not check(sc.ok(), "1. the Strike scenario reads cleanly: %s" % str(sc.errors)):
		return
	eq(sc.ai_kind, SandboxScenario.AI_PILOT, "1. it asks for the pilot AI")
	eq(sc.units.size(), 7, "1. seven units: bomber, two fighters, the patrol, the tower, two batteries")
	var by_id: Dictionary = {}
	var pools: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SandboxScenario.CALLSIGNS_PATH))
	var seen: Dictionary = {}
	var bounds := World.new().bounds
	for spec: Dictionary in sc.units:
		by_id[str(spec["id"])] = spec
		check(bounds.has_point(Vector2(float(spec["x"]), float(spec["y"]))), "1. %s starts on the map" % spec["id"])
		if spec["type"] in ["bomber", "light_fighter", "heavy_fighter"]:
			var pool_name := ""
			for k: String in sc.sides:
				if (sc.sides[k] as Dictionary)["world_side"] == spec["side"]:
					pool_name = str((sc.sides[k] as Dictionary)["callsign_pool"])
			var names: Array = (pools[pool_name] as Dictionary).get(spec["type"], [])
			check(spec.has("callsign") and names.has(spec["callsign"]), "1. %s's callsign comes from the %s pool" % [spec["id"], pool_name])
			check(not seen.has(spec.get("callsign", "")), "1. no callsign twice")
			seen[spec.get("callsign", "")] = true
	for id: String in [BOMBER, LIGHT, HEAVY, PATROL, TOWER, AA1, AA2]:
		check(by_id.has(id), "1. the scenario has %s" % id)
	eq(by_id[BOMBER]["type"], "bomber", "1. the players' bomber")
	eq(by_id[LIGHT]["type"], "light_fighter", "1. a light fighter")
	eq(by_id[HEAVY]["type"], "heavy_fighter", "1. and a heavy one")
	eq(by_id[PATROL]["type"], "light_fighter", "1. ONE patrolling enemy fighter")
	eq(by_id[TOWER]["type"], "radio_tower", "1. the target is a radio tower")
	eq(by_id[AA1]["type"], "anti_aircraft_battery", "1. two anti-aircraft batteries")
	eq(by_id[AA2]["type"], "anti_aircraft_battery", "1. (the second)")
	for id: String in [BOMBER, LIGHT, HEAVY]:
		eq(by_id[id]["controller"], "player", "1. %s is a player's" % id)
		eq(by_id[id]["altitude_band"], "medium", "1. %s starts in the medium band" % id)
	for id: String in [PATROL, TOWER, AA1, AA2]:
		eq(by_id[id]["controller"], "ai", "1. %s is the enemy's" % id)
	eq(by_id[BOMBER]["side"], by_id[LIGHT]["side"], "1. the players are one side")
	check(by_id[BOMBER]["side"] != by_id[TOWER]["side"], "1. the village is the other")
	# The tower and the batteries are at the layout's sites, by key, not by copied numbers.
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/scenarios/strike.json"))
	var raw_units: Dictionary = {}
	for u: Variant in (raw["units"] as Array):
		raw_units[str((u as Dictionary)["id"])] = u
	for id: String in [TOWER, AA1, AA2, PATROL]:
		check((raw_units[id] as Dictionary).has("site") and not (raw_units[id] as Dictionary).has("x"), "1. %s names a world-layout site and carries no coordinates" % id)
	var layout: RefCounted = WorldLayout.shared(int(sc.seed_value))
	check(layout.ok(), "1. the world layout loads")
	var sites: Dictionary = layout.sites()
	var tower_site: Vector2 = sites["radio_tower"]
	var batteries: Array = sites["aa_battery"]
	eq(batteries.size(), 2, "1. the layout has two battery sites")
	near(Vector2(float(by_id[TOWER]["x"]), float(by_id[TOWER]["y"])).distance_to(tower_site), 0.0, 1e-6, "1. the tower stands on the layout's tower site")
	near(Vector2(float(by_id[AA1]["x"]), float(by_id[AA1]["y"])).distance_to(batteries[0]), 0.0, 1e-6, "1. the first battery on the first battery site")
	near(Vector2(float(by_id[AA2]["x"]), float(by_id[AA2]["y"])).distance_to(batteries[1]), 0.0, 1e-6, "1. the second on the second")
	check(Geometry2D.is_point_in_polygon(tower_site, layout.village()["polygon"]), "1. the tower is inside the village")
	# The patrol's loop is anchored to the tower as well.
	var route: Array = sc.ai_assignments[PATROL]["route"]
	eq(str(sc.ai_assignments[PATROL]["role"]), "patrol", "1. the enemy fighter patrols")
	eq(route.size(), 4, "1. a loop of four waypoints")
	for p: Variant in route:
		var d := Vector2(float((p as Array)[0]), float((p as Array)[1])).distance_to(tower_site)
		check(d > 400.0 and d < 900.0, "1. a waypoint is %.0f m from the tower: a loop round the village" % d)
	var start := Vector2(float(by_id[PATROL]["x"]), float(by_id[PATROL]["y"]))
	near(start.distance_to(Vector2(float((route[0] as Array)[0]), float((route[0] as Array)[1]))), 0.0, 1e-6, "1. it starts on its first waypoint")
	# The players start far out and out of sight of everything the village has.
	var sight := 0.0
	for id: String in [PATROL, TOWER, AA1, AA2]:
		sight = maxf(sight, World.new().unit_def(str(by_id[id]["type"])).sight_range_m)
	for id: String in [BOMBER, LIGHT, HEAVY]:
		var p := Vector2(float(by_id[id]["x"]), float(by_id[id]["y"]))
		check(p.distance_to(tower_site) > 1800.0, "1. %s starts %.0f m from the tower: the players must fly in" % [id, p.distance_to(tower_site)])
		check(p.distance_to(start) > sight, "1. and %.0f m from the patrol, out of its sight (%.0f m)" % [p.distance_to(start), sight])
	var heading := float(by_id[BOMBER]["heading"])
	var bearing := (tower_site - Vector2(float(by_id[BOMBER]["x"]), float(by_id[BOMBER]["y"]))).angle()
	check(absf(wrapf(heading - bearing, -PI, PI)) < deg_to_rad(5.0), "1. the bomber starts heading at the tower")
	# The mission is the Strike's, with the turn limit in the data.
	var limit_cond: Dictionary = {}
	for c: Variant in (sc.mission_spec["lose"] as Array):
		if str((c as Dictionary).get("type", "")) == Mission.TYPE_TURN_LIMIT:
			limit_cond = c
	check(not limit_cond.is_empty(), "1. the mission has a turn limit")
	_limit = int(limit_cond.get("turn", 0))
	check(_limit >= 12 and _limit <= 30, "1. of %d turns (a pass is about seven; the bomber has three drops)" % _limit)
	# (Both through JSON, so a whole number is the same number on each side.)
	check(JSON.stringify(JSON.parse_string(JSON.stringify(sc.mission_spec)), "", true) == JSON.stringify(JSON.parse_string(JSON.stringify(Mission.strike(TOWER, BOMBER, _limit))), "", true), "1. and the mission block IS Mission.strike(tower, bomber, %d)" % _limit)
	# The objective: the ring round the tower.
	var obj := sc.objective()
	check(not obj.is_empty(), "1. the scenario has an objective")
	if not obj.is_empty():
		near((obj["point"] as Vector2).distance_to(tower_site), 0.0, 1e-6, "1. it is the tower")
		check(float(obj["radius_m"]) > 40.0 and float(obj["radius_m"]) < 400.0, "1. with a ring of %.0f m" % float(obj["radius_m"]))
		eq(str(obj["unit"]), TOWER, "1. naming the unit")
	for k: String in ["fog", "plane_px", "plane_min_px", "start_zoom_max", "start_pad_m", "start_look_ahead_turns", "start_frame_objective", "track_sample_s", "track_line_px", "bake_pause_overview", "result_card_delay_s"]:
		check(sc.view.has(k), "1. view.%s is in the scenario" % k)
	check(sc.briefing.contains("STRIKE"), "1. and a briefing line: %s" % sc.briefing)
	check(sc.briefing.contains("turn %d" % _limit) and not sc.briefing.contains("{"), "1. which says the turn limit, once written in the data (the {turn_limit} filled in)")
	eq(sc.turn_limit(), _limit, "1. the scenario reports its turn limit")
	eq(SandboxScenario.new("intercept").turn_limit(), 0, "1. (the first fight has none)")

	# Standing up: the World, the pilot and the mission, as the sandbox attaches them.
	var g := StrikePlay.new("strike", 7)
	if not check(g.ok(), "1. the scenario stands up as a game: %s" % str(g.errors)):
		return
	eq(g.world.units.size(), 7, "1. the World has seven units")
	eq(g.player_ids().size(), 3, "1. three of them the players'")
	check(g.ai is AiPilot, "1. the AI is the pilot")
	eq(g.ai.state_of(PATROL), AiPilot.S_PATROL, "1. the patrol is patrolling")
	check(g.world.is_ready(World.AI_PLAYER), "1. the AI has planned and readied")
	check((g.world.units[PATROL].plan as Array).size() > 0, "1. the patrol has a plan")
	for id: String in [TOWER, AA1, AA2]:
		check((g.world.units[id] as Unit).def.is_static(), "1. %s is a static unit" % id)
		eq((g.world.units[id].plan as Array).size(), 0, "1. which plans nothing")
	check(g.mission != null and g.mission.ok() and g.mission.state == Mission.PLAYING, "1. the mission is attached and playing")
	eq(g.world.rng_seed, 7, "1. the dice seed is the one asked for")
	eq(SandboxScenario.new("strike").rng_seed, 7, "1. and the scenario's own is its rng_seed")
	# The turn clock counts the turn being planned and warns in the last three.
	var clk := SandboxClock.new()
	add_child(clk)
	clk.setup(UiStyle.shared(), g.world, _limit)
	check(clk.visible, "1. the turn clock shows for a mission with a limit")
	eq(clk.line(), "turn 1 of %d" % _limit, "1. it reads: turn 1 of %d" % _limit)
	eq(clk.warning(), "", "1. and says nothing yet")
	g.world.turn = _limit - 2
	eq(clk.warning(), "2 turns left", "1. two turns from the end it says so")
	g.world.turn = _limit - 1
	eq(clk.warning(), "1 turn left", "1. then one")
	g.world.turn = _limit
	eq(clk.warning(), "last turn", "1. then the last")
	g.world.turn = _limit + 4
	eq(clk.line(), "turn %d of %d" % [_limit, _limit], "1. and never reads past the limit")
	g.world.turn = 1
	clk.queue_free()
	var none := SandboxClock.new()
	add_child(none)
	none.setup(UiStyle.shared(), g.world, 0)
	check(not none.visible, "1. no limit, no clock")
	none.queue_free()
	check(g.world.units[BOMBER].drops_left >= 2, "1. the bomber has at least two drops (Alex: every bomber gets two)")
	eq(g.world.units[BOMBER].def.bomb_per_drop, 4, "1. a stick of four")

# --- 2. Doing nothing is a loss -----------------------------------------------------------------------

func _idle_is_a_loss() -> void:
	var by_limit := 0
	var won := 0
	var intact := true
	var checked_words := false
	for s in range(1, 9):
		var g := StrikePlay.new("strike", s)
		if not g.ok():
			fail("2. the game did not stand up: %s" % str(g.errors))
			return
		var r: Dictionary = g.play("idle", _limit + 5)
		if str(r["state"]) == Mission.WON:
			won += 1
			continue
		eq(r["state"], Mission.LOST, "2. seed %d: nobody drops anything: lost" % s)
		if g.world.units[BOMBER].down:
			continue   # the flak got the idle bomber first: also a loss
		by_limit += 1
		eq(int(r["turn"]), _limit, "2. seed %d: lost at the turn limit, turn %d" % [s, _limit])
		eq(int(r["turns"]), _limit, "2. and the game was played exactly that long")
		check(str(r["reason"]).contains("turn %d" % _limit) and str(r["reason"]).contains("objective"), "2. the reason says so: %s" % str(r["reason"]))
		if g.world.units[TOWER].down or g.world.units[TOWER].health != g.world.units[TOWER].def.health:
			intact = false
		if not checked_words:
			checked_words = true
			eq(ResultCard.reason_words(UiStyle.shared(), g.world, str(r["reason"])), "the tower still stands after turn %d" % _limit, "2. the result card words the limit")
		eq(g.mission.evaluate({"turn": 99})["state"], Mission.LOST, "2. a decided mission stays decided")
	eq(won, 0, "2. doing nothing never wins")
	check(by_limit >= 1, "2. at least one idle game runs to the turn limit (%d of 8)" % by_limit)
	check(intact, "2. with the tower untouched")
	# One turn short of the limit it is still playing.
	var short_ok := false
	for s in range(1, 9):
		var g := StrikePlay.new("strike", s)
		var r: Dictionary = g.play("idle", _limit - 1)
		if str(r["state"]) == Mission.PLAYING:
			short_ok = true
			eq(int(r["turns"]), _limit - 1, "2. %d turns played" % (_limit - 1))
			break
	check(short_ok, "2. the game is still playing one turn short of the limit")

# --- 3. The other ends, forced -------------------------------------------------------------------------

func _down(u: Unit, at: float) -> void:
	u.health = 0
	u.down = true
	u.down_at = at
	u.fate = Unit.FATE_EXPLODED if u.def.domain == "air" else Unit.FATE_DESTROYED

func _forced_ends() -> void:
	var style := UiStyle.shared()
	# The bomber down: lost, on the first resolve that sees it.
	var g := StrikePlay.new("strike", 7)
	_down(g.world.units[BOMBER], NAN)
	var r: Dictionary = g.play("idle", 3)
	eq(r["state"], Mission.LOST, "3. the bomber down: lost")
	eq(int(r["turn"]), 1, "3. on the first resolve that sees it")
	check(str(r["reason"]).contains(BOMBER) and str(r["reason"]).contains("down"), "3. the reason names it: %s" % str(r["reason"]))
	eq(ResultCard.reason_words(style, g.world, str(r["reason"])), "bomber down", "3. the card says: bomber down")
	# A fighter down is not the end.
	var g1 := StrikePlay.new("strike", 7)
	_down(g1.world.units[LIGHT], NAN)
	eq(g1.play("idle", 2)["state"], Mission.PLAYING, "3. a fighter down: still playing")
	# The tower down: won.
	var g2 := StrikePlay.new("strike", 7)
	_down(g2.world.units[TOWER], NAN)
	var r2: Dictionary = g2.play("idle", 3)
	eq(r2["state"], Mission.WON, "3. the tower down: won")
	check(str(r2["reason"]).contains(TOWER), "3. the reason names it: %s" % str(r2["reason"]))
	eq(ResultCard.reason_words(style, g2.world, str(r2["reason"])), "the radio tower is destroyed", "3. the card says: the radio tower is destroyed")
	# Both in one turn: a tie goes to the players (Mission: proposed).
	var g3 := StrikePlay.new("strike", 7)
	_down(g3.world.units[TOWER], NAN)
	_down(g3.world.units[BOMBER], NAN)
	eq(g3.play("idle", 3)["state"], Mission.WON, "3. the tower and the bomber down together: a win, the tie goes to the players")
	# A battery down is not the end either.
	var g4 := StrikePlay.new("strike", 7)
	_down(g4.world.units[AA1], NAN)
	eq(g4.play("idle", 2)["state"], Mission.PLAYING, "3. a battery down: still playing")

# --- 4. A bombing run can win --------------------------------------------------------------------------

func _bombing_run_wins() -> void:
	var wins := 0
	var lost_bomber := 0
	var lost_limit := 0
	var t0 := Time.get_ticks_msec()
	var first: StrikePlay = null
	for s in range(1, SEEDS + 1):
		var g := StrikePlay.new("strike", s)
		var r: Dictionary = g.play("bomb", _limit + 2)
		match str(r["state"]):
			Mission.WON:
				wins += 1
				if _won_seed < 0:
					_won_seed = s
					_won_turn = int(r["turn"])
					_won_drops = g.drops_made
					first = g
			Mission.LOST:
				if g.world.units[BOMBER].down:
					lost_bomber += 1
				else:
					lost_limit += 1
		if _won_seed >= 0 and s >= 8:
			break   # a win found, and a few more seeds seen for the report
	print("[test] strike run: %d won, %d lost with the bomber down, %d lost at the limit over the first seeds tried; first win on seed %d (turn %d, %d drops); %.1f s" % [
		wins, lost_bomber, lost_limit, _won_seed, _won_turn, _won_drops, (Time.get_ticks_msec() - t0) / 1000.0])
	if not check(_won_seed >= 0, "4. the scripted bombing run wins on some seed in 1..%d (it won on none: the strike cannot be won, or the numbers moved it out of reach)" % SEEDS):
		return
	var w: World = first.world
	check(w.units[TOWER].down and w.units[TOWER].health <= 0, "4. the tower is down, with no health left")
	eq(w.units[TOWER].fate, Unit.FATE_DESTROYED, "4. destroyed (a ground unit's fate)")
	check(not w.units[BOMBER].down, "4. the bomber is still up")
	var releases: Array = []
	var impacts := 0
	var tower_hits := 0
	var bomb_hits_on_tower := 0
	var tower_downs := 0
	var flak := 0
	var flak_by: Dictionary = {}
	for ev: Dictionary in first.events:
		match str(ev["type"]):
			"bomb_release":
				releases.append(ev)
			"bomb_impact":
				impacts += 1
			"hit":
				if str(ev.get("unit", "")) == TOWER:
					tower_hits += 1
					if str(ev.get("weapon", "")) == "bomb" and str(ev.get("by", "")) == BOMBER:
						bomb_hits_on_tower += 1
			"down":
				if str(ev.get("unit", "")) == TOWER:
					tower_downs += 1
			"fire":
				if str(ev.get("weapon", "")) == "flak":
					flak += 1
					flak_by[str(ev.get("unit", ""))] = true
	check(releases.size() >= 1 and releases.size() <= w.units[BOMBER].def.bomb_drops, "4. the bomber dropped %d stick(s) (it carries %d drops)" % [releases.size(), w.units[BOMBER].def.bomb_drops])
	for ev: Dictionary in releases:
		eq(int(ev["bombs"]), 4, "4. a stick of four")
		check(float(ev["accuracy"]) > 0.4, "4. released in the cone: accuracy %.2f" % float(ev["accuracy"]))
		check(str(ev["unit"]) == BOMBER, "4. by the bomber")
	check(impacts >= 4 * releases.size() - 4, "4. the bombs landed (%d impacts for %d sticks)" % [impacts, releases.size()])
	check(bomb_hits_on_tower >= 1 and bomb_hits_on_tower == tower_hits, "4. the tower was hit by bombs: %d hits, all the bomber's" % tower_hits)
	eq(tower_downs, 1, "4. and exactly one 'down' event for it")
	check(flak > 0, "4. the flak fired (%d rolls)" % flak)
	check(_won_turn >= 4 and _won_turn <= _limit, "4. it took until turn %d (five turns to fly in; the limit is %d)" % [_won_turn, _limit])
	check(str(first.mission.reason).contains(TOWER), "4. the mission's reason: %s" % first.mission.reason)
	check(int(first.mission.status()["turn"]) == _won_turn, "4. decided on that turn")
	# The same seed, played again, ends the same way.
	var again := StrikePlay.new("strike", _won_seed)
	var r2: Dictionary = again.play("bomb", _limit + 2)
	eq(r2["state"], Mission.WON, "4. the same seed wins again")
	eq(int(r2["turn"]), _won_turn, "4. on the same turn")
	near(float(r2["t"]), float(first.mission.time), 1e-9, "4. at the same moment")
	eq(again.drops_made, _won_drops, "4. with the same drops")

# --- 5. Local, through the menu ----------------------------------------------------------------------------

func _until(cond: Callable, max_frames: int = 3000) -> bool:
	for i in max_frames:
		if cond.call():
			return true
		await get_tree().physics_frame
	return cond.call()

func _local() -> bool:
	_main.setup_menu()
	check(_main.menu.visible, "5. the menu is up")
	var sel: OptionButton = _main.scenario_select
	if not check(sel != null, "5. the menu has a scenario selector"):
		return false
	eq(sel.item_count, 3, "5. it lists the three scenarios")
	eq(str(sel.get_item_metadata(sel.selected)), "strike", "5. and shows the Strike (the knob says so)")
	eq(_main.selected_scenario(), "strike", "5. the Strike is what Local would start")
	# Intercept, chosen on the menu, is what Local starts; the knob follows the selector.
	sel.select(1)
	sel.item_selected.emit(1)
	eq(_main.selected_scenario(), "intercept", "5. choosing Intercept on the menu sets the scenario knob")
	check(_main.start_sandbox(), "5. Local builds the sandbox")
	if _main.sandbox == null:
		return false
	eq(_main.sandbox.scenario.id, "intercept", "5. and it is the first fight")
	check(not _main.sandbox.clock.visible, "5. (which has no turn limit, so no turn clock)")
	_main.stop_sandbox()
	check(_main.menu.visible, "5. Esc brings the menu back")
	sel.select(0)
	sel.item_selected.emit(0)
	eq(_main.selected_scenario(), "strike", "5. choosing the Strike again")

	check(_main.start_sandbox(), "5. Local builds the sandbox")
	var sb: Node = _main.sandbox
	if sb == null:
		return false
	eq(sb.scenario.id, "strike", "5. Local starts the Strike")
	sb.scenario.view["result_card_delay_s"] = 0.1
	var playable := await _until(func() -> bool: return sb.is_playable)
	if not check(playable, "5. the sandbox becomes playable"):
		return false
	var w: World = sb.world
	eq(w.units.size(), 7, "5. seven units")
	check(sb.ai is AiPilot, "5. Local attaches the pilot")
	check(sb.mission != null and sb.mission.state == Mission.PLAYING, "5. and the mission, playing")
	check(sb.objective != null, "5. the target ring is on the map")
	if sb.objective != null:
		var ring: Dictionary = sb.objective.screen_ring()
		check(not ring.is_empty() and float(ring["radius_px"]) >= 9.0, "5. drawn at least %.0f px across" % (float(ring.get("radius_px", 0.0)) * 2.0))
		check(sb.objective.shown(), "5. and shown while the tower stands")
		eq(sb.objective.label, "TARGET", "5. with its word")
	eq(sb.ui.roster.rows().size(), 3, "5. the roster lists the three player units, not the enemy's, not the ground's")
	check(sb.hint.headline.contains("STRIKE") and sb.hint.headline.contains("turn %d" % _limit), "5. the briefing is in the hint card, with the turn limit")
	check(sb.clock != null and sb.clock.visible, "5. the turn clock is up")
	eq(sb.clock.line(), "turn 1 of %d" % _limit, "5. reading: %s" % sb.clock.line())
	check(sb.hint.text.contains("B drops"), "5. and the key hint lists B (drop): %s" % sb.hint.text)
	# The camera: the HUD insets in.
	check(sb.ctl.insets.right > 0.0 and is_equal_approx(sb.ctl.insets.right, float(sb.ui.hud_insets()["right"])), "5. the camera has the HUD insets")
	# The opening view frames the players AND the village, and never the enemy's plan.
	sb._frame_start_view()
	var view: Rect2 = sb.ctl.visible_rect_px()
	var ppm: float = sb.map_view.px_per_m
	for id in [BOMBER, LIGHT, HEAVY]:
		check(view.has_point(Vector2(float(w.units[id].x), float(w.units[id].y)) * ppm), "5. %s is in the opening view" % id)
	var tower_m := Vector2(float(w.units[TOWER].x), float(w.units[TOWER].y))
	check(view.has_point(tower_m * ppm), "5. so is the radio tower")
	var layout: RefCounted = WorldLayout.shared(int(sb.scenario.seed_value))
	var village: Dictionary = layout.village()
	check(view.has_point((village["centre"] as Vector2) * ppm), "5. and the village's middle")
	var inside := 0
	for q: Vector2 in (village["polygon"] as PackedVector2Array):
		if view.has_point(q * ppm):
			inside += 1
	check(inside >= (village["polygon"] as PackedVector2Array).size() * 3 / 4, "5. and most of the village's outline (%d of %d points)" % [inside, (village["polygon"] as PackedVector2Array).size()])
	# The enemy's plan is not what framed it: moving the patrol's plan elsewhere moves nothing.
	var view_before: Rect2 = sb.ctl.visible_rect_px()
	var patrol_plan: Array = (w.units[PATROL].plan as Array).duplicate(true)
	w.units[PATROL].plan = []
	sb._frame_start_view()
	var view_after: Rect2 = sb.ctl.visible_rect_px()
	check(view_before.position.distance_to(view_after.position) < 1e-6 and view_before.size.distance_to(view_after.size) < 1e-6, "5. the opening view does not depend on the patrol's plan (the AI's plan is never framed)")
	w.units[PATROL].plan = patrol_plan
	# The fog hides the enemy and the village's guns; the players' own planes show.
	sb.ui.marker_layer.update_poses()
	for id in [BOMBER, LIGHT, HEAVY]:
		check(sb.ui.marker_layer.marker(id).visible, "5. %s is shown" % id)
	for id in [PATROL, TOWER, AA1, AA2]:
		check(not sb.ui.marker_layer.marker(id).visible, "5. %s is in the fog" % id)

	# Played through the interface: the scripted bombing run on the seed that won above.
	w.rng_seed = _won_seed
	var planner: RefCounted = StrikePlay.for_world(w)
	var ended: Array = []
	sb.mission_ended.connect(func(res: Dictionary) -> void: ended.append(res))
	var shown: Array = []
	sb.result_shown.connect(func(res: Dictionary) -> void: shown.append(res))
	var last_turn := 0
	var tracked_ok := false
	for n in _limit + 2:
		var ready_for_orders := await _until(func() -> bool: return sb.result_decided() or (w.phase == World.PHASE_PLANNING and not sb.ui.is_playing() and w.turn > last_turn))
		if not ready_for_orders or sb.result_decided():
			break
		last_turn = w.turn
		planner.plan_players()
		sb.ui.press_ready()
		if last_turn == 2:
			# After the first resolved turn the flown tracks exist for the planes, never for the ground units.
			tracked_ok = sb.tracks.tracks.has(BOMBER) and not sb.tracks.tracks.has(TOWER) and not sb.tracks.tracks.has(AA1)
	check(tracked_ok, "5. the flown tracks are the planes' (a tower and a battery have none)")
	eq(ended.size(), 1, "5. the mission ended once")
	if ended.is_empty():
		return false
	eq(ended[0]["state"], Mission.WON, "5. won: the tower is down (the seed that won in section 4, played through the interface)")
	eq(int(ended[0]["turn"]), _won_turn, "5. on the same turn as the scripted run without an interface")
	eq(sb.result["state"], Mission.WON, "5. the sandbox keeps the result")
	var card_up := await _until(func() -> bool: return sb.result_card_shown())
	check(card_up, "5. the result card is put up after the playback")
	check(not sb.ui.is_playing(), "5. (the deciding turn has been played back first)")
	eq(shown.size(), 1, "5. once")
	check(sb.ui.input_locked(), "5. the card locks planning input")
	check(sb.ui.result_card != null and sb.ui.result_card.is_showing(), "5. and shows")
	eq(str(sb.ui.result_card.result.get("state", "")), "won", "5. the card has the verdict")
	eq(sb.ui.result_card.reason_text(), "the radio tower is destroyed", "5. and says why: %s" % sb.ui.result_card.reason_text())
	check(not sb.objective.shown(), "5. the target ring is gone with the tower")
	await get_tree().physics_frame

	# Play again: a fresh Strike in its place.
	var old_id := sb.get_instance_id()
	sb.ui.result_card.play_again.emit()
	var swapped := await _until(func() -> bool: return _main.sandbox != null and _main.sandbox.get_instance_id() != old_id)
	if not check(swapped, "5. Play again replaces the sandbox"):
		return false
	var fresh: Node = _main.sandbox
	eq(fresh.scenario.id, "strike", "5. with the same scenario")
	eq(fresh.world.turn, 1, "5. a new game on turn 1")
	eq(fresh.mission.state, Mission.PLAYING, "5. whose mission is playing again")
	check(fresh.result.is_empty() and not fresh.ui.input_locked(), "5. with no result and no card")
	check(not fresh.world.units[TOWER].down and fresh.world.units[TOWER].health == fresh.world.units[TOWER].def.health, "5. and a standing tower")
	check(not _main.menu.visible, "5. and the menu stays hidden")
	var again := await _until(func() -> bool: return fresh.is_playable)
	check(again, "5. and it becomes playable")
	fresh.ui.result_card.menu.emit()
	var back := await _until(func() -> bool: return _main.sandbox == null)
	check(back, "5. Menu leaves the sandbox")
	check(_main.menu.visible, "5. and brings the menu back")
	return true

# --- 6. Over the net -----------------------------------------------------------------------------------------

func _arm(role: String) -> void:
	var sb: Node = _boxes[role]
	sb.scenario.view["result_card_delay_s"] = 0.1
	sb.restart_requested.connect(_replace.bind(role), CONNECT_DEFERRED)

# What main.gd's restart_sandbox does, under a rig peer's root: the old one out of the tree first (the new
# one must be named "Sandbox" again: the node path is the address of the RPCs), a new one in its place.
func _replace(role: String) -> void:
	var old: Node = _boxes[role]
	old.call("shutdown")
	(_roots[role] as Node).remove_child(old)
	old.queue_free()
	var nb: Node = Sandbox.new()
	nb.set("net_role", role)
	nb.set("announce_restart", role == "host")
	_boxes[role] = nb
	_arm(role)
	(_roots[role] as Node).add_child(nb)

func _net() -> bool:
	if _won_seed < 0:
		fail("6. no seed won the scripted run, so there is no game to play over the net")
		return false
	var h: NetRig.Peer = rig.add_host(PORT, "Hal", false)
	if not check(h != null, "6. the host binds port %d" % PORT):
		return false
	var c: NetRig.Peer = await rig.add_client(PORT, "Cy", false)
	if not check(c != null, "6. the client connects"):
		return false
	_roots = {"host": h.root, "client": c.root}
	var sb_h: Node = Sandbox.new()
	sb_h.set("net_role", "host")
	var sb_c: Node = Sandbox.new()
	sb_c.set("net_role", "client")
	_boxes = {"host": sb_h, "client": sb_c}
	_arm("host")
	_arm("client")
	h.root.add_child(sb_h)
	c.root.add_child(sb_c)
	if not check(bool(sb_h.ok()) and bool(sb_c.ok()), "6. both sandboxes build: %s %s" % [str(sb_h.errors), str(sb_c.errors)]):
		return false
	sb_h.world.rng_seed = _won_seed   # (only the host rolls; the client takes the seed from the host's snapshot)
	h.world = sb_h.world
	h.sync = sb_h.session.sync
	c.world = sb_c.world
	c.sync = sb_c.session.sync
	eq(sb_h.scenario.id, "strike", "6. Host starts the Strike")
	eq(sb_c.scenario.id, "strike", "6. and so does Join")
	check(sb_h.ai is AiPilot, "6. the pilot flies the patrol on the host")
	check(sb_c.ai == null, "6. and does not exist on the client: its World never plans the enemy")
	check((sb_h.world.units[PATROL].plan as Array).size() > 0, "6. the host has the patrol's plan")
	eq((sb_c.world.units[PATROL].plan as Array).size(), 0, "6. the client never gets it")
	check(sb_h.mission != null and sb_c.mission != null and sb_h.mission.state == Mission.PLAYING and sb_c.mission.state == Mission.PLAYING, "6. both machines judge the game")
	check(sb_h.hint.text.contains("B drops") and sb_c.hint.text.contains("B drops"), "6. both hint cards list B")
	var joined: bool = await rig.wait_until(func() -> bool: return sb_c.session.sync.is_joined() and sb_h.world.players.size() == 2)
	if not check(joined, "6. the client is welcomed"):
		return false
	check("strike" in sb_c.session.status_text() and "strike" in sb_h.session.status_text(), "6. both status lines say which scenario: %s" % sb_c.session.status_text())
	eq(sb_h.world.rng_seed, _won_seed, "6. the host rolls the winning seed")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "6. the client holds the host's game")

	# Play the scripted run to its end: the host plans all three planes (any player edits any plan: the plans go to the
	# client), both players ready, the host resolves. After every turn the two Worlds are the same, and the bombs
	# still falling at a turn's end are the client's too.
	var planner: RefCounted = StrikePlay.for_world(sb_h.world)
	var guard := 0
	var last := 0
	var in_flight_seen := 0
	var in_flight_same := true
	while guard < _limit + 2 and not (sb_h.result_decided() and sb_c.result_decided()):
		guard += 1
		var up: bool = await rig.wait_until(func() -> bool:
			return (sb_h.result_decided() and sb_c.result_decided()) or (sb_h.world.phase == World.PHASE_PLANNING and sb_c.world.phase == World.PHASE_PLANNING \
				and sb_h.world.turn == sb_c.world.turn and sb_h.world.turn > last and not sb_h.ui.is_playing() and not sb_c.ui.is_playing()), 4000)
		if not check(up, "6. both machines reach the planning phase of the turn after %d" % last):
			return false
		# What the turn that just ended left in the air: the same on both machines.
		if not sb_h.world.bombs_in_flight.is_empty():
			in_flight_seen += 1
			var same_air: bool = await rig.wait_until(func() -> bool: return WorldSync.same(sb_h.world.net_bombs(), sb_c.world.net_bombs()), 2000)
			if not same_air:
				in_flight_same = false
				fail("6. turn %d: the bombs in flight differ: host %s against client %s" % [last, str(sb_h.world.net_bombs()), str(sb_c.world.net_bombs())])
		if sb_h.result_decided() and sb_c.result_decided():
			break
		last = sb_h.world.turn
		planner.plan_players()
		var planned: bool = await rig.wait_until(func() -> bool:
			for id: String in [BOMBER, LIGHT, HEAVY]:
				if not WorldSync.same(sb_h.world.units[id].plan, sb_c.world.units[id].plan):
					return false
			return true, 2000)
		if not check(planned, "6. the client sees the plans for turn %d" % last):
			return false
		sb_c.ui.press_ready()
		sb_h.ui.press_ready()
	var both: bool = await rig.wait_until(func() -> bool: return sb_h.result_decided() and sb_c.result_decided(), 4000)
	if not check(both, "6. the mission ends on both machines"):
		return false
	check(in_flight_seen >= 1, "6. bombs were still falling at the end of %d turn(s) of the game" % in_flight_seen)
	check(in_flight_same, "6. and the client held the same bombs in the air each time")
	eq(sb_c.result["state"], sb_h.result["state"], "6. the client ends in the host's state")
	eq(sb_c.result["state"], Mission.WON, "6. (won: the scripted run on the winning seed)")
	eq(sb_c.result["turn"], sb_h.result["turn"], "6. on the same turn")
	eq(int(sb_h.result["turn"]), _won_turn, "6. which is the turn the run without a network won on")
	eq(sb_c.result["reason"], sb_h.result["reason"], "6. for the same reason")
	near(float(sb_c.result["t"]), float(sb_h.result["t"]), 1e-9, "6. at the same moment")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "6. the Worlds are the same at the end")
	check(WorldSync.same(sb_h.world.net_bombs(), sb_c.world.net_bombs()), "6. and the bombs in the air")
	check(sb_c.world.units[TOWER].down and sb_c.world.units[TOWER].health == sb_h.world.units[TOWER].health, "6. the tower is down on the client too, with the host's health")
	eq(sb_c.world.units[TOWER].fate, sb_h.world.units[TOWER].fate, "6. and the same fate")
	for id: String in [AA1, AA2, PATROL, BOMBER, LIGHT, HEAVY]:
		eq(sb_c.world.units[id].health, sb_h.world.units[id].health, "6. %s has the same health on both machines" % id)
	var cards: bool = await rig.wait_until(func() -> bool: return sb_h.result_card_shown() and sb_c.result_card_shown(), 4000)
	check(cards, "6. both machines put the card up")
	check(sb_h.ui.result_card.is_showing() and sb_c.ui.result_card.is_showing(), "6. and it shows on both")
	eq(sb_c.ui.result_card.reason_text(), "the radio tower is destroyed", "6. the client's card says why")

	# A player who walks into the finished game never saw the tower fall: her mission is decided from the snapshot, and
	# the tower's ruin is put back on her effects layer (it is a fact of the map).
	check(sb_h.ui.fx.stats()["ruins"] >= 1, "6. the host's layer holds the tower's ruin (%s)" % str(sb_h.ui.fx.stats()))
	var dee: NetRig.Peer = await rig.add_client(PORT, "Dee", false)
	if not check(dee != null, "6. a late player connects"):
		return false
	var sb_d: Node = Sandbox.new()
	sb_d.set("net_role", "client")
	sb_d.scenario.view["result_card_delay_s"] = 0.1
	dee.root.add_child(sb_d)
	dee.world = sb_d.world
	dee.sync = sb_d.session.sync
	var dee_in: bool = await rig.wait_until(func() -> bool: return sb_d.session.sync.is_joined() and sb_d.result_decided(), 4000)
	check(dee_in, "6. a player who joins the finished game has its result decided on joining")
	if sb_d.result_decided():
		eq(sb_d.result["state"], sb_h.result["state"], "6. the same verdict as the host's")
		eq(sb_d.result["turn"], sb_h.result["turn"], "6. for the same turn")
	eq(int(sb_d.ui.fx.stats()["ruins"]), 1, "6. and the radio tower's ruin is on her map (restored from the snapshot)")
	check(not sb_d.ui.marker_layer.marker(TOWER).visible, "6. with no tower standing")
	var dee_card: bool = await rig.wait_until(func() -> bool: return sb_d.result_card_shown(), 2000)
	check(dee_card, "6. and she gets the card")
	sb_d.shutdown()
	sb_d.queue_free()
	rig.drop(dee)
	var gone: bool = await rig.wait_until(func() -> bool: return sb_h.world.players.size() == 2, 2000)
	check(gone, "6. (she leaves again)")

	# Play again from the CLIENT: it asks the host, the host replaces its sandbox and tells the client to replace its own.
	var old_h := sb_h.get_instance_id()
	var old_c := sb_c.get_instance_id()
	sb_c.ui.result_card.play_again.emit()
	var swapped: bool = await rig.wait_until(func() -> bool: return _boxes["host"].get_instance_id() != old_h and _boxes["client"].get_instance_id() != old_c, 4000)
	if not check(swapped, "6. the client's Play again replaces BOTH sandboxes"):
		return false
	var nh: Node = _boxes["host"]
	var nc: Node = _boxes["client"]
	check(nh.ok() and nc.ok(), "6. the new sandboxes build")
	h.world = nh.world
	h.sync = nh.session.sync
	c.world = nc.world
	c.sync = nc.session.sync
	eq(nh.scenario.id, "strike", "6. the new host game is the Strike again")
	eq(nc.scenario.id, "strike", "6. and so is the client's")
	var rejoined: bool = await rig.wait_until(func() -> bool: return nc.session.sync.is_joined() and nh.world.players.size() == 2, 4000)
	check(rejoined, "6. the client joins the new game as it joined the first")
	eq(nh.world.turn, 1, "6. a new game on turn 1")
	check(nh.mission.state == Mission.PLAYING and nc.mission.state == Mission.PLAYING, "6. both missions playing again")
	check(nh.result.is_empty() and nc.result.is_empty(), "6. no result")
	check(not nh.world.units[TOWER].down and not nc.world.units[TOWER].down, "6. the tower stands on both")
	await rig.wait_until(func() -> bool: return rig.differences_from_host(c) == "")
	eq(rig.differences_from_host(c), "", "6. the client holds the new host game")
	check((nh.world.units[PATROL].plan as Array).size() > 0 and (nc.world.units[PATROL].plan as Array).size() == 0, "6. the enemy's plan is on the host only, again")

	for role: String in ["client", "host"]:
		var sb: Node = _boxes[role]
		sb.shutdown()
		sb.queue_free()
	rig.close_all()
	await get_tree().process_frame
	return true
