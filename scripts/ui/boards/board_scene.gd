extends RefCounted

# The running sandbox, stood up for a variant board (Track U1, the first fight).
# WINDOWED ONLY: under --headless nothing is drawn. The shot scripts of this
# folder (standout_board_shot.gd, cone_board_shot.gd) drive one of these:
#
#   var scene := BoardScene.new(tree)
#   if not await scene.start(): ...            # Sandbox, exactly as Local builds it, baked
#   await scene.place(layout)                  # the three planes, the camera, the fog
#   var img := await scene.grab()              # the 1280 x 720 frame, HUD and all
#
# It is the REAL game's pieces over the real map (data/scenarios/sandbox.json,
# seed 20261009): MapView's baked chunks, the fog layer with its inked edge and
# topographic outside, the markers, the roster, the orders card. Only the three
# planes' positions, the camera and the selection are set by the board; nothing
# is drawn by the board itself. A board's options differ in data (ui.json) and
# nothing else, so the ground is baked once per view and every option is
# photographed on the same pixels.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const SIZE := Vector2i(1280, 720)
const SANDBOX := "res://scripts/app/sandbox.gd"

var tree: SceneTree
var sb: Node = null
var style: UiStyle = null
var errors: Array[String] = []
var ids: Array[String] = []     # the scenario's order: light fighter, heavy fighter, bomber
var p_light := ""
var p_heavy := ""
var bomber := ""

func _init(scene_tree: SceneTree) -> void:
	tree = scene_tree

func frames(n: int) -> void:
	for _i in n:
		await tree.process_frame

# Builds the sandbox in the root window and waits until it is playable.
func start(max_s: float = 240.0) -> bool:
	if DisplayServer.get_name() == "headless":
		errors.append("a board needs a windowed run: under --headless nothing is drawn")
		return false
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(SIZE)
	tree.root.size = SIZE
	await frames(10)
	var script: Script = load(SANDBOX)
	if script == null or not script.can_instantiate():
		errors.append("%s did not compile -- see the Parse Error above" % SANDBOX)
		return false
	sb = script.new()
	tree.root.add_child(sb)
	if not sb.ok():
		errors.append("the sandbox did not build: %s" % str(sb.errors))
		return false
	var t := Time.get_ticks_msec()
	while not sb.is_playable and (Time.get_ticks_msec() - t) / 1000.0 < max_s:
		await tree.process_frame
	if not sb.is_playable:
		errors.append("the sandbox was not playable after %.0f s" % max_s)
		return false
	style = UiStyle.shared() as UiStyle
	ids = sb.ids
	var w: World = sb.world
	for id: String in ids:
		match str(w.units[id].type):
			"light_fighter":
				p_light = id
			"heavy_fighter":
				p_heavy = id
			"bomber":
				bomber = id
	# A clean frame: no knob panel, no key hint, nothing selected (the fan would paint the ground).
	sb.hint.visible = false
	sb.knobs.visible = false
	sb.ui.selection.clear()
	return true

func world() -> World:
	return sb.world

# `layout`: unit id -> {x, y, heading, band?} in world metres (heading in radians,
# 0 = east, positive clockwise on screen).
func place(layout: Dictionary) -> void:
	var w: World = sb.world
	for id: String in layout:
		var u = w.units[id]
		var d: Dictionary = layout[id]
		u.x = float(d["x"])
		u.y = float(d["y"])
		u.heading = float(d["heading"])
		if d.has("band"):
			u.altitude_band = str(d["band"])
		u.out_of_bounds = false
	await frames(3)

# The camera: world point `at_m` at screen point `screen_at`, at `zoom`.
func look(at_m: Vector2, screen_at: Vector2, zoom: float) -> void:
	var ctl = sb.ctl
	ctl.stop_follow()
	var ppm: float = sb.map_view.px_per_m
	var z: float = ctl.clamp_zoom(zoom)
	ctl.set_view(at_m * ppm - (screen_at - ctl.view_size() * 0.5) / z, z)
	await frames(2)

# Waits for the map under the view to be baked, then lets the fog and the markers settle.
func settle(max_s: float = 120.0) -> float:
	var t := Time.get_ticks_msec()
	await frames(2)
	while sb.map_view.missing_in_view() > 0:
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			errors.append("view not complete after %.0f s (%d chunks missing)" % [max_s, sb.map_view.missing_in_view()])
			break
		await tree.process_frame
	# The fog's topographic chunks and its mask follow a few frames behind.
	await frames(24)
	return (Time.get_ticks_msec() - t) / 1000.0

# One frame of the window, as an Image (1280 x 720).
func grab() -> Image:
	await frames(3)
	await RenderingServer.frame_post_draw
	var img := tree.root.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img

func screen_of(id: String) -> Vector2:
	var u = sb.world.units[id]
	return sb.map_view.world_to_screen(Vector2(float(u.x), float(u.y)))

func shutdown() -> void:
	if sb != null:
		sb.shutdown()
		sb.queue_free()
		sb = null
