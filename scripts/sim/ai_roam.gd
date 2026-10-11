extends RefCounted

# THE ROAM ROLE (Track M2L, PROPOSED 2026-10-11: the second mission, "clear the mobile AA and their escorts to enable a bombing run of a
# military complex"). The AI's orders for a MOBILE GROUND GUN that SHOOTS AND SCOOTS -- the lead's proposal, not Alex's (decision
# suppress-mission: the guns are hidden, move, and give themselves away when they fire, as the Wild Weasels baited guns over Vietnam).
# ai_pilot.gd assigns and dispatches (two lines), this class holds what is the role's own. Numbers: data/sim/roam.json.
#
#   {"role": "roam", "route": [[x, y], ...]}
#       route   the HIDE POINTS, two or more, in the order the gun visits them (the scenario writes them on the world layout's sites, as
#               a patrol's route: {"site": "radio_tower", "dx": .., "dy": ..}). The gun starts at the one nearest where it is placed.
#
# STATES (reported through ai_pilot.gd's transitions):
#   hide     standing at a hide point, no plane in its reach: it holds still. It has not fired since it settled here, or it has and
#            the delay has not passed.
#   fire     a plane (a known enemy aircraft, scripts/sim/ai_sense.gd: one the AI's units have in sight) is within its reach plus
#            a margin of its own: it HOLDS STILL, as the guns fire by the engagement rules (combat.gd), which the role never aims.
#   drive    relocating: it has FIRED (and so, by scripts/sim/reveal.gd, given itself away) and the delay (relocate_delay_turns) has
#            passed since its last shot, no plane is near: it drives to the next hide point of its list that is at least min_leg_m away,
#            by scripts/sim/ai_drive.gd's pure pursuit under the ground rule (data/sim/ground.json). A plane coming into reach on the
#            way stops it (fire); it drives on from where it stands when they are gone and it is due again.
#   arrived  (ai_drive's word) the leg is done: it settles at the new point (hide) at the next planning.
# A leg that makes no progress for stuck_turns turns running (held by the ground rule) is given up: it hides where it stands.
#
# WHAT IT KNOWS. Planes only as the AI knows anything (scripts/sim/ai_sense.gd: sight circles, no plan of a player's), and whether IT
# has fired, from Reveal (the record of its own shots). Deterministic: no randomness; planning a turn twice gives the same plans (the
# unit's memory `m` is restored by ai_pilot.gd, and the course a leg builds is a function of it).

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Records = preload("res://scripts/sim/records.gd")
const AiDrive = preload("res://scripts/sim/ai_drive.gd")
const RevealRules = preload("res://scripts/sim/reveal.gd")

const ROLE := "roam"
const S_HIDE := "hide"
const S_FIRE := "fire"

const R_START := "start"
const R_PLANES := "planes_in_reach"
const R_CLEAR := "clear"
const R_FIRED := "fired"
const R_SETTLED := "settled"
const R_STUCK := "stuck"

const PATH := "res://data/sim/roam.json"

# The numbers (data/sim/roam.json), read once.
class Rules extends RefCounted:
	var hold_reach_factor: float = NAN
	var hold_margin_m: float = NAN
	var relocate_delay_turns: int = 0
	var settle_tolerance_m: float = NAN
	var min_leg_m: float = NAN
	var stuck_turns: int = 0
	var errors: Array[String] = []

	func _init(path: String = "res://data/sim/roam.json", quiet: bool = false) -> void:
		var r := Records.new(path, quiet)
		var d: Variant = r.read_json(path)
		if d is Dictionary:
			var dd: Dictionary = d
			hold_reach_factor = r.number(dd, "hold_reach_factor", "hold_reach_factor", 0.0)
			hold_margin_m = r.number(dd, "hold_margin_m", "hold_margin_m", 0.0)
			relocate_delay_turns = r.integer(dd, "relocate_delay_turns", "relocate_delay_turns", 0)
			settle_tolerance_m = r.number(dd, "settle_tolerance_m", "settle_tolerance_m", 0.0)
			min_leg_m = r.number(dd, "min_leg_m", "min_leg_m", 0.0)
			stuck_turns = r.integer(dd, "stuck_turns", "stuck_turns", 1)
			for key: Variant in dd:
				var k := str(key)
				if not k.begins_with("_") and not ["hold_reach_factor", "hold_margin_m", "relocate_delay_turns", "settle_tolerance_m", "min_leg_m", "stuck_turns"].has(k):
					r.err("unknown field '%s' (misspelt?)" % k)
		errors = r.errors

	func ok() -> bool:
		return errors.is_empty()

