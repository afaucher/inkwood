extends "res://scripts/test_support/test_case.gd"

# Track F's line of sight, headless: the viewshed (scripts/render/fog_viewshed.gd)
# on synthetic height grids, then on the real seed-20261009 terrain, then
# through FogVision. No pixels (fog_los_shot.gd is the windowed look).
#
#   WALL      a wall blocks what is behind it, and only what is behind it: the
#             sweep agrees with an independent segment-against-rectangle test
#             at random points (a margin around the shadow edge is not judged).
#   PIT       a viewer in a pit sees the pit and its rim, nothing beyond.
#   PLATEAU   a viewer on a plateau sees far low ground but not the dead ground
#             under its cliff; the dead ground ends where the sight line meets
#             the ground (computed by hand from the numbers).
#   TREES     canopy columns block when the switch is on and not when it is
#             off; the eye's own surroundings never block (eye_clear_m).
#   TARGETS   visible_from sees a high target over a wall, not a low one; a
#             plane overhead is seen from a pit though the ground under it is
#             not; it agrees with the ground mask at random points.
#   DETERMINISM  the same grid, eye and range give the same runs.
#   TERRAIN   a tank in a real valley of the seed sees far less than its
#             circle, a plane over the same spot sees nearly all of it, trees
#             take more away, and a viewer at a plateau edge has dead ground.
#   VISION    FogVision with line_of_sight on: per-unit eye heights, sheds
#             cached until a unit moves, ground and unit queries, the mask
#             circles leaving out the units that have a shape.

