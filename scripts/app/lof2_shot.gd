extends SceneTree

# THE LINES OF FIRE, STAGE 2: THE PROOFS (builder LOF2, 2026-10-12; decision line-of-fire). WINDOWED ONLY -- under --headless nothing is drawn
# (scripts/tests/test_line_of_fire_combat.gd is the headless proof).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --script res://scripts/app/lof2_shot.gd -- [what=all|sections|cover|compare|table] [out=tmp/lof2] [seed=11] [turns=14]
#
# what=sections  PROOF 1 again, with the low bridge and the spread rows: a1_/a2_ across the bridge (it was a solid 6.5 m slab: the tanks at its two
#                ends now see each other), a3_ a tank on the deck behind the parapet, c_ behind the sandbags.
# what=cover     PROOF 2, cover_bridge_55.png: Hold the bridge's map at the window's native 1600 x 900 (2 px a metre), shaded by how much of an
#                enemy tank at each spot the player's first tank could see: red fully visible, amber hull-down, blue hidden.
# what=compare   PROOF 4: the same seeded turns of Hold the bridge with the lines off and on (compare_off.png, compare_on.png): every shot of the
#                tanks drawn from the muzzle to where it went (on: the box a hit struck, what a miss landed on), with the numbers printed.
# what=table     PROOF 4, odds_table.png: a tank's gun against a tank at 100, 200 and 350 m, old and new, in the open, behind the parapet, sandbags
#                and a house.

