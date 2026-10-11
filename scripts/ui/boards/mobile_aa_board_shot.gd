extends SceneTree

# BOARD: THE MOBILE ANTI-AIRCRAFT GUN (Track M2U, mission 2). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/mobile_aa_board_shot.gd -- [out=variants/mobile-aa]
#
# Alex's second mission profile (2026-10-11, decision suppress-mission): "Clear mobile Aa units and their escorts to enable a bombing
# run of a military complex." The mobile AA gun is a new unit and has no art. HOW IT LOOKS is this board's question and NOTHING IS CHOSEN:
# three looks of one generator (scripts/ui/unit_marker_art_mobile_aa.gd, the unit sheet's style: a tracked or half-tracked chassis,
# the gun's barrels drawn raised and foreshortened as the battery's are), each ONE accent zone in the side's colour, drawn BY THE GAME:
# the real markers (scripts/ui/unit_marker.gd) with the baked art unit_marker_art.gd returns, on the game's own paper and road (the
# ground code of scripts/render/ink_ground.gd), the shadows merged and tinted once at the map's shadow strength, the scale the
# sandbox's plane rule gives at that zoom (scripts/ui/boards/m2_frame.gd). ONLY data/ui/ui.json unit_art.variant.mobile_aa changes between
# the options (the seed and the sheet index are the same: 7, the next after the radio tower's 6).
#
# Each option is shown BESIDE A TANK AND THE ANTI-AIRCRAFT BATTERY (the things it sits with), at the planning zoom 0.35 and at zoom 1 (full
# size), and closer at zoom 2 (the camera's closest): three headings of the vehicle in the enemy's slate and one in the players' brick red.
#
# Output (out=): board.png (the sheet), <id>_z1.png / _plan.png / _z2.png (every frame whole, native size), shadow_rule.png, frames.json,
# board.json ("chosen": null for Alex to choose).
#
# EVERY OPTION AND VALUE IS PROPOSED by Track M2U; none is a decision.

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const M2Frame = preload("res://scripts/ui/boards/m2_frame.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const MobileAA = preload("res://scripts/ui/unit_marker_art_mobile_aa.gd")

const SEED := 20261009
const OUT_DEFAULT := "variants/mobile-aa"
const MARGIN := 24.0
const W := 1480
const Z1_SIZE := Vector2i(420, 150)
const PLAN_SIZE := Vector2i(240, 70)
const Z2_SIZE := Vector2i(520, 170)
const INFLATE := 3.0

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
	print("[mobile-aa-board] ", msg)

func _save(img: Image, file: String, look: String, zoom: float, caption: String) -> void:
	var err := img.save_png(base.path_join(file))
	if err != OK:
		failures += 1
		printerr("[mobile-aa-board] could not write ", file)
	frames.append({"file": file, "look": look, "zoom": zoom, "caption": caption, "size": [img.get_width(), img.get_height()]})

# The row of things, the same for every option: a tank, the vehicle at three headings in slate and once in brick red, the battery.
func _row() -> Array:
	return [
		{"silhouette": "tank", "side": "axis", "at": Vector2(-80.0, 0.0), "heading": 0.0, "size_m": 6.0},
		{"silhouette": "mobile_aa", "side": "axis", "at": Vector2(-48.0, 0.0), "heading": 0.0, "size_m": 6.5},
		{"silhouette": "mobile_aa", "side": "axis", "at": Vector2(-16.0, 0.0), "heading": PI / 2.0, "size_m": 6.5},
		{"silhouette": "mobile_aa", "side": "axis", "at": Vector2(16.0, 0.0), "heading": PI * 1.25, "size_m": 6.5},
		{"silhouette": "mobile_aa", "side": "allies", "at": Vector2(48.0, 0.0), "heading": 0.0, "size_m": 6.5},
		{"silhouette": "anti_aircraft_battery", "side": "axis", "at": Vector2(84.0, 0.0), "heading": 0.4, "size_m": 14.0, "static_rule": true},
	]

# The shadow comparison: the same vehicles with the layer as it was (cast_h 0: the shadow under the vehicle) and as it is now.
func _pair(as_it_was: bool) -> Array:
	var items: Array = [
		{"silhouette": "tank", "side": "axis", "at": Vector2(-18.0, 0.0), "heading": 0.0, "size_m": 6.0},
		{"silhouette": "mobile_aa", "side": "axis", "at": Vector2(10.0, 0.0), "heading": 0.0, "size_m": 6.5},
		{"silhouette": "mobile_aa", "side": "axis", "at": Vector2(34.0, 0.0), "heading": PI * 0.5, "size_m": 6.5}]
	if as_it_was:
		for it: Dictionary in items:
			it["cast_h"] = 0.0
	return items

func _close_row() -> Array:
	return [
		{"silhouette": "tank", "side": "axis", "at": Vector2(-52.0, 0.0), "heading": 0.0, "size_m": 6.0},
		{"silhouette": "mobile_aa", "side": "axis", "at": Vector2(-22.0, 0.0), "heading": 0.0, "size_m": 6.5},
		{"silhouette": "mobile_aa", "side": "allies", "at": Vector2(6.0, 0.0), "heading": PI * 0.75, "size_m": 6.5},
		{"silhouette": "anti_aircraft_battery", "side": "axis", "at": Vector2(46.0, 0.0), "heading": 0.4, "size_m": 14.0, "static_rule": true},
	]

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[mobile-aa-board] a board needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(Vector2i(1280, 720))
	for _i in 10:
		await process_frame
	style = UiStyle.shared() as UiStyle
	if not style.ok():
		printerr("[mobile-aa-board] style errors: ", style.errors)
		quit(1)
		return
	frame = M2Frame.new(self, style)
	base = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var looks: Array = MobileAA.looks()
	for look in looks.size():
		var L: Dictionary = looks[look]
		var id := str(L["id"])
		style.ui["unit_art"]["variant"]["mobile_aa"] = look
		models[id] = MobileAA.model_for(style, look)
		var z1: Image = await frame.render(Z1_SIZE, 1.0, _row())
		var pl: Image = await frame.render(PLAN_SIZE, 0.35, _row())
		var z2: Image = await frame.render(Z2_SIZE, 2.0, _close_row())
		imgs[id + "/z1"] = z1
		imgs[id + "/plan"] = pl
		imgs[id + "/z2"] = z2
		var title := "%s  %s" % [L["letter"], L["title"]]
		_save(z1, "%s_z1.png" % id, id, 1.0, "%s at zoom 1 (the vehicle 4 px per metre, the battery 8): a tank, the vehicle at three headings in the enemy's slate blue and once in the players' brick red, the battery" % title)
		_save(pl, "%s_plan.png" % id, id, 0.35, "%s at the planning zoom 0.35 (the planes' 14 px floor: the vehicle about 1.6 px per metre)" % title)
		_save(z2, "%s_z2.png" % id, id, 2.0, "%s at zoom 2, the camera's closest (the vehicle 8 px per metre)" % title)
		_say("%s drawn: %s" % [id, str(models[id].p)])
	# the shadow rule: the same two vehicles as the layer draws a ground unit today (no offset: the shadow hides under it) and with the sun's rule
	style.ui["unit_art"]["variant"]["mobile_aa"] = MobileAA.default_look()
	var rule_a: Image = await frame.render(Vector2i(280, 110), 2.0, _pair(true))
	var rule_b: Image = await frame.render(Vector2i(280, 110), 2.0, _pair(false))
	imgs["rule/today"] = rule_a
	imgs["rule/sun"] = rule_b
	_save(rule_a, "shadow_rule_today.png", "shadow_rule", 2.0, "A ground vehicle's shadow as the marker layer drew it before this change: its footprint offset by the layer's shadow offset for its height, which is 0 at the surface, so the shadow hides under it")
	_save(rule_b, "shadow_rule_sun.png", "shadow_rule", 2.0, "The same vehicles with the marker layer's rule now (ui.json marker.cast_shadow_on, PROPOSED, on): the footprint offset by height x 0.97 m away from the sun (marker.cast_height_m: 2.0 m for the tank, 2.4 m for the gun)")
	_say("frames drawn: %d" % frames.size())
	await _sheet()
	_write_frames_json()
	_write_board_json()
	quit(1 if failures > 0 else 0)

# --- the sheet --------------------------------------------------------------------------------------------------------------------

func _box(sh: BoardSheet, img: Image, pos: Vector2, scale_f: float = 1.0) -> Vector2:
	var sz := Vector2(img.get_size()) * scale_f
	sh.image(img, pos, Rect2(), sz)
	sh.rect(Rect2(pos, sz), sh.c_chip_line, false, 1.0)
	return sz

func _sheet() -> void:
	var looks: Array = MobileAA.looks()
	var head_h := 318.0
	var row_h := 24.0 + float(PLAN_SIZE.y) * INFLATE + 30.0 + float(Z2_SIZE.y) + 50.0
	var rule_h := 230.0
	var pal_h := 620.0
	var total := int(head_h + float(looks.size()) * row_h + rule_h + pal_h)
	var sh := BoardSheet.new(style, Vector2i(W, total))
	var tw := float(W) - MARGIN * 2.0
	sh.text(Vector2(MARGIN, 34.0), "The mobile anti-aircraft gun: half-track, open turret, ring carrier  ·  seed %d" % SEED, 25.0, sh.c_text)
	var hy := 52.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "Alex (2026-10-11, decision suppress-mission): \"Clear mobile Aa units and their escorts to enable a bombing run of a military complex.\" The gun is a new unit (data/units/mobile_aa.json: a ground vehicle that drives like the tank, 6.5 m long, and shoots up like the battery's light flak, so it covers the low band and not the medium). This board asks how it LOOKS: three looks of one seeded generator in the unit sheet's style (scripts/ui/unit_marker_art_mobile_aa.gd; sheet index 7, the next after the tower's 6), drawn by the game itself: the real markers with the baked art, on the game's own paper and road, the shadows merged at the map's strength. Nothing is chosen (chosen: null); every option and number is PROPOSED by Track M2U.", 12.5, sh.c_muted, tw, true) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "WHAT STAYS THE SAME: the seed and the sheet index; the scale (units at the planes' own scale: a light fighter 36 px across at zoom 1, never under 14 px, so the 6.5 m vehicle is about 26 px long at zoom 1 and 10 px at the planning zoom, a tank 24 and 9; the battery is drawn at twice the plane rule, 64 px across at zoom 1, 25 at the planning zoom); the pen (the shadow-side pen); the sun (north-west, shadows south-east, one merged tint at 0.44); the colour roles. ONE ACCENT ZONE per look, in the side's colour, nowhere else: the cab roof (A), the engine deck as the tank's (B), the rear deck (C). Each row is one option: the planning zoom twice (1:1 and 3x so the pixels can be seen), then zoom 1 beside it, then zoom 2 below with the tank and the battery.", 12.5, sh.c_muted, tw, true) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "A GROUND VEHICLE'S SHADOW (done, on the lead's request, PROPOSED and behind a data switch): the marker layer used to place a shadow at the unit's height above the ground, which is 0 for a unit at the surface, so a tank and this vehicle cast none. The layer now lifts a surface unit's shadow by its height x the sun's length (the style guide's rule: one sun, NW, elevation 46 degrees, length height / tan 46) when ui.json marker.cast_shadow_on is true and the silhouette has a height in marker.cast_height_m (tank 2.0 m, mobile gun 2.4 m); the planes, the tower and the battery are untouched. Every frame here is the game's rule as it stands; the last frames show it against the layer as it was. The unit's accent is the enemy's slate blue; the brick red one is the same vehicle on the players' side.", 12.5, sh.c_muted, tw, true)
	var y := head_h
	for look in looks.size():
		var L: Dictionary = looks[look]
		var id := str(L["id"])
		sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
		sh.text(Vector2(MARGIN, y + 20.0), "%s  ·  %s" % [L["letter"], L["title"]], 17.0, sh.c_text)
		sh.text(Vector2(MARGIN + 700.0, y + 20.0), "ui.json unit_art.variant.mobile_aa = %d   ·   accent: %s" % [look, L["accent_zone"]], 12.0, sh.c_muted, true)
		var iy := y + 30.0
		# the planning zoom: 1:1 and at 3x, then zoom 1
		var a := _box(sh, imgs[id + "/plan"], Vector2(MARGIN, iy))
		sh.text(Vector2(MARGIN, iy + a.y + 13.0), "planning zoom 0.35, 1:1: what the player sees", 11.0, sh.c_muted, true)
		var x2 := MARGIN + a.x + 24.0
		var b := _box(sh, imgs[id + "/plan"], Vector2(x2, iy), INFLATE)
		sh.text(Vector2(x2, iy + b.y + 13.0), "the same frame at 3x (nearest)", 11.0, sh.c_muted, true)
		var x3 := x2 + b.x + 24.0
		var c := _box(sh, imgs[id + "/z1"], Vector2(x3, iy), 1.0)
		sh.text(Vector2(x3, iy + c.y + 13.0), "zoom 1, 1:1", 11.0, sh.c_muted, true)
		var jy := iy + b.y + 30.0
		var d := _box(sh, imgs[id + "/z2"], Vector2(MARGIN, jy))
		sh.text(Vector2(MARGIN, jy + d.y + 13.0), "zoom 2 (the camera's closest): the tank, the vehicle turned east, the same vehicle on the players' side turned south-east, the battery", 11.0, sh.c_muted, true)
		var tx := MARGIN + d.x + 24.0
		var m: UnitMarkerArt.Model = models[id]
		var hh := sh.paragraph(Vector2(tx, jy), str(L["about"]), 12.0, sh.c_text, float(W) - MARGIN - tx, false, 3.0)
		sh.paragraph(Vector2(tx, jy + hh + 8.0), "DRAWN: %.1f x %.1f m, %d barrels%s. %s" % [float(m.p.length), float(m.p.width), int(m.p.guns), ", rivets" if bool(m.p.rivets) else "", _look_notes(id)], 12.0, sh.c_muted, float(W) - MARGIN - tx, true, 3.0)
		y += row_h
	# the shadow rule
	sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 22.0), "A ground vehicle's shadow: as the layer was, and now (marker.cast_shadow_on, PROPOSED)", 17.0, sh.c_text)
	var ry := y + 36.0
	var r1 := _box(sh, imgs["rule/today"], Vector2(MARGIN, ry))
	sh.paragraph(Vector2(MARGIN, ry + r1.y + 4.0), "before: the layer's offset for a unit at the surface was 0 (the shadow is under the vehicle)", 11.0, sh.c_muted, r1.x, true, 2.0)
	var r2 := _box(sh, imgs["rule/sun"], Vector2(MARGIN + r1.x + 24.0, ry))
	sh.paragraph(Vector2(MARGIN + r1.x + 24.0, ry + r2.y + 4.0), "now: the footprint offset by height x 0.97 m, away from the sun", 11.0, sh.c_muted, r2.x, true, 2.0)
	var rtx := MARGIN + r1.x + r2.x + 72.0
	sh.paragraph(Vector2(rtx, ry), "The footprint offset is what a prism of the vehicle's height casts beyond it: the mask is the footprint with the barrels, lifted by marker.cast_height_m (tank 2.0 m, mobile gun 2.4 m, both PROPOSED), so the turret's and the barrels' longer shadows are not drawn (the cruiser's rule, Track SH). The offset is in screen space, the sun does not turn with the hull, which is right. Turning marker.cast_shadow_on off brings back the layer as it was (a ship's shadow too).", 12.0, sh.c_muted, float(W) - MARGIN - rtx, true, 3.0)
	y += rule_h
	_palette_strip(sh, Vector2(MARGIN, y), float(W) - MARGIN * 2.0)
	var err: int = await sh.save(self, base.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[mobile-aa-board] could not write board.png: ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), W, total])

