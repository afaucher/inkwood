extends "res://scripts/test_support/test_case.gd"

# THE SPECIAL'S TARGET IN THE SIM (Track T, 2026-10-10; decision special-targeting, and Alex's two later lines).
# Alex: "The special is active and targeted for the step" -- a unit "could have two targets for different specials
# across two steps". Then, on a moving unit: "Targeting a moving unit like a tank should follow the unit. We need to pick
# the release point for bombs and things dynamically." Then, on a target outside the cone: "That means it might leave
# the cone and completely not fire" and "Or just be a bad shot" (data/sim/bombs.json outside_cone_mode is the switch).
# Headless, on the real World and the real data:
#
#   1. THE REQUEST      a drop may carry {"target": {"unit": id} | {"point": [x, y]}}; a malformed one or an unknown unit is
#                       refused; Envelope.drop_target reads it
#   2. IT TRAVELS       the step state, the history of the resolve, the bomb_release event and the client's World carry it;
#                       the aim stays what the sim bombs
#   3. HOLD             a drop whose aim is outside the cone releases nothing and spends nothing (up to inside_tolerance)
#   4. POOR SHOT        the same drop with the switch at poor_shot releases a stick, spends a bomb drop, at the cone's nearest
#                       point, with the rim's accuracy or worse (never below the floor)
#   5. FOLLOWED         a unit target FOLLOWS the unit: the stick lands where the moving unit is at impact, not where it was
#                       when the drop was planned, identically on a client
#   6. LEAVES THE CONE  a followed unit that leaves the cone during the resolve: hold releases nothing, poor_shot a poor stick
#   7. EXPECTED DAMAGE  the model's own expected pips ("radio tower: about 5 of 8"): deterministic, ordered, honest about the cone

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const BombExpect = preload("res://scripts/sim/bomb_expect.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const SimRules = preload("res://scripts/sim/sim_rules.gd")
const CombatResolver = preload("res://scripts/sim/combat_resolver.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")

const TANK_DIR := "res://tmp/test_units"
const SPEED := 85.0

var _data: BombRules = BombRules.new()

func setup(_main) -> void:
	timeout_seconds = 180.0
	for part: Script in [World, Bombs, BombRules, BombExpect, Envelope, WorldSync]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	if not check(_data.ok(), "data/sim/bombs.json loads: %s" % str(_data.errors)):
		finish()
		return
	eq(_data.outside_cone_mode, "hold", "0. the working default is hold (PROPOSED)")
	_write_tank()
	eq(_request(), true, "1. the request part ran to its end")
	eq(_travels(), true, "2. the travel part ran to its end")
	eq(_hold(), true, "3. the hold part ran to its end")
	eq(_poor_shot(), true, "4. the poor-shot part ran to its end")
	eq(_followed(), true, "5. the followed part ran to its end")
	eq(_leaves_the_cone(), true, "6. the leaves-the-cone part ran to its end")
	eq(_expected(), true, "7. the expected-damage part ran to its end")
	finish()

# --- helpers ----------------------------------------------------------------------------------

func _rules(mode: String) -> BombRules:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BombRules.PATH))
	(d["outside_cone_mode"] as Dictionary)["value"] = mode
	var r := BombRules.new(d)
	check(r.ok(), "(a rules variant loads: %s)" % str(r.errors))
	return r

# A World whose bombing rules are `mode`'s.
func _set_mode(w: World, mode: String) -> void:
	var r := _rules(mode)
	w.bombs = r
	w._combat_resolver = CombatResolver.new(w.combat, r)

# The bomber's start so that step 0's ideal aim (a release at the middle of the step) is `aim`.
func _align(w: World, aim: Vector2, band: String = "medium", id: String = "bomber") -> void:
	var u: Unit = w.units[id]
	u.x = aim.x - SPEED * 0.5 * w.step_dt(id) - Bombs.ideal_range(SPEED, w.band_height(band), w.bombs.gravity)
	u.y = aim.y

func _world(mode: String, seed_value: int = 1, band: String = "medium") -> World:
	var w := BombWorlds.world(seed_value, band)
	_set_mode(w, mode)
	_align(w, BombWorlds.TOWER, band)
	return w

func _plan_drop(w: World, aim: Vector2, target: Variant = null, k: int = 0) -> Dictionary:
	var drop := {"aim": [aim.x, aim.y]}
	if target != null:
		drop["target"] = target
	return w.plan_step("bomber", k, {"drop": drop})

# The across-track offset (metres) at which step 0's release error for an aim ideal + (0, off) is `want_r`.
func _across_for_r(w: World, want_r: float) -> float:
	var ideal: Vector2 = w.drop_cone("bomber", 0)["ideal_aim"]
	var lo := 0.0
	var hi := 900.0
	for _i in 40:
		var mid := 0.5 * (lo + hi)
		if float(w.drop_spread("bomber", 0, ideal + Vector2(0.0, mid))["requested_r"]) < want_r:
			lo = mid
		else:
			hi = mid
	return 0.5 * (lo + hi)

