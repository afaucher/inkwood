extends "res://scripts/test_support/test_case.gd"

# Track T's terrain (scripts/world/terrain.gd), headless -- generation only,
# no pixels. What it holds the generator to:
#
#   DATA         data/terrain/terrain.json parses, every field in it is read by
#                Terrain + TerrainDraw + TerrainShadows (TerrainData.unused()
#                is empty), and the map bounds come from Track S's
#                data/sim/turn.json when that file is there.
#   DETERMINISM  two Terrains on one seed give the same field, the same
#                boundary points and the same trees; another seed does not.
#   CHUNKS       a chunk generated ALONE equals the same chunk generated after
#                all of its neighbours (field, boundaries, regions, trees,
#                bit for bit); open boundary ends meet the neighbour's exactly,
#                with consistent orientation; no two trees overlap across a
#                chunk border.
#   AGREEMENT    level_at agrees with the boundary polylines: just inside a
#                boundary (on its right) the level is above the threshold,
#                just outside it is not; level_at equals a brute-force
#                even-odd test against every region polygon at random points;
#                height_at is the level's height.
#   TREES        every tree's level is level_at at its foot, its base is that
#                level's height (metres and px); trees stand on at least two
#                levels; none stands on a scarp's slope band.
#
# The generation timings are printed for the report ([terrain] lines).

