extends RefCounted

# THE ENEMY AI (execution plan component 14; Track E, proposed, 2026-10-09).
# Replaces ai_dumb.gd for the first fight (the sandbox still uses ai_dumb).
# Design doc, Enemy AI: enemies have mission goals and pursue them, take
# secondary opportunities, and are built from STATES and CRITERIA -- patrol,
# engage when an enemy is spotted, disengage when disengagement criteria are
# met. Enemy units use the same rules as player units: this class plans ONLY
# through the World's public API (plan_step, clear_plan, reachable, step_dt,
# sample of its OWN units' plans, commit), so it cannot do what a player could
# not, and it readies itself (World.AI_PLAYER) when its plans are in.
#
#   var ai := AiPilot.new()                       # reads data/sim/ai.json
#   ai.attach(world, {
#       "bomber_1":  {"role": "strike", "route": [[2200, 1100], [3300, 2300]],
#                     "target": [3800, 4000]},
#       "escort_1":  {"role": "escort", "protect": "bomber_1"},
#   })                                            # plans now if the world is
#                                                 # planning, and every turn after
#   ai.ok(); ai.errors; ai.warnings               # a bad assignment is reported here
#
# ASSIGNMENTS: attach(world, assignments) maps a unit id (an AI-CONTROLLED
# unit) to its orders:
#   {"role": "strike", "route": [[x, y], ...], "target": [x, y], "band": id}
#       Fly the waypoints in order, then the target, holding a band ("band":
#       default the band the unit is in when attached). Needs a route or a
#       target; the route ends at the target (it is appended if the route stops
#       short; with no target the last waypoint is the target). Never chases.
#   {"role": "escort", "protect": unit id}
#       Hold a station beside that unit (another AI-controlled unit), engage,
#       break off, return. The protected unit is planned first.
# An AI-controlled unit with NO assignment flies straight and keeps off the
# map edge (role "idle"); a down unit is not planned.
#
# STATES (per unit; the numbers behind every criterion are in data/sim/ai.json,
# all proposed):
#   strike  route    fly to the next waypoint at cruise, hold the band
#           evade    alarmed -- a known enemy within threat_radius_m of the
#                    bomber, or its own health fell since last turn: weave
#                    (heading swings +-weave_amplitude_deg of the route bearing,
#                    switching side every weave_half_period_steps steps) and move
#                    to the band whose height is farthest from the nearest
#                    threat, at most evade_max_band_offset bands from the one it
#                    holds; back to `route` evade_turns turns after the last sign
#           arrived  the last waypoint (the target) is reached: circle it
#   escort  station  hold the station point beside the protected unit
#           engage   an enemy was seen within engage_radius_protect_m of the
#                    protected unit or engage_radius_self_m of the escort (and the
#                    escort is not wounded): steer to bring it into the forward
#                    weapon's cone -- LEAD PURSUIT on the target's current
#                    position and velocity, assuming it flies straight, and match
#                    its altitude band. Breaks off to `return` when health falls
#                    below break_off_health_fraction, when more than leash_m from
#                    the protected unit, after no_chance_turns engaged turns in a
#                    row whose plan never brings the target into the cone, or when
#                    the target is gone (down, or forgotten) and no other qualifies
#           return   fly back to the station, ignoring enemies; `station` again
#                    within station_tolerance_m of it
#           free     the protected unit is down: hunt the nearest known enemy,
#                    no leash, no break-off (proposed; nothing in the first fight
#                    depends on it), else fly straight
#   idle    idle     straight on at the current speed
# Every state is edge-safe: if a plan would run the unit at the map edge (inside
# edge_margin_turn_radii turn radii and closing on it), it turns to the centre
# instead, as ai_dumb does (the unit's `edge` flag in info() says so).
#
# WHAT THE AI KNOWS (ai_sense.gd): a player's unit while inside sight_range_m of
# any living AI unit; else the last seen state for memory_turns; else nothing.
# It reads only public state (position, heading, speed, band, type, side,
# down). NEVER a player unit's plan, planned_states, reachable or sample.
# The one thing it does read of a plan is its OWN units' (an escort flies its
# station against where its protected unit WILL be, which the AI itself planned).
#
# HOST ONLY: in a networked game only the host's World plans the AI and resolves
# (Alex: the host resolves each turn); a client applies the host's result and must
# not attach an AiPilot, or its World would plan and ready up the AI itself. The AI's
# plans are in the World like any unit's (Unit.plan, planned_states): an interface
# or a sync layer must not show or send them to players (Alex: players never learn
# the enemy's plans).
#
# Planning a turn twice in the same turn gives the same plans: per-unit memory is
# snapshotted when the turn's first plan starts and restored for a re-plan.
# Deterministic: no randomness, ids iterate in the order units were added.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const JsMath = preload("res://scripts/core/js_math.gd")
const AiParams = preload("res://scripts/sim/ai_params.gd")
const AiSense = preload("res://scripts/sim/ai_sense.gd")
const AiSteer = preload("res://scripts/sim/ai_steer.gd")
const AiCone = preload("res://scripts/sim/ai_cone.gd")

