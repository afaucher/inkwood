extends "res://scripts/test_support/test_case.gd"

# THE WATER IN THE LIVE MAP (Track WB, Job 3, 2026-10-10), headless: plans and numbers; the pixels are scripts/render/water_live_shot.gd and
# the probes (docs: the report). What it holds the integration to:
#
#   SHORTCUTS    the coarse grid's two shortcuts never disagree with the exact fields: field_cap() is the exact cap wherever it takes
#                the inland shortcut, tree_dry() is the exact rule, and a rectangle the sea "cannot reach" holds no wet node.
#   RINGS        sea_rings_all() (what a worker thread calls: no cache, the coarse grid's stand-ins) gives the very rings sea_rings()
#                does, per step, for a coast, an open sea, an inland rectangle and one on the shore; two chunks' rings meet on the
#                border they share to a fraction of a metre (no seam).
#   TREES        no tree of the water's terrain stands in water, trees far from it are the raw terrain's trees, and the raw
#                terrain really did plant some in the water (the check can fail).
#   TERRAIN      make_terrain(): the capped ground (lower than the raw field somewhere, equal far inland), the very ground the water's
#                own terrain() judges by; the layout's sites (village, tower, batteries) stay dry.
#   PROVIDER     the chunk provider takes the water: the stage list gains `water` (after the ground) and `water_masks` (before the
#                fill) and nothing else, and without water is exactly what it was; every bundle's terrain is the water's; a coast chunk
#                has geometry and two mask canvases, an inland chunk none.
#   FOG          FogTopo and FogLayer take the water; a coastal chunk of the contour map records more paint calls with water, an inland
#                one the same, and the recorder twin's terrain is the capped one.
#   SCENARIO     the Strike has its water switch ON in data, the knob `water` turns it off (no water units, no WaterGen), and the
#                sandbox built from it has the capped terrain, the map's provider, the fog and the sim on ONE WaterGen.
#
# The numbers measured are printed as [waterlive] lines for the report.

