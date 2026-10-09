extends "res://scripts/test_support/test_case.gd"

# Track F's fog of war, headless -- the vision rule, the query and the mask's
# geometry; no pixels (fog_shot.gd is the windowed look, and it reads the GPU
# mask back against the same CPU formula this test holds it to).
#
#   DATA     data/view/fog.json parses and every field in it is read by
#            FogVision + FogTopo + FogLayer (unused() is empty); every colour
#            is a role that resolves; the fog scripts hold no colour literal.
#   RADIUS   one circle per revealing unit, radius = its type's sight_range_m
#            (read here from data/units/<type>.json directly) x the scale knob;
#            "player_sides" reveals an AI unit on the players' side,
#            "player_controlled" does not; the enemy never reveals.
#   EDGE     is_visible is true ON the circle and inside, false just outside;
#            shows_unit hides an enemy outside vision, never a friend.
#   MASK     the CPU twin of fog_mask.gdshader, through random camera
#            transforms, is >= 0.5 exactly on the union of the circles at a
#            sample of points (random, on both sides of every edge, and next
#            to where two edges cross -- where an additive union would bulge),
#            1 deeper than range inside and 0 farther than range outside.
#   LAYER    a FogLayer under a CameraController in a 1280 x 720 SubViewport
#            hands the mask shader the circles where the camera puts them
#            (CameraController.world_to_screen x mask scale).
#   TOPO     the level of detail for a zoom is never magnified past 1 /
#            lod_ratio; a chunk records (GDScript timing printed); the sheet
#            gets lighter level by level.
#   SIGHT    with line of sight on (test_viewshed owns the rule itself) the
#            layer draws a unit's viewshed as a shape: one shape per unit, its
#            texture and eye handed to the shape shader, the mask pixel -> metres
#            map agreeing with the camera, the circle pass taken over by the
#            three-pass one and handed back when the rule is switched off.

const Terrain = preload("res://scripts/world/terrain.gd")
const World = preload("res://scripts/sim/world.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")
const CameraController = preload("res://scripts/world/camera_controller.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const FogViewshed = preload("res://scripts/render/fog_viewshed.gd")
const FogTopo = preload("res://scripts/render/fog_topo.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const SEED := 20261009
const FOG_SCRIPTS := ["res://scripts/render/fog_vision.gd", "res://scripts/render/fog_topo.gd",
	"res://scripts/render/fog_layer.gd", "res://scripts/render/fog_style.gd",
	"res://scripts/render/fog_mask.gdshader", "res://scripts/render/fog_composite.gdshader",
	"res://scripts/world/camera_controller.gd", "res://scripts/render/fog_shot.gd",
	"res://scripts/render/fog_viewshed.gd", "res://scripts/render/fog_viewshed_sites.gd",
	"res://scripts/render/fog_los_shape.gdshader", "res://scripts/render/fog_los_cols.gdshader",
	"res://scripts/render/fog_mask_los.gdshader", "res://scripts/render/fog_los_shot.gd"]

var _terrain: Terrain
var _vp: SubViewport
var _cam: Node
var _layer: FogLayer
var _frames := 0

func setup(_main) -> void:
	timeout_seconds = 120.0
	_terrain = Terrain.new(SEED)
	if not check(_terrain.ok(), "terrain loads: %s" % [_terrain.errors]):
		finish()
		return
	_data()
	_radius()
	_edge()
	_mask()
	_topo()
	_layer_setup()   # finishes in _physics_process, after the camera has drawn

# --- data ---------------------------------------------------------------------------

func _data() -> void:
	var d := CameraData.new(CameraData.FOG_PATH)
	check(d.ok(), "fog.json parses: %s" % [d.errors])
	var layer := FogLayer.new()
	layer.setup(_terrain, null, d)
	check(layer.ok(), "the fog layer, its vision and its topographic layer load cleanly: %s %s %s" % [layer.errors, layer.vision.errors, layer.topo.errors])
	var unused := d.unused()
	check(unused.is_empty(), "every field of fog.json is read; unused: %s" % [unused])
	print("[fog] fog.json: %d fields read, %d unused" % [d._used.size(), unused.size()])
	layer.free()
	# Rule 6: no colour literal in the fog's draw code -- colours are roles in data.
	var hex := RegEx.create_from_string("#[0-9A-Fa-f]{6}\\b|Color\\(\\s*[0-9.]|Color8\\(|vec[34]\\(\\s*0\\.[0-9]+\\s*,\\s*0\\.[0-9]+\\s*,\\s*0\\.[0-9]+")
	for path: String in FOG_SCRIPTS:
		var src := FileAccess.get_file_as_string(path)
		var m := hex.search(src)
		check(m == null, "%s holds no colour literal (found '%s')" % [path, m.get_string() if m != null else ""])

# --- the radius per unit -----------------------------------------------------------------

func _world() -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "lf", "type": "light_fighter", "side": "allies", "controller": "player", "x": 2000.0, "y": 2000.0, "heading": 0.0})
	w.add_unit({"id": "hf", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 3000.0, "y": 2600.0, "heading": 0.0})
	w.add_unit({"id": "bw", "type": "bomber", "side": "allies", "controller": "ai", "x": 1200.0, "y": 3300.0, "heading": 0.0})
	w.add_unit({"id": "en", "type": "light_fighter", "side": "axis", "controller": "ai", "x": 4800.0, "y": 600.0, "heading": 3.1})
	return w

