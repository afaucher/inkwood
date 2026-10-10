extends SceneTree

# SHOTS: THE TARGET SELECTION AND ITS CONSEQUENCES (Track T, 2026-10-10). WINDOWED ONLY, native size (1280 x 720), the running
# game itself (the sandbox on seed 20261009 with the strike's units, scripts/ui/boards/strike_scene.gd), every state reached the
# way a player reaches it -- the planner's and the interface's own calls (a left press on the tower's marker, a right click on
# the map, Drop, the aim handle, a step dragged):
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed --resolution 1280x720 `
#       --script res://scripts/ui/target_shot.gd -- [out=tmp/target]
#
#   01_unit_target_035.png / 01_unit_target_1.png    the tower is the target: brackets round it (a left-click on its marker)
#   02_point_target_035.png / 02_point_target_1.png  a point target (a right-click), drawn over the fog, far from anything in sight
#   03_drop_disabled_no_target.png                   Drop disabled for want of a target, the reason on the card's line
#   04_drop_disabled_outside.png                     Drop disabled: the target is outside the step's cone, the reason on the card
#   05_two_steps_two_targets.png                     step 2 drops on the tower (a unit target), step 3 on a point of its own
#   06_moved_step_hold.png                           a step moved: its cone left the target; it is marked "will not release" (hold)
#   06_moved_step_poor_shot.png                      the same under outside_cone_mode poor_shot: "poor shot", the stick lands at the cone's edge
#   07_aoe_default_035.png / 07_aoe_default_1.png    the area of effect in the working default (bombs.aoe.mode), the expected-damage line on the card
#
# Every frame is the whole window: roster, orders card, map. Nothing here is a decision; every look is PROPOSED by Track T.

const StrikeScene = preload("res://scripts/ui/boards/strike_scene.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const CombatResolver = preload("res://scripts/sim/combat_resolver.gd")

var out_dir := "tmp/target"
var s: StrikeScene = null
var failures := 0
var saved: Array = []

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[target-shot] ", msg)

func _check(ok: bool, what: String) -> void:
	if not ok:
		failures += 1
		printerr("[target-shot] CHECK FAILED: ", what)

func _snap(name: String) -> void:
	await s.scene.frames(4)
	var img: Image = await s.scene.grab()
	var path := ProjectSettings.globalize_path("res://").path_join(out_dir).path_join(name + ".png")
	var err := img.save_png(path)
	if err != OK:
		failures += 1
		printerr("[target-shot] could not write ", path)
	else:
		saved.append(name + ".png")
		_say("saved %s (%d x %d)  card: '%s'" % [name, img.get_width(), img.get_height(), s.ui.orders.bomb_caption()])

func _screen(p_m: Vector2) -> Vector2:
	return s.screen_of_m(p_m)

func _set_mode(mode: String) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(BombRules.PATH))
	(d["outside_cone_mode"] as Dictionary)["value"] = mode
	var r := BombRules.new(d)
	s.world.bombs = r
	s.world._combat_resolver = CombatResolver.new(s.world.combat, r)
	s.pl.bombs._cone_cache.clear()
	s.pl.bombs._info_cache.clear()
	s.pl.bombs._expect_cache.clear()

func _drag(k: int, to: Vector2) -> void:
	s.pl.begin_edit(k, to)
	s.pl.end_step()

func _run() -> void:
	s = StrikeScene.new(self)
	_say("standing up the sandbox (seed 20261009)...")
	if not await s.start():
		printerr("[target-shot] ", s.scene.errors)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://").path_join(out_dir))
	await s.set_up()
	if s.scene.sb.objective != null:
		s.scene.sb.objective.visible = false   # (the scenario's dashed TARGET ring is not what these shots are about)
	var ui = s.ui
	var pl = s.pl
	var dir := Vector2.from_angle(s.heading)
	var step := s.DROP_STEP
	var base_aoe: String = s.style.text("bombs.aoe.mode")

	# --- a clean slate: no drop, no target; the bomber with two steps ----------------------------------------------------
	pl.set_step_drop(step, false)
	ui.target.clear()
	await s.frame_play()

	# 03. Drop disabled: a step, no target.
	_check(not bool(ui.orders.buttons()["drop"]["enabled"]), "Drop is disabled with no target")
	await _snap("03_drop_disabled_no_target")

	# 04. A target outside the step's cone: a point 330 m to the side of the tower.
	var cone: Dictionary = pl.bombs.cone("b1", step)
	var outside: Vector2 = cone["ideal_aim"] + Vector2(-dir.y, dir.x) * 330.0
	ui.set_target_point(outside)
	_check(not bool(ui.orders.buttons()["drop"]["enabled"]), "Drop is disabled with a target outside the cone")
	await _snap("04_drop_disabled_outside")

	# 02. A point target drawn over the fog, far from anything the players see: 900 m past the tower, in the dark.
	var far_pt: Vector2 = s.tower_m + dir * 900.0 + Vector2(-dir.y, dir.x) * 250.0
	ui.target.clear()
	_check(ui.right_click(_screen(far_pt)), "the right click on the map is taken")
	_check(ui.target.kind == "point" and ui.target.point_m.distance_to(far_pt) < 1.0, "a point target is set where the pointer was")
	await s.scene.look(s.tower_m + dir * 350.0, Vector2(480.0, 360.0), 0.35)
	await s.scene.settle()
	await _snap("02_point_target_035")
	await s.scene.look(far_pt, Vector2(640.0, 360.0), 1.0)
	await s.scene.settle()
	await _snap("02_point_target_1")

	# 01. The tower as the target: a left-click on its marker, as a player does (the bomber stays selected).
	ui.target.clear()
	await s.frame_play()
	await s.scene.frames(8)   # (the fog follows the camera a few frames behind: the tower's marker must be in sight to be clicked)
	ui.marker_layer.update_poses()
	var tower_px: Vector2 = _screen(s.tower_m)
	_check(ui.map_press(tower_px), "the left press on the tower's marker is taken")
	ui.map_release(tower_px)
	_check(ui.target.unit_id == "tower" and ui.selection.unit_id == "b1", "the tower is the target and the bomber is still selected (target %s '%s', selected '%s')" % [ui.target.kind, ui.target.unit_id, ui.selection.unit_id])
	await _snap("01_unit_target_035")
	await s.frame_close()
	await _snap("01_unit_target_1")

	# 07. Drop on the tower: the area of effect in the working default, and the expected-damage line.
	await s.frame_play()
	_check(not pl.toggle_drop().is_empty() or pl.step_has_drop(step), "Drop takes the tower")
	await _snap("07_aoe_default_035")
	await s.frame_close()
	await _snap("07_aoe_default_1")

	# 05. Two steps, two targets: step 2 on the tower (a unit target), step 3 on a point of its own.
	await s.frame_play()
	pl.place_point(s.start_m + dir * 426.0)
	var cone3: Dictionary = pl.bombs.cone("b1", 2)
	var p3: Vector2 = cone3["ideal_aim"] + dir * 30.0 + Vector2(-dir.y, dir.x) * 40.0
	ui.set_target_point(p3)
	_check(not pl.toggle_drop().is_empty(), "step 3 takes a point target")
	_check(pl.step_target(step).get("unit", "") == "tower" and pl.step_target(2).get("unit", "x") == "", "two steps, two targets (a unit, a point): %s and %s" % [str(pl.step_target(step)), str(pl.step_target(2))])
	await s.frame_play()
	await _snap("05_two_steps_two_targets")

	# 06. A step moved: step 2's cone leaves the tower. Both earlier steps are dragged hard to the side; the drop on the tower is
	# kept, MARKED, and what the sim does is its switch: hold (nothing released) or poor_shot.
	pl.set_step_drop(2, false)
	ui.target.clear()
	pl.set_focus_step(step)
	for mode: String in ["hold", "poor_shot"]:
		_set_mode(mode)
		var side := Vector2(-dir.y, dir.x)
		_drag(0, s.start_m + dir * 120.0 - side * 90.0)
		_drag(1, s.start_m + dir * 230.0 - side * 260.0)
		_check(pl.step_has_drop(step) and pl.drop_blocked(step), "[%s] the moved step keeps its drop and is marked" % mode)
		pl.set_focus_step(step)
		await s.scene.look(s.tower_m - dir * 420.0 - side * 120.0, Vector2(500.0, 380.0), 0.35)
		await s.scene.settle()
		await _snap("06_moved_step_hold" if mode == "hold" else "06_moved_step_poor_shot")
		# Put the steps back for the next mode.
		_drag(0, s.start_m + dir * 142.0)
		_drag(1, s.start_m + dir * 284.0)
	_set_mode("hold")
	pl.set_step_drop(step, false)
	pl.clear()
	var report := {"saved": saved, "aoe_default": base_aoe, "failures": failures}
	var f := FileAccess.open(ProjectSettings.globalize_path("res://").path_join(out_dir).path_join("shots.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  ", false))
		f.close()
	s.shutdown()
	quit(1 if failures > 0 else 0)
