extends RefCounted

# THE SUN: the one light the map, the interface and the effects take their shadows from.
# data/params/sun.json is the only place its numbers live; this script reads it (and the
# run-time switches) and answers every reader the same thing. The readers:
#
#   RenderParams       P.sunAz, P.elev (and P.treeSunAz, P.treeElev)  -> the drawing layer, the terrain's
#                      shadows, the structures, the shadow-side pen's direction (InkCanvas.configure_pen_from)
#   UiStyle, FxStyle   shadow_dir(), sun_len() and the sun_direction / sun_elevation params -> the markers'
#                      shadows, the cards', the effects'
#   InkCanvas          the pen's default shadow direction, and the sun in pen_key() (every cached sprite's key)
#   DemoFrame          the drawing-layer demo
#
#   const Sun = preload("res://scripts/world/sun.gd")
#   var sun = Sun.current()           # shared; Sun.reset() after the switches changed
#   sun.azimuth_deg                   # the compass bearing of the sun, 0 north, 90 east: the prototype's
#                                     # sun_direction (315 = north-west)
#   sun.elevation_deg                 # the height of the sun above the horizon, after the length clamp
#   sun.shadow_dir()                  # unit vector, screen axes (y down), the way a shadow falls
#   sun.sun_len()                     # shadow length per unit of height, 1 / tan(elevation)
#   sun.asked_hour, sun.mode          # the hour the clock model was asked for (the wind reads it), and the mode
#
# MODES (data/params/sun.json): "clock_at_start" is the game's sun (decision sun-time, 2026-10-11): an hour gives
# the bearing and the height, taken ONCE when the mission starts and held for the whole mission, and every shadow
# follows it (Alex: "Fixed time at start", "Every shadow follows"; night hours FOLD onto the day; the sun comes
# "from north side to keep shadows below the objects not above" and the shadows are shorter than the board's).
# The model's NUMBERS are PROPOSED (data/params/sun.json says which are whose). "fixed" is today's sun, bit for
# bit (315, 46), kept as a switch.
#
# WHERE THE HOUR COMES FROM (the first that has one wins; the mission layer is the host's sun in co-op):
#   1. the code's override (set_override: a board's or a test's)
#   2. the mission layer: on a CLIENT the host's start (apply_start), on a host or Local the sun frozen at the
#      mission's start (begin_mission); it holds the mode, hour, scope and night
#   3. the test harness's baseline (enter_test_harness: mode fixed, which never asks for the clock)
#   4. the DebugSettings knobs sun_mode / sun_hour / sun_scope (INKWOOD_SUN_MODE...)
#   5. the scenario's pinned hour ("sun_hour" in its JSON: begin_mission(pin))
#   6. the data: hour_source "system" = THE MACHINE'S CLOCK, read once at the mission's start; "data" = "hour"
# A CLIENT NEVER READS ITS OWN CLOCK: its start is the host's (apply_start before anything is built), and the
# mission layer outranks the clock. The machine's clock is read in ONE place, machine_hour(), which counts
# its reads; the tests replace it (enter_test_harness) and fail a test that reached the real one.
#
# A change of sun is a REBAKE of the map and of every cached sprite and of the unit art: begin_mission()
# resets the shared sun, and cache_key (in InkCanvas.pen_key(), part of every sprite's cache key) makes the
# caches see it. Nothing re-reads the sun by itself in the middle of a mission.
#
# THREADS: current() is built under a mutex and shared. The bake workers read what they were handed
# (RenderParams copies the numbers) and the pen's snapshot, never this object while it is being changed.

const PATH := "res://data/params/sun.json"
const MODES := ["fixed", "clock_at_start"]
const SCOPES := ["all", "trees"]
const NIGHTS := ["clamp", "fold", "spread"]
const SOURCES := ["data", "system"]
# What the test harness's stand-in for the machine's clock says. Deliberately not an hour any test asks for.
const TEST_CLOCK_HOUR := 3.25

