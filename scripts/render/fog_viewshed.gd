extends RefCounted

# THE VIEWSHED (Track F, line of sight; Alex 2026-10-09: "terrain, trees and
# buildings block sight", and "what it looks like when something occludes the
# line of sight. Ex - a tank's view inside a valley"). From an eye point, which
# ground can be seen. Pure -- no nodes, no drawing -- so the vision rule, the
# fog layer and the tests all ask it. Metres throughout (the sim's unit).
#
#   var vs := FogViewshed.new(cell_m, step_cells, spacing_cells, eye_clear_m, rim_m)
#   vs.attach_terrain(terrain, canopy_radius_scale, margin_m)   # or setup_grid(...) for a test
#   vs.canopy = true                                            # trees block too ("terrain_trees")
#   var shed := vs.compute(Vector2(x_m, y_m), eye_agl_m, range_m)
#   shed.visible_ground(x_m, y_m)                  # is that GROUND in sight?
#   vs.visible_from(eye, eye_agl_m, point, target_agl_m)   # can this eye see a TARGET up there?
#
# HEIGHTS. Every height is metres above SEA LEVEL inside; the public calls take
# heights ABOVE THE GROUND at the point (a tank's eye 2.5 m, a target 2.5 m).
# An aircraft's altitude is absolute (data/sim/altitude.json), so its caller
# passes band_height - ground_at(x, y) as the height above the ground.
#
# THE OCCLUDERS. A grid of cell_m cells (the terrain's own 8 m grid), one
# height per cell:
#   ground    the height of the terrain level (three levels, every step a cliff)
#   surface   ground, raised under every tree canopy to base + canopy height
#             (the tree's h in px / px_per_m), over the cells whose centres lie
#             within the canopy radius (r / px_per_m x canopy_radius_scale), and
#             always the cell the trunk stands in. A canopy is an OPAQUE COLUMN
#             from the ground up. `canopy` picks which array occludes. Within
#             eye_clear_m of the eye only the ground occludes (a viewer standing
#             in a grove is not inside a solid tree).
# The grid is a lazily filled cache of the whole map (plus a margin), filled a
# chunk at a time the first time a sweep reaches it; every unit shares it.
# EXACT CLIFFS. A cell that a level boundary crosses (the terrain's "mixed"
# cells) holds a code, MIXED_BASE minus its centre height, instead of a height:
# the sweep asks the terrain for the height at the exact point, and where a
# ray's samples straddle a step it bisects Terrain.level_at for the cliff to a
# quarter of a metre. Everywhere else a cell is one height. The sight line over a
# cliff lip is tilted by where the lip really is, and for a low eye that
# magnifies the lip's position: a 2.5 m eye 28 m back from a 12 m cliff has its
# dead ground end (12 + 2.5) / 2.5 = 5.8 times as far out as the lip, so a lip
# found to the cell (8 m) would put the far edge out by 47 m, and the shape would
# jump that far as a viewer moved a metre. With exact lips it moves smoothly.
# The magnification is eye / (eye - lip height), so an eye more than
# exact_below_factor times the tallest ground (an aircraft) skips the exact
# lookups and takes the cell as one block. A given grid (tests) may pass its own
# exact(x, y) for the same effect.
#
# THE SWEEP (compute). A radial sweep: rays at an angular step small enough that
# neighbouring rays are at most spacing_cells apart at full range (TAU x range /
# (cell x spacing) rays). Each ray is marched outward one step_cells at a time as
# a PROFILE OF FLAT SEGMENTS (the height changes only at steps), keeping the
# STEEPEST SLOPE SO FAR from the eye, M. A flat segment below the eye rises in
# slope with distance, so it comes into view where its slope reaches M (or at its
# start, if it already does), and is visible from there to its end; a segment
# level with the eye is visible when M <= 0; a segment above the eye falls in
# slope with distance, so only its near edge is seen -- a rim rim_m wide. The ray
# keeps the visible runs [from, to] in metres, so ground comes back into view:
# from a plateau the low ground right under the cliff is DEAD GROUND (hidden)
# while low ground further out is visible. Equal slopes are visible ("at least
# that maximum"), so flat ground at the eye's height is all seen.
#
# THE SHAPE. A Shed holds the runs of all rays in the layout of a texture
# (RUN_ROWS rows of rays, RGBAF, two runs per texel) so the fog mask can draw
# it on the GPU straight from the array (fog_los_shape.gdshader). A point's
# ground is visible when the ray nearest its bearing has a run holding its
# distance: the same rule the GPU uses, so the mask and the query agree.
#
# visible_from marches ONE segment with the same profile and the same
# occluders: the target is seen when the slope to its top is at least M over
# everything between. A plane overhead is visible from a valley even when the
# ground under it is not.
#
# DETERMINISTIC: no randomness; the same grid, eye and range give the same runs.

