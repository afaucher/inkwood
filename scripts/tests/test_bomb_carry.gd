extends "res://scripts/test_support/test_case.gd"

# THE BOMB LOAD AND THE BOMBS IN FLIGHT (Track S2, the strike, 2026-10-10; scripts/sim/bombs.gd):
#
#   - a drop is a special taken in a step: the request carries {"drop": {"aim": [x, y]}}; a bad one is refused,
#     a unit with no bombs is refused, and no more drops are accepted than the unit has left
#   - bombs_left counts down as the bomber lets its sticks go, one drop at a time
#   - a drop planned and then left with no load to drop is not released; a bomber that is down before its
#     release moment does not release; one that was up at it does, and its bombs land whatever happens to it
#   - a bomb still falling at the end of the turn is carried to the turn it lands in (a high drop falls three
#     turns), on the host and on a client that only applies the host's result, bit for bit, and a snapshot
#     of the bombs in flight hands a joining client the same
#   - where a bomb is at a moment (Bombs.bomb_position), for the effects

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")

func setup(_main) -> void:
	timeout_seconds = 120.0
	_requests()
	_load_counts_down()
	_load_spent_after_planning()
	_down_before_release()
	_carried_across_turns()
	_unit_state()
	finish()

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

# The bomber placed so its step 0 releases a stick that lands on the tower: ideal at the middle of the step.
func _on_the_run(w: World, band: String) -> void:
	var u: Unit = w.units["bomber"]
	u.x = BombWorlds.TOWER.x - 85.0 * 0.5 * w.step_dt("bomber") - Bombs.ideal_range(85.0, w.band_height(band), w.bombs.gravity)

func _ideal(w: World, k: int = 0) -> Vector2:
	return w.drop_cone("bomber", k)["ideal_aim"]

# --- The request ------------------------------------------------------------------------------------------

func _requests() -> void:
	var w := BombWorlds.world(1, "medium")
	var aim := _ideal(w)
	var st := w.plan_step("bomber", 0, {"turn": 0.1, "speed": 85.0, "drop": {"aim": [aim.x, aim.y]}})
	check(not st.is_empty(), "a drop with a manoeuvre is planned: %s" % w.last_error)
	check(st.has("drop") and st["drop"]["ok"] == true, "the step's state carries the drop's analysis")
	near(float(st["turn"]), 0.1, 1e-9, "and the step is flown as asked")
	check(not w.plan_step("bomber", 1, {"drop": {"aim": aim}}).is_empty(), "an aim may be a Vector2")
	eq(w.bombs_left("bomber")["planned"], 2, "two drops are planned")
	# Every kind of bad request is refused and leaves the plan alone.
	var before: Array = (w.units["bomber"].plan as Array).duplicate(true)
	var bad: Array = [
		["a drop that is not an object", {"drop": 5}],
		["a drop with no aim", {"drop": {}}],
		["an aim with one number", {"drop": {"aim": [1.0]}}],
		["an aim that is a string", {"drop": {"aim": "there"}}],
		["an infinite aim", {"drop": {"aim": [INF, 0.0]}}],
		["a NaN aim", {"drop": {"aim": [NAN, 0.0]}}],
	]
	for c: Array in bad:
		w.last_error = ""
		eq(w.plan_step("bomber", 2, c[1]), {}, "refused: %s" % c[0])
		check(w.last_error.contains("drop"), "...and it says why: %s" % w.last_error)
	eq(w.units["bomber"].plan, before, "the plan is untouched by the refusals")
	# A unit that carries no bombs.
	var f := World.new()
	f.quiet = true
	f.add_unit({"id": "f", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 2500.0, "heading": 0.0})
	eq(f.plan_step("f", 0, {"drop": {"aim": [2000.0, 2500.0]}}), {}, "a fighter cannot drop")
	check(f.last_error.contains("no bombs"), "...it carries no bombs: %s" % f.last_error)
	eq(f.units["f"].plan.size(), 0, "and nothing was planned")
	# The envelope itself ignores a drop (it is a special, not a manoeuvre): the same step with and without one.
	var a := BombWorlds.world(1, "medium")
	var b := BombWorlds.world(1, "medium")
	var sa := a.plan_step("bomber", 0, {"turn": 0.2, "speed": 90.0})
	var sb := b.plan_step("bomber", 0, {"turn": 0.2, "speed": 90.0, "drop": {"aim": [2000.0, 2500.0]}})
	for k: String in ["x", "y", "heading", "speed", "altitude_band", "turn", "clamped"]:
		eq(sa[k], sb[k], "a drop changes nothing about how the step is flown (%s)" % k)

