extends "res://scripts/test_support/test_case.gd"

# LINES OF FIRE, STAGE 2 (builder LOF2, 2026-10-12; decision line-of-fire, tank-accuracy; every number PROPOSED, in data/sim/line_of_fire.json):
# combat uses the height grid and the line check when it is given them (World.set_line_of_fire; SandboxScenario.populate does it when the data's
# `enabled` is true, and it is false). Headless, on the open bay of Hold the bridge's map (seed 55: flat water, no tree) with walls laid in by
# hand, and on the Strike's bridge (seed 20261009).
#
#   DATA        the table of straight rounds is the set of weapons whose round has the path 'straight' (data/sim/rounds.json), no other; each spread
#               gives its reference case the old base_hit_chance; the bridge's deck is bridges.json crown_h and its parapets 1 m
#   OFF         with the lines off (never given, or taken away) combat is byte for byte what it was: the same events from the same World; a weapon not
#               in the table (flak) is unchanged even with the lines on, and a fire event carries nothing new when they are off
#   ODDS        range: a tank's chance falls with the distance; size: it rises with the target's; cover: a tank behind a wall is hit less than an
#               exposed one, and the lower the wall the more of it shows; a target of which nothing shows is HELD (no fire event), by a wall and by
#               a hill against a low plane
#   THE LOW BRIDGE  tanks at the two ends of the bridge see each other; a tank beside a parapet shows its turret over it and part of its hull
#   MISSES      a miss lands on the first thing its line meets, with that thing's material; a hit names the box it struck (hull, turret); a miss in
#               open water lands in the water or is lost in the air
#   THE DICE    the hit rolls are the combat stream's own (recomputed from the seed, equal to the events'): the landing draws shift nothing
#   DETERMINISM the same World twice gives the same events, to the byte

