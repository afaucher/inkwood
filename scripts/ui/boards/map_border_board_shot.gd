extends SceneTree

# BOARD: WHAT THE MAP SHOWS PAST ITS EDGE (builder, map-border board, 2026-10-11). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed --resolution 1280x720 `
#       --script res://scripts/ui/boards/map_border_board_shot.gd -- [out=variants/map-border] [options=none,A,B,C,D] [sheet=1]
#
# Alex (2026-10-11): "The secondary thing I wanted to do was look at a couple of art proposals for what to do for the area around the
# map when you zoom out. It is just a solid color right now. What are some treatments? Should we constrain the outer most zoom to a
# specific area? For treatments I was thinking of: The hatch edging onto a continued blank paper pattern. Clipped so you just see it
# as the border but not beyond." He then chose to keep the zoom-out limit at "whole map fits" and to STOP PANNING PAST THE MAP'S EDGE
# (decision pan-stops-at-edge): the view shows at most pan.edge_overscroll_m (100 m) past the edge at any zoom but the full zoom-out,
# where the whole map is centred and the strips beside it are wide.
#
# THE FOUR OPTIONS (all PROPOSED; scripts/render/map_border*.gd, data/view/map_border.json), each photographed in the REAL game --
# the Strike scenario as the Local button starts it (scripts/app/strike_shot.gd's start), seed 20261009, 1280 x 720, the roster
# sidebar up -- with MapView.border.set_option(letter), plus the current look ("none") as the reference:
#
#   A  hatched edge onto blank paper   B  printed map sheet   C  contours continue   D  sheet on a table
#
# THREE VIEWS of each (and a fourth, edge1_se, for the south-east corner: the sea's edge, where option D's shadow falls), the camera put where the clamp (CameraController.set_view) allows:
#   far      fully zoomed out: the whole map centred in the free area (the window less the sidebar), the topographic overview
#            (the fog on, the game as it is), the strips beside the map as wide as the window makes them
#   edge035  the planning zoom 0.35 pushed against the map's north-west corner: two edges show, 100 m of band each, the full render
#            beside them (trees and terrain within 250 m of both edges: the corner holds the most trees of the map's four)
#   edge1    zoom 1 at the same corner
# The two edge views are taken with the FOG OFF (the Sandbox's own switch): nobody's sight reaches that corner, so with it on they
# would show the topographic map there; off, they show the full render beside the border, as they do where a unit has sight.
# The key hint and the turn card are hidden for the photographs (they would sit over the band).
#
# Output (out=): frames/<option>_<view>.png (native 1280 x 720), frames.json (file, option, view, zoom, focus, caption per frame),
# board.json (id "map-border", the question, the options with their notes and numbers, the measured costs, and "chosen": Alex's pick, E; E's frames are frames/chosen_<view>.png), and
# board.png: a sheet of 1:1 crops of every frame, the notes, and a PALETTE STRIP of every role the options use beside paper, ink,
# the shadow tint, the two side accents and water.
#
# EVERYTHING IS PROPOSED; nothing here is a decision.

const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")

const SIZE := Vector2i(1280, 720)
const ALL_OPTIONS := ["none", "A", "B", "C", "D", "E"]
const VIEWS := [
	{"id": "far", "label": "fully zoomed out", "fog": true},
	{"id": "edge035", "label": "planning zoom 0.35 at the north-west corner", "fog": false},
	{"id": "edge1", "label": "zoom 1 at the north-west corner", "fog": false},
	{"id": "edge1_se", "label": "zoom 1 at the south-east corner (the sea's edge: the sheet's shadow of option D falls here)", "fog": false},
	{"id": "edge1_tick_n", "label": "zoom 1 against the north edge at the 500 m tick: the legend's number over the land", "fog": false, "only": "E"},
	{"id": "edge1_tick_e", "label": "zoom 1 against the east edge at the 2,500 m tick: the legend's number over the deep sea", "fog": false, "only": "E"},
]
# the crops of the sheet, 1:1: [view id, crop name, region of the 1280 x 720 frame, caption]
const CROPS := [
	["far", "far_tl", Rect2i(30, 0, 600, 330), "fully zoomed out, the map's north-west corner: the strip left of the map is 120 px wide"],
	["far", "far_bl", Rect2i(30, 390, 600, 330), "fully zoomed out, the south-west corner (B's scale bar; the strip left of the map)"],
	["edge035", "edge035_c", Rect2i(0, 0, 600, 330), "planning zoom 0.35 against the north-west corner: 70 px of band along each edge, the full render beside it"],
	["edge1", "edge1_c", Rect2i(0, 0, 600, 330), "zoom 1 at the same corner: the band is 200 px deep (100 m)"],
	["edge1_se", "edge1_se_c", Rect2i(300, 300, 600, 330), "zoom 1 at the south-east corner, where the Strike's sea meets the edge (and where D's lifted shadow falls)"],
]
const CROP_SIZE := Vector2i(600, 330)
const MARGIN := 24
const GAP := 14

