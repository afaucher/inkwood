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
# stays where it is. A SEA unit, when the World has water (`ships_sink`), SINKS instead (Track BB, 2026-10-11; Alex, decision
# ship-sinks: 'ideally we just sink them to the bottom', 'just like a downed plane its altitude should decrease until it hits the floor.
# It just does so through the water'): its fate is OUT_OF_CONTROL with no spin, the World flies the fall (scripts/sim/world.gd, _fall_step:
# a hull stays where it went down and loses height at combat.json sink_descent_mps below the surface to the water's floor, then it is
# CRASHED, on the floor).
#
# SHELLS (Track SH, the warship, 2026-10-10; scripts/sim/guns.gd has the model and the events). The same walk also fires the BIG-GUN
# SPECIALS: the histories' step states carry the "fire" a unit planned (its special, its target, the moment); a unit that is up at
# the start of the tick the moment falls in, is loaded, and whose target is still in range and SPOTTED (spot_fn, the World's
# shared-spotting query) fires its salvo (shell_fire, the shells seeded and scattered). A target that is no longer spotted or is out of
# reach by then gets a POOR SHOT (Alex, decision outside-cone-release; data/sim/guns.json gun_unspotted_mode: a shell_fire with "poor_shot":
# true, at the target's last spotted place, the scatter widened; with the mode "hold" nothing is spent and a gun_hold says why); the guns
# reloading, a target that is down, a friend or gone are always held, with a gun_hold that says why. A shell whose impact moment falls
# in a tick lands (shell_impact) and hurts the units that were up at the start of the tick and stand at the surface within the blast --
# the very blast code a bomb uses (_blast_at), with the special's own table.
# Shells that land in a later turn are returned in `shells`; the ones carried from earlier turns come in as `shells_in`. Without gun
# rules (a resolver built with fewer arguments) there are no shells.
#
#   var fight := CombatResolver.new(rules, bomb_rules, gun_rules).run(units, histories, turn, rng_seed, turn_seconds,
#       sampler, band_height, bombs_in, shells_in, spot_fn)
#   spot_fn(side: String, target: Dictionary, t: float, down_at: Dictionary, special_id: String) -> {spotted: bool, run_s: float, salvos: int, spotter_ratio: float}
#       (run_s: seconds the target has been spotted without a break; salvos: fired at it before this turn, the bracketing)
#   reach_fn(special_id: String, from: Vector2, target_pos: Vector2) -> String   "" or why the target is out of reach beyond the range
#       (the World's coastal strip: Guns.WHY_INLAND)
#   fight.shells      the shells still in the air at the end of the turn (records: guns.gd header)
#   fight.fired       unit id -> the special ids it fired this turn (the World sets their reload)

