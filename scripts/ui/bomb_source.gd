extends RefCounted

# WHERE THE INTERFACE GETS ITS BOMBS (Track U3, the strike, 2026-10-10). One seam between the
# simulation's bomb answers and everything the interface draws or enables with them: the planner
# (the Drop control, the aim handle), the bomb cone node, the orders card and the roster. The
# simulation (Track S2, scripts/sim/world.gd + bombs.gd) answers three questions about a unit and
# this class asks them in one place, in one shape, and remembers the answers until the plan changes
# (a cone is a polygon merged from thirteen footprints: not something to ask for every frame):
#
#   World.bombs_left(unit_id)              -> {drops_left, drops_max, per_drop, planned, carries}
#   World.drop_cone(unit_id, step_index)   -> {ok, polygon, ideal_aim, release_path, height_m, ...}
#   World.drop_spread(unit_id, step, aim)  -> {spread {radius_m, along_m, across_m, heading}, quality,
#                                              release, stick_length_m, clamped, ...}
#
# AND NOTHING ELSE: a World that lacks them (an older one) has no bombs as far as the interface is
# concerned (has_bombs false, no Drop control). The keys are read tolerantly (_first lists the names
# each may have); a missing key is a missing piece of the picture, never a crash. The World's header
# and bombs.gd are the truth about what they mean.
#
# WHAT THIS HANDS ON (positions metres, world space):
#   bombs_left(id) -> {drops_left, drops_max, per_drop, has_bombs}
#   cone(id, k)    -> {ok, polygon: PackedVector2Array, ideal_aim: Vector2 (INF: none),
#                      path: PackedVector2Array (the bomber through the step), height_m}
#   aim_info(id, k, aim) -> {quality (0..1: the accuracy factor, 1 at the ideal release angle),
#                      spread {along_m, across_m, heading, sigma_m, stick_m}, release: Vector2 (INF: none)}
#   inside(poly, p) / nearest_inside(poly, p)   the aim must lie inside the cone
#
# THE SPREAD THAT IS DRAWN. The sim's spread is one bomb's scatter, a standard deviation (sigma) in each
# ground axis; the stick of a drop (its bombs fall a few metres apart along the bomber's heading) adds its
# own length. What the map shows is the ellipse that holds most of the stick: `across` = sigma_k x sigma,
# `along` = sigma_k x sigma + half the stick (data bombs.aim.spread.sigma_k, proposed 2: 86 percent of a
# round scatter lies inside two sigma). The orders card's "spread N m" is that across radius.
#
# WHAT A RESOLVE DOES TO WHAT IS SHOWN (as UiHealth does for pips): the drops shown on the roster during a
# playback are the ones the unit had when the turn began, and one empties as its `bomb_release` event passes
# (release_seen); clear_shown() when the playback ends.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

var world: Object = null
var style: RefCounted = null

var _start: Dictionary = {}     # unit id -> drops left when this turn's planning began
var _shown: Dictionary = {}     # unit id -> drops left to show during the playback
var _max: Dictionary = {}       # unit id -> the most drops seen (when the sim sends no max)
var _cone_cache: Dictionary = {}   # "id|k" -> normalized cone
var _info_cache: Dictionary = {}   # "id|k|ax|ay" -> normalized aim info

func setup(w: Object, st: RefCounted) -> void:
	world = w
	style = st
	snapshot()
	if world != null and world.has_signal("phase_changed") and not world.phase_changed.is_connected(_on_phase):
		world.phase_changed.connect(_on_phase)
		world.plan_changed.connect(_on_plan_changed)

func _on_phase(phase: String) -> void:
	_cone_cache.clear()
	_info_cache.clear()
	if phase == World.PHASE_PLANNING:
		_shown.clear()
		snapshot()

func _on_plan_changed(id: String) -> void:
	for cache: Dictionary in [_cone_cache, _info_cache]:
		for key: String in cache.keys():
			if key.begins_with(id + "|"):
				cache.erase(key)