func _look_notes(id: String) -> String:
	match id:
		"halftrack":
			return "READING IT: the longest, narrowest, and the one least like the tank: wheels at the front, tracks at the back, an open bed with a round mount. At the planning zoom it is a dark bar with a bright cab. Four barrels (or two) point forward over the cab."
		"turret":
			return "READING IT: the nearest to the tank (the same hull and the same accent zone), told apart by an eight-sided open tub with two barrels raised over the bow in place of a mantlet and a gun; the likeliest to be mistaken for a tank at the planning zoom."
		"carrier":
			return "READING IT: the one that looks like the battery that moves (a ring round a pedestal mount, the battery's sandbag ring in steel), which is the best clue to what it does; the accent strip is the smallest of the three."
	return ""

# --- the palette strip --------------------------------------------------------------------------------------------------------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0.0, 26.0), "The palette, and what the vehicle spends of it (roles from the palette; no hex in the draw code)", 17.0, sh.c_text)
	var pal: Dictionary = style.palette
	var shadow_c: Color = pal["shadow"]
	var chips: Array = [
		["paper (the ground)", pal["paper"]],
		["ink", pal["ink"]],
		["object fill (hull)", style.color("art_fill")],
		["fill shaded (turret, mount)", style.color("art_fill_shaded")],
		["rock fill (tracks, tyres)", pal["rock_fill"]],
		["glass lit (windscreen)", style.color("art_glass_lit")],
		["glass shaded", style.color("art_glass_shaded")],
		["slope (glacis, B)", UiStyle.mix8(pal["shadow"], pal["object_fill"], 1.0 - float(style.mixes["wall_slope_shadow_mix"]))],
		["side_b (enemy accent)", pal["side_b"]],
		["side_a (players' accent)", pal["side_a"]],
		["shadow tint at 0.44 on paper", BoardSheet.over(Color(shadow_c.r, shadow_c.g, shadow_c.b, style.color("unit_shadow").a), pal["paper"])],
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
	var paper_l: float = BoardSheet.oklch(pal["paper"]).x
	var fill_l: float = BoardSheet.oklch(style.color("art_fill")).x
	var rock_l: float = BoardSheet.oklch(pal["rock_fill"]).x
	var yy := cy + 90.0
	var lines: Array = [
		"HOW THE PALETTE STAYS ONE PALETTE. Hue is reserved for paper, ink, the shadow tint and the two side accents, and the vehicle adds none: its hull is the OBJECT FILL (L %.3f) a step off the paper (L %.3f), the tracks and tyres the ROCK fill (L %.3f), the windscreen the planes' glass pair, a face turned from the sun the one mix toward the shadow tint (art_fill_shaded), and the ONE accent zone the side's colour. Lightness is the ramp off paper, material is linework: tracks are hatch links, tyres tread lines, the bed rivets and stipple, the barrels foreshortened strokes. The vehicle sits in the same ramp as the tank beside it and the battery (their fills are the same roles), so it is one drawing." % [fill_l, paper_l, rock_l],
		"THE ACCENT is the side's: the enemy's slate blue (side_b) here, and the same panel in the players' brick red (side_a) in the zoom-1 and zoom-2 frames. At the planning zoom the panel is 2 or 3 px and reads as a bright fleck on a dark bar, the way the tank's does; the board leaves it to Alex whether a gun that is meant to be hunted should have a larger panel. No other part of the vehicle takes the accent: not the barrels, not the wheels, not the shield.",
	]
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width, false, 3.0) + 6.0

