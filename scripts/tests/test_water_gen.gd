extends "res://scripts/test_support/test_case.gd"

# THE WATER GENERATOR (Track WB: scripts/world/water_gen.gd, water_contour.gd; data/world/water.json;
# the colour roles of scripts/render/water_draw.gd), headless -- plans and numbers, no pixels (the board,
# scripts/ui/boards/water_board_shot.gd, is the pixels). What it holds the water to:
#
#   DATA         water.json parses, and every record in it is read by WaterGen or WaterDraw (nothing is dead).
#   DETERMINISM  two waters of one seed are the same (signature of the sea, the river and sample depths);
#                another seed is another water.
#   DRY SITES    on seed 20261009 the village (outline and inside), the radio tower, both batteries, every field
#                and the whole road, but the gap at the river, are dry; so on six more seeds.
#   THE SEA      the three depth steps exist and start at 0, 6 and 18 m; the terrain's field is CAPPED by the water's mask
#                so no upland stands in deep water (islands are islands of landness, not upland patches); the sea's rings
#                are closed, nested by step, outer rings clockwise on screen.
#   THE SHAPE    NOT A SQUARE OF LAND (Alex, 2026-10-10): over ten seeds the shore leaves a straight line (coast_stats().spread
#                above a floor in data quality.*, per seed and in the median), the mainland does not fill its bounding box
#                (fill under a ceiling), the sea has a real coast, the seeds differ (at least four shapes, and sea shares
#                that differ), and no seed's sea floods the layout.
#   THE RIVER    it crosses the road once, square, in a gap no longer than the data says; it is as wide there as the
#                data says, widens and deepens downstream, and runs to the sea.
#   COLOURS      the water steps are roles: in gamut, lighter than the shadow tint and the enemy accent, darker than
#                the paper, more chromatic with depth and less chromatic than the accents, a hue apart from both blues.
#
# The numbers measured are printed as [water] lines for the report.

