extends RefCounted

# WORLDS FOR THE STRIKE'S TESTS (Track S2, 2026-10-10): a bomber, a radio tower, batteries; and bomb
# records to drop straight into a World's bombs_in_flight, so a test can put a blast exactly where it
# wants one (the same carried-bomb mechanism a real drop uses across turns). Not a test: the gate does
# not run scripts/test_support/.
#
#   var w := BombWorlds.world(seed_value)             # tower at (2500, 2500), a player bomber far west, no batteries
#   BombWorlds.drop_bombs(w, [BombWorlds.record(w, 2500.0, 2500.0, 2.0)])   # a bomb that lands at t = 2 s of this turn
#   var res := BombWorlds.turn(w)

const World = preload("res://scripts/sim/world.gd")

const TOWER := Vector2(2500.0, 2500.0)

# The bomber `bomber` (player, allies, 8 pips) at (400, 2500) heading east at cruise in `band`; the radio
# tower `tower` (axis, AI) at TOWER; and, if `batteries`, the two anti-aircraft batteries `aa0` and `aa1`.
static func world(seed_value: int = 1, band: String = "medium", batteries: bool = false) -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "bomber", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": TOWER.y, "heading": 0.0, "altitude_band": band, "speed": 85.0})
	w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": TOWER.x, "y": TOWER.y, "heading": 0.0})
	if batteries:
		w.add_unit({"id": "aa0", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2250.0, "y": 2200.0, "heading": 0.0})
		w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2800.0, "y": 2800.0, "heading": 0.0})
	return w

# A bomb record (scripts/sim/bombs.gd header) for a bomb of `bomber` that lands at (x, y) at second
# `impact_t` of the turn the world is on (it was released earlier, the same turn).
static func record(w: World, x: float, y: float, impact_t: float, index: int = 0, by: String = "bomber") -> Dictionary:
	return {
		"id": "%s/%d/0/%d" % [by, w.turn, index], "unit": by, "drop_index": 0, "bomb": index,
		"release_turn": w.turn, "release_t": 0.0, "x0": x, "y0": y, "h0": 400.0, "x": x, "y": y, "fall_s": impact_t,
		"impact_turn": w.turn, "impact_t": impact_t,
	}

static func drop_bombs(w: World, records: Array) -> void:
	w.bombs_in_flight.append_array(records)

# Commit and resolve the turn being planned; {} if it did not resolve.
static func turn(w: World) -> Dictionary:
	w.commit("local")
	return w.resolve()

static func events_of(res: Dictionary, type: String, unit: String = "") -> Array:
	var out: Array = []
	for ev: Dictionary in res.get("events", []):
		if ev["type"] == type and (unit == "" or ev.get("unit") == unit):
			out.append(ev)
	return out
