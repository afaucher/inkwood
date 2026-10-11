extends SceneTree

# THE SHAPE OF THE SEA, AFTER ALEX'S NOTE (Track WB, 2026-10-10). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed --resolution 1280x720 `
#       --script res://scripts/ui/boards/water_shape_shot.gd -- [out=variants/water] [reuse=1] [seed=20261009] [only=overview|coast]
#
# Alex (2026-10-10), on the generator: "the seeds are too uniform. It looks like a big square of land." The sea's shape is
# reworked (scripts/world/water_gen.gd: domain-warped noise, six archetypes, deliberate islands, uplands that fade into the sea
# through a mask the terrain reads) and this photographs it:
#
#   frames/overview_<seed>.png   the whole 5 km map of 12 seeds (20261009 and 1 to 11), one frame a seed, from the generator's own
#                                numbers (land lifted by the CAPPED terrain's level, water in the three steps in the chosen hue 222,
#                                the village's outline, its road, the tower and the river's crossing in ink)
#   frames/<A..F>_coast_<035|1>.png  the coast of seed 20261009 in the decided look A (and the five others, so the folder agrees
#                                with itself), at the planning zoom 0.35 and at zoom 1, drawn by the game's own layer over the
#                                CAPPED terrain (water_terrain.gd): its contours, hachures and shadows follow the cap
#   shape.png                    the sheet: the twelve overviews with their numbers, the two A coast frames, what integration needs
#   shape.json                   the numbers per seed, the quality floors, the integration notes
#
# The other frames of variants/water/ (river, bank, markers, board.png) are of the FIRST revision of the generator: the board Alex
# chose from. They are not redrawn.

