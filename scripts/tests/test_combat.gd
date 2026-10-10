extends "res://scripts/test_support/test_case.gd"

# THE COMBAT CHECK (Track C, first fight): the hit model and the rolls.
#
#   - cone geometry: in and out across, in height, as an ellipse; a rearward
#     turret; a hardpoint's offset changes the result near the edge; range; the
#     airframe's pitch tilts the cones
#   - odds: peaked against flat, the product of named factors, nothing outside
#     the cone
#   - the seeds: every index changes the stream; the fate stream is its own
#   - the turn: determinism (same seed and plans, same events; another seed,
#     other rolls; a roll does not depend on the other units), a scripted tail
#     chase that lands hits at the odds the events say, a unit going down
#     mid-turn that stops firing and being hit, a fighter diving through the
#     bomber's height that rolls only while inside the cone, the host-to-client
#     round trip with events, and a down unit that takes no orders
#
# The values it checks are the proposed ones in data/units and data/sim/combat.json;
# the cross-band case is derived from them (see its comment), so retuning a cone
# or the tilt asks for it to be re-derived.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")
const CombatRules = preload("res://scripts/sim/combat_rules.gd")
const CombatResolver = preload("res://scripts/sim/combat_resolver.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

# A level shooter turned a little, so the rotation is exercised.
const SHOOTER := {"x": 3000.0, "y": 2500.0, "heading": 0.7, "height_m": 400.0}

func setup(_main) -> void:
	var w := World.new()
	if not check(w.ok(), "the world's data loads: %s" % str(w.errors)):
		finish()
		return
	_rules()
	_geometry(w)
	_odds(w)
	_seeds()
	_determinism()
	_chase()
	_down_mid_turn()
	_cross_band()
	_round_trip()
	finish()

# --- helpers ---------------------------------------------------------------------

func _new_world(seed_value: int) -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	return w

func _add(w: World, id: String, type: String, side: String, x: float, y: float, heading: float, speed: float = -1.0, band: String = "") -> void:
	var spec := {"id": id, "type": type, "side": side, "controller": "player", "x": x, "y": y, "heading": heading}
	if speed > 0.0:
		spec["speed"] = speed
	if band != "":
		spec["altitude_band"] = band
	eq(w.add_unit(spec), id, "unit %s added" % id)

# Commit, resolve, and return the result ({} on failure).
func _turn(w: World) -> Dictionary:
	w.commit("local")
	var res := w.resolve()
	check(not res.is_empty(), "turn %d resolves: %s" % [w.turn, w.last_error])
	return res

func _of_type(events: Array, type: String) -> Array:
	var out: Array = []
	for ev: Dictionary in events:
		if ev["type"] == type:
			out.append(ev)
	return out

# NaN equal to NaN, dictionaries and arrays by content.
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

# A point `dist` metres from a pose, in the airframe's axes at `across_deg` /
# `height_deg` off the weapon's cone centre: the test places targets exactly.
func _target_from(p: Dictionary, weapon: CombatWeapon, across_deg: float, height_deg: float, dist: float) -> Dictionary:
	var b := weapon.mount + deg_to_rad(across_deg)
	var e := weapon.elevation + deg_to_rad(height_deg)
	var cb := cos(b)
	var sb := sin(b)
	var ce := cos(e)
	var se := sin(e)
	var dx: float = ce * (cb * float(p["fx"]) + sb * float(p["rx"])) + se * float(p["ux"])
	var dy: float = ce * (cb * float(p["fy"]) + sb * float(p["ry"])) + se * float(p["uy"])
	var dz: float = ce * (cb * float(p["fz"])) + se * float(p["uz"])
	return {"x": float(p["x"]) + dist * dx, "y": float(p["y"]) + dist * dy, "height_m": float(p["z"]) + dist * dz}

func _eval(shooter: Dictionary, weapon: CombatWeapon, hp: int, across_deg: float, height_deg: float, dist: float) -> Dictionary:
	var p := Combat.pose(shooter, weapon.hardpoints[hp])
	return Combat.evaluate_pose(p, weapon, _target_from(p, weapon, across_deg, height_deg, dist), ["centre"])

# --- the rules file --------------------------------------------------------------

func _rules() -> void:
	var r := CombatRules.new()
	check(r.ok(), "data/sim/combat.json loads: %s" % str(r.errors))
	eq(r.odds_factors, ["centre"] as Array[String], "the only decided odds factor is the cone's centre")
	check(r.tick_seconds > 0.0 and r.tick_seconds <= 1.0, "the tick is a fraction of a step")
	check(r.max_pitch > 0.0, "the climb tilt is on (max_pitch_deg > 0)")
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(CombatRules.PATH))
	var bad: Dictionary = d.duplicate(true)
	bad["odds_factors"] = {"value": ["range"], "_proposed": true, "_reason": "x"}
	var rb := CombatRules.new(bad, true)
	check(not rb.ok() and "; ".join(rb.errors).contains("range"), "a factor the code does not know is a data error: %s" % str(rb.errors))
	bad = d.duplicate(true)
	bad["tick_seconds"] = 0.25
	check(not CombatRules.new(bad, true).ok(), "a bare number instead of a value record is rejected")
	bad = d.duplicate(true)
	bad.erase("explode_chance")
	check(not CombatRules.new(bad, true).ok(), "a missing field is rejected, not defaulted")

