extends "res://scripts/test_support/test_case.gd"

# THE SUN (builder BS, 2026-10-11; the board variants/sun-time/; the model is PROPOSED, today's sun is not).
#
#   1. ONE SOURCE, and the default changes nothing: with the data's mode (fixed) every reader -- Sun, RenderParams,
#      UiStyle, FxStyle, the pen -- gives today's 315 / 46 to the bit (the same expressions the readers used
#      when each parsed render_defaults.json), the trees' sun is the same sun, and render_defaults.json no longer
#      holds a second copy of the numbers.
#   2. THE CLOCK MODEL (pure): rises in the east, due south at noon, sets in the west; the height is a sine arc;
#      the shadow's length is clamped so dawn and dusk stay readable and the elevation a reader sees is the one the
#      clamped length belongs to; a night hour clamps to the nearest daytime hour or folds onto the arc.
#   3. THE SWITCHES: an override gives mode clock with an hour, scope "trees" moves only the trees' sun (the terrain's
#      shadows get a second direction and length for the trees only), the knobs exist, and clearing the override
#      puts today's sun back.

const Sun = preload("res://scripts/world/sun.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")

# A runtime error in a helper ends it in silence and finish() still runs (CLAUDE.md): each helper puts its mark here at its end.
var _done: Array[String] = []

func setup(_main) -> void:
	timeout_seconds = 60.0
	Sun.set_override({})
	_one_source()
	_clock_model()
	_switches()
	Sun.set_override({})
	eq(_done, ["one_source", "clock_model", "switches"] as Array[String], "every part of the test ran to its end")
	finish()

func _one_source() -> void:
	var sun = Sun.current()
	check(sun.ok(), "data/params/sun.json loads: %s" % ", ".join(sun.errors))
	eq(sun.mode, "fixed", "the data's mode is fixed: today's sun until Alex picks")
	eq(sun.scope, "all", "the data's scope is all")
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
	eq(pen, Vector2(cos(paz), sin(paz)), "the pen's data default shadow direction is the sun's, to the bit")
	# a shadow falls to the south-east of the north-west sun
	check(sun.shadow_dir().x > 0.7 and sun.shadow_dir().y > 0.7, "the shadow falls to the south-east (screen axes, y down)")
	# one copy: render_defaults.json no longer holds a default for the sun
	var rd: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/params/render_defaults.json"))
	var prm: Dictionary = (rd as Dictionary).get("parameters", {})
	for k: String in ["sun_direction", "sun_elevation"]:
		check(prm.has(k) and not (prm[k] as Dictionary).has("default"), "render_defaults.json parameters.%s keeps only its slider range, not a second copy of the value" % k)
	_done.append("one_source")

