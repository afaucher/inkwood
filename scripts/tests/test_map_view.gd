extends "res://scripts/test_support/test_case.gd"

# THE MAP VIEW'S HEADLESS CHECKS (Track V: scripts/render/map_view.gd,
# chunk_baker.gd, chunk_*_provider.gd). Baking itself renders and needs a
# windowed run (scripts/render/map_view_shot.gd); what decides WHAT a chunk
# holds and WHERE things land on screen is checked here:
#
#   1. CHUNK DETERMINISM. A chunk's content is the same whatever was asked
#      for before it -- the border rules included. For both providers, a
#      fresh provider asked for chunk X first, and another asked for X's
#      neighbours (and their neighbours) first, give X the same objects:
#      same kinds, seeds, positions, radii.
#   2. METRES <-> SCREEN. A MapView in the tree, its camera current (baking
#      off: headless draws nothing): world_to_screen and screen_to_world
#      invert each other to 1e-3 m at several zooms and positions; the point
#      the camera looks at is the viewport centre; and after a change of
#      scale (set_px_per_m, the demo knob) the camera still looks at the same
#      metres.
#   3. THE CACHE CAP HOLDS (fix pass 2026-10-09): after a schedule pass the
#      view keeps at most max(max_cached_chunks, the chunks in view) chunks,
#      the view's own all among them, the furthest dropped first -- the keep
#      ring used to stop eviction altogether, so the cache grew with the map.
#   4. A CONTROLLED CAMERA IS LEFT ALONE: once use_camera() has handed the
#      camera over, look_at_m, set_zoom, follow and the easing do nothing.

