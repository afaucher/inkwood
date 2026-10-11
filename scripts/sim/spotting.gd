extends RefCounted

# SHARED SPOTTING: is a target (a unit or a point) SPOTTED by a side at a moment (Track SH, the warship, proposed 2026-10-10).
# Alex (decision mixed-warfare): "you need tanks to move inland to spot the aa batteries for the ship"; shared spotting: "Yes" --
# any friendly unit's sight counts for every gun of its side, and long-range guns need a spotted target. The sim's answer, from
# the SAME sight rules the player's fog (scripts/render/fog_vision.gd) and the enemy AI (scripts/sim/ai_sense.gd) use:
#
#   a unit of the side SEES a point when it is inside that unit's sight circle: its type's sight_range_m (times sight_scale, the
#   fog's sight_range_scale knob, 1.0), as sight_rules.gd gives it (a live unit sees its full radius; an exploded, destroyed or
#   crashed one nothing; a plane disabled and falling a reduced one -- Alex, "sight follows the pilot"), and, where the fog has
#   line of sight on, where the line of sight from the unit's eye to the target is not blocked.
#
# LINE OF SIGHT IS A SEAM (PROPOSED): the sim does not know the terrain, as it does not know the water (World.set_water); it is
# GIVEN a line-of-sight Callable, `los`, by whoever has a terrain, and without one the answer is the circle alone. That is exactly
# the fog's own default (data/view/fog.json vision.line_of_sight "none"): the glue that switches the fog's line of sight on
# should hand the same query to World.set_sight_los. The Callable is called only for an observer already inside its circle:
#
#     los(observer: Dictionary, target: Dictionary) -> bool        # true: the line is clear
#     each end: {unit: Unit (or null for a point), x, y, altitude_band, height_m}   metres; the ends' states at that moment
#
# (fog_vision.gd: unit_agl() turns a state into an eye height above the ground, visible_from() asks the viewshed.)
#
# THE MOMENT. A query is made at a moment: t < 0 is the world as it stands (the planning phase: the interface asks what the player
# sees, and the card words the answer); t >= 0 is that many seconds into the last resolve (World.sample's clock), for the host's
# resolve (the guns fire at a moment of a step). `down_at` ({unit id: seconds}) tells which units went down THIS turn and when
# (they are not marked down until the turn's combat is over): from that moment they see nothing (PROPOSED: a plane shot down
# mid-turn loses the reduced falling sight it would otherwise keep, because the combat has not chosen its fate yet).
#
# HOW LONG IT HAS BEEN SPOTTED. run_at() walks the turn from its start, every spot.step_s of data/sim/guns.json, and answers
# whether the target is spotted at the moment AND for how many seconds without a break (the guns range in on a target that stays
# spotted: guns.gd). A run that is still going at the end of a turn is REMEMBERED per side and target unit (World.spot_memory,
# which the host sends with the turn's result) and the next turn's run starts from it; a break starts it again from nothing; a
# point on the map has no memory (it is not a thing that can be tracked), so its run is the part of the turn it has been in sight.
#
# Everything here is a pure function of the World's units, their histories and the arguments: deterministic, host-resolved,
# testable headless. The World is passed as an untyped Object (world.gd preloads this file).

const SightRules = preload("res://scripts/sim/sight_rules.gd")
const ConcealRules = preload("res://scripts/sim/concealment.gd")
const RevealRules = preload("res://scripts/sim/reveal.gd")

var rules: SightRules = SightRules.new()
var los: Callable = Callable()       # see the header; invalid: circles only
var sight_scale: float = 1.0         # multiplies every unit's sight_range_m (the fog's sight_range_scale knob)

var _frames: Dictionary = {}         # t (seconds into the resolve, as a String) -> {unit id: sampled state}: positions only
var _frames_turn: int = -1

# --- Frames ---------------------------------------------------------------------------------

# Where every unit is at moment `t`: {unit id: {x, y, heading, speed, altitude_band, height_m}}. t < 0: as the units stand.
# t >= 0: the last resolve's histories (World.sample). Cached through one resolve (forget() drops the cache).
func frame_at(world: Object, t: float, source: String = "history") -> Dictionary:
	if t >= 0.0:
		if _frames_turn != int(world.turn):
			_frames.clear()
			_frames_turn = int(world.turn)
		var key := "%s|%.4f" % [source, t]
		if _frames.has(key):
			return _frames[key]
	var out := {}
	for id: String in world.units:
		var u: Object = world.units[id]
		var s: Dictionary
		if t >= 0.0:
			s = world.sample(id, t, source)
		else:
			s = u.state()
			s["height_m"] = float(u.fall_height_m) if is_finite(float(u.fall_height_m)) else float(world.band_height(str(u.altitude_band)))
		out[id] = s
	if t >= 0.0:
		_frames["%s|%.4f" % [source, t]] = out
	return out

# Forgets the cached frames (a new resolve, or units that changed under a query).
func forget() -> void:
	_frames.clear()
	_frames_turn = -1

# --- Sight ------------------------------------------------------------------------------------

