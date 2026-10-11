extends RefCounted

# A SMALL BAKE PIPELINE for the border's tiles (builder, map-border board, 2026-10-11; PROPOSED). Option C bakes its contours into
# textures ONCE per option and scale; this is the machinery, in the manner of the fog's (fog_topo_baker.gd) and the map's
# (chunk_baker.gd) bakers, and it never forces a frame or stalls on a read-back:
#
#   queued       waiting for a recorder thread and a free twin
#   recording    a WORKER thread records the tile's canvas on a PRIVATE twin (the terrain's caches are not thread-safe, so a twin is
#                used by one task at a time): `recorder.call(job, twin) -> InkCanvas`
#   recorded     the canvas is back; waiting for its turn on the main thread (at most `submits_per_frame` a frame)
#   submitting   main thread: InkCanvas.begin_submit / submit_some in slices of `submit_budget_us`, so a big tile never costs a frame
#   submitted    drawn by the engine's next frame
#   reading      InkCanvas.collect_async: the pixels arrive a frame or two later (no stall)
#   done         `on_done.call(job, image)` on the main thread, with the Image; the caller makes its texture
#
# At most `in_flight` jobs are past `queued` at once (each holds a supersampled render target). A headless run (no frames are drawn,
# nothing can be read back) bakes nothing: `rendering` is false there, tick() returns at once and pending() is 0.
# shutdown() waits for every worker task: a quit with a task still running GDScript crashes the engine (CLAUDE.md).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

class Job:
	var id := 0
	var rect := Rect2()          # map px
	var level := 0
	var side := 0
	var twin := 0                # which twin records it
	var payload: Variant = null  # whatever the caller needs back
	var state := "queued"
	var task := -1
	var canvas: InkCanvas = null
	var frame := 0
	var image: Image = null
	var ops := 0                 # recorded canvas items, for the report
	var record_ms := 0.0

var recorder: Callable = Callable()   # (job, twin) -> InkCanvas   WORKER THREAD
var on_done: Callable = Callable()    # (job, image or null)       main thread
var twins: Array = []
var in_flight := 4
var submits_per_frame := 2
var submit_budget_us := 3000
var rendering := true
var priority: Callable = Callable()   # (job) -> float: lower first; evaluated when the queue is re-sorted

var jobs: Array[Job] = []
var _queue: Array[Job] = []
var _recording: Array[Job] = []
var _recorded: Array[Job] = []
var _submitting: Array[Job] = []
var _submitted: Array[Job] = []
var _reading: Array[Job] = []
var _results: Dictionary = {}
var _arrived: Dictionary = {}
var _mutex := Mutex.new()
var _busy: Array[bool] = []
var failed := 0
var stats := {"jobs": 0, "done": 0, "record_ms": 0.0, "submit_ms": 0.0, "max_frame_ms": 0.0, "max_begin_ms": 0.0, "max_collect_ms": 0.0, "max_done_ms": 0.0}

func _init(twin_list: Array) -> void:
	twins = twin_list
	for _t in twins:
		_busy.append(false)
	rendering = DisplayServer.get_name() != "headless"

func add(job: Job) -> void:
	job.id = jobs.size()
	jobs.append(job)
	_queue.append(job)
	stats.jobs = jobs.size()

# Jobs not made yet. A headless run has nothing to bake into (no frames are drawn): 0 there, and tick() does nothing.
func pending() -> int:
	return jobs.size() - int(stats.done) if rendering else 0

# Re-sorts the queue by `priority` (the caller calls it when the camera moves, so the tiles in view are baked first).
func resort() -> void:
	if not priority.is_valid() or _queue.size() < 2:
		return
	_queue.sort_custom(func(a: Job, b: Job) -> bool: return float(priority.call(a)) < float(priority.call(b)))