# --- The load counts down ---------------------------------------------------------------------------------------------

func _load_counts_down() -> void:
	var w := BombWorlds.world(2, "low")
	var u: Unit = w.units["bomber"]
	var total: int = u.def.bomb_drops
	var per: int = u.def.bomb_per_drop
	check(total >= 2, "the bomber has at least two drops (Alex): %d" % total)
	check(per >= 1, "and bombs in each: %d" % per)
	eq(w.bombs_left("bomber"), {"drops_left": total, "drops_max": total, "drops_total": total, "per_drop": per, "planned": 0, "carries": true}, "a full load")
	eq(w.bombs_left("tower")["carries"], false, "a tower carries nothing")
	var drop_indexes: Array[int] = []
	var bombs_dropped := 0
	for turn_no in total:
		var aim := _ideal(w, 0)
		check(not w.plan_step("bomber", 0, {"drop": {"aim": [aim.x, aim.y]}}).is_empty(), "turn %d: a drop is planned (drops left %d)" % [w.turn, u.drops_left])
		eq(w.bombs_left("bomber")["planned"], 1, "...one planned")
		var res := BombWorlds.turn(w)
		for ev: Dictionary in BombWorlds.events_of(res, "bomb_release", "bomber"):
			drop_indexes.append(int(ev["drop_index"]))
			bombs_dropped += int(ev["bombs"])
		eq(u.drops_left, total - turn_no - 1, "turn %d: %d drops left" % [w.turn, total - turn_no - 1])
		eq(w.bombs_left("bomber")["drops_left"], total - turn_no - 1, "...and bombs_left agrees")
		w.begin_turn()
	eq(drop_indexes, [0, 1, 2] as Array[int] if total == 3 else range(total) as Array[int], "the drops are numbered in order")
	eq(bombs_dropped, total * per, "every bomb of the load was dropped")
	# None left: refused.
	w.last_error = ""
	var aim := _ideal(w, 0)
	eq(w.plan_step("bomber", 0, {"drop": {"aim": [aim.x, aim.y]}}), {}, "with no drops left a drop is refused")
	check(w.last_error.contains("0 drop"), "...saying so: %s" % w.last_error)
	eq(w.bombs_left("bomber")["drops_left"], 0, "nothing left")
	# Within one turn: no more than the unit has left; replacing a step's drop does not count twice.
	var w2 := BombWorlds.world(2, "low")
	var u2: Unit = w2.units["bomber"]
	u2.drops_left = 2
	var a2 := _ideal(w2, 0)
	check(not w2.plan_step("bomber", 0, {"drop": {"aim": [a2.x, a2.y]}}).is_empty(), "the first of two drops left")
	check(not w2.plan_step("bomber", 0, {"drop": {"aim": [a2.x + 5.0, a2.y]}}).is_empty(), "the same step again is a replacement, not a second drop")
	check(not w2.plan_step("bomber", 1, {"drop": {"aim": [a2.x, a2.y]}}).is_empty(), "the second of two")
	w2.last_error = ""
	eq(w2.plan_step("bomber", 2, {"drop": {"aim": [a2.x, a2.y]}}), {}, "a third is refused")
	check(w2.last_error.contains("2 drop"), "...saying how many it has: %s" % w2.last_error)
	eq(w2.bombs_left("bomber")["planned"], 2, "two planned, not three")
	check(not w2.plan_step("bomber", 2, {"turn": 0.1}).is_empty(), "a step with no drop is still fine")
	var res2 := BombWorlds.turn(w2)
	eq(BombWorlds.events_of(res2, "bomb_release").size(), 2, "both drops were released")
	eq(u2.drops_left, 0, "and the load is empty")