static func _sight_from_file(type_id: String) -> float:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/%s.json" % type_id))
	return float(parsed["sight_range_m"]["value"])

func _radius() -> void:
	var w := _world()
	check(w.ok() and w.units.size() == 4, "the test world has its four units: %s" % w.last_error)
	var v := FogVision.new()
	v.update_from_world(w)
	var by_id := {}
	for c: Dictionary in v.circles:
		by_id[c.id] = c
	eq(by_id.keys().size(), 3, "player_sides: the three allied units reveal, the AI bomber on the allied side included")
	check(not by_id.has("en"), "the enemy does not reveal")
	for id: String in ["lf", "hf", "bw"]:
		if not check(by_id.has(id), "%s reveals" % id):
			continue
		var u: Object = w.units[id]
		near(by_id[id].r, _sight_from_file(u.type) * v.sight_scale, 1e-9, "%s's radius is its type's sight_range_m x vision.sight_range_scale" % id)
		near(by_id[id].x, u.x, 0.0, "%s's circle is centred on it (x)" % id)
		near(by_id[id].y, u.y, 0.0, "%s's circle is centred on it (y)" % id)
	print("[fog] radii (m): %s" % [v.circles.map(func(c: Dictionary) -> String: return "%s %.0f" % [c.id, c.r])])

	# "player_controlled": only the units players give orders to.
	var d := CameraData.new(CameraData.FOG_PATH)
	d.root["vision"]["reveal"]["value"] = "player_controlled"
	d.root["vision"]["sight_range_scale"]["value"] = 0.5
	var v2 := FogVision.new(d)
	check(v2.ok(), "vision loads with reveal = player_controlled")
	v2.update_from_world(w)
	eq(v2.circles.size(), 2, "player_controlled: the two player units reveal, the AI bomber does not")
	for c: Dictionary in v2.circles:
		near(c.r, _sight_from_file(w.units[c.id].type) * 0.5, 1e-9, "the scale knob scales %s's radius" % c.id)

	# During the resolve animation the circles follow World.sample.
	w.plan_step("lf", 0, Vector2(2300.0, 1900.0))
	var v3 := FogVision.new()
	v3.update_from_world(w, 1.0, "plan")
	var s: Dictionary = w.sample("lf", 1.0, "plan")
	for c: Dictionary in v3.circles:
		if c.id == "lf":
			near(c.x, float(s["x"]), 1e-9, "t >= 0: the circle sits where World.sample puts the unit (x)")
			near(c.y, float(s["y"]), 1e-9, "t >= 0: the circle sits where World.sample puts the unit (y)")

# --- the query at the edge -------------------------------------------------------------------

