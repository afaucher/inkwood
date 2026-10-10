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
#
# BOMBS (Track S2, 2026-10-10; scripts/sim/bombs.gd has the model and the events). The resolver
# also releases and lands bombs, on the same tick clock and under the same rules: the histories'
# step states carry the drop a bomber planned ("drop", Bombs.plan_drop's analysis, with "ok" false
# for a drop the bomber had no load for); a bomber that is up at the start of the tick a drop's
# release moment falls in releases its stick (bomb_release, the bombs seeded and scattered); a bomb
# whose impact moment falls in a tick lands (bomb_impact) and damages the units that were up at the
# start of the tick and stand at the surface within the blast (hit, down). Bombs that land in a later
# turn are returned in `bombs`; the ones carried from earlier turns come in as `bombs_in`. Without
# bomb rules (a resolver built with one argument) there are no bombs.
#
#   var fight := CombatResolver.new(rules, bomb_rules).run(units, histories, turn, rng_seed,
#       turn_seconds, sampler, band_height, bombs_in)
#   fight.bombs       the bombs still falling at the end of the turn (records: bombs.gd header)
#   fight.released    unit id -> drops it released this turn
#
# A unit that goes down and is not an aircraft is DESTROYED (Unit.FATE_DESTROYED): no fate roll, it
# stays where it is.

const Combat = preload("res://scripts/sim/combat.gd")
const CombatRules = preload("res://scripts/sim/combat_rules.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")

var rules: CombatRules
var bomb_rules: BombRules = null

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
var _turn_seconds: float = 0.0
var _released: Dictionary = {}  # unit id -> drops released this turn
var _pending: Array = []        # bombs that land this turn and have not landed yet
var _carry: Array = []          # bombs still falling at the end of the turn
var _drop_plan: Array = []      # [{unit, t, tick, drop}] the releases of this turn, in order

func _init(combat_rules: CombatRules, bombing_rules: BombRules = null) -> void:
	rules = combat_rules
	bomb_rules = bombing_rules

func run(units: Dictionary, histories: Dictionary, turn: int, rng_seed: int, turn_seconds: float, sampler: Callable, band_height: Callable, bombs_in: Array = []) -> Dictionary:
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
	_turn_seconds = turn_seconds
	_released = {}
	_pending = []
	_carry = []
	_drop_plan = []
	for i in _ids.size():
		var id: String = _ids[i]
		var u: Unit = units[id]
		_index[id] = i
		_health[id] = u.health
		_up[id] = not u.down
	var n_ticks := maxi(1, roundi(turn_seconds / rules.tick_seconds))
	if bomb_rules != null:
		_start_bombs(histories, bombs_in, n_ticks)
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
		if bomb_rules != null:
			_bombs_tick(active, tick, n_ticks, sampler)
		t_prev = t
	return {"events": _sorted_events(), "health": _health, "down_at": _down_at, "fates": _fates,
		"bombs": _carry, "released": _released}

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
		_hurt(best_id, sid, weapon.id, weapon.damage_pips, t, tick, tstate)

# Take `pips` from a unit, by a shooter's weapon (or "bomb"), at t: the hit event and, when it is the
# last pip, the down event and the fate -- an aircraft explodes or falls out of control (a seeded
# roll), anything else (a ground unit) is destroyed and stays where it is. A unit hit again within
# the tick it went down gets another hit event and no second down.
func _hurt(target_id: String, by_id: String, weapon_id: String, pips: int, t: float, tick: int, tstate: Dictionary) -> void:
	_health[target_id] = maxi(0, int(_health[target_id]) - pips)
	_events.append({
		"type": "hit", "turn": _turn, "unit": target_id, "by": by_id, "weapon": weapon_id,
		"t": t, "damage": pips, "health": _health[target_id],
	})
	if int(_health[target_id]) == 0 and not _down_at.has(target_id):
		_down_at[target_id] = t
		_up[target_id] = false
		var fate: Dictionary
		if (_units[target_id] as Unit).def.domain == "air":
			fate = Combat.fate_roll(_seed, _turn, int(_index[target_id]), tick, rules.explode_chance)
		else:
			fate = {"fate": Unit.FATE_DESTROYED, "spin": 0}
		_fates[target_id] = fate
		_events.append({
			"type": "down", "turn": _turn, "unit": target_id, "by": by_id, "t": t,
			"x": tstate["x"], "y": tstate["y"], "height_m": tstate["height_m"],
			"fate": fate["fate"],
		})

# --- Bombs -----------------------------------------------------------------------------

# The tick (1-based) a moment t seconds into the turn belongs to: a moment on a tick's end belongs
# to that tick, one at 0 to the first.
func _tick_of(t: float, n_ticks: int) -> int:
	return clampi(ceili(t / (_turn_seconds / float(n_ticks)) - 1e-9), 1, n_ticks)

# Lay out the turn's bombing: the drops planned in the histories (the releases), and the bombs
# carried in from earlier turns (the ones landing this turn go to _pending, the rest stay _carry).
func _start_bombs(histories: Dictionary, bombs_in: Array, n_ticks: int) -> void:
	for id: String in _ids:
		var h: Array = histories[id]
		for k in range(1, h.size()):
			var d: Variant = (h[k] as Dictionary).get("drop")
			if d is Dictionary and (d as Dictionary).get("ok", false) == true:
				_drop_plan.append({"unit": id, "t": float((d as Dictionary)["release_t"]), "tick": _tick_of(float((d as Dictionary)["release_t"]), n_ticks), "drop": d, "step": int((h[k] as Dictionary).get("step", k - 1))})
	for b: Dictionary in bombs_in:
		_land_or_carry(b.duplicate(true))

