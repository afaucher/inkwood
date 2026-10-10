extends SceneTree

# BOARD: WINGTIP TRAILS (Track U1). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/trails_board_shot.gd -- [out=variants/wingtip-trails] [focus=lines]
#
# Alex (2026-10-10): "For locating the players planes, what about wingtip trails in the
# players color? That cover the past turn." The same harness, site and camera as
# variants/own-units-stand-out/ (seed 20261009, the running sandbox over the real map, the
# same three planes over the busy grove, zoom 1 and the far play zoom 0.35, fog on), so the
# two boards compare directly. Two real turns of history end at the same places as that
# board's planes: they are flown by two real World.resolve() calls (the weapons disarmed for
# the board, so nothing is shot down), and the trail node records them from
# World.turn_resolved, exactly as in a game. Only data/ui/ui.json marker.trails.mode changes between options. The
# sandbox's whole-flight track is OFF in the option frames (the board shows the trails
# alone), and ON in the frames that show how the two sit together.
#
# Per option: zoom 1 and the far play zoom, planning (the whole last turn), and one PLAYBACK
# frame (zoom 1, 2.5 s into turn 2: the rolling window reaches back 2.5 s into turn 1).
# Below: how it sits with the whole-flight track, with the selection ring and the cone wash,
# and the same trail on the ENEMY bomber, for comparison.
#
# EVERY OPTION AND VALUE IS PROPOSED by Track U1; none is a decision.

const World = preload("res://scripts/sim/world.gd")
const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const WingtipTrails = preload("res://scripts/ui/wingtip_trails.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")

const SEED := 20261009
const SITE_M := Vector2(3000.0, 3620.0)          # the own-units-stand-out board's site
const NEAR_CENTRE := Vector2(440.0, 330.0)       # its camera at zoom 1
const FAR_ZOOM := 0.35
const FAR_AT := Vector2(400.0, 346.0)            # the heavy fighter's place in the far frame: room behind it for the trail
const NEAR_CROP := Rect2(0.0, 150.0, 700.0, 330.0)
const FAR_CROP := Rect2(20.0, 181.0, 680.0, 330.0)
const PANEL_CROP := Rect2(0.0, 180.0, 690.0, 300.0)
const FAR_PANEL_CROP := Rect2(20.0, 196.0, 680.0, 300.0)
const ENEMY_CROP := Rect2(300.0, 240.0, 670.0, 300.0)
# The last two turns of each plane: a gentle constant turn per step (radians), so the paths curve.
const TURNS := {"light_fighter": 0.10, "heavy_fighter": -0.08, "bomber": 0.06}

const OPTIONS := [
	{"id": "a_today", "letter": "A", "mode": "none", "title": "Today", "line": "No trail. (The sandbox's whole-flight track is switched OFF in these frames; in the live game it is the thin side-colour line, drawn for every turn flown.) During playback the marker layer draws its own solid ink line of the track flown so far this turn, and a dashed one ahead."},
	{"id": "b_lines", "letter": "B", "mode": "lines", "title": "Two thin wingtip lines", "line": "One line from each drawn wingtip, solid, in the side colour, fading to nothing over the past turn. While a turn plays back the lines grow behind the plane and the marker layer's own solid ink line is not drawn (marker.trails.replaces_flown_line)."},
	{"id": "c_steps", "letter": "C", "mode": "steps", "title": "Lines broken at every step", "line": "The same, with a gap at each step's end, so the turn reads as its steps (five for a light fighter, four for the heavy, three for the bomber)."},
	{"id": "d_ribbon", "letter": "D", "mode": "ribbon", "title": "One ribbon between the wingtips", "line": "A soft band of the side colour between the two wingtip paths, a hairline on each edge, fading over the turn. The widest mark: the plane's whole swept width."},
	{"id": "e_rungs", "letter": "E", "mode": "rungs", "title": "Twin lines and a rung at each step end", "line": "Twin lines as B, and a short bar across the wingtips where each step ended: the plane's wing left behind, a ladder the turn climbed."},
	{"id": "f_wake", "letter": "F", "mode": "wake", "title": "A tapered wake (my own)", "line": "Proposed: the lines start at the wingtips and narrow and draw together toward the centre line as they age, like a wake or a contrail, fading out. It points back along the path and says which way the plane came."},
]

