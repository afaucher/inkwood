extends RefCounted

# THE STRIKE SEED'S MAP FOR THE TANK TESTS AND SHOTS (Track TK2, 2026-10-11): the Strike's seed (20261009) with its water and its
# ground, a World that has both (World.set_water, GroundMap.attach) and a bridge unit where the road crosses the river, plus the
# few helpers the tests share (a road point, a unit placed on the road, a turn played, a legal-pose check that does NOT go through
# the rule it is checking). Helpers go here, which the gate does not run (CLAUDE.md).
#
#   var w := TankWorlds.world()                     # water + ground + the bridge "bridge_1" (side allies, so a tank of the
#                                                   # other side shoots at it, one of its own does not)
#   TankWorlds.road(94)                             # the road's 94th point (the bridge stands at about 94; the road runs from the
#                                                   # village, index 0, away to the north-west edge, index 233)
#   TankWorlds.tank(w, "t1", "allies", "player", TankWorlds.road(108), TankWorlds.toward(108, 94))
#   TankWorlds.turn(w)                              # every player readies up, the turn resolves, the next one begins

const World = preload("res://scripts/sim/world.gd")
const Envelope = preload("res://scripts/sim/envelope.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")

const SEED := 20261009
const BRIDGE_INDEX := 94      # the road point nearest the bridge (WaterGen.sites().bridge.road_index)

static func water() -> RefCounted:
	return WaterGen.shared(SEED)

static func ground() -> RefCounted:
	return GroundMap.shared(SEED, water())

static func road(i: int) -> Vector2:
	var r: PackedVector2Array = ground().road
	return r[clampi(i, 0, r.size() - 1)]

# The heading of the road from point `a` toward point `b` (indices): the way a tank on it faces to drive from a to b.
static func toward(a: int, b: int) -> float:
	return (road(b) - road(a)).angle()

static func bridge_site() -> Dictionary:
	return water().sites()["bridge"]

# A World with the Strike seed's water and ground, a "local" player and (by default) the bridge.
static func world(bridge_side: String = "allies", with_bridge: bool = true) -> World:
	var w := World.new()
	w.quiet = true
	w.set_water(Callable(water(), "depth_at"))
	ground().attach(w)
	w.add_player("local")
	if with_bridge:
		var b := bridge_site()
		w.add_unit({"id": "bridge_1", "type": "bridge", "side": bridge_side, "controller": "ai",
			"x": (b["pos"] as Vector2).x, "y": (b["pos"] as Vector2).y, "heading": b["heading"]})
	return w

static func tank(w: World, id: String, side: String, controller: String, at: Vector2, heading: float, speed: float = 0.0) -> String:
	return w.add_unit({"id": id, "type": "tank", "side": side, "controller": controller, "x": at.x, "y": at.y, "heading": heading, "speed": speed})

# Every player readies up, the turn resolves, the next one begins. (The AI, if it is attached, has planned and readied itself.)
static func turn(w: World) -> Dictionary:
	for p: String in w.players.duplicate():
		w.commit(p)
	var result := w.resolve()
	w.begin_turn()
	return result

# Metres from the point to the nearest road point (a vertex; the road's points are 10 m apart).
static func road_index_near(p: Vector2) -> int:
	var r: PackedVector2Array = ground().road
	var best := 0
	var best_d := INF
	for i in r.size():
		var d := r[i].distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = i
	return best

# --- An independent look at a pose --------------------------------------------------------------------------

# Is the hull of a tank at (x, y) heading h on legal ground, judged by the map's own queries and the bridge, NOT by GroundRules
# (so that the rule is not marked by itself)? "" when it is, else "water" or "cliff".
static func pose_problem(w: World, x: float, y: float, h: float, size_m: float = 6.0) -> String:
	var wg := water()
	var gm := ground()
	var half := 0.5 * size_m
	var pts := [Vector2(x, y), Vector2(x + cos(h) * half, y + sin(h) * half), Vector2(x - cos(h) * half, y - sin(h) * half)]
	var bridge: Object = w.units.get("bridge_1")
	for p: Vector2 in pts:
		if float(wg.depth_at(p.x, p.y)) > 0.0 and not _on_bridge(bridge, p):
			return "water"
	var on_road := road_dist_brute(Vector2(x, y)) <= 8.0 or _on_bridge(bridge, pts[0])
	if not on_road:
		var l0: int = gm.level_at(x, y)
		for p: Vector2 in pts:
			if int(gm.level_at(p.x, p.y)) != l0:
				return "cliff"
	return ""

