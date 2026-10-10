extends RefCounted

# THE BOMBS: the physics and the geometry of a bomb drop (Track S2, proposed
# 2026-10-10 for the strike, on Alex's decisions bomb-release and bomb-load:
# "It is per step, just like diving. You set the intent in the cone. The accuracy
# is based on how close you are to the ideal release angle." "Height is a good
# factor." "The smaller bombers have fewer to release. Both per drop and number of
# drops. Everything gets at least two. Multiple passes make sense."). Pure
# functions, headless, no nodes; the rolls are seeded here and drawn by the
# resolver (combat_resolver.gd); the numbers are data/sim/bombs.json (bomb_rules.gd)
# and the bomber's own bomb_load (data/units/<id>.json).
#
# THE REQUEST. A step's request may carry a drop:
#
#     {"turn": ..., "speed": ..., "drop": {"aim": [x, y]}}        (aim: [x, y] or a Vector2)
#     {"turn": ..., "drop": {"aim": [x, y], "target": {"unit": "radio_tower_1"}}}   or   {"point": [x, y]}
#
# The step is flown as usual (envelope.gd); the drop is a SPECIAL taken in that step,
# the way a dive is a band change in it. At most one drop a step, at most as many
# drops in a turn as the bomber has left (World.bombs_left); a drop with none left is
# refused by plan_step.
#
# THE TARGET (Track T, 2026-10-10; Alex, decision special-targeting: "The special is active and targeted for the
# step" -- a unit "could have two targets for different specials across two steps"): a drop may carry the target
# it was activated with, an enemy unit ({"unit": id}) or a point ({"point": [x, y]}). It is part of the step's
# request, so it crosses the wire with the plan, reaches the co-op partners and survives the snapshot, and the
# step's analysis (the "drop" of the step state, and the bomb_release event) carries it. The "aim" is where the stick
# is centred; for a POINT target and for a drop with no target it is the aim the request names. A POINT target is fixed.
#
# A UNIT TARGET FOLLOWS THE UNIT (Alex: "Targeting a moving unit like a tank should follow the unit. We need to pick
# the release point for bombs and things dynamically."). The request's aim is then only the planning preview: the unit's
# position as the planning player saw it (so the card and the map show a fixed aim, and the enemy's motion is never
# projected there). When the turn is RESOLVED the World knows where the unit goes (World._resolve_followed_drops) and
# the aim becomes a function of the release moment t: the unit's position at t led by its velocity at t times the
# fall time of a bomb released at t (aim_at: PROPOSED, a constant-velocity projection, so the stick lands where the unit
# is expected to be; a unit that turns or stops after the release is missed by that much). The release is then the
# moment of the step with the smallest release error for THAT moving aim (best_release_moving / plan_drop_moving), the
# way best_release picks it for a fixed one. A followed unit that is out of the player side's sight at the release is
# still followed (PROPOSED: the sim has no fog rule).
#
# WHEN THE TARGET IS OUTSIDE THE CONE (Track T; Alex: "That means it might leave the cone and completely not fire" and
# then "Or just be a bad shot" -- he has not picked, so data/sim/bombs.json outside_cone_mode is a switch; the planning
# rule stands either way: a special cannot be activated on a step whose cone does not hold the target). It covers a
# followed unit that leaves the cone during the resolve and a step moved after its drop was set:
#     "hold"       the drop does not release: {"ok": false, "reason": "outside_cone"} and no bomb is spent (PROPOSED default)
#     "poor_shot"  the stick IS released and the bombs ARE spent, at the moment the target is closest to the cone, aimed at the
#                  cone's nearest point to the target (the old clamp, clamp_aim), with the rim's accuracy scaled down by how far
#                  outside the cone the target is, never below poor_shot_floor (release_rule, poor_shot_accuracy)
# "Outside" is a release error r above 1 plus inside_tolerance. plan_drop() itself still only ANALYSES: it reports the
# nearest aim inside the cone ("aim", "clamped") and "outside"; release_rule() applies the switch to that analysis.

