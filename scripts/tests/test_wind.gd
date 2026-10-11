extends "res://scripts/test_support/test_case.gd"

# THE COASTAL WIND, THE SIMULATION (decision coastal-wind, 2026-10-11; scripts/sim/wind.gd, data/sim/wind.json, and the fire's lean and drift in
# scripts/sim/fire.gd, data/sim/fire.json). Alex: "a slight wind or variety over time ... near the coast", then '1-3 looks good': by day a gentle onshore wind
# of 2-5 m/s from the sea toward the battle area, by night a lighter offshore wind of 1-3 m/s, near calm at dawn and dusk with a wandering direction; the
# direction wanders +/-15 degrees and the speed +/-30% over a few turns with short gusts on top, seeded so every player sees the same wind; all smoke drifts
# with it, fire spreads 45 m downwind and 20 m upwind instead of 30 m all round (the same 40%), the untrackable smoke zone moves with the smoke; planes and
# bombs are not moved. Headless.
#
#   1. THE DATA          data/sim/wind.json loads under the sim's rules; Alex's numbers are decisions, the rest PROPOSED; a bad file is refused
#   2. THE REGIMES       day onshore within 2-5 m/s, night offshore within 1-3, dawn and dusk under 1 m/s with a wandering direction, over many seeds and hours
#   3. THE WANDER        the direction stays within +/-15 degrees and the speed within +/-30% (and uses the room); gusts are short, small and seeded
#   4. PURE              the same inputs give the same wind at any game second, in any order, for any instance; another seed another wind
#   5. THE HOUR          the sun's hour when its mode is clock_at_start, the data's mid-afternoon while it is fixed
#   6. THE SEA           where the sea lies from the mission's centre (a synthetic coast; the Strike seed's real one); the day wind blows from it
#   7. THE WIRE          a client applying the host's snapshot, the host's turn result or net_wind() gets the host's wind, whatever its own hour
#   8. FIRE SPREAD       more likely downwind than upwind, over many seeds; 30 m all round in a calm; the wind at the turn's start
#   9. THE SMOKE ZONE    shifted downwind (a capsule), with the wind of the moment asked about; a unit downwind is in it and one upwind is not
#  10. THE SCENARIO      the scenario builder gives the World a wind (the Strike's sea breeze blows from its sea); "wind": false takes it away
#  11. WITH HEIGHT       (decision wind-with-height) the factor is 1 at 10 m, rises with height by the power law, is flat under the floor and over the cap;
#                        at_height = at x factor; at() stays the near-ground wind; the profile data loads and a bad exponent or cap is refused; the smoke zone
#                        stays at the near-ground wind

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Wind = preload("res://scripts/sim/wind.gd")
const FireRules = preload("res://scripts/sim/fire_rules.gd")
const FireState = preload("res://scripts/sim/fire.gd")
const FireFakes = preload("res://scripts/test_support/fire_fakes.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const WorldSync = preload("res://scripts/net/world_sync.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const Sun = preload("res://scripts/world/sun.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")

const SEED := 20261009
const EAST := Vector2(1.0, 0.0)

func setup(_main) -> void:
	timeout_seconds = 240.0
	for part: Script in [World, Wind, FireRules, FireState, FireFakes, BombWorlds, WorldSync, SandboxScenario, Sun, WaterGen]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	eq(_data(), true, "1. the data part ran to its end")
	eq(_regimes(), true, "2. the regimes part ran to its end")
	eq(_wander(), true, "3. the wander part ran to its end")
	eq(_pure(), true, "4. the purity part ran to its end")
	eq(_hour(), true, "5. the hour part ran to its end")
	eq(_sea(), true, "6. the sea part ran to its end")
	eq(_wire(), true, "7. the wire part ran to its end")
	eq(_spread(), true, "8. the spread part ran to its end")
	eq(_smoke_zone(), true, "9. the smoke-zone part ran to its end")
	eq(_scenario(), true, "10. the scenario part ran to its end")
	eq(_with_height(), true, "11. the wind-with-height part ran to its end")
	Sun.set_override({})
	Sun.reset()
	finish()

# --- helpers --------------------------------------------------------------------------------------------------------

# A Wind with the sea to the east (so the sea breeze blows west), at an hour and a seed. `toward` overrides the sea's direction ([] = none).
func _wind(hour: float, seed_v: int = 1, toward: Array = [1.0, 0.0]) -> Wind:
	var w: Wind = Wind.from_params({"hour": hour, "toward_sea": toward, "seed": seed_v, "v": 1}, Wind.PATH, true) as Wind
	check(w.ok() and w.configured, "(a wind at hour %.1f, seed %d is made: %s)" % [hour, seed_v, str(w.errors)])
	return w

# The angle in degrees between two vectors.
func _angle_deg(a: Vector2, b: Vector2) -> float:
	return rad_to_deg(absf(a.angle_to(b)))

func _band(p: float, n: int) -> Vector2:
	var sigma := sqrt(p * (1.0 - p) / float(n))
	return Vector2(maxf(p - 4.0 * sigma, 0.0), minf(p + 4.0 * sigma, 1.0))

func _in_band(rate: float, p: float, n: int, what: String) -> void:
	var b := _band(p, n)
	check(rate >= b.x and rate <= b.y, "%s: %.3f over %d draws is within %.3f..%.3f of %.3f" % [what, rate, n, b.x, b.y, p])

# --- 1. The data ------------------------------------------------------------------------------------------------------

func _data() -> bool:
	var w := Wind.new({}, Wind.PATH, true)
	if not check(w.ok(), "1. data/sim/wind.json loads: %s" % str(w.errors)):
		return false
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Wind.PATH))
	for path: Array in [["day", "range_mps"], ["night", "range_mps"], ["wander", "direction_deg"], ["wander", "speed_frac"]]:
		eq(str(((raw[path[0]] as Dictionary)[path[1]] as Dictionary).get("decision", "")), "coastal-wind", "1. %s.%s is Alex's (decision coastal-wind)" % [path[0], path[1]])
	for path: Array in [["fixed_hour"], ["schedule"], ["calm", "speed_mps"], ["calm", "wander_deg"], ["wander", "period_s"], ["gusts", "size_frac"], ["gusts", "length_s"], ["sea", "ring_radii_m"], ["prevailing", "speed_mps"]]:
		var rec: Dictionary = raw[path[0]] if path.size() == 1 else (raw[path[0]] as Dictionary)[path[1]]
		check(bool(rec.get("_proposed", false)) and str(rec.get("_reason", "")) != "", "1. %s is labelled PROPOSED with a reason" % str(path))
	near(w.fixed_hour, 15.0, 1e-12, "1. while the sun is fixed the wind takes a mid-afternoon hour (PROPOSED)")
	eq([w.day_min, w.day_max, w.night_min, w.night_max], [2.0, 5.0, 1.0, 3.0], "1. day 2-5 m/s, night 1-3 m/s")
	near(w.wander_dir_deg, 15.0, 1e-12, "1. direction +/-15 degrees")
	near(w.wander_speed_frac, 0.3, 1e-12, "1. speed +/-30%")
	var fr := FireFakes.rules()
	near(fr.spread_reach_down_m, 45.0, 1e-12, "1. 45 m downwind (fire.json, decision coastal-wind)")
	near(fr.spread_reach_up_m, 20.0, 1e-12, "1. 20 m upwind")
	near(fr.spread_reach_m, 30.0, 1e-12, "1. 30 m all round in a calm")
	near(fr.spread_chance, 0.4, 1e-12, "1. the 40% at touching canopies stays")
	check(fr.drift_s > 0.0, "1. fire.json smoke.drift_s is there (%s s, PROPOSED)" % str(fr.drift_s))
	var fraw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FireRules.PATH))
	eq(str(((fraw["spread"] as Dictionary)["reach_downwind_m"] as Dictionary).get("decision", "")), "coastal-wind", "1. the downwind reach is Alex's")
	check(bool(((fraw["smoke"] as Dictionary)["drift_s"] as Dictionary).get("_proposed", false)), "1. the drift is PROPOSED")
	near(fr.spread_reach(1.0, 1.0), 45.0, 1e-12, "1. reach straight downwind at full wind")
	near(fr.spread_reach(-1.0, 1.0), 20.0, 1e-12, "1. straight upwind")
	near(fr.spread_reach(0.0, 1.0), 30.0, 1e-12, "1. across the wind")
	near(fr.spread_reach(1.0, 0.0), 30.0, 1e-12, "1. a calm: 30 m downwind ...")
	near(fr.spread_reach(-1.0, 0.0), 30.0, 1e-12, "1. ... and upwind")
	near(fr.spread_reach(1.0, 0.5), 37.5, 1e-12, "1. half the wind leans it half way")
	near(fr.skew_of(4.0), 1.0, 1e-12, "1. full skew at 4 m/s (PROPOSED)")
	near(fr.skew_of(2.0), 0.5, 1e-12, "1. half at 2 m/s")
	near(fr.skew_of(9.0), 1.0, 1e-12, "1. and no more")
	# a bad file is refused
	var bad: Dictionary = raw.duplicate(true)
	(bad["wander"] as Dictionary)["speed_frac"] = {"value": 0.6, "_proposed": true, "_reason": "x"}
	check(not Wind.new({}, bad, true).ok(), "1. a wander that would take the wind out of Alex's 2-5 / 1-3 m/s ranges is refused")
	bad = raw.duplicate(true)
	(bad["gusts"] as Dictionary)["size_frac"] = {"value": 0.5, "_proposed": true, "_reason": "x"}
	check(not Wind.new({}, bad, true).ok(), "1. so is a gust that would")
	bad = raw.duplicate(true)
	(bad["schedule"] as Dictionary)["value"] = [[1.0, 0.0], [24.0, 0.0]]
	check(not Wind.new({}, bad, true).ok(), "1. a schedule that does not start at hour 0 is refused")
	bad = raw.duplicate(true)
	(bad["calm"] as Dictionary)["gust"] = 1
	check(not Wind.new({}, bad, true).ok(), "1. an unknown field is refused")
	bad = raw.duplicate(true)
	(bad["calm"] as Dictionary)["speed_mps"] = {"value": 1.2, "_proposed": true, "_reason": "x"}
	check(not Wind.new({}, bad, true).ok(), "1. a 'calm' that is not under about 1 m/s is refused")
	bad = raw.duplicate(true)
	((bad["sea"] as Dictionary)["directions"] as Dictionary).erase("_proposed")
	check(not Wind.new({}, bad, true).ok(), "1. a value with no provenance is refused")
	var w2 := Wind.new({}, Wind.PATH, true)
	check(not w2.configure({"hour": "noon", "seed": 1}), "1. params that are not numbers are refused")
	eq(w2.at(3.0), Vector2.ZERO, "1. a wind without its params blows nothing")
	return true