# --- 1. The request ------------------------------------------------------------------------------

func _request() -> bool:
	var w := _world("hold")
	var ideal: Vector2 = w.drop_cone("bomber", 0)["ideal_aim"]
	var st := _plan_drop(w, ideal, {"unit": "tower"})
	check(not st.is_empty(), "1. a drop with a unit target is planned: %s" % w.last_error)
	eq((st["drop"] as Dictionary).get("target"), {"unit": "tower"}, "1. and the step state carries the target")
	st = _plan_drop(w, ideal, {"point": [ideal.x, ideal.y]})
	check(not st.is_empty(), "1. a point target ([x, y]) is planned")
	eq((st["drop"] as Dictionary).get("target"), {"point": [ideal.x, ideal.y]}, "1. and is carried as it was given")
	st = _plan_drop(w, ideal, {"point": ideal})
	check(not st.is_empty(), "1. a Vector2 point is planned too")
	check((st["drop"] as Dictionary).has("target"), "1. and carried")
	st = _plan_drop(w, ideal)
	check(not st.is_empty() and not (st["drop"] as Dictionary).has("target"), "1. a drop with no target is still a drop (the aim alone)")
	for case: Array in [
		["a target that is not an object", 5],
		["an empty target", {}],
		["a target with both a unit and a point", {"unit": "tower", "point": [1.0, 2.0]}],
		["an empty unit id", {"unit": ""}],
		["a unit id that is not a string", {"unit": 7}],
		["a point with one number", {"point": [1.0]}],
		["a non-finite point", {"point": [INF, 0.0]}],
		["a NaN point", {"point": [NAN, 0.0]}],
		["a target with a field of its own", {"unit": "tower", "colour": "red"}],
	]:
		var before: Array = (w.units["bomber"].plan as Array).duplicate(true)
		eq(_plan_drop(w, ideal, case[1]), {}, "1. %s is refused" % case[0])
		check(Envelope.request_error({"drop": {"aim": [1.0, 2.0], "target": case[1]}}) != "", "1. and Envelope.request_error says so for %s" % case[0])
		eq(w.units["bomber"].plan, before, "1. and the plan is as it was")
	eq(_plan_drop(w, ideal, {"unit": "ghost"}), {}, "1. a target unit that does not exist is refused")
	check(w.last_error.contains("ghost"), "1. and it names the unit: %s" % w.last_error)
	eq(Envelope.drop_target({"drop": {"aim": [1.0, 2.0], "target": {"unit": "tower"}}}), {"unit": "tower"}, "1. Envelope.drop_target reads a unit")
	eq(Envelope.drop_target({"drop": {"aim": [1.0, 2.0], "target": {"point": Vector2(3.0, 4.0)}}}), {"point": [3.0, 4.0]}, "1. and normalises a point to [x, y]")
	eq(Envelope.drop_target({"drop": {"aim": [1.0, 2.0]}}), {}, "1. none when there is none")
	eq(Envelope.drop_target({"turn": 0.1}), {}, "1. none for a request with no drop")
	return true

# --- 2. It travels -------------------------------------------------------------------------------