var out_dir := "variants/wingtip-trails"
var focus := "lines"
var scene: BoardScene = null
var style = null
var layer = null
var trails: WingtipTrails = null
var cones: ConeOverlay = null
var near_f: Dictionary = {}
var far_f: Dictionary = {}
var play_f: Dictionary = {}
var extra: Dictionary = {}          # name -> Image
var extra_rects: Dictionary = {}
var heavy_play_screen := Vector2.ZERO
var failures := 0
var _final: Dictionary = {}         # unit id -> Vector2 final position

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
		if kv.size() == 2 and kv[0] == "focus":
			focus = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[trails-board] ", msg)

func _run() -> void:
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed %d)..." % SEED)
	if not await scene.start():
		printerr("[trails-board] ", scene.errors)
		quit(1)
		return
	style = scene.style
	var ui = scene.sb.ui
	layer = ui.marker_layer
	ui.planner.visible = false
	var parent: Node = layer.get_parent()
	# The trails and the cones go in just under the markers (trails lowest).
	trails = WingtipTrails.new()
	parent.add_child(trails)
	parent.move_child(trails, layer.get_index())
	trails.setup(scene.world(), scene.sb.map_view, layer, style)
	trails.unit_visible = layer.unit_visible
	cones = ConeOverlay.new()
	parent.add_child(cones)
	parent.move_child(cones, layer.get_index())
	cones.setup(scene.world(), scene.sb.map_view, ui.selection, style)
	cones.unit_visible = layer.unit_visible
	cones.marker_layer = layer
	scene.sb.tracks.visible = false

	# --- two real turns of history, ending where the stand-out board's planes are ---------------
	var ppm: float = scene.sb.map_view.px_per_m
	var at := func(dx: float, dy: float) -> Vector2: return SITE_M + Vector2(dx, dy) / ppm
	_final = {scene.p_light: at.call(-235.0, -45.0), scene.p_heavy: at.call(0.0, 0.0), scene.bomber: at.call(165.0, 60.0)}
	var heads := {scene.p_light: 0.12, scene.p_heavy: 0.38, scene.bomber: -2.25}
	_fly_two_turns(heads)
	await scene.frames(4)
	var hp: Dictionary = scene.world().sample(scene.p_heavy, 2.5, "history")
	_say("history on the planes: heavy %d states; its mid-turn-2 place %s" % [(scene.world().units[scene.p_heavy].history as Array).size(), str(Vector2(float(hp["x"]), float(hp["y"])).round())])

	# --- zoom 1, planning -------------------------------------------------------------------------
	await scene.look(SITE_M, NEAR_CENTRE, 1.0)
	_say("zoom 1 baked in %.1f s" % await scene.settle())
	for o: Dictionary in OPTIONS:
		_mode(str(o["mode"]))
		await scene.frames(6)
		near_f[o["id"]] = await scene.grab()
		_say("%s (%s): near, %d trail records" % [o["letter"], o["mode"], trails.collect().size()])
	# Extras that want this view: the track on, the heavy selected with its cone wash, the enemy's.
	await _extras_near()

	# --- the far play zoom -------------------------------------------------------------------------
	await scene.look(_final[scene.p_heavy], FAR_AT, FAR_ZOOM)
	_say("far view settled in %.1f s" % await scene.settle())
	for o: Dictionary in OPTIONS:
		_mode(str(o["mode"]))
		await scene.frames(6)
		far_f[o["id"]] = await scene.grab()
	_mode("none")
	scene.sb.tracks.visible = true
	await scene.frames(4)
	extra["far_track_none"] = await scene.grab()
	_mode(focus)
	await scene.frames(6)
	extra["far_track_focus"] = await scene.grab()
	scene.sb.tracks.visible = false
	_mode("none")

	# --- a playback frame: 2.5 s into turn 2 ---------------------------------------------------------
	await scene.look(Vector2(float(hp["x"]), float(hp["y"])), NEAR_CENTRE, 1.0)
	layer.playback_paused = true
	layer.start_playback(2)
	layer.set_playback_time(2.5)
	_say("playback view baked in %.1f s" % await scene.settle())
	layer.set_playback_time(2.5)
	for o: Dictionary in OPTIONS:
		_mode(str(o["mode"]))
		await scene.frames(6)
		play_f[o["id"]] = await scene.grab()
		_say("%s (%s): playback frame (trail records %d)" % [o["letter"], o["mode"], trails.collect().size()])
	layer.stop_playback()
	_mode("none")

	await _write()
	scene.shutdown()
	quit(1 if failures > 0 else 0)

