extends SceneTree

# A look at the co-op interface (Track U2, "the first fight", part 1). WINDOWED
# ONLY -- under --headless the renderer is a dummy and nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"     # autoloads load under --script; keep Steam out of it
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64.exe --path . --script res://scripts/ui/ui_coop_shot.gd
#
# (give it a timeout: a script that fails to compile idles forever). Five
# player planes and one enemy plane on paper, the interface mounted through
# UnitUI exactly as the sandbox mounts it, and 1280x720 frames saved to
# tmp/ui_coop/:
#
#   coop_plans.png     three planned paths (Wizard, Anvil, Raven) on the map, one
#                      unit with no plan (Brick: its dashed flight, and "no plan
#                      (flies on)" in the roster), one down (Magpie: a greyed
#                      row, struck through, no pips); Anvil selected -- its fan,
#                      the speed each step ends at, the health arc on the ring.
#                      The enemy plane has a plan in the world; it is not drawn.
#   coop_damaged.png   Raven (1 of 3 pips) selected: the arc and the pips agree
#   coop_grouped.png   the roster grouped by "needs orders": headings needs orders (1) /
#                      planned (3) / down (1) with their counts, the group-by button
#   coop_playing.png   the turn played back to 2 s: the rows still show the
#                      health the units began the turn with (no spoiled hit)
#
# THE SCALE IS A PLACEHOLDER (1 px/m here so a whole turn's paths fit the
# window; the planes are drawn at the sandbox's own size through
# marker.true_scale). The UI takes whatever mapping its host passes.

const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")

const OUT_DIR := "res://tmp/ui_coop"
const PPM := 1.0
const PLANE_PX := 36.0

var _vp: SubViewport

func _initialize() -> void:
	_run()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[ui-coop-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	var st: RefCounted = UiStyle.shared()
	if not st.ok():
		printerr("[ui-coop-shot] style data errors: ", st.errors)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var size := Vector2i(1280, 720)
	_vp = SubViewport.new()
	_vp.size = size
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	root.add_child(_vp)
	var paper := _build_paper(size)
	if paper != null:
		var tr := TextureRect.new()
		tr.size = Vector2(size)
		tr.texture = paper
		_vp.add_child(tr)
	else:
		var flat := ColorRect.new()
		flat.color = st.color("map_paper")
		flat.size = Vector2(size)
		_vp.add_child(flat)

	var w := World.new()
	if not w.ok():
		printerr("[ui-coop-shot] world data errors: ", w.errors)
		quit(1)
		return
	w.add_player("local")
	var origin := Vector2(1000.0, 2200.0)   # world metres at the screen's top-left
	var at := func(sx: float, sy: float) -> Vector2: return origin + Vector2(sx, sy) / PPM
	var specs := [
		["p1", "Wizard", "light_fighter", "player", 90.0, 130.0, 0.05, "medium"],
		["p2", "Anvil", "heavy_fighter", "player", 80.0, 300.0, 0.0, "medium"],
		["p3", "Raven", "light_fighter", "player", 120.0, 470.0, -0.1, "medium"],
		["p4", "Brick", "bomber", "player", 150.0, 610.0, 0.0, "low"],
		["p5", "Magpie", "light_fighter", "player", 600.0, 520.0, 1.2, "low"],
		["ai1", "Kestrel", "heavy_fighter", "ai", 760.0, 200.0, PI, "medium"],
	]
	for s: Array in specs:
		var p: Vector2 = at.call(s[4], s[5])
		w.add_unit({"id": s[0], "callsign": s[1], "type": s[2], "side": "allies" if s[3] == "player" else "axis",
			"controller": s[3], "x": p.x, "y": p.y, "heading": s[6], "altitude_band": s[7]})
	w.units["p2"].health = 3
	w.units["p3"].health = 1
	w.units["p5"].health = 0
	w.units["p5"].down = true
	var ai := AiDumb.new(w)
	ai.attach()   # the enemy plane has a plan: it must not show

	# The planes at the sandbox's own size: the knob the sandbox sets from the plane-size rule.
	st.set_num("marker.true_scale", PLANE_PX / (9.0 * PPM))
	var xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -origin * PPM)
	var ui := UnitUI.new()
	_vp.add_child(ui)
	ui.setup(w, xf, "local")
	ui.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	ui.hud.size = Vector2(size)
	ui.layout()
	print("[ui-coop-shot] sidebar %.0f px wide: hud_insets %s" % [ui.sidebar_width_px(), str(ui.hud_insets())])

	# Three plans made "elsewhere" (the World, as the network applies them) ...
	for step: Array in [["p1", [[190.0, 125.0], [290.0, 140.0], [385.0, 178.0]]], ["p3", [[215.0, 452.0], [295.0, 405.0], [345.0, 340.0], [352.0, 270.0]]]]:
		var k := 0
		for pt: Array in step[1]:
			w.plan_step(step[0], k, {"to": at.call(pt[0], pt[1])})
			k += 1
	# ... and Anvil's by this player, with a climb on its second step.
	ui.select("p2")
	ui.planner.place_point(at.call(215.0, 306.0))
	ui.planner.place_point(at.call(345.0, 292.0))
	ui.planner.change_band(1)
	print("[ui-coop-shot] rows: ", ui.roster.rows().map(func(r: Dictionary) -> String: return "%s %s %d/%d" % [r["name"], r["status"], r["health"], r["health_max"]]))
	print("[ui-coop-shot] header: ", ui.roster.header_status(), "; step labels of Anvil: ", ui.planner.step_labels("p2"))
	await _save("coop_plans.png")

	ui.select("p3")
	await _save("coop_damaged.png")

	# The roster grouped by who needs orders (the header button's second mode).
	ui.select("p2")
	ui.roster.set_group_by("needs_orders")
	print("[ui-coop-shot] grouped: ", ui.roster.headings().map(func(h: Dictionary) -> String: return "%s (%d)" % [h["text"], h["count"]]), " order ", ui.roster.ordered_ids())
	await _save("coop_grouped.png")
	ui.roster.set_group_by("none")

	# The turn played back to 2 s: Raven, hit during the turn, still shows its 3 pips.
	ui.select("p2")
	ui.auto_begin_turn = false
	ui.press_ready()
	w.units["p3"].health = 0   # (combat would have written this at the end of the resolve)
	ui.marker_layer.playback_paused = true
	ui.marker_layer.set_playback_time(2.0)
	await _save("coop_playing.png")
	quit(0)

func _build_paper(size: Vector2i) -> Texture2D:
	var ground: Script = load("res://scripts/render/ink_ground.gd")
	var params: Script = load("res://scripts/world/render_params.gd")
	if ground == null or params == null or not ground.can_instantiate() or not params.can_instantiate():
		print("[ui-coop-shot] STAND-IN flat paper (ink_ground.gd did not load)")
		return null
	var P = params.new()
	if not P.ok():
		return null
	P.L["road"] = false
	return ground.build_ground(size, [], P, true)

func _save(file: String) -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var path := ProjectSettings.globalize_path(OUT_DIR).path_join(file)
	var err := img.save_png(path)
	if err != OK:
		printerr("[ui-coop-shot] could not write ", path, ": ", error_string(err))
	else:
		print("[ui-coop-shot] saved ", path)
