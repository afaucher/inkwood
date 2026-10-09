extends SceneTree

# A look at LINE OF SIGHT (Track F; Alex 2026-10-09: "I would love to see what it
# looks like when something occludes the line of sight. Ex - a tank's view inside
# a valley"). WINDOWED ONLY -- under --headless the renderer is a dummy:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/render/fog_los_shot.gd -- [key=value ...]
#
# Writes tmp/fog_los/*.png (1280 x 720), each the real compositor (fog_layer.gd,
# its mask passes and composite shader, fog_topo.gd's baked chunks) under a
# CameraController-driven Camera2D, over a STAND-IN for Track V's MapView: the
# full render of the same spot made by Track T's terrain_shot.gd (a child process
# the first time, cached in tmp/fog_los/cache by seed, spot and zoom). The two
# sites are FOUND IN THE TERRAIN (fog_viewshed_sites.gd), not placed by hand:
#
#   the VALLEY        a low-ground point with higher ground 150-400 m away on most
#                     sides: a tank's view inside a valley
#   the PLATEAU EDGE  high ground a few tens of metres back from a cliff, with
#                     low ground stretching away below
#
#   los_a_baseline        the tank in the valley, circle only (line_of_sight none)
#   los_b_terrain         the same with terrain line of sight
#   los_c_terrain_trees   the same with every tree canopy blocking too
#   los_d_plane_low       a plane at the low band over the same spot (it sees over the cliffs)
#   los_d2_plane_low_trees  the same with the canopies blocking too (a forest seen from 120 m at a slant)
#   los_e_plateau_edge    a tank at the plateau edge looking down: DEAD GROUND under the cliff
#   los_f_closeup         the valley tank at play zoom: the sight edge against the cliffs
#
# Each carries two ENEMY markers to show what line of sight does to units: an
# enemy tank on a plateau (shown inside the circle, hidden when the cliffs hide
# it) and an enemy plane over hidden ground (seen from the valley all the same).
# MARKERS ARE MAGNIFIED to a constant screen size (a 6 m tank is 3 px at this
# zoom); their art is the unit sheet's, ported (scripts/ui/unit_marker_art.gd).
#
# Options: seed=<n> zoom=<z> sight=<m> rim=<m> ring=0|1 margin=<m> tag=<text> only=<name,...>
# (margin: how far from the map edge the valley may be, default 1700 m so a whole 3,200 m
# view stays on the map; tag: appended to the file names, for a comparison run.)
# Prints the sites, the viewshed cost of each shot, the mask read back against
# the viewshed's own query, and the GPU cost of the three mask passes.