var out_dir := "variants/map-border"
var only: Array = []
var make_sheet := true
var seed_value := 20261009
var base_dir := ""
var main: Node = null
var sb: Node = null
var ctl: Node = null
var border: Node2D = null
var style: UiStyle = null
var P: RenderParams = null
var frames: Array = []
var images: Dictionary = {}            # "<option>|<view>" -> Image
var measured: Dictionary = {}          # option -> {numbers}
var notes: Dictionary = {}             # option -> String
var failures := 0
var _t_start := 0
var _root_rid := RID()

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			match kv[0]:
				"out": out_dir = kv[1]
				"options": only = kv[1].split(",")
				"sheet": make_sheet = kv[1] != "0"
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[map-border-board] ", msg)

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _options() -> Array:
	var out: Array = []
	for o: String in ALL_OPTIONS:
		if only.is_empty() or only.has(o):
			out.append(o)
	return out

# --- the run --------------------------------------------------------------------------------------------

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[map-border-board] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(SIZE)
	root.size = SIZE
	await _frames(10)
	base_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base_dir.path_join("frames"))
	style = UiStyle.shared() as UiStyle
	P = RenderParams.new()
	_root_rid = root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_root_rid, true)
	_t_start = Time.get_ticks_msec()

	# the game, as the menu's Local button starts it: the Strike
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	var t0 := Time.get_ticks_msec()
	if not main.start_sandbox():
		printerr("[map-border-board] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	while not sb.is_playable and Time.get_ticks_msec() - t0 < 240000:
		await process_frame
	_say("the Strike is playable %.1f s after Local" % ((Time.get_ticks_msec() - t0) / 1000.0))
	if not sb.is_playable or sb.scenario.id != "strike":
		printerr("[map-border-board] the Strike did not start")
		quit(1)
		return
	ctl = sb.ctl
	border = sb.map_view.border
	var ppm: float = sb.map_view.px_per_m
	_say("viewport %s, free area %s, zoom limit %.4f, the band %.0f m = %.0f px at zoom 0.35 and %.0f px at zoom 1" % [
		str(root.get_viewport().get_visible_rect().size), str(ctl.free_size()), ctl.zoom_limit_min(), border.data.num("reach.band_m"),
		border.data.num("reach.band_m") * ppm * 0.35, border.data.num("reach.band_m") * ppm])
	await _wait_view()

	# pass 1: the fog on, fully zoomed out
	for opt: String in _options():
		await _switch(opt)
		await _take(opt, VIEWS[0])
	# pass 2: the fog off, the two edge views
	sb._set_fog(false)
	await _frames(3)
	for opt: String in _options():
		await _switch(opt)
		await _take(opt, VIEWS[1])
		await _take(opt, VIEWS[2])
		await _take(opt, VIEWS[3])
		for v: Dictionary in VIEWS:
			if str(v.get("only", "")) == opt:
				await _take(opt, v)   # (views taken for the chosen look alone: the legend's numbers at zoom 1)
	sb._set_fog(true)
	await _frames(3)
	await _switch("none")

	_write_notes()
	_write_frames_json()
	_write_board_json()
	if make_sheet:
		await _sheet()
	_say("done in %.0f s, %d failures" % [(Time.get_ticks_msec() - _t_start) / 1000.0, failures])
	main.stop_sandbox()
	quit(1 if failures > 0 else 0)

# Switches the option, waits for its bake, and records what that cost.
func _switch(opt: String) -> void:
	if border.option() == opt:
		return
	var t0 := Time.get_ticks_msec()
	var us0 := Time.get_ticks_usec()
	if not border.set_option(opt):
		failures += 1
		printerr("[map-border-board] set_option(%s) failed: %s" % [opt, str(border.errors)])
		return
	var build_ms := (Time.get_ticks_usec() - us0) / 1000.0
	await _frames(2)
	# the bake runs behind the paper, which is there at once; the planning zoom's level of detail first
	ctl.set_view(Vector2(-1.0e7, -1.0e7), 0.35)
	await _frames(2)
	var waited := 0
	while not border.is_ready() and Time.get_ticks_msec() - t0 < 300000:
		await process_frame
		waited += 1
	var bake_s := (Time.get_ticks_msec() - t0) / 1000.0
	var m: Dictionary = measured.get(opt, {})
	m["build_ms"] = snappedf(build_ms, 0.01)
	m["bake_s_to_ready"] = snappedf(bake_s, 0.1)
	m["border_stats_after_bake"] = _stats_plain(border.stats())
	measured[opt] = m
	_say("option %s on: built in %.1f ms, ready after %.1f s (%s)" % [opt, build_ms, bake_s, str(_stats_plain(border.stats()))])

func _stats_plain(s: Dictionary) -> Dictionary:
	var out := {}
	for k: String in s:
		var v: Variant = s[k]
		out[k] = snappedf(float(v), 0.01) if v is float else v
	return out

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(sb._fog_on) > 0 or _fog_busy() or not border.is_ready():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[map-border-board] the view is not complete after %.0f s" % max_s)
			failures += 1
			break
		await process_frame
	await _frames(12)

func _fog_busy() -> bool:
	if not sb._fog_on:
		return false
	var lod: int = sb.fog.topo.lod_for_zoom(ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _place(view: Dictionary) -> void:
	match str(view["id"]):
		"far":
			ctl.set_view(sb.terrain.map_rect_px().get_center(), 0.001)
		"edge035":
			ctl.set_view(Vector2(-1.0e7, -1.0e7), 0.35)
		"edge1":
			ctl.set_view(Vector2(-1.0e7, -1.0e7), 1.0)
		"edge1_se":
			ctl.set_view(Vector2(1.0e7, 1.0e7), 1.0)
		"edge1_tick_n":
			ctl.set_view(Vector2(500.0 * 2.0, -1.0e7), 1.0)
		"edge1_tick_e":
			ctl.set_view(Vector2(1.0e7, 2500.0 * 2.0), 1.0)

func _take(opt: String, view: Dictionary) -> void:
	_place(view)
	await _frames(3)
	await _wait_view()
	sb.hint.visible = false
	sb.clock.visible = false
	for lab: Node in main.find_children("*", "Label", true, false):
		if str((lab as Label).text).begins_with("dev ("):
			(lab as CanvasItem).visible = false   # the build stamp sits over the south-west margin
	await _frames(30)
	# GPU and CPU render time per frame, the median of 60 frames, for the cost line
	var gpu: Array = []
	var cpu: Array = []
	for _i in 60:
		await process_frame
		gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(_root_rid))
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(_root_rid))
	gpu.sort()
	cpu.sort()
	var gpu_med: float = gpu[30]
	var cpu_med: float = cpu[30]
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var file := _fname(opt, str(view["id"]))
	if img.save_png(base_dir.path_join(file)) != OK:
		failures += 1
		printerr("[map-border-board] could not write ", file)
	images["%s|%s" % [opt, view["id"]]] = img
	var m: Dictionary = measured.get(opt, {})
	m["gpu_ms_%s" % view["id"]] = snappedf(gpu_med, 0.01)
	m["render_cpu_ms_%s" % view["id"]] = snappedf(cpu_med, 0.01)
	measured[opt] = m
	var zoom: float = ctl.zoom_level()
	var focus: Vector2 = ctl.center() / float(sb.map_view.px_per_m)
	var title := "reference (none): the map's own edge" if opt == "none" else ("E  -  CHOSEN: %s" % border.option_name(opt) if opt == "E" else "%s  -  %s" % [opt, border.option_name(opt)])
	if view["id"] == "edge1_se":
		_check_sliver(opt)
	frames.append({"file": file, "option": opt, "view": view["id"], "zoom": snappedf(zoom, 0.0001), "focus_m": [snappedf(focus.x, 0.1), snappedf(focus.y, 0.1)],
		"fog": bool(view["fog"]), "chosen": opt == "E", "caption": "%s  -  %s (zoom %.3f)" % [title, view["label"], zoom], "size": [SIZE.x, SIZE.y]})
	_say("saved %s (zoom %.3f, gpu median %.2f ms, the border's own CPU per frame %s us)" % [file, zoom, gpu_med, str(border.stats().get("frame_us", 0))])

