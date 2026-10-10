extends "res://scripts/test_support/test_case.gd"

# THE GROUND CHECK (Track S2, the strike, 2026-10-10): the radio tower and the anti-aircraft battery are
# STATIC units. They stand: the World gives them one step a turn that stays put, refuses their plans and
# does not wait for them in the ready-up (the AI included). The battery fires FLAK -- a cone aimed up and all
# around, flexible-gun tracking -- that is strong against the low (120 m) and medium (400 m) bands and weak
# against the high one (1,000 m): a tuning table across the bands is printed, and the pips per pass are
# held to it. A destroyed ground unit is down with the fate "destroyed", stays in World.units and stops firing.
#
# The numbers it holds the flak to are RELATIONS (low and medium at least so many pips a pass, high a
# fraction of them), not the data's exact values, so a retune inside Alex's intent passes and one against it
# does not.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")

func setup(_main) -> void:
	timeout_seconds = 90.0
	_data()
	_standing_still()
	_ready_up()
	_flak_cone()
	var table := _flak_by_band()
	_flak_rolls(table)
	_destroyed_battery_stops()
	_client_matches()
	finish()

# --- The data --------------------------------------------------------------------

func _data() -> void:
	var w := World.new()
	if not check(w.ok(), "the world's data loads: %s" % str(w.errors)):
		return
	var tower := w.unit_def("radio_tower")
	var aa := w.unit_def("anti_aircraft_battery")
	if not check(tower != null and aa != null, "both ground unit files load"):
		return
	for d in [tower, aa]:
		eq(d.mobility, "static", "%s is static" % d.id)
		check(d.is_static(), "%s: is_static()" % d.id)
		eq(d.domain, "ground", "%s is a ground unit" % d.id)
		eq(d.envelope.bands, ["surface"] as Array[String], "%s lives in the surface band" % d.id)
		check(d.envelope.speed_max == 0.0 and d.envelope.speed_cruise == 0.0 and d.envelope.turn_rate(0.0) == 0.0, "%s never moves or turns" % d.id)
		check(d.health >= 1, "%s has health in pips" % d.id)
		check(not d.carries_bombs(), "%s drops nothing" % d.id)
	eq(tower.weapons.size(), 0, "the tower has no weapons")
	eq(aa.weapons.size(), 1, "the battery has one weapon")
	var flak: CombatWeapon = aa.weapons[0]
	eq(flak.id, "flak", "...flak")
	eq(flak.kind, "flexible", "...mounted like a flexible gun")
	eq(flak.half_across_deg, 180.0, "...all around")
	check(flak.elevation_deg > 0.0 and flak.elevation_deg + flak.half_height_deg >= 90.0, "...aimed up, reaching straight overhead (centre %s, half %s)" % [flak.elevation_deg, flak.half_height_deg])
	check(flak.elevation_deg - flak.half_height_deg >= 0.0 and flak.elevation_deg - flak.half_height_deg < 15.0, "...from a low angle above the horizon (%s deg)" % (flak.elevation_deg - flak.half_height_deg))
	var fixed := w.unit_def("light_fighter").weapons[0]
	check(flak.tracking_dps > fixed.tracking_dps, "flak tracks like a gunner, better than a fixed gun (%s against %s deg/s)" % [flak.tracking_dps, fixed.tracking_dps])
	var med := w.band_height("medium")
	var high := w.band_height("high")
	var reach := flak.max_range_m(w.combat.range_overshoot)
	check(w.band_height("low") < flak.effective_range_m and med < flak.effective_range_m, "the low and medium bands are inside the flak's effective range (%s m)" % flak.effective_range_m)
	check(high > flak.effective_range_m and high < reach, "the high band is in the fringe past it, inside the reach (%s < %s < %s m): weak, not nothing" % [flak.effective_range_m, high, reach])
	# A static unit with a moving envelope is refused (the rule is checked in test_unit_defs; here the World).
	check(w.unit_def("bomber") != null and not w.unit_def("bomber").is_static(), "a bomber is not static")

# --- Standing still ------------------------------------------------------------------

func _ground_world() -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 500.0, "y": 500.0, "heading": 0.0})
	w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.7})
	w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2300.0, "y": 2300.0, "heading": -1.2})
	return w

