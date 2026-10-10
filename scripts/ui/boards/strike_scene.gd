extends RefCounted

# THE STRIKE, stood up on the running sandbox for a board or a look (Track U3, 2026-10-10). WINDOWED ONLY.
# Built on BoardScene (the real game's pieces over the real map, seed 20261009): this adds what the
# strike has that the sandbox scenario does not yet -- the radio tower, two anti-aircraft batteries and a
# PLAYER bomber -- and plans the drop the way a player does, through the interface's own planner:
#
#   var s := StrikeScene.new(tree)
#   if not await s.start(): ...
#   await s.set_up()                 # the units, the plan, the drop aimed at the tower
#   await s.frame_play()             # the camera at the planning zoom, bomber to tower in view
#   var img := await s.scene.grab()  # the frame, HUD and all
#   await s.frame_close()            # zoom 1 over the aim
#
# WHERE THE TOWER STANDS: the world layout's site (Track W: WorldLayout.sites(), the walled compound in the
# village) when that loads, else a fixed site of the sandbox's map; the batteries stand where the layout puts
# them, else on either side of the tower. The bomber starts the right distance back along its heading for step
# two's drop to land on the tower (the cone's ideal aim, which the sim computes). One of the players' fighters
# stands near the tower so that it, the batteries and the village are in sight through the fog.

const World = preload("res://scripts/sim/world.gd")
const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")

const PLAY_ZOOM := 0.35          # data/view/camera.json zoom.start: the planning view
const DROP_STEP := 1             # the second step of the bomber's three
const FALLBACK_SITE := Vector2(2600.0, 3300.0)

var scene: BoardScene = null
var ui = null
var pl = null
var world: World = null
var style = null
var tower_m := Vector2.ZERO
var battery_m: Array[Vector2] = []
var heading := 0.0
var start_m := Vector2.ZERO
var layout_note := ""

func _init(tree: SceneTree) -> void:
	scene = BoardScene.new(tree)

func start() -> bool:
	if not await scene.start():
		return false
	style = scene.style
	ui = scene.sb.ui
	pl = ui.planner
	world = scene.world()
	ui.set_process_input(false)   # the real mouse must not move a board's pointer
	return true

# The tower's site and the batteries', metres: Track W's layout, else the fixed fallback.
func _sites() -> void:
	tower_m = FALLBACK_SITE
	battery_m = [FALLBACK_SITE + Vector2(-330.0, -170.0), FALLBACK_SITE + Vector2(300.0, 210.0)]
	layout_note = "fallback site (no world layout)"
	if not ResourceLoader.exists("res://scripts/world/world_layout.gd"):
		return
	var script: Script = load("res://scripts/world/world_layout.gd")
	if script == null or not script.can_instantiate():
		return
	var layout = script.new(20261009, scene.sb.terrain)
	if not layout.has_method("ok") or not layout.ok():
		return
	var sites: Dictionary = layout.sites()
	if sites.has("radio_tower") and sites["radio_tower"] is Vector2:
		tower_m = sites["radio_tower"]
		var aa: Array = sites.get("aa_battery", [])
		battery_m = []
		for q: Variant in aa:
			battery_m.append(q as Vector2)
		layout_note = "Track W's world layout (the village's compound)"

# The units, the bomber's plan and its drop aimed at the tower. `band`: the bomber's altitude band.
func set_up(band: String = "medium") -> void:
	_sites()
	heading = 0.0 if tower_m.x >= 1700.0 else PI
	var dir := Vector2.from_angle(heading)
	start_m = tower_m - dir * 980.0
	world.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": tower_m.x, "y": tower_m.y, "heading": 0.0})
	for i in battery_m.size():
		var q := battery_m[i]
		world.add_unit({"id": "aa%d" % (i + 1), "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": q.x, "y": q.y, "heading": 0.4 - 1.0 * float(i)})
	world.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "callsign": "Anvil",
		"x": start_m.x, "y": start_m.y, "heading": heading, "altitude_band": band})
	# A fighter near the tower sees it (and the batteries) through the fog; the other two players' units
	# and the enemy's planes (whatever the scenario has: a bomber, an escort) are out of the shot.
	var side := Vector2(-dir.y, dir.x)
	var mine_light := ""
	var mine_heavy := ""
	var enemies: Array[String] = []
	for id: String in world.units:
		var u = world.units[id]
		if u.def.is_static() or id == "b1":
			continue
		if u.controller == World.CONTROLLER_PLAYER and str(u.type) == "light_fighter":
			mine_light = id
		elif u.controller == World.CONTROLLER_PLAYER and str(u.type) == "heavy_fighter":
			mine_heavy = id
		elif u.controller == World.CONTROLLER_AI:
			enemies.append(id)
	var layout := {}
	if mine_light != "":
		layout[mine_light] = {"x": tower_m.x - dir.x * 330.0 + side.x * 260.0, "y": tower_m.y - dir.y * 330.0 + side.y * 260.0, "heading": heading}
	if mine_heavy != "":
		layout[mine_heavy] = {"x": start_m.x - dir.x * 80.0 + side.x * 190.0, "y": start_m.y - dir.y * 80.0 + side.y * 190.0, "heading": heading}
	var corner := Vector2(4400.0 if tower_m.x < 2500.0 else 600.0, 4400.0 if tower_m.y < 2500.0 else 600.0)
	for i in enemies.size():
		layout[enemies[i]] = {"x": corner.x + float(i) * 150.0, "y": corner.y, "heading": heading + PI}
	await scene.place(layout)
	ui.select("b1")
	_plan()
	# Move the bomber so the ideal aim of its drop step is the tower, and plan again.
	var ideal: Vector2 = pl.bombs.cone("b1", DROP_STEP)["ideal_aim"]
	var delta := tower_m - ideal
	await scene.place({"b1": {"x": start_m.x + delta.x, "y": start_m.y + delta.y, "heading": heading}})
	start_m += delta
	_plan()
	pl.place_aim(DROP_STEP, tower_m)
	await scene.frames(3)

func _plan() -> void:
	pl.clear()
	var dir := Vector2.from_angle(heading)
	pl.place_point(start_m + dir * 142.0)
	pl.place_point(start_m + dir * 284.0)
	pl.set_step_drop(DROP_STEP, true)

func midpoint() -> Vector2:
	return (start_m + tower_m) * 0.5

# The planning view: the bomber to the tower, left of the sidebar.
func frame_play() -> void:
	await scene.look(midpoint(), Vector2(420.0, 380.0), PLAY_ZOOM)
	await scene.settle()

# Zoom 1 over the aim: the cone's far part, the spread, the tower and its batteries.
func frame_close() -> void:
	await scene.look(tower_m + Vector2.from_angle(heading) * -40.0, Vector2(500.0, 360.0), 1.0)
	await scene.settle()

func screen_of_m(p: Vector2) -> Vector2:
	return scene.sb.map_view.world_to_screen(p)

func shutdown() -> void:
	scene.shutdown()