# --- What the sun is -----------------------------------------------------------------
var mode := "fixed"
var scope := "all"
var night := "spread"
var hour_source := "data"
var hour_origin := ""           # who gave the hour: override, mission, harness, knob, scenario, clock or data
var asked_hour := 12.0          # the hour the clock model was asked for (clock mode)
var azimuth_deg := 315.0        # the sun every shadow follows, except the trees' when scope is "trees"
var elevation_deg := 46.0
var tree_azimuth_deg := 315.0   # the sun the trees' cast shadows follow (the same, unless scope is "trees")
var tree_elevation_deg := 46.0
var cache_key := ""             # the sun in a few characters: part of every cached sprite's key (InkCanvas.pen_key)
var errors: Array[String] = []

var _clock: Dictionary = {}     # the clock model's numbers

static var _cur: RefCounted = null
static var _override: Dictionary = {}     # a board's or a test's, in code
static var _baseline: Dictionary = {}     # the test harness's (enter_test_harness)
static var _mission: Dictionary = {}      # the mission's sun: {mode, hour, scope, night, from}
static var _pin := -1.0                   # the scenario's pinned hour, -1 = none
static var _fake_clock := -1.0            # >= 0: the harness's stand-in for the machine's clock
static var _clock_reads := 0              # asks for the machine's hour (real or the stand-in)
static var _real_clock_reads := 0         # ... that reached the machine's own clock
static var last_start_error := ""         # why the last apply_start refused
static var _mutex := Mutex.new()

# --- Access ----------------------------------------------------------------------------

# The shared sun. Built on first use; reset() drops it.
static func current() -> RefCounted:
	_mutex.lock()
	if _cur == null:
		_cur = load("res://scripts/world/sun.gd").new()
	var s := _cur
	_mutex.unlock()
	return s

static func reset() -> void:
	_mutex.lock()
	_cur = null
	_mutex.unlock()

# A switch set in code, ahead of the data, the knobs and the mission: {mode, hour, scope, night, hour_source},
# any of them. An empty Dictionary clears it (the harness's baseline stays). Drops the shared sun, so the next
# current() sees it.
static func set_override(o: Dictionary) -> void:
	_mutex.lock()
	_override = o.duplicate()
	_cur = null
	_mutex.unlock()

static func override_now() -> Dictionary:
	return _override.duplicate()

func ok() -> bool:
	return errors.is_empty()

