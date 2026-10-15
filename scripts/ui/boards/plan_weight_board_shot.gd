extends SceneTree

# BOARD: THE WEIGHT OF THE PLAN INDICATORS (board plan-weight, backlog A8; builder BP, 2026-10-14). WINDOWED ONLY.
#
#   .\tools\shot.ps1 -Script res://scripts/ui/boards/plan_weight_board_shot.gd -Out variants/plan-weight -Sheet
#
# Alex (decision plan-indicators-bold): "We need to make the plan indicators on the map much bolder to be visible. There is too much visual
# noise to see a thin dashed lines and tiny dots." DECIDED: much bolder; the weights are picked on this board. Five options P0 .. P4, ONE data
# switch (data/ui/ui.json planner.weight.preset, scripts/ui/plan_weight.gd), drawn by the game's own planner in the running sandbox over
# Hold the bridge (data/scenarios/bridge.json, seed 55; scripts/ui/boards/plan_rig.gd), the same scenes for every option:
#
#   road    the selected tank's 2-step plan on the road through the woods, a second tank's plan beside it   zoom 1.0 and the start zoom 0.35
#   carry   the selected tank with ONE step planned (its second step flies on, the carry-on path), the other tank with no plan (it flies on)    zoom 1.0
#   village the same two tanks on the road through the village (houses, fields)                              zoom 1.0 and 0.35
#   forest  the same two tanks in the thick woods east of the road (trees, shadows)                          zoom 1.0 and 0.35
#   smoke   the same, with a grove burning beside the path (the forest fire's smoke)                         zoom 1.0 and 0.35
#
# Output (out=): every crop as <option>_<scene>_z<zoom>.png at native size, context_<scene>_z0.35.png whole 1280 x 720 frames (P0), board.json
# ("chosen": null for Alex) and frames.json. EVERY OPTION AND VALUE IS PROPOSED by builder BP.

const PlanRig = preload("res://scripts/ui/boards/plan_rig.gd")

const SEED := 55
const CROP_Z1 := Vector2i(520, 300)
const CROP_Z035 := Vector2i(400, 240)

const OPTIONS := [
	{"id": "p0", "preset": "P0", "label": "P0 · Today", "line": "The reference: the selected path 1.6 px, its carry-on 1.0 px dashed, nodes 3 px, the others' plans 1.0 px with 1.9 px nodes, the range of motion's rim 0.9 px."},
	{"id": "p1", "preset": "P1", "label": "P1 · 2x, still dashed", "line": "Every weight doubled: path 3.2 px, carry-on 2.0 px still dashed, nodes 6 px, the others 2.0 px and 3.8 px nodes, rim 1.8 px. No halo."},
	{"id": "p2", "preset": "P2", "label": "P2 · 2x, solid, paper halo", "line": "2x and a paper halo under every ink line so it reads over hatching and forest: path 3.2 px, carry-on solid 2.2 px, nodes 6 px with a paper rim, the others 2.0 px with a lighter halo, rim 1.8 px."},
	{"id": "p3", "preset": "P3", "label": "P3 · 3x, solid, halo, big nodes", "line": "3x with the halo: path 4.8 px, carry-on solid 3.2 px, nodes as ink discs 7.5 px with a 2.4 px paper rim, the others 3.0 px with 5 px nodes, rim 2.7 px."},
	{"id": "p4", "preset": "P4", "label": "P4 · Bold solid path, quiet dashed carry", "line": "The path 4.0 px solid with a halo, the carry-on a quieter 2.0 px dash with a light halo, nodes 6.5 px discs with a paper rim, the others 2.4 px, rim 2.2 px."},
]

const PLAN_A := [{"turn": 0.35, "speed": 10.0}, {"turn": -0.3, "speed": 10.0}]     # the selected tank, two steps
const PLAN_B := [{"turn": -0.45, "speed": 8.0}, {"turn": 0.0, "speed": 8.0}]       # the second tank, two steps, veering to the west
const PLAN_A1 := [{"turn": 0.3, "speed": 10.0}]                                      # the selected tank, ONE step (the second flies on)

