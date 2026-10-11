extends RefCounted

# THE DRIVE ROLE (Track TK2, proposed 2026-10-11; the first mixed mission, "hold the bridge at the far end of ship range", which
# Alex said to build as it was proposed, as the first playtest of all the units). The AI's orders for a GROUND unit, a tank;
# ai_pilot.gd assigns and dispatches, this class holds what is the role's own. Numbers: data/sim/ai.json "drive".
#
#   {"role": "drive", "route": [[x, y], ...], "to": [x, y], "start_turn": 4}
#
#   route        waypoints in order, driven point to point (the author puts them on the road if the tank is to drive on it)
#   to           a target point REACHED BY ROAD: the road between where the tank starts (or its last waypoint) and the road point
#                nearest the target (World.ground_road_path: the world layout's road), then straight to the target. No road: straight
#   start_turn   the tank waits where it is, with no orders, until this turn (a wave out of sight; default 1: it drives at once). A waiting
#                tank brakes at once, so a scenario places it with "speed": 0 (a new unit starts at its type's cruise, which would roll it
#                a few metres in turn 1)
#   (at least one of route and to)
#
# THE COURSE is the polyline of all that, from where the tank stands (its waypoints are marks the look-ahead never reaches past, so the
# tank passes through them; the road's own bends are rounded). The tank follows it by PURE PURSUIT: each step it asks for the heading at the step's end
# that points at the point `lookahead_m` ahead (along the course) of its own foot on the course, at its top speed, and brakes to stop at
# the course's end (the speed it asks for falls with the distance left, so it does not overrun). It asks for what it wants and the
# envelope and the World's ground rule (data/sim/ground.json) decide what it gets: a plan the rule had to hold, because the way is a
# cliff or a river with no bridge, simply holds the tank there, turn after turn (a destroyed bridge stops it; it does not turn back).
#
# States (reported through ai_pilot.gd's transitions): `wait` before the start turn, `drive` along the course, `arrived` at its end.
# It fires on its own by the engagement rules (combat.gd): the role never aims or chooses a target, and has no other tactics.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")
const JsMath = preload("res://scripts/core/js_math.gd")

const S_WAIT := "wait"
const S_DRIVE := "drive"
const S_ARRIVED := "arrived"

const R_START := "start_turn"
const R_ARRIVED := "course_end"

var world: World
var steer: RefCounted
var params: AiParams
var enter: Callable                      # AiPilot._enter(id, memory, state, code, detail)
var courses: Dictionary = {}             # unit id -> {pts: PackedVector2Array, cum: PackedFloat64Array (arc length at each point), total}

func _init(w: World, st: RefCounted, p: AiParams, enter_fn: Callable) -> void:
	world = w
	steer = st
	params = p
	enter = enter_fn

# --- Orders --------------------------------------------------------------------------------------------

# Check the orders `spec` of unit `id` and keep its course; returns "" or what is wrong with them. `orders` is filled with the
# normalised orders (route, to, start_turn, course).
func take(id: String, spec: Dictionary, orders: Dictionary) -> String:
	var u: Unit = world.units[id]
	if u.def.domain != "ground":
		return "a %s does not drive (domain %s): the drive role is for ground units" % [u.type, u.def.domain]
	var route: Array = []
	if spec.has("route"):
		if not (spec["route"] is Array):
			return "'route' is a list of [x, y] points"
		for pt: Variant in (spec["route"] as Array):
			var q := _point(pt)
			if q.is_empty():
				return "route point %s is not [x, y] of finite numbers" % str(pt)
			route.append(q)
	var to: Array = []
	if spec.has("to"):
		to = _point(spec["to"])
		if to.is_empty():
			return "'to' is not [x, y] of finite numbers"
	if route.is_empty() and to.is_empty():
		return "a drive needs a 'route' or a 'to'"
	var start := 1
	if spec.has("start_turn"):
		var sv: Variant = spec["start_turn"]
		if not ((sv is int or sv is float) and float(sv) == floorf(float(sv)) and float(sv) >= 1.0):
			return "'start_turn' is a whole turn number, 1 or more, got %s" % str(sv)
		start = int(sv)
	var pts := PackedVector2Array()
	_push(pts, Vector2(u.x, u.y))   # (the course starts where the tank stands: the first leg is a straight line to the first waypoint)
	var mark_at: Array[int] = []      # the points of the course that are WAYPOINTS: the tank steers for them, not past them
	for q: Array in route:
		_push(pts, Vector2(float(q[0]), float(q[1])))
		mark_at.append(pts.size() - 1)
	if not to.is_empty():
		var goal := Vector2(float(to[0]), float(to[1]))
		var rd := world.ground_road_path(pts[pts.size() - 1], goal)
		for q: Vector2 in rd:
			_push(pts, q)
		_push(pts, goal)
	if pts.size() < 2:
		return "the course is a single point (the tank is already there)"
	var course := _course(pts)
	var marks := PackedFloat64Array()
	for k in mark_at:
		marks.append(float((course["cum"] as PackedFloat64Array)[k]))
	course["marks"] = marks
	courses[id] = course
	orders["route"] = route
	orders["to"] = to
	orders["start_turn"] = start
	return ""

static func _push(pts: PackedVector2Array, q: Vector2) -> void:
	if pts.is_empty() or pts[pts.size() - 1].distance_to(q) > 0.5:
		pts.append(q)

static func _course(pts: PackedVector2Array) -> Dictionary:
	var cum := PackedFloat64Array()
	var total := 0.0
	for k in pts.size():
		if k > 0:
			total += pts[k].distance_to(pts[k - 1])
		cum.append(total)
	return {"pts": pts, "cum": cum, "total": total}