const ROLE_STRIKE := "strike"
const ROLE_ESCORT := "escort"
const ROLE_IDLE := "idle"

const S_ROUTE := "route"
const S_EVADE := "evade"
const S_ARRIVED := "arrived"
const S_STATION := "station"
const S_ENGAGE := "engage"
const S_RETURN := "return"
const S_FREE := "free"
const S_IDLE := "idle"

# Transition reason codes (a transition also carries a `detail` sentence).
const R_ENEMY := "enemy_in_radius"
const R_HEALTH := "health"
const R_LEASH := "leash"
const R_NO_CHANCE := "no_chance"
const R_TARGET_GONE := "target_gone"
const R_ON_STATION := "on_station"
const R_PROTECTED_DOWN := "protected_down"
const R_THREAT := "threat"
const R_HIT := "hit"
const R_CALM := "calm"
const R_ROUTE_END := "route_end"

var world: World = null
var params: AiParams = null
var sense: AiSense = AiSense.new()
var steer: AiSteer = null
var assignments: Dictionary = {}       # unit id -> normalised orders
var errors: Array[String] = []         # data or assignment problems; see ok()
var warnings: Array[String] = []       # e.g. a waypoint inside the edge margin
var transitions: Array = []            # {turn, unit, from, to, reason, detail}, in order
var quiet: bool = false

var _mem: Dictionary = {}              # unit id -> memory after its latest plan
var _mem_start: Dictionary = {}        # unit id -> {turn, mem}: memory as the turn began
var _cones: Dictionary = {}            # unit type -> forward cone

func _init(data_path: String = AiParams.DATA_PATH, quiet_errors: bool = false) -> void:
	quiet = quiet_errors
	params = AiParams.new(data_path, quiet_errors)
	errors.append_array(params.errors)

func ok() -> bool:
	return errors.is_empty()

# --- Attaching -----------------------------------------------------------------

# Take command of the assigned units of `target`. Plans now if the world is in
# its planning phase, and again at the start of every planning phase. Returns
# ok(): false if the data did not load (nothing is attached) or an assignment
# was refused (the rest still fly).
func attach(target: World, assigned: Dictionary) -> bool:
	detach()
	world = target
	if not params.ok():
		return false
	steer = AiSteer.new(world, params.num("common", "edge_margin_turn_radii"))
	sense = AiSense.new()
	assignments.clear()
	_mem.clear()
	_mem_start.clear()
	transitions.clear()
	for key: Variant in assigned:
		assign(str(key), assigned[key])
	world.phase_changed.connect(_on_phase_changed)
	if world.phase == World.PHASE_PLANNING:
		plan_turn()
	return ok()

func detach() -> void:
	if world != null and world.phase_changed.is_connected(_on_phase_changed):
		world.phase_changed.disconnect(_on_phase_changed)

