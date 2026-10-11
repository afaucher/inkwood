extends RefCounted

# ONE BOARD FRAME OF THE GAME'S OWN MARKERS on the game's own paper (Track M2U, mission 2, 2026-10-11). WINDOWED ONLY.
# The mobile AA and military-complex boards (mobile_aa_board_shot.gd, military_complex_board_shot.gd) use it:
#
#   var f := M2Frame.new(tree, style)
#   var img: Image = await f.render(Vector2i(420, 160), 1.0, [
#       {"silhouette": "tank", "side": "axis", "at": Vector2(-40, 0), "heading": 0.0},
#       {"silhouette": "mobile_aa", "side": "axis", "at": Vector2(0, 0), "heading": 0.0, "cast_h": 2.9}], {"road": [Vector2(-80, 20), Vector2(80, 20)]})
#
# WHAT IS THE GAME'S: the ground is InkGround's (the paper tint, specks and dirt, the road with its ruts and pebbles, the
# grain over the frame at the data's strength); every unit is a real UnitMarker (scripts/ui/unit_marker.gd) with the baked art
# unit_marker_art.gd returns, its shadow in a CanvasGroup tinted once at the map's shadow strength, exactly the marker layer's
# build (unit_marker_layer.gd _build). The scale is the sandbox's rule (scripts/app/sandbox.gd _update_plane_scale): the map's
# px per metre x zoom for the map, and marker.true_scale = the wanted plane size over the smallest plane, never below the
# 14 px floor, so a unit is the size it is in the game at that zoom. A static unit (the tower, a battery) takes
# marker.static_scale on top, as the layer does (item "static_rule": true).
#
# An item is {silhouette, side ("allies" | "axis"), at (metres from the frame's centre), heading (radians, 0 = east, clockwise
# on screen), static_rule, cast_h (metres: the shadow offset the sun gives a thing that high; the marker layer's own rule, ui.json
# marker.cast_height_m behind marker.cast_shadow_on, when it is left out), plane_h (metres: a plane's height, its shadow by the layer's altitude rule)}, or an ART item {art: an Art, at, tint_shadow: true}: a baked art placed as
# is (the destroyed complex, which no marker draws).

