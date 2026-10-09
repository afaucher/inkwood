extends "res://scripts/test_support/test_case.gd"

# THE SANDBOX DEMO, ASSEMBLED (Track A): the menu's Local button starts it, the
# parts are wired, a minute of flight runs, Esc comes back. Headless, so no
# pixels (scripts/app/demo_shot.gd is the windowed proof); what is checked is
# every join the parts were never tested across:
#
#   1. THE SCENARIO (data/scenarios/sandbox.json): reads cleanly; two player
#      planes and one AI plane, every one on the map; callsigns come from the
#      pools in data/names/callsigns.json, per side and type, none twice; a
#      broken scenario name is an error, not a default.
#   2. LOCAL: the menu's Local path builds the sandbox over the menu and hides
#      the menu; the world has 2 player + 1 AI units, the roster lists the two
#      player planes by callsign, the camera is the controller's (MapView's own
#      input is off), the fog is the first child of the live layer, and the
#      first view frames the players to the left of the sidebar.
#   3. ONE SPACE: every marker is where MapView.world_to_screen puts its unit,
#      and the planner's pointer maps back to the same metres; the plane's
#      drawn size follows the plane-size knob (a light fighter 36 px wide at
#      zoom 1 whatever the map scale, never under the minimum).
#   4. THE PLANNER'S MAP RULE: a step asked for off the map is refused and the
#      plan stays as it was.
#   5. A MINUTE OF FLIGHT: 12 turns through the real turn flow (Ready, the AI
#      already in, resolve, the markers play the turn back, the next turn). One
#      player plane flies a full 360 degree circle by scripted plans, the other
#      is planned through the UI's planner and steered clear of the edges, the
#      AI plane flies on its own. Nobody leaves the map; every plane has a track.
#   6. THE KNOBS (F2 panel; DebugSettings, so INKWOOD_<KEY> drives them): plane
#      size, fog on/off and edge, line of sight, far zoom, playback speed, pen,
#      tree pool, and the live map scale -- the terrain, the controller and the
#      map view agree afterwards and the camera is still over the same metres.
#   7. ESC: back to the menu, the UI style's two borrowed numbers restored; Local
#      again builds a fresh sandbox.

const World = preload("res://scripts/sim/world.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

const TURNS := 12

var _main: Node
var _sb: Node
var _frames := 0
var _phase := "boot"
var _phase_frames := 0
var _resolved := 0
var _left_bounds := 0
var _start_pos: Dictionary = {}
var _heading_total: Dictionary = {}     # unit id -> signed heading change over every resolved step
var _path_m: Dictionary = {}            # unit id -> metres flown (from the histories)
var _last_planned_turn := -1
var _style_true_scale := 0.0
var _style_playback := 0.0
var _ppm_before := 0.0
var _centre_before := Vector2.ZERO
var _p1 := ""
var _p2 := ""
var _ai := ""
var _looped_back := false

func setup(main) -> void:
	timeout_seconds = 240.0
	_main = main
	_check_scenario()
	var st: UiStyle = UiStyle.shared() as UiStyle
	_style_true_scale = st.num("marker.true_scale")
	_style_playback = st.num("marker.playback_speed")

	# The sandbox frames its view in the window it is given; a headless run's is tiny.
	main.get_window().size = Vector2i(1280, 720)
	print("[test] window ", main.get_window().size, " viewport ", main.get_viewport().get_visible_rect().size)

	# 2. Local, through the menu's own path.
	main.setup_menu()
	check(main.menu.visible, "the menu is up before Local")
	check(main.start_sandbox(), "Local builds the sandbox")
	_sb = main.sandbox
	if _sb == null:
		finish()
		return
	check(not main.menu.visible, "and hides the menu")
	check(main.start_sandbox(), "Local again is a no-op that still reports a sandbox")

# --- 1. The scenario -----------------------------------------------------------------------

func _check_scenario() -> void:
	var sc := SandboxScenario.new("sandbox")
	if not check(sc.ok(), "the sandbox scenario reads cleanly: %s" % str(sc.errors)):
		return
	eq(sc.seed_value, 20261009, "the scenario's seed is the prototype's fixed seed")
	eq(sc.units.size(), 3, "three units")
	var players := 0
	var ais := 0
	var pools: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SandboxScenario.CALLSIGNS_PATH))
	var bounds := World.new().bounds
	var seen: Dictionary = {}
	for spec: Dictionary in sc.units:
		if spec["controller"] == "player":
			players += 1
		else:
			ais += 1
		check(bounds.has_point(Vector2(float(spec["x"]), float(spec["y"]))), "%s starts on the map" % spec["type"])
		# The callsign is in its side's pool for its type, and nobody has it twice.
		var pool_name := ""
		for k: String in sc.sides:
			if (sc.sides[k] as Dictionary)["world_side"] == spec["side"]:
				pool_name = str((sc.sides[k] as Dictionary)["callsign_pool"])
		var names: Array = (pools[pool_name] as Dictionary).get(spec["type"], [])
		check(spec.has("callsign") and names.has(spec["callsign"]), "%s's callsign comes from the %s pool" % [spec["type"], pool_name])
		check(not seen.has(spec.get("callsign", "")), "no callsign twice")
		seen[spec.get("callsign", "")] = true
	eq(players, 2, "two player-controlled planes")
	eq(ais, 1, "one AI plane")
	var bad := SandboxScenario.new("no_such_scenario", true)
	check(not bad.ok(), "a scenario that is not there is an error, not a default")
	# The view values the sandbox reads are all present.
	for k: String in ["fog", "plane_px", "plane_min_px", "start_zoom_max", "start_pad_m", "start_look_ahead_turns", "track_sample_s", "track_line_px"]:
		check(sc.view.has(k), "view.%s is in the scenario" % k)

