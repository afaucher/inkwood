extends "res://scripts/test_support/test_case.gd"

# THE BOMBS CHECK (Track S2, the strike, 2026-10-10; scripts/sim/bombs.gd has the model): Alex's decisions
# -- "per step, just like diving; you set the intent in the cone; the accuracy is based on how close you are
# to the ideal release angle; height is a good factor" -- as tests.
#
#   - the rules load from data/sim/bombs.json and a broken file is refused for its own reason
#   - the physics: fall time, ground range and the ideal release angle in closed form
#   - the cone (World.drop_cone): higher and faster reach farther and wider; the ideal point is inside it, the
#     ideal curve too; it follows a turning bomber and a later step
#   - accuracy (World.drop_spread): 1 and the smallest scatter at the ideal release angle, falling smoothly
#     with the release error, the rim factor on the rim, more scatter at height, an aim outside the cone
#     clamped to it
#   - a perfect release at a stationary target lands within the spread (statistics over many sticks, and
#     through the World)
#   - a stick scatters: its bombs are spread along the track, differ from each other and from the aim, and
#     are the same for the same seed
#   - the blast: pips by distance from the data, nothing for the air above it, own side by the data's flag,
#     nothing for a unit already down
#   - the tower destroyed by enough hits (fate "destroyed", by the bomber, at the moment of the last pip)
#   - a whole drop through the World: the events, the load, the landing
#
# The values it holds the model to are relations and the data's own numbers, so a retune passes; the
# tuning tables are in scripts/test_support/strike_tuning.gd.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")

var _rules_data: BombRules = BombRules.new()

func setup(_main) -> void:
	timeout_seconds = 120.0
	if not check(_rules_data.ok(), "data/sim/bombs.json loads: %s" % str(_rules_data.errors)):
		finish()
		return
	_rules()
	_physics()
	_cone_geometry()
	_cone_follows_the_plan()
	_accuracy()
	_perfect_release()
	_stick()
	_blast()
	_tower_destroyed()
	_full_chain()
	finish()

# --- helpers ---------------------------------------------------------------------------

# A world with a bomber at (1000, 2500) heading `heading`, in `band` at `speed`, nothing else.
func _bomber_world(band: String, speed: float, heading: float = 0.0) -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "b", "type": "bomber", "side": "allies", "controller": "player", "x": 1000.0, "y": 2500.0, "heading": heading, "altitude_band": band, "speed": speed})
	return w

func _extent(poly: PackedVector2Array, heading: float) -> Vector2:
	# (along, across) extent of a polygon in the frame of `heading`.
	var u := Vector2(cos(heading), sin(heading))
	var v := Vector2(-u.y, u.x)
	var lo_a := INF
	var hi_a := -INF
	var lo_c := INF
	var hi_c := -INF
	for p in poly:
		lo_a = minf(lo_a, p.dot(u))
		hi_a = maxf(hi_a, p.dot(u))
		lo_c = minf(lo_c, p.dot(v))
		hi_c = maxf(hi_c, p.dot(v))
	return Vector2(hi_a - lo_a, hi_c - lo_c)

# --- The rules ----------------------------------------------------------------------------

func _rules() -> void:
	var r := _rules_data
	check(r.gravity > 0.0 and r.cone_half_across > 0.0 and r.cone_half_height > 0.0 and r.release_samples >= 2, "the numbers are sane")
	check(r.rim_accuracy_factor > 0.0 and r.rim_accuracy_factor < 1.0, "the rim accuracy factor is between 0 and 1")
	# The blast tiers read from the data: within each tier's distance, its pips; beyond the last, nothing.
	check(r.blast_distances.size() >= 1, "there is at least one blast tier")
	for i in r.blast_distances.size():
		eq(r.blast_damage(r.blast_distances[i]), int(r.blast_pips[i]), "a unit exactly %s m away takes tier %d's pips" % [r.blast_distances[i], i])
		eq(r.blast_damage(r.blast_distances[i] + 0.01), int(r.blast_pips[i + 1]) if i + 1 < r.blast_distances.size() else 0, "a hair further takes the next tier's (or nothing)")
	eq(r.blast_damage(0.0), int(r.blast_pips[0]), "a direct hit takes the first tier's")
	eq(r.blast_damage(r.blast_radius_m() + 1.0), 0, "beyond the blast radius, nothing")
	var prev := 1000
	for d in range(0, 80, 2):
		var dmg := r.blast_damage(float(d))
		check(dmg <= prev, "damage never rises with distance (%d m: %d)" % [d, dmg])
		prev = dmg
	# A broken file is refused for its own reason.
	var good: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BombRules.PATH))
	var cases: Array = [
		["a missing value", "missing field 'gravity_mps2'", func(d: Dictionary) -> void: d.erase("gravity_mps2")],
		["a value with no provenance", "'cone_half_across_deg' says neither where it came from", func(d: Dictionary) -> void: d["cone_half_across_deg"] = {"value": 8}],
		["a misspelt key", "unknown field 'gravty_mps2'", func(d: Dictionary) -> void: d["gravty_mps2"] = {"value": 9.81, "_proposed": true, "_reason": "typo"}],
		["a rim factor above 1", "'rim_accuracy_factor' = 1.5 is outside", func(d: Dictionary) -> void: d["rim_accuracy_factor"] = {"value": 1.5, "_proposed": true, "_reason": "x"}],
		["blast tiers out of order", "strictly increase", func(d: Dictionary) -> void: d["blast_pips_by_distance"] = {"value": [[40, 1], [10, 3]], "_proposed": true, "_reason": "x"}],
		["a flag that is not a flag", "'blast_hits_own_side' must be true or false", func(d: Dictionary) -> void: d["blast_hits_own_side"] = {"value": "yes", "_proposed": true, "_reason": "x"}],
	]
	for c: Array in cases:
		var d: Dictionary = good.duplicate(true)
		(c[2] as Callable).call(d)
		var bad := BombRules.new(d, true)
		check(not bad.ok(), "rejected: %s" % c[0])
		check(" | ".join(bad.errors).contains(str(c[1])), "...for its own reason (%s): %s" % [c[1], " | ".join(bad.errors)])