func _mode(m: String) -> void:
	style.ui["marker"]["trails"]["mode"] = m

# --- the history -------------------------------------------------------------------------------------

# One planned turn flown from a spot at heading 0 in a World of its own: where it ends and how
# far it turned. (The envelope is the same everywhere but for rotation, so the board can work
# out where a plane must START for its second turn to end at a given place and heading.)
func _probe(type_id: String, turn: float) -> Dictionary:
	var pw := World.new()
	pw.add_player("probe")
	var o := Vector2(2500.0, 2500.0)
	pw.add_unit({"id": "q", "type": type_id, "side": "allies", "controller": "player", "x": o.x, "y": o.y, "heading": 0.0})
	for k in pw.steps_per_turn("q"):
		pw.plan_step("q", k, {"turn": turn})
	pw.commit("probe")
	pw.resolve()
	var hist: Array = pw.units["q"].history
	var last: Dictionary = hist[hist.size() - 1]
	return {"d": Vector2(float(last["x"]), float(last["y"])) - o, "dh": angle_difference(0.0, float(last["heading"]))}

# Flies turn 1 then turn 2 for every plane, by real resolves, so that turn 2 ends at the plane's
# final place and heading. The trail node and the sandbox's track record both as they resolve.
func _fly_two_turns(heads: Dictionary) -> void:
	var w = scene.world()
	var starts := {}
	for id: String in _final:
		var u = w.units[id]
		var turn: float = float(TURNS[str(u.type)])
		var pr := _probe(str(u.type), turn)
		var h2: float = float(heads[id]) - float(pr["dh"])
		var e1: Vector2 = (_final[id] as Vector2) - (pr["d"] as Vector2).rotated(h2)
		var h1: float = h2 - float(pr["dh"])
		starts[id] = {"pos": e1 - (pr["d"] as Vector2).rotated(h1), "h": h1, "turn": turn}
	# Disarmed: the bomber ends within range of the fighters, and nothing here is about the fight.
	var armed := {}
	for id: String in _final:
		var d = w.units[id].def
		armed[id] = d.weapons.duplicate()
		d.weapons.clear()
	layer.playback_paused = true
	for turn_no in [1, 2]:
		for id: String in _final:
			var u = w.units[id]
			if turn_no == 1:
				u.x = (starts[id]["pos"] as Vector2).x
				u.y = (starts[id]["pos"] as Vector2).y
				u.heading = float(starts[id]["h"])
			w.clear_plan(id)
			for k in w.steps_per_turn(id):
				w.plan_step(id, k, {"turn": float(starts[id]["turn"])})
		w.commit("local")
		w.commit(World.AI_PLAYER)
		var res: Dictionary = w.resolve()
		if res.is_empty():
			failures += 1
			printerr("[trails-board] turn %d did not resolve: %s" % [turn_no, w.last_error])
		layer.stop_playback()
		w.begin_turn()
	for id: String in _final:
		(w.units[id].def.weapons as Array).append_array(armed[id])
		var u = w.units[id]
		var err := Vector2(float(u.x), float(u.y)).distance_to(_final[id])
		if err > 0.5:
			failures += 1
			printerr("[trails-board] %s ends %.2f m from its place" % [id, err])
	_say("two turns resolved and recorded; every plane ends at its place (turn %d to plan)" % w.turn)

# --- frames for how it sits ---------------------------------------------------------------------------

func _extras_near() -> void:
	var ui = scene.sb.ui
	# The whole-flight track on, today and with the focus trail.
	scene.sb.tracks.visible = true
	_mode("none")
	await scene.frames(5)
	extra["track_none"] = await scene.grab()
	_mode(focus)
	await scene.frames(6)
	extra["track_focus"] = await scene.grab()
	scene.sb.tracks.visible = false
	# The heavy selected: ring, health arc, the cone wash (Alex's pick), with and without the trail.
	ui.selection.select(scene.p_heavy)
	_mode("none")
	await scene.frames(8)
	extra["sel_none"] = await scene.grab()
	_mode(focus)
	await scene.frames(8)
	extra["sel_focus"] = await scene.grab()
	ui.selection.clear()
	# The same trail on the enemy bomber too, in its colour.
	style.ui["marker"]["trails"]["applies_to"] = "all"
	await scene.frames(6)
	extra["enemy"] = await scene.grab()
	style.ui["marker"]["trails"]["applies_to"] = "own"
	_mode("none")
	await scene.frames(4)

