extends SceneTree

# BOARD: SELECTING PATH NODES (Track U2, the first fight). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/node_hover_board_shot.gd -- [out=variants/node-hover]
#
# Alex (2026-10-10): "We also need a visual indicator for selecting path nodes.
# It is hard to tell when you are close enough." Today a press within
# planner.handle_px of a planned step's end grabs that step, and nothing shows it
# beforehand. This stands up the RUNNING SANDBOX (seed 20261009, the real map and
# fog) over the same dense grove the stand-out board uses, selects the light
# fighter with a four-step plan running through it -- its plan line, its ghosts,
# its speed labels and the brick-red cone wash all in view -- and photographs the
# SECOND step's handle with the pointer at four distances, once per hover style,
# at zoom 1 and at the far play zoom 0.35:
#
#   far          3 x the pick radius from the handle (nothing shows)
#   approaching  1.5 x the radius (inside planner.hover.near_factor x the radius)
#   in range     0.6 x the radius (a press would grab THIS handle)
#   dragging     the step held (begin_edit), the pointer 0.15 x the radius away
#
# ONLY data/ui/ui.json planner.hover.mode changes between options (the chosen
# style lands in data as that one value). The pointer is drawn into the frame as
# the usual arrow in paper and ink (the system cursor is not in a screenshot). The
# planner is the game's own: this script moves nothing but the pointer.
#
# Output (out=): board.png (the sheet: options as rows, two zooms by four
# states, and a palette strip), <option>.png (an option's eight crops, 1:1),
# board.json (seed, the parameters, "chosen": null for Alex to choose).
#
# EVERY OPTION AND VALUE IS PROPOSED by Track U2; none is a decision.

const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")

const SEED := 20261009
const SITE_M := Vector2(3000.0, 3620.0)       # the dense grove on the plateau edge, a scarp through it
const TARGET := Vector2(560.0, 300.0)         # where the hovered handle sits on screen
const ZOOMS := [1.0, 0.35]
const HANDLE_STEP := 1                        # the second step: a plan line each side, a ghost, a label
const DIR := Vector2(0.8, 0.6)                # the pointer comes from the lower right (the label sits upper left)
const CROP := Vector2(262.0, 176.0)
const CROP_FROM := Vector2(-136.0, -118.0)    # crop's top left, from the handle
const STATES := [
	{"id": "far", "title": "far", "radii": 3.0},
	{"id": "near", "title": "approaching", "radii": 1.5},
	{"id": "range", "title": "in range", "radii": 0.6},
	{"id": "drag", "title": "dragging", "radii": 0.15},
]
const OPTIONS := [
	{"id": "a_grow", "letter": "A", "mode": "grow", "title": "Grow and fill",
		"line": "The handle's dot swells as the pointer comes in and fills with a rule round it in range; held, a side-colour core. Nothing else moves."},
	{"id": "b_ring", "letter": "B", "mode": "ring", "title": "Closing ring",
		"line": "A dashed ring through the pointer's distance closes in on the handle and locks at the pick radius, where it goes solid with a second rule: the ring IS the grab zone. Held: reticle ticks and a side-colour core."},
	{"id": "c_halo", "letter": "C", "mode": "halo+label", "title": "Paper halo and lit label",
		"line": "A pool of paper under the handle quiets the grove's ink; in range the step's lettering (number and speed) takes a paper plate and full ink, so the node and its numbers read together."},
	{"id": "d_magnet", "letter": "D", "mode": "magnet", "title": "Magnet line",
		"line": "A dotted line from the pointer to the handle while approaching; in range it goes solid and snaps the pointer to a ring round the handle."},
	{"id": "e_ring_label", "letter": "E", "mode": "ring+label", "title": "Closing ring and lit label",
		"line": "B and the plate of C together: the ring says WHICH handle and HOW CLOSE, the lit lettering says which step it is and the speed it ends at."},
]

var out_dir := "variants/node-hover"
var scene: BoardScene = null
var style = null
var ui = null
var pl = null
var ptr: Node2D = null
var crops: Dictionary = {}          # "<option id>/<zoom>/<state id>" -> Image
var saved_plan: Array = []
var last_full: Image = null         # the whole frame of the last _shoot
var contexts: Dictionary = {}       # zoom text -> a whole frame (the in-range state of the last option)
var radius := 16.0
var failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[node-hover-board] ", msg)

