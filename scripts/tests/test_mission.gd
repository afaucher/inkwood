extends "res://scripts/test_support/test_case.gd"

# THE MISSION RULES (Track E, scripts/sim/mission.gd): the Intercept mission as
# data. Won when the bomber is down; lost when it comes within the target
# radius at ANY sampled time of a turn (not only at its end) or when every
# player unit is down; otherwise playing. The order of a turn's events decides a
# turn in which both hold, a result is sticky, a bad spec is reported, and a
# client that applied the host's resolution reaches the host's verdict.
#
# Combat is Track C's; this test marks units down by hand (Unit.down, down_at)
# exactly as a resolve would, so it keeps working however combat is tuned.

const World = preload("res://scripts/sim/world.gd")
const Mission = preload("res://scripts/sim/mission.gd")

const TARGET := [3600.0, 3900.0]
const RADIUS := 300.0

func setup(_main) -> void:
	_playing()
	_won()
	_lost_by_reaching_the_target()
	_lost_by_a_pass_between_samples()
	_lost_when_all_players_are_down()
	_order_within_a_turn()
	_sticky_and_signal()
	_attach_and_client()
	_spec_errors()
	_vocabulary()
	_turn_limit_and_strike()
	finish()

# Two player fighters far from everything, an AI bomber (and its id "bomber_1")
# flying straight east from the given point.
func _world(bomber_x := 1000.0, bomber_y := 2500.0, bomber_heading := 0.0) -> World:
	var w := World.new()
	check(w.ok(), "the world's data loads: %s" % str(w.errors))
	w.add_player("local")
	eq(w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 300.0, "y": 4600.0, "heading": 0.0}), "p1", "player 1 added")
	eq(w.add_unit({"id": "p2", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 300.0, "y": 4750.0, "heading": 0.0}), "p2", "player 2 added")
	eq(w.add_unit({"id": "bomber_1", "type": "bomber", "side": "axis", "controller": "ai", "x": bomber_x, "y": bomber_y, "heading": bomber_heading}), "bomber_1", "the bomber added")
	return w

# One turn with nobody planning anything: everyone carries on.
func _turn(w: World) -> Dictionary:
	w.commit("local")
	w.commit(World.AI_PLAYER)
	var res := w.resolve()
	check(not res.is_empty(), "the turn resolves: %s" % w.last_error)
	return res

func _mission(w: World, target: Array = TARGET, radius := RADIUS) -> Mission:
	var m := Mission.new(w, Mission.intercept("bomber_1", target, radius))
	check(m.ok(), "the Intercept mission is valid: %s" % str(m.errors))
	return m

func _playing() -> void:
	var w := _world()
	var m := _mission(w)
	var res := _turn(w)
	var r := m.evaluate(res)
	eq(r["state"], Mission.PLAYING, "nothing has happened: playing")
	eq(r["turn"], 1, "the verdict names the turn")
	eq(m.state, Mission.PLAYING, "the mission's own state agrees")
	# A bomber that is hurt but not down, a player down but not both: still playing.
	w.units["p1"].down = true
	w.units["p1"].down_at = 1.0
	w.units["bomber_1"].health = 1
	eq(m.evaluate(res)["state"], Mission.PLAYING, "one player down and the bomber hurt: still playing")

func _won() -> void:
	var w := _world()
	var m := _mission(w)
	var res := _turn(w)
	var b: Variant = w.units["bomber_1"]
	b.down = true
	b.down_at = 2.0
	var r := m.evaluate(res)
	eq(r["state"], Mission.WON, "the bomber went down this turn: won")
	check(str(r["reason"]).contains("bomber_1"), "the reason names the bomber: %s" % r["reason"])
	near(float(r["t"]), 2.0, 1e-9, "and the moment it went down")
	eq(r["turn"], 1, "on turn 1")
	# Down in an earlier turn (down_at is NAN in the turn after): still a win, at t = 0.
	var w2 := _world()
	var m2 := _mission(w2)
	w2.units["bomber_1"].down = true
	w2.units["bomber_1"].down_at = NAN
	var r2 := m2.evaluate({"turn": 4})
	eq(r2["state"], Mission.WON, "a bomber already down is a win")
	eq(r2["turn"], 4, "the result's turn is the one passed in")
	near(float(r2["t"]), 0.0, 1e-9, "counted from the start of the turn")

