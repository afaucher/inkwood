extends RefCounted

# The demo's dumb AI (exit criterion 2: "The AI may be as dumb as it likes, but
# it flies on its own"). Each planning phase, for every AI-controlled unit:
# fly straight at cruise speed; if the unit is within a margin of the map edge,
# now or at the end of this turn flying straight, turn toward the map centre
# instead -- as hard as the envelope allows, step by step, until it points
# there. That is all. The design doc's Enemy AI (mission goals, patrol, engage,
# disengage; execution plan component 14) replaces it.
#
# A STATIC unit (a radio tower, a battery: data/units mobility "static") is skipped -- it has no plan to
# make and does not hold up the ready-up (World.participants()); the AI readies only for mobile units.
#
# IT USES ONLY THE WORLD'S PUBLIC API -- units, bounds, phase, steps_per_turn,
# clear_plan, plan_step, reachable, commit and the phase_changed signal --
# exactly what a player's UI uses, so the AI cannot do anything a player
# could not. It readies itself (World.AI_PLAYER) when its plans are in.
#
# The margin is in TURN RADII at the unit's current speed (data/sim/
# ai_dumb.json, proposed): turning back from an edge met head-on needs one
# radius of forward room, and a bomber's radius is twice a fighter's.
#
#   var ai := AiDumb.new(world)
#   ai.attach()          # plans now if the world is planning, and every turn after

const World = preload("res://scripts/sim/world.gd")
const Records = preload("res://scripts/sim/records.gd")
const JsMath = preload("res://scripts/core/js_math.gd")

const DATA_PATH := "res://data/sim/ai_dumb.json"

var world: World
var edge_margin_turn_radii: float = NAN
var errors: Array[String] = []

func _init(target: World, data_path: String = DATA_PATH) -> void:
	world = target
	var r := Records.new(data_path)
	var d: Variant = r.read_json(data_path)
	if d is Dictionary:
		edge_margin_turn_radii = r.number(d, "edge_margin_turn_radii", "edge_margin_turn_radii", 0.0)
	errors = r.errors

func ok() -> bool:
	return errors.is_empty()

func attach() -> void:
	if not world.phase_changed.is_connected(_on_phase_changed):
		world.phase_changed.connect(_on_phase_changed)
	if world.phase == World.PHASE_PLANNING:
		plan_turn()

func _on_phase_changed(phase: String) -> void:
	if phase == World.PHASE_PLANNING:
		plan_turn()

# Plan every AI unit, then ready up.
func plan_turn() -> void:
	var any := false
	for id: String in world.units:
		if world.units[id].controller != World.CONTROLLER_AI:
			continue
		# A static unit (a tower, a battery) has no plan to make and does not hold up the turn.
		if world.units[id].def.is_static():
			continue
		any = true
		# A down unit takes no orders (combat: plan_step refuses it); the AI
		# still readies, or a game whose AI units are all down never resolves.
		if world.units[id].down:
			continue
		_plan_unit(id)
	if any:
		world.commit(World.AI_PLAYER)

func _plan_unit(id: String) -> void:
	var u: Variant = world.units[id]
	var cruise: float = u.def.envelope.speed_cruise
	var n := world.steps_per_turn(id)
	world.clear_plan(id)

	# Straight at cruise: where does that leave it?
	var end: Dictionary = {}
	for i in n:
		end = world.plan_step(id, i, {"turn": 0.0, "speed": cruise})
	var radius: float = world.reachable(id, 0).get("turn_radius", INF)
	var margin := edge_margin_turn_radii * radius
	if _edge_distance(u.x, u.y) >= margin and _edge_distance(float(end["x"]), float(end["y"])) >= margin:
		return

	# Near an edge: turn toward the centre, step by step from where each step
	# leaves it. Asking for the whole angle lets the envelope cut it to the most
	# the plane can turn; once it points at the centre the request is ~0.
	var c := world.bounds_center()
	var at := {"x": u.x, "y": u.y, "heading": u.heading}
	for i in n:
		var bearing := JsMath.atan2(float(c.y) - float(at["y"]), float(c.x) - float(at["x"]))
		var turn := _wrap(bearing - float(at["heading"]))
		at = world.plan_step(id, i, {"turn": turn, "speed": cruise})

# Distance to the nearest map edge; negative outside the map.
func _edge_distance(x: float, y: float) -> float:
	var b := world.bounds
	return minf(minf(x - b.position.x, b.end.x - x), minf(y - b.position.y, b.end.y - y))

static func _wrap(a: float) -> float:
	return a - TAU * floorf((a + PI) / TAU)