# --- The frame loop --------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _main == null or _finished:
		return   # (not `_sb == null`: a freed sandbox reads as null, and the Esc phase frees it)
	_frames += 1
	_phase_frames += 1
	match _phase:
		"boot":
			if _sb.is_playable and _phase_frames > 4:
				_inspect()
				_go("turns")
			elif _phase_frames > 120:
				fail("the sandbox never became playable")
				finish()
		"turns":
			_turns()
		"knobs":
			_knobs()
		"scale":
			_scale()
		"esc":
			_esc()
		"again":
			_again()

func _go(next: String) -> void:
	_phase = next
	_phase_frames = 0

# --- 2/3/4. Structure, one space, the map rule -----------------------------------------------

func _inspect() -> void:
	var w: World = _sb.world
	eq(w.units.size(), 3, "the world has three units")
	var players: Array[String] = []
	for id: String in w.units:
		var u = w.units[id]
		if u.controller == World.CONTROLLER_PLAYER:
			players.append(id)
		else:
			_ai = id
	eq(players.size(), 2, "two of them are player planes")
	check(_ai != "", "and one is the AI's")
	_p1 = players[0]
	_p2 = players[1]
	eq(w.units[_p1].type, "light_fighter", "player plane 1 is the light fighter")
	eq(w.units[_p2].type, "heavy_fighter", "player plane 2 is the heavy fighter")
	for id: String in w.units:
		_start_pos[id] = Vector2(float(w.units[id].x), float(w.units[id].y))
		_heading_total[id] = 0.0
		_path_m[id] = 0.0
	w.turn_resolved.connect(_on_resolved)
	w.unit_left_bounds.connect(func(_u: String, _t: int, _s: int) -> void: _left_bounds += 1)

	# The roster: the two player planes, by callsign.
	var rows: Array[Dictionary] = _sb.ui.roster.rows()
	eq(rows.size(), 2, "the roster lists the two player planes, not the AI's")
	for r: Dictionary in rows:
		eq(r["name"], w.units[r["id"]].callsign, "%s is listed by its callsign" % r["id"])
		check(str(r["name"]) != "", "and has one")
	eq(_sb.ui.selection.unit_id, _p1, "the first player plane starts selected")

	# Parts and wiring.
	check(_sb.map_view.camera == _sb.ctl.camera, "the controller drives MapView's own camera")
	check(not _sb.map_view.input_enabled, "MapView's fallback input is off: the controller owns the camera")
	check(_sb.map_view.live_layer.get_child(0) == _sb.fog, "the fog is the first child of the live layer")
	check(_sb.fog.controller == _sb.ctl, "the fog reads the overview amount from the controller")
	check(_sb.ui.marker_layer.unit_visible.is_valid(), "fog on: units outside sight are hidden through the marker layer's hook")
	check(_sb.ui.marker_layer.ground_height.is_valid(), "plane shadows read the ground height")
	eq(_sb.ui.marker_layer.markers.size(), 3, "a marker for every unit")
	check(_sb.terrain.px_per_m == _sb.map_view.px_per_m and _sb.ctl.px_per_m == _sb.map_view.px_per_m, "terrain, controller and map view start at one scale")
	near(_sb.map_view.px_per_m, 2.0, 0.0, "the map starts at 2 px/m (Alex's baseline)")
	check(_sb.knob_keys().has("map_scale") and _sb.knob_keys().has("fog"), "the knob panel lists the knobs")
	for k: String in _sb.knob_keys():
		check(DebugSettings.OPTIONS.has(k), "knob '%s' is registered with DebugSettings" % k)

	# The HUD fills the window and the sidebar is on screen (in the real window the roster's
	# parent came out zero-sized, which left it at x = -300: the sandbox sizes it itself).
	var vs: Vector2 = _sb.get_viewport().get_visible_rect().size
	check(_sb.ui.hud.size == vs, "the HUD fills the viewport (%s of %s)" % [_sb.ui.hud.size, vs])
	check(_sb.ui.roster.position.x > vs.x * 0.5 and _sb.ui.roster.position.x + _sb.ui.roster.size.x < vs.x, "the roster sits inside the window on the right (x %.0f)" % _sb.ui.roster.position.x)
	check(_sb.ui.orders.position.x == _sb.ui.roster.position.x and _sb.ui.orders.position.y > _sb.ui.roster.position.y, "the orders card is under it")
	check(not _sb.loading.visible and not _sb.note.visible, "the loading card and the redraw note are gone once the map is up")
	check(_sb.hint.text.contains("F2") and _sb.hint.text.contains(UiStyle.shared().text("keys.ready")), "the key hint names F2 and the Ready key from data")
	# The opening view: every plane in sight, left of the sidebar.
	var free_right: float = vs.x - (_sb.ctl.insets.right as float)
	for id: String in w.units:
		var s: Vector2 = _sb.map_view.world_to_screen(Vector2(float(w.units[id].x), float(w.units[id].y)))
		check(s.x > 0.0 and s.x < free_right and s.y > 0.0 and s.y < vs.y, "%s is in the opening view, clear of the sidebar (%s in %s)" % [id, s, vs])
		check(_sb.ui.marker_layer.marker(id).visible, "%s's marker is shown (the AI plane is inside sight at the start)" % id)
	check(_sb.ctl.zoom_level() <= 0.9 + 1e-9, "the opening zoom is no closer than view.start_zoom_max (%.3f)" % _sb.ctl.zoom_level())

	# One space: markers are where MapView puts the units; the pointer maps back.
	_check_one_space()

	# Plane size: a light fighter is plane_px wide at zoom 1 whatever the scale, never under the minimum.
	_check_plane_size()

	# The planner's map rule: a step that ENDS off the map is refused (a point asked
	# for behind the plane is only clamped to the fan, which is on the map). Put the
	# heavy fighter 300 m from the east edge, heading east, and plan toward the edge.
	var pl = _sb.ui.planner
	_sb.ui.select(_p2)
	var u2 = w.units[_p2]
	var keep_x: float = u2.x
	var keep_y: float = u2.y
	var keep_h: float = u2.heading
	u2.x = w.bounds.end.x - 300.0
	u2.heading = 0.0
	var step1: Dictionary = pl.place_point(Vector2(u2.x + 125.0, u2.y))
	check(not step1.is_empty(), "a first step 125 m ahead, still on the map, is taken")
	var step2: Dictionary = pl.place_point(Vector2(float(step1["x"]) + 125.0, u2.y))
	check(not step2.is_empty(), "a second, still on the map, is taken")
	eq(pl.planned_count(), 2, "two steps planned")
	var snap_x: float = float(pl.states()[1]["x"])
	var asked := Vector2(float(step2["x"]) + 400.0, u2.y)
	check(pl.place_point(asked).is_empty(), "a third step that would end off the map is refused")
	eq(pl.planned_count(), 2, "and the plan stays as it was")
	near(float(pl.states()[1]["x"]), snap_x, 1e-9, "step 2 unchanged")
	check(pl.refused_world.distance_to(asked) < 1e-6, "the planner remembers where it was refused (to draw the cross)")
	pl.clear()
	eq(pl.planned_count(), 0, "cleared")
	u2.x = keep_x
	u2.y = keep_y
	u2.heading = keep_h
	_sb.ui.select(_p1)