const World = preload("res://scripts/sim/world.gd")
const Rules = preload("res://scripts/sim/line_of_fire_rules.gd")
const HeightGrid = preload("res://scripts/sim/height_grid.gd")
const LineOfFire = preload("res://scripts/sim/line_of_fire.gd")
const Shapes = preload("res://scripts/sim/line_of_fire_shapes.gd")
const Odds = preload("res://scripts/sim/line_of_fire_odds.gd")
const CombatLines = preload("res://scripts/sim/combat_lines.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const Rounds = preload("res://scripts/sim/rounds.gd")
const Mulberry32 = preload("res://scripts/core/mulberry32.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")
const GroundMap = preload("res://scripts/world/ground_map.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")
const LofCalibration = preload("res://scripts/test_support/lof_calibration.gd")

const SEED_BAY := 55
const BAY := Vector2(3700.0, 3560.0)
const SEED_STRIKE := 20261009

var rules: Rules
var grid: HeightGrid
var cal: LofCalibration
var _sections := 0

func setup(_main) -> void:
	timeout_seconds = 600.0
	for part: Script in [World, Rules, HeightGrid, LineOfFire, Shapes, Odds, CombatLines, Combat, Rounds, WaterGen, GroundMap, TankWorlds, LofCalibration]:
		if not part.can_instantiate():
			fail("%s does not compile -- see the Parse Error in the .err.log" % part.resource_path)
			finish()
			return
	rules = Rules.new()
	if not check(rules.ok(), "data/sim/line_of_fire.json loads: %s" % [rules.errors]):
		finish()
		return
	grid = HeightGrid.shared(SEED_BAY, WaterGen.shared(SEED_BAY))
	if not check(grid.ok(), "the grid of seed %d builds" % SEED_BAY):
		finish()
		return
	grid.build_rect(Rect2(BAY.x - 50.0, BAY.y - 300.0, 700.0, 600.0))
	cal = LofCalibration.new(rules)
	var t0 := Time.get_ticks_usec()
	_data()
	_off()
	_odds()
	_held()
	_low_bridge()
	_landings()
	_dice()
	_determinism()
	print("[lof2] test total %.0f ms, %d sections" % [(Time.get_ticks_usec() - t0) / 1000.0, _sections])
	check(_sections == 8, "all eight sections ran (%d)" % _sections)
	finish()

# --- helpers ---------------------------------------------------------------------------------------------------

# A synthetic world box for the stamp layer: a stone wall `half_l` along x and `half_w` across, from 0 to `h`.
func _wall(cx: float, cy: float, half_l: float, half_w: float, h: float) -> Dictionary:
	return {"part": "test", "material": Rules.STONE, "material_name": "stone", "kind": "box", "stamp": true, "standable": false,
		"cx": cx, "cy": cy, "cs": 1.0, "sn": 0.0, "hl": half_l, "hw": half_w, "ro": 0.0, "ri": 0.0, "z0": 0.0, "z1": h}

# A World on the bay: tank "a" (allies) at BAY facing +x, a target of `type` (axis) `dist` m on, facing back, both at rest, both under players' hands (no AI to ready).
func _world(dist: float, seed_v: int = 3, type_b: String = "tank", lines_on: bool = true, a_type: String = "tank") -> World:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.rng_seed = seed_v
	w.add_unit({"id": "a", "type": a_type, "side": "allies", "controller": "player", "x": BAY.x, "y": BAY.y, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "b", "type": type_b, "side": "axis", "controller": "player", "x": BAY.x + dist, "y": BAY.y, "heading": PI, "speed": 0.0})
	if lines_on:
		w.set_line_of_fire(CombatLines.new(grid, rules))
	return w

# Play `turns` turns, putting every unit back on full health after each (so a long exchange is not ended by a kill) and every gun loaded (the tank's gun is an
# order since 2026-10-14, builder ORD: each turn every tank orders it at the nearest enemy, one aimed shell each, TURNS of them are as many shots as 15 turns of rolls
# were); returns every event, each with its turn.
const TURNS := 15

func _play(w: World, turns: int) -> Array:
	var out: Array = []
	for _t in turns:
		TankWorlds.fire_at_nearest(w)
		for p: String in w.players.duplicate():
			w.commit(p)
		var res := w.resolve()
		if res.is_empty():
			fail("a turn did not resolve: %s" % w.last_error)
			return out
		for ev: Dictionary in res["events"]:
			out.append(ev)
		for id: String in w.units:
			var u: Object = w.units[id]
			u.health = u.def.health
			u.down = false
			u.fate = ""
			u.gun_ready = {}
		w.begin_turn()
	return out

func _fires(events: Array, unit: String = "") -> Array:
	var out: Array = []
	for e: Dictionary in events:
		if e["type"] == "fire" and (unit == "" or e["unit"] == unit):
			out.append(e)
	return out

# The state dictionary combat uses for a unit at rest.
func _state(w: World, id: String) -> Dictionary:
	var u: Object = w.units[id]
	return {"x": u.x, "y": u.y, "heading": u.heading, "height_m": w.band_height(u.altitude_band), "pitch": 0.0, "vx": 0.0, "vy": 0.0, "vz": 0.0}

# The line-of-fire assessment of shooter `sid`'s first weapon against `tid`, as the resolver makes it (roll seed 11).
func _assess(w: World, cl: CombatLines, sid: String, tid: String, roll_seed: int = 11) -> Dictionary:
	var s: Object = w.units[sid]
	var t: Object = w.units[tid]
	var ss := _state(w, sid)
	var ts := _state(w, tid)
	var weapon: Object = s.def.weapons[0]
	var pose := Combat.pose(ss, weapon.hardpoints[0])
	var geo := Combat.evaluate_pose(pose, weapon, ts, w.combat.odds_factors, w.combat.factor_params())
	return cl.assess(s, ss, pose, weapon, geo, t, ts, roll_seed)

func _tank_odds(dist: float, wall_h: float = 0.0, wall_gap: float = 4.0) -> Dictionary:
	var w := _world(dist, 3, "tank", true)
	var cl: CombatLines = w.line_of_fire
	if wall_h > 0.0:
		grid.stamp("test_wall", [_wall(BAY.x + dist - wall_gap, BAY.y, 1.0, 12.0, wall_h)])
	var a := _assess(w, cl, "a", "b")
	grid.unstamp("test_wall")
	return a

# --- 1. data ----------------------------------------------------------------------------------------------------

func _data() -> void:
	_sections += 1
	check(not rules.enabled, "the switch is off in the data (Alex has not looked at the proofs yet)")
	var w := World.new()
	w.quiet = true
	var rounds := Rounds.shared() as Rounds
	# every weapon of every unit: in the table exactly when its round is straight
	var straight: Array = []
	var wid_unit: Dictionary = {}
	var dir := DirAccess.open("res://data/units")
	for f in dir.get_files():
		if f.ends_with(".json") and not f.begins_with("_"):
			var def: Variant = w.unit_def(f.get_basename())
			if def == null:
				continue
			for wp in def.weapons:
				var round_def: Variant = rounds.round_of(str(wp.round_id))
				var is_straight: bool = round_def != null and round_def.path == "straight"
				if is_straight:
					straight.append(wp.id)
					wid_unit[wp.id] = def
				eq(rules.has_spread(wp.id), is_straight, "%s (%s, round %s): in the table of straight rounds exactly when the round's path is straight" % [wp.id, def.id, wp.round_id])
	straight.sort()
	var in_table: Array = rules.spreads.keys()
	in_table.sort()
	eq(in_table, straight, "the table of spreads is exactly the straight rounds")
	for wid: String in rules.spreads:
		var spec: Dictionary = rules.spreads[wid]
		var found := cal.find_weapon(wid)
		if not check(not found.is_empty(), "the weapon %s of the table exists" % wid):
			continue
		near(float(spec["odds"]), float(found["weapon"].base_hit_chance), 1e-9, "%s: the reference odds are the weapon's own base_hit_chance" % wid)
		var p := cal.reference_p(found, spec, float(spec["spread_mrad"]))
		near(p, float(spec["odds"]), 0.004, "%s: a still, exposed %s at %.0f m (%+.0f deg) takes %.3f from a spread of %s mrad" % [wid, spec["target"], spec["range_m"], spec["elevation_deg"], p, str(spec["spread_mrad"])])
	# the low bridge: the deck is bridges.json crown_h and the parapets parapet_h
	var bridges: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/world/bridges.json"))
	var bdef: Variant = w.unit_def("bridge")
	near(float(bdef.shape_boxes[0]["top_m"]), float(bridges["arch"]["crown_h"]["value"]), 1e-9, "the bridge's deck is bridges.json crown_h")
	near(float(bdef.shape_boxes[1]["top_m"]) - float(bdef.shape_boxes[1]["bottom_m"]), float(bridges["arch"]["parapet_h"]["value"]), 1e-9, "its parapets are bridges.json parapet_h")
	near(float(bridges["arch"]["parapet_h"]["value"]), 1.0, 1e-9, "... 1 m (Alex)")
	check(rules.not_target_parts.has("deck"), "the deck is no target")
	# the glue reads the table
	check(CombatLines.new(grid, rules).applies(w.unit_def("tank").weapons[0]), "a tank's gun takes the lines")
	check(not CombatLines.new(grid, rules).applies(w.unit_def("anti_aircraft_battery").weapons[0]), "flak does not")

# --- 2. off changes nothing ------------------------------------------------------------------------------------

func _off() -> void:
	_sections += 1
	# (a) never given, and given then taken away: the same events, to the byte, and no new key on a fire event
	var plain := _play(_world(150.0, 5, "tank", false), TURNS)
	var w2 := _world(150.0, 5, "tank", true)
	w2.set_line_of_fire(null)
	var taken := _play(w2, TURNS)
	eq(JSON.stringify(taken), JSON.stringify(plain), "lines given and taken away: the events are those of a World that never had them, to the byte")
	var fires := _fires(plain)
	check(fires.size() > 20, "the exchange has fire events to compare (%d)" % fires.size())
	var keys_ok := true
	for e: Dictionary in fires:
		for k: String in ["vis", "spread_m", "hit_part", "mx", "m_material"]:
			if e.has(k):
				keys_ok = false
	check(keys_ok, "with the lines off a fire event carries none of the new fields")
	# (b) a weapon not in the table is unchanged with the lines ON: a battery's flak against a fighter, the flak events equal with and without
	for use_lines in [false, true]:
		var w := World.new()
		w.quiet = true
		w.add_player("local")
		w.rng_seed = 9
		w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "allies", "controller": "player", "x": BAY.x, "y": BAY.y, "heading": 0.0})
		w.add_unit({"id": "f", "type": "light_fighter", "side": "axis", "controller": "player", "x": BAY.x + 150.0, "y": BAY.y, "heading": PI, "speed": 30.0, "altitude_band": "low"})
		if use_lines:
			w.set_line_of_fire(CombatLines.new(grid, rules))
		var ev := _play(w, 1)
		var flak: Array = []
		for e: Dictionary in ev:
			if e["type"] == "fire" and (e["weapon"] == "flak" or e["weapon"] == "light_flak"):
				flak.append(e)
		if use_lines:
			eq(JSON.stringify(flak), _off_flak, "the battery's flak events are the same with the lines on (flak is not a straight round)")
		else:
			_off_flak = JSON.stringify(flak)
			check(flak.size() > 0, "the flak fires (%d events)" % flak.size())