# Give one unit orders (or replace them). Returns whether they were accepted.
func assign(id: String, spec: Variant) -> bool:
	var label := "assignment '%s'" % id
	if not world.units.has(id):
		return _refuse("%s: no such unit" % label)
	var u: Unit = world.units[id]
	if u.controller != World.CONTROLLER_AI:
		return _refuse("%s: not AI-controlled (the AI does not command a player's unit)" % label)
	if not (spec is Dictionary):
		return _refuse("%s: orders are a Dictionary" % label)
	var s: Dictionary = spec
	var role := str(s.get("role", ""))
	var orders := {"role": role, "route": [], "target": [], "protect": "", "band": u.altitude_band}
	if s.has("band"):
		var band := str(s["band"])
		if not u.def.envelope.bands.has(band):
			return _refuse("%s: a %s cannot hold band '%s'" % [label, u.type, band])
		orders["band"] = band
	match role:
		ROLE_STRIKE:
			var route: Array = []
			if s.has("route"):
				if not (s["route"] is Array):
					return _refuse("%s: 'route' is a list of [x, y] points" % label)
				for pt: Variant in (s["route"] as Array):
					var q := _point(pt)
					if q.is_empty():
						return _refuse("%s: route point %s is not [x, y] of finite numbers" % [label, str(pt)])
					route.append(q)
			var tgt: Array = []
			if s.has("target"):
				tgt = _point(s["target"])
				if tgt.is_empty():
					return _refuse("%s: 'target' is not [x, y] of finite numbers" % label)
			if tgt.is_empty():
				if route.is_empty():
					return _refuse("%s: a strike needs a route or a target" % label)
				tgt = route[route.size() - 1]
			if route.is_empty() or _d(float((route[route.size() - 1] as Array)[0]), float((route[route.size() - 1] as Array)[1]), float(tgt[0]), float(tgt[1])) > 1.0:
				route.append(tgt)
			orders["route"] = route
			orders["target"] = tgt
			_warn_edge(label, u, route)
		ROLE_ESCORT:
			var prot := str(s.get("protect", ""))
			if prot == "" or not world.units.has(prot):
				return _refuse("%s: 'protect' must name a unit (got '%s')" % [label, prot])
			if prot == id:
				return _refuse("%s: a unit cannot protect itself" % label)
			if (world.units[prot] as Unit).controller != World.CONTROLLER_AI:
				return _refuse("%s: cannot protect '%s': it is not AI-controlled (the AI never reads a player's plan)" % [label, prot])
			orders["protect"] = prot
		_:
			return _refuse("%s: role '%s' is not '%s' or '%s'" % [label, role, ROLE_STRIKE, ROLE_ESCORT])
	assignments[id] = orders
	_mem.erase(id)
	_mem_start.erase(id)
	return true

func _on_phase_changed(phase: String) -> void:
	if phase == World.PHASE_PLANNING:
		plan_turn()

# --- Planning ------------------------------------------------------------------

# Plan every AI unit for the current turn (protected units before the escorts
# that fly against their plans), then ready up. Safe to call again in the same
# turn: it re-plans to the same result.
func plan_turn() -> void:
	if world == null or steer == null or world.phase != World.PHASE_PLANNING:
		return
	var ai_ids: Array[String] = []
	for id: String in world.units:
		if (world.units[id] as Unit).controller == World.CONTROLLER_AI:
			ai_ids.append(id)
	if ai_ids.is_empty():
		return
	sense.update(world, params.whole("knowledge", "memory_turns"))
	var turn_no := world.turn
	transitions = transitions.filter(func(t: Dictionary) -> bool: return int(t["turn"]) != turn_no)
	var planned := {}
	var pending: Array[String] = ai_ids.duplicate()
	while not pending.is_empty():
		var progressed := false
		for id: String in pending.duplicate():
			var dep := str((assignments.get(id, {}) as Dictionary).get("protect", ""))
			if dep == "" or planned.has(dep) or not ai_ids.has(dep):
				_plan_unit(id)
				planned[id] = true
				pending.erase(id)
				progressed = true
		if not progressed:
			# A protection cycle: plan the rest in order anyway.
			for id: String in pending:
				_plan_unit(id)
			break
	world.commit(World.AI_PLAYER)

func _plan_unit(id: String) -> void:
	var u: Unit = world.units[id]
	if u.down:
		return
	var a: Dictionary = assignments.get(id, {"role": ROLE_IDLE})
	var m := _begin_memory(id, a)
	match str(a["role"]):
		ROLE_STRIKE:
			_plan_strike(id, a, m)
		ROLE_ESCORT:
			_plan_escort(id, a, m)
		_:
			_plan_idle(id, m)
	_mem[id] = m