# `use_switches` false reads the data alone (no knobs, no mission, no override). `ask_clock` false never
# reads the machine's clock, whatever the data's hour_source (hour stays the data's).
func _init(path: String = PATH, use_switches: bool = true, ask_clock: bool = true) -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not (raw is Dictionary):
		_err("%s did not load" % path)
		return
	var d: Dictionary = raw
	mode = _choice(d, "mode", MODES)
	scope = _choice(d, "scope", SCOPES)
	hour_source = _choice(d, "hour_source", SOURCES)
	var hour := _num(d, "hour")
	hour_origin = "data"
	var fx: Variant = d.get("fixed")
	var fixed_az := NAN
	var fixed_el := NAN
	if fx is Dictionary:
		fixed_az = _num(fx, "azimuth_deg")
		fixed_el = _num(fx, "elevation_deg")
	else:
		_err("sun.json has no 'fixed' block")
	var ck: Variant = d.get("clock")
	if ck is Dictionary:
		var c: Dictionary = ck
		night = _choice(c, "night", NIGHTS)
		_clock = {
			"sunrise": _num(c, "sunrise_hour"), "sunset": _num(c, "sunset_hour"),
			"az_rise": _num(c, "rise_azimuth_deg"), "az_set": _num(c, "set_azimuth_deg"),
			"noon_elev": _num(c, "noon_elevation_deg"), "max_len": _num(c, "max_shadow_len"),
		}
		# THE NIGHT SPREAD (decision night-spread; the numbers are PROPOSED): the night lies between two daytime suns and a midnight one
		var sp: Variant = c.get("spread")
		if sp is Dictionary:
			_clock["evening_like_hour"] = _num(sp, "evening_like_hour")
			_clock["morning_like_hour"] = _num(sp, "morning_like_hour")
			_clock["midnight_azimuth_deg"] = _num(sp, "midnight_azimuth_deg")
		elif night == "spread":
			_err("sun.json clock has no 'spread' block, and the night rule is 'spread'")
	else:
		_err("sun.json has no 'clock' block")
	if use_switches:
		if _pin >= 0.0:
			hour = _pin
			hour_source = "data"
			hour_origin = "scenario"
		# DebugSettings' knobs ("data" leaves the file's choice)
		var ds := _debug_settings()
		if ds != null:
			var km: String = ds.get_choice_name("sun_mode")
			if MODES.has(km):
				mode = km
			var ks: String = ds.get_choice_name("sun_scope")
			if SCOPES.has(ks):
				scope = ks
			var kh: float = float(ds.get_value("sun_hour"))
			if kh >= 0.0:
				hour = kh
				hour_source = "data"
				hour_origin = "knob"
		# then the layers, each over the one before: the harness's baseline, the mission's sun, the code's override
		hour = _layer(_baseline, "harness", hour)
		hour = _layer(_mission, "mission", hour)
		hour = _layer(_override, "override", hour)
	if mode == "clock_at_start" and hour_source == "system" and ask_clock and errors.is_empty():
		hour = machine_hour()
		hour_origin = "clock"
	asked_hour = hour
	azimuth_deg = fixed_az
	elevation_deg = fixed_el
	tree_azimuth_deg = fixed_az
	tree_elevation_deg = fixed_el
	if mode == "clock_at_start" and errors.is_empty():
		var s := clock_sun(_clock, hour, night)
		if scope == "trees":
			# only the trees' cast shadows take the clock's sun; everything else keeps today's
			tree_azimuth_deg = float(s["azimuth_deg"])
			tree_elevation_deg = float(s["elevation_deg"])
		else:
			azimuth_deg = float(s["azimuth_deg"])
			elevation_deg = float(s["elevation_deg"])
			tree_azimuth_deg = azimuth_deg
			tree_elevation_deg = elevation_deg
	cache_key = "s%.2f/%.2f" % [azimuth_deg, elevation_deg]
	if trees_apart():
		cache_key += "t%.2f/%.2f" % [tree_azimuth_deg, tree_elevation_deg]

# One layer of switches over what is read so far: any of mode, scope, night, hour_source, hour. An hour
# makes the hour the data's (no clock) and names the layer as its origin. Returns the hour.
func _layer(l: Dictionary, origin: String, hour: float) -> float:
	if l.is_empty():
		return hour
	if l.has("mode") and MODES.has(str(l["mode"])):
		mode = str(l["mode"])
	if l.has("scope") and SCOPES.has(str(l["scope"])):
		scope = str(l["scope"])
	if l.has("night") and NIGHTS.has(str(l["night"])):
		night = str(l["night"])
	if l.has("hour_source") and SOURCES.has(str(l["hour_source"])):
		hour_source = str(l["hour_source"])
		hour_origin = origin
	if l.has("hour"):
		hour_source = "data"
		hour_origin = origin
		return float(l["hour"])
	return hour

# --- The model --------------------------------------------------------------------------

