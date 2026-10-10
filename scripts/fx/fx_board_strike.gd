extends SceneTree

# THE STRIKE'S VARIANT BOARDS (Track X2, 2026-10-10): variants/flak/, variants/bomb-impact/, variants/tower-ruin/.
# WINDOWED ONLY -- under --headless nothing is drawn:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/fx/fx_board_strike.gd -- what=flak|bomb|tower|all|maps [out=variants] [options=F1,F2] [only=<row key>]
#
# Every frame is the REAL MAP (the terrain provider, seed 20261009, the sandbox's 2 px/m) with the effect drawn by the FxLayer
# over it, beside a plane (a tank on the ground for scale, the standing tower for the ruin), at the sandbox's drawn scale (a
# light fighter 36 px across at zoom 1) and at the planning view (zoom 0.35). One seed, one sun, one map spot for every
# option; only the option changes. The frames are over W's village (the walled compound, houses, the road, fields) where the strike will be.
#
# Each board writes: board.json (chosen: null; the options and their parameter sets), frames.json (every frame's file and
# caption), frames/<option>_<row>_<i>.png (every frame at native size, for the full-resolution viewer), option_<X>.png (each
# option's sheet at full size), board.png (every option, scaled) and compare.png (the options side by side, one key frame
# per row). NOTHING IS CHOSEN HERE: Alex chooses; the recommendation is the lead's to record, labelled proposed.

