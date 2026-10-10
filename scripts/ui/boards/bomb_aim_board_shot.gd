extends SceneTree

# BOARD: THE BOMB CONE AND THE AIM (Track U3, the strike). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/bomb_aim_board_shot.gd -- [out=variants/bomb-aim]
#
# Alex (2026-10-10): bombing is "per step, just like diving. You set the intent in the cone. The accuracy is
# based on how close you are to the ideal release angle", and height is a factor. This is HOW THE CONE AND THE
# AIM MARK WITH ITS SPREAD LOOK, in four ways, on the RUNNING SANDBOX (seed 20261009, the real map, the fog,
# the village Track W lays out, the real orders card and roster): the player's bomber, its second step's drop
# aimed at the radio tower in its compound, one of the players' fighters beside it so the village is in sight.
# ONLY data/ui/ui.json bombs.aim.mode changes between the options. Per option three frames of the game itself:
#
#   play    the planning zoom (0.35, data/view/camera.json zoom.start): the bomber on the left, the cone over the
#           village, the aim on the tower -- the aim at the IDEAL release angle (accuracy 100 percent)
#   close   zoom 1.0 over the aim, the same aim: the cone, the spread, the fall line, the tower in its compound
#   rim     zoom 1.0, the aim dragged to the cone's near rim -- the worst release angle the cone allows (accuracy
#           35 percent): how each look says "less accurate" through the spread and the shading
#
# Output (out=): board.png (the sheet: crops 1:1 of those frames, a row per option, and a palette strip),
# <option>_play.png / _close.png / _rim.png (every frame whole, 1280 x 720, native size), frames.json (every
# frame's file, look, zoom and a caption: what a viewer reading the frames one at a time needs), board.json (the
# seed, the parameter set per option, "chosen": null for Alex to choose).
#
# EVERY OPTION AND VALUE IS PROPOSED by Track U3; none is a decision.

