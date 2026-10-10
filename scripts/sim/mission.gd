extends RefCounted

# THE MISSION RULES (Track E, proposed, 2026-10-09): win and lose conditions as
# DATA, evaluated after each resolve. Built for the first fight's INTERCEPT
# scenario (design doc: two player fighters must find and shoot down an enemy
# bomber, flying with an escort, before it reaches a target on the map); it
# holds exactly the three conditions Intercept needs, in a vocabulary other
# missions can be written in.
#
# THE SPEC (a Dictionary, so a scenario file can carry it as its "mission"):
#   {
#     "id": "intercept",                         (optional, a label)
#     "target": [x, y],                          (optional) the point "target" names
#     "win":  [ condition, ... ],                WON when ANY holds
#     "lose": [ condition, ... ],                LOST when ANY holds
#   }
# CONDITIONS, each {"type": ..., ...}:
#   {"type": "unit_down",   "unit": id}
#       the unit is down (Unit.down).
#   {"type": "all_down",    "units": [id, ...]}   or  "controller": "player"  or  "side": id
#       every unit of the set is down (an empty set is never "all down").
#   {"type": "unit_within", "unit": id, "of": "target" | [x, y], "radius_m": r}
#       the unit comes within r metres of the point at ANY sampled time of the
#       turn, not only at its end: the turn's path is looked at every sample_dt_s
#       seconds (data/sim/ai.json, mission). radius_m defaults to
#       mission.target_radius_m in the same file. A unit that went down this
#       turn counts only up to the moment it went down (Unit.down_at); one that
#       was already down counts for nothing.
#
#   var m := Mission.new(world, spec)       # spec: see intercept()
#   m.attach()                              # evaluates after every turn_resolved
#   m.evaluate()                            # or by hand after a resolve
#   m.state, m.reason, m.turn               # "playing" | "won" | "lost"
#   -> evaluate() returns {state, reason, turn, t}  (t: seconds into the turn
#      the deciding condition first held, NAN while playing)
#
# THE ORDER: a result is STICKY (once won or lost it stays). If a win and a lose
# condition both hold in one turn, the one that held EARLIER in the turn decides
# (the bomber dropping its bomb at t = 2 s beats being shot down at t = 4 s); an
# exact tie goes to the players (proposed). A unit_down that is already true
# when first evaluated counts as t = 0.
#
# It reads only the world's units and World.sample(), so a client that applied
# the host's resolution (World.apply_resolution, which also emits turn_resolved)
# reaches the same verdict as the host.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")

signal state_changed(state: String, reason: String, turn: int)

const PLAYING := "playing"
const WON := "won"
const LOST := "lost"

const TYPE_UNIT_DOWN := "unit_down"
const TYPE_ALL_DOWN := "all_down"
const TYPE_UNIT_WITHIN := "unit_within"
const TYPES := [TYPE_UNIT_DOWN, TYPE_ALL_DOWN, TYPE_UNIT_WITHIN]

var world: World = null
var spec: Dictionary = {}
var state: String = PLAYING
var reason: String = ""
var turn: int = 0
var time: float = NAN
var errors: Array[String] = []

var _sample_dt: float = NAN
var _default_radius: float = NAN
var _target: Array = []
var _quiet: bool = false

func _init(target_world: World, mission_spec: Dictionary, data_path: String = AiParams.DATA_PATH, quiet: bool = false) -> void:
	world = target_world
	spec = mission_spec
	_quiet = quiet
	var params := AiParams.new(data_path, quiet)
	errors.append_array(params.errors)
	_sample_dt = params.num("mission", "sample_dt_s")
	_default_radius = params.num("mission", "target_radius_m")
	_validate()

func ok() -> bool:
	return errors.is_empty()

# The Intercept mission as a spec: won when `bomber` is down; lost when it comes
# within radius_m of `target`, or when every unit of `controller` ("player") is
# down. radius_m <= 0 takes the data's default (mission.target_radius_m).
static func intercept(bomber: String, target: Array, radius_m: float = 0.0, controller: String = World.CONTROLLER_PLAYER) -> Dictionary:
	var within := {"type": TYPE_UNIT_WITHIN, "unit": bomber, "of": "target"}
	if radius_m > 0.0:
		within["radius_m"] = radius_m
	return {
		"id": "intercept",
		"target": target,
		"win": [{"type": TYPE_UNIT_DOWN, "unit": bomber}],
		"lose": [within, {"type": TYPE_ALL_DOWN, "controller": controller}],
	}