func _lost_by_reaching_the_target() -> void:
	# The bomber starts a turn's flight from the target: it flies 425 m east and
	# ends 25 m past it.
	var w := _world(3600.0 - 400.0, 3900.0)
	var m := _mission(w)
	var res := _turn(w)
	var u: Variant = w.units["bomber_1"]
	check(Vector2(u.x - TARGET[0], u.y - TARGET[1]).length() <= RADIUS, "the scenario: it ended inside the radius (%.0f m)" % Vector2(u.x - TARGET[0], u.y - TARGET[1]).length())
	var r := m.evaluate(res)
	eq(r["state"], Mission.LOST, "the bomber reached the target: lost")
	check(str(r["reason"]).contains("bomber_1") and str(r["reason"]).contains("target"), "the reason says so: %s" % r["reason"])

# The bomber crosses the target's circle in the MIDDLE of a turn and ends it well
# outside; no step end is inside the circle either. Only the fine sampling sees it.
func _lost_by_a_pass_between_samples() -> void:
	var w := _world(1000.0, 2500.0, 0.0)
	var target := [1212.5, 2600.0]
	var radius := 110.0
	var m := _mission(w, target, radius)
	var res := _turn(w)
	var u: Variant = w.units["bomber_1"]
	var h: Array = u.history
	var nearest_step := INF
	for s: Dictionary in h:
		nearest_step = minf(nearest_step, Vector2(float(s["x"]) - target[0], float(s["y"]) - target[1]).length())
	check(nearest_step > radius, "the scenario: no step state is inside the radius (nearest %.0f m)" % nearest_step)
	check(Vector2(u.x - target[0], u.y - target[1]).length() > radius, "the scenario: the turn ends outside the radius")
	var r := m.evaluate(res)
	eq(r["state"], Mission.LOST, "crossing the circle mid-turn is reaching the target")
	check(float(r["t"]) > 1.0 and float(r["t"]) < 4.0, "and it is dated mid-turn (t = %.2f s)" % float(r["t"]))
	# A pass that stays outside the circle is not.
	var w2 := _world(1000.0, 2500.0, 0.0)
	var m2 := _mission(w2, [1212.5, 2700.0], radius)
	eq(m2.evaluate(_turn(w2))["state"], Mission.PLAYING, "a pass 200 m off, radius 110: playing")

func _lost_when_all_players_are_down() -> void:
	var w := _world()
	var m := _mission(w)
	var res := _turn(w)
	w.units["p1"].down = true
	w.units["p1"].down_at = 1.5
	eq(m.evaluate(res)["state"], Mission.PLAYING, "one of two down: playing")
	w.units["p2"].down = true
	w.units["p2"].down_at = 3.0
	var r := m.evaluate(res)
	eq(r["state"], Mission.LOST, "both down: lost")
	check(str(r["reason"]).contains("player"), "the reason says the players are down: %s" % r["reason"])
	near(float(r["t"]), 3.0, 1e-9, "dated by the last one to go")

# A win and a loss in the same turn: whichever came first in the turn decides; a
# tie goes to the players (proposed).
func _order_within_a_turn() -> void:
	# The bomber crosses the target's circle around t = 2.5 s.
	var target := [1212.5, 2600.0]
	var cases: Array = [
		# [bomber down_at, expected state, why]
		[1.0, Mission.WON, "shot down at 1 s, before reaching the target"],
		[4.0, Mission.LOST, "over the target at 2.5 s, shot down at 4 s: it dropped its bomb"],
	]
	for c: Array in cases:
		var w := _world(1000.0, 2500.0, 0.0)
		var m := _mission(w, target, 110.0)
		var res := _turn(w)
		w.units["bomber_1"].down = true
		w.units["bomber_1"].down_at = float(c[0])
		eq(m.evaluate(res)["state"], c[1], str(c[2]))
	# Players all down at 3 s against the bomber down at 3 s: a tie; the players win it.
	var w3 := _world()
	var m3 := _mission(w3)
	var res3 := _turn(w3)
	for id in ["p1", "p2"]:
		w3.units[id].down = true
		w3.units[id].down_at = 3.0
	w3.units["bomber_1"].down = true
	w3.units["bomber_1"].down_at = 3.0
	eq(m3.evaluate(res3)["state"], Mission.WON, "an exact tie is the players'")
	# Players all down at 2 s, the bomber at 3 s: lost.
	var w4 := _world()
	var m4 := _mission(w4)
	var res4 := _turn(w4)
	for id in ["p1", "p2"]:
		w4.units[id].down = true
		w4.units[id].down_at = 2.0
	w4.units["bomber_1"].down = true
	w4.units["bomber_1"].down_at = 3.0
	eq(m4.evaluate(res4)["state"], Mission.LOST, "the players were all down first: lost")

