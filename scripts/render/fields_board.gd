extends "res://scripts/render/village_shot.gd"

# THE FIELDS BOARD (Track W, 2026-10-10): how the fields round the village are drawn, four options
# from ONE seed over the REAL map (the terrain provider's own bake), beside the village, at
# several zooms. WINDOWED ONLY:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . `
#       --script res://scripts/render/fields_board.gd -- 20261009 variants/fields
#
# It writes into the output folder (variants/fields/, README.md there):
#   frames/<option>_<view>.png   every frame at NATIVE size (1280 x 720; the swatch strips 1280 x 256),
#                                one file each: Alex reads boards in a full-resolution viewer
#   frames.json                  the captions, grouped the way damage-smoke-r2's are (option > rows > frames)
#   board.json                   the question, what is held constant, the options and `chosen: null`
#   board.png                    a contact sheet of the play-zoom frames (shrunk; the frames are the board)
#
# THE OPTIONS are data (data/terrain/terrain.json draw.fields.styles: what each kind of field carries)
# and the board changes ONE thing, `draw.fields.style`, between photographs: the layout (the ten
# fields, the village, the road), the trees, the sun, the pen and the camera are the same.
# Every option is judged beside the things it sits with (CLAUDE.md rule 6: the palette stays one
# palette): each option's SWATCH strip puts a field, a tree, a house, a wall and the road side by
# side at zoom 2, 1:1 crops of the same bake.
#
# The recommended option is proposed (the lead's, not Alex's); chosen stays null until Alex picks.

const OPTIONS := [
	{"name": "A", "style": "rows", "title": "Ruled rows",
		"changes": "every field is ruled crop rows in ink at low alpha, a broken edge line, and a quiet wash (dirt or object fill) under it",
		"note": "The cheapest and plainest: ink rows (dense or light) and nothing else. Reads as ploughed ground at zoom 1; the rows thin to a tone at far zoom, held up by the wash. The same treatment ten times reads as a pattern."},
	{"name": "B", "style": "hedgerow", "title": "Hedgerow edges",
		"changes": "fields are bounded by hedges: the tree generator at 0.36 of the usual radius along most edges, a firm edge line, light rows or fallow dirt inside",
		"note": "Reads as farmland at once, even at far zoom, because the hedge beads are dark and the shapes close. Costs sprites (239 small trees on this seed) and casts short shadows; the interior is quiet."},
	{"name": "C", "style": "stipple", "title": "Stipple crops",
		"changes": "crops are rows of ink dots (the stipple vocabulary of the tree shading), fallow is dirt dots, a broken edge line",
		"note": "Softest and closest to the paper's own dirt stipple, so the fields sit very quietly; at zoom 1 it reads as a planted crop, at play zoom as a faint tone, and by far zoom almost not at all."},
	{"name": "D", "style": "mixed", "title": "Mixed (recommended, working default)",
		"changes": "a patchwork: dense rows, stipple crops, a pasture with a hedge on most edges and fallow dirt with a hedge on some, each with its own wash",
		"note": "Reads as farmland at every zoom: neighbouring fields differ, so the eye gets a patchwork instead of a repeated stamp; costs a share of B's sprites (108 hedge trees on this seed). PROPOSED as the working default, not Alex's pick."},
]

const VIEWS := [
	{"key": "close", "zoom": 1.0, "what": "at the village", "caption": "zoom 1.0 on the village: houses, the compound, the road, trees and the nearest fields"},
	{"key": "fields", "zoom": 1.0, "what": "at the fields", "caption": "zoom 1.0 where the fields are thickest"},
	{"key": "play", "zoom": 0.35, "what": "play zoom", "caption": "play zoom 0.35 (the camera's start zoom: a planning view, 1,830 x 1,030 m)"},
	{"key": "far", "zoom": 0.2, "what": "far zoom", "caption": "far zoom 0.2 (3,200 x 1,800 m: the full render a little above where the topographic overview takes over)"},
]

const SWATCH := 256   # a swatch crop: 256 x 256 screen px at zoom 2

func _run() -> void:
	var code := await _board()
	quit(code)

