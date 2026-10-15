extends SceneTree

# BOARD: THE FOG EDGE (builder BF, 2026-10-14; backlog B15). WINDOWED ONLY.
#
#   .\tools\shot.ps1 -Script res://scripts/render/boards/fog_edge_board_shot.gd -Out variants/fog-edge -Sheet
#   (key=value after the out: only=<scene,...> probe=1 to write whole frames of every scene, tag=<text>)
#
# Alex: "How expensive would it be to smooth the edge of the fog of war? It currently looks pretty blocky."
#
# The game's own fog (scripts/render/fog_layer.gd, fog_composite.gdshader, fog_los_shape.gdshader) in the running sandbox over
# seed 20261009 (variants/fog-edge/scenario.json: a light fighter and a tank of one side, fog on), photographed once per option
# with ONLY data/view/fog.json edge.inked.look (a row of edge.inked.looks; FogLayer.set_look) and viewshed.interp changed.
#
# Scenes, per option: the edge of the light fighter's 800 m sight circle across OPEN ground and across FOREST (found in the
# terrain by tree cover along the arc), each at zoom 1.0 and 0.35; and the edge of a tank's line-of-sight shape in a valley
# (line_of_sight terrain_trees, FogSites.find_valley) at zoom 1.0, today's nearest-ray shape and viewshed.interp true.
# The crops are 1:1 from the game's frame, the same pixels for every option.
#
# EVERY OPTION AND VALUE IS PROPOSED by builder BF; none is a decision.

const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const FogSites = preload("res://scripts/render/fog_viewshed_sites.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")

const SEED := 20261009
const SCENARIO := "../../variants/fog-edge/scenario"
const PLANE := "light_fighter_1"
const TANK := "tank_1"
const SIGHT_M := 800.0
const EDGE_DEG := -35.0                  # the bearing from the plane to the edge point shown
const CROP := Rect2i(240, 150, 800, 420)   # of the 1280 x 720 frame; the edge point is at the frame's centre (640, 360)
const CENTRE := Vector2(640.0, 360.0)
const PARK_PLANE := Vector2(4900.0, 4900.0)
const PARK_TANK := Vector2(100.0, 4900.0)

const OPTIONS := [
	{"id": "e0", "title": "Today", "line": "Value noise, a hard 1 px cut, random tick lengths. Nothing changed."},
	{"id": "e1", "title": "Gradient noise", "line": "Perlin gradient noise in place of value noise, the same 2.5 px peak wobble and the same wave length: the edge has a slope everywhere, so no straight runs and kinks."},
	{"id": "e2", "title": "Gradient noise and a soft cut", "line": "E1, and the cut between the full render and the map is cross-faded over 2.5 px instead of 1 px: no stair-stepped coverage."},
	{"id": "e3", "title": "Two octaves", "line": "E2 with a slow 2.5 px swell (a wave every ~110 px) and a small 0.8 px tremor (every ~22 px): a hand-drawn edge."},
	{"id": "e4", "title": "Smooth hatch", "line": "E2 with the hatch ticks' lengths varying smoothly along the edge (0.55 to 1.0 of the band, a wave every ~17 ticks) instead of at random: one continuous band."},
	{"id": "e5", "title": "Two octaves and smooth hatch", "line": "E3 and E4 together."},
]

var out_dir := "variants/fog-edge"
var tag := ""
var only: PackedStringArray = []
var probe := false
var scene: BoardScene = null
var fog = null
var w = null
var frames_out: Array = []
var crops: Dictionary = {}       # file -> Image
var contexts: Dictionary = {}    # file -> Image
var sites: Dictionary = {}
var cost: Dictionary = {}        # key -> {view_gpu_ms, mask_gpu_ms, cpu_ms}
var opts := {}
var failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
			match kv[0]:
				"out":
					out_dir = kv[1]
				"tag":
					tag = kv[1]
				"only":
					only = kv[1].split("+", false)
				"probe":
					probe = kv[1] == "1"
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[fog-edge-board] ", msg)

func _want(scene_id: String) -> bool:
	return only.is_empty() or only.has(scene_id)

