extends "res://scripts/test_support/test_case.gd"

# THE GROUND RULE AND THE FAN UNDER A RULE (Track TK2, 2026-10-11; proposed -- the rule's numbers are data/sim/ground.json, the
# cliff rule is Alex's: decision terrain-passability A, "every height step is a cliff, impassable to ground units and crossed only at
# ramps or roads"). On a SYNTHETIC map, so every number is known:
#
#     x:    0 ............ 500 ............ 700 ==== 740 ........ 1000
#           low ground     |  upland (cliff at x = 500)   river (3 m deep) with the bridge at (720, 100), 40 m long
#     y = 100: a road, east-west, over the cliff (the one place a tank may cross it) and over the bridge
#     y in [400, 600]: a belt of woods (tree density 1)
#
#   1. DATA          data/sim/ground.json loads with every number a proposed record; a missing field, a number with no provenance
#                    and a misspelt key are errors
#   2. THE CLIFF     off the road a tank is stopped short of the height step and HELD there (limit "cliff"); it never has an end
#                    over it; on the road it drives over it (the road is the crossing, hull straddling two levels and all)
#   3. THE WATER     off the road, short of the river (limit "water"); over an intact bridge it crosses; with the bridge down
#                    it is stopped at the bank and stays dry
#   4. THE GOING     top speed on the road, a half of it in the open, a third in woods; woods slow it, they never block it; the
#                    cap is soft (a tank that drives into woods brakes at its decel); a step half on the road is in between
#   5. THE NET       a step that is not clamped is returned untouched (the same dictionary); an unruled unit (a plane, a World with
#                    no eyes) is not touched; a ground unit that cannot move (a static one) is not ruled; a destroyed bridge
#                    stops carrying at once
#   6. THE FAN       World.reachable clips a TANK's fan by the ground rule and a BOAT's by the water rule: near a cliff, a shore, a
#                    river the fan is smaller and every point of it is the end of a step the unit can make; in the open it is the
#                    envelope's own outline; and the planner (MotionPlanner.fan_outline_world, place_point, in_fan) shows and uses it:
#                    a click across the cliff comes back clamped short of it, and is not in the fan

const World = preload("res://scripts/sim/world.gd")
const GroundRules = preload("res://scripts/sim/ground_rules.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")

const CLIFF_X := 500.0
const RIVER_X0 := 700.0
const RIVER_X1 := 740.0
const ROAD_Y := 100.0
const BRIDGE := Vector2(720.0, 100.0)
const SHORE_X := 1000.0        # the sea scene: water for x < SHORE_X

var _sea_scene := false
var _checked := 0

func setup(_main) -> void:
	timeout_seconds = 120.0
	for part: Script in [World, GroundRules, UnitUI]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	_data()
	_cliff()
	_water()
	_going()
	_net()
	_fans()
	_planner()
	eq(_checked, 7, "the test reached its last section (a runtime error would have ended it silently)")
	finish()

# --- The synthetic map -------------------------------------------------------------------------------

func _level(x: float, _y: float) -> int:
	return 1 if x >= CLIFF_X else 0

func _road(x: float, y: float) -> float:
	var d := absf(y - ROAD_Y)
	return d if (d <= 32.0 and x >= -50.0 and x <= 1050.0) else INF

func _woods(_x: float, y: float) -> float:
	return 1.0 if (y >= 400.0 and y <= 600.0) else 0.0

# The river is deep at its middle and the sea scene's water is everywhere west of SHORE_X
func _depth(x: float, _y: float) -> float:
	if _sea_scene:
		return 8.0 if x < SHORE_X else 0.0
	return 3.0 if (x >= RIVER_X0 and x <= RIVER_X1) else 0.0

func _path(a: Vector2, b: Vector2) -> PackedVector2Array:
	return PackedVector2Array([Vector2(a.x, ROAD_Y), Vector2(b.x, ROAD_Y)])

func _world(with_bridge: bool = true, bridge_down: bool = false) -> World:
	_sea_scene = false
	var w := World.new()
	w.quiet = true
	w.set_water(Callable(self, "_depth"))
	w.set_ground(Callable(self, "_level"), Callable(self, "_road"), Callable(self, "_woods"), Callable(self, "_path"))
	w.add_player("local")
	if with_bridge:
		w.add_unit({"id": "bridge_1", "type": "bridge", "side": "allies", "controller": "ai", "x": BRIDGE.x, "y": BRIDGE.y, "heading": 0.0})
		(w.units["bridge_1"] as Object).down = bridge_down
	return w

func _tank(w: World, x: float, y: float, heading: float = 0.0, speed: float = 0.0, id: String = "t") -> String:
	var got := w.add_unit({"id": id, "type": "tank", "side": "allies", "controller": "player", "x": x, "y": y, "heading": heading, "speed": speed})
	if got == "":
		fail("the tank was not added at (%s, %s): %s" % [x, y, w.last_error])
	return got

