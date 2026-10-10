extends RefCounted

# Walks one resolved turn at a fixed tick and rolls every weapon (Track C,
# proposed 2026-10-09; the model and the event shapes are in combat.gd's
# header). World.resolve() calls it AFTER motion: motion does not depend on
# combat, so the histories are already built and combat only samples them.
#
# It changes nothing itself. Given the units, the just-built histories and a
# sampler, it returns what happened and the World applies it:
#
#   var fight := CombatResolver.new(rules).run(units, histories, turn, rng_seed,
#       turn_seconds, sampler, band_height)
#   fight.events      the fire / hit / down events, t ascending
#   fight.health      unit id -> pips left at the end of the turn
#   fight.down_at     unit id -> seconds into the turn, ONLY for units that went
#                     down this turn
#   fight.fates       unit id -> {"fate", "spin"} (Combat.fate_roll), same units
#
# `sampler` is a Callable(unit_id: String, t: float) -> Dictionary: where the
# unit is t seconds in, on the arcs World.sample walks (x, y, heading, speed,
# height_m). `band_height` is a Callable(band: String) -> float. Callables
# rather than a World, so this file does not preload the World that preloads it.
#
# Units that are down at the start take no part: they do not fire and are not
# fired at. A unit that goes down mid-turn stops at the end of that tick. The
# order of everything is the order the units were added, so the same game
# draws the same rolls (combat.gd, THE SEED).

