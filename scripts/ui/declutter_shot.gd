extends SceneTree

# DECLUTTER SHOTS: LINES AND LETTERING (Track C, 2026-10-10; Alex's notes on the Strike playtest). WINDOWED ONLY.
# The REAL Strike, started as the menu starts it (the Main scene, Local), played three turns through the real turn flow
# (Ready, the host-side resolve, the markers' playback; the players flown by the scripted run, scripts/test_support/
# strike_play.gd) so there is a ribbon, a flown track and thin plans on the map, then the bomber selected and THREE
# STEPS PLANNED, each asked for past what its envelope allows (so each is clamped: the planner's old dashed tie to a
# little X). The same two views are saved, at the window's native size:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --script res://scripts/ui/declutter_shot.gd `
#       -- [out=tmp/declutter] [window=1280x720] [phase=after] [seed=3]
#
#   plan   the planning zoom (0.35): the bomber, its three steps, the fighters' thin plans, the ribbon and the flown track
#   zoom1  zoom 1: the bomber and its first steps close, the lettering at its largest
#
# phase picks what is saved and under which data:
#   before   the data as it stood before this track (run this on the code before the change; it reads nothing new)
#   after    the data as it stands: <w>_plan_after.png, <w>_zoom1_after.png, and the weapon arcs switched off with the
#            roster's button (pressed as a mouse click on its rect): <w>_plan_arcs_off.png, <w>_zoom1_arcs_off.png
#   each     the new defaults with ONE old line put back by data at a time (<w>_plan_only_<line>.png): which switch is which line
#   legacy   the old look put back BY DATA ALONE (the switches this track added, flipped back): proves each is reversible
# Files are named <width>x<height>_<view>_<phase-or-variant>.png.

const World = preload("res://scripts/sim/world.gd")
const StrikePlay = preload("res://scripts/test_support/strike_play.gd")

const BOMBER := "bomber_1"

# The old defaults, by data path (phase legacy): what Track C changed and what it was.
const LEGACY := {
	"marker.leader_to_roster": true,
	"marker.trails.whole_flight_line": true,
	"planner.clamp_marks": true,
	"planner.cones.overhead_footprint": true,
	"labels.px": 11.0,
	"labels.font.italic": true,
	"labels.font.weight": 400.0,
	"labels.halo_px": 3.0,
}
const LEGACY_ROLES := {
	"label_ink": {"base": "ink", "alpha": 0.82},
	"label_carry": {"base": "ink", "alpha": 0.58},
	"label_halo": {"base": "paper", "alpha": 0.9},
}

var out_dir := "tmp/declutter"
var opts: Dictionary = {}
var size := Vector2i(1280, 720)
var phase := "after"
var main: Node = null
var sb: Node = null
var _failures := 0
var _frame_no := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[declutter-shot] needs a windowed run: under --headless nothing is drawn")
		quit(1)
		return
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	out_dir = str(opts.get("out", out_dir))
	if out_dir.is_relative_path():
		out_dir = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(out_dir)
	phase = str(opts.get("phase", phase))
	var win := str(opts.get("window", "1280x720")).split("x")
	if win.size() == 2:
		size = Vector2i(int(win[0]), int(win[1]))
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame
		_frame_no += 1

func _say(msg: String) -> void:
	print("[declutter-shot] ", msg)

func _fog_busy() -> bool:
	var lod: int = sb.fog.topo.lod_for_zoom(sb.ctl.zoom_level())
	return sb.fog.bakes_in_flight() > 0 or not sb.fog.wanted_chunks(sb.fog.view_rect_px(), lod).is_empty()

func _wait_view(max_s: float = 90.0) -> void:
	var t := Time.get_ticks_msec()
	await _frames(2)
	while sb.map_view.missing_in_view(true) > 0 or _fog_busy():
		if (Time.get_ticks_msec() - t) / 1000.0 > max_s:
			printerr("[declutter-shot] view not complete after %.0f s" % max_s)
			break
		await process_frame
	await _frames(14)

func _shot(file: String) -> void:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := out_dir.path_join(file)
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1

func _until(cond: Callable, max_ms: int) -> bool:
	var t := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t > max_ms:
			return false
		await process_frame
		_frame_no += 1
	return true

# Sets a ui.json value at a dotted path at run time (the shared style's own dictionary).
func _set_data(path: String, value: Variant) -> void:
	var st = sb.ui.style
	var parts := path.split(".")
	var cur: Dictionary = st.ui
	for i in parts.size() - 1:
		cur = cur[parts[i]]
	cur[parts[parts.size() - 1]] = value

func _legacy() -> void:
	for path: String in LEGACY:
		if sb.ui.style.lookup(path) == null:
			printerr("[declutter-shot] legacy: no data at %s" % path)
			_failures += 1
			continue
		_set_data(path, LEGACY[path])
	# (the roles are resolved at load: put the old ones back through the style's own resolver)
	for role: String in LEGACY_ROLES:
		sb.ui.style._roles[role] = sb.ui.style._resolve(role, LEGACY_ROLES[role])