func _edge() -> void:
	var v := FogVision.new()
	v.set_circles([{"id": "a", "x": 2000.0, "y": 2000.0, "r": 1500.0}])
	check(v.is_visible_xy(3500.0, 2000.0), "exactly on the circle is visible (east)")
	check(v.is_visible_xy(2000.0, 500.0), "exactly on the circle is visible (north)")
	check(v.is_visible(Vector2(3500.0, 2000.0)), "is_visible(Vector2) on the circle")
	check(not v.is_visible_xy(3500.000001, 2000.0), "a micrometre outside is not visible")
	check(not v.is_visible(Vector2(3501.0, 2000.0)), "a metre outside is not visible")
	check(v.is_visible_xy(3499.999999, 2000.0), "a micrometre inside is visible")
	var a := 0.7
	check(v.is_visible_xy(2000.0 + cos(a) * 1499.999, 2000.0 + sin(a) * 1499.999), "just inside on a diagonal")
	check(not v.is_visible_xy(2000.0 + cos(a) * 1500.001, 2000.0 + sin(a) * 1500.001), "just outside on a diagonal")
	near(v.signed_distance_m(2500.0, 2000.0), 1000.0, 1e-9, "signed distance inside is r - d")
	near(v.signed_distance_m(4000.0, 2000.0), -500.0, 1e-9, "signed distance outside is negative")
	check(not FogVision.new().is_visible_xy(0.0, 0.0), "no revealing unit: nothing is visible")

	# Hiding enemy markers.
	var w := _world()
	var v2 := FogVision.new()
	v2.update_from_world(w)
	check(not v2.shows_unit(w, "en"), "an enemy far outside every circle is hidden")
	check(v2.shows_unit(w, "en", Vector2(2100.0, 2100.0)), "the same enemy inside a circle is shown")
	check(v2.shows_unit(w, "hf", Vector2(-9000.0, -9000.0)), "a friendly unit is always shown")
	check(not v2.shows_unit(w, "nobody"), "an unknown unit is not shown")
	# Track U's hook: a Callable taking a unit id.
	var hook: Callable = v2.unit_visible(w)
	check(hook.call("lf") and not hook.call("en"), "unit_visible(world) is U's id -> bool hook: friend shown, distant enemy hidden")
	w.units["en"].x = 2100.0
	w.units["en"].y = 2100.0
	check(hook.call("en"), "the hook reads live: the enemy moved inside a circle is shown")
	# During the resolve animation the enemy is judged where World.sample puts it.
	var w2 := _world()
	w2.plan_step("en", 0, Vector2(4700.0, 700.0))
	var v3 := FogVision.new()
	v3.update_from_world(w2, 0.5, "plan")
	var s: Dictionary = w2.sample("en", 0.5, "plan")
	eq(v3.shows_unit(w2, "en"), v3.is_visible_xy(float(s["x"]), float(s["y"])), "with a sample time, shows_unit judges the enemy at World.sample(t)")

# --- the mask covers the union --------------------------------------------------------------

func _mask() -> void:
	var d := CameraData.new(CameraData.FOG_PATH)
	var v := FogVision.new(d)
	var range_px := d.num("mask.range_px")
	var mscale := d.num("mask.scale")
	var ppm := _terrain.px_per_m
	# Three circles: two crossing, one apart; radii from the unit files.
	var r := _sight_from_file("light_fighter")
	v.set_circles([{"x": 2000.0, "y": 2500.0, "r": r}, {"x": 2000.0 + 1.6 * r, "y": 2700.0, "r": r * 0.8},
		{"x": 4600.0, "y": 600.0, "r": r * 0.3}])
	var rng := Mulberry32.new(SEED)
	var checked := 0
	var skipped := 0
	var wrong := 0
	var saturation_bad := 0
	for trial in 24:
		var z := exp(lerpf(log(0.03), log(2.0), rng.next()))
		var centre := Vector2(rng.next() * 5000.0, rng.next() * 5000.0) * ppm
		var xf := Transform2D(Vector2(z, 0.0), Vector2(0.0, z), -centre * z + Vector2(640.0, 360.0))
		var mc := v.mask_circles(ppm, xf, mscale)
		var inv := xf.affine_inverse()
		var range_mask := range_px * mscale
		var pts: Array[Vector2] = []
		for i in 120:
			pts.append(Vector2(rng.next() * 1280.0, rng.next() * 720.0))
		# both sides of every circle's edge, as seen on this screen
		for c: Dictionary in v.circles:
			var sc := xf * (Vector2(c.x, c.y) * ppm)
			var sr: float = c.r * ppm * z
			for i in 24:
				var a := rng.next() * TAU
				for off: float in [-3.0, -0.6, 0.6, 3.0, range_px + 2.0, -range_px - 2.0]:
					pts.append(sc + Vector2(cos(a), sin(a)) * (sr + off))
		# just outside both crossing circles, at their crossing (an additive or
		# alpha union would call these seen)
		var c0: Dictionary = v.circles[0]
		var c1: Dictionary = v.circles[1]
		var ip := _crossing(Vector2(c0.x, c0.y), c0.r, Vector2(c1.x, c1.y), c1.r)
		for p_m: Vector2 in ip:
			var away := (p_m - (Vector2(c0.x, c0.y) + Vector2(c1.x, c1.y)) * 0.5).normalized()
			for k in [0.5, 1.5, 4.0, 12.0]:
				pts.append(xf * ((p_m + away * k / ppm / z) * ppm))
		for p: Vector2 in pts:
			var w_m := (inv * p) / ppm
			var sd_m := v.signed_distance_m(w_m.x, w_m.y)
			var sd_px := sd_m * ppm * z
			if absf(sd_px) < 0.05:
				skipped += 1   # on the edge to within float error: either answer is right
				continue
			var m := FogVision.mask_value(mc, p * mscale, range_mask)
			checked += 1
			if (m >= 0.5) != v.is_visible_xy(w_m.x, w_m.y):
				wrong += 1
				if wrong <= 5:
					fail("mask %.4f vs is_visible %s at screen %s, %.3f px from the edge, zoom %.3f" % [m, v.is_visible_xy(w_m.x, w_m.y), p, sd_px, z])
			if sd_px > range_px + 0.5 and m != 1.0:
				saturation_bad += 1
			if sd_px < -range_px - 0.5 and m != 0.0:
				saturation_bad += 1
	eq(wrong, 0, "the mask's 0.5 level is exactly the union of the circles at %d sample points" % checked)
	eq(saturation_bad, 0, "the mask is 1 deeper than range_px inside and 0 farther than range_px outside")
	print("[fog] mask vs union: %d points checked over 24 camera transforms, %d within 0.05 px of an edge skipped, %d wrong" % [checked, skipped, wrong])

	# The cap on circles.
	var many := []
	for i in 80:
		many.append({"x": float(i) * 10.0, "y": 0.0, "r": 5.0})
	v.set_circles(many)
	eq(v.mask_circles(ppm, Transform2D.IDENTITY, 0.5).size(), v.max_circles, "at most mask.max_circles go to the shader")

