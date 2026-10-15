extends "res://scripts/test_support/test_case.gd"

# GUNFIRE, G3 LIVE (builder G3, 2026-10-12; Alex, decision gunfire-looks: 'G3 W1 soft puffs'; round-model: a round per weapon; impact-by-round-and-target: 'a
# round hitting water would splash, not explode with smoke'; damage-looks: everything names a material). Headless: the data, the records the feed makes from
# the sim's events and the draw routine run to its end; the pixels are scripts/app/g3_shot.gd (tmp/g3/). Every number read is PROPOSED data (data/fx/fx.json
# gunfire, data/sim/rounds.json) except where its record names Alex's decision.
#
#   1. THE DATA      the G3 values are read from data/fx/fx.json (the class sizes, the recipes, the roles, the puff sets); every material of the one vocabulary
#                    has a look and a recipe; changing a number in the data changes the record (nothing is a literal in the code); the switch turns it all off
#   2. THE MUZZLE    a tank shot makes a muzzle puff sized by its calibre (medium); the nose cannon's is small, the battery's flak medium and light flak small,
#                    the cruiser's ship flak small, a salvo of the Main Guns six large ones 0.2 s apart; a machine gun makes none
#   3. A HIT         a hit that does not destroy makes an impact on the target a moment later, with the TARGET's material (a tank: metal; the bridge: stone), sized
#                    by the round (medium); a hit that destroys makes none (the explosion is its look); a machine gun's hit and a flak burst make none
#   4. A MISS        a miss of a straight round lands beside the target: earth over ground, water over water, and a round in water splashes with NO smoke
#   5. WHAT STAYS    bombs, shells and tracers are as they were; nothing here touches the combat dice
#   6. THE FOG       a muzzle is shown when the shooter is seen; an impact when the shooter or the target is
#   7. DETERMINISM   the same events make the same records; another shot id lands elsewhere
#   8. THE REAL SIM  a duel of two tanks through the real combat: a muzzle for every roll, an impact for every miss and every hit that did not destroy
#   9. THE DRAW      the layer's three passes run to their end with records in them

