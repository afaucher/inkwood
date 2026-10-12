extends "res://scripts/test_support/test_case.gd"

# LINES OF FIRE, STAGE 1 (builder LOF1, 2026-10-11; decision line-of-fire): the height grid and the line check, headless. Nothing here is
# used by combat (data/sim/line_of_fire.json `enabled` is false; this test checks that nothing in the combat scripts names it).
#
#   DATA         the rules load; every unit has a shape whose materials exist; a tank is two boxes (hull to 1.5 m, turret to 2.3 m: Alex's
#                two layers), a vehicle that drives two, every other unit one; the bridge deck's height is bridges.json's crown.
#   THE GRID     the cells agree with the sources they are built from: the terrain's levels, the water's own query, a house's and a wall's
#                height (the structure's `h` over the scale), the canopies (the map's tree set). Built twice (the shared grid, and a fresh
#                water, terrain and grid) it is the same grid.
#   GEOMETRY     open ground is clear; a 1.35 m wall blocks a tank's hull and not its turret; a 24 m step blocks a 120 m plane exactly where the
#                arithmetic says (synthetic, and on a real scarp of the map); a stamped box can be unstamped.
#   TREES        a canopy's stop rate matches its data over many seeded lines, scales with the chord, and a line's answer is the same every
#                time, in any order, and does not touch the combat stream.
#   STATICS      the bridge's deck is stood on and stops a low line; the battery's sandbags stop a low line and not a high one; a down static unit
#                is unstamped.
#   TIMING       the time a check takes stays inside a budget (the measured numbers are printed as [lof] lines for the report).

const World = preload("res://scripts/sim/world.gd")
const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const HeightGrid = preload("res://scripts/sim/height_grid.gd")
const LineOfFire = preload("res://scripts/sim/line_of_fire.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")

const SEED := 20261009         # the Strike's map: the village, the river and its bridge, the sea
const SEED_BAY := 55           # Hold the bridge's: a bay of open water to lay synthetic geometry in

# The time budget of one check on this machine under the gate's load (microseconds): the measured mean is about a tenth of it.
const TRACE_BUDGET_US := 400.0
const EXPOSURE_BUDGET_MS := 8.0

var world: World
var rules: Rules
var grid: HeightGrid
var lof: LineOfFire
var tank_def: Variant

func setup(_main) -> void:
	timeout_seconds = 900.0
	world = World.new()
	world.quiet = true
	rules = Rules.new()
	if not check(rules.ok(), "data/sim/line_of_fire.json loads: %s" % [rules.errors]):
		finish()
		return
	tank_def = world.unit_def("tank")
	_data()
	var water := WaterGen.shared(SEED)
	grid = HeightGrid.shared(SEED, water)
	if not check(grid.ok(), "the grid of seed %d builds: %s" % [SEED, grid.errors]):
		finish()
		return
	lof = LineOfFire.new(grid)
	var t0 := Time.get_ticks_usec()
	_cells(water)
	print("[lof] cells checked in %.0f ms" % [(Time.get_ticks_usec() - t0) / 1000.0])
	_bay_geometry()
	_scarp()
	_trees()
	_statics()
	_brute_force()
	_robust()
	_determinism()
	_timing()
	_combat_untouched()
	print("[lof] test total %.0f ms" % [(Time.get_ticks_usec() - t0) / 1000.0])
	finish()

# --- data -------------------------------------------------------------------------------------------------

func _data() -> void:
	check(not rules.enabled, "stage 1: data/sim/line_of_fire.json enabled is false")
	for id in ["tank", "mobile_aa", "anti_aircraft_battery", "radio_tower", "military_complex", "bridge", "cruiser", "patrol_boat", "supply_boat", "light_fighter", "heavy_fighter", "bomber"]:
		var def: Variant = world.unit_def(id)
		if not check(def != null and def.ok(), "unit %s loads" % id):
			continue
		var boxes: Array = def.shape_boxes
		check(not boxes.is_empty(), "%s has a shape" % id)
		for b: Dictionary in boxes:
			check(rules.material_id(str(b["material"])) >= 0, "%s: box %s names a material of the data (%s)" % [id, b["part"], b["material"]])
		if id == "tank" or id == "mobile_aa":
			eq(boxes.size(), 2, "%s (a ground vehicle) is two boxes: hull and turret" % id)
			eq(str(boxes[0]["part"]), "hull", "%s: the lower box is the hull" % id)
			eq(str(boxes[1]["part"]), "turret", "%s: the upper box is the turret" % id)
			near(float(boxes[0]["top_m"]), float(boxes[1]["bottom_m"]), 1e-9, "%s: the turret stands on the hull" % id)
		elif id != "anti_aircraft_battery":
			eq(boxes.size(), 1, "%s is one box" % id)
	var tb: Array = tank_def.shape_boxes
	near(float(tb[0]["top_m"]), 1.5, 1e-9, "the tank's hull goes to 1.5 m")
	near(float(tb[1]["top_m"]), 2.3, 1e-9, "the tank's turret goes to 2.3 m")
	# the bridge deck is the crown of data/world/bridges.json (one number, two files)
	var bridges: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/bridges.json"))
	var crown := float(bridges["arch"]["crown_h"]["value"])
	var bdef: Variant = world.unit_def("bridge")
	near(float(bdef.shape_boxes[0]["top_m"]), crown, 1e-9, "the bridge unit's deck height is bridges.json arch.crown_h (%s)" % crown)
	check(bool(bdef.shape_boxes[0]["stamp"]) and bool(bdef.shape_boxes[0]["standable"]), "the deck stamps and can be stood on")
	var adef: Variant = world.unit_def("anti_aircraft_battery")
	eq(str(adef.shape_boxes[0]["kind"]), "ring", "the battery's first box is its sandbag ring")
	check(bool(adef.shape_boxes[0]["stamp"]) and not bool(adef.shape_boxes[1]["stamp"]), "the ring stamps, the guns inside it are a target")
	# a malformed shape is refused by the loader (the schema is strict)
	var bad := (JSON.parse_string(FileAccess.get_file_as_string("res://data/units/tank.json")) as Dictionary).duplicate(true)
	(bad["shape"]["boxes"][0] as Dictionary).erase("top_m")
	var UnitDef = load("res://scripts/sim/unit_def.gd")
	var broken: Variant = UnitDef.new(bad, world.rules.band_ids, true, "tank without top_m")
	check(not broken.ok(), "a shape box without a top is refused")

