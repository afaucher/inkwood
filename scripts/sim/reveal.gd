extends RefCounted

# REVEAL ON FIRING (Track M2L, PROPOSED 2026-10-11: the second mission, "clear the mobile AA and their escorts to enable a bombing
# run of a military complex"). The lead's idea, not Alex's (decision suppress-mission): the guns are hidden, they move, and they GIVE
# THEMSELVES AWAY WHEN THEY FIRE -- the Wild Weasels baited guns over Vietnam. The numbers are data/sim/reveal.json; this is the rule.
#
#   var rv := Reveal.of(world)                       # the one of a World, made and attached on first use
#   rv.marks("allies", now)                          # what the allies have been shown of the guns that fired at them
#   rv.is_revealed("mobile_aa_1", "allies", now)     # is that gun revealed to them at game second `now`
#   rv.net_state() / rv.apply_net_state(d)           # for a joining client (scripts/net/world_sync.gd snapshot)
#
# THE RULE. A ground unit that FIRES (a "fire" event of the resolved turn, hit or miss, scripts/sim/combat.gd) is revealed to the side it
# fired at, from the moment of the shot: for reveal_s seconds of GAME TIME the side sees the place the shot came from (the fog opens a
# patch of radius_m round it: scripts/render/fog_vision.gd; the enemy AI knows the unit there: scripts/sim/ai_sense.gd) and a "last seen"
# mark is drawn there; for fade_s more seconds the mark stays, fading, and nothing is seen. Which units give themselves away is data
# (shooter_domains, shooter_mobility): mobile ground units, not the Strike's static batteries.
#
# GAME TIME. A moment is game seconds from the start of the game: (turn - 1) x turn_seconds + t, t the seconds into that turn
# (World.sample's clock). A shot at t = 3.2 of turn 4 is second 18.2. A query at a moment BEFORE a shot does not see it, so the playback of
# a turn shows a gun at the moment it fires and not before. Reveal.now_s(world) is "as the world stands": the start of the turn being
# planned, or the end of the turn just resolved.
#
# WHERE IT COMES FROM. Only the events of the turn each machine already has (World emits turn_resolved with the same events on the host,
# which resolves, and on a client, which applies the host's result), so nothing new crosses the wire for the turns a machine sees. A
# machine that JOINS in the middle of a game missed the events, so the snapshot carries net_state(); deterministic, host-resolved,
# the same on every machine (the shots are positions the combat resolver computed, copied as they are).
#
# A record per (gun, side it fired at): {unit, to, type, side, shots: [[first, x, y, heading, last], ...]}: a list of BURSTS (the latest
# max_shots of them), a burst being the shots of one gun at one place with less than shot_gap_s between them -- game seconds of its first and
# its last shot, and the place and heading of the last (flak rolls four times a second; what the fog needs is where the gun was and when). last_fire (unit -> {turn, time}) is kept for any unit that is allowed to give itself away, whoever it fired at: the
# roam AI (scripts/sim/ai_roam.gd) reads it to know that its gun has fired.
#
# The World is held WEAKLY (a World keeps its Reveal in its meta, and a World is freed when nothing else holds it).

const Records = preload("res://scripts/sim/records.gd")

const PATH := "res://data/sim/reveal.json"
const META := "reveal"

var reveal_s: float = NAN
var fade_s: float = NAN
var radius_m: float = NAN
var shooter_domains: Array[String] = []
var shooter_mobility: Array[String] = []
var max_shots: int = 0
var shot_gap_s: float = NAN
var same_place_m: float = NAN
var ghost_ring_px: float = NAN
var ghost_line_px: float = NAN
var ghost_alpha: float = NAN
var ghost_label: String = ""
var errors: Array[String] = []

var records: Dictionary = {}       # "unit|side" -> record (see above)
var last_fire: Dictionary = {}     # unit id -> {turn, time}
var turn_seconds: float = 5.0

var _world: WeakRef = null

# The Reveal of a World: made on first use and attached (it listens to turn_resolved from then on). Pass the World as it is built (the
# scenario's populate() and the sync node do), or any time: a Reveal made late has only the turns that resolve after it.
static func of(w: Object) -> RefCounted:
	if w == null or not w.has_signal("turn_resolved"):
		return null      # (not a World: a stand-in a test hands the fog has nothing to remember)
	if w.has_meta(META):
		return w.get_meta(META)
	var made: RefCounted = (load("res://scripts/sim/reveal.gd") as GDScript).new()
	made.attach(w)
	w.set_meta(META, made)
	return made