# The unit's memory as this turn began (so a second plan in the same turn starts
# from the same place), as a working copy.
func _begin_memory(id: String, a: Dictionary) -> Dictionary:
	var start: Dictionary = _mem_start.get(id, {})
	if int(start.get("turn", -1)) != world.turn:
		var mem: Dictionary = (_mem[id] as Dictionary).duplicate(true) if _mem.has(id) else _fresh_memory(id, a)
		start = {"turn": world.turn, "mem": mem}
		_mem_start[id] = start
	return (start["mem"] as Dictionary).duplicate(true)

func _fresh_memory(id: String, a: Dictionary) -> Dictionary:
	var u: Unit = world.units[id]
	var state := S_IDLE
	if str(a["role"]) == ROLE_STRIKE:
		state = S_ROUTE
	elif str(a["role"]) == ROLE_ESCORT:
		state = S_STATION
	return {
		"state": state, "reason": "", "detail": "", "since": world.turn,
		"target": "", "wp": 0, "no_chance": 0, "chance": false, "alarm": 0,
		"health": u.health, "edge": false,
	}

func _enter(id: String, m: Dictionary, new_state: String, code: String, detail: String) -> void:
	var old := str(m["state"])
	if old == new_state:
		return
	m["state"] = new_state
	m["reason"] = code
	m["detail"] = detail
	m["since"] = world.turn
	transitions.append({"turn": world.turn, "unit": id, "from": old, "to": new_state, "reason": code, "detail": detail})

# --- Idle ----------------------------------------------------------------------

func _plan_idle(id: String, m: Dictionary) -> void:
	var u: Unit = world.units[id]
	var speed := u.speed
	var ctrl := func(_i: int, _at: Dictionary, _t: float) -> Dictionary:
		return {"turn": 0.0, "speed": speed}
	m["edge"] = steer.fly_safe(id, ctrl)["edge"]

# --- Strike --------------------------------------------------------------------

func _plan_strike(id: String, a: Dictionary, m: Dictionary) -> void:
	var p := params
	var u: Unit = world.units[id]
	var route: Array = a["route"]
	var cap := p.num("strike", "capture_radius_m")
	var env := u.def.envelope
	var speed := env.speed_cruise * p.num("strike", "speed_fraction_of_cruise")
	var hold := str(a["band"])
	var n := world.steps_per_turn(id)
	var dt := world.step_dt(id)

	# The alarm: a known enemy close, or hurt since last turn.
	var threat := _nearest_visible(u.x, u.y)
	var near_threat := {}
	if not threat.is_empty() and _d(u.x, u.y, float(threat["x"]), float(threat["y"])) <= p.num("strike", "threat_radius_m"):
		near_threat = threat
	var hurt := u.health < int(m["health"])
	m["health"] = u.health
	if not near_threat.is_empty() or hurt:
		m["alarm"] = p.whole("strike", "evade_turns")
	else:
		m["alarm"] = maxi(0, int(m["alarm"]) - 1)

	var wp := int(m["wp"])
	while wp < route.size() and _near(u.x, u.y, route[wp], cap):
		wp += 1
	var arrived := wp >= route.size()
	var evading := not arrived and int(m["alarm"]) > 0
	if arrived:
		_enter(id, m, S_ARRIVED, R_ROUTE_END, "reached the target point")
	elif evading:
		var why := "%s is within %.0f m" % [near_threat["id"], p.num("strike", "threat_radius_m")] if not near_threat.is_empty() else "hit"
		_enter(id, m, S_EVADE, R_THREAT if not near_threat.is_empty() else R_HIT, why)
	else:
		_enter(id, m, S_ROUTE, R_CALM, "no alarm")

	var band_goal := hold
	if evading and p.flag("strike", "evade_changes_band") and not near_threat.is_empty():
		band_goal = _band_away(u, world.band_height(str(near_threat["altitude_band"])), hold)
	var amp := deg_to_rad(p.num("strike", "weave_amplitude_deg")) if evading else 0.0
	var half_period := p.num("strike", "weave_half_period_steps")
	var base_step := (world.turn - 1) * n
	var orbit := p.num("strike", "orbit_turn_fraction")
	var wp_box: Array = [wp]

	var ctrl := func(i: int, at: Dictionary, _t: float) -> Dictionary:
		var w: int = wp_box[0]
		while w < route.size() and _near(float(at["x"]), float(at["y"]), route[w], cap):
			w += 1
		wp_box[0] = w
		if w >= route.size():
			return {"turn": orbit * env.turn_rate(float(at["speed"])) * dt, "speed": speed, "band": hold}
		var wx := float((route[w] as Array)[0])
		var wy := float((route[w] as Array)[1])
		var sgn := 1.0 if int(floorf(float(base_step + i) / half_period)) % 2 == 0 else -1.0
		return {
			"aim": func(s: Dictionary) -> float: return JsMath.atan2(wy - float(s["y"]), wx - float(s["x"])) + sgn * amp,
			"speed": speed,
			"band": band_goal,
		}

	var r := steer.fly_safe(id, ctrl)
	m["edge"] = r["edge"]
	if r["edge"]:
		m["wp"] = wp
		return
	var states: Array = r["states"]
	var w2: int = wp_box[0]
	if not states.is_empty():
		var last: Dictionary = states[states.size() - 1]
		while w2 < route.size() and _near(float(last["x"]), float(last["y"]), route[w2], cap):
			w2 += 1
	m["wp"] = w2
	if w2 >= route.size():
		_enter(id, m, S_ARRIVED, R_ROUTE_END, "reached the target point")