func _run() -> void:
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed %d, scenario %s)..." % [SEED, SCENARIO])
	if not await scene.start(300.0, SCENARIO):
		printerr("[fog-edge-board] ", scene.errors)
		quit(1)
		return
	fog = scene.sb.fog
	w = scene.world()
	scene.sb.ui.hud.visible = false
	scene.sb.clock.visible = false
	scene.sb.ui.set_process_input(false)
	for n: String in ["roster", "orders"]:
		var c: Variant = scene.sb.ui.get(n)
		if c is CanvasItem:
			(c as CanvasItem).visible = false
	if str(fog.vision.line_of_sight) != "none":
		fog.vision.set_line_of_sight("none")
	fog.set_los_interp(false)
	var base_interp: bool = fog.los_interp
	var terrain = scene.sb.terrain
	var open_site := _find_circle_site(terrain, scene.sb.water, false)
	var forest_site := _find_circle_site(terrain, scene.sb.water, true)
	var valley: Dictionary = FogSites.find_valley(terrain, 1500.0, 40.0, true)
	sites = {"open": open_site, "forest": forest_site, "valley": valley}
	_say("open ground edge point %s: %s" % [str(open_site.edge), str(open_site.note)])
	_say("forest edge point %s: %s" % [str(forest_site.edge), str(forest_site.note)])
	_say("valley (the tank) %s: %s" % [str(valley.p), str(valley.note)])

	# The circle scenes (line of sight none): the plane at the circle's centre, the tank parked far away.
	for kind: String in ["open", "forest"]:
		if not _want(kind):
			continue
		var s: Dictionary = sites[kind]
		await _park_and_place(PLANE, s.unit, TANK, PARK_TANK)
		for z: float in [1.0, 0.35]:
			await scene.look(s.edge, CENTRE, z)
			var t: float = await scene.settle()
			_say("%s zoom %s baked in %.1f s" % [kind, str(z), t])
			await _photograph_options("%s_z%s" % [kind, str(z)], kind, z, false, "circle")

	# The line-of-sight scene: the tank in the valley, terrain_trees, the plane parked far away.
	if _want("los"):
		await _park_and_place(TANK, valley.p, PLANE, PARK_PLANE)
		fog.vision.set_line_of_sight("terrain_trees")
		await _wait_sheds()
		var z_los := float(opts.get("losz", "1.0"))
		await scene.look(valley.p + Vector2(float(opts.get("lookx", "380")), float(opts.get("looky", "40"))), CENTRE, z_los)
		await scene.settle()
		await _wait_sheds()
		fog.set_look("e0")
		fog.set_los_interp(false)
		await _grab_into("e0_los", "e0", "los", z_los, "Today: line of sight terrain_trees, the nearest ray (viewshed.interp false), E0 edge")
		for o: Dictionary in OPTIONS:
			fog.set_look(str(o.id))
			fog.set_los_interp(true)
			await scene.frames(4)
			await _grab_into("%s_los_interp" % str(o.id), str(o.id), "los", z_los, "%s: line of sight terrain_trees with viewshed.interp true" % str(o.title))
		# the cost of the shape pass, nearest ray against blended
		for interp: bool in [false, true]:
			fog.set_los_interp(interp)
			await scene.frames(6)
			cost["los_interp_%s" % str(interp)] = await _measure()
		fog.set_los_interp(base_interp)
		fog.vision.set_line_of_sight("none")

	fog.set_look("")
	await _write()
	scene.shutdown()
	await scene.frames(2)
	quit(1 if failures > 0 else 0)

# --- sites ----------------------------------------------------------------------------------------------

# A point on the circle of a plane's sight where the edge crosses open ground (no trees) or forest, found by tree
# cover along 600 m of the arc and in a 120 m disc round the point shown. Ground of one level, away from the coast.
func _find_circle_site(terrain: Object, water: Object, want_forest: bool) -> Dictionary:
	var a := deg_to_rad(EDGE_DEG)
	var dir := Vector2.from_angle(a)
	var best := {"edge": Vector2(2000, 2000), "unit": Vector2(2000, 2000) - dir * SIGHT_M, "score": -INF, "note": "none"}
	var village_centre: Vector2 = terrain.layout().village().centre
	for x in range(1400, 3200, 100):
		for y in range(1400, 3600, 100):
			var e := Vector2(x, y)
			var u := e - dir * SIGHT_M
			var covers: Array = []
			var levels := {}
			var wet := false
			for k in range(-6, 7):
				var p := u + Vector2.from_angle(a + float(k) * 50.0 / SIGHT_M) * SIGHT_M
				covers.append(FogSites.tree_cover(terrain, p, 45.0))
				levels[terrain.level_at(p.x, p.y)] = true
				for dr: float in [-120.0, -60.0, 0.0, 60.0, 120.0]:
					var q := u + Vector2.from_angle(a + float(k) * 50.0 / SIGHT_M) * (SIGHT_M + dr)
					if water != null and water.is_wet(q.x, q.y):
						wet = true
					if q.distance_to(village_centre) < 700.0:
						wet = true   # (not wet: the village's own ground; the board wants plain fields and woods)
			if levels.size() > 1 or wet:
				continue
			var lo := 1.0
			var hi := 0.0
			var mean := 0.0
			for c: float in covers:
				lo = minf(lo, c)
				hi = maxf(hi, c)
				mean += c / float(covers.size())
			var disc := FogSites.tree_cover(terrain, e, 120.0)
			var score := (lo * 4.0 + mean) if want_forest else -(hi * 8.0 + mean + disc * 4.0)
			if want_forest and lo < 0.12:
				continue
			if score > float(best.score):
				best = {"edge": e, "unit": u, "score": score,
					"note": "tree cover along the arc %.2f to %.2f (mean %.2f), %.2f within 120 m" % [lo, hi, mean, disc]}
	return best