# --- 2. The regimes ---------------------------------------------------------------------------------------------------------

func _regimes() -> bool:
	var onshore := -EAST   # the sea is to the east: the sea breeze blows from it, to the west
	for hour: float in [10.5, 12.0, 13.5, 15.0, 16.0]:
		var max_angle := 0.0
		var lo := INF
		var hi := 0.0
		for seed_v in range(1, 9):
			var w := _wind(hour, seed_v)
			if seed_v == 1:
				near(w.mean().length(), 3.5, 1e-9, "2. hour %.1f: the day mean is the middle of 2-5 m/s" % hour)
			var g := 0.0
			while g < 400.0:
				var v := w.at(g)
				lo = minf(lo, v.length())
				hi = maxf(hi, v.length())
				max_angle = maxf(max_angle, _angle_deg(v, onshore))
				g += 0.7
		check(lo >= 2.0 - 1e-4 and hi <= 5.0 + 1e-4, "2. hour %.1f (day): the speed stays within 2-5 m/s: %.3f..%.3f" % [hour, lo, hi])
		check(max_angle <= 15.0 + 1e-3, "2. hour %.1f (day): it blows onshore, within 15 degrees of the line from the sea: %.2f" % [hour, max_angle])
	for hour: float in [21.5, 23.0, 1.0, 3.0, 4.5]:
		var max_angle := 0.0
		var lo := INF
		var hi := 0.0
		for seed_v in range(1, 9):
			var w := _wind(hour, seed_v)
			if seed_v == 1:
				near(w.mean().length(), 2.0, 1e-9, "2. hour %.1f: the night mean is the middle of 1-3 m/s" % hour)
				check(w.mean().dot(EAST) > 0.0, "2. hour %.1f: the night wind blows offshore, toward the sea" % hour)
			var g := 0.0
			while g < 400.0:
				var v := w.at(g)
				lo = minf(lo, v.length())
				hi = maxf(hi, v.length())
				max_angle = maxf(max_angle, _angle_deg(v, EAST))
				g += 0.7
		check(lo >= 1.0 - 1e-4 and hi <= 3.0 + 1e-4, "2. hour %.1f (night): the speed stays within 1-3 m/s: %.3f..%.3f" % [hour, lo, hi])
		check(max_angle <= 15.0 + 1e-3, "2. hour %.1f (night): offshore, within 15 degrees: %.2f" % [hour, max_angle])
	for hour: float in [7.0, 7.5, 8.0, 18.25, 18.75, 19.25]:
		var hi := 0.0
		var spread_deg := 0.0
		for seed_v in range(1, 9):
			var w := _wind(hour, seed_v)
			var first := w.at(0.0)
			var g := 0.0
			while g < 400.0:
				var v := w.at(g)
				hi = maxf(hi, v.length())
				spread_deg = maxf(spread_deg, _angle_deg(v, first))
				g += 1.3
		check(hi < 1.0, "2. hour %.2f (dawn or dusk): near calm, under 1 m/s: %.3f" % [hour, hi])
		check(spread_deg > 120.0, "2. hour %.2f: a wandering direction (it points %.0f degrees apart at times)" % [hour, spread_deg])
	# the blends are continuous in the hour and pass through the calm between the regimes
	var prev := _wind(0.0).mean()
	var worst := 0.0
	var h := 0.05
	while h <= 24.0:
		var cur := _wind(h).mean()
		worst = maxf(worst, (cur - prev).length())
		prev = cur
		h += 0.05
	check(worst < 0.2, "2. the mean wind changes smoothly through the day (the biggest step in 3 minutes of hour: %.3f m/s)" % worst)
	check(_wind(9.5).mean().length() > 0.5 and _wind(9.5).mean().length() < 3.4, "2. 09:30 is part way between the dawn calm and the sea breeze")
	check(_wind(9.5).mean().dot(onshore) > 0.0, "2. and it blows onshore")
	check(_wind(20.2).mean().dot(EAST) > 0.0 and _wind(20.2).mean().length() < 2.0, "2. 20:12 is part way into the land breeze, offshore")
	eq(_wind(7.5).mean(), Vector2.ZERO, "2. the dawn calm has no mean wind")
	# no sea in reach: the light prevailing wind, whatever the hour
	for hour: float in [3.0, 8.0, 14.0]:
		var wp := _wind(hour, 5, [])
		near(wp.mean().length(), 1.5, 1e-6, "2. no sea (hour %.0f): the prevailing wind, 1.5 m/s (PROPOSED)" % hour)
		check(wp.mean().x > 1.4 and absf(wp.mean().y) < 0.01, "2. from the west (270 degrees), blowing east")
		var lo := INF
		var hi := 0.0
		var g := 0.0
		while g < 300.0:
			lo = minf(lo, wp.at(g).length())
			hi = maxf(hi, wp.at(g).length())
			g += 0.9
		check(lo >= 1.5 * 0.7 - 1e-4 and hi <= 1.5 * 1.4 + 1e-4, "2. with the same wander and gusts: %.2f..%.2f m/s" % [lo, hi])
	return true