# --- cone geometry ---------------------------------------------------------------

func _geometry(w: World) -> void:
	var cannon: CombatWeapon = w.unit_def("heavy_fighter").weapons[0]
	var tail: CombatWeapon = null
	var dorsal: CombatWeapon = null
	for wp: CombatWeapon in w.unit_def("bomber").weapons:
		if wp.id == "tail_turret":
			tail = wp
		elif wp.id == "dorsal_turret":
			dorsal = wp
	var wing: CombatWeapon = w.unit_def("light_fighter").weapons[0]
	if not check(cannon.id == "nose_cannon" and tail != null and dorsal != null and wing.id == "wing_guns", "the weapons the geometry cases use exist"):
		return

	# Dead ahead of the nose cannon (7 deg across, 6 deg in height, 600 m).
	var g := _eval(SHOOTER, cannon, 0, 0.0, 0.0, 300.0)
	check(bool(g["in_cone"]), "dead ahead is in the cone")
	near(float(g["r"]), 0.0, 1e-9, "dead ahead is the centre (r = 0)")
	near(float(g["distance"]), 300.0, 1e-9, "the distance is from the hardpoint")
	near(float(g["odds"]), cannon.base_hit_chance, 1e-12, "odds at the centre are the base chance")
	# Across: inside and outside the 7 degree half-width, both sides.
	for side: float in [1.0, -1.0]:
		check(bool(_eval(SHOOTER, cannon, 0, 6.5 * side, 0.0, 300.0)["in_cone"]), "6.5 deg to one side is inside a 7 deg cone (%s)" % side)
		check(not bool(_eval(SHOOTER, cannon, 0, 7.5 * side, 0.0, 300.0)["in_cone"]), "7.5 deg to one side is outside a 7 deg cone (%s)" % side)
		check(bool(_eval(SHOOTER, cannon, 0, 0.0, 5.5 * side, 300.0)["in_cone"]), "5.5 deg up or down is inside a 6 deg cone (%s)" % side)
		check(not bool(_eval(SHOOTER, cannon, 0, 0.0, 6.5 * side, 300.0)["in_cone"]), "6.5 deg up or down is outside a 6 deg cone (%s)" % side)
	# The cone is an ellipse: 5 deg across and 4.5 up are each inside their limits
	# but together outside (r = 1.036); 4 and 3 are inside (r = 0.759).
	var ell := _eval(SHOOTER, cannon, 0, 5.0, 4.5, 300.0)
	check(not bool(ell["in_cone"]) and float(ell["r"]) > 1.0, "5 deg across with 4.5 up is outside the ellipse (r = %.3f)" % float(ell["r"]))
	var ell_in := _eval(SHOOTER, cannon, 0, 4.0, 3.0, 300.0)
	check(bool(ell_in["in_cone"]), "4 across with 3 up is inside")
	near(float(ell_in["r"]), sqrt(pow(4.0 / 7.0, 2.0) + pow(3.0 / 6.0, 2.0)), 2e-3, "r combines across and height as an ellipse")
	# The signs: across is positive to the right (clockwise), height positive up.
	check(float(_eval(SHOOTER, cannon, 0, 3.0, 0.0, 300.0)["across"]) > 0.0, "across is positive to the right")
	check(float(_eval(SHOOTER, cannon, 0, 0.0, 3.0, 300.0)["height"]) > 0.0, "height is positive upward")
	# Range, from the hardpoint, in the slant.
	check(bool(_eval(SHOOTER, cannon, 0, 0.0, 0.0, 599.0)["in_cone"]), "599 m is inside a 600 m weapon")
	var far := _eval(SHOOTER, cannon, 0, 0.0, 0.0, 601.0)
	check(not bool(far["in_cone"]) and bool(far["in_arc"]) and not bool(far["in_range"]), "601 m is in the arc but out of range")
	check(float(far["odds"]) == 0.0, "outside the cone the odds are 0")

	# A target in another band is the same cone: 600 m above a level gun is far
	# outside 6 deg; a target 40 m above at 300 m (7.6 deg) is outside, 25 m (4.8) inside.
	var high_t := {"x": 3300.0, "y": 2500.0, "height_m": 1000.0}
	check(not bool(Combat.evaluate(SHOOTER, cannon, 0, high_t)["in_cone"]), "a bomber a band above a level fighter is outside its cone")

	# The rearward turrets: the tail turret (mount 180, 40 across, 30 in height, 400 m).
	check(bool(_eval(SHOOTER, tail, 0, 0.0, 0.0, 300.0)["in_cone"]), "straight behind is in the tail turret's cone")
	check(bool(_eval(SHOOTER, tail, 0, 35.0, 0.0, 300.0)["in_cone"]), "35 deg off the tail is inside +-40")
	check(not bool(_eval(SHOOTER, tail, 0, 45.0, 0.0, 300.0)["in_cone"]), "45 deg off the tail is outside +-40")
	var ahead_p := Combat.pose(SHOOTER, tail.hardpoints[0])
	var ahead_t := {"x": float(ahead_p["x"]) + 300.0 * float(ahead_p["fx"]), "y": float(ahead_p["y"]) + 300.0 * float(ahead_p["fy"]), "height_m": 400.0 + 0.5}
	check(not bool(Combat.evaluate_pose(ahead_p, tail, ahead_t, ["centre"])["in_cone"]), "the tail turret does not cover the front")
	# Range: the tail turret reaches 400 m and not 450.
	check(bool(_eval(SHOOTER, tail, 0, 0.0, 0.0, 399.0)["in_cone"]), "the tail turret reaches 399 m")
	check(not bool(_eval(SHOOTER, tail, 0, 0.0, 0.0, 401.0)["in_cone"]), "the tail turret does not reach 401 m")
	check(not bool(_eval(SHOOTER, tail, 0, 0.0, 0.0, 450.0)["in_cone"]), "the tail turret does not reach 450 m")
	check(wing.range_m == 450.0, "the wing guns reach 450 m (the proposal)")
	check(bool(_eval(SHOOTER, wing, 0, 0.0, 0.0, 449.0)["in_cone"]), "the wing guns reach 449 m")
	# The proposal sheet's third picture: a fighter 430 m behind a bomber is in its
	# wing guns' range and out of the tail turret's (the hardpoint is 10.5 m behind the centre).
	var bomber_state := {"x": 3000.0, "y": 2500.0, "heading": 0.0, "height_m": 400.0}
	var fighter_state := {"x": 2570.0, "y": 2500.0, "heading": 0.0, "height_m": 400.0}
	var bomber_sees := Combat.evaluate(bomber_state, tail, 0, fighter_state)
	check(not bool(bomber_sees["in_cone"]) and bool(bomber_sees["in_arc"]), "430 m behind: the tail turret has it in its arc but out of range")
	check(bool(Combat.evaluate(fighter_state, wing, 0, bomber_state)["in_cone"]), "430 m behind: the wing guns reach the bomber")
	# The dorsal turret: +-110 across, centre 35 up with +-35: wide and high, not level.
	check(bool(_eval(SHOOTER, dorsal, 0, 100.0, 0.0, 300.0)["in_cone"]), "the dorsal turret covers 100 deg either side of the tail")
	check(not bool(_eval(SHOOTER, dorsal, 0, 120.0, 0.0, 300.0)["in_cone"]), "...and not 120")
	check(bool(_eval(SHOOTER, dorsal, 0, 0.0, -15.0, 300.0)["in_cone"]), "it covers a target 20 deg above the level behind (35 - 15)")
	check(not bool(_eval(SHOOTER, dorsal, 0, 0.0, -45.0, 300.0)["in_cone"]), "it does not cover a target 10 deg BELOW the level")
	var level_behind := Combat.evaluate(SHOOTER, dorsal, 0, {"x": 3000.0 - 300.0 * cos(0.7), "y": 2500.0 - 300.0 * sin(0.7), "height_m": 400.0})
	check(not bool(level_behind["in_cone"]), "a plane level and straight behind is the tail turret's, not the dorsal turret's (r = %.3f)" % float(level_behind["r"]))

	# A hardpoint's offset changes the result near the edge: a target 12 m ahead
	# of the centre and 2.5 m to the right. The right wing gun (3 m right, 0.3 m
	# back) sees it 2.3 deg off its nose; the left one 24 deg.
	var wp_p := Combat.pose(SHOOTER, wing.hardpoints[1])
	var fx := cos(0.7)
	var fy := sin(0.7)
	near(float(wp_p["x"]), 3000.0 + (-0.3) * fx + 3.0 * (-sin(0.7)), 1e-6, "the right hardpoint is placed from the heading (x)")
	near(float(wp_p["y"]), 2500.0 + (-0.3) * fy + 3.0 * cos(0.7), 1e-6, "the right hardpoint is placed from the heading (y)")
	var near_t := {"x": 3000.0 + 12.0 * fx + 2.5 * (-sin(0.7)), "y": 2500.0 + 12.0 * fy + 2.5 * cos(0.7), "height_m": 400.0}
	var left_gun := Combat.evaluate(SHOOTER, wing, 0, near_t)
	var right_gun := Combat.evaluate(SHOOTER, wing, 1, near_t)
	check(bool(right_gun["in_cone"]) and not bool(left_gun["in_cone"]), "the hardpoint's offset decides: right gun in (%.1f deg), left gun out (%.1f deg)" % [rad_to_deg(float(right_gun["across"])), rad_to_deg(float(left_gun["across"]))])
	near(rad_to_deg(float(right_gun["across"])), -atan(0.5 / 12.3) * 180.0 / PI, 0.01, "the right gun sees it slightly to its left")

	# The airframe's pitch tilts every cone with it (nose up positive). A forward
	# gun pitched up 20 deg has a level target 20 deg below its axis; a tail
	# turret pitched up 20 deg has it 20 deg ABOVE its axis.
	var up20 := SHOOTER.duplicate()
	up20["pitch"] = deg_to_rad(20.0)
	var lvl_ahead := {"x": 3000.0 + 300.0 * fx, "y": 2500.0 + 300.0 * fy, "height_m": 400.0}
	var pitched := Combat.evaluate(up20, cannon, 0, lvl_ahead)
	check(not bool(pitched["in_cone"]) and absf(rad_to_deg(float(pitched["height"])) + 20.0) < 1.0, "a nose-up gun has a level target about 20 deg below its axis (%.2f)" % rad_to_deg(float(pitched["height"])))
	var lvl_behind := {"x": 3000.0 - 300.0 * fx, "y": 2500.0 - 300.0 * fy, "height_m": 400.0}
	var tail_p := Combat.evaluate(up20, tail, 0, lvl_behind)
	check(bool(tail_p["in_cone"]) and rad_to_deg(float(tail_p["height"])) > 15.0, "a nose-up tail turret has a level target behind about 20 deg above its axis, still inside +-30 (%.2f)" % rad_to_deg(float(tail_p["height"])))
	var up35 := SHOOTER.duplicate()
	up35["pitch"] = deg_to_rad(35.0)
	check(not bool(Combat.evaluate(up35, tail, 0, lvl_behind)["in_cone"]), "...at 35 deg of pitch it is outside")
	var up5 := SHOOTER.duplicate()
	up5["pitch"] = deg_to_rad(5.0)
	check(bool(Combat.evaluate(up5, cannon, 0, lvl_ahead)["in_cone"]), "5 deg of pitch leaves a 6 deg cone on a level target")

