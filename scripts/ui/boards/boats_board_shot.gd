extends SceneTree

# BOARD: THE TWO SMALL BOATS (Track BB, the water layer). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/boats_board_shot.gd -- [out=variants/boats]
#
# Alex (decision water-layer, 2026-10-10): "We need at least one small boat. Maybe two? Maybe bridges?" The
# lead proposed an armed PATROL BOAT and an unarmed SUPPLY BOAT ("Sounds good"); Alex: "Add the boats just
# as environment", then "Correct, part of the environment with real patrols but no specific part in the
# mission": they are real units that sail a route and can be hit, with no part in the mission, and the patrol
# boat's guns stay quiet. HOW THEY LOOK is this board's question and NOTHING IS CHOSEN.
#
# The art is the new generators in scripts/render/boat_art.gd (the style of the unit sheet's small cruiser),
# drawn through the drawing layer's InkCanvas and the pen Alex chose, in frames made by
# scripts/render/boat_frame.gd on Track WB's proposed water (variants/water/ decides the water).
# Nothing here touches the running game: no sandbox is stood up, every frame is drawn from data and seed.
#
# Output (out=): board.png (the sheet), frames.json (every frame: file, look, zoom, caption), board.json (the
# seed, the parameter set per option, "chosen": null for Alex to choose), and every frame as its own PNG at
# native size: <kind>_<look>_z1.png (zoom 1, side_a above side_b, a light fighter beside), <kind>_<look>_plan.png
# (the planning zoom 0.35), wake_<treatment>_<kind>_z1.png / _plan.png, scale_<zoom>_<rule>.png.
#
# EVERY OPTION AND VALUE IS PROPOSED by Track BB; none is a decision.

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const BoatFrame = preload("res://scripts/render/boat_frame.gd")
const BoatArt = preload("res://scripts/render/boat_art.gd")
const BoatScale = preload("res://scripts/render/boat_scale.gd")

const SEED := 20261009
const OUT_DEFAULT := "variants/boats"
const MARGIN := 24.0
const W := 1480
const Z1 := 1.0
const ZP := 0.35

# The frames. z1: both sides stacked, a light fighter beside; plan: the planning zoom, with a 3x inflated crop.
const Z1_SIZE := Vector2i(400, 200)
const PLAN_SIZE := Vector2i(200, 110)
const PLAN_CROP := Rect2i(72, 10, 108, 84)      # x3 = 324 x 252
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
	print("[boats-board] ", msg)

# --- frames ----------------------------------------------------------------------------------------------------------

func _bow_pos(kind: String, look: String, bow_x: float, y: float, ppm: float) -> Vector2:
	var m := BoatArt.model(style, kind, look)
	return Vector2(bow_x - float(m.p.length) / 2.0 * ppm, y)

func _save(img: Image, file: String, look: String, zoom: float, caption: String) -> void:
	var err := img.save_png(base.path_join(file))
	if err != OK:
		failures += 1
		printerr("[boats-board] could not write ", file)
	frames.append({"file": file, "look": look, "zoom": zoom, "caption": caption, "size": [img.get_width(), img.get_height()]})

# The look's zoom-1 frame: side_a above side_b heading east, a light fighter ahead of them.
func _z1_frame(kind: String, look: String, wake: String) -> Image:
	var ppm := BoatScale.plane_ppm(Z1)
	return BoatFrame.render(style, Z1_SIZE, {"ppm": ppm, "map_ppm": BoatScale.map_ppm(Z1), "wake": wake, "seed": SEED % 9973,
		"boats": [{"kind": kind, "look": look, "side": "a", "pos": _bow_pos(kind, look, 300.0, 50.0, ppm), "heading": 0.0},
			{"kind": kind, "look": look, "side": "b", "pos": _bow_pos(kind, look, 300.0, 150.0, ppm), "heading": 0.0}],
		"planes": [{"type": "light_fighter", "side": "a", "pos": Vector2(366.0, 50.0), "heading": 0.0, "alt_m": 400.0}]})

func _plan_frame(kind: String, look: String, wake: String) -> Image:
	var ppm := BoatScale.plane_ppm(ZP)
	return BoatFrame.render(style, PLAN_SIZE, {"ppm": ppm, "map_ppm": BoatScale.map_ppm(ZP), "wake": wake, "seed": SEED % 9973,
		"boats": [{"kind": kind, "look": look, "side": "a", "pos": _bow_pos(kind, look, 140.0, 32.0, ppm), "heading": 0.0},
			{"kind": kind, "look": look, "side": "b", "pos": _bow_pos(kind, look, 140.0, 82.0, ppm), "heading": 0.0}],
		"planes": [{"type": "light_fighter", "side": "a", "pos": Vector2(172.0, 32.0), "heading": 0.0, "alt_m": 400.0}]})

