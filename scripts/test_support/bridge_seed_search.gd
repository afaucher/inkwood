extends RefCounted

# THE SEED SEARCH FOR HOLD THE BRIDGE (Track BM, 2026-10-11; test support -- the gate does not run scripts/test_support). Alex's mission idea
# (decisions mixed-warfare and bridge-mission): "Capture and hold a bridge, but you are at the far end of ship range so your shots need to be
# really on point to hit." So the MAP must put a road bridge at the edge of the cruiser's gun range, from water deep enough for the cruiser to
# sail (the shallows keep the ship out: that is the "far end"). This asks every seed the same questions and says which fit. EVERYTHING HERE
# IS PROPOSED (the bands below are the lead's: "about 2.4 to 3 km"; Alex gave the idea, not the numbers).
#
#   var r := BridgeSeedSearch.evaluate(20261009)      # {seed, ok, fits, why, bridge, d_min, station, station_d, ...}
#   var all := BridgeSeedSearch.search(range(1, 41))  # evaluate() of each, in order
#   BridgeSeedSearch.report(r)                        # one line of words
#
# WHAT IT LOOKS AT, per seed (the water of WaterGen.shared(seed), its bridge site, the world layout's road):
#   1. THE BRIDGE        the seed has a river that crosses the road (WaterGen.sites().bridge), and the road runs on at least `road_far_m` beyond it
#                        to the map's edge side (where the waves come from) and `road_near_m` the other way (the player's side), inside the map.
#   2. NAVIGABLE WATER   the cells (CELL_M) where the cruiser (data/units/cruiser.json: draught, hull length) floats at any heading: the water under
#                        the cell's centre and at the hull's two ends' reach (hull_fraction x size) in the four compass directions is at least its
#                        draught deep (the sea rule, data/sim/sea.json), and the largest connected set of them (the sea the ship can sail). The
#                        shallows are what keep it away from the shore.
#   3. d_min             the nearest of those cells to the bridge: how close the ship can ever bring its guns. The mission wants it near the
#                        gun's range_max_m (3000 m): inside [d_min_lo_m, d_min_hi_m].
#   4. A STATION         a navigable cell within the gun's reach of the bridge from which every target spot on the road, from `cover_near_m` on the
#                        bridge's middle to `cover_far_m` on the enemy's, is IN REACH by the guns' own rule (guns.gd reach_error: range in
#                        [range_min_m, range_max_m] and the COASTAL STRIP: the first water along the line of fire from the target back toward the
#                        ship within inland_max_m -- the river counts as water). The nearest to the middle of the band is chosen.
# A seed `fits` when it has the bridge, the road, a station, and d_min is inside the band. `why` says what failed otherwise.

const WaterGen = preload("res://scripts/world/water_gen.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")
const Guns = preload("res://scripts/sim/guns.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")

const CELL_M := 50.0
const MAP_M := 5000.0

# The band (PROPOSED): the nearest the ship can get to the bridge, and where its station is looked for (metres).
const D_MIN_LO_M := 2300.0
const D_MIN_HI_M := 2900.0
const STATION_LO_M := 2300.0
const STATION_HI_M := 3000.0
const STATION_MID_M := 2700.0
# The road (PROPOSED): metres of it needed beyond the bridge on the enemy's side (the waves start 300 to 400 m out and need room to queue)
# and on the player's side; and the spots the cruiser must be able to shell, along the road, from the player's side to the enemy's.
const ROAD_FAR_M := 480.0
const ROAD_NEAR_M := 150.0
const COVER_NEAR_M := 0.0       # (the bridge's middle: a ship on the player's side of the river cannot shell the land on its own side, the coastal strip's first water along the line of fire being the river BEHIND the target; and an enemy tank there has crossed)
const COVER_FAR_M := 300.0
const COVER_STEP_M := 20.0
# A sea the ship can sail in must be at least this many cells (50 m): 0.75 km2, a few hundred metres of room to turn round in.
const MIN_SEA_CELLS := 300

