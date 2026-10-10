extends SceneTree

# THE VARIANT BOARDS FOR THE EFFECTS (Track X): variants/damage-smoke/ and
# variants/crash-explosion/. WINDOWED ONLY -- under --headless nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/fx/fx_board.gd -- what=smoke|crash|all|probe [out=variants] [options=A,B,C,D]
#
# Every frame is the REAL MAP (the terrain provider, seed 20261009, at the sandbox's
# 2 px/m) with the effect drawn by the FxLayer over it and the planes drawn as the unit
# markers draw them (same art, same shadow rule), at the sandbox's plane scale (a light
# fighter 36 px across at zoom 1, never under 14 px). Time is shown as a filmstrip.
# One seed, one sun, one map spot for every option; only the option changes.
#
# NOTHING IS CHOSEN HERE: board.json carries "chosen": null. Alex chooses; the choice is
# recorded in data/decisions/decisions.json.

const MapView = preload("res://scripts/render/map_view.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const InkGround = preload("res://scripts/render/ink_ground.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const FxPlaneProxy = preload("res://scripts/fx/fx_plane_proxy.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxBurst = preload("res://scripts/fx/fx_burst.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxSheet = preload("res://scripts/fx/fx_sheet.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

const SIZE := Vector2i(1280, 720)
const SEED := 20261009
const TURN_S := 5.0
const T0 := 100.0                   # game time of the event in the crash scenarios

# The sandbox's plane scale (data/scenarios/sandbox.json view.plane_px / plane_min_px).
const PLANE_PX := 36.0
const PLANE_MIN_PX := 14.0
const CRASH_CROP := Vector2i(380, 260)
const SMOKE_CROP := Vector2i(380, 260)

var opts: Dictionary = {}
var out_dir := ""
var fxs: FxStyle
var fxd: FxData
var ui_style: UiStyle
var vp: SubViewport
var view: MapView
var layer: CanvasLayer
var fx: FxLayer
var proxy: FxPlaneProxy
var _zoom := 1.0
var _failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[fx-board] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	out_dir = str(opts.get("out", "variants"))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _run() -> void:
	fxs = FxStyle.shared() as FxStyle
	fxd = FxData.shared() as FxData
	ui_style = UiStyle.shared() as UiStyle
	if not fxs.ok() or not ui_style.ok():
		printerr("[fx-board] style errors: ", fxs.errors, ui_style.errors)
		quit(1)
		return
	await _setup()
	var what := str(opts.get("what", "all"))
	if what == "probe":
		await _probe()
	if what == "probecrash":
		await _probe_crash()
	if what == "smoke" or what == "all":
		await _smoke_board()
	if what == "crash" or what == "all":
		await _crash_board()
	quit(1 if _failures > 0 else 0)

# --- Setup ---------------------------------------------------------------------------------------------

func _setup() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	vp = SubViewport.new()
	vp.size = SIZE
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	var P := RenderParams.new()
	view = MapView.new(SEED, Rect2(), 0.0, "terrain", P)
	view.input_enabled = false
	vp.add_child(view)
	layer = CanvasLayer.new()
	vp.add_child(layer)
	proxy = FxPlaneProxy.new()
	layer.add_child(proxy)
	proxy.setup(view, ui_style, fxs)
	fx = FxLayer.new()
	layer.add_child(fx)
	fx.setup(view, SEED)
	if not view.errors().is_empty():
		printerr("[fx-board] map errors: ", view.errors())
	print("[fx-board] map %s px/m, seed %d" % [view.px_per_m, SEED])

# The plane's drawn scale at a zoom (the sandbox's rule), as a multiple of the map's px per metre.
func true_scale_at(zoom: float) -> float:
	var ppm_drawn := maxf(PLANE_PX * zoom, PLANE_MIN_PX) / 9.0
	return ppm_drawn / (view.px_per_m * zoom)

func _camera(center: Vector2, zoom: float) -> void:
	_zoom = zoom
	view.set_zoom(zoom)
	view.look_at_m(center)
	var k := true_scale_at(zoom)
	fx.true_scale = k
	proxy.true_scale = k

func _wait_map(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while view.missing_in_view() > 0:
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[fx-board] the view did not finish baking (%d missing)" % view.missing_in_view())
			_failures += 1
			break
		await process_frame
	await _frames(3)

# One 1280x720 frame centred on `center` at `zoom`, cropped to `crop` round the centre.
func _grab(center: Vector2, zoom: float, crop: Vector2i) -> Image:
	_camera(center, zoom)
	await _wait_map()
	fx.queue_redraws()
	proxy.refresh()
	await _frames(2)
	fx.queue_redraws()
	proxy.refresh()
	await _frames(2)
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	var c := Vector2i(SIZE.x / 2, SIZE.y / 2)
	return img.get_region(Rect2i(c - crop / 2, crop))

# --- The scenarios ----------------------------------------------------------------------------------------------

# Damage smoke: a light fighter at 400 m, 100 m/s, a gentle left turn from the sandbox's start.
const SMOKE_START := Vector2(2850.0, 2470.0)
const SMOKE_SPEED := 100.0
const SMOKE_TURN := -6.0     # degrees per second (negative: to the left)
const SMOKE_H := 400.0

func smoke_pose(t: float) -> Dictionary:
	var w := deg_to_rad(SMOKE_TURN)
	var h0 := 0.0
	var h := h0 + w * t
	var x := SMOKE_START.x + SMOKE_SPEED / w * (sin(h) - sin(h0))
	var y := SMOKE_START.y + SMOKE_SPEED / w * (-cos(h) + cos(h0))
	return {"x": x, "y": y, "heading": h, "height_m": SMOKE_H}

func _pose_pos(p: Dictionary) -> Vector2:
	return Vector2(float(p["x"]), float(p["y"]))

# The stand-in for the sim's out-of-control flight (World.sample): a descending spiral over
# FALL_S seconds. The sim flies the real one; the board needs something shaped like it.
const FALL_S := 14.0
const FALL_START := Vector2(3200.0, 2580.0)
const FALL_RADIUS := 120.0
const FALL_TURN := 40.0      # degrees per second, clockwise
const FALL_DRIFT := Vector2(18.0, -4.0)
const FALL_H0 := 400.0

func fall_pose(t: float) -> Dictionary:
	var th := deg_to_rad(FALL_TURN) * t - PI * 0.5
	var c := FALL_START + FALL_DRIFT * t
	var pos := c + Vector2(cos(th), sin(th)) * FALL_RADIUS
	var h := FALL_H0 * maxf(0.0, 1.0 - pow(t / FALL_S, 1.5))
	return {"x": pos.x, "y": pos.y, "heading": th + PI * 0.5, "height_m": h}

const MID_POS := Vector2(3050.0, 2480.0)
const MID_HEADING := 0.12

# --- Frames ---------------------------------------------------------------------------------------------------------

func _set_planes(list: Array) -> void:
	var out: Array[Dictionary] = []
	for p in list:
		out.append(p)
	proxy.planes = out

func _plane(pos: Vector2, heading: float, h: float, side: String = "side_a") -> Dictionary:
	return {"pos": pos, "heading": heading, "h": h, "type": "light_fighter", "side": side}

# One damage-smoke frame: option, health, t seconds into the flight.
func _smoke_frame(health: float, t: float, zoom: float, mode: String) -> Image:
	fx.set_time(t)
	var p := smoke_pose(t)
	var pos := _pose_pos(p)
	var hd: float = p["heading"]
	var dirv := Vector2.from_angle(hd)
	var center: Vector2
	var planes: Array = []
	if mode == "follow":
		var back := minf(SMOKE_SPEED * t * 0.5, 55.0)
		center = pos - dirv * back
	else:
		center = _pose_pos(smoke_pose(2.5))
	if t <= 5.0 + 1e-6:
		planes.append(_plane(pos, hd, SMOKE_H))
		var side := Vector2(-dirv.y, dirv.x)
		var rp := smoke_pose(t)
		planes.append(_plane(_pose_pos(rp) + side * 85.0, float(rp["heading"]), SMOKE_H, "side_b"))
	else:
		# the plane has flown on; a healthy plane of the other side sits by the trail for scale
		var rp := smoke_pose(2.5)
		planes.append(_plane(_pose_pos(rp) + Vector2(-30.0, 95.0), float(rp["heading"]), SMOKE_H, "side_b"))
	_set_planes(planes)
	return await _grab(center, zoom, SMOKE_CROP)

func _smoke_option(name: String) -> Dictionary:
	fx.select(name, fxd.working_default("crash"))
	return fxd.smoke_option(name)

const SMOKE_COLS := [
	{"t": 0.1, "zoom": 1.0, "mode": "follow", "cap": "0.1 s"},
	{"t": 0.3, "zoom": 1.0, "mode": "follow", "cap": "0.3 s"},
	{"t": 1.0, "zoom": 1.0, "mode": "follow", "cap": "1 s"},
	{"t": 3.0, "zoom": 0.35, "mode": "mid", "cap": "3 s"},
	{"t": 5.0, "zoom": 0.35, "mode": "mid", "cap": "5 s (end of turn 1)"},
	{"t": 10.0, "zoom": 0.35, "mode": "mid", "cap": "one turn later (10 s)"},
	{"t": 20.0, "zoom": 0.35, "mode": "mid", "cap": "three turns later (20 s)"},
]

const SMOKE_ROWS := [
	{"health": 0.6667, "title": "one hit: 2 of 3 pips left (a thin trail)"},
	{"health": 0.3333, "title": "two hits: 1 of 3 pips left (a heavy trail)"},
]

func _smoke_board() -> void:
	var names: Array = str(opts.get("options", "A,B,C,D")).split(",")
	var data := {}
	var specimens := {}
	for name: String in names:
		_smoke_option(name)
		var o := fxd.smoke_option(name)
		var rows: Array = []
		for r in SMOKE_ROWS:
			fx.clear()
			fx.select(name, fxd.working_default("crash"))
			fx.emit_path("p1", func(t: float) -> Dictionary: return smoke_pose(t), 0.0, 20.0, float(r["health"]), 9.0)
			var imgs: Array = []
			for c in SMOKE_COLS:
				var img := await _smoke_frame(float(r["health"]), float(c["t"]), float(c["zoom"]), str(c["mode"]))
				imgs.append(img)
			print("[fx-board] smoke %s health %.2f: %d frames (%s)" % [name, r["health"], imgs.size(), str(fx.stats())])
			rows.append({"title": r["title"], "frames": imgs})
		# the "shadow or none" comparison: the same trail (option's own puffs) with and without the ground shadow
		fx.clear()
		fx.select(name, fxd.working_default("crash"))
		fx.emit_path("p1", func(t: float) -> Dictionary: return smoke_pose(t), 0.0, 20.0, 0.3333, 9.0)
		fx.show_shadows = true
		var with_sh := await _smoke_frame(0.3333, 2.0, 1.0, "follow")
		fx.show_shadows = false
		var without_sh := await _smoke_frame(0.3333, 2.0, 1.0, "follow")
		fx.show_shadows = true
		data[name] = {"rows": rows, "with": with_sh, "without": without_sh}
		specimens[name] = await _specimen_smoke(name)
	await _write_smoke_sheets(names, data, specimens)

# --- The sheets ---------------------------------------------------------------------------------------------------------

func _chips(sh: FxSheet, pos: Vector2) -> float:
	var items := [["paper", "paper"], ["object_fill", "object fill"], ["wall_fill", "wall fill"], ["ink", "ink"], ["dirt", "dirt"], ["shadow", "shadow tint"], ["side_a", "side A"], ["side_b", "side B"], ["fire", "FIRE (proposed)"]]
	var x := pos.x
	for it in items:
		var c: Color = fxs.palette[it[0]]
		sh.swatch(Vector2(x, pos.y), Vector2(58, 26), c)
		var l := FxStyle.to_oklch(c)
		sh.label(it[1], Vector2(x, pos.y + 29), 11, false, FxSheet.FG)
		sh.label("%.2f %.2f %d" % [l[0], l[1], roundi(l[2])], Vector2(x, pos.y + 43), 10, false, FxSheet.DIM)
		x += 74.0
	return pos.y + 60.0

func _write_smoke_sheets(names: Array, data: Dictionary, specimens: Dictionary) -> void:
	var dir := out_dir.path_join("damage-smoke")
	var cols := SMOKE_COLS.size()
	var cw := SMOKE_CROP.x
	var ch := SMOKE_CROP.y
	# per option sheets, full size
	var json_opts: Array = []
	var board_blocks: Array = []
	for name: String in names:
		var d: Dictionary = data[name]
		var w := cols * (cw + 8) + 40
		var h := 170 + 2 * (ch + 62) + 40 + ch + 90
		var sh := FxSheet.new(root, Vector2i(w, h))
		sh.label("Damage smoke, option %s: %s" % [name, fxd.option_label("smoke", name)], Vector2(16, 10), 22, true)
		sh.label(fxd.option_note("smoke", name), Vector2(16, 40), 13, false, FxSheet.DIM, w - 40.0)
		var y := 82.0
		sh.label("Beside a tree (38 px canopy) and a light fighter (36 px) at zoom 1.0, on the paper; the option's three tones, thin to heavy:", Vector2(16, y), 12, false, FxSheet.DIM)
		sh.image(specimens[name], Vector2(16, y + 18), 1.0)
		var by := _chips(sh, Vector2(16 + specimens[name].get_width() + 24, y + 22))
		y += 18 + specimens[name].get_height() + 22
		for r in d["rows"]:
			sh.label(str(r["title"]), Vector2(16, y), 14, true)
			y += 22
			for k in cols:
				var img: Image = r["frames"][k]
				sh.image(img, Vector2(16 + k * (cw + 8), y), 1.0)
				sh.label("%s  (zoom %.2f)" % [SMOKE_COLS[k]["cap"], SMOKE_COLS[k]["zoom"]], Vector2(16 + k * (cw + 8), y + ch + 4), 12, false, FxSheet.DIM)
			y += ch + 30
		sh.label("The ground shadow, 1 pip left at 2 s, zoom 1.0: with it (left, 1% of altitude along the light) and without (right)", Vector2(16, y), 13, true)
		y += 22
		sh.image(d["with"], Vector2(16, y), 1.0)
		sh.image(d["without"], Vector2(16 + cw + 8, y), 1.0)
		var file := "option_%s.png" % name
		await sh.save(dir.path_join(file), self)
		sh.free_sheet()
		json_opts.append({"name": name, "label": fxd.option_label("smoke", name), "note": fxd.option_note("smoke", name), "file": file, "parameters": fxd.smoke_option(name)})
	# the overview board: every option, scaled
	var sc := 0.62
	var bw := int((cols * (cw + 8)) * sc) + 40
	var bh := 140
	for name: String in names:
		bh += int(76 + 2 * (ch * sc + 20) + 20 + specimens[name].get_height() * 0.62)
	var bd := FxSheet.new(root, Vector2i(bw, bh + 60))
	bd.label("Damage smoke: a damaged plane trails smoke that grows as its health falls  ·  seed %d, the real map" % SEED, Vector2(16, 10), 22, true)
	bd.label("Light fighter at 400 m, 100 m/s in a gentle left turn; time runs left to right from the first puff. The first three frames are at zoom 1.0 (the plane 36 px), the rest at zoom 0.35, the sandbox's planning view. The second plane is a healthy one of the other side, for scale. Sun from the NW, shadows 44%, the shadow of a puff 1% of its altitude along the light. ALL OPTIONS ARE PROPOSED; none is chosen.", Vector2(16, 42), 12, false, FxSheet.DIM, bw - 40.0)
	var y2 := _chips(bd, Vector2(16, 92)) + 8
	for name: String in names:
		bd.label("%s · %s" % [name, fxd.option_label("smoke", name)], Vector2(16, y2), 17, true)
		var nl := bd.label(fxd.option_note("smoke", name), Vector2(16, y2 + 24), 11, false, FxSheet.DIM, bw - 40.0)
		y2 += 30 + nl.size.y
		for r in data[name]["rows"]:
			bd.label(str(r["title"]), Vector2(16, y2), 12, true)
			y2 += 18
			for k in cols:
				var img: Image = r["frames"][k]
				var small := Image.create_from_data(img.get_width(), img.get_height(), false, img.get_format(), img.get_data())
				small.resize(int(cw * sc), int(ch * sc), Image.INTERPOLATE_LANCZOS)
				bd.image(small, Vector2(16 + k * (cw * sc + 8), y2), 1.0)
				bd.label(str(SMOKE_COLS[k]["cap"]), Vector2(16 + k * (cw * sc + 8), y2 + ch * sc + 2), 10, false, FxSheet.DIM)
			y2 += ch * sc + 20
		y2 += 14
	await bd.save(dir.path_join("board.png"), self)
	bd.free_sheet()
	_write_json(dir.path_join("board.json"), {
		"id": "damage-smoke",
		"date": "2026-10-09",
		"area": "Effects",
		"question": "How does a damaged plane's smoke look, and how does it grow as its health falls? (Alex: 'damage smoke and crash explosions'; particles in style, fast flashes with a very slow decay)",
		"source": "scripts/fx/fx_board.gd over the real map (terrain provider) at 2 px/m, planes at the sandbox's own scale (36 px at zoom 1)",
		"seed": SEED,
		"parameter": "data/fx/fx.json#smoke.options (every value a proposed record)",
		"held_constant": {
			"scene": "a light fighter, 9 m, 400 m up, 100 m/s, turning left 6 degrees per second from (2850, 2470) m; health 2/3 and 1/3",
			"light": "sun azimuth 315, elevation 46; shadow strength 0.44; shadow of a puff = 1% of its height above ground along the light (aircraft_shadow_altitude_scale 0.01)",
			"pen": "shadow side", "fire_accent": fxd.fire_oklch(), "wind_mps": "per option (data)",
		},
		"frames": SMOKE_COLS,
		"rows": SMOKE_ROWS,
		"options": json_opts,
		"sheet": "board.png (every option, scaled), option_<X>.png (each at full size, with the palette row, the specimen strip and the shadow with/without comparison)",
		"chosen": null,
		"chosen_by": null,
	})

func _write_json(path: String, d: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		printerr("[fx-board] could not write ", path)
		_failures += 1
		return
	f.store_string(JSON.stringify(d, "  ", false) + "\n")
	f.close()
	print("[fx-board] wrote ", path)

# --- The specimen strip: a tree, a plane and the option's puffs on paper -----------------------------------------------------

func _paper_texture(size: Vector2i) -> Texture2D:
	var P := RenderParams.new()
	P.L["road"] = false
	return InkGround.build_ground(size, [], P, true)

func _specimen_base(size: Vector2i, items: Callable) -> Image:
	var svp := SubViewport.new()
	svp.size = size
	svp.disable_3d = true
	svp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(svp)
	var paper := TextureRect.new()
	paper.texture = _paper_texture(size)
	paper.size = Vector2(size)
	svp.add_child(paper)
	var cl := CanvasLayer.new()
	svp.add_child(cl)
	items.call(cl)
	await _frames(4)
	await RenderingServer.frame_post_draw
	var img := svp.get_texture().get_image()
	svp.queue_free()
	return img

func _tree_sprite(at: Vector2, parent: Node, r: float) -> void:
	var P := RenderParams.new()
	var t := {"r": r, "seed": 4242}
	var g := InkSprites.build_tree_sprite(t, P)
	var img := g.finish_image()
	var sp := Sprite2D.new()
	sp.texture = FxBake.texture(img, false)
	sp.position = at
	parent.add_child(sp)

func _specimen_smoke(name: String) -> Image:
	var o := fxd.smoke_option(name)
	var z := 1.0
	var k := true_scale_at(z)
	var ppm := maxf(PLANE_PX * z, PLANE_MIN_PX) / 9.0
	var size := Vector2i(560, 120)
	return await _specimen_base(size, func(cl: CanvasLayer) -> void:
		_tree_sprite(Vector2(48, 60), cl, 19.0)
		_tree_sprite(Vector2(100, 70), cl, 14.0)
		# the plane, with its shadow at 400 m
		var xf := Transform2D(0.0, Vector2(view.px_per_m * z, view.px_per_m * z), 0.0, Vector2(-1120.0, -100.0) * 0.0)
		var pr := FxPlaneProxy.new()
		cl.add_child(pr)
		pr.setup(Transform2D(0.0, Vector2(view.px_per_m, view.px_per_m), 0.0, Vector2.ZERO), ui_style, fxs)
		pr.true_scale = k
		var pl: Array[Dictionary] = []
		pl.append(_plane(Vector2(190.0, 60.0) / view.px_per_m, -PI / 2.0, 400.0))
		pr.planes = pl
		pr.refresh()
		# the option's puffs, three tones, at the scale they are drawn at on the board (a 9 m plane)
		var ps := FxPuff.bake_set(fxs, o, ppm, 9.0)
		var x := 260.0
		for tone in FxPuff.TONES:
			if ps == null:
				break
			var sp := Sprite2D.new()
			sp.texture = (ps.tex[tone] as Array)[0]
			sp.centered = false
			sp.position = Vector2(x, 60.0) - ps.origin[tone] * 1.0
			cl.add_child(sp)
			x += ps.origin[tone].x * 2.0 + 40.0
	)

# --- The crash board ------------------------------------------------------------------------------------------------------------

const MID_COLS := [
	{"dt": -0.4, "zoom": 1.0, "cap": "just before"},
	{"dt": 0.0, "zoom": 1.0, "cap": "0 s"},
	{"dt": 0.1, "zoom": 1.0, "cap": "0.1 s"},
	{"dt": 0.3, "zoom": 1.0, "cap": "0.3 s"},
	{"dt": 1.0, "zoom": 1.0, "cap": "1 s"},
	{"dt": 3.0, "zoom": 1.0, "cap": "3 s"},
	{"dt": 5.0, "zoom": 0.35, "cap": "one turn later"},
	{"dt": 15.0, "zoom": 0.35, "cap": "three turns later"},
	{"dt": 40.0, "zoom": 0.35, "cap": "eight turns later"},
]
const FALL_COLS := [
	{"t": 0.5, "cap": "0.5 s"},
	{"t": 3.0, "cap": "3 s"},
	{"t": 6.0, "cap": "6 s (turn 2)"},
	{"t": 9.0, "cap": "9 s"},
	{"t": 12.0, "cap": "12 s (turn 3)"},
	{"t": 13.8, "cap": "13.8 s (a moment before)"},
]
const HIT_COLS := [
	{"dt": 0.0, "zoom": 1.0, "cap": "0 s"},
	{"dt": 0.1, "zoom": 1.0, "cap": "0.1 s"},
	{"dt": 0.3, "zoom": 1.0, "cap": "0.3 s"},
	{"dt": 1.0, "zoom": 1.0, "cap": "1 s"},
	{"dt": 3.0, "zoom": 1.0, "cap": "3 s"},
	{"dt": 5.0, "zoom": 1.0, "cap": "one turn later: the wreck smoking"},
	{"dt": 15.0, "zoom": 1.0, "cap": "three turns later: still smoking"},
	{"dt": 40.0, "zoom": 0.35, "cap": "eight turns later (wide)"},
	{"dt": 90.0, "zoom": 1.0, "cap": "eighteen turns later: what stays"},
]

func _fall_replay(crash: String, until: float) -> void:
	fx.clear()
	fx.select(fxd.working_default("smoke"), crash)
	var dt := 1.0 / 30.0
	var k := 0
	while float(k) * dt <= until + 1e-6:
		var t := float(k) * dt
		var p := fall_pose(t)
		fx.falling("p1", _pose_pos(p), float(p["height_m"]), t, 9.0, float(p["heading"]))
		k += 1

func _ref_plane(near: Vector2, heading: float) -> Dictionary:
	return _plane(near, heading, 400.0, "side_b")

func _mid_frame(c: Dictionary) -> Image:
	var dt: float = c["dt"]
	fx.set_time(T0 + dt)
	var planes: Array = [_ref_plane(MID_POS + Vector2(40.0, 105.0), MID_HEADING)]
	if dt < 0.0:
		planes.append(_plane(MID_POS + Vector2.from_angle(MID_HEADING) * 100.0 * dt, MID_HEADING, 400.0))
	_set_planes(planes)
	var centre := MID_POS + Vector2(8.0, 22.0) * clampf(dt / 40.0, 0.0, 1.0)
	if float(c["zoom"]) < 0.5:
		centre = MID_POS + Vector2(30.0, 40.0)
	return await _grab(centre, float(c["zoom"]), CRASH_CROP)

func _fall_frame(crash: String, t: float) -> Image:
	_fall_replay(crash, t)
	fx.set_time(t)
	var p := fall_pose(t)
	_set_planes([_plane(_pose_pos(p), float(p["heading"]), float(p["height_m"]))])
	return await _grab(_pose_pos(p), 0.8, CRASH_CROP)

func _hit_frame(crash: String, c: Dictionary) -> Image:
	_fall_replay(crash, FALL_S)
	var g := _pose_pos(fall_pose(FALL_S))
	fx.impact("p1", g, FALL_S, 9.0, float(fall_pose(FALL_S)["heading"]))
	var dt: float = c["dt"]
	fx.set_time(FALL_S + dt)
	_set_planes([_ref_plane(g + Vector2(-60.0, 120.0), 0.4)])
	var centre := g
	if float(c["zoom"]) < 0.5:
		centre = g + Vector2(40.0, 30.0)
	elif dt >= 4.0 and dt < 60.0:
		centre = g + Vector2(30.0, 12.0)   # the column drifts downwind of the wreck
	return await _grab(centre, float(c["zoom"]), CRASH_CROP)

func _crash_board() -> void:
	var names: Array = str(opts.get("options", "A,B,C,D")).split(",")
	var data := {}
	var specimens := {}
	for name: String in names:
		var mid: Array = []
		fx.clear()
		fx.select(fxd.working_default("smoke"), name)
		fx.explode_midair("p1", MID_POS, 400.0, T0, 9.0, MID_HEADING)
		for c in MID_COLS:
			mid.append(await _mid_frame(c))
		var fall: Array = []
		for c in FALL_COLS:
			fall.append(await _fall_frame(name, float(c["t"])))
		var hit: Array = []
		for c in HIT_COLS:
			hit.append(await _hit_frame(name, c))
		print("[fx-board] crash %s: %d + %d + %d frames (%s)" % [name, mid.size(), fall.size(), hit.size(), str(fx.stats())])
		data[name] = {"mid": mid, "fall": fall, "hit": hit}
		specimens[name] = await _specimen_crash(name)
	await _write_crash_sheets(names, data, specimens)

func _crash_rows(d: Dictionary) -> Array:
	var mid_caps: Array = []
	for c in MID_COLS:
		mid_caps.append("%s  (zoom %.2f)" % [c["cap"], c["zoom"]])
	var fall_caps: Array = []
	for c in FALL_COLS:
		fall_caps.append("%s  (zoom 0.80)" % c["cap"])
	var hit_caps: Array = []
	for c in HIT_COLS:
		hit_caps.append("%s  (zoom %.2f)" % [c["cap"], c["zoom"]])
	return [
		{"title": "a. The plane explodes in mid air (400 m): flash, burst at altitude, pieces falling, smoke left in the sky, its shadow on the ground", "short": "a. Explodes in mid air", "frames": d["mid"], "caps": mid_caps},
		{"title": "b. The plane is out of control: the sim flies a spiral down from 400 m over 14 s; heavy smoke, a flame, embers, the shadow gap closing", "short": "b. Out of control", "frames": d["fall"], "caps": fall_caps},
		{"title": "c. It hits the ground: an explosion, then a smoking wreck (Alex): flash, burst, a billow, a column over the wreck that thins over turns, the wreck and its scar that stay", "short": "c. Ground impact: an explosion, then a smoking wreck", "frames": d["hit"], "caps": hit_caps},
	]

func _write_crash_sheets(names: Array, data: Dictionary, specimens: Dictionary) -> void:
	var dir := out_dir.path_join("crash-explosion")
	var cw := CRASH_CROP.x
	var ch := CRASH_CROP.y
	var json_opts: Array = []
	var maxcols := MID_COLS.size()
	for name: String in names:
		var rows := _crash_rows(data[name])
		var w := maxcols * (cw + 8) + 40
		var h := 150 + 3 * (ch + 62) + 60
		var sh := FxSheet.new(root, Vector2i(w, h))
		sh.label("Crash and explosion, option %s: %s" % [name, fxd.option_label("crash", name)], Vector2(16, 10), 22, true)
		sh.label(fxd.option_note("crash", name), Vector2(16, 40), 13, false, FxSheet.DIM, w - 40.0)
		var y := 90.0
		sh.label("Beside a tree (38 px canopy) and a light fighter (36 px) at zoom 1.0, on the paper: the flash at 0.1 s, 0.5 s and 2.2 s, the flame, a piece of debris, the scar with its wreck, a heavy puff:", Vector2(16, y), 12, false, FxSheet.DIM)
		sh.image(specimens[name], Vector2(16, y + 18), 1.0)
		_chips(sh, Vector2(16 + specimens[name].get_width() + 24, y + 22))
		y += 18 + specimens[name].get_height() + 24
		for r in rows:
			sh.label(str(r["title"]), Vector2(16, y), 14, true)
			y += 22
			for k in r["frames"].size():
				sh.image(r["frames"][k], Vector2(16 + k * (cw + 8), y), 1.0)
				sh.label(str(r["caps"][k]), Vector2(16 + k * (cw + 8), y + ch + 4), 12, false, FxSheet.DIM)
			y += ch + 36
		await sh.save(dir.path_join("option_%s.png" % name), self)
		sh.free_sheet()
		json_opts.append({"name": name, "label": fxd.option_label("crash", name), "note": fxd.option_note("crash", name), "file": "option_%s.png" % name, "parameters": fxd.crash_option(name)})
	var sc := 0.56
	var bw := int(maxcols * (cw * sc + 8)) + 40
	var bh := 170
	for name: String in names:
		bh += int(70 + 3 * (ch * sc + 40) + 26)
	var bd := FxSheet.new(root, Vector2i(bw, bh))
	bd.label("Crash and explosion: a downed plane explodes in mid air, or flies out of control and crashes  ·  seed %d, the real map" % SEED, Vector2(16, 10), 22, true)
	bd.label("Three phases in one consistent treatment per option. Frames run left to right in time; zoom 1.0 puts the plane at 36 px, 0.35 is the sandbox's planning view. In (a) and (c) the second plane, of the other side, is a healthy reference for scale. In (b) the plane is flown by a stand-in for the sim's spiral descent (the sim flies the real one; the effects draw what rides on it). Sun from the NW, shadows 44%, the shadow of anything in the air 1% of its height along the light. FAST FLASHES WITH A VERY SLOW DECAY (Alex). ALL OPTIONS ARE PROPOSED; none is chosen.", Vector2(16, 42), 12, false, FxSheet.DIM, bw - 40.0)
	var y2 := _chips(bd, Vector2(16, 104)) + 14
	for name: String in names:
		bd.label("%s · %s" % [name, fxd.option_label("crash", name)], Vector2(16, y2), 17, true)
		var nl := bd.label(fxd.option_note("crash", name), Vector2(16, y2 + 24), 11, false, FxSheet.DIM, bw - 40.0)
		y2 += 30 + nl.size.y
		for r in _crash_rows(data[name]):
			bd.label(str(r["short"]), Vector2(16, y2), 12, true)
			y2 += 18
			for k in r["frames"].size():
				var img: Image = r["frames"][k]
				var small := Image.create_from_data(img.get_width(), img.get_height(), false, img.get_format(), img.get_data())
				small.resize(int(cw * sc), int(ch * sc), Image.INTERPOLATE_LANCZOS)
				bd.image(small, Vector2(16 + k * (cw * sc + 8), y2), 1.0)
				bd.label(str(r["caps"][k]).split("  (")[0], Vector2(16 + k * (cw * sc + 8), y2 + ch * sc + 2), 10, false, FxSheet.DIM)
			y2 += ch * sc + 22
		y2 += 16
	await bd.save(dir.path_join("board.png"), self)
	bd.free_sheet()
	_write_json(dir.path_join("board.json"), {
		"id": "crash-explosion",
		"date": "2026-10-09",
		"area": "Effects",
		"question": "How does a downed plane look: exploding in mid air, or out of control and crashing? Each option is one consistent treatment of the mid-air explosion, the fall, and the ground impact. (Alex 2026-10-09: 'Dead planes should either explode mid air or lose control by players and crash eventually'; fast flashes, very slow decay)",
		"source": "scripts/fx/fx_board.gd over the real map (terrain provider) at 2 px/m, planes at the sandbox's own scale (36 px at zoom 1)",
		"seed": SEED,
		"parameter": "data/fx/fx.json#crash.options (every value a proposed record)",
		"held_constant": {
			"midair": "a light fighter exploding at 400 m at (3050, 2480) m",
			"out_of_control": "a stand-in for the sim's spiral: 120 m radius, 40 degrees per second clockwise, drifting east at 18 m/s, height 400 m x (1 - (t/14)^1.5), a crash at 14 s at the spiral's end; the plane's own art and shadow are the unit markers' (drawn by the board)",
			"light": "sun azimuth 315, elevation 46; shadow strength 0.44; shadow gap 1% of the height above ground",
			"pen": "shadow side", "fire_accent": fxd.fire_oklch(),
		},
		"frames": {"midair": MID_COLS, "out_of_control": FALL_COLS, "impact": HIT_COLS},
		"options": json_opts,
		"sheet": "board.png (every option, scaled), option_<X>.png (each at full size, with the palette row and the specimen strip)",
		"chosen": null,
		"chosen_by": null,
	})

func _specimen_crash(name: String) -> Image:
	var co := fxd.crash_option(name)
	var z := 1.0
	var k := true_scale_at(z)
	var ppm := maxf(PLANE_PX * z, PLANE_MIN_PX) / 9.0
	var size := Vector2i(900, 140)
	return await _specimen_base(size, func(cl: CanvasLayer) -> void:
		_tree_sprite(Vector2(44, 70), cl, 19.0)
		var pr := FxPlaneProxy.new()
		cl.add_child(pr)
		pr.setup(Transform2D(0.0, Vector2(view.px_per_m, view.px_per_m), 0.0, Vector2.ZERO), ui_style, fxs)
		pr.true_scale = k
		var pl: Array[Dictionary] = []
		pl.append(_plane(Vector2(120.0, 70.0) / view.px_per_m, -PI / 2.0, 400.0))
		pr.planes = pl
		pr.refresh()
		var b := FxData.grp(co, "burst")
		var R := FxData.f(b, "radius_frac") * 9.0
		var x := 200.0
		var bs := FxBurst.bake_burst(fxs, b, R, ppm, true, 777)
		if bs != null:
			for tt in [0.1, 0.5, 2.2]:
				var fi := FxBurst.frame_index(FxData.arr(b, "frames_s"), bs.end_s, tt)
				var sp := Sprite2D.new()
				sp.texture = bs.frames[fi]["tex"]
				sp.centered = false
				sp.position = Vector2(x, 70.0) - bs.origin
				cl.add_child(sp)
				x += bs.origin.x * 1.3 + 10.0
		var parts := FxBurst.bake_parts(fxs, co, 9.0, ppm, null, 99)
		if parts != null:
			var sp2 := Sprite2D.new()
			sp2.texture = parts.flame[0]
			sp2.centered = false
			sp2.position = Vector2(x, 40.0) - parts.flame_origin
			cl.add_child(sp2)
			x += 50.0
			var sp3 := Sprite2D.new()
			sp3.texture = parts.shards[0]
			sp3.centered = false
			sp3.position = Vector2(x, 70.0) - parts.shard_origin[0]
			cl.add_child(sp3)
			x += 40.0
			var sp4 := Sprite2D.new()
			sp4.texture = parts.scars[0]
			sp4.centered = false
			sp4.position = Vector2(x, 70.0) - parts.scar_origin
			cl.add_child(sp4)
			x += parts.scar_origin.x * 2.0 + 20.0
		var smoke_key := FxData.s(FxData.grp(co, "falling"), "smoke_option")
		var so := fxd.smoke_option(smoke_key)
		var pset := FxPuff.bake_set(fxs, so, ppm, 9.0)
		if pset != null:
			var sp5 := Sprite2D.new()
			sp5.texture = (pset.tex[2] as Array)[0]
			sp5.centered = false
			sp5.position = Vector2(x, 70.0) - pset.origin[2]
			cl.add_child(sp5)
	)

func _probe() -> void:
	# one frame each: a trail at zoom 1.0 and at 0.4, to check the look before a board
	var name := str(opts.get("option", "A"))
	fx.clear()
	fx.select(name, name)
	fx.emit_path("p1", func(t: float) -> Dictionary: return smoke_pose(t), 0.0, 20.0, float(opts.get("health", "0.3333")), 9.0)
	var out_probe := ProjectSettings.globalize_path("res://tmp/fx")
	DirAccess.make_dir_recursive_absolute(out_probe)
	var a := await _smoke_frame(0.3333, 3.0, 1.0, "follow")
	a.save_png(out_probe.path_join("probe_smoke_close.png"))
	var b := await _smoke_frame(0.3333, 5.0, 0.35, "mid")
	b.save_png(out_probe.path_join("probe_smoke_far.png"))
	print("[fx-board] probe saved, stats ", fx.stats())

# A handful of crash frames, one option, written to tmp/fx/ to check the look before a board.
func _probe_crash() -> void:
	var name := str(opts.get("option", "A"))
	var out_probe := ProjectSettings.globalize_path("res://tmp/fx")
	DirAccess.make_dir_recursive_absolute(out_probe)
	fx.clear()
	fx.select(fxd.working_default("smoke"), name)
	fx.explode_midair("p1", MID_POS, 400.0, T0, 9.0, MID_HEADING)
	var imgs: Array = []
	for dt in [0.0, 0.1, 0.3, 1.0, 3.0]:
		imgs.append(await _mid_frame({"dt": dt, "zoom": 1.0}))
	imgs.append(await _mid_frame({"dt": 15.0, "zoom": 0.35}))
	for t in [3.0, 9.0, 13.8]:
		imgs.append(await _fall_frame(name, t))
	for dt in [0.0, 0.1, 0.3, 1.0, 3.0]:
		imgs.append(await _hit_frame(name, {"dt": dt, "zoom": 1.0}))
	imgs.append(await _hit_frame(name, {"dt": 15.0, "zoom": 0.35}))
	var cols := 6
	var rows := int(ceil(float(imgs.size()) / float(cols)))
	var sheet := Image.create(cols * CRASH_CROP.x, rows * CRASH_CROP.y, false, Image.FORMAT_RGBA8)
	for k in imgs.size():
		sheet.blit_rect(imgs[k], Rect2i(Vector2i.ZERO, CRASH_CROP), Vector2i((k % cols) * CRASH_CROP.x, (k / cols) * CRASH_CROP.y))
	sheet.save_png(out_probe.path_join("probe_crash_%s.png" % name))
	print("[fx-board] probe crash saved, stats ", fx.stats())
