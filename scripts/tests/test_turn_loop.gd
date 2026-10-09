extends "res://scripts/test_support/test_case.gd"

# THE TURN LOOP CHECK (Track S): the demo's world -- two player planes and one
# AI plane (exit criterion 2) -- planned, committed and resolved for several
# turns; the dumb AI never leaves the map over 20 turns from awkward starts;
# an unplanned plane carries on with inertia rather than stopping; leaving the
# map is an event the world survives; ready-up follows the design doc (every
# participant readies, the AI readies itself); and resolution is a pure
# function of (state, plans): two identical worlds resolve identically.

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")

func setup(_main) -> void:
	_three_turns()
	_ai_stays_in_bounds()
	_leaving_is_an_event()
	_determinism()
	_ready_up()
	finish()

func _demo_world() -> World:
	var w := World.new()
	check(w.ok(), "the world's data loads: %s" % str(w.errors))
	w.add_player("local")
	eq(w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0}), "p1", "player plane 1 added")
	eq(w.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2700.0, "heading": 0.0}), "p2", "player plane 2 added")
	eq(w.add_unit({"id": "ai1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": 3500.0, "y": 1800.0, "heading": PI}), "ai1", "AI plane added")
	return w

# Plans for player plane 1 that exercise both request forms.
func _plan_p1(w: World, turn_no: int) -> void:
	w.plan_step("p1", 0, {"turn": 0.3 if turn_no % 2 == 1 else -0.3, "speed": 130.0})
	var u = w.units["p1"]
	var ahead := Vector2(float(u.x) + cos(float(u.heading)) * 300.0, float(u.y) + sin(float(u.heading)) * 300.0 + 40.0)
	w.plan_step("p1", 2, ahead)

