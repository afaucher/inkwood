extends "res://scripts/test_support/test_case.gd"

# THE SUN (builder BS and BS2, 2026-10-11; decision sun-time -- Alex: fixed at the mission's start, every shadow
# follows, night hours fold, the sun from the north side, shorter shadows, the planes' gap accurate. The model's numbers
# are PROPOSED, today's sun is not).
#
#   1. THE HARNESS     every test starts with the sun pinned ("fixed", no clock) and a stand-in for the machine's clock
#   2. THE DATA        sun.json's defaults: the time-of-day sun from the machine's clock, scope all, night fold
#   3. ONE SOURCE      with "fixed" every reader -- Sun, RenderParams, UiStyle, FxStyle, the pen -- gives today's 315 / 46
#                      to the bit, and render_defaults.json no longer holds a second copy of the numbers
#   4. THE CLOCK MODEL (pure) the bearing runs 45 -> 0 -> 315, the height is a sine arc, the shadow's length is clamped at
#                      2.0, night clamps or folds; EVERY HOUR'S SHADOW POINTS SOUTH (down the map) of its object
#   5. THE SWITCHES    an override gives the clock mode with an hour; scope "trees" moves only the trees' sun; the planes'
#                      altitude gap follows the sun's length
#   6. THE MISSION     a mission picks its sun ONCE (the clock is read once and held), a scenario may pin an hour, the knob
#                      outranks the pin, end_mission puts the pinned sun back
#   7. CO-OP           a client builds from the HOST's hour over a real socket and never reads its own clock
#   8. NO WALL CLOCK   nothing in a test run reads the machine's clock, and no script but sun.gd can

const Sun = preload("res://scripts/world/sun.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const NetRig = preload("res://scripts/net/net_rig.gd")
const MissionStart = preload("res://scripts/net/mission_start.gd")

# One port per networked test: the gate runs tests in parallel (CLAUDE.md).
const PORT := 28788

# A runtime error in a helper ends it in silence and finish() still runs (CLAUDE.md): each helper puts its mark here at its end.
var _done: Array[String] = []

func setup(_main) -> void:
	timeout_seconds = 90.0
	# The harness (test_case.gd) has pinned the sun before this line. Look before anything of ours touches it.
	_harness()
	Sun.set_override({})
	_data_defaults()
	_one_source()
	_clock_model()
	_switches()
	_mission()
	var completed: Variant = await _co_op()
	check(completed == true, "the co-op part ran to its last line (a runtime error would have ended it silently)")
	_no_wall_clock()
	Sun.set_override({})
	Sun.end_mission()
	Sun.set_test_clock(Sun.TEST_CLOCK_HOUR)
	eq(_done, ["harness", "data_defaults", "one_source", "clock_model", "switches", "mission", "co_op", "no_wall_clock"] as Array[String], "every part of the test ran to its end")
	finish()

# --- 1. The harness ------------------------------------------------------------------------------

func _harness() -> void:
	check(Sun.in_test_harness(), "the test harness pinned the sun (test_case.gd)")
	var sun = Sun.current()
	eq(sun.mode, "fixed", "under the harness the sun is fixed: today's, whatever the data says")
	eq(sun.azimuth_deg, 315.0, "harness: 315")
	eq(sun.elevation_deg, 46.0, "harness: 46")
	eq(Sun.clock_reads(), 0, "building the sun under the harness did not ask for any clock")
	eq(Sun.real_clock_reads(), 0, "the harness has not touched the machine's clock")
	# the stand-in answers, deterministically, and is not the machine's
	near(Sun.machine_hour(), Sun.TEST_CLOCK_HOUR, 1e-12, "the machine's clock is the harness's stand-in")
	eq(Sun.clock_reads(), 1, "an ask for the machine's hour is counted")
	eq(Sun.real_clock_reads(), 0, "... and it was the stand-in that answered")
	Sun.set_test_clock(Sun.TEST_CLOCK_HOUR)
	_done.append("harness")

# --- 2. The data -----------------------------------------------------------------------------------

func _data_defaults() -> void:
	# Read without the switches, the harness or the clock: what sun.json itself says.
	var d = Sun.new(Sun.PATH, false, false)
	check(d.ok(), "data/params/sun.json loads: %s" % ", ".join(d.errors))
	eq(d.mode, "clock_at_start", "the data's mode is the time-of-day sun (decision sun-time; fixed stays as a switch)")
	eq(d.scope, "all", "the data's scope is all: every shadow follows (Alex)")
	eq(d.night, "spread", "the data's night rule is the spread (Alex, decision night-spread; the fold of decision sun-time stays as a setting)")
	eq(d.hour_source, "system", "the data's hour comes from the machine's clock at the mission's start (PROPOSED)")
	eq(Sun.clock_reads(), 0, "reading the data without the clock did not ask for it")
	var c: Dictionary = d.clock_numbers()
	eq(float(c["sunrise"]), 6.0, "sunrise 06:00 (PROPOSED)")
	eq(float(c["sunset"]), 18.0, "sunset 18:00 (PROPOSED)")
	eq(float(c["az_rise"]), 45.0, "the sun rises in the north-east: bearing 45 (PROPOSED, on Alex's direction)")
	eq(float(c["az_set"]), -45.0, "... and sets in the north-west: -45 is 315 (PROPOSED)")
	eq(float(c["noon_elev"]), 60.0, "noon elevation 60 (PROPOSED)")
	eq(float(c["max_len"]), 2.0, "the shadow is at most twice the height: 2.0 instead of the board's 3.0 (PROPOSED, on Alex's 'reduce the distance a bit')")
	# the file says whose each value is
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(Sun.PATH))
	var root: Dictionary = raw if raw is Dictionary else {}
	for k: String in ["mode", "scope"]:
		eq(str((root.get(k, {}) as Dictionary).get("decision", "")), "sun-time", "sun.json %s is Alex's (decision sun-time)" % k)
	eq(str(((root.get("clock", {}) as Dictionary).get("night", {}) as Dictionary).get("decision", "")), "night-spread", "sun.json clock.night (spread) is Alex's (decision night-spread)")
	for k: String in ["evening_like_hour", "morning_like_hour", "midnight_azimuth_deg"]:
		check(bool((((root.get("clock", {}) as Dictionary).get("spread", {}) as Dictionary).get(k, {}) as Dictionary).get("_proposed", false)), "sun.json clock.spread.%s is marked PROPOSED" % k)
	for k: String in ["rise_azimuth_deg", "set_azimuth_deg", "max_shadow_len", "noon_elevation_deg"]:
		check(bool(((root.get("clock", {}) as Dictionary).get(k, {}) as Dictionary).get("_proposed", false)), "sun.json clock.%s is marked PROPOSED" % k)
	_done.append("data_defaults")