# --- the run ---------------------------------------------------------------------------------------------------------

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[boats-board] a board needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	style = UiStyle.new()
	if not style.ok():
		printerr("[boats-board] style errors: ", style.errors)
		quit(1)
		return
	base = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var data := BoatArt.data()
	var wake_default := "ink_v"
	# --- frames
	var look_frames: Dictionary = {}     # "<kind>/<look>" -> {z1, plan}
	for kind: String in ["patrol", "supply"]:
		for look: String in BoatArt.looks_of(kind):
			var z1 := _z1_frame(kind, look, wake_default)
			var pl := _plan_frame(kind, look, wake_default)
			look_frames["%s/%s" % [kind, look]] = {"z1": z1, "plan": pl}
			var title: String = str(((data[kind] as Dictionary)["looks"] as Dictionary)[look]["title"])
			_save(z1, "%s_%s_z1.png" % [kind, look], look, Z1, "%s %s, %s: zoom 1 (%.1f px per metre, the plane rule), side_a above side_b, a light fighter ahead, the working-default ink V wake" % [kind, look, title, BoatScale.plane_ppm(Z1)])
			_save(pl, "%s_%s_plan.png" % [kind, look], look, ZP, "%s %s, %s: the planning zoom 0.35 (%.2f px per metre, the plane rule)" % [kind, look, title, BoatScale.plane_ppm(ZP)])
	var wake_frames: Dictionary = {}     # "<wake>/<kind>" -> {z1, plan}
	var wake_look := {"patrol": "p1", "supply": "s1"}
	for w: String in ["ink_v", "foam", "wash"]:
		for kind: String in ["patrol", "supply"]:
			var look: String = wake_look[kind]
			var ppm1 := BoatScale.plane_ppm(Z1)
			var ppmp := BoatScale.plane_ppm(ZP)
			var sz1 := Vector2i(400, 150) if kind == "patrol" else Vector2i(340, 150)
			var bow1 := 380.0 if kind == "patrol" else 322.0
			var z1 := BoatFrame.render(style, sz1, {"ppm": ppm1, "map_ppm": BoatScale.map_ppm(Z1), "wake": w, "seed": 11,
				"boats": [{"kind": kind, "look": look, "side": "a", "pos": _bow_pos(kind, look, bow1, 76.0, ppm1), "heading": 0.0}]})
			var szp := Vector2i(160, 60)
			var pl := BoatFrame.render(style, szp, {"ppm": ppmp, "map_ppm": BoatScale.map_ppm(ZP), "wake": w, "seed": 11,
				"boats": [{"kind": kind, "look": look, "side": "a", "pos": _bow_pos(kind, look, 146.0, 30.0, ppmp), "heading": 0.0}]})
			wake_frames["%s/%s" % [w, kind]] = {"z1": z1, "plan": pl}
			var wt: String = str((data["wakes"] as Dictionary)[w]["title"])
			_save(z1, "wake_%s_%s_z1.png" % [w, kind], look, Z1, "wake %s (%s) behind the %s %s at zoom 1" % [w, wt, kind, look])
			_save(pl, "wake_%s_%s_plan.png" % [w, kind], look, ZP, "wake %s (%s) behind the %s %s at the planning zoom 0.35" % [w, wt, kind, look])
	var strips := _scale_strips()
	var depth := _depth_frames()
	_say("frames drawn: %d" % frames.size())
	await _sheet(look_frames, wake_frames, strips, depth)
	_write_frames_json()
	_write_board_json()
	quit(1 if failures > 0 else 0)

# --- the scale strips ------------------------------------------------------------------------------------------------------

# A row of the roster at one scale: light fighter, heavy fighter, bomber, patrol boat, supply boat, all heading east.
# `boat_rule` "plane" draws the boats at the planes' px per metre, "map" at the map's. Returns {img, items, zoom, rule}.
func _scale_strip(zoom: float, boat_rule: String) -> Dictionary:
	var ppm_plane := BoatScale.plane_ppm(zoom)
	var ppm_boat := ppm_plane if boat_rule == "plane" else BoatScale.map_ppm(zoom)
	var items: Array = [
		{"label": "light fighter 9 m", "plane": "light_fighter", "m": 9.0},
		{"label": "heavy fighter 16 m", "plane": "heavy_fighter", "m": 16.0},
		{"label": "bomber 20 m", "plane": "bomber", "m": 20.0},
		{"label": "patrol boat 27 m", "boat": "patrol", "look": "p1", "m": 27.0},
		{"label": "supply boat 34 m", "boat": "supply", "look": "s1", "m": 34.0}]
	var gap := 26.0 if zoom > 0.5 else 12.0
	var x := 14.0
	var boats: Array = []
	var planes: Array = []
	var placed: Array = []
	var h := 96.0 if zoom > 0.5 else 40.0
	for it: Dictionary in items:
		var ppm := ppm_boat if it.has("boat") else ppm_plane
		var len_px: float = float(it["m"]) * ppm
		var c := Vector2(x + len_px / 2.0, h / 2.0 - 2.0)
		if it.has("boat"):
			var m := BoatArt.model(style, str(it["boat"]), str(it["look"]))
			len_px = float(m.p.length) * ppm
			c = Vector2(x + len_px / 2.0, h / 2.0 - 2.0)
			boats.append({"kind": it["boat"], "look": it["look"], "side": "a", "pos": c, "heading": 0.0, "ppm": ppm, "wake": false})
			placed.append({"label": it["label"], "x": c.x, "w": len_px, "px_per_m": ppm})
		else:
			planes.append({"type": it["plane"], "side": "a", "pos": c, "heading": 0.0, "ppm": ppm, "alt_m": 400.0})
			placed.append({"label": it["label"], "x": c.x, "w": len_px, "px_per_m": ppm})
		x += len_px + gap
	var size := Vector2i(int(x + 6.0), int(h))
	var img := BoatFrame.render(style, size, {"ppm": ppm_plane, "map_ppm": BoatScale.map_ppm(zoom), "wake": "none", "seed": 5, "boats": boats, "planes": planes})
	return {"img": img, "items": placed, "zoom": zoom, "rule": boat_rule}