const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const CameraController = preload("res://scripts/world/camera_controller.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const FogViewshed = preload("res://scripts/render/fog_viewshed.gd")
const FogSites = preload("res://scripts/render/fog_viewshed_sites.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

const SIZE := Vector2i(1280, 720)
const DEFAULT_ZOOM := 0.2          # 1280 x 720 px is 3,200 x 1,800 m at 2 px/m: a whole 800 m sight circle fits
const CLOSE_ZOOM := 0.7            # the close-up: 914 x 514 m, a tank 8 px long
const MARKER_PX := 46.0            # on-screen length of a unit marker, magnified (the close-up uses less)
const ALTITUDE_PATH := "res://data/sim/altitude.json"
const OUT_DIR := "res://tmp/fog_los"

# A unit marker: the unit sheet's art in an ink ring, at a constant screen size.
class Marker extends Node2D:
	var tex: Texture2D
	var tex_origin := Vector2.ZERO     # the unit's centre in texture px
	var tex_px := 1.0                  # the texture's longest side, px
	var zoom := 1.0                    # the camera's zoom
	var length_px := MARKER_PX         # its on-screen size
	var ink := Color.BLACK
	var heading := 0.0                 # radians, 0 = along +x
	var ring := true
	func _draw() -> void:
		var s := length_px / tex_px / zoom
		if ring:
			draw_arc(Vector2.ZERO, length_px * 0.62 / zoom, 0.0, TAU, 40, ink, 1.4 / zoom, true)
		draw_set_transform(Vector2.ZERO, heading + PI / 2.0, Vector2(s, s))   # art is nose up
		draw_texture(tex, -tex_origin)

# The sight range as a thin dotted ink ring, so a line-of-sight shape can be read against
# the circle it was cut from. Constant screen weight.
class RangeRing extends Node2D:
	var radius_px := 100.0     # map px
	var zoom := 1.0
	var ink := Color.BLACK
	func _draw() -> void:
		var n := 120
		for i in n:
			if i % 2 == 0:
				var a0 := float(i) / float(n) * TAU
				draw_arc(Vector2.ZERO, radius_px, a0, a0 + TAU / float(n) * 0.55, 3, ink, 1.0 / zoom, true)

# A 500 m scale bar at the lower left, in screen px.
class ScaleBar extends Control:
	var ink := Color.BLACK
	var plate := Color.WHITE
	var px_per_m := 2.0
	var zoom := 0.2
	var metres := 500.0
	func _draw() -> void:
		var len_px := metres * px_per_m * zoom
		var y := 692.0
		var x0 := 30.0
		draw_rect(Rect2(x0 - 14.0, y - 22.0, len_px + 88.0, 40.0), plate)
		draw_line(Vector2(x0, y), Vector2(x0 + len_px, y), ink, 2.0, true)
		for i in 6:
			var x := x0 + len_px * float(i) / 5.0
			draw_line(Vector2(x, y - 6.0), Vector2(x, y + 2.0), ink, 1.5, true)
		draw_string(ThemeDB.fallback_font, Vector2(x0 + len_px + 10.0, y + 5.0), "%d m" % int(metres), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, ink)

var terrain: Terrain
var P: RenderParams
var st: RefCounted
var vp: SubViewport
var cam: Camera2D
var ctl: CameraController
var fog: FogLayer
var backdrop: Sprite2D
var full: Sprite2D
var live: Node2D
var caption: Label
var caption_plate: ColorRect
var scale_bar: Control
var opts := {}
var out_dir := ""
var sight_m := 800.0
var zoom := DEFAULT_ZOOM
var low_band_m := 120.0
var marker_px := MARKER_PX

func _initialize() -> void:
	_main()

func _main() -> void:
	var code := await _run()
	quit(code)

func _run() -> int:
	if DisplayServer.get_name() == "headless":
		printerr("[fog-los-shot] needs a windowed run: under --headless nothing is drawn")
		return 1
	await process_frame
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	var seed_value := int(opts.get("seed", "20261009"))
	zoom = float(opts.get("zoom", str(DEFAULT_ZOOM)))
	sight_m = float(opts.get("sight", "800"))
	var only: PackedStringArray = str(opts.get("only", "")).split(",", false)
	out_dir = ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("cache"))

	P = RenderParams.new()
	terrain = Terrain.new(seed_value)
	if not terrain.ok():
		printerr("[fog-los-shot] terrain errors: ", terrain.errors)
		return 1
	st = UiStyle.shared()
	low_band_m = _band_height("low")
	var ppm := terrain.px_per_m

	var t0 := Time.get_ticks_msec()
	var valley := FogSites.find_valley(terrain, float(opts.get("margin", "1700")), 40.0, true)
	var edge := FogSites.find_plateau_edge(terrain)
	print("[fog-los-shot] seed %d, %s px/m, sight %.0f m, zoom %.2f (view %.0f x %.0f m); sites found in %d ms" % [
		seed_value, ppm, sight_m, zoom, SIZE.x / zoom / ppm, SIZE.y / zoom / ppm, Time.get_ticks_msec() - t0])
	print("[fog-los-shot] VALLEY at %s m: %s" % [valley.p, valley.note])
	print("[fog-los-shot] PLATEAU EDGE at %s m, looking along %.0f deg: %s" % [edge.p, rad_to_deg((edge.dir as Vector2).angle()), edge.note])

	_build_scene()
	if opts.has("rim"):
		fog.vision.rim_m = float(opts["rim"])
	var tank_agl := float(fog.vision.eye_heights["ground"])
	var vp_site: Vector2 = valley.p
	var ep_site: Vector2 = edge.p

	# Enemies, placed by what the cliffs hide: scan out from each site for the first
	# higher ground (a tank) and the first hidden point (a plane's ground) the viewshed
	# does not see, 250-700 m out.
	fog.vision.set_line_of_sight(FogVision.LOS_TERRAIN)
	var enemy_v := _hidden_spots(vp_site, tank_agl)
	var enemy_e := _hidden_spots(ep_site, tank_agl)
	print("[fog-los-shot] enemy tank on high ground at %s m and enemy plane over hidden ground at %s m (valley); %s / %s (edge)" % [
		enemy_v.tank, enemy_v.plane, enemy_e.tank, enemy_e.plane])

	var stand_valley := _stand_in(seed_value, vp_site, zoom)
	var stand_edge := _stand_in(seed_value, ep_site, zoom)
	var stand_close := _stand_in(seed_value, vp_site, CLOSE_ZOOM)
	if stand_valley == "" or stand_edge == "" or stand_close == "":
		return 1

	var shots := [
		{"name": "los_a_baseline", "site": vp_site, "los": FogVision.LOS_NONE, "unit": "tank", "enemy": enemy_v, "full": stand_valley,
			"caption": "Tank in a valley, eye %.1f m.  line_of_sight: none (a circle)" % tank_agl},
		{"name": "los_b_terrain", "site": vp_site, "los": FogVision.LOS_TERRAIN, "unit": "tank", "enemy": enemy_v, "full": stand_valley,
			"caption": "Tank in a valley, eye %.1f m.  line_of_sight: terrain" % tank_agl},
		{"name": "los_c_terrain_trees", "site": vp_site, "los": FogVision.LOS_TREES, "unit": "tank", "enemy": enemy_v, "full": stand_valley,
			"caption": "Tank in a valley, eye %.1f m.  line_of_sight: terrain_trees" % tank_agl},
		{"name": "los_d_plane_low", "site": vp_site, "los": FogVision.LOS_TERRAIN, "unit": "plane", "enemy": enemy_v, "full": stand_valley,
			"caption": "Plane over the same spot, low band (%.0f m).  line_of_sight: terrain" % low_band_m},
		{"name": "los_d2_plane_low_trees", "site": vp_site, "los": FogVision.LOS_TREES, "unit": "plane", "enemy": enemy_v, "full": stand_valley,
			"caption": "The same plane, trees blocking too.  line_of_sight: terrain_trees"},
		{"name": "los_e_plateau_edge", "site": ep_site, "los": FogVision.LOS_TERRAIN, "unit": "tank", "enemy": enemy_e, "full": stand_edge,
			"caption": "Tank on a plateau, %.0f m back from the cliff, eye %.1f m.  line_of_sight: terrain  (dead ground under the cliff)" % [edge.cliff_m, tank_agl]},
		{"name": "los_f_closeup", "site": vp_site, "los": FogVision.LOS_TERRAIN, "unit": "tank", "enemy": enemy_v, "full": stand_close,
			"zoom": CLOSE_ZOOM, "marker_px": 40.0, "caption": "Close up (play zoom).  line_of_sight: terrain"},
	]
	for s: Dictionary in shots:
		if not only.is_empty() and not only.has(s.name):
			continue
		var img: Image = await _shot(s)
		var path := out_dir.path_join(s.name + str(opts.get("tag", "")) + ".png")
		img.save_png(path)
		print("[fog-los-shot] saved ", path)
	await _frame_cost(vp_site, tank_agl)
	return 0

func _band_height(band_id: String) -> float:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(ALTITUDE_PATH))
	if parsed is Dictionary:
		for b: Variant in (parsed as Dictionary).get("bands", []):
			if b is Dictionary and (b as Dictionary).get("id") == band_id:
				var h: Variant = (b as Dictionary).get("height_m")
				return float((h as Dictionary).get("value", 0.0)) if h is Dictionary else float(h)
	push_error("fog_los_shot: no altitude band '%s' in %s" % [band_id, ALTITUDE_PATH])
	return 120.0

