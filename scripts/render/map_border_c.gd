extends "res://scripts/render/map_border_base.gd"

# OPTION C, "Contours continue" (builder, map-border board, 2026-10-11; PROPOSED). Past the edge the terrain goes on in the fog's
# topographic style -- the contour lines only: no trees, no level tones, no hachures, no shadows -- in a fainter ink (a lighter
# role, 62% of the way to paper), so the world does not stop. The playable map keeps its full ink and ends at a thin edge line. Far
# out the contours fade to blank paper over `c.fade`, so the ring never ends in a hard square. With `c.contour.water_lines` the
# sea's shore and depth steps go on too (the fog's water lines; no wash), so a sea that runs off the map's edge goes on.
#
# THE BAKE (once per option and scale). The height field is continuous past the edge (the terrain makes a chunk from its seed and
# coordinates alone; only its LISTS keep to the map's chunks), so the contours are recorded with the fog's own drawing
# (map_border_contours.gd: FogTopo._add_offset) for rectangles of map px outside the map, on WORKER threads, each on a private twin
# of the terrain (the fog's way), into tiles of at most c.lods.tile_texels a side, at three levels of detail like the fog's
# (c.lods.texels_per_px: one texel a map px for the band, a quarter and a sixteenth for the wide strips of the full zoom-out), each
# level a ring of its own depth. Each tile is submitted to the GPU in slices, drawn, read back without a stall
# (map_border_bake.gd), made one channel (R8: the lines' coverage) with mipmaps, and shown as a quad whose shader (map_border_contour.
# gdshader) gives it the ink colour and the fade. Per frame there is nothing to do but choose the level for the zoom.
#
# NEVER BLANK: the paper fill is there at once; tiles appear as they land. A level that is not wholly baked is not shown instead of
# the one wanted until it is (the wanted level shows what has landed).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Bake = preload("res://scripts/render/map_border_bake.gd")
const Contours = preload("res://scripts/render/map_border_contours.gd")
const FogTopo = preload("res://scripts/render/fog_topo.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const TERRAIN_PATH := "res://data/terrain/terrain.json"
const CONTOUR_SHADER = preload("res://scripts/render/map_border_contour.gdshader")
const WASH_SHADER = preload("res://scripts/render/map_border_wash.gdshader")

# The sea's quiet wash: one quad over the ring (map_border_wash.gdshader paints it from the depth mask).
class WashNode extends Node2D:
	var rect := Rect2()

	func _init() -> void:
		name = "Wash"
		z_index = 2

	func _draw() -> void:
		draw_rect(rect, Color.WHITE)

class Level:
	var s := 1.0                  # texels per map px
	var depth_px := 0.0           # how far past the edge, map px
	var container: Node2D = null
	var tiles: Array = []         # Bake.Job
	var done := 0

var levels: Array[Level] = []
var _bake: Bake
var _mat: ShaderMaterial
var _with_water := true
var _lod_ratio := 0.75
var _zoom := 1.0
var _centre := Vector2.ZERO
var _dirty := false
var _chosen := 0
var _shown := -1
var _tiles_root: Node2D
var _sprites: Dictionary = {}   # job id -> Sprite2D
var _textures_bytes := 0
var _released := false
var _water: RefCounted = null
var _wash_on := false
var _wash_cell := 16.0
var _wash_strength := 1.0
var _wash_node: WashNode = null
var _wash_mat: ShaderMaterial = null
var _wash_task := -1
var _wash_img: Image = null
var _wash_args := {}
var _wash_done := true

func build() -> void:
	var d: CameraData = b.data
	d.text("c.name")
	var f := make_fill(true, b.role("paper.role"))
	var edge_c: Color = b.role("c.edge.line_role")
	f.set_param("line_color", vec4(edge_c))
	f.set_param("line_px", d.num("c.edge.line_px"))
	f.set_param("wobble_px", d.num("c.edge.wobble_px"))
	f.set_param("wobble_freq", d.num("c.edge.wobble_per_px"))
	var ink: Color = b.role("c.contour.role")
	var ink_alpha := d.num("c.contour.alpha")
	_with_water = d.flag("c.contour.water_lines")
	var texels := d.floats("c.lods.texels_per_px")
	var depths := d.floats("c.lods.depth_m")
	_lod_ratio = d.num("c.lods.lod_ratio")
	var tile_texels := d.integer("c.lods.tile_texels")
	var ppm: float = b.px_per_m
	var fade_from: float = d.num("c.fade.from_m") * ppm
	var fade_to: float = d.num("c.fade.to_m") * ppm
	var workers := maxi(1, d.integer("c.bake.workers"))
	_wash_on = d.flag("c.wash.on")
	_wash_cell = d.num("c.wash.cell_m")
	_wash_strength = d.num("c.wash.strength")
	var per_frame := d.integer("c.bake.tiles_per_frame")
	var in_flight := d.integer("c.bake.in_flight")
	var r: Rect2 = b.map_rect_px
	_mat = ShaderMaterial.new()
	_mat.shader = CONTOUR_SHADER
	_mat.set_shader_parameter("ink", Vector4(ink.r, ink.g, ink.b, ink.a * ink_alpha))
	_mat.set_shader_parameter("map_rect", Vector4(r.position.x, r.position.y, r.end.x, r.end.y))
	_mat.set_shader_parameter("fade_from", fade_from)
	_mat.set_shader_parameter("fade_to", fade_to)
	_tiles_root = Node2D.new()
	_tiles_root.name = "Contours"
	_tiles_root.z_index = 2
	b.add_child(_tiles_root)
	# the bake's twins: private terrains (and the water's own, when the map has one), made here on the main thread
	var twins: Array = []
	for _i in workers:
		twins.append(_make_twin())
	_bake = Bake.new(twins)
	_bake.recorder = Callable(self, "_record")
	_bake.on_done = Callable(self, "_landed")
	_bake.priority = Callable(self, "_priority")
	_bake.in_flight = in_flight
	_bake.submits_per_frame = per_frame
	if texels.size() != depths.size() or texels.is_empty():
		push_error("MapBorder C: c.lods.texels_per_px and depth_m must be lists of the same length")
		return
	# the sea past the edge, as the fog's quiet wash, under the contours (a node before the levels' in the tree)
	_water = (twins[0] as FogTopo).water
	if _wash_on and _water != null:
		_build_wash(fade_from, fade_to, twins[0])
	# the plan: per level, four strips (the top and bottom ones take the corners), each cut along its length into tiles
	for i in texels.size():
		var lv := Level.new()
		lv.s = texels[i]
		lv.depth_px = depths[i] * ppm
		lv.container = Node2D.new()
		lv.container.name = "Level%d" % i
		_tiles_root.add_child(lv.container)
		var D := lv.depth_px
		var strips := [
			Rect2(r.position.x - D, r.position.y - D, r.size.x + 2.0 * D, D),    # 0 top
			Rect2(r.end.x, r.position.y, D, r.size.y),                           # 1 right
			Rect2(r.position.x - D, r.end.y, r.size.x + 2.0 * D, D),             # 2 bottom
			Rect2(r.position.x - D, r.position.y, D, r.size.y),                  # 3 left
		]
		for side in 4:
			var st: Rect2 = strips[side]
			var horizontal := side == 0 or side == 2
			var length: float = st.size.x if horizontal else st.size.y
			var ltex := maxi(1, int(ceil(length * lv.s - 1e-6)))
			var n := maxi(1, int(ceil(float(ltex) / float(tile_texels))))
			var each := int(ceil(float(ltex) / float(n)))
			for k in n:
				var t0 := k * each
				var t1 := mini((k + 1) * each, ltex)
				var a := float(t0) / lv.s
				var bb := float(t1) / lv.s
				var rect := Rect2(st.position.x + a, st.position.y, bb - a, st.size.y) if horizontal else Rect2(st.position.x, st.position.y + a, st.size.x, bb - a)
				var job := Bake.Job.new()
				job.rect = rect
				job.level = i
				job.side = side
				job.twin = side % workers
				lv.tiles.append(job)
				var sp := Sprite2D.new()
				sp.centered = false
				sp.position = rect.position
				sp.scale = Vector2(1.0 / lv.s, 1.0 / lv.s)
				sp.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
				sp.material = _mat
				lv.container.add_child(sp)
				_sprites[job] = sp
		levels.append(lv)
	# the order: the level the view wants first (level 0 until the first frame says otherwise)
	for lv: Level in levels:
		for job: Bake.Job in lv.tiles:
			_bake.add(job)
	_bake.resort()
	_choose()

# The wash: a mask of the water's depth on a coarse grid over the ring (made on a worker thread, a few thousand samples of the
# generator), one quad, and the step colours at the fog's quiet strength.
func _build_wash(fade_from: float, fade_to: float, twin: FogTopo) -> void:
	var ppm: float = b.px_per_m
	var r: Rect2 = b.map_rect_px
	var reach := fade_to + 2.0 * _wash_cell * ppm
	var origin_m := (r.position - Vector2(reach, reach)) / ppm
	var n := int(ceil((r.size.x + 2.0 * reach) / ppm / _wash_cell))
	_wash_args = {"origin": origin_m, "n": n, "map": Rect2(r.position / ppm, r.size / ppm)}
	_wash_mat = ShaderMaterial.new()
	_wash_mat.shader = WASH_SHADER
	var side := float(n) * _wash_cell * ppm
	_wash_mat.set_shader_parameter("area", Vector4(origin_m.x * ppm, origin_m.y * ppm, side, side))
	_wash_mat.set_shader_parameter("map_rect", Vector4(r.position.x, r.position.y, r.end.x, r.end.y))
	_wash_mat.set_shader_parameter("fade_from", fade_from)
	_wash_mat.set_shader_parameter("fade_to", fade_to)
	var alpha: float = (1.0 - twin.water_quiet) * _wash_strength
	for k in 3:
		var c: Color = twin.water_draw.steps[k]
		_wash_mat.set_shader_parameter("step%d" % k, Vector4(c.r, c.g, c.b, alpha))
	var from: PackedFloat64Array = _water.step_from
	_wash_mat.set_shader_parameter("thresholds", Vector3(from[0], from[1], from[2]))
	_wash_node = WashNode.new()
	_wash_node.rect = Rect2(origin_m * ppm, Vector2(side, side))
	_wash_node.material = _wash_mat
	_tiles_root.add_child(_wash_node)
	if DisplayServer.get_name() != "headless":
		_wash_done = false
		_wash_task = WorkerThreadPool.add_task(Callable(self, "_wash_compute"), false, "map border wash")

# WORKER THREAD.
func _wash_compute() -> void:
	_wash_img = wash_image()

# The depth mask: water depth s (metres, clamped to -8 .. 48) at the centre of each cell, 0..255 over that range; the map's own
# interior (two cells in from its edge) is left empty. Public for the test, which runs it on the main thread.
func wash_image() -> Image:
	var origin: Vector2 = _wash_args["origin"]
	var n: int = _wash_args["n"]
	var map: Rect2 = _wash_args["map"]
	var inner := map.grow(-_wash_cell * 2.0)
	var data := PackedByteArray()
	data.resize(n * n)
	for j in n:
		var y := origin.y + (float(j) + 0.5) * _wash_cell
		for i in n:
			var x := origin.x + (float(i) + 0.5) * _wash_cell
			if inner.has_point(Vector2(x, y)):
				continue
			var depth := clampf(float(_water.s_at(x, y)), -8.0, 48.0)
			data[j * n + i] = int(roundf((depth + 8.0) / 56.0 * 255.0))
	return Image.create_from_data(n, n, false, Image.FORMAT_R8, data)

# A twin: a FogTopo over a terrain of its own (the map's own maker, so the water's capped ground when the map has water), made on
# the main thread. The recorder thread that gets it is the only one that touches it while it records.
func _make_twin() -> RefCounted:
	var view: Node2D = b.view
	var maker := Callable()
	var water: RefCounted = null
	var prov: Object = view.get("provider")
	if prov != null:
		var m: Variant = prov.get("terrain_maker")
		if m is Callable and (m as Callable).is_valid():
			maker = m
		water = prov.get("water")
	var seed_v: int = view.seed_value
	var t: Terrain = maker.call(seed_v, TERRAIN_PATH, b.P) if maker.is_valid() else Terrain.new(seed_v, TERRAIN_PATH, b.P)
	t.px_per_m = float(b.px_per_m)
	var topo := FogTopo.new(t, CameraData.new(CameraData.FOG_PATH), b.P)
	topo.terrain_maker = maker
	if water != null:
		topo.set_water(water)
	return topo

# WORKER THREAD: the canvas of a tile.
func _record(job: Bake.Job, twin: RefCounted) -> InkCanvas:
	var lv: Level = levels[job.level]
	return Contours.record(twin, job.rect, lv.s, _with_water)

# Main thread: a tile's pixels. One channel, mipmaps, a texture on its quad.
func _landed(job: Bake.Job, img: Image) -> void:
	var lv: Level = levels[job.level]
	lv.done += 1
	if img != null:
		img.convert(Image.FORMAT_R8)
		img.generate_mipmaps()
		var tex := ImageTexture.create_from_image(img)
		(_sprites[job] as Sprite2D).texture = tex
		_textures_bytes += int(img.get_data().size())
	_dirty = true

func _priority(job: Bake.Job) -> float:
	return float(absi(job.level - _chosen)) * 1.0e9 + job.rect.get_center().distance_to(_centre)

func _lod_for(z: float) -> int:
	for i in range(levels.size() - 1, -1, -1):
		if levels[i].s >= _lod_ratio * z:
			return i
	return 0

# Which level is shown: the level the zoom wants if it is wholly baked, else the nearest level that is, else the wanted one (with
# whatever tiles of it have landed).
func _choose() -> void:
	var want := _lod_for(_zoom)
	_chosen = want
	var pick := want
	if levels[want].done < levels[want].tiles.size():
		var best := -1
		var best_d := 99
		for i in levels.size():
			if levels[i].done >= levels[i].tiles.size() and absi(i - want) < best_d:
				best = i
				best_d = absi(i - want)
		if best >= 0:
			pick = best
	if pick != _shown:
		_shown = pick
		for i in levels.size():
			(levels[i] as Level).container.visible = i == pick

func frame(xf: Transform2D, zoom: float, vp: Vector2) -> void:
	_zoom = zoom
	_centre = xf.affine_inverse() * (vp * 0.5)
	fill.set_zoom(zoom)
	_choose()
	_bake.resort()

func tick() -> void:
	if _bake == null:
		return
	_bake.tick()
	if _wash_task >= 0 and WorkerThreadPool.is_task_completed(_wash_task):
		WorkerThreadPool.wait_for_task_completion(_wash_task)
		_wash_task = -1
		_wash_mat.set_shader_parameter("mask", ImageTexture.create_from_image(_wash_img))
		_wash_img = null
		_wash_done = true
	if _dirty:
		_dirty = false
		_choose()
	if _bake.pending() == 0 and not _released:
		# the twins' terrains (their chunk caches) are not needed again: freed one a frame, so no frame pays for all
		if _bake.twins.is_empty():
			_released = true
		else:
			_bake.twins.pop_back()

func is_ready() -> bool:
	return (_bake == null or _bake.pending() == 0) and _wash_done

func pending() -> int:
	return (0 if _bake == null else _bake.pending()) + (0 if _wash_done else 1)

# Records one tile synchronously on the main thread with a throwaway twin (the test's way of proving the recorder runs headless):
# the recorded canvas's op count.
func record_tile_now(level: int, index: int) -> int:
	var lv: Level = levels[level]
	var twin := _make_twin()
	var cv := Contours.record(twin, (lv.tiles[index] as Bake.Job).rect, lv.s, _with_water)
	var n := cv.op_count()
	cv.discard()
	return n

func stats() -> Dictionary:
	var out := {"tiles": 0, "tiles_done": 0, "texture_bytes": _textures_bytes, "levels": levels.size(), "shown_level": _shown, "wash": _wash_node != null}
	for lv: Level in levels:
		out.tiles = int(out.tiles) + lv.tiles.size()
		out.tiles_done = int(out.tiles_done) + lv.done
	if _bake != null:
		out["record_ms"] = _bake.stats.record_ms
		out["failed"] = _bake.failed
		out["bake_frame_ms_max"] = _bake.stats.max_frame_ms
		out["bake_begin_ms_max"] = _bake.stats.max_begin_ms
		out["bake_collect_ms_max"] = _bake.stats.max_collect_ms
		out["bake_done_ms_max"] = _bake.stats.max_done_ms
	return out

func dispose() -> void:
	shutdown()

func shutdown() -> void:
	if _wash_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_wash_task)
		_wash_task = -1
	if _bake != null:
		_bake.shutdown()