var _off_flak := ""

# --- 3. the odds ------------------------------------------------------------------------------------------------

func _odds() -> void:
	_sections += 1
	# range: an exposed tank's chance falls with the distance (and is large close up)
	var p := {}
	var line := "[lof2] a tank's gun against a tank, end on, in the open:"
	for d in [50.0, 100.0, 150.0, 200.0, 300.0, 350.0]:
		var a := _tank_odds(d)
		check(bool(a["visible"]), "an exposed tank %.0f m off is visible" % d)
		p[d] = float(a["odds"])
		line += "  %.0f m %.3f" % [d, p[d]]
	print(line)
	for pair in [[50.0, 100.0], [100.0, 150.0], [150.0, 200.0], [200.0, 300.0], [300.0, 350.0]]:
		check(p[pair[0]] > p[pair[1]], "the chance falls with range: %.0f m %.3f > %.0f m %.3f" % [pair[0], p[pair[0]], pair[1], p[pair[1]]])
	check(p[350.0] < p[100.0] * 0.4, "... a long way: at 350 m it is under two fifths of its chance at 100 m (the aimed shell's spread, 0.6 at 200 m; was a fifth for the 0.12 roll)")
	# size: at 200 m the bigger the target the better the odds
	var sizes := {}
	for type_b in ["light_fighter", "tank", "supply_boat", "military_complex"]:
		var w := _world(200.0, 3, type_b, true)
		if type_b == "light_fighter":
			w.units["b"].altitude_band = "low"
		var a := _assess(w, w.line_of_fire, "a", "b")
		sizes[type_b] = float(a["odds"]) if bool(a["visible"]) else 0.0
	print("[lof2] a tank's gun at 200 m by target: %s" % [str(sizes)])
	check(float(sizes["tank"]) < float(sizes["supply_boat"]) and float(sizes["supply_boat"]) < float(sizes["military_complex"]), "the chance rises with the target's size: tank %.3f < boat %.3f < complex %.3f" % [sizes["tank"], sizes["supply_boat"], sizes["military_complex"]])
	# cover: the wall 4 m in front of the target. none, 1.15 m (sandbags), 1.35 m, 1.6 m (over the hull, under the turret's top), then a wall that hides it
	var open := _tank_odds(200.0)
	var bags := _tank_odds(200.0, 1.15)
	var wall135 := _tank_odds(200.0, 1.35)
	var wall16 := _tank_odds(200.0, 1.6)
	var hidden := _tank_odds(200.0, 2.6)
	print("[lof2] a tank's gun at 200 m: open %.3f, behind 1.15 m %.3f, 1.35 m %.3f, 1.6 m %.3f, 2.6 m %s" % [open["odds"], bags["odds"], wall135["odds"], wall16["odds"], "held" if not bool(hidden["visible"]) else "visible"])
	check(bool(bags["visible"]) and float(bags["odds"]) < float(open["odds"]) and float(bags["odds"]) > 0.0, "hull-down behind sandbags: hit less than exposed (%.3f < %.3f)" % [bags["odds"], open["odds"]])
	check(float(wall135["odds"]) < float(bags["odds"]), "a higher wall, a lower chance (1.35 m %.3f < 1.15 m %.3f)" % [wall135["odds"], bags["odds"]])
	check(float(wall16["odds"]) < float(wall135["odds"]) and float(wall16["odds"]) > 0.0, "... with only the turret showing the chance is small and not nothing (%.3f)" % wall16["odds"])
	check(float(open["share"]) > 0.99 and float(bags["share"]) < float(open["share"]), "the visible share falls the same way (%.2f, %.2f)" % [open["share"], bags["share"]])
	check(not bool(hidden["visible"]), "behind a wall taller than the tank nothing shows")
	# aiming at the middle of the whole target instead of what is visible: hull-down hit much less
	var sc_rules := _rules_with({"odds": {"aim": "silhouette_centre"}})
	var w_sc := _world(200.0)
	var cl_sc := CombatLines.new(grid, sc_rules)
	grid.stamp("test_wall", [_wall(BAY.x + 196.0, BAY.y, 1.0, 12.0, 1.15)])
	var a_sc := _assess(w_sc, cl_sc, "a", "b")
	grid.unstamp("test_wall")
	check(float(a_sc["odds"]) < float(bags["odds"]), "the other aim (the middle of the whole silhouette) hits a tank behind sandbags less (%.3f < %.3f)" % [a_sc["odds"], bags["odds"]])