func _init(source: Variant = PATH, quiet: bool = false) -> void:
	var label := str(source) if source is String else "<reveal dictionary>"
	var r := Records.new(label, quiet)
	var data: Variant = null
	if source is String:
		data = r.read_json(source)
	elif source is Dictionary:
		data = source
	else:
		r.err("a reveal source is a path or a Dictionary, got %s" % type_string(typeof(source)))
	if data is Dictionary:
		var d: Dictionary = data
		reveal_s = r.number(d, "reveal_s", "reveal_s", 0.0)
		fade_s = r.number(d, "fade_s", "fade_s", 0.0)
		radius_m = r.number(d, "radius_m", "radius_m", 1.0)
		shooter_domains = _strings(r, d, "shooter_domains")
		shooter_mobility = _strings(r, d, "shooter_mobility")
		max_shots = r.integer(d, "max_shots", "max_shots", 1)
		shot_gap_s = r.number(d, "shot_gap_s", "shot_gap_s", 0.0)
		same_place_m = r.number(d, "same_place_m", "same_place_m", 0.0)
		var g := r.section(d, "ghost", "ghost")
		ghost_ring_px = r.number(g, "ring_px", "ghost.ring_px", 1.0)
		ghost_line_px = r.number(g, "line_px", "ghost.line_px", 0.1)
		ghost_alpha = r.number(g, "alpha_revealed", "ghost.alpha_revealed", 0.0, 1.0)
		var lv: Variant = r.record(g, "label", "ghost.label")
		ghost_label = str(lv) if lv is String else ""
		for key: Variant in d:
			var k := str(key)
			if not k.begins_with("_") and not ["reveal_s", "fade_s", "radius_m", "shooter_domains", "shooter_mobility", "max_shots", "shot_gap_s", "same_place_m", "ghost"].has(k):
				r.err("unknown field '%s' (misspelt?)" % k)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

static func _strings(r: Records, d: Dictionary, key: String) -> Array[String]:
	var out: Array[String] = []
	var v: Variant = r.record(d, key, key)
	if typeof(v) == TYPE_NIL:
		return out
	if not (v is Array) or (v as Array).is_empty():
		r.err("'%s' must be a non-empty list of text" % key)
		return out
	for item: Variant in v:
		if item is String and str(item) != "":
			out.append(str(item))
		else:
			r.err("'%s' has an entry that is not text: %s" % [key, str(item)])
	return out

# --- Attaching -----------------------------------------------------------------------------------

func attach(w: Object) -> void:
	_world = weakref(w)
	turn_seconds = float(w.rules.turn_seconds)
	if not w.turn_resolved.is_connected(_on_turn_resolved):
		w.turn_resolved.connect(_on_turn_resolved)

func detach() -> void:
	var w: Object = _world.get_ref() if _world != null else null
	if w != null and w.turn_resolved.is_connected(_on_turn_resolved):
		w.turn_resolved.disconnect(_on_turn_resolved)

func clear() -> void:
	records.clear()
	last_fire.clear()

# --- Time ------------------------------------------------------------------------------------------

# Game seconds of the moment `t` seconds into turn `turn`.
func game_time(turn: int, t: float) -> float:
	return float(turn - 1) * turn_seconds + t

# "Now" as the world stands: the start of the turn being planned, the end of the one just resolved.
func now_s(w: Object) -> float:
	return game_time(int(w.turn), turn_seconds if str(w.phase) != "planning" else 0.0)

# --- The rule ----------------------------------------------------------------------------------------

# Does a unit of this type give itself away when it fires? (shooter_domains and shooter_mobility)
func gives_away(def: Object) -> bool:
	return shooter_domains.has(str(def.domain)) and shooter_mobility.has(str(def.mobility))

func _on_turn_resolved(turn: int, _histories: Dictionary, events: Array) -> void:
	var w: Object = _world.get_ref() if _world != null else null
	if w == null or not ok():
		return
	for ev: Variant in events:
		var e: Dictionary = ev
		if str(e.get("type", "")) != "fire":
			continue
		var uid := str(e.get("unit", ""))
		var tid := str(e.get("target", ""))
		if not w.units.has(uid) or not w.units.has(tid):
			continue
		var shooter: Object = w.units[uid]
		var target: Object = w.units[tid]
		if str(shooter.side) == str(target.side) or not gives_away(shooter.def):
			continue
		var tm := game_time(turn, float(e["t"]))
		var prev: Dictionary = last_fire.get(uid, {})
		if prev.is_empty() or tm >= float(prev["time"]):
			last_fire[uid] = {"turn": turn, "time": tm}
		var key := "%s|%s" % [uid, str(target.side)]
		var rec: Dictionary = records.get(key, {"unit": uid, "to": str(target.side), "type": str(shooter.type), "side": str(shooter.side), "shots": []})
		var heading := float(shooter.heading)
		var at: Dictionary = w.sample(uid, float(e["t"]), "history")
		if at.has("heading"):
			heading = float(at["heading"])
		var shots: Array = rec["shots"]
		var sx := float(e["x"])
		var sy := float(e["y"])
		var burst: Array = shots[shots.size() - 1] if not shots.is_empty() else []
		if not burst.is_empty() and tm - float(burst[4]) < shot_gap_s and Vector2(sx, sy).distance_to(Vector2(float(burst[1]), float(burst[2]))) <= same_place_m:
			burst[1] = sx
			burst[2] = sy
			burst[3] = heading
			burst[4] = tm
		else:
			shots.append([tm, sx, sy, heading, tm])
		while shots.size() > max_shots:
			shots.pop_front()
		records[key] = rec
	_prune(game_time(turn, turn_seconds))

