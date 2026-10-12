extends "res://scripts/test_support/test_case.gd"

# SCENERY HEIGHTS, LIVE (decision scenery-heights, 2026-10-12; Alex: "S1 real heights"): the game's map carries S1's heights -- houses
# about 7 m to the ridge, the compound's walls about 2.5 m, trees held to 8 to 20 m -- and everything that reads a height follows.
# Headless. The prototype's own numbers are kept reachable as each value's prototype_default and are checked against the prototype
# in test_scene_gen (the whole default scene) and test_render_layer (the parity switch); this test is the other half, the GAME:
#
#   DATA        the five entries carry the decision, Alex's words, S1's value and the prototype's (render_defaults.json).
#   THE VILLAGE the Strike's houses are 6 to 8 m (today's were 10.7 to 14.5), its walls 1.1 to 2.9 m (were 2.7 to 6.0), in metres at
#               the map's own scale, from the Terrain the game builds (not from a hand-made RenderParams).
#   THE TREES   every tree of a 1.5 km square round the village is held to 8 to 20 m, the floor and the ceiling are both reached, and
#               24 m of terrain plus the tallest tree stays under the 120 m low band (Track S's constraint). Hedge trees are not lifted.
#   THE GRID    the line-of-fire height grid (scripts/sim/height_grid.gd) reads a structure's own height: a house's middle and a wall's
#               centre line stand at S1's heights in the grid too, and a canopy's top is the tree's S1 height.
#   REACH       a shadow's reach is measured from the tallest tree the window allows (RenderParams.tallest_tree_px): 40 px, not the
#               prototype's 57 px, and the prototype's own numbers give the old value back.

const RenderParams = preload("res://scripts/world/render_params.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const HeightGrid = preload("res://scripts/sim/height_grid.gd")
const VillageDraw = preload("res://scripts/render/village_draw.gd")

const SEED := 20261009          # the Strike's map: the village round the radio tower

func setup(_main) -> void:
	timeout_seconds = 600.0
	var P := RenderParams.new()
	if not check(P.ok(), "render params load: %s" % ", ".join(P.errors)):
		finish()
		return
	_data(P)
	_reach()
	var water := WaterGen.shared(SEED)
	var grid := HeightGrid.shared(SEED, water)
	if not check(grid.ok(), "the grid of seed %d builds: %s" % [SEED, grid.errors]):
		finish()
		return
	var terrain: Object = grid.terrain
	var ppm := float(terrain.px_per_m)
	check(ppm == 2.0, "the demo baseline: 2 px per metre (the heights are in px; 5 px = 2.5 m only here), got %s" % ppm)
	var tower: Vector2 = terrain.layout().sites()["radio_tower"]
	_village(terrain, ppm)
	_trees(terrain, ppm, tower)
	_hedges(terrain, ppm)
	_grid(grid, terrain, ppm, tower)
	finish()

# --- the data ---------------------------------------------------------------------------------------------------

func _data(P: RenderParams) -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(P.source_path))
	var prm: Dictionary = (raw as Dictionary).get("parameters", {}) if raw is Dictionary else {}
	for key: String in ["wall_height", "house_height_ratio", "tree_height_scale", "tree_height_min_px", "tree_height_max_px"]:
		var e: Dictionary = prm.get(key, {})
		check(not e.is_empty(), "parameters.%s exists" % key)
		eq(str(e.get("decision", "")), "scenery-heights", "%s names its decision" % key)
		check(str(e.get("alex_words", "")).contains("S1 real heights"), "%s carries Alex's words" % key)
		check(e.has("prototype_default"), "%s keeps the prototype's value as prototype_default" % key)
	near(P.wallH, 5.0, 0.0, "the game's walls are 5 px")
	near(P.houseHeightRatio, 0.5, 0.0, "the game's houses are 0.5 x house_size")
	near(P.treeHeightScale, 1.1, 0.0, "the game's trees are x1.1")
	near(P.treeHeightMin, 16.0, 0.0, "the game's trees are at least 16 px")
	near(P.treeHeightMax, 40.0, 0.0, "the game's trees are at most 40 px")

# A shadow's reach is from the tallest tree the window allows.
func _reach() -> void:
	var game := RenderParams.new()
	near(game.tallest_tree_px(), 40.0, 1e-9, "the tallest tree in the game is the window's 40 px (the crowns alone allow %.1f)" % (game.treeSize * (1.0 + game.sizeVar) * game.big_tree_scale * game.height * 1.15))
	var proto := RenderParams.new()
	proto.use_prototype_defaults()
	near(proto.tallest_tree_px(), proto.treeSize * (1.0 + proto.sizeVar) * proto.big_tree_scale * proto.height * 1.15, 1e-12, "the prototype's tallest tree is the crowns' own (no window)")
	check(proto.tallest_tree_px() > 55.0, "the prototype's tallest tree is 57 px (28.8 m), got %.1f" % proto.tallest_tree_px())

# --- the village -------------------------------------------------------------------------------------------------