# --- odds --------------------------------------------------------------------------

func _odds(w: World) -> void:
	var cannon: CombatWeapon = w.unit_def("heavy_fighter").weapons[0]
	var tail: CombatWeapon = null
	for wp: CombatWeapon in w.unit_def("bomber").weapons:
		if wp.id == "tail_turret":
			tail = wp
	check(cannon.rim_odds_factor < 1.0, "a fixed gun is peaked (rim factor %.2f < 1)" % cannon.rim_odds_factor)
	check(tail.rim_odds_factor == 1.0, "a turret is flat (rim factor 1)")
	# Across offsets giving r = 0, 0.5, 0.9 of the cannon's 7 degrees.
	var last := INF
	for r: float in [0.0, 0.5, 0.9]:
		var g := _eval(SHOOTER, cannon, 0, 7.0 * r, 0.0, 300.0)
		var want: float = cannon.base_hit_chance * (1.0 - (1.0 - cannon.rim_odds_factor) * pow(r, cannon.falloff_exponent))
		near(float(g["odds"]), want, 1e-6, "the cannon's odds at r = %.1f follow base x (1 - (1 - rim) r^p)" % r)
		check(float(g["odds"]) < last, "peaked: the odds fall as the target nears the rim (r = %.1f)" % r)
		last = float(g["odds"])
	# Flat: the tail turret's odds are the same anywhere in the cone.
	var o0 := float(_eval(SHOOTER, tail, 0, 0.0, 0.0, 300.0)["odds"])
	var o9 := float(_eval(SHOOTER, tail, 0, 0.9 * 40.0, 0.0, 300.0)["odds"])
	near(o0, tail.base_hit_chance, 1e-12, "a flat gun's odds are the base chance at the centre")
	near(o9, o0, 1e-12, "...and at r = 0.9")
	# The product of the named factors: none named, the base chance; the centre
	# factor named, the factor is in the result and multiplies the odds.
	var p := Combat.pose(SHOOTER, cannon.hardpoints[0])
	var t := _target_from(p, cannon, 3.5, 0.0, 300.0)
	var none := Combat.evaluate_pose(p, cannon, t, [])
	var with_c := Combat.evaluate_pose(p, cannon, t, ["centre"])
	near(float(none["odds"]), cannon.base_hit_chance, 1e-12, "with no factors named the odds are the base chance")
	check((with_c["factors"] as Dictionary).has("centre"), "the result lists the factors that were applied")
	near(float(with_c["odds"]), cannon.base_hit_chance * float((with_c["factors"] as Dictionary)["centre"]), 1e-12, "the odds are base x the product of the factors")
	check(float(with_c["odds"]) < float(none["odds"]), "the centre factor lowers the odds off the centre")

	# Rolls per tick: the global clock, a whole number of rolls over the turn.
	var rolls := 0
	var pattern := ""
	for i in range(1, 21):
		var n := Combat.rolls_in_tick(2.0, 0.25 * (i - 1), 0.25 * i)
		rolls += n
		pattern += str(n)
	eq(pattern, "01010101010101010101", "2 rolls a second on a 0.25 s tick: every other tick, the first at 0.5 s")
	eq(rolls, 10, "...10 rolls in 5 s")
	eq(Combat.rolls_in_tick(1.0, 0.75, 1.0), 1, "1 roll a second: a roll at t = 1.0")
	eq(Combat.rolls_in_tick(8.0, 0.0, 0.25), 2, "8 rolls a second on a 0.25 s tick: two rolls in the tick")