func _standing_still() -> void:
	var w := _ground_world()
	for id in ["tower", "aa"]:
		var u: Variant = w.units[id]
		var x0: float = u.x
		var y0: float = u.y
		var h0: float = u.heading
		w.last_error = ""
		eq(w.plan_step(id, 0, {"turn": 1.0, "speed": 50.0}), {}, "%s: a plan is refused" % id)
		check(w.last_error.contains("static"), "%s: and says why: %s" % [id, w.last_error])
		w.last_error = ""
		eq(w.plan_step(id, 0, Vector2(100.0, 100.0)), {}, "%s: so is a target point" % id)
		w.last_error = ""
		w.clear_plan(id)
		eq(w.last_error, "", "%s: clearing the plan it never had is quiet" % id)
		eq(w.steps_per_turn(id), 1, "%s: one step a turn" % id)
		eq(u.plan.size(), 0, "%s: no plan" % id)
		var planned := w.planned_states(id)
		eq(planned.size(), 1, "%s: the planned turn is one state" % id)
		check(absf(float(planned[0]["x"]) - x0) < 1e-9 and absf(float(planned[0]["y"]) - y0) < 1e-9 and float(planned[0]["speed"]) == 0.0, "%s: which stands still" % id)
		eq(w.reachable(id, 0)["turn_max"], 0.0, "%s: cannot turn" % id)
		eq(u.speed, 0.0, "%s: speed 0" % id)
		eq(u.altitude_band, "surface", "%s: on the surface" % id)
	for k in 3:
		check(not BombWorlds.turn(w).is_empty(), "turn %d resolves: %s" % [k + 1, w.last_error])
		for id in ["tower", "aa"]:
			var u: Variant = w.units[id]
			var hist: Array = u.history
			eq(hist.size(), 2, "%s: the history is the start and the end, nothing more" % id)
			check(float(hist[0]["x"]) == float(hist[1]["x"]) and float(hist[0]["y"]) == float(hist[1]["y"]) and float(hist[0]["heading"]) == float(hist[1]["heading"]), "%s: and they are the same place" % id)
			var mid := w.sample(id, 2.5, "history")
			check(absf(float(mid["x"]) - float(u.x)) < 1e-9 and float(mid["height_m"]) == 0.0, "%s: sampled mid-turn it is where it is, on the ground" % id)
			check(not u.down, "%s: untouched" % id)
		w.begin_turn()
	near(float(w.units["tower"].x), 2500.0, 1e-9, "the tower is where it was put after three turns")
	near(float(w.units["aa"].heading), -1.2, 1e-9, "the battery still faces where it faced")

func _ready_up() -> void:
	# AI statics and nothing else AI: only the players hold the turn up.
	var w := _ground_world()
	eq(w.participants(), ["local"] as Array[String], "statics do not make the AI a participant")
	check(w.commit("local"), "the player alone readies the turn")
	check(not w.resolve().is_empty(), "and it resolves: %s" % w.last_error)
	# The dumb AI skips them and still readies for its mobile units.
	var w2 := _ground_world()
	w2.add_unit({"id": "ai_fighter", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 4000.0, "y": 4000.0, "heading": 3.0})
	eq(w2.participants(), ["local", World.AI_PLAYER] as Array[String], "a mobile AI unit does")
	var dumb := AiDumb.new(w2)
	dumb.attach()
	eq(w2.units["tower"].plan.size(), 0, "the dumb AI did not plan the tower")
	eq(w2.units["aa"].plan.size(), 0, "nor the battery")
	check(w2.units["ai_fighter"].plan.size() > 0, "but it planned its fighter")
	check(w2.is_ready(World.AI_PLAYER), "and readied up")
	w2.last_error = ""
	check(w2.commit("local"), "so the player's ready resolves the turn")
	check(not w2.resolve().is_empty(), "which resolves: %s" % w2.last_error)
	# The dumb AI with statics alone commits nothing and complains of nothing.
	var w3 := _ground_world()
	w3.last_error = ""
	AiDumb.new(w3).attach()
	eq(w3.last_error, "", "the dumb AI with only statics to command is quiet")

