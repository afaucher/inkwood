extends "res://scripts/world/terrain.gd"

# THE TERRAIN WITH THE WATER'S CAP ON ITS HEIGHT FIELD (Track WB, 2026-10-10): scripts/world/terrain.gd with ONE
# change to the ground, the two functions below, and one to what grows on it (the trees, below). The water
# (scripts/world/water_gen.gd) makes a mask,
# field_cap(x, y), the highest the height field may stand at a point: far inland it is above the field's range
# (nothing changes), toward a coast it falls and the plateaus taper, under the sea it is below the first threshold
# (level 0: water, never a drowned upland), and where a cliff noise says so an upland keeps its height to the very
# shore and meets the sea as a coastal cliff. The levels, contours, hachures, shadows, trees and the world layout's
# queries all read the field through field_at / field_at_node, so they follow the cap with no other change.
#
# THIS FILE IS THE PROOF OF WHAT INTEGRATION NEEDS from scripts/world/terrain*.gd: in terrain.gd's
# field_at_node() and field_at(), `return minf(<the fbm>, cap)` where `cap` is the water's mask (a Callable the
# terrain is given; absent: no cap, the terrain as it was). The world layout is made on the RAW terrain (before the
# water exists) and does not change: the cap only lowers ground, and every layout site is low ground already.
#
#   var t := water.make_terrain(seed)        # (WaterGen.make_terrain: this script, the cap and the tree filter installed)
#
# NO TREE STANDS IN WATER (live map, Job 3): trees_in_chunk() keeps only the trees the water says may stand where they
# are (set_tree_filter(fn(x_m, y_m) -> bool), WaterGen.tree_dry). The terrain's own placement is untouched -- it plants the
# chunk as it always did and the wet trees are dropped from the list afterwards -- so away from the water every tree is
# exactly the tree it was, and the map, the shadows, the sight (trees block it) and the tests all see one list.

var _cap_fn: Callable = Callable()
var _tree_ok: Callable = Callable()
var _dry: Dictionary = {}         # Vector2i -> the chunk's trees on dry ground
var _lattice: Object = null      # the water, when the terrain's lattice is the water's (the node path below)
var _blk_i := 1 << 40
var _blk_j := 0
var _blk: Variant = null

func set_cap(fn: Callable) -> void:
	_cap_fn = fn
	clear_cache()

# THE LATTICE PATH: the water's sea field is kept in blocks on the same 8 m lattice as this terrain's nodes, so the cap at a node is read
# off the block (water.cap_at_node) and not made from the fields again. One terrain is used by one thread at a time (its bundle's
# lock, its twin's lock), so the last block fetched is kept here without a lock.
func set_lattice(w: Object) -> void:
	_lattice = w if w != null and is_equal_approx(cell_m, float(w.lattice_m())) else null
	_blk_i = 1 << 40
	_blk = null

func set_tree_filter(fn: Callable) -> void:
	_tree_ok = fn
	_dry.clear()

func field_at_node(ix: int, iy: int) -> float:
	var v := super.field_at_node(ix, iy)
	if _lattice != null:
		var n: int = _lattice.BLOCK_N
		var bi := floori(float(ix) / float(n))
		var bj := floori(float(iy) / float(n))
		if bi != _blk_i or bj != _blk_j:
			_blk = _lattice.lattice_block(bi, bj)
			_blk_i = bi
			_blk_j = bj
		v = minf(v, _lattice.cap_at_node(_blk, ix, iy))
	elif _cap_fn.is_valid():
		v = minf(v, float(_cap_fn.call(float(ix) * cell_m, float(iy) * cell_m)))
	return v

func field_at(x: float, y: float) -> float:
	var v := super.field_at(x, y)
	if _cap_fn.is_valid():
		v = minf(v, float(_cap_fn.call(x, y)))
	return v

func trees_in_chunk(cx: int, cy: int) -> Array:
	var all: Array = super.trees_in_chunk(cx, cy)
	if not _tree_ok.is_valid():
		return all
	var key := Vector2i(cx, cy)
	var hit: Variant = _dry.get(key)
	if hit != null:
		return hit
	var out: Array = []
	for t: Dictionary in all:
		if bool(_tree_ok.call(float(t.x) / px_per_m, float(t.y) / px_per_m)):
			out.append(t)
	_dry[key] = out
	return out

func clear_cache() -> void:
	super.clear_cache()
	_dry.clear()