func _travels() -> bool:
	var host := _world("hold", 3)
	var ideal: Vector2 = host.drop_cone("bomber", 0)["ideal_aim"]
	var target := {"unit": "tower"}
	_plan_drop(host, BombWorlds.TOWER, target)
	var ps: Dictionary = (host.planned_states("bomber")[0] as Dictionary)["drop"]
	check(bool(ps.get("ok", false)), "2. the drop is ok in the preview: %s" % str(ps.get("reason", "")))
	eq(ps.get("target"), target, "2. the preview carries the target")
	near((ps["aim"] as Array)[0], BombWorlds.TOWER.x, 1e-3, "2. and the aim is what the request named (the tower's place)")
	check(ideal.distance_to(BombWorlds.TOWER) < 1.0, "2. (the bomber is lined up on the tower)")
	# A second step with another target: different steps, different targets.
	_plan_drop(host, BombWorlds.TOWER + Vector2(0.0, 5.0), {"point": [BombWorlds.TOWER.x, BombWorlds.TOWER.y + 5.0]}, 1)
	var plan: Array = host.units["bomber"].plan
	eq((plan[0]["drop"] as Dictionary)["target"], {"unit": "tower"}, "2. step 1 keeps its unit target")
	eq((plan[1]["drop"] as Dictionary)["target"], {"point": [BombWorlds.TOWER.x, BombWorlds.TOWER.y + 5.0]}, "2. step 2 has a point of its own")
	host.clear_plan("bomber")
	_plan_drop(host, BombWorlds.TOWER, target)
	# The wire (WorldSync takes a World's players over, so it gets worlds of its own).
	var ws_host := _world("hold", 3)
	var ws_client := _world("hold", 3)
	_plan_drop(ws_host, BombWorlds.TOWER, target)
	var wired: Variant = bytes_to_var(var_to_bytes(ws_host.units["bomber"].plan))
	check(WorldSync.same(wired, ws_host.units["bomber"].plan), "2. the plan with its target survives the engine's own encoder exactly")
	var hs := WorldSync.new()
	add_child(hs)
	hs.setup(ws_host, "test")
	eq(hs._plan_problem("bomber", ws_host.units["bomber"].plan), "", "2. the host accepts a plan with a target")
	check(hs._plan_problem("bomber", [{"drop": {"aim": [1.0, 2.0], "target": {"unit": "tower", "point": [1.0, 2.0]}}}]) != "", "2. and refuses a malformed one")
	var snap: Dictionary = hs.snapshot()
	eq(((snap["units"] as Dictionary)["bomber"]["plan"][0]["drop"] as Dictionary)["target"], target, "2. the snapshot carries the plan with its target")
	var cs := WorldSync.new()
	add_child(cs)
	cs.setup(ws_client, "test")
	cs.apply_snapshot(bytes_to_var(var_to_bytes(snap)) as Dictionary)
	eq((ws_client.units["bomber"].plan[0]["drop"] as Dictionary).get("target"), target, "2. a peer that joins from the snapshot has the step's target")
	var cps: Dictionary = (ws_client.planned_states("bomber")[0] as Dictionary)["drop"]
	check(WorldSync.same(cps, ps), "2. and the same analysis of it")
	# The resolve: the history, the event, the client.
	var client := _world("hold", 3)
	var res := BombWorlds.turn(host)
	check(not res.is_empty(), "2. the turn resolves: %s" % host.last_error)
	var rel := BombWorlds.events_of(res, "bomb_release", "bomber")
	eq(rel.size(), 1, "2. one bomb_release")
	if rel.size() != 1:
		return false
	eq((rel[0] as Dictionary).get("target"), target, "2. which carries the target")
	check(not (rel[0] as Dictionary).has("poor_shot"), "2. and says nothing of a poor shot")
	var h1: Dictionary = ((host.units["bomber"].history as Array)[1] as Dictionary)["drop"]
	eq(h1.get("target"), target, "2. the history's step state carries it")
	eq(host.units["bomber"].drops_left, 2, "2. a drop is spent")
	var wired_res: Dictionary = bytes_to_var(var_to_bytes(res)) as Dictionary
	check(client.apply_resolution(wired_res), "2. the client applies the result: %s" % client.last_error)
	check(WorldSync.same(client.units["bomber"].history, host.units["bomber"].history), "2. and holds the same history, the target in it")
	eq(((client.units["bomber"].history as Array)[1] as Dictionary)["drop"].get("target"), target, "2. (the client's step state has the target)")
	return true

# --- 3. Hold ---------------------------------------------------------------------------------------