# --- 3. One source ---------------------------------------------------------------------------------

func _one_source() -> void:
	Sun.set_override({"mode": "fixed"})
	var sun = Sun.current()
	check(sun.ok(), "data/params/sun.json loads: %s" % ", ".join(sun.errors))
	eq(sun.mode, "fixed", "fixed: today's sun")
	eq(sun.scope, "all", "the scope is all")
	eq(sun.azimuth_deg, 315.0, "fixed: the north-west")
	eq(sun.elevation_deg, 46.0, "fixed: elevation 46")
	# the exact expressions the readers used before there was a Sun
	var az := deg_to_rad(315.0 + 90.0)
	eq(sun.shadow_dir(), Vector2(cos(az), sin(az)), "Sun.shadow_dir() is the old shadow_dir, to the bit")
	eq(sun.sun_len(), 1.0 / tan(deg_to_rad(46.0)), "Sun.sun_len() is the old sun_len, to the bit")
	check(not sun.trees_apart(), "by default the trees' sun is THE sun")
	var P := RenderParams.new()
	check(P.ok(), "render params load: %s" % ", ".join(P.errors))
	eq(P.sunAz, 315.0, "RenderParams.sunAz is the sun's")
	eq(P.elev, 46.0, "RenderParams.elev is the sun's")
	eq(P.treeSunAz, P.sunAz, "the trees' sun is the same")
	eq(P.treeElev, P.elev, "the trees' elevation is the same")
	var ui := UiStyle.new()
	eq(ui.shadow_dir(), sun.shadow_dir(), "UiStyle.shadow_dir() is the sun's")
	eq(ui.sun_len(), sun.sun_len(), "UiStyle.sun_len() is the sun's")
	eq(ui.param("sun_direction"), 315.0, "UiStyle's sun_direction param is the sun's")
	eq(ui.param("sun_elevation"), 46.0, "UiStyle's sun_elevation param is the sun's")
	var fx := FxStyle.new()
	eq(fx.shadow_dir(), sun.shadow_dir(), "FxStyle.shadow_dir() is the sun's")
	eq(fx.sun_len(), sun.sun_len(), "FxStyle.sun_len() is the sun's")
	var pen: Vector2 = InkCanvas._load_pen()["shadow_dir"]
	var paz := (315.0 + 90.0) * PI / 180.0
	eq(pen, Vector2(cos(paz), sin(paz)), "the pen's shadow direction is the sun's, to the bit")
	# a shadow falls to the south-east of the north-west sun
	check(sun.shadow_dir().x > 0.7 and sun.shadow_dir().y > 0.7, "the shadow falls to the south-east (screen axes, y down)")
	# one copy: render_defaults.json no longer holds a default for the sun
	var rd: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/params/render_defaults.json"))
	var prm: Dictionary = (rd as Dictionary).get("parameters", {})
	for k: String in ["sun_direction", "sun_elevation"]:
		check(prm.has(k) and not (prm[k] as Dictionary).has("default"), "render_defaults.json parameters.%s keeps only its slider range, not a second copy of the value" % k)
	# every cached sprite's key names the sun (a mission with another sun is not handed the last one's art)
	var key_fixed := InkCanvas.pen_key()
	check(key_fixed.contains(sun.cache_key), "InkCanvas.pen_key() carries the sun's cache key")
	Sun.set_override({"mode": "clock_at_start", "hour": 9.0})
	check(InkCanvas.pen_key() != key_fixed, "... and another sun makes another key")
	Sun.set_override({})
	_done.append("one_source")

# --- 4. The clock model ------------------------------------------------------------------------------

