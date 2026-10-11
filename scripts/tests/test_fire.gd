extends "res://scripts/test_support/test_case.gd"

# THE FOREST FIRE, THE SIMULATION (decision forest-fire, 2026-10-11; scripts/sim/fire.gd, fire_rules.gd, fire_trees.gd, data/sim/fire.json). Alex: "the fire
# is actually just smoke coming from the trees. It spreads from tree to tree based on distance. It can inflict damage to nearby units with low power and low
# chance." The numbers Alex accepted (50% a tree in a blast, 40% touching falling to 0 at 30 m, three turns, 10% falling to 0 at 25 m) are asserted as
# frequencies over many seeds; every detail the lead proposed is asserted as built, labelled PROPOSED. Headless, host side only (the tracking rules are
# test_fire_track, the wire is test_fire_net).
#
#   1. THE DATA           data/sim/fire.json loads under the sim's rules; a missing field, a value with no provenance and an unknown field are refused
#   2. TREE IDENTITY      the sim's trees are the map's: the same ids chunk by chunk from the GroundMap's terrain, a second Terrain of the seed, the map provider's
#                         terrain, with the water and without
#   3. IGNITION           a bomb_impact in a dense grove of the Strike's seed lights about half the trees whose canopy is in the blast, never one outside it, at
#                         the event's moment; a shell_impact and a crash do the same (the crash with its PROPOSED 20 m)
#   4. SPREAD             40% when canopies touch or overlap, 20% at a 15 m gap, none from 30 m; from the turn after the one a tree was lit in; a seeded
#                         moment inside the turn; a fire never leaves its cluster (a gap of 30 m, a road, a field)
#   5. BURNING OUT        three turns, the turn it is lit counting as the first; a fire_out at the end of the last; the feed keeps it
#   6. DAMAGE             the odds fade with the distance, measured over many seeds; trees combine; one pip a unit a turn; planes are untouched; the moment is
#                         the closest approach; a unit that loses its last pip is destroyed where it stood
#   7. THROUGH THE WORLD  a bomb lands in the grove: events merged in time order, the fire in the turn's result; the same seed draws the same fire; fire off
#                         adds nothing; Suppress has it on, the other scenarios off, the knob's override works
#   8. BURNT COVER        a burnt-out tree takes its woods cover with it (scaled by the share of the trees near it), at the moment asked about
#   9. SUPPRESS, PLAYED   the scripted bombing runs of Suppress (the fire is on in its data): every fire the runs lit is consistent with its events, the same seed
#                         plays out the same fire

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const FireRules = preload("res://scripts/sim/fire_rules.gd")
const FireState = preload("res://scripts/sim/fire.gd")
const FireTrees = preload("res://scripts/sim/fire_trees.gd")
const FireFakes = preload("res://scripts/test_support/fire_fakes.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const SuppressWorlds = preload("res://scripts/test_support/suppress_worlds.gd")
const SuppressPlay = preload("res://scripts/test_support/suppress_play.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const ConcealRules = preload("res://scripts/sim/concealment.gd")
const SandboxScenario = preload("res://scripts/app/sandbox_scenario.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const WorldLayout = preload("res://scripts/world/world_layout.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const ChunkTerrainProvider = preload("res://scripts/render/chunk_terrain_provider.gd")

const SEED := 20261009

var _water: RefCounted = null
var _gm: RefCounted = null
var _src: FireTrees = null
var _site := Vector2.ZERO
var _grove := {}

func setup(_main) -> void:
	timeout_seconds = 240.0
	for part: Script in [World, FireRules, FireState, FireTrees, FireFakes, BombWorlds, SuppressWorlds, ConcealRules, SandboxScenario, GroundMap, WaterGen, Terrain, ChunkTerrainProvider]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	_water = WaterGen.shared(SEED)
	_gm = GroundMap.shared(SEED, _water)
	if not check(_gm.ok(), "the Strike seed's ground builds: %s" % str(_gm.errors)):
		finish()
		return
	_src = FireTrees.new(_gm.terrain)
	_site = WorldLayout.shared(SEED).sites()["radio_tower"]
	_grove = _dense_grove(_site)
	eq(_data(), true, "1. the data part ran to its end")
	eq(_identity(), true, "2. the identity part ran to its end")
	eq(_ignition(), true, "3. the ignition part ran to its end")
	eq(_spread(), true, "4. the spread part ran to its end")
	eq(_burning_out(), true, "5. the burning-out part ran to its end")
	eq(_damage(), true, "6. the damage part ran to its end")
	eq(_through_the_world(), true, "7. the world part ran to its end")
	eq(_burnt_cover(), true, "8. the burnt-cover part ran to its end")
	eq(_suppress_played(), true, "9. the Suppress part ran to its end")
	finish()

# --- helpers ------------------------------------------------------------------------------------------------------

# The tree of the village's neighbourhood with the most trees within 45 m of it (a grove): {centre: Vector2 (that tree's), count}.
func _dense_grove(near: Vector2) -> Dictionary:
	var trees: Array = _src.trees_in_disc(near.x, near.y, 700.0)
	var best := Vector2.ZERO
	var best_n := 0
	for a: Dictionary in trees:
		if float(_gm.woods_at(float(a["x_m"]), float(a["y_m"]))) < 0.5:
			continue
		var n := 0
		for b: Dictionary in trees:
			if Vector2(float(a["x_m"]) - float(b["x_m"]), float(a["y_m"]) - float(b["y_m"])).length() <= 45.0:
				n += 1
		if n > best_n:
			best_n = n
			best = Vector2(float(a["x_m"]), float(a["y_m"]))
	return {"centre": best, "count": best_n}

func _ids(trees: Array) -> Array:
	var out: Array = []
	for t: Variant in trees:
		out.append(FireTrees.id_of(float((t as Dictionary)["x"]), float((t as Dictionary)["y"])))
	out.sort()
	return out

func _fresh_state() -> FireState:
	return FireFakes.state(_src)

func _blast_m() -> float:
	return BombRules.new().blast_radius_m()

# The seeds a frequency is taken over, and its band: p +- 4 sigma.
func _band(p: float, n: int) -> Vector2:
	var sigma := sqrt(p * (1.0 - p) / float(n))
	return Vector2(maxf(p - 4.0 * sigma, 0.0), minf(p + 4.0 * sigma, 1.0))

func _in_band(rate: float, p: float, n: int, what: String) -> void:
	var b := _band(p, n)
	check(rate >= b.x and rate <= b.y, "%s: %.3f over %d draws is within %.3f..%.3f of %.2f" % [what, rate, n, b.x, b.y, p])

# --- 1. The data --------------------------------------------------------------------------------------------------

func _data() -> bool:
	var r := FireFakes.rules()
	if not check(r.ok(), "1. data/sim/fire.json loads: %s" % str(r.errors)):
		return false
	near(r.ignite_chance, 0.5, 1e-12, "1. a tree in a blast catches at 50% (Alex)")
	near(r.spread_chance, 0.4, 1e-12, "1. 40% when canopies touch (Alex)")
	near(r.spread_reach_m, 30.0, 1e-12, "1. falling to 0 at 30 m (Alex)")
	eq(r.burn_turns, 3, "1. a tree burns 3 turns (Alex)")
	near(r.damage_chance, 0.1, 1e-12, "1. 10% at a canopy's edge (Alex)")
	near(r.damage_reach_m, 25.0, 1e-12, "1. falling to 0 at 25 m (Alex)")
	eq(r.damage_pips, 1, "1. one pip (Alex)")
	check(r.denies_tracking, "1. smoke denies tracking (Alex: visible but untrackable)")
	near(r.crash_radius_m, 20.0, 1e-12, "1. a crash lights trees within 20 m (PROPOSED)")
	near(r.smoke_reach_m, 20.0, 1e-12, "1. a unit is in the smoke within 20 m of a canopy's edge (PROPOSED)")
	near(r.burnt_share_radius_m, 20.0, 1e-12, "1. the burnt-cover share is taken within 20 m (PROPOSED)")
	check(r.smoke_domains.has("ground") and r.smoke_domains.has("sea") and not r.smoke_domains.has("air"), "1. smoke denies tracking of ground and sea units, not planes (PROPOSED)")
	check(r.smoke_mobility.has("mobile") and r.smoke_mobility.has("static"), "1. mobile and static alike (PROPOSED)")
	eq(r.spread_p(-5.0), r.spread_p(0.0), "1. overlapping canopies are touching")
	near(r.spread_p(15.0), 0.2, 1e-12, "1. 20% at a 15 m gap")
	eq(r.spread_p(30.0), 0.0, "1. 0 at 30 m")
	eq(r.spread_p(31.0), 0.0, "1. and beyond")
	near(r.damage_p(0.0), 0.1, 1e-12, "1. 10% at the edge")
	near(r.damage_p(12.5), 0.05, 1e-12, "1. 5% half way")
	eq(r.damage_p(25.0), 0.0, "1. 0 at 25 m")
	eq(r.out_turn(5), 7, "1. lit in turn 5 it burns in 5, 6 and 7 (the lit turn counts as the first: PROPOSED)")
	# every tunable says where it came from, nothing is guessed, an unknown field is refused
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FireRules.PATH))
	var broken: Dictionary = raw.duplicate(true)
	(broken["ignite"] as Dictionary).erase("chance")
	check(not FireRules.new(broken, true).ok(), "1. a missing field is an error, not a default")
	broken = raw.duplicate(true)
	((broken["spread"] as Dictionary)["reach_m"] as Dictionary).erase("decision")
	check(not FireRules.new(broken, true).ok(), "1. a value that says neither where it came from nor why is an error")
	broken = raw.duplicate(true)
	broken["flames"] = {"value": 1}
	check(not FireRules.new(broken, true).ok(), "1. an unknown field is an error (misspelt?)")
	broken = raw.duplicate(true)
	(broken["smoke"] as Dictionary)["cover_radius_m"] = {"value": 150, "_proposed": true, "_reason": "x"}
	check(not FireRules.new(broken, true).ok(), "1. an unknown field inside a section is an error too (smoke has no cover radius)")
	broken = raw.duplicate(true)
	((broken["spread"] as Dictionary)["gap_measure"] as Dictionary)["value"] = "elbow"
	check(not FireRules.new(broken, true).ok(), "1. a setting the code does not know is an error")
	check(not (raw.has("smoke") and (raw["smoke"] as Dictionary).has("cover_radius_m")), "1. smoke has no cover radius (it is not cover)")
	return true

# --- 2. Tree identity ---------------------------------------------------------------------------------------------

func _identity() -> bool:
	var ppm: float = _gm.terrain.px_per_m
	var c0: Vector2i = _gm.terrain.chunk_of(_site.x, _site.y)
	var chunks: Array[Vector2i] = []
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			chunks.append(Vector2i(c0.x + dx, c0.y + dy))
	var total := 0
	# a second Terrain of the seed, made as the map's provider makes its own (the water's maker, the data path, the render parameters)
	var provider := ChunkTerrainProvider.new(SEED, RenderParams.new(), {"chunk_px": 1024}, 0.0, _water)
	check(provider.ok(), "2. the map provider builds: %s" % str(provider.errors))
	var other: Terrain = _water.make_terrain()
	for c in chunks:
		var a: Array = _ids(_gm.terrain.trees_in_chunk(c.x, c.y))
		var b: Array = _ids(other.trees_in_chunk(c.x, c.y))
		var m: Array = _ids(provider.terrain.trees_in_chunk(c.x, c.y))
		total += a.size()
		eq(a, b, "2. chunk %s: a second water terrain makes the same trees (ids)" % c)
		eq(a, m, "2. chunk %s: the map provider's terrain makes the same trees (ids)" % c)
	check(total >= 100, "2. the nine chunks round the village hold %d trees, enough to mean something" % total)
	# and the sim's source answers with those very trees, in metres
	var cpx := float(_gm.terrain.chunk_m)
	var rect_centre := Vector2((float(c0.x) + 0.5) * cpx, (float(c0.y) + 0.5) * cpx)
	var disc: Array = _src.trees_in_disc(rect_centre.x, rect_centre.y, cpx * 0.5)
	var px_ids: Dictionary = {}
	for t: Dictionary in _gm.terrain.trees_in_chunk(c0.x, c0.y):
		px_ids[FireTrees.id_of(float(t["x"]), float(t["y"]))] = t
	var inside := 0
	for r: Dictionary in disc:
		if px_ids.has(str(r["id"])):
			inside += 1
			var t: Dictionary = px_ids[str(r["id"])]
			near(float(r["x_m"]) * ppm, float(t["x"]), 1e-6, "2. x in metres is the terrain's px / px_per_m")
			near(float(r["r_m"]) * ppm, float(t["r"]), 1e-6, "2. the canopy radius in metres is the terrain's r / px_per_m")
	check(inside >= 5, "2. the source's disc holds trees of the centre chunk (%d)" % inside)
	var ids_seen: Dictionary = {}
	for r: Dictionary in _src.trees_in_disc(_site.x, _site.y, 400.0):
		check(not ids_seen.has(str(r["id"])), "2. ids are unique")
		ids_seen[str(r["id"])] = true
	check(float(_src.max_canopy_m()) >= 10.0, "2. the largest canopy the source knows of (%.1f m) bounds the trees" % float(_src.max_canopy_m()))
	for r: Dictionary in _src.trees_in_disc(_site.x, _site.y, 400.0):
		if float(r["r_m"]) > float(_src.max_canopy_m()) + 1e-9:
			fail("2. a tree of %.2f m is larger than max_canopy_m" % float(r["r_m"]))
			break
	# without the water: the raw terrain's own ids, equal to a second raw terrain's
	var raw_gm: RefCounted = GroundMap.shared(SEED, null)
	var raw2 := Terrain.new(SEED)
	eq(_ids(raw_gm.terrain.trees_in_chunk(c0.x, c0.y)), _ids(raw2.trees_in_chunk(c0.x, c0.y)), "2. without the water too: the same trees from two Terrains of the seed")
	return true

# --- 3. Ignition --------------------------------------------------------------------------------------------------

func _ignition() -> bool:
	var centre: Vector2 = _grove["centre"]
	check(int(_grove["count"]) >= 8, "3. a dense grove was found near the village: %d trees within 45 m of (%.0f, %.0f)" % [int(_grove["count"]), centre.x, centre.y])
	var blast := _blast_m()
	var all: Array = _src.trees_in_disc(centre.x, centre.y, blast + float(_src.max_canopy_m()) + 5.0)
	var eligible: Dictionary = {}
	var outside: Dictionary = {}
	for t: Dictionary in all:
		var edge := Vector2(float(t["x_m"]) - centre.x, float(t["y_m"]) - centre.y).length() - float(t["r_m"])
		if edge <= blast:
			eligible[str(t["id"])] = t
		else:
			outside[str(t["id"])] = t
	check(eligible.size() >= 6 and outside.size() >= 1, "3. the blast (%.0f m) reaches %d trees' canopies and leaves %d near it alone" % [blast, eligible.size(), outside.size()])
	var runs := 150
	var lit_total := 0
	var outside_lit := 0
	var wrong_t := 0
	var wrong_cause := 0
	for s in range(1, runs + 1):
		var f := _fresh_state()
		var res: Dictionary = f.resolve_turn(1, s, {}, [FireFakes.bomb(centre.x, centre.y, 2.0)], FireFakes.stand(0.0, 0.0))
		for e: Dictionary in FireFakes.events_of(res["events"], "fire_ignite"):
			if not eligible.has(str(e["tree"])):
				outside_lit += 1
			lit_total += 1
			if not is_equal_approx(float(e["t"]), 2.0):
				wrong_t += 1
			if str(e["cause"]) != "bomb":
				wrong_cause += 1
		if s <= 3:
			eq(f.lit_count(), FireFakes.events_of(res["events"], "fire_ignite").size(), "3. every tree lit has an event (seed %d)" % s)
	eq(outside_lit, 0, "3. no tree outside the blast was lit")
	eq(wrong_t, 0, "3. every tree is lit at the event's moment (t = 2.0)")
	eq(wrong_cause, 0, "3. and its cause is the bomb")
	_in_band(float(lit_total) / float(runs * eligible.size()), 0.5, runs * eligible.size(), "3. a tree in a blast catches at 50%")
	# the feed's shape, the events' shape, the order
	var f1 := _fresh_state()
	var res1: Dictionary = f1.resolve_turn(1, 7, {}, [FireFakes.bomb(centre.x, centre.y, 2.0)], FireFakes.stand(0.0, 0.0))
	var feed: Array = f1.feed()
	check(feed.size() >= 1, "3. seed 7 lit %d trees" % feed.size())
	for rec: Dictionary in feed:
		eq((rec.keys() as Array).size(), 7, "3. a feed record has seven fields")
		for k: String in ["id", "x_m", "y_m", "r_m", "lit_turn", "lit_t", "out_turn"]:
			check(rec.has(k), "3. the feed record has '%s'" % k)
		eq(int(rec["lit_turn"]), 1, "3. lit in turn 1")
		eq(int(rec["out_turn"]), 3, "3. out after turn 3 (the lit turn counts as the first: PROPOSED)")
		check(eligible.has(str(rec["id"])), "3. the lit tree is one the blast reached")
	for e: Dictionary in FireFakes.events_of(res1["events"], "fire_ignite"):
		for k: String in ["type", "turn", "t", "tree", "x", "y", "cause"]:
			check(e.has(k), "3. fire_ignite has '%s'" % k)
	# a shell hits like a bomb (its own blast_m), a crash with the PROPOSED 20 m
	var f2 := _fresh_state()
	var shell := {"type": "shell_impact", "turn": 1, "unit": "cruiser", "t": 1.5, "x": centre.x, "y": centre.y, "blast_m": 30.0}
	var lit_shell := 0
	var shell_far := 0
	for s in range(1, 60):
		var fs := _fresh_state()
		var rs: Dictionary = fs.resolve_turn(1, s, {}, [shell], FireFakes.stand(0.0, 0.0))
		for e: Dictionary in FireFakes.events_of(rs["events"], "fire_ignite"):
			lit_shell += 1
			check(str(e["cause"]) == "shell", "3. a shell's fire says so")
			var rec: Dictionary = fs.record(str(e["tree"]))
			if Vector2(float(rec["x_m"]) - centre.x, float(rec["y_m"]) - centre.y).length() - float(rec["r_m"]) > 30.0:
				shell_far += 1
	check(lit_shell > 0 and shell_far == 0, "3. a shell lights trees within its own blast_m (30 m here): %d lit, %d too far" % [lit_shell, shell_far])
	var crash := {"type": "crash", "turn": 1, "unit": "bomber", "t": 3.0, "x": centre.x, "y": centre.y}
	var lit_crash := 0
	var crash_far := 0
	for s in range(1, 60):
		var fc := _fresh_state()
		var rc: Dictionary = fc.resolve_turn(1, s, {}, [crash], FireFakes.stand(0.0, 0.0))
		for e: Dictionary in FireFakes.events_of(rc["events"], "fire_ignite"):
			lit_crash += 1
			check(str(e["cause"]) == "crash" and is_equal_approx(float(e["t"]), 3.0), "3. a crash's fire says so, at the crash's moment")
			var rec: Dictionary = fc.record(str(e["tree"]))
			if Vector2(float(rec["x_m"]) - centre.x, float(rec["y_m"]) - centre.y).length() - float(rec["r_m"]) > 20.0:
				crash_far += 1
	check(lit_crash > 0 and crash_far == 0, "3. a crash lights trees within 20 m (PROPOSED): %d lit, %d too far" % [lit_crash, crash_far])
	# an event that is not a blast or a crash lights nothing
	var hit := {"type": "hit", "turn": 1, "unit": "x", "t": 1.0, "x": centre.x, "y": centre.y, "blast_m": 99.0}
	var fh := _fresh_state()
	fh.resolve_turn(1, 3, {}, [hit], FireFakes.stand(0.0, 0.0))
	eq(fh.lit_count(), 0, "3. only bomb_impact, shell_impact and crash light trees")
	# a tree already lit is not lit again; a burnt-out one cannot catch
	var fl := _fresh_state()
	fl.resolve_turn(1, 11, {}, [FireFakes.bomb(centre.x, centre.y, 2.0)], FireFakes.stand(0.0, 0.0))
	var n1 := fl.lit_count()
	var r2: Dictionary = fl.resolve_turn(1, 11, {}, [FireFakes.bomb(centre.x, centre.y, 3.0)], FireFakes.stand(0.0, 0.0))
	for e: Dictionary in FireFakes.events_of(r2["events"], "fire_ignite"):
		check(fl.record(str(e["tree"])).get("lit_t", 0.0) == 3.0, "3. only a tree not lit before is lit by the second blast")
	check(fl.lit_count() >= n1, "3. a lit tree stays lit")
	return true

# --- 4. Spread ----------------------------------------------------------------------------------------------------

# One burning tree (id f1, lit in turn 1) and one unlit tree whose canopy edge is `gap` m from it: how often it is lit in turn 2, over `runs` seeds.
func _pair_rate(gap: float, runs: int, r1: float = 8.0, r2: float = 8.0) -> float:
	var lit := 0
	for s in range(1, runs + 1):
		var ft := FireFakes.FakeTrees.new()
		ft.add(1, 0.0, 0.0, r1)
		ft.add(2, r1 + r2 + gap, 0.0, r2)
		var f := FireFakes.state(ft)
		f.add_lit(FireFakes.tree(1, 0.0, 0.0, r1), 1, 1.0, "bomb")
		f.resolve_turn(2, s, {}, [], FireFakes.stand(0.0, 0.0))
		if f.trees.has("f2"):
			lit += 1
	return float(lit) / float(runs)

func _spread() -> bool:
	var runs := 800
	_in_band(_pair_rate(0.0, runs), 0.4, runs, "4. canopies touching: 40%")
	_in_band(_pair_rate(-6.0, runs), 0.4, runs, "4. canopies overlapping count as touching: 40%")
	_in_band(_pair_rate(15.0, runs), 0.2, runs, "4. a 15 m gap: 20% (linear)")
	_in_band(_pair_rate(7.5, runs), 0.3, runs, "4. a 7.5 m gap: 30%")
	eq(_pair_rate(30.0, 300), 0.0, "4. a 30 m gap: never")
	eq(_pair_rate(45.0, 300), 0.0, "4. beyond it: never")
	# the canopy radius is what the gap is measured from: two big trees 40 m apart centre to centre are 16 m apart edge to edge
	_in_band(_pair_rate(16.0, runs, 12.0, 12.0), 0.4 * (1.0 - 16.0 / 30.0), runs, "4. the gap is edge to edge (PROPOSED): 12 m canopies 40 m apart")
	# FROM THE TURN AFTER the one a tree was lit in (PROPOSED)
	var ft := FireFakes.FakeTrees.new()
	ft.add(1, 0.0, 0.0, 8.0)
	for i in range(2, 8):
		ft.add(i, 14.0 + 3.0 * float(i), 4.0 * float(i % 3), 8.0)
	var any_same_turn := 0
	var any_next := 0
	var lit_ts: Array = []
	for s in range(1, 120):
		var f := FireFakes.state(ft)
		f.resolve_turn(1, s, {}, [], FireFakes.stand(0.0, 0.0))   # (nothing lit, nothing spreads)
		f.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.5, "bomb")
		var r1: Dictionary = f.resolve_turn(1, s, {}, [], FireFakes.stand(0.0, 0.0))
		any_same_turn += FireFakes.events_of(r1["events"], "fire_ignite").size()
		var r2: Dictionary = f.resolve_turn(2, s, {}, [], FireFakes.stand(0.0, 0.0))
		for e: Dictionary in FireFakes.events_of(r2["events"], "fire_ignite"):
			any_next += 1
			check(str(e["cause"]) == "spread" and str(e["from"]) == "f1" and int(e["turn"]) == 2, "4. a spread fire says so, and from which tree, in turn 2")
			lit_ts.append(float(e["t"]))
	eq(any_same_turn, 0, "4. a tree lit in a turn does not spread in it (PROPOSED)")
	check(any_next > 0, "4. and does in the next (%d lit)" % any_next)
	var distinct := {}
	for x: float in lit_ts:
		check(x >= 0.0 and x < 5.0, "4. a spread fire is lit inside the turn (%.2f s)" % x)
		distinct[snappedf(x, 0.001)] = true
	check(distinct.size() >= 8, "4. at seeded moments (%d different ones over %d fires), not all at once" % [distinct.size(), lit_ts.size()])
	# the same seed lights the same moment
	var fa := FireFakes.state(ft)
	var fb := FireFakes.state(ft)
	for f: FireState in [fa, fb]:
		f.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.5, "bomb")
		f.resolve_turn(2, 31, {}, [], FireFakes.stand(0.0, 0.0))
	eq(fa.feed(), fb.feed(), "4. the same seed lights the same trees at the same moments")
	# A FIRE NEVER LEAVES ITS CLUSTER: the real trees round the village, joined while the gap between canopies is under 30 m; a tree beyond a 30 m gap -- across
	# a road, a field or open ground -- is never lit, however long the fire burns and spreads
	var gc: Vector2 = _grove["centre"]
	var trees: Array = _src.trees_in_disc(gc.x, gc.y, 450.0)
	var comps := _components(trees)
	var home: Dictionary = {}
	for comp: Dictionary in comps:
		for id: String in comp:
			var rec: Dictionary = comp[id]
			if Vector2(float(rec["x_m"]) - gc.x, float(rec["y_m"]) - gc.y).length() < 0.01:
				home = comp
	var others := 0
	for comp: Dictionary in comps:
		if comp != home:
			others += comp.size()
	print("[test] the village's %d trees fall into %d clusters; the grove's holds %d, the others %d" % [trees.size(), comps.size(), home.size(), others])
	check(home.size() >= 5, "4. the grove's cluster holds %d trees" % home.size())
	check(others >= 1, "4. and %d trees of the village are beyond a 30 m gap of it (a road, a field, open ground)" % others)
	var escaped := 0
	var lit_inside := 0
	for s in range(1, 40):
		var f := _fresh_state()
		var start: Dictionary = (home.values() as Array)[s % home.size()]
		f.add_lit(start, 1, 0.0, "bomb")
		for turn in range(2, 6):
			f.resolve_turn(turn, s, {}, [], FireFakes.stand(0.0, 0.0))
		for id: String in f.trees:
			if not home.has(id):
				escaped += 1
			else:
				lit_inside += 1
	eq(escaped, 0, "4. over 39 fires and 4 turns of spread no tree outside the cluster was ever lit")
	check(lit_inside > 39, "4. while inside it the fire spread (%d trees lit in all)" % lit_inside)
	return true