# --- the stand-in full render --------------------------------------------------------------

# Track T's terrain_shot at the site (a child process the first time), cached.
func _stand_in(seed_value: int, site: Vector2, z: float) -> String:
	var stem := "cache/full_%d_%s_%d_%d_%s" % [seed_value, terrain.px_per_m, roundi(site.x), roundi(site.y), z]
	var wide := out_dir.path_join(stem + "_wide.png")
	if FileAccess.file_exists(wide):
		return wide
	var t0 := Time.get_ticks_msec()
	print("[fog-los-shot] rendering the full-render stand-in at %s m with terrain_shot.gd (once; cached) ..." % site)
	var output: Array = []
	var args := ["--path", ProjectSettings.globalize_path("res://"), "--script", "res://scripts/render/terrain_shot.gd", "--",
		str(seed_value), "tmp/fog_los/" + stem + ".png", "x=%s" % site.x, "y=%s" % site.y, "zoom=%s" % z]
	var rc := OS.execute(OS.get_executable_path(), args, output, true)
	if rc != 0 or not FileAccess.file_exists(wide):
		printerr("[fog-los-shot] terrain_shot failed (%d): %s" % [rc, "".join(output)])
		return ""
	print("[fog-los-shot] stand-in rendered in %d ms" % (Time.get_ticks_msec() - t0))
	return wide

