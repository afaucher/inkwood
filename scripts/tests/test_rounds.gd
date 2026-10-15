extends "res://scripts/test_support/test_case.gd"

# THE ROUND MODEL AND THE MATERIALS (builder G3, 2026-10-12; Alex, decisions round-model: 'a round per weapon with class, calibre, explosive, path, tracer
# and blast; a round x material table for impacts; armour and penetration later', damage-looks: everything names a material, weapon-kinds: what a weapon
# fires decides its look, tracers-mg: tracers for machine guns only for now). Every table here is PROPOSED except where its data record names a decision.
# Headless: the data and its readers; the pictures are test_gunfire (records) and scripts/app/g3_shot.gd (pixels).
#
#   1. THE DATA      data/sim/rounds.json loads; every round has a class, calibre, explosive, path, tracer and blast from the vocabulary, with its provenance;
#                    an explosive round's blast points at a table that exists (and is the table it already had); only the bullet draws a tracer
#   2. THE WEAPONS   every weapon of every unit names a known round; the mapping the brief gave (machine guns fire bullets, the nose cannon a small cannon
#                    round, the tank's gun a medium one, flak shells, the Main Guns a shell); one weapon id names one round in every unit that has it
#   3. THE TRACERS   exactly the weapons the old fx.json list named (wing_guns, nose_gun, dorsal_turret, tail_turret, rear_gunner, quad_mg, deck_mg) have a
#                    round with a tracer, and the list is gone from fx.json
#   4. THE MATERIALS every unit names a material of the one vocabulary; the table the brief gave; the line-of-fire grid says the same words
#                    (earth, water, stone, wood) and a stamped box of earth is the sandbags' raised earth
#   5. THE READER    a broken model is refused: an unknown calibre, a non-explosive round with a blast, a special naming a round that is not there

const SimRules = preload("res://scripts/sim/sim_rules.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")
const Rounds = preload("res://scripts/sim/rounds.gd")
const LofRules = preload("res://scripts/sim/line_of_fire_rules.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")

# The weapons that draw a tracer today: the machine guns (decision tracers-mg, the list data/fx/fx.json tracers.weapons held until this model) and, since
# decision tracers-cannons (Alex 2026-10-14), the direct-fire cannons (the nose cannon and the tank's gun).
const OLD_TRACER_LIST := ["wing_guns", "nose_gun", "dorsal_turret", "tail_turret", "rear_gunner", "quad_mg", "deck_mg", "nose_cannon", "turret_gun"]
const TRACER_ROUNDS := ["bullet", "cannon_small", "cannon_medium"]
# What each weapon fires (PROPOSED by the brief and the gunfire board's mapping, variants/gunfire/families.json rounds).
const WEAPON_ROUND := {
	"wing_guns": "bullet", "nose_gun": "bullet", "dorsal_turret": "bullet", "tail_turret": "bullet", "rear_gunner": "bullet", "quad_mg": "bullet", "deck_mg": "bullet",
	"nose_cannon": "cannon_small", "turret_gun": "cannon_medium", "flak": "flak_medium", "light_flak": "flak_small", "ship_flak": "flak_small",
}
# The material of each unit type (PROPOSED: the board's table, variants/gunfire/board.json material_table, in the one vocabulary).
const UNIT_MATERIAL := {
	"light_fighter": "metal", "heavy_fighter": "metal", "bomber": "metal", "tank": "metal", "mobile_aa": "metal", "radio_tower": "metal", "cruiser": "metal",
	"patrol_boat": "metal", "bridge": "stone", "military_complex": "stone", "supply_boat": "wood", "anti_aircraft_battery": "earth",
}

var _ran := {}
var _rm: Rounds = null
var _units: Dictionary = {}   # unit type id -> UnitDef

func setup(_main) -> void:
	_rm = Rounds.new()
	if not check(_rm.ok(), "data/sim/rounds.json loads: %s" % "; ".join(_rm.errors)):
		finish()
		return
	var rules := SimRules.new()
	for file: String in DirAccess.get_files_at(UnitDef.UNITS_DIR):
		if file.ends_with(".json") and not file.begins_with("_"):
			var d := UnitDef.new(UnitDef.path_for(file.get_basename()), rules.band_ids, true)
			if check(d.ok(), "%s loads: %s" % [file, "; ".join(d.errors)]):
				_units[d.id] = d
	_data()
	_weapons()
	_tracers()
	_materials()
	_reader()
	var missing: Array = []
	for k: String in ["data", "weapons", "tracers", "materials", "reader"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	finish()

# --- 1. the data ----------------------------------------------------------------------------------------------------------

func _raw() -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(Rounds.PATH))