static func cruiser_numbers() -> Dictionary:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/units/cruiser.json"))
	var sea: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/sim/sea.json"))
	return {
		"draught_m": float((d["draught_m"] as Dictionary)["value"]),
		"size_m": float((d["size_m"] as Dictionary)["value"]),
		"hull_fraction": float((sea["hull_fraction"] as Dictionary)["value"]),
	}

static func search(seeds: Array) -> Array:
	var out: Array = []
	for s: Variant in seeds:
		out.append(evaluate(int(s)))
	return out

# The point `m` metres along the road from road point `idx` (negative: toward the village, index 0); (INF, INF) if the road ends first.
static func road_point(road: PackedVector2Array, idx: int, m: float) -> Vector2:
	return GroundMap.road_point(road, idx, m)

static func evaluate(seed_v: int) -> Dictionary:
	var out := {"seed": seed_v, "ok": false, "fits": false, "why": "", "bridge": Vector2.ZERO, "d_min": INF, "station": Vector2.ZERO, "station_d": INF,
		"nav_cells": 0, "road_index": -1, "targets": []}
	var water: RefCounted = WaterGen.shared(seed_v)
	if water == null or not water.ok():
		out["why"] = "the water did not build"
		return out
	var site: Dictionary = water.sites().get("bridge", {})
	if site.is_empty() or site.get("ok", false) != true:
		out["why"] = "no river crosses the road"
		return out
	var road: PackedVector2Array = water.layout().road()
	var bridge: Vector2 = site["pos"]
	var idx := int(site["road_index"])
	out["bridge"] = bridge
	out["road_index"] = idx
	out["heading"] = float(site["heading"])
	out["river_width_m"] = float(site["river_width_m"])
	out["ok"] = true
	# the road on both sides of the bridge, inside the map
	var far_end := road_point(road, idx, ROAD_FAR_M)
	var near_end := road_point(road, idx, -ROAD_NEAR_M)
	if not _inside(far_end) or not _inside(near_end):
		out["why"] = "the road runs off the map within %.0f m of the bridge on the far side or %.0f m on the near side" % [ROAD_FAR_M, ROAD_NEAR_M]
		return out
	# the targets the ship must be able to reach: the road from the near side to the far
	var targets: Array = []
	var m := -COVER_NEAR_M
	while m <= COVER_FAR_M + 1e-6:
		targets.append({"m": m, "p": road_point(road, idx, m)})
		m += COVER_STEP_M
	out["targets"] = targets
	# the sea the cruiser can sail
	var nums := cruiser_numbers()
	var half := float(nums["hull_fraction"]) * float(nums["size_m"])
	var need := float(nums["draught_m"])
	var n := int(MAP_M / CELL_M)
	var nav := PackedByteArray()
	nav.resize(n * n)
	for j in n:
		for i in n:
			var c := Vector2((float(i) + 0.5) * CELL_M, (float(j) + 0.5) * CELL_M)
			if float(water.depth_at(c.x, c.y)) < need:
				continue
			var ok := true
			for dv: Vector2 in [Vector2(half, 0.0), Vector2(-half, 0.0), Vector2(0.0, half), Vector2(0.0, -half)]:
				var q := c + dv
				if float(water.depth_at(q.x, q.y)) < need:
					ok = false
					break
			if ok:
				nav[j * n + i] = 1
	var comp := _largest_component(nav, n)
	out["nav_cells"] = comp.size()
	if comp.size() < MIN_SEA_CELLS:
		out["why"] = "no sea the cruiser can sail in (%d cells of %.0f m)" % [comp.size(), CELL_M]
		return out
	var d_min := INF
	for k: int in comp:
		var c2 := Vector2((float(k % n) + 0.5) * CELL_M, (float(k / n) + 0.5) * CELL_M)
		d_min = minf(d_min, c2.distance_to(bridge))
	out["d_min"] = d_min
	# a station
	var spec: GunRules.Spec = GunRules.new().special("main_guns")
	var depth := Callable(water, "depth_at")
	var best_score := INF
	var best := Vector2.ZERO
	var best_missing := 99
	for k: int in comp:
		var c3 := Vector2((float(k % n) + 0.5) * CELL_M, (float(k / n) + 0.5) * CELL_M)
		var d := c3.distance_to(bridge)
		if d < STATION_LO_M or d > STATION_HI_M:
			continue
		var missing := 0
		for t: Dictionary in targets:
			if Guns.reach_error(c3, t["p"], spec, depth) != "":
				missing += 1
		var score := float(missing) * 10000.0 + absf(d - STATION_MID_M)
		if score < best_score:
			best_score = score
			best = c3
			best_missing = missing
	out["station_missing"] = best_missing
	if best_score == INF:
		out["why"] = "no navigable water between %.0f and %.0f m of the bridge (the nearest is %.0f m)" % [STATION_LO_M, STATION_HI_M, d_min]
		return out
	out["station"] = best
	out["station_d"] = best.distance_to(bridge)
	var why_not: Array[String] = []
	if best_missing > 0:
		why_not.append("%d of %d spots on the road are out of the guns' reach from the best station (%s)" % [best_missing, targets.size(), _reasons(best, targets, spec, depth)])
	if d_min < D_MIN_LO_M:
		why_not.append("the ship can come to %.0f m (under %.0f m): not the far end of its range" % [d_min, D_MIN_LO_M])
	if d_min > D_MIN_HI_M:
		why_not.append("the nearest navigable water is %.0f m away (over %.0f m)" % [d_min, D_MIN_HI_M])
	out["fits"] = why_not.is_empty()
	out["why"] = "; ".join(why_not)
	return out