# The band, within evade_max_band_offset bands of the one it holds, whose height
# is farthest from `threat_z` (ties: the band it holds).
func _band_away(u: Unit, threat_z: float, hold: String) -> String:
	var bands: Array[String] = u.def.envelope.bands
	var hold_i := bands.find(hold)
	var reach := params.whole("strike", "evade_max_band_offset")
	var best := hold
	var best_sep := absf(world.band_height(hold) - threat_z)
	for i in bands.size():
		if hold_i >= 0 and absi(i - hold_i) > reach:
			continue
		var sep := absf(world.band_height(bands[i]) - threat_z)
		if sep > best_sep + 1e-9:
			best = bands[i]
			best_sep = sep
	return best

# --- Escort --------------------------------------------------------------------

func _plan_escort(id: String, a: Dictionary, m: Dictionary) -> void:
	var p := params
	var u: Unit = world.units[id]
	var prot_id := str(a["protect"])
	var prot: Unit = world.units.get(prot_id)
	var prot_alive := prot != null and not prot.down
	var cone := _cone_for(u)
	var can_fight := AiCone.usable(cone)
	var enemies := sense.visible_enemies()
	var wounded := float(u.health) < p.num("escort", "break_off_health_fraction") * float(u.def.health)

	if not prot_alive and str(m["state"]) != S_FREE:
		_enter(id, m, S_FREE, R_PROTECTED_DOWN, "%s is down" % prot_id)
		m["target"] = ""
	var state := str(m["state"])

	if state == S_STATION:
		if can_fight and not wounded:
			var t := _pick_target(enemies, u, prot)
			if not t.is_empty():
				m["target"] = str(t["id"])
				m["no_chance"] = 0
				_enter(id, m, S_ENGAGE, R_ENEMY, "%s is within the engage radius" % t["id"])
	elif state == S_ENGAGE:
		var why := _break_off(u, prot, m, wounded)
		if not why.is_empty():
			m["target"] = ""
			_enter(id, m, S_RETURN, str(why["code"]), str(why["detail"]))
		elif sense.entry(str(m["target"])).is_empty():
			var t2 := _pick_target(enemies, u, prot)
			if not t2.is_empty():
				m["target"] = str(t2["id"])
				m["no_chance"] = 0
			else:
				m["target"] = ""
				_enter(id, m, S_RETURN, R_TARGET_GONE, "the target is down or forgotten and no other enemy qualifies")
	elif state == S_RETURN:
		if prot_alive and _station_distance(u, prot) <= p.num("escort", "station_tolerance_m"):
			m["no_chance"] = 0
			_enter(id, m, S_STATION, R_ON_STATION, "within %.0f m of the station" % p.num("escort", "station_tolerance_m"))
	elif state == S_FREE:
		var nearest := _nearest_known(u.x, u.y)
		m["target"] = "" if nearest.is_empty() else str(nearest["id"])
	state = str(m["state"])

	var target := {}
	if state == S_ENGAGE or state == S_FREE:
		target = sense.entry(str(m["target"]))
	var ctrl: Callable
	if not target.is_empty() and can_fight:
		ctrl = _engage_ctrl(id, target, cone)
	elif prot_alive and state != S_FREE:
		ctrl = _station_ctrl(id, prot_id)
	else:
		var speed := u.speed
		ctrl = func(_i: int, _at: Dictionary, _t: float) -> Dictionary:
			return {"turn": 0.0, "speed": speed}

	var r := steer.fly_safe(id, ctrl)
	m["edge"] = r["edge"]
	if not target.is_empty() and can_fight:
		var chance := _has_chance(id, r["states"], target, cone)
		m["chance"] = chance
		m["no_chance"] = 0 if chance else int(m["no_chance"]) + 1
	else:
		m["chance"] = false