# --- the cells ----------------------------------------------------------------------------------------------

func _cells(water: RefCounted) -> void:
	var terrain: Object = grid.terrain
	var sites: Dictionary = terrain.layout().sites()
	var tower: Vector2 = sites["radio_tower"]
	var bridge: Vector2 = water.sites()["bridge"]["pos"]
	grid.build_rect(Rect2(tower.x - 260.0, tower.y - 260.0, 520.0, 520.0))
	grid.build_rect(Rect2(bridge.x - 130.0, bridge.y - 130.0, 260.0, 260.0))
	# 1. the terrain's levels, wherever no structure stands
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var agree := 0
	var total := 0
	var wet_agree := 0
	var wet_total := 0
	var wet_seen := 0
	for centre: Vector2 in [tower, bridge]:
		for i in 1500:
			var p := centre + Vector2(rng.randf_range(-250.0, 250.0), rng.randf_range(-250.0, 250.0))
			var mat := grid.material_at(p.x, p.y)
			var top := grid.top_at(p.x, p.y)
			var depth := float(water.depth_at(p.x, p.y))
			wet_total += 1
			if (depth > 0.0) == (mat == Rules.WATER):
				wet_agree += 1
			if mat == Rules.WATER:
				wet_seen += 1
			if mat == Rules.GROUND or mat == Rules.WATER:
				total += 1
				# a cell is 1 m, the level is asked at the cell's own middle: sample the middle
				var mx := floorf(p.x / grid.cell_m) * grid.cell_m + grid.cell_m * 0.5
				var my := floorf(p.y / grid.cell_m) * grid.cell_m + grid.cell_m * 0.5
				if absf(top - float(terrain.height_at(mx, my))) < 1e-4:
					agree += 1
	check(total > 1000, "enough open cells sampled (%d)" % total)
	check(float(agree) / float(total) > 0.9995, "the grid's tops are the terrain's levels (%d of %d cells)" % [agree, total])
	check(wet_seen > 50, "the samples include water (%d cells) so the water check is not vacuous" % wet_seen)
	check(float(wet_agree) / float(wet_total) > 0.995, "the grid's water is the sim's water (WaterGen.depth_at > 0) in %d of %d cells" % [wet_agree, wet_total])
	print("[lof] terrain agreement %d/%d, water agreement %d/%d (%d wet)" % [agree, total, wet_agree, wet_total, wet_seen])
	# 2. houses and walls: the structure's own height over the scale, at its own place
	var vil: Variant = terrain.village()
	var ppm := float(terrain.px_per_m)
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
				eq(grid.material_at(px, py), rules.house_material, "a house's middle is timber")
				near(grid.top_at(px, py), hm, 1e-3, "a house's middle is the house's height (%.2f m)" % hm)
		else:
			var pts: Array = s.pts
			var mid: Array = pts[pts.size() / 2]
			var wx := float(mid[0]) / ppm
			var wy := float(mid[1]) / ppm
			if absf(wx - tower.x) < 250.0 and absf(wy - tower.y) < 250.0:
				walls += 1
				eq(grid.material_at(wx, wy), rules.wall_material, "a wall's centre line is stone")
				near(grid.top_at(wx, wy), hm, 1e-3, "a wall's centre line is the wall's height (%.2f m)" % hm)
	check(houses >= 3 and walls >= 2, "the village has houses and walls to check (%d, %d)" % [houses, walls])
	# the height comes from the structure: a taller structure is a taller cell (a stand-in for the scenery-heights board)
	# 3. the canopies are the map's tree set, in metres
	var ctr: Vector2i = grid.chunk_of(tower.x, tower.y)
	var trees: Array = terrain.trees_in_chunk(ctr.x, ctr.y)
	check(not trees.is_empty(), "the tower's chunk has trees")
	var found := 0
	for t: Dictionary in trees.slice(0, 40):
		var near_c: Array = grid.canopies_near(float(t.x) / ppm, float(t.y) / ppm, 0.05)
		for c: Dictionary in near_c:
			if absf(c.x - float(t.x) / ppm) < 1e-6 and absf(c.y - float(t.y) / ppm) < 1e-6:
				found += 1
				near(c.r, float(t.r) / ppm, 1e-6, "a canopy's radius is the tree's")
				near(c.zt, float(t.base_m) + float(t.h) / ppm, 1e-6, "a canopy's top is the tree's height over the scale")
				break
	eq(found, mini(trees.size(), 40), "every tree is a canopy")
	# trees are not cells: the cell under a tree is ground
	var t0: Dictionary = trees[0]
	check(grid.material_at(float(t0.x) / ppm, float(t0.y) / ppm) != Rules.TREES, "a tree is not a cell")

# --- synthetic geometry in open water ------------------------------------------------------------------------

var bay := Vector2(3700.0, 3560.0)   # open water in Hold the bridge's bay, 1.5 km of it east (integer metres: the cell edges fall where the arithmetic says)

