extends RefCounted

# How the AI turns an intention into a plan (Track E, proposed): the planning
# loop and the edge-of-map safety, over the World's PUBLIC API only (clear_plan,
# plan_step, step_dt, steps_per_turn, reachable, bounds_center), exactly what a
# player's interface uses. Nothing here reads another unit.
#
# A CONTROLLER is a Callable the loop asks once per step:
#   ctrl.call(i, at, t_end) -> Dictionary
#     i      the step index;  at  the state the unit is in at the START of the
#            step (x, y, heading, speed, altitude_band);  t_end  seconds into the
#            turn at which this step ends
#   result keys (all optional):
#     "aim"    Callable(state) -> float: the heading (rad) the unit should have at
#              the END of the step, as a function of where the step ends. The loop
#              asks for the turn that gets there from the start, then corrects it
#              against the end state a couple of times -- so an aim at a point
#              (a target's predicted position) is met from where the step really
#              ends, not from where it began.
#     "turn"   a heading change to ask for, when there is no aim (0 = straight)
#     "speed"  m/s to ask for (default: hold the current speed)
#     "band"   altitude band to ask for ("" or absent: stay)
# The envelope clamps every request, so a controller asks for what it wants and
# the plan is what the plane can do.

const World = preload("res://scripts/sim/world.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const JsMath = preload("res://scripts/core/js_math.gd")

# How many times the loop corrects an aimed turn against the step's end state.
const REFINE_PASSES := 2

var world: World
var edge_margin_turn_radii: float

func _init(target: World, margin_radii: float) -> void:
	world = target
	edge_margin_turn_radii = margin_radii

# Plan every step of the unit's turn from `ctrl`; returns the clamped state after
# each step (the same states World.planned_states would give).
func fly(id: String, ctrl: Callable) -> Array:
	var u: Variant = world.units[id]
	var n := world.steps_per_turn(id)
	var dt := world.step_dt(id)
	world.clear_plan(id)
	var at: Dictionary = u.state()
	var states: Array = []
	for i in n:
		var c: Dictionary = ctrl.call(i, at, dt * float(i + 1))
		var req := {"speed": float(c.get("speed", at["speed"]))}
		var band := str(c.get("band", ""))
		if band != "":
			req["altitude_band"] = band
		var res: Dictionary
		if c.has("aim"):
			var aim: Callable = c["aim"]
			req["turn"] = Envelope.wrap_angle(float(aim.call(at)) - float(at["heading"]))
			res = world.plan_step(id, i, req)
			for _pass_no in REFINE_PASSES:
				if res.is_empty():
					break
				var extra := Envelope.wrap_angle(float(aim.call(res)) - float(res["heading"]))
				if absf(extra) < 1e-4:
					break
				req["turn"] = float(res["turn"]) + extra
				res = world.plan_step(id, i, req)
		else:
			req["turn"] = float(c.get("turn", 0.0))
			res = world.plan_step(id, i, req)
		if res.is_empty():
			break
		states.append(res)
		at = res
	return states

# --- The edge of the map -------------------------------------------------------

# Margin from the nearest edge, in metres: edge_margin_turn_radii turn radii at
# the unit's current speed (ai_dumb's rule: the room a turn back needs).
func edge_margin(id: String) -> float:
	var radius: float = world.reachable(id, 0).get("turn_radius", INF)
	if not is_finite(radius):
		return 0.0
	return edge_margin_turn_radii * radius

# Distance to the nearest map edge; negative outside the map.
func edge_distance(x: float, y: float) -> float:
	var b := world.bounds
	return minf(minf(x - b.position.x, b.end.x - x), minf(y - b.position.y, b.end.y - y))

# Is this plan one that runs the unit at an edge? Unsafe when some state of it is
# inside the margin AND the turn ends closer to an edge than it began: a unit
# that starts inside the margin but is flying away from the edge is left alone
# (ai_dumb would turn it to the centre at once; a bomber spawned near the west
# edge heading east must be free to fly its route).
func edge_unsafe(id: String, states: Array) -> bool:
	if states.is_empty():
		return false
	var u: Variant = world.units[id]
	var margin := edge_margin(id)
	var d0 := edge_distance(u.x, u.y)
	var dmin := d0
	for s: Dictionary in states:
		dmin = minf(dmin, edge_distance(float(s["x"]), float(s["y"])))
	var last: Dictionary = states[states.size() - 1]
	var d_end := edge_distance(float(last["x"]), float(last["y"]))
	return dmin < margin and d_end < d0 - 1.0

# Turn toward the map centre as hard as the envelope allows, at cruise.
func fly_to_centre(id: String) -> Array:
	var u: Variant = world.units[id]
	var cruise: float = u.def.envelope.speed_cruise
	var c := world.bounds_center()
	var cx := float(c.x)
	var cy := float(c.y)
	var ctrl := func(_i: int, _at: Dictionary, _t: float) -> Dictionary:
		return {
			"aim": func(s: Dictionary) -> float: return JsMath.atan2(cy - float(s["y"]), cx - float(s["x"])),
			"speed": cruise,
		}
	return fly(id, ctrl)

# Fly `ctrl`'s plan, or, when that runs the unit at an edge, the centre-turn
# instead. Returns {"states": Array, "edge": bool}.
func fly_safe(id: String, ctrl: Callable) -> Dictionary:
	var states := fly(id, ctrl)
	if edge_unsafe(id, states):
		return {"states": fly_to_centre(id), "edge": true}
	return {"states": states, "edge": false}
