extends SceneTree

# BOARD: OWN UNITS STAND OUT (Track U1, the first fight). WINDOWED ONLY.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --windowed `
#       --resolution 1280x720 --script res://scripts/ui/boards/standout_board_shot.gd -- [out=variants/own-units-stand-out]
#
# Alex (2026-10-09): "a comparison board for figuring out how to make your own
# units stand out visually on the busy background." The heavy fighter is faint
# over trees. This stands up the RUNNING SANDBOX (seed 20261009, the real map,
# the fog as the game shows it) and photographs the same three planes -- two
# player fighters and the AI bomber -- over dense trees and a scarp with some
# open ground, once per option, changing ONLY marker.standout.mode in
# data/ui/ui.json's table (the chosen option lands in data as that one value).
#
# Per option: zoom 1 (planes at their own scale, a light fighter 36 px), the far
# play zoom (the camera's start zoom, 0.35: the planes are at their minimum
# size and the fog's inked edge is in view), and zoom 1 again with the heavy
# fighter selected (the ring and leader beside the option). Output:
#   board.png        the sheet, options A..F as rows, with a palette strip
#   <option>.png     each option's two full frames (HUD and all), zoom 1 over far
#   board.json       seed, the parameter set per option, "chosen": null (Alex chooses)
#
# EVERY OPTION AND VALUE IS PROPOSED by Track U1; none is a decision.