const LofCases = preload("res://scripts/test_support/lof_cases.gd")
const LofSection = preload("res://scripts/render/boards/lof_section.gd")
const LofCover = preload("res://scripts/render/boards/lof_cover.gd")
const LofEvents = preload("res://scripts/render/boards/lof_events.gd")
const LofShapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const LofOddsTable = preload("res://scripts/test_support/lof_odds_table.gd")
const BridgePlay = preload("res://scripts/test_support/bridge_play.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const CombatLines = preload("res://scripts/sim/combat_lines.gd")
const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")

const SIZE := Vector2i(1600, 900)

var out_dir := "tmp/lof2"
var opts: Dictionary = {}
var _failures := 0

# The key, in screen space over the map.
class Legend extends Node2D:
	var title := ""
	var rows: Array = []
	var notes: Array = []
	var bottom := false
	func _draw() -> void:
		var font := ThemeDB.fallback_font
		var h := 40.0 + 18.0 * rows.size() + 16.0 * notes.size()
		var top := 10.0 if not bottom else 890.0 - h
		var w := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x + 20.0
		for r: Array in rows:
			w = maxf(w, 34.0 + font.get_string_size(str(r[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 20.0)
		for n in notes:
			w = maxf(w, font.get_string_size(str(n), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 30.0)
		draw_rect(Rect2(10, top, w, h), Color(0.97, 0.95, 0.9, 0.93))
		draw_rect(Rect2(10, top, w, h), Color(0.2, 0.15, 0.1), false, 1.0)
		draw_string(font, Vector2(20, top + 20), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.15, 0.1, 0.05))
		var y := top + 34.0
		for r: Array in rows:
			draw_rect(Rect2(20, y, 16, 14), r[0])
			draw_string(font, Vector2(44, y + 12), str(r[1]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.1, 0.1, 0.1))
			y += 18.0
		for n in notes:
			draw_string(font, Vector2(20, y + 10), str(n), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.25, 0.2, 0.15))
			y += 16.0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("[lof2-shot] needs a windowed run: under --headless nothing is drawn")
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
	print("[lof2-shot] ", msg)

func _run() -> void:
	var what := str(opts.get("what", "all"))
	if what == "sections" or what == "all":
		await _sections()
	if what == "cover" or what == "all":
		await _cover()
	if what == "compare" or what == "all":
		await _compare()
	if what == "table" or what == "all":
		await _table()
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

# --- proof 1 again: the side views ---------------------------------------------------------------------------------------

func _sections() -> void:
	var cases: Array = []
	var bs := LofCases.ProbeScene.new(LofCases.BRIDGE)
	cases.append(["a1_across_the_bridge_ground", LofCases.case_bridge(bs, 45.0, "A: a tank against a tank across the LOW bridge, both on the ground at the two ends (Hold the bridge, seed 55)",
		["The deck is level with the banks (0 m) with a 1 m stone parapet along each side (Alex: '(c) A low bridge'); tank 1 is 45 m before the bridge's middle on the road, tank 2 45 m beyond.",
		"The roadway is level, so a line along the road is clear: the tanks see each other (the stage 1 slab, 6.5 m high, hid them). The parapets stand beside the line."])])
	cases.append(["a2_across_the_bridge_deck", LofCases.case_bridge(bs, 14.0, "A: the same tanks on the deck, 28 m apart: on the bridge a tank stands at the deck, 0 m",
		["Both tanks are on the deck cells, level with the banks; the parapets are 7.5 m off the line."])])
	var par := LofCases.case_parapet(bs, 40.0, "A3: a tank on the deck, its front 1 m behind the near parapet, a gun 40 m off the bridge's side (Hold the bridge)",
		["The parapet is 1 m of stone, 1 m in front of the tank; the gun's muzzle is 2.3 m up, 33 m from the parapet.",
		"The hull (0 to 1.5 m, six rows, the top at 1.45 m) shows above 1 m only where the line clears the stone; the turret (1.5 to 2.3 m) is over it."])
	cases.append(["a3_behind_the_parapet", par])
	var ss := LofCases.ProbeScene.new(LofCases.STRIKE)
	var tower: Vector2 = ss.grid.terrain.layout().sites()["radio_tower"]
	ss.grid.build_rect(Rect2(tower.x - 300.0, tower.y - 300.0, 600.0, 600.0))
	var c := LofCases.case_sandbags(ss, "C: a tank behind the anti-aircraft battery's sandbags (the Strike), the spread rows",
		["The ring is 1.15 m high; the tank is 7.5 m behind its middle, the gun 46 m before it.",
		"The hull has six rows (0.05 to 1.45 m) and each stands for the band round it; the top two clear the bags (together 0.31 of the hull); the turret is over them."])
	if not c.is_empty():
		cases.append(["c_behind_the_sandbags", c])
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
				parts.append("%s %d/%d (%.2f)" % [bx["part"], bx["reached"], bx["samples"], float(bx["share"])])
			_say("%s - %s: %s; %.0f%% in view" % [entry[0], t["label"], ", ".join(parts), float(t["exposure"]["share"]) * 100.0])
		vp.queue_free()
		await _frames(2)

# --- the map under a proof ------------------------------------------------------------------------------------------------

# A MapView of seed 55 at 2 px a metre in a SubViewport of the window's size, centred on `centre`, waited for until baked.
func _map(scene: LofCases.ProbeScene, centre: Vector2, zoom: float = 1.0) -> Array:
	var vp := SubViewport.new()
	vp.size = SIZE
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.disable_3d = true
	root.add_child(vp)
	var view := MapView.new(scene.seed_value, Rect2(), 0.0, "", null, scene.water)
	view.input_enabled = false
	vp.add_child(view)
	view.set_zoom(zoom)
	view.look_at_m(centre)
	return [vp, view]

func _wait_map(view: MapView) -> void:
	var t1 := Time.get_ticks_msec()
	await _frames(2)
	while view.missing_in_view() > 0 or view.pending() > 0:
		if (Time.get_ticks_msec() - t1) / 1000.0 > 120.0:
			printerr("[lof2-shot] the map was not complete after 120 s")
			_failures += 1
			break
		await process_frame
	await _frames(6)

# The bridge and the player's first tank on seed 55: {scene, view rect centre, tank id, muzzle}.
func _bridge_scene() -> Dictionary:
	var sc := LofCases.ProbeScene.new(LofCases.BRIDGE)
	var site: Dictionary = sc.water.sites()["bridge"]
	var road: PackedVector2Array = sc.ground.road
	var idx: int = site["road_index"]
	sc.add("bridge_1", "bridge", site["pos"], float(site["heading"]))
	var a := GroundMap.road_point(road, idx, -45.0)
	var b := GroundMap.road_point(road, idx, 0.0)
	sc.add("tank_1", "tank", a, (b - a).angle())
	var along := (GroundMap.road_point(road, idx, 60.0) - GroundMap.road_point(road, idx, -60.0)).normalized()
	var centre: Vector2 = (site["pos"] as Vector2) + along * 150.0
	return {"scene": sc, "centre": centre, "tank": "tank_1", "site": site}

# --- proof 2: the cover map ----------------------------------------------------------------------------------------------------

func _cover() -> void:
	var bsn := _bridge_scene()
	var sc: LofCases.ProbeScene = bsn["scene"]
	var centre: Vector2 = bsn["centre"]
	var mv := _map(sc, centre)
	var vp: SubViewport = mv[0]
	var view: MapView = mv[1]
	var half := Vector2(SIZE) * 0.5 / view.px_per_m
	var rect := Rect2(centre - half, half * 2.0)
	var muzzle := sc.muzzle(sc.pose(str(bsn["tank"])))
	var cm := LofCover.new()
	view.live_layer.add_child(cm)
	var t0 := Time.get_ticks_msec()
	cm.setup(sc.lof, sc.grid, sc.grid.rules, sc.world.unit_def("tank"), Vector3(muzzle[0], muzzle[1], muzzle[2]), rect, 3.0)
	_say("cover map of %s m made in %.1f s: %s" % [str(rect.size), (Time.get_ticks_msec() - t0) / 1000.0, str(cm.stats)])
	var layer := CanvasLayer.new()
	vp.add_child(layer)
	var leg := Legend.new()
	leg.title = "COVER MAP: how much of an enemy tank at each spot tank_1 (black dot) could see"
	var counts: Dictionary = cm.stats["counts"]
	leg.rows = [[Color(0.92, 0.12, 0.08, 0.6), "fully visible (95 percent or more of the tank): %d cells" % counts["full"]],
		[Color(1.0, 0.5, 0.0, 0.8), "hull-down (turret in view, hull mostly hidden behind low solid cover): %d cells" % counts["hull_down"]],
		[Color(1.0, 0.88, 0.1, 0.7), "partly screened (some lines stopped, e.g. by thin tree crowns): %d cells" % counts["partly"]],
		[Color(0.12, 0.3, 0.95, 0.6), "hidden: nothing in view, the gun holds: %d cells" % counts["hidden"]]]
	leg.notes = ["Hold the bridge, seed 55. An enemy tank is put in every 3 m cell facing tank_1, on the ground or the deck;",
		"clear = water, houses, walls (nowhere to stand). Rings: 100, 200 and 350 m. Trees stop a line with the data's chance.",
		"The road is open (red); off it the thin trees screen part of the tank or all of it; the NE wood hides tanks."]
	layer.add_child(leg)
	await _wait_map(view)
	await _save(vp, "cover_bridge_55.png")
	view.baker.clear()
	vp.queue_free()
	await _frames(2)

# --- proof 4: the same seeded turns, off and on ----------------------------------------------------------------------------------

func _compare() -> void:
	var seed_v := int(opts.get("seed", 11))
	var turns := int(opts.get("turns", 14))
	var runs: Array = []
	for on in [false, true]:
		var g := BridgePlay.new(seed_v)
		if not g.ok():
			printerr("[lof2-shot] the game did not build: ", g.errors)
			_failures += 1
			return
		if on:
			g.scenario.attach_lines_of_fire(g.world)
		g.play("defend", turns)
		runs.append(g)
		_say("the %s run: %d turns, %d events" % ["ON" if on else "OFF", turns, g.events.size()])
	var bsn := _bridge_scene()
	var sc: LofCases.ProbeScene = bsn["scene"]
	var site: Dictionary = bsn["site"]
	var weapons := ["turret_gun"]
	# two views of each run: the whole road (2 px a metre) and the bridge close up (6 px a metre)
	var views := [["wide", bsn["centre"], 1.0, false], ["bridge", (site["pos"] as Vector2) + (bsn["centre"] - (site["pos"] as Vector2)).normalized() * 25.0, 3.0, true]]
	for v: Array in views:
		for k in 2:
			var g: BridgePlay = runs[k]
			var mv := _map(sc, v[1], float(v[2]))
			var vp: SubViewport = mv[0]
			var view: MapView = mv[1]
			var ev := LofEvents.new()
			ev.mark = 1.0 / float(v[2])
			var bu: Object = sc.world.units["bridge_1"]
			ev.outlines = LofShapes.world_boxes(bu.def, sc.grid.rules, float(bu.x), float(bu.y), float(bu.heading), 0.0)
			view.live_layer.add_child(ev)
			ev.setup(g.events, weapons, view.px_per_m, "ON" if k == 1 else "OFF")
			var c: Dictionary = ev.counts
			if v[0] == "wide":
				_say("%s: tank shots %d, hits %d, misses %d; boxes struck %s; misses landed on %s" % ["ON" if k == 1 else "OFF", c["fire"], c["hit"], c["miss"], str(c["by_box"]), str(c["by_material"])])
			var layer := CanvasLayer.new()
			vp.add_child(layer)
			var leg := Legend.new()
			leg.bottom = false
			leg.title = "HOLD THE BRIDGE, dice seed %d, %d turns - lines of fire %s%s" % [g.world.rng_seed, turns, "ON" if k == 1 else "OFF (old rules)", "" if v[0] == "wide" else ", close up"]
			if k == 1:
				leg.rows = [[Color(0.95, 0.5, 0.05), "a hit on the HULL (%d)" % int(c["by_box"].get("hull", 0))], [Color(0.85, 0.05, 0.05), "a hit on the TURRET (%d)" % int(c["by_box"].get("turret", 0))]]
				for m in ["stone", "earth", "wood", "water", "air"]:
					leg.rows.append([LofEvents.MAT_COLORS[m], "a miss that landed on %s (%d)" % [m if m != "air" else "nothing: lost in the air", int(c["by_material"].get(m, 0))]])
			else:
				leg.rows = [[Color(0.55, 0.0, 0.0), "a hit (%d), on the tank's middle" % int(c["hit"])], [Color(0.35, 0.35, 0.35), "a miss (%d): no landing is known" % int(c["miss"])]]
			leg.notes = ["%d shots in all: %d hit, %d missed. Black squares: the muzzles. The low bridge is outlined (deck grey, parapets violet)." % [int(c["fire"]), int(c["hit"]), int(c["miss"])]]
			layer.add_child(leg)
			await _wait_map(view)
			await _save(vp, "compare_%s_%s.png" % ["on" if k == 1 else "off", v[0]])
			view.baker.clear()
			vp.queue_free()
			await _frames(2)

# --- proof 4: the odds table -----------------------------------------------------------------------------------------------------

class TableView extends Node2D:
	var rows: Array = []
	func _draw() -> void:
		var font := ThemeDB.fallback_font
		draw_rect(Rect2(0, 0, 1000, 560), Color(0.97, 0.95, 0.9))
		draw_string(font, Vector2(20, 34), "A TANK'S GUN AGAINST A STILL TANK: the chance per shot, old model and new", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.1, 0.07, 0.03))
		draw_string(font, Vector2(20, 58), "old: 0.12 in every cell (flat to 350 m, cover did not count).  new: the share of the round's spread on what is in view.", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.25, 0.2, 0.15))
		var seen: Array[String] = []
		for r: Dictionary in rows:
			if not seen.has(str(r["situation"])):
				seen.append(str(r["situation"]))
		var x0 := [20.0, 470.0, 600.0, 730.0, 860.0]
		var y := 100.0
		for i in 4:
			draw_string(font, Vector2(x0[i + 1] if i < 3 else x0[4], 90), ["100 m", "200 m", "350 m", "old"][i], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.1, 0.07, 0.03))
		for s in seen:
			draw_line(Vector2(20, y - 18), Vector2(980, y - 18), Color(0.7, 0.65, 0.55), 1.0)
			draw_string(font, Vector2(x0[0], y + 6), s, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.1, 0.07, 0.03))
			var col := 1
			for r: Dictionary in rows:
				if str(r["situation"]) == s:
					var txt := ("%.3f" % float(r["odds"])) if bool(r["visible"]) else "held"
					var cc := Color(0.1, 0.07, 0.03) if bool(r["visible"]) else Color(0.1, 0.3, 0.9)
					draw_string(font, Vector2(x0[col], y + 6), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, cc)
					draw_string(font, Vector2(x0[col], y + 22), "view %.2f" % float(r["share"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.4, 0.35, 0.3))
					col += 1
			draw_string(font, Vector2(x0[4], y + 6), "0.120", HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(0.5, 0.45, 0.4))
			y += 52.0
		draw_string(font, Vector2(20, y + 22), "held: nothing of the tank is in view, so the gun does not fire (Alex: 'otherwise we would just mow down anything in between on purpose').", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.25, 0.2, 0.15))
		draw_string(font, Vector2(20, y + 42), "view: the share of the target's silhouette in view. The spread is 17.67 mrad (PROPOSED), calibrated to 0.12 at 200 m averaged over all sides.", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.25, 0.2, 0.15))

func _table() -> void:
	var t := LofOddsTable.new()
	var rows := t.compute()
	print(LofOddsTable.to_text(rows))
	var tv := TableView.new()
	tv.rows = rows
	var vp := SubViewport.new()
	vp.size = Vector2i(1000, 560)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	vp.add_child(tv)
	await _save(vp, "odds_table.png")
	vp.queue_free()
	await _frames(2)
