extends SceneTree

# A LOOK AT THE STRIKE'S INTERFACE (Track U3, 2026-10-10). WINDOWED ONLY -- under --headless the
# renderer is a dummy and nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/bomb_ui_shot.gd -- [out=tmp/bomb_ui] [only=ground|map]
#
# Native-size frames (1280 x 720, never scaled) to tmp/bomb_ui/:
#
#   ground_close.png     the radio tower and the two anti-aircraft batteries on paper, big enough to see the
#                        drawing (the sheet's tower and battery, ported): the lattice and its long shadow, the
#                        hut with its accent roof panel, the sandbag ring, the gun pit and its ground panel
#   ground_play.png      the same at the play scale, a bomber beside them for size
#   strike_plan.png      THE REAL MAP (the running sandbox, seed 20261009): the player's bomber with a drop planned
#                        over the village -- the bomb cone as a wash, the aim with its spread and release, the
#                        orders card with the Drop control on, the roster with its drops left, the radio tower
#                        and the batteries on the map with their shadows
#   strike_roster.png    the roster and the orders card at full size, cropped
#   strike_ground.png    the tower and the batteries on the map, close
#
# A shot only sets the scene up and calls the interface's own public methods (it plans through the planner and presses
# the card's buttons); nothing is drawn by the script but the paper.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const StrikeScene = preload("res://scripts/ui/boards/strike_scene.gd")

var out_dir := "tmp/bomb_ui"
var only := ""
var st: UiStyle = null
var failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
		elif kv.size() == 2 and kv[0] == "only":
			only = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[bomb-ui-shot] ", msg)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[bomb-ui-shot] needs a windowed run")
		quit(1)
		return
	st = UiStyle.shared() as UiStyle
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://").path_join(out_dir))
	if only == "" or only == "ground":
		await _ground_on_paper()
	if only == "" or only == "map":
		await _strike_on_map()
	quit(1 if failures > 0 else 0)

