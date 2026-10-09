extends RefCounted

# WHERE TO LOOK (Track F, line of sight): two sites in a seeded terrain found
# by search, not by hand, so the look and the tests hold for any seed. Both read
# only Terrain.level_at (metres), keep clear of the map edge by the sight range
# so a whole viewshed fits, and are deterministic.
#
#   find_valley(terrain)        a low-ground point with higher ground 150 to
#                               400 m away on most sides: "a tank's view inside
#                               a valley" (Alex)
#   find_plateau_edge(terrain)  a point on high ground a few tens of metres back
#                               from a cliff, with low ground stretching away
#                               below: the viewer who has DEAD GROUND under the
#                               cliff and sees low ground again further out
#
# Used by fog_los_shot.gd (the pictures) and test_viewshed.gd.

const DIRS := 16

# {p: Vector2 metres, dirs: sides with higher ground 150-400 m away (of 16),
#  level2: how many of those are the top level, note: String}
#
# With open_pick, the best forty valleys (at least 120 m apart, no fewer sides closed
# in than the best minus two) are looked at again for TREES: the one with the least
# canopy within 150 m and groves round about (so the trees have something to hide) wins,
# and the spot is then moved up to 200 m to the clearest ground that is still as closed
# in (canopy within 60 m and 150 m, in that order). For pictures, where a tank deep in a
# grove sees 20 m whatever the cliffs do.
static func find_valley(terrain: Object, margin_m: float = 950.0, step_m: float = 40.0, open_pick: bool = false) -> Dictionary:
	var centre := Vector2(terrain.map_x + terrain.map_w * 0.5, terrain.map_y + terrain.map_h * 0.5)
	var best := {"p": centre, "dirs": -1, "level2": 0, "note": "none found", "score": -INF}
	var unit: Array[Vector2] = []
	for a in DIRS:
		unit.append(Vector2.from_angle(float(a) / float(DIRS) * TAU))
	var x0: float = terrain.map_x + margin_m
	var x1: float = terrain.map_x + terrain.map_w - margin_m
	var y0: float = terrain.map_y + margin_m
	var y1: float = terrain.map_y + terrain.map_h - margin_m
	var cands: Array = []
	var y := y0
	while y <= y1:
		var x := x0
		while x <= x1:
			if terrain.level_at(x, y) == 0 and _clear_near(terrain, x, y, unit):
				var sides := _sides(terrain, x, y, unit)
				var dirs: int = sides.x
				var l2: int = sides.y
				var score := float(dirs) * 100.0 + float(l2) * 8.0 - 0.02 * Vector2(x, y).distance_to(centre)
				var rec := {"p": Vector2(x, y), "dirs": dirs, "level2": l2, "score": score,
					"note": "higher ground on %d of %d sides (%d of them the top level)" % [dirs, DIRS, l2]}
				if score > best.score:
					best = rec
				if open_pick:
					cands.append(rec)
			x += step_m
		y += step_m
	if not open_pick or cands.is_empty():
		return best
	cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)
	var picked: Array = []
	for c: Dictionary in cands:
		var apart := true
		for q: Dictionary in picked:
			if (c.p as Vector2).distance_to(q.p) < 120.0:
				apart = false
		if apart and int(c.dirs) >= int(best.dirs) - 2:
			picked.append(c)
		if picked.size() >= 40:
			break
	var top_dirs: int = best.dirs
	var winner: Dictionary = best
	var winner_rank := -INF
	for c: Dictionary in picked:
		if int(c.dirs) < top_dirs - 2:
			continue
		var near := tree_cover(terrain, c.p, 60.0)
		var mid := tree_cover(terrain, c.p, 150.0)
		var around := tree_cover(terrain, c.p, 250.0)
		c["cover60"] = near
		c["cover150"] = mid
		c["cover250"] = around
		# a clearing (no canopy close in, little to 150 m), groves around (some canopy out to 250 m)
		var rank: float = float(c.score) - 3000.0 * mid - 400.0 * absf(around - 0.3)
		if rank > winner_rank:
			winner_rank = rank
			winner = c
	# Move to the clearest ground nearby that is still as closed in.
	var centre_p: Vector2 = winner.p
	var min_dirs: int = int(winner.dirs)
	var best_rank := INF
	var best_q: Vector2 = centre_p
	var best_sides := Vector2i(int(winner.dirs), int(winner.level2))
	for dy in range(-200, 201, 20):
		for dx in range(-200, 201, 20):
			var q := centre_p + Vector2(float(dx), float(dy))
			if q.x < x0 or q.x > x1 or q.y < y0 or q.y > y1:
				continue
			if terrain.level_at(q.x, q.y) != 0 or not _clear_near(terrain, q.x, q.y, unit):
				continue
			var q_near := tree_cover(terrain, q, 60.0)
			var q_mid := tree_cover(terrain, q, 150.0)
			var rank := 3.0 * q_near + q_mid
			if rank >= best_rank:
				continue
			var sd := _sides(terrain, q.x, q.y, unit)
			if sd.x < min_dirs:
				continue
			best_rank = rank
			best_q = q
			best_sides = sd
	winner = {"p": best_q, "dirs": best_sides.x, "level2": best_sides.y, "score": winner.score}
	winner["note"] = "higher ground on %d of %d sides (%d of them the top level); canopy %.0f%% within 60 m, %.0f%% within 150 m, %.0f%% within 250 m" % [
		best_sides.x, DIRS, best_sides.y, 100.0 * tree_cover(terrain, best_q, 60.0), 100.0 * tree_cover(terrain, best_q, 150.0), 100.0 * tree_cover(terrain, best_q, 250.0)]
	return winner