# --- seeds --------------------------------------------------------------------------

func _seeds() -> void:
	var base := Combat.roll_seed(20261009, 3, 2, 1, 0, 7)
	eq(Combat.roll_seed(20261009, 3, 2, 1, 0, 7), base, "a roll's seed is a pure function of its indices")
	var variants: Array = [
		Combat.roll_seed(20261010, 3, 2, 1, 0, 7), Combat.roll_seed(20261009, 4, 2, 1, 0, 7),
		Combat.roll_seed(20261009, 3, 3, 1, 0, 7), Combat.roll_seed(20261009, 3, 2, 2, 0, 7),
		Combat.roll_seed(20261009, 3, 2, 1, 1, 7), Combat.roll_seed(20261009, 3, 2, 1, 0, 8),
	]
	var seen := {base: true}
	for v: int in variants:
		check(not seen.has(v), "changing any one index changes the stream")
		seen[v] = true
	check(base >= 0 and base <= 0xFFFFFFFF, "the seed is a 32-bit value")
	check(Combat.fate_seed(20261009, 3, 2, 7) != Combat.roll_seed(20261009, 3, 2, 7, 0, 0), "the fate stream is its own")
	# Neighbouring seeds give unrelated first draws (the mix works): the draws
	# of 200 neighbouring ticks fall about half under 0.5.
	var under := 0
	for tick in 200:
		var rng := Mulberry32.new(Combat.roll_seed(1, 1, 0, 0, 0, tick))
		if rng.next() < 0.5:
			under += 1
	check(under > 75 and under < 125, "neighbouring ticks draw a fair spread (%d of 200 under 0.5)" % under)

