extends RefCounted

# THE FOREST FIRE (decision forest-fire, 2026-10-11; numbers data/sim/fire.json, scripts/sim/fire_rules.gd). ALEX: "I am thinking that the fire
# is actually just smoke coming from the trees. It spreads from tree to tree based on distance. It can inflict damage to nearby units with low
# power and low chance." "It should generate smoke which makes it harder to see." Then, on how: "1 visible but untrackable and 2 last place you
# saw it". Every detail that is not in his words is PROPOSED (the lead's, or this track's reading), labelled so in the data and below.
#
# THE WORLD holds one as `world.fire` (null when the fire is off: then nothing here runs and nothing changes), made by World.enable_fire.
#
#   fire.feed() -> Array     every tree EVER lit: {id, x_m, y_m, r_m, lit_turn, lit_t, out_turn} (metres; r_m the canopy radius; out_turn the
#                            last turn it burns -- a trunk from out_turn + 1), in the order they were lit. THE EFFECTS LAYER AND THE MAP READ THIS.
#   fire.smoke_at(x, y, time_s) / fire.denies_tracking(def, x, y, time_s)      the smoke (below)
#   fire.burnt_scale(x, y, time_s)                                              the burnt-out share of the woods (below)
#   fire.resolve_turn(...)                                                      the host's step, called by World.resolve()
#   fire.net_state() / fire.apply_net_state(d)                                  the wire (World.net_fire / apply_net_fire)
#
# THE EVENTS resolve_turn adds to the turn's list (metres, seconds into the turn, plain values; t ascending, merged in by the World):
#   {"type": "fire_ignite", "turn", "t", "tree": id, "x", "y", "cause": "bomb" | "shell" | "crash" | "spread"[, "from": the tree it spread from]}
#   {"type": "fire_out", "turn", "t" (= turn_seconds), "tree": id, "x", "y"}          a tree burns out at the end of its last burning turn
#   {"type": "fire_damage", "turn", "t", "unit", "x", "y" (the unit's), "tree": the tree it was most exposed to}
#   and for a unit it hurt the standard {"type": "hit", ..., "by": "", "weapon": "fire", "damage", "health"} and, at 0 pips, {"type": "down", ...,
#   "by": "", "fate": "destroyed"}, so the interface shows it as it shows any hit (combat.gd).
#
# THE RULES (Alex's numbers are {decision} in the data; the rest is PROPOSED):
#   IGNITION   a bomb_impact, a shell_impact (radius: the event's blast_m) and a crash (radius: ignite.crash_radius_m, PROPOSED 20 m) light each
#              tree whose canopy is within the radius of the point, 50% each, at the event's moment. The dice are per (event, tree).
#   SPREAD     once a turn, each tree burning from an EARLIER turn (PROPOSED) may light each unlit tree within spread.reach_m of it, canopy edge to
#              canopy edge (PROPOSED): 40% when the canopies touch or overlap, falling linearly to 0 at 30 m. A tree lit by spread is lit at a
#              seeded moment inside the turn (PROPOSED), so its smoke starts during the playback. The dice are per (source, target) pair.
#   BURNING    a tree burns burn.turns turns, the turn it is lit counting as the first (PROPOSED reading); it is then BURNT OUT, a trunk.
#   DAMAGE     a ground or sea unit loses 1 pip with the chance damage.chance_near at a burning canopy's edge, fading linearly to 0 at 25 m beyond
#              it; several burning trees combine as 1 - product(1 - p) and a unit loses at most one pip a turn (PROPOSED), judged at the moment of
#              the turn its path is most exposed (the event's t); a unit that loses its last pip is DESTROYED (the existing down machinery).
#   SMOKE      a tree smokes from its lit moment to the end of its last burning turn. A ground or sea unit (mobile and static, PROPOSED) within
#              smoke.reach_m (PROPOSED 20 m) of a smoking canopy is IN THE SMOKE. Smoke is NOT cover: the unit stays as visible as it was (the fog,
#              the AI's knowledge, the woods radius). It cannot be TRACKED (Alex): see Spotting (fire control), World._resolve_followed_drops
#              (bombs follow the last place it was tracked) and UiTarget (a click sets a point).
#   BURNT COVER  a burnt-out tree takes its woods cover with it (Alex, '5 - yes'): Concealment scales the woods density by burnt_scale().
#
# TIME is game seconds from the start of the game, as the guns' reveal (reveal.gd): (turn - 1) x turn_seconds + t. "As the world stands" is the
# start of the turn being planned or the end of the turn just resolved. A tree lit at (turn L, lit_t) smokes in [that moment, out_turn x
# turn_seconds). What the host knows while it resolves a turn is the fire of the turns BEFORE it (the trees this turn's blasts light are
# added after the turn's combat), so a decision made inside the resolve -- the guns' spotting, a bomb's aim -- sees last turn's smoke, and the
# playback and the planning after it see this turn's too.
#
# RANDOMNESS. The host only. Every roll is its own seeded stream (Mulberry32 seeded by combat.gd's mix32 folded over the game seed, the turn, FIRE_TAG,
# a kind and the keys of what is rolled), so a replay draws the same dice, no roll depends on the order of the others, and the combat's dice
# are never touched. Nothing here sorts with sort_custom on a tie.