# --- 3. The wander and the gusts ----------------------------------------------------------------------------------------------

func _wander() -> bool:
	var max_dir := 0.0
	var max_sp := 0.0
	var max_gust := 0.0
	var gust_time := 0.0
	var samples := 0
	var gusts_started := 0
	for seed_v in range(1, 21):
		var w := _wind(13.0, seed_v)
		var was := 0.0
		var g := 0.0
		while g < 600.0:
			var p := w.parts(g)
			max_dir = maxf(max_dir, absf(float(p["dir_deg"])))
			max_sp = maxf(max_sp, absf(float(p["speed_frac"])))
			max_gust = maxf(max_gust, float(p["gust"]))
			if float(p["gust"]) < 0.0:
				fail("3. a gust only adds: %f" % float(p["gust"]))
			if float(p["gust"]) > 1e-6:
				gust_time += 0.37
			if float(p["gust"]) > 1e-6 and was <= 1e-6:
				gusts_started += 1
			was = float(p["gust"])
			samples += 1
			g += 0.37
	check(max_dir <= 15.0 + 1e-9, "3. the direction never wanders more than 15 degrees: %.4f" % max_dir)
	check(max_dir > 12.0, "3. and uses the room (it reaches %.2f degrees)" % max_dir)
	check(max_sp <= 0.3 + 1e-9, "3. the speed never wanders more than 30%%: %.4f" % max_sp)
	check(max_sp > 0.25, "3. and uses the room (it reaches %.3f)" % max_sp)
	check(max_gust <= 0.1 + 1e-9 and max_gust > 0.05, "3. gusts add up to 10%% of the mean on top (the biggest seen %.3f)" % max_gust)
	var per_gust := gust_time / float(maxi(gusts_started, 1))
	check(per_gust > 0.5 and per_gust <= 4.0 + 0.4, "3. gusts are short: %.2f s each on average (%d of them in %d s of 20 winds)" % [per_gust, gusts_started, 600 * 20])
	check(gust_time / (float(samples) * 0.37) < 0.5, "3. and most of the time there is none (%.0f%% of the time)" % (100.0 * gust_time / (float(samples) * 0.37)))
	# it is slow: the direction does not jump from one second to the next, and it changes over a few turns
	var w := _wind(13.0, 3)
	var step_max := 0.0
	var g2 := 0.0
	while g2 < 300.0:
		step_max = maxf(step_max, _angle_deg(w.at(g2), w.at(g2 + 0.25)))
		g2 += 0.25
	check(step_max < 1.5, "3. the direction changes slowly: at most %.2f degrees in a quarter second" % step_max)
	var turn_apart := 0.0
	g2 = 0.0
	while g2 < 300.0:
		turn_apart = maxf(turn_apart, _angle_deg(w.at(g2), w.at(g2 + 20.0)))
		g2 += 1.0
	check(turn_apart > 8.0, "3. and moves several degrees over a few turns (%.1f degrees in 20 s at most)" % turn_apart)
	# the calm air's wander is wide
	var wc := _wind(7.5, 2)
	var swing := 0.0
	var gg := 0.0
	while gg < 300.0:
		swing = maxf(swing, absf(wc.parts(gg)["calm_n"]))
		gg += 0.5
	check(swing > 0.9, "3. the calm air's direction uses its whole wander (%.2f of it)" % swing)
	return true

# --- 4. Pure -------------------------------------------------------------------------------------------------------------------

