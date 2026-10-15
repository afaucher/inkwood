extends "res://scripts/test_support/test_case.gd"

# THE SPLASH (builder BS, board splash = backlog B13, 2026-10-14; data/fx/fx.json `splash`). ALEX: "Water splashes are far too big and the style is inconsistent." and
# (decision soft-puffs-default) "Generally I like the look of the soft puffs as a default impact style". Headless: the structure and the numbers; the pixels are a windowed
# run (scripts/fx/fx_board_splash.gd, variants/splash/). Every number tested is PROPOSED data.
#
#   1. THE DATA     the section holds S1..S4, each with a size for every round tag and a recipe of known parts whose roles, puff sets and tags exist; the default
#                   mode is S0 (nothing changes until Alex picks); sizes grow from the bullet to the bomb and from S1 to S2
#   2. S0           today's looks, unchanged: a bomb, a shell and a unit going under are ink rings in the field, a tank round in water is G3's disc and rings, and the
#                   soft book stays empty
#   3. THE OPTIONS  in S1..S4 each of those three is a record of the soft book (the old field and the G3 water impact stay empty), tagged by its round and sized by it at
#                   the map's scale; a unit going under is sized by the unit; S3 adds the wash on the ground, S4 a column for bombs and shells only
#   4. THE FEED     the real CombatFeed names the round (bomb, shell_large) and the sinking splash event makes a "unit" record, in every option
#   5. THE SWITCH   an unknown mode reads as S0; the layer's mode follows fx.json; the scale key picks the map's or the markers'

const World = preload("res://scripts/sim/world.gd")
const FxLayer = preload("res://scripts/fx/fx_layer.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxStyle = preload("res://scripts/fx/fx_style.gd")
const CombatFeed = preload("res://scripts/ui/combat_feed.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")

const SEED := 20261009
const TAGS := ["bullet", "cannon_small", "cannon_medium", "shell_large", "bomb"]
const PART_TYPES := ["puffs", "disc", "rings"]
const OPTIONS := ["S1", "S2", "S3", "S4", "S5"]

class _Markers extends RefCounted:
	var unit_visible: Callable = Callable()
	func height_above_ground(_s: Dictionary) -> float:
		return 0.0
	func marker(_id: String) -> Object:
		return null

var _ran := {}

func setup(_main) -> void:
	timeout_seconds = 120.0
	_data()
	_s0()
	_options()
	_feed()
	_switch()
	var missing: Array = []
	for k: String in ["data", "s0", "options", "feed", "switch"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	finish()

# --- helpers --------------------------------------------------------------------------------------------------------------------

func _world(water: bool = true) -> World:
	var w := World.new()
	w.rng_seed = 7
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": "tank_a", "type": "tank", "side": "allies", "controller": "player", "x": 3000.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": "tank_b", "type": "tank", "side": "axis", "controller": "player", "x": 3150.0, "y": 2500.0, "heading": PI, "speed": 0.0})
	w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "player", "x": 3400.0, "y": 2300.0, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
	w.add_unit({"id": "patrol", "type": "patrol_boat", "side": "allies", "controller": "player", "x": 3200.0, "y": 2600.0, "heading": 0.0, "speed": 0.0})
	if water:
		w.set_water(func(_x: float, _y: float) -> float: return 12.0)
	return w

func _rig(w: World) -> Dictionary:
	var layer := FxLayer.new()
	add_child(layer)
	layer.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	var feed := CombatFeed.new()
	feed.setup(w, layer, _Markers.new(), null, UiStyle.shared())
	return {"layer": layer, "feed": feed, "w": w}

func _bare() -> FxLayer:
	var layer := FxLayer.new()
	add_child(layer)
	layer.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	return layer

func _tank_miss() -> Dictionary:
	return {"type": "fire", "turn": 1, "tick": 8, "unit": "tank_a", "weapon": "turret_gun", "hardpoint": 0, "target": "tank_b", "t": 2.0, "hit": false, "odds": 0.1, "r": 0.0,
		"distance": 150.0, "crossing_dps": 0.0, "x": 3000.4, "y": 2500.0, "height_m": 2.3, "tx": 3150.0, "ty": 2500.0, "theight_m": 0.0}

# The G3 impacts of a layer (its muzzles are not counted).
func _g3_impacts(layer: FxLayer) -> int:
	var n := 0
	for r: Dictionary in layer.gunfire.records:
		if str(r["kind"]) == "impact":
			n += 1
	return n