var out_dir := "variants/plan-weight"
var rig: PlanRig = null
var frames: Array = []
var failures := 0
var base := ""

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[plan-weight-board] ", msg)

func _run() -> void:
	base = ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	rig = PlanRig.new(self)
	if not await rig.start(true):
		printerr("[plan-weight-board] ", rig.errors)
		quit(1)
		return
	var w = rig.w
	var bridge := rig.unit_at("bridge_1")
	_say("bridge %s" % str(bridge))
	var plan_a := [{"turn": 0.3, "speed": 10.0}, {"turn": -0.3, "speed": 10.0}]
	var plan_b := [{"turn": 0.55, "speed": 9.0}, {"turn": -0.1, "speed": 9.0}]
	# --- road: both tanks on the road through the woods short of the village ---
	_stand_on_road(-170.0)
	await _scene("road", "tank_1", "tank_2", plan_a, plan_b, [1.0, 0.35])
	# --- carry: the same place, ONE step planned and the second flying on; the other tank without a plan ---
	await _scene("carry", "tank_1", "tank_2", PLAN_A1, [], [1.0])
	# --- village: the road through the village, the houses and the fields ---
	_stand_on_road(-405.0)
	await _scene("village", "tank_1", "tank_2", plan_a, plan_b, [1.0, 0.35])
	# --- forest: the road where the woods close in on both sides, the plan veering into the trees ---
	var plan_fa := [{"turn": 0.45, "speed": 9.0}, {"turn": 0.1, "speed": 9.0}]
	var plan_fb := [{"turn": 0.4, "speed": 9.0}, {"turn": -0.1, "speed": 9.0}]
	_stand_on_road(-262.0)
	await _scene("forest", "tank_1", "tank_2", plan_fa, plan_fb, [1.0, 0.35])
	# --- smoke: a grove burning beside the path (the forest fire's smoke) ---
	var at := rig.road_point(-262.0)
	_light_trees(at + Vector2(30.0, -42.0), 36.0)
	await _scene("smoke", "tank_1", "tank_2", plan_fa, plan_fb, [1.0, 0.35])

	_write_json()
	await rig.shutdown()
	quit(1 if failures > 0 else 0)

# One scene: the units planned, each zoom framed on the selected unit's plan, every option photographed.
func _scene(sid: String, sel: String, other: String, plan_sel: Array, plan_other: Array, zooms: Array, keep: bool = false) -> void:
	var w = rig.w
	for id: String in [sel, other]:
		w.clear_plan(id)
	rig.plan(sel, plan_sel)
	if not plan_other.is_empty():
		rig.plan(other, plan_other)
	rig.ui.select(sel)
	rig.ui.planner.set_focus_step(plan_sel.size() - 1)
	await rig.frames(3)
	var st: Array = rig.ui.planner.states(sel)
	var a := rig.unit_at(sel)
	var b := Vector2(float(st[plan_sel.size() - 1]["x"]), float(st[plan_sel.size() - 1]["y"]))
	var mid := (a + b) * 0.5
	_say("scene %s: the plan runs %s -> %s (%.0f m)" % [sid, str(a.round()), str(b.round()), a.distance_to(b)])
	for z: float in zooms:
		await rig.view(mid, z)
		var size: Vector2i = CROP_Z1 if z >= 0.9 else CROP_Z035
		for o: Dictionary in OPTIONS:
			rig.style.ui["planner"]["weight"]["preset"] = str(o["preset"])
			rig.ui.planner.queue_redraw()
			await rig.frames(4)
			var img: Image = await rig.grab()
			var crop := rig.crop(img, mid, size / 2, size)
			var f := "%s_%s_z%s.png" % [o["id"], sid, str(z)]
			_save(crop, f)
			frames.append({"file": f, "option": o["id"], "title": "%s  ·  %s  ·  zoom %s" % [o["label"], sid, str(z)],
				"caption": "%s. Scene '%s': %s. 1:1 crop of the game's own frame." % [o["line"], sid, _scene_text(sid)], "scene": sid, "zoom": z, "size": [crop.get_width(), crop.get_height()]})
			if str(o["id"]) == "p0" and z < 0.5:
				_save(img, "context_%s_z0.35.png" % sid)
				frames.append({"file": "context_%s_z0.35.png" % sid, "option": "p0", "title": "context: %s at the start zoom, today's weights, the whole frame" % sid,
					"caption": "The whole 1280 x 720 frame at the start zoom (0.35), P0.", "scene": sid, "zoom": z, "size": [1280, 720]})
	rig.style.ui["planner"]["weight"]["preset"] = "P0"