func _rules_with(changes: Dictionary) -> Rules:
	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Rules.PATH))
	for sec: String in changes:
		for key: String in changes[sec]:
			(raw[sec][key] as Dictionary)["value"] = changes[sec][key]
	return Rules.new(raw)

# --- 4. held ----------------------------------------------------------------------------------------------------

func _held() -> void:
	_sections += 1
	# a wall that hides the whole tank: it is not fired on, by either side, in a whole turn; the same turn without the wall has fire
	var open := _fires(_play(_world(150.0, 4), TURNS))
	check(open.size() >= 25, "in the open both tanks fire (%d fire events in %d turns, one ordered shell each a turn)" % [open.size(), TURNS])
	grid.stamp("test_wall", [_wall(BAY.x + 100.0, BAY.y, 1.0, 14.0, 2.6)])
	var behind := _fires(_play(_world(150.0, 4), TURNS))
	grid.unstamp("test_wall")
	eq(behind.size(), 0, "behind a 2.6 m wall nothing shows and the guns hold: no fire event in %d turns" % TURNS)
	# a wall that leaves the turret: they fire, and every shot says how much was in view
	grid.stamp("test_wall", [_wall(BAY.x + 100.0, BAY.y, 1.0, 14.0, 1.6)])
	var part := _fires(_play(_world(150.0, 4), TURNS))
	grid.unstamp("test_wall")
	check(part.size() > 0, "a wall of 1.6 m leaves the turrets in view: the guns fire (%d)" % part.size())
	var share_ok := true
	for e: Dictionary in part:
		if not (float(e["vis"]) > 0.0 and float(e["vis"]) < 1.0):
			share_ok = false
	check(share_ok, "... each shot says the visible share, a part of the target")
	# a plane behind a hill: the same line check between the ground and the air. A gun at the foot of a 24 m step, 3 m before it; a plane at 120 m.
	grid.stamp("test_step", [_wall(BAY.x + 103.0, BAY.y, 100.0, 40.0, 24.0)])
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "a", "type": "mobile_aa", "side": "allies", "controller": "player", "x": BAY.x, "y": BAY.y, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "near", "type": "light_fighter", "side": "axis", "controller": "player", "x": BAY.x + 8.0, "y": BAY.y + 2.0, "heading": 0.0, "speed": 30.0, "altitude_band": "low"})
	w.add_unit({"id": "far", "type": "light_fighter", "side": "axis", "controller": "player", "x": BAY.x + 240.0, "y": BAY.y, "heading": 0.0, "speed": 30.0, "altitude_band": "low"})
	var cl := CombatLines.new(grid, rules)
	var n := _assess(w, cl, "a", "near")
	var f := _assess(w, cl, "a", "far")
	grid.unstamp("test_step")
	var f2 := _assess(w, cl, "a", "far")
	check(bool(n["visible"]), "a low-band plane close above the gun is in view past the step")
	check(not bool(f["visible"]), "a low-band plane 240 m off, behind a 24 m step 3 m ahead of the gun, is hidden: the AA holds")
	check(bool(f2["visible"]), "... and in view once the step is gone")