# --- The physics ---------------------------------------------------------------------------

func _physics() -> void:
	var g := _rules_data.gravity
	near(Bombs.fall_time(400.0, g), sqrt(800.0 / g), 1e-12, "fall time is sqrt(2 h / g)")
	near(Bombs.ideal_range(85.0, 400.0, g), 85.0 * sqrt(800.0 / g), 1e-9, "a bomb flies speed x fall time ahead")
	near(Bombs.ideal_depression(85.0, 400.0, g), atan2(400.0, 85.0 * sqrt(800.0 / g)), 1e-12, "and is seen at atan(h / range) below the horizon")
	eq(Bombs.fall_time(0.0, g), 0.0, "from the ground it does not fall")
	eq(Bombs.fall_time(-5.0, g), 0.0, "(nor from below it)")
	var lows := [120.0, 400.0, 1000.0]
	for i in range(1, lows.size()):
		check(Bombs.ideal_range(85.0, lows[i], g) > Bombs.ideal_range(85.0, lows[i - 1], g), "higher: farther (%s m)" % lows[i])
		check(Bombs.ideal_depression(85.0, lows[i], g) > Bombs.ideal_depression(85.0, lows[i - 1], g), "higher: a steeper release angle (%s m)" % lows[i])
	var speeds := [50.0, 85.0, 120.0]
	for i in range(1, speeds.size()):
		check(Bombs.ideal_range(speeds[i], 400.0, g) > Bombs.ideal_range(speeds[i - 1], 400.0, g), "faster: farther (%s m/s)" % speeds[i])
		check(Bombs.ideal_depression(speeds[i], 400.0, g) < Bombs.ideal_depression(speeds[i - 1], 400.0, g), "faster: a shallower release angle (%s m/s)" % speeds[i])
	# The sight line to the landing point IS the ideal angle: a bomb released at (0, h) with the bomber's speed lands where the angle says.
	var h := 700.0
	var v := 90.0
	var rng := Bombs.ideal_range(v, h, g)
	near(h / tan(Bombs.ideal_depression(v, h, g)), rng, 1e-6, "the ideal angle points at the landing point")

# --- The cone ------------------------------------------------------------------------------------

func _cone_geometry() -> void:
	var ahead := {}
	var width := {}
	print("  cone (level bomber, step 0): band, speed -> ideal point ahead, cone extent along x across, ideal angle")
	for band: String in ["low", "medium", "high"]:
		for speed: float in [60.0, 85.0, 110.0]:
			var w := _bomber_world(band, speed)
			var c := w.drop_cone("b", 0)
			if not check(not c.is_empty() and c["ok"], "%s/%s: a cone: %s" % [band, speed, w.last_error]):
				continue
			var poly: PackedVector2Array = c["polygon"]
			check(poly.size() >= 3, "%s/%s: a polygon of %d points" % [band, speed, poly.size()])
			var ideal: Vector2 = c["ideal_aim"]
			check(Geometry2D.is_point_in_polygon(ideal, poly), "%s/%s: the ideal aim is inside the cone" % [band, speed])
			eq(c["ideal"], ideal, "%s/%s: 'ideal' is the same point" % [band, speed])
			var curve: PackedVector2Array = c["ideal_curve"]
			eq(curve.size(), _rules_data.release_samples + 1, "%s/%s: the ideal curve has a point for every part of the step" % [band, speed])
			for p in curve:
				check(Geometry2D.is_point_in_polygon(p, poly), "%s/%s: every point of the ideal curve is inside the cone" % [band, speed])
			var path: PackedVector2Array = c["release_path"]
			eq(path.size(), _rules_data.release_samples + 1, "%s/%s: and so is the release path" % [band, speed])
			near(path[0].x, 1000.0, 1e-3, "%s/%s: which starts where the bomber is" % [band, speed])
			var bx := path[path.size() / 2].x
			near(ideal.x - bx, float(c["range_m"]), 0.01, "%s/%s: the ideal point is the ground range ahead of the bomber's middle of the step" % [band, speed])
			near(ideal.y, 2500.0, 1e-3, "%s/%s: straight ahead" % [band, speed])
			near(float(c["ideal_deg"]), rad_to_deg(atan2(float(c["height_m"]), float(c["range_m"]))), 1e-6, "%s/%s: the ideal angle is atan(h / range)" % [band, speed])
			var ext := _extent(poly, 0.0)
			ahead["%s/%s" % [band, speed]] = ideal.x - bx
			width["%s/%s" % [band, speed]] = ext.y
			check(ext.y / float(c["range_m"]) > 0.15 and ext.y / float(c["range_m"]) < 0.6, "%s/%s: it is about a third of the range wide (%.0f of %.0f m)" % [band, speed, ext.y, c["range_m"]])
			print("    %-7s %5.0f m/s: ideal %5.0f m ahead, %5.0f x %4.0f m, %.1f deg" % [band, speed, ideal.x - bx, ext.x, ext.y, c["ideal_deg"]])
	for speed: float in [60.0, 85.0, 110.0]:
		check(ahead["low/%s" % speed] < ahead["medium/%s" % speed] and ahead["medium/%s" % speed] < ahead["high/%s" % speed], "higher: farther at %s m/s" % speed)
		check(width["low/%s" % speed] < width["medium/%s" % speed] and width["medium/%s" % speed] < width["high/%s" % speed], "higher: wider at %s m/s" % speed)
	for band: String in ["low", "medium", "high"]:
		check(ahead["%s/60.0" % band] < ahead["%s/85.0" % band] and ahead["%s/85.0" % band] < ahead["%s/110.0" % band], "faster: farther at the %s band" % band)
		check(width["%s/60.0" % band] < width["%s/85.0" % band] and width["%s/85.0" % band] < width["%s/110.0" % band], "faster: wider at the %s band" % band)
	# Heading: the same cone, turned.
	var east := _bomber_world("medium", 85.0, 0.0).drop_cone("b", 0)
	var north := _bomber_world("medium", 85.0, -PI / 2.0).drop_cone("b", 0)
	var d_east: Vector2 = (east["ideal_aim"] as Vector2) - Vector2(1000.0, 2500.0)
	var d_north: Vector2 = (north["ideal_aim"] as Vector2) - Vector2(1000.0, 2500.0)
	near(d_east.length(), d_north.length(), 0.5, "turned to the north the ideal point is as far ahead")
	check(d_north.y < 0.0 and absf(d_north.x) < 85.0 * 1.7, "and it is to the north (%s)" % str(d_north))
	# No bombs, no cone; a step that does not exist.
	var f := World.new()
	f.quiet = true
	f.add_unit({"id": "f", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1000.0, "y": 2500.0, "heading": 0.0})
	eq(f.drop_cone("f", 0), {}, "a fighter has no bomb cone")
	check(f.last_error.contains("no bombs"), "and says so: %s" % f.last_error)
	var b := _bomber_world("medium", 85.0)
	eq(b.drop_cone("b", 3), {}, "a bomber has steps 0..2 (not 3)")
	eq(b.drop_cone("b", -1), {}, "(nor -1)")
	eq(b.drop_cone("ghost", 0), {}, "(nor does a ghost have a cone)")