# The radius, metres, that unit `u` (at state `s`, moment `t`) sees to: 0 for a unit that sees nothing.
func radius_at(u: Object, s: Dictionary, t: float, down_at: Dictionary = {}) -> float:
	var base := float(u.def.sight_range_m) * sight_scale
	if not (base > 0.0):
		return 0.0
	if bool(u.down):
		return rules.radius_m(u, base, -1.0, float(s.get("height_m", NAN)))   # as it stands: sight_rules.gd
	if t >= 0.0 and down_at.has(u.id) and t >= float(down_at[u.id]):
		return 0.0
	return base

# The target at a moment: {x, y, unit (Object or null), state (the sampled state, a point's made up)} -- or {} when it names a
# unit that is not in the world.
func target_at(world: Object, target: Dictionary, frame: Dictionary) -> Dictionary:
	if target.has("unit"):
		var id := str(target["unit"])
		if not world.units.has(id) or not frame.has(id):
			return {}
		var s: Dictionary = frame[id]
		return {"x": float(s["x"]), "y": float(s["y"]), "unit": world.units[id], "state": s}
	if target.has("point"):
		var p: Variant = target["point"]
		var px := (p as Vector2).x if p is Vector2 else float(p[0])
		var py := (p as Vector2).y if p is Vector2 else float(p[1])
		return {"x": px, "y": py, "unit": null, "state": {"x": px, "y": py, "altitude_band": "surface", "height_m": 0.0}}
	return {}

# Does unit `o` (at state `os`) see the target `tg` (target_at's): inside its sight circle and, with a line-of-sight query given, a clear line.
func _sees(o: Object, os: Dictionary, tg: Dictionary, t: float, down_at: Dictionary, world: Object = null) -> bool:
	var r := radius_at(o, os, t, down_at)
	if r <= 0.0:
		return false
	# CONCEALMENT (Track M2L, proposed; scripts/sim/concealment.gd): a target unit in cover is seen only within the rule's radius, unless it has fired at
	# the spotter's side and is revealed at this moment (scripts/sim/reveal.gd)
	if world != null and tg["unit"] != null:
		var cover: RefCounted = ConcealRules.shared()
		if cover.covered(world, tg["unit"], float(tg["x"]), float(tg["y"])) and not _revealed(world, tg["unit"], str(o.side), t):
			r = minf(r, float(cover.radius_m))
	var dx := float(tg["x"]) - float(os["x"])
	var dy := float(tg["y"]) - float(os["y"])
	if dx * dx + dy * dy > r * r:
		return false
	if los.is_valid():
		var eye := {"unit": o, "x": float(os["x"]), "y": float(os["y"]), "altitude_band": str(os.get("altitude_band", o.altitude_band)), "height_m": float(os.get("height_m", NAN))}
		var ts: Dictionary = tg["state"]
		var tgt := {"unit": tg["unit"], "x": float(tg["x"]), "y": float(tg["y"]), "altitude_band": str(ts.get("altitude_band", "surface")), "height_m": float(ts.get("height_m", 0.0))}
		if not bool(los.call(eye, tgt)):
			return false
	return true

# Is the unit revealed to `side` at moment `t` (seconds into the last resolve; < 0: as the world stands) by having fired at it (reveal.gd)?
func _revealed(world: Object, unit: Object, side: String, t: float) -> bool:
	var rv: Variant = RevealRules.of(world)
	if rv == null or not rv.ok():
		return false
	return bool(rv.is_revealed(str(unit.id), side, rv.game_time(int(world.turn), t) if t >= 0.0 else rv.now_s(world)))

# Every unit of `side` that sees `target` ({"unit": id} | {"point": [x, y]}) in this frame (unit ids, in World order). `frame` is
# frame_at()'s; `t` its moment (for the sight of units that went down this turn: down_at). A unit does not spot itself.
func spotters_in(world: Object, side: String, target: Dictionary, frame: Dictionary, t: float = -1.0, down_at: Dictionary = {}, first_only: bool = false) -> Array[String]:
	var out: Array[String] = []
	var tg := target_at(world, target, frame)
	if tg.is_empty():
		return out
	for id: String in world.units:
		var o: Object = world.units[id]
		if o.side != side or not frame.has(id):
			continue
		if target.has("unit") and str(target["unit"]) == id:
			continue
		if _sees(o, frame[id], tg, t, down_at, world):
			out.append(id)
			if first_only:
				break
	return out

# HOW CLOSE the nearest spotter is, as a share of its own sight: the smallest distance-to-the-target over sight radius among the units
# of `side` that see `target` in this frame (0: right on it, 1: the target is at the edge of the sight of every one that sees it), or
# 1.0 when none sees it. The guns' scatter reads it (guns.gd spotter_mult).
func closeness_in(world: Object, side: String, target: Dictionary, frame: Dictionary, t: float = -1.0, down_at: Dictionary = {}) -> float:
	var tg := target_at(world, target, frame)
	if tg.is_empty():
		return 1.0
	var best := 1.0
	for id: String in spotters_in(world, side, target, frame, t, down_at):
		var os: Dictionary = frame[id]
		var r := radius_at(world.units[id], os, t, down_at)
		if r <= 0.0:
			continue
		var d := Vector2(float(tg["x"]) - float(os["x"]), float(tg["y"]) - float(os["y"])).length()
		best = minf(best, clampf(d / r, 0.0, 1.0))
	return best

