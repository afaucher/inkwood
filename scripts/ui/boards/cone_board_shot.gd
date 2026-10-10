extends SceneTree

# BOARD: ENGAGEMENT-CONE OVERLAY (Track U1, the first fight). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/cone_board_shot.gd -- [out=variants/cone-overlay]
#
# How the cones are drawn in the game while planning. The running sandbox (seed
# 20261009, the real map and fog), a cone overlay (scripts/ui/cone_overlay.gd)
# mounted under the markers, the weapons from the unit files (data/units/*.json
# weapons: Track C's records of the lead's proposal, hardpoints in metres
# [forward, right, up]), photographed once per style with ONLY
# data/ui/ui.json planner.cones.mode changed.
#
# Per option: (1) the heavy fighter selected, an AI bomber in sight at the camera's
# start zoom 0.35 -- the selected plane's cones and the bomber's turrets, both
# pointing at each other; (2) the light fighter selected at the same zoom, alone
# (the bomber out of sight, so none of its cones show): its two wing guns' hardpoints
# a few px apart, and a x5 enlargement of that corner of the frame; (3) the same at
# zoom 1. Under the row, the same cones SIDE-ON (the cone in height) in the same
# style. Output:
#   board.png            the sheet, options A..D as rows, the side view and a palette strip below
#   <option>.png         each option's three full frames (HUD and all), 0.35 / 0.35 / 1.0
#   board.json           seed, the parameter set per option, "chosen": null (Alex chooses)
#
# EVERY OPTION, VALUE AND RULE IS PROPOSED by Track U1; none is a decision.

const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const ConeOverlay = preload("res://scripts/ui/cone_overlay.gd")
const UiRoles = preload("res://scripts/ui/ui_roles.gd")

const SEED := 20261009
const SITE_M := Vector2(3000.0, 3620.0)
const PLAY_ZOOM := 0.35          # data/view/camera.json zoom.start: the planning view
const V1_CROP := Rect2(0.0, 150.0, 972.0, 360.0)
const V2_CROP := Rect2(44.0, 258.0, 560.0, 152.0)
const V3_CROP := Rect2(26.0, 232.0, 560.0, 196.0)
const INSET_SRC := Vector2(40.0, 26.0)          # px of frame magnified
const INSET_K := 8.0

const OPTIONS := [
	{"id": "a_outline", "letter": "A", "mode": "outline", "title": "Outline and range ticks",
		"line": "An inked rim at the EFFECTIVE range, a faint centre line with a tick every 100 m. Nothing inside, so the ground reads through; the odds are not shown, only the reach. Past the rim the falloff zone is linework too: the sides carry on dashed and three arcs, each fainter, fade out."},
	{"id": "b_hatch", "letter": "B", "mode": "hatch", "title": "Hatched wedge",
		"line": "45 degree strokes in the side colour (the fog edge's own hatch angle); the strokes break up where the odds fall, so a fixed gun is solid down its centre and ragged at its rim, a turret is solid across. Past the effective-range rim the strokes fray out along the range factor, to nothing."},
	{"id": "c_stipple", "letter": "C", "mode": "stipple", "title": "Stippled odds",
		"line": "Dots in the side colour on a jittered grid, kept in proportion to the odds: dense down a fixed gun's centre, sparse at its rim, even across a turret. Past the effective-range rim the dots thin out with the range factor until none are left."},
	{"id": "d_wash", "letter": "D", "mode": "wash", "title": "Wash in the side colour",
		"line": "A light wash of the side accent in steps from the centre outwards (the engagement-cones proposal's look), an inked rim on it; a turret is one even wash. Past the effective-range rim the same steps carry on in four rings, each lighter by the range factor, to nothing."},
]

var out_dir := "variants/cone-overlay"
var scene: BoardScene = null
var overlay: ConeOverlay = null
var style = null
var v1: Dictionary = {}
var v2: Dictionary = {}
var v3: Dictionary = {}
var rect1 := V1_CROP
var rect2 := V2_CROP
var rect3 := V3_CROP
var inset_rect := Rect2()
var weapons_note := {}
var failures := 0

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[cone-board] ", msg)