# Evaluate after each resolve (or let attach() do it). `result` is
# World.resolve()'s return value; only its "turn" is used.
func evaluate(result: Dictionary = {}) -> Dictionary:
	if state != PLAYING or not ok():
		return status()
	turn = int(result.get("turn", world.turn))
	var won := _first(spec.get("win", []))
	var lost := _first(spec.get("lose", []))
	var verdict := ""
	var hit: Dictionary = {}
	if not won.is_empty() and (lost.is_empty() or float(won["t"]) <= float(lost["t"])):
		verdict = WON
		hit = won
	elif not lost.is_empty():
		verdict = LOST
		hit = lost
	if verdict != "":
		state = verdict
		reason = str(hit["reason"])
		time = float(hit["t"])
		state_changed.emit(state, reason, turn)
	return status()

func status() -> Dictionary:
	return {"state": state, "reason": reason, "turn": turn, "t": time}

# Evaluate after every resolve the world announces (a host's own or a client's
# applied one).
func attach() -> void:
	if not world.turn_resolved.is_connected(_on_turn_resolved):
		world.turn_resolved.connect(_on_turn_resolved)

func detach() -> void:
	if world.turn_resolved.is_connected(_on_turn_resolved):
		world.turn_resolved.disconnect(_on_turn_resolved)

func _on_turn_resolved(turn_no: int, _histories: Dictionary, _events: Array) -> void:
	evaluate({"turn": turn_no})

# --- Conditions ----------------------------------------------------------------

# The earliest-holding condition of a list as {t, reason}, or {} if none holds
# (earlier in the list wins a tie).
func _first(conditions: Variant) -> Dictionary:
	var best: Dictionary = {}
	if not (conditions is Array):
		return best
	for c: Variant in (conditions as Array):
		var hit := _check(c as Dictionary)
		if not hit.is_empty() and (best.is_empty() or float(hit["t"]) < float(best["t"])):
			best = hit
	return best

func _check(c: Dictionary) -> Dictionary:
	match str(c.get("type", "")):
		TYPE_UNIT_DOWN:
			var id := str(c["unit"])
			var u: Unit = world.units.get(id)
			if u != null and u.down:
				return {"t": _down_time(u), "reason": "%s is down" % id}
		TYPE_ALL_DOWN:
			var members := _unit_set(c)
			if members.is_empty():
				return {}
			var latest := 0.0
			for u: Unit in members:
				if not u.down:
					return {}
				latest = maxf(latest, _down_time(u))
			return {"t": latest, "reason": "%s down" % _set_label(c)}
		TYPE_UNIT_WITHIN:
			return _check_within(c)
	return {}

# The first sampled time this turn the unit was within the radius of the point.
func _check_within(c: Dictionary) -> Dictionary:
	var id := str(c["unit"])
	var u: Unit = world.units.get(id)
	if u == null:
		return {}
	var pt := _resolve_point(c.get("of"))
	var radius := float(c.get("radius_m", _default_radius))
	var turn_s := world.rules.turn_seconds
	# A unit that went down this turn counts only before that moment; one that was
	# already down counts for nothing.
	var until := turn_s
	if u.down:
		if is_nan(u.down_at):
			return {}
		until = u.down_at
	var steps := int(ceil(turn_s / _sample_dt))
	for k in steps + 1:
		var t := minf(float(k) * _sample_dt, turn_s)
		if u.down and t >= until:
			break
		var s := world.sample(id, t, "history")
		if s.is_empty():
			return {}
		var dx := float(s["x"]) - float(pt[0])
		var dy := float(s["y"]) - float(pt[1])
		if dx * dx + dy * dy <= radius * radius:
			return {"t": t, "reason": "%s came within %.0f m of %s" % [id, radius, _point_label(c.get("of"))]}
	return {}

# When a unit went down, in seconds into the turn being judged: down_at if it
# went down this turn, else 0 (it was already down).
static func _down_time(u: Unit) -> float:
	return 0.0 if is_nan(u.down_at) else u.down_at