# A bomb with its impact turn and moment filled in: pending if it lands this turn (a stale one, due in
# an earlier turn, lands at the start of this one), else carried.
func _land_or_carry(b: Dictionary) -> void:
	if int(b["impact_turn"]) <= _turn:
		if int(b["impact_turn"]) < _turn:
			b["impact_turn"] = _turn
			b["impact_t"] = 0.0
		_pending.append(b)
	else:
		_carry.append(b)

# One tick of bombing, after the guns: the releases that fall in it, then the impacts that fall in it.
func _bombs_tick(active: Array[String], tick: int, n_ticks: int, sampler: Callable) -> void:
	for entry: Dictionary in _drop_plan:
		if int(entry["tick"]) != tick:
			continue
		var uid: String = entry["unit"]
		# Only a bomber that was up when the tick began releases (as for the guns: simultaneous).
		if not active.has(uid):
			continue
		_release(uid, entry["drop"], int(entry["step"]))
	var due: Array = []
	var rest: Array = []
	for b: Dictionary in _pending:
		if int(b["impact_turn"]) == _turn and _tick_of(float(b["impact_t"]), n_ticks) == tick:
			due.append(b)
		else:
			rest.append(b)
	_pending = rest
	if due.is_empty():
		return
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["impact_t"]) != float(b["impact_t"]):
			return float(a["impact_t"]) < float(b["impact_t"])
		return str(a["id"]) < str(b["id"]))
	for b: Dictionary in due:
		_land(b, active, tick, sampler)

# A bomber lets its stick go: the bomb_release event, and the bombs scheduled (landing this turn or a later one).
func _release(uid: String, drop: Dictionary, step: int) -> void:
	var u: Unit = _units[uid]
	var drop_index := u.def.bomb_drops - u.drops_left + int(_released.get(uid, 0))
	_released[uid] = int(_released.get(uid, 0)) + 1
	var stick := Bombs.make_stick(drop, u.def.bomb_per_drop, bomb_rules, _seed, _turn, uid, int(_index[uid]), drop_index)
	var rel: Dictionary = drop["release"]
	_events.append({
		"type": "bomb_release", "turn": _turn, "unit": uid, "t": float(drop["release_t"]),
		"x": rel["x"], "y": rel["y"], "height_m": rel["height_m"], "heading": rel["heading"], "speed": rel["speed"],
		"aim": (drop["aim"] as Array).duplicate(), "bombs": stick.size(), "drop_index": drop_index, "step": step,
		"accuracy": drop["accuracy"], "spread_m": drop["spread_m"], "fall_s": drop["fall_s"], "impact_t": drop["impact_t"],
	})
	for b: Dictionary in stick:
		_land_or_carry(Bombs.schedule(b, _turn_seconds))

# A bomb lands: the bomb_impact event, then the blast on every unit that was up when the tick began.
func _land(b: Dictionary, active: Array[String], tick: int, sampler: Callable) -> void:
	var t := float(b["impact_t"])
	var bx := float(b["x"])
	var by := float(b["y"])
	var radius := bomb_rules.blast_radius_m()
	_events.append({
		"type": "bomb_impact", "turn": _turn, "unit": b["unit"], "bomb": int(b["bomb"]), "drop_index": int(b["drop_index"]),
		"stick": "%s/%d/%d" % [b["unit"], int(b["release_turn"]), int(b["drop_index"])],
		"t": t, "x": bx, "y": by, "blast_m": radius, "released_turn": int(b["release_turn"]), "released_t": float(b["release_t"]),
	})
	var bomber_side := ""
	if _units.has(b["unit"]):
		bomber_side = (_units[b["unit"]] as Unit).side
	for tid: String in active:
		var target: Unit = _units[tid]
		if not bomb_rules.blast_hits_own_side and bomber_side != "" and target.side == bomber_side:
			continue
		var ts: Dictionary = sampler.call(tid, t)
		if float(ts.get("height_m", 0.0)) > bomb_rules.blast_height_m:
			continue
		var dist := Vector2(float(ts["x"]) - bx, float(ts["y"]) - by).length()
		var pips := bomb_rules.blast_damage(dist)
		if pips <= 0:
			continue
		_hurt(tid, str(b["unit"]), "bomb", pips, t, tick, ts)

# The events in time order: by t, and by the order they were made within a moment. (The guns' events
# carry their tick's end, a bomb's its own moment, so a bomb's event may be made after a later-stamped
# one of the same tick.) Array.sort_custom is not stable, so the order made is the second key.
func _sorted_events() -> Array:
	if bomb_rules == null:
		return _events
	var keyed: Array = []
	for i in _events.size():
		keyed.append([float((_events[i] as Dictionary).get("t", 0.0)), i])
	keyed.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		return a[1] < b[1])
	var out: Array = []
	for k: Array in keyed:
		out.append(_events[int(k[1])])
	return out

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