# --- Planned, then no load; down before the release ---------------------------------------------------------------------------

func _load_spent_after_planning() -> void:
	var w := BombWorlds.world(3, "medium")
	var u: Unit = w.units["bomber"]
	var aim := _ideal(w, 0)
	w.plan_step("bomber", 0, {"drop": {"aim": [aim.x, aim.y]}})
	w.plan_step("bomber", 1, {"drop": {"aim": [aim.x + 100.0, aim.y]}})
	eq(w.bombs_left("bomber")["planned"], 2, "two drops planned")
	# The load shrinks to one after planning (a bomb bay hit, say): the first drop stands, the second is refused at the resolve.
	u.drops_left = 1
	var planned := w.planned_states("bomber")
	check(planned[0]["drop"]["ok"] == true, "the first drop still stands in the preview")
	eq(planned[1]["drop"]["ok"], false, "the second is refused in the preview")
	eq(planned[1]["drop"]["reason"], "no_drops", "...for want of drops")
	var res := BombWorlds.turn(w)
	eq(BombWorlds.events_of(res, "bomb_release").size(), 1, "only one drop is released")
	eq(u.drops_left, 0, "the load is empty, not below it")
	eq(u.history[2]["drop"]["ok"], false, "the history records the refused drop")
	# No load at all.
	var w2 := BombWorlds.world(3, "medium")
	w2.plan_step("bomber", 0, {"drop": {"aim": [aim.x, aim.y]}})
	w2.units["bomber"].drops_left = 0
	var res2 := BombWorlds.turn(w2)
	eq(BombWorlds.events_of(res2, "bomb_release").size(), 0, "a drop planned with no load is not released")
	eq(w2.bombs_in_flight.size(), 0, "no bombs fall")
	eq(w2.units["bomber"].drops_left, 0, "and the count does not go below zero")

# A bomber with one pip over a battery is shot down in some seeds before its release moment and not in others.
func _down_before_release() -> void:
	var before := -1
	var after := -1
	var release_t := 0.0
	for s in range(1, 200):
		var w := World.new()
		w.quiet = true
		w.rng_seed = s
		w.add_player("local")
		w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 1900.0, "y": 2500.0, "heading": 0.0, "altitude_band": "medium", "speed": 85.0})
		w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2300.0, "y": 2500.0, "heading": 0.0})
		w.units["bomber"].health = 1
		var aim := _ideal(w, 2)
		var st := w.plan_step("bomber", 2, {"drop": {"aim": [aim.x, aim.y]}})
		release_t = float(st["drop"]["release_t"])
		var res := BombWorlds.turn(w)
		var downs := BombWorlds.events_of(res, "down", "bomber")
		var rel := BombWorlds.events_of(res, "bomb_release")
		if not downs.is_empty() and float(downs[0]["t"]) < release_t - 0.26 and before < 0:
			before = s
			eq(rel.size(), 0, "seed %d: shot down at %.2f s, before the release at %.2f s: nothing released" % [s, downs[0]["t"], release_t])
			eq(w.units["bomber"].drops_left, 3, "...and the drop is not spent")
			eq(w.bombs_in_flight.size(), 0, "...and no bombs fall")
		elif (downs.is_empty() or float(downs[0]["t"]) > release_t + 0.26) and after < 0:
			after = s
			eq(rel.size(), 1, "seed %d: still up at the release at %.2f s: released" % [s, release_t])
			eq(w.units["bomber"].drops_left, 2, "...and the drop is spent")
			eq(w.bombs_in_flight.size() + BombWorlds.events_of(res, "bomb_impact").size(), w.units["bomber"].def.bomb_per_drop, "...with every bomb falling or landed")
		if before >= 0 and after >= 0:
			break
	check(before >= 0, "a seed exists in which the bomber is shot down before its release")
	check(after >= 0, "and one in which it is not")