# --- the notes ---------------------------------------------------------------------------------------

# frames/<option>_<view>.png; the chosen look (E) is frames/chosen_<view>.png.
func _fname(opt: String, view_id: String) -> String:
	return "frames/%s_%s.png" % ["chosen" if opt == "E" else opt, view_id]

func _num(path: String) -> float:
	return border.data.num(path)

func _ints(a: Array) -> String:
	var parts := PackedStringArray()
	for v: Variant in a:
		parts.append(str(int(v)))
	return ", ".join(parts)

func _contour_t() -> float:
	return float(border.data.root["c"]["contour"]["role"]["value"].get("t", 0.0))

func _table_t() -> float:
	return float(border.data.root["d"]["table"]["role"]["value"].get("t", 0.0))

# The map's content past the 5,000 m bounds must be covered: reads the frame's pixel just beyond the south-east corner's edges.
func _check_sliver(opt: String) -> void:
	var img: Image = images["%s|edge1_se" % opt]
	var br: Vector2 = ctl.world_px_to_screen(sb.terrain.map_rect_px().end)
	var bluish := 0
	var total := 0
	var x0 := int(br.x) + 60
	for x in range(x0, mini(x0 + 100, 900)):
		for y in range(100, int(br.y) - 20, 7):
			var c := img.get_pixel(x, y)
			total += 1
			if c.b - c.r > 0.1:
				bluish += 1
	if opt == "none":
		_say("control, option none: %d of %d pixels of the strip 60 to 160 px past the map's south-east edge are sea-blue (the 120 m the chunks show past the bounds; must be above 0 or the check below proves nothing)" % [bluish, total])
		if bluish == 0:
			failures += 1
		return
	_say("option %s: %d of %d pixels of the strip 60 to 160 px past the map's south-east edge are sea-blue (the map's terrain beyond the 5,000 m bounds must be covered: 0)" % [opt, bluish, total])
	if bluish > 0:
		failures += 1