func _clock_model() -> void:
	var sun = Sun.new(Sun.PATH, false, false)
	var c: Dictionary = sun.clock_numbers()
	var noon: Dictionary = Sun.clock_sun(c, 12.0)
	near(float(noon["azimuth_deg"]), 0.0, 1e-9, "noon: due north")
	near(float(noon["elevation_deg"]), float(c["noon_elev"]), 1e-9, "noon: the highest sun")
	near(float(noon["sun_len"]), 1.0 / tan(deg_to_rad(float(c["noon_elev"]))), 1e-9, "noon: the shortest shadow")
	var rise: Dictionary = Sun.clock_sun(c, 6.0, "clamp")
	near(float(rise["azimuth_deg"]), 45.0, 1e-9, "sunrise: north-east")
	var set_s: Dictionary = Sun.clock_sun(c, 18.0, "clamp")
	near(float(set_s["azimuth_deg"]), 315.0, 1e-9, "sunset: north-west, today's fixed sun")
	# the way a shadow falls: noon, straight down the map; sunrise, down and to the west; sunset, down and to the east
	var south := _shadow_of(float(noon["azimuth_deg"]))
	check(south.y > 0.99 and absf(south.x) < 1e-6, "at noon the shadow falls south (down the screen)")
	var sw := _shadow_of(float(rise["azimuth_deg"]))
	check(sw.x < -0.7 and sw.y > 0.7, "at sunrise the shadow falls south-west")
	var se := _shadow_of(float(set_s["azimuth_deg"]))
	check(se.x > 0.7 and se.y > 0.7, "at sunset the shadow falls south-east")
	# EVERY HOUR, both night rules: the shadow has a southward part, so it falls BELOW its object (Alex: "to keep shadows
	# below the objects not above"); the sun never leaves the 90 degrees north of east and west, and in fact stays within 45
	var floor_y := cos(deg_to_rad(45.0)) - 1e-6   # (a Vector2 holds float32: its y is good to about 6e-8)
	for rule: String in ["clamp", "fold", "spread"]:
		for i in 97:
			var h := float(i) * 0.25
			var m: Dictionary = Sun.clock_sun(c, h, rule)
			var d := _shadow_of(float(m["azimuth_deg"]))
			check(d.y >= floor_y, "%s %.2f: the shadow falls below its object (y %.3f)" % [rule, h, d.y])
			var signed := wrapf(float(m["azimuth_deg"]), -180.0, 180.0)
			check(absf(signed) <= 45.0 + 1e-9, "%s %.2f: the sun stays within 45 degrees of north (%.2f)" % [rule, h, signed])
			check(float(m["sun_len"]) <= float(c["max_len"]) + 1e-12, "%s %.2f: the shadow is never longer than the clamp (%.3f)" % [rule, h, float(m["sun_len"])])
			check(float(m["elevation_deg"]) > 0.0, "%s %.2f: the reader never sees a sun on the horizon" % [rule, h])
			near(float(m["sun_len"]), 1.0 / tan(deg_to_rad(float(m["elevation_deg"]))), 1e-9, "%s %.2f: the length is the elevation's own" % [rule, h])
	# morning and afternoon mirror each other about noon: the bearing reflects about north, the height is the same
	for i in range(1, 25):   # (24:00 is 0:00, so the mirror of midnight is itself)
		var h := float(i) * 0.5
		var m: Dictionary = Sun.clock_sun(c, h)
		var mirror: Dictionary = Sun.clock_sun(c, 24.0 - h)
		near(float(m["elevation_deg"]), float(mirror["elevation_deg"]), 1e-9, "elevation mirrors about noon at %.1f" % h)
		near(wrapf(float(m["azimuth_deg"]) + float(mirror["azimuth_deg"]), -180.0, 180.0), 0.0, 1e-9, "the bearing mirrors about north at %.1f" % h)
	# the bearing sweeps from the north-east at 6:00 to the north-west at 18:00 (clamp rule: the daytime hours)
	var prev := 1000.0
	for i in 25:
		var h := 6.0 + float(i) * 0.5
		var signed := wrapf(float((Sun.clock_sun(c, h, "clamp"))["azimuth_deg"]), -180.0, 180.0)
		check(signed < prev, "the bearing keeps turning from east to west through the day at %.1f" % h)
		prev = signed
	# THE CLAMP at 2.0 (a 26.6 degree sun): 7:00 would be a 15.5 degree sun and throws a shadow 3.7 times the height
	var dawn: Dictionary = Sun.clock_sun(c, 7.0, "clamp")
	near(float(dawn["sun_len"]), 2.0, 1e-9, "7:00: the shadow is at the clamp, 2.0")
	check(float(dawn["raw_elevation_deg"]) < float(dawn["elevation_deg"]), "7:00: the raw sun is lower than the one the readers see")
	near(float(dawn["elevation_deg"]), rad_to_deg(atan(0.5)), 1e-9, "7:00: the readers see the clamp's own sun, 26.57 degrees")
	var eight: Dictionary = Sun.clock_sun(c, 8.0, "clamp")
	near(float(eight["sun_len"]), 1.0 / tan(deg_to_rad(30.0)), 1e-9, "8:00: a 30 degree sun, 1.73, under the clamp")
	check(absf(float(eight["elevation_deg"]) - float(eight["raw_elevation_deg"])) < 1e-9, "8:00: not clamped, the raw elevation")
	# night: clamp to the nearest daytime hour, or fold the 24 hours on the arc
	for pair: Array in [[3.0, 6.0], [0.0, 6.0], [22.0, 18.0], [19.5, 18.0]]:
		var a: Dictionary = Sun.clock_sun(c, float(pair[0]), "clamp")
		var b: Dictionary = Sun.clock_sun(c, float(pair[1]), "clamp")
		near(float(a["azimuth_deg"]), float(b["azimuth_deg"]), 1e-9, "clamp: %.1f is the %.1f sun" % [pair[0], pair[1]])
	var f0: Dictionary = Sun.clock_sun(c, 0.0, "fold")
	var f24: Dictionary = Sun.clock_sun(c, 24.0, "fold")
	near(float(f0["azimuth_deg"]), 45.0, 1e-9, "fold: midnight is the sunrise sun")
	near(float(f24["azimuth_deg"]), float(f0["azimuth_deg"]), 1e-9, "fold: 24:00 is 0:00")
	near(float((Sun.clock_sun(c, 12.0, "fold"))["azimuth_deg"]), 0.0, 1e-9, "fold: noon is still noon")
	var f6: Dictionary = Sun.clock_sun(c, 6.0, "fold")
	near(float(f6["azimuth_deg"]), 22.5, 1e-9, "fold: 6:00 is a quarter of the way along the day: bearing 22.5")
	near(float(f6["elevation_deg"]), 60.0 * sin(PI / 4.0), 1e-9, "fold: 6:00 is at 42.4 degrees")
	var f18: Dictionary = Sun.clock_sun(c, 18.0, "fold")
	near(float(f18["azimuth_deg"]), 337.5, 1e-9, "fold: 18:00 is three quarters along: bearing 337.5")
	# the fold keeps the sun moving, every hour of the real day gives another sun, except where the clamp holds the length
	var clamped := 0
	for hh in 24:
		var m: Dictionary = Sun.clock_sun(c, float(hh), "fold")
		if absf(float(m["sun_len"]) - 2.0) < 1e-9:
			clamped += 1
		if hh > 0:
			var before: Dictionary = Sun.clock_sun(c, float(hh - 1), "fold")
			check(absf(wrapf(float(m["azimuth_deg"]) - float(before["azimuth_deg"]), -180.0, 180.0)) > 1.0, "fold: the bearing differs between %d:00 and %d:00" % [hh - 1, hh])
	eq(clamped, 7, "fold: 7 of the 24 hours (21:00 to 03:00) sit at the clamp, the rest are shorter")
	# THE NIGHT SPREAD (decision night-spread, Alex: "every hour differs and only midnight reaches the longest (capped) shadows"; evenings like
	# a late afternoon, the small hours like an early morning). PROPOSED numbers (sun.json clock.spread).
	var cap := float(c["max_len"])
	var lens := {}
	for hh: int in [21, 22, 23, 0, 1, 2, 3]:
		var m: Dictionary = Sun.clock_sun(c, float(hh), "spread")
		lens[hh] = float(m["sun_len"])
	var keys: Array = lens.keys()
	for i in keys.size():
		for j in range(i + 1, keys.size()):
			check(absf(float(lens[keys[i]]) - float(lens[keys[j]])) > 0.01, "spread: %d:00 and %d:00 throw different shadows (%.3f and %.3f)" % [keys[i], keys[j], lens[keys[i]], lens[keys[j]]])
	near(float(lens[0]), cap, 1e-9, "spread: midnight is at the cap")
	for hh: int in [21, 22, 23, 1, 2, 3]:
		check(float(lens[hh]) < cap - 0.01, "spread: %d:00 is under the cap (%.3f)" % [hh, lens[hh]])
	# every quarter hour of the night: only midnight reaches the cap, and the shadow always falls below its object
	var capped_hours := 0
	for i in 97:
		var hq := float(i) * 0.25
		if hq >= 6.0 and hq <= 18.0:
			continue
		var m2: Dictionary = Sun.clock_sun(c, hq, "spread")
		if absf(float(m2["sun_len"]) - cap) < 1e-9:
			capped_hours += 1
			check(hq == 0.0 or hq == 24.0, "spread: only midnight is at the cap (%.2f is)" % hq)
	eq(capped_hours, 2, "spread: midnight (0:00, and 24:00 as the same hour) is the only night start at the cap")
	# it rises into midnight and falls out of it; the evening begins where the day left off (18:00 is the fold's sun)
	var prev_len := float((Sun.clock_sun(c, 18.0, "spread"))["sun_len"])
	near(prev_len, float((Sun.clock_sun(c, 18.0, "fold"))["sun_len"]), 1e-9, "spread: 18:00 is the fold's own sun")
	for hh in range(19, 25):
		var l := float((Sun.clock_sun(c, float(hh), "spread"))["sun_len"])
		check(l > prev_len, "spread: the evening's shadow lengthens to %d:00 (%.3f)" % [hh, l])
		prev_len = l
	for hh in range(1, 6):
		var l2 := float((Sun.clock_sun(c, float(hh), "spread"))["sun_len"])
		check(l2 < prev_len, "spread: the small hours' shadow shortens to %d:00 (%.3f)" % [hh, l2])
		prev_len = l2
	near(float((Sun.clock_sun(c, 24.0, "spread"))["sun_len"]), cap, 1e-9, "spread: 24:00 is 0:00")
	# the daytime keeps the fold's sun, hour for hour
	for hh in range(6, 19):
		near(float((Sun.clock_sun(c, float(hh), "spread"))["azimuth_deg"]), float((Sun.clock_sun(c, float(hh), "fold"))["azimuth_deg"]), 1e-9, "spread: %d:00 is the fold's sun (the day is as it was)" % hh)
	check(Sun.hour_text(9.5) == "09:30" and Sun.hour_text(24.0) == "00:00", "hour_text")
	_done.append("clock_model")