# {code, detail} if a break-off criterion holds, else {}.
func _break_off(u: Unit, prot: Unit, m: Dictionary, wounded: bool) -> Dictionary:
	var p := params
	if wounded:
		return {"code": R_HEALTH, "detail": "health %d of %d is below the break-off fraction %.2f" % [u.health, u.def.health, p.num("escort", "break_off_health_fraction")]}
	if prot != null and not prot.down:
		var d := _d(u.x, u.y, prot.x, prot.y)
		if d > p.num("escort", "leash_m"):
			return {"code": R_LEASH, "detail": "%.0f m from the protected unit, leash %.0f m" % [d, p.num("escort", "leash_m")]}
	if int(m["no_chance"]) >= p.whole("escort", "no_chance_turns"):
		return {"code": R_NO_CHANCE, "detail": "no firing chance for %d turns" % int(m["no_chance"])}
	return {}

# The visible enemy to engage from the station: one within engage_radius_protect_m
# of the protected unit or engage_radius_self_m of the escort, the nearest to the
# protected unit (to the escort when there is none). PROPOSED placeholder -- not
# a target-priority scheme, which is not designed yet (Alex, 2026-10-09).
func _pick_target(enemies: Array[Dictionary], u: Unit, prot: Unit) -> Dictionary:
	var prot_alive := prot != null and not prot.down
	var r_prot := params.num("escort", "engage_radius_protect_m")
	var r_self := params.num("escort", "engage_radius_self_m")
	var best := {}
	var best_d := INF
	for e: Dictionary in enemies:
		var ex := float(e["x"])
		var ey := float(e["y"])
		var ds := _d(u.x, u.y, ex, ey)
		var dp := _d(prot.x, prot.y, ex, ey) if prot_alive else INF
		if dp <= r_prot or ds <= r_self:
			var key := dp if prot_alive else ds
			if key < best_d:
				best = e
				best_d = key
	return best

func _station_distance(u: Unit, prot: Unit) -> float:
	var s := _station_point(prot.state())
	return _d(u.x, u.y, s[0], s[1])

# The station point for a protected unit in `b` (x, y, heading): forward and
# right of it in its own frame.
func _station_point(b: Dictionary) -> Array:
	var fwd := params.num("escort", "station_forward_m")
	var rgt := params.num("escort", "station_right_m")
	var h := float(b["heading"])
	var c := JsMath.cos(h)
	var s := JsMath.sin(h)
	return [float(b["x"]) + c * fwd - s * rgt, float(b["y"]) + s * fwd + c * rgt]

# Where an OWN unit is `t` seconds into this turn on its plan. Refuses any unit
# that is not AI-controlled: a player's plan is not the AI's to read.
func _own_state(id: String, t: float) -> Dictionary:
	var u: Unit = world.units[id]
	if u.controller != World.CONTROLLER_AI:
		return u.state()
	var s := world.sample(id, t, "plan")
	return s if not s.is_empty() else u.state()

