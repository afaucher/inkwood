extends "res://scripts/world/terrain.gd"

# THE TERRAIN WITH THE WATER'S CAP ON ITS HEIGHT FIELD (Track WB, 2026-10-10): scripts/world/terrain.gd with ONE
# change, the two functions below, and nothing else. The water (scripts/world/water_gen.gd) makes a mask,
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
#   var t := preload("res://scripts/world/water_terrain.gd").new(seed)
#   t.set_cap(Callable(water, "field_cap"))

var _cap_fn: Callable = Callable()

func set_cap(fn: Callable) -> void:
	_cap_fn = fn
	clear_cache()

func field_at_node(ix: int, iy: int) -> float:
	var v := super.field_at_node(ix, iy)
	if _cap_fn.is_valid():
		v = minf(v, float(_cap_fn.call(float(ix) * cell_m, float(iy) * cell_m)))
	return v

func field_at(x: float, y: float) -> float:
	var v := super.field_at(x, y)
	if _cap_fn.is_valid():
		v = minf(v, float(_cap_fn.call(x, y)))
	return v