func _sticky_and_signal() -> void:
	var w := _world()
	var m := _mission(w)
	var seen: Array = []
	m.state_changed.connect(func(s: String, why: String, t: int) -> void: seen.append([s, why, t]))
	var res := _turn(w)
	m.evaluate(res)
	eq(seen.size(), 0, "no signal while playing")
	w.units["bomber_1"].down = true
	w.units["bomber_1"].down_at = 2.0
	m.evaluate(res)
	eq(seen.size(), 1, "one signal when it ends")
	eq(seen[0][0], Mission.WON, "...saying won")
	# Whatever happens later, the result stays.
	w.units["bomber_1"].down = false
	w.units["p1"].down = true
	w.units["p2"].down = true
	var r := m.evaluate({"turn": 9})
	eq(r["state"], Mission.WON, "a decided mission stays decided")
	eq(r["turn"], 1, "with its own turn")
	eq(seen.size(), 1, "and does not signal again")

# attach(): the mission evaluates itself after every resolve the world announces,
# a client's applied resolution included, and reaches the host's verdict.
func _attach_and_client() -> void:
	var host := _world()
	var client := _world()
	var hm := _mission(host)
	var cm := _mission(client)
	hm.attach()
	cm.attach()
	# Turn 1: nothing happens on either.
	var res1 := _turn(host)
	eq(hm.state, Mission.PLAYING, "the host's mission evaluated itself after the resolve: playing")
	check(client.apply_resolution(res1), "the client applies turn 1: %s" % client.last_error)
	eq(cm.state, Mission.PLAYING, "the client's mission evaluated itself on the applied resolution: playing")
	host.begin_turn()
	client.begin_turn()
	# Turn 2: the host resolves; combat (Track C) would mark the bomber down in the
	# result, which the host evaluates and sends to the client.
	var res2 := _turn(host)
	host.units["bomber_1"].down = true
	host.units["bomber_1"].down_at = 3.5
	eq(hm.evaluate(res2)["state"], Mission.WON, "the host: the bomber is down, won")
	var sent := res2.duplicate(true)
	(sent["units"] as Dictionary)["bomber_1"]["down"] = true
	(sent["units"] as Dictionary)["bomber_1"]["down_at"] = 3.5
	check(client.apply_resolution(sent), "the client applies turn 2: %s" % client.last_error)
	eq(cm.state, Mission.WON, "the client reaches the host's verdict from the applied resolution alone")
	eq(cm.turn, hm.turn, "on the same turn")
	near(cm.time, hm.time, 1e-9, "at the same moment")