func _bay_geometry() -> void:
	var water := WaterGen.shared(SEED_BAY)
	var g: HeightGrid = HeightGrid.shared(SEED_BAY, water)
	var l := LineOfFire.new(g)
	g.build_rect(Rect2(bay.x - 20.0, bay.y - 60.0, 440.0, 120.0))
	# open and flat: a lattice over the strip is water at 0 m
	var flat := true
	for iy in range(0, 30):
		for ix in range(0, 100):
			if g.top_at(bay.x + ix * 4.0, bay.y - 55.0 + iy * 3.7) != 0.0 or g.material_at(bay.x + ix * 4.0, bay.y - 55.0 + iy * 3.7) != Rules.WATER:
				flat = false
	if not check(flat, "the bay corner at %s is flat open water, for the synthetic geometry" % bay):
		return
	var treeless := true
	for k in 41:
		if not g.canopies_near(bay.x + 10.0 * k, bay.y, 12.0).is_empty():
			treeless = false
	check(treeless, "no tree within 12 m of the bay strip")
	var rk := 1
	# 1. open ground is clear
	var r := l.trace_xyz(bay.x, bay.y, 1.5, bay.x + 300.0, bay.y + 20.0, 1.5, rk)
	check(bool(r["clear"]), "a level line over open water is clear")
	near(float(r["t"]), 1.0, 1e-12, "a clear line reaches its end")
	# a line laid exactly on the water is clear (no float noise decides a shot)
	check(bool(l.trace_xyz(bay.x, bay.y, 0.0, bay.x + 300.0, bay.y, 0.0, rk)["clear"]), "a line laid exactly on flat ground is clear")
	# below the ground it is stopped at once, on the water
	var sub := l.trace_xyz(bay.x, bay.y, -1.0, bay.x + 300.0, bay.y, -1.0, rk)
	check(not bool(sub["clear"]) and sub["material_name"] == "water", "a line under the surface stops on the water")
	# a line that comes down onto the water stops where it meets the surface
	var dive := l.trace_xyz(bay.x, bay.y, 10.0, bay.x + 100.0, bay.y, -10.0, rk)
	check(not bool(dive["clear"]), "a diving line meets the water")
	near(float(dive["x"]), bay.x + 50.0, 0.01, "a line from 10 m to -10 m over 100 m meets the surface at 50 m")
	near(float(dive["z"]), 0.0, 0.01, "... at height 0")
	# 2. the wall and the tank: hull and turret
	var shooter_x := bay.x
	var shooter_y := bay.y
	var target_x := bay.x + 101.0
	var muzzle := Shapes.muzzle(tank_def.weapons[0].hardpoints[0], shooter_x, shooter_y, 0.0, 0.0)
	near(muzzle[2], 2.3, 1e-6, "the tank's gun is at 2.3 m")
	var target := Shapes.world_boxes(tank_def, rules, target_x, shooter_y, PI, 0.0)
	var open := l.exposure_xyz(muzzle[0], muzzle[1], muzzle[2], target, 7)
	near(float(open["share"]), 1.0, 1e-12, "open water: the whole tank is in view")
	eq((open["boxes"] as Array).size(), 2, "the exposure reports hull and turret")
	eq(str(open["boxes"][0]["part"]), "hull", "the first box is the hull")
	print("[lof] a tank: hull %d lines (%d rows x %d columns), turret %d lines" % [open["boxes"][0]["samples"], open["boxes"][0]["rows"], open["boxes"][0]["cols"], open["boxes"][1]["samples"]])
	var wall := _box(bay.x + 95.0, shooter_y, 1.5, 10.0, 0.0, 1.35)
	g.stamp("test_wall", [wall])
	var cover := l.exposure_xyz(muzzle[0], muzzle[1], muzzle[2], target, 7)
	near(float(cover["boxes"][0]["share"]), 0.0, 1e-12, "a 1.35 m wall in front of a tank blocks its whole hull")
	near(float(cover["boxes"][1]["share"]), 1.0, 1e-12, "... and none of its turret")
	check(cover["visible"] and float(cover["share"]) > 0.0 and float(cover["share"]) < 1.0, "hull-down: the tank is partly in view (share %.2f)" % float(cover["share"]))
	var first_line: Dictionary = cover["boxes"][0]["lines"][0]
	check(not bool(first_line["reach"]) and first_line["stop"]["material_name"] == "stone" and first_line["stop"]["kind"] == "cell", "a stopped hull line says what stopped it: a stone cell")
	near(float(first_line["stop"]["top"]), 1.35, 1e-4, "... the wall's top, 1.35 m")
	# a wall the height of the whole tank hides it; a wall as tall as the turret hides it
	g.stamp("test_wall", [_box(bay.x + 95.0, shooter_y, 1.5, 10.0, 0.0, 2.6)])
	var tall := l.exposure_xyz(muzzle[0], muzzle[1], muzzle[2], target, 7)
	near(float(tall["share"]), 0.0, 1e-12, "a 2.6 m wall hides the whole tank")
	check(not bool(tall["visible"]), "... and a target with no line is not visible (a gun holds)")
	g.unstamp("test_wall")
	near(float(l.exposure_xyz(muzzle[0], muzzle[1], muzzle[2], target, 7)["share"]), 1.0, 1e-12, "unstamped, the wall is gone")
	eq(g.stamped_owners().size(), 0, "no stamp is left")
	# 3. a 24 m step against a 120 m plane: blocked exactly where the arithmetic says. The step is 3 m ahead of the gun.
	g.stamp("test_step", [_box(bay.x + 3.0 + 100.0, bay.y, 100.0, 40.0, 0.0, 24.0)])
	var sy := bay.y
	var frac := (24.0 - 2.3) / (120.0 - 2.3)
	var d_edge := 3.0 / frac
	print("[lof] a 24 m step 3 m ahead of a gun at 2.3 m blocks a plane at 120 m when it is farther than %.2f m" % d_edge)
	for dist in [10.0, 14.0, 16.0, 17.0, 20.0, 60.0, 100.0]:
		var rr := l.trace_xyz(bay.x, sy, 2.3, bay.x + dist, sy, 120.0, rk)
		var expect_blocked: bool = dist > d_edge
		eq(not bool(rr["clear"]), expect_blocked, "a plane at 120 m, %.0f m off: %s by a 24 m step 3 m ahead" % [dist, "blocked" if expect_blocked else "clear"])
		if expect_blocked:
			near(float(rr["x"]), bay.x + 3.0, 0.01, "... and stopped at the step's face")
	# the plane and a lower hill: 12 m
	g.stamp("test_step", [_box(bay.x + 3.0 + 100.0, sy, 100.0, 40.0, 0.0, 12.0)])
	var d12 := 3.0 / ((12.0 - 2.3) / (120.0 - 2.3))
	check(not bool(l.trace_xyz(bay.x, sy, 2.3, bay.x + d12 + 1.0, sy, 120.0, rk)["clear"]), "a 12 m hill blocks a plane farther than %.1f m" % d12)
	check(bool(l.trace_xyz(bay.x, sy, 2.3, bay.x + d12 - 1.0, sy, 120.0, rk)["clear"]), "... and not a nearer one")
	# a plane at 120 m over a 24 m step it never crosses
	check(bool(l.trace_xyz(bay.x + 200.0, sy, 120.0, bay.x + 400.0, sy, 120.0, rk)["clear"]), "a plane flying level at 120 m passes over a 12 m hill")
	g.unstamp("test_step")
	# 4. stamps on a chunk border, and a stamp laid before its chunk exists is applied when the chunk is built
	var edge_x := floorf(bay.x / 256.0 + 1.0) * 256.0
	g.stamp("test_edge", [_box(edge_x, bay.y - 40.0, 6.0, 6.0, 0.0, 3.0)])
	near(g.top_at(edge_x - 2.0, bay.y - 40.0), 3.0, 1e-6, "a stamp across a chunk border is on both sides (west)")
	near(g.top_at(edge_x + 2.0, bay.y - 40.0), 3.0, 1e-6, "... (east)")
	g.unstamp("test_edge")
	near(g.top_at(edge_x - 2.0, bay.y - 40.0), 0.0, 1e-6, "an unstamped border is flat again")