func _pure() -> bool:
	var a := _wind(14.0, 42)
	var b := _wind(14.0, 42)
	var times: Array = []
	for i in 200:
		times.append(float(i) * 1.37)
	var forward: Array = []
	for t: float in times:
		forward.append(a.at(t))
	# another instance, asked in the opposite order, interleaved with other queries, gives the same
	var reverse: Array = []
	for i in range(times.size() - 1, -1, -1):
		b.parts(times[i] * 0.5)
		b.at(times[i] + 3.3)
		reverse.append(b.at(times[i]))
	reverse.reverse()
	var same := true
	for i in times.size():
		if forward[i] != reverse[i]:
			same = false
	check(same, "4. the same inputs give the same wind at the same game second, whatever else was asked and in what order")
	var again := true
	for t: float in times:
		if a.at(t) != a.at(t):
			again = false
	check(again, "4. asking twice gives the same")
	eq(JSON.stringify(a.params()), JSON.stringify(b.params()), "4. the same parameters")
	var c := Wind.from_params(a.params(), Wind.PATH, true) as Wind
	var from_params_same := true
	for t: float in times:
		if c.at(t) != a.at(t):
			from_params_same = false
	check(from_params_same, "4. a Wind rebuilt from params() is the very same wind")
	var d := _wind(14.0, 43)
	var differs := 0
	for t: float in times:
		if d.at(t) != a.at(t):
			differs += 1
	check(differs > 150, "4. another seed is another wind (%d of 200 moments differ)" % differs)
	check(_wind(2.0, 42).at(10.0) != a.at(10.0), "4. and another regime (night) is another wind")
	check(_wind(11.0, 42).at(10.0) == a.at(10.0), "4. while two hours in the same regime (the day plateau, 11:00 and 14:00) give the same wind")
	# the params are plain values (the wire): numbers and a pair of numbers, and they survive a trip through bytes
	var ps := a.params()
	var back: Dictionary = bytes_to_var(var_to_bytes(ps)) as Dictionary
	eq(back, ps, "4. params() survive the wire as they are")
	check(Wind.from_params(back, Wind.PATH, true).at(7.7) == a.at(7.7), "4. and make the same wind")
	return true

# --- 5. The hour -----------------------------------------------------------------------------------------------------------------

func _hour() -> bool:
	var sea_east := Callable(self, "_sea_east")
	Sun.set_override({"mode": "fixed"})
	var wf: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), sea_east, 7, Rect2(0, 0, 5000, 5000), Wind.PATH, NAN, true) as Wind
	near(wf.hour, 15.0, 1e-9, "5. while the sun is fixed the wind takes the data's mid-afternoon hour")
	Sun.set_override({"mode": "clock_at_start", "hour": 3.5})
	var wn: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), sea_east, 7, Rect2(0, 0, 5000, 5000), Wind.PATH, NAN, true) as Wind
	near(wn.hour, 3.5, 1e-9, "5. with the sun's mode clock_at_start the hour is the sun's own (3.5)")
	check(wn.mean().dot(EAST) > 0.0, "5. 03:30: the land breeze, blowing toward the sea")
	Sun.set_override({"mode": "clock_at_start", "hour": 13.0})
	var wd: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), sea_east, 7, Rect2(0, 0, 5000, 5000), Wind.PATH, NAN, true) as Wind
	near(wd.hour, 13.0, 1e-9, "5. 13:00 the sea breeze")
	check(wd.mean().dot(EAST) < 0.0, "5. blowing from the sea")
	Sun.set_override({"mode": "clock_at_start", "hour": 7.5})
	var wc: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), sea_east, 7, Rect2(0, 0, 5000, 5000), Wind.PATH, NAN, true) as Wind
	near(wc.mean().length(), 0.0, 1e-9, "5. 07:30 the dawn calm")
	var wo: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), sea_east, 7, Rect2(0, 0, 5000, 5000), Wind.PATH, 20.0, true) as Wind
	near(wo.hour, 20.0, 1e-9, "5. an hour given in code is used as it is")
	Sun.set_override({})
	Sun.reset()
	return true

# --- 6. The sea --------------------------------------------------------------------------------------------------------------------

# A synthetic coast: sea (10 m deep) east of x = 3000, none elsewhere.
func _sea_east(x: float, _y: float) -> float:
	return 10.0 if x > 3000.0 else -5.0

func _sea_all(_x: float, _y: float) -> float:
	return 10.0

func _sea_none(_x: float, _y: float) -> float:
	return -5.0

func _sea() -> bool:
	var w := Wind.new({}, Wind.PATH, true)
	var bounds := Rect2(0, 0, 5000, 5000)
	var f := w.find_sea(Vector2(2000.0, 2500.0), Callable(self, "_sea_east"), bounds)
	check(bool(f["found"]), "6. a coast to the east is found (%d sea samples)" % int(f["hits"]))
	var toward: Array = f["toward"]
	check(float(toward[0]) > 0.99 and absf(float(toward[1])) < 0.1, "6. the sea lies east: (%.3f, %.3f)" % [float(toward[0]), float(toward[1])])
	check(float(f["bias"]) > 0.6, "6. and it is all on one side (bias %.2f)" % float(f["bias"]))
	var f2 := w.find_sea(Vector2(2000.0, 2500.0), Callable(self, "_sea_all"), bounds)
	check(not bool(f2["found"]), "6. sea on every side (an island) has no one direction: the prevailing wind blows (bias %.3f)" % float(f2["bias"]))
	var f3 := w.find_sea(Vector2(2000.0, 2500.0), Callable(self, "_sea_none"), bounds)
	check(not bool(f3["found"]) and int(f3["hits"]) == 0, "6. no sea in reach: none found")
	var f4 := w.find_sea(Vector2(100.0, 100.0), Callable(self, "_sea_east"), Rect2(0, 0, 500, 500))
	check(not bool(f4["found"]), "6. samples off the map are not counted (a sea beyond the map's edge does not count)")
	# the mission's wind from it: the day wind blows from the sea
	var wd: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), Callable(self, "_sea_east"), 3, bounds, Wind.PATH, 13.0, true) as Wind
	check(wd.has_sea and wd.mean().x < -3.0, "6. the day wind of this coast blows west, from the sea: %s" % str(wd.mean()))
	check(wd.onshore().x < -0.99 and wd.toward_sea().x > 0.99, "6. onshore() and toward_sea() are opposites")
	var wp: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), Callable(self, "_sea_none"), 3, bounds, Wind.PATH, 13.0, true) as Wind
	check(not wp.has_sea and wp.toward_sea() == Vector2.ZERO, "6. no sea: the prevailing wind")
	var wi: Wind = Wind.for_mission(Vector2(2000.0, 2500.0), Callable(), 3, bounds, Wind.PATH, 13.0, true) as Wind
	check(not wi.has_sea, "6. no water query at all: the same")
	# the Strike seed's real sea
	var water: RefCounted = WaterGen.shared(SEED)
	var site: Vector2 = WorldLayout.shared(SEED).sites()["radio_tower"]
	var wr: Wind = Wind.for_mission(site, Callable(water, "sea_s"), 11, Rect2(0, 0, 5000, 5000), Wind.PATH, 14.0, true) as Wind
	if not check(wr.has_sea, "6. the Strike seed has a sea in reach of its village"):
		return false
	var dir := wr.toward_sea()
	var near_cone := 0
	var far_cone := 0
	for k in 24:
		var ang := TAU * float(k) / 24.0
		var d := Vector2.from_angle(ang)
		for radius: float in [400.0, 800.0, 1200.0, 1600.0, 2000.0]:
			var p := site + d * radius
			if float(water.sea_s(p.x, p.y)) >= 2.0 and p.x >= 0.0 and p.x <= 5000.0 and p.y >= 0.0 and p.y <= 5000.0:
				if d.dot(dir) > 0.5:
					near_cone += 1
				elif d.dot(dir) < -0.5:
					far_cone += 1
	check(near_cone > far_cone, "6. the sea of the Strike seed lies the way the wind says: %d sea samples in the cone toward (%.2f, %.2f), %d in the opposite" % [near_cone, dir.x, dir.y, far_cone])
	check(wr.mean().dot(dir) < -3.0, "6. and its day wind blows from it: mean %s" % str(wr.mean()))
	print("[test] the Strike seed's sea lies toward (%.3f, %.3f) from the village" % [dir.x, dir.y])
	return true

