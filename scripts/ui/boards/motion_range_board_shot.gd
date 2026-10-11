extends SceneTree

# BOARD: THE RANGE-OF-MOTION INDICATOR (builder BM, 2026-10-11). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/motion_range_board_shot.gd -- [out=variants/motion-range]
#
# Alex (2026-10-11, the second playtest): "I want to look at the design of the 'acceptable range of motion' indicator for
# planes. Is there a style that makes more sense across all unit types? Should we just have a little shaded area where you
# can set the node? Show me some options before commiting this."
#
# The indicator is the planner's FAN: the region where the NEXT step's node may be set (World.reachable's outline; for a
# tank or a ship it is clipped by the ground and sea rules, scripts/sim/ground_rules.gd, sea_rules.gd). This board draws it
# six ways, by the game's own planner (scripts/ui/motion_planner.gd _draw_fan; ONLY data/ui/ui.json planner.fan.mode
# changes between options), on four units of one side in the running sandbox over seed 20261009 (variants/motion-range/
# scenario.json, water on, fog off so every crop shows the drawn map):
#
#   a light fighter and the bomber over open ground,
#   a tank on the village road 33 m short of the river (the river clips its fan),
#   the cruiser beside the east coast (the shore clips its fan).
#
# Every unit has flown two real turns (its ribbon trail is the game's), has one or two steps planned and is the SELECTED
# unit, so the fan of its next step is up with its plan line, ghosts and speed labels. Per option and unit: zoom 1 (2 px per
# metre; the fan's apex at the same spot in every crop), the start zoom 0.35 and a zoomed-out 0.2. The weapon-cone wash is OFF
# in the grid (planner.cones.shown is another track's) and shown once, with the light fighter, below.
#
# The cruiser's fan is 30 m long and its hull 120 m: the marker layer draws the hull over the planner, so today the fan is
# hidden under it. The ship crops are therefore drawn with the planner raised above the markers (a rig action, not a game
# change); what the game draws today is shown separately at the foot of the sheet.
#
# Output (out=): board.png (the sheet), board.json ("chosen": null for Alex), frames.json and every crop as its own PNG
# at native size (<option>_<unit>_z<zoom>.png), a whole 1280 x 720 frame per unit (context_<unit>_z0.35.png).
#
# EVERY OPTION AND VALUE IS PROPOSED by builder BM; none is a decision.

const World = preload("res://scripts/sim/world.gd")
const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")

const SEED := 20261009
const SCENARIO := "../../variants/motion-range/scenario"
const APEX_SCREEN := Vector2(700.0, 380.0)       # where the fan's apex is put on screen for every frame
const ZOOMS := [1.0, 0.35, 0.2]
const ZOOM_TEXT := ["zoom 1", "zoom 0.35", "zoom 0.2"]
const CROP_SIZE := [Vector2i(380, 170), Vector2i(380, 110), Vector2i(380, 80)]   # per zoom, the same width in every cell
const CROP_APEX := [Vector2i(320, 85), Vector2i(150, 55), Vector2i(130, 40)]     # where the apex falls in the crop
const GAP := 14.0
const MARGIN := 22.0

# The four units. `end`: where it stands after two flown turns (metres; the tank's from the road, below); `speed`: the speed it flew at
# and plans at; `plan`: the steps planned in the turn shown; `ship`: the planner is drawn over the hull for it.
const CASE_DATA := [
	{"id": "light", "title": "Light fighter", "unit": "light_fighter_1", "end": Vector2(3200.0, 2900.0), "heading": 3.1, "speed": 100.0,
		"plan": [{"turn": 0.08, "speed": 100.0}, {"turn": -0.08, "speed": 100.0}]},
	{"id": "bomber", "title": "Bomber", "unit": "bomber_1", "end": Vector2(3350.0, 3250.0), "heading": 3.1, "speed": 85.0,
		"plan": [{"turn": 0.06, "speed": 85.0}, {"turn": -0.06, "speed": 85.0}]},
	{"id": "tank", "title": "Tank, by the river", "unit": "tank_1", "end": Vector2.ZERO, "road_m": -53.0, "heading": 0.0, "speed": 8.0,
		"plan": [{"turn": 0.0, "speed": 8.0}]},
	{"id": "cruiser", "title": "Cruiser, by the coast", "unit": "cruiser_1", "end": Vector2(3594.0, 1300.0), "heading": PI, "speed": 12.0,
		"plan": [{"turn": 0.0, "speed": 12.0}], "ship": true},
]

const OPTIONS := [
	{"id": "a_ribs", "letter": "A", "mode": "ribs", "title": "Today: outline, a faint wash and ribs"},
	{"id": "b_shade", "letter": "B", "mode": "shade", "title": "A shaded area, no outline (Alex's idea)"},
	{"id": "c_wash_rim", "letter": "C", "mode": "wash_rim", "title": "Wash and a thin inked rim"},
	{"id": "d_stipple", "letter": "D", "mode": "stipple", "title": "Stipple"},
	{"id": "e_hatch", "letter": "E", "mode": "hatch", "title": "Hatch"},
	{"id": "f_rim_ticks", "letter": "F", "mode": "rim_ticks", "title": "Quiet rim, and ticks for the slowest and the fastest reach"},
]

