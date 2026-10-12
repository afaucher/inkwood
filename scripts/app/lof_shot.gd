extends SceneTree

# THE LINES OF FIRE, STAGE 1: THE TWO PROOFS (builder LOF1, 2026-10-11; decision line-of-fire). WINDOWED ONLY -- under --headless nothing
# is drawn (scripts/tests/test_line_of_fire.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --script res://scripts/app/lof_shot.gd -- [what=all|grid|sections] [out=tmp/lof]
#
# what=grid      PROOF 3, the height grid over the real map, at the window's native pixels (1600 x 900, the map at 4 px per metre, so a 1 m
#                cell is 4 px): the real map is baked as the game bakes it (MapView with the seed's water), and over it scripts/render/boards/lof_overlay.gd
#                draws the cells (height and material), the canopies, the 16 m blocks and the 256 m chunks.
#                  grid_bridge_55.png      Hold the bridge (seed 55) round the bridge: the river, the deck (violet, 6.5 m)
#                  grid_village_strike.png the Strike (seed 20261009) round the radio tower: the compound's walls, the houses, the road
#                  grid_battery_strike.png the Strike's first battery: its sandbag ring (green, 1.15 m)
# what=sections  PROOF 1, side views of real lines of fire (scripts/test_support/lof_cases.gd places the units; scripts/render/boards/lof_section.gd
#                draws the strip): a1_ a2_ across the bridge, b_ behind a house, c_ behind the sandbags, d_ a low-band plane behind a hill.

const LofCases = preload("res://scripts/test_support/lof_cases.gd")
const LofSection = preload("res://scripts/render/boards/lof_section.gd")
const LofOverlay = preload("res://scripts/render/boards/lof_overlay.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const HeightGrid = preload("res://scripts/sim/height_grid.gd")

const SIZE := Vector2i(1600, 900)

var out_dir := "tmp/lof"
var opts: Dictionary = {}
var _failures := 0

# The key, in screen space over the map.
class Legend extends Node2D:
	var title := ""
	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_rect(Rect2(10, 10, 420, 206), Color(0.97, 0.95, 0.9, 0.92))
		draw_rect(Rect2(10, 10, 420, 206), Color(0.2, 0.15, 0.1), false, 1.0)
		draw_string(font, Vector2(20, 30), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.15, 0.1, 0.05))
		var rows: Array = [
			[Color(1.0, 0.8, 0.05, 0.6), "terrain step, 12 m"], [Color(1.0, 0.45, 0.0, 0.7), "terrain step, 24 m"], [Color(0.15, 0.45, 1.0, 0.6), "water, 0 m"],
			[Color(0.95, 0.1, 0.85, 0.8), "stone: walls (number: height, m)"], [Color(0.95, 0.15, 0.1, 0.8), "timber: houses"], [Color(0.1, 0.8, 0.15, 0.9), "earthworks: sandbags"],
			[Color(0.55, 0.25, 0.95, 0.8), "deck: stone a unit stands on"], [Color(0.0, 0.55, 0.1, 0.9), "crown: circle at its radius, top height in it"]]
		var y := 44.0
		for r: Array in rows:
			draw_rect(Rect2(20, y, 16, 14), r[0])
			draw_string(font, Vector2(44, y + 12), str(r[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.1, 0.1, 0.1))
			y += 18.0
		draw_string(font, Vector2(20, y + 10), "grey lines: 16 m blocks (heavy: 256 m chunks); clear: ground at 0 m", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.25, 0.2, 0.15))

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[lof-shot] needs a windowed run: under --headless nothing is drawn")
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
	_run.call_deferred()

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _say(msg: String) -> void:
	print("[lof-shot] ", msg)

func _run() -> void:
	var what := str(opts.get("what", "all"))
	if what == "sections" or what == "all":
		await _sections()
	if what == "grid" or what == "all":
		await _grids()
	_say("failures %d" % _failures)
	quit(1 if _failures > 0 else 0)

