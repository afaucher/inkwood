extends SceneTree

# BOARD: THE BRIDGE (Track BB, the water layer). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/bridge_board_shot.gd -- [out=variants/bridge]
#
# Alex (decision water-layer, 2026-10-10): "Maybe bridges?" The lead proposed bridges where the village road
# crosses the river, drawn like the buildings with shadows on the water, destroyable like the radio tower
# (Alex: "Sounds good"). HOW THEY LOOK is this board's question and NOTHING IS CHOSEN: three looks, each shown
# whole and destroyed (a broken span, rubble in the water), at the planning zoom 0.35 and at zoom 1, and
# closer still at zoom 2 (the camera's closest) where the detail can be judged.
#
# The art is the new generators in scripts/render/bridge_art.gd, drawn through the drawing layer's InkCanvas
# with the pen Alex chose, in frames made by scripts/render/bridge_frame.gd on PLACEHOLDER water and banks
# (Track WB's board, variants/water/, decides the water). A bridge is MAP SCENERY, so it is drawn at the MAP's
# scale (2 px per metre x zoom), not the units'. The road is the village road's own look (scripts/render/
# village_draw.gd draw_road) run onto the deck from both banks.
#
# Output (out=): board.png (the sheet), frames.json, board.json ("chosen": null for Alex), and every frame as its
# own PNG at native size: <kind>_<ok|ruin>_z1.png, _plan.png, _z2.png, and range_<kind>_<w>m.png.
#
# EVERY OPTION AND VALUE IS PROPOSED by Track BB; none is a decision.

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const BridgeFrame = preload("res://scripts/render/bridge_frame.gd")
const BridgeArt = preload("res://scripts/render/bridge_art.gd")

const SEED := 20261009
const OUT_DEFAULT := "variants/bridge"
const MARGIN := 24.0
const W := 1480
const Z1_SIZE := Vector2i(300, 210)
const PLAN_SIZE := Vector2i(120, 84)
const Z2_SIZE := Vector2i(480, 300)
const INFLATE := 3.0

var out_dir := OUT_DEFAULT
var style: UiStyle = null
var frames: Array = []
var failures := 0
var base := ""

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[bridge-board] ", msg)

func _save(img: Image, file: String, look: String, zoom: float, caption: String) -> void:
	var err := img.save_png(base.path_join(file))
	if err != OK:
		failures += 1
		printerr("[bridge-board] could not write ", file)
	frames.append({"file": file, "look": look, "zoom": zoom, "caption": caption, "size": [img.get_width(), img.get_height()]})

func _frame(kind: String, ruin: bool, zoom: float, size: Vector2i, river_w: float = -1.0) -> Image:
	return BridgeFrame.render(style, size, {"zoom": zoom, "kind": kind, "ruin": ruin, "seed": SEED % 9973, "river_w": river_w})

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[bridge-board] a board needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	style = UiStyle.new()
	if not style.ok():
		printerr("[bridge-board] style errors: ", style.errors)
		quit(1)
		return
	base = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var imgs: Dictionary = {}     # "<kind>/<ok|ruin>/<z1|plan|z2>" -> Image
	var data := BridgeArt.data()
	for kind: String in BridgeArt.kinds():
		var title: String = str((data[kind] as Dictionary)["title"])
		for ruin: bool in [false, true]:
			var tag := "ruin" if ruin else "ok"
			var word := "destroyed" if ruin else "whole"
			var z1 := _frame(kind, ruin, 1.0, Z1_SIZE)
			var pl := _frame(kind, ruin, 0.35, PLAN_SIZE)
			var z2 := _frame(kind, ruin, 2.0, Z2_SIZE)
			imgs["%s/%s/z1" % [kind, tag]] = z1
			imgs["%s/%s/plan" % [kind, tag]] = pl
			imgs["%s/%s/z2" % [kind, tag]] = z2
			_save(z1, "%s_%s_z1.png" % [kind, tag], kind, 1.0, "%s, %s, at zoom 1 (2 px per metre, the map's scale)" % [title, word])
			_save(pl, "%s_%s_plan.png" % [kind, tag], kind, 0.35, "%s, %s, at the planning zoom 0.35 (0.7 px per metre)" % [title, word])
			_save(z2, "%s_%s_z2.png" % [kind, tag], kind, 2.0, "%s, %s, at zoom 2 (4 px per metre, the camera's closest)" % [title, word])
	# the range check: each bridge over a 42 m and a 78 m river
	var range_imgs: Dictionary = {}
	for kind: String in BridgeArt.kinds():
		for rw: float in [26.0, 42.0, 78.0]:
			var img := _frame(kind, false, 1.0, Z1_SIZE, rw)
			range_imgs["%s/%d" % [kind, int(rw)]] = img
			_save(img, "range_%s_%dm.png" % [kind, int(rw)], kind, 1.0, "%s over a %d m river at zoom 1" % [str((data[kind] as Dictionary)["title"]), int(rw)])
	_say("frames drawn: %d" % frames.size())
	await _sheet(imgs, range_imgs)
	_write_frames_json()
	_write_board_json()
	quit(1 if failures > 0 else 0)