func _data() -> void:
	eq(_rm.materials, ["metal", "stone", "wood", "earth", "water"] as Array[String], "1. the ONE vocabulary of what a round hits: metal, stone, wood, earth, water")
	eq(_rm.classes, ["bullet", "cannon_round", "flak_shell", "shell", "bomb"] as Array[String], "1. the five classes of the proposal")
	eq(_rm.calibres, ["small", "medium", "large"] as Array[String], "1. small, medium, large")
	eq(_rm.paths, ["straight", "arc", "air_burst"] as Array[String], "1. a straight line, an arc, a burst in the air")
	var raw := _raw()
	check(str((raw["vocabulary"]["materials"] as Dictionary).get("decision", "")) == "gunfire-looks", "1. the vocabulary of materials names Alex's decision gunfire-looks")
	check(str(raw["_about"]).contains("2 rounds - for now") and str(raw["_about"]).contains("armour and penetration later"), "1. the file quotes Alex's words (round-model: '2 rounds - for now', 'armour and penetration later')")
	eq(_rm.round_ids().size(), 7, "1. seven rounds: bullet, two cannon rounds, two flak shells, a shell, a bomb")
	var classes_seen := {}
	for id: String in _rm.round_ids():
		var r: Rounds.Round = _rm.round_of(id)
		classes_seen[r.round_class] = true
		check(_rm.classes.has(r.round_class) and _rm.calibres.has(r.calibre) and _rm.paths.has(r.path), "1. %s: class %s, calibre %s, path %s are the vocabulary's" % [id, r.round_class, r.calibre, r.path])
		var rec: Dictionary = (raw["rounds"] as Dictionary)[id]
		for k: String in ["class", "calibre", "explosive", "path", "tracer", "blast"]:
			var f: Dictionary = rec[k]
			check(f.has("value") and (f.get("_proposed") == true or str(f.get("decision", "")) != "") and str(f.get("_reason", "")).length() > 20, "1. %s.%s carries its value, its provenance and a reason" % [id, k])
		# the path follows the class
		match r.round_class:
			"bullet", "cannon_round":
				eq(r.path, "straight", "1. %s: a bullet or a cannon round flies straight" % id)
			"flak_shell":
				eq(r.path, "air_burst", "1. %s: flak bursts in the air" % id)
			"shell", "bomb":
				eq(r.path, "arc", "1. %s: a shell or a bomb flies an arc" % id)
		# Alex's weapon-kinds: bullets do not explode, flak shells do
		if r.round_class == "bullet":
			eq(r.explosive, false, "1. %s: machine guns fire bullets 'which don't' explode (decision weapon-kinds)" % id)
		if r.round_class == "flak_shell":
			eq(r.explosive, true, "1. %s: flak is 'shells shot that then explode' (decision weapon-kinds)" % id)
		eq(r.tracer, TRACER_ROUNDS.has(id), "1. %s: a tracer for the bullet and the two cannon rounds only (decisions tracers-mg, tracers-cannons; bombs, shells and flak keep their own marks)" % id)
		if not r.blast.is_empty():
			check(r.explosive, "1. %s: only an explosive round has a blast table" % id)
			check(not _rm.blast_table(id).is_empty(), "1. %s: its blast pointer %s resolves to a table" % [id, str(r.blast)])
	for c: String in _rm.classes:
		check(classes_seen.has(c), "1. the class %s has a round" % c)
	# the blast tables are where they were, not copied: the pointers lead to the very numbers the sim reads
	var shell_table := _rm.blast_table("shell_large")
	var guns := GunRules.new()
	var spec: GunRules.Spec = guns.special("main_guns")
	eq(shell_table.size(), spec.blast_distances.size(), "1. the shell's pointer leads to the Main Guns' table (data/sim/guns.json)")
	for i in shell_table.size():
		near(float((shell_table[i] as Array)[0]), spec.blast_distances[i], 1e-9, "1. ...tier %d's distance" % i)
		near(float((shell_table[i] as Array)[1]), spec.blast_pips[i], 1e-9, "1. ...and its pips")
	var bombs := BombRules.new()
	var bomb_table := _rm.blast_table("bomb")
	eq(bomb_table.size(), bombs.blast_distances.size(), "1. the bomb's pointer leads to the bombs' table (data/sim/bombs.json)")
	for i in bomb_table.size():
		near(float((bomb_table[i] as Array)[0]), bombs.blast_distances[i], 1e-9, "1. ...tier %d's distance" % i)
	for id: String in ["bullet", "cannon_small", "cannon_medium", "flak_small", "flak_medium"]:
		eq(_rm.blast_table(id), [], "1. %s has no blast table (a hit takes the weapon's damage_pips from its target)" % id)
	# the specials that are not in weapons[]
	eq(_rm.special_round("main_guns"), "shell_large", "1. the Main Guns fire the large shell")
	eq(_rm.special_round("bomb"), "bomb", "1. the bomb drop drops the bomb")
	# the size classes of an impact and a muzzle
	eq(_rm.impact_class("bullet"), "bullet", "1. a bullet's impact is its own small mark")
	eq(_rm.impact_class("cannon_medium"), "medium", "1. a medium cannon round's impact is medium")
	eq(_rm.impact_class("shell_large"), "large", "1. a shell's impact is large")
	eq(_rm.muzzle_class("cannon_small"), "small", "1. a small cannon round's muzzle is small")
	eq(_rm.muzzle_class("flak_medium"), "medium", "1. a medium flak shell's muzzle is medium")
	_ran["data"] = true

