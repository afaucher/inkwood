extends Node2D

# THE MAP VIEW (Track V): the static map -- paper, ground, terrain, vegetation,
# structures, their shadows, grain -- baked ONCE per chunk into a texture and
# shown under a Camera2D. Only what moves is drawn live, above it: units,
# their shadows, fog, UI.
#
#   var view = load("res://scripts/render/map_view.gd").new(seed)   # bounds and scale from data
#   parent.add_child(view)                     # bakes the chunks around the camera from then on
#
# THE API OTHER TRACKS USE (names fixed; Track U and F bind to them):
#   world_to_screen(p_m: Vector2) -> Vector2   metres -> VIEWPORT pixels, camera included
#   screen_to_world(p: Vector2) -> Vector2     viewport pixels -> metres
#   look_at_m(p_m: Vector2)                    centre the view on a point (metres) -- for a
#                                              MapView that drives its OWN camera (tools,
#                                              tests). With a camera controller (the sandbox)
#                                              it does nothing: the controller's follow() /
#                                              set_view() / frame_points() are the way, and a
#                                              roster click (Track U's unit_focus_requested)
#                                              goes to its follow, as sandbox.gd does
#   camera: Camera2D                           the view's camera, a child, in MAP px. Track
#                                              F's camera_controller.gd drives it (or another,
#                                              via use_camera(cam)); MapView reads its bake
#                                              window from whichever camera is current
#   use_camera(cam)                            hand the camera to a controller: MapView's
#                                              input is off and look_at_m, follow, set_zoom
#                                              and the _process easing do nothing from then on
#                                              (camera_controlled), so they cannot fight it
#   input_enabled: bool                        MapView's own fallback input (WASD, drag, wheel)
#   live_layer: Node2D                         above the map, in MAP px (zooms with it): for
#                                              Track F's fog if it suits; U draws in screen
#                                              space on its own CanvasLayers instead
#   px_per_m, set_px_per_m(v)                  the scale; a live knob (1..4 tried): regenerate,
#                                              rebake, camera kept on the same metres
#   m_to_map(p_m) / map_to_m(p_px)             metres <-> map px
#   follow(p_m or null), set_zoom(z)           the own-camera helpers (no-ops once controlled)
#   get_zoom(), view_rect(), missing_in_view(), rebake()
#   signal chunk_baked(c: Vector2i)
#
# COORDINATES: WORLD = metres (Track S's units: bounds, unit positions).
# MAP px = metres x px_per_m, the space the chunks, the camera and live_layer
# live in (the prototype's pixels: a 38 px canopy). SCREEN = viewport pixels.
# bounds_m and px_per_m default to the data (Track S's map_bounds_m in
# data/sim/turn.json through Track T's terrain; T's scale.px_per_m in
# data/terrain/terrain.json, 2 today).
#
# BAKING: chunk_baker.gd, a few steps a frame within map_view.bake_budget_ms
# of main-thread time (recording runs on worker threads, read-backs are
# asynchronous), in this ORDER (map-performance track, 2026-10-10, all proposed
# data under map_view): the chunks the player can see first, nearest the centre
# first; then the view's chunks wholly under the fog's opaque topographic layer
# (hidden_test: set it to FogLayer.rect_under_fog); then a ring of
# prefetch_chunks round the view, leaning along the camera's recent motion
# (further ahead, nothing behind: prefetch_ahead_extra_chunks,
# prefetch_behind_chunks, motion_px_s), and the terrain one ring further. Each group is
# only REQUESTED once the one before it is baked (ring_after_view), so a ring job
# never takes a job slot, worker threads or the budget from a chunk the player
# waits for; the baker itself steps jobs and sprite pages nearest first.
# bake_boost raises the budget to bake_budget_loading_ms (a loading card is up).
# Up to max_cached_chunks kept, the
# furthest dropped first -- the cap HOLDS (fix pass, 2026-10-09): a chunk is
# asked for only if it fits under it, and the keep ring (keep_chunks) is only
# what is left over, not a reason to go past it. The one exception is the view
# itself: the chunks the view shows are never dropped for the cap (a window
# that shows more than max_cached_chunks, 1080p near the far zoom, would else
# show holes and never finish loading), so the cap is max(max_cached_chunks,
# the chunks in view). A chunk not baked yet shows plain paper. Content
# from chunk_terrain_provider.gd (Track T's terrain, the default) or
# chunk_scene_provider.gd (the prototype stand-in): map_view.provider in data.
# Chunk borders do not show: every object that reaches a chunk is drawn by it,
# and paper, dirt and grain are anchored to the world.
#
# ZOOM WITHOUT SHIMMER: every chunk texture carries MIPMAPS (made from the
# baked image when it is read back) and is drawn LINEAR_WITH_MIPMAPS, so a
# zoomed-out view samples a box-filtered level whose texels are about a screen
# pixel -- ink lines thin to a tone instead of crawling. Chosen over a second
# bake per zoom band because a mip level IS that lower-resolution bake, for
# 33% more memory and no extra drawing. Below Track F's far-zoom threshold the
# topographic overview takes over (data/view/camera.json), so the full render
# is not baked for the whole map at once.
#
# FALLBACK INPUT (input_enabled; Track F's controller replaces it): WASD /
# arrows and the screen edges pan, a MIDDLE- or RIGHT-button drag pans, the
# wheel zooms about the cursor. Never the left button: it is the planner's.