# One turn in which the tank is asked to drive straight at `speed` (every step), resolved. Returns the unit.
func _drive(w: World, speed: float = 10.0, turn: float = 0.0, id: String = "t") -> Object:
	for k in w.steps_per_turn(id):
		w.plan_step(id, k, {"turn": turn, "speed": speed})
	w.commit("local")
	w.resolve()
	w.begin_turn()
	return w.units[id]

func _limits(u: Object) -> Array:
	var out: Array = []
	for st: Variant in u.history:
		for l: Variant in ((st as Dictionary).get("limits", []) as Array):
			if not out.has(l):
				out.append(l)
	return out

# --- 1. Data ---------------------------------------------------------------------------------------------

func _data() -> void:
	var r := GroundRules.new()
	if not check(r.ok(), "1. data/sim/ground.json loads: %s" % str(r.errors)):
		return
	check(r.hull_fraction > 0.0 and r.hull_fraction <= 1.0, "1. the hull's ends are checked part of the way along its length (%s)" % r.hull_fraction)
	check(r.sample_m > 0.0 and r.sample_m <= 8.0, "1. the arc is sampled every few metres (%s m)" % r.sample_m)
	check(r.slow_tries >= 1 and r.refine_steps >= 0, "1. a step is slowed in tries, then refined (%d, %d)" % [r.slow_tries, r.refine_steps])
	check(r.wade_m == 0.0, "1. no fording: wade_m is %s" % r.wade_m)
	eq(r.bridge_types, ["bridge"] as Array[String], "1. the bridge unit carries a tank over water")
	eq(r.factor_road, 1.0, "1. a road is the unit's own top speed (a factor of 1)")
	check(r.factor_open < r.factor_road and r.factor_open > 0.0, "1. open ground is slower (%s)" % r.factor_open)
	check(r.factor_woods < r.factor_open and r.factor_woods > 0.0, "1. woods are slower again, never a block (%s)" % r.factor_woods)
	check(r.road_half_m >= 4.0, "1. the road is wider than a tank (half width %s m)" % r.road_half_m)
	# every number says where it came from (records.gd), and the file is read strictly
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(GroundRules.PATH))
	var no_sample := raw.duplicate(true)
	no_sample.erase("sample_m")
	check(not GroundRules.new(no_sample, true).ok(), "1. a missing field is an error, never a default")
	var anon := raw.duplicate(true)
	anon["slow_tries"] = {"value": 6}
	check(not GroundRules.new(anon, true).ok(), "1. a number with no provenance is an error")
	var typo := raw.duplicate(true)
	typo["slow_trys"] = {"value": 6, "_proposed": true, "_reason": "x"}
	check(not GroundRules.new(typo, true).ok(), "1. a misspelt key is an error")
	var bad_factor := raw.duplicate(true)
	bad_factor["speed_factor"]["woods"] = {"value": 1.5, "_proposed": true, "_reason": "x"}
	check(not GroundRules.new(bad_factor, true).ok(), "1. a speed factor above 1 is an error")
	var no_bridge := raw.duplicate(true)
	no_bridge["bridge_types"] = {"value": [], "_proposed": true, "_reason": "x"}
	check(not GroundRules.new(no_bridge, true).ok(), "1. an empty list of bridge types is an error")
	# the proposals are labelled as such, and the one decision is quoted
	check(str(raw["_about"]).contains("terrain-passability"), "1. the cliff rule names Alex's decision")
	for k: String in ["hull_fraction", "sample_m", "slow_tries", "refine_steps", "road_half_m", "wade_m", "bridge_types", "bridge_half_width_m", "woods_density_min"]:
		check((raw[k] as Dictionary).get("_proposed", false) == true, "1. %s is a PROPOSED record" % k)
	_checked += 1

# --- 2. The cliff -------------------------------------------------------------------------------------------

