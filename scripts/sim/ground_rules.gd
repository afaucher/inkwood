extends RefCounted

# THE GROUND RULE (Track TK2, proposed 2026-10-11; the pattern is the water rule's, sea_rules.gd and World._keep_afloat).
# Numbers from data/sim/ground.json (every value there carries its reason; the same rules as the other sim data,
# records.gd: a missing field is an error, never a default) AND the rule itself, which the World applies to every step
# of a unit of domain "ground" that can move (a tank). The World is GIVEN what it needs, as it is given the water
# (World.set_water), and a rule part whose query is missing is off, so the sim stays testable on its own:
#
#   world.set_ground(level, road, woods, road_path)      # Callables, see set_queries
#   var rules := GroundRules.new()                       # rules.ok(), rules.errors; hull_fraction, sample_m ...
#
# WHAT IT KEEPS along every step (the arc is sampled every sample_m, at least four times; at each sample the hull's
# centre and both ends are looked at):
#   1. NO CLIFF (ALEX, decision terrain-passability A: "every height step is a cliff, impassable to ground units and crossed
#      only at ramps or roads"; ramps do not exist yet): the hull stays on one height level, and the level under its centre
#      changes between two samples only where the unit is on a ROAD at both. (On a road the three points of the hull may
#      straddle two levels, too: the road is the crossing.)
#   2. NO WATER: no point of the hull is over water deeper than wade_m, except where the water is covered by an INTACT
#      BRIDGE (a unit of a bridge type that is not down: the span is the rectangle size_m long along its heading and
#      bridge_half_width_m either side of its axis). A destroyed bridge is water again.
#   3. THE GOING: the step's end speed may not exceed the unit's top speed times the going's factor, averaged over the
#      samples: 1 on a road (or a bridge), speed_factor.open off it, speed_factor.woods among trees (the tree density at
#      or above woods_density_min). Trees do not block (Alex, trees-do-not-block, for now): they only slow.
# A step that breaks (1) or (2) is CLAMPED the way the envelope and the sea rule clamp: first SLOWED (the same turn at slower
# and slower end speeds, down to the floor of the step's speed window), then, if even the slowest breaks it, HELD (the unit stays
# where it is, speed 0); the step reports clamped with the limit "cliff" or "water". A step the going slows reports "terrain":
# a SOFT cap, the unit cannot brake faster than its decel, so one that drives from a road into woods at top speed is as slow
# as its brakes allow and no slower. Between the planned speed and the first speed that is legal the step is refined by
# bisection (refine_steps), so the fan and the plan show the fastest legal step, not the nearest of a coarse ladder.
#
# `source` may also be an already-parsed Dictionary (tests build variants that way without writing files).