# A synthetic world box (a wall, a step) for the stamp layer.
func _box(cx: float, cy: float, half_l: float, half_w: float, z0: float, z1: float) -> Dictionary:
	return {"part": "test", "material": Rules.STONE, "material_name": "stone", "kind": "box", "stamp": true, "standable": false,
		"cx": cx, "cy": cy, "cs": 1.0, "sn": 0.0, "hl": half_l, "hw": half_w, "ro": 0.0, "ri": 0.0, "z0": z0, "z1": z1}

# --- a real scarp, a real plane --------------------------------------------------------------------------------

func _scarp() -> void:
	var terrain: Object = grid.terrain
	var tower: Vector2 = terrain.layout().sites()["radio_tower"]
	grid.build_rect(Rect2(tower.x - 800.0, tower.y - 800.0, 1600.0, 1600.0))
	var found: Dictionary = _find_scarp(Rect2i(grid.chunk_of(tower.x - 800.0, tower.y - 800.0), Vector2i(7, 7)))
	if not check(not found.is_empty(), "a scarp (0 m to a plateau, flat both sides, no tree) is found round the village for the real-terrain check"):
		return
	var cx0: float = found["x"]
	var cy0: float = found["y"]
	var H: float = found["h"]
	var gx := cx0 - 3.0         # the gun, 3 m before the scarp's foot
	var frac := (H - 2.3) / (120.0 - 2.3)
	var d_edge := 3.0 / frac
	print("[lof] a real scarp of %.0f m at (%.0f, %.0f): a plane at 120 m is blocked beyond %.1f m" % [H, cx0, cy0, d_edge])
	for dist in [d_edge * 0.5, d_edge * 0.9, d_edge * 1.1, d_edge * 2.0, d_edge * 5.0]:
		var rr := lof.trace_xyz(gx, cy0, 2.3, gx + dist, cy0, 120.0, 3)
		var expect_blocked: bool = dist > d_edge
		eq(not bool(rr["clear"]), expect_blocked, "a real %.0f m scarp: a plane %.1f m off is %s" % [H, dist, "blocked" if expect_blocked else "clear"])
		if expect_blocked and not bool(rr["clear"]):
			check(rr["kind"] == "cell" and absf(float(rr["top"]) - H) < 1e-4, "... by the scarp's cell, %.0f m high" % H)
	# the same plane over the plateau, looking down at a gun on the plateau's edge: nothing stands between
	check(bool(lof.trace_xyz(cx0 + 20.0, cy0, H + 2.3, cx0 + 80.0, cy0, 120.0, 3)["clear"]), "a gun on the plateau sees a plane above it")

# A scarp on a row: 12 low cells at 0 m, then 50 cells at one plateau height, no canopy within 25 m of the foot. Returns {x, y, h} (the foot's x).
func _find_scarp(chunks: Rect2i) -> Dictionary:
	var n := grid.n
	var c := grid.cell_m
	for cy in range(chunks.position.y, chunks.end.y):
		for cx in range(chunks.position.x, chunks.end.x):
			var ch = grid.chunk_at(cx, cy)
			if ch.uniform:
				continue
			for iy in range(2, n - 2, 3):
				var ix := 14
				while ix < n - 60:
					var up: float = ch.h[iy * n + ix]
					if up > 5.0 and ch.h[iy * n + ix - 1] == 0.0:
						var ok := true
						for k in range(0, 50):
							if ch.h[iy * n + ix + k] != up:
								ok = false
								break
						if ok:
							for k in range(1, 13):
								if ch.h[iy * n + ix - k] != 0.0 or (ch.m[iy * n + ix - k] & Rules.MATERIAL_MASK) != Rules.GROUND:
									ok = false
									break
						if ok:
							var fx := float(cx) * grid.chunk_m + float(ix) * c
							var fy := float(cy) * grid.chunk_m + (float(iy) + 0.5) * c
							if grid.canopies_near(fx - 10.0, fy, 25.0).is_empty() and grid.canopies_near(fx + 20.0, fy, 25.0).is_empty():
								return {"x": fx, "y": fy, "h": up}
					ix += 1
	return {}

