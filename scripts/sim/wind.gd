extends RefCounted

# THE COASTAL WIND (decision coastal-wind, 2026-10-11; numbers data/sim/wind.json). ALEX: "We also need a slight wind or variety over time. What is the
# natural pattern near the coast?" and, on the lead's answer, "1-3 looks good": a sea breeze by day, a weaker land breeze at night, calms at dawn and
# dusk, a slow wander and short gusts on top, the same for every player; all smoke drifts with it, fire spreads further downwind, the untrackable smoke
# zone moves with the smoke. Planes and bombs are not moved by it (Alex: "for now"). Every detail he did not say is PROPOSED, in the data.
#
#   var wind := Wind.for_mission(centre, Callable(water, "sea_s"), seed, bounds)    # the scenario builder's call (sandbox_scenario.gd)
#   wind.at(game_s) -> Vector2       the air's velocity, m/s, ON THE MAP'S AXES: x east (right), y south (down), the units' own x and y. game_s is game
#                                    seconds from the start of the game, (turn - 1) x turn_seconds + t (reveal.gd, fire.gd). A pure function of the Wind's
#                                    inputs: no random state is consumed by a query, so any peer, in any order, gets the same answer.
#   wind.mean() -> Vector2           the regime's mean wind (no wander, no gust): the sea breeze blows from the sea, so it points away from it
#   wind.params() -> Dictionary      the defining parameters, plain values, the wire's: {hour, toward_sea: [x, y] | [], seed, v}
#   Wind.from_params(d) -> Wind      the very same wind from them, on any peer (its numbers are the data's, the same files everywhere)
#
# THE MODEL. level(hour) is a number from -1 (the night's land breeze) through 0 (a calm) to +1 (the day's sea breeze), a smoothstep through the
# schedule of the data; the mean speed is level x the middle of Alex's day range (2-5 m/s: 3.5) or night range (1-3 m/s: 2). The mean points away from
# the sea (onshore: from the sea toward the battle area) by day and toward it (offshore) at night. On top, all seeded:
#   direction  wanders +/-15 degrees and speed +/-30% (Alex), over a few turns, as smooth functions of the game second (two sine waves, seeded phases,
#              scaled so that they never leave -1..+1: the limits are exact)
#   gusts      short bumps (sin squared), at most one in each window of a few seconds, whose moment, length and size are seeded by the window's number
#   calm       as the mean speed falls under calm.below_mps the wind becomes a weak air (calm.speed_mps) whose direction wanders by up to calm.wander_deg
#              round a seeded bearing: "near calm at dawn and dusk, with a wandering direction" (Alex). Continuous in the hour.
# THE HOUR is taken once, at the mission start, as the sun is: Sun.current().asked_hour when the sun's mode is clock_at_start, else data fixed_hour
# (mid-afternoon, PROPOSED). This file reads the sun only through scripts/world/sun.gd. THE SEA: the direction in which the sea lies from the mission's
# centre is the mean of the directions of the sea samples on rings round it (PROPOSED method; WaterGen.sea_s, deep water only). With no sea in reach a
# light prevailing wind blows from a fixed bearing instead, with the same wander and gusts.
#
# THE WIRE. The hour may come from each machine's own clock, so a client never derives its wind: the host's params() travel in the snapshot and in every
# turn result (World.net_wind / apply_net_wind), and a client builds its Wind from them. All the trigonometry is scripts/core/js_math.gd's, so the result is
# the same on every platform.