func _check_one_space() -> void:
	var w: World = _sb.world
	_sb.ui.marker_layer.update_poses()
	for id: String in w.units:
		var want: Vector2 = _sb.map_view.world_to_screen(Vector2(float(w.units[id].x), float(w.units[id].y)))
		check(_sb.ui.marker_layer.marker(id).position.distance_to(want) < 1e-3, "%s's marker sits where MapView.world_to_screen puts it" % id)
	var p := Vector2(2900.0, 2400.0)
	check(_sb.ui.planner.mapping.screen_to_world(_sb.map_view.world_to_screen(p)).distance_to(p) < 1e-3, "the planner's pointer maps back to the same metres")
	var a: Vector2 = _sb.map_view.world_to_screen(Vector2(100.0, 100.0))
	var b: Vector2 = _sb.map_view.world_to_screen(Vector2(110.0, 100.0))
	near(b.x - a.x, 10.0 * _sb.map_view.px_per_m * _sb.map_view.get_zoom(), 1e-3, "10 m is px_per_m x zoom x 10 screen px")
	near(_sb.ctl.world_to_screen(p).distance_to(_sb.map_view.world_to_screen(p)), 0.0, 0.01, "the controller's transform is the one the camera applied")

func _check_plane_size() -> void:
	_sb._update_plane_scale()
	var m = _sb.ui.marker_layer.marker(_p1)
	m.set_pose(m.position, 0.0, _sb.map_view.get_zoom() * _sb.map_view.px_per_m, Vector2.ZERO)
	var z: float = _sb.map_view.get_zoom()
	var width: float = m.radius_px() * 2.0
	var want := maxf(_sb.plane_px * z, _sb.plane_min_px)
	near(width, want, 0.5, "the light fighter draws %.1f px wide at zoom %.2f (36 px at zoom 1, never under the minimum)" % [want, z])