func _run() -> void:
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed %d)..." % SEED)
	if not await scene.start():
		printerr("[cone-board] ", scene.errors)
		quit(1)
		return
	style = scene.style
	var ui = scene.sb.ui
	ui.planner.visible = false   # the fan would paint the ground: the board is about the cones
	# The overlay goes in the markers' own layer, just under the markers (planes above the wedges).
	overlay = ConeOverlay.new()
	var parent: Node = ui.marker_layer.get_parent()
	parent.add_child(overlay)
	parent.move_child(overlay, ui.marker_layer.get_index())
	overlay.setup(scene.world(), scene.sb.map_view, ui.selection, style)
	overlay.unit_visible = ui.marker_layer.unit_visible
	overlay.marker_layer = ui.marker_layer
	for id: String in [scene.p_light, scene.p_heavy, scene.bomber]:
		var u = scene.world().units[id]
		var ws := []
		for w in u.def.weapons:
			ws.append("%s (%s, %d m, +-%.0f deg across, hardpoints %s)" % [w.name, w.kind, int(w.range_m), w.half_across_deg, str(w.hardpoints)])
		weapons_note[str(u.type)] = ws
	_say("weapons: %s" % str(weapons_note))

	# --- view 1: the heavy fighter selected, the bomber in sight ---------------------------------
	await scene.place({
		scene.p_light: {"x": SITE_M.x - 300.0, "y": SITE_M.y + 95.0, "heading": 0.15},
		scene.p_heavy: {"x": SITE_M.x - 240.0, "y": SITE_M.y + 20.0, "heading": 0.0},
		scene.bomber: {"x": SITE_M.x - 40.0, "y": SITE_M.y + 6.0, "heading": 0.0},
	})
	ui.selection.select(scene.p_heavy)
	await scene.look(Vector2(SITE_M.x - 240.0, SITE_M.y + 20.0), Vector2(372.0, 330.0), PLAY_ZOOM)
	_say("view 1 baked in %.1f s" % await scene.settle())
	for o: Dictionary in OPTIONS:
		_set_mode(str(o["mode"]))
		await scene.frames(8)
		v1[o["id"]] = await scene.grab()
		_say("%s (%s): view 1 (%d cones drawn)" % [o["letter"], o["mode"], overlay.collect().size()])

	# --- view 2: the light fighter alone, wing hardpoints, at the play zoom -------------------------
	await scene.place({
		scene.p_light: {"x": SITE_M.x - 100.0, "y": SITE_M.y + 30.0, "heading": 0.0},
		scene.p_heavy: {"x": SITE_M.x - 700.0, "y": SITE_M.y + 330.0, "heading": 0.3},
		scene.bomber: {"x": SITE_M.x + 1500.0, "y": SITE_M.y - 200.0, "heading": 3.1},
	})
	ui.selection.select(scene.p_light)
	await scene.look(Vector2(SITE_M.x - 100.0, SITE_M.y + 30.0), Vector2(90.0, 330.0), PLAY_ZOOM)
	_say("view 2 settled in %.1f s" % await scene.settle())
	var lp: Vector2 = scene.screen_of(scene.p_light)
	inset_rect = Rect2(lp - INSET_SRC * Vector2(0.5, 0.5), INSET_SRC)
	rect2 = Rect2(lp.x - 46.0, lp.y - 74.0, 560.0, 152.0)
	for o: Dictionary in OPTIONS:
		_set_mode(str(o["mode"]))
		await scene.frames(8)
		v2[o["id"]] = await scene.grab()
		_say("%s (%s): view 2 (%d cones)" % [o["letter"], o["mode"], overlay.collect().size()])

	# --- view 3: the same at zoom 1 --------------------------------------------------------------
	await scene.look(Vector2(SITE_M.x - 100.0, SITE_M.y + 30.0), Vector2(70.0, 330.0), 1.0)
	_say("view 3 settled in %.1f s" % await scene.settle())
	var lp3: Vector2 = scene.screen_of(scene.p_light)
	rect3 = Rect2(lp3.x - 44.0, lp3.y - 98.0, 560.0, 196.0)
	for o: Dictionary in OPTIONS:
		_set_mode(str(o["mode"]))
		await scene.frames(8)
		v3[o["id"]] = await scene.grab()
		_say("%s (%s): view 3" % [o["letter"], o["mode"]])

	await _write()
	_set_mode("outline")
	scene.shutdown()
	quit(1 if failures > 0 else 0)