signal chunk_baked(c: Vector2i)

const ChunkBaker = preload("res://scripts/render/chunk_baker.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")
const ChunkSceneProvider = preload("res://scripts/render/chunk_scene_provider.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

var seed_value: int
var bounds_m: Rect2
var px_per_m: float
var cfg: Dictionary = {}
var P: RenderParams
var provider: RefCounted
var baker: ChunkBaker
var provider_kind: String

var camera: Camera2D
var map_layer: Node2D
var live_layer: Node2D
var background: Polygon2D

var zoom_min := 0.25
var zoom_max := 2.0
var wheel_step := 1.15
var pan_speed := 1200.0
var edge_px := 10.0
var edge_pan := true
var input_enabled := true
var bake_enabled := true
# A camera controller has the camera (use_camera): the own-camera helpers below
# stand down.
var camera_controlled := false
var follow_speed := 6.0      # 1/s: how fast the camera eases to its target

var chunk_px := 1024
# (rect_px: Rect2) -> bool: is this map-px rectangle wholly under the fog's opaque
# topographic layer (FogLayer.rect_under_fog)? Chunks that are hidden bake after the
# visible ones. Unset: nothing is hidden.
var hidden_test: Callable = Callable()
# The sandbox sets this while its loading card is up: the baker then spends
# map_view.bake_budget_loading_ms of main-thread time a frame instead of
# bake_budget_ms (nobody is playing, so a long frame costs nothing).
var bake_boost := false
# The camera's recent motion, map px / s (track_motion): the prefetch ring leans
# along it.
var motion_px_s := Vector2.ZERO
var _motion: Array = []       # [[seconds, view centre]]
var _chunks: Dictionary = {}  # Vector2i -> Sprite2D
var _target: Variant = null   # Vector2 (map px) to ease to, or null
var _dragging := false
var _errors: Array[String] = []

# seed: the world's seed; bounds_m: the map in metres (empty: from data);
# px_per_m: map pixels per metre (0: from data); kind: "terrain" or "scene"
# ("": from data). `params` lets a caller pass its own RenderParams (it is
# used as is: the providers switch its road off).
func _init(seed_v: int = 20261009, bounds: Rect2 = Rect2(), ppm: float = 0.0, kind: String = "",
		params: RenderParams = null) -> void:
	seed_value = seed_v
	P = params if params != null else RenderParams.new()
	cfg = load_config(P.source_path)
	chunk_px = int(cfg.get("chunk_px", 1024))
	provider_kind = kind if kind != "" else str(cfg.get("provider", "terrain"))
	if provider_kind == "scene":
		provider = ChunkSceneProvider.new(seed_v, P, cfg)
		px_per_m = ppm if ppm > 0.0 else _terrain_px_per_m()
		bounds_m = bounds if bounds.has_area() else _sim_bounds()
	else:
		provider = ChunkTerrainProvider.new(seed_v, P, cfg, ppm)
		px_per_m = provider.px_per_m()
		var mr: Rect2 = provider.map_rect_px()
		bounds_m = bounds if bounds.has_area() else Rect2(mr.position / px_per_m, mr.size / px_per_m)
		if not provider.ok():
			_errors.append_array(provider.errors)
	var z: Dictionary = cfg.get("zoom", {})
	zoom_min = float(z.get("min", zoom_min))
	zoom_max = float(z.get("max", zoom_max))
	wheel_step = float(z.get("wheel_step", wheel_step))
	var pan: Dictionary = cfg.get("pan", {})
	pan_speed = float(pan.get("keys_px_per_s", pan_speed))
	edge_px = float(pan.get("edge_px", edge_px))
	edge_pan = bool(pan.get("edge", edge_pan))
	baker = ChunkBaker.new(provider, P, cfg)

	background = Polygon2D.new()
	background.name = "Paper"
	background.color = P.PAPER
	add_child(background)
	map_layer = Node2D.new()
	map_layer.name = "Map"
	add_child(map_layer)
	live_layer = Node2D.new()
	live_layer.name = "Live"
	add_child(live_layer)
	camera = Camera2D.new()
	camera.name = "Camera"
	add_child(camera)
	_update_background()
	camera.position = map_rect().get_center()
	set_zoom(float(z.get("start", 1.0)))

func _ready() -> void:
	camera.make_current()

func errors() -> Array[String]:
	return _errors

# The map_view section of render_defaults.json, flattened: an entry with a
# `value` becomes that value; other sections stay as they are.
static func load_config(path: String) -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	var mv: Dictionary = (raw as Dictionary).get("map_view", {}) if raw is Dictionary else {}
	var out: Dictionary = {}
	for k: String in mv:
		var v: Variant = mv[k]
		out[k] = (v as Dictionary).get("value") if v is Dictionary and (v as Dictionary).has("value") else v
	return out

static func _terrain_px_per_m() -> float:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(ChunkTerrainProvider.TERRAIN_DATA_PATH))
	if raw is Dictionary:
		var v: Variant = (((raw as Dictionary).get("scale", {}) as Dictionary).get("px_per_m", {}) as Dictionary).get("value")
		if v is float or v is int:
			return float(v)
	return 4.0