const Records = preload("res://scripts/sim/records.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const JsMath = preload("res://scripts/core/js_math.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const Sun = preload("res://scripts/world/sun.gd")

const PATH := "res://data/sim/wind.json"
const SELF := "res://scripts/sim/wind.gd"
const VERSION := 1
const TAG := 0x57494E44           # "WIND"
const CH_DIR := 0
const CH_SPEED := 1
const CH_CALM := 2
const KIND_PHASE := 1
const KIND_CALM_BEARING := 2
const KIND_GUST := 3
const KNOWN := {
	"fixed_hour": null, "day": ["range_mps"], "night": ["range_mps"], "schedule": null,
	"calm": ["speed_mps", "below_mps", "wander_deg"],
	"wander": ["direction_deg", "speed_frac", "period_s", "second_ratio", "second_weight"],
	"gusts": ["window_s", "chance", "length_s", "size_min", "size_frac"],
	"sea": ["ring_radii_m", "directions", "deep_m", "min_hits", "min_bias"],
	"prevailing": ["from_bearing_deg", "speed_mps"],
}

# --- The data ---------------------------------------------------------------------------------------------
var errors: Array[String] = []
var fixed_hour: float = NAN
var day_min: float = NAN
var day_max: float = NAN
var night_min: float = NAN
var night_max: float = NAN
var sched_hour := PackedFloat64Array()
var sched_level := PackedFloat64Array()
var calm_speed: float = NAN
var calm_below: float = NAN
var calm_wander_deg: float = NAN
var wander_dir_deg: float = NAN
var wander_speed_frac: float = NAN
var wander_period_s: float = NAN
var wander_second_ratio: float = NAN
var wander_second_weight: float = NAN
var gust_window_s: float = NAN
var gust_chance: float = NAN
var gust_len_min: float = NAN
var gust_len_max: float = NAN
var gust_size_min: float = NAN
var gust_size_frac: float = NAN
var sea_radii := PackedFloat64Array()
var sea_directions: int = 0
var sea_deep_m: float = NAN
var sea_min_hits: int = 0
var sea_min_bias: float = NAN
var prevailing_from_deg: float = NAN
var prevailing_mps: float = NAN

# --- The defining parameters (params()) and what they make ---------------------------------------------------
var hour: float = NAN             # the local hour the regime was taken at, 0..24
var seed_value: int = 0
var configured := false
var has_sea := false
var _tsx := 0.0                   # the unit vector from the battle area toward the sea (doubles: they travel exactly)
var _tsy := 0.0
var _level := 0.0                 # -1 night .. +1 day
var _mean_mps := 0.0              # signed: > 0 onshore, < 0 offshore (the sea breeze case); the prevailing speed otherwise
var _mx := 0.0                    # the mean wind, doubles
var _my := 0.0
var _calm_w := 0.0                # how much of the wind is the wandering calm air: 1 at a calm, 0 from calm.below_mps up
var _calm_bearing := 0.0          # the bearing the calm air's direction wanders round, radians
var _phase: Array = []            # per channel [phase of the first wave, of the second], radians
var _gust_cache: Dictionary = {}  # window number -> [start, length, size] or null (a cache only: an answer never depends on it)

# --- Making one ------------------------------------------------------------------------------------------------

# `params`: params()'s dictionary, or {} for a Wind that has only its data (for_mission fills it in). `source`: the data's path or a Dictionary.
func _init(params: Dictionary = {}, source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<wind dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a wind source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		_read(r, data as Dictionary)
	errors = r.errors
	if not params.is_empty() and errors.is_empty():
		configure(params)

static func _make(params: Dictionary, source: Variant, quiet: bool) -> RefCounted:
	return (load(SELF) as GDScript).new(params, source, quiet)

# The Wind of a mission: where the sea lies from `centre` (sea_fn: Callable (x, y) -> metres of sea water, > 0 in the sea; invalid: no sea), the hour from the
# sun (or `hour_override` when it is finite), `seed_v` the game's. `bounds`: a non-empty Rect2 keeps the sea samples on the map.
static func for_mission(centre: Vector2, sea_fn: Callable, seed_v: int, bounds: Rect2 = Rect2(), source: Variant = PATH, hour_override: float = NAN, quiet: bool = false) -> RefCounted:
	var w: RefCounted = _make({}, source, quiet)
	if not w.ok():
		return w
	var h: float = hour_override if is_finite(hour_override) else float(w.mission_hour())
	var toward: Array = []
	if sea_fn.is_valid():
		var found: Dictionary = w.find_sea(centre, sea_fn, bounds)
		if bool(found["found"]):
			toward = found["toward"]
	w.configure({"hour": h, "toward_sea": toward, "seed": seed_v, "v": VERSION})
	return w

# The very same wind on another machine, from the host's params().
static func from_params(params: Dictionary, source: Variant = PATH, quiet: bool = false) -> RefCounted:
	return _make(params, source, quiet)

func ok() -> bool:
	return errors.is_empty()

# The hour the mission's wind is taken at: the sun's own asked hour when its mode is clock_at_start (decision sun-time: picked once at the mission start),
# else fixed_hour. The only place the sun is read, and only through sun.gd.
func mission_hour() -> float:
	var sun: RefCounted = Sun.current()
	if str(sun.mode) == "clock_at_start":
		return fposmod(float(sun.asked_hour), 24.0)
	return fixed_hour

# Where the sea lies from `centre`: the mean direction of the samples on rings round it that hold deep sea water. {found: bool, toward: [x, y] (a unit
# vector on the map's axes), bias: the length of the mean of the unit directions (1 when the sea is all on one side, 0 when it surrounds), hits}.
func find_sea(centre: Vector2, sea_fn: Callable, bounds: Rect2 = Rect2()) -> Dictionary:
	var sx := 0.0
	var sy := 0.0
	var hits := 0
	for radius: float in sea_radii:
		for k in sea_directions:
			var ang := TAU * float(k) / float(sea_directions)
			var dx := JsMath.cos(ang)
			var dy := JsMath.sin(ang)
			var px := float(centre.x) + dx * radius
			var py := float(centre.y) + dy * radius
			if bounds.has_area() and not bounds.has_point(Vector2(px, py)):
				continue
			if float(sea_fn.call(px, py)) >= sea_deep_m:
				sx += dx
				sy += dy
				hits += 1
	if hits < sea_min_hits:
		return {"found": false, "toward": [], "bias": 0.0, "hits": hits}
	var len := JsMath.hypot(sx, sy)
	var bias := len / float(hits)
	if bias < sea_min_bias or len <= 0.0:
		return {"found": false, "toward": [], "bias": bias, "hits": hits}
	return {"found": true, "toward": [sx / len, sy / len], "bias": bias, "hits": hits}

# Give the Wind its defining parameters (params()). False, with an error recorded, if they are not a valid set.
func configure(p: Dictionary) -> bool:
	if not errors.is_empty():
		return false
	if not (p.get("hour") is float or p.get("hour") is int) or not (p.get("seed") is int or p.get("seed") is float):
		errors.append("wind params need a number 'hour' and a 'seed': %s" % str(p))
		return false
	hour = fposmod(float(p["hour"]), 24.0)
	seed_value = int(p["seed"])
	var ts: Variant = p.get("toward_sea", [])
	has_sea = false
	_tsx = 0.0
	_tsy = 0.0
	if ts is Array and (ts as Array).size() == 2:
		var tx := float((ts as Array)[0])
		var ty := float((ts as Array)[1])
		var l := JsMath.hypot(tx, ty)
		if l > 0.0:
			has_sea = true
			_tsx = tx / l
			_tsy = ty / l
	# the regime
	if has_sea:
		_level = level_at(hour)
		var mid_day := 0.5 * (day_min + day_max)
		var mid_night := 0.5 * (night_min + night_max)
		_mean_mps = _level * mid_day if _level >= 0.0 else _level * mid_night   # (> 0 onshore, < 0 offshore)
		_mx = -_tsx * _mean_mps   # onshore blows away from the sea
		_my = -_tsy * _mean_mps
		_calm_w = clampf(1.0 - absf(_mean_mps) / calm_below, 0.0, 1.0)
	else:
		_level = 0.0
		var to_b := deg_to_rad(prevailing_from_deg + 180.0)   # the bearing it blows TOWARD
		_mean_mps = prevailing_mps
		_mx = JsMath.sin(to_b) * prevailing_mps    # north is -y, east is +x
		_my = -JsMath.cos(to_b) * prevailing_mps
		_calm_w = 0.0
	# the seeded phases of the waves, per channel, and the calm air's bearing
	_phase = []
	for ch in 3:
		var rng := Mulberry32.new(_seed(KIND_PHASE, ch))
		_phase.append([rng.next() * TAU, rng.next() * TAU])
	_calm_bearing = Mulberry32.new(_seed(KIND_CALM_BEARING, 0)).next() * TAU
	_gust_cache.clear()
	configured = true
	return true

# The wire's: plain values that make this very wind on any machine (from_params).
func params() -> Dictionary:
	return {"hour": hour, "toward_sea": [_tsx, _tsy] if has_sea else [], "seed": seed_value, "v": VERSION}

func _seed(kind: int, key: int) -> int:
	var s := (seed_value & 0xFFFFFFFF) ^ ((seed_value >> 32) & 0xFFFFFFFF)
	for part: int in [TAG, kind, key]:
		s = Combat.mix32(s, part)
	return s

# --- The queries ------------------------------------------------------------------------------------------------------

# The air's velocity at a game second, m/s, on the map's axes (x east, y south). Vector2.ZERO for a Wind that was not given its params.
func at(game_s: float) -> Vector2:
	if not configured:
		return Vector2.ZERO
	var p := parts(game_s)
	var ang: float = float(p["dir_deg"]) * PI / 180.0
	var scale: float = float(p["speed_scale"])
	var c := JsMath.cos(ang)
	var s := JsMath.sin(ang)
	var x := (_mx * c - _my * s) * scale
	var y := (_mx * s + _my * c) * scale
	if _calm_w > 0.0:
		var psi: float = _calm_bearing + calm_wander_deg * PI / 180.0 * float(p["calm_n"])
		var cs := calm_speed * _calm_w * scale
		x += JsMath.cos(psi) * cs
		y += JsMath.sin(psi) * cs
	return Vector2(x, y)

# The regime's mean wind: the sea breeze (from the sea toward the battle area) by day, the land breeze by night, nothing but the weak calm air at dawn and
# dusk, the prevailing wind with no sea. No wander, no gust.
func mean() -> Vector2:
	return Vector2(_mx, _my) if configured else Vector2.ZERO

# The parts of the wind at a game second, for the tests and the effects: {dir_deg: the wander of the direction, within +/-wander.direction_deg;
# speed_frac: the wander of the speed, within +/-wander.speed_frac; gust: the gust's share, 0..gusts.size_frac; speed_scale: 1 + speed_frac + gust;
# calm_n: the calm air's direction wander, -1..1}.
func parts(game_s: float) -> Dictionary:
	var nd := _noise(CH_DIR, game_s)
	var ns := _noise(CH_SPEED, game_s)
	var nc := _noise(CH_CALM, game_s)
	var gust := gust_size_frac * _gust(game_s)
	var sf := wander_speed_frac * ns
	return {"dir_deg": wander_dir_deg * nd, "speed_frac": sf, "gust": gust, "speed_scale": 1.0 + sf + gust, "calm_n": nc}

# The regime level at an hour: -1 (full night), 0 (calm) .. +1 (full day), a smoothstep between the schedule's points.
func level_at(h: float) -> float:
	var hh := fposmod(h, 24.0)
	var n := sched_hour.size()
	for i in range(1, n):
		if hh <= sched_hour[i]:
			var span := sched_hour[i] - sched_hour[i - 1]
			var u := 0.0 if span <= 0.0 else clampf((hh - sched_hour[i - 1]) / span, 0.0, 1.0)
			var e := u * u * (3.0 - 2.0 * u)
			return sched_level[i - 1] + (sched_level[i] - sched_level[i - 1]) * e
	return sched_level[n - 1]

# The regime's signed mean speed (m/s): > 0 onshore (day), < 0 offshore (night).
func mean_speed_mps() -> float:
	return _mean_mps

func level() -> float:
	return _level

# The unit vector from the battle area toward the sea (Vector2.ZERO with no sea).
func toward_sea() -> Vector2:
	return Vector2(_tsx, _tsy)

# The unit vector the sea breeze blows along: from the sea toward the battle area.
func onshore() -> Vector2:
	return Vector2(-_tsx, -_tsy)

# The most this wind can blow, m/s (the wander and the biggest gust at the top, the calm air added): a bound for a search radius.
func speed_bound() -> float:
	return (absf(_mean_mps) + calm_speed * _calm_w) * (1.0 + wander_speed_frac + gust_size_frac)

func describe() -> String:
	var m := mean()
	return "wind: hour %.1f, %s, mean %.1f m/s toward (%.2f, %.2f)%s" % [hour, "level %.2f" % _level if has_sea else "prevailing", m.length(), m.x, m.y, " (sea breeze)" if has_sea and _mean_mps > 0.0 else ""]

# --- The wander and the gusts -------------------------------------------------------------------------------------------

# A smooth seeded function of the game second, never outside -1..+1: two sine waves (the second of a shorter period) with seeded phases.
func _noise(ch: int, g: float) -> float:
	var ph: Array = _phase[ch] if configured else [0.0, 0.0]
	var a := JsMath.sin(TAU * g / wander_period_s + float(ph[0]))
	var b := JsMath.sin(TAU * g / (wander_period_s * wander_second_ratio) + float(ph[1]))
	return clampf((a + wander_second_weight * b) / (1.0 + wander_second_weight), -1.0, 1.0)

# The gust at a game second, 0..1: the one gust of this second's window, if it has one, a sin-squared bump of its size.
func _gust(g: float) -> float:
	if not configured:
		return 0.0
	var k := floori(maxf(g, 0.0) / gust_window_s)
	var rec: Variant
	if _gust_cache.has(k):
		rec = _gust_cache[k]
	else:
		var rng := Mulberry32.new(Combat.mix32(_seed(KIND_GUST, 0), k))
		var roll := rng.next()
		var len := gust_len_min + (gust_len_max - gust_len_min) * rng.next()
		var start := rng.next() * maxf(gust_window_s - len, 0.0)
		var size := gust_size_min + (1.0 - gust_size_min) * rng.next()
		rec = [start, len, size] if roll < gust_chance else null
		_gust_cache[k] = rec
	if rec == null:
		return 0.0
	var x: float = maxf(g, 0.0) - float(k) * gust_window_s - float((rec as Array)[0])
	var l: float = float((rec as Array)[1])
	if x < 0.0 or x > l:
		return 0.0
	var sn := JsMath.sin(PI * x / l)
	return float((rec as Array)[2]) * sn * sn

# --- Reading the data ------------------------------------------------------------------------------------------------------

func _read(r: Records, d: Dictionary) -> void:
	fixed_hour = r.number(d, "fixed_hour", "fixed_hour", 0.0, 24.0)
	var dy := r.section(d, "day", "day")
	var dr := _pair(r, dy, "range_mps", "day.range_mps")
	day_min = dr[0]
	day_max = dr[1]
	var ng := r.section(d, "night", "night")
	var nr := _pair(r, ng, "range_mps", "night.range_mps")
	night_min = nr[0]
	night_max = nr[1]
	_read_schedule(r, d)
	var cm := r.section(d, "calm", "calm")
	calm_speed = r.number(cm, "speed_mps", "calm.speed_mps", 0.0)
	calm_below = r.number(cm, "below_mps", "calm.below_mps", 0.001)
	calm_wander_deg = r.number(cm, "wander_deg", "calm.wander_deg", 0.0, 180.0)
	var wd := r.section(d, "wander", "wander")
	wander_dir_deg = r.number(wd, "direction_deg", "wander.direction_deg", 0.0, 180.0)
	wander_speed_frac = r.number(wd, "speed_frac", "wander.speed_frac", 0.0, 0.9)
	wander_period_s = r.number(wd, "period_s", "wander.period_s", 1.0)
	wander_second_ratio = r.number(wd, "second_ratio", "wander.second_ratio", 0.05, 1.0)
	wander_second_weight = r.number(wd, "second_weight", "wander.second_weight", 0.0, 1.0)
	var gs := r.section(d, "gusts", "gusts")
	gust_window_s = r.number(gs, "window_s", "gusts.window_s", 1.0)
	gust_chance = r.number(gs, "chance", "gusts.chance", 0.0, 1.0)
	var gl := _pair(r, gs, "length_s", "gusts.length_s")
	gust_len_min = gl[0]
	gust_len_max = gl[1]
	gust_size_min = r.number(gs, "size_min", "gusts.size_min", 0.0, 1.0)
	gust_size_frac = r.number(gs, "size_frac", "gusts.size_frac", 0.0, 1.0)
	var se := r.section(d, "sea", "sea")
	sea_radii = _numbers(r, se, "ring_radii_m", "sea.ring_radii_m")
	sea_directions = r.integer(se, "directions", "sea.directions", 3)
	sea_deep_m = r.number(se, "deep_m", "sea.deep_m", 0.0)
	sea_min_hits = r.integer(se, "min_hits", "sea.min_hits", 1)
	sea_min_bias = r.number(se, "min_bias", "sea.min_bias", 0.0, 1.0)
	var pv := r.section(d, "prevailing", "prevailing")
	prevailing_from_deg = r.number(pv, "from_bearing_deg", "prevailing.from_bearing_deg", 0.0, 360.0)
	prevailing_mps = r.number(pv, "speed_mps", "prevailing.speed_mps", 0.0)
	for key: Variant in d:
		var k := str(key)
		if not k.begins_with("_") and not KNOWN.has(k):
			r.err("unknown field '%s' (misspelt?)" % k)
	for sec: String in KNOWN:
		if KNOWN[sec] is Array and d.get(sec) is Dictionary:
			for key: Variant in (d[sec] as Dictionary):
				var k2 := str(key)
				if not k2.begins_with("_") and not (KNOWN[sec] as Array).has(k2):
					r.err("unknown field '%s.%s' (misspelt?)" % [sec, k2])
	# THE WANDER AND THE GUSTS MUST KEEP THE SPEED INSIDE ALEX'S RANGES (day 2-5, night 1-3 m/s) at the middle of each regime
	if r.ok():
		var up := 1.0 + wander_speed_frac + gust_size_frac
		var dn := 1.0 - wander_speed_frac
		var mid_d := 0.5 * (day_min + day_max)
		var mid_n := 0.5 * (night_min + night_max)
		if mid_d * up > day_max + 1e-9 or mid_d * dn < day_min - 1e-9:
			r.err("the wander (+/-%s) and the biggest gust (%s) would take the day wind (mean %s m/s) out of its range %s..%s m/s" % [wander_speed_frac, gust_size_frac, mid_d, day_min, day_max])
		if mid_n * up > night_max + 1e-9 or mid_n * dn < night_min - 1e-9:
			r.err("the wander (+/-%s) and the biggest gust (%s) would take the night wind (mean %s m/s) out of its range %s..%s m/s" % [wander_speed_frac, gust_size_frac, mid_n, night_min, night_max])
		if calm_speed * up >= 1.0:
			r.err("the calm air (%s m/s with its wander and gusts: %s) is not near calm (under about 1 m/s)" % [calm_speed, calm_speed * up])
		if gust_len_min > gust_len_max or gust_len_max > gust_window_s:
			r.err("gusts.length_s must be min <= max <= the window (%s s)" % gust_window_s)

func _read_schedule(r: Records, d: Dictionary) -> void:
	var v: Variant = r.record(d, "schedule", "schedule")
	sched_hour = PackedFloat64Array()
	sched_level = PackedFloat64Array()
	if typeof(v) == TYPE_NIL:
		return
	if not (v is Array) or (v as Array).size() < 2:
		r.err("'schedule' must be a list of at least two [hour, level] pairs")
		return
	for p: Variant in (v as Array):
		if not (p is Array) or (p as Array).size() != 2 or not Records.is_number((p as Array)[0]) or not Records.is_number((p as Array)[1]):
			r.err("'schedule' has an entry that is not [hour, level]: %s" % str(p))
			continue
		var h := float((p as Array)[0])
		var lv := float((p as Array)[1])
		if lv < -1.0 or lv > 1.0:
			r.err("'schedule' level %s is outside -1..1" % str(lv))
		if not sched_hour.is_empty() and h <= sched_hour[sched_hour.size() - 1]:
			r.err("'schedule' hours must strictly increase (%s after %s)" % [str(h), str(sched_hour[sched_hour.size() - 1])])
		sched_hour.append(h)
		sched_level.append(lv)
	if sched_hour.size() >= 2 and (sched_hour[0] != 0.0 or sched_hour[sched_hour.size() - 1] != 24.0):
		r.err("'schedule' must run from hour 0 to hour 24")
	if sched_hour.size() >= 2 and not is_equal_approx(sched_level[0], sched_level[sched_level.size() - 1]):
		r.err("'schedule' hours 0 and 24 are the same hour: their levels must be equal")

static func _pair(r: Records, d: Dictionary, key: String, label: String) -> PackedFloat64Array:
	var v: Variant = r.record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return PackedFloat64Array([NAN, NAN])
	if not (v is Array) or (v as Array).size() != 2 or not Records.is_number((v as Array)[0]) or not Records.is_number((v as Array)[1]) or float((v as Array)[0]) > float((v as Array)[1]) or float((v as Array)[0]) < 0.0:
		r.err("'%s' must be [min, max], 0 <= min <= max" % label)
		return PackedFloat64Array([NAN, NAN])
	return PackedFloat64Array([float((v as Array)[0]), float((v as Array)[1])])

static func _numbers(r: Records, d: Dictionary, key: String, label: String) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var v: Variant = r.record(d, key, label)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		r.err("'%s' must be a non-empty list of numbers" % label)
		return out
	for x: Variant in (v as Array):
		if Records.is_number(x) and float(x) > 0.0:
			out.append(float(x))
		else:
			r.err("'%s' has an entry that is not a positive number: %s" % [label, str(x)])
	return out