# --- The flak cone -----------------------------------------------------------------------

func _flak_cone() -> void:
	var w := World.new()
	var aa := w.unit_def("anti_aircraft_battery")
	var flak: CombatWeapon = aa.weapons[0]
	var factors: Array = w.combat.odds_factors
	var params := w.combat.factor_params()
	var shoot := func(shooter_heading: float, tx: float, ty: float, theight: float, weapon: CombatWeapon = flak) -> Dictionary:
		return Combat.evaluate({"x": 0.0, "y": 0.0, "heading": shooter_heading, "height_m": 0.0}, weapon, 0, {"x": tx, "y": ty, "height_m": theight}, factors, params)
	var low: Dictionary = shoot.call(0.0, 0.0, 1.0, w.band_height("low"))
	var med: Dictionary = shoot.call(0.0, 0.0, 1.0, w.band_height("medium"))
	var high: Dictionary = shoot.call(0.0, 0.0, 1.0, w.band_height("high"))
	check(low["in_cone"] and med["in_cone"], "a plane overhead in the low and the medium band is in the cone")
	check(high["in_cone"] and high["odds"] > 0.0, "one in the high band is in the cone too, in the range fringe")
	check(float(high["odds"]) < 0.6 * float(med["odds"]), "...at well under the medium band's odds (%.4f against %.4f)" % [high["odds"], med["odds"]])
	check(float(high["factors"]["range"]) < 1.0 and float(med["factors"]["range"]) == 1.0, "...because of the range factor, not the cone")
	# All around: the same at every azimuth, whichever way the battery faces.
	for heading: float in [0.0, 1.1, -2.5]:
		var base: Dictionary = shoot.call(heading, 500.0, 0.0, 400.0)
		check(base["in_cone"], "a plane at 500 m, 400 m up, is in the cone (battery heading %s)" % heading)
		for k in 8:
			var az := TAU * float(k) / 8.0
			var g: Dictionary = shoot.call(heading, 500.0 * cos(az), 500.0 * sin(az), 400.0)
			check(g["in_cone"] and absf(float(g["odds"]) - float(base["odds"])) < 1e-12 and absf(float(g["r"]) - float(base["r"])) < 1e-12, "the same cone at azimuth %d deg (battery heading %s)" % [roundi(rad_to_deg(az)), heading])
	# The cone is aimed up: low angles are outside it, however near. Use a reach long enough that only the cone speaks.
	var far_values := flak.values()
	far_values["effective_range_m"] = 10000.0
	var far := CombatWeapon.new(far_values)
	var floor_deg := flak.elevation_deg - flak.half_height_deg
	var below: Dictionary = shoot.call(0.0, 4000.0, 0.0, 4000.0 * tan(deg_to_rad(floor_deg * 0.5)), far)
	check(not below["in_cone"] and not below["in_arc"], "a target at half the cone's floor angle (%.1f deg) is outside it" % (floor_deg * 0.5))
	var above: Dictionary = shoot.call(0.0, 4000.0, 0.0, 4000.0 * tan(deg_to_rad(floor_deg + 3.0)), far)
	check(above["in_cone"], "one 3 degrees above the floor is inside")
	var ground: Dictionary = shoot.call(0.0, 300.0, 0.0, 0.0, far)
	check(not ground["in_cone"], "a unit on the ground is never in the cone")

# --- Flak by band: the tuning table ---------------------------------------------------------

# A plane flies straight over the battery at cruise, with 999 pips so it stays up. Returns the expected pips
# of the pass (the sum of the flak rolls' odds) and the rolls it drew.
func _pass(type_id: String, band: String, offset_m: float) -> Dictionary:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	var speed: float = w.unit_def(type_id).envelope.speed_cruise
	w.add_unit({"id": "p", "type": type_id, "side": "allies", "controller": "player", "x": 700.0, "y": 2500.0 + offset_m, "heading": 0.0, "altitude_band": band, "speed": speed})
	w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	w.units["p"].health = 999
	var expected := 0.0
	var rolls := 0
	for _t in int(ceil(3600.0 / speed / 5.0)) + 1:
		var res := BombWorlds.turn(w)
		for ev: Dictionary in res["events"]:
			if ev["type"] == "fire":
				expected += float(ev["odds"])
				rolls += 1
		w.begin_turn()
	return {"expected": expected, "rolls": rolls}

