extends SceneTree

# A look at combat on the map (Track U2, "the first fight", part 2). WINDOWED ONLY -- under
# --headless the renderer is a dummy and nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"     # autoloads load under --script; keep Steam out of it
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64.exe --path . --script res://scripts/ui/combat_shot.gd
#
# (give it a timeout: a script that fails to compile idles forever). Three real fights, found by
# seed (scripts/test_support/combat_worlds.gd: a "bomber" flying east with a fighter 300 m behind
# it shooting), the interface mounted through UnitUI exactly as the sandbox mounts it, the
# playback stepped by hand and held, and 1280x720 frames saved at native size to tmp/combat_ui/:
#
#   hit_1_flash.png      a hit: the paper flash and the ink burst on the bomber, as the event passes
#   hit_2_ink.png        1.3 s later: the same ink, hardly faded (fast flash, very slow decay)
#   hit_3_smoking.png    the end of that turn: the damaged bomber has smoked along its path
#   plan_1_cones.png     the turn planned: the selected fighter's cones as a wash, the wingtip
#                        ribbons running up to each plane
#   fall_1_start.png     a plane out of control, a moment after it went down: smoke, rocking, a
#                        shadow gap that closes as it falls
#   fall_2_late.png      next turn, near the ground
#   crash_1_burst.png    the crash: the explosion
#   crash_2_after.png    0.7 s later
#   wreck_1_planning.png the turn planned: a smoking wreck and its scar, the ribbon fading
#   wreck_2_later.png    four turns on: the wreck still smokes, thinner
#   blast_1.png          the other fate: a plane exploding in mid air
#   blast_2_after.png    and a second after it
#   result_won.png       the end-of-mission card, a won mission
#   result_lost.png      and a lost one
#
# THE SCALE IS A PLACEHOLDER (a ppm per frame below; the planes are drawn at the sandbox's own
# size through marker.true_scale). Look at the options in data/fx/fx.json as they are: the fire
# treatment, the smoke and crash options are open, and these frames use the working defaults.