const StrikeScene = preload("res://scripts/ui/boards/strike_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const BombSource = preload("res://scripts/ui/bomb_source.gd")

const SEED := 20261009
const OPTIONS := [
	{"id": "a_outline", "letter": "A", "mode": "outline", "title": "Ink outline, dotted fall line, dashed spread",
		"line": "All linework and nothing filled, so the village reads straight through. The cone is an inked rim; a dotted line runs from where the bomber lets go (the dot on its path) to the aim; the spread is a dashed ellipse. Accuracy is said by the ellipse's size and the lettering alone."},
	{"id": "b_wash", "letter": "B", "mode": "wash", "title": "Wash in the side colour, crosshair, faint spread",
		"line": "The cone as a wash in the unit's side colour, deepest round the ideal aim and fading to the rim: the more colour under the aim, the closer the release is to ideal. The same wash Alex chose for the guns' cones (decision cone-overlay), used for bombs. A crosshair at the aim, a faint inked ellipse for the spread."},
	{"id": "c_stipple", "letter": "C", "mode": "stipple", "title": "Stippled cone, spread as scattered impacts",
		"line": "The cone in dots, dense toward the ideal aim and thin to the rim; the spread is not an outline but a scatter of dots, the places bombs may land (the same dots every frame, so nothing shimmers). Reads as the bombs' own randomness."},
	{"id": "d_rings", "letter": "D", "mode": "rings", "title": "Range rings from the release point",
		"line": "A faint wash and RANGE RINGS about the release point, one every 100 m through the cone, the aim's own ring solid: the throw is the thing, and this draws it as a distance. The spread is a solid ellipse. The most technical of the four."},
]
const SHOTS := [
	{"id": "play", "title": "planning zoom", "aim": "ideal", "caption": "the planning zoom 0.35, the aim at the ideal release angle"},
	{"id": "close", "title": "zoom 1, ideal aim", "aim": "ideal", "caption": "zoom 1.0 over the aim at the ideal release angle (accuracy 100 percent)"},
	{"id": "rim", "title": "zoom 1, aim on the near rim", "aim": "rim", "caption": "zoom 1.0, the aim dragged to the cone's near rim: the worst release angle the cone allows"},
]
const CROPS := {
	"play": Rect2(0.0, 190.0, 966.0, 380.0),
}
const CROP_CLOSE := Vector2(660.0, 400.0)

var out_dir := "variants/bomb-aim"
var s: StrikeScene = null
var style = null
var images: Dictionary = {}      # "<option id>_<shot id>" -> Image (the whole frame)
var crops: Dictionary = {}       # the same keys -> Image (the sheet's crop)
var aim_info: Dictionary = {}    # shot id -> {quality, spread_m, ...} read from the interface
var frames: Array = []
var failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[bomb-aim-board] ", msg)

func _run() -> void:
	s = StrikeScene.new(self)
	_say("standing up the sandbox (seed %d)..." % SEED)
	if not await s.start():
		printerr("[bomb-aim-board] ", s.scene.errors)
		quit(1)
		return
	style = s.style
	await s.set_up()
	var ideal_aim: Vector2 = s.pl.step_aim(s.DROP_STEP)
	var rim_aim := _rim_point()
	_say("tower %s, bomber from %s, ideal aim %s, rim aim %s -- %s" % [str(s.tower_m), str(s.start_m), str(ideal_aim), str(rim_aim), s.layout_note])
	var base_mode: String = style.text("bombs.aim.mode")
	for shot: Dictionary in SHOTS:
		# The camera, once per shot kind (the ground bakes once; every option is photographed on the same pixels).
		var rim: bool = shot["aim"] == "rim"
		s.pl.place_aim(s.DROP_STEP, rim_aim if rim else ideal_aim)
		if shot["id"] == "play":
			await s.frame_play()
		else:
			await s.frame_close()
		aim_info[str(shot["id"])] = _read_info()
		for o: Dictionary in OPTIONS:
			style.ui["bombs"]["aim"]["mode"] = str(o["mode"])
			s.ui.bomb_aim.mode_override = ""
			s.ui.bomb_aim._sig = ""
			await s.scene.frames(3)
			var img: Image = await s.scene.grab()
			var key := "%s_%s" % [o["id"], shot["id"]]
			images[key] = img
			crops[key] = _crop(img, str(shot["id"]))
			var file := key + ".png"
			var err := img.save_png(ProjectSettings.globalize_path("res://").path_join(out_dir).path_join(file))
			if err != OK:
				failures += 1
				printerr("[bomb-aim-board] could not write ", file)
			frames.append({"file": file, "option": o["letter"], "look": str(o["mode"]), "title": "%s  ·  %s  ·  %s" % [o["letter"], o["title"], shot["title"]],
				"zoom": snappedf(s.scene.sb.ctl.camera.zoom.x, 0.001),
				"aim": str(shot["aim"]), "caption": "%s: %s. %s" % [o["title"], shot["caption"], o["line"]], "size": [img.get_width(), img.get_height()]})
		_say("shot '%s' photographed in %d looks (%s)" % [shot["id"], OPTIONS.size(), str(aim_info[str(shot["id"])])])
	style.ui["bombs"]["aim"]["mode"] = base_mode
	await _write()
	s.shutdown()
	quit(1 if failures > 0 else 0)

# The near rim of the cone, a hair inside it: the worst release angle the cone allows (the point of the
# polygon nearest the bomber, pulled toward the ideal aim).
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
	return {"accuracy": snappedf(float(d["quality"]), 0.01), "spread_across_m": snappedf(float(sp["across_m"]), 0.1), "sigma_m": snappedf(float(sp["sigma_m"]), 0.1), "stick_m": snappedf(float(sp["stick_m"]), 0.1)}

# The sheet's crop of a whole frame: the planning frame cropped by a fixed rect, a close frame round the aim.
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

# --- the sheet -------------------------------------------------------------------------------------

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var margin := 22.0
	var gap := 12.0
	var cw := [CROPS["play"].size.x, CROP_CLOSE.x, CROP_CLOSE.x]
	var ch := CROP_CLOSE.y
	var w := int(margin * 2.0 + cw[0] + cw[1] + cw[2] + gap * 2.0)
	var head_h := 240.0
	var opt_h := 22.0 + ch + 14.0 + 64.0
	var pal_h := 430.0
	var h := int(head_h + opt_h * float(OPTIONS.size()) + pal_h)
	var sh := BoardSheet.new(style, Vector2i(w, h))
	sh.text(Vector2(margin, 34), "The bomb cone and the aim  ·  seed %d, the running sandbox" % SEED, 25.0, sh.c_text)
	var hy := 44.0
	hy += sh.paragraph(Vector2(margin, hy), "Alex (2026-10-10): bombing is \"per step, just like diving. You set the intent in the cone. The accuracy is based on how close you are to the ideal release angle,\" and height is a factor; a bomber makes several drops. In the game: the orders card's Drop control turns a drop on for the step the card is about; the map then shows that step's BOMB CONE (where this step's release can put the bombs, from the simulation) and you place the AIM POINT in it, a handle like a step's with the same grow-and-fill hover.", 12.5, sh.c_muted, float(w) - margin * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(margin, hy), "Each row is one look at the same three frames of the game: the planning zoom with the aim at the ideal release angle (accuracy %d%%, spread %.0f m: the ellipse is 2 sigma, and half the stick, round it), the close zoom over the same aim, and the close zoom with the aim dragged to the cone's near rim (accuracy %d%%, spread %.0f m). A look has to say three things at once: WHERE bombs can go (the cone), WHERE they will land on average and how widely (the aim and its spread), and HOW GOOD the release is (the accuracy, as shading, size and lettering). The scene: the bomber on the left flying east at medium height, the village's walled compound with the radio tower under the aim, a battery north of it and one south, a fighter of yours beside the tower so the village is in sight." % [
		roundi(float((aim_info["play"] as Dictionary).get("accuracy", 1.0)) * 100.0), float((aim_info["play"] as Dictionary).get("spread_across_m", 0.0)),
		roundi(float((aim_info["rim"] as Dictionary).get("accuracy", 0.35)) * 100.0), float((aim_info["rim"] as Dictionary).get("spread_across_m", 0.0))], 12.0, sh.c_muted, float(w) - margin * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(margin, hy), "Every option is PROPOSED by Track U3; nothing is chosen (chosen: null). Crops are 1:1 from the game's own frames; the whole frames (1280 x 720, native size) are <option>_play.png / _close.png / _rim.png, captions in frames.json. The tower and the batteries are drawn at twice the planes' scale (marker.static_scale, proposed) so the target reads at the planning zoom. Every unit and every plan node carries a small height-and-speed label (Alex, 2026-10-10: height is hard to read from above): \"400 m · 85\" under a unit, \"2 · 85 m/s · 400 m\" at a node; they are in every frame.", 12.0, sh.c_muted, float(w) - margin * 2.0, true)
	var y := head_h
	var records: Array = []
	for o: Dictionary in OPTIONS:
		sh.line(Vector2(margin, y), Vector2(float(w) - margin, y), sh.c_rule, 1.0)
		sh.text(Vector2(margin, y + 18), "%s  ·  %s" % [o["letter"], o["title"]], 17.0, sh.c_text)
		sh.text(Vector2(margin + 680, y + 18), "bombs.aim.mode = %s" % o["mode"], 12.0, sh.c_muted, true)
		var iy := y + 28.0
		var x := margin
		for i in SHOTS.size():
			var shot: Dictionary = SHOTS[i]
			sh.image(crops["%s_%s" % [o["id"], shot["id"]]], Vector2(x, iy + 12.0))
			sh.text(Vector2(x, iy + 8.0), str(shot["title"]), 11.0, sh.c_muted, true)
			x += float(cw[i]) + gap
		sh.paragraph(Vector2(margin, iy + 12.0 + ch + 8.0), str(o["line"]), 12.0, sh.c_muted, float(w) - margin * 2.0, true)
		y += opt_h
		records.append(_record(o))
	_palette_strip(sh, Vector2(margin, y + 14.0), float(w) - margin * 2.0)
	var err: int = await sh.save(self, base.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[bomb-aim-board] could not write board.png: ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), w, h])
	_write_json(base.path_join("board.json"), records)
	_write_frames(base.path_join("frames.json"))