func _station_ctrl(id: String, prot_id: String) -> Callable:
	var p := params
	var align := p.num("escort", "align_range_m")
	var catchup := p.num("escort", "catchup_time_s")
	var dt := world.step_dt(id)
	return func(_i: int, at: Dictionary, t_end: float) -> Dictionary:
		var b0 := _own_state(prot_id, t_end - dt)
		var b1 := _own_state(prot_id, t_end)
		var s0 := _station_point(b0)
		var s1 := _station_point(b1)
		var h0 := float(b0["heading"])
		var h1 := float(b1["heading"])
		# Speed: the protected unit's, plus what closes the gap along its track.
		var along := (float(s0[0]) - float(at["x"])) * JsMath.cos(h0) + (float(s0[1]) - float(at["y"])) * JsMath.sin(h0)
		var speed := float(b0["speed"]) + along / catchup
		var aim := func(s: Dictionary) -> float:
			var dx := float(s1[0]) - float(s["x"])
			var dy := float(s1[1]) - float(s["y"])
			var d := sqrt(dx * dx + dy * dy)
			var w := clampf(d / align, 0.0, 1.0)
			var ux := JsMath.cos(h1) * (1.0 - w)
			var uy := JsMath.sin(h1) * (1.0 - w)
			if d > 1e-6:
				ux += dx / d * w
				uy += dy / d * w
			return JsMath.atan2(uy, ux)
		return {"aim": aim, "speed": speed, "band": str(b1["altitude_band"])}

# Lead pursuit on a known target: the target is assumed to keep flying straight
# at its seen speed (a target out of sight is taken to be where it was last
# seen, standing still); each step aims the nose at where the target will be when
# the step ends, from where the step really ends.
func _engage_ctrl(id: String, e: Dictionary, cone: Dictionary) -> Callable:
	var p := params
	var u: Unit = world.units[id]
	var dt := world.step_dt(id)
	var desired := p.num("escort", "engage_range_fraction") * float(cone["range_m"])
	var catchup := p.num("escort", "catchup_time_s")
	var tp := _predict(e)
	var tband := str(e["altitude_band"])
	var match_band := p.flag("escort", "match_band") and u.def.envelope.bands.has(tband)
	return func(_i: int, at: Dictionary, t_end: float) -> Dictionary:
		var then := _target_at(tp, t_end - dt)
		var gap := _d(float(at["x"]), float(at["y"]), float(then[0]), float(then[1]))
		var speed := float(tp["speed"]) + (gap - desired) / catchup
		var ahead := _target_at(tp, t_end)
		var out := {
			"aim": func(s: Dictionary) -> float: return JsMath.atan2(float(ahead[1]) - float(s["y"]), float(ahead[0]) - float(s["x"])),
			"speed": speed,
		}
		if match_band:
			out["band"] = tband
		return out

# Did the planned turn bring the predicted target inside the forward cone at the
# end of some step? (This is the AI's own estimate of a firing chance: the real
# one is the firing rules' (Track C), which the AI does not run. Only a target in
# sight this turn can give one.)
func _has_chance(id: String, states: Array, e: Dictionary, cone: Dictionary) -> bool:
	# A contact out of sight is a guess at where it was: not a chance.
	if e.get("visible", false) != true:
		return false
	var dt := world.step_dt(id)
	var tp := _predict(e)
	var tz := world.band_height(str(e["altitude_band"]))
	for i in states.size():
		var s: Dictionary = states[i]
		var at := _target_at(tp, dt * float(i + 1))
		if AiCone.contains(cone, float(s["x"]), float(s["y"]), float(s["heading"]), world.band_height(str(s["altitude_band"])), float(at[0]), float(at[1]), tz):
			return true
	return false

# A known target's straight-line model: where it was seen, and (only if it is
# in sight this turn) the velocity it was seen with.
func _predict(e: Dictionary) -> Dictionary:
	var visible: bool = e.get("visible", false) == true
	var v := float(e["speed"]) if visible else 0.0
	var h := float(e["heading"])
	return {"x": float(e["x"]), "y": float(e["y"]), "vx": JsMath.cos(h) * v, "vy": JsMath.sin(h) * v, "speed": v}