# --- trees -------------------------------------------------------------------------------------------------------

func _trees() -> void:
	var terrain: Object = grid.terrain
	var tower: Vector2 = terrain.layout().sites()["radio_tower"]
	# a canopy no other crown comes within 3 m of, so a line along its own chord meets nothing else
	var pick := -1
	var best_r := 0.0
	for id in grid.canopy_count():
		var x := grid.can_x[id]
		var y := grid.can_y[id]
		if absf(x - tower.x) > 400.0 or absf(y - tower.y) > 400.0 or grid.can_r[id] < 8.0:
			continue
		if grid.can_r[id] > best_r and grid.canopies_near(x, y, grid.can_r[id] + 3.0).size() == 1:
			pick = id
			best_r = grid.can_r[id]
	if not check(pick >= 0, "a canopy with no neighbour within 3 m is found round the village for the stop-rate check"):
		return
	var cn: Dictionary = grid.canopy(pick)
	var zmid: float = (float(cn.zb) + float(cn.zt)) * 0.5
	var r: float = cn.r
	var reach: float = r + 1.0
	print("[lof] canopy %d: r %.1f m, band %.1f to %.1f m, stop chance %s (chord scaled %s)" % [pick, r, cn.zb, cn.zt, rules.stop_chance, rules.scale_by_chord])
	var n := 6000
	var stops := 0
	var stops_off := 0
	var wrong := 0
	for k in n:
		# through the middle: the full diameter
		var a := lof.trace_xyz(cn.x - reach, cn.y, zmid, cn.x + reach, cn.y, zmid, k)
		if not bool(a["clear"]):
			if a["kind"] == "canopy" and int(a["canopy"]) == pick:
				stops += 1
			else:
				wrong += 1
		# half a radius off the middle: a chord of 0.866 of the diameter
		var yo: float = cn.y + 0.5 * r
		var xo: float = sqrt(reach * reach - 0.25 * r * r)
		var b := lof.trace_xyz(cn.x - xo, yo, zmid, cn.x + xo, yo, zmid, k)
		if not bool(b["clear"]) and b["kind"] == "canopy" and int(b["canopy"]) == pick:
			stops_off += 1
	eq(wrong, 0, "nothing but the canopy stops a line along its chord")
	var p0: float = rules.stop_chance
	var tol := 4.0 * sqrt(p0 * (1.0 - p0) / float(n))
	near(float(stops) / float(n), p0, tol, "a line through a canopy's middle is stopped at the data's rate (%d of %d)" % [stops, n])
	if rules.scale_by_chord:
		var p1 := p0 * sqrt(1.0 - 0.25)
		near(float(stops_off) / float(n), p1, 4.0 * sqrt(p1 * (1.0 - p1) / float(n)), "a line half a radius off the middle is stopped at %.3f (%d of %d)" % [p1, stops_off, n])
	# a flat chance per canopy (Alex's words, literally) when the data says so
	var flat_rules := _rules_with({"canopy": {"scale_by_chord": false}})
	var flat_lof := LineOfFire.new(grid, flat_rules)
	var flat_stops := 0
	for k in n:
		var c := flat_lof.trace_xyz(cn.x - xo_of(reach, r), cn.y + 0.5 * r, zmid, cn.x + xo_of(reach, r), cn.y + 0.5 * r, zmid, k)
		if not bool(c["clear"]):
			flat_stops += 1
	near(float(flat_stops) / float(n), p0, tol, "with scale_by_chord off every canopy a line meets stops it at stop_chance (%d of %d)" % [flat_stops, n])
	# the same line and key give the same answer, whatever was traced in between
	var first := lof.trace_xyz(cn.x - reach, cn.y, zmid, cn.x + reach, cn.y, zmid, 12345)
	for k in 50:
		lof.trace_xyz(cn.x - reach, cn.y + 1.0, zmid, cn.x + reach, cn.y + 1.0, zmid, k)
	var again := lof.trace_xyz(cn.x - reach, cn.y, zmid, cn.x + reach, cn.y, zmid, 12345)
	eq(JSON.stringify(first), JSON.stringify(again), "the same line and roll key give the same answer, whatever came between")
	# the rolls have their own stream: the engine's global random numbers are not drawn from
	seed(0)
	var s0 := randi()
	for k in 200:
		lof.trace_xyz(cn.x - reach, cn.y, zmid, cn.x + reach, cn.y, zmid, k)
	seed(0)
	eq(randi(), s0, "tracing draws nothing from the engine's random numbers")
	# a line over a crown or under its band passes the canopy
	check(bool(lof.trace_xyz(cn.x - reach, cn.y, float(cn.zt) + 1.0, cn.x + reach, cn.y, float(cn.zt) + 1.0, 1)["clear"]), "a line over a crown is clear")
	# the stop is where the line enters the crown, the near side
	for k in 40:
		var s := lof.trace_xyz(cn.x - reach, cn.y, zmid, cn.x + reach, cn.y, zmid, k)
		if not bool(s["clear"]):
			near(float(s["x"]), cn.x - r, 0.01, "a stopped line stops where it enters the crown")
			break

# The x offset of a chord half a radius off the middle for a line of half-length `reach` (see _trees).
func xo_of(reach: float, r: float) -> float:
	return sqrt(reach * reach - 0.25 * r * r)

# The rules of the data with some values replaced: {"section": {"key": value}}.
func _rules_with(changes: Dictionary) -> Rules:
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Rules.PATH))
	for sec: String in changes:
		for key: String in changes[sec]:
			(raw[sec][key] as Dictionary)["value"] = changes[sec][key]
	return Rules.new(raw)

# --- the static units -------------------------------------------------------------------------------------------