func _hold() -> bool:
	var w := _world("hold", 5)
	var ideal: Vector2 = w.drop_cone("bomber", 0)["ideal_aim"]
	# A hair outside the rim is inside the tolerance; a clear step beyond it is outside.
	var tol: float = w.bombs.inside_tolerance
	var off_in := _across_for_r(w, 1.0 + 0.5 * tol)
	var off_out := _across_for_r(w, 1.0 + 4.0 * tol + 0.02)
	var inside := w.drop_spread("bomber", 0, ideal + Vector2(0.0, off_in))
	eq(inside["outside"], false, "3. an aim at r %.4f (inside the %.3f tolerance) is not outside" % [float(inside["requested_r"]), tol])
	eq(inside["releases"], true, "3. and releases")
	var out := w.drop_spread("bomber", 0, ideal + Vector2(0.0, off_out))
	eq(out["outside"], true, "3. an aim at r %.4f is outside" % float(out["requested_r"]))
	eq(out["releases"], false, "3. and in hold mode does not release")
	var st := _plan_drop(w, ideal + Vector2(0.0, off_in))
	check(bool((st["drop"] as Dictionary).get("ok", false)), "3. the aim inside the tolerance is a drop")
	near(((st["drop"] as Dictionary)["aim"] as Array)[1], ideal.y + off_in, 1e-3, "3. at the aim asked for (not clamped)")
	# Outside: the step says so and releases nothing.
	st = _plan_drop(w, ideal + Vector2(0.0, 600.0), {"point": [ideal.x, ideal.y + 600.0]})
	var d: Dictionary = st["drop"]
	eq(d.get("ok"), false, "3. a drop 600 m off the track is not ok")
	eq(d.get("reason"), "outside_cone", "3. the reason is outside_cone")
	check(float(d.get("requested_r", 0.0)) > 1.0, "3. with its release error (%.2f)" % float(d.get("requested_r", 0.0)))
	check(d.has("nearest") and d.has("target"), "3. the nearest aim inside the cone and the target are in it")
	var res := BombWorlds.turn(w)
	eq(BombWorlds.events_of(res, "bomb_release").size(), 0, "3. nothing is released")
	eq(w.units["bomber"].drops_left, 3, "3. no drop is spent")
	eq(w.bombs_in_flight.size(), 0, "3. and no bomb is in the air")
	eq(BombWorlds.events_of(res, "bomb_impact").size(), 0, "3. none lands")
	# Moving the steps before a step after its drop was set (the interface does it): step 2's drop stays, its cone moves away
	# from the target, and it holds.
	var w2 := _world("hold", 6)
	w2.plan_step("bomber", 0, {"speed": SPEED})
	var aim2: Vector2 = w2.drop_cone("bomber", 1)["ideal_aim"]
	w2.plan_step("bomber", 1, {"drop": {"aim": [aim2.x, aim2.y], "target": {"point": [aim2.x, aim2.y]}}})
	check(bool(((w2.planned_states("bomber")[1] as Dictionary)["drop"] as Dictionary).get("ok", false)), "3. the drop is ok where it was set")
	w2.plan_step("bomber", 0, {"turn": 0.6, "speed": SPEED})
	var moved: Dictionary = (w2.planned_states("bomber")[1] as Dictionary)["drop"]
	eq(moved.get("ok"), false, "3. step 1 is turned hard: the cone of step 2 leaves the target, the drop does not release")
	eq(moved.get("reason"), "outside_cone", "3. for want of the cone")
	var r2 := BombWorlds.turn(w2)
	eq(BombWorlds.events_of(r2, "bomb_release").size(), 0, "3. nothing is released from the moved step")
	eq(w2.units["bomber"].drops_left, 3, "3. and none is spent")
	return true

# --- 4. Poor shot ----------------------------------------------------------------------------------

func _poor_shot() -> bool:
	var w := _world("poor_shot", 7)
	var rules: BombRules = w.bombs
	var ideal: Vector2 = w.drop_cone("bomber", 0)["ideal_aim"]
	var cone: PackedVector2Array = w.drop_cone("bomber", 0)["polygon"]
	var edge_off := _across_for_r(w, 1.0)
	var sp_edge := w.drop_spread("bomber", 0, ideal + Vector2(0.0, edge_off))
	var asked := ideal + Vector2(0.0, 600.0)
	var sp := w.drop_spread("bomber", 0, asked)
	eq(sp["outside"], true, "4. an aim 600 m off the track is outside")
	eq(sp["releases"], true, "4. and in poor_shot mode it releases")
	eq(sp["poor_shot"], true, "4. as a poor shot")
	check(float(sp["accuracy"]) <= rules.rim_accuracy_factor + 1e-9, "4. with the rim's accuracy or worse (%.3f against the rim's %.3f)" % [float(sp["accuracy"]), rules.rim_accuracy_factor])
	check(float(sp["accuracy"]) >= rules.poor_shot_floor - 1e-9, "4. never below the floor (%.3f)" % rules.poor_shot_floor)
	check(float(sp["spread_m"]) > float(sp_edge["spread_m"]) - 1e-9, "4. and a scatter at least the rim's (%.1f against %.1f m)" % [float(sp["spread_m"]), float(sp_edge["spread_m"])])
	var nearest: Vector2 = sp["aim"]
	check(Geometry2D.is_point_in_polygon(nearest.lerp(ideal, 0.08), cone), "4. it is aimed at the cone's nearest point to the target, at its edge (%s)" % str(nearest))
	check(nearest.y < asked.y - 100.0 and nearest.y > ideal.y, "4. between the ideal point and the target")
	# Farther outside: worse, down to the floor.
	var acc_prev := 2.0
	for r_want: float in [1.1, 1.3, 1.8, 2.5]:
		var off := _across_for_r(w, r_want)
		var s := w.drop_spread("bomber", 0, ideal + Vector2(0.0, off))
		var want := Bombs.poor_shot_accuracy(float(s["requested_r"]), rules)
		near(float(s["accuracy"]), minf(want, Bombs.accuracy(float(s["r"]), rules)), 0.01, "4. at r %.2f the accuracy is the rim's scaled down: %.3f" % [float(s["requested_r"]), float(s["accuracy"])])
		check(float(s["accuracy"]) < acc_prev + 1e-9, "4. and falls the farther outside the target is")
		acc_prev = float(s["accuracy"])
	near(float(w.drop_spread("bomber", 0, ideal + Vector2(0.0, 3000.0))["accuracy"]), rules.poor_shot_floor, 1e-9, "4. far outside it is the floor")
	# Planned and resolved: the stick is released, the drop is spent, the bombs fall round the nearest point.
	var st := _plan_drop(w, asked, {"point": [asked.x, asked.y]})
	var d: Dictionary = st["drop"]
	eq(d.get("ok"), true, "4. the drop is ok in the plan")
	eq(d.get("poor_shot"), true, "4. a poor shot")
	check(Vector2(float((d["aim"] as Array)[0]), float((d["aim"] as Array)[1])).distance_to(nearest) < 1.0, "4. aimed at the nearest point")
	eq(d.get("requested"), [asked.x, asked.y], "4. (the request is kept)")
	var res := BombWorlds.turn(w)
	var rel := BombWorlds.events_of(res, "bomb_release", "bomber")
	eq(rel.size(), 1, "4. a stick is released")
	if rel.size() == 1:
		eq((rel[0] as Dictionary).get("poor_shot"), true, "4. the event says it was a poor shot")
		check(absf(float((rel[0] as Dictionary)["accuracy"]) - float(d["accuracy"])) < 1e-9, "4. with the poor accuracy")
	eq(w.units["bomber"].drops_left, 2, "4. and the drop is spent")
	var imp := BombWorlds.events_of(res, "bomb_impact")
	check(imp.size() + w.bombs_in_flight.size() == 4, "4. four bombs are in the air or down (%d + %d)" % [imp.size(), w.bombs_in_flight.size()])
	var near_asked := 0
	for b: Dictionary in w.bombs_in_flight:
		if Vector2(float(b["x"]), float(b["y"])).distance_to(asked) < Vector2(float(b["x"]), float(b["y"])).distance_to(nearest):
			near_asked += 1
	check(near_asked <= 1, "4. the bombs fall round the nearest point, not round the target (%d nearer the target)" % near_asked)
	# The tolerance still holds: an aim inside it is a normal shot.
	var w2 := _world("poor_shot", 8)
	var i2: Vector2 = w2.drop_cone("bomber", 0)["ideal_aim"]
	var s_in := w2.drop_spread("bomber", 0, i2 + Vector2(0.0, _across_for_r(w2, 1.0 + 0.5 * w2.bombs.inside_tolerance)))
	eq(s_in["poor_shot"], false, "4. inside the tolerance it is not a poor shot")
	return true