# The clusters of `trees` (records): trees joined while the canopy gap is under the spread reach. [{id: record}, ...]
func _components(trees: Array) -> Array:
	var reach := FireFakes.rules().spread_reach_m
	var label: Array = []
	label.resize(trees.size())
	label.fill(-1)
	var out: Array = []
	for i in trees.size():
		if int(label[i]) >= 0:
			continue
		var k := out.size()
		var comp := {}
		var queue: Array = [i]
		label[i] = k
		while not queue.is_empty():
			var a: Dictionary = trees[queue.pop_back()]
			comp[str(a["id"])] = a
			for j in trees.size():
				if int(label[j]) >= 0:
					continue
				var b: Dictionary = trees[j]
				var gap := Vector2(float(a["x_m"]) - float(b["x_m"]), float(a["y_m"]) - float(b["y_m"])).length() - float(a["r_m"]) - float(b["r_m"])
				if gap < reach:
					label[j] = k
					queue.append(j)
		out.append(comp)
	return out

# --- 5. Burning out -------------------------------------------------------------------------------------------------

func _burning_out() -> bool:
	var f := FireFakes.state(null)
	f.add_lit(FireFakes.tree(1, 50.0, 60.0, 8.0), 4, 1.5, "bomb")
	var outs: Array = []
	for turn in range(4, 9):
		var res: Dictionary = f.resolve_turn(turn, 5, {}, [], FireFakes.stand(0.0, 0.0))
		for e: Dictionary in FireFakes.events_of(res["events"], "fire_out"):
			outs.append(e)
	eq(outs.size(), 1, "5. exactly one fire_out")
	if outs.size() == 1:
		var e: Dictionary = outs[0]
		eq(int(e["turn"]), 6, "5. lit in turn 4 it burns in 4, 5 and 6 and goes out in turn 6")
		near(float(e["t"]), 5.0, 1e-12, "5. at the end of the turn (t = turn_seconds)")
		eq(str(e["tree"]), "f1", "5. the tree")
		near(float(e["x"]), 50.0, 1e-9, "5. at its place (metres)")
	var feed: Array = f.feed()
	eq(feed.size(), 1, "5. the feed keeps a tree that burnt out")
	eq(int((feed[0] as Dictionary)["out_turn"]), 6, "5. with its last burning turn")
	var rec: Dictionary = f.record("f1")
	check(f.smoking(rec, f.game_time(4, 1.5)), "5. it smokes from the moment it is lit")
	check(not f.smoking(rec, f.game_time(4, 1.0)), "5. and not before")
	check(f.smoking(rec, f.game_time(6, 4.99)), "5. through the end of its last turn")
	check(not f.smoking(rec, f.game_time(7, 0.0)) and not f.smoking(rec, f.game_time(6, 5.0)), "5. and no more once it is out")
	check(f.burnt_out(rec, f.game_time(7, 0.0)) and not f.burnt_out(rec, f.game_time(6, 4.9)), "5. it is a trunk from the turn after")
	# a burnt-out tree does not burn again, spread again or hurt
	var res2: Dictionary = f.resolve_turn(7, 5, {}, [], FireFakes.stand(50.0, 60.0))
	eq(res2["events"], [], "5. a tree that has burnt out does nothing")
	# the other reading of "3 turns" is a switch in the data
	var alt: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FireRules.PATH))
	((alt["burn"] as Dictionary)["counts_lit_turn"] as Dictionary)["value"] = false
	eq(FireRules.new(alt, true).out_turn(4), 7, "5. (the other reading, counts_lit_turn false: three whole turns after the lit one)")
	return true