# --- the rig --------------------------------------------------------------------------------------------

func _park_and_place(id: String, at: Vector2, other: String, parked: Vector2) -> void:
	var layout := {}
	layout[id] = {"x": at.x, "y": at.y, "heading": deg_to_rad(10.0), "band": "medium"}
	layout[other] = {"x": parked.x, "y": parked.y, "heading": 0.0, "band": "medium"}
	await scene.place(layout)

func _wait_sheds() -> void:
	for i in 900:
		await scene.frames(1)
		if i > 20 and int(fog.vision.stats.pending) == 0:
			break
	await scene.frames(12)

# One scene at one zoom: every option's crop (and, for the first, the whole frame as context).
func _photograph_options(scene_id: String, kind: String, z: float, interp: bool, note: String) -> void:
	fog.set_los_interp(interp)
	for o: Dictionary in OPTIONS:
		fog.set_look(str(o.id))
		await scene.frames(4)
		await _grab_into("%s_%s" % [str(o.id), scene_id], str(o.id), kind, z, "%s: %s, zoom %s" % [str(o.title), kind, str(z)])
	for oid: String in ["e0", "e3", "e5"]:
		fog.set_look(oid)
		await scene.frames(6)
		cost["%s_%s_%s" % [kind, str(z), oid]] = await _measure()
	fog.set_look("e0")

func _grab_into(file_stem: String, option: String, kind: String, z: float, title: String) -> void:
	if only.has("none"):
		return
	var img: Image = await scene.grab()
	var crop := img.get_region(CROP)
	var file := file_stem + tag + ".png"
	crops[file] = crop
	frames_out.append({"file": file, "option": option, "title": title, "caption": "%s, 1:1 crop of the game's own frame (%dx%d from (%d, %d)); the edge point is at the crop's centre-ish" % [title, CROP.size.x, CROP.size.y, CROP.position.x, CROP.position.y],
		"scene": kind, "zoom": z, "size": [crop.get_width(), crop.get_height()]})
	if option == "e0" and not file_stem.ends_with("_interp"):
		contexts["context_" + file_stem.substr(3) + tag + ".png"] = img

# Mean GPU ms of the whole view and of the mask viewport, and the fog's CPU ms a frame, over 60 frames.
func _measure() -> Dictionary:
	var rid: RID = root.get_viewport_rid()
	var mrid: RID = fog.mask_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	RenderingServer.viewport_set_measure_render_time(mrid, true)
	await scene.frames(4)
	var gpu := 0.0
	var mgpu := 0.0
	var cpu := 0.0
	var n := 60
	for i in n:
		await RenderingServer.frame_post_draw
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		mgpu += RenderingServer.viewport_get_measured_render_time_gpu(mrid)
		cpu += (float(fog.stats.mask_us) + float(fog.stats.draw_us)) / 1000.0
	RenderingServer.viewport_set_measure_render_time(rid, false)
	RenderingServer.viewport_set_measure_render_time(mrid, false)
	return {"view_gpu_ms": snappedf(gpu / n, 0.001), "mask_gpu_ms": snappedf(mgpu / n, 0.001), "fog_cpu_ms": snappedf(cpu / n, 0.001)}

# --- output ---------------------------------------------------------------------------------------------