# --- 5. Followed -----------------------------------------------------------------------------------

# A test-only mobile ground unit (data/units has none): the radio tower's file with a motor.
func _write_tank() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TANK_DIR))
	var tower: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/radio_tower.json"))
	tower["id"] = "tank"
	tower["name"] = "Test tank"
	tower["mobility"] = "mobile"
	tower["actions_per_turn"] = {"value": 2, "_proposed": true, "_reason": "test-only unit"}
	var e: Dictionary = tower["envelope"]
	var set_v := func(key: String, v: Variant) -> void:
		e[key] = {"value": v, "_proposed": true, "_reason": "test-only unit"}
	set_v.call("speed_min_mps", 0)
	set_v.call("speed_cruise_mps", 8)
	set_v.call("speed_max_mps", 12)
	set_v.call("dive_speed_max_mps", 12)
	set_v.call("accel_mps2", 2)
	set_v.call("decel_mps2", 2)
	set_v.call("turn_rate_curve_dps", [[0, 40], [12, 40]])
	var f := FileAccess.open(TANK_DIR + "/tank.json", FileAccess.WRITE)
	f.store_string(JSON.stringify(tower, "  "))
	f.close()
	for id: String in ["bomber", "radio_tower", "anti_aircraft_battery"]:
		var src := FileAccess.get_file_as_string("res://data/units/%s.json" % id)
		var g := FileAccess.open("%s/%s.json" % [TANK_DIR, id], FileAccess.WRITE)
		g.store_string(src)
		g.close()

# A world with a bomber lined up (step 0, medium) on a point `lead_m` ahead of a tank at TOWER that drives `heading` at
# `speed`, the bombing rules of `mode`. The tank plans nothing: it carries on, straight, at its speed.
func _tank_world(mode: String, seed_value: int, heading: float, speed: float, lead_m: float, off_m: float = 0.0) -> World:
	var w := World.new(SimRules.TURN_PATH, SimRules.ALTITUDE_PATH, TANK_DIR)
	w.quiet = true
	w.rng_seed = seed_value
	_set_mode(w, mode)
	w.add_player("local")
	w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": 2500.0, "heading": 0.0, "altitude_band": "medium", "speed": SPEED})
	w.add_unit({"id": "tank", "type": "tank", "side": "axis", "controller": "ai", "x": BombWorlds.TOWER.x, "y": BombWorlds.TOWER.y + off_m, "heading": heading, "speed": speed})
	check(w.ok() and w.units.has("tank"), "(the test world loads: %s %s)" % [str(w.errors), w.last_error])
	_align(w, BombWorlds.TOWER + Vector2(lead_m, 0.0))
	return w