# The cone is the cone of the step AS PLANNED: a turn bends it, a later step moves it on, a climb changes it.
func _cone_follows_the_plan() -> void:
	var w := _bomber_world("medium", 85.0)
	var straight := w.drop_cone("b", 0)
	var step1 := w.drop_cone("b", 1)
	var s0: Vector2 = straight["ideal_aim"]
	var s1: Vector2 = step1["ideal_aim"]
	near(s1.x - s0.x, 85.0 * w.step_dt("b"), 0.5, "the next step's ideal point is a step further on (%.1f m)" % (s1.x - s0.x))
	# A turn to the right (clockwise) in step 0.
	w.plan_step("b", 0, {"turn": 0.25, "speed": 85.0})
	var bent := w.drop_cone("b", 0)
	var b_ideal: Vector2 = bent["ideal_aim"]
	check(b_ideal.y > s0.y + 5.0, "a right turn throws the ideal point to the right of straight ahead (%.0f m)" % (b_ideal.y - s0.y))
	check(Geometry2D.is_point_in_polygon(b_ideal, bent["polygon"]), "which is still inside the bent cone")
	for p in (bent["ideal_curve"] as PackedVector2Array):
		check(Geometry2D.is_point_in_polygon(p, bent["polygon"]), "as is every point of the bent ideal curve")
	# Planning step 0 changed the cone of step 1 too (it starts where step 0 ends).
	var step1b := w.drop_cone("b", 1)
	check((step1b["ideal_aim"] as Vector2).distance_to(s1) > 20.0, "and the cone of the next step starts where the turn left the bomber")
	# A climb in step 0 raises the cone's height and so its range.
	var w2 := _bomber_world("medium", 85.0)
	w2.plan_step("b", 0, {"altitude_band": "high", "speed": 85.0})
	var climb := w2.drop_cone("b", 0)
	var flat := _bomber_world("medium", 85.0).drop_cone("b", 0)
	check(float(climb["height_m"]) > float(flat["height_m"]), "a climb raises the height of the step's middle (%.0f against %.0f m)" % [climb["height_m"], flat["height_m"]])

# --- Accuracy --------------------------------------------------------------------------------------------

