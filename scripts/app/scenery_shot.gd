extends SceneTree

# THE LIVE GAME'S SCENERY, ONE SHOT (decision scenery-heights, S1 live, 2026-10-12). WINDOWED ONLY.
#
# The Strike's village at the closest zoom (3.0, 6 px per metre): the radio tower and its walled compound, houses, and a tank beside
# the compound's wall for scale -- the board's "village" subject (scripts/ui/boards/scenery_heights_board_shot.gd), now drawn by the
# game's own data (render_defaults.json: wall_height, house_height_ratio, tree_height_*), not by the board's override.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed --resolution 1280x720 `
#       --script res://scripts/app/scenery_shot.gd -- [out=tmp/scenery_s1] [hour=9] [fixed=1] [compare=variants/scenery-heights/s1_village_close.png]
#
# The sun is the game's: the clock model pinned to `hour` (default 9, so the run is the same at any time of day; the shadows fall
# south). `fixed=1` is the prototype's fixed sun (315, 46), which the board's frames used: with it this frame must equal the board's
# S1 frame, and `compare=` says how many pixels differ. Saved at the window's native 1280 x 720.

const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const Sun = preload("res://scripts/world/sun.gd")

const CENTRE := Vector2(2004.0, 1435.0)       # metres: the village's east edge, the compound's wall at the left of the frame
const TANK := Vector2(1988.0, 1462.0)         # on the road beside the compound's wall, facing south
const FAR := Vector2(4400.0, 4400.0)

var opts: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	if DisplayServer.get_name() == "headless":
		printerr("[scenery-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	_run.call_deferred()

func _run() -> void:
	var fixed := str(opts.get("fixed", "0")) == "1"
	Sun.set_override({"mode": "fixed"} if fixed else {"mode": "clock_at_start", "hour": float(opts.get("hour", 9.0))})
	print("[scenery-shot] sun: ", Sun.current().describe())
	var knobs: Node = root.get_node("DebugSettings")
	knobs.set_value("fog", knobs.OPTIONS["fog"]["choices"].find("off"))
	var scene := BoardScene.new(self)
	if not await scene.start(300.0, "strike"):
		printerr("[scenery-shot] start failed: ", scene.errors)
		quit(1)
		return
	var sb: Node = scene.sb
	sb.ui.hud.visible = false
	sb.clock.visible = false
	if sb.objective != null:
		sb.objective.visible = false
	sb.ui.selection.clear()
	sb.ui.set_process_input(false)
	((UiStyle.shared() as UiStyle).ui["labels"] as Dictionary)["enabled"] = false
	var w = sb.world
	for id: String in w.units:
		var u = w.units[id]
		if u.def.domain == "air":
			u.x = FAR.x
			u.y = FAR.y
			u.out_of_bounds = false
	w.add_unit({"id": "tank_shot", "type": "tank", "side": "allies", "controller": "player", "x": TANK.x, "y": TANK.y, "heading": PI / 2.0, "speed": 0.0})
	await scene.frames(3)
	await scene.look(CENTRE, Vector2(640.0, 360.0), float(sb.ctl.clamp_zoom(3.0)))
	await scene.settle(180.0)
	var img: Image = await scene.grab()
	var out_dir := str(opts.get("out", "tmp/scenery_s1"))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var path := out_dir.path_join("strike_village_z3%s.png" % ("_fixed_sun" if fixed else ""))
	var e := img.save_png(path)
	print("[scenery-shot] saved %s (%s, %s)" % [path, str(img.get_size()), error_string(e)])
	if opts.has("compare"):
		_compare(img, str(opts["compare"]))
	sb.map_view.baker.clear()   # the baker's workers must be done before quitting (CLAUDE.md: exit 139 otherwise)
	scene.shutdown()
	await process_frame
	await process_frame
	quit(0 if e == OK else 1)

# How many pixels differ from another native frame, and by how much.
func _compare(img: Image, file: String) -> void:
	var path := file if not file.is_relative_path() else ProjectSettings.globalize_path("res://").path_join(file)
	var other := Image.load_from_file(path)
	if other == null:
		printerr("[scenery-shot] cannot read ", path)
		return
	other.convert(Image.FORMAT_RGBA8)
	if other.get_size() != img.get_size():
		printerr("[scenery-shot] sizes differ: ", img.get_size(), " ", other.get_size())
		return
	var diff := 0
	var sum := 0.0
	var worst := 0.0
	for y in img.get_height():
		for x in img.get_width():
			var a := img.get_pixel(x, y)
			var b := other.get_pixel(x, y)
			var d := absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)
			if d > 1e-6:
				diff += 1
				sum += d
				worst = maxf(worst, d)
	print("[scenery-shot] against %s: %d of %d pixels differ, mean difference %.5f, worst %.3f (sum of the three channels, 0 to 3)" % [file, diff, img.get_width() * img.get_height(), sum / float(maxi(diff, 1)), worst])