func _save(vp: SubViewport, file: String) -> void:
	await _frames(3)
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var path := out_dir.path_join(file)
	var err := img.save_png(path)
	_say("saved %s (%s, %s)" % [path, str(img.get_size()), error_string(err)])
	if err != OK:
		_failures += 1

# --- proof 1: the side views --------------------------------------------------------------------------------------------

func _sections() -> void:
	var t0 := Time.get_ticks_msec()
	var cases: Array = []
	# a: across the bridge (Hold the bridge's map)
	var bs := LofCases.ProbeScene.new(LofCases.BRIDGE)
	cases.append(["a1_across_the_bridge_ground", LofCases.case_bridge(bs, 45.0, "A: a tank against a tank across the bridge, both on the ground at the two ends (Hold the bridge, seed 55)",
		["Tank 1 is 45 m before the bridge's middle on the road, tank 2 45 m beyond; the bridge is a solid 40 m x 16 m slab to the water, stamped from the bridge unit (deck 6.5 m).",
		"In 2.5D the deck has one height per cell, so there is no room under it: a low line along the road meets the slab's end."])])
	cases.append(["a2_across_the_bridge_deck", LofCases.case_bridge(bs, 14.0, "A: the same tanks on the deck, 28 m apart: a tank on the bridge stands on the deck (6.5 m), not on the river",
		["Both tanks are on the deck cells, so their base is the deck's top and the line runs along the deck."])])
	# b, c, d: the Strike
	var ss := LofCases.ProbeScene.new(LofCases.STRIKE)
	var tower: Vector2 = ss.grid.terrain.layout().sites()["radio_tower"]
	ss.grid.build_rect(Rect2(tower.x - 300.0, tower.y - 300.0, 600.0, 600.0))
	var b := LofCases.case_house(ss, "B: a tank behind a house (the Strike's village, seed 20261009)",
		["A house of the village's own geometry, its height the structure's own h over the map scale (timber).", "The enemy tank stands 7 m behind the house's far wall; the gun is 36 m in front of it."])
	if b.is_empty():
		printerr("[lof-shot] no house gave a clean case")
		_failures += 1
	else:
		cases.append(["b_behind_a_house", b])
	var c := LofCases.case_sandbags(ss, "C: a tank behind the anti-aircraft battery's sandbags (the Strike)",
		["The ring is 8 m across, 1 m of bags, 1.15 m high, stamped from the battery unit's shape; the tank is 7.5 m behind its middle, the gun 46 m before it.",
		"The hull's top row (1.25 m) clears the bags (1.15 m); the lower rows meet them; the turret (1.5 to 2.3 m) is over them."])
	if c.is_empty():
		_failures += 1
	else:
		cases.append(["c_behind_the_sandbags", c])
	ss.grid.build_rect(Rect2(tower.x - 800.0, tower.y - 800.0, 1600.0, 1600.0))
	var scarp := LofCases.find_scarp(ss.grid, Rect2i(ss.grid.chunk_of(tower.x - 800.0, tower.y - 800.0), Vector2i(7, 7)), 33, 20.0)
	if scarp.is_empty():
		scarp = LofCases.find_scarp(ss.grid, Rect2i(ss.grid.chunk_of(tower.x - 800.0, tower.y - 800.0), Vector2i(7, 7)), 33, 5.0)
	if scarp.is_empty():
		printerr("[lof-shot] no scarp to put the hill case on")
		_failures += 1
	else:
		var d := LofCases.case_hill(ss, "D: a low-band plane behind a hill (the Strike): the nearer plane is in view, the farther is behind the scarp",
			["Planes fly at their band's height above sea level, whatever is under them (the low band, 120 m); the scarp is the terrain's own step.",
			"A gun 30 m before the scarp's foot; both planes are on the same line."], scarp)
		cases.append(["d_plane_behind_a_hill", d])
	_say("cases built in %.1f s" % [(Time.get_ticks_msec() - t0) / 1000.0])
	for entry: Array in cases:
		var s := LofSection.new()
		s.setup(entry[1])
		var vp := SubViewport.new()
		vp.size = Vector2i(ceili(s.size_px.x), ceili(s.size_px.y))
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		vp.transparent_bg = false
		root.add_child(vp)
		vp.add_child(s)
		await _save(vp, str(entry[0]) + ".png")
		for t: Dictionary in (entry[1]["targets"] as Array):
			var parts: PackedStringArray = []
			for bx: Dictionary in t["exposure"]["boxes"]:
				parts.append("%s %d/%d" % [bx["part"], bx["reached"], bx["samples"]])
			_say("%s - %s: %s; %.0f%% in view" % [entry[0], t["label"], ", ".join(parts), float(t["exposure"]["share"]) * 100.0])
		vp.queue_free()
		await _frames(2)

