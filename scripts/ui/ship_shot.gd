extends SceneTree

# A look at the small cruiser (Track SH, the warship, 2026-10-10). WINDOWED ONLY -- under --headless nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64.exe --path . --windowed --resolution 1280x720 --script res://scripts/ui/ship_shot.gd -- [out=tmp/ships]
#
# The REAL unit interface (UnitUI, the marker layer, the roster, the orders card) on a World with the cruiser under way, a light fighter
# and an enemy battery; the cutter (the patrol boat, whose art is not in the marker layer yet) is drawn behind them by the boats'
# frame (scripts/render/boat_frame.gd) at the same scale, on the same sea. The scale is the planes' rule (decision water-layer):
# BoatScale.plane_ppm(zoom), the very number the sandbox's plane-size rule gives. Frames (1280 x 720), in the out directory:
#
#   ships_z1.png        zoom 1: the cruiser, a light fighter and the cutter, the roster hidden
#   ships_plan.png      the planning zoom (0.35)
#   ships_roster.png    zoom 1 with the roster and the card: the cruiser is a row, selected
#   ships_fire.png      the main guns: a step planned, the target (a battery the tower sees) chosen, the fire on the step: the shell, the
#                       line to the target, the ring of the scatter, the card's lines
#   ships_reach.png     the same with the pointer on the special's button: the guns' reach as two thin rings
#   ships_reload.png    the guns reloading: the roster row's "reload 2" mark
#
# EVERYTHING HERE IS PROPOSED by Track SH; nothing is a decision.

const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const BoatFrame = preload("res://scripts/render/boat_frame.gd")
const BoatScale = preload("res://scripts/render/boat_scale.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")

const SIZE := Vector2i(1280, 720)
const ORIGIN := Vector2(1000.0, 2400.0)

var out_dir := "tmp/ships"
var _vp: SubViewport
var _ui: UnitUI = null
var _style: UiStyle
var _failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[ship-shot] ", msg)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[ship-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	_style = UiStyle.shared() as UiStyle
	if not _style.ok():
		printerr("[ship-shot] style data errors: ", _style.errors)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://").path_join(out_dir))
	await _zoom_frame(1.0, "ships_z1.png", false)
	await _zoom_frame(0.35, "ships_plan.png", false)
	await _zoom_frame(1.0, "ships_roster.png", true)
	await _fire_frames()
	quit(1 if _failures > 0 else 0)

func _new_viewport() -> void:
	if _vp != null:
		_vp.queue_free()
		await process_frame
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	root.add_child(_vp)

func _backdrop(tex: Texture2D) -> void:
	var rect := TextureRect.new()
	rect.texture = tex
	rect.size = Vector2(SIZE)
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	_vp.add_child(rect)

# --- zoom frames ----------------------------------------------------------------------------------------

func _zoom_frame(zoom: float, file: String, with_roster: bool) -> void:
	await _new_viewport()
	var map_ppm := BoatScale.map_ppm(zoom)
	var k := BoatScale.marker_k(zoom)
	_style.set_num("marker.true_scale", k)
	var at := func(sx: float, sy: float) -> Vector2: return ORIGIN + Vector2(sx, sy) / map_ppm
	var ppm := map_ppm * k
	# The sea, with the cutter on it (the boats' frame), under the interface.
	var cutter_s := Vector2(900.0, 470.0) if zoom >= 1.0 else Vector2(760.0, 470.0)
	var sea := BoatFrame.render(_style, SIZE, {"ppm": ppm, "map_ppm": map_ppm, "wake": "ink_v", "seed": 11,
		"boats": [{"kind": "patrol", "look": "p1", "side": "a", "pos": cutter_s, "heading": 0.0}]})
	_backdrop(ImageTexture.create_from_image(sea))
	var w := World.new()
	w.add_player("local")
	var cr: Vector2 = at.call(520.0 if zoom >= 1.0 else 380.0, 230.0)
	var fi: Vector2 = at.call(900.0 if zoom >= 1.0 else 700.0, 150.0)
	w.add_unit({"id": "cruiser", "type": "cruiser", "side": "allies", "controller": "player", "x": cr.x, "y": cr.y, "heading": 0.0, "speed": 12.0})
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": "player", "x": fi.x, "y": fi.y, "heading": 0.0, "altitude_band": "low"})
	w.add_unit({"id": "enemy", "type": "light_fighter", "side": "axis", "controller": "ai", "x": fi.x + 400.0 / map_ppm, "y": fi.y + 300.0 / map_ppm, "heading": PI, "altitude_band": "medium"})
	var xf := Transform2D(0.0, Vector2(map_ppm, map_ppm), 0.0, -ORIGIN * map_ppm)
	var ui := UnitUI.new()
	_vp.add_child(ui)
	_ui = ui
	ui.setup(w, xf, "local")
	if not with_roster:
		ui.roster.visible = false
		ui.orders.visible = false
	else:
		ui.select("cruiser")
	var m = ui.marker_layer.marker("cruiser")
	_say("hud size %s, roster at %s size %s visible %s, orders at %s" % [str(ui.hud.size), str(ui.roster.position), str(ui.roster.size), str(ui.roster.visible), str(ui.orders.position)])
	_say("zoom %.2f: map %.2f px/m, plane rule %.2f px/m; the cruiser's art: %s, wake %s, cast height %.1f m" % [zoom, map_ppm, ppm,
		str(m.has_art()), str(m.art != null and m.art.wake != null), m.art.cast_height_m if m.art != null else -1.0])
	if not m.has_art():
		_failures += 1
	await _save(file)
	_say("cruiser shadow: visible %s, offset %s, position %s, tex %s, modulate %s; layer shadows self_modulate %s" % [str(m.shadow.visible), str(m.shadow_offset), str(m.shadow.position), str(m.shadow.texture), str(m.shadow.modulate), str(ui.marker_layer.get_node("Shadows").self_modulate)])

