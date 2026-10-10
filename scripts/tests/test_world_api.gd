extends "res://scripts/test_support/test_case.gd"

# THE INTERFACE CHECK (Track S): the World exposes what docs/proposals/
# demo-plan.md says S exposes ("a World with units (id, type, side,
# controller player/ai, x, y, heading, speed, altitude band, plan), a
# plan_step(unit, step_index, point) that validates a point against the
# envelope, commit(), resolve() producing per-step positions for every unit,
# and signals for turn phase changes"), by those names and with these
# signatures. Track U and Track A are written against it, so a rename here is
# a break there: this test is the tripwire, and the report lists the same
# signatures.
#
# It checks the SHAPE (method names, argument counts and names, signals,
# properties, the Dictionary keys a caller reads), plus one round trip each so
# a method that exists but returns the wrong shape is caught too.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")

# name -> argument names, in order. Optional arguments are listed too.
const WORLD_METHODS := {
	"add_player": ["player"],
	"remove_player": ["player"],
	"add_unit": ["spec"],
	"unit_def": ["type_id"],
	"steps_per_turn": ["unit_id"],
	"step_dt": ["unit_id"],
	"plan_step": ["unit_id", "step_index", "request"],
	"clear_plan": ["unit_id"],
	"planned_states": ["unit_id"],
	"reachable": ["unit_id", "step_index"],
	"participants": [],
	"is_ready": ["player"],
	"all_ready": [],
	"commit": ["player"],
	"withdraw": ["player"],
	"resolve": [],
	"begin_turn": [],
	"apply_resolution": ["result"],
	"in_bounds": ["px", "py"],
	"bounds_center": [],
	"band_height": ["band"],
	"sample": ["unit_id", "t", "source"],
	"ok": [],
}
const WORLD_SIGNALS := {
	"phase_changed": ["phase"],
	"ready_changed": ["player", "is_ready"],
	"plan_changed": ["unit_id"],
	"turn_resolved": ["turn", "histories", "events"],
	"unit_left_bounds": ["unit_id", "turn", "step_index"],
}
const WORLD_PROPERTIES := ["units", "bounds", "turn", "phase", "players", "ready", "rules", "last_error", "quiet", "rng_seed", "combat"]
# The demo-plan's unit fields, plus what Track S adds.
const UNIT_FIELDS := ["id", "type", "side", "controller", "x", "y", "heading", "speed", "altitude_band", "plan", "history", "def", "out_of_bounds", "health", "down", "down_at", "fate", "fall_height_m", "fall_dir"]
const STATE_KEYS := ["x", "y", "heading", "speed", "altitude_band", "turn", "clamped", "limits", "step", "t", "planned", "out_of_bounds"]
const REACHABLE_KEYS := ["step_dt", "speed", "turn_max", "turn_rate", "turn_radius", "speed_lo", "speed_hi", "speed_lo_full_turn", "speed_hi_full_turn", "bands", "outline"]