# --- proof 3: the grid over the map ---------------------------------------------------------------------------------------------

func _grids() -> void:
	# Hold the bridge round the bridge
	var water55 := WaterGen.shared(LofCases.BRIDGE)
	var s55 := LofCases.ProbeScene.new(LofCases.BRIDGE)
	var site: Dictionary = water55.sites()["bridge"]
	s55.add("bridge_1", "bridge", site["pos"], float(site["heading"]))
	await _grid_shot(s55, site["pos"], "grid_bridge_55.png", "Hold the bridge (seed 55): the height grid over the map")
	# the Strike round the tower, and the first battery
	var ss := LofCases.ProbeScene.new(LofCases.STRIKE)
	var lay: RefCounted = ss.grid.terrain.layout()
	var sites: Dictionary = lay.sites()
	var tower: Vector2 = sites["radio_tower"]
	var bsite: Dictionary = ss.water.sites()["bridge"]
	ss.add("bridge_1", "bridge", bsite["pos"], float(bsite["heading"]))
	ss.add("radio_tower_1", "radio_tower", tower, 0.0)
	var i := 0
	for bat: Vector2 in (sites["aa_battery"] as Array):
		i += 1
		ss.add("aa_battery_%d" % i, "anti_aircraft_battery", bat, 0.0)
	await _grid_shot(ss, tower, "grid_village_strike.png", "The Strike (seed 20261009): the village and the radio tower's compound")
	await _grid_shot(ss, (sites["aa_battery"] as Array)[0], "grid_battery_strike.png", "The Strike: the first anti-aircraft battery's sandbag ring")

func _grid_shot(scene: LofCases.ProbeScene, centre: Vector2, file: String, title: String) -> void:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	root.add_child(vp)
	var view := MapView.new(scene.seed_value, Rect2(), 0.0, "", null, scene.water)
	view.input_enabled = false
	vp.add_child(view)
	view.set_zoom(2.0)
	view.look_at_m(centre)
	var half := Vector2(SIZE) * 0.5 / (view.px_per_m * 2.0)
	var rect := Rect2(centre - half, half * 2.0)
	var ov := LofOverlay.new()
	view.live_layer.add_child(ov)
	var t0 := Time.get_ticks_msec()
	ov.setup(scene.grid, rect)
	_say("%s: overlay of %s m made in %.0f ms: %s" % [file, str(rect.size), Time.get_ticks_msec() - t0, str(ov.stats)])
	var layer := CanvasLayer.new()
	vp.add_child(layer)
	var leg := Legend.new()
	leg.title = title
	layer.add_child(leg)
	# wait for the map
	var t1 := Time.get_ticks_msec()
	await _frames(2)
	while view.missing_in_view() > 0 or view.pending() > 0:
		if (Time.get_ticks_msec() - t1) / 1000.0 > 120.0:
			printerr("[lof-shot] the map was not complete after 120 s")
			_failures += 1
			break
		await process_frame
	await _frames(6)
	_say("%s: the map baked in %.1f s" % [file, (Time.get_ticks_msec() - t1) / 1000.0])
	await _save(vp, file)
	view.baker.clear()
	vp.queue_free()
	await _frames(2)
