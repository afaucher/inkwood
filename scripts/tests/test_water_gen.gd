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
#   THE SEA      the three depth steps exist and start at 0, 6 and 18 m; an upland is never water (a coastal cliff
#                or an islet, never a drowned plateau); the sea's rings are closed, nested by step, outer rings
#                clockwise on screen.
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
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const TerrainDraw = preload("res://scripts/render/terrain_draw.gd")

const SEED := 20261009

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
	_other_seeds()
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

static func _sites_dry(water: WaterGen, terrain: Terrain) -> Dictionary:
	var lay: RefCounted = water.layout()
	var v: Dictionary = lay.village()
	var wet: Array[String] = []
	var n := 0
	var poly: PackedVector2Array = v.polygon
	for p in poly:
		n += 1
		if water.is_wet(p.x, p.y):
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
				if water.is_wet(x, y):
					wet.append("village %s" % Vector2(x, y))
			x += 20.0
		y += 20.0
	var sites: Dictionary = lay.sites()
	var tower: Vector2 = sites.radio_tower
	n += 1
	if water.is_wet(tower.x, tower.y):
		wet.append("tower")
	for b: Vector2 in sites.aa_battery:
		n += 1
		if water.is_wet(b.x, b.y):
			wet.append("battery %s" % b)
		for k in 4:
			var q := b + Vector2.from_angle(float(k) * PI * 0.5) * 25.0
			n += 1
			if water.is_wet(q.x, q.y):
				wet.append("battery ring %s" % q)
	for f: PackedVector2Array in lay.fields():
		for p in f:
			n += 1
			if water.is_wet(p.x, p.y):
				wet.append("field corner %s" % p)
		var c := Vector2.ZERO
		for p in f:
			c += p
		c /= float(f.size())
		n += 1
		if water.is_wet(c.x, c.y):
			wet.append("field centre %s" % c)
	var road: PackedVector2Array = lay.road()
	var map := water.map_rect()
	for p in road:
		if not map.has_point(p):
			continue
		if water.river_crossing.is_finite() and p.distance_to(water.river_crossing) <= 130.0:
			continue
		n += 1
		if water.is_wet(p.x, p.y):
			wet.append("road %s" % p)
	return {"wet": wet, "samples": n}

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
	# an upland is never water, a level-0 point under water is
	var islets := 0
	var wet0 := 0
	var y := 300.0
	while y < 4800.0:
		var x := 3600.0
		while x < 4900.0:
			var s := water.s_at(x, y)
			if s > 0.0:
				var lev := int(terrain.level_at(x, y))
				if lev > 0:
					islets += 1
					check(not water.is_wet(x, y), "an upland in the sea is not water at (%d, %d)" % [x, y])
				else:
					wet0 += 1
					check(water.is_wet(x, y), "level-0 ground under the sea is water at (%d, %d)" % [x, y])
			x += 97.0
		y += 97.0
	check(islets > 0, "the sea has islets and cliffs: uplands that stay land (%d samples)" % islets)
	print("[water] sea samples: %d wet level-0, %d on uplands (islets, cliffs)" % [wet0, islets])

func _rings(water: WaterGen) -> void:
	var shore := Vector2(3930, 2600)
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

# --- other seeds ----------------------------------------------------------------------------------------------------------------------

func _other_seeds() -> void:
	var made := 0
	for sd in [1, 2, 3, 4, 5, 6]:
		var t := Terrain.new(sd)
		var w := WaterGen.new(sd, t)
		if not check(w.ok(), "seed %d: the water builds: %s" % [sd, w.errors]):
			continue
		var r := _sites_dry(w, t)
		eq(r["wet"], [] as Array[String], "seed %d: every site of the layout is dry" % sd)
		var sea: Dictionary = w.diagnostics["sea"]
		var riv: Dictionary = w.diagnostics["river"]
		if bool(riv.get("made", false)):
			made += 1
		print("[water] seed %d: sea edges %s (first try dry %s, %d adapt steps), river %s, %d samples dry" % [sd, sea["edges"], sea["dry_first_try"], sea["adapt_steps"], riv.get("made", false), r["samples"]])
	check(made >= 5, "a river on at least five of six seeds (%d)" % made)