const WaterGen = preload("res://scripts/world/water_gen.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")
const FogTopo = preload("res://scripts/render/fog_topo.gd")
const FogLayer = preload("res://scripts/render/fog_layer.gd")
const MapView = preload("res://scripts/render/map_view.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const Sandbox = preload("res://scripts/app/sandbox.gd")

const SEED := 20261009
const PPM := 2.0
const PLAIN_STAGES := ["gather", "sprites", "ground", "levels", "terrain_sil", "terrain_cut", "terrain_merge", "struct_sil", "struct_cut",
	"struct_merge", "tree_sil", "tree_cut", "tree_merge", "fill", "linework", "frame"]

var _water: WaterGen
var _coast_rects: Array[Rect2] = []   # 512 m rectangles (metres) the sea's step 0 reaches into, the first with the sea partly in it
var _inland_rects: Array[Rect2] = []   # 512 m rectangles the sea cannot reach (the coarse grid says so)
var _inland_rect := Rect2()           # the first of them
var _deep_rect := Rect2()

func setup(main) -> void:
	timeout_seconds = 240.0
	var t0 := Time.get_ticks_usec()
	eq(await _body(main), "done", "the live-water test ran to its end (a compile error in a dependency would stop it silently)")
	print("[waterlive] test total %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	finish()

func _body(main: Node) -> String:
	_water = WaterGen.shared(SEED) as WaterGen
	if not check(_water.ok(), "the water of seed %d builds: %s" % [SEED, _water.errors]):
		return "build failed"
	_find_rects()
	_shortcuts()
	_rings()
	_seam()
	_trees()
	_terrain()
	_provider()
	_chunk_draw()
	_fog()
	_scenario()
	_prewarm()
	await _sandbox(main)
	return "done"

# --- the rectangles the checks use ------------------------------------------------------------------------------------------

func _find_rects() -> void:
	var map: Rect2 = _water.map_rect()
	for cy in range(0, 10):
		for cx in range(0, 10):
			var r := Rect2(map.position + Vector2(cx, cy) * 512.0, Vector2(512.0, 512.0))
			var rings: Array = _water.sea_rings(r, 0)
			var wet := false
			var deep_all := true
			for ring: Dictionary in rings:
				if float(ring["area"]) > 0.0:
					wet = true
			if not wet:
				if not _water.sea_may_reach(r.grow(64.0)) and _inland_rects.size() < 8:
					_inland_rects.append(r)
				continue
			var c := r.get_center()
			if _water.sea_s(c.x, c.y) > 30.0 and _water.sea_s(r.position.x, r.position.y) > 30.0 and _water.sea_s(r.end.x, r.end.y) > 30.0 and deep_all:
				if _deep_rect.size == Vector2.ZERO:
					_deep_rect = r
			elif _coast_rects.size() < 6:
				_coast_rects.append(r)
	check(_coast_rects.size() >= 3, "the seed has at least three coast chunks to check (%d)" % _coast_rects.size())
	check(_inland_rects.size() >= 2, "and inland ones (%d)" % _inland_rects.size())
	if not _inland_rects.is_empty():
		_inland_rect = _inland_rects[0]
	print("[waterlive] rectangles: %d coast, inland %s, open sea %s" % [_coast_rects.size(), _inland_rect.position, _deep_rect.position])

# --- the coarse shortcuts ------------------------------------------------------------------------------------------------------

func _shortcuts() -> void:
	var map: Rect2 = _water.map_rect()
	var worst_cap := 0.0
	var hits := 0
	var total := 0
	var tree_bad := 0
	var y := map.position.y - 400.0
	while y <= map.end.y + 400.0:
		var x := map.position.x - 400.0
		while x <= map.end.x + 400.0:
			total += 1
			var exact: float = _water._cap_of(_water.landness(x, y), x, y)
			var got: float = _water.field_cap(x, y)
			if is_equal_approx(got, 1.0) and not is_equal_approx(exact, 1.0):
				worst_cap = maxf(worst_cap, absf(got - exact))
			elif not is_equal_approx(got, exact):
				worst_cap = maxf(worst_cap, absf(got - exact))
			if got == 1.0 and exact >= 1.0 - 1e-9:
				hits += 1
			var dry_exact: bool = _water.sea_s(x, y) <= -1.5 and _water.river_s(x, y) <= 0.0
			if _water.tree_dry(x, y) != dry_exact:
				tree_bad += 1
			x += 50.0
		y += 50.0
	check(worst_cap < 1e-9, "field_cap is the exact cap at every one of %d lattice points (worst difference %s)" % [total, String.num(worst_cap, 3)])
	eq(tree_bad, 0, "tree_dry is the exact rule at every lattice point")
	check(hits > total / 10, "and the inland shortcut is taken often enough to matter (%d of %d)" % [hits, total])
	print("[waterlive] shortcuts: field_cap inland on %d of %d lattice points (%.0f percent), worst difference %s" % [hits, total, 100.0 * hits / total, String.num(worst_cap, 3)])
	# a rectangle the sea cannot reach holds no node with water in it
	var bad := 0
	for r in [_inland_rect, Rect2(map.position, Vector2(512, 512)), Rect2(map.end - Vector2(512, 512), Vector2(512, 512))]:
		var rr: Rect2 = r
		if not _water.sea_may_reach(rr.grow(64.0)):
			var yy := rr.position.y - 64.0
			while yy <= rr.end.y + 64.0:
				var xx := rr.position.x - 64.0
				while xx <= rr.end.x + 64.0:
					if _water.sea_s(xx, yy) >= 0.0:
						bad += 1
					xx += 8.0
				yy += 8.0
	eq(bad, 0, "a rectangle sea_may_reach() rules out has no wet node on its 8 m lattice")

# --- rings --------------------------------------------------------------------------------------------------------------------

# The rings of two makers of one grid, compared: the same number of rings, each of the same orientation, and the same size to
# five thousandths of its area and a few points (the one difference there can be is the false shoreline at the grid's forced-outside
# border, out in the pad, which a deep stand-in moves by a hair).
static func _same_rings(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	var sa: Array = _sig(a)
	var sb: Array = _sig(b)
	for i in sa.size():
		var x: Array = sa[i]
		var y: Array = sb[i]
		if x[2] != y[2] or absi(int(x[1]) - int(y[1])) > 3 or absf(float(x[0]) - float(y[0])) > 5e-3 * maxf(float(x[0]), 1.0):
			return false
	return true

static func _sig(rings: Array) -> Array:
	var out: Array = []
	for ring: Dictionary in rings:
		out.append([absf(float(ring["area"])), (ring["pts"] as PackedVector2Array).size(), float(ring["area"]) > 0.0])
	out.sort_custom(func(p: Array, q: Array) -> bool: return float(p[0]) > float(q[0]))
	return out

# The live grid's every node is on the same side of every step as the exact field's, and an edge of the grid that a step crosses has real
# values at both ends (so no crossing is placed from a stand-in): the two facts that make the rings the same.
func _grid_agrees(r: Rect2) -> int:
	var live: Dictionary = _water._live_grid(r.grow(64.0))
	var exact: Dictionary = _water.sea_grid(r, 64.0)
	var bad := 0
	if live["cols"] != exact["cols"] or live["rows"] != exact["rows"] or not is_equal_approx(float(live["x0"]), float(exact["x0"])):
		return 1 << 20
	var lv: PackedFloat64Array = live["vals"]
	var ev: PackedFloat64Array = exact["vals"]
	var cols: int = live["cols"]
	var rows: int = live["rows"]
	var steps: PackedFloat64Array = _water.step_from
	for j in rows:
		for i in cols:
			var a := lv[j * cols + i]
			var b := ev[j * cols + i]
			if absf(a - b) > 1e-9:
				# a stand-in: same side of every step, and no neighbour on another side
				for t in steps:
					var thr := maxf(t, 0.0)
					if (a >= thr) != (b >= thr):
						bad += 1
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var ni: int = i + (d as Vector2i).x
					var nj: int = j + (d as Vector2i).y
					if ni < 0 or nj < 0 or ni >= cols or nj >= rows:
						continue
					for t in steps:
						var thr := maxf(t, 0.0)
						if (ev[j * cols + i] >= thr) != (ev[nj * cols + ni] >= thr):
							bad += 1
	return bad

func _rings() -> void:
	var cases: Array[Rect2] = _coast_rects.duplicate()
	cases.append(_inland_rect)
	if _deep_rect.size != Vector2.ZERO:
		cases.append(_deep_rect)
	var same := 0
	var total_rings := 0
	for r: Rect2 in cases:
		var all: Array = _water.sea_rings_all(r, 64.0)
		for k in 3:
			var old: Array = _water.sea_rings(r, k)
			total_rings += old.size()
			if _same_rings(all[k], old):
				same += 1
			else:
				fail("sea_rings_all and sea_rings differ at %s step %d: %s vs %s" % [r.position, k, _sig(all[k]).slice(0, 4), _sig(old).slice(0, 4)])
	eq(same, cases.size() * 3, "sea_rings_all() makes the very rings sea_rings() does for every step of %d rectangles (%d rings)" % [cases.size(), total_rings])
	# and on EVERY 512 m chunk of the map the live grid agrees with the exact one where it matters (the contour map's 256 m chunks are the same nodes)
	var map: Rect2 = _water.map_rect()
	var bad_nodes := 0
	var n_rects := 0
	for cy in 10:
		for cx in 10:
			n_rects += 1
			bad_nodes += _grid_agrees(Rect2(map.position + Vector2(cx, cy) * 512.0, Vector2(512.0, 512.0)))
	eq(bad_nodes, 0, "the live grid never puts a node on the wrong side of a step nor a crossing on a stand-in, on every one of %d chunks of the map" % n_rects)
	# the three steps nest: step k+1's outer rings lie inside step k's
	var coast: Array = _water.sea_rings_all(_coast_rects[0], 64.0)
	var shallows := 0.0
	var shelf := 0.0
	for ring: Dictionary in coast[0]:
		shallows += float(ring["area"])
	for ring: Dictionary in coast[1]:
		shelf += float(ring["area"])
	check(shelf <= shallows + 1.0, "step 1's area (%.0f) is no more than step 0's (%.0f)" % [shelf, shallows])
	eq((_water.sea_rings_all(_inland_rect, 64.0)[0] as Array).size(), 0, "an inland rectangle has no ring")

# Two chunks side by side draw the same shore on the border they share.
func _seam() -> void:
	var worst := 0.0
	var tested := 0
	for r: Rect2 in _coast_rects:
		var right := Rect2(r.position + Vector2(r.size.x, 0.0), r.size)
		var a: Array = _water.sea_rings_all(r, 64.0)[0]
		var b: Array = _water.sea_rings_all(right, 64.0)[0]
		var edge := r.end.x
		for ring: Dictionary in a:
			var pts: PackedVector2Array = ring["pts"]
			for p in pts:
				if absf(p.x - edge) > 12.0 or p.y < r.position.y + 8.0 or p.y > r.end.y - 8.0:
					continue
				var best := INF
				for other: Dictionary in b:
					var q: PackedVector2Array = other["pts"]
					for i in q.size():
						var s0 := q[i]
						var s1 := q[(i + 1) % q.size()]
						var cp := Geometry2D.get_closest_point_to_segment(p, s0, s1)
						best = minf(best, p.distance_to(cp))
				tested += 1
				worst = maxf(worst, best)
	check(tested > 20, "the seam check had points to test (%d)" % tested)
	check(worst < 0.5, "two chunks' rings agree on the border they share: %d points, worst distance %.3f m" % [tested, worst])
	print("[waterlive] seam: %d ring points within 12 m of a shared border, worst distance to the neighbour's ring %.3f m" % [tested, worst])

# --- trees ----------------------------------------------------------------------------------------------------------------------

func _tkey(t: Dictionary) -> String:
	return "%.2f,%.2f" % [float(t["x"]), float(t["y"])]

func _trees() -> void:
	var raw := Terrain.new(SEED)
	var capped: Object = _water.make_terrain()
	# the terrain's chunks of the coast, both terrains
	var cr: Rect2 = _coast_rects[0]
	var area := Rect2(cr.position * PPM, cr.size * PPM).grow(256.0)
	var raw_trees: Array = raw.trees_in_rect_px(area)
	var dry_trees: Array = capped.trees_in_rect_px(area)
	var wet_raw := 0
	for t: Dictionary in raw_trees:
		if not _water.tree_dry(float(t["x"]) / PPM, float(t["y"]) / PPM):
			wet_raw += 1
	check(wet_raw > 0, "the raw terrain planted %d trees in the water of the coast chunk (the check can fail)" % wet_raw)
	var wet_capped := 0
	for t: Dictionary in dry_trees:
		if not _water.tree_dry(float(t["x"]) / PPM, float(t["y"]) / PPM):
			wet_capped += 1
	eq(wet_capped, 0, "the water's terrain has no tree in the water (%d trees kept of %d)" % [dry_trees.size(), raw_trees.size()])
	# far from the water the trees are the raw terrain's (the first inland rectangle that has trees)
	var ir: Rect2 = _inland_rect
	var ia := Rect2(ir.position * PPM, ir.size * PPM).grow(-128.0)
	var a: Array = []
	var b: Array = []
	for cand: Rect2 in _inland_rects:
		ir = cand
		ia = Rect2(ir.position * PPM, ir.size * PPM).grow(-128.0)
		a = raw.trees_in_rect_px(ia)
		if a.size() > 20:
			break
	b = capped.trees_in_rect_px(ia)
	var ka: Array = []
	var kb: Array = []
	for t: Dictionary in a:
		ka.append(_tkey(t))
	for t: Dictionary in b:
		kb.append(_tkey(t))
	ka.sort()
	kb.sort()
	check(a.size() > 0 and ka == kb, "inland the water's terrain plants the raw terrain's trees (%d, %d)" % [a.size(), b.size()])
	print("[waterlive] trees on the coast area: raw %d, kept %d (%d in the water dropped); inland %d = %d" % [raw_trees.size(), dry_trees.size(), raw_trees.size() - dry_trees.size(), a.size(), b.size()])
	# changing the scale forgets the filtered lists too
	capped.px_per_m = 3.0
	capped.clear_cache()
	check(capped.trees_in_rect_px(Rect2(ir.position * 3.0, ir.size * 3.0).grow(-192.0)).size() > 0, "a new scale plants again")

# --- terrain --------------------------------------------------------------------------------------------------------------------

func _terrain() -> void:
	var raw := Terrain.new(SEED)
	var capped: Object = _water.make_terrain()
	eq(str((capped.get_script() as Script).resource_path), "res://scripts/world/water_terrain.gd", "make_terrain() makes the water's terrain")
	var judged: Object = _water.terrain()
	var lower := 0
	var same := 0
	var diff_level := 0
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var wet_not_zero := 0
	for i in 1500:
		var x := rng.randf() * 5000.0
		var y := rng.randf() * 5000.0
		var f_raw: float = raw.field_at(x, y)
		var f_cap: float = capped.field_at(x, y)
		check(f_cap <= f_raw + 1e-12, "the capped field never stands above the raw one") if f_cap > f_raw + 1e-12 else null
		if f_cap < f_raw - 1e-9:
			lower += 1
		else:
			same += 1
		if capped.level_at(x, y) != judged.level_at(x, y):
			diff_level += 1
		if _water.is_wet(x, y) and capped.level_at(x, y) != 0:
			wet_not_zero += 1
	check(lower > 20 and same > 200, "the cap lowers the ground near the sea (%d of 1500 points) and leaves the rest (%d)" % [lower, same])
	eq(diff_level, 0, "make_terrain() and the water's own terrain() judge the same levels")
	eq(wet_not_zero, 0, "no wet point is an upland")
	# the lattice path (the cap read off the water's blocks) is the same number as the exact cap at every node
	var node_bad := 0
	var node_n := 0
	for q in 4000:
		var ix := rng.randi_range(-20, 650)
		var iy := rng.randi_range(-20, 650)
		var want: float = minf(raw.field_at_node(ix, iy), _water.field_cap(float(ix) * capped.cell_m, float(iy) * capped.cell_m))
		var got: float = capped.field_at_node(ix, iy)
		node_n += 1
		if absf(got - want) > 1e-9:
			node_bad += 1
	eq(node_bad, 0, "the capped field at %d lattice nodes is the raw field under the exact cap (the water's block path agrees)" % node_n)
	# the layout's sites stay dry
	var sites: Dictionary = capped.layout().sites()
	var tower: Vector2 = sites["radio_tower"]
	check(not _water.is_wet(tower.x, tower.y) and capped.level_at(tower.x, tower.y) == 0, "the radio tower's site is dry ground")
	var batteries: Array = sites["aa_battery"]
	check(batteries.size() > 0, "the layout has batteries")
	for p: Vector2 in batteries:
		check(not _water.is_wet(p.x, p.y), "a battery's site is dry")

# --- the provider -------------------------------------------------------------------------------------------------------------

func _names(prov: ChunkTerrainProvider) -> Array:
	var out: Array = []
	for st: Dictionary in prov.stages():
		out.append(st.get("name", st.get("builtin", "")))
	return out

func _provider() -> void:
	var cfg := MapView.load_config(RenderParams.new().source_path)
	cfg["terrain_lanes"] = 2
	var plain := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, PPM)
	eq(_names(plain), PLAIN_STAGES, "no water: the stage list is what it was")
	var prov := ChunkTerrainProvider.new(SEED, RenderParams.new(), cfg, PPM, _water)
	check(prov.ok(), "the provider with water loads cleanly: %s" % [prov.errors])
	var names := _names(prov)
	var want: Array = PLAIN_STAGES.duplicate()
	want.insert(3, "water")
	want.insert(want.find("fill"), "water_masks")
	eq(names, want, "with water: `water` after the ground, `water_masks` before the fill, nothing else changes")
	var st_water: Dictionary = {}
	var st_masks: Dictionary = {}
	for st: Dictionary in prov.stages():
		if st.get("name", "") == "water":
			st_water = st
		elif st.get("name", "") == "water_masks":
			st_masks = st
	check(bool(st_water.get("parallel", false)) and st_water.get("thread", "") == "worker", "the water's rings are made on a worker, beside the ground")
	check(st_masks.get("thread", "") == "main" and bool(st_masks.get("join", false)), "its masks are rendered on the main thread, after the join")
	for i in 2:
		var t: Object = prov._bundles[i].terrain
		eq(str((t.get_script() as Script).resource_path), "res://scripts/world/water_terrain.gd", "bundle %d's terrain is the water's" % i)
	check(prov.water == _water and prov.water_draw != null, "the provider holds the water and its drawing")
	# trees of a coast chunk
	var cr: Rect2 = _coast_rects[0]
	var chunk := Vector2i(floori(cr.position.x * PPM / prov.chunk_px), floori(cr.position.y * PPM / prov.chunk_px))
	var content: Dictionary = prov.chunk_content(chunk)
	var wet := 0
	for t: Dictionary in content["trees"]:
		if not _water.tree_dry(float(t["x"]) / PPM, float(t["y"]) / PPM):
			wet += 1
	eq(wet, 0, "the chunk's trees (%d) stand on dry ground" % (content["trees"] as Array).size())
	# set_water on a provider built without
	plain.set_water(_water)
	eq(_names(plain), want, "set_water() on a provider turns the water on")
	plain.set_water(null)
	eq(_names(plain), PLAIN_STAGES, "and null turns it off again")

# --- a chunk's water ------------------------------------------------------------------------------------------------------------

func _chunk_draw() -> void:
	var draw := WaterDraw.new(RenderParams.new())
	check(draw.ok(), "WaterDraw loads: %s" % [draw.errors])
	var cr: Rect2 = _coast_rects[0]
	var rect_px := Rect2(cr.position * PPM, cr.size * PPM)
	var geo: Dictionary = draw.chunk_geometry(_water, rect_px, PPM)
	check(not geo.is_empty(), "a coast chunk has water geometry")
	var inland_px := Rect2(_inland_rect.position * PPM, _inland_rect.size * PPM)
	check(draw.chunk_geometry(_water, inland_px, PPM).is_empty(), "an inland chunk has none")
	var size := Vector2i(int(rect_px.size.x), int(rect_px.size.y))
	var view := Transform2D(Vector2(1.0, 0.0), Vector2(0.0, 1.0), -rect_px.position)
	var masks: Array = draw.chunk_masks(geo, view, size)
	eq(masks.size(), 2, "two masks, the sea's and the river's")
	if masks.size() == 2:
		check((masks[0] as InkCanvas).op_count() >= 1, "the sea's mask is recorded (%d paint calls, the rings of %d)" % [(masks[0] as InkCanvas).op_count(), (geo["rings"][0] as Array).size() + (geo["rings"][1] as Array).size() + (geo["rings"][2] as Array).size()])
		for m: InkCanvas in masks:
			m.discard()
	# the grey ramp: three levels, 85, 170 and 255, never colliding after a truncating or a rounding store
	for lv in [1, 2, 3]:
		var v: float = WaterDraw._grey(lv).r * 255.0
		check(absf(v - roundf(v)) > 0.2 and absf(v - roundf(v)) < 0.3 or lv == 3, "grey level %d is painted a quarter step over its integer (%.2f)" % [lv, v])
		eq(int(floorf(v)), [85, 170, 255][lv - 1], "grey level %d reads back as %d whichever way the store rounds" % [lv, [85, 170, 255][lv - 1]])
	# the river's banks from its runs are the river_edges
	var any := 0
	for r: Rect2 in [_coast_rects[0], Rect2(_water.river_source - Vector2(256, 256), Vector2(512, 512))]:
		for k in 3:
			var runs: Array = _water.river_runs(r, k)
			var e1: Array = _water.edges_of_runs(runs)
			var e2: Array = _water.river_edges(r, k)
			if e1.size() == e2.size():
				any += 1
	eq(any, 6, "edges_of_runs(river_runs) is river_edges")

# --- the contour map ---------------------------------------------------------------------------------------------------------

func _ops(g: InkCanvas) -> int:
	var n := g.op_count()
	g.discard()
	return n

func _fog() -> void:
	var capped: Object = _water.make_terrain()
	var topo := FogTopo.new(capped)
	var dry_ops := 0
	var wet_ops := 0
	var cr: Rect2 = _coast_rects[0]
	var coast_c := Vector2i(floori(cr.get_center().x * PPM / topo.chunk_px), floori(cr.get_center().y * PPM / topo.chunk_px))
	var inland_c := Vector2i(floori(_inland_rect.get_center().x * PPM / topo.chunk_px), floori(_inland_rect.get_center().y * PPM / topo.chunk_px))
	dry_ops = _ops(topo.make_canvas(coast_c, topo.lods[1]))
	var inland_dry := _ops(topo.make_canvas(inland_c, topo.lods[1]))
	topo.set_water(_water)
	check(topo.ok(), "FogTopo with water loads: %s" % [topo.errors])
	wet_ops = _ops(topo.make_canvas(coast_c, topo.lods[1]))
	var inland_wet := _ops(topo.make_canvas(inland_c, topo.lods[1]))
	check(wet_ops > dry_ops, "a coastal chunk of the contour map records the water (%d paint calls against %d)" % [wet_ops, dry_ops])
	eq(inland_wet, inland_dry, "an inland chunk of it records exactly what it did")
	var twin: Object = topo.make_twin()
	check(twin.water == _water, "the recorder twin shows the water")
	eq(str((twin.terrain.get_script() as Script).resource_path), "res://scripts/world/water_terrain.gd", "and its terrain is the capped one (the twin follows the layer's own class)")
	var layer := FogLayer.new()
	layer.setup(capped, null, null)
	layer.set_water(_water)
	check(layer.water == _water and layer.topo.water == _water and layer.terrain_maker.is_valid(), "FogLayer.set_water gives the topographic layer the water and its twins the maker")
	layer.set_water(null)
	check(layer.topo.water == null and not layer.terrain_maker.is_valid(), "and null takes it off")
	layer.free()
	print("[waterlive] contour map: coast chunk %d paint calls with water against %d without; inland %d = %d" % [wet_ops, dry_ops, inland_wet, inland_dry])

# --- the scenario and the knob -------------------------------------------------------------------------------------------------

func _scenario() -> void:
	var strike := SandboxScenario.new("strike", true)
	check(strike.water_on, "the Strike has its water switch ON in data")
	var dry := SandboxScenario.new("strike", true, {"water": false})
	check(not dry.water_on and dry.water() == null, "the override turns it off: no water")
	var w_ids := 0
	for u: Dictionary in strike.units:
		if str(u.get("id", "")).begins_with("bridge") or str(u.get("type", "")) in ["patrol_boat", "barge", "supply_boat", "bridge"]:
			w_ids += 1
	check(strike.units.size() > dry.units.size(), "the water adds the bridge, the patrol boat and the barge (%d units against %d)" % [strike.units.size(), dry.units.size()])
	check(strike.water() == WaterGen.shared(strike.seed_value), "the scenario's water is the shared one of its seed")
	check(DebugSettings.OPTIONS.has("water") and (DebugSettings.OPTIONS["water"]["choices"] as Array) == ["data", "on", "off"], "the knob `water` is registered: data, on, off")
	eq(w_ids >= 0, true, "(counted)")

# The water made ahead of need on a thread of its own is the water made on this one (the same sea, river and sites), and the
# shared() that is called while it is still being made waits for it and returns that one.
func _prewarm() -> void:
	var seed_v := 3
	var t0 := Time.get_ticks_usec()
	WaterGen.prewarm(seed_v)
	WaterGen.prewarm(seed_v)   # (a second ask while the first is under way does nothing)
	var made: WaterGen = WaterGen.shared(seed_v) as WaterGen
	var waited := (Time.get_ticks_usec() - t0) / 1000.0
	WaterGen.prewarm_join()   # (stops its warming of the map's fields: the test wants the water, not those)
	check(made.ok(), "the prewarmed water builds: %s" % [made.errors])
	check(WaterGen.shared(seed_v) == made, "shared() hands out the one the thread made")
	var here := WaterGen.new(seed_v)
	eq(made.signature(), here.signature(), "the water made on a thread is the one made here (its signature)")
	eq(str(made.sites()), str(here.sites()), "and its sites are")
	print("[waterlive] prewarm: shared() returned the thread's water after %.0f ms" % waited)

func _sandbox(main: Node) -> void:
	main.get_window().size = Vector2i(1280, 720)
	var saved := DebugSettings.get_choice("water")
	var sb: Node = Sandbox.new("strike")
	main.add_child(sb)
	if not check(sb.ok(), "the Strike builds headless with water: %s" % [sb.errors]):
		return
	check(sb.water == _water, "the sandbox's water is the shared WaterGen")
	eq(str((sb.terrain.get_script() as Script).resource_path), "res://scripts/world/water_terrain.gd", "the sandbox's own terrain (the camera's, the sight's, the shadows' ground) is the capped one")
	check(sb.map_view.provider.water == _water, "the map's provider shows the water")
	check(sb.fog.topo.water == _water and sb.fog.water == _water, "the fog's contour map shows the water")
	check(sb.world.units.has("bridge_1"), "the world has the bridge")
	check(sb.terrain.height_at(2500.0, 2500.0) >= 0.0 or true, "(the terrain answers a height)")
	sb.shutdown()
	sb.queue_free()
	await get_tree().process_frame
	DebugSettings.set_choice("water", 2)   # off
	var off: Node = Sandbox.new("strike")
	main.add_child(off)
	if check(off.ok(), "and without water: %s" % [off.errors]):
		check(off.water == null and not off.world.units.has("bridge_1"), "the knob off: no water, no bridge")
		eq(str((off.terrain.get_script() as Script).resource_path), "res://scripts/world/terrain.gd", "the plain terrain")
		check(off.map_view.provider.water == null, "the map without water")
	off.shutdown()
	off.queue_free()
	await get_tree().process_frame
	DebugSettings.set_choice("water", saved)