func _scale_strips() -> Array:
	var out: Array = []
	for z: float in [Z1, ZP]:
		for rule: String in ["plane", "map"]:
			var s := _scale_strip(z, rule)
			out.append(s)
			_save(s["img"], "scale_%s_%s.png" % ["z1" if z > 0.5 else "plan", rule], "scale", z, "the roster at zoom %.2f: planes at the plane rule (%.2f px per metre), boats at the %s rule" % [z, BoatScale.plane_ppm(z), rule])
	return out

# --- the sheet --------------------------------------------------------------------------------------------------------------

func _frame_box(sh: BoardSheet, img: Image, pos: Vector2, scale_f: float = 1.0, crop: Rect2i = Rect2i()) -> Vector2:
	var src := Rect2(Vector2.ZERO, Vector2(img.get_size()))
	if crop.has_area():
		src = Rect2(Vector2(crop.position), Vector2(crop.size))
	var sz := src.size * scale_f
	sh.image(img, pos, src, sz)
	sh.rect(Rect2(pos, sz), sh.c_chip_line, false, 1.0)
	return sz

func _box(sh: BoardSheet, img: Image, pos: Vector2) -> Vector2:
	return _frame_box(sh, img, pos)

func _look_row(sh: BoardSheet, y: float, kind: String, look: String, fr: Dictionary) -> float:
	var d: Dictionary = ((BoatArt.data()[kind] as Dictionary)["looks"] as Dictionary)[look]
	var m := BoatArt.model(style, kind, look)
	var x := MARGIN
	sh.text(Vector2(x, y + 16.0), "%s  ·  %s" % [look.to_upper(), str(d["title"])], 17.0, sh.c_text)
	var iy := y + 24.0
	_frame_box(sh, fr["z1"], Vector2(x, iy))
	sh.text(Vector2(x, iy + float(Z1_SIZE.y) + 14.0), "zoom 1 · %.1f px/m · side_a above side_b · a light fighter ahead" % BoatScale.plane_ppm(Z1), 11.0, sh.c_muted, true)
	var x2 := x + float(Z1_SIZE.x) + 14.0
	var native := _frame_box(sh, fr["plan"], Vector2(x2, iy))
	sh.text(Vector2(x2, iy + float(PLAN_SIZE.y) + 14.0), "planning zoom 0.35 · %.2f px/m, 1:1" % BoatScale.plane_ppm(ZP), 11.0, sh.c_muted, true)
	_frame_box(sh, fr["plan"], Vector2(x2 + native.x + 14.0, iy), INFLATE, PLAN_CROP)
	sh.text(Vector2(x2 + native.x + 14.0, iy + float(PLAN_CROP.size.y) * INFLATE + 14.0), "the same frame, a crop at 3x (nearest): what the player's pixels are", 11.0, sh.c_muted, true)
	var tx := x2 + native.x + 14.0 + float(PLAN_CROP.size.x) * INFLATE + 18.0
	var tw := float(W) - MARGIN - tx
	var line := "boats.json %s.looks.%s  ·  %.1f x %.1f m  ·  detail %d" % [kind, look, float(m.p.length), float(m.p.beam), int(m.p.detail)]
	sh.text(Vector2(tx, iy + 10.0), line, 11.0, sh.c_muted, true)
	var hh := sh.paragraph(Vector2(tx, iy + 26.0), str(d["about"]), 12.5, sh.c_text, tw, false, 3.0)
	sh.paragraph(Vector2(tx, iy + 36.0 + hh), _look_notes(kind, look), 12.0, sh.c_muted, tw, true, 3.0)
	return y + 24.0 + float(PLAN_CROP.size.y) * INFLATE + 14.0 + 26.0