var out_dir := "variants/motion-range"
var cases: Array = []              # CASE_DATA, copied so the tank's place can be filled in
var scene: BoardScene = null
var style = null
var ui = null
var w = null
var crops: Dictionary = {}        # "<option id>/<case id>/<zoom index>" -> Image
var cone_crops: Dictionary = {}   # option id -> Image (the light fighter at zoom 0.35 with the cone wash on)
var hidden_crops: Dictionary = {} # "<option id>/<zoom index>" -> Image (the cruiser as the game draws it today: planner under the hull)
var contexts: Dictionary = {}     # case id -> whole frame (option A, zoom 0.35)
var measured: Dictionary = {}     # case id -> {...}
var failures := 0
var _planner_idx := -1

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	cases = CASE_DATA.duplicate(true)
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[motion-range-board] ", msg)

func _run() -> void:
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed %d, scenario %s)..." % [SEED, SCENARIO])
	if not await scene.start(240.0, SCENARIO):
		printerr("[motion-range-board] ", scene.errors)
		quit(1)
		return
	style = scene.style
	ui = scene.sb.ui
	w = scene.world()
	ui.hud.visible = false
	scene.sb.clock.visible = false
	ui.set_process_input(false)   # the real mouse must not move the board's pointer
	ui.cones.set_arcs_shown(false)
	var sc = scene.sb.scenario
	# The tank stands on the village road short of the river, facing it.
	for c: Dictionary in cases:
		if str(c["id"]) == "tank":
			var rm := float(c["road_m"])
			c["end"] = sc.site_point("water.bridge", 0, 0.0, 0.0, true, rm)
			c["heading"] = sc._road_heading_to_site("water.bridge", rm, "tank", true)
	_fly_two_turns()
	await scene.frames(4)
	_plan_steps()
	await scene.frames(4)

	var base_mode: String = style.text("planner.fan.mode")
	for c: Dictionary in cases:
		var id := str(c["unit"])
		ui.select(id)
		var apex := _apex_world(id)
		_say("%s: apex %s" % [str(c["id"]), str(apex.round())])
		if bool(c.get("ship", false)):
			_planner_top(true)
		for zi in ZOOMS.size():
			var z: float = ZOOMS[zi]
			await scene.look(apex, APEX_SCREEN, z)
			var t: float = await scene.settle()
			_say("%s zoom %s baked in %.1f s" % [str(c["id"]), str(z), t])
			if zi == 0 or zi == 1:
				measured["%s/%d" % [str(c["id"]), zi]] = _measure(id)
			for o: Dictionary in OPTIONS:
				style.ui["planner"]["fan"]["mode"] = str(o["mode"])
				await scene.frames(4)
				var img: Image = await scene.grab()
				crops["%s/%s/%d" % [str(o["id"]), str(c["id"]), zi]] = _crop(img, apex, zi)
				if zi == 1 and str(o["mode"]) == "ribs":
					contexts[str(c["id"])] = img
			# The light fighter with its weapon cones on (the cone wash is Alex's pick, and the fan sits in it).
			if str(c["id"]) == "light" and zi == 0:
				ui.cones.set_arcs_shown(true)
				for o: Dictionary in OPTIONS:
					style.ui["planner"]["fan"]["mode"] = str(o["mode"])
					await scene.frames(6)
					var img2: Image = await scene.grab()
					cone_crops[str(o["id"])] = _crop(img2, apex, zi)
				ui.cones.set_arcs_shown(false)
		if bool(c.get("ship", false)):
			_planner_top(false)
			# What the game draws today for the ship: the planner under the hull.
			for zi in [0, 1]:
				await scene.look(apex, APEX_SCREEN, float(ZOOMS[zi]))
				await scene.settle()
				for o: Dictionary in OPTIONS:
					if str(o["mode"]) != "ribs" and str(o["mode"]) != "shade":
						continue
					style.ui["planner"]["fan"]["mode"] = str(o["mode"])
					await scene.frames(4)
					var img3: Image = await scene.grab()
					hidden_crops["%s/%d" % [str(o["id"]), zi]] = _crop(img3, apex, zi)
		ui.selection.clear()
	style.ui["planner"]["fan"]["mode"] = base_mode

	await _write()
	scene.shutdown()
	await scene.frames(2)
	quit(1 if failures > 0 else 0)

# --- the rig ---------------------------------------------------------------------------------------------

