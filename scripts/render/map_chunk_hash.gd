extends SceneTree

# THE LOOK OF BAKED MAP TILES, AS HASHES (Track W, 2026-10-10): the proof that a change to what the
# map holds leaves the tiles it does not touch pixel for pixel as they were. A tool, not a test (it
# needs a window; the gate is headless). scripts/render/map_look_hash.gd is the map-performance
# track's, for three tiles and the fog; this one takes a list of tiles and says which of them the
# village reaches.
#
#   INKWOOD_STEAM=off Godot_console.exe --path . --script res://scripts/render/map_chunk_hash.gd -- out=tmp/village/hash_after.json
#   ... -- out=<file> chunks="1,1;3,3;8,3"      (default: a 4 x 4 grid over the map plus three more)
#   ... -- out=<file> compare=<file from an earlier run>    (prints same / DIFFERENT per tile)
#
# THE PROCEDURE for "before and after": extract the commit before the change into a scratch folder
# (git archive HEAD scripts data project.godot scenes addons steam_appid.txt | tar -x -C tmp/village/base;
# copy this file in; import it once with --headless --import), run this tool in both trees with the
# same list, and compare. WHAT TO EXPECT (measured 2026-10-10, 19 tiles, three runs of each tree):
# SHA-256 of a tile's bytes, mipmaps and all, is the same in every run for 14 tiles; a tile the
# village reaches differs, always, the same way; and the HEAD tree ITSELF gives a different hash on
# one or two tiles per run (a pre-existing flake in the baker's read-back, not in this change), so
# a tile that differs once and matches on a rerun is that flake, not a difference.

const MapView = preload("res://scripts/render/map_view.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

var opts: Dictionary = {}
var out: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

func _list() -> Array[Vector2i]:
	var list: Array[Vector2i] = []
	if opts.has("chunks"):
		for s: String in str(opts["chunks"]).split(";"):
			var p := s.split(",")
			list.append(Vector2i(int(p[0]), int(p[1])))
		return list
	for cy in [1, 3, 6, 8]:
		for cx in [1, 3, 6, 8]:
			list.append(Vector2i(cx, cy))
	for c: Vector2i in [Vector2i(4, 4), Vector2i(5, 3), Vector2i(2, 6)]:
		if not list.has(c):
			list.append(c)
	return list

func _run() -> void:
	for _i in 5:
		await process_frame
	var view = MapView.new(20261009, Rect2(), 0.0, "", RenderParams.new())
	view.bake_enabled = false
	view.input_enabled = false
	var baker = view.baker
	var list := _list()
	for i in list.size():
		baker.request(list[i], float(i))
	var t0 := Time.get_ticks_msec()
	var left := list.size()
	while left > 0 and Time.get_ticks_msec() - t0 < 900000:
		await process_frame
		for r: Dictionary in baker.step(6000):
			out["map:%d,%d" % [r.c.x, r.c.y]] = _hash(r.texture)
			left -= 1
	print("[hash] %d of %d tiles baked in %d ms" % [list.size() - left, list.size(), Time.get_ticks_msec() - t0])
	var reached := _reached(view, list)
	baker.clear()
	view.free()
	var path := str(opts.get("out", "tmp/village/hash.json"))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  ", true))
	f.close()
	print("[hash] wrote %d hashes to %s" % [out.size(), path])
	if opts.has("compare"):
		_compare(str(opts["compare"]), reached)
	quit(0)

# Which tiles the village reaches (its structures, fields, road or hedge trees within shadow reach).
func _reached(view, list: Array[Vector2i]) -> Dictionary:
	var res := {}
	var vil: Variant = view.provider.village() if view.provider.has_method("village") else null   # (a tree without the village has none)
	for c in list:
		var rect: Rect2 = view.provider.chunk_rect(c).grow(view.provider.ts.reach_px())
		var hit := false
		if vil != null:
			hit = not (vil.structs_in_rect(rect) as Array).is_empty() or not (vil.fields_in_rect(rect) as Array).is_empty() \
				or not (vil.road_runs_in_rect(rect, 40.0) as Array).is_empty()
		res["map:%d,%d" % [c.x, c.y]] = hit
	return res

func _compare(path: String, reached: Dictionary) -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (raw is Dictionary):
		printerr("[hash] cannot read ", path)
		return
	var base: Dictionary = raw
	var same := 0
	var differ := 0
	for k: String in out:
		if not base.has(k):
			continue
		var is_same: bool = base[k] == out[k]
		same += 1 if is_same else 0
		differ += 0 if is_same else 1
		print("[hash] %-10s %s   village reaches this tile: %s" % [k, "same     " if is_same else "DIFFERENT", "yes" if reached.get(k, false) else "no"])
	print("[hash] %d same, %d different" % [same, differ])

static func _hash(tex: Texture2D) -> String:
	var img := tex.get_image()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(img.get_data())
	return "%dx%d m%s %s" % [img.get_width(), img.get_height(), str(img.has_mipmaps()), ctx.finish().hex_encode()]
