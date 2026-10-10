extends "res://scripts/test_support/test_case.gd"

# THE WORLD LAYOUT (Track W: scripts/world/world_layout.gd, village.gd; data/world/layout.json),
# headless -- plans and content, no pixels. What it holds the layout to:
#
#   DATA         layout.json parses, every field in it is read by WorldLayout + Village
#                (TerrainData.unused() is empty).
#   DETERMINISM  two layouts of one seed are the same plan (a signature of the village, the
#                sites, the road, the fields and the house slots), a layout shared through the
#                cache is that plan too; other seeds give other plans, each valid.
#   THE TOWER    the radio tower's site is on low ground (level 0, clear of cliffs), inside the
#                village's outline, inside the walled compound the village builds round it,
#                well clear of the compound's walls, of every house, of every field and of the road.
#   BATTERIES    two sites on open level-0 ground: clear of cliffs, outside the village, off the
#                road and the fields, a few hundred metres from the tower and from each other.
#   THE ROAD     one connected polyline from the village's street to past a map edge, through the
#                village's middle, on level 0 and clear of cliffs everywhere, evenly sampled.
#   FIELDS       convex quadrilaterals on level 0 clear of cliffs, on the map, off the village,
#                the road, the compound and each other.
#   THE CELLS    the terrain's trees consult the layout: no tree stands on a house, a wall, the
#                compound's yard, the road or a field; the cells round the village differ from the
#                same cells without the layout; a cell far from the village is IDENTICAL with and
#                without it (the map's look elsewhere is unchanged); and a cell's content is the
#                same whatever was generated before it (bake order never changes a result).
#
# The numbers measured are printed as [layout] lines for the report.

const WorldLayout = preload("res://scripts/world/world_layout.gd")
const Terrain = preload("res://scripts/world/terrain.gd")

const SEED := 20261009
const PPM := 2.0