# --- the scene ---------------------------------------------------------------------------------

func _build_scene() -> void:
	vp = SubViewport.new()
	vp.size = SIZE
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	backdrop = Sprite2D.new()
	backdrop.centered = false
	var desk := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	desk.fill(FogStyle.resolve({"base": "paper", "toward": "ink", "t": 0.45}, P))
	backdrop.texture = ImageTexture.create_from_image(desk)
	var big := terrain.map_rect_px().grow(terrain.map_rect_px().size.x)
	backdrop.position = big.position
	backdrop.scale = big.size
	vp.add_child(backdrop)
	full = Sprite2D.new()
	full.centered = false
	full.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	vp.add_child(full)
	cam = Camera2D.new()
	vp.add_child(cam)
	cam.make_current()
	ctl = CameraController.new()
	ctl.setup_from_terrain(terrain)
	ctl.input_enabled = false
	ctl.bind(cam)
	vp.add_child(ctl)
	fog = FogLayer.new()
	fog.setup(terrain, P)
	fog.controller = ctl
	fog.auto_bake = false
	vp.add_child(fog)
	if not fog.ok():
		printerr("[fog-los-shot] fog errors: ", fog.errors)
	live = Node2D.new()
	vp.add_child(live)         # above the fog, as V's live layer would be
	var layer := CanvasLayer.new()
	vp.add_child(layer)
	caption_plate = ColorRect.new()
	caption_plate.color = FogStyle.resolve({"base": "paper", "alpha": 0.86}, P)
	caption_plate.position = Vector2(12, 12)
	layer.add_child(caption_plate)
	caption = Label.new()
	caption.position = Vector2(20, 16)
	caption.custom_minimum_size = Vector2(400, 0)
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.add_theme_color_override("font_color", P.INK)
	caption.add_theme_font_size_override("font_size", 16)
	layer.add_child(caption)
	var bar := ScaleBar.new()
	bar.ink = P.INK
	bar.plate = FogStyle.resolve({"base": "paper", "alpha": 0.86}, P)
	bar.px_per_m = terrain.px_per_m
	bar.zoom = zoom
	layer.add_child(bar)
	scale_bar = bar

