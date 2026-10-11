extends "res://scripts/test_support/test_case.gd"

# THE BOATS' AND BRIDGES' DATA AND GENERATORS (Track BB, 2026-10-10): data/world/boats.json and bridges.json
# parse; every colour role resolves against the palette with no error and no hex in the files' draw code
# (working rule 6); every look of the two boats and every bridge, whole and destroyed, builds a model that is the
# SAME on a second build (the seed rule) with the parts its design names (an accent zone on every boat, a
# shadow, a deck); the ranges in the data hold; a bridge builds over rivers of 26 to 78 m; and the scale rule
# is computed from the data the game reads (the planes' marker rule: a floor of plane_min_px for the light
# fighter at every zoom). Headless-safe: nothing here draws (the boards, variants/boats and variants/bridge,
# are windowed runs and never tests).

const UiStyle = preload("res://scripts/ui/ui_style.gd")
const InkRoles = preload("res://scripts/render/ink_roles.gd")
const BoatArt = preload("res://scripts/render/boat_art.gd")
const BridgeArt = preload("res://scripts/render/bridge_art.gd")
const BoatScale = preload("res://scripts/render/boat_scale.gd")

const DRAW_FILES := ["res://scripts/render/boat_art.gd", "res://scripts/render/bridge_art.gd", "res://scripts/render/boat_frame.gd",
	"res://scripts/render/bridge_frame.gd", "res://scripts/render/ink_roles.gd", "res://scripts/render/water_placeholder.gd"]

var built := 0