func _flak_by_band() -> Dictionary:
	print("  flak: expected pips of damage, one battery, a plane flying straight over it at cruise (and 600 m aside)")
	print("  %-14s %-8s %-8s %-8s" % ["plane", "low", "medium", "high"])
	var table := {}
	for type_id: String in ["bomber", "light_fighter"]:
		var row: Array[String] = []
		for band: String in ["low", "medium", "high"]:
			var over := _pass(type_id, band, 0.0)
			var aside := _pass(type_id, band, 600.0)
			table["%s/%s" % [type_id, band]] = float(over["expected"])
			table["%s/%s/aside" % [type_id, band]] = float(aside["expected"])
			row.append("%.2f (%.2f)" % [over["expected"], aside["expected"]])
		print("  %-14s %-8s %-8s %-8s" % [type_id, row[0], row[1], row[2]])
	for type_id: String in ["bomber", "light_fighter"]:
		var low: float = table["%s/low" % type_id]
		var med: float = table["%s/medium" % type_id]
		var high: float = table["%s/high" % type_id]
		check(low >= 1.0 and med >= 1.0, "%s: flak is strong in the low and medium bands (%.2f and %.2f pips a pass)" % [type_id, low, med])
		check(high <= 0.2 * minf(low, med), "%s: and weak in the high one (%.2f pips, a fifth of %.2f)" % [type_id, high, minf(low, med)])
		check(high < 0.5, "%s: under half a pip a pass in the high band (%.2f)" % [type_id, high])
		# Missing the battery by 600 m costs the high band everything and the others little: height keeps the high plane out.
		check(float(table["%s/high/aside" % type_id]) <= 0.01, "%s: a high plane passing 600 m to one side is out of reach (%.3f)" % [type_id, table["%s/high/aside" % type_id]])
		check(float(table["%s/medium/aside" % type_id]) > 0.5 * med, "%s: a medium plane passing 600 m aside is still in it (%.2f of %.2f)" % [type_id, table["%s/medium/aside" % type_id], med])
	return table

# The dice: a plane with one pip over the battery is brought down often at medium and rarely at high.
func _flak_rolls(table: Dictionary) -> void:
	var downs := {"low": 0, "medium": 0, "high": 0}
	var shown := false
	for band: String in downs:
		for s in 40:
			var w := World.new()
			w.quiet = true
			w.rng_seed = s + 1
			w.add_player("local")
			w.add_unit({"id": "p", "type": "light_fighter", "side": "allies", "controller": "player", "x": 700.0, "y": 2500.0, "heading": 0.0, "altitude_band": band, "speed": 100.0})
			w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
			w.units["p"].health = 1
			var went_down := false
			for _t in 8:
				var res := BombWorlds.turn(w)
				for ev: Dictionary in res["events"]:
					if ev["type"] == "fire":
						check(ev["unit"] == "aa" and ev["weapon"] == "flak" and ev["target"] == "p" and float(ev["r"]) <= 1.0, "a flak roll names the battery, the weapon and the plane, inside the cone")
						check(float(ev["distance"]) <= 900.0 * (1.0 + w.combat.range_overshoot) + 1e-6, "...inside its reach (%.0f m)" % ev["distance"])
						check(float(ev["height_m"]) == 6.0 and float(ev["x"]) == 2500.0, "...fired from the battery's guns (6 m up)")
					elif ev["type"] == "hit":
						check(ev["by"] == "aa" and ev["weapon"] == "flak" and ev["unit"] == "p" and ev["damage"] == 1 and ev["health"] == 0, "a flak hit takes one pip")
					elif ev["type"] == "down":
						went_down = true
						check(ev["unit"] == "p" and ev["by"] == "aa" and (ev["fate"] == Unit.FATE_EXPLODED or ev["fate"] == Unit.FATE_OUT_OF_CONTROL), "a plane shot down by flak explodes or falls: %s" % ev["fate"])
				w.begin_turn()
				if went_down:
					break
			if went_down:
				downs[band] += 1
	print("  flak dice, a one-pip light fighter flying over the battery, 40 seeds: down low %d, medium %d, high %d" % [downs["low"], downs["medium"], downs["high"]])
	check(downs["medium"] >= 24 and downs["low"] >= 24, "low and medium planes are usually brought down (%d and %d of 40)" % [downs["low"], downs["medium"]])
	check(downs["high"] <= 16 and downs["high"] * 2 < downs["medium"], "high ones rarely (%d of 40)" % downs["high"])