func _shadow_of(bearing: float) -> Vector2:
	var az := deg_to_rad(bearing + 90.0)
	return Vector2(cos(az), sin(az))

# --- 5. The switches ------------------------------------------------------------------------------------

func _switches() -> void:
	eq(DebugSettings.get_choice_name("sun_mode"), "data", "the sun_mode knob defaults to the data's")
	eq(DebugSettings.get_choice_name("sun_scope"), "data", "the sun_scope knob defaults to the data's")
	near(float(DebugSettings.get_value("sun_hour")), -1.0, 1e-9, "the sun_hour knob defaults to -1 (the data's hour)")
	# clock at 9:00 (the data's night rule is fold): every reader follows
	Sun.set_override({"mode": "clock_at_start", "hour": 9.0})
	var sun = Sun.current()
	eq(sun.mode, "clock_at_start", "override: clock_at_start")
	eq(sun.hour_origin, "override", "the hour is the override's")
	near(sun.azimuth_deg, 45.0 - 90.0 * (9.0 / 24.0), 1e-9, "9:00 folded: bearing 11.25, nearly due north")
	near(sun.elevation_deg, 60.0 * sin(PI * (9.0 / 24.0)), 1e-9, "9:00 folded: a sine arc")
	check(not sun.trees_apart(), "scope all: the trees follow the same sun")
	check(sun.shadow_dir().y > 0.9, "9:00: the shadow falls down the map")
	var P := RenderParams.new()
	near(P.sunAz, sun.azimuth_deg, 1e-9, "RenderParams follows the clock sun")
	near(P.treeSunAz, sun.azimuth_deg, 1e-9, "and so do the trees")
	var ui := UiStyle.new()
	check(ui.shadow_dir().distance_to(sun.shadow_dir()) < 1e-12, "UiStyle follows the clock sun live")
	near(ui.param("sun_direction"), sun.azimuth_deg, 1e-9, "UiStyle's param follows too")
	var fx := FxStyle.new()
	check(fx.sun_len() == sun.sun_len(), "FxStyle follows the clock sun live")
	# the pen is read when the pen first loads or when a RenderParams configures it
	var paz: float = (sun.azimuth_deg + 90.0) * PI / 180.0
	check((InkCanvas._load_pen()["shadow_dir"] as Vector2).distance_to(Vector2(cos(paz), sin(paz))) < 1e-12, "the pen's default follows the clock sun")
	# THE PLANES' ALTITUDE SHADOW IS ACCURATE (Alex: "No, make them accurate"): the gap follows the sun's length, like every
	# shadow, and is not held at today's length. 1:00 folded is at the clamp (2.0), noon is 0.577, today's fixed sun 0.966.
	var gap_scale: float = ui.param("aircraft_shadow_altitude_scale")
	Sun.set_override({"mode": "clock_at_start", "hour": 1.0, "night": "fold"})
	near(ui.plane_shadow_offset_m(100.0).length(), 100.0 * gap_scale * 2.0, 1e-6, "UiStyle: at the clamp the gap is twice the height x the rule")
	near(fx.plane_shadow_offset_m(100.0).length(), 100.0 * gap_scale * 2.0, 1e-6, "FxStyle: the same")
	Sun.set_override({"mode": "clock_at_start", "hour": 12.0})
	near(ui.plane_shadow_offset_m(100.0).length(), 100.0 * gap_scale / tan(deg_to_rad(60.0)), 1e-6, "UiStyle: at noon the gap is the 60 degree sun's")
	Sun.set_override({"mode": "fixed"})
	near(ui.plane_shadow_offset_m(100.0).length(), 100.0 * gap_scale / tan(deg_to_rad(46.0)), 1e-6, "UiStyle: under the fixed sun it is today's")
	# every reader's shadow points down the map at every hour, the planes' gap included
	for hh in [0.0, 3.0, 6.0, 9.0, 12.0, 15.0, 18.0, 21.0]:
		Sun.set_override({"mode": "clock_at_start", "hour": hh})
		var off: Vector2 = ui.plane_shadow_offset_m(100.0)
		check(off.y > 0.0, "%02d:00: a plane's shadow sits below it on the map" % int(hh))
		check(ui.shadow_dir().y > 0.7 and fx.shadow_dir().y > 0.7, "%02d:00: the markers' and the effects' shadows fall down the map" % int(hh))
		check((RenderParams.new()).sunAz < 45.0 + 1e-9 or (RenderParams.new()).sunAz > 315.0 - 1e-9, "%02d:00: the map's sun is on the north side" % int(hh))
	# scope trees: only the trees' cast shadows
	Sun.set_override({"mode": "clock_at_start", "hour": 9.0, "scope": "trees"})
	sun = Sun.current()
	eq(sun.azimuth_deg, 315.0, "scope trees: everything but the trees keeps the fixed sun")
	eq(sun.elevation_deg, 46.0, "scope trees: ... its elevation too")
	near(sun.tree_azimuth_deg, 11.25, 1e-9, "scope trees: the trees take the clock's bearing")
	check(sun.trees_apart(), "scope trees: two suns")
	P = RenderParams.new()
	eq(P.sunAz, 315.0, "RenderParams.sunAz stays fixed under scope trees")
	near(P.treeSunAz, 11.25, 1e-9, "RenderParams.treeSunAz is the clock's")
	var t := Terrain.new(20261009)
	var ts := TerrainShadows.new(t, P)
	check(ts.tree_dir.distance_to(sun.tree_shadow_dir()) < 1e-9 and ts.dir.distance_to(sun.shadow_dir()) < 1e-9, "TerrainShadows: scarps and structures on the fixed sun, the trees on the clock's")
	check(ts.tree_dir.distance_to(ts.dir) > 0.5, "TerrainShadows: two directions")
	Sun.set_override({"mode": "fixed"})
	P = RenderParams.new()
	t = Terrain.new(20261009)
	ts = TerrainShadows.new(t, P)
	eq(ts.tree_dir, ts.dir, "TerrainShadows by default: the trees' direction is the sun's, to the bit")
	eq(ts.tree_L, ts.L, "TerrainShadows by default: the trees' length is the sun's")
	eq(ts.tree_stretch, ts.stretch, "TerrainShadows by default: the trees' stretch is the sun's")
	# a night hour under the data's rule (fold), and under clamp
	Sun.set_override({"mode": "clock_at_start", "hour": 2.0, "night": "fold"})
	near(Sun.current().azimuth_deg, 45.0 - 90.0 * (2.0 / 24.0), 1e-9, "2:00 under the fold rule is 2/24 of the way along the arc")
	Sun.set_override({"mode": "clock_at_start", "hour": 2.0})
	eq(Sun.current().night, "spread", "the data's night rule reaches the sun")
	near(Sun.current().sun_len(), Sun.clock_sun(Sun.current().clock_numbers(), 2.0, "spread")["sun_len"], 1e-9, "2:00 under the data's rule (the spread) is the spread's sun")
	check(Sun.current().sun_len() < 2.0 - 0.1, "...and is no longer at the clamp (%.3f)" % Sun.current().sun_len())
	Sun.set_override({"mode": "clock_at_start", "hour": 2.0, "night": "clamp"})
	near(Sun.current().azimuth_deg, 45.0, 1e-9, "2:00 under the clamp rule is the 6:00 sun")
	# cleared: the harness's sun is back
	Sun.set_override({})
	eq(Sun.current().mode, "fixed", "cleared: the harness's fixed sun")
	eq(Sun.current().azimuth_deg, 315.0, "cleared: 315")
	_done.append("switches")