func _spec_errors() -> void:
	var w := _world()
	var bad_specs: Array = [
		["an unknown unit", {"win": [{"type": "unit_down", "unit": "ghost"}], "lose": []}],
		["an unknown condition type", {"win": [{"type": "flag_captured"}], "lose": []}],
		["'of' target with no target point", {"win": [], "lose": [{"type": "unit_within", "unit": "bomber_1", "of": "target"}]}],
		["a radius that is not positive", {"target": [1.0, 1.0], "win": [], "lose": [{"type": "unit_within", "unit": "bomber_1", "of": "target", "radius_m": -5}]}],
		["all_down with no selector", {"win": [], "lose": [{"type": "all_down"}]}],
		["all_down with two selectors", {"win": [], "lose": [{"type": "all_down", "controller": "player", "side": "allies"}]}],
		["no win list", {"lose": [{"type": "unit_down", "unit": "bomber_1"}]}],
		["no conditions at all", {"win": [], "lose": []}],
		["a target that is not a point", {"target": "the harbour", "win": [{"type": "unit_down", "unit": "bomber_1"}], "lose": []}],
	]
	for c: Array in bad_specs:
		var m := Mission.new(w, c[1], "res://data/sim/ai.json", true)
		check(not m.ok(), "a spec with %s is refused" % c[0])
		eq(m.evaluate({"turn": 1})["state"], Mission.PLAYING, "and a refused mission never ends (%s)" % c[0])
	check(Mission.new(w, Mission.intercept("bomber_1", TARGET, RADIUS), "res://data/sim/ai.json", true).ok(), "the Intercept spec is accepted")

# The vocabulary beyond Intercept's own shape: a hand-written spec, units named
# by list or side, a point given inline.
func _vocabulary() -> void:
	var w := _world(1000.0, 2500.0, 0.0)
	var spec := {
		"id": "hand_written",
		"win": [{"type": "all_down", "side": "axis"}],
		"lose": [
			{"type": "all_down", "units": ["p1"]},
			{"type": "unit_within", "unit": "bomber_1", "of": [1212.5, 2600.0], "radius_m": 110},
		],
	}
	var m := Mission.new(w, spec)
	check(m.ok(), "a hand-written spec is valid: %s" % str(m.errors))
	var res := _turn(w)
	eq(m.evaluate(res)["state"], Mission.LOST, "an inline point works as well as \"target\"")
	var m2 := Mission.new(_world(), {"win": [{"type": "all_down", "side": "axis"}], "lose": [{"type": "all_down", "units": ["p1"]}]})
	var w2 := m2.world
	eq(m2.evaluate(_turn(w2))["state"], Mission.PLAYING, "all_down by side: not yet")
	w2.units["bomber_1"].down = true
	w2.units["bomber_1"].down_at = NAN
	eq(m2.evaluate({"turn": 2})["state"], Mission.WON, "all_down by side: the axis side is just the bomber")
	# The empty set is never "all down".
	var m3 := Mission.new(_world(), {"win": [{"type": "all_down", "side": "nobody"}], "lose": [{"type": "unit_down", "unit": "p1"}]})
	eq(m3.evaluate({"turn": 1})["state"], Mission.PLAYING, "an empty side is not 'all down'")

# --- The turn limit and the Strike (Track S2, 2026-10-10) ---------------------------------------------
#
# Alex's strike-plan: "win when the target is destroyed, lose when the bomber is down or at a turn limit".
# The target is a static ground unit and goes down with the fate "destroyed" like any unit goes down; the
# turn limit is a lose condition that holds at the END of turn n.

func _strike_world() -> World:
	var w := World.new()
	check(w.ok(), "the world's data loads: %s" % str(w.errors))
	w.add_player("local")
	w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": 2500.0, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
	w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	return w

func _strike_turn(w: World) -> Dictionary:
	w.commit("local")
	var res := w.resolve()
	check(not res.is_empty(), "the turn resolves: %s" % w.last_error)
	return res