func _commit_all(w: World) -> Dictionary:
	w.commit("local")
	w.commit(World.AI_PLAYER)
	return w.resolve()

func _mean_stick(bombs: Array) -> Vector2:
	var c := Vector2.ZERO
	for b: Dictionary in bombs:
		c += Vector2(float(b["x"]), float(b["y"]))
	return c / float(maxi(bombs.size(), 1))

func _followed() -> bool:
	var speed := 8.0
	var errors_proj := 0.0
	var errors_plan := 0.0
	var errors_actual := 0.0
	var runs := 16
	var made := 0
	var host_last: World = null
	var client_last: World = null
	for seed_value in runs:
		var host := _tank_world("hold", seed_value + 1, 0.0, speed, 80.0)
		var client := _tank_world("hold", seed_value + 1, 0.0, speed, 80.0)
		var shown: Vector2 = Vector2(host.units["tank"].x, host.units["tank"].y)
		# Planned at where the tank is SHOWN (the preview, no projection of the enemy's motion).
		var st := host.plan_step("bomber", 0, {"drop": {"aim": [shown.x, shown.y], "target": {"unit": "tank"}}})
		check(not st.is_empty(), "5. the drop on the tank is planned: %s" % host.last_error)
		var pv: Dictionary = (host.planned_states("bomber")[0] as Dictionary)["drop"]
		check(bool(pv.get("ok", false)), "5. it is ok in the preview")
		near(((pv["aim"] as Array)[0]), shown.x, 1e-3, "5. whose aim is where the tank is shown (no projection in the preview)")
		var res := _commit_all(host)
		check(not res.is_empty(), "5. the turn resolves: %s" % host.last_error)
		var rel := BombWorlds.events_of(res, "bomb_release", "bomber")
		if rel.size() != 1:
			fail("5. seed %d: expected one bomb_release, got %d" % [seed_value, rel.size()])
			continue
		var ev: Dictionary = rel[0]
		eq(ev.get("followed"), true, "5. the release says it followed a unit")
		eq(ev.get("target"), {"unit": "tank"}, "5. and the target")
		var t_rel := float(ev["t"])
		var fall := float(ev["fall_s"])
		# The aim at the release: the tank's position at t_rel, led by its velocity times the fall time.
		var at_rel := host.sample("tank", t_rel, "history")
		var want := Vector2(float(at_rel["x"]) + speed * fall, float(at_rel["y"]))
		var aim := Vector2(float((ev["aim"] as Array)[0]), float((ev["aim"] as Array)[1]))
		check(aim.distance_to(want) < 0.5, "5. the aim is the tank's place at the release plus its speed x the fall time: %s against %s" % [str(aim), str(want)])
		check(aim.x > shown.x + 60.0, "5. %.0f m beyond where the tank was shown" % (aim.x - shown.x))
		# Turns 2 and 3: the bombs land (a stick of four spans the turn boundary) where the tank is by then.
		host.begin_turn()
		var res2 := _commit_all(host)
		var t_centre: float = t_rel + fall - host.rules.turn_seconds   # the stick's centre lands this second of turn 2
		var tank_then := host.sample("tank", t_centre, "history")
		host.begin_turn()
		var res3 := _commit_all(host)
		var imp := BombWorlds.events_of(res2, "bomb_impact", "bomber") + BombWorlds.events_of(res3, "bomb_impact", "bomber")
		check(imp.size() == 4, "5. four bombs land in turns 2 and 3 (%d)" % imp.size())
		if imp.size() == 4:
			var centre := _mean_stick(imp)
			errors_actual += centre.distance_to(Vector2(float(tank_then["x"]), float(tank_then["y"])))
			errors_proj += centre.distance_to(want)
			errors_plan += centre.distance_to(shown)
			made += 1
		host_last = host
		# The client: the same results, applied turn by turn.
		client.plan_step("bomber", 0, {"drop": {"aim": [shown.x, shown.y], "target": {"unit": "tank"}}})
		check(client.apply_resolution(bytes_to_var(var_to_bytes(res)) as Dictionary), "5. the client applies turn 1: %s" % client.last_error)
		check(WorldSync.same(client.units["bomber"].history, (res["histories"] as Dictionary)["bomber"]), "5. and its history is the host's, the followed drop in it")
		check(WorldSync.same(client.bombs_in_flight, res["bombs"]), "5. with the same bombs in the air")
		client.begin_turn()
		check(client.apply_resolution(bytes_to_var(var_to_bytes(res2)) as Dictionary), "5. and turn 2: %s" % client.last_error)
		client.begin_turn()
		check(client.apply_resolution(bytes_to_var(var_to_bytes(res3)) as Dictionary), "5. and turn 3: %s" % client.last_error)
		check(WorldSync.same(client.units["tank"].history, host.units["tank"].history), "5. the tank's history agrees")
		check(WorldSync.same(client.bombs_in_flight, host.bombs_in_flight), "5. and no bomb is left that the host does not have")
		client_last = client
	if made == 0:
		return false
	var mean_actual := errors_actual / float(made)
	var mean_proj := errors_proj / float(made)
	var mean_plan := errors_plan / float(made)
	print("[test] followed tank: stick centre %.1f m from the tank at impact, %.1f m from the projected aim, %.1f m from where it was shown (%d sticks)" % [mean_actual, mean_proj, mean_plan, made])
	check(mean_actual < 38.0, "5. the stick lands near where the tank is at impact (%.1f m on average)" % mean_actual)
	check(mean_proj < 38.0, "5. near the projected aim (%.1f m)" % mean_proj)
	check(mean_plan > 62.0, "5. and not where the tank was when the drop was planned (%.1f m from it)" % mean_plan)
	check(mean_actual < mean_plan * 0.6, "5. much nearer the tank's place at impact than its place at planning")
	# Determinism: the same world resolves to the same drop twice.
	var a := _tank_world("hold", 3, 0.0, speed, 80.0)
	var b := _tank_world("hold", 3, 0.0, speed, 80.0)
	for w: World in [a, b]:
		w.plan_step("bomber", 0, {"drop": {"aim": [BombWorlds.TOWER.x, BombWorlds.TOWER.y], "target": {"unit": "tank"}}})
	var ra := _commit_all(a)
	var rb := _commit_all(b)
	check(WorldSync.same(ra, rb), "5. two Worlds that resolve the same turn agree exactly")
	# A point target is fixed: the tank drives away from it.
	var p := _tank_world("hold", 3, 0.0, speed, 0.0)
	p.plan_step("bomber", 0, {"drop": {"aim": [BombWorlds.TOWER.x, BombWorlds.TOWER.y], "target": {"point": [BombWorlds.TOWER.x, BombWorlds.TOWER.y]}}})
	var rp := _commit_all(p)
	var rp_rel := BombWorlds.events_of(rp, "bomb_release", "bomber")
	if rp_rel.size() == 1:
		near(float(((rp_rel[0] as Dictionary)["aim"] as Array)[0]), BombWorlds.TOWER.x, 1e-6, "5. a point target is not followed: the aim is the point")
		check(not (rp_rel[0] as Dictionary).has("followed"), "5. and the release does not say it followed")
	else:
		fail("5. the point drop released %d sticks" % rp_rel.size())
	# A unit target that does not move (the tower) is followed to the same place.
	var t := _world("hold", 4)
	t.plan_step("bomber", 0, {"drop": {"aim": [BombWorlds.TOWER.x, BombWorlds.TOWER.y], "target": {"unit": "tower"}}})
	var rt := BombWorlds.turn(t)
	var rt_rel := BombWorlds.events_of(rt, "bomb_release", "bomber")
	if rt_rel.size() == 1:
		near(float(((rt_rel[0] as Dictionary)["aim"] as Array)[0]), BombWorlds.TOWER.x, 1e-6, "5. a followed tower is where it stands (no lead for a static unit)")
		eq((rt_rel[0] as Dictionary).get("followed"), true, "5. and the release says it was followed")
	else:
		fail("5. the tower drop released %d sticks" % rt_rel.size())
	return host_last != null and client_last != null

