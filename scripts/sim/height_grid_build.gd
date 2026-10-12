extends RefCounted

# MAKES ONE CHUNK OF THE HEIGHT GRID (builder LOF1, stage 1 of the lines of fire, 2026-10-11). A function of the seed's terrain, its
# water, its village and the data (data/sim/line_of_fire.json) alone: the same chunk on every peer, in any order.
#
#   var b := HeightGridBuild.new(grid, cx, cy)       # grid: scripts/sim/height_grid.gd (terrain, water, rules, cell sizes)
#   var chunk := b.run()                             # scripts/sim/height_chunk.gd
#
# THE LAYERS, in the order they are written (a later one only ever RAISES a cell):
#   1. the terrain: each cell's level height (0, 12, 24 m, data/terrain/terrain.json). A terrain lattice cell (8 m) whose corners
#      agree is filled whole; only the cells a boundary runs through ask Terrain.level_at cell by cell, so the grid follows the
#      drawn, smoothed boundary exactly and costs time where the boundaries are.
#   2. the water: material WATER at height 0, where the sim's own query (WaterGen.depth_at) says a boat could float. The sea's
#      field is smooth, so a lattice cell far from a shore is taken whole (data water.margin_m); a cell near a shore, and every
#      cell near the river, is asked one by one.
#   3. the village's houses (timber) and walls (stone): the structures' own geometry (scripts/world/structures.gd, in map px) over
#      the scale, at the structure's own `h` over the scale -- so the scenery-heights board's pick flows in -- on the ground they
#      stand on.
# TREES ARE NOT CELLS: they are canopies, kept by the grid (height_grid.gd). THE STAMP LAYER (a static unit's sandbag ring, the
# bridge's deck) is the grid's too.
#
# A chunk with one terrain level, one water state and no structure keeps no arrays at all (height_chunk.gd, `uniform`).

const Chunk = preload("res://scripts/sim/height_chunk.gd")
const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")

var _g: Object
var _cx: int
var _cy: int
var _t: Object
var _water: Object
var _rules: Rules
var _c: float            # grid cell, metres
var _n: int              # cells per chunk side
var _nb: int             # blocks per chunk side
var _bc: int             # cells per block side
var _chunk_m: float
var _x0: float
var _y0: float
var _ppm: float
var _ch: Chunk
var _h := PackedFloat32Array()      # the arrays are the builder's own while it works (a write to them is a write), given to the chunk at the end
var _m := PackedByteArray()
var _bmax := PackedFloat32Array()
var _gnd: Dictionary = {}    # cell index -> the ground height it had before a structure first raised it

func _init(grid: Object, cx: int, cy: int) -> void:
	_g = grid
	_cx = cx
	_cy = cy
	_t = grid.terrain
	_water = grid.water
	_rules = grid.rules
	_c = grid.cell_m
	_n = grid.n
	_nb = grid.nb
	_bc = grid.block_cells
	_chunk_m = grid.chunk_m
	_x0 = float(cx) * _chunk_m
	_y0 = float(cy) * _chunk_m
	_ppm = float(_t.px_per_m)