func _palette_image() -> Image:
	var chips: Array = []
	for i in fog.topo.paper_levels.size():
		chips.append(fog.topo.paper_levels[i])
	var line: Color = fog._mat.get_shader_parameter("line_color")
	var hatch: Color = fog._mat.get_shader_parameter("hatch_color")
	var base: Color = fog.topo.paper_levels[0]
	chips.append(Color(base.r * (1.0 - line.a) + line.r * line.a, base.g * (1.0 - line.a) + line.g * line.a, base.b * (1.0 - line.a) + line.b * line.a))
	chips.append(Color(base.r * (1.0 - hatch.a) + hatch.r * hatch.a, base.g * (1.0 - hatch.a) + hatch.g * hatch.a, base.b * (1.0 - hatch.a) + hatch.b * hatch.a))
	var img := Image.create(chips.size() * 100, 70, false, Image.FORMAT_RGBA8)
	for i in chips.size():
		img.fill_rect(Rect2i(i * 100, 0, 100, 70), chips[i])
	return img

func _save(img: Image, path: String) -> void:
	var err := img.save_png(path)
	if err != OK:
		failures += 1
		printerr("[fog-edge-board] could not write ", path, ": ", error_string(err))

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	for f: String in crops:
		_save(crops[f], base.path_join(f))
	for f: String in contexts:
		_save(contexts[f], base.path_join(f))
		frames_out.append({"file": f, "option": "e0", "title": "context: today's edge, the whole 1280 x 720 frame", "caption": "The whole frame the crops are cut from (today's look), so the edge can be seen against the map and the fog's outside", "scene": f.get_basename().substr(8), "zoom": 0.0, "size": [1280, 720]})
	_save(_palette_image(), base.path_join("palette_fog.png"))
	frames_out.append({"file": "palette_fog.png", "option": "all", "title": "the palette the fog edge spends", "caption": "Left to right: the topographic sheet at the three height levels (the paper lifted), then the inked line (ink 90%) and the hatch (ink 55%) over the lowest level. No option adds a colour: every look is the same ink roles, only the shape of the edge differs", "scene": "palette", "zoom": 0.0, "size": [600, 70]})
	var f := FileAccess.open(base.path_join("frames.json"), FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"id": "fog-edge", "about": "Every frame of the fog-edge board as its own PNG at native size: <option>_<scene>.png are 1:1 crops (800 x 420) of the game's frames, the same pixels for every option; <scene> is open_z1.0 / open_z0.35 / forest_z1.0 / forest_z0.35 (the edge of the light fighter's 800 m sight circle across open ground and across forest) or los (the tank's line-of-sight shape in a valley, zoom 1.0: e0_los is today, eN_los_interp has viewshed.interp true); context_* are whole 1280 x 720 frames; palette_fog.png is the swatch row.", "frames": frames_out}, "  ", false))
		f.close()
	var m := FileAccess.open(base.path_join("measured.json"), FileAccess.WRITE)
	if m != null:
		var s2 := {}
		for k: String in sites:
			var d: Dictionary = sites[k]
			s2[k] = {"point": [snappedf(float((d.get("edge", d.get("p", Vector2.ZERO)) as Vector2).x), 0.1), snappedf(float((d.get("edge", d.get("p", Vector2.ZERO)) as Vector2).y), 0.1)], "note": str(d.get("note", ""))}
		m.store_string(JSON.stringify({"sites": s2, "cost": cost}, "  ", false))
		m.close()
	_write_board(base.path_join("board.json"))
	_say("wrote %d frames to %s" % [frames_out.size(), base])