# Whether the World answers bomb questions at all.
func available() -> bool:
	return world != null and world.has_method("drop_cone") and world.has_method("bombs_left") and world.has_method("drop_spread")

# --- The load ----------------------------------------------------------------------------------

# The unit's load now: {drops_left, drops_max, per_drop, has_bombs}. A unit with no bombs (or an
# unknown one) is all zeros.
func bombs_left(id: String) -> Dictionary:
	var none := {"drops_left": 0, "drops_max": 0, "per_drop": 0, "has_bombs": false}
	if not available() or not world.units.has(id):
		return none
	var raw: Variant = world.bombs_left(id)
	if not (raw is Dictionary):
		return none
	var r: Dictionary = raw
	var left := int(_first(r, ["drops_left", "drops", "left"], 0))
	var per := int(_first(r, ["per_drop", "bombs_per_drop"], 0))
	var mx := int(_first(r, ["drops_max", "max_drops", "drops_total", "total_drops"], 0))
	mx = maxi(mx, maxi(int(_max.get(id, 0)), left))
	_max[id] = mx
	var carries := bool(_first(r, ["carries"], per > 0 or mx > 0))
	return {"drops_left": left, "drops_max": mx, "per_drop": per, "has_bombs": carries and (per > 0 or mx > 0)}

func has_bombs(id: String) -> bool:
	return bool(bombs_left(id)["has_bombs"])

# The steps of the unit's plan that carry a drop, in order.
func drop_steps(id: String) -> Array[int]:
	var out: Array[int] = []
	if world == null or not world.units.has(id):
		return out
	var plan: Array = world.units[id].plan
	for k in plan.size():
		if (plan[k] as Dictionary).has("drop"):
			out.append(k)
	return out

# Drops still free to plan: the load minus the steps already carrying one (the step
# `except_step`, if any, does not count: it is the one being asked about).
func drops_free(id: String, except_step: int = -1) -> int:
	var n := int(bombs_left(id)["drops_left"])
	for k in drop_steps(id):
		if k != except_step:
			n -= 1
	return maxi(n, 0)

# --- Playback: the load as the turn began --------------------------------------------------------

func snapshot() -> void:
	_start.clear()
	if world == null:
		return
	for id: String in world.units:
		var b := bombs_left(id)
		if bool(b["has_bombs"]):
			_start[id] = int(b["drops_left"])

# Drops to show for the unit: during a playback the turn's start less the releases seen.
func shown_drops(id: String, playing: bool) -> int:
	var now := int(bombs_left(id)["drops_left"])
	if playing:
		if _shown.has(id):
			return int(_shown[id])
		if _start.has(id):
			return int(_start[id])
	return now

# A bomb_release event of `id` passed the playback clock.
func release_seen(id: String) -> void:
	_shown[id] = maxi(shown_drops(id, true) - 1, 0)

func clear_shown() -> void:
	_shown.clear()

# --- The cone ---------------------------------------------------------------------------------------

# The step's bomb cone, normalized. {ok: false} when there is none (no bombs, no such step, a unit that
# is down).
func cone(id: String, k: int) -> Dictionary:
	var bad := {"ok": false, "polygon": PackedVector2Array(), "ideal_aim": Vector2.INF, "path": PackedVector2Array(), "height_m": 0.0}
	if not available() or not world.units.has(id) or k < 0 or not has_bombs(id):
		return bad
	var key := "%s|%d" % [id, k]
	if _cone_cache.has(key):
		return _cone_cache[key]
	var raw: Variant = world.drop_cone(id, k)
	var rec := bad.duplicate()
	if raw is Dictionary:
		var r: Dictionary = raw
		rec["polygon"] = _poly(_first(r, ["polygon", "region", "outline", "impact_region"], []))
		rec["ideal_aim"] = _v2(_first(r, ["ideal_aim", "ideal"], null))
		rec["path"] = _poly(_first(r, ["release_path", "path"], []))
		rec["height_m"] = float(_first(r, ["height_m", "height"], 0.0))
		rec["ok"] = bool(r.get("ok", true)) and (rec["polygon"] as PackedVector2Array).size() >= 3
	_cone_cache[key] = rec
	return rec

