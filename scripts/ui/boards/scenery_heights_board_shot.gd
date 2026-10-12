extends SceneTree

# BOARD: SCENERY HEIGHTS (builder SH, 2026-10-11). WINDOWED ONLY. Nothing in the game changes until Alex picks.
#
# Alex, asked "Scenery heights: fix the heights of trees, houses and walls to real-world sizes, with look options before
# anything is built?": "12 yes, but show me" (decision scenery-heights). Misfit 3 of docs/proposals/shot-heights.md: scenery is
# authored in the prototype's px, so at the decided 2 px/m a median tree is 12.7 m (6.3 to 28.8), houses 10.7 to 14.5 m, walls
# 5 to 7 m, while terrain.json says "tallest tree 14 m" (true at 4 px/m, stale now). A height drives the SHADOW and nothing
# else (the sprites, footprints and crowns do not read it), so the options differ in how long the shadows are.
#
# ONE PROCESS PER (option, scenario). The heights are read when the map is built and baked once, so each process is its own run of
# the real game: BoardScene (the Sandbox exactly as Local builds it) on the Strike's seed 20261009 or the Hold the bridge's seed 55,
# the fog off, the sun FIXED (the prototype's 315 degrees, 46 degrees: the frames are comparable), the same units in the same
# places; only the option's heights differ. How an option reaches the game: scenery_heights_patch.gd rewrites the two lines of the
# port that set a height IN MEMORY (the files and data are not touched), see its header and board.json "mechanism".
#
#   $env:INKWOOD_STEAM = "off"
#   Godot_v4.7-stable_win64_console.exe --path . --windowed --resolution 1280x720 `
#       --script res://scripts/ui/boards/scenery_heights_board_shot.gd -- option=s1 scenario=strike [out=variants/scenery-heights]
#   ... one run per option (s0 s1 s2 s3) and scenario (strike bridge), then
#   ... --script res://scripts/ui/boards/scenery_heights_board_shot.gd -- compose=1 [out=variants/scenery-heights]
#
# `compose=1` reads the frames and their sidecars and writes board.png (the sheet), frames.json and board.json ("chosen": null).
# EVERYTHING HERE IS PROPOSED (the options, their numbers, the subjects, the crops): Alex's only words are above.

const OUT_DEFAULT := "variants/scenery-heights"
const WINDOW := Vector2i(1280, 720)
const PLAN_ZOOM := 0.35     # data/view/camera.json zoom.start: the planning view, what the player sees at the start of every turn
const CLOSE_ZOOM := 3.0     # data/view/camera.json zoom.max: the closest zoom
const SEEDS := {"strike": 20261009, "bridge": 55}
const FAR := Vector2(4400.0, 4400.0)   # where a unit that is not in a shot waits

# The options, all PROPOSED except S0 (today's data). Heights in metres; the board turns them into the multiples the patched lines
# read. house_mean_m / wall_mean_m: the mean height of a house / a wall (the generators vary it by 0.85 to 1.15 per building; a wall's
# height is also scaled per wall by its own hs). tree_mult scales every tree's height, tree_min_m / tree_max_m clamp it (0: no clamp).
# MEASURED on the Strike's map (a 1.5 km square round the village, 2,361 trees): today's trees run 6.4 to 28.7 m, median 11.2, p10 7.9,
# p90 16.1; only 1.4 percent are over 20 m. So S1's tree rule (8 to 20 m, median 12 to 14) is a +10 percent lift plus a clamp on the tails.
const OPTIONS := [
	{"id": "s0", "name": "S0", "title": "Today's heights", "short": "today (the prototype's px)",
		"patch": {}},
	{"id": "s1", "name": "S1", "title": "Real-world heights", "short": "real world",
		"patch": {"tree_mult": 1.1, "tree_min_m": 8.0, "tree_max_m": 20.0, "house_mean_m": 7.0, "wall_mean_m": 2.5}},
	{"id": "s2", "name": "S2", "title": "Halfway between S0 and S1", "short": "halfway",
		"patch": {"tree_mult": 1.05, "tree_min_m": 7.2, "tree_max_m": 24.4, "house_mean_m": 9.8, "wall_mean_m": 4.25}},
	{"id": "s3", "name": "S3", "title": "Real heights, trees a little taller", "short": "real, trees taller",
		"patch": {"tree_mult": 1.3, "tree_min_m": 9.0, "tree_max_m": 24.0, "house_mean_m": 7.0, "wall_mean_m": 2.5}},
]

# The subjects (PROPOSED). `centre`: the camera's metres, the same at both zooms. `crop_plan` / `crop_close`: the part of the 1280 x 720
# frame the sheet shows at 1:1. `units`: what the board puts in the shot (every other unit waits at FAR).
const SUBJECTS := [
	{"id": "village", "scenario": "strike", "title": "The village: the radio tower, its walled compound, houses and a tank",
		"centre": Vector2(2004.0, 1435.0), "tank": Vector2(1988.0, 1462.0), "tank_heading": 1.5708,
		"crop_plan": Rect2(412.0, 200.0, 456.0, 320.0), "crop_close": Rect2(440.0, 120.0, 456.0, 480.0)},
	{"id": "wood", "scenario": "strike", "title": "A wood's edge, a hedged field and open ground",
		"centre": Vector2(1735.0, 1345.0),
		"crop_plan": Rect2(412.0, 200.0, 456.0, 320.0), "crop_close": Rect2(250.0, 100.0, 456.0, 540.0)},
	{"id": "plane", "scenario": "strike", "title": "A plane at 120 m (low band) over houses and a wood, for scale",
		"centre": Vector2(1990.0, 1555.0), "plane": Vector2(1984.0, 1566.0), "plane_heading": 0.0,
		"crop_plan": Rect2(412.0, 200.0, 456.0, 320.0), "crop_close": Rect2(412.0, 150.0, 456.0, 420.0)},
	{"id": "bridge", "scenario": "bridge", "title": "The bridge on seed 55 with a tank beside it",
		"centre": Vector2(3835.0, 735.0),
		"crop_plan": Rect2(412.0, 200.0, 456.0, 320.0), "crop_close": Rect2(560.0, 40.0, 456.0, 520.0)},
]

