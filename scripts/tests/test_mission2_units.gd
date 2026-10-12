extends "res://scripts/test_support/test_case.gd"

# MISSION 2'S TWO NEW UNITS (Track M2U, 2026-10-11): the MOBILE ANTI-AIRCRAFT GUN and the MILITARY COMPLEX, data and art.
# Alex's second mission profile (decision suppress-mission): "Clear mobile Aa units and their escorts to enable a bombing run of a
# military complex." Every number is PROPOSED; what is held here is the shape of the design, not the figures:
#
#   1. both unit files load and validate; the gun is a mobile ground unit that drives (a road speed of 8 to 10 m/s, the tank's
#      movement system) with ONE weapon, a short all-around cone aimed up; the complex is a static ground unit, no weapons, no bombs,
#      more health than the radio tower, a footprint of about 80 m
#   2. THE GUN IS A MACHINE GUN (decision weapon-kinds, Alex 2026-10-11: 'machine guns are around and less up'; the band is PROPOSED):
#      weapon quad_mg, a cone from the horizon to a moderate elevation, so a plane STRAIGHT OVER it (low or medium) is out of the cone,
#      a blind disc under the plane, and a low plane 150 to 300 m out is in; the medium band is reached only in a ring
#      THE GUN'S REACH: its cone covers a plane in the LOW band round it and never the HIGH band, from straight below or from any
#      distance (the brief said the medium band too was out of reach; Track M2L widened the reach to contest a medium approach, so the
#      figure is theirs and the ORDER is held: low at least as dangerous as medium, high out of reach); it cannot hurt a unit on the
#      ground; played through the World, a plane flying over it at the low band loses pips, a high one none, and the gun rolls only at
#      the low and medium planes
#   3. THE COMPLEX IS DESTROYED BY BOMBS: enough bombs on its centre take its pips (fate "destroyed", by the bomber, in World.units
#      still), one bomb fewer leaves it standing, it never fires and never moves, and no plan is taken from it
#   4. THE ART: three looks of each, built twice with the same seed and the same parameters; ONE accent zone on every look; the
#      complex's parts inside its footprint; every sub-draw RUNS TO ITS END (a trace of each sub-draw's last statement: a runtime error
#      inside one would otherwise only reach the error log), onto a canvas that records its ops (nothing is rendered: the boards,
#      variants/mobile-aa and variants/military-complex, are windowed runs and never tests); the destroyed complex draws; the shadow of
#      the standing one is cast by part height (the chimney's by its 26 m); and no hex or colour literal in the draw code
#   6. THE DESTROYED COMPLEX is the effects layer's: fx ruin / add_ruin take the kind military_complex (the feed passes the unit's
#      silhouette), size its flash and smoke by the effects share of its 80 m, keep the unit's own size, and the layer draws the ruin
#      art and its shadow; and A SURFACE UNIT'S SHADOW is lifted by its height x the sun's length (ui.json marker.cast_shadow_on,
#      marker.cast_height_m): the tank and the gun, not the planes, the tower or the battery; off, the layer is as it was
#   5. THE WIRING: unit_marker_art.gd names both silhouettes in its one dispatch line each; both units have a marker in the marker layer;
#      the player's gun is in the roster and the enemy's complex and gun are in sight only when a player unit's sight reaches them
#
# A sentinel counts what ran: a dependency that does not compile, or a runtime error, stops a test coroutine in silence.

