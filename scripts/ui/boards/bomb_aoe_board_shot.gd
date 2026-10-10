extends SceneTree

# BOARD: THE AREA OF EFFECT OF A BOMB DROP (Track T, the strike's targeting). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/bomb_aoe_board_shot.gd -- [out=variants/bomb-aoe]
#
# Alex (2026-10-10, decision special-targeting): "For bombs, I expected area of effect as well." HOW the area of effect is drawn is
# this board's question, and nothing is chosen. Four ways on the RUNNING SANDBOX (seed 20261009, the real map, the fog, the village
# Track W lays out, the real orders card and roster): the player's bomber with the radio tower as its TARGET -- the player
# left-clicked the tower, switched Drop on at the second step, and the aim sits on the tower -- photographed once per option with
# ONLY data/ui/ui.json bombs.aoe.mode changed, in three frames of the game itself:
#
#   play    the planning zoom (0.35): the bomber on the left, the cone over the village, the aim on the tower (the IDEAL release angle)
#   close   zoom 1.0 over the aim, the same aim
#   rim     zoom 1.0, the aim dragged to the cone's near rim -- the worst release angle the cone allows (accuracy 35 percent): the
#           scatter is widest there, and so is the area of effect
#
# Every frame carries the EXPECTED-DAMAGE LINE on the orders card ("step 2: radio tower, about 5 of 8 · 100%"), computed from the
# sim's own rules (World.drop_expected: the sim's dice, a fixed sample, its blast table, the sum capped at the unit's health); the
# sheet shows the card's top beside each frame. The cone beside the area of effect is the side accent; the area of effect is ink.
#
# Output (out=): board.png (the sheet: crops 1:1 of those frames, a row per option, the card's line, and a palette strip), <option>_
# play.png / _close.png / _rim.png (every frame whole, 1280 x 720, native size), frames.json (every frame's file, look, zoom and a
# caption), board.json (the seed, the parameter set per option, "chosen": null for Alex to choose).
#
# EVERY OPTION AND VALUE IS PROPOSED by Track T; none is a decision.

const StrikeScene = preload("res://scripts/ui/boards/strike_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")

const SEED := 20261009
const OPTIONS := [
	{"id": "o_none", "letter": "0", "mode": "none", "reference": true, "title": "For reference: no area of effect (the game before this board)",
		"line": "The cone, the aim and the scatter ellipse, nothing about the blast. The blast is only in the sim and the card's line."},
	{"id": "a_rings", "letter": "A", "mode": "rings", "title": "Blast rings round the aim",
		"line": "The sim's blast table as rings round the aim, on top of the scatter: 12 m (3 pips, solid), 25 m (2 pips) and 45 m (1 pip, dashed), each numbered. It says what ONE bomb that lands on the aim does. It does not say where the bombs will land: the scatter ellipse inside it does, and the two have to be read together."},
	{"id": "b_footprint", "letter": "B", "mode": "footprint", "title": "One footprint: the scatter grown by the blast",
		"line": "One wash: the scatter's ellipse grown by the blast's whole reach (45 m) -- anything in here can take damage. The simplest to read and the closest to Alex's words, but it is binary: it does not say where a unit takes 3 pips and where it takes 1."},
	{"id": "c_impacts", "letter": "C", "mode": "impacts", "title": "The stick's impacts along the track, each with its own blast",
		"line": "The four bombs of the stick at their nominal places along the bomber's heading, each with its 12 m direct-hit ring and its 45 m reach. Honest about the stick, but at 10 m between bombs and a 45 m reach the circles overlap into a knot, and the scatter moves every one of them."},
	{"id": "d_tiers", "letter": "D", "mode": "tiers", "title": "Tiered footprint (proposed): the scatter grown by each blast tier",
		"line": "The scatter's ellipse grown by each tier of the blast table (12, 25 and 45 m) as three nested washes, darker toward more pips -- the footprint of B with the table's depth in it. Lightness is the damage, in ink only; the outer edge is dashed, the 3-pip edge solid."},
]
const SHOTS := [
	{"id": "play", "title": "planning zoom", "aim": "ideal", "caption": "the planning zoom 0.35, the aim at the ideal release angle"},
	{"id": "close", "title": "zoom 1, ideal aim", "aim": "ideal", "caption": "zoom 1.0 over the aim at the ideal release angle (accuracy 100 percent)"},
	{"id": "rim", "title": "zoom 1, aim on the near rim", "aim": "rim", "caption": "zoom 1.0, the aim dragged to the cone's near rim: the worst release angle the cone allows"},
]
const CROPS := {"play": Rect2(0.0, 190.0, 966.0, 380.0)}
const CROP_CLOSE := Vector2(440.0, 400.0)
const CARD_W := 286.0

