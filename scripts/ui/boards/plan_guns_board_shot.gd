extends SceneTree

# BOARD: THE MAIN GUNS' FIRE MARK (board guns-mark, backlog D8; builder BP, 2026-10-14). WINDOWED ONLY.
#
#   .\tools\shot.ps1 -Script res://scripts/ui/boards/plan_guns_board_shot.gd -Out variants/guns-mark -Sheet
#
# Alex: "The main guns fire mark is not, we need a better option." and (decision no-ink-marks) "Generally I don't like the ink mark
# indicators, lets not propose them again". Today (G0) a step with Main Guns fire draws a dashed line from its node to the target, a ring at the
# scatter's two sigma, a small shell beside the node and an X at the target. Five options, ONE data switch (data/ui/ui.json guns.marks.mode,
# scripts/ui/gun_marks.gd), drawn by the game's own planner in the running sandbox over Hold the bridge (data/scenarios/bridge.json, seed 55;
# scripts/ui/boards/plan_rig.gd), the same scenes for every option, WITH the target selection drawn (scripts/ui/target_art.gd) and the plan at
# the weight board's P2 (planner.weight.preset P2: the two boards agree):
#
#   coast   the cruiser at its station, a point on the coast 800 m off (a tank spots it), the whole shot at the start zoom 0.35, the target end
#           and the ship end at zoom 1.0
#   bridge  a point by the bridge, 2.7 km from the ship (the real shot of the mission), the target end at zoom 1.0 and 0.35
#   water   a point in the river, a spray not a dust, zoom 1.0 and 0.35
#   tank    a tank's gun at an enemy tank 120 m up the road (a direct shot: no scatter), zoom 1.0
#
# Output (out=): every crop as <option>_<scene>_z<zoom>[_ship].png at native size, board.json ("chosen": null for Alex), frames.json.
# EVERY OPTION AND VALUE IS PROPOSED by builder BP.

const PlanRig = preload("res://scripts/ui/boards/plan_rig.gd")
const GunMarks = preload("res://scripts/ui/gun_marks.gd")

const SEED := 55
const SHIP := "cruiser_1"

const OPTIONS := [
	{"id": "g0", "mode": "G0", "label": "G0 · Today", "line": "The reference: a dashed line from the node, a ring at the shells' two-sigma scatter, a small shell beside the node and an X at the target."},
	{"id": "g1", "mode": "G1", "label": "G1 · Scatter wash, quiet line", "line": "The scatter as a soft wash under one thin rim (the range of motion's grammar), the one-sigma core a shade deeper, a quiet solid line from the node. No X, no shell."},
	{"id": "g2", "mode": "G2", "label": "G2 · The shells' arc", "line": "The trajectory: a light curve from the ship, tapering up in weight and tone to the target and ending in the scatter wash. No X, no shell."},
	{"id": "g3", "mode": "G3", "label": "G3 · Previewed puffs", "line": "The landing area as faint soft puffs, one per shell: dust on land, spray on water. No line, no ring, no X."},
	{"id": "g4", "mode": "G4", "label": "G4 · Arc, wash and puffs (proposed best)", "line": "The arc, the scatter wash and a few faint puffs in it: where it comes from, how wide it falls and what it will raise."},
]

var out_dir := "variants/guns-mark"
var rig: PlanRig = null
var frames: Array = []
var failures := 0
var base := ""
var _facts: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[guns-mark-board] ", msg)