const RUN_MAX := 6        # visible runs kept per ray; more are counted in overflow
const RUN_ROWS := 3       # RUN_MAX / 2 texels per ray
const EPS := 1.0e-4       # metres of slack in "slope at least the maximum"
const TINY := 1.0e-6
const NEG := -1.0e9
const MIXED_BASE := -10000.0    # a cell a level boundary crosses holds MIXED_BASE - its centre height
const MIXED_BELOW := -5000.0

static var _serial_counter := 0

var cell_m: float
var step_cells: float
var spacing_cells: float
var eye_clear_m: float
var rim_m: float
var exact_below_factor: float
var canopy := false             # trees occlude too
var errors: Array[String] = []

var gw := 0                     # grid size in cells
var gh := 0
var ox := 0.0                   # metres of the grid's left / top edge
var oy := 0.0
var ground := PackedFloat32Array()    # [row * gw + col], metres above sea level, or a mixed_code
var surface := PackedFloat32Array()   # ground plus canopy columns

var stats := {"computes": 0, "last_ms": 0.0, "last_steps": 0, "chunks_filled": 0, "fill_ms": 0.0,
	"surface_chunks": 0, "surface_ms": 0.0, "bisects": 0, "exacts": 0}

# --- the terrain-backed source ---
var terrain: Object = null
var _canopy_scale := 0.9
var _cpc := 0                   # cells per chunk side
var _cx0 := 0                   # first chunk column / row of the grid
var _cy0 := 0
var _ncx := 0
var _ncy := 0
var _g_done := PackedByteArray()
var _s_done := PackedByteArray()
var _ppm_filled := 0.0
var _exact_fn := Callable()     # (x, y) -> exact ground height; invalid: the grid is exact

# --- the ray being marched (set by _march, read by _seg) ---
var _m := NEG
var _eye_abs := 0.0
var _out := PackedFloat64Array()
var _exact_on := false
var _hmax_ground := 0.0         # the tallest ground anywhere in the grid
var _hmax_surface := 0.0        # the tallest canopy top (or ground) anywhere in what has been filled

