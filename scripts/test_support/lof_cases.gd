extends RefCounted

# THE PROBE SCENES FOR THE LINE-OF-FIRE PROOFS (builder LOF1, stage 1 of the lines of fire, 2026-10-11). Units placed on the REAL maps
# with World.add_unit (the Strike's seed 20261009 and Hold the bridge's seed 55), their real data, the real grid; no scenario file is
# touched. Each case builds a World, stamps its static units into the grid, traces the shooter's gun to the target's sample points, and
# returns everything the side view needs (scripts/render/boards/lof_section.gd draws it; scripts/app/lof_shot.gd saves it):
#
#   a  a tank against a tank across the bridge (Hold the bridge): both on the ground at the two ends, and both on the deck
#   b  a tank behind a house (the Strike's village)
#   c  a tank behind the anti-aircraft battery's sandbags (the Strike)
#   d  a low-band plane behind a hill (the Strike): a gun at the foot of a scarp, a plane before and a plane beyond the blocked distance
#
# A CASE is {title, notes: [String], grid, lof, shooter: {id, x, y, z (the muzzle), name}, shooter_boxes, targets: [{id, label, x, y, boxes,
# exposure}], hscale, vscale, z_lo, z_hi, roll_key}. Helpers go in test_support, which the gate does not run.

const World = preload("res://scripts/sim/world.gd")
const HeightGrid = preload("res://scripts/sim/height_grid.gd")
const LineOfFire = preload("res://scripts/sim/line_of_fire.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")

const STRIKE := 20261009
const BRIDGE := 55
const ROLL_KEY := 1

# A World with the seed's water and ground, a player, and the grid with its static units stamped as they are added.
class ProbeScene:
	var seed_value: int
	var water: RefCounted
	var ground: RefCounted
	var grid: HeightGrid
	var lof: LineOfFire
	var world: World
	var build_ms := 0.0

	func _init(seed_v: int) -> void:
		var t0 := Time.get_ticks_usec()
		seed_value = seed_v
		water = WaterGen.shared(seed_v)
		ground = GroundMap.shared(seed_v, water)
		grid = HeightGrid.shared(seed_v, water)
		lof = LineOfFire.new(grid)
		world = World.new()
		world.quiet = true
		world.set_water(Callable(water, "depth_at"))
		ground.attach(world)
		world.add_player("local")
		build_ms = (Time.get_ticks_usec() - t0) / 1000.0

	func add(id: String, type: String, at: Vector2, heading: float, band: String = "") -> String:
		var spec := {"id": id, "type": type, "side": "side_a" if type != "radio_tower" else "side_b", "controller": "player", "x": at.x, "y": at.y, "heading": heading}
		if band != "":
			spec["altitude_band"] = band
		var made := str(world.add_unit(spec))
		grid.sync_statics(world.units)
		return made

	# The unit's place: {x, y, heading, z (its base: the ground it stands on, or its band's height), def}.
	func pose(id: String) -> Dictionary:
		var u: Object = world.units[id]
		var band := str(u.altitude_band)
		var ref := str(world.rules.band_reference.get(band, "terrain"))
		return {"x": float(u.x), "y": float(u.y), "heading": float(u.heading), "z": lof.base_z(float(u.x), float(u.y), world.band_height(band), ref), "def": u.def, "id": id}

	func muzzle(p: Dictionary, weapon: int = 0, hardpoint: int = 0) -> PackedFloat64Array:
		var hp: Vector3 = p["def"].weapons[weapon].hardpoints[hardpoint]
		return Shapes.muzzle(hp, p["x"], p["y"], p["heading"], p["z"])

	func boxes(p: Dictionary) -> Array:
		return Shapes.world_boxes(p["def"], grid.rules, p["x"], p["y"], p["heading"], p["z"])

	# Everything the side view needs for one shooter and its targets.
	func make_case(title: String, notes: Array, shooter_id: String, target_ids: Array, labels: Array, hscale: float, vscale: float, rules_lof: LineOfFire = null) -> Dictionary:
		var l := rules_lof if rules_lof != null else lof
		var sp := pose(shooter_id)
		var mz := muzzle(sp)
		var targets: Array = []
		for i in target_ids.size():
			var tp := pose(str(target_ids[i]))
			var tb := boxes(tp)
			var ex := l.exposure_xyz(mz[0], mz[1], mz[2], tb, ROLL_KEY)
			targets.append({"id": str(target_ids[i]), "label": str(labels[i]), "x": tp["x"], "y": tp["y"], "boxes": tb, "exposure": ex})
		return {"title": title, "notes": notes, "grid": grid, "lof": l, "shooter": {"id": shooter_id, "x": mz[0], "y": mz[1], "z": mz[2], "name": str(sp["def"].name)},
			"shooter_boxes": boxes(sp), "targets": targets, "hscale": hscale, "vscale": vscale, "roll_key": ROLL_KEY}