static func _sim_bounds() -> Rect2:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/turn.json"))
	if raw is Dictionary:
		var b: Variant = ((raw as Dictionary).get("map_bounds_m", {}) as Dictionary).get("value")
		if b is Dictionary:
			return Rect2(float(b.get("x", 0)), float(b.get("y", 0)), float(b.get("width", 5000)), float(b.get("height", 5000)))
	return Rect2(0, 0, 5000, 5000)

# --- coordinates ---------------------------------------------------------------------

func m_to_map(p_m: Vector2) -> Vector2:
	return p_m * px_per_m

func map_to_m(p_px: Vector2) -> Vector2:
	return p_px / px_per_m

# Metres -> viewport pixels, through the camera.
func world_to_screen(p_m: Vector2) -> Vector2:
	return get_global_transform_with_canvas() * m_to_map(p_m)

# Viewport pixels -> metres.
func screen_to_world(p_screen: Vector2) -> Vector2:
	return map_to_m(get_global_transform_with_canvas().affine_inverse() * p_screen)

# The map in map px.
func map_rect() -> Rect2:
	return Rect2(bounds_m.position * px_per_m, bounds_m.size * px_per_m)

# What the viewport shows, in map px: the viewport rectangle through the
# inverse of the canvas transform -- whichever Camera2D is current (this
# view's own, or Track F's camera controller driving another one).
func view_rect() -> Rect2:
	if not is_inside_tree():
		var half := Vector2(1280, 720) * 0.5 / camera.zoom.x
		return Rect2(camera.position - half, half * 2.0)
	var inv := get_global_transform_with_canvas().affine_inverse()
	var vs := get_viewport_rect().size
	var r := Rect2(inv * Vector2.ZERO, Vector2.ZERO)
	for p: Vector2 in [Vector2(vs.x, 0.0), Vector2(0.0, vs.y), vs]:
		r = r.expand(inv * p)
	return r