# One viewshed result. Distances are metres from `eye`.
class Shed:
	var eye := Vector2.ZERO
	var eye_agl := 0.0            # the eye above the ground under it
	var eye_abs := 0.0            # the eye above sea level
	var range_m := 0.0
	var n := 0                    # rays
	var dtheta := 0.0             # radians between rays; ray r points at r x dtheta
	var runs := PackedFloat32Array()      # RUN_ROWS x n x 4: (from0, to0, from1, to1) per texel
	var counts := PackedByteArray()       # runs per ray
	var overflow := 0             # visible runs dropped because a ray had more than RUN_MAX
	var serial := 0               # unique per compute: a cache key for whoever uploads it
	var compute_ms := 0.0
	var steps := 0                # samples taken
	var complete := true          # false while begin() / step() are still sweeping it
	var next_ray := 0             # the next ray step() will march

	# Is the ground at (x, y) in sight? The ray nearest its bearing decides.
	func visible_ground(x: float, y: float) -> bool:
		var dx := x - eye.x
		var dy := y - eye.y
		var d := sqrt(dx * dx + dy * dy)
		if d > range_m:
			return false
		if n == 0:
			return d == 0.0
		var a := atan2(dy, dx)
		if a < 0.0:
			a += TAU
		var r := int(a / dtheta + 0.5)
		if r >= n:
			r -= n
		return in_runs(r, d)

	func in_runs(r: int, d: float) -> bool:
		for i in int(counts[r]):
			var base := ((i >> 1) * n + r) * 4 + (i & 1) * 2
			if d >= runs[base] and d < runs[base + 1]:
				return true
		return false

	# Run i of ray r as Vector2(from, to) metres.
	func run_of(r: int, i: int) -> Vector2:
		var base := ((i >> 1) * n + r) * 4 + (i & 1) * 2
		return Vector2(runs[base], runs[base + 1])

	# The area in sight, square metres (sector areas, summed).
	func area_m2() -> float:
		var a := 0.0
		for r in n:
			for i in int(counts[r]):
				var base := ((i >> 1) * n + r) * 4 + (i & 1) * 2
				var f: float = runs[base]
				var t: float = runs[base + 1]
				a += 0.5 * (t * t - f * f) * dtheta
		return a

	# The farthest visible distance along ray r (0 when nothing).
	func reach_of(r: int) -> float:
		var c := int(counts[r])
		if c == 0:
			return 0.0
		return run_of(r, c - 1).y

	# The runs as the bytes of an RGBAF image n wide and RUN_ROWS high.
	func texture_bytes() -> PackedByteArray:
		return runs.to_byte_array()

	func run_count() -> int:
		var c := 0
		for r in n:
			c += int(counts[r])
		return c

func _init(cell: float, step: float, spacing: float, clear_m: float, rim: float, exact_below: float) -> void:
	cell_m = cell
	step_cells = step
	spacing_cells = spacing
	eye_clear_m = clear_m
	rim_m = rim
	exact_below_factor = exact_below
	if not (cell_m > 0.0 and step_cells > 0.0 and spacing_cells > 0.0 and eye_clear_m >= 0.0 and rim_m >= 0.0 and exact_below_factor >= 0.0):
		_err("FogViewshed needs cell_m, step_cells and spacing_cells above 0 and eye_clear_m, rim_m, exact_below_factor at least 0 (got %s, %s, %s, %s, %s, %s)" % [cell, step, spacing, clear_m, rim, exact_below])

# The grid value for a cliff cell whose centre is `centre_h` high.
static func mixed_code(centre_h: float) -> float:
	return MIXED_BASE - centre_h

func ok() -> bool:
	return errors.is_empty()

func _err(message: String) -> void:
	errors.append(message)
	push_error("FogViewshed: " + message)

# --- the occluder grid -------------------------------------------------------------

# A given grid (tests, other height sources): heights[row * w + col] for the cell
# whose top-left corner is origin + (col, row) x cell_m, and optionally the
# canopy-raised surface in the same layout. All of it counts as filled. A cell
# holding mixed_code(centre height) is resolved by `exact` (x, y metres -> height)
# when given (and the eye is low enough to want it), else is its centre height.
func setup_grid(heights: PackedFloat32Array, w: int, h: int, origin: Vector2, canopy_heights: PackedFloat32Array = PackedFloat32Array(), exact: Callable = Callable()) -> void:
	terrain = null
	_cpc = 0
	gw = w
	gh = h
	ox = origin.x
	oy = origin.y
	_exact_fn = exact
	if heights.size() != w * h:
		_err("setup_grid: %d heights for a %d x %d grid" % [heights.size(), w, h])
		return
	ground = heights
	surface = canopy_heights if canopy_heights.size() == w * h else heights
	_hmax_ground = _array_max(ground)
	_hmax_surface = _array_max(surface)