var out_dir := "variants/bomb-aoe"
var s: StrikeScene = null
var style = null
var images: Dictionary = {}      # "<option id>_<shot id>" -> Image (the whole frame)
var crops: Dictionary = {}       # the same keys -> Image (the sheet's crop)
var cards: Dictionary = {}       # the same keys -> Image (the card's top)
var card_lines: Dictionary = {}  # the same keys -> the card's line
var aim_info: Dictionary = {}    # shot id -> {accuracy, spread_across_m, expected, ...} read from the interface
var marks_crop: Image = null
var frames: Array = []
var failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[bomb-aoe-board] ", msg)

func _run() -> void:
	s = StrikeScene.new(self)
	_say("standing up the sandbox (seed %d)..." % SEED)
	if not await s.start():
		printerr("[bomb-aoe-board] ", s.scene.errors)
		quit(1)
		return
	style = s.style
	await s.set_up()
	if s.scene.sb.objective != null:
		s.scene.sb.objective.visible = false   # the scenario's dashed TARGET ring would be read as a blast ring
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://").path_join(out_dir))
	var ideal_aim: Vector2 = s.pl.step_aim(s.DROP_STEP)
	var rim_aim := _rim_point()
	_say("tower %s, bomber from %s, ideal aim %s, rim aim %s -- %s" % [str(s.tower_m), str(s.start_m), str(ideal_aim), str(rim_aim), s.layout_note])
	_check_target()
	var base_mode: String = style.text("bombs.aoe.mode")
	for shot: Dictionary in SHOTS:
		var rim: bool = shot["aim"] == "rim"
		# The player drags the aim handle to the rim: the step's target becomes that point (Alex), as the board's rim shot needs.
		if rim:
			s.pl.place_aim(s.DROP_STEP, rim_aim)   # dragging the aim handle to the rim: the step's target becomes that point (Alex)
		if shot["id"] == "play":
			await s.frame_play()
		else:
			await s.frame_close()
		aim_info[str(shot["id"])] = _read_info()
		for o: Dictionary in OPTIONS:
			style.ui["bombs"]["aoe"]["mode"] = str(o["mode"])
			s.ui.bomb_aim._sig = ""
			await s.scene.frames(3)
			var img: Image = await s.scene.grab()
			var key := "%s_%s" % [o["id"], shot["id"]]
			images[key] = img
			crops[key] = _crop(img, str(shot["id"]))
			cards[key] = _card(img)
			card_lines[key] = s.ui.orders.bomb_caption()
			var file := key + ".png"
			var err := img.save_png(ProjectSettings.globalize_path("res://").path_join(out_dir).path_join(file))
			if err != OK:
				failures += 1
				printerr("[bomb-aoe-board] could not write ", file)
			frames.append({"file": file, "option": o["letter"], "look": str(o["mode"]), "title": "%s  ·  %s  ·  %s" % [o["letter"], o["title"], shot["title"]],
				"zoom": snappedf(s.scene.sb.ctl.camera.zoom.x, 0.001), "aim": str(shot["aim"]), "card_line": card_lines[key],
				"caption": "%s: %s. %s" % [o["title"], shot["caption"], o["line"]], "size": [img.get_width(), img.get_height()]})
		_say("shot '%s' photographed in %d looks (%s)" % [shot["id"], OPTIONS.size(), str(aim_info[str(shot["id"])])])
	# The target marks, for the palette strip: the tower's brackets and a point target's diamond, at zoom 1.
	s.pl.place_aim(s.DROP_STEP, ideal_aim)
	s.ui.set_target_unit("tower")
	_retarget_tower()
	s.ui.target.set_point(s.tower_m + Vector2(-48.0, -40.0))
	await s.frame_close()
	style.ui["bombs"]["aoe"]["mode"] = base_mode
	s.ui.bomb_aim._sig = ""
	await s.scene.frames(3)
	var marks_img: Image = await s.scene.grab()
	var tp := s.screen_of_m(s.tower_m)
	marks_crop = marks_img.get_region(Rect2i(Vector2i(tp - Vector2(110.0, 90.0)), Vector2i(220, 180)))
	marks_img.save_png(ProjectSettings.globalize_path("res://").path_join(out_dir).path_join("target_marks.png"))
	await _write()
	s.shutdown()
	quit(1 if failures > 0 else 0)