const World = preload("res://scripts/sim/world.gd")
const Mission = preload("res://scripts/sim/mission.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const CombatWorlds = preload("res://scripts/test_support/combat_worlds.gd")

const OUT_DIR := "res://tmp/combat_ui"
const PLANE_PX := 36.0
const SIZE := Vector2i(1280, 720)

var _vp: SubViewport
var _paper: Control
var _ui: UnitUI = null
var _w: World = null
var _st: UiStyle

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[combat-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	_st = UiStyle.shared() as UiStyle
	if not _st.ok():
		printerr("[combat-shot] style data errors: ", _st.errors)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	_vp = SubViewport.new()
	_vp.size = SIZE
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.transparent_bg = false
	root.add_child(_vp)
	_paper = _build_paper()
	_vp.add_child(_paper)

	var seeds := {
		"hit": CombatWorlds.find_hit_seed(),
		"out_of_control": CombatWorlds.find_seed("out_of_control"),
		"exploded": CombatWorlds.find_seed("exploded"),
	}
	print("[combat-shot] seeds ", seeds)
	if int(seeds["hit"]) < 0 or int(seeds["out_of_control"]) < 0 or int(seeds["exploded"]) < 0:
		printerr("[combat-shot] no seed for a fate")
		quit(1)
		return
	await _hit(int(seeds["hit"]))
	await _fall(int(seeds["out_of_control"]))
	await _blast(int(seeds["exploded"]))
	await _results()
	quit(0)

# --- The scenes ------------------------------------------------------------------------------------------

func _hit(seed_value: int) -> void:
	_start(seed_value, 8)
	var res := CombatWorlds.turn(_w)
	var hits := CombatWorlds.events_of(res, "hit")
	var t_h := float((hits[0] as Dictionary)["t"])
	_ui.marker_layer.playback_paused = true
	_play_to(t_h + 0.06)
	await _frame("hit_1_flash.png", _bomber_at(), 2.2)
	_play_to(t_h + 1.3)
	await _frame("hit_2_ink.png", _bomber_at(), 2.2)
	_play_to(4.95)
	await _frame("hit_3_smoking.png", _bomber_at() - Vector2(120.0, 0.0), 1.6)
	CombatWorlds.play_out(_ui)
	_ui.select("fighter")
	await _frame("plan_1_cones.png", (_unit("fighter") + _unit("bomber")) * 0.5, 1.0)

func _fall(seed_value: int) -> void:
	_start(seed_value, 1)
	var res := CombatWorlds.turn(_w)
	var down := CombatWorlds.event_of(res, "down")
	var t_down := float(down["t"])
	_ui.marker_layer.playback_paused = true
	_play_to(t_down + 0.8)
	await _frame("fall_1_start.png", _bomber_at(), 2.2)
	CombatWorlds.play_out(_ui)
	# On to the turn of the crash.
	var crash := {}
	var turn_no := 1
	while crash.is_empty() and turn_no < 8:
		turn_no += 1
		var r := CombatWorlds.turn(_w)
		crash = CombatWorlds.event_of(r, "crash")
		if crash.is_empty():
			CombatWorlds.play_out(_ui)
	var t_c := float(crash["t"])
	_ui.marker_layer.playback_paused = true
	_play_to(maxf(t_c - 0.45, 0.1))
	await _frame("fall_2_late.png", _bomber_at(), 2.2)
	_play_to(t_c + 0.12)
	await _frame("crash_1_burst.png", Vector2(float(crash["x"]), float(crash["y"])), 2.2)
	_play_to(minf(t_c + 0.8, 4.95))
	await _frame("crash_2_after.png", Vector2(float(crash["x"]), float(crash["y"])), 2.2)
	CombatWorlds.play_out(_ui)
	var wreck := Vector2(float(crash["x"]), float(crash["y"]))
	await _frame("wreck_1_planning.png", wreck, 2.2)
	for i in 4:
		CombatWorlds.turn(_w)
		CombatWorlds.play_out(_ui)
	await _frame("wreck_2_later.png", wreck, 2.2)

func _blast(seed_value: int) -> void:
	_start(seed_value, 1)
	var res := CombatWorlds.turn(_w)
	var down := CombatWorlds.event_of(res, "down")
	var t_down := float(down["t"])
	var at := Vector2(float(down["x"]), float(down["y"]))
	_ui.marker_layer.playback_paused = true
	_play_to(t_down + 0.18)
	await _frame("blast_1.png", at, 2.2)
	_play_to(minf(t_down + 1.2, 4.95))
	await _frame("blast_2_after.png", at, 2.2)

func _results() -> void:
	_start(CombatWorlds.find_hit_seed(), 8)
	_ui.show_result({"state": "won", "reason": "bomber is down", "turn": 7, "t": 2.5})
	await _frame("result_won.png", _unit("bomber"), 1.0)
	_ui.hide_result()
	_ui.show_result({"state": "lost", "reason": "bomber came within 150 m of the target", "turn": 9, "t": 3.0})
	await _frame("result_lost.png", _unit("bomber"), 1.0)

# --- Plumbing ---------------------------------------------------------------------------------------------

func _start(seed_value: int, pips: int) -> void:
	if _ui != null:
		_ui.queue_free()
	_w = CombatWorlds.world(seed_value, pips)
	_ui = UnitUI.new()
	_vp.add_child(_ui)
	_ui.setup(_w, Transform2D.IDENTITY, "local")
	_ui.hud.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_ui.hud.size = Vector2(SIZE)
	_ui.layout()

func _unit(id: String) -> Vector2:
	var u = _w.units[id]
	return Vector2(float(u.x), float(u.y))

# Where the bomber is now (the playback's pose while one is held).
func _bomber_at() -> Vector2:
	if _ui.marker_layer.is_playing():
		var s := _w.sample("bomber", _ui.marker_layer.playback_t, "history")
		return Vector2(float(s["x"]), float(s["y"]))
	return _unit("bomber")

# Steps the held playback to t seconds into the turn in frames of 1/30 s, as a host's frames would.
func _play_to(t: float) -> void:
	var guard := 0
	while _ui.marker_layer.is_playing() and _ui.marker_layer.playback_t < t - 1e-6 and guard < 2000:
		CombatWorlds.step(_ui, minf(1.0 / 30.0, t - _ui.marker_layer.playback_t))
		guard += 1

# Look at world point `centre` at `ppm` px per metre, the planes drawn at PLANE_PX for the smallest.
func _view(centre: Vector2, ppm: float) -> void:
	_st.set_num("marker.true_scale", PLANE_PX / (9.0 * ppm))
	var xf := Transform2D(0.0, Vector2(ppm, ppm), 0.0, Vector2(SIZE) * 0.5 - centre * ppm)
	_ui.set_mapping(xf)

func _frame(file: String, centre: Vector2, ppm: float) -> void:
	_view(centre, ppm)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := _vp.get_texture().get_image()
	var path := ProjectSettings.globalize_path(OUT_DIR).path_join(file)
	var err := img.save_png(path)
	if err != OK:
		printerr("[combat-shot] could not write ", path, ": ", error_string(err))
	else:
		print("[combat-shot] saved ", path)

func _build_paper() -> Control:
	var ground: Script = load("res://scripts/render/ink_ground.gd")
	var params: Script = load("res://scripts/world/render_params.gd")
	if ground != null and params != null and ground.can_instantiate() and params.can_instantiate():
		var P = params.new()
		if P.ok():
			P.L["road"] = false
			var tex: Texture2D = ground.build_ground(SIZE, [], P, true)
			if tex != null:
				var tr := TextureRect.new()
				tr.size = Vector2(SIZE)
				tr.texture = tex
				return tr
	print("[combat-shot] STAND-IN flat paper (ink_ground.gd did not load)")
	var flat := ColorRect.new()
	flat.color = _st.color("map_paper")
	flat.size = Vector2(SIZE)
	return flat