# --- 7. The wire ---------------------------------------------------------------------------------------------------------------------

func _world_with(hour: float, seed_v: int) -> World:
	var w := BombWorlds.world(1)
	w.set_wind(_wind(hour, seed_v))
	return w

func _wire() -> bool:
	var host := _world_with(14.0, 77)
	var client := _world_with(2.0, 5)       # this machine's own hour says night, and it made its own seed
	var probe := [0.0, 1.0, 7.3, 12.9, 31.0]
	var differ := false
	for t: float in probe:
		if client.wind.at(t) != host.wind.at(t):
			differ = true
	check(differ, "7. (a client's own wind differs from the host's: a different hour and seed)")
	var snap := host.net_wind()
	check(not snap.is_empty() and snap.has("hour") and snap.has("seed") and snap.has("toward_sea"), "7. net_wind() holds the defining parameters: %s" % str(snap))
	client.apply_net_wind(bytes_to_var(var_to_bytes(snap)) as Dictionary)
	for t: float in probe:
		check(client.wind.at(t) == host.wind.at(t), "7. after applying the host's wind the client's blows the host's at %.1f s" % t)
	eq(client.wind.params(), host.wind.params(), "7. with the host's parameters")
	# through the WorldSync snapshot, a joiner
	var ws_host := WorldSync.new()
	ws_host.world = host
	ws_host.scenario_id = "test"
	var snapshot := ws_host.snapshot()
	check(snapshot.has("wind") and not (snapshot["wind"] as Dictionary).is_empty(), "7. the snapshot carries the wind")
	var joiner := _world_with(21.0, 9)
	var ws_c := WorldSync.new()
	ws_c.world = joiner
	ws_c.scenario_id = "test"
	ws_c.apply_snapshot(bytes_to_var(var_to_bytes(snapshot)) as Dictionary)
	for t: float in probe:
		check(joiner.wind.at(t) == host.wind.at(t), "7. a joiner given the snapshot blows the host's wind at %.1f s" % t)
	ws_host.free()
	ws_c.free()
	# through a turn result, every turn
	var host2 := _world_with(14.0, 77)
	var client2 := _world_with(3.0, 8)
	var res := BombWorlds.turn(host2)
	check(not res.is_empty() and res.has("wind"), "7. the turn result carries the wind")
	check(client2.apply_resolution(bytes_to_var(var_to_bytes(res)) as Dictionary), "7. the client applies the host's result: %s" % client2.last_error)
	for t: float in probe:
		check(client2.wind.at(t) == host2.wind.at(t), "7. and blows the host's wind at %.1f s" % t)
	# a World without wind sends none, and a client with none stays without
	var bare := BombWorlds.world(1)
	eq(bare.net_wind(), {}, "7. no wind: net_wind() is empty")
	check(bare.wind == null, "7. world.wind is null")
	var res_bare := BombWorlds.turn(bare)
	check(not res_bare.has("wind"), "7. and the turn result has no wind")
	var bare_c := BombWorlds.world(1)
	check(bare_c.apply_resolution(bytes_to_var(var_to_bytes(res_bare)) as Dictionary) and bare_c.wind == null, "7. a client with none stays without")
	bare_c.apply_net_wind({})
	check(bare_c.wind == null, "7. an empty net_wind() makes none")
	# a wind the host has and the client's World has no fire for: the fire follows the wind when both exist
	var wf := _world_with(14.0, 3)
	wf.enable_fire(null)
	check(wf.fire.wind == wf.wind, "7. the fire is given the World's wind")
	wf.apply_net_wind(_wind(2.0, 4).params())
	check(wf.fire.wind == wf.wind and wf.wind.hour == 2.0, "7. and follows a wind that is replaced")
	return true

# --- 8. Fire spread ----------------------------------------------------------------------------------------------------------------------

# How often a tree at `offset` metres from a burning one (both canopies 8 m) catches in turn 2, over `runs` seeds, with this wind (null: a calm).
func _spread_rate(offset: Vector2, wind: RefCounted, runs: int, rules_in: FireRules = null) -> float:
	var lit := 0
	for s in range(1, runs + 1):
		var ft := FireFakes.FakeTrees.new()
		ft.add(1, 0.0, 0.0, 8.0)
		ft.add(2, offset.x, offset.y, 8.0)
		var f := FireFakes.state(ft, rules_in, wind)
		f.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 1.0, "bomb")
		f.resolve_turn(2, s, {}, [], FireFakes.stand(0.0, 0.0))
		if f.trees.has("f2"):
			lit += 1
	return float(lit) / float(runs)