func _save(img: Image, file: String) -> void:
	var path := ProjectSettings.globalize_path("res://").path_join(out_dir).path_join(file)
	var err := img.save_png(path)
	if err != OK:
		failures += 1
		printerr("[bomb-ui-shot] could not write ", path, ": ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [path, img.get_width(), img.get_height()])

# --- the ground units on paper ----------------------------------------------------------------------

func _ground_on_paper() -> void:
	var size := Vector2i(1280, 720)
	var vp := SubViewport.new()
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	root.add_child(vp)
	var paper := ColorRect.new()
	paper.color = st.color("map_paper")
	paper.size = Vector2(size)
	vp.add_child(paper)
	var tex := _paper_texture(size)
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.size = Vector2(size)
		vp.add_child(tr)
	for scale_ppm: Array in [["ground_close.png", 9.0], ["ground_play.png", 3.8]]:
		var w := World.new()
		w.add_player("local")
		var ppm: float = scale_ppm[1]
		var origin := Vector2(1000.0, 2000.0)
		var at := func(sx: float, sy: float) -> Vector2: return origin + Vector2(sx, sy) / ppm
		var tp: Vector2 = at.call(380.0, 330.0)
		var a1: Vector2 = at.call(760.0, 250.0)
		var a2: Vector2 = at.call(900.0, 520.0)
		var bp: Vector2 = at.call(300.0, 600.0)
		w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": tp.x, "y": tp.y, "heading": 0.0})
		w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": a1.x, "y": a1.y, "heading": 0.4})
		w.add_unit({"id": "aa2", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": a2.x, "y": a2.y, "heading": -0.6})
		w.add_unit({"id": "b1", "type": "bomber", "side": "allies", "controller": "player", "x": bp.x, "y": bp.y, "heading": 0.0, "altitude_band": "low"})
		var xf := Transform2D(0.0, Vector2(ppm, ppm), 0.0, -origin * ppm)
		var ui := UnitUI.new()
		vp.add_child(ui)
		ui.setup(w, xf, "local")
		ui.hud.visible = false
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		_save(img, str(scale_ppm[0]))
		for id: String in ["tower", "aa1", "aa2"]:
			var m = ui.marker_layer.marker(id)
			_say("%s: art %s, %s, extent %.1f m, drawn %.1f px/m" % [id, "baked" if m.has_art() else "NOT baked",
				"screen-aligned" if (m.art != null and m.art.screen_aligned) else "-", m.art.extent_m if m.art != null else -1.0, m.screen_ppm * st.num("marker.true_scale")])
		ui.queue_free()
		await process_frame
	vp.queue_free()

func _paper_texture(size: Vector2i) -> Texture2D:
	var ground: Script = load("res://scripts/render/ink_ground.gd")
	var params: Script = load("res://scripts/world/render_params.gd")
	if ground == null or params == null or not ground.can_instantiate() or not params.can_instantiate():
		return null
	var P = params.new()
	if not P.ok():
		return null
	P.L["road"] = false
	return ground.build_ground(size, [], P, true)

# --- the strike on the real map ----------------------------------------------------------------------

func _strike_on_map() -> void:
	var s := StrikeScene.new(self)
	_say("standing up the sandbox (seed 20261009)...")
	if not await s.start():
		printerr("[bomb-ui-shot] ", s.scene.errors)
		failures += 1
		return
	await s.set_up()
	_say("tower at %s, %d batteries, bomber from %s heading %.2f -- %s" % [str(s.tower_m), s.battery_m.size(), str(s.start_m), s.heading, s.layout_note])
	# 1. The plan, at the planning zoom: the cone and the aim, the card, the roster, the tower and its batteries.
	await s.frame_play()
	var img: Image = await s.scene.grab()
	_save(img, "strike_plan.png")
	for id: String in s.world.units:
		var u = s.world.units[id]
		var mk = s.ui.marker_layer.marker(id)
		_say("  %s  %s  %s/%s  at (%.0f, %.0f) m -> screen %s  marker %s" % [id, u.type, u.side, u.controller, u.x, u.y, str(s.screen_of_m(Vector2(u.x, u.y))), "visible" if mk.visible else "hidden"])
	# 2. The roster and the orders card, cropped 1:1 from that frame.
	var r: Rect2 = s.ui.sidebar_rect()
	var col := Rect2i(int(r.position.x), 0, int(r.size.x), mini(int(r.end.y), img.get_height()))
	_save(img.get_region(col), "strike_roster.png")
	_say("the drop control: %s; the card says '%s'" % [str(s.ui.orders.buttons()["drop"]), s.ui.orders.bomb_caption()])
	# 3. Close: zoom 1 over the aim, the spread and the release, the tower and the batteries.
	await s.frame_close()
	_save(await s.scene.grab(), "strike_close.png")
	# 4. The ground units alone, nothing selected, a close look.
	s.ui.selection.clear()
	await s.scene.look(s.tower_m, Vector2(480.0, 360.0), 1.6)
	await s.scene.settle()
	_save(await s.scene.grab(), "strike_ground.png")
	if only == "" or only == "map":
		await _strike_plays(s)
	s.shutdown()

# --- the strike played, through the real effects layer -------------------------------------------------

# Turn 1: the stick leaves the bomber (at 2.5 s, the middle of its second step) and the bombs fall for nine seconds
# (the medium band); the bombs land in turn 3, the tower goes down and its ruin takes the place of its marker.
# Frames at the moments that show it, the playback held there for the grab; a script error from any layer on the
# way shows in the log.
func _strike_plays(s: StrikeScene) -> void:
	var ui = s.ui
	ui.select("b1")
	# (staged: the tower is worn down to two pips so the first stick finishes it; whether a drop kills a
	# full-health tower is the sim's tuning, not the interface's)
	s.world.units["tower"].health = 2
	var seen: Array = []
	ui.playback_event.connect(func(ev: Dictionary) -> void: seen.append(ev))
	await s.frame_play()
	var shot_impact := false
	var shot_ruin := false
	for turn in 4:
		seen.clear()
		if turn == 1:
			await s.scene.look(s.tower_m, Vector2(480.0, 360.0), 0.8)
		ui.press_ready()
		var guard := 0
		while not ui.is_playing() and guard < 30:
			await process_frame
			guard += 1
		guard = 0
		while ui.is_playing() and guard < 3000:
			await process_frame
			guard += 1
			if turn == 0 and _seen(seen, "bomb_release") and not FileAccess.file_exists(_path("strike_release.png")):
				for i in 6:
					await process_frame
				await _hold_and_save(ui, s, "strike_release.png")
			elif _seen(seen, "bomb_impact") and not shot_impact:
				shot_impact = true
				for i in 5:
					await process_frame
				await _hold_and_save(ui, s, "strike_impact.png")
			elif _seen(seen, "down") and shot_impact and not shot_ruin:
				shot_ruin = true
				for i in 30:
					await process_frame
				await _hold_and_save(ui, s, "strike_ruin.png")
		_say("turn %d played: %s" % [turn + 1, str(_counts(seen))])
		if shot_ruin:
			break
	var u = s.world.units["tower"]
	_say("the tower: fate '%s', health %d, marker %s" % [str(u.fate), int(u.health), "visible" if s.ui.marker_layer.marker("tower").visible else "hidden"])

func _path(file: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join(out_dir).path_join(file)

# Holds the playback where it is, grabs one frame, lets it run on.
func _hold_and_save(ui, s: StrikeScene, file: String) -> void:
	ui.marker_layer.playback_paused = true
	await s.scene.frames(3)
	_save(await s.scene.grab(), file)
	ui.marker_layer.playback_paused = false

func _counts(list: Array) -> Dictionary:
	var c := {}
	for e: Dictionary in list:
		c[str(e.get("type", ""))] = int(c.get(str(e.get("type", "")), 0)) + 1
	return c

func _seen(list: Array, kind: String) -> bool:
	for e: Dictionary in list:
		if str(e.get("type", "")) == kind:
			return true
	return false
