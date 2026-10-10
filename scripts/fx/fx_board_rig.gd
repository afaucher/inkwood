extends RefCounted

# THE RIG the strike's boards share (Track X2): the real map under a camera, the effects layer over it, the planes and a
# standing tower drawn as the markers draw them, a frame grabbed to an Image. WINDOWED ONLY (under --headless nothing is
# drawn). The same map, sun and scale as the earlier effects boards (scripts/fx/fx_board.gd): the terrain provider at seed
# 20261009 and the sandbox's 2 px/m, planes at the sandbox's own drawn scale (a light fighter 36 px across at zoom 1, never
# under 14 px). Its owner (a SceneTree script) hands in itself so frames can be awaited.
#
#   var rig := FxBoardRig.new(tree)
#   await rig.setup()
#   rig.set_planes([...]) ; rig.set_towers([...])
#   var img: Image = await rig.grab(centre_m, zoom, crop_px, pre)      # the crop, native size

const MapView = preload("res://scripts/render/map_view.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const FxPlaneProxy = preload("res://scripts/fx/fx_plane_proxy.gd")
const FxStructProxy = preload("res://scripts/fx/fx_struct_proxy.gd")
const FxPass = preload("res://scripts/fx/fx_pass.gd")

const SIZE := Vector2i(1280, 720)
const SEED := 20261009
const PLANE_PX := 36.0
const PLANE_MIN_PX := 14.0

var tree: SceneTree
var fxs: FxStyle
var fxd: FxData
var ui_style: UiStyle
var vp: SubViewport
var view: MapView
var layer: CanvasLayer
var fx: FxLayer
var proxy: FxPlaneProxy
var towers: FxStructProxy
var failures := 0

func _init(t: SceneTree) -> void:
	tree = t

func frames(n: int) -> void:
	for _i in n:
		await tree.process_frame

func setup() -> void:
	fxs = FxStyle.shared() as FxStyle
	fxd = FxData.shared() as FxData
	ui_style = UiStyle.shared() as UiStyle
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	vp = SubViewport.new()
	vp.size = SIZE
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(vp)
	var P := RenderParams.new()
	view = MapView.new(SEED, Rect2(), 0.0, "terrain", P)
	view.input_enabled = false
	vp.add_child(view)
	layer = CanvasLayer.new()
	vp.add_child(layer)
	fx = FxLayer.new()
	layer.add_child(fx)
	fx.setup(view, SEED)
	towers = FxStructProxy.new()
	layer.add_child(towers)
	towers.setup(view, fxs)
	towers.variant = fx.field.tower_variant()
	proxy = FxPlaneProxy.new()
	layer.add_child(proxy)
	proxy.setup(view, ui_style, fxs)
	var above := Node2D.new()
	above.name = "AbovePlanes"
	layer.add_child(above)
	fx.mount(layer, above)   # ground, shadows and air below the planes; the flashes above them
	if not view.errors().is_empty():
		printerr("[fx-rig] map errors: ", view.errors())

func true_scale_at(zoom: float) -> float:
	var ppm_drawn := maxf(PLANE_PX * zoom, PLANE_MIN_PX) / 9.0
	return ppm_drawn / (view.px_per_m * zoom)

func camera(center: Vector2, zoom: float) -> void:
	view.set_zoom(zoom)
	view.look_at_m(center)
	var k := true_scale_at(zoom)
	fx.true_scale = k
	proxy.true_scale = k
	towers.true_scale = k

func wait_map(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await frames(2)
	while view.missing_in_view() > 0:
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[fx-rig] the view did not finish baking (%d missing)" % view.missing_in_view())
			failures += 1
			break
		await tree.process_frame
	await frames(3)

func set_planes(list: Array) -> void:
	var out: Array[Dictionary] = []
	for p in list:
		out.append(p)
	proxy.planes = out

func plane(pos: Vector2, heading: float, h: float, side: String = "side_a", type: String = "light_fighter") -> Dictionary:
	return {"pos": pos, "heading": heading, "h": h, "type": type, "side": side}

func set_towers(list: Array) -> void:
	var out: Array[Dictionary] = []
	for p in list:
		out.append(p)
	towers.towers = out

# One frame centred on `center` at `zoom`, cropped to `crop` round the middle of the viewport.
func grab(center: Vector2, zoom: float, crop: Vector2i, pre: Callable = Callable()) -> Image:
	camera(center, zoom)
	await wait_map()
	if pre.is_valid():
		pre.call()   # (the camera has moved: screen positions from the map view are true now)
	fx.queue_redraws()
	proxy.refresh()
	towers.refresh()
	await frames(2)
	fx.queue_redraws()
	proxy.refresh()
	towers.refresh()
	await frames(2)
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var c := Vector2i(SIZE.x / 2, SIZE.y / 2)
	return img.get_region(Rect2i(c - crop / 2, crop))

# A free-standing frame on plain paper (for specimens): returns an Image of `size` with `items` called on a CanvasLayer.
func specimen(size: Vector2i, items: Callable) -> Image:
	var svp := SubViewport.new()
	svp.size = size
	svp.disable_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	tree.root.add_child(svp)
	var bg := ColorRect.new()
	bg.color = fxs.palette["paper"]
	bg.size = Vector2(size)
	svp.add_child(bg)
	var cl := CanvasLayer.new()
	svp.add_child(cl)
	items.call(cl)
	await frames(4)
	await RenderingServer.frame_post_draw
	var img := svp.get_texture().get_image()
	svp.queue_free()
	return img

func write_json(path: String, d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("[fx-rig] could not write ", path)
		failures += 1
		return
	f.store_string(JSON.stringify(d, "  ", false) + "\n")
	f.close()
	print("[fx-rig] wrote ", path)