# --- 5. A minute of flight ---------------------------------------------------------------------

func _on_resolved(turn_no: int, histories: Dictionary, _events: Array) -> void:
	_resolved += 1
	for id: String in histories:
		var h: Array = histories[id]
		for i in range(1, h.size()):
			var d := float(h[i]["heading"]) - float(h[i - 1]["heading"])
			_heading_total[id] += d - TAU * floorf((d + PI) / TAU)
			_path_m[id] += Vector2(float(h[i - 1]["x"]), float(h[i - 1]["y"])).distance_to(Vector2(float(h[i]["x"]), float(h[i]["y"])))
	if turn_no == 1:
		# One turn at the playback speed in the data (5 s of animation), the rest fast.
		eq(_sb.ui.marker_layer.is_playing(), true, "the markers play turn 1 back")
	var w: World = _sb.world
	for id: String in w.units:
		check(w.in_bounds(float(w.units[id].x), float(w.units[id].y)), "turn %d: %s ends on the map" % [turn_no, id])

func _turns() -> void:
	var w: World = _sb.world
	if _resolved >= TURNS:
		if not _sb.ui.marker_layer.is_playing() and w.phase == World.PHASE_PLANNING:
			_after_turns()
		return
	if w.phase != World.PHASE_PLANNING or _sb.ui.marker_layer.is_playing():
		return
	if _last_planned_turn == w.turn:
		return
	_last_planned_turn = w.turn
	print("[test] planning turn %d (frame %d)" % [w.turn, _frames])
	if w.turn == 2:
		# Turn 1 played at the data's speed; speed the rest up with the knob (which also tests the knob).
		DebugSettings.set_choice("playback_speed", 4)
		near(UiStyle.shared().num("marker.playback_speed"), 8.0, 0.0, "the playback-speed knob sets Track U's playback speed")
	_plan_turn()
	_sb.ui.press_ready()