func _soft(layer: FxLayer) -> Array:
	return layer.splash_book.records

func _types(parts: Array) -> Array:
	var out: Array = []
	for p: Dictionary in parts:
		if not out.has(str(p["type"])):
			out.append(str(p["type"]))
	return out

# --- 1. the data ----------------------------------------------------------------------------------------------------------------

func _data() -> void:
	var fxd := FxData.new()
	var sec := fxd.splash_section()
	if not check(not sec.is_empty(), "1. data/fx/fx.json has a splash section"):
		return
	var raw: Dictionary = fxd.raw["splash"]
	eq(str(sec["mode"]), "S0", "1. the working default is S0, today's looks: nothing changes until Alex picks")
	eq(fxd.splash_mode(), "S0", "1. ...as FxData reads it")
	for k: String in ["mode", "scale", "max_records", "bomb_blast_min_m", "tag_class", "gunfire_tag", "puffs"]:
		var rec: Dictionary = raw[k]
		check(rec.get("_proposed") == true and str(rec.get("_reason", "")).length() > 30, "1. splash.%s is a proposal with its reason" % k)
	var style: FxStyle = FxStyle.shared() as FxStyle
	var puffs: Dictionary = sec["puffs"]
	var opts: Dictionary = sec["options"]
	eq((opts.keys() as Array), OPTIONS, "1. the options are S1..S5")
	for id: String in OPTIONS:
		var o: Dictionary = opts[id]
		var raw_o: Dictionary = (raw["options"] as Dictionary)[id]
		for k: String in ["sizes", "recipe"]:
			check((raw_o[k] as Dictionary).get("_proposed") == true and str((raw_o[k] as Dictionary).get("_reason", "")).length() > 30, "1. %s.%s is a proposal with its reason" % [id, k])
		check(str(o.get("label", "")) != "" and str(o.get("description", "")) != "", "1. %s has a label and a description" % id)
		var sizes: Dictionary = o["sizes"]
		var last := 0.0
		for tag: String in TAGS:
			if check(sizes.has(tag) and float((sizes[tag] as Dictionary).get("r_m", 0.0)) > 0.0 and float((sizes[tag] as Dictionary).get("min_px", 0.0)) > 0.0, "1. %s sizes the round %s" % [id, tag]):
				var r := float((sizes[tag] as Dictionary)["r_m"])
				check(r > last, "1. %s: a bigger round, a bigger splash (%s %.2f m after %.2f m)" % [id, tag, r, last])
				last = r
		check(sizes.has("unit") and float((sizes["unit"] as Dictionary)["frac"]) > 0.0 and float((sizes["unit"] as Dictionary)["max_m"]) > 0.0, "1. %s sizes a unit going under" % id)
		var recipe: Array = o["recipe"]
		check(not recipe.is_empty(), "1. %s has a recipe" % id)
		for p: Dictionary in recipe:
			check(PART_TYPES.has(str(p["type"])), "1. %s: the part '%s' is one the painter draws, in soft puffs, discs and pale rings: no ink strokes" % [id, p["type"]])
			if str(p["type"]) == "puffs":
				check(puffs.has(str(p["set"])), "1. %s: the puff set %s exists" % [id, p["set"]])
			for rk: String in ["fill", "role"]:
				if p.has(rk) and str(p[rk]) != "":
					check(style.has_role(str(p[rk])), "1. %s: the role %s exists" % [id, p[rk]])
					check(not str(p[rk]).begins_with("ink"), "1. %s: the role %s is not ink" % [id, p[rk]])
	for s in 3:
		for t in 3:
			check(style.has_role("splash.spray.%d.%d" % [s, t]), "1. the spray ramp has its role %d.%d" % [s, t])
	for tag: String in TAGS:
		check(float(((opts["S1"] as Dictionary)["sizes"] as Dictionary)[tag]["r_m"]) < float(((opts["S2"] as Dictionary)["sizes"] as Dictionary)[tag]["r_m"]), "1. S1 is smaller than S2 for %s" % tag)
	eq(_types((opts["S2"] as Dictionary)["recipe"]), ["puffs"], "1. S2 is spray puffs and nothing else")
	check(_types((opts["S3"] as Dictionary)["recipe"]).has("disc") and _types((opts["S3"] as Dictionary)["recipe"]).has("rings"), "1. S3 adds a wash and a pale ring")
	var column := 0
	for p: Dictionary in (opts["S4"] as Dictionary)["recipe"]:
		if p.has("tags"):
			column += 1
			eq(p["tags"], ["shell_large", "bomb"], "1. S4's column is for bombs and shells only")
	eq(column, 1, "1. S4 has one column part")
	_ran["data"] = true