func _turn_limit_and_strike() -> void:
	var spec := Mission.strike("tower", "bomber", 3)
	var w := _strike_world()
	var m := Mission.new(w, spec)
	check(m.ok(), "the Strike spec is valid: %s" % str(m.errors))
	eq(spec["win"], [{"type": "unit_down", "unit": "tower"}], "won when the tower is down")
	eq((spec["lose"] as Array).size(), 2, "lost two ways")
	# Turns 1 and 2: nothing has happened, the limit is 3.
	for turn_no in 2:
		var res := _strike_turn(w)
		eq(m.evaluate(res)["state"], Mission.PLAYING, "turn %d of a 3-turn limit: playing" % w.turn)
		w.begin_turn()
	# The end of turn 3: lost, at the end of the turn.
	var res3 := _strike_turn(w)
	var r := m.evaluate(res3)
	eq(r["state"], Mission.LOST, "the end of turn 3 with the tower standing: lost")
	check(str(r["reason"]).contains("3"), "the reason names the limit: %s" % r["reason"])
	near(float(r["t"]), w.rules.turn_seconds, 1e-9, "at the end of the turn")
	eq(r["turn"], 3, "on turn 3")
	# A win earlier in the turn the limit falls in beats it.
	var w2 := _strike_world()
	var m2 := Mission.new(w2, Mission.strike("tower", "bomber", 1))
	var res := _strike_turn(w2)
	w2.units["tower"].down = true
	w2.units["tower"].down_at = 3.2
	w2.units["tower"].fate = "destroyed"
	var r2 := m2.evaluate(res)
	eq(r2["state"], Mission.WON, "the tower destroyed at 3.2 s of the last turn: won, not lost to the limit")
	near(float(r2["t"]), 3.2, 1e-9, "at that moment")
	# The bomber down earlier in the turn than the tower: lost to the bomber.
	var w3 := _strike_world()
	var m3 := Mission.new(w3, Mission.strike("tower", "bomber", 10))
	var res3b := _strike_turn(w3)
	w3.units["tower"].down = true
	w3.units["tower"].down_at = 4.0
	w3.units["bomber"].down = true
	w3.units["bomber"].down_at = 1.5
	var r3 := m3.evaluate(res3b)
	eq(r3["state"], Mission.LOST, "the bomber down at 1.5 s, the tower at 4.0 s: lost")
	check(str(r3["reason"]).contains("bomber"), "because of the bomber: %s" % r3["reason"])
	# The bomber down on its own (no tower yet): lost at once, long before the limit.
	var w4 := _strike_world()
	var m4 := Mission.new(w4, Mission.strike("tower", "bomber", 10))
	var res4 := _strike_turn(w4)
	w4.units["bomber"].down = true
	w4.units["bomber"].down_at = 2.0
	eq(m4.evaluate(res4)["state"], Mission.LOST, "a bomber down loses the strike whatever the turn")
	# Sticky: after the limit, a late win does not undo it.
	w.units["tower"].down = true
	w.units["tower"].down_at = NAN
	eq(m.evaluate({"turn": 4})["state"], Mission.LOST, "a result is sticky: the limit is not undone by a tower falling later")
	# A mission evaluated late (turn 5 of a 3-turn limit) is still lost to the limit.
	var w5 := _strike_world()
	var m5 := Mission.new(w5, Mission.strike("tower", "bomber", 3))
	eq(m5.evaluate({"turn": 5})["state"], Mission.LOST, "evaluated after the limit it still holds")
	# A client that applied the host's results reaches the host's verdict, the limit included.
	var host := _strike_world()
	var client := _strike_world()
	var mh := Mission.new(host, Mission.strike("tower", "bomber", 2))
	var mc := Mission.new(client, Mission.strike("tower", "bomber", 2))
	mh.attach()
	mc.attach()
	for turn_no in 2:
		var hr := _strike_turn(host)
		check(client.apply_resolution(hr), "the client applies turn %d: %s" % [host.turn, client.last_error])
		host.begin_turn()
		client.begin_turn()
	eq(mh.state, Mission.LOST, "the host's mission is lost at the limit")
	eq(mc.state, mh.state, "and the client's agrees")
	eq(mc.reason, mh.reason, "with the same reason")
	# Bad specs: the limit must be a whole number of turns, 1 or more.
	for bad: Variant in [0, -3, 2.5, "ten", null]:
		var spec_bad := {"win": [{"type": "unit_down", "unit": "tower"}], "lose": [{"type": "turn_limit", "turn": bad}]}
		check(not Mission.new(_strike_world(), spec_bad, "res://data/sim/ai.json", true).ok(), "a turn limit of %s is refused" % str(bad))
	var no_turn := {"win": [{"type": "unit_down", "unit": "tower"}], "lose": [{"type": "turn_limit"}]}
	check(not Mission.new(_strike_world(), no_turn, "res://data/sim/ai.json", true).ok(), "a turn limit with no turn is refused")
	check(Mission.TYPES.has(Mission.TYPE_TURN_LIMIT), "the vocabulary lists turn_limit")