# --- a: across the bridge --------------------------------------------------------------------------------------------------

# Two tanks on the road, `half_gap` metres either side of the bridge's middle. Returns the case.
static func case_bridge(scene: ProbeScene, half_gap: float, title: String, notes: Array) -> Dictionary:
	var site: Dictionary = scene.water.sites()["bridge"]
	var road: PackedVector2Array = scene.ground.road
	var idx: int = site["road_index"]
	if not scene.world.units.has("bridge_1"):
		scene.add("bridge_1", "bridge", site["pos"], float(site["heading"]))
	var a := GroundMap.road_point(road, idx, -half_gap)
	var b := GroundMap.road_point(road, idx, half_gap)
	var tag := "%d" % int(half_gap)
	scene.add("tank_a" + tag, "tank", a, (b - a).angle())
	scene.add("tank_b" + tag, "tank", b, (a - b).angle())
	return scene.make_case(title, notes, "tank_a" + tag, ["tank_b" + tag], ["enemy tank"], 9.0, 28.0)

# --- b: behind a house ------------------------------------------------------------------------------------------------------

# The first house of the village a tank can be put behind with nothing else between: returns the case, or {} when none.
static func case_house(scene: ProbeScene, title: String, notes: Array) -> Dictionary:
	var vil: Variant = scene.grid.terrain.village()
	var ppm: float = scene.grid.ppm
	var tries := 0
	for s: Dictionary in vil.structs:
		if s.kind != "house":
			continue
		var part: Dictionary = s.geo[0]
		var c := Vector2(float(part.cx), float(part.cy)) / ppm
		var w := float(part.w) / ppm
		var d := float(part.d) / ppm
		var ex := Vector2(float(part.cc), float(part.ss))
		var ey := Vector2(-float(part.ss), float(part.cc))
		var axis := ey if d <= w else ex
		var half := minf(w, d) * 0.5
		var from := c - axis * (half + 36.0)
		var to := c + axis * (half + 7.0)
		tries += 1
		var tag := "h%d" % tries
		var a_id := "tank_s_" + tag
		var b_id := "tank_t_" + tag
		if not _ground_clear(scene.grid, from, 4.0) or not _ground_clear(scene.grid, to, 4.0):
			continue
		scene.add(a_id, "tank", from, axis.angle())
		scene.add(b_id, "tank", to, (-axis).angle())
		var cs := scene.make_case(title, notes, a_id, [b_id], ["enemy tank behind the house"], 11.0, 24.0)
		var exp: Dictionary = cs["targets"][0]["exposure"]
		var only_house := true
		var any_line := false
		for bx: Dictionary in exp["boxes"]:
			for ln: Dictionary in bx["lines"]:
				any_line = true
				if not bool(ln["reach"]) and ln["stop"]["material_name"] != "timber":
					only_house = false
		if any_line and only_house and float(exp["share"]) < 0.001:
			return cs
		scene.world.units.erase(a_id)
		scene.world.units.erase(b_id)
	return {}

# Are the cells within r of p plain ground at the ground's level, with no crown over them?
static func _ground_clear(grid: HeightGrid, p: Vector2, r: float) -> bool:
	for dx in [-r, 0.0, r]:
		for dy in [-r, 0.0, r]:
			var x: float = p.x + dx
			var y: float = p.y + dy
			if grid.material_at(x, y) != Rules.GROUND or grid.top_at(x, y) != 0.0:
				return false
	return grid.canopies_near(p.x, p.y, r + 2.0).is_empty()

# --- c: behind the sandbags -----------------------------------------------------------------------------------------------