# --- a world to compare -------------------------------------------------------------

# A light fighter chasing a bomber, both flying the bomber's cruise speed, the
# fighter `gap` m behind, in one band. The fighter's plan wobbles a little (turns
# in steps 1 and 3) so the cones are not always centred.
func _chase_world(seed_value: int, gap: float, wobble: bool = true) -> World:
	var w := _new_world(seed_value)
	_add(w, "bomber", "bomber", "axis", 1200.0, 2500.0, 0.0, 85.0, "medium")
	_add(w, "fighter", "light_fighter", "allies", 1200.0 - gap, 2500.0, 0.0, 85.0, "medium")
	if wobble:
		w.plan_step("fighter", 1, {"turn": 0.03})
		w.plan_step("fighter", 3, {"turn": -0.03})
	return w

func _play(w: World, turns: int, wobble: bool = false) -> Array:
	var all: Array = []
	for i in turns:
		if wobble:
			w.plan_step("fighter", 1, {"turn": 0.03})
		all.append(_turn(w))
		w.begin_turn()
	return all

func _determinism() -> void:
	var runs: Array = []
	for i in 2:
		runs.append(_play(_chase_world(7, 300.0), 4, true))
	var ev_a: Array = []
	var ev_b: Array = []
	for res: Dictionary in runs[0]:
		ev_a.append_array(res["events"])
	for res: Dictionary in runs[1]:
		ev_b.append_array(res["events"])
	check(ev_a.size() > 0, "the scripted run produces events")
	check(_same(ev_a, ev_b), "two Worlds with the same seed and plans produce identical events (%d events)" % ev_a.size())
	var same_states := true
	for t in 4:
		same_states = same_states and _same((runs[0][t] as Dictionary)["units"], (runs[1][t] as Dictionary)["units"])
	check(same_states, "...and identical unit states every turn")
	var other: Array = _play(_chase_world(8, 300.0), 4, true)
	var ev_c: Array = []
	for res: Dictionary in other:
		ev_c.append_array(res["events"])
	var flags_a: Array = []
	var flags_c: Array = []
	for ev: Dictionary in _of_type(ev_a, "fire"):
		flags_a.append(ev["hit"])
	for ev: Dictionary in _of_type(ev_c, "fire"):
		flags_c.append(ev["hit"])
	check(flags_a != flags_c, "another seed draws other rolls (%d and %d rolls)" % [flags_a.size(), flags_c.size()])

	# A roll does not depend on the others: a third unit, added last and far
	# away, leaves the fighter's rolls as they were.
	var w1 := _chase_world(11, 300.0, false)
	var w2 := _chase_world(11, 300.0, false)
	_add(w2, "straggler", "light_fighter", "allies", 200.0, 200.0, 0.0, 100.0, "low")
	var e1: Array = []
	var e2: Array = []
	for ev: Dictionary in (_turn(w1)["events"] as Array):
		if ev.get("unit") == "fighter" or ev.get("unit") == "bomber":
			e1.append(ev)
	for ev: Dictionary in (_turn(w2)["events"] as Array):
		if ev.get("unit") == "fighter" or ev.get("unit") == "bomber":
			e2.append(ev)
	check(e1.size() > 0 and _same(e1, e2), "a far-off third unit does not change the others' rolls (%d events)" % e1.size())