# --- the sheet -------------------------------------------------------------------------------------------

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var margin := 22.0
	var gap := 14.0
	var w := int(margin * 2.0 + NEAR_CROP.size.x + FAR_CROP.size.x + gap)
	var head_h := 214.0
	var row_h := NEAR_CROP.size.y + 56.0
	var panel_h := PANEL_CROP.size.y + 40.0
	var play_h := 70.0 + panel_h * 3.0
	var sit_h := 70.0 + panel_h * 4.0
	var pal_h := 470.0
	var h := int(head_h + row_h * float(OPTIONS.size()) + play_h + sit_h + pal_h)
	var sh := BoardSheet.new(style, Vector2i(w, h))
	sh.text(Vector2(margin, 34), "Wingtip trails  ·  seed %d, the running sandbox, the own-units-stand-out board's site and camera" % SEED, 25.0, sh.c_text)
	var hy := 46.0
	for l: String in [
		"Alex (2026-10-10): \"For locating the players planes, what about wingtip trails in the players color? That cover the past turn.\" The same three planes over the same grove as variants/own-units-stand-out/ (zoom 1 and the far play zoom 0.35, fog on, the sandbox's whole-flight track OFF here); only marker.trails.mode changes.",
		"Each wingtip's line starts AT the drawn wingtip (the wing outline's half-span x the plane's drawn scale, so it sits on the wingtip at every zoom: the far-zoom plane is 14 px wide and its lines are 14 px apart) and follows the history of the last resolved turn, in the unit's side accent, fading to nothing over the turn. Two real turns of history end where the other board's planes stand; the light fighter flew 500 m in the last one (1,000 px at zoom 1), so at zoom 1 the lines run off the crop. The right-hand frames show it whole.",
		"Left: zoom 1 (a light fighter is 36 px). Right: the far play zoom (14 px); the fog edge is 560 px east of the heavy fighter, out of this crop. Below: one frame of a turn PLAYING BACK (the window rolls: its tail is the end of the turn before), then how a trail sits with the whole-flight track, the selection ring and the cone wash, and the same trail on the enemy.",
		"Every option is PROPOSED by Track U1; nothing is chosen. Crops are 1:1 from the game's own frames.",
	]:
		hy += sh.paragraph(Vector2(margin, hy), l, 12.5, sh.c_muted, float(w) - margin * 2.0, true) + 3.0
	var y := head_h
	var records: Array = []
	for o: Dictionary in OPTIONS:
		var id: String = o["id"]
		sh.text(Vector2(margin, y + 16), "%s  ·  %s" % [o["letter"], o["title"]], 17.0, sh.c_text)
		sh.text(Vector2(margin + 330, y + 16), _param_line(str(o["mode"])), 12.0, sh.c_muted, true)
		var iy := y + 24.0
		sh.image(near_f[id], Vector2(margin, iy), NEAR_CROP)
		sh.image(far_f[id], Vector2(margin + NEAR_CROP.size.x + gap, iy), FAR_CROP)
		sh.paragraph(Vector2(margin, iy + NEAR_CROP.size.y + 4.0), str(o["line"]), 12.0, sh.c_muted, float(w) - margin * 2.0, true)
		y += row_h
		var all := Image.create(1280, 2160, false, Image.FORMAT_RGBA8)
		all.blit_rect(near_f[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 0))
		all.blit_rect(far_f[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 720))
		all.blit_rect(play_f[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 1440))
		var err := all.save_png(base.path_join(id + ".png"))
		if err != OK:
			failures += 1
			printerr("[trails-board] could not write ", id, ".png: ", error_string(err))
		records.append(_record(o))
	# The playback frames.
	sh.line(Vector2(margin, y + 2.0), Vector2(float(w) - margin, y + 2.0), sh.c_rule, 1.0)
	sh.text(Vector2(margin, y + 26.0), "One frame of a turn playing back: 2.5 s into turn 2, zoom 1", 16.0, sh.c_text)
	sh.text(Vector2(margin + 520.0, y + 26.0), "the window rolls: the trail's far end is where the plane was 2.5 s into turn 1; the marker layer's own solid ink line (A) is dropped when a trail replaces it", 12.0, sh.c_muted, true)
	var py := y + 38.0
	for i in OPTIONS.size():
		var px := margin + float(i % 2) * (PANEL_CROP.size.x + gap)
		var pyy := py + float(i / 2) * panel_h
		sh.image(play_f[OPTIONS[i]["id"]], Vector2(px, pyy), PANEL_CROP)
		sh.text(Vector2(px, pyy + PANEL_CROP.size.y + 14.0), "%s · %s" % [OPTIONS[i]["letter"], OPTIONS[i]["title"]], 12.0, sh.c_muted)
	y += play_h
	# How it sits.
	var fo := _option(focus)
	sh.line(Vector2(margin, y + 2.0), Vector2(float(w) - margin, y + 2.0), sh.c_rule, 1.0)
	sh.text(Vector2(margin, y + 26.0), "How it sits with the rest (shown with %s · %s)" % [str(fo.get("letter", "?")), str(fo.get("title", focus))], 16.0, sh.c_text)
	var sy := y + 38.0
	var items := [
		["today: the whole-flight track on, no trail", "track_none", PANEL_CROP, 0, 0],
		["the same with the trail: three lines over the last turn (track, and one trail either side)", "track_focus", PANEL_CROP, 1, 0],
		["the heavy fighter selected today: ring, health arc, the cone wash behind its rear gunner", "sel_none", PANEL_CROP, 0, 1],
		["the same with the trail: the trail and the brick-red wash share the ground behind the plane", "sel_focus", PANEL_CROP, 1, 1],
		["far play zoom, the track on, no trail", "far_track_none", FAR_PANEL_CROP, 0, 2],
		["far play zoom, the track and the trail", "far_track_focus", FAR_PANEL_CROP, 1, 2],
		["the same trail on the ENEMY bomber too, in its colour (for comparison only: Alex asked for the players' planes)", "enemy", ENEMY_CROP, 0, 3],
	]
	for it: Array in items:
		var rc: Rect2 = it[2]
		var px2 := margin + float(it[3]) * (PANEL_CROP.size.x + gap)
		var py2 := sy + float(it[4]) * panel_h
		sh.image(extra[it[1]], Vector2(px2, py2), rc)
		sh.text(Vector2(px2, py2 + rc.size.y + 14.0), str(it[0]), 12.0, sh.c_muted)
	y += sit_h
	_palette_strip(sh, Vector2(margin, y + 10.0), float(w) - margin * 2.0)
	var err2: int = await sh.save(self, base.path_join("board.png"))
	if err2 != OK:
		failures += 1
		printerr("[trails-board] could not write board.png: ", error_string(err2))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), w, h])
	_write_json(base.path_join("board.json"), records)