func run() -> Chunk:
	var t0 := Time.get_ticks_usec()
	_ch = Chunk.new()
	_ch.cx = _cx
	_ch.cy = _cy
	_ch.n = _n
	_ch.nb = _nb
	var tc: Dictionary = _t.chunk(_cx, _cy)
	var ph := {"terrain_chunk_ms": (Time.get_ticks_usec() - t0) / 1000.0}
	var tp := Time.get_ticks_usec()
	var tn: int = _t.cells
	var tcell: float = _t.cell_m
	var f := roundi(tcell / _c)
	if absf(float(f) * _c - tcell) > 1e-9:
		push_error("HeightGridBuild: the terrain lattice (%s m) is not a whole number of grid cells (%s m)" % [str(tcell), str(_c)])
	var thr: PackedFloat64Array = _t.thresholds
	var lh: PackedFloat64Array = _t.heights_m
	var vals: PackedFloat64Array = tc.vals
	var levels: Array = tc.levels
	var stride := tn + 1

	# 1. the level of every lattice cell (-1: a boundary runs through it) and the highest level it can hold
	var lev := PackedInt32Array()
	lev.resize(tn * tn)
	var lev_ub := PackedInt32Array()
	lev_ub.resize(tn * tn)
	var mixed_cells := 0
	var first_level := -2
	var all_same := true
	for j in tn:
		for i in tn:
			var idx := j * tn + i
			var mix := false
			for k in thr.size():
				if (levels[k].mixed as PackedByteArray)[idx] != 0:
					mix = true
					break
			var v00: float = vals[j * stride + i]
			if mix:
				lev[idx] = -1
				mixed_cells += 1
				var hi := maxf(maxf(v00, vals[j * stride + i + 1]), maxf(vals[(j + 1) * stride + i], vals[(j + 1) * stride + i + 1]))
				var ub := 0
				for k in thr.size():
					if hi >= thr[k]:
						ub = k + 1
				lev_ub[idx] = ub
			else:
				var l := 0
				for k in thr.size():
					if v00 >= thr[k]:
						l = k + 1
					else:
						break
				lev[idx] = l
				lev_ub[idx] = l
			if first_level == -2:
				first_level = lev[idx]
			elif lev[idx] != first_level:
				all_same = false

	ph["levels_ms"] = (Time.get_ticks_usec() - tp) / 1000.0
	tp = Time.get_ticks_usec()
	# 2. the water of every lattice cell: 0 dry, 1 wet, 2 decide cell by cell
	var wc := _water_classes(lev, tn, tcell)
	ph["water_classes_ms"] = (Time.get_ticks_usec() - tp) / 1000.0
	tp = Time.get_ticks_usec()
	var all_wc_same := true
	for q in range(1, wc.size()):
		if wc[q] != wc[0]:
			all_wc_same = false
			break

	# structures that touch the chunk (houses and walls of the village)
	var structs: Array = _structs_here()

	# a chunk of one level, one water state and no structure keeps no arrays
	if all_same and first_level >= 0 and all_wc_same and wc[0] != 2 and structs.is_empty():
		_ch.uniform = true
		_ch.uh = lh[first_level]
		_ch.um = Rules.WATER if wc[0] == 1 else Rules.GROUND
		var ub := PackedFloat32Array()
		ub.resize(_nb * _nb)
		ub.fill(_ch.uh)
		_ch.bmax = ub
		_ch.stats = {"build_ms": (Time.get_ticks_usec() - t0) / 1000.0, "mixed_cells": 0, "wet_cells": 0, "struct_cells": 0, "uniform": true}
		return _ch

	# 3. the heights, row by row
	var seg: Array = []
	for l in lh.size():
		var s := PackedFloat32Array()
		s.resize(f)
		s.fill(lh[l])
		seg.append(s)
	var h := PackedFloat32Array()
	for j in tn:
		var row_mixed := false
		for i in tn:
			if lev[j * tn + i] < 0:
				row_mixed = true
				break
		if not row_mixed:
			var row := PackedFloat32Array()
			for i in tn:
				row.append_array(seg[lev[j * tn + i]])
			for r in f:
				h.append_array(row)
		else:
			for r in f:
				var yc := _y0 + (float(j * f + r) + 0.5) * _c
				var row := PackedFloat32Array()
				for i in tn:
					var l := lev[j * tn + i]
					if l >= 0:
						row.append_array(seg[l])
					else:
						for q in f:
							var xc := _x0 + (float(i * f + q) + 0.5) * _c
							row.append(lh[_t.level_at(xc, yc)])
				h.append_array(row)
	_h = h
	_m = PackedByteArray()
	_m.resize(_n * _n)
	ph["heights_ms"] = (Time.get_ticks_usec() - tp) / 1000.0
	tp = Time.get_ticks_usec()

	# 4. the water
	var wet_cells := _fill_water(wc, tn, f)
	ph["water_fill_ms"] = (Time.get_ticks_usec() - tp) / 1000.0
	tp = Time.get_ticks_usec()

	# 5. the block bounds from the terrain, then the structures raise cells and the bounds with them
	_bmax = PackedFloat32Array()
	_bmax.resize(_nb * _nb)
	var bm := _bc * _c
	for by in _nb:
		var j0 := clampi(floori(float(by) * bm / tcell), 0, tn - 1)
		var j1 := clampi(floori((float(by + 1) * bm - 1e-6) / tcell), 0, tn - 1)
		for bx in _nb:
			var i0 := clampi(floori(float(bx) * bm / tcell), 0, tn - 1)
			var i1 := clampi(floori((float(bx + 1) * bm - 1e-6) / tcell), 0, tn - 1)
			var mx := 0
			for jj in range(j0, j1 + 1):
				for ii in range(i0, i1 + 1):
					mx = maxi(mx, lev_ub[jj * tn + ii])
			_bmax[by * _nb + bx] = lh[mx]
	ph["bmax_ms"] = (Time.get_ticks_usec() - tp) / 1000.0
	tp = Time.get_ticks_usec()
	var struct_cells := _stamp_structs(structs)
	ph["structs_ms"] = (Time.get_ticks_usec() - tp) / 1000.0
	_ch.h = _h
	_ch.m = _m
	_ch.bmax = _bmax
	_ch.stats = {"build_ms": (Time.get_ticks_usec() - t0) / 1000.0, "mixed_cells": mixed_cells, "wet_cells": wet_cells, "struct_cells": struct_cells, "uniform": false, "phases": ph}
	return _ch

