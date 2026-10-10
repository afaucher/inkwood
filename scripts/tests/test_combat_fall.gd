extends "res://scripts/test_support/test_case.gd"

# THE FATE CHECK (Track C): what a kill does (Alex 2026-10-09: "dead planes should
# either explode mid air or lose control by players and crash eventually").
#
#   - the fate roll: a seeded stream of its own, about explode_chance exploding,
#     the spin of a fall either way
#   - exploded: gone at the tick it was downed, where it was and at its height;
#     it stops; nothing fires at it or from it; it takes no orders
#   - out of control: nobody can plan it, the sim flies it -- it spirals at the
#     data's turn rate, holds or gains speed, loses height at the data's rate,
#     across turns, and crashes on a later turn with a crash event; nothing before
#     the moment it went down moves; the height is continuous from turn to turn
#   - a client World that applies the host's result every turn matches it at
#     every turn, fall height included
#
# Seeds that give each fate are FOUND, not written down (a retune would move
# them); the test fails if none exists. The numbers it checks the fall against
# are read from data/sim/combat.json.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const CombatRules = preload("res://scripts/sim/combat_rules.gd")

func setup(_main) -> void:
	var rules := CombatRules.new()
	if not check(rules.ok(), "combat.json loads: %s" % str(rules.errors)):
		finish()
		return
	_fate_roll(rules)
	var seeds := _find_seeds()
	if seeds.has("exploded") and seeds.has("out_of_control"):
		_exploded(seeds["exploded"], rules)
		_out_of_control(seeds["out_of_control"], rules)
		_history_sanity(rules)
		_low_crash(rules)
	finish()

# --- helpers ---------------------------------------------------------------------

func _new_world(seed_value: int) -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	return w

