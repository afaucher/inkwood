extends RefCounted

# THE VILLAGE'S GROUND, DRAWN IN INK (Track W, 2026-10-10): the road and the fields of
# scripts/world/village.gd, recorded onto a chunk's canvas after the paper and before the level
# fill, linework and shadows (the ground layer of the map-layer model: it never changes), plus the
# hedge trees that stand on the fields' edges (the tree layer's).
#
#   var vd := VillageDraw.new(terrain, P)             # reads draw.road.* and draw.fields.* of terrain.json
#   vd.draw_ground(g, village, rect)                  # g under the chunk's view; rect = the chunk, world px
#   vd.hedge_trees(village) -> Array                  # tree records (world px), cached; trees.gd's shape
#   vd.style = "rows"                                 # a board overrides the data's working default
#
# EVERYTHING IS A FUNCTION OF WORLD POSITION: a row, a dot, a rut is placed from the field's or the
# road's own seeds and indices (never a stream that runs across a chunk), so two chunks that both
# reach a field or a stretch of road draw the same marks, and the border never shows.
#
# THE ROAD is the prototype's drawRoad (ink_ground.gd): dirt specks across it, eight wobbly broken
# rut and edge lines offset along the sample normals, pebbles along both verges. Its literals are
# the prototype's, as in ink_ground.gd; the only change is that each sample draws from a stream
# seeded by its index, so a chunk draws just the samples near it.
#
# THE FIELDS (art-direction plan terrain.field: ink at low alpha, ruled rows; edges in ink;
# hedgerows with the tree generator at small scale; crops as stipple): each field carries the
# marks its KIND says (data draw.fields.styles[style].kinds[kind]) -- crop rows, stipple (crop dots
# or fallow dirt), an edge line, hedge trees along some edges. Colour is ink or dirt at an alpha
# step, weight a named multiplier from the linework table, tone and material come from the line
# density: no new hue (palette-architecture.md; CLAUDE.md rule 6).

