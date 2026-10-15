extends RefCounted

# THE TURRET (builder ORD, 2026-10-14; Alex, decision tank-fire-feedback: "It should delay the shot in the game so the timing is variable during the
# turn", "The turret feedback should also apply to the ship"). Pure functions, headless, no nodes: the model of a turret that has to turn to its target
# before an ordered shot can go. The numbers are the unit's own (data/units/<id>.json "turret": traverse_dps, half_arc_deg, barrel_tip_m, all PROPOSED);
# the bearing is Unit.turret; the combat resolver walks it (combat_resolver.gd) and the World stores its track in the history (world.gd).
#
# THE BEARING is an angle in radians RELATIVE TO THE HULL'S NOSE, positive clockwise on screen (the sim's angles: x east, y south), 0 straight ahead. A hull
# that turns carries its turret round with it (the bearing relative to the nose does not change by itself). The absolute bearing is heading + rel.
#
# THE ARC. half_arc_deg 180 is ALL ROUND (the cruiser's main guns): the turret takes the SHORT way to a bearing. Less is a fixed arc either side of the nose (the
# tank's 170 degrees is 85): the turret turns the DIRECT way inside it, a target outside it cannot be brought to bear (goal() clamps to the edge: the turret
# turns as far as it can while the hull comes round), and the card says "outside the arc".
#
# THE ORDER (combat_resolver.gd): from the start of the step an order is set on, the turret turns toward the target at traverse_dps; the shot is fired the
# moment it is on bearing (and not before the special's fire_at), so a far swing delays the shot and the timing varies with the turret's bearing and the
# target's, within the turn. A turret that cannot be on bearing by the end of the turn fires nothing (a gun_hold "off_bearing"), keeps the bearing it reached
# and goes on from there next turn.

const Envelope = preload("res://scripts/sim/envelope.gd")
const JsMath = preload("res://scripts/core/js_math.gd")

# Radians of slack when asking whether the bearing is the goal (a step that lands exactly on the goal is on bearing).
const EPS := 1e-9

# Is the turret all round (no arc limit)?
static func all_round(half_arc: float) -> bool:
	return half_arc >= PI - 1e-9

# The bearing relative to the hull's nose of the line from `from` to `to`, for a hull heading `heading`: (-PI, PI].
static func rel_to(from: Vector2, heading: float, to: Vector2) -> float:
	var d := to - from
	if d.length_squared() < 1e-12:
		return 0.0
	return Envelope.wrap_angle(JsMath.atan2(d.y, d.x) - heading)

# The bearing the turret can actually take toward a desired one: the desired bearing itself, or the edge of the arc when it is outside.
static func goal(desired_rel: float, half_arc: float) -> float:
	if all_round(half_arc):
		return desired_rel
	return clampf(desired_rel, -half_arc, half_arc)

# Is the desired bearing inside the arc?
static func in_arc(desired_rel: float, half_arc: float) -> bool:
	return all_round(half_arc) or absf(desired_rel) <= half_arc + 1e-9

# The signed turn from `rel` to `goal_rel`: the short way round for an all-round turret, the direct way inside a fixed arc.
static func turn_needed(rel: float, goal_rel: float, half_arc: float) -> float:
	if all_round(half_arc):
		return Envelope.wrap_angle(goal_rel - rel)
	return goal_rel - clampf(rel, -half_arc, half_arc)

# Seconds the turret needs to come from `rel` to `goal_rel` at `rate` (radians a second).
static func traverse_s(rel: float, goal_rel: float, half_arc: float, rate: float) -> float:
	return absf(turn_needed(rel, goal_rel, half_arc)) / maxf(rate, 1e-9)

# One move of at most `max_turn` radians from `rel` toward `goal_rel`: {rel (the new bearing), reached (it is on the goal), used (radians turned)}.
static func step_toward(rel: float, goal_rel: float, half_arc: float, max_turn: float) -> Dictionary:
	var need := turn_needed(rel, goal_rel, half_arc)
	var start := rel if all_round(half_arc) else clampf(rel, -half_arc, half_arc)
	if absf(need) <= max_turn + EPS:
		return {"rel": Envelope.wrap_angle(goal_rel) if all_round(half_arc) else goal_rel, "reached": true, "used": absf(need)}
	var moved := start + signf(need) * max_turn
	return {"rel": Envelope.wrap_angle(moved) if all_round(half_arc) else moved, "reached": false, "used": max_turn}

# The absolute bearing (radians, the sim's axes) of a turret at `rel` on a hull heading `heading`.
static func absolute(heading: float, rel: float) -> float:
	return Envelope.wrap_angle(heading + rel)

# The muzzle: where the barrel's tip is, for a turret axis at `axis` (metres) and a bearing `abs_bearing` (absolute radians), `tip_m` out.
static func muzzle_at(axis: Vector2, abs_bearing: float, tip_m: float) -> Vector2:
	return axis + Vector2(JsMath.cos(abs_bearing), JsMath.sin(abs_bearing)) * tip_m

# The bearing at time `t` of a turret track: keyframes [[t, rel], ...] ascending in t, the bearing before the first being `start_rel`, between two a straight
# line (the shortest way when the turret is all round), after the last the last. An empty track holds `start_rel`.
static func rel_at(track: Array, start_rel: float, t: float, half_arc: float) -> float:
	if track.is_empty():
		return start_rel
	var first: Array = track[0]
	if t <= float(first[0]):
		return start_rel if float(first[0]) > t + 1e-12 else float(first[1])
	for i in range(1, track.size()):
		var a: Array = track[i - 1]
		var b: Array = track[i]
		if t <= float(b[0]):
			var span := float(b[0]) - float(a[0])
			if span <= 1e-12:
				return float(b[1])
			var f := (t - float(a[0])) / span
			var ra := float(a[1])
			var rb := float(b[1])
			if all_round(half_arc):
				return Envelope.wrap_angle(ra + Envelope.wrap_angle(rb - ra) * f)
			return ra + (rb - ra) * f
	var last: Array = track[track.size() - 1]
	return float(last[1])