func _accuracy() -> void:
	var r := _rules_data
	near(Bombs.accuracy(0.0, r), 1.0, 1e-12, "accuracy is 1 at the ideal release angle")
	near(Bombs.accuracy(1.0, r), r.rim_accuracy_factor, 1e-12, "and the rim factor on the rim")
	near(Bombs.accuracy(0.5, r), Combat.centre_factor(r.accuracy_weapon, 0.5), 1e-12, "it is the weapons' centre factor")
	var prev := 2.0
	for i in 21:
		var a := Bombs.accuracy(float(i) / 20.0, r)
		check(a < prev, "accuracy falls with the release error (r %.2f: %.4f)" % [float(i) / 20.0, a])
		prev = a
	# A real cone: medium, level, 85 m/s.
	var w := _bomber_world("medium", 85.0)
	var cone := w.drop_cone("b", 0)
	var ideal: Vector2 = cone["ideal_aim"]
	var curve: PackedVector2Array = cone["ideal_curve"]
	var h := float(cone["height_m"])
	var sigma0 := r.spread_base_m + r.spread_per_height * h
	var at_ideal := w.drop_spread("b", 0, ideal)
	check(float(at_ideal["accuracy"]) > 0.999999 and not at_ideal["clamped"], "at the ideal point the accuracy is 1 and nothing is moved")
	near(float(at_ideal["spread_m"]), sigma0, 1e-6, "and the scatter is the base plus height times its factor (%.2f m)" % sigma0)
	near(float(at_ideal["spread"]["radius_m"]), float(at_ideal["spread_m"]), 1e-12, "(the same under 'spread')")
	for p in curve:
		var on_curve := w.drop_spread("b", 0, p)
		check(float(on_curve["accuracy"]) > 0.999, "any point of the ideal curve is as good: a release moment is found for it (%.5f)" % on_curve["accuracy"])
	# Beyond the far end of the curve, along the track: worse and worse.
	var far_end: Vector2 = curve[curve.size() - 1]
	var near_end: Vector2 = curve[0]
	var accs: Array[float] = []
	var sigmas: Array[float] = []
	var errs: Array[float] = []
	for off in [0.0, 40.0, 80.0, 120.0, 160.0]:
		var s := w.drop_spread("b", 0, far_end + Vector2(off, 0.0))
		if bool(s["clamped"]):
			break
		accs.append(float(s["accuracy"]))
		sigmas.append(float(s["spread_m"]))
		errs.append(float(s["error_deg"]))
	check(accs.size() >= 4, "the cone reaches at least 120 m beyond the ideal curve (%d points)" % accs.size())
	for i in range(1, accs.size()):
		check(accs[i] < accs[i - 1] - 1e-6, "farther past the curve: less accurate (%.4f then %.4f)" % [accs[i - 1], accs[i]])
		check(sigmas[i] > sigmas[i - 1], "and more scatter (%.1f then %.1f m)" % [sigmas[i - 1], sigmas[i]])
		check(errs[i] < errs[i - 1], "and a larger release angle error, the aim point seen at a shallower angle than ideal (%.2f then %.2f deg)" % [errs[i - 1], errs[i]])
	# Short of the near end, the same the other way: the aim point is seen steeper than ideal.
	var short_accs: Array[float] = []
	var short_errs: Array[float] = []
	for off in [0.0, 40.0, 80.0, 120.0]:
		var s := w.drop_spread("b", 0, near_end - Vector2(off, 0.0))
		if bool(s["clamped"]):
			break
		short_accs.append(float(s["accuracy"]))
		short_errs.append(float(s["error_deg"]))
	check(short_accs.size() >= 3, "and some way short of it too (%d points)" % short_accs.size())
	for i in range(1, short_accs.size()):
		check(short_accs[i] < short_accs[i - 1] - 1e-6, "nearer than the curve: less accurate (%.4f then %.4f)" % [short_accs[i - 1], short_accs[i]])
		check(short_errs[i] > short_errs[i - 1], "with the error of the other sign (%.2f then %.2f deg)" % [short_errs[i - 1], short_errs[i]])
	# Across the track.
	var cross: Array[float] = []
	for off in [0.0, 20.0, 40.0, 80.0, 120.0]:
		var s := w.drop_spread("b", 0, ideal + Vector2(0.0, off))
		if bool(s["clamped"]):
			break
		cross.append(float(s["accuracy"]))
	check(cross.size() >= 4, "the cone is more than 80 m to either side (%d points)" % cross.size())
	for i in range(1, cross.size()):
		check(cross[i] < cross[i - 1] - 1e-6, "off to the side: less accurate (%.4f then %.4f)" % [cross[i - 1], cross[i]])
	var left := w.drop_spread("b", 0, ideal + Vector2(0.0, -60.0))
	var right := w.drop_spread("b", 0, ideal + Vector2(0.0, 60.0))
	near(float(left["accuracy"]), float(right["accuracy"]), 1e-6, "left and right are the same")
	# Outside the cone: moved to its edge, where the accuracy is the rim's.
	var out := w.drop_spread("b", 0, ideal + Vector2(0.0, 600.0))
	check(out["clamped"], "an aim 600 m off the track is moved")
	near(float(out["r"]), 1.0, 0.002, "to the rim of the cone")
	near(float(out["accuracy"]), r.rim_accuracy_factor, 0.002, "where the accuracy is the rim factor (%.4f)" % out["accuracy"])
	near(float(out["spread_m"]), sigma0 / r.rim_accuracy_factor, sigma0 * 0.03, "and the scatter is the ideal one over it (%.1f m)" % out["spread_m"])
	var moved: Vector2 = out["aim"]
	check(moved.y < ideal.y + 600.0 and moved.y > ideal.y, "the moved aim is between the ideal point and the request (y %.0f)" % moved.y)
	check(Geometry2D.is_point_in_polygon(moved.lerp(ideal, 0.08), cone["polygon"]), "and it is at the polygon's edge")
	var behind := w.drop_spread("b", 0, Vector2(500.0, 2500.0))
	check(behind["clamped"] and float(behind["r"]) <= 1.0001, "an aim behind the bomber is moved into the cone too")
	# The aim is a Vector2 or [x, y]; anything else is refused.
	var as_array := w.drop_spread("b", 0, [ideal.x, ideal.y])
	near(float(as_array["accuracy"]), float(at_ideal["accuracy"]), 1e-12, "an [x, y] aim works as a Vector2")
	eq(w.drop_spread("b", 0, "there"), {}, "a string is refused")
	eq(w.drop_spread("b", 0, Vector2(INF, 0.0)), {}, "and so is an infinite point")
	# Height: more height, more scatter, at the ideal and at the same release error.
	var by_band := {}
	for band: String in ["low", "medium", "high"]:
		var wb := _bomber_world(band, 85.0)
		var cb := wb.drop_cone("b", 0)
		var ib: Vector2 = cb["ideal_aim"]
		var on := wb.drop_spread("b", 0, ib)
		# The same release error r: sideways by the same share of the cone's width at the ideal range.
		var across_m := tan(0.5 * _rules_data.cone_half_across) * float(cb["range_m"])
		var off_aim := wb.drop_spread("b", 0, ib + Vector2(0.0, across_m))
		by_band[band] = {"ideal": float(on["spread_m"]), "off": float(off_aim["spread_m"]), "acc": float(off_aim["accuracy"]), "r": float(off_aim["r"])}
	check(by_band["low"]["ideal"] < by_band["medium"]["ideal"] and by_band["medium"]["ideal"] < by_band["high"]["ideal"], "more height, more scatter at the ideal release: %.1f, %.1f, %.1f m" % [by_band["low"]["ideal"], by_band["medium"]["ideal"], by_band["high"]["ideal"]])
	check(by_band["low"]["off"] < by_band["medium"]["off"] and by_band["medium"]["off"] < by_band["high"]["off"], "and at the same release error: %.1f, %.1f, %.1f m" % [by_band["low"]["off"], by_band["medium"]["off"], by_band["high"]["off"]])
	near(float(by_band["low"]["r"]), float(by_band["high"]["r"]), 0.05, "(the release error was about the same: r %.2f, %.2f)" % [by_band["low"]["r"], by_band["high"]["r"]])
	near(float(by_band["low"]["ideal"]), r.spread_base_m + r.spread_per_height * 120.0, 1e-6, "the low band's ideal scatter is the formula's")
	near(float(by_band["high"]["ideal"]), r.spread_base_m + r.spread_per_height * 1000.0, 1e-6, "and so is the high band's")