# --- 2. S0 ----------------------------------------------------------------------------------------------------------------------

func _s0() -> void:
	var layer := _bare()
	eq(layer.splash_mode(), "S0", "2. the layer starts in S0")
	check(not layer.splash_soft(), "2. ...and the soft grammar is off")
	layer.water_impact(Vector2(3200.0, 2400.0), 1.0, 45.0, "bomber", "bomb")
	layer.water_impact(Vector2(3300.0, 2400.0), 1.0, 20.0, "tank_a", "shell_large")
	layer.splash("patrol", Vector2(3200.0, 2600.0), 1.0, 27.0)
	eq(layer.field.splashes.size(), 3, "2. a bomb, a shell and a unit going under are the old ink rings")
	eq(layer.splash_book.records.size(), 0, "2. ...and the soft book is empty")
	near(float((layer.field.splashes[0] as Dictionary)["size_m"]), 45.0 * 0.35, 1e-9, "2. ...the bomb's sized as before (0.35 x its blast)")
	check(layer.gunfire_impact("m/land", "medium", "water", Vector2(3100.0, 2500.0), 1.0), "2. a tank round in water is G3's impact")
	eq(layer.gunfire.records.size(), 1, "2. ...in the gunfire book, as before")
	eq(layer.splash_book.records.size(), 0, "2. ...and not in the soft book")
	layer.queue_free()
	_ran["s0"] = true

# --- 3. the options -------------------------------------------------------------------------------------------------------------