# The share of the disc of radius r_m around p that tree canopies cover (summed,
# so overlaps count twice: a density, not an area).
static func tree_cover(terrain: Object, p: Vector2, r_m: float) -> float:
	var ppm: float = terrain.px_per_m
	var rect := Rect2((p - Vector2(r_m, r_m)) * ppm, Vector2(r_m, r_m) * 2.0 * ppm)
	var area := 0.0
	for t: Dictionary in terrain.trees_in_rect_px(rect):
		var tp := Vector2(float(t.x), float(t.y)) / ppm
		if tp.distance_to(p) <= r_m:
			var rr: float = float(t.r) / ppm
			area += PI * rr * rr
	return area / (PI * r_m * r_m)

# Sides (of 16) with higher ground 150-400 m away, and how many of those are the top level.
static func _sides(terrain: Object, x: float, y: float, unit: Array[Vector2]) -> Vector2i:
	var dirs := 0
	var l2 := 0
	for u in unit:
		var hit := 0
		var d := 150.0
		while d <= 400.0:
			var lv: int = terrain.level_at(x + u.x * d, y + u.y * d)
			hit = maxi(hit, lv)
			d += 25.0
		if hit >= 1:
			dirs += 1
		if hit >= 2:
			l2 += 1
	return Vector2i(dirs, l2)

# Nothing higher within 60 m on any of the eight compass sides (not at a cliff foot).
static func _clear_near(terrain: Object, x: float, y: float, unit: Array[Vector2]) -> bool:
	for i in range(0, DIRS, 2):
		for d in [20.0, 40.0, 60.0]:
			if terrain.level_at(x + unit[i].x * d, y + unit[i].y * d) != 0:
				return false
	return true