# --- A perfect release on a stationary target -----------------------------------------------------------------------

func _perfect_release() -> void:
	for band: String in ["low", "medium", "high"]:
		var w := _bomber_world(band, 85.0)
		var cone := w.drop_cone("b", 0)
		var ideal: Vector2 = cone["ideal_aim"]
		var info := w.drop_spread("b", 0, ideal)
		var sigma := float(info["spread_m"])
		# The drop as the resolver makes it (plan_drop), then many sticks of it.
		w.plan_step("b", 0, {"drop": {"aim": [ideal.x, ideal.y]}})
		var drop: Dictionary = w.planned_states("b")[0]["drop"]
		check(drop["ok"], "%s: the drop is planned" % band)
		var n := 0
		var within2 := 0
		var within245 := 0
		var sum := Vector2.ZERO
		var sum_sq := 0.0
		var per_drop: int = w.units["b"].def.bomb_per_drop
		var spacing := 85.0 * _rules_data.release_interval_s
		for seed_value in 300:
			var stick := Bombs.make_stick(drop, per_drop, _rules_data, seed_value, 1, "b", 0, 0)
			eq(stick.size(), per_drop, "a stick has the load's bombs")
			for b: Dictionary in stick:
				var along := (float(b["bomb"]) - 0.5 * float(per_drop - 1)) * spacing
				# Residual about this bomb's place in the stick (heading 0: along is x).
				var res := Vector2(float(b["x"]) - ideal.x - along, float(b["y"]) - ideal.y)
				sum += res
				sum_sq += res.length_squared()
				n += 1
				if res.length() <= 2.0 * sigma:
					within2 += 1
				if res.length() <= 2.4495 * sigma:
					within245 += 1
		var mean := sum / float(n)
		var rms := sqrt(sum_sq / float(n) / 2.0)
		print("  perfect release, %-6s sigma %.1f m: rms per axis %.1f, mean offset (%.1f, %.1f), within 2 sigma %.0f%%, within 2.45 sigma %.0f%%" % [band, sigma, rms, mean.x, mean.y, 100.0 * within2 / n, 100.0 * within245 / n])
		check(absf(mean.x) < 0.15 * sigma and absf(mean.y) < 0.15 * sigma, "%s: centred on the aim (mean offset %.1f, %.1f of sigma %.1f)" % [band, mean.x, mean.y, sigma])
		check(absf(rms / sigma - 1.0) < 0.1, "%s: the scatter is the spread (rms %.1f against %.1f m)" % [band, rms, sigma])
		check(float(within2) / n > 0.80 and float(within2) / n < 0.92, "%s: about 86 percent of the bombs within two sigma (%.0f%%)" % [band, 100.0 * within2 / n])
		check(float(within245) / n > 0.92, "%s: and 95 percent within 2.45 sigma (%.0f%%)" % [band, 100.0 * within245 / n])
	# Through the World: a stick at the tower from the ideal release lands around it, within the spread.
	var close := 0
	var total := 0
	var sigma_w := 0.0
	for seed_value in 12:
		var w := BombWorlds.world(seed_value + 1, "low")
		var u: Unit = w.units["b"] if w.units.has("b") else w.units["bomber"]
		# Put the bomber on a perfect run at the tower: ideal release at the middle of step 0.
		u.x = BombWorlds.TOWER.x - 85.0 * 0.5 * w.step_dt("bomber") - Bombs.ideal_range(85.0, w.band_height("low"), _rules_data.gravity)
		var info := w.drop_spread("bomber", 0, BombWorlds.TOWER)
		sigma_w = float(info["spread_m"])
		w.plan_step("bomber", 0, {"drop": {"aim": [BombWorlds.TOWER.x, BombWorlds.TOWER.y]}})
		for _t in 4:
			var res := BombWorlds.turn(w)
			for ev: Dictionary in BombWorlds.events_of(res, "bomb_impact"):
				total += 1
				if Vector2(float(ev["x"]), float(ev["y"])).distance_to(BombWorlds.TOWER) <= 2.5 * sigma_w + 20.0:
					close += 1
			w.begin_turn()
	eq(total, 12 * 4, "12 sticks of 4 bombs landed")
	check(float(close) / float(total) > 0.9, "through the World: %d of %d bombs within 2.5 sigma and the stick's half length of the tower (sigma %.1f m)" % [close, total, sigma_w])