func _options() -> void:
	var fxd := FxData.shared() as FxData
	var opts: Dictionary = fxd.splash_section()["options"]
	var sizes_seen := {}
	for id: String in OPTIONS:
		var layer := _bare()
		layer.set_splash_mode(id)
		eq(layer.splash_mode(), id, "3. %s: the layer takes the mode" % id)
		check(layer.splash_soft(), "3. %s: the soft grammar is on" % id)
		layer.water_impact(Vector2(3200.0, 2400.0), 1.0, 45.0, "bomber", "bomb")
		layer.water_impact(Vector2(3300.0, 2400.0), 1.0, 20.0, "tank_a", "shell_large")
		layer.splash("patrol", Vector2(3200.0, 2600.0), 1.0, 27.0)
		check(layer.gunfire_impact("m/land", "medium", "water", Vector2(3100.0, 2500.0), 1.0), "3. %s: a tank round in water is taken" % id)
		check(layer.gunfire_impact("b/land", "bullet", "water", Vector2(3100.0, 2510.0), 1.0, 0.0, 0.0, Vector2(2.0, 0.0)), "3. %s: so is a bullet" % id)
		eq(layer.field.splashes.size(), 0, "3. %s: no ink ring in the field" % id)
		eq(_g3_impacts(layer), 0, "3. %s: no G3 water impact: one grammar" % id)
		var recs := _soft(layer)
		if not check(recs.size() == 5, "3. %s: five soft splashes (%d)" % [id, recs.size()]):
			layer.queue_free()
			continue
		var by: Dictionary = {}
		for r: Dictionary in recs:
			by[str(r["tag"])] = r
			eq(str(r["mat"]), "water", "3. %s: a water record" % id)
		for tag: String in ["bomb", "shell_large", "unit", "cannon_medium", "bullet"]:
			check(by.has(tag), "3. %s: a splash tagged %s" % [id, tag])
		var sz: Dictionary = (opts[id] as Dictionary)["sizes"]
		near(float((by["bomb"] as Dictionary)["r_m"]), float((sz["bomb"] as Dictionary)["r_m"]), 1e-9, "3. %s: the bomb's size is the table's" % id)
		near(float((by["unit"] as Dictionary)["r_m"]), minf(27.0 * float((sz["unit"] as Dictionary)["frac"]), float((sz["unit"] as Dictionary)["max_m"])), 1e-9, "3. %s: a 27 m cutter going under is sized by the cutter" % id)
		check(float((by["bomb"] as Dictionary)["r_m"]) > float((by["shell_large"] as Dictionary)["r_m"]) and float((by["shell_large"] as Dictionary)["r_m"]) > float((by["cannon_medium"] as Dictionary)["r_m"]) \
			and float((by["cannon_medium"] as Dictionary)["r_m"]) > float((by["bullet"] as Dictionary)["r_m"]), "3. %s: bomb > shell > tank round > bullet" % id)
		var bomb_end := layer.splash_book.end_of(by["bomb"]) - 1.0
		var bullet_end := layer.splash_book.end_of(by["bullet"]) - 1.0
		check(bomb_end > bullet_end and bomb_end < 6.0, "3. %s: a bomb's splash lasts longer than a bullet's and still under 6 s (%.1f s, %.1f s)" % [id, bomb_end, bullet_end])
		# the miss offset of a G3 impact lands where the feed's water test put it
		near((by["bullet"]["centre"] as Vector2).x, 3100.0 + 2.0 * layer.true_scale, 1e-9, "3. %s: a miss offset is applied once, in the units' metres" % id)
		# parts per tag: S3's wash for all, S4's column for bombs and shells only
		var n_bomb := layer.splash_book.parts_of(by["bomb"]).size()
		var types_bomb := _types(layer.splash_book.parts_of(by["bomb"]))
		match id:
			"S1", "S2", "S5":
				eq(types_bomb, ["puffs"], "3. %s: puffs only" % id)
			"S3":
				check(types_bomb.has("disc") and types_bomb.has("rings") and types_bomb.has("puffs"), "3. S3: the wash, the pale ring and the puffs")
			"S4":
				var col_bomb := 0
				var col_cannon := 0
				for p: Dictionary in layer.splash_book.parts_of(by["bomb"]):
					if p.has("tags") and (p["tags"] as Array).has("bomb"):
						col_bomb += 1
				for p: Dictionary in layer.splash_book.parts_of(by["cannon_medium"]):
					if p.has("tags") and (p["tags"] as Array).has("cannon_medium"):
						col_cannon += 1
				eq([col_bomb, col_cannon, n_bomb], [1, 0, 3], "3. S4: the column part is a bomb's and a shell's (a tank round's recipe has it filtered by its tag)")
				check(layer.splash_book.end_of(by["bomb"]) > layer.splash_book.end_of(by["cannon_medium"]), "3. S4: the column lasts")
		# nothing in the soft book draws as ink: every colour it names is a role off the flash step
		for p: Dictionary in layer.splash_book.parts_of(by["bomb"]):
			for rk: String in ["fill", "role"]:
				if p.has(rk):
					check(str(p[rk]).begins_with("splash."), "3. %s: %s is a splash role, no ink" % [id, p[rk]])
		# a unit's splash goes with its hull (the markers' scale); at S5 everything is at the markers' scale already, so no record is scaled twice
		eq(bool((by["unit"] as Dictionary).get("marker", false)), id != "S5", "3. %s: the unit's splash is marker-scaled by its own flag except where the whole option is (S5)" % id)
		eq(bool((by["bomb"] as Dictionary).get("marker", false)), false, "3. %s: a round's is not flagged" % id)
		layer.true_scale = 2.5
		eq(layer.splash_draw_scale(), 2.5 if id == "S5" else 1.0, "3. %s: drawn at the %s scale" % [id, "markers'" if id == "S5" else "map's"])
		sizes_seen[id] = float((by["bomb"] as Dictionary)["r_m"])
		layer.queue_free()
	check(float(sizes_seen["S1"]) < float(sizes_seen["S2"]) and is_equal_approx(float(sizes_seen["S2"]), float(sizes_seen["S3"])) and is_equal_approx(float(sizes_seen["S2"]), float(sizes_seen["S5"])), "3. S1 is smaller than S2; S3, S4 and S5 keep S2's sizes")
	# the map's scale, not the markers': the painter is handed 1.0 whatever true_scale is
	var layer2 := _bare()
	layer2.true_scale = 2.7
	eq(layer2.splash_draw_scale(), 1.0, "3. the splash is drawn at the map's scale (true_scale is the markers')")
	layer2.queue_free()
	_ran["options"] = true

# --- 4. the feed ----------------------------------------------------------------------------------------------------------------