# --- 5. the low bridge ------------------------------------------------------------------------------------------

func _low_bridge() -> void:
	_sections += 1
	var w := TankWorlds.world("allies", true)
	var water := TankWorlds.water()
	var g: HeightGrid = HeightGrid.shared(SEED_STRIKE, water)
	var cl := CombatLines.new(g, rules)
	w.set_line_of_fire(cl)
	var site: Dictionary = TankWorlds.bridge_site()
	var road: PackedVector2Array = TankWorlds.ground().road
	var idx: int = site["road_index"]
	var a_pos := GroundMap.road_point(road, idx, -45.0)
	var b_pos := GroundMap.road_point(road, idx, 45.0)
	w.add_unit({"id": "ta", "type": "tank", "side": "axis", "controller": "player", "x": a_pos.x, "y": a_pos.y, "heading": (b_pos - a_pos).angle(), "speed": 0.0})
	w.add_unit({"id": "tb", "type": "tank", "side": "allies", "controller": "player", "x": b_pos.x, "y": b_pos.y, "heading": (a_pos - b_pos).angle(), "speed": 0.0})
	cl.sync(w.units)
	var a := _assess(w, cl, "ta", "tb")
	check(bool(a["visible"]), "the stage 1 proof a1, now with the low bridge: a tank at one end of the bridge sees the tank at the other (it was a solid 6.5 m slab)")
	check(float(a["share"]) > 0.9, "... all of it, over the level deck, the parapets beside the line (%.2f)" % float(a["share"]))
	print("[lof2] across the low bridge, 90 m: visible share %.2f, odds %.3f" % [a["share"], a["odds"]])
	# the bridge is the same to the guns whichever way round
	var back := _assess(w, cl, "tb", "ta")
	check(bool(back["visible"]), "... and the other way")
	# beside a parapet: a gun 40 m off one side of the bridge, a tank on the deck 3 m that side of the axis (6 m long, its front 1 m behind the near parapet, 1 m of stone)
	var bp: Vector2 = site["pos"]
	var hd: float = site["heading"]
	var across := Vector2(-sin(hd), cos(hd))
	var gun := bp + across * 40.0
	var tgt := bp + across * 3.0
	var l := cl.lof
	var boxes := Shapes.world_boxes(w.unit_def("tank"), rules, tgt.x, tgt.y, (bp - gun).angle() + PI, 0.0)
	var ex := l.exposure_xyz(gun.x, gun.y, 2.3, boxes, 1, false, true)
	var hull: Dictionary = ex["boxes"][0]
	var turret: Dictionary = ex["boxes"][1]
	print("[lof2] a tank on the deck behind the near parapet: hull %.2f, turret %.2f in view" % [hull["share"], turret["share"]])
	check(float(hull["share"]) > 0.2 and float(hull["share"]) < 0.4, "a tank 1 m behind a 1 m parapet shows only the top rows of its hull (%.2f, the two rows over 1 m)" % float(hull["share"]))
	check(float(turret["share"]) > 0.99, "... and all of its turret (over the parapet)")
	# a shot at the bridge itself: the parapets are what a gun sees
	var tb: Object = w.units["bridge_1"]
	check(cl.boxes_of(tb, _state(w, "bridge_1")).size() == 3, "the bridge is a deck and two parapets to the glue")
	var wb := _assess(w, cl, "ta", "bridge_1")
	check(bool(wb["visible"]), "an enemy tank 45 m from the bridge sees its parapets")

