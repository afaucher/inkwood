extends "res://scripts/test_support/test_case.gd"

# THE ENEMY AI'S STATES (Track E, scripts/sim/ai_pilot.gd and helpers): the
# bomber flies its route, holds its band and weaves when alarmed; the escort
# holds station, engages an enemy that comes within its radii, breaks off by each
# of its rules and returns to station; the AI knows an enemy only inside sight
# (and remembers it a few turns); it never reads a player's plan; it is
# deterministic and stays on the map.
#
# Combat is live in the World (Track C) and is NOT what is under test: every unit
# gets a large health so a stray hit cannot change a scenario. The one test that
# wants a hurt unit lowers its health by hand. Rules are isolated by changing one
# data value after loading (ai.params.set_value), exactly as a tuning change would.

const World = preload("res://scripts/sim/world.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const AiCone = preload("res://scripts/sim/ai_cone.gd")

# THE PROPOSED INTERCEPT ROUTE (Track E; reported to Alex): the bomber starts at
# START flying towards the first waypoint and reaches the target (the last point)
# on turn 12 at cruise. Every point is more than the edge margin (about 730 m)
# from the map edge.
const START := Vector2(800.0, 900.0)
const ROUTE := [[2300.0, 1000.0], [3500.0, 1900.0], [3600.0, 3900.0]]

const TOUGH := 100000

# A wide-open spy: it records every call the AI makes that names a unit and could
# read that unit's plan (or steer it).
class SpyWorld extends "res://scripts/sim/world.gd":
	var calls: Array = []     # [method, unit id], recorded only while `recording`
	var recording := false    # the test switches it on around the AI's planning, not around its own calls or a resolve

	func planned_states(unit_id: String) -> Array:
		if recording:
			calls.append(["planned_states", unit_id])
		return super.planned_states(unit_id)

	func reachable(unit_id: String, step_index: int) -> Dictionary:
		if recording:
			calls.append(["reachable", unit_id])
		return super.reachable(unit_id, step_index)

	func sample(unit_id: String, t: float, source: String = "history") -> Dictionary:
		if recording:
			calls.append(["sample", unit_id])
		return super.sample(unit_id, t, source)

	func plan_step(unit_id: String, step_index: int, request: Variant) -> Dictionary:
		if recording:
			calls.append(["plan_step", unit_id])
		return super.plan_step(unit_id, step_index, request)

	func clear_plan(unit_id: String) -> void:
		if recording:
			calls.append(["clear_plan", unit_id])
		super.clear_plan(unit_id)

func setup(_main) -> void:
	timeout_seconds = 60.0
	_data()
	_assignments()
	_bomber_route()
	_bomber_evades()
	_escort_holds_station()
	_escort_engages()
	_break_off_leash()
	_break_off_no_chance()
	_break_off_health()
	_protected_unit_down()
	_sight_and_memory()
	_down_units_are_skipped()
	_never_reads_a_players_plan()
	_determinism()
	_stays_on_the_map()
	finish()

# --- Scenario helpers -----------------------------------------------------------

# A point `fwd` metres ahead of and `rgt` metres to the right of a unit-like
# {x, y, heading}.
func _rel(b: Variant, fwd: float, rgt: float) -> Vector2:
	var h := float(b.heading)
	return Vector2(float(b.x) + cos(h) * fwd - sin(h) * rgt, float(b.y) + sin(h) * fwd + cos(h) * rgt)

func _start_heading() -> float:
	return atan2(float(ROUTE[0][1]) - START.y, float(ROUTE[0][0]) - START.x)

# The formation: an AI bomber at START heading for the route and an AI escort
# fighter on its station, in `band`; plus any extra units. `enemy`, if given:
# {fwd, rgt, dh (heading relative to the bomber's), speed, band, type, id}.
func _formation(enemy: Dictionary = {}, band := "medium", esc_type := "light_fighter", world: World = null) -> World:
	var w: World = world if world != null else World.new()
	check(w.ok(), "the world's data loads: %s" % str(w.errors))
	w.add_player("local")
	var h := _start_heading()
	var b := {"x": START.x, "y": START.y, "heading": h}
	eq(w.add_unit({"id": "bomber_1", "type": "bomber", "side": "axis", "controller": "ai", "x": START.x, "y": START.y, "heading": h, "altitude_band": band}), "bomber_1", "the bomber is added")
	var ai_params := AiPilot.new()
	var st := _rel(b, ai_params.params.num("escort", "station_forward_m"), ai_params.params.num("escort", "station_right_m"))
	eq(w.add_unit({"id": "escort_1", "type": esc_type, "side": "axis", "controller": "ai", "x": st.x, "y": st.y, "heading": h, "altitude_band": band}), "escort_1", "the escort is added")
	if not enemy.is_empty():
		var p := _rel(b, float(enemy["fwd"]), float(enemy["rgt"]))
		var id := str(enemy.get("id", "p1"))
		eq(w.add_unit({"id": id, "type": enemy.get("type", "light_fighter"), "side": "allies", "controller": "player", "x": p.x, "y": p.y,
			"heading": h + float(enemy["dh"]), "speed": enemy.get("speed", 100.0), "altitude_band": enemy.get("band", band)}), id, "the enemy is added")
	for id: String in w.units:
		w.units[id].health = TOUGH
	return w

func _orders() -> Dictionary:
	return {"bomber_1": {"role": "strike", "route": ROUTE}, "escort_1": {"role": "escort", "protect": "bomber_1"}}

# Attach a pilot, with `tweak` ({section.key: value}) applied to its data first.
func _pilot(w: World, tweak: Dictionary = {}) -> AiPilot:
	var ai := AiPilot.new()
	check(ai.ok(), "the AI's data loads: %s" % str(ai.errors))
	for k: String in tweak:
		var parts := k.split(".")
		ai.params.set_value(parts[0], parts[1], tweak[k])
	check(ai.attach(w, _orders()), "the pilot attaches: %s" % str(ai.errors))
	return ai

# One turn: the local player readies, the world resolves, the next turn begins
# (the AI plans on the phase change).
func _turn(w: World) -> Dictionary:
	w.commit("local")
	var res := w.resolve()
	check(not res.is_empty(), "the turn resolves: %s" % w.last_error)
	return res

func _next(w: World) -> void:
	w.begin_turn()

func _dist(a: Variant, b: Variant) -> float:
	return Vector2(float(a.x) - float(b.x), float(a.y) - float(b.y)).length()

# Seconds of the last resolved turn in which `target` was inside `shooter`'s
# forward cone, on the resolved paths sampled every quarter second.
func _contact(w: World, ai: AiPilot, shooter: String, target: String) -> float:
	var cone := ai.cone_of(shooter)
	var total := 0.0
	var tt := 0.0
	while tt <= 5.0 + 1e-9:
		var a := w.sample(shooter, tt, "history")
		var b := w.sample(target, tt, "history")
		if AiCone.contains(cone, a["x"], a["y"], a["heading"], a["height_m"], b["x"], b["y"], b["height_m"]):
			total += 0.25
		tt += 0.25
	return total

func _transitions(ai: AiPilot, unit: String) -> Array:
	return ai.transitions.filter(func(t: Dictionary) -> bool: return str(t["unit"]) == unit)

func _transition_to(ai: AiPilot, unit: String, to: String, reason: String = "") -> Dictionary:
	for t: Dictionary in ai.transitions:
		if str(t["unit"]) == unit and str(t["to"]) == to and (reason == "" or str(t["reason"]) == reason):
			return t
	return {}

# --- Data and assignments --------------------------------------------------------

func _data() -> void:
	var ai := AiPilot.new()
	check(ai.ok(), "data/sim/ai.json loads: %s" % str(ai.errors))
	# A file with a value missing and a value with no provenance is refused, with
	# both problems named.
	var src: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/ai.json"))
	(src["escort"] as Dictionary).erase("leash_m")
	(src["strike"] as Dictionary)["capture_radius_m"] = {"value": 300}
	DirAccess.make_dir_recursive_absolute("res://tmp")
	var path := "res://tmp/test_ai_states_bad.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(src))
	f.close()
	var bad := AiPilot.new(path, true)
	check(not bad.ok(), "a file with a missing value and a bare number is refused")
	var joined := " | ".join(bad.errors)
	check(joined.contains("escort.leash_m"), "the missing value is named: %s" % joined)
	check(joined.contains("strike.capture_radius_m"), "and so is the one with no provenance")
	var w := _formation()
	check(not bad.attach(w, _orders()), "a pilot with bad data attaches to nothing")
	eq(w.units["bomber_1"].plan.size(), 0, "and plans nothing")
	DirAccess.remove_absolute(path)

func _assignments() -> void:
	var w := _formation({"fwd": 3000.0, "rgt": 0.0, "dh": PI})
	var ai := AiPilot.new("res://data/sim/ai.json", true)
	var ok := ai.attach(w, {
		"bomber_1": {"role": "strike", "route": ROUTE},
		"escort_1": {"role": "escort", "protect": "bomber_1"},
		"ghost": {"role": "strike", "target": [1.0, 1.0]},
		"p1": {"role": "strike", "target": [1.0, 1.0]},
	})
	check(not ok, "unknown and player-controlled units are refused")
	eq(ai.errors.size(), 2, "one error each: %s" % str(ai.errors))
	check(ai.assignments.has("bomber_1") and ai.assignments.has("escort_1"), "the good orders stand")
	check(not ai.assignments.has("p1") and not ai.assignments.has("ghost"), "the bad ones do not")
	eq(w.units["p1"].plan.size(), 0, "the AI did not plan a player's unit")
	check(w.units["bomber_1"].plan.size() > 0, "and it planned its own")
	var cases: Array = [
		["a strike with neither route nor target", "bomber_1", {"role": "strike"}],
		["a route point that is not a point", "bomber_1", {"role": "strike", "route": [[1.0]]}],
		["an escort with no protect", "escort_1", {"role": "escort"}],
		["an escort protecting a player's unit", "escort_1", {"role": "escort", "protect": "p1"}],
		["an escort protecting itself", "escort_1", {"role": "escort", "protect": "escort_1"}],
		["an unknown role", "escort_1", {"role": "patrol"}],
		["a band the type cannot hold", "bomber_1", {"role": "strike", "target": [2000.0, 2000.0], "band": "surface"}],
		["orders that are not a Dictionary", "bomber_1", "strike"],
	]
	for c: Array in cases:
		check(not ai.assign(str(c[1]), c[2]), "%s is refused" % c[0])
	# A route that does not end at the target gets the target appended; a target alone is a route.
	check(ai.assign("bomber_1", {"role": "strike", "route": [[2000.0, 1000.0]], "target": [3000.0, 2000.0]}), "a route and a target")
	eq((ai.assignments["bomber_1"]["route"] as Array).size(), 2, "the target is appended to a route that stops short")
	check(ai.assign("bomber_1", {"role": "strike", "target": [3000.0, 2000.0]}), "a target alone")
	eq((ai.assignments["bomber_1"]["route"] as Array).size(), 1, "is a route of one point")
	# A waypoint in the edge margin draws a warning, not a refusal.
	var n_warn := ai.warnings.size()
	check(ai.assign("bomber_1", {"role": "strike", "target": [4900.0, 2500.0]}), "a target near the edge is accepted")
	eq(ai.warnings.size(), n_warn + 1, "with a warning: %s" % str(ai.warnings.back()))

# --- The bomber -------------------------------------------------------------------

func _path_length() -> float:
	var total := 0.0
	var prev := START
	for pt: Array in ROUTE:
		var p := Vector2(float(pt[0]), float(pt[1]))
		total += prev.distance_to(p)
		prev = p
	return total

# Unopposed, the bomber follows its route and reaches the target in the number of
# turns its speed allows, holding its band, off the weave, inside the map.
func _bomber_route() -> void:
	var w := World.new()
	check(w.ok(), "the world loads")
	eq(w.add_unit({"id": "bomber_1", "type": "bomber", "side": "axis", "controller": "ai", "x": START.x, "y": START.y, "heading": _start_heading()}), "bomber_1", "the bomber is added")
	var ai := AiPilot.new()
	check(ai.attach(w, {"bomber_1": {"role": "strike", "route": ROUTE}}), "attached: %s" % str(ai.errors))
	check(ai.warnings.is_empty(), "no waypoint is inside the edge margin: %s" % str(ai.warnings))
	eq(ai.state_of("bomber_1"), AiPilot.S_ROUTE, "it starts on its route")
	var u: Variant = w.units["bomber_1"]
	var band0: String = u.altitude_band
	eq(band0, "high", "it holds the band it starts in (the type's: high)")
	var cap := ai.params.num("strike", "capture_radius_m")
	var target := Vector2(float(ROUTE[ROUTE.size() - 1][0]), float(ROUTE[ROUTE.size() - 1][1]))
	var cruise: float = u.def.envelope.speed_cruise
	var vmax: float = u.def.envelope.speed_max
	var turn_m := cruise * w.rules.turn_seconds
	var arrival := -1
	var min_to_wp: Array = []
	for pt in ROUTE:
		min_to_wp.append(INF)
	var min_speed := INF
	var left_bounds := 0
	var edge_turns := 0
	var bands_seen := {}
	for turn_no in 16:
		var res := w.resolve()
		if not check(not res.is_empty(), "turn %d resolves: %s" % [turn_no + 1, w.last_error]):
			return
		for ev: Dictionary in res["events"]:
			if str(ev["type"]) == "left_bounds":
				left_bounds += 1
		for s: Dictionary in u.history:
			var p := Vector2(float(s["x"]), float(s["y"]))
			bands_seen[str(s["altitude_band"])] = true
			min_speed = minf(min_speed, float(s["speed"]))
			for i in ROUTE.size():
				min_to_wp[i] = minf(float(min_to_wp[i]), p.distance_to(Vector2(float(ROUTE[i][0]), float(ROUTE[i][1]))))
			if arrival < 0 and p.distance_to(target) <= cap:
				arrival = turn_no + 1
		if ai.info("bomber_1")["edge"]:
			edge_turns += 1
		if arrival >= 0:
			break
		w.begin_turn()
	var length := _path_length()
	var lo := int(floor((length - cap) / (vmax * w.rules.turn_seconds)))
	var hi := int(ceil((length - cap) / turn_m)) + 2
	print("  bomber: route %.0f m, reaches the target's %.0f m circle on turn %d (bounds %d..%d)" % [length, cap, arrival, lo, hi])
	check(arrival >= lo and arrival <= hi, "the bomber reaches the target in the turns its speed allows (%d, expected %d..%d)" % [arrival, lo, hi])
	check(arrival >= 11 and arrival <= 13, "the proposed route is about a 12-turn mission (turn %d)" % arrival)
	for i in ROUTE.size():
		check(float(min_to_wp[i]) <= cap, "it came within the capture radius of waypoint %d (%.0f m)" % [i + 1, float(min_to_wp[i])])
	eq(bands_seen.keys(), [band0], "it held its band the whole way")
	check(min_speed >= 0.85 * cruise, "it stayed near cruise speed (slowest %.1f of %.0f m/s)" % [min_speed, cruise])
	eq(left_bounds, 0, "it never left the map")
	eq(edge_turns, 0, "and its edge-safety never had to turn it")
	var kinds := _transitions(ai, "bomber_1").map(func(t: Dictionary) -> String: return str(t["to"]))
	eq(kinds, [AiPilot.S_ARRIVED], "its only transition is route -> arrived")
	# It does not chase: with nothing else in the world there was nobody to chase, and
	# it never evaded.
	check(not kinds.has(AiPilot.S_EVADE), "no alarm while nothing was near")

# A threat near the bomber makes it weave and move to the band farthest from it;
# a hit does the same with nothing in sight; it settles back after evade_turns.
func _bomber_evades() -> void:
	# An enemy in the bomber's own band, flying past it at 300 m.
	var w := _formation({"fwd": 500.0, "rgt": -200.0, "dh": PI, "speed": 100.0, "band": "high"}, "high")
	var ai := _pilot(w)
	var bomber: Variant = w.units["bomber_1"]
	var info := ai.info("bomber_1")
	eq(info["state"], AiPilot.S_EVADE, "an enemy within the threat radius: the bomber evades")
	eq(info["reason"], AiPilot.R_THREAT, "because of a threat")
	# Its plan weaves: it does not just head for the waypoint.
	var plan_states := w.planned_states("bomber_1")
	var bearing := atan2(float(ROUTE[0][1]) - bomber.y, float(ROUTE[0][0]) - bomber.x)
	var worst := 0.0
	for s: Dictionary in plan_states:
		worst = maxf(worst, absf(wrapf(float(s["heading"]) - bearing, -PI, PI)))
	check(worst > deg_to_rad(8.0), "the plan swings off the route bearing (%.1f degrees)" % rad_to_deg(worst))
	check(worst < deg_to_rad(45.0), "but stays near it (%.1f degrees)" % rad_to_deg(worst))
	# Band: the enemy is in the bomber's band (high); the farthest band within one band
	# of it is medium.
	_turn(w)
	eq(bomber.altitude_band, "medium", "after one turn it has dived out of the enemy's band, and no further")
	# The enemy flew on, out of the threat radius; after the calm turns it is back on
	# its route, and climbs back to its band as its speed allows (a climb costs a
	# bomber 35 m/s a band).
	var back_on_route := false
	var turns_to_band := 0
	for i in 16:
		turns_to_band += 1
		_next(w)
		_turn(w)
		if ai.state_of("bomber_1") == AiPilot.S_ROUTE and bomber.altitude_band == "high":
			back_on_route = true
			break
	check(back_on_route, "later it is back on its route and in its band (state %s, band %s)" % [ai.state_of("bomber_1"), bomber.altitude_band])
	print("  bomber: evaded an enemy in its band, back on route and band %d turns later" % turns_to_band)
	var calm := _transition_to(ai, "bomber_1", AiPilot.S_ROUTE, AiPilot.R_CALM)
	check(not calm.is_empty(), "the return to the route is a recorded transition")

	# A hit with nothing in sight raises the alarm too.
	var w2 := _formation()
	var ai2 := _pilot(w2)
	eq(ai2.state_of("bomber_1"), AiPilot.S_ROUTE, "calm: on its route")
	_turn(w2)
	_next(w2)
	eq(ai2.state_of("bomber_1"), AiPilot.S_ROUTE, "still calm")
	_turn(w2)
	w2.units["bomber_1"].health -= 1
	_next(w2)
	eq(ai2.state_of("bomber_1"), AiPilot.S_EVADE, "its health fell: it evades")
	eq(ai2.info("bomber_1")["reason"], AiPilot.R_HIT, "because it was hit")
	# Evading keeps the band when there is no threat to be farthest from.
	eq(w2.units["bomber_1"].altitude_band, "medium", "no threat to dive away from: it holds its band")

# --- The escort: station ------------------------------------------------------------

func _escort_holds_station() -> void:
	var w := _formation()
	var ai := _pilot(w)
	var tol := ai.params.num("escort", "station_tolerance_m")
	var fwd := ai.params.num("escort", "station_forward_m")
	var rgt := ai.params.num("escort", "station_right_m")
	var worst := 0.0
	var worst_turn := 0
	var b: Variant = w.units["bomber_1"]
	var e: Variant = w.units["escort_1"]
	for turn_no in 10:
		_turn(w)
		var st := _rel(b, fwd, rgt)
		var err := Vector2(float(e.x), float(e.y)).distance_to(st)
		if turn_no >= 1 and err > worst:
			worst = err
			worst_turn = turn_no + 1
		eq(e.altitude_band, b.altitude_band, "turn %d: the escort flies in the bomber's band" % (turn_no + 1))
		_next(w)
	print("  escort: worst distance from its station over turns 2..10: %.0f m (turn %d), tolerance %.0f m" % [worst, worst_turn, tol])
	check(worst <= 1.5 * tol, "the escort holds its station to within one and a half tolerances (worst %.0f m of %.0f m)" % [worst, 1.5 * tol])
	eq(ai.state_of("escort_1"), AiPilot.S_STATION, "it is still on station")
	eq(_transitions(ai, "escort_1").size(), 0, "and never left it")
	# On the right-hand side of the bomber, as the data says.
	var lateral := (Vector2(float(e.x), float(e.y)) - Vector2(float(b.x), float(b.y))).dot(Vector2(-sin(b.heading), cos(b.heading)))
	check(lateral > 0.0, "on the bomber's right (%.0f m abeam)" % lateral)

# --- The escort: engage -------------------------------------------------------------

# An enemy crosses in front of the formation. The escort sees it, engages it,
# steers its nose onto it (the target really is in the cone for a good part of two
# turns), and the bomber evades and keeps clear in height.
func _escort_engages() -> void:
	var w := _formation({"fwd": 800.0, "rgt": 900.0, "dh": -PI / 2.0, "speed": 100.0, "band": "high"}, "medium")
	var ai := _pilot(w)
	var engage_turn := -1
	var contact_total := 0.0
	var contact_turns := 0
	var seen_in_band := false
	var bomber_low := false
	var left := 0
	for turn_no in 5:
		var res := _turn(w)
		for ev: Dictionary in res["events"]:
			if str(ev["type"]) == "left_bounds" and ["escort_1", "bomber_1"].has(str(ev["unit"])):
				left += 1
		var c := _contact(w, ai, "escort_1", "p1")
		if c > 0.0:
			contact_total += c
			contact_turns += 1
		if w.units["escort_1"].altitude_band == "high":
			seen_in_band = true
		if w.units["bomber_1"].altitude_band == "low":
			bomber_low = true
		_next(w)
	var t := _transition_to(ai, "escort_1", AiPilot.S_ENGAGE, AiPilot.R_ENEMY)
	check(not t.is_empty(), "the escort engages the enemy that came within its radii")
	if not t.is_empty():
		engage_turn = int(t["turn"])
		check(engage_turn <= 3, "within a turn or two of it coming into sight (turn %d)" % engage_turn)
	check(ai.info("escort_1").get("target", "") == "p1" or _transition_to(ai, "escort_1", AiPilot.S_ENGAGE).get("detail", "").contains("p1"), "its target is the enemy fighter")
	print("  engage: the target was in the escort's cone for %.2f s over %d turns" % [contact_total, contact_turns])
	check(contact_total >= 3.0, "steering brought the target into the forward cone for at least 3 s (%.2f s)" % contact_total)
	check(seen_in_band, "the escort matched the target's altitude band (high)")
	check(bomber_low, "the bomber took the band farthest from the threat (low)")
	eq(left, 0, "neither left the map in the chase")

# --- The escort: breaking off ---------------------------------------------------------

# Leash: an enemy flies past and away to the west; the escort follows until it is
# farther than leash_m from the bomber, then breaks off. The no-chance rule is
# switched off so that only the leash can end it.
func _break_off_leash() -> void:
	var w := _formation({"fwd": 1500.0, "rgt": 150.0, "dh": PI, "speed": 100.0})
	var ai := _pilot(w, {"escort.no_chance_turns": 1000})
	var leash := ai.params.num("escort", "leash_m")
	var dist_at_plan := {}
	for turn_no in 9:
		dist_at_plan[w.turn] = _dist(w.units["escort_1"], w.units["bomber_1"])
		_turn(w)
		_next(w)
	var off := _transition_to(ai, "escort_1", AiPilot.S_RETURN, AiPilot.R_LEASH)
	check(not off.is_empty(), "the escort breaks off by the leash: %s" % str(_transitions(ai, "escort_1")))
	if not off.is_empty():
		var turn_off := int(off["turn"])
		check(float(dist_at_plan[turn_off]) > leash, "it was beyond the leash when it did (%.0f m of %.0f m)" % [float(dist_at_plan[turn_off]), leash])
		check(float(dist_at_plan[turn_off - 1]) <= leash, "and not the turn before (%.0f m)" % float(dist_at_plan[turn_off - 1]))
		check(_transition_to(ai, "escort_1", AiPilot.S_ENGAGE).get("turn", 99) < turn_off, "after engaging")
	check(ai.state_of("escort_1") == AiPilot.S_RETURN or ai.state_of("escort_1") == AiPilot.S_STATION, "and it is coming back or back")

# No chance: the enemy outruns the escort ahead of it and stays out of its cone
# range. After no_chance_turns engaged turns without a predicted firing chance the
# escort breaks off, then returns to its station. The leash is off so only the
# no-chance rule can end it.
func _break_off_no_chance() -> void:
	var w := _formation({"fwd": 330.0, "rgt": 250.0, "dh": 0.0, "speed": 160.0})
	var ai := _pilot(w, {"escort.leash_m": 1.0e9})
	var n := ai.params.whole("escort", "no_chance_turns")
	for turn_no in 14:
		_turn(w)
		_next(w)
	var on := _transition_to(ai, "escort_1", AiPilot.S_ENGAGE, AiPilot.R_ENEMY)
	var off := _transition_to(ai, "escort_1", AiPilot.S_RETURN, AiPilot.R_NO_CHANCE)
	check(not on.is_empty() and not off.is_empty(), "it engaged, then broke off by the no-chance rule: %s" % str(_transitions(ai, "escort_1")))
	if not on.is_empty() and not off.is_empty():
		eq(int(off["turn"]) - int(on["turn"]), n, "after exactly no_chance_turns (%d) engaged turns" % n)
	var home := _transition_to(ai, "escort_1", AiPilot.S_STATION, AiPilot.R_ON_STATION)
	check(not home.is_empty(), "then it returns to its station")
	eq(ai.state_of("escort_1"), AiPilot.S_STATION, "and holds it")
	var e: Variant = w.units["escort_1"]
	var b: Variant = w.units["bomber_1"]
	var tol := ai.params.num("escort", "station_tolerance_m")
	var st := _rel(b, ai.params.num("escort", "station_forward_m"), ai.params.num("escort", "station_right_m"))
	check(Vector2(float(e.x), float(e.y)).distance_to(st) <= 2.0 * tol, "it is near its station (%.0f m)" % Vector2(float(e.x), float(e.y)).distance_to(st))

# Health: below the fraction the escort breaks off an engagement, goes home, and
# stays there however close an enemy comes.
func _break_off_health() -> void:
	var w := _formation({"fwd": 800.0, "rgt": 900.0, "dh": -PI / 2.0, "speed": 100.0})
	var ai := _pilot(w, {"escort.leash_m": 1.0e9, "escort.no_chance_turns": 1000})
	for i in 2:
		_turn(w)
		_next(w)
	eq(ai.state_of("escort_1"), AiPilot.S_ENGAGE, "engaged after two turns")
	var e: Variant = w.units["escort_1"]
	var hp: int = e.def.health
	var frac := ai.params.num("escort", "break_off_health_fraction")
	# At exactly the fraction it still fights; one pip below, it breaks off.
	e.health = int(ceil(frac * float(hp)))
	ai.plan_turn()
	eq(ai.state_of("escort_1"), AiPilot.S_ENGAGE, "at the break-off fraction (%d of %d) it still fights" % [e.health, hp])
	e.health = int(ceil(frac * float(hp))) - 1
	ai.plan_turn()
	eq(ai.state_of("escort_1"), AiPilot.S_RETURN, "one pip below it breaks off (%d of %d)" % [e.health, hp])
	eq(ai.info("escort_1")["reason"], AiPilot.R_HEALTH, "for its health")
	# Wounded from the start, with an enemy flying right at it: it never engages.
	var w2 := _formation({"fwd": 300.0, "rgt": 250.0, "dh": PI, "speed": 100.0})
	var ai2 := _pilot(w2)
	w2.units["escort_1"].health = 1
	ai2.plan_turn()
	for turn_no in 5:
		_turn(w2)
		_next(w2)
	eq(_transition_to(ai2, "escort_1", AiPilot.S_ENGAGE).size(), 0, "a wounded escort never engages, however near the enemy")
	eq(ai2.state_of("escort_1"), AiPilot.S_STATION, "it stays on station")

# The protected unit goes down: the escort has nobody to guard and hunts.
func _protected_unit_down() -> void:
	var w := _formation({"fwd": 1500.0, "rgt": 150.0, "dh": PI, "speed": 100.0})
	w.units["bomber_1"].down = true
	var ai := _pilot(w)
	eq(ai.state_of("escort_1"), AiPilot.S_FREE, "with the bomber down the escort is free")
	eq(ai.info("escort_1")["reason"], AiPilot.R_PROTECTED_DOWN, "because its protected unit is down")
	eq(w.units["bomber_1"].plan.size(), 0, "a down unit is not planned")
	check(w.units["escort_1"].plan.size() > 0, "the escort still flies")
	for turn_no in 4:
		_turn(w)
		_next(w)
	check(w.phase == World.PHASE_PLANNING, "the world carries on")

# --- Knowledge ------------------------------------------------------------------------

func _probe(fwd: float, rgt: float, extra_tweak: Dictionary = {}) -> Dictionary:
	var w := _formation({"fwd": fwd, "rgt": rgt, "dh": PI, "speed": 100.0})
	var tweak := {"escort.engage_radius_protect_m": 1.0e6, "escort.engage_radius_self_m": 1.0e6}
	tweak.merge(extra_tweak, true)
	var ai := _pilot(w, tweak)
	return {"sees": ai.sees("p1"), "state": ai.state_of("escort_1"), "w": w, "ai": ai}

# The AI knows an enemy only inside sight_range_m of a living AI unit (a circle).
# The engage radii are opened wide here, so sight is the only thing between the
# AI and an engagement.
func _sight_and_memory() -> void:
	var w0 := _formation()
	var escort_sight: float = w0.units["escort_1"].def.sight_range_m
	var bomber_sight: float = w0.units["bomber_1"].def.sight_range_m
	# Outside every sight: not seen, not engaged, and the plan is exactly the plan of a world without the enemy.
	var far := _probe(1100.0, 250.0)
	check(not far["sees"], "an enemy beyond every sight circle is not seen")
	eq(far["state"], AiPilot.S_STATION, "so the escort stays on station however wide its radii")
	var alone := _formation()
	var alone_ai := _pilot(alone, {"escort.engage_radius_protect_m": 1.0e6, "escort.engage_radius_self_m": 1.0e6})
	for id in ["bomber_1", "escort_1"]:
		eq(far["w"].units[id].plan, alone.units[id].plan, "%s plans exactly as it would without the enemy in the world" % id)
	# Just outside the escort's circle and the bomber's.
	var edge := _probe(700.0, 250.0)
	check(not edge["sees"], "743 m from the bomber, 850 m from the escort: just outside both")
	# Seen by the escort only.
	var by_escort := _probe(-600.0, 600.0)
	check(by_escort["sees"], "inside the escort's circle only: seen")
	check(_dist(by_escort["w"].units["p1"], by_escort["w"].units["bomber_1"]) > bomber_sight, "(and beyond the bomber's)")
	eq(by_escort["state"], AiPilot.S_ENGAGE, "and engaged")
	# Seen by the bomber only: any AI unit's sight counts.
	var by_bomber := _probe(0.0, -640.0)
	check(by_bomber["sees"], "inside the bomber's circle only: seen")
	check(_dist(by_bomber["w"].units["p1"], by_bomber["w"].units["escort_1"]) > escort_sight, "(and beyond the escort's)")

	# Memory: seen, then out of sight; the AI keeps it for memory_turns and forgets it.
	var m := _probe(500.0, 250.0)
	var w: World = m["w"]
	var ai: AiPilot = m["ai"]
	var memory := ai.params.whole("knowledge", "memory_turns")
	check(ai.sees("p1") and ai.knows("p1"), "seen and known")
	w.units["p1"].x = 4900.0
	w.units["p1"].y = 4900.0
	var timeline: Array = []
	for i in memory + 3:
		_turn(w)
		_next(w)
		w.units["p1"].x = 4900.0
		w.units["p1"].y = 4900.0
		ai.plan_turn()
		timeline.append([ai.knows("p1"), ai.sees("p1")])
	for i in memory + 3:
		var turn_no := i + 2
		var kept := (turn_no - 1) <= memory
		eq(timeline[i], [kept, false], "turn %d: out of sight, %s" % [turn_no, "remembered" if kept else "forgotten"])
	# Once forgotten, an engagement on it is over.
	check(_transitions(ai, "escort_1").any(func(t: Dictionary) -> bool: return str(t["from"]) == AiPilot.S_ENGAGE and str(t["to"]) == AiPilot.S_RETURN), "the escort gave the lost contact up and went back")

func _down_units_are_skipped() -> void:
	var m := _probe(500.0, 250.0)
	eq(m["state"], AiPilot.S_ENGAGE, "an enemy in sight is engaged")
	var w: World = m["w"]
	var ai: AiPilot = m["ai"]
	_turn(w)
	_next(w)
	eq(ai.state_of("escort_1"), AiPilot.S_ENGAGE, "still engaged a turn later")
	w.units["p1"].down = true
	w.units["p1"].down_at = NAN
	ai.plan_turn()
	check(not ai.knows("p1"), "a unit seen down is dropped from what the AI knows")
	eq(ai.state_of("escort_1"), AiPilot.S_RETURN, "the escort drops it and goes home")
	eq(ai.info("escort_1")["reason"], AiPilot.R_TARGET_GONE, "because its target is gone")
	# A down enemy in sight from the start is never picked.
	var w2 := _formation({"fwd": 500.0, "rgt": 250.0, "dh": PI, "speed": 100.0})
	w2.units["p1"].down = true
	var ai2 := _pilot(w2)
	eq(ai2.state_of("escort_1"), AiPilot.S_STATION, "a down enemy is not engaged")
	check(not ai2.knows("p1"), "or known")

# --- Never a player's plan ------------------------------------------------------------

func _odd_plans(w: World) -> void:
	var p: Variant = w.units["p1"]
	w.plan_step("p1", 0, {"turn": 1.0, "speed": 150.0, "altitude_band": "low"})
	w.plan_step("p1", 1, {"turn": -1.0, "speed": 60.0})
	w.plan_step("p1", 3, Vector2(float(p.x) - 900.0, float(p.y) + 700.0))
	w.plan_step("p1", 4, {"turn": 0.5, "speed": 140.0, "altitude_band": "high"})

# The AI reads only public state. Two checks: the AI's plans are identical whether
# the player's units carry wild plans or none (in several states of the AI), and
# through a spy on the World's API, the AI never asks for a player unit's plan,
# preview, reach or samples, nor edits its plan.
func _never_reads_a_players_plan() -> void:
	var scenarios: Array = [
		["escort engaged on a crossing enemy", {"fwd": 800.0, "rgt": 900.0, "dh": -PI / 2.0, "speed": 100.0}, 2],
		["bomber alarmed by a head-on enemy", {"fwd": 1500.0, "rgt": 150.0, "dh": PI, "speed": 100.0}, 1],
		["escort on station, enemy out of sight", {"fwd": 2500.0, "rgt": 0.0, "dh": PI, "speed": 100.0}, 1],
	]
	for sc: Array in scenarios:
		var a := _formation(sc[1])
		var b := _formation(sc[1])
		var ai_a := _pilot(a)
		var ai_b := _pilot(b)
		for i in int(sc[2]):
			_turn(a)
			_turn(b)
			_next(a)
			_next(b)
		var before := {}
		for id in ["bomber_1", "escort_1"]:
			before[id] = (a.units[id].plan as Array).duplicate(true)
			eq(a.units[id].plan, b.units[id].plan, "%s: the same plans before the player plans anything (%s)" % [id, sc[0]])
		# World A's player now plans something wild, and the AI re-plans its turn.
		_odd_plans(a)
		check(a.units["p1"].plan.size() > 0, "the player's wild plan is in")
		ai_a.plan_turn()
		for id in ["bomber_1", "escort_1"]:
			eq(a.units[id].plan, before[id], "%s: the AI's plan does not change when a player plans (%s)" % [id, sc[0]])
			eq(a.units[id].plan, b.units[id].plan, "%s: and equals the plan of a world where nobody planned (%s)" % [id, sc[0]])
		eq(ai_a.state_of("escort_1"), ai_b.state_of("escort_1"), "the escort's state agrees too (%s)" % sc[0])

	# The spy.
	var spy := SpyWorld.new()
	_formation({"fwd": 800.0, "rgt": 900.0, "dh": -PI / 2.0, "speed": 100.0}, "medium", "light_fighter", spy)
	spy.recording = true
	var ai_s := _pilot(spy)
	spy.recording = false
	for i in 4:
		_odd_plans(spy)
		_turn(spy)
		spy.recording = true
		_next(spy)
		spy.recording = false
	check(spy.calls.size() > 0, "the spy saw the AI plan (%d calls)" % spy.calls.size())
	var forbidden: Array = []
	for c: Array in spy.calls:
		if str(c[1]) == "p1":
			forbidden.append(c)
	eq(forbidden, [], "the AI never asked the World about a player's unit")
	var own := {}
	for c: Array in spy.calls:
		own[str(c[0])] = true
	check(own.has("plan_step") and own.has("sample"), "it did plan, and read its own units' plans (%s)" % str(own.keys()))
	check(ai_s.sees("p1") or ai_s.knows("p1"), "(and it knew the enemy, by sight)")

# --- Determinism and the map --------------------------------------------------------------

func _determinism() -> void:
	var runs: Array = []
	for r in 2:
		var w := _formation({"fwd": 800.0, "rgt": 900.0, "dh": -PI / 2.0, "speed": 100.0})
		var ai := _pilot(w)
		var record: Array = []
		for t in 10:
			if t % 3 == 0:
				_odd_plans(w)
			var res := _turn(w)
			record.append(res["histories"])
			_next(w)
		runs.append({"histories": record, "transitions": ai.transitions.duplicate(true), "infos": [ai.info("bomber_1"), ai.info("escort_1")]})
	eq(runs[0]["histories"], runs[1]["histories"], "two identical games have identical histories over 10 turns")
	eq(runs[0]["transitions"], runs[1]["transitions"], "and identical state transitions")
	eq(runs[0]["infos"], runs[1]["infos"], "and identical AI memory")
	# Re-planning a turn gives the same plan (and the same transitions).
	var w := _formation({"fwd": 800.0, "rgt": 900.0, "dh": -PI / 2.0, "speed": 100.0})
	var ai := _pilot(w)
	for i in 3:
		_turn(w)
		_next(w)
	var plans := {}
	for id in ["bomber_1", "escort_1"]:
		plans[id] = (w.units[id].plan as Array).duplicate(true)
	var transitions := ai.transitions.duplicate(true)
	var info := ai.info("escort_1")
	ai.plan_turn()
	ai.plan_turn()
	for id in ["bomber_1", "escort_1"]:
		eq(w.units[id].plan, plans[id], "%s: planning the turn again gives the same plan" % id)
	eq(ai.transitions, transitions, "and the same transitions, none doubled")
	eq(ai.info("escort_1"), info, "and the same memory")

# Unassigned AI units fly straight and keep off the edge; assigned ones too. A
# bomber that starts inside the edge margin heading inward is not turned away.
func _stays_on_the_map() -> void:
	var w := World.new()
	var spawns: Array = [
		{"type": "light_fighter", "x": 2500.0, "y": 2500.0, "heading": 0.0},
		{"type": "light_fighter", "x": 700.0, "y": 2500.0, "heading": PI},
		{"type": "heavy_fighter", "x": 800.0, "y": 800.0, "heading": -0.75 * PI},
		{"type": "bomber", "x": 2500.0, "y": 1000.0, "heading": -0.5 * PI},
		{"type": "light_fighter", "x": 4000.0, "y": 2500.0, "heading": 0.0, "speed": 160.0},
		{"type": "heavy_fighter", "x": 2500.0, "y": 4200.0, "heading": 0.5 * PI, "speed": 165.0},
	]
	for i in spawns.size():
		var s: Dictionary = spawns[i]
		s["side"] = "axis"
		s["controller"] = "ai"
		s["id"] = "idle_%d" % i
		check(w.add_unit(s) != "", "spawn %d added" % i)
	# A strike spawned 500 m from the west edge, heading east along its route.
	eq(w.add_unit({"id": "edge_bomber", "type": "bomber", "side": "axis", "controller": "ai", "x": 500.0, "y": 2500.0, "heading": 0.0}), "edge_bomber", "the edge bomber is added")
	var ai := AiPilot.new()
	var orders := {"edge_bomber": {"role": "strike", "route": [[2500.0, 2500.0], [3500.0, 3200.0]]}}
	check(ai.attach(w, orders), "attached: %s" % str(ai.errors))
	var outside := 0
	var min_edge := INF
	var turned_away := 0
	for turn_no in 20:
		if not check(w.all_ready(), "turn %d: the AI readied itself" % (turn_no + 1)):
			return
		if turn_no == 0 and ai.info("edge_bomber")["edge"]:
			turned_away += 1
		var res := w.resolve()
		if not check(not res.is_empty(), "turn %d resolves" % (turn_no + 1)):
			return
		for id: String in w.units:
			for st: Dictionary in w.units[id].history:
				min_edge = minf(min_edge, minf(minf(float(st["x"]), 5000.0 - float(st["x"])), minf(float(st["y"]), 5000.0 - float(st["y"]))))
				if not w.in_bounds(float(st["x"]), float(st["y"])):
					outside += 1
		w.begin_turn()
	eq(outside, 0, "no AI unit left the map in 20 turns")
	eq(turned_away, 0, "the bomber that began inside the margin, heading inward, flew on")
	print("  map: 20 turns, closest approach to an edge %.0f m" % min_edge)