var opts: Dictionary = {}
var out_dir := OUT_DEFAULT
var scene = null          # BoardScene
var sb: Node = null
var _failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	out_dir = str(opts.get("out", OUT_DEFAULT))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	if DisplayServer.get_name() == "headless":
		printerr("[scenery-board] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	if opts.has("compose"):
		_compose.call_deferred()
	else:
		_frame.call_deferred()

func _say(msg: String) -> void:
	print("[scenery-board] ", msg)

func _option(id: String) -> Dictionary:
	for o: Dictionary in OPTIONS:
		if str(o["id"]) == id:
			return o
	return {}

func _data(path: String) -> Dictionary:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	return raw if raw is Dictionary else {}

# The option's patch as the multiples scenery_heights_patch.gd reads, from the data's own numbers (nothing copied into code).
func _patch_for(opt: Dictionary) -> Dictionary:
	var p: Dictionary = opt["patch"]
	if p.is_empty():
		return {}
	var render := _data("res://data/params/render_defaults.json")
	var prm: Dictionary = render["parameters"]
	var ppm := float(((_data("res://data/terrain/terrain.json")["scale"] as Dictionary)["px_per_m"] as Dictionary)["value"])
	var house_today_m := 0.9 * float((prm["house_size"] as Dictionary)["default"]) / ppm      # structures.gd: houseSize * 0.9, at hs 1
	var wall_today_m := float((prm["wall_height"] as Dictionary)["default"]) / ppm            # at hs 1
	return {"tree_mult": float(p["tree_mult"]), "tree_min_m": float(p["tree_min_m"]), "tree_max_m": float(p["tree_max_m"]),
		"house_mult": float(p["house_mean_m"]) / house_today_m, "wall_mult": float(p["wall_mean_m"]) / wall_today_m}

# --- One run: one option on one scenario ------------------------------------------------------------------------------------------

func _frame() -> void:
	var opt := _option(str(opts.get("option", "s0")))
	var scenario := str(opts.get("scenario", "strike"))
	if opt.is_empty() or not SEEDS.has(scenario):
		printerr("[scenery-board] unknown option '%s' or scenario '%s'" % [str(opts.get("option")), scenario])
		quit(1)
		return
	var ppm := float(((_data("res://data/terrain/terrain.json")["scale"] as Dictionary)["px_per_m"] as Dictionary)["value"])
	# 1. the heights, BEFORE anything loads the generators
	var Patch = load("res://scripts/ui/boards/scenery_heights_patch.gd")
	var patch := _patch_for(opt)
	var err: String = Patch.apply(patch, ppm)
	if err != "":
		printerr("[scenery-board] ", err)
		quit(1)
		return
	_say("%s on %s (seed %d): %s" % [opt["id"], scenario, SEEDS[scenario], str(patch)])
	# 2. the fixed sun and the fog off: every unit and the whole patch are drawn wherever the camera looks
	var Sun = load("res://scripts/world/sun.gd")
	Sun.set_override({"mode": "fixed"})
	var sun = Sun.current()
	_say("sun: " + str(sun.describe()))
	var knobs: Node = root.get_node("DebugSettings")
	knobs.set_value("fog", knobs.OPTIONS["fog"]["choices"].find("off"))
	var BoardScene = load("res://scripts/ui/boards/board_scene.gd")
	scene = BoardScene.new(self)
	var t0 := Time.get_ticks_msec()
	if not await scene.start(300.0, scenario):
		printerr("[scenery-board] start failed: ", scene.errors)
		quit(1)
		return
	sb = scene.sb
	_say("playable after %d ms" % (Time.get_ticks_msec() - t0))
	# a clean frame: no HUD, no clock, no target ring, nothing selected, no lettering under the units
	sb.ui.hud.visible = false
	sb.clock.visible = false
	if sb.objective != null:
		sb.objective.visible = false
	sb.ui.selection.clear()
	sb.ui.set_process_input(false)
	var UiStyle = load("res://scripts/ui/ui_style.gd")
	var st = UiStyle.shared()
	(st.ui["labels"] as Dictionary)["enabled"] = false
	var info := {"option": opt["id"], "scenario": scenario, "seed": SEEDS[scenario], "patch": patch, "sun": str(sun.describe()),
		"sun_len": sun.sun_len(), "px_per_m": ppm, "frames": []}
	info["measured"] = _measure(scenario, ppm)
	_stage_units_once(scenario, info)
	for subj: Dictionary in SUBJECTS:
		if str(subj["scenario"]) != scenario:
			continue
		if opts.has("subject") and str(opts["subject"]) != str(subj["id"]):
			continue
		_stage(subj)
		await scene.frames(3)
		for kind: String in ["plan", "close"]:
			var zoom: float = PLAN_ZOOM if kind == "plan" else float(sb.ctl.clamp_zoom(CLOSE_ZOOM))
			await scene.look(subj["centre"], Vector2(640.0, 360.0), zoom)
			var settle: float = await scene.settle(180.0)
			var img: Image = await scene.grab()
			var file := "%s_%s_%s.png" % [opt["id"], subj["id"], kind]
			var e := img.save_png(out_dir.path_join(file))
			_say("saved %s (%s, settled %.1f s, %s)" % [file, str(img.get_size()), settle, error_string(e)])
			if e != OK:
				_failures += 1
			(info["frames"] as Array).append({"file": file, "subject": subj["id"], "kind": kind, "zoom": zoom,
				"px_per_m": float(sb.map_view.px_per_m) * zoom, "size": [img.get_width(), img.get_height()],
				"mean_lightness": _mean_lightness(img)})
	var f := FileAccess.open(out_dir.path_join("%s_%s.json" % [opt["id"], scenario]), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(info, "  ", false))
		f.close()
	if not scene.errors.is_empty():
		printerr("[scenery-board] scene errors: ", scene.errors)
		_failures += 1
	sb.map_view.baker.clear()   # the baker's workers must be done before quitting (CLAUDE.md: exit 139 otherwise)
	scene.shutdown()
	await process_frame
	await process_frame
	quit(1 if _failures > 0 else 0)

# What the heights of the scenery come to on THIS map: every tree in a 1.5 km square round the village (Strike) or the bridge (Hold the
# bridge), the village's houses and walls, the hedge trees. In metres. These are the numbers of the table under the frames.
func _measure(scenario: String, ppm: float) -> Dictionary:
	var terr = sb.terrain
	var centre := Vector2(1985.0, 1450.0) if scenario == "strike" else Vector2(3835.0, 735.0)
	var rect := Rect2((centre - Vector2(768.0, 768.0)) * ppm, Vector2(1536.0, 1536.0) * ppm)
	var trees: Array = terr.trees_in_rect_px(rect)
	var th := PackedFloat64Array()
	for t: Dictionary in trees:
		th.append(float(t["h"]) / ppm)
	var out := {"area_m": [centre.x - 768.0, centre.y - 768.0, 1536.0, 1536.0], "trees": _stats(th)}
	var vil = terr.village()
	if vil != null:
		var hh := PackedFloat64Array()
		var wh := PackedFloat64Array()
		for s: Dictionary in vil.structs:
			(hh if s["kind"] == "house" else wh).append(float(s["h"]) / ppm)
		out["houses"] = _stats(hh)
		out["walls"] = _stats(wh)
		var VillageDraw = load("res://scripts/render/village_draw.gd")
		var vd = VillageDraw.new(terr, terr.P)
		var hed := PackedFloat64Array()
		for t: Dictionary in vd.hedge_trees(vil):
			hed.append(float(t["h"]) / ppm)
		out["hedges"] = _stats(hed)
	return out

static func _stats(a: PackedFloat64Array) -> Dictionary:
	if a.is_empty():
		return {"n": 0}
	var s := a.duplicate()
	s.sort()
	var n := s.size()
	var over12 := 0
	var over20 := 0
	for v in s:
		if v >= 12.0:
			over12 += 1
		if v > 20.0:
			over20 += 1
	return {"n": n, "min": s[0], "p10": s[int(n * 0.1)], "median": s[n / 2], "p90": s[mini(n - 1, int(n * 0.9))], "max": s[n - 1],
		"mean": _mean(s), "share_12_or_more": float(over12) / float(n), "share_over_20": float(over20) / float(n)}

static func _mean(a: PackedFloat64Array) -> float:
	var t := 0.0
	for v in a:
		t += v
	return t / float(maxi(a.size(), 1))

# The units that are the same in every shot of a scenario: every air unit (and the bridge scenario's enemy tanks and its cruiser) waits
# out of the way; the Strike gets a tank of its own for the village subject (a ground unit at rest).
func _stage_units_once(scenario: String, info: Dictionary) -> void:
	var w = sb.world
	for id: String in w.units:
		var u = w.units[id]
		if u.def.domain == "air" or (scenario == "bridge" and (str(u.type) == "cruiser" or u.controller == "ai" and str(u.type) == "tank")):
			u.x = FAR.x
			u.y = FAR.y
			u.out_of_bounds = false
	if scenario == "strike":
		var tid: String = w.add_unit({"id": "tank_sh", "type": "tank", "side": "allies", "controller": "player",
			"x": FAR.x - 100.0, "y": FAR.y - 100.0, "heading": 0.0, "speed": 0.0})
		info["tank_added"] = tid if tid != "" else ("ERROR: " + str(w.last_error))

# The units of one subject: the tank and the plane stand in the subject (or wait at FAR when the subject has none).
func _stage(subj: Dictionary) -> void:
	var w = sb.world
	if str(subj["scenario"]) == "strike":
		var tank = w.units.get("tank_sh")
		if tank != null:
			var at: Vector2 = subj.get("tank", FAR - Vector2(100.0, 100.0))
			tank.x = at.x
			tank.y = at.y
			tank.heading = float(subj.get("tank_heading", 0.0))
		var plane = w.units.get("light_fighter_1")
		if plane != null:
			if subj.has("plane"):
				var pa: Vector2 = subj["plane"]
				plane.x = pa.x
				plane.y = pa.y
				plane.heading = float(subj.get("plane_heading", 0.0))
				plane.altitude_band = "low"
			else:
				plane.x = FAR.x
				plane.y = FAR.y
			plane.out_of_bounds = false

# The mean lightness of a frame (OKLCH L): how much of the ground is in shadow.
func _mean_lightness(img: Image) -> float:
	var BoardSheet = load("res://scripts/ui/boards/board_sheet.gd")
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	for y in range(0, img.get_height(), 3):
		for x in range(0, img.get_width(), 3):
			var c := img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	return snappedf(BoardSheet.oklch(Color(r / n, g / n, b / n)).x, 0.001)

# --- The sheet, frames.json and board.json ---------------------------------------------------------------------------------------

const MARGIN := 24.0
const GAP := 12.0
const CROP_W := 456.0
const SHEET_W := 1908          # four 456 px crops across, 1:1
const REF_TANK := [2.0, 2.5]   # units' heights from docs/proposals/shot-heights.md (the tank: ui.json, tank.json)
const REF_TOWER := [23.0, 27.0]
const REF_STEPS := [12.0, 24.0]
const REF_PLANE_LOW := 120.0
const LIVE_SUN_NOON := 0.58    # shadow length per unit of height at noon (data/params/sun.json clock model)
const LIVE_SUN_CLAMP := 2.0    # ... and at the clamp (dawn, dusk and the folded night hours)

var _side: Dictionary = {}     # "s1_strike" -> the sidecar
var _imgs: Dictionary = {}     # file -> Image

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _load_png(name: String) -> Image:
	var img := Image.load_from_file(out_dir.path_join(name))
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
	return img

func _m(v: float) -> String:
	return "%.1f" % v

# A measured record, by option, scenario and what ("trees", "houses", "walls", "hedges").
func _meas(opt_id: String, scenario: String, what: String) -> Dictionary:
	var side: Dictionary = _side.get("%s_%s" % [opt_id, scenario], {})
	var m: Dictionary = side.get("measured", {})
	return m.get(what, {})

func _range_text(r: Dictionary) -> String:
	if r.is_empty() or int(r.get("n", 0)) == 0:
		return "none"
	return "%s to %s" % [_m(float(r["min"])), _m(float(r["max"]))]

func _compose() -> void:
	var BoardSheet = load("res://scripts/ui/boards/board_sheet.gd")
	var UiStyle = load("res://scripts/ui/ui_style.gd")
	var style = UiStyle.new()
	if not style.ok():
		printerr("[scenery-board] style errors: ", style.errors)
		quit(1)
		return
	for o: Dictionary in OPTIONS:
		for scn: String in ["strike", "bridge"]:
			var key := "%s_%s" % [o["id"], scn]
			var info: Variant = _read_json(out_dir.path_join("%s.json" % key))
			if not (info is Dictionary):
				printerr("[scenery-board] missing sidecar %s.json in %s: run option=%s scenario=%s first" % [key, out_dir, o["id"], scn])
				quit(1)
				return
			_side[key] = info
			for fr: Dictionary in (info as Dictionary)["frames"]:
				var img := _load_png(str(fr["file"]))
				if img == null:
					printerr("[scenery-board] missing frame ", fr["file"])
					quit(1)
					return
				_imgs[str(fr["file"])] = img
	var sh = BoardSheet.new(style, Vector2i(SHEET_W, 9000))
	var tw := float(SHEET_W) - MARGIN * 2.0
	var s0t := _meas("s0", "strike", "trees")
	var y := 34.0
	sh.text(Vector2(MARGIN, y), "Scenery heights  ·  four options on the Strike's village (seed 20261009) and the Hold the bridge map (seed 55), under the fixed sun", 24.0, sh.c_text)
	y += 18.0
	y += sh.paragraph(Vector2(MARGIN, y), "Alex, asked \"Scenery heights: fix the heights of trees, houses and walls to real-world sizes, with look options before anything is built?\": \"12 yes, but show me\" (decision scenery-heights). Nothing in the game changes until he picks. EVERYTHING on this board except those words and S0 (today's data) is PROPOSED by the builder SH.", 12.5, sh.c_muted, tw, true) + 8.0
	y += sh.paragraph(Vector2(MARGIN, y), "THE MISFIT (docs/proposals/shot-heights.md, misfit 3). Scenery is authored in the prototype's pixels and the map is 2 px per metre, so on the Strike's map a house stands %s m to its ridge, a compound wall %s m and a tree %s m (median %s): the median tree is nearly as tall as the 12 m terrain step and the tallest as tall as the 24 m one, while a tank is 2 to 2.5 m. data/terrain/terrain.json still says 'tallest tree 14 m', which was true at 4 px/m. A height drives the SHADOW and nothing else (the sprites, footprints and crowns do not read it), so each option below changes how long the scenery's shadows are, not how big anything is drawn." % [_range_text(_meas("s0", "strike", "houses")), _range_text(_meas("s0", "strike", "walls")), _range_text(s0t), _m(float(s0t["median"]))], 12.5, sh.c_muted, tw) + 8.0
	y += sh.paragraph(Vector2(MARGIN, y), "WHAT YOU ARE LOOKING AT. Every crop is the real game's own pixels at 1:1 (never scaled): the map baked through the real pipeline, the unit markers over it, the fog off, the height and speed lettering off, the SUN FIXED at the prototype's (bearing 315, elevation 46, a shadow 0.97 x the height) so the frames compare. The game's own sun follows the time of day now (shadows 0.58 x at noon up to 2.0 x at dawn and dusk), so the differences between options are the SMALLEST they will be in play. Each pair of rows is one place at the planning zoom 0.35 (0.7 px per metre: what the player sees at the start of every turn) and at the closest zoom 3.0 (6 px per metre), left to right S0 to S3. The whole 1280 x 720 frames are the PNGs beside this sheet (frames.json). A tank (2 to 2.5 m), the radio tower (23 to 27 m, its lattice shadow) and a plane in the low band (120 m) are in the frames as the yardsticks.", 12.5, sh.c_muted, tw) + 8.0
	y += sh.paragraph(Vector2(MARGIN, y), "HOW AN OPTION REACHES THE GAME (board only). The heights come out of three lines of the port that no data key can set to '7 m' (a house's is the literal 0.9 x house_size, which is its footprint's scale too). scripts/ui/boards/scenery_heights_patch.gd rewrites two lines of scene_gen.gd and structures.gd IN MEMORY for the run, before anything loads them, and hands them the option's numbers; no file and no data value is changed, and S0 runs the unpatched code. board.json 'to_make_it_live' says what the real edit is if Alex picks one.", 12.5, sh.c_muted, tw) + 12.0
	# the four options
	sh.line(Vector2(MARGIN, y), Vector2(float(SHEET_W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 26.0), "The four options (heights measured on the Strike's map: a 1.5 km square round the village, %d trees)" % int(s0t["n"]), 18.0, sh.c_text)
	y += 38.0
	for o: Dictionary in OPTIONS:
		y += sh.paragraph(Vector2(MARGIN, y), _option_text(o), 12.5, sh.c_text if o["id"] == "s0" else sh.c_muted, tw, false, 3.0) + 6.0
	y += 6.0
	# the frames
	for subj: Dictionary in SUBJECTS:
		sh.line(Vector2(MARGIN, y), Vector2(float(SHEET_W) - MARGIN, y), sh.c_rule, 1.0)
		sh.text(Vector2(MARGIN, y + 26.0), str(subj["title"]), 18.0, sh.c_text)
		y += 38.0
		for kind: String in ["plan", "close"]:
			y = _frame_row(sh, y, subj, kind)
	# the chart and the table
	y = _chart(sh, style, y)
	y = _table(sh, y)
	y = _notes(sh, y)
	y = _palette_strip(sh, style, BoardSheet, y)
	var end_y := y + 20.0
	var path := out_dir.path_join("board.png")
	var e: int = await sh.save(self, path)
	if e != OK:
		printerr("[scenery-board] could not write board.png: ", error_string(e))
		quit(1)
		return
	var full := Image.load_from_file(path)
	full.get_region(Rect2i(0, 0, SHEET_W, int(end_y))).save_png(path)
	_say("saved %s (%d x %d)" % [path, SHEET_W, int(end_y)])
	_write_frames_json()
	_write_board_json()
	quit(0)

func _option_text(o: Dictionary) -> String:
	var id := str(o["id"])
	var t := _meas(id, "strike", "trees")
	var hs := _meas(id, "strike", "houses")
	var ws := _meas(id, "strike", "walls")
	var hg := _meas(id, "strike", "hedges")
	var nums := "trees %s m (median %s, p10 %s, p90 %s); houses %s m (mean %s); compound walls %s m; hedge trees %s m (median %s)" % [
		_range_text(t), _m(float(t["median"])), _m(float(t["p10"])), _m(float(t["p90"])), _range_text(hs), _m(float(hs["mean"])), _range_text(ws), _range_text(hg), _m(float(hg["median"]))]
	var why := ""
	match id:
		"s0":
			why = "The data as it stands (the prototype's pixels at 2 px/m)."
		"s1":
			why = "PROPOSED: the real-world heights. Trees lifted 10 percent (today's median is a little low for a broadleaf) and held to 8 to 20 m, so the 6 m saplings and the rare 28 m giants go; houses about 6 to 8 m to the ridge; compound walls about 1 to 2.5 m (the rampart ring 2.5, the low inner ring 1.1); hedge trees are already about 2 m and are left alone in every option."
		"s2":
			why = "PROPOSED: every number halfway between S0 and S1 (trees x1.05 held to 7.2 to 24.4 m, houses 9.8 m mean, walls 4.25 m), for a look that is a compromise."
		"s3":
			why = "PROPOSED: S1's houses, walls and hedges, but every tree 30 percent taller than today (median 14.6 m, held to 9 to 24 m), a little over the real range. Why: a crown is drawn 19 m across at 2 px/m (the prototype's 38 px), so a tree's shadow is displaced by its height times the sun's length; below about a crown's radius that displacement hides under the tree itself and a wood reads as a mat of discs, not as trees casting shadows. S1 against S3 at the planning zoom shows whether that matters."
	return "%s  %s  ·  %s  ·  %s" % [str(o["name"]), str(o["title"]), nums, why]

func _caption(subj: Dictionary, o: Dictionary) -> String:
	var id := str(o["id"])
	var scn := str(subj["scenario"])
	var t := _meas(id, scn, "trees")
	match str(subj["id"]):
		"village":
			return "walls %s m, houses %s m" % [_range_text(_meas(id, scn, "walls")), _range_text(_meas(id, scn, "houses"))]
		"wood":
			return "trees median %s m (%s), hedge trees %s m" % [_m(float(t["median"])), _range_text(t), _range_text(_meas(id, scn, "hedges"))]
		"plane":
			return "houses %s m, trees median %s m, the plane 120 m" % [_range_text(_meas(id, scn, "houses")), _m(float(t["median"]))]
	return "trees median %s m (%s) on this map" % [_m(float(t["median"])), _range_text(t)]

func _frame_row(sh, y: float, subj: Dictionary, kind: String) -> float:
	var crop: Rect2 = subj["crop_plan"] if kind == "plan" else subj["crop_close"]
	var label := "planning zoom 0.35 (0.7 px per metre), 1:1" if kind == "plan" else "closest zoom 3.0 (6 px per metre), 1:1"
	sh.text(Vector2(MARGIN, y + 13.0), label, 12.0, sh.c_muted, true)
	y += 20.0
	var x := MARGIN
	for o: Dictionary in OPTIONS:
		var file := "%s_%s_%s.png" % [o["id"], subj["id"], kind]
		sh.text(Vector2(x, y + 13.0), "%s  %s" % [str(o["name"]), str(o["short"])], 13.5, sh.c_text)
		sh.image(_imgs[file], Vector2(x, y + 20.0), crop)
		sh.rect(Rect2(Vector2(x, y + 20.0), crop.size), sh.c_chip_line, false, 1.0)
		sh.text(Vector2(x, y + 20.0 + crop.size.y + 13.0), _caption(subj, o), 11.0, sh.c_muted, true)
		x += CROP_W + GAP
	return y + 20.0 + crop.size.y + 26.0

# --- The heights chart --------------------------------------------------------------------------------------------------------

func _chart(sh, style, y0: float) -> float:
	var pal: Dictionary = style.palette
	sh.line(Vector2(MARGIN, y0), Vector2(float(SHEET_W) - MARGIN, y0), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y0 + 26.0), "The heights against the things on the map (metres; a bar is the median, or the mean for houses and walls; the whisker the min and max)", 18.0, sh.c_text)
	var pm := 9.0                       # px per metre of height in this chart
	var top := y0 + 80.0
	var base := top + 30.0 * pm
	var x_axis := MARGIN + 60.0
	var x_end := float(SHEET_W) - MARGIN - 190.0
	# the yardsticks first (bands and lines), then the bars over them
	var shade_col: Color = pal["shadow"]
	sh.rect(Rect2(Vector2(x_axis, base - REF_TOWER[1] * pm), Vector2(x_end - x_axis, (REF_TOWER[1] - REF_TOWER[0]) * pm)), Color(shade_col.r, shade_col.g, shade_col.b, 0.35))
	sh.text(Vector2(x_end + 8.0, base - REF_TOWER[1] * pm + 12.0), "radio tower 23 to 27 m", 11.5, sh.c_muted)
	sh.rect(Rect2(Vector2(x_axis, base - REF_TANK[1] * pm), Vector2(x_end - x_axis, (REF_TANK[1] - REF_TANK[0]) * pm)), Color(shade_col.r, shade_col.g, shade_col.b, 0.8))
	sh.text(Vector2(x_end + 8.0, base - REF_TANK[1] * pm + 4.0), "a tank, 2 to 2.5 m", 11.5, sh.c_muted)
	for s: float in REF_STEPS:
		sh.line(Vector2(x_axis, base - s * pm), Vector2(x_end, base - s * pm), sh.c_chip_line, 1.0)
		sh.text(Vector2(x_end + 8.0, base - s * pm + 4.0), "terrain step %d m" % int(s), 11.5, sh.c_muted)
	for v: int in [0, 5, 10, 15, 20, 25, 30]:
		sh.line(Vector2(x_axis - 6.0, base - float(v) * pm), Vector2(x_axis, base - float(v) * pm), sh.c_muted, 1.0)
		sh.text(Vector2(MARGIN, base - float(v) * pm + 4.0), "%d m" % v, 11.0, sh.c_muted)
	sh.line(Vector2(x_axis, top), Vector2(x_axis, base), sh.c_muted, 1.0)
	sh.line(Vector2(x_axis, base), Vector2(x_end, base), sh.c_muted, 1.0)
	var kinds: Array = [["trees", pal["object_fill"], "median"], ["houses", pal["roof_lit"], "mean"], ["walls", pal["wall_fill"], "mean"], ["hedges", pal["rock_fill"], "median"]]
	var group_w := (x_end - x_axis) / 4.0
	for k in OPTIONS.size():
		var o: Dictionary = OPTIONS[k]
		var gx := x_axis + group_w * float(k) + 22.0
		sh.text(Vector2(gx, top - 18.0), "%s  %s" % [str(o["name"]), str(o["short"])], 13.0, sh.c_text)
		for j in kinds.size():
			var kd: Array = kinds[j]
			var r := _meas(str(o["id"]), "strike", str(kd[0]))
			var v := float(r[str(kd[2])])
			var bx := gx + float(j) * 84.0
			var col: Color = kd[1]
			sh.rect(Rect2(Vector2(bx, base - v * pm), Vector2(58.0, v * pm)), col)
			sh.rect(Rect2(Vector2(bx, base - v * pm), Vector2(58.0, v * pm)), sh.c_chip_line, false, 1.0)
			var cx := bx + 29.0
			sh.line(Vector2(cx, base - float(r["min"]) * pm), Vector2(cx, base - float(r["max"]) * pm), sh.c_text, 1.5)
			sh.line(Vector2(cx - 6.0, base - float(r["min"]) * pm), Vector2(cx + 6.0, base - float(r["min"]) * pm), sh.c_text, 1.5)
			sh.line(Vector2(cx - 6.0, base - float(r["max"]) * pm), Vector2(cx + 6.0, base - float(r["max"]) * pm), sh.c_text, 1.5)
			sh.text(Vector2(cx + 8.0, base - v * pm - 4.0), _m(v), 11.5, sh.c_text)
			sh.text(Vector2(bx + 6.0, base + 15.0), str(kd[0]), 11.5, sh.c_muted)
	return base + 40.0

# --- The table ---------------------------------------------------------------------------------------------------------------------

func _table(sh, y0: float) -> float:
	sh.line(Vector2(MARGIN, y0), Vector2(float(SHEET_W) - MARGIN, y0), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y0 + 26.0), "The numbers: each option's heights (metres) and shadows against the yardsticks (the Strike's map; the units' heights are docs/proposals/shot-heights.md)", 18.0, sh.c_text)
	var y := y0 + 46.0
	var c0 := MARGIN
	var cw := 360.0
	var cx0 := MARGIN + 440.0
	sh.text(Vector2(c0, y + 14.0), "what", 12.5, sh.c_muted, true)
	for k in OPTIONS.size():
		sh.text(Vector2(cx0 + cw * float(k), y + 14.0), "%s  %s" % [str(OPTIONS[k]["name"]), str(OPTIONS[k]["short"])], 13.0, sh.c_text)
	y += 22.0
	var L := float((_side["s0_strike"] as Dictionary)["sun_len"])
	var rows: Array = []
	rows.append(["Trees: median (p10 to p90)", func(id: String) -> String:
		var t := _meas(id, "strike", "trees")
		return "%s  (%s to %s)" % [_m(float(t["median"])), _m(float(t["p10"])), _m(float(t["p90"]))]])
	rows.append(["Trees: shortest to tallest", func(id: String) -> String: return _range_text(_meas(id, "strike", "trees"))])
	rows.append(["Trees as tall as the 12 m terrain step, or taller", func(id: String) -> String:
		return "%d percent" % int(round(float(_meas(id, "strike", "trees")["share_12_or_more"]) * 100.0))])
	rows.append(["Trees over 20 m", func(id: String) -> String:
		return "%.1f percent" % (float(_meas(id, "strike", "trees")["share_over_20"]) * 100.0)])
	rows.append(["Trees on seed 55 (the bridge map): median (min to max)", func(id: String) -> String:
		var t := _meas(id, "bridge", "trees")
		return "%s  (%s)" % [_m(float(t["median"])), _range_text(t)]])
	rows.append(["Houses to the ridge: min to max (mean)", func(id: String) -> String:
		var t := _meas(id, "strike", "houses")
		return "%s  (%s)" % [_range_text(t), _m(float(t["mean"]))]])
	rows.append(["Compound walls (3: ring, divider, low inner ring)", func(id: String) -> String: return _range_text(_meas(id, "strike", "walls"))])
	rows.append(["Hedge trees: median (min to max)", func(id: String) -> String:
		var t := _meas(id, "strike", "hedges")
		return "%s  (%s)" % [_m(float(t["median"])), _range_text(t)]])
	rows.append(["A house's shadow at the board's sun (x%.2f)" % L, func(id: String) -> String: return "%s m" % _m(float(_meas(id, "strike", "houses")["mean"]) * L)])
	rows.append(["... at the game's noon sun (x%.2f) / its longest (x%.1f)" % [LIVE_SUN_NOON, LIVE_SUN_CLAMP], func(id: String) -> String:
		var hm := float(_meas(id, "strike", "houses")["mean"])
		return "%s m / %s m" % [_m(hm * LIVE_SUN_NOON), _m(hm * LIVE_SUN_CLAMP)]])
	rows.append(["The outer compound wall's shadow, board's sun / longest", func(id: String) -> String:
		var hw := float(_meas(id, "strike", "walls")["max"])
		return "%s m / %s m" % [_m(hw * L), _m(hw * LIVE_SUN_CLAMP)]])
	rows.append(["A median tree's shadow, board's sun / longest", func(id: String) -> String:
		var ht := float(_meas(id, "strike", "trees")["median"])
		return "%s m / %s m" % [_m(ht * L), _m(ht * LIVE_SUN_CLAMP)]])
	rows.append(["A median tree against a house (height ratio)", func(id: String) -> String:
		return "%s x" % _m(float(_meas(id, "strike", "trees")["median"]) / float(_meas(id, "strike", "houses")["mean"]))])
	rows.append(["A house against a tank (2 to 2.5 m)", func(id: String) -> String:
		return "%s to %s x" % [_m(float(_meas(id, "strike", "houses")["mean"]) / 2.5), _m(float(_meas(id, "strike", "houses")["mean"]) / 2.0)]])
	rows.append(["The outer wall against a tank", func(id: String) -> String:
		return "%s to %s x" % [_m(float(_meas(id, "strike", "walls")["max"]) / 2.5), _m(float(_meas(id, "strike", "walls")["max"]) / 2.0)]])
	var shade := true
	for r: Array in rows:
		if shade:
			sh.rect(Rect2(Vector2(MARGIN - 6.0, y), Vector2(float(SHEET_W) - MARGIN * 2.0 + 12.0, 20.0)), Color(1, 1, 1, 0.04))
		shade = not shade
		sh.text(Vector2(c0, y + 14.0), str(r[0]), 12.0, sh.c_muted)
		for k in OPTIONS.size():
			var fn: Callable = r[1]
			sh.text(Vector2(cx0 + cw * float(k), y + 14.0), str(fn.call(str(OPTIONS[k]["id"]))), 12.0, sh.c_text)
		y += 20.0
	y += 6.0
	y += sh.paragraph(Vector2(MARGIN, y), "UNCHANGED BY EVERY OPTION: a tank 2 to 2.5 m; the radio tower 23 to 27 m (art, its lattice shadow); the terrain steps 12 and 24 m; the bands 120 / 400 / 1,000 m, so a low-band plane's shadow stands 120 x 1% x the sun's length = 1.2 m from it at the board's sun (decision unit-sheet-choices: the gap is a hundredth of the height); the crowns, the footprints and the village's layout. The 25 m blast ceiling, the cruiser's 'twenty metres up' bridge deck wording and the fire's smoke heights are other rows of the heights chart and are not touched here.", 12.0, sh.c_muted, float(SHEET_W) - MARGIN * 2.0, false, 3.0) + 10.0
	return y