func _run() -> void:
	base = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	rig = PlanRig.new(self)
	if not await rig.start(false):
		printerr("[guns-mark-board] ", rig.errors)
		quit(1)
		return
	var w = rig.w
	rig.style.ui["planner"]["weight"]["preset"] = "P2"
	var bridge := rig.unit_at("bridge_1")
	var ship := rig.unit_at(SHIP)
	# the enemy tanks stay out of the frames
	for id: String in ["tank_e1", "tank_e2", "tank_e3", "tank_e4"]:
		rig.put(id, Vector2(100.0, 100.0), 0.0)
	var ship_plan := [{"turn": 0.0, "speed": 6.0}]

	# --- bridge: a point by the bridge, the mission's real shot ---
	var t_bridge := bridge + Vector2(-25.0, -170.0)
	await _scene("bridge", ship_plan, Vector2.ZERO, t_bridge, "", [{"zoom": 1.0, "at": "target", "size": Vector2i(560, 380)}, {"zoom": 0.35, "at": "target", "size": Vector2i(560, 380)}])
	# --- water: a point in the river just east of the bridge ---
	var t_water := bridge + Vector2(70.0, 0.0)
	_say("river point %s: water %.1f m" % [str(t_water), float(w.water_depth_at(t_water.x, t_water.y))])
	await _scene("water", ship_plan, Vector2.ZERO, t_water, "", [{"zoom": 1.0, "at": "target", "size": Vector2i(560, 380)}, {"zoom": 0.35, "at": "target", "size": Vector2i(560, 380)}])

	# --- coast: a point on the coast near the ship, spotted by a tank stood beside it ---
	var coast := _coast_target(ship, bridge)
	_say("coast target %s, %.0f m from the ship" % [str(coast.round()), ship.distance_to(coast)])
	rig.put("tank_1", coast + Vector2(-35.0, 55.0), 0.0)
	rig.put("tank_2", coast + Vector2(-60.0, 90.0), 0.0)
	await _scene("coast", ship_plan, Vector2.ZERO, coast, "", [
		{"zoom": 0.35, "at": "mid", "size": Vector2i(700, 640)},
		{"zoom": 1.0, "at": "target", "size": Vector2i(560, 380)},
		{"zoom": 1.0, "at": "ship", "size": Vector2i(560, 380), "tag": "_ship"}])

	# --- tank: a direct shot, the tank's gun at an enemy tank up the road ---
	var p := rig.road_point(-160.0)
	var h := rig.road_heading(-160.0)
	rig.put("tank_1", p, h, 0.0)
	rig.put("tank_2", p + Vector2(40.0, 40.0), h, 0.0)
	rig.put("tank_e1", rig.road_point(-40.0), h + PI, 0.0)
	await _tank_scene(h)

	rig.style.ui["planner"]["weight"]["preset"] = "P0"
	rig.style.ui["guns"]["marks"]["mode"] = "G0"
	_write_json()
	await rig.shutdown()
	quit(1 if failures > 0 else 0)

# The first land on the line from the ship toward the bridge, then 40 m further inland (a point on the coast the guns reach).
func _coast_target(ship: Vector2, bridge: Vector2) -> Vector2:
	var dir := (bridge - ship).normalized()
	var d := 150.0
	while d < 2400.0:
		var q := ship + dir * d
		if rig.w.water_depth_at(q.x, q.y) <= 0.0:
			break
		d += 10.0
	var land := ship + dir * (maxf(d + 40.0, 700.0))
	return land

# A scene of the cruiser: its plan, the fire set on a point `target` (the unit `unit` when given), then each view photographed per option.
func _scene(sid: String, ship_plan: Array, _off: Vector2, target: Vector2, unit: String, views: Array) -> void:
	var w = rig.w
	w.clear_plan(SHIP)
	rig.ui.select(SHIP)
	rig.ui.planner.clear()
	rig.plan(SHIP, ship_plan)
	rig.ui.select("")
	rig.ui.select(SHIP)
	rig.ui.planner.set_focus_step(0)
	if unit != "":
		rig.ui.set_target_unit(unit)
	else:
		rig.ui.target.set_point(target)
	var st: Dictionary = rig.ui.planner.toggle_drop()
	if st.is_empty() or not rig.ui.planner.step_has_fire(0):
		failures += 1
		printerr("[guns-mark-board] scene %s: the fire could not be set: %s | %s" % [sid, str(w.last_error), rig.ui.orders.bomb_caption()])
		return
	await rig.frames(3)
	var node := Vector2(float(rig.ui.planner.states(SHIP)[0]["x"]), float(rig.ui.planner.states(SHIP)[0]["y"]))
	var info: Dictionary = rig.ui.planner.fire_info(0)
	_facts[sid] = {"range_m": snappedf(float(info.get("range_m", 0.0)), 1.0), "spread_m": snappedf(float(info.get("spread_m", 0.0)), 0.1), "target": [snappedf(target.x, 1.0), snappedf(target.y, 1.0)], "on_water": w.water_depth_at(target.x, target.y) > 0.0}
	_say("scene %s: fire on, range %.0f m, sigma %.1f m (two sigma %.0f m), target on water %s" % [sid, float(info.get("range_m", 0.0)), float(info.get("spread_m", 0.0)), 2.0 * float(info.get("spread_m", 0.0)), str(_facts[sid]["on_water"])])
	for v: Dictionary in views:
		var z: float = v["zoom"]
		var at_m: Vector2 = target if str(v["at"]) == "target" else (node if str(v["at"]) == "ship" else (node + target) * 0.5)
		await rig.view(at_m, z)
		var size: Vector2i = v["size"]
		for o: Dictionary in OPTIONS:
			rig.style.ui["guns"]["marks"]["mode"] = str(o["mode"])
			rig.ui.planner.queue_redraw()
			await rig.frames(4)
			var img: Image = await rig.grab()
			var crop := rig.crop(img, at_m, size / 2, size)
			var f := "%s_%s_z%s%s.png" % [o["id"], sid, str(z), str(v.get("tag", ""))]
			_save(crop, f)
			frames.append({"file": f, "option": o["id"], "title": "%s  ·  %s  ·  zoom %s%s" % [o["label"], sid, str(z), " (the ship's end)" if str(v.get("tag", "")) == "_ship" else ""],
				"caption": "%s Scene '%s': %s. 1:1 crop of the game's own frame, the target selection drawn." % [o["line"], sid, _scene_text(sid)], "scene": sid, "zoom": z, "size": [crop.get_width(), crop.get_height()]})
			if str(o["id"]) == "g0" and sid == "coast" and z < 0.5:
				_save(img, "context_coast_z0.35.png")
				frames.append({"file": "context_coast_z0.35.png", "option": "g0", "title": "context: the coast shot at the start zoom, today's marks, the whole frame", "caption": "The whole 1280 x 720 frame (G0).", "scene": sid, "zoom": z, "size": [1280, 720]})
	rig.style.ui["guns"]["marks"]["mode"] = "G0"