func _spread() -> bool:
	var runs := 1500
	var gap := 12.0
	var dist := 16.0 + gap
	var east := Vector2(dist, 0.0)
	var west := Vector2(-dist, 0.0)
	var north := Vector2(0.0, dist)
	var gale := FireFakes.FakeWind.new(Vector2(5.0, 0.0))          # east, over the full-skew speed
	# the expected chances, from the rules: 40% at touching falling to 0 at the reach in that direction
	_in_band(_spread_rate(east, gale, runs), 0.4 * (1.0 - gap / 45.0), runs, "8. downwind (45 m reach) at a 12 m gap")
	_in_band(_spread_rate(west, gale, runs), 0.4 * (1.0 - gap / 20.0), runs, "8. upwind (20 m reach) at a 12 m gap")
	_in_band(_spread_rate(north, gale, runs), 0.4 * (1.0 - gap / 30.0), runs, "8. across the wind (30 m reach)")
	var calm := FireFakes.FakeWind.new(Vector2.ZERO)
	for off: Vector2 in [east, west, north]:
		_in_band(_spread_rate(off, calm, runs), 0.4 * (1.0 - gap / 30.0), runs, "8. in a calm (a zero wind) the reach is 30 m all round: %s" % str(off))
	_in_band(_spread_rate(west, null, runs), 0.4 * (1.0 - gap / 30.0), runs, "8. with no wind at all, the same")
	# far downwind a tree still catches where upwind it cannot
	var far_gap := 25.0
	var far_east := Vector2(16.0 + far_gap, 0.0)
	_in_band(_spread_rate(far_east, gale, runs), 0.4 * (1.0 - far_gap / 45.0), runs, "8. 25 m downwind (past the calm reach) still catches")
	eq(_spread_rate(-far_east, gale, 400), 0.0, "8. 25 m upwind (past the 20 m reach) never does")
	eq(_spread_rate(Vector2(16.0 + 46.0, 0.0), gale, 400), 0.0, "8. 46 m downwind never does")
	# half the wind leans it half way
	var breeze := FireFakes.FakeWind.new(Vector2(2.0, 0.0))
	_in_band(_spread_rate(east, breeze, runs), 0.4 * (1.0 - gap / 37.5), runs, "8. a 2 m/s wind leans the reach half way (37.5 m downwind)")
	# the wind is the wind AT THE TURN'S START (PROPOSED): it turns at game second 7 -- after turn 2 begins (second 5), before its middle (7.5)
	var turning := FireFakes.FakeWind.new(Vector2(5.0, 0.0), Vector2(-5.0, 0.0), 7.0)
	_in_band(_spread_rate(east, turning, runs), 0.4 * (1.0 - gap / 45.0), runs, "8. the wind at the turn's start (east) leans the turn's spread: downwind is east")
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FireRules.PATH))
	((raw["spread"] as Dictionary)["wind_at"] as Dictionary)["value"] = "turn_middle"
	var mid_rules := FireRules.new(raw, true)
	check(mid_rules.ok(), "8. (the other setting loads: %s)" % str(mid_rules.errors))
	_in_band(_spread_rate(west, turning, runs, mid_rules), 0.4 * (1.0 - gap / 45.0), runs, "8. (wind_at turn_middle: the wind of the middle of the turn, west, leans it west)")
	# the real wind: a day wind blowing west (the sea is east), so the fire runs west more than east
	var real := _wind(13.0, 4)
	var down := _spread_rate(west, real, 2000)
	var up := _spread_rate(east, real, 2000)
	check(down > up + 0.05, "8. with the real coastal wind (day, blowing west) a fire spreads further downwind than upwind: %.3f against %.3f" % [down, up])
	var night := _wind(2.0, 4)    # offshore: blowing east, lighter
	var down_n := _spread_rate(east, night, 2000)
	var up_n := _spread_rate(west, night, 2000)
	check(down_n > up_n + 0.02, "8. and at night the other way, less: %.3f against %.3f" % [down_n, up_n])
	check((down - up) > (down_n - up_n), "8. the day breeze leans it more than the night one (%.3f against %.3f)" % [down - up, down_n - up_n])
	return true

# --- 9. The smoke zone -----------------------------------------------------------------------------------------------------------------

func _smoke_zone() -> bool:
	var drift_s := FireFakes.rules().drift_s
	var f := FireFakes.state(null, null, FireFakes.FakeWind.new(Vector2(5.0, 0.0)))
	f.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
	var g := 2.0
	var drift := f.drift_at(g)
	near(drift.x, 5.0 * drift_s, 1e-9, "9. the smoke has drifted wind x drift_s: %.1f m" % drift.x)
	check(f.smoke_at(drift.x + 8.0 + 20.0 - 0.5, 0.0, g), "9. a point just inside the drifted capsule's far end (downwind) is in the smoke")
	check(not f.smoke_at(drift.x + 8.0 + 20.0 + 0.5, 0.0, g), "9. one just outside is not")
	check(not f.smoke_at(-(8.0 + 20.0) - 0.5, 0.0, g), "9. upwind, the zone reaches no farther than the canopy's own 20 m")
	check(f.smoke_at(-(8.0 + 20.0) + 0.5, 0.0, g), "9. but does reach that far")
	check(f.smoke_at(drift.x * 0.5, 27.5, g) and not f.smoke_at(drift.x * 0.5, 28.5, g), "9. across the wind the zone is 28 m wide either side of the drift's line (a capsule)")
	# the zone is judged with the wind of the moment asked about
	var turning := FireFakes.state(null, null, FireFakes.FakeWind.new(Vector2(5.0, 0.0), Vector2(-5.0, 0.0), 6.0))
	turning.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
	check(turning.smoke_at(40.0, 0.0, 3.0) and not turning.smoke_at(-40.0, 0.0, 3.0), "9. while the wind blows east the zone is east of the tree")
	check(turning.smoke_at(-40.0, 0.0, 9.0) and not turning.smoke_at(40.0, 0.0, 9.0), "9. and when it turns west, west")
	var calm := FireFakes.state(null, null, null)
	calm.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
	check(calm.smoke_at(27.0, 0.0, 2.0) and calm.smoke_at(-27.0, 0.0, 2.0) and not calm.smoke_at(40.0, 0.0, 2.0) and not calm.smoke_at(-40.0, 0.0, 2.0), "9. with no wind the zone stays on the canopy, 28 m all round")
	var zero := FireFakes.state(null, null, FireFakes.FakeWind.new(Vector2.ZERO))
	zero.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
	check(not zero.smoke_at(40.0, 0.0, 2.0), "9. a dead calm drifts nothing")
	# the zone still ends with the tree: out at the end of its last turn, no matter the wind
	check(not f.smoke_at(10.0, 0.0, f.game_time(4, 0.0)), "9. a tree that has burnt out has no smoke, drifting or not")
	# in the World: a unit downwind is denied tracking, a unit at the same distance upwind is not -- with the real wind
	var w := BombWorlds.world(1)
	w.set_wind(_wind(13.0, 6))
	w.enable_fire(null)
	var c := Vector2(1000.0, 1000.0)
	w.fire.add_lit(FireFakes.tree(1, c.x, c.y, 8.0), 1, 0.0, "bomb")
	var v: Vector2 = w.wind.at(0.0)
	var dv: Vector2 = v * drift_s
	var dir := v.normalized()
	var down_pt := c + dir * (dv.length() + 20.0)
	var up_pt := c - dir * (dv.length() + 20.0)
	w.add_unit({"id": "tank_down", "type": "tank", "side": "axis", "controller": "ai", "x": down_pt.x, "y": down_pt.y, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "tank_up", "type": "tank", "side": "axis", "controller": "ai", "x": up_pt.x, "y": up_pt.y, "heading": 0.0, "speed": 0.0})
	check(w.tracking_denied("tank_down"), "9. a tank %.0f m downwind of the burning tree is in the smoke (denied tracking)" % (dv.length() + 20.0))
	check(not w.tracking_denied("tank_up"), "9. a tank the same distance upwind is not")
	var w0 := BombWorlds.world(1)
	w0.enable_fire(null)
	w0.fire.add_lit(FireFakes.tree(1, c.x, c.y, 8.0), 1, 0.0, "bomb")
	w0.add_unit({"id": "tank_down", "type": "tank", "side": "axis", "controller": "ai", "x": down_pt.x, "y": down_pt.y, "heading": 0.0, "speed": 0.0})
	check(not w0.tracking_denied("tank_down"), "9. (with no wind the same tank is out of the zone)")
	return true

