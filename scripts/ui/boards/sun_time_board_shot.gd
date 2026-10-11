extends SceneTree

# BOARD: THE SUN FROM THE TIME OF DAY (builder BS, 2026-10-11). WINDOWED ONLY. Nothing in the game changes until Alex picks.
#
# Alex's playtest note: "Lets have the tree shadows change. The easiest thing to do would be to use the current time of day and
# use that to select the shadow angles. Show me some options before commiting this." His answers on this board (decision
# sun-time): "Fixed time at start" (the sun is taken once, when the mission starts, and stays) and "Every shadow follows" (one
# sun for trees, terrain, structures, the planes' altitude shadows, the effects and the shadow-side pen). STILL OPEN: the look
# across the hours, the clock source in co-op, the night hours.
#
# ONE PROCESS PER FRAME. A sun is read when the map is built and baked once, so each frame is its own run of the real game:
# the Main scene, the Strike on its seed (20261009, water on), fog off, the camera on one map patch, the same units in the
# same places, only the sun different. Every frame is the game's own pixels (MapView's baked chunks, the unit markers, their
# shadows), cropped and saved at native size.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed --resolution 1280x720 `
#       --script res://scripts/ui/boards/sun_time_board_shot.gd -- option=h09 [out=variants/sun-time]
#   ... one run per option (fixed h07 h09 h12 h15 h18 trees09), then
#   ... --script res://scripts/ui/boards/sun_time_board_shot.gd -- compose=1 [out=variants/sun-time]
#
# `compose=1` reads the frames and their sidecars (<option>.json) and writes board.png (the sheet), frames.json and board.json
# ("chosen": null). `x= y= zoom=` move the camera for a look at another patch; `units=0` leaves the added units out.
#
# EVERYTHING HERE THAT IS NOT ALEX'S IS PROPOSED: the hours shown, the model's numbers (data/params/sun.json clock block), the
# patch, the zoom, the units' places.

const Sun = preload("res://scripts/world/sun.gd")
const World = preload("res://scripts/sim/world.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")

const SEED := 20261009
const OUT_DEFAULT := "variants/sun-time"
const WINDOW := Vector2i(1280, 720)
# The patch (PROPOSED): centred between the bridge (1368, 1172) and the radio tower (1940, 1444), where the road from the
# bridge reaches the village; zoom 0.85 (1.7 px per metre: the whole 1280 x 720 shows 753 x 423 m, the bridge and the tower
# both in it). The second frame of each option is the PLANNING ZOOM over the same patch.
const PATCH_CENTRE_M := Vector2(1654.0, 1308.0)
const PATCH_ZOOM := 0.85
const PLAN_ZOOM := 0.35   # data/view/camera.json zoom.start: the planning view, what the player sees at the start of a turn

# The options (all PROPOSED): id, caption, the Sun's override. The five hours are the lead's example set; the first is today's.
const OPTIONS := [
	{"id": "fixed", "title": "Today's sun (fixed)", "override": {}},
	{"id": "h07", "title": "07:00", "override": {"mode": "clock_at_start", "hour": 7.0}},
	{"id": "h09", "title": "09:00", "override": {"mode": "clock_at_start", "hour": 9.0}},
	{"id": "h12", "title": "12:00", "override": {"mode": "clock_at_start", "hour": 12.0}},
	{"id": "h15", "title": "15:00", "override": {"mode": "clock_at_start", "hour": 15.0}},
	{"id": "h18", "title": "18:00", "override": {"mode": "clock_at_start", "hour": 18.0}},
	{"id": "trees09", "title": "Why not: only the trees follow (09:00)", "override": {"mode": "clock_at_start", "hour": 9.0, "scope": "trees"}},
]