func setup(_main) -> void:
	timeout_seconds = 300.0
	var t0 := Time.get_ticks_usec()
	var terrain := Terrain.new(SEED)
	var layout := WorldLayout.new(SEED, terrain)
	if not check(layout.ok(), "the layout of seed %d builds: %s %s" % [SEED, layout.errors, layout.data.errors]):
		finish()
		return
	print("[layout] seed %d built in %.0f ms; %s" % [SEED, layout.diagnostics.get("build_ms", -1.0), layout.diagnostics])
	_data(terrain, layout)
	_determinism(terrain, layout)
	var vil: Variant = terrain.village()
	if check(vil != null and vil.ok(), "the village builds at %s px/m: %s" % [PPM, vil.errors if vil != null else "null"]):
		_tower(terrain, layout, vil)
		_batteries(terrain, layout)
		_road(terrain, layout)
		_road_trees(terrain, vil)
		_fields(terrain, layout)
		_cells(terrain, layout, vil)
	_other_seeds()
	print("[layout] test total %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	finish()

# --- helpers ---------------------------------------------------------------------------------------

static func _in_any(p: Vector2, polys: Array[PackedVector2Array]) -> bool:
	for f in polys:
		if Geometry2D.is_point_in_polygon(p, f):
			return true
	return false

static func _road_dist(road: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	for k in range(1, road.size()):
		var a := road[k - 1]
		var b := road[k]
		var ab := b - a
		var l2 := ab.length_squared()
		var t := 0.0 if l2 == 0.0 else clampf((p - a).dot(ab) / l2, 0.0, 1.0)
		best = minf(best, p.distance_to(a + ab * t))
	return best

# --- data ---------------------------------------------------------------------------------------------

func _data(terrain: Terrain, layout: WorldLayout) -> void:
	# the layout the terrain shares (WorldLayout.shared) is the one its Village reads clearance.*,
	# houses.min_gap_px and compound.fort_size_px from; between them they read every field
	terrain.village()
	var used: WorldLayout = terrain.layout()
	var unused := used.data.unused()
	check(unused.is_empty(), "every field of layout.json is read; unused: %s" % [unused])
	check(used.data.ok() and layout.data.ok(), "no data errors: %s %s" % [used.data.errors, layout.data.errors])
	print("[layout] layout.json: %d fields read, %d unused" % [used.data._used.size(), unused.size()])

# --- determinism -----------------------------------------------------------------------------------------

func _determinism(terrain: Terrain, layout: WorldLayout) -> void:
	var again := WorldLayout.new(SEED)          # its own terrain
	check(again.ok(), "a second layout of the same seed builds")
	eq(again.signature(), layout.signature(), "same seed, same plan (village, sites, road, fields, house slots)")
	var shared := WorldLayout.shared(SEED, terrain)
	eq(shared.signature(), layout.signature(), "the shared layout is the same plan")
	check(WorldLayout.shared(SEED) == shared, "and it is shared: asking again returns the same object")
	var a := layout.sites()
	var b := again.sites()
	check(a.radio_tower == b.radio_tower and a.aa_battery == b.aa_battery, "same seed, same sites")
	check(layout.road() == again.road(), "same seed, same road")
	check(layout.fields() == again.fields(), "same seed, same fields")
	var g1 := layout.village()
	var g2 := again.village()
	check(g1.polygon == g2.polygon and g1.centre == g2.centre, "same seed, same village outline")
	var info_same := true
	for i in layout.field_count():
		info_same = info_same and layout.field_info(i) == again.field_info(i)
	check(info_same, "same seed, same field info (row angle, kind, seed)")
	# the plan is scale-free: the layout never reads px_per_m
	var other_scale := Terrain.new(SEED)
	other_scale.px_per_m = 4.0
	eq(WorldLayout.new(SEED, other_scale).signature(), layout.signature(), "the plan is in metres: another px_per_m gives the same plan")

# --- the tower ----------------------------------------------------------------------------------------------

func _tower(terrain: Terrain, layout: WorldLayout, vil: Variant) -> void:
	var site: Vector2 = layout.sites().radio_tower
	var v := layout.village()
	var map := Rect2(terrain.map_x, terrain.map_y, terrain.map_w, terrain.map_h)
	check(map.has_point(site), "the tower is on the map (%s)" % site)
	eq(terrain.level_at(site.x, site.y), 0, "the tower stands on level 0 (low ground)")
	var cliff := terrain.boundary_distance(site.x, site.y, 0, 100.0)
	check(cliff >= 40.0, "and 40 m or more from any height boundary (%.0f m)" % cliff)
	check(layout.in_village(site), "the tower is inside the village's outline")
	check(not _in_any(site, layout.fields()), "the tower is in no field")
	var rd := _road_dist(layout.road(), site)
	check(rd > layout.road_clear_half_m(), "the tower is off the road (%.0f m from it)" % rd)
	var yard: PackedVector2Array = vil.compound.yard
	check(Geometry2D.is_point_in_polygon(site * PPM, yard), "the tower is inside the walled compound (the village's fort ring)")
	var nearest_wall := INF
	var nearest_house := INF
	for s: Dictionary in vil.structs:
		var d: float = vil._struct_dist(s, site.x * PPM, site.y * PPM)
		if s.role == "compound":
			nearest_wall = minf(nearest_wall, d)
		else:
			nearest_house = minf(nearest_house, d)
	check(nearest_wall >= 24.0, "the tower is open ground: at least 24 px (12 m) from every wall of the compound (%.0f px)" % nearest_wall)
	check(nearest_house >= 120.0, "and at least 120 px (60 m) from every house (%.0f px)" % nearest_house)
	var kinds := {}
	for s: Dictionary in vil.structs:
		kinds[s.role] = int(kinds.get(s.role, 0)) + 1
	check(int(kinds.get("compound", 0)) >= 2, "the compound has its ring and its divider (%s)" % [kinds])
	check(int(kinds.get("house", 0)) >= 10, "the village has houses (%s)" % [kinds])
	print("[layout] village at %s, axis %.2f rad, tower %s, %d walls, %d houses (%d slots, %d dropped), %d fields, road %d m" % [
		v.centre, v.axis, site, kinds.get("compound", 0), kinds.get("house", 0), (v.house_slots as Array).size(),
		vil.compound.houses_dropped, layout.field_count(), roundi(layout.diagnostics.get("road_length_m", 0.0))])

# --- batteries --------------------------------------------------------------------------------------------------

func _batteries(terrain: Terrain, layout: WorldLayout) -> void:
	var s := layout.sites()
	var tower: Vector2 = s.radio_tower
	var list: Array = s.aa_battery
	eq(list.size(), 2, "two anti-aircraft battery sites")
	var polys := layout.fields()
	var village := layout.village()
	for i in list.size():
		var p: Vector2 = list[i]
		eq(terrain.level_at(p.x, p.y), 0, "battery %d is on level 0" % i)
		var open := true
		for k in 4:
			var q := p + Vector2.from_angle(k * PI * 0.5) * 25.0
			open = open and terrain.level_at(q.x, q.y) == 0
		check(open, "battery %d has level 0 all round it (25 m)" % i)
		check(terrain.boundary_distance(p.x, p.y, 0, 60.0) >= 50.0, "battery %d is 50 m or more from any height boundary" % i)
		check(not layout.in_village(p), "battery %d is outside the village's outline" % i)
		check(not _in_any(p, polys), "battery %d is in no field" % i)
		check(_road_dist(layout.road(), p) >= 30.0, "battery %d is off the road (%.0f m)" % [i, _road_dist(layout.road(), p)])
		var d := p.distance_to(tower)
		check(d >= 150.0 and d <= 650.0, "battery %d is a few hundred metres from the tower (%.0f m)" % [i, d])
	var apart: float = (list[0] as Vector2).distance_to(list[1])
	check(apart >= 280.0, "the batteries are a few hundred metres apart (%.0f m)" % apart)
	print("[layout] batteries %s and %s: %.0f and %.0f m from the tower, %.0f m apart" % [
		list[0], list[1], (list[0] as Vector2).distance_to(tower), (list[1] as Vector2).distance_to(tower), apart])
	check(village.polygon.size() > 8, "the village has an outline")

# --- the road ----------------------------------------------------------------------------------------------------------

func _road(terrain: Terrain, layout: WorldLayout) -> void:
	var road := layout.road()
	var v := layout.village()
	var map := Rect2(terrain.map_x, terrain.map_y, terrain.map_w, terrain.map_h)
	if not check(road.size() > 50, "the road has points (%d)" % road.size()):
		return
	check(layout.in_village(road[0]) or road[0].distance_to(v.street[0]) < 1.0, "the road starts in the village, at the street's far end (%s)" % road[0])
	check(not map.has_point(road[road.size() - 1]), "and runs past the map's edge (%s)" % road[road.size() - 1])
	var step_ok := true
	var worst := 0.0
	var near_centre := INF
	var off_level := 0
	var near_cliff := 0
	for k in road.size():
		if k > 0:
			var d := road[k].distance_to(road[k - 1])
			worst = maxf(worst, d)
			step_ok = step_ok and d <= 12.5
		near_centre = minf(near_centre, road[k].distance_to(v.centre))
		if map.has_point(road[k]):
			if terrain.level_at(road[k].x, road[k].y) != 0:
				off_level += 1
			elif terrain.boundary_distance(road[k].x, road[k].y, 0, 12.0) < 12.0:
				near_cliff += 1
	check(step_ok, "the road is one connected polyline, a point every 12.5 m or less (worst gap %.1f m)" % worst)
	check(near_centre < 8.0, "the road runs through the village's middle (%.1f m from it)" % near_centre)
	eq(off_level, 0, "the road stays on level 0 (no point on high ground)")
	eq(near_cliff, 0, "and 12 m or more from every height boundary")
	eq(int(layout.diagnostics.get("road_crossings", -1)), 0, "diagnostics agree: no road crossings")
	var len_m := float(layout.diagnostics.get("road_length_m", 0.0))
	check(len_m > 400.0 and len_m < 6000.0, "the road is a road, %.0f m long" % len_m)

# Along the WHOLE road: every tree of the cells it crosses keeps its canopy's collision radius plus
# the road's half width from the middle, and the road's own index finds the road (a check that
# cannot pass by finding nothing).
func _road_trees(terrain: Terrain, vil: Variant) -> void:
	var p0: Dictionary = vil.road_pts[vil.road_pts.size() / 2]
	near(float(vil.road_dist(p0.x, p0.y)), 0.0, 1e-6, "the village's road index finds the road (distance on it)")
	near(float(vil.road_dist(p0.x + p0.nx * 30.0, p0.y + p0.ny * 30.0)), 30.0, 1e-3, "and 30 px off it")
	var seen := {}
	var near_n := 0
	var bad := 0
	var worst := INF
	for i in range(0, vil.road_pts.size(), 60):
		var p: Dictionary = vil.road_pts[i]
		var c := terrain.chunk_of(p.x / terrain.px_per_m, p.y / terrain.px_per_m)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var k := Vector2i(c.x + dx, c.y + dy)
				if seen.has(k):
					continue
				seen[k] = true
				for t: Dictionary in terrain.trees_in_chunk(k.x, k.y):
					var d: float = vil.road_dist(t.x, t.y)
					if d < INF:
						near_n += 1
						var margin := d - (terrain.P.ROAD_HALF + float(t.r) * terrain.P.tree_collision_radius)
						worst = minf(worst, margin)
						if margin < -1e-6:
							bad += 1
	check(near_n >= 100, "trees stand along the road, so the check bites (%d near it, %d cells)" % [near_n, seen.size()])
	eq(bad, 0, "no tree anywhere along the road is closer than its canopy's collision radius + the road's half width (worst margin %.2f px)" % worst)

# --- fields ---------------------------------------------------------------------------------------------------------------

func _fields(terrain: Terrain, layout: WorldLayout) -> void:
	var fields := layout.fields()
	check(fields.size() >= 6, "fields round the village (%d)" % fields.size())
	var map := Rect2(terrain.map_x, terrain.map_y, terrain.map_w, terrain.map_h)
	var road := layout.road()
	var site: Vector2 = layout.sites().radio_tower
	var vpoly: PackedVector2Array = layout.village().polygon
	var bad := 0
	for i in fields.size():
		var f := fields[i]
		var convex := true
		var sgn := 0.0
		for k in 4:
			var cr := (f[(k + 1) % 4] - f[k]).cross(f[(k + 2) % 4] - f[(k + 1) % 4])
			if sgn == 0.0:
				sgn = signf(cr)
			convex = convex and signf(cr) == sgn and cr != 0.0
		if not convex:
			bad += 1
			fail("field %d is not convex" % i)
		var c := (f[0] + f[1] + f[2] + f[3]) / 4.0
		for p in [f[0], f[1], f[2], f[3], c]:
			if not map.has_point(p) or terrain.level_at(p.x, p.y) != 0 or terrain.boundary_distance(p.x, p.y, 0, 25.0) < 25.0:
				bad += 1
				fail("field %d has a point on high ground, near a cliff or off the map: %s" % [i, p])
		if not Geometry2D.intersect_polygons(f, vpoly).is_empty():
			bad += 1
			fail("field %d overlaps the village" % i)
		if site.distance_to(c) < 78.0:
			bad += 1
			fail("field %d is inside the compound's reserve" % i)
		for p in road:
			if Geometry2D.is_point_in_polygon(p, f):
				bad += 1
				fail("field %d has the road through it" % i)
				break
		for j in range(i + 1, fields.size()):
			if not Geometry2D.intersect_polygons(f, fields[j]).is_empty():
				bad += 1
				fail("fields %d and %d overlap" % [i, j])
		var info := layout.field_info(i)
		check(int(info.kind) >= 0 and int(info.kind) < 4 and info.has("angle") and info.has("seed"), "field %d has a kind, a row angle and a seed" % i)
	eq(bad, 0, "%d fields: convex, on level 0 clear of cliffs, off the village, the road, the compound and each other" % fields.size())

# --- the cells' content ---------------------------------------------------------------------------------------------------------

func _cells(terrain: Terrain, layout: WorldLayout, vil: Variant) -> void:
	var cell_m := terrain.chunk_m
	var site: Vector2 = layout.sites().radio_tower
	var c := terrain.chunk_of(site.x, site.y)
	var block: Array[Vector2i] = []
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			block.append(c + Vector2i(dx, dy))
	var plain := Terrain.new(SEED)
	plain.use_layout = false
	var with_n := 0
	var without_n := 0
	var differing := 0
	var on_structs := 0
	var on_road := 0
	var on_field := 0
	var overlap := 0
	var house_n := 0
	var all: Array = []
	for cc in block:
		var a := terrain.trees_in_chunk(cc.x, cc.y)
		var b := plain.trees_in_chunk(cc.x, cc.y)
		with_n += a.size()
		without_n += b.size()
		if _sig(a) != _sig(b):
			differing += 1
		all.append_array(a)
		for t: Dictionary in a:
			for s: Dictionary in vil.structs:
				if vil._struct_dist(s, t.x, t.y) < 0.0:
					on_structs += 1
			if vil.road_dist(t.x, t.y) < terrain.P.ROAD_HALF:
				on_road += 1
			for f: Dictionary in vil.fields:
				if (f.rect as Rect2).has_point(Vector2(t.x, t.y)) and Geometry2D.is_point_in_polygon(Vector2(t.x, t.y), f.poly):
					on_field += 1
			if vil.blocks_tree(t.x, t.y, float(t.r) * terrain.P.tree_collision_radius):
				overlap += 1
	for s: Dictionary in vil.structs:
		if s.role == "house":
			house_n += 1
	var plain_blocked := 0
	for cc in block:
		for t: Dictionary in plain.trees_in_chunk(cc.x, cc.y):
			if vil.blocks_tree(t.x, t.y, float(t.r) * terrain.P.tree_collision_radius):
				plain_blocked += 1
	check(plain_blocked >= 20, "without the layout, trees DO stand on the village's ground (%d): the checks above can fail" % plain_blocked)
	print("[layout] the 5 x 5 cells round the tower: %d trees with the layout, %d without (%d of them on the village's ground); %d cells differ" % [with_n, without_n, plain_blocked, differing])
	check(house_n >= 10, "the cells round the village hold houses (%d)" % house_n)
	check(differing >= 2 and with_n < without_n, "the layout changes the cells round the village (fewer trees: %d against %d)" % [with_n, without_n])
	eq(on_structs, 0, "no tree stands on a house or a wall")
	eq(on_road, 0, "no tree stands on the road")
	eq(on_field, 0, "no tree stands in a field")
	eq(overlap, 0, "and the village's own clearance test finds none too close")
	# a cell far from the village: identical with and without the layout, whatever the order
	var far := _far_cells(terrain, layout, 4)
	var same := 0
	for fc in far:
		if _sig(terrain.trees_in_chunk(fc.x, fc.y)) == _sig(plain.trees_in_chunk(fc.x, fc.y)):
			same += 1
	eq(same, far.size(), "cells far from the village are exactly what they were without the layout (%d of %d)" % [same, far.size()])
	var map_rect := Rect2(terrain.map_x, terrain.map_y, terrain.map_w, terrain.map_h)
	check(map_rect.has_area() and cell_m > 0.0, "the map is real")
	# bake order: a fresh terrain asked for the village's cell alone == one asked for the whole block first
	var alone := Terrain.new(SEED)
	var crowd := Terrain.new(SEED)
	for cc in block:
		if cc != c:
			crowd.trees_in_chunk(cc.x, cc.y)
	check(_sig(alone.trees_in_chunk(c.x, c.y)) == _sig(crowd.trees_in_chunk(c.x, c.y)), "the village's cell alone == the cell among its neighbours (bake order changes nothing)")
	check(alone.village().structs.size() == vil.structs.size(), "and its structures are the same")

# The cells (terrain chunks) whose 3 x 3 neighbourhood is well clear of the village, the road and the fields: n of them.
func _far_cells(terrain: Terrain, layout: WorldLayout, n: int) -> Array[Vector2i]:
	var v := layout.village()
	var road := layout.road()
	var out: Array[Vector2i] = []
	var r := terrain.map_chunk_range()
	for cy in range(r.position.y, r.end.y, 3):
		for cx in range(r.position.x, r.end.x, 3):
			var rect := Rect2(Vector2(cx, cy) * terrain.chunk_m, Vector2.ONE * terrain.chunk_m).grow(terrain.chunk_m * 1.5)
			if rect.has_point(v.centre) or rect.grow(300.0).has_point(layout.sites().radio_tower):
				continue
			var hit := false
			for p in road:
				if rect.has_point(p):
					hit = true
					break
			for f in layout.fields():
				for q in f:
					hit = hit or rect.has_point(q)
			if not hit and out.size() < n:
				out.append(Vector2i(cx, cy))
	return out

static func _sig(list: Array) -> Array:
	var out: Array = []
	for o: Dictionary in list:
		out.append("%d|%.6f|%.6f|%.4f" % [int(o.seed), float(o.x), float(o.y), float(o.r)])
	out.sort()
	return out

# --- other seeds ------------------------------------------------------------------------------------------------------------------

func _other_seeds() -> void:
	var sigs := {}
	var t0 := Time.get_ticks_usec()
	for s in [SEED, SEED + 1, 7, 31337, 123456789]:
		var layout := WorldLayout.new(s)
		if not check(layout.ok(), "seed %d: the layout builds: %s" % [s, layout.errors]):
			continue
		sigs[layout.signature()] = s
		var terrain := Terrain.new(s)
		var site: Vector2 = layout.sites().radio_tower
		eq(terrain.level_at(site.x, site.y), 0, "seed %d: the tower is on level 0" % s)
		check(layout.in_village(site), "seed %d: the tower is inside its village" % s)
		eq((layout.sites().aa_battery as Array).size(), 2, "seed %d: two battery sites" % s)
		eq(int(layout.diagnostics.get("road_crossings", -1)) >= 0, true, "seed %d: the road reports its crossings (%s)" % [s, layout.diagnostics.get("road_crossings")])
		print("[layout] seed %d: village %s, tower %s, road %d m, %d crossings, %d fields, %.0f ms" % [s, layout.village().centre, site,
			roundi(layout.diagnostics.get("road_length_m", 0.0)), layout.diagnostics.get("road_crossings", -1), layout.field_count(), layout.diagnostics.get("build_ms", 0.0)])
	eq(sigs.size(), 5, "five seeds, five different plans")
	print("[layout] five more layouts: %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