# The terrain as the height source: ground from Terrain.level_at, canopy from
# its tree lists, over the map plus margin_m on every side, filled on demand.
func attach_terrain(t: Object, canopy_radius_scale: float, margin_m: float) -> void:
	terrain = t
	_canopy_scale = canopy_radius_scale
	var chunk_m: float = t.chunk_m
	_cpc = roundi(chunk_m / cell_m)
	if not (_cpc > 0 and float(_cpc) * cell_m == chunk_m):
		_err("viewshed.cell_m (%s) must divide the terrain's chunk size (%s) into whole cells" % [cell_m, chunk_m])
		_cpc = 0
		return
	_cx0 = floori((t.map_x - margin_m) / chunk_m)
	_cy0 = floori((t.map_y - margin_m) / chunk_m)
	_ncx = floori((t.map_x + t.map_w + margin_m) / chunk_m) - _cx0 + 1
	_ncy = floori((t.map_y + t.map_h + margin_m) / chunk_m) - _cy0 + 1
	ox = float(_cx0) * chunk_m
	oy = float(_cy0) * chunk_m
	gw = _ncx * _cpc
	gh = _ncy * _cpc
	ground = PackedFloat32Array()
	ground.resize(gw * gh)
	surface = PackedFloat32Array()
	surface.resize(gw * gh)
	_g_done = PackedByteArray()
	_g_done.resize(_ncx * _ncy)
	_s_done = PackedByteArray()
	_s_done.resize(_ncx * _ncy)
	_ppm_filled = t.px_per_m
	_exact_fn = Callable(self, "_terrain_height")
	_hmax_ground = 0.0
	for hm: float in t.heights_m:
		_hmax_ground = maxf(_hmax_ground, hm)
	_hmax_surface = _hmax_ground

func _inside(p: Vector2) -> bool:
	return p.x >= ox and p.y >= oy and p.x < ox + float(gw) * cell_m and p.y < oy + float(gh) * cell_m

static func _array_max(a: PackedFloat32Array) -> float:
	var m := 0.0
	for v in a:
		if v > m:
			m = v
	return m

func has_terrain() -> bool:
	return terrain != null and _cpc > 0

func _terrain_height(x: float, y: float) -> float:
	return terrain.heights_m[terrain.level_at(x, y)]

# The exact ground height at (x, y), for a cell the grid marks as a cliff.
func _exact(x: float, y: float) -> float:
	stats.exacts += 1
	if terrain != null:
		return terrain.heights_m[terrain.level_at(x, y)]
	if _exact_fn.is_valid():
		return _exact_fn.call(x, y)
	return 0.0

# The array that occludes with the current switch.
func occluder() -> PackedFloat32Array:
	return surface if canopy else ground

# Ground height above sea level at (x, y), metres (0 outside the grid).
func ground_at(x: float, y: float) -> float:
	var i := floori((x - ox) / cell_m)
	var j := floori((y - oy) / cell_m)
	if i < 0 or j < 0 or i >= gw or j >= gh:
		return 0.0
	if terrain != null:
		_ensure_ground_cell(i, j)
	var v := ground[j * gw + i]
	if v < MIXED_BELOW:
		return _exact(x, y) if (terrain != null or _exact_fn.is_valid()) else MIXED_BASE - v
	return v