# --- the sheet --------------------------------------------------------------------------------------------------------------

func _box(sh: BoardSheet, img: Image, pos: Vector2, scale_f: float = 1.0) -> Vector2:
	var sz := Vector2(img.get_size()) * scale_f
	sh.image(img, pos, Rect2(), sz)
	sh.rect(Rect2(pos, sz), sh.c_chip_line, false, 1.0)
	return sz

func _look_notes(kind: String) -> String:
	match kind:
		"arch":
			return "READING IT: the heaviest look and the most like a building: it shares the village walls' two stone tones, and it is the only one whose shadow is a solid slab. At the planning zoom it is a banded block (the roof halves, light and shade, one per arch). The most to draw: parapets, wing walls, humps, cutwaters."
		"truss":
			return "READING IT: the most distinctive and the most legible at the planning zoom (a pale span with a lattice on it); the lattice shows twice, as X bracing over the road and as a LATTICE OF SHADOW on the water, like the radio tower's. The cheapest of the three to read from far away."
		"trestle":
			return "READING IT: the lightest look and the least visible at the planning zoom (a plain pale bar with a thin, many-legged shadow); the cheapest to draw. Suits the back roads rather than the village's crossing."
	return ""

func _sheet(imgs: Dictionary, range_imgs: Dictionary) -> void:
	var head_h := 270.0
	var row_h := 24.0 + float(PLAN_SIZE.y) * INFLATE + 40.0
	var close_h := 24.0 + float(Z2_SIZE.y) + 40.0
	var range_h := 24.0 + 3.0 * (float(Z1_SIZE.y) + 14.0) + 20.0
	var pal_h := 600.0
	var total := int(head_h + 3.0 * (row_h + 30.0) + 60.0 + 3.0 * close_h + 60.0 + range_h + pal_h)
	var sh := BoardSheet.new(style, Vector2i(W, total))
	var tw := float(W) - MARGIN * 2.0
	sh.text(Vector2(MARGIN, 34.0), "The bridge: stone arch, steel truss, wooden trestle  ·  seed %d, over Track WB's proposed water" % SEED, 25.0, sh.c_text)
	var hy := 52.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "Alex (decision water-layer, 2026-10-10): \"Maybe bridges?\" The lead proposed bridges where the village road crosses the river, drawn like the buildings with shadows on the water, destroyable like the radio tower; Alex: \"Sounds good\". This board asks how they LOOK: three looks, each whole and destroyed (a broken span and rubble in the water), at the planning zoom 0.35 and at zoom 1, and at zoom 2 (the camera's closest) where the detail can be judged. The art is new generators (scripts/render/bridge_art.gd, in the style of the buildings and the radio tower); nothing is in the game yet.", 12.5, sh.c_muted, tw, true) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "SIZES (all PROPOSED, data/world/bridges.json): each spans a river of 54 to 70 m as drawn (the lead's brief: 40 to 80 m) and was checked over 26 m, 42 m and 78 m (the last strip: 26 m is what Track WB's river generator makes at the road's crossing, data/world/water.json river.shape.crossing_half_width_m); the bridge is the river plus 6 m of stone abutment each end. The DECK IS THE ROAD'S OWN WIDTH, 16 m (the road's half width is 16 px at 2 px per metre), so the village road's eight rut and edge lines carry across it unchanged: the road is drawn from the village code's own numbers on both banks and over the deck (dirt specks, wobbly broken lines, pebbles on the verges). Heights, which set the shadows: arch crown 6.5 m, truss roadway 4.5 m and top chord 11.5 m, trestle deck 4.2 m; each shadow is the map's, so it falls to the south-east on the water.", 12.5, sh.c_muted, tw) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "SCALE: a bridge is MAP SCENERY and drawn at the map's own scale like a house or the road (2 px per metre at zoom 1, 0.7 at the planning zoom, 4 at zoom 2), NOT at the planes' scale (4 and 1.56). The river runs top to bottom, the road west to east, the sun is the map's (from the north-west). The water, the banks and the bank's hachures are PLACEHOLDERS (the water is Track WB's PROPOSED default, read from data/world/water.json at render time -- shallows along the banks and a shelf channel down the middle -- and the banks are paper; Track WB's board, variants/water/, decides the water). A bridge belongs to nobody, so it carries no side accent. Every option is PROPOSED; nothing is chosen (chosen: null). Row layout: whole and destroyed at zoom 1 (300 x 210), then the planning zoom twice, 1:1 (small) and at 3x (nearest), so the pixels can be seen.", 12.5, sh.c_muted, tw, true)
	var y := head_h
	for kind: String in BridgeArt.kinds():
		var d: Dictionary = (BridgeArt.data()[kind] as Dictionary)
		sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
		var m := BridgeArt.model(style, kind, false)
		sh.text(Vector2(MARGIN, y + 20.0), "%s  ·  %.0f m river, %.0f m long  ·  data/world/bridges.json %s" % [str(d["title"]), float(m.p.river_w), float(m.p.len), kind], 17.0, sh.c_text)
		var iy := y + 30.0
		var x := MARGIN
		var a := _box(sh, imgs["%s/ok/z1" % kind], Vector2(x, iy))
		sh.text(Vector2(x, iy + a.y + 13.0), "whole · zoom 1 · 2 px/m", 11.0, sh.c_muted, true)
		var b := _box(sh, imgs["%s/ruin/z1" % kind], Vector2(x + a.x + 12.0, iy))
		sh.text(Vector2(x + a.x + 12.0, iy + b.y + 13.0), "destroyed · zoom 1", 11.0, sh.c_muted, true)
		var x2 := x + a.x + b.x + 36.0
		var c := _box(sh, imgs["%s/ok/plan" % kind], Vector2(x2, iy), INFLATE)
		sh.text(Vector2(x2, iy + c.y + 13.0), "whole · planning zoom 0.35 at 3x", 11.0, sh.c_muted, true)
		var e := _box(sh, imgs["%s/ruin/plan" % kind], Vector2(x2 + c.x + 12.0, iy), INFLATE)
		sh.text(Vector2(x2 + c.x + 12.0, iy + e.y + 13.0), "destroyed · planning zoom at 3x", 11.0, sh.c_muted, true)
		# the same two frames 1:1, and the description under
		var ny := iy + maxf(a.y, c.y) + 30.0
		var n1 := _box(sh, imgs["%s/ok/plan" % kind], Vector2(x, ny))
		var n2 := _box(sh, imgs["%s/ruin/plan" % kind], Vector2(x + n1.x + 8.0, ny))
		sh.text(Vector2(x, ny + n1.y + 13.0), "the planning zoom 1:1: what the player sees", 11.0, sh.c_muted, true)
		var tx := x + n1.x * 2.0 + 40.0
		var hh := sh.paragraph(Vector2(tx, ny - 4.0), str(d["about"]), 12.0, sh.c_text, float(W) - MARGIN - tx, false, 3.0)
		hh += sh.paragraph(Vector2(tx, ny + hh + 4.0), "DESTROYED: " + str((d["ruin"] as Dictionary)["about"]), 12.0, sh.c_text, float(W) - MARGIN - tx, false, 3.0)
		sh.paragraph(Vector2(tx, ny + hh + 12.0), _look_notes(kind), 12.0, sh.c_muted, float(W) - MARGIN - tx, true, 3.0)
		y = ny + 120.0
	# --- close, zoom 2
	sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 26.0), "Closer: zoom 2 (the camera's closest, 4 px per metre), whole and destroyed", 20.0, sh.c_text)
	y += 40.0
	for kind: String in BridgeArt.kinds():
		var title: String = str((BridgeArt.data()[kind] as Dictionary)["title"])
		sh.text(Vector2(MARGIN, y + 14.0), title, 14.0, sh.c_text)
		var a := _box(sh, imgs["%s/ok/z2" % kind], Vector2(MARGIN, y + 24.0))
		_box(sh, imgs["%s/ruin/z2" % kind], Vector2(MARGIN + a.x + 12.0, y + 24.0))
		y += close_h
	# --- the range check
	sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 26.0), "The range check: each bridge over a 26 m, a 42 m and a 78 m river, zoom 1 (top to bottom)", 20.0, sh.c_text)
	y += 40.0
	var rx := MARGIN
	for kind: String in BridgeArt.kinds():
		for ri in 3:
			_box(sh, range_imgs["%s/%d" % [kind, [26, 42, 78][ri]]], Vector2(rx, y + float(ri) * (float(Z1_SIZE.y) + 14.0)))
		rx += float(Z1_SIZE.x) + 14.0
	var note_x := rx + 14.0
	sh.paragraph(Vector2(note_x, y), "The 26 m row is the river Track WB's generator makes where it crosses the road (data/world/water.json river.shape.crossing_half_width_m 13, 'the span a bridge will have to cover'); 42 and 78 are the ends of the 40 to 80 m the lead asked for. The arch takes one to four arches (a span of about 19 m each: 1, 2, 3 or 4); the truss adds panels (4, 5, 10: about 6.5 to 8 m each); the trestle adds bents (about every 5.5 m). All three hold their look from 26 to 78 m: nothing in the generators depends on the river's width but the count and the spacing of the parts. WHICH WIDTH THE GAME WANTS IS A QUESTION FOR ALEX (see the report): the 54 to 70 m drawn above is the lead's brief, the 26 m is what the river generator makes today.", 12.0, sh.c_muted, float(W) - MARGIN - note_x, true, 3.0)
	y += range_h
	_palette_strip(sh, Vector2(MARGIN, y), float(W) - MARGIN * 2.0)
	var err: int = await sh.save(self, base.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[bridge-board] could not write board.png: ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), W, total])