func _cliff() -> void:
	# OFF THE ROAD: driven at the cliff at the tank's top speed, from 80 m back
	var w := _world()
	_tank(w, CLIFF_X - 80.0, 300.0, 0.0, 8.0)
	check(w.unit_grounded("t"), "2. the tank starts on legal ground")
	var u: Object = null
	for i in 6:
		u = _drive(w)
	var front: float = u.x + 3.0
	check(u.x < CLIFF_X - 3.0 + 1e-6, "2. off the road the tank stops short of the cliff: its front end is at %.2f, the cliff at %.0f" % [front, CLIFF_X])
	check(u.x > CLIFF_X - 40.0, "2. ... and it got close to it (centre at %.1f)" % u.x)
	eq(u.speed, 0.0, "2. ... held, speed 0")
	check(_limits(u).has(Envelope.LIMIT_CLIFF), "2. ... the step reports the limit 'cliff' (%s)" % str(_limits(u)))
	check(bool(u.history[u.history.size() - 1]["clamped"]), "2. ... and is clamped")
	check(not w.units["t"].history.any(func(st: Dictionary) -> bool: return float(st["x"]) + 3.0 > CLIFF_X), "2. no state of the turn has an end of the hull over the step")
	check(w.unit_grounded("t"), "2. it is on legal ground where it stopped")
	# held means held: it asks again and stays
	var x_held: float = u.x
	u = _drive(w)
	eq(u.x, x_held, "2. a held tank that asks again stays where it is")
	# and it can turn away on the spot (a pivot) and drive off
	u = _drive(w, 0.0, PI * 0.45)       # a pivot: no way on, two steps of 75 degrees
	check(absf(Envelope.wrap_angle(float(u.heading))) > 2.0, "2. a held tank pivots on the spot (heading %.2f)" % float(u.heading))
	check(absf(u.x - x_held) < 1e-6, "2. ... without moving (x %.3f)" % u.x)
	u = _drive(w, 6.0, 0.0)
	u = _drive(w, 6.0, 0.0)
	check(u.x < x_held - 5.0, "2. turned round it drives away from the cliff (x %.1f, was %.1f)" % [u.x, x_held])
	# SLOWED, NOT HELD, when slowing is enough: 10 m/s from 14 m away stops at the cliff short of a full step
	var w2 := _world()
	_tank(w2, CLIFF_X - 20.0, 300.0, 0.0, 10.0)
	var u2: Object = _drive(w2)
	check(u2.x < CLIFF_X - 3.0 + 1e-6 and u2.x > CLIFF_X - 12.0, "2. a step that would cross it is slowed to end at the edge (centre at %.2f)" % u2.x)
	check(float(u2.history[1]["x"]) > float(u2.history[0]["x"]), "2. ... it moved, it was not held (x %.2f from %.2f)" % [float(u2.history[1]["x"]), float(u2.history[0]["x"])])
	check(_limits(u2).has(Envelope.LIMIT_CLIFF), "2. ... limit cliff")
	# ON THE ROAD: the road is the crossing
	var w3 := _world()
	_tank(w3, CLIFF_X - 60.0, ROAD_Y, 0.0, 8.0)
	var crossed := false
	var straddled := false
	for i in 4:
		var u3: Object = _drive(w3)
		if abs(u3.x - CLIFF_X) < 3.0:
			straddled = true
		for k in 21:
			var s: Dictionary = w3.sample("t", 0.25 * float(k), "history")
			if absf(float(s["x"]) - CLIFF_X) < 2.9:
				straddled = true
		crossed = crossed or u3.x > CLIFF_X + 5.0
		check(not _limits(u3).has(Envelope.LIMIT_CLIFF), "2. on the road no step is stopped by the cliff (turn %d)" % (i + 1))
	check(crossed, "2. on the road the tank drives over the height step")
	check(straddled, "2. ... through poses with the hull on both levels (the road is the crossing)")
	check(w3.units["t"].x > CLIFF_X + 20.0, "2. ... and on beyond it (x %.1f)" % w3.units["t"].x)
	# A tank on the road that swings OFF it at the cliff is stopped by it
	var w4 := _world()
	_tank(w4, CLIFF_X - 14.0, ROAD_Y + 12.0, 0.0, 5.0)   # 12 m north of the centre line: off the road (8 m)
	var u4: Object = _drive(w4, 5.0)
	check(u4.x < CLIFF_X - 3.0 + 1e-6, "2. 12 m beside the road is not the road: stopped (x %.2f)" % u4.x)
	# Something the rule is not asked about: a tank that crosses the step in a fully legal pose is not held by a straddle off the road
	var w5 := _world()
	_tank(w5, CLIFF_X - 3.0, 300.0, PI * 0.5, 0.0)   # parked beside the cliff, facing along it: its ends are 3 m north and south, same level
	check(w5.unit_grounded("t"), "2. parked beside the cliff, facing along it, is legal")
	var w6 := _world()
	check(not w6.ground_ok_at(CLIFF_X - 2.0, 300.0, 0.0, _tank(w6, 100.0, 300.0)), "2. ground_ok_at: a hull whose front end is over the step is not legal off the road")
	check(w6.ground_ok_at(CLIFF_X - 2.0, ROAD_Y, 0.0, "t"), "2. ... but it is on the road")
	_checked += 1

# --- 3. The water --------------------------------------------------------------------------------------------