func _board() -> int:
	var made := make_view(root, seed_value, float(opts.get("ppm", "0")), "")
	var vp: SubViewport = made[0]
	var view = made[1]
	if not view.errors().is_empty():
		printerr("[fields-board] errors: ", view.errors())
		return 1
	var layout = view.provider.terrain.layout()
	var v: Dictionary = layout.village()
	var vil = view.provider.terrain.village()
	var spots := _spots(view, layout, vil)
	DirAccess.make_dir_recursive_absolute(out_dir.path_join("frames"))
	var frames_json := {"id": "fields", "size_px": [SIZE.x, SIZE.y], "options": []}
	var play_images: Array[Image] = []
	for o: Dictionary in OPTIONS:
		print("[fields-board] option %s: %s (style %s)" % [o.name, o.title, o.style])
		view.provider.vd.style = o.style
		view.rebake()
		var entry := {"option": o.name, "label": "%s - %s" % [o.name, o.title], "changes": o.changes, "note": o.note, "rows": []}
		# the zooms, far first (it bakes the chunks the closer ones reuse)
		var shots := {}
		for vw: Dictionary in [VIEWS[3], VIEWS[2], VIEWS[0], VIEWS[1]]:
			var at: Vector2 = spots.fields if vw.key == "fields" else v.centre
			look(view, at, vw.zoom)
			await bake_view(view)
			var rel := "frames/%s_%s.png" % [o.name, vw.key]
			shots[vw.key] = save_frame(vp, out_dir.path_join(rel))
		play_images.append(shots["play"])
		# the swatch strip: five 1:1 crops at zoom 2
		var strip := Image.create(SWATCH * 5, SWATCH, false, Image.FORMAT_RGBA8)
		var names := ["a field", "a tree", "a house", "the compound wall", "the road"]
		var order := ["field", "tree", "house", "wall", "road"]
		for k in 5:
			look(view, spots[order[k]], 2.0)
			await bake_view(view)
			var img := vp.get_texture().get_image()
			img.convert(Image.FORMAT_RGBA8)
			var c := Vector2i(SIZE.x / 2, SIZE.y / 2) - Vector2i(SWATCH / 2, SWATCH / 2)
			strip.blit_rect(img, Rect2i(c, Vector2i(SWATCH, SWATCH)), Vector2i(k * SWATCH, 0))
		strip.save_png(out_dir.path_join("frames/%s_swatch.png" % o.name))
		print("[fields-board] saved swatch strip for ", o.name)
		(entry.rows as Array).append({"title": "beside the things it sits with (zoom 2, 1:1 crops: %s)" % ", ".join(names), "frames": [
			{"file": "frames/%s_swatch.png" % o.name, "caption": "swatch row: %s (zoom 2.0, native size 1280 x 256)" % ", ".join(names)}]})
		(entry.rows as Array).append({"title": "in the village", "frames": [
			{"file": "frames/%s_close.png" % o.name, "caption": VIEWS[0].caption},
			{"file": "frames/%s_fields.png" % o.name, "caption": VIEWS[1].caption}]})
		(entry.rows as Array).append({"title": "at play and far zoom", "frames": [
			{"file": "frames/%s_play.png" % o.name, "caption": VIEWS[2].caption},
			{"file": "frames/%s_far.png" % o.name, "caption": VIEWS[3].caption}]})
		(frames_json.options as Array).append(entry)
	# the records
	_write_json(out_dir.path_join("frames.json"), frames_json)
	_write_json(out_dir.path_join("board.json"), _board_record(layout, v, view.provider.terrain.data))
	_contact_sheet(play_images)
	vp.queue_free()
	await _frames(2)
	return 0

# The camera spots (metres) for the swatches and the fields frame.
func _spots(view, layout, vil) -> Dictionary:
	var v: Dictionary = layout.village()
	var ppm: float = view.px_per_m
	var spots := {}
	var fields: Array[PackedVector2Array] = layout.fields()
	var centres: Array[Vector2] = []
	for f in fields:
		var c := Vector2.ZERO
		for q in f:
			c += q
		centres.append(c / float(f.size()))
	# the 640 x 360 m window (zoom 1) holding the most field centres; its middle
	var best_n := -1
	var best_at: Vector2 = v.centre
	for c in centres:
		for off: Vector2 in [Vector2.ZERO, Vector2(-100, 0), Vector2(100, 0), Vector2(0, -60), Vector2(0, 60)]:
			var win := Rect2(c + off - Vector2(320, 180), Vector2(640, 360))
			var n := 0
			for d in centres:
				if win.has_point(d):
					n += 1
			if n > best_n:
				best_n = n
				best_at = c + off
	spots["fields"] = best_at
	# swatches: the field nearest the village, its middle
	var nearest := 0
	var nd := INF
	for i in centres.size():
		var d := centres[i].distance_to(v.centre)
		if d < nd:
			nd = d
			nearest = i
	spots["field"] = centres[nearest]
	for s: Dictionary in vil.structs:
		if s.role == "house" and not spots.has("house"):
			spots["house"] = Vector2(s.geo[0].cx, s.geo[0].cy) / ppm
	spots["wall"] = (vil.compound.yard as PackedVector2Array)[0] / ppm
	var road: PackedVector2Array = layout.road()
	spots["road"] = road[road.size() / 2]
	for p in road:
		if p.distance_to(v.centre) > 260.0:
			spots["road"] = p
			break
	# a tree: the nearest regular tree to the village's middle that is not on a field edge
	var terrain = view.provider.terrain
	var vc := Vector2(v.centre) * ppm
	var best_tree := Vector2.ZERO
	var best_d := INF
	for t: Dictionary in terrain.trees_in_rect_px(Rect2(vc - Vector2(700, 700), Vector2(1400, 1400))):
		var p := Vector2(t.x, t.y)
		var d := p.distance_to(vc)
		if d < best_d and t.level == 0 and not vil.in_village(p.x, p.y) and float(t.r) > 14.0:
			best_d = d
			best_tree = p
	spots["tree"] = best_tree / ppm
	return spots