const FireRules = preload("res://scripts/sim/fire_rules.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const MASK32 := 0xFFFFFFFF
const FIRE_TAG := 0x46495245        # "FIRE"
const KIND_IGNITE := 1
const KIND_SPREAD := 2
const KIND_LIT_T := 3
const KIND_DAMAGE := 4
const CELL_M := 64.0                # the grid the lit trees are found by
const EPS := 1e-9

# The event order within one moment: a tree lights, then what that does to the units, then the trees that burn out.
const RANK_IGNITE := 0
const RANK_DAMAGE := 1
const RANK_OUT := 2

var rules: FireRules
var turn_seconds: float = 5.0
# The trees the fire can light: a FireTrees (scripts/sim/fire_trees.gd) or any object with trees_in_disc(x, y, reach) and max_canopy_m(). null: a state
# that only carries trees (a client that joined without the terrain): it lights nothing and the burnt-out share is 1.
var source: Object = null
var revision: int = 0               # counts the changes (the map and the effects redraw when it moves)

var trees: Dictionary = {}          # id -> {id, x_m, y_m, r_m, kx, ky, lit_turn, lit_t, out_turn, cause, from}
var _order: Array[String] = []      # ids in the order they were lit
var _cells: Dictionary = {}         # Vector2i -> Array of ids
var _max_r: float = 0.0

func _init(fire_rules: FireRules, turn_len_s: float) -> void:
	rules = fire_rules
	turn_seconds = turn_len_s

func ok() -> bool:
	return rules != null and rules.ok()

# --- The feed and the wire --------------------------------------------------------------------------------------------

# Every tree ever lit, in the order they were lit: the agreed shape (the effects layer and the map are written against it).
func feed() -> Array:
	var out: Array = []
	for id: String in _order:
		var t: Dictionary = trees[id]
		out.append({"id": id, "x_m": t["x_m"], "y_m": t["y_m"], "r_m": t["r_m"], "lit_turn": t["lit_turn"], "lit_t": t["lit_t"], "out_turn": t["out_turn"]})
	return out

func lit_count() -> int:
	return _order.size()

func record(id: String) -> Dictionary:
	return (trees[id] as Dictionary).duplicate() if trees.has(id) else {}

# Everything a joining machine needs, plain values (the snapshot's and the turn result's "fire").
func net_state() -> Dictionary:
	var list: Array = []
	for id: String in _order:
		list.append((trees[id] as Dictionary).duplicate())
	return {"trees": list}

func apply_net_state(d: Dictionary) -> void:
	trees.clear()
	_order.clear()
	_cells.clear()
	_max_r = 0.0
	for rec: Variant in (d.get("trees", []) as Array):
		var r: Dictionary = (rec as Dictionary).duplicate()
		_store(r)
	revision += 1

# Puts a tree on the lit list: the record has id, x_m, y_m, r_m (and kx, ky), and is given its turn and moment. Returns false if it is lit already.
# (resolve_turn calls this; a test or a late joiner may too.)
func add_lit(tree: Dictionary, lit_turn: int, lit_t: float, cause: String, from: String = "") -> bool:
	var id := str(tree["id"])
	if trees.has(id):
		return false
	var rec := {
		"id": id, "x_m": float(tree["x_m"]), "y_m": float(tree["y_m"]), "r_m": float(tree["r_m"]),
		"kx": int(tree.get("kx", 0)), "ky": int(tree.get("ky", 0)),
		"lit_turn": lit_turn, "lit_t": lit_t, "out_turn": rules.out_turn(lit_turn), "cause": cause, "from": from,
	}
	_store(rec)
	revision += 1
	return true

func _store(rec: Dictionary) -> void:
	var id := str(rec["id"])
	trees[id] = rec
	_order.append(id)
	_max_r = maxf(_max_r, float(rec["r_m"]))
	var c := _cell(float(rec["x_m"]), float(rec["y_m"]))
	if not _cells.has(c):
		_cells[c] = []
	(_cells[c] as Array).append(id)

static func _cell(x: float, y: float) -> Vector2i:
	return Vector2i(floori(x / CELL_M), floori(y / CELL_M))

# The lit trees whose centre is within `reach` of (x, y), in no particular order (nothing that asks depends on it).
func _near(x: float, y: float, reach: float) -> Array:
	var out: Array = []
	if trees.is_empty():
		return out
	var r2 := reach * reach
	var c0 := _cell(x - reach, y - reach)
	var c1 := _cell(x + reach, y + reach)
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var ids: Variant = _cells.get(Vector2i(cx, cy))
			if ids == null:
				continue
			for id: String in (ids as Array):
				var t: Dictionary = trees[id]
				var dx: float = float(t["x_m"]) - x
				var dy: float = float(t["y_m"]) - y
				if dx * dx + dy * dy <= r2:
					out.append(t)
	return out

# --- Time -------------------------------------------------------------------------------------------------------------

func game_time(turn: int, t: float) -> float:
	return float(turn - 1) * turn_seconds + t

# "As the world stands": the start of the turn being planned, the end of the turn just resolved (reveal.gd's now_s).
func now_s(world: Object) -> float:
	return game_time(int(world.turn), turn_seconds if str(world.phase) != "planning" else 0.0)

# The game second of `t` seconds into the world's turn (the last resolve's clock); t < 0: as the world stands.
func moment(world: Object, t: float) -> float:
	return game_time(int(world.turn), t) if t >= 0.0 else now_s(world)

func lit_s(rec: Dictionary) -> float:
	return game_time(int(rec["lit_turn"]), float(rec["lit_t"]))

func out_s(rec: Dictionary) -> float:
	return float(int(rec["out_turn"])) * turn_seconds

# Is the tree smoking (burning) at the game second?
func smoking(rec: Dictionary, time_s: float) -> bool:
	return time_s >= lit_s(rec) - EPS and time_s < out_s(rec) - EPS

# Has it burnt out by the game second (a trunk)?
func burnt_out(rec: Dictionary, time_s: float) -> bool:
	return time_s >= out_s(rec) - EPS

# --- The smoke ----------------------------------------------------------------------------------------------------------

# Is the point within smoke.reach_m of the canopy edge of a tree that is smoking at the game second?
func smoke_at(x_m: float, y_m: float, time_s: float) -> bool:
	var reach := rules.smoke_reach_m
	for t: Dictionary in _near(x_m, y_m, reach + _max_r):
		if not smoking(t, time_s):
			continue
		var d := Vector2(float(t["x_m"]) - x_m, float(t["y_m"]) - y_m).length()
		if d - float(t["r_m"]) <= reach:
			return true
	return false

# Does the smoke deny tracking of a unit of this definition standing at the point at the game second (the tracking rule is on, the unit's domain
# and mobility are listed, and it is in the smoke)?
func denies_tracking(def: Object, x_m: float, y_m: float, time_s: float) -> bool:
	return rules.smoke_applies(def) and smoke_at(x_m, y_m, time_s)

# --- Burnt cover ---------------------------------------------------------------------------------------------------------

# The share of the trees within burnt_cover.share_radius_m of the point that are NOT burnt out at the game second: 1 when none is (or the fire
# does not know the terrain's trees). Concealment multiplies the woods density by it.
func burnt_scale(x_m: float, y_m: float, time_s: float) -> float:
	var rad := rules.burnt_share_radius_m
	var burnt := 0
	for t: Dictionary in _near(x_m, y_m, rad):
		if burnt_out(t, time_s):
			burnt += 1
	if burnt == 0 or source == null:
		return 1.0
	var total: int = (source.trees_in_disc(x_m, y_m, rad) as Array).size()
	if total <= 0:
		return 1.0
	return clampf(1.0 - float(burnt) / float(total), 0.0, 1.0)

# --- The turn step -------------------------------------------------------------------------------------------------------

func _base(rng_seed: int) -> int:
	return (rng_seed & MASK32) ^ ((rng_seed >> 32) & MASK32)

# The seed of one roll: the game seed folded with the turn, the tag, the kind and the keys.
func _seed(rng_seed: int, turn: int, kind: int, keys: Array) -> int:
	var s := _base(rng_seed)
	for part: int in [turn, FIRE_TAG, kind]:
		s = Combat.mix32(s, part)
	for k: int in keys:
		s = Combat.mix32(s, k)
	return s

# One turn of the fire, on the HOST, after the turn's combat and crashes are known:
#   events   the turn's events so far (impacts and crashes among them, t ascending)
#   units    World.units (Unit objects, in World order: the dice are keyed by a unit's place in it)
#   sampler  Callable (unit id, t seconds) -> {x, y, ...} where the unit is at t this turn
# Returns {"events": the fire's events, t ascending (merge them in), "hurt": {unit id: {t, x, y, tree, pips, health, down}}}. The trees it lights
# and burns out change this state; the World applies `hurt` to the units.
func resolve_turn(turn: int, rng_seed: int, units: Dictionary, events: Array, sampler: Callable) -> Dictionary:
	var made: Array = []      # [t, rank, seq, event]
	var seq := 0
	# 1. IGNITION by the turn's blasts and crashes
	if source != null:
		var ordinal := 0
		var cmax: float = float(source.max_canopy_m())
		for ev: Variant in events:
			var e: Dictionary = ev
			var typ := str(e.get("type", ""))
			if not rules.ignite_events.has(typ):
				continue
			var radius := float(e.get(rules.ignite_radius_field, NAN))
			if is_nan(radius):
				radius = rules.crash_radius_m
			var ex := float(e["x"])
			var ey := float(e["y"])
			var et := float(e.get("t", 0.0))
			for tr: Dictionary in source.trees_in_disc(ex, ey, radius + cmax):
				if trees.has(str(tr["id"])):
					continue
				var edge := Vector2(float(tr["x_m"]) - ex, float(tr["y_m"]) - ey).length() - float(tr["r_m"])
				if edge > radius:
					continue
				var rng := Mulberry32.new(_seed(rng_seed, turn, KIND_IGNITE, [ordinal, int(tr["kx"]), int(tr["ky"])]))
				if rng.next() < rules.ignite_chance:
					var cause := typ.trim_suffix("_impact")
					add_lit(tr, turn, et, cause)
					made.append([et, RANK_IGNITE, seq, _ignite_event(turn, et, tr, cause, "")])
					seq += 1
			ordinal += 1
	# 2. SPREAD from the trees burning from an earlier turn (a tree lit in this turn spreads from the next, unless starts is same_turn)
	if source != null:
		var spreaders: Array = []
		for id: String in _order:
			var rec: Dictionary = trees[id]
			var from_ok := int(rec["lit_turn"]) < turn if rules.spread_starts == "next_turn" else int(rec["lit_turn"]) <= turn
			if from_ok and int(rec["out_turn"]) >= turn:
				spreaders.append(rec)
		var cmax2: float = float(source.max_canopy_m())
		for s: Dictionary in spreaders:
			var sx := float(s["x_m"])
			var sy := float(s["y_m"])
			for u: Dictionary in source.trees_in_disc(sx, sy, rules.spread_reach_m + float(s["r_m"]) + cmax2):
				var uid := str(u["id"])
				if trees.has(uid):
					continue
				var d := Vector2(float(u["x_m"]) - sx, float(u["y_m"]) - sy).length()
				var gap := d - float(s["r_m"]) - float(u["r_m"]) if rules.gap_measure == "canopy_edge" else d
				var p := rules.spread_p(gap)
				if p <= 0.0:
					continue
				var rng := Mulberry32.new(_seed(rng_seed, turn, KIND_SPREAD, [int(s["kx"]), int(s["ky"]), int(u["kx"]), int(u["ky"])]))
				if rng.next() < p:
					var lit_t := 0.0
					if rules.lit_t_mode == "seeded_in_turn":
						lit_t = Mulberry32.new(_seed(rng_seed, turn, KIND_LIT_T, [int(u["kx"]), int(u["ky"])])).next() * turn_seconds
					add_lit(u, turn, lit_t, "spread", str(s["id"]))
					made.append([lit_t, RANK_IGNITE, seq, _ignite_event(turn, lit_t, u, "spread", str(s["id"]))])
					seq += 1
	# 3. DAMAGE to the units near the trees that burn in this turn
	var hurt := {}
	var burning: Array = []
	for id: String in _order:
		var rec: Dictionary = trees[id]
		if int(rec["lit_turn"]) <= turn and int(rec["out_turn"]) >= turn:
			burning.append(rec)
	if not burning.is_empty():
		var index := 0
		for uid: String in units:
			var u: Object = units[uid]
			var i := index
			index += 1
			if bool(u.down) or int(u.health) <= 0 or not rules.hurts(u.def):
				continue
			var best := _most_exposed(uid, turn, burning, sampler)
			if best.is_empty():
				continue
			var rng := Mulberry32.new(_seed(rng_seed, turn, KIND_DAMAGE, [i]))
			if not (rng.next() < float(best["p"])):
				continue
			var pips := mini(rules.damage_pips, rules.max_pips_per_unit_turn)
			var health := maxi(int(u.health) - pips, 0)
			var bt := float(best["t"])
			var at: Vector2 = best["at"]
			hurt[uid] = {"t": bt, "x": at.x, "y": at.y, "tree": best["tree"], "pips": pips, "health": health, "down": health == 0}
			made.append([bt, RANK_DAMAGE, seq, {"type": "fire_damage", "turn": turn, "t": bt, "unit": uid, "x": at.x, "y": at.y, "tree": best["tree"]}])
			seq += 1
			made.append([bt, RANK_DAMAGE, seq, {"type": "hit", "turn": turn, "unit": uid, "by": "", "weapon": "fire", "t": bt, "damage": pips, "health": health}])
			seq += 1
			if health == 0:
				made.append([bt, RANK_DAMAGE, seq, {"type": "down", "turn": turn, "unit": uid, "by": "", "t": bt, "x": at.x, "y": at.y, "height_m": 0.0, "fate": "destroyed"}])
				seq += 1
	# 4. BURNING OUT at the end of the last burning turn
	for id: String in _order:
		var rec: Dictionary = trees[id]
		if int(rec["out_turn"]) == turn:
			made.append([turn_seconds, RANK_OUT, seq, {"type": "fire_out", "turn": turn, "t": turn_seconds, "tree": id, "x": rec["x_m"], "y": rec["y_m"]}])
			seq += 1
	made.sort_custom(func(a: Array, b: Array) -> bool:
		if a[0] != b[0]:
			return a[0] < b[0]
		if a[1] != b[1]:
			return a[1] < b[1]
		return a[2] < b[2])
	var out: Array = []
	for m: Array in made:
		out.append(m[3])
	return {"events": out, "hurt": hurt}

func _ignite_event(turn: int, t: float, tree: Dictionary, cause: String, from: String) -> Dictionary:
	var ev := {"type": "fire_ignite", "turn": turn, "t": t, "tree": str(tree["id"]), "x": float(tree["x_m"]), "y": float(tree["y_m"]), "cause": cause}
	if from != "":
		ev["from"] = from
	return ev

# The moment of the turn a unit is most exposed to the burning trees (its path sampled every damage.sample_s), and how: {t, p (the chance of a pip
# then, the trees combined as 1 - product(1 - p_i)), at (its place), tree (the id of the tree with the largest chance then)}; {} when it is never
# within reach of a burning canopy. Trees that are lit later in the turn count from their moment. The earliest moment wins a tie.
func _most_exposed(uid: String, turn: int, burning: Array, sampler: Callable) -> Dictionary:
	var n := maxi(1, ceili(turn_seconds / rules.damage_sample_s - EPS))
	var pts: Array = []
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for k in n + 1:
		var tk := turn_seconds * float(k) / float(n)
		var s: Dictionary = sampler.call(uid, tk)
		var p := Vector2(float(s["x"]), float(s["y"]))
		pts.append(p)
		lo = Vector2(minf(lo.x, p.x), minf(lo.y, p.y))
		hi = Vector2(maxf(hi.x, p.x), maxf(hi.y, p.y))
	var near: Array = []
	for t: Dictionary in burning:
		var reach := float(t["r_m"]) + rules.damage_reach_m
		if float(t["x_m"]) < lo.x - reach or float(t["x_m"]) > hi.x + reach or float(t["y_m"]) < lo.y - reach or float(t["y_m"]) > hi.y + reach:
			continue
		near.append(t)
	if near.is_empty():
		return {}
	var best_p := 0.0
	var best_edge := INF
	var best := {}
	for k in n + 1:
		var tk := turn_seconds * float(k) / float(n)
		var p: Vector2 = pts[k]
		var none := 1.0
		var top_p := 0.0
		var top_edge := INF
		var top_id := ""
		var min_edge := INF
		for t: Dictionary in near:
			if int(t["lit_turn"]) == turn and tk < float(t["lit_t"]) - EPS:
				continue
			var edge := Vector2(float(t["x_m"]) - p.x, float(t["y_m"]) - p.y).length() - float(t["r_m"])
			var pt := rules.damage_p(edge)
			if pt <= 0.0:
				continue
			min_edge = minf(min_edge, edge)
			none *= 1.0 - pt
			if pt > top_p or (pt == top_p and edge < top_edge):
				top_p = pt
				top_edge = edge
				top_id = str(t["id"])
		var pk := 1.0 - none
		# the most exposed moment: the largest chance; among moments of an equal chance (the chance is flat under a canopy) the one nearest a canopy's
		# edge or deepest under it -- the closest approach
		if pk > best_p + EPS or (pk > 0.0 and absf(pk - best_p) <= EPS and min_edge < best_edge - EPS):
			best_p = pk
			best_edge = min_edge
			best = {"t": tk, "p": pk, "at": p, "tree": top_id}
	return best
