extends RefCounted

# WHAT A DOWN UNIT IS DOING IN THE TURN BEING PLAYED (Track U2, part 2). One place that
# reads a Unit's end-of-resolve state and its history and says, in seconds into that
# turn, when the unit is on the map as a plane, when it is falling out of control, when it
# struck the ground. The marker layer (does the plane draw, how high is it), the wingtip
# trails (where does the ribbon stop) and the effects feed (what to call and when) all
# ask here, so they cannot disagree.
#
# WHAT THE SIM LEAVES (scripts/sim/combat.gd, WHAT A KILL DOES). After a resolve every unit
# holds its END state: fate "" (up), "exploded", "out_of_control" or "crashed", down_at
# (seconds into the turn the unit went down THIS turn, NAN if it was already down or is up),
# and a history whose states carry fall_height_m while the unit falls. So:
#   exploded        gone at down_at (this turn) -- or gone since an earlier turn (down_at NAN)
#   out_of_control  flies on, falling from down_at (this turn) or from the turn's start
#   crashed         flew the fall until the history's height reaches 0 (this turn: a time
#                   after 0) -- or crashed in an earlier turn (the first state is already at
#                   0 m, so the time reads 0)
#   destroyed       (Track U3, the strike) a STATIC ground unit at 0 health -- the radio tower, a
#                   battery -- Unit.FATE_DESTROYED: it does not fall or fly, it stays, down. Its marker
#                   goes at down_at, as an exploded plane's does, and the effects layer's ruin takes
#                   its place (Track X); after the turn it is not drawn as a unit at all
#
# These are pure statics over a Unit (or anything with the same fields), no nodes.

const Unit = preload("res://scripts/sim/unit.gd")

# The unit's fate as the end of the last resolve left it ("" for a unit that is up).
static func fate(u: Object) -> String:
	if u == null:
		return ""
	var f: Variant = u.get("fate")
	return str(f) if f != null else ""

# True when the unit went down in the last resolved turn (not in an earlier one).
static func went_down_this_turn(u: Object) -> bool:
	return u != null and bool(u.get("down")) and is_finite(float(u.get("down_at")))

# Seconds into the last resolved turn at which a falling unit reached the ground: the first
# time the history's fall height reaches 0, exact between states (the height is linear
# there, as World._crash_time finds it). 0.0 when the unit was already on the ground when the
# turn began (it crashed in an earlier turn); NAN when it never gets there.
static func crash_t(u: Object) -> float:
	if u == null:
		return NAN
	var path: Array = u.get("history")
	for i in range(1, path.size()):
		var a: Dictionary = path[i - 1]
		var b: Dictionary = path[i]
		if not a.has("fall_height_m") or not b.has("fall_height_m"):
			continue
		var ha := float(a["fall_height_m"])
		var hb := float(b["fall_height_m"])
		if ha <= 0.0:
			return float(a["t"])
		if hb <= 0.0:
			return float(a["t"]) + (float(b["t"]) - float(a["t"])) * ha / (ha - hb)
	return NAN

# Until which second of the last resolved turn the unit is on the map as a plane: INF for a
# unit that is up or still falling at the turn's end, down_at for one that exploded in this
# turn, the crash time for one that struck the ground, and 0 for one that was gone before.
static func alive_until(u: Object) -> float:
	match fate(u):
		Unit.FATE_EXPLODED, Unit.FATE_DESTROYED:
			return float(u.get("down_at")) if went_down_this_turn(u) else 0.0
		Unit.FATE_CRASHED:
			var c := crash_t(u)
			return c if is_finite(c) else 0.0
	return INF

# From which second of the last resolved turn the unit falls out of control: down_at when it
# went down in this turn, 0 when it was already falling (or had already struck the ground);
# INF for a unit that does not fall at all (up, or exploded).
static func falls_from(u: Object) -> float:
	var f := fate(u)
	if f != Unit.FATE_OUT_OF_CONTROL and f != Unit.FATE_CRASHED:
		return INF
	return float(u.get("down_at")) if went_down_this_turn(u) else 0.0

# Whether the unit is drawn as a plane at `t` seconds into the turn. `playing` false: the
# state after the turn (an exploded or crashed unit is not a plane any more).
static func on_map(u: Object, t: float, playing: bool) -> bool:
	if not playing:
		var f := fate(u)
		return f != Unit.FATE_EXPLODED and f != Unit.FATE_CRASHED and f != Unit.FATE_DESTROYED
	return t < alive_until(u)

# Whether the unit is falling out of control at `t` (or, not playing, right now).
static func falling_at(u: Object, t: float, playing: bool) -> bool:
	if not on_map(u, t, playing):
		return false
	if not playing:
		return fate(u) == Unit.FATE_OUT_OF_CONTROL
	return t >= falls_from(u)