const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const ValueNoise = preload("res://scripts/render/fast_noise.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const SceneGen = preload("res://scripts/world/scene_gen.gd")

# Salts (code constants, not tunables).
const SALT_ROAD_DIRT := 0x71A1
const SALT_ROAD_PEBBLE := 0x71A2
const SALT_ROW := 0x72B1
const SALT_ROW_WOB := 0x72B2
const SALT_ROW_BRK := 0x72B3
const SALT_EDGE_WOB := 0x72C1
const SALT_EDGE_BRK := 0x72C2
const SALT_DOT := 0x72D1
const SALT_HEDGE := 0x72E1

var terrain: RefCounted
var P: RenderParams
var errors: Array[String] = []
var style: String

var road_margin: float
var rows: Dictionary = {}        # "dense" / "light": {spacing, alpha}
var row_weight: float
var row_inset: float
var row_step: float
var row_wobble: float
var row_wobble_f: float
var row_break_f: float
var row_break_thr: float
var crop: Dictionary = {}
var fallow: Dictionary = {}
var edges: Dictionary = {}       # "line" / "heavy": {alpha, weight}
var edge_step: float
var edge_wobble: float
var edge_wobble_f: float
var edge_break_f: float
var edge_break_thr: float
var hedge_spacing := PackedFloat64Array()
var hedge_scale: float
var hedge_height: float
var hedge_gap: float
var hedge_end: float
var tone_dirt: float
var tone_cream: float
var styles: Dictionary = {}      # style name -> {kinds: [recipe]}

var _hedges: Dictionary = {}     # style -> Array of tree records (world px)

func _init(t: RefCounted, params: RenderParams) -> void:
	terrain = t
	P = params
	var d: Variant = t.data
	road_margin = d.num("draw.road.run_margin_px")
	style = d.text("draw.fields.style")
	styles = d.dict("draw.fields.styles")
	for k: String in ["dense", "light"]:
		rows[k] = {"spacing": d.num("draw.fields.rows.%s.spacing_px" % k), "alpha": d.num("draw.fields.rows.%s.alpha" % k)}
	row_weight = _weight(d.text("draw.fields.rows.weight"))
	row_inset = d.num("draw.fields.rows.inset_px")
	row_step = d.num("draw.fields.rows.step_px")
	row_wobble = d.num("draw.fields.rows.wobble_px")
	row_wobble_f = d.num("draw.fields.rows.wobble_noise_per_px")
	row_break_f = d.num("draw.fields.rows.break_noise_per_px")
	row_break_thr = d.num("draw.fields.rows.break_threshold")
	crop = {"row": d.num("draw.fields.stipple.crop.row_spacing_px"), "dot": d.num("draw.fields.stipple.crop.dot_spacing_px"),
		"size": d.floats("draw.fields.stipple.crop.size_px"), "alpha": d.floats("draw.fields.stipple.crop.alpha"),
		"keep": d.num("draw.fields.stipple.crop.keep")}
	fallow = {"density": d.num("draw.fields.stipple.fallow.density_per_px2"), "size": d.floats("draw.fields.stipple.fallow.size_px"),
		"alpha": d.floats("draw.fields.stipple.fallow.alpha")}
	for k: String in ["line", "heavy"]:
		edges[k] = {"alpha": d.num("draw.fields.edge.%s.alpha" % k), "weight": _weight(d.text("draw.fields.edge.%s.weight" % k))}
	edge_step = d.num("draw.fields.edge.step_px")
	edge_wobble = d.num("draw.fields.edge.wobble_px")
	edge_wobble_f = d.num("draw.fields.edge.wobble_noise_per_px")
	edge_break_f = d.num("draw.fields.edge.break_noise_per_px")
	edge_break_thr = d.num("draw.fields.edge.break_threshold")
	hedge_spacing = d.floats("draw.fields.hedge.spacing_px")
	hedge_scale = d.num("draw.fields.hedge.scale")
	hedge_height = d.num("draw.fields.hedge.height_frac")
	hedge_gap = d.num("draw.fields.hedge.gap_chance")
	hedge_end = d.num("draw.fields.hedge.end_margin_px")
	tone_dirt = d.num("draw.fields.tone.dirt_alpha")
	tone_cream = d.num("draw.fields.tone.cream_alpha")
	errors.append_array(d.errors)
	if not styles.has(style):
		errors.append("draw.fields.style '%s' is not one of draw.fields.styles (%s)" % [style, styles.keys()])
	for name: String in styles:
		var kinds: Variant = (styles[name] as Dictionary).get("kinds")
		if not (kinds is Array) or (kinds as Array).size() < 1:
			errors.append("draw.fields.styles.%s needs a kinds list" % name)
			continue
		for rec: Variant in kinds:
			var r: Dictionary = rec if rec is Dictionary else {}
			if not (str(r.get("rows", "")) in ["none", "dense", "light"] and str(r.get("stipple", "")) in ["none", "crop", "fallow"]
					and str(r.get("edge", "")) in ["none", "line", "heavy"] and (r.get("hedge") is float or r.get("hedge") is int)
					and str(r.get("tone", "")) in ["none", "dirt", "cream"]):
				errors.append("draw.fields.styles.%s: bad kind recipe %s" % [name, r])

func ok() -> bool:
	return errors.is_empty()

# Drops what is derived from the village (a new scale makes a new one).
func forget() -> void:
	_hedges.clear()

func _weight(name: String) -> float:
	if P.linework.has(name):
		return float(P.linework[name])
	errors.append("linework multiplier '%s' is not in %s" % [name, P.source_path])
	return 1.0

# The recipe a field of this kind gets in the current style.
func recipe(kind: int) -> Dictionary:
	var kinds: Array = (styles[style] as Dictionary).kinds
	return kinds[kind % kinds.size()]

# --- the whole ground --------------------------------------------------------------------------

# Fields, then the road, for the chunk `rect` (world px); `g` has the chunk's view transform.
func draw_ground(g: InkCanvas, village: RefCounted, rect: Rect2) -> void:
	if village == null:
		return
	draw_fields(g, village, rect)
	draw_road(g, village, rect)

# --- the road -----------------------------------------------------------------------------------

func _sample_rng(i: int, salt: int) -> Mulberry32:
	return Mulberry32.new(int(ValueNoise.hash2(i, salt, terrain.seed_value & 0x7FFFFFFF) * 2147483647.0))

# drawRoad over the samples near `rect` (see the header for what differs from ink_ground.gd).
func draw_road(g: InkCanvas, village: RefCounted, rect: Rect2) -> void:
	var runs: Array = village.road_runs_in_rect(rect, road_margin)
	if runs.is_empty():
		return
	var pts: Array = village.road_pts
	var ROAD_HALF := P.ROAD_HALF
	g.save()
	g.global_alpha = 1.0
	# dirt specks across the road
	g.fill_color = P.DIRT
	for run: Array in runs:
		for i in range(run[0], run[1] + 1):
			var p: Dictionary = pts[i]
			var rng := _sample_rng(i, SALT_ROAD_DIRT)
			for _k in 6:
				var t := rng.next() * 2.0 - 1.0
				if rng.next() > 1.0 - absf(t) * 0.65:
					continue
				var off := t * ROAD_HALF * 1.5
				g.global_alpha = 0.14 + rng.next() * 0.2
				var x: float = p.x + p.nx * off + (rng.next() - 0.5) * 3.0
				var y: float = p.y + p.ny * off + (rng.next() - 0.5) * 3.0
				g.fill_rect(x, y, 0.9, 0.9)
	# the eight rut and edge lines
	g.stroke_color = P.INK
	g.line_cap = "round"
	var lines := [{"o": -9.0, "a": 0.6}, {"o": -7.2, "a": 0.35}, {"o": -10.9, "a": 0.3}, {"o": 9.0, "a": 0.6},
		{"o": 7.2, "a": 0.35}, {"o": 10.9, "a": 0.3}, {"o": -ROAD_HALF, "a": 0.3}, {"o": ROAD_HALF, "a": 0.3}]
	for li in lines.size():
		var L: Dictionary = lines[li]
		var ns := 1000 + li * 13
		g.global_alpha = L.a
		g.line_width = P.linework["road_ruts"] * P.lw
		g.begin_path()
		var o: float = L.o
		for run: Array in runs:
			var pen := false
			for i in range(run[0], run[1] + 1):
				var p: Dictionary = pts[i]
				if ValueNoise.vnoise(i * 0.045, 3.3, ns) < 0.3:
					pen = false
					continue
				var j := (ValueNoise.vnoise(i * 0.09, 1.7, ns + 5) - 0.5) * 2.6 * (0.35 + P.wob)
				var x: float = p.x + p.nx * (o + j)
				var y: float = p.y + p.ny * (o + j)
				if not pen:
					g.move_to(x, y)
					pen = true
				else:
					g.line_to(x, y)
		g.stroke()
	# pebbles along both verges, every fifth sample
	for run: Array in runs:
		for i in range(run[0] + (5 - run[0] % 5) % 5, run[1] + 1, 5):
			var rng := _sample_rng(i, SALT_ROAD_PEBBLE)
			if rng.next() < 0.45:
				continue
			var p: Dictionary = pts[i]
			var off := (-1.0 if rng.next() < 0.5 else 1.0) * (ROAD_HALF + 1.0 + rng.next() * 8.0)
			var rr := 0.6 + rng.next() * 1.4
			g.begin_path()
			g.arc(p.x + p.nx * off, p.y + p.ny * off, rr, 0.0, PI * 2.0)
			g.global_alpha = 0.9
			g.fill_color = P.CREAM
			g.fill()
			g.global_alpha = 0.55
			g.line_width = 0.6 * P.lw
			g.stroke()
	g.global_alpha = 1.0
	g.restore()

# --- the fields ------------------------------------------------------------------------------------

func draw_fields(g: InkCanvas, village: RefCounted, rect: Rect2) -> void:
	var list: Array = village.fields_in_rect(rect.grow(8.0))
	if list.is_empty():
		return
	var batches: Dictionary = {}   # "kind|alpha|weight" -> {alpha, weight, runs: []}
	var dots: Array = []           # [x, y, size, alpha, ink?]
	g.save()
	g.line_cap = "round"
	for f: Dictionary in list:
		var info: Dictionary = f.info
		var rc := recipe(int(info.kind))
		var seed_f: int = int(info.seed)
		var poly: PackedVector2Array = f.poly
		var inner := rect.grow(10.0)
		if rc.tone != "none":
			g.fill_color = P.DIRT if rc.tone == "dirt" else P.CREAM
			g.global_alpha = tone_dirt if rc.tone == "dirt" else tone_cream
			g.begin_path()
			g.move_to(poly[0].x, poly[0].y)
			for q in range(1, poly.size()):
				g.line_to(poly[q].x, poly[q].y)
			g.close_path()
			g.fill()
		if rc.rows != "none":
			var rr: Dictionary = rows[rc.rows]
			_rows(batches, poly, float(info.angle), seed_f, float(rr.spacing), float(rr.alpha), row_weight, inner)
		if rc.stipple == "crop":
			_crop_dots(dots, poly, float(info.angle), seed_f, inner)
		elif rc.stipple == "fallow":
			_fallow_dots(dots, poly, seed_f, inner)
		if rc.edge != "none":
			var e: Dictionary = edges[rc.edge]
			_edge(batches, poly, seed_f, float(e.alpha), float(e.weight), inner)
	# one stroke per alpha and weight: a translucent stroke is one coverage mask, so overlaps never darken twice
	var keys := batches.keys()
	keys.sort()
	g.stroke_color = P.INK
	for k: String in keys:
		var b: Dictionary = batches[k]
		g.global_alpha = b.alpha
		g.line_width = P.lw * float(b.weight)
		g.begin_path()
		for run: PackedVector2Array in b.runs:
			g.move_to(run[0].x, run[0].y)
			for i in range(1, run.size()):
				g.line_to(run[i].x, run[i].y)
		g.stroke()
	for dd: Array in dots:
		g.fill_color = P.INK if dd[4] else P.DIRT
		g.global_alpha = dd[3]
		g.fill_rect(dd[0], dd[1], dd[2], dd[2])
	g.global_alpha = 1.0
	g.restore()

# The interior unit vectors of a convex quad: the signed side test sign s0 and, for each edge,
# the data needed to clip a line to the polygon shrunk by `inset`.
static func _clip(poly: PackedVector2Array, origin: Vector2, d: Vector2, inset: float) -> Vector2:
	var area := 0.0
	var n := poly.size()
	for i in n:
		area += poly[i].cross(poly[(i + 1) % n])
	var s0 := 1.0 if area > 0.0 else -1.0
	var lo := -INF
	var hi := INF
	for i in n:
		var a := poly[i]
		var e := poly[(i + 1) % n] - a
		var l := e.length()
		if l == 0.0:
			continue
		var c0 := s0 * e.cross(origin - a) / l - inset   # >= 0 inside
		var c1 := s0 * e.cross(d) / l
		if absf(c1) < 1e-9:
			if c0 < 0.0:
				return Vector2(1.0, 0.0)   # parallel and outside: empty
			continue
		var t := -c0 / c1
		if c1 > 0.0:
			lo = maxf(lo, t)
		else:
			hi = minf(hi, t)
	return Vector2(lo, hi)

func _rows(batches: Dictionary, poly: PackedVector2Array, angle: float, seed_f: int, spacing: float, alpha: float,
		weight: float, rect: Rect2) -> void:
	var d := Vector2.from_angle(angle)
	var nrm := Vector2(-d.y, d.x)
	var c0 := Vector2.ZERO
	for p in poly:
		c0 += p
	c0 /= poly.size()
	var lo := INF
	var hi := -INF
	for p in poly:
		var q := (p - c0).dot(nrm)
		lo = minf(lo, q)
		hi = maxf(hi, q)
	var key := "r|%.3f|%.3f" % [alpha, weight]
	var batch: Dictionary = batches.get(key, {"alpha": alpha, "weight": weight, "runs": []})
	batches[key] = batch
	var k := 0
	var off := lo + row_inset + spacing * 0.5
	while off <= hi - row_inset:
		var origin := c0 + nrm * off
		var tr := _clip(poly, origin, d, row_inset)
		if tr.x < tr.y:
			# the row's bounding box against the chunk, before any sampling
			var a := origin + d * tr.x
			var b := origin + d * tr.y
			if rect.intersects(Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (a - b).abs()).grow(2.0)):
				var run := PackedVector2Array()
				var t := tr.x
				while t <= tr.y + 0.001:
					var tt := minf(t, tr.y)
					var broken := ValueNoise.vnoise(tt * row_break_f, k * 3.3, seed_f + SALT_ROW_BRK) < row_break_thr
					if broken:
						if run.size() >= 2:
							(batch.runs as Array).append(run)
						run = PackedVector2Array()
					else:
						var w := (ValueNoise.vnoise(tt * row_wobble_f, k * 7.1, seed_f + SALT_ROW_WOB) - 0.5) * 2.0 * row_wobble
						run.append(origin + d * tt + nrm * w)
					t += row_step
				if run.size() >= 2:
					(batch.runs as Array).append(run)
		off += spacing
		k += 1

