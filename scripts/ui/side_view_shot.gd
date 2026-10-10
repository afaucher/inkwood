extends SceneTree

# A LOOK AT THE SIDE VIEW IN THE GAME (Track V, 2026-10-10). WINDOWED ONLY -- under --headless the renderer is a
# dummy and nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/side_view_shot.gd -- [out=tmp/sideview_game]
#
# THE REAL SANDBOX (the strike scenario on the seed 20261009 map, the fog, the roster, the orders card), native size
# (1280 x 720, never scaled), at the planning zoom. The mock-up's four scenes (tmp/sideview/make.py) rebuilt with the game's
# own units and numbers; each saves
#
#   sv_<n>_<name>.png        the whole window: the map, the roster and the orders card with the side view in it
#   sv_<n>_<name>_card.png   the sidebar column, cropped 1:1
#   sv_<n>_<name>_x3.png     the side view's section alone, three times as large with the nearest pixel (to read; the 1:1 files are the truth)
#
#   1 level_far_above     a light fighter at 400 m; an enemy 500 m ahead and 600 m higher: out of the cone, the arrow on the edge
#   2 diving              the heavy fighter, high, diving a band onto an enemy 280 m below the dive's end: the cone tilted down
#   3 past_effective      a light fighter and an enemy 470 m ahead, level: inside the fade past the wing guns' 450 m
#   4 drop_on_tower       the bomber's second step drops on the radio tower: the fall, the landing, the spread, the tower
#   5 bomber_rear_guns    the bomber's nose gun, dorsal and tail turrets, and an enemy 300 m behind it: the page makes room behind
#   6 off_axis_ring       an enemy 20 degrees off the nose, past the wing guns' 10 degree arc: a ring in place of the dot
#   7 live_playback       scene 3 played: the turn held at 2.5 s, the panel live at the fighter's SHOWN pose with the enemy
#                         followed at ITS shown position (Alex: a moving target follows the unit)
#
# A shot only sets the scene up and calls the interface's own public methods (it plans through the planner and picks the
# target the way a click does); nothing is drawn by the script.

const World = preload("res://scripts/sim/world.gd")
const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const UiTarget = preload("res://scripts/ui/ui_target.gd")

const PLAY_ZOOM := 0.35          # data/view/camera.json zoom.start: the planning view
const BASE := Vector2(2300.0, 2300.0)

var out_dir := "tmp/sideview_game"
var only := 0                    # only=N runs scene N alone
var scene: BoardScene = null
var ui = null
var world: World = null
var sv = null
var tg = null                    # the target selection (Track T's UnitUI.target when it exists, else this script's own)
var failures := 0
var light := ""
var heavy := ""
var bomber := ""
var enemy := ""
var tower := ""

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
		elif kv.size() == 2 and kv[0] == "only":
			only = int(kv[1])
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[sideview-shot] ", msg)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[sideview-shot] needs a windowed run")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://").path_join(out_dir))
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed 20261009)...")
	if not await scene.start():
		printerr("[sideview-shot] ", scene.errors)
		quit(1)
		return
	ui = scene.sb.ui
	world = scene.world()
	ui.set_process_input(false)   # the real mouse must not move a shot's pointer
	sv = ui.get_meta("side_view", null)
	if sv == null:
		printerr("[sideview-shot] UnitUI mounted no side view")
		quit(1)
		return
	for id: String in world.units:
		var u = world.units[id]
		match str(u.type):
			"light_fighter":
				if u.controller == World.CONTROLLER_PLAYER:
					light = id
				else:
					enemy = id
			"heavy_fighter":
				if u.controller == World.CONTROLLER_PLAYER:
					heavy = id
			"bomber":
				if u.controller == World.CONTROLLER_PLAYER:
					bomber = id
			"radio_tower":
				tower = id
	_say("units: light %s, heavy %s, bomber %s, an enemy %s, the target %s" % [light, heavy, bomber, enemy, tower])
	tg = ui.get("target")
	if tg == null:
		_say("UnitUI.target does not exist yet (Track T): this script uses its own UiTarget as the panel's source")
		tg = UiTarget.new()
		sv.target_source = func() -> Object: return tg
	else:
		_say("UnitUI.target (Track T) is the panel's source")
	if only == 0 or only == 1:
		await _scene_1()
	if only == 0 or only == 2:
		await _scene_2()
	if only == 0 or only == 3:
		await _scene_3()
	if only == 0 or only == 4:
		await _scene_4()
	if only == 0 or only == 5:
		await _scene_5()
	if only == 0 or only == 6:
		await _scene_6()
	if only == 0 or only == 7:
		await _scene_7()
	scene.shutdown()
	quit(1 if failures > 0 else 0)