func _write_board(path: String) -> void:
	var opts_out: Array = []
	var looks: Dictionary = fog.fog_data.dict("edge.inked.looks")
	for o: Dictionary in OPTIONS:
		opts_out.append({"name": str(o.id).to_upper(), "title": str(o.title), "description": str(o.line), "edge.inked.look": str(o.id),
			"overrides": looks.get(str(o.id), {}), "file": "%s_open_z1.0.png" % str(o.id), "proposed": true})
	var doc := {
		"id": "fog-edge",
		"date": "2026-10-14",
		"area": "render",
		"question": "How expensive would it be to smooth the edge of the fog of war? Alex: 'How expensive would it be to smooth the edge of the fog of war? It currently looks pretty blocky.' (backlog B15)",
		"source": "scripts/render/boards/fog_edge_board_shot.gd: the running sandbox (scripts/app/sandbox.gd) over the real map, scenario variants/fog-edge/scenario.json (seed 20261009, water on, fog ON), the game's own fog (scripts/render/fog_layer.gd, fog_composite.gdshader, fog_los_shape.gdshader), photographed once per option with ONLY data/view/fog.json edge.inked.look (and viewshed.interp for the line-of-sight frames) changed",
		"seed": SEED,
		"held_constant": {
			"units": "a light fighter (800 m sight circle) and a tank (600 m), one side; the one not shown is parked in a far corner",
			"scenes": {
				"open_z1.0 / open_z0.35": "the edge of the light fighter's sight circle across open ground (found by tree cover along 600 m of the arc: %s), at zoom 1.0 (2 px/m) and 0.35; the edge point at the frame's centre, bearing %d degrees from the plane, line_of_sight none" % [str(sites.get("open", {}).get("note", "")), int(EDGE_DEG)],
				"forest_z1.0 / forest_z0.35": "the same circle edge across forest (%s)" % str(sites.get("forest", {}).get("note", "")),
				"los": "the tank in a valley (%s; FogSites.find_valley) with line_of_sight terrain_trees, zoom 1.0, looking 380 m east of the tank where the viewshed's edge is a run of long, thin dead-ground shadows. e0_los is today (the nearest ray, viewshed.interp false); eN_los_interp is look eN with viewshed.interp true. trees_block is false (decision trees-do-not-block), so terrain_trees draws as terrain" % str(sites.get("valley", {}).get("note", "")),
			},
			"crops": "800 x 420 px, 1:1 from the game's 1280 x 720 frame at (240, 150); the same pixels for every option of a scene",
			"fog_range": "mask.range_px (72) still covers the widest effect of every look (FogLayer checks it on set_look)",
			"decisions_in_force": "edge.mode inked (fog-first-option); trees_block false; the palette: every look uses the same two ink roles (edge.inked.line_role, hatch_role) over the same topographic sheet",
		},
		"measured": {"sites": {"open": str(sites.get("open", {}).get("edge", "")), "forest": str(sites.get("forest", {}).get("edge", "")), "valley": str(sites.get("valley", {}).get("p", ""))}, "cost": cost,
			"cost_note": "mean over 60 frames, RTX 3080, windowed 1280 x 720: view_gpu_ms is the WHOLE frame's GPU time (map, markers and fog), mask_gpu_ms the mask viewport's three line-of-sight passes (0 in analytic mode), fog_cpu_ms the layer's own CPU. No option adds a pass, a texture or a viewport; the differences are inside the frame-to-frame noise (a first pass read 1.07, 1.13 and 1.15 ms for e0, e3 and e5 at forest zoom 0.35 and this one 0.76, 1.35 and 1.67: the GPU's clock moves between runs, so these numbers cannot rank the looks, only bound the cost)"},
		"parameter": "data/view/fog.json#edge.inked.look (e0 | e1 | e2 | e3 | e4 | e5: a row of edge.inked.looks, which overrides edge.inked.wobble_noise, cut_soft_px, wobble_px, wobble_per_px, wobble2_px, wobble2_per_px, hatch_length, hatch_length_min, hatch_length_per_tick) and data/view/fog.json#viewshed.interp (line of sight only: false = the nearest ray, true = the two rays either side blended; viewshed.interp_spread 2.0)",
		"options": opts_out,
		"palette_check": {"hue": "No option adds a hue: every mark is the fog's existing ink roles (line ink 90%, hatch ink 55%) over the topographic sheet (paper lifted, desaturated); only the SHAPE of the edge changes.", "lightness": "unchanged: a ramp off the paper, the sheet at three levels, the line and hatch at their existing alphas (palette_fog.png)", "material": "linework: the inked line and the hatch ticks; the soft cut is a 2.5 px cross-fade between the full render and the sheet, not a new tone"},
		"recommendation_proposed": "PROPOSED by builder BF (Alex decides): E3, two octaves of gradient noise with the 2.5 px cut, WITH viewshed.interp true. The blockiness of the circle is value noise's flat runs and kinks (E1 removes them at no cost); the soft cut (E2) removes the stair-stepped coverage of the cut itself; two octaves (E3) keep the hand-drawn wander a printed map's edge has and a pure gradient edge would lose. E4 and E5 smooth the hatch's lengths: they read tidier, but the ragged random fringe is part of the inked look Alex accepted (fog-first-option), so they are offered as the alternative, not the recommendation. Line of sight is the other half: with it on the sector steps are the blockiest edge in the game, and viewshed.interp true removes them in the same pass at no measurable cost.",
		"how_to_switch": "set data/view/fog.json edge.inked.look to the option's id (e0..e5), and viewshed.interp to true for line of sight; nothing else changes. FogLayer.set_look(id) / set_los_interp(on) do the same at run time.",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