static func _point(v: Variant) -> Array:
	if v is Vector2:
		return [(v as Vector2).x, (v as Vector2).y] if (v as Vector2).is_finite() else []
	if v is Array and (v as Array).size() >= 2 and (v[0] is float or v[0] is int) and (v[1] is float or v[1] is int) \
			and is_finite(float(v[0])) and is_finite(float(v[1])):
		return [float(v[0]), float(v[1])]
	return []

# --- Planning ------------------------------------------------------------------------------------------

# Plan the unit's turn. `m` is its memory (state, since ...; "s": the progress along the course, metres), changed in place.
func plan(id: String, a: Dictionary, m: Dictionary) -> void:
	var u: Unit = world.units[id]
	if not courses.has(id):
		# (orders without a course: an assignment from before the world had a road, say) hold
		steer.fly(id, _hold())
		return
	var c: Dictionary = courses[id]
	if world.turn < int(a["start_turn"]):
		if str(m["state"]) != S_WAIT:
			enter.call(id, m, S_WAIT, "waiting", "waits for turn %d" % int(a["start_turn"]))
		steer.fly(id, _hold())
		return
	var p := params
	var cap := p.num("drive", "capture_radius_m")
	var ahead := p.num("drive", "lookahead_m")
	var env := u.def.envelope
	var vmax := env.speed_max * p.num("drive", "speed_fraction_of_max")
	var s0 := float(m.get("s", 0.0))
	var total := float(c["total"])
	var dt := world.step_dt(id)
	var done_box: Array = [false]     # (a lambda changes what a box holds, not a local it captured)
	var ctrl := func(_i: int, at: Dictionary, _t: float) -> Dictionary:
		var pr := _project(c, Vector2(float(at["x"]), float(at["y"])), s0)
		var left: float = total - float(pr["s"])
		if left <= cap:
			done_box[0] = true
			return {"turn": 0.0, "speed": 0.0}
		var aim := func(s: Dictionary) -> float:
			var q := _project(c, Vector2(float(s["x"]), float(s["y"])), s0)
			var tp_s := minf(float(q["s"]) + ahead, total)
			for ms in (c["marks"] as PackedFloat64Array):   # a waypoint is steered for, not cut: the look-ahead stops at the next one
				if ms > float(q["s"]) + 0.5:
					tp_s = minf(tp_s, ms)
					break
			var tp := _point_at(c, tp_s)
			return JsMath.atan2(tp.y - float(s["y"]), tp.x - float(s["x"]))
		# the end speed that still lets it stop at the capture radius: after this step's travel (v0 + v1) / 2 x dt the distance left
		# must hold its braking distance v1^2 / (2 decel):  v1^2 + decel dt v1 + decel dt v0 - 2 decel (left - cap) <= 0
		var brake := env.decel * dt
		var disc := brake * brake - 4.0 * (brake * float(at["speed"]) - 2.0 * env.decel * (left - cap))
		var v_stop := 0.0 if disc <= 0.0 else 0.5 * (-brake + sqrt(disc))
		return {"aim": aim, "speed": minf(vmax, v_stop)}
	var states: Array = steer.fly(id, ctrl)
	var end := Vector2(u.x, u.y)
	if not states.is_empty():
		var last: Dictionary = states[states.size() - 1]
		end = Vector2(float(last["x"]), float(last["y"]))
	m["s"] = float(_project(c, end, s0)["s"])
	var state := str(m["state"])
	if bool(done_box[0]):
		if state != S_ARRIVED:
			enter.call(id, m, S_ARRIVED, R_ARRIVED, "within %.0f m of the end of its course" % cap)
	elif state != S_DRIVE:
		enter.call(id, m, S_DRIVE, R_START if state == S_WAIT else "off_course", "the wave starts" if state == S_WAIT else "pushed off the end of its course")

func _hold() -> Callable:
	return func(_i: int, _at: Dictionary, _t: float) -> Dictionary:
		return {"turn": 0.0, "speed": 0.0}

# --- The course ----------------------------------------------------------------------------------------

# The foot of `p` on the course: {s: arc length at the foot, d: its distance from p}. Looked for among the stretches near the last
# progress `s_hint`; the whole course when nothing there is within stray_m.
func _project(c: Dictionary, p: Vector2, s_hint: float) -> Dictionary:
	var pts: PackedVector2Array = c["pts"]
	var cum: PackedFloat64Array = c["cum"]
	var back := params.num("drive", "progress_back_m")
	var fwd := params.num("drive", "progress_ahead_m")
	var stray := params.num("drive", "stray_m")
	var best := {"s": 0.0, "d": INF}
	for pass_no in 2:
		for k in pts.size() - 1:
			if pass_no == 0 and (cum[k + 1] < s_hint - back or cum[k] > s_hint + fwd):
				continue
			var a := pts[k]
			var ab := pts[k + 1] - a
			var l2 := ab.length_squared()
			var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
			var d := p.distance_to(a + ab * t)
			if d < float(best["d"]):
				best = {"s": cum[k] + t * (cum[k + 1] - cum[k]), "d": d}
		if float(best["d"]) <= stray:
			break
	return best

# The point at arc length `s` along the course.
static func _point_at(c: Dictionary, s: float) -> Vector2:
	var pts: PackedVector2Array = c["pts"]
	var cum: PackedFloat64Array = c["cum"]
	if s <= 0.0:
		return pts[0]
	if s >= float(c["total"]):
		return pts[pts.size() - 1]
	var k := cum.bsearch(s) - 1       # the last point at or before s
	k = clampi(k, 0, pts.size() - 2)
	var seg := cum[k + 1] - cum[k]
	return pts[k] if seg <= 0.0 else pts[k].lerp(pts[k + 1], (s - cum[k]) / seg)