const World = preload("res://scripts/sim/world.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const FxGunfire = preload("res://scripts/fx/fx_gunfire.gd")
const CombatFeed = preload("res://scripts/ui/combat_feed.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const Rounds = preload("res://scripts/sim/rounds.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")

const SEED := 20261009
const TANK_FWD := 5.2          # the tank's hardpoint 0.4 m ahead of its centre plus the barrel's 4.8 m (data/fx/fx.json gunfire.muzzle.weapons)

class _Markers extends RefCounted:
	var unit_visible: Callable = Callable()
	var height: float = 0.0
	func height_above_ground(_s: Dictionary) -> float:
		return height
	func marker(_id: String) -> Object:
		return null

# A canvas that draws one pass of a layer and says whether the draw ran to its end.
class _Canvas extends Node2D:
	var layer: Node = null
	var kind: String = "air"
	var ended: bool = false
	func _draw() -> void:
		layer.draw_pass(self, kind)
		ended = true

var _ran := {}
var _rm: Rounds = null

func setup(_main) -> void:
	timeout_seconds = 120.0
	_rm = Rounds.shared() as Rounds
	_data()
	_muzzle()
	_hit()
	_miss()
	_stays()
	_fog()
	_determinism()
	_real_sim()
	await _draw_pass()
	var missing: Array = []
	for k: String in ["data", "muzzle", "hit", "miss", "stays", "fog", "determinism", "real", "draw"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	finish()

# --- helpers --------------------------------------------------------------------------------------------------------------------

func _world(water: bool = false, seed_v: int = 7) -> World:
	var w := World.new()
	w.rng_seed = seed_v
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "tank_a", "type": "tank", "side": "allies", "controller": "player", "x": 3000.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "tank_b", "type": "tank", "side": "axis", "controller": "player", "x": 3150.0, "y": 2500.0, "heading": PI, "speed": 0.0})
	w.add_unit({"id": "bridge_1", "type": "bridge", "side": "axis", "controller": "ai", "x": 3300.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "player", "x": 3400.0, "y": 2300.0, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
	w.add_unit({"id": "hf", "type": "heavy_fighter", "side": "allies", "controller": "player", "x": 3200.0, "y": 2300.0, "heading": 0.0, "speed": 100.0, "altitude_band": "medium"})
	w.add_unit({"id": "fighter", "type": "light_fighter", "side": "allies", "controller": "player", "x": 3200.0, "y": 2200.0, "heading": 0.0, "speed": 100.0, "altitude_band": "medium"})
	w.add_unit({"id": "aa1", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 3500.0, "y": 2600.0, "heading": 0.4})
	w.add_unit({"id": "ship1", "type": "cruiser", "side": "allies", "controller": "player", "x": 2000.0, "y": 2900.0, "heading": 0.0, "speed": 0.0})
	if water:
		w.set_water(func(_x: float, _y: float) -> float: return 12.0)
	return w

# A layer (with its own data when asked) and a feed on a world.
func _rig(w: World, data: FxData = null) -> Dictionary:
	var layer := FxLayer.new()
	if data != null:
		layer.data = data
	add_child(layer)
	layer.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	var mk := _Markers.new()
	var feed := CombatFeed.new()
	feed.setup(w, layer, mk, null, UiStyle.shared())
	return {"layer": layer, "feed": feed, "mk": mk, "w": w}

func _fire(unit: String, weapon: String, target: String, hit: bool, x: float, y: float, tx: float, ty: float, tick: int = 8, hz: float = 2.3, theight: float = 0.0, t: float = 2.0) -> Dictionary:
	return {"type": "fire", "turn": 1, "tick": tick, "unit": unit, "weapon": weapon, "hardpoint": 0, "target": target, "t": t, "hit": hit, "odds": 0.1, "r": 0.0,
		"distance": Vector2(x, y).distance_to(Vector2(tx, ty)), "crossing_dps": 0.0, "x": x, "y": y, "height_m": hz, "tx": tx, "ty": ty, "theight_m": theight}

func _hit_ev(by: String, weapon: String, target: String, health: int, t: float = 2.0) -> Dictionary:
	return {"type": "hit", "turn": 1, "unit": target, "by": by, "weapon": weapon, "t": t, "damage": 1, "health": health}

func _records(rig: Dictionary, kind: String) -> Array:
	var out: Array = []
	for r: Dictionary in (rig["layer"] as FxLayer).gunfire.records:
		if str(r["kind"]) == kind:
			out.append(r)
	return out

# The tank's shot at the other tank (150 m east).
func _tank_shot(hit: bool, tick: int = 8) -> Dictionary:
	return _fire("tank_a", "turret_gun", "tank_b", hit, 3000.4, 2500.0, 3150.0, 2500.0, tick)

func _types(parts: Array) -> Array:
	var out: Array = []
	for p: Dictionary in parts:
		if not out.has(str(p["type"])):
			out.append(str(p["type"]))
	return out

# --- 1. the data ----------------------------------------------------------------------------------------------------------------

func _data() -> void:
	var fxd := FxData.new()
	var cfg := FxGunfire.cfg_from_data(fxd)
	if not check(not cfg.is_empty(), "1. data/fx/fx.json has a gunfire section"):
		return
	var raw: Dictionary = (fxd.raw["gunfire"] as Dictionary)
	var g: Dictionary = cfg["game"]
	check(bool(g["enabled"]) and str(g["family"]) == "G3", "1. G3 is live (gunfire.enabled, family G3)")
	for k: String in ["enabled", "family", "classes", "materials", "puffs", "recipes"]:
		eq(str((raw[k] as Dictionary).get("decision", "")), "gunfire-looks", "1. gunfire.%s names Alex's decision gunfire-looks" % k)
	check(str((raw["family"] as Dictionary)["_reason"]).contains("G3 W1 soft puffs") or str((raw["family"] as Dictionary)["_reason"]).contains("G3 · G3 W1 soft puffs"), "1. ...with his words")
	for path: Array in [["muzzle", "round_classes"], ["muzzle", "shown_when"], ["muzzle", "weapons"], ["muzzle", "shell_barrels"], ["impact", "round_classes"], ["impact", "shown_when"], ["impact", "flight_mps"], ["impact", "hit_spread_frac"]]:
		var rec: Dictionary = (raw[path[0]] as Dictionary)[path[1]]
		check(rec.get("_proposed") == true and str(rec.get("_reason", "")).length() > 30, "1. gunfire.%s.%s is a proposal with its reason" % [path[0], path[1]])
	# the sizes
	var gun: Dictionary = (cfg["classes"] as Dictionary)["gun"]
	var rnd: Dictionary = (cfg["classes"] as Dictionary)["round"]
	near(float((gun["small"] as Dictionary)["r_m"]), 1.7, 1e-9, "1. a small gun's flash is 1.7 m")
	near(float((gun["medium"] as Dictionary)["r_m"]), 2.4, 1e-9, "1. a medium gun's is 2.4 m")
	near(float((gun["large"] as Dictionary)["r_m"]), 6.5, 1e-9, "1. a large gun's is 6.5 m")
	near(float((rnd["bullet"] as Dictionary)["r_m"]), 0.7, 1e-9, "1. a bullet's impact is 0.7 m")
	near(float((rnd["medium"] as Dictionary)["r_m"]), 2.8, 1e-9, "1. a medium round's impact is 2.8 m")
	# every material of the one vocabulary has a look, and every look a recipe in the family
	var fam: Dictionary = (cfg["families"] as Dictionary)["G3"]
	for m: String in _rm.materials:
		if check((cfg["materials"] as Dictionary).has(m), "1. the material %s has a row in gunfire.materials" % m):
			var look := str(((cfg["materials"] as Dictionary)[m] as Dictionary)["look"])
			check((fam["impact"] as Dictionary).has(look), "1. ...its look %s has a recipe" % look)
	eq(_types((fam["impact"] as Dictionary)["water"]), ["disc", "rings"], "1. a round in water is a soft disc and rings: NO puffs, no flash, no smoke (Alex: 'a round hitting water would splash, not explode with smoke')")
	for m: String in ["earth", "stone", "metal", "wood"]:
		check(_types((fam["impact"] as Dictionary)[m]).has("puffs"), "1. %s makes dust or a puff" % m)
	# every colour role and every puff set the recipes name exists
	var st := FxStyle.shared() as FxStyle
	var missing: Array[String] = []
	_roles_in(fam, st, missing)
	for set_id: String in (cfg["puffs"] as Dictionary):
		var def: Dictionary = (cfg["puffs"] as Dictionary)[set_id]
		if def.has("ramp"):
			for s in 3:
				for t in 3:
					if not st.has_role("%s.%d.%d" % [def["ramp"], s, t]):
						missing.append("%s.%d.%d" % [def["ramp"], s, t])
		else:
			for r: String in def["roles"]:
				if not st.has_role(r):
					missing.append(r)
	check(missing.is_empty(), "1. every colour role the recipes and the puff sets name is in fx.json roles: %s" % str(missing.slice(0, 6)))
	for part: Dictionary in (fam["muzzle"] as Array):
		if str(part["type"]) == "puffs":
			check((cfg["puffs"] as Dictionary).has(str(part["set"])), "1. the muzzle's puff set %s is defined" % part["set"])
	# the lists name real classes
	for c: String in (g["muzzle"]["round_classes"] as Array) + (g["impact"]["round_classes"] as Array):
		check(_rm.classes.has(c), "1. %s is a class of the round model" % c)
	check(not (g["impact"]["round_classes"] as Array).has("bullet") and not (g["impact"]["round_classes"] as Array).has("flak_shell") \
			and not (g["impact"]["round_classes"] as Array).has("shell") and not (g["impact"]["round_classes"] as Array).has("bomb"), "1. no G3 impact for bullets (T5), flak (F2), shells or bombs (B3): only cannon rounds")
	check(not (g["muzzle"]["round_classes"] as Array).has("bullet") and not (g["muzzle"]["round_classes"] as Array).has("bomb"), "1. no muzzle smoke for machine guns or bombs")
	# NOTHING IS A LITERAL IN THE CODE: change the data and the record follows
	var big := FxData.new()
	((((big.raw["gunfire"] as Dictionary)["classes"] as Dictionary)["value"] as Dictionary)["gun"] as Dictionary)["medium"]["r_m"] = 3.3
	var w := _world()
	var rig := _rig(w, big)
	(rig["feed"] as CombatFeed).on_event(_tank_shot(false))
	var mz := _records(rig, "muzzle")
	if check(mz.size() == 1, "1. the changed data still makes a muzzle"):
		near(float((rig["layer"] as FxLayer).gunfire.class_table(mz[0])["r_m"]), 3.3, 1e-9, "1. ...sized by the changed data (3.3 m): the size is read from fx.json")
	(rig["layer"] as FxLayer).queue_free()
	var off := FxData.new()
	((raw_gun(off))["enabled"] as Dictionary)["value"] = false
	var rig2 := _rig(_world(), off)
	(rig2["feed"] as CombatFeed).on_event(_tank_shot(false))
	eq((rig2["layer"] as FxLayer).gunfire_enabled(), false, "1. gunfire.enabled false turns it off")
	eq((rig2["layer"] as FxLayer).gunfire.records.size(), 0, "1. ...and no record is made")
	(rig2["layer"] as FxLayer).queue_free()
	var nomz := FxData.new()
	(((raw_gun(nomz)["muzzle"] as Dictionary)["round_classes"] as Dictionary))["value"] = []
	var rig3 := _rig(_world(), nomz)
	(rig3["feed"] as CombatFeed).on_event(_tank_shot(false))
	eq(_records(rig3, "muzzle").size(), 0, "1. an empty muzzle.round_classes list: no muzzle (the list is the data's)")
	eq(_records(rig3, "impact").size(), 1, "1. ...and the miss still lands (its own list)")
	(rig3["layer"] as FxLayer).queue_free()
	_ran["data"] = true

func raw_gun(d: FxData) -> Dictionary:
	return d.raw["gunfire"] as Dictionary

func _roles_in(node: Variant, st: FxStyle, missing: Array[String]) -> void:
	if node is Dictionary:
		for k: String in node:
			var v: Variant = node[k]
			if k in ["role", "fill", "edge", "wash_role", "dot_role", "hatch_role"] and v is String and (v as String) != "" and not st.has_role(v):
				missing.append(v)
			_roles_in(v, st, missing)
	elif node is Array:
		for v: Variant in node:
			_roles_in(v, st, missing)

# --- 2. the muzzle ----------------------------------------------------------------------------------------------------------------

func _muzzle() -> void:
	var w := _world()
	var rig := _rig(w)
	var layer: FxLayer = rig["layer"]
	var feed: CombatFeed = rig["feed"]
	# the tank's shot: one puff, sized by the medium calibre of the round it fires
	feed.on_event(_tank_shot(false))
	var mz := _records(rig, "muzzle")
	if not check(mz.size() == 1, "2. a tank shot makes one muzzle (%d)" % mz.size()):
		return
	var rec: Dictionary = mz[0]
	eq(str(rec["cls"]), "medium", "2. ...sized by the calibre of its round (cannon_medium: medium)")
	near(float(layer.gunfire.class_table(rec)["r_m"]), 2.4, 1e-9, "2. ...a flash of 2.4 m, read from the data")
	near(float(rec["t0"]), 2.0, 1e-9, "2. ...at the event's game time (turn 1, 2.0 s)")
	near((rec["centre"] as Vector2).distance_to(Vector2(3000.0, 2500.0)), 0.0, 1e-3, "2. ...from the tank's centre")
	near(float(rec["dir"]), 0.0, 1e-6, "2. ...along its hull (a tank's gun is drawn along it)")
	near(float(rec["fwd_m"]), TANK_FWD, 1e-3, "2. ...at the end of the barrel: %.1f m ahead of the centre (hardpoint 0.4 m + barrel 4.8 m)" % TANK_FWD)
	near(float(rec["lat_m"]), 0.0, 1e-6, "2. ...on the axis")
	# AN ORDERED SHOT (builder ORD, 2026-10-14; decision tank-fire-feedback): the event carries the turret's bearing; the smoke starts at the TIP of the barrel along it
	# (the unit file's turret.barrel_tip_m, 4.8 m), the turret's axis 0.4 m ahead of the hull's centre staying where the hull puts it
	var ordered := _tank_shot(false, 41)
	ordered["bearing"] = PI / 2.0
	ordered["aimed"] = true
	feed.on_event(ordered)
	var mz2 := _records(rig, "muzzle")
	if check(mz2.size() == 2, "2. an ordered shot makes a muzzle too (%d)" % mz2.size()):
		var rec2: Dictionary = mz2[1]
		near(float(rec2["dir"]), PI / 2.0, 1e-6, "2. ...along the turret's bearing, not the hull's")
		near(float(rec2["fwd_m"]), 4.8, 1e-3, "2. ...4.8 m out from the turret's axis along it (the drawn barrel's tip)")
		near(float(rec2["lat_m"]), -0.4, 1e-3, "2. ...the axis itself 0.4 m off the hull's centre sideways of the new bearing")
	check(layer.gunfire.parts_of(rec).size() > 0 and _types(layer.gunfire.parts_of(rec)).has("puffs") and _types(layer.gunfire.parts_of(rec)).has("flash"), "2. ...a flash and W1 puffs (the muzzle recipe)")
	var by_class := {}
	# each weapon with a muzzle, and the ones without
	var cases: Array = [
		["hf", "nose_cannon", "bomber", 3200.0, 2300.0, 3400.0, 2300.0, "small"],
		["aa1", "flak", "bomber", 3500.0, 2600.0, 3400.0, 2300.0, "medium"],
		["aa1", "light_flak", "bomber", 3500.0, 2600.0, 3400.0, 2300.0, "small"],
		["ship1", "ship_flak", "bomber", 2022.0, 2905.0, 3400.0, 2300.0, "small"],
		["fighter", "wing_guns", "bomber", 3200.0, 2197.0, 3400.0, 2300.0, ""],
		["bomber", "tail_turret", "fighter", 3400.0, 2300.0, 3200.0, 2200.0, ""],
		["hf", "rear_gunner", "bomber", 3200.0, 2300.0, 3400.0, 2300.0, ""],
	]
	for c: Array in cases:
		var before := _records(rig, "muzzle").size()
		feed.on_event(_fire(str(c[0]), str(c[1]), str(c[2]), true, float(c[3]), float(c[4]), float(c[5]), float(c[6]), 20 + by_class.size(), 100.0, 400.0))
		by_class[str(c[1])] = true
		var made := _records(rig, "muzzle").size() - before
		if str(c[7]) == "":
			eq(made, 0, "2. %s is a machine gun: no muzzle smoke (its look is the tracer)" % c[1])
		elif check(made == 1, "2. %s makes a muzzle (%d)" % [c[1], made]):
			var r2: Dictionary = _records(rig, "muzzle")[_records(rig, "muzzle").size() - 1]
			eq(str(r2["cls"]), str(c[7]), "2. ...%s, the calibre of the round it fires" % c[7])
	# the nose cannon fires along the nose; a flak gun at its target
	var nc: Dictionary = {}
	var fl: Dictionary = {}
	for r: Dictionary in _records(rig, "muzzle"):
		if str(r["shot"]).contains("/nose_cannon/"):
			nc = r
		if str(r["shot"]).contains("/flak/"):
			fl = r
	near(float(nc.get("dir", 99.0)), 0.0, 1e-6, "2. the nose cannon's muzzle points along the nose (heading 0)")
	near(float(fl.get("dir", 99.0)), (Vector2(3400.0, 2300.0) - Vector2(3500.0, 2600.0)).angle(), 1e-6, "2. a flak gun's points at its target")
	# the Main Guns: a salvo of shells, one muzzle each, from the barrels, 0.2 s apart
	var salvo_before := _records(rig, "muzzle").size()
	feed.on_event({"type": "shell_fire", "turn": 1, "unit": "ship1", "special": "main_guns", "t": 1.0, "x": 2000.0, "y": 2900.0, "step": 0, "target": {"unit": "tank_b"}, "aim": [2800.0, 2900.0], "shells": 6, "range_m": 800.0, "flight_s": 3.0, "impact_t": 4.0})
	var shells := _records(rig, "muzzle").slice(salvo_before)
	if check(shells.size() == 6, "2. a salvo of six shells makes six muzzles (%d)" % shells.size()):
		for k in 6:
			var s: Dictionary = shells[k]
			eq(str(s["cls"]), "large", "2. shell %d: a large muzzle (the shell's calibre)" % k)
			near(float(s["t0"]), 1.0 + 0.2 * float(k), 1e-9, "2. shell %d leaves %.1f s after the salvo starts (the shells' own release time)" % [k, 0.2 * float(k)])
		near(float(layer.gunfire.class_table(shells[0])["r_m"]), 6.5, 1e-9, "2. ...a 6.5 m flash")
		check(absf(float(shells[0]["fwd_m"])) > 40.0, "2. ...from the cruiser's bow turrets, not its centre (%.1f m ahead; the aim is to the east, the ship's heading too)" % float(shells[0]["fwd_m"]))
		# aft: the same salvo aimed behind the ship leaves the after turrets
		var aft_before := _records(rig, "muzzle").size()
		feed.on_event({"type": "shell_fire", "turn": 1, "unit": "ship1", "special": "main_guns", "t": 2.0, "x": 2000.0, "y": 2900.0, "step": 1, "target": {"point": [1200.0, 2900.0]}, "aim": [1200.0, 2900.0], "shells": 2, "range_m": 800.0, "flight_s": 3.0, "impact_t": 5.0})
		var aft := _records(rig, "muzzle").slice(aft_before)
		check(aft.size() == 2 and float((aft[0] as Dictionary)["fwd_m"]) > 30.0, "2. a salvo aimed astern leaves the after turrets (they are 37 to 46 m aft, 'ahead' along the direction of fire: %.1f m)" % (float((aft[0] as Dictionary)["fwd_m"]) if aft.size() > 0 else -1.0))
	layer.queue_free()
	_ran["muzzle"] = true

# --- 3. a hit ---------------------------------------------------------------------------------------------------------------------

func _hit() -> void:
	var w := _world()
	var rig := _rig(w)
	var layer: FxLayer = rig["layer"]
	var feed: CombatFeed = rig["feed"]
	# a hit on a tank that does not destroy it: nothing at the fire event (it is not known yet), a metal impact at the hit event
	feed.on_event(_tank_shot(true))
	eq(_records(rig, "impact").size(), 0, "3. the fire event of a hit makes no impact yet (the hit event says whether it destroyed)")
	feed.on_event(_hit_ev("tank_a", "turret_gun", "tank_b", 3))
	var im := _records(rig, "impact")
	if check(im.size() == 1, "3. a hit that does not destroy makes one impact (%d)" % im.size()):
		var r: Dictionary = im[0]
		eq(str(r["mat"]), "metal", "3. ...with the TARGET's material: a tank is metal")
		eq(str(r["cls"]), "medium", "3. ...sized by the round (cannon_medium: medium)")
		near(float(layer.gunfire.class_table(r)["r_m"]), 2.8, 1e-9, "3. ...2.8 m, read from the data")
		var flight := 149.6 / 700.0
		near(float(r["t0"]), 2.0 + flight, 1e-6, "3. ...a moment after the muzzle, by the round's flight (149.6 m from the muzzle at 700 m/s: %.2f s)" % flight)
		check((r["centre"] as Vector2).distance_to(Vector2(3150.0, 2500.0)) < 1e-3, "3. ...at the target's place")
		check((r["off"] as Vector2).length() <= 0.2 * 6.0 + 1e-6, "3. ...inside its hull: at most %.1f m from the centre (0.2 x the 6 m tank): %.2f m" % [1.2, (r["off"] as Vector2).length()])
		check(not _types(layer.gunfire.parts_of(r)).has("disc") and _types(layer.gunfire.parts_of(r)).has("strokes") and _types(layer.gunfire.parts_of(r)).has("puffs"), "3. ...a metal hit: spark ticks and a dark puff")
	# a hit on the bridge: stone
	feed.on_event(_fire("tank_a", "turret_gun", "bridge_1", true, 3000.4, 2500.0, 3300.0, 2500.0, 9))
	feed.on_event(_hit_ev("tank_a", "turret_gun", "bridge_1", 13))
	var im2 := _records(rig, "impact")
	if check(im2.size() == 2, "3. a hit on the bridge makes an impact too (%d)" % im2.size()):
		eq(str((im2[1] as Dictionary)["mat"]), "stone", "3. ...a STONE one: the bridge is stone")
		check(_types(layer.gunfire.parts_of(im2[1])).has("chips") and _types(layer.gunfire.parts_of(im2[1])).has("puffs"), "3. ...dust and chips (and no damage smoke: the bridge's smoke stays off)")
		check(((im2[1] as Dictionary)["off"] as Vector2).length() <= 0.2 * 40.0 + 1e-6, "3. ...on the deck: within 0.2 x the 40 m bridge")
	# a hit that destroys: no impact
	feed.on_event(_fire("tank_a", "turret_gun", "tank_b", true, 3000.4, 2500.0, 3150.0, 2500.0, 10))
	feed.on_event(_hit_ev("tank_a", "turret_gun", "tank_b", 0))
	eq(_records(rig, "impact").size(), 2, "3. a hit that destroys the target makes no impact: its explosion, ruin or sinking is the look")
	# the nose cannon's hit on a plane: a small metal impact at the plane
	feed.on_event(_fire("hf", "nose_cannon", "bomber", true, 3200.0, 2300.0, 3400.0, 2300.0, 11, 100.0, 400.0))
	feed.on_event(_hit_ev("hf", "nose_cannon", "bomber", 6))
	var im3 := _records(rig, "impact")
	if check(im3.size() == 3, "3. the nose cannon's hit on a plane makes an impact (%d)" % im3.size()):
		eq(str((im3[2] as Dictionary)["mat"]), "metal", "3. ...metal (a plane)")
		eq(str((im3[2] as Dictionary)["cls"]), "small", "3. ...small (cannon_small)")
	# a machine gun's hit and a flak hit: no G3 impact
	var before := _records(rig, "impact").size()
	feed.on_event(_fire("fighter", "wing_guns", "bomber", true, 3200.0, 2197.0, 3400.0, 2300.0, 12, 100.0, 400.0))
	feed.on_event(_hit_ev("fighter", "wing_guns", "bomber", 5))
	feed.on_event(_fire("aa1", "flak", "bomber", true, 3500.0, 2600.0, 3400.0, 2300.0, 13, 6.0, 400.0))
	feed.on_event(_hit_ev("aa1", "flak", "bomber", 4))
	eq(_records(rig, "impact").size(), before, "3. a machine gun's hit (T5) and a flak hit (F2) make no G3 impact")
	# a hit event with no fire event before it is left alone
	feed.on_event(_hit_ev("tank_a", "turret_gun", "tank_b", 2, 4.0))
	eq(_records(rig, "impact").size(), before, "3. a hit event with no fire event before it makes nothing")
	layer.queue_free()
	_ran["hit"] = true

# --- 4. a miss --------------------------------------------------------------------------------------------------------------------

func _miss() -> void:
	# over ground: earth
	var w := _world()
	var rig := _rig(w)
	var layer: FxLayer = rig["layer"]
	var feed: CombatFeed = rig["feed"]
	feed.on_event(_tank_shot(false))
	var im := _records(rig, "impact")
	if not check(im.size() == 1, "4. a miss makes an impact at once (%d)" % im.size()):
		return
	var r: Dictionary = im[0]
	eq(str(r["mat"]), "earth", "4. a miss over ground makes an EARTH impact")
	eq(str(r["cls"]), "medium", "4. ...sized by the round")
	var off: Vector2 = r["off"]
	var dir := Vector2.RIGHT   # the line of fire: tank_a to tank_b, east
	var aside := absf(off.dot(Vector2(0.0, 1.0)))
	var along := off.dot(dir)
	check(aside >= 4.0 - 1e-6 and aside <= 16.0 + 1e-6, "4. ...beside the target by 4 to 16 m (%.2f m)" % aside)
	check(along >= -10.0 - 1e-6 and along <= 30.0 + 1e-6, "4. ...and -10 to +30 m along the line (%.2f m)" % along)
	check(_types(layer.gunfire.parts_of(r)).has("puffs") and not _types(layer.gunfire.parts_of(r)).has("disc"), "4. ...dust, not a splash")
	check(layer.gunfire.parts_of(r).size() > 0, "4. ...with a recipe to draw")
	# the dice are not used: the world's seed and a unit's state are as they were
	eq(w.rng_seed, 7, "4. the combat seed is untouched")
	layer.queue_free()
	# over water: a splash, no smoke
	var wet := _world(true)
	var rig2 := _rig(wet)
	(rig2["feed"] as CombatFeed).on_event(_tank_shot(false))
	var im2 := _records(rig2, "impact")
	if check(im2.size() == 1, "4. a tank's miss over water makes an impact (%d)" % im2.size()):
		var r2: Dictionary = im2[0]
		eq(str(r2["mat"]), "water", "4. ...a WATER one")
		var types := _types((rig2["layer"] as FxLayer).gunfire.parts_of(r2))
		check(not types.has("puffs") and not types.has("flash") and not types.has("chips") and not types.has("strokes"), "4. ...a splash with NO smoke, flash, chips or sparks (parts: %s)" % str(types))
		check(types.has("rings") and types.has("disc"), "4. ...a pale disc and rings")
		near(float((rig2["layer"] as FxLayer).gunfire.size_mult("water")), 1.35, 1e-9, "4. ...a bigger mark than dust from the same round (size_mult 1.35, from the data)")
	(rig2["layer"] as FxLayer).queue_free()
	# water only where it is deep enough (fx.json impacts.water.min_depth_m): a shallow edge is land
	var shallow := _world()
	shallow.set_water(func(_x: float, _y: float) -> float: return 0.2)
	var rig3 := _rig(shallow)
	(rig3["feed"] as CombatFeed).on_event(_tank_shot(false))
	var im3 := _records(rig3, "impact")
	check(im3.size() == 1 and str((im3[0] as Dictionary)["mat"]) == "earth", "4. 0.2 m of water is a wet shore, not water: earth")
	(rig3["layer"] as FxLayer).queue_free()
	# the nose cannon's miss at a plane: the ground under the miss (the data's air_targets setting), or nothing
	var air := _world()
	var rig4 := _rig(air)
	(rig4["feed"] as CombatFeed).on_event(_fire("hf", "nose_cannon", "bomber", false, 3200.0, 2300.0, 3400.0, 2300.0, 14, 100.0, 400.0))
	var im4 := _records(rig4, "impact")
	if check(im4.size() == 1, "4. the nose cannon's miss at a plane makes an impact (ground_below, the brief's rule) (%d)" % im4.size()):
		eq(str((im4[0] as Dictionary)["mat"]), "earth", "4. ...on the ground below the miss")
		eq(str((im4[0] as Dictionary)["cls"]), "small", "4. ...small (cannon_small)")
		check(((im4[0] as Dictionary)["off"] as Vector2).length() >= 0.6 * 20.0 - 1e-6, "4. ...clear of the 20 m bomber (at least 0.6 x its size beside it)")
	(rig4["layer"] as FxLayer).queue_free()
	var none := FxData.new()
	(((((raw_gun(none)["impact"] as Dictionary)["miss"] as Dictionary)["air_targets"]) as Dictionary))["value"] = "none"
	var rig5 := _rig(_world(), none)
	(rig5["feed"] as CombatFeed).on_event(_fire("hf", "nose_cannon", "bomber", false, 3200.0, 2300.0, 3400.0, 2300.0, 14, 100.0, 400.0))
	eq(_records(rig5, "impact").size(), 0, "4. impact.miss.air_targets 'none': a miss at a plane draws no impact")
	(rig5["layer"] as FxLayer).queue_free()
	_ran["miss"] = true

# --- 5. what stays ------------------------------------------------------------------------------------------------------------------

func _stays() -> void:
	var w := _world()
	var rig := _rig(w)
	var layer: FxLayer = rig["layer"]
	var feed: CombatFeed = rig["feed"]
	var craters_before: int = layer.field.craters.size()
	feed.on_event({"type": "bomb_impact", "unit": "bomber", "turn": 1, "t": 2.0, "x": 3100.0, "y": 2400.0, "blast_m": 45.0, "drop_index": 0, "bomb": 0})
	feed.on_event({"type": "shell_impact", "unit": "ship1", "turn": 1, "t": 2.0, "x": 3100.0, "y": 2450.0, "blast_m": 20.0, "step": 0, "shell": 0})
	eq(layer.gunfire.records.size(), 0, "5. a bomb's and a shell's landing make no G3 impact (B3 and the water splash keep them)")
	eq(layer.field.craters.size(), craters_before + 2, "5. ...they still make their craters as before")
	# a machine gun still draws its tracer, a battery's flak its burst
	feed.on_event(_fire("fighter", "wing_guns", "bomber", false, 3200.0, 2197.0, 3400.0, 2300.0, 31, 100.0, 400.0))
	check(layer.field.tracers != null and layer.field.tracers.records.size() == 1, "5. a machine gun's shot still draws its tracer (T5)")
	feed.on_event(_fire("aa1", "flak", "bomber", false, 3500.0, 2600.0, 3400.0, 2300.0, 32, 6.0, 400.0))
	check(layer.field.bursts.size() >= 1, "5. a battery's flak still draws its burst (F2)")
	eq(_records(rig, "muzzle").size(), 1, "5. ...and now a muzzle at the gun (the flak's round is a flak shell)")
	eq(_records(rig, "impact").size(), 0, "5. ...and no impact")
	layer.queue_free()
	_ran["stays"] = true

# --- 6. the fog ---------------------------------------------------------------------------------------------------------------------

func _fog() -> void:
	var w := _world()
	var rig := _rig(w)
	var feed: CombatFeed = rig["feed"]
	var mk: _Markers = rig["mk"]
	mk.unit_visible = func(_id: String) -> bool: return false
	feed.on_event(_tank_shot(false))
	feed.on_event(_tank_shot(true, 9))
	feed.on_event(_hit_ev("tank_a", "turret_gun", "tank_b", 3))
	eq((rig["layer"] as FxLayer).gunfire.records.size(), 0, "6. a shot nobody can see leaves nothing (no muzzle, no impact)")
	mk.unit_visible = func(id: String) -> bool: return id == "tank_b"
	feed.on_event(_tank_shot(false, 10))
	eq(_records(rig, "muzzle").size(), 0, "6. an unseen shooter's muzzle smoke is not drawn (it would give its place away)")
	eq(_records(rig, "impact").size(), 1, "6. ...but its shot landing at a tank you can see is (shown_when either_seen)")
	mk.unit_visible = func(id: String) -> bool: return id == "tank_a"
	feed.on_event(_tank_shot(false, 11))
	eq(_records(rig, "muzzle").size(), 1, "6. a seen shooter's muzzle is drawn")
	(rig["layer"] as FxLayer).queue_free()
	_ran["fog"] = true

# --- 7. determinism -----------------------------------------------------------------------------------------------------------------

func _determinism() -> void:
	var a := _rig(_world())
	var b := _rig(_world())
	for rig: Dictionary in [a, b]:
		(rig["feed"] as CombatFeed).on_event(_tank_shot(false))
		(rig["feed"] as CombatFeed).on_event(_tank_shot(true, 9))
		(rig["feed"] as CombatFeed).on_event(_hit_ev("tank_a", "turret_gun", "tank_b", 3))
	eq((a["layer"] as FxLayer).gunfire.records, (b["layer"] as FxLayer).gunfire.records, "7. two layers fed the same events hold the same records")
	(b["layer"] as FxLayer).queue_free()
	var c := _rig(_world())
	(c["feed"] as CombatFeed).on_event(_tank_shot(false, 77))
	var offs_a: Vector2 = (_records(a, "impact")[0] as Dictionary)["off"]
	var offs_c: Vector2 = (_records(c, "impact")[0] as Dictionary)["off"]
	check(offs_a.distance_to(offs_c) > 0.01, "7. another shot lands elsewhere (%s against %s)" % [str(offs_a), str(offs_c)])
	# a replayed event adds nothing
	var n := (a["layer"] as FxLayer).gunfire.records.size()
	(a["feed"] as CombatFeed).on_event(_tank_shot(false))
	eq((a["layer"] as FxLayer).gunfire.records.size(), n, "7. the same shot seen twice makes one record")
	(a["layer"] as FxLayer).queue_free()
	(c["layer"] as FxLayer).queue_free()
	_ran["determinism"] = true

# --- 8. the real sim ------------------------------------------------------------------------------------------------------------------

func _duel(seed_v: int) -> World:
	var w := World.new()
	w.rng_seed = seed_v
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "tank_a", "type": "tank", "side": "allies", "controller": "player", "x": 3000.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "tank_b", "type": "tank", "side": "axis", "controller": "player", "x": 3120.0, "y": 2500.0, "heading": PI, "speed": 0.0})
	w.units["tank_a"].health = 99
	w.units["tank_b"].health = 99
	return w

# The duel's events over `turns` turns, each tank ordering its gun when it may (builder ORD, 2026-10-14: the gun is an order now, one aimed shot each, then a turn's
# reload). When `feed` is given every turn's events go to it as the turn resolves (the feed samples the World's last history).
func _duel_events(w: World, turns: int, feed: Object = null) -> Array:
	var all: Array = []
	for _i in turns:
		TankWorlds.fire_at_nearest(w)
		w.commit("local")
		var res := w.resolve()
		var evs: Array = res.get("events", [])
		if feed != null:
			feed.call("begin_turn", w.turn)
			for e: Dictionary in evs:
				feed.call("on_event", e)
		all.append_array(evs)
		w.begin_turn()
	return all

func _real_sim() -> void:
	# a seed with both a hit that did not destroy and a miss over eight turns (health 99 each: nothing is destroyed)
	var found := -1
	for s in range(1, 60):
		var hits_s := 0
		var misses_s := 0
		for e: Dictionary in _duel_events(_duel(s), 8):
			if str(e["type"]) == "fire" and str(e["weapon"]) == "turret_gun":
				if bool(e["hit"]):
					hits_s += 1
				else:
					misses_s += 1
		if hits_s >= 2 and misses_s >= 2:
			found = s
			break
	if not check(found > 0, "8. a seed of the duel has hits and misses (found %d)" % found):
		return
	var w2 := _duel(found)
	var rig := _rig(w2)
	var events := _duel_events(w2, 8, rig["feed"] as Object)
	var fires := 0
	var hits := 0
	var misses := 0
	for e: Dictionary in events:
		if str(e["type"]) == "fire" and str(e["weapon"]) == "turret_gun":
			fires += 1
			if bool(e["hit"]):
				hits += 1
			else:
				misses += 1
	eq(_records(rig, "muzzle").size(), fires, "8. the duel: one muzzle for every ordered shot of the tanks' guns (%d)" % fires)
	eq(_records(rig, "impact").size(), hits + misses, "8. ...and one impact for every shot that did not destroy (%d hits, %d misses; nobody went down)" % [hits, misses])
	var metal := 0
	for r: Dictionary in _records(rig, "impact"):
		check(str(r["mat"]) in ["metal", "earth"], "8. an impact on a tank or on the ground, not on anything else (%s)" % str(r["mat"]))
		if str(r["mat"]) == "metal":
			metal += 1
	check(metal >= hits, "8. ...every hit is on metal (%d metal impacts for %d hits)" % [metal, hits])
	(rig["layer"] as FxLayer).queue_free()
	_ran["real"] = true

# --- 9. the draw ------------------------------------------------------------------------------------------------------------------------

func _draw_pass() -> void:
	var w := _world(true)
	var rig := _rig(w)
	var layer: FxLayer = rig["layer"]
	var feed: CombatFeed = rig["feed"]
	feed.on_event(_tank_shot(false))
	feed.on_event(_tank_shot(true, 9))
	feed.on_event(_hit_ev("tank_a", "turret_gun", "tank_b", 3))
	feed.on_event({"type": "shell_fire", "turn": 1, "unit": "ship1", "special": "main_guns", "t": 1.0, "x": 2000.0, "y": 2900.0, "step": 0, "target": {"unit": "tank_b"}, "aim": [2800.0, 2900.0], "shells": 6, "range_m": 800.0, "flight_s": 3.0, "impact_t": 4.0})
	layer.set_time(2.2)
	layer.stats()
	for kind: String in ["ground", "shadows", "air"]:
		var cv := _Canvas.new()
		cv.layer = layer
		cv.kind = kind
		add_child(cv)
		cv.queue_redraw()
		await get_tree().process_frame
		await get_tree().process_frame
		check(cv.ended, "9. the %s pass draws to its end with %d records in the book" % [kind, layer.gunfire.records.size()])
		cv.queue_free()
	check(layer.gunfire.live_count(2.2) > 0, "9. records are live at 2.2 s")
	layer.set_time(500.0)
	eq(layer.gunfire.live_count(500.0), 0, "9. ...and over long after (the scorch lasts 90 s)")
	layer.clear()
	eq(layer.gunfire.records.size(), 0, "9. clear() empties the book")
	layer.queue_free()
	_ran["draw"] = true