# --- 6. Damage ---------------------------------------------------------------------------------------------------------

func _tank_world(count: int = 1) -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	for i in count:
		w.add_unit({"id": "tank%d" % i, "type": "tank", "side": "axis", "controller": "ai", "x": 100.0, "y": 100.0, "heading": 0.0, "speed": 0.0})
	return w

# How often a tank at `edge` m beyond the canopy edge of one burning tree (centre (0, 0), radius 8) loses a pip in turn 1, over `runs` seeds.
func _hurt_rate(edge: float, runs: int, extra_trees: Array = [], unit_type: String = "tank") -> float:
	var w := World.new()
	w.quiet = true
	var at := Vector2(8.0 + edge, 0.0)
	var spec := {"id": "u", "type": unit_type, "side": "axis", "controller": "ai", "x": at.x, "y": at.y, "heading": 0.0}
	if unit_type == "tank":
		spec["speed"] = 0.0
	w.add_unit(spec)
	var hurt := 0
	for s in range(1, runs + 1):
		var f := FireFakes.state(null)
		f.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
		for t: Dictionary in extra_trees:
			f.add_lit(t, 1, 0.0, "bomb")
		var res: Dictionary = f.resolve_turn(1, s, w.units, [], FireFakes.stand(at.x, at.y))
		if (res["hurt"] as Dictionary).has("u"):
			hurt += 1
	return float(hurt) / float(runs)