# Every unit starts straight behind its place and flies two real turns to it, so the ribbon trail is the game's own, recorded as
# the turns resolve. The planes fly at their cruise, the tank and the ship at theirs.
func _fly_two_turns() -> void:
	for c: Dictionary in cases:
		var u = w.units[str(c["unit"])]
		var h: float = float(c["heading"])
		var v: float = float(c["speed"])
		var s: Vector2 = (c["end"] as Vector2) - Vector2.from_angle(h) * v * 2.0 * float(w.rules.turn_seconds)
		u.x = s.x
		u.y = s.y
		u.heading = h
		u.speed = v
		u.out_of_bounds = false
	ui.marker_layer.playback_paused = true
	for turn_no in [1, 2]:
		w.commit("local")
		var res: Dictionary = w.resolve()
		if res.is_empty():
			failures += 1
			printerr("[motion-range-board] turn %d did not resolve: %s" % [turn_no, w.last_error])
		ui.marker_layer.stop_playback()
		w.begin_turn()
	for c: Dictionary in cases:
		var u = w.units[str(c["unit"])]
		var err := Vector2(float(u.x), float(u.y)).distance_to(c["end"])
		_say("%s stands %.2f m from its place after two turns (speed %.1f)" % [str(c["id"]), err, float(u.speed)])
		if err > 1.5:
			failures += 1

func _plan_steps() -> void:
	for c: Dictionary in cases:
		var id := str(c["unit"])
		var steps: Array = c["plan"]
		for k in steps.size():
			w.plan_step(id, k, steps[k])

# The fan's apex: the last planned step's end (the unit itself with none planned).
func _apex_world(id: String) -> Vector2:
	var k: int = ui.planner.next_step_index(id)
	if k > 0:
		var prev: Dictionary = ui.planner.states(id)[k - 1]
		return Vector2(float(prev["x"]), float(prev["y"]))
	var u = w.units[id]
	return Vector2(float(u.x), float(u.y))

func _planner_top(on: bool) -> void:
	var p: Node = ui.planner
	var parent: Node = p.get_parent()
	if on:
		_planner_idx = p.get_index()
		parent.move_child(p, parent.get_child_count() - 1)
	else:
		parent.move_child(p, _planner_idx)

func _crop(img: Image, apex: Vector2, zi: int) -> Image:
	var a: Vector2 = scene.sb.map_view.world_to_screen(apex)
	var size: Vector2i = CROP_SIZE[zi]
	var at: Vector2i = CROP_APEX[zi]
	var o := Vector2i(roundi(a.x), roundi(a.y)) - at
	return img.get_region(Rect2i(o, size))

func _area(p: PackedVector2Array) -> float:
	var s := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		s += p[i].x * q.y - q.x * p[i].y
	return absf(s) * 0.5

# What the fan is, in screen px at the current zoom: how far its far edge is from the apex, how wide it is across, how deep (far to near edge,
# at the centre), its area and the share of its unclipped area the ground or sea rule left.
func _measure(id: String) -> Dictionary:
	var pl = ui.planner
	var poly: PackedVector2Array = pl.fan_outline_screen()
	var apex: Vector2 = pl._fan_apex()
	var n: int = poly.size() / 2
	var mid: int = n / 2
	var depth := poly[mid].distance_to(poly[poly.size() - 1 - mid])
	var k: int = pl.next_step_index(id)
	var u = w.units[id]
	var from: Dictionary = u.state() if k == 0 else pl.states(id)[k - 1]
	var env: Dictionary = u.def.envelope.reachable(from, w.step_dt(id))
	var ppm: float = scene.sb.map_view.px_per_m * scene.sb.ctl.zoom_level()
	var unclipped := _area(env["outline"]) * ppm * ppm
	return {"reach_px": snappedf(apex.distance_to(poly[mid]), 0.1), "across_px": snappedf(poly[0].distance_to(poly[n - 1]), 0.1), "depth_px": snappedf(depth, 0.1),
		"area_px2": snappedf(_area(poly), 1.0), "share_left": snappedf(_area(poly) / maxf(unclipped, 1e-6), 0.01), "zoom": scene.sb.ctl.zoom_level()}