# --- a scripted tail chase ----------------------------------------------------------

func _chase() -> void:
	# One turn of a light fighter 300 m behind a bomber at the same speed and
	# heading: the wing guns (450 m) are on it the whole turn, the tail turret
	# (400 m) answers. Many seeds: the hits must land at the odds the events say.
	var rolls := 0
	var hits := 0
	var sum_odds := 0.0
	var sum_var := 0.0
	var by_fighter_ok := true
	var bomber_rolls := 0
	for s in range(1, 41):
		var w := _chase_world(s, 300.0, false)
		w.units["bomber"].health = 1000
		w.units["fighter"].health = 1000
		var res := _turn(w)
		var turn_hits := 0
		for ev: Dictionary in _of_type(res["events"], "fire"):
			if ev["unit"] == "fighter":
				rolls += 1
				sum_odds += float(ev["odds"])
				sum_var += float(ev["odds"]) * (1.0 - float(ev["odds"]))
				if ev["hit"]:
					hits += 1
					turn_hits += 1
				by_fighter_ok = by_fighter_ok and ev["target"] == "bomber" and ev["weapon"] == "wing_guns"
			elif ev["unit"] == "bomber":
				bomber_rolls += 1
				check(ev["weapon"] == "tail_turret", "the bomber answers from the tail turret only (not the dorsal turret: the fighter is level)")
		eq(w.units["bomber"].health, 1000 - turn_hits, "seed %d: the bomber lost a pip per hit" % s)
	check(by_fighter_ok, "the fighter's wing guns roll at the bomber")
	eq(rolls, 40 * 20, "20 rolls a turn on a centred target: 2 hardpoints x 10 (2 rolls a second for 5 s)")
	check(bomber_rolls == 40 * 10, "the tail turret rolls 10 times a turn (%d)" % bomber_rolls)
	check(hits > 0, "the fighter lands hits")
	print("  chase: 40 turns, %d rolls, %d hits, expected %.1f (sigma %.1f); the bomber answered with %d rolls" % [rolls, hits, sum_odds, sqrt(sum_var), bomber_rolls])
	var sigma := sqrt(sum_var)
	check(absf(float(hits) - sum_odds) <= 5.0 * sigma, "hits (%d) land at the events' own odds (expected %.1f, sigma %.1f)" % [hits, sum_odds, sigma])
	check(sum_odds > 0.9 * 800.0 * 0.14, "a centred target gets nearly the full base odds (mean %.3f)" % (sum_odds / float(rolls)))

# --- a unit going down mid-turn -----------------------------------------------------

func _head_on(seed_value: int) -> World:
	# Two light fighters closing head-on, 700 m apart: in each other's range after
	# 1.25 s. B has one pip; A has plenty.
	var w := _new_world(seed_value)
	_add(w, "A", "light_fighter", "allies", 2000.0, 2500.0, 0.0, 100.0, "medium")
	_add(w, "B", "light_fighter", "axis", 2700.0, 2500.0, PI, 100.0, "medium")
	w.units["B"].health = 1
	w.units["A"].health = 99
	return w