const WaterGen = preload("res://scripts/world/water_gen.gd")
const WaterContour = preload("res://scripts/world/water_contour.gd")
const WaterDraw = preload("res://scripts/render/water_draw.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const RenderParams = preload("res://scripts/world/render_params.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")

const SEED := 20261009
const SHAPE_SEEDS := [20261009, 1, 2, 3, 4, 5, 6, 7, 8, 9]

func setup(_main) -> void:
	timeout_seconds = 300.0
	var t0 := Time.get_ticks_usec()
	eq(_body(), "done", "the water test ran to its end (a compile error in a dependency would stop it silently)")
	print("[water] test total %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	finish()

func _body() -> String:
	var terrain := Terrain.new(SEED)
	var water := WaterGen.new(SEED, terrain)
	if not check(water.ok(), "the water of seed %d builds: %s %s" % [SEED, water.errors, water.data.errors]):
		return "build failed"
	print("[water] seed %d built in %.0f ms; %s" % [SEED, water.diagnostics.get("build_ms", -1.0), water.diagnostics.get("sea", {})])
	_data(water)
	_determinism(water)
	_dry(water, terrain)
	_steps(water, terrain)
	_rings(water)
	_river(water)
	_colours()
	_contour()
	_cap(water, terrain)
	_shapes()
	return "done"

# --- data -------------------------------------------------------------------------------------------------------

func _data(water: WaterGen) -> void:
	var draw := WaterDraw.new(RenderParams.new())
	check(draw.ok(), "WaterDraw reads water.json: %s" % [draw.errors])
	var a := water.data.unused()
	var b := draw.data.unused()
	var dead: Array[String] = []
	for p in a:
		if p in b:
			dead.append(p)
	eq(dead, [] as Array[String], "every record of water.json is read by WaterGen or WaterDraw")
	eq(draw.options.keys().size(), 6, "six options in data (A to F)")
	for L in ["A", "B", "C", "D", "E", "F"]:
		check(draw.options.has(L) and (draw.options[L] as Dictionary).has("title"), "option %s has a title" % L)
	eq(draw.variants.size(), 3, "three palette variants in data")
	check(draw.options.has(draw.working_default), "the working default (%s) is an option" % draw.working_default)
	var rec: Variant = (JSON.parse_string(FileAccess.get_file_as_string("res://data/world/water.json")) as Dictionary)["levels"]["heights_m"]
	eq((rec as Dictionary).get("decision"), "water-layer", "the three depths carry Alex's decision (water-layer); the rest of the file is proposed")

# --- determinism ------------------------------------------------------------------------------------------------------

func _determinism(water: WaterGen) -> void:
	var again := WaterGen.new(SEED)
	check(again.ok(), "a second water of the seed builds")
	eq(again.signature(), water.signature(), "two waters of one seed are the same water")
	var other := WaterGen.new(SEED + 1)
	check(other.signature() != water.signature(), "another seed is another water")

# --- the sites stay dry -------------------------------------------------------------------------------------------------------

static func _sites_dry(water: WaterGen, _terrain: Terrain, use_level: bool = true) -> Dictionary:
	var lay: RefCounted = water.layout()
	var v: Dictionary = lay.village()
	var wet: Array[String] = []
	var n := 0
	var poly: PackedVector2Array = v.polygon
	for p in poly:
		n += 1
		if _wet(water, p.x, p.y, use_level):
			wet.append("village outline %s" % p)
	var rect := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		rect = rect.expand(p)
	var y := rect.position.y
	while y < rect.end.y:
		var x := rect.position.x
		while x < rect.end.x:
			if Geometry2D.is_point_in_polygon(Vector2(x, y), poly):
				n += 1
				if _wet(water, x, y, use_level):
					wet.append("village %s" % Vector2(x, y))
			x += 20.0
		y += 20.0
	var sites: Dictionary = lay.sites()
	var tower: Vector2 = sites.radio_tower
	n += 1
	if _wet(water, tower.x, tower.y, use_level):
		wet.append("tower")
	for b: Vector2 in sites.aa_battery:
		n += 1
		if _wet(water, b.x, b.y, use_level):
			wet.append("battery %s" % b)
		for k in 4:
			var q := b + Vector2.from_angle(float(k) * PI * 0.5) * 25.0
			n += 1
			if _wet(water, q.x, q.y, use_level):
				wet.append("battery ring %s" % q)
	for f: PackedVector2Array in lay.fields():
		for p in f:
			n += 1
			if _wet(water, p.x, p.y, use_level):
				wet.append("field corner %s" % p)
		var c := Vector2.ZERO
		for p in f:
			c += p
		c /= float(f.size())
		n += 1
		if _wet(water, c.x, c.y, use_level):
			wet.append("field centre %s" % c)
	var road: PackedVector2Array = lay.road()
	var map := water.map_rect()
	for p in road:
		if not map.has_point(p):
			continue
		if water.river_crossing.is_finite() and p.distance_to(water.river_crossing) <= 130.0:
			continue
		n += 1
		if _wet(water, p.x, p.y, use_level):
			wet.append("road %s" % p)
	return {"wet": wet, "samples": n}

static func _wet(water: WaterGen, x: float, y: float, use_level: bool) -> bool:
	return water.is_wet(x, y) if use_level else water.s_at(x, y) > 0.0

func _dry(water: WaterGen, terrain: Terrain) -> void:
	var r := _sites_dry(water, terrain)
	eq(r["wet"], [] as Array[String], "seed %d: the village, the tower, both batteries, the fields and the road are dry" % SEED)
	print("[water] seed %d: %d keep-dry samples checked, %d wet; the sea's first choice was dry: %s; keep_dry_ok %s" % [
		SEED, r["samples"], (r["wet"] as Array).size(), water.diagnostics["sea"]["dry_first_try"], water.diagnostics["keep_dry_ok"]])

# --- the steps ----------------------------------------------------------------------------------------------------------------------------

func _steps(water: WaterGen, terrain: Terrain) -> void:
	eq(water.step_of(-3.0), -1, "land is no step")
	eq(water.step_of(0.0), -1, "depth 0 is the shore: dry")
	eq(water.step_of(0.1), 0, "0.1 m is shallows")
	eq(water.step_of(5.9), 0, "5.9 m is shallows")
	eq(water.step_of(6.0), 1, "6 m starts the shelf")
	eq(water.step_of(17.9), 1, "17.9 m is shelf")
	eq(water.step_of(18.0), 2, "18 m starts the deep")
	eq(water.step_of(90.0), 2, "90 m is deep")
	eq(water.heights_m, PackedFloat64Array([-3.0, -10.0, -30.0]), "the seabed at -3, -10 and -30 m (Alex: 'Sounds good')")
	var wf := water.wet_fraction(100.0)
	check(float(wf["water"]) > 0.1 and float(wf["water"]) < 0.5, "a sea of a fifth to a half of the map on seed %d (%s)" % [SEED, wf])
	for k in ["shallows", "shelf", "deep"]:
		check(float(wf[k]) > 0.005, "step %s exists (%.3f of the map)" % [k, wf[k]])
	print("[water] seed %d: water %.1f%% of the map: shallows %.1f%%, shelf %.1f%%, deep %.1f%%" % [SEED, 100.0 * float(wf["water"]), 100.0 * float(wf["shallows"]), 100.0 * float(wf["shelf"]), 100.0 * float(wf["deep"])])
	# no upland stands in deep water (the cap), and a level-0 point under water is water
	var deep_uplands := 0
	var wet0 := 0
	var shore_uplands := 0
	var y := 300.0
	while y < 4800.0:
		var x := 150.0
		while x < 4900.0:
			var sv := water.s_at(x, y)
			if sv > 3.0:
				var lev := int(water.terrain().level_at(x, y))
				if lev > 0:
					deep_uplands += 1
				else:
					wet0 += 1
					check(water.is_wet(x, y), "level-0 ground under the sea is water at (%d, %d)" % [x, y])
			elif sv > 0.0 and int(water.terrain().level_at(x, y)) > 0:
				shore_uplands += 1
				check(not water.is_wet(x, y), "an upland at the shore is not water at (%d, %d)" % [x, y])
			x += 131.0
		y += 131.0
	eq(deep_uplands, 0, "no upland stands more than 3 m under the sea (the terrain's field is capped by the water's mask)")
	check(wet0 > 50, "the sea has deep level-0 ground (%d samples)" % wet0)
	print("[water] sea samples: %d deep level-0 water, %d uplands under more than 3 m of water, %d coastal cliffs (upland at the shore, s 0 to 3 m)" % [wet0, deep_uplands, shore_uplands])

# THE CAP (what integration will need from the terrain): the capped terrain's field is the raw field under the mask, the mask is
# above the field's range inland and under the first threshold under the sea, and the layout (made on the raw terrain) stands.
func _cap(water: WaterGen, terrain: Terrain) -> void:
	var capped: RefCounted = water.terrain()
	var thr0: float = terrain.thresholds[0]
	var lower := 0
	var same := 0
	var worse := 0
	var rng := Mulberry32.new(77)
	for i in 400:
		var x := rng.next() * 5000.0
		var y := rng.next() * 5000.0
		var raw: float = terrain.field_at(x, y)
		var c: float = capped.field_at(x, y)
		var cap: float = water.field_cap(x, y)
		if c > raw + 1e-12:
			worse += 1
		elif c < raw - 1e-12:
			lower += 1
		else:
			same += 1
		check(absf(c - minf(raw, cap)) < 1e-9, "the capped field is min(field, cap) at (%d, %d)" % [x, y])
		if water.sea_s(x, y) > 1.0:
			check(cap < thr0, "under the sea the cap is under the first threshold (%.3f < %.3f) at (%d, %d)" % [cap, thr0, x, y])
	eq(worse, 0, "the cap never raises ground")
	check(lower > 0 and same > 100, "the cap lowers ground near the sea and leaves the rest (%d lowered, %d unchanged of 400)" % [lower, same])
	# the layout was made on the raw terrain and is the same one
	eq(capped.layout().signature(), terrain.layout().signature(), "the capped terrain shares the raw terrain's layout")
	print("[water] cap: %d of 400 samples lowered, %d unchanged" % [lower, same])

# A point of a coast of this water: the first dry-to-wet change on the row nearest the middle of the map that has one.
func _shore_of(water: WaterGen) -> Vector2:
	for dy in [0.0, 150.0, -150.0, 300.0, -300.0, 600.0, -600.0, 900.0, -900.0, 1200.0, -1200.0]:
		var y := 2500.0 + float(dy)
		var x := 100.0
		var prev := water.sea_s(x, y) > 0.0
		while x < 4900.0:
			x += 10.0
			var now := water.sea_s(x, y) > 0.0
			if now != prev and x > 800.0 and x < 4200.0 and y > 800.0 and y < 4200.0:
				return Vector2(x, y)
			prev = now
	return Vector2(2500, 2500)

func _rings(water: WaterGen) -> void:
	var shore := _shore_of(water)
	var rect := Rect2(shore - Vector2(500, 300), Vector2(1000, 600))
	var areas: Array[float] = []
	for k in 3:
		var rings := water.sea_rings(rect, k)
		check(rings.size() > 0, "step %d has rings over the coast" % k)
		var outer := 0.0
		for r: Dictionary in rings:
			check((r["pts"] as PackedVector2Array).size() >= 3, "a ring has points")
			if float(r["area"]) > 0.0:
				outer += float(r["area"])
			else:
				outer += float(r["area"])   # holes subtract
		areas.append(outer)
	check(areas[1] < areas[0] and areas[2] < areas[1], "the steps nest: the water at least 6 m deep is less than at least 0 m, and at least 18 m less again (%s)" % [areas])
	# a point of the 6 m ring is 6 m deep
	# (the rings close along the grid's padded border outside the rect: only points inside the rect are on the contour)
	var worst := 0.0
	var checked := 0
	for ring: Dictionary in water.sea_rings(rect, 1):
		var pts: PackedVector2Array = ring["pts"]
		for i in range(0, pts.size(), maxi(1, pts.size() / 80)):
			if rect.has_point(pts[i]):
				checked += 1
				worst = maxf(worst, absf(water.sea_s(pts[i].x, pts[i].y) - 6.0))
	check(checked > 10 and worst < 0.8, "the 6 m ring lies on the 6 m contour (%d points, worst %.2f m off)" % [checked, worst])
	print("[water] coast rings: areas of the three steps %s m2; the 6 m ring is within %.2f m of the 6 m contour" % [areas, worst])

func _river(water: WaterGen) -> void:
	var rec: Dictionary = water.diagnostics["river"]
	check(bool(rec.get("made", false)), "seed %d has a river: %s" % [SEED, rec.get("why", "")])
	check(water.river_crossing.is_finite(), "the river crosses the road")
	var lay: RefCounted = water.layout()
	var road: PackedVector2Array = lay.road()
	var x_at: Vector2 = water.river_crossing
	check(water.s_at(x_at.x, x_at.y) > 0.0, "the crossing is wet")
	# the wet stretch of the road at the crossing, and that it is the only one
	var wet_runs := 0
	var in_run := false
	var wet_len := 0.0
	var map := water.map_rect()
	for i in road.size():
		var wet := map.has_point(road[i]) and water.s_at(road[i].x, road[i].y) > 0.0
		if wet:
			if not in_run:
				wet_runs += 1
			in_run = true
			wet_len += 10.0
		else:
			in_run = false
	eq(wet_runs, 1, "the road is wet in ONE place: the river crosses it once")
	check(wet_len <= 95.0, "the gap in the road is short (%.0f m): the river crosses it, it does not run along it" % wet_len)
	var hw := float(rec["half_width_at_crossing_m"])
	check(hw >= 12.0 and hw <= 14.0, "the river is about 26 m wide where it crosses the road (half width %.1f)" % hw)
	check(wet_len >= 2.0 * hw * 0.8, "the gap is as wide as the river (%.0f m gap, %.0f m river)" % [wet_len, 2.0 * hw])
	# widens and deepens downstream
	var n := water.river_pts.size()
	check(water.river_hw[n / 4] < water.river_hw[n * 3 / 4], "the river widens downstream")
	check(water.river_dmax[n / 4] < water.river_dmax[n * 3 / 4], "the river deepens downstream")
	check(water.river_hw[0] < 4.0, "the spring is a brook (half width %.1f)" % water.river_hw[0])
	check(water.sea_s(water.river_mouth.x, water.river_mouth.y) > 0.0, "the river runs into the sea")
	# the section is a parabola: deepest in the middle, steps from the bank in
	var i := n * 3 / 4
	var c := water.river_pts[i]
	var t := (water.river_pts[i + 1] - water.river_pts[i - 1]).normalized()
	var nr := Vector2(-t.y, t.x)
	var mid := water.river_s(c.x, c.y)
	var edge := water.river_s(c.x + nr.x * water.river_hw[i] * 0.9, c.y + nr.y * water.river_hw[i] * 0.9)
	check(mid > edge and mid > 6.0 and edge > 0.0 and edge < 6.0, "the lower river: shelf in the middle (%.1f m), shallows at the bank (%.1f m)" % [mid, edge])
	print("[water] river: %.0f m long, %.0f m wide at the road (gap %.0f m), spring %s, mouth %s, %.1f m deep in the middle at three quarters" % [
		water.river_length, 2.0 * hw, wet_len, water.river_source, water.river_mouth, mid])
	# a ribbon for each step
	var rect := Rect2(x_at - Vector2(300, 300), Vector2(600, 600))
	check(water.river_runs(rect, 0).size() > 0, "river ribbons are made for the channel")
	check(water.river_edges(rect, 0).size() > 0, "river banks are made")

# --- colour roles ---------------------------------------------------------------------------------------------------------------

func _colours() -> void:
	var P := RenderParams.new()
	var d := WaterDraw.new(P)
	var st := UiStyle.new()
	var paper := _lch(P.PAPER)
	var tint := _lch(P.shadowCol)
	var side_b := _lch(st.palette["side_b"])
	var side_a := _lch(st.palette["side_a"])
	var prev := paper
	for k in 3:
		var c := _lch(d.steps[k])
		check(WaterDraw.in_gamut(paper.x - [0.03, 0.11, 0.2][k], [0.032, 0.05, 0.066][k], d.hue_deg), "step %d is inside sRGB without clamping" % k)
		check(c.x < prev.x, "step %d is darker than the one before it (L %.3f < %.3f)" % [k, c.x, prev.x])
		check(c.y < tint.y and c.y < side_b.y and c.y < side_a.y, "step %d is less chromatic than the shadow tint and both accents (C %.3f)" % [k, c.y])
		prev = c
	check(_lch(d.steps[1]).y > _lch(d.steps[0]).y and _lch(d.steps[2]).y > _lch(d.steps[1]).y, "more saturated with depth (Alex)")
	check(_lch(d.steps[0]).x < paper.x, "the shallows are under the paper's lightness")
	check(_lch(d.steps[2]).x > side_b.x and _lch(d.steps[2]).x > tint.x, "the deepest step is lighter than the enemy accent and the shadow tint: they read on it")
	var dh_tint := absf(angle_difference(deg_to_rad(d.hue_deg), deg_to_rad(tint.z))) * 180.0 / PI
	var dh_b := absf(angle_difference(deg_to_rad(d.hue_deg), deg_to_rad(side_b.z))) * 180.0 / PI
	check(dh_tint >= 15.0 and dh_b >= 30.0, "the water hue is apart from the shadow tint (%.0f degrees) and the enemy accent (%.0f degrees)" % [dh_tint, dh_b])
	print("[water] hue %d: %.0f degrees from the shadow tint, %.0f from the slate accent; steps L %s C %s" % [int(d.hue_deg), dh_tint, dh_b,
		[snappedf(_lch(d.steps[0]).x, 0.001), snappedf(_lch(d.steps[1]).x, 0.001), snappedf(_lch(d.steps[2]).x, 0.001)], [snappedf(_lch(d.steps[0]).y, 0.001), snappedf(_lch(d.steps[1]).y, 0.001), snappedf(_lch(d.steps[2]).y, 0.001)]])
	for v: Dictionary in d.variants:
		var dv := WaterDraw.new(P, float(v["hue_deg"]))
		for k in 3:
			check(WaterDraw.in_gamut(_lch(P.PAPER).x - [0.03, 0.11, 0.2][k], [0.032, 0.05, 0.066][k], float(v["hue_deg"])), "variant %s step %d is in gamut" % [v["name"], k])
		check(dv.ok(), "variant %s resolves" % v["name"])

static func _lch(c: Color) -> Vector3:
	var lab := TerrainDraw.to_oklab(c)
	var h := rad_to_deg(atan2(lab.z, lab.y))
	if h < 0.0:
		h += 360.0
	return Vector3(lab.x, sqrt(lab.y * lab.y + lab.z * lab.z), h)

# --- marching squares -----------------------------------------------------------------------------------------------------------------

func _contour() -> void:
	var cols := 40
	var rows := 40
	var vals := PackedFloat64Array()
	vals.resize(cols * rows)
	for j in rows:
		for i in cols:
			vals[j * cols + i] = 10.0 - Vector2(float(i) - 19.5, float(j) - 19.5).length()   # a cone: the 0 contour is a circle of radius 10
	var rings := WaterContour.rings(vals, cols, rows, 100.0, 200.0, 1.0, 0.0, 2, 0.5)
	eq(rings.size(), 1, "one ring from a cone")
	var a: float = rings[0]["area"]
	near(a, PI * 100.0, 4.0, "its area is a circle's, positive (clockwise on screen)")
	# a hole: a dip inside a plateau
	for j in rows:
		for i in cols:
			var d := Vector2(float(i) - 19.5, float(j) - 19.5).length()
			vals[j * cols + i] = (10.0 if d < 15.0 else -1.0) - (20.0 if d < 4.0 else 0.0)
	var rr := WaterContour.rings(vals, cols, rows, 0.0, 0.0, 1.0, 0.0, 2, 0.5)
	eq(rr.size(), 2, "a plateau with a dip has an outer ring and a hole")
	var pos := 0
	var neg := 0
	for r: Dictionary in rr:
		if float(r["area"]) > 0.0:
			pos += 1
		else:
			neg += 1
	check(pos == 1 and neg == 1, "one outer ring (clockwise) and one hole (anticlockwise)")

# --- the shape of the sea over many seeds ---------------------------------------------------------------------------------------

func _shapes() -> void:
	var q: Dictionary = {}
	var cand := WaterGen.new(SEED)
	q = cand.quality
	var spreads: Array[float] = []
	var fills: Array[float] = []
	var shares: Array[float] = []
	var kinds: Dictionary = {}
	var made := 0
	var islands_seen := 0
	var cliffs := 0.0
	for sd: int in SHAPE_SEEDS:
		var t := Terrain.new(sd)
		var w := WaterGen.new(sd, t)
		if not check(w.ok(), "seed %d: the water builds: %s" % [sd, w.errors]):
			continue
		var r := _sites_dry(w, t, false)
		eq(r["wet"], [] as Array[String], "seed %d: every site of the layout is dry" % sd)
		var st := w.coast_stats()
		var sea: Dictionary = w.diagnostics["sea"]
		var riv: Dictionary = w.diagnostics["river"]
		if bool(riv.get("made", false)):
			made += 1
		kinds[w.archetype] = int(kinds.get(w.archetype, 0)) + 1
		islands_seen += int(st["islands"])
		cliffs += float(st["cliff_share"])
		check(float(st["cliff_share"]) <= 0.4, "seed %d: coastal cliffs are occasional, not the whole coast (%.2f of it)" % [sd, st["cliff_share"]])
		spreads.append(float(st["spread"]))
		fills.append(float(st["fill"]))
		shares.append(float(st["share"]))
		check(float(st["spread"]) >= float(q["min_coast_spread"]), "seed %d (%s): the shore is not one straight line: spread %.2f >= %.2f" % [sd, w.archetype, st["spread"], q["min_coast_spread"]])
		check(float(st["fill"]) <= float(q["max_land_fill"]), "seed %d (%s): the land is not a square block: it fills %.2f of its box <= %.2f" % [sd, w.archetype, st["fill"], q["max_land_fill"]])
		check(float(st["coast_m"]) >= float(q["min_coast_m"]), "seed %d (%s): a real coast: %.0f m >= %.0f" % [sd, w.archetype, st["coast_m"], q["min_coast_m"]])
		print("[water] seed %d: %s %s, sea %.0f%% of the map, coast %.0f m (%.0f%% parallel to an edge, spread %.2f, %.0f%% cliffs), %d islands, land fill %.2f, first try dry %s (%d attempts, accepted %d), river %s" % [
			sd, w.archetype, sea["components"], 100.0 * float(st["share"]), st["coast_m"], 100.0 * float(st["axis_share"]), st["spread"], 100.0 * float(st["cliff_share"]), st["islands"], st["fill"],
			sea["dry_first_try"], (sea["attempts"] as Array).size(), sea["accepted"], riv.get("made", false)])
	var med_spread := _median(spreads)
	var med_fill := _median(fills)
	check(med_spread >= float(q["min_median_coast_spread"]), "the median shore spread over %d seeds is %.2f >= %.2f (a straight coast along an edge scores 0.06 to 0.10)" % [SHAPE_SEEDS.size(), med_spread, q["min_median_coast_spread"]])
	check(med_fill <= float(q["max_median_land_fill"]), "the median land fill is %.2f <= %.2f (a square block scores 0.93 and up)" % [med_fill, q["max_median_land_fill"]])
	check(kinds.size() >= int(q["min_archetypes"]), "the seeds make at least %d different shapes: %s" % [int(q["min_archetypes"]), kinds])
	shares.sort()
	check(shares[shares.size() - 1] - shares[0] >= float(q["min_share_spread"]), "the sea's share differs between seeds: %.2f to %.2f (spread >= %.2f)" % [shares[0], shares[shares.size() - 1], q["min_share_spread"]])
	check(islands_seen >= 2, "some seeds have real islands (%d over the seeds)" % islands_seen)
	check(cliffs > 0.05, "some coasts have a cliff where an upland meets the sea (%.2f of a coast, summed over the seeds)" % cliffs)
	check(made >= SHAPE_SEEDS.size() - 1, "a river on all but at most one of the seeds (%d of %d)" % [made, SHAPE_SEEDS.size()])
	print("[water] %d seeds: median shore spread %.2f, median land fill %.2f, shapes %s, sea share %.2f to %.2f, %d islands, rivers %d" % [
		SHAPE_SEEDS.size(), med_spread, med_fill, kinds, shares[0], shares[shares.size() - 1], islands_seen, made])

static func _median(a: Array[float]) -> float:
	var b := a.duplicate()
	b.sort()
	return b[b.size() / 2]