# The tank's gun: a direct shot. tank_1 selected, one step planned (a short one), the gun ordered at the enemy tank 120 m up the road.
func _tank_scene(_h: float) -> void:
	var w = rig.w
	var id := "tank_1"
	w.clear_plan(id)
	rig.ui.select("")
	rig.ui.select(id)
	rig.ui.planner.clear()
	rig.plan(id, [{"turn": 0.0, "speed": 5.0}])
	rig.ui.select("")
	rig.ui.select(id)
	rig.ui.planner.set_focus_step(0)
	rig.ui.set_target_unit("tank_e1")
	var st: Dictionary = rig.ui.planner.toggle_drop()
	if st.is_empty() or not rig.ui.planner.step_has_fire(0):
		_say("the tank scene: the gun could not be set (%s | %s): left out" % [str(w.last_error), rig.ui.orders.bomb_caption()])
		return
	await rig.frames(3)
	var a := rig.unit_at(id)
	var t := rig.unit_at("tank_e1")
	var mid := (a + t) * 0.5
	await rig.view(mid, 1.0)
	for o: Dictionary in OPTIONS:
		rig.style.ui["guns"]["marks"]["mode"] = str(o["mode"])
		rig.ui.planner.queue_redraw()
		await rig.frames(4)
		var img: Image = await rig.grab()
		var crop := rig.crop(img, mid, Vector2i(260, 200), Vector2i(520, 400))
		var f := "%s_tank_z1.0.png" % str(o["id"])
		_save(crop, f)
		frames.append({"file": f, "option": o["id"], "title": "%s  ·  tank  ·  zoom 1.0" % o["label"],
			"caption": "%s Scene 'tank': %s. 1:1 crop of the game's own frame." % [o["line"], _scene_text("tank")], "scene": "tank", "zoom": 1.0, "size": [crop.get_width(), crop.get_height()]})
	rig.style.ui["guns"]["marks"]["mode"] = "G0"

func _scene_text(sid: String) -> String:
	match sid:
		"coast":
			return "the cruiser's Main Guns on a point on the coast about 800 m away (a tank beside it spots it); the whole shot at the start zoom, then the target end and the ship's end at zoom 1"
		"bridge":
			return "the cruiser's Main Guns on a point on the road beyond the bridge, 2.9 km away (the mission's real shot, the spread at its widest); the target end"
		"water":
			return "the cruiser's Main Guns on a point in the river by the bridge (the shells will raise spray); the target end"
		"tank":
			return "a tank's gun ordered at an enemy tank 120 m up the road: a direct shot, one aimed round, no scatter"
	return sid