# --- 6. A followed unit leaves the cone ----------------------------------------------------------------------

func _leaves_the_cone() -> bool:
	# The tank starts 40 m north of the track (inside the cone where it is SHOWN) and drives north, away from it, at 10 m/s, so by
	# the time of the release plus the lead it is ~100 m off: outside the cone for every moment of the step.
	for mode: String in ["hold", "poor_shot"]:
		var w := _tank_world(mode, 9, -PI / 2.0, 10.0, 0.0, -40.0)
		var shown := Vector2(float(w.units["tank"].x), float(w.units["tank"].y))
		w.plan_step("bomber", 0, {"drop": {"aim": [shown.x, shown.y], "target": {"unit": "tank"}}})
		var pv: Dictionary = (w.planned_states("bomber")[0] as Dictionary)["drop"]
		check(bool(pv.get("ok", false)) and not bool(pv.get("outside", false)), "6. %s: the tank is inside the cone where it is shown" % mode)
		var cone: PackedVector2Array = w.drop_cone("bomber", 0)["polygon"]
		var cone_ideal: Vector2 = w.drop_cone("bomber", 0)["ideal_aim"]
		var res := _commit_all(w)
		var rel := BombWorlds.events_of(res, "bomb_release", "bomber")
		var hist: Dictionary = (w.units["bomber"].history as Array)[1]["drop"]
		if mode == "hold":
			eq(rel.size(), 0, "6. hold: the tank left the cone during the resolve: nothing is released")
			eq(hist.get("ok"), false, "6. hold: the history says so")
			eq(hist.get("reason"), "outside_cone", "6. hold: for want of the cone")
			eq(w.units["bomber"].drops_left, 3, "6. hold: no drop is spent")
			eq(w.bombs_in_flight.size(), 0, "6. hold: no bomb falls")
		else:
			eq(rel.size(), 1, "6. poor_shot: the stick IS released")
			eq(hist.get("poor_shot"), true, "6. poor_shot: and is a poor shot")
			eq(w.units["bomber"].drops_left, 2, "6. poor_shot: the drop is spent")
			if rel.size() == 1:
				eq((rel[0] as Dictionary).get("poor_shot"), true, "6. poor_shot: the event says so")
				check(float((rel[0] as Dictionary)["accuracy"]) <= w.bombs.rim_accuracy_factor + 1e-9, "6. poor_shot: at the rim's accuracy or worse (%.3f)" % float((rel[0] as Dictionary)["accuracy"]))
				var aim := Vector2(float(((rel[0] as Dictionary)["aim"] as Array)[0]), float(((rel[0] as Dictionary)["aim"] as Array)[1]))
				check(Geometry2D.is_point_in_polygon(aim.lerp(cone_ideal, 0.06), cone), "6. poor_shot: aimed at the cone's nearest point to the tank (%s)" % str(aim))
	return true