# The fog's own line of sight as this class's query (the glue that builds the fog and the World calls
# world.set_sight_los(Spotting.los_from_vision(fog.vision, world)); the query asks the vision each time, so it follows the fog's run-time
# line-of-sight switch). `vision` is a FogVision (duck-typed here: los_on(), engine().visible_from(eye, eye_agl, point, target_agl),
# unit_agl(world, unit, x, y, band, height_m)); a target that is a point is the ground itself (height 0), a unit is seen at its own height.
static func los_from_vision(vision: Object, world: Object) -> Callable:
	return func(eye: Dictionary, tgt: Dictionary) -> bool:
		if not bool(vision.los_on()):
			return true
		var engine: Object = vision.engine()
		if engine == null:
			return true
		var eye_agl := float(vision.unit_agl(world, eye["unit"], float(eye["x"]), float(eye["y"]), str(eye["altitude_band"]), float(eye["height_m"])))
		var tu: Variant = tgt["unit"]
		var tgt_agl := 0.0
		if tu != null:
			tgt_agl = float(vision.unit_agl(world, tu, float(tgt["x"]), float(tgt["y"]), str(tgt["altitude_band"]), float(tgt["height_m"])))
		return bool(engine.visible_from(Vector2(float(eye["x"]), float(eye["y"])), eye_agl, Vector2(float(tgt["x"]), float(tgt["y"])), tgt_agl))

# Does any unit of `side` see `target` in this frame? {spotted: bool, by: the first unit that does, or ""}.
func spotted_in(world: Object, side: String, target: Dictionary, frame: Dictionary, t: float = -1.0, down_at: Dictionary = {}) -> Dictionary:
	var by := spotters_in(world, side, target, frame, t, down_at, true)
	return {"spotted": not by.is_empty(), "by": by[0] if not by.is_empty() else ""}

# Is the target spotted by `side` as the world stands now (the planning phase)?
func spotted_now(world: Object, side: String, target: Dictionary) -> bool:
	return bool(spotted_in(world, side, target, frame_at(world, -1.0))["spotted"])

# Is the target spotted by `side` at `t` seconds into the last resolve?
func spotted_at(world: Object, side: String, target: Dictionary, t: float, down_at: Dictionary = {}, source: String = "history") -> bool:
	return bool(spotted_in(world, side, target, frame_at(world, t, source), t, down_at)["spotted"])

# Who of `side` sees the target now (unit ids, in World order): the card's "spotted by".
func spotters_now(world: Object, side: String, target: Dictionary) -> Array[String]:
	return spotters_in(world, side, target, frame_at(world, -1.0))

# Walk the turn from its start to `t_end` every `step_s`: whether the target is spotted at t_end and for how many seconds without a break.
# `carry_s` is the run it had at the start of the turn (World.spot_memory); it counts only if the target is spotted at 0.
# {spotted: bool, run_s: float}. A break in the run (not spotted at some step) starts it again from nothing.
func run_at(world: Object, side: String, target: Dictionary, t_end: float, carry_s: float, step_s: float, down_at: Dictionary = {}, source: String = "history") -> Dictionary:
	var run := 0.0
	var spotted := false
	var t := 0.0
	var prev := 0.0
	var first := true
	while true:
		spotted = spotted_at(world, side, target, t, down_at, source)
		if first:
			run = carry_s if spotted else 0.0
			first = false
		elif spotted:
			run += t - prev
		else:
			run = 0.0
		if t >= t_end - 1e-9:
			break
		prev = t
		t = minf(t + step_s, t_end)
	return {"spotted": spotted, "run_s": run}

# The memory a turn leaves: {side: {unit id: run seconds at the turn's end}} for every enemy unit (still up) some unit of a side has
# spotted without a break to the end of the turn. `memory` is what the turn began with (the carry), `down_at` the units downed in it.
func memory_after(world: Object, memory: Dictionary, turn_seconds: float, step_s: float, down_at: Dictionary = {}) -> Dictionary:
	var sides: Array[String] = []
	for id: String in world.units:
		var sd: String = (world.units[id] as Object).side
		if not sides.has(sd):
			sides.append(sd)
	var out := {}
	for side: String in sides:
		var mine := {}
		var carried: Dictionary = memory.get(side, {})
		for id: String in world.units:
			var tu: Object = world.units[id]
			if tu.side == side or bool(tu.down) or down_at.has(id):
				continue
			var r := run_at(world, side, {"unit": id}, turn_seconds, float(carried.get(id, 0.0)), step_s, down_at)
			if bool(r["spotted"]) and float(r["run_s"]) > 0.0:
				mine[id] = float(r["run_s"])
		if not mine.is_empty():
			out[side] = mine
	return out