# Fill whatever the current switch needs for the metres rectangle.
@warning_ignore("integer_division")
func ensure_rect(r: Rect2) -> void:
	if terrain == null or _cpc == 0:
		return
	var i0 := clampi(floori((r.position.x - ox) / cell_m), 0, gw - 1)
	var j0 := clampi(floori((r.position.y - oy) / cell_m), 0, gh - 1)
	var i1 := clampi(floori((r.end.x - ox) / cell_m), 0, gw - 1)
	var j1 := clampi(floori((r.end.y - oy) / cell_m), 0, gh - 1)
	if terrain.px_per_m != _ppm_filled:
		# The tree layout depends on the scale; the canopy cache is stale.
		_s_done.fill(0)
		_ppm_filled = terrain.px_per_m
	for cj in range(j0 / _cpc, j1 / _cpc + 1):
		for ci in range(i0 / _cpc, i1 / _cpc + 1):
			if _g_done[cj * _ncx + ci] == 0:
				_fill_ground(ci, cj)
			if canopy and _s_done[cj * _ncx + ci] == 0:
				_fill_surface(ci, cj)

@warning_ignore("integer_division")
func _ensure_ground_cell(i: int, j: int) -> void:
	var k := (j / _cpc) * _ncx + i / _cpc
	if _g_done[k] == 0:
		_fill_ground(i / _cpc, j / _cpc)

# Ground for grid chunk (ci, cj): the level's height at every cell centre, as a
# mixed_code where a level boundary crosses the cell.
func _fill_ground(ci: int, cj: int) -> void:
	var t0 := Time.get_ticks_usec()
	var cx := _cx0 + ci
	var cy := _cy0 + cj
	var i0 := ci * _cpc
	var j0 := cj * _cpc
	if terrain.chunk_in_map(cx, cy):
		var heights: PackedFloat64Array = terrain.heights_m
		var geo: Dictionary = terrain.chunk(cx, cy)
		var tc: float = terrain.cell_m
		var tn: int = terrain.cells
		var gx0: float = geo.x0
		var gy0: float = geo.y0
		var mixed: Array = []
		for L: Dictionary in geo.levels:
			mixed.append(L.mixed)
		for j in _cpc:
			var ya := oy + float(j0 + j) * cell_m
			var base := (j0 + j) * gw + i0
			var tj0 := clampi(floori((ya - gy0) / tc), 0, tn - 1)
			var tj1 := clampi(floori((ya + cell_m - 1.0e-9 - gy0) / tc), 0, tn - 1)
			for i in _cpc:
				var xa := ox + float(i0 + i) * cell_m
				var ti0 := clampi(floori((xa - gx0) / tc), 0, tn - 1)
				var ti1 := clampi(floori((xa + cell_m - 1.0e-9 - gx0) / tc), 0, tn - 1)
				var crossed := false
				for m: PackedByteArray in mixed:
					for tj in range(tj0, tj1 + 1):
						for ti in range(ti0, ti1 + 1):
							if m[tj * tn + ti] != 0:
								crossed = true
				var centre: float = heights[terrain.level_at(xa + cell_m * 0.5, ya + cell_m * 0.5)]
				ground[base + i] = MIXED_BASE - centre if crossed else centre
	_g_done[cj * _ncx + ci] = 1
	stats.chunks_filled += 1
	stats.fill_ms += (Time.get_ticks_usec() - t0) / 1000.0