func setup(_main) -> void:
	var st := UiStyle.new()
	if not check(st.ok(), "the style loads: %s" % str(st.errors)):
		finish()
		return
	var boats := BoatArt.data()
	var bridges := BridgeArt.data()
	check(boats.has("patrol") and boats.has("supply") and boats.has("wakes") and boats.has("roles"), "boats.json has patrol, supply, wakes, roles")
	check(bridges.has("arch") and bridges.has("truss") and bridges.has("trestle") and bridges.has("roles"), "bridges.json has the three kinds and roles")
	# every colour is a role that resolves
	for pair: Array in [[boats["roles"], "boats"], [bridges["roles"], "bridges"]]:
		var errs: Array = []
		var resolved := InkRoles.resolve_all(st, pair[0], errs)
		eq(errs, [], "%s.json roles all resolve against the palette" % pair[1])
		check(resolved.size() >= 10, "%s.json has its roles" % pair[1])
		for k: String in resolved:
			var c: Color = resolved[k]
			check(not (c.r == 1.0 and c.g == 0.0 and c.b == 1.0), "%s role %s is not the loud placeholder" % [pair[1], k])
	# the two side accents are the palette's, never a copy
	var rl := InkRoles.resolve_all(st, boats["roles"])
	check((rl["side_a"] as Color).is_equal_approx(st.palette["side_a"]), "side_a is the palette's side_a")
	check((rl["side_b"] as Color).is_equal_approx(st.palette["side_b"]), "side_b is the palette's side_b")
	# no hex in the draw code
	var hex := RegEx.create_from_string("#[0-9A-Fa-f]{6}\\b|Color\\.html|Color\\(\\s*\"|Color8\\(|Color\\(0x")
	for f: String in DRAW_FILES:
		var text := FileAccess.get_file_as_string(f)
		check(text != "", "%s reads" % f)
		check(hex.search(text) == null, "%s has no hex literal or colour constructor from a literal" % f)
	# every boat look, twice
	for kind: String in ["patrol", "supply"]:
		var looks: Array = BoatArt.looks_of(kind)
		eq(looks.size(), 4, "%s has four looks" % kind)
		var d: Dictionary = boats[kind]
		var rng_len: Array = (d["size_m"] as Dictionary)["range"]
		for look: String in looks:
			var a := BoatArt.model(st, kind, look)
			var b := BoatArt.model(st, kind, look)
			eq(a.seed, b.seed, "%s %s: the seed is the same on a second build" % [kind, look])
			eq(str(a.p), str(b.p), "%s %s: the parameters are the same on a second build" % [kind, look])
			check(a.G.hull == b.G.hull, "%s %s: the hull is the same on a second build" % [kind, look])
			var lk: Dictionary = (d["looks"] as Dictionary)[look]
			var len_range: Array = lk["length"]
			check(float(a.p.length) >= float(len_range[0]) - 0.011 and float(a.p.length) <= float(len_range[1]) + 0.011, "%s %s: the length %.2f is inside the look's range" % [kind, look, float(a.p.length)])
			check(float(a.p.length) >= float(rng_len[0]) - 0.011 - 1.0 and float(a.p.length) <= float(rng_len[1]) + 0.011 + 2.0, "%s %s: the length is about the unit's proposed range" % [kind, look])
			check((a.G.hull as PackedVector2Array).size() > 40, "%s %s: the hull has a contour" % [kind, look])
			check((a.G.casts as Array).size() >= 4, "%s %s: the boat casts a shadow in parts" % [kind, look])
			check((a.G.panel as PackedVector2Array).size() >= 3, "%s %s: ONE accent zone exists (a painted panel)" % [kind, look])
			# the hull is a closed simple shape about the length and beam it says
			var xs := 0.0
			var ys := 0.0
			for q in (a.G.hull as PackedVector2Array):
				xs = maxf(xs, absf(q.x))
				ys = maxf(ys, absf(q.y))
			check(ys >= float(a.p.length) / 2.0 - 0.05 and ys <= float(a.p.length) / 2.0 + 2.0, "%s %s: the hull reaches its length (a round stern may overhang by its cap)" % [kind, look])
			near(xs * 2.0, float(a.p.beam), 0.2, "%s %s: the hull's extent along x is its beam" % [kind, look])
			if kind == "patrol":
				var mounts: Array = a.G.mounts
				check(mounts.size() == 2, "patrol %s: two gun mounts (fore and aft)" % look)
			else:
				check(a.p.hatches.size() > 0 or str(a.p.cargo) != "none", "supply %s: a hold or a deck load" % look)
			built += 1
	# the shapes differ between looks (a board of four identical boats would pass everything above)
	check(BoatArt.model(st, "patrol", "p1").G.hull != BoatArt.model(st, "patrol", "p2").G.hull, "p1 and p2 are different hulls")
	check(BoatArt.model(st, "supply", "s1").G.hull != BoatArt.model(st, "supply", "s2").G.hull, "s1 and s2 are different hulls")
	# the wakes named in the data are the ones the art draws
	for w: String in ["ink_v", "foam", "wash"]:
		check((boats["wakes"] as Dictionary).has(w), "wakes.%s exists" % w)
	# bridges: whole and destroyed, over a range of rivers
	for kind: String in BridgeArt.kinds():
		for ruin: bool in [false, true]:
			for rw: float in [-1.0, 26.0, 42.0, 78.0]:
				var a := BridgeArt.model(st, kind, ruin, rw)
				var b := BridgeArt.model(st, kind, ruin, rw)
				eq(str(a.p), str(b.p), "%s ruin=%s w=%s: same parameters on a second build" % [kind, str(ruin), str(rw)])
				check(a.G.deck == b.G.deck, "%s ruin=%s w=%s: same deck on a second build" % [kind, str(ruin), str(rw)])
				if rw > 0.0:
					near(float(a.p.river_w), rw, 0.001, "%s: the river's width is the one asked for" % kind)
				check((a.G.deck as Array).size() == (2 if ruin else 1), "%s ruin=%s: the deck is %d piece(s)" % [kind, str(ruin), 2 if ruin else 1])
				check((a.G.casts as Array).size() >= 3, "%s: the bridge casts a shadow in parts" % kind)
				check(((a.G.rubble as Array).size() > 0) == ruin, "%s ruin=%s: rubble exactly when destroyed" % [kind, str(ruin)])
				check(float(a.p.deck_w) > 0.0, "%s: the deck has a width (the road's)" % kind)
				built += 1
	# the arch takes one to four arches by the river's width
	eq(BridgeArt.model(st, "arch", false, 26.0).p.arches, 1, "one arch over a 26 m river")
	eq(BridgeArt.model(st, "arch", false, 78.0).p.arches, 4, "four arches over a 78 m river")
	# the scale rule is computed from the data the game reads: the light fighter never draws under plane_min_px
	var v := BoatScale.values()
	for zoom: float in [0.25, 0.35, 1.0, 2.0]:
		var fighter_px := BoatScale.plane_ppm(zoom) * float(v["fighter_m"])
		check(fighter_px >= float(v["plane_min_px"]) - 0.001, "zoom %s: the light fighter is at least plane_min_px on screen" % str(zoom))
		check(fighter_px >= float(v["plane_px"]) * zoom - 0.001, "zoom %s: and at least plane_px x zoom" % str(zoom))
		near(BoatScale.plane_ppm(zoom) / BoatScale.map_ppm(zoom), BoatScale.marker_k(zoom), 1e-9, "zoom %s: the plane rule is the map's scale x marker.true_scale" % str(zoom))
	# the sentinel: a dependency that did not compile would have stopped this test above, silently
	eq(built, 8 + 3 * 2 * 4, "every look and every bridge was built")
	finish()
