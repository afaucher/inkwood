extends "res://scripts/test_support/test_case.gd"

# THE WARSHIP (Track SH, the warship, proposed 2026-10-10; Alex, decisions mixed-warfare, special-targeting, target-follows-unit,
# step-selection: the small cruiser's main guns are a special, fired by hand with a long reload at a SPOTTED target, aimed with the
# target selection; shared spotting: any friendly unit's sight counts; the sea guns attack the coast, not inland). The sim side; the
# card, the lettering and the art are test_ui_guns's.
#
#   - the cruiser loads, is a sea unit of the sheet's size, and stays afloat
#   - its light anti-aircraft guns fire at a low plane and never at a medium one
#   - main guns cannot be activated at a target that is unspotted, out of range, inland, too close, ... and the answer says why
#   - shared spotting: a friendly tower, tank or plane spots for the ship; a downed spotter does not; the line of sight is a seam
#   - a salvo fires at its moment, its shells fly for a time set by the range, land (in a later turn) near the target and damage it
#   - the scatter grows with the range, tightens with the time spotted and with successive salvos; a break in sight starts it again
#   - a target no longer spotted at the moment of fire (or out of reach) is fired at POORLY, the reload spent: Alex, decision
#     outside-cone-release, 2026-10-11: "Fire a poorer one" -- at its last spotted place, the scatter doubled, clamped to the reach;
#     gun_unspotted_mode "hold" keeps the old answer (not fired, nothing spent); a target already down is held either way
#   - the reload; a shell in flight across a turn end lands identically on a client and on a joiner; the blast hurts a friend
#   - the blast: Alex (decision shell-blast, 2026-10-11): "for the smaller ship lets do high damage smaller range" -- 6 / 12 / 20 m, 4 / 3 / 2
#     pips; a fresh direct salvo cannot one-shot a bridge (Alex, bridge-durability: "it should take a lot"), one with the range found can
#   - what a request may be (plan_step), the special's words

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Guns = preload("res://scripts/sim/guns.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")
const Spotting = preload("res://scripts/sim/spotting.gd")
const CombatResolver = preload("res://scripts/sim/combat_resolver.gd")
const Combat = preload("res://scripts/sim/combat.gd")

# A stand-in for the fog's FogVision: the three calls Spotting.los_from_vision makes.
class FakeVision:
	var on := false
	var clear := true
	var asked := 0
	var last_target_agl := -1.0
	func los_on() -> bool:
		return on
	func engine() -> Object:
		return self
	func unit_agl(_world: Object, u: Object, _x: float, _y: float, _band: String = "", _h: float = NAN) -> float:
		return 1.5 if str(u.def.domain) != "air" else 100.0
	func visible_from(_eye: Vector2, _eye_agl: float, _point: Vector2, target_agl: float) -> bool:
		asked += 1
		last_target_agl = target_agl
		return clear

var _sentinel := 0

func setup(_main) -> void:
	timeout_seconds = 240.0
	_unit_data()
	_afloat()
	_anti_air()
	_requests()
	_activation()
	_spotting()
	_salvo()
	_salvo_for_a_tank_and_a_plane()
	_scatter()
	_bracketing()
	_hold()
	_poor_shot()
	_reload()
	_carried()
	_friendly_fire()
	_blast_and_bridge()
	check(_sentinel == 16, "every part of the test ran (%d of 16)" % _sentinel)
	finish()

# Equality that treats NaN as equal to NaN.
func _same(a: Variant, b: Variant) -> bool:
	if a is float and b is float:
		return a == b or (is_nan(a) and is_nan(b))
	if a is Dictionary and b is Dictionary:
		if (a as Dictionary).size() != (b as Dictionary).size():
			return false
		for k: Variant in a:
			if not (b as Dictionary).has(k) or not _same(a[k], b[k]):
				return false
		return true
	if a is Array and b is Array:
		if (a as Array).size() != (b as Array).size():
			return false
		for i in (a as Array).size():
			if not _same(a[i], b[i]):
				return false
		return true
	return a == b

func _spec() -> GunRules.Spec:
	return GunRules.new().special("main_guns")

# --- The unit ------------------------------------------------------------------------------------------------------

func _unit_data() -> void:
	var w := GunWorlds.world(1)
	check(w.ok(), "the World loads its rules, the guns' too: %s" % str(w.errors))
	var rules := GunRules.new()
	check(rules.ok(), "data/sim/guns.json loads: %s" % str(rules.errors))
	check(rules.has_special("main_guns"), "main_guns has a record there")
	var def := w.unit_def("cruiser")
	check(def != null, "the cruiser loads: %s" % w.last_error)
	if def == null:
		return
	eq(def.domain, "sea", "a sea unit")
	eq(def.mobility, "mobile", "that moves")
	check(def.size_m >= 112.0 and def.size_m <= 128.0, "the unit sheet's small cruiser is 112 to 128 m: %.0f" % def.size_m)
	check(def.draught_m >= 5.0, "a draught that keeps it in deep water: %.1f m" % def.draught_m)
	check(def.sight_range_m > 800.0, "a long sight, over a fighter's 800 m: %.0f m" % def.sight_range_m)
	check(def.health > 8, "the hardest unit to sink: %d pips" % def.health)
	check(def.envelope.speed_max >= 14.0 and def.envelope.speed_max <= 16.0, "about 15 m/s flat out: %.1f" % def.envelope.speed_max)
	check(def.envelope.turn_rate(def.envelope.speed_cruise) * def.actions_per_turn > 0.0, "it turns")
	var radius := def.envelope.speed_cruise / def.envelope.turn_rate(def.envelope.speed_cruise)
	check(radius > 1.2 * def.size_m, "a large turn radius, over its length and a bit: %.0f m for a hull of %.0f m" % [radius, def.size_m])
	eq(def.specials.size(), 1, "ONE special: a single unit, not a nest")
	eq(str(def.specials[0]["id"]), "main_guns", "main_guns")
	eq(def.special_label("main_guns"), "Main Guns Fire", "the step is lettered with the special's name and its action")
	check(not def.carries_bombs(), "it drops nothing")
	eq(def.weapons.size(), 1, "one set of guns that fire by themselves")
	# DECISION weapon-kinds (Alex, 2026-10-11): the cruiser's AA is FLAK ("shells shot that then explode", pointed up), not machine guns
	eq(str(def.weapons[0].id), "ship_flak", "the anti-aircraft guns are flak")
	check(def.weapons[0].hardpoints.size() >= 4, "on several mounts: %d" % def.weapons[0].hardpoints.size())
	eq(w.gun_specials("cruiser"), ["main_guns"] as Array[String], "the World sees the gun special")
	check(w.gun_specials("spotter").is_empty() and w.gun_specials("aa").is_empty(), "and no other unit has one")
	_sentinel += 1

func _afloat() -> void:
	var w := GunWorlds.world(1)
	check(w.unit_afloat("cruiser"), "the cruiser is afloat where it lies")
	var land := w.add_unit({"id": "stranded", "type": "cruiser", "side": "allies", "controller": "player", "x": 1760.0, "y": 2500.0, "heading": 0.0})
	eq(land, "", "it will not be put where it would not float (20 m off the shore: its ends are on land)")
	# Steer for the land every step for ten turns: the water rule holds it off the shore.
	w.units["cruiser"].x = 1250.0
	w.units["cruiser"].speed = 12.0
	var shore_seen := false
	for _t in 10:
		for k in 2:
			w.plan_step("cruiser", k, {"to": Vector2(2400.0, 2500.0), "speed": 15.0})
		for st: Dictionary in w.planned_states("cruiser"):
			if (st["limits"] as Array).has("shore"):
				shore_seen = true
		GunWorlds.next_turn(w)
		check(w.unit_afloat("cruiser"), "turn %d: still afloat at x = %.0f" % [w.turn, w.units["cruiser"].x])
	var cx: float = w.units["cruiser"].x
	check(cx < GunWorlds.COAST_X - 60.0, "and held off the coast by its own length: x = %.0f, the coast at %.0f" % [cx, GunWorlds.COAST_X])
	check(cx > 1450.0, "it did sail towards it: x = %.0f" % cx)
	check(shore_seen, "the plan reported the shore limit")
	_sentinel += 1

# --- The anti-aircraft guns ------------------------------------------------------------------------------------------

func _plane_world(band: String, seed_value: int) -> World:
	var w := GunWorlds.world(seed_value)
	w.add_player("local")
	w.add_unit({"id": "bandit", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 450.0, "y": 2500.0, "heading": 0.0, "altitude_band": band})
	return w

func _anti_air() -> void:
	var fired_low := 0
	var fired_medium := 0
	for seed_value in [1, 2, 3]:
		var w := _plane_world("low", seed_value)
		var res := GunWorlds.turn(w)
		check(not res.is_empty(), "the low-plane turn resolves: %s" % w.last_error)
		for ev: Dictionary in GunWorlds.events_of(res, "fire", "cruiser"):
			fired_low += 1
			eq(str(ev["weapon"]), "ship_flak", "the cruiser fires its flak")
			eq(str(ev["target"]), "bandit", "at the plane")
		var wm := _plane_world("medium", seed_value)
		var resm := GunWorlds.turn(wm)
		fired_medium += GunWorlds.events_of(resm, "fire", "cruiser").size()
	check(fired_low > 10, "its guns fire at a plane over it in the low band: %d rolls in three turns" % fired_low)
	eq(fired_medium, 0, "and never at one in the medium band (the light guns reach 320 m)")
	# FLAK POINTS UP (decision weapon-kinds; Alex: "flak guns have better coverage in the area directly above them"): the cone covers a low
	# plane straight over the ship, and one 300 m out; a medium plane straight over is out of REACH (400 m up, the guns reach 384 m)
	var cw := GunWorlds.world(1)
	var flak = cw.unit_def("cruiser").weapons[0]
	var low_m := cw.band_height("low")
	var shoot := func(tx: float, th: float) -> Dictionary:
		return Combat.evaluate({"x": 0.0, "y": 0.0, "heading": 0.0, "height_m": 0.0}, flak, 0, {"x": tx, "y": 0.0, "height_m": th}, cw.combat.odds_factors, cw.combat.factor_params())
	var over: Dictionary = shoot.call(0.0, low_m)
	check(over["in_cone"] and float(over["odds"]) > 0.0, "the flak cone covers a low plane straight over the ship (odds %.4f)" % float(over["odds"]))
	var out300: Dictionary = shoot.call(300.0, low_m)
	check(out300["in_cone"] and float(out300["odds"]) > 0.0, "...and one 300 m out (odds %.4f)" % float(out300["odds"]))
	check(not (shoot.call(0.0, cw.band_height("medium")) as Dictionary)["in_cone"], "...but not a medium plane over it: out of reach, as before")
	_sentinel += 1