const World = preload("res://scripts/sim/world.gd")
const Unit = preload("res://scripts/sim/unit.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")
const SimRules = preload("res://scripts/sim/sim_rules.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const CombatWeapon = preload("res://scripts/sim/combat_weapon.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UnitMarkerArt = preload("res://scripts/ui/unit_marker_art.gd")
const MobileAA = preload("res://scripts/ui/unit_marker_art_mobile_aa.gd")
const StaticArt = preload("res://scripts/ui/unit_marker_art_static.gd")
const InkCanvas = preload("res://scripts/render/ink_canvas.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxField = preload("res://scripts/fx/fx_field.gd")
const UnitMarkerLayer = preload("res://scripts/ui/unit_marker_layer.gd")

const DRAW_FILES := ["res://scripts/ui/unit_marker_art_mobile_aa.gd", "res://scripts/ui/unit_marker_art_static.gd", "res://scripts/ui/boards/m2_frame.gd"]

var ran := 0

func setup(_main) -> void:
	timeout_seconds = 120.0
	_data()
	_reach()
	_pass_through_the_world()
	_complex_bombed()
	_art()
	_wiring()
	_ruin_and_shadow()
	eq(ran, 7, "every section ran to its end (a dependency that did not compile stops a test in silence)")
	finish()

# --- 1. The data ------------------------------------------------------------------------------------------------------------

func _data() -> void:
	var w := World.new()
	if not check(w.ok(), "the world's data loads: %s" % str(w.errors)):
		return
	var rules := SimRules.new()
	var aa := UnitDef.new(UnitDef.path_for("mobile_aa"), rules.band_ids)
	var mc := UnitDef.new(UnitDef.path_for("military_complex"), rules.band_ids)
	check(aa.ok(), "mobile_aa.json validates: %s" % "; ".join(aa.errors))
	check(mc.ok(), "military_complex.json validates: %s" % "; ".join(mc.errors))
	if not (aa.ok() and mc.ok()):
		return
	eq(aa.id, "mobile_aa", "the gun's id is what the mission names it by")
	eq(mc.id, "military_complex", "the complex's id is what the mission names it by")
	eq(aa.domain, "ground", "the gun is a ground unit")
	eq(aa.mobility, "mobile", "which drives")
	check(not aa.is_static() and aa.envelope.speed_max >= 8.0 and aa.envelope.speed_max <= 10.0, "at 8 to 10 m/s on a road (%s)" % str(aa.envelope.speed_max))
	check(aa.envelope.speed_min < 0.0 and aa.envelope.reverse_from_stop and aa.envelope.bands == (["surface"] as Array[String]), "reverses once stopped, rides the surface")
	check(aa.envelope.turn_rate(0.0) > 0.0 and aa.envelope.turn_rate(aa.envelope.speed_max) == aa.envelope.turn_rate(0.0), "and pivots like a tracked vehicle: the same turn rate at any speed")
	eq(aa.draught_m, 0.0, "it does not float")
	check(not aa.carries_bombs() and aa.specials.is_empty(), "no bombs, no specials")
	eq(aa.weapons.size(), 1, "one weapon")
	eq(aa.silhouette, "mobile_aa", "drawn as the mobile_aa silhouette")
	var tank := w.unit_def("tank")
	if tank != null:
		check(aa.health < tank.health and aa.health >= 3, "thin-skinned: under the tank's %d pips, over a light fighter's 3 (%d)" % [tank.health, aa.health])
	eq(mc.domain, "ground", "the complex is a ground unit")
	check(mc.is_static() and mc.envelope.speed_max == 0.0 and mc.envelope.bands == (["surface"] as Array[String]), "static: never moves, on the surface")
	eq(mc.weapons.size(), 0, "it has no weapons")
	check(not mc.carries_bombs() and mc.specials.is_empty(), "no bombs, no specials")
	check(mc.health > w.unit_def("radio_tower").health, "more health than the radio tower (%d against %d)" % [mc.health, w.unit_def("radio_tower").health])
	check(mc.health >= 10 and mc.health <= 16, "about 12 pips (%d)" % mc.health)
	check(mc.size_m >= 60.0 and mc.size_m <= 100.0, "a footprint of about 80 m (%s)" % str(mc.size_m))
	eq(mc.silhouette, "military_complex", "drawn as the military_complex silhouette")
	check(mc.draught_m == 0.0 and mc.actions_per_turn == 1, "one step a turn that stands still, no draught")
	ran += 1

# --- 2. The gun's reach -----------------------------------------------------------------------------------------------------

func _reach() -> void:
	var w := World.new()
	var aa: UnitDef = w.unit_def("mobile_aa")
	var gun: CombatWeapon = aa.weapons[0]
	# DECISION weapon-kinds (Alex, 2026-10-11): the quad mount is a MACHINE GUN ("machine guns are around and less up"; flak "has better
	# coverage in the area directly above"). Its band is PROPOSED: from the horizon to a moderate elevation, so a plane straight over it is
	# out of the cone and a plane some way out is in it
	eq(gun.id, "quad_mg", "the weapon is the quad machine guns")
	eq(gun.kind, "flexible", "mounted like a flexible gun")
	eq(gun.half_across_deg, 180.0, "all around")
	var lo_deg: float = gun.elevation_deg - gun.half_height_deg
	var hi_deg: float = gun.elevation_deg + gun.half_height_deg
	check(lo_deg >= 0.0 and hi_deg > 20.0 and hi_deg < 80.0, "aimed from the horizon to a moderate elevation, not straight overhead (%s to %s deg)" % [lo_deg, hi_deg])
	var muzzle: float = gun.hardpoints[0].z
	var reach := gun.max_range_m(w.combat.range_overshoot)
	var low := w.band_height("low")
	var med := w.band_height("medium")
	check(low - muzzle < gun.effective_range_m, "the low band is inside its effective range (%.0f m < %s m)" % [low - muzzle, gun.effective_range_m])
	# THE REACH IS THE DESIGN'S DIAL (the brief said low and not medium; Track M2L widened it to contest a medium approach, 2026-10-11): what
	# is held is the ORDER, not the figure: the low band is inside the guns' effective range, the HIGH band is out of their reach from
	# anywhere, and the medium band, wherever it is in reach, is no easier to hit than the low one
	check(reach < w.band_height("high") - muzzle, "the high band is out of its reach even from straight below it (reach %.0f m < %.0f m)" % [reach, w.band_height("high") - muzzle])
	var factors: Array = w.combat.odds_factors
	var params := w.combat.factor_params()
	var shoot := func(tx: float, ty: float, theight: float) -> Dictionary:
		return Combat.evaluate({"x": 0.0, "y": 0.0, "heading": 0.0, "height_m": 0.0}, gun, 0, {"x": tx, "y": ty, "height_m": theight}, factors, params)
	# THE MACHINE GUN'S BLIND DISC: a plane straight over the mount is above the cone, low or medium; a low plane 300 m out is in it
	var over_low: Dictionary = shoot.call(0.0, 1.0, low)
	check(not over_low["in_cone"] and float(over_low["odds"]) == 0.0, "a low plane right over the guns is NOT in the cone (it is above %s deg)" % str(hi_deg))
	var over_med: Dictionary = shoot.call(0.0, 1.0, med)
	check(not over_med["in_cone"] and float(over_med["odds"]) == 0.0, "nor is a medium plane right over them")
	var blind_low := (low - muzzle) / tan(deg_to_rad(hi_deg))
	check(not (shoot.call(blind_low * 0.9, 0.0, low) as Dictionary)["in_cone"] and (shoot.call(blind_low * 1.1, 0.0, low) as Dictionary)["in_cone"], "the blind disc under a low plane is %.0f m wide on the ground (inside it out, just outside it in)" % (2.0 * blind_low))
	var low_best := 0.0
	for off: float in [150.0, 250.0, 300.0]:
		var e: Dictionary = shoot.call(off, 0.0, low)
		check(e["in_cone"] and float(e["odds"]) > 0.0, "a low plane %.0f m off is in the cone and has odds (%.4f)" % [off, float(e["odds"])])
		low_best = maxf(low_best, float(e["odds"]))
	var low_ground := sqrt(maxf(reach * reach - (low - muzzle) * (low - muzzle), 0.0))
	check(not (shoot.call(low_ground + 60.0, 0.0, low) as Dictionary)["in_cone"], "a low plane beyond its reach (%.0f m off) is out: the guns are short" % (low_ground + 60.0))
	var med_ground := sqrt(maxf(reach * reach - (med - muzzle) * (med - muzzle), 0.0)) if reach > med - muzzle else -1.0
	var worst := 0.0
	for off: float in [0.0, 1.0, 50.0, 100.0, 200.0, 300.0, 400.0, 600.0, 1000.0]:
		for k in 8:
			var az := TAU * float(k) / 8.0
			var m: Dictionary = shoot.call(off * cos(az), off * sin(az), med)
			worst = maxf(worst, float(m["odds"]))
			if off > med_ground + 1.0 and (m["in_cone"] or float(m["odds"]) != 0.0):
				fail("a medium plane %.0f m off at azimuth %d is beyond the reach (%.0f m on the ground) and in it (odds %.4f)" % [off, roundi(rad_to_deg(az)), med_ground, float(m["odds"])])
	check(worst <= low_best + 1e-12, "no medium plane has better odds than a low one in the cone (%.4f against %.4f)" % [worst, low_best])
	# the medium band is reached only in a RING (the machine guns do not point up that far): 400 m out it is in the cone, 200 m out it is not
	var ring_inner := (med - muzzle) / tan(deg_to_rad(hi_deg))
	var ring_in := (shoot.call(ring_inner * 1.1, 0.0, med) as Dictionary)
	check(ring_in["in_cone"] and float(ring_in["odds"]) > 0.0, "a medium plane just outside the ring's inner edge (%.0f m out, %.0f m on the ground) is in the cone" % [ring_inner * 1.1, ring_inner])
	check(not (shoot.call(ring_inner * 0.9, 0.0, med) as Dictionary)["in_cone"], "and one just inside it is not: too steep for the machine guns")
	var hi_worst := 0.0
	for off: float in [0.0, 200.0, 600.0]:
		hi_worst = maxf(hi_worst, float((shoot.call(off, 0.0, w.band_height("high")) as Dictionary)["odds"]))
	eq(hi_worst, 0.0, "no high plane has odds")
	check(not (shoot.call(300.0, 0.0, 0.0) as Dictionary)["in_cone"], "a unit on the ground is never in the cone: it cannot hurt a tank")
	ran += 1

# Every participant readies up, the turn resolves, the next one begins.
func _turn(w: World) -> Dictionary:
	for p: String in w.participants():
		w.commit(p)
	var res := w.resolve()
	w.begin_turn()
	return res

# A plane flying straight over ONE standing gun at cruise (999 pips so it stays up): the gun's rolls' expected pips.
func _pass(band: String, offset_m: float) -> Dictionary:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	var speed: float = w.unit_def("bomber").envelope.speed_cruise
	w.add_unit({"id": "p", "type": "bomber", "side": "allies", "controller": "player", "x": 700.0, "y": 2500.0 + offset_m, "heading": 0.0, "altitude_band": band, "speed": speed})
	w.add_unit({"id": "aa", "type": "mobile_aa", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w.units["p"].health = 999
	var expected := 0.0
	var rolls := 0
	for _t in int(ceil(3600.0 / speed / 5.0)) + 1:
		var res := _turn(w)
		for ev: Dictionary in res.get("events", []):
			if ev["type"] == "fire" and ev["unit"] == "aa":
				expected += float(ev["odds"])
				rolls += 1
	return {"expected": expected, "rolls": rolls, "moved": Vector2(float(w.units["aa"].x), float(w.units["aa"].y)).distance_to(Vector2(2500.0, 2500.0))}

func _pass_through_the_world() -> void:
	var low := _pass("low", 0.0)
	var low_aside := _pass("low", 150.0)
	var med := _pass("medium", 0.0)
	var med_aside := _pass("medium", 150.0)
	var high := _pass("high", 0.0)
	print("  mobile gun, a bomber flying straight over it, expected pips: low %.2f (150 m aside %.2f), medium %.2f (%.2f), high %.2f" % [low["expected"], low_aside["expected"], med["expected"], med_aside["expected"], high["expected"]])
	check(float(low["expected"]) >= 0.4, "a bomber flying over it at the low band loses pips (%.2f of 8)" % float(low["expected"]))
	check(float(low_aside["expected"]) >= 0.4, "and passing 150 m to one side (%.2f)" % float(low_aside["expected"]))
	check(int(low["rolls"]) > 0, "the gun rolls at the low plane (%d rolls)" % int(low["rolls"]))
	check(float(med["expected"]) <= float(low["expected"]) + 1e-9, "a medium plane is no worse off than a low one: the low band is still the most dangerous (%.2f against %.2f)" % [float(med["expected"]), float(low["expected"])])
	eq(high["rolls"], 0, "the gun never rolls at a high plane")
	check(float(low["expected"]) < 4.76, "weaker than the whole battery's flak straight over it at low (4.76 of 8)")
	check(float(low["moved"]) < 1e-6, "a gun standing still is where it was after the pass (%.3f m)" % float(low["moved"]))
	# the dice: a one-pip light fighter over it at low goes down sometimes; at medium never
	var downs := {"low": 0, "medium": 0}
	var rolls_at := {"low": 0, "medium": 0}
	for band: String in downs:
		for s in 40:
			var w := World.new()
			w.quiet = true
			w.rng_seed = s + 1
			w.add_player("local")
			w.add_unit({"id": "p", "type": "light_fighter", "side": "allies", "controller": "player", "x": 700.0, "y": 2500.0, "heading": 0.0, "altitude_band": band, "speed": 100.0})
			w.add_unit({"id": "aa", "type": "mobile_aa", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
			w.units["p"].health = 1
			var went_down := false
			for _t in 8:
				var res := _turn(w)
				for ev: Dictionary in res.get("events", []):
					if ev["type"] == "fire" and ev["unit"] == "aa":
						rolls_at[band] += 1
						check(ev["weapon"] == "quad_mg" and ev["target"] == "p" and float(ev["r"]) <= 1.0, "a gun roll names the gun's weapon and the plane, inside the cone")
					elif ev["type"] == "hit":
						check(ev["by"] == "aa" and ev["weapon"] == "quad_mg" and ev["damage"] == 1, "a hit takes one pip")
					elif ev["type"] == "down":
						went_down = true
						check(ev["by"] == "aa" and (ev["fate"] == Unit.FATE_EXPLODED or ev["fate"] == Unit.FATE_OUT_OF_CONTROL), "shot down by the gun: it explodes or falls")
				if went_down:
					break
			if went_down:
				downs[band] += 1
	print("  mobile gun dice, a one-pip light fighter flying over it, 40 seeds: down low %d, medium %d (rolls %d and %d)" % [downs["low"], downs["medium"], rolls_at["low"], rolls_at["medium"]])
	check(downs["low"] >= 8, "a low plane is often brought down (%d of 40)" % downs["low"])
	check(downs["medium"] <= downs["low"], "and a medium one no more often (%d against %d)" % [downs["medium"], downs["low"]])
	ran += 1

# --- 3. The complex bombed ----------------------------------------------------------------------------------------------------

func _complex_bombed() -> void:
	var centre := BombWorlds.TOWER + Vector2(900.0, 0.0)
	var make := func(seed_value: int) -> World:
		var w := BombWorlds.world(seed_value, "medium")
		w.add_unit({"id": "complex", "type": "military_complex", "side": "axis", "controller": "ai", "x": centre.x, "y": centre.y, "heading": 0.3})
		return w
	var w: World = make.call(1)
	var health: int = w.units["complex"].health
	var direct := w.bombs.blast_damage(0.0)
	var n := int(ceil(float(health) / float(direct)))
	var recs: Array = []
	for i in n + 2:
		recs.append(BombWorlds.record(w, centre.x, centre.y, 1.0 + 0.5 * float(i), i))
	BombWorlds.drop_bombs(w, recs)
	var res := BombWorlds.turn(w)
	var c: Unit = w.units["complex"]
	check(c.down and c.health == 0, "the complex is down after %d direct hits of %d pips (%d pips of health)" % [n, direct, health])
	eq(c.fate, Unit.FATE_DESTROYED, "its fate is 'destroyed'")
	check(w.units.has("complex"), "it stays in World.units")
	var downs := BombWorlds.events_of(res, "down", "complex")
	eq(downs.size(), 1, "one down event")
	if downs.size() == 1:
		eq(downs[0]["fate"], "destroyed", "with the fate")
		eq(downs[0]["by"], "bomber", "by the bomber")
		check(float(downs[0]["x"]) == centre.x and float(downs[0]["y"]) == centre.y and float(downs[0]["height_m"]) == 0.0, "where it stands, on the ground")
	check(BombWorlds.events_of(res, "hit", "tower").is_empty(), "the tower 900 m away was not touched")
	# one bomb fewer leaves it standing, hurt
	var w2: World = make.call(1)
	var recs2: Array = []
	for i in n - 1:
		recs2.append(BombWorlds.record(w2, centre.x, centre.y, 1.0 + 0.5 * float(i), i))
	BombWorlds.drop_bombs(w2, recs2)
	BombWorlds.turn(w2)
	check(not w2.units["complex"].down and w2.units["complex"].health == health - (n - 1) * direct, "one bomb fewer and it stands, hurt (%d of %d pips)" % [w2.units["complex"].health, health])
	# a bomber's stick on a perfect line destroys it in a few passes from the low band (the tuning table, mission2_unit_tuning.gd, says how many)
	var w3: World = make.call(2)
	check(w3.units["complex"].health > w3.units["tower"].health, "it takes more bombs than the tower")
	# it never fires, never moves, takes no plan
	var w4: World = make.call(3)
	var x0: float = w4.units["complex"].x
	w4.last_error = ""
	eq(w4.plan_step("complex", 0, {"turn": 0.0, "speed": 0.0}), {}, "a plan is refused")
	check(w4.last_error.contains("static"), "and says why: %s" % w4.last_error)
	for _k in 3:
		var r := BombWorlds.turn(w4)
		eq(BombWorlds.events_of(r, "fire", "complex").size(), 0, "it never fires")
	check(float(w4.units["complex"].x) == x0 and not w4.units["complex"].down, "it is where it was and untouched after three turns")
	eq(w4.participants(), ["local"] as Array[String], "and the AI does not wait for it")
	ran += 1

# --- 4. The art -----------------------------------------------------------------------------------------------------------------

func _art() -> void:
	var st := UiStyle.new()
	if not check(st.ok(), "the style loads: %s" % str(st.errors)):
		return
	var ink := UnitMarkerArt.ink_consts(st)
	var accent: Color = st.side_color("axis")
	# no hex in the draw code (working rule 6)
	var hex := RegEx.create_from_string("#[0-9A-Fa-f]{6}\\b|Color\\.html|Color\\(\\s*\"|Color8\\(|Color\\(0x")
	for f: String in DRAW_FILES:
		var text := FileAccess.get_file_as_string(f)
		check(text != "", "%s reads" % f)
		check(hex.search(text) == null, "%s has no hex literal or colour constructor from a literal" % f)
	# the data: roles resolve, the defaults name a look that exists
	var roles := MobileAA.roles(st)
	check(roles.size() >= 10 and not roles.has(""), "the data's colour roles resolve (%d)" % roles.size())
	var mc_roles := StaticArt.mc_roles(st)
	for k: String in mc_roles:
		var c: Color = mc_roles[k]
		check(not (c.r == 1.0 and c.g == 0.0 and c.b == 1.0), "role %s is not the loud placeholder" % k)
	check(MobileAA.default_look() >= 0 and MobileAA.default_look() < MobileAA.looks().size(), "the gun's default look exists")
	check(int(StaticArt.mc_val(StaticArt.mc_data()["default_look"])) < StaticArt.mc_looks().size(), "the complex's default look exists")
	eq(MobileAA.looks().size(), 3, "three looks of the gun")
	eq(StaticArt.mc_looks().size(), 3, "three looks of the complex")
	var built := 0
	# --- the mobile gun: every look, twice, drawn
	var kinds: Array[String] = []
	for look in 3:
		var a := MobileAA.model_for(st, look)
		var b := MobileAA.gen(look, Mulberry32.new(a.seed))
		eq(str(a.p), str(b), "gun look %d: the same seed makes the same parameters" % look)
		eq(a.seed, UnitMarkerArt.unit_seed(st.scene_seed, 7, look), "gun look %d: the seed is the sheet's rule with index 7" % look)
		kinds.append(str(a.p.kind))
		check((a.G.panel as PackedVector2Array).size() >= 4, "gun look %d: ONE accent zone exists (a painted panel)" % look)
		check((a.G.barrels as Array).size() == int(a.p.guns) and int(a.p.guns) >= 2, "gun look %d: a barrel for each gun (%d)" % [look, int(a.p.guns)])
		var ext := UnitMarkerArt.extent_box(a)
		check(ext.size.y >= 5.4 and ext.size.y <= 7.6 and ext.size.x >= 2.0 and ext.size.x <= 3.6, "gun look %d: a vehicle's size, %.1f x %.1f m" % [look, ext.size.y, ext.size.x])
		var length: float = a.p.length
		check(length >= 5.6 and length <= 7.0, "gun look %d: about the unit's 6.5 m (%.2f)" % [look, length])
		var canvas := InkCanvas.new(Vector2i(220, 220))
		canvas.line_cap = "round"
		var v := UnitMarkerArt.View.new(110.0 - (ext.position.x + ext.size.x / 2.0) * 8.0, 110.0 - (ext.position.y + ext.size.y / 2.0) * 8.0, 8.0, 0.0)
		MobileAA.trace.clear()
		MobileAA.tracing = true
		MobileAA.draw(canvas, a, v, ink, accent, roles)
		MobileAA.tracing = false
		var tr := MobileAA.trace.duplicate()
		var want: Array = ["tracks", "barrels", str(a.p.kind)]
		if str(a.p.kind) != "turret":
			want.append("mount")
		for t: String in want:
			check(tr.has(t), "gun look %d: the sub-draw '%s' ran to its end (%s)" % [look, t, str(tr)])
		check(canvas.op_count() > 30, "gun look %d: the draw recorded %d ops" % [look, canvas.op_count()])
		canvas.discard()
		built += 1
	eq(kinds, ["halftrack", "turret", "carrier"] as Array[String], "the three looks are the three plans")
	check(str(MobileAA.model_for(st, 0).G.hull) != str(MobileAA.model_for(st, 1).G.hull) and str(MobileAA.model_for(st, 1).G.hull) != str(MobileAA.model_for(st, 2).G.hull), "and their hulls differ")
	# --- the military complex: every look, whole and destroyed
	var seen_main: Array[String] = []
	for look in 3:
		var a := StaticArt.mc_model(st, look)
		var b := StaticArt.gen_complex(look, Mulberry32.new(a.seed))
		eq(str(a.p), str(b), "complex look %d: the same seed makes the same parameters" % look)
		eq(a.seed, UnitMarkerArt.unit_seed(st.scene_seed, 8, look), "complex look %d: the seed is the sheet's rule with index 8" % look)
		var G := a.G
		var parts: Array = G.parts
		var main_kind := ""
		var counts := {}
		for pt: Dictionary in parts:
			counts[pt["kind"]] = int(counts.get(pt["kind"], 0)) + 1
			if str(pt["name"]) == "main":
				main_kind = str(pt["kind"])
			for q: Vector2 in pt["poly"]:
				check(absf(q.x) <= 40.0 and absf(q.y) <= 30.0, "complex look %d: every part is inside the 80 x 60 m footprint (%s at %.1f, %.1f)" % [look, str(pt["name"]), q.x, q.y])
		seen_main.append(main_kind)
		check(main_kind != "", "complex look %d: a main building" % look)
		eq((G.panels as Array).size(), 2, "complex look %d: ONE accent zone, placed on either roof half (two places, one is drawn)" % look)
		for pn: PackedVector2Array in G.panels:
			check(pn.size() == 4, "complex look %d: a painted panel" % look)
		check((G.yard as PackedVector2Array).size() == 4 and (G.ring as PackedVector2Array).size() >= 5, "complex look %d: a yard and a fence with a gate" % look)
		check(counts.get("truck", 0) >= 1 and counts.get("tower", 0) + counts.get("crates", 0) >= 1, "complex look %d: vehicles and a watch tower or crates" % look)
		var gs := 8.0
		var rl := StaticArt.mc_roles(st)
		# whole
		var canvas := InkCanvas.new(Vector2i(900, 700))
		canvas.line_cap = "round"
		var cvv := UnitMarkerArt.View.new(450.0, 350.0, gs, 0.0)
		StaticArt.mc_trace.clear()
		StaticArt.mc_tracing = true
		StaticArt.draw_complex(canvas, a, cvv, ink, accent, rl)
		StaticArt.mc_tracing = false
		var tr := StaticArt.mc_trace.duplicate()
		var n_roofs: int = int(counts.get("barrel", 0)) + int(counts.get("gable", 0))
		eq(tr.count("roof"), n_roofs, "complex look %d: every roof ran to its end" % look)
		eq(tr.count("saw"), int(counts.get("saw", 0)), "complex look %d: and every saw-tooth roof" % look)
		eq(tr.count("tank"), int(counts.get("tank", 0)), "complex look %d: and every fuel tank" % look)
		eq(tr.count("stack"), int(counts.get("stack", 0)), "complex look %d: and the chimney" % look)
		eq(tr.count("tower"), int(counts.get("tower", 0)), "complex look %d: and every watch tower" % look)
		eq(tr.count("truck"), int(counts.get("truck", 0)), "complex look %d: and every truck" % look)
		eq(tr.count("crates"), int(counts.get("crates", 0)), "complex look %d: and every crate stack" % look)
		eq(tr.count("heap"), (G.heaps as Array).size(), "complex look %d: and the heaps" % look)
		eq(tr.count("routes"), 1, "complex look %d: and the tyre tracks" % look)
		eq(tr.count("fence"), 1, "complex look %d: and the fence" % look)
		eq(tr.count("complex"), 1, "complex look %d: and the whole picture, accent panel last" % look)
		check(canvas.op_count() > 100, "complex look %d: the draw recorded %d ops" % [look, canvas.op_count()])
		canvas.discard()
		# destroyed
		var rcanvas := InkCanvas.new(Vector2i(900, 700))
		rcanvas.line_cap = "round"
		var pieces: Array = []
		StaticArt.mc_trace.clear()
		StaticArt.mc_tracing = true
		StaticArt.draw_complex_ruin(rcanvas, a, cvv, ink, rl, pieces)
		StaticArt.mc_tracing = false
		var rt := StaticArt.mc_trace.duplicate()
		eq(rt.count("ruin"), 1, "complex look %d: the destroyed picture ran to its end" % look)
		eq(rt.count("crater"), int(StaticArt.mc_val((StaticArt.mc_data()["ruin"] as Dictionary)["craters"])), "complex look %d: with its craters" % look)
		check(rt.count("rubble") >= 3 and pieces.size() >= 10, "complex look %d: and heaps of rubble (%d heaps, %d pieces)" % [look, rt.count("rubble"), pieces.size()])
		check(rcanvas.op_count() > 100, "complex look %d: the destroyed draw recorded %d ops" % [look, rcanvas.op_count()])
		rcanvas.discard()
		# the cast shadow, by part height
		var band: Dictionary = StaticArt._wall_band(cvv, ink, G, (a.seed % 99991) + 31) if str(a.p.fence) == "wall" else {}
		var prims := StaticArt.complex_shadow_prims(a, cvv, ink, st, band)
		check(prims.size() >= parts.size(), "complex look %d: every part casts (%d shadows for %d parts)" % [look, prims.size(), parts.size()])
		var reach := 0.0
		for pr: Dictionary in prims:
			for q: Vector2 in pr["pts"]:
				check(is_finite(q.x) and is_finite(q.y), "complex look %d: a finite shadow point" % look)
				reach = maxf(reach, q.dot(ink.sd))
		if str(a.p.kind) == "works":
			for pt: Dictionary in parts:
				if str(pt["kind"]) == "stack":
					var base_d: float = (cvv.tp(pt["c"]) as Vector2).dot(ink.sd)
					var cast := reach - base_d
					var want_len: float = float(pt["h"]) * st.sun_len() * gs
					check(cast >= want_len - 2.0, "the chimney's shadow is its height x the sun's length: %.1f px for %.1f (%.0f m)" % [cast, want_len, float(pt["h"])])
		var ruin_prims := StaticArt.complex_ruin_prims(a, cvv, ink, st, pieces)
		check(ruin_prims.size() == pieces.size(), "complex look %d: the pieces lying in the ruin cast low shadows" % look)
		built += 1
	check(seen_main.has("barrel") and seen_main.has("saw") and seen_main.has("gable"), "the three looks have three kinds of main building (%s)" % str(seen_main))
	eq(built, 6, "every look of both units was built and drawn")
	# the baked art is the renderer's: headless it is null, never an error, and the cache stays empty
	if not UnitMarkerArt.can_bake():
		var before := UnitMarkerArt.cache_size()
		check(UnitMarkerArt.art_for(st, "mobile_aa", accent, 4.0) == null and UnitMarkerArt.art_for(st, "military_complex", accent, 4.0, 0.0) == null, "headless, both silhouettes bake nothing (and say nothing)")
		eq(UnitMarkerArt.cache_size(), before, "and the art cache is untouched")
	ran += 1

# --- 5. The wiring --------------------------------------------------------------------------------------------------------------

func _wiring() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/ui/unit_marker_art.gd")
	check(src.contains('silhouette == "mobile_aa"') and src.contains("unit_marker_art_mobile_aa.gd"), "unit_marker_art.gd has the gun's dispatch line")
	check(src.contains('silhouette == "military_complex"') and src.contains("complex_art("), "and the complex's")
	var st := UiStyle.new()
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "mine", "type": "mobile_aa", "side": "allies", "controller": "player", "x": 1480.0, "y": 2450.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "theirs", "type": "mobile_aa", "side": "axis", "controller": "ai", "x": 1700.0, "y": 2400.0, "heading": 2.0, "speed": 0.0})
	w.add_unit({"id": "target", "type": "military_complex", "side": "axis", "controller": "ai", "x": 1750.0, "y": 2600.0, "heading": 0.3})
	w.add_unit({"id": "far_target", "type": "military_complex", "side": "axis", "controller": "ai", "x": 4200.0, "y": 4200.0, "heading": 0.0})
	var origin := Vector2(1400.0, 2300.0)
	var xf := Transform2D(0.0, Vector2(3.8, 3.8), 0.0, -origin * 3.8)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")
	var rows: Array[Dictionary] = ui.roster.rows()
	eq(rows.map(func(r: Dictionary) -> String: return r["id"]), ["p1", "mine"], "the roster lists the player's gun with the player's fighter, and not the enemy's units")
	for r: Dictionary in rows:
		if r["id"] == "mine":
			eq(r["type"], "Mobile anti-aircraft gun", "the gun's row names its type from the unit file")
			eq(r["steps"], 2, "two steps a turn")
			eq(r["side"], "allies", "on the players' side")
	for id: String in ["mine", "theirs", "target", "far_target"]:
		var m = ui.marker_layer.marker(id)
		check(m != null, "%s has a marker" % id)
		if m != null:
			eq(m.silhouette, str(w.units[id].def.silhouette), "%s: the marker's silhouette is the unit file's" % id)
			near(m.draw_scale, 1.0, 1e-9, "%s is drawn at the plane rule, not the static rule (the complex is drawn at the map's scale by its own art)" % id)
	check(not UnitMarkerArt.is_static("military_complex") and not UnitMarkerArt.is_static("mobile_aa"), "neither is in STATICS (the layer's static_scale is for the tower and the batteries)")
	# in sight: the enemy's gun and complex show when a player unit's sight reaches them, and not when it does not
	var fog := FogVision.new()
	fog.update_from_world(w)
	check(fog.shows_unit(w, "theirs"), "the enemy's gun 200 m from the player's fighter is in sight")
	check(fog.shows_unit(w, "target"), "the enemy's complex 360 m from it is in sight")
	check(not fog.shows_unit(w, "far_target"), "a complex 3,000 m away is not")
	check(fog.shows_unit(w, "mine"), "the player's own gun always is")
	ran += 1

# --- 6. The destroyed complex in the effects layer, and a surface unit's shadow --------------------------------------------------

class _FakeFx extends RefCounted:
	var calls: Array = []
	func clear() -> void:
		calls.append({"call": "clear"})
	func ruin(unit_id: String, pos: Vector2, t: float, kind: String = "radio_tower", size_m: float = 12.0, heading: float = 0.0) -> void:
		calls.append({"call": "ruin", "unit": unit_id, "pos": pos, "t": t, "kind": kind, "size": size_m, "heading": heading})
	func add_ruin(unit_id: String, pos: Vector2, t: float, kind: String = "radio_tower", size_m: float = 12.0, heading: float = 0.0, _s: int = 0) -> void:
		calls.append({"call": "add_ruin", "unit": unit_id, "pos": pos, "t": t, "kind": kind, "size": size_m, "heading": heading})
	func add_scar(_u: String, _p: Vector2, _t: float, _sz: float = 9.0, _r: float = 0.0, _s: int = 0) -> void:
		calls.append({"call": "add_scar"})
	func of(call_name: String) -> Array:
		return calls.filter(func(c: Dictionary) -> bool: return c["call"] == call_name)

func _ruin_and_shadow() -> void:
	# the field: a complex's ruin keeps its kind and its own size, and its flash is sized by the effects share
	var data := FxData.new()
	var frac := StaticArt.mc_effects_frac()
	check(frac > 0.0 and frac <= 1.0, "the effects share of the complex's size is a fraction (%.2f)" % frac)
	var f := FxField.new(data)
	f.world_seed = 20261009
	f.ruin("c1", Vector2(2000.0, 2000.0), 5.0, "military_complex", 80.0, 0.3)
	f.ruin("t1", Vector2(1000.0, 1000.0), 5.0, "radio_tower", 12.0, 0.0)
	eq(f.ruins.size(), 2, "both ruins are in the field")
	eq(str(f.ruins[0]["kind"]), "military_complex", "the complex's ruin keeps its kind (the layer draws it by it)")
	near(float(f.ruins[0]["size_m"]), 80.0, 1e-9, "and the unit's own size")
	near(float(f.ruins[0]["heading"]), 0.3, 1e-9, "and its heading (the art is turned by it)")
	var flash_frac := FxData.f(FxData.grp(f.ruin_o, "flash"), "radius_frac")
	var radii := {}
	for b: Dictionary in f.bursts:
		if str(b.get("grp", "")) == "ruin" and b.get("unit") != null:
			radii[str(b["unit"])] = float(b["radius_m"])
	near(float(radii.get("c1", -1.0)), flash_frac * 80.0 * frac, 1e-6, "the complex's flash is sized by its effects share (%.1f m, not %.1f)" % [flash_frac * 80.0 * frac, flash_frac * 80.0])
	near(float(radii.get("t1", -1.0)), flash_frac * 12.0, 1e-6, "the tower's is untouched")
	# a late joiner: the bare ruin is put back with the kind
	var late := FxField.new(data)
	late.world_seed = 20261009
	late.add_ruin("c1", Vector2(2000.0, 2000.0), 1.0, "military_complex", 80.0, 0.3, 77)
	eq(str(late.ruins[0]["kind"]), "military_complex", "add_ruin takes the kind too")
	# the layer draws it: the branch and the shadow's are in its source (nothing renders headless)
	var layer_src := FileAccess.get_file_as_string("res://scripts/fx/fx_layer.gd")
	check(layer_src.contains('"military_complex"') and layer_src.contains("complex_ruin_art(") and layer_src.contains("_blit_complex_ruin("), "fx_layer.gd draws the complex's ruin art")
	check(layer_src.contains("Color(_tint.r, _tint.g, _tint.b, ra), true)"), "and its shadow, in the shadow pass")
	# the feed: a destroyed complex asks the effects layer for its ruin by the silhouette, and a late joiner gets it back
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "p1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0})
	w.add_unit({"id": "target", "type": "military_complex", "side": "axis", "controller": "ai", "x": 1750.0, "y": 2600.0, "heading": 0.3})
	w.add_unit({"id": "tank1", "type": "tank", "side": "axis", "controller": "ai", "x": 1700.0, "y": 2450.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "gun1", "type": "mobile_aa", "side": "axis", "controller": "ai", "x": 1740.0, "y": 2450.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "bat1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 1780.0, "y": 2450.0, "heading": 0.4})
	w.add_unit({"id": "tow1", "type": "radio_tower", "side": "axis", "controller": "ai", "x": 1820.0, "y": 2450.0, "heading": 0.0})
	w.add_unit({"id": "low1", "type": "light_fighter", "side": "allies", "controller": "player", "x": 1600.0, "y": 2400.0, "heading": 0.0, "altitude_band": "low"})
	var origin := Vector2(1400.0, 2300.0)
	var xf := Transform2D(0.0, Vector2(3.8, 3.8), 0.0, -origin * 3.8)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, xf, "local")
	var fake := _FakeFx.new()
	ui.feed.fx = fake
	var tgt: Unit = w.units["target"]
	tgt.health = 0
	tgt.down = true
	tgt.fate = Unit.FATE_DESTROYED
	ui.feed._destroyed("target", tgt, {"x": tgt.x, "y": tgt.y}, 5.0)
	var rn: Array = fake.of("ruin")
	eq(rn.size(), 1, "the feed asks the effects layer for the complex's ruin")
	if rn.size() == 1:
		eq(rn[0]["kind"], "military_complex", "by the unit's silhouette")
		near(float(rn[0]["size"]), 80.0, 1e-9, "at its size")
		near(float(rn[0]["heading"]), 0.3, 1e-9, "and its heading")
	ui.feed.restore_wrecks(false, ui.game_time(), true)
	var ar: Array = fake.of("add_ruin")
	check(ar.size() >= 1 and str(ar[ar.size() - 1]["kind"]) == "military_complex", "a late joiner's layer gets the complex's ruin back with its kind")
	# the shadow rule: heights by silhouette, behind the switch; the planes, the tower and the battery are in neither table
	var st: UiStyle = ui.marker_layer.style
	check(st.flag("marker.cast_shadow_on"), "the switch is on (PROPOSED)")
	var heights := {"tank1": 2.0, "gun1": 2.4, "low1": 0.0, "bat1": 0.0, "tow1": 0.0, "target": 0.0}
	var sun := st.shadow_dir() * st.sun_len()
	ui.marker_layer.update_poses()
	for id: String in heights:
		var mk = ui.marker_layer.marker(id)
		near(UnitMarkerLayer.cast_height_m(st, mk), float(heights[id]), 1e-9, "%s: the layer's cast height" % id)
	for id: String in ["tank1", "gun1"]:
		var mk = ui.marker_layer.marker(id)
		var want: Vector2 = sun * float(heights[id]) * 3.8 * st.num("marker.true_scale") * mk.draw_scale
		check(mk.shadow_offset.distance_to(want) < 1e-6 and mk.shadow_offset.length() > 3.0, "%s: its shadow is lifted by height x the sun's length (%.2f px, wanted %.2f)" % [id, mk.shadow_offset.length(), want.length()])
		check(mk.shadow_offset.normalized().dot(st.shadow_dir()) > 0.999, "%s: away from the sun" % id)
	var lm = ui.marker_layer.marker("low1")
	var gap: Vector2 = ui.marker_layer.shadow_offset_px(Vector2(float(w.units["low1"].x), float(w.units["low1"].y)), w.band_height("low"), lm.draw_scale)
	check(lm.shadow_offset.distance_to(gap) < 1e-6 and gap.length() > 0.0, "a plane keeps its altitude cue (%.2f px)" % gap.length())
	for id: String in ["bat1", "tow1", "target"]:
		eq(ui.marker_layer.marker(id).shadow_offset, Vector2.ZERO, "%s: no lift (its cast shadow is in its art)" % id)
	# off: the layer as it was
	st.ui["marker"]["cast_shadow_on"] = false
	ui.marker_layer.update_poses()
	eq(ui.marker_layer.marker("tank1").shadow_offset, Vector2.ZERO, "switched off, the tank's shadow is under it again")
	eq(ui.marker_layer.marker("gun1").shadow_offset, Vector2.ZERO, "and the gun's")
	check(ui.marker_layer.marker("low1").shadow_offset.distance_to(gap) < 1e-6, "and the plane's is the same")
	st.ui["marker"]["cast_shadow_on"] = true
	ran += 1