# --- 6. The mission ---------------------------------------------------------------------------------------

func _mission() -> void:
	Sun.end_mission()
	# A host (or Local) at 17:07 by its clock. The harness keeps the data's clock out of it, so the test asks for it.
	Sun.set_test_clock(17.123456789)
	Sun.set_override({"mode": "clock_at_start"})
	var msg: Dictionary = Sun.begin_mission()
	Sun.set_override({})
	near(float(msg["hour"]), 17.123456789, 1e-12, "the mission's start message carries the clock's hour")
	eq(msg["mode"], "clock_at_start", "... the mode")
	eq(msg["scope"], "all", "... the scope")
	eq(msg["night"], "spread", "... the night rule")
	eq(Sun.clock_reads(), 1, "the clock is read ONCE, at the mission's start")
	var sun = Sun.current()
	eq(sun.mode, "clock_at_start", "the mission's sun holds: the clock model, whatever the harness's baseline says")
	near(sun.asked_hour, 17.123456789, 1e-12, "the mission's hour is the clock's")
	eq(sun.hour_origin, "mission", "... and the sun says it comes from the mission")
	var az_then: float = sun.azimuth_deg
	# PICKED ONCE: the clock moves on, the sun is rebuilt (reset), the mission's sun does not change and does not ask again
	Sun.set_test_clock(9.0)
	Sun.reset()
	Sun.set_override({})
	near(Sun.current().asked_hour, 17.123456789, 1e-12, "a rebuilt sun is the same: the hour is held for the mission")
	near(Sun.current().azimuth_deg, az_then, 1e-12, "... and so is the bearing")
	eq(Sun.clock_reads(), 0, "... without asking the clock again")
	# the next mission picks again
	var msg2: Dictionary = _begin_from_clock()
	near(float(msg2["hour"]), 9.0, 1e-12, "a new mission takes the clock's hour then")
	Sun.end_mission()
	eq(Sun.current().mode, "fixed", "end_mission: nothing is held, the harness's sun is back")
	# A SCENARIO MAY PIN AN HOUR: the clock is not read at all
	Sun.set_test_clock(21.0)
	Sun.set_override({"mode": "clock_at_start"})
	var pinned: Dictionary = Sun.begin_mission(7.5)
	Sun.set_override({})
	near(float(pinned["hour"]), 7.5, 1e-12, "a scenario's pinned hour is the mission's hour")
	near(Sun.current().asked_hour, 7.5, 1e-12, "... and the sun's")
	eq(Sun.clock_reads(), 0, "... without reading the clock")
	near(Sun.current().azimuth_deg, 45.0 - 90.0 * (7.5 / 24.0), 1e-9, "... folded: the bearing of 7:30")
	Sun.end_mission()
	for bad: float in [-0.5, 24.5]:
		Sun.set_override({"mode": "clock_at_start"})
		var b: Dictionary = Sun.begin_mission(bad)
		Sun.set_override({})
		near(float(b["hour"]), 21.0, 1e-12, "a pin of %.1f is not an hour of the day: ignored, the clock decides" % bad)
		Sun.end_mission()
	# the knob outranks the scenario's pin (a debug switch over the data)
	DebugSettings.set_value("sun_hour", 9.0)
	Sun.set_override({"mode": "clock_at_start"})
	var knobbed: Dictionary = Sun.begin_mission(7.5)
	Sun.set_override({})
	DebugSettings.set_value("sun_hour", -1.0)
	near(float(knobbed["hour"]), 9.0, 1e-12, "the sun_hour knob outranks a scenario's pin")
	Sun.end_mission()
	# a fixed mission sends "fixed", and a client takes it (no hour needed for the sun, but the message is whole)
	Sun.set_test_clock(21.0)
	var fixed_msg: Dictionary = Sun.begin_mission()
	eq(fixed_msg["mode"], "fixed", "under the harness' fixed sun a mission is fixed, and says so")
	eq(Sun.clock_reads(), 0, "a fixed mission never asks for the clock")
	Sun.end_mission()
	# THE SCENARIO FILE: "sun_hour" is optional, 0 to 24
	var plain := SandboxScenario.new("strike", true)
	check(plain.ok(), "the Strike loads: %s" % ", ".join(plain.errors))
	eq(plain.sun_hour, -1.0, "a scenario with no sun_hour pins nothing")
	var dawn := SandboxScenario.new("strike", true, {"sun_hour": 7.5})
	check(dawn.ok(), "a scenario with sun_hour 7.5 loads: %s" % ", ".join(dawn.errors))
	eq(dawn.sun_hour, 7.5, "the scenario's sun_hour is read")
	var late := SandboxScenario.new("strike", true, {"sun_hour": 30.0})
	check(not late.ok(), "a sun_hour of 30 is an error")
	var words := SandboxScenario.new("strike", true, {"sun_hour": "dawn"})
	check(not words.ok(), "a sun_hour that is not a number is an error")
	Sun.set_test_clock(Sun.TEST_CLOCK_HOUR)
	_done.append("mission")