# Where the cliffs hide things, found with the target rule itself: a spot on higher
# ground, 250-700 m out, where an enemy TANK is hidden from the viewer, and a spot on
# another bearing over ground that is hidden where an enemy PLANE at the low band is
# nevertheless seen.
func _hidden_spots(site: Vector2, eye_agl: float) -> Dictionary:
	fog.vision.set_circles([{"id": "probe", "x": site.x, "y": site.y, "r": sight_m, "eye_agl": eye_agl}])
	var shed: FogViewshed.Shed = fog.vision.circles[0].shed
	var tank_agl := float(fog.vision.eye_heights["ground"])
	var tank := Vector2.INF
	var plane := Vector2.INF
	var tank_bearing := -10.0
	for ring in [350.0, 450.0, 300.0, 550.0, 250.0, 650.0]:
		for a in 24:
			var ang := float(a) / 24.0 * TAU
			var p: Vector2 = site + Vector2.from_angle(ang) * ring
			if tank == Vector2.INF and terrain.level_at(p.x, p.y) >= 1 and terrain.level_at(p.x + 24.0, p.y) >= 1 and terrain.level_at(p.x, p.y + 24.0) >= 1 \
					and not fog.vision.target_visible(p.x, p.y, tank_agl):
				tank = p
				tank_bearing = ang
		if tank != Vector2.INF:
			break
	for ring in [500.0, 600.0, 400.0, 650.0]:
		for a in 24:
			var ang := float(a) / 24.0 * TAU
			if tank_bearing > -5.0 and absf(angle_difference(ang, tank_bearing)) < 1.6:
				continue
			var p: Vector2 = site + Vector2.from_angle(ang) * ring
			var plane_agl := maxf(low_band_m - fog.vision.ground_at(p.x, p.y), 0.0)
			if not shed.visible_ground(p.x, p.y) and terrain.level_at(p.x, p.y) >= 1 and fog.vision.target_visible(p.x, p.y, plane_agl):
				plane = p
				break
		if plane != Vector2.INF:
			break
	if tank == Vector2.INF:
		tank = site + Vector2(350.0, 0.0)
	if plane == Vector2.INF:
		plane = site + Vector2(-500.0, 0.0)
	return {"tank": tank, "plane": plane}

# A marker node for a unit silhouette in a side's accent.
func _marker(silhouette: String, side: String, at_m: Vector2, heading: float) -> Marker:
	var accent: Color = st.side_color(side)
	var art := UnitMarkerArt.art_for(st, silhouette, accent, 10.0)
	var m := Marker.new()
	m.ink = P.INK
	m.zoom = ctl.zoom_level()
	m.length_px = marker_px
	m.heading = heading
	m.position = at_m * terrain.px_per_m
	if art != null and art.texture != null:
		m.tex = art.texture
		m.tex_origin = art.origin
		m.tex_px = float(maxi(art.size_px.x, art.size_px.y))
	else:
		push_error("fog_los_shot: no art for %s" % silhouette)
	return m

func _shot(s: Dictionary) -> Image:
	var site: Vector2 = s.site
	var mode: String = s.los
	var tank_agl := float(fog.vision.eye_heights["ground"])
	fog.vision.set_line_of_sight(mode)
	var is_plane: bool = s.unit == "plane"
	var agl := tank_agl if not is_plane else maxf(low_band_m - fog.vision.ground_at(site.x, site.y), 0.0)
	fog.vision.set_circles([{"id": "unit", "x": site.x, "y": site.y, "r": sight_m, "eye_agl": agl}])
	var zz: float = s.get("zoom", zoom)
	marker_px = float(s.get("marker_px", MARKER_PX))
	ctl.set_view(site * terrain.px_per_m, zz)
	var z := ctl.zoom_level()
	var img := Image.load_from_file(s.full)
	full.texture = ImageTexture.create_from_image(img)
	full.position = site * terrain.px_per_m - Vector2(SIZE) * 0.5 / zz
	full.scale = Vector2.ONE / zz
	(scale_bar as ScaleBar).zoom = zz
	(scale_bar as ScaleBar).metres = 500.0 if zz < 0.4 else 100.0
	# Markers: the player's unit (side_a), and two enemies shown only where vision shows them.
	for c in live.get_children():
		c.queue_free()
	var enemy: Dictionary = s.enemy
	if str(opts.get("ring", "1")) != "0":
		var ring := RangeRing.new()
		ring.position = site * terrain.px_per_m
		ring.radius_px = sight_m * terrain.px_per_m
		ring.zoom = z
		ring.ink = Color(P.INK, 0.55)
		live.add_child(ring)
	var mine := _marker("light_fighter" if is_plane else "tank", "allies", site, -PI * 0.25)
	live.add_child(mine)
	var shown: Array[String] = []
	var hidden: Array[String] = []
	var et: Vector2 = enemy.tank
	var ep: Vector2 = enemy.plane
	var tank_seen: bool = fog.vision.target_visible(et.x, et.y, tank_agl)
	var plane_agl := maxf(low_band_m - fog.vision.ground_at(ep.x, ep.y), 0.0)
	var plane_seen: bool = fog.vision.target_visible(ep.x, ep.y, plane_agl)
	if tank_seen:
		live.add_child(_marker("tank", "axis", et, PI * 0.8))
		shown.append("enemy tank")
	else:
		hidden.append("enemy tank")
	if plane_seen:
		live.add_child(_marker("light_fighter", "axis", ep, PI * 1.2))
		shown.append("enemy plane")
	else:
		hidden.append("enemy plane")
	caption.text = s.caption
	caption.size = Vector2(400, 0)
	caption_plate.size = Vector2(424, maxf(caption.get_minimum_size().y, 22.0) + 10.0)
	scale_bar.queue_redraw()
	var lod := fog.topo.lod_for_zoom(z)
	var bake := fog.prebake(ctl.visible_rect_px().grow(fog.topo.chunk_px), lod)
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var out := vp.get_texture().get_image()
	var vision: FogVision = fog.vision
	var shed_ms: float = vision.stats.last_ms if mode != FogVision.LOS_NONE else 0.0
	var seen_pct := -1.0
	if not vision.circles.is_empty() and vision.circles[0].has("shed"):
		seen_pct = 100.0 * (vision.circles[0].shed as FogViewshed.Shed).area_m2() / (PI * sight_m * sight_m)
	print("[fog-los-shot] %s: %s, eye %.1f m, viewshed %.1f ms (sees %.0f%% of the circle), %d shapes, %d topo chunks baked; shown %s, hidden %s; mask vs viewshed: %s" % [
		s.name, mode, agl, shed_ms, seen_pct, fog.stats.los_shapes, bake.count, shown, hidden, _check_mask()])
	return out

