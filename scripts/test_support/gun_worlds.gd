extends RefCounted

# WORLDS FOR THE WARSHIP'S TESTS (Track SH, the warship, 2026-10-10): a small cruiser parked off a straight coast, a friendly
# radio tower inland that sees for it, an enemy anti-aircraft battery on the coast to shoot at. Not a test: the gate does not run
# scripts/test_support/.
#
#   var w := GunWorlds.world(seed)            # the cruiser `cruiser` (allies, player) at SHIP, a tower `spotter` (allies) at SPOTTER,
#                                             # a battery `aa` (axis, ai) at TARGET, water west of COAST_X
#   GunWorlds.fire(w, "aa")                   # plan the cruiser's step 0 to fire at the unit, return the step's state
#   var res := GunWorlds.turn(w)              # commit and resolve; {} if it did not
#
# The geometry (metres): the sea is x < COAST_X (deep to the west, a sloping shelf at the shore: the depth is (COAST_X - x) / 2, so
# a 6 m draught is afloat from 12 m off the shore, and its 60 m ends keep it out to about 130 m), the land is x >= COAST_X. The
# cruiser lies at 1200 m from the target; the tower sees 500 m, so the battery and what is round it are SPOTTED, and the cruiser
# (1000 m of sight) does not see them itself.

const World = preload("res://scripts/sim/world.gd")

const COAST_X := 1700.0
const SHIP := Vector2(600.0, 2500.0)
const TARGET := Vector2(1800.0, 2500.0)       # on the coast, 100 m inland, 1200 m from the ship
const SPOTTER := Vector2(2000.0, 2500.0)      # 200 m behind the target: it sees it (sight 500 m) and the cruiser does not (1000 m)

# The sea as a depth query: metres of water, 0 or less on land.
static func depth(x: float, _y: float) -> float:
	return clampf((COAST_X - x) * 0.5, -10.0, 200.0)

static func world(seed_value: int = 1, with_water: bool = true) -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	if with_water:
		w.set_water(func(x: float, y: float) -> float: return depth(x, y))
	w.add_unit({"id": "cruiser", "type": "cruiser", "side": "allies", "controller": "player", "x": SHIP.x, "y": SHIP.y, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "spotter", "type": "radio_tower", "side": "allies", "controller": "player", "x": SPOTTER.x, "y": SPOTTER.y, "heading": 0.0})
	w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": TARGET.x, "y": TARGET.y, "heading": 0.0})
	return w

# Plan step 0 of the cruiser to fire its main guns at `unit` (a unit id) or a point; the step's state ({} if refused).
static func fire(w: World, target: Variant, step: int = 0) -> Dictionary:
	var t: Dictionary = {"unit": target} if target is String else {"point": [(target as Vector2).x, (target as Vector2).y]}
	return w.plan_step("cruiser", step, {"fire": {"special": "main_guns", "target": t}})

static func turn(w: World) -> Dictionary:
	w.commit("local")
	if w.participants().has(World.AI_PLAYER):
		w.commit(World.AI_PLAYER)
	return w.resolve()

# Commit, resolve and begin the next turn; the result.
static func next_turn(w: World) -> Dictionary:
	var res := turn(w)
	if not res.is_empty():
		w.begin_turn()
	return res

static func events_of(res: Dictionary, type: String, unit: String = "") -> Array:
	var out: Array = []
	for ev: Dictionary in res.get("events", []):
		if ev["type"] == type and (unit == "" or ev.get("unit") == unit):
			out.append(ev)
	return out