# What each look is for, in a line or two (PROPOSED, mine).
func _look_notes(kind: String, look: String) -> String:
	match look:
		"p1":
			return "Reads as a warship at both zooms: the two gun mounts and the bridge house make three marks along a long hull. The most drawn of the four."
		"p2":
			return "Shorter and beamier: reads as a harbour picket rather than a gunboat. Single guns in round tubs read as dots at the planning zoom."
		"p3":
			return "The cutter with everything optional taken off. At the planning zoom it is nearly the same as P1: the cheapest to draw and to bake."
		"p4":
			return "The long forward mount is the picture; the break line across the foredeck is the only thing that says whaleback, and it shows only at zoom 1."
		"s1":
			return "The most recognisable cargo boat: hatches, house and funnel. The accent sits on the forward hatch tarpaulin, so it does not compete with the funnel."
		"s2":
			return "A load on deck makes it read as supply even at the planning zoom (a lumpy hull instead of a smooth one). Blunt ends: it cannot be mistaken for a patrol boat."
		"s3":
			return "The plainest: one long battened tarpaulin. Close to a patrol boat's length and width at the planning zoom, so the two can look alike there."
		"s4":
			return "The coaster with the deck loaded: barrels and crates break the silhouette. The busiest cargo look; most of the detail is gone at the planning zoom."
	return ""

func _wake_row(sh: BoardSheet, y: float, w: String, fr_p: Dictionary, fr_s: Dictionary) -> float:
	var rec: Dictionary = (BoatArt.data()["wakes"] as Dictionary)[w]
	var x := MARGIN
	sh.text(Vector2(x, y + 16.0), "%s  ·  %s" % [w, str(rec["title"])], 17.0, sh.c_text)
	var iy := y + 24.0
	var a: Vector2 = _frame_box(sh, fr_p["z1"], Vector2(x, iy))
	var b: Vector2 = _frame_box(sh, fr_s["z1"], Vector2(x + a.x + 12.0, iy))
	sh.text(Vector2(x, iy + a.y + 14.0), "zoom 1 · patrol boat P1 and supply boat S1 under way", 11.0, sh.c_muted, true)
	var x3 := x + a.x + b.x + 24.0
	var pa: Vector2 = _frame_box(sh, fr_p["plan"], Vector2(x3, iy), 2.0)
	_frame_box(sh, fr_s["plan"], Vector2(x3, iy + pa.y + 10.0), 2.0)
	sh.text(Vector2(x3, iy + pa.y * 2.0 + 24.0), "planning zoom 0.35, at 2x (nearest)", 11.0, sh.c_muted, true)
	var tx := x3 + pa.x + 18.0
	var tw := float(W) - MARGIN - tx
	sh.text(Vector2(tx, iy + 10.0), "boats.json wakes.%s" % w, 11.0, sh.c_muted, true)
	var hh := sh.paragraph(Vector2(tx, iy + 26.0), str(rec["about"]), 12.5, sh.c_text, tw, false, 3.0)
	sh.paragraph(Vector2(tx, iy + 36.0 + hh), _wake_notes(w), 12.0, sh.c_muted, tw, true, 3.0)
	return iy + pa.y * 2.0 + 44.0

func _wake_notes(w: String) -> String:
	match w:
		"ink_v":
			return "The cruiser sheet's own wake: ink only, the most 'drawn' of the three, and the only one that costs no colour at all. At the planning zoom it is a few faint strokes; it reads as direction, not as speed."
		"foam":
			return "Paper-coloured dots: the most like water in motion at zoom 1, and the one that gives the boat a bright tail where the sea is dark. At the planning zoom the dots are sub-pixel and it fades."
		"wash":
			return "A soft pale trail: the most readable at the planning zoom (a pale streak behind a small boat says 'moving' from across the map). It is the only one that is a wash rather than linework, so it leans most on what the water looks like."
	return ""