var opts: Dictionary = {}
var out_dir := OUT_DEFAULT
var main: Node = null
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
		printerr("[sun-board] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	if opts.has("compose"):
		_compose.call_deferred()
	else:
		_frame.call_deferred()

func _say(msg: String) -> void:
	print("[sun-board] ", msg)

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _option(id: String) -> Dictionary:
	for o: Dictionary in OPTIONS:
		if str(o["id"]) == id:
			return o
	return {}

# --- One frame -------------------------------------------------------------------------------------------------------------

func _frame() -> void:
	var opt := _option(str(opts.get("option", "fixed")))
	if opt.is_empty():
		printerr("[sun-board] unknown option '%s'" % str(opts.get("option")))
		quit(1)
		return
	Sun.set_override(opt["override"])
	var sun = Sun.current()
	_say("%s -> %s" % [opt["id"], sun.describe()])
	# fog off: every unit and the whole patch are drawn wherever the camera looks
	var knobs: Node = root.get_node("DebugSettings")   # (an autoload is not a global name in a --script run)
	var fog_i: int = knobs.OPTIONS["fog"]["choices"].find("off")
	knobs.set_value("fog", fog_i)
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(WINDOW)
	root.size = WINDOW
	await _frames(10)
	var t0 := Time.get_ticks_msec()
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[sun-board] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	while not sb.is_playable and Time.get_ticks_msec() - t0 < 300000:
		await process_frame
	if not sb.is_playable:
		printerr("[sun-board] the sandbox was not playable after 300 s")
		quit(1)
		return
	var load_ms := Time.get_ticks_msec() - t0
	_say("playable after %d ms (the map's first view and the tree set baked once, under this sun)" % load_ms)
	# a clean frame: no HUD, no hint, no clock, no target ring, nothing selected
	sb.ui.hud.visible = false
	sb.hint.visible = false
	sb.clock.visible = false
	sb.knobs.visible = false
	if sb.objective != null:
		sb.objective.visible = false
	sb.ui.selection.clear()
	sb.ui.set_process_input(false)
	for c: Node in main.get_node("CanvasLayer").get_children():
		if c is Label:
			c.visible = false   # the corner build stamp
	# the height and speed lettering under the units is left out so that the frame shows shadows only
	var st = UiStyle.shared()
	(st.ui["labels"] as Dictionary)["enabled"] = false
	var w: World = sb.world
	var info := {"option": opt["id"], "title": opt["title"], "sun": sun.describe(), "mode": sun.mode, "scope": sun.scope,
		"hour": sun.asked_hour if sun.mode == "clock_at_start" else null,
		"azimuth_deg": sun.azimuth_deg, "elevation_deg": sun.elevation_deg, "sun_len": sun.sun_len(),
		"tree_azimuth_deg": sun.tree_azimuth_deg, "tree_elevation_deg": sun.tree_elevation_deg,
		"shadow_dir": [sun.shadow_dir().x, sun.shadow_dir().y], "load_ms": load_ms}
	if str(opts.get("units", "1")) != "0":
		info["units"] = _place_units(w)
	var centre := Vector2(float(opts.get("x", PATCH_CENTRE_M.x)), float(opts.get("y", PATCH_CENTRE_M.y)))
	var zoom := float(opts.get("zoom", PATCH_ZOOM))
	sb.ctl.stop_follow()
	sb.ctl.set_view(centre * float(sb.map_view.px_per_m), zoom)
	await _frames(4)
	var t1 := Time.get_ticks_msec()
	await _wait_view()
	info["settle_ms"] = Time.get_ticks_msec() - t1
	info["camera"] = {"centre_m": [centre.x, centre.y], "zoom": zoom, "px_per_m": float(sb.map_view.px_per_m) * zoom}
	var id := str(opt["id"])
	var file := "%s.png" % id if not opts.has("x") else "look_%s.png" % id
	var img := await _grab()
	var err := img.save_png(out_dir.path_join(file))
	_say("saved %s (%s, %s)" % [out_dir.path_join(file), str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1
	info["file"] = file
	info["size"] = [img.get_width(), img.get_height()]
	# the planning zoom over the same patch
	if str(opts.get("plan", "1")) != "0":
		sb.ctl.set_view(centre * float(sb.map_view.px_per_m), PLAN_ZOOM)
		await _frames(4)
		var t2 := Time.get_ticks_msec()
		await _wait_view()
		info["plan_settle_ms"] = Time.get_ticks_msec() - t2
		var pimg := await _grab()
		var pfile := "%s_plan.png" % id if not opts.has("x") else "look_%s_plan.png" % id
		err = pimg.save_png(out_dir.path_join(pfile))
		_say("saved %s (%s, %s)" % [out_dir.path_join(pfile), str(pimg.get_size()), error_string(err)])
		if err != OK:
			_failures += 1
		info["plan_file"] = pfile
		info["plan_camera"] = {"centre_m": [centre.x, centre.y], "zoom": PLAN_ZOOM, "px_per_m": float(sb.map_view.px_per_m) * PLAN_ZOOM}
	var f := FileAccess.open(out_dir.path_join("%s.json" % id), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(info, "  ", false))
		f.close()
	sb.map_view.baker.clear()   # the baker's workers must be done before quitting (CLAUDE.md: exit 139 otherwise)
	sb.shutdown()
	await _frames(2)
	quit(1 if _failures > 0 else 0)

func _grab() -> Image:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	return img

# Waits for the map under the view to be baked, then lets the markers settle.
func _wait_view(max_s: float = 180.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0:
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[sun-board] view not complete after %.0f s" % max_s)
			_failures += 1
			break
		await process_frame
	await _frames(24)

# The units of the patch (PROPOSED), placed by the layout's own sites: a bomber at altitude over the village (its shadow gap
# is the altitude rule), and a tank on the road at the bridge. The Strike's own units (the tower, the batteries, the bridge)
# stand where the scenario puts them; the other planes are moved out of the patch.
func _place_units(w: World) -> Dictionary:
	var info := {}
	var bridge = w.units["bridge_1"] if w.units.has("bridge_1") else null
	var tower = w.units["radio_tower_1"] if w.units.has("radio_tower_1") else null
	if bridge == null or tower == null:
		printerr("[sun-board] the Strike has no bridge or tower: ", str(w.units.keys()))
		_failures += 1
		return info
	var bpos := Vector2(float(bridge.x), float(bridge.y))
	var road_dir := Vector2.from_angle(float(bridge.heading))   # along the road, from the bridge towards the west-north-west
	# the other planes out of the shot
	for id: String in w.units:
		var u = w.units[id]
		if u.def.domain == "air":
			u.x = 4300.0
			u.y = 4300.0
	var tank_at := bpos - road_dir * 70.0      # on the road, on the village side of the bridge
	var tank_heading := float(bridge.heading) + PI
	var tid: String = w.add_unit({"id": "tank_sun", "type": "tank", "side": "allies", "controller": "player",
		"x": tank_at.x, "y": tank_at.y, "heading": tank_heading, "speed": 0.0})
	info["tank"] = {"id": tid, "at": [tank_at.x, tank_at.y], "error": w.last_error if tid == "" else ""}
	# a bomber at altitude, over the village's west end, heading across the patch
	var plane_at := Vector2(float(opts.get("px", 1560.0)), float(opts.get("py", 1250.0)))
	var pid: String = "bomber_1"
	if w.units.has(pid):
		var b = w.units[pid]
		b.x = plane_at.x
		b.y = plane_at.y
		b.heading = 0.45
		b.altitude_band = "high"
		b.out_of_bounds = false
	info["plane"] = {"id": pid, "at": [plane_at.x, plane_at.y], "band": "high"}
	return info

# --- The sheet, frames.json and board.json -----------------------------------------------------------------------------------

const MARGIN := 24.0
const CROP := Vector2(640.0, 360.0)
const GAP := 12.0
const SHEET_W := 1992   # three native 640 x 360 crops across
# Crops of the 1280 x 720 frame at zoom 0.85, 1:1 (native pixels): the bridge, river, plane and tank; the tower and village.
const Z1_NW := Rect2(0.0, 0.0, 640.0, 360.0)
const Z1_SE := Rect2(640.0, 360.0, 640.0, 360.0)
# The planning-zoom frame, the middle of it, 1:1.
const PLAN_MID := Rect2(320.0, 180.0, 640.0, 360.0)
# Where the plane and the tank are in the zoom 0.85 frame (the camera and the units are the same in every option).
const PLANE_BOX := Rect2(330.0, 190.0, 300.0, 120.0)
const TANK_BOX := Rect2(215.0, 128.0, 100.0, 60.0)

# Alex's two answers, in his words.
const DECIDED := [
	{"id": "sun-time", "what": "fixed_at_start", "alex": "Fixed time at start",
		"meaning": "The sun is taken once, when the mission starts, and stays for the whole mission: the map bakes once (no moving sun, no rebake during play)."},
	{"id": "sun-time", "what": "every_shadow_follows", "alex": "Every shadow follows",
		"meaning": "One sun for the trees, the terrain's scarps, the structures, the planes' altitude shadows, the effects and the shadow-side pen. The 'trees only' frame is kept as a why-not note."},
]

# The questions, with options and a PROPOSED recommendation each.
const QUESTIONS := [
	{"id": "a_time_source", "status": "open", "question": "(a) Where does the hour come from, and in co-op whose clock?",
		"options": [
			{"id": "each_clock", "text": "Each player's own clock at the moment the mission starts. Simple, but in co-op the two players can see two different maps (one at 09:00, one at 21:00), which breaks 'one shared map'."},
			{"id": "host_clock", "text": "The host's clock at mission start, sent to the client with the start (the way the seed travels), so both see one map. A single player's game is Alex's own idea: their own clock."},
			{"id": "scenario_hour", "text": "An hour written into the scenario (a Strike at dawn, a Bridge at noon), with the clock used only when the scenario names none. Gives every mission a look of its own, and the headless tests need it anyway (a test pins an hour)."}],
		"recommendation_proposed": "host_clock, with scenario_hour as an override: the host's clock at the start of the mission, sent to the client; a scenario may name its own hour. (PROPOSED by the builder BS; Alex decides. Alex's own suggestion was the current time of day.)"},
	{"id": "b_night", "status": "open", "question": "(b) What does an hour outside the day (before 06:00, after 18:00) mean?",
		"options": [
			{"id": "clamp", "text": "The nearest daytime hour: before 06:00 the 06:00 sun, after 18:00 the 18:00 sun. Half of the clock's hours (the 12 night ones) then land on the two longest-shadow suns of the day."},
			{"id": "fold", "text": "Fold the 24 hours onto the day arc: midnight is the sunrise sun, 06:00 the 09:00 sun, noon is noon, 18:00 the 15:00 sun. The sun always moves with the clock, every hour of the real day gives a different map, and no part of the day piles up on the clamp."}],
		"recommendation_proposed": "fold (PROPOSED by the builder BS): with clamp, a game played at any hour from 18:00 to 06:00, half of all hours, gets the dawn-or-dusk sun with the longest shadows the model has; fold spreads them. sun.json 'night' holds the switch."},
	{"id": "c_when", "status": "decided", "question": "(c) A sun fixed for the mission, or moving during it?",
		"alex": "Fixed time at start",
		"note": "DECIDED by Alex (decision sun-time): \"Fixed time at start\". The map bakes once; what that costs is measured above."},
	{"id": "d_look", "status": "open", "question": "(d) The look across the hours: what the model's numbers should be.",
		"options": [
			{"id": "as_shown", "text": "As shown: sunrise 06:00 and sunset 18:00, noon elevation 60 degrees, the shadow's length per unit of height clamped at 3.0 (an 18.4 degree sun). Today's fixed sun is 46 degrees, a length of 0.97."},
			{"id": "gentler", "text": "A shorter clamp (2.0, a 26.6 degree sun): the dawn and dusk shadows are less dramatic, less of the map is under them, and the tower's lattice shadow and a plane's gap stay closer to today's."},
			{"id": "narrower_day", "text": "A narrower day (08:00 to 16:00 in the model; the hours outside follow the night rule): no frame at the clamp, only the middle of the day's looks."},
			{"id": "plane_gap", "text": "The planes' altitude shadow (1% of the height, decision unit-sheet-choices) is scaled by the sun's length, so at the 07:00 and 18:00 clamp the gap is 3.1 times today's (see the detail rows). Either leave that, or hold the gap at today's length so a plane's shadow never strays far from it."}],
		"recommendation_proposed": "as_shown for the model, and the planes' gap held at today's length (PROPOSED by the builder BS): the long shadows are the point of the board, but a plane's shadow that drifts 100 px from it reads as a second plane. Alex looks at the frames and decides."},
]

func _compass(bearing: float) -> String:
	var names := ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
	return str(names[int(roundf(fposmod(bearing, 360.0) / 22.5)) % 16])

func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _load_png(name: String) -> Image:
	var img := Image.load_from_file(out_dir.path_join(name))
	if img != null:
		img.convert(Image.FORMAT_RGBA8)
	return img

# The mean colour of a crop, as OKLCH lightness: how much darker the map is under this sun.
func _mean_lightness(img: Image) -> float:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	var step := 3
	for y in range(0, img.get_height(), step):
		for x in range(0, img.get_width(), step):
			var c := img.get_pixel(x, y)
			r += c.r
			g += c.g
			b += c.b
			n += 1
	return BoardSheet.oklch(Color(r / n, g / n, b / n)).x

func _compose() -> void:
	var style: UiStyle = UiStyle.new()
	if not style.ok():
		printerr("[sun-board] style errors: ", style.errors)
		quit(1)
		return
	var infos: Array = []
	var imgs: Dictionary = {}
	for o: Dictionary in OPTIONS:
		var id := str(o["id"])
		var info: Variant = _read_json(out_dir.path_join("%s.json" % id))
		var z1 := _load_png("%s.png" % id)
		var pl := _load_png("%s_plan.png" % id)
		if not (info is Dictionary) or z1 == null or pl == null:
			printerr("[sun-board] missing frame or sidecar for '%s' in %s: run option=%s first" % [id, out_dir, id])
			quit(1)
			return
		(info as Dictionary)["_lightness_z1"] = _mean_lightness(z1)
		(info as Dictionary)["_lightness_plan"] = _mean_lightness(pl)
		infos.append(info)
		imgs[id] = {"z1": z1, "plan": pl}
	var measured: Variant = _read_json(out_dir.path_join("measured.json"))
	var sh := BoardSheet.new(style, Vector2i(SHEET_W, 9000))
	var tw := float(SHEET_W) - MARGIN * 2.0
	var y := 34.0
	sh.text(Vector2(MARGIN, y), "The sun from the time of day  ·  seed %d, the Strike's map patch under five hours and today's sun" % SEED, 25.0, sh.c_text)
	y += 18.0
	y += sh.paragraph(Vector2(MARGIN, y), "Alex, from the playtest: \"Lets have the tree shadows change. The easiest thing to do would be to use the current time of day and use that to select the shadow angles. Show me some options before commiting this.\" He has answered two of the questions on this board (decision sun-time): \"Fixed time at start\" (the sun is taken once, when the mission starts, and stays: the map bakes once) and \"Every shadow follows\" (one sun for the trees, the terrain, the structures, the planes' altitude shadows, the effects and the shadow-side pen). STILL OPEN, below: (a) whose clock in co-op, (b) the night hours, (d) the look across the hours. Nothing in the game changes until he picks: the sun is data/params/sun.json, its mode is 'fixed' (today's sun) and the switch to the clock is mode 'clock_at_start' with an hour.", 12.5, sh.c_muted, tw, true) + 8.0
	y += sh.paragraph(Vector2(MARGIN, y), "WHAT YOU ARE LOOKING AT. Each option is a run of the real game: the Strike on seed 20261009 with the water on, the fog off, the camera on one patch of map between the bridge and the radio tower, and only the sun different. Everything in a frame is the game's own pixels: the baked chunks (trees and their shadows, the hills' scarps and their shadows, the village, the fields, the river and the bridge), the unit markers and their shadows (a bomber in the HIGH band, 1,000 m up, over the field; a tank on the road at the bridge). The height and speed lettering and the HUD are left off. Each row shows three 640 x 360 crops at 1:1 (never scaled): the bridge, river, plane and tank at zoom 0.85 (1.7 px per metre); the radio tower and the village at the same zoom; and the middle of the planning zoom 0.35 (0.7 px per metre), what the player sees at the start of every turn. The whole frames are the PNGs beside this sheet (frames.json). The detail rows enlarge the plane and the tank (nearest neighbour, 2 and 3 times).", 12.5, sh.c_muted, tw) + 8.0
	y += sh.paragraph(Vector2(MARGIN, y), "THE MODEL (all PROPOSED by the builder BS; data/params/sun.json, scripts/world/sun.gd). The sun rises in the east and sets in the west through the south, the map's north up: the bearing runs 90 (east) at 06:00 to 180 (due south) at noon to 270 (west) at 18:00, straight over the hours. The height is a sine arc, 60 degrees at noon. A shadow is its object's height times 1 / tan(elevation); that length is clamped at 3.0 so dawn and dusk shadows stay readable (an unclamped 07:00 sun is 15.5 degrees, a length of 3.6; sunrise and sunset themselves would be infinite). Today's sun is the north-west at 46 degrees, a length of 0.97, and is mode 'fixed', the default. The pen's shadow side, the shaded roofs and slopes, the tower's lattice shadow and the planes' altitude shadows all read the one sun. Hours shown (the lead's example set): 07:00, 09:00, 12:00, 15:00 and 18:00; 07:00 and 18:00 sit AT the clamp.", 12.5, sh.c_muted, tw) + 12.0
	var row_h := 26.0 + CROP.y + 30.0
	for k in infos.size():
		var info: Dictionary = infos[k]
		var id := str(info["option"])
		var why_not := id == "trees09"
		sh.line(Vector2(MARGIN, y), Vector2(float(SHEET_W) - MARGIN, y), sh.c_rule, 1.0)
		var head := str(info["title"])
		var line := ""
		if id == "fixed":
			line = "bearing 315 (NW), elevation 46, shadows %.2f x the height, fall to the SE  ·  mode 'fixed', the default" % float(info["sun_len"])
		elif why_not:
			line = "the trees' shadows follow the 09:00 sun (bearing 135, SE: they fall to the NW); everything else keeps today's NW sun (they fall to the SE)  ·  scope 'trees', a test switch only"
		else:
			var az := float(info["azimuth_deg"])
			line = "bearing %.0f (%s), elevation %.1f%s, shadows %.2f x the height, fall to the %s  ·  mode 'clock_at_start', hour %s" % [az, _compass(az), float(info["elevation_deg"]), " (the clamp)" if absf(float(info["sun_len"]) - 3.0) < 1e-6 else "", float(info["sun_len"]), _compass(az + 180.0), Sun.hour_text(float(info["hour"]))]
		sh.text(Vector2(MARGIN, y + 20.0), "%s  ·  %s" % [head, line], 15.0, sh.c_text)
		var iy := y + 30.0
		var z1: Image = imgs[id]["z1"]
		var pl: Image = imgs[id]["plan"]
		var x := MARGIN
		for part: Array in [[z1, Z1_NW, "zoom 0.85, 1:1: the bridge, the river, a bomber at 1,000 m and a tank"], [z1, Z1_SE, "zoom 0.85, 1:1: the radio tower and the village"], [pl, PLAN_MID, "planning zoom 0.35, 1:1: the middle of the frame"]]:
			sh.image(part[0], Vector2(x, iy), part[1])
			sh.rect(Rect2(Vector2(x, iy), CROP), sh.c_chip_line, false, 1.0)
			sh.text(Vector2(x, iy + CROP.y + 13.0), str(part[2]), 11.0, sh.c_muted, true)
			x += CROP.x + GAP
		y += row_h
	# --- the detail rows: the plane and the tank, enlarged
	sh.line(Vector2(MARGIN, y), Vector2(float(SHEET_W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 26.0), "Detail: the bomber and the tank, enlarged (nearest neighbour: the plane 2x, the tank 3x)", 20.0, sh.c_text)
	y += 40.0
	var drow := PLANE_BOX.size.y * 2.0 + 12.0
	for k in infos.size():
		var info: Dictionary = infos[k]
		var id := str(info["option"])
		var z1: Image = imgs[id]["z1"]
		var x := MARGIN
		sh.image(z1, Vector2(x, y), PLANE_BOX, PLANE_BOX.size * 2.0)
		sh.rect(Rect2(Vector2(x, y), PLANE_BOX.size * 2.0), sh.c_chip_line, false, 1.0)
		x += PLANE_BOX.size.x * 2.0 + GAP
		sh.image(z1, Vector2(x, y), TANK_BOX, TANK_BOX.size * 3.0)
		sh.rect(Rect2(Vector2(x, y), TANK_BOX.size * 3.0), sh.c_chip_line, false, 1.0)
		x += TANK_BOX.size.x * 3.0 + GAP + 8.0
		var main_len := float(info["sun_len"])   # (the trees-only frame keeps today's sun for the planes)
		var gap_m := 1000.0 * 0.01 * main_len
		sh.text(Vector2(x, y + 22.0), str(info["title"]), 14.0, sh.c_text)
		var ty := y + 42.0
		ty += sh.paragraph(Vector2(x, ty), "The bomber's shadow stands %.1f m from it (1%% of its 1,000 m, times the sun's length %.2f), %.0f px at this zoom before the marker's own scale. Mean lightness of the whole patch: L %.3f at zoom 0.85, L %.3f at the planning zoom." % [gap_m, main_len, gap_m * 1.7, float(info["_lightness_z1"]), float(info["_lightness_plan"])], 12.0, sh.c_muted, float(SHEET_W) - MARGIN - x, false, 3.0) + 4.0
		y += drow
	# --- what it costs
	y += 8.0
	sh.line(Vector2(MARGIN, y), Vector2(float(SHEET_W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 26.0), "What a sun costs: measured on this machine (decision: fixed at the start, so the map bakes once)", 20.0, sh.c_text)
	y += 40.0
	y += sh.paragraph(Vector2(MARGIN, y), _cost_text(infos, measured), 12.5, sh.c_muted, tw) + 12.0
	# --- the questions
	sh.line(Vector2(MARGIN, y), Vector2(float(SHEET_W) - MARGIN, y), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y + 26.0), "Alex's two answers, and the questions still open (each with options and a PROPOSED recommendation)", 20.0, sh.c_text)
	y += 40.0
	for d: Dictionary in DECIDED:
		y += sh.paragraph(Vector2(MARGIN, y), "DECIDED by Alex (%s, 2026-10-11): \"%s\". %s" % [str(d["id"]), str(d["alex"]), str(d["meaning"])], 12.5, sh.c_text, tw) + 6.0
	y += 6.0
	for q: Dictionary in QUESTIONS:
		sh.text(Vector2(MARGIN, y + 16.0), "%s  [%s]" % [str(q["question"]), str(q["status"]).to_upper()], 14.5, sh.c_text)
		y += 24.0
		if q.has("options"):
			for op: Dictionary in q["options"]:
				y += sh.paragraph(Vector2(MARGIN + 14.0, y), "- %s: %s" % [str(op["id"]), str(op["text"])], 12.0, sh.c_muted, tw - 14.0, false, 3.0) + 3.0
			y += sh.paragraph(Vector2(MARGIN + 14.0, y), "RECOMMENDATION (PROPOSED): %s" % str(q["recommendation_proposed"]), 12.0, sh.c_text, tw - 14.0, false, 3.0) + 12.0
		else:
			y += sh.paragraph(Vector2(MARGIN + 14.0, y), str(q["note"]), 12.0, sh.c_muted, tw - 14.0, false, 3.0) + 12.0
	# --- the palette
	y = _palette_strip(sh, style, infos, y)
	var end_y := y + 20.0
	var path := out_dir.path_join("board.png")
	var err: int = await sh.save(self, path)
	if err != OK:
		printerr("[sun-board] could not write board.png: ", error_string(err))
		quit(1)
		return
	var full := Image.load_from_file(path)
	full.get_region(Rect2i(0, 0, SHEET_W, int(end_y))).save_png(path)
	_say("saved %s (%d x %d)" % [path, SHEET_W, int(end_y)])
	_write_frames_json(infos)
	_write_board_json(infos, measured)
	quit(0)

func _cost_text(infos: Array, measured: Variant) -> String:
	var parts: Array[String] = []
	var loads := ""
	for info: Dictionary in infos:
		loads += "%s %.1f s; " % [str(info["option"]), float(info["load_ms"]) / 1000.0]
	parts.append("TIME TO PLAYABLE under each sun (the Strike started as the menu starts it: the first view of 40 chunks and the tree set, fog off; one run after another on one machine): %s" % loads)
	if measured is Dictionary:
		parts.append(str((measured as Dictionary).get("text", "")))
	else:
		parts.append("(the whole-map bake measurement has not been added: measured.json)")
	parts.append("WHAT BAKES ONCE: with the sun fixed at the start, a mission's map is baked exactly as today (view first, the rest in the background) under the sun that mission has. Nothing in play re-reads the sun. A new mission (Play again, a new scenario) builds a new sun and a new map, as it builds a new seed's map today. The tree set, the unit art and the effects' sprites are built after the sun is read, so they carry no stale sun as long as Sun.reset() runs before a mission builds (not built yet: these runs are one process per sun).")
	return "  ".join(parts)

func _palette_strip(sh: BoardSheet, style: UiStyle, infos: Array, y0: float) -> float:
	var pal: Dictionary = style.palette
	sh.line(Vector2(MARGIN, y0), Vector2(float(SHEET_W) - MARGIN, y0), sh.c_rule, 1.0)
	sh.text(Vector2(MARGIN, y0 + 26.0), "The palette: the sun adds no colour (roles in data/params/render_defaults.json; no hex in the draw code)", 20.0, sh.c_text)
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
	for info: Dictionary in infos:
		if str(info["option"]) == "trees09":
			continue
		lo = minf(lo, float(info["_lightness_z1"]))
		hi = maxf(hi, float(info["_lightness_z1"]))
	var lines: Array = [
		"HUE stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md). The sun changes WHERE the one shadow tint falls, not what it is: every shadow in every row is the same steel tint at the same strength (%.2f), so a shadow on paper and a shadow over a lit roof are the two chips above in every frame, and a place where two shadows overlap does not darken twice (the shadow pass composites each class once). LIGHTNESS is still a ramp off paper: the hours change the SHARE of the ground that is in shadow, not the ramp. The mean lightness of the zoom 0.85 patch runs from L %.3f to L %.3f across the options (the longest shadows give the darkest patch)." % [strength, lo, hi],
		"MATERIAL is linework and stays so: the shadow-side pen thickens the edges that face away from the sun and thins the ones that face it, whichever way that is (the trees' outlines, the hills' contours, the tower, the houses): at 12:00 the heavy edge of a tree is its north side, at 07:00 the east. NO WARMING OR COOLING of the light at dawn or dusk is proposed (a golden hour would add a hue to the map, against the palette rule): the model moves only the direction and the length. The interior detail light of the trees' florets and stipple (linework.detail_light, 'independent of the sun', top-left) is untouched by the hours; it is the one light on the map that does not follow the sun, and it is a prototype choice.",
	]
	for l: String in lines:
		yy += sh.paragraph(Vector2(MARGIN, yy), l, 12.0, sh.c_muted, float(SHEET_W) - MARGIN * 2.0, false, 3.0) + 6.0
	return yy

func _write_frames_json(infos: Array) -> void:
	var frames: Array = []
	for info: Dictionary in infos:
		var cam: Dictionary = info["camera"]
		frames.append({"file": info["file"], "option": info["option"], "kind": "zoom_0.85", "zoom": cam["zoom"], "px_per_m": cam["px_per_m"], "size": info["size"],
			"caption": "%s: %s" % [str(info["title"]), str(info["sun"])]})
		var pcam: Dictionary = info["plan_camera"]
		frames.append({"file": info["plan_file"], "option": info["option"], "kind": "planning_zoom", "zoom": pcam["zoom"], "px_per_m": pcam["px_per_m"], "size": info["size"],
			"caption": "%s at the planning zoom: %s" % [str(info["title"]), str(info["sun"])]})
	var doc := {"id": "sun-time", "about": "Every frame of the sun-time board as its own PNG at native size (1280 x 720): the game's own pixels, one run of the real game per sun (the Strike, seed 20261009, water on, fog off, the camera on the same patch). board.png is the sheet: 1:1 crops of these frames and nearest-neighbour enlargements of the plane and the tank.",
		"frames": frames}
	var f := FileAccess.open(out_dir.path_join("frames.json"), FileAccess.WRITE)
	if f == null:
		printerr("[sun-board] could not write frames.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()

func _write_board_json(infos: Array, measured: Variant) -> void:
	var options: Array = []
	var why_not := {}
	var letters := ["A", "B", "C", "D", "E", "F", "G"]
	var n := 0
	for info: Dictionary in infos:
		var hour_text := ""
		if info["hour"] != null:
			hour_text = ", hour %s" % Sun.hour_text(float(info["hour"]))
		var rec := {"id": info["option"], "title": info["title"], "proposed": true, "files": [info["file"], info["plan_file"]],
			"sun": {"mode": info["mode"], "scope": info["scope"], "hour": info["hour"], "bearing_deg": info["azimuth_deg"], "elevation_deg": info["elevation_deg"], "shadow_length_per_height": info["sun_len"],
				"tree_bearing_deg": info["tree_azimuth_deg"], "tree_elevation_deg": info["tree_elevation_deg"]},
			"set_by": "data/params/sun.json mode '%s'%s" % [str(info["mode"]), hour_text],
			"mean_lightness": {"zoom_0.85": snappedf(float(info["_lightness_z1"]), 0.001), "planning_zoom": snappedf(float(info["_lightness_plan"]), 0.001)}}
		if str(info["option"]) == "trees09":
			rec["why_not"] = "Only the trees' cast shadows follow the 09:00 sun; the scarps, structures, units and the pen keep today's. Two suns on one map break the look (the tower's shadow runs south-east while the trees' run north-west). Alex decided 'Every shadow follows'; this frame is the note of why."
			why_not = rec
		else:
			rec["name"] = letters[n]
			n += 1
			options.append(rec)
	var doc := {
		"id": "sun-time",
		"date": "2026-10-11",
		"area": "Light and shadow, World",
		"question": "Should the shadow angles follow the time of day? Alex (playtest): 'Lets have the tree shadows change. The easiest thing to do would be to use the current time of day and use that to select the shadow angles. Show me some options before commiting this.'",
		"source": "scripts/ui/boards/sun_time_board_shot.gd: one run of the real game per sun (the Strike on seed 20261009, water on, fog off, one patch of map between the bridge and the radio tower at zoom 0.85 and at the planning zoom 0.35; the same units in the same places), through the sun source scripts/world/sun.gd and data/params/sun.json. Nothing in the live game changes: the default mode is 'fixed' (today's sun).",
		"seed": SEED,
		"held_constant": {
			"map": "the Strike's map and units on seed 20261009, water on (a river, the bridge, the sea); the same camera on the patch centred at (1654, 1308) m",
			"units": "a bomber in the high band (1,000 m) at (1560, 1250) heading 0.45 rad over the field; a tank on the road 70 m from the bridge, on the village side; the Strike's own tower, batteries and bridge. The other planes are out of the frame.",
			"shadow": "the one steel tint at the map's shadow strength 0.44; the shadow-side pen; the planes' altitude shadow rule (1% of the height)",
			"left_off": "the HUD, the height and speed lettering, the target ring, the build stamp",
			"detail_light": "the trees' interior detail light (linework.detail_light, top-left) is independent of the sun and unchanged",
		},
		"decided": [
			{"decision": "sun-time", "id": "fixed_at_start", "by": "Alex", "alex_words": "Fixed time at start", "status": "chosen by Alex",
				"meaning": "The sun is taken once when the mission starts and stays fixed for the whole mission, so the map bakes once. No moving-sun option."},
			{"decision": "sun-time", "id": "every_shadow_follows", "by": "Alex", "alex_words": "Every shadow follows", "status": "chosen by Alex",
				"meaning": "Every shadow follows the one sun: the trees', the terrain's, the structures', the planes' altitude shadows, the effects' and the shadow-side pen. The trees-only frame is kept as a why-not note."},
		],
		"parameter": "data/params/sun.json: mode ('fixed' | 'clock_at_start'), hour, hour_source, scope, the 'clock' block (sunrise 6, sunset 18, bearings 90 to 270, noon elevation 60, max shadow length 3.0, night rule); DebugSettings knobs sun_mode, sun_hour, sun_scope (INKWOOD_SUN_MODE=clock_at_start INKWOOD_SUN_HOUR=9)",
		"model_proposed": {
			"bearing": "90 (east) at 06:00 through 180 (south) at noon to 270 (west) at 18:00, straight over the hours; 0 is north, the map's north is up",
			"elevation": "60 * sin(pi * t), t = 0 at sunrise, 1 at sunset",
			"shadow_length": "1 / tan(elevation) per unit of height, clamped at 3.0 (an 18.4 degree sun); today's fixed sun is 46 degrees, 0.97",
			"night": "clamp (the nearest daytime hour) or fold (24 hours on the arc): open question (b)",
			"note": "ALL PROPOSED by the builder BS except today's sun, which is the design doc's.",
		},
		"options": options,
		"why_not_frame": why_not,
		"questions": QUESTIONS,
		"measured": measured if measured is Dictionary else {},
		"palette_check": "The sun adds no colour: every shadow is the one steel tint at the same strength, a shadow over a lit roof the roof-shaded chip. The hours change the share of the ground in shadow (mean lightness of the zoom 0.85 patch by hour in each option), not the lightness ramp. No dawn or dusk colour cast is proposed (it would add a hue). The trees' interior detail light does not follow the sun.",
		"recommendation_proposed": "PROPOSED by the builder BS (Alex decides): the model as shown (06:00 to 18:00, noon 60 degrees, shadow length clamped at 3.0), the host's clock at mission start with a scenario able to name its own hour, the night hours FOLDED, and the planes' altitude shadow held at today's length. See 'questions'.",
		"frames": "frames.json (every frame, native 1280 x 720)",
		"sheet": "board.png (1:1 crops of every frame, enlarged plane and tank details, the measured cost, the questions, the palette strip)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(out_dir.path_join("board.json"), FileAccess.WRITE)
	if f == null:
		printerr("[sun-board] could not write board.json")
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved board.json")
