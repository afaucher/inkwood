extends SceneTree

# BOARD: HOW WATER LOOKS (Track WB, 2026-10-10). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed --resolution 1280x720 `
#       --script res://scripts/ui/boards/water_board_shot.gd -- [out=variants/water] [reuse=1] [seed=20261009]
#
# Alex (decisions water-stepped-depth and water-layer, 2026-10-10): "I like the same height system with a blue color wash. Same
# shadows." Water is stepped washes on the land's own height system, three depth steps (shallows, shelf, deep at -3, -10, -30 m),
# GENERATED from the seed. This board asks HOW the steps are drawn, over the generated water of seed 20261009
# (scripts/world/water_gen.gd: a sea on one edge, a river that crosses the village's road), with the game's own drawing layer
# (InkCanvas, the terrain's levels, contours and shadows, the village's road and fields, the trees and houses, the markers):
#
#   A  stepped wash, an ink line at each depth step        D  stepped wash, ink ripple lines along the shore
#   B  stepped wash, no step lines, an inked shoreline     E  a smooth gradient, for comparison (the reference's way)
#   C  stepped wash, a soft shore and a pale band on land  F  stepped wash, pale (paper-coloured) step edges, no ink
#
# Every option is photographed over the SAME pieces (scripts/ui/boards/water_frame.gd makes the ground, the masks, the sprites and
# the shadow classes once per view and records each option over them), at the planning zoom 0.35 and at zoom 1, in four subjects:
#   coast     the sea's shore: the three steps, a cliff, trees on the beach, shadows on the water
#   river     where the river crosses the village's road (no bridge yet: the road stops at the bank)
#   shadows   trees and houses on a bank (PLACED for the board, not generated) and a plane, casting onto the water
#   markers   the game's own unit markers over the three steps: three of the player's (brick red) and three of the enemy's (slate blue)
# and a palette row re-photographs the coast and the markers at three hues.
#
# Output (out=): board.png (the sheet: crops 1:1 of the frames, a palette strip, the generator's overview of six seeds),
# frames/<option>_<subject>_<zoom>.png (every frame whole, 1280 x 720, native size), frames/pal_<hue>_*.png, frames/overview_*.png,
# frames.json (every frame's file, look, zoom and a caption), board.json (the seed, the switches per option, the numbers, "chosen": null).
#
# EVERY OPTION AND VALUE IS PROPOSED by Track WB; none is a decision.

