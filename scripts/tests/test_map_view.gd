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
#   5. THE QUEUE ORDER (map-performance track, 2026-10-10): the view's chunks are
#      requested first, nearest the centre first, and the prefetch ring only once
#      the view is baked; view chunks under the fog (hidden_test) come after the
#      visible ones and before the ring; the ring leans along the camera's motion
#      (further ahead, nothing behind). In the baker: jobs start nearest first, a
#      sprite page for a farther chunk is pulled forward when a nearer chunk needs
#      a sprite on it, and the per-frame cap on submitting pages holds.

const RenderParams = preload("res://scripts/world/render_params.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const ChunkBaker = preload("res://scripts/render/chunk_baker.gd")
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
			_check_queue_order()
			_check_baker_order()
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

# 5. The order in which MapView asks the baker for chunks (queue only: nothing is baked here).
func _clear_chunks() -> void:
	for c in _view._chunks.keys():
		(_view._chunks[c] as Node).free()
	_view._chunks.clear()
	for c: Vector2i in _view.baker.queued():
		_view.baker.cancel(c)

func _fake_baked(list: Array) -> void:
	for c: Vector2i in list:
		if not _view._chunks.has(c):
			var s := Sprite2D.new()
			_view.map_layer.add_child(s)
			_view._chunks[c] = s

func _view_chunks() -> Array:
	var cp: int = _view.chunk_px
	var view: Rect2 = _view.view_rect().intersection(_view.map_rect())
	var out: Array = []
	for cy in range(floori(view.position.y / cp), floori(view.end.y / cp) + 1):
		for cx in range(floori(view.position.x / cp), floori(view.end.x / cp) + 1):
			out.append(Vector2i(cx, cy))
	return out

func _check_queue_order() -> void:
	_view.look_at_m(Vector2(2500.0, 2500.0))
	_view.set_zoom(0.3)
	_view.cfg["max_cached_chunks"] = 200
	_view.cfg["ring_after_view"] = true
	_view.motion_px_s = Vector2.ZERO
	_view.hidden_test = Callable()
	_clear_chunks()
	var cp: float = _view.chunk_px
	var view_list := _view_chunks()
	var in_view := {}
	for c: Vector2i in view_list:
		in_view[c] = true
	var centre: Vector2 = _view.view_rect().get_center() / cp
	# a. the view first, nearest the centre first; no ring while a view chunk is missing
	_view._schedule()
	var queued: Array = _view.baker.queued()
	eq(queued.size(), view_list.size(), "5. with nothing baked, exactly the view's chunks are requested (no ring): %d of %d" % [queued.size(), view_list.size()])
	var all_view := true
	for c: Vector2i in queued:
		all_view = all_view and in_view.has(c)
	check(all_view, "5. and every one of them is in the view")
	queued.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return _view.baker.priority_of(a) < _view.baker.priority_of(b))
	var last_d := -1.0
	var near_first := true
	for c: Vector2i in queued:
		var d := (Vector2(c) + Vector2(0.5, 0.5)).distance_to(centre)
		near_first = near_first and d >= last_d - 1e-6
		last_d = d
	check(near_first, "5. in priority order the view's chunks run from the centre outwards")
	# b. with one view chunk still missing the ring stays out; once the view is baked it is requested after it
	var spare: Vector2i = queued[queued.size() - 1]
	var rest: Array = view_list.duplicate()
	rest.erase(spare)
	_fake_baked(rest)
	_view._schedule()
	var q2: Array = _view.baker.queued()
	eq(q2.size(), 1, "5. one view chunk missing: only it is requested, the ring waits")
	var worst_view: float = _view.baker.priority_of(spare)
	_fake_baked([spare])
	_view._schedule()
	var ring: Array = _view.baker.queued()
	check(ring.size() > 0, "5. the view baked: the ring is requested (%d chunks)" % ring.size())
	var ring_after := true
	for c: Vector2i in ring:
		ring_after = ring_after and not in_view.has(c) and _view.baker.priority_of(c) > worst_view
	check(ring_after, "5. every ring chunk is outside the view and ranks after the view's")
	var pre := int(_view.cfg.get("prefetch_chunks", 1))
	var c0 := Vector2i(view_list[0])
	var c1 := Vector2i(view_list[view_list.size() - 1])
	var still_prio: Dictionary = {}
	for c: Vector2i in ring:
		still_prio[c] = _view.baker.priority_of(c)
		check(c.x >= c0.x - pre and c.x <= c1.x + pre and c.y >= c0.y - pre and c.y <= c1.y + pre, "5. a still camera's ring is %d chunk(s) round the view (%s)" % [pre, c])
	# c. the ring leans along the camera's motion: further ahead, nothing behind
	var ahead := int(_view.cfg.get("prefetch_ahead_extra_chunks", 0))
	var behind := int(_view.cfg.get("prefetch_behind_chunks", pre))
	_clear_chunks()
	_fake_baked(view_list)
	_view.motion_px_s = Vector2(2.0 * cp, 0.0)   # east, 2 chunks a second
	_view._schedule()
	var moving: Array = _view.baker.queued()
	var has_far_east := false
	var has_west := false
	var mid_row := (c0.y + c1.y) / 2
	for c: Vector2i in moving:
		if c.x == c1.x + pre + ahead and c.y == mid_row:
			has_far_east = true
		if c.x < c0.x - behind and behind < pre:
			has_west = true
	if ahead > 0:
		check(has_far_east, "5. moving east the ring reaches %d chunk(s) further ahead" % ahead)
	if behind < pre:
		check(not has_west, "5. and none is requested behind the motion (prefetch_behind_chunks %d)" % behind)
	var lean_ok := true
	var leaned := 0
	for c: Vector2i in moving:
		if still_prio.has(c) and c.x > c1.x:
			leaned += 1
			lean_ok = lean_ok and _view.baker.priority_of(c) < float(still_prio[c])
	check(leaned == 0 or lean_ok, "5. a ring chunk ahead of the motion ranks nearer than when the camera is still")
	# track_motion: the view centre's displacement over the window
	_view.motion_px_s = Vector2.ZERO
	_view._motion.clear()
	var home: Vector2 = _view.view_rect().get_center()
	_view.track_motion(100.0, home)
	_view.track_motion(101.0, home + Vector2(cp, 0.0))
	check(_view.motion_px_s.distance_to(Vector2(cp, 0.0)) < 1.0, "5. a camera that moved a chunk east in a second is moving east at a chunk a second (%s)" % _view.motion_px_s)
	check(_view.motion_dir().distance_to(Vector2.RIGHT) < 1e-4, "5. and motion_dir() is east")
	_view.track_motion(110.0, home + Vector2(cp, 0.0))
	check(_view.motion_dir() == Vector2.ZERO, "5. a camera that has stopped for longer than the window is still")
	_view._motion.clear()
	_view.motion_px_s = Vector2.ZERO
	# d. view chunks under the fog come after the visible ones and before the ring
	_clear_chunks()
	var hidden_x := c1.x
	_view.hidden_test = func(r: Rect2) -> bool: return int(r.position.x / cp) >= hidden_x
	_view._schedule()
	var vis: Array = []
	var fogged: Array = []
	for c: Vector2i in view_list:
		(fogged if c.x >= hidden_x else vis).append(c)
	eq(_view.missing_in_view(), view_list.size(), "5. missing_in_view() counts every unbaked chunk of the view")
	eq(_view.missing_in_view(true), vis.size(), "5. and with ignore_hidden not the ones under the fog (a loading card need not wait for them)")
	var q3: Array = _view.baker.queued()
	eq(q3.size(), vis.size(), "5. the visible view chunks are requested first (%d), the ones under the fog wait" % vis.size())
	var worst_vis := worst_view_of(vis)   # before they are baked: a baked chunk has no request
	_fake_baked(vis)
	_view._schedule()
	var q4: Array = _view.baker.queued()
	eq(q4.size(), fogged.size(), "5. then the view chunks under the fog (%d), still before the ring" % fogged.size())
	var min_fogged := INF
	for c: Vector2i in q4:
		min_fogged = minf(min_fogged, _view.baker.priority_of(c))
	check(min_fogged > worst_vis, "5. a fogged view chunk ranks after every visible one (%.1f vs %.1f)" % [min_fogged, worst_vis])
	_fake_baked(fogged)
	_view._schedule()
	check(_view.baker.queued().size() > 0, "5. everything in view baked: the ring comes")
	_view.hidden_test = Callable()
	# e. the knob that turns the gate off: view and ring are requested together, view still first
	_view.cfg["ring_after_view"] = false
	_clear_chunks()
	_view._schedule()
	var together: Array = _view.baker.queued()
	check(together.size() > view_list.size(), "5. ring_after_view false: the ring is requested with the view (%d chunks)" % together.size())
	var vmax := 0.0
	var rmin := INF
	for c: Vector2i in together:
		if in_view.has(c):
			vmax = maxf(vmax, _view.baker.priority_of(c))
		else:
			rmin = minf(rmin, _view.baker.priority_of(c))
	check(vmax < rmin, "5. and the view's chunks still rank before the ring's")
	_view.cfg["ring_after_view"] = true
	_clear_chunks()