# --- the records ---------------------------------------------------------------------------------------------------------------------

func _write_frames_json() -> void:
	var f := FileAccess.open(base.path_join("frames.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[mobile-aa-board] could not write frames.json")
		return
	f.store_string(JSON.stringify({"id": "mobile-aa", "about": "Every frame of the mobile anti-aircraft gun board as its own PNG at native size, with its zoom and a caption. board.png is the sheet; the 3x copies on it are nearest-neighbour copies of the *_plan.png frames.", "frames": frames}, "  ", false))
	f.close()

func _write_board_json() -> void:
	var data: Dictionary = MobileAA.data()
	var options: Array = []
	var looks: Array = MobileAA.looks()
	for look in looks.size():
		var L: Dictionary = looks[look]
		var id := str(L["id"])
		var m: UnitMarkerArt.Model = models[id]
		options.append({"name": str(L["letter"]), "title": str(L["title"]), "look": id, "ui.json unit_art.variant.mobile_aa": look, "proposed": true,
			"files": ["%s_z1.png" % id, "%s_plan.png" % id, "%s_z2.png" % id], "description": str(L["about"]), "accent_zone": str(L["accent_zone"]),
			"drawn_as": m.p, "seed": m.seed, "parameters": {"ranges": L["ranges"], "guns": L["guns"], "rivets_chance": L["rivets_chance"]}})
	var pal: Dictionary = style.palette
	var doc := {
		"id": "mobile-aa",
		"date": "2026-10-11",
		"area": "Units, Missions",
		"question": "How does the mobile anti-aircraft gun look? Alex's second mission profile (decision suppress-mission): 'Clear mobile Aa units and their escorts to enable a bombing run of a military complex.'",
		"source": "scripts/ui/boards/mobile_aa_board_shot.gd: the new generator scripts/ui/unit_marker_art_mobile_aa.gd drawn through the game's own markers (scripts/ui/unit_marker.gd) and baked art (unit_marker_art.gd) by scripts/ui/boards/m2_frame.gd, on the game's own paper and road; no sandbox is stood up and nothing in the game changes but the art cache",
		"seed": SEED,
		"held_constant": {
			"scale": "the sandbox's plane rule (a light fighter 36 px across at zoom 1, never under 14 px): the vehicle about 4 px per metre at zoom 1, 8 at zoom 2 and 1.6 at the planning zoom 0.35; the battery at twice that (marker.static_scale 2)",
			"light": "the map's sun (north-west, elevation 46, shadow strength 0.44), one merged shadow tint",
			"pen": "the game's own pen (render_defaults linework.pen, shadow side)",
			"accent": "one zone per look in the side's colour: the enemy's slate blue (side_b) on most frames, the players' brick red (side_a) on one vehicle in the zoom-1 and zoom-2 frames",
			"beside": "a tank and the anti-aircraft battery, the game's own, at the same zoom",
			"data_that_changes_between_options": "ui.json unit_art.variant.mobile_aa (the look index) and nothing else",
		},
		"parameter": "data/ui/unit_art_mission2.json mobile_aa.default_look (PROPOSED: %d, the half-track) until Alex picks; ui.json unit_art.variant.mobile_aa overrides it once the pick is made" % MobileAA.default_look(),
		"options": options,
		"shadow_rule": {"before": "the marker layer's shadow offset for a unit at the surface was 0: a ground vehicle's shadow was under it (the tank's too)", "now": "ui.json marker.cast_shadow_on (PROPOSED, on) lifts a surface unit's shadow by its marker.cast_height_m (tank 2.0 m, mobile_aa 2.4 m, PROPOSED) x the sun's length away from the sun; the planes, the tower and the battery are untouched", "files": ["shadow_rule_today.png", "shadow_rule_sun.png"],
			"question_for_alex": "keep ground vehicles casting a shadow by that rule (it is on)? The heights are proposed."},
		"palette_check": "No option adds a hue. The hull is the object fill (L %.3f) a step off the paper (L %.3f); tracks and tyres the rock fill (L %.3f); the windscreen the planes' glass roles; a shaded face the one mix toward the shadow tint; the accent zone the side's colour (side_b L %.3f C %.3f, side_a L %.3f C %.3f: equal lightness and chroma). Material is linework." % [
			BoardSheet.oklch(style.color("art_fill")).x, BoardSheet.oklch(pal["paper"]).x, BoardSheet.oklch(pal["rock_fill"]).x,
			BoardSheet.oklch(pal["side_b"]).x, BoardSheet.oklch(pal["side_b"]).y, BoardSheet.oklch(pal["side_a"]).x, BoardSheet.oklch(pal["side_a"]).y],
		"recommendation_proposed": "A, the half-track, as the working default (PROPOSED by Track M2U, Alex decides): it is the look least like the tank at the planning zoom (a long narrow bar against a squat block), and a half-track with a quad mount is the vehicle people picture for the job. C is the one that tells what it does fastest (the battery's ring), at the price of the smallest accent. B is the likeliest to be taken for a tank, which could be wanted (it is a hull the tank track can draw from) or not (the player is meant to find and hunt it).",
		"frames": "frames.json (every frame whole, native size)",
		"sheet": "board.png (each look at the planning zoom 1:1 and 3x, zoom 1 and zoom 2 beside a tank and the battery; the shadow rule; a palette strip)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(base.path_join("board.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[mobile-aa-board] could not write board.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved board.json")
