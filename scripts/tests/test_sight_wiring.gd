extends "res://scripts/test_support/test_case.gd"

# THE MAIN GUNS SEE WHAT THE PLAYER'S FOG SEES (Track SH, the warship, proposed 2026-10-11). Shared spotting (Alex, decision
# mixed-warfare: any friendly unit's sight counts, a long-range gun needs a spotted target) asks the SAME sight as the fog:
# the sight scale and the fog's own line of sight, through World.set_sight_los(Spotting.los_from_vision(fog.vision, world)) -- which
# the sandbox does where it builds the World and the fog. Headless:
#
#   1. on the real terrain, a target on high ground that the only spotter's valley hides: with line of sight OFF it is spotted (it is
#      inside his circle) and the cruiser may fire at it; with line of sight ON it is not spotted (gun_check says "unspotted"); a plane
#      overhead sees it all the same; the knob switched at run time is followed, and so is a salvo planned before it was switched:
#      at the moment of fire it is held
#   2. the sandbox wires it: Local's World has the line-of-sight query and the fog's sight scale, and the query asks the fog's vision

const World = preload("res://scripts/sim/world.gd")
const Spotting = preload("res://scripts/sim/spotting.gd")
const Terrain = preload("res://scripts/world/terrain.gd")
const FogVision = preload("res://scripts/render/fog_vision.gd")
const FogViewshed = preload("res://scripts/render/fog_viewshed.gd")
const FogSites = preload("res://scripts/render/fog_viewshed_sites.gd")
const GunWorlds = preload("res://scripts/test_support/gun_worlds.gd")

const SEED := 20261009

var _sentinel := 0

func setup(main) -> void:
	timeout_seconds = 180.0
	_hidden_behind_high_ground()
	_sandbox(main)
	check(_sentinel == 2, "both parts ran (%d of 2)" % _sentinel)
	finish()

# --- 1 ------------------------------------------------------------------------------------------------