func _target_at(tp: Dictionary, t: float) -> Array:
	return [float(tp["x"]) + float(tp["vx"]) * t, float(tp["y"]) + float(tp["vy"]) * t]

func _cone_for(u: Unit) -> Dictionary:
	if not _cones.has(u.type):
		_cones[u.type] = AiCone.forward_cone(u.def, u.type, params)
	return _cones[u.type]

# --- Knowledge helpers ---------------------------------------------------------

func _nearest_visible(x: float, y: float) -> Dictionary:
	return _nearest_of(sense.visible_enemies(), x, y)

func _nearest_known(x: float, y: float) -> Dictionary:
	return _nearest_of(sense.known_enemies(), x, y)

func _nearest_of(list: Array[Dictionary], x: float, y: float) -> Dictionary:
	var best := {}
	var best_d := INF
	for e: Dictionary in list:
		var d := _d(x, y, float(e["x"]), float(e["y"]))
		if d < best_d:
			best = e
			best_d = d
	return best

# --- Inspection ----------------------------------------------------------------

# The unit's current state name ("route", "evade", "arrived", "station",
# "engage", "return", "free", "idle"), or "" if it has not been planned.
func state_of(id: String) -> String:
	var m: Variant = _mem.get(id)
	return str((m as Dictionary)["state"]) if m is Dictionary else ""

# {role, state, reason, detail, since, target, wp, no_chance, chance, alarm,
# edge, health}: what the unit is doing and why. For debugging and a later
# interface; it is the AI's own business, never a player's to see.
func info(id: String) -> Dictionary:
	var m: Variant = _mem.get(id)
	if not (m is Dictionary):
		return {}
	var out: Dictionary = (m as Dictionary).duplicate()
	out["role"] = str((assignments.get(id, {}) as Dictionary).get("role", ROLE_IDLE))
	return out

# The forward cone the unit steers by, with its "source" ("def" | "fallback" |
# "none"), or {} for a type nothing knows.
func cone_of(id: String) -> Dictionary:
	return _cone_for(world.units[id]).duplicate()

# Does the AI currently know this unit (seen now, or remembered)?
func knows(id: String) -> bool:
	return sense.knows(id)

# Is it in sight of the AI this turn?
func sees(id: String) -> bool:
	return sense.is_visible(id)

# --- Small helpers -------------------------------------------------------------

static func _d(ax: float, ay: float, bx: float, by: float) -> float:
	var dx := bx - ax
	var dy := by - ay
	return sqrt(dx * dx + dy * dy)

static func _near(x: float, y: float, pt: Variant, radius: float) -> bool:
	var q: Array = pt
	return _d(x, y, float(q[0]), float(q[1])) <= radius

# [x, y] floats from an Array or Vector2, or [] if it is neither.
static func _point(v: Variant) -> Array:
	if v is Vector2:
		return [float((v as Vector2).x), float((v as Vector2).y)]
	if v is Array and (v as Array).size() == 2 and ((v as Array)[0] is float or (v as Array)[0] is int) and ((v as Array)[1] is float or (v as Array)[1] is int):
		var x := float((v as Array)[0])
		var y := float((v as Array)[1])
		if is_finite(x) and is_finite(y):
			return [x, y]
	return []

func _refuse(message: String) -> bool:
	errors.append(message)
	if not quiet:
		push_error("AiPilot: " + message)
	return false

# A waypoint inside the edge margin is flown at only if the unit is moving
# inward; warn so a scenario does not put its target where the bomber's own
# safety turn would keep it from reaching.
func _warn_edge(label: String, u: Unit, route: Array) -> void:
	var cruise := u.def.envelope.speed_cruise
	var margin := params.num("common", "edge_margin_turn_radii") * u.def.envelope.turn_radius(cruise)
	if not is_finite(margin):
		return
	var b := world.bounds
	for pt: Array in route:
		var x := float(pt[0])
		var y := float(pt[1])
		var edge := minf(minf(x - b.position.x, b.end.x - x), minf(y - b.position.y, b.end.y - y))
		if edge < margin:
			warnings.append("%s: waypoint [%.0f, %.0f] is %.0f m from the map edge, inside the %.0f m margin; the unit may turn away before reaching it" % [label, x, y, edge, margin])