# A tank 7.5 m behind the first battery's ring, a gunner on the far side; the first compass direction where nothing but the ring is between.
static func case_sandbags(scene: ProbeScene, title: String, notes: Array) -> Dictionary:
	var bat: Vector2 = (scene.grid.terrain.layout().sites()["aa_battery"] as Array)[0]
	scene.grid.build_rect(Rect2(bat.x - 80.0, bat.y - 80.0, 160.0, 160.0))
	scene.add("aa_1", "anti_aircraft_battery", bat, 0.0)
	var best: Dictionary = {}
	for k in 12:
		var a := PI + float(k) * TAU / 12.0
		var dir := Vector2(cos(a), sin(a))
		var gunner := bat + dir * 46.0
		var tank := bat - dir * 7.5
		if not _ground_clear(scene.grid, gunner, 2.0) or not _ground_clear(scene.grid, tank, 3.0):
			continue
		var gid := "tank_s_c%d" % k
		var tid := "tank_t_c%d" % k
		scene.add(gid, "tank", gunner, (-dir).angle())
		scene.add(tid, "tank", tank, dir.angle())
		var cs := scene.make_case(title, notes, gid, [tid], ["tank behind the sandbags"], 13.0, 40.0)
		var clean := true
		for bx: Dictionary in cs["targets"][0]["exposure"]["boxes"]:
			for ln: Dictionary in bx["lines"]:
				if not bool(ln["reach"]) and ln["stop"]["material_name"] != "earthworks":
					clean = false
		if clean:
			return cs
		if best.is_empty():
			best = cs
	return best

# --- d: a plane behind a hill ---------------------------------------------------------------------------------------------------

# A scarp on a row of the grid: `lead` low cells at 0 m, then 50 cells at one plateau height (no crown within 25 m of the foot).
# Returns {x, y, h} (the foot's x), preferring the highest plateau; {} if there is none in the chunks.
static func find_scarp(grid: HeightGrid, chunks: Rect2i, lead: int, want_min_h: float) -> Dictionary:
	var n: int = grid.n
	var c: float = grid.cell_m
	var best: Dictionary = {}
	for cy in range(chunks.position.y, chunks.end.y):
		for cx in range(chunks.position.x, chunks.end.x):
			var ch = grid.chunk_at(cx, cy)
			if ch.uniform:
				continue
			for iy in range(2, n - 2, 3):
				var ix := lead + 2
				while ix < n - 60:
					var up: float = ch.h[iy * n + ix]
					if up >= want_min_h and ch.h[iy * n + ix - 1] == 0.0:
						var ok := true
						for k in range(0, 50):
							if ch.h[iy * n + ix + k] != up:
								ok = false
								break
						if ok:
							for k in range(1, lead + 1):
								if ch.h[iy * n + ix - k] != 0.0 or (ch.m[iy * n + ix - k] & Rules.MATERIAL_MASK) != Rules.GROUND:
									ok = false
									break
						if ok:
							var fx := float(cx) * grid.chunk_m + float(ix) * c
							var fy := float(cy) * grid.chunk_m + (float(iy) + 0.5) * c
							if grid.canopies_near(fx - float(lead) * 0.5, fy, float(lead) * 0.6 + 12.0).is_empty():
								if best.is_empty() or up > float(best["h"]):
									best = {"x": fx, "y": fy, "h": up}
					ix += 1
	return best

static func case_hill(scene: ProbeScene, title: String, notes: Array, scarp: Dictionary) -> Dictionary:
	var H: float = scarp["h"]
	var lead := 30.0
	var foot := Vector2(float(scarp["x"]), float(scarp["y"]))
	var gun := foot - Vector2(lead, 0.0)
	scene.add("aa_mobile", "mobile_aa", gun, 0.0)
	var mz: PackedFloat64Array = scene.muzzle(scene.pose("aa_mobile"))
	var frac := (H - mz[2]) / (120.0 - mz[2])
	var d_edge := lead / frac
	var near_d := d_edge * 0.6
	var far_d := d_edge * 1.6
	scene.add("fighter_near", "light_fighter", gun + Vector2(near_d, 0.0), PI * 0.5, "low")
	scene.add("fighter_far", "light_fighter", gun + Vector2(far_d, 0.0), PI * 0.5, "low")
	var cs := scene.make_case(title, notes + ["a %.0f m scarp %.0f m ahead of the gun; at 120 m a plane is hidden beyond %.0f m (the muzzle at %.1f m)" % [H, lead, d_edge, mz[2]]],
		"aa_mobile", ["fighter_near", "fighter_far"], ["low-band plane, %.0f m" % near_d, "low-band plane, %.0f m" % far_d], maxf(1.2, 1300.0 / (far_d + 40.0)), 5.0)
	return cs