# --- Across turns --------------------------------------------------------------------------------------------------------------

func _carried_across_turns() -> void:
	var host := BombWorlds.world(9, "high")
	var client := BombWorlds.world(9, "high")
	_on_the_run(host, "high")
	_on_the_run(client, "high")
	var aim := _ideal(host, 0)
	host.plan_step("bomber", 0, {"drop": {"aim": [aim.x, aim.y]}})
	near(aim.x, BombWorlds.TOWER.x, 0.01, "the bomber is on a perfect run at the tower from the high band")
	var per: int = host.units["bomber"].def.bomb_per_drop
	var landed_turns := {}
	var in_flight_per_turn: Array = []
	var released_turn := 0
	for turn_no in 6:
		var res := BombWorlds.turn(host)
		if not check(not res.is_empty(), "turn %d resolves: %s" % [host.turn, host.last_error]):
			return
		check(res.has("bombs"), "the result carries the bombs still falling")
		check(client.apply_resolution(res), "turn %d: the client applies it: %s" % [host.turn, client.last_error])
		check(_same(res["bombs"], host.bombs_in_flight), "turn %d: the result's bombs are the host's bombs in flight" % host.turn)
		check(_same(client.bombs_in_flight, host.bombs_in_flight), "turn %d: the client's bombs in flight are the host's" % host.turn)
		for id: String in host.units:
			check(_same((client.units[id] as Unit).net_state(), (host.units[id] as Unit).net_state()), "turn %d: %s agrees on host and client" % [host.turn, id])
			check(_same((client.units[id] as Unit).history, (host.units[id] as Unit).history), "turn %d: %s's history agrees" % [host.turn, id])
		for ev: Dictionary in res["events"]:
			if ev["type"] == "bomb_release":
				released_turn = host.turn
			if ev["type"] == "bomb_impact":
				landed_turns[int(ev["turn"])] = int(landed_turns.get(int(ev["turn"]), 0)) + 1
				eq(int(ev["turn"]), host.turn, "an impact is reported in the turn it lands in")
				check(int(ev["released_turn"]) < host.turn, "...a later turn than the release (%d)" % ev["released_turn"])
		in_flight_per_turn.append(host.bombs_in_flight.size())
		for b: Dictionary in host.bombs_in_flight:
			check(int(b["impact_turn"]) > host.turn, "turn %d: a bomb in flight lands in a later turn (%d)" % [host.turn, b["impact_turn"]])
			check(float(b["impact_t"]) >= 0.0 and float(b["impact_t"]) < 5.0, "...at a moment inside that turn (%.2f)" % b["impact_t"])
		if turn_no == 0:
			# After the release turn: the whole stick is in the air, and the bomber is gone from it (it is marked down, and its bombs fall regardless).
			eq(host.bombs_in_flight.size(), per, "after the release turn the whole stick is falling")
			host.units["bomber"].down = true
			client.units["bomber"].down = true
			# Where a bomb is, for the effects.
			var b0: Dictionary = host.bombs_in_flight[0]
			var rt := int(b0["release_turn"])
			var up := Bombs.bomb_position(b0, rt, float(b0["release_t"]) - 0.1, 5.0)
			eq(up["state"], "unreleased", "before its release a bomb is not yet released")
			var heights: Array[float] = []
			var xs: Array[float] = []
			for k in 8:
				var tau := float(b0["release_t"]) + float(b0["fall_s"]) * (float(k) + 0.5) / 8.0
				var abs_turn := rt + int(floorf(tau / 5.0))
				var t_in := tau - 5.0 * float(abs_turn - rt)
				var p := Bombs.bomb_position(b0, abs_turn, t_in, 5.0)
				eq(p["state"], "falling", "a bomb between its release and its landing is falling")
				heights.append(float(p["height_m"]))
				xs.append(float(p["x"]))
			for k in range(1, heights.size()):
				check(heights[k] < heights[k - 1], "it falls: lower at every sample (%.0f then %.0f m)" % [heights[k - 1], heights[k]])
				check(xs[k] > xs[k - 1], "...and moves on towards where it lands")
			check(heights[0] < float(b0["h0"]) and heights[0] > 0.0, "from the height it left at")
			var land := Bombs.bomb_position(b0, int(b0["impact_turn"]), float(b0["impact_t"]), 5.0)
			eq(land["state"], "landed", "at its moment it has landed")
			near(float(land["x"]), float(b0["x"]), 1e-9, "where the record says")
			eq(land["height_m"], 0.0, "on the ground")
		if host.bombs_in_flight.is_empty() and turn_no > 0:
			host.begin_turn()
			client.begin_turn()
			break
		host.begin_turn()
		client.begin_turn()
	check(released_turn == 1, "the stick was released in the first turn")
	var last_landing := 0
	var n_landed := 0
	for t: int in landed_turns:
		last_landing = maxi(last_landing, t)
		n_landed += int(landed_turns[t])
	eq(n_landed, per, "every bomb landed in the end (%s)" % str(landed_turns))
	check(last_landing >= 3, "a high drop falls for turns: the last bomb landed in turn %d (a fall of %.1f s)" % [last_landing, Bombs.fall_time(1000.0, host.bombs.gravity)])
	check(in_flight_per_turn[0] == per and in_flight_per_turn[1] == per, "the stick was in the air through the first two turns (%s)" % str(in_flight_per_turn))
	eq(host.bombs_in_flight.size(), 0, "nothing is left falling")
	eq(client.bombs_in_flight.size(), 0, "on the client either")
	eq(client.units["tower"].health, host.units["tower"].health, "the tower is as hurt on the client as on the host (%d pips)" % host.units["tower"].health)
	# A joining client is handed the bombs in flight (WorldSync's snapshot).
	var h2 := BombWorlds.world(9, "high")
	_on_the_run(h2, "high")
	var aim2 := _ideal(h2, 0)
	h2.plan_step("bomber", 0, {"drop": {"aim": [aim2.x, aim2.y]}})
	BombWorlds.turn(h2)
	var snap := h2.net_bombs()
	eq(snap.size(), per, "a snapshot of the bombs in flight")
	var joiner := BombWorlds.world(9, "high")
	joiner.apply_net_bombs(snap)
	check(_same(joiner.bombs_in_flight, h2.bombs_in_flight), "hands a joining client the same bombs")
	snap[0]["x"] = -1.0
	check(float(h2.bombs_in_flight[0]["x"]) != -1.0, "(a copy: editing the snapshot does not touch the host)")

# --- The unit's own state ---------------------------------------------------------------------------------------------------------

func _unit_state() -> void:
	var w := BombWorlds.world(1, "medium")
	var u: Unit = w.units["bomber"]
	u.drops_left = 1
	check(u.net_state().has("drops_left") and u.net_state()["drops_left"] == 1, "drops_left travels in the unit's net state")
	eq(u.to_dict()["drops_left"], 1, "and in its dictionary")
	var other := Unit.new()
	other.apply_state({"x": 0.0, "y": 0.0, "heading": 0.0, "speed": 0.0, "altitude_band": "surface"})
	other.apply_net_state(u.net_state())
	eq(other.drops_left, 1, "a client unit takes it from the host's")
	eq(w.units["tower"].drops_left, 0, "a tower has none")
