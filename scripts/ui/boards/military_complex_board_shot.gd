extends SceneTree

# BOARD: THE MILITARY COMPLEX (Track M2U, mission 2). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/military_complex_board_shot.gd -- [out=variants/military-complex]
#
# Alex's second mission profile (2026-10-11, decision suppress-mission): "Clear mobile Aa units and their escorts to enable a bombing run of
# a military complex." The complex is the target and has no art. HOW IT LOOKS is this board's question and NOTHING IS CHOSEN: three looks of one
# seeded generator (scripts/ui/unit_marker_art_static.gd, the military complex section) in the village's building language (the roofs in two
# halves, the wall fill and its slope tone, the prism shadow of the part heights) and the unit sheet's pen: a fenced compound of a main building,
# sheds, a yard and a gate, 80 x 60 m, with ONE accent zone (a recognition panel painted on the main roof) in the side's colour. Each look is
# shown whole and DESTROYED (R1's language: scorch, craters, the main building roofless with its floor black and a torn roof lying across it,
# the sheds in heaps, the fence half down; no fire), at zoom 1, at the planning zoom 0.35 (1:1 and 3x) and at zoom 2, beside the radio tower
# and the anti-aircraft battery (the things it sits with) and a light fighter at the low band for scale, and once turned (a static unit is
# baked already turned by its heading).
#
# DRAWN BY THE GAME: the real markers (scripts/ui/unit_marker.gd) with the baked art unit_marker_art.gd returns (the complex through its
# one dispatch line), on the game's own paper and road, the shadows merged and tinted once at the map's strength (scripts/ui/boards/m2_frame.gd).
# The destroyed look is the art UnitMarkerArtStatic.complex_ruin_art bakes, placed as the effects layer would place a ruin. Scale: A STATIC
# TARGET AT THE MAP'S SCALE (2 px per metre x zoom), as a bridge is, not at the units' scale (data military_complex.map_scale_factor).
# ONLY data/ui/ui.json unit_art.variant.military_complex changes between the options.
#
# Output (out=): board.png (the sheet), <id>_z1.png / _ruin_z1.png / _plan.png / _ruin_plan.png / _z2.png / _ruin_z2.png / _turned_z1.png (every
# frame whole, native size), frames.json, board.json ("chosen": null for Alex to choose).
#
# EVERY OPTION AND VALUE IS PROPOSED by Track M2U; none is a decision.

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const M2Frame = preload("res://scripts/ui/boards/m2_frame.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const StaticArt = preload("res://scripts/ui/unit_marker_art_static.gd")

const SEED := 20261009
const OUT_DEFAULT := "variants/military-complex"
const MARGIN := 24.0
const W := 1480
const Z1_SIZE := Vector2i(460, 240)
const PLAN_SIZE := Vector2i(150, 80)
const Z2_SIZE := Vector2i(440, 340)
const TURN_SIZE := Vector2i(330, 240)
const INFLATE := 3.0
const NORTH := -PI / 2.0     # the heading whose sprite angle is 0: the compound as drawn, unturned

var out_dir := OUT_DEFAULT
var style: UiStyle = null
var frame: M2Frame = null
var frames: Array = []
var failures := 0
var base := ""
var imgs: Dictionary = {}
var models: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[military-complex-board] ", msg)

func _save(img: Image, file: String, look: String, zoom: float, caption: String) -> void:
	var err := img.save_png(base.path_join(file))
	if err != OK:
		failures += 1
		printerr("[military-complex-board] could not write ", file)
	frames.append({"file": file, "look": look, "zoom": zoom, "caption": caption, "size": [img.get_width(), img.get_height()]})

# The road the compound stands beside, in metres from the frame's centre: along its gate's side, 14 m off the fence.
func _road(gate: String, at: Vector2) -> Array:
	if gate == "west":
		return [Vector2(at.x - 50.0, -260.0), Vector2(at.x - 50.0, 260.0)]
	return [Vector2(-260.0, at.y + 40.0), Vector2(260.0, at.y + 40.0)]

# The compound (standing or its ruin) with the tower, the battery and a light fighter at the low band beside it.
func _items(at: Vector2, with_neighbours: bool, ruin: Variant, heading: float, ppm_want: float, tower_at: Vector2, battery_at: Vector2, plane_at: Vector2) -> Array:
	var items: Array = []
	if ruin != null:
		items.append({"art": ruin, "at": at})
	else:
		items.append({"silhouette": "military_complex", "side": "axis", "at": at, "heading": heading, "size_m": 80.0})
	if with_neighbours:
		items.append({"silhouette": "radio_tower", "side": "axis", "at": tower_at, "heading": 0.0, "size_m": 12.0, "static_rule": true})
		items.append({"silhouette": "anti_aircraft_battery", "side": "axis", "at": battery_at, "heading": 0.4, "size_m": 14.0, "static_rule": true})
		items.append({"silhouette": "light_fighter", "side": "allies", "at": plane_at, "heading": 0.0, "size_m": 9.0, "plane_h": 120.0})
	return items

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[military-complex-board] a board needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	for _i in 10:
		await process_frame
	style = UiStyle.shared() as UiStyle
	if not style.ok():
		printerr("[military-complex-board] style errors: ", style.errors)
		quit(1)
		return
	frame = M2Frame.new(self, style)
	base = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var looks: Array = StaticArt.mc_looks()
	for look in looks.size():
		var L: Dictionary = looks[look]
		var id := str(L["id"])
		style.ui["unit_art"]["variant"]["military_complex"] = look
		models[id] = StaticArt.mc_model(style, look)
		var gate := str(L["gate"])
		var title := "%s  %s" % [L["letter"], L["title"]]
		# zoom 1
		var at1 := Vector2(-28.0, 4.0)
		var want1 := frame.drawn_ppm(1.0, false)
		var ruin1 = StaticArt.complex_ruin_art(style, want1, 0.0)
		var nb1 := [Vector2(52.0, -22.0), Vector2(54.0, 26.0), Vector2(0.0, -50.0)]
		var z1: Image = await frame.render(Z1_SIZE, 1.0, _items(at1, true, null, NORTH, want1, nb1[0], nb1[1], nb1[2]), {"road": _road(gate, at1)})
		var z1r: Image = await frame.render(Z1_SIZE, 1.0, _items(at1, true, ruin1, NORTH, want1, nb1[0], nb1[1], nb1[2]), {"road": _road(gate, at1)})
		# the planning zoom
		var at_p := Vector2(-20.0, 2.0)
		var want_p := frame.drawn_ppm(0.35, false)
		var ruin_p = StaticArt.complex_ruin_art(style, want_p, 0.0)
		var nbp := [Vector2(44.0, -18.0), Vector2(44.0, 22.0), Vector2(2.0, -44.0)]
		var pl: Image = await frame.render(PLAN_SIZE, 0.35, _items(at_p, true, null, NORTH, want_p, nbp[0], nbp[1], nbp[2]), {"road": _road(gate, at_p)})
		var plr: Image = await frame.render(PLAN_SIZE, 0.35, _items(at_p, true, ruin_p, NORTH, want_p, nbp[0], nbp[1], nbp[2]), {"road": _road(gate, at_p)})
		# zoom 2
		var want2 := frame.drawn_ppm(2.0, false)
		var ruin2 = StaticArt.complex_ruin_art(style, want2, 0.0)
		var z2: Image = await frame.render(Z2_SIZE, 2.0, _items(Vector2.ZERO, false, null, NORTH, want2, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO), {"road": _road(gate, Vector2.ZERO)})
		var z2r: Image = await frame.render(Z2_SIZE, 2.0, _items(Vector2.ZERO, false, ruin2, NORTH, want2, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO), {"road": _road(gate, Vector2.ZERO)})
		# turned: the marker bakes it already turned by its heading, so the light stays the map's
		var tr: Image = await frame.render(TURN_SIZE, 1.0, _items(Vector2.ZERO, false, null, NORTH + 0.9, want1, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO), {})
		imgs[id + "/z1"] = z1
		imgs[id + "/ruin_z1"] = z1r
		imgs[id + "/plan"] = pl
		imgs[id + "/ruin_plan"] = plr
		imgs[id + "/z2"] = z2
		imgs[id + "/ruin_z2"] = z2r
		imgs[id + "/turned"] = tr
		_save(z1, "%s_z1.png" % id, id, 1.0, "%s whole at zoom 1 (2 px per metre, the map's scale): beside the radio tower and the anti-aircraft battery (at the units' scale, as in the game) and a light fighter at the low band" % title)
		_save(z1r, "%s_ruin_z1.png" % id, id, 1.0, "%s destroyed at zoom 1 (R1's language: scorch, craters, the main building roofless, heaps, the fence half down; no fire)" % title)
		_save(pl, "%s_plan.png" % id, id, 0.35, "%s whole at the planning zoom 0.35 (about 0.8 px per metre: the planes' floor holds the marker rule above the map's 0.7)" % title)
		_save(plr, "%s_ruin_plan.png" % id, id, 0.35, "%s destroyed at the planning zoom 0.35" % title)
		_save(z2, "%s_z2.png" % id, id, 2.0, "%s whole at zoom 2, the camera's closest (4 px per metre)" % title)
		_save(z2r, "%s_ruin_z2.png" % id, id, 2.0, "%s destroyed at zoom 2" % title)
		_save(tr, "%s_turned_z1.png" % id, id, 1.0, "%s turned by its heading (about 51 degrees clockwise), baked already turned: the light and the shadows stay the map's" % title)
		_say("%s drawn: %s" % [id, str(models[id].p)])
	_say("frames drawn: %d" % frames.size())
	await _sheet()
	_write_frames_json()
	_write_board_json()
	quit(1 if failures > 0 else 0)

# --- the sheet ------------------------------------------------------------------------------------------------------------------

func _box(sh: BoardSheet, img: Image, pos: Vector2, scale_f: float = 1.0) -> Vector2:
	var sz := Vector2(img.get_size()) * scale_f
	sh.image(img, pos, Rect2(), sz)
	sh.rect(Rect2(pos, sz), sh.c_chip_line, false, 1.0)
	return sz

func _sheet() -> void:
	var looks: Array = StaticArt.mc_looks()
	var head_h := 338.0
	var row_h := 24.0 + float(Z1_SIZE.y) + 34.0 + float(PLAN_SIZE.y) * INFLATE + 34.0 + float(Z2_SIZE.y) + 44.0
	var pal_h := 560.0
	var total := int(head_h + float(looks.size()) * row_h + pal_h)
	var sh := BoardSheet.new(style, Vector2i(W, total))
	var tw := float(W) - MARGIN * 2.0
	sh.text(Vector2(MARGIN, 34.0), "The military complex: hangar yard, works, depot  ·  seed %d" % SEED, 25.0, sh.c_text)
	var hy := 52.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "Alex (2026-10-11, decision suppress-mission): \"Clear mobile Aa units and their escorts to enable a bombing run of a military complex.\" The complex is the second mission's target (data/units/military_complex.json: static, no weapons, 12 pips, 80 x 60 m). This board asks how it LOOKS: three looks of one seeded generator in the village's building language and the unit sheet's pen (scripts/ui/unit_marker_art_static.gd; sheet index 8, the next after the mobile gun's 7), each whole and DESTROYED, at the planning zoom 0.35, at zoom 1 and at zoom 2. Drawn by the game itself: the real markers on the game's own paper and road; the tower, the battery and a light fighter at the low band stand beside it for scale. Nothing is chosen (chosen: null); every option and number is PROPOSED by Track M2U.", 12.5, sh.c_muted, tw, true) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "SCALE (the brief: a static target drawn at the map's scale): the complex is MAP SCENERY with a unit's behaviour, drawn at the map's 2 px per metre x zoom like the village's houses and the bridges (a village house is 20 x 11 m, the hangar 35 x 18), not at the units' scale; the tower and the battery beside it keep the rule the game gives them (twice the planes'), which is why they look big. The marker layer sizes a marker at the plane rule, so the generator draws at half of it (data military_complex.map_scale_factor 0.5, PROPOSED); under the planes' 14 px floor (zoom 0.39) the complex stays the size it has there, as a plane does. ROOFS are the village's: two halves, the half turned from the sun in the shaded roof tone (the blue-grey), ribs across the pitch for corrugated sheet in place of the village's thatch strokes, an inset eave line, the outline, the ridge; the hall in B has saw-tooth strips; walls and the low wall in C are the wall fill and its slope tone; the shadows are every part cast by its height (the chimney's is 25 m).", 12.5, sh.c_muted, tw, true) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "ONE ACCENT ZONE per look, in the side's colour (the enemy's slate blue), nowhere else: a recognition panel painted on the main roof, put on whichever roof half is lit (the style guide's rule is one zone per unit; the tower's is its hut roof). DESTROYED is R1's language (the tower's ruin, decision strike-plan: a ruin, a crater and a smoke column, no fire): scorch (dirt stipple, thick in the middle, thinning out), pale-lipped craters, the main building roofless with its walls half standing, its floor black and a piece of torn roof lying across the hole, the sheds in heaps of broken roof and masonry, a fuel tank burst, the chimney down in two pieces (B), the fence half gone, wrecks of the trucks. The smoke column is the effects layer's, not drawn here. THE RUIN IS NOT WIRED INTO THE GAME YET: a destroyed static unit's marker goes at its down_at and the effects layer's ruin takes its place (Track X; fx.ruin takes a kind), so wiring is UnitMarkerArtStatic.complex_ruin_art into that layer for kind military_complex.", 12.5, sh.c_muted, tw, true)
	var y := head_h
	for look in looks.size():
		var L: Dictionary = looks[look]
		var id := str(L["id"])
		sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
		sh.text(Vector2(MARGIN, y + 20.0), "%s  ·  %s" % [L["letter"], L["title"]], 17.0, sh.c_text)
		sh.text(Vector2(MARGIN + 700.0, y + 20.0), "ui.json unit_art.variant.military_complex = %d   ·   accent: %s" % [look, L["accent_zone"]], 12.0, sh.c_muted, true)
		var iy := y + 30.0
		var a := _box(sh, imgs[id + "/z1"], Vector2(MARGIN, iy))
		sh.text(Vector2(MARGIN, iy + a.y + 13.0), "whole, zoom 1, 1:1 (with the tower, the battery and a light fighter)", 11.0, sh.c_muted, true)
		var b := _box(sh, imgs[id + "/ruin_z1"], Vector2(MARGIN + a.x + 12.0, iy))
		sh.text(Vector2(MARGIN + a.x + 12.0, iy + b.y + 13.0), "destroyed, zoom 1, 1:1", 11.0, sh.c_muted, true)
		var tx := MARGIN + a.x + b.x + 40.0
		var m: UnitMarkerArt.Model = models[id]
		var hh := sh.paragraph(Vector2(tx, iy), str(L["about"]), 12.0, sh.c_text, float(W) - MARGIN - tx, false, 3.0)
		sh.paragraph(Vector2(tx, iy + hh + 8.0), "DRAWN: main building %.0f x %.0f m. %s" % [float(m.p.main_w), float(m.p.main_d), _look_notes(id)], 12.0, sh.c_muted, float(W) - MARGIN - tx, true, 3.0)
		# the planning zoom: whole and destroyed, each 1:1 and at 3x
		var jy := iy + a.y + 34.0
		var p1 := _box(sh, imgs[id + "/plan"], Vector2(MARGIN, jy))
		var p2 := _box(sh, imgs[id + "/plan"], Vector2(MARGIN + p1.x + 12.0, jy), INFLATE)
		sh.text(Vector2(MARGIN, jy + p2.y + 13.0), "whole at the planning zoom 0.35: 1:1, and at 3x (nearest)", 11.0, sh.c_muted, true)
		var px := MARGIN + p1.x + p2.x + 48.0
		var p3 := _box(sh, imgs[id + "/ruin_plan"], Vector2(px, jy))
		var p4 := _box(sh, imgs[id + "/ruin_plan"], Vector2(px + p3.x + 12.0, jy), INFLATE)
		sh.text(Vector2(px, jy + p4.y + 13.0), "destroyed at the planning zoom 0.35: 1:1, and at 3x", 11.0, sh.c_muted, true)
		# zoom 2 and the turned one
		var ky := jy + p2.y + 34.0
		var z2a := _box(sh, imgs[id + "/z2"], Vector2(MARGIN, ky))
		sh.text(Vector2(MARGIN, ky + z2a.y + 13.0), "whole at zoom 2 (the camera's closest)", 11.0, sh.c_muted, true)
		var z2b := _box(sh, imgs[id + "/ruin_z2"], Vector2(MARGIN + z2a.x + 12.0, ky))
		sh.text(Vector2(MARGIN + z2a.x + 12.0, ky + z2b.y + 13.0), "destroyed at zoom 2", 11.0, sh.c_muted, true)
		var tr := _box(sh, imgs[id + "/turned"], Vector2(MARGIN + z2a.x + z2b.x + 36.0, ky))
		sh.text(Vector2(MARGIN + z2a.x + z2b.x + 36.0, ky + tr.y + 13.0), "turned by its heading, zoom 1", 11.0, sh.c_muted, true)
		y += row_h
	_palette_strip(sh, Vector2(MARGIN, y), float(W) - MARGIN * 2.0)
	var err: int = await sh.save(self, base.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[military-complex-board] could not write board.png: ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), W, total])