func _write_json(path: String, d: Variant) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", false))
	f.close()
	print("[fields-board] wrote ", path)

func _board_record(layout, v: Dictionary, d) -> Dictionary:
	var opts_rec: Array = []
	for o: Dictionary in OPTIONS:
		opts_rec.append({"name": o.name, "title": o.title, "draw.fields.style": o.style, "changes": o.changes,
			"proposed": true, "recommended": o.name == "D", "frames": ["frames/%s_%s.png" % [o.name, "close"]]})
	return {
		"id": "fields",
		"date": "2026-10-10",
		"area": "Terrain, Map generation",
		"question": "How are the fields round the strike's village drawn? (The doc's backlog row: 'Fields and farmland: field patterns, hedgerows and crops as scatter.')",
		"source": "scripts/render/fields_board.gd over the real map (the terrain provider's own bake, the MapView in a 1280 x 720 viewport) at 2 px/m; only data/terrain/terrain.json draw.fields.style changes between photographs",
		"seed": seed_value,
		"parameter": "data/terrain/terrain.json#draw.fields.style (and .styles, .rows, .stipple, .edge, .hedge, .tone: every value a proposed record)",
		"held_constant": {
			"layout": "the village at %s m, its ten fields, the road and the radio tower's compound are the world layout's (data/world/layout.json), identical in every frame; trees keep off fields in every option" % [v.centre],
			"light": "sun azimuth 315, elevation 46; shadow strength 0.44; pen shadow side",
			"zooms": "1.0 (two frames), 0.35 (play zoom: the camera's start) and 0.2 (far zoom: the full render, above data/view/camera.json far_zoom.topo_below_zoom 0.11); the swatch strips at 2.0, 1:1",
		},
		"palette": "ink and dirt at alpha steps read from the data (rows %.2f to %.2f, edges %.2f to %.2f, crop dots %.2f to %.2f, fallow dirt %.2f to %.2f), washes of dirt (alpha %.2f) or the object fill (alpha %.2f: paper lifted one fill-ramp step); weights are the linework table's own multipliers (cusp ticks 0.75, road ruts 0.8); no new hue and no hex in draw code. Each option's swatch strip puts a field beside a tree, a house, the compound wall and the road, 1:1." % [
			d.num("draw.fields.rows.light.alpha"), d.num("draw.fields.rows.dense.alpha"), d.num("draw.fields.edge.line.alpha"), d.num("draw.fields.edge.heavy.alpha"),
			d.floats("draw.fields.stipple.crop.alpha")[0], d.floats("draw.fields.stipple.crop.alpha")[1], d.floats("draw.fields.stipple.fallow.alpha")[0],
			d.floats("draw.fields.stipple.fallow.alpha")[1], d.num("draw.fields.tone.dirt_alpha"), d.num("draw.fields.tone.cream_alpha")],
		"options": opts_rec,
		"frames": "frames.json: every frame at native size in frames/",
		"sheet": "board.png (contact sheet of the play-zoom frames, shrunk; the frames are the board)",
		"recommended": "D (proposed by the lead): a patchwork reads as farmland at every zoom",
		"chosen": null,
		"chosen_by": null,
		"working_default": "D (data/terrain/terrain.json draw.fields.style = mixed), PROPOSED, until Alex picks",
	}

func _contact_sheet(images: Array[Image]) -> void:
	if images.is_empty():
		return
	var w := SIZE.x / 2
	var h := SIZE.y / 2
	var sheet := Image.create(w * 2 + 12, h * 2 + 12, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.15, 0.15, 0.15))
	for i in images.size():
		var im := images[i].duplicate() as Image
		im.convert(Image.FORMAT_RGBA8)
		im.resize(w, h, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(im, Rect2i(Vector2i.ZERO, im.get_size()), Vector2i(4 + (i % 2) * (w + 4), 4 + (i / 2) * (h + 4)))
	sheet.save_png(out_dir.path_join("board.png"))
	print("[fields-board] wrote board.png")
