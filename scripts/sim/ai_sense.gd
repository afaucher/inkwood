extends RefCounted

# What the AI knows of the other side (Track E, proposed): FOG FOR THE AI. A
# unit of another side is KNOWN while it is inside sight_range_m (data/units, a
# circle, no line of sight this pass) of any living AI-controlled unit. Outside
# sight the AI keeps the unit's LAST SEEN state for `memory_turns` turns and then
# forgets it ("the last seen position, or nothing"). A unit seen down is
# dropped. Down status of an unseen unit is never read.
#
# It reads only a unit's public state: x, y, heading, speed, altitude_band, type,
# side, down. NEVER a plan, a preview or a history -- those are not the AI's
# knowledge (Alex: players never learn the enemy's plans, so the AI must not
# read the players').
#
# An entry: {id, type, side, x, y, heading, speed, altitude_band, turn (the
# turn it was last seen), visible (seen THIS turn)}. update() is idempotent
# within a turn: calling it twice on the same world state changes nothing.
#
# Proposed limit: one AI side. An entry is keyed by the other unit's id, and
# every AI-controlled unit is an observer for all of them.
#
# SIGHT FOLLOWS THE PILOT (Alex, 2026-10-10, for the player's fog; proposed here
# for the AI so both sides agree): an observer's radius is sight_rules.gd's, the
# state as it stands at the planning phase. A live unit sees sight_range_m as
# before; an exploded or destroyed unit (a tower, a battery) and a crashed plane
# see nothing; a plane that is down out of control and still falling keeps a
# reduced radius that shrinks with its height (data/sim/sight.json). A unit that
# was not an observer because it was down is still not one, unless it is falling.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const SightRules = preload("res://scripts/sim/sight_rules.gd")
const RevealRules = preload("res://scripts/sim/reveal.gd")
const ConcealRules = preload("res://scripts/sim/concealment.gd")

# REVEAL ON FIRING (Track M2L, PROPOSED; scripts/sim/reveal.gd): a unit of another side that FIRED at this one's side is known at the
# place of its shot while it is revealed (data/sim/reveal.json reveal_s), whether or not it is inside any sight circle -- the same
# rule the player's fog follows, so both sides are shown the same thing. After that the usual memory applies.

var seen: Dictionary = {}     # unit id -> entry
var _rules: SightRules = null  # data/sim/sight.json, read on the first update

func clear() -> void:
	seen.clear()

# Observe the world as it stands now (call once per planning phase).
func update(world: World, memory_turns: int) -> void:
	if _rules == null:
		_rules = SightRules.new()
	var observers: Array = []     # [unit, the radius it sees to now, metres]
	for id: String in world.units:
		var o: Unit = world.units[id]
		if o.controller != World.CONTROLLER_AI:
			continue
		var r := _rules.radius_m(o, o.def.sight_range_m)
		if o.down and r <= 0.0:
			continue
		observers.append([o, r])
	# the guns that fired at the AI's side and are still revealed: unit id -> Reveal.marks entry
	var revealed := {}
	var rv: Variant = RevealRules.of(world)
	if rv != null and rv.ok():
		var asked := {}
		for ob: Array in observers:
			var oside: String = (ob[0] as Unit).side
			if asked.has(oside):
				continue
			asked[oside] = true
			for m: Dictionary in rv.marks(oside, rv.now_s(world)):
				if bool(m["revealed"]):
					revealed[str(m["unit"])] = m
	for id: String in world.units:
		var t: Unit = world.units[id]
		if t.controller == World.CONTROLLER_AI:
			continue
		var spotted := false
		var shot: Dictionary = {}
		# CONCEALMENT (Track M2L, proposed; scripts/sim/concealment.gd): a unit in cover is seen only inside the rule's radius, whatever the sight
		var cover_limit: float = ConcealRules.shared().sight_limit_m(world, t, t.x, t.y, INF)
		for ob: Array in observers:
			var o: Unit = ob[0]
			if o.side == t.side:
				continue
			var dx := t.x - o.x
			var dy := t.y - o.y
			var r: float = minf(float(ob[1]), cover_limit)
			if dx * dx + dy * dy <= r * r:
				spotted = true
				break
		if not spotted and revealed.has(id):
			# fired at the AI's side: known where the shot came from (and not moving: a gun that has just fired)
			shot = revealed[id]
			spotted = true
		if spotted:
			if t.down:
				seen.erase(id)
			elif not shot.is_empty():
				seen[id] = {
					"id": id, "type": t.type, "side": t.side,
					"x": float(shot["x"]), "y": float(shot["y"]), "heading": float(shot["heading"]), "speed": 0.0,
					"altitude_band": t.altitude_band,
					"turn": world.turn, "visible": true,
				}
			else:
				seen[id] = {
					"id": id, "type": t.type, "side": t.side,
					"x": t.x, "y": t.y, "heading": t.heading, "speed": t.speed,
					"altitude_band": t.altitude_band,
					"turn": world.turn, "visible": true,
				}
		elif seen.has(id):
			var e: Dictionary = seen[id]
			if world.turn - int(e["turn"]) > memory_turns:
				seen.erase(id)
			else:
				e["visible"] = false
	# A unit that left the world is forgotten too.
	for id: Variant in seen.keys():
		if not world.units.has(id):
			seen.erase(id)

# The entry for a unit id (a copy), or {} if unknown.
func entry(id: String) -> Dictionary:
	var e: Variant = seen.get(id)
	return (e as Dictionary).duplicate() if e is Dictionary else {}

func knows(id: String) -> bool:
	return seen.has(id)

func is_visible(id: String) -> bool:
	var e: Variant = seen.get(id)
	return e is Dictionary and (e as Dictionary).get("visible", false) == true

# Entries seen this turn, in id order.
func visible_enemies() -> Array[Dictionary]:
	return _sorted(true)

# Every entry the AI still remembers (seen this turn or kept), in id order.
func known_enemies() -> Array[Dictionary]:
	return _sorted(false)

func _sorted(visible_only: bool) -> Array[Dictionary]:
	var ids: Array[String] = []
	for id: Variant in seen:
		var e: Dictionary = seen[id]
		if not visible_only or e.get("visible", false) == true:
			ids.append(str(id))
	ids.sort()
	var out: Array[Dictionary] = []
	for id: String in ids:
		out.append((seen[id] as Dictionary).duplicate())
	return out