# --- A destroyed ground unit ------------------------------------------------------------------

func _destroyed_battery_stops() -> void:
	var w := World.new()
	w.quiet = true
	w.rng_seed = 3
	w.add_player("local")
	w.add_unit({"id": "p", "type": "bomber", "side": "allies", "controller": "player", "x": 1900.0, "y": 2500.0, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
	w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	w.units["p"].health = 999
	var aa_health: int = w.units["aa"].health
	w.units["aa"].health = 3
	# A bomb of the bomber's lands on the battery one second in: a direct hit, 3 pips.
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, 2500.0, 2500.0, 1.0, 0, "p")])
	var res := BombWorlds.turn(w)
	var impacts := BombWorlds.events_of(res, "bomb_impact")
	eq(impacts.size(), 1, "the bomb landed")
	var down := BombWorlds.events_of(res, "down", "aa")
	eq(down.size(), 1, "the battery went down")
	if down.size() == 1:
		eq(down[0]["fate"], Unit.FATE_DESTROYED, "destroyed, not exploded or fallen")
		eq(down[0]["by"], "p", "by the bomber whose bomb it was")
		near(float(down[0]["t"]), 1.0, 1e-9, "at the moment the bomb landed")
		check(float(down[0]["x"]) == 2500.0 and float(down[0]["height_m"]) == 0.0, "where it stands, on the ground")
	var aa: Unit = w.units["aa"]
	check(aa.down and aa.fate == Unit.FATE_DESTROYED and aa.health == 0, "the battery is down with the fate 'destroyed'")
	check(w.units.has("aa") and float(aa.x) == 2500.0, "and stays in World.units, where it was")
	check(is_nan(w.units["aa"].fall_height_m), "it does not fall")
	var fired_after := 0
	var fired_before := 0
	for ev: Dictionary in BombWorlds.events_of(res, "fire", "aa"):
		if float(ev["t"]) > 1.0 + 0.2501:
			fired_after += 1
		else:
			fired_before += 1
	check(fired_before > 0, "it fired before it went down (%d rolls)" % fired_before)
	eq(fired_after, 0, "and not after")
	w.begin_turn()
	w.last_error = ""
	eq(w.plan_step("aa", 0, {}), {}, "a destroyed unit takes no orders")
	check(w.last_error.contains("down") or w.last_error.contains("static"), "(%s)" % w.last_error)
	var res2 := BombWorlds.turn(w)
	eq(BombWorlds.events_of(res2, "fire", "aa").size(), 0, "and it fires no more in the next turn")
	eq(w.units["aa"].history.size(), 2, "its history stays two states")
	check(aa_health > 3 or aa_health == 4, "(the battery's full health was %d pips)" % aa_health)

# --- A client matches the host --------------------------------------------------------------------

func _client_matches() -> void:
	var host := BombWorlds.world(11, "medium", true)
	var client := BombWorlds.world(11, "medium", true)
	for t in 3:
		var res := BombWorlds.turn(host)
		check(not res.is_empty(), "turn %d resolves on the host" % (t + 1))
		check(client.apply_resolution(res), "and applies on the client: %s" % client.last_error)
		for id: String in host.units:
			check(_same((client.units[id] as Unit).net_state(), (host.units[id] as Unit).net_state()), "turn %d: %s agrees" % [t + 1, id])
			check(_same((client.units[id] as Unit).history, (host.units[id] as Unit).history), "turn %d: %s's history agrees" % [t + 1, id])
		host.begin_turn()
		client.begin_turn()

# Equality that treats NaN as equal to NaN (a unit that is up has down_at NaN).
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