func _check_target() -> void:
	var st: Dictionary = s.pl.step_target(s.DROP_STEP)
	if str(st.get("unit", "")) != "tower":
		failures += 1
		printerr("[bomb-aoe-board] the drop's target is not the tower: ", st)

# The step's target is the tower again (a rim shot made it a point): a plain drop on the unit, the way the player sets it.
func _retarget_tower() -> void:
	var k: int = s.DROP_STEP
	if str(s.pl.step_target(k).get("unit", "")) == "tower":
		return
	s.pl.set_step_drop(k, false)
	s.ui.set_target_unit("tower")
	s.pl.set_step_drop(k, true)

func _rim_point() -> Vector2:
	var cone: Dictionary = s.pl.bombs.cone("b1", s.DROP_STEP)
	var poly: PackedVector2Array = cone["polygon"]
	var ideal: Vector2 = cone["ideal_aim"]
	var from := s.start_m
	var best := poly[0]
	for q in poly:
		if q.distance_to(from) < best.distance_to(from) and absf(angle_difference((q - from).angle(), (ideal - from).angle())) < 0.02:
			best = q
	return BombSource.nearest_inside(poly, best.lerp(ideal, 0.03))

func _read_info() -> Dictionary:
	var d: Dictionary = s.pl.drop_info(s.DROP_STEP)
	if d.is_empty():
		return {}
	var sp: Dictionary = d["spread"]
	var ex := {}
	for rec: Dictionary in s.pl.bombs.expected("b1", s.DROP_STEP, s.pl.step_aim(s.DROP_STEP)):
		if str(rec["unit"]) == "tower":
			ex = rec
	return {"accuracy": snappedf(float(d["quality"]), 0.01), "spread_across_m": snappedf(float(sp["across_m"]), 0.1), "sigma_m": snappedf(float(sp["sigma_m"]), 0.1),
		"stick_m": snappedf(float(sp["stick_m"]), 0.1), "expected_pips": snappedf(float(ex.get("mean", 0.0)), 0.01), "tower_health": int(ex.get("health", 0)),
		"p_destroy": snappedf(float(ex.get("p_destroy", 0.0)), 0.01)}

func _crop(img: Image, shot_id: String) -> Image:
	var r: Rect2
	if shot_id == "play":
		r = CROPS["play"]
	else:
		var a := s.screen_of_m(s.pl.step_aim(s.DROP_STEP))
		r = Rect2(a - CROP_CLOSE * 0.5, CROP_CLOSE)
		r.position.x = clampf(r.position.x, 0.0, float(img.get_width()) - r.size.x)
		r.position.y = clampf(r.position.y, 0.0, float(img.get_height()) - r.size.y)
	return img.get_region(Rect2i(Vector2i(r.position), Vector2i(r.size)))