func _run() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	DisplayServer.window_set_size(size)
	root.size = size
	await _frames(10)
	_say("window %s, viewport %s, phase %s" % [str(DisplayServer.window_get_size()), str(root.get_viewport().get_visible_rect().size), phase])
	var scene: PackedScene = load("res://scenes/main.tscn")
	main = scene.instantiate()
	root.add_child(main)
	await _frames(6)
	if not main.start_sandbox():
		printerr("[declutter-shot] Local did not start the sandbox")
		quit(1)
		return
	sb = main.sandbox
	var t := Time.get_ticks_msec()
	while not sb.is_playable and Time.get_ticks_msec() - t < 240000:
		await process_frame
	if sb.scenario.id != "strike":
		printerr("[declutter-shot] the scenario is %s, not the strike" % sb.scenario.id)
		_failures += 1
	var w: World = sb.world
	var ui = sb.ui
	w.rng_seed = int(opts.get("seed", 3))
	sb.scenario.view["result_card_delay_s"] = 9999.0
	await _wait_view()
	var planner = StrikePlay.for_world(w)

	# Three turns through the real flow: a ribbon, a flown track, the fighters' plans.
	for turn_no in range(1, 4):
		var ok := await _until(func() -> bool: return w.phase == World.PHASE_PLANNING and not ui.is_playing() and w.turn == turn_no, 180000)
		if not ok:
			printerr("[declutter-shot] turn %d never came" % turn_no)
			_failures += 1
			break
		planner.plan_players()
		ui.press_ready()
		await _until(func() -> bool: return w.turn > turn_no and not ui.is_playing() and w.phase == World.PHASE_PLANNING, 180000)
	_say("turn %d is being planned" % w.turn)
	planner.plan_players()   # the fighters' plans stay on the map as thin lines

	# The bomber: three steps, each asked for beyond its envelope (so each is clamped).
	ui.select(BOMBER)
	ui.planner.clear()
	var u = w.units[BOMBER]
	var at := Vector2(float(u.x), float(u.y))
	var dir := Vector2.from_angle(float(u.heading))
	var asks: Array[Vector2] = []
	var turns := [0.0, -0.22, 0.2]
	var head := float(u.heading)
	var from := at
	for k in 3:
		head += float(turns[k])
		var want := from + Vector2.from_angle(head) * 700.0
		var s: Dictionary = ui.planner.place_point(want)
		asks.append(want)
		if s.is_empty():
			printerr("[declutter-shot] step %d was refused" % (k + 1))
			_failures += 1
			break
		from = Vector2(float(s["x"]), float(s["y"]))
	var clamped := 0
	for st: Dictionary in ui.planner.states(BOMBER):
		if bool(st["planned"]) and bool(st["clamped"]):
			clamped += 1
	_say("the bomber has %d steps planned, %d of them clamped" % [ui.planner.planned_count(BOMBER), clamped])
	var end_of_plan := from
	var first_end := Vector2(float((ui.planner.states(BOMBER)[0] as Dictionary)["x"]), float((ui.planner.states(BOMBER)[0] as Dictionary)["y"]))

	var tag := phase
	if phase == "legacy":
		_legacy()
	await _view_plan(at, end_of_plan)
	await _shot("%dx%d_plan_%s.png" % [size.x, size.y, tag])
	await _view_zoom1(at, first_end)
	await _shot("%dx%d_zoom1_%s.png" % [size.x, size.y, tag])

	if phase == "each":
		# The new defaults with ONE of the old lines put back by data at a time (the same plan view): which switch brings which line.
		var each := {"leader": "marker.leader_to_roster", "track_line": "marker.trails.whole_flight_line",
			"clamp_mark": "planner.clamp_marks", "overhead_footprint": "planner.cones.overhead_footprint"}
		await _view_plan(at, end_of_plan)
		await _shot("%dx%d_plan_only_none.png" % [size.x, size.y])
		for name: String in each:
			var path: String = each[name]
			var was: Variant = sb.ui.style.lookup(path)
			_set_data(path, true)
			await _frames(6)
			await _shot("%dx%d_plan_only_%s.png" % [size.x, size.y, name])
			_set_data(path, was)
		await _frames(4)

	if phase == "after":
		# The weapon arcs off, by the roster's own button (a real click on its rect).
		if not ui.roster.has_method("arcs_button_rect"):
			printerr("[declutter-shot] the roster has no arcs button")
			_failures += 1
		else:
			var r: Rect2 = ui.roster.arcs_button_rect()
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = true
			ev.position = r.get_center()
			ui.roster._gui_input(ev)
			_say("the arcs button pressed: arcs are %s" % ("shown" if ui.arcs_shown() else "hidden"))
			if ui.arcs_shown():
				_failures += 1
			await _view_plan(at, end_of_plan)
			await _shot("%dx%d_plan_arcs_off.png" % [size.x, size.y])
			await _view_zoom1(at, first_end)
			await _shot("%dx%d_zoom1_arcs_off.png" % [size.x, size.y])
			ev.position = r.get_center()
			ui.roster._gui_input(ev)
			_say("pressed again: arcs are %s" % ("shown" if ui.arcs_shown() else "hidden"))
			if not ui.arcs_shown():
				_failures += 1
	main.stop_sandbox()
	quit(1 if _failures > 0 else 0)

# The planning zoom: the whole of the bomber's plan in the free part of the window.
func _view_plan(from_m: Vector2, to_m: Vector2) -> void:
	var mid := (from_m + to_m) * 0.5
	sb.ctl.stop_follow()
	sb.ctl.set_view(mid * sb.map_view.px_per_m, 0.35)
	await _wait_view()

# Zoom 1: the bomber and its first step, near the middle of the free area.
func _view_zoom1(from_m: Vector2, to_m: Vector2) -> void:
	var mid := from_m.lerp(to_m, 0.45)
	sb.ctl.stop_follow()
	sb.ctl.set_view(mid * sb.map_view.px_per_m, 1.0)
	await _wait_view()
