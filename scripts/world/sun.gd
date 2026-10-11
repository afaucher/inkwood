extends RefCounted

# THE SUN: the one light the map, the interface and the effects take their shadows from.
# data/params/sun.json is the only place its numbers live; this script reads it (and the
# run-time switches) and answers every reader the same thing. The readers:
#
#   RenderParams       P.sunAz, P.elev (and P.treeSunAz, P.treeElev)  -> the drawing layer, the terrain's
#                      shadows, the structures, the shadow-side pen's direction (InkCanvas.configure_pen_from)
#   UiStyle, FxStyle   shadow_dir(), sun_len() and the sun_direction / sun_elevation params -> the markers'
#                      shadows, the cards', the effects'
#   InkCanvas          the pen's default shadow direction
#   DemoFrame          the drawing-layer demo
#
#   const Sun = preload("res://scripts/world/sun.gd")
#   var sun = Sun.current()           # shared; Sun.reset() after the switches changed
#   sun.azimuth_deg                   # the compass bearing of the sun, 0 north, 90 east: the prototype's
#                                     # sun_direction (315 = north-west)
#   sun.elevation_deg                 # the height of the sun above the horizon, after the length clamp
#   sun.shadow_dir()                  # unit vector, screen axes (y down), the way a shadow falls
#   sun.sun_len()                     # shadow length per unit of height, 1 / tan(elevation)
#
# MODES (data/params/sun.json): "fixed" is today's sun, bit for bit (315, 46). "clock_at_start" is the
# time-of-day model (the board variants/sun-time/): an hour gives the bearing and the height, taken ONCE when
# the mission starts and held for the whole mission, and every shadow follows it (Alex, decision sun-time:
# "Fixed time at start", "Every shadow follows"); the model's numbers are PROPOSED. The
# switches are the data's, then DebugSettings' knobs sun_mode / sun_hour / sun_scope (INKWOOD_SUN_MODE...),
# then set_override() (a board's or a test's, in code). A change of sun is a REBAKE of the map and of
# every cached sprite, and of the unit art: reset(), then rebuild what read it. Nothing re-reads it by itself.
#
# THREADS: current() is built under a mutex and shared. The bake workers read what they were handed
# (RenderParams copies the numbers) and the pen's snapshot, never this object while it is being changed.

const PATH := "res://data/params/sun.json"
const MODES := ["fixed", "clock_at_start"]
const SCOPES := ["all", "trees"]
const NIGHTS := ["clamp", "fold"]
const SOURCES := ["data", "system"]

# --- What the sun is -----------------------------------------------------------------
var mode := "fixed"
var scope := "all"
var night := "clamp"
var hour_source := "data"
var asked_hour := 12.0          # the hour the clock model was asked for (clock mode)
var azimuth_deg := 315.0        # the sun every shadow follows, except the trees' when scope is "trees"
var elevation_deg := 46.0
var tree_azimuth_deg := 315.0   # the sun the trees' cast shadows follow (the same, unless scope is "trees")
var tree_elevation_deg := 46.0
var errors: Array[String] = []

var _clock: Dictionary = {}     # the clock model's numbers

static var _cur: RefCounted = null
static var _override: Dictionary = {}
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

# A switch set in code, ahead of the data and the knobs: {mode, hour, scope, night, hour_source}, any of
# them. An empty Dictionary clears it. Drops the shared sun, so the next current() sees it.
static func set_override(o: Dictionary) -> void:
	_mutex.lock()
	_override = o.duplicate()
	_cur = null
	_mutex.unlock()

static func override_now() -> Dictionary:
	return _override.duplicate()

func ok() -> bool:
	return errors.is_empty()

func _init(path: String = PATH, use_switches: bool = true) -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if not (raw is Dictionary):
		_err("%s did not load" % path)
		return
	var d: Dictionary = raw
	mode = _choice(d, "mode", MODES)
	scope = _choice(d, "scope", SCOPES)
	hour_source = _choice(d, "hour_source", SOURCES)
	var hour := _num(d, "hour")
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
	else:
		_err("sun.json has no 'clock' block")
	if use_switches:
		# DebugSettings' knobs ("data" leaves the file's choice), then the code's override.
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
		if _override.has("mode") and MODES.has(str(_override["mode"])):
			mode = str(_override["mode"])
		if _override.has("scope") and SCOPES.has(str(_override["scope"])):
			scope = str(_override["scope"])
		if _override.has("night") and NIGHTS.has(str(_override["night"])):
			night = str(_override["night"])
		if _override.has("hour_source") and SOURCES.has(str(_override["hour_source"])):
			hour_source = str(_override["hour_source"])
		if _override.has("hour"):
			hour = float(_override["hour"])
			hour_source = "data"
	if hour_source == "system":
		var t := Time.get_time_dict_from_system()
		hour = float(t["hour"]) + float(t["minute"]) / 60.0
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

# --- The model --------------------------------------------------------------------------

# The clock model, pure: hour (0 to 24, may be fractional) -> {azimuth_deg, elevation_deg, sun_len, t}.
# `c` is the "clock" block's numbers {sunrise, sunset, az_rise, az_set, noon_elev, max_len}; `night` is
# "clamp" or "fold" (what an hour outside sunrise..sunset means). t is how far through the day's arc the
# sun is, 0 at sunrise, 1 at sunset. PROPOSED (board variants/sun-time/); see data/params/sun.json.
static func clock_sun(c: Dictionary, hour: float, night_rule: String = "clamp") -> Dictionary:
	var rise := float(c["sunrise"])
	var set_h := float(c["sunset"])
	var h := fposmod(hour, 24.0)
	var t := 0.0
	if night_rule == "fold":
		t = h / 24.0
	else:
		t = (clampf(h, rise, set_h) - rise) / maxf(set_h - rise, 1e-6)
	var az := float(c["az_rise"]) + (float(c["az_set"]) - float(c["az_rise"])) * t
	var elev := float(c["noon_elev"]) * sin(PI * t)
	var max_len := float(c["max_len"])
	var raw_len := INF if elev <= 1e-6 else 1.0 / tan(deg_to_rad(elev))
	var length := minf(raw_len, max_len)
	# the reader sees the elevation its length belongs to: past the clamp, the clamp's own
	var eff := elev if raw_len <= max_len else rad_to_deg(atan(1.0 / max_len))
	return {"azimuth_deg": az, "elevation_deg": eff, "sun_len": length, "t": t, "raw_elevation_deg": elev}

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
		s += " (hour %s, night %s, scope %s)" % [hour_text(asked_hour), night, scope]
	return s

# 9.5 -> "09:30"
static func hour_text(h: float) -> String:
	var m := roundi(fposmod(h, 24.0) * 60.0)
	return "%02d:%02d" % [(m / 60) % 24, m % 60]

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