# The top of the orders card as the frame has it: the title, the lines, the buttons and the line under them.
func _card(img: Image) -> Image:
	var card: Control = s.ui.orders
	var drop_rect: Rect2 = card.buttons()["drop"]["rect"]
	var r := Rect2(card.global_position, Vector2(CARD_W, drop_rect.end.y + 34.0))
	r = r.intersection(Rect2(Vector2.ZERO, Vector2(img.get_size())))
	return img.get_region(Rect2i(Vector2i(r.position), Vector2i(r.size)))

# --- the sheet -------------------------------------------------------------------------------------

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	var margin := 22.0
	var gap := 12.0
	var cw := [CROPS["play"].size.x, CROP_CLOSE.x, CROP_CLOSE.x]
	var ch := CROP_CLOSE.y
	var w := int(margin * 2.0 + cw[0] + cw[1] + cw[2] + CARD_W + gap * 3.0)
	var head_h := 250.0
	var opt_h := 22.0 + ch + 14.0 + 64.0
	var pal_h := 780.0
	var h := int(head_h + opt_h * float(OPTIONS.size()) + pal_h)
	var sh := BoardSheet.new(style, Vector2i(w, h))
	sh.text(Vector2(margin, 34), "The area of effect of a bomb drop  ·  seed %d, the running sandbox" % SEED, 25.0, sh.c_text)
	var hy := 44.0
	hy += sh.paragraph(Vector2(margin, hy), "Alex (2026-10-10): \"For bombs, I expected area of effect as well.\" The target is set (decision special-targeting: left-click an enemy unit or right-click the map, then Drop on the step) and the drop is aimed at it. This board asks HOW the area of effect is drawn. The game's own pieces are in every frame: the bomber with its cone (the side-colour wash), the aim on the radio tower (the target's brackets and the aim's crosshair), the scatter ellipse, and on the orders card the EXPECTED-DAMAGE LINE, computed by the sim from its own rules (its dice, its blast table of 12 m / 25 m / 45 m for 3 / 2 / 1 pips, the sum capped at the tower's 8 pips): ideal aim \"%s\", aim on the rim \"%s\"." % [
		str(card_lines.get("d_tiers_play", "")), str(card_lines.get("d_tiers_rim", ""))], 12.5, sh.c_muted, float(w) - margin * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(margin, hy), "Each row is one look at the same three frames: the planning zoom with the aim at the ideal release angle (accuracy %d%%, scatter %.0f m across, the tower expected to lose about %.1f of 8 pips and destroyed %d%% of the time), the close zoom over the same aim, and the close zoom with the aim on the cone's near rim (accuracy %d%%, scatter %.0f m, about %.1f pips, destroyed %d%% of the time). A look has to say two things the cone does not: WHERE the bombs can fall (the scatter, wider the worse the release) and WHAT THEY DO there (the blast). Bombs hurt only what is on the ground -- the batteries, the tower, a wreck -- never a plane in the air." % [
		roundi(float((aim_info["play"] as Dictionary).get("accuracy", 1.0)) * 100.0), float((aim_info["play"] as Dictionary).get("spread_across_m", 0.0)),
		float((aim_info["play"] as Dictionary).get("expected_pips", 0.0)), roundi(float((aim_info["play"] as Dictionary).get("p_destroy", 0.0)) * 100.0),
		roundi(float((aim_info["rim"] as Dictionary).get("accuracy", 0.35)) * 100.0), float((aim_info["rim"] as Dictionary).get("spread_across_m", 0.0)),
		float((aim_info["rim"] as Dictionary).get("expected_pips", 0.0)), roundi(float((aim_info["rim"] as Dictionary).get("p_destroy", 0.0)) * 100.0)], 12.0, sh.c_muted, float(w) - margin * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(margin, hy), "Every option is PROPOSED by Track T; nothing is chosen (chosen: null). Row 0 is the game before this board, for reference only. Crops are 1:1 from the game's own frames; the whole frames (1280 x 720, native size) are <option>_play.png / _close.png / _rim.png, captions in frames.json. The card beside each frame is the top of the real orders card in that frame; its last line is the expected-damage line (data bombs.aoe.card_line, the same in every option: it is the sim's number, not a drawing).", 12.0, sh.c_muted, float(w) - margin * 2.0, true)
	var y := head_h
	var records: Array = []
	for o: Dictionary in OPTIONS:
		sh.line(Vector2(margin, y), Vector2(float(w) - margin, y), sh.c_rule, 1.0)
		sh.text(Vector2(margin, y + 18), "%s  ·  %s" % [o["letter"], o["title"]], 17.0, sh.c_text)
		sh.text(Vector2(margin + 760, y + 18), "bombs.aoe.mode = %s" % o["mode"], 12.0, sh.c_muted, true)
		var iy := y + 28.0
		var x := margin
		for i in SHOTS.size():
			var shot: Dictionary = SHOTS[i]
			sh.image(crops["%s_%s" % [o["id"], shot["id"]]], Vector2(x, iy + 12.0))
			sh.text(Vector2(x, iy + 8.0), str(shot["title"]), 11.0, sh.c_muted, true)
			x += float(cw[i]) + gap
		# The card's top: the ideal-aim frame's, and under it the rim frame's.
		var card_play: Image = cards["%s_play" % o["id"]]
		var card_rim: Image = cards["%s_rim" % o["id"]]
		sh.text(Vector2(x, iy + 8.0), "the orders card, ideal aim / rim aim", 11.0, sh.c_muted, true)
		sh.image(card_play, Vector2(x, iy + 12.0))
		sh.image(card_rim, Vector2(x, iy + 12.0 + float(card_play.get_height()) + 10.0))
		sh.paragraph(Vector2(margin, iy + 12.0 + ch + 8.0), str(o["line"]), 12.0, sh.c_muted, float(w) - margin * 2.0, true)
		y += opt_h
		records.append(_record(o))
	_palette_strip(sh, Vector2(margin, y + 14.0), float(w) - margin * 2.0)
	var err: int = await sh.save(self, base.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[bomb-aoe-board] could not write board.png: ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), w, h])
	_write_json(base.path_join("board.json"), records)
	_write_frames(base.path_join("frames.json"))

