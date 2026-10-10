extends SceneTree

# SHOTS: STEP SELECTION AND THE DROP (Track B, 2026-10-10; Alex's Strike playtest: "The bomb controls are wildly bad ... nothing connects
# 'I am selecting the bomb special on step 2' with this red blob. And it moves with subsequent steps??" "I actually want to be able to set my
# motion and come back to step 2/3 and tell it to drop the bomb then." "Selecting the node should select that step in the plan."
# "maybe we could have a clickable indicator for the steps"). WINDOWED ONLY, at the window's native size.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --script res://scripts/app/stepdrop_shot.gd `
#       -- [out=tmp/stepdrop] [window=1280x720]
#
# The REAL Strike, started as the menu starts it (the Main scene, Local). The bomber is put where step 2's bombs can fall on the
# radio tower, one fighter stands by the tower so it is in sight, and the flow is Alex's own, every state reached through the
# interface's own calls (a press and release on a step's node, a left press on the tower's marker, the card's buttons and step
# strip pressed as clicks, a node dragged):
#
#   01_three_steps          three steps planned: the new step 3 is the selected one (filled, ringed, numbered), the strip says so
#   02_step2_clicked        step 2's node clicked: it is the selected step, on the map and in the strip, and the card names it
#   03_tower_targeted       the tower targeted (a left press on its marker): "target: radio tower"
#   04_drop_pressed         Bomb Drop pressed: its pressed state, the bomb at step 2's node, the line from the node to the tower
#   05_step3_moved          step 3's node dragged: step 2's picture has not moved
#   06_drop_hover           the pointer on the Drop button: the selected step's cone as a thin outline
#   07_no_target_words      step 2 selected with no target and no drop: the words on the card
#   08_next_step_selected   the strip's NEXT step clicked: nothing placed is selected, the fan places step 3
#   09_two_drops            step 2 on the tower, step 3 on a point of its own: one picture for each
# and each as <nn>_<name>_<width>.png (the whole window) and <nn>_<name>_<width>_card.png (the orders card alone, magnified 2x).

const World = preload("res://scripts/sim/world.gd")

const BOMBER := "bomber_1"
const TOWER := "radio_tower_1"
const DROP_STEP := 1