# Hands the camera to another controller (Track F's camera_controller.gd):
# MapView stops moving its own Camera2D and takes its bake window from
# whatever camera is current. `cam`, if given, is made current.
func use_camera(cam: Camera2D) -> void:
	input_enabled = false
	camera_controlled = true
	_target = null
	if cam != null and cam != camera:
		external_camera = cam
		cam.make_current()

var external_camera: Camera2D = null

# --- camera ------------------------------------------------------------------------------

func set_zoom(z: float) -> void:
	if camera_controlled:
		_controlled("set_zoom")
		return
	z = clampf(z, zoom_min, zoom_max)
	camera.zoom = Vector2(z, z)

# The zoom the viewport shows the map at (screen px per map px), whichever
# camera is current.
func get_zoom() -> float:
	if is_inside_tree():
		return get_global_transform_with_canvas().get_scale().x
	return camera.zoom.x

# Jumps the camera to a point (metres) -- this view's own camera. Does nothing
# once a controller has the camera (use_camera): its set_view() is the way.
func look_at_m(p_m: Vector2) -> void:
	if camera_controlled:
		_controlled("look_at_m")
		return
	_target = null
	var z := camera.zoom.x
	camera.position = (_clamp_to_map(m_to_map(p_m)) * z).round() / z  # whole screen pixels (see _process)

# Eases the camera to a point (metres) over the next frames: the way to
# follow a unit through its turn animation. null stops following. Does nothing
# once a controller has the camera (use_camera): its follow() is the way.
func follow(p_m: Variant) -> void:
	if camera_controlled:
		_controlled("follow")
		return
	_target = null if p_m == null else _clamp_to_map(m_to_map(p_m))

var _warned_controlled: Dictionary = {}

# A helper was called that would move a camera a controller owns: say so once.
func _controlled(helper: String) -> void:
	if not _warned_controlled.has(helper):
		_warned_controlled[helper] = true
		push_warning("MapView.%s ignored: a camera controller owns the camera (use its set_view / follow)" % helper)

func _clamp_to_map(p: Vector2) -> Vector2:
	var r := map_rect()
	return Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))

# A new scale (map px per metre), e.g. as a demo knob: the providers
# regenerate in the new pixels, every chunk is rebaked, and the camera stays
# over the same point of the world.
func set_px_per_m(v: float) -> void:
	if v <= 0.0 or v == px_per_m:
		return
	var centre_m := map_to_m(camera.position)
	var target_m: Variant = null if _target == null else map_to_m(_target)
	px_per_m = v
	if provider.has_method("set_px_per_m"):
		provider.set_px_per_m(v)
	rebake()
	_update_background()
	camera.position = m_to_map(centre_m)
	if target_m != null:
		_target = m_to_map(target_m)

# Drops every baked chunk and sprite and bakes again (a scale, pen or
# parameter change).
func rebake() -> void:
	baker.clear()
	for c: Vector2i in _chunks:
		(_chunks[c] as Node).queue_free()
	_chunks.clear()

func _update_background() -> void:
	var r := map_rect()
	background.polygon = PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])