func _water() -> void:
	# Off the road, driven at the river
	var w := _world()
	_tank(w, RIVER_X0 - 80.0, 300.0, 0.0, 8.0)
	var u: Object = null
	for i in 6:
		u = _drive(w)
	check(u.x + 3.0 <= RIVER_X0 + 1e-6, "3. off the road the tank stops short of the river (front end at %.2f, the water at %.0f)" % [u.x + 3.0, RIVER_X0])
	check(u.x > RIVER_X0 - 40.0, "3. ... close to it (centre at %.1f)" % u.x)
	eq(u.speed, 0.0, "3. ... held")
	check(_limits(u).has(Envelope.LIMIT_WATER), "3. ... the limit is 'water' (%s)" % str(_limits(u)))
	check(w.unit_grounded("t"), "3. ... on dry ground")
	# Over the intact bridge, on the road
	var wb := _world()
	_tank(wb, RIVER_X0 - 70.0, ROAD_Y, 0.0, 8.0)
	var on_deck := false
	var speed_on_deck := 0.0
	for i in 6:
		var ub: Object = _drive(wb)
		check(not _limits(ub).has(Envelope.LIMIT_WATER), "3. over the bridge no step is stopped by the water (turn %d)" % (i + 1))
		for k in 21:
			var s: Dictionary = wb.sample("t", 0.25 * float(k), "history")
			if float(s["x"]) > RIVER_X0 + 3.0 and float(s["x"]) < RIVER_X1 - 3.0:
				on_deck = true
				speed_on_deck = maxf(speed_on_deck, float(s["speed"]))
	check(on_deck, "3. the tank drives onto the deck over the water")
	check(wb.units["t"].x > RIVER_X1 + 20.0, "3. ... and across to the far bank (x %.1f)" % wb.units["t"].x)
	check(speed_on_deck > 9.0, "3. the deck is road: it keeps its road speed on it (%.1f m/s)" % speed_on_deck)
	# With the bridge DOWN the same drive is stopped at the bank
	var wd := _world(true, true)
	_tank(wd, RIVER_X0 - 70.0, ROAD_Y, 0.0, 8.0)
	var ud: Object = null
	for i in 6:
		ud = _drive(wd)
	check(ud.x + 3.0 <= RIVER_X0 + 1e-6, "3. a destroyed bridge stops the tank at the bank (front end at %.2f)" % (ud.x + 3.0))
	check(_limits(ud).has(Envelope.LIMIT_WATER), "3. ... limit water")
	eq(ud.speed, 0.0, "3. ... held")
	check(wd.unit_grounded("t"), "3. ... dry")
	# With NO bridge at all in the world, the same
	var wn := _world(false)
	_tank(wn, RIVER_X0 - 70.0, ROAD_Y, 0.0, 8.0)
	var un: Object = null
	for i in 6:
		un = _drive(wn)
	check(un.x + 3.0 <= RIVER_X0 + 1e-6, "3. with no bridge unit the river is a river even on the road (front end at %.2f)" % (un.x + 3.0))
	# A bridge that falls under the tank's feet during play: the next turn it is stopped
	var wf := _world()
	_tank(wf, RIVER_X0 - 120.0, ROAD_Y, 0.0, 8.0)
	_drive(wf)
	_drive(wf)
	var up: Object = wf.units["t"]
	check(up.x < RIVER_X0 - 20.0, "3. (the tank is on its way to the bridge, x %.1f)" % up.x)
	(wf.units["bridge_1"] as Object).down = true
	for i in 5:
		up = _drive(wf)
	check(up.x + 3.0 <= RIVER_X0 + 1e-6, "3. a bridge destroyed while the tank approaches stops it at the bank (front end at %.2f)" % (up.x + 3.0))
	# the deck is the bridge's: 12 m off its axis (a hull end over the water beside the deck) is not on it
	var wa := _world()
	check(not wa.ground_ok_at(BRIDGE.x, BRIDGE.y + 12.0, 0.0, _tank(wa, 100.0, 300.0)), "3. 12 m off the bridge's axis is over the river, not on the deck")
	check(wa.ground_ok_at(BRIDGE.x, BRIDGE.y + 3.0, 0.0, "t"), "3. 3 m off it is on the deck")
	check(wa.ground_ok_at(BRIDGE.x + 17.0, BRIDGE.y, 0.0, "t"), "3. the hull may reach the span's end (the abutment: 20 m from its middle)")
	_checked += 1

# --- 4. The going ---------------------------------------------------------------------------------------------