func _run() -> void:
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed %d)..." % SEED)
	if not await scene.start():
		printerr("[node-hover-board] ", scene.errors)
		quit(1)
		return
	style = scene.style
	ui = scene.sb.ui
	pl = ui.planner
	radius = style.num("planner.handle_px")
	ui.set_process_input(false)   # the real mouse must not move the board's pointer
	# The cone wash, as Alex picked it (the selected unit's): the sandbox does not mount it yet,
	# so the board mounts it the way the cone board does, just under the markers.
	var cones := ConeOverlay.new()
	var mp: Node = ui.marker_layer.get_parent()
	mp.add_child(cones)
	mp.move_child(cones, ui.marker_layer.get_index())
	cones.setup(scene.world(), scene.sb.map_view, ui.selection, style)
	cones.unit_visible = ui.marker_layer.unit_visible
	cones.marker_layer = ui.marker_layer
	ptr = _PointerMark.new()
	ptr.paper = style.palette["paper"]
	ptr.ink = style.palette["ink"]
	ui.overlay.add_child(ptr)

	# The light fighter in the open ground west of the grove, a plan of four gentle steps through it.
	var ppm: float = scene.sb.map_view.px_per_m
	var w = scene.world()
	var u0 := SITE_M + Vector2(-215.0, 18.0)
	await scene.place({
		scene.p_light: {"x": u0.x, "y": u0.y, "heading": 0.0},
		scene.p_heavy: {"x": SITE_M.x - 300.0, "y": SITE_M.y + 700.0, "heading": 0.3},
		scene.bomber: {"x": SITE_M.x + 1200.0, "y": SITE_M.y - 900.0, "heading": -2.2},
	})
	ui.select(scene.p_light)
	for k in 4:
		w.plan_step(scene.p_light, k, {"turn": [0.12, 0.16, 0.14, -0.10][k], "speed": 100.0})
	saved_plan = (w.units[scene.p_light].plan as Array).duplicate(true)
	_say("plan of %d steps; pick radius %.0f px; handle %d at %s m" % [saved_plan.size(), radius, HANDLE_STEP, str(_handle_world())])

	var base_mode: String = style.text("planner.hover.mode")
	for z: float in ZOOMS:
		await scene.look(_handle_world(), TARGET, z)
		_say("zoom %.2f baked in %.1f s" % [z, await scene.settle()])
		for o: Dictionary in OPTIONS:
			style.ui["planner"]["hover"]["mode"] = str(o["mode"])
			for s: Dictionary in STATES:
				crops["%s/%s/%s" % [o["id"], str(z), s["id"]]] = await _shoot(s)
			_say("%s (%s) at zoom %.2f" % [o["letter"], o["mode"], z])
		# One whole frame (HUD and all) in the last option's in-range state, for the context.
		await _shoot(STATES[2])
		contexts[str(z)] = last_full
	style.ui["planner"]["hover"]["mode"] = base_mode

	await _write()
	for zk: String in contexts:
		var cerr: int = (contexts[zk] as Image).save_png(ProjectSettings.globalize_path("res://").path_join(out_dir).path_join("context_zoom_%s.png" % zk))
		if cerr != OK:
			failures += 1
	scene.shutdown()
	quit(1 if failures > 0 else 0)

func _handle_world() -> Vector2:
	var s: Dictionary = pl.states()[HANDLE_STEP]
	return Vector2(float(s["x"]), float(s["y"]))

func _handle_screen() -> Vector2:
	return scene.sb.map_view.world_to_screen(_handle_world())

# One state: the pointer placed, one frame taken, the crop around the handle.
func _shoot(s: Dictionary) -> Image:
	var h := _handle_screen()
	var p := h + DIR.normalized() * radius * float(s["radii"])
	ptr.pos = p
	pl.set_pointer(p)
	if s["id"] == "drag":
		pl.begin_edit(HANDLE_STEP, scene.sb.map_view.screen_to_world(p))
	await scene.frames(3)
	var img: Image = await scene.grab()
	last_full = img
	if s["id"] == "drag":
		pl.end_step()
		scene.world().clear_plan(scene.p_light)
		for k in saved_plan.size():
			scene.world().plan_step(scene.p_light, k, saved_plan[k])
	pl.clear_pointer()
	ptr.pos = Vector2.INF
	var r := Rect2(h + CROP_FROM, CROP)
	return img.get_region(Rect2i(Vector2i(r.position), Vector2i(r.size)))