const Combat = preload("res://scripts/sim/combat.gd")
const CombatRules = preload("res://scripts/sim/combat_rules.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const Guns = preload("res://scripts/sim/guns.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")

var rules: CombatRules
var bomb_rules: BombRules = null
var gun_rules: GunRules = null
# Set by the World each resolve: it has water, so a destroyed sea unit sinks (fate out_of_control, no spin) instead of being destroyed.
var ships_sink: bool = false
# Set by the World each resolve when the lines of fire are on (scripts/sim/combat_lines.gd; data/sim/line_of_fire.json `enabled`): null is the old
# combat, unchanged to the byte.
var lines: RefCounted = null

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
var _fire_plan: Array = []      # [{unit, special, step, t, tick, target}] the gun specials planned this turn, in order
var _shell_pending: Array = []  # shells that land this turn and have not landed yet
var _shell_carry: Array = []    # shells still in the air at the end of the turn
var _fired: Dictionary = {}     # unit id -> [special ids fired this turn]
var _spot_fn: Callable = Callable()
var _reach_fn: Callable = Callable()

func _init(combat_rules: CombatRules, bombing_rules: BombRules = null, gunnery_rules: GunRules = null) -> void:
	rules = combat_rules
	bomb_rules = bombing_rules
	gun_rules = gunnery_rules

func run(units: Dictionary, histories: Dictionary, turn: int, rng_seed: int, turn_seconds: float, sampler: Callable, band_height: Callable, bombs_in: Array = [], shells_in: Array = [], spot_fn: Callable = Callable(), reach_fn: Callable = Callable()) -> Dictionary:
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
	_fire_plan = []
	_shell_pending = []
	_shell_carry = []
	_fired = {}
	_spot_fn = spot_fn
	_reach_fn = reach_fn
	for i in _ids.size():
		var id: String = _ids[i]
		var u: Unit = units[id]
		_index[id] = i
		_health[id] = u.health
		_up[id] = not u.down
	var n_ticks := maxi(1, roundi(turn_seconds / rules.tick_seconds))
	if bomb_rules != null:
		_start_bombs(histories, bombs_in, n_ticks)
	if gun_rules != null:
		_start_guns(histories, shells_in, n_ticks)
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
		if gun_rules != null:
			_guns_tick(active, tick, n_ticks, sampler)
		t_prev = t
	return {"events": _sorted_events(), "health": _health, "down_at": _down_at, "fates": _fates,
		"bombs": _carry, "released": _released, "shells": _shell_carry, "fired": _fired}

# One hardpoint's rolls in one tick: pick the target (best odds among the enemy
# units in the cone), then roll n_rolls times at it.
func _fire_hardpoint(active: Array[String], states: Dictionary, sid: String, w_i: int, weapon: CombatWeapon, h_i: int, n_rolls: int, tick: int, t: float) -> void:
	var shooter: Unit = _units[sid]
	var p := Combat.pose(states[sid], weapon.hardpoints[h_i])
	var reach_m := Combat.reach(weapon, rules.odds_factors, _params)
	var range_sq := reach_m * reach_m
	var best_id := ""
	var best: Dictionary = {}
	# THE LINES OF FIRE (stage 2, builder LOF2; scripts/sim/combat_lines.gd): only with the switch on AND for a weapon with a straight round in
	# the data. A target of which nothing is in view is not a candidate (the gun HOLDS); a visible one has its odds from the share of the
	# round's spread on what is visible, and the fire event says where each round went.
	var use_lines: bool = lines != null and lines.applies(weapon)
	var roll_seed := 0
	if use_lines:
		roll_seed = Combat.roll_seed(_seed, _turn, int(_index[sid]), w_i, h_i, tick)
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
		if use_lines:
			var la: Dictionary = lines.assess(shooter, states[sid], p, weapon, g, target, ts, roll_seed)
			if not bool(la["visible"]):
				continue
			g["odds"] = la["odds"]
			g["lines"] = la
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
		if use_lines:
			# where this round went: drawn from the roll's own stream, never from `rng` (a draw here would shift every later roll)
			(_events[_events.size() - 1] as Dictionary).merge(lines.landing(best["lines"], hit, roll_seed, _j))
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
		var domain: String = (_units[target_id] as Unit).def.domain
		if domain == "air":
			fate = Combat.fate_roll(_seed, _turn, int(_index[target_id]), tick, rules.explode_chance)
		elif domain == "sea" and ships_sink:
			fate = {"fate": Unit.FATE_OUT_OF_CONTROL, "spin": 0}   # a hull going down: no turn, the sink rate (World._fall_step)
		else:
			fate = {"fate": Unit.FATE_DESTROYED, "spin": 0}
		_fates[target_id] = fate
		if lines != null and (_units[target_id] as Unit).def.is_static():
			lines.grid.unstamp(target_id)   # a battery's sandbags or the bridge's parapets are cover no longer, from this moment
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
	var ev := {
		"type": "bomb_release", "turn": _turn, "unit": uid, "t": float(drop["release_t"]),
		"x": rel["x"], "y": rel["y"], "height_m": rel["height_m"], "heading": rel["heading"], "speed": rel["speed"],
		"aim": (drop["aim"] as Array).duplicate(), "bombs": stick.size(), "drop_index": drop_index, "step": step,
		"accuracy": drop["accuracy"], "spread_m": drop["spread_m"], "fall_s": drop["fall_s"], "impact_t": drop["impact_t"],
	}
	# Track T: the target the drop was activated with, whether it followed a unit, and whether it was a poor shot
	# (the target outside the cone with outside_cone_mode "poor_shot"); only when there is something to say.
	if drop.has("target"):
		ev["target"] = (drop["target"] as Dictionary).duplicate(true)
	if bool(drop.get("followed", false)):
		ev["followed"] = true
	if bool(drop.get("poor_shot", false)):
		ev["poor_shot"] = true
	_events.append(ev)
	for b: Dictionary in stick:
		_land_or_carry(Bombs.schedule(b, _turn_seconds))

# A bomb lands: the bomb_impact event, then the blast on every unit that was up when the tick began.
func _land(b: Dictionary, active: Array[String], tick: int, sampler: Callable) -> void:
	var t := float(b["impact_t"])
	var radius := bomb_rules.blast_radius_m()
	_events.append({
		"type": "bomb_impact", "turn": _turn, "unit": b["unit"], "bomb": int(b["bomb"]), "drop_index": int(b["drop_index"]),
		"stick": "%s/%d/%d" % [b["unit"], int(b["release_turn"]), int(b["drop_index"])],
		"t": t, "x": float(b["x"]), "y": float(b["y"]), "blast_m": radius, "released_turn": int(b["release_turn"]), "released_t": float(b["release_t"]),
	})
	_blast_at(str(b["unit"]), "bomb", float(b["x"]), float(b["y"]), t, active, tick, sampler, bomb_rules)

# THE BLAST, a bomb's or a shell's: every unit that was up when the tick began, at the surface (blast_height_m) and inside the
# blast table of `blast` (a BombRules or a GunRules.Spec: both answer blast_damage, blast_height_m and blast_hits_own_side), is
# hurt by the pips of the tier its centre falls in, `by_id` being the unit that fired and `weapon_id` what it fired with.
func _blast_at(by_id: String, weapon_id: String, bx: float, by: float, t: float, active: Array[String], tick: int, sampler: Callable, blast: Object) -> void:
	var shooter_side := ""
	if _units.has(by_id):
		shooter_side = (_units[by_id] as Unit).side
	for tid: String in active:
		var target: Unit = _units[tid]
		if not blast.blast_hits_own_side and shooter_side != "" and target.side == shooter_side:
			continue
		var ts: Dictionary = sampler.call(tid, t)
		if float(ts.get("height_m", 0.0)) > blast.blast_height_m:
			continue
		var dist := Vector2(float(ts["x"]) - bx, float(ts["y"]) - by).length()
		var pips: int = blast.blast_damage(dist)
		if pips <= 0:
			continue
		_hurt(tid, by_id, weapon_id, pips, t, tick, ts)

# --- Shells (the big-gun specials; guns.gd) ----------------------------------------------------------

# Lay out the turn's gunnery: the gun specials planned in the histories (every step state that carries a "fire"), and the shells
# carried in from earlier turns (the ones landing this turn go to _shell_pending, the rest stay _shell_carry).
func _start_guns(histories: Dictionary, shells_in: Array, n_ticks: int) -> void:
	for id: String in _ids:
		var h: Array = histories[id]
		for k in range(1, h.size()):
			var f: Variant = (h[k] as Dictionary).get("fire")
			if f is Dictionary and (f as Dictionary).has("fire_t") and (f as Dictionary).get("target") is Dictionary and not ((f as Dictionary)["target"] as Dictionary).is_empty() 					and gun_rules.has_special(str((f as Dictionary).get("special", ""))):
				var ft := float((f as Dictionary)["fire_t"])
				_fire_plan.append({"unit": id, "special": str((f as Dictionary)["special"]), "step": int((h[k] as Dictionary).get("step", k - 1)),
					"t": ft, "tick": _tick_of(ft, n_ticks), "target": (f as Dictionary)["target"], "aim": (f as Dictionary).get("aim", [])})
	for s: Dictionary in shells_in:
		_shell_land_or_carry(s.duplicate(true))

func _shell_land_or_carry(s: Dictionary) -> void:
	if int(s["impact_turn"]) <= _turn:
		if int(s["impact_turn"]) < _turn:
			s["impact_turn"] = _turn
			s["impact_t"] = 0.0
		_shell_pending.append(s)
	else:
		_shell_carry.append(s)

# One tick of gunnery, after the bombs: the salvos that fall in it, then the shells that land in it.
func _guns_tick(active: Array[String], tick: int, n_ticks: int, sampler: Callable) -> void:
	for entry: Dictionary in _fire_plan:
		if int(entry["tick"]) != tick:
			continue
		# Only a unit that was up when the tick began fires (as for the guns and the bombs: simultaneous).
		if not active.has(str(entry["unit"])):
			continue
		_fire_salvo(entry, active, sampler)
	var due: Array = []
	var rest: Array = []
	for s: Dictionary in _shell_pending:
		if int(s["impact_turn"]) == _turn and _tick_of(float(s["impact_t"]), n_ticks) == tick:
			due.append(s)
		else:
			rest.append(s)
	_shell_pending = rest
	if due.is_empty():
		return
	due.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["impact_t"]) != float(b["impact_t"]):
			return float(a["impact_t"]) < float(b["impact_t"])
		return str(a["id"]) < str(b["id"]))
	for s: Dictionary in due:
		var spec: GunRules.Spec = gun_rules.special(str(s["special"]))
		if spec == null:
			continue
		var t := float(s["impact_t"])
		_events.append({
			"type": "shell_impact", "turn": _turn, "unit": s["unit"], "special": s["special"], "shell": int(s["shell"]), "step": int(s["step"]),
			"t": t, "x": float(s["x"]), "y": float(s["y"]), "blast_m": spec.blast_radius_m(), "released_turn": int(s["release_turn"]), "released_t": float(s["release_t"]),
		})
		_blast_at(str(s["unit"]), str(s["special"]), float(s["x"]), float(s["y"]), t, active, tick, sampler, spec)