func _going() -> void:
	# Top speed over a long run on the road (west of the cliff), in the open and in woods
	var road_top := _top_speed(20.0, ROAD_Y, 0.0)
	var open_top := _top_speed(20.0, 250.0, 0.0)
	var woods_top := _top_speed(100.0, 425.0, PI * 0.5, 10, Rect2(0.0, 440.0, 1000.0, 140.0))   # south in the woods belt (y 400 to 600)
	near(road_top, 10.0, 0.01, "4. on the road the tank reaches its top speed (data/units/tank.json: 10 m/s)")
	near(open_top, 5.0, 0.05, "4. in the open it is held to half of it (speed_factor.open 0.5)")
	near(woods_top, 3.0, 0.05, "4. in woods to a third (speed_factor.woods 0.3)")
	check(road_top > 1.9 * open_top, "4. the road is twice the open ground")
	# Woods slow, they never block: the tank gets through the belt
	var w := _world()
	_tank(w, 100.0, 380.0, PI * 0.5, 5.0)
	var through := false
	for i in 25:
		var u: Object = _drive(w, 10.0)
		if u.y > 620.0:
			through = true
			break
	check(through, "4. a tank drives through the woods belt (it ends at y %.1f)" % w.units["t"].y)
	# The cap is soft: a tank at 10 m/s that enters woods brakes at its decel (4 m/s2: 10 in a step), not instantly
	var ws := _world()
	_tank(ws, 100.0, 380.0, PI * 0.5, 10.0)
	var us: Object = _drive(ws, 10.0)
	check(_limits(us).has(Envelope.LIMIT_TERRAIN), "4. entering woods at top speed the going slows the step (limit 'terrain': %s)" % str(_limits(us)))
	check(float(us.history[1]["speed"]) < 10.0, "4. ... it is slowed in the first step (%.2f m/s)" % float(us.history[1]["speed"]))
	check(not _limits(us).has(Envelope.LIMIT_CLIFF) and not _limits(us).has(Envelope.LIMIT_WATER), "4. ... and held by nothing else")
	# A step half on the road, half beside it, is in between
	var wm := _world()
	_tank(wm, 20.0, ROAD_Y + 6.0, 0.0, 10.0)   # 6 m off the centre line (the road is 8 m each side): the step turns away, off the road
	wm.plan_step("t", 0, {"turn": 0.7, "speed": 10.0})
	var s0: Dictionary = wm.planned_states("t")[0]
	check(float(s0["speed"]) > 5.0 and float(s0["speed"]) < 10.0, "4. a step that leaves the road is capped between the two goings (%.2f m/s)" % float(s0["speed"]))
	# A ship is not a tank: the ground rule is not asked of a boat or a plane
	var wp := _world()
	wp.add_unit({"id": "p", "type": "light_fighter", "side": "allies", "controller": "player", "x": CLIFF_X - 20.0, "y": 300.0, "heading": 0.0})
	wp.plan_step("p", 0, {"turn": 0.0, "speed": 100.0})
	check((wp.planned_states("p")[0]["limits"] as Array).has(Envelope.LIMIT_CLIFF) == false, "4. a plane flies over the cliff and the river")
	_checked += 1

# The highest speed a tank asked for 10 m/s reaches over `turns` turns from rest at (x, y) heading h.
func _top_speed(x: float, y: float, h: float, turns: int = 9, inside: Rect2 = Rect2()) -> float:
	var w := _world()
	_tank(w, x, y, h, 0.0)
	var top := 0.0
	for i in turns:
		var u: Object = _drive(w, 10.0)
		for st: Variant in u.history:
			var d := st as Dictionary
			if inside.size == Vector2.ZERO or inside.has_point(Vector2(float(d["x"]), float(d["y"]))):
				top = maxf(top, float(d["speed"]))
	return top

# --- 5. The net ---------------------------------------------------------------------------------------------------

func _net() -> void:
	# a step the rule does not change is the envelope's step, untouched
	var w := _world()
	_tank(w, 100.0, ROAD_Y, 0.0, 8.0)
	var r := GroundRules.new()
	var def = w.unit_def("tank")
	var prev: Dictionary = w.units["t"].state()
	prev["turn"] = 0.0
	var s: Dictionary = def.envelope.clamp_step(prev, {"turn": 0.1, "speed": 9.0}, 2.5)
	var kept: Dictionary = r.keep(def, prev, s, 2.5, [], Callable())
	check(kept == s, "5. a legal step comes back untouched")
	# a World with no eyes: the tank is a plain unit
	var wb := World.new()
	wb.quiet = true
	wb.add_player("local")
	wb.add_unit({"id": "t", "type": "tank", "side": "allies", "controller": "player", "x": 100.0, "y": 100.0, "heading": 0.0, "speed": 10.0})
	check(not wb.has_ground(), "5. a World given nothing has no ground rule")
	wb.plan_step("t", 0, {"turn": 0.0, "speed": 10.0})
	check(not (wb.planned_states("t")[0]["limits"] as Array).has(Envelope.LIMIT_TERRAIN), "5. ... and a tank drives at its envelope's speed")
	check(wb.ground_ok_at(0.0, 0.0, 0.0, "t"), "5. ... anywhere is ok")
	# a World with water but no ground queries: the tank still keeps out of the river
	var ww := World.new()
	ww.quiet = true
	_sea_scene = false
	ww.set_water(Callable(self, "_depth"))
	ww.add_player("local")
	ww.add_unit({"id": "t", "type": "tank", "side": "allies", "controller": "player", "x": RIVER_X0 - 40.0, "y": 300.0, "heading": 0.0, "speed": 8.0})
	check(ww.has_ground(), "5. water alone is something to judge by")
	var uw: Object = null
	for i in 4:
		for k in 2:
			ww.plan_step("t", k, {"turn": 0.0, "speed": 10.0})
		ww.commit("local")
		ww.resolve()
		ww.begin_turn()
		uw = ww.units["t"]
	check(uw.x + 3.0 <= RIVER_X0 + 1e-6, "5. with only water given, a tank stops at the river (front at %.2f)" % (uw.x + 3.0))
	# a static ground unit (the bridge, the tower) is not ruled and does not move
	var wt := _world()
	check(wt.unit_grounded("bridge_1"), "5. a static ground unit is always grounded")
	# plan_step reports what it did: the same dictionary the planner draws
	var wc := _world()
	_tank(wc, CLIFF_X - 20.0, 300.0, 0.0, 10.0)
	var st: Dictionary = wc.plan_step("t", 0, {"turn": 0.0, "speed": 10.0})
	check(bool(st["clamped"]) and (st["limits"] as Array).has(Envelope.LIMIT_CLIFF), "5. plan_step returns the clamped state with the limit")
	var pre: Dictionary = wc.planned_states("t")[0]
	eq(pre["x"], st["x"], "5. and planned_states agrees (the preview is the resolve)")
	wc.commit("local")
	wc.resolve()
	near(float(wc.units["t"].history[1]["x"]), float(st["x"]), 1e-9, "5. ... and so does the resolve")
	_checked += 1

