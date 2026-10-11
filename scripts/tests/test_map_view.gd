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
#   7. BACKGROUND BAKING (Track P, 2026-10-10): with a fog (hidden_test) the map is baked by SIGHT, not by
#      camera -- every chunk sight reaches, anywhere on the map, view first; the chunks under the fog follow
#      in the background, a couple at a time, nearest a unit first, and only once everything in sight is
#      baked; and with the whole map baked a pan, a zoom or a change of view requests nothing at all.
#   9. SEVERAL TERRAINS, SEVERAL LANES (Track P): with map_view.terrain_lanes the provider keeps one terrain
#      per band of the map's chunk rows, each a lane of its own; a chunk's trees and structures are the
#      same from any of them as from a single terrain, the bands cover every row and the lanes are named.
#   8. THE SPRITE CACHE EVICTS IN ONE CHEAP PASS (Track P, 2026-10-10): over its cap it used to sort every
#      key with a lambda each frame (100-250 ms of main thread a frame, the frames of 100+ ms while a pan
#      baked chunks); now the oldest quarter of the cap goes at once, the newest stay, and it is fast.
#   6. THE VILLAGE (Track W): the baker tile that holds the radio tower holds the village's houses
#      and walls (and the stages that cast their shadows), no tree of it stands on one, the road
#      or a field, a tile far from the village holds none of it, and a tile's content is the same
#      whatever was generated before it.

