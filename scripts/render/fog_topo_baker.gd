extends RefCounted

# THE FOG'S TOPOGRAPHIC PREBAKE (Track P, map and fog performance, 2026-10-10). Alex: "The fog layer
# should also be static and can be done completely ahead of time" (decision map-layers) -- the
# contour map depends on the terrain alone, so every chunk of the WHOLE MAP at EVERY level of detail
# is made once, behind the loading card, and kept. After that a pan or a zoom only composites
# textures that already exist. (Before this the layer baked what the view needed, one recording at a
# time, as the player panned: the view showed the plain sheet, then a coarser level's blurry
# colours, then the contour lines, and the hang was the bakes.)
#
#   var baker := FogTopoBaker.new(topo, twins, max_inflight, starts_per_frame, budget_ms, boost_ms, threaded)
#   baker.enqueue(keys)           # Vector3i(chunk x, chunk y, level of detail), in the order to make them
#   baker.step()                  # every frame, main thread: starts recordings, advances the pipeline
#   baker.on_done = func(key: Vector3i, tex: Texture2D) -> void: ...
#   baker.remaining()             # queued + in flight; 0 when everything asked for is made
#   baker.shutdown()              # waits for the workers (a quit with a task running GDScript crashes)
#
# THE PIPELINE of one chunk at one level of detail (the work of a bake, where it runs):
#   recording   a WORKER thread: FogTopo.make_canvas on one of `twins` -- each twin is a private
#               Terrain (same seed and data, so the same geometry bit for bit; fog_topo.gd), used by one
#               task at a time, so there is no lock and K recordings run side by side. A twin keeps its
#               terrain chunks, so the chunks are dealt to twins in BANDS OF ROWS (a twin sees its own
#               rows, plus one row of margin the contours reach across) and each chunk's geometry is
#               made about once, not once per twin.
#   submitting  main thread, a slice of the frame budget: the recorded canvas becomes canvas items
#   render      the engine draws it with the next frame
#   arriving    the pixels are read back asynchronously (InkCanvas.collect_async: no stall)
#   mipmaps     a WORKER thread: Image.generate_mipmaps (the layer minifies a level up to 1/lod_ratio)
#   texture     main thread: ImageTexture.create_from_image, handed to `on_done`
# The main thread's share per chunk is the submission, the read-back request and the texture.
#
# At most `max_inflight` chunks are past the queue at once (each holds a supersampled render target
# until its pixels are read), `starts_per_frame` recordings begin per frame, and the main thread spends
# at most `budget_ms` a frame (`boost_ms` while `boost` is set: a loading card is up and nobody plays).
# `threaded` false records on the main thread instead (for a comparison; the rest is the same).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const FogTopo = preload("res://scripts/render/fog_topo.gd")

var topo: RefCounted                   # the layer's own FogTopo (chunk rectangles, levels of detail)
var twins: Array = []                  # FogTopo, one private Terrain each
var max_inflight := 12
var starts_per_frame := 4
var budget_ms := 3.0
var boost_ms := 12.0
var boost := false
var threaded := true
var on_done: Callable = Callable()     # (key: Vector3i, tex: Texture2D)
# Counters for reports. record_ms: the recordings' time (worker threads), main_ms: the main thread's
# time in step(), main_ms_max_frame: its worst frame, finished: chunks that left the pipeline.
var stats := {"started": 0, "finished": 0, "record_ms": 0.0, "record_ms_max": 0.0, "record_ms_sum": 0.0,
	"main_ms": 0.0, "main_ms_max_frame": 0.0}

var _twin_count := 0                   # how many twins to (re)make after release_twins()
var _queues: Array = []                # per twin: Array of keys, next first
var _heads: PackedInt32Array = PackedInt32Array()
var _busy: Array[bool] = []            # twin i has a recording running
var _jobs: Array = []                  # past the queue: {key, twin, state, ...}
var _rows0 := 0                        # first chunk row of the map, and how many rows there are
var _rows := 1
var _queued := 0
var _total := 0

