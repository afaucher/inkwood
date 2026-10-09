extends Node2D

# THE SANDBOX (Track A, execution plan "sandbox demo"): every part built so far,
# assembled behind the menu's Local button. One node that builds, from
# data/scenarios/sandbox.json:
#
#   World + AiDumb          Track S: the units, the turn loop, the AI that flies on its own
#   Terrain                 Track T, for the main thread: heights under the shadows, the fog's
#                           topographic layer (MapView has its own, on its worker threads)
#   MapView                 Track V: the static map baked in chunks under a camera
#   CameraController        Track F: pan, zoom, follow; it OWNS MapView's camera
#   FogLayer                Track F: first in MapView's live layer, over the baked map
#   UnitUI                  Track U: markers, roster, fan, orders; mapped through MapView
#   SandboxTracks           the flown paths (this folder, proposed)
#   SandboxKnobs (F2)       the live knobs (this folder, proposed)
#   SandboxLoading          "Drawing the map..." until the first view has baked
#
#   var sb = load("res://scripts/app/sandbox.gd").new()
#   main.add_child(sb)            # builds everything in _ready
#   sb.playable                   # signal: the first view is baked, the card is gone
#   sb.shutdown(); sb.queue_free()   # back to the menu
#
# SPACES. World = metres (Track S). MapView draws in MAP px = metres x px_per_m
# (a live knob, 1-4, starting at 2) under a Camera2D that the CameraController
# drives. Track U draws in SCREEN px on its own CanvasLayers through MapView's
# world_to_screen / screen_to_world, so ink stays a true pixel width; the fog
# is the first child of MapView's live layer (map px, zooms with the map).
#
# PLANES ARE DRAWN AT THEIR OWN SCALE (decision demo-baseline: planes_drawn_at_own_scale):
# a light fighter is view.plane_px (36) wide at zoom 1 whatever the map scale,
# the other types in proportion to their size_m, and never narrower than
# view.plane_min_px on screen. Track U's marker.true_scale (a multiplier on
# the map's metres-to-pixels) is set from that every frame (UiStyle.set_num).
#
# CAMERA (proposed): the opening view frames every plane in sight and the first
# turn's carry-on flight; a roster click glides to that unit and follows it
# (through playback too) until the player pans; nothing else moves the camera.
# Mouse: LEFT plans (Track U); MIDDLE/RIGHT drag pans; wheel zooms; WASD/arrows
# pan; Q/E (and -/=) zoom (Track F, data/view/camera.json); F2 the knobs; Esc
# the menu (scripts/app/main.gd). Track U's keys: Enter, Backspace, Delete,
# PageUp/PageDown, Tab -- no clash.

signal playable
signal failed(message: String)

