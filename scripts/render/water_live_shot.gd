extends SceneTree

# SHOTS OF THE WATER IN THE LIVE MAP (Track WB, Job 3, 2026-10-10). A tool, not a test: WINDOWED. It stands the real sandbox up exactly as
# Local builds it (the Strike, seed 20261009, its water switch as the scenario file says) through BoardScene and photographs it:
#
#   INKWOOD_STEAM=off Godot_console.exe --path . --script res://scripts/render/water_live_shot.gd -- out=tmp/water_live [only=opening,coast_plan,...]
#
#   opening      the Strike's own opening view
#   coast_plan   the coast at the planning zoom (the river's mouth), the fog as the game has it
#   coast_close  the same shore at zoom 1
#   river_bridge the river where the road crosses it, at zoom 1.2, the bridge's unit on it
#   fog_water    a view over the sea beyond the planes' sight: the fog's contour map with its water
#   fog_overview the whole map at the overview zoom with the contour map everywhere (overview forced)
#
# It prints what it saw (the water's sites, the fog, the markers of the water units) and one line per file.

const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")

var opts: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

func _want(name: String) -> bool:
	var only := str(opts.get("only", ""))
	return only == "" or only.split(",").has(name)

func _save(bs: RefCounted, name: String) -> void:
	var img: Image = await bs.grab()
	var out := str(opts.get("out", "tmp/water_live"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var path := "%s/%s.png" % [out, name]
	img.save_png(path)
	print("[watershot] %s (%dx%d)" % [path, img.get_width(), img.get_height()])

# The three planes put near `at` (metres), heading east, so the view round it is in sight and the fog is not what is photographed.
func _planes_at(bs: RefCounted, at: Vector2) -> void:
	var layout: Dictionary = {}
	var offs: Array[Vector2] = [Vector2(-90.0, -70.0), Vector2(-120.0, 60.0), Vector2(-40.0, 0.0)]
	var ids: Array[String] = [bs.p_light, bs.p_heavy, bs.bomber]
	for i in 3:
		layout[ids[i]] = {"x": at.x + offs[i].x, "y": at.y + offs[i].y, "heading": 0.0}
	await bs.place(layout)

func _run() -> void:
	var bs := BoardScene.new(self)
	var t0 := Time.get_ticks_msec()
	if not await bs.start(300.0):
		print("[watershot] FAILED: ", bs.errors)
		quit(1)
		return
	print("[watershot] playable in %.1f s; water %s" % [(Time.get_ticks_msec() - t0) / 1000.0, "on" if bs.sb.water != null else "OFF"])
	var sb: Node = bs.sb
	var w: RefCounted = sb.water
	var sites: Dictionary = w.sites() if w != null else {}
	var anchor: Vector2 = sites.get("anchor", Vector2(2500.0, 2500.0))
	var bridge: Dictionary = sites.get("bridge", {})
	print("[watershot] anchor ", anchor, " bridge ", bridge.get("pos", "none"))
	for id: String in sb.world.units:
		var u = sb.world.units[id]
		print("[watershot] unit %s %s at (%.0f, %.0f) marker %s" % [id, u.type, u.x, u.y, "yes" if sb.ui.marker_layer.marker(id) != null else "no"])
	await bs.settle()
	if _want("opening"):
		await _save(bs, "opening")
	var centre: Vector2 = bs.sb.ctl.view_size() * 0.5
	var start_layout: Dictionary = {}
	for id: String in [bs.p_light, bs.p_heavy, bs.bomber]:
		var u = sb.world.units[id]
		start_layout[id] = {"x": float(u.x), "y": float(u.y), "heading": float(u.heading)}
	if _want("coast_plan"):
		await _planes_at(bs, anchor)
		await bs.look(anchor, centre, 0.35)
		await bs.settle()
		await _save(bs, "coast_plan")
	if _want("coast_close"):
		await bs.look(anchor, centre, 1.0)
		await bs.settle()
		await _save(bs, "coast_close")
	if _want("river_bridge") and not bridge.is_empty():
		await _planes_at(bs, bridge["pos"])
		sb.ui.hud.visible = false
		await bs.look(bridge["pos"], centre, 1.2)
		await bs.settle()
		await _save(bs, "river_bridge")
		sb.ui.hud.visible = true
	if _want("fog_water"):
		await bs.place(start_layout)
		# the sea beyond the planes' sight: look at the shore from the far side, so the contour map is what shows there
		var far: Vector2 = Vector2(float(opts.get("fx", anchor.x)), float(opts.get("fy", anchor.y)))
		await bs.look(far, centre, float(opts.get("fz", 0.5)))
		await bs.settle()
		await _save(bs, "fog_water")
	if _want("fog_overview"):
		sb.fog.overview_override = 1.0
		await bs.look(Vector2(2500.0, 2500.0), centre, 0.16)
		await bs.settle()
		await _save(bs, "fog_overview")
		sb.fog.overview_override = -1.0
	bs.shutdown()
	await process_frame
	quit(0)