# A unit fires the salvo it planned, if it can: loaded, its target there, in range and spotted at this moment. Its target out of sight
# or out of reach is a poor shot (_fire_poor) unless the mode is "hold"; for the other reasons a gun_hold event says why and nothing is spent.
func _fire_salvo(entry: Dictionary, active: Array[String], sampler: Callable) -> void:
	var uid: String = entry["unit"]
	var sid: String = entry["special"]
	var u: Unit = _units[uid]
	var t := float(entry["t"])
	var target: Dictionary = entry["target"]
	var spec: GunRules.Spec = gun_rules.special(sid)
	if spec == null:
		return
	var fired: Array = _fired.get(uid, [])
	if fired.has(sid) or u.gun_ready_turn(sid) > _turn:
		_hold(entry, Guns.WHY_RELOADING)
		return
	var from_s: Dictionary = sampler.call(uid, t)
	var from := Vector2(float(from_s["x"]), float(from_s["y"]))
	var tpos := Vector2.ZERO
	var tvel := Vector2.ZERO
	if target.has("unit"):
		var tid := str(target["unit"])
		if not _units.has(tid):
			_hold(entry, Guns.WHY_NO_TARGET)
			return
		if (_units[tid] as Unit).side == u.side:
			_hold(entry, Guns.WHY_OWN_SIDE)
			return
		if not _up.get(tid, false):
			_hold(entry, Guns.WHY_TARGET_DOWN)
			return
		var ts: Dictionary = sampler.call(tid, t)
		tpos = Vector2(float(ts["x"]), float(ts["y"]))
		tvel = Vector2(cos(float(ts["heading"])), sin(float(ts["heading"]))) * float(ts["speed"])
	else:
		var p: Variant = target["point"]
		tpos = (p as Vector2) if p is Vector2 else Vector2(float(p[0]), float(p[1]))
	var why := Guns.range_error(from.distance_to(tpos), spec)
	if why == "" and _reach_fn.is_valid():
		why = str(_reach_fn.call(sid, from, tpos))
	var poor := gun_rules.unspotted_mode == "poor_shot"
	if why != "" and not (poor and Guns.poor_shot_reason(why)):
		_hold(entry, why)
		return
	var spot: Dictionary = {"spotted": true, "run_s": 0.0, "salvos": 0, "spotter_ratio": 0.0, "last_t": -1.0}
	if _spot_fn.is_valid():
		spot = _spot_fn.call(u.side, target, t, _down_at, sid)
	if why == "" and not bool(spot["spotted"]):
		why = Guns.WHY_UNSPOTTED
		if not poor:
			_hold(entry, why)
			return
	if why != "":
		_fire_poor(entry, why, spec, target, from, tpos, spot, sampler)
		return
	var aim := Guns.aim_for(from, tpos, tvel, spec)
	var salvos_before := int(spot.get("salvos", 0))
	var spotter_ratio := float(spot.get("spotter_ratio", 0.0))
	var sigma := Guns.sigma_m(float(aim["range_m"]), float(spot["run_s"]), spec, salvos_before, spotter_ratio)
	_launch_salvo(entry, spec, target, from, aim["aim"], float(aim["range_m"]), float(aim["flight_s"]), sigma, spot, target.has("unit"), {})