# Surface for grid chunk (ci, cj): the ground, raised under the canopies of the
# trees of this chunk and its eight neighbours that reach into it. A cell that
# is both crossed by a boundary and under a canopy takes the canopy top.
func _fill_surface(ci: int, cj: int) -> void:
	var t0 := Time.get_ticks_usec()
	if _g_done[cj * _ncx + ci] == 0:
		_fill_ground(ci, cj)
	var cx := _cx0 + ci
	var cy := _cy0 + cj
	var i0 := ci * _cpc
	var j0 := cj * _cpc
	for j in _cpc:
		var base := (j0 + j) * gw + i0
		for i in _cpc:
			surface[base + i] = ground[base + i]
	if terrain.chunk_in_map(cx, cy):
		var ppm: float = terrain.px_per_m
		var x_lo := ox + float(i0) * cell_m
		var y_lo := oy + float(j0) * cell_m
		var x_hi := x_lo + float(_cpc) * cell_m
		var y_hi := y_lo + float(_cpc) * cell_m
		for ny in range(cy - 1, cy + 2):
			for nx in range(cx - 1, cx + 2):
				if not terrain.chunk_in_map(nx, ny):
					continue
				for tr: Dictionary in terrain.trees_in_chunk(nx, ny):
					var tx: float = float(tr.x) / ppm
					var ty: float = float(tr.y) / ppm
					var rr: float = float(tr.r) / ppm * _canopy_scale
					if tx + rr < x_lo or tx - rr >= x_hi or ty + rr < y_lo or ty - rr >= y_hi:
						continue
					var top: float = float(tr.base_m) + float(tr.h) / ppm
					var ia := maxi(i0, floori((tx - rr - ox) / cell_m))
					var ib := mini(i0 + _cpc - 1, floori((tx + rr - ox) / cell_m))
					var ja := maxi(j0, floori((ty - rr - oy) / cell_m))
					var jb := mini(j0 + _cpc - 1, floori((ty + rr - oy) / cell_m))
					var rr2 := rr * rr
					var ti := floori((tx - ox) / cell_m)
					var tj := floori((ty - oy) / cell_m)
					for j in range(ja, jb + 1):
						var cyc := oy + (float(j) + 0.5) * cell_m - ty
						for i in range(ia, ib + 1):
							var cxc := ox + (float(i) + 0.5) * cell_m - tx
							if (cxc * cxc + cyc * cyc <= rr2 or (i == ti and j == tj)) and top > surface[j * gw + i]:
								surface[j * gw + i] = top
								if top > _hmax_surface:
									_hmax_surface = top
	_s_done[cj * _ncx + ci] = 1
	stats.surface_chunks += 1
	stats.surface_ms += (Time.get_ticks_usec() - t0) / 1000.0

# --- the ray ----------------------------------------------------------------------------

# Rays for a range: neighbours at most spacing_cells apart at full range.
func ray_count_for(range_m: float) -> int:
	return maxi(8, ceili(TAU * range_m / (cell_m * spacing_cells)))

# Appends the visible part of the flat segment [a, b] metres at height h to the
# ray's runs and raises the steepest slope. See the header.
func _seg(a: float, b: float, h: float) -> void:
	if b <= a:
		return
	var dh := h - _eye_abs
	if dh < -TINY:
		var from: float
		if _m < NEG * 0.5:
			from = a
		elif _m >= 0.0:
			return
		else:
			from = dh / _m
		if from >= b:
			return
		_emit(maxf(a, from), b)
		_m = dh / b
	elif dh <= TINY:
		if _m <= TINY:
			_emit(a, b)
			if _m < 0.0:
				_m = 0.0
	else:
		var near := maxf(a, TINY)
		var sl := dh / near
		if sl >= _m - EPS / near:
			_emit(a, minf(b, a + rim_m))
			if sl > _m:
				_m = sl

func _emit(lo: float, hi: float) -> void:
	if hi <= lo:
		return
	var k := _out.size()
	if k >= 2 and lo <= _out[k - 1] + 1.0e-9:
		_out[k - 1] = maxf(_out[k - 1], hi)
		return
	_out.append(lo)
	_out.append(hi)

# The cliff between two samples on a ray: where the exact ground height crosses
# the middle of the two heights, between distances d0 and d1.
func _find_edge(eye: Vector2, ux: float, uy: float, d0: float, d1: float, g0: float, g1: float) -> float:
	var thr := (g0 + g1) * 0.5
	var low_side := g0 > thr
	var lo := d0
	var hi := d1
	for _i in 5:
		var mid := (lo + hi) * 0.5
		if (_exact(eye.x + ux * mid, eye.y + uy * mid) > thr) == low_side:
			lo = mid
		else:
			hi = mid
	stats.bisects += 1
	return (lo + hi) * 0.5