func _set_mode(mode: String) -> void:
	style.ui["planner"]["cones"]["mode"] = mode

# --- the sheet ----------------------------------------------------------------------------------

func _write() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var margin := 22.0
	var gap := 14.0
	var w := int(margin * 2.0 + rect1.size.x + rect2.size.x + gap)
	var head_h := 200.0
	var row_h := rect1.size.y + 62.0
	var inset_size := INSET_SRC * INSET_K
	var close_h := inset_size.y + 74.0
	var side_h := 330.0
	var pal_h := 330.0
	var h := int(head_h + row_h * float(OPTIONS.size()) + close_h + side_h + pal_h)
	var sh := BoardSheet.new(style, Vector2i(w, h))
	sh.text(Vector2(margin, 34), "Engagement cones on the map while planning  ·  seed %d, the running sandbox" % SEED, 25.0, sh.c_text)
	var hy := 46.0
	for l: String in [
		"Alex: a cone per weapon, starting at the weapon's hardpoint; the same cone in height; machine guns have better odds near the cone's centre. The same scene, map and fog; only planner.cones.mode changes. The rim and a dot on every hardpoint are common to all four.",
		"Left: the heavy fighter selected (nose cannon: peaked; rear gunner: even) with the bomber in sight and its three turrets, zoom 0.35, the planning view. Right: the light fighter selected, alone, at zoom 0.35 and zoom 1. Below: its two wing hardpoints enlarged, and the cones side-on.",
		"Assumed (PROPOSED): own cones for the selected unit only; an enemy's cones only while it is in sight (the right-hand frames have the bomber out of sight: none shown); drawn at the unit's own level, a weapon with no slice there is dashed and marked overhead; nothing while a turn plays back.",
		"Ranges are EFFECTIVE ranges (Alex: guns fire slightly over them): the solid rim is the effective range, labelled in metres, and beyond it each style fades the odds out over a falloff zone of %d%% more (PROPOSED stand-in for Track C's range factor, overshoot 15 to 25%%; planner.cones.overshoot_fraction, smooth ramp). The sides carry on dashed through the zone." % int(round(float(style.ui["planner"]["cones"]["overshoot_fraction"]) * 100.0)),
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
		var x2 := margin + rect1.size.x + gap
		sh.image(v1[id], Vector2(margin, iy), rect1)
		sh.image(v2[id], Vector2(x2, iy), rect2)
		sh.image(v3[id], Vector2(x2, iy + rect2.size.y + 8.0), rect3)
		sh.paragraph(Vector2(margin, iy + rect1.size.y + 4.0), str(o["line"]), 12.0, sh.c_muted, float(w) - margin * 2.0, true)
		y += row_h
		var all := Image.create(1280, 2160, false, Image.FORMAT_RGBA8)
		all.blit_rect(v1[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 0))
		all.blit_rect(v2[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 720))
		all.blit_rect(v3[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 1440))
		var err := all.save_png(base.path_join(id + ".png"))
		if err != OK:
			failures += 1
			printerr("[cone-board] could not write ", id, ".png: ", error_string(err))
		records.append(_record(o))
	# The hardpoints close up: the same pixels as the zoom 0.35 frame, enlarged.
	sh.line(Vector2(margin, y + 2.0), Vector2(float(w) - margin, y + 2.0), sh.c_rule, 1.0)
	sh.text(Vector2(margin, y + 26.0), "The light fighter's two wing hardpoints at the play zoom (0.35), the frame's own pixels enlarged x%d" % int(INSET_K), 16.0, sh.c_text)
	sh.text(Vector2(margin + 700.0, y + 26.0), "6 m apart on the airframe, about 9 px apart at this zoom (the plane is drawn 14 px wide); the selection ring is the arc round them", 12.0, sh.c_muted, true)
	var panel_gap := (float(w) - margin * 2.0 - inset_size.x * 4.0) / 3.0
	for i in OPTIONS.size():
		var px := margin + float(i) * (inset_size.x + panel_gap)
		sh.image(v2[OPTIONS[i]["id"]], Vector2(px, y + 38.0), inset_rect, inset_size)
		sh.text(Vector2(px, y + 38.0 + inset_size.y + 16.0), "%s · %s" % [OPTIONS[i]["letter"], OPTIONS[i]["title"]], 12.0, sh.c_muted)
	y += close_h
	await _side_views(sh, Vector2(margin, y + 6.0), float(w) - margin * 2.0, side_h)
	y += side_h
	_palette_strip(sh, Vector2(margin, y + 10.0), float(w) - margin * 2.0)
	var err2: int = await sh.save(self, base.path_join("board.png"))
	if err2 != OK:
		failures += 1
		printerr("[cone-board] could not write board.png: ", error_string(err2))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), w, h])
	_write_json(base.path_join("board.json"), records)