func _init(t: RefCounted, twin_list: Array, inflight: int, per_frame: int, budget: float, boost_budget: float, use_threads: bool) -> void:
	topo = t
	twins = twin_list
	max_inflight = maxi(1, inflight)
	starts_per_frame = maxi(1, per_frame)
	budget_ms = budget
	boost_ms = boost_budget
	threaded = use_threads
	_twin_count = twin_list.size()
	var r: Rect2i = t.terrain.map_chunk_range()
	_rows0 = r.position.y
	_rows = maxi(1, r.size.y)
	for _i in twins.size():
		_queues.append([])
		_busy.append(false)
	_heads.resize(twins.size())

# The twin that makes chunk row `cy`: contiguous bands of rows.
func twin_of(cy: int) -> int:
	return clampi((cy - _rows0) * _twin_count / _rows, 0, _twin_count - 1)

# Gives the twins' terrains back once everything is made (each holds the geometry of its band of the map);
# enqueue() makes them again if more work comes. Only with nothing queued or in flight.
func release_twins() -> void:
	if remaining() > 0 or twins.is_empty():
		return
	twins = []

# Adds keys (Vector3i(cx, cy, lod)) to the work, in this order within each twin's band.
func enqueue(keys: Array) -> void:
	if twins.is_empty() and _twin_count > 0:
		for _i in _twin_count:
			twins.append(topo.make_twin())
	for key: Vector3i in keys:
		(_queues[twin_of(key.y)] as Array).append(key)
		_queued += 1
		_total += 1

# Chunks not yet made: waiting in a queue or in the pipeline.
func remaining() -> int:
	return _queued + _jobs.size()

# Everything ever enqueued, and how many of it has left the pipeline.
func total() -> int:
	return _total

func finished() -> int:
	return int(stats.finished)

func in_flight() -> int:
	return _jobs.size()

func is_queued_or_running(key: Vector3i) -> bool:
	for j: Dictionary in _jobs:
		if j.key == key:
			return true
	var q: Array = _queues[twin_of(key.y)]
	return q.find(key, _heads[twin_of(key.y)]) >= 0

func recordings() -> int:
	var n := 0
	for j: Dictionary in _jobs:
		if j.state == "recording":
			n += 1
	return n

func job_states() -> Array:
	var out: Array = []
	for j: Dictionary in _jobs:
		out.append(j.state)
	return out

# Drops everything: the queue, and the bakes in flight (their canvases are freed, the workers waited for).
func clear() -> void:
	shutdown()
	for q: Array in _queues:
		q.clear()
	_heads.fill(0)
	_queued = 0
	_total = 0
	stats.finished = 0
	stats.started = 0

# Waits for the worker tasks and drops every bake in flight. A quit with a task still running GDScript
# crashes the engine. A bake whose pixels are already on their way keeps its canvas (the read-back frees it).
func shutdown() -> void:
	for job: Dictionary in _jobs:
		if job.has("task"):
			WorkerThreadPool.wait_for_task_completion(job.task)
		if job.has("mip_task"):
			WorkerThreadPool.wait_for_task_completion(job.mip_task)
		if job.has("box"):
			if job.box[0] is InkCanvas:
				(job.box[0] as InkCanvas).discard()
		elif job.has("canvas") and job.state != "arriving":
			(job.canvas as InkCanvas).discard()
	_jobs.clear()
	for i in _busy.size():
		_busy[i] = false

# --- the frame ---------------------------------------------------------------------------

