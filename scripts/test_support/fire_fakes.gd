extends RefCounted

# TEST SUPPORT for the forest fire (decision forest-fire, 2026-10-11; the gate does not run scripts/test_support). Trees and states made by hand, so a rule is
# tried on exactly the trees it is about, without the terrain:
#
#   var trees := FireFakes.FakeTrees.new()
#   trees.add(1, 100.0, 100.0, 8.0)                      # id "f1", centre (100, 100) m, canopy radius 8 m
#   var fire := FireFakes.state(trees)                   # a FireState over data/sim/fire.json with that tree source (null: none)
#   FireFakes.tree(2, 130.0, 100.0, 8.0)                 # a tree record to hand to fire.add_lit
#   FireFakes.stand(10.0, 20.0)                          # a sampler that keeps every unit at (10, 20)
#   FireFakes.bomb(x, y, t)                              # a bomb_impact event as combat_resolver makes them (blast_m from data/sim/bombs.json)

const FireRules = preload("res://scripts/sim/fire_rules.gd")
const FireState = preload("res://scripts/sim/fire.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")

# A tree source with a list of trees, the two calls the fire makes of one (scripts/sim/fire_trees.gd).
class FakeTrees:
	extends RefCounted
	var list: Array = []
	var cmax: float = 10.0

	func add(n: int, x: float, y: float, r: float) -> void:
		list.append({"id": "f%d" % n, "x_m": x, "y_m": y, "r_m": r, "kx": n, "ky": n * 7 + 3})
		cmax = maxf(cmax, r)

	func trees_in_disc(x_m: float, y_m: float, reach_m: float) -> Array:
		var out: Array = []
		for t: Dictionary in list:
			if Vector2(float(t["x_m"]) - x_m, float(t["y_m"]) - y_m).length() <= reach_m:
				out.append(t)
		return out

	func max_canopy_m() -> float:
		return cmax

static func rules() -> FireRules:
	return FireRules.new(FireRules.PATH, true)

static func state(source: Object = null) -> FireState:
	var f := FireState.new(rules(), 5.0)
	f.source = source
	return f

static func tree(n: int, x: float, y: float, r: float) -> Dictionary:
	return {"id": "f%d" % n, "x_m": x, "y_m": y, "r_m": r, "kx": n, "ky": n * 7 + 3}

static func stand(x: float, y: float) -> Callable:
	return func(_uid: String, _t: float) -> Dictionary: return {"x": x, "y": y}

static func bomb(x: float, y: float, t: float) -> Dictionary:
	var br := BombRules.new()
	return {"type": "bomb_impact", "turn": 1, "unit": "bomber", "t": t, "x": x, "y": y, "blast_m": br.blast_radius_m()}

static func events_of(list: Array, type: String) -> Array:
	var out: Array = []
	for e: Variant in list:
		if str((e as Dictionary).get("type", "")) == type:
			out.append(e)
	return out

# The centre of a grove of the terrain near `near_pt`: the tree with woods density 0.5 or more that has the most trees within 45 m of it; Vector2.INF if none.
# `gm` is a GroundMap (woods_at), `src` the FireTrees.
static func grove_point(gm: RefCounted, src: Object, near_pt: Vector2) -> Vector2:
	var trees: Array = src.trees_in_disc(near_pt.x, near_pt.y, 700.0)
	var best := Vector2.INF
	var best_n := 0
	for a: Dictionary in trees:
		if float(gm.woods_at(float(a["x_m"]), float(a["y_m"]))) < 0.5:
			continue
		var n := 0
		for b: Dictionary in trees:
			if Vector2(float(a["x_m"]) - float(b["x_m"]), float(a["y_m"]) - float(b["y_m"])).length() <= 45.0:
				n += 1
		if n > best_n:
			best_n = n
			best = Vector2(float(a["x_m"]), float(a["y_m"]))
	return best