static func _reasons(from: Vector2, targets: Array, spec: GunRules.Spec, depth: Callable) -> String:
	var counts := {}
	for t: Dictionary in targets:
		var why := Guns.reach_error(from, t["p"], spec, depth)
		if why != "":
			counts[why] = int(counts.get(why, 0)) + 1
	return ", ".join(counts.keys().map(func(k: Variant) -> String: return "%s x%d" % [str(k), int(counts[k])]))

static func _inside(p: Vector2) -> bool:
	return p.is_finite() and p.x >= 20.0 and p.y >= 20.0 and p.x <= MAP_M - 20.0 and p.y <= MAP_M - 20.0

# The largest 4-connected set of navigable cells, as cell indices (j * n + i).
static func _largest_component(nav: PackedByteArray, n: int) -> PackedInt32Array:
	var seen := PackedByteArray()
	seen.resize(n * n)
	var best := PackedInt32Array()
	for start in n * n:
		if nav[start] == 0 or seen[start] == 1:
			continue
		var stack: Array[int] = [start]
		var cells := PackedInt32Array()
		seen[start] = 1
		while not stack.is_empty():
			var k: int = stack.pop_back()
			cells.append(k)
			var i := k % n
			var j := k / n
			for nb: Vector2i in [Vector2i(i + 1, j), Vector2i(i - 1, j), Vector2i(i, j + 1), Vector2i(i, j - 1)]:
				if nb.x < 0 or nb.y < 0 or nb.x >= n or nb.y >= n:
					continue
				var q := nb.y * n + nb.x
				if nav[q] == 1 and seen[q] == 0:
					seen[q] = 1
					stack.append(q)
		if cells.size() > best.size():
			best = cells
	return best

static func report(r: Dictionary) -> String:
	if not bool(r["ok"]):
		return "seed %d: %s" % [int(r["seed"]), str(r["why"])]
	if r["station_d"] == INF or float(r["station_d"]) == INF:
		return "seed %d: bridge at (%.0f, %.0f) river %.0f m, %s" % [int(r["seed"]), (r["bridge"] as Vector2).x, (r["bridge"] as Vector2).y, float(r.get("river_width_m", 0.0)), str(r["why"])]
	return "seed %d: %s  bridge (%.0f, %.0f)  nearest navigable water %.0f m (%d cells)  station (%.0f, %.0f) at %.0f m  %s" % [
		int(r["seed"]), "FITS" if bool(r["fits"]) else "no", (r["bridge"] as Vector2).x, (r["bridge"] as Vector2).y, float(r["d_min"]), int(r["nav_cells"]),
		(r["station"] as Vector2).x, (r["station"] as Vector2).y, float(r["station_d"]), str(r["why"])]