func _save(img: Image, file: String) -> void:
	var err := img.save_png(base.path_join(file))
	if err != OK:
		failures += 1
		printerr("[guns-mark-board] could not write ", file)

func _write_json() -> void:
	var st = rig.style
	var opts: Array = []
	for o: Dictionary in OPTIONS:
		var rec: Variant = st.ui["guns"]["marks"].get(str(o["mode"]), {})
		var vals: Dictionary = (rec as Dictionary).duplicate(true) if rec is Dictionary else {}
		for k: String in vals.keys():
			if k.begins_with("_"):
				vals.erase(k)
		opts.append({"id": o["id"], "label": o["label"], "description": o["line"], "guns.marks.mode": o["mode"], "values": vals, "proposed": true})
	var doc := {
		"id": "guns-mark",
		"date": "2026-10-14",
		"area": "UI",
		"question": "How is a planned Main Guns fire drawn on the map? Alex: 'The main guns fire mark is not, we need a better option.' (decision no-ink-marks: 'Generally I don't like the ink mark indicators, lets not propose them again', so no option is a small drawn symbol.)",
		"source": "scripts/ui/boards/plan_guns_board_shot.gd on scripts/ui/boards/plan_rig.gd: the running sandbox over Hold the bridge (data/scenarios/bridge.json, seed 55, fog off), the game's own planner (scripts/ui/motion_planner.gd _draw_fire_marks, scripts/ui/gun_marks.gd), photographed once per option with ONLY data/ui/ui.json guns.marks.mode changed",
		"seed": SEED,
		"held_constant": {
			"scenes": "coast (a point on the coast ~800 m from the cruiser, the whole shot at zoom 0.35, the target end and the ship's end at zoom 1), bridge (a point by the bridge, 2.7 km from the ship, target end at zoom 1 and 0.35), water (a point in the river by the bridge, zoom 1 and 0.35), tank (a tank's gun, a direct shot)",
			"facts": _facts,
			"target_selection": "drawn in every frame (scripts/ui/target_art.gd: a ring with a dot for a point, brackets for a unit); no option draws on it",
			"plan_weight": "planner.weight.preset P2 in every frame, G0 included, so the plan line and its nodes are the plan-weight board's P2 and the two boards agree (the 'today' of G0 is its marks, not the plan's weight)",
			"crops": "the same crop for every option of a scene and view",
		},
		"options": opts,
		"palette_check": {
			"hue": "No option adds a hue: the line, the arc and the rims are INK at an alpha (hover_ink, fan_rim 50%); the wash is the range of motion's (fan_wash, ink 14%); the paper halo is path_halo (paper 85%); the puffs are the gunfire board's G3 dust (the dirt ink lightened toward the paper, gun_puff_dust) and a pale paper disc for spray (gun_puff_water), their outline ink 55% x outline_k. The side colour appears only in the unit markers.",
			"lightness": "A ramp off the paper: arc 22 to 80% ink, wash 14% (28% at the core), rim 50%, dust 42% of a lightened dirt, spray 70% of paper.",
			"material": "linework and soft tone: a line, a curve, a rim, a wash, scalloped puffs; no symbol.",
		},
		"recommendation_proposed": "PROPOSED by builder BP (Alex decides): G4, the arc, the scatter wash and a few faint puffs. The arc says where it comes from and that it is an artillery lob, not a flat shot; the wash says how wide it falls (and is the same grammar as the range of motion, so it reads as 'the area' at once); the puffs say what it will raise, dust or spray, so the player sees the land or the river they are shelling. If that is too much on a busy map, G1 is the quietest that still shows the scatter (a wash and a line), and G3 the most distinctive but with no line from the ship.",
		"how_to_switch": "set guns.marks.mode in data/ui/ui.json to G0, G1, G2, G3 or G4",
		"chosen": null,
		"chosen_by": null,
	}
	_write(base.path_join("board.json"), doc)
	_write(base.path_join("frames.json"), {
		"id": "guns-mark",
		"about": "Every frame of the guns-mark board as its own PNG at native size: <option>_<scene>_z<zoom>[_ship].png are 1:1 crops of the game's own frames (the same crop for every option of a scene and view), context_coast_z0.35.png the whole 1280 x 720 frame of G0.",
		"frames": frames,
	})

func _write(path: String, doc: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[guns-mark-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)