func _option(mode: String) -> Dictionary:
	for o: Dictionary in OPTIONS:
		if o["mode"] == mode:
			return o
	return {}

func _param_line(mode: String) -> String:
	if mode == "none":
		return "marker.trails.mode = none (the data's default)"
	var d: Dictionary = style.ui["marker"]["trails"][mode]
	var parts := PackedStringArray()
	for k: String in d:
		if not k.begins_with("_"):
			parts.append("%s %s" % [k, str(d[k])])
	return "marker.trails.mode = %s  ·  %s" % [mode, "  ·  ".join(parts)]

func _record(o: Dictionary) -> Dictionary:
	var mode := str(o["mode"])
	var rec := {"name": o["letter"], "title": o["title"], "marker.trails.mode": mode, "file": o["id"] + ".png", "proposed": true}
	var params := {}
	if mode != "none":
		var d: Dictionary = (style.ui["marker"]["trails"][mode] as Dictionary).duplicate(true)
		for k: String in d.keys():
			if k.begins_with("_"):
				d.erase(k)
		params = d
	rec["parameters"] = params
	return rec

func _write_json(path: String, records: Array) -> void:
	var t: Dictionary = style.ui["marker"]["trails"]
	var common := {}
	for k: String in ["applies_to", "window_turns", "sample_s", "fade_power", "min_alpha", "replaces_flown_line"]:
		common[k] = t[k]
	var doc := {
		"id": "wingtip-trails",
		"date": "2026-10-10",
		"area": "Units, UI",
		"question": "Alex: 'For locating the players planes, what about wingtip trails in the players color? That cover the past turn.' How should the trails look?",
		"source": "scripts/ui/boards/trails_board_shot.gd: the running sandbox over the real map with scripts/ui/wingtip_trails.gd, photographed once per option with ONLY data/ui/ui.json marker.trails.mode changed; the same site, camera and planes as variants/own-units-stand-out/",
		"seed": SEED,
		"held_constant": {
			"scene": "the own-units-stand-out board's three planes (light fighter and heavy fighter player-controlled, bomber AI) over the grove at (3000, 3620) m, at the same places and headings; each flew two real turns ending there (a constant turn per step: light %s, heavy %s, bomber %s rad), by two World.resolve() calls with the weapons disarmed so nothing is shot down" % [str(TURNS["light_fighter"]), str(TURNS["heavy_fighter"]), str(TURNS["bomber"])],
			"views": {"zoom_1": "camera zoom 1.0, 2 px/m map scale (the light fighter 36 px)", "far_play_zoom": "camera zoom 0.35 (the light fighter 14 px); the fog edge is out of the crop", "playback": "zoom 1, 2.5 s into turn 2, playback held"},
			"decisions_in_force": "own-units-stand-out = A (today's marker); cones = D wash for the selected unit only, no enemy cones; shadow strength 0.44; pen shadow_side; side colours brick red (allies) and slate blue (axis); terrain with contours; planes at their own scale; fog with sight circles",
			"sandbox_tracks": "OFF in the option frames; ON in the 'how it sits' frames",
		},
		"parameter": "data/ui/ui.json#marker.trails.mode (and marker.trails.<mode>, and the common keys); 'none' is today's look and draws nothing",
		"common_parameters": common,
		"options": records,
		"focus_for_how_it_sits": focus,
		"palette_check": _palette_text(),
		"sheet": "board.png (rows A-F: zoom 1 | far play zoom; playback frames; how it sits; a palette strip)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[trails-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)

# --- the palette, measured ----------------------------------------------------------------------------------

func _palette_text() -> String:
	var m := _palette_numbers()
	return "The trail spends the side accent (side_a for the players: L 0.551, C 0.100, h 30; the same colour as the roundels, the roster marks and the brick-red cone wash). In OKLab distance (about 0.02 just noticeable, 0.1 plainly different): the trail at full alpha is %.2f from a contour line and %.2f from the plane's shadow over paper; at 45%% alpha it is %.2f from the paper, at 10%% %.2f (gone). The enemy's slate-blue trail is %.2f from the shadow-tinted ground at full alpha but %.2f at a third of it, so faded over a plane's shadow it drifts toward the shadow tint (a reason, besides Alex's, to keep trails to the players' planes)." % [m["trail_vs_contour"], m["trail_vs_shadow"], m["half_vs_paper"], m["tenth_vs_paper"], m["enemy_vs_shadow"], m["enemy_faded_vs_shadow"]]

func _palette_numbers() -> Dictionary:
	var paper: Color = style.palette["paper"]
	var ink: Color = style.palette["ink"]
	var sa: Color = style.palette["side_a"]
	var sb_: Color = style.palette["side_b"]
	var shadow: Color = style.palette["shadow"]
	var strength: float = style.param("shadow_strength")
	var shaded := BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, strength), paper)
	var contour := BoardSheet.over(Color(ink.r, ink.g, ink.b, 0.85), paper)
	return {
		"trail_vs_contour": BoardSheet.delta_ok(BoardSheet.over(Color(sa.r, sa.g, sa.b, 0.9), paper), contour),
		"trail_vs_shadow": BoardSheet.delta_ok(BoardSheet.over(Color(sa.r, sa.g, sa.b, 0.9), paper), shaded),
		"half_vs_paper": BoardSheet.delta_ok(BoardSheet.over(Color(sa.r, sa.g, sa.b, 0.45), paper), paper),
		"tenth_vs_paper": BoardSheet.delta_ok(BoardSheet.over(Color(sa.r, sa.g, sa.b, 0.10), paper), paper),
		"enemy_vs_shadow": BoardSheet.delta_ok(BoardSheet.over(Color(sb_.r, sb_.g, sb_.b, 0.9), shaded), shaded),
		"enemy_faded_vs_shadow": BoardSheet.delta_ok(BoardSheet.over(Color(sb_.r, sb_.g, sb_.b, 0.3), shaded), shaded),
	}

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette: what the trail spends, and what it must not be mistaken for", 16.0, sh.c_text)
	var paper: Color = style.palette["paper"]
	var ink: Color = style.palette["ink"]
	var sa: Color = style.palette["side_a"]
	var sb_: Color = style.palette["side_b"]
	var shadow: Color = style.palette["shadow"]
	var strength: float = style.param("shadow_strength")
	var shaded := BoardSheet.over(Color(shadow.r, shadow.g, shadow.b, strength), paper)
	var chips := [
		["paper", paper, ""],
		["contour line", BoardSheet.over(Color(ink.r, ink.g, ink.b, 0.85), paper), "ink @ 0.85 on paper"],
		["shadow over paper", shaded, "steel @ %.2f" % strength],
		["trail, at the plane", BoardSheet.over(Color(sa.r, sa.g, sa.b, 0.9), paper), "side_a @ 0.90"],
		["trail, half way", BoardSheet.over(Color(sa.r, sa.g, sa.b, 0.45), paper), "side_a @ 0.45"],
		["trail, near the end", BoardSheet.over(Color(sa.r, sa.g, sa.b, 0.10), paper), "side_a @ 0.10"],
		["cone wash, centre", BoardSheet.over(Color(sa.r, sa.g, sa.b, float(style.ui["planner"]["cones"]["wash"]["alpha_centre"])), paper), "side_a @ %.2f" % float(style.ui["planner"]["cones"]["wash"]["alpha_centre"])],
		["enemy trail on shadow", BoardSheet.over(Color(sb_.r, sb_.g, sb_.b, 0.9), shaded), "side_b @ 0.90"],
	]
	var x := pos.x
	var cy := pos.y + 40.0
	for c: Array in chips:
		sh.chip(Vector2(x, cy), c[1], str(c[0]), BoardSheet.oklch_text(c[1]), Vector2(74, 40))
		if str(c[2]) != "":
			sh.text(Vector2(x, cy + 40.0 + 42.0), str(c[2]), 11.0, sh.c_muted)
		x += 172.0
	var m := _palette_numbers()
	var lines := [
		"Hue stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md): the trail is the unit's own side accent at an alpha, nothing else; no new colour. For the players it is brick red, the colour of their roundels, their roster marks, their selection-ring badge and (Alex's pick) the cone wash.",
		"Against the terrain's lines: a contour is a thin ink-brown line (L 0.325 at full alpha, h 69); the trail is a mid red (L 0.55, h 30) and goes pale as it fades, so it never goes dark: OKLab distance from a contour line is %.2f at the plane. As it fades toward paper it loses chroma too: at half alpha it is %.2f from the paper, at a tenth %.2f, which is gone; it stops being drawn below marker.trails.min_alpha (0.03). A fading red line reads as terrain nowhere: terrain is dark and does not fade." % [m["trail_vs_contour"], m["half_vs_paper"], m["tenth_vs_paper"]],
		"Against the shadow tint: the steel-blue plane shadow (44%%) is %.2f from the red trail, a different hue and a different lightness. The enemy's slate blue is %.2f from that same shadowed ground at full alpha, %.2f at a third of it: an enemy trail is the one that fades toward a shadow, which is one more reason to keep trails to the players' planes." % [m["trail_vs_shadow"], m["enemy_vs_shadow"], m["enemy_faded_vs_shadow"]],
		"Against the cone wash and the selection ring: the wash is the same accent at 0.07 to 0.30 alpha as a fill; the trail is the same accent as thin lines. Where the rear gunner's cone lies over the trail (the selected-heavy frames) they are one colour at two weights and two textures; the trail is the thinner, brighter mark and sits under the cone. The ring and its leader are ink, as before.",
	]
	var yy := pos.y + 40.0 + 40.0 + 60.0
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width, false, 3.0) + 5.0