# Marches one ray from `eye` along (ux, uy) out to d_max metres; the visible runs
# end up in _out and the steepest slope in _m. Samples every step_cells.
func _march(eye: Vector2, ux: float, uy: float, d_max: float, kclear: int) -> int:
	var step_m := cell_m * step_cells
	var half_step := 0.5 * step_m
	var egx := (eye.x - ox) / cell_m
	var egy := (eye.y - oy) / cell_m
	var dgx := ux * step_cells
	var dgy := uy * step_cells
	var nsteps := int(floorf(d_max / step_m + 1.0e-9))
	var kmax := nsteps
	var fw := float(gw) - 1.0e-6
	var fh := float(gh) - 1.0e-6
	if dgx > 1.0e-12:
		kmax = mini(kmax, int((fw - egx) / dgx))
	elif dgx < -1.0e-12:
		kmax = mini(kmax, int(egx / -dgx))
	if dgy > 1.0e-12:
		kmax = mini(kmax, int((fh - egy) / dgy))
	elif dgy < -1.0e-12:
		kmax = mini(kmax, int(egy / -dgy))
	_m = NEG
	_out.resize(0)
	var gnd := ground
	var occ := occluder()
	var arr := gnd
	var exact := _exact_on
	var hs: float = gnd[int(egy) * gw + int(egx)]
	if hs < MIXED_BELOW:
		hs = _exact(eye.x, eye.y) if exact else MIXED_BASE - hs
	var seg_a := 0.0
	var gx := egx
	var gy := egy
	# Nothing beyond distance e can be seen when even the tallest thing in the world
	# there would sit below the steepest slope so far: (hmax - eye) < M x e.
	var rise := (_hmax_surface if canopy else _hmax_ground) - _eye_abs
	var steps := kmax
	for k in range(1, kmax + 1):
		if k == kclear + 1:
			arr = occ
		gx += dgx
		gy += dgy
		var idx := int(gy) * gw + int(gx)
		var h: float = arr[idx]
		if h == hs:
			continue
		var dk := float(k) * step_m
		if h < MIXED_BELOW:
			h = _exact(eye.x + ux * dk, eye.y + uy * dk) if exact else MIXED_BASE - h
			if h == hs:
				continue
		# A step between sample k-1 and sample k. Where the terrain made it, find the
		# cliff; a canopy edge is the cell edge.
		var e := dk - half_step
		if exact:
			var pidx := int(gy - dgy) * gw + int(gx - dgx)
			var gp: float = gnd[pidx]
			var gc: float = gnd[idx]
			if gp < MIXED_BELOW or gc < MIXED_BELOW or gp != gc:
				if k <= kclear or not canopy:
					gp = hs
					gc = h
				else:
					gp = _exact(eye.x + ux * (dk - step_m), eye.y + uy * (dk - step_m))
					gc = _exact(eye.x + ux * dk, eye.y + uy * dk)
				if absf(gp - gc) > 0.25:
					e = _find_edge(eye, ux, uy, dk - step_m, dk, gp, gc)
		_seg(seg_a, e, hs)
		seg_a = e
		hs = h
		if rise > 0.0 and rise < _m * e - EPS:
			steps = k
			break
	var b := d_max
	if kmax < nsteps:
		b = minf(d_max, float(kmax) * step_m + half_step)
	_seg(seg_a, b, hs)
	return steps

# --- the viewshed -----------------------------------------------------------------

# Which ground is visible from `eye` (metres), the eye `eye_agl_m` above the
# ground under it, out to `range_m`. Returns a Shed.
func compute(eye: Vector2, eye_agl_m: float, range_m: float) -> Shed:
	var s := begin(eye, eye_agl_m, range_m)
	step(s, 1 << 60)
	return s