func worst_view_of(list: Array) -> float:
	var w := 0.0
	for c: Vector2i in list:
		w = maxf(w, _view.baker.priority_of(c))
	return w

# 5. The baker's own order, without rendering anything: jobs start nearest first,
# a sprite page is pulled forward by a nearer chunk, the page cap holds.
func _check_baker_order() -> void:
	var P := RenderParams.new()
	var cfg := MapView.load_config(P.source_path)
	cfg["max_jobs"] = 2
	cfg["sprite_pages_per_frame"] = 2
	var prov := ChunkSceneProvider.new(SEED, P, cfg)
	var baker := ChunkBaker.new(prov, P, cfg)
	baker.request(Vector2i(1, 1), 5.0)
	baker.request(Vector2i(2, 2), 1.0)
	baker.request(Vector2i(3, 3), 3.0)
	baker.request(Vector2i(3, 3), 9.0)   # an existing request keeps the better priority
	eq(baker.priority_of(Vector2i(3, 3)), 3.0, "5. a repeated request keeps the better priority")
	baker.request(Vector2i(1, 1), 7.0, true)   # replace: the camera moved, the chunk is now farther
	eq(baker.priority_of(Vector2i(1, 1)), 7.0, "5. a request with replace sets the priority (up or down)")
	baker._start_jobs()
	eq(baker._jobs.size(), 2, "5. the baker starts max_jobs jobs")
	var started: Array = baker._jobs.map(func(j: Dictionary) -> Vector2i: return j.c)
	check(started.has(Vector2i(2, 2)) and started.has(Vector2i(3, 3)), "5. and they are the two nearest (%s)" % [started])
	baker.request(Vector2i(3, 3), 0.5, true)
	eq(baker.priority_of(Vector2i(3, 3)), 0.5, "5. a running job's priority follows the camera too")
	# sprites: a page requested for a far chunk is pulled forward by a nearer one
	var objs: Array = prov.objects(Vector2i(4, 5)).trees
	check(objs.size() >= 4, "5. the test chunk has trees (%d)" % objs.size())
	var first: Array = objs.slice(0, 2)
	var second: Array = objs.slice(1, 4)   # overlaps the first on one tree
	baker._request_sprites(first, 10.0)
	eq(baker._pages.size(), 1, "5. a request for new sprites starts a page")
	eq(float(baker._pages[0].prio), 10.0, "5. with its requester's priority")
	baker._request_sprites(second, 4.0)
	eq(baker._pages.size(), 2, "5. the sprites it did not have get a page of their own")
	eq(float(baker._pages[0].prio), 4.0, "5. the first page, which holds a sprite the nearer chunk needs, is pulled forward to its priority")
	eq(float(baker._pages[1].prio), 4.0, "5. and the new page has it")
	baker._request_sprites(first, 20.0)
	eq(float(baker._pages[0].prio), 4.0, "5. a farther chunk asking for the same sprites does not push the page back")
	# the cap on submitting pages
	baker.pages_per_frame = 2
	baker._pages_touched.clear()
	var p1: Dictionary = {"id": 1}
	var p2: Dictionary = {"id": 2}
	var p3: Dictionary = {"id": 3}
	check(baker._page_may_submit(p1) and baker._page_may_submit(p2), "5. two pages may submit in a frame (sprite_pages_per_frame 2)")
	check(not baker._page_may_submit(p3), "5. a third is held back")
	check(baker._page_may_submit(p1), "5. a page already submitting this frame goes on")
	baker._pages_touched.clear()
	check(baker._page_may_submit(p3), "5. the next frame it may")
	baker.pages_per_frame = 0
	baker._pages_touched.clear()
	check(baker._page_may_submit(p1) and baker._page_may_submit(p2) and baker._page_may_submit(p3), "5. cap 0: no limit")
	baker.clear()

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