func _notes(sh, y0: float) -> float:
	sh.line(Vector2(MARGIN, y0), Vector2(float(SHEET_W) - MARGIN, y0), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y0 + 26.0), "What changes in the shadows, what to decide, and the builder's recommendation (PROPOSED)", 18.0, sh.c_text)
	var y := y0 + 40.0
	var tw := float(SHEET_W) - MARGIN * 2.0
	for p: String in NOTES:
		y += sh.paragraph(Vector2(MARGIN, y), p, 12.5, sh.c_muted, tw, false, 3.0) + 8.0
	return y + 4.0

# The text under the table, kept in one place so the sheet and board.json say the same (written after the frames were read).
const NOTES: Array[String] = [
	"WHAT CHANGES IN THE SHADOWS. Houses and walls carry the change; trees hardly move. At the board's sun a house's shadow goes from 12.0 m to 6.7 m in S1 (at the game's longest sun, x2.0, from 24.9 m to 13.8 m): today it is as long as the house is deep and falls across the next house and the road, in S1 it is a short wedge. The compound's rampart ring throws a 5.8 m shadow today (a second ring beside the 8 m wide earthwork) and 2.4 m in S1, so it reads as a low earthwork with a thin shadow instead of a fortress wall: the outer wall is 2.4 to 3.0 tanks tall today and 1.0 to 1.3 in S1, a house 5.0 to 6.2 tanks today and 2.8 to 3.5 in S1. The radio tower, unchanged at 23 to 27 m, goes from twice a house's height to 3.6 times it.",
	"TREES. S1 changes a tree's shadow by little: the median tree goes from 11.2 m to 12.3 m, its shadow from 10.8 m to 11.9 m, and only the tails move (the 1.4 percent of trees over 20 m, up to 28.7 m, stop at 20; the smallest, under 7.3 m today, come up to 8 m). Today's trees are already real-sized: the median is 11.2 m on this map (the 12.7 m of the study was the theoretical middle), a plausible broadleaf. What is odd today is that a median tree is SHORTER than a house (0.9 x); in S1 it is 1.8 x. S3's trees are 30 percent taller than today's: 74 percent of them reach the 12 m terrain step and 13.5 percent pass 20 m.",
	"AT THE PLANNING ZOOM the four options are close to indistinguishable: a house's shadow is 8 px long at 0.7 px per metre today and 5 px in S1, and the walls' and trees' differences are 1 to 3 px (compare the first row of each subject). The choice is plain at the closest zoom 3.0, where a house's shadow is 72 px today and 40 px in S1 beside a tank 54 px long. It is a close-up decision, and the game's longer sun (x2.0) doubles every difference.",
	"THE REASON FOR S3, CHECKED. A crown is drawn 19 m across (the prototype's 38 px at 2 px/m), and a tree's shadow is displaced by its height times the sun's length: 7.7 m (15.5 px) for a tree of 8 m against a crown radius of about 19 px, so only the shortest trees' shadows start to hide under their own crowns, and S1's floor of 8 m already holds those. In the planning rows S1 and S3 are hard to tell apart; S3's extra height buys little and costs a tree shadow twice as long as a house's (14.1 m against 6.7 m) and three quarters of the trees as tall as the terrain step.",
	"THE HEDGES AND THE PLANE. Hedge trees are already 1.3 to 4.2 m (median 2.4 m, about a tank's height) in all four, so no option touches them and S1's 'hedges about 2 m' is met. A low-band plane's shadow stands 1.2 m from it in every option (the decided 1 percent rule), unrelated to the scenery's heights.",
	"WHAT TO DECIDE (Alex), one recommendation each, all PROPOSED. (1) Houses and walls to real heights? Recommended yes, S1's numbers: a house 0.5 x its footprint scale (about 7 m to the ridge) and walls 5 px (2.5 m). (2) Trees: lift 10 percent and hold to 8 to 20 m (S1), or leave them as they are? Recommended S1's rule, but it is the one part with no visible difference at the planning zoom and it needs a new height window in the tree generator; leaving tree_height at 1.3 is a defensible smaller change. (3) Keep S2 (halfway) or S3 (taller trees) in play? Recommended no: S2 is a compromise nobody asked for and S3's reason is met by S1's 8 m floor.",
	"WHAT IT COSTS TO MAKE LIVE (PROPOSED). Data: wall_height 12 to 5, with a prototype_default of 12 beside it (so --parity and test_scene_gen still compare with the prototype, as shadow_strength does). One new key, house_height_ratio, replacing the literal 0.9 in structures.gd (0.9 to 0.5; default 0.9 keeps the port check). If the tree rule is taken, a tree_height_min_m / tree_height_max_m window in scene_gen.gd sync_tree (absent means no clamp). terrain.json's 'tallest tree (~14 m)' text reworded (24 m + 20 m = 44 m stays under the 120 m low band, Track S's constraint). No sprite, footprint or random stream changes, so every map bakes as before apart from the shadow passes. One caution: wall_height and the house ratio are in prototype px, right only at the demo baseline of 2 px per metre; a key in metres times px_per_m would follow the map-scale knob.",
]
const RECOMMENDATION := "S1 (PROPOSED, Alex decides): houses about 7 m to the ridge, compound walls about 2.5 m, trees held to 8 to 20 m (median 12.3). It fixes the two clear misfits (a house 5 to 6 tanks high, a wall 2.4 to 3 tanks) and puts the tower, trees, houses, walls and tanks in the real order of heights (25 m, 12 m, 7 m, 2.5 m, 2.3 m), while the trees themselves hardly change. If Alex wants the smallest edit: S1's houses and walls with today's trees, two data values and one new key, which looks the same at the planning zoom. Not S3 (its reason is met by S1's 8 m floor) and not S2 (a compromise nobody asked for)."