# --- 6. where a round goes --------------------------------------------------------------------------------------

func _landings() -> void:
	_sections += 1
	# a tank 200 m off behind a 1.15 m wall 4 m in front of it: rounds that fall short land in the wall, rounds that go over or wide in the water
	var wall_x := BAY.x + 196.0
	grid.stamp("test_wall", [_wall(wall_x, BAY.y, 1.0, 12.0, 1.15)])
	var w := _world(200.0)
	var cl: CombatLines = w.line_of_fire
	var a := _assess(w, cl, "a", "b")
	check(bool(a["visible"]), "the tank behind the wall has parts in view")
	var muzzle := cl.muzzle_of(w.units["a"], _state(w, "a"), Combat.pose(_state(w, "a"), w.units["a"].def.weapons[0].hardpoints[0]))
	var on_wall := 0
	var in_air := 0
	var in_water := 0
	var other := 0
	var first_ok := true
	var bad := ""
	for j in 400:
		var land := cl.landing(a, false, 1234 + j * 7, j)
		check(land.has("m_material"), "a miss says what it landed on")
		var mat := str(land["m_material"])
		var kind := str(land["m_kind"])
		var mx := float(land["mx"])
		var mz := float(land["mz"])
		if kind == "cell" and mat == "stone" and mx >= wall_x - 1.2 and mx <= wall_x + 1.2:
			on_wall += 1
			if mz > 1.15 + 1e-3 or mz < -1e-3:
				first_ok = false
				bad = "a wall landing at height %.3f" % mz
		elif kind == "air":
			in_air += 1
		elif mat == "water":
			in_water += 1
			if absf(mz) > 1e-2:
				first_ok = false
				bad = "a water landing at height %.3f" % mz
		else:
			other += 1
		# nothing earlier on the line: a hair before the landing point the line is clear
		if kind != "air":
			var dx := mx - muzzle[0]
			var dy := float(land["my"]) - muzzle[1]
			var dz := mz - muzzle[2]
			var len := sqrt(dx * dx + dy * dy + dz * dz)
			var k := (len - 0.06) / len
			if not bool(cl.lof.trace_xyz(muzzle[0], muzzle[1], muzzle[2], muzzle[0] + dx * k, muzzle[1] + dy * k, muzzle[2] + dz * k, 1)["clear"]):
				first_ok = false
				bad = "the line to %s was stopped before its landing point" % str(land)
	print("[lof2] 400 misses at a tank behind a 1.15 m wall at 200 m: %d in the wall, %d in the water, %d lost in the air, %d other" % [on_wall, in_water, in_air, other])
	check(first_ok, "every miss lands on the FIRST thing its line meets (%s)" % bad)
	check(on_wall > 40, "many misses land in the wall in front of the tank (%d of 400)" % on_wall)
	check(in_air + in_water > 40, "and others go over or wide, into the water or the air (%d)" % (in_air + in_water))
	eq(other, 0, "nothing else in the bay to land on")
	# a hit names the box it struck: with the wall at 1.15 m both boxes show; with a wall at 1.6 m only the turret does
	var parts := {}
	for j in 300:
		var land := cl.landing(a, true, 99 + j * 13, j)
		parts[str(land["hit_part"])] = int(parts.get(str(land["hit_part"]), 0)) + 1
	check(parts.has("hull") and parts.has("turret"), "behind 1.15 m a hit can strike the hull or the turret: %s" % [str(parts)])
	check(int(parts.get("turret", 0)) > int(parts.get("hull", 0)), "... the turret more often (the aim is at what is in view)")
	grid.stamp("test_wall", [_wall(wall_x, BAY.y, 1.0, 12.0, 1.6)])
	var w2 := _world(200.0)
	var a2 := _assess(w2, w2.line_of_fire, "a", "b")
	var parts2 := {}
	for j in 300:
		var land: Dictionary = w2.line_of_fire.landing(a2, true, 5 + j * 11, j)
		parts2[str(land["hit_part"])] = int(parts2.get(str(land["hit_part"]), 0)) + 1
	grid.unstamp("test_wall")
	eq(parts2.keys(), ["turret"], "behind 1.6 m a hit can only strike the turret")
	# in a whole turn of the exchange the fire events carry it all
	var ev := _fires(_play(_world(250.0, 8), TURNS))
	var hits := 0
	var misses := 0
	var fields_ok := true
	for e: Dictionary in ev:
		if bool(e["hit"]):
			hits += 1
			if not (e.has("hit_part") and e.has("hx") and ["hull", "turret"].has(str(e["hit_part"]))):
				fields_ok = false
		else:
			misses += 1
			if not (e.has("mx") and e.has("my") and e.has("mz") and e.has("m_material") and e.has("m_kind")):
				fields_ok = false
		if not (e.has("vis") and e.has("spread_m")):
			fields_ok = false
	check(hits > 5 and misses > 5, "the exchange has hits and misses (%d, %d)" % [hits, misses])
	check(fields_ok, "every hit says the box it struck, every miss where it landed and what with, every shot the visible share and the spread")