# --- What a request may be -----------------------------------------------------------------------------------------------

func _requests() -> void:
	var w := GunWorlds.world(1)
	var st := GunWorlds.fire(w, "aa")
	check(not st.is_empty(), "a fire at a spotted unit is planned: %s" % w.last_error)
	check(st.has("fire") and st["fire"]["ok"] == true, "the step's state carries the analysis: ok")
	eq(str(st["fire"]["special"]), "main_guns", "of the special")
	eq(st["fire"]["target"], {"unit": "aa"}, "and its target")
	near(float(st["fire"]["fire_t"]), 0.5 * w.step_dt("cruiser"), 1e-9, "fired at the middle of the step (fire_at 0.5)")
	near(float(st["fire"]["range_m"]), 1200.0, 0.5, "1,200 m away")
	# The step is flown as asked: the fire changes nothing about it.
	var a := GunWorlds.world(1)
	var b := GunWorlds.world(1)
	var sa := a.plan_step("cruiser", 0, {"turn": 0.05, "speed": 10.0})
	var sb := b.plan_step("cruiser", 0, {"turn": 0.05, "speed": 10.0, "fire": {"special": "main_guns", "target": {"unit": "aa"}}})
	for k: String in ["x", "y", "heading", "speed", "turn", "clamped"]:
		eq(sa[k], sb[k], "a fire changes nothing about how the step is flown (%s)" % k)
	# A point target, with the aim the target was shown at.
	var wp := GunWorlds.world(1)
	check(not wp.plan_step("cruiser", 1, {"fire": {"special": "main_guns", "target": {"point": [1800.0, 2500.0]}, "aim": [1800.0, 2500.0]}}).is_empty(), "a point target, with an aim")
	# Bad requests are refused and leave the plan alone.
	var before: Array = (w.units["cruiser"].plan as Array).duplicate(true)
	var bad: Array = [
		["a fire that is not an object", {"fire": 5}],
		["a fire with no special", {"fire": {"target": {"unit": "aa"}}}],
		["a fire with no target", {"fire": {"special": "main_guns"}}],
		["a target with both a unit and a point", {"fire": {"special": "main_guns", "target": {"unit": "aa", "point": [1.0, 1.0]}}}],
		["a target point with one number", {"fire": {"special": "main_guns", "target": {"point": [1.0]}}}],
		["an infinite aim", {"fire": {"special": "main_guns", "target": {"unit": "aa"}, "aim": [INF, 0.0]}}],
		["an unknown field", {"fire": {"special": "main_guns", "target": {"unit": "aa"}, "pips": 3}}],
		["a special that is not a gun", {"fire": {"special": "bomb", "target": {"unit": "aa"}}}],
		["a special the unit does not have", {"fire": {"special": "nope", "target": {"unit": "aa"}}}],
		["a target unit that does not exist", {"fire": {"special": "main_guns", "target": {"unit": "ghost"}}}],
		["a fire and a drop in one step", {"fire": {"special": "main_guns", "target": {"unit": "aa"}}, "drop": {"aim": [1.0, 1.0]}}],
	]
	for c: Array in bad:
		w.last_error = ""
		eq(w.plan_step("cruiser", 1, c[1]), {}, "refused: %s" % c[0])
		check(w.last_error != "", "...and it says why: %s" % w.last_error)
	eq(w.units["cruiser"].plan, before, "the plan is untouched by the refusals")
	# One salvo a turn: the second fire in a plan is refused.
	w.last_error = ""
	eq(w.plan_step("cruiser", 1, {"fire": {"special": "main_guns", "target": {"unit": "aa"}}}), {}, "a second fire in the same plan is refused")
	check(w.last_error.contains("one salvo a turn"), "...one salvo a turn: %s" % w.last_error)
	# Re-planning the same step is not a second one.
	check(not w.plan_step("cruiser", 0, {"fire": {"special": "main_guns", "target": {"unit": "aa"}}}).is_empty(), "the same step planned again is replaced, not refused")
	# A unit without the special.
	var f := GunWorlds.world(1)
	f.add_unit({"id": "f", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 2000.0, "heading": 0.0, "altitude_band": "medium"})
	eq(f.plan_step("f", 0, {"fire": {"special": "main_guns", "target": {"unit": "aa"}}}), {}, "a fighter cannot fire main guns")
	check(f.last_error.contains("no special"), "...it has no such special: %s" % f.last_error)
	# Bomb Drop is as it was: a bomber's drop is planned beside it.
	var bw := World.new()
	bw.quiet = true
	bw.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": 2500.0, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
	check(not bw.plan_step("bomber", 0, {"drop": {"aim": [1200.0, 2500.0]}}).is_empty(), "a bomber still plans its drop")
	eq(bw.plan_step("bomber", 1, {"fire": {"special": "main_guns", "target": {"unit": "bomber"}}}), {}, "and cannot fire guns it has not got")
	_sentinel += 1

# --- Activation --------------------------------------------------------------------------------------------------------------

func _reason(w: World, target: Variant, step: int = 0) -> String:
	var t: Dictionary = {"unit": target} if target is String else {"point": [(target as Vector2).x, (target as Vector2).y]}
	return str(w.gun_check("cruiser", step, t)["reason"])

func _activation() -> void:
	var w := GunWorlds.world(1)
	var ok := w.gun_check("cruiser", 0, {"unit": "aa"})
	check(ok["ok"] == true and ok["reason"] == "", "a spotted enemy on the coast in range can be fired at: %s" % ok["reason"])
	check(bool(ok["spotted"]) and ok["by"] == "spotter", "spotted by the tower: '%s'" % ok["by"])
	near(float(ok["range_m"]), 1200.0, 0.5, "1,200 m")
	check(float(ok["spread_m"]) > 20.0 and float(ok["spread_m"]) < 40.0, "with the scatter it would get: %.1f m" % float(ok["spread_m"]))
	near(float(ok["flight_s"]), 1200.0 / _spec().shell_speed_mps, 1e-6, "the shells fly for their range over their speed")
	eq(int(ok["lands_in_turn"]), 2, "and land in the next turn (impact at %.2f s)" % float(ok["impact_t"]))
	# Each way it cannot be activated, with its reason.
	var far := w.add_unit({"id": "aa_far", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 1900.0, "y": 3300.0, "heading": 0.0})
	check(far != "", "an enemy battery 800 m from the tower: %s" % w.last_error)
	eq(_reason(w, "aa_far"), "unspotted", "an enemy no friendly unit sees: unspotted")
	var chk := w.gun_check("cruiser", 0, {"unit": "aa_far"})
	check(not bool(chk["spotted"]) and float(chk["range_m"]) < 3000.0, "...though it is in range (%.0f m)" % float(chk["range_m"]))
	w.add_unit({"id": "aa_edge", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 4800.0, "y": 2500.0, "heading": 0.0})
	eq(_reason(w, "aa_edge"), "out_of_range", "an enemy 4,200 m away: out of range")
	w.add_unit({"id": "aa_in", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 3200.0, "y": 2500.0, "heading": 0.0})
	eq(_reason(w, "aa_in"), "inland", "an enemy 2,600 m away in range but 1,500 m inland: the guns attack the coast, not inland (Alex)")
	check(float(w.gun_check("cruiser", 0, {"unit": "aa_in"})["range_m"]) < _spec().range_max_m, "...it is inside the guns' range: %.0f m" % float(w.gun_check("cruiser", 0, {"unit": "aa_in"})["range_m"]))
	eq(_reason(w, Vector2(700.0, 2500.0)), "too_close", "a point alongside the ship: too close")
	eq(_reason(w, "spotter"), "own_side", "a friend: its own side")
	var dead := GunWorlds.world(1)
	dead.units["aa"].down = true
	eq(str(dead.gun_check("cruiser", 0, {"unit": "aa"})["reason"]), "target_down", "a unit already down: target_down")
	eq(str(w.gun_check("cruiser", 0, {})["reason"]), "no_target", "no target: no_target")
	eq(str(w.gun_check("spotter", 0, {"unit": "aa"})["reason"]), "not_a_gun", "a unit with no gun special: not_a_gun")
	eq(w.gun_check("ghost", 0, {"unit": "aa"}), {}, "an unknown unit is an error")
	eq(w.gun_check("cruiser", 5, {"unit": "aa"}), {}, "and so is a step the unit does not have")
	# The ranges are the data's, edge to edge.
	var spec := _spec()
	eq(Guns.range_error(spec.range_min_m - 1.0, spec), "too_close", "just inside the minimum")
	eq(Guns.range_error(spec.range_min_m + 1.0, spec), "", "just outside it")
	eq(Guns.range_error(spec.range_max_m - 1.0, spec), "", "just inside the maximum")
	eq(Guns.range_error(spec.range_max_m + 1.0, spec), "out_of_range", "just outside it")
	check(spec.inland_max_m > 0.0 and spec.inland_max_m < spec.range_max_m, "the coastal strip (%.0f m) is shorter than the range (%.0f m)" % [spec.inland_max_m, spec.range_max_m])
	# With no water in the World there is no coast: the rule is off.
	var dry := GunWorlds.world(1, false)
	dry.add_unit({"id": "aa_in", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 3200.0, "y": 2500.0, "heading": 0.0})
	check(str(dry.gun_check("cruiser", 0, {"unit": "aa_in"})["reason"]) != "inland", "a World with no water has no coast")
	# Where the ship will be is what counts: the plan moves it out of range.
	var mv := GunWorlds.world(1)
	mv.units["cruiser"].speed = 12.0
	for k in 2:
		mv.plan_step("cruiser", k, {"turn": -0.3, "speed": 15.0})
	var mc := mv.gun_check("cruiser", 1, {"unit": "aa"})
	var still := GunWorlds.world(1).gun_check("cruiser", 1, {"unit": "aa"})
	check(absf(float(mc["range_m"]) - float(still["range_m"])) > 5.0, "the range is from where the step puts the ship: %.0f m, from rest %.0f m" % [float(mc["range_m"]), float(still["range_m"])])
	# The step the plan fires from must exist.
	check(float(mv.gun_check("cruiser", 1, {"unit": "aa"})["fire_t"]) > float(mv.gun_check("cruiser", 0, {"unit": "aa"})["fire_t"]), "a later step fires later")
	_sentinel += 1