func _clock_model() -> void:
	var sun = Sun.current()
	var c: Dictionary = sun.clock_numbers()
	eq(float(c["sunrise"]), 6.0, "sunrise 6:00 (PROPOSED)")
	eq(float(c["sunset"]), 18.0, "sunset 18:00 (PROPOSED)")
	var noon: Dictionary = Sun.clock_sun(c, 12.0)
	near(float(noon["azimuth_deg"]), 180.0, 1e-9, "noon: due south")
	near(float(noon["elevation_deg"]), float(c["noon_elev"]), 1e-9, "noon: the highest sun")
	near(float(noon["sun_len"]), 1.0 / tan(deg_to_rad(float(c["noon_elev"]))), 1e-9, "noon: the shortest shadow")
	var rise: Dictionary = Sun.clock_sun(c, 6.0)
	near(float(rise["azimuth_deg"]), 90.0, 1e-9, "sunrise: due east")
	var set_s: Dictionary = Sun.clock_sun(c, 18.0)
	near(float(set_s["azimuth_deg"]), 270.0, 1e-9, "sunset: due west")
	# the way a shadow falls: the sun in the east, the shadow to the west; noon, to the north (up the screen); sunset, east
	var west := _shadow_of(float(rise["azimuth_deg"]))
	check(west.x < -0.99 and absf(west.y) < 1e-6, "at sunrise the shadow falls west")
	var north := _shadow_of(float(noon["azimuth_deg"]))
	check(north.y < -0.99 and absf(north.x) < 1e-6, "at noon the shadow falls north (up the screen)")
	var east := _shadow_of(float(set_s["azimuth_deg"]))
	check(east.x > 0.99 and absf(east.y) < 1e-6, "at sunset the shadow falls east")
	# morning and afternoon mirror each other, and the bearing only ever grows
	var prev := -1.0
	var h := 6.0
	while h <= 18.0 + 1e-9:
		var m: Dictionary = Sun.clock_sun(c, h)
		var mirror: Dictionary = Sun.clock_sun(c, 24.0 - h)
		near(float(m["elevation_deg"]), float(mirror["elevation_deg"]), 1e-9, "elevation mirrors about noon at %.1f" % h)
		near(float(m["azimuth_deg"]) + float(mirror["azimuth_deg"]), 360.0, 1e-9, "bearing mirrors about south at %.1f" % h)
		check(float(m["azimuth_deg"]) > prev, "the bearing grows through the day at %.1f" % h)
		check(float(m["sun_len"]) <= float(c["max_len"]) + 1e-12, "the shadow is never longer than the clamp at %.1f (%.3f)" % [h, float(m["sun_len"])])
		check(float(m["elevation_deg"]) > 0.0, "the reader never sees a sun on the horizon at %.1f" % h)
		near(float(m["sun_len"]), 1.0 / tan(deg_to_rad(float(m["elevation_deg"]))), 1e-9, "the length is the elevation's own at %.1f" % h)
		prev = float(m["azimuth_deg"])
		h += 0.5
	# the clamp: 7:00 would be a 15.5 degree sun; the shadow stays at the clamp
	var dawn: Dictionary = Sun.clock_sun(c, 7.0)
	near(float(dawn["sun_len"]), float(c["max_len"]), 1e-9, "7:00: the shadow is at the clamp")
	check(float(dawn["raw_elevation_deg"]) < float(dawn["elevation_deg"]), "7:00: the raw sun is lower than the one the readers see")
	var mid: Dictionary = Sun.clock_sun(c, 9.0)
	check(float(mid["sun_len"]) < float(c["max_len"]) and absf(float(mid["elevation_deg"]) - float(mid["raw_elevation_deg"])) < 1e-9, "9:00: not clamped, the raw elevation")
	# night: clamp to the nearest daytime hour, or fold the 24 hours on the arc
	for pair: Array in [[3.0, 6.0], [0.0, 6.0], [22.0, 18.0], [19.5, 18.0]]:
		var a: Dictionary = Sun.clock_sun(c, float(pair[0]), "clamp")
		var b: Dictionary = Sun.clock_sun(c, float(pair[1]), "clamp")
		near(float(a["azimuth_deg"]), float(b["azimuth_deg"]), 1e-9, "clamp: %.1f is the %.1f sun" % [pair[0], pair[1]])
	var f0: Dictionary = Sun.clock_sun(c, 0.0, "fold")
	var f24: Dictionary = Sun.clock_sun(c, 24.0, "fold")
	near(float(f0["azimuth_deg"]), 90.0, 1e-9, "fold: midnight is the sunrise sun")
	near(float(f24["azimuth_deg"]), float(f0["azimuth_deg"]), 1e-9, "fold: 24:00 is 0:00")
	var f12: Dictionary = Sun.clock_sun(c, 12.0, "fold")
	near(float(f12["azimuth_deg"]), 180.0, 1e-9, "fold: noon is still noon")
	var f6: Dictionary = Sun.clock_sun(c, 6.0, "fold")
	var nine: Dictionary = Sun.clock_sun(c, 9.0, "clamp")
	near(float(f6["azimuth_deg"]), float(nine["azimuth_deg"]), 1e-9, "fold: 6:00 is the 9:00 sun of the day")
	check(Sun.hour_text(9.5) == "09:30" and Sun.hour_text(24.0) == "00:00", "hour_text")
	_done.append("clock_model")

func _shadow_of(bearing: float) -> Vector2:
	var az := deg_to_rad(bearing + 90.0)
	return Vector2(cos(az), sin(az))

