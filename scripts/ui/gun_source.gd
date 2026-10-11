extends RefCounted

# WHERE THE INTERFACE GETS ITS BIG GUNS (Track SH, the warship, proposed 2026-10-10), the gun twin of bomb_source.gd: one seam
# between the simulation's answers about a gun special and everything the interface draws or enables with them -- the planner (the
# special's control, the lettering, the marks), the orders card and the roster. The simulation (scripts/sim/world.gd + guns.gd +
# spotting.gd) answers
#
#   World.gun_specials(unit_id)                      -> the gun special ids the unit has ("main_guns")
#   World.gun_check(unit_id, step, target, special)  -> {ok, reason, range_m, spotted, spotted_s, salvos, spread_m, flight_s, ...}
#   World.gun_reload_left(unit_id, special)          -> turns until the guns are loaded
#
# and this class asks in one place and remembers the answers until the plan changes (a check walks the sight rules over every
# unit: not something to ask for every frame). A World without them has no guns as far as the interface is concerned.
#
#   special_id(id) -> "main_guns" | ""            has_guns(id)
#   check(id, k, target) -> World.gun_check's record ({} when there is none), cached
#   fire_steps(id) -> the steps of the unit's plan that carry a fire, in order
#   reload_left(id) -> turns until the guns are loaded
#   range_max_m(id) / range_min_m(id) -> the special's reach, metres (0 with no guns)

const World = preload("res://scripts/sim/world.gd")

var world: Object = null
var style: RefCounted = null

var _cache: Dictionary = {}     # "id|k|target" -> World.gun_check's record

func setup(w: Object, st: RefCounted) -> void:
	world = w
	style = st
	_cache.clear()
	if world != null and world.has_signal("phase_changed") and not world.phase_changed.is_connected(_on_phase):
		world.phase_changed.connect(_on_phase)
		world.plan_changed.connect(_on_plan_changed)

func _on_phase(_phase: String) -> void:
	_cache.clear()

func _on_plan_changed(id: String) -> void:
	for key: String in _cache.keys():
		if key.begins_with(id + "|"):
			_cache.erase(key)

func available() -> bool:
	return world != null and world.has_method("gun_check") and world.has_method("gun_specials")

# The unit's gun special ("" for a unit with none).
func special_id(id: String) -> String:
	if not available() or not world.units.has(id):
		return ""
	var ids: Array = world.gun_specials(id)
	return str(ids[0]) if not ids.is_empty() else ""

func has_guns(id: String) -> bool:
	return special_id(id) != ""

# The steps of the unit's plan that carry a fire, in order.
func fire_steps(id: String) -> Array[int]:
	var out: Array[int] = []
	if world == null or not world.units.has(id) or world.units[id].controller != World.CONTROLLER_PLAYER:
		return out   # (only a player unit's plan is ever read: an AI unit's never reaches the screen)
	var plan: Array = world.units[id].plan
	for k in plan.size():
		if (plan[k] as Dictionary).has("fire"):
			out.append(k)
	return out

# World.gun_check for step k and a target ({"unit": id} | {"point": [x, y]}), cached until the plan changes. {} when there is none.
func check(id: String, k: int, target: Dictionary) -> Dictionary:
	var sid := special_id(id)
	if sid == "" or k < 0 or target.is_empty() or world.units[id].controller != World.CONTROLLER_PLAYER:
		return {}
	var key := "%s|%d|%s" % [id, k, JSON.stringify(target)]
	if _cache.has(key):
		return _cache[key]
	var raw: Variant = world.gun_check(id, k, target, sid)
	var rec: Dictionary = raw if raw is Dictionary else {}
	_cache[key] = rec
	return rec

func reload_left(id: String) -> int:
	var sid := special_id(id)
	if sid == "" or not world.has_method("gun_reload_left"):
		return 0
	return int(world.gun_reload_left(id, sid))

func range_max_m(id: String) -> float:
	var sid := special_id(id)
	if sid == "" or not ("guns" in world) or world.guns == null or not world.guns.has_special(sid):
		return 0.0
	return float(world.guns.special(sid).range_max_m)

func range_min_m(id: String) -> float:
	var sid := special_id(id)
	if sid == "" or not ("guns" in world) or world.guns == null or not world.guns.has_special(sid):
		return 0.0
	return float(world.guns.special(sid).range_min_m)