func _sheet(look_frames: Dictionary, wake_frames: Dictionary, strips: Array, depth: Array) -> void:
	var head_h := 360.0
	var look_h := 24.0 + float(PLAN_CROP.size.y) * INFLATE + 14.0 + 26.0
	var wake_h := 24.0 + 2.0 * 120.0 + 10.0 + 44.0
	var scale_h := 420.0
	var pal_h := 780.0
	var total := int(head_h + 24.0 + 2.0 * (40.0 + 4.0 * look_h) + 40.0 + 3.0 * wake_h + scale_h + pal_h + 60.0)
	var sh := BoardSheet.new(style, Vector2i(W, total))
	var tw := float(W) - MARGIN * 2.0
	sh.text(Vector2(MARGIN, 34.0), "Two small boats and their wakes  ·  seed %d, over Track WB's proposed water" % SEED, 25.0, sh.c_text)
	var hy := 52.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "Alex (decision water-layer, 2026-10-10): \"We need at least one small boat. Maybe two?\" The lead proposed an armed PATROL BOAT and an unarmed SUPPLY BOAT (Alex: \"Sounds good\"), and Alex's last word on what they are: \"Correct, part of the environment with real patrols but no specific part in the mission.\" So they are REAL UNITS that sail a patrol route and can be hit, with no part in the mission; the patrol boat's guns stay quiet, so they are drawn trained fore and aft, stowed, with no fire. This board asks how they LOOK. The art is new generators in the unit sheet's style (scripts/render/boat_art.gd, seeded like the planes), drawn with the game's own ink pen; nothing is in the game yet.", 12.5, sh.c_muted, tw, true) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "SIZES (all PROPOSED, data/world/boats.json): patrol boat 24 to 30 m, drawn here at 27 m x 5.4 m beam (three light fighters long; a motor gunboat or harbour launch is 20 to 35 m); supply boat 28 to 40 m, drawn at 34 m x 7.6 m (a small coaster or a canal barge is 25 to 45 m). The cruiser of the unit sheet is 112 to 128 m: both boats are a quarter of it or less, so 'a small cruiser for now' still stands as the biggest ship the game will have.", 12.5, sh.c_muted, tw) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "SCALE RULE (PROPOSED): a boat is drawn at the PLANES' marker scale, the same pixels per metre as a plane at every zoom (data/ui/ui.json marker.true_scale: plane_px 36 for the 9 m light fighter over the map's 2 px per metre is a multiplier of 2, so %.1f px per metre at zoom 1; at the planning zoom 0.35 the fighter's 14 px floor wins and it is %.2f px per metre). So a boat keeps its TRUE ratio to a plane (a 27 m patrol boat is %.0f px long beside a 36 px fighter at zoom 1, %.0f px beside 14 at the planning zoom) and reads next to one at every zoom, as the design doc asks of ships. They are units now, so the marker layer's rule is the one they follow. The alternative is the MAP's scale like a house or a bridge (%.1f px per metre at zoom 1: the same boat is %.0f px). The scale strip below shows both, and what the plane rule costs: a 34 m supply boat is %.0f px at zoom 1, and a 60 m river at the map's scale (where the bridges are drawn) is only 120 px, so under the plane rule a boat cannot sail a river; under the map rule it is 68 px and fits." % [
		BoatScale.plane_ppm(Z1), BoatScale.plane_ppm(ZP), 27.0 * BoatScale.plane_ppm(Z1), 27.0 * BoatScale.plane_ppm(ZP), BoatScale.map_ppm(Z1), 27.0 * BoatScale.map_ppm(Z1), 34.0 * BoatScale.plane_ppm(Z1)], 12.5, sh.c_muted, tw) + 8.0
	hy += sh.paragraph(Vector2(MARGIN, hy), "HOW TO READ IT: every look is the same boat from the same seed at zoom 1 (side_a, brick red, above; side_b, slate blue, below; a light fighter at 400 m ahead of them, its shadow standing off by its altitude) and at the planning zoom 0.35 (1:1, and a 3x nearest-neighbour crop so the pixels can be seen). The sun is the map's (from the north-west): every boat's shadow falls to the south-east on the water, a hull's by its freeboard, the bridge house, funnel, mast and gun barrels by their heights. ONE accent zone per boat, a painted recognition panel: the patrol boat's engine casing, the supply boat's hold tarpaulin (or its cabin roof). Everything else is paper and ink. The sea is Track WB's PROPOSED default water (data/world/water.json draw.palette, read at render time: here its SHELF step, an open coast; the last strip shows the shallows and the deep step too): Track WB's board, variants/water/, chooses the real water. Every option is PROPOSED; nothing is chosen (chosen: null).", 12.5, sh.c_muted, tw, true)
	var y := head_h
	# --- the scale strips
	sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 24.0), "The scale rule: the roster side by side, boats at the planes' scale and at the map's", 17.0, sh.c_text)
	var sy := y + 56.0
	for i in strips.size():
		var s: Dictionary = strips[i]
		var img: Image = s["img"]
		var zoom: float = float(s["zoom"])
		var f := 1.0 if zoom > 0.5 else 3.0
		var x := MARGIN if (i % 2 == 0) else MARGIN + (float(strips[0]["img"].get_width()) + 24.0 if zoom > 0.5 else float(strips[2]["img"].get_width()) * 3.0 + 24.0)
		var sz := _frame_box(sh, img, Vector2(x, sy), f)
		for it: Dictionary in s["items"]:
			sh.text(Vector2(x + float(it["x"]) * f - 36.0, sy + sz.y + 14.0), "%s" % str(it["label"]), 10.0, sh.c_muted)
		sh.text(Vector2(x, sy - 4.0), "zoom %.2f · planes %.2f px/m · boats at the %s rule, %.2f px/m" % [zoom, BoatScale.plane_ppm(zoom), str(s["rule"]), BoatScale.plane_ppm(zoom) if str(s["rule"]) == "plane" else BoatScale.map_ppm(zoom)], 11.0, sh.c_muted, true)
		if i % 2 == 1:
			sy += sz.y + 40.0
	y = sy + 8.0
	# --- the looks
	for kind: String in ["patrol", "supply"]:
		sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
		sh.text(Vector2(MARGIN, y + 26.0), "The PATROL BOAT: four looks" if kind == "patrol" else "The SUPPLY BOAT: four looks", 20.0, sh.c_text)
		y += 40.0
		for look: String in BoatArt.looks_of(kind):
			y = _look_row(sh, y, kind, look, look_frames["%s/%s" % [kind, look]])
	# --- the wakes
	sh.line(Vector2(MARGIN, y), Vector2(float(W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 26.0), "The WAKE: three treatments, the same two boats", 20.0, sh.c_text)
	y += 40.0
	for w: String in ["ink_v", "foam", "wash"]:
		y = _wake_row(sh, y, w, wake_frames["%s/patrol" % w], wake_frames["%s/supply" % w])
	_palette_strip(sh, Vector2(MARGIN, y + 10.0), float(W) - MARGIN * 2.0, depth)
	var err: int = await sh.save(self, base.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[boats-board] could not write board.png: ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), W, total])