func _unit_set(c: Dictionary) -> Array:
	var out: Array = []
	if c.has("units"):
		for id: Variant in (c["units"] as Array):
			var u: Variant = world.units.get(str(id))
			if u != null:
				out.append(u)
	elif c.has("controller"):
		for id: String in world.units:
			if (world.units[id] as Unit).controller == str(c["controller"]):
				out.append(world.units[id])
	elif c.has("side"):
		for id: String in world.units:
			if (world.units[id] as Unit).side == str(c["side"]):
				out.append(world.units[id])
	return out

func _set_label(c: Dictionary) -> String:
	if c.has("units"):
		return "all of %s are" % str(c["units"])
	if c.has("controller"):
		return "all %s units are" % str(c["controller"])
	return "all %s units are" % str(c.get("side", ""))

func _resolve_point(of: Variant) -> Array:
	if of is String and of == "target":
		return _target
	if of is Array and (of as Array).size() == 2:
		return [float(of[0]), float(of[1])]
	return [NAN, NAN]

func _point_label(of: Variant) -> String:
	if of is String and of == "target":
		return "the target"
	return "[%.0f, %.0f]" % [float(_resolve_point(of)[0]), float(_resolve_point(of)[1])]

# --- Validation ----------------------------------------------------------------

func _validate() -> void:
	if spec.has("target"):
		var t: Variant = spec["target"]
		if t is Array and (t as Array).size() == 2 and ((t as Array)[0] is float or (t as Array)[0] is int) and ((t as Array)[1] is float or (t as Array)[1] is int):
			_target = [float(t[0]), float(t[1])]
		else:
			_err("'target' must be [x, y]")
	for list_key: String in ["win", "lose"]:
		if not spec.has(list_key):
			_err("the mission has no '%s' list" % list_key)
			continue
		if not (spec[list_key] is Array):
			_err("'%s' must be a list of conditions" % list_key)
			continue
		var i := 0
		for c: Variant in (spec[list_key] as Array):
			_validate_condition(c, "%s[%d]" % [list_key, i])
			i += 1
	if (spec.get("win", []) as Array).is_empty() and (spec.get("lose", []) as Array).is_empty():
		_err("a mission with no conditions can never end")

func _validate_condition(c: Variant, label: String) -> void:
	if not (c is Dictionary):
		_err("%s is not a condition object" % label)
		return
	var d: Dictionary = c
	var type := str(d.get("type", ""))
	if not TYPES.has(type):
		_err("%s: unknown condition type '%s' (known: %s)" % [label, type, str(TYPES)])
		return
	match type:
		TYPE_UNIT_DOWN:
			_need_unit(d, "unit", label)
		TYPE_UNIT_WITHIN:
			_need_unit(d, "unit", label)
			var of: Variant = d.get("of")
			if of is String and of == "target":
				if _target.is_empty():
					_err("%s: 'of' is \"target\" but the mission names no 'target' point" % label)
			elif not (of is Array and (of as Array).size() == 2):
				_err("%s: 'of' must be \"target\" or [x, y]" % label)
			if d.has("radius_m") and not ((d["radius_m"] is float or d["radius_m"] is int) and float(d["radius_m"]) > 0.0):
				_err("%s: 'radius_m' must be a positive number" % label)
		TYPE_ALL_DOWN:
			var selectors := 0
			for k: String in ["units", "controller", "side"]:
				if d.has(k):
					selectors += 1
			if selectors != 1:
				_err("%s: all_down needs exactly one of 'units', 'controller', 'side'" % label)
			if d.has("units"):
				if not (d["units"] is Array):
					_err("%s: 'units' must be a list of unit ids" % label)
				else:
					for id: Variant in (d["units"] as Array):
						if not world.units.has(str(id)):
							_err("%s: no unit '%s'" % [label, str(id)])

func _need_unit(d: Dictionary, key: String, label: String) -> void:
	if not d.has(key) or not world.units.has(str(d[key])):
		_err("%s: '%s' must name a unit in the world (got '%s')" % [label, key, str(d.get(key, ""))])

func _err(message: String) -> void:
	errors.append("mission: " + message)
	if not _quiet:
		push_error("Mission: " + message)