func setup(_main) -> void:
	var w := World.new()
	_check_methods(w, WORLD_METHODS, "World")
	_check_signals(w, WORLD_SIGNALS)
	var props := _property_names(w)
	for p: String in WORLD_PROPERTIES:
		check(props.has(p), "World has property '%s'" % p)
	for c: String in ["PHASE_PLANNING", "PHASE_RESOLVING", "PHASE_RESOLVED", "AI_PLAYER", "CONTROLLER_PLAYER", "CONTROLLER_AI"]:
		check(w.get_script().get_script_constant_map().has(c), "World has constant %s" % c)
	eq([World.PHASE_PLANNING, World.PHASE_RESOLVING, World.PHASE_RESOLVED], ["planning", "resolving", "resolved"], "phase names are the ones the plan names")
	eq([World.CONTROLLER_PLAYER, World.CONTROLLER_AI], ["player", "ai"], "controller values are the plan's player/ai")
	check(w.bounds is Rect2 and w.bounds.has_area(), "bounds is a non-empty Rect2 in metres")
	eq(w.phase, World.PHASE_PLANNING, "a new world is planning")
	eq(w.turn, 1, "a new world is on turn 1")
	check(w.units is Dictionary, "units is a Dictionary keyed by unit id")

	_check_methods(Unit.new(), {"state": [], "apply_state": ["s"], "to_dict": [], "net_state": [], "apply_net_state": ["s"]}, "Unit")
	_check_methods(AiDumb.new(w), {"attach": [], "plan_turn": [], "ok": []}, "AiDumb")
	var env_methods := {"turn_rate": ["speed"], "turn_radius": ["speed"], "reachable": ["state", "step_dt", "outline_samples"], "clamp_step": ["state", "request", "step_dt"]}

	# --- Round trips: the shapes a caller reads -------------------------------------
	w.add_player("local")
	var id := w.add_unit({"type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1000.0, "heading": 0.0})
	eq(id, "light_fighter_1", "add_unit returns the new id (auto-named after the type)")
	var u = w.units.get(id)
	if not check(u is Unit, "units[id] is a Unit"):
		finish()
		return
	_check_methods(u.def.envelope, env_methods, "Envelope")
	var props_u := _property_names(u)
	for f: String in UNIT_FIELDS:
		check(props_u.has(f), "Unit has field '%s'" % f)
	var d: Dictionary = u.to_dict()
	for f: String in ["id", "type", "side", "controller", "x", "y", "heading", "speed", "altitude_band", "plan", "history"]:
		check(d.has(f), "Unit.to_dict() has '%s'" % f)
	eq(d["type"], "light_fighter", "type is the unit type id")
	eq(d["controller"], "player", "controller is player or ai")
	eq(d["altitude_band"], "medium", "a new unit starts in its type's start band")
	eq(d["speed"], 100.0, "a new unit starts at its type's cruise speed")
	eq(u.health, u.def.health, "a new unit starts with its type's health")
	check(u.health > 0 and not u.down and is_nan(u.down_at), "a new unit is up, with no down time")

	var s := w.plan_step(id, 0, Vector2(1100.0, 1010.0))
	for k: String in STATE_KEYS:
		check(s.has(k), "plan_step's result has '%s'" % k)
	check(s["limits"] is Array, "limits is a list of limit names")
	var s2 := w.plan_step(id, 1, {"turn": 0.1, "speed": 100.0})
	check(not s2.is_empty(), "plan_step also takes a {turn, speed} request")
	var r := w.reachable(id, 1)
	for k: String in REACHABLE_KEYS:
		check(r.has(k), "reachable() has '%s'" % k)
	check(r["outline"] is PackedVector2Array, "the reachable outline is drawing data (PackedVector2Array)")
	eq(w.planned_states(id).size(), w.steps_per_turn(id), "planned_states covers every step of the turn")
	near(w.step_dt(id) * float(w.steps_per_turn(id)), w.rules.turn_seconds, 1e-12, "steps fill the turn")
	var got: Array = []
	w.turn_resolved.connect(func(t: int, h: Dictionary, e: Array) -> void: got.append([t, h, e]))
	check(w.commit("local"), "commit returns true when everyone is ready")
	var out := w.resolve()
	for k: String in ["turn", "histories", "events"]:
		check(out.has(k), "resolve() returns '%s'" % k)
	check((out["histories"] as Dictionary).has(id), "resolve() has a history for every unit")
	eq(got.size(), 1, "turn_resolved fired once")
	if got.size() == 1:
		eq(got[0][0], 1, "turn_resolved carries the turn number")
		eq(got[0][1], out["histories"], "turn_resolved carries the same histories resolve() returns")
	check(out.has("units") and (out["units"] as Dictionary).has(id), "resolve() returns every unit's net_state")

	# The network contract: a client World applies the host's result as if it
	# had resolved the turn itself.
	var c := World.new()
	c.add_player("client")
	c.add_unit({"type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 1000.0, "heading": 0.0})
	var got_c: Array = []
	c.turn_resolved.connect(func(t: int, h: Dictionary, e: Array) -> void: got_c.append([t, h, e]))
	check(c.apply_resolution(out), "apply_resolution takes the host's resolve() result")
	eq(c.phase, World.PHASE_RESOLVED, "after apply_resolution the client is resolved")
	var host_s: Dictionary = u.net_state()
	var client_s: Dictionary = c.units[id].net_state()
	check(is_nan(host_s["down_at"]) and is_nan(client_s["down_at"]), "down_at stays NAN for a unit that did not go down")
	host_s.erase("down_at")
	client_s.erase("down_at")
	eq(client_s, host_s, "the client's unit ends where the host's did")
	eq(c.units[id].history, u.history, "the client's unit carries the host's history")
	eq(got_c.size(), 1, "apply_resolution fires turn_resolved once")
	if got_c.size() == 1:
		eq(got_c[0][1], out["histories"], "with the host's histories")
	c.quiet = true
	check(not c.apply_resolution(out), "apply_resolution refuses outside the planning phase")
	c.begin_turn()
	w.begin_turn()
	check(not c.apply_resolution(out), "apply_resolution refuses a result for another turn")
	c.quiet = false
	var smp := w.sample(id, 2.5)
	for k: String in ["x", "y", "heading", "speed", "altitude_band", "height_m"]:
		check(smp.has(k), "sample() has '%s'" % k)
	check(Envelope.request_error(Vector2(1, 2)) == "", "a Vector2 is a request (the plan's 'point')")
	finish()

func _check_methods(obj: Object, wanted: Dictionary, label: String) -> void:
	var have := {}
	for m: Dictionary in obj.get_script().get_script_method_list():
		have[m["name"]] = m
	for mname: String in wanted:
		if not check(have.has(mname), "%s has method %s()" % [label, mname]):
			continue
		var args: Array = []
		for a: Dictionary in have[mname]["args"]:
			args.append(a["name"])
		eq(args, wanted[mname], "%s.%s() arguments" % [label, mname])

func _check_signals(obj: Object, wanted: Dictionary) -> void:
	for sname: String in wanted:
		if not check(obj.has_signal(sname), "World has signal %s" % sname):
			continue
		for sig: Dictionary in obj.get_signal_list():
			if sig["name"] == sname:
				var args: Array = []
				for a: Dictionary in sig["args"]:
					args.append(a["name"])
				eq(args, wanted[sname], "signal %s arguments" % sname)

func _property_names(obj: Object) -> Array:
	var out: Array = []
	for p: Dictionary in obj.get_property_list():
		out.append(p["name"])
	return out