func _palette_strip(sh, style, BoardSheet, y0: float) -> float:
	var pal: Dictionary = style.palette
	sh.line(Vector2(MARGIN, y0), Vector2(float(SHEET_W) - MARGIN, y0), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y0 + 26.0), "The palette: heights add no colour (roles in data/params/render_defaults.json; no hex in the draw code)", 18.0, sh.c_text)
	var strength := float(style.params["shadow_strength"])
	var shadow: Color = pal["shadow"]
	var paper: Color = pal["paper"]
	var chips: Array = [
		["paper (the ground)", paper],
		["object fill (a lit tree)", pal["object_fill"]],
		["wall fill", pal["wall_fill"]],
		["roof, lit", pal["roof_lit"]],
		["shadow tint (steel)", shadow],
		["shadow on paper at %.2f" % strength, BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, strength), paper)],
		["shadow on a lit roof", BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, strength), pal["roof_lit"])],
		["ink", pal["ink"]],
	]
	var x := MARGIN
	var cy := y0 + 44.0
	for c: Array in chips:
		var col: Color = c[1]
		sh.chip(Vector2(x, cy), col, str(c[0]), BoardSheet.oklch_text(col), Vector2(120.0, 40.0))
		x += 158.0
	var yy := cy + 84.0
	var lo := 1.0
	var hi := 0.0
	for o: Dictionary in OPTIONS:
		for fr: Dictionary in ((_side["%s_strike" % o["id"]] as Dictionary)["frames"] as Array):
			if str(fr["kind"]) == "close":
				lo = minf(lo, float(fr["mean_lightness"]))
				hi = maxf(hi, float(fr["mean_lightness"]))
	var text := "HUE stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md). A height changes WHERE the one shadow tint falls and how far, never what it is: every shadow in every crop is the same steel tint at the same strength (%.2f), a shadow on paper and a shadow over a lit roof the two chips above, and where two shadows overlap they do not darken twice (each class is composited once). LIGHTNESS is still a ramp off paper: taller scenery puts more of the ground in shadow, shorter scenery less; the mean lightness of the closest-zoom frames runs from L %.3f to L %.3f across the options (the chart's bars use the object, roof, wall and rock fills: lightness steps, no new hue). MATERIAL is linework and stays so: the sprites, outlines and the shadow-side pen are the same in every option." % [strength, lo, hi]
	yy += sh.paragraph(Vector2(MARGIN, yy), text, 12.0, sh.c_muted, float(SHEET_W) - MARGIN * 2.0, false, 3.0) + 6.0
	return yy