func _path(file: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join(out_dir).path_join(file)

func _save(img: Image, file: String) -> void:
	var err := img.save_png(_path(file))
	if err != OK:
		failures += 1
		printerr("[sideview-shot] could not write ", _path(file), ": ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [_path(file), img.get_width(), img.get_height()])

# Parks the planes that are not in the scene far from the camera (they stay in the world and in the roster).
func _park(keep: Array) -> void:
	var layout := {}
	var i := 0
	for id: String in [light, heavy, bomber, enemy]:
		if keep.has(id) or id == "":
			continue
		layout[id] = {"x": 900.0 + float(i) * 200.0, "y": 4300.0, "heading": 0.0}
		i += 1
	await scene.place(layout)

func _target_unit(id: String) -> void:
	var u = world.units[id]
	tg.set_unit(id, Vector2(float(u.x), float(u.y)))

func _frame(at_m: Vector2) -> void:
	await scene.look(at_m, Vector2(430.0, 380.0), PLAY_ZOOM)
	await scene.settle()

# One scene's three files.
func _shoot(n: int, name: String) -> void:
	await scene.frames(4)
	sv.refresh()
	await scene.frames(3)
	var img: Image = await scene.grab()
	var stem := "sv_%d_%s" % [n, name]
	_save(img, stem + ".png")
	var col: Rect2 = ui.sidebar_rect()
	_save(img.get_region(Rect2i(int(col.position.x), 0, int(col.size.x), mini(int(col.end.y), img.get_height()))), stem + "_card.png")
	var r: Rect2 = sv.get_global_rect()
	var crop := img.get_region(Rect2i(Vector2i(int(r.position.x), int(r.position.y)), Vector2i(int(r.size.x), int(r.size.y))).intersection(Rect2i(0, 0, img.get_width(), img.get_height())))
	crop.resize(crop.get_width() * 3, crop.get_height() * 3, Image.INTERPOLATE_NEAREST)
	_save(crop, stem + "_x3.png")
	var m: Dictionary = sv.model()
	var t: Dictionary = m.get("target", {})
	_say("scene %d: active %s, mode %s, step %d, %d cones, target %s, line '%s', picture draws %d, failed sub-draws %d, card %.0f px tall" % [
		n, str(m.get("active")), str(m.get("mode")), int(m.get("step", -9)), (m.get("cones", []) as Array).size(),
		("%s %s inside=%s hollow=%s rel (%.0f, %.0f)" % [t["kind"], t["unit"], t["inside"], t["hollow"], t["rel_x"], t["rel_z"]]) if not t.is_empty() else "none",
		str(m.get("line")), sv.picture_draws, sv.failed_draws, ui.orders.size.y])
	if sv.failed_draws != 0 or not bool(m.get("active")):
		failures += 1

# --- 1. Level, the enemy far above ----------------------------------------------------------------------------

func _scene_1() -> void:
	await _park([light, enemy])
	await scene.place({light: {"x": BASE.x, "y": BASE.y, "heading": 0.0, "band": "medium"},
		enemy: {"x": BASE.x + 500.0, "y": BASE.y, "heading": PI, "band": "high"}})
	ui.select(light)
	ui.planner.clear()
	await _frame(BASE + Vector2(250.0, 0.0))
	_target_unit(enemy)
	await _shoot(1, "level_far_above")

# --- 2. Diving onto it ------------------------------------------------------------------------------------------

func _scene_2() -> void:
	await _park([heavy, enemy])
	await scene.place({heavy: {"x": BASE.x, "y": BASE.y, "heading": 0.0, "band": "high"},
		enemy: {"x": BASE.x + 125.0 + 380.0, "y": BASE.y, "heading": PI, "band": "low"}})
	ui.select(heavy)
	ui.planner.clear()
	ui.planner.place_point(Vector2(BASE.x + 125.0, BASE.y))
	ui.planner.change_band(-1)
	await _frame(BASE + Vector2(250.0, 0.0))
	_target_unit(enemy)
	await _shoot(2, "diving")

# --- 3. Just past the effective range ---------------------------------------------------------------------------------

func _scene_3() -> void:
	await _park([light, enemy])
	await scene.place({light: {"x": BASE.x, "y": BASE.y, "heading": 0.0, "band": "medium"},
		enemy: {"x": BASE.x + 470.0, "y": BASE.y, "heading": PI, "band": "medium"}})
	ui.select(light)
	ui.planner.clear()
	await _frame(BASE + Vector2(235.0, 0.0))
	_target_unit(enemy)
	await _shoot(3, "past_effective")

# --- 4. A drop on the tower ------------------------------------------------------------------------------------------------

func _scene_4() -> void:
	await _park([bomber, light])
	var tu = world.units[tower]
	var tower_m := Vector2(float(tu.x), float(tu.y))
	var heading := 0.0 if tower_m.x >= 1700.0 else PI
	var dir := Vector2.from_angle(heading)
	var start := tower_m - dir * 980.0
	# A fighter near the tower sees it through the fog (as the strike boards do), so it can be the target.
	var side := Vector2(-dir.y, dir.x)
	var scout := tower_m - dir * 330.0 + side * 260.0
	await scene.place({bomber: {"x": start.x, "y": start.y, "heading": heading, "band": "medium"},
		light: {"x": scout.x, "y": scout.y, "heading": heading, "band": "medium"}})
	ui.select(bomber)
	var pl = ui.planner
	pl.clear()
	pl.place_point(start + dir * 142.0)
	pl.place_point(start + dir * 284.0)
	_target_unit(tower)
	pl.set_step_drop(1, true)
	# Move the bomber so the ideal aim of its drop step is the tower, as the strike boards do, and plan again.
	var ideal: Vector2 = pl.bombs.cone(bomber, 1)["ideal_aim"]
	var delta := tower_m - ideal
	await scene.place({bomber: {"x": start.x + delta.x, "y": start.y + delta.y, "heading": heading}})
	start += delta
	pl.clear()
	pl.place_point(start + dir * 142.0)
	pl.place_point(start + dir * 284.0)
	_target_unit(tower)
	pl.set_step_drop(1, true)   # the target (the tower) is the step's own, and the aim
	await _frame((start + tower_m) * 0.5)
	await _shoot(4, "drop_on_tower")

# --- 5. The bomber's three guns, a plane on its tail --------------------------------------------------------------------

func _scene_5() -> void:
	await _park([bomber, enemy])
	await scene.place({bomber: {"x": BASE.x, "y": BASE.y, "heading": 0.0, "band": "medium"},
		enemy: {"x": BASE.x - 300.0, "y": BASE.y, "heading": 0.0, "band": "medium"}})
	ui.select(bomber)
	ui.planner.clear()
	await _frame(BASE + Vector2(-150.0, 0.0))
	_target_unit(enemy)
	await _shoot(5, "bomber_rear_guns")

# --- 6. A plane off the guns' arc: a ring, not a dot -----------------------------------------------------------------------

func _scene_6() -> void:
	await _park([light, enemy])
	var off := Vector2.from_angle(deg_to_rad(20.0)) * 400.0
	await scene.place({light: {"x": BASE.x, "y": BASE.y, "heading": 0.0, "band": "medium"},
		enemy: {"x": BASE.x + off.x, "y": BASE.y + off.y, "heading": PI, "band": "medium"}})
	ui.select(light)
	ui.planner.clear()
	await _frame(BASE + off * 0.5)
	_target_unit(enemy)
	await _shoot(6, "off_axis_ring")

# --- 7. The turn playing back: the panel follows the shown poses ------------------------------------------------------------

func _scene_7() -> void:
	await _park([light, enemy])
	await scene.place({light: {"x": BASE.x, "y": BASE.y, "heading": 0.0, "band": "medium"},
		enemy: {"x": BASE.x + 420.0, "y": BASE.y + 120.0, "heading": PI * 0.75, "band": "medium"}})
	ui.select(light)
	ui.planner.clear()
	await _frame(BASE + Vector2(260.0, 60.0))
	_target_unit(enemy)
	ui.auto_begin_turn = false
	ui.press_ready()
	var guard := 0
	while not ui.is_playing() and guard < 60:
		await process_frame
		guard += 1
	ui.marker_layer.playback_paused = true
	ui.marker_layer.set_playback_time(2.5)
	await _shoot(7, "live_playback")
	ui.marker_layer.playback_paused = false