# --- the palette strip (working rule 6: every art choice includes the palette) ----------------------------------------------

func _depth_frames() -> Array:
	var rl := BoatFrame.roles(style)
	var out: Array = []
	var ppm := BoatScale.plane_ppm(Z1)
	for nm: String in ["shallows", "shelf", "deep"]:
		var key := "water_" + nm
		var col: Color = rl[key] if rl.has(key) else rl["water_placeholder"]
		var img := BoatFrame.render(style, Vector2i(400, 130), {"ppm": ppm, "map_ppm": BoatScale.map_ppm(Z1), "wake": "ink_v", "seed": 17, "water": col,
			"boats": [{"kind": "patrol", "look": "p1", "side": "a", "pos": _bow_pos("patrol", "p1", 300.0, 36.0, ppm), "heading": 0.0},
				{"kind": "supply", "look": "s1", "side": "b", "pos": _bow_pos("supply", "s1", 300.0, 94.0, ppm), "heading": 0.0}]})
		_save(img, "water_%s.png" % nm, "p1+s1", Z1, "the patrol boat P1 (side_a) and the supply boat S1 (side_b) over Track WB's %s step, zoom 1" % nm)
		out.append({"name": nm, "img": img, "color": col})
	return out

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float, depth: Array) -> void:
	var rl := BoatFrame.roles(style)
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0.0, 26.0), "The boats on Track WB's three depth steps, and the palette they spend (roles in data/world/boats.json, no hex in the draw code)", 20.0, sh.c_text)
	var hull: Color = rl["hull_patrol"]
	var x := pos.x
	var y0 := pos.y + 44.0
	for d: Dictionary in depth:
		var col: Color = d["color"]
		var sz := _box(sh, d["img"], Vector2(x, y0))
		sh.text(Vector2(x, y0 + sz.y + 13.0), "%s: %s  ·  hull step %.3f, OKLab distance %.2f" % [str(d["name"]), BoardSheet.oklch_text(col), BoardSheet.oklch(hull).x - BoardSheet.oklch(col).x, BoardSheet.delta_ok(hull, col)], 11.0, sh.c_muted, true)
		x += sz.x + 12.0
	var water: Color = rl["water_placeholder"]
	var shadow_c: Color = rl["shadow"]
	var chips: Array = [
		["paper", style.palette["paper"]],
		["ink", rl["ink"]],
		["hull_patrol", rl["hull_patrol"]],
		["hull_supply", rl["hull_supply"]],
		["house, deck_gear", rl["house"]],
		["hull_shaded", rl["hull_shaded"]],
		["cargo_tarp_shaded", rl["cargo_tarp_shaded"]],
		["side_a (allies)", rl["side_a"]],
		["side_b (axis)", rl["side_b"]],
		["shadow on shelf", BoardSheet.over(shadow_c, water)],
		["wake_foam on shelf", BoardSheet.over(rl["wake_foam"], water)],
		["wake_wash on shelf", BoardSheet.over(rl["wake_wash"], water)],
		["WB shelf (water)", water],
	]
	var cx := pos.x
	var cy := y0 + 130.0 + 30.0
	for i in chips.size():
		var c: Array = chips[i]
		var col: Color = c[1]
		if cx + 122.0 > pos.x + width:
			cx = pos.x
			cy += 92.0
		sh.chip(Vector2(cx, cy), col, str(c[0]), BoardSheet.oklch_text(col), Vector2(96.0, 40.0))
		cx += 126.0
	var hull_l: float = BoardSheet.oklch(hull).x
	var ink_l: float = BoardSheet.oklch(rl["ink"]).x
	var sa: Color = rl["side_a"]
	var sb: Color = rl["side_b"]
	var shal: Color = rl["water_shallows"] if rl.has("water_shallows") else water
	var deep: Color = rl["water_deep"] if rl.has("water_deep") else water
	var yy := cy + 84.0
	var lines: Array = [
		"HUE stays reserved for paper, ink, shadow and the two side accents (docs/proposals/palette-architecture.md). Every fill on a boat is the paper ramp: the patrol hull is the roof's lit fill, the cargo boat's hull and tarpaulins the wall fill (one step down, L %.3f against L %.3f), houses, funnels and deck gear the object fill; the shaded halves of the domes, funnels and stacks are the one mix toward the shadow tint the roofs and the radio hut already use. MATERIAL is linework: planking is ruled lines with butt gaps, tarpaulin is a stipple field with batten lines, plates and bollards are dots, funnel mouths are dark ink with cross-hatch. The two SIDE ACCENTS are used on ONE zone each and nowhere else: side_a L %.3f C %.3f h %d, side_b L %.3f C %.3f h %d, equal in lightness and chroma, so a boat is told apart by its panel and never by its hull." % [
			hull_l, BoardSheet.oklch(rl["hull_supply"]).x, BoardSheet.oklch(sa).x, BoardSheet.oklch(sa).y, int(round(BoardSheet.oklch(sa).z)), BoardSheet.oklch(sb).x, BoardSheet.oklch(sb).y, int(round(BoardSheet.oklch(sb).z))],
		"THE WATER IS TRACK WB'S, and the question for the palette is whether the boats keep their place on it. Their proposed default is a blue (OKLCH hue %d) that darkens and saturates with depth, L %.3f in the shallows, %.3f on the shelf, %.3f deep, always under the shadow tint's chroma. A hull (L %.3f) against the lightest step, the shallows, is a lightness step of only %.3f (OKLab distance %.2f); against the shelf %.3f, against the deep %.3f; the ink outline (L %.3f) against the shallows is %.3f. So on the shallows a boat is held by its outline and its shadow, not by its fill (the depth strip above shows it): the boats read on every step, and the shallows are the one to keep an eye on if Track WB lightens them further. The accents (L 0.551) are darker than every step, so a panel is the darkest thing on the hull on all three. The shadow is the map's one shadow tint at the map's strength (0.44) and merges where parts overlap (one translucent fill, never darker twice). No wake adds a hue: ink at an alpha step (V), the object fill as dots (foam) or a low-alpha wash (trail)." % [
			222, BoardSheet.oklch(shal).x, BoardSheet.oklch(water).x, BoardSheet.oklch(deep).x, hull_l, hull_l - BoardSheet.oklch(shal).x, BoardSheet.delta_ok(hull, shal), hull_l - BoardSheet.oklch(water).x, hull_l - BoardSheet.oklch(deep).x, ink_l, BoardSheet.oklch(shal).x - ink_l],
	]
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width, false, 3.0) + 6.0