func _write_notes() -> void:
	var fog_line := float(sb.fog.fog_data.num("edge.inked.line_px"))
	notes["A"] = "PROPOSED. Alex's idea, built as he said it: blank paper continues past the edge (the map's own tint at world coordinates and its grain, no ink and no specks) and along the edge a band of ink hachures points outward, clipped to the band (reach.band_m = 100 m; on screen at most %d px deep). It is drawn by one shader in screen px, like the fog's inked edge, so a line keeps its width at every zoom; the hatch lines are perpendicular to the edge and fan out at the corners. HOW IT READS AS THE WORLD'S EDGE AND NOT THE FOG'S SIGHT EDGE (the fog's: a %.1f px line, hatching at 45 degrees, 4 px apart, 0.9 px wide, ink alpha 0.55, 26 px deep, inside the fog): this one is HEAVIER (a %.1f px edge line, hatch %.1f px wide at alpha %.2f), DENSER (%.0f px between lines), DEEPER (%.0f px), DOUBLED (a fine rule %.1f px outside the heavy line) and PERPENDICULAR to the edge. Nothing is baked: no memory, no bake time." % [
		int(_num("a.hatch.depth_px")), fog_line, _num("a.edge.line_px"), _num("a.hatch.width_px"), border.role("a.hatch.role").a, _num("a.hatch.spacing_px"), _num("a.hatch.depth_px"), _num("a.rule2.gap_px")]
	notes["B"] = "PROPOSED. Blank paper continues; at the edge a ruled neatline in the cards' double-rule language (a fine rule on the edge, a heavy one %.0f px outside it), a graticule tick every %.0f m with its number in metres in the label face (14 px, full ink, on the paper margin under the map's paper halo; a number that does not fit is left off: at the full zoom-out on a 720 px window the margin above and below the map is 20 px, so the numbers go on the left and right and the ticks stay), and, when the whole map is in view, a scale bar (the longest of %s m that fits the margin) and a north arrow in the margin (north is up: there is no rotation). Drawn in screen px by a screen-pinned node that repaints when the camera moves; nothing baked." % [
		_num("b.rule.gap_px"), _num("b.tick.spacing_m"), _ints(border.data.list("b.scale_bar.lengths_m"))]
	var cs: Dictionary = (measured.get("C", {}) as Dictionary).get("border_stats_after_bake", {})
	notes["C"] = "PROPOSED. Past the edge the terrain continues in the fog's topographic style -- contour lines, no trees, no level tones, no hachures -- in a fainter ink (the contour ink %.0f%% of the way to paper), and fades to blank paper by %.0f m out; the playable map keeps its full ink and ends at a thin %.1f px line. The contours are the fog's own drawing (FogTopo._add_offset) recorded for chunks outside the map on worker threads and baked ONCE per option into %d tiles of three levels of detail (%s texels a map px), %s MB of one-channel textures. Alex said \"contours only\", but open deep sea has no contours: without more, this seed's east edge (sea) would stop at the line with blank paper beyond it. So the sea's shore and depth steps go on as lines AND the sea goes on as the fog's own quiet wash (its three depth steps at topo.water.quiet, the water palette's colours; data c.wash.on, one switch: false is contours only), fading with the contours." % [
		_contour_t() * 100.0, _num("c.fade.to_m"), _num("c.edge.line_px"), int(cs.get("tiles", 0)), str(border.data.list("c.lods.texels_per_px")), "%.0f" % (float(cs.get("texture_bytes", 0)) / 1048576.0)]
	var em: Dictionary = measured.get("E", {})
	notes["E"] = "CHOSEN BY ALEX (2026-10-11: \"I like the hatches, with the distance legend\"); every number in it is still a PROPOSED record. A's hatched edge onto blank paper (the heavy %.1f px edge line, the fine rule, the perpendicular hatching clipped to the band, the paper going on) PLUS B's distance legend: a tick every %.0f m with its number in metres and, at the full zoom-out, the scale bar. NOT B's double-ruled neatline (A's heavy line and hatch are the edge) and NOT B's north arrow. WHERE THE NUMBERS SIT: INSIDE THE MAP, just inside the edge line, never on the hatching: each tick is a %.0f px stroke from the edge INWARD and its number stands %.0f px inside the tick's end, 14 px, full ink, on the map's paper halo (top edge: under its tick and centred; bottom edge: above; left edge: to the right; right edge: to the left). Outside the hatch band they would not fit: the view shows 70 px past the edge at zoom 0.35 and the hatching takes 56 of them, and at the full zoom-out the margin above and below the map is 14 to 20 px. The corners (0 and 5,000 m) are not numbered. A number that does not fit between its neighbours loses its \" m\" first, then goes (the ticks stay): at the full zoom-out on this window the spacing is 68 px, so all stay. The scale bar (the longest of %s m that fits left of the map, clear of the hatching) is at the bottom of that margin. Screen-pinned paint like B's, repainted when the camera moves; nothing baked." % [
		_num("a.edge.line_px"), _num("e.tick.spacing_m"), _num("e.tick.length_px"), _num("e.label.gap_px"), _ints(border.data.list("e.scale_bar.lengths_m"))]
	notes["D"] = "PROPOSED. The map is a sheet of paper with a slightly ragged deckle edge (the table's colour bitten into the map's edge by %.0f m of two-octave noise) and a thin pale lip, lying on a darker table; the sheet's lifted shadow is its silhouette moved %.0f m away from the sun, flat, at the map's shadow tint and strength (the cards' lifted-shadow language), on the table only. NO NEW HUE: the table is the paper stepped %.0f%% toward the ink (an ink wash), a role in data; a step toward the shadow tint is a one-line change. Faint seams every %.0f m tell the boards. Static geometry recorded once; nothing baked." % [
		_num("d.deckle.amplitude_m"), _num("d.shadow.lift_m"), _table_t() * 100.0, _num("d.table.board_m")]