# --- 7. the dice ------------------------------------------------------------------------------------------------

func _dice() -> void:
	_sections += 1
	# the hit rolls are the combat stream's own: recomputed from the seed they equal the events'. The landing draws (own stream) shift nothing.
	var w := _world(250.0, 21)
	var ev := _fires(_play(w, 20))
	var mismatches := 0
	var checked := 0
	var idx := {"a": 0, "b": 1}
	for e: Dictionary in ev:
		var rng := Mulberry32.new(Combat.roll_seed(21, int(e["turn"]), int(idx[str(e["unit"])]), 0, int(e["hardpoint"]), int(e["tick"])))
		var hit := rng.next() < float(e["odds"])
		checked += 1
		if hit != bool(e["hit"]):
			mismatches += 1
	check(checked >= 35, "events to check (%d)" % checked)
	eq(mismatches, 0, "every hit roll is the combat stream's draw against the event's odds (%d checked)" % checked)
	# the same World with a different landing salt: the same hits and misses (the landing stream is separate), different landing places
	var alt := _rules_with({"odds": {"landing_salt": 99}})
	var w2 := _world(250.0, 21, "tank", false)
	w2.set_line_of_fire(CombatLines.new(grid, alt))
	var ev2 := _fires(_play(w2, 20))
	eq(ev2.size(), ev.size(), "another landing salt: the same number of rolls")
	var same_hits := true
	var moved := 0
	for i in mini(ev.size(), ev2.size()):
		if bool(ev[i]["hit"]) != bool(ev2[i]["hit"]) or absf(float(ev[i]["odds"]) - float(ev2[i]["odds"])) > 1e-12:
			same_hits = false
		if not bool(ev[i]["hit"]) and (absf(float(ev[i].get("mx", 0.0)) - float(ev2[i].get("mx", 0.0))) > 1e-6 or absf(float(ev[i].get("mz", 0.0)) - float(ev2[i].get("mz", 0.0))) > 1e-6):
			moved += 1
	check(same_hits, "... the same hits, the same odds: the landing draws shift no combat dice")
	check(moved > 3, "... and the misses land elsewhere (%d moved)" % moved)

# --- 8. determinism ---------------------------------------------------------------------------------------------

func _determinism() -> void:
	_sections += 1
	var wall_x := BAY.x + 196.0
	var runs: Array[String] = []
	for k in 2:
		grid.stamp("test_wall", [_wall(wall_x, BAY.y, 1.0, 12.0, 1.15)])
		var ev := _play(_world(200.0, 13), TURNS)
		grid.unstamp("test_wall")
		runs.append(JSON.stringify(ev))
	check(runs[0].length() > 2000, "the runs have events (%d bytes)" % runs[0].length())
	eq(runs[0], runs[1], "the same World twice (fresh World, fresh glue, the wall laid in again): the same events, to the byte")
	# and a different seed is a different game
	var ev3 := _play(_world(200.0, 14), TURNS)
	check(JSON.stringify(ev3) != runs[0], "another combat seed gives other events")