# --- A stick ----------------------------------------------------------------------------------------------------------------

func _stick() -> void:
	var w := _bomber_world("medium", 85.0)
	var ideal: Vector2 = w.drop_cone("b", 0)["ideal_aim"]
	w.plan_step("b", 0, {"drop": {"aim": [ideal.x, ideal.y]}})
	var drop: Dictionary = w.planned_states("b")[0]["drop"]
	var per_drop: int = w.units["b"].def.bomb_per_drop
	var a := Bombs.make_stick(drop, per_drop, _rules_data, 7, 1, "b", 0, 0)
	var b := Bombs.make_stick(drop, per_drop, _rules_data, 7, 1, "b", 0, 0)
	eq(a, b, "the same seed, the same stick")
	var c := Bombs.make_stick(drop, per_drop, _rules_data, 8, 1, "b", 0, 0)
	check(a != c, "another seed, another stick")
	var d := Bombs.make_stick(drop, per_drop, _rules_data, 7, 1, "b", 0, 1)
	check(a != d, "another drop of the same bomber, another stick")
	var e := Bombs.make_stick(drop, per_drop, _rules_data, 7, 1, "b", 1, 0)
	check(a != e, "another bomber, another stick")
	var f := Bombs.make_stick(drop, per_drop, _rules_data, 7, 2, "b", 0, 0)
	check(a != f, "another turn, another stick")
	# The stick's bombs differ from each other and are in order along the track, one release interval apart.
	var spacing := 85.0 * _rules_data.release_interval_s
	var gaps := 0.0
	var gap_n := 0
	var order_ok := 0
	var seeds := 80
	for seed_value in seeds:
		var s := Bombs.make_stick(drop, per_drop, _rules_data, seed_value, 1, "b", 0, 0)
		for i in range(1, s.size()):
			check(Vector2(float(s[i]["x"]), float(s[i]["y"])).distance_to(Vector2(float(s[i - 1]["x"]), float(s[i - 1]["y"]))) > 0.01, "the bombs of a stick land in different places")
			near(float(s[i]["impact_total"]) - float(s[i - 1]["impact_total"]), _rules_data.release_interval_s, 1e-9, "released one interval apart, so landing one apart")
			gaps += float(s[i]["x"]) - float(s[i - 1]["x"])
			gap_n += 1
			if float(s[i]["x"]) > float(s[i - 1]["x"]):
				order_ok += 1
		near(float(s[0]["h0"]), 400.0, 1e-9, "every bomb leaves from the bomber's height")
		near(float(s[0]["fall_s"]), Bombs.fall_time(400.0, _rules_data.gravity), 1e-9, "and falls for the time that height gives")
	near(gaps / float(gap_n), spacing, 0.15 * spacing + 6.0, "on average a bomb lands a release-interval's flight (%.1f m) beyond the one before (%.1f m)" % [spacing, gaps / float(gap_n)])
	check(float(order_ok) / float(gap_n) > 0.55, "and mostly in order along the track (%.0f%%)" % (100.0 * order_ok / gap_n))
	# The stick's bombs share an error: their scatter about the stick's own centre is smaller than about the aim.
	var about_aim := 0.0
	var about_centre := 0.0
	var count := 0
	for seed_value in 200:
		var s := Bombs.make_stick(drop, per_drop, _rules_data, seed_value, 1, "b", 0, 0)
		var centre := Vector2.ZERO
		for bm: Dictionary in s:
			centre += Vector2(float(bm["x"]), float(bm["y"]))
		centre /= float(s.size())
		for bm: Dictionary in s:
			var p := Vector2(float(bm["x"]), float(bm["y"]))
			about_aim += p.distance_squared_to(ideal)
			about_centre += p.distance_squared_to(centre)
			count += 1
	check(about_centre < about_aim, "the bombs of a stick fall nearer each other than to the aim: the stick's error is shared (%.0f against %.0f m^2)" % [about_centre / count, about_aim / count])

# --- The blast -----------------------------------------------------------------------------------------------------------------------

func _blast_world(distance: float, extra: Array = []) -> World:
	var w := BombWorlds.world(1, "medium")
	var angle := 0.9
	var at := BombWorlds.TOWER + Vector2(cos(angle), sin(angle)) * distance
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, at.x, at.y, 2.0)])
	for spec: Dictionary in extra:
		w.add_unit(spec)
	return w