const BoardScene = preload("res://scripts/ui/boards/board_scene.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const UiRoles = preload("res://scripts/ui/ui_roles.gd")
const UnitMarkerLayer = preload("res://scripts/ui/unit_marker_layer.gd")

const SEED := 20261009
# The site: the dense grove on the plateau edge near (3000, 3620) m, with a scarp
# running through it and open ground to its north-west and south (seen from the
# first probe of the seed's busiest windows). Screen positions of the three planes at zoom 1,
# in a frame whose centre is the site: converted to metres below.
const SITE_M := Vector2(3000.0, 3620.0)
const NEAR_CENTRE := Vector2(440.0, 330.0)        # where the cluster's centre sits at zoom 1
const FAR_ZOOM := 0.35                            # data/view/camera.json zoom.start: planes at their minimum size
const NEAR_CROP := Rect2(160.0, 165.0, 495.0, 310.0)
const FAR_CROP := Rect2(5.0, 191.0, 700.0, 310.0)
const SEL_CROP_SIZE := Vector2(250.0, 310.0)

# The options. mode is the value of marker.standout.mode; the rest is lettering.
const OPTIONS := [
	{"id": "a_today", "letter": "A", "mode": "none", "title": "Today's marker", "line": "Cream plane, ink outline, side roundels; nothing added."},
	{"id": "b_halo", "letter": "B", "mode": "halo", "title": "Paper halo", "line": "A paper knock-out round the silhouette erases the trees' ink under and round the plane; the shadow still falls over it."},
	{"id": "c_lift", "letter": "C", "mode": "lift", "title": "Paper lift", "line": "A soft pool of paper under the plane: the same erasing, no edge, so it reads as a pale patch of ground."},
	{"id": "d_rim", "letter": "D", "mode": "rim", "title": "Heavier outline", "line": "The silhouette grown in ink round the drawn outline: own planes are drawn with a bolder line."},
	{"id": "e_ring", "letter": "E", "mode": "ring", "title": "Side-colour ring", "line": "A ring in the unit's own accent under the plane, inked on its outer edge."},
	{"id": "f_larger", "letter": "F", "mode": "larger", "title": "Own planes larger", "line": "Own planes drawn 1.3 x the size the rule gives; the shadow gap grows with them."},
]

var out_dir := "variants/own-units-stand-out"
var options: Array = OPTIONS.duplicate(true)
var scene: BoardScene = null
var layer: UnitMarkerLayer = null
var style = null
var near: Dictionary = {}     # option id -> Image (full frame)
var far: Dictionary = {}
var sel: Dictionary = {}
var failures := 0
var _sel_rect := Rect2()

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2 and kv[0] == "out":
			out_dir = kv[1]
		# modes=halo+ring,rim+ring: a board of your own choosing (the modes the data names, joined with '+')
		if kv.size() == 2 and kv[0] == "modes":
			options = []
			var letters := "ABCDEFGHIJ"
			var i := 0
			for m: String in kv[1].split(",", false):
				options.append({"id": "%s_%s" % [letters[i].to_lower(), m.replace("+", "_")], "letter": letters[i], "mode": m,
					"title": m.replace("+", " + "), "line": "A mode of your own choosing from the data's own effects (marker.standout.mode = %s)." % m})
				i += 1
	_run.call_deferred()

func _say(msg: String) -> void:
	print("[standout-board] ", msg)

func _run() -> void:
	scene = BoardScene.new(self)
	_say("standing up the sandbox (seed %d)..." % SEED)
	if not await scene.start():
		printerr("[standout-board] ", scene.errors)
		quit(1)
		return
	style = scene.style
	layer = scene.sb.ui.marker_layer
	_say("playable; planes %s" % str(scene.ids))
	var ppm: float = scene.sb.map_view.px_per_m

	# Three planes over the busiest ground. Screen layout at zoom 1 (px from the cluster's centre
	# NEAR_CENTRE) -> metres. Light fighter in the open ground to the west, the heavy fighter in the
	# grove, the bomber at the grove's far edge over the scarp.
	var at := func(dx: float, dy: float) -> Vector2: return SITE_M + Vector2(dx, dy) / ppm
	var pl: Vector2 = at.call(-235.0, -45.0)
	var ph: Vector2 = at.call(0.0, 0.0)
	var pb: Vector2 = at.call(165.0, 60.0)
	await scene.place({
		scene.p_light: {"x": pl.x, "y": pl.y, "heading": 0.12},
		scene.p_heavy: {"x": ph.x, "y": ph.y, "heading": 0.38},
		scene.bomber: {"x": pb.x, "y": pb.y, "heading": -2.25},
	})
	scene.sb.ui.planner.visible = false   # the fan would paint the ground: the board is about the markers

	# --- zoom 1 ---------------------------------------------------------------------------
	await scene.look(SITE_M, NEAR_CENTRE, 1.0)
	_say("zoom 1 view baked in %.1f s" % await scene.settle())
	for o: Dictionary in options:
		_set_mode(str(o["mode"]))
		await scene.frames(6)
		near[o["id"]] = await scene.grab()
		scene.sb.ui.selection.select(scene.p_heavy)
		await scene.frames(4)
		sel[o["id"]] = await scene.grab()
		scene.sb.ui.selection.clear()
		_say("%s (%s): near and selected frames" % [o["letter"], o["mode"]])
	_sel_rect = _sel_crop()
	_set_mode("none")

	# --- the far play zoom ----------------------------------------------------------------
	await scene.look(ph, Vector2(135.0, 346.0), FAR_ZOOM)
	_say("far view settled in %.1f s" % await scene.settle())
	for o: Dictionary in options:
		_set_mode(str(o["mode"]))
		await scene.frames(6)
		far[o["id"]] = await scene.grab()
		_say("%s (%s): far frame" % [o["letter"], o["mode"]])
	var min_px: float = scene.sb.plane_min_px
	_set_mode("none")

	await _write(min_px)
	scene.shutdown()
	quit(1 if failures > 0 else 0)

# The data's mode, set the way a host would (the layer reads it again).
func _set_mode(mode: String) -> void:
	style.ui["marker"]["standout"]["mode"] = mode
	layer.apply_standout(true)

func _sel_crop() -> Rect2:
	var c: Vector2 = scene.screen_of(scene.p_heavy)
	return Rect2(Vector2(c.x - 96.0, c.y - 150.0), SEL_CROP_SIZE)

# --- the sheet -------------------------------------------------------------------------------

func _write(far_plane_px: float) -> void:
	var base := ProjectSettings.globalize_path("res://").path_join(out_dir)
	DirAccess.make_dir_recursive_absolute(base)
	var margin := 22.0
	var gap := 14.0
	var row_h := 310.0 + 56.0
	var w := int(margin * 2.0 + NEAR_CROP.size.x + FAR_CROP.size.x + SEL_CROP_SIZE.x + gap * 2.0)
	var head_h := 118.0
	var pal_h := 350.0
	var h := int(head_h + row_h * float(options.size()) + pal_h)
	var sh := BoardSheet.new(style, Vector2i(w, h))
	sh.text(Vector2(margin, 34), "Own units stand out  ·  seed %d, the running sandbox" % SEED, 25.0, sh.c_text)
	sh.text(Vector2(margin, 58), "Alex: \"how to make your own units stand out visually on the busy background\". The same three planes (two yours, one AI bomber), the same map and fog, shadows at 44%, shadow-side pen; only marker.standout.mode changes.", 12.5, sh.c_muted, true)
	sh.text(Vector2(margin, 76), "Left: zoom 1 (a light fighter is 36 px). Middle: the far play zoom 0.35, planes at their minimum size (a light fighter is %.0f px), with the fog's inked edge. Right: zoom 1, the heavy fighter selected (ring and leader)." % far_plane_px, 12.5, sh.c_muted, true)
	sh.text(Vector2(margin, 94), "Every option is PROPOSED by Track U1; nothing is chosen. Crops are 1:1 from the game's own frames.", 12.5, sh.c_muted, true)
	sh.text(Vector2(margin + NEAR_CROP.size.x + gap, 112), "far play zoom, zoom 0.35 -- fog edge at the right", 11.5, sh.c_muted, true)
	sh.text(Vector2(margin, 112), "zoom 1", 11.5, sh.c_muted, true)
	sh.text(Vector2(margin + NEAR_CROP.size.x + FAR_CROP.size.x + gap * 2.0, 112), "selected", 11.5, sh.c_muted, true)
	var y := head_h
	var records: Array = []
	var sel_rect := _sel_rect
	for o: Dictionary in options:
		var id: String = o["id"]
		sh.text(Vector2(margin, y + 16), "%s  ·  %s" % [o["letter"], o["title"]], 17.0, sh.c_text)
		sh.text(Vector2(margin + 250, y + 16), _param_line(str(o["mode"])), 12.0, sh.c_muted, true)
		var iy := y + 24.0
		sh.image(near[id], Vector2(margin, iy), NEAR_CROP)
		sh.image(far[id], Vector2(margin + NEAR_CROP.size.x + gap, iy), FAR_CROP)
		sh.image(sel[id], Vector2(margin + NEAR_CROP.size.x + FAR_CROP.size.x + gap * 2.0, iy), sel_rect)
		sh.paragraph(Vector2(margin, iy + 310.0 + 2.0), str(o["line"]), 12.0, sh.c_muted, float(w) - margin * 2.0, true)
		y += row_h
		# One PNG per option: the two full frames, zoom 1 over far.
		var both := Image.create(1280, 1440, false, Image.FORMAT_RGBA8)
		both.blit_rect(near[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 0))
		both.blit_rect(far[id], Rect2i(0, 0, 1280, 720), Vector2i(0, 720))
		var err := both.save_png(base.path_join(id + ".png"))
		if err != OK:
			failures += 1
			printerr("[standout-board] could not write ", id, ".png: ", error_string(err))
		records.append(_record(o))
	_palette_strip(sh, Vector2(margin, y + 14.0), float(w) - margin * 2.0)
	var err2: int = await sh.save(self, base.path_join("board.png"))
	if err2 != OK:
		failures += 1
		printerr("[standout-board] could not write board.png: ", error_string(err2))
	else:
		_say("saved %s (%d x %d)" % [base.path_join("board.png"), w, h])
	_write_json(base.path_join("board.json"), records, far_plane_px)

# The effective values of a mode, for the caption and the record.
func _param_line(mode: String) -> String:
	if mode == "none":
		return "marker.standout.mode = none (the data's default)"
	var parts := PackedStringArray()
	for token: String in mode.split("+", false):
		var d: Dictionary = style.ui["marker"]["standout"][token]
		for k: String in d:
			if k.begins_with("_"):
				continue
			var v: Variant = d[k]
			if v is Dictionary:
				parts.append("%s %s @ %s" % [k, str((v as Dictionary).get("base", "")), str((v as Dictionary).get("alpha", ""))])
			else:
				parts.append("%s %s" % [k, str(v)])
	return "marker.standout.mode = %s  ·  %s" % [mode, "  ·  ".join(parts)]

func _record(o: Dictionary) -> Dictionary:
	var mode := str(o["mode"])
	var rec := {
		"name": o["letter"],
		"title": o["title"],
		"marker.standout.mode": mode,
		"file": o["id"] + ".png",
		"proposed": true,
	}
	var params := {}
	if mode != "none":
		for token: String in mode.split("+", false):
			var d: Dictionary = (style.ui["marker"]["standout"][token] as Dictionary).duplicate(true)
			for k: String in d.keys():
				if k.begins_with("_"):
					d.erase(k)
			params[token] = d
	rec["parameters"] = params
	return rec

func _write_json(path: String, records: Array, far_plane_px: float) -> void:
	var doc := {
		"id": "own-units-stand-out",
		"date": "2026-10-09",
		"area": "Units, UI",
		"question": "How do the players' own units stand out on the busy background (dense trees, scarps, shadows, the fog edge)? Alex: 'a comparison board for figuring out how to make your own units stand out visually on the busy background.' The heavy fighter is faint over trees.",
		"source": "scripts/ui/boards/standout_board_shot.gd: the running sandbox (scripts/app/sandbox.gd) over the real map, photographed once per option with ONLY data/ui/ui.json marker.standout.mode changed",
		"seed": SEED,
		"held_constant": {
			"scene": "the sandbox's three planes (light fighter and heavy fighter player-controlled, bomber AI), medium altitude, around (3000, 3620) m: a dense grove on the plateau edge with a scarp through it, open ground to the west and south",
			"decisions_in_force": "shadow strength 0.44; pen 'shadow_side'; side colours brick red #A45A4E (allies, the players) and slate blue #4E72AC (axis); terrain with contours; level fills as they are; planes at their own scale (light fighter 36 px at zoom 1, never below 14 px); a plane's shadow gap follows its drawn size; fog with sight circles, an inked hatched edge and the topographic outside",
			"views": {
				"zoom_1": "the cluster at the frame's centre-left, camera zoom 1.0, 2 px/m map scale",
				"far_play_zoom": "camera zoom %.2f (data/view/camera.json zoom.start); planes at their minimum size, the light fighter %.0f px wide; the fog's inked edge in view" % [FAR_ZOOM, far_plane_px],
				"selected": "zoom 1 with the heavy fighter selected (the selection ring and leader), planner fan hidden"
			},
			"far_zoom_note": "At zoom 1 the sight edge (800 m = 1,600 px) is off screen; it shows at the far zoom only."
		},
		"parameter": "data/ui/ui.json#marker.standout.mode (and the values of marker.standout.<mode>); 'none' is today's marker, drawn exactly as before. A mode may join effects with '+' (for example 'halo+ring').",
		"options": records,
		"palette_check": "No option adds a hue: halo and lift are PAPER (L 0.847, the ground's own colour) at alpha %s / %s, rim is INK at %s, ring is the unit's own side accent (side_a, side_b: equal OKLCH L 0.551, C 0.100) with an ink hairline at %s. The plane's fill (object fill, L 0.925) stays one step lighter than the paper it sits on; the halo's gain is a calm field (the trees' inked edges and shadows erased), not more lightness contrast." % [
			str(style.ui["marker"]["standout"]["halo"]["role"]["alpha"]), str(style.ui["marker"]["standout"]["lift"]["role"]["alpha"]),
			str(style.ui["marker"]["standout"]["rim"]["role"]["alpha"]), str(style.ui["marker"]["standout"]["ring"]["rim_role"]["alpha"])],
		"sheet": "board.png (rows A-F: zoom 1 | far play zoom | selected; a palette strip below)",
		"chosen": null,
		"chosen_by": null,
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		failures += 1
		printerr("[standout-board] could not write ", path)
		return
	f.store_string(JSON.stringify(doc, "  ", false))
	f.close()
	_say("saved " + path)

# --- the palette strip (working rule 6: every art choice includes the palette) ---------------

func _palette_strip(sh: BoardSheet, pos: Vector2, width: float) -> void:
	sh.line(pos, pos + Vector2(width, 0.0), sh.c_rule, 1.0)
	sh.text(pos + Vector2(0, 26), "The palette, and what each option does to it", 16.0, sh.c_text)
	var chips := [
		["paper", "paper", {}],
		["object fill", "object_fill", {}],
		["ink", "ink", {}],
		["shadow", "shadow", {}],
		["side_a (yours)", "side_a", {}],
		["side_b (enemy)", "side_b", {}],
	]
	var x := pos.x
	for c: Array in chips:
		var col: Color = style.palette[c[1]]
		sh.chip(Vector2(x, pos.y + 40.0), col, str(c[0]), BoardSheet.oklch_text(col))
		x += 148.0
	# The roles the options add.
	var d: Dictionary = style.ui["marker"]["standout"]
	var used := [
		["B halo", d["halo"]["role"]],
		["C lift", d["lift"]["role"]],
		["D rim", d["rim"]["role"]],
		["E ring edge", d["ring"]["rim_role"]],
	]
	var ux := pos.x + 6.0 * 148.0 + 24.0
	for u: Array in used:
		var col: Color = UiRoles.resolve(style, u[1], "board " + str(u[0]))
		sh.chip(Vector2(ux, pos.y + 40.0), col, str(u[0]), "%s @ %.2f" % [str(u[1].get("base")), col.a], Vector2(62, 40))
		ux += 100.0
	var ty := pos.y + 134.0
	var fill_l: float = BoardSheet.oklch(style.palette["object_fill"]).x
	var paper_l: float = BoardSheet.oklch(style.palette["paper"]).x
	var ink_l: float = BoardSheet.oklch(style.palette["ink"]).x
	var lines := [
		"Hue stays reserved for paper, ink, shadow and the side accents (docs/proposals/palette-architecture.md): halo and lift are paper, rim is ink, the ring is the unit's own accent. Nothing here adds a colour.",
		"Lightness ramp: the plane fill (object fill, L %.3f) sits one step above the paper (L %.3f) that the halo and the lift put under it, and the outline is ink (L %.3f). Against a cream canopy the outline has dL %.2f; against paper dL %.2f, a little less. So what the halo gives the plane is a calm field (the trees' own inked edges and shadows erased), not more lightness contrast." % [fill_l, paper_l, ink_l, fill_l - ink_l, paper_l - ink_l],
		"The ring is the one option that uses an accent: it spends side_a (chroma 0.100) outside the plane, so the roundel colour is no longer unique to the wings and the roster mark; side_b is never used by it (the AI's units get no effect).",
		"Material is still linework: nothing is shaded or textured; the shadow tint is unchanged and no option draws over a plane's own shadow.",
	]
	var yy := ty
	for l: String in lines:
		yy += sh.paragraph(Vector2(pos.x, yy), l, 12.0, sh.c_muted, width - 330.0, false, 3.0) + 5.0
	# The roster as the game shows it, beside the colours it shares with the ring.
	sh.text(Vector2(pos.x + width - 300.0, ty - 6.0), "the roster's own marks (same two accents)", 11.5, sh.c_muted, true)
	sh.image(near[options[0]["id"]], Vector2(pos.x + width - 300.0, ty), Rect2(978.0, 10.0, 292.0, 184.0))