func _down_mid_turn() -> void:
	var downs := 0
	var first_seed := -1
	for s in range(1, 61):
		var w := _head_on(s)
		var res := _turn(w)
		var events: Array = res["events"]
		var down_events := _of_type(events, "down")
		var b: Unit = w.units["B"]
		if down_events.is_empty():
			check(not b.down and b.health == 1, "seed %d: no down event, B still up with its pip" % s)
			check(is_nan(b.down_at) and b.fate == "", "seed %d: an up unit has no down time and no fate" % s)
			continue
		downs += 1
		if first_seed < 0:
			first_seed = s
		eq(down_events.size(), 1, "seed %d: B goes down once" % s)
		var d: Dictionary = down_events[0]
		var t_star := float(d["t"])
		eq(d["unit"], "B", "seed %d: the down event names B" % s)
		eq(d["by"], "A", "seed %d: ...and A" % s)
		check(["exploded", "out_of_control"].has(d["fate"]), "seed %d: the down event carries the fate (%s)" % [s, d["fate"]])
		check(b.down and b.health == 0 and b.fate == d["fate"], "seed %d: B is down, at 0 pips, with the event's fate" % s)
		near(b.down_at, t_star, 1e-12, "seed %d: down_at is the event's time" % s)
		var late_fire := 0
		var late_hits := 0
		for ev: Dictionary in events:
			if ev["type"] == "fire" and float(ev["t"]) > t_star + 1e-9 and (ev["unit"] == "B" or ev["target"] == "B"):
				late_fire += 1
			if ev["type"] == "hit" and ev["unit"] == "B" and float(ev["t"]) > t_star + 1e-9:
				late_hits += 1
		eq(late_fire, 0, "seed %d: after going down at t = %.2f B neither fires nor is fired at" % [s, t_star])
		eq(late_hits, 0, "seed %d: ...and takes no more hits" % s)
		# B fired before it went down in at least some of the seeds (head-on, both in range).
		# The next turn: nothing fires at or from B either.
		w.begin_turn()
		var res2 := _turn(w)
		for ev: Dictionary in res2["events"]:
			if ev["type"] == "fire":
				check(ev["unit"] != "B" and ev["target"] != "B", "seed %d, next turn: a down unit is out of the fight" % s)
			check(ev["type"] != "down" or ev["unit"] != "B", "seed %d, next turn: B does not go down twice" % s)
		check(is_nan(b.down_at), "seed %d, next turn: down_at is NAN again (it went down in an earlier turn)" % s)
		check(b.down and b.health == 0, "seed %d, next turn: B stays down" % s)
	check(downs >= 20, "B goes down in most seeds (%d of 60); first at seed %d" % [downs, first_seed])
	print("  head-on: B went down in %d of 60 seeds" % downs)
	# B shot back before it went down in at least one seed (the head-on is mutual).
	var b_fired := false
	for s in range(1, 21):
		var w := _head_on(s)
		for ev: Dictionary in (_turn(w)["events"] as Array):
			if ev["type"] == "fire" and ev["unit"] == "B":
				b_fired = true
	check(b_fired, "B fires while it is up: the head-on is mutual")

	# A down unit takes no orders (quiet: the refusal is recorded, not logged).
	var w := _head_on(first_seed)
	_turn(w)
	w.begin_turn()
	var participants_before := w.participants()
	w.last_error = ""
	eq(w.plan_step("B", 0, {"turn": 0.1}), {}, "plan_step refuses a down unit")
	check(w.last_error.contains("down"), "...and says why: %s" % w.last_error)
	w.last_error = ""
	w.units["A"].plan.clear()
	w.clear_plan("B")
	check(w.last_error.contains("down"), "clear_plan refuses a down unit too: %s" % w.last_error)
	eq(w.units["B"].plan.size(), 0, "a refused plan_step leaves no plan")
	check(not w.plan_step("A", 0, {"turn": 0.1}).is_empty(), "the other plane still takes orders")
	check(w.units.has("B") and w.participants() == participants_before, "B stays in units and the ready-up is unchanged")
	w.commit("local")
	check(not w.resolve().is_empty(), "the turn plays with a down unit in it: %s" % w.last_error)

# --- a fighter diving through the bomber's height -----------------------------------