func _look_notes(id: String) -> String:
	match id:
		"hangar_yard":
			return "READING IT: the one with the clearest silhouette at the planning zoom, a long pale roof with a pale apron in front of it and two round tanks; reads as an airfield's corner, which a bombing run plausibly goes for. The hangar's roof is the village's gable made big, with the vault drawn as lines along it."
		"works":
			return "READING IT: the most distinctive and the most legible from far away: the saw-tooth roof is a striped block and the chimney throws a long shadow across the open ground south-east of the fence, a tell that stands out at the planning zoom like the tower's lattice does. The most to draw."
		"depot":
			return "READING IT: the quietest and the most like the village (low walls, long roofs round a yard), and so the one that reads as a military place least: nearest to a farm until the vehicles and the flag are seen. The wall casts a thin shadow; the cheapest to draw."
	return ""

# --- the palette strip ------------------------------------------------------------------------------------------------------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	var rl := StaticArt.mc_roles(style)
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0.0, 26.0), "The palette, and what the compound spends of it (roles in data/ui/unit_art_mission2.json, no hex in the draw code)", 17.0, sh.c_text)
	var pal: Dictionary = style.palette
	var paper: Color = pal["paper"]
	var chips: Array = [
		["paper (the ground)", paper],
		["ink", pal["ink"]],
		["roof lit", pal["roof_lit"]],
		["roof shaded (42% shadow)", rl["roof_shaded"]],
		["wall fill (the low wall, C)", pal["wall_fill"]],
		["wall slope (30% shadow)", UiStyle.mix8(pal["shadow"], pal["wall_fill"], 1.0 - float(style.mixes["wall_slope_shadow_mix"]))],
		["object fill (tanks, vehicles)", pal["object_fill"]],
		["rock fill (ruin masonry)", pal["rock_fill"]],
		["yard: dirt at 0.1 on paper", BoardSheet.over(rl["yard"], paper)],
		["dirt (stipple)", pal["dirt"]],
		["ruin char: dirt at 0.55", BoardSheet.over(rl["ruin_char"], paper)],
		["crater pit: ink at 0.17", BoardSheet.over(rl["pit"], paper)],
		["crater lip", BoardSheet.over(rl["lip"], paper)],
		["side_b (the accent panel)", pal["side_b"]],
		["shadow tint at 0.44 on paper", BoardSheet.over(Color(pal["shadow"].r, pal["shadow"].g, pal["shadow"].b, style.color("unit_shadow").a), paper)],
	]
	var x := pos.x
	var cy := pos.y + 44.0
	for c: Array in chips:
		var col: Color = c[1]
		if x + 150.0 > pos.x + width:
			x = pos.x
			cy += 92.0
		sh.chip(Vector2(x, cy), col, str(c[0]), BoardSheet.oklch_text(col), Vector2(110.0, 40.0))
		x += 150.0
	var roof_l: float = BoardSheet.oklch(pal["roof_lit"]).x
	var shaded_l: float = BoardSheet.oklch(rl["roof_shaded"]).x
	var paper_l: float = BoardSheet.oklch(paper).x
	var yy := cy + 90.0
	var lines: Array = [
		"HOW THE PALETTE STAYS ONE PALETTE. The compound adds no hue and uses no accent but the one panel: every surface is the paper ramp the village's houses and walls are drawn in -- the roof's lit half (L %.3f) and its shaded half, the one mix toward the shadow tint (L %.3f), against the paper's L %.3f; the low wall in C the wall fill and its slope mix; vehicles and tanks the object fill; the apron the wall fill; the yard dirt at 0.1 under the same dirt stipple the ground uses. Material is linework: corrugation is rib lines, the vault lines along it, saw-tooth strips boundary lines and glazing ticks, tracks tyre lines, the fence thin ink with dot posts, the apron expansion joints. The destroyed look takes R1's own roles (char, pit, lip, scar dots: the same palette colours at the same alphas), so a ruin of the tower and a ruin of the complex read as one burnt map." % [roof_l, shaded_l, paper_l],
		"THE ACCENT is the enemy's slate blue (side_b) on the main roof; on the lit roof half it is the strongest contrast the compound has, so the target reads from the planning zoom as the one blue fleck. In the destroyed frames the panel is gone with the roof (the accent is not drawn on a ruin). A player-owned complex would take brick red (side_a) by the same call. SHADOWS are cast by part height, as the tower's: they fall under the unit's own roofs only where the art is transparent (the marker draws its shadow below its art), so the chimney's shadow shows across open ground and not across a roof.",
	]
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width, false, 3.0) + 6.0