func _three_turns() -> void:
	var w := _demo_world()
	var phases: Array[String] = []
	var resolved_turns: Array[int] = []
	w.phase_changed.connect(func(p: String) -> void: phases.append(p))
	w.turn_resolved.connect(func(t: int, _h: Dictionary, _e: Array) -> void: resolved_turns.append(t))
	var ai := AiDumb.new(w)
	check(ai.ok(), "the AI's data loads")
	ai.attach()
	check(w.is_ready(World.AI_PLAYER), "the AI planned and readied itself")
	check(not w.all_ready(), "the human has not readied yet")
	eq(w.participants(), ["local", "ai"] as Array[String], "participants: the local player and the AI")

	for turn_no in range(1, 4):
		eq(w.turn, turn_no, "turn counter at the start of turn %d" % turn_no)
		eq(w.phase, World.PHASE_PLANNING, "turn %d starts in planning" % turn_no)
		_plan_p1(w, turn_no)
		var preview := w.planned_states("p1")
		eq(preview.size(), 5, "turn %d: the preview covers all 5 of the light fighter's steps" % turn_no)
		check(bool(preview[0]["planned"]) and not bool(preview[1]["planned"]) and bool(preview[2]["planned"]), "turn %d: the preview marks which steps were planned" % turn_no)
		var before := {}
		for id: String in w.units:
			before[id] = w.units[id].state()
		phases.clear()
		check(w.commit("local"), "turn %d: the local player's commit makes everyone ready" % turn_no)
		var res := w.resolve()
		if not check(not res.is_empty(), "turn %d resolves: %s" % [turn_no, w.last_error]):
			return
		eq(phases, ["resolving", "resolved"] as Array[String], "turn %d: phase sequence" % turn_no)
		eq(int(res["turn"]), turn_no, "turn %d: the result names its turn" % turn_no)

		for id: String in w.units:
			var u = w.units[id]
			var h: Array = u.history
			var n: int = u.def.actions_per_turn
			eq(h.size(), n + 1, "turn %d, %s: history holds the start and %d steps" % [turn_no, id, n])
			eq((res["histories"] as Dictionary)[id], h, "turn %d, %s: turn_resolved's history is the unit's" % [turn_no, id])
			near(float(h[0]["x"]), float(before[id]["x"]), 0.0, "turn %d, %s: history starts where the unit was" % [turn_no, id])
			near(float(h[h.size() - 1]["t"]), w.rules.turn_seconds, 1e-12, "turn %d, %s: the last step ends with the turn" % [turn_no, id])
			for k in range(1, h.size()):
				check(float(h[k]["t"]) > float(h[k - 1]["t"]), "turn %d, %s: step times increase" % [turn_no, id])
			var moved := Vector2(float(u.x) - float(before[id]["x"]), float(u.y) - float(before[id]["y"])).length()
			check(moved > 100.0, "turn %d, %s: the plane moved (%.1f m)" % [turn_no, id, moved])
			eq(u.x, h[h.size() - 1]["x"], "turn %d, %s: the unit ends where its history ends" % [turn_no, id])
			eq(u.plan.size(), 0, "turn %d, %s: the plan is consumed" % [turn_no, id])
		# What the preview showed is what happened.
		var hp1: Array = w.units["p1"].history
		for k in preview.size():
			eq(hp1[k + 1]["x"], preview[k]["x"], "turn %d: p1 step %d resolved where the preview said (x)" % [turn_no, k])
			eq(hp1[k + 1]["y"], preview[k]["y"], "turn %d: p1 step %d resolved where the preview said (y)" % [turn_no, k])

		# p2 never gets a plan: it carries on straight at its speed -- inertia, not a stop.
		var p2 = w.units["p2"]
		var b2: Dictionary = before["p2"]
		near(float(p2.heading), float(b2["heading"]), 1e-12, "turn %d: unplanned p2 holds its heading" % turn_no)
		near(float(p2.speed), float(b2["speed"]), 1e-12, "turn %d: unplanned p2 holds its speed" % turn_no)
		var dist := float(b2["speed"]) * w.rules.turn_seconds
		near(float(p2.x), float(b2["x"]) + cos(float(b2["heading"])) * dist, 1e-6, "turn %d: unplanned p2 flew straight on (x)" % turn_no)
		near(float(p2.y), float(b2["y"]) + sin(float(b2["heading"])) * dist, 1e-6, "turn %d: unplanned p2 flew straight on (y)" % turn_no)

		phases.clear()
		w.begin_turn()
		eq(phases, ["planning"] as Array[String], "turn %d: begin_turn returns to planning" % turn_no)
		check(w.is_ready(World.AI_PLAYER), "turn %d: the AI re-planned and readied itself for the next turn" % turn_no)
		check(not w.is_ready("local"), "turn %d: the human's ready flag reset" % turn_no)
	eq(resolved_turns, [1, 2, 3] as Array[int], "turn_resolved fired once per turn")
	eq(w.turn, 4, "three turns played, the fourth is planning")

	# sample() walks the same arcs: at a step boundary it is the history's state.
	var h1: Array = w.units["p1"].history
	var at := w.sample("p1", float(h1[2]["t"]))
	near(float(at["x"]), float(h1[2]["x"]), 1e-9, "sample() at a step's end time is that step's state (x)")
	near(float(at["height_m"]), w.band_height("medium"), 1e-9, "sample() carries the band's height for shadows")

# The dumb AI keeps every kind of plane on the map for 20 turns, from awkward
# starts: heading straight at an edge, into a corner, at top speed near an edge.
func _ai_stays_in_bounds() -> void:
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
		s["id"] = "ai_%d" % i
		check(w.add_unit(s) != "", "AI spawn %d added" % i)
	var left: Array = []
	w.unit_left_bounds.connect(func(id: String, t: int, k: int) -> void: left.append([id, t, k]))
	var ai := AiDumb.new(w)
	ai.attach()
	var checked := 0
	var outside := 0
	var min_edge := INF
	for turn_no in 20:
		if not check(w.all_ready(), "turn %d: the AI readied itself" % (turn_no + 1)):
			return
		var res := w.resolve()
		if not check(not res.is_empty(), "AI-only turn %d resolves" % (turn_no + 1)):
			return
		for id: String in w.units:
			for st: Dictionary in w.units[id].history:
				checked += 1
				var x := float(st["x"])
				var y := float(st["y"])
				min_edge = minf(min_edge, minf(minf(x, 5000.0 - x), minf(y, 5000.0 - y)))
				if not w.in_bounds(x, y):
					outside += 1
		w.begin_turn()
	eq(outside, 0, "no AI plane left the map in 20 turns (%d states checked)" % checked)
	eq(left.size(), 0, "no left_bounds event in 20 AI turns")
	print("  AI: 20 turns, %d plane states, closest approach to an edge %.1f m" % [checked, min_edge])

