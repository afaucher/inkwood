extends RefCounted

# Bakes map chunks into textures, a few steps per frame, so the game never
# waits for a whole bake. Owned by map_view.gd; content and composition come
# from a provider (chunk_provider.gd: chunk_terrain_provider.gd for Track T's
# terrain, chunk_scene_provider.gd for the prototype stand-in).
#
#   var baker := ChunkBaker.new(provider, P, cfg)    # cfg: the map_view section of render_defaults.json
#   baker.request(Vector2i(cx, cy), priority)        # lower priority value = sooner
#   baker.cancel(c)                                   # drops a request that has not started
#   var done: Array = baker.step(budget_usec)         # call every frame; returns finished chunks
#       # -> [{c: Vector2i, texture: ImageTexture (mipmapped), ms: total, ...}]
#   baker.stats                                        # counters and timings for reports
#
# A BAKE IS A SEQUENCE OF STAGES the provider declares (provider.stages():
# [{name, thread: "worker"|"main", fn, final?, parallel?, join?, lane?} or
# {builtin: "sprites"}]). Each stage fn(job) RECORDS InkCanvases -- on a worker
# thread (WorkerThreadPool) or the main thread, as the stage says -- and
# returns either an Array of canvases to render, or {canvases: [...], data:
# {key: value}}, or null (main thread only: not ready, call again next frame).
# A stage READS job.data and job.c / rect / view / size and never writes the
# job: its `data` is merged into job.data by the baker, on the main thread,
# when the stage is done -- so a worker never races the main thread. The baker
# submits the canvases in slices within the frame budget (InkCanvas.begin_submit
# / submit_some: never a forced frame), and once the engine has drawn them
# asks for their pixels asynchronously (InkCanvas.collect_async) into
# job.data[<stage name>] as an Array of ImageTextures; the next stage records
# against those (a shadow mask, a level mask). The stage marked `final`
# returns the chunk canvas; its image, mipmapped, is the chunk. A stage marked
# `parallel` runs on a worker in the background against a SNAPSHOT of
# job.data, and the next stage marked `join` waits for it (its data merged
# first). A stage with a `lane` runs only when no other task of that lane does
# (the terrain generator's, which is serialized behind its own lock). The
# built-in stage "sprites" waits until every object in
# job.data.sprite_objects has a sprite and gives each its `sprite` (a
# Texture2D) and `half`, as the prototype's castShadows and drawSprites expect.
#
# WHAT MAKES IT FAST ENOUGH (measured 2026-10-09; the report has the table):
# recording on at most max_worker_tasks threads (GDScript slows down past ~8),
# canvas groups kept off one-segment strokes (InkCanvas), viewports drawn ONCE
# and read back asynchronously (a synchronous read-back waits for every frame
# in flight), one small canvas per sprite (a group costs a pass over its whole
# target), the noise inlined (fast_noise.gd), a parallel task's slot given back
# as soon as it is done (else eight jobs waiting at their joins deadlock), and
# the provider's content generated a ring ahead of the camera (warm()) whenever
# its lane is idle.
#
# SPRITES OUTLIVE A CHUNK. Each sprite is drawn on its own small canvas
# (sprite_batch of them recorded per worker task), rendered once and kept in a
# cache keyed by the prototype's sprite key (seed + r.toFixed(1)|rings|wob|lw,
# + the pen) up to sprite_cache_max sprites, least recently used dropped
# first. A canopy that reaches into two chunks is built once. (Not atlas
# pages: see _start_pages for why.)
#
# THE TREE POOL (map_view.tree_pool, PROPOSED, a data switch, default off):
# instead of one sprite per tree, `variants` sprites per radius bucket of
# `bucket_px`, drawn by every tree in the bucket (each tree's variant is its
# seed modulo `variants`). No rotation or mirroring: a sprite's lit side,
# shadow-side stipple and shadow-side pen are baked in world orientation, and
# any rotation would turn them away from the sun. It CHANGES THE LOOK (trees
# repeat at that rate); see the report's side-by-side.

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const InkStructs = preload("res://scripts/render/ink_structs.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

var provider: RefCounted
var P: RenderParams
var chunk_px: int
var sprite_batch: int      # sprites recorded per worker task (map_view.sprite_batch)
var max_jobs: int
var max_workers: int        # worker tasks in flight at once (map_view.max_worker_tasks)
var sprite_cache_max: int
var pool_enabled := false
var pool_variants := 16
var pool_bucket_px := 0.5
var stats: Dictionary = {}

var _stages: Array = []
var _queue: Dictionary = {}       # Vector2i -> priority (not started)
var _jobs: Array = []             # started jobs
var _sprites: Dictionary = {}     # key -> [AtlasTexture or Texture2D, half, last_used]
var _pending: Dictionary = {}     # key -> true (on a page being built)
var _pages: Array = []            # pages being recorded / rendered
var _use_clock := 0
var _busy := 0                    # worker tasks launched and not yet collected
var _lanes: Dictionary = {}       # lane name -> tasks running in it (at most one each)
var _warm: Dictionary = {}        # Vector2i -> priority: content to generate ahead (provider.warm_chunk)
var _warmed: Dictionary = {}      # Vector2i -> true: generated or being generated
var _warm_task := -1
var _lane_wanted: Dictionary = {} # lanes a job could not start in this frame
# Extra frames between the frame that draws a submitted canvas and the request
# for its pixels (map_view.collect_delay_frames). The read-back is
# asynchronous (InkCanvas.collect_async), so 0 is right; the knob stays for a
# renderer without one (a synchronous read-back waits for every frame in
# flight: measured 2026-10-09, ~190 ms the next frame, ~25 ms four frames later).
var collect_delay := 0
# Main-thread time one canvas's submission may take per call (see
# InkCanvas.submit_some); set from the frame budget in step().
var _slice_usec := 3000

func _init(p: RefCounted, params: RenderParams, cfg: Dictionary) -> void:
	provider = p
	P = params
	chunk_px = int(cfg.get("chunk_px", 1024))
	sprite_batch = int(cfg.get("sprite_batch", 24))
	max_jobs = int(cfg.get("max_jobs", 3))
	max_workers = int(cfg.get("max_worker_tasks", 8))
	collect_delay = int(cfg.get("collect_delay_frames", 0))
	sprite_cache_max = int(cfg.get("sprite_cache_max", 12000))
	var pool: Dictionary = cfg.get("tree_pool", {})
	pool_enabled = bool(pool.get("enabled", false))
	pool_variants = int(pool.get("variants", 16))
	pool_bucket_px = float(pool.get("bucket_px", 0.5))
	provider.prepare()
	InkCanvas.configure_pen_from(P)
	_stages = provider.stages()
	reset_stats()

func reset_stats() -> void:
	stats = {"chunks": 0, "chunk_ms_total": 0.0, "chunk_ms_max": 0.0, "sprites_built": 0, "pages": 0,
		"page_record_ms": 0.0, "main_ms": 0.0, "main_ms_max_frame": 0.0, "stage_ms": {}, "worker_ms": {}}

# --- requests -----------------------------------------------------------------------

func request(c: Vector2i, priority: float = 0.0) -> void:
	for j: Dictionary in _jobs:
		if j.c == c:
			return  # being baked
	_queue[c] = minf(priority, float(_queue.get(c, priority)))

func cancel(c: Vector2i) -> void:
	_queue.erase(c)

func is_busy(c: Vector2i) -> bool:
	if _queue.has(c):
		return true
	for j: Dictionary in _jobs:
		if j.c == c:
			return true
	return false

func pending() -> int:
	return _queue.size() + _jobs.size()

# Everything dropped: requests, jobs (their canvases freed), sprites. For a
# change of scale or style; the next request starts over.
func clear() -> void:
	_queue.clear()
	for j: Dictionary in _jobs:
		_discard_job(j)
	_jobs.clear()
	for pg: Dictionary in _pages:
		if pg.has("task"):
			_collected(pg.task)
		if pg.state != "arriving":
			for e: Array in pg.entries:
				(e[3] as InkCanvas).discard()
	_pages.clear()
	_sprites.clear()
	_pending.clear()
	if _warm_task >= 0:
		_collected(_warm_task, provider.warm_lane() if provider.has_method("warm_lane") else "")
		_warm_task = -1
	_warm.clear()
	_warmed.clear()
	provider.clear_cache()
	InkCanvas.configure_pen_from(P)
	_stages = provider.stages()

# --- the frame step ----------------------------------------------------------------------

# Advances every job and page, spending at most about `budget_usec` of main
# thread time (at least one action per frame, so a bake always progresses).
# Returns the chunks finished this frame.
func step(budget_usec: int) -> Array:
	var t0 := Time.get_ticks_usec()
	_slice_usec = maxi(1000, budget_usec / 2)
	var done: Array = []
	_lane_wanted.clear()
	_start_jobs()
	_step_pages(t0, budget_usec)
	_note_action("pages", t0)
	for j: Dictionary in _jobs.duplicate():
		if Time.get_ticks_usec() - t0 > budget_usec and _acted:
			break
		var ta := Time.get_ticks_usec()
		var label := "%s:%s" % [j.state, (_stages[j.stage] as Dictionary).get("name", "sprites")]
		var r: Variant = _step_job(j)
		_note_action(label, ta)
		if r != null:
			done.append(r)
			_jobs.erase(j)
	_step_warm()  # after the jobs: a bake waiting for the lane goes first
	var spent := (Time.get_ticks_usec() - t0) / 1000.0
	stats.main_ms += spent
	stats.main_ms_max_frame = maxf(stats.main_ms_max_frame, spent)
	_acted = false
	return done

var _acted := false

func _start_jobs() -> void:
	while _jobs.size() < max_jobs and not _queue.is_empty():
		var best: Vector2i = _queue.keys()[0]
		for k: Vector2i in _queue:
			if _queue[k] < _queue[best]:
				best = k
		_queue.erase(best)
		var origin := Vector2(best * chunk_px)
		var job := {"c": best, "rect": Rect2(origin, Vector2(chunk_px, chunk_px)),
			"view": Transform2D.IDENTITY.translated(-origin), "size": Vector2i(chunk_px, chunk_px),
			"stage": 0, "state": "ready", "data": {}, "bg": {}, "t0": Time.get_ticks_usec()}
		_jobs.append(job)

# A parallel task gives its worker slot back as soon as it is done (its
# result waits in its box for the join): a job must never hold a slot it is
# not using, or eight jobs each waiting at a join for a stage that needs a
# slot deadlock the pool (observed 2026-10-09 with max_jobs 8).
func _release_bg(j: Dictionary) -> void:
	for name: String in j.bg:
		var e: Array = j.bg[name]
		if e[0] >= 0 and WorkerThreadPool.is_task_completed(e[0]):
			_collected(e[0], e[2])
			e[0] = -1

# Returns a result dictionary when the job finished, else null.
func _step_job(j: Dictionary) -> Variant:
	_release_bg(j)
	match j.state:
		"submitting":
			_acted = true
			var cv: Array = j.canvases
			while j.sub_i < cv.size():
				if not (cv[j.sub_i] as InkCanvas).submit_some(_slice_usec):
					return null
				j.sub_i += 1
			j.erase("sub_i")
			j.frame = Engine.get_frames_drawn()
			j.state = "render"
			return null
		"ready":
			var st: Dictionary = _stages[j.stage]
			if st.get("builtin", "") == "sprites":
				_acted = true
				j.sprite_keys = _request_sprites(j.data.get("sprite_objects", []))
				j.state = "sprites"
				return _step_job(j)
			if st.get("join", false):
				_release_bg(j)
				for name: String in j.bg:
					if j.bg[name][0] >= 0:
						return null
				for name: String in j.bg:
					var bbox: Array = j.bg[name][1]
					_add_worker_ms(name, bbox[1])
					_merge_out(j, bbox[0])
				j.bg.clear()
			if st.get("thread", "main") == "worker":
				var fn: Callable = st.fn
				var box := [null, 0.0]   # [result, ms] -- written by the worker only
				var parallel: bool = st.get("parallel", false)
				var view_job := j
				if parallel:
					view_job = j.duplicate()
					view_job.data = (j.data as Dictionary).duplicate()
				var task := _launch(func() -> void:
					var tw := Time.get_ticks_usec()
					box[0] = fn.call(view_job)
					box[1] = (Time.get_ticks_usec() - tw) / 1000.0, str(st.get("lane", "")))
				if task < 0:
					return null  # no free worker: next frame
				if parallel:
					j.bg[st.name] = [task, box, str(st.get("lane", ""))]
					return _advance(j)
				j.task = task
				j.box = box
				j.state = "worker"
				return null
			var tm := Time.get_ticks_usec()
			var out: Variant = (st.fn as Callable).call(j)
			_acted = true
			_add_stage_ms(st.name, (Time.get_ticks_usec() - tm) / 1000.0)
			if out == null:
				return null  # retry next frame
			return _render_or_advance(j, out)
		"worker":
			if not WorkerThreadPool.is_task_completed(j.task):
				return null
			var st: Dictionary = _stages[j.stage]
			_collected(j.task, str(st.get("lane", "")))
			var box: Array = j.box
			j.erase("task")
			j.erase("box")
			_add_worker_ms(st.name, box[1])
			_acted = true
			return _render_or_advance(j, box[0] if box[0] != null else [])
		"sprites":
			for k: String in j.sprite_keys:
				if not _sprites.has(k):
					return null
			var objs: Array = j.data.get("sprite_objects", [])
			for i in objs.size():
				var ref: Array = _sprites[j.sprite_keys[i]]
				ref[2] = _use_clock
				var o: Dictionary = objs[i]
				o["sprite"] = ref[0]
				o["half"] = ref[1]
			return _advance(j)
		"render":
			if Engine.get_frames_drawn() <= j.frame + collect_delay:
				return null
			# Ask for every canvas's pixels without stalling (InkCanvas.collect_async);
			# they arrive a frame or two later.
			var canvases: Array = j.canvases
			j.erase("canvases")
			var arrived: Array = []
			arrived.resize(canvases.size())
			var tq := Time.get_ticks_usec()
			for i in canvases.size():
				(canvases[i] as InkCanvas).collect_async(func(img: Image) -> void: arrived[i] = img)
			_add_stage_ms("readback_request", (Time.get_ticks_usec() - tq) / 1000.0)
			j.arrived = arrived
			j.state = "arriving"
			_acted = true
			return null
		"arriving":
			var arrived: Array = j.arrived
			for img in arrived:
				if img == null:
					return null
			j.erase("arrived")
			var tm := Time.get_ticks_usec()
			var st: Dictionary = _stages[j.stage]
			_acted = true
			if st.get("final", false):
				var img: Image = arrived[0]
				var t_rb := Time.get_ticks_usec()
				img.generate_mipmaps()
				var t_mip := Time.get_ticks_usec()
				_add_stage_ms("final_mipmaps", (t_mip - t_rb) / 1000.0)
				var tex := ImageTexture.create_from_image(img)
				_add_stage_ms("final_upload", (Time.get_ticks_usec() - t_mip) / 1000.0)
				_add_stage_ms("collect_final", (Time.get_ticks_usec() - tm) / 1000.0)
				var ms: float = (Time.get_ticks_usec() - int(j.t0)) / 1000.0
				stats.chunks += 1
				stats.chunk_ms_total += ms
				stats.chunk_ms_max = maxf(stats.chunk_ms_max, ms)
				return {"c": j.c, "texture": tex, "ms": ms}
			var texs: Array[ImageTexture] = []
			for img: Image in arrived:
				texs.append(ImageTexture.create_from_image(img))
			j.data[st.name] = texs
			_add_stage_ms("collect", (Time.get_ticks_usec() - tm) / 1000.0)
			return _advance(j)
	return null

func _render_or_advance(j: Dictionary, out: Variant) -> Variant:
	var canvases: Array = []
	if out is Dictionary:
		_merge_out(j, out)
		canvases = (out as Dictionary).get("canvases", [])
	else:
		canvases = out
	if canvases.is_empty():
		if (_stages[j.stage] as Dictionary).get("final", false):
			push_error("ChunkBaker: the final stage returned no canvas")
		return _advance(j)
	for cv: InkCanvas in canvases:
		cv.begin_submit()
	j.canvases = canvases
	j.sub_i = 0
	j.state = "submitting"
	return _step_job(j)

func _advance(j: Dictionary) -> Variant:
	j.stage += 1
	j.state = "ready"
	if j.stage >= _stages.size():
		push_error("ChunkBaker: stages ran out before a final stage")
		return {"c": j.c, "texture": null, "ms": 0.0}
	return null

# Starts `fn` on a worker if a slot is free (max_workers): returns the task id,
# or -1 to try again next frame. GDScript on more than about eight threads
# gets SLOWER, not faster (measured 2026-10-09 on 32 threads: 256 tree
# sprites 820 ms serial, 131 ms on 8 threads, 475 ms on 16, 840 ms on 31), so
# the baker keeps its own work to a few threads.
# A stage with a `lane` runs only when no other task of that lane does: the
# terrain generator is serialized behind its own lock anyway, and a task
# blocked on that lock would hold a worker slot that sprites could use.
func _launch(fn: Callable, lane: String = "") -> int:
	if _busy >= max_workers or (lane != "" and int(_lanes.get(lane, 0)) > 0):
		if lane != "":
			_lane_wanted[lane] = true
		return -1
	_busy += 1
	if lane != "":
		_lanes[lane] = 1
	return WorkerThreadPool.add_task(fn, true)

func _collected(task: int, lane: String = "") -> void:
	WorkerThreadPool.wait_for_task_completion(task)
	_busy -= 1
	if lane != "":
		_lanes[lane] = 0

# Content to generate before it is needed (the terrain's trees for chunks
# about to come into view): run in the provider's warm lane whenever that
# lane is idle. MapView asks for the ring beyond the chunks it bakes.
func warm(c: Vector2i, priority: float) -> void:
	if not _warmed.has(c):
		_warm[c] = priority

func _step_warm() -> void:
	if not provider.has_method("warm_chunk"):
		return
	var lane: String = provider.warm_lane()
	if _warm_task >= 0:
		if not WorkerThreadPool.is_task_completed(_warm_task):
			return
		_collected(_warm_task, lane)
		_warm_task = -1
	if _warm.is_empty() or _lane_wanted.has(lane) or not _queue.is_empty():
		return  # bakes first: a job is waiting for the lane, or chunks wait to start
	var best: Vector2i = _warm.keys()[0]
	for k: Vector2i in _warm:
		if _warm[k] < _warm[best]:
			best = k
	var prov := provider
	var task := _launch(func() -> void: prov.warm_chunk(best), lane)
	if task >= 0:
		_warm.erase(best)
		_warmed[best] = true
		_warm_task = task

# A stage's {data: {...}} into job.data (main thread).
static func _merge_out(j: Dictionary, out: Variant) -> void:
	if out is Dictionary:
		(j.data as Dictionary).merge((out as Dictionary).get("data", {}), true)

func _add_worker_ms(name: String, ms: float) -> void:
	var ws: Dictionary = stats.worker_ms
	ws[name] = float(ws.get(name, 0.0)) + ms

# The slowest single main-thread action so far, by label (for reports).
func _note_action(label: String, since: int) -> void:
	var ms := (Time.get_ticks_usec() - since) / 1000.0
	if ms > float(stats.get("worst_action_ms", 0.0)):
		stats.worst_action_ms = ms
		stats.worst_action = label

func _add_stage_ms(name: String, ms: float) -> void:
	var sm: Dictionary = stats.stage_ms
	sm[name] = float(sm.get(name, 0.0)) + ms

func _discard_job(j: Dictionary) -> void:
	if j.has("task"):
		_collected(j.task, str((_stages[j.stage] as Dictionary).get("lane", "")))
	for name: String in j.bg:
		if j.bg[name][0] >= 0:
			_collected(j.bg[name][0], j.bg[name][2])
		var bbox: Array = j.bg[name][1]
		if bbox[0] is Dictionary:
			for v in ((bbox[0] as Dictionary).get("data", {}) as Dictionary).values():
				if v is InkCanvas:
					(v as InkCanvas).discard()
	for cv in j.get("canvases", []):
		(cv as InkCanvas).discard()
	var g: Variant = j.data.get("g")
	if g is InkCanvas:
		(g as InkCanvas).discard()

# --- sprites -------------------------------------------------------------------------------

# The cache key of an object's sprite: the prototype's (syncTree / syncProp /
# syncStruct) plus the seed (each object's sprite is its own) and the pen.
func sprite_key(o: Dictionary) -> String:
	var pen := InkCanvas.pen_key()
	match o.kind:
		"tree":
			if pool_enabled:
				var b := _pool_bucket(o)
				return "pool|%d|%d|%d|%s|%s|%s" % [b, _pool_variant(o), P.rings, str(P.wob), str(P.lw), pen]
			return "t%d|%.1f|%d|%s|%s%s" % [o.seed, o.r, P.rings, str(P.wob), str(P.lw), pen]
		"prop":
			return "p%d|%s|%s%s" % [o.seed, o.type, str(P.lw), pen]
		_:
			return "s%d|%s%s" % [o.seed, str(o.get("key", "")), pen]

func _pool_bucket(o: Dictionary) -> int:
	return roundi(float(o.r) / pool_bucket_px)

func _pool_variant(o: Dictionary) -> int:
	return absi(int(o.seed)) % pool_variants

# The tree a pool sprite is drawn from: the bucket's radius and a variant seed
# (the same for every map, so the pool is shared by all of them).
func _pool_tree(o: Dictionary) -> Dictionary:
	var b := _pool_bucket(o)
	var v := _pool_variant(o)
	var t := o.duplicate()
	t.r = float(b) * pool_bucket_px
	t.seed = 0x5EED0000 + b * 977 + v
	return t

# Keys for `objs`, and pages started for any not cached or on the way.
func _request_sprites(objs: Array) -> Array:
	_use_clock += 1
	var keys: Array = []
	var build: Array = []   # [key, object copy]
	for o: Dictionary in objs:
		var k := sprite_key(o)
		keys.append(k)
		if _sprites.has(k):
			(_sprites[k] as Array)[2] = _use_clock
		elif not _pending.has(k):
			_pending[k] = true
			build.append([k, _pool_tree(o) if (pool_enabled and o.kind == "tree") else o.duplicate()])
	if not build.is_empty():
		_start_pages(build)
	return keys

# One canvas per sprite, sized to the sprite, recorded in batches of
# sprite_batch on a worker. NOT shared atlas pages: a canvas group (every
# translucent ink stroke; a tree sprite has ~30) costs a render pass over its
# WHOLE render target, so 60 trees on a 2048 px supersampled page cost ~70x
# what they cost on their own ~240 px targets (measured 2026-10-09: pages
# made 100-200 ms GPU hitches while panning).
func _start_pages(build: Array) -> void:
	var batch: Array = []
	for e: Array in build:
		var o: Dictionary = e[1]
		var size: Vector2i
		var half := 0
		if o.kind == "tree":
			half = InkSprites.tree_half(o)
			size = Vector2i(half * 2, half * 2)
		elif o.kind == "prop":
			half = InkSprites.prop_half(o)
			size = Vector2i(half * 2, half * 2)
		else:
			size = Vector2i(ceili(o.bw), ceili(o.bh))
		batch.append([e[0], o, half, InkCanvas.new(size)])
		if batch.size() >= sprite_batch:
			_start_page(batch)
			batch = []
	if not batch.is_empty():
		_start_page(batch)

func _start_page(entries: Array) -> void:
	var box := [0.0]   # record ms, written by the worker only
	var page := {"entries": entries, "state": "queued", "box": box}
	var Pp := P
	page.fn = (func() -> void:
		var tw := Time.get_ticks_usec()
		for e: Array in entries:
			var o: Dictionary = e[1]
			var canvas: InkCanvas = e[3]
			var half: int = e[2]
			match o.kind:
				"tree":
					InkSprites.draw_tree_sprite(canvas, o, Pp, Vector2(half, half))
				"prop":
					InkSprites.draw_prop_sprite(canvas, o, Pp, Vector2(half, half))
				"wall":
					canvas.set_transform(1, 0, 0, 1, -o.bx, -o.by)
					InkStructs.draw_wall(canvas, o, Pp)
				_:
					canvas.set_transform(1, 0, 0, 1, -o.bx, -o.by)
					InkStructs.draw_house(canvas, o, Pp)
		box[0] = (Time.get_ticks_usec() - tw) / 1000.0)
	_pages.append(page)
	stats.pages += 1
	stats.sprites_built += entries.size()

func _step_pages(t0: int, budget_usec: int) -> void:
	for pg: Dictionary in _pages.duplicate():
		if Time.get_ticks_usec() - t0 > budget_usec and _acted:
			return
		if pg.state == "queued":
			var task := _launch(pg.fn)
			if task >= 0:
				pg.task = task
				pg.erase("fn")
				pg.state = "recording"
		elif pg.state == "recording":
			if not WorkerThreadPool.is_task_completed(pg.task):
				continue
			_collected(pg.task)
			pg.erase("task")
			stats.page_record_ms += float(pg.box[0])
			for e: Array in pg.entries:
				(e[3] as InkCanvas).begin_submit()
			pg.sub_i = 0
			pg.state = "submitting"
			_acted = true
		elif pg.state == "submitting":
			var ts := Time.get_ticks_usec()
			var entries: Array = pg.entries
			while pg.sub_i < entries.size():
				if not (entries[pg.sub_i][3] as InkCanvas).submit_some(_slice_usec):
					break
				pg.sub_i += 1
				if Time.get_ticks_usec() - ts > _slice_usec:
					break
			_note_action("page_submit", ts)
			_add_stage_ms("page_submit", (Time.get_ticks_usec() - ts) / 1000.0)
			_acted = true
			if pg.sub_i >= entries.size():
				pg.frame = Engine.get_frames_drawn()
				pg.state = "render"
		elif pg.state == "render" and Engine.get_frames_drawn() > pg.frame + collect_delay:
			var got: Array = []
			got.resize(pg.entries.size())
			for i in pg.entries.size():
				(pg.entries[i][3] as InkCanvas).collect_async(func(img: Image) -> void: got[i] = img)
			pg.got = got
			pg.state = "arriving"
			_acted = true
		elif pg.state == "arriving":
			if (pg.got as Array).has(null):
				continue
			var tc := Time.get_ticks_usec()
			for i in pg.entries.size():
				var e: Array = pg.entries[i]
				_sprites[e[0]] = [ImageTexture.create_from_image(pg.got[i]), e[2], _use_clock]
				_pending.erase(e[0])
			_note_action("page_collect", tc)
			_add_stage_ms("page_collect", (Time.get_ticks_usec() - tc) / 1000.0)
			_pages.erase(pg)
			_acted = true
	_evict_sprites()

func _evict_sprites() -> void:
	if _sprites.size() <= sprite_cache_max:
		return
	var keys := _sprites.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return _sprites[a][2] < _sprites[b][2])
	for i in keys.size() - sprite_cache_max:
		_sprites.erase(keys[i])

func sprite_count() -> int:
	return _sprites.size()

# What every job and sprite batch is doing, for a report when a bake stalls.
func debug_state() -> String:
	var parts: Array[String] = []
	for j: Dictionary in _jobs:
		var st: Dictionary = _stages[j.stage]
		var missing := 0
		if j.state == "sprites":
			for k: String in j.sprite_keys:
				if not _sprites.has(k):
					missing += 1
		parts.append("job %s stage %d %s/%s%s" % [j.c, j.stage, st.get("name", st.get("builtin", "")), j.state,
			(" (%d sprites missing)" % missing) if j.state == "sprites" else ""])
	var by_state: Dictionary = {}
	for pg: Dictionary in _pages:
		by_state[pg.state] = int(by_state.get(pg.state, 0)) + 1
	parts.append("batches %s; busy %d/%d; lanes %s; queue %d; warm %d (task %d); pending sprites %d" % [
		by_state, _busy, max_workers, _lanes, _queue.size(), _warm.size(), _warm_task, _pending.size()])
	return "
".join(parts)
