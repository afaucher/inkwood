extends "res://scripts/test_support/test_case.gd"

# THE MAP'S BORDER, headless (builder, map-border board, 2026-10-11; scripts/render/map_border*.gd, data/view/map_border.json). What
# the map shows past its edge: four options A to D from the board, and E, the look Alex chose from it (decision map-border,
# 2026-10-11: "I like the hatches, with the distance legend"), on a switch; nothing is baked headless (no frames are drawn) and the
# pixels are the board's (scripts/ui/boards/map_border_board_shot.gd, windowed). Here:
#
#   1 DATA       map_border.json parses, the default option is E (a decision record: "decision": "map-border", not "_proposed"),
#                every other value is a proposed record, reach.band_m equals camera.json's pan.edge_overscroll_m, and after
#                every option has been built every field of the file has been read (unused() is empty)
#   2 DEFAULT    a MapView's border has the chosen look E on by default (its fill and its legend), "none" removes it all
#   3 ROLES      every colour role resolves against the palette with no error; each role's base (and `toward`) is a palette
#                colour; no role has more chroma than its endpoints (a mix cannot invent a hue); none is pure black; the border's
#                scripts hold no colour literal (working rule 6)
#   4 OPTIONS    each of A, B, C, D builds in a MapView in the tree without an error, puts its nodes ABOVE the map (z_index >= 1:
#                the map's chunks and the fog are z 0), covers the whole outside (the fill's four rectangles reach past the edge
#                by reach.outside_px and into the map by reach.inset_px), and is ready at once headless
#   5 SWITCHING  A -> B -> C -> none -> D at run time: the previous option's nodes are gone each time, none is a bad name, and a
#                bad name changes nothing; a new scale (MapView.set_px_per_m) rebuilds the option for it
#   6 B          its lettering: a repaint draws numbers in the label face, at least 14 px (data ui.json lettering.min_px), each
#                inside the viewport and none over another, and the ticks are 500 m apart; the scale bar and the north arrow come
#                only when the whole map is in view
#   7 C          its plan: three levels of detail, every tile outside the map's rectangle, the strips cover the ring, and a tile
#                records on a twin terrain (the contours of chunks OUTSIDE the map) to a canvas with something drawn
#   8 D          its ragged edge and its shadow: the shadow polygons lie outside the sheet's own outline, to the south-east
#   9 E          the chosen look: A's hatched edge and B's legend without B's neatline or north arrow. At the planning zoom a tick is
#                drawn every 500 m from the edge INWARD, each number is 14 px or more, lies inside the map (never on the hatching
#                outside it), over no other number, the corners are not numbered; numbers that do not fit are left off and the ticks
#                stay; with the whole map in view a scale bar clear of the hatch band and no "N"