func _record(o: Dictionary) -> Dictionary:
	var a: Dictionary = style.ui["bombs"]["aim"]
	var params := {}
	for k: String in ["rim_px", "mark", "ideal", "release", "spread", str(o["mode"])]:
		var d: Variant = a.get(k)
		if d is Dictionary:
			var c: Dictionary = (d as Dictionary).duplicate(true)
			for kk: String in c.keys():
				if kk.begins_with("_"):
					c.erase(kk)
			params[k] = c
		elif d != null:
			params[k] = d
	return {"name": o["letter"], "title": o["title"], "bombs.aim.mode": o["mode"], "files": ["%s_play.png" % o["id"], "%s_close.png" % o["id"], "%s_rim.png" % o["id"]],
		"proposed": true, "description": o["line"], "parameters": params}

func _write_frames(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[bomb-aim-board] could not write ", path)
		return
	f.store_string(JSON.stringify({"id": "bomb-aim", "about": "Every frame of the board as its own PNG at native size (1280 x 720), with its caption. board.png is the sheet of 1:1 crops of these.", "frames": frames}, "  ", false))
	f.close()
	_say("saved " + path)

func _write_json(path: String, records: Array) -> void:
	var accent: Color = style.palette["side_a"]
	var ink: Color = style.palette["ink"]
	var paper: Color = style.palette["paper"]
	var doc := {
		"id": "bomb-aim",
		"date": "2026-10-10",
		"area": "UI, Specials",
		"question": "How are the bomb cone and the aim mark with its spread drawn? Alex's decisions behind the control (bomb-release, bomb-load): a drop is per step like diving, the player sets the intent in the cone, accuracy follows how close the release is to the ideal release angle, height is a factor, a bomber makes several drops.",
		"source": "scripts/ui/boards/bomb_aim_board_shot.gd: the running sandbox (scripts/app/sandbox.gd) over the real map and the village Track W lays out, through scripts/ui/boards/strike_scene.gd (the radio tower, two batteries and a player bomber added; the drop planned through the planner's own calls), photographed once per option with ONLY data/ui/ui.json bombs.aim.mode changed",
		"seed": SEED,
		"held_constant": {
			"scene": "the player's bomber (Anvil, medium band, 85 m/s, flying east) with two steps planned and its SECOND step's drop aimed at the radio tower in the village's compound (the cone and the numbers are the simulation's own: World.drop_cone / drop_spread, scripts/sim/bombs.gd); a player fighter beside the tower so the village is in sight; the orders card with Drop on and the roster with the bomber's drops left are in the whole frames",
			"shots": {"play": "the planning zoom 0.35, the aim at the ideal release angle", "close": "zoom 1.0 over the same aim", "rim": "zoom 1.0, the aim on the cone's near rim (the worst release angle)"},
			"accuracy_and_spread": aim_info,
			"decisions_in_force": "shadow strength 0.44; pen 'shadow_side'; side colours brick red (allies) and slate blue (axis); cones as a colour wash for the selected unit only (Alex, cone-overlay); the node-hover pick 'grow and fill' for every handle, the aim's too; planes at their own scale",
		},
		"parameter": "data/ui/ui.json#bombs.aim.mode (outline | wash | stipple | rings) and bombs.aim.<look> for each one's numbers; bombs.aim.spread.sigma_k how many sigmas the drawn ellipse holds",
		"also_built_behind_every_option": "the aim is a handle (press it, drag it; held inside the cone; nearest handle wins); a press in the cone off every handle moves the aim there; the cursor is a cross there; the orders card line says the spread and the accuracy; the aim handle's hover is the grow-and-fill; the enemy's drops are never drawn; another player's drop shows as a small crosshair with no cone",
		"options": records,
		"palette_check": "No option adds a hue. The cone's interior is the unit's SIDE ACCENT (side_a, L %.3f, C %.3f), the same colour as the bomber's roundels and the guns' cone wash; the rim, the fall line, the crosshair, the spread and the lettering are INK (L %.3f) and PAPER (L %.3f, alpha 0.92 for the crosshair's pool and the lettering's halo). Lightness is a ramp off paper: the wash's depth (alpha 0.07 at the rim to 0.30 at the ideal aim) is the accuracy; the spread's ink fill is 0.13. Material is linework: dashes, dots and rings; the only fills are the wash and the spread's faint ink." % [
			BoardSheet.oklch(accent).x, BoardSheet.oklch(accent).y, BoardSheet.oklch(ink).x, BoardSheet.oklch(paper).x],
		"recommendation_proposed": "B, the wash (bombs.aim.mode in data is set to it, PROPOSED, so the build gives feedback before Alex picks): it is the look Alex already chose for the guns' cones, so every cone on the map is one language; its depth is the accuracy, so the cone itself says where the release is good, with no lettering needed; the ink spread ellipse on it stays legible over the village's linework. A is the quietest and leaves the ground readable; C says 'random' best but is heavy on a busy map; D draws the throw as a distance, which suits a player who wants to judge the range.",
		"frames": "frames.json (every frame whole, with its caption)",
		"sheet": "board.png (rows A-D: the planning zoom, the close zoom over the ideal aim, the close zoom over a rim aim; a palette strip below)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[bomb-aim-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)

# --- the palette strip (working rule 6: every art choice includes the palette) ---------------------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette, and what the bomb cone spends of it", 16.0, sh.c_text)
	var side_a: Color = style.palette["side_a"]
	var wash_lo := Color(side_a.r, side_a.g, side_a.b, style.num("bombs.aim.wash.alpha_rim"))
	var wash_hi := Color(side_a.r, side_a.g, side_a.b, style.num("bombs.aim.wash.alpha_centre"))
	var chips := [
		["paper", style.palette["paper"]],
		["ink", style.palette["ink"]],
		["side_a (yours)", side_a],
		["wash at the rim", BoardSheet.over(wash_lo, style.palette["paper"])],
		["wash at the aim", BoardSheet.over(wash_hi, style.palette["paper"])],
		["spread fill", BoardSheet.over(UiRolesLite.role(style, "bombs.aim.spread.fill_role"), style.palette["paper"])],
		["crosshair pool", BoardSheet.over(UiRolesLite.role(style, "bombs.aim.halo_role"), style.palette["paper"])],
	]
	var x := pos.x
	for c: Array in chips:
		sh.chip(Vector2(x, pos.y + 40.0), c[1], str(c[0]), BoardSheet.oklch_text(c[1]))
		x += 148.0
	var ink_l: float = BoardSheet.oklch(style.palette["ink"]).x
	var paper_l: float = BoardSheet.oklch(style.palette["paper"]).x
	var deep: Color = BoardSheet.over(wash_hi, style.palette["paper"])
	var lines := [
		"Hue stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md). The cone's colour is the bomber's own side accent (side_a, brick red), the same one as its roundels and the guns' cone wash: a cone on the map is always its unit's colour. Everything drawn on top is ink or paper. Nothing else is coloured.",
		"Against the village (ink walls and roofs, trees in ink and a pale fill) the wash at 0.07 to 0.30 of side_a keeps the linework readable under it: at its deepest (L %.3f over the paper's %.3f) ink is still %.2f of lightness darker than the ground (OKLab distance %.2f). The accuracy is the wash's depth, a lightness step, not a second hue." % [BoardSheet.oklch(deep).x, paper_l, BoardSheet.oklch(deep).x - ink_l, BoardSheet.delta_ok(deep, style.palette["ink"])],
		"Material is linework: the rim, the dotted fall line and the dashed or solid spread are strokes; the crosshair has a paper pool so it reads on the busiest ground (the same pool the node-hover halo uses).",
	]
	var yy := pos.y + 140.0
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width - 40.0, false, 3.0) + 5.0

# (a role is resolved the way the interface resolves one: through UiRoles)
class UiRolesLite:
	const UiRoles = preload("res://scripts/ui/ui_roles.gd")
	static func role(st, path: String) -> Color:
		return UiRoles.resolve(st, st.lookup(path), path)