# What an aim point gets in the step: the accuracy (quality), the spread to draw, and where the bomber
# releases. Zeros for a step without a cone.
func aim_info(id: String, k: int, aim: Vector2) -> Dictionary:
	var info := {"quality": 0.0, "release": Vector2.INF,
		"spread": {"along_m": 0.0, "across_m": 0.0, "heading": 0.0, "sigma_m": 0.0, "stick_m": 0.0}}
	if not aim.is_finite() or not bool(cone(id, k)["ok"]):
		return info
	var key := "%s|%d|%.2f|%.2f" % [id, k, aim.x, aim.y]
	if _info_cache.has(key):
		return _info_cache[key]
	var raw: Variant = world.drop_spread(id, k, aim)
	if raw is Dictionary:
		var r: Dictionary = raw
		var sp: Variant = _first(r, ["spread"], {})
		var sigma := 0.0
		var heading := 0.0
		if sp is Dictionary:
			var sd: Dictionary = sp
			sigma = float(_first(sd, ["radius_m", "radius", "across_m", "along_m"], 0.0))
			heading = float(_first(sd, ["heading", "angle"], 0.0))
		elif sp is float or sp is int:
			sigma = float(sp)
		sigma = float(_first(r, ["spread_m"], sigma))
		var stick := float(_first(r, ["stick_length_m", "stick_m"], 0.0))
		var k_sigma: float = style.num("bombs.aim.spread.sigma_k")
		info["spread"] = {"along_m": sigma * k_sigma + stick * 0.5, "across_m": sigma * k_sigma, "heading": heading, "sigma_m": sigma, "stick_m": stick}
		info["quality"] = clampf(float(_first(r, ["quality", "accuracy"], 0.0)), 0.0, 1.0)
		var rel := _v2(_first(r, ["release", "release_pos"], null))
		if rel.is_finite():
			info["release"] = rel
	_info_cache[key] = info
	return info

# --- Geometry helpers -------------------------------------------------------------------------------------------

static func inside(poly: PackedVector2Array, p: Vector2) -> bool:
	return poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly)

# `p` itself when it is inside the polygon, else the nearest point of the polygon's edge
# pulled a hair inside (so it still tests as inside).
static func nearest_inside(poly: PackedVector2Array, p: Vector2) -> Vector2:
	if poly.size() < 3:
		return p
	if Geometry2D.is_point_in_polygon(p, poly):
		return p
	var best := poly[0]
	var best_d := INF
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
		var d := q.distance_to(p)
		if d < best_d:
			best_d = d
			best = q
	var c := _centroid(poly)
	for t in [0.004, 0.02, 0.08]:
		var q2 := best.lerp(c, t)   # a hair inside
		if Geometry2D.is_point_in_polygon(q2, poly):
			return q2
	return best

static func _centroid(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	var c := Vector2.ZERO
	for q in poly:
		c += q
	return c / float(poly.size())

static func _first(d: Dictionary, keys: Array, default: Variant) -> Variant:
	for k: Variant in keys:
		if d.has(k):
			return d[k]
	return default

static func _v2(v: Variant) -> Vector2:
	if v is Vector2:
		return v
	if v is Array and (v as Array).size() >= 2:
		return Vector2(float((v as Array)[0]), float((v as Array)[1]))
	if v is Dictionary and (v as Dictionary).has("x") and (v as Dictionary).has("y"):
		return Vector2(float((v as Dictionary)["x"]), float((v as Dictionary)["y"]))
	return Vector2.INF

static func _poly(v: Variant) -> PackedVector2Array:
	if v is PackedVector2Array:
		return v
	var out := PackedVector2Array()
	if v is Array:
		for e: Variant in v:
			var q := _v2(e)
			if q.is_finite():
				out.append(q)
	return out