# --- Shared spotting ------------------------------------------------------------------------------------------------------------

func _spotting() -> void:
	var w := GunWorlds.world(1)
	var tgt := {"unit": "aa"}
	check(w.spotted_now("allies", tgt), "the tower sees the battery for its side")
	check(not w.spotted_now("axis", {"unit": "cruiser"}), "the enemy does not see the cruiser (1,200 m)")
	eq(w.spotters_now("allies", tgt), ["spotter"] as Array[String], "who sees it")
	check(w.spotted_now("allies", {"point": [1800.0, 2500.0]}), "a point near the tower is spotted too")
	check(not w.spotted_now("allies", {"point": [1800.0, 3500.0]}), "a point in the fog is not (Alex: the target location 'needs to be found')")
	# A friendly TANK spots for the ship, from a place the tower does not see.
	var far := w.add_unit({"id": "aa_far", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 1900.0, "y": 3300.0, "heading": 0.0})
	check(far != "" and not w.spotted_now("allies", {"unit": "aa_far"}), "a battery nobody sees")
	var tank := w.add_unit({"id": "tank", "type": "tank", "side": "allies", "controller": "player", "x": 1900.0, "y": 3000.0, "heading": 0.0})
	check(tank != "", "a friendly tank: %s" % w.last_error)
	check(w.spotted_now("allies", {"unit": "aa_far"}), "a friendly tank 300 m away sees it for the whole side")
	eq(w.spotters_now("allies", {"unit": "aa_far"}), ["tank"] as Array[String], "the tank")
	eq(str(w.gun_check("cruiser", 0, {"unit": "aa_far"})["reason"]), "", "and the ship can fire at it")
	# A friendly PLANE does too.
	var w2 := GunWorlds.world(1)
	w2.add_unit({"id": "aa_far", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 1900.0, "y": 3300.0, "heading": 0.0})
	w2.add_unit({"id": "scout", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 3300.0, "heading": 0.0, "altitude_band": "medium"})
	check(w2.spotted_now("allies", {"unit": "aa_far"}), "a friendly plane 400 m away sees it")
	# An enemy's sight is not ours: a unit of the other side does not spot for us.
	var w3 := GunWorlds.world(1)
	w3.units["spotter"].side = "axis"
	check(not w3.spotted_now("allies", {"unit": "aa"}), "a unit of the other side spots for nobody of ours")
	# A spotter that is destroyed no longer spots.
	var w4 := GunWorlds.world(1)
	w4.units["spotter"].down = true
	w4.units["spotter"].fate = "destroyed"
	check(not w4.spotted_now("allies", tgt), "a destroyed spotter sees nothing (sight follows the pilot)")
	# The sight scale (the fog's knob) and the line of sight are seams.
	var w5 := GunWorlds.world(1)
	w5.set_sight_scale(0.3)
	check(not w5.spotted_now("allies", tgt), "the fog's sight scale applies: 0.3 of 500 m is 150 m, the battery is 200 m away")
	w5.set_sight_scale(1.0)
	check(w5.spotted_now("allies", tgt), "...and back")
	var asked: Array = []
	w5.set_sight_los(func(eye: Dictionary, target: Dictionary) -> bool:
		asked.append([eye["unit"].id, target["x"]])
		return false)
	check(not w5.spotted_now("allies", tgt), "a line of sight that is blocked takes the target out of sight")
	check(asked.size() >= 1 and asked[0][0] == "spotter", "...it was asked of the tower (inside its circle) only: %s" % str(asked))
	w5.set_sight_los(func(_e: Dictionary, _t: Dictionary) -> bool: return true)
	check(w5.spotted_now("allies", tgt), "a clear line of sight changes nothing")
	w5.set_sight_los(Callable())
	check(w5.spotted_now("allies", tgt), "and none is the circle alone (the fog's default)")
	# The fog's own line of sight, handed over as the spotting's (Spotting.los_from_vision): asked of the vision each time.
	var vision := FakeVision.new()
	w5.set_sight_los(Spotting.los_from_vision(vision, w5))
	check(w5.spotted_now("allies", tgt), "a vision with its line of sight off sees as the circle does")
	vision.on = true
	vision.clear = false
	check(not w5.spotted_now("allies", tgt), "the same vision, line of sight on and blocked: out of sight")
	eq(vision.last_target_agl, 1.5, "the target is judged at its own height (the vision's unit_agl for the battery)")
	vision.clear = true
	check(w5.spotted_now("allies", tgt) and vision.asked > 0, "clear: spotted, and the vision was asked")
	check(w5.spotted_now("allies", {"point": [1800.0, 2480.0]}) and vision.last_target_agl == 0.0, "a point is the ground itself")
	# The nearest spotter's closeness tightens the scatter: the same target with the tower close, and far (near the edge of its 500 m sight).
	var near_w := GunWorlds.world(1)
	var far_w := GunWorlds.world(1)
	far_w.units["spotter"].x = GunWorlds.TARGET.x + 450.0
	var c_near := near_w.gun_check("cruiser", 0, tgt)
	var c_far := far_w.gun_check("cruiser", 0, tgt)
	check(float(c_near["spotter_ratio"]) < float(c_far["spotter_ratio"]), "closeness: the tower is %.2f of its sight from the target, then %.2f" % [float(c_near["spotter_ratio"]), float(c_far["spotter_ratio"])])
	check(float(c_far["spread_m"]) > float(c_near["spread_m"]) * 1.1, "...and the scatter is wider with the far spotter: %.1f against %.1f m" % [float(c_far["spread_m"]), float(c_near["spread_m"])])
	_sentinel += 1

# --- The salvo ------------------------------------------------------------------------------------------------------------------