# --- the frame ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	# The camera is MapView's to move only while its own fallback controller
	# is on (input_enabled) or it is following, and no controller has been handed
	# the camera (camera_controlled); otherwise whoever drives it (Track F's
	# camera_controller.gd) owns position, limits and smoothing -- the easing and
	# the clamp to the map below would fight it (its pan margin reaches past the
	# map's edge).
	if not camera_controlled and (input_enabled or _target != null):
		if input_enabled:
			_pan_input(delta)
		if _target != null:
			var t: Vector2 = _target
			var k := 1.0 - exp(-follow_speed * delta)
			camera.position = camera.position.lerp(t, k)
		camera.position = _clamp_to_map(camera.position)
		# Whole screen pixels: a camera between pixels samples every chunk
		# texture between texels and the ink goes soft (seen at zoom 1 against
		# Track T's own frame of the same spot). Proposed for F's controller too.
		var z := camera.zoom.x
		camera.position = (camera.position * z).round() / z
	if bake_enabled:
		track_motion()
		_schedule()
		var budget_ms := float(cfg.get("bake_budget_loading_ms", 6.0)) if bake_boost else float(cfg.get("bake_budget_ms", 6.0))
		for r: Dictionary in baker.step(int(budget_ms * 1000.0)):
			_show(r.c, r.texture)

func _pan_input(delta: float) -> void:
	var d := Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		d.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		d.x += 1.0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		d.y -= 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		d.y += 1.0
	if edge_pan and is_inside_tree() and DisplayServer.window_is_focused():
		var vp := get_viewport()
		var m := vp.get_mouse_position()
		var vs := vp.get_visible_rect().size
		if Rect2(Vector2.ZERO, vs).has_point(m):
			if m.x < edge_px:
				d.x -= 1.0
			elif m.x > vs.x - edge_px:
				d.x += 1.0
			if m.y < edge_px:
				d.y -= 1.0
			elif m.y > vs.y - edge_px:
				d.y += 1.0
	if d != Vector2.ZERO:
		_target = null
		camera.position += d.normalized() * pan_speed * delta / camera.zoom.x

func _unhandled_input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var before := get_global_transform_with_canvas().affine_inverse() * mb.position
			set_zoom(get_zoom() * (wheel_step if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / wheel_step))
			var after := get_global_transform_with_canvas().affine_inverse() * mb.position
			camera.position += before - after  # zoom about the cursor
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
	elif event is InputEventMouseMotion and _dragging:
		_target = null
		camera.position -= (event as InputEventMouseMotion).relative / camera.zoom.x