# --- the water ----------------------------------------------------------------------------------------------

# 0 dry, 1 wet, 2 ask cell by cell, for each lattice cell. See the header.
func _water_classes(lev: PackedInt32Array, tn: int, tcell: float) -> PackedByteArray:
	var wc := PackedByteArray()
	wc.resize(tn * tn)
	if _water == null:
		return wc
	var margin: float = _rules.water_margin_m
	var rect := Rect2(_x0, _y0, _chunk_m, _chunk_m)
	if _water.sea_may_reach(rect):
		var stride := tn + 1
		var s := PackedFloat64Array()
		s.resize(stride * stride)
		for j in stride:
			for i in stride:
				s[j * stride + i] = _water.sea_s(_x0 + float(i) * tcell, _y0 + float(j) * tcell)
		for j in tn:
			for i in tn:
				var a: float = s[j * stride + i]
				var b: float = s[j * stride + i + 1]
				var c: float = s[(j + 1) * stride + i]
				var d: float = s[(j + 1) * stride + i + 1]
				var lo := minf(minf(a, b), minf(c, d))
				var hi := maxf(maxf(a, b), maxf(c, d))
				var idx := j * tn + i
				if hi < -margin:
					wc[idx] = 0
				elif lo > margin:
					var l := lev[idx]
					wc[idx] = 1 if l == 0 else (2 if l < 0 else 0)
				else:
					wc[idx] = 2
	# the river: every lattice cell near one of its segments is asked cell by cell
	var segs: PackedInt32Array = _g.river_segments_near(_cx, _cy)
	if not segs.is_empty():
		var pts: PackedVector2Array = _water.river_pts
		var hws: PackedFloat64Array = _water.river_hw
		for si in segs:
			var a: Vector2 = pts[si]
			var b: Vector2 = pts[si + 1]
			var g := maxf(hws[si], hws[si + 1]) + tcell
			var i0 := clampi(floori((minf(a.x, b.x) - g - _x0) / tcell), 0, tn - 1)
			var i1 := clampi(floori((maxf(a.x, b.x) + g - _x0) / tcell), 0, tn - 1)
			var j0 := clampi(floori((minf(a.y, b.y) - g - _y0) / tcell), 0, tn - 1)
			var j1 := clampi(floori((maxf(a.y, b.y) + g - _y0) / tcell), 0, tn - 1)
			for j in range(j0, j1 + 1):
				for i in range(i0, i1 + 1):
					if wc[j * tn + i] == 0:
						wc[j * tn + i] = 2
	return wc

# Marks the WATER material; returns how many cells are wet.
func _fill_water(wc: PackedByteArray, tn: int, f: int) -> int:
	if _water == null:
		return 0
	var wet := 0
	var sea_here: bool = _water.sea_may_reach(Rect2(_x0, _y0, _chunk_m, _chunk_m))
	var tcell: float = _t.cell_m
	for j in tn:
		for i in tn:
			var k: int = wc[j * tn + i]
			if k == 0:
				continue
			for r in f:
				var iy := j * f + r
				for q in f:
					var ix := i * f + q
					var idx := iy * _n + ix
					if k == 1:
						_m[idx] = Rules.WATER
						wet += 1
					elif _h[idx] == 0.0:
						var xc := _x0 + (float(ix) + 0.5) * _c
						var yc := _y0 + (float(iy) + 0.5) * _c
						var is_wet: bool = (_water.depth_at(xc, yc) > 0.0) if sea_here else (_water.river_s(xc, yc) > 0.0)
						if is_wet:
							_m[idx] = Rules.WATER
							wet += 1
	return wet

# --- the structures ------------------------------------------------------------------------------------------

func _structs_here() -> Array:
	var vil: Variant = _t.village()
	if vil == null:
		return []
	var r := Rect2(_x0 * _ppm, _y0 * _ppm, _chunk_m * _ppm, _chunk_m * _ppm)
	return vil.structs_in_rect(r)