const Terrain = preload("res://scripts/world/terrain.gd")
const World = preload("res://scripts/sim/world.gd")
const CameraData = preload("res://scripts/world/camera_data.gd")
const FogViewshed = preload("res://scripts/render/fog_viewshed.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const FogSites = preload("res://scripts/render/fog_viewshed_sites.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")

const SEED := 20261009
var _terrain: Terrain
var _valley := Vector2.ZERO
const CELL := 2.0
const GRID := 201                       # cells a side: 402 m
const ORIGIN := Vector2(-201.0, -201.0)

func setup(_main) -> void:
	timeout_seconds = 240.0
	_wall()
	_pit()
	_plateau()
	_trees()
	_targets()
	_determinism()
	_consistency()
	_terrain_sites()
	_vision()
	finish()

# --- helpers -----------------------------------------------------------------------

# A grid whose cell centres take their height from fn(x, y).
static func grid(fn: Callable) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(GRID * GRID)
	for j in GRID:
		for i in GRID:
			a[j * GRID + i] = fn.call(ORIGIN.x + (float(i) + 0.5) * CELL, ORIGIN.y + (float(j) + 0.5) * CELL)
	return a

static func engine(ground: PackedFloat32Array, surface: PackedFloat32Array = PackedFloat32Array(), clear_m: float = 0.0, exact: Callable = Callable()) -> FogViewshed:
	var vs := FogViewshed.new(CELL, 1.0, 1.0, clear_m, CELL, 3.0)   # the rim of something above the eye: one cell
	vs.setup_grid(ground, GRID, GRID, ORIGIN, surface, exact)
	return vs

# Does the segment a-b cross the axis-aligned rectangle?
static func seg_hits_rect(a: Vector2, b: Vector2, r: Rect2) -> bool:
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return false
	var t0 := 0.0
	var t1 := 1.0
	var d := b - a
	for axis in 2:
		var lo: float = r.position[axis]
		var hi: float = r.end[axis]
		if absf(d[axis]) < 1e-12:
			if a[axis] < lo or a[axis] > hi:
				return false
		else:
			var ta: float = (lo - a[axis]) / d[axis]
			var tb: float = (hi - a[axis]) / d[axis]
			t0 = maxf(t0, minf(ta, tb))
			t1 = minf(t1, maxf(ta, tb))
			if t0 > t1:
				return false
	return true

# --- WALL -----------------------------------------------------------------------------

const WALL := Rect2(30.0, -40.0, 6.0, 80.0)   # x 30..36, y -40..40, 10 m high

func _wall() -> void:
	var ground := grid(func(x: float, y: float) -> float: return 10.0 if WALL.has_point(Vector2(x, y)) else 0.0)
	var vs := engine(ground)
	var eye := Vector2.ZERO
	var s := vs.compute(eye, 2.0, 150.0)
	check(vs.ok(), "the viewshed loads: %s" % [vs.errors])
	eq(s.n, ceili(TAU * 150.0 / (CELL * 1.0)), "rays: neighbours at most one cell apart at full range")
	check(s.dtheta * 150.0 <= CELL * 1.0 + 1e-9, "the angular step puts neighbouring rays no more than a cell apart at full range")
	check(s.visible_ground(20.0, 0.0), "ground before the wall is visible")
	check(s.visible_ground(30.0, 0.0), "the wall's near edge (its rim) is visible")
	check(not s.visible_ground(33.0, 0.0), "but not its top, seen from below: the rim is one cell wide")
	check(not s.visible_ground(60.0, 0.0), "ground straight behind the wall is hidden")
	check(not s.visible_ground(50.0, 10.0), "ground behind the wall, off the axis, is hidden")
	check(not s.visible_ground(90.0, 20.0), "ground far behind the wall, inside its shadow, is hidden")
	check(s.visible_ground(0.0, 60.0), "ground to the side of the wall is visible")
	check(s.visible_ground(60.0, 100.0), "ground past the wall's end, outside its shadow, is visible")
	check(s.visible_ground(-100.0, 0.0), "ground behind the viewer is visible")
	check(not s.visible_ground(151.0, 0.0), "past the range nothing is visible")
	check(s.visible_ground(0.0, 0.0), "the eye sees its own ground")
	# Independent check: the segment from the eye to a point either crosses the wall's
	# rectangle (hidden: the wall is 10 m, the eye 2 m, and the ground 0) or not. Points
	# whose verdict changes if the wall is a few metres bigger or smaller are not judged.
	var rng := Mulberry32.new(SEED)
	var judged := 0
	var wrong := 0
	for _i in 4000:
		var p := Vector2((rng.next() * 2.0 - 1.0) * 140.0, (rng.next() * 2.0 - 1.0) * 140.0)
		if p.length() > 148.0 or p.length() < 6.0:
			continue
		if WALL.grow(4.0).has_point(p):
			continue
		var tight := seg_hits_rect(eye, p, WALL.grow(-3.5))
		var loose := seg_hits_rect(eye, p, WALL.grow(3.5))
		if tight != loose:
			continue
		judged += 1
		if s.visible_ground(p.x, p.y) == tight:
			wrong += 1
			if wrong <= 4:
				fail("wall: %s should be %s, the sweep says %s" % [p, "hidden" if tight else "visible", s.visible_ground(p.x, p.y)])
	eq(wrong, 0, "the sweep agrees with the segment-against-wall test at %d random points" % judged)
	check(judged > 1500, "enough random points were judged (%d)" % judged)

# --- PIT ---------------------------------------------------------------------------------

func _pit() -> void:
	var ground := grid(func(x: float, y: float) -> float: return -10.0 if Vector2(x, y).length() < 30.0 else 0.0)
	var vs := engine(ground)
	var s := vs.compute(Vector2.ZERO, 1.7, 160.0)
	var rng := Mulberry32.new(SEED + 1)
	var inside_seen := 0
	var inside := 0
	var beyond_seen := 0
	var beyond := 0
	for _i in 3000:
		var a := rng.next() * TAU
		var d := rng.next() * 150.0
		var p := Vector2(cos(a), sin(a)) * d
		if d < 26.0:
			inside += 1
			inside_seen += 1 if s.visible_ground(p.x, p.y) else 0
		elif d > 38.0:
			beyond += 1
			beyond_seen += 1 if s.visible_ground(p.x, p.y) else 0
	eq(inside_seen, inside, "a viewer in a pit sees all of the pit (%d points)" % inside)
	eq(beyond_seen, 0, "and nothing past its rim (%d points)" % beyond)
	check(s.visible_ground(30.0, 0.0), "the rim itself is in sight")
	check(s.area_m2() < PI * 45.0 * 45.0, "the visible area is the pit and its rim, not the circle (%.0f m2)" % s.area_m2())

# --- PLATEAU ----------------------------------------------------------------------------------

func _plateau() -> void:
	# Plateau 20 m high for x < 0 (cell centres), low ground (0) beyond. The cliff is the
	# cell edge at x = -1. Eye 2 m above the plateau at x = -16, so 15 m from the cliff. By
	# hand: the sight line over the lip has slope (20 - 22) / 15; ground at distance D is in
	# sight where -22 / D >= -2 / 15, i.e. D >= 165.
	var ground := grid(func(x: float, _y: float) -> float: return 20.0 if x < 0.0 else 0.0)
	var vs := engine(ground)
	var eye := Vector2(-16.0, 0.0)
	var s := vs.compute(eye, 2.0, 190.0)
	check(s.visible_ground(-60.0, 40.0), "the plateau is visible")
	check(s.visible_ground(-2.0, 0.0), "up to the lip")
	check(not s.visible_ground(10.0, 0.0), "low ground just under the cliff is dead ground (26 m from the eye)")
	check(not s.visible_ground(60.0, 0.0), "dead ground 76 m from the eye")
	check(not s.visible_ground(100.0, 0.0), "dead ground 116 m from the eye")
	check(not s.visible_ground(140.0, 0.0), "dead ground 156 m from the eye, 9 m short of its far edge")
	check(s.visible_ground(160.0, 0.0), "low ground 176 m from the eye is in sight again")
	check(s.visible_ground(165.0, 20.0), "and so is low ground off to the side at the same range")
	var r0 := s.run_of(0, 0)
	near(r0.x, 0.0, 1e-9, "ray 0: the first run starts at the eye")
	near(r0.y, 15.0, 1e-6, "ray 0: the plateau run ends at the cliff (15 m from the eye)")
	eq(int(s.counts[0]), 2, "ray 0 has two runs: the plateau and the far low ground")
	var r1 := s.run_of(0, 1)
	near(r1.x, 165.0, 1e-3, "ray 0: the low ground comes back into view where the sight line meets it (165 m, by hand)")
	near(r1.y, 190.0, 1e-6, "ray 0: and runs on to the range")
	# The dead ground's far edge is a straight line on flat ground, 181 m out in x: a ray at
	# angle a reaches it at 165 / cos a. On a grid the cliff is found to the cell (the cell
	# edge along each ray), a metre either way, which the far edge magnifies eleven times.
	var worst := 0.0
	var crossing := 0
	for r in s.n:
		var a := float(r) * s.dtheta
		if absf(sin(a)) < 0.2 and cos(a) > 0.0 and int(s.counts[r]) == 2:
			crossing += 1
			worst = maxf(worst, absf(s.run_of(r, 1).x - 165.0 / cos(a)))
	check(crossing > 10, "many rays cross the cliff and come back into view (%d)" % crossing)
	check(worst < 14.0, "the dead ground's far edge follows the sight line on every ray (worst error %.2f m on the cell grid)" % worst)
	_plateau_exact()

# The same plateau with the cliff at x = 0.7, between cell centres, on a grid whose
# cliff cells hold a mixed code and an exact height function (what the terrain gives):
# the far edge is exact, not found to the cell.
func _plateau_exact() -> void:
	var cliff := 0.7
	var ground := grid(func(x: float, _y: float) -> float:
		# the cell [x - 1, x + 1) holds the cliff
		if x - CELL * 0.5 <= cliff and cliff < x + CELL * 0.5:
			return FogViewshed.mixed_code(20.0 if x < cliff else 0.0)
		return 20.0 if x < cliff else 0.0)
	var vs := engine(ground, PackedFloat32Array(), 0.0, func(x: float, _y: float) -> float: return 20.0 if x < cliff else 0.0)
	var s := vs.compute(Vector2(-16.0, 0.0), 2.0, 200.0)
	var want := (22.0 * (cliff + 16.0)) / 2.0     # 183.7 m along the axis
	near(s.run_of(0, 0).y, cliff + 16.0, 0.1, "exact cliffs: the plateau run ends at the cliff, 16.7 m from the eye")
	near(s.run_of(0, 1).x, want, 1.0, "exact cliffs: the dead ground ends at %.1f m by hand" % want)
	var worst := 0.0
	var crossing := 0
	for r in s.n:
		var a := float(r) * s.dtheta
		if absf(sin(a)) < 0.3 and cos(a) > 0.0 and int(s.counts[r]) == 2:
			crossing += 1
			worst = maxf(worst, absf(s.run_of(r, 1).x - want / cos(a)))
	check(crossing > 30, "exact cliffs: many rays cross (%d)" % crossing)
	check(worst < 2.0, "exact cliffs: every ray's dead ground ends where the sight line meets the ground (worst error %.2f m)" % worst)
	# Moving the viewer 0.25 m moves the far edge by 2.75 m, evenly: no jumps of a cell's worth.
	var prev := 0.0
	var worst_jump := 0.0
	var least_jump := INF
	for i in 12:
		var si := vs.compute(Vector2(-16.0 + 0.25 * float(i), 0.0), 2.0, 200.0)
		var edge := si.run_of(0, 1).x
		if i > 0:
			worst_jump = maxf(worst_jump, absf(edge - prev))
			least_jump = minf(least_jump, absf(edge - prev))
		prev = edge
	near(worst_jump, 22.0 * 0.25 / 2.0, 0.6, "exact cliffs: a viewer stepping 0.25 m moves the far edge about 2.75 m a step, never a cell's worth (worst step %.2f)" % worst_jump)
	check(least_jump > 2.0, "exact cliffs: and never stands still (smallest step %.2f)" % least_jump)

# --- TREES ------------------------------------------------------------------------------------

func _trees() -> void:
	var ground := grid(func(_x: float, _y: float) -> float: return 0.0)
	# A grove: canopy columns 8 m high over x 30..40, |y| < 10.
	var surface := grid(func(x: float, y: float) -> float: return 8.0 if (x >= 30.0 and x < 40.0 and absf(y) < 10.0) else 0.0)
	var vs := engine(ground, surface)
	var s_open := vs.compute(Vector2.ZERO, 2.0, 150.0)
	check(s_open.visible_ground(60.0, 0.0), "trees off (line_of_sight terrain): the ground behind the grove is visible")
	vs.canopy = true
	var s_closed := vs.compute(Vector2.ZERO, 2.0, 150.0)
	check(not s_closed.visible_ground(60.0, 0.0), "trees on (terrain_trees): the ground behind the grove is hidden")
	check(s_closed.visible_ground(30.0, 0.0), "trees on: the grove's near edge is visible")
	check(s_closed.visible_ground(0.0, 60.0), "trees on: ground beside the grove is visible")
	check(s_closed.area_m2() < s_open.area_m2(), "trees on: less is seen (%.0f against %.0f m2)" % [s_closed.area_m2(), s_open.area_m2()])
	# A viewer standing in a grove is not inside a solid tree: within eye_clear_m only the
	# ground occludes.
	var around := grid(func(x: float, y: float) -> float: return 8.0 if Vector2(x, y).length() < 10.0 else 0.0)
	var vs_clear := engine(ground, around, 12.0)
	vs_clear.canopy = true
	var sc := vs_clear.compute(Vector2.ZERO, 2.0, 150.0)
	check(sc.visible_ground(60.0, 0.0), "the canopy within eye_clear_m of the eye does not block")
	var vs_blind := engine(ground, around, 0.0)
	vs_blind.canopy = true
	var sb := vs_blind.compute(Vector2.ZERO, 2.0, 150.0)
	check(not sb.visible_ground(60.0, 0.0), "with no clearing the same canopy walls the viewer in")

# --- TARGETS ---------------------------------------------------------------------------------

func _targets() -> void:
	var ground := grid(func(x: float, y: float) -> float: return 10.0 if WALL.has_point(Vector2(x, y)) else 0.0)
	var vs := engine(ground)
	var eye := Vector2.ZERO
	check(not vs.visible_from(eye, 2.0, Vector2(60.0, 0.0), 0.0), "a target on the ground behind the wall is hidden")
	check(not vs.visible_from(eye, 2.0, Vector2(60.0, 0.0), 3.0), "a tank (3 m) behind the wall is hidden")
	check(vs.visible_from(eye, 2.0, Vector2(60.0, 0.0), 40.0), "a plane 40 m up behind the wall is visible over it")
	check(not vs.visible_from(eye, 2.0, Vector2(45.0, 0.0), 10.0), "a target 10 m up close behind the wall is still hidden (slope 0.18 against the wall's 0.25)")
	check(vs.visible_from(eye, 2.0, Vector2(45.0, 0.0), 20.0), "and 20 m up it is visible (slope 0.4)")
	check(vs.visible_from(eye, 2.0, Vector2(20.0, 0.0), 0.0), "ground before the wall is visible")
	check(vs.visible_from(eye, 2.0, Vector2(0.0, 80.0), 0.0), "ground to the side is visible")
	check(vs.visible_from(eye, 2.0, Vector2.ZERO, 0.0), "the same point is visible")
	# A plane overhead is seen from a pit though the ground under it is not.
	var pit := grid(func(x: float, y: float) -> float: return -10.0 if Vector2(x, y).length() < 30.0 else 0.0)
	var vp := engine(pit)
	check(not vp.visible_from(Vector2.ZERO, 1.7, Vector2(70.0, 0.0), 0.0), "from a pit the ground 70 m away is hidden")
	check(not vp.visible_from(Vector2.ZERO, 1.7, Vector2(70.0, 0.0), 3.0), "and a tank there")
	check(vp.visible_from(Vector2.ZERO, 1.7, Vector2(70.0, 0.0), 120.0), "but a plane 120 m up over that spot is seen")
	var sp := vp.compute(Vector2.ZERO, 1.7, 160.0)
	check(not sp.visible_ground(70.0, 0.0), "(the mask has that ground hidden: the plane is judged by visible_from, not the mask)")

# --- DETERMINISM --------------------------------------------------------------------------------

func _noise_ground() -> PackedFloat32Array:
	# Two levels cut from smooth noise: cliffs of every shape.
	var rng := Mulberry32.new(SEED + 7)
	var coarse := PackedFloat64Array()
	var n := 14
	for _i in n * n:
		coarse.append(rng.next())
	return grid(func(x: float, y: float) -> float:
		var u := clampf((x - ORIGIN.x) / (GRID * CELL) * float(n - 1), 0.0, float(n) - 1.001)
		var v := clampf((y - ORIGIN.y) / (GRID * CELL) * float(n - 1), 0.0, float(n) - 1.001)
		var i := int(u)
		var j := int(v)
		var fu := smoothstep(0.0, 1.0, u - float(i))
		var fv := smoothstep(0.0, 1.0, v - float(j))
		var a := lerpf(coarse[j * n + i], coarse[j * n + i + 1], fu)
		var b := lerpf(coarse[(j + 1) * n + i], coarse[(j + 1) * n + i + 1], fu)
		var f := lerpf(a, b, fv)
		return 12.0 if f > 0.6 else (6.0 if f > 0.45 else 0.0))

func _determinism() -> void:
	var g := _noise_ground()
	var a := engine(g).compute(Vector2(-60.0, 30.0), 2.5, 170.0)
	var b := engine(g).compute(Vector2(-60.0, 30.0), 2.5, 170.0)
	check(a.runs == b.runs and a.counts == b.counts, "two engines on the same grid give the same runs")
	var vs := engine(g)
	var c := vs.compute(Vector2(-60.0, 30.0), 2.5, 170.0)
	var d := vs.compute(Vector2(-60.0, 30.0), 2.5, 170.0)
	check(c.runs == d.runs and c.counts == d.counts, "computing again on the same engine gives the same runs")
	check(a.runs == c.runs, "and the same as a fresh engine")
	check(c.serial != d.serial, "each compute has its own serial (a cache key for whoever uploads it)")
	# The same sweep in slices (a frame's budget at a time) gives the same runs.
	var vs2 := engine(g)
	var job := vs2.begin(Vector2(-60.0, 30.0), 2.5, 170.0)
	check(not job.complete, "begin() returns an unfinished shed")
	var slices := 0
	while not vs2.step(job, 0) and slices < 10000:
		slices += 1
	check(job.complete and slices > 5, "a zero budget still marches (eight rays a slice): %d slices" % slices)
	check(job.runs == a.runs and job.counts == a.counts, "swept in slices it gives the same runs as in one go")
	eq(a.overflow, 0, "no ray overflowed its %d runs" % FogViewshed.RUN_MAX)

# --- the sweep against the point query -----------------------------------------------------------

func _consistency() -> void:
	var g := _noise_ground()
	var vs := engine(g)
	var eye := Vector2(-60.0, 30.0)
	var s := vs.compute(eye, 2.5, 170.0)
	var rng := Mulberry32.new(SEED + 3)
	var n := 0
	var differ := 0
	for _i in 3000:
		var a := rng.next() * TAU
		var d := 10.0 + rng.next() * 155.0
		var p := eye + Vector2(cos(a), sin(a)) * d
		if absf(p.x) > 190.0 or absf(p.y) > 190.0:
			continue
		n += 1
		if s.visible_ground(p.x, p.y) != vs.visible_from(eye, 2.5, p, 0.0):
			differ += 1
	check(float(differ) / float(n) < 0.06, "the ground mask and visible_from agree at random points (%d of %d differ)" % [differ, n])
	print("[viewshed] sweep against point query on a noisy cliff field: %d of %d points differ (%.1f%%); %d runs, area %.0f m2 of %.0f" % [
		differ, n, 100.0 * float(differ) / float(n), s.run_count(), s.area_m2(), PI * 170.0 * 170.0])

# --- the real terrain -------------------------------------------------------------------------------

func _terrain_sites() -> void:
	_terrain = Terrain.new(SEED)
	var terrain := _terrain
	if not check(terrain.ok(), "terrain loads: %s" % [terrain.errors]):
		return
	var vs := FogViewshed.new(8.0, 1.0, 1.0, 12.0, 6.0, 3.0)
	vs.attach_terrain(terrain, 0.9, 1000.0)
	check(vs.ok(), "the viewshed attaches to the terrain: %s" % [vs.errors])
	var t0 := Time.get_ticks_usec()
	var site := FogSites.find_valley(terrain)
	print("[viewshed] valley found at %s m (%s) in %.0f ms" % [site.p, site.note, (Time.get_ticks_usec() - t0) / 1000.0])
	_valley = site.p
	check(site.dirs >= 11, "a real valley: higher ground 150-400 m away on %d of 16 sides" % site.dirs)
	eq(terrain.level_at(site.p.x, site.p.y), 0, "the valley floor is low ground")
	var circle := PI * 800.0 * 800.0
	# The tank, terrain only.
	t0 = Time.get_ticks_usec()
	var tank := vs.compute(site.p, 2.5, 800.0)
	var cold_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	var tank2 := vs.compute(site.p, 2.5, 800.0)
	var warm_ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(tank.runs == tank2.runs, "the real terrain gives the same runs twice")
	print("[viewshed] tank in the valley, terrain only, 800 m: cold %.0f ms (fills %d chunks in %.0f ms), warm %.1f ms, %d samples, %d rays, %d runs, area %.0f%% of the circle" % [
		cold_ms, vs.stats.chunks_filled, vs.stats.fill_ms, warm_ms, tank.steps, tank.n, tank.run_count(), 100.0 * tank.area_m2() / circle])
	check(tank.overflow == 0, "no overflow on the real terrain")
	check(tank.area_m2() < 0.5 * circle, "the valley hides more than half of the tank's circle (sees %.0f%%)" % (100.0 * tank.area_m2() / circle))
	check(tank.area_m2() > 0.01 * circle, "but it sees its valley (%.1f%%)" % (100.0 * tank.area_m2() / circle))
	check(tank.visible_ground(site.p.x, site.p.y), "the tank sees its own ground")
	# Ground on higher land a few hundred metres off is out of sight: find a plateau point 250-400 m away.
	var hidden_up := 0
	var tested_up := 0
	for a in 16:
		var ang := float(a) / 16.0 * TAU
		for d in [250.0, 300.0, 350.0]:
			var q: Vector2 = site.p + Vector2(cos(ang), sin(ang)) * d
			if terrain.level_at(q.x, q.y) >= 1 and terrain.level_at(q.x + cos(ang) * 16.0, q.y + sin(ang) * 16.0) >= 1:
				tested_up += 1
				if not tank.visible_ground(q.x, q.y):
					hidden_up += 1
	check(tested_up > 4 and hidden_up >= tested_up - 1, "higher ground 250-350 m off the valley floor is out of the tank's sight (%d of %d points hidden)" % [hidden_up, tested_up])
	# The same spot from a plane at the low band: it flies over the cliffs.
	var plane := vs.compute(site.p, 120.0 - vs.ground_at(site.p.x, site.p.y), 800.0)
	check(plane.area_m2() > 0.8 * circle, "a plane at the low band over the valley sees most of the circle (%.0f%%)" % (100.0 * plane.area_m2() / circle))
	check(vs.visible_from(site.p, 2.5, site.p + Vector2(300.0, 0.0), 120.0 - vs.ground_at(site.p.x + 300.0, site.p.y)), "the tank sees a plane at the low band 300 m off")
	# Trees take more away.
	vs.canopy = true
	t0 = Time.get_ticks_usec()
	var treed := vs.compute(site.p, 2.5, 800.0)
	var trees_cold_ms := (Time.get_ticks_usec() - t0) / 1000.0
	t0 = Time.get_ticks_usec()
	treed = vs.compute(site.p, 2.5, 800.0)
	var trees_warm_ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("[viewshed] same, trees too: cold %.0f ms (%d canopy chunks in %.0f ms), warm %.1f ms, area %.0f%% of the circle" % [
		trees_cold_ms, vs.stats.surface_chunks, vs.stats.surface_ms, trees_warm_ms, 100.0 * treed.area_m2() / circle])
	check(treed.area_m2() < tank.area_m2(), "trees on: the tank sees less (%.0f%% against %.0f%%)" % [100.0 * treed.area_m2() / circle, 100.0 * tank.area_m2() / circle])
	vs.canopy = false
	# A viewer at a plateau edge looking down: dead ground under the cliff.
	var edge := FogSites.find_plateau_edge(terrain)
	print("[viewshed] plateau edge found at %s m, looking along %.0f deg, %s" % [edge.p, rad_to_deg(edge.dir.angle()), edge.note])
	var top := vs.compute(edge.p, 2.5, 800.0)
	var u: Vector2 = edge.dir
	check(top.visible_ground(edge.p.x, edge.p.y), "the viewer sees its own plateau")
	var under: Vector2 = edge.p + u * (edge.cliff_m + 25.0)
	check(terrain.level_at(under.x, under.y) < terrain.level_at(edge.p.x, edge.p.y), "(the point 25 m past the cliff is on lower ground)")
	check(not top.visible_ground(under.x, under.y), "low ground 25 m under the cliff is dead ground")
	var far: Vector2 = edge.p + u * edge.far_m
	check(terrain.level_at(far.x, far.y) == 0, "(the far point is low ground)")
	check(top.visible_ground(far.x, far.y), "low ground %.0f m out is in sight again" % edge.far_m)

# --- FogVision ---------------------------------------------------------------------------------------------

func _vision() -> void:
	if _terrain == null:
		return
	var v := FogVision.new()
	check(v.ok(), "FogVision loads: %s" % [v.errors])
	check(v.line_of_sight == FogVision.LOS_NONE, "line of sight is off in the data (the first option)")
	v.attach_terrain(_terrain)
	var site := _valley
	var tank_agl := float(v.eye_heights["ground"])
	near(tank_agl, 2.5, 0.0, "a ground unit's eye is 2.5 m (data vision.eye_height_m)")
	# A tank at the valley floor (the sim has no tank file yet: circles given directly).
	v.set_circles([{"id": "tank", "x": site.x, "y": site.y, "r": 800.0}])
	var c0: Dictionary = v.circles[0]
	near(c0.eye_agl, tank_agl, 0.0, "a circle given without an eye takes the ground eye height")
	check(not c0.has("shed"), "line of sight none: no shed, a plain circle")
	check(v.mask_circles(2.0, Transform2D.IDENTITY, 0.5).size() == 1 and v.los_circles().is_empty(), "none: the mask gets the circle")
	# A point the cliffs hide from the tank: found with the engine, then asked of FogVision.
	var eng := FogViewshed.new(8.0, 1.0, 1.0, 12.0, 6.0, 3.0)
	eng.attach_terrain(_terrain, 0.9, 1000.0)
	var probe := eng.compute(site, tank_agl, 800.0)
	var hidden := Vector2.INF
	for ring in [350.0, 450.0, 300.0, 550.0]:
		for a in 24:
			var p: Vector2 = site + Vector2.from_angle(float(a) / 24.0 * TAU) * ring
			if hidden == Vector2.INF and not probe.visible_ground(p.x, p.y) and _terrain.level_at(p.x, p.y) >= 1:
				hidden = p
	check(hidden != Vector2.INF, "a point on higher ground the valley hides was found")
	check(v.is_visible(hidden), "none: the hidden point is inside the circle, so it is visible")
	check(v.target_visible(hidden.x, hidden.y, tank_agl), "none: and so is a tank there")
	# Switch the rule on.
	check(v.set_line_of_sight(FogVision.LOS_TERRAIN), "terrain is a valid rule")
	c0 = v.circles[0]
	check(c0.has("shed"), "terrain: the circle has its shed")
	check(not v.is_visible(hidden), "terrain: the point on the far plateau is hidden")
	check(v.is_visible(site), "terrain: the tank's own ground is visible")
	check(not v.target_visible(hidden.x, hidden.y, tank_agl), "terrain: an enemy tank on that plateau is hidden")
	var plane_agl := maxf(120.0 - v.ground_at(hidden.x, hidden.y), 0.0)
	check(v.target_visible(hidden.x, hidden.y, plane_agl), "terrain: a plane at the low band over it is seen though its ground is not")
	check(v.mask_circles(2.0, Transform2D.IDENTITY, 0.5).is_empty(), "terrain: the mask is not given the circle ...")
	eq(v.los_circles().size(), 1, "... it is drawn as a shape")
	# Trees too.
	check(v.set_line_of_sight(FogVision.LOS_TREES), "terrain_trees is a valid rule")
	check(v.engine().canopy, "terrain_trees: the engine's canopy switch is on")
	var shed_t: FogViewshed.Shed = v.circles[0].shed
	var shed_g: FogViewshed.Shed = probe   # terrain only, same eye and range
	check(shed_t.area_m2() < shed_g.area_m2(), "terrain_trees: the shed is smaller than terrain alone (%.0f against %.0f m2)" % [shed_t.area_m2(), shed_g.area_m2()])
	# Back to none: the circle again.
	check(v.set_line_of_sight(FogVision.LOS_NONE), "none again")
	check(not v.circles[0].has("shed") and v.mask_circles(2.0, Transform2D.IDENTITY, 0.5).size() == 1, "none again: a plain circle")

	# Through the World: an aircraft's eye is its band, absolute.
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "me", "type": "light_fighter", "side": "allies", "controller": "player", "x": site.x, "y": site.y, "heading": 0.0})
	w.add_unit({"id": "foe", "type": "light_fighter", "side": "axis", "controller": "ai", "x": hidden.x, "y": hidden.y, "heading": 0.0})
	var vw := FogVision.new()
	vw.attach_terrain(_terrain)
	vw.set_line_of_sight(FogVision.LOS_TERRAIN)
	vw.update_from_world(w)
	var me: Object = w.units["me"]
	var band_h := w.band_height(me.altitude_band)
	var ground := vw.ground_at(site.x, site.y)
	near(vw.circles[0].eye_agl, band_h - ground, 1e-6, "an aircraft's eye is its band height (%.0f m, absolute) above the ground (%.0f m) under it" % [band_h, ground])
	check(vw.circles[0].has("shed"), "the aircraft has a shed")
	check(vw.shows_unit(w, "foe"), "an enemy plane over ground the cliffs hide is shown: it is a target at its own height")
	check(vw.unit_visible(w).call("foe"), "and the hook says so")
	check(vw.shows_unit(w, "me"), "a revealing unit is always shown")
	# The shed is cached until the unit moves.
	var computed: int = vw.stats.computed
	me.x += 3.0
	vw.update_from_world(w)
	eq(vw.stats.computed, computed, "a unit that moved 3 m keeps its shed")
	me.x += 12.0
	vw.update_from_world(w)
	eq(vw.stats.computed, computed + 1, "one that moved 15 m gets a new one")
	me.altitude_band = "low"
	vw.update_from_world(w)
	eq(vw.stats.computed, computed + 2, "and one that changed its altitude band another")
	near(vw.circles[0].eye_agl, w.band_height("low") - vw.ground_at(me.x, me.y), 1e-6, "(the low band's height)")
	# Slicing: with a budget a moving unit keeps its old shed drawn while the new one is swept.
	var va := FogVision.new()
	va.attach_terrain(_terrain)
	va.set_line_of_sight(FogVision.LOS_TERRAIN)
	va.budget_ms = 0.2
	w.units["me"].altitude_band = "medium"
	w.units["me"].x = site.x
	w.units["me"].y = site.y
	va.update_from_world(w)
	var first: FogViewshed.Shed = va.circles[0].shed
	check(first.complete, "a unit with no shed yet gets one whole, whatever the budget")
	w.units["me"].x = site.x + 60.0
	va.update_from_world(w)
	var passes := 1
	check(va.stats.pending == 1 and va.circles[0].shed == first, "a unit that moved 60 m keeps its old shed while the new one is swept")
	while va.stats.pending > 0 and passes < 5000:
		va.update_from_world(w)
		passes += 1
	var second: FogViewshed.Shed = va.circles[0].shed
	check(second != first and second.complete and second.eye.distance_to(Vector2(site.x + 60.0, site.y)) < 1e-6, "and then the new one replaces it (after %d updates)" % passes)
	check(passes > 2, "which took several frames' budgets")
	print("[viewshed] FogVision: aircraft eye %.0f m above ground at band 'medium'; shed cache: %d computed, %d reused, %.1f ms the last" % [
		band_h - ground, vw.stats.computed, vw.stats.reused, vw.stats.last_ms])