func _statics() -> void:
	var w := TankWorlds.world()
	var water := TankWorlds.water()
	var g: HeightGrid = HeightGrid.shared(SEED, water)
	var l := LineOfFire.new(g)
	# the cover alone: the same grid, the trees off (a crown's chance would decide some of the lines)
	var l0 := LineOfFire.new(g, _rules_with({"canopy": {"stop_chance": 0.0}}))
	var b: Dictionary = TankWorlds.bridge_site()
	var bp: Vector2 = b["pos"]
	var hd := float(b["heading"])
	g.build_rect(Rect2(bp.x - 60.0, bp.y - 60.0, 120.0, 120.0))
	var crown := 6.5
	near(g.stand_z(bp.x, bp.y), 0.0, 1e-6, "before the bridge is stamped a unit at the crossing stands on the river's 0 m")
	var n := g.sync_statics(w.units)
	check(n >= 1, "sync_statics stamps the World's static units (%d)" % n)
	eq(g.sync_statics(w.units), 0, "... and a second sync changes nothing")
	near(g.stand_z(bp.x, bp.y), crown, 1e-6, "a unit on the bridge stands on the deck (%s m)" % crown)
	check(g.is_deck(bp.x, bp.y), "... the cell is a deck")
	eq(g.material_at(bp.x, bp.y), Rules.STONE, "... of stone")
	# the deck's footprint is 40 m along the road and 16 across
	var along := Vector2(cos(hd), sin(hd))
	var across := Vector2(-sin(hd), cos(hd))
	near(g.top_at(bp.x + along.x * 19.0, bp.y + along.y * 19.0), crown, 1e-6, "the deck reaches 19 m along the road")
	near(g.top_at(bp.x + along.x * 22.0, bp.y + along.y * 22.0), g.top_at(bp.x + along.x * 40.0, bp.y + along.y * 40.0), 7.0, "... and not 22 m")
	check(g.top_at(bp.x + across.x * 12.0, bp.y + across.y * 12.0) < crown, "... nor 12 m across")
	# a low line across the deck is stopped by it; one above it passes
	var from := bp - along * 30.0
	var to := bp + along * 30.0
	var low := l.trace_xyz(from.x, from.y, 3.0, to.x, to.y, 3.0, 1)
	check(not bool(low["clear"]) and low["material_name"] == "stone" and bool(low["deck"]), "a line at 3 m along the bridge hits the deck's stone")
	check(bool(l.trace_xyz(from.x, from.y, 12.0, to.x, to.y, 12.0, 1)["clear"]), "a line at 12 m passes over the deck")
	# the bridge as a target: its deck is its only box and stamps, so the lines are drawn to a metre and a half short of its face
	var bx := Shapes.world_boxes(world.unit_def("bridge"), rules, bp.x, bp.y, hd, 0.0)
	var gun_at := bp - along * 70.0
	var bex := l0.exposure_xyz(gun_at.x, gun_at.y, 2.3, bx, 1)
	near(float(bex["share"]), 1.0, 1e-12, "a gun 70 m down the road sees the whole bridge")
	# a tank on the deck: its base is the deck
	var base := l.base_z(bp.x, bp.y, 0.0, "terrain")
	near(base, crown, 1e-6, "a surface unit on the bridge has the deck as its base")
	near(l.base_z(bp.x, bp.y, 120.0, "sea_level"), 120.0, 1e-9, "a plane's base is its band's absolute height")
	# the bridge destroyed: its deck goes
	(w.units["bridge_1"] as Object).down = true
	g.sync_statics(w.units)
	near(g.stand_z(bp.x, bp.y), 0.0, 1e-6, "a destroyed bridge is no deck")
	(w.units["bridge_1"] as Object).down = false
	# the battery
	var sites: Dictionary = g.terrain.layout().sites()
	var bat: Vector2 = (sites["aa_battery"] as Array)[0]
	g.build_rect(Rect2(bat.x - 40.0, bat.y - 40.0, 80.0, 80.0))
	w.add_unit({"id": "aa_1", "type": "anti_aircraft_battery", "side": "side_b", "controller": "ai", "x": bat.x, "y": bat.y, "heading": 0.0})
	g.sync_statics(w.units)
	var gz := g.stand_z(bat.x, bat.y)
	near(gz, 0.0, 1e-6, "the battery site is on the low ground")
	# the ring: 8 m outer, 6 m inner diameter, 1.15 m of bags
	near(g.top_at(bat.x + 3.5, bat.y), gz + 1.15, 1e-4, "the sandbag ring is 1.15 m high at 3.5 m from the middle")
	eq(g.material_at(bat.x + 3.5, bat.y), Rules.EARTHWORKS, "... of earthworks")
	near(g.top_at(bat.x, bat.y), gz, 1e-4, "... and the ground inside it is open")
	near(g.top_at(bat.x + 5.5, bat.y), gz, 1e-4, "... and outside")
	near(g.stand_z(bat.x + 3.5, bat.y), gz, 1e-4, "a vehicle over the sandbags stands on the ground there")
	var def_bat: Variant = w.unit_def("anti_aircraft_battery")
	# a tank behind the ring: a low line stopped, a turret-high line over it
	var gunner_x := bat.x - 40.0
	var tank_x := bat.x + 7.5
	var muzzle := Shapes.muzzle(tank_def.weapons[0].hardpoints[0], gunner_x, bat.y, 0.0, gz)
	var tgt := Shapes.world_boxes(tank_def, rules, tank_x, bat.y, PI, gz)
	var ex := l0.exposure_xyz(muzzle[0], muzzle[1], muzzle[2], tgt, 3)
	print("[lof] a tank 7.5 m behind a battery's ring, shot from 47 m: hull %.2f, turret %.2f" % [ex["boxes"][0]["share"], ex["boxes"][1]["share"]])
	# bags 1.15 m, the hull's rows at 0.25, 0.75 and 1.25 m: the top row clears them. The turret is over them.
	near(float(ex["boxes"][0]["share"]), 1.0 / 3.0, 0.01, "a tank behind the sandbags: only the hull's top row shows")
	near(float(ex["boxes"][1]["share"]), 1.0, 1e-12, "... the whole turret shows")
	check(ex["boxes"][0]["lines"][0]["stop"]["material_name"] == "earthworks", "... and a stopped hull line says earthworks")
	# the battery as a target: its guns are the target, the ring is its cover
	var gun_t := Shapes.world_boxes(def_bat, rules, bat.x, bat.y, 0.0, gz)
	var exb := l0.exposure_xyz(muzzle[0], muzzle[1], muzzle[2], gun_t, 3)
	eq((exb["boxes"] as Array).size(), 1, "the battery's target boxes are its guns, the ring is cover")
	var gshare := float(exb["boxes"][0]["share"])
	check(gshare > 0.0 and gshare < 1.0, "the guns show over the ring but not whole (%.2f)" % gshare)
	# the ring destroyed
	(w.units["aa_1"] as Object).down = true
	g.sync_statics(w.units)
	near(g.top_at(bat.x + 3.5, bat.y), gz, 1e-4, "a destroyed battery's ring is gone")

