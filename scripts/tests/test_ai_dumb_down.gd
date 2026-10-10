extends "res://scripts/test_support/test_case.gd"

# The sandbox's dumb AI with a downed unit: it plans the units that are up,
# leaves the downed one alone (combat refuses its orders), and still readies,
# so the turn resolves -- also when every AI unit is down.

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const Unit = preload("res://scripts/sim/unit.gd")

func setup(_main) -> void:
	var w := World.new()
	w.add_player("local")
	var a := w.add_unit({"type": "bomber", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	var b := w.add_unit({"type": "light_fighter", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2000.0, "heading": 0.0})
	var down: Unit = w.units[a]
	down.health = 0
	down.down = true
	down.fate = Unit.FATE_EXPLODED
	w.quiet = true
	var ai := AiDumb.new(w)
	ai.plan_turn()
	eq(w.last_error, "", "the AI asks nothing of the downed unit")
	check(w.is_ready(World.AI_PLAYER), "the AI readies with one unit down")
	check((w.units[b] as Unit).plan.size() > 0, "the unit that is up is planned")

	var w2 := World.new()
	w2.add_player("local")
	var c := w2.add_unit({"type": "bomber", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	(w2.units[c] as Unit).down = true
	(w2.units[c] as Unit).fate = Unit.FATE_EXPLODED
	w2.quiet = true
	AiDumb.new(w2).plan_turn()
	check(w2.is_ready(World.AI_PLAYER), "the AI readies even when every AI unit is down")
	check(w2.commit("local"), "so the turn can resolve")
	finish()
