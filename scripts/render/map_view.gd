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
#   look_at_m(p_m: Vector2)                    centre the view on a point (metres): A wires
#                                              Track U's unit_focus_requested to it
#   camera: Camera2D                           the view's camera, a child, in MAP px. Track
#                                              F's camera_controller.gd drives it (or another,
#                                              via use_camera(cam)); MapView reads its bake
#                                              window from whichever camera is current
#   input_enabled: bool                        MapView's own fallback input; F sets false
#   live_layer: Node2D                         above the map, in MAP px (zooms with it): for
#                                              Track F's fog if it suits; U draws in screen
#                                              space on its own CanvasLayers instead
#   px_per_m, set_px_per_m(v)                  the scale; a live knob (1..4 tried): regenerate,
#                                              rebake, camera kept on the same metres
#   m_to_map(p_m) / map_to_m(p_px)             metres <-> map px
#   follow(p_m or null), set_zoom(z), get_zoom(), view_rect(), missing_in_view(), rebake()
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
# asynchronous), visible chunks first, then a ring of prefetch_chunks, and
# terrain generated one more ring ahead; up to max_cached_chunks kept, the
# furthest dropped first. A chunk not baked yet shows plain paper. Content
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
var follow_speed := 6.0      # 1/s: how fast the camera eases to its target

var chunk_px := 1024
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
	_target = null
	if cam != null and cam != camera:
		external_camera = cam
		cam.make_current()

var external_camera: Camera2D = null

# --- camera ------------------------------------------------------------------------------

func set_zoom(z: float) -> void:
	z = clampf(z, zoom_min, zoom_max)
	camera.zoom = Vector2(z, z)

# The zoom the viewport shows the map at (screen px per map px), whichever
# camera is current.
func get_zoom() -> float:
	if is_inside_tree():
		return get_global_transform_with_canvas().get_scale().x
	return camera.zoom.x

# Jumps the camera to a point (metres) -- this view's own camera, or the one
# handed over with use_camera().
func look_at_m(p_m: Vector2) -> void:
	_target = null
	if external_camera != null:
		external_camera.global_position = to_global(m_to_map(p_m))
		return
	var z := camera.zoom.x
	camera.position = (_clamp_to_map(m_to_map(p_m)) * z).round() / z  # whole screen pixels (see _process)

# Eases the camera to a point (metres) over the next frames: the way to
# follow a unit through its turn animation. null stops following.
func follow(p_m: Variant) -> void:
	_target = null if p_m == null else _clamp_to_map(m_to_map(p_m))

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
	# is on (input_enabled) or it is following; otherwise whoever drives it
	# (Track F's camera_controller.gd) owns position, limits and smoothing.
	if input_enabled or _target != null:
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
		_schedule()
		for r: Dictionary in baker.step(int(float(cfg.get("bake_budget_ms", 6.0)) * 1000.0)):
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

# Requests every chunk the view needs, nearest first, and drops queued ones it
# no longer needs.
func _schedule() -> void:
	var view := view_rect()
	var pre := int(cfg.get("prefetch_chunks", 1))
	var c0 := Vector2i(floori(view.position.x / chunk_px), floori(view.position.y / chunk_px))
	var c1 := Vector2i(floori(view.end.x / chunk_px), floori(view.end.y / chunk_px))
	var mr := map_rect()
	var m0 := Vector2i(floori(mr.position.x / chunk_px), floori(mr.position.y / chunk_px))
	var m1 := Vector2i(ceili(mr.end.x / chunk_px) - 1, ceili(mr.end.y / chunk_px) - 1)
	var centre := view.get_center() / float(chunk_px)
	var wanted: Dictionary = {}
	for cy in range(maxi(c0.y - pre, m0.y), mini(c1.y + pre, m1.y) + 1):
		for cx in range(maxi(c0.x - pre, m0.x), mini(c1.x + pre, m1.x) + 1):
			var c := Vector2i(cx, cy)
			var visible := cx >= c0.x and cx <= c1.x and cy >= c0.y and cy <= c1.y
			var d := (Vector2(cx, cy) + Vector2(0.5, 0.5)).distance_to(centre)
			wanted[c] = d + (0.0 if visible else 100.0)
	for c: Vector2i in wanted:
		if not _chunks.has(c):
			baker.request(c, wanted[c])
	# Content for one ring further out is generated ahead (idle generator lane).
	for cy in range(maxi(c0.y - pre - 1, m0.y), mini(c1.y + pre + 1, m1.y) + 1):
		for cx in range(maxi(c0.x - pre - 1, m0.x), mini(c1.x + pre + 1, m1.x) + 1):
			var c := Vector2i(cx, cy)
			if not _chunks.has(c):
				baker.warm(c, (Vector2(cx, cy) + Vector2(0.5, 0.5)).distance_to(centre))
	for c: Vector2i in baker._queue.keys():
		if not wanted.has(c):
			baker.cancel(c)
	_evict(view)

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

func _evict(view: Rect2) -> void:
	var cap := int(cfg.get("max_cached_chunks", 64))
	if _chunks.size() <= cap:
		return
	var keep := int(cfg.get("keep_chunks", 3))
	var centre := view.get_center() / float(chunk_px)
	var order := _chunks.keys()
	order.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return (Vector2(a) + Vector2(0.5, 0.5)).distance_to(centre) > (Vector2(b) + Vector2(0.5, 0.5)).distance_to(centre))
	var reach := view.grow(keep * chunk_px)
	for c: Vector2i in order:
		if _chunks.size() <= cap:
			break
		if reach.intersects(Rect2(Vector2(c * chunk_px), Vector2(chunk_px, chunk_px))):
			break
		(_chunks[c] as Node).queue_free()
		_chunks.erase(c)

# --- status --------------------------------------------------------------------------------

func chunk_count() -> int:
	return _chunks.size()

func has_chunk(c: Vector2i) -> bool:
	return _chunks.has(c)

# Chunks of the map the current view touches that are not baked yet.
func missing_in_view() -> int:
	var view := view_rect()
	var mr := map_rect()
	var r := view.intersection(mr)
	if not r.has_area():
		return 0
	var n := 0
	for cy in range(floori(r.position.y / chunk_px), floori((r.end.y - 0.001) / chunk_px) + 1):
		for cx in range(floori(r.position.x / chunk_px), floori((r.end.x - 0.001) / chunk_px) + 1):
			if not _chunks.has(Vector2i(cx, cy)):
				n += 1
	return n

func pending() -> int:
	return baker.pending()
