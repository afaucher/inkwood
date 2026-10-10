extends "res://scripts/test_support/test_case.gd"

# THE MOTION CHECK (Track S): the performance envelope (scripts/sim/
# envelope.gd) applies inertia the way the design doc says (Game concept >
# Motion and inertia, Alex 2026-10-09): speed carries, acceleration takes
# several steps, turns cost speed, a plane turns tighter when slow, climbs
# cost speed and dives add it, and a ship stops before it reverses. clamp_step
# is idempotent, and its point form lands on the arc it describes.
#
# Assertions are about RELATIONSHIPS the design asks for, checked against the
# unit's own data -- not about the placeholder numbers, which will change.

const SimRules = preload("res://scripts/sim/sim_rules.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const Records = preload("res://scripts/sim/records.gd")

const EPS := 1e-9

var rules: SimRules

func setup(_main) -> void:
	rules = SimRules.new()
	if not check(rules.ok(), "sim rules load"):
		finish()
		return
	for id: String in ["light_fighter", "heavy_fighter", "bomber"]:
		var def := UnitDef.new(UnitDef.path_for(id), rules.band_ids)
		if check(def.ok(), "%s loads" % id):
			_plane(def)
	_ship()
	finish()

func _state(x: float, y: float, heading: float, speed: float, band: String) -> Dictionary:
	return {"x": x, "y": y, "heading": heading, "speed": speed, "altitude_band": band}

func _plane(def: UnitDef) -> void:
	var e := def.envelope
	var dt := rules.step_dt(def.actions_per_turn)
	var id := def.id
	var mid := e.start_band

	# --- Inertia: acceleration takes steps -------------------------------------
	var s := _state(0.0, 0.0, 0.0, 0.0, mid)
	var r := e.clamp_step(s, {"speed": e.speed_max}, dt)
	check(float(r["speed"]) < e.speed_max, "%s at 0 cannot reach top speed in one step (got %.2f)" % [id, r["speed"]])
	near(float(r["speed"]), e.accel * dt, EPS, "%s from 0 gains exactly accel x step_dt" % id)
	check(r["limits"].has("speed"), "%s: the speed request was limited, and says so" % id)
	var steps := 0
	var cur := _state(0.0, 0.0, 0.0, e.speed_cruise, mid)
	while float(cur["speed"]) < e.speed_max and steps < 1000:
		cur = e.clamp_step(cur, {"speed": e.speed_max}, dt)
		steps += 1
	var turns := float(steps) / float(def.actions_per_turn)
	check(turns >= 2.0, "%s needs several turns to go from cruise to top speed (%d steps = %.1f turns)" % [id, steps, turns])
	print("  %-14s cruise -> top speed: %d steps (%.1f turns)" % [id, steps, turns])
	r = e.clamp_step(_state(0.0, 0.0, 0.0, e.speed_max, mid), {"speed": e.speed_min}, dt)
	near(float(r["speed"]), e.speed_max - e.decel * dt, EPS, "%s slows by at most decel x step_dt" % id)

	# --- An empty request is "carry on", not a stop ------------------------------
	r = e.clamp_step(_state(10.0, 20.0, 0.5, e.speed_cruise, mid), {}, dt)
	near(float(r["speed"]), e.speed_cruise, EPS, "%s: an empty request holds speed" % id)
	near(float(r["heading"]), 0.5, EPS, "%s: an empty request holds heading" % id)
	near(float(r["x"]), 10.0 + cos(0.5) * e.speed_cruise * dt, 1e-6, "%s: carries on straight (x)" % id)
	near(float(r["y"]), 20.0 + sin(0.5) * e.speed_cruise * dt, 1e-6, "%s: carries on straight (y)" % id)
	check(not bool(r["clamped"]), "%s: carrying on is never clamped" % id)

	# --- Turns cost speed ----------------------------------------------------------
	var top := _state(0.0, 0.0, 0.0, e.speed_max, mid)
	var straight := e.clamp_step(top, {"speed": e.speed_max}, dt)
	near(float(straight["speed"]), e.speed_max, EPS, "%s holds top speed flying straight" % id)
	var hard := e.clamp_step(top, {"turn": PI, "speed": e.speed_max}, dt)
	check(float(hard["speed"]) < e.speed_max - 0.5, "%s: a hard turn at top speed costs speed (%.2f -> %.2f)" % [id, e.speed_max, hard["speed"]])
	near(absf(float(hard["turn"])), e.turn_rate(e.speed_max) * dt, EPS, "%s: the turn is cut to the rate at top speed" % id)
	check(hard["limits"].has("turn"), "%s: the cut turn is reported" % id)
	var gentle := e.clamp_step(top, {"turn": 0.25 * float(hard["turn"]), "speed": e.speed_max}, dt)
	check(float(gentle["speed"]) > float(hard["speed"]), "%s: a gentle turn costs less than a hard one" % id)
	# No stall rule yet: a hard turn at minimum speed does not go below it.
	var slow := e.clamp_step(_state(0.0, 0.0, 0.0, e.speed_min, mid), {"turn": PI, "speed": e.speed_min}, dt)
	near(float(slow["speed"]), e.speed_min, EPS, "%s: a hard turn at minimum speed stays at minimum speed (no stall yet)" % id)

	# --- Tighter when slow --------------------------------------------------------
	check(e.turn_rate(e.speed_min) > e.turn_rate(e.speed_max), "%s turns faster at low speed than at high speed" % id)
	check(e.turn_radius(e.speed_min) < e.turn_radius(e.speed_max), "%s turns tighter at low speed" % id)
	var reach_slow := e.reachable(_state(0.0, 0.0, 0.0, e.speed_min, mid), dt)
	var reach_fast := e.reachable(top, dt)
	check(float(reach_slow["turn_max"]) > float(reach_fast["turn_max"]), "%s: reachable() offers a wider turn when slow" % id)

	# --- Climbs cost speed, dives add it, one band at a time ----------------------
	var pos := e.bands.find(mid)
	var cruise := _state(0.0, 0.0, 0.0, e.speed_cruise, mid)
	var level := e.clamp_step(cruise, {"speed": e.speed_cruise + 1000.0}, dt)
	if pos + 1 < e.bands.size():
		var up := e.clamp_step(cruise, {"speed": e.speed_cruise + 1000.0, "altitude_band": e.bands[pos + 1]}, dt)
		eq(up["altitude_band"], e.bands[pos + 1], "%s climbs one band at cruise" % id)
		near(float(up["speed"]), float(level["speed"]) - e.climb_cost, EPS, "%s: a climb costs climb_speed_cost_mps" % id)
		var stalled := e.clamp_step(_state(0.0, 0.0, 0.0, e.speed_min, mid), {"altitude_band": e.bands[pos + 1]}, dt)
		eq(stalled["altitude_band"], mid, "%s cannot climb at minimum speed (it would stall)" % id)
		check(stalled["limits"].has("climb"), "%s: the refused climb is reported" % id)
		var reach_min := e.reachable(_state(0.0, 0.0, 0.0, e.speed_min, mid), dt)
		check(not (reach_min["bands"] as Array).has(e.bands[pos + 1]), "%s: reachable() does not offer a climb it would refuse" % id)
	if pos >= 1:
		var down := e.clamp_step(top, {"speed": e.speed_max + 1000.0, "altitude_band": e.bands[pos - 1]}, dt)
		eq(down["altitude_band"], e.bands[pos - 1], "%s dives one band" % id)
		check(float(down["speed"]) > e.speed_max, "%s: a dive carries it past top speed" % id)
		check(float(down["speed"]) <= e.dive_speed_max, "%s: but not past the dive limit" % id)
		var after := e.clamp_step(down, {"speed": e.speed_max + 1000.0}, dt)
		check(float(after["speed"]) < float(down["speed"]), "%s sheds overspeed after the dive" % id)
	if e.bands.size() >= 3:
		var far := e.clamp_step(_state(0.0, 0.0, 0.0, e.speed_cruise, e.bands[0]), {"altitude_band": e.bands[2]}, dt)
		eq(far["altitude_band"], e.bands[1], "%s climbs at most bands_per_step bands in one step" % id)
		check(far["limits"].has("band"), "%s: the cut band change is reported" % id)

	# --- Idempotence ------------------------------------------------------------------
	var requests: Array = [
		{}, {"turn": 0.1}, {"turn": -10.0}, {"turn": 10.0, "speed": 0.0},
		{"speed": 1e6}, {"speed": -1e6}, {"turn": 0.05, "speed": e.speed_cruise + 3.0},
		{"altitude_band": e.bands[0]}, {"altitude_band": e.bands[e.bands.size() - 1], "turn": -0.2},
		{"to": [500.0, 300.0]}, {"to": Vector2(-50.0, 10.0)}, Vector2(80.0, -40.0),
	]
	var states: Array = [
		_state(0.0, 0.0, 0.0, 0.0, mid), _state(100.0, -40.0, 2.5, e.speed_min, mid),
		_state(-3.0, 7.0, -1.0, e.speed_cruise, mid), _state(0.0, 0.0, PI * 0.5, e.speed_max, mid),
		_state(0.0, 0.0, -2.0, e.dive_speed_max, e.bands[0]),
	]
	var bad := 0
	for st: Dictionary in states:
		for rq: Variant in requests:
			var once := e.clamp_step(st, rq, dt)
			var twice := e.clamp_step(st, once, dt)
			for k: String in ["x", "y", "heading", "speed", "altitude_band", "turn"]:
				if once[k] != twice[k]:
					bad += 1
					if bad <= 5:
						fail("%s: clamp is not idempotent on %s for %s from %s: %s then %s" % [id, k, str(rq), str(st), str(once[k]), str(twice[k])])
			check(not bool(twice["clamped"]), "%s: a clamped result fed back is within the envelope" % id)
			# The point form: steering for where a step ended lands there again.
			var by_point := e.clamp_step(st, {"to": [float(once["x"]), float(once["y"])], "altitude_band": once["altitude_band"]}, dt)
			if absf(float(once["x"]) - float(st["x"])) + absf(float(once["y"]) - float(st["y"])) > 1e-3:
				near(float(by_point["x"]), float(once["x"]), 1e-6, "%s: steering for a reachable point reaches it (x)" % id)
				near(float(by_point["y"]), float(once["y"]), 1e-6, "%s: steering for a reachable point reaches it (y)" % id)
	eq(bad, 0, "%s: clamp_step is idempotent over %d states x %d requests" % [id, states.size(), requests.size()])

	# --- The arc: point_on_step walks it and ends exactly at the step's end ----------
	var from := _state(5.0, 6.0, 0.3, e.speed_cruise, mid)
	var to := e.clamp_step(from, {"turn": 1.0, "speed": e.speed_max}, dt)
	var end := Envelope.point_on_step(from, to, dt, 1.0)
	eq(end["x"], to["x"], "%s: point_on_step(f=1) is the step's end, bit for bit (x)" % id)
	eq(end["y"], to["y"], "%s: point_on_step(f=1) is the step's end, bit for bit (y)" % id)
	var half := Envelope.point_on_step(from, to, dt, 0.5)
	near(float(half["heading"]), Envelope.wrap_angle(0.3 + float(to["turn"]) * 0.5), EPS, "%s: half way through the step, half the turn" % id)
	var rad := (float(from["speed"]) + float(to["speed"])) * 0.5 * dt / absf(float(to["turn"]))
	var cx := float(from["x"]) - sin(0.3) * rad * signf(float(to["turn"]))
	var cy := float(from["y"]) + cos(0.3) * rad * signf(float(to["turn"]))
	for f: float in [0.25, 0.5, 0.75, 1.0]:
		var p := Envelope.point_on_step(from, to, dt, f)
		near(Vector2(float(p["x"]) - cx, float(p["y"]) - cy).length(), rad, 1e-3, "%s: the step's path is a circular arc (f=%.2f)" % [id, f])

	# --- reachable() agrees with clamp_step ------------------------------------------------
	var reach := e.reachable(cruise, dt)
	var hi := e.clamp_step(cruise, {"speed": 1e6}, dt)
	var lo := e.clamp_step(cruise, {"speed": -1e6}, dt)
	eq(reach["speed_hi"], hi["speed"], "%s: reachable speed_hi is what clamp_step gives" % id)
	eq(reach["speed_lo"], lo["speed"], "%s: reachable speed_lo is what clamp_step gives" % id)
	eq((reach["outline"] as PackedVector2Array).size(), 18, "%s: the outline is a closed polygon of 2 x 9 points" % id)

# A ship-shaped unit, built in memory: the schema and the envelope must hold
# the design doc's ship (slow to turn and stop, reverses once stopped) though
# no ship is in the demo.
func _ship() -> void:
	var rec := func(v: Variant) -> Dictionary: return {"value": v, "_proposed": true, "_reason": "test ship"}
	var d := {
		"id": "test_ship", "name": "Test ship", "domain": "sea",
		"size_m": rec.call(120), "actions_per_turn": rec.call(2), "health": rec.call(20),
		"sight_range_m": rec.call(3000), "drawing": {"silhouette": "small_cruiser"}, "weapons": [],
		"envelope": {
			"speed_min_mps": rec.call(-4), "speed_cruise_mps": rec.call(10), "speed_max_mps": rec.call(15),
			"dive_speed_max_mps": rec.call(15), "accel_mps2": rec.call(0.3), "decel_mps2": rec.call(0.4),
			"reverse_from_stop": rec.call(true), "turn_rate_curve_dps": rec.call([[0, 0], [5, 2], [15, 4]]),
			"turn_bleed_mps2": rec.call(0.1), "turn_bleed_exponent": rec.call(2),
			"altitude_bands": rec.call(["surface"]), "start_band": rec.call("surface"),
			"bands_per_step": rec.call(0), "climb_speed_cost_mps": rec.call(0), "dive_speed_gain_mps": rec.call(0),
		},
	}
	var def := UnitDef.new(d, rules.band_ids, false, "test ship")
	if not check(def.ok(), "a ship-shaped unit fits the schema: %s" % str(def.errors)):
		return
	var e := def.envelope
	var dt := rules.step_dt(def.actions_per_turn)
	eq(e.turn_rate(0.0), 0.0, "ship: cannot turn with no way on")
	check(e.turn_rate(10.0) > e.turn_rate(2.0), "ship: turns better with way on")
	var moving := _state(0.0, 0.0, 0.0, 0.5, "surface")
	var r := e.clamp_step(moving, {"speed": -4.0}, dt)
	eq(r["speed"], 0.0, "ship: moving ahead, it can only come to a stop this step, not reverse")
	var r2 := e.clamp_step(r, {"speed": -4.0}, dt)
	check(float(r2["speed"]) < 0.0, "ship: once stopped, it reverses")
	near(float(r2["speed"]), -e.decel * dt, EPS, "ship: reverse builds up at its rate")
	check(float(r2["x"]) < 0.0, "ship: reversing moves it backwards")
	var fast := e.clamp_step(_state(0.0, 0.0, 0.0, 15.0, "surface"), {"speed": 0.0}, dt)
	check(float(fast["speed"]) > 10.0, "ship: slow to stop (15 m/s sheds only %.2f in a step)" % (15.0 - float(fast["speed"])))
	var climb := e.clamp_step(moving, {"altitude_band": "high"}, dt)
	eq(climb["altitude_band"], "surface", "ship: cannot leave the surface")