# --- the records ------------------------------------------------------------------------------------

func _write_frames_json() -> void:
	var doc := {
		"id": "map-border",
		"about": "Every frame of the board as its own PNG at native size (1280 x 720), in frames/: <option>_<view>.png, option none (today's look, the reference), A, B, C, D; views far (fully zoomed out, the fog on: the topographic overview), edge035 (planning zoom 0.35 against the north-west corner, the fog off) and edge1 (zoom 1 at the same corner). board.png is the sheet of 1:1 crops of these.",
		"frames": frames,
	}
	_write_json("frames.json", doc)

func _flatten(node: Dictionary, prefix: String, out: Dictionary) -> void:
	for k: String in node:
		if k.begins_with("_"):
			continue
		var path := k if prefix == "" else prefix + "." + k
		var child: Variant = node[k]
		if child is Dictionary and not (child as Dictionary).has("value"):
			_flatten(child, path, out)
		elif child is Dictionary:
			out[path] = (child as Dictionary)["value"]

func _write_board_json() -> void:
	var opts: Array = []
	for L: String in ["A", "B", "C", "D", "E"]:
		if not _options().has(L):
			continue
		var params := {}
		if L == "E":
			_flatten(border.data.root["e"] as Dictionary, "e", params)
			_flatten(border.data.root["a"] as Dictionary, "a", params)   # (E's edge is A's records)
		else:
			_flatten(border.data.root[L.to_lower()] as Dictionary, "", params)
		var files: Array = []
		for v: Dictionary in VIEWS:
			if str(v.get("only", L)) == L:
				files.append(_fname(L, str(v["id"])))
		opts.append({"name": L, "label": border.option_name(L), "note": notes.get(L, ""), "parameters": params, "files": files, "measured": measured.get(L, {}), "proposed": L != "E", "chosen": L == "E"})
	var shared := {}
	_flatten({"reach": border.data.root["reach"], "paper": border.data.root["paper"]}, "", shared)
	var doc := {
		"id": "map-border",
		"date": "2026-10-11",
		"area": "Map",
		"question": "What does the map show past its edge? Alex (2026-10-11): 'look at a couple of art proposals for what to do for the area around the map when you zoom out. It is just a solid color right now. What are some treatments?' with the decision pan-stops-at-edge: keep the zoom-out limit at 'whole map fits' and stop panning past the edge, so a treatment is a band along the edge, at most pan.edge_overscroll_m (100 m) deep, seen at the planning zoom 0.35 and at zoom 1, and the fill of wide strips at the full zoom-out, where the map itself is the topographic overview.",
		"source": "scripts/ui/boards/map_border_board_shot.gd: the real game (the Strike scenario as the Local button starts it, seed %d, 1280 x 720, the roster sidebar up) with MapView.border.set_option(letter) (scripts/render/map_border.gd and map_border_a/b/c/d.gd, data/view/map_border.json); every option is PROPOSED" % seed_value,
		"seed": seed_value,
		"held_constant": {
			"game": "the Strike as Local starts it, seed 20261009, the sea on the east edge, 1280 x 720, the roster sidebar up (358 px at the right); the hint and the turn card are hidden for the photographs",
			"camera": "views are put with CameraController.set_view, so the view is where the edge clamp allows: far = the whole map centred in the free area (zoom %.4f); edge035 and edge1 = the free area 100 m past the north-west corner" % ctl.zoom_limit_min(),
			"fog": "on in the far view (the topographic overview, as the game shows it); off in the two edge views, so the full render shows beside the border",
			"band": "reach.band_m = 100 m = pan.edge_overscroll_m (data/view/camera.json; test_map_border holds them equal): 70 px at zoom 0.35, 200 px at zoom 1, 14 px at the full zoom-out",
			"shared": shared,
		},
		"options": opts,
		"reference": {"name": "none", "label": "the map's own edge (today's look)", "note": "REFERENCE, not an option: the engine's clear colour past the map's hard edge, which is the last 256 m chunk of the fog and 512 m chunk of the map, 120 m past the 5,000 m bounds on the right and the bottom", "files": ["frames/none_far.png", "frames/none_edge035.png", "frames/none_edge1.png"], "measured": measured.get("none", {})},
		"default": "E, the chosen look (data/view/map_border.json option, decision map-border); none, A, B, C and D stay switchable (MapView.border.set_option)",
		"palette_check": _palette_check(),
		"decision": "map-border",
		"frames": "frames.json (every frame whole, with its caption)",
		"sheet": "board.png (1:1 crops of the frames, the notes, the palette strip)",
		"measured_note": "gpu_ms_* is the root viewport's measured GPU render time per frame averaged over 60 frames at that view (RenderingServer.viewport_get_measured_render_time_gpu); compare an option with none at the same view for its cost. border_stats_after_bake: build_ms is MapBorder.set_option's own time, frame_us / frame_us_max the border's own _process time per frame (microseconds), paint_us B's repaint of its screen-space marks, C's record_ms the worker-thread recording time of all its tiles added up and texture_bytes its memory.",
		"chosen": "E - the hatched edge onto blank paper with the distance legend: option A's heavy edge line, fine rule and perpendicular hatching, plus option B's 500 m ticks with their numbers in metres and the scale bar at the full zoom-out; NOT B's double-ruled neatline and NOT B's north arrow. The numbers sit inside the map, just inside the edge line, on the paper halo, never on the hatching. Alex (2026-10-11): \"I like the hatches, with the distance legend.\" Frames: frames/chosen_<view>.png.",
		"chosen_by": "Alex, 2026-10-11",
	}
	_write_json("board.json", doc)