# --- the sheet ---------------------------------------------------------------------------------------------

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var cw := float(CROP_SIZE[0].x)
	var width := int(MARGIN * 2.0 + cw * float(cases.size()) + GAP * float(cases.size() - 1))
	var inner := float(width) - MARGIN * 2.0
	var line_h := [float(CROP_SIZE[0].y), float(CROP_SIZE[1].y), float(CROP_SIZE[2].y)]
	var opt_h: float = 30.0 + (line_h[0] + 24.0) + (line_h[1] + 24.0) + (line_h[2] + 24.0) + 44.0
	var head_h := 330.0
	var cone_h := 92.0 + (float(CROP_SIZE[0].y) + 26.0) * 2.0
	var hid_h := 118.0 + float(CROP_SIZE[0].y) + 30.0
	var pal_h := 470.0
	var height := int(head_h + opt_h * float(OPTIONS.size()) + cone_h + hid_h + pal_h)
	var sh := BoardSheet.new(style, Vector2i(width, height))
	sh.text(Vector2(MARGIN, 34), "The range-of-motion indicator  ·  seed %d, the running game, four units, six looks" % SEED, 25.0, sh.c_text)
	var hy := 46.0
	for l: String in _head_lines():
		hy += sh.paragraph(Vector2(MARGIN, hy), l, 12.5, sh.c_muted, inner, true) + 5.0
	# column heads, once, over the first option (each crop carries its own label too)
	var y := head_h
	var frames: Array = []
	var records: Array = []
	for o: Dictionary in OPTIONS:
		var oid := str(o["id"])
		sh.line(Vector2(MARGIN, y), Vector2(float(width) - MARGIN, y), sh.c_rule, 1.0)
		sh.text(Vector2(MARGIN, y + 20), "%s  ·  %s" % [o["letter"], o["title"]], 17.0, sh.c_text)
		sh.text(Vector2(MARGIN + 560.0, y + 20), "planner.fan.mode = %s" % o["mode"], 12.0, sh.c_muted, true)
		var ly := y + 30.0
		var tile := Image.create(int(cw) * cases.size(), int(line_h[0] + line_h[1] + line_h[2]), false, Image.FORMAT_RGBA8)
		var ty := 0
		for zi in ZOOMS.size():
			for ci in cases.size():
				var c: Dictionary = cases[ci]
				var img: Image = crops["%s/%s/%d" % [oid, str(c["id"]), zi]]
				var x := MARGIN + (cw + GAP) * float(ci)
				sh.text(Vector2(x, ly + 13.0), "%s  ·  %s" % [str(c["title"]), ZOOM_TEXT[zi]], 11.0, sh.c_muted, true)
				sh.image(img, Vector2(x, ly + 20.0))
				tile.blit_rect(img, Rect2i(0, 0, img.get_width(), img.get_height()), Vector2i(ci * int(cw), ty))
				var f := "%s_%s_z%s.png" % [oid, str(c["id"]), str(ZOOMS[zi])]
				_save(img, base.path_join(f))
				frames.append({"file": f, "option": o["letter"], "look": o["mode"], "unit": c["id"], "zoom": ZOOMS[zi],
					"title": "%s  ·  %s  ·  %s" % [o["letter"], c["title"], ZOOM_TEXT[zi]], "caption": "%s: %s, %s, 1:1 crop of the game's own frame, the fan's apex at (%d, %d)" % [o["title"], c["title"], ZOOM_TEXT[zi], CROP_APEX[zi].x, CROP_APEX[zi].y],
					"size": [img.get_width(), img.get_height()]})
			ly += line_h[zi] + 24.0
			ty += int(line_h[zi])
		sh.paragraph(Vector2(MARGIN, ly + 2.0), _option_line(o), 12.0, sh.c_muted, inner, true)
		y += opt_h
		_save(tile, base.path_join(oid + ".png"))
		records.append(_record(o))
	# the cone wash
	sh.line(Vector2(MARGIN, y), Vector2(float(width) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 22), "How each look sits in the cone wash (the light fighter, zoom 1, its weapon cones on)", 16.0, sh.c_text)
	sh.paragraph(Vector2(MARGIN, y + 30), "The wash is the unit's own side colour (side_a, brick red, 7 to 30%) and lies under the fan in the game. Every fan look is ink, so the two never mix: the fan is dark linework or tone on top of a red tint, never a second colour.", 12.0, sh.c_muted, inner, true)
	var cy := y + 70.0
	for i in OPTIONS.size():
		var o2: Dictionary = OPTIONS[i]
		var col := i % cases.size()
		var row := i / cases.size()
		var x := MARGIN + (cw + GAP) * float(col)
		var yy := cy + (float(CROP_SIZE[0].y) + 26.0) * float(row)
		var im: Image = cone_crops[str(o2["id"])]
		sh.text(Vector2(x, yy + 13.0), "%s  ·  %s" % [o2["letter"], o2["title"]], 11.0, sh.c_muted, true)
		sh.image(im, Vector2(x, yy + 20.0))
		var f2 := "%s_light_cones_z1.0.png" % str(o2["id"])
		_save(im, base.path_join(f2))
		frames.append({"file": f2, "option": o2["letter"], "look": o2["mode"], "unit": "light", "zoom": 1.0, "title": "%s  ·  light fighter with its cone wash" % o2["letter"],
			"caption": "%s: the light fighter's fan in its weapon-cone wash, zoom 1" % o2["title"], "size": [im.get_width(), im.get_height()]})
	y += cone_h
	# the ship as the game draws it today
	sh.line(Vector2(MARGIN, y), Vector2(float(width) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 22), "The cruiser as the game draws it today: the fan is under the hull", 16.0, sh.c_text)
	sh.paragraph(Vector2(MARGIN, y + 30), "The marker layer draws the ship at 4 px per metre (the planes' own scale, twice the map's 2 px per metre at zoom 1) and over the planner; the fan is the map's scale. The cruiser's next step is 30 m long and its region about 5 m across and 5 m deep (64 px out and 10 px deep at zoom 1, 22 px out and 4 deep at 0.35: 54 and 7 px2), all of it inside a hull 490 px long at zoom 1. Whatever the look, nothing of it shows (the ghost of the next node, the pale hull to the left, is the only mark). The ship crops above are drawn with the planner raised over the hull to show the fan at all; raising it in the game is a change this board does not make.", 12.0, sh.c_muted, inner, true)
	var hy2 := y + 100.0
	var hx := MARGIN
	for key: String in ["a_ribs/0", "b_shade/0", "a_ribs/1", "b_shade/1"]:
		var im2: Image = hidden_crops[key]
		var parts := key.split("/")
		var zi2 := int(parts[1])
		var oo := _option(parts[0])
		if hx + float(im2.get_width()) > float(width) - MARGIN + 1.0:
			hx = MARGIN
			hy2 += float(CROP_SIZE[0].y) + 20.0
		sh.text(Vector2(hx, hy2 + 13.0), "the cruiser as drawn today  ·  look %s (%s)  ·  %s" % [str(oo["letter"]), str(oo["mode"]), ZOOM_TEXT[zi2]], 11.0, sh.c_muted, true)
		sh.image(im2, Vector2(hx, hy2 + 20.0))
		var f3 := "cruiser_hidden_%s_z%s.png" % [str(oo["id"]), str(ZOOMS[zi2])]
		_save(im2, base.path_join(f3))
		frames.append({"file": f3, "option": oo["letter"], "look": oo["mode"], "unit": "cruiser", "zoom": ZOOMS[zi2], "title": "the cruiser as drawn today (planner under the hull)",
			"caption": "The cruiser with the planner under the marker layer, as the game draws it: the fan is hidden by the hull", "size": [im2.get_width(), im2.get_height()]})
		hx += cw + GAP
	y += hid_h
	_palette_strip(sh, Vector2(MARGIN, y), inner)
	for cid: String in contexts:
		var f4 := "context_%s_z0.35.png" % cid
		_save(contexts[cid], base.path_join(f4))
		frames.append({"file": f4, "option": "A", "look": "ribs", "unit": cid, "zoom": 0.35, "title": "context: %s, today's look, the whole frame" % cid,
			"caption": "The whole 1280 x 720 frame: the selected unit, its plan, its ghosts and speed labels, its ribbon trail, today's fan", "size": [1280, 720]})
	var err: int = await sh.save(self, base.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[motion-range-board] could not write board.png: ", error_string(err))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), width, height])
	_write_json(base.path_join("board.json"), records)
	_write_frames(base.path_join("frames.json"), frames)

func _option(oid: String) -> Dictionary:
	for o: Dictionary in OPTIONS:
		if str(o["id"]) == oid:
			return o
	return {}

func _save(img: Image, path: String) -> void:
	var err := img.save_png(path)
	if err != OK:
		failures += 1
		printerr("[motion-range-board] could not write ", path, ": ", error_string(err))

func _head_lines() -> Array:
	var f: Dictionary = measured.get("light/0", {})
	var f1: Dictionary = measured.get("light/1", {})
	var b: Dictionary = measured.get("bomber/0", {})
	var b1: Dictionary = measured.get("bomber/1", {})
	var t: Dictionary = measured.get("tank/0", {})
	var t1: Dictionary = measured.get("tank/1", {})
	var s: Dictionary = measured.get("cruiser/0", {})
	var s1: Dictionary = measured.get("cruiser/1", {})
	var cut_t := 100 - int(round(float(t.get("share_left", 1.0)) * 100.0))
	var cut_s := 100 - int(round(float(s.get("share_left", 1.0)) * 100.0))
	return [
		"Alex (2026-10-11): \"I want to look at the design of the 'acceptable range of motion' indicator for planes. Is there a style that makes more sense across all unit types? Should we just have a little shaded area where you can set the node? Show me some options before commiting this.\"",
		"The indicator is the planner's fan: the region where the NEXT step's node may be set. Rows are looks, columns are units, so one look can be read straight down across a light fighter, the bomber, a tank (on the village road, 33 m from the bridge's middle: the river takes %d%% of its region) and the cruiser (beside the east coast: the shore takes %d%%). Three lines per look: zoom 1 (2 px per metre), the start zoom 0.35 and a zoomed-out 0.2. Every unit has flown two real turns (its ribbon trail is the game's), has one or two steps planned and is selected, so its plan line, ghosts and speed labels are up. All crops are 1:1 from the game's own frames; only planner.fan.mode changes between looks." % [cut_t, cut_s],
		"WHAT THE REGION IS (screen px, zoom 1 / zoom 0.35): the light fighter's is an arc %s px out and %s px deep, %s / %s px2 in area; the bomber's %s px out, %s deep, %s / %s px2; the tank's a wedge %s px out and %s deep, %s / %s px2; the cruiser's %s px out and %s deep, %s / %s px2. A step is a second for a fighter and its speed can change by only 4 to 5 m/s, so its region is a thin arc, not a fan; a tank pivots 75 degrees a step but covers 20 m; a cruiser turns 9 degrees and covers 30 m. Today's spokes and ribs are most of the ink; the region itself is the little arc." % [
			str(f.get("reach_px", "?")), str(f.get("depth_px", "?")), str(f.get("area_px2", "?")), str(f1.get("area_px2", "?")),
			str(b.get("reach_px", "?")), str(b.get("depth_px", "?")), str(b.get("area_px2", "?")), str(b1.get("area_px2", "?")),
			str(t.get("reach_px", "?")), str(t.get("depth_px", "?")), str(t.get("area_px2", "?")), str(t1.get("area_px2", "?")),
			str(s.get("reach_px", "?")), str(s.get("depth_px", "?")), str(s.get("area_px2", "?")), str(s1.get("area_px2", "?"))],
		"WHAT NO LOOK CAN FIX: the region is as small as it is. At zoom 0.35 the fighter's is a 3 by 24 px streak, the tank's about 15 px across and the cruiser's about 7 px2; and under today's draw order the cruiser's is under its own hull (the foot of the sheet; the ship crops above are drawn with the planner raised over the hull). Every look is a way to mark a very small shape, and the question is which one still reads on all four. Every option is PROPOSED by builder BM and nothing is chosen. The drawing is one switch in data/ui/ui.json (planner.fan.mode; the default, ribs, is today's look).",
		"PROPOSED READING: " + _recommendation(),
	]

# What an option is, in words, with its numbers read from the data (so the sheet cannot drift from ui.json).
func _pct(role: String) -> int:
	return int(round(style.color(role).a * 100.0))

func _option_line(o: Dictionary) -> String:
	match str(o["mode"]):
		"ribs":
			return "The game as it is: an inked outline (%d%%, %.1f px), a faint wash inside it (%d%%), a rib across the band for each sampled turn and two dashed spokes back to the apex." % [_pct("fan_line"), style.num("planner.fan_line_px"), _pct("fan_fill")]
		"shade":
			return "Just the region, flat ink at %d%%: no outline, no ribs, no spokes. The node is set 'in the shade'. Alex's own idea. The tone is raised from today's wash (%d%%) because with no outline the tone alone has to show the edge." % [_pct("fan_shade"), _pct("fan_fill")]
		"wash_rim":
			return "A wash (%d%%) under one thin rim (%.1f px at %d%%): the shaded area with its edge said once, in the line's own weight. No ribs, no spokes." % [_pct("fan_wash"), style.num("planner.fan.wash_rim.rim_px"), _pct("fan_rim")]
		"stipple":
			return "Ink dots (%d%%, %.1f px) on a jittered grid (%.1f px cells) inside the region, no outline at all: the map's own grain and the cone board's stipple. The edge is where the dots stop." % [_pct("fan_dot"), style.num("planner.fan.stipple.dot_px") * 2.0, style.num("planner.fan.stipple.cell_px")]
		"hatch":
			return "%d degree ink strokes (%d%%, %.1f px) %.1f px apart, cut to the region, no outline: the map's hachures. On a band this thin it reads as a ladder." % [int(style.num("planner.fan.hatch.angle_deg")), _pct("fan_hatch"), style.num("planner.fan.hatch.line_px"), style.num("planner.fan.hatch.spacing_px")]
		"rim_ticks":
			return "A quiet rim (%.1f px at %d%%) and a faint ruler from the apex along the centre (%d%%), with a bar across it at the slowest reach (the near edge) and at the fastest (the far edge): as the cone board's outline look carries range ticks. No fill." % [style.num("planner.fan.rim_ticks.rim_px"), _pct("fan_rim_quiet"), _pct("fan_centre")]
	return ""

func _record(o: Dictionary) -> Dictionary:
	var params := {}
	var d: Variant = style.ui["planner"]["fan"].get(str(o["mode"]))
	if d is Dictionary:
		var cp: Dictionary = (d as Dictionary).duplicate(true)
		for k: String in cp.keys():
			if k.begins_with("_"):
				cp.erase(k)
		params[str(o["mode"])] = cp
	elif str(o["mode"]) == "ribs":
		params["ribs"] = {"planner.fan_line_px": style.num("planner.fan_line_px"), "planner.rib_line_px": style.num("planner.rib_line_px"), "roles": ["fan_fill", "fan_line", "fan_rib"]}
	return {
		"name": o["letter"],
		"title": o["title"],
		"planner.fan.mode": o["mode"],
		"description": _option_line(o),
		"file": str(o["id"]) + ".png",
		"proposed": true,
		"parameters": params,
	}

func _write_json(path: String, records: Array) -> void:
	var paper: Color = style.palette["paper"]
	var ink: Color = style.palette["ink"]
	var roles := ["fan_fill", "fan_line", "fan_rib", "fan_shade", "fan_wash", "fan_rim", "fan_dot", "fan_hatch", "fan_rim_quiet", "fan_centre", "fan_tick"]
	var lum := {}
	for r: String in roles:
		lum[r] = {"alpha": snappedf(style.color(r).a, 0.01), "over_paper": BoardSheet.oklch_text(BoardSheet.over(style.color(r), paper))}
	var doc := {
		"id": "motion-range",
		"date": "2026-10-11",
		"area": "UI",
		"question": "How is the range of motion (the fan: where the next step's node may be set) drawn, so that one style reads across every unit type? Alex: 'I want to look at the design of the acceptable range of motion indicator for planes. Is there a style that makes more sense across all unit types? Should we just have a little shaded area where you can set the node? Show me some options before commiting this.'",
		"source": "scripts/ui/boards/motion_range_board_shot.gd: the running sandbox (scripts/app/sandbox.gd) over the real map, scenario variants/motion-range/scenario.json (seed 20261009, water on, fog off), the game's own planner (scripts/ui/motion_planner.gd _draw_fan), photographed once per option with ONLY data/ui/ui.json planner.fan.mode changed",
		"seed": SEED,
		"held_constant": {
			"units": "a light fighter and the bomber over open ground, a tank on the village road, its next step starting 33 m from the bridge's middle (it stands 53 m from it, one step planned), the cruiser beside the east coast (3594, 1300) heading west; all of one side (side_a, brick red), each flown two real turns so its ribbon is the game's, one or two steps planned, the unit selected; the next step's fan is up with the plan line, ghosts and speed labels",
			"zooms": {"zoom_1": "camera zoom 1.0, 2 px/m", "start_zoom": "camera zoom 0.35 (data/view/camera.json zoom.start)", "zoomed_out": "camera zoom 0.2"},
			"crop_apex": "the fan's apex (the last planned step, or the unit) falls at the same pixel in every crop of a zoom: (320, 85), (150, 55), (130, 40); the crops of 0.35 and 0.2 put it nearer the left so the planes and the start of their ribbon are in",
			"cone_wash": "OFF in the grid (planner.cones.shown is another session's; the weapon-arcs button), shown once for the light fighter",
			"fog": "off in this rig (scenario view.fog false), so every crop shows the drawn map",
			"ship_rig": "the cruiser's crops are drawn with the planner raised above the marker layer, because today the hull covers the fan (shown separately); a rig action, not a game change",
			"decisions_in_force": "shadow strength 0.44; pen 'shadow_side'; side colours brick red (allies) and slate blue (axis); the ribbon trail (wingtip-trails D, all moving units); cones as a colour wash for the selected unit; planes at their own scale",
		},
		"measured": measured,
		"parameter": "data/ui/ui.json#planner.fan.mode (ribs | shade | wash_rim | stipple | hatch | rim_ticks) and planner.fan.<mode> for each one's numbers and colour roles (roles fan_shade, fan_wash, fan_rim, fan_dot, fan_hatch, fan_rim_quiet, fan_centre, fan_tick in ui.json roles)",
		"options": records,
		"palette_check": {
			"hue": "No option adds a hue: every fan mark is INK (L %.3f) at an alpha, over PAPER (L %.3f). The roles, with the lightness each gives over the paper, are in `roles`. The unit's side accent appears only in the cone wash under the fan (side_a at 7 to 30%%) and in the ribbon, never in the fan." % [BoardSheet.oklch(ink).x, BoardSheet.oklch(paper).x],
			"lightness": "A ramp off the paper: wash %d%%, today's wash %d%%, centre line %d%%, shade %d%%, rim %d to %d%%, hatch %d%%, dots %d%%, ticks %d%% (today's rim is %d%% and its ribs %d%%)." % [_pct("fan_wash"), _pct("fan_fill"), _pct("fan_centre"), _pct("fan_shade"), _pct("fan_rim_quiet"), _pct("fan_rim"), _pct("fan_hatch"), _pct("fan_dot"), _pct("fan_tick"), _pct("fan_line"), _pct("fan_rib")],
			"material": "linework: a rim, ticks, hatch strokes, dots; or a wash. No new colour, no hex in draw code (roles in data).",
		},
		"roles": lum,
		"recommendation_proposed": _recommendation(),
		"how_to_switch": "set planner.fan.mode in data/ui/ui.json to the option's mode; nothing else changes",
		"sheet": "board.png (rows A-F, columns: light fighter | bomber | tank | cruiser, three zoom lines each; the cone wash and the cruiser-today sections and a palette strip below)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[motion-range-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)

func _recommendation() -> String:
	return "C, a wash under one thin rim, no ribs and no spokes, for every unit type (PROPOSED by builder BM; Alex decides). The region is a thin arc for the planes, a small wedge for the tank and a speck for the cruiser, and the ribs and spokes are most of today's ink, so Alex's instinct is right that they are not what tells a player where a node can go. But a tone alone (B) is the first thing to vanish where the region is smallest and the ground busiest (the fighter's is a 3 by 24 px streak at the start zoom, over trees), so one thin rim keeps it findable: C is the same two marks on every unit at every zoom, in ink only. D and E break up on a 9 px band (a dotted line, a ladder). F is the quietest and the only look that says the slowest and the fastest reach, so it is the one to keep in mind if Alex wants the extent shown. None of them fixes the cruiser: its region is under its own hull today."

func _write_frames(path: String, frames: Array) -> void:
	var doc := {
		"id": "motion-range",
		"about": "Every frame of the range-of-motion board as its own PNG at native size: <option>_<unit>_z<zoom>.png are 1:1 crops of the game's frames (380 px wide; the fan's apex at the same pixel in every crop of a zoom), *_light_cones_z1.0.png the light fighter with its cone wash, cruiser_hidden_* the cruiser as the game draws it today, context_<unit>_z0.35.png whole 1280 x 720 frames. board.png is the sheet.",
		"frames": frames,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()

# --- the palette strip (working rule 6: every art choice includes the palette) -----------------------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette, and what the fan spends of it", 16.0, sh.c_text)
	var paper: Color = style.palette["paper"]
	var chips := [
		["paper", paper],
		["ink", style.palette["ink"]],
		["side_a (cone wash, ribbon)", style.palette["side_a"]],
		["A  fan_fill %d%%" % _pct("fan_fill"), style.color("fan_fill")],
		["A  fan_rib %d%%" % _pct("fan_rib"), style.color("fan_rib")],
		["A  fan_line %d%%" % _pct("fan_line"), style.color("fan_line")],
		["B  fan_shade %d%%" % _pct("fan_shade"), style.color("fan_shade")],
		["C  fan_wash %d%%" % _pct("fan_wash"), style.color("fan_wash")],
		["C  fan_rim %d%%" % _pct("fan_rim"), style.color("fan_rim")],
		["D  fan_dot %d%%" % _pct("fan_dot"), style.color("fan_dot")],
		["E  fan_hatch %d%%" % _pct("fan_hatch"), style.color("fan_hatch")],
		["F  fan_rim_quiet %d%%" % _pct("fan_rim_quiet"), style.color("fan_rim_quiet")],
		["F  fan_centre %d%%" % _pct("fan_centre"), style.color("fan_centre")],
		["F  fan_tick %d%%" % _pct("fan_tick"), style.color("fan_tick")],
	]
	var x := pos.x
	var yy := pos.y + 40.0
	for i in chips.size():
		var c: Array = chips[i]
		var col: Color = c[1]
		var shown := BoardSheet.over(col, paper) if col.a < 0.999 else col
		sh.chip(Vector2(x, yy), shown, str(c[0]), BoardSheet.oklch_text(shown), Vector2(86, 36))
		x += 168.0
		if x + 168.0 > pos.x + width:
			x = pos.x
			yy += 100.0
	var ty := yy + 110.0
	var ink_l: float = BoardSheet.oklch(style.palette["ink"]).x
	var paper_l: float = BoardSheet.oklch(paper).x
	var lines := [
		"Hue stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md). Every look here is INK (L %.3f) at an alpha laid over the PAPER (L %.3f): the fan never takes a side colour, so on top of the cone wash (side_a) it stays a dark mark on a tint and never a second hue. Each chip is the role laid over the paper (the lightness printed under it is of that composite)." % [ink_l, paper_l],
		"Lightness is a ramp off the paper: the region's own tone is %d to %d%% ink (today's wash and C's, then B's shade), the edge %d to %d%% (F, C), the strokes and dots %d to %d%% (E, D), the ticks %d%% (F). Today's rim is %d%% and its ribs %d%%; a look that drops the rim has to hold the edge by tone or texture alone, which is why B's shade (%d%%) is stronger than today's wash (%d%%)." % [_pct("fan_fill"), _pct("fan_shade"), _pct("fan_rim_quiet"), _pct("fan_rim"), _pct("fan_hatch"), _pct("fan_dot"), _pct("fan_tick"), _pct("fan_line"), _pct("fan_rib"), _pct("fan_shade"), _pct("fan_fill")],
		"Material is linework: a rim, ticks, hatch strokes, dots; or a wash (B, C). Each is the map's own material (the stipple is the cone board's and the ground's grain, the hatch the hachures), so the fan reads as part of the map and not as an overlay in a different language. No colour is written in draw code: every one is a role in data/ui/ui.json (roles fan_*).",
	]
	for l: String in lines:
		ty += sh.paragraph(Vector2(pos.x, ty), l, 12.0, sh.c_muted, width - 40.0, false, 3.0) + 5.0