# Forget shots that can no longer be seen (older than reveal_s + fade_s at the end of the turn just resolved).
func _prune(time_s: float) -> void:
	for key: Variant in records.keys():
		var rec: Dictionary = records[key]
		var shots: Array = rec["shots"]
		while not shots.is_empty() and time_s - float((shots[0] as Array)[4]) > reveal_s + fade_s + turn_seconds:
			shots.pop_front()
		if shots.is_empty():
			records.erase(key)

# --- The queries -------------------------------------------------------------------------------------------

# What `to_side` has been shown at game second `time_s`, one entry per gun, in the order the guns first fired:
#   {unit, type, side (the gun's), x, y, heading (where it stood at its latest shot at or before time_s), shot_s (when),
#    age_s (since that shot; 0 while it is still firing), revealed (age <= reveal_s: the fog is open there), alpha (1 while revealed, then falling to 0 over fade_s)}
# A gun that is down is not shown, from the moment it went down (a ruin is the effects layer's). A shot that has not happened yet at
# `time_s` (the playback of a turn is part way through it) is not seen.
func marks(to_side: String, time_s: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var w: Object = _world.get_ref() if _world != null else null
	for key: Variant in records:
		var rec: Dictionary = records[key]
		if str(rec["to"]) != to_side:
			continue
		var shot := _shot_at(rec, time_s)
		if shot.is_empty():
			continue
		var age := maxf(time_s - float(shot[4]), 0.0)    # (inside a burst the gun is firing now: age 0)
		if age > reveal_s + fade_s:
			continue
		if w != null and w.units.has(str(rec["unit"])) and _gone(w, w.units[str(rec["unit"])], time_s):
			continue
		var revealed := age <= reveal_s
		out.append({
			"unit": str(rec["unit"]), "type": str(rec["type"]), "side": str(rec["side"]),
			"x": float(shot[1]), "y": float(shot[2]), "heading": float(shot[3]),
			"shot_s": minf(float(shot[4]), time_s), "age_s": age, "revealed": revealed,
			"alpha": 1.0 if revealed else clampf(1.0 - (age - reveal_s) / maxf(fade_s, 1e-6), 0.0, 1.0),
		})
	return out

func _gone(w: Object, u: Object, time_s: float) -> bool:
	if not bool(u.down):
		return false
	var da := float(u.down_at)
	if is_nan(da):
		return true
	# down_at is seconds into the LAST RESOLVED turn: this one while it plays back, the one before while the next is planned
	var resolved := int(w.turn) - (1 if str(w.phase) == "planning" else 0)
	return time_s >= float(resolved - 1) * turn_seconds + da

# The latest burst of the record that began at or before `time_s`, or [].
static func _shot_at(rec: Dictionary, time_s: float) -> Array:
	var best: Array = []
	for s: Variant in (rec["shots"] as Array):
		if float((s as Array)[0]) <= time_s + 1e-9:
			best = s
	return best

func is_revealed(unit_id: String, to_side: String, time_s: float) -> bool:
	for m: Dictionary in marks(to_side, time_s):
		if str(m["unit"]) == unit_id and bool(m["revealed"]):
			return true
	return false

# The turn of the unit's latest shot (-1: it has not fired since the game began, or it is not a unit that gives itself away).
func last_fire_turn(unit_id: String) -> int:
	return int((last_fire.get(unit_id, {}) as Dictionary).get("turn", -1))

# --- The wire -----------------------------------------------------------------------------------------------

# Everything a joining machine needs, as plain values (the snapshot's "reveal").
func net_state() -> Dictionary:
	return {"records": records.duplicate(true), "last_fire": last_fire.duplicate(true)}

func apply_net_state(d: Dictionary) -> void:
	records = (d.get("records", {}) as Dictionary).duplicate(true)
	last_fire = (d.get("last_fire", {}) as Dictionary).duplicate(true)