# The polygon's own edge, wobbled and broken, as runs of one batch.
func _edge(batches: Dictionary, poly: PackedVector2Array, seed_f: int, alpha: float, weight: float, rect: Rect2) -> void:
	var key := "e|%.3f|%.3f" % [alpha, weight]
	var batch: Dictionary = batches.get(key, {"alpha": alpha, "weight": weight, "runs": []})
	batches[key] = batch
	var n := poly.size()
	var run := PackedVector2Array()
	var walked := 0.0
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var l := a.distance_to(b)
		var steps := maxi(1, int(ceil(l / edge_step)))
		var tangent := (b - a) / l if l > 0.0 else Vector2.RIGHT
		var nrm := Vector2(-tangent.y, tangent.x)
		var seg_box := Rect2(Vector2(minf(a.x, b.x), minf(a.y, b.y)), (a - b).abs()).grow(3.0)
		if not rect.intersects(seg_box):
			if run.size() >= 2:
				(batch.runs as Array).append(run)
			run = PackedVector2Array()
			walked += l
			continue
		for s in steps + 1:
			var t := float(s) / steps
			var p := a.lerp(b, t)
			var along := walked + t * l
			if ValueNoise.vnoise(along * edge_break_f, 5.5, seed_f + SALT_EDGE_BRK) < edge_break_thr:
				if run.size() >= 2:
					(batch.runs as Array).append(run)
				run = PackedVector2Array()
				continue
			var w := (ValueNoise.vnoise(p.x * edge_wobble_f, p.y * edge_wobble_f, seed_f + SALT_EDGE_WOB) - 0.5) * 2.0 * edge_wobble
			run.append(p + nrm * w)
		walked += l
	if run.size() >= 2:
		(batch.runs as Array).append(run)

