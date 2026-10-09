extends SceneTree

# A look at the unit interface without main.gd (Track U). WINDOWED ONLY --
# under --headless the renderer is a dummy and nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"     # autoloads load under --script; keep Steam out of it
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64.exe --path . --script res://scripts/ui/ui_shot.gd
#
# Builds a World with two player light fighters and one AI heavy fighter on
# paper (Track R's ink_ground.gd paper when it loads, the flat paper role when
# it does not), mounts the whole interface through UnitUI exactly as Track A
# will, drives it through its public methods, and saves 1280x720 frames to
# tmp/ui/:
#
#   ui_roster.png    the roster with a unit selected (ring, leader, first fan)
#   ui_plan.png      a two-step plan: one step inside the fan, one asked for
#                    outside it (clamped), a climb on the second; the next fan
#   ui_resolve.png   mid-resolve: the turn played back to 2.5 s
#   ui_wide.png      the same plan at a wider scale, where a whole turn fits
#
# THE SCALE IS A PLACEHOLDER: 3.8 px/m (data/ui/ui.json shot.placeholder_px_per_m,
# the unit sheet's true-scale strip) for the first three, a third of it for
# the wide one. The map scale is Alex's open question; the UI takes whatever
# mapping its host passes and the shot is the only thing that picks one.

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")

const OUT_DIR := "res://tmp/ui"

var _vp: SubViewport
var _paper: TextureRect

func _initialize() -> void:
	_run()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[ui-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	var st: RefCounted = UiStyle.shared()
	if not st.ok():
		printerr("[ui-shot] style data errors: ", st.errors)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var sz: Array = st.lookup("shot.size")
	var size := Vector2i(int(sz[0]), int(sz[1]))
	var ppm: float = st.num("shot.placeholder_px_per_m")
	print("[ui-shot] PLACEHOLDER scale %.2f px/m (the map scale is an open question for Alex)" % ppm)

	_vp = SubViewport.new()
	_vp.size = size
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	root.add_child(_vp)
	_paper = TextureRect.new()
	_paper.size = Vector2(size)
	_vp.add_child(_paper)
	var paper := _build_paper(size, st)
	if paper != null:
		_paper.texture = paper
	else:
		var flat := ColorRect.new()
		flat.color = st.color("map_paper")
		flat.size = Vector2(size)
		_vp.add_child(flat)
		_vp.move_child(flat, 0)

	# The world: two player planes and one AI plane (exit criterion 2).
	var w := World.new()
	if not w.ok():
		printerr("[ui-shot] world data errors: ", w.errors)
		quit(1)
		return
	w.add_player("local")
	var origin := Vector2(1000.0, 2400.0)   # world metres at the screen's top-left
	var at := func(sx: float, sy: float) -> Vector2: return origin + Vector2(sx, sy) / ppm
	var p1: Vector2 = at.call(120.0, 250.0)
	var p2: Vector2 = at.call(170.0, 560.0)
	var a1: Vector2 = at.call(330.0, 660.0)
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": p1.x, "y": p1.y, "heading": 0.05})
	w.add_unit({"id": "p2", "type": "light_fighter", "side": "allies", "controller": "player", "x": p2.x, "y": p2.y, "heading": -0.12, "altitude_band": "low"})
	w.add_unit({"id": "ai1", "type": "heavy_fighter", "side": "axis", "controller": "ai", "x": a1.x, "y": a1.y, "heading": -0.3, "altitude_band": "high"})
	var ai := AiDumb.new(w)
	ai.attach()

	var xf := Transform2D(0.0, Vector2(ppm, ppm), 0.0, -origin * ppm)
	var ui := UnitUI.new()
	_vp.add_child(ui)
	var t0 := Time.get_ticks_usec()
	ui.setup(w, xf, "local")
	print("[ui-shot] UI built in %.0f ms (art baked once per type and side)" % ((Time.get_ticks_usec() - t0) / 1000.0))

	# 1. The roster with a selection: p1 has one step in, p2 is selected.
	ui.select("p1")
	ui.planner.place_point(at.call(500.0, 270.0))
	ui.select("p2")
	await _save("ui_roster.png")

	# 2. A two-step plan on p1: step 1 inside the fan, step 2 asked for hard
	# right and short (outside the envelope: it comes back clamped), climbing.
	ui.select("p1")
	ui.planner.undo()
	var s1: Dictionary = ui.planner.place_point(at.call(497.0, 285.0))
	var s2: Dictionary = ui.planner.place_point(at.call(700.0, 700.0))
	ui.planner.change_band(1)
	print("[ui-shot] step 1 clamped=%s limits=%s; step 2 clamped=%s limits=%s" % [s1.get("clamped"), s1.get("limits"), s2.get("clamped"), s2.get("limits")])
	await _save("ui_plan.png")

	# 4 (before the resolve consumes the plan). The same at a third of the scale.
	var wide := ppm / 3.0
	var c := Vector2(w.units["p1"].x, w.units["p1"].y) + Vector2(230.0, 60.0)
	ui.set_mapping(Transform2D(0.0, Vector2(wide, wide), 0.0, -c * wide + Vector2(size) * Vector2(0.38, 0.5)))
	await _save("ui_wide.png")
	ui.set_mapping(xf)

	# 3. Mid-resolve: Ready (the AI readied itself), the turn resolves, the
	# markers play it back; held at 2.5 s, the view centred on all three.
	ui.auto_begin_turn = false
	ui.press_ready()
	print("[ui-shot] phase after Ready: ", w.phase)
	var t := 2.5
	ui.marker_layer.playback_paused = true
	ui.marker_layer.set_playback_time(t)
	var mid := Vector2.ZERO
	for id: String in ["p1", "p2", "ai1"]:
		var s: Dictionary = w.sample(id, t, "history")
		mid += Vector2(float(s["x"]), float(s["y"])) / 3.0
	ui.set_mapping(Transform2D(0.0, Vector2(ppm, ppm), 0.0, -mid * ppm + Vector2(size) * Vector2(0.4, 0.5)))
	ui.marker_layer.set_playback_time(t)
	await _save("ui_resolve.png")
	quit(0)

func _build_paper(size: Vector2i, st: RefCounted) -> Texture2D:
	var ground: Script = load("res://scripts/render/ink_ground.gd")
	var params: Script = load("res://scripts/world/render_params.gd")
	if ground == null or params == null or not ground.can_instantiate() or not params.can_instantiate():
		print("[ui-shot] STAND-IN flat paper (ink_ground.gd did not load)")
		return null
	var P = params.new()
	if not P.ok():
		return null
	P.L["road"] = false
	var tex: Texture2D = ground.build_ground(size, [], P, true)
	print("[ui-shot] paper: Track R's ink_ground.gd (tint shader, specks, fibres, dirt)")
	return tex

func _save(file: String) -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var path := ProjectSettings.globalize_path(OUT_DIR).path_join(file)
	var err := img.save_png(path)
	if err != OK:
		printerr("[ui-shot] could not write ", path, ": ", error_string(err))
	else:
		print("[ui-shot] saved ", path)