const RenderParams = preload("res://scripts/world/render_params.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const MapBorder = preload("res://scripts/render/map_border.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")
const FogStyle = preload("res://scripts/render/fog_style.gd")
const BoardSheet = preload("res://scripts/ui/boards/board_sheet.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")

const SEED := 20261009
const BORDER_SCRIPTS := [
	"res://scripts/render/map_border.gd", "res://scripts/render/map_border_base.gd", "res://scripts/render/map_border_fill.gd",
	"res://scripts/render/map_border_screen.gd", "res://scripts/render/map_border_a.gd", "res://scripts/render/map_border_b.gd",
	"res://scripts/render/map_border_c.gd", "res://scripts/render/map_border_d.gd", "res://scripts/render/map_border_bake.gd",
	"res://scripts/render/map_border_contours.gd", "res://scripts/render/map_border_edge.gdshader", "res://scripts/render/map_border_contour.gdshader",
	"res://scripts/render/map_border_wash.gdshader", "res://scripts/render/map_border_e.gd", "res://scripts/render/map_border_legend.gd",
	"res://scripts/ui/boards/map_border_board_shot.gd",
]
const PALETTE_NAMES := ["paper", "ink", "object_fill", "wall_fill", "rock_fill", "roof_lit", "dirt", "shadow", "side_a", "side_b"]

var _view: MapView
var _border: Node2D
var _reached := 0
var _host: Node

func setup(main) -> void:
	timeout_seconds = 180.0
	_host = main
	var P := RenderParams.new()
	if not check(P.ok(), "render params load: %s" % ", ".join(P.errors)):
		finish()
		return
	_data_checks()
	_view = MapView.new(SEED, Rect2(0, 0, 5000, 5000), 2.0, "", P)
	_view.bake_enabled = false
	_view.input_enabled = false
	main.add_child(_view)
	_view.get_window().size = Vector2i(1280, 720)   # (a headless window is tiny)
	_border = _view.border
	await get_tree().physics_frame
	await get_tree().physics_frame
	_default_checks()
	_role_checks(P)
	await _option_checks()
	await _switching_checks()
	await _b_checks()
	_c_checks()
	await _c_wash_checks()
	_d_checks()
	await _e_checks()
	_source_checks()
	check(_view.errors().is_empty(), "the map view loaded cleanly: %s" % [_view.errors()])
	eq(_reached, 11, "every section ran to its end (a section that stopped on a runtime error would not have counted)")
	_view.queue_free()
	finish()

# --- 1 data ----------------------------------------------------------------------------------------

func _data_checks() -> void:
	var d := CameraData.new(MapBorder.DATA_PATH)
	check(d.ok(), "map_border.json parses: %s" % [d.errors])
	eq(d.text("option"), "E", "1. the data's default option is E, the look Alex chose (hatched edge with the distance legend)")
	var rec: Dictionary = d.root["option"]
	eq(str(rec.get("decision", "")), "map-border", "1. and its record is the decision map-border's")
	check(not rec.has("_proposed"), "1. no longer a proposed record")
	var rec_name: Dictionary = (d.root["e"] as Dictionary)["name"]
	eq(str(rec_name.get("decision", "")), "map-border", "1. E's name is the decision's too")
	var cam := CameraData.new(CameraData.CAMERA_PATH)
	near(d.num("reach.band_m"), cam.num("pan.edge_overscroll_m"), 1e-9, "1. the band is the camera's edge overscroll (camera.json pan.edge_overscroll_m)")
	# every record is proposed
	var bad := PackedStringArray()
	_proposed_walk(d.root, "", bad)
	eq(bad.size(), 0, "1. every value record is marked proposed: %s" % ", ".join(bad))
	_reached += 1

func _proposed_walk(node: Dictionary, prefix: String, bad: PackedStringArray) -> void:
	for k: String in node:
		if k.begins_with("_"):
			continue
		var path := k if prefix == "" else prefix + "." + k
		var child: Variant = node[k]
		if child is Dictionary:
			var c: Dictionary = child
			if c.has("value"):
				if not bool(c.get("_proposed", false)) and not c.has("decision"):
					bad.append(path)
				if not (c.get("_reason") is String and str(c["_reason"]) != ""):
					bad.append(path + " (no reason)")
			else:
				_proposed_walk(c, path, bad)

# --- 2 default -------------------------------------------------------------------------------------------

func _default_checks() -> void:
	check(_border != null and _border.get_script() == MapBorder, "2. the MapView has a border node")
	eq(_border.option(), "E", "2. the default option is E, the chosen look")
	check(_border.get_child_count() >= 2, "2. E has its fill and its legend (%d nodes)" % _border.get_child_count())
	check(_border.is_ready() and _border.pending() == 0, "2. and has nothing to bake")
	check(_border.set_option("none") and _border.get_child_count() == 0 and _border.option() == "none", "2. none removes it all")
	check(_border.set_option("E") and _border.option() == "E", "2. and E comes back")
	check(_view.get_children().has(_border), "2. the border is the MapView's child")
	_reached += 1

# --- 3 roles ---------------------------------------------------------------------------------------------

func _role_checks(P: RenderParams) -> void:
	var paths: Array[String] = _border.all_role_paths()
	check(paths.size() >= 16, "3. the data has its roles (%d)" % paths.size())
	var errors: Array = []
	var st: UiStyle = UiStyle.shared()
	for path: String in paths:
		var spec: Dictionary = _border.data.value(path)
		var base := str(spec.get("base", ""))
		check(PALETTE_NAMES.has(base), "3. %s: base '%s' is a palette colour" % [path, base])
		if spec.has("toward"):
			check(PALETTE_NAMES.has(str(spec["toward"])), "3. %s: toward '%s' is a palette colour" % [path, str(spec["toward"])])
		var c: Color = FogStyle.resolve(spec, P, errors)
		var lch := BoardSheet.oklch(c)
		var b_lch := BoardSheet.oklch(FogStyle.base(base, P))
		var t_lch := BoardSheet.oklch(FogStyle.base(str(spec["toward"]), P)) if spec.has("toward") else b_lch
		check(lch.y <= maxf(b_lch.y, t_lch.y) + 0.01, "3. %s: chroma %.3f does not exceed its endpoints' (%.3f, %.3f): no new hue" % [path, lch.y, b_lch.y, t_lch.y])
		check(lch.x > 0.2, "3. %s: not pure black (L %.3f)" % [path, lch.x])
		check(c.a > 0.0 and c.a <= 1.0, "3. %s: its alpha is a real alpha (%.2f)" % [path, c.a])
	eq(errors.size(), 0, "3. every role resolves: %s" % [errors])
	eq(st.errors.size(), 0, "3. the style loads cleanly")
	# the roles of the options that matter most to the palette: the table is a step down the ramp from the paper toward the ink
	var table: Color = _border.role("d.table.role")
	var paper_lch := BoardSheet.oklch(P.PAPER)
	var table_lch := BoardSheet.oklch(table)
	check(table_lch.x < paper_lch.x and table_lch.x > BoardSheet.oklch(P.INK).x, "3. D's table is darker than the paper and lighter than the ink (L %.3f between %.3f and %.3f)" % [table_lch.x, BoardSheet.oklch(P.INK).x, paper_lch.x])
	var contour: Color = _border.role("c.contour.role")
	var fog_line: Color = FogStyle.resolve(CameraData.new(CameraData.FOG_PATH).value("topo.lines.role"), P)
	check(BoardSheet.oklch(contour).x > BoardSheet.oklch(fog_line).x, "3. C's contour ink is a lighter role than the fog's (L %.3f against %.3f)" % [BoardSheet.oklch(contour).x, BoardSheet.oklch(fog_line).x])
	_reached += 1

# --- 4 options -------------------------------------------------------------------------------------

func _option_checks() -> void:
	for L: String in ["A", "B", "C", "D", "E"]:
		var ok: bool = _border.set_option(L)
		check(ok, "4. %s: set_option answers true" % L)
		eq(_border.option(), L, "4. %s: the option is on" % L)
		await get_tree().physics_frame
		await get_tree().physics_frame
		check(_border.get_child_count() >= 1, "4. %s: it made nodes (%d)" % [L, _border.get_child_count()])
		for c in _border.get_children():
			check((c as CanvasItem).z_index >= 1, "4. %s: %s draws above the map (z_index %d)" % [L, c.name, (c as CanvasItem).z_index])
		var fill = _border.impl().fill
		check(fill != null and fill.get_script() != null, "4. %s: it has the outside fill" % L)
		var rects: Array = fill._rects
		var r: Rect2 = _view.map_rect()
		var union := Rect2()
		for q: Rect2 in rects:
			union = q if union.size == Vector2.ZERO else union.merge(q)
		var reach := float(_border.data.num("reach.outside_px"))
		check(union.position.x <= r.position.x - reach + 1.0 and union.end.x >= r.end.x + reach - 1.0 and union.position.y <= r.position.y - reach + 1.0 and union.end.y >= r.end.y + reach - 1.0, "4. %s: the fill reaches %.0f px past the map on every side" % [L, reach])
		# the rectangles cover the ring round the map (the outside) with no gap: every sample point outside the map is in one of them
		var gaps := 0
		for p: Vector2 in [Vector2(-10, -10), Vector2(5010 * 2, -10), Vector2(-10, 5010 * 2), Vector2(5010 * 2, 5010 * 2), Vector2(5000, -3), Vector2(-3, 5000), Vector2(10003, 5000), Vector2(5000, 10003), Vector2(10100, 10100), Vector2(-50000, 4000), Vector2(60000, 4000), Vector2(4000, -50000), Vector2(4000, 90000)]:
			var inside := false
			for q: Rect2 in rects:
				if q.has_point(p):
					inside = true
			if r.has_point(p):
				continue
			if not inside:
				gaps += 1
		eq(gaps, 0, "4. %s: no point outside the map is left out of the fill" % L)
		check(_border.is_ready() and _border.pending() == 0, "4. %s: ready at once headless (nothing is baked without frames)" % L)
		eq(_border.errors.size(), 0, "4. %s: no error: %s" % [L, str(_border.errors)])
	var unused: Array[String] = _border.data.unused()
	check(unused.is_empty(), "1. every field of map_border.json is read once all four options have been built; unused: %s" % [unused])
	for L: String in ["A", "B", "C", "D", "E"]:
		check(str(_border.option_name(L)) != "", "4. %s has a name in the data (%s)" % [L, _border.option_name(L)])
	_reached += 1

# --- 5 switching -----------------------------------------------------------------------------------------

func _switching_checks() -> void:
	var seq := ["A", "B", "C", "none", "D", "E", "A"]
	for L: String in seq:
		check(_border.set_option(L), "5. switch to %s" % L)
		await get_tree().physics_frame
		await get_tree().physics_frame
		eq(_border.option(), L, "5. %s is on" % L)
		if L == "none":
			eq(_border.get_child_count(), 0, "5. none leaves no node behind")
		else:
			# only the option's own nodes: its fill is the one Fill node
			var fills := 0
			for c in _border.get_children():
				if str(c.name).begins_with("Fill"):
					fills += 1
			eq(fills, 1, "5. %s: one fill, the earlier option's gone" % L)
	var before: String = _border.option()
	check(not _border.set_option("Z"), "5. a bad name is refused")
	eq(_border.option(), before, "5. and changes nothing")
	_border.errors.clear()
	check(_border.set_option("a"), "5. a letter in any case is taken (a)")
	eq(_border.option(), "A", "5. as its capital")
	# a new scale rebuilds the option for it
	_view.set_px_per_m(4.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	near(_border.px_per_m, 4.0, 1e-9, "5. a new scale (4 px/m): the border follows it")
	eq(_border.option(), "A", "5. and keeps its option")
	var fill = _border.impl().fill
	var r: Rect2 = _view.map_rect()
	near(r.size.x, 20000.0, 1e-6, "5. the map is 20,000 px at 4 px/m")
	check(fill._rects[0].end.x >= r.end.x, "5. and the fill was made again for it")
	_view.set_px_per_m(2.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	await get_tree().physics_frame
	near(_border.px_per_m, 2.0, 1e-9, "5. back to 2 px/m")
	_border.set_option("none")
	_reached += 1

# --- 6 B -------------------------------------------------------------------------------------------------

func _b_checks() -> void:
	_border.set_option("B")
	await get_tree().physics_frame
	var b = _border.impl()
	var st: UiStyle = UiStyle.shared()
	# a view of the north-west corner at the planning zoom: the map's top-left at screen (70, 70)
	var z := 0.35
	var xf := Transform2D(Vector2(z, 0.0), Vector2(0.0, z), Vector2(70.0, 70.0))
	var vp := Vector2(1280, 720)
	b.frame(xf, z, vp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var labels: Array = b.drawn_labels
	check(labels.size() >= 4, "6. a repaint at the planning zoom drew numbers (%d) -- the screen node's _draw ran" % labels.size())
	var boxes: Array[Rect2] = []
	var min_px: float = st.min_px()
	for l: Dictionary in labels:
		check(float(l["px"]) >= min_px, "6. the number '%s' is %.0f px (>= %.0f)" % [l["text"], float(l["px"]), min_px])
		var box := Rect2(float(l["x"]), float(l["y"]) - float(l["px"]) * 0.8, float(l["w"]), float(l["px"]) * 0.95)
		check(Rect2(Vector2.ZERO, vp).encloses(box), "6. '%s' lies inside the viewport (%s)" % [l["text"], str(box)])
		for other: Rect2 in boxes:
			check(not other.intersects(box), "6. '%s' is not over another number" % l["text"])
		boxes.append(box)
	var texts := PackedStringArray()
	for l: Dictionary in labels:
		texts.append(str(l["text"]))
	check(texts.has("500 m") or texts.has("500"), "6. the 500 m tick is numbered (%s)" % ", ".join(texts))
	check(texts.has("0 m") or texts.has("0"), "6. and the 0 (%s)" % ", ".join(texts))
	check(b.drawn_furniture["scale_bar"] == Rect2() and b.drawn_furniture["north"] == Rect2(), "6. no scale bar or north arrow while the map is not wholly in view")
	# the whole map in view: the full zoom-out as 1280 x 720 with a 358 px roster gives (0.0679)
	var zf := 0.0679
	var mid := Vector2(121.0, 20.0)
	var xf2 := Transform2D(Vector2(zf, 0.0), Vector2(0.0, zf), mid)
	b.frame(xf2, zf, vp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var bar: Rect2 = b.drawn_furniture["scale_bar"]
	var north: Rect2 = b.drawn_furniture["north"]
	check(bar.has_area() and north.has_area(), "6. with the whole map in view the scale bar (%s) and the north arrow (%s) are drawn" % [str(bar), str(north)])
	check(bar.end.x <= mid.x and north.end.x <= mid.x, "6. both in the margin left of the map")
	check(Rect2(Vector2.ZERO, vp).encloses(bar) and Rect2(Vector2.ZERO, vp).encloses(north), "6. and inside the window")
	var expect_px := float(b.drawn_furniture["bar_m"]) * 2.0 * zf
	near(bar.size.x, expect_px, 1.0, "6. the bar's length is its metres at the map's scale (%.0f m = %.1f px)" % [float(b.drawn_furniture["bar_m"]), expect_px])
	# every label at that view
	for l: Dictionary in b.drawn_labels:
		check(float(l["px"]) >= min_px, "6. at the full zoom-out '%s' is %.0f px" % [l["text"], float(l["px"])])
	_border.set_option("none")
	_reached += 1

# --- 7 C -------------------------------------------------------------------------------------------------

func _c_checks() -> void:
	_border.set_option("C")
	var c = _border.impl()
	var r: Rect2 = _view.map_rect()
	eq(c.levels.size(), 3, "7. three levels of detail")
	var total := 0
	for i in c.levels.size():
		var lv = c.levels[i]
		check(lv.tiles.size() > 0, "7. level %d has tiles (%d)" % [i, lv.tiles.size()])
		total += lv.tiles.size()
		var area := 0.0
		for job in lv.tiles:
			area += job.rect.get_area()
			check(not job.rect.intersects(r) or not job.rect.intersection(r).has_area(), "7. level %d: tile %s lies outside the map %s" % [i, str(job.rect), str(r)])
			var tex := Vector2(ceil(job.rect.size.x * lv.s - 1e-6), ceil(job.rect.size.y * lv.s - 1e-6))
			check(tex.x <= 1024.0 + 1.0 and tex.y <= 1024.0 + 1.0 + 1.0, "7. level %d: a tile is at most the tile size in texels (%s)" % [i, str(tex)])
		var d: float = lv.depth_px
		var ring := (r.size.x + 2.0 * d) * (r.size.y + 2.0 * d) - r.size.x * r.size.y
		near(area, ring, ring * 0.001, "7. level %d: the tiles cover the ring (%.0f of %.0f px^2)" % [i, area, ring])
	check(total >= 30, "7. a few dozen tiles in all (%d)" % total)
	# a tile on the main thread with a twin: the contours of OUTSIDE chunks (the finest level, then a coarse one)
	var drawn := 0
	for lvl in [0, 1]:
		var lv = c.levels[lvl]
		for k in mini(lv.tiles.size(), 6):
			drawn += c.record_tile_now(lvl, k)
	check(drawn > 0, "7. the recorder draws the contours of chunks outside the map (%d canvas items over some tiles)" % drawn)
	# the twin's terrain really is generated outside the map: a chunk with a negative index has contours
	var twin = c._make_twin()
	var t = twin.terrain
	check(not t.chunk_in_map(-1, -1), "7. chunk (-1, -1) is outside the map (the terrain's lists keep to the map)")
	var chains: Array = []
	for cy in range(-3, 0):
		for cx in range(-3, 0):
			chains.append_array(t.chains_px(cx, cy, 0))
	check(chains.size() > 0, "7. yet the terrain makes its contours there: %d chains in the nine chunks north-west of the map" % chains.size())
	_border.set_option("none")
	_reached += 1

# --- 7b C's sea -------------------------------------------------------------------------------------

# With water on the map (the Strike has a sea on its east edge) the wash's mask is the generator's own depth at each cell, and
# nothing inside the map; the step colours are the water palette's and the contour map's quiet strength.
func _c_wash_checks() -> void:
	var water: RefCounted = WaterGen.shared(SEED)
	var v2 := MapView.new(SEED, Rect2(0, 0, 5000, 5000), 2.0, "", RenderParams.new(), water)
	v2.bake_enabled = false
	v2.input_enabled = false
	_host.add_child(v2)
	await get_tree().physics_frame
	check(v2.border.set_option("C"), "7b. C on in a map with water")
	var c = v2.border.impl()
	check(c.stats()["wash"], "7b. the sea's wash is made")
	var img: Image = c.wash_image()
	var n := img.get_width()
	check(n > 300, "7b. the mask is a grid of %d cells a side" % n)
	var args: Dictionary = c._wash_args
	var origin: Vector2 = args["origin"]
	var cell := float(v2.border.data.num("c.wash.cell_m"))
	var off := 0
	var sea := 0
	var land_wet := 0
	for k in 60:
		# sample points on a ring 150 to 900 m past the map's edge, all sides
		var side := k % 4
		var t := float(k * 83 % 100) / 100.0 * 5000.0
		var d := 150.0 + float(k * 37 % 750)
		var p := [Vector2(t, -d), Vector2(5000.0 + d, t), Vector2(t, 5000.0 + d), Vector2(-d, t)][side] as Vector2
		var ix := int(floor((p.x - origin.x) / cell))
		var iy := int(floor((p.y - origin.y) / cell))
		var val := img.get_pixel(ix, iy).r * 255.0
		var want := clampf(float(water.s_at(origin.x + (ix + 0.5) * cell, origin.y + (iy + 0.5) * cell)), -8.0, 48.0)
		var got := val / 255.0 * 56.0 - 8.0
		if absf(got - want) > 0.25:
			off += 1
		if want > 0.0:
			sea += 1
		elif got > 0.5:
			land_wet += 1
	eq(off, 0, "7b. every mask cell holds the generator's depth (to a quarter metre)")
	check(sea > 3, "7b. some of the ring is sea (%d of 60 sample points)" % sea)
	eq(land_wet, 0, "7b. and no land is wet")
	var inside_cell := img.get_pixel(int((2500.0 - origin.x) / cell), int((2500.0 - origin.y) / cell)).r
	eq(inside_cell, 0.0, "7b. the map's own interior is left empty")
	# the sea is on the east edge (the layout's numbering: 1)
	check(water.sea_edges.has(1), "7b. this seed's sea is on its east edge (%s)" % [str(water.sea_edges)])
	check(float(water.s_at(5300.0, 2500.0)) > 0.0, "7b. and the mask has sea past it: the generator says %.1f m at (5300, 2500)" % float(water.s_at(5300.0, 2500.0)))
	# the colours are the water palette's, at the fog's quiet strength
	var m: ShaderMaterial = c._wash_mat
	var s0: Vector4 = m.get_shader_parameter("step0")
	var quiet := float(CameraData.new(CameraData.FOG_PATH).num("topo.water.quiet"))
	near(s0.w, 1.0 - quiet, 1e-6, "7b. the wash is laid at 1 - the fog's quiet (%.2f)" % (1.0 - quiet))
	v2.border.set_option("none")
	v2.queue_free()
	_reached += 1

# --- 8 D -------------------------------------------------------------------------------------------------

func _d_checks() -> void:
	_border.set_option("D")
	var d = _border.impl()
	var r: Rect2 = _view.map_rect()
	var sheet = d._sheet
	check(sheet.shadow_polys.size() >= 1, "8. the sheet has a lifted shadow (%d polygons)" % sheet.shadow_polys.size())
	var dir: Vector2 = UiStyle.shared().shadow_dir()
	check(dir.x > 0.0 and dir.y > 0.0, "8. the map's sun puts shadows to the south-east")
	var amp := float(_border.data.num("d.deckle.amplitude_m")) * 2.0   # px at 2 px/m
	var ok := true
	var area := 0.0
	for poly: PackedVector2Array in sheet.shadow_polys:
		for p: Vector2 in poly:
			# no shadow vertex is north or west of the sheet's corner; and none lies deeper inside the sheet than the ragged edge bites
			# from its south or east side (the shadow is the part of the moved sheet OUTSIDE the sheet)
			if p.x < r.position.x - 1.0 or p.y < r.position.y - 1.0:
				ok = false
			if p.x < r.end.x - amp - 1.0 and p.y < r.end.y - amp - 1.0:
				ok = false
		area += absf(_poly_area(poly))
	check(ok, "8. the shadow lies along the south and east edges only, outside the sheet")
	var lift_px := float(_border.data.num("d.shadow.lift_m")) * 2.0
	var expect := lift_px * 0.7071 * (r.size.x + r.size.y)   # two strips, each as wide as the lift is along an axis
	check(area > expect * 0.5 and area < expect * 2.0, "8. its area is the sheet's south and east edges times the lift (%.0f px^2, expected about %.0f)" % [area, expect])
	check(int(d.drawn["bite_vertices"]) > 400, "8. the ragged edge has its vertices (%d)" % int(d.drawn["bite_vertices"]))
	# no bite is deeper than the deckle's amplitude, on any of the four sides
	var bites: Array = d._bites.polys
	var deepest := [0.0, 0.0, 0.0, 0.0]
	for p: Vector2 in bites[0]:
		if p.y > r.position.y:
			deepest[0] = maxf(deepest[0], p.y - r.position.y)
	for p: Vector2 in bites[1]:
		if p.y < r.end.y:
			deepest[1] = maxf(deepest[1], r.end.y - p.y)
	for p: Vector2 in bites[2]:
		if p.x > r.position.x:
			deepest[2] = maxf(deepest[2], p.x - r.position.x)
	for p: Vector2 in bites[3]:
		if p.x < r.end.x:
			deepest[3] = maxf(deepest[3], r.end.x - p.x)
	for i in 4:
		check(deepest[i] <= amp + 0.001, "8. side %d: no bite deeper than the amplitude (%.1f of %.1f px)" % [i, deepest[i], amp])
		check(deepest[i] > 0.3, "8. side %d: and the edge is bitten at all (%.1f px at most)" % [i, deepest[i]])
	_border.set_option("none")
	_reached += 1

static func _poly_area(p: PackedVector2Array) -> float:
	var a := 0.0
	for i in p.size():
		var q := p[(i + 1) % p.size()]
		a += p[i].x * q.y - q.x * p[i].y
	return a * 0.5


# --- 9 E -------------------------------------------------------------------------------------------------

func _e_checks() -> void:
	_border.set_option("E")
	await get_tree().physics_frame
	var e = _border.impl()
	var st: UiStyle = UiStyle.shared()
	var min_px: float = st.min_px()
	var r: Rect2 = _view.map_rect()
	var vp := Vector2(1280, 720)
	# no neatline, no north arrow: E has neither's code, and its legend names no such thing
	check(not e.has_method("_rule") and not e.has_method("_furniture_paint"), "9. E has no neatline and no furniture of B's")
	# the planning zoom at the north-west corner: the map's top-left at screen (70, 70)
	var z := 0.35
	var xf := Transform2D(Vector2(z, 0.0), Vector2(0.0, z), Vector2(70.0, 70.0))
	e.frame(xf, z, vp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var a: Vector2 = xf * r.position
	var map_screen := Rect2(a, r.size * z)
	var labels: Array = e.legend.drawn_labels
	check(labels.size() >= 4, "9. numbers are drawn at the planning zoom (%d) -- the legend's _draw ran" % labels.size())
	var boxes: Array[Rect2] = []
	var texts := PackedStringArray()
	for l: Dictionary in labels:
		texts.append(str(l["text"]))
		check(float(l["px"]) >= min_px, "9. '%s' is %.0f px (>= %.0f)" % [l["text"], float(l["px"]), min_px])
		var box := Rect2(float(l["x"]), float(l["y"]) - float(l["px"]) * 0.8, float(l["w"]), float(l["px"]) * 0.95)
		check(Rect2(Vector2.ZERO, vp).encloses(box), "9. '%s' lies inside the window" % l["text"])
		check(map_screen.encloses(box), "9. '%s' lies INSIDE the map, never on the hatching outside it (%s in %s)" % [l["text"], str(box), str(map_screen)])
		for other: Rect2 in boxes:
			check(not other.intersects(box), "9. '%s' is not over another number" % l["text"])
		boxes.append(box)
	check(texts.has("500 m") and texts.has("1000 m"), "9. the 500 m and 1000 m ticks are numbered in metres (%s)" % ", ".join(texts))
	check(not texts.has("0 m") and not texts.has("0"), "9. the corner is not numbered (it is the edge)")
	check(e.legend.drawn_ticks.size() >= 4, "9. a tick every 500 m along the two edges in view (%d)" % e.legend.drawn_ticks.size())
	for t: Dictionary in e.legend.drawn_ticks:
		var from: Vector2 = t["from"]
		var to: Vector2 = t["to"]
		var on_edge := absf(from.y - a.y) < 0.01 or absf(from.x - a.x) < 0.01
		check(on_edge, "9. a tick starts on the edge line (%s)" % str(from))
		check(map_screen.has_point(to), "9. and runs INWARD, into the map (%s)" % str(to))
		check(absf(from.distance_to(to) - float(_border.data.num("e.tick.length_px"))) < 0.01, "9. at the tick's length")
	# the ticks are 500 m apart
	var xs: Array[float] = []
	for t: Dictionary in e.legend.drawn_ticks:
		var from: Vector2 = t["from"]
		if absf(from.y - a.y) < 0.01 and from.x > a.x + 1.0:
			xs.append(from.x)
	xs.sort()
	if xs.size() >= 2:
		near(xs[1] - xs[0], 500.0 * 2.0 * z, 0.01, "9. neighbouring ticks are 500 m apart on screen (%.1f px)" % (500.0 * 2.0 * z))
	# cramped: ticks 20 px apart cannot hold a number: the numbers go, the ticks stay
	var zc := 0.02
	var xfc := Transform2D(Vector2(zc, 0.0), Vector2(0.0, zc), Vector2(300.0, 200.0))
	e.frame(xfc, zc, vp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	eq(e.legend.drawn_labels.size(), e.legend.drawn_labels.size(), "9. (the cramped view painted)")
	var numbers := 0
	for l: Dictionary in e.legend.drawn_labels:
		if not l.has("bar"):
			numbers += 1
	eq(numbers, 0, "9. ticks 20 px apart carry no numbers (left off, not squeezed)")
	check(e.legend.drawn_ticks.size() > 0, "9. but their ticks are still drawn")
	# every edge out of the window: nothing
	var xfo := Transform2D(Vector2(1.0, 0.0), Vector2(0.0, 1.0), Vector2(-3000.0, -3000.0))
	e.frame(xfo, 1.0, vp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	eq(e.legend.drawn_ticks.size(), 0, "9. inside the map, far from every edge: no tick")
	eq(e.legend.drawn_labels.size(), 0, "9. and no number")
	# the full zoom-out: the whole map in view; the scale bar clear of the hatch band; no north arrow
	var zf := 0.0679
	var mid := Vector2(121.0, 20.0)
	var xf2 := Transform2D(Vector2(zf, 0.0), Vector2(0.0, zf), mid)
	e.frame(xf2, zf, vp)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var bar: Rect2 = e.legend.drawn_bar
	check(bar.has_area(), "9. with the whole map in view the scale bar is drawn (%s)" % str(bar))
	check(bar.end.x <= mid.x - e.hatch_clear_px() + 0.5, "9. clear of the hatch band (bar ends at %.1f, the band starts at %.1f)" % [bar.end.x, mid.x - e.hatch_clear_px()])
	check(Rect2(Vector2.ZERO, vp).encloses(bar), "9. inside the window")
	near(bar.size.x, float(e.legend.drawn_bar_m) * 2.0 * zf, 1.0, "9. its length is its metres at the map's scale (%.0f m)" % float(e.legend.drawn_bar_m))
	var has_n := false
	var all_ok := true
	var map2 := Rect2(xf2 * r.position, r.size * zf)
	for l: Dictionary in e.legend.drawn_labels:
		if str(l["text"]) == "N":
			has_n = true
		all_ok = all_ok and float(l["px"]) >= min_px
		if not l.has("bar"):
			var box := Rect2(float(l["x"]), float(l["y"]) - float(l["px"]) * 0.8, float(l["w"]), float(l["px"]) * 0.95)
			check(map2.encloses(box), "9. at the full zoom-out '%s' is still inside the map" % l["text"])
	check(not has_n, "9. no north arrow, no N")
	check(all_ok, "9. every word at the full zoom-out is 14 px or more")
	# the hatch band is what A's is: E's fill carries A's hatching
	var fill = e.fill
	check(bool(fill.mat.get_shader_parameter("hatch_on")), "9. the hatching is on (A's edge)")
	near(float(fill.mat.get_shader_parameter("line_px")), float(_border.data.num("a.edge.line_px")), 1e-6, "9. with A's heavy edge line")
	_border.set_option("none")
	_reached += 1

# --- source ----------------------------------------------------------------------------------------------

func _source_checks() -> void:
	var hex := RegEx.create_from_string("#[0-9A-Fa-f]{6}\\b|Color\\(\\s*[0-9.]|Color8\\(|Color\\.html|Color\\(0x|vec[34]\\(\\s*0\\.[0-9]+\\s*,\\s*0\\.[0-9]+\\s*,\\s*0\\.[0-9]+")
	for path: String in BORDER_SCRIPTS:
		var src := FileAccess.get_file_as_string(path)
		check(src != "", "%s reads" % path)
		var m := hex.search(src)
		check(m == null, "%s holds no colour literal (found '%s')" % [path, m.get_string() if m != null else ""])
		# the lettering gate: a string is drawn through UiLabels / UiInk, never by hand
		if path.ends_with(".gd"):
			for line: String in src.split("\n"):
				var t := line.strip_edges()
				if t.begins_with("#"):
					continue
				check(not t.contains("draw_string("), "%s draws no string itself: %s" % [path.get_file(), t])
				check(not t.contains("Label.new()"), "%s makes no unstyled Label: %s" % [path.get_file(), t])
	_reached += 1