func _switches() -> void:
	eq(DebugSettings.get_choice_name("sun_mode"), "data", "the sun_mode knob defaults to the data's")
	eq(DebugSettings.get_choice_name("sun_scope"), "data", "the sun_scope knob defaults to the data's")
	near(float(DebugSettings.get_value("sun_hour")), -1.0, 1e-9, "the sun_hour knob defaults to -1 (the data's hour)")
	# clock at 9:00: every reader follows
	Sun.set_override({"mode": "clock_at_start", "hour": 9.0})
	var sun = Sun.current()
	eq(sun.mode, "clock_at_start", "override: clock_at_start")
	near(sun.azimuth_deg, 135.0, 1e-9, "9:00: the sun is in the south-east")
	near(sun.elevation_deg, 60.0 * sin(PI * 0.25), 1e-9, "9:00: a sine arc")
	check(not sun.trees_apart(), "scope all: the trees follow the same sun")
	var P := RenderParams.new()
	near(P.sunAz, 135.0, 1e-9, "RenderParams follows the clock sun")
	near(P.treeSunAz, 135.0, 1e-9, "and so do the trees")
	var ui := UiStyle.new()
	check(ui.shadow_dir().distance_to(sun.shadow_dir()) < 1e-12, "UiStyle follows the clock sun live")
	near(ui.param("sun_direction"), 135.0, 1e-9, "UiStyle's param follows too")
	var fx := FxStyle.new()
	check(fx.sun_len() == sun.sun_len(), "FxStyle follows the clock sun live")
	# the pen is read when the pen first loads or when a RenderParams configures it
	var paz: float = (sun.azimuth_deg + 90.0) * PI / 180.0
	check((InkCanvas._load_pen()["shadow_dir"] as Vector2).distance_to(Vector2(cos(paz), sin(paz))) < 1e-12, "the pen's default follows the clock sun")
	# scope trees: only the trees' cast shadows
	Sun.set_override({"mode": "clock_at_start", "hour": 9.0, "scope": "trees"})
	sun = Sun.current()
	eq(sun.azimuth_deg, 315.0, "scope trees: everything but the trees keeps the fixed sun")
	eq(sun.elevation_deg, 46.0, "scope trees: ... its elevation too")
	near(sun.tree_azimuth_deg, 135.0, 1e-9, "scope trees: the trees take the clock's bearing")
	check(sun.trees_apart(), "scope trees: two suns")
	P = RenderParams.new()
	eq(P.sunAz, 315.0, "RenderParams.sunAz stays fixed under scope trees")
	near(P.treeSunAz, 135.0, 1e-9, "RenderParams.treeSunAz is the clock's")
	var t := Terrain.new(20261009)
	var ts := TerrainShadows.new(t, P)
	check(ts.tree_dir.distance_to(sun.tree_shadow_dir()) < 1e-9 and ts.dir.distance_to(sun.shadow_dir()) < 1e-9, "TerrainShadows: scarps and structures on the fixed sun, the trees on the clock's")
	check(ts.tree_dir.distance_to(ts.dir) > 0.5, "TerrainShadows: two directions")
	Sun.set_override({})
	P = RenderParams.new()
	t = Terrain.new(20261009)
	ts = TerrainShadows.new(t, P)
	eq(ts.tree_dir, ts.dir, "TerrainShadows by default: the trees' direction is the sun's, to the bit")
	eq(ts.tree_L, ts.L, "TerrainShadows by default: the trees' length is the sun's")
	eq(ts.tree_stretch, ts.stretch, "TerrainShadows by default: the trees' stretch is the sun's")
	# a night hour under the data's rule
	Sun.set_override({"mode": "clock_at_start", "hour": 2.0})
	near(Sun.current().azimuth_deg, 90.0, 1e-9, "2:00 under the clamp rule is the 6:00 sun")
	Sun.set_override({"mode": "clock_at_start", "hour": 2.0, "night": "fold"})
	near(Sun.current().azimuth_deg, 90.0 + 180.0 * (2.0 / 24.0), 1e-9, "2:00 under the fold rule is 2/24 of the way along the arc")
	# cleared: today's sun is back
	Sun.set_override({})
	eq(Sun.current().mode, "fixed", "cleared: fixed")
	eq(Sun.current().azimuth_deg, 315.0, "cleared: 315")
	_done.append("switches")
