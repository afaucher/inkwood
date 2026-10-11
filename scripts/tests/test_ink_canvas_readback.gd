extends "res://scripts/test_support/test_case.gd"

# THE ASYNCHRONOUS READ-BACK FREES NOTHING INSIDE THE ENGINE (fix 2026-10-10).
# InkCanvas.collect_async asks RenderingDevice.texture_get_data_async for a canvas's pixels, and
# the engine calls back from inside its own frame processing -- and, whenever something does a
# SYNCHRONOUS read-back meanwhile (Texture2D.get_image, RenderingServer.texture_2d_get,
# InkCanvas.render_all), from inside that call's flush of every frame in flight. The callback used
# to free the spent canvas right there (canvas items, viewports, and with them the last references
# to its materials and textures), and a free in the middle of that flush made canvases drawn
# afterwards come out wrong: 1 to 4 of 19 map tiles per run baked with a shadow mask uncut, empty
# or opaque -- a receiver's tree shadows missing, the whole terrain shade black. Now the engine's
# callback only builds the Image and hands it to _pixels_arrived, which leaves freeing the canvas
# and calling the caller back to the message queue: the main loop flushes it outside the engine's
# frame processing.
#
# Headless there is no RenderingDevice (collect_async reads back synchronously instead), so this
# calls the landing directly, as the engine's callback does, and checks:
#   1. on return the canvas is not freed and the caller has not been called back;
#   2. after the message queue has run, the canvas is spent and the caller got its image, once;
#   3. a canvas nothing else holds stays alive until then (the deferred call holds it), so it is
#      not freed when the engine drops its callback either.
# The windowed half is scripts/render/map_chunk_hash.gd repeat=5 (every tile, every pass, the same).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")

var _held: InkCanvas
var _lone_id := 0
var _got: Array = []
var _got_lone: Array = []
var _sent: Image
var _frames := 0
var _setup_done := false

func setup(_main) -> void:
	check(load("res://scripts/render/ink_canvas.gd").can_instantiate(), "ink_canvas.gd compiles")
	_sent = Image.create(8, 8, false, Image.FORMAT_RGBA8)
	_sent.fill(Color(0.25, 0.5, 0.75, 1.0))
	_held = _submitted()
	_held._pixels_arrived(_sent, func(img: Image) -> void: _got.append(img))
	check(not _held._done, "1. the canvas is not freed inside the engine's callback")
	eq(_got.size(), 0, "1. the caller is not called back inside the engine's callback")
	var lone := _submitted()
	_lone_id = lone.get_instance_id()
	lone._pixels_arrived(_sent, func(img: Image) -> void: _got_lone.append(img))
	lone = null  # what the engine does with its callback (and the canvas it captured) once it has run
	check(is_instance_id_valid(_lone_id), "3. an unheld canvas outlives the engine's callback")
	_setup_done = true

func _submitted() -> InkCanvas:
	var g := InkCanvas.new(Vector2i(8, 8))
	g.fill_color = Color.BLACK
	g.fill_rect(0.0, 0.0, 8.0, 8.0)
	g.begin_submit()
	check(g.submit_some(1 << 30), "the canvas submits")
	return g

func _physics_process(_delta: float) -> void:
	if _finished:
		return
	_frames += 1
	if _frames < 3:
		return
	check(_setup_done, "setup ran to its end")
	check(_held != null and _held._done, "2. the canvas is spent once the message queue has run")
	eq(_got.size(), 1, "2. the caller is called back once")
	check(_got.size() == 1 and _got[0] == _sent, "2. with the image that arrived")
	eq(_got_lone.size(), 1, "3. the unheld canvas's caller is called back once")
	check(not is_instance_id_valid(_lone_id), "3. and then the unheld canvas is gone")
	finish()