func _damage() -> bool:
	var runs := 3000
	_in_band(_hurt_rate(0.0, runs), 0.1, runs, "6. at a burning canopy's edge: 10% a turn")
	_in_band(_hurt_rate(-6.0, runs), 0.1, runs, "6. under the canopy: the same 10%")
	_in_band(_hurt_rate(12.5, runs), 0.05, runs, "6. 12.5 m beyond: 5% (it fades with the distance, Alex)")
	_in_band(_hurt_rate(20.0, runs), 0.02, runs, "6. 20 m beyond: 2%")
	eq(_hurt_rate(25.0, 500), 0.0, "6. 25 m beyond: never")
	eq(_hurt_rate(40.0, 500), 0.0, "6. farther: never")
	var a := _hurt_rate(5.0, runs)
	var b := _hurt_rate(15.0, runs)
	check(a > b, "6. nearer is likelier (%.3f against %.3f)" % [a, b])
	# several trees combine as 1 - product(1 - p); two at the edge give 19%
	_in_band(_hurt_rate(0.0, runs, [FireFakes.tree(2, 16.0, 0.0, 8.0)]), 1.0 - 0.9 * 0.9, runs, "6. two burning trees at the unit combine as 1 - product(1 - p): 19% (PROPOSED)")
	# a plane is untouched; so is a unit the fire does not hurt
	eq(_hurt_rate(0.0, 600, [], "light_fighter"), 0.0, "6. a plane over the burning trees is untouched")
	# one pip, at most
	var w := _tank_world(1)
	var most := 0
	for s in range(1, 400):
		var f2 := FireFakes.state(null)
		for i in 6:
			f2.add_lit(FireFakes.tree(i + 1, 90.0 + float(i) * 3.0, 100.0, 8.0), 1, 0.0, "bomb")
		var res: Dictionary = f2.resolve_turn(1, s, w.units, [], FireFakes.stand(100.0, 100.0))
		for uid: String in res["hurt"]:
			most = maxi(most, int((res["hurt"][uid] as Dictionary)["pips"]))
	eq(most, 1, "6. a unit loses at most one pip a turn, however many trees burn round it (PROPOSED)")
	# THE CLOSEST APPROACH: a tank driving past a tree, the event at the moment it is nearest (PROPOSED)
	var w2 := World.new()
	w2.quiet = true
	w2.add_unit({"id": "u", "type": "tank", "side": "axis", "controller": "ai", "x": 0.0, "y": 0.0, "heading": 0.0, "speed": 0.0})
	var drive := func(_uid: String, t: float) -> Dictionary: return {"x": -100.0 + 40.0 * t, "y": 20.0}
	var first_t := -1.0
	for s in range(1, 300):
		var f3 := FireFakes.state(null)
		f3.add_lit(FireFakes.tree(1, 0.0, 0.0, 8.0), 1, 0.0, "bomb")
		var res3: Dictionary = f3.resolve_turn(1, s, w2.units, [], drive)
		if (res3["hurt"] as Dictionary).has("u"):
			first_t = float((res3["hurt"]["u"] as Dictionary)["t"])
			break
	near(first_t, 2.5, 1e-9, "6. the pip is lost at the unit's closest approach to the burning canopy (it passes at t = 2.5 s)")
	# a tree lit later in the turn counts from its moment
	var w3 := _tank_world(1)
	var earliest := 99.0
	for s in range(1, 400):
		var f4 := FireFakes.state(null)
		f4.add_lit(FireFakes.tree(1, 100.0, 100.0, 8.0), 1, 4.0, "spread", "x")
		var res4: Dictionary = f4.resolve_turn(1, s, w3.units, [], FireFakes.stand(100.0, 100.0))
		if (res4["hurt"] as Dictionary).has("tank0"):
			earliest = minf(earliest, float((res4["hurt"]["tank0"] as Dictionary)["t"]))
	check(earliest >= 4.0 and earliest < 99.0, "6. a tree lit at 4.0 s hurts from 4.0 s (first pip at %.2f s)" % earliest)
	return true