# --- 10. The scenario --------------------------------------------------------------------------------------------------------------------

func _scenario() -> bool:
	Sun.set_override({"mode": "fixed"})
	Sun.reset()
	for id: String in ["strike", "suppress", "intercept", "sandbox"]:
		var sc := SandboxScenario.new(id, true)
		check(sc.ok() and sc.wind_on, "10. %s: the wind switch is on unless the file says otherwise" % id)
		var w := World.new()
		w.quiet = true
		sc.populate(w)
		if not check(w.wind != null, "10. %s: its World has a wind" % id):
			continue
		check(w.wind.ok() and w.wind.configured, "10. and it is configured")
		near(w.wind.hour, 15.0, 1e-9, "10. %s: the sun is fixed, so the wind takes the mid-afternoon hour" % id)
		if sc.water_on:
			check(w.wind.has_sea and w.wind.mean().dot(w.wind.toward_sea()) < -3.0, "10. %s: it has a sea and the day wind blows from it: toward the sea %s, mean %s" % [id, str(w.wind.toward_sea()), str(w.wind.mean())])
		else:
			check(not w.wind.has_sea and w.wind.mean().length() > 1.4, "10. %s: no water, no sea: the light prevailing wind" % id)
		check(not w.net_wind().is_empty(), "10. %s: net_wind() has the parameters" % id)
	var off := SandboxScenario.new("strike", true, {"wind": false})
	var wo := World.new()
	wo.quiet = true
	off.populate(wo)
	check(not off.wind_on and wo.wind == null, "10. \"wind\": false leaves world.wind null")
	check(not SandboxScenario.new("strike", true, {"wind": "yes"}).ok(), "10. a wind switch that is not true or false is an error")
	# the same scenario, the same wind: the seed is the scenario's
	var a := World.new()
	a.quiet = true
	SandboxScenario.new("strike", true).populate(a)
	var b := World.new()
	b.quiet = true
	SandboxScenario.new("strike", true).populate(b)
	eq(a.wind.params(), b.wind.params(), "10. two Worlds of the same scenario build the same wind")
	# the sun at clock_at_start: the night hour makes the land breeze, offshore
	Sun.set_override({"mode": "clock_at_start", "hour": 2.0})
	var wn := World.new()
	wn.quiet = true
	SandboxScenario.new("strike", true).populate(wn)
	near(wn.wind.hour, 2.0, 1e-9, "10. with the sun at clock_at_start the wind has the sun's hour (2.0)")
	check(wn.wind.mean().dot(wn.wind.toward_sea()) > 1.5, "10. and it blows offshore, toward the sea")
	Sun.set_override({})
	Sun.reset()
	# with the fire on (Suppress), the fire is given the wind
	var sp := World.new()
	sp.quiet = true
	SandboxScenario.new("suppress", true).populate(sp)
	check(sp.fire != null and sp.wind != null and sp.fire.wind == sp.wind, "10. Suppress: the fire is given the wind")
	return true

# --- 11. The wind with height ------------------------------------------------------------------------------------------------------------