func _salvo() -> void:
	var w := GunWorlds.world(7)
	var spec := _spec()
	# The guns have been ranged in on the battery for a while (a long-spotted target), so the salvo is tight.
	w.spot_memory = {"allies": {"aa": 20.0}}
	w.gun_memory = [{"side": "allies", "unit": "aa", "point": [], "salvos": 2, "turn": 0}]
	var st := GunWorlds.fire(w, "aa")
	check(not st.is_empty() and st["fire"]["ok"] == true, "planned: %s" % w.last_error)
	check(float(st["fire"]["spread_m"]) < 12.0, "ranged in and bracketed, the planned scatter is small: %.1f m" % float(st["fire"]["spread_m"]))
	eq(w.shells_in_flight.size(), 0, "nothing is in the air yet")
	var res := GunWorlds.turn(w)
	check(not res.is_empty(), "the turn resolves: %s" % w.last_error)
	var fires := GunWorlds.events_of(res, "shell_fire", "cruiser")
	eq(fires.size(), 1, "one salvo")
	if fires.size() != 1:
		return
	var fe: Dictionary = fires[0]
	near(float(fe["t"]), 1.25, 1e-9, "fired at the middle of step 0")
	eq(int(fe["shells"]), spec.shells, "%d shells" % spec.shells)
	near(float(fe["range_m"]), 1200.0, 1.0, "at 1,200 m")
	near(float(fe["flight_s"]), 1200.0 / spec.shell_speed_mps, 0.01, "they fly for %.1f s" % float(fe["flight_s"]))
	check(float(fe["impact_t"]) > 5.0, "and land after this turn (at %.2f s)" % float(fe["impact_t"]))
	check(bool(fe["followed"]), "a unit target is followed")
	near(float(fe["spotted_s"]), 20.0 + 1.25, 0.01, "spotted for the carried 20 s and the 1.25 s of this turn")
	eq(int(fe["salvos_before"]), 2, "two salvos already at it")
	eq(w.shells_in_flight.size(), spec.shells, "the shells are in the air at the end of the turn")
	eq(w.units["aa"].health, 4, "and have hurt nothing")
	eq(GunWorlds.events_of(res, "shell_impact").size(), 0, "no impacts yet")
	eq(int(w.units["cruiser"].gun_ready["main_guns"]), 1 + spec.reload_turns + 1, "the guns are reloading until turn %d" % (1 + spec.reload_turns + 1))
	var first_release := INF
	for sh: Dictionary in w.shells_in_flight:
		eq(int(sh["impact_turn"]), 2, "a shell lands in turn 2")
		first_release = minf(first_release, float(sh["release_t"]))
		near(float(sh["fall_s"]), float(fe["flight_s"]), 1e-9, "after its flight time")
	near(first_release, 1.25, 1e-9, "the first shell leaves at the moment of fire")
	# Where a shell is, for the effects.
	var s0: Dictionary = w.shells_in_flight[0]
	var pos := Guns.shell_position(s0, 1, 2.0, 5.0)
	eq(pos["state"], "falling", "in the air between the guns and the target")
	check(float(pos["height_m"]) > 0.0 and float(pos["x"]) > GunWorlds.SHIP.x, "high, and on its way")
	# Turn 2: the shells land, near the target, and hurt it.
	w.begin_turn()
	var res2 := GunWorlds.turn(w)
	var impacts := GunWorlds.events_of(res2, "shell_impact", "cruiser")
	eq(impacts.size(), spec.shells, "all %d shells land in the second turn" % spec.shells)
	var worst := 0.0
	var last_t := -1.0
	for ev: Dictionary in impacts:
		eq(int(ev["turn"]), 2, "reported in the turn it lands in")
		check(int(ev["released_turn"]) == 1, "...released in turn 1")
		var d := Vector2(float(ev["x"]) - GunWorlds.TARGET.x, float(ev["y"]) - GunWorlds.TARGET.y).length()
		worst = maxf(worst, d)
		check(float(ev["t"]) >= last_t, "in time order")
		last_t = float(ev["t"])
		var flown := (float(ev["turn"]) - float(ev["released_turn"])) * 5.0 + float(ev["t"]) - float(ev["released_t"])
		near(flown, float(fe["flight_s"]), 0.25, "each flew its flight time (one combat tick)")
	print("  salvo: sigma %.1f m, worst shell %.1f m from the battery, battery %d pips, flight %.2f s, impact %.2f s" % [float(fe["spread_m"]), worst, w.units["aa"].health, float(fe["flight_s"]), float(fe["impact_t"])])
	check(worst < 40.0, "near the target: the worst shell %.1f m from it" % worst)
	check(w.units["aa"].health < 4, "and it damaged the battery: %d of 4 pips left" % w.units["aa"].health)
	var hits := GunWorlds.events_of(res2, "hit", "aa")
	check(not hits.is_empty() and str(hits[0]["by"]) == "cruiser" and str(hits[0]["weapon"]) == "main_guns", "the hit is the main guns'")
	eq(w.shells_in_flight.size(), 0, "nothing is left in the air")
	if w.units["aa"].down:
		eq(w.units["aa"].fate, "destroyed", "a ground unit at 0 pips is destroyed")
	# A POINT target is fixed: the salvo goes where it was sent whatever happens.
	var wp := GunWorlds.world(7)
	wp.plan_step("cruiser", 0, {"fire": {"special": "main_guns", "target": {"point": [1800.0, 2480.0]}}})
	var rp := GunWorlds.turn(wp)
	var fp := GunWorlds.events_of(rp, "shell_fire", "cruiser")
	eq(fp.size(), 1, "a point target in sight is fired at")
	if fp.size() == 1:
		check(not bool(fp[0]["followed"]), "a point is not followed")
		near(float(fp[0]["aim"][1]), 2480.0, 1e-6, "and aimed where it is")
	_sentinel += 1

# THE ROLES, end to end: a friendly tank on the ground, and a friendly plane overhead, spot a battery the tower does not see, and the
# ship's salvo fires at it, lands after its flight and hurts it.
func _salvo_for_a_tank_and_a_plane() -> void:
	for kind: String in ["tank", "plane"]:
		var w := GunWorlds.world(21)
		w.add_unit({"id": "aa_far", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 1900.0, "y": 3300.0, "heading": 0.0})
		w.spot_memory = {"allies": {"aa_far": 20.0}}
		w.gun_memory = [{"side": "allies", "unit": "aa_far", "point": [], "salvos": 2, "turn": 0}]
		if kind == "tank":
			check(w.add_unit({"id": "eyes", "type": "tank", "side": "allies", "controller": "player", "x": 1900.0, "y": 3000.0, "heading": 0.0, "speed": 0.0}) != "", "a friendly tank: %s" % w.last_error)
		else:
			check(w.add_unit({"id": "eyes", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 3300.0, "heading": 0.0, "altitude_band": "medium"}) != "", "a friendly plane: %s" % w.last_error)
		var st := GunWorlds.fire(w, "aa_far")
		check(not st.is_empty() and st["fire"]["ok"] == true, "%s: the ship plans a salvo at a battery only the %s sees: %s" % [kind, kind, str(st.get("fire", w.last_error))])
		var res := GunWorlds.turn(w)
		var fe := GunWorlds.events_of(res, "shell_fire", "cruiser")
		if not check(fe.size() == 1, "%s: the salvo fires" % kind):
			continue
		check(float(fe[0]["spotted_s"]) > 20.0, "%s: ranged in on a target spotted for %.1f s" % [kind, float(fe[0]["spotted_s"])])
		w.begin_turn()
		var res2 := GunWorlds.turn(w)
		var impacts := GunWorlds.events_of(res2, "shell_impact", "cruiser")
		eq(impacts.size(), _spec().shells, "%s: the shells land in the next turn" % kind)
		var worst := 0.0
		for ev: Dictionary in impacts:
			worst = maxf(worst, Vector2(float(ev["x"]) - 1900.0, float(ev["y"]) - 3300.0).length())
		check(worst < 50.0, "%s: near the target (worst %.1f m)" % [kind, worst])
		check(w.units["aa_far"].health < 4, "%s: and the battery is hurt (%d of 4 pips)" % [kind, w.units["aa_far"].health])
	_sentinel += 1

# --- Scatter ------------------------------------------------------------------------------------------------------------------

# The RMS distance of the shells of many salvos from their aim (the dice are the game's): seeds 1..n of the World's.
func _rms(range_m: float, spotted_s: float, salvos: int, seeds: int = 40) -> float:
	var spec := _spec()
	var sigma := Guns.sigma_m(range_m, spotted_s, spec, salvos)
	var aim := Vector2(2000.0, 2500.0)
	var total := 0.0
	var n := 0
	for s in range(1, seeds + 1):
		var shells := Guns.make_salvo({"unit": "cruiser", "special": "main_guns", "step": 0, "t": 1.0, "from": aim - Vector2(range_m, 0.0), "aim": aim,
			"range_m": range_m, "flight_s": Guns.flight_time(range_m, spec), "sigma_m": sigma}, spec, s, 1, 0)
		for sh: Dictionary in shells:
			total += (Vector2(float(sh["x"]), float(sh["y"])) - aim).length_squared()
			n += 1
	return sqrt(total / float(n) / 2.0)   # per axis, to compare with sigma

func _scatter() -> void:
	var spec := _spec()
	var s600 := Guns.sigma_m(600.0, 0.0, spec)
	var s1200 := Guns.sigma_m(1200.0, 0.0, spec)
	var s2000 := Guns.sigma_m(2000.0, 0.0, spec)
	var s3000 := Guns.sigma_m(3000.0, 0.0, spec)
	check(s600 < s1200 and s1200 < s2000 and s2000 < s3000, "the scatter grows with the range: %.0f, %.0f, %.0f, %.0f m at 600, 1200, 2000, 3000 m" % [s600, s1200, s2000, s3000])
	print("  sigma by range (fresh target): 600 m %.1f, 1200 m %.1f, 2000 m %.1f, 3000 m %.1f" % [s600, s1200, s2000, s3000])
	check(s3000 > 2.0 * s600, "CLEARLY: the edge of the range scatters more than twice what 600 m does (%.0f against %.0f m)" % [s3000, s600])
	# It tightens with the time spotted, to a floor.
	var t0 := Guns.sigma_m(2000.0, 0.0, spec)
	var t10 := Guns.sigma_m(2000.0, spec.ranging_s * 0.5, spec)
	var t20 := Guns.sigma_m(2000.0, spec.ranging_s, spec)
	var t60 := Guns.sigma_m(2000.0, spec.ranging_s * 3.0, spec)
	check(t0 > t10 and t10 > t20, "the longer the target has been spotted, the tighter: %.1f, %.1f, %.1f m" % [t0, t10, t20])
	near(t60, t20, 1e-9, "to a floor (ranging_s)")
	near(t20 / t0, spec.ranged_factor / spec.unranged_factor, 1e-9, "the ranged factor")
	# ... and with each salvo already fired at it, to a floor.
	var b0 := Guns.sigma_m(2000.0, 0.0, spec, 0)
	var b1 := Guns.sigma_m(2000.0, 0.0, spec, 1)
	var b2 := Guns.sigma_m(2000.0, 0.0, spec, 2)
	var b9 := Guns.sigma_m(2000.0, 0.0, spec, 9)
	check(b0 > b1 and b1 > b2, "each salvo at the same target tightens the next (bracketing): %.1f, %.1f, %.1f m" % [b0, b1, b2])
	near(b9 / b0, spec.bracket_floor, 1e-9, "to the floor")
	near(b1 / b0, spec.bracket_factor, 1e-9, "by the factor")
	# The dice follow the sigma: the measured scatter of the shells is the model's.
	var m_far := _rms(3000.0, 0.0, 0)
	var m_near := _rms(600.0, 0.0, 0)
	var m_ranged := _rms(3000.0, spec.ranging_s, 0)
	var m_bracketed := _rms(3000.0, spec.ranging_s, 2)
	near(m_far, Guns.sigma_m(3000.0, 0.0, spec), 0.2 * Guns.sigma_m(3000.0, 0.0, spec), "the shells fall with the sigma at the edge: %.1f m" % m_far)
	print("  measured rms: edge %.1f, 600 m %.1f, edge ranged %.1f, edge ranged+bracketed(2) %.1f" % [m_far, m_near, m_ranged, m_bracketed])
	check(m_far > 2.0 * m_near, "measured, the edge scatters over twice the near range: %.1f against %.1f m" % [m_far, m_near])
	check(m_ranged < 0.55 * m_far, "measured, ranging in tightens it: %.1f against %.1f m" % [m_ranged, m_far])
	check(m_bracketed < 0.7 * m_ranged, "measured, bracketing tightens it further: %.1f against %.1f m" % [m_bracketed, m_ranged])
	# ... and with how close the nearest spotter is, from 1 at the target to spotter_far_factor at the edge of its sight.
	var c0 := Guns.sigma_m(2000.0, 0.0, spec, 0, 0.0)
	var c1 := Guns.sigma_m(2000.0, 0.0, spec, 0, 1.0)
	near(c1 / c0, spec.spotter_far_factor, 1e-9, "a spotter at the edge of its sight: the far factor")
	check(Guns.sigma_m(2000.0, 0.0, spec, 0, 0.5) > c0 and Guns.sigma_m(2000.0, 0.0, spec, 0, 0.5) < c1, "and between, in between")
	# A salvo is correlated: this share of one shell's error is the whole salvo's.
	var spread_within := 0.0
	var spread_between := 0.0
	var aim := Vector2(2000.0, 2500.0)
	for s in range(1, 41):
		var shells := Guns.make_salvo({"unit": "cruiser", "special": "main_guns", "step": 0, "t": 1.0, "from": aim - Vector2(2000.0, 0.0), "aim": aim,
			"range_m": 2000.0, "flight_s": 8.0, "sigma_m": 40.0}, spec, s, 1, 0)
		var mean := Vector2.ZERO
		for sh: Dictionary in shells:
			mean += Vector2(float(sh["x"]), float(sh["y"]))
		mean /= float(shells.size())
		spread_between += (mean - aim).length_squared()
		for sh: Dictionary in shells:
			spread_within += (Vector2(float(sh["x"]), float(sh["y"])) - mean).length_squared()
	spread_between = sqrt(spread_between / 40.0 / 2.0)
	spread_within = sqrt(spread_within / 40.0 / float(spec.shells - 1) / 2.0)
	check(spread_between > 0.3 * 40.0, "a salvo falls long or short, left or right as a whole: its centre is %.1f m off (the salvo error is %.0f%% of 40 m)" % [spread_between, spec.salvo_error_fraction * 100.0])
	check(spread_within < 40.0, "...and the shells differ among themselves less than a single shell's scatter: %.1f m" % spread_within)
	# The same game rolls the same salvo; another seed rolls another.
	var shot := {"unit": "cruiser", "special": "main_guns", "step": 0, "t": 1.0, "from": Vector2(0.0, 0.0), "aim": Vector2(1500.0, 0.0), "range_m": 1500.0, "flight_s": 6.0, "sigma_m": 30.0}
	var a := Guns.make_salvo(shot, spec, 5, 3, 0)
	var b := Guns.make_salvo(shot, spec, 5, 3, 0)
	var c := Guns.make_salvo(shot, spec, 6, 3, 0)
	check(_same(a, b), "the same game, turn and unit roll the same salvo")
	check(not _same(a, c), "another seed rolls another")
	# The reload and the range are data, with their reasons.
	check(spec.reload_turns >= 1, "a long reload, in turns: %d" % spec.reload_turns)
	_sentinel += 1