# The host's start at the clock's hour, the way main.gd does it: ask for the clock model, begin, drop the ask.
func _begin_from_clock() -> Dictionary:
	Sun.end_mission()
	Sun.set_override({"mode": "clock_at_start"})
	var m: Dictionary = Sun.begin_mission()
	Sun.set_override({})
	return m

# --- 7. Co-op: the client builds from the host's hour -------------------------------------------------------------

func _co_op() -> bool:
	var rig := NetRig.new()
	add_child(rig)
	var host: NetRig.Peer = rig.add_host(PORT, "Hal", false)
	if not check(host != null, "the host binds port %d" % PORT):
		return false
	var client: NetRig.Peer = await rig.add_client(PORT, "Ann", false)
	if not check(client != null, "a client connects"):
		rig.close_all()
		return false
	var hs: MissionStart = MissionStart.new()
	hs.name = "MissionStart"
	host.root.add_child(hs)
	var cs: MissionStart = MissionStart.new()
	cs.name = "MissionStart"
	client.root.add_child(cs)

	# THE HOST'S MACHINE: its clock says 17:07, it starts a mission, and keeps what a client is sent.
	Sun.end_mission()
	Sun.set_test_clock(17.123456789)
	var start: Dictionary = _begin_from_clock()
	hs.start = {"sun": start}
	var host_az: float = Sun.current().azimuth_deg
	var host_el: float = Sun.current().elevation_deg
	var host_len: float = Sun.current().sun_len()
	var host_pen: String = InkCanvas.pen_key()
	eq(Sun.clock_reads(), 1, "7. the host read its clock once")

	# THE CLIENT'S MACHINE: it has no mission yet and its clock says 06:00. (One process has one Sun, so the host's is put away.)
	Sun.end_mission()
	Sun.set_test_clock(6.0)
	var got: Array = []
	cs.received.connect(func(s: Dictionary) -> void: got.append(s))
	check(cs.request(), "7. the client asks the host for the mission's start")
	var arrived: bool = await rig.wait_until(func() -> bool: return got.size() > 0)
	if not check(arrived, "7. the host's start arrives"):
		rig.close_all()
		return false
	eq(hs.served, 1, "7. the host answered once")
	check(got[0] is Dictionary and (got[0] as Dictionary).has("sun"), "7. the start carries the sun")
	check(Sun.apply_start((got[0] as Dictionary).get("sun")), "7. the client takes the host's sun: %s" % Sun.last_start_error)
	var sun = Sun.current()
	eq(sun.mode, "clock_at_start", "7. the client's sun is the time-of-day sun")
	near(sun.asked_hour, 17.123456789, 1e-12, "7. the client's hour is the HOST's, bit for bit over the wire")
	check(absf(sun.asked_hour - 6.0) > 1.0, "7. ... not its own clock's 06:00")
	eq(sun.hour_origin, "mission", "7. the hour is the mission's, not the clock's")
	near(sun.azimuth_deg, host_az, 1e-12, "7. the client's bearing is the host's")
	near(sun.elevation_deg, host_el, 1e-12, "7. the client's height is the host's")
	near(sun.sun_len(), host_len, 1e-12, "7. the client's shadow length is the host's")
	var P := RenderParams.new()
	near(P.sunAz, host_az, 1e-12, "7. the map the client bakes is lit from the host's bearing")
	near(P.elev, host_el, 1e-12, "7. ... and the host's height")
	eq(InkCanvas.pen_key(), host_pen, "7. ... and its sprites' cache keys are the host's")
	eq(UiStyle.new().shadow_dir(), sun.shadow_dir(), "7. ... and the markers' shadows too")
	eq(Sun.clock_reads(), 0, "7. THE CLIENT NEVER READ ITS OWN CLOCK")
	eq(Sun.real_clock_reads(), 0, "7. ... nor the machine's")
	# a client that did not take the host's start would have built on its own clock: the control
	Sun.end_mission()
	Sun.set_override({"mode": "clock_at_start"})
	near(Sun.current().asked_hour, 6.0, 1e-12, "7. control: a client on its own clock would have had 06:00")
	check(absf(Sun.current().azimuth_deg - host_az) > 5.0, "7. control: and another bearing from the host's")
	eq(Sun.clock_reads(), 1, "7. control: the read is counted")
	Sun.set_override({})
	Sun.end_mission()

	# A START THAT IS NOT A SUN is refused, and nothing is applied (the client leaves; it does not start on its own sun)
	for bad: Variant in [null, {}, {"mode": "clock_at_start"}, {"mode": "moon", "hour": 5.0, "scope": "all", "night": "fold"},
			{"mode": "clock_at_start", "hour": 30.0, "scope": "all", "night": "fold"}, {"mode": "clock_at_start", "hour": "noon", "scope": "all", "night": "fold"},
			{"mode": "clock_at_start", "hour": 5.0, "scope": "all", "night": "never"}, "17.5"]:
		check(not Sun.apply_start(bad), "7. a start with no usable sun is refused: %s" % str(bad))
		check(Sun.last_start_error != "", "7. ... and says why")
		eq(Sun.current().mode, "fixed", "7. ... and applied nothing")
	# a host with no mission answers with an empty start, which a client refuses the same way
	hs.start = {}
	got.clear()
	check(cs.request(), "7. a second ask")
	await rig.wait_until(func() -> bool: return got.size() > 0)
	check(got.size() == 1 and (got[0] as Dictionary).is_empty(), "7. a host with no mission answers an empty start")
	check(not Sun.apply_start((got[0] as Dictionary).get("sun")), "7. ... which a client does not build on")
	# a client cannot answer for the host: its request is not served, and a host cannot ask itself
	check(not hs.request(), "7. the host does not ask for a start")
	rig.close_all()
	_done.append("co_op")
	return true