# A bomber with one pip, high (1000 m), flying straight at 85 m/s; a light fighter
# 300 m behind it at the same speed and height with plenty of pips. The bomber is
# shot down in the first turn in nearly every seed.
func _victim_world(seed_value: int, bomber_health: int = 1, victim_type: String = "bomber", band: String = "high") -> World:
	var w := _new_world(seed_value)
	w.add_unit({"id": "bomber", "type": victim_type, "side": "axis", "controller": "player", "x": 1500.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": band})
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1200.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": band})
	w.units["bomber"].health = bomber_health
	w.units["fighter"].health = 99
	return w

func _turn(w: World) -> Dictionary:
	w.commit("local")
	var res := w.resolve()
	check(not res.is_empty(), "turn %d resolves: %s" % [w.turn, w.last_error])
	return res

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

func _down_event(res: Dictionary) -> Dictionary:
	for ev: Dictionary in res["events"]:
		if ev["type"] == "down" and ev["unit"] == "bomber":
			return ev
	return {}

func _wrap(a: float) -> float:
	return a - TAU * floorf((a + PI) / TAU)

# --- the fate roll -----------------------------------------------------------------

func _fate_roll(rules: CombatRules) -> void:
	var exploded := 0
	var spins := {1: 0, -1: 0}
	for s in 400:
		var r := Combat.fate_roll(s, 1, 0, 3, rules.explode_chance)
		eq(r, Combat.fate_roll(s, 1, 0, 3, rules.explode_chance), "the fate roll is a pure function of its inputs")
		if r["fate"] == Unit.FATE_EXPLODED:
			exploded += 1
			eq(r["spin"], 0, "an exploded unit has no spin")
		else:
			eq(r["fate"], Unit.FATE_OUT_OF_CONTROL, "the other fate is out_of_control")
			spins[int(r["spin"])] += 1
	var frac := float(exploded) / 400.0
	check(absf(frac - rules.explode_chance) < 0.08, "about explode_chance of kills explode (%.3f of 400, chance %.2f)" % [frac, rules.explode_chance])
	check(spins[1] > 50 and spins[-1] > 50, "falls spin both ways (%d right, %d left)" % [spins[1], spins[-1]])
	for s in 50:
		eq(Combat.fate_roll(s, 1, 0, 3, 0.0)["fate"], Unit.FATE_OUT_OF_CONTROL, "chance 0: never explodes")
		eq(Combat.fate_roll(s, 1, 0, 3, 1.0)["fate"], Unit.FATE_EXPLODED, "chance 1: always explodes")
	# The same unit downed at another tick, another turn or another index rolls afresh.
	var diff := 0
	for s in 100:
		if Combat.fate_roll(s, 1, 0, 3, 0.5) != Combat.fate_roll(s, 1, 0, 4, 0.5):
			diff += 1
	check(diff > 20, "a different tick draws a different fate (%d of 100 differ)" % diff)

# One seed that gives each fate in the first turn, the bomber going down before the
# last tick (so where it went down is not where the turn ends).
func _find_seeds() -> Dictionary:
	var found := {}
	for s in range(1, 200):
		var w := _victim_world(s)
		var ev := _down_event(_turn(w))
		if ev.is_empty() or float(ev["t"]) > 4.9:
			continue
		if not found.has(ev["fate"]):
			found[ev["fate"]] = s
		if found.size() == 2:
			break
	check(found.has("exploded"), "a seed explodes the bomber (found: %s)" % str(found))
	check(found.has("out_of_control"), "a seed sends the bomber out of control (found: %s)" % str(found))
	print("  fate seeds: %s" % str(found))
	return found

# --- exploded ------------------------------------------------------------------------

func _exploded(seed_value: int, _rules: CombatRules) -> void:
	var w := _victim_world(seed_value)
	var client := _victim_world(seed_value)
	var res := _turn(w)
	_apply_and_compare(w, client, res, 1)
	var ev := _down_event(res)
	var u: Unit = w.units["bomber"]
	var t_star := float(ev["t"])
	eq(ev["fate"], "exploded", "the down event says it exploded")
	eq(u.fate, Unit.FATE_EXPLODED, "the unit's fate is exploded")
	check(u.down and u.health == 0, "it is down at 0 pips")
	near(u.down_at, t_star, 1e-12, "down_at is the event's t")
	check(not is_finite(u.fall_height_m) and u.fall_dir == 0, "an exploded unit is not falling")
	check(not (u.net_state() as Dictionary).has("fall_height_m"), "...so its net_state carries no fall height")
	# Gone where it was, at its height, at that t.
	var at := w.sample("bomber", t_star)
	near(float(ev["x"]), float(at["x"]), 1e-6, "the explosion is where the bomber was (x)")
	near(float(ev["y"]), float(at["y"]), 1e-6, "the explosion is where the bomber was (y)")
	near(float(ev["height_m"]), 1000.0, 1e-9, "...at its height (high, 1000 m)")
	near(u.x, float(at["x"]), 1e-6, "it ends the turn where it exploded (x)")
	near(u.y, float(at["y"]), 1e-6, "it ends the turn where it exploded (y)")
	near(u.speed, 0.0, 0.0, "it stops")
	var full: Dictionary = u.history[u.history.size() - 1]
	check(Vector2(float(full["x"]) - u.x, float(full["y"]) - u.y).length() > 5.0, "...not where its path would have carried it")
	var crashes := 0
	for e: Dictionary in res["events"]:
		if e["type"] == "crash":
			crashes += 1
	eq(crashes, 0, "an exploded unit does not crash")
	# Turn 2 and 3: it stays; nothing is fired at it or from it; no orders.
	var pos := Vector2(u.x, u.y)
	for n in 2:
		w.begin_turn()
		w.last_error = ""
		eq(w.plan_step("bomber", 0, {"turn": 0.1}), {}, "an exploded unit takes no orders")
		check(w.last_error.contains("down"), "...and says so: %s" % w.last_error)
		client.begin_turn()
		var r2 := _turn(w)
		_apply_and_compare(w, client, r2, w.turn)
		eq(Vector2(u.x, u.y), pos, "turn %d: the wreck has not moved" % w.turn)
		for h: Dictionary in u.history:
			check(Vector2(float(h["x"]), float(h["y"])) == pos and float(h["speed"]) == 0.0, "turn %d: its history sits still" % w.turn)
		for e: Dictionary in r2["events"]:
			check(e.get("unit") != "bomber" and e.get("target") != "bomber", "turn %d: no event concerns the exploded bomber (%s)" % [w.turn, e["type"]])
		check(is_nan(u.down_at) and u.fate == Unit.FATE_EXPLODED, "turn %d: down_at is NAN again, the fate stays" % w.turn)

# --- out of control -------------------------------------------------------------------

func _out_of_control(seed_value: int, rules: CombatRules) -> void:
	var host := _victim_world(seed_value)
	var client := _victim_world(seed_value)
	# A reference run of the same seed in which the bomber cannot die: the path
	# before it went down must not have moved.
	var ref := _victim_world(seed_value, 1000)
	var ref_res := _turn(ref)
	check(_down_event(ref_res).is_empty(), "the reference bomber, with 1000 pips, is not downed")

	var res := _turn(host)
	var ev := _down_event(res)
	var u: Unit = host.units["bomber"]
	var t_star := float(ev["t"])
	eq(ev["fate"], "out_of_control", "the down event says it lost control")
	eq(u.fate, Unit.FATE_OUT_OF_CONTROL, "the unit's fate is out_of_control")
	check(u.down and u.health == 0, "it is down at 0 pips")
	check(u.fall_dir == 1 or u.fall_dir == -1, "it spirals one way or the other (%d)" % u.fall_dir)
	var spin := u.fall_dir
	var descent := rules.fall_descent
	var fall_end := 1000.0 - descent * (5.0 - t_star)
	near(u.fall_height_m, fall_end, 1e-6, "after turn 1 it has fallen %.0f m a second since t = %.2f: %.1f m" % [descent, t_star, fall_end])

	# History: a state at t_star with the height it had; nothing before it moved.
	var c: Dictionary = {}
	for h: Dictionary in u.history:
		if absf(float(h["t"]) - t_star) < 1e-9:
			c = h
	if check(not c.is_empty() and c.has("fall_height_m"), "the history has a state at the moment it went down, carrying the fall height"):
		near(float(c["fall_height_m"]), 1000.0, 1e-6, "...which is the height it had (1000 m)")
	var moved_before := 0.0
	for i in range(1, 21):
		var t := 0.25 * float(i)
		if t >= t_star - 1e-9:
			break
		var a := host.sample("bomber", t)
		var b := ref.sample("bomber", t)
		moved_before = maxf(moved_before, maxf(absf(float(a["x"]) - float(b["x"])), absf(float(a["y"]) - float(b["y"]))))
		near(float(a["height_m"]), float(b["height_m"]), 1e-6, "before it went down the height is the reference's (t = %.2f)" % t)
	near(moved_before, 0.0, 1e-6, "nothing before it went down moved (largest difference to the reference %s m)" % moved_before)
	# After: the spiral. Heading turns at the data's rate in the roll's direction,
	# the speed gains up to the dive limit, the height falls.
	var last: Dictionary = u.history[u.history.size() - 1]
	var d := 5.0 - t_star
	if d > 0.01:
		near(_wrap(float(last["heading"]) - float(c["heading"])), float(spin) * rules.fall_turn_rate * d, 1e-6, "it turns %d x %.0f deg/s for %.2f s" % [spin, rules.fall_turn_rate_dps, d])
		near(float(last["speed"]), minf(float(c["speed"]) + rules.fall_speed_gain * d, u.def.envelope.dive_speed_max), 1e-6, "it gains speed (up to the dive limit)")
	near(float(host.sample("bomber", 5.0)["height_m"]), fall_end, 1e-6, "the sampler reports the fall height at the turn's end")
	check(float(host.sample("bomber", t_star)["height_m"]) > float(host.sample("bomber", 5.0)["height_m"]) or d < 0.01, "...and it is lower than it was when it went down")
	check(float(u.to_dict()["fall_height_m"]) == u.fall_height_m and u.to_dict()["fate"] == "out_of_control" and int(u.to_dict()["fall_dir"]) == spin, "to_dict carries fate, fall_height_m and fall_dir")

	# The client applies the host's result and matches it.
	var turn_no := 1
	var crash_turn := -1
	var crash_event: Dictionary = {}
	var end_heights: Array = [u.fall_height_m]
	var last_pos := Vector2(u.x, u.y)
	_apply_and_compare(host, client, res, turn_no)
	while turn_no < 12 and u.fate != Unit.FATE_CRASHED:
		host.begin_turn()
		client.begin_turn()
		turn_no += 1
		host.last_error = ""
		eq(host.plan_step("bomber", 0, {"turn": 0.1}), {}, "turn %d: an out-of-control unit takes no orders" % turn_no)
		eq(host.plan_step("bomber", 0, Vector2(2500.0, 2500.0)), {}, "turn %d: ...of either kind" % turn_no)
		var prev_height := u.fall_height_m
		var r := _turn(host)
		_apply_and_compare(host, client, r, turn_no)
		for e: Dictionary in r["events"]:
			if e["type"] == "crash":
				crash_event = e
				crash_turn = turn_no
			if e["type"] == "fire":
				check(e["target"] != "bomber" and e["unit"] != "bomber", "turn %d: nobody fires at or from the falling bomber" % turn_no)
			check(e["type"] != "down" or e["unit"] != "bomber", "turn %d: it does not go down twice" % turn_no)
		# It keeps moving and keeps falling, from where it was.
		near(float(host.sample("bomber", 0.0)["height_m"]), prev_height, 1e-6, "turn %d: the height is continuous from the last turn (%.1f m)" % [turn_no, prev_height])
		if crash_turn < 0:
			check(Vector2(u.x, u.y).distance_to(last_pos) > 100.0, "turn %d: it keeps moving (%.0f m)" % [turn_no, Vector2(u.x, u.y).distance_to(last_pos)])
			near(u.fall_height_m, prev_height - descent * 5.0, 1e-6, "turn %d: it loses %.0f m of height" % [turn_no, descent * 5.0])
			end_heights.append(u.fall_height_m)
			last_pos = Vector2(u.x, u.y)
	# Crash: from 1000 m at `descent` m/s it is on the ground 1000 / descent seconds
	# after it went down, i.e. in turn ceil((t_star + 1000/descent) / 5).
	var expect_turn := int(ceil((t_star + 1000.0 / descent) / 5.0 - 1e-9))
	eq(crash_turn, expect_turn, "it crashes in turn %d (%.1f s after going down: 1000 m at %.0f m/s)" % [expect_turn, 1000.0 / descent, descent])
	check(crash_turn > 1, "...a later turn than the one it went down in")
	if not crash_event.is_empty():
		var t_in_turn := t_star + 1000.0 / descent - 5.0 * float(crash_turn - 1)
		near(float(crash_event["t"]), t_in_turn, 1e-6, "the crash event's t is when the height reaches 0")
		eq(crash_event["unit"], "bomber", "the crash event names the unit")
		near(float(crash_event["x"]), u.x, 1e-6, "it ends the crash turn where it crashed (x)")
		near(float(crash_event["y"]), u.y, 1e-6, "it ends the crash turn where it crashed (y)")
		check(crash_event.has("turn") and crash_event["turn"] == crash_turn, "the crash event carries its turn")
	eq(u.fate, Unit.FATE_CRASHED, "its fate is now crashed")
	check(u.down and u.fall_height_m == 0.0 and u.speed == 0.0 and u.fall_dir == 0, "crashed: on the ground, stopped, no longer spiralling")
	# Afterwards it is a wreck: still, no events.
	var pos := Vector2(u.x, u.y)
	for n in 2:
		host.begin_turn()
		client.begin_turn()
		var r2 := _turn(host)
		_apply_and_compare(host, client, r2, host.turn)
		eq(Vector2(u.x, u.y), pos, "turn %d: the crashed wreck has not moved" % host.turn)
		for e: Dictionary in r2["events"]:
			check(e["type"] != "crash" and e.get("unit") != "bomber" and e.get("target") != "bomber", "turn %d: no event concerns the crashed bomber (%s)" % [host.turn, e["type"]])
		near(float(host.sample("bomber", 2.0)["height_m"]), 0.0, 1e-9, "turn %d: a wreck is on the ground" % host.turn)
	print("  out of control: spin %d, down at t = %.2f, crashed in turn %d at t = %.2f (heights at turn ends %s)" % [spin, t_star, crash_turn, float(crash_event.get("t", NAN)), str(end_heights.map(func(h: float) -> float: return snappedf(h, 0.1)))])

# The client applies the host's result for this turn and every unit matches:
# state (NaN-aware, fall height included), history, health, fate, and the events.
func _apply_and_compare(host: World, client: World, res: Dictionary, turn_no: int) -> void:
	var got: Array = []
	var cb := func(_t: int, _h: Dictionary, e: Array) -> void: got.append(e)
	client.turn_resolved.connect(cb)
	check(client.apply_resolution(res), "turn %d: the client applies the host's result: %s" % [turn_no, client.last_error])
	client.turn_resolved.disconnect(cb)
	for id: String in host.units:
		var hu: Unit = host.units[id]
		var cu: Unit = client.units[id]
		check(_same(hu.net_state(), cu.net_state()), "turn %d, %s: the client's net_state matches the host's: host %s, client %s" % [turn_no, id, str(hu.net_state()), str(cu.net_state())])
		check(_same(hu.history, cu.history), "turn %d, %s: ...and its history" % [turn_no, id])
		check(hu.fate == cu.fate and _same(hu.fall_height_m, cu.fall_height_m) and hu.fall_dir == cu.fall_dir, "turn %d, %s: ...fate, fall height and spin" % [turn_no, id])
	check(got.size() == 1 and _same(got[0], res["events"]), "turn %d: the client's events are the host's" % turn_no)

# --- the history of a fall, over many seeds ----------------------------------------------

# Light fighters as the victim, so the moment it went down is sometimes exactly on a
# step boundary (a step is 1 s, a kill roll is on every half second) and sometimes
# between two: the inserted state, or not. Whichever, the history is in order and
# complete, the fall is continuous with the flight, and nothing before moved.
func _history_sanity(rules: CombatRules) -> void:
	var falls := 0
	var on_boundary := 0
	var between := 0
	for s in range(1, 80):
		var w := _victim_world(s, 1, "light_fighter")
		var res := _turn(w)
		var ev := _down_event(res)
		if ev.is_empty() or ev["fate"] != "out_of_control":
			continue
		falls += 1
		var u: Unit = w.units["bomber"]
		var t_star := float(ev["t"])
		var h: Array = u.history
		var ref := _victim_world(s, 1000, "light_fighter")
		_turn(ref)
		var states_at := 0
		var ok_order := true
		var ok_fall := true
		for i in h.size():
			if i > 0:
				ok_order = ok_order and float(h[i]["t"]) > float(h[i - 1]["t"])
			if absf(float(h[i]["t"]) - t_star) < 1e-9:
				states_at += 1
			var falling: bool = h[i].has("fall_height_m")
			if falling != (float(h[i]["t"]) >= t_star - 1e-9):
				ok_fall = false
			if i > 0 and falling and h[i - 1].has("fall_height_m"):
				if absf((float(h[i - 1]["fall_height_m"]) - float(h[i]["fall_height_m"])) - rules.fall_descent * (float(h[i]["t"]) - float(h[i - 1]["t"]))) > 1e-6:
					ok_fall = false
		check(ok_order, "seed %d: the history's times strictly increase" % s)
		eq(states_at, 1, "seed %d: exactly one state at the moment it went down (t = %.2f)" % [s, t_star])
		check(ok_fall, "seed %d: exactly the states from t = %.2f on are falling, each %.0f m a second lower" % [s, t_star, rules.fall_descent])
		near(float(h[h.size() - 1]["t"]), 5.0, 1e-12, "seed %d: the history still ends with the turn" % s)
		var is_boundary: bool = absf(t_star - roundf(t_star)) < 1e-9
		eq(h.size(), 6 if is_boundary else 7, "seed %d: %s, so %s states" % [s, "t is a step boundary" if is_boundary else "t is inside a step", "6" if is_boundary else "7"])
		if is_boundary:
			on_boundary += 1
		else:
			between += 1
		# Continuous with the flight: position and height either side of t_star.
		var a := w.sample("bomber", t_star - 1e-6)
		var b := w.sample("bomber", t_star + 1e-6)
		check(Vector2(float(a["x"]) - float(b["x"]), float(a["y"]) - float(b["y"])).length() < 0.01, "seed %d: the position is continuous through t = %.2f" % [s, t_star])
		check(absf(float(a["height_m"]) - float(b["height_m"])) < 0.01, "seed %d: ...and the height" % s)
		# Nothing before it went down moved.
		var worst := 0.0
		var t := 0.1
		while t < t_star - 1e-6:
			var p := w.sample("bomber", t)
			var q := ref.sample("bomber", t)
			worst = maxf(worst, Vector2(float(p["x"]) - float(q["x"]), float(p["y"]) - float(q["y"])).length())
			t += 0.1
		check(worst < 1e-6, "seed %d: the path before t = %.2f is the one it was flying (largest difference %s m)" % [s, t_star, str(worst)])
	check(falls >= 10, "enough falls to look at (%d)" % falls)
	check(on_boundary >= 1 and between >= 1, "both a kill on a step boundary (%d) and one inside a step (%d) were covered" % [on_boundary, between])

# A victim in the low band (120 m) hits the ground 2.4 s after it goes down: the
# crash is in the same turn when it went down before t = 2.6, else in the next.
func _low_crash(rules: CombatRules) -> void:
	var drop := 120.0 / rules.fall_descent
	var same_turn := 0
	var next_turn := 0
	for s in range(1, 120):
		var w := _victim_world(s, 1, "light_fighter", "low")
		var res := _turn(w)
		var ev := _down_event(res)
		if ev.is_empty() or ev["fate"] != "out_of_control":
			continue
		var u: Unit = w.units["bomber"]
		var t_star := float(ev["t"])
		var crashes: Array = res["events"].filter(func(e: Dictionary) -> bool: return e["type"] == "crash")
		if t_star + drop <= 5.0 + 1e-9:
			same_turn += 1
			if not check(crashes.size() == 1, "seed %d: down at t = %.2f, it reaches the ground at t = %.2f, in the same turn" % [s, t_star, t_star + drop]):
				continue
			near(float(crashes[0]["t"]), t_star + drop, 1e-6, "seed %d: the crash is %.1f s after the kill" % [s, drop])
			eq(u.fate, Unit.FATE_CRASHED, "seed %d: crashed within the turn" % s)
			check(u.down and u.fall_height_m == 0.0 and u.speed == 0.0, "seed %d: on the ground, stopped" % s)
			near(u.x, float(crashes[0]["x"]), 1e-6, "seed %d: it ends the turn where it crashed" % s)
			# The down event comes before the crash event, in the one time-ordered list.
			var order: Array = []
			for e: Dictionary in res["events"]:
				if e["type"] == "down" or e["type"] == "crash":
					order.append(e["type"])
			eq(order, ["down", "crash"], "seed %d: events in time order: down, then crash" % s)
		else:
			next_turn += 1
			eq(crashes.size(), 0, "seed %d: down at t = %.2f, it is still falling at the turn's end" % [s, t_star])
			eq(u.fate, Unit.FATE_OUT_OF_CONTROL, "seed %d: still out of control" % s)
			w.begin_turn()
			var res2 := _turn(w)
			var crashes2: Array = res2["events"].filter(func(e: Dictionary) -> bool: return e["type"] == "crash")
			eq(crashes2.size(), 1, "seed %d: it crashes in the next turn" % s)
			if crashes2.size() == 1:
				near(float(crashes2[0]["t"]), t_star + drop - 5.0, 1e-6, "seed %d: at t = %.2f of turn 2" % [s, t_star + drop - 5.0])
	check(same_turn >= 1 and next_turn >= 1, "both a crash in the turn of the kill (%d) and one in the next (%d) were covered" % [same_turn, next_turn])
