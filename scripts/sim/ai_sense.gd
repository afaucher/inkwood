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

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")

var seen: Dictionary = {}     # unit id -> entry

func clear() -> void:
	seen.clear()

# Observe the world as it stands now (call once per planning phase).
func update(world: World, memory_turns: int) -> void:
	var observers: Array = []
	for id: String in world.units:
		var o: Unit = world.units[id]
		if o.controller == World.CONTROLLER_AI and not o.down:
			observers.append(o)
	for id: String in world.units:
		var t: Unit = world.units[id]
		if t.controller == World.CONTROLLER_AI:
			continue
		var spotted := false
		for o: Unit in observers:
			if o.side == t.side:
				continue
			var dx := t.x - o.x
			var dy := t.y - o.y
			var r := o.def.sight_range_m
			if dx * dx + dy * dy <= r * r:
				spotted = true
				break
		if spotted:
			if t.down:
				seen.erase(id)
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