# --- 2. the weapons -------------------------------------------------------------------------------------------------------

func _weapons() -> void:
	var seen := {}
	for id: String in _units:
		var d: UnitDef = _units[id]
		for w in d.weapons:
			check(w.round_id != "" and _rm.has_round(w.round_id), "2. %s.%s names a round that exists (%s)" % [id, w.id, w.round_id])
			check(not seen.has(w.id) or str(seen[w.id]) == w.round_id, "2. the weapon id %s names one round in every unit that has it" % w.id)
			seen[w.id] = w.round_id
			var raw_w: Dictionary = {}
			for rw: Dictionary in (JSON.parse_string(FileAccess.get_file_as_string(UnitDef.path_for(id))) as Dictionary)["weapons"]:
				if rw["id"] == w.id:
					raw_w = rw["round"]
			check(str(raw_w.get("_reason", "")).length() > 30 and (raw_w.get("_proposed") == true or str(raw_w.get("decision", "")) != ""), "2. %s.%s: the round carries its provenance and a reason" % [id, w.id])
	for wid: String in WEAPON_ROUND:
		eq(str(seen.get(wid, "")), str(WEAPON_ROUND[wid]), "2. %s fires %s" % [wid, WEAPON_ROUND[wid]])
	eq(seen.size(), WEAPON_ROUND.size(), "2. no weapon is unlisted here (a new weapon is a line in this test, with its round)")
	# the index the effects layer asks by weapon id
	for wid: String in WEAPON_ROUND:
		eq(_rm.weapon_round(wid), str(WEAPON_ROUND[wid]), "2. the weapon index says %s fires %s" % [wid, WEAPON_ROUND[wid]])
	eq(_rm.conflicts(), [] as Array[String], "2. no weapon id is given two rounds")
	eq(_rm.weapon_round("no_such_weapon"), "", "2. an unknown weapon fires nothing")
	_ran["weapons"] = true

# --- 3. the tracers -------------------------------------------------------------------------------------------------------

func _tracers() -> void:
	var drawn := _rm.tracer_weapons()
	var want := OLD_TRACER_LIST.duplicate()
	want.sort()
	eq(drawn, want, "3. exactly the machine guns and the two cannons draw tracers (decision tracers-cannons)")
	for wid: String in WEAPON_ROUND:
		eq(_rm.weapon_tracer(wid), OLD_TRACER_LIST.has(wid), "3. %s: tracer %s" % [wid, str(OLD_TRACER_LIST.has(wid))])
	var fxd := FxData.new()
	check(not (fxd.raw["tracers"] as Dictionary).has("weapons"), "3. data/fx/fx.json tracers has no weapon list any more: the round's flag decides")
	_ran["tracers"] = true

# --- 4. the materials -----------------------------------------------------------------------------------------------------