# --- the walk against a brute-force look, and the edge cases --------------------------------------------------------------

# The block and cell walk against a plain sampling of the same line every 10 cm (the trees off): a line the walk calls clear never has a
# sample inside an obstacle (a miss), and where both stop they stop at the same place. A line that only clips the corner of a cell
# may stop the walk and not the samples: a few are allowed, counted and printed.
func _brute_force() -> void:
	var tower: Vector2 = grid.terrain.layout().sites()["radio_tower"]
	grid.build_rect(Rect2(tower.x - 330.0, tower.y - 330.0, 660.0, 660.0))
	var l0 := LineOfFire.new(grid, _rules_with({"canopy": {"stop_chance": 0.0}}))
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var lines := 700
	var both_clear := 0
	var both_stop := 0
	var walk_only := 0
	var misses := 0
	var off := 0
	for i in lines:
		var a := rng.randf() * TAU
		var length := rng.randf_range(20.0, 150.0)
		var p := tower + Vector2(rng.randf_range(-170.0, 170.0), rng.randf_range(-170.0, 170.0))
		var q := p + Vector2(cos(a), sin(a)) * length
		var z0 := rng.randf_range(0.4, 15.0)
		var z1 := z0 if i % 3 == 0 else rng.randf_range(0.4, 15.0)
		var r := l0.trace_xyz(p.x, p.y, z0, q.x, q.y, z1, i)
		# the samples
		var steps := int(length / 0.1)
		var hit_d := -1.0
		for k in range(0, steps + 1):
			var f := float(k) / float(steps)
			var x := p.x + (q.x - p.x) * f
			var y := p.y + (q.y - p.y) * f
			var z := z0 + (z1 - z0) * f
			if z < grid.top_at(x, y) - 1e-4:
				hit_d = f * length
				break
		var walked := not bool(r["clear"])
		if not walked and hit_d < 0.0:
			both_clear += 1
		elif walked and hit_d >= 0.0:
			both_stop += 1
			if absf(float(r["t"]) * length - hit_d) > 0.12:
				off += 1
		elif walked:
			walk_only += 1
		else:
			misses += 1
	print("[lof] walk vs samples: %d clear both, %d stopped both (%d at a different place), %d stopped by the walk only (corner clips), %d missed" % [both_clear, both_stop, off, walk_only, misses])
	eq(misses, 0, "the walk never calls a line clear that a 10 cm sampling finds inside an obstacle")
	eq(off, 0, "where both stop, they stop at the same place (within 12 cm)")
	check(walk_only <= lines / 100, "the walk stops a line the samples do not for corner clips only (%d of %d)" % [walk_only, lines])
	check(both_stop > 100 and both_clear > 100, "the lines include plenty of both kinds (%d stopped, %d clear)" % [both_stop, both_clear])

func _robust() -> void:
	var l := lof
	var nan := NAN
	var bad := l.trace_xyz(nan, 0.0, 1.0, 10.0, 0.0, 1.0, 1)
	check(not bool(bad["clear"]) and bad["kind"] == "invalid", "a line with a point that is not a number is refused, not walked")
	check(not bool(l.trace_xyz(0.0, 0.0, 1.0, INF, 0.0, 1.0, 1)["clear"]), "... and one to infinity")
	# a line with no length: a point in the air is clear, a point in the ground is stopped
	var tower: Vector2 = grid.terrain.layout().sites()["radio_tower"]
	check(bool(l.trace_xyz(tower.x, tower.y, 500.0, tower.x, tower.y, 500.0, 1)["clear"]), "a point in the air is clear")
	check(not bool(l.trace_xyz(tower.x, tower.y, -5.0, tower.x, tower.y, -5.0, 1)["clear"]), "a point under the ground is stopped")
	check(bool(l.trace_xyz(tower.x, tower.y, 500.0, tower.x, tower.y, 5.0, 1)["clear"]), "a straight-down line that ends above the ground is clear")
	var down := l.trace_xyz(tower.x, tower.y, 500.0, tower.x, tower.y, -5.0, 1)
	check(not bool(down["clear"]), "a straight-down line that ends under the ground is stopped")
	near(float(down["z"]), 0.0, 0.05, "... at the ground")
	# a line off the map is over flat ground at 0 m
	check(bool(l.trace_xyz(-500.0, -500.0, 3.0, -300.0, -450.0, 3.0, 1)["clear"]), "off the map the ground is flat")
	check(bool(l.trace_xyz(9000.0, 9000.0, 3.0, 9100.0, 9100.0, 3.0, 1)["clear"]), "... far off it too")
	# a stamp laid before its chunk exists is applied when the chunk is built
	var water := WaterGen.shared(SEED_BAY)
	var g: HeightGrid = HeightGrid.shared(SEED_BAY, water)
	var spot := Vector2.ZERO
	for k in 40:
		var p := Vector2(600.0 + 97.0 * k, 700.0 + 61.0 * k)
		var cc := g.chunk_of(p.x, p.y)
		if not g.is_built(cc.x, cc.y) and float(g.terrain.height_at(p.x, p.y)) == 0.0 and float(g.terrain.height_at(p.x + 4.0, p.y)) == 0.0:
			spot = p
			break
	if not check(spot != Vector2.ZERO, "an unbuilt chunk on low ground is found for the late-stamp check"):
		return
	var cc2 := g.chunk_of(spot.x, spot.y)
	g.stamp("test_late", [_box(spot.x, spot.y, 2.0, 2.0, 0.0, 3.0)])
	check(not g.is_built(cc2.x, cc2.y), "stamping does not build a chunk")
	near(g.top_at(spot.x, spot.y), 3.0, 1e-6, "a stamp laid before its chunk was built is there once it is")
	g.unstamp("test_late")
	near(g.top_at(spot.x, spot.y), 0.0, 1e-6, "and gone again when it is taken out")