static func _crossing(a: Vector2, ra: float, b: Vector2, rb: float) -> Array[Vector2]:
	var d := a.distance_to(b)
	var x := (d * d + ra * ra - rb * rb) / (2.0 * d)
	var h := sqrt(maxf(ra * ra - x * x, 0.0))
	var u := (b - a) / d
	var base := a + u * x
	var n := Vector2(-u.y, u.x)
	return [base + n * h, base - n * h]

# --- the topographic layer ----------------------------------------------------------------------

func _topo() -> void:
	var topo := FogTopo.new(_terrain)
	check(topo.ok(), "the topographic layer loads: %s" % [topo.errors])
	for i in range(1, topo.lods.size()):
		check(topo.lods[i] < topo.lods[i - 1], "levels of detail run finest first")
	for z: float in [3.0, 2.0, 1.0, 0.7, 0.5, 0.3, 0.2, 0.1, 0.05, 0.03, 0.01]:
		var lod := topo.lod_for_zoom(z)
		var s: float = topo.lods[lod]
		if lod < topo.lods.size() - 1:
			check(topo.lods[lod + 1] < topo.lod_ratio * z, "zoom %.2f: no coarser level would do (lod %d)" % [z, lod])
		if lod > 0 or s >= topo.lod_ratio * z:
			check(s >= topo.lod_ratio * z or lod == 0, "zoom %.2f: lod %d is magnified at most 1/lod_ratio" % [z, lod])
	for k in range(1, topo.paper_levels.size()):
		check(topo.paper_levels[k].get_luminance() > topo.paper_levels[k - 1].get_luminance(),
			"the map sheet gets lighter with each height level (%d)" % k)
	var sheet: Color = topo.paper_levels[0]
	check(absf(sheet.h - _terrain_paper().h) < 0.05, "the map sheet keeps the paper's hue (%.3f vs %.3f)" % [sheet.h, _terrain_paper().h])
	check(sheet.s < _terrain_paper().s, "the map sheet is less saturated than the paper")
	# Record a chunk with both levels in it, at each level of detail (GDScript only).
	var c := _chunk_with_levels()
	for lod in topo.lods.size():
		var t0 := Time.get_ticks_usec()
		var g := topo.make_canvas(c, topo.lods[lod])
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		eq(g.size, topo.canvas_size(topo.lods[lod]), "lod %d canvas is chunk_px x texels per px" % lod)
		check(g.op_count() > 0, "lod %d chunk %s records paint calls" % [lod, c])
		print("[fog] topo chunk %s lod %d (%d px): recorded in %.1f ms, %d paint calls" % [c, lod, g.size.x, ms, g.op_count()])
		g.discard()