# The clock model, pure: hour (0 to 24, may be fractional) -> {azimuth_deg, elevation_deg, sun_len, t}.
# `c` is the "clock" block's numbers {sunrise, sunset, az_rise, az_set, noon_elev, max_len}; `night` is
# "clamp" or "fold" (what an hour outside sunrise..sunset means). t is how far through the day's arc the
# sun is, 0 at sunrise, 1 at sunset. The bearing runs in a straight line over t from az_rise to az_set (the
# data writes the sunset side as a negative bearing, -45 = 315, so the line passes through north at noon) and
# is returned as a compass bearing 0 to 360. PROPOSED numbers (data/params/sun.json; the board
# variants/sun-time/); Alex's: the sun comes from the north side, night hours fold.
static func clock_sun(c: Dictionary, hour: float, night_rule: String = "fold") -> Dictionary:
	var rise := float(c["sunrise"])
	var set_h := float(c["sunset"])
	var h := fposmod(hour, 24.0)
	var t := 0.0
	if night_rule == "spread" and (h < rise or h > set_h) and c.has("evening_like_hour"):
		return _spread_sun(c, h)
	if night_rule == "fold" or night_rule == "spread":
		t = h / 24.0   # (spread: the hours from sunrise to sunset are the fold's, as they were; only the night is laid out differently)
	else:
		t = (clampf(h, rise, set_h) - rise) / maxf(set_h - rise, 1e-6)
	var az := fposmod(float(c["az_rise"]) + (float(c["az_set"]) - float(c["az_rise"])) * t, 360.0)
	var elev := float(c["noon_elev"]) * sin(PI * t)
	var max_len := float(c["max_len"])
	var raw_len := INF if elev <= 1e-6 else 1.0 / tan(deg_to_rad(elev))
	var length := minf(raw_len, max_len)
	# the reader sees the elevation its length belongs to: past the clamp, the clamp's own
	var eff := elev if raw_len <= max_len else rad_to_deg(atan(1.0 / max_len))
	return {"azimuth_deg": az, "elevation_deg": eff, "sun_len": length, "t": t, "raw_elevation_deg": elev}

# THE NIGHT SPREAD (decision night-spread, Alex 2026-10-14: "spread the night: every hour differs and only midnight reaches the longest (capped)
# shadows"; "evenings read like late afternoon, the small hours like early morning"). An hour of the night (after sunset, before sunrise) is laid
# between three suns, bearing and shadow length each moving in a straight line over the hours:
#   sunset .. midnight    from the daytime sun at clock.spread.evening_like_hour (a late afternoon) to MIDNIGHT's, the bearing
#                         clock.spread.midnight_azimuth_deg and the longest shadow there is (max_shadow_len)
#   midnight .. sunrise   from MIDNIGHT's to the daytime sun at clock.spread.morning_like_hour (an early morning)
# so midnight alone sits at the clamp, every other night hour is shorter and no two are alike. Pure. The hours from sunrise to sunset keep the fold's sun
# (t = h / 24, a 42 to 60 degree sun: shadows 0.58 to 1.09 times the height), which the end suns are chosen to meet at 18:00 (and nearly at 06:00).
static func _spread_sun(c: Dictionary, h: float) -> Dictionary:
	var rise := float(c["sunrise"])
	var set_h := float(c["sunset"])
	var max_len := float(c["max_len"])
	var mid_az := float(c["midnight_azimuth_deg"])
	var a_az: float
	var a_len: float
	var b_az: float
	var b_len: float
	var w: float
	if h > set_h:
		var ev := clock_sun(c, float(c["evening_like_hour"]), "clamp")
		a_az = float(ev["azimuth_deg"])
		a_len = float(ev["sun_len"])
		b_az = mid_az
		b_len = max_len
		w = (h - set_h) / maxf(24.0 - set_h, 1e-6)
	else:
		var mo := clock_sun(c, float(c["morning_like_hour"]), "clamp")
		a_az = mid_az
		a_len = max_len
		b_az = float(mo["azimuth_deg"])
		b_len = float(mo["sun_len"])
		w = h / maxf(rise, 1e-6)
	var az := fposmod(rad_to_deg(lerp_angle(deg_to_rad(a_az), deg_to_rad(b_az), w)), 360.0)
	var length := lerpf(a_len, b_len, w)
	var elev := rad_to_deg(atan(1.0 / length))
	return {"azimuth_deg": az, "elevation_deg": elev, "sun_len": length, "t": h / 24.0, "raw_elevation_deg": elev}