# Requests the chunks the view needs and cancels queued ones it no longer
# does. THE ORDER (map_view.priority_offsets, proposed): the view's own chunks
# first, nearest the centre first; then the view's chunks wholly under the
# fog's opaque topographic layer (hidden_test: nobody sees them until a unit's
# sight reaches them); then the ring of prefetch chunks round the view, biased
# along the camera's recent motion. With map_view.ring_after_view each later
# group is only REQUESTED once every chunk of the earlier ones is baked: a
# ring job started while a view chunk is missing took a job slot, worker
# threads and the main thread's budget from the chunk the player is waiting
# for (and the ring's terrain generation waits too).
func _schedule() -> void:
	var view := view_rect()
	var pre := int(cfg.get("prefetch_chunks", 1))
	var c0 := Vector2i(floori(view.position.x / chunk_px), floori(view.position.y / chunk_px))
	var c1 := Vector2i(floori(view.end.x / chunk_px), floori(view.end.y / chunk_px))
	var mr := map_rect()
	var m0 := Vector2i(floori(mr.position.x / chunk_px), floori(mr.position.y / chunk_px))
	var m1 := Vector2i(ceili(mr.end.x / chunk_px) - 1, ceili(mr.end.y / chunk_px) - 1)
	var centre := view.get_center() / float(chunk_px)
	var dir := motion_dir()
	var ahead := int(cfg.get("prefetch_ahead_extra_chunks", 0))
	var behind := int(cfg.get("prefetch_behind_chunks", pre))
	var bias := float(cfg.get("prefetch_bias", 0.0))
	var offs: Dictionary = cfg.get("priority_offsets", {})
	var off_fogged_view := float(offs.get("fogged_view", 50.0))
	var off_ring := float(offs.get("ring", 100.0))
	var off_fogged_ring := float(offs.get("fogged_ring", 50.0))
	var reach := pre + (ahead if dir != Vector2.ZERO else 0)
	var wanted: Dictionary = {}   # Vector2i -> priority: the view and its ring (what the cache holds)
	var tier: Dictionary = {}     # Vector2i -> 0 view, 1 view under the fog, 2 ring
	var in_view := 0
	var missing := [0, 0, 0]
	for cy in range(maxi(c0.y - reach, m0.y), mini(c1.y + reach, m1.y) + 1):
		for cx in range(maxi(c0.x - reach, m0.x), mini(c1.x + reach, m1.x) + 1):
			var c := Vector2i(cx, cy)
			var visible := cx >= c0.x and cx <= c1.x and cy >= c0.y and cy <= c1.y
			var to := (Vector2(cx, cy) + Vector2(0.5, 0.5)) - centre
			var d := to.length()
			var hidden: bool = hidden_test.is_valid() and bool(hidden_test.call(Rect2(Vector2(c * chunk_px), Vector2(chunk_px, chunk_px))))
			var t := 0
			var prio := d
			if visible:
				in_view += 1
				if hidden:
					t = 1
					prio = off_fogged_view + d
			else:
				# the ring: pre chunks round the view, more ahead of the camera's motion
				# and fewer behind it; a chunk is in only if both of its axes are
				var dx := maxi(c0.x - cx, cx - c1.x)
				var dy := maxi(c0.y - cy, cy - c1.y)
				if (dx > 0 and dx > _ring_depth(1 if cx > c1.x else -1, dir.x, pre, ahead, behind)) \
						or (dy > 0 and dy > _ring_depth(1 if cy > c1.y else -1, dir.y, pre, ahead, behind)):
					continue
				t = 2
				prio = off_ring + d + (off_fogged_ring if hidden else 0.0)
				if dir != Vector2.ZERO and d > 0.0:
					prio -= bias * dir.dot(to / d)
			wanted[c] = prio
			tier[c] = t
			if not _chunks.has(c):
				missing[t] += 1
	# The cache cap holds (see the header): ask for no more chunks than fit under
	# it, nearest first (the view's own always come first: their priority is
	# below the prefetch ring's), or the ones baked would be dropped and baked
	# again for ever.
	var cap := maxi(int(cfg.get("max_cached_chunks", 64)), in_view)
	if wanted.size() > cap:
		var nearest := wanted.keys()
		nearest.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return wanted[a] < wanted[b])
		for i in range(cap, nearest.size()):
			wanted.erase(nearest[i])
	var gate := bool(cfg.get("ring_after_view", false))
	var open := [true, not gate or missing[0] == 0, not gate or (missing[0] == 0 and missing[1] == 0)]
	var requested: Dictionary = {}
	for c: Vector2i in wanted:
		if not _chunks.has(c) and open[tier[c]]:
			baker.request(c, wanted[c], true)
			requested[c] = true
	# Content for one ring further out is generated ahead (idle generator lane),
	# once the view is baked.
	baker.warm_paused = not open[2]
	if open[2]:
		for cy in range(maxi(c0.y - reach - 1, m0.y), mini(c1.y + reach + 1, m1.y) + 1):
			for cx in range(maxi(c0.x - reach - 1, m0.x), mini(c1.x + reach + 1, m1.x) + 1):
				var c := Vector2i(cx, cy)
				if not _chunks.has(c):
					baker.warm(c, (Vector2(cx, cy) + Vector2(0.5, 0.5)).distance_to(centre))
	for c: Vector2i in baker.queued():
		if not requested.has(c):
			baker.cancel(c)
	_evict(view, wanted, cap)

# Chunks the prefetch ring reaches beyond the view's edge on one side (side +1:
# past the far edge, -1: past the near one) given the camera's motion along
# that axis: `pre`, plus `ahead` more in the direction it moves, `behind` on the
# side it left.
static func _ring_depth(side: int, motion: float, pre: int, ahead: int, behind: int) -> int:
	if absf(motion) < 0.3:
		return pre
	return pre + ahead if motion * float(side) > 0.0 else behind

# --- the camera's recent motion ----------------------------------------------------------