# --- 7. Through the World ------------------------------------------------------------------------------------------------

func _bomb_world(seed_v: int, with_fire: bool) -> World:
	var w := BombWorlds.world(seed_v)
	if with_fire:
		check(w.enable_fire(_src), "7. the World takes the fire: %s" % str(w.errors))
	var c: Vector2 = _grove["centre"]
	BombWorlds.drop_bombs(w, [BombWorlds.record(w, c.x, c.y, 2.0)])
	return w

func _through_the_world() -> bool:
	var res: Dictionary = {}
	var seed_used := 0
	for s in range(1, 30):
		var w := _bomb_world(s, true)
		res = BombWorlds.turn(w)
		if not FireFakes.events_of(res["events"], "fire_ignite").is_empty():
			seed_used = s
			break
	if not check(seed_used > 0, "7. a bomb in the grove set trees alight for some seed"):
		return false
	var evs: Array = res["events"]
	var last_t := -1.0
	var sorted := true
	for e: Dictionary in evs:
		if float(e["t"]) < last_t - 1e-12:
			sorted = false
		last_t = float(e["t"])
	check(sorted, "7. the turn's events are in time order with the fire's merged in")
	var impact_i := -1
	var ignite_i := -1
	for i in evs.size():
		if str(evs[i]["type"]) == "bomb_impact" and impact_i < 0:
			impact_i = i
		if str(evs[i]["type"]) == "fire_ignite" and ignite_i < 0:
			ignite_i = i
	check(impact_i >= 0 and ignite_i > impact_i, "7. the bomb_impact comes before the fires it lit (same moment, merged in order)")
	check(res.has("fire") and (res["fire"] as Dictionary).has("trees"), "7. the turn's result carries the fire")
	eq((res["fire"]["trees"] as Array).size(), FireFakes.events_of(evs, "fire_ignite").size(), "7. one tree in the result for each fire_ignite")
	# the same seed draws the same fire; another seed another
	var again := BombWorlds.turn(_bomb_world(seed_used, true))
	eq(JSON.stringify(again["events"]), JSON.stringify(res["events"]), "7. the same game seed draws the same turn, events and all")
	eq(JSON.stringify(again["fire"]), JSON.stringify(res["fire"]), "7. and the same fire")
	var differs := false
	for s in range(100, 112):
		var other := BombWorlds.turn(_bomb_world(s, true))
		if JSON.stringify(other["fire"]) != JSON.stringify(res["fire"]):
			differs = true
			break
	check(differs, "7. another game seed draws another fire")
	# the combat's dice are not the fire's: the fire changes none of the combat events
	var plain := BombWorlds.turn(_bomb_world(seed_used, false))
	var combat_with: Array = []
	for e: Dictionary in evs:
		if not str(e["type"]).begins_with("fire_"):
			combat_with.append(e)
	eq(JSON.stringify(combat_with), JSON.stringify(plain["events"]), "7. the fire leaves the combat's events exactly as they are without it")
	check(not plain.has("fire"), "7. FIRE OFF: the result has no fire")
	for e: Dictionary in plain["events"]:
		check(not str(e["type"]).begins_with("fire_"), "7. FIRE OFF: no fire event")
	var off := World.new()
	check(off.fire == null and off.net_fire().is_empty(), "7. FIRE OFF: no state")
	# a tank near a burning tree loses its last pip: destroyed where it stood
	var downed := false
	for s in range(1, 120):
		var w := BombWorlds.world(s)
		w.enable_fire(null)
		w.fire.add_lit(FireFakes.tree(1, 112.0, 2500.0, 8.0), 1, 0.0, "bomb")
		# (the tower is at (2500, 2500); the tank rolls east along y = 2500 at 5 m/s past the tree at x = 112 from x = 100)
		var tid := w.add_unit({"id": "tank", "type": "tank", "side": "allies", "controller": "player", "x": 100.0, "y": 2500.0, "heading": 0.0, "speed": 5.0})
		(w.units[tid] as Unit).health = 1
		var r := BombWorlds.turn(w)
		if r.is_empty():
			continue
		var tu: Unit = w.units["tank"]
		if tu.health > 0:
			continue
		downed = true
		check(tu.down and tu.fate == Unit.FATE_DESTROYED, "7. a tank that loses its last pip is destroyed")
		check(not is_nan(tu.down_at) and tu.down_at >= 0.0 and tu.down_at <= 5.0, "7. at a moment of the turn (%.2f s)" % tu.down_at)
		var types: Array = []
		for e: Dictionary in r["events"]:
			if str(e.get("unit", "")) == "tank":
				types.append(str(e["type"]))
		check(types.has("fire_damage") and types.has("hit") and types.has("down"), "7. with a fire_damage, a hit and a down event: %s" % str(types))
		for e: Dictionary in r["events"]:
			if str(e["type"]) == "down" and str(e["unit"]) == "tank":
				eq(str(e["fate"]), "destroyed", "7. fate destroyed")
			if str(e["type"]) == "hit" and str(e["unit"]) == "tank":
				eq(str(e["weapon"]), "fire", "7. the hit is the fire's")
				eq(int(e["health"]), 0, "7. leaving 0 pips")
		check(tu.x < 100.0 + 5.0 * 5.0 - 1.0 and tu.speed == 0.0, "7. it stopped where it was hurt, not at the end of its path (x = %.1f)" % tu.x)
		var net: Dictionary = (r["units"] as Dictionary)["tank"]
		check(int(net["health"]) == 0 and bool(net["down"]), "7. and the result's final state says so")
		break
	check(downed, "7. some seed's fire destroyed the one-pip tank")
	# which scenarios have the fire
	for id: String in ["strike", "intercept", "sandbox"]:
		var sc := SandboxScenario.new(id, true)
		check(sc.ok() and not sc.fire_on, "7. the %s scenario has the fire off" % id)
	var sp := SandboxScenario.new("suppress", true)
	check(sp.ok() and sp.fire_on, "7. Suppress has it on")
	var wsp := SuppressWorlds.new_world()
	sp.populate(wsp)
	check(wsp.fire != null and wsp.fire.source != null and wsp.fire.rules.ok(), "7. and its World holds a fire with the seed's trees")
	var sp_off := SandboxScenario.new("suppress", true, {"fire": false})
	var wsp_off := SuppressWorlds.new_world()
	sp_off.populate(wsp_off)
	check(not sp_off.fire_on and wsp_off.fire == null, "7. the knob's override puts it out")
	var st_on := SandboxScenario.new("strike", true, {"fire": true})
	var wst := World.new()
	wst.quiet = true
	st_on.populate(wst)
	check(st_on.fire_on and wst.fire != null, "7. and lights it in a scenario that has it off")
	var bad := SandboxScenario.new("strike", true, {"fire": "yes"})
	check(not bad.ok(), "7. a fire switch that is not true or false is an error")
	return true

