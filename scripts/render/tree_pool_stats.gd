extends SceneTree

# THE MAP'S TREE SIZES (Track P2, 2026-10-10). A tool, not a test (no window needed):
#
#   INKWOOD_STEAM=off Godot_console.exe --headless --path . --script res://scripts/render/tree_pool_stats.gd -- ppm=2 every=4
#
# Samples every `every`-th terrain cell of the map (Terrain.trees_in_chunk, the trees the map bakes), and prints
# the spread of the trees' radii in px and the pool buckets (map_view.tree_pool.bucket_px) they fall in: how many
# buckets the map uses, from where to where, and how many trees each holds. It is how the size of the global tree
# set (tree_pool.variants x the buckets) was chosen: see docs/proposals/map-performance.md.

const Terrain = preload("res://scripts/world/terrain.gd")

var opts: Dictionary = {}

func _initialize() -> void:
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			opts[kv[0]] = kv[1]
	_run.call_deferred()

func _run() -> void:
	var ppm := float(opts.get("ppm", "2"))
	var every := maxi(1, int(opts.get("every", "4")))
	var bucket_px := float(opts.get("bucket", "0.5"))
	var terrain := Terrain.new(20261009)
	terrain.px_per_m = ppm
	var rng_cells := terrain.map_chunk_range()
	var radii: Array = []
	var cells := 0
	var t0 := Time.get_ticks_msec()
	for cy in range(rng_cells.position.y, rng_cells.position.y + rng_cells.size.y):
		for cx in range(rng_cells.position.x, rng_cells.position.x + rng_cells.size.x):
			if (cx + cy * 7) % every != 0:
				continue
			cells += 1
			for t: Dictionary in terrain.trees_in_chunk(cx, cy):
				radii.append(float(t.r))
	radii.sort()
	var n := radii.size()
	print("[trees] %d cells sampled (every %d), %d trees, %.1f s" % [cells, every, n, (Time.get_ticks_msec() - t0) / 1000.0])
	if n == 0:
		quit(1)
		return
	print("[trees] radius px at %.1f px/m: min %.2f, p1 %.2f, p10 %.2f, median %.2f, p90 %.2f, p99 %.2f, max %.2f" % [
		ppm, radii[0], radii[int(n * 0.01)], radii[int(n * 0.10)], radii[n / 2], radii[int(n * 0.90)], radii[int(n * 0.99)], radii[n - 1]])
	var hist: Dictionary = {}
	for r: float in radii:
		var b := roundi(r / bucket_px)
		hist[b] = int(hist.get(b, 0)) + 1
	var keys := hist.keys()
	keys.sort()
	var lo: int = keys[0]
	var hi: int = keys[keys.size() - 1]
	print("[trees] buckets of %.2f px: %d used, from %d (r %.2f) to %d (r %.2f); %d buckets would span the whole range" % [
		bucket_px, keys.size(), lo, lo * bucket_px, hi, hi * bucket_px, hi - lo + 1])
	# how many buckets hold 99%, 99.9% of the trees (the rest build on demand)
	var cum := 0
	var sorted_by_count: Array = []
	for b: int in keys:
		sorted_by_count.append([int(hist[b]), b])
	sorted_by_count.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	var need99 := 0
	var need999 := 0
	for e: Array in sorted_by_count:
		cum += int(e[0])
		if need99 == 0 and cum >= n * 0.99:
			need99 = sorted_by_count.find(e) + 1
		if need999 == 0 and cum >= n * 0.999:
			need999 = sorted_by_count.find(e) + 1
	print("[trees] buckets holding 99%% of the trees: %d, 99.9%%: %d" % [need99, need999])
	var parts: Array[String] = []
	for b: int in keys:
		parts.append("%.1f:%d" % [b * bucket_px, hist[b]])
	print("[trees] histogram (radius px: trees) %s" % " ".join(parts))
	_repeats(terrain, ppm, bucket_px, int(opts.get("variants", "28")), float(opts.get("near", "60")))
	quit(0)

# How often two trees that stand close together are drawn from the same sprite of the global set (the same size bucket
# and the same variant): in the densest wood within three terrain cells of the map's centre, for a window the size of a
# 1920 x 1080 screen at zoom 1 and one at the planning zoom (0.3), a tree counting if another tree of the SAME sprite
# stands within `near` map px (about three tree radii) of it.
func _repeats(terrain: RefCounted, ppm: float, bucket_px: float, variants: int, near: float) -> void:
	var rc: Rect2i = terrain.map_chunk_range()
	var best := Vector2i(rc.position.x + rc.size.x / 2, rc.position.y + rc.size.y / 2)
	var best_n := -1
	for cy in range(best.y - 3, best.y + 4):
		for cx in range(best.x - 3, best.x + 4):
			var n: int = terrain.trees_in_chunk(cx, cy).size()
			if n > best_n:
				best_n = n
				best = Vector2i(cx, cy)
	var centre := (Vector2(best) + Vector2(0.5, 0.5)) * float(terrain.chunk_m) * ppm
	for z: float in [1.0, 0.3]:
		var win := Rect2(centre - Vector2(960.0, 540.0) / z, Vector2(1920.0, 1080.0) / z)
		var trees: Array = terrain.trees_in_rect_px(win)
		var keys: Array = []
		var by_key: Dictionary = {}
		for i in trees.size():
			var t: Dictionary = trees[i]
			var k := "%d|%d" % [roundi(float(t.r) / bucket_px), absi(int(t.seed)) % variants]
			keys.append(k)
			if not by_key.has(k):
				by_key[k] = []
			(by_key[k] as Array).append(Vector2(float(t.x), float(t.y)))
		var twins := 0
		for i in trees.size():
			var p := Vector2(float(trees[i].x), float(trees[i].y))
			for q: Vector2 in by_key[keys[i]]:
				if q != p and q.distance_to(p) <= near:
					twins += 1
					break
		print("[trees] a 1920 x 1080 screen at zoom %.1f over the densest wood: %d trees, %d distinct sprites, %d (%.1f%%) have the same sprite another tree stands within %.0f map px of" % [
			z, trees.size(), by_key.size(), twins, 100.0 * twins / maxf(trees.size(), 1), near])