func _blast() -> void:
	var r := _rules_data
	var health: int = World.new().unit_def("radio_tower").health
	var probes: Array[float] = [0.0, 5.0]
	for i in r.blast_distances.size():
		probes.append(r.blast_distances[i] - 0.5)
		probes.append(r.blast_distances[i] + 0.5)
	probes.append(r.blast_radius_m() + 30.0)
	print("  blast: distance from the impact -> pips (tower of %d)" % health)
	for d in probes:
		var w := _blast_world(maxf(d, 0.0))
		var res := BombWorlds.turn(w)
		var want := r.blast_damage(maxf(d, 0.0))
		eq(w.units["tower"].health, health - want, "a tower %.1f m from the impact takes %d pips" % [d, want])
		var hits := BombWorlds.events_of(res, "hit", "tower")
		eq(hits.size(), 1 if want > 0 else 0, "...and a hit event only if it was hurt (%.1f m)" % d)
		if want > 0 and hits.size() == 1:
			eq(hits[0]["damage"], want, "...naming the pips")
			eq(hits[0]["by"], "bomber", "...and the bomber")
			eq(hits[0]["weapon"], "bomb", "...and the weapon 'bomb'")
			near(float(hits[0]["t"]), 2.0, 1e-9, "...at the moment the bomb landed")
			eq(hits[0]["health"], health - want, "...and the health it left")
		print("    %5.1f m -> %d" % [d, want])
	# The impact event.
	var w := _blast_world(30.0)
	var res := BombWorlds.turn(w)
	var imp := BombWorlds.events_of(res, "bomb_impact")
	eq(imp.size(), 1, "one impact event")
	if imp.size() == 1:
		near(float(imp[0]["t"]), 2.0, 1e-9, "at the moment it lands")
		eq(imp[0]["unit"], "bomber", "naming the bomber")
		near(float(imp[0]["blast_m"]), r.blast_radius_m(), 1e-9, "and the blast radius")
		check(imp[0].has("x") and imp[0].has("y") and imp[0].has("bomb") and imp[0].has("drop_index") and imp[0].has("released_turn") and imp[0].has("stick"), "with the fields the effects need")
		check(float(imp[0]["x"]) != BombWorlds.TOWER.x, "at the place it landed")
	# Aircraft above are not hurt: a fighter in the low band right over the impact.
	var wa := _blast_world(0.0, [{"id": "f", "type": "light_fighter", "side": "axis", "controller": "player", "x": BombWorlds.TOWER.x, "y": BombWorlds.TOWER.y, "heading": 0.0, "altitude_band": "low", "speed": 100.0}])
	wa.units["f"].health = 50
	BombWorlds.turn(wa)
	eq(wa.units["f"].health, 50, "a plane 120 m up over the impact is not touched")
	eq(wa.units["tower"].health, health - r.blast_damage(0.0), "(the tower under it was)")
	# Own side: a battery of the bomber's own side next to the impact.
	var friend := {"id": "friend", "type": "anti_aircraft_battery", "side": "allies", "controller": "player", "x": BombWorlds.TOWER.x + 30.0, "y": BombWorlds.TOWER.y, "heading": 0.0}
	var wf := _blast_world(0.0, [friend])
	var hp: int = wf.units["friend"].health
	BombWorlds.turn(wf)
	eq(wf.units["friend"].health, hp - r.blast_damage(30.0), "a blast does not know whose side it is on (by the data's flag)")
	var wg := _blast_world(0.0, [friend])
	wg.bombs.blast_hits_own_side = false
	BombWorlds.turn(wg)
	eq(wg.units["friend"].health, hp, "unless the flag says it spares its own")
	eq(wg.units["tower"].health, health - r.blast_damage(0.0), "(the enemy's tower is still hit)")
	# A unit already down is not hit again.
	var wd := _blast_world(0.0)
	wd.units["tower"].health = 0
	wd.units["tower"].down = true
	wd.units["tower"].fate = Unit.FATE_DESTROYED
	var resd := BombWorlds.turn(wd)
	eq(BombWorlds.events_of(resd, "hit", "tower").size(), 0, "a destroyed tower is not hit again")
	eq(BombWorlds.events_of(resd, "bomb_impact").size(), 1, "(the bomb still lands)")

# --- The tower destroyed -------------------------------------------------------------------------------------------------------------------

func _tower_destroyed() -> void:
	var w := BombWorlds.world(1, "medium")
	var health: int = w.units["tower"].health
	var direct := _rules_data.blast_damage(0.0)
	var n := int(ceil(float(health) / float(direct)))
	# Enough direct hits, one a half second after another.
	var recs: Array = []
	for i in n + 2:
		recs.append(BombWorlds.record(w, BombWorlds.TOWER.x, BombWorlds.TOWER.y, 1.0 + 0.5 * float(i), i))
	BombWorlds.drop_bombs(w, recs)
	var res := BombWorlds.turn(w)
	var tower: Unit = w.units["tower"]
	check(tower.down and tower.health == 0, "the tower is down after %d direct hits of %d pips (%d pips of health)" % [n, direct, health])
	eq(tower.fate, Unit.FATE_DESTROYED, "its fate is 'destroyed'")
	check(w.units.has("tower"), "it stays in World.units")
	near(tower.down_at, 1.0 + 0.5 * float(n - 1), 1e-9, "down at the moment of the hit that took the last pip")
	var downs := BombWorlds.events_of(res, "down", "tower")
	eq(downs.size(), 1, "one down event")
	if downs.size() == 1:
		eq(downs[0]["fate"], "destroyed", "with the fate")
		eq(downs[0]["by"], "bomber", "by the bomber")
		near(float(downs[0]["t"]), tower.down_at, 1e-9, "at that moment")
		check(float(downs[0]["x"]) == BombWorlds.TOWER.x and float(downs[0]["y"]) == BombWorlds.TOWER.y and float(downs[0]["height_m"]) == 0.0, "where it stands, on the ground")
	var hits := BombWorlds.events_of(res, "hit", "tower")
	eq(hits.size(), n, "it was hit by the bombs that landed before it fell, no more (%d)" % hits.size())
	eq(BombWorlds.events_of(res, "bomb_impact").size(), n + 2, "all the bombs still landed")
	# Fewer hits leave it standing.
	var w2 := BombWorlds.world(1, "medium")
	var recs2: Array = []
	for i in n - 1:
		recs2.append(BombWorlds.record(w2, BombWorlds.TOWER.x, BombWorlds.TOWER.y, 1.0 + 0.5 * float(i), i))
	BombWorlds.drop_bombs(w2, recs2)
	BombWorlds.turn(w2)
	check(not w2.units["tower"].down and w2.units["tower"].health == health - (n - 1) * direct, "one bomb fewer and it stands, hurt (%d of %d pips)" % [w2.units["tower"].health, health])
	# Misses leave it alone.
	var w3 := BombWorlds.world(1, "medium")
	var recs3: Array = []
	for i in 6:
		recs3.append(BombWorlds.record(w3, BombWorlds.TOWER.x + _rules_data.blast_radius_m() + 5.0, BombWorlds.TOWER.y, 1.0 + 0.2 * float(i), i))
	BombWorlds.drop_bombs(w3, recs3)
	BombWorlds.turn(w3)
	eq(w3.units["tower"].health, health, "bombs that land beyond the blast radius do nothing")
	# The events come in time order.
	var last_t := -1.0
	for ev: Dictionary in res["events"]:
		check(float(ev["t"]) >= last_t - 1e-12, "events are in time order (%s at %.3f)" % [ev["type"], ev["t"]])
		last_t = float(ev["t"])