# The mask read back against the viewshed's own query at a grid of pixels not within
# 3 mask px of an edge.
func _check_mask() -> String:
	var mimg := fog.mask_texture().get_image()
	var msize := Vector2(mimg.get_size())
	var k := msize.x / float(SIZE.x)
	var inv := fog.get_global_transform_with_canvas().affine_inverse()
	var range_mask := fog.range_px * k
	var near_edge_m := 3.0 / (2.0 * range_mask)
	var wrong := 0
	var judged := 0
	for j in 36:
		for i in 64:
			var px := Vector2((i + 0.5) / 64.0 * msize.x, (j + 0.5) / 36.0 * msize.y).floor() + Vector2(0.5, 0.5)
			var m := mimg.get_pixelv(Vector2i(px)).r
			if absf(m - 0.5) < near_edge_m:
				continue
			var w_m := (inv * (px / k)) / terrain.px_per_m
			judged += 1
			if (m > 0.5) != fog.vision.is_visible_xy(w_m.x, w_m.y):
				wrong += 1
	return "%d of %d pixels disagree" % [wrong, judged]

# The GPU cost of the three mask passes: the whole view with the fog on and with the
# mask viewport alone, one shape against none.
func _frame_cost(site: Vector2, tank_agl: float) -> void:
	var rid := vp.get_viewport_rid()
	var mrid := fog.mask_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	RenderingServer.viewport_set_measure_render_time(mrid, true)
	ctl.set_view(site * terrain.px_per_m, zoom)
	for mode: String in [FogVision.LOS_NONE, FogVision.LOS_TERRAIN]:
		fog.vision.set_line_of_sight(mode)
		fog.vision.set_circles([{"id": "unit", "x": site.x, "y": site.y, "r": sight_m, "eye_agl": tank_agl}])
		for i in 8:
			await process_frame
		var gpu := 0.0
		var mgpu := 0.0
		var cpu := 0.0
		var frames := 30
		for i in frames:
			await RenderingServer.frame_post_draw
			gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
			mgpu += RenderingServer.viewport_get_measured_render_time_gpu(mrid)
			cpu += (fog.stats.mask_us + fog.stats.draw_us) / 1000.0
		print("[fog-los-shot] frame cost, line of sight %s: view GPU %.3f ms, mask viewport GPU %.3f ms (all passes), fog CPU %.3f ms/frame (mask %d us of it for the shapes)" % [
			mode, gpu / frames, mgpu / frames, cpu / frames, fog.stats.los_us])