func _terrain_paper() -> Color:
	return FogStyle.base("paper", FogTopo.new(_terrain).P)

func _chunk_with_levels() -> Vector2i:
	var r := _terrain.map_chunk_range()
	var mid := r.position + r.size / 2
	for dd in 6:
		for cy in range(mid.y - dd, mid.y + dd + 1):
			for cx in range(mid.x - dd, mid.x + dd + 1):
				if not _terrain.chains_px(cx, cy, 0).is_empty():
					return Vector2i(cx, cy)
	return mid

# --- the layer under a camera --------------------------------------------------------------------

func _layer_setup() -> void:
	_vp = SubViewport.new()
	_vp.size = Vector2i(1280, 720)
	_vp.disable_3d = true
	add_child(_vp)
	var cam2d := Camera2D.new()
	_vp.add_child(cam2d)
	cam2d.make_current()
	_cam = CameraController.new()
	_cam.setup_from_terrain(_terrain)
	_cam.input_enabled = false
	_cam.bind(cam2d)
	_vp.add_child(_cam)
	_cam.set_view(Vector2(2600.0, 2500.0) * _terrain.px_per_m, 0.08)
	_layer = FogLayer.new()
	_layer.setup(_terrain)
	_layer.auto_bake = false
	_layer.controller = _cam
	_vp.add_child(_layer)
	var w := _world()
	_layer.vision.update_from_world(w)

func _physics_process(_delta: float) -> void:
	if _layer == null or is_finished():
		return
	_frames += 1
	if _frames == 3:
		_check_layer("at %s px/m" % _terrain.px_per_m)
		# px_per_m is a live knob (Alex: 1, 2, 3 or 4): change it under the
		# running layer and camera, which both watch the terrain.
		_ppm_before = _terrain.px_per_m
		_centre_m_before = _cam.center() / _ppm_before
		_zoom_before = _cam.zoom_level()
		_terrain.px_per_m = 4.0 if _ppm_before != 4.0 else 1.0
	elif _frames == 6:
		near(_layer.topo.ppm, _terrain.px_per_m, 0.0, "the fog layer rebuilt its topographic layer for the new px_per_m")
		near(_layer.topo.chunk_px, _terrain.chunk_m * _terrain.px_per_m, 1e-9, "its chunks are the new scale's size")
		near((_cam.center() / _terrain.px_per_m).distance_to(_centre_m_before), 0.0, 0.01, "the camera stays on the same point in metres")
		near(_cam.zoom_level(), _zoom_before, 1e-6, "and keeps its zoom (render detail is drawn in map px at any scale)")
		_check_layer("after px_per_m %s -> %s" % [_ppm_before, _terrain.px_per_m])
		_terrain.px_per_m = _ppm_before
	elif _frames == 8:
		_sight_start()
	elif _frames == 11:
		_sight_check()
	elif _frames == 14:
		_sight_off_check()
		finish()

# --- line of sight in the layer -------------------------------------------------------------------

func _sight_start() -> void:
	_cam.set_view(Vector2(2600.0, 2500.0) * _terrain.px_per_m, 0.3)
	_layer.vision.set_line_of_sight(FogVision.LOS_TERRAIN)
	_layer.vision.set_circles([{"id": "u1", "x": 2600.0, "y": 2500.0, "r": 800.0},
		{"id": "u2", "x": 3100.0, "y": 2300.0, "r": 650.0, "eye_agl": 120.0}, {"id": "u3", "x": 1500.0, "y": 3500.0, "r": 800.0}])
	# u3 is given no shed on purpose below: a circle with a shed is dropped from the circle list.
	_layer.vision.circles[2].erase("shed")