# The distance to the road by looking at every segment (the rule's own query is bucketed).
static func road_dist_brute(p: Vector2) -> float:
	var r: PackedVector2Array = ground().road
	var best := INF
	for k in r.size() - 1:
		var q := Geometry2D.get_closest_point_to_segment(p, r[k], r[k + 1])
		best = minf(best, p.distance_to(q))
	return best

static func _on_bridge(bridge: Object, p: Vector2) -> bool:
	if bridge == null or bridge.down:
		return false
	var d: Vector2 = p - Vector2(bridge.x, bridge.y)
	var c := cos(bridge.heading)
	var s := sin(bridge.heading)
	return absf(d.x * c + d.y * s) <= 0.5 * float(bridge.def.size_m) and absf(-d.x * s + d.y * c) <= 8.0

# Every pose of the unit's last turn, every 0.25 s, judged by pose_problem; returns the first problem found as "<problem> at (x, y)",
# or "".
static func turn_problem(w: World, id: String) -> String:
	for k in 21:
		var s: Dictionary = w.sample(id, 0.25 * float(k), "history")
		if s.is_empty():
			continue
		var why := pose_problem(w, float(s["x"]), float(s["y"]), float(s["heading"]), float(w.units[id].def.size_m))
		if why != "":
			return "%s at (%.1f, %.1f) t=%.2f" % [why, float(s["x"]), float(s["y"]), 0.25 * float(k)]
	return ""

# The step limits of the unit's last turn, all of them.
static func limits_of(w: World, id: String) -> Array:
	var out: Array = []
	for st: Variant in w.units[id].history:
		for l: Variant in ((st as Dictionary).get("limits", []) as Array):
			if not out.has(l):
				out.append(l)
	return out

# The nearest the unit's last turn came to point `p`, metres.
static func nearest_to(w: World, id: String, p: Vector2) -> float:
	var best := INF
	for k in 21:
		var s: Dictionary = w.sample(id, 0.25 * float(k), "history")
		best = minf(best, Vector2(float(s["x"]), float(s["y"])).distance_to(p))
	return best

# --- The tank's gun is an ORDER now (builder ORD, 2026-10-14; data/sim/guns.json tank_gun) ---------------------------------------

# Order the tank's gun at `target` (a unit id) in step `step` of its plan, keeping what the step already says. The step's state ({} if refused).
static func order_fire(w: World, shooter: String, target: String, step: int = 0) -> Dictionary:
	var u: Object = w.units[shooter]
	var req: Dictionary = (u.plan[step] as Dictionary).duplicate(true) if step < u.plan.size() else {}
	req["fire"] = {"special": "tank_gun", "target": {"unit": target}}
	return w.plan_step(shooter, step, req)

# A stand-in for a player (the AI does the same in scripts/sim/ai_drive.gd): every tank of the world whose gun can be set orders it at the nearest enemy
# the sim allows (World.gun_check ok), in the first step that allows it. Returns how many orders were set.
static func fire_at_nearest(w: World) -> int:
	var n := 0
	for id: String in w.units:
		var u: Object = w.units[id]
		if u.type != "tank" or u.down or u.def.is_static():
			continue
		var best := ""
		var best_d := INF
		for tid: String in w.units:
			var t: Object = w.units[tid]
			if t.side == u.side or t.down:
				continue
			var d := Vector2(u.x, u.y).distance_to(Vector2(t.x, t.y))
			if d < best_d:
				best_d = d
				best = tid
		if best == "":
			continue
		for k in w.steps_per_turn(id):
			if bool(w.gun_check(id, k, {"unit": best}, "tank_gun").get("ok", false)):
				if not order_fire(w, id, best, k).is_empty():
					n += 1
				break
	return n

# The "fire" events of a result by a shooter at a target (the aimed shots of the tank's gun).
static func fires(res: Dictionary, shooter: String, target: String = "") -> Array:
	return (res.get("events", []) as Array).filter(func(e: Dictionary) -> bool:
		return e["type"] == "fire" and e["unit"] == shooter and (target == "" or e["target"] == target))

# The "gun_hold" events of a result for a shooter.
static func holds(res: Dictionary, shooter: String) -> Array:
	return (res.get("events", []) as Array).filter(func(e: Dictionary) -> bool: return e["type"] == "gun_hold" and e["unit"] == shooter)
