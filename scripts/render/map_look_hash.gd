extends SceneTree

# THE LOOK OF THE BAKED MAP AND OF THE FOG'S TOPOGRAPHIC LAYER, as hashes (map-performance
# track, 2026-10-10): run it before and after a change to the baking and diff the two files.
# A tool, not a test (it needs a window; the gate is headless).
#
#   pixels (WINDOWED):  INKWOOD_STEAM=off Godot_console.exe --path . --script res://scripts/render/map_look_hash.gd -- out=tmp/render/look_before.json
#   ops (headless OK):  INKWOOD_STEAM=off Godot_console.exe --headless --path . --script res://scripts/render/map_look_hash.gd -- mode=ops
#                       prints the recorded-paint-call hashes test_fog.gd keeps in OPS_HASHES
#                       (regenerate them when Track T's terrain data or px_per_m changes)
#
# Hashes (SHA-256 of the image bytes, mipmaps included) of
#   map:<cx>,<cy>        three baked map chunks through the real ChunkBaker (request + step)
#   fogdirect:<cx>,<cy>,<lod>  FogTopo.bake_chunk (the unchanged synchronous API: the reference
#                        for what a fog chunk looks like)
#   fog:<cx>,<cy>,<lod>  the FogLayer's own pipeline (whatever it is: main-thread recording and
#                        a synchronous read-back in the committed code, worker recording and an
#                        asynchronous read-back after) - every chunk of the view at three zooms
# and writes them as JSON. Run before and after a change and diff the files.

const MapView = preload("res://scripts/render/map_view.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")
const FogTopo = preload("res://scripts/render/fog_topo.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

var opts: Dictionary = {}
var out: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

static func _hash(tex: Texture2D) -> String:
	var img := tex.get_image()
	return "%dx%d m%s %s" % [img.get_width(), img.get_height(), str(img.has_mipmaps()), _sha(img.get_data())]

func _run() -> void:
	if str(opts.get("mode", "pixels")) == "ops":
		_ops()
		quit(0)
		return
	await _frames(5)
	await _map()
	await _fog()
	_self_check()
	var path := str(opts.get("out", "tmp/render/map_look.json"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  ", true))
	f.close()
	print("[look] wrote %d hashes to %s" % [out.size(), path])
	quit(0)

func _map() -> void:
	var view = MapView.new(20261009, Rect2(), 0.0, "", RenderParams.new())
	view.bake_enabled = false
	view.input_enabled = false
	var baker = view.baker
	var list: Array[Vector2i] = [Vector2i(4, 4), Vector2i(5, 3), Vector2i(2, 6)]
	for i in list.size():
		baker.request(list[i], float(i))
	var t0 := Time.get_ticks_msec()
	var left := list.size()
	while left > 0 and Time.get_ticks_msec() - t0 < 120000:
		await process_frame
		for r: Dictionary in baker.step(6000):
			out["map:%d,%d" % [r.c.x, r.c.y]] = _hash(r.texture)
			left -= 1
	print("[look] map chunks %d baked in %d ms" % [list.size() - left, Time.get_ticks_msec() - t0])
	baker.clear()
	view.free()

func _fog() -> void:
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	root.add_child(vp)
	var terrain := Terrain.new(20261009)
	var fog := FogLayer.new()
	fog.setup(terrain)
	fog.bakes_per_frame = int(opts.get("bakes", "6"))
	var cam := Camera2D.new()
	vp.add_child(cam)
	vp.add_child(fog)
	cam.make_current()
	await _frames(3)
	var centre := terrain.map_rect_px().get_center()
	for z: float in [0.9, 0.3, 0.08]:
		cam.position = centre
		cam.zoom = Vector2(z, z)
		await _frames(3)
		var lod: int = fog.topo.lod_for_zoom(fog._zoom)
		var view: Rect2 = fog.view_rect_px()
		var want: Array[Vector3i] = []
		for c in terrain.chunks_in_rect_px(view.grow(fog.topo.chunk_px)):
			want.append(Vector3i(c.x, c.y, lod))
		var t0 := Time.get_ticks_msec()
		var missing := 1
		while missing > 0 and Time.get_ticks_msec() - t0 < 180000:
			await process_frame
			missing = 0
			for k in want:
				if not fog._cache.has(k):
					missing += 1
		print("[look] fog zoom %.2f lod %d: %d chunks wanted, %d missing after %d ms" % [z, lod, want.size(), missing, Time.get_ticks_msec() - t0])
		var s: float = fog.topo.lods[lod]
		var n := 0
		for k in want:
			if fog._cache.has(k):
				out["fog:%d,%d,%d" % [k.x, k.y, k.z]] = _hash(fog._cache[k])
				n += 1
			# the unchanged synchronous API, for a sample of the view
			if n % 7 == 1 and fog._cache.has(k):
				out["fogdirect:%d,%d,%d" % [k.x, k.y, k.z]] = _hash(fog.topo.bake_chunk(Vector2i(k.x, k.y), s))
	if fog.has_method("shutdown"):
		fog.shutdown()
	vp.queue_free()
	await _frames(2)

func _self_check() -> void:
	var bad := 0
	var n := 0
	for k: String in out:
		if k.begins_with("fogdirect:"):
			n += 1
			if out["fog:" + k.substr(10)] != out[k]:
				bad += 1
				print("[look] MISMATCH pipeline vs direct bake at ", k.substr(10))
	print("[look] pipeline vs FogTopo.bake_chunk: %d samples, %d differ" % [n, bad])

static func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()

# SHA-256 (first 16 hex) of the paint calls recorded on a chunk canvas, for the chunks test_fog.gd checks.
func _ops() -> void:
	var terrain := Terrain.new(20261009)
	var topo := FogTopo.new(terrain)
	topo.prepare_threaded()
	print("[look] px_per_m %s" % terrain.px_per_m)
	for key: String in ["10,9,0", "10,9,1", "10,9,2", "0,0,0", "19,19,1"]:
		var p := key.split(",")
		var c := Vector2i(int(p[0]), int(p[1]))
		var s: float = topo.lods[int(p[2])]
		var g := topo.make_canvas(c, s)
		g._flush_batch()
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(var_to_bytes(g._ops))
		var main_sig := ctx.finish().hex_encode().substr(0, 16)
		var w := topo.make_canvas_threaded(c, s)
		w._flush_batch()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(var_to_bytes(w._ops))
		var worker_sig := ctx.finish().hex_encode().substr(0, 16)
		print("[look] \"%s\": \"%s\"%s" % [key, main_sig, "" if main_sig == worker_sig else "   (the worker twin differs: %s)" % worker_sig])