func _plan_turn() -> void:
	var w: World = _sb.world
	# Plane 1 circles: every step asks for more turn than it can give, so it turns at its limit.
	for i in w.steps_per_turn(_p1):
		w.plan_step(_p1, i, {"turn": 1.5})
	# Plane 2 through the UI's planner: a weave ahead, steered back from the edges.
	var pl = _sb.ui.planner
	_sb.ui.select(_p2)
	pl.clear()
	var u = w.units[_p2]
	var centre := Vector2(w.bounds.get_center())
	var ahead: Dictionary = w.planned_states(_p2).back()   # where it ends if it flies on
	var end := Vector2(float(ahead["x"]), float(ahead["y"]))
	var edge := minf(minf(end.x - w.bounds.position.x, w.bounds.end.x - end.x), minf(end.y - w.bounds.position.y, w.bounds.end.y - end.y))
	var here := Vector2(float(u.x), float(u.y))
	if edge < 900.0:
		_looped_back = true
		for i in 3:
			check(not pl.place_point(centre).is_empty(), "turn %d: a step toward the centre is taken" % w.turn)
	else:
		var heading := float(u.heading)
		for i in 2:
			var p := here + Vector2.from_angle(heading + 0.12 * float(i + w.turn % 3 - 1)) * (160.0 * float(i + 1))
			check(not pl.place_point(p).is_empty(), "turn %d: a step ahead is taken" % w.turn)
	_sb.ui.select(_p1)

func _after_turns() -> void:
	var w: World = _sb.world
	eq(_resolved, TURNS, "twelve turns resolved through the turn flow")
	eq(w.turn, TURNS + 1, "and the next turn began after the last playback")
	eq(_left_bounds, 0, "nobody left the map in a minute of flight")
	for id: String in w.units:
		check(w.in_bounds(float(w.units[id].x), float(w.units[id].y)), "%s is on the map at the end" % id)
		check(_sb.tracks.point_count(id) > TURNS * 10, "%s has a track (%d points)" % [id, _sb.tracks.point_count(id)])
		check(_sb.tracks.length_m(id) > 1500.0, "%s's track is %.0f m long" % [id, _sb.tracks.length_m(id)])
	# A full circle: the circling plane's heading changed by more than 360 degrees, all one way.
	check(absf(_heading_total[_p1]) >= TAU, "plane 1 flew a full circle (%.0f degrees of heading change)" % rad_to_deg(absf(_heading_total[_p1])))
	# The AI flew on its own: the test never planned for it, and it covered ground every turn.
	check(float(_path_m[_ai]) > 12.0 * 3.0 * 85.0 * 0.9, "the AI plane flew %.0f m on its own" % float(_path_m[_ai]))
	check(_start_pos[_ai].distance_to(Vector2(float(w.units[_ai].x), float(w.units[_ai].y))) > 100.0, "and ended elsewhere")
	check(_looped_back, "plane 2 had to be steered back from an edge at least once (so the map's edge was met)")
	check(float(_path_m[_p2]) > 3000.0, "plane 2 flew %.0f m" % float(_path_m[_p2]))
	# Frames were recorded by what the game was doing.
	var played := 0
	var planned := 0
	for k: String in _sb.stats:
		if k.begins_with("playing"):
			played += int(_sb.stats[k].n)
		elif k.begins_with("planning"):
			planned += int(_sb.stats[k].n)
	check(played > 100 and planned > 0, "frame times are recorded while playing (%d frames) and planning (%d)" % [played, planned])
	_go("knobs")

# --- 6. The knobs ----------------------------------------------------------------------------------

func _knobs() -> void:
	if _phase_frames == 1:
		_knob_group_one()
	elif _phase_frames == 4:
		_knob_group_two()
	elif _phase_frames == 8:
		_prepare_scale()
		_go("scale")