func _write_frames_json() -> void:
	var frames: Array = []
	for o: Dictionary in OPTIONS:
		for scn: String in ["strike", "bridge"]:
			var info: Dictionary = _side["%s_%s" % [o["id"], scn]]
			for fr: Dictionary in info["frames"]:
				var subj_title := ""
				for s: Dictionary in SUBJECTS:
					if str(s["id"]) == str(fr["subject"]):
						subj_title = str(s["title"])
				var zoom_name := "planning_zoom" if str(fr["kind"]) == "plan" else "closest_zoom"
				frames.append({"file": fr["file"], "option": o["id"], "subject": fr["subject"], "kind": zoom_name,
					"zoom": fr["zoom"], "px_per_m": fr["px_per_m"], "size": fr["size"], "seed": info["seed"],
					"caption": "%s %s: %s, %s" % [str(o["name"]), str(o["short"]), subj_title, "planning zoom 0.35" if str(fr["kind"]) == "plan" else "closest zoom 3.0"]})
	var doc := {"id": "scenery-heights", "about": "Every frame of the scenery-heights board as its own PNG at native size (1280 x 720): the game's own pixels, one run of the real game per option and map (the Strike, seed 20261009, and Hold the bridge, seed 55; fog off, labels off, the sun fixed at 315 / 46). board.png is the sheet: 1:1 crops of these frames, the heights chart, the numbers table, the notes and the palette strip. The images are not committed (decision board-images): scripts/ui/boards/scenery_heights_board_shot.gd regenerates them.",
		"frames": frames}
	var f := FileAccess.open(out_dir.path_join("frames.json"), FileAccess.WRITE)
	if f == null:
		printerr("[scenery-board] could not write frames.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()

func _write_board_json() -> void:
	var render := _data("res://data/params/render_defaults.json")
	var prm: Dictionary = render["parameters"]
	var ppm := 2.0
	var house_size := float((prm["house_size"] as Dictionary)["default"])
	var wall_h := float((prm["wall_height"] as Dictionary)["default"])
	var tree_k := float((prm["tree_height"] as Dictionary)["default"])
	var options: Array = []
	for o: Dictionary in OPTIONS:
		var id := str(o["id"])
		var p: Dictionary = o["patch"]
		var live: Dictionary = {}
		var multiples: Dictionary = {}
		if not p.is_empty():
			var house_ratio := float(p["house_mean_m"]) * ppm / house_size   # house_height_ratio: h = ratio x house_size x hs (today 0.9)
			var wall_px := float(p["wall_mean_m"]) * ppm
			live = {
				"parameters.wall_height.default": snappedf(wall_px, 0.01),
				"parameters.house_height_ratio.default (NEW key; today the literal 0.9 in structures.gd sync_struct)": snappedf(house_ratio, 0.001),
				"parameters.tree_height.default": snappedf(tree_k * float(p["tree_mult"]), 0.001),
				"parameters.tree_height_min_m / tree_height_max_m (NEW keys; no clamp today, read in scene_gen.gd sync_tree)": [p["tree_min_m"], p["tree_max_m"]],
				"data/terrain/terrain.json level_heights_m reason": "the text 'the tallest tree (~14 m)' is stale at 2 px/m; reword it with the pick",
				"render_defaults.json prototype_default entries": "wall_height 12 and tree_height 1.3 keep a prototype_default beside the new default, as shadow_strength does, so --parity and test_scene_gen still compare with the prototype",
			}
			multiples = {"tree_mult": p["tree_mult"], "tree_min_m": p["tree_min_m"], "tree_max_m": p["tree_max_m"],
				"house_mult": snappedf(float(p["house_mean_m"]) / (0.9 * house_size / ppm), 0.0001), "wall_mult": snappedf(float(p["wall_mean_m"]) * ppm / wall_h, 0.0001)}
		var meas: Dictionary = {}
		for what: String in ["trees", "houses", "walls", "hedges"]:
			meas[what] = _meas(id, "strike", what)
		meas["trees_seed_55"] = _meas(id, "bridge", "trees")
		var files: Array = []
		for scn: String in ["strike", "bridge"]:
			for fr: Dictionary in _side["%s_%s" % [id, scn]]["frames"]:
				files.append(fr["file"])
		var lightness: Dictionary = {}
		for fr: Dictionary in _side["%s_strike" % id]["frames"]:
			lightness["%s_%s" % [fr["subject"], fr["kind"]]] = fr["mean_lightness"]
		options.append({"id": id, "name": o["name"], "title": o["title"], "proposed": id != "s0", "patch_m": p, "multiples_read_by_the_patch": multiples,
			"set_by": "today's data (nothing patched)" if p.is_empty() else "scripts/ui/boards/scenery_heights_patch.gd: the board-only override; the live equivalent is 'to_make_it_live'",
			"to_make_it_live": live, "measured_m_strike_map": meas, "mean_lightness_strike_frames": lightness, "files": files})
	var doc := {
		"id": "scenery-heights",
		"date": "2026-10-11",
		"area": "World, Style (the scale of the scenery)",
		"question": "Real-world heights for trees, houses and walls (prototype px today: walls 5-7 m, houses 10.7-14.5 m, trees 6-29 m at 2 px/m)? Alex: '12 yes, but show me'.",
		"source": "scripts/ui/boards/scenery_heights_board_shot.gd: one run of the real game per option and map (BoardScene on the Strike, seed 20261009, and Hold the bridge, seed 55; fog off, labels off, the sun fixed at 315 / 46), the heights switched by scripts/ui/boards/scenery_heights_patch.gd. Rendered in a throwaway checkout at HEAD because other builders were editing the units' data in the shared tree.",
		"seeds": SEEDS,
		"held_constant": {
			"sun": "FIXED (data/params/sun.json mode 'fixed': bearing 315, elevation 46, a shadow 0.966 x the height) so the frames compare; the game's live sun follows the time of day (0.58 x at noon to 2.0 x), which makes every difference between options larger",
			"map": "the same map, water, fog off; the same crowns, footprints, tree placement and random streams in every option (a height is read by the shadow passes only): the measured square holds the same %d trees on the Strike and %d on seed 55 in all four options" % [int(_meas("s0", "strike", "trees")["n"]), int(_meas("s0", "bridge", "trees")["n"])],
			"units": "a tank on the village road (Strike), a light fighter in the low band (120 m) over the village's south edge, the Strike's own tower and bridge; on seed 55 the two player tanks and the bridge (the enemy tanks and the cruiser are out of the shot); every other unit waits at (4400, 4400)",
			"left_off": "the HUD, the height and speed lettering, the target ring, the roster",
			"zooms": "planning zoom 0.35 (0.7 px per metre) and the closest zoom 3.0 (6 px per metre), the same camera centres in every option",
		},
		"mechanism": {
			"what": "Heights are set by three lines of the port: scene_gen.gd sync_tree (t.h = t.r * P.height * (0.85 + 0.3 * t.hr)), structures.gd sync_struct (s.h = P.wallH * s.hs for a wall, P.houseSize * 0.9 * s.hs for a house) and village_draw.gd (a hedge tree's h = r * P.height * (...) * terrain.json hedge.height_frac). A height drives the shadow passes (terrain_shadows.gd, chunk_terrain_provider.gd _struct_sil) and the trees' draw order, and nothing else: sprites, footprints, crowns, tree placement and every random draw are independent of it.",
			"board_override": "scripts/ui/boards/scenery_heights_patch.gd rewrites the two lines of scene_gen.gd and structures.gd in memory (Script.source_code + reload(), before the first instance; the files on disk are untouched) and puts the option's numbers in Engine meta 'scenery_heights'. With no meta the patched lines compute what they computed before. The hedge trees are not patched: they are already about 2 m.",
			"why_not_data": "wall_height and tree_height are data keys; a house's height is the literal 0.9 x house_size (the footprint's own scale, so house_size cannot be used), and trees have no height window.",
		},
		"to_make_it_live": {
			"_about": "PROPOSED, if Alex picks an option: each option's own 'to_make_it_live' lists the values. Data edits alone: parameters.wall_height.default and parameters.tree_height.default (plus a prototype_default beside each). Two small code edits: a house_height_ratio key replacing the literal 0.9 in structures.gd sync_struct (default 0.9 keeps the port check), and a tree_height_min_m / tree_height_max_m window in scene_gen.gd sync_tree (absent = no clamp, which the port check needs). RenderParams reads both (render_params.gd); test_scene_gen, test_port_utils and --parity keep the prototype's values through prototype_default. The board's patch file and this board script are then retired or kept as a look-compare tool.",
		},
		"yardsticks_m": {"tank": REF_TANK, "radio_tower": REF_TOWER, "terrain_steps": REF_STEPS, "low_band_plane": REF_PLANE_LOW, "source": "docs/proposals/shot-heights.md heights table"},
		"options": options,
		"subjects": _subjects_json(),
		"notes_proposed": NOTES,
		"recommendation_proposed": RECOMMENDATION,
		"palette_check": "Heights add no colour: every shadow is the one steel tint at the same strength, a shadow over a lit roof the roof-shaded chip. Taller scenery puts more of the ground in shadow (the mean lightness of the closest-zoom frames is in each option), a change in the SHARE of the ground in shadow, not in the lightness ramp. The chart's bars use the object, roof, wall and rock fills. Material stays linework: sprites and the shadow-side pen are identical in every option.",
		"frames": "frames.json (every frame, native 1280 x 720)",
		"sheet": "board.png (1:1 crops of every frame, the heights chart, the numbers table, the notes, the palette strip)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(out_dir.path_join("board.json"), FileAccess.WRITE)
	if f == null:
		printerr("[scenery-board] could not write board.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved board.json")

func _subjects_json() -> Array:
	var out: Array = []
	for s: Dictionary in SUBJECTS:
		var cp: Rect2 = s["crop_plan"]
		var cc: Rect2 = s["crop_close"]
		var ctr: Vector2 = s["centre"]
		out.append({"id": s["id"], "scenario": s["scenario"], "seed": SEEDS[str(s["scenario"])], "title": s["title"], "camera_centre_m": [ctr.x, ctr.y],
			"crop_plan": [cp.position.x, cp.position.y, cp.size.x, cp.size.y], "crop_close": [cc.position.x, cc.position.y, cc.size.x, cc.size.y]})
	return out
