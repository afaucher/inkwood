extends RefCounted

# THE FOREST FIRE'S TREES (decision forest-fire): the trees the fire lights, as the TERRAIN generates them. The sim does not know the
# generators (as it does not know the water or the ground): the scenario builder hands the World a FireTrees over the terrain of the
# seed (SandboxScenario.populate: GroundMap.shared(seed, water).terrain, the very terrain the map is drawn from -- the water's capped one
# when the water is on, the raw one when not), and the fire only asks for the trees round a place.
#
#   var src := FireTrees.new(terrain)                 # any object with px_per_m, chunk_m, P (tree sizes) and trees_in_chunk(cx, cy) -> Array
#   src.trees_in_disc(x_m, y_m, reach_m)              # -> [{id, x_m, y_m, r_m, kx, ky}] the trees whose CENTRE is within reach_m, in id order
#   src.max_canopy_m()                                # the largest canopy radius a tree can have, metres
#   FireTrees.id_of(x_px, y_px)                       # the tree's id: its place, 0.1 px, so it is the same in every Terrain of the seed
#
# TREE IDENTITY. A tree record in the terrain is generated per chunk from (seed, chunk) alone (terrain.gd), so every Terrain of a seed makes
# the same trees (scripts/tests/test_fire.gd compares this source with the map provider's terrain chunk by chunk). The id is therefore the
# tree's place in world px at the terrain's own scale, rounded to a tenth of a pixel: "<x*10>_<y*10>". Two trees never stand within a pixel
# of each other (the terrain's own collision rule keeps their canopies apart), so the id is unique; it is the same on the host and a client,
# and it does not depend on the order chunks were generated in. The sim's scale is the DATA's (terrain.json scale.px_per_m, 2): trees are
# generated in pixels, so a map drawn at another scale (the debug map_scale knob) has other trees than the sim's.
#
# Records are in METRES (the sim's unit): x_m, y_m the tree's centre, r_m its CANOPY radius (the terrain's `r`, px / px_per_m); kx, ky the
# id's integers, for the dice (scripts/sim/fire.gd). The terrain's caches are not thread safe: ask from the sim's thread only.

var terrain: Object = null
var px_per_m: float = 1.0
var chunk_px: float = 1.0

func _init(t: Object) -> void:
	terrain = t
	px_per_m = float(t.px_per_m)
	chunk_px = float(t.chunk_m) * px_per_m

static func key_of(x_px: float, y_px: float) -> Vector2i:
	return Vector2i(roundi(x_px * 10.0), roundi(y_px * 10.0))

static func id_of(x_px: float, y_px: float) -> String:
	var k := key_of(x_px, y_px)
	return "%d_%d" % [k.x, k.y]

func ok() -> bool:
	return terrain != null and bool(terrain.ok())

# The largest canopy radius, metres: the terrain's tree size at its largest variation, as a big tree.
func max_canopy_m() -> float:
	var p: Object = terrain.P
	return float(p.treeSize) * (1.0 + float(p.sizeVar)) * float(p.big_tree_scale) / px_per_m

# One terrain tree record (px) as the fire's (metres).
func record_of(t: Dictionary) -> Dictionary:
	var k := key_of(float(t["x"]), float(t["y"]))
	return {"id": "%d_%d" % [k.x, k.y], "x_m": float(t["x"]) / px_per_m, "y_m": float(t["y"]) / px_per_m, "r_m": float(t["r"]) / px_per_m, "kx": k.x, "ky": k.y}

# The trees whose centre is within reach_m of (x_m, y_m), in id order (the chunks the disc touches are generated on first use).
func trees_in_disc(x_m: float, y_m: float, reach_m: float) -> Array:
	var out: Array = []
	if reach_m < 0.0:
		return out
	var x := x_m * px_per_m
	var y := y_m * px_per_m
	var reach := reach_m * px_per_m
	var r2 := reach * reach
	for cy in range(floori((y - reach) / chunk_px), floori((y + reach) / chunk_px) + 1):
		for cx in range(floori((x - reach) / chunk_px), floori((x + reach) / chunk_px) + 1):
			if not terrain.chunk_in_map(cx, cy):
				continue
			for t: Dictionary in terrain.trees_in_chunk(cx, cy):
				var dx: float = float(t["x"]) - x
				var dy: float = float(t["y"]) - y
				if dx * dx + dy * dy <= r2:
					out.append(record_of(t))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))
	return out