func _hash01(i: int, j: int, s: int) -> float:
	return ValueNoise.hash2(i, j, s)

# Crop dots in rows: a lattice along the field's own axes, each dot kept or not by a hash of its
# lattice indices (so a dot is the same whichever chunk draws it).
func _crop_dots(out: Array, poly: PackedVector2Array, angle: float, seed_f: int, rect: Rect2) -> void:
	var d := Vector2.from_angle(angle)
	var nrm := Vector2(-d.y, d.x)
	var c0 := Vector2.ZERO
	for p in poly:
		c0 += p
	c0 /= poly.size()
	var lo := INF
	var hi := -INF
	for p in poly:
		var q := (p - c0).dot(nrm)
		lo = minf(lo, q)
		hi = maxf(hi, q)
	var size: PackedFloat64Array = crop.size
	var alpha: PackedFloat64Array = crop.alpha
	var k := 0
	var off := lo + row_inset + float(crop.row) * 0.5
	while off <= hi - row_inset:
		var origin := c0 + nrm * off
		var tr := _clip(poly, origin, d, row_inset)
		if tr.x < tr.y:
			var j0 := int(ceil(tr.x / float(crop.dot)))
			var j1 := int(floor(tr.y / float(crop.dot)))
			for j in range(j0, j1 + 1):
				if _hash01(k, j, seed_f + SALT_DOT) > float(crop.keep):
					continue
				var jit := _hash01(k, j, seed_f + SALT_DOT + 1) - 0.5
				var p := origin + d * (j * float(crop.dot) + jit * float(crop.dot) * 0.5) + nrm * ((_hash01(j, k, seed_f + SALT_DOT + 2) - 0.5) * 1.2)
				if not rect.has_point(p):
					continue
				out.append([p.x, p.y, size[0] + (size[1] - size[0]) * _hash01(k, j, seed_f + SALT_DOT + 3),
					alpha[0] + (alpha[1] - alpha[0]) * _hash01(k, j, seed_f + SALT_DOT + 4), true])
		off += float(crop.row)
		k += 1