func _sight_check() -> void:
	eq(_layer.stats.los_shapes, 2, "line of sight: the layer draws a shape for each unit that has a viewshed")
	eq(_layer._los_items.size(), 2, "line of sight: one shape node per shed")
	check(not _layer._mask_rect.visible and _layer._final_rect.visible and _layer._cols_rect.visible, "line of sight: the three-pass mask replaces the circle pass")
	eq(_layer._final_mat.get_shader_parameter("count"), 1, "line of sight: only the unit without a viewshed goes to the circle loop")
	var k := roundf(float(_vp.size.x) * _layer.mask_scale) / float(_vp.size.x)
	for key: String in ["u1", "u2"]:
		var item: Dictionary = _layer._los_items[key]
		var mat: ShaderMaterial = item.mat
		var c: Dictionary = {}
		for cc: Dictionary in _layer.vision.circles:
			if cc.id == key:
				c = cc
		var shed = c.shed
		eq(mat.get_shader_parameter("rays"), shed.n, "%s: the shader gets the shed's ray count" % key)
		check((mat.get_shader_parameter("eye") as Vector2).is_equal_approx(shed.eye), "%s: and its eye" % key)
		near(mat.get_shader_parameter("range_m"), shed.range_m, 1e-9, "%s: and its range" % key)
		var tex: ImageTexture = item.tex
		eq(tex.get_width(), shed.n, "%s: the runs texture is a column per ray" % key)
		eq(tex.get_height(), FogViewshed.RUN_ROWS, "%s: and a row per pair of runs" % key)
		var rimg := tex.get_image()
		var r0: Vector2 = shed.run_of(0, 0)
		var texel := rimg.get_pixel(0, 0)
		near(texel.r, r0.x, 1e-3, "%s: ray 0's first run starts as the viewshed says" % key)
		near(texel.g, r0.y, 1e-3, "%s: and ends as it says" % key)
		# mask px -> metres is an affine map agreeing with the camera
		var ax: Vector2 = mat.get_shader_parameter("ax")
		var ay: Vector2 = mat.get_shader_parameter("ay")
		var base: Vector2 = mat.get_shader_parameter("base_m")
		var worst := 0.0
		for mp: Vector2 in [Vector2(0.5, 0.5), Vector2(320.5, 180.5), Vector2(600.5, 90.5), Vector2(100.5, 340.5)]:
			var got := ax * mp.x + ay * mp.y + base
			var want: Vector2 = _cam.screen_to_world(mp / k)
			worst = maxf(worst, got.distance_to(want))
		check(worst < 1e-3, "%s: mask pixels map to the metres the camera says they are (worst %.5f m)" % [key, worst])
	print("[fog] line of sight in the layer: %d shapes, %d uploads, %d us of CPU for the shapes' uniforms" % [_layer.stats.los_shapes, _layer.stats.los_uploads, _layer.stats.los_us])
	_layer.vision.set_line_of_sight(FogVision.LOS_NONE)

func _sight_off_check() -> void:
	eq(_layer.stats.los_shapes, 0, "line of sight off: no shapes")
	check(_layer._mask_rect.visible and not _layer._final_rect.visible, "line of sight off: the circle pass is back")
	eq(_layer._mask_mat.get_shader_parameter("count"), _layer.vision.circles.size(), "line of sight off: every circle goes to the circle loop again")

var _ppm_before := 0.0
var _centre_m_before := Vector2.ZERO
var _zoom_before := 0.0

func _check_layer(label: String) -> void:
	var vsize := Vector2(_vp.size)
	var k := roundf(vsize.x * _layer.mask_scale) / vsize.x
	var sent: PackedVector4Array = _layer._mask_mat.get_shader_parameter("circles")
	var count: int = _layer._mask_mat.get_shader_parameter("count")
	eq(count, _layer.vision.circles.size(), "the mask shader gets one circle per revealing unit")
	var ok_all := true
	for i in mini(count, sent.size()):
		var c: Dictionary = _layer.vision.circles[i]
		var want: Vector2 = _cam.world_to_screen(Vector2(c.x, c.y)) * k
		var got := Vector2(sent[i].x, sent[i].y)
		var want_r: float = c.r * _terrain.px_per_m * _cam.zoom_level() * k
		if got.distance_to(want) > 0.01 or absf(sent[i].z - want_r) > 0.01:
			ok_all = false
			fail("circle %d: mask %s r %.3f, the camera says %s r %.3f" % [i, got, sent[i].z, want, want_r])
	check(ok_all, "%s: the mask circles sit where the camera draws the units (CameraController.world_to_screen x mask scale)" % label)
	eq(_layer.mask_viewport().size, Vector2i(roundi(vsize.x * _layer.mask_scale), roundi(vsize.y * _layer.mask_scale)), "the mask is mask.scale of the screen")
	near(_layer.overview_amount(), _cam.overview_amount(), 0.0, "the layer takes the overview amount from the camera")
	print("[fog] mask uniforms %s: %d circles in %d us (CPU side, per frame)" % [label, count, _layer.stats.mask_us])

func is_finished() -> bool:
	return _finished