# A POOR SHOT (Alex, decision outside-cone-release: "Fire a poorer one"; data/sim/guns.json gun_unspotted_mode "poor_shot"): the target is no
# longer spotted, or is out of reach, at the moment of fire. The salvo goes all the same and the reload is spent: at where the guns take the
# target to be (a point target: where it is; a unit still spotted: where it is; a unit no longer spotted: where it was LAST SPOTTED -- its
# place at the last walked moment the side saw it this turn, else where it was shown when the fire was set, else where it stood at the start
# of the turn), pulled back along the line to the edge of the reach if that is outside it (Guns.poor_aim), with no lead and a widened
# scatter (Guns.poor_sigma_m). If no place on the line is in reach it is held after all, with the reason.
func _fire_poor(entry: Dictionary, why: String, spec: GunRules.Spec, target: Dictionary, from: Vector2, tpos: Vector2, spot: Dictionary, sampler: Callable) -> void:
	var known := tpos
	if target.has("unit") and not bool(spot["spotted"]):
		var tid := str(target["unit"])
		var last_t := float(spot.get("last_t", -1.0))
		var shown: Variant = entry.get("aim", [])
		if last_t >= 0.0:
			var ls: Dictionary = sampler.call(tid, last_t)
			known = Vector2(float(ls["x"]), float(ls["y"]))
		elif shown is Array and (shown as Array).size() >= 2:
			known = Vector2(float(shown[0]), float(shown[1]))
		else:
			var s0: Dictionary = sampler.call(tid, 0.0)
			known = Vector2(float(s0["x"]), float(s0["y"]))
	var sid := str(entry["special"])
	var reach := Callable()
	if _reach_fn.is_valid():
		reach = func(f: Vector2, to: Vector2) -> String: return str(_reach_fn.call(sid, f, to))
	var pa := Guns.poor_aim(from, known, spec, reach)
	if not bool(pa["ok"]):
		_hold(entry, why)
		return
	var salvos_before := int(spot.get("salvos", 0))
	var spotter_ratio := float(spot.get("spotter_ratio", 1.0))
	var sigma := Guns.poor_sigma_m(float(pa["range_m"]), float(spot.get("run_s", 0.0)), spec, salvos_before, spotter_ratio)
	_launch_salvo(entry, spec, target, from, pa["aim"], float(pa["range_m"]), float(pa["flight_s"]), sigma, spot, false,
		{"poor_shot": true, "poor_why": why, "known": [known.x, known.y], "clamped": bool(pa["clamped"])})