# --- the same grid, built again ---------------------------------------------------------------------------------------

func _determinism() -> void:
	var tower: Vector2 = grid.terrain.layout().sites()["radio_tower"]
	var rect := Rect2(tower.x - 130.0, tower.y - 130.0, 260.0, 260.0)
	var t0 := Time.get_ticks_usec()
	var sig_a := grid.signature(rect)
	# a fresh water, a fresh terrain, a fresh grid: nothing shared with the first
	var w2 := WaterGen.new(SEED)
	check(w2.ok(), "a second water of the seed builds")
	var terrain2: Object = w2.make_terrain()
	var grid2 := HeightGrid.new(terrain2, w2)
	var sig_b := grid2.signature(rect)
	eq(sig_a, sig_b, "the grid is the same built twice, from a second water and a second terrain")
	print("[lof] determinism: %d chunks twice in %.0f ms" % [grid.built_count(), (Time.get_ticks_usec() - t0) / 1000.0])
	# and on a second World of the seed
	var wa := TankWorlds.world()
	var wb := TankWorlds.world()
	var ga: HeightGrid = HeightGrid.shared(SEED, TankWorlds.water())
	eq(ga.signature(rect), sig_b, "a World of the seed sees the same grid")
	wa.quiet = wb.quiet
	# a different seed is a different map
	var other: HeightGrid = HeightGrid.shared(SEED_BAY, WaterGen.shared(SEED_BAY))
	check(other.signature(rect) != sig_a, "another seed is another map")

# --- timing -----------------------------------------------------------------------------------------------------------

func _timing() -> void:
	var tower: Vector2 = grid.terrain.layout().sites()["radio_tower"]
	grid.build_rect(Rect2(tower.x - 700.0, tower.y - 700.0, 1400.0, 1400.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var count := 1500
	for spec in [["a tank-high line, 300 m", 2.3, 2.3, 300.0], ["a low-band plane, 350 m", 2.3, 120.0, 350.0]]:
		lof.reset_counters()
		var t0 := Time.get_ticks_usec()
		var stopped := 0
		for i in count:
			var a := rng.randf() * TAU
			var p := tower + Vector2(rng.randf_range(-200.0, 200.0), rng.randf_range(-200.0, 200.0))
			var q := p + Vector2(cos(a), sin(a)) * float(spec[3])
			var r := lof.trace_xyz(p.x, p.y, float(spec[1]), q.x, q.y, float(spec[2]), i)
			if not bool(r["clear"]):
				stopped += 1
		var us := (Time.get_ticks_usec() - t0) / float(count)
		print("[lof] %s: %.1f us a check (%d of %d stopped; %.1f blocks, %.1f cells a check)" % [spec[0], us, stopped, count, float(lof.blocks_walked) / count, float(lof.cells_walked) / count])
		check(us < TRACE_BUDGET_US, "%s: %.1f us a check is inside the budget of %.0f us" % [spec[0], us, TRACE_BUDGET_US])
	# an exposure: a tank against a tank across the village
	var gz := 0.0
	var tdef: Variant = tank_def
	var m := Shapes.muzzle(tdef.weapons[0].hardpoints[0], tower.x - 150.0, tower.y, 0.0, gz)
	var tgt := Shapes.world_boxes(tdef, rules, tower.x + 150.0, tower.y + 20.0, PI, gz)
	var t1 := Time.get_ticks_usec()
	var lines := 0
	var reps := 200
	for i in reps:
		var e := lof.exposure_xyz(m[0], m[1], m[2], tgt, i, false)
		lines += int(e["boxes"][0]["samples"]) + int(e["boxes"][1]["samples"])
	var ms := (Time.get_ticks_usec() - t1) / 1000.0 / float(reps)
	print("[lof] an exposure of a tank (%d lines): %.2f ms" % [lines / reps, ms])
	check(ms < EXPOSURE_BUDGET_MS, "an exposure takes %.2f ms, inside the budget of %.0f ms" % [ms, EXPOSURE_BUDGET_MS])
	print("[lof] memory %s" % [grid.stats()])

# --- nothing in combat reads it ------------------------------------------------------------------------------------------

func _combat_untouched() -> void:
	var dir := DirAccess.open("res://scripts/sim")
	var readers := 0
	for f in dir.get_files():
		if f.ends_with(".gd") and (f.begins_with("combat") or f.begins_with("bomb") or f.begins_with("gun") or f.begins_with("ai_") or f.begins_with("world") or f.begins_with("spotting") or f.begins_with("mission")):
			var src := FileAccess.get_file_as_string("res://scripts/sim/" + f)
			if src.contains("line_of_fire") or src.contains("height_grid"):
				readers += 1
				print("[lof] reads the line of fire: ", f)
	eq(readers, 0, "stage 1: no combat, bomb, gun, AI, spotting, mission or World script reads the line-of-fire files (combat is untouched)")