# THE PHYSICS (proposed). A bomb released at height h (metres above the ground, the
# sim's 0 m: Terrain height is not in the sim; a bomber's h is its altitude band's
# height, or between two during a band change) carries the bomber's HORIZONTAL
# velocity (v, along its heading; the climb or dive of a band change is the sim's
# abstraction and is not carried) and falls under gravity g with no drag:
#
#     fall time  T = sqrt(2 h / g)        ground range  R = v T       landing = release point + R along the heading
#
# so a bomb lands AHEAD of the release point. At 85 m/s: R = 421 m from low (120 m,
# T 4.9 s), 768 m from medium (400 m, T 9.0 s), 1,214 m from high (1,000 m, T 14.3 s).
# A bomb's fall can outlast the turn: it is carried across turns (World.bombs_in_flight).
#
# THE RELEASE ANGLE. Seen from the bomber, the point where the bomb will land lies at
# a fixed angle below the horizon, the IDEAL RELEASE ANGLE:
#
#     alpha_ideal = atan(h / R)           (15.9 degrees low, 27.5 medium, 39.5 high at 85 m/s)
#
# An aim point on the ground at distance d, bearing b is seen at depression
# atan(h / d), azimuth (b - heading). Its RELEASE ERROR is the pair
#
#     across = azimuth,    height = atan(h / d) - alpha_ideal
#
# and the CONE is the ellipse of release errors r = sqrt((across / half_across)^2 +
# (height / half_height)^2) <= 1 (the same ellipse in two angles the weapon cones use,
# combat.gd), additionally no farther than cone_max_range_factor x R. An aim point is
# in the cone of a RELEASE MOMENT; the step offers a window of them (the bomber moves
# 140 m in a step): the cone of the STEP is the union of the cones of its moments, and
# the moment the stick is released at is the one with the smallest r for the aim point
# ("the drop releases at the step's moment if the geometry allows", found at
# release_samples parts of the step and refined between the best part's neighbours).
#
# ACCURACY AND SPREAD. The accuracy factor is the weapons' CENTRE FACTOR
# (combat.gd centre_factor) of that r: 1 at the ideal release angle, rim_accuracy_factor
# at the rim. Each bomb lands scattered about its place in the stick (the aim point
# is the stick's centre) by a Gaussian per ground axis of
#
#     sigma = (spread_base_m + spread_per_height x h) / accuracy
#
# metres: HEIGHT is a factor (more height, more spread; Alex) and the release angle
# is the other (further from the ideal, more spread; Alex). A fraction of sigma
# (stick_error_fraction) is the STICK's, shared by every bomb of the drop; the rest
# is each bomb's own. An aim point outside the cone is ANALYSED at the nearest point
# inside it (along the line from the ideal point, clamp_aim) -- what the interface shows;
# whether the World then releases at all is outside_cone_mode (see THE TARGET above).
#
# THE STICK. A drop of n bombs releases them release_interval_s apart, centred on the
# release moment: bomb i leaves at t_i = t_release + (i - (n-1)/2) x interval, lands
# T later and (before scatter) (i - (n-1)/2) x v x interval along the bomber's heading
# from the aim point. The dice are Mulberry32 streams seeded from (the World's
# rng_seed, the release turn, the bomber's index in World.units, the drop's index in
# its load, the bomb's index) through combat.gd's mix32, so the same game rolls the
# same stick and one stick does not depend on the others; only the host's World rolls.
#
# THE BLAST. A bomb landing at (x, y) damages every unit up at that moment whose
# height above the ground is at most blast_height_m (units on the surface; not planes
# in the air), by blast_pips_by_distance of the unit's centre from the impact (pips
# within 12 m, 25 m, 45 m: data/sim/bombs.json). It makes no difference whose side
# the unit is on (blast_hits_own_side). A unit at 0 health goes down with the fate
# "destroyed" if it is not an aircraft (combat.gd).
#
# EVENTS (added to resolve()'s `events`, merged in time order with the rest; every one
# also has "turn", the World's turn, and positions are metres, t seconds into the turn,
# height_m metres above the ground):
#
#   {"type": "bomb_release", "turn", "unit" (the bomber), "t", "x", "y", "height_m" (the
#    bomber at the release), "heading", "speed", "aim": [x, y] (the stick's centre,
#    after any clamp), "bombs": n, "drop_index" (0 for the unit's first drop, ...),
#    "step", "accuracy", "spread_m" (sigma), "fall_s", "impact_t" (seconds after the
#    start of THIS turn at which the stick's centre lands; above turn_seconds means a
#    later turn)}
#   {"type": "bomb_impact", "turn" (the turn it LANDS in), "unit" (the bomber), "bomb"
#    (index in the stick), "drop_index", "stick" (the bomb's stick id), "t", "x", "y",
#    "blast_m" (the blast radius), "released_turn", "released_t"}
#   {"type": "hit", "turn", "unit" (the target), "by" (the bomber), "weapon": "bomb", "t",
#    "damage", "health"}                    after the bomb_impact that did it
#   {"type": "down", ..., "by" (the bomber), "fate": "destroyed"}   for a ground unit
#
# A bomb's record while it falls (World.bombs_in_flight, and the "bombs" of resolve()'s
# result, which apply_resolution hands to a client): a plain Dictionary,
#
#   {"id" ("<unit>/<turn>/<drop_index>/<bomb>"), "unit", "drop_index", "bomb",
#    "release_turn", "release_t" (this bomb's release, seconds into release_turn),
#    "x0", "y0", "h0" (where and how high it left), "x", "y" (where it will land,
#    scatter included), "fall_s", "impact_turn", "impact_t"}
#
# and bomb_position() says where it is at a moment, for the effects.