func _hidden_behind_high_ground() -> void:
	var terrain := Terrain.new(SEED)
	if not check(terrain.ok(), "the terrain loads: %s" % str(terrain.errors)):
		return
	var site: Vector2 = FogSites.find_valley(terrain).p
	# The point on higher ground, a few hundred metres off, that the valley hides from a tank (found with the viewshed engine, as test_viewshed does).
	var eng := FogViewshed.new(8.0, 1.0, 1.0, 12.0, 6.0, 3.0)
	eng.attach_terrain(terrain, 0.9, 1000.0)
	var probe := eng.compute(site, 2.5, 800.0)
	var hidden := Vector2.INF
	for ring: float in [350.0, 450.0, 300.0, 550.0]:
		for a in 24:
			var p: Vector2 = site + Vector2.from_angle(float(a) / 24.0 * TAU) * ring
			if hidden == Vector2.INF and not probe.visible_ground(p.x, p.y) and terrain.level_at(p.x, p.y) >= 1:
				hidden = p
	if not check(hidden != Vector2.INF, "a point on higher ground the valley hides was found"):
		return
	# The ship lies 1,500 m beyond the hidden point, away from the valley (its own sight, 1,000 m, reaches neither).
	var away := (hidden - site).normalized()
	var ship := hidden + away * 1500.0
	if ship.x < 100.0 or ship.x > 4900.0 or ship.y < 100.0 or ship.y > 4900.0:
		ship = hidden - away * 1500.0
		if ship.x < 100.0 or ship.x > 4900.0 or ship.y < 100.0 or ship.y > 4900.0:
			ship = hidden + away.rotated(PI / 2.0) * 1500.0
	check(ship.x >= 100.0 and ship.x <= 4900.0 and ship.y >= 100.0 and ship.y <= 4900.0, "(the ship's place is on the map: %s)" % str(ship))
	var w := World.new()
	w.quiet = true
	w.rng_seed = 5
	w.add_player("local")
	check(w.add_unit({"id": "cruiser", "type": "cruiser", "side": "allies", "controller": "player", "x": ship.x, "y": ship.y, "heading": 0.0, "speed": 0.0}) != "", "the cruiser: %s" % w.last_error)
	check(w.add_unit({"id": "tank", "type": "tank", "side": "allies", "controller": "player", "x": site.x, "y": site.y, "heading": 0.0, "speed": 0.0}) != "", "a friendly tank in the valley: %s" % w.last_error)
	check(w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": hidden.x, "y": hidden.y, "heading": 0.0}) != "", "an enemy battery on the high ground: %s" % w.last_error)
	var vision := FogVision.new()
	check(vision.ok(), "FogVision loads: %s" % str(vision.errors))
	vision.attach_terrain(terrain)
	eq(vision.line_of_sight, FogVision.LOS_NONE, "the fog's line of sight is off in the data")
	w.set_sight_scale(vision.sight_scale)
	w.set_sight_los(Spotting.los_from_vision(vision, w))
	var tgt := {"unit": "aa"}
	check(site.distance_to(hidden) < 600.0, "(the battery is inside the tank's 600 m circle: %.0f m)" % site.distance_to(hidden))
	check(w.spotted_now("allies", tgt), "line of sight OFF: the tank's circle holds the battery, so it is spotted")
	eq(str(w.gun_check("cruiser", 0, tgt)["reason"]), "", "line of sight OFF: the cruiser may fire at it")
	check(not w.spotted_now("axis", {"unit": "cruiser"}), "(the enemy does not see the ship)")
	# The fog's switch, thrown at run time: the high ground is hidden from the valley.
	check(vision.set_line_of_sight(FogVision.LOS_TERRAIN), "the fog's line of sight goes to 'terrain'")
	check(not w.spotted_now("allies", tgt), "line of sight ON: the battery behind high ground is NOT spotted")
	var chk := w.gun_check("cruiser", 0, tgt)
	eq(str(chk["reason"]), "unspotted", "and the main guns cannot be activated: unspotted")
	check(float(chk["range_m"]) > 1000.0 and float(chk["range_m"]) < 3000.0, "(in range: %.0f m)" % float(chk["range_m"]))
	check(w.spotted_now("allies", {"point": [site.x + 10.0, site.y]}), "the tank's own ground is spotted")
	# A plane overhead sees over the cliffs, as the fog says: it spots what the tank cannot.
	check(w.add_unit({"id": "scout", "type": "light_fighter", "side": "allies", "controller": "player", "x": site.x, "y": site.y, "heading": 0.0, "altitude_band": "low", "speed": 100.0}) != "", "a friendly plane over the valley")
	check(w.spotted_now("allies", tgt), "line of sight ON: a plane at the low band over the valley spots it")
	eq(w.spotters_now("allies", tgt), ["scout"] as Array[String], "(the plane, not the tank)")
	w.units["scout"].down = true
	w.units["scout"].fate = "destroyed"
	check(not w.spotted_now("allies", tgt), "without the plane: not spotted again")
	# The switch back.
	vision.set_line_of_sight(FogVision.LOS_NONE)
	check(w.spotted_now("allies", tgt), "line of sight switched OFF again: spotted")
	# A salvo planned while it was spotted is fired POORLY when the line of sight is on at the moment of fire (Alex, decision
	# outside-cone-release, 2026-10-11: "Fire a poorer one"; data/sim/guns.json gun_unspotted_mode).
	var st := w.plan_step("cruiser", 0, {"fire": {"special": "main_guns", "target": tgt}})
	check(not st.is_empty() and st["fire"]["ok"] == true, "planned while spotted: %s" % str(st.get("fire", w.last_error)))
	vision.set_line_of_sight(FogVision.LOS_TERRAIN)
	w.commit("local")
	var res := w.resolve()
	check(not res.is_empty(), "the turn resolves: %s" % w.last_error)
	eq(GunWorlds.events_of(res, "gun_hold", "cruiser").size(), 0, "line of sight on at the moment of fire: the salvo is not held")
	var poor := GunWorlds.events_of(res, "shell_fire", "cruiser")
	eq(poor.size(), 1, "...it is fired")
	if poor.size() == 1:
		check(bool(poor[0].get("poor_shot", false)) and str(poor[0].get("poor_why", "")) == "unspotted", "...as a poor shot, unspotted")
	check(w.shells_in_flight.size() > 0, "shells flew")
	check(w.units["cruiser"].gun_ready_turn("main_guns") > 0, "and the reload was spent")
	_sentinel += 1

# --- 2 ------------------------------------------------------------------------------------------------

func _sandbox(main) -> void:
	main.setup_menu()
	if not check(main.start_sandbox(), "Local builds the sandbox"):
		return
	var sb: Node = main.sandbox
	if not check(sb != null, "there is a sandbox"):
		return
	var w: World = sb.world
	var vision: Object = sb.fog.vision
	check(w.spotting.los.is_valid(), "the World has a line-of-sight query for its spotting")
	near(w.spotting.sight_scale, float(vision.sight_scale), 1e-9, "and the fog's sight scale (%.2f)" % float(vision.sight_scale))
	# The query is the fog's: with line of sight off it is clear; switched on it asks the vision's viewshed.
	var first: String = w.units.keys()[0]
	var u: Object = w.units[first]
	var eye := {"unit": u, "x": u.x, "y": u.y, "altitude_band": u.altitude_band, "height_m": w.band_height(u.altitude_band)}
	var tgt := {"unit": null, "x": u.x + 250.0, "y": u.y, "altitude_band": "surface", "height_m": 0.0}
	vision.set_line_of_sight("none")
	check(bool(w.spotting.los.call(eye, tgt)), "the fog's line of sight off: the query is clear")
	var built_before: bool = vision.viewshed != null
	vision.set_line_of_sight("terrain")
	w.spotting.los.call(eye, tgt)
	check(vision.viewshed != null, "the knob 'terrain': the query goes through the fog's viewshed (it was %s before)" % ("built" if built_before else "not built"))
	vision.set_line_of_sight("none")
	main.stop_sandbox()
	_sentinel += 1