static var _rules: Rules = null

static func rules() -> Rules:
	if _rules == null:
		_rules = Rules.new()
	return _rules

# --- Orders ----------------------------------------------------------------------------------------------

# Check the orders `spec` of unit `id` and fill `orders` (the pilot's normalised orders); returns "" or what is wrong with them.
# `pilot` is the AiPilot (its world, drive, warnings are used).
static func take(pilot: Object, id: String, spec: Dictionary, orders: Dictionary) -> String:
	var w: World = pilot.world
	var u: Unit = w.units[id]
	if u.def.domain != "ground" or u.def.is_static():
		return "a %s does not roam (domain %s, %s): the roam role is for mobile ground units" % [u.type, u.def.domain, u.def.mobility]
	var rl := rules()
	if not rl.ok():
		return "data/sim/roam.json does not load: %s" % str(rl.errors)
	if not spec.has("route") or not (spec["route"] is Array) or (spec["route"] as Array).size() < 2:
		return "a roam needs a 'route' of two or more hide points [x, y]"
	var hide: Array = []
	for pt: Variant in (spec["route"] as Array):
		var q: Array = AiDrive._point(pt)
		if q.is_empty():
			return "hide point %s is not [x, y] of finite numbers" % str(pt)
		hide.append(q)
	orders["route"] = hide
	orders["to"] = []
	orders["start_turn"] = 1
	var near := _nearest(hide, u.x, u.y)
	if _d(u.x, u.y, float((hide[near] as Array)[0]), float((hide[near] as Array)[1])) > rl.settle_tolerance_m:
		pilot.warnings.append("assignment '%s': the gun stands %.0f m from its nearest hide point (more than %.0f m): is it placed on one?" % [id, _d(u.x, u.y, float((hide[near] as Array)[0]), float((hide[near] as Array)[1])), rl.settle_tolerance_m])
	return ""

# --- Planning ----------------------------------------------------------------------------------------------

# Plan the unit's turn. `a` its orders, `m` its memory (state, since ...; "point": the hide point it stands at or left, "dest": the
# one it drives to, "settled": the turn it settled, "stuck": turns without progress, "s": the drive's progress), changed in place.
static func plan(pilot: Object, id: String, a: Dictionary, m: Dictionary) -> void:
	var w: World = pilot.world
	var u: Unit = w.units[id]
	var rl := rules()
	var hide: Array = a["route"]
	var enter: Callable = Callable(pilot, "_enter")
	if not m.has("point"):
		m["point"] = _nearest(hide, u.x, u.y)
		m["dest"] = -1
		m["settled"] = w.turn
		m["stuck"] = 0
		m["state"] = S_HIDE      # (not a transition: where the unit starts)
		m["reason"] = R_START
		m["since"] = w.turn
	var state := str(m["state"])
	if state == AiDrive.S_ARRIVED:
		m["point"] = int(m["dest"])
		m["dest"] = -1
		m["settled"] = w.turn
		m["stuck"] = 0
		enter.call(id, m, S_HIDE, R_SETTLED, "reached hide point %d" % int(m["point"]))
		state = S_HIDE
	if state != S_HIDE and state != S_FIRE and state != AiDrive.S_DRIVE:
		enter.call(id, m, S_HIDE, R_START, "hides at its start")
		state = S_HIDE

	var planes := _planes_in_reach(pilot, u)
	if not planes.is_empty():
		if state == AiDrive.S_DRIVE:
			m["dest"] = -1      # the leg is dropped; it is due again when the planes are gone
		if state != S_FIRE:
			enter.call(id, m, S_FIRE, R_PLANES, "%s is within reach" % str(planes[0]["id"]))
		pilot.steer.fly(id, _hold())
		return
	if state == S_FIRE:
		enter.call(id, m, S_HIDE, R_CLEAR, "no plane in reach")
		state = S_HIDE

	if state == AiDrive.S_DRIVE:
		_drive_on(pilot, id, a, m, rl)
		return

	# hide: due to relocate?
	var last: int = RevealRules.of(w).last_fire_turn(id)
	if last >= int(m["settled"]) and w.turn - last >= rl.relocate_delay_turns:
		var dest := _next_point(hide, int(m["point"]), u, rl.min_leg_m)
		if dest >= 0:
			var scratch := {}
			var why: String = pilot.drive.take(id, {"route": [hide[dest]]}, scratch)
			if why == "":
				m["dest"] = dest
				m["s"] = 0.0
				m["stuck"] = 0
				enter.call(id, m, AiDrive.S_DRIVE, R_FIRED, "fired in turn %d: drives to hide point %d" % [last, dest])
				_drive_on(pilot, id, a, m, rl)
				return
	pilot.steer.fly(id, _hold())