func _knob_group_one() -> void:
	# Plane size.
	DebugSettings.set_choice("plane_size", 5)   # "72"
	near(_sb.plane_px, 72.0, 0.0, "the plane-size knob sets the size")
	_sb._update_plane_scale()
	var k72: float = UiStyle.shared().num("marker.true_scale")
	DebugSettings.set_choice("plane_size", 1)   # "true"
	_sb._update_plane_scale()
	check(absf(UiStyle.shared().num("marker.true_scale") - maxf(1.0, _sb.plane_min_px / (9.0 * _sb.map_view.px_per_m * _sb.map_view.get_zoom()))) < 1e-6, "'true' draws planes at the map's own scale (1x, or the minimum)")
	check(k72 > 0.0, "72 px sets a scale")
	DebugSettings.set_choice("plane_size", 0)
	near(_sb.plane_px, 36.0, 0.0, "back on data: 36 px")
	# Fog.
	DebugSettings.set_choice("fog", 2)           # off
	check(not _sb.fog.visible, "fog off hides the layer")
	check(not _sb.ui.marker_layer.unit_visible.is_valid(), "and stops hiding units")
	check(not _sb.tracks.reveals.is_valid(), "and shows every track")
	DebugSettings.set_choice("fog", 0)           # data: on
	check(_sb.fog.visible and _sb.ui.marker_layer.unit_visible.is_valid(), "fog back on")
	_check_fog_hides()
	# Edge, far zoom, line of sight, playback.
	DebugSettings.set_choice("fog_edge", 2)
	eq(_sb.fog.edge_mode, "soft", "the edge knob switches the fog's edge style")
	DebugSettings.set_choice("fog_edge", 0)
	eq(_sb.fog.edge_mode, "inked", "back on data: inked (Alex's choice)")
	DebugSettings.set_choice("far_zoom", 2)
	eq(_sb.ctl.far_mode, "full_render", "the far-zoom knob switches the controller's mode")
	eq(_sb.fog.far_mode, "full_render", "and the fog's")
	check(_sb.ctl.zoom_limit_min() >= 0.1199, "full render limits how far out the camera goes")
	DebugSettings.set_choice("far_zoom", 0)
	eq(_sb.ctl.far_mode, "overview_topo", "back on data: the topographic overview")
	DebugSettings.set_choice("line_of_sight", 2)   # terrain
	eq(_sb.fog.vision.line_of_sight, "terrain", "the line-of-sight knob reaches the vision rule")
	DebugSettings.set_choice("playback_speed", 0)
	near(UiStyle.shared().num("marker.playback_speed"), _style_playback, 0.0, "playback speed back on data")
	# Pen and tree pool (both redraw the map; headless draws nothing, so what is checked is the setting).
	DebugSettings.set_choice("pen", 1)
	eq(InkCanvas.pen_mode(), "even", "the pen knob switches the ink line")
	DebugSettings.set_choice("pen", 0)
	eq(InkCanvas.pen_mode(), "shadow_side", "back on data: the shadow-side pen (Alex's choice)")
	DebugSettings.set_choice("tree_pool", 2)
	check(_sb.map_view.baker.pool_enabled, "the tree-pool knob reaches the baker")
	DebugSettings.set_choice("tree_pool", 0)
	check(not _sb.map_view.baker.pool_enabled, "back on data: off")
	# The panel's own text.
	check(_sb.knob_text("map_scale").contains("data"), "a knob on data says so: '%s'" % _sb.knob_text("map_scale"))
	_sb.knob_step("playback_speed", 1)          # what a click on the panel's row does
	eq(DebugSettings.get_choice("playback_speed"), 1, "a click steps a knob to its next value")
	_sb.knob_step("playback_speed", -1)
	eq(DebugSettings.get_choice("playback_speed"), 0, "a right click steps it back")
	_sb.knobs.toggle()
	check(_sb.knobs.visible, "F2 opens the panel")
	# A click on a row through the panel's own handler steps its knob; a right click steps it back.
	var row: int = _sb.knobs.keys.find("playback_speed")
	check(row >= 0, "the panel lists the playback-speed knob")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = _sb.knobs.row_rect(row).get_center()
	_sb.knobs._gui_input(click)
	eq(DebugSettings.get_choice("playback_speed"), 1, "a click on the panel's row steps the knob")
	click.button_index = MOUSE_BUTTON_RIGHT
	_sb.knobs._gui_input(click)
	eq(DebugSettings.get_choice("playback_speed"), 0, "a right click steps it back")
	_sb.knobs.toggle()