# Fallow dirt: dots at random inside the polygon, from a lattice of cells (one candidate per cell)
# so the density is exact and every chunk agrees.
func _fallow_dots(out: Array, poly: PackedVector2Array, seed_f: int, rect: Rect2) -> void:
	var cell := 1.0 / sqrt(float(fallow.density))
	var box := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		box = box.expand(p)
	box = box.intersection(rect)
	if not box.has_area():
		return
	var size: PackedFloat64Array = fallow.size
	var alpha: PackedFloat64Array = fallow.alpha
	var i0 := int(floor(box.position.x / cell))
	var i1 := int(floor(box.end.x / cell))
	var j0 := int(floor(box.position.y / cell))
	var j1 := int(floor(box.end.y / cell))
	for j in range(j0, j1 + 1):
		for i in range(i0, i1 + 1):
			var p := Vector2((i + _hash01(i, j, seed_f + SALT_DOT + 5)) * cell, (j + _hash01(i, j, seed_f + SALT_DOT + 6)) * cell)
			if not rect.has_point(p) or not Geometry2D.is_point_in_polygon(p, poly):
				continue
			out.append([p.x, p.y, size[0] + (size[1] - size[0]) * _hash01(i, j, seed_f + SALT_DOT + 7),
				alpha[0] + (alpha[1] - alpha[0]) * _hash01(i, j, seed_f + SALT_DOT + 8), false])