const WaterGen = preload("res://scripts/world/water_gen.gd")
const WaterFrame = preload("res://scripts/ui/boards/water_frame.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UiSelection = preload("res://scripts/ui/ui_selection.gd")
const UnitMarkerLayer = preload("res://scripts/ui/unit_marker_layer.gd")
const World = preload("res://scripts/sim/world.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")

const SIZE := Vector2i(1280, 720)
const LETTERS := ["A", "B", "C", "D", "E", "F"]
const ZOOMS := [{"id": "035", "zoom": 0.35, "label": "planning zoom 0.35"}, {"id": "1", "zoom": 1.0, "label": "zoom 1"}]
const CROP := Vector2i(400, 250)
const OVERVIEW_SEEDS := [20261009, 4, 5, 6, 7, 20]
const OVERVIEW_PX := 330

var out_dir := "variants/water"
var seed_value := 20261009
var reuse := false
var water: WaterGen = null
var wf: WaterFrame = null
var style: UiStyle = null
var base_dir := ""
var frames: Array = []                 # frames.json records
var crops: Dictionary = {}             # "<option>|<subject>|<zoom>" -> Image (the sheet's crop)
var pal_crops: Dictionary = {}         # "<variant>|<what>|<zoom>" -> Image
var subject_info: Dictionary = {}      # subject id -> {focus, ...}
var failures := 0
var survey: Dictionary = {}
var overview_imgs: Array = []

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			match kv[0]:
				"out": out_dir = kv[1]
				"reuse": reuse = kv[1] == "1"
				"seed": seed_value = int(kv[1])
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[water-board] ", msg)

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[water-board] needs a windowed run")
		quit(1)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(SIZE)
	root.size = SIZE
	await _frames(6)
	base_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base_dir.path_join("frames"))
	var t0 := Time.get_ticks_msec()
	water = WaterGen.new(seed_value)
	if not water.ok():
		printerr("[water-board] the water does not build: ", water.errors)
		quit(1)
		return
	wf = WaterFrame.new(water)
	if not wf.errors.is_empty():
		printerr("[water-board] frame errors: ", wf.errors)
		quit(1)
		return
	style = UiStyle.shared() as UiStyle
	_say("water of seed %d built in %.1f s: %s" % [seed_value, (Time.get_ticks_msec() - t0) / 1000.0, str(water.diagnostics.get("sea", {}))])
	_plan_subjects()
	# the options x subjects x zooms
	for subj: String in ["coast", "river", "shadows", "markers"]:
		for z: Dictionary in ZOOMS:
			await _shoot(subj, z)
	# the palette row: the coast and the markers at three hues, the working default option
	await _palette_row()
	await _overview()
	_survey()
	await _sheet()
	_write_frames_json()
	_write_board_json()
	_say("done in %.0f s, %d failures" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
	quit(1 if failures > 0 else 0)

# --- the subjects ----------------------------------------------------------------------------------------------

# Where each subject looks (metres), what is placed for it, and which markers fly in it.
func _plan_subjects() -> void:
	var lay: RefCounted = water.layout()
	var village: Vector2 = lay.village().centre
	var cross: Vector2 = water.river_crossing
	# THE COAST: a stretch of the sea's east shore on low ground, the three steps in a row
	var shore := _find_shore(Vector2(3930, 2600))
	subject_info["coast"] = {"focus": Vector2(shore.x + 140.0, shore.y), "look": Vector2(shore.x + 140.0, shore.y), "look_1": Vector2(shore.x + 55.0, shore.y), "extras": {}, "units": []}
	# THE RIVER at the village's road
	subject_info["river"] = {"focus": cross, "focus_wide": (cross + village) * 0.5, "look": cross, "extras": {}, "units": []}
	# THE BANK: trees, houses and a plane on the bank of the river near the road
	var bank := _bank_scene()
	subject_info["shadows"] = bank
	# THE MARKERS over the three steps, off the shore of the coast
	subject_info["markers"] = _marker_scene(shore)
	_say("subjects: coast at %s, river crossing %s, bank at %s, markers at %s" % [str(subject_info["coast"]["focus"]), str(cross), str(bank.get("look")), str(subject_info["markers"]["focus"])])

# The shore point east of `near` going out to sea: the first wet point along the row.
func _find_shore(near: Vector2) -> Vector2:
	var x := near.x - 200.0
	while x < near.x + 400.0:
		if water.s_at(x, near.y) > 0.0 and int(water.terrain().level_at(x, near.y)) == 0:
			return Vector2(x, near.y)
		x += 2.0
	return near

# The x on the row y, east of x0, where the sea's depth first reaches `s`.
func _x_for_depth(x0: float, y: float, s: float) -> float:
	var x := x0
	while x < x0 + 700.0:
		if water.s_at(x, y) >= s:
			return x
		x += 2.0
	return x0 + 700.0

func _marker_scene(shore: Vector2) -> Dictionary:
	var y := shore.y
	var xs := [_x_for_depth(shore.x, y, 2.5), _x_for_depth(shore.x, y, 11.0), _x_for_depth(shore.x, y, 30.0) + 20.0]
	var units: Array = []
	var names := ["shallows", "shelf", "deep"]
	for k in 3:
		units.append({"id": "p%d" % (k + 1), "side": "allies", "controller": "player", "x": xs[k], "y": y - 22.0, "heading": 0.35, "band": "low", "step": names[k]})
		units.append({"id": "e%d" % (k + 1), "side": "axis", "controller": "ai", "x": xs[k], "y": y + 22.0, "heading": PI - 0.35, "band": "low", "step": names[k]})
	var focus := Vector2((float(xs[0]) + float(xs[2])) * 0.5, y)
	return {"focus": focus, "look": focus, "look_1": Vector2(float(xs[2]), y), "extras": {}, "units": units, "selected": "p3"}

# A bank of the river within reach of the crossing where the sun's shadows run straight across the water, and what to put on it.
func _bank_scene() -> Dictionary:
	var sd: Vector2 = wf.ts.dir
	var pts := water.river_pts
	var best := {}
	var best_score := -INF
	for i in range(2, pts.size() - 2, 2):
		var c := pts[i]
		var hw := water.river_hw[i]
		if c.distance_to(water.river_crossing) > 520.0 or hw < 10.0:
			continue
		var t := (pts[i + 2 if i + 2 < pts.size() else i + 1] - pts[i - 2]).normalized()
		var n := Vector2(-t.y, t.x)
		if n.dot(sd) < 0.0:
			n = -n
		var align := n.dot(sd)
		if align < 0.8:
			continue
		var bank := c - n * (hw + 1.5)
		var ok := true
		for d in [2.0, 8.0, 14.0, 20.0, 28.0]:
			var q: Vector2 = bank - n * d
			if water.is_wet(q.x, q.y) or int(water.terrain().level_at(q.x, q.y)) != 0:
				ok = false
		if not ok:
			continue
		var score := align * 10.0 - c.distance_to(water.river_crossing) / 60.0
		if score > best_score:
			best_score = score
			best = {"i": i, "c": c, "t": t, "n": n, "bank": bank, "hw": hw}
	if best.is_empty():
		_say("no bank with the shadow across the river near the crossing: the board's bank scene is empty")
		return {"focus": water.river_crossing, "look": water.river_crossing, "extras": {}, "units": []}
	var b: Vector2 = best["bank"]
	var n: Vector2 = best["n"]
	var t: Vector2 = best["t"]
	var trees: Array = []
	for k in 5:
		var along := (float(k) - 2.0) * 11.0 + (7.0 if k % 2 == 0 else -3.0)
		var back := 3.5 + 2.5 * float(k % 3)
		var p := b - n * back + t * along
		trees.append([p.x, p.y, 9100 + k * 37])
	var houses: Array = []
	for s: float in [-1.0, 1.0]:
		var p := b - n * 13.0 + t * (s * 24.0)
		houses.append([p.x, p.y, t.angle() + (0.12 if s > 0.0 else -0.1), 7300 + int(s) * 11])
	var plane := (best["c"] as Vector2) + t * 30.0
	var units := [{"id": "p1", "side": "allies", "controller": "player", "x": plane.x, "y": plane.y, "heading": t.angle(), "band": "low", "step": "river"}]
	return {"focus": b + n * 4.0, "look": b + n * 4.0, "extras": {"trees": trees, "houses": houses, "clear": [[b.x, b.y, 120.0]]}, "units": units, "selected": "", "bank": best}

# --- photographing ----------------------------------------------------------------------------------------------

func _look_of(info: Dictionary, zid: String) -> Vector2:
	return info.get("look_" + zid, info["look"])

func _file(letter: String, subj: String, zid: String) -> String:
	return "frames/%s_%s_%s.png" % [letter, subj, zid]

func _all_exist(files: Array) -> bool:
	for f: String in files:
		if not FileAccess.file_exists(base_dir.path_join(f)):
			return false
	return true

# The crop of an image centred on screen point `c` (clamped into the frame).
func _crop_at(img: Image, c: Vector2) -> Image:
	var x := clampi(roundi(c.x) - CROP.x / 2, 0, img.get_width() - CROP.x)
	var y := clampi(roundi(c.y) - CROP.y / 2, 0, img.get_height() - CROP.y)
	return img.get_region(Rect2i(x, y, CROP.x, CROP.y))

func _screen_of(base: WaterFrame.Base, m: Vector2) -> Vector2:
	return base.view * (m * wf.ppm())

func _shoot(subj: String, z: Dictionary) -> void:
	var info: Dictionary = subject_info[subj]
	var zoom: float = z["zoom"]
	var zid: String = z["id"]
	var focus: Vector2 = info["focus"]
	if subj == "river" and zid == "035":
		focus = info["focus_wide"]
	var files: Array = []
	for L: String in LETTERS:
		files.append(_file(L, subj, zid))
	var look: Vector2 = _look_of(info, zid)
	var view := wf.view_of(focus, zoom)
	var look_screen := view * (look * wf.ppm())
	if reuse and _all_exist(files):
		for L: String in LETTERS:
			var img := Image.load_from_file(base_dir.path_join(_file(L, subj, zid)))
			crops["%s|%s|%s" % [L, subj, zid]] = _crop_at(img, look_screen)
			_note_frame(L, subj, z, focus)
		_say("%s at %s: loaded from disk" % [subj, z["label"]])
		return
	var t0 := Time.get_ticks_msec()
	var base := wf.prepare(focus, zoom, info["extras"])
	var overlay: RefCounted = null
	var units: Array = info["units"]
	if not units.is_empty():
		overlay = _Overlay.new(self, units, base.view, zoom * wf.ppm(), style, str(info.get("selected", "")))
		await overlay.build()
	_say("%s at %s: prepared in %.1f s %s" % [subj, z["label"], (Time.get_ticks_msec() - t0) / 1000.0, str(base.counts)])
	for L: String in LETTERS:
		var img: Image = wf.render(base, wf.draw.option(L))
		if overlay != null:
			img = await overlay.shoot(img)
		_save(img, _file(L, subj, zid))
		crops["%s|%s|%s" % [L, subj, zid]] = _crop_at(img, _screen_of(base, look))
		_note_frame(L, subj, z, focus)
	if overlay != null:
		overlay.discard()

func _save(img: Image, rel: String) -> void:
	var err := img.save_png(base_dir.path_join(rel))
	if err != OK:
		failures += 1
		printerr("[water-board] could not write ", rel)

func _note_frame(letter: String, subj: String, z: Dictionary, focus: Vector2) -> void:
	var opt: Dictionary = wf.draw.option(letter)
	frames.append({"file": _file(letter, subj, z["id"]), "option": letter, "subject": subj, "zoom": z["zoom"], "focus_m": [snappedf(focus.x, 0.1), snappedf(focus.y, 0.1)],
		"title": "%s  ·  %s  ·  %s  ·  %s" % [letter, opt.get("title", ""), subj, z["label"]], "size": [SIZE.x, SIZE.y]})

# --- the palette row ------------------------------------------------------------------------------------------------

func _palette_row() -> void:
	var variants: Array = wf.draw.variants
	var default_draw := wf.draw
	var default_letter: String = wf.draw.working_default
	for what: String in ["coast", "markers"]:
		for z: Dictionary in ZOOMS:
			if what == "coast" and z["id"] == "1":
				continue
			var info: Dictionary = subject_info[what]
			var zoom: float = z["zoom"]
			var view := wf.view_of(info["focus"], zoom)
			var look_screen: Vector2 = view * (_look_of(info, z["id"]) * wf.ppm())
			var todo: Array = []
			for v: Dictionary in variants:
				var key := str(v["name"]).replace(" ", "_").replace("(", "").replace(")", "")
				var rel := "frames/pal_%s_%s_%s.png" % [key, what, z["id"]]
				if reuse and FileAccess.file_exists(base_dir.path_join(rel)):
					pal_crops["%s|%s|%s" % [key, what, z["id"]]] = _crop_at(Image.load_from_file(base_dir.path_join(rel)), look_screen)
					_note_pal(rel, default_letter, what, zoom, v, z)
				else:
					todo.append([v, key, rel])
			if todo.is_empty():
				continue
			var base := wf.prepare(info["focus"], zoom, info["extras"])
			var overlay: RefCounted = null
			var units: Array = info["units"]
			if not units.is_empty():
				overlay = _Overlay.new(self, units, base.view, zoom * wf.ppm(), style, str(info.get("selected", "")))
				await overlay.build()
			for t: Array in todo:
				var v: Dictionary = t[0]
				wf.draw = WaterDraw.new(wf.P, float(v["hue_deg"]))
				var img: Image = wf.render(base, wf.draw.option(default_letter))
				if overlay != null:
					img = await overlay.shoot(img)
				_save(img, t[2])
				pal_crops["%s|%s|%s" % [t[1], what, z["id"]]] = _crop_at(img, look_screen)
				_note_pal(t[2], default_letter, what, zoom, v, z)
			wf.draw = default_draw
			if overlay != null:
				overlay.discard()
			_say("palette row: %s at %s done" % [what, z["label"]])
	wf.draw = default_draw

func _note_pal(rel: String, letter: String, what: String, zoom: float, v: Dictionary, z: Dictionary) -> void:
	frames.append({"file": rel, "option": letter, "subject": what, "zoom": zoom, "palette_variant": v["name"], "hue_deg": v["hue_deg"],
		"title": "palette row: hue %d (%s) · option %s · %s · %s" % [int(v["hue_deg"]), v["name"], letter, what, z["label"]], "size": [SIZE.x, SIZE.y]})

# --- the generator's overview of six seeds -----------------------------------------------------------------------------

func _overview() -> void:
	var td := wf.td
	var P := wf.P
	var step: float = td.terrain.data.num("draw.level_fill.ok_lightness_step")
	var chroma: float = td.terrain.data.num("draw.level_fill.chroma_scale_per_step")
	var land: Array[Color] = []
	for k in 3:
		land.append(TerrainDraw.lift(P.PAPER, step * k, pow(chroma, k)))
	var steps: Array[Color] = wf.draw.steps
	var files: Array = []
	for sd: int in OVERVIEW_SEEDS:
		files.append("frames/overview_%d.png" % sd)
	if reuse and _all_exist(files):
		for f: String in files:
			overview_imgs.append(Image.load_from_file(base_dir.path_join(f)))
		return
	for sd: int in OVERVIEW_SEEDS:
		var t0 := Time.get_ticks_msec()
		var w: WaterGen = water if sd == seed_value else WaterGen.new(sd)
		var ter: RefCounted = w.terrain()
		var n := OVERVIEW_PX
		var img := Image.create(n, n, false, Image.FORMAT_RGB8)
		var m: Rect2 = w.map_rect()
		var thr: PackedFloat64Array = ter.thresholds
		for j in n:
			for i in n:
				var x := m.position.x + (float(i) + 0.5) / n * m.size.x
				var y := m.position.y + (float(j) + 0.5) / n * m.size.y
				var f: float = ter.field_at(x, y)
				var lev := 0 if f < thr[0] else (1 if f < thr[1] else 2)
				var s := w.s_at(x, y)
				if s > 0.0 and lev == 0:
					img.set_pixel(i, j, steps[w.step_of(s)])
				else:
					img.set_pixel(i, j, land[lev])
		var lay: RefCounted = w.layout()
		for p: Vector2 in lay.road():
			_dot(img, m, p, P.INK, 0)
		var vp: PackedVector2Array = lay.village().polygon
		for q in vp.size():
			_line(img, m, vp[q], vp[(q + 1) % vp.size()], P.INK)
		_dot(img, m, lay.sites().radio_tower, P.INK, 2)
		for b: Vector2 in lay.sites().aa_battery:
			_dot(img, m, b, P.INK, 1)
		if w.river_crossing.is_finite():
			_ring(img, m, w.river_crossing, 5.0, P.INK)
		_save(img, "frames/overview_%d.png" % sd)
		overview_imgs.append(img)
		_say("overview of seed %d in %.1f s" % [sd, (Time.get_ticks_msec() - t0) / 1000.0])
		await _frames(1)

func _px(img: Image, m: Rect2, p: Vector2) -> Vector2i:
	return Vector2i(int((p.x - m.position.x) / m.size.x * img.get_width()), int((p.y - m.position.y) / m.size.y * img.get_height()))

func _dot(img: Image, m: Rect2, p: Vector2, c: Color, r: int) -> void:
	var q := _px(img, m, p)
	for dj in range(-r, r + 1):
		for di in range(-r, r + 1):
			var a := q.x + di
			var b := q.y + dj
			if a >= 0 and b >= 0 and a < img.get_width() and b < img.get_height():
				img.set_pixel(a, b, c)

func _line(img: Image, m: Rect2, a: Vector2, b: Vector2, c: Color) -> void:
	var n := int(a.distance_to(b) / 12.0) + 1
	for k in n + 1:
		_dot(img, m, a.lerp(b, float(k) / n), c, 0)

func _ring(img: Image, m: Rect2, p: Vector2, r_px: float, c: Color) -> void:
	for k in 24:
		var q := _px(img, m, p) + Vector2i(Vector2.from_angle(float(k) / 24.0 * TAU) * r_px)
		if q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height():
			img.set_pixel(q.x, q.y, c)

# --- the survey (the generator's numbers) ---------------------------------------------------------------------------------

func _survey() -> void:
	var seeds: Array = []
	for s in range(1, 21):
		seeds.append(s)
	var first_dry := 0
	var final_dry := 0
	var rivers := 0
	var sea_river := 0
	var rows: Array = []
	var t0 := Time.get_ticks_msec()
	for sd: int in seeds:
		var w := WaterGen.new(sd)
		var sea: Dictionary = w.diagnostics.get("sea", {})
		var riv: Dictionary = w.diagnostics.get("river", {})
		var d1: bool = sea.get("dry_first_try", false)
		var d2: bool = w.ok() and bool(w.diagnostics.get("keep_dry_ok", false))
		first_dry += 1 if d1 else 0
		final_dry += 1 if d2 else 0
		rivers += 1 if bool(riv.get("made", false)) else 0
		sea_river += 1 if str(riv.get("ends_in", "")) == "sea" else 0
		rows.append({"seed": sd, "sea_edges": sea.get("edges", []), "dry_first_try": d1, "dry_after_adapting": d2, "river": bool(riv.get("made", false)),
			"river_length_m": riv.get("length_m", 0.0), "river_ends_in": riv.get("ends_in", "")})
	survey = {"seeds": "1..20", "dry_first_try": first_dry, "dry_after_adapting": final_dry, "river_crosses_road": rivers, "river_ends_in_sea": sea_river, "rows": rows}
	_say("survey of seeds 1..20 in %.0f s: first choice dry %d, dry after adapting %d, a river %d (%d to the sea)" % [(Time.get_ticks_msec() - t0) / 1000.0, first_dry, final_dry, rivers, sea_river])

# --- the sheet ------------------------------------------------------------------------------------------------------------------

const MARGIN := 24
const GAP := 10

func _sheet() -> void:
	var cols := LETTERS.size()
	var w := MARGIN * 2 + cols * CROP.x + (cols - 1) * GAP
	var row_h := CROP.y + 26
	var head_h := 262
	var rows := 8
	var pal_rows_h := 3 * (CROP.y + 30) + 80
	var strip_h := 800
	var ov_h := OVERVIEW_PX + 150
	var h := head_h + rows * row_h + 70 + pal_rows_h + strip_h + ov_h
	var sh := BoardSheet.new(style, Vector2i(w, h))
	sh.text(Vector2(MARGIN, 36), "How water looks  ·  seed %d, generated by scripts/world/water_gen.gd and drawn by the game's own layer" % seed_value, 26.0, sh.c_text)
	var hy := 50.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "Alex (2026-10-10): \"I like the same height system with a blue color wash. Same shadows.\" Water is stepped washes on the land's own height system: three depth steps below sea level (shallows, shelf, deep; seabed at -3, -10 and -30 m, steps starting at 0, 6 and 18 m of depth), each one flat wash, darker and more saturated with depth. The water SURFACE is flat at sea level, so a shadow falls on it exactly as on level-0 land: scripts/render/terrain_shadows.gd is unchanged and every shadow below is the game's own, the cliff's and the trees' and the houses' and the plane's. Water is generated from the seed (the design doc's premise: an island, a river down to the sea, a road that crosses it): a sea on one or two edges, a river from a spring at the foot of high ground that crosses the village's road once and runs to the sea; the village, the tower, both batteries and the fields stay dry.", 12.5, sh.c_muted, float(w) - MARGIN * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "THIS BOARD asks only HOW the steps are drawn. A to F differ in the water's look and in nothing else: the ground, the trees, the shadows and the markers are the same pixels under every column. Rows: the coast (the three steps, a cliff, trees on the beach); the river at the road (no bridge yet: the road stops at the bank); a bank with trees and two houses PLACED for the board (not generated) and a plane; the markers over the three steps -- the player's brick red (side_a) in the upper row of the cluster, the enemy's slate blue (side_b) in the lower, over shallows, shelf and deep, the deep one's marker selected (its ring). Each row is shown at the planning zoom 0.35 and at zoom 1; crops are 1:1 from the native frames (frames/<option>_<subject>_<zoom>.png, 1280 x 720).", 12.0, sh.c_muted, float(w) - MARGIN * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "PROPOSED by Track WB, nothing chosen (chosen: null): the working default in data/world/water.json is A, the most literal reading of 'the same height system': the land's contours go on under the water as lines, fainter with depth. F is the one more: the steps are divided by a thin paper-coloured line, so nothing dark competes with the planes' ink or the enemy's accent on the water. The palette strip and the six-seed overview of the generator are below.", 12.0, sh.c_muted, float(w) - MARGIN * 2.0, true)
	var y := float(head_h)
	var letters_y := y - 22.0
	for c in cols:
		var L: String = LETTERS[c]
		var opt: Dictionary = wf.draw.option(L)
		var x := MARGIN + c * (CROP.x + GAP)
		sh.text(Vector2(x, letters_y), "%s  ·  %s" % [L, _short(str(opt.get("title", "")), 44)], 13.0, sh.c_text)
	var order := [["coast", "035"], ["coast", "1"], ["river", "035"], ["river", "1"], ["shadows", "035"], ["shadows", "1"], ["markers", "035"], ["markers", "1"]]
	var captions := {
		"coast|035": "the coast, planning zoom 0.35: the beach, the three steps out to deep water (shallows, shelf, deep), an islet; the frame's own cliffs and their shadows on the water are in the whole frames",
		"coast|1": "the coast, zoom 1: the beach, the shallows and the start of the shelf, trees' shadows on the water",
		"river|035": "the river at the village's road, planning zoom 0.35 (the village is at the right of the frame's middle): the road stops at the bank",
		"river|1": "the river at the road, zoom 1: 26 m wide, shallows banks and a shelf in the middle, trees on both banks",
		"shadows|035": "a bank with trees, two houses and a plane (PLACED for the board), planning zoom 0.35: shadows fall across the river",
		"shadows|1": "the same bank at zoom 1",
		"markers|035": "the game's markers over shallows, shelf and deep, planning zoom 0.35: the player's (brick red) above, the enemy's (slate blue) below",
		"markers|1": "the markers at zoom 1: the deep-water pair -- the player's (selected: its ring) and the enemy's -- the worst case for the enemy's colour; the shallows and shelf pairs are in the whole frames",
	}
	for r in order.size():
		var subj: String = order[r][0]
		var zid: String = order[r][1]
		sh.text(Vector2(MARGIN, y + 14), captions["%s|%s" % [subj, zid]], 12.0, sh.c_muted, true)
		for c in cols:
			var L: String = LETTERS[c]
			var x := MARGIN + c * (CROP.x + GAP)
			var img: Image = crops["%s|%s|%s" % [L, subj, zid]]
			sh.image(img, Vector2(x, y + 20))
			sh.rect(Rect2(Vector2(x, y + 20), Vector2(22, 18)), sh.c_page)
			sh.text(Vector2(x + 6, y + 34), L, 13.0, sh.c_text)
		y += row_h
	# the palette row
	y += 14.0
	sh.line(Vector2(MARGIN, y), Vector2(float(w) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 24), "The palette row: the working default look (%s) at three hues -- the coast at 0.35, and the markers at 0.35 and at zoom 1" % wf.draw.working_default, 17.0, sh.c_text)
	y += 38.0
	var pv: Array = wf.draw.variants
	for vi in pv.size():
		var v: Dictionary = pv[vi]
		var key := str(v["name"]).replace(" ", "_").replace("(", "").replace(")", "")
		var x := MARGIN
		sh.text(Vector2(x, y + 11), "hue %d  ·  %s" % [int(v["hue_deg"]), v["name"]], 12.0, sh.c_text)
		for what: Array in [["coast", "035"], ["markers", "035"], ["markers", "1"]]:
			var img: Image = pal_crops.get("%s|%s|%s" % [key, what[0], what[1]])
			if img != null:
				sh.image(img, Vector2(x, y + 18))
			x += CROP.x + GAP
		# the three steps of this hue, beside
		var d2 := WaterDraw.new(wf.P, float(v["hue_deg"]))
		for k in 3:
			var c: Color = d2.steps[k]
			sh.chip(Vector2(x + 14 + k * 150, y + 30), c, ["shallows", "shelf", "deep"][k], BoardSheet.oklch_text(c), Vector2(120, 46))
		sh.paragraph(Vector2(x + 14, y + 130), _hue_note(d2), 11.5, sh.c_muted, float(w) - x - MARGIN - 20.0, true)
		y += CROP.y + 30.0
	# the strip
	_palette_strip(sh, Vector2(MARGIN, y + 20.0), float(w) - MARGIN * 2.0)
	var oy := y + 20.0 + float(strip_h)
	sh.line(Vector2(MARGIN, oy), Vector2(float(w) - MARGIN, oy), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, oy + 24), "What the generator does on other seeds (the whole 5 km map, one frame a seed; land lifted by level, water in the three steps, the village's outline, its road, the tower and the batteries in ink, a ring where the river crosses the road)", 15.0, sh.c_text)
	var ox := float(MARGIN)
	for i in OVERVIEW_SEEDS.size():
		var sd: int = OVERVIEW_SEEDS[i]
		sh.image(overview_imgs[i], Vector2(ox, oy + 40))
		sh.text(Vector2(ox, oy + 40 + OVERVIEW_PX + 16), "seed %d" % sd, 12.0, sh.c_text)
		ox += OVERVIEW_PX + 12
	var sv: Dictionary = survey
	sh.paragraph(Vector2(MARGIN, oy + 40 + OVERVIEW_PX + 30), "Seeds 1 to 20: the first choice of sea (edges picked by seed, never the edge the village's road leaves by) already left the village, the tower, both batteries, the fields and the road dry on %d of 20; after the generator shrinks a sea that would flood one (or drops its edge) it is %d of 20. A river that crosses the road once: %d of 20 (%d end in the sea; the rest leave by a map edge or are absent where no crossing keeps the layout dry). Seed %d: dry on the first try, every site dry." % [
		int(sv["dry_first_try"]), int(sv["dry_after_adapting"]), int(sv["river_crosses_road"]), int(sv["river_ends_in_sea"]), seed_value], 12.0, sh.c_muted, float(w) - MARGIN * 2.0, true)
	var err: int = await sh.save(self, base_dir.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[water-board] could not write board.png: ", error_string(err))
	else:
		_say("saved board.png (%d x %d)" % [w, h])

func _short(s: String, n: int) -> String:
	return s if s.length() <= n else s.substr(0, n - 1) + "…"

func _hue_note(d: WaterDraw) -> String:
	var shadow: Color = wf.P.shadowCol
	var sh_lch := BoardSheet.oklch(shadow)
	var b: Color = style.palette["side_b"]
	var b_lch := BoardSheet.oklch(b)
	var deep: Color = d.steps[2]
	return "hue %d: %d degrees from the shadow tint (%d) and %d from the slate-blue accent (%d); deep step against the accent: OKLab distance %.3f (lightness %.3f against %.3f)." % [
		int(d.hue_deg), int(round(absf(angle_difference(deg_to_rad(d.hue_deg), deg_to_rad(sh_lch.z))) * 180.0 / PI)), int(sh_lch.z),
		int(round(absf(angle_difference(deg_to_rad(d.hue_deg), deg_to_rad(b_lch.z))) * 180.0 / PI)), int(b_lch.z),
		BoardSheet.delta_ok(deep, b), BoardSheet.oklch(deep).x, b_lch.x]

# The palette strip (working rule 6: every art choice includes the palette).
func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette: paper, ink, the shadow tint, both side accents, and each option's water steps (OKLCH: lightness, chroma, hue)", 17.0, sh.c_text)
	var P := wf.P
	var paper := P.PAPER
	var ink := P.INK
	var shadow := P.shadowCol
	var side_a: Color = style.palette["side_a"]
	var side_b: Color = style.palette["side_b"]
	var d := wf.draw
	var s0 := d.steps[0]
	var s1 := d.steps[1]
	var s2 := d.steps[2]
	var x := pos.x
	var yy := pos.y + 44.0
	var base: Array = [["paper", paper], ["ink", ink], ["shadow tint", shadow], ["side_a (yours)", side_a], ["side_b (theirs)", side_b]]
	for c: Array in base:
		sh.chip(Vector2(x, yy), c[1], str(c[0]), BoardSheet.oklch_text(c[1]))
		x += 150.0
	x += 20.0
	var names := ["shallows", "shelf", "deep"]
	for k in 3:
		sh.chip(Vector2(x, yy), d.steps[k], "water: %s" % names[k], BoardSheet.oklch_text(d.steps[k]))
		x += 150.0
	x += 20.0
	for k in 3:
		var shaded := BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, P.shadowStr), d.steps[k])
		sh.chip(Vector2(x, yy), shaded, "shadow on %s" % names[k], BoardSheet.oklch_text(shaded))
		x += 150.0
	# each option's water steps
	var oy := yy + 100.0
	sh.text(Vector2(pos.x, oy), "each option's water", 13.0, sh.c_text)
	oy += 14.0
	var ink_on: Array = []
	for L: String in LETTERS:
		var opt: Dictionary = d.option(L)
		var ox := pos.x
		sh.text(Vector2(ox, oy + 16), "%s" % L, 14.0, sh.c_text)
		ox += 26.0
		var seq: Array = []
		if str(opt.get("mode", "stepped")) == "smooth":
			var a := BoardSheet.over(Color(s1.r, s1.g, s1.b, 0.5), s0)
			var b2 := BoardSheet.over(Color(s2.r, s2.g, s2.b, 0.5), s1)
			seq = [s0, a, s1, b2, s2]
		else:
			seq = [s0, s1, s2]
			if bool(opt.get("soft", false)):
				seq.push_front(BoardSheet.over(Color(s0.r, s0.g, s0.b, 0.5), paper))
				seq.push_front(wf.draw.halo_color)
		if bool(opt.get("pale_edges", false)):
			seq.append(WaterDraw.oklch_color(d.paper_lab.x - 0.11 + d.pale_lift, 0.05, d.hue_deg))
		if bool(opt.get("shore_line", false)) or bool(opt.get("step_lines", false)):
			seq.append(BoardSheet.over(Color(ink.r, ink.g, ink.b, d.ink_alpha), s0))
		if bool(opt.get("step_lines", false)):
			seq.append(BoardSheet.over(Color(ink.r, ink.g, ink.b, d.step_alphas[1]), s1))
			seq.append(BoardSheet.over(Color(ink.r, ink.g, ink.b, d.step_alphas[2]), s2))
		if bool(opt.get("ripples", false)):
			seq.append(BoardSheet.over(Color(ink.r, ink.g, ink.b, d.ripple_alphas[0]), s0))
		for c2: Color in seq:
			sh.rect(Rect2(Vector2(ox, oy), Vector2(70, 24)), c2)
			sh.text(Vector2(ox, oy + 38), "%.2f/%.3f" % [BoardSheet.oklch(c2).x, BoardSheet.oklch(c2).y], 10.5, sh.c_muted)
			ox += 78.0
		var tag := ""
		if bool(opt.get("soft", false)) and str(opt.get("mode", "stepped")) != "smooth":
			tag = "pale band, soft shore edge, shallows, shelf, deep"
		elif str(opt.get("mode", "stepped")) == "smooth":
			tag = "pale band, shore, then the gradient's five stops"
		elif bool(opt.get("pale_edges", false)):
			tag = "shallows, shelf, deep, the pale step edge"
		elif bool(opt.get("step_lines", false)):
			tag = "three steps, then ink over each step: shore, shelf edge, deep edge"
		elif bool(opt.get("ripples", false)):
			tag = "three steps, then the first ripple line's ink"
		else:
			tag = "three steps, then the inked shoreline"
		sh.text(Vector2(ox + 10, oy + 16), tag, 11.5, sh.c_muted, true)
		oy += 56.0
		ink_on.append(L)
	# the numbers
	var ty := oy + 10.0
	var steps_lch: Array = []
	for k in 3:
		steps_lch.append(BoardSheet.oklch(d.steps[k]))
	var sh_lch := BoardSheet.oklch(shadow)
	var a_lch := BoardSheet.oklch(side_a)
	var b_lch := BoardSheet.oklch(side_b)
	var p_lch := BoardSheet.oklch(paper)
	var lines: Array = []
	lines.append("ONE PALETTE. The water hue is new (%d degrees) and the only thing the palette gains is a lightness ramp BELOW the paper and one chroma ramp on that one hue: shallows L %.3f C %.3f, shelf L %.3f C %.3f, deep L %.3f C %.3f (the paper is L %.3f, so the water is the paper less %.2f, %.2f, %.2f of lightness, as the land lifts off it by +0.025 a level). Three blues, kept apart on all three axes: HUE water %d, shadow tint %d (a steel blue that is only ever a shade mixed in at 0.44), the enemy's slate blue %d; CHROMA water %.3f to %.3f, shadow %.3f, accent %.3f -- the water is the quietest blue in the drawing, the accent the loudest; LIGHTNESS water %.3f to %.3f, accent %.3f, shadow tint %.3f, ink %.3f, so the darkest water is still lighter than anything that is meant to be read on it." % [
		int(d.hue_deg), steps_lch[0].x, steps_lch[0].y, steps_lch[1].x, steps_lch[1].y, steps_lch[2].x, steps_lch[2].y, p_lch.x,
		p_lch.x - steps_lch[0].x, p_lch.x - steps_lch[1].x, p_lch.x - steps_lch[2].x, int(d.hue_deg), int(sh_lch.z), int(b_lch.z),
		steps_lch[0].y, steps_lch[2].y, sh_lch.y, b_lch.y, steps_lch[2].x, steps_lch[0].x, b_lch.x, sh_lch.x, BoardSheet.oklch(ink).x])
	var dist_rows: Array = []
	for k in 3:
		dist_rows.append("%s: enemy accent %.3f, player accent %.3f, ink %.3f" % [names[k], BoardSheet.delta_ok(d.steps[k], side_b), BoardSheet.delta_ok(d.steps[k], side_a), BoardSheet.delta_ok(d.steps[k], ink)])
	lines.append("THE KEY RISK, the enemy's slate blue (side_b, L %.3f C %.3f h %d) on blue water. OKLab distance of each step from the accent, from the player's brick red and from the ink (0.02 is just noticeable, 0.1 plainly different) -- %s. The enemy is least legible over the DEEP step (%.3f), the player's red is separated from every step by hue (blue against red-orange). The plane itself (cream fill, ink outline: L 0.925 and 0.325) reads on every step; it is the accent -- the roundels and the side badge -- that sits near the deep water. The accent's lightness (%.3f) is darker than every step, so it reads as the DARKER, MORE CHROMATIC thing on the water, never lost in it; shadows on water: the shadow tint at the map's strength 0.44 moves a step by dL %.3f (shallows), %.3f (shelf), %.3f (deep) -- a shadow is readable on all three and weakest on the deep." % [
		b_lch.x, b_lch.y, int(b_lch.z), " | ".join(dist_rows), BoardSheet.delta_ok(d.steps[2], side_b), b_lch.x,
		BoardSheet.oklch(BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, P.shadowStr), s0)).x - steps_lch[0].x,
		BoardSheet.oklch(BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, P.shadowStr), s1)).x - steps_lch[1].x,
		BoardSheet.oklch(BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, P.shadowStr), s2)).x - steps_lch[2].x])
	lines.append("HOW EACH OPTION HANDLES THE MARKERS. A: ink lines run across the water at each step's top (alpha 0.55 and 0.4, hairlines at 0.35): a marker over a step edge has a faint ink line under its badge, but the marker's own ink outline and the accent are untouched; the lines add linework noise round a cluster. B: one inked shoreline and flat washes: the quietest ground for a marker once it is off the shore. C: the shore melts into the ground and a pale band lifts the land at the water's edge: a marker near the shore sits on a LIGHTER, lower-chroma ground (the accent gains contrast there) and the soft edge has no line to cross it; a river is only softened by 3 m, so it stays readable. D: three broken ink ripple lines along the shore, out to 26 m: they cross markers only in the shallows near the beach; the deep step is clean. E: no edges at all, the steps blend over about 60 m: the cleanest ground, but the 'which step am I over' information is a gradient and the shore is a blur. F: pale paper-coloured step edges and no ink on the water: nothing dark competes with the planes' ink or the accent anywhere, and the only line is where one step meets the next (lighter, never darker, than the water).")
	for l: String in lines:
		ty += sh.paragraph(Vector2(pos.x, ty), l, 12.0, sh.c_muted, width - 20.0, false, 3.0) + 8.0