# The fog hides the AI plane when it is out of the players' sight and shows it when it is in.
func _check_fog_hides() -> void:
	var w: World = _sb.world
	var ai = w.units[_ai]
	var keep := Vector2(float(ai.x), float(ai.y))
	var p1 = w.units[_p1]
	ai.x = clampf(float(p1.x) + 2000.0, 100.0, 4900.0)
	ai.y = clampf(float(p1.y) + 2000.0, 100.0, 4900.0)
	_sb._update_fog()
	_sb.ui.marker_layer.update_poses()
	check(not _sb.ui.marker_layer.marker(_ai).visible, "an AI plane 2.8 km from the players is hidden by the fog")
	check(_sb.ui.marker_layer.marker(_p1).visible, "while the players' own planes are always shown")
	ai.x = float(p1.x) + 300.0
	ai.y = float(p1.y)
	_sb._update_fog()
	_sb.ui.marker_layer.update_poses()
	check(_sb.ui.marker_layer.marker(_ai).visible, "and shown again 300 m away, inside sight")
	ai.x = keep.x
	ai.y = keep.y
	_sb._update_fog()
	_sb.ui.marker_layer.update_poses()

func _knob_group_two() -> void:
	# Line of sight needs a few frames of vision updates; then off again.
	eq(_sb.fog.vision.line_of_sight, "terrain", "line of sight stayed on terrain through the frames")
	check(_sb.fog.vision.ok(), "the vision rule is healthy with line of sight on: %s" % str(_sb.fog.vision.errors))
	DebugSettings.set_choice("line_of_sight", 0)
	eq(_sb.fog.vision.line_of_sight, "none", "back on data: no line of sight")

func _prepare_scale() -> void:
	_ppm_before = _sb.map_view.px_per_m
	_centre_before = _sb.ctl.center() / _ppm_before
	DebugSettings.set_choice("map_scale", 3)    # "3"
	near(_sb.map_view.px_per_m, 3.0, 0.0, "the map-scale knob changes MapView's scale")
	near(_sb.terrain.px_per_m, 3.0, 0.0, "and the terrain's")
	near(_sb.ctl.px_per_m, 3.0, 0.0, "and the controller's")
	near((_sb.ctl.center() / 3.0).distance_to(_centre_before), 0.0, 0.5, "the camera is still over the same metres")

func _scale() -> void:
	if _phase_frames == 3:
		_sb.ui.marker_layer.update_poses()
		var w: World = _sb.world
		for id: String in w.units:
			var want: Vector2 = _sb.map_view.world_to_screen(Vector2(float(w.units[id].x), float(w.units[id].y)))
			var mk = _sb.ui.marker_layer.marker(id)
			check(mk.position.distance_to(want) < 1e-3 or not mk.visible, "at 3 px/m: %s's marker still sits where MapView puts it" % id)
			eq(mk.visible, _sb.fog.vision.shows_unit(w, id), "%s's marker is shown exactly when the fog says it is in sight" % id)
		near(_sb.fog.topo.ppm, 3.0, 0.0, "the fog rebuilt its topographic layer for the new scale")
		_check_plane_size()
		DebugSettings.set_choice("map_scale", 0)
		near(_sb.map_view.px_per_m, 2.0, 0.0, "back on data: 2 px/m")
		near((_sb.ctl.center() / 2.0).distance_to(_centre_before), 0.0, 0.5, "and over the same metres again")
	elif _phase_frames == 6:
		near(_sb.fog.topo.ppm, 2.0, 0.0, "the fog follows back")
		_go("esc")

# --- 7. Esc ----------------------------------------------------------------------------------------------

func _esc() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.physical_keycode = KEY_ESCAPE
	ev.pressed = true
	_main._unhandled_input(ev)
	eq(_main.sandbox, null, "Esc stops the sandbox")
	check(_main.menu.visible, "and brings the menu back")
	check(_sb.is_queued_for_deletion(), "the sandbox is freed")
	var st: UiStyle = UiStyle.shared() as UiStyle
	near(st.num("marker.true_scale"), _style_true_scale, 1e-9, "the UI style's true_scale is put back")
	near(st.num("marker.playback_speed"), _style_playback, 1e-9, "and its playback speed")
	_go("again")

func _again() -> void:
	if _phase_frames < 3:
		return
	check(_main.start_sandbox(), "Local after Esc builds a fresh sandbox")
	check(_main.sandbox != _sb, "a new one, not the freed one")
	check(not _main.menu.visible, "and hides the menu again")
	var w: World = _main.sandbox.world
	eq(w.turn, 1, "it starts on turn 1")
	eq(w.units.size(), 3, "with its three units")
	_main.stop_sandbox()
	check(_main.menu.visible, "Esc once more: the menu")
	finish()