func _cross_band() -> void:
	# The bomber flies level at medium (400 m). The fighter starts a band above
	# (high, 1000 m), 250 m behind, same speed, and dives to medium in step 0
	# (1 s: 600 m, so its airframe pitches down by the cap, 35 deg, for the whole
	# step). Its wing guns are set to roll every tick so each tick is a test.
	# Derived by hand (cannon-free, wing guns +-8 deg in height): at t = 0.25 and
	# 0.5 the bomber is 21 and 15 deg below the nose-down axis (out); at 0.75 it
	# is 4 deg above it (IN); at 1.0 the fighter is level with the bomber but
	# still pitched down (out); from 1.25 it is level and dead ahead (in).
	var w := _new_world(3)
	var wing: CombatWeapon = w.unit_def("light_fighter").weapons[0]
	wing.rolls_per_second = 4.0
	_add(w, "bomber", "bomber", "axis", 1500.0, 2500.0, 0.0, 85.0, "medium")
	_add(w, "fighter", "light_fighter", "allies", 1250.0, 2500.0, 0.0, 85.0, "high")
	w.units["bomber"].health = 1000
	w.units["fighter"].health = 1000
	w.plan_step("fighter", 0, {"altitude_band": "medium"})
	var res := _turn(w)
	# Independent expectation: the tilt is the cap while the fighter changes band
	# (the first step, up to and including t = 1.0), else none.
	var expect: Dictionary = {0: [], 1: []}
	for i in range(1, 21):
		var t := 0.25 * i
		var fs := w.sample("fighter", t)
		var bs := w.sample("bomber", t)
		var shooter := {"x": fs["x"], "y": fs["y"], "heading": fs["heading"], "height_m": fs["height_m"], "pitch": deg_to_rad(-35.0) if t <= 1.0 + 1e-9 else 0.0}
		for h in 2:
			if bool(Combat.evaluate(shooter, wing, h, bs)["in_cone"]):
				(expect[h] as Array).append(t)
	var got: Dictionary = {0: [], 1: []}
	for ev: Dictionary in _of_type(res["events"], "fire"):
		if ev["unit"] == "fighter":
			(got[int(ev["hardpoint"])] as Array).append(float(ev["t"]))
			eq(ev["target"], "bomber", "the fighter fires at the bomber")
	for h in 2:
		eq(got[h], expect[h], "hardpoint %d rolls exactly on the ticks its cone holds the bomber" % h)
	var ticks: Array = got[0]
	print("  cross-band: hardpoint 0 rolled at t = %s" % str(ticks))
	check(ticks.size() > 0 and ticks.size() < 20, "rolls on some ticks and not others (%d of 20)" % ticks.size())
	check(not ticks.has(0.25) and not ticks.has(0.5), "no rolls while the bomber is far below the nose-down cone (t = 0.25, 0.5)")
	check(ticks.has(0.75), "a roll at t = 0.75: the dive's tilt brings the bomber into the cone")
	check(not ticks.has(1.0), "no roll at t = 1.0: level with the bomber but still pitched down")
	var all_after := true
	for i in range(5, 21):
		all_after = all_after and ticks.has(0.25 * i)
	check(all_after, "rolls on every tick from t = 1.25: level and dead ahead")
	# The height the sampler reports for the dive: linear between the bands.
	near(float(w.sample("fighter", 0.5)["height_m"]), 700.0, 1e-9, "half way down the dive step the fighter is half way between high and medium")

# --- the host-to-client round trip with events --------------------------------------

func _round_trip() -> void:
	var seed_down := _down_seed()
	var host := _head_on(seed_down)
	var client := _head_on(seed_down)
	var got: Array = []
	client.turn_resolved.connect(func(t: int, h: Dictionary, e: Array) -> void: got.append([t, h, e]))
	var any_down := false
	for n in range(1, 4):
		got.clear()
		var res := _turn(host)
		check(client.apply_resolution(res), "turn %d: the client applies the host's result: %s" % [n, client.last_error])
		eq(got.size(), 1, "turn %d: the client's turn_resolved fires once" % n)
		for id: String in host.units:
			var hu: Unit = host.units[id]
			var cu: Unit = client.units[id]
			check(_same(hu.net_state(), cu.net_state()), "turn %d, %s: the client's unit state matches the host's" % [n, id])
			check(_same(hu.history, cu.history), "turn %d, %s: ...and its history" % [n, id])
			check(hu.health == cu.health and hu.down == cu.down and hu.fate == cu.fate, "turn %d, %s: ...health, down and fate" % [n, id])
		if got.size() == 1:
			check(_same(got[0][2], res["events"]), "turn %d: the client's events are the host's" % n)
		any_down = any_down or host.units["B"].down
		host.begin_turn()
		client.begin_turn()
	check(any_down, "the round trip covers a unit going down")

# The first seed in which B (one pip) is shot down in the head-on's first turn.
func _down_seed() -> int:
	for s in range(1, 100):
		var w := _head_on(s)
		if not _of_type(_turn(w)["events"], "down").is_empty():
			return s
	fail("no seed downs B in the head-on: the model has stopped hitting")
	return 1