# --- the guns ---------------------------------------------------------------------------------------------

func _fire_frames() -> void:
	await _new_viewport()
	var zoom := 0.3
	var map_ppm := BoatScale.map_ppm(zoom)
	_style.set_num("marker.true_scale", BoatScale.marker_k(zoom))
	var origin := Vector2(417.0, 1700.0)
	var paper: Texture2D = _paper()
	if paper != null:
		_backdrop(paper)
	var w := GunWorlds.world(3)
	w.units["cruiser"].speed = 12.0
	w.add_unit({"id": "aa2", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 1780.0, "y": 2540.0, "heading": 0.6})
	w.add_unit({"id": "tank", "type": "tank", "side": "allies", "controller": "player", "x": 1990.0, "y": 2420.0, "heading": 3.1})
	var xf := Transform2D(0.0, Vector2(map_ppm, map_ppm), 0.0, -origin * map_ppm)
	var ui := UnitUI.new()
	_vp.add_child(ui)
	_ui = ui
	ui.setup(w, xf, "local")
	ui.auto_resolve = false
	ui.select("cruiser")
	ui.planner.place_point(Vector2(632.0, 2500.0))
	ui.planner.place_point(Vector2(664.0, 2498.0))
	ui.set_target_unit("aa")
	ui.planner.set_focus_step(0)
	var st: Dictionary = ui.planner.toggle_drop()
	_say("fire planned: %s (%s)" % [str(not st.is_empty()), str((st.get("fire", {}) as Dictionary).get("reason", "?"))])
	if st.is_empty():
		_failures += 1
	_say("card: %s | %s" % [ui.orders.target_caption(), ui.orders.bomb_caption()])
	await _save("ships_fire.png")
	ui.orders.set_hover_button("drop")
	ui.planner.set_drop_hover(true)
	await _save("ships_reach.png")
	# The guns reloading: the roster row says so (and the card says for how long).
	ui.planner.set_drop_hover(false)
	ui.orders.set_hover_button("")
	ui.planner.clear()
	w.units["cruiser"].gun_ready["main_guns"] = w.turn + 2
	w.plan_changed.emit("cruiser")
	ui.roster.queue_redraw()
	await _save("ships_reload.png")

func _paper() -> Texture2D:
	var ground: Script = load("res://scripts/render/ink_ground.gd")
	var params: Script = load("res://scripts/world/render_params.gd")
	if ground == null or params == null or not ground.can_instantiate() or not params.can_instantiate():
		return null
	var P = params.new()
	if not P.ok():
		return null
	P.L["road"] = false
	return ground.build_ground(SIZE, [], P, true)

func _save(file: String) -> void:
	for i in 4:
		await process_frame
	if _ui != null:
		_say("hud size now %s" % str(_ui.hud.size))
		_ui.hud.size = Vector2(SIZE)
		_ui.layout()
		_ui.marker_layer.update_poses()   # (the first pose baked the art; the shadow's lift needs it)
	await process_frame
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var path := ProjectSettings.globalize_path("res://").path_join(out_dir).path_join(file)
	var err := img.save_png(path)
	if err != OK:
		_failures += 1
		printerr("[ship-shot] could not write ", path, ": ", error_string(err))
	else:
		_say("saved " + path)