func step() -> void:
	if _jobs.is_empty() and _queued == 0:
		return
	var t0 := Time.get_ticks_usec()
	var budget := int((boost_ms if boost else budget_ms) * 1000.0)
	var slice := maxi(500, budget / 2)
	var acted := false
	for job: Dictionary in _jobs.duplicate():
		if acted and Time.get_ticks_usec() - t0 > budget:
			break
		match job.state:
			"recording":
				if job.has("task"):
					if not WorkerThreadPool.is_task_completed(job.task):
						continue
					WorkerThreadPool.wait_for_task_completion(job.task)
					job.erase("task")
				_busy[job.twin] = false
				var box: Array = job.box
				job.erase("box")
				job["canvas"] = box[0]
				_note_record(box[1])
				(job.canvas as InkCanvas).begin_submit()
				job.state = "submitting"
				acted = true
			"submitting":
				acted = true
				if (job.canvas as InkCanvas).submit_some(slice):
					job["frame"] = Engine.get_frames_drawn()
					job.state = "render"
			"render":
				if Engine.get_frames_drawn() > job.frame:
					(job.canvas as InkCanvas).collect_async(func(img: Image) -> void: job["img"] = img)
					job.state = "arriving"
					acted = true
			"arriving":
				if not job.has("img"):
					continue
				var img: Image = job.img
				job.erase("img")
				if img == null or img.is_empty():
					_finish(job, null)
					acted = true
				elif threaded:
					job["mip_task"] = WorkerThreadPool.add_task(func() -> void: img.generate_mipmaps())
					job["pixels"] = img
					job.state = "mipmaps"
					acted = true
				else:
					img.generate_mipmaps()
					_finish(job, ImageTexture.create_from_image(img))
					acted = true
			"mipmaps":
				if not WorkerThreadPool.is_task_completed(job.mip_task):
					continue
				WorkerThreadPool.wait_for_task_completion(job.mip_task)
				job.erase("mip_task")
				var done_img: Image = job.pixels
				job.erase("pixels")
				_finish(job, ImageTexture.create_from_image(done_img))
				acted = true
	_start()   # after the pump: a twin whose recording just finished takes its next chunk this frame
	var spent := (Time.get_ticks_usec() - t0) / 1000.0
	stats.main_ms = float(stats.main_ms) + spent
	stats.main_ms_max_frame = maxf(float(stats.main_ms_max_frame), spent)

func _note_record(ms: float) -> void:
	stats.record_ms = ms
	stats.record_ms_max = maxf(float(stats.record_ms_max), ms)
	stats.record_ms_sum = float(stats.record_ms_sum) + ms

func _finish(job: Dictionary, tex: Texture2D) -> void:
	_jobs.erase(job)
	stats.finished = int(stats.finished) + 1
	if tex != null and on_done.is_valid():
		on_done.call(job.key, tex)

# Starts recordings: a free twin with work, while fewer than max_inflight are past the queue.
func _start() -> void:
	var started := 0
	for i in twins.size():
		if started >= starts_per_frame or _jobs.size() >= max_inflight:
			break
		if _busy[i]:
			continue
		var q: Array = _queues[i]
		if _heads[i] >= q.size():
			continue
		var key: Vector3i = q[_heads[i]]
		_heads[i] += 1
		_queued -= 1
		if _heads[i] >= q.size():
			q.clear()
			_heads[i] = 0
		var tw = twins[i]
		var c := Vector2i(key.x, key.y)
		var s: float = tw.lods[key.z]
		var job := {"key": key, "twin": i, "state": "recording"}
		if threaded:
			var box := [null, 0.0]   # [canvas, ms]: written by the worker only
			job["box"] = box
			job["task"] = WorkerThreadPool.add_task(func() -> void:
				var tw0 := Time.get_ticks_usec()
				box[0] = tw.make_canvas(c, s)
				box[1] = (Time.get_ticks_usec() - tw0) / 1000.0, true)
			_busy[i] = true
		else:
			var tr := Time.get_ticks_usec()
			var g = tw.make_canvas(c, s)
			job["box"] = [g, (Time.get_ticks_usec() - tr) / 1000.0]
		_jobs.append(job)
		stats.started = int(stats.started) + 1
		started += 1