const Records = preload("res://scripts/sim/records.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const JsMath = preload("res://scripts/core/js_math.gd")

const PATH := "res://data/sim/ground.json"

const KNOWN := ["hull_fraction", "sample_m", "slow_tries", "refine_steps", "road_half_m", "wade_m", "bridge_types",
	"bridge_half_width_m", "speed_factor", "woods_density_min"]

var hull_fraction: float = NAN          # the hull's ends are checked this share of size_m fore and aft of the centre
var sample_m: float = NAN               # a step's arc is sampled at least this often
var slow_tries: int = 0                 # slower end speeds tried before a step is held
var refine_steps: int = 0               # bisection steps between the last illegal speed and the first legal one
var road_half_m: float = NAN            # on the road: the centre within this of the road's centre line
var wade_m: float = NAN                 # the depth of water a ground unit may drive into
var bridge_types: Array[String] = []    # the unit types that carry a ground unit over water while they stand
var bridge_half_width_m: float = NAN
var factor_road: float = NAN            # the going: a share of the unit's top speed
var factor_open: float = NAN
var factor_woods: float = NAN
var woods_density_min: float = NAN
var errors: Array[String] = []

# The queries (set_queries); an invalid Callable is a part of the rule that is off.
var level_fn: Callable = Callable()     # (x, y) -> int, the height level (0 low ground, 1 upland, 2 top)
var road_fn: Callable = Callable()      # (x, y) -> float, metres to the nearest road centre line (INF when none is near)
var woods_fn: Callable = Callable()     # (x, y) -> float, the tree density 0..1
var path_fn: Callable = Callable()      # (from: Vector2, to: Vector2) -> PackedVector2Array, the road between two points

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<ground dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a ground source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		hull_fraction = r.number(d, "hull_fraction", "hull_fraction", 0.0, 1.0)
		sample_m = r.number(d, "sample_m", "sample_m", 0.1)
		slow_tries = r.integer(d, "slow_tries", "slow_tries", 1)
		refine_steps = r.integer(d, "refine_steps", "refine_steps", 0)
		road_half_m = r.number(d, "road_half_m", "road_half_m", 0.0)
		wade_m = r.number(d, "wade_m", "wade_m", 0.0)
		bridge_types = _types(r, d, "bridge_types")
		bridge_half_width_m = r.number(d, "bridge_half_width_m", "bridge_half_width_m", 0.0)
		var sf := r.section(d, "speed_factor", "speed_factor")
		factor_road = r.number(sf, "road", "speed_factor.road", 0.0, 1.0)
		factor_open = r.number(sf, "open", "speed_factor.open", 0.0, 1.0)
		factor_woods = r.number(sf, "woods", "speed_factor.woods", 0.0, 1.0)
		for key: Variant in sf:
			var sk := str(key)
			if not sk.begins_with("_") and not ["road", "open", "woods"].has(sk):
				r.err("unknown field 'speed_factor.%s' (misspelt?)" % sk)
		woods_density_min = r.number(d, "woods_density_min", "woods_density_min", 0.0, 1.0)
		for key: Variant in d:
			var k := str(key)
			if not k.begins_with("_") and not KNOWN.has(k):
				r.err("unknown field '%s' (misspelt?)" % k)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

# A value record holding a non-empty list of unit type ids (text; that the files exist is the World's business).
static func _types(r: Records, d: Dictionary, key: String) -> Array[String]:
	var out: Array[String] = []
	var v: Variant = r.record(d, key, key)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		r.err("'%s' must be a non-empty list of unit type ids" % key)
		return out
	for item: Variant in v:
		if item is String and str(item) != "" and not out.has(str(item)):
			out.append(str(item))
		else:
			r.err("'%s' has an entry that is not a new unit type id: %s" % [key, str(item)])
	return out

# --- The queries -------------------------------------------------------------------------------------

func set_queries(level: Callable, road: Callable, woods: Callable, path: Callable = Callable()) -> void:
	level_fn = level
	road_fn = road
	woods_fn = woods
	path_fn = path

# Is any part of the ground rule's eyes there? (The water is the World's own; it counts too: see World.)
func has_queries() -> bool:
	return level_fn.is_valid() or road_fn.is_valid() or woods_fn.is_valid()

# The metres to the nearest road centre line; INF with no road query or none near.
func road_dist(px: float, py: float) -> float:
	return float(road_fn.call(px, py)) if road_fn.is_valid() else INF

func level_at(px: float, py: float) -> int:
	return int(level_fn.call(px, py)) if level_fn.is_valid() else 0

# The road between two points, from the road query's polyline ([] without one).
func road_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	return path_fn.call(from, to) if path_fn.is_valid() else PackedVector2Array()

# --- Bridges ------------------------------------------------------------------------------------------

# The spans of the intact bridges among `units` (the World's Dictionary id -> Unit): [{x, y, c, s, half_len}] in the
# bridge's own axes (c, s the cosine and sine of its heading).
func spans(units: Dictionary) -> Array:
	var out: Array = []
	for id: String in units:
		var b: Variant = units[id]
		if b.down or not bridge_types.has(str(b.type)):
			continue
		out.append({"x": float(b.x), "y": float(b.y), "c": JsMath.cos(float(b.heading)), "s": JsMath.sin(float(b.heading)),
			"half_len": 0.5 * float(b.def.size_m)})
	return out

func on_span(spans_list: Array, px: float, py: float) -> bool:
	for sp: Dictionary in spans_list:
		var dx := px - float(sp["x"])
		var dy := py - float(sp["y"])
		var along := dx * float(sp["c"]) + dy * float(sp["s"])
		var across := -dx * float(sp["s"]) + dy * float(sp["c"])
		if absf(along) <= float(sp["half_len"]) and absf(across) <= bridge_half_width_m:
			return true
	return false

# --- One pose of the hull ---------------------------------------------------------------------------------

# What the hull of a unit `size_m` long, centred at (px, py) and pointing along `heading`, stands on:
#   water    some point of it (centre or an end) is over water deeper than wade_m with no intact bridge under it
#   level    the height level under the centre
#   cliff    the hull is not on one level and not on a road
#   on_road  the centre is on a road (within road_half_m of its centre line) or a bridge's deck
#   factor   the going's share of the top speed under the centre (1 on a road)
# `water` is the World's water query (an invalid Callable: no water).
func look(size_m: float, px: float, py: float, heading: float, spans_list: Array, water: Callable) -> Dictionary:
	var half := hull_fraction * size_m
	var cx := JsMath.cos(heading) * half
	var cy := JsMath.sin(heading) * half
	var wet := false
	var on_deck := on_span(spans_list, px, py)
	if water.is_valid():
		if float(water.call(px, py)) > wade_m and not on_deck:
			wet = true
		elif float(water.call(px + cx, py + cy)) > wade_m and not on_span(spans_list, px + cx, py + cy):
			wet = true
		elif float(water.call(px - cx, py - cy)) > wade_m and not on_span(spans_list, px - cx, py - cy):
			wet = true
	var on_road := on_deck or road_dist(px, py) <= road_half_m
	var lvl := 0
	var cliff := false
	if level_fn.is_valid():
		lvl = int(level_fn.call(px, py))
		if not on_road:
			cliff = int(level_fn.call(px + cx, py + cy)) != lvl or int(level_fn.call(px - cx, py - cy)) != lvl
	# the going: a road is the unit's own top speed; off it the open ground's share, woods' a smaller one. A part of the eyes that is
	# missing is a part that is off: with no road query nothing is known to be "off the road", with no woods query nothing is woods.
	var factor := factor_road
	if not on_road:
		if woods_fn.is_valid() and float(woods_fn.call(px, py)) >= woods_density_min:
			factor = factor_woods
		elif road_fn.is_valid():
			factor = factor_open
	return {"water": wet, "level": lvl, "cliff": cliff, "on_road": on_road, "factor": factor}

# Is the pose one the unit may stand in at all (no water, no cliff)? What World.ground_ok_at answers.
func pose_ok(size_m: float, px: float, py: float, heading: float, spans_list: Array, water: Callable) -> bool:
	var lk := look(size_m, px, py, heading, spans_list, water)
	return not bool(lk["water"]) and not bool(lk["cliff"])

# --- One step ---------------------------------------------------------------------------------------------

# How a candidate step from `prev` to `c` fares: {"problem": "" | "cliff" | "water", "cap": m/s} -- the cap is the
# largest end speed the going allows (top speed x the mean factor over the samples), only meaningful with no problem.
func judge(def: Object, prev: Dictionary, c: Dictionary, dt: float, start: Dictionary, spans_list: Array, water: Callable) -> Dictionary:
	var length := absf(0.5 * (float(prev["speed"]) + float(c["speed"]))) * dt
	var count := maxi(4, ceili(length / sample_m))
	var last_level := int(start["level"])
	var last_road := bool(start["on_road"])
	var total := 0.0
	for i in range(1, count + 1):
		var p := Envelope.point_on_step(prev, c, dt, float(i) / float(count))
		var lk := look(float(def.size_m), float(p["x"]), float(p["y"]), float(p["heading"]), spans_list, water)
		if bool(lk["water"]):
			return {"problem": Envelope.LIMIT_WATER, "cap": 0.0}
		if bool(lk["cliff"]):
			return {"problem": Envelope.LIMIT_CLIFF, "cap": 0.0}
		if int(lk["level"]) != last_level and not (bool(lk["on_road"]) and last_road):
			return {"problem": Envelope.LIMIT_CLIFF, "cap": 0.0}
		last_level = int(lk["level"])
		last_road = bool(lk["on_road"])
		total += float(lk["factor"])
	return {"problem": "", "cap": float(def.envelope.speed_max) * total / float(count)}

# The step `s` (clamped by the envelope) kept on the ground: as it is if it breaks nothing; else the same turn at slower
# end speeds (slow_tries of them, from the planned one down to the floor of the speed window, then refined by bisection
# between the last speed that failed and the first that held); else, if even the slowest breaks a hard rule (cliff,
# water), HELD where it is (speed 0). A changed step is clamped and carries what changed it: "cliff", "water", "terrain".
func keep(def: Object, prev: Dictionary, s: Dictionary, dt: float, spans_list: Array, water: Callable) -> Dictionary:
	var env: Envelope = def.envelope
	var start := look(float(def.size_m), float(prev["x"]), float(prev["y"]), float(prev["heading"]), spans_list, water)
	var first := judge(def, prev, s, dt, start, spans_list, water)
	if str(first["problem"]) == "" and absf(float(s["speed"])) <= float(first["cap"]) + 1e-9:
		return s
	var turn := float(s["turn"])
	# the slowest end speed the step's window allows: the one nearest zero (the window's floor going ahead, its top going astern)
	var w_lo := float(env.clamp_step(prev, {"turn": turn, "speed": -1.0e9}, dt)["speed"])
	var w_hi := float(env.clamp_step(prev, {"turn": turn, "speed": 1.0e9}, dt)["speed"])
	var v_planned := float(s["speed"])
	var v_slow := clampf(0.0, w_lo, w_hi)
	var reasons: Array[String] = []
	_note(reasons, str(first["problem"]) if str(first["problem"]) != "" else Envelope.LIMIT_TERRAIN)
	# THE GOING ALONE (no cliff, no water: the step is only too fast for the ground it crosses -- off the road, the commonest case, and the
	# one a fan asks for eighteen times): the cap hardly depends on the speed, so the speed to try is the cap itself, again if the shorter
	# arc found a different going; two or three looks instead of the ladder and its refinement.
	if str(first["problem"]) == "":
		var v := v_planned
		var cap := float(first["cap"])
		for _i in 3:
			var v_next := clampf(signf(v) * minf(absf(v), cap), w_lo, w_hi)
			if is_equal_approx(v_next, v):
				break
			v = v_next
			var c1 := env.clamp_step(prev, {"turn": turn, "speed": v}, dt)
			var d1 := judge(def, prev, c1, dt, start, spans_list, water)
			if str(d1["problem"]) != "":
				break   # (this speed breaks a hard rule: the ladder below)
			cap = float(d1["cap"])
			if absf(float(c1["speed"])) <= cap + 1e-9:
				return _limited(c1, reasons)
	var v_bad := v_planned
	var soft: Dictionary = {}     # the slowest candidate that broke no hard rule (the going's cap is soft)
	for j in range(1, slow_tries + 1):
		var v := lerpf(v_planned, v_slow, float(j) / float(slow_tries))
		var c := env.clamp_step(prev, {"turn": turn, "speed": v}, dt)
		var verdict := judge(def, prev, c, dt, start, spans_list, water)
		if str(verdict["problem"]) != "":
			_note(reasons, str(verdict["problem"]))
			v_bad = v
			continue
		soft = c
		if absf(float(c["speed"])) <= float(verdict["cap"]) + 1e-9:
			# the first legal speed: refine between it and the last that was not
			var v_ok := v
			var best := c
			for _k in refine_steps:
				var mid := 0.5 * (v_ok + v_bad)
				var cm := env.clamp_step(prev, {"turn": turn, "speed": mid}, dt)
				var vm := judge(def, prev, cm, dt, start, spans_list, water)
				if str(vm["problem"]) == "" and absf(float(cm["speed"])) <= float(vm["cap"]) + 1e-9:
					v_ok = mid
					best = cm
				else:
					v_bad = mid
			return _limited(best, reasons)
		_note(reasons, Envelope.LIMIT_TERRAIN)
		v_bad = v
	if not soft.is_empty():
		# nothing is within the going's cap, but the slowest step breaks no hard rule: it is as slow as the brakes allow
		return _limited(soft, reasons)
	var held := {
		"x": prev["x"], "y": prev["y"], "heading": prev["heading"], "speed": 0.0,
		"altitude_band": prev["altitude_band"], "turn": 0.0, "limits": [],
		"held": true,   # (Envelope.point_on_step: a held step goes nowhere, whatever speed the unit had)
	}
	return _limited(held, reasons)

static func _note(reasons: Array[String], reason: String) -> void:
	if reason != "" and not reasons.has(reason):
		reasons.append(reason)

static func _limited(c: Dictionary, reasons: Array[String]) -> Dictionary:
	var limits: Array = (c.get("limits", []) as Array).duplicate()
	for r: String in reasons:
		if not limits.has(r):
			limits.append(r)
	c["limits"] = limits
	c["clamped"] = not limits.is_empty()
	return c