const FxRig = preload("res://scripts/fx/fx_board_rig.gd")
const FxSheet = preload("res://scripts/fx/fx_sheet.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxPuff = preload("res://scripts/fx/fx_puff.gd")
const FxBurst = preload("res://scripts/fx/fx_burst.gd")
const FxBomb = preload("res://scripts/fx/fx_bomb.gd")
const FxRuin = preload("res://scripts/fx/fx_ruin.gd")
const FxBake = preload("res://scripts/fx/fx_bake.gd")
const FxPlaneProxy = preload("res://scripts/fx/fx_plane_proxy.gd")
const InkSprites = preload("res://scripts/render/ink_sprites.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const CROP := Vector2i(560, 380)
const WIDE := Vector2i(900, 520)
const T0 := 100.0                       # game time of the event in every scenario

var opts: Dictionary = {}
var out_dir := ""
var rig: FxRig
var fxs: FxStyle
var fxd: FxData
var _only := ""
var TOWER := Vector2(1940.0, 1444.0)     # W's radio tower site (WorldLayout.sites(), read when the board runs)
var BATTERY := Vector2(1981.0, 1175.0)   # W's first anti-aircraft battery site

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[fx-strike] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	out_dir = str(opts.get("out", "variants"))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	_only = str(opts.get("only", ""))
	_run.call_deferred()

func _run() -> void:
	rig = FxRig.new(self)
	await rig.setup()
	fxs = rig.fxs
	fxd = rig.fxd
	if not fxs.ok() or not rig.ui_style.ok():
		printerr("[fx-strike] style errors: ", fxs.errors, rig.ui_style.errors)
		quit(1)
		return
	var WL: GDScript = load("res://scripts/world/world_layout.gd")
	var layout = WL.new(FxRig.SEED)
	var sites: Dictionary = layout.sites()
	TOWER = sites["radio_tower"]
	BATTERY = (sites["aa_battery"] as Array)[0]
	print("[fx-strike] the village's tower site ", TOWER, ", first battery site ", BATTERY)
	var what := str(opts.get("what", "all"))
	if what == "maps":
		await _maps()
	if what == "flak" or what == "all":
		await _flak_board()
	if what == "bomb" or what == "all":
		await _bomb_board()
	if what == "tower" or what == "all":
		await _tower_board()
	rig.view.queue_free()
	await rig.frames(2)
	quit(1 if rig.failures > 0 else 0)

# --- Scouting the map ---------------------------------------------------------------------------------------------------------

func _maps() -> void:
	var dir := ProjectSettings.globalize_path("res://tmp/fxstrike")
	DirAccess.make_dir_recursive_absolute(dir)
	var spots: Array = [Vector2(1940.0, 1444.0), Vector2(2000.0, 1400.0), Vector2(1981.0, 1175.0), Vector2(1723.0, 1629.0), Vector2(2100.0, 1500.0), Vector2(1800.0, 1300.0), Vector2(3000.0, 2740.0), Vector2(2000.0, 1700.0)]
	var cols := 4
	var imgs: Array = []
	for s: Vector2 in spots:
		rig.set_planes([])
		rig.set_towers([])
		imgs.append(await rig.grab(s, 1.0, CROP))
	var rows := int(ceil(float(imgs.size()) / float(cols)))
	var sheet := Image.create(cols * CROP.x, rows * CROP.y, false, Image.FORMAT_RGBA8)
	for k in imgs.size():
		sheet.blit_rect(imgs[k], Rect2i(Vector2i.ZERO, CROP), Vector2i((k % cols) * CROP.x, (k / cols) * CROP.y))
	sheet.save_png(dir.path_join("maps.png"))
	print("[fx-strike] maps: ", spots)

# --- Rows ---------------------------------------------------------------------------------------------------------------------------

func _frame(dt: float, zoom: float, center: Vector2, planes: Array, cap: String, towers: Array = []) -> Dictionary:
	return {"dt": dt, "zoom": zoom, "center": center, "planes": planes, "towers": towers,
		"cap": "%s  (zoom %.2f)" % [cap, zoom]}

# A row: {key, title, crop, setup (Callable: replays the field), frames [...], key_frame (the one the compare sheet shows)}.
func _row(key: String, title: String, crop: Vector2i, setup: Callable, frames: Array, key_frame: int) -> Dictionary:
	return {"key": key, "title": title, "crop": crop, "setup": setup, "frames": frames, "key_frame": key_frame}

# Runs a row: replays its state, then grabs each frame. Returns {key, title, frames [Image], caps [String], key_frame}.
func _run_row(r: Dictionary) -> Dictionary:
	if (r["setup"] as Callable).is_valid():
		(r["setup"] as Callable).call()
	var imgs: Array = []
	var caps: Array = []
	for f: Dictionary in r["frames"]:
		if f.has("setup"):
			(f["setup"] as Callable).call()
		rig.fx.set_time(T0 + float(f["dt"]))
		rig.set_planes(f["planes"])
		rig.set_towers(f["towers"])
		var img: Image = await rig.grab(f["center"], float(f["zoom"]), r["crop"])
		imgs.append(img)
		caps.append(str(f["cap"]))
	print("[fx-strike] row %s: %d frames (%s)" % [r["key"], imgs.size(), str(rig.fx.stats())])
	return {"key": r["key"], "title": r["title"], "frames": imgs, "caps": caps, "key_frame": int(r["key_frame"]), "crop": r["crop"]}

func _fx_reset() -> void:
	rig.fx.clear()
	rig.set_planes([])
	rig.set_towers([])

# The reference plane of the other side, hanging by the event for scale.
func _ref_plane(near: Vector2, h: float = 400.0) -> Dictionary:
	return rig.plane(near, 0.1, h, "side_b")

# --- The sheets (shared) -------------------------------------------------------------------------------------------------------------

func _chips(sh: FxSheet, pos: Vector2) -> float:
	var items := [["paper", "paper"], ["object_fill", "object fill"], ["wall_fill", "wall fill"], ["ink", "ink"], ["dirt", "dirt"], ["shadow", "shadow tint"], ["side_a", "side A"], ["side_b", "side B"], ["flash", "knock-out (flash)"]]
	var x := pos.x
	for it in items:
		var c: Color = fxs.palette[it[0]]
		sh.swatch(Vector2(x, pos.y), Vector2(58, 26), c)
		var l := FxStyle.to_oklch(c)
		sh.label(it[1], Vector2(x, pos.y + 29), 11, false, FxSheet.FG)
		sh.label("%.2f %.2f %d" % [l[0], l[1], roundi(l[2])], Vector2(x, pos.y + 43), 10, false, FxSheet.DIM)
		x += 74.0
	return pos.y + 60.0

func _shrink(img: Image, w: int, h: int) -> Image:
	var small := Image.create_from_data(img.get_width(), img.get_height(), false, img.get_format(), img.get_data())
	small.resize(w, h, Image.INTERPOLATE_LANCZOS)
	return small

# Writes a board: every frame at native size with frames.json, option sheets, the contact sheet, the compare sheet, board.json.
# data: option -> [row result]. specimens: option -> Image. meta: id, question, source, held (Dictionary), kind ("flak"...), changes (option -> text).
func _write_board(meta: Dictionary, names: Array, data: Dictionary, specimens: Dictionary) -> void:
	var id := str(meta["id"])
	var kind := str(meta["kind"])
	var dir := out_dir.path_join(id)
	DirAccess.make_dir_recursive_absolute(dir.path_join("frames"))
	var listing: Array = []
	var json_opts: Array = []
	for name: String in names:
		var rows_out: Array = []
		for r: Dictionary in data[name]:
			var frames_out: Array = []
			for i in (r["frames"] as Array).size():
				var rel := "frames/%s_%s_%d.png" % [name, r["key"], i]
				var err := ((r["frames"] as Array)[i] as Image).save_png(dir.path_join(rel))
				if err != OK:
					printerr("[fx-strike] could not write ", rel)
					rig.failures += 1
				frames_out.append({"file": rel, "caption": str((r["caps"] as Array)[i])})
			rows_out.append({"title": str(r["title"]), "key": str(r["key"]), "size_px": [(r["crop"] as Vector2i).x, (r["crop"] as Vector2i).y], "frames": frames_out})
		listing.append({"option": name, "label": fxd.option_label(kind, name), "note": fxd.option_note(kind, name), "rows": rows_out})
	_write_json(dir.path_join("frames.json"), {"id": id, "options": listing})
	# one sheet per option, full size
	for name: String in names:
		var rows: Array = data[name]
		var w := 1300
		var h := 230
		for r: Dictionary in rows:
			var c: Vector2i = r["crop"]
			var per := _per_line(c)
			var n := (r["frames"] as Array).size()
			w = maxi(w, mini(n, per) * (c.x + 8) + 40)
			h += int(ceil(float(n) / float(per))) * (c.y + 40) + 30
		var sh := FxSheet.new(rig.vp.get_parent(), Vector2i(w, h))
		sh.label("%s, option %s" % [meta["title"], fxd.option_label(kind, name)], Vector2(16, 10), 22, true)
		var nl := sh.label(fxd.option_note(kind, name), Vector2(16, 40), 13, false, FxSheet.DIM, w - 40.0)
		var y := 48.0 + nl.size.y
		sh.label("On paper, beside a tree (38 px canopy) and a light fighter (36 px at zoom 1.0): what it is made of, and the palette it is drawn in:", Vector2(16, y), 12, false, FxSheet.DIM)
		sh.image(specimens[name], Vector2(16, y + 18), 1.0)
		_chips(sh, Vector2(16 + specimens[name].get_width() + 24, y + 22))
		y += 18 + specimens[name].get_height() + 22
		for r: Dictionary in rows:
			sh.label(str(r["title"]), Vector2(16, y), 14, true)
			y += 22
			var c: Vector2i = r["crop"]
			var per := _per_line(c)
			for k in (r["frames"] as Array).size():
				var col := k % per
				var line := k / per
				var at := Vector2(16 + col * (c.x + 8), y + line * (c.y + 40))
				sh.image((r["frames"] as Array)[k], at, 1.0)
				sh.label(str((r["caps"] as Array)[k]), at + Vector2(0, c.y + 4), 12, false, FxSheet.DIM)
			y += int(ceil(float((r["frames"] as Array).size()) / float(per))) * (c.y + 40) + 8
		await sh.save(dir.path_join("option_%s.png" % name), self)
		sh.free_sheet()
		json_opts.append({"name": name, "label": fxd.option_label(kind, name), "note": fxd.option_note(kind, name), "file": "option_%s.png" % name, "parameters": _option_of(kind, name)})
	# the contact sheet: every option, every row, shrunk
	var sc := 0.5
	var bw := 1200
	var bh := 150
	for name: String in names:
		bh += 40
		for r: Dictionary in data[name]:
			bh += int((r["crop"] as Vector2i).y * sc) + 24
	var bd := FxSheet.new(rig.vp.get_parent(), Vector2i(bw, bh))
	bd.label("%s  ·  seed %d, the real map" % [meta["title"], FxRig.SEED], Vector2(16, 10), 22, true)
	bd.label(str(meta["intro"]), Vector2(16, 42), 12, false, FxSheet.DIM, bw - 40.0)
	var y2 := _chips(bd, Vector2(16, 100)) + 8
	for name: String in names:
		bd.label("%s" % fxd.option_label(kind, name), Vector2(16, y2), 16, true)
		y2 += 26
		for r: Dictionary in data[name]:
			var c: Vector2i = r["crop"]
			var cw := int(c.x * sc)
			var ch := int(c.y * sc)
			var x := 16.0
			var shown := 0
			for k in (r["frames"] as Array).size():
				if x + cw > bw - 8:
					break
				bd.image(_shrink((r["frames"] as Array)[k], cw, ch), Vector2(x, y2), 1.0)
				x += cw + 4
				shown += 1
			y2 += ch + 4
			bd.label("%s (%d of %d frames shown; the rest are in frames/)" % [r["title"], shown, (r["frames"] as Array).size()], Vector2(16, y2), 10, false, FxSheet.DIM)
			y2 += 18
	await bd.save(dir.path_join("board.png"), self)
	bd.free_sheet()
	# the compare sheet: one key frame per row, the options side by side
	var row_keys: Array = []
	for r: Dictionary in data[names[0]]:
		row_keys.append(str(r["key"]))
	var c0: Vector2i = (data[names[0]] as Array)[0]["crop"]
	var csc := 0.6
	var cell := Vector2i(int(c0.x * csc), int(c0.y * csc))
	var cmp_w := 400
	var cmp_h := 80
	for r: Dictionary in data[names[0]]:
		cmp_h += int((r["crop"] as Vector2i).y * csc) + 50
		cmp_w = maxi(cmp_w, int(names.size() * (int((r["crop"] as Vector2i).x * csc) + 6)) + 40)
	var cmp := FxSheet.new(rig.vp.get_parent(), Vector2i(cmp_w, cmp_h))
	cmp.label("%s: the options side by side" % meta["title"], Vector2(16, 10), 22, true)
	cmp.label("One key frame per row, the options left to right (%s). Shrunk to 60%%; the native frames are in frames/." % ", ".join(PackedStringArray(names)), Vector2(16, 42), 12, false, FxSheet.DIM, cmp_w - 40.0)
	var y3 := 76.0
	for ri in (data[names[0]] as Array).size():
		var r0: Dictionary = (data[names[0]] as Array)[ri]
		var c: Vector2i = r0["crop"]
		var cw2 := int(c.x * csc)
		var ch2 := int(c.y * csc)
		cmp.label("%s  --  %s" % [r0["title"], (r0["caps"] as Array)[int(r0["key_frame"])]], Vector2(16, y3), 12, true)
		y3 += 20
		for ni in names.size():
			var rr: Dictionary = (data[names[ni]] as Array)[ri]
			cmp.image(_shrink((rr["frames"] as Array)[int(rr["key_frame"])], cw2, ch2), Vector2(16 + ni * (cw2 + 6), y3), 1.0)
			cmp.label(str(names[ni]), Vector2(20 + ni * (cw2 + 6), y3 + 3), 14, true, FxSheet.FG)
		y3 += ch2 + 28
	await cmp.save(dir.path_join("compare.png"), self)
	cmp.free_sheet()
	_write_json(dir.path_join("board.json"), {
		"id": id,
		"date": "2026-10-10",
		"area": "Effects",
		"question": str(meta["question"]),
		"source": str(meta["source"]),
		"seed": FxRig.SEED,
		"parameter": "data/fx/fx.json#%s.options (every value a proposed record)" % kind,
		"held_constant": meta["held"],
		"options": json_opts,
		"sheet": "board.png (every option, scaled), compare.png (the options side by side, one key frame per row), option_<X>.png (each at full size, with the palette row and the specimen strip); every frame at native size in frames/, listed in frames.json",
		"recommendation": meta.get("recommendation", {"option": null, "_proposed": true, "_reason": "none yet"}),
		"chosen": null,
		"chosen_by": null,
	})

# How many frames of a crop fit across an option sheet (the sheets are about 2300 px wide).
func _per_line(c: Vector2i) -> int:
	return maxi(1, int(2300 / (c.x + 8)))

func _option_of(kind: String, name: String) -> Dictionary:
	match kind:
		"flak":
			return fxd.flak_option(name)
		"bomb":
			return fxd.bomb_option(name)
	return fxd.ruin_option(name)

func _write_json(path: String, d: Dictionary) -> void:
	rig.write_json(path, d)

# --- Specimens ---------------------------------------------------------------------------------------------------------------------------

func _tree_sprite(at: Vector2, parent: Node, r: float) -> void:
	var P := RenderParams.new()
	var t := {"r": r, "seed": 4242}
	var g := InkSprites.build_tree_sprite(t, P)
	var img := g.finish_image()
	var sp := Sprite2D.new()
	sp.texture = FxBake.texture(img, false)
	sp.position = at
	parent.add_child(sp)

func _sprite(cl: Node, tex: Texture2D, origin: Vector2, at: Vector2, scale: float = 1.0) -> void:
	if tex == null:
		return
	var sp := Sprite2D.new()
	sp.texture = tex
	sp.centered = false
	sp.scale = Vector2(scale, scale)
	sp.position = at - origin * scale
	cl.add_child(sp)

func _plane_specimen(cl: Node, at_px: Vector2, h: float = 400.0) -> void:
	var k := rig.true_scale_at(1.0)
	var pr := FxPlaneProxy.new()
	cl.add_child(pr)
	pr.setup(Transform2D(0.0, Vector2(rig.view.px_per_m, rig.view.px_per_m), 0.0, Vector2.ZERO), rig.ui_style, fxs)
	pr.true_scale = k
	var pl: Array[Dictionary] = []
	pl.append(rig.plane(at_px / rig.view.px_per_m, -PI / 2.0, h))
	pr.planes = pl
	pr.refresh()

func _ppm1() -> float:
	return maxf(FxRig.PLANE_PX * 1.0, FxRig.PLANE_MIN_PX) / 9.0

func _flash_strip(cl: Node, flash: Dictionary, radius_m: float, hit: bool, ages: Array, x0: float, y: float, ground: bool) -> float:
	var def := flash.duplicate()
	def["hit"] = hit
	var bs := FxBurst.bake_burst(fxs, def, radius_m, _ppm1(), ground, 777)
	var x := x0
	if bs == null:
		return x
	for tt in ages:
		var fi := FxBurst.frame_index(FxData.arr(def, "frames_s"), bs.end_s, float(tt))
		if fi < 0:
			continue
		_sprite(cl, bs.frames[fi]["tex"], bs.origin, Vector2(x + bs.origin.x * 0.7, y))
		x += bs.origin.x * 1.4 + 6.0
	return x

func _specimen_flak(name: String) -> Image:
	var o := fxd.flak_option(name)
	var bg := FxData.grp(o, "burst")
	var fl := FxData.grp(o, "flash")
	var po := FxData.grp(o, "puff").duplicate(true)
	po["ground_shadow"] = true
	po["shadow_min_tone"] = 1
	var size := FxData.f(bg, "size_m")
	var ppm := _ppm1()
	var ages := [0.04, 0.09, 0.16, 0.4]
	return await rig.specimen(Vector2i(1400, 190), func(cl: CanvasLayer) -> void:
		_tree_sprite(Vector2(40, 60), cl, 19.0)
		_plane_specimen(cl, Vector2(110, 60))
		var x := 170.0
		var rflash := FxData.f(fl, "radius_frac") * size
		x = _flash_strip(cl, fl, rflash, false, ages, x, 60.0, false)
		x += 14.0
		x = _flash_strip(cl, fl, rflash * FxData.f(fl, "hit_scale"), true, ages, x, 60.0, false)
		x += 18.0
		var ps := FxPuff.bake_set(fxs, po, ppm, size)
		if ps != null:
			var x2 := 170.0
			for stage in ps.stages:
				for tone in FxPuff.TONES:
					var tex: Texture2D = (ps.tex[tone] as Array)[ps.variants * stage]
					_sprite(cl, tex, ps.origin[tone], Vector2(x2 + ps.origin[tone].x, 140.0))
					x2 += ps.origin[tone].x * 2.0 + 10.0
				x2 += 20.0
	)

func _specimen_bomb(name: String) -> Image:
	var o := fxd.bomb_option(name)
	var fl := FxData.grp(o, "flash")
	var blast := 45.0
	var ppm := _ppm1()
	var ages := [0.05, 0.1, 0.3, 0.8, 2.2]
	return await rig.specimen(Vector2i(1400, 190), func(cl: CanvasLayer) -> void:
		_tree_sprite(Vector2(40, 60), cl, 19.0)
		_plane_specimen(cl, Vector2(110, 60))
		var x := _flash_strip(cl, fl, FxData.f(fl, "radius_frac") * blast, false, ages, 170.0, 60.0, true)
		x += 20.0
		var bs := FxBomb.bake_set(fxs, FxData.grp(o, "crater"), FxData.grp(o, "debris"), FxData.grp(o, "fall"), blast, ppm, 99)
		if bs != null:
			for t in bs.craters:
				_sprite(cl, t, bs.crater_origin, Vector2(x + bs.crater_origin.x, 60.0))
				x += bs.crater_origin.x * 2.0 + 6.0
			x += 10.0
			for k in bs.clods.size():
				_sprite(cl, bs.clods[k], bs.clod_origin[k], Vector2(x, 60.0))
				x += 24.0
			_sprite(cl, bs.bomb, bs.bomb_origin, Vector2(x + 14.0, 60.0))
		# the smoke the bomb makes, at its thick tone and thin
		var sk := fxd.smoke_option(FxData.s(FxData.grp(o, "smoke_burst"), "smoke_option"))
		var ps := FxPuff.bake_set(fxs, sk, ppm, blast * 0.5)
		if ps != null:
			var x2 := 170.0
			for stage in ps.stages:
				for tone in FxPuff.TONES:
					_sprite(cl, (ps.tex[tone] as Array)[ps.variants * stage], ps.origin[tone], Vector2(x2 + ps.origin[tone].x, 140.0))
					x2 += ps.origin[tone].x * 2.0 + 8.0
				x2 += 16.0
	)

func _specimen_ruin(name: String) -> Image:
	var o := fxd.ruin_option(name)
	var M := FxRuin.tower_model(fxs.scene_seed, rig.fx.field.tower_variant())
	var ppm := _ppm1()
	var rs := FxRuin.bake_set(fxs, o, M, ppm, FxBake.seed_of(name, "ruin", 0), PI / 2.0)
	var fl := FxData.grp(o, "flash")
	return await rig.specimen(Vector2i(1400, 250), func(cl: CanvasLayer) -> void:
		_tree_sprite(Vector2(40, 60), cl, 19.0)
		_plane_specimen(cl, Vector2(110, 60))
		# the standing tower beside its ruin variants
		var half := int(ceil(34.0 * ppm))
		var g := InkCanvas_new(Vector2i(half * 2, half * 2))
		FxRuin.draw_standing(g, fxs, M, ppm, Vector2(half, half), fxs.palette["side_a"], {"rock": "ruin.rock", "roof": "ruin.roof", "cream": "ruin.cream"}, PI / 2.0)
		var img := FxBake.render([g])
		var tex := FxBake.texture(img[0], false)
		_sprite(cl, tex, Vector2(half, half), Vector2(240, 100), 1.0)
		var x := 380.0
		if rs != null:
			for v in rs.remains.size():
				_sprite(cl, rs.remains[v], rs.remains_origin, Vector2(x + 70.0, 100.0))
				x += 150.0
			x = 380.0
			for v in rs.lying.size():
				if rs.lying[v] != null:
					_sprite(cl, rs.lying[v], rs.lying_origin, Vector2(x, 215.0))
					x += 190.0
			var frames: Array = rs.collapse[0] if not rs.collapse.is_empty() else []
			for fr in frames:
				_sprite(cl, (fr as Dictionary)["tex"], rs.lying_origin, Vector2(x, 215.0), 0.6)
				x += 90.0
		x = 1000.0
		x = _flash_strip(cl, fl, FxData.f(fl, "radius_frac") * 12.0, false, [0.05, 0.18, 0.5, 1.3], x, 60.0, true)
	)

func InkCanvas_new(size: Vector2i) -> RefCounted:
	var g = load("res://scripts/render/ink_canvas.gd").new(size)
	g.line_cap = "round"
	return g

# --- THE FLAK BOARD ---------------------------------------------------------------------------------------------------------------------

const BOMBER_V := 85.0   # the sim's bomber speed (data/units/bomber.json), m/s

func _names(key_default: Array) -> Array:
	return str(opts.get("options", ",".join(PackedStringArray(key_default)))).split(",")

func _flak_board() -> void:
	var names: Array = _names(fxd.flak_option_names())
	var data := {}
	var specimens := {}
	for name: String in names:
		var rows: Array = []
		for r: Dictionary in _flak_rows(name):
			if _only != "" and str(r["key"]) != _only:
				continue
			rows.append(await _run_row(r))
		data[name] = rows
		specimens[name] = await _specimen_flak(name)
	await _write_board({
		"id": "flak", "kind": "flak", "title": "Flak bursts",
		"question": "How does a flak burst look where an anti-aircraft battery's shell bursts near a plane: classic dark puffs in Inkwood's ink-and-wash terms, no fire; a fast flash and a slowly fading puff at the burst's height with its shadow by the altitude rule; hits and misses. (Alex 2026-10-10: the strike has two anti-aircraft batteries firing flak at the players' planes.)",
		"source": "scripts/fx/fx_board_strike.gd (what=flak) over the real map (terrain provider) at 2 px/m, planes at the sandbox's own scale (36 px at zoom 1); the bursts are FxLayer.flak_burst",
		"intro": "A light fighter at 400 m is shot at: a miss, a hit, and a barrage of twenty shells (two batteries, two rolls a second each, a bomber at 85 m/s) as the sim fires them. Time runs left to right. Zoom 1.0 puts the plane at 36 px and the map at 2 px/m; 0.6 and 0.35 are wider views (the planning view is 0.35). The second plane, of the other side, hangs by the burst for scale. Sun from the NW, shadows 44%, the shadow of a burst 1% of its height along the light. NO FIRE. ALL OPTIONS ARE PROPOSED; none is chosen.",
		"held": {"scene": "a light fighter at 400 m heading 0.1 rad at 100 m/s over the first anti-aircraft battery site of the world layout (the battery is drawn by the unit marker art); the burst at game time 100", "light": "sun azimuth 315, elevation 46; shadow strength 0.44", "pen": "shadow side", "fire": "none"},
		"recommendation": {"option": "F1", "_proposed": true, "_reason": "PROPOSED by Track X2, not Alex's call: F1 builds the burst the way Alex's chosen damage smoke (W1, soft white to grey) is built, stepped translucent washes with no outline, in the palette's ink instead of white; it is the quietest of the four, reads as a dark cloud at both scales, cannot be mistaken for the white smoke, and avoids the star and scallop shapes the fire research found cartoony. F2 is the flak look at its most classic (a jagged cloud with streamers) if Alex wants more drawing in it."},
	}, names, data, specimens)

func _flak_rows(name: String) -> Array:
	var A := BATTERY + Vector2(70.0, -20.0)
	var bat := rig.plane(BATTERY, 0.0, 0.0, "side_b", "anti_aircraft_battery")
	var dirv := Vector2.from_angle(0.1)
	var ref := _ref_plane(A + Vector2(-60.0, 70.0))
	var rows: Array = []
	# where the burst of a shot lands (the field's own arithmetic, in a scratch field)
	var probe := FxFieldScratch.new(fxd)
	for spec in [["miss", false, "a. A MISS: the shell bursts beside the fighter; it flies on at 100 m/s (its tail leaves the frame by 1.5 s)"], ["hit", true, "b. A HIT: the shell bursts on the fighter"]]:
		var hit: bool = spec[1]
		probe.f.select_strike(name)
		probe.f.clear()
		probe.f.flak_burst(A, 400.0, T0, hit, "aa1/0")
		var bpos: Vector2 = probe.f.bursts[0]["pos"]
		var setup := func() -> void:
			_fx_reset()
			rig.fx.select_strike(name)
			rig.fx.flak_burst(A, 400.0, T0, hit, "aa1/0")
		var frames: Array = []
		for c in [[0.0, 1.0, "0 s"], [0.1, 1.0, "0.1 s"], [0.3, 1.0, "0.3 s"], [1.0, 1.0, "1 s"], [3.0, 1.0, "3 s"], [5.0, 1.0, "one turn later"], [10.0, 0.35, "two turns later"], [15.0, 0.35, "three turns later"]]:
			var dt: float = c[0]
			var pl := rig.plane(A + dirv * 100.0 * dt, 0.1, 400.0)
			frames.append(_frame(dt, float(c[1]), bpos, [pl, ref, bat], str(c[2])))
		rows.append(_row(str(spec[0]), str(spec[2]), CROP, setup, frames, 1))
	# the barrage
	var start := BATTERY + Vector2(-330.0, 40.0)
	var barrage := func() -> void:
		_fx_reset()
		rig.fx.select_strike(name)
		for k in 20:
			var t := T0 + 0.25 * float(k)
			var tgt := start + Vector2(BOMBER_V * (t - T0), 0.0)
			var hit := (k == 6 or k == 11)
			rig.fx.flak_burst(tgt, 400.0, t, hit, "aa%d/%d" % [k % 2, k / 2])
	var bframes: Array = []
	for c in [[2.5, 0.6, "mid-turn, 10 shells"], [5.0, 0.6, "the turn's end, 20 shells"], [10.0, 0.6, "one turn later"], [15.0, 0.6, "two turns later"], [5.0, 0.35, "the turn's end"], [12.0, 0.35, "two turns on"], [20.0, 0.35, "three turns on"], [30.0, 0.35, "five turns on"]]:
		var dt: float = c[0]
		var bp := rig.plane(start + Vector2(BOMBER_V * dt, 0.0), 0.0, 400.0, "side_a", "bomber")
		var cx := start + Vector2(BOMBER_V * 2.5 if float(c[1]) > 0.5 else BOMBER_V * 2.5, 0.0)
		bframes.append(_frame(dt, float(c[1]), cx, [bp, rig.plane(BATTERY, 0.0, 0.0, "side_b", "anti_aircraft_battery")], str(c[2])))
	rows.append(_row("barrage", "c. A BARRAGE: two batteries, 20 shells in a turn (two hits among them) at a bomber crossing at 85 m/s; the planning view is the second half", WIDE, barrage, bframes, 1))
	# beside the damage smoke
	var mixed := func() -> void:
		_fx_reset()
		rig.fx.select_strike(name)
		var sampler := func(t: float) -> Dictionary:
			return {"x": A.x + 100.0 * (t - T0), "y": A.y, "height_m": 400.0, "heading": 0.0}
		rig.fx.emit_path("p1", sampler, T0 - 8.0, T0 + 10.0, 0.3333, 9.0)
		for k in 6:
			var t := T0 + 0.5 * float(k)
			rig.fx.flak_burst(A + Vector2(100.0 * (t - T0), 0.0), 400.0, t, k == 3, "aa/%d" % k)
	var mframes: Array = []
	for c in [[1.0, "1 s"], [3.0, "3 s"], [6.0, "6 s"], [12.0, "12 s"]]:
		var dt: float = c[0]
		var mp := rig.plane(A + Vector2(100.0 * dt, 0.0), 0.0, 400.0)
		mframes.append(_frame(dt, 0.6, A + Vector2(150.0, 0.0), [mp, bat], "%s: a damaged fighter, its white smoke, and flak" % c[1]))
	# the shadow by the altitude rule: the same burst at three heights
	var hframes: Array = []
	for hh in [[120.0, "120 m (low): its shadow nearly under it"], [400.0, "400 m (medium)"], [1000.0, "1,000 m (high): its shadow well away"]]:
		var h: float = hh[0]
		var hset := func() -> void:
			_fx_reset()
			rig.fx.select_strike(name)
			rig.fx.flak_burst(A, h, T0, false, "aa1/h%d" % int(h))
			rig.fx.flak_burst(A + Vector2(60.0, 40.0), h, T0, true, "aa1/h%db" % int(h))
		var hp := rig.plane(A + Vector2(60.0, 40.0), 0.1, h)
		hframes.append(_frame(1.0, 1.0, A + Vector2(30.0, 20.0), [hp], str(hh[1])))
		hframes[hframes.size() - 1]["setup"] = hset
	rows.append(_row("heights", "d. THE SHADOW BY THE ALTITUDE RULE (1% of the height, away from the sun): a miss and a hit at 120, 400 and 1,000 m, 1 s after the burst", CROP, Callable(), hframes, 1))
	rows.append(_row("smoke", "e. NEXT TO THE DAMAGE SMOKE (W1, soft white to grey): a fighter on its last pip trailing smoke, six shells bursting round it, one hit", WIDE, mixed, mframes, 2))
	return rows

# A scratch FxField to ask where a shot's burst falls without touching the layer.
class FxFieldScratch:
	var f: RefCounted
	func _init(d: RefCounted) -> void:
		f = load("res://scripts/fx/fx_field.gd").new(d)

# --- THE BOMB BOARD ---------------------------------------------------------------------------------------------------------------------

const BOMB_H := 400.0
const BOMB_G := 9.81

func _fall_s() -> float:
	return sqrt(2.0 * BOMB_H / BOMB_G)

# A stick of n bombs landing round `centre` along the bomber's heading (east), spaced as the sim spaces them
# (release_interval_s 0.12 x 85 m/s = 10.2 m) with a Gaussian-ish scatter, the bombs' own times 0.12 s apart.
func _stick(n: int, centre: Vector2, t_mid: float, seed_v: int, sigma: float = 7.0) -> Array:
	var rng := Mulberry32.new(seed_v)
	var out: Array = []
	var fall := _fall_s()
	for i in n:
		var u := float(i) - float(n - 1) * 0.5
		var gx := (rng.next() + rng.next() + rng.next() - 1.5) * 2.0 * sigma
		var gy := (rng.next() + rng.next() + rng.next() - 1.5) * 2.0 * sigma
		var land := centre + Vector2(u * BOMBER_V * 0.12 + gx, gy)
		var t := t_mid + u * 0.12
		out.append({"pos": land, "t": t, "from": land - Vector2(BOMBER_V * fall, 0.0), "t_rel": t - fall, "i": i})
	return out

func _play_stick(stick: Array, uid: String) -> void:
	for b: Dictionary in stick:
		rig.fx.bomb_drop(uid, int(b["i"]), b["from"], BOMB_H, float(b["t_rel"]), b["pos"], float(b["t"]))
		rig.fx.bomb_impact(b["pos"], float(b["t"]), 45.0, uid, int(b["i"]))

func _tank(at: Vector2) -> Dictionary:
	return rig.plane(at, 0.3, 0.0, "side_b", "tank")

func _bomb_board() -> void:
	var names: Array = _names(fxd.bomb_option_names())
	var data := {}
	var specimens := {}
	for name: String in names:
		var rows: Array = []
		for r: Dictionary in _bomb_rows(name):
			if _only != "" and str(r["key"]) != _only:
				continue
			rows.append(await _run_row(r))
		data[name] = rows
		specimens[name] = await _specimen_bomb(name)
	await _write_board({
		"id": "bomb-impact", "kind": "bomb", "title": "Bomb impacts",
		"question": "How does a bomb hitting the ground look: a fast flash, a smoke burst (thick, shadowed), debris, then a crater mark that stays; and a stick of several bombs walking across the ground. (Alex 2026-10-10: bombers drop sticks of bombs; thick smoke casts a shadow; no fire.)",
		"source": "scripts/fx/fx_board_strike.gd (what=bomb) over the real map (terrain provider) at 2 px/m, planes at the sandbox's own scale (36 px at zoom 1); the effects are FxLayer.bomb_drop and bomb_impact (blast radius 45 m, data/sim/bombs.json)",
		"intro": "One bomb, then a stick of six (spaced 10 m by the sim's 0.12 s release interval at 85 m/s, scattered as its spread does), from a bomber at 400 m: the impact at 0.1 s, 0.3 s, 1 s and a turn on, and what stays when the smoke has gone. The tank (side B, 6 m) is for scale; the second plane hangs by for scale. The smoke is the damage smoke (W1, soft white to grey; B2 draws it in the plain grey W2). Sun from the NW, shadows 44%. NO FIRE. ALL OPTIONS ARE PROPOSED; none is chosen.",
		"held": {"scene": "bombs from a bomber at 400 m and 85 m/s (fall 9.0 s, range 768 m), landing east of the village compound at game time 100; blast radius 45 m", "light": "sun azimuth 315, elevation 46; shadow strength 0.44; a bomb's shadow 1% of its height along the light", "pen": "shadow side", "fire": "none"},
		"recommendation": {"option": "B1", "_proposed": true, "_reason": "PROPOSED by Track X2, not Alex's call: B1 is the damage smoke's own language (a soft knock-out flash, thick white smoke thrown out and hanging, casting a shadow), with clods and an ink-ringed pit. B3 draws the lasting crater better (a pale lip round a dark pit reads as a hole at any distance): if Alex likes B1's blast and B3's crater, the crater is a separate data group and can be swapped."},
	}, names, data, specimens)

func _bomb_rows(name: String) -> Array:
	var P := TOWER + Vector2(110.0, 30.0)   # east of the compound, across the street, among the houses
	var P1 := TOWER + Vector2(170.0, 60.0)  # open ground beyond them
	var tank := _tank(P + Vector2(34.0, 20.0))
	var tank1 := _tank(P1 + Vector2(34.0, 20.0))
	var ref := _ref_plane(P + Vector2(-60.0, -70.0), 150.0)
	var ref1 := _ref_plane(P1 + Vector2(-60.0, -70.0), 150.0)
	var single := _stick(1, P1, T0, 1)
	var six := _stick(6, P, T0, 7)
	var rows: Array = []
	# b. one bomb
	var one_setup := func() -> void:
		_fx_reset()
		rig.fx.select_strike("", name)
		_play_stick(single, "b1")
	var one_frames: Array = []
	for c in [[0.0, "0 s"], [0.1, "0.1 s"], [0.3, "0.3 s"], [1.0, "1 s"], [3.0, "3 s"], [5.0, "one turn later"], [10.0, "two turns later"], [20.0, "four turns later"], [60.0, "twelve turns later: what stays"]]:
		one_frames.append(_frame(float(c[0]), 1.0, P1 + Vector2(8.0, 0.0), [tank1, ref1], str(c[1])))
	rows.append(_row("single", "a. ONE BOMB (blast radius 45 m): a fast flash, a thick shadowed burst of smoke, clods of earth thrown up and falling, a billow, then the crater", CROP, one_setup, one_frames, 2))
	# c. a stick
	var six_setup := func() -> void:
		_fx_reset()
		rig.fx.select_strike("", name)
		_play_stick(six, "bs")
	var six_frames: Array = []
	for c in [[0.1, "0.1 s: the first bombs"], [0.4, "0.4 s"], [0.8, "0.8 s"], [1.5, "1.5 s"], [3.0, "3 s"], [6.0, "one turn later"], [15.0, "three turns later"], [40.0, "eight turns later"]]:
		six_frames.append(_frame(float(c[0]), 1.0, P + Vector2(10.0, 0.0), [tank, ref], str(c[1])))
	rows.append(_row("stick", "b. A STICK OF SIX walks across the ground, 0.12 s apart, 10 m apart, scattered: six flashes, six crater marks, one pall of smoke", WIDE, six_setup, six_frames, 2))
	# d. what stays
	var stay_frames: Array = []
	for c in [[90.0, 1.0, "eighteen turns later"], [300.0, 1.0, "sixty turns later"], [90.0, 0.35, "eighteen turns later"], [300.0, 0.35, "sixty turns later"]]:
		stay_frames.append(_frame(float(c[0]), float(c[1]), P + Vector2(10.0, 0.0), [tank], str(c[2])))
	rows.append(_row("stays", "c. WHAT STAYS: the craters after the smoke has gone, close and at the planning view", WIDE, six_setup, stay_frames, 0))
	# e. two passes
	var two_setup := func() -> void:
		_fx_reset()
		rig.fx.select_strike("", name)
		_play_stick(six, "bp1")
		_play_stick(_stick(6, P + Vector2(-40.0, -70.0), T0 + 10.0, 11), "bp2")
	var two_frames: Array = []
	for c in [[3.0, "3 s: the first pass"], [10.5, "10.5 s: the second pass lands"], [14.0, "14 s"], [30.0, "six turns on"], [100.0, "twenty turns on"]]:
		two_frames.append(_frame(float(c[0]), 0.35, P + Vector2(-20.0, -35.0), [], str(c[1])))
	rows.append(_row("passes", "d. TWO PASSES, ten seconds apart, at the planning view", WIDE, two_setup, two_frames, 1))
	return rows

# --- THE TOWER BOARD ---------------------------------------------------------------------------------------------------------------------

func _tower_board() -> void:
	var names: Array = _names(fxd.ruin_option_names())
	var data := {}
	var specimens := {}
	for name: String in names:
		var rows: Array = []
		for r: Dictionary in _tower_rows(name):
			if _only != "" and str(r["key"]) != _only:
				continue
			rows.append(await _run_row(r))
		data[name] = rows
		specimens[name] = await _specimen_ruin(name)
	await _write_board({
		"id": "tower-ruin", "kind": "ruin", "title": "The radio tower destroyed",
		"question": "How does the strike's target look destroyed: the moment (the burst), the collapse, and what stays: a ruin (a broken base, scattered pieces), a crater, a smoke column that thins over turns; no fire. (Alex 2026-10-10: the target is a radio tower; the destroyed target is a ruin, crater and smoke column, no fire, from a board.) The standing tower is the unit sheet's.",
		"source": "scripts/fx/fx_board_strike.gd (what=tower) over the real map (terrain provider) at 2 px/m; the tower is drawn from reference/mockups/unit_sheet.html's radio tower model (scripts/fx/fx_ruin.gd, the same seed as the unit marker's), the ruin is FxLayer.ruin",
		"intro": "The tower (12 m; the unit sheet's 25 m lattice mast, base 6 m, hut beside it with the side's recognition panel on its roof) is destroyed at 0 s. Row a: the moment and the fall (zoom 1.0); row b: the smoke and what stays; row c: the planning view; row d: before and after, close (zoom 1.0 and 2.0, the closest the camera goes). The tank (6 m) and the second plane are for scale. The smoke is the damage smoke (W1). Sun from the NW, shadows 44%. NO FIRE. ALL OPTIONS ARE PROPOSED; none is chosen.",
		"held": {"scene": "a radio tower (the sheet's variant 0) at the world layout's tower site, in the village compound, heading 0, destroyed at game time 100; side A", "light": "sun azimuth 315, elevation 46; shadow strength 0.44", "pen": "shadow side", "fire": "none"},
		"recommendation": {"option": "R1", "_proposed": true, "_reason": "PROPOSED by Track X2, not Alex's call: R1 is the one that reads as THE TOWER destroyed: the same lattice (the unit sheet's) tips and lies broken, snapped in two places, beside a roofless hut, bent leg stumps, cracked footings, a crater and scorch, under a column of smoke that thins over eighteen turns. R2 (blown apart) is the cheapest to read as violence; R3 adds one leg left standing; R4 is the quietest (a burnt mark) and reads best at the planning view."},
	}, names, data, specimens)

# A world heading (radians, 0 east, clockwise on the screen) as the nearest of eight winds.
func _compass(rad: float) -> String:
	var names := ["east", "south-east", "south", "south-west", "west", "north-west", "north", "north-east"]
	return names[posmod(roundi(rad_to_deg(rad) / 45.0), 8)]

func _tower_rows(name: String) -> Array:
	var P := TOWER
	var tank := _tank(P + Vector2(30.0, 24.0))
	var ref := _ref_plane(P + Vector2(-55.0, -60.0), 120.0)
	var standing := [{"pos": P, "heading": 0.0, "side": "side_a"}]
	var probe := FxFieldScratch.new(fxd)
	probe.f.select_strike("", "", name)
	probe.f.clear()
	probe.f.ruin("t1", P, T0, "radio_tower", 12.0, 0.0)
	var fall: float = float(probe.f.ruins[0]["fall_rad"])
	var c_fall := P + Vector2.from_angle(fall) * 8.0
	var setup := func() -> void:
		_fx_reset()
		rig.fx.select_strike("", "", name)
		rig.fx.ruin("t1", P, T0, "radio_tower", 12.0, 0.0)
	var rows: Array = []
	var a_frames: Array = []
	for c in [[-0.5, "before: the tower stands"], [0.0, "0 s: the blast"], [0.1, "0.1 s"], [0.3, "0.3 s"], [0.6, "0.6 s: the mast tips"], [1.0, "1 s"], [1.4, "1.4 s"], [2.0, "2 s: it is down"]]:
		var dt: float = c[0]
		a_frames.append(_frame(dt, 1.0, c_fall, [tank, ref], str(c[1]), standing if dt < 0.0 else []))
	rows.append(_row("moment", "a. THE MOMENT AND THE COLLAPSE (the mast falls toward the %s in this seed)" % _compass(fall), CROP, setup, a_frames, 4))
	var b_frames: Array = []
	for c in [[3.0, "3 s"], [5.0, "one turn later"], [10.0, "two turns later"], [20.0, "four turns later"], [40.0, "eight turns later"], [80.0, "sixteen turns later"], [120.0, "twenty-four turns later"], [200.0, "forty turns later: what stays"]]:
		b_frames.append(_frame(float(c[0]), 1.0, c_fall + Vector2(14.0, -10.0), [tank], str(c[1])))
	rows.append(_row("after", "b. THE SMOKE COLUMN THINS OVER TURNS, AND WHAT STAYS (the wind carries the smoke to the east)", CROP, setup, b_frames, 4))
	var c_frames: Array = []
	for c in [[5.0, "one turn later"], [15.0, "three turns later"], [30.0, "six turns later"], [60.0, "twelve turns later"], [100.0, "twenty turns later"], [200.0, "forty turns later"]]:
		c_frames.append(_frame(float(c[0]), 0.35, P + Vector2(70.0, -15.0), [], str(c[1])))
	rows.append(_row("far", "c. AT THE PLANNING VIEW: the column and the dark mark under it", WIDE, setup, c_frames, 1))
	var d_frames: Array = []
	d_frames.append(_frame(-3.0, 1.0, P + Vector2(2.0, 0.0), [tank], "before, close", standing))
	d_frames.append(_frame(200.0, 1.0, c_fall + Vector2(-2.0, 0.0), [tank], "after: the ruin"))
	d_frames.append(_frame(-3.0, 2.0, P + Vector2(2.0, 0.0), [tank], "before, closest", standing))
	d_frames.append(_frame(200.0, 2.0, c_fall + Vector2(-2.0, 0.0), [tank], "after: the ruin, closest"))
	rows.append(_row("detail", "d. BEFORE AND AFTER, CLOSE: the tower and what is left of it, at the camera's two nearest zooms", CROP, setup, d_frames, 3))
	return rows