# --- Bracketing across turns --------------------------------------------------------------------------------------------------------

func _bracketing() -> void:
	var w := GunWorlds.world(11)
	w.units["aa"].health = 999   # (it is shot at for many turns and must stay a target)
	var spec := _spec()
	var spreads: Array[float] = []
	var before: Array[int] = []
	var spotted_s: Array[float] = []
	var ready := 1
	for salvo in 3:
		while w.turn < ready:
			GunWorlds.next_turn(w)
		var st := GunWorlds.fire(w, "aa")
		check(not st.is_empty() and st["fire"]["ok"] == true, "turn %d: planned: %s / %s" % [w.turn, w.last_error, str(st.get("fire", {}))])
		var res := GunWorlds.next_turn(w)
		var fe: Array = GunWorlds.events_of(res, "shell_fire", "cruiser")
		if not check(fe.size() == 1, "turn %d: a salvo fired" % (w.turn - 1)):
			return
		spreads.append(float(fe[0]["spread_m"]))
		before.append(int(fe[0]["salvos_before"]))
		spotted_s.append(float(fe[0]["spotted_s"]))
		ready = int(w.units["cruiser"].gun_ready["main_guns"])
	print("  bracketing: spread %s, spotted_s %s, salvos before %s" % [str(spreads), str(spotted_s), str(before)])
	eq(before, [0, 1, 2] as Array[int], "successive salvos at the same spotted target count: 0, 1, 2 before them")
	check(spreads[0] > spreads[1] and spreads[1] > spreads[2], "and tighten: %.1f, %.1f, %.1f m (same range)" % [spreads[0], spreads[1], spreads[2]])
	check(spotted_s[1] > spotted_s[0] + 10.0, "the target has been spotted longer each time: %.1f, %.1f, %.1f s" % [spotted_s[0], spotted_s[1], spotted_s[2]])
	eq(w.gun_memory.size(), 1, "the bracketing is remembered, one entry for the target")
	# A break in sight starts it all again: the spotter is out of sight of the target for a turn.
	while w.turn < int(w.units["cruiser"].gun_ready["main_guns"]) - 1:
		GunWorlds.next_turn(w)
	var home := Vector2(w.units["spotter"].x, w.units["spotter"].y)
	w.units["spotter"].x = 4500.0
	GunWorlds.next_turn(w)
	w.units["spotter"].x = home.x
	eq(w.gun_memory.size(), 0, "a turn out of sight and the bracketing is forgotten")
	check(not (w.spot_memory.get("allies", {}) as Dictionary).has("aa") or float(w.spot_memory["allies"]["aa"]) < 1.0, "...and so is the ranging")
	GunWorlds.fire(w, "aa")
	var res4 := GunWorlds.next_turn(w)
	var f4: Array = GunWorlds.events_of(res4, "shell_fire", "cruiser")
	if check(f4.size() == 1, "and the guns fire again when it is back in sight"):
		eq(int(f4[0]["salvos_before"]), 0, "as a new target")
		check(float(f4[0]["spread_m"]) > spreads[1], "with a wide scatter again: %.1f m" % float(f4[0]["spread_m"]))
	# Not fired at for bracket_turns turns: a new target again.
	var mem := Guns.bracket_after([], "allies", {"unit": "aa"}, Vector2.ZERO, 3, spec)
	eq(Guns.bracket_salvos(mem, "allies", {"unit": "aa"}, 3 + spec.bracket_turns, spec), 1, "remembered for %d turns" % spec.bracket_turns)
	eq(Guns.bracket_salvos(mem, "allies", {"unit": "aa"}, 3 + spec.bracket_turns + 1, spec), 0, "then a new target")
	eq(Guns.bracket_salvos(mem, "axis", {"unit": "aa"}, 3, spec), 0, "another side starts from nothing")
	# A point target is 'the same' within a radius.
	var pm := Guns.bracket_after([], "allies", {"point": [1000.0, 1000.0]}, Vector2(1000.0, 1000.0), 3, spec)
	eq(Guns.bracket_salvos(pm, "allies", {"point": [1000.0 + spec.bracket_point_m * 0.9, 1000.0]}, 3, spec), 1, "a point within %.0f m of the last aim is the same target" % spec.bracket_point_m)
	eq(Guns.bracket_salvos(pm, "allies", {"point": [1000.0 + spec.bracket_point_m * 1.5, 1000.0]}, 3, spec), 0, "one farther is a new one")
	_sentinel += 1

# --- Held at resolve (the switch on "hold", and what is held in any mode) -------------------------------------------------------------

# The World's guns with gun_unspotted_mode set to `mode` (data/sim/guns.json). The resolver holds the same GunRules object.
func _guns_mode(w: World, mode: String) -> void:
	w.guns.unspotted_mode = mode

func _hold() -> void:
	# gun_unspotted_mode "hold": the strict answer, how the guns were first built. Planned while spotted; the spotter is gone by the time
	# the guns fire.
	var w := GunWorlds.world(3)
	_guns_mode(w, "hold")
	GunWorlds.fire(w, "aa")
	w.units["spotter"].x = 4500.0
	var res := GunWorlds.turn(w)
	var holds := GunWorlds.events_of(res, "gun_hold", "cruiser")
	eq(holds.size(), 1, "hold: a target no longer spotted at the moment of fire is not fired at")
	if holds.size() == 1:
		eq(str(holds[0]["reason"]), "unspotted", "...and the event says why")
		eq(holds[0]["target"], {"unit": "aa"}, "...and at what")
	eq(GunWorlds.events_of(res, "shell_fire").size(), 0, "no salvo")
	eq(w.shells_in_flight.size(), 0, "no shell in the air")
	eq(w.units["cruiser"].gun_ready_turn("main_guns"), 0, "NOTHING IS SPENT: the guns are still loaded")
	# Planned in range; by the moment of fire the target is out of reach.
	var w2 := GunWorlds.world(3)
	_guns_mode(w2, "hold")
	GunWorlds.fire(w2, "aa")
	w2.units["aa"].x = 4800.0
	var r2 := GunWorlds.turn(w2)
	var h2 := GunWorlds.events_of(r2, "gun_hold", "cruiser")
	eq(h2.size(), 1, "hold: a target out of reach at the moment of fire is held")
	if h2.size() == 1:
		eq(str(h2[0]["reason"]), "out_of_range", "...out of range")
	eq(w2.units["cruiser"].gun_ready_turn("main_guns"), 0, "...and nothing is spent")
	# A target that has been destroyed by then: held in EVERY mode (there is nothing to aim at).
	for mode: String in ["hold", "poor_shot"]:
		var w3 := GunWorlds.world(3)
		_guns_mode(w3, mode)
		GunWorlds.fire(w3, "aa")
		w3.units["aa"].health = 0
		w3.units["aa"].down = true
		w3.units["aa"].fate = "destroyed"
		var r3 := GunWorlds.turn(w3)
		var h3 := GunWorlds.events_of(r3, "gun_hold", "cruiser")
		check(h3.size() == 1 and str(h3[0]["reason"]) == "target_down", "%s: a target already down: held (target_down)" % mode)
		eq(GunWorlds.events_of(r3, "shell_fire").size(), 0, "%s: ... and no salvo" % mode)
		eq(w3.units["cruiser"].gun_ready_turn("main_guns"), 0, "%s: ... and nothing spent" % mode)
	_sentinel += 1

