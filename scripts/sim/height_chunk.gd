extends RefCounted

# ONE CHUNK OF THE HEIGHT GRID (builder LOF1, stage 1 of the lines of fire, 2026-10-11; scripts/sim/height_grid.gd holds the
# chunks, scripts/sim/height_grid_build.gd makes them). A chunk is one terrain chunk (256 m square, data/terrain/terrain.json
# chunks.chunk_m) cut into n x n cells of data grid.cell_m, row by row, y down:
#
#   h[iy * n + ix]    the cell's top, metres above sea level (PackedFloat32Array)
#   m[iy * n + ix]    its material id in the low four bits, FLAG_DECK (0x10) for a surface units stand on (PackedByteArray)
#   bmax[by * nb + bx]  the highest top in each block of block_cells x block_cells cells: an UPPER BOUND (a line that passes
#                     above a block's bound skips the block)
#
# A UNIFORM chunk (open sea, a plain with no village in it) keeps no arrays: `uh` and `um` are the one height and material of
# every cell, so most of a 5 km map costs nothing. THE STAMP LAYER (oh, om, obmax) is a second set of arrays allocated the
# first time a static unit's shape (a battery's sandbag ring, the bridge's deck) reaches the chunk; the effective top of a cell
# is the larger of the two, so a stamp can come and go (the unit is destroyed) while the map layer under it stays as built.

var cx: int = 0
var cy: int = 0
var n: int = 0                      # cells per side
var nb: int = 0                     # blocks per side
var uniform: bool = false
var uh: float = 0.0
var um: int = 0
var h := PackedFloat32Array()
var m := PackedByteArray()
var bmax := PackedFloat32Array()
var has_ov: bool = false
var oh := PackedFloat32Array()
var om := PackedByteArray()
var obmax := PackedFloat32Array()
var stats: Dictionary = {}          # build_ms, mixed terrain cells, structure cells, wet cells, trees

# Allocates the stamp layer (zeros: nothing there).
func ensure_overlay() -> void:
	if has_ov:
		return
	oh.resize(n * n)
	om.resize(n * n)
	obmax.resize(nb * nb)
	has_ov = true

func clear_overlay() -> void:
	if not has_ov:
		return
	oh.fill(0.0)
	om.fill(0)
	obmax.fill(0.0)
	has_ov = false
	oh = PackedFloat32Array()
	om = PackedByteArray()
	obmax = PackedFloat32Array()

# The base layer's top and material at a local cell, without the stamp layer.
func base_top(ix: int, iy: int) -> float:
	return uh if uniform else h[iy * n + ix]

func base_material(ix: int, iy: int) -> int:
	return um if uniform else m[iy * n + ix]

# The effective top at a local cell (the larger of the layers).
func top(ix: int, iy: int) -> float:
	var t: float = uh if uniform else h[iy * n + ix]
	if has_ov:
		var o := oh[iy * n + ix]
		if o > t:
			return o
	return t

# The effective material byte at a local cell: the stamp's where the stamp is the higher top, or as high and WRITTEN (om is never 0 where a
# stamp wrote: stone, sandbags and the deck flag are all non-zero), else the map's. The tie matters for a deck level with the banks
# (the low bridge, decision line-of-fire, builder LOF2): its cells are stone and a deck at the same height as the water or the ground.
func material_byte(ix: int, iy: int) -> int:
	var t: float = uh if uniform else h[iy * n + ix]
	var mat: int = um if uniform else m[iy * n + ix]
	if has_ov:
		var o := oh[iy * n + ix]
		if o > t or (o == t and om[iy * n + ix] != 0):
			return om[iy * n + ix]
	return mat

# Memory the chunk's arrays hold, bytes.
func bytes() -> int:
	return h.size() * 4 + m.size() + bmax.size() * 4 + oh.size() * 4 + om.size() + obmax.size() * 4