func _scene_text(sid: String) -> String:
	match sid:
		"road":
			return "the selected tank's 2-step plan on the road by the bridge, a second tank's 2-step plan beside it (the quieter one)"
		"village":
			return "the same two tanks on the road through the village (houses, fields, trees)"
		"carry":
			return "the selected tank with one step planned and its second step flying on (the carry-on path), the second tank with no plan (it flies on, dashed)"
		"forest":
			return "the same two tanks with their plans over the woods (trees and their shadows)"
		"smoke":
			return "the same, with a grove burning beside the path (the forest fire's smoke)"
	return sid

func _save(img: Image, file: String) -> void:
	var err := img.save_png(base.path_join(file))
	if err != OK:
		failures += 1
		printerr("[plan-weight-board] could not write ", file)

func _density(p: Vector2) -> float:
	var woods: Callable = rig.w.ground.woods_fn
	return float(woods.call(p.x, p.y)) if woods.is_valid() else 0.0

# The thickest woods on dry land within 350 m of the bridge, on the east side of the road (where the opening view shows them): the best mean density
# over a 25 m ring, so the plan runs through trees, not past them.
func _woods_spot(bridge: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_d := -1.0
	for dy in range(40, 321, 10):
		for dx in range(40, 321, 10):
			var p := bridge + Vector2(dx, dy)
			if rig.w.water_depth_at(p.x, p.y) > 0.0:
				continue
			var s := 0.0
			var n := 0
			for k in 8:
				var q := p + Vector2.from_angle(float(k) * TAU / 8.0) * 25.0
				s += _density(q)
				n += 1
			var d := s / float(n) + _density(p)
			if d > best_d:
				best_d = d
				best = p
	return best

# Both tanks on the road `road_m` metres from the bridge, facing the bridge: the second one off the road's east edge and a step behind.
func _stand_on_road(road_m: float) -> void:
	var p := rig.road_point(road_m)
	var h := rig.road_heading(road_m)
	rig.put("tank_1", p, h, 8.0)
	rig.put("tank_2", p + Vector2(34.0, 30.0), h, 8.0)

# Sets the trees within `reach` metres of `at` alight (the forest fire, decision forest-fire): the smoke the draw shows.
func _light_trees(at: Vector2, reach: float) -> void:
	var w = rig.w
	if w.fire == null or w.fire.source == null:
		_say("no fire in this world: the smoke scene shows none")
		return
	var n := 0
	for t: Dictionary in w.fire.source.trees_in_disc(at.x, at.y, reach):
		if w.fire.add_lit(t, 0, 0.0, "bomb"):
			n += 1
	_say("%d trees alight" % n)
	if rig.scene.sb.has_method("_update_fire_view"):
		rig.scene.sb.call("_update_fire_view")

func _write_json() -> void:
	var st = rig.style
	var opts: Array = []
	for o: Dictionary in OPTIONS:
		var rec: Dictionary = (st.ui["planner"]["weight"].get(str(o["preset"]), {}) as Dictionary).duplicate(true)
		for k: String in rec.keys():
			if k.begins_with("_"):
				rec.erase(k)
		opts.append({"id": o["id"], "label": o["label"], "description": o["line"], "planner.weight.preset": o["preset"], "values": rec, "proposed": true})
	var doc := {
		"id": "plan-weight",
		"date": "2026-10-14",
		"area": "UI",
		"question": "How bold are the plan indicators on the map (the selected unit's path, its carry-on path, the step nodes, the other units' plans and the range of motion's rim)? Alex (decision plan-indicators-bold): 'We need to make the plan indicators on the map much bolder to be visible. There is too much visual noise to see a thin dashed lines and tiny dots.' DECIDED: much bolder; the weights are picked here.",
		"source": "scripts/ui/boards/plan_weight_board_shot.gd on scripts/ui/boards/plan_rig.gd: the running sandbox over Hold the bridge (data/scenarios/bridge.json, seed 55, fog off), the game's own planner (scripts/ui/motion_planner.gd _draw_curve), photographed once per option with ONLY data/ui/ui.json planner.weight.preset changed",
		"seed": SEED,
		"held_constant": {
			"scenes": "road (the selected tank's 2-step plan on the road through the woods, a second tank's plan), carry (one step planned, the second flies on; the second tank flies on), village (the road through the village), forest (the same in thick woods), smoke (a grove burning beside the path)",
			"zooms": "zoom 1.0 (2 px per metre) and the start zoom 0.35 (data/view/camera.json zoom.start)",
			"crops": "the same crop for every option of a scene, centred on the middle of the selected tank's plan: %s at zoom 1, %s at 0.35" % [str(CROP_Z1), str(CROP_Z035)],
			"in_force": "planner on top of the unit markers (decision planner-on-top); wash_rim range of motion (decision motion-range-look); shadow strength 0.44; pen shadow_side; sides brick red and slate blue",
			"others_rule": "in every option the other units' plans are one clear step quieter than the selected unit's: thinner, smaller nodes, 55% alpha",
		},
		"options": opts,
		"palette_check": {
			"hue": "No option adds a hue: the plan is INK (the role path at 90%, path_carry at 50%) and the halo and node rim PAPER (the new role path_halo, paper at 85%). The side colour appears only in the unit's own marker, ribbon and ghost.",
			"lightness": "A ramp off the paper: halo paper 85%, path ink 90%, carry-on ink 50%, the others' plans ink x 55%, the range of motion's wash 14% and rim 50%.",
			"material": "linework: a line, a disc, a paper halo. No hex in draw code (the roles are in data/ui/ui.json roles).",
		},
		"recommendation_proposed": "PROPOSED by builder BP (Alex decides): P2, 2x solid with the paper halo (P4 if the carry-on should keep reading as a dash, flying on). The halo is what carries the plan over trees, houses and smoke; thickness alone (P1) is still a dark line lost among tree shadows. P3 is the boldest that still reads as a line, but its 7.5 px discs crowd a tank's two steps (25 m apart, 17 px at the start zoom). Honest limit: at the start zoom 0.35 a tank's whole plan is about 30 px, so beyond P2 the selection disc and the labels, not the weight, are what is seen; a tank's step is short.",
		"how_to_switch": "set planner.weight.preset in data/ui/ui.json to P0, P1, P2, P3 or P4; the range of motion's rim, the nodes and the hover dots follow it",
		"chosen": null,
		"chosen_by": null,
	}
	_write(base.path_join("board.json"), doc)
	_write(base.path_join("frames.json"), {
		"id": "plan-weight",
		"about": "Every frame of the plan-weight board as its own PNG at native size: <option>_<scene>_z<zoom>.png are 1:1 crops of the game's own frames (520 x 300 at zoom 1, 400 x 240 at 0.35, the same crop for every option of a scene), context_<scene>_z0.35.png whole 1280 x 720 frames of P0.",
		"frames": frames,
	})

func _write(path: String, doc: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[plan-weight-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)