# --- The poor shot ------------------------------------------------------------------------------------------------------------------------
#
# ALEX (decision outside-cone-release, 2026-10-11): "Fire a poorer one. Maybe in the future we have an engagement mode but for now that is
# extra complexity we are not ready for." A salvo whose target is no longer spotted, or out of reach, when it fires goes anyway, the
# reload spent, at where the target was last spotted, the scatter widened (data/sim/guns.json gun_unspotted_mode, poor_shot_factor).

# The mean distance from `aim` of the shells a salvo has in the air at the end of the turn, over many seeds of the same set-up.
func _mean_miss(poor: bool, aim: Vector2, seeds: int = 10) -> float:
	var total := 0.0
	var n := 0
	for sd in range(1, seeds + 1):
		var w := GunWorlds.world(sd)
		GunWorlds.fire(w, "aa")
		if poor:
			w.units["spotter"].x = 4500.0
		GunWorlds.turn(w)
		for sh: Dictionary in w.shells_in_flight:
			total += Vector2(float(sh["x"]), float(sh["y"])).distance_to(aim)
			n += 1
	return total / float(maxi(n, 1))

func _poor_shot() -> void:
	var spec := _spec()
	var rules := GunRules.new()
	eq(rules.unspotted_mode, "poor_shot", "0. the default is a poor shot (Alex, outside-cone-release: 'Fire a poorer one')")
	eq(JSON.parse_string(FileAccess.get_file_as_string(GunRules.PATH))["gun_unspotted_mode"].get("decision", ""), "outside-cone-release", "0. and the record cites the decision")
	check(spec.poor_shot_factor > 1.0 and spec.poor_shot_min_sigma_m > 0.0, "0. the poor shot's numbers are data: x%.1f, least %.0f m" % [spec.poor_shot_factor, spec.poor_shot_min_sigma_m])
	check(Guns.poor_shot_reason("unspotted") and Guns.poor_shot_reason("out_of_range") and Guns.poor_shot_reason("too_close") and Guns.poor_shot_reason("inland"), "0. unspotted and out of reach are poor shots")
	check(not Guns.poor_shot_reason("reloading") and not Guns.poor_shot_reason("target_down") and not Guns.poor_shot_reason("own_side") and not Guns.poor_shot_reason("no_target"), "0. a reload, a dead target, a friend and no target are not")
	# The scatter is the unranged, unbracketed one with the spotter at the edge of its sight, times the factor, never under the floor.
	near(Guns.poor_sigma_m(1200.0, 0.0, spec), maxf(Guns.sigma_m(1200.0, 0.0, spec, 0, 1.0) * spec.poor_shot_factor, spec.poor_shot_min_sigma_m), 1e-9, "0. poor_sigma_m")
	check(Guns.poor_sigma_m(100.0, 0.0, spec) >= spec.poor_shot_min_sigma_m, "0. a short poor shot is not tighter than the floor: %.1f m" % Guns.poor_sigma_m(100.0, 0.0, spec))
	check(Guns.poor_sigma_m(1200.0, 20.0, spec, 2, 0.0) > Guns.sigma_m(1200.0, 20.0, spec, 2, 0.0) * 1.5, "0. and far wider than a ranged-in shot")

	# 1. NOT SPOTTED at the moment of fire (planned while spotted; the spotter is gone). Nothing in sight this turn and no aim stored with
	# the fire: the place the target stood at the start of the turn.
	var w := GunWorlds.world(3)
	check(not GunWorlds.fire(w, "aa").is_empty(), "1. planned while spotted")
	w.units["spotter"].x = 4500.0
	var res := GunWorlds.turn(w)
	eq(GunWorlds.events_of(res, "gun_hold", "cruiser").size(), 0, "1. NOT held")
	var fe := GunWorlds.events_of(res, "shell_fire", "cruiser")
	if not check(fe.size() == 1, "1. the salvo is fired"):
		return
	check(bool(fe[0].get("poor_shot", false)), "1. and the event says it is a poor shot")
	eq(str(fe[0].get("poor_why", "")), "unspotted", "1. ... because the target was not spotted")
	eq(bool(fe[0]["followed"]), false, "1. a poor shot does not follow the unit (it has nothing to follow)")
	eq(int(fe[0]["shells"]), spec.shells, "1. all %d shells" % spec.shells)
	eq(w.shells_in_flight.size(), spec.shells, "1. in the air")
	near(float(fe[0]["aim"][0]), GunWorlds.TARGET.x, 1e-6, "1. aimed at where the battery stood (x)")
	near(float(fe[0]["aim"][1]), GunWorlds.TARGET.y, 1e-6, "1. ... (y)")
	eq(bool(fe[0].get("clamped", true)), false, "1. (in reach: not pulled back)")
	near(float(fe[0]["spread_m"]), Guns.poor_sigma_m(float(fe[0]["range_m"]), 0.0, spec, 0, 1.0), 1e-6, "1. the scatter is the poor one: %.1f m" % float(fe[0]["spread_m"]))
	eq(int(w.units["cruiser"].gun_ready["main_guns"]), 1 + spec.reload_turns + 1, "1. THE RELOAD IS SPENT: the guns are reloading until turn %d" % (1 + spec.reload_turns + 1))
	eq(w.gun_memory.size(), 0, "1. and a poor shot is not a bracketing salvo")
	# The same salvo with the target in sight, for the comparison.
	var wn := GunWorlds.world(3)
	GunWorlds.fire(wn, "aa")
	var fn := GunWorlds.events_of(GunWorlds.turn(wn), "shell_fire", "cruiser")
	if check(fn.size() == 1, "1. (the salvo with the target in sight fires too)"):
		check(not fn[0].has("poor_shot"), "1. which is not a poor shot")
		check(float(fe[0]["spread_m"]) >= 2.0 * float(fn[0]["spread_m"]), "1. the poor shot's scatter is at least twice the good one's: %.1f against %.1f m" % [float(fe[0]["spread_m"]), float(fn[0]["spread_m"])])
	var miss_poor := _mean_miss(true, GunWorlds.TARGET)
	var miss_good := _mean_miss(false, GunWorlds.TARGET)
	print("  poor shot: the shells land %.0f m from the battery on average, against %.0f m with it in sight" % [miss_poor, miss_good])
	check(miss_poor > 1.8 * miss_good, "1. the shells LAND wider: %.0f m against %.0f m (10 seeds)" % [miss_poor, miss_good])
	# Next turn the shells land (the poor shot is a real salvo), identically on a client.
	var client := GunWorlds.world(3)
	client.units["spotter"].x = 4500.0
	check(client.apply_resolution(res), "1. the client applies the host's result: %s" % client.last_error)
	check(_same(client.shells_in_flight, w.shells_in_flight), "1. and has the same shells in the air")
	check(int(client.units["cruiser"].gun_ready["main_guns"]) == int(w.units["cruiser"].gun_ready["main_guns"]), "1. and the same reload")
	w.begin_turn()
	var res2 := GunWorlds.turn(w)
	eq(GunWorlds.events_of(res2, "shell_impact", "cruiser").size(), spec.shells, "1. the shells land in the next turn")

	# 2. LAST SPOTTED. An enemy plane flies out of the tower's sight just before the guns fire: they aim where it was at the last moment
	# it was seen, not where it is, not where it will be.
	var w2 := GunWorlds.world(11)
	w2.units["spotter"].x = 4500.0
	w2.add_unit({"id": "spot2", "type": "radio_tower", "side": "allies", "controller": "player", "x": 1700.0, "y": 2500.0, "heading": 0.0})
	check(w2.add_unit({"id": "runner", "type": "light_fighter", "side": "axis", "controller": "player", "x": 2150.0, "y": 2500.0, "heading": 0.0,
			"altitude_band": "medium", "speed": 45.0}) != "", "2. an enemy plane near the tower: %s" % w2.last_error)
	for k in w2.steps_per_turn("runner"):
		w2.plan_step("runner", k, {"turn": 0.0, "speed": 45.0})
	check(w2.spotted_now("allies", {"unit": "runner"}), "2. the tower sees it at the start of the turn")
	var st2 := GunWorlds.fire(w2, "runner")
	check(not st2.is_empty() and st2["fire"]["ok"] == true, "2. the salvo is planned: %s" % str(st2.get("fire", w2.last_error)))
	var r2 := GunWorlds.turn(w2)
	var f2 := GunWorlds.events_of(r2, "shell_fire", "cruiser")
	if check(f2.size() == 1, "2. fired"):
		check(bool(f2[0].get("poor_shot", false)) and str(f2[0].get("poor_why", "")) == "unspotted", "2. as a poor shot, the plane having left the tower's sight")
		var seen: Dictionary = w2.sample("runner", 1.0, "history")
		var at_fire: Dictionary = w2.sample("runner", float(f2[0]["t"]), "history")
		check(Vector2(float(seen["x"]), float(seen["y"])).distance_to(Vector2(float(at_fire["x"]), float(at_fire["y"]))) > 5.0, "2. (it moved %.1f m between the last sighting and the shot)" % Vector2(float(seen["x"]), float(seen["y"])).distance_to(Vector2(float(at_fire["x"]), float(at_fire["y"]))))
		near(float(f2[0]["known"][0]), float(seen["x"]), 0.01, "2. the guns take it to be where it was LAST SEEN (x)")
		near(float(f2[0]["known"][1]), float(seen["y"]), 0.01, "2. ... (y)")
		near(float(f2[0]["aim"][0]), float(seen["x"]), 0.01, "2. and aim there, no lead: the aim is the last seen place")

	# 3. SHOWN: the fire carries the aim the target was shown at when it was set; with the target never in sight this turn, that is the place.
	var w3 := GunWorlds.world(3)
	w3.plan_step("cruiser", 0, {"fire": {"special": "main_guns", "target": {"unit": "aa"}, "aim": [1750.0, 2510.0]}})
	w3.units["spotter"].x = 4500.0
	var f3 := GunWorlds.events_of(GunWorlds.turn(w3), "shell_fire", "cruiser")
	if check(f3.size() == 1, "3. fired"):
		near(float(f3[0]["aim"][0]), 1750.0, 1e-6, "3. aimed at the place the target was SHOWN at when the fire was set (x)")
		near(float(f3[0]["aim"][1]), 2510.0, 1e-6, "3. ... (y)")

	# 4. OUT OF RANGE at the moment of fire: pulled back along the line to the edge of the reach (and the coastal strip, which is nearer).
	var w4 := GunWorlds.world(3)
	GunWorlds.fire(w4, "aa")
	w4.units["aa"].x = 4800.0
	var f4 := GunWorlds.events_of(GunWorlds.turn(w4), "shell_fire", "cruiser")
	if check(f4.size() == 1, "4. a target out of reach is fired at"):
		eq(str(f4[0].get("poor_why", "")), "out_of_range", "4. ... a poor shot, out of range")
		check(bool(f4[0].get("clamped", false)), "4. pulled back to the edge of the reach")
		check(float(f4[0]["range_m"]) <= spec.range_max_m and float(f4[0]["range_m"]) >= spec.range_min_m, "4. inside the guns' reach: %.0f m" % float(f4[0]["range_m"]))
		var ax: float = float(f4[0]["aim"][0])
		check(ax > GunWorlds.COAST_X and ax <= GunWorlds.COAST_X + spec.inland_max_m + 1e-6, "4. and on the coastal strip, the shore at x %.0f and the aim at %.0f" % [GunWorlds.COAST_X, ax])
		near(float(f4[0]["aim"][1]), 2500.0, 1e-6, "4. on the line from the ship to the target")
	eq(w4.units["cruiser"].gun_ready_turn("main_guns"), 1 + spec.reload_turns + 1, "4. the reload is spent")
	# Without water the range alone clamps it.
	var w4b := GunWorlds.world(3, false)
	GunWorlds.fire(w4b, "aa")
	w4b.units["aa"].x = 4800.0
	var f4b := GunWorlds.events_of(GunWorlds.turn(w4b), "shell_fire", "cruiser")
	if check(f4b.size() == 1, "4. (with no water in the world either)"):
		near(float(f4b[0]["range_m"]), spec.range_max_m, 0.01, "4. the aim is the guns' longest range, %.0f m" % float(f4b[0]["range_m"]))
		near(float(f4b[0]["aim"][0]), GunWorlds.SHIP.x + spec.range_max_m, 0.01, "4. along the line to the target")

	# 5. TOO CLOSE (a point alongside the ship) and INLAND (a point behind the strip).
	var w5 := GunWorlds.world(3)
	var st5 := GunWorlds.fire(w5, Vector2(700.0, 2500.0))
	check(not st5.is_empty() and st5["fire"]["ok"] == false and st5["fire"]["reason"] == "too_close" and bool(st5["fire"]["poor_shot"]), "5. a point alongside: the step says too_close, and that it is a poor shot")
	var f5 := GunWorlds.events_of(GunWorlds.turn(w5), "shell_fire", "cruiser")
	if check(f5.size() == 1, "5. fired"):
		eq(str(f5[0].get("poor_why", "")), "too_close", "5. a poor shot, too close")
		near(float(f5[0]["range_m"]), spec.range_min_m, 0.01, "5. pushed out to the guns' shortest range: %.1f m" % float(f5[0]["range_m"]))
	var w6 := GunWorlds.world(3)
	var st6 := GunWorlds.fire(w6, Vector2(2500.0, 2500.0))
	check(not st6.is_empty() and st6["fire"]["reason"] == "inland" and bool(st6["fire"]["poor_shot"]), "6. a point 800 m inland: the step says inland, and that it is a poor shot (%s)" % str(st6.get("fire", w6.last_error)))
	var f6 := GunWorlds.events_of(GunWorlds.turn(w6), "shell_fire", "cruiser")
	if check(f6.size() == 1, "6. fired"):
		eq(str(f6[0].get("poor_why", "")), "inland", "6. a poor shot, inland")
		check(bool(f6[0].get("clamped", false)) and float(f6[0]["aim"][0]) < GunWorlds.COAST_X + spec.inland_max_m + 1e-6, "6. pulled back onto the coastal strip: x %.0f" % float(f6[0]["aim"][0]))
	# The planning rule stands: the special still cannot be switched on for a target nobody sees, and the answer says it would be a poor shot.
	var c7 := GunWorlds.world(3).gun_check("cruiser", 0, {"point": [1800.0, 3500.0]})
	check(c7["ok"] == false and c7["reason"] == "unspotted" and bool(c7["poor_shot"]), "7. a point in the fog: cannot be activated (unspotted), and it would be a poor shot")
	check(float(c7["spread_m"]) >= spec.poor_shot_min_sigma_m, "7. the scatter it shows is the poor one: %.1f m" % float(c7["spread_m"]))
	var c8 := GunWorlds.world(3).gun_check("cruiser", 0, {"unit": "aa"})
	check(c8["ok"] == true and not bool(c8["poor_shot"]), "7. a spotted target in reach is not")
	var wh := GunWorlds.world(3)
	_guns_mode(wh, "hold")
	check(not bool(wh.gun_check("cruiser", 0, {"point": [1800.0, 3500.0]})["poor_shot"]), "7. with the switch on hold, nothing is a poor shot")
	_sentinel += 1