# --- 8. Burnt cover ------------------------------------------------------------------------------------------------------

func _burnt_cover() -> bool:
	var w := World.new()
	w.quiet = true
	_gm.attach(w)
	check(w.enable_fire(_src), "8. the World takes the fire")
	var c: Vector2 = _grove["centre"]
	var rule: RefCounted = ConcealRules.shared()
	check(rule.ok() and rule.on, "8. the concealment rule is on")
	w.add_player("local")
	var tid := w.add_unit({"id": "gun", "type": "tank", "side": "axis", "controller": "ai", "x": c.x, "y": c.y, "heading": 0.0, "speed": 0.0})
	if not check(tid == "gun", "8. a mobile ground unit stands in the grove"):
		return false
	var gun: Unit = w.units["gun"]
	check(rule.covered(w, gun, c.x, c.y), "8. in the grove (woods density %.2f) it is in cover, no fire yet" % float(_gm.woods_at(c.x, c.y)))
	var near_trees: Array = _src.trees_in_disc(c.x, c.y, 20.0)
	check(near_trees.size() >= 3, "8. %d trees within 20 m of the grove's centre" % near_trees.size())
	eq(w.fire.burnt_scale(c.x, c.y, w.fire.game_time(9, 0.0)), 1.0, "8. nothing has burnt: the share is 1")
	# half of them burn out: the share is the half that did not; the time matters
	var half := near_trees.size() / 2
	for i in half:
		w.fire.add_lit(near_trees[i], 1, 0.0, "bomb")   # lit in turn 1, out after turn 3
	var share := 1.0 - float(half) / float(near_trees.size())
	near(w.fire.burnt_scale(c.x, c.y, w.fire.game_time(4, 0.0)), share, 1e-9, "8. after they burn out the density is scaled by the share of the trees left (%.2f)" % share)
	eq(w.fire.burnt_scale(c.x, c.y, w.fire.game_time(3, 4.0)), 1.0, "8. while they still burn they still give cover (the moment matters)")
	eq(w.fire.burnt_scale(c.x, c.y, w.fire.game_time(1, 0.0)), 1.0, "8. and before they are lit")
	# all of them: no cover left
	for i in range(half, near_trees.size()):
		w.fire.add_lit(near_trees[i], 1, 0.0, "bomb")
	eq(w.fire.burnt_scale(c.x, c.y, w.fire.game_time(4, 0.0)), 0.0, "8. all burnt out: the share is 0")
	# the moments: t is seconds into the last resolve of the World's turn, t < 0 is as the world stands (the start of the turn being planned, the end of the
	# turn just resolved); the trees lit in turn 1 burn in 1, 2 and 3 and are trunks from game second 15
	w.turn = 3
	w.phase = World.PHASE_RESOLVED
	check(rule.covered(w, gun, c.x, c.y, 4.5), "8. turn 3 played back, 4.5 s in: the trees still burn, and still give cover")
	check(not rule.covered(w, gun, c.x, c.y), "8. turn 3 resolved, as the world stands (its end): they have burnt out, no cover")
	w.phase = World.PHASE_PLANNING
	check(rule.covered(w, gun, c.x, c.y), "8. planning turn 3 (its start): they still burn, cover")
	w.turn = 4
	check(not rule.covered(w, gun, c.x, c.y), "8. planning turn 4: trunks, no cover")
	eq(rule.sight_limit_m(w, gun, c.x, c.y, 800.0), 800.0, "8. an observer sees it to its full sight again")
	w.turn = 3
	w.phase = World.PHASE_RESOLVED
	eq(rule.sight_limit_m(w, gun, c.x, c.y, 800.0, 2.0), minf(800.0, rule.radius_m), "8. while turn 3 plays back (2 s in) it is in cover: seen only to the woods radius")
	# ground movement is not touched: the going still slows a tank in woods (the density the ground rule reads is unscaled)
	check(float(w.ground.woods_fn.call(c.x, c.y)) >= 0.5, "8. the ground rule still reads the unscaled woods density (trunks still slow a tank)")
	return true