const RenderParams = preload("res://scripts/world/render_params.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const ChunkBaker = preload("res://scripts/render/chunk_baker.gd")
const ChunkSceneProvider = preload("res://scripts/render/chunk_scene_provider.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")

const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
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
	_check_lane_equality(cfg)
	_check_terrain_maker(cfg)
	_check_village_content(cfg)
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
			_check_background()
			_check_stale_floor()
			_check_sprite_eviction()
			_check_tree_set()
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
	# d. view chunks under the fog come after the visible ones and before the ring (the view-and-ring rule:
	#    with background baking on, a fog means the fogged schedule of section 7 instead)
	var saved_bg: Variant = _view.cfg.get("background_bake")
	_view.cfg["background_bake"] = {"enabled": false}
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
	_view.cfg["background_bake"] = saved_bg
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

# 7. THE FOGGED SCHEDULE (Track P): what MapView asks the baker for when a fog says which chunks are
# under it. Queue only: nothing is baked here (chunks are faked as baked with an empty Sprite2D).
func _check_background() -> void:
	var cfg_bg: Dictionary = _view.cfg.get("background_bake", {})
	check(bool(cfg_bg.get("enabled", false)), "7. data: map_view.background_bake is on")
	var jobs := int(cfg_bg.get("jobs", 2))
	_view.cfg["max_cached_chunks"] = 1000
	_view.motion_px_s = Vector2.ZERO
	_view.look_at_m(Vector2(1250.0, 1250.0))
	_view.set_zoom(0.3)
	_clear_chunks()
	_view._sched_sig = []
	var cp: float = _view.chunk_px
	var mr: Rect2 = _view.map_rect()
	var nx := int(ceil(mr.size.x / cp))
	var ny := int(ceil(mr.size.y / cp))
	check(nx * ny > 200, "7. the test map has many chunks (%d)" % [nx * ny])
	# the fog: a vision circle near (6, 6) chunks, radius 2.2 chunks; everything else is under it
	var circ := [Vector2(6.0, 6.0) * cp]   # (an array: a lambda captures a local by value, and the circle moves below)
	var circle_r := 2.2 * cp
	var calls := [0]
	_view.hidden_test = func(r: Rect2) -> bool:
		calls[0] += 1
		var at: Vector2 = circ[0]
		var q := Vector2(clampf(at.x, r.position.x, r.end.x), clampf(at.y, r.position.y, r.end.y))
		return q.distance_to(at) > circle_r
	var sig := [1]
	_view.sight_sig = func() -> Variant: return sig[0]
	_view.anchor_points = func() -> PackedVector2Array: return PackedVector2Array([circ[0]])
	var sighted: Array = []
	for cy in ny:
		for cx in nx:
			var c := Vector2i(cx, cy)
			if not bool(_view.hidden_test.call(Rect2(Vector2(c) * cp, Vector2(cp, cp)))):
				sighted.append(c)
	check(sighted.size() > 6 and sighted.size() < 40, "7. the test circle reaches a few chunks (%d)" % sighted.size())
	# a. every chunk sight reaches is requested, and nothing else, wherever the camera is
	_view._schedule()
	var q: Array = _view.baker.queued()
	var want := {}
	for c: Vector2i in sighted:
		want[c] = true
	var same := q.size() == sighted.size()
	for c: Vector2i in q:
		same = same and want.has(c)
	check(same, "7. with nothing baked exactly the chunks sight reaches are requested, view or not (%d of %d)" % [q.size(), sighted.size()])
	eq(_view.missing_sighted(), sighted.size(), "7. missing_sighted() counts them over the whole map")
	var in_view := {}
	for c: Vector2i in _view_chunks():
		in_view[c] = true
	var worst_in := 0.0
	var best_out := INF
	for c: Vector2i in q:
		if in_view.has(c):
			worst_in = maxf(worst_in, _view.baker.priority_of(c))
		else:
			best_out = minf(best_out, _view.baker.priority_of(c))
	check(worst_in < best_out, "7. the sighted chunks in the view rank before the sighted ones the view does not show")
	# b. the background waits until everything in sight is baked, then asks for `jobs` chunks nearest the unit
	var first_rest: Array = sighted.slice(0, sighted.size() - 1)
	_fake_baked(first_rest)
	_view._schedule()
	eq(_view.baker.queued().size(), 1, "7. one chunk in sight missing: only it is requested, the background waits")
	_fake_baked(sighted)
	_view._schedule()
	var bg_q: Array = _view.baker.queued()
	eq(bg_q.size(), jobs, "7. everything in sight baked: %d background chunks are requested, no more" % jobs)
	var near := true
	for c: Vector2i in bg_q:
		near = near and not want.has(c) and (Vector2(c) + Vector2(0.5, 0.5)).distance_to((circ[0] as Vector2) / cp) < 4.5
	check(near, "7. and they are the chunks under the fog nearest the unit")
	check(_view._bg_only, "7. only the background is running: the smaller budget applies")
	# c. a view that moves with the sight unchanged re-requests nothing new and reclassifies nothing
	_clear_chunks()
	_fake_baked(sighted)
	_view._schedule()
	var before: Array = _view.baker.queued().duplicate()
	var calls_before: int = calls[0]
	_view._schedule()
	eq(calls[0], calls_before, "7. a second schedule with the same view and sight classifies nothing again (no hidden_test calls)")
	_view.look_at_m(Vector2(1260.0, 1255.0))   # a little pan, the same chunks in view
	_view._schedule()
	eq(calls[0], calls_before, "7. and a little pan within the same chunks neither")
	_view.look_at_m(Vector2(3800.0, 1300.0))   # a big pan: new chunks in view, same sight
	_view._schedule()
	var after: Array = _view.baker.queued()
	check(after.size() == before.size(), "7. a pan to another part of the map asks for as much and no more (%d, was %d)" % [after.size(), before.size()])
	# d. the whole map baked: nothing is requested wherever the camera goes, at any zoom
	var all: Array = []
	for cy in ny:
		for cx in nx:
			all.append(Vector2i(cx, cy))
	_clear_chunks()
	_view.cfg["max_cached_chunks"] = nx * ny + 10
	_fake_baked(all)
	for at: Vector2 in [Vector2(250.0, 250.0), Vector2(4800.0, 300.0), Vector2(2500.0, 4900.0), Vector2(4700.0, 4700.0)]:
		for z: float in [0.3, 1.0, 0.08]:
			_view.look_at_m(at)
			_view.set_zoom(z)
			_view._schedule()
			eq(_view.baker.queued().size() + _view.baker._jobs.size(), 0, "7. whole map baked: a pan/zoom to %s at %.2f requests no bake" % [at, z])
	eq(_view.missing_sighted(), 0, "7. and missing_sighted() is 0")
	# e. sight moves (a unit flew): the classification is redone and the newly sighted chunk is requested
	_clear_chunks()
	_fake_baked(all)
	var target := Vector2i(14, 6)
	(_view._chunks[target] as Node).free()
	_view._chunks.erase(target)
	_view._schedule()
	var off_bg := float((_view.cfg.get("priority_offsets", {}) as Dictionary).get("background", 100.0))
	check(_view.baker.queued().has(target) and _view.baker.priority_of(target) >= off_bg, "7. a missing chunk under the fog is a background request (priority %.1f >= %.0f)" % [_view.baker.priority_of(target), off_bg])
	circ[0] = Vector2(14.0, 6.0) * cp
	sig[0] = 2
	_view._schedule()
	check(_view.baker.queued().has(target) and _view.baker.priority_of(target) < off_bg, "7. sight moved onto it (sight_sig changed): the schedule is redone and it ranks as sighted (%.1f)" % _view.baker.priority_of(target))
	eq(_view.missing_sighted(), 1, "7. and it is the one chunk missing in sight")
	# f. the cap holds: a map bigger than max_cached_chunks keeps the sighted chunks and the nearest background
	_clear_chunks()
	circ[0] = Vector2(6.0, 6.0) * cp
	sig[0] = 3
	_view.cfg["max_cached_chunks"] = 60
	_fake_baked(all)
	_view._schedule()
	check(_view.chunk_count() <= maxi(60, _view_chunks().size()), "7. the cap holds (%d chunks kept of %d, cap 60)" % [_view.chunk_count(), all.size()])
	var kept_sighted := true
	for c: Vector2i in sighted:
		kept_sighted = kept_sighted and _view.has_chunk(c)
	check(kept_sighted, "7. and every chunk sight reaches is among the kept")
	_view.hidden_test = Callable()
	_view.sight_sig = Callable()
	_view.anchor_points = Callable()
	_clear_chunks()

# 11. THE FLOOR (Track P2, 2026-10-10; Alex: "showing a stale map seems better then a plain brown square", and "we
# have to be throwing out work we can reuse"): a rebake keeps what is on screen until the replacement lands, at a new
# scale too; nothing baked is dropped for the cache cap; the bakes of each chunk are counted.
func _check_stale_floor() -> void:
	var cp: float = _view.chunk_px
	var nx := int(ceil(_view.map_rect().size.x / cp))
	var ny := int(ceil(_view.map_rect().size.y / cp))
	# a. no eviction: the cap is above any map this game draws (400 chunks at 4 px/m), and the whole map stays
	var data_cfg := MapView.load_config(RenderParams.new().source_path)
	check(int(data_cfg.get("max_cached_chunks", 0)) >= 400, "11. data: max_cached_chunks (%s) holds a whole 4 px/m map (400 chunks): nothing baked is dropped for the cap" % data_cfg.get("max_cached_chunks"))
	var all: Array = []
	for cy in ny:
		for cx in nx:
			all.append(Vector2i(cx, cy))
	_clear_chunks()
	_view.cfg["max_cached_chunks"] = 1000
	_fake_baked(all)
	for c: Vector2i in all:
		(_view._chunks[c] as Sprite2D).position = Vector2(c) * cp   # (the fakes have no place of their own)
	_view.hidden_test = Callable()
	_view.look_at_m(Vector2(250.0, 250.0))
	_view._schedule()
	eq(_view.chunk_count(), all.size(), "11. the whole map (%d chunks) stays baked after a schedule at a corner, no eviction" % all.size())
	eq(_view.missing_total(), 0, "11. missing_total() (what the card waits for with load_whole_map) is 0 with the whole map baked")
	check(not _view.load_whole_map(), "11. data: the card waits for the chunks sight reaches by default (background_bake.load_whole_map is off, proposed)")
	# b. a rebake keeps the chunks on screen as stale ones, and they cover the same places
	var serial0: int = _view.chunk_serial
	var probe_rect := Rect2(Vector2(3, 3) * cp, Vector2(cp, cp))
	_view.rebake()
	eq(_view.chunk_count(), 0, "11. rebake(): no fresh chunk")
	eq(_view.stale_count(), all.size(), "11. but every chunk that was on screen is still there, stale")
	check(_view.chunk_serial != serial0, "11. and the layers above are told")
	check(_view.covers_px(probe_rect), "11. a stale chunk covers its place (covers_px)")
	# c. a fresh chunk lands: the stale sprite it replaces goes, the others stay
	var tex := ImageTexture.create_from_image(Image.create(8, 8, false, Image.FORMAT_RGBA8))
	_view._show(Vector2i(3, 3), tex)
	eq(_view.chunk_count(), 1, "11. one fresh chunk")
	eq(_view.stale_count(), all.size() - 1, "11. and exactly the stale sprite of that place went")
	check(_view.covers_px(probe_rect), "11. the place is covered by the fresh chunk")
	check(_view.covers_px(Rect2(Vector2(4, 4) * cp, Vector2(cp, cp))), "11. a neighbour is still covered, by its stale sprite")
	# d. a new scale: the stale sprites are scaled to it and still cover the same places
	var r_before: Rect2 = _view._sprite_rect(_view._stale[0])
	var ppm0: float = _view.px_per_m
	_view.set_px_per_m(ppm0 * 2.0)
	var r_after: Rect2 = _view._sprite_rect(_view._stale[0])
	check(r_after.size.is_equal_approx(r_before.size * 2.0) and r_after.position.is_equal_approx(r_before.position * 2.0), "11. a new scale: the stale sprites are scaled with it (%s -> %s)" % [r_before, r_after])
	check(_view.covers_px(Rect2(Vector2(4, 4) * cp * 2.0, Vector2(cp, cp) * 2.0)), "11. and still cover the place they covered, now in the new pixels")
	# e. the bake counts
	_view.baker.reset_bake_counts()
	_view.baker.bake_counts[Vector2i(1, 1)] = 1
	_view.baker.bake_counts[Vector2i(2, 2)] = 2
	var re: Array = _view.baker.rebaked()
	check(re.size() == 1 and re[0][0] == Vector2i(2, 2) and re[0][1] == 2, "11. rebaked() lists the chunks baked more than once (%s)" % [re])
	_view.baker.reset_bake_counts()
	# f. the background waits for the camera (Track P2, proposed): while it moves and everything in sight is baked
	var bg: Dictionary = _view.cfg.get("background_bake", {})
	check(int(bg.get("yield_to_camera_ms", 0)) > 0, "11. data: background_bake.yield_to_camera_ms is set (%s)" % bg.get("yield_to_camera_ms"))
	_view.bake_boost = false
	_view._bg_only = true
	_view.camera.position += Vector2(40.0, 10.0)
	check(_view._bg_yielding(), "11. the camera moved: the background's main-thread work waits")
	_view._cam_moved_ms = Time.get_ticks_msec() - 100000
	check(not _view._bg_yielding(), "11. the camera has been still for a while: it goes on")
	_view.camera.position += Vector2(40.0, 10.0)
	_view._bg_only = false
	check(not _view._bg_yielding(), "11. a chunk in sight is missing: nothing waits, whatever the camera does")
	_view._bg_only = true
	check(not bool(bg.get("yield_to_playback", false)), "11. data: the background bakes through a turn's playback (yield_to_playback is off, proposed)")
	_view._cam_moved_ms = Time.get_ticks_msec() - 100000
	_view._cam_sig = Vector3(_view.camera.position.x, _view.camera.position.y, _view.camera.zoom.x)
	_view.bake_hold = func() -> bool: return true
	check(not _view._bg_yielding(), "11. a turn is playing back and the switch is off: the background goes on")
	(_view.cfg["background_bake"] as Dictionary)["yield_to_playback"] = true
	check(_view._bg_yielding(), "11. the switch on: a turn is playing back, so the background waits")
	(_view.cfg["background_bake"] as Dictionary)["yield_to_playback"] = false
	_view.bake_hold = Callable()
	_view.bake_boost = true
	check(not _view._bg_yielding(), "11. a loading card is up: nothing waits")
	_view.bake_boost = false
	_view._bg_only = false
	# back to the scale the other checks expect
	_view.set_px_per_m(ppm0)
	_clear_chunks()
	for sp: Sprite2D in _view._stale:
		sp.free()
	_view._stale.clear()

# 12. THE GLOBAL TREE SET (Track P2, 2026-10-10; Alex: "one set of globally unique trees of a large amount and
# sample from that"): the pool is on by default, the set is every (size bucket, variant) the map's trees come in,
# made ahead of the chunks, and each map tree samples from it: the closest size, the variant its seed picks, no
# scaling, no rotation.
func _check_tree_set() -> void:
	var P := RenderParams.new()
	var cfg := MapView.load_config(P.source_path)
	var pool: Dictionary = cfg.get("tree_pool", {})
	check(bool(pool.get("enabled", false)), "12. data: the tree pool is ON by default (Alex's global set)")
	var variants := int(pool.get("variants", 0))
	var bucket_px := float(pool.get("bucket_px", 0.5))
	var rr: Array = pool.get("prebuild_radius_px", [])
	check(rr.size() == 2 and float(rr[0]) < 11.4 and float(rr[1]) > 38.5, "12. data: the set's radii (%s px) cover the map's trees (11.4 to 38.5 px at any scale)" % [rr])
	var baker := ChunkBaker.new(ChunkSceneProvider.new(SEED, P, cfg), P, cfg)
	var objs: Array = baker.pool_objects()
	var buckets := roundi(float(rr[1]) / bucket_px) - roundi(float(rr[0]) / bucket_px) + 1
	eq(objs.size(), buckets * variants, "12. the set is %d buckets x %d variants = %d trees" % [buckets, variants, buckets * variants])
	check(objs.size() >= 1000 and objs.size() <= 2000, "12. and that is 'about 1,000 to 2,000' (%d)" % objs.size())
	var in_set := {}
	for o: Dictionary in objs:
		in_set[baker.sprite_key(o)] = true
	eq(in_set.size(), objs.size(), "12. every tree of the set has a key of its own")
	# sampling: random map trees (radius 11.4 to 38.5 px, any seed) land in the set, near their size
	var rng := Mulberry32.new(5)
	var worst_dr := 0.0
	var all_in := true
	var used := {}
	for i in 3000:
		var t := {"kind": "tree", "r": 11.4 + rng.next() * (38.5 - 11.4), "seed": int(rng.next() * 2147483647.0)}
		var k := baker.sprite_key(t)
		all_in = all_in and in_set.has(k)
		used[k] = true
		var drawn := baker._pool_tree(t)
		worst_dr = maxf(worst_dr, absf(float(drawn.r) - float(t.r)))
		# the variant is the tree's own seed's
		if baker._pool_variant(t) != absi(int(t.seed)) % variants:
			all_in = false
	check(all_in, "12. every one of 3,000 trees samples a tree that is in the set, by its own seed")
	check(worst_dr <= bucket_px * 0.5 + 1e-6, "12. at the closest size: never more than %.2f px off the tree's radius (worst %.3f px)" % [bucket_px * 0.5, worst_dr])
	check(used.size() > objs.size() / 2, "12. and they spread over the set (%d of %d sprites used by 3,000 trees)" % [used.size(), objs.size()])
	# the set is asked for a few pages a frame, first in line
	eq(baker.prebuild_pool(), objs.size(), "12. prebuild_pool() asks for the whole set")
	eq(baker.pool_total(), objs.size(), "12. and counts it")
	for _i in 12:
		baker._step_pool_requests()
	eq(baker.pool_done(), 0, "12. nothing is made without a window to draw in (headless)")
	check(baker._pool_todo.is_empty() and baker._pending.size() == objs.size(), "12. every sprite of it is on its way (%d)" % baker._pending.size())
	check(not baker.pool_ready(), "12. and the set is not ready")
	baker.clear(true)
	eq(baker.pool_total(), 0, "12. clear() drops the request for the set (prebuild again after it)")
	# a sprite made survives a change that does not touch how it looks (the scale), not one that does (the pen)
	baker._sprites["k"] = [null, 3, 0]
	baker.clear(true)
	check(baker._sprites.has("k"), "12. clear(keep_sprites): a sprite made stays (a scale change)")
	baker.clear()
	check(not baker._sprites.has("k"), "12. clear(): all go (a new pen)")
	# unique-per-tree stays as the off setting
	baker.pool_enabled = false
	eq(baker.prebuild_pool(), 0, "12. pool off: there is no set")
	var ta := {"kind": "tree", "r": 17.0, "seed": 1}
	var tb := {"kind": "tree", "r": 17.0, "seed": 2}
	check(baker.sprite_key(ta) != baker.sprite_key(tb), "12. pool off: every tree is its own sprite (unique)")
	baker.pool_enabled = true
	var tc := {"kind": "tree", "r": 17.1, "seed": 1 + variants}
	eq(baker.sprite_key(ta), baker.sprite_key(tc), "12. pool on: two trees of the same size bucket whose seeds agree modulo %d stand on one sprite" % variants)
	check(baker.sprite_key(ta) != baker.sprite_key(tb), "12. pool on: and with other seeds they sample other trees of that size")

# 8. The sprite cache: a baker whose cache is filled past its cap with stamped fake sprites.
func _check_sprite_eviction() -> void:
	var P := RenderParams.new()
	var cfg := MapView.load_config(P.source_path)
	cfg["sprite_cache_max"] = 16000
	var baker := ChunkBaker.new(ChunkSceneProvider.new(SEED, P, cfg), P, cfg)
	var tex := ImageTexture.new()
	for i in 16500:
		baker._sprites["k%d" % i] = [tex, 10, i / 10]   # stamps 0..1649, ten sprites to a stamp
	baker._evict_sprites()   # (once to warm the allocator: the next is the one timed)
	for i in 16500:
		baker._sprites["j%d" % i] = [tex, 10, 2000 + i / 10]
	var t0 := Time.get_ticks_usec()
	baker._evict_sprites()
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var cap: int = baker.sprite_cache_max
	var target := cap - cap / 4
	check(baker.sprite_count() <= target + 10 and baker.sprite_count() >= target - 10, "8. over the cap (%d), the cache drops to three quarters of it (%d; asked for %d)" % [cap, baker.sprite_count(), target])
	check(baker._sprites.has("j16499") and baker._sprites.has("j15500"), "8. the newest sprites stayed")
	check(not baker._sprites.has("j0") and not baker._sprites.has("k0"), "8. the oldest went")
	check(ms < 150.0, "8. and it took %.1f ms (the sort it replaced took 100-250 ms every frame over the cap)" % ms)
	var n: int = baker.sprite_count()
	baker._evict_sprites()
	eq(baker.sprite_count(), n, "8. under the cap nothing is touched")

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


# 9. A provider with K terrains against one with a single terrain.
func _check_lane_equality(cfg: Dictionary) -> void:
	var one_cfg := cfg.duplicate()
	one_cfg["terrain_lanes"] = 1
	var many_cfg := cfg.duplicate()
	many_cfg["terrain_lanes"] = 8
	var one := ChunkTerrainProvider.new(SEED, RenderParams.new(), one_cfg, 2.0)
	var many := ChunkTerrainProvider.new(SEED, RenderParams.new(), many_cfg, 2.0)
	if not check(one.ok() and many.ok(), "9. both providers load"):
		return
	eq(one.lanes, 1, "9. one terrain")
	eq(many.lanes, 8, "9. and eight")
	var bands := {}
	var rows := many._rows
	for cy in rows:
		bands[many.bundle_index(Vector2i(3, many._rows0 + cy))] = true
	eq(bands.size(), 8, "9. the map's %d chunk rows are dealt to all eight terrains" % rows)
	var lanes := {}
	for cy in rows:
		lanes[many.lane_for(Vector2i(3, many._rows0 + cy), "terrain")] = true
	eq(lanes.size(), 8, "9. each terrain is a lane of its own")
	eq(one.lane_for(Vector2i(3, 3), "terrain"), "terrain", "9. a single terrain keeps the lane's old name")
	eq(many.lane_for(Vector2i(3, 3), "other"), "other", "9. and only the terrain lane is split")
	var same := true
	var checked := 0
	for c: Vector2i in [Vector2i(4, 4), Vector2i(8, 1), Vector2i(2, 8), Vector2i(6, 9), Vector2i(4, 0), Vector2i(1, 5)]:
		var a: Dictionary = one.chunk_content(c)
		var b: Dictionary = many.chunk_content(c)
		var ok_here: bool = _sig(a.trees) == _sig(b.trees) and (a.structs as Array).size() == (b.structs as Array).size()
		same = same and ok_here
		checked += 1
		if not ok_here:
			fail("9. chunk %s differs between one terrain and eight (%d vs %d trees)" % [c, (a.trees as Array).size(), (b.trees as Array).size()])
	check(same, "9. %d chunks across the bands hold the same trees and structures from one terrain as from eight" % checked)

# 10. A terrain maker (Track P2, 2026-10-10, proposed): how a layer that changes the ground a terrain stands on
# (the water's capped height field) makes every bundle's terrain. Water is not wired in; this is the seam.
func _check_terrain_maker(cfg: Dictionary) -> void:
	var many_cfg := cfg.duplicate()
	many_cfg["terrain_lanes"] = 3
	var prov := ChunkTerrainProvider.new(SEED, RenderParams.new(), many_cfg, 2.0)
	var made := [0]
	prov.set_terrain_maker(func(seed_v: int, path: String, params: RenderParams) -> RefCounted:
		made[0] += 1
		var t: RefCounted = (load("res://scripts/world/terrain.gd") as GDScript).new(seed_v, path, params)
		t.set_meta("made_by_maker", true)
		return t)
	check(prov.ok(), "10. a provider with a terrain maker loads")
	eq(made[0], 3, "10. every bundle's terrain came from the maker (3 lanes)")
	check(prov.terrain.has_meta("made_by_maker"), "10. and bundle 0's is one of them")
	eq(prov.terrain.px_per_m, 2.0, "10. at the scale the provider was asked for")
	prov.set_px_per_m(3.0)
	prov.set_terrain_maker(prov.terrain_maker)
	eq(prov.terrain.px_per_m, 3.0, "10. a maker set after a scale change keeps that scale")
	var plain := ChunkTerrainProvider.new(SEED, RenderParams.new(), many_cfg, 3.0)
	check(_sig(plain.chunk_content(Vector2i(4, 4)).trees) == _sig(prov.chunk_content(Vector2i(4, 4)).trees), "10. a maker that builds the plain terrain changes nothing about a chunk's trees")

# 6. The village in the terrain provider's chunk content, and the stages that bake it.
func _check_village_content(cfg: Dictionary) -> void:
	var a := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, 2.0)
	if not check(a.ok(), "terrain provider loads for the village check: %s" % ", ".join(a.errors)):
		return
	var names: Array = []
	for st: Dictionary in a.stages():
		names.append(st.get("name", st.get("builtin", "")))
	var i_terrain: int = names.find("terrain_merge")
	var i_struct: int = names.find("struct_sil")
	check(i_terrain >= 0 and i_struct > i_terrain and names.find("struct_cut") == i_struct + 1 and names.find("struct_merge") == i_struct + 2 and names.find("tree_sil") == i_struct + 3,
		"6. the stages cast the village's shadows after the terrain's and before the trees' (%s)" % [names])
	var vil: Variant = a.village()
	if not check(vil != null, "6. the provider has a village"):
		return
	var site: Vector2 = a.terrain.layout().sites().radio_tower * a.px_per_m()
	var cp := float(a.chunk_px)
	var c := Vector2i(floori(site.x / cp), floori(site.y / cp))
	var first: Dictionary = a.chunk_content(c)
	var houses := 0
	var walls := 0
	for s: Dictionary in first.structs:
		if s.kind == "house":
			houses += 1
		else:
			walls += 1
	check(houses >= 1 and walls >= 1, "6. the tile %s that holds the radio tower holds houses (%d) and walls (%d)" % [c, houses, walls])
	var on := 0
	for t: Dictionary in first.trees:
		for s: Dictionary in first.structs:
			if vil._struct_dist(s, t.x, t.y) < 0.0:
				on += 1
		if vil.blocks_tree(t.x, t.y, float(t.r) * a.P.tree_collision_radius) and not t.get("hedge", false):
			on += 1
	eq(on, 0, "6. no tree of the tile stands on a house or a wall, on the road, or in a field (%d trees)" % (first.trees as Array).size())
	# a tile far from everything: none of it
	var far := Vector2i(0, 0)
	var rect := Rect2(Vector2(far) * cp, Vector2(cp, cp)).grow(a.ts.reach_px())
	eq((vil.structs_in_rect(rect) as Array).size(), 0, "6. a tile in the map's corner holds none of the village's structures")
	eq((vil.fields_in_rect(rect) as Array).size(), 0, "6. nor its fields")
	check((vil.road_runs_in_rect(rect, 40.0) as Array).is_empty(), "6. nor its road")
	# the same whatever was generated first
	var b := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, 2.0)
	for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1)]:
		b.chunk_content(c + d)
	var later: Dictionary = b.chunk_content(c)
	check(_sig(first.trees) == _sig(later.trees), "6. the village tile's trees are the same whatever was generated first (%d)" % (first.trees as Array).size())
	var sig_structs := func(list: Array) -> Array:
		var out: Array = []
		for s: Dictionary in list:
			out.append("%s|%d|%d|%d" % [s.kind, int(s.seed), int(s.bx), int(s.by)])
		out.sort()
		return out
	check(sig_structs.call(first.structs) == sig_structs.call(later.structs), "6. and so are its structures (%d)" % (first.structs as Array).size())
	print("[map_view] village tile %s: %d houses, %d walls and %d trees in its content; %d stages (%s)" % [
		c, houses, walls, (first.trees as Array).size(), names.size(), ", ".join(names.slice(i_terrain, i_struct + 4))])