const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const SandboxTracks = preload("res://scripts/app/sandbox_tracks.gd")
const SandboxKnobs = preload("res://scripts/app/sandbox_knobs.gd")
const SandboxLoading = preload("res://scripts/app/sandbox_loading.gd")
const SandboxHint = preload("res://scripts/app/sandbox_hint.gd")
const World = preload("res://scripts/sim/world.gd")
const AiDumb = preload("res://scripts/sim/ai_dumb.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const CameraController = preload("res://scripts/world/camera_controller.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const SCENARIO_ID := "sandbox"
# The knobs the F2 panel lists, in order (each is registered in DebugSettings,
# section "Sandbox"). line_of_sight is added when the fog layer has it.
const KNOB_KEYS: Array[String] = ["map_scale", "plane_size", "fog", "fog_edge", "line_of_sight", "pen", "far_zoom", "tree_pool", "playback_speed"]

var scenario: SandboxScenario = null
var world: World = null
var ai: AiDumb = null
var terrain: Terrain = null
var map_view: MapView = null
var ctl: CameraController = null
var fog: FogLayer = null
var ui: UnitUI = null
var tracks: SandboxTracks = null
var knobs: SandboxKnobs = null
var loading: SandboxLoading = null    # the blocking card, then hidden
var note: SandboxLoading = null       # the small "redrawing" note
var hint: SandboxHint = null          # the keys, for the first seconds

var ids: Array[String] = []
var headless := false
var is_playable := false
var load_ms := -1.0                   # _init -> the card gone
var build_ms := -1.0                  # _ready: building every part, before the first frame
var created_ms := 0
var last_rebake_s := -1.0             # the last knob-triggered redraw, seconds to a full view
var plane_px := 36.0                  # effective: light fighter px at zoom 1; 0 = the map's own scale
var plane_min_px := 14.0
var errors: Array[String] = []
# Frame times by what the game was doing: loading, rebaking, playing (a turn
# animating), planning, and either of those two "+baking" while chunks of the
# view are still being drawn. {n, sum_ms, max_ms, over33, over100}
var stats: Dictionary = {}

var _style: UiStyle = null
var _mount: CanvasLayer = null
var _hud: CanvasLayer = null
var _top: CanvasLayer = null
var _ref_size := 9.0                  # the smallest unit's size_m: plane_px is its width
var _last_k := -1.0
var _fog_on := true
var _revealing: Dictionary = {}       # side -> true
var _frames := 0
var _load_total := 0
var _load_t0 := 0
var _rebaking := false
var _rebake_t0 := 0
var _saved_style: Dictionary = {}
var _data_ppm := 2.0
var _data := {}                       # knob key -> what "data" means (text)
var _window: Array[float] = []        # the last frame times, for frame_line()

func _init(scenario_id: String = SCENARIO_ID) -> void:
	name = "Sandbox"
	created_ms = Time.get_ticks_msec()
	scenario = SandboxScenario.new(scenario_id)

func _ready() -> void:
	process_priority = 50   # after Track U's layers and the camera: the fog and tracks see this frame's poses
	var t0 := Time.get_ticks_msec()
	_build()
	build_ms = float(Time.get_ticks_msec() - t0)

# --- Building -------------------------------------------------------------------------

func _build() -> void:
	headless = DisplayServer.get_name() == "headless"
	_style = UiStyle.shared() as UiStyle
	if not scenario.ok() or not _style.ok():
		_fail("scenario or UI style data did not load: %s %s" % [scenario.errors, _style.errors])
		return
	_data_ppm = CameraController.terrain_px_per_m()

	# The simulation.
	world = World.new()
	if not world.ok():
		_fail("simulation data did not load: %s" % [world.errors])
		return
	ids = scenario.populate(world)
	if ids.has(""):
		_fail("the scenario's units did not all load: %s" % world.last_error)
		return
	_ref_size = INF
	for id: String in ids:
		_ref_size = minf(_ref_size, float(world.units[id].def.size_m))
		if world.units[id].controller == World.CONTROLLER_PLAYER:
			_revealing[str(world.units[id].side)] = true
	ai = AiDumb.new(world)
	ai.attach()

	# The knobs that must be set before anything bakes: scale, pen, tree pool.
	_data["pen"] = InkCanvas.pen_mode()
	var ppm := _effective_ppm()
	var pen := _choice("pen")
	if pen != "data":
		InkCanvas.set_pen_mode(pen)

	terrain = Terrain.new(scenario.seed_value)
	terrain.px_per_m = ppm
	map_view = MapView.new(scenario.seed_value, Rect2(), ppm if not is_equal_approx(ppm, _data_ppm) else 0.0)
	if not map_view.errors().is_empty():
		_fail("map view data did not load: %s" % [map_view.errors()])
		return
	map_view.name = "MapView"
	map_view.bake_enabled = not headless
	_data["tree_pool"] = "on" if map_view.baker.pool_enabled else "off"
	var pool := _choice("tree_pool")
	if pool != "data":
		map_view.baker.pool_enabled = (pool == "on")
	add_child(map_view)

	# The camera is the controller's from here on.
	ctl = CameraController.new()
	ctl.name = "CameraController"
	ctl.setup_from_terrain(terrain)
	if not ctl.ok():
		_fail("camera data did not load: %s" % [ctl.errors])
		return
	ctl.bind(map_view.camera)
	map_view.add_child(ctl)
	map_view.input_enabled = false
	var inset: float = _style.num("roster.width_px") + 2.0 * _style.num("card.margin_px")
	if get_viewport().get_visible_rect().size.x < inset * 2.5:
		inset = 0.0   # a window too narrow to keep a free area beside the sidebar (a headless test's)
	ctl.set_insets(0.0, 0.0, inset, 0.0)   # the roster and orders column is on the RIGHT
	_data["far_zoom"] = ctl.far_mode

	# The fog: the first child of the live layer, over the baked map.
	fog = FogLayer.new()
	fog.name = "Fog"
	fog.setup(terrain)
	if not fog.ok():
		_fail("fog data did not load: %s" % [fog.errors])
		return
	fog.auto_bake = not headless
	fog.controller = ctl
	map_view.live_layer.add_child(fog)
	_data["fog_edge"] = fog.edge_mode
	_data["line_of_sight"] = fog.vision.line_of_sight

	# The interface, in screen space above the map: the tracks first (below the
	# markers), then Track U's planner and markers in the same layer.
	_mount = CanvasLayer.new()
	_mount.name = "MapLayer"
	_mount.layer = 1
	add_child(_mount)
	tracks = SandboxTracks.new()
	tracks.name = "Tracks"
	_mount.add_child(tracks)
	ui = UnitUI.new()
	ui.name = "UnitUI"
	add_child(ui)
	ui.setup(world, map_view, scenario.local_player, _mount, null)
	ui.marker_layer.ground_height = func(x: float, y: float) -> float: return terrain.height_at(x, y)
	ui.unit_focus_requested.connect(_on_focus_requested)
	tracks.setup(world, map_view, ui.marker_layer, _style, scenario.view_num("track_sample_s"), scenario.view_num("track_line_px"))
	_saved_style = {"marker.true_scale": _style.num("marker.true_scale"), "marker.playback_speed": _style.num("marker.playback_speed")}
	_data["playback_speed"] = String.num(_style.num("marker.playback_speed"), 2)

	# The knob panel, then the loading card above everything.
	_hud = CanvasLayer.new()
	_hud.name = "KnobLayer"
	_hud.layer = 3
	add_child(_hud)
	knobs = SandboxKnobs.new()
	knobs.name = "Knobs"
	_hud.add_child(knobs)
	knobs.setup(self, _style)
	hint = SandboxHint.new()
	hint.name = "Hint"
	_hud.add_child(hint)
	hint.setup(_style, "F2 knobs   ·   Esc menu   ·   right-drag or WASD pans   ·   wheel or Q E zooms   ·   %s readies" % _style.text("keys.ready"), 16.0)
	_top = CanvasLayer.new()
	_top.name = "LoadingLayer"
	_top.layer = 20
	add_child(_top)
	note = SandboxLoading.new()
	note.name = "RedrawNote"
	_top.add_child(note)
	note.setup(_style, false, "Redrawing the map…")
	note.visible = false
	loading = SandboxLoading.new()
	loading.name = "Loading"
	_top.add_child(loading)
	loading.setup(_style, true)
	loading.seed_text = scenario.seed_value

	# Knobs that need the parts: apply every one to the data's state.
	plane_min_px = scenario.view_num("plane_min_px")
	_apply_all_knobs()
	DebugSettings.changed.connect(_on_knob_changed)

	# The first view: every plane in sight and where the first turn takes it.
	_update_fog()
	_frame_start_view()
	if not ui.roster.ordered_ids().is_empty():
		ui.select(ui.roster.ordered_ids()[0])
	_load_t0 = Time.get_ticks_msec()
	_load_total = _view_chunk_total()
	_update_plane_scale()

func _fail(message: String) -> void:
	errors.append(message)
	push_error("Sandbox: " + message)
	failed.emit(message)

func ok() -> bool:
	return errors.is_empty() and world != null

# --- The frame ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not ok():
		return
	_frames += 1
	_fit_overlays()
	_update_plane_scale()
	_pause_baking_at_overview()
	_update_fog()
	if not is_playable:
		_check_loading()
	elif _rebaking:
		_check_rebake()
	_record_frame(delta)

# Fully zoomed out the topographic overview covers the baked map entirely
# (Track F), so the full render of the whole map -- 100 chunks of 4 MB -- is not
# worth baking: MapView only bakes while any of the full render shows through.
func _pause_baking_at_overview() -> void:
	if headless:
		return
	var want: bool = ctl.overview_amount() < 0.999
	if map_view.bake_enabled != want:
		map_view.bake_enabled = want

# Controls mounted straight in a CanvasLayer (Track U's HUD, the loading card)
# take their size from the viewport through anchors, and in the real window
# that came out ZERO-sized (observed 2026-10-09: the roster at x = -300 and the
# card centred off screen), so the sandbox sizes them to the viewport itself,
# every frame -- which also follows a resized window.
func _fit_overlays() -> void:
	var vs := get_viewport().get_visible_rect().size
	for c: Control in [ui.hud, loading, note, hint]:
		if c.size != vs or c.position != Vector2.ZERO:
			c.position = Vector2.ZERO
			c.size = vs
			if c == ui.hud:
				ui.layout()

# Planes keep their own on-screen size: Track U's marker.true_scale is the
# multiplier from the map's metres to pixels, so it is the wanted size over the
# smallest plane's size_m, the map scale and the zoom -- never below the minimum.
func _update_plane_scale() -> void:
	var ppm: float = map_view.px_per_m
	var z: float = maxf(map_view.get_zoom(), 1e-6)
	var base := 1.0 if plane_px <= 0.0 else plane_px / (_ref_size * ppm)
	var floor_k := plane_min_px / (_ref_size * ppm * z)
	var k := maxf(base, floor_k)
	if _last_k < 0.0 or absf(k - _last_k) > _last_k * 0.004:
		_last_k = k
		_style.set_num("marker.true_scale", k)

# The fog's circles follow the units (where the markers are drawn, mid-playback included).
func _update_fog() -> void:
	if not _fog_on or fog == null:
		return
	var t := -1.0
	if ui != null and ui.marker_layer.is_playing():
		t = ui.marker_layer.playback_t
	fog.vision.update_from_world(world, t, "history")

# --- Loading -----------------------------------------------------------------------------

func _check_loading() -> void:
	var missing: int = map_view.missing_in_view()
	var secs := (Time.get_ticks_msec() - _load_t0) / 1000.0
	loading.set_progress(maxi(_load_total - missing, 0), _load_total, secs)
	if headless or (missing == 0 and _frames > 3):
		_finish_loading()

func _finish_loading() -> void:
	is_playable = true
	loading.visible = false
	hint.start()
	load_ms = float(Time.get_ticks_msec() - created_ms)
	print("[Sandbox] first playable frame %.0f ms after the sandbox was created (building the parts %.0f ms; first view of %d chunks, %s)" % [
		load_ms, build_ms, _load_total, "headless: no bake" if headless else "baked"])
	playable.emit()

func _check_rebake() -> void:
	var missing: int = map_view.missing_in_view()
	var secs := (Time.get_ticks_msec() - _rebake_t0) / 1000.0
	note.set_progress(maxi(_load_total - missing, 0), _load_total, secs)
	if headless or (missing == 0 and _frames > 3):
		_rebaking = false
		note.visible = false
		last_rebake_s = secs
		print("[Sandbox] map redrawn in %.1f s" % secs)

func _begin_rebake(clear_chunks: bool = true) -> void:
	if clear_chunks:
		map_view.rebake()
	if headless:
		return
	_rebaking = true
	_rebake_t0 = Time.get_ticks_msec()
	_load_total = _view_chunk_total()
	note.set_progress(0, _load_total, 0.0)
	note.visible = true

# How many baked chunks the current view needs.
func _view_chunk_total() -> int:
	var r: Rect2 = map_view.view_rect().intersection(map_view.map_rect())
	if not r.has_area():
		return 0
	var cp: float = map_view.chunk_px
	var nx := floori((r.end.x - 0.001) / cp) - floori(r.position.x / cp) + 1
	var ny := floori((r.end.y - 0.001) / cp) - floori(r.position.y / cp) + 1
	return nx * ny

# --- Camera ---------------------------------------------------------------------------------

# Frame every plane in sight and the end of its carry-on flight this turn (and
# the next ones, view.start_look_ahead_turns): the first screen shows the action.
func _frame_start_view() -> void:
	var pts: Array = []
	for id: String in ids:
		if not _in_sight(id):
			continue
		var u = world.units[id]
		var at: Array = [Vector2(float(u.x), float(u.y))]
		var st: Array = world.planned_states(id)
		if not st.is_empty():
			var last: Dictionary = st[st.size() - 1]
			var a := Vector2(float(u.x), float(u.y))
			var b := Vector2(float(last["x"]), float(last["y"]))
			at.append(a + (b - a) * maxf(scenario.view_num("start_look_ahead_turns"), 0.0))
		# A margin round every plane and its carry-on end, so none sits on the screen's edge.
		var pad := scenario.view_num("start_pad_m")
		for p: Vector2 in at:
			for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				pts.append(p + corner * pad)
	var old_max := ctl.frame_max_zoom
	ctl.frame_max_zoom = minf(old_max, scenario.view_num("start_zoom_max"))
	ctl.frame_points(pts)
	ctl.frame_max_zoom = old_max

func _in_sight(id: String) -> bool:
	if not _fog_on or fog == null:
		return true
	return fog.vision.shows_unit(world, id)

# A roster click: glide to the unit and follow it -- through the playback, where
# the marker is, not where the turn ends -- until the player pans.
func _on_focus_requested(id: String, _p: Vector2) -> void:
	follow_unit(id)

func follow_unit(id: String) -> void:
	if not world.units.has(id):
		return
	ctl.follow(func() -> Variant:
		if not world.units.has(id) or ui == null:
			return null
		var pose: Dictionary = ui.marker_layer.pose_of(id)
		var p := Vector2(float(pose["x"]), float(pose["y"]))
		# Centre the unit in the part of the screen the sidebar leaves free.
		var z := maxf(ctl.zoom_level(), 1e-6)
		return p + Vector2(ctl.insets.right * 0.5 / (z * ctl.px_per_m), 0.0))

# --- Input ------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if not ok():
		return
	if event is InputEventKey and (event as InputEventKey).pressed and not (event as InputEventKey).echo:
		if (event as InputEventKey).keycode == KEY_F2:
			knobs.toggle()
			get_viewport().set_input_as_handled()

# --- Knobs ---------------------------------------------------------------------------------------

func knob_keys() -> Array[String]:
	var out: Array[String] = []
	for k: String in KNOB_KEYS:
		if k == "line_of_sight" and (fog == null or not fog.vision.has_method("set_line_of_sight")):
			continue
		out.append(k)
	return out

func knob_label(key: String) -> String:
	return str(DebugSettings.OPTIONS[key]["label"])

func _choice(key: String) -> String:
	return str(DebugSettings.get_choice_name(key))

func knob_step(key: String, dir: int) -> void:
	var n: int = (DebugSettings.OPTIONS[key]["choices"] as Array).size()
	DebugSettings.set_choice(key, posmod(DebugSettings.get_choice(key) + dir, n))

# The value as the panel reads it: "2 (data)" while on "data".
func knob_text(key: String) -> String:
	var c := _choice(key)
	if c == "data":
		return "%s (data)" % _resolved_text(key)
	return _shown(key, c)

func _shown(key: String, c: String) -> String:
	match key:
		"map_scale":
			return "%s px/m" % c
		"plane_size":
			return "true scale" if c == "true" else "%s px" % c
		"playback_speed":
			return "x%s" % c
	return c

func _resolved_text(key: String) -> String:
	match key:
		"map_scale":
			return "%s px/m" % String.num(_data_ppm, 2)
		"plane_size":
			var px := scenario.view_num("plane_px")
			return "true scale" if px <= 0.0 else "%s px" % String.num(px, 1)
		"fog":
			return "on" if scenario.view_flag("fog") else "off"
		"playback_speed":
			return "x%s" % str(_data.get(key, "1"))
	return str(_data.get(key, "?"))

func _effective_ppm() -> float:
	var c := _choice("map_scale")
	return _data_ppm if c == "data" else float(c)

func _effective_plane_px() -> float:
	var c := _choice("plane_size")
	if c == "data":
		return scenario.view_num("plane_px")
	return 0.0 if c == "true" else float(c)

func _effective_fog() -> bool:
	var c := _choice("fog")
	return scenario.view_flag("fog") if c == "data" else c == "on"

func _apply_all_knobs() -> void:
	for k: String in KNOB_KEYS:
		_apply_knob(k, true)

func _on_knob_changed(key: String, _value: Variant) -> void:
	if ok() and KNOB_KEYS.has(key):
		_apply_knob(key, false)

# `startup`: the parts exist but nothing has baked yet, so the knobs that rebake
# (scale, pen, pool) have already been applied while building.
func _apply_knob(key: String, startup: bool) -> void:
	var c := _choice(key)
	match key:
		"map_scale":
			if not startup:
				set_map_scale(_effective_ppm())
		"plane_size":
			plane_px = _effective_plane_px()
			_update_plane_scale()
		"fog":
			_set_fog(_effective_fog())
		"fog_edge":
			fog.set_edge_mode(str(_data["fog_edge"]) if c == "data" else c)
		"line_of_sight":
			if fog.vision.has_method("set_line_of_sight"):
				fog.vision.set_line_of_sight(str(_data["line_of_sight"]) if c == "data" else c)
		"pen":
			if not startup:
				InkCanvas.set_pen_mode(str(_data["pen"]) if c == "data" else c)
				_begin_rebake()
				fog.set_terrain(terrain)   # its topographic layer is inked with the same pen
		"far_zoom":
			var mode := str(_data["far_zoom"]) if c == "data" else c
			ctl.far_mode = mode
			fog.far_mode = mode
			ctl.set_view(ctl.center(), ctl.zoom_level())   # a new zoom-out limit may apply
		"tree_pool":
			if not startup:
				map_view.baker.pool_enabled = (str(_data["tree_pool"]) == "on") if c == "data" else (c == "on")
				_begin_rebake()
		"playback_speed":
			_style.set_num("marker.playback_speed", float(str(_data["playback_speed"])) if c == "data" else float(c))

func _set_fog(on: bool) -> void:
	_fog_on = on
	fog.visible = on
	fog.process_mode = Node.PROCESS_MODE_INHERIT if on else Node.PROCESS_MODE_DISABLED
	fog.mask_viewport().render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if on:
		_update_fog()
		ui.marker_layer.unit_visible = fog.vision.unit_visible(world)
		tracks.reveals = func(id: String) -> bool: return _revealing.has(str(world.units[id].side))
		tracks.point_visible = func(p: Vector2) -> bool: return fog.vision.is_visible(p)
	else:
		ui.marker_layer.unit_visible = Callable()
		tracks.reveals = Callable()
		tracks.point_visible = Callable()

# A new map scale, live: MapView redraws (its camera is converted and put back,
# because the controller owns the camera), Terrain follows, the controller keeps
# the view on the same metres and the same zoom, the fog rebuilds its layer when
# it sees the terrain change.
func set_map_scale(v: float) -> void:
	if v <= 0.0 or is_equal_approx(v, map_view.px_per_m):
		return
	var cam_pos: Vector2 = ctl.camera.position
	map_view.set_px_per_m(v)
	ctl.camera.position = cam_pos
	terrain.px_per_m = v
	terrain.clear_cache()
	ctl.set_scale(terrain.map_rect_px(), v)
	_begin_rebake(false)   # MapView.set_px_per_m already dropped every chunk
	_update_plane_scale()

# --- Frame times ----------------------------------------------------------------------------------

func _category() -> String:
	if not is_playable:
		return "loading"
	if _rebaking:
		return "rebaking"
	var what := "playing" if (ui != null and ui.marker_layer.is_playing()) else "planning"
	# Chunks still being baked for the view the camera has moved to cost frames of their own.
	return what + "+baking" if map_view.missing_in_view() > 0 else what

func _record_frame(delta: float) -> void:
	var ms := delta * 1000.0
	var cat := _category()
	var s: Dictionary = stats.get(cat, {"n": 0, "sum_ms": 0.0, "max_ms": 0.0, "over33": 0, "over100": 0})
	s.n += 1
	s.sum_ms += ms
	s.max_ms = maxf(s.max_ms, ms)
	if ms > 33.4:
		s.over33 += 1
	if ms > 100.0:
		s.over100 += 1
	stats[cat] = s
	_window.append(ms)
	if _window.size() > 90:
		_window.pop_front()

func reset_stats() -> void:
	stats.clear()
	_window.clear()

# One line for the knob panel: recent frame times.
func frame_line() -> String:
	if _window.is_empty():
		return "frame -"
	var sum := 0.0
	var worst := 0.0
	for ms: float in _window:
		sum += ms
		worst = maxf(worst, ms)
	return "frame %.1f ms (worst %.0f)  turn %d" % [sum / float(_window.size()), worst, world.turn if world != null else 0]

# --- Teardown ----------------------------------------------------------------------------------------

# Everything a run changed outside its own nodes put back: the UI style's two
# numbers, the knob signal; the map view's bake jobs dropped.
func shutdown() -> void:
	if DebugSettings.changed.is_connected(_on_knob_changed):
		DebugSettings.changed.disconnect(_on_knob_changed)
	if _style != null:
		for k: String in _saved_style:
			_style.set_num(k, float(_saved_style[k]))
	if is_instance_valid(map_view) and map_view.baker != null:
		map_view.baker.clear()
	if is_instance_valid(ctl):
		ctl.stop_follow()

func _exit_tree() -> void:
	shutdown()