# --- the records ------------------------------------------------------------------------------------------------------------------

func _write_frames_json() -> void:
	var f := FileAccess.open(base_dir.path_join("frames.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		return
	f.store_string(JSON.stringify({"id": "water", "about": "Every frame of the board as its own PNG at native size (1280 x 720), in frames/: <option>_<subject>_<zoom>.png (zoom 035 is the planning zoom 0.35), the palette row's pal_<hue>_*.png, and the generator's overview_<seed>.png (one frame a seed, the whole 5 km map). board.png is the sheet of 1:1 crops of these.", "frames": frames}, "  ", false))
	f.close()
	_say("saved frames.json")

func _write_board_json() -> void:
	var d := wf.draw
	var opts: Array = []
	for L: String in LETTERS:
		var o: Dictionary = (d.option(L) as Dictionary).duplicate(true)
		var files: Array = []
		for subj: String in ["coast", "river", "shadows", "markers"]:
			for z: Dictionary in ZOOMS:
				files.append(_file(L, subj, z["id"]))
		opts.append({"name": L, "title": o.get("title", ""), "switches": o, "files": files, "proposed": true, "working_default": L == d.working_default})
	var shadow := wf.P.shadowCol
	var steps_lch: Array = []
	for k in 3:
		var c := BoardSheet.oklch(d.steps[k])
		steps_lch.append({"step": ["shallows", "shelf", "deep"][k], "L": snappedf(c.x, 0.001), "C": snappedf(c.y, 0.001), "h": snappedf(c.z, 0.1)})
	var tint := BoardSheet.oklch(shadow)
	var sa := BoardSheet.oklch(style.palette["side_a"])
	var sb := BoardSheet.oklch(style.palette["side_b"])
	var paper := BoardSheet.oklch(wf.P.PAPER)
	var dist := {}
	for k in 3:
		dist[["shallows", "shelf", "deep"][k]] = {"to_side_b": snappedf(BoardSheet.delta_ok(d.steps[k], style.palette["side_b"]), 0.001), "to_side_a": snappedf(BoardSheet.delta_ok(d.steps[k], style.palette["side_a"]), 0.001)}
	var doc := {
		"id": "water",
		"date": "2026-10-10",
		"area": "Terrain, Water",
		"question": "How does water look: stepped washes on the land's own height system, three depth steps, the same shadows? Alex (decisions water-stepped-depth, water-layer): 'I like the same height system with a blue color wash. Same shadows.'",
		"source": "scripts/ui/boards/water_board_shot.gd: the generated water of seed %d (scripts/world/water_gen.gd, data/world/water.json) drawn by scripts/ui/boards/water_frame.gd and scripts/render/water_draw.gd over the game's own drawing layer (ink_ground, terrain_draw, terrain_shadows, village_draw, ink_sprites, ink_structs, the unit markers); NOT wired into the chunk baker or the terrain provider" % seed_value,
		"seed": seed_value,
		"held_constant": {
			"ground": "the terrain's levels, contours, hachures and shadows, the village's road and fields, trees (never on water) and houses are identical under every option; only data/world/water.json draw.options switches change between the six columns",
			"shadows": "the water surface is flat at sea level, so shadows land on it as on level-0 land: scripts/render/terrain_shadows.gd is unchanged. Shadow strength 0.44, steel tint.",
			"placed_for_the_board": "the bank scene's five trees and two houses and the plane (not generated); the six markers of the markers row",
			"depth_steps": {"from_m": [0, 6, 18], "seabed_heights_m": [-3, -10, -30], "decision": "water-layer"},
			"zooms": "0.35 (the planning zoom) and 1.0",
		},
		"parameter": "data/world/water.json (generator and draw.*: every value a proposed record but the three depths); draw.options is each option's switches, draw.working_default the option the data defaults to",
		"options": opts,
		"palette_check": {
			"water_hue_deg": d.hue_deg,
			"steps_oklch": steps_lch,
			"shadow_tint_oklch": {"L": snappedf(tint.x, 0.001), "C": snappedf(tint.y, 0.001), "h": snappedf(tint.z, 0.1)},
			"side_a_oklch": {"L": snappedf(sa.x, 0.001), "C": snappedf(sa.y, 0.001), "h": snappedf(sa.z, 0.1)},
			"side_b_oklch": {"L": snappedf(sb.x, 0.001), "C": snappedf(sb.y, 0.001), "h": snappedf(sb.z, 0.1)},
			"paper_oklch": {"L": snappedf(paper.x, 0.001), "C": snappedf(paper.y, 0.001), "h": snappedf(paper.z, 0.1)},
			"oklab_distance_of_step_to_accent": dist,
			"how_it_stays_one_palette": "Hue is reserved for paper, ink, shadow and accents; the water adds one hue (%d degrees) but only as a lightness ramp BELOW the paper (the paper less 0.03, 0.11 and 0.20) with a chroma that stays under the shadow tint's and the accents': water is the quietest blue. It is 20 degrees from the shadow tint and 38 from the enemy accent. Colours are roles in data/world/water.json (OKLCH numbers off the paper, resolved in scripts/render/water_draw.gd), never hex in draw code." % int(d.hue_deg),
		},
		"generator": {
			"sea": "landness = base + noise + terrain field - edge bias; the sea is where it is below zero; one or two ADJACENT sea edges by seed, never the edge the village's road leaves by; uplands are never water (a coastal cliff, or an islet)",
			"river": "from a spring at the foot of high ground, routed on a 40 m grid that avoids the village, the fields, the tower and the batteries and does not climb a scarp, square across the village's road once, to the sea; width and depth grow downstream (26 m at the road)",
			"seed_20261009": water.diagnostics,
			"survey_seeds_1_to_20": survey,
		},
		"recommendation_proposed": "A, the working default in data (PROPOSED, not Alex's): see the sheet",
		"frames": "frames.json (every frame whole, with its caption)",
		"sheet": "board.png (rows: coast, river, bank, markers at 0.35 and 1; the palette row; the palette strip; the generator's overview of six seeds)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(base_dir.path_join("board.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[water-board] could not write board.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved board.json")

# --- the markers over a frame -------------------------------------------------------------------------------------------------------

# The game's own unit markers (scripts/ui/unit_marker_layer.gd: the plane in ink with its accent roundels, its shadow, the side badge, the selected ring)
# over a frame, through the same world-to-screen mapping the game gives them.
class _Overlay extends RefCounted:
	var host: SceneTree
	var vp: SubViewport = null
	var bg: TextureRect = null
	var layer: Node2D = null
	var units: Array
	var view: Transform2D
	var k: float
	var style: Object
	var selected: String

	func _init(h: SceneTree, u: Array, v: Transform2D, px_per_m: float, st: Object, sel: String) -> void:
		host = h
		units = u
		view = v
		k = px_per_m
		style = st
		selected = sel

	func build() -> void:
		var w := World.new()
		w.add_player("local")
		for u: Dictionary in units:
			var id: String = w.add_unit({"id": u["id"], "type": "light_fighter", "side": u["side"], "controller": u["controller"], "x": u["x"], "y": u["y"],
				"heading": u["heading"], "altitude_band": u.get("band", "medium")})
			if id == "":
				printerr("[water-board] could not add unit ", u["id"])
		vp = SubViewport.new()
		vp.size = Vector2i(1280, 720)
		vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		host.root.add_child(vp)
		bg = TextureRect.new()
		bg.stretch_mode = TextureRect.STRETCH_KEEP
		bg.size = Vector2(1280, 720)
		vp.add_child(bg)
		var sel := UiSelection.new()
		layer = UnitMarkerLayer.new()
		vp.add_child(layer)
		var xf := Transform2D(Vector2(k, 0.0), Vector2(0.0, k), view.origin)
		layer.call("setup", w, xf, sel)
		if selected != "":
			sel.select(selected)
		for _i in 4:
			await host.process_frame

	func shoot(img: Image) -> Image:
		bg.texture = ImageTexture.create_from_image(img)
		for _i in 3:
			await host.process_frame
		layer.call("update_poses")
		await host.process_frame
		await RenderingServer.frame_post_draw
		var out := vp.get_texture().get_image()
		out.convert(Image.FORMAT_RGBA8)
		return out

	func discard() -> void:
		if vp != null:
			vp.queue_free()
			vp = null