func _stamp_structs(structs: Array) -> int:
	if structs.is_empty():
		return 0
	var cells := 0
	for s: Dictionary in structs:
		var hm := float(s.h) / _ppm
		if s.kind == "house":
			for p: Dictionary in s.geo:
				cells += _house_part(p, hm)
		else:
			cells += _wall(s, hm)
	return cells

# A cell raised to `top` (ground + a structure's height), the first time from the ground it stands on; a cell already higher stays.
func _raise(idx: int, ix: int, iy: int, hm: float, mat: int) -> bool:
	var g: float
	if _gnd.has(idx):
		g = _gnd[idx]
	else:
		g = _h[idx]
		_gnd[idx] = g
	var top := g + hm
	if top <= _h[idx]:
		return false
	_h[idx] = top
	_m[idx] = mat
	var bi := (iy / _bc) * _nb + ix / _bc
	if top > _bmax[bi]:
		_bmax[bi] = top
	return true

func _cell_range(lo: float, hi: float, origin: float) -> Vector2i:
	return Vector2i(clampi(floori((lo - origin) / _c), 0, _n - 1), clampi(floori((hi - origin) / _c), 0, _n - 1))

# One rectangular part of a house (map px).
func _house_part(p: Dictionary, hm: float) -> int:
	var ext_x := absf(p.w * 0.5 * p.cc) + absf(p.d * 0.5 * p.ss)
	var ext_y := absf(p.w * 0.5 * p.ss) + absf(p.d * 0.5 * p.cc)
	var cxm := float(p.cx) / _ppm
	var cym := float(p.cy) / _ppm
	var rx := _cell_range(cxm - ext_x / _ppm, cxm + ext_x / _ppm, _x0)
	var ry := _cell_range(cym - ext_y / _ppm, cym + ext_y / _ppm, _y0)
	if cxm + ext_x / _ppm < _x0 or cxm - ext_x / _ppm > _x0 + _chunk_m or cym + ext_y / _ppm < _y0 or cym - ext_y / _ppm > _y0 + _chunk_m:
		return 0
	var hw := float(p.w) * 0.5 / _ppm
	var hd := float(p.d) * 0.5 / _ppm
	var cc: float = p.cc
	var ss: float = p.ss
	var count := 0
	for iy in range(ry.x, ry.y + 1):
		var dy := _y0 + (float(iy) + 0.5) * _c - cym
		for ix in range(rx.x, rx.y + 1):
			var dx := _x0 + (float(ix) + 0.5) * _c - cxm
			var lx := dx * cc + dy * ss
			var ly := -dx * ss + dy * cc
			if absf(lx) <= hw and absf(ly) <= hd:
				if _raise(iy * _n + ix, ix, iy, hm, _rules.house_material):
					count += 1
	return count

# A wall: every cell within its half width of its centre line (a capsule round each segment, so an open wall has round ends).
func _wall(s: Dictionary, hm: float) -> int:
	var pts: Array = s.pts
	var np := pts.size()
	var hw := float(s.hw) / _ppm
	var hw2 := hw * hw
	var closed: bool = s.closed
	var count := 0
	var lim := np if closed else np - 1
	for i in lim:
		var a: Array = pts[i]
		var b: Array = pts[(i + 1) % np]
		var ax := float(a[0]) / _ppm
		var ay := float(a[1]) / _ppm
		var bx := float(b[0]) / _ppm
		var by := float(b[1]) / _ppm
		if maxf(ax, bx) + hw < _x0 or minf(ax, bx) - hw > _x0 + _chunk_m or maxf(ay, by) + hw < _y0 or minf(ay, by) - hw > _y0 + _chunk_m:
			continue
		var rx := _cell_range(minf(ax, bx) - hw, maxf(ax, bx) + hw, _x0)
		var ry := _cell_range(minf(ay, by) - hw, maxf(ay, by) + hw, _y0)
		var vx := bx - ax
		var vy := by - ay
		var l2 := vx * vx + vy * vy
		for iy in range(ry.x, ry.y + 1):
			var py := _y0 + (float(iy) + 0.5) * _c
			for ix in range(rx.x, rx.y + 1):
				var px := _x0 + (float(ix) + 0.5) * _c
				var u := 0.0
				if l2 > 0.0:
					u = clampf(((px - ax) * vx + (py - ay) * vy) / l2, 0.0, 1.0)
				var ex := px - (ax + vx * u)
				var ey := py - (ay + vy * u)
				if ex * ex + ey * ey <= hw2:
					if _raise(iy * _n + ix, ix, iy, hm, _rules.wall_material):
						count += 1
	return count