# --- 6. The fan ----------------------------------------------------------------------------------------------------

# The area of a polygon (shoelace), absolute
static func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		a += p[i].x * q.y - q.x * p[i].y
	return absf(a) * 0.5

func _fans() -> void:
	# A TANK ON THE ROAD, clear of the rules: the fan is the envelope's own where it goes straight ahead
	var w := _world()
	_tank(w, 100.0, ROAD_Y, 0.0, 8.0)
	var open: PackedVector2Array = w.reachable("t", 0)["outline"]
	var env_out: PackedVector2Array = w.unit_def("tank").envelope.reachable(w.units["t"].state(), w.step_dt("t"))["outline"]
	eq(open.size(), env_out.size(), "6. the fan keeps the envelope's shape (%d points)" % open.size())
	var apex := Vector2(100.0, ROAD_Y)
	var longer := 0
	for i in mini(open.size(), env_out.size()):
		if open[i].distance_to(apex) > env_out[i].distance_to(apex) + 0.02:
			longer += 1
	eq(longer, 0, "6. the ruled fan is never longer than the envelope's")
	var mid_i := open.size() / 4   # the straight-ahead sample of the far edge (9 samples a side: the 5th)
	check(open[mid_i].distance_to(env_out[mid_i]) < 0.02, "6. straight ahead along the road the ruled fan is the envelope's own (%.4f m)" % open[mid_i].distance_to(env_out[mid_i]))
	# (a hard turn off the road's line is off the road a few metres later, where the going is slower: the corners of the fan are shorter)
	# the same tank in the open: the going halves the speed it can end the step at, so the fan is shorter
	var wo := _world()
	_tank(wo, 100.0, 300.0, 0.0, 8.0)
	var ofan: PackedVector2Array = wo.reachable("t", 0)["outline"]
	var reach_open := 0.0
	var reach_road := 0.0
	for p in ofan:
		reach_open = maxf(reach_open, p.distance_to(Vector2(100.0, 300.0)))
	for p in open:
		reach_road = maxf(reach_road, p.distance_to(Vector2(100.0, ROAD_Y)))
	check(reach_open < 0.8 * reach_road and reach_open > 10.0, "6. off the road the fan is shorter: %.1f m of %.1f (the open ground's cap, 5 m/s)" % [reach_open, reach_road])
	# 15 m from the cliff, off the road: clipped
	var wc := _world()
	_tank(wc, CLIFF_X - 15.0, 300.0, 0.0, 8.0)
	var fan: PackedVector2Array = wc.reachable("t", 0)["outline"]
	var raw_fan: PackedVector2Array = wc.unit_def("tank").envelope.reachable(wc.units["t"].state(), wc.step_dt("t"))["outline"]
	check(_area(fan) < 0.8 * _area(raw_fan), "6. near the cliff the fan is clipped: %.0f m2 of %.0f" % [_area(fan), _area(raw_fan)])
	var beyond := 0
	for p in fan:
		if p.x > CLIFF_X + 1e-6:
			beyond += 1
	eq(beyond, 0, "6. no point of the fan is over the step")
	var raw_beyond := 0
	for p in raw_fan:
		if p.x > CLIFF_X:
			raw_beyond += 1
	check(raw_beyond > 0, "6. (and the unruled fan did cross it: %d points)" % raw_beyond)
	# every point of the fan is the end of a step the tank really makes: ask the World for it as a target point
	var illegal := 0
	for p in fan:
		var got: Dictionary = wc.plan_step("t", 0, p)
		if not wc.ground_ok_at(float(got["x"]), float(got["y"]), float(got["heading"]), "t"):
			illegal += 1
	eq(illegal, 0, "6. the step to any point of the fan ends on legal ground")
	wc.clear_plan("t")
	# ON THE ROAD the fan crosses the cliff
	var wr := _world()
	_tank(wr, CLIFF_X - 15.0, ROAD_Y, 0.0, 8.0)
	var rfan: PackedVector2Array = wr.reachable("t", 0)["outline"]
	var across := 0
	for p in rfan:
		if p.x > CLIFF_X + 3.0:
			across += 1
	check(across > 0, "6. on the road the fan reaches over the height step (%d points)" % across)
	# AT THE RIVER: clipped; on the road with the bridge, not; with the bridge down, clipped
	var wv := _world()
	_tank(wv, RIVER_X0 - 15.0, 300.0, 0.0, 8.0)
	var vfan: PackedVector2Array = wv.reachable("t", 0)["outline"]
	var wet := 0
	for p in vfan:
		if p.x > RIVER_X0 + 1e-6:
			wet += 1
	eq(wet, 0, "6. off the road the fan stops at the river")
	var wbr := _world()
	_tank(wbr, RIVER_X0 - 15.0, ROAD_Y, 0.0, 8.0)
	var bfan: PackedVector2Array = wbr.reachable("t", 0)["outline"]
	var onto := 0
	for p in bfan:
		if p.x > RIVER_X0 + 3.0:
			onto += 1
	check(onto > 0, "6. on the road the fan goes onto the bridge (%d points)" % onto)
	(wbr.units["bridge_1"] as Object).down = true
	var dfan: PackedVector2Array = wbr.reachable("t", 0)["outline"]
	var onto2 := 0
	for p in dfan:
		if p.x > RIVER_X0 + 1e-6:
			onto2 += 1
	eq(onto2, 0, "6. with the bridge down the fan stops at the bank")
	# A later step's fan starts from the step before and is clipped from there
	var wl := _world()
	_tank(wl, CLIFF_X - 40.0, 300.0, 0.0, 8.0)
	wl.plan_step("t", 0, {"turn": 0.0, "speed": 8.0})
	var f1: PackedVector2Array = wl.reachable("t", 1)["outline"]
	var f1_beyond := 0
	for p in f1:
		if p.x > CLIFF_X + 1e-6:
			f1_beyond += 1
	eq(f1_beyond, 0, "6. the second step's fan is clipped too")
	# A BOAT: a shore ahead
	_sea_scene = true
	var wsea := World.new()
	wsea.quiet = true
	wsea.set_water(Callable(self, "_depth"))
	wsea.add_player("local")
	wsea.add_unit({"id": "b", "type": "patrol_boat", "side": "allies", "controller": "player", "x": SHORE_X - 18.0, "y": 300.0, "heading": 0.0, "speed": 8.0})
	var bf: PackedVector2Array = wsea.reachable("b", 0)["outline"]
	var braw: PackedVector2Array = wsea.unit_def("patrol_boat").envelope.reachable(wsea.units["b"].state(), wsea.step_dt("b"))["outline"]
	check(_area(bf) < 0.8 * _area(braw), "6. a boat near a shore has a clipped fan: %.0f m2 of %.0f" % [_area(bf), _area(braw)])
	var sea_beyond := 0
	for p in bf:
		if p.x > SHORE_X:
			sea_beyond += 1
	eq(sea_beyond, 0, "6. no point of a boat's fan is on land")
	var sea_raw_beyond := 0
	for p in braw:
		if p.x > SHORE_X:
			sea_raw_beyond += 1
	check(sea_raw_beyond > 0, "6. (the envelope's own fan crossed the shore: %d points)" % sea_raw_beyond)
	for p in bf:
		var got2: Dictionary = wsea.plan_step("b", 0, p)
		check(wsea.afloat_at(float(got2["x"]), float(got2["y"]), float(got2["heading"]), "b"), "6. a step to a boat's fan point ends afloat")
	wsea.clear_plan("b")
	# the same boat in open water has the envelope's own fan
	wsea.add_unit({"id": "b2", "type": "patrol_boat", "side": "allies", "controller": "player", "x": 400.0, "y": 300.0, "heading": 0.0, "speed": 8.0})
	var of2: PackedVector2Array = wsea.reachable("b2", 0)["outline"]
	var oraw: PackedVector2Array = wsea.unit_def("patrol_boat").envelope.reachable(wsea.units["b2"].state(), wsea.step_dt("b2"))["outline"]
	var w2 := 0.0
	for i in mini(of2.size(), oraw.size()):
		w2 = maxf(w2, of2[i].distance_to(oraw[i]))
	check(w2 < 0.02, "6. a boat in open water: the envelope's own fan (%.4f m)" % w2)
	# a plane, a World with no eyes: untouched
	var wpl := World.new()
	wpl.quiet = true
	wpl.add_player("local")
	wpl.add_unit({"id": "p", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	var pf: PackedVector2Array = wpl.reachable("p", 0)["outline"]
	var praw: PackedVector2Array = wpl.unit_def("light_fighter").envelope.reachable(wpl.units["p"].state(), wpl.step_dt("p"))["outline"]
	eq(pf, praw, "6. a plane's fan is the envelope's, exactly")
	_sea_scene = false
	_checked += 1

# --- the planner --------------------------------------------------------------------------------------------------

func _planner() -> void:
	var w := _world()
	_tank(w, CLIFF_X - 15.0, 300.0, 0.0, 8.0)
	var ppm := 4.0
	var origin := Vector2(CLIFF_X - 100.0, 200.0)
	var xf := Transform2D(0.0, Vector2(ppm, ppm), 0.0, -origin * ppm)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")
	var pl := ui.planner
	ui.select("t")
	var fan := pl.fan_outline_world()
	var direct: PackedVector2Array = w.reachable("t", 0)["outline"]
	eq(fan, direct, "6. the planner's fan is the World's ruled fan")
	var beyond := 0
	for p in fan:
		if p.x > CLIFF_X + 1e-6:
			beyond += 1
	eq(beyond, 0, "6. the fan the planner shows stays on this side of the cliff")
	# a click across the cliff is outside the fan, and, placed anyway, comes back clamped short of it
	var across := Vector2(CLIFF_X + 30.0, 300.0)
	check(not pl.in_fan(xf * across), "6. a point across the cliff is not in the fan")
	var got := pl.place_point(across)
	check(not got.is_empty(), "6. a point across the cliff is still taken: %s" % w.last_error)
	check(bool(got["clamped"]), "6. ... clamped")
	check(float(got["x"]) + 3.0 <= CLIFF_X + 1e-6, "6. ... short of the cliff (the front end at %.2f)" % (float(got["x"]) + 3.0))
	check((got["limits"] as Array).has(Envelope.LIMIT_CLIFF), "6. ... because of the cliff (%s)" % str(got["limits"]))
	check(w.ground_ok_at(float(got["x"]), float(got["y"]), float(got["heading"]), "t"), "6. ... on legal ground")
	pl.clear()
	# a point inside the fan is taken as asked
	var o: PackedVector2Array = pl.fan_outline_world()
	var half := o.size() / 2
	var mid := (o[half / 2] + o[o.size() - 1 - half / 2]) * 0.5
	check(pl.in_fan(xf * mid), "6. the middle of the fan is in it")
	var in1 := pl.place_point(mid)
	check(not bool(in1["clamped"]), "6. a point inside the fan is not clamped (%s)" % str(in1.get("limits")))
	check(Vector2(float(in1["x"]), float(in1["y"])).distance_to(mid) < 1.0, "6. ... and lands where it was asked (%.2f m)" % Vector2(float(in1["x"]), float(in1["y"])).distance_to(mid))
	# the next step's fan starts from the one placed and is clipped from there
	var next_fan := pl.fan_outline_world()
	var nb := 0
	for p in next_fan:
		if p.x > CLIFF_X + 1e-6:
			nb += 1
	eq(nb, 0, "6. and the step after it is clipped too")
	# a boat in the planner
	_sea_scene = true
	var ws := World.new()
	ws.quiet = true
	ws.set_water(Callable(self, "_depth"))
	ws.add_player("local")
	ws.add_unit({"id": "b", "type": "patrol_boat", "side": "allies", "controller": "player", "x": SHORE_X - 18.0, "y": 300.0, "heading": 0.0, "speed": 8.0})
	var xf2 := Transform2D(0.0, Vector2(ppm, ppm), 0.0, -Vector2(SHORE_X - 200.0, 200.0) * ppm)
	var ui2 := UnitUI.new()
	add_child(ui2)
	ui2.setup(ws, xf2, "local")
	ui2.select("b")
	var bfan := ui2.planner.fan_outline_world()
	var bl := 0
	for p in bfan:
		if p.x > SHORE_X:
			bl += 1
	eq(bl, 0, "6. a ship's fan in the planner stays on the water")
	var bgot := ui2.planner.place_point(Vector2(SHORE_X + 60.0, 300.0))
	check(bool(bgot["clamped"]) and (bgot["limits"] as Array).has(Envelope.LIMIT_SHORE), "6. a ship's step placed on land comes back clamped by the shore (%s)" % str(bgot["limits"]))
	check(ws.afloat_at(float(bgot["x"]), float(bgot["y"]), float(bgot["heading"]), "b"), "6. ... afloat")
	_sea_scene = false
	_checked += 1