const Combat = preload("res://scripts/sim/combat.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const MASK32 := 0xFFFFFFFF
const BOMB_TAG := 0x424F4D42   # "BOMB"

# --- Physics ---------------------------------------------------------------------

static func fall_time(height_m: float, gravity: float) -> float:
	return sqrt(2.0 * maxf(height_m, 0.0) / gravity)

# The ground range a bomb released at `speed` and `height_m` flies before it lands.
static func ideal_range(speed: float, height_m: float, gravity: float) -> float:
	return maxf(speed, 0.0) * fall_time(height_m, gravity)

# The ideal release angle, radians below the horizon.
static func ideal_depression(speed: float, height_m: float, gravity: float) -> float:
	return atan2(maxf(height_m, 0.0), ideal_range(speed, height_m, gravity))

# --- The bomber through a step -----------------------------------------------------

# `n + 1` samples of the bomber through a step, equally spaced from t0 to t1 (seconds into
# the turn): [{t, x, y, heading, speed, height_m}], on the arc the envelope flies
# (Envelope.point_on_step), the height going linearly from h0 to h1. `prev` is the state at
# the step's start, `cur` the state after it (with its `turn`).
static func make_samples(prev: Dictionary, cur: Dictionary, t0: float, t1: float, h0: float, h1: float, n: int) -> Array:
	var out: Array = []
	var dt := t1 - t0
	for i in n + 1:
		var f := float(i) / float(n)
		var p := Envelope.point_on_step(prev, cur, dt, f)
		out.append({
			"t": t0 + dt * f, "x": p["x"], "y": p["y"], "heading": p["heading"], "speed": p["speed"],
			"height_m": h0 + (h1 - h0) * f,
		})
	return out

# The bomber between two samples (linear in position, speed, height and, along the shorter way
# round, heading): t outside the samples' span is held at its ends.
static func sample_at(samples: Array, t: float) -> Dictionary:
	var last := samples.size() - 1
	var t0 := float(samples[0]["t"])
	var t1 := float(samples[last]["t"])
	if t <= t0:
		return (samples[0] as Dictionary).duplicate()
	if t >= t1:
		return (samples[last] as Dictionary).duplicate()
	var f := (t - t0) / (t1 - t0) * float(last)
	var i := mini(int(floorf(f)), last - 1)
	var a: Dictionary = samples[i]
	var b: Dictionary = samples[i + 1]
	var u := f - float(i)
	var dh := Combat.wrap_angle(float(b["heading"]) - float(a["heading"]))
	return {
		"t": t,
		"x": lerpf(float(a["x"]), float(b["x"]), u), "y": lerpf(float(a["y"]), float(b["y"]), u),
		"heading": float(a["heading"]) + dh * u,
		"speed": lerpf(float(a["speed"]), float(b["speed"]), u),
		"height_m": lerpf(float(a["height_m"]), float(b["height_m"]), u),
	}

# --- The cone ----------------------------------------------------------------------

# Where a bomb released from sample `s` lands (before scatter).
static func impact_point(s: Dictionary, rules: BombRules) -> Vector2:
	var rng := ideal_range(float(s["speed"]), float(s["height_m"]), rules.gravity)
	var h := float(s["heading"])
	return Vector2(float(s["x"]) + cos(h) * rng, float(s["y"]) + sin(h) * rng)

# The release error of aiming at (ax, ay) from the bomber as it is in sample `s`:
# {r (1 or less is inside the cone), across, height (radians; signed: height is
# positive when the aim point is closer than the ideal), depression (radians), ideal
# (radians), distance (ground metres), range (the ideal ground range), accuracy}.
static func evaluate(s: Dictionary, ax: float, ay: float, rules: BombRules) -> Dictionary:
	var dx := ax - float(s["x"])
	var dy := ay - float(s["y"])
	var d := sqrt(dx * dx + dy * dy)
	var h := maxf(float(s["height_m"]), 0.0)
	var rng := ideal_range(float(s["speed"]), h, rules.gravity)
	var ideal := atan2(h, rng)
	var depression := atan2(h, d)
	var across := Combat.wrap_angle(atan2(dy, dx) - float(s["heading"])) if d > 1e-9 else 0.0
	var height := depression - ideal
	var a := across / rules.cone_half_across
	var b := height / rules.cone_half_height
	var r := sqrt(a * a + b * b)
	# No farther than cone_max_range_factor x the ideal range: the low band's cone would
	# otherwise run on towards the horizon.
	if rng > 0.0:
		var over := d / (rules.cone_max_range_factor * rng)
		if over > 1.0:
			r = maxf(r, over)
	return {
		"r": r, "across": across, "height": height, "depression": depression, "ideal": ideal,
		"distance": d, "range": rng, "accuracy": accuracy(r, rules),
	}

# The accuracy factor of a release error r: the weapons' centre factor.
static func accuracy(r: float, rules: BombRules) -> float:
	return Combat.centre_factor(rules.accuracy_weapon, r)

# The scatter of one bomb (one standard deviation per ground axis), metres.
static func spread_m(height_m: float, accuracy_factor: float, rules: BombRules) -> float:
	return (rules.spread_base_m + rules.spread_per_height * maxf(height_m, 0.0)) / maxf(accuracy_factor, 1e-6)

# The release moment in the step with the smallest release error for (ax, ay):
# {t, r, ev (evaluate()'s result), sample, aim}. The step is `samples` (make_samples).
static func best_release(samples: Array, ax: float, ay: float, rules: BombRules) -> Dictionary:
	var fixed := Vector2(ax, ay)
	return best_release_moving(samples, func(_t: float) -> Vector2: return fixed, rules)

# The same for an aim that moves: `aim_at` is a Callable (t seconds into the turn) -> Vector2, where the stick's
# centre would be if it were released at t (Alex: "pick the release point for bombs ... dynamically"). The release
# moment is the one with the smallest release error between each moment's bomber and that moment's aim.
static func best_release_moving(samples: Array, aim_at: Callable, rules: BombRules) -> Dictionary:
	var n := samples.size() - 1
	var best_i := 0
	var best_r := INF
	for i in n + 1:
		var a: Vector2 = aim_at.call(float((samples[i] as Dictionary)["t"]))
		var ev := evaluate(samples[i], a.x, a.y, rules)
		if float(ev["r"]) < best_r - 1e-12:
			best_r = float(ev["r"])
			best_i = i
	var t0 := float(samples[0]["t"])
	var t1 := float(samples[n]["t"])
	var lo := float((samples[maxi(best_i - 1, 0)] as Dictionary)["t"])
	var hi := float((samples[mini(best_i + 1, n)] as Dictionary)["t"])
	# Refine between the best part's neighbours (the release error is smooth and has one
	# minimum there): a ternary search.
	for _k in 14:
		var m1 := lo + (hi - lo) / 3.0
		var m2 := hi - (hi - lo) / 3.0
		var a1: Vector2 = aim_at.call(m1)
		var a2: Vector2 = aim_at.call(m2)
		if float(evaluate(sample_at(samples, m1), a1.x, a1.y, rules)["r"]) <= float(evaluate(sample_at(samples, m2), a2.x, a2.y, rules)["r"]):
			hi = m2
		else:
			lo = m1
	var tm := clampf(0.5 * (lo + hi), t0, t1)
	var sm := sample_at(samples, tm)
	var am: Vector2 = aim_at.call(tm)
	var evm := evaluate(sm, am.x, am.y, rules)
	var t_best := tm
	var s_best := sm
	var ev_best := evm
	var aim_best := am
	if float(evm["r"]) > best_r:
		t_best = float((samples[best_i] as Dictionary)["t"])
		s_best = (samples[best_i] as Dictionary).duplicate()
		aim_best = aim_at.call(t_best)
		ev_best = evaluate(s_best, aim_best.x, aim_best.y, rules)
	return {"t": t_best, "r": float(ev_best["r"]), "ev": ev_best, "sample": s_best, "aim": aim_best}

# The IDEAL aim point of a step: where a bomb released at the middle of the step lands,
# release error 0 there. (Every point of impact_curve() is ideal for some moment.)
static func ideal_point(samples: Array, rules: BombRules) -> Vector2:
	return impact_point(sample_at(samples, 0.5 * (float((samples[0] as Dictionary)["t"]) + float((samples[samples.size() - 1] as Dictionary)["t"]))), rules)

# The ideal points of the whole step, release moment by moment: the line the bombs would
# land on if the aim followed it.
static func impact_curve(samples: Array, rules: BombRules) -> PackedVector2Array:
	var out := PackedVector2Array()
	for s: Dictionary in samples:
		out.append(impact_point(s, rules))
	return out

# The ground footprint of the cone of one release moment: the points whose release error
# is exactly 1, `count` of them round the ellipse, as a closed polygon. (The part of the
# cone below ideal - half_height < 0 is cut at the farthest range.)
static func footprint(s: Dictionary, rules: BombRules, count: int = 24) -> PackedVector2Array:
	var out := PackedVector2Array()
	var h := maxf(float(s["height_m"]), 0.0)
	var rng := ideal_range(float(s["speed"]), h, rules.gravity)
	var ideal := atan2(h, rng)
	var far := rules.cone_max_range_factor * rng
	for i in count:
		var phi := TAU * float(i) / float(count)
		var across := rules.cone_half_across * cos(phi)
		var dep := ideal + rules.cone_half_height * sin(phi)
		var d := far
		if dep > 1e-6:
			d = minf(h / tan(dep), far)
		var az := float(s["heading"]) + across
		out.append(Vector2(float(s["x"]) + cos(az) * d, float(s["y"]) + sin(az) * d))
	return out

# The region where bombs released in the step can land: the union of the footprints of the
# release moments. A closed polygon, metres (float32: drawing data).
static func cone_polygon(samples: Array, rules: BombRules) -> PackedVector2Array:
	var acc := PackedVector2Array()
	var all_points := PackedVector2Array()
	for s: Dictionary in samples:
		var fp := footprint(s, rules)
		all_points.append_array(fp)
		if acc.is_empty():
			acc = fp
			continue
		var merged := Geometry2D.merge_polygons(acc, fp)
		var best := PackedVector2Array()
		var best_area := -1.0
		for poly: PackedVector2Array in merged:
			var area := absf(_area(poly))
			if area > best_area:
				best_area = area
				best = poly
		if not best.is_empty():
			acc = best
	if acc.size() < 3:
		return Geometry2D.convex_hull(all_points)
	return acc

static func _area(poly: PackedVector2Array) -> float:
	var a := 0.0
	var n := poly.size()
	for i in n:
		var p := poly[i]
		var q := poly[(i + 1) % n]
		a += p.x * q.y - q.x * p.y
	return 0.5 * a

# Move (ax, ay) into the cone of the step if it is outside, along the line from the step's
# ideal point: {x, y, clamped, r}.
static func clamp_aim(samples: Array, ax: float, ay: float, rules: BombRules) -> Dictionary:
	var first := best_release(samples, ax, ay, rules)
	if float(first["r"]) <= 1.0 + rules.inside_tolerance:
		return {"x": ax, "y": ay, "clamped": false, "r": float(first["r"])}
	var c0 := ideal_point(samples, rules)
	var lo := 0.0
	var hi := 1.0
	for _k in 16:
		var mid := 0.5 * (lo + hi)
		var px := c0.x + (ax - c0.x) * mid
		var py := c0.y + (ay - c0.y) * mid
		if float(best_release(samples, px, py, rules)["r"]) <= 1.0:
			lo = mid
		else:
			hi = mid
	var x := c0.x + (ax - c0.x) * lo
	var y := c0.y + (ay - c0.y) * lo
	return {"x": x, "y": y, "clamped": true, "r": float(best_release(samples, x, y, rules)["r"]), "requested_r": float(first["r"])}

# The whole analysis of a drop in a step, for an aim point: what plan_step reports and what the
# resolver releases from. `samples` as make_samples. Plain values only (arrays, numbers, bools):
#
#   {"ok": true, "requested": [x, y], "aim": [x, y] (clamped), "clamped": bool, "outside": bool (the requested
#    aim is outside the cone: release_rule() decides what the World does with such a drop), "requested_r" (its
#    release error), "release_t" (seconds into the turn), "release": {x, y, heading, speed, height_m},
#    "r", "accuracy", "spread_m", "across_deg", "depression_deg", "ideal_deg", "error_deg"
#    (depression - ideal), "fall_s", "range_m", "impact_t" (release_t + fall_s, may pass the turn)}
static func plan_drop(samples: Array, ax: float, ay: float, rules: BombRules) -> Dictionary:
	var c := clamp_aim(samples, ax, ay, rules)
	var best := best_release(samples, float(c["x"]), float(c["y"]), rules)
	return _drop_record(best, [ax, ay], [float(c["x"]), float(c["y"])], bool(c["clamped"]), float(c.get("requested_r", c["r"])), rules)

# plan_drop for an aim that moves (a followed unit): the release at the moment best_release_moving finds. Inside the
# cone at that moment the record is released from there with the aim at that moment; outside it is plan_drop's for the
# aim at the moment the target is closest to the cone (the nearest aim inside the cone, "outside" true).
static func plan_drop_moving(samples: Array, aim_at: Callable, rules: BombRules) -> Dictionary:
	var best := best_release_moving(samples, aim_at, rules)
	var aim: Vector2 = best["aim"]
	if float(best["r"]) <= 1.0 + rules.inside_tolerance:
		return _drop_record(best, [aim.x, aim.y], [aim.x, aim.y], false, float(best["r"]), rules)
	return plan_drop(samples, aim.x, aim.y, rules)

static func _drop_record(best: Dictionary, requested: Array, aim: Array, clamped: bool, requested_r: float, rules: BombRules) -> Dictionary:
	var ev: Dictionary = best["ev"]
	var s: Dictionary = best["sample"]
	var acc := float(ev["accuracy"])
	var fall := fall_time(float(s["height_m"]), rules.gravity)
	return {
		"ok": true,
		"requested": requested,
		"aim": aim,
		"clamped": clamped,
		"outside": clamped,
		"requested_r": requested_r,
		"release_t": float(best["t"]),
		"release": {"x": float(s["x"]), "y": float(s["y"]), "heading": float(s["heading"]), "speed": float(s["speed"]), "height_m": float(s["height_m"])},
		"r": float(ev["r"]),
		"accuracy": acc,
		"spread_m": spread_m(float(s["height_m"]), acc, rules),
		"across_deg": rad_to_deg(float(ev["across"])),
		"depression_deg": rad_to_deg(float(ev["depression"])),
		"ideal_deg": rad_to_deg(float(ev["ideal"])),
		"error_deg": rad_to_deg(float(ev["height"])),
		"fall_s": fall,
		"range_m": float(ev["range"]),
		"impact_t": float(best["t"]) + fall,
	}

# The accuracy of a poor shot (outside_cone_mode "poor_shot"): the rim's accuracy scaled down by how far outside the
# cone the target is (`requested_r`, 1 is the rim), never below poor_shot_floor.
static func poor_shot_accuracy(requested_r: float, rules: BombRules) -> float:
	return maxf(rules.poor_shot_floor, rules.rim_accuracy_factor / maxf(requested_r, 1.0))

# What the World does with an analysis (plan_drop / plan_drop_moving): a drop inside its cone stands as it is; one
# OUTSIDE it follows data/sim/bombs.json outside_cone_mode -- "hold": {"ok": false, "reason": "outside_cone", ...} and
# nothing is released or spent; "poor_shot": the stick is released from the analysis's moment at its clamped aim, with
# the poor shot's accuracy and the scatter that goes with it, "poor_shot": true.
static func release_rule(d: Dictionary, rules: BombRules) -> Dictionary:
	if d.get("ok", false) != true or not bool(d.get("outside", false)):
		return d
	if rules.outside_cone_mode == "poor_shot":
		var out := d.duplicate(true)
		var acc := minf(float(d["accuracy"]), poor_shot_accuracy(float(d["requested_r"]), rules))
		out["accuracy"] = acc
		out["spread_m"] = spread_m(float((d["release"] as Dictionary)["height_m"]), acc, rules)
		out["poor_shot"] = true
		return out
	return {"ok": false, "reason": "outside_cone", "requested": d["requested"], "requested_r": d["requested_r"], "nearest": d["aim"]}

# The aim of a FOLLOWED unit for a release at `t`: its position at t led by its velocity at t times the fall time of a
# bomb released at t from `bomber_height_m` (PROPOSED: a constant-velocity projection). `pose` is the unit's sample at t
# ({x, y, heading, speed}).
static func followed_aim(pose: Dictionary, bomber_height_m: float, rules: BombRules) -> Vector2:
	var lead := float(pose["speed"]) * fall_time(bomber_height_m, rules.gravity)
	var h := float(pose["heading"])
	return Vector2(float(pose["x"]) + cos(h) * lead, float(pose["y"]) + sin(h) * lead)

# --- The stick ----------------------------------------------------------------------

# The seed of one stick's dice: the game seed, the release turn, a constant tag, the bomber's
# index in World.units and the drop's index in its load, folded through combat.gd's mix32.
static func stick_seed(game_seed: int, turn: int, unit_index: int, drop_index: int) -> int:
	var s := (game_seed & MASK32) ^ ((game_seed >> 32) & MASK32)
	for part: int in [turn, BOMB_TAG, unit_index, drop_index]:
		s = Combat.mix32(s, part)
	return s

# A pair of independent standard normal draws from two uniform ones (Box-Muller).
static func gaussian_pair(rng: Mulberry32) -> Vector2:
	var u1 := rng.next()
	var u2 := rng.next()
	var rad := sqrt(-2.0 * log(1.0 - u1))
	return Vector2(rad * cos(TAU * u2), rad * sin(TAU * u2))

# The bombs of one drop: `drop` is plan_drop()'s result; `per_drop` bombs. Returns the bomb
# records (see the header) without impact_turn / impact_t, which the World fills in knowing the
# turn's length, but with "impact_total": seconds from the start of the release turn at which
# this bomb lands.
static func make_stick(drop: Dictionary, per_drop: int, rules: BombRules, game_seed: int, turn: int, unit_id: String, unit_index: int, drop_index: int) -> Array:
	var rel: Dictionary = drop["release"]
	var aim: Array = drop["aim"]
	var heading := float(rel["heading"])
	var ux := cos(heading)
	var uy := sin(heading)
	var sigma := float(drop["spread_m"])
	var common_sigma := sigma * rules.stick_error_fraction
	var own_sigma := sigma * sqrt(maxf(1.0 - rules.stick_error_fraction * rules.stick_error_fraction, 0.0))
	var seed_value := stick_seed(game_seed, turn, unit_index, drop_index)
	var common := gaussian_pair(Mulberry32.new(seed_value)) * common_sigma
	var spacing := float(rel["speed"]) * rules.release_interval_s
	var out: Array = []
	for i in per_drop:
		var k := float(i) - 0.5 * float(per_drop - 1)
		var own := gaussian_pair(Mulberry32.new(Combat.mix32(seed_value, i + 1))) * own_sigma
		var along := k * spacing
		var t_i := float(drop["release_t"]) + k * rules.release_interval_s
		out.append({
			"id": "%s/%d/%d/%d" % [unit_id, turn, drop_index, i],
			"unit": unit_id, "drop_index": drop_index, "bomb": i,
			"release_turn": turn, "release_t": t_i,
			"x0": float(rel["x"]) + ux * along, "y0": float(rel["y"]) + uy * along, "h0": float(rel["height_m"]),
			"x": float(aim[0]) + ux * along + common.x + own.x,
			"y": float(aim[1]) + uy * along + common.y + own.y,
			"fall_s": float(drop["fall_s"]),
			"impact_total": t_i + float(drop["fall_s"]),
		})
	return out

# Fill in the turn and moment a bomb lands in: `impact_turn` and `impact_t` from the total
# time since its release turn began.
static func schedule(bomb: Dictionary, turn_seconds: float) -> Dictionary:
	var total := float(bomb["impact_total"])
	var ahead := int(floorf(total / turn_seconds + 1e-9))
	bomb["impact_turn"] = int(bomb["release_turn"]) + ahead
	bomb["impact_t"] = maxf(total - float(ahead) * turn_seconds, 0.0)
	bomb.erase("impact_total")
	return bomb

# Where a falling bomb is at `t` seconds into `turn`: {x, y, height_m, state} with state
# "unreleased" (before its release), "falling" or "landed". Horizontally it flies a straight
# line from where it left to where it lands; its height falls as h0 (1 - (tau / T)^2).
static func bomb_position(bomb: Dictionary, turn: int, t: float, turn_seconds: float) -> Dictionary:
	var tau := float(turn - int(bomb["release_turn"])) * turn_seconds + t - float(bomb["release_t"])
	var fall := float(bomb["fall_s"])
	if tau <= 0.0:
		return {"x": float(bomb["x0"]), "y": float(bomb["y0"]), "height_m": float(bomb["h0"]), "state": "unreleased"}
	if tau >= fall:
		return {"x": float(bomb["x"]), "y": float(bomb["y"]), "height_m": 0.0, "state": "landed"}
	var f := tau / fall
	return {
		"x": lerpf(float(bomb["x0"]), float(bomb["x"]), f), "y": lerpf(float(bomb["y0"]), float(bomb["y"]), f),
		"height_m": float(bomb["h0"]) * (1.0 - f * f), "state": "falling",
	}