# Called every frame by _process: the view centre over the last
# prefetch_motion_window_s seconds gives a velocity (map px / s). `now_s` and
# `at` (a view centre, map px) are for tests.
func track_motion(now_s: float = -1.0, at: Variant = null) -> void:
	var now := Time.get_ticks_msec() / 1000.0 if now_s < 0.0 else now_s
	var here: Vector2 = view_rect().get_center() if at == null else at
	_motion.append([now, here])
	var window := float(cfg.get("prefetch_motion_window_s", 1.5))
	while _motion.size() > 2 and now - float(_motion[0][0]) > window:
		_motion.pop_front()
	var dt := now - float(_motion[0][0])
	motion_px_s = (here - (_motion[0][1] as Vector2)) / dt if dt > 0.05 else Vector2.ZERO

# The unit direction the camera has been moving in, or ZERO when it is
# (nearly) still: slower than prefetch_motion_min_chunks_per_s.
func motion_dir() -> Vector2:
	var min_px := float(cfg.get("prefetch_motion_min_chunks_per_s", 0.15)) * float(chunk_px)
	if motion_px_s.length() < min_px or min_px <= 0.0:
		return Vector2.ZERO
	return motion_px_s.normalized()

func _show(c: Vector2i, tex: Texture2D) -> void:
	if tex == null:
		return
	if _chunks.has(c):
		(_chunks[c] as Node).queue_free()
	var s := Sprite2D.new()
	s.name = "Chunk_%d_%d" % [c.x, c.y]
	s.centered = false
	s.position = Vector2(c * chunk_px)
	s.texture = tex
	s.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	map_layer.add_child(s)
	_chunks[c] = s
	chunk_baked.emit(c)

# Drops chunks until at most `cap` are kept. Order of going: those outside the
# keep ring (view grown by keep_chunks), furthest first; then those inside it that
# nothing wants any more, furthest first; the ones `wanted` (the view and what the
# cap leaves for prefetch) last, the least wanted first -- and since wanted holds
# no more than `cap` chunks, those never have to go. (This used to stop at the
# first chunk inside the keep ring, so the cache could grow without limit.)
func _evict(view: Rect2, wanted: Dictionary, cap: int) -> void:
	if _chunks.size() <= cap:
		return
	var keep := int(cfg.get("keep_chunks", 3))
	var centre := view.get_center() / float(chunk_px)
	var reach := view.grow(keep * chunk_px)
	var scored: Array = []   # [keep value, chunk]: the lowest goes first
	for c: Vector2i in _chunks:
		var v: float
		if wanted.has(c):
			v = 2.0e6 - float(wanted[c])
		else:
			var inside := reach.intersects(Rect2(Vector2(c * chunk_px), Vector2(chunk_px, chunk_px)))
			v = (1.0e6 if inside else 0.0) - (Vector2(c) + Vector2(0.5, 0.5)).distance_to(centre)
		scored.append([v, c])
	scored.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for i in _chunks.size() - cap:
		var c: Vector2i = scored[i][1]
		(_chunks[c] as Node).queue_free()
		_chunks.erase(c)

# --- status --------------------------------------------------------------------------------

func chunk_count() -> int:
	return _chunks.size()

func has_chunk(c: Vector2i) -> bool:
	return _chunks.has(c)

# Chunks of the map the current view touches that are not baked yet. With
# `ignore_hidden`, not those wholly under the fog's opaque layer (hidden_test):
# nobody sees them yet, so a loading card need not wait for them.
func missing_in_view(ignore_hidden: bool = false) -> int:
	var view := view_rect()
	var mr := map_rect()
	var r := view.intersection(mr)
	if not r.has_area():
		return 0
	var n := 0
	for cy in range(floori(r.position.y / chunk_px), floori((r.end.y - 0.001) / chunk_px) + 1):
		for cx in range(floori(r.position.x / chunk_px), floori((r.end.x - 0.001) / chunk_px) + 1):
			if _chunks.has(Vector2i(cx, cy)):
				continue
			if ignore_hidden and hidden_test.is_valid() and bool(hidden_test.call(Rect2(Vector2(cx * chunk_px, cy * chunk_px), Vector2(chunk_px, chunk_px)))):
				continue
			n += 1
	return n

func pending() -> int:
	return baker.pending()