const Terrain = preload("res://scripts/world/terrain.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")
const TerrainShadows = preload("res://scripts/render/terrain_shadows.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const SEED := 20261009

func setup(_main) -> void:
	timeout_seconds = 300.0
	var t0 := Time.get_ticks_usec()
	var a := Terrain.new(SEED)
	if not check(a.ok(), "terrain loads cleanly: %s %s" % [a.errors, a.data.errors]):
		finish()
		return
	_data(a)
	var c := _pick_chunk(a)
	print("[terrain] test chunk ", c)
	_determinism(a, c)
	_chunks(c)
	_agreement(a, c)
	_trees(a, c)
	print("[terrain] test total %.0f ms" % _ms(t0))
	finish()

# --- data -----------------------------------------------------------------------

func _data(a: Terrain) -> void:
	var td := TerrainDraw.new(a)
	var ts := TerrainShadows.new(a)
	check(td.ok(), "terrain draw settings load cleanly: %s" % [td.errors])
	check(a.data.ok(), "no data errors: %s" % [a.data.errors])
	var unused := a.data.unused()
	check(unused.is_empty(), "every field of terrain.json is read; unused: %s" % [unused])
	print("[terrain] terrain.json: %d fields read, %d unused" % [a.data._used.size(), unused.size()])
	eq(a.heights_m.size(), a.thresholds.size() + 1, "one level height per threshold plus the low ground")
	check(a.level_count() >= 2, "at least two height levels")
	eq(a.veg_threshold.size(), a.level_count(), "a vegetation rule per level")
	check(a.px_per_m > 0.0, "px_per_m is positive")
	if FileAccess.file_exists("res://data/sim/turn.json"):
		check(a.bounds_source.begins_with("res://data/sim/turn.json"),
			"map bounds come from Track S's turn.json (got %s)" % a.bounds_source)
	check(ts.L > 0.0 and ts.dir.is_normalized(), "the sun gives a shadow direction and length")
	print("[terrain] map %s x %s m (%s), %s px/m = %d x %d px; %d chunks of %s m" % [a.map_w, a.map_h,
		a.bounds_source, a.px_per_m, roundi(a.map_w * a.px_per_m), roundi(a.map_h * a.px_per_m),
		a.map_chunk_range().get_area(), a.chunk_m])

# A chunk near the map centre whose 3 x 3 block has both low ground and upland.
func _pick_chunk(a: Terrain) -> Vector2i:
	var r := a.map_chunk_range()
	var mid := r.position + r.size / 2
	for d in range(0, 6):
		for cy in range(mid.y - d, mid.y + d + 1):
			for cx in range(mid.x - d, mid.x + d + 1):
				var c := a.chunk(cx, cy)
				var up := 0
				var vals: PackedFloat64Array = c.vals
				for v in vals:
					if v >= a.thresholds[0]:
						up += 1
				var share := float(up) / vals.size()
				if share > 0.25 and share < 0.75 and not (c.levels[0].chains as Array).is_empty():
					return Vector2i(cx, cy)
	return mid

# --- determinism --------------------------------------------------------------------

func _determinism(a: Terrain, c: Vector2i) -> void:
	var b := Terrain.new(SEED)
	for d: Vector2i in [c, c + Vector2i(1, 0), c + Vector2i(0, 1)]:
		var ga := a.chunk(d.x, d.y)
		var gb := b.chunk(d.x, d.y)
		check(ga.vals == gb.vals, "same seed, same field in chunk %s" % d)
		for k in a.thresholds.size():
			check(_same_chains(ga.levels[k].chains, gb.levels[k].chains),
				"same seed, same boundary points in chunk %s, threshold %d" % [d, k])
	check(_same_trees(a.trees_in_chunk(c.x, c.y), b.trees_in_chunk(c.x, c.y)), "same seed, same trees in chunk %s" % c)
	var other := Terrain.new(SEED + 1)
	check(other.chunk(c.x, c.y).vals != a.chunk(c.x, c.y).vals, "another seed gives another field")

static func _same_chains(x: Array, y: Array) -> bool:
	if x.size() != y.size():
		return false
	for i in x.size():
		if x[i].closed != y[i].closed or x[i].pts != y[i].pts:
			return false
	return true

static func _same_polys(x: Array, y: Array) -> bool:
	if x.size() != y.size():
		return false
	for i in x.size():
		if x[i].border != y[i].border or x[i].pts != y[i].pts or x[i].area != y[i].area:
			return false
	return true

static func _same_trees(x: Array, y: Array) -> bool:
	if x.size() != y.size():
		return false
	for i in x.size():
		for f in ["x", "y", "seed", "sr", "hr", "big", "r", "h", "level", "base", "base_m"]:
			if x[i][f] != y[i][f]:
				return false
	return true

# --- chunks ---------------------------------------------------------------------------

func _chunks(c: Vector2i) -> void:
	# ALONE: a fresh terrain asked for this one chunk and nothing else.
	var alone := Terrain.new(SEED)
	var t0 := Time.get_ticks_usec()
	var g_alone := alone.chunk(c.x, c.y)
	var t_geo := _ms(t0)
	t0 = Time.get_ticks_usec()
	var trees_alone := alone.trees_in_chunk(c.x, c.y)
	var t_cold := _ms(t0)
	print("[terrain] one chunk: geometry %.1f ms; trees %.0f ms cold (its own placement and its 4 earlier neighbours'), one placement %.0f ms; %d trees" % [
		t_geo, t_cold, alone.timings.get("chunk_trees_pre_ms", -1.0), trees_alone.size()])

	# WITH NEIGHBOURS: every chunk of the 5 x 5 block around it first, in reverse order.
	var crowd := Terrain.new(SEED)
	t0 = Time.get_ticks_usec()
	for cy in range(c.y + 2, c.y - 3, -1):
		for cx in range(c.x + 2, c.x - 3, -1):
			if Vector2i(cx, cy) != c:
				crowd.chunk(cx, cy)
				if absi(cx - c.x) <= 1 and absi(cy - c.y) <= 1:
					crowd.trees_in_chunk(cx, cy)
	print("[terrain] 5 x 5 geometry + 3 x 3 trees (minus one) %.0f ms" % _ms(t0))
	var g_crowd := crowd.chunk(c.x, c.y)
	check(g_alone.vals == g_crowd.vals, "chunk alone == chunk among neighbours: field")
	for k in alone.thresholds.size():
		check(_same_chains(g_alone.levels[k].chains, g_crowd.levels[k].chains),
			"chunk alone == chunk among neighbours: boundaries, threshold %d" % k)
		check(_same_polys(g_alone.levels[k].polys, g_crowd.levels[k].polys),
			"chunk alone == chunk among neighbours: regions, threshold %d" % k)
	check(_same_trees(trees_alone, crowd.trees_in_chunk(c.x, c.y)), "chunk alone == chunk among neighbours: trees")

	# Open ends meet across every border of the 3 x 3 block, oriented consistently.
	var meets := 0
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			meets += _borders_meet(crowd, Vector2i(cx, cy), Vector2i(cx + 1, cy))
			meets += _borders_meet(crowd, Vector2i(cx, cy), Vector2i(cx, cy + 1))
	check(meets > 0, "the block has boundaries crossing chunk borders (%d checked)" % meets)
	print("[terrain] %d boundary ends checked across chunk borders" % meets)

	# No overlap anywhere in the 3 x 3 block (within a chunk: can_place; across: the border pass).
	var all: Array = []
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			all.append_array(crowd.trees_in_chunk(cx, cy))
	var k_cr := crowd.P.tree_collision_radius
	var overlaps := 0
	var cross_pairs := 0
	for i in all.size():
		for j in range(i + 1, all.size()):
			var p: Dictionary = all[i]
			var q: Dictionary = all[j]
			var dx: float = p.x - q.x
			var dy: float = p.y - q.y
			var rr: float = (p.r + q.r) * k_cr
			if dx * dx + dy * dy < rr * rr:
				overlaps += 1
				if overlaps <= 5:
					fail("trees overlap: %s %s and %s %s" % [p.chunk, Vector2(p.x, p.y), q.chunk, Vector2(q.x, q.y)])
			elif p.chunk != q.chunk and dx * dx + dy * dy < 4.0 * rr * rr:
				cross_pairs += 1
	eq(overlaps, 0, "no overlapping trees in the 3 x 3 block (%d trees)" % all.size())
	check(cross_pairs > 0, "trees do stand close across chunk borders (%d near pairs) -- the border is not a gap" % cross_pairs)

# Every open chain end on the shared border of a and b has a partner end in
# the other chunk at the same point: an END in one is a START in the other.
func _borders_meet(t: Terrain, a: Vector2i, b: Vector2i) -> int:
	var count := 0
	for k in t.thresholds.size():
		var ends_a := _border_ends(t, a, k)
		var ends_b := _border_ends(t, b, k)
		var vertical := b.x != a.x
		var line := float(b.x if vertical else b.y) * t.chunk_m
		for e: Array in ends_a:
			var on: bool = (e[0] if vertical else e[1]) == line
			if not on:
				continue
			count += 1
			var found := false
			for f: Array in ends_b:
				if f[0] == e[0] and f[1] == e[1]:
					found = true
					check(f[2] != e[2], "border point %s is a start on one side and an end on the other" % Vector2(e[0], e[1]))
			check(found, "boundary end %s of chunk %s meets chunk %s" % [Vector2(e[0], e[1]), a, b])
	return count

# [x, y, is_start] for every open chain end of chunk c, threshold k.
static func _border_ends(t: Terrain, c: Vector2i, k: int) -> Array:
	var out: Array = []
	for ch: Dictionary in t.chunk(c.x, c.y).levels[k].chains:
		if ch.closed:
			continue
		var p: PackedFloat64Array = ch.pts
		out.append([p[0], p[1], true])
		out.append([p[p.size() - 2], p[p.size() - 1], false])
	return out

# --- agreement -------------------------------------------------------------------------

func _agreement(t: Terrain, c: Vector2i) -> void:
	var delta := 0.4  # metres either side of the line
	var checked := 0
	var bad := 0
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			for k in t.thresholds.size():
				for ch: Dictionary in t.chunk(cx, cy).levels[k].chains:
					var p: PackedFloat64Array = ch.pts
					var n := p.size() / 2
					for i in range(1, n - 1, 5):
						var tx: float = p[(i + 1) * 2] - p[(i - 1) * 2]
						var ty: float = p[(i + 1) * 2 + 1] - p[(i - 1) * 2 + 1]
						var l := sqrt(tx * tx + ty * ty)
						if l == 0.0:
							continue
						# right of the chain = higher; (-ty, tx) is the right normal, y down
						var rx := -ty / l * delta
						var ry := tx / l * delta
						var hi := t.level_at(p[i * 2] + rx, p[i * 2 + 1] + ry)
						var lo := t.level_at(p[i * 2] - rx, p[i * 2 + 1] - ry)
						checked += 1
						if hi < k + 1 or lo > k:
							bad += 1
							if bad <= 5:
								fail("threshold %d boundary at %s: level %d on its high side, %d on its low side" % [
									k, Vector2(p[i * 2], p[i * 2 + 1]), hi, lo])
	eq(bad, 0, "level_at sides with the boundary polylines at %d points" % checked)
	check(checked > 100, "the agreement check saw boundary points (%d)" % checked)
	print("[terrain] level_at vs polylines: %d boundary points, %d disagreements" % [checked, bad])

	# level_at (grid fast path + bucketed parity) against brute-force even-odd.
	var g := t.chunk(c.x, c.y)
	var rng := Mulberry32.new(7)  # the project RNG for sample points, never the engine's
	var mism := 0
	for s in 3000:
		var x: float = g.x0 + rng.next() * t.chunk_m
		var y: float = g.y0 + rng.next() * t.chunk_m
		var want := 0
		for k in t.thresholds.size():
			if not _brute_inside(g.levels[k].polys, x, y):
				break
			want = k + 1
		var got := t.level_at(x, y)
		if got != want:
			mism += 1
			if mism <= 5:
				fail("level_at(%s) = %d, brute force says %d" % [Vector2(x, y), got, want])
		if not is_equal_approx(t.height_at(x, y), t.heights_m[got]):
			fail("height_at(%s) is not level %d's height" % [Vector2(x, y), got])
	eq(mism, 0, "level_at equals brute-force even-odd over the region polygons at 3000 points")
	print("[terrain] level_at vs brute-force even-odd: 3000 points, %d mismatches" % mism)

static func _brute_inside(polys: Array, x: float, y: float) -> bool:
	var inside := false
	for poly: Dictionary in polys:
		var p: PackedFloat64Array = poly.pts
		var n := p.size() / 2
		for i in n:
			var j := (i + 1) % n
			var ay: float = p[i * 2 + 1]
			var by: float = p[j * 2 + 1]
			if (ay > y) != (by > y):
				var xi: float = p[i * 2] + (y - ay) / (by - ay) * (p[j * 2] - p[i * 2])
				if xi > x:
					inside = not inside
	return inside

# --- trees -----------------------------------------------------------------------------

func _trees(t: Terrain, c: Vector2i) -> void:
	var by_level := {}
	var total := 0
	var on_slope := 0
	var ppm := t.px_per_m
	for cy in range(c.y - 1, c.y + 2):
		for cx in range(c.x - 1, c.x + 2):
			for tr: Dictionary in t.trees_in_chunk(cx, cy):
				total += 1
				var xm: float = tr.x / ppm
				var ym: float = tr.y / ppm
				var lvl := t.level_at(xm, ym)
				if not eq(tr.level, lvl, "tree at %s: its level is level_at at its foot" % Vector2(tr.x, tr.y)):
					continue
				eq(tr.base_m, t.height_at(xm, ym), "tree at %s: base_m is its level's height" % Vector2(tr.x, tr.y))
				eq(tr.base, t.heights_m[lvl] * ppm, "tree at %s: base (px) is its level's height in px" % Vector2(tr.x, tr.y))
				by_level[lvl] = by_level.get(lvl, 0) + 1
				for k in t.thresholds.size():
					if lvl <= k and t.boundary_distance(xm, ym, k, t.scarp_m) < t.scarp_m:
						on_slope += 1
	print("[terrain] 3 x 3 block: %d trees, by level %s" % [total, by_level])
	check(by_level.size() >= 2, "trees stand on at least two levels (%s)" % [by_level])
	eq(on_slope, 0, "no tree stands on a scarp's slope band")

static func _ms(t0: int) -> float:
	return (Time.get_ticks_usec() - t0) / 1000.0