# {p: the viewer, dir: unit vector pointing out over the cliff, cliff_m: how far
#  the cliff edge is from p, far_m: a distance along dir at which the ground is
#  low again and the dead ground is over, level: the viewer's level, note}
static func find_plateau_edge(terrain: Object, margin_m: float = 950.0, step_m: float = 40.0, standoff_m: float = 28.0) -> Dictionary:
	var centre := Vector2(terrain.map_x + terrain.map_w * 0.5, terrain.map_y + terrain.map_h * 0.5)
	var best := {"p": centre, "dir": Vector2.RIGHT, "cliff_m": standoff_m, "far_m": 300.0, "level": 1, "note": "none found", "score": -INF}
	var n := 24
	var unit: Array[Vector2] = []
	for a in n:
		unit.append(Vector2.from_angle(float(a) / float(n) * TAU))
	var x0: float = terrain.map_x + margin_m
	var x1: float = terrain.map_x + terrain.map_w - margin_m
	var y0: float = terrain.map_y + margin_m
	var y1: float = terrain.map_y + terrain.map_h - margin_m
	var y := y0
	while y <= y1:
		var x := x0
		while x <= x1:
			var lv: int = terrain.level_at(x, y)
			if lv >= 1:
				# Which directions run out to a cliff within 60 m and then onto low ground?
				var ok_dir: Array[float] = []
				for u in unit:
					ok_dir.append(_drop_distance(terrain, Vector2(x, y), u, lv))
				for a in n:
					if ok_dir[a] <= 0.0:
						continue
					# a wide front: the neighbours within 45 degrees drop too
					var front := 0
					for o in range(-3, 4):
						if ok_dir[(a + o + n) % n] > 0.0:
							front += 1
					var score := float(front) * 10.0 + float(lv) * 3.0 - 0.01 * Vector2(x, y).distance_to(centre)
					if score > best.score:
						best = {"p": Vector2(x, y), "dir": unit[a], "edge_m": ok_dir[a], "level": lv, "score": score, "front": front}
			x += step_m
		y += step_m
	if best.score == -INF:
		return best
	# Stand `standoff_m` back from the edge, along the bearing found.
	var u: Vector2 = best.dir
	var edge_pt: Vector2 = best.p + u * float(best.edge_m)
	var p: Vector2 = edge_pt - u * standoff_m
	var lvl: int = best.level
	while terrain.level_at(p.x, p.y) != lvl and standoff_m > 6.0:
		standoff_m -= 2.0
		p = edge_pt - u * standoff_m
	var h_up: float = terrain.heights_m[lvl]
	# The dead ground ends where the sight line over the rim meets low ground:
	# (h_up + eye) / D = eye / d  ->  D = (h_up + eye) x d / eye, eye = 2.5 m; with margin.
	var dead_end := (h_up + 2.5) * standoff_m / 2.5
	var far := dead_end * 1.4
	while far < 600.0 and not _low_ahead(terrain, p, u, far):
		far += 20.0
	best.p = p
	best.cliff_m = standoff_m
	best.far_m = far
	best.note = "level %d, cliff %.0f m ahead, a front of %d of 7 bearings, low ground again from about %.0f m" % [lvl, standoff_m, best.front, far]
	return best

# Distance from p along u to the first point lower than `lv` (a cliff), when that is
# within 12-60 m and the ground 120-450 m beyond it is low (level 0); else 0.
static func _drop_distance(terrain: Object, p: Vector2, u: Vector2, lv: int) -> float:
	var d := 4.0
	while d <= 60.0:
		var q := p + u * d
		if terrain.level_at(q.x, q.y) < lv:
			break
		d += 4.0
	if d > 60.0 or d < 12.0:
		return 0.0
	# bisect the edge to a metre
	var lo := d - 4.0
	var hi := d
	for _i in 3:
		var mid := (lo + hi) * 0.5
		var q := p + u * mid
		if terrain.level_at(q.x, q.y) < lv:
			hi = mid
		else:
			lo = mid
	var edge := hi
	for k: float in [120.0, 200.0, 300.0, 450.0]:
		var q := p + u * (edge + k)
		if terrain.level_at(q.x, q.y) != 0:
			return 0.0
	return edge

static func _low_ahead(terrain: Object, p: Vector2, u: Vector2, d: float) -> bool:
	for k: float in [0.0, 30.0, 60.0]:
		var q := p + u * (d + k)
		if terrain.level_at(q.x, q.y) != 0:
			return false
	return true