# --- 7. The expected damage -----------------------------------------------------------------------------------

func _expected() -> bool:
	var w := _world("hold", 11)
	var tower := BombWorlds.TOWER
	var list := w.drop_expected("bomber", 0, tower)
	check(list.size() >= 1, "7. the tower is expected to be hurt by a drop on it")
	if list.is_empty():
		return false
	var top: Dictionary = list[0]
	eq(top["unit"], "tower", "7. it is the tower")
	check(float(top["mean"]) > 3.0 and float(top["mean"]) < 7.0, "7. about 5 of its 8 pips from medium at the ideal release: %.2f" % float(top["mean"]))
	eq(top["health"], 8, "7. of 8")
	check(float(top["p_destroy"]) > 0.0 and float(top["p_destroy"]) < 1.0, "7. with a chance of destroying it (%.2f)" % float(top["p_destroy"]))
	check(float(top["mean"]) <= float(top["mean_raw"]) + 1e-9, "7. capped at its health")
	var again := w.drop_expected("bomber", 0, tower)
	check(WorldSync.same(list, again), "7. the sample is fixed: asked twice, the same answer")
	# Farther from the aim, less damage; at the rim, less than at the ideal.
	var far := w.drop_expected("bomber", 0, tower + Vector2(0.0, 40.0))
	var far_mean := float((far[0] as Dictionary)["mean"]) if far.size() > 0 and (far[0] as Dictionary)["unit"] == "tower" else 0.0
	check(far_mean < float(top["mean"]), "7. an aim 40 m off the tower hurts it less (%.2f against %.2f)" % [far_mean, float(top["mean"])])
	var edge := w.drop_expected("bomber", 0, tower + Vector2(0.0, _across_for_r(w, 0.95)))
	var edge_mean := float((edge[0] as Dictionary)["mean"]) if edge.size() > 0 and (edge[0] as Dictionary)["unit"] == "tower" else 0.0
	check(edge_mean < float(top["mean"]), "7. and an aim on the rim of the cone less again (%.2f)" % edge_mean)
	# Outside the cone: hold hurts nothing; poor_shot hurts less.
	eq(w.drop_expected("bomber", 0, tower + Vector2(0.0, 700.0)), [], "7. hold: an aim outside the cone is expected to hurt nothing")
	var p := _world("poor_shot", 11)
	var outside := p.drop_expected("bomber", 0, tower + Vector2(0.0, 700.0))
	check(outside.is_empty() or float((outside[0] as Dictionary)["mean"]) < float(top["mean"]), "7. poor_shot: an aim outside the cone does less than the ideal one")
	# The model's own pieces.
	var d := Bombs.plan_drop(Bombs.make_samples(w.units["bomber"].state(), w.planned_states("bomber")[0], 0.0, w.step_dt("bomber"), w.band_height("medium"), w.band_height("medium"), w.bombs.release_samples), tower.x, tower.y, w.bombs)
	var air := BombExpect.damage(d, 4, w.bombs, tower, 8, 400.0)
	eq(air["mean"], 0.0, "7. a unit in the air takes nothing (bombs cannot hurt planes today)")
	eq(BombExpect.damage(d, 0, w.bombs, tower, 8)["mean"], 0.0, "7. a stick of no bombs does nothing")
	eq(BombExpect.damage(d, 4, w.bombs, tower, 0)["mean"], 0.0, "7. a unit with no health left takes nothing")
	check(BombExpect.reach_m(d, 4, w.bombs) > w.bombs.blast_radius_m(), "7. the reach is beyond the blast's own")
	return true