# --- The reload -------------------------------------------------------------------------------------------------------------------------------

func _reload() -> void:
	var spec := _spec()
	var w := GunWorlds.world(5)
	eq(w.gun_reload_left("cruiser", "main_guns"), 0, "loaded to begin with")
	eq(str(w.gun_check("cruiser", 0, {"unit": "aa"})["reason"]), "", "and it can fire")
	GunWorlds.fire(w, "aa")
	var res := GunWorlds.next_turn(w)
	eq(GunWorlds.events_of(res, "shell_fire", "cruiser").size(), 1, "fired in turn 1")
	var fired_turn := 1
	for n in range(1, spec.reload_turns + 1):
		eq(w.turn, fired_turn + n, "turn %d" % w.turn)
		var chk := w.gun_check("cruiser", 0, {"unit": "aa"})
		eq(str(chk["reason"]), "reloading", "turn %d: reloading" % w.turn)
		eq(int(chk["reload_left"]), spec.reload_turns + 1 - n, "...%d turns to go" % int(chk["reload_left"]))
		eq(w.gun_reload_left("cruiser", "main_guns"), spec.reload_turns + 1 - n, "(the World says the same)")
		# plan_step accepts the request all the same (a plan is replayed on the other peers); the step says it will not fire.
		var st := GunWorlds.fire(w, "aa")
		check(not st.is_empty() and st["fire"]["ok"] == false and st["fire"]["reason"] == "reloading", "turn %d: a planned fire says it will not fire" % w.turn)
		var r := GunWorlds.next_turn(w)
		var holds := GunWorlds.events_of(r, "gun_hold", "cruiser")
		check(holds.size() == 1 and holds[0]["reason"] == "reloading", "turn %d: the guns are held, reloading" % (w.turn - 1))
		eq(GunWorlds.events_of(r, "shell_fire", "cruiser").size(), 0, "...and no salvo goes")
		eq(w.units["cruiser"].gun_ready_turn("main_guns"), fired_turn + spec.reload_turns + 1, "(the reload does not move)")
	eq(w.turn, fired_turn + spec.reload_turns + 1, "turn %d" % w.turn)
	eq(str(w.gun_check("cruiser", 0, {"unit": "aa"})["reason"]), "", "loaded again, a salvo every %d turns" % (spec.reload_turns + 1))
	GunWorlds.fire(w, "aa")
	var r2 := GunWorlds.next_turn(w)
	eq(GunWorlds.events_of(r2, "shell_fire", "cruiser").size(), 1, "and it fires")
	# The reload crosses the wire with the unit.
	var u: Unit = w.units["cruiser"]
	check(u.net_state().has("gun_ready") and int(u.net_state()["gun_ready"]["main_guns"]) == u.gun_ready["main_guns"], "gun_ready travels in the unit's net state")
	var other := Unit.new()
	other.apply_state({"x": 0.0, "y": 0.0, "heading": 0.0, "speed": 0.0, "altitude_band": "surface"})
	other.apply_net_state(u.net_state())
	eq(other.gun_ready_turn("main_guns"), u.gun_ready_turn("main_guns"), "a client unit takes it from the host's")
	_sentinel += 1

# --- Across a turn end, and across the wire ----------------------------------------------------------------------------------------------

