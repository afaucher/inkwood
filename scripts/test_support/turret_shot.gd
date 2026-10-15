extends SceneTree

# THE TURNING TURRETS, LOOKED AT (builder ORD, 2026-10-14; Alex, decision tank-fire-feedback). WINDOWED ONLY (a headless run draws nothing; test_tank_orders is the
# headless proof). Hold the bridge's map, the closest zoom: a player tank and the cruiser with their turrets at different bearings, drawn by the marker as parts.
#
#   .\\tools\\shot.ps1 -Script scripts\\test_support\\turret_shot.gd -Out tmp\\turrets -Sheet
#
# Saves 01_tank_<deg>.png (the turret at 0, 60 and -80 degrees from the nose) and 02_cruiser_<deg>.png (0, 75 and 180).

const World = preload("res://scripts/sim/world.gd")

var out_dir := "tmp/turrets"
var opts: Dictionary = {}
var size := Vector2i(1280, 720)
var sb: Node = null

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[turret-shot] needs a windowed run")
		quit(1)
		return
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	out_dir = str(opts.get("out", out_dir))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _shot(file: String) -> void:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png(out_dir.path_join(file))
	print("[turret-shot] saved %s (%s)" % [file, error_string(err)])

func _wait_view() -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or sb.fog.bakes_in_flight() > 0:
		if (Time.get_ticks_msec() - t) / 1000.0 > 90.0:
			break
		await process_frame
	await _frames(14)

func _look(at_m: Vector2, zoom: float) -> void:
	var ppm: float = sb.ctl.px_per_m
	sb.ctl.stop_follow()
	sb.ctl.set_view(at_m * ppm, zoom)

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	var script: GDScript = load("res://scripts/app/sandbox.gd")
	sb = script.new("bridge")
	root.add_child(sb)
	if not sb.ok():
		printerr("[turret-shot] the sandbox did not start: ", sb.errors)
		quit(1)
		return
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 300000:
		await process_frame
	var w: World = sb.world
	# the tank first: tank_1, closest zoom
	var tank: Object = w.units["tank_1"]
	for deg: float in [0.0, 60.0, -80.0]:
		tank.turret = deg_to_rad(deg)
		_look(Vector2(tank.x, tank.y), 3.0)
		await _wait_view()
		sb.ui.marker_layer.update_poses()
		await _shot("01_tank_%d.png" % int(deg))
	var ship: Object = w.units["cruiser_1"]
	for deg: float in [0.0, 75.0, 180.0]:
		ship.turret = deg_to_rad(deg)
		_look(Vector2(ship.x, ship.y), 1.0)
		await _wait_view()
		sb.ui.marker_layer.update_poses()
		await _shot("02_cruiser_%d.png" % int(deg))
	if sb.has_method("shutdown"):
		sb.shutdown()
	quit(0)