# The pointer, drawn into the frame: the arrow in paper and ink.
class _PointerMark extends Node2D:
	var pos := Vector2.INF
	var paper := Color.WHITE
	var ink := Color.BLACK

	func _process(_d: float) -> void:
		queue_redraw()

	func _draw() -> void:
		if not pos.is_finite():
			return
		var pts := PackedVector2Array([Vector2(0, 0), Vector2(0, 16), Vector2(4.2, 12.4), Vector2(7.2, 19.0), Vector2(10.0, 17.8), Vector2(7.0, 11.4), Vector2(12.0, 11.4)])
		var moved := PackedVector2Array()
		for q in pts:
			moved.append(pos + q)
		draw_colored_polygon(moved, paper)
		moved.append(moved[0])
		draw_polyline(moved, ink, 1.3, true)

# --- the sheet -------------------------------------------------------------------------------

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var margin := 22.0
	var gap := 12.0
	var cols := STATES.size()
	var w := int(margin * 2.0 + CROP.x * float(cols) + gap * float(cols - 1))
	var head_h := 210.0
	var opt_h := 22.0 + (CROP.y + 18.0) * 2.0 + 44.0
	var pal_h := 400.0
	var h := int(head_h + opt_h * float(OPTIONS.size()) + pal_h)
	var sh := BoardSheet.new(style, Vector2i(w, h))
	sh.text(Vector2(margin, 34), "Selecting path nodes  ·  seed %d, the running sandbox" % SEED, 25.0, sh.c_text)
	var hy := 44.0
	hy += sh.paragraph(Vector2(margin, hy), "Alex: \"We also need a visual indicator for selecting path nodes. It is hard to tell when you are close enough.\" Today a press within the pick radius of a planned step's end grabs that step, and nothing shows it beforehand.", 12.5, sh.c_muted, float(w) - margin * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(margin, hy), "The light fighter's second step, in the dense grove, with its plan line, ghosts, speed labels and the cone wash (the selected unit's, Alex's pick). Each row is one hover style at four pointer positions: FAR (3 x the pick radius), APPROACHING (1.5 x; the zone starts at 2 x), IN RANGE (0.6 x: a press grabs THIS handle) and DRAGGING (the step held). Upper line zoom 1, lower line the far play zoom 0.35. The arrow is the pointer, drawn in; in the game the cursor also changes (a pointing hand in range, a grabbing hand dragging, a cross where a press places the next step).", 12.0, sh.c_muted, float(w) - margin * 2.0, true) + 6.0
	hy += sh.paragraph(Vector2(margin, hy), "Pick radius %.0f px (planner.handle_px, proposed up from 12), approach zone %.0f px (planner.hover.near_factor 2.0). Every option is PROPOSED by Track U2; nothing is chosen. Crops are 1:1 from the game's own frames; context_zoom_*.png are whole frames." % [radius, radius * style.num("planner.hover.near_factor")], 12.0, sh.c_muted, float(w) - margin * 2.0, true)
	var y := head_h
	var records: Array = []
	for o: Dictionary in OPTIONS:
		sh.line(Vector2(margin, y), Vector2(float(w) - margin, y), sh.c_rule, 1.0)
		sh.text(Vector2(margin, y + 18), "%s  ·  %s" % [o["letter"], o["title"]], 17.0, sh.c_text)
		sh.text(Vector2(margin + 300, y + 18), "planner.hover.mode = %s" % o["mode"], 12.0, sh.c_muted, true)
		var iy := y + 26.0
		var strip := Image.create(int(CROP.x) * cols, int(CROP.y) * ZOOMS.size(), false, Image.FORMAT_RGBA8)
		for zi in ZOOMS.size():
			var z: float = ZOOMS[zi]
			var ry := iy + (CROP.y + 18.0) * float(zi)
			for si in cols:
				var s: Dictionary = STATES[si]
				var img: Image = crops["%s/%s/%s" % [o["id"], str(z), s["id"]]]
				var x := margin + (CROP.x + gap) * float(si)
				sh.image(img, Vector2(x, ry + 14.0))
				sh.text(Vector2(x, ry + 10.0), "%s  ·  zoom %s" % [s["title"], ("1" if z == 1.0 else str(z))], 11.0, sh.c_muted, true)
				strip.blit_rect(img, Rect2i(0, 0, int(CROP.x), int(CROP.y)), Vector2i(si * int(CROP.x), zi * int(CROP.y)))
		sh.paragraph(Vector2(margin, iy + (CROP.y + 18.0) * 2.0 + 6.0), str(o["line"]), 12.0, sh.c_muted, float(w) - margin * 2.0, true)
		y += opt_h
		var err := strip.save_png(base.path_join(str(o["id"]) + ".png"))
		if err != OK:
			failures += 1
			printerr("[node-hover-board] could not write ", o["id"], ".png: ", error_string(err))
		records.append(_record(o))
	_palette_strip(sh, Vector2(margin, y + 14.0), float(w) - margin * 2.0)
	var err2: int = await sh.save(self, base.path_join("board.png"))
	if err2 != OK:
		failures += 1
		printerr("[node-hover-board] could not write board.png: ", error_string(err2))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), w, h])
	_write_json(base.path_join("board.json"), records)