func _carried() -> void:
	var host := GunWorlds.world(9)
	var client := GunWorlds.world(9)
	host.spot_memory = {"allies": {"aa": 20.0}}
	client.spot_memory = {"allies": {"aa": 20.0}}
	var spec := _spec()
	GunWorlds.fire(host, "aa")
	# Turn 1: the salvo is fired; the shells are in the air at the turn's end.
	var res1 := GunWorlds.turn(host)
	if not check(not res1.is_empty(), "turn 1 resolves: %s" % host.last_error):
		return
	check(res1.has("shells") and res1.has("spot_memory") and res1.has("gun_memory"), "the result carries the shells, the spotting and the bracketing")
	check(client.apply_resolution(res1), "the client applies it: %s" % client.last_error)
	eq(host.shells_in_flight.size(), spec.shells, "after the firing turn the whole salvo is in the air")
	check(_same(client.shells_in_flight, host.shells_in_flight), "the client's shells in the air are the host's")
	check(_same(client.spot_memory, host.spot_memory) and _same(client.gun_memory, host.gun_memory), "and what the sides remember")
	for id: String in host.units:
		check(_same((client.units[id] as Unit).net_state(), (host.units[id] as Unit).net_state()), "%s agrees on host and client" % id)
	# A twin World given only what the wire carries lands the shells exactly as the host does.
	var twin := GunWorlds.world(9)
	twin.turn = host.turn + 1
	for id: String in host.units:
		twin.units[id].apply_net_state((host.units[id] as Unit).net_state())
	twin.apply_net_guns(host.net_guns())
	host.begin_turn()
	client.begin_turn()
	# Turn 2: the shells land.
	var res2 := GunWorlds.turn(host)
	var twin2 := GunWorlds.turn(twin)
	check(not res2.is_empty() and not twin2.is_empty(), "turn 2 resolves on both: %s / %s" % [host.last_error, twin.last_error])
	var landed := GunWorlds.events_of(res2, "shell_impact").size()
	eq(landed, spec.shells, "every shell lands in the second turn")
	check(_same(res2["events"], twin2["events"]), "a joiner handed the shells lands them identically: %d events" % (res2["events"] as Array).size())
	check(_same(res2["shells"], twin2["shells"]) and host.units["aa"].health == twin.units["aa"].health, "(the same damage: %d pips left)" % host.units["aa"].health)
	check(client.apply_resolution(res2), "the client applies it: %s" % client.last_error)
	check(_same(client.shells_in_flight, host.shells_in_flight), "the client has none in the air either")
	eq(client.units["aa"].health, host.units["aa"].health, "the battery is as hurt on the client (%d pips)" % client.units["aa"].health)
	for id: String in host.units:
		check(_same((client.units[id] as Unit).net_state(), (host.units[id] as Unit).net_state()), "turn 2: %s agrees on host and client" % id)
	eq(host.shells_in_flight.size(), 0, "nothing is left in the air")
	# A longer flight crosses TWO turn ends: 2,200 m, nine seconds in the air, fired at 1.25 s of turn 1, landing at 0.05 s of turn 3.
	var far_host := GunWorlds.world(9)
	var far_client := GunWorlds.world(9)
	for w: World in [far_host, far_client]:
		w.units["cruiser"].x = 50.0
		w.add_unit({"id": "aa_far", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2250.0, "y": 2500.0, "heading": 0.0})
		w.add_unit({"id": "spot2", "type": "radio_tower", "side": "allies", "controller": "player", "x": 2300.0, "y": 2500.0, "heading": 0.0})
	var st := GunWorlds.fire(far_host, "aa_far")
	check(not st.is_empty() and st["fire"]["ok"] == true, "a 2,200 m shot at the edge of the coastal strip: %s" % str(st.get("fire", far_host.last_error)))
	var landed_turns := {}
	for turn_no in 3:
		var r := GunWorlds.turn(far_host)
		check(not r.is_empty() and far_client.apply_resolution(r), "far turn %d resolves and applies: %s %s" % [far_host.turn, far_host.last_error, far_client.last_error])
		check(_same(far_client.shells_in_flight, far_host.shells_in_flight), "far turn %d: the client's shells in the air are the host's (%d)" % [far_host.turn, far_host.shells_in_flight.size()])
		for ev: Dictionary in GunWorlds.events_of(r, "shell_impact"):
			landed_turns[int(ev["turn"])] = int(landed_turns.get(int(ev["turn"]), 0)) + 1
		if turn_no < 2:
			eq(far_host.shells_in_flight.size(), spec.shells, "far turn %d: all still in the air" % far_host.turn)
		far_host.begin_turn()
		far_client.begin_turn()
	eq(landed_turns, {3: spec.shells}, "they land in turn 3, two turn ends after the salvo")
	eq(far_client.units["aa_far"].health, far_host.units["aa_far"].health, "and hurt the same on the client")
	# A snapshot copies: editing it does not touch the host.
	var snap := host.net_guns()
	snap["shells"] = [{"x": 1.0}]
	eq(host.shells_in_flight.size(), 0, "(a copy)")
	_sentinel += 1

# --- The blast hurts a friend ---------------------------------------------------------------------------------------------------------------

func _friendly_fire() -> void:
	var w := GunWorlds.world(13)
	w.spot_memory = {"allies": {"aa": 20.0}}
	w.gun_memory = [{"side": "allies", "unit": "aa", "point": [], "salvos": 3, "turn": 0}]
	w.add_unit({"id": "buddy", "type": "radio_tower", "side": "allies", "controller": "player", "x": GunWorlds.TARGET.x + 5.0, "y": GunWorlds.TARGET.y, "heading": 0.0})
	var bystander_health: int = w.units["spotter"].health
	var buddy_health: int = w.units["buddy"].health
	GunWorlds.fire(w, "aa")
	GunWorlds.next_turn(w)
	var res := GunWorlds.next_turn(w)
	var friendly_hits := 0
	for ev: Dictionary in GunWorlds.events_of(res, "hit", "buddy"):
		eq(str(ev["by"]), "cruiser", "the cruiser's shells")
		eq(str(ev["weapon"]), "main_guns", "the main guns")
		friendly_hits += 1
	print("  friendly fire: %d hits on the buddy 5 m from the target, %d of %d pips left" % [friendly_hits, w.units["buddy"].health, buddy_health])
	check(friendly_hits > 0, "the blast hurts a friendly unit 5 m from the target: %d hits" % friendly_hits)
	check(w.units["buddy"].health < buddy_health, "it lost pips: %d of %d" % [w.units["buddy"].health, buddy_health])
	eq(w.units["spotter"].health, bystander_health, "and one 200 m away is untouched")
	check(w.guns.special("main_guns").blast_hits_own_side, "the data says a shell does not know whose side a unit is on")
	# A blast table with a flat zero outside its last tier.
	var spec := _spec()
	eq(spec.blast_damage(spec.blast_radius_m() + 1.0), 0, "nothing past the last tier")
	check(spec.blast_damage(1.0) >= spec.blast_damage(spec.blast_radius_m()), "more pips closer in")
	_sentinel += 1

# --- The blast, and what it does to a bridge -------------------------------------------------------------------------------------

func _blast_and_bridge() -> void:
	var spec := _spec()
	# ALEX (decision shell-blast, 2026-10-11): "for the smaller ship lets do high damage smaller range." Small radii, big pips (4 / 3 / 2
	# at 6 / 12 / 20 m; the pips are proposed, data/sim/guns.json).
	eq(Array(spec.blast_distances), [6.0, 12.0, 20.0], "the radii stay small: 6, 12 and 20 m (not the bombs' 12, 25 and 45)")
	eq(Array(spec.blast_pips), [4.0, 3.0, 2.0], "...and the damage is high: 4, 3 and 2 pips")
	eq([spec.blast_damage(0.0), spec.blast_damage(6.0), spec.blast_damage(6.5), spec.blast_damage(12.0), spec.blast_damage(19.9), spec.blast_damage(20.5)], [4, 4, 3, 3, 2, 0], "a hit near the target is decisive: 4 pips within 6 m, 3 within 12, 2 within 20, nothing beyond")
	check(spec.blast_damage(1.0) >= w_battery_health(), "one shell on a battery takes all of it (%d pips of %d)" % [spec.blast_damage(1.0), w_battery_health()])
	# The bridge (data/units/bridge.json): a FRESH direct salvo (nothing ranged, nothing bracketed) cannot one-shot it, at any range;
	# one ranged in for the full ranging time can, and one with salvos already on the target all but surely does. (Alex, bridge-durability:
	# "it should take a lot." scripts/test_support/bridge_tuning.gd prints the whole table.)
	var w := GunWorlds.world(1)
	var health: int = w.unit_def("bridge").health
	var aim := Vector2(2000.0, 2500.0)
	var most := {}
	for cfg: Array in [[1200.0, 0.0, 0], [3000.0, 0.0, 0], [600.0, 0.0, 0], [1200.0, 20.0, 2], [600.0, 20.0, 2]]:
		var sigma := Guns.sigma_m(float(cfg[0]), float(cfg[1]), spec, int(cfg[2]), 0.4)
		var top := 0
		var total := 0
		for sd in range(1, 301):
			var shells := Guns.make_salvo({"unit": "cruiser", "special": "main_guns", "step": 0, "t": 1.0, "from": aim - Vector2(float(cfg[0]), 0.0), "aim": aim,
				"range_m": cfg[0], "flight_s": Guns.flight_time(float(cfg[0]), spec), "sigma_m": sigma}, spec, sd, 1, 0)
			var pips := 0
			for sh: Dictionary in shells:
				pips += spec.blast_damage(Vector2(float(sh["x"]), float(sh["y"])).distance_to(aim))
			top = maxi(top, pips)
			if pips >= health:
				total += 1
		most[str(cfg)] = [top, total]
	print("  bridge %d pips vs one salvo (most pips in 300 salvos, how many drop it): %s" % [health, str(most)])
	for key: String in ["[1200.0, 0.0, 0]", "[3000.0, 0.0, 0]", "[600.0, 0.0, 0]"]:
		check(int(most[key][0]) < health, "a fresh direct salvo %s never drops the bridge: the most it did was %d of %d pips" % [key, int(most[key][0]), health])
	check(int(most["[1200.0, 20.0, 2]"][1]) > 150, "but guns that have found the range do it in a salvo or two: %d of 300 at 1200 m with two salvos already on it" % int(most["[1200.0, 20.0, 2]"][1]))
	check(health > 10, "the bridge takes more than the old 10 pips (%d)" % health)
	_sentinel += 1

func w_battery_health() -> int:
	return GunWorlds.world(1).unit_def("anti_aircraft_battery").health
