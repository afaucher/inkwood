extends RefCounted

# THE RIG OF THE PLAN BOARDS (builder BP, 2026-10-14): boards plan-weight (variants/plan-weight/) and guns-mark (variants/guns-mark/).
# WINDOWED ONLY. The running sandbox over Hold the bridge (data/scenarios/bridge.json, seed 55: the road through woods, the village
# by the bridge, the river, the cruiser offshore), fog OFF so every crop shows the drawn map, photographed through BoardScene. Nothing is
# drawn by the board: the game's own planner draws, and ONLY a data key (planner.weight.preset, guns.marks.mode) changes between options.
#
#   var rig := PlanRig.new(tree)
#   if not await rig.start(): ...          # the sandbox, baked; rig.ui, rig.w, rig.style are the game's
#   rig.plan_tank(...)                      # a plan for a unit
#   await rig.view(at_m, zoom)              # the camera, the view baked
#   var img := await rig.grab()             # the 1280 x 720 frame
#
# EVERY OPTION AND VALUE ON THE BOARDS IS PROPOSED by builder BP; none is a decision.

const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")

const SCENARIO := "bridge"
const SCREEN_AT := Vector2(640.0, 360.0)       # where the point of interest is put on screen

var tree: SceneTree
var scene: BoardScene = null
var ui = null
var w = null
var style = null
var errors: Array[String] = []

func _init(t: SceneTree) -> void:
	tree = t

# Stands the sandbox up: fog off, the fire switch on when asked (the smoke scene), the hud, hint and clock hidden, the real mouse stopped.
func start(with_fire: bool = false) -> bool:
	var dbg: Node = tree.root.get_node("DebugSettings")
	dbg.set_choice("fog", 2)
	if with_fire:
		dbg.set_choice("fire", 1)
	scene = BoardScene.new(tree)
	if not await scene.start(240.0, SCENARIO):
		errors.append_array(scene.errors)
		return false
	style = scene.style
	ui = scene.sb.ui
	w = scene.world()
	ui.hud.visible = false
	scene.sb.clock.visible = false
	ui.set_process_input(false)
	ui.cones.set_arcs_shown(false)
	if scene.sb.objective != null:
		scene.sb.objective.visible = false   # the BRIDGE ring would be the loudest dashed line in the frame
	await scene.frames(4)
	return true

# A point on the village road `road_m` metres from the bridge's middle (negative: on the village's side) and the heading a tank facing the
# bridge has there (the scenario's own rule, "road_to_site").
func road_point(road_m: float) -> Vector2:
	return scene.sb.scenario.site_point("water.bridge", 0, 0.0, 0.0, true, road_m)

func road_heading(road_m: float) -> float:
	return scene.sb.scenario._road_heading_to_site("water.bridge", road_m, "tank", true)

func unit_at(id: String) -> Vector2:
	var u = w.units[id]
	return Vector2(float(u.x), float(u.y))

# Puts a unit down at `p` metres facing `heading` (radians, 0 = east) at rest, or at `speed`.
func put(id: String, p: Vector2, heading: float, speed: float = 0.0) -> void:
	var u = w.units[id]
	u.x = p.x
	u.y = p.y
	u.heading = heading
	u.speed = speed
	u.out_of_bounds = false

# Plans steps for a unit: `steps` is [{turn, speed}...] (World.plan_step requests).
func plan(id: String, steps: Array) -> void:
	for k in steps.size():
		w.plan_step(id, k, steps[k])

# The camera: world point `at_m` at SCREEN_AT, at `zoom`; waits for the map under the view.
func view(at_m: Vector2, zoom: float) -> void:
	await scene.look(at_m, SCREEN_AT, zoom)
	await scene.settle()
	await scene.frames(4)

func grab() -> Image:
	return await scene.grab()

func frames(n: int) -> void:
	await scene.frames(n)

# A crop of a frame: `size` px with the world point `at_m` at `at_px` in the crop (the same crop for every option of a scene).
func crop(img: Image, at_m: Vector2, at_px: Vector2i, size: Vector2i) -> Image:
	var a: Vector2 = scene.sb.map_view.world_to_screen(at_m)
	var o := Vector2i(roundi(a.x), roundi(a.y)) - at_px
	var r := Rect2i(o, size).intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	return img.get_region(r)

func shutdown() -> void:
	if scene != null:
		scene.shutdown()
	await tree.process_frame