func _with_height() -> bool:
	var w := _wind(13.0, 8)
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Wind.PATH))
	var prof: Dictionary = raw["profile"]
	# the data: the rule is Alex's, the numbers the lead's
	eq(str((prof["rule"] as Dictionary).get("decision", "")), "wind-with-height", "11. the rule is Alex's (decision wind-with-height)")
	eq(str((prof["rule"] as Dictionary)["value"]), "power_law", "11. a power law")
	for key: String in ["reference_height_m", "exponent", "floor_m", "cap_m"]:
		var rec: Dictionary = prof[key]
		check(bool(rec.get("_proposed", false)) and str(rec.get("_reason", "")) != "", "11. profile.%s is PROPOSED with a reason" % key)
	near(w.profile_ref_m, 10.0, 1e-12, "11. reference height 10 m")
	near(w.profile_exponent, 0.2, 1e-12, "11. exponent 0.2")
	near(w.profile_floor_m, 2.0, 1e-12, "11. floor 2 m")
	near(w.profile_cap_m, 500.0, 1e-12, "11. cap 500 m")
	# the factor
	eq(w.height_factor(10.0), 1.0, "11. the factor is exactly 1 at the reference height (10 m)")
	var prev := 0.0
	var h := 2.0
	var rising := true
	while h <= 500.0:
		var f := w.height_factor(h)
		if f <= prev:
			rising = false
		prev = f
		h += 1.0
	check(rising, "11. the factor increases with height, from the floor to the cap")
	near(w.height_factor(100.0), pow(10.0, 0.2), 1e-12, "11. at 100 m it is the power law: 10 ^ 0.2 = %.4f (about 1.6)" % w.height_factor(100.0))
	near(w.height_factor(300.0), pow(30.0, 0.2), 1e-12, "11. at 300 m: 30 ^ 0.2 = %.4f (about 2)" % w.height_factor(300.0))
	check(absf(w.height_factor(100.0) - 1.6) < 0.05 and absf(w.height_factor(300.0) - 2.0) < 0.05, "11. 'roughly 1.6x at 100 m and 2x at 300 m'")
	near(w.height_factor(50.0), pow(5.0, 0.2), 1e-12, "11. at 50 m")
	near(w.height_factor(25.0), pow(2.5, 0.2), 1e-12, "11. at 25 m")
	# flat above the cap and below the floor
	var cap_f := w.height_factor(500.0)
	near(cap_f, pow(50.0, 0.2), 1e-12, "11. at the cap, 500 m: 50 ^ 0.2 = %.4f" % cap_f)
	for hh: float in [501.0, 800.0, 3000.0, 100000.0]:
		eq(w.height_factor(hh), cap_f, "11. flat above the cap: %.0f m" % hh)
	var floor_f := w.height_factor(2.0)
	near(floor_f, pow(0.2, 0.2), 1e-12, "11. at the floor, 2 m: 0.2 ^ 0.2 = %.4f" % floor_f)
	for hh: float in [1.99, 1.0, 0.0, -5.0]:
		eq(w.height_factor(hh), floor_f, "11. flat below the floor: %.2f m" % hh)
	check(floor_f < 1.0 and cap_f > 1.0, "11. a puff just off the ground drifts a little slower than the 10 m wind, and high aloft faster")
	# the deterministic power against the engine's
	var worst := 0.0
	for xv: float in [0.05, 0.2, 0.7, 1.0, 1.4, 3.0, 10.0, 30.0, 50.0, 100.0]:
		for a: float in [0.2, 0.5, 1.0 / 3.0, 0.9, 1.0]:
			worst = maxf(worst, absf(Wind.pow_exact(xv, a) / pow(xv, a) - 1.0))
	check(worst < 1e-13, "11. the power built from + - * / alone agrees with the engine's to %s (relative)" % String.num(worst, 18))
	eq(Wind.pow_exact(7.0, 0.0), 1.0, "11. x ^ 0 is 1")
	eq(Wind.pow_exact(1.0, 0.2), 1.0, "11. 1 ^ a is 1")
	# at_height = at x factor; at() is the near-ground wind, unchanged
	var same := true
	var near_ground_ok := true
	for g in range(0, 200, 7):
		for hm: float in [0.0, 2.0, 10.0, 37.0, 100.0, 300.0, 500.0, 900.0]:
			if w.at_height(float(g), hm) != w.at(float(g)) * w.height_factor(hm):
				same = false
		if w.at_height(float(g), 10.0) != w.at(float(g)):
			near_ground_ok = false
	check(same, "11. at_height(g, h) is exactly at(g) x height_factor(h)")
	check(near_ground_ok, "11. at the reference height at_height is at(): at() is the near-ground wind")
	var lo := INF
	var hi := 0.0
	var hi100 := 0.0
	var lo100 := INF
	for seed_v in range(1, 6):
		var wd := _wind(13.0, seed_v)
		var g := 0.0
		while g < 300.0:
			lo = minf(lo, wd.at(g).length())
			hi = maxf(hi, wd.at(g).length())
			lo100 = minf(lo100, wd.at_height(g, 100.0).length())
			hi100 = maxf(hi100, wd.at_height(g, 100.0).length())
			g += 0.9
	check(lo >= 2.0 - 1e-4 and hi <= 5.0 + 1e-4, "11. at() stays within Alex's 2-5 m/s at the reference height: %.3f..%.3f" % [lo, hi])
	near(hi100 / hi, w.height_factor(100.0), 1e-5, "11. and at 100 m the same wind is %.2f times as fast (%.2f m/s at most)" % [w.height_factor(100.0), hi100])
	check(w.at_height(5.0, 300.0).normalized().dot(w.at(5.0).normalized()) > 0.999999, "11. the wind aloft blows the same way, only faster")
	# the 'uniform' rule is the old one-wind-at-every-height; the profile data is checked
	var uni: Dictionary = raw.duplicate(true)
	((uni["profile"] as Dictionary)["rule"] as Dictionary)["value"] = "uniform"
	var wu := Wind.new({"hour": 13.0, "toward_sea": [1.0, 0.0], "seed": 8}, uni, true)
	check(wu.ok() and wu.height_factor(300.0) == 1.0 and wu.height_factor(0.0) == 1.0 and wu.at_height(4.0, 300.0) == wu.at(4.0), "11. the rule 'uniform' is one wind at every height")
	for bad_case: Array in [["exponent", -0.1], ["exponent", 1.5], ["cap_m", 2.0], ["cap_m", 1.0], ["cap_m", 0.0], ["floor_m", 0.0], ["floor_m", 600.0], ["reference_height_m", 0.0]]:
		var bad: Dictionary = raw.duplicate(true)
		((bad["profile"] as Dictionary)[bad_case[0]] as Dictionary)["value"] = bad_case[1]
		check(not Wind.new({}, bad, true).ok(), "11. profile.%s = %s is refused" % [bad_case[0], str(bad_case[1])])
	var bad_rule: Dictionary = raw.duplicate(true)
	((bad_rule["profile"] as Dictionary)["rule"] as Dictionary)["value"] = "log_law"
	check(not Wind.new({}, bad_rule, true).ok(), "11. a rule the code does not know is refused")
	var missing: Dictionary = raw.duplicate(true)
	(missing["profile"] as Dictionary).erase("exponent")
	check(not Wind.new({}, missing, true).ok(), "11. a missing exponent is refused")
	var no_prov: Dictionary = raw.duplicate(true)
	(((no_prov["profile"] as Dictionary)["cap_m"]) as Dictionary).erase("_proposed")
	check(not Wind.new({}, no_prov, true).ok(), "11. a value with no provenance is refused")
	var extra: Dictionary = raw.duplicate(true)
	(extra["profile"] as Dictionary)["top_m"] = 1
	check(not Wind.new({}, extra, true).ok(), "11. an unknown field in the profile is refused")
	# the fake wind the fire tests use has the same two calls
	var fake := FireFakes.FakeWind.new(Vector2(3.0, 0.0))
	fake.exponent = 0.2
	near(fake.height_factor(10.0), 1.0, 1e-12, "11. (the test wind: 1 at 10 m)")
	near(fake.at_height(1.0, 100.0).x, 3.0 * pow(10.0, 0.2), 1e-5, "11. (and at_height = at x factor)")
	eq(FireFakes.FakeWind.new(Vector2(3.0, 0.0)).at_height(1.0, 300.0), Vector2(3.0, 0.0), "11. (a test wind with no exponent is one wind at every height)")
	# THE SMOKE ZONE stays at the near-ground wind: the fire drifts its zone with at(), never at_height()
	var fz := FireFakes.state(null, null, fake)
	fz.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
	var dr := fz.drift_at(2.0)
	near(dr.x, 3.0 * FireFakes.rules().drift_s, 1e-9, "11. the smoke zone drifts with the near-ground wind x drift_s (%.1f m), not the faster wind aloft" % dr.x)
	var real := _wind(13.0, 8)
	var fr := FireFakes.state(null, null, real)
	fr.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
	check(fr.drift_at(3.0) == real.at(3.0) * FireFakes.rules().drift_s, "11. and so does a real wind's: drift = at(g) x drift_s")
	var fraw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FireRules.PATH))
	var reason := str((fraw["smoke"] as Dictionary).get("_reason", ""))
	check(reason.find("near-ground") >= 0 or reason.find("NEAR-GROUND") >= 0, "11. fire.json's smoke._reason says the zone stays at the near-ground wind")
	return true