func _village(terrain: Object, ppm: float) -> void:
	var vil: Variant = terrain.village()
	if not check(vil != null, "the Strike has a village"):
		return
	var houses := PackedFloat64Array()
	var walls := PackedFloat64Array()
	for s: Dictionary in vil.structs:
		(houses if s.kind == "house" else walls).append(float(s.h) / ppm)
	check(houses.size() >= 10 and walls.size() >= 2, "the village has houses and walls (%d, %d)" % [houses.size(), walls.size()])
	var h_lo := 1e9
	var h_hi := 0.0
	for v in houses:
		h_lo = minf(h_lo, v)
		h_hi = maxf(h_hi, v)
	check(h_lo >= 5.9 and h_hi <= 8.1, "every house is 6 to 8 m to the ridge (S1; was 10.7 to 14.5): %.2f to %.2f m" % [h_lo, h_hi])
	var w_lo := 1e9
	var w_hi := 0.0
	for v in walls:
		w_lo = minf(w_lo, v)
		w_hi = maxf(w_hi, v)
	check(w_lo >= 1.0 and w_hi <= 2.9, "every compound wall is 1.1 to 2.9 m (S1: 5 px x 0.45 to 1.15; was 2.7 to 6.0): %.2f to %.2f m" % [w_lo, w_hi])
	print("[scenery] houses %.2f to %.2f m (%d), walls %.2f to %.2f m (%d)" % [h_lo, h_hi, houses.size(), w_lo, w_hi, walls.size()])

# --- the trees ---------------------------------------------------------------------------------------------------

func _trees(terrain: Object, ppm: float, tower: Vector2) -> void:
	var rect := Rect2((tower - Vector2(768.0, 768.0)) * ppm, Vector2(1536.0, 1536.0) * ppm)
	var trees: Array = terrain.trees_in_rect_px(rect)
	if not check(trees.size() > 1000, "enough trees in the 1.5 km square round the village (%d)" % trees.size()):
		return
	var lo := 1e9
	var hi := 0.0
	var held_low := 0
	var held_high := 0
	for t: Dictionary in trees:
		var m := float(t.h) / ppm
		lo = minf(lo, m)
		hi = maxf(hi, m)
		if absf(m - 8.0) < 1e-9:
			held_low += 1
		if absf(m - 20.0) < 1e-9:
			held_high += 1
	check(lo >= 8.0 - 1e-9 and hi <= 20.0 + 1e-9, "every tree is held to 8 to 20 m (S1; was 6.4 to 28.7): %.3f to %.3f m of %d" % [lo, hi, trees.size()])
	check(held_low > 0 and held_high > 0, "the floor and the ceiling are both reached (%d held at 8 m, %d at 20 m)" % [held_low, held_high])
	check(24.0 + hi < 120.0, "24 m of terrain plus the tallest tree (%.1f m) stays under the 120 m low band" % hi)
	print("[scenery] %d trees, %.2f to %.2f m, %d held at 8 m, %d at 20 m" % [trees.size(), lo, hi, held_low, held_high])

# Hedge trees keep their own height (a fraction of a tree of their size): the window's 8 m floor does not lift them.
func _hedges(terrain: Object, ppm: float) -> void:
	var vil: Variant = terrain.village()
	var vd := VillageDraw.new(terrain, terrain.P)
	var hedges: Array = vd.hedge_trees(vil)
	if not check(hedges.size() > 20, "the village has hedge trees (%d)" % hedges.size()):
		return
	var hi := 0.0
	for t: Dictionary in hedges:
		hi = maxf(hi, float(t.h) / ppm)
	check(hi < 5.0, "hedge trees stay low, under 5 m (the tallest is %.2f m), not lifted to the window's 8 m floor" % hi)

# --- the height grid ---------------------------------------------------------------------------------------------

func _grid(grid: Object, terrain: Object, ppm: float, tower: Vector2) -> void:
	grid.build_rect(Rect2(tower.x - 260.0, tower.y - 260.0, 520.0, 520.0))
	var vil: Variant = terrain.village()
	var houses := 0
	var walls := 0
	for s: Dictionary in vil.structs:
		var hm := float(s.h) / ppm
		if s.kind == "house":
			var part: Dictionary = s.geo[0]
			var px := float(part.cx) / ppm
			var py := float(part.cy) / ppm
			if absf(px - tower.x) < 250.0 and absf(py - tower.y) < 250.0:
				houses += 1
				var top: float = grid.top_at(px, py)
				near(top, hm, 1e-3, "the grid's house is the structure's S1 height (%.2f m)" % hm)
				check(top >= 5.9 and top <= 8.1, "a house stands 6 to 8 m in the grid (%.2f m)" % top)
		else:
			var pts: Array = s.pts
			var mid: Array = pts[pts.size() / 2]
			var wx := float(mid[0]) / ppm
			var wy := float(mid[1]) / ppm
			if absf(wx - tower.x) < 250.0 and absf(wy - tower.y) < 250.0:
				walls += 1
				var top: float = grid.top_at(wx, wy)
				near(top, hm, 1e-3, "the grid's wall is the structure's S1 height (%.2f m)" % hm)
				check(top >= 1.0 and top <= 2.9, "a wall stands 1.1 to 2.9 m in the grid (%.2f m)" % top)
	check(houses >= 3 and walls >= 2, "the village has houses and walls near the tower to check in the grid (%d, %d)" % [houses, walls])
	# a canopy's top is the tree's own height, so S1's too
	var ctr: Vector2i = terrain.chunk_of(tower.x, tower.y)
	var trees: Array = terrain.trees_in_chunk(ctr.x, ctr.y)
	var tallest := 0.0
	for t: Dictionary in trees:
		tallest = maxf(tallest, float(t.h) / ppm)
	check(not trees.is_empty() and tallest <= 20.0 + 1e-9, "the tower's chunk has trees, none over 20 m (%.2f m of %d)" % [tallest, trees.size()])
	print("[scenery] grid: %d houses and %d walls near the tower at S1's heights" % [houses, walls])