# The same sweep in slices, so a frame can spend a budget on it and go on: begin()
# fills the grid the range needs (the slow part when cold) and returns an
# incomplete Shed; step(shed, budget_us) marches rays until the budget is spent
# and returns whether the shed is complete. Slices may be interleaved with other
# computes and point queries (each step sets what it needs); a shed is only to be
# read once `complete`.
func begin(eye: Vector2, eye_agl_m: float, range_m: float) -> Shed:
	_serial_counter += 1
	var s := Shed.new()
	s.serial = _serial_counter
	s.eye = eye
	s.eye_agl = eye_agl_m
	s.range_m = range_m
	var n := ray_count_for(range_m)
	s.n = n
	s.dtheta = TAU / float(n)
	var runs := PackedFloat32Array()
	runs.resize(RUN_ROWS * n * 4)
	var counts := PackedByteArray()
	counts.resize(n)
	s.runs = runs
	s.counts = counts
	if gw == 0 or not errors.is_empty() or not _inside(eye):
		s.next_ray = n
		return s
	ensure_rect(Rect2(eye - Vector2(range_m, range_m), Vector2(range_m, range_m) * 2.0))
	s.eye_abs = ground_at(eye.x, eye.y) + eye_agl_m
	s.complete = false
	return s

func step(s: Shed, budget_us: int) -> bool:
	if s.complete:
		return true
	var t0 := Time.get_ticks_usec()
	_eye_abs = s.eye_abs
	_exact_on = (terrain != null or _exact_fn.is_valid()) and _eye_abs < exact_below_factor * _hmax_ground
	var kclear := int(floorf(eye_clear_m / (cell_m * step_cells)))
	var n := s.n
	var runs := s.runs
	var counts := s.counts
	var eye := s.eye
	var overflow := 0
	var steps := 0
	var r := s.next_ray
	while r < n:
		var th := float(r) * s.dtheta
		steps += _march(eye, cos(th), sin(th), s.range_m, kclear)
		var pairs := _out.size() >> 1
		var cnt := mini(pairs, RUN_MAX)
		overflow += pairs - cnt
		for i in cnt:
			var base := ((i >> 1) * n + r) * 4 + (i & 1) * 2
			runs[base] = _out[i * 2]
			runs[base + 1] = _out[i * 2 + 1]
		counts[r] = cnt
		r += 1
		if (r & 7) == 0 and Time.get_ticks_usec() - t0 > budget_us:
			break
	s.runs = runs
	s.counts = counts
	s.next_ray = r
	s.overflow += overflow
	s.steps += steps
	s.compute_ms += (Time.get_ticks_usec() - t0) / 1000.0
	if r >= n:
		s.complete = true
		stats.computes += 1
		stats.last_ms = s.compute_ms
		stats.last_steps = s.steps
	return s.complete

# --- the point query ----------------------------------------------------------------------

# Can an eye `eye_agl_m` above the ground at `eye` see a target `target_agl_m`
# above the ground at `point`? The profile and the occluders are the sweep's. A
# target at the eye is seen.
func visible_from(eye: Vector2, eye_agl_m: float, point: Vector2, target_agl_m: float) -> bool:
	var d := eye.distance_to(point)
	if gw == 0 or d <= 0.0 or not errors.is_empty():
		return true
	if not (_inside(eye) and _inside(point)):
		return true
	ensure_rect(Rect2(eye, Vector2.ZERO).expand(point).grow(cell_m))
	_eye_abs = ground_at(eye.x, eye.y) + eye_agl_m
	_exact_on = (terrain != null or _exact_fn.is_valid()) and _eye_abs < exact_below_factor * _hmax_ground
	var tgt_abs := ground_at(point.x, point.y) + target_agl_m
	var kclear := int(floorf(eye_clear_m / (cell_m * step_cells)))
	_march(eye, (point.x - eye.x) / d, (point.y - eye.y) / d, d, kclear)
	return tgt_abs - _eye_abs >= _m * d - EPS

# Does ground at `point` show from `eye` (the target is the ground itself)?
func ground_visible_from(eye: Vector2, eye_agl_m: float, point: Vector2) -> bool:
	return visible_from(eye, eye_agl_m, point, 0.0)