func _materials() -> void:
	for id: String in UNIT_MATERIAL:
		if not check(_units.has(id), "4. unit %s exists" % id):
			continue
		var d: UnitDef = _units[id]
		eq(d.material, str(UNIT_MATERIAL[id]), "4. %s is %s" % [id, UNIT_MATERIAL[id]])
		var rec: Dictionary = (JSON.parse_string(FileAccess.get_file_as_string(UnitDef.path_for(id))) as Dictionary)["material"]
		check(rec.get("_proposed") == true and str(rec.get("_reason", "")).length() > 30, "4. %s: the material is a proposal with its reason" % id)
	for id: String in _units:
		check(UNIT_MATERIAL.has(id), "4. %s is in this test's table (a new unit names its material here)" % id)
		for b: Dictionary in (_units[id] as UnitDef).shape_boxes:
			check(_rm.materials.has(str(b["material"])), "4. %s's box %s is %s, a word of the one vocabulary" % [id, b["part"], b["material"]])
	# the line-of-fire grid says the same words
	var lof := LofRules.new()
	check(lof.ok(), "4. data/sim/line_of_fire.json loads: %s" % "; ".join(lof.errors))
	for name: String in lof.materials:
		check(_rm.materials.has(name), "4. the grid's material %s is in the one vocabulary" % name)
	eq(lof.material_name(LofRules.GROUND), "earth", "4. open ground is earth (it was ground)")
	eq(lof.material_name(LofRules.TIMBER), "wood", "4. a house is wood (it was timber)")
	eq(lof.material_name(LofRules.EARTHWORKS), "earth", "4. the sandbags are earth (they were earthworks)")
	eq(lof.material_name(LofRules.STONE), "stone", "4. walls and the bridge are stone")
	eq(lof.material_name(LofRules.WATER), "water", "4. water is water")
	eq(lof.material_name(LofRules.TREES), "wood", "4. a tree's canopy is wood")
	eq(lof.material_name(6), "metal", "4. a unit box of metal has an id of its own (no cell is metal)")
	eq(lof.house_material, LofRules.TIMBER, "4. the village's houses are the wood cell")
	eq(lof.wall_material, LofRules.STONE, "4. the village's walls are the stone cell")
	eq(lof.stamp_id("earth"), LofRules.EARTHWORKS, "4. a STAMPED box of earth is the raised earth of the sandbags, not open ground (a vehicle stands under it)")
	eq(lof.stamp_id("stone"), LofRules.STONE, "4. a stamped box of stone is stone")
	eq(lof.material_id("earth"), LofRules.GROUND, "4. the first id of earth is open ground")
	_ran["materials"] = true

# --- 5. the reader --------------------------------------------------------------------------------------------------------

func _reader() -> void:
	var good := _raw()
	check(Rounds.new(good, true).ok(), "5. the shipped model passes as a Dictionary")
	var cases: Array = [
		["an unknown calibre", "is not one of", func(d: Dictionary) -> void: ((d["rounds"] as Dictionary)["bullet"] as Dictionary)["calibre"]["value"] = "huge"],
		["an unknown class", "is not one of", func(d: Dictionary) -> void: ((d["rounds"] as Dictionary)["bullet"] as Dictionary)["class"]["value"] = "rocket"],
		["a round with no tracer flag", "missing field 'rounds.bullet.tracer'", func(d: Dictionary) -> void: ((d["rounds"] as Dictionary)["bullet"] as Dictionary).erase("tracer")],
		["a record with no provenance", "says neither where it came from nor why", func(d: Dictionary) -> void: ((d["rounds"] as Dictionary)["bullet"] as Dictionary)["path"] = {"value": "straight"}],
		["a blast on a round that does not explode", "is not explosive and so has no blast table", func(d: Dictionary) -> void: ((d["rounds"] as Dictionary)["bullet"] as Dictionary)["blast"]["value"] = {"file": "data/sim/bombs.json", "path": ["blast_pips_by_distance"]}],
		["a blast that is neither none nor a pointer", "is \"none\" or a pointer", func(d: Dictionary) -> void: ((d["rounds"] as Dictionary)["shell_large"] as Dictionary)["blast"]["value"] = 5],
		["a special naming a round that is not there", "is not one of", func(d: Dictionary) -> void: (d["specials"] as Dictionary)["main_guns"]["value"] = "railgun"],
		["no vocabulary", "missing section 'vocabulary'", func(d: Dictionary) -> void: d.erase("vocabulary")],
	]
	for c: Array in cases:
		var d: Dictionary = good.duplicate(true)
		(c[2] as Callable).call(d)
		var bad := Rounds.new(d, true)
		var all := "; ".join(bad.errors)
		check(not bad.ok(), "5. rejected: %s" % c[0])
		check(all.contains(str(c[1])), "5. rejected for its own reason: %s -- errors were: %s" % [c[0], all])
	# a pointer to a table that is not there answers nothing, not a crash
	var d2: Dictionary = good.duplicate(true)
	((d2["rounds"] as Dictionary)["shell_large"] as Dictionary)["blast"]["value"] = {"file": "data/sim/no_such_file.json", "path": ["x"]}
	eq(Rounds.new(d2, true).blast_table("shell_large"), [], "5. a pointer to a file that is not there gives no table")
	_ran["reader"] = true