# --- the palette strip --------------------------------------------------------------------------------------------------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	var rl := BridgeFrame.roles(style)
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0.0, 26.0), "The palette: what the bridges spend of it (roles in data/world/bridges.json, no hex in the draw code)", 17.0, sh.c_text)
	var water: Color = rl["water_placeholder"]
	var chips: Array = [
		["paper (the bank)", rl["land_placeholder"]],
		["ink", rl["ink"]],
		["dirt (road specks)", rl["dirt"]],
		["stone, timber", rl["stone"]],
		["stone_slope", rl["stone_slope"]],
		["stone_rock (piers)", rl["stone_rock"]],
		["steel, coping", rl["steel"]],
		["timber_new, rails", rl["timber_new"]],
		["rubble_slope", rl["rubble_slope"]],
		["shadow on water", BoardSheet.over(rl["shadow"], water)],
		["submerged wreck", BoardSheet.over(rl["submerged"], rl["timber"])],
		["WB shallows (river)", water],
		["WB shelf (channel)", rl["water_shelf"] if rl.has("water_shelf") else water],
	]
	var x := pos.x
	var cy := pos.y + 44.0
	for i in chips.size():
		var c: Array = chips[i]
		var col: Color = c[1]
		if x + 122.0 > pos.x + width:
			x = pos.x
			cy += 92.0
		sh.chip(Vector2(x, cy), col, str(c[0]), BoardSheet.oklch_text(col), Vector2(96.0, 40.0))
		x += 126.0
	var stone_l: float = BoardSheet.oklch(rl["stone"]).x
	var slope_l: float = BoardSheet.oklch(rl["stone_slope"]).x
	var paper_l: float = BoardSheet.oklch(rl["land_placeholder"]).x
	var water_l: float = BoardSheet.oklch(water).x
	var yy := cy + 84.0
	var lines: Array = [
		"HUE stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md). A bridge uses none of the accents (it belongs to nobody): every surface is the paper ramp, as the village's walls and roofs are. The stone roadway and the parapets are the WALL fill (L %.3f), the faces away from the sun the wall-slope mix toward the shadow tint (L %.3f) -- the same two tones as the village's walls, so a stone bridge reads as part of the village's masonry; the piers are the ROCK fill, the steel chords and the coping the object fill, timber the wall fill and new planks the roof's lit fill. MATERIAL is linework: stone is courses and cobble stipple, planks are lines across the deck, steel is X bracing and rivet dots, the road is the village's own ruts and specks. The lightness of the bank (paper, L %.3f) against the roadway (L %.3f) is the step the village's houses already have against their ground." % [stone_l, slope_l, paper_l, stone_l],
		"THE WATER IS TRACK WB'S: their proposed default river is the shallows (L %.3f) along the banks with the shelf (L %.3f) down the middle, read from data/world/water.json at render time. A stone roadway (L %.3f) against the shallows is a lightness step of %.3f and against the shelf %.3f, and every bridge has an ink outline (L %.3f) and a shadow on top of that, so it reads on both. The bridge's shadow is the map's one shadow tint at the map's strength (0.44) and one translucent fill, so a pier's shadow and the roadway's never darken twice where they overlap; the bank casts on the water the same way. A ruin adds no colour: the wreck in the water is the same fills with the shelf's colour laid over at an alpha (the 'submerged' role) so it reads half under the water." % [water_l, BoardSheet.oklch(rl["water_shelf"] if rl.has("water_shelf") else water).x, stone_l, stone_l - water_l, stone_l - BoardSheet.oklch(rl["water_shelf"] if rl.has("water_shelf") else water).x, BoardSheet.oklch(rl["ink"]).x],
	]
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width, false, 3.0) + 6.0

