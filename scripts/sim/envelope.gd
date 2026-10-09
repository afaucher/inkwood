extends RefCounted

# The performance envelope: which end-of-step states a unit can reach from its
# state at the start of a step. Design doc, Game concept > Motion and inertia:
# "Selecting motion is defining a curve. Each point on the curve is one step
# ... at each step the player picks a point within that unit's performance
# envelope", with inertia -- planes lose speed in turns and climbs and take
# several turns to reach top speed; ships are slow to turn and stop but can
# reverse once stopped.
#
# Built by unit_def.gd from the validated `envelope` section of a unit file
# (field meanings: data/units/_schema.json). Every method is a PURE FUNCTION of
# its arguments and this object's constants: no randomness, no engine state,
# so resolving a turn is a function of (world state, plans) alone.
#
# STATES AND REQUESTS are Dictionaries, so the World, the UI and tests can
# build and read them without this class:
#   state:   {x, y, heading, speed, altitude_band}    metres, radians, m/s
#   request: {turn: rad, speed: m/s, altitude_band}   any key may be left out:
#            no turn = fly straight, no speed = hold the current speed,
#            no band = stay; an empty request is "carry on" (inertia, not a stop)
#        or  {to: Vector2 | [x, y], altitude_band}    steer for a point
#        or  a bare Vector2                           the same as {to: point}
#   result:  the state after the step, plus turn (the heading change applied),
#            clamped (bool) and limits (which limits bit: turn, speed, band,
#            climb). Feeding a result back in as a request returns the same
#            state: clamp_step is idempotent.
#
# THE MOTION MODEL (proposed, Track S 2026-10-09):
#   - All limits are read from the state at the START of the step: the turn
#     rate at the starting speed, the speed window around the starting speed.
#   - Heading changes by at most turn_rate(speed) x step_dt either way.
#   - Speed changes by at most accel x step_dt up, decel x step_dt down
#     (rates per second, so retuning the turn length does not retune the
#     planes), minus the cost of the manoeuvre: turn bleed (scaled by
#     (turn used / turn available)^exponent), climb cost per band; plus dive
#     gain per band.
#   - Range rules: above speed_max (after a dive) a unit sheds speed at its
#     full deceleration; a dive may carry it up to dive_speed_max. NO STALL
#     YET: a unit at or above speed_min never drops below it -- a hard turn at
#     minimum speed costs nothing more (proposed; a stall rule is an open
#     question). A unit below speed_min (only a plane spawned slow) accelerates
#     toward it at full power. A climb the unit cannot afford without falling
#     below speed_min is refused. With reverse_from_stop, speed cannot cross
#     zero within a step.
#   - The path of a step is a CIRCULAR ARC: constant turn rate, length
#     (v_start + v_end) / 2 x step_dt. point_on_step() walks the same arc, so a
#     drawn path and an animated unit land exactly where the step ends.
#
# TRIG IS JsMath'S (scripts/core/js_math.gd, pure GDScript fdlibm), not the
# engine's: the engine's sin/cos/atan2 come from each platform's C runtime, and
# networked co-op will want every peer to resolve the same turn to the same
# bits (the design doc's Steering and specials section already proposes seeded
# disturbances for that reason). sqrt and the arithmetic are IEEE-exact.

const JsMath = preload("res://scripts/core/js_math.gd")

const LIMIT_TURN := "turn"
const LIMIT_SPEED := "speed"
const LIMIT_BAND := "band"
const LIMIT_CLIMB := "climb"

var speed_min: float
var speed_cruise: float
var speed_max: float
var dive_speed_max: float
var accel: float
var decel: float
var reverse_from_stop: bool
var curve_speeds: PackedFloat64Array      # m/s, strictly increasing
var curve_rates: PackedFloat64Array       # rad/s
var turn_bleed: float
var turn_bleed_exponent: float
var bands: Array[String] = []             # this unit's bands, bottom first
var start_band: String
var bands_per_step: int
var climb_cost: float
var dive_gain: float