func _bomb(x: float, y: float) -> Dictionary:
	return {"type": "bomb_impact", "unit": "bomber", "turn": 1, "t": 2.0, "x": x, "y": y, "blast_m": 45.0, "drop_index": 0, "bomb": 0}

func _shell(x: float, y: float) -> Dictionary:
	return {"type": "shell_impact", "unit": "bomber", "turn": 1, "t": 2.0, "x": x, "y": y, "blast_m": 20.0, "step": 0, "shell": 0}

func _feed() -> void:
	for id: String in ["S0"] + OPTIONS:
		var rig := _rig(_world())
		var layer: FxLayer = rig["layer"]
		layer.set_splash_mode(id)
		var feed: CombatFeed = rig["feed"]
		feed.on_event(_bomb(3200.0, 2400.0))
		feed.on_event(_shell(3300.0, 2450.0))
		feed.on_event({"type": "splash", "unit": "patrol", "turn": 1, "t": 1.0, "x": 3200.0, "y": 2600.0})
		feed.on_event(_tank_miss())
		if id == "S0":
			eq([layer.field.splashes.size(), layer.splash_book.records.size(), _g3_impacts(layer)], [3, 0, 1], "4. S0: the feed makes three ink splashes and a G3 water impact")
		else:
			var tags: Array = []
			for r: Dictionary in _soft(layer):
				tags.append(str(r["tag"]))
			tags.sort()
			eq(tags, ["bomb", "cannon_medium", "shell_large", "unit"], "4. %s: the feed names the round of each: %s" % [id, str(tags)])
			eq([layer.field.splashes.size(), _g3_impacts(layer)], [0, 0], "4. %s: nothing else is made" % id)
		# on land the same rounds do as they did: no splash of any kind
		var land := _rig(_world(false))
		var llayer: FxLayer = land["layer"]
		llayer.set_splash_mode(id)
		(land["feed"] as CombatFeed).on_event(_bomb(3200.0, 2400.0))
		(land["feed"] as CombatFeed).on_event(_tank_miss())
		eq([llayer.field.splashes.size(), llayer.splash_book.records.size()], [0, 0], "4. %s: a bomb and a tank round on land make no splash" % id)
		check(llayer.field.craters.size() == 1 and _g3_impacts(llayer) == 1, "4. %s: ...a crater and a dust impact instead" % id)
		layer.queue_free()
		llayer.queue_free()
	_ran["feed"] = true

# --- 5. the switch --------------------------------------------------------------------------------------------------------------

func _switch() -> void:
	var layer := _bare()
	layer.set_splash_mode("S9")
	eq(layer.splash_mode(), "S0", "5. an unknown mode reads as S0")
	layer.set_splash_mode("S3")
	eq(layer.splash_mode(), "S3", "5. S3 takes")
	layer.set_splash_mode("S0")
	check(not layer.splash_soft(), "5. and back to S0 turns the soft grammar off")
	var fxd := FxData.new()
	var rec: Dictionary = (fxd.raw["splash"] as Dictionary)["mode"]
	var saved: Variant = rec["value"]
	rec["value"] = "S2"
	eq(fxd.splash_mode(), "S2", "5. fx.json splash.mode is the switch")
	rec["value"] = "nonsense"
	eq(fxd.splash_mode(), "S0", "5. ...and a name it does not know is S0")
	rec["value"] = saved
	var fake := FxData.new()
	(fake.raw["splash"] as Dictionary)["mode"]["value"] = "S4"
	var layer3 := FxLayer.new()
	layer3.data = fake
	add_child(layer3)
	layer3.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	eq(layer3.splash_mode(), "S4", "5. a layer on data whose mode is S4 starts in S4")
	var fake2 := FxData.new()
	((fake2.raw["splash"] as Dictionary)["scale"] as Dictionary)["value"] = "marker"
	var layer4 := FxLayer.new()
	layer4.data = fake2
	add_child(layer4)
	layer4.setup(Transform2D(0.0, Vector2(2, 2), 0.0, Vector2.ZERO), SEED)
	layer4.true_scale = 2.5
	eq(layer4.splash_draw_scale(), 2.5, "5. scale 'marker' draws at the units' scale")
	layer.queue_free()
	layer3.queue_free()
	layer4.queue_free()
	_ran["switch"] = true