# The salvo leaves: its shells are made and scheduled, the guns are spent (the World sets the reload from `_fired`), the shell_fire event
# says so. `extra` is added to the event (a poor shot's marks).
func _launch_salvo(entry: Dictionary, spec: GunRules.Spec, target: Dictionary, from: Vector2, aim: Vector2, range_m: float, flight_s: float, sigma: float, spot: Dictionary, followed: bool, extra: Dictionary) -> void:
	var uid := str(entry["unit"])
	var sid := str(entry["special"])
	var t := float(entry["t"])
	var shells := Guns.make_salvo({"unit": uid, "special": sid, "step": int(entry["step"]), "t": t, "from": from, "aim": aim,
		"range_m": range_m, "flight_s": flight_s, "sigma_m": sigma}, spec, _seed, _turn, int(_index[uid]))
	var fired: Array = _fired.get(uid, [])
	fired.append(sid)
	_fired[uid] = fired
	var ev := {
		"type": "shell_fire", "turn": _turn, "unit": uid, "special": sid, "t": t, "x": from.x, "y": from.y, "step": int(entry["step"]),
		"target": target.duplicate(true), "aim": [aim.x, aim.y], "shells": shells.size(), "range_m": range_m, "flight_s": flight_s,
		"impact_t": t + flight_s, "spread_m": sigma, "spotted_s": float(spot.get("run_s", 0.0)), "salvos_before": int(spot.get("salvos", 0)),
		"spotter_ratio": float(spot.get("spotter_ratio", 0.0)), "followed": followed,
	}
	ev.merge(extra)
	_events.append(ev)
	for sh: Dictionary in shells:
		_shell_land_or_carry(Bombs.schedule(sh, _turn_seconds))

func _hold(entry: Dictionary, reason: String) -> void:
	_events.append({
		"type": "gun_hold", "turn": _turn, "unit": entry["unit"], "special": entry["special"], "t": float(entry["t"]), "step": int(entry["step"]),
		"target": (entry["target"] as Dictionary).duplicate(true), "reason": reason,
	})

# The events in time order: by t, and by the order they were made within a moment. (The guns' events
# carry their tick's end, a bomb's its own moment, so a bomb's event may be made after a later-stamped
# one of the same tick.) Array.sort_custom is not stable, so the order made is the second key.
func _sorted_events() -> Array:
	if bomb_rules == null and gun_rules == null:
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