# Pure, from a Sun's own data: the model at `hour`, with this sun's numbers and night rule.
func at_hour(hour: float, night_rule: String = "") -> Dictionary:
	return clock_sun(_clock, hour, night if night_rule == "" else night_rule)

func clock_numbers() -> Dictionary:
	return _clock.duplicate()

# --- What the readers ask ---------------------------------------------------------------

# The direction a shadow falls: unit vector, screen axes (y down). The prototype's shadowDir():
# (sun_direction + 90) degrees.
func shadow_dir() -> Vector2:
	var az := deg_to_rad(azimuth_deg + 90.0)
	return Vector2(cos(az), sin(az))

# Shadow length per unit of height, 1 / tan(elevation): the prototype's sunL().
func sun_len() -> float:
	return 1.0 / tan(deg_to_rad(elevation_deg))

func tree_shadow_dir() -> Vector2:
	var az := deg_to_rad(tree_azimuth_deg + 90.0)
	return Vector2(cos(az), sin(az))

func tree_sun_len() -> float:
	return 1.0 / tan(deg_to_rad(tree_elevation_deg))

# True when the trees' cast shadows follow a sun of their own (scope "trees").
func trees_apart() -> bool:
	return not (is_equal_approx(azimuth_deg, tree_azimuth_deg) and is_equal_approx(elevation_deg, tree_elevation_deg))

# One line for a log or a caption.
func describe() -> String:
	var s := "%s sun: bearing %.1f, elevation %.1f, shadow x%.3f" % [mode, azimuth_deg, elevation_deg, sun_len()]
	if mode == "clock_at_start":
		s += " (hour %s from the %s, night %s, scope %s)" % [hour_text(asked_hour), hour_origin, night, scope]
	return s

# 9.5 -> "09:30"
static func hour_text(h: float) -> String:
	var m := roundi(fposmod(h, 24.0) * 60.0)
	return "%02d:%02d" % [(m / 60) % 24, m % 60]

# --- The mission's sun ------------------------------------------------------------------------
#
# A mission picks its sun ONCE, when it starts, and keeps it (Alex, decision sun-time). main.gd calls these.
#
#   host or Local:  Sun.begin_mission(scenario.sun_hour)   picks the hour (the scenario's pin, else the machine's
#                                                          clock: the ONE read) and freezes the sun
#   host:           ... Sun.start_message()                what travels to a client with the start
#   client:         Sun.apply_start(message)               BEFORE its sandbox is built: the host's sun, never its own clock
#   leaving:        Sun.end_mission()
#
# Play again keeps the mission's sun (the same scenario, the same map); only the menu ends it.

# Picks and freezes the sun for a new mission. `scenario_hour` is the scenario's "sun_hour" (-1 = none).
# Returns start_message().
static func begin_mission(scenario_hour: float = -1.0) -> Dictionary:
	_mutex.lock()
	_mission = {}
	_pin = scenario_hour if scenario_hour >= 0.0 and scenario_hour <= 24.0 else -1.0
	_cur = null
	_mutex.unlock()
	var s = current()   # resolves everything below the mission layer, and reads the clock if that is where the hour is
	_mutex.lock()
	_mission = {"mode": s.mode, "hour": s.asked_hour, "scope": s.scope, "night": s.night, "from": s.hour_origin}
	_cur = null
	_mutex.unlock()
	return start_message()

# The mission is over (back at the menu): the next one picks its own.
static func end_mission() -> void:
	_mutex.lock()
	_mission = {}
	_pin = -1.0
	_cur = null
	_mutex.unlock()

# The current sun as it travels to a client: plain Variants.
static func start_message() -> Dictionary:
	var s = current()
	return {"mode": s.mode, "hour": s.asked_hour, "scope": s.scope, "night": s.night}