func _leaving_is_an_event() -> void:
	var w := World.new()
	w.add_player("local")
	w.add_unit({"id": "stray", "type": "light_fighter", "side": "allies", "controller": "player", "x": 4950.0, "y": 2500.0, "heading": 0.0})
	var left: Array = []
	w.unit_left_bounds.connect(func(id: String, t: int, k: int) -> void: left.append([id, t, k]))
	w.commit("local")
	var res := w.resolve()
	var events: Array = res.get("events", [])
	eq(events.size(), 1, "flying off the map is one event")
	if events.size() == 1:
		eq(events[0]["type"], "left_bounds", "the event says the unit left")
		eq(events[0]["unit"], "stray", "the event names the unit")
	eq(left.size(), 1, "unit_left_bounds fired")
	check(w.units["stray"].out_of_bounds, "the unit knows it is out of bounds")
	eq(w.phase, World.PHASE_RESOLVED, "the world carries on after a unit leaves")
	# Steer it home (a point request each step: the map centre); it comes
	# back, and that is an event too. (Turning at full rate is not enough: it
	# circles out there.)
	var returned := false
	for turn_no in 10:
		w.begin_turn()
		for k in w.steps_per_turn("stray"):
			w.plan_step("stray", k, w.bounds_center())
		w.commit("local")
		res = w.resolve()
		if not check(not res.is_empty(), "an out-of-bounds unit's turn still resolves"):
			return
		for ev: Dictionary in res["events"]:
			check(ev["type"] != "left_bounds", "no second left_bounds while it is still out")
			if ev["type"] == "returned_to_bounds":
				returned = true
		if returned:
			break
	check(returned, "turning back onto the map is a returned_to_bounds event")

func _determinism() -> void:
	var results: Array = []
	for run in 2:
		var w := _demo_world()
		var ai := AiDumb.new(w)
		ai.attach()
		var runs: Array = []
		for turn_no in range(1, 6):
			_plan_p1(w, turn_no)
			w.plan_step("p2", 1, {"turn": -0.2, "speed": 90.0, "altitude_band": "high"})
			w.commit("local")
			runs.append(w.resolve()["histories"])
			w.begin_turn()
		results.append(runs)
	eq(results[0], results[1], "two identical worlds with identical plans resolve identically over 5 turns")

func _ready_up() -> void:
	var w := World.new()
	w.quiet = true
	w.add_player("alice")
	w.add_player("bob")
	w.add_unit({"id": "p", "type": "light_fighter", "side": "allies", "controller": "player", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	w.add_unit({"id": "a", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 2500.0, "y": 1500.0, "heading": PI})
	var ai := AiDumb.new(w)
	ai.attach()
	check(not w.commit("alice"), "one of two players ready is not everyone")
	eq(w.resolve(), {}, "resolve waits for everyone")
	check(w.last_error.contains("bob"), "and says who it is waiting for: %s" % w.last_error)
	check(w.commit("bob"), "the second player's commit makes everyone ready")
	w.withdraw("bob")
	check(not w.all_ready(), "a withdrawn ready flag holds the turn again")
	check(not w.commit("mallory"), "someone not playing cannot commit")
	check(w.commit("bob"), "ready again")
	w.remove_player("bob")
	check(w.all_ready(), "a player who drops out no longer holds up the turn")
	check(not w.resolve().is_empty(), "the turn resolves")
	eq(w.plan_step("p", 0, {"turn": 0.1}), {}, "no planning while resolved")
	check(not w.commit("alice"), "no commit while resolved")
	w.begin_turn()
	eq(w.plan_step("p", 7, {}), {}, "a step past the unit's steps is refused")
	eq(w.plan_step("nobody", 0, {}), {}, "an unknown unit is refused")
	eq(w.plan_step("p", 0, {"speed": "fast"}), {}, "a malformed request is refused")
	eq(w.add_unit({"type": "light_fighter", "side": "allies", "controller": "player", "x": 1.0, "y": 1.0, "heading": 0.0, "altitude_band": "surface"}), "", "a plane cannot be put on the surface band")
	eq(w.add_unit({"type": "zeppelin", "side": "allies", "controller": "player", "x": 1.0, "y": 1.0, "heading": 0.0}), "", "an unknown unit type is refused")