const Combat = preload("res://scripts/sim/combat.gd")
const CombatRules = preload("res://scripts/sim/combat_rules.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const Unit = preload("res://scripts/sim/unit.gd")

var rules: CombatRules

# One run's working state (reset by run()).
var _units: Dictionary = {}
var _ids: Array = []
var _index: Dictionary = {}     # unit id -> its position in World.units
var _health: Dictionary = {}
var _up: Dictionary = {}
var _down_at: Dictionary = {}
var _fates: Dictionary = {}
var _events: Array = []
var _turn: int = 0
var _seed: int = 0
var _params: Dictionary = {}    # CombatRules.factor_params()

func _init(combat_rules: CombatRules) -> void:
	rules = combat_rules

func run(units: Dictionary, histories: Dictionary, turn: int, rng_seed: int, turn_seconds: float, sampler: Callable, band_height: Callable) -> Dictionary:
	_units = units
	_ids = units.keys()
	_index = {}
	_health = {}
	_up = {}
	_down_at = {}
	_fates = {}
	_events = []
	_turn = turn
	_seed = rng_seed
	_params = rules.factor_params()
	for i in _ids.size():
		var id: String = _ids[i]
		var u: Unit = units[id]
		_index[id] = i
		_health[id] = u.health
		_up[id] = not u.down
	var n_ticks := maxi(1, roundi(turn_seconds / rules.tick_seconds))
	var t_prev := 0.0
	for tick in range(1, n_ticks + 1):
		var t := turn_seconds * float(tick) / float(n_ticks)
		# Who is up is fixed for the whole tick: shots are simultaneous.
		var active: Array[String] = []
		for id: String in _ids:
			if _up[id]:
				active.append(id)
		if _has_enemies(active):
			var states := {}
			for id: String in active:
				states[id] = _state_at(id, t, histories[id], sampler, band_height)
			for sid: String in active:
				var shooter: Unit = units[sid]
				var weapons: Array[CombatWeapon] = shooter.def.weapons
				for w_i in weapons.size():
					var weapon: CombatWeapon = weapons[w_i]
					var n_rolls := Combat.rolls_in_tick(weapon.rolls_per_second, t_prev, t)
					if n_rolls <= 0:
						continue
					for h_i in weapon.hardpoints.size():
						_fire_hardpoint(active, states, sid, w_i, weapon, h_i, n_rolls, tick, t)
		t_prev = t
	return {"events": _events, "health": _health, "down_at": _down_at, "fates": _fates}

# One hardpoint's rolls in one tick: pick the target (best odds among the enemy
# units in the cone), then roll n_rolls times at it.
func _fire_hardpoint(active: Array[String], states: Dictionary, sid: String, w_i: int, weapon: CombatWeapon, h_i: int, n_rolls: int, tick: int, t: float) -> void:
	var shooter: Unit = _units[sid]
	var p := Combat.pose(states[sid], weapon.hardpoints[h_i])
	var reach_m := Combat.reach(weapon, rules.odds_factors, _params)
	var range_sq := reach_m * reach_m
	var best_id := ""
	var best: Dictionary = {}
	for tid: String in active:
		var target: Unit = _units[tid]
		if target.side == shooter.side:
			continue
		var ts: Dictionary = states[tid]
		if Combat.distance_sq(p, ts) > range_sq:
			continue
		var g := Combat.evaluate_pose(p, weapon, ts, rules.odds_factors, _params)
		if not g["in_cone"]:
			continue
		# The target rule "best_odds" (the only one): the best odds, then the
		# nearer, then the unit added first (strict comparisons keep the first).
		if best_id == "" or float(g["odds"]) > float(best["odds"]) \
				or (float(g["odds"]) == float(best["odds"]) and float(g["distance"]) < float(best["distance"])):
			best_id = tid
			best = g
	if best_id == "":
		return
	var tstate: Dictionary = states[best_id]
	var odds := float(best["odds"])
	var rng := Mulberry32.new(Combat.roll_seed(_seed, _turn, int(_index[sid]), w_i, h_i, tick))
	for _j in n_rolls:
		var hit := rng.next() < odds
		_events.append({
			"type": "fire", "turn": _turn, "tick": tick, "unit": sid, "weapon": weapon.id,
			"hardpoint": h_i, "target": best_id, "t": t, "hit": hit, "odds": odds,
			"r": best["r"], "distance": best["distance"], "crossing_dps": best["crossing_dps"],
			"x": p["x"], "y": p["y"], "height_m": p["z"],
			"tx": tstate["x"], "ty": tstate["y"], "theight_m": tstate["height_m"],
		})
		if not hit:
			continue
		_health[best_id] = maxi(0, int(_health[best_id]) - weapon.damage_pips)
		_events.append({
			"type": "hit", "turn": _turn, "unit": best_id, "by": sid, "weapon": weapon.id,
			"t": t, "damage": weapon.damage_pips, "health": _health[best_id],
		})
		if int(_health[best_id]) == 0 and not _down_at.has(best_id):
			_down_at[best_id] = t
			_up[best_id] = false
			var fate := Combat.fate_roll(_seed, _turn, int(_index[best_id]), tick, rules.explode_chance)
			_fates[best_id] = fate
			_events.append({
				"type": "down", "turn": _turn, "unit": best_id, "by": sid, "t": t,
				"x": tstate["x"], "y": tstate["y"], "height_m": tstate["height_m"],
				"fate": fate["fate"],
			})

func _has_enemies(active: Array[String]) -> bool:
	if active.size() < 2:
		return false
	var side: String = (_units[active[0]] as Unit).side
	for id: String in active:
		if (_units[id] as Unit).side != side:
			return true
	return false

# A unit's state for combat at t: {x, y, heading, height_m, pitch, vx, vy, vz}. Position,
# heading and height are the World's sample; pitch is the airframe's tilt while
# the unit changes band (combat.gd, THE TILT): the angle of the path in the
# step that t falls in, from the heights of its two bands over its length, at
# the sample's speed, limited to +-max_pitch. The step is found the way
# World.sample finds it (a boundary belongs to the step that ends there).
func _state_at(id: String, t: float, path: Array, sampler: Callable, band_height: Callable) -> Dictionary:
	var s: Dictionary = sampler.call(id, t)
	var pitch := 0.0
	if rules.max_pitch > 0.0 and path.size() >= 2:
		var k := 0
		while k < path.size() - 2 and float(path[k + 1]["t"]) < t:
			k += 1
		var a: Dictionary = path[k]
		var b: Dictionary = path[k + 1]
		var dh := float(band_height.call(str(b["altitude_band"]))) - float(band_height.call(str(a["altitude_band"])))
		var dt := float(b["t"]) - float(a["t"])
		if dh != 0.0 and dt > 0.0:
			pitch = clampf(atan2(dh / dt, maxf(float(s["speed"]), 1e-9)), -rules.max_pitch, rules.max_pitch)
	# Velocity (for the crossing_rate factor): the sampled speed along the nose, pitched by the
	# same tilt as the cones. The band heights imply a climb of 280 to 600 m a second over a
	# step; the airframe's pitch is the plausible rate and agrees with the cones.
	var speed := float(s["speed"])
	var hdg := float(s["heading"])
	var cp := cos(pitch)
	return {
		"x": s["x"], "y": s["y"], "heading": hdg, "height_m": s["height_m"], "pitch": pitch,
		"vx": speed * cp * cos(hdg), "vy": speed * cp * sin(hdg), "vz": speed * sin(pitch),
	}

# Two time-ordered event lists as one: by "t" ascending, `first` before
# `second` when they tie. (Array.sort_custom is not stable, so this merges.)
static func merge_events(first: Array, second: Array) -> Array:
	var out: Array = []
	var i := 0
	var j := 0
	while i < first.size() and j < second.size():
		if float((first[i] as Dictionary).get("t", 0.0)) <= float((second[j] as Dictionary).get("t", 0.0)):
			out.append(first[i])
			i += 1
		else:
			out.append(second[j])
			j += 1
	while i < first.size():
		out.append(first[i])
		i += 1
	while j < second.size():
		out.append(second[j])
		j += 1
	return out