# `p`: the envelope section as unit_def.gd unwraps it (plain values; the curve
# as [speeds, degrees_per_second] PackedFloat64Arrays). `band_order`: every
# band id, bottom first (data/sim/altitude.json), which puts this unit's own
# bands in vertical order whatever order its file lists them in.
func _init(p: Dictionary, band_order: Array) -> void:
	speed_min = float(p.get("speed_min_mps", NAN))
	speed_cruise = float(p.get("speed_cruise_mps", NAN))
	speed_max = float(p.get("speed_max_mps", NAN))
	dive_speed_max = float(p.get("dive_speed_max_mps", NAN))
	accel = float(p.get("accel_mps2", NAN))
	decel = float(p.get("decel_mps2", NAN))
	reverse_from_stop = p.get("reverse_from_stop", false) == true
	var c: Array = p.get("turn_rate_curve_dps", [PackedFloat64Array(), PackedFloat64Array()])
	curve_speeds = c[0]
	curve_rates = PackedFloat64Array()
	for dps: float in (c[1] as PackedFloat64Array):
		curve_rates.append(deg_to_rad(dps))
	turn_bleed = float(p.get("turn_bleed_mps2", NAN))
	turn_bleed_exponent = float(p.get("turn_bleed_exponent", NAN))
	var allowed: Array = p.get("altitude_bands", [])
	for id: Variant in band_order:
		if allowed.has(id):
			bands.append(str(id))
	start_band = str(p.get("start_band", ""))
	bands_per_step = int(p.get("bands_per_step", 0))
	climb_cost = float(p.get("climb_speed_cost_mps", NAN))
	dive_gain = float(p.get("dive_speed_gain_mps", NAN))

# --- Envelope functions ------------------------------------------------------

# Largest heading change per second at `speed` (absolute speed when
# reversing): straight-line interpolation along the data's curve, held flat
# past either end.
func turn_rate(speed: float) -> float:
	var s := absf(speed)
	var n := curve_speeds.size()
	if n == 0:
		return 0.0
	if s <= curve_speeds[0]:
		return curve_rates[0]
	for i in range(1, n):
		if s <= curve_speeds[i]:
			var f := (s - curve_speeds[i - 1]) / (curve_speeds[i] - curve_speeds[i - 1])
			return curve_rates[i - 1] + (curve_rates[i] - curve_rates[i - 1]) * f
	return curve_rates[n - 1]

# Radius of the tightest sustained circle at `speed`; INF when the unit cannot
# turn at that speed (a ship with no way on).
func turn_radius(speed: float) -> float:
	var rate := turn_rate(speed)
	if rate <= 0.0:
		return INF
	return absf(speed) / rate

# Speed lost to a turn of `turn` radians when `turn_max` is available.
func turn_loss(turn: float, turn_max: float, step_dt: float) -> float:
	if turn_max <= 0.0 or turn == 0.0:
		return 0.0
	return turn_bleed * pow(minf(absf(turn) / turn_max, 1.0), turn_bleed_exponent) * step_dt

# The end speeds reachable in one step from `v0`, after a manoeuvre that costs
# `loss` m/s (negative = a gain, as in a dive), with `upper` the ceiling this
# step (speed_max, or dive_speed_max when diving). Returns [lo, hi], lo <= hi.
func speed_window(v0: float, step_dt: float, loss: float, upper: float) -> PackedFloat64Array:
	var lo := v0 - decel * step_dt - loss
	var hi := v0 + accel * step_dt - loss
	# Over the ceiling (after a dive): the only way is down, at full deceleration.
	if lo > upper:
		hi = lo
	else:
		hi = minf(hi, upper)
	# The floor. No stall rule yet (proposed): from at or above speed_min the
	# unit never ends below it; from below it (a plane spawned slow) it gains
	# what it can toward it.
	if hi < speed_min:
		lo = minf(speed_min, maxf(v0, hi))
		hi = lo
	else:
		lo = maxf(lo, speed_min)
	# Ships and tanks: come to a stop before reversing, and the other way round.
	if reverse_from_stop:
		if v0 > 0.0:
			lo = maxf(lo, 0.0)
		elif v0 < 0.0:
			hi = minf(hi, 0.0)
	return PackedFloat64Array([lo, hi])