func _record(o: Dictionary) -> Dictionary:
	var a: Dictionary = style.ui["bombs"]["aoe"]
	var params := {}
	for k: String in ["edge_role", "fill_role", "line_px", "dash_px", str(o["mode"])]:
		var d: Variant = a.get(k)
		if d is Dictionary:
			var c: Dictionary = (d as Dictionary).duplicate(true)
			for kk: String in c.keys():
				if kk.begins_with("_"):
					c.erase(kk)
			params[k] = c
		elif d != null:
			params[k] = d
	return {"name": o["letter"], "title": o["title"], "bombs.aoe.mode": o["mode"], "files": ["%s_play.png" % o["id"], "%s_close.png" % o["id"], "%s_rim.png" % o["id"]],
		"proposed": true, "reference": bool(o.get("reference", false)), "description": o["line"], "parameters": params}

func _write_frames(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[bomb-aoe-board] could not write ", path)
		return
	f.store_string(JSON.stringify({"id": "bomb-aoe", "about": "Every frame of the board as its own PNG at native size (1280 x 720), with its caption and the orders card's expected-damage line. board.png is the sheet of 1:1 crops of these; target_marks.png is the frame the palette strip's target marks are cut from.", "frames": frames}, "  ", false))
	f.close()
	_say("saved " + path)

func _write_json(path: String, records: Array) -> void:
	var accent: Color = style.palette["side_a"]
	var ink: Color = style.palette["ink"]
	var paper: Color = style.palette["paper"]
	var doc := {
		"id": "bomb-aoe",
		"date": "2026-10-10",
		"area": "UI, Specials",
		"question": "How is the area of effect of a bomb drop drawn? Alex (decision special-targeting): 'For bombs, I expected area of effect as well.'",
		"source": "scripts/ui/boards/bomb_aoe_board_shot.gd: the running sandbox (scripts/app/sandbox.gd) over the real map and the village Track W lays out, through scripts/ui/boards/strike_scene.gd (the radio tower, two batteries and a player bomber added; the tower is the drop's TARGET, set the way a player does), photographed once per option with ONLY data/ui/ui.json bombs.aoe.mode changed",
		"seed": SEED,
		"held_constant": {
			"scene": "the player's bomber (Anvil, medium band, 85 m/s, flying east) with two steps planned and its SECOND step's drop aimed at the radio tower in the village's compound: the tower is a unit target (it follows the unit); the cone and the numbers are the simulation's own (World.drop_cone / drop_spread / drop_expected, scripts/sim/bombs.gd, bomb_expect.gd); a player fighter beside the tower so the village is in sight",
			"shots": {"play": "the planning zoom 0.35, the aim at the ideal release angle", "close": "zoom 1.0 over the same aim", "rim": "zoom 1.0, the aim on the cone's near rim (the worst release angle)"},
			"accuracy_spread_and_expected_damage": aim_info,
			"blast_table": "data/sim/bombs.json blast_pips_by_distance [[12, 3], [25, 2], [45, 1]] (proposed by Track S2)",
			"decisions_in_force": "special-targeting (a target selection; per step); bomb-aim is still a board (the cone look is the working default, wash); cone-overlay (colour wash); node-hover (grow and fill); shadow strength 0.44; side colours brick red (allies) and slate blue (axis)",
		},
		"parameter": "data/ui/ui.json#bombs.aoe.mode (none | rings | footprint | impacts | tiers) and bombs.aoe.<look> for each one's numbers; bombs.aoe.card_line the expected-damage line on the orders card",
		"also_built_behind_every_option": "the expected-damage line on the orders card (the sim's own number: its dice and its blast table, fixed sample, capped at the unit's health, only for units in sight); the target selection (left-click an enemy, right-click a point, Esc clears it); Drop needs a target inside the step's cone; the unit target follows the unit (the sim resolves the release dynamically)",
		"options": records,
		"palette_check": "No option adds a hue. The cone's interior is the unit's SIDE ACCENT (side_a, L %.3f, C %.3f); the area of effect is INK (L %.3f) at low alpha on PAPER (L %.3f): lightness is the ramp, darker is more damage, material is linework (dashes, rings, dots). The target marks are ink with a paper pool (alpha 0.92) -- the same pool the node-hover halo and the aim's crosshair use." % [
			BoardSheet.oklch(accent).x, BoardSheet.oklch(accent).y, BoardSheet.oklch(ink).x, BoardSheet.oklch(paper).x],
		"recommendation_proposed": "D, the tiered footprint (bombs.aoe.mode in data is set to it, PROPOSED, so the build gives feedback before Alex picks): it is the only look that draws both halves of the area of effect -- where the bombs can land (the scatter) and what they do there (the blast table, as lightness) -- in one shape that stays legible at the planning zoom, and it spends ink only. B is the simplest and nearly as good at the planning zoom (one shape, 'anything in here takes damage'); A reads best at zoom 1 but says nothing at the planning zoom and leaves the scatter to be read separately; C is the most literal and the least legible (overlapping circles).",
		"frames": "frames.json (every frame whole, with its caption and the card's line)",
		"sheet": "board.png (rows 0 and A-D: the planning zoom, the close zoom over the ideal aim, the close zoom over a rim aim, and the orders card's top for each; a palette strip below)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[bomb-aoe-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)

# --- the palette strip (working rule 6: every art choice includes the palette) ---------------------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette, and what the area of effect and the target spend of it", 16.0, sh.c_text)
	var side_a: Color = style.palette["side_a"]
	var side_b: Color = style.palette["side_b"]
	var paper: Color = style.palette["paper"]
	var ink: Color = style.palette["ink"]
	var wash_lo := Color(side_a.r, side_a.g, side_a.b, style.num("bombs.aim.wash.alpha_rim"))
	var wash_hi := Color(side_a.r, side_a.g, side_a.b, style.num("bombs.aim.wash.alpha_centre"))
	var alphas: Array = style.lookup("bombs.aoe.tiers.alphas")
	var tier_1 := BoardSheet.over(Color(ink.r, ink.g, ink.b, float(alphas[0])), paper)
	var tier_2 := BoardSheet.over(Color(ink.r, ink.g, ink.b, float(alphas[1])), tier_1)
	var tier_3 := BoardSheet.over(Color(ink.r, ink.g, ink.b, float(alphas[2])), tier_2)
	var chips := [
		["paper", paper],
		["ink", ink],
		["side_a (yours)", side_a],
		["side_b (theirs)", side_b],
		["cone wash, rim", BoardSheet.over(wash_lo, paper)],
		["cone wash, aim", BoardSheet.over(wash_hi, paper)],
		["tier 1 pip (D)", tier_1],
		["tier 2 pips (D)", tier_2],
		["tier 3 pips (D)", tier_3],
		["footprint (B)", BoardSheet.over(Color(ink.r, ink.g, ink.b, style.num("bombs.aoe.footprint.fill_alpha")), paper)],
		["target pool", BoardSheet.over(Color(paper.r, paper.g, paper.b, 0.92), paper)],
	]
	var x := pos.x
	for c: Array in chips:
		sh.chip(Vector2(x, pos.y + 40.0), c[1], str(c[0]), BoardSheet.oklch_text(c[1]))
		x += 138.0
	# The target marks, cut from the game's own frame at zoom 1 and shown at twice the size.
	if marks_crop != null:
		var mx := pos.x
		var my := pos.y + 150.0
		sh.text(Vector2(mx, my), "the target marks at zoom 1 (2x): the tower's brackets with the aim's crosshair on it, a point target's diamond", 11.0, sh.c_muted, true)
		sh.image(marks_crop, Vector2(mx, my + 10.0), Rect2(), Vector2(marks_crop.get_size()) * 2.0)
	var ink_l: float = BoardSheet.oklch(ink).x
	var paper_l: float = BoardSheet.oklch(paper).x
	var deep: Color = tier_3
	var lines := [
		"Hue stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md). The cone is the bomber's side accent (side_a, brick red) as before. The area of effect adds NO hue: it is ink on the paper, and its depth -- the lightness ramp off paper -- is the damage: in D the three tiers stack to L %.3f at the centre against the paper's %.3f and the ink's %.3f (OKLab distance from ink %.2f, so the village's linework stays legible under it). The enemy's side colour (side_b) is not spent on the blast: it falls on both sides alike (blast_hits_own_side)." % [BoardSheet.oklch(deep).x, paper_l, ink_l, BoardSheet.delta_ok(deep, ink)],
		"The target marks are ink with a paper pool (alpha 0.92), the pool the aim's crosshair and the hover halo already use. A unit target is four corner brackets, a point target a diamond: shapes, not colours, so a target reads the same in either side's territory and over the fog. Material is linework everywhere: rings, dashes, brackets, dots.",
	]
	var yy := pos.y + 150.0 + (marks_crop.get_height() * 2.0 + 40.0 if marks_crop != null else 0.0)
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width - 40.0, false, 3.0) + 5.0