# --- A whole drop through the World ---------------------------------------------------------------------------------------------------------

func _full_chain() -> void:
	var w := BombWorlds.world(5, "medium")
	var u: Unit = w.units["bomber"]
	var per_drop: int = u.def.bomb_per_drop
	var tower := BombWorlds.TOWER
	var released := {}
	var impacts: Array = []
	var all_events: Array = []
	var planned_at := -1
	for turn_no in 10:
		if planned_at < 0 and u.drops_left > 0:
			for k in 3:
				var info := w.drop_spread("bomber", k, tower)
				if not info.is_empty() and not bool(info["clamped"]) and float(info["r"]) <= 0.4:
					var st := w.plan_step("bomber", k, {"drop": {"aim": [tower.x, tower.y]}})
					check(st.has("drop") and st["drop"]["ok"], "turn %d: the drop is planned on step %d and reported in the step's state" % [w.turn, k])
					planned_at = w.turn * 10 + k
					break
		var res := BombWorlds.turn(w)
		all_events.append_array(res["events"])
		for ev: Dictionary in res["events"]:
			if ev["type"] == "bomb_release":
				released = ev
			elif ev["type"] == "bomb_impact":
				impacts.append(ev)
		w.begin_turn()
	if not check(not released.is_empty(), "the bomber released"):
		return
	var dt: float = w.step_dt("bomber")
	var step := int(released["step"])
	eq(released["unit"], "bomber", "the release names the bomber")
	eq(released["drop_index"], 0, "its first drop")
	eq(released["bombs"], per_drop, "a stick of the load's size")
	check(float(released["t"]) >= dt * float(step) - 1e-9 and float(released["t"]) <= dt * float(step + 1) + 1e-9, "released inside the step it was planned on (t %.2f, step %d is %.2f..%.2f)" % [released["t"], step, dt * step, dt * (step + 1)])
	near(float(released["height_m"]), 400.0, 1e-9, "from the medium band's height")
	near(float(released["speed"]), 85.0, 1e-9, "at the bomber's speed")
	near(float((released["aim"] as Array)[0]), tower.x, 1e-6, "aimed at the tower (x)")
	near(float((released["aim"] as Array)[1]), tower.y, 1e-6, "(y)")
	check(float(released["accuracy"]) > 0.5 and float(released["accuracy"]) <= 1.0, "with an accuracy (%.3f)" % released["accuracy"])
	near(float(released["spread_m"]), Bombs.spread_m(400.0, float(released["accuracy"]), _rules_data), 1e-6, "and the scatter that accuracy and height give (%.1f m)" % released["spread_m"])
	near(float(released["impact_t"]), float(released["t"]) + Bombs.fall_time(400.0, _rules_data.gravity), 1e-9, "the stick's centre lands one fall time later")
	check(float(released["x"]) < tower.x and float(released["x"]) > tower.x - 1500.0, "the bomber let go west of the tower, about the ideal range back (x %.0f)" % released["x"])
	eq(impacts.size(), per_drop, "every bomb of the stick landed")
	eq(u.drops_left, u.def.bomb_drops - 1, "the bomber has one drop fewer")
	eq(w.bombs_left("bomber")["drops_left"], u.def.bomb_drops - 1, "bombs_left says so")
	eq(w.bombs_left("bomber")["per_drop"], per_drop, "and the bombs in a drop")
	eq(w.bombs_in_flight.size(), 0, "nothing is left falling")
	var sigma := float(released["spread_m"])
	var near_count := 0
	for ev: Dictionary in impacts:
		check(int(ev["turn"]) >= int(ev["released_turn"]), "a bomb lands in the turn it was released or a later one")
		if Vector2(float(ev["x"]), float(ev["y"])).distance_to(tower) <= 3.0 * sigma + 20.0:
			near_count += 1
	check(near_count >= per_drop - 1, "the bombs landed round the tower (%d of %d within 3 sigma and the stick's half length)" % [near_count, per_drop])
	var last_t := -1.0
	var last_turn := 0
	for ev: Dictionary in all_events:
		if int(ev.get("turn", 0)) == last_turn:
			check(float(ev["t"]) >= last_t - 1e-12, "events stay in time order within a turn")
		last_turn = int(ev.get("turn", 0))
		last_t = float(ev["t"])