# One turn of a leg: the drive role's pursuit, and the guard against a leg that goes nowhere.
static func _drive_on(pilot: Object, id: String, a: Dictionary, m: Dictionary, rl: Rules) -> void:
	var before := float(m.get("s", 0.0))
	pilot.drive.plan(id, a, m)
	if str(m["state"]) == AiDrive.S_ARRIVED:
		return
	if float(m.get("s", 0.0)) - before < 1.0:
		m["stuck"] = int(m.get("stuck", 0)) + 1
		if int(m["stuck"]) >= rl.stuck_turns:
			var enter: Callable = Callable(pilot, "_enter")
			m["dest"] = -1
			m["settled"] = pilot.world.turn
			enter.call(id, m, S_HIDE, R_STUCK, "no progress for %d turns: hides where it stands" % int(m["stuck"]))
			m["stuck"] = 0
	else:
		m["stuck"] = 0

# --- Helpers -------------------------------------------------------------------------------------------------

# The farthest any weapon of the unit's type reaches, metres (effective range x (1 + the range overshoot)).
static func reach_m(w: World, u: Unit) -> float:
	var best := 0.0
	for wp in u.def.weapons:
		best = maxf(best, wp.max_range_m(w.combat.range_overshoot))
	return best

# The known enemy aircraft the AI's units have in sight this turn that are within the gun's reach plus its margin, nearest first.
static func _planes_in_reach(pilot: Object, u: Unit) -> Array:
	var w: World = pilot.world
	var rl := rules()
	var radius := reach_m(w, u) * rl.hold_reach_factor + rl.hold_margin_m
	var out: Array = []
	for e: Dictionary in pilot.sense.visible_enemies():
		var def: Variant = w.unit_def(str(e["type"]))
		if def == null or (def as Object).get("domain") != "air":
			continue
		# the SLANT distance: a plane's height counts (the gun's cone is aimed up; a mobile AA that reaches 384 m does not reach a plane
		# at 400 m however near it is, but a plane about to dive is near enough to be held for)
		var gd := _d(u.x, u.y, float(e["x"]), float(e["y"]))
		var dz := w.band_height(str(e["altitude_band"]))
		var d := sqrt(gd * gd + dz * dz) if is_finite(dz) else gd
		if d <= radius:
			var rec := e.duplicate()
			rec["dist"] = d
			out.append(rec)
	out.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		if float(p["dist"]) != float(q["dist"]):
			return float(p["dist"]) < float(q["dist"])
		return str(p["id"]) < str(q["id"]))
	return out

# The next hide point after `from` in list order that is at least `min_leg` from the unit; -1 if none.
static func _next_point(hide: Array, from: int, u: Unit, min_leg: float) -> int:
	for k in range(1, hide.size() + 1):
		var i := (from + k) % hide.size()
		var p: Array = hide[i]
		if _d(u.x, u.y, float(p[0]), float(p[1])) >= min_leg:
			return i
	return -1

static func _nearest(hide: Array, x: float, y: float) -> int:
	var best := 0
	var best_d := INF
	for i in hide.size():
		var d := _d(x, y, float((hide[i] as Array)[0]), float((hide[i] as Array)[1]))
		if d < best_d:
			best_d = d
			best = i
	return best

static func _hold() -> Callable:
	return func(_i: int, _at: Dictionary, _t: float) -> Dictionary:
		return {"turn": 0.0, "speed": 0.0}

static func _d(ax: float, ay: float, bx: float, by: float) -> float:
	return sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