const WaterGen = preload("res://scripts/world/water_gen.gd")
const WaterContour = preload("res://scripts/world/water_contour.gd")
const WaterFrame = preload("res://scripts/ui/boards/water_frame.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

const SIZE := Vector2i(1280, 720)
const LETTERS := ["A", "B", "C", "D", "E", "F"]
const ZOOMS := [{"id": "035", "zoom": 0.35, "label": "planning zoom 0.35"}, {"id": "1", "zoom": 1.0, "label": "zoom 1"}]
const OVERVIEW_SEEDS := [20261009, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
const OV_PX := 280

var out_dir := "variants/water"
var seed_value := 20261009
var reuse := false
var only := ""
var base_dir := ""
var style: UiStyle = null
var rows: Array = []            # per overview seed: the numbers
var ov_imgs: Array = []
var coast_info: Dictionary = {}
var coast_a: Dictionary = {}    # "035" / "1" -> Image (option A, whole frame)
var failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			match kv[0]:
				"out": out_dir = kv[1]
				"reuse": reuse = kv[1] == "1"
				"seed": seed_value = int(kv[1])
				"only": only = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[water-shape] ", msg)

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[water-shape] needs a windowed run")
		quit(1)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(SIZE)
	root.size = SIZE
	await _frames(6)
	base_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base_dir.path_join("frames"))
	style = UiStyle.shared() as UiStyle
	var t0 := Time.get_ticks_msec()
	var P := RenderParams.new()
	var draw := WaterDraw.new(P)
	if only != "coast":
		await _overviews(draw)
	if only != "overview":
		await _coast()
	await _sheet(draw)
	_write_json(draw)
	_say("done in %.0f s, %d failures" % [(Time.get_ticks_msec() - t0) / 1000.0, failures])
	quit(1 if failures > 0 else 0)

# --- the overviews -------------------------------------------------------------------------------------------------

func _overviews(draw: WaterDraw) -> void:
	var P := RenderParams.new()
	var tcfg := Terrain.new(1)   # only for the fill ramp's numbers
	var step: float = tcfg.data.num("draw.level_fill.ok_lightness_step")
	var chroma: float = tcfg.data.num("draw.level_fill.chroma_scale_per_step")
	var land: Array[Color] = []
	for k in 3:
		land.append(TerrainDraw.lift(P.PAPER, step * k, pow(chroma, k)))
	for sd: int in OVERVIEW_SEEDS:
		var t0 := Time.get_ticks_msec()
		var w := WaterGen.new(sd)
		var st := w.coast_stats()
		var sea: Dictionary = w.diagnostics["sea"]
		var riv: Dictionary = w.diagnostics["river"]
		var rec := {"seed": sd, "archetype": w.archetype, "components": sea["components"], "sea_share": snappedf(float(st["share"]), 0.001),
			"coast_m": snappedf(float(st["coast_m"]), 1.0), "axis_share": snappedf(float(st["axis_share"]), 0.001), "cliff_share": snappedf(float(st["cliff_share"]), 0.001), "spread": snappedf(float(st["spread"]), 0.001),
			"islands": st["islands"], "island_share_of_land": snappedf(float(st["island_share"]), 0.001), "land_fill": snappedf(float(st["fill"]), 0.001),
			"first_try_dry": sea["dry_first_try"], "attempts": (sea["attempts"] as Array).size(), "accepted_attempt": sea["accepted"],
			"coast_pulled_back_to": sea["reach_scale"], "keep_dry_ok": w.diagnostics.get("keep_dry_ok", false),
			"river": bool(riv.get("made", false)), "river_length_m": riv.get("length_m", 0.0), "river_ends_in": riv.get("ends_in", ""),
			"islands_made": sea["islands_made"]}
		rows.append(rec)
		var rel := "frames/overview_%d.png" % sd
		var img: Image
		if reuse and FileAccess.file_exists(base_dir.path_join(rel)):
			img = Image.load_from_file(base_dir.path_join(rel))
		else:
			img = _draw_overview(w, draw, land)
			_save(img, rel)
		ov_imgs.append(img)
		_say("seed %d: %s, sea %.0f%%, coast %.1f km, %d islands, fill %.2f, spread %.2f (%.1f s)" % [sd, w.archetype, 100.0 * float(st["share"]), float(st["coast_m"]) / 1000.0,
			int(st["islands"]), float(st["fill"]), float(st["spread"]), (Time.get_ticks_msec() - t0) / 1000.0])
		await _frames(1)

func _draw_overview(w: WaterGen, draw: WaterDraw, land: Array[Color]) -> Image:
	var P := draw.P
	var n := OV_PX
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var m: Rect2 = w.map_rect()
	var thr: PackedFloat64Array = w.raw_terrain().thresholds
	for j in n:
		for i in n:
			var x := m.position.x + (float(i) + 0.5) / n * m.size.x
			var y := m.position.y + (float(j) + 0.5) / n * m.size.y
			var sf := w.s_and_field(x, y)
			var lev := 0 if sf.y < thr[0] else (1 if sf.y < thr[1] else 2)
			if sf.x > 0.0 and lev == 0:
				img.set_pixel(i, j, draw.steps[w.step_of(sf.x)])
			else:
				img.set_pixel(i, j, land[lev])
	var lay: RefCounted = w.layout()
	for p: Vector2 in lay.road():
		_dot(img, m, p, P.INK, 0)
	var vp: PackedVector2Array = lay.village().polygon
	for q in vp.size():
		_line(img, m, vp[q], vp[(q + 1) % vp.size()], P.INK)
	_dot(img, m, lay.sites().radio_tower, P.INK, 1)
	if w.river_crossing.is_finite():
		_ring(img, m, w.river_crossing, 4.0, P.INK)
	return img

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
	var n := int(a.distance_to(b) / 14.0) + 1
	for k in n + 1:
		_dot(img, m, a.lerp(b, float(k) / n), c, 0)

func _ring(img: Image, m: Rect2, p: Vector2, r_px: float, c: Color) -> void:
	for k in 24:
		var q := _px(img, m, p) + Vector2i(Vector2.from_angle(float(k) / 24.0 * TAU) * r_px)
		if q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height():
			img.set_pixel(q.x, q.y, c)

func _save(img: Image, rel: String) -> void:
	var err := img.save_png(base_dir.path_join(rel))
	if err != OK:
		failures += 1
		printerr("[water-shape] could not write ", rel)

# --- the coast of seed 20261009 --------------------------------------------------------------------------------------

# A stretch of shore with the three steps within 650 m, the sea to the lee of the land (the sun's shadows fall onto the water),
# far from the river's mouth and, if there is one, a coastal cliff (an upland at the water's edge).
func _pick_coast(w: WaterGen, wf: WaterFrame) -> Dictionary:
	var m: Rect2 = w.map_rect()
	var cell := 50.0
	var cols := int(ceil(m.size.x / cell)) + 3
	var rws := int(ceil(m.size.y / cell)) + 3
	var x0 := m.position.x - cell
	var y0 := m.position.y - cell
	var vals := PackedFloat64Array()
	vals.resize(cols * rws)
	for j in rws:
		var y := clampf(y0 + float(j) * cell, m.position.y, m.end.y - 0.01)
		for i in cols:
			vals[j * cols + i] = w.sea_s(clampf(x0 + float(i) * cell, m.position.x, m.end.x - 0.01), y)
	var sd: Vector2 = wf.ts.dir
	var inner := m.grow(-650.0)
	var cands: Array = []
	for ring: Dictionary in WaterContour.rings(vals, cols, rws, x0, y0, cell, 0.0, 1, 40.0):
		var pts: PackedVector2Array = ring["pts"]
		var n := pts.size()
		if n < 12:
			continue
		for k in range(0, n, 3):
			var p := pts[k]
			if not inner.has_point(p):
				continue
			var t := (pts[(k + 2) % n] - pts[(k - 2 + n) % n]).normalized()
			var nrm := Vector2(-t.y, t.x)
			var bearing := nrm.dot(sd)
			if bearing < 0.0:
				continue
			if w.sea_s(p.x - nrm.x * 40.0, p.y - nrm.y * 40.0) > -0.3:
				continue
			var s70 := w.sea_s(p.x + nrm.x * 70.0, p.y + nrm.y * 70.0)
			if s70 < 0.5 or s70 > 14.0:
				continue
			if w.sea_s(p.x + nrm.x * 650.0, p.y + nrm.y * 650.0) < 15.0:
				continue
			if w.river_s(p.x + nrm.x * 150.0, p.y + nrm.y * 150.0) > -500.0 or (w.river_mouth.is_finite() and p.distance_to(w.river_mouth) < 600.0):
				continue
			var cf := w.s_and_field(p.x - nrm.x * 6.0, p.y - nrm.y * 6.0).y >= float(w.raw_terrain().thresholds[0])
			cands.append([bearing + (2.5 if cf else 0.0), p, nrm, cf])
	cands.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var best := {}
	if not cands.is_empty():
		var c: Array = cands[0]
		best = {"shore": c[1], "normal": c[2], "cliff": c[3], "bearing": float(c[0]) - (2.5 if c[3] else 0.0), "candidates": cands.size()}
	return best

func _coast() -> void:
	var w := WaterGen.new(seed_value)
	var wf := WaterFrame.new(w)
	if not wf.errors.is_empty():
		printerr("[water-shape] frame errors: ", wf.errors)
		failures += 1
		return
	coast_info = _pick_coast(w, wf)
	if coast_info.is_empty():
		failures += 1
		printerr("[water-shape] no stretch of coast with the three steps found")
		return
	var shore: Vector2 = coast_info["shore"]
	var nrm: Vector2 = coast_info["normal"]
	_say("coast at %s facing %s (cliff at the shore: %s, %d candidates)" % [str(shore), str(nrm), coast_info["cliff"], coast_info["candidates"]])
	for z: Dictionary in ZOOMS:
		var focus := shore + nrm * (140.0 if z["id"] == "035" else 55.0)
		coast_info["focus_" + str(z["id"])] = focus
		var files: Array = []
		for L: String in LETTERS:
			files.append("frames/%s_coast_%s.png" % [L, z["id"]])
		if reuse and _all_exist(files):
			coast_a[z["id"]] = Image.load_from_file(base_dir.path_join(files[0]))
			continue
		var t0 := Time.get_ticks_msec()
		var base := wf.prepare(focus, z["zoom"], {})
		_say("coast at %s prepared in %.1f s %s" % [z["label"], (Time.get_ticks_msec() - t0) / 1000.0, str(base.counts)])
		for i in LETTERS.size():
			var img: Image = wf.render(base, wf.draw.option(LETTERS[i]))
			_save(img, files[i])
			if LETTERS[i] == "A":
				coast_a[z["id"]] = img
		await _frames(1)

func _all_exist(files: Array) -> bool:
	for f: String in files:
		if not FileAccess.file_exists(base_dir.path_join(f)):
			return false
	return true

# --- the sheet --------------------------------------------------------------------------------------------------------------

func _sheet(draw: WaterDraw) -> void:
	if ov_imgs.is_empty() or coast_a.is_empty():
		return
	var margin := 22
	var cols := 4
	var cap_h := 62
	var cell_w := OV_PX + 14
	var w := margin * 2 + cols * cell_w + 20
	var half := Vector2(640, 360)
	var h := 250 + 3 * (OV_PX + cap_h) + 60 + int(half.y) + 40 + 330
	var sh := BoardSheet.new(style, Vector2i(maxi(w, margin * 2 + 2 * int(half.x) + 14), h))
	var full_w := sh.size.x
	sh.text(Vector2(margin, 34), "The shape of the sea, twelve seeds  ·  the generator after Alex's note", 24.0, sh.c_text)
	var hy := 48.0
	hy += sh.paragraph(Vector2(margin, hy), "Alex (2026-10-10), on the generator: \"The seeds are too uniform. It looks like a big square of land.\" The first generator laid a straight falloff from one or two map edges under a little noise: the coast ran parallel to an edge, the land was one block, and every upland patch that fell in the sea stayed as an islet (speckle). Now the sea is built from COMPONENTS the seed picks as a SHAPE -- coast, corner, peninsula, bay, islands, lagoon -- evaluated at a point pushed by a low-frequency vector noise (a domain warp of up to 1,500 m), so nothing is parallel to anything; a coast can have an inlet, a bay can bite a kilometre into the land, a lagoon can sit inland behind an estuary. Islands are made on purpose (3 to 7 off an 'islands' coast, a few off other coasts sometimes), sized and clustered. A seed whose first shape floods the village, the tower, the batteries, the fields or the road tries its next draw instead of shrinking to a puddle. Uplands FADE into the sea: the terrain's height field is capped by a mask the water makes, so plateaus taper toward a coast, vanish under the sea, and meet it as a cliff only where a cliff noise says so.", 12.0, sh.c_muted, float(full_w) - margin * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(margin, hy), "Below: the whole 5 km map of seed 20261009 and 1 to 11 (land lifted by the capped terrain's level, water in the three steps in the decided hue 222; the village's outline, its road, the tower and, as a ring, the river's crossing in ink), with each seed's numbers: its shape, the sea's share of the map, the length of its coast, the real islands (land that does not touch the border), the share of its mainland's bounding box that is land (a square block is near 1), and the shore's spread (how far it leaves one straight line: the first generator scored 0.06 to 0.10 on these seeds, this one 0.16 to 0.66).", 12.0, sh.c_muted, float(full_w) - margin * 2.0, true)
	var y0 := 250.0
	for i in ov_imgs.size():
		var x := margin + (i % cols) * cell_w
		var y := y0 + (i / cols) * (OV_PX + cap_h)
		sh.image(ov_imgs[i], Vector2(x, y))
		var r: Dictionary = rows[i]
		sh.text(Vector2(x, y + OV_PX + 16), "seed %d  ·  %s" % [r["seed"], r["archetype"]], 12.5, sh.c_text)
		sh.text(Vector2(x, y + OV_PX + 31), "sea %d%%  ·  coast %.1f km  ·  %d islands" % [roundi(100.0 * float(r["sea_share"])), float(r["coast_m"]) / 1000.0, int(r["islands"])], 11.0, sh.c_muted)
		sh.text(Vector2(x, y + OV_PX + 45), "fill %.2f  ·  spread %.2f  ·  cliffs %d%%%s" % [float(r["land_fill"]), float(r["spread"]), roundi(100.0 * float(r["cliff_share"])), "" if bool(r["river"]) else "  ·  no river"], 11.0, sh.c_muted)
	var cy := y0 + 3.0 * (OV_PX + cap_h) + 20.0
	sh.line(Vector2(margin, cy), Vector2(float(full_w) - margin, cy), sh.c_rule, 1.0)
	sh.text(Vector2(margin, cy + 24), "The coast of seed 20261009 in look A, hue 222: the planning zoom 0.35 (left) and zoom 1 (right), half size; native frames in frames/A_coast_035.png and A_coast_1.png", 15.0, sh.c_text)
	var ix := float(margin)
	for zid: String in ["035", "1"]:
		if coast_a.has(zid):
			sh.image(coast_a[zid], Vector2(ix, cy + 36.0), Rect2(), half)
		ix += half.x + 14.0
	var ty := cy + 36.0 + half.y + 18.0
	var lines: Array = [
		"WHAT INTEGRATION NEEDS FROM scripts/world/terrain*.gd (proposed): two lines and one rule. (1) In Terrain.field_at_node() and Terrain.field_at(), return minf(<the fbm as now>, cap), where cap comes from a Callable the terrain is given, WaterGen.field_cap(x, y) (in the field's own units: 1.0 and over inland, falling to the first threshold less 0.03 at and under the sea); with no Callable, nothing changes. scripts/world/water_terrain.gd is exactly that as a subclass, and is what these frames are drawn on: contours, hachures, level fills, shadows, trees and every level_at / height_at follow the cap with no other change. (2) The order of assembly: a RAW terrain first (the world layout is made on it and does not change: the cap only lowers ground and every layout site is low ground already), then WaterGen on the raw terrain, then the terrain the map, the sim and the fog use, with the cap installed BEFORE its first chunk is generated (set_cap clears the caches). WorldLayout.shared() is keyed by the seed and the data's text, so the capped terrain finds the layout already made. (3) Thread safety: field_cap reads arrays that are never written after the build, so every bundle of Track P's provider may share one WaterGen. Cost: one landness evaluation (about 70 microseconds) per field node, about 75 ms per 256 m chunk on top of 250 ms.",
		"WHAT THE CAP DOES: where landness is under about 0.10 (150 m inland of a coast) an upland tapers and under the sea it is level 0, so there is no speckle; where the cliff noise is high (about a fifth of a coast) the margin is the shore itself and a plateau meets the sea as a cliff (those frames show the cliff's hachures and its shadow falling on the water); islands are islands of landness with a peak of 0.14 to 0.40 and may carry a plateau if the terrain's field is high there.",
	]
	for l: String in lines:
		ty += sh.paragraph(Vector2(margin, ty), l, 11.5, sh.c_muted, float(full_w) - margin * 2.0, false, 3.0) + 8.0
	var err: int = await sh.save(self, base_dir.path_join("shape.png"))
	if err != OK:
		failures += 1
		printerr("[water-shape] could not write shape.png: ", error_string(err))
	else:
		_say("saved shape.png (%d x %d)" % [sh.size.x, sh.size.y])

func _overview_files() -> Array:
	var out: Array = []
	for sd: int in OVERVIEW_SEEDS:
		out.append("frames/overview_%d.png" % sd)
	return out

func _write_json(draw: WaterDraw) -> void:
	var doc := {
		"id": "water-shape",
		"date": "2026-10-10",
		"question": "Alex, on the water generator: 'the seeds are too uniform. It looks like a big square of land.' The sea's shape reworked: domain-warped noise, six shapes, deliberate islands, uplands that fade into the sea.",
		"look": "A (an ink line at each step), hue 222: Alex's choice (decision water-look)",
		"seeds": rows,
		"coast_of_20261009": coast_info,
		"integration": {
			"terrain_change": "Terrain.field_at_node() and Terrain.field_at() return minf(fbm, cap) where cap = a Callable the terrain is given (WaterGen.field_cap); no Callable: unchanged. scripts/world/water_terrain.gd is that as a subclass.",
			"assembly_order": "raw Terrain -> its WorldLayout (unchanged by the cap) -> WaterGen(raw terrain) -> the terrain the map, the sim and the fog use, with set_cap(water.field_cap) installed before its first chunk (set_cap clears the caches)",
			"layout_unchanged": "the cap only lowers ground and every layout site is low ground; WorldLayout.shared() keys on seed and data text, so the capped terrain finds the layout already made",
			"threading": "field_cap reads arrays never written after the build: one WaterGen may be shared by all of Track P's bundles",
			"cost": "one landness evaluation (about 70 microseconds) per field node, about 75 ms per chunk on top of the chunk's 250 ms",
		},
		"files": {"overviews": _overview_files(), "coast": ["frames/A_coast_035.png", "frames/A_coast_1.png"], "sheet": "shape.png"},
	}
	var f := FileAccess.open(base_dir.path_join("shape.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved shape.json")
