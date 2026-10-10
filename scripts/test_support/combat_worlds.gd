extends RefCounted

# WORLDS IN WHICH A UNIT IS SHOT DOWN, for the tests of what the interface shows of combat
# (Track U2). Not a test: the gate does not run scripts/test_support/. Built the way
# scripts/tests/test_combat_fall.gd builds its worlds (a "bomber" ahead of a "fighter" that
# shoots at it, both flying straight and level), with the seed FOUND for the fate wanted rather
# than written down, so a retune of the combat data moves the test with it.
#
#   var seed_value := CombatWorlds.find_seed("out_of_control")
#   var w := CombatWorlds.world(seed_value)
#   var res := CombatWorlds.turn(w)           # commit and resolve: -> the resolve result
#   CombatWorlds.event_of(res, "down", "bomber")

const World = preload("res://scripts/sim/world.gd")

# The victim "bomber" (health pips as given, a 1-pip victim is shot down at once) flies at
# 85 m/s in `band`; the "fighter" 300 m behind it, 99 pips, at the same speed and height.
static func world(seed_value: int, victim_health: int = 1, band: String = "medium", victim_type: String = "bomber") -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "bomber", "type": victim_type, "side": "axis", "controller": "player", "x": 1500.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": band})
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1200.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": band})
	w.units["bomber"].health = victim_health
	w.units["fighter"].health = 99
	return w

# Commit and resolve the turn being planned; {} if it did not resolve.
static func turn(w: World) -> Dictionary:
	w.commit("local")
	return w.resolve()

static func event_of(res: Dictionary, type: String, unit: String = "bomber") -> Dictionary:
	for ev: Dictionary in res.get("events", []):
		if ev["type"] == type and ev.get("unit") == unit:
			return ev
	return {}

static func events_of(res: Dictionary, type: String, unit: String = "bomber") -> Array:
	var out: Array = []
	for ev: Dictionary in res.get("events", []):
		if ev["type"] == type and ev.get("unit") == unit:
			out.append(ev)
	return out

# The first seed in which the 1-pip victim goes down with `fate` between t_min and t_max seconds
# into turn 1 (so there is flight before it and fall or nothing after). -1 if none.
static func find_seed(fate: String, band: String = "medium", t_min: float = 0.8, t_max: float = 3.6) -> int:
	for s in range(1, 400):
		var w := world(s, 1, band)
		var ev := event_of(turn(w), "down")
		if not ev.is_empty() and ev["fate"] == fate and float(ev["t"]) >= t_min and float(ev["t"]) <= t_max:
			return s
	return -1

# The first seed in which the victim, with `pips` pips, is hit in turn 1 (between t_min and
# t_max) and is not shot down in it. -1 if none.
static func find_hit_seed(pips: int = 8, t_min: float = 0.6, t_max: float = 3.6) -> int:
	for s in range(1, 400):
		var w := world(s, pips)
		var res := turn(w)
		if not event_of(res, "down").is_empty():
			continue
		var hits := events_of(res, "hit")
		if hits.is_empty():
			continue
		if float((hits[0] as Dictionary)["t"]) >= t_min and float((hits[0] as Dictionary)["t"]) <= t_max:
			return s
	return -1

# One frame of a playback as the host's frames run it: the marker layer advances, then UnitUI
# fires the events the clock passed and tells the effects.
static func step(ui: Node, dt: float) -> void:
	ui.marker_layer.advance_playback(dt)
	ui.poll_playback()

# Play the running playback to its end in steps of dt (the UnitUI hands over to the next turn
# by itself when auto_begin_turn is on).
static func play_out(ui: Node, dt: float = 1.0 / 30.0) -> void:
	var guard := 0
	while ui.marker_layer.is_playing() and guard < 4000:
		step(ui, dt)
		guard += 1