var out_dir := "tmp/stepdrop"
var opts: Dictionary = {}
var size := Vector2i(1280, 720)
var main: Node = null
var sb: Node = null
var ui: Node = null
var pl: Node = null
var w: World = null
var heading := 0.0
var start_m := Vector2.ZERO
var tower_m := Vector2.ZERO
var _failures := 0
var _saved: Array = []

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[stepdrop-shot] needs a windowed run: under --headless nothing is drawn")
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
	var win := str(opts.get("window", "1280x720")).split("x")
	if win.size() == 2:
		size = Vector2i(int(win[0]), int(win[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _say(msg: String) -> void:
	print("[stepdrop-shot] ", msg)

func _check(ok: bool, msg: String) -> void:
	if ok:
		_say("PASS  " + msg)
	else:
		_failures += 1
		printerr("[stepdrop-shot] FAIL  " + msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[stepdrop-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(12)

# One whole-window frame and one crop of the orders card (2x).
func _shot(nn: String, name: String) -> void:
	await _frames(4)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var base := "%s_%s_%d" % [nn, name, size.x]
	var path := out_dir.path_join(base + ".png")
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1
	_saved.append(base + ".png")
	var r: Rect2 = ui.orders.get_global_rect()
	var crop := img.get_region(Rect2i(Vector2i(int(r.position.x) - 6, int(r.position.y) - 6), Vector2i(int(r.size.x) + 12, int(r.size.y) + 12)))
	crop.resize(crop.get_width() * 2, crop.get_height() * 2, Image.INTERPOLATE_LANCZOS)
	crop.save_png(out_dir.path_join(base + "_card.png"))
	_saved.append(base + "_card.png")

func _frame_plan() -> void:
	var pts: Array = [start_m, tower_m + Vector2(80.0, 140.0), tower_m + Vector2(-80.0, -140.0)]
	for st: Dictionary in w.planned_states(BOMBER):
		pts.append(Vector2(float(st["x"]), float(st["y"])))
	sb.ctl.frame_max_zoom = 1.0
	sb.ctl.frame_points(pts)
	sb.ctl.stop_follow()

func _step_m(k: int) -> Vector2:
	var st: Dictionary = w.planned_states(BOMBER)[k]
	return Vector2(float(st["x"]), float(st["y"]))

# A left click as the player makes it: the press, then the release, at a map point (the map layer's space).
func _click(p: Vector2) -> bool:
	var used: bool = ui.map_press(p)
	ui.map_release(p)
	return used

func _card_click(button: String) -> bool:
	return ui.orders.press_button(button)

func _tower_px() -> Vector2:
	return sb.map_view.world_to_screen(tower_m)

# The pinned picture of step k (the planner's record), or {}.
func _pin(k: int) -> Dictionary:
	for m: Dictionary in pl.bomb_marks():
		if int(m["step"]) == k and bool(m.get("pin", false)):
			return m
	return {}

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	_say("window %s, viewport %s" % [str(DisplayServer.window_get_size()), str(root.get_viewport().get_visible_rect().size)])
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[stepdrop-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	_check(sb.is_playable and sb.scenario.id == "strike", "the Strike is playable")
	w = sb.world
	ui = sb.ui
	pl = ui.planner
	sb.hint.visible = false
	sb.knobs.visible = false
	if sb.objective != null:
		sb.objective.visible = false   # (the scenario's dashed TARGET ring is not what these shots are about)
	sb.scenario.view["result_card_delay_s"] = 9999.0

	# --- the units: the bomber where step 2's bombs fall on the tower; a fighter by the tower so it is in sight -----------------
	tower_m = Vector2(float(w.units[TOWER].x), float(w.units[TOWER].y))
	heading = 0.0 if tower_m.x >= 1700.0 else PI
	var dir := Vector2.from_angle(heading)
	var side := Vector2(-dir.y, dir.x)
	start_m = tower_m - dir * 980.0
	var corner := Vector2(4400.0 if tower_m.x < 2500.0 else 600.0, 4400.0 if tower_m.y < 2500.0 else 600.0)
	_place({BOMBER: [start_m, heading], "light_fighter_1": [tower_m - dir * 330.0 + side * 260.0, heading],
		"heavy_fighter_1": [start_m - dir * 80.0 + side * 190.0, heading], "patrol_1": [corner, heading + PI]})
	ui.select(BOMBER)
	_plan_two()
	var ideal: Vector2 = pl.bombs.cone(BOMBER, DROP_STEP)["ideal_aim"]
	start_m += tower_m - ideal
	_place({BOMBER: [start_m, heading]})
	pl.clear()
	await _frames(3)

	# --- 01. three steps planned -----------------------------------------------------------------------------------------------
	pl.place_point(start_m + dir * 142.0)
	pl.place_point(start_m + dir * 284.0)
	pl.place_point(start_m + dir * 426.0)
	_frame_plan()
	await _wait_view()
	_check(pl.planned_count() == 3 and pl.focus_step() == 2, "three steps planned; the new step 3 is the selected one")
	await _shot("01", "three_steps")

	# --- 02. step 2's node clicked ----------------------------------------------------------------------------------------------
	var n2: Vector2 = pl.node_screen(1)
	_check(_click(n2), "a press and release on step 2's node is taken")
	_check(pl.focus_step() == 1, "step 2 is the selected step (card: '%s')" % ("step %d of %d" % [pl.focus_step() + 1, w.steps_per_turn(BOMBER)]))
	_check(pl.states()[1]["x"] == _step_m(1).x, "and the click moved nothing")
	await _shot("02", "step2_clicked")

	# --- 03. the tower targeted -------------------------------------------------------------------------------------------------
	ui.marker_layer.update_poses()
	await _frames(8)
	var tp := _tower_px()
	_check(_click(tp), "a left press on the tower's marker is taken")
	_check(ui.target.is_unit() and ui.target.unit_id == TOWER and ui.selection.unit_id == BOMBER, "the tower is the target; the bomber stays selected")
	_check(ui.orders.target_caption() == "target: radio tower", "the card says: '%s'" % ui.orders.target_caption())
	await _shot("03", "tower_targeted")

	# --- 04. Bomb Drop pressed --------------------------------------------------------------------------------------------------
	_check(_card_click("drop"), "the Bomb Drop button is pressed")
	_check(pl.step_has_drop(1) and not pl.step_has_drop(2), "step 2 has the drop, step 3 has not")
	_check(bool(ui.orders.buttons()["drop"]["on"]), "the button shows its pressed state")
	var pin2 := _pin(1)
	_check(not pin2.is_empty() and bool(pin2["selected"]), "step 2's picture is pinned and selected")
	await _shot("04", "drop_pressed")

	# --- 05. step 3 moved: step 2's picture has not --------------------------------------------------------------------------------
	var node_before: Vector2 = pin2["node"]
	var lands_before: Vector2 = pin2["lands"]
	var n3: Vector2 = pl.node_screen(2)
	_check(ui.map_press(n3), "a press on step 3's node")
	var to := n3 + Vector2(0.0, 70.0)
	ui.map_drag(n3 + Vector2(0.0, 35.0))
	ui.map_drag(to)
	ui.map_release(to)
	_check(pl.focus_step() == 2, "the dragged node is the selected step")
	var pin2b := _pin(1)
	_check((pin2b["node"] as Vector2).distance_to(node_before) < 0.5 and (pin2b["lands"] as Vector2).distance_to(lands_before) < 0.5, "step 2's node and landing have not moved")
	await _wait_view()
	await _shot("05", "step3_moved")

	# --- 06. the pointer on the Drop button: the cone as a thin outline ------------------------------------------------------------
	_check(_click(pl.node_screen(1)), "step 2 selected again")
	ui.orders.set_hover_button("drop")
	_check(pl.drop_hover() and pl.cone_outline_shown(), "the pointer on the button: the cone is outlined")
	await _shot("06", "drop_hover")
	ui.orders.set_hover_button("")

	# --- 07. no target, no drop: the words -------------------------------------------------------------------------------------------
	_card_click("drop")
	ui.clear_target()
	_check(not pl.step_has_drop(1) and not ui.target.is_set(), "step 2 without its drop, no target")
	_check(ui.orders.target_caption() == "no target: click an enemy or right-click the map", "the card says: '%s'" % ui.orders.target_caption())
	_check(not bool(ui.orders.buttons()["drop"]["enabled"]) and ui.orders.bomb_caption() == "Bomb Drop needs a target", "and why Drop is off: '%s'" % ui.orders.bomb_caption())
	await _shot("07", "no_target_words")

	# --- 08. the strip's next step clicked ------------------------------------------------------------------------------------------------
	pl.undo()
	_check(pl.planned_count() == 2, "the plan has two steps")
	_check(_card_click("step_2"), "the strip's NEXT step (3) is clicked")
	_check(pl.focus_step() == -1 and pl.is_placing(), "no placed step is selected: the fan places step 3")
	_check(_card_click("step_0") and pl.focus_step() == 0, "a planned step in the strip selects it")
	_card_click("step_2")
	await _shot("08", "next_step_selected")

	# --- 09. two drops: one picture for each ---------------------------------------------------------------------------------------------
	pl.place_point(start_m + dir * 426.0)
	_click(pl.node_screen(1))
	ui.set_target_unit(TOWER)
	_card_click("drop")
	_click(pl.node_screen(2))
	var c3: Dictionary = pl.bombs.cone(BOMBER, 2)
	var p3: Vector2 = c3["ideal_aim"] + dir * 20.0 + side * 50.0
	ui.set_target_point(p3)
	_check(_card_click("drop"), "step 3 drops on a point of its own")
	_frame_plan()
	await _wait_view()
	await _shot("09", "two_drops")

	var f := FileAccess.open(out_dir.path_join("shots_%d.json" % size.x), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"saved": _saved, "failures": _failures}, "  ", false))
		f.close()
	_say("done: %d failure(s)" % _failures)
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)

func _place(layout: Dictionary) -> void:
	for id: String in layout:
		var u = w.units[id]
		var at: Vector2 = layout[id][0]
		u.x = at.x
		u.y = at.y
		u.heading = float(layout[id][1])
		u.out_of_bounds = false
	ui.marker_layer.update_poses()

func _plan_two() -> void:
	pl.clear()
	var dir := Vector2.from_angle(heading)
	pl.place_point(start_m + dir * 142.0)
	pl.place_point(start_m + dir * 284.0)
	pl.place_point(start_m + dir * 426.0)