func _param_line(mode: String) -> String:
	var d: Dictionary = style.ui["planner"]["cones"][mode]
	var parts := PackedStringArray()
	for k: String in d:
		if k.begins_with("_"):
			continue
		parts.append("%s %s" % [k, str(d[k])])
	return "planner.cones.mode = %s  ·  %s" % [mode, "  ·  ".join(parts)]

func _record(o: Dictionary) -> Dictionary:
	var mode := str(o["mode"])
	var d: Dictionary = (style.ui["planner"]["cones"][mode] as Dictionary).duplicate(true)
	for k: String in d.keys():
		if k.begins_with("_"):
			d.erase(k)
	var common := {}
	for k: String in ["rim_px", "rim_role", "hardpoint_px", "overshoot_fraction", "falloff_side_alpha", "falloff_dash_px", "overhead_dash_px", "label", "label_px", "own", "enemy"]:
		common[k] = style.ui["planner"]["cones"][k]
	return {
		"name": o["letter"], "title": o["title"], "planner.cones.mode": mode,
		"file": o["id"] + ".png", "proposed": true,
		"parameters": d, "common_parameters": common,
	}

func _write_json(path: String, records: Array) -> void:
	var doc := {
		"id": "cone-overlay",
		"date": "2026-10-09",
		"area": "UI, Combat",
		"question": "How are a weapon's engagement cones drawn on the map while planning? (a cone per weapon from its hardpoint; the same cone in height; better odds near the centre for machine guns)",
		"source": "scripts/ui/boards/cone_board_shot.gd: the running sandbox over the real map with scripts/ui/cone_overlay.gd, photographed once per option with ONLY data/ui/ui.json planner.cones.mode changed; weapons are data/units/*.json weapons (Track C's records of variants/engagement-cones/weapons_proposed.json)",
		"seed": SEED,
		"held_constant": {
			"scene": "around (3000, 3620) m, the dense grove on the plateau edge; view 1: the heavy fighter selected 200 m behind the AI bomber, both heading east, each inside the other's cone; view 2 and 3: the light fighter selected, alone (the bomber 1,500 m away, out of sight)",
			"zoom": {"view_1_and_2": PLAY_ZOOM, "view_3": 1.0},
			"decisions_in_force": "shadow strength 0.44; pen 'shadow_side'; side colours brick red (allies, the players) and slate blue (axis, the enemy); terrain with contours; planes at their own scale (light fighter 36 px at zoom 1, never below 14 px); fog with sight circles and an inked edge; cones start at the weapon's hardpoint; the same cone in height; machine guns have better odds near the cone's centre",
			"weapons": weapons_note,
		},
		"assumptions_proposed": [
			"Own cones only for the selected player unit during planning; enemy cones only while that enemy is in sight (planner.cones.own, planner.cones.enemy)",
			"Cones are drawn at the unit's current pose, not at a planned step's ghost",
			"The wedge is the cone cut at the unit's own level; a weapon whose cone has no slice there (the bomber's dorsal turret, +35 +- 35 degrees) is a dashed rim marked overhead",
			"Shading is relative to a weapon's own centre odds (combat.gd centre_factor); the label carries the weapon's name and its effective range in metres (centre odds could be added as a percentage)",
			"Cones are drawn under the plane markers and above the map and the fog; the hardpoints, rims and lettering over the markers (the interior is under the planes so an enemy's wash does not tint your own plane)",
			"EFFECTIVE RANGE (Alex: guns fire slightly over it): range_m is the effective range, drawn as the solid rim and labelled; a falloff zone of planner.cones.overshoot_fraction (0.2, proposed: the middle of Track C's 15 to 25%) beyond it fades the odds to nothing along a smoothstep, in each style's own way. Track C's real range factor replaces the stand-in through ConeOverlay.range_factor (CombatWeapon, distance_m) -> 0..1; the zone's size is read from it",
		],
		"parameter": "data/ui/ui.json#planner.cones.mode (and planner.cones.<mode>)",
		"options": records,
		"palette_check": "No option adds a hue. The interior of a cone is the unit's own side accent (side_a, side_b: equal OKLCH L 0.551, C 0.100); the rim, the ticks and the lettering are ink; the label's halo is paper. Outline uses only ink; hatch and stipple draw the accent as thin ink-like marks (no fill); the wash is the accent mixed toward paper by 7 to 30% alpha, a lighter, less chromatic tint of the same hue. Over warm paper the slate-blue wash is nearly neutral (C 0.009 at 0.30), so in D the two sides differ less in tint than in marks (salmon against grey); B and C keep each side's hue.",
		"sheet": "board.png (rows A-D: heavy and bomber at 0.35 | light fighter at 0.35 and 1.0 | hardpoints x5; the side view and a palette strip below)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[cone-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)

# --- the cone in height: the same styles, side-on ---------------------------------------------------

# The heavy fighter at medium altitude with the bomber 330 m ahead at the same altitude and
# another 280 m lower, side-on: the cone's height as the data has it, drawn in each style by
# the overlay's own functions. One panel per option.
func _side_views(sh: BoardSheet, pos: Vector2, width: float, height: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The same cones in height (side-on, the same styles)", 16.0, sh.c_text)
	sh.text(pos + Vector2(380, 26), "the heavy fighter (yours) at medium, 400 m; a bomber 330 m ahead at the same altitude and one 280 m lower. One scale both ways: 0.3 px per metre; the falloff past the effective range is drawn too. Proposed.", 12.0, sh.c_muted, true)
	var ppm := 0.3
	var panel := Vector2((width - 3.0 * 12.0) / 4.0, height - 56.0)
	var w_world = scene.world()
	var heavy = w_world.units[scene.p_heavy]
	var bomber_u = w_world.units[scene.bomber]
	var medium_m: float = w_world.band_height("medium")
	var low_m: float = w_world.band_height("low")
	var imgs: Array = []
	for i in OPTIONS.size():
		imgs.append(await _render_side(OPTIONS[i], heavy, bomber_u, medium_m, low_m, panel, ppm))
	for i in OPTIONS.size():
		var px := pos.x + float(i) * (panel.x + 12.0)
		var py := pos.y + 38.0
		sh.image(imgs[i], Vector2(px, py))
		sh.text(Vector2(px + 4.0, py + panel.y + 14.0), "%s · %s" % [OPTIONS[i]["letter"], OPTIONS[i]["title"]], 12.0, sh.c_muted)

func _render_side(o: Dictionary, heavy: Object, bomber_u: Object, medium_m: float, low_m: float, panel: Vector2, ppm: float) -> Image:
	var vp := SubViewport.new()
	vp.size = Vector2i(panel)
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var node := _SidePanel.new()
	node.panel = panel
	node.ppm = ppm
	node.style = style
	node.mode = str(o["mode"])
	node.heavy = heavy
	node.bomber = bomber_u
	node.medium_m = medium_m
	node.low_m = low_m
	vp.add_child(node)
	root.add_child(vp)
	for _i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	img.convert(Image.FORMAT_RGBA8)
	vp.queue_free()
	return img

# One panel: paper, the ground line, the altitude bands, two planes in profile, their cones.
class _SidePanel extends Node2D:
	const _Cone = preload("res://scripts/ui/cone_overlay.gd")
	var panel := Vector2.ZERO
	var ppm := 0.3
	var style
	var mode := "outline"
	var heavy: Object
	var bomber: Object
	var medium_m := 400.0
	var low_m := 120.0

	func _draw() -> void:
		var paper: Color = style.palette["paper"]
		var ink: Color = style.palette["ink"]
		draw_rect(Rect2(Vector2.ZERO, panel), paper)
		var ground_y := panel.y - 22.0
		var font: Font = style.font(true)
		draw_line(Vector2(0, ground_y), Vector2(panel.x, ground_y), Color(ink.r, ink.g, ink.b, 0.8), 1.2, true)
		draw_string(font, Vector2(6, ground_y + 15.0), "ground", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(ink.r, ink.g, ink.b, 0.6))
		var halo := Color(paper.r, paper.g, paper.b, 0.92)
		for band: Array in [["low", low_m], ["medium", medium_m]]:
			var yy: float = ground_y - float(band[1]) * ppm
			draw_dashed_line(Vector2(0, yy), Vector2(panel.x, yy), Color(ink.r, ink.g, ink.b, 0.3), 1.0, 5.0, true)
			draw_string_outline(font, Vector2(panel.x - 78.0, yy - 4.0), "%s %d m" % [band[0], int(band[1])], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 4, halo)
			draw_string(font, Vector2(panel.x - 78.0, yy - 4.0), "%s %d m" % [band[0], int(band[1])], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(ink.r, ink.g, ink.b, 0.75))
		# The heavy fighter (own, facing right) and the bomber (enemy, facing right) ahead of it.
		var x_h := 116.0
		var cones: Array = []
		cones.append_array(_side_cones(heavy, Vector2(x_h, ground_y - medium_m * ppm), 1.0))
		cones.append_array(_side_cones(bomber, Vector2(x_h + 330.0 * ppm, ground_y - medium_m * ppm), 1.0))
		_Cone.draw_cones(self, cones, style, mode)
		# The planes: small side silhouettes, the same inked marks.
		_plane(Vector2(x_h, ground_y - medium_m * ppm), 16.0, style.side_color("allies"), ink)
		_plane(Vector2(x_h + 330.0 * ppm, ground_y - medium_m * ppm), 20.0, style.side_color("axis"), ink)
		_plane(Vector2(x_h + 330.0 * ppm + 40.0, ground_y - (medium_m - 280.0) * ppm), 20.0, style.side_color("axis"), ink)

	func _plane(c: Vector2, len: float, accent: Color, ink: Color) -> void:
		var fill: Color = style.palette["object_fill"]
		var body := PackedVector2Array([c + Vector2(-len * 0.5, -1.4), c + Vector2(len * 0.5, -1.4), c + Vector2(len * 0.6, 0.0), c + Vector2(len * 0.5, 1.4), c + Vector2(-len * 0.5, 1.4), c + Vector2(-len * 0.58, -4.2)])
		draw_colored_polygon(body, fill)
		draw_polyline(_close(body), ink, 1.0, true)
		draw_circle(c, 2.0, accent, true, -1.0, true)

	func _close(p: PackedVector2Array) -> PackedVector2Array:
		var q := PackedVector2Array(p)
		q.append(p[0])
		return q

	# Cone records for a unit seen from the side, facing right (heading 0) at `at`: each weapon's
	# cone in ELEVATION about its mount: forward weapons point right, rearward weapons left.
	# The records have the keys the overlay's style functions read; "side" turns its odds
	# from azimuth to elevation.
	func _side_cones(u: Object, at: Vector2, _sgn: float) -> Array:
		var out: Array = []
		for w in u.def.weapons:
			var facing_right := absf(w.mount_deg) < 90.0
			var elev: float = w.elevation
			var phi := -elev if facing_right else PI + elev
			for hi in w.hardpoints.size():
				var hp: Vector3 = w.hardpoints[hi]
				# The hardpoint on the DRAWN airframe (1 px per metre of airframe; ranges stay at ppm).
				var ap := at + Vector2(hp.x, -hp.z)
				out.append({
					"unit": u.id, "side": str(u.side), "own": true, "weapon": w, "hp": hi,
					"apex": ap, "phi": phi, "half": float(w.half_height), "range_px": float(w.range_m) * ppm,
					"b0": 0.0, "sp": at, "side_view": true, "ppm": ppm,
					"reach_px": _Cone.reach_for(w, ppm, style, Callable()), "rf": Callable(),
				})
		return out

# --- the palette strip --------------------------------------------------------------------------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette, and what each option does to it", 16.0, sh.c_text)
	var paper: Color = style.palette["paper"]
	var cones: Dictionary = style.ui["planner"]["cones"]
	var x := pos.x
	var base_chips := [["paper", paper], ["ink", style.palette["ink"]], ["side_a (yours)", style.palette["side_a"]], ["side_b (enemy)", style.palette["side_b"]]]
	for c: Array in base_chips:
		sh.chip(Vector2(x, pos.y + 40.0), c[1], str(c[0]), BoardSheet.oklch_text(c[1]))
		x += 148.0
	# What the colours become on paper: the wash's two ends, and the side accent as a hatch or dot
	# (a thin mark at 0.85: shown here as the colour at that alpha over paper).
	var wash: Dictionary = cones["wash"]
	var comp := func(accent: Color, a: float) -> Color: return Color(paper.r + (accent.r - paper.r) * a, paper.g + (accent.g - paper.g) * a, paper.b + (accent.b - paper.b) * a, 1.0)
	var sa: Color = style.palette["side_a"]
	var sb_: Color = style.palette["side_b"]
	var chips2 := [
		["D wash a, rim", comp.call(sa, float(wash["alpha_rim"])), "side_a @ %.2f" % float(wash["alpha_rim"])],
		["D wash a, centre", comp.call(sa, float(wash["alpha_centre"])), "side_a @ %.2f" % float(wash["alpha_centre"])],
		["D wash b, centre", comp.call(sb_, float(wash["alpha_centre"])), "side_b @ %.2f" % float(wash["alpha_centre"])],
		["B/C mark on paper", comp.call(sa, float(cones["hatch"]["alpha"])), "side_a @ %.2f" % float(cones["hatch"]["alpha"])],
	]
	x += 24.0
	for c: Array in chips2:
		sh.chip(Vector2(x, pos.y + 40.0), c[1], str(c[0]), BoardSheet.oklch_text(c[1]), Vector2(70, 40))
		sh.text(Vector2(x, pos.y + 40.0 + 40.0 + 42.0), str(c[2]), 11.0, sh.c_muted)
		x += 152.0
	var l_paper := BoardSheet.oklch(paper)
	var lines := [
		"Hue stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md): every cone's interior is the unit's own side accent, so a player's cones are brick red and the enemy's slate blue, the same two colours as the roundels, the roster marks and the rings; the rim, the ticks and the lettering are ink; the label's halo is paper. Nothing adds a colour.",
		"Lightness ramp: a wash is the accent mixed toward paper (L %.3f), so it is a lighter, less chromatic step of the same hue, never a new one (the centre of D's wash is L %.3f, C %.3f against the accent's L 0.551, C 0.100). Hatch and stipple are marks, not fills: they thin out toward the rim instead of fading in colour." % [l_paper.x, BoardSheet.oklch(comp.call(sa, float(wash["alpha_centre"]))).x, BoardSheet.oklch(comp.call(sa, float(wash["alpha_centre"]))).y],
		"Over warm paper the slate-blue wash is almost neutral (side_b at %.2f lands at L %.3f, C %.3f against side_a's C %.3f at the same alpha), so in D the two sides read less alike in tint than in marks: the player's cones look salmon, the enemy's grey. B and C keep each side's hue because a thin mark of the accent stays the accent." % [float(wash["alpha_centre"]), BoardSheet.oklch(comp.call(sb_, float(wash["alpha_centre"]))).x, BoardSheet.oklch(comp.call(sb_, float(wash["alpha_centre"]))).y, BoardSheet.oklch(comp.call(sa, float(wash["alpha_centre"]))).y],
		"Material is linework: A is pure linework; B is hatching at the fog edge's own 45 degrees, the map's existing way of saying 'not here'; C is stippling, the map's way of saying dirt and canvas; D is the only one that uses a tint.",
	]
	var yy := pos.y + 134.0
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width, false, 3.0) + 5.0