const RenderParams = preload("res://scripts/world/render_params.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const ChunkSceneProvider = preload("res://scripts/render/chunk_scene_provider.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")

const SEED := 20261009

var _view: Node2D
var _frames := 0
var _phase := 0

func setup(main) -> void:
	timeout_seconds = 180.0
	var P := RenderParams.new()
	if not check(P.ok(), "render params load: %s" % ", ".join(P.errors)):
		finish()
		return
	var cfg := MapView.load_config(P.source_path)
	check(not cfg.is_empty(), "render_defaults.json has a map_view section")
	var t0 := Time.get_ticks_usec()
	_check_scene_determinism(cfg)
	_check_terrain_determinism(cfg)
	print("determinism checks: %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	_view = MapView.new(SEED, Rect2(0, 0, 5000, 5000), 2.0, "scene", RenderParams.new())
	_view.bake_enabled = false
	_view.input_enabled = false
	main.add_child(_view)

func _physics_process(_delta: float) -> void:
	if _view == null or _finished:
		return
	_frames += 1
	if _frames < 3:
		return
	match _phase:
		0:
			_view.set_zoom(1.0)
			_view.look_at_m(Vector2(1234.5, 2345.25))
			_phase = 1
			_frames = 0
		1:
			_check_round_trip("zoom 1")
			_view.set_zoom(0.3)
			_view.look_at_m(Vector2(4000.0, 900.0))
			_phase = 2
			_frames = 0
		2:
			_check_round_trip("zoom 0.3")
			_view.get_window().size = Vector2i(1280, 720)   # (a headless window is tiny; the cache check wants a real view)
			_view.set_px_per_m(4.0)
			_phase = 3
			_frames = 0
		3:
			eq(_view.px_per_m, 4.0, "set_px_per_m changes the scale")
			_check_round_trip("zoom 0.3 at 4 px/m")
			_check_centre(Vector2(4000.0, 900.0), "the camera stays on the same metres across a scale change")
			_check_cache_cap()
			_check_controlled_camera()
			_view.queue_free()
			_view = null
			finish()

# 3. A full cache (every chunk of the 20 x 20 map, as sprites) and a view of a
# few chunks: one schedule pass (which requests, cancels and evicts) leaves the cap.
func _check_cache_cap() -> void:
	_view.look_at_m(Vector2(2500.0, 2500.0))
	_view.set_zoom(0.3)
	var cp: int = _view.chunk_px
	var n := int(ceil(_view.map_rect().size.x / float(cp)))
	var view: Rect2 = _view.view_rect()
	var c0 := Vector2i(floori(view.position.x / cp), floori(view.position.y / cp))
	var c1 := Vector2i(floori(view.end.x / cp), floori(view.end.y / cp))
	var in_view := (c1.x - c0.x + 1) * (c1.y - c0.y + 1)
	check(in_view >= 6 and in_view < 40, "3. the test view shows a few chunks (%d)" % in_view)
	for cap: int in [in_view + 6, 4]:
		_view.cfg["max_cached_chunks"] = cap
		for c in _view._chunks.keys():
			(_view._chunks[c] as Node).free()
		_view._chunks.clear()
		for cy in n:
			for cx in n:
				var s := Sprite2D.new()
				_view.map_layer.add_child(s)
				_view._chunks[Vector2i(cx, cy)] = s
		_view._schedule()
		var want := maxi(cap, in_view)
		eq(_view.chunk_count(), want, "3. cap %d, %d chunks in view: %d chunks kept after a schedule pass (of %d)" % [cap, in_view, want, n * n])
		eq(_view.missing_in_view(), 0, "3. and every chunk the view shows is among them")
		if cap > in_view:
			# The furthest went first: what stays is the view and the nearest ring round it.
			var far := 0
			for c: Vector2i in _view._chunks:
				if c.x < c0.x - 3 or c.x > c1.x + 3 or c.y < c0.y - 3 or c.y > c1.y + 3:
					far += 1
			eq(far, 0, "3. nothing far from the view was kept while nearer chunks went")
	for c in _view._chunks.keys():
		(_view._chunks[c] as Node).free()
	_view._chunks.clear()
	_view._schedule()
	check(_view.baker.pending() > 0, "3. with the cache empty, the schedule asks for chunks again")

# 4.
func _check_controlled_camera() -> void:
	_view.input_enabled = false
	_view.look_at_m(Vector2(2500.0, 2500.0))
	_view.set_zoom(0.5)
	var pos: Vector2 = _view.camera.position
	var zoom: float = _view.camera.zoom.x
	check(not _view.camera_controlled, "4. a view that only has its input off is still MapView's to move (tools and tests drive it)")
	_view.use_camera(_view.camera)
	check(_view.camera_controlled and not _view.input_enabled, "4. use_camera() hands the camera over")
	_view.look_at_m(Vector2(100.0, 100.0))
	_view.set_zoom(1.7)
	_view.follow(Vector2(4000.0, 4000.0))
	_view._target = Vector2(0.0, 0.0)   # a stale easing target must not move it either
	_view._process(0.5)
	near(_view.camera.position.distance_to(pos), 0.0, 0.0, "4. look_at_m, follow and the easing leave the controller's camera where it was")
	near(_view.camera.zoom.x, zoom, 0.0, "4. and set_zoom leaves its zoom")
	_view.camera.position = Vector2(-900.0, -900.0)   # the controller's pan margin reaches past the map
	_view._process(0.5)
	near(_view.camera.position.distance_to(Vector2(-900.0, -900.0)), 0.0, 0.0, "4. nothing clamps it back to the map")

func _check_round_trip(label: String) -> void:
	var worst := 0.0
	for p: Vector2 in [Vector2(0, 0), Vector2(1234.5, 2345.25), Vector2(4999.0, 17.0), Vector2(2500.0, 2500.0), Vector2(-50.0, 6000.0)]:
		var s: Vector2 = _view.world_to_screen(p)
		var back: Vector2 = _view.screen_to_world(s)
		worst = maxf(worst, back.distance_to(p))
	check(worst < 1e-3, "%s: screen_to_world(world_to_screen(p)) == p (worst %s m)" % [label, String.num_scientific(worst)])
	var z: float = _view.get_zoom()
	var a: Vector2 = _view.world_to_screen(Vector2(100.0, 100.0))
	var b: Vector2 = _view.world_to_screen(Vector2(110.0, 100.0))
	near(b.x - a.x, 10.0 * _view.px_per_m * z, 1e-3, "%s: 10 m is px_per_m x zoom x 10 screen px" % label)

func _check_centre(p_m: Vector2, label: String) -> void:
	var vs: Vector2 = _view.get_viewport_rect().size
	var s: Vector2 = _view.world_to_screen(p_m)
	check(s.distance_to(vs * 0.5) < 0.01, "%s (%s vs viewport centre %s)" % [label, s, vs * 0.5])

# --- determinism -------------------------------------------------------------------------

static func _sig(list: Array) -> Array:
	var out: Array = []
	for o: Dictionary in list:
		out.append("%s|%d|%.6f|%.6f|%.6f" % [o.kind, int(o.seed), float(o.x), float(o.y), float(o.get("r", o.get("s", 0.0)))])
	out.sort()
	return out

func _check_scene_determinism(cfg: Dictionary) -> void:
	var X := Vector2i(4, 5)
	var a := ChunkSceneProvider.new(SEED, RenderParams.new(), cfg)
	var first: Dictionary = a.objects(X)
	var b := ChunkSceneProvider.new(SEED, RenderParams.new(), cfg)
	for c: Vector2i in [Vector2i(5, 6), Vector2i(3, 4), Vector2i(4, 4), Vector2i(5, 4), Vector2i(3, 5), Vector2i(4, 6)]:
		b.objects(c)
	var later: Dictionary = b.objects(X)
	for k: String in ["trees", "props", "structs"]:
		check(_sig(first[k]) == _sig(later[k]), "scene provider: chunk %s's %s are the same whatever was generated first (%d vs %d)" % [X, k, first[k].size(), later[k].size()])
	check((first.trees as Array).size() > 0, "scene provider: the test chunk has trees")
	# Neighbours never overlap each other (the border rule): X against its W neighbour.
	var w: Dictionary = b.objects(X + Vector2i(-1, 0))
	var clash := 0
	for o: Dictionary in first.trees:
		for p: Dictionary in w.trees:
			var rr: float = float(o.r) * 0.72 + float(p.r) * 0.72
			if Vector2(o.x, o.y).distance_squared_to(Vector2(p.x, p.y)) < rr * rr:
				clash += 1
	eq(clash, 0, "scene provider: no tree of chunk %s overlaps one of its west neighbour" % X)

func _check_terrain_determinism(cfg: Dictionary) -> void:
	var X := Vector2i(4, 4)
	var a := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, 2.0)
	if not check(a.ok(), "terrain provider loads: %s" % ", ".join(a.errors)):
		return
	var first: Array = a.chunk_content(X).trees
	var b := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, 2.0)
	b.chunk_content(Vector2i(5, 5))
	b.chunk_content(Vector2i(3, 4))
	var later: Array = b.chunk_content(X).trees
	check(first.size() > 0, "terrain provider: the test chunk has trees")
	check(_sig(first) == _sig(later), "terrain provider: chunk %s's trees are the same whatever was generated first (%d vs %d)" % [X, first.size(), later.size()])