func tick() -> void:
	if not rendering:
		return
	var t0 := Time.get_ticks_usec()
	# 1. recordings that finished
	for j: Job in _recording.duplicate():
		if WorkerThreadPool.is_task_completed(j.task):
			WorkerThreadPool.wait_for_task_completion(j.task)
			_busy[j.twin] = false
			_recording.erase(j)
			_mutex.lock()
			var cv: Variant = _results.get(j.id)
			_results.erase(j.id)
			_mutex.unlock()
			if cv == null:
				failed += 1
				_finish(j, null)
			else:
				j.canvas = cv
				j.state = "recorded"
				_recorded.append(j)
	if true:
		# 2. submit
		var started := 0
		while not _recorded.is_empty() and started < submits_per_frame and _submitting.size() < submits_per_frame:
			var j: Job = _recorded.pop_front()
			var tb := Time.get_ticks_usec()
			j.canvas.begin_submit()
			stats.max_begin_ms = maxf(float(stats.max_begin_ms), (Time.get_ticks_usec() - tb) / 1000.0)
			j.state = "submitting"
			_submitting.append(j)
			started += 1
		var tm := Time.get_ticks_usec()
		for j: Job in _submitting.duplicate():
			var left := submit_budget_us - (Time.get_ticks_usec() - tm)
			if left <= 0:
				break
			if j.canvas.submit_some(left):
				_submitting.erase(j)
				j.frame = Engine.get_frames_drawn()
				j.state = "submitted"
				_submitted.append(j)
		stats.submit_ms = float(stats.submit_ms) + (Time.get_ticks_usec() - tm) / 1000.0
		# 3. a frame has drawn the submitted canvas: ask for its pixels
		for j: Job in _submitted.duplicate():
			if Engine.get_frames_drawn() > j.frame:
				_submitted.erase(j)
				var cv: InkCanvas = j.canvas
				j.canvas = null
				j.state = "reading"
				_reading.append(j)
				var tc := Time.get_ticks_usec()
				cv.collect_async(func(img: Image) -> void: _arrived[j.id] = img)
				stats.max_collect_ms = maxf(float(stats.max_collect_ms), (Time.get_ticks_usec() - tc) / 1000.0)
		# 4. pixels that arrived
		for j: Job in _reading.duplicate():
			if _arrived.has(j.id):
				_reading.erase(j)
				var img: Image = _arrived[j.id]
				_arrived.erase(j.id)
				_finish(j, img)
	# 5. start recordings
	var active := _recording.size() + _recorded.size() + _submitting.size() + _submitted.size() + _reading.size()
	var i := 0
	while i < _queue.size() and active < in_flight:
		var j: Job = _queue[i]
		if _busy[j.twin]:
			i += 1
			continue
		_queue.remove_at(i)
		_busy[j.twin] = true
		j.state = "recording"
		j.task = WorkerThreadPool.add_task(Callable(self, "_record").bind(j), false, "map border tile")
		_recording.append(j)
		active += 1
	stats.max_frame_ms = maxf(float(stats.max_frame_ms), (Time.get_ticks_usec() - t0) / 1000.0)

# On a worker thread.
func _record(j: Job) -> void:
	var t0 := Time.get_ticks_usec()
	var cv: Variant = recorder.call(j, twins[j.twin])
	j.record_ms = (Time.get_ticks_usec() - t0) / 1000.0
	if cv != null:
		j.ops = (cv as InkCanvas).op_count()
	_mutex.lock()
	_results[j.id] = cv
	stats.record_ms = float(stats.record_ms) + j.record_ms
	_mutex.unlock()

func _finish(j: Job, img: Image) -> void:
	j.state = "done"
	j.image = img
	stats.done = int(stats.done) + 1
	if on_done.is_valid():
		var td := Time.get_ticks_usec()
		on_done.call(j, img)
		stats.max_done_ms = maxf(float(stats.max_done_ms), (Time.get_ticks_usec() - td) / 1000.0)

# Waits for every worker task and frees every canvas not yet drawn. The jobs are dropped.
func shutdown() -> void:
	for j: Job in _recording:
		WorkerThreadPool.wait_for_task_completion(j.task)
	_recording.clear()
	for list: Array in [_recorded, _submitting]:
		for j: Job in list:
			if j.canvas != null:
				j.canvas.discard()
				j.canvas = null
		list.clear()
	_mutex.lock()
	for k: Variant in _results:
		if _results[k] != null:
			(_results[k] as InkCanvas).discard()
	_results.clear()
	_mutex.unlock()
	# (a canvas already drawn and being read back frees itself when its pixels arrive)
	_queue.clear()
	_submitted.clear()
	_reading.clear()
	jobs.clear()