# --- the records ----------------------------------------------------------------------------------------------------------------------

func _write_frames_json() -> void:
	var f := FileAccess.open(base.path_join("frames.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[military-complex-board] could not write frames.json")
		return
	f.store_string(JSON.stringify({"id": "military-complex", "about": "Every frame of the military complex board as its own PNG at native size, with its zoom and a caption. board.png is the sheet; the 3x copies on it are nearest-neighbour copies of the *_plan.png frames.", "frames": frames}, "  ", false))
	f.close()

func _write_board_json() -> void:
	var options: Array = []
	var looks: Array = StaticArt.mc_looks()
	for look in looks.size():
		var L: Dictionary = looks[look]
		var id := str(L["id"])
		var m: UnitMarkerArt.Model = models[id]
		options.append({"name": str(L["letter"]), "title": str(L["title"]), "look": id, "ui.json unit_art.variant.military_complex": look, "proposed": true,
			"files": ["%s_z1.png" % id, "%s_ruin_z1.png" % id, "%s_plan.png" % id, "%s_ruin_plan.png" % id, "%s_z2.png" % id, "%s_ruin_z2.png" % id, "%s_turned_z1.png" % id],
			"description": str(L["about"]), "accent_zone": str(L["accent_zone"]), "drawn_as": m.p, "seed": m.seed,
			"parameters": {"main": L["main"], "ranges": L["ranges"], "fence": L["fence"], "gate": L["gate"]}})
	var pal: Dictionary = style.palette
	var rl := StaticArt.mc_roles(style)
	var doc := {
		"id": "military-complex",
		"date": "2026-10-11",
		"area": "Units, Missions",
		"question": "How does the military complex look, whole and destroyed? Alex's second mission profile (decision suppress-mission): 'Clear mobile Aa units and their escorts to enable a bombing run of a military complex.'",
		"source": "scripts/ui/boards/military_complex_board_shot.gd: the new generator in scripts/ui/unit_marker_art_static.gd (the military complex section), drawn through the game's own markers (scripts/ui/unit_marker.gd) and baked art by scripts/ui/boards/m2_frame.gd, on the game's own paper and road; the ruin is the art UnitMarkerArtStatic.complex_ruin_art bakes, placed as the effects layer would place a ruin. No sandbox is stood up and nothing in the game changes but the art cache",
		"seed": SEED,
		"held_constant": {
			"scale": "the MAP's (2 px per metre x zoom: 2 at zoom 1, 4 at zoom 2, about 0.8 at the planning zoom 0.35, a little over the map's 0.7 because the planes' 14 px floor holds the marker rule), data military_complex.map_scale_factor 0.5 of the marker rule (PROPOSED); the tower and the battery beside it at the game's rule for static units (twice the planes')",
			"footprint": "80 x 60 m with the fence 4 m inside it (data military_complex.footprint_m, PROPOSED)",
			"light": "the map's sun (north-west, elevation 46, shadow strength 0.44), every part cast by its height (data heights_m)",
			"pen": "the game's own pen (render_defaults linework.pen, shadow side)",
			"accent": "one zone per look: a recognition panel on the main roof, on the lit half, in the enemy's slate blue (side_b)",
			"destroyed": "R1's language (the tower's ruin: scorch, pale-lipped craters, the hall roofless with a torn roof lying across it, heaps, the fence half down), no fire; the smoke column is the effects layer's",
			"data_that_changes_between_options": "ui.json unit_art.variant.military_complex (the look index) and nothing else",
		},
		"parameter": "data/ui/unit_art_mission2.json military_complex.default_look (PROPOSED: %d, the hangar yard) until Alex picks; ui.json unit_art.variant.military_complex overrides it once the pick is made" % int(StaticArt.mc_val(StaticArt.mc_data()["default_look"])),
		"options": options,
		"palette_check": "No option adds a hue and the only accent is the one roof panel (side_b L %.3f C %.3f). Surfaces are the paper ramp the village uses (roof lit L %.3f, roof shaded L %.3f, wall fill L %.3f, object fill L %.3f against paper L %.3f); the ruin uses R1's roles (char = dirt at 0.55 L %.3f over paper, pit = ink at 0.17). Material is linework." % [
			BoardSheet.oklch(pal["side_b"]).x, BoardSheet.oklch(pal["side_b"]).y, BoardSheet.oklch(pal["roof_lit"]).x, BoardSheet.oklch(rl["roof_shaded"]).x,
			BoardSheet.oklch(pal["wall_fill"]).x, BoardSheet.oklch(pal["object_fill"]).x, BoardSheet.oklch(pal["paper"]).x, BoardSheet.oklch(BoardSheet.over(rl["ruin_char"], pal["paper"])).x],
		"recommendation_proposed": "A, the hangar yard, as the working default (PROPOSED by Track M2U, Alex decides): the clearest silhouette at the planning zoom (one long pale roof, a pale apron, round tanks) and the most obviously a target for a bomber; its blue panel sits on the lit half of a big pale roof where it reads best. B is the most distinctive at distance (the saw-tooth block and the chimney's long shadow, the same kind of tell as the tower's lattice) at the price of the most drawing; C is the quietest and the most like the village.",
		"wiring_note": "The standing complex is wired through unit_marker_art.gd's one dispatch line (silhouette military_complex). The DESTROYED look is baked by UnitMarkerArtStatic.complex_ruin_art(style, ppm, rot) and is NOT wired: a destroyed static unit's marker goes at its down_at and the effects layer's ruin (scripts/fx, fx.ruin(unit, pos, t, kind, size, heading)) takes its place, so the effects layer needs a kind 'military_complex' that blits this art in place of its battery scorch.",
		"frames": "frames.json (every frame whole, native size)",
		"sheet": "board.png (each look whole and destroyed at zoom 1, the planning zoom 1:1 and 3x, zoom 2, and turned; a palette strip)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(base.path_join("board.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[military-complex-board] could not write board.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved board.json")