func _palette_check() -> Dictionary:
	var roles := {}
	for path: String in border.all_role_paths():
		var c: Color = border.role(path)
		var lch := BoardSheet.oklch(c)
		roles[path] = {"rgba": [snappedf(c.r, 0.001), snappedf(c.g, 0.001), snappedf(c.b, 0.001), snappedf(c.a, 0.001)], "oklch": [snappedf(lch.x, 0.001), snappedf(lch.y, 0.001), snappedf(lch.z, 0.1)]}
	return {
		"how_it_stays_one_palette": "Every colour is a role in data/view/map_border.json resolved by the fog's resolver (scripts/render/fog_style.gd) against the palette in data/params/render_defaults.json: the paper, the ink at an alpha or mixed toward the paper, the object fill, or the shadow tint; D's table is the paper stepped toward the ink. No hue is added; the lightness of the ink roles is a ramp off the paper. test_map_border checks every role's base is a palette colour and its chroma never exceeds its endpoints'.",
		"roles": roles,
	}

func _write_json(rel: String, doc: Dictionary) -> void:
	var f := FileAccess.open(base_dir.path_join(rel), FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[map-border-board] could not write ", rel)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + rel)

# --- the sheet ----------------------------------------------------------------------------------------

func _sheet() -> void:
	var opts := _options()
	var cols := opts.size()
	var w := MARGIN * 2 + cols * CROP_SIZE.x + (cols - 1) * GAP
	# a first pass on a tall scratch sheet says how tall the real one must be
	var scratch := BoardSheet.new(style, Vector2i(w, 6000))
	var h := int(_compose(scratch, w, opts)) + 30
	var sh := BoardSheet.new(style, Vector2i(w, h))
	_compose(sh, w, opts)
	var err: int = await sh.save(self, base_dir.path_join("board.png"))
	if err != OK:
		failures += 1
		printerr("[map-border-board] could not write board.png: ", error_string(err))
	else:
		_say("saved board.png (%d x %d)" % [w, h])

func _crop(opt: String, view: String, r: Rect2i) -> Image:
	var img: Image = images.get("%s|%s" % [opt, view])
	if img == null:
		return Image.create(r.size.x, r.size.y, false, Image.FORMAT_RGBA8)
	return img.get_region(r)

# Lays the sheet out on `sh`; returns the y it ended at.
func _compose(sh: BoardSheet, w: int, opts: Array) -> float:
	sh.text(Vector2(MARGIN, 36), "What the map shows past its edge  -  four proposals, today's look, and Alex's pick (E)  -  seed %d, the Strike, in the real game" % seed_value, 26.0, sh.c_text)
	var y := 50.0
	y += sh.paragraph(Vector2(MARGIN, y), "Alex (2026-10-11): \"look at a couple of art proposals for what to do for the area around the map when you zoom out. It is just a solid color right now. What are some treatments? ... The hatch edging onto a continued blank paper pattern. Clipped so you just see it as the border but not beyond.\" His decision since: keep the zoom-out limit at \"whole map fits\" and STOP PANNING PAST THE MAP'S EDGE (the view shows at most 100 m past it at any zoom but the full zoom-out, where the whole map is centred and the strips beside it are as wide as the window makes them). So a treatment is a band along the edge, at most 100 m deep (70 px at the planning zoom 0.35, 200 px at zoom 1), and the fill of the wide strips at the full zoom-out, where the map itself is the topographic overview.", 12.5, sh.c_muted, float(w) - MARGIN * 2.0, true) + 6.0
	y += sh.paragraph(Vector2(MARGIN, y), "Each column is one treatment photographed in the running game with MapView.border.set_option(letter): the reference column (none) is today's look, the engine's clear colour past the map's hard edge. The rows are crops, 1:1, of the whole 1280 x 720 frames (frames/<option>_<view>.png): the full zoom-out with the fog on (the topographic overview), then the planning zoom 0.35 and zoom 1 against the map's north-west corner with the fog off, so the full render's terrain and trees sit beside the border. The roster sidebar is up in every frame; the key hint and the turn card are hidden. THE PICK: Alex chose E (2026-10-11: \"I like the hatches, with the distance legend\"): A's hatched edge plus B's 500 m ticks with numbers in metres and the scale bar, without B's neatline or north arrow; the last column is that look, now the data's default (decision map-border). Every number in data/view/map_border.json is still a PROPOSED record; A to D and none stay switchable.", 12.0, sh.c_muted, float(w) - MARGIN * 2.0, true) + 14.0
	var head_y := y + 14.0
	for c in opts.size():
		var o: String = opts[c]
		var x := MARGIN + c * (CROP_SIZE.x + GAP)
		var title := "none  -  today's look (reference)" if o == "none" else ("E  -  CHOSEN: %s" % border.option_name(o) if o == "E" else "%s  -  %s" % [o, border.option_name(o)])
		sh.text(Vector2(x, head_y), title, 16.0, sh.c_text)
	y = head_y + 12.0
	for crop: Array in CROPS:
		sh.text(Vector2(MARGIN, y + 14), crop[3], 12.0, sh.c_muted, true)
		for c in opts.size():
			var o: String = opts[c]
			var x := MARGIN + c * (CROP_SIZE.x + GAP)
			sh.image(_crop(o, str(crop[0]), crop[2]), Vector2(x, y + 20))
			sh.rect(Rect2(Vector2(x, y + 20), Vector2(22, 18)), sh.c_page)
			sh.text(Vector2(x + 6, y + 34), o if o != "none" else "-", 13.0, sh.c_text)
		y += CROP_SIZE.y + 30.0
	# the notes
	sh.line(Vector2(MARGIN, y), Vector2(float(w) - MARGIN, y), sh.c_rule, 1.0)
	y += 12.0
	sh.text(Vector2(MARGIN, y + 16), "The notes, and what each costs in the running game", 17.0, sh.c_text)
	y += 30.0
	var cw := float(w - MARGIN * 2 - GAP * (opts.size() - 1)) / float(opts.size())
	var ny := y
	var tallest := 0.0
	for c in opts.size():
		var o: String = opts[c]
		var x := MARGIN + c * (cw + GAP)
		var text: String = "REFERENCE: the map's own edge. The engine's clear colour past it, a hard edge at the last whole chunk (120 m past the 5,000 m bounds on the right and the bottom)." if o == "none" else str(notes.get(o, ""))
		var used := sh.paragraph(Vector2(x, ny), text, 11.5, sh.c_muted, cw - 6.0, false, 3.0)
		var m: Dictionary = measured.get(o, {})
		var cost := "COST. GPU per frame: far %s ms, edge 0.35 %s ms, edge 1 %s ms (reference none: far %s, 0.35 %s, 1 %s). Built in %s ms, ready %s s after the switch. %s" % [
			str(m.get("gpu_ms_far", "?")), str(m.get("gpu_ms_edge035", "?")), str(m.get("gpu_ms_edge1", "?")),
			str((measured.get("none", {}) as Dictionary).get("gpu_ms_far", "?")), str((measured.get("none", {}) as Dictionary).get("gpu_ms_edge035", "?")), str((measured.get("none", {}) as Dictionary).get("gpu_ms_edge1", "?")),
			str(m.get("build_ms", "?")), str(m.get("bake_s_to_ready", "?")), _own_cost(o)]
		if o == "none":
			cost = "COST. GPU per frame: far %s ms, edge 0.35 %s ms, edge 1 %s ms." % [str(m.get("gpu_ms_far", "?")), str(m.get("gpu_ms_edge035", "?")), str(m.get("gpu_ms_edge1", "?"))]
		used += 8.0 + sh.paragraph(Vector2(x, ny + used + 8.0), cost, 11.5, sh.c_text, cw - 6.0, false, 3.0)
		tallest = maxf(tallest, used)
	y = ny + tallest + 24.0
	y = _palette_strip(sh, Vector2(MARGIN, y), float(w) - MARGIN * 2.0)
	return y

func _own_cost(o: String) -> String:
	var s: Dictionary = (measured.get(o, {}) as Dictionary).get("border_stats_after_bake", {})
	match o:
		"A": return "The border's own CPU: %s us a frame, nothing baked." % str(s.get("frame_us", "?"))
		"B": return "The border's own CPU: %s us a frame; the marks repaint (%s us last, %s us at most) only when the camera moves." % [str(s.get("frame_us", "?")), str(s.get("paint_us", "?")), str(s.get("paint_us_max", "?"))]
		"C": return "Baked ONCE per option: %s tiles, %s MB, %s s of worker-thread recording in all, at most %s ms of main-thread time in a frame (submit %s, read-back request %s, texture %s); %s us a frame after." % [
			str(s.get("tiles", "?")), "%.0f" % (float(s.get("texture_bytes", 0)) / 1048576.0), "%.0f" % (float(s.get("record_ms", 0)) / 1000.0),
			str(s.get("bake_frame_ms_max", "?")), str(s.get("bake_begin_ms_max", "?")), str(s.get("bake_collect_ms_max", "?")), str(s.get("bake_done_ms_max", "?")), str(s.get("frame_us", "?"))]
		"E": return "The border's own CPU: %s us a frame; the legend repaints (%s us last, %s us at most) when the camera moves; nothing baked." % [str(s.get("frame_us", "?")), str(s.get("paint_us", "?")), str(s.get("paint_us_max", "?"))]
		"D": return "Static geometry recorded once (%s ragged-edge vertices, %s shadow polygon(s)); the border's own CPU: %s us a frame." % [str(s.get("bite_vertices", "?")), str(s.get("shadow_polys", "?")), str(s.get("frame_us", "?"))]
	return ""

# The palette strip (working rule 6: every art choice includes the palette): paper, ink, the shadow tint, both accents and water,
# then every role each option uses (the colour as it reads: an alpha role laid over what it lies on).
func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> float:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette: paper, ink, the shadow tint, both side accents and water, then every colour role each option uses (laid over what it lies on; OKLCH lightness, chroma, hue)", 17.0, sh.c_text)
	var paper: Color = P.PAPER
	var ink: Color = P.INK
	var shadow: Color = P.shadowCol
	var water := WaterDraw.new(P)
	var x := pos.x
	var yy := pos.y + 44.0
	var base: Array = [["paper", paper], ["ink", ink], ["shadow tint", shadow], ["side_a (yours)", style.palette["side_a"]], ["side_b (theirs)", style.palette["side_b"]],
		["water: shallows", water.steps[0]], ["water: shelf", water.steps[1]], ["water: deep", water.steps[2]]]
	for c: Array in base:
		sh.chip(Vector2(x, yy), c[1], str(c[0]), BoardSheet.oklch_text(c[1]))
		x += 150.0
	yy += 100.0
	var table: Color = border.role("d.table.role")
	var groups := [
		["A", [["a.edge.line_role", "edge line", paper], ["a.rule2.role", "fine rule", paper], ["a.hatch.role", "hatch", paper]]],
		["B", [["b.rule.inner_role", "inner rule", paper], ["b.rule.outer_role", "outer rule", paper], ["b.tick.role", "ticks", paper], ["b.label.role", "numbers", paper], ["b.scale_bar.role", "scale bar", paper], ["b.north_arrow.role", "north arrow", paper]]],
		["C", [["c.contour.role", "contours", paper], ["c.edge.line_role", "edge line", paper]]],
		["E", [["e.tick.role", "ticks", paper], ["e.label.role", "numbers", paper], ["e.scale_bar.role", "scale bar", paper]]],
		["D", [["d.table.role", "table", paper], ["d.table.seam_role", "seams", table], ["d.lip.role", "lip", table], ["d.shadow.role", "shadow on table", table]]],
	]
	for g: Array in groups:
		if not _options().has(g[0]):
			continue
		x = pos.x
		sh.text(Vector2(x, yy + 22), str(g[0]), 18.0, sh.c_text)
		x += 40.0
		for e: Array in g[1]:
			var c: Color = border.role(str(e[0]))
			if str(e[0]) == "d.shadow.role":
				c = Color(c.r, c.g, c.b, P.shadowStr)
			var shown: Color = BoardSheet.over(c, e[2]) if c.a < 0.999 else c
			var label := "%s %s" % [g[0], e[1]]
			sh.chip(Vector2(x, yy), shown, label, BoardSheet.oklch_text(shown) + ("  a %.2f" % c.a if c.a < 0.999 else ""))
			x += 160.0
		yy += 100.0
	var lines: Array = []
	var pl := BoardSheet.oklch(paper)
	var il := BoardSheet.oklch(ink)
	var tl := BoardSheet.oklch(table)
	lines.append("ONE PALETTE. No option adds a hue. Every colour above is a role in data/view/map_border.json: the paper (L %.3f, C %.3f, h %d) continued past the edge with its own tint function and grain; the ink (L %.3f) at an alpha, or mixed toward the paper (C's contours are %.0f%% of the way, so they are a lighter step of the same ink ramp); the object fill for D's lip; the shadow tint at the map's own strength for D's shadow. D's table is the paper stepped %.0f%% toward the ink: L %.3f, C %.3f, h %d -- a darker step of the paper's own hue, so the table is the ground's own brown, not a new colour, and the sheet's shadow (steel tint at 0.44) falls on it as it falls on the map. Water is not used by any option; it is shown because the Strike's east edge is sea, and the blue washes the borders meet there are the water steps above." % [
		pl.x, pl.y, int(pl.z), il.x, _contour_t() * 100.0, _table_t() * 100.0, tl.x, tl.y, int(tl.z)])
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width - 20.0, false, 3.0) + 8.0
	return yy