# What the unit can do this step, for the planning UI and the AI:
#   turn_max         largest heading change either way (rad)
#   turn_rate        rad/s at the starting speed;  turn_radius  m (INF if none)
#   speed_lo/hi      end-speed window flying straight in the same band
#   speed_lo_full_turn / speed_hi_full_turn   the same at the full turn
#   bands            band ids reachable this step (the current one included)
#   outline          the region of reachable end POSITIONS in the same band, a
#                    closed polygon: the far edge (fastest) from full left to
#                    full right, then the near edge (slowest) back. Drawing
#                    data, hence float32 Vector2.
func reachable(state: Dictionary, step_dt: float, outline_samples: int = 9) -> Dictionary:
	var x := _num(state, "x")
	var y := _num(state, "y")
	var h0 := _num(state, "heading")
	var v0 := _num(state, "speed")
	var band0 := str(state.get("altitude_band", ""))
	var rate := turn_rate(v0)
	var turn_max := rate * step_dt
	var straight := speed_window(v0, step_dt, 0.0, speed_max)
	var full := speed_window(v0, step_dt, turn_loss(turn_max, turn_max, step_dt), speed_max)

	var reach_bands: Array[String] = []
	var pos0 := bands.find(band0)
	if pos0 >= 0:
		for i in bands.size():
			var d := i - pos0
			if absi(d) > bands_per_step:
				continue
			if d > 0 and v0 + accel * step_dt - climb_cost * float(d) < speed_min:
				continue
			reach_bands.append(bands[i])

	var far := PackedVector2Array()
	var near := PackedVector2Array()
	var n := maxi(outline_samples, 2)
	for i in n:
		var t := -turn_max + 2.0 * turn_max * float(i) / float(n - 1)
		var w := speed_window(v0, step_dt, turn_loss(t, turn_max, step_dt), speed_max)
		var a := advance(x, y, h0, t, (v0 + w[1]) * 0.5 * step_dt)
		var b := advance(x, y, h0, t, (v0 + w[0]) * 0.5 * step_dt)
		far.append(Vector2(a[0], a[1]))
		near.append(Vector2(b[0], b[1]))
	near.reverse()
	far.append_array(near)

	return {
		"step_dt": step_dt,
		"speed": v0,
		"turn_max": turn_max,
		"turn_rate": rate,
		"turn_radius": turn_radius(v0),
		"speed_lo": straight[0],
		"speed_hi": straight[1],
		"speed_lo_full_turn": full[0],
		"speed_hi_full_turn": full[1],
		"bands": reach_bands,
		"outline": far,
	}

# The state after one step: the request clamped into the envelope.
func clamp_step(state: Dictionary, request: Variant, step_dt: float) -> Dictionary:
	var req := normalize_request(request)
	var x := _num(state, "x")
	var y := _num(state, "y")
	var h0 := _num(state, "heading")
	var v0 := _num(state, "speed")
	var band0 := str(state.get("altitude_band", ""))
	var limits: Array[String] = []

	# Band: at most bands_per_step places along this unit's own bands.
	var pos0 := bands.find(band0)
	var delta := 0
	if req.has("altitude_band"):
		var want := str(req["altitude_band"])
		var pos1 := bands.find(want)
		if pos0 < 0 or pos1 < 0:
			if want != band0:
				limits.append(LIMIT_BAND)
		else:
			delta = clampi(pos1 - pos0, -bands_per_step, bands_per_step)
			if delta != pos1 - pos0:
				limits.append(LIMIT_BAND)

	# Turn: from the request, or from the target point (see below).
	var turn_max := turn_rate(v0) * step_dt
	var turn := 0.0
	var v_req := v0
	var to_point := req.has("to")
	var dx := 0.0
	var dy := 0.0
	if to_point:
		var p := _point(req["to"])
		dx = p[0] - x
		dy = p[1] - y
		# A circular arc's chord leaves at half the arc's heading change, so the
		# arc through the point turns by twice the angle to it.
		if dx != 0.0 or dy != 0.0:
			turn = 2.0 * wrap_angle(JsMath.atan2(dy, dx) - h0)
	else:
		turn = float(req.get("turn", 0.0))
		v_req = float(req.get("speed", v0))
	var turn_c := clampf(turn, -turn_max, turn_max)
	if turn_c != turn:
		limits.append(LIMIT_TURN)
	turn = turn_c
	if to_point:
		# With the turn settled, the arc's end lies on the chord ray from the
		# unit at heading h0 + turn/2, at distance length x sinc(turn/2). Aim
		# for the point on that ray closest to the target (never backwards).
		var a := h0 + turn * 0.5
		var s := maxf(0.0, dx * JsMath.cos(a) + dy * JsMath.sin(a))
		v_req = 2.0 * (s / sinc(turn * 0.5)) / step_dt - v0

	# Speed: inertia window, shifted by what the manoeuvre costs.
	var bleed := turn_loss(turn, turn_max, step_dt)
	if delta > 0 and v0 + accel * step_dt - bleed - climb_cost * float(delta) < speed_min:
		delta = 0
		limits.append(LIMIT_CLIMB)
	var loss := bleed + climb_cost * float(maxi(delta, 0)) - dive_gain * float(maxi(-delta, 0))
	var upper := dive_speed_max if delta < 0 else speed_max
	var w := speed_window(v0, step_dt, loss, upper)
	var v1 := clampf(v_req, w[0], w[1])
	if v1 != v_req:
		limits.append(LIMIT_SPEED)

	var band1 := band0 if delta == 0 else bands[pos0 + delta]
	var end := advance(x, y, h0, turn, (v0 + v1) * 0.5 * step_dt)
	return {
		"x": end[0],
		"y": end[1],
		"heading": wrap_angle(h0 + turn),
		"speed": v1,
		"altitude_band": band1,
		"turn": turn,
		"clamped": not limits.is_empty(),
		"limits": limits,
	}