const UnitMarker = preload("res://scripts/ui/unit_marker.gd")
const UnitMarkerLayer = preload("res://scripts/ui/unit_marker_layer.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const InkGround = preload("res://scripts/render/ink_ground.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Grain = preload("res://scripts/render/grain.gd")
const CameraController = preload("res://scripts/world/camera_controller.gd")

const SANDBOX_PATH := "res://data/scenarios/sandbox.json"
const LIGHT_FIGHTER_PATH := "res://data/units/light_fighter.json"

var tree: SceneTree
var style: UiStyle
var P: RenderParams
var map_ppm: float
var plane_px: float
var plane_min_px: float
var ref_m: float

func _init(t: SceneTree, st: RefCounted) -> void:
	tree = t
	style = st as UiStyle
	P = RenderParams.new()
	map_ppm = CameraController.terrain_px_per_m()
	var sb: Variant = JSON.parse_string(FileAccess.get_file_as_string(SANDBOX_PATH))
	var view: Dictionary = (sb as Dictionary)["view"]
	plane_px = float((view["plane_px"] as Dictionary)["value"])
	plane_min_px = float((view["plane_min_px"] as Dictionary)["value"])
	var lf: Variant = JSON.parse_string(FileAccess.get_file_as_string(LIGHT_FIGHTER_PATH))
	ref_m = float(((lf as Dictionary)["size_m"] as Dictionary)["value"])

# The sandbox's rule at `zoom`: marker.true_scale (the plane rule) and the screen px per metre of the map.
func rule(zoom: float) -> Dictionary:
	var base := plane_px / (ref_m * map_ppm)
	var floor_k := plane_min_px / (ref_m * map_ppm * zoom)
	return {"k": maxf(base, floor_k), "screen_ppm": map_ppm * zoom}

# The px per metre a marker of this kind is DRAWN at (what its art is baked for) at `zoom`.
func drawn_ppm(zoom: float, static_rule: bool = false) -> float:
	var r := rule(zoom)
	return float(r["screen_ppm"]) * float(r["k"]) * (style.num("marker.static_scale") if static_rule else 1.0)

# A road through the frame as the ground's samples ({x, y, nx, ny}, ground px, one per 2 px), from a polyline in metres.
func _road_pts(poly_m: Array, centre_px: Vector2) -> Array:
	var out: Array = []
	for i in range(1, poly_m.size()):
		var a: Vector2 = poly_m[i - 1] * map_ppm + centre_px
		var b: Vector2 = poly_m[i] * map_ppm + centre_px
		var d := b - a
		var n := maxi(1, int(d.length() / 2.0))
		var nrm := Vector2(-d.y, d.x).normalized()
		for k in n:
			var q := a + d * (float(k) / float(n))
			out.append({"x": q.x, "y": q.y, "nx": nrm.x, "ny": nrm.y})
	return out

func render(size: Vector2i, zoom: float, items: Array, opts: Dictionary = {}) -> Image:
	var r := rule(zoom)
	var k: float = r["k"]
	var screen_ppm: float = r["screen_ppm"]
	var saved_k := style.num("marker.true_scale")
	style.set_num("marker.true_scale", k)
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	var root := Node2D.new()
	vp.add_child(root)
	# the ground, in map px (world px), laid at the zoom's scale round the frame's centre
	var gsize := Vector2i(ceili(float(size.x) / zoom) + 4, ceili(float(size.y) / zoom) + 4)
	var road: Array = _road_pts(opts.get("road", []), Vector2(gsize) / 2.0)
	var ground: Texture2D = InkGround.build_ground(gsize, road, P, true)
	var gs := Sprite2D.new()
	gs.texture = ground
	gs.centered = true
	gs.position = Vector2(size) / 2.0
	gs.scale = Vector2.ONE * zoom
	root.add_child(gs)
	# the shadows, one group tinted once at the map's strength (unit_marker_layer.gd _build)
	var tint: Color = style.color("unit_shadow")
	var shadows := CanvasGroup.new()
	shadows.self_modulate = Color(1.0, 1.0, 1.0, tint.a)
	root.add_child(shadows)
	var planes := Node2D.new()
	root.add_child(planes)
	var centre := Vector2(size) / 2.0
	var markers: Array = []
	var n := 0
	for it: Dictionary in items:
		var pos: Vector2 = centre + (it["at"] as Vector2) * screen_ppm
		if it.has("art"):
			_art_item(planes, shadows, it["art"], pos, tint, bool(it.get("tint_shadow", true)))
			continue
		var m := UnitMarker.new()
		m.own = false
		var static_rule := bool(it.get("static_rule", false))
		if static_rule:
			m.base_scale = style.num("marker.static_scale")
			m.draw_scale = m.base_scale
		var sil := str(it["silhouette"])
		m.setup(style, "item%d" % n, sil, float(it.get("size_m", 6.0)), style.side_color(str(it.get("side", "axis"))), shadows)
		planes.add_child(m)
		var want := screen_ppm * k * (m.draw_scale)
		m.set_pose(pos, float(it.get("heading", 0.0)), screen_ppm, Vector2.ZERO)   # bakes the art (a ship's carries a cast height)
		# a surface unit's shadow: the marker layer's rule (UnitMarkerLayer.cast_height_m, ui.json marker.cast_height_m behind
		# marker.cast_shadow_on); an item's cast_h overrides it (0 shows the layer as it was)
		var cast_h := float(it["cast_h"]) if it.has("cast_h") else UnitMarkerLayer.cast_height_m(style, m)
		var off := style.shadow_dir() * cast_h * style.sun_len() * want
		if it.has("plane_h"):
			# a plane at this height above the ground: the layer's rule (unit_marker_layer.gd shadow_offset_px)
			off = style.plane_shadow_offset_m(float(it["plane_h"])) * k * screen_ppm
		m.set_pose(pos, float(it.get("heading", 0.0)), screen_ppm, off)
		markers.append(m)
		n += 1
	# the grain over the whole frame (the map's, at the data's strength), multiplied in
	var grain_tex := Grain.build_texture(size, 4242)
	var gmat := ShaderMaterial.new()
	gmat.shader = Grain.GRAIN_SHADER
	gmat.set_shader_parameter("strength", P.grain)
	var gr := Sprite2D.new()
	gr.texture = grain_tex
	gr.centered = false
	gr.material = gmat
	root.add_child(gr)
	tree.root.add_child(vp)
	for _i in 3:
		await tree.process_frame
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	await tree.process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	vp.queue_free()
	style.set_num("marker.true_scale", saved_k)
	return img

# A baked art placed as it is: the sprite, and its mask in the shadow group when it has one.
func _art_item(planes: Node2D, shadows: CanvasGroup, art: UnitMarkerArt.Art, pos: Vector2, tint: Color, with_shadow: bool) -> void:
	if art == null or art.texture == null:
		return
	var sp := Sprite2D.new()
	sp.texture = art.texture
	sp.centered = false
	sp.offset = -art.origin
	sp.position = pos
	planes.add_child(sp)
	if with_shadow and art.mask != null:
		var sh := Sprite2D.new()
		sh.texture = art.mask
		sh.centered = false
		sh.offset = -art.origin
		sh.position = pos
		sh.modulate = Color(tint.r, tint.g, tint.b, 1.0)
		shadows.add_child(sh)