# --- 8. No wall clock ---------------------------------------------------------------------------------------------

func _no_wall_clock() -> void:
	eq(Sun.real_clock_reads(), 0, "8. nothing in this test run reached the machine's clock")
	# and nothing else could: the machine's clock is read in ONE place. A script that wants the time of day for another
	# reason adds itself to ALLOWED, with the reason, and says in its own test how that test stays off the wall clock.
	var needles: Array[String] = ["_from" + "_system(", "OS.get_system" + "_time", "OS.get_date" + "time", "OS.get_unix" + "_time"]
	var allowed: Dictionary = {"res://scripts/world/sun.gd": "the sun's one read of the machine's clock (machine_hour), replaced in every test"}
	var found: Array[String] = []
	_scan("res://scripts", needles, found)
	found.sort()
	var unexpected: Array[String] = []
	for f: String in found:
		if not allowed.has(f):
			unexpected.append(f)
	eq(unexpected, [] as Array[String], "8. no script but sun.gd reads the machine's clock (a test that depended on it would pass or fail with the hour)")
	check(found.has("res://scripts/world/sun.gd"), "8. the scan does find the sun's own read (it is looking at the right things)")
	# the data path reaches the stand-in, not the machine
	Sun.set_test_clock(Sun.TEST_CLOCK_HOUR)
	var d = Sun.new(Sun.PATH, false)
	near(d.asked_hour, Sun.TEST_CLOCK_HOUR, 1e-12, "8. the data's own hour source asks the clock through machine_hour (the stand-in)")
	eq(Sun.clock_reads(), 1, "8. ... once")
	eq(Sun.real_clock_reads(), 0, "8. ... and the real clock stays untouched")
	_done.append("no_wall_clock")

func _scan(dir_path: String, needles: Array[String], found: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		fail("could not open %s to scan it" % dir_path)
		return
	for sub: String in dir.get_directories():
		_scan(dir_path.path_join(sub), needles, found)
	for f: String in dir.get_files():
		if not f.ends_with(".gd"):
			continue
		var path := dir_path.path_join(f)
		var text := FileAccess.get_file_as_string(path)
		for n: String in needles:
			if text.contains(n):
				found.append(path)
				break