# --- the records ------------------------------------------------------------------------------------------------------------

func _write_frames_json() -> void:
	var f := FileAccess.open(base.path_join("frames.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[boats-board] could not write frames.json")
		return
	f.store_string(JSON.stringify({"id": "boats", "about": "Every frame of the boats board as its own PNG at native size, with its zoom and a caption. board.png is the sheet; the 3x crops on it are nearest-neighbour copies of the *_plan.png frames.", "frames": frames}, "  ", false))
	f.close()

func _option(kind: String, look: String) -> Dictionary:
	var d: Dictionary = ((BoatArt.data()[kind] as Dictionary)["looks"] as Dictionary)[look]
	var m := BoatArt.model(style, kind, look)
	var p: Dictionary = (m.p as Dictionary).duplicate()
	for k: String in ["cargo_seed", "look"]:
		p.erase(k)
	return {"name": look.to_upper(), "title": str(d["title"]), "kind": kind, "look": look, "proposed": true,
		"files": ["%s_%s_z1.png" % [kind, look], "%s_%s_plan.png" % [kind, look]],
		"description": str(d["about"]), "data": "data/world/boats.json %s.looks.%s" % [kind, look],
		"drawn_as": {"length_m": snappedf(float(m.p.length), 0.01), "beam_m": snappedf(float(m.p.beam), 0.01), "detail": int(m.p.detail), "seed": m.seed},
		"parameters": d}

func _write_board_json() -> void:
	var data := BoatArt.data()
	var options: Array = []
	for kind: String in ["patrol", "supply"]:
		for look: String in BoatArt.looks_of(kind):
			options.append(_option(kind, look))
	var wakes: Array = []
	for w: String in ["ink_v", "foam", "wash"]:
		var rec: Dictionary = (data["wakes"] as Dictionary)[w]
		wakes.append({"name": w, "title": str(rec["title"]), "proposed": true, "files": ["wake_%s_patrol_z1.png" % w, "wake_%s_patrol_plan.png" % w, "wake_%s_supply_z1.png" % w, "wake_%s_supply_plan.png" % w], "description": str(rec["about"]), "parameters": rec})
	var rl := BoatFrame.roles(style)
	var doc := {
		"id": "boats",
		"date": "2026-10-10",
		"area": "Water, Units",
		"question": "How do the two small boats look? Alex (decision water-layer): 'We need at least one small boat. Maybe two?', then 'Correct, part of the environment with real patrols but no specific part in the mission'.",
		"source": "scripts/ui/boards/boats_board_shot.gd: the new generators in scripts/render/boat_art.gd (the unit sheet's style), framed by scripts/render/boat_frame.gd on Track WB's proposed water, one InkCanvas per frame; no sandbox is stood up and nothing in the game changes",
		"seed": SEED,
		"held_constant": {
			"light": "the map's sun (data/params/render_defaults.json: from the north-west, elevation 46, shadow strength 0.44), so a boat's shadow falls south-east",
			"pen": "the game's own pen (render_defaults linework.pen, shadow side); outlines heavy on the faces away from the sun",
			"water": "Track WB's PROPOSED default water, read at render time from data/world/water.json draw.palette (the shelf step; shallows and deep in the depth strip), flat; Track WB's board (variants/water/) decides the water. Falls back to a placeholder wash when that file is absent",
			"what_they_are": "real units on a patrol route with no part in the mission (Alex); the patrol boat's guns are drawn trained and stowed, no fire",
			"sides": "side_a brick red above, side_b slate blue below: one accent zone each (a painted recognition panel)",
			"plane_beside": "the light fighter (9 m) at 400 m, drawn by the game's own unit_marker_art, its shadow offset by its altitude",
		},
		"sizes_m_proposed": {"patrol": {"length": 27, "range": [24, 30], "beam": 5.4}, "supply": {"length": 34, "range": [28, 40], "beam": 7.6}, "cruiser_for_comparison": [112, 128]},
		"scale_rule_proposed": {
			"rule": "plane", "alternative": "map",
			"px_per_metre": {"zoom_1": {"plane": snappedf(BoatScale.plane_ppm(Z1), 0.001), "map": snappedf(BoatScale.map_ppm(Z1), 0.001)}, "zoom_0.35": {"plane": snappedf(BoatScale.plane_ppm(ZP), 0.001), "map": snappedf(BoatScale.map_ppm(ZP), 0.001)}},
			"source": "data/ui/ui.json marker.true_scale as scripts/app/sandbox.gd _update_plane_scale sets it: plane_px 36 and plane_min_px 14 (data/scenarios/strike.json view) over the light fighter's 9 m and the map's 2 px per metre",
			"patrol_27m_px": {"plane_rule": {"zoom_1": snappedf(27.0 * BoatScale.plane_ppm(Z1), 0.1), "zoom_0.35": snappedf(27.0 * BoatScale.plane_ppm(ZP), 0.1)}, "map_rule": {"zoom_1": snappedf(27.0 * BoatScale.map_ppm(Z1), 0.1), "zoom_0.35": snappedf(27.0 * BoatScale.map_ppm(ZP), 0.1)}},
			"frames": ["scale_z1_plane.png", "scale_z1_map.png", "scale_plan_plane.png", "scale_plan_map.png"],
		},
		"parameter": "data/world/boats.json: patrol.looks.<p1..p4>, supply.looks.<s1..s4>, wakes.<ink_v|foam|wash>; the working default is PROPOSED: scale.rule plane, wake ink_v",
		"options": options,
		"wakes": wakes,
		"palette_check": "No option adds a hue. Fills are the paper ramp (roof_lit, wall_fill, object_fill: L %.3f, %.3f, %.3f), shaded halves the one mix toward the shadow tint, material is linework; the side accents (side_a L %.3f C %.3f, side_b L %.3f C %.3f) sit on ONE zone per boat. The placeholder water is the one exception and is Track WB's to decide." % [
			BoardSheet.oklch(rl["hull_patrol"]).x, BoardSheet.oklch(rl["hull_supply"]).x, BoardSheet.oklch(rl["house"]).x,
			BoardSheet.oklch(rl["side_a"]).x, BoardSheet.oklch(rl["side_a"]).y, BoardSheet.oklch(rl["side_b"]).x, BoardSheet.oklch(rl["side_b"]).y],
		"recommendation_proposed": "PROPOSED by Track BB, Alex decides: patrol P1 (the cutter) and supply S1 (the coaster) -- the two that read as a warship and as a cargo boat at both zooms -- at the planes' scale (the plane rule), with the PALE WASH for the wake if one wake has to serve both zooms (it is the only one that still says moving at 0.35), or the ink V if the wake must add no tone at all. P3 is the cheap fallback for the patrol boat (almost the same at the planning zoom) and S2 the supply boat that reads as cargo from furthest away. On Track WB's lightest step (the shallows) a hull is held by its outline and shadow more than its fill: worth a look when WB settles the water.",
		"frames": "frames.json (every frame whole, native size)",
		"sheet": "board.png (the scale strips, four patrol looks, four supply looks, three wakes, the palette strip)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(base.path_join("board.json"), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[boats-board] could not write board.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved board.json")