# --- 9. Suppress, played -------------------------------------------------------------------------------------------------

func _suppress_played() -> bool:
	if not SuppressWorlds.real_units():
		print("[test] the units track's files are not there: section 9 skipped")
		return true
	var games := 0
	var lit_games := 0
	var damaged := 0
	var lit_total := 0
	var first_feed := ""
	for seed_v in range(1, 9):
		var g := SuppressPlay.new(seed_v)
		g.dive_band = "low"
		if not check(g.ok() and g.world.fire != null, "9. a Suppress game with the fire on (seed %d): %s" % [seed_v, str(g.errors)]):
			return false
		var result := g.play("bomb", 20)
		games += 1
		var ignites := 0
		var outs := 0
		var last_t_by_turn := {}
		for e: Variant in g.events:
			var ev: Dictionary = e
			var typ := str(ev["type"])
			if typ == "fire_ignite":
				ignites += 1
			elif typ == "fire_out":
				outs += 1
			elif typ == "fire_damage":
				damaged += 1
				check(g.world.units[str(ev["unit"])].def.domain != "air", "9. the fire hurts no plane (seed %d)" % seed_v)
			if typ.begins_with("fire_"):
				check(float(ev["t"]) >= 0.0 and float(ev["t"]) <= 5.0 + 1e-9, "9. a fire event's moment is inside its turn")
		eq(g.world.fire.lit_count(), ignites, "9. seed %d: the trees lit are the fire_ignite events (%d)" % [seed_v, ignites])
		check(outs <= ignites, "9. seed %d: no more fires out than lit" % seed_v)
		if ignites > 0:
			lit_games += 1
			lit_total += ignites
			if first_feed == "":
				first_feed = JSON.stringify(g.world.fire.feed())
				var again := SuppressPlay.new(seed_v)
				again.dive_band = "low"
				again.play("bomb", 20)
				eq(JSON.stringify(again.world.fire.feed()), first_feed, "9. the same seed plays out the same fire (seed %d)" % seed_v)
		check(str(result.get("state", "")) != "", "9. seed %d played to a result: %s" % [seed_v, str(result.get("state", ""))])
	print("[test] Suppress with the fire on: %d of %d scripted games lit trees (%d in all), %d fire_damage events" % [lit_games, games, lit_total, damaged])
	return true