# --- hedge trees ----------------------------------------------------------------------------------------

# The hedge trees of the current style, world px, as terrain trees' records (kind "tree", x, y,
# seed, sr, hr, big, r, h, key + level 0 and base 0), in field order: the tree generator
# (scene_gen.make_tree) at hedge.scale of the usual radius and hedge.height_frac of the usual height.
func hedge_trees(village: RefCounted) -> Array:
	if _hedges.has(style):
		return _hedges[style]
	var out: Array = []
	var gen := SceneGen.new(1.0, 1.0, P)
	for f: Dictionary in village.fields:
		var info: Dictionary = f.info
		var rc := recipe(int(info.kind))
		if float(rc.hedge) <= 0.0:
			continue
		var seed_f: int = int(info.seed)
		var poly: PackedVector2Array = f.poly
		var n := poly.size()
		for i in n:
			if _hash01(i, 11, seed_f + SALT_HEDGE) >= float(rc.hedge):
				continue
			var a := poly[i]
			var b := poly[(i + 1) % n]
			var l := a.distance_to(b)
			var rng := Mulberry32.new(int(_hash01(i, 12, seed_f + SALT_HEDGE) * 2147483647.0))
			var s := hedge_end + rng.next() * hedge_spacing[0]
			while s < l - hedge_end:
				var pos := a.lerp(b, s / l)
				var t := gen.make_tree(rng, pos.x, pos.y)
				gen.sync_tree(t)
				var skip := rng.next() < hedge_gap
				s += hedge_spacing[0] + rng.next() * (hedge_spacing[1] - hedge_spacing[0])
				if skip:
					continue
				t.r = float(t.r) * hedge_scale
				t.h = t.r * P.height * (0.85 + 0.3 * float(t.hr)) * hedge_height
				t["big"] = false
				t["level"] = 0
				t["base"] = 0.0
				t["base_m"] = 0.0
				t["hedge"] = true
				out.append(t)
	_hedges[style] = out
	return out