# --- the records ---------------------------------------------------------------------------------------------------------------

func _write_frames_json() -> void:
	var f := FileAccess.open(base.path_join("frames.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[bridge-board] could not write frames.json")
		return
	f.store_string(JSON.stringify({"id": "bridge", "about": "Every frame of the bridge board as its own PNG at native size, with its zoom and a caption. board.png is the sheet; the 3x copies on it are nearest-neighbour copies of the *_plan.png frames.", "frames": frames}, "  ", false))
	f.close()

func _write_board_json() -> void:
	var data := BridgeArt.data()
	var rl := BridgeFrame.roles(style)
	var options: Array = []
	var letter := 0
	for kind: String in BridgeArt.kinds():
		var d: Dictionary = data[kind]
		var m := BridgeArt.model(style, kind, false)
		options.append({"name": ["A", "B", "C"][letter], "title": str(d["title"]), "kind": kind, "proposed": true,
			"files": ["%s_ok_z1.png" % kind, "%s_ruin_z1.png" % kind, "%s_ok_plan.png" % kind, "%s_ruin_plan.png" % kind, "%s_ok_z2.png" % kind, "%s_ruin_z2.png" % kind],
			"range_check": ["range_%s_26m.png" % kind, "range_%s_42m.png" % kind, "range_%s_78m.png" % kind],
			"description": str(d["about"]), "ruin": str((d["ruin"] as Dictionary)["about"]), "data": "data/world/bridges.json %s" % kind,
			"drawn_as": {"river_m": snappedf(float(m.p.river_w), 0.1), "length_m": snappedf(float(m.p.len), 0.1), "deck_width_m": float(m.p.deck_w), "seed": m.seed},
			"parameters": d})
		letter += 1
	var doc := {
		"id": "bridge",
		"date": "2026-10-10",
		"area": "Water, World",
		"question": "How does a bridge look where the village road crosses the river? Alex (decision water-layer): 'Maybe bridges?' -- proposed by the lead as bridges drawn like the buildings, with shadows on the water, destroyable like the radio tower; Alex: 'Sounds good'.",
		"source": "scripts/ui/boards/bridge_board_shot.gd: the new generators in scripts/render/bridge_art.gd, framed by scripts/render/bridge_frame.gd on PLACEHOLDER water and banks, one InkCanvas per frame; no sandbox is stood up and nothing in the game changes",
		"seed": SEED,
		"held_constant": {
			"light": "the map's sun (from the north-west, elevation 46, shadow strength 0.44), so the shadows fall south-east onto the water",
			"pen": "the game's own pen (render_defaults linework.pen, shadow side)",
			"scale": "the MAP's scale (2 px per metre x zoom): a bridge is scenery like a house, not a unit; zoom 0.35 / 1 / 2 are 0.7 / 2 / 4 px per metre",
			"road": "the village road's own look (village_draw.gd draw_road: dirt specks, eight wobbly broken lines at the road's offsets, pebbles on the verges), 16 m wide, run onto the deck from both banks",
			"water_and_banks": "the water is Track WB's PROPOSED default (data/world/water.json draw.palette, read at render time: shallows along the banks, a shelf channel down the middle); the banks are a PLACEHOLDER (paper with a hachured shore). Track WB's board (variants/water/) decides the water",
		},
		"sizes_m_proposed": {"deck_width": 16, "abutment_each_end": 6, "arch_river": [54, 62], "truss_river": [62, 70], "trestle_river": [50, 60], "range_checked": [26, 42, 78], "heights": {"arch_crown": 6.5, "truss_deck": 4.5, "truss_top_chord": 11.5, "trestle_deck": 4.2}},
		"parameter": "data/world/bridges.json: arch, truss, trestle (each with its ruin block), ripples, roles",
		"options": options,
		"palette_check": "No option adds a hue and none uses a side accent (a bridge belongs to nobody). Surfaces are the paper ramp (wall fill L %.3f, its slope mix L %.3f, rock fill L %.3f, object fill L %.3f, roof lit L %.3f); material is linework. The placeholder water is the one exception and is Track WB's to decide." % [
			BoardSheet.oklch(rl["stone"]).x, BoardSheet.oklch(rl["stone_slope"]).x, BoardSheet.oklch(rl["stone_rock"]).x, BoardSheet.oklch(rl["steel"]).x, BoardSheet.oklch(rl["timber_new"]).x],
		"recommendation_proposed": "PROPOSED by Track BB, Alex decides: B, the steel truss, if the bridge has to be found and read at the planning zoom (the lattice, on the span and as a lattice of shadow, is the most legible thing of the three at 0.7 px per metre); A, the stone arch, if it should look like the village's own masonry (it shares the walls' two tones and is the most like the buildings); C, the wooden trestle, as the cheap, light variant (a second bridge type for the back roads). They need not be one: the generator can pick a look per crossing (a stone arch in the village, a trestle on the track).",
		"frames": "frames.json (every frame whole, native size)",
		"sheet": "board.png (each look whole and destroyed at zoom 1 and the planning zoom, a zoom-2 close-up, a range check, a palette strip)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(base.path_join("board.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[bridge-board] could not write board.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved board.json")