# --- Path geometry (static: the World and the UI use it without an envelope) --

# Where a unit is a fraction `f` (0..1) of the way through a step from `from`
# to `to` (`to` as clamp_step returned it, with its `turn`): the same circular
# arc, walked at the step's average speed. At f = 1 this is exactly `to`.
static func point_on_step(from: Dictionary, to: Dictionary, step_dt: float, f: float) -> Dictionary:
	var v0 := _num(from, "speed")
	var v1 := _num(to, "speed")
	var turn := _num(to, "turn")
	var h0 := _num(from, "heading")
	var p := advance(_num(from, "x"), _num(from, "y"), h0, turn * f, (v0 + v1) * 0.5 * step_dt * f)
	return {
		"x": p[0],
		"y": p[1],
		"heading": wrap_angle(h0 + turn * f),
		"speed": v0 + (v1 - v0) * f,
	}

# The end of a circular arc of length `dist` that starts at (x, y) heading `h`
# and turns by `turn`: the chord is dist x sinc(turn/2) long, at h + turn/2.
static func advance(x: float, y: float, h: float, turn: float, dist: float) -> PackedFloat64Array:
	var half := turn * 0.5
	var chord := dist * sinc(half)
	var a := h + half
	return PackedFloat64Array([x + chord * JsMath.cos(a), y + chord * JsMath.sin(a)])

static func sinc(a: float) -> float:
	if absf(a) < 1e-6:
		return 1.0 - a * a / 6.0
	return JsMath.sin(a) / a

# An angle in [-PI, PI).
static func wrap_angle(a: float) -> float:
	return a - TAU * floorf((a + PI) / TAU)

# --- Requests ----------------------------------------------------------------

static func normalize_request(request: Variant) -> Dictionary:
	if request is Vector2:
		return {"to": request}
	if request is Dictionary:
		return request
	return {}

# "" if `request` is something clamp_step accepts, else what is wrong with it.
static func request_error(request: Variant) -> String:
	if request is Vector2:
		return "" if (request as Vector2).is_finite() else "the target point is not finite"
	if not (request is Dictionary):
		return "a request is a Dictionary or a Vector2 target point, got %s" % type_string(typeof(request))
	var r: Dictionary = request
	if r.has("to"):
		var p := _point(r["to"])
		if not (is_finite(p[0]) and is_finite(p[1])):
			return "'to' must be a Vector2 or [x, y] of finite numbers, got %s" % str(r["to"])
	for k: String in ["turn", "speed"]:
		if r.has(k) and not ((r[k] is float or r[k] is int) and is_finite(float(r[k]))):
			return "'%s' must be a finite number, got %s" % [k, str(r[k])]
	if r.has("altitude_band") and not (r["altitude_band"] is String):
		return "'altitude_band' must be a band id string, got %s" % str(r["altitude_band"])
	return ""

static func _point(v: Variant) -> PackedFloat64Array:
	if v is Vector2:
		return PackedFloat64Array([(v as Vector2).x, (v as Vector2).y])
	if (v is Array or v is PackedFloat64Array or v is PackedFloat32Array or v is PackedInt32Array) and v.size() >= 2 \
			and (v[0] is float or v[0] is int) and (v[1] is float or v[1] is int):
		return PackedFloat64Array([float(v[0]), float(v[1])])
	return PackedFloat64Array([NAN, NAN])

static func _num(d: Dictionary, key: String) -> float:
	var v: Variant = d.get(key, NAN)
	if v is float or v is int:
		return float(v)
	return NAN