func _record(o: Dictionary) -> Dictionary:
	var params := {}
	for fx: String in str(o["mode"]).split("+", false):
		var d: Variant = style.ui["planner"]["hover"].get(fx)
		if d is Dictionary:
			var c: Dictionary = (d as Dictionary).duplicate(true)
			for k: String in c.keys():
				if k.begins_with("_"):
					c.erase(k)
			params[fx] = c
	return {
		"name": o["letter"],
		"title": o["title"],
		"planner.hover.mode": o["mode"],
		"file": str(o["id"]) + ".png",
		"proposed": true,
		"parameters": params,
	}

func _write_json(path: String, records: Array) -> void:
	var accent: Color = style.palette["side_a"]
	var ink: Color = style.palette["ink"]
	var paper: Color = style.palette["paper"]
	var doc := {
		"id": "node-hover",
		"date": "2026-10-10",
		"area": "UI",
		"question": "How does the planner show that the pointer is close enough to a planned step's handle to grab it? Alex: 'We also need a visual indicator for selecting path nodes. It is hard to tell when you are close enough.' Also: which handle wins when handles crowd, and whether the 12 px pick radius should grow.",
		"source": "scripts/ui/node_hover_board_shot.gd: the running sandbox (scripts/app/sandbox.gd) over the real map, photographed once per option with ONLY data/ui/ui.json planner.hover.mode changed; the pointer positions are set on the planner (set_pointer, begin_edit), the arrow is drawn into the frame",
		"seed": SEED,
		"held_constant": {
			"scene": "the light fighter selected in the open ground west of the dense grove near (3000, 3620) m, a four-step plan of gentle turns at 100 m/s through the grove; the hovered handle is the SECOND step's. Its plan line, ghosts, speed labels and the brick-red cone wash are in view; the next step's fan is up",
			"zooms": {"zoom_1": "camera zoom 1.0, 2 px/m (a step is 200 px)", "far_play_zoom": "camera zoom 0.35 (data/view/camera.json zoom.start; a step is 70 px)"},
			"pointer_states": {"far": "3 x the pick radius from the handle", "approaching": "1.5 x the radius (inside the approach zone, planner.hover.near_factor 2.0 x the radius)", "in_range": "0.6 x the radius: a press grabs this handle", "dragging": "the step held with begin_edit, the pointer 0.15 x the radius away"},
			"pick_radius_px": radius,
			"decisions_in_force": "shadow strength 0.44; pen 'shadow_side'; side colours brick red (allies) and slate blue (axis); cones as a colour wash for the selected unit only (Alex, 5b20183); planes at their own scale; fog with sight circles and an inked edge"
		},
		"parameter": "data/ui/ui.json#planner.hover.mode (effects joined with '+': grow, ring, halo, magnet, label) and planner.hover.<effect> for each one's numbers; planner.handle_px is the pick radius, planner.hover.near_factor the approach zone",
		"also_built_behind_every_option": "the nearest handle wins (a press and the hover); the mouse cursor changes (pointing hand to grab, grabbing hand dragging, cross to place the next step, arrow otherwise, reset when it leaves); a small plus at the pointer where a press places the next step; nothing hovers for a down unit, an AI unit or during the playback",
		"options": records,
		"palette_check": "No option adds a hue: every mark is INK (L %.3f) or PAPER (L %.3f, alpha 0.92 for the halo and the label plate), and the one place the unit's side accent appears is the held (dragging) core, side_a (L %.3f, C %.3f), the same colour as the unit's roundel and the cone wash. Lightness: ink on paper dL %.2f; the paper plate keeps the lettering readable over the grove's ink and over the cone wash. Material is linework: rings and rules, no fills but the handle's own dot and the paper pools." % [
			BoardSheet.oklch(ink).x, BoardSheet.oklch(paper).x, BoardSheet.oklch(accent).x, BoardSheet.oklch(accent).y, BoardSheet.oklch(paper).x - BoardSheet.oklch(ink).x],
		"recommendation_proposed": "E, ring + label (planner.hover.mode in data is set to it, PROPOSED, so the build gives feedback before Alex picks): the ring IS the grab zone (the pick radius), so 'close enough' is literally visible; it closes in as the pointer approaches, so the approach is shown and not only the arrival; the lit lettering names the step and the speed it ends at. A (grow) is the quietest alternative but shows no zone; C's halo does least over the cone wash and the grove; D's line is too short to see in range, the pick radius being 16 px.",
		"pick_radius_proposal": "planner.handle_px 12 -> 16 PROPOSED: 24 px is the least a mouse target needs and is small for a trackpad or a finger; with the nearest handle winning, a larger radius no longer costs a crowded neighbour its handle; the ring now shows the radius; 16 px still clears the next step's fan at the start zoom (its near edge is 31 px from the last handle at minimum speed). Revert by setting 12.",
		"sheet": "board.png (rows A-E: zoom 1 and zoom 0.35 by far | approaching | in range | dragging; a palette strip below)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[node-hover-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)

# --- the palette strip (working rule 6: every art choice includes the palette) ---------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette, and what the hover spends of it", 16.0, sh.c_text)
	var chips := [
		["paper", style.palette["paper"]],
		["ink", style.palette["ink"]],
		["side_a (yours)", style.palette["side_a"]],
		["hover_paper", style.color("hover_paper")],
		["hover_ink", style.color("hover_ink")],
		["plan line", style.color("path")],
		["speed label", style.color("ink_soft")],
	]
	var x := pos.x
	for c: Array in chips:
		sh.chip(Vector2(x, pos.y + 40.0), c[1], str(c[0]), BoardSheet.oklch_text(c[1]))
		x += 148.0
	var ty := pos.y + 134.0
	var ink_l: float = BoardSheet.oklch(style.palette["ink"]).x
	var paper_l: float = BoardSheet.oklch(style.palette["paper"]).x
	var red_l: float = BoardSheet.oklch(style.palette["side_a"]).x
	var lines := [
		"Hue stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md). Every hover mark is ink or paper; the unit's own accent (side_a, brick red) appears only in the HELD state, as a small core, so 'held' has a colour of its own that the unit's roundel and the cone wash share. Nothing else is coloured.",
		"Against the plan line (ink at 0.9) a ring or rule in full ink at 1.9 px is the same lightness and a thicker stroke: it reads as an annotation of the line, not a second line. Against the cone wash (side_a at 0.07 to 0.30, L %.3f under it) ink keeps dL %.2f even against the wash at full strength, more than red on red would; that is why the accent is kept to the held core." % [red_l, red_l - ink_l],
		"Against the speed labels (ink_soft, 0.72) the lit label (ink on a paper plate, L %.3f against L %.3f) is the only text in the frame that gains a ground: it is the label of the one handle in play." % [ink_l, paper_l],
		"Material is linework: rings, rules and one filled dot per handle; the paper pool (halo) is the ground's own colour, the way the stand-out board's halo was, so it quiets the grove's inked edges rather than adding a tone.",
	]
	var yy := ty
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width - 40.0, false, 3.0) + 5.0