# A client takes the host's sun as its own and holds it for the mission. False (and last_start_error) when
# the message is not a sun: the caller must not start the game on a sun of its own.
static func apply_start(msg: Variant) -> bool:
	last_start_error = ""
	if not (msg is Dictionary):
		last_start_error = "the host's start has no sun"
		return false
	var m: Dictionary = msg
	var hour: Variant = m.get("hour")
	if not (hour is float or hour is int) or float(hour) < 0.0 or float(hour) > 24.0 or is_nan(float(hour)):
		last_start_error = "the host's sun has no hour of the day"
		return false
	if not MODES.has(str(m.get("mode", ""))) or not SCOPES.has(str(m.get("scope", ""))) or not NIGHTS.has(str(m.get("night", ""))):
		last_start_error = "the host's sun has a mode, scope or night this build does not know"
		return false
	_mutex.lock()
	_mission = {"mode": str(m["mode"]), "hour": float(hour), "scope": str(m["scope"]), "night": str(m["night"]), "from": "host"}
	_pin = -1.0
	_cur = null
	_mutex.unlock()
	return true

# --- The machine's clock -----------------------------------------------------------------------
#
# Read here and nowhere else (test_sun scans the scripts for any other reader). The hour of the day on this
# machine, local time, as 17.5 for half past five in the afternoon.
static func machine_hour() -> float:
	_clock_reads += 1
	if _fake_clock >= 0.0:
		return _fake_clock
	_real_clock_reads += 1
	var t := Time.get_time_dict_from_system()
	return float(t["hour"]) + float(t["minute"]) / 60.0

static func clock_reads() -> int:
	return _clock_reads

# Asks that reached the machine's own clock (a stand-in does not count). A test run must end with 0.
static func real_clock_reads() -> int:
	return _real_clock_reads

# A stand-in for the machine's clock: hour >= 0 sets it, a negative hour puts the machine's own back.
static func set_test_clock(hour: float) -> void:
	_fake_clock = hour
	_clock_reads = 0

# THE TEST HARNESS (scripts/test_support/test_case.gd calls it before any test body): no test depends on the
# wall clock or on the data's mode. The sun is "fixed" with no clock (today's 315 and 46, which the prototype
# comparisons and the stored hashes were made under), the machine's clock is a stand-in that says
# TEST_CLOCK_HOUR, and the real one is counted so that finish() can fail a test that reached it. A test that
# wants the clock model asks for it with set_override or begin_mission.
static func enter_test_harness() -> void:
	_mutex.lock()
	_baseline = {"mode": "fixed"}
	_override = {}
	_mission = {}
	_pin = -1.0
	_fake_clock = TEST_CLOCK_HOUR
	_clock_reads = 0
	_real_clock_reads = 0
	_cur = null
	_mutex.unlock()

static func in_test_harness() -> bool:
	return not _baseline.is_empty()

# --- Reading ----------------------------------------------------------------------------

func _debug_settings() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null("DebugSettings")
	return null

func _choice(d: Dictionary, key: String, allowed: Array) -> String:
	var rec: Variant = d.get(key)
	if rec is Dictionary and (rec as Dictionary).get("value") is String and allowed.has((rec as Dictionary)["value"]):
		return str((rec as Dictionary)["value"])
	_err("sun.json '%s' needs a value out of %s" % [key, str(allowed)])
	return str(allowed[0])

func _num(d: Dictionary, key: String) -> float:
	var rec: Variant = d.get(key)
	if rec is Dictionary and ((rec as Dictionary).get("value") is float or (rec as Dictionary).get("value") is int):
		return float((rec as Dictionary)["value"])
	_err("sun.json has no number at '%s'" % key)
	return NAN

func _err(message: String) -> void:
	errors.append(message)
	push_error("Sun: " + message)
