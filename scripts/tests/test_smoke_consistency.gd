extends "res://scripts/test_support/test_case.gd"

# SMOKE, MADE CONSISTENT (builder SMOKE, 2026-10-11; decisions smoke-consistency and impact-by-round-and-target; the audit is
# docs/proposals/smoke-audit.md). Headless: the structure and the numbers; the pixels are a windowed run (scripts/app/smoke_shot.gd, tmp/smoke/).
# Every number tested is PROPOSED data (data/units/*.json damage_smoke, data/fx/fx.json smoke_model and impacts) or the sim's own.
#
#   1. THE DATA      every unit says what it smokes with: a source of at most 8 m and smaller than the unit itself (never sized by size_m), the stone
#                    bridge smokes not at all (a per-unit switch, not a case in code), every unit that smokes climbs at the smoulder's rate of the
#                    ruins and wrecks (a plane's trail too: Alex, 2026-10-12, "Yes to both"), a plume climbs like the burst thrown with it
#   2. THE PUFFS     from a source of 3 m a damaged tank's puffs are at most 0.96 x 3 m in radius (a 40 m bridge's old puffs were 13 m and more), leave
#                    the source behind the centre, climb, and lean further downwind than a puff that does not (the wind picks up with height)
#   3. THE LAYERS    the effects layer's air pass (all smoke) is mounted between the surface units' markers and the aircraft's: over a tank, the
#                    bridge, a boat and their shadows, under every plane; the smoke's own ground shadow stays under the units; fx.json
#                    smoke_model.layer 'under_all' brings the old order back
#   4. THE FEED      through the real effects layer: a damaged tank and a damaged fighter smoke, the bridge hit as hard makes none; the tank's puffs
#                    climb and are small, the fighter's climb at the same rate and are the engine's size (the heavy fighter's and the bomber's source
#                    stay the light fighter's 8 m, Alex "Yes to both")
#   5. WATER         a bomb or a shell that lands in water makes a splash and no flash, smoke, clods or crater; on land it does as it did; out of
#                    sight nothing at all; the switch's 'burst' setting treats water as land

const World = preload("res://scripts/sim/world.gd")
const SimRules = preload("res://scripts/sim/sim_rules.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")
const UnitUI = preload("res://scripts/ui/unit_ui.gd")
const UiStyle = preload("res://scripts/ui/ui_style.gd")
const FxData = preload("res://scripts/fx/fx_data.gd")
const FxField = preload("res://scripts/fx/fx_field.gd")
const CombatWorlds = preload("res://scripts/test_support/combat_worlds.gd")

const PPM := 1.5
const ORIGIN := Vector2(1000.0, 2200.0)
const TANK := "tank_1"
const BRIDGE := "bridge_1"
const FIGHTER := "fighter_1"
const SOURCE_MAX_M := 8.0   # Alex's 'about 8 m at most' (the lead's reading of 'a small source')

# The air, with the wind picking up with height as data/sim/wind.json says (the power law, exponent 0.2 about a 10 m reference, held 2 to 500 m).
class _Air extends RefCounted:
	func at(_game_s: float) -> Vector2:
		return Vector2(3.0, 0.0)
	func height_factor(h: float) -> float:
		return pow(clampf(h, 2.0, 500.0) / 10.0, 0.2)

var _xf := Transform2D(0.0, Vector2(PPM, PPM), 0.0, -ORIGIN * PPM)
var _ran := {}
var _units: Dictionary = {}   # unit type id -> its UnitDef

func setup(_main) -> void:
	timeout_seconds = 120.0
	var rules := SimRules.new()
	for file: String in DirAccess.get_files_at(UnitDef.UNITS_DIR):
		if file.ends_with(".json") and not file.begins_with("_"):
			var d := UnitDef.new(UnitDef.path_for(file.get_basename()), rules.band_ids, true)
			if check(d.ok(), "%s loads: %s" % [file, "; ".join(d.errors)]):
				_units[d.id] = d
	_data()
	_puffs()
	_layers(_world())
	_feed(_world())
	_water()
	var missing: Array = []
	for k: String in ["data", "puffs", "layers", "feed", "water"]:
		if not _ran.has(k):
			missing.append(k)
	check(missing.is_empty(), "every section ran to its end (a runtime error would end one early): missing %s" % str(missing))
	finish()

# --- 1. the data ----------------------------------------------------------------------------------------------------------

func _data() -> void:
	var fxd: FxData = FxData.shared() as FxData
	var ruin_rise := FxData.f(FxData.grp(fxd.ruin_option("R1"), "smolder"), "rise_mps")
	var crash_rise := FxData.f(FxData.grp(FxData.grp(fxd.crash_option("A"), "impact"), "smolder"), "rise_mps")
	check(ruin_rise > 0.0, "1. the ruin's smolder climbs (%s m/s)" % str(ruin_rise))
	near(ruin_rise, crash_rise, 1e-9, "1. the ruin's and the wreck's smolder climb at one rate")
	eq(_units.size() >= 12, true, "1. every unit file was read (%d)" % _units.size())
	for id: String in _units:
		var d: UnitDef = _units[id]
		var ds: Dictionary = d.damage_smoke
		if not check(ds.has("enabled") and ds.has("source_m") and ds.has("source_back_m") and ds.has("rise_mps"), "1. %s says what it smokes with" % id):
			continue
		if id == "bridge":
			eq(bool(ds["enabled"]), false, "1. the bridge does not smoke: a stone bridge does not burn (Alex: 'Right now bridges don't have anything, that is fine.')")
			near(float(ds["source_m"]), 0.0, 1e-9, "1. ...so it has no source")
			continue
		eq(bool(ds["enabled"]), true, "1. %s smokes when damaged" % id)
		var src := float(ds["source_m"])
		check(src > 0.0 and src <= SOURCE_MAX_M + 1e-9, "1. %s: the source is small, at most %s m (%s m)" % [id, str(SOURCE_MAX_M), str(src)])
		check(src < d.size_m, "1. %s: the source (%s m) is smaller than the unit (%s m): its puffs are not sized by its length" % [id, str(src), str(d.size_m)])
		check(absf(float(ds["source_back_m"])) <= d.size_m * 0.5, "1. %s: the source sits on the unit (%s m behind a centre %s m from either end)" % [id, str(ds["source_back_m"]), str(d.size_m * 0.5)])
		# ONE RATE FOR ALL SMOKE (Alex, decision smoke-consistency, 2026-10-12, asked whether planes' trails should rise like ground smoke: "Yes to both")
		near(float(ds["rise_mps"]), ruin_rise, 1e-9, "1. %s climbs at the smoulder's rate of the ruins and wrecks (%s m/s), a plane's trail too" % [id, str(ruin_rise)])
		if d.domain == "air":
			eq(str(((JSON.parse_string(FileAccess.get_file_as_string(UnitDef.path_for(id))) as Dictionary)["damage_smoke"] as Dictionary)["rise_mps"].get("decision", "")), "smoke-consistency", "1. %s: the plane's climb names Alex's decision" % id)
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(UnitDef.path_for(id)))
		var rec: Dictionary = ((raw as Dictionary)["damage_smoke"] as Dictionary)
		for k: String in ["enabled", "source_m", "source_back_m", "rise_mps"]:
			check(str((rec[k] as Dictionary).get("_reason", "")).length() > 20, "1. %s damage_smoke.%s carries its reason" % [id, k])
	# the heavy fighter's and the bomber's trails stay at the light fighter's source (Alex, 2026-10-12: "Yes to both")
	if _units.has("light_fighter") and _units.has("heavy_fighter") and _units.has("bomber"):
		for id: String in ["heavy_fighter", "bomber"]:
			near(float((_units[id] as UnitDef).damage_smoke["source_m"]), float((_units["light_fighter"] as UnitDef).damage_smoke["source_m"]), 1e-9, "1. the %s's trail keeps the light fighter's source size (Alex: 'Yes to both')" % id)
	# a plume climbs like the burst thrown with it (the active options and every other: the data holds the pair)
	for kind: String in ["crash", "bomb", "ruin"]:
		var names: Array = (fxd.raw[kind]["options"] as Dictionary).keys()
		for n: String in names:
			var o: Dictionary = fxd.crash_option(n) if kind == "crash" else (fxd.bomb_option(n) if kind == "bomb" else fxd.ruin_option(n))
			var pairs: Array = []
			if kind == "crash":
				for ph: String in ["midair", "impact"]:
					pairs.append([FxData.grp(FxData.grp(o, ph), "plume"), FxData.grp(FxData.grp(o, ph), "smoke_burst"), "%s %s %s" % [kind, n, ph]])
			else:
				pairs.append([FxData.grp(o, "plume"), FxData.grp(o, "smoke_burst"), "%s %s" % [kind, n]])
			for pr: Array in pairs:
				near(FxData.f(pr[0], "rise_mps"), FxData.f(pr[1], "rise_mps"), 1e-9, "1. %s: the plume climbs like its burst" % pr[2])
	var wtr: Dictionary = fxd.impact_water()
	eq(str(wtr["look"]), "splash", "1. a round that lands in water splashes (fx.json impacts.water)")
	eq(fxd.impact_look(20.0), "splash", "1. 20 m of water: a splash")
	eq(fxd.impact_look(0.0), "burst", "1. no water: the burst")
	eq(fxd.smoke_layer(), "above_surface_units", "1. the smoke is mounted over the surface units (fx.json smoke_model.layer)")
	_ran["data"] = true

# --- 2. the puffs ---------------------------------------------------------------------------------------------------------------

func _puffs() -> void:
	var fxd: FxData = FxData.shared() as FxData
	var tank: Dictionary = (_units["tank"] as UnitDef).damage_smoke
	var src := float(tank["source_m"])
	var rise := float(tank["rise_mps"])
	var back := float(tank["source_back_m"])
	var sampler := func(_t: float) -> Dictionary: return {"x": 0.0, "y": 0.0, "height_m": 0.0, "heading": 0.0}
	var climbing := FxField.new(fxd)
	var level := FxField.new(fxd)
	climbing.world_seed = 7
	level.world_seed = 7
	var air := _Air.new()
	climbing.wind = air
	level.wind = air
	var n_climb := climbing.emit_path("t", sampler, 0.0, 6.0, 0.5, src, back, rise)
	var n_level := level.emit_path("t", sampler, 0.0, 6.0, 0.5, src, back, 0.0)
	check(n_climb > 20 and n_climb == n_level, "2. a damaged tank leaves puffs along its stretch (%d, and %d without the climb)" % [n_climb, n_level])
	var biggest := 0.0
	var mean_x := 0.0
	var mean_drift_climb := 0.0
	var mean_drift_level := 0.0
	var all_rise := true
	for k in climbing.puffs.size():
		var p: Dictionary = climbing.puffs[k]
		var q: Dictionary = level.puffs[k]
		biggest = maxf(biggest, float(p["r_m"]))
		mean_x += (p["pos"] as Vector2).x
		all_rise = all_rise and absf(float(p.get("rise", 0.0)) - rise) < 1e-9 and not q.has("rise")
		var born := float(p["born"])
		mean_drift_climb += ((climbing.puff_state(p, born + 20.0)["pos"] as Vector2) - (p["pos"] as Vector2)).x
		mean_drift_level += ((level.puff_state(q, born + 20.0)["pos"] as Vector2) - (q["pos"] as Vector2)).x
	mean_x /= float(climbing.puffs.size())
	mean_drift_climb /= float(climbing.puffs.size())
	mean_drift_level /= float(level.puffs.size())
	check(biggest <= 0.96 * src + 1e-6, "2. no puff is bigger than 0.96 x the 3 m source (W1's 0.8 radius_frac, a puff's 1.2 spread): %.2f m" % biggest)
	check(biggest < 0.5 * (_units["tank"] as UnitDef).size_m, "2. ...and none as big as half the 6 m tank")
	check(all_rise, "2. every puff of a ground unit's smoke climbs at the unit's rise_mps, and one that does not climb carries no such key")
	near(mean_x, -back, 0.6, "2. the source is %s m behind the centre of a tank heading east (mean puff x)" % str(back))
	check(mean_drift_climb > 1.5 * mean_drift_level, "2. a climbing puff leans further downwind in 20 s than one that does not (%.1f m against %.1f m): the wind picks up with height" % [mean_drift_climb, mean_drift_level])
	var p0: Dictionary = climbing.puffs[0]
	near(float(climbing.puff_state(p0, float(p0["born"]) + 20.0)["h"]), rise * 20.0, 1e-6, "2. the puff is %s m up after 20 s (rise x age)" % str(rise * 20.0))
	# the old size: a 40 m bridge sized by its length
	var old := FxField.new(fxd)
	old.emit_path("b", sampler, 0.0, 2.0, 0.5, 40.0)
	var old_max := 0.0
	for p: Dictionary in old.puffs:
		old_max = maxf(old_max, float(p["r_m"]))
	check(old_max > 10.0 * biggest, "2. (what the bridge used to wear: puffs of up to %.1f m, %.0f times the tank's)" % [old_max, old_max / biggest])
	_ran["puffs"] = true

# --- helpers ---------------------------------------------------------------------------------------------------------------------

func _world() -> World:
	var w := World.new()
	w.rng_seed = 20261009
	w.quiet = true
	w.add_player("local")
	w.add_unit({"id": TANK, "type": "tank", "side": "allies", "controller": "player", "x": 1500.0, "y": 2400.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": BRIDGE, "type": "bridge", "side": "allies", "controller": "ai", "x": 1700.0, "y": 2400.0, "heading": 0.0, "speed": 0.0})
	w.add_unit({"id": FIGHTER, "type": "light_fighter", "side": "allies", "controller": "player", "x": 1300.0, "y": 2300.0, "heading": 0.0, "speed": 85.0, "altitude_band": "low"})
	for id: String in [TANK, BRIDGE, FIGHTER]:
		if not check(w.units.has(id), "the world has %s" % id):
			return w
	return w

# A UnitUI on a world, mounted in a Node2D of its own.
func _ui_on(w: World) -> UnitUI:
	var mount := Node2D.new()
	mount.name = "Mount"
	add_child(mount)
	var ui := UnitUI.new()
	add_child(ui)
	ui.setup(w, _xf, "local", mount, null)
	return ui

func _names(n: Node) -> Array:
	var out: Array = []
	for c: Node in n.get_children():
		out.append(str(c.name))
	return out

# --- 3. the layers -----------------------------------------------------------------------------------------------------------------

func _layers(w: World) -> void:
	var ui := _ui_on(w)
	var ml: Node = ui.marker_layer
	var order := _names(ml)
	var at := func(nm: String) -> int: return order.find(nm)
	check(at.call("Under") >= 0 and at.call("Shadows") > at.call("Under") and at.call("Planes") > at.call("Shadows") and at.call("SmokeSlot") > at.call("Planes") and at.call("Aircraft") > at.call("SmokeSlot") and at.call("Marks") > at.call("Aircraft"),
		"3. the marker layer's order: stand-out, shadows, surface units, THE SMOKE SLOT, aircraft, marks -- %s" % [order])
	var slot: Node = ui.marker_layer.smoke_slot()
	eq(slot.get_parent(), ml, "3. the smoke slot is a child of the marker layer")
	eq(ui.fx.air_node.get_parent(), slot, "3. the effects layer's air pass (all smoke) is in the slot: over the surface units and their shadows, under the aircraft")
	eq(ui.marker_layer.marker(TANK).get_parent().name, &"Planes", "3. the tank's marker is a surface unit's (under the smoke)")
	eq(ui.marker_layer.marker(BRIDGE).get_parent().name, &"Planes", "3. ...and the bridge's")
	eq(ui.marker_layer.marker(FIGHTER).get_parent().name, &"Aircraft", "3. the fighter's marker is an aircraft's (over the smoke: it flies in front of its own trail)")
	var shadows: Node = ml.get_node("Shadows")
	check(shadows.get_index() < slot.get_index(), "3. the units' shadows (one group) are under the smoke")
	eq(ui.fx.shadow_node.get_parent(), ui.fx, "3. the smoke's own ground shadow stays in the effects layer's shadow pass, under the units")
	check(ui.fx.get_index() < ml.get_index(), "3. ...and the effects layer's ground and shadow passes are under the markers")
	eq(ui.fx.top_node.get_parent(), ui.fx_above, "3. the bursts (flash flipbooks) stay over the planes")
	ui.free()
	# the other setting: the old order, under every marker
	var raw: Dictionary = (FxData.shared() as FxData).raw
	var layer_rec: Dictionary = (raw["smoke_model"] as Dictionary)["layer"]
	var saved: Variant = layer_rec["value"]
	layer_rec["value"] = "under_all"
	var ui2 := _ui_on(w)
	eq(ui2.fx.air_node.get_parent(), ui2.fx, "3. smoke_model.layer 'under_all': the air pass stays under every marker, as before")
	ui2.free()
	layer_rec["value"] = saved
	_ran["layers"] = true

# --- 4. the feed -------------------------------------------------------------------------------------------------------------------

func _feed(w: World) -> void:
	w.units[TANK].health = 3        # of 6
	w.units[BRIDGE].health = 7      # of 14: as hurt as the tank, so it is the switch that keeps it from smoking
	w.units[FIGHTER].health = 1     # of 3
	var ui := _ui_on(w)
	var res := CombatWorlds.turn(w)
	if not check(not res.is_empty(), "4. the turn resolves"):
		return
	CombatWorlds.play_out(ui)
	var by_unit := {}
	for p: Dictionary in ui.fx.field.puffs:
		if not by_unit.has(p["unit"]):
			by_unit[p["unit"]] = []
		(by_unit[p["unit"]] as Array).append(p)
	check(not by_unit.has(BRIDGE), "4. the bridge, hurt as hard, leaves no smoke at all (damage_smoke.enabled false)")
	if check(by_unit.has(TANK) and (by_unit[TANK] as Array).size() > 10, "4. the damaged tank smokes (%d puffs)" % ((by_unit[TANK] as Array).size() if by_unit.has(TANK) else 0)) \
			and check(by_unit.has(FIGHTER) and (by_unit[FIGHTER] as Array).size() > 10, "4. the damaged fighter smokes (%d puffs)" % ((by_unit[FIGHTER] as Array).size() if by_unit.has(FIGHTER) else 0)):
		var tank_src := float((_units["tank"] as UnitDef).damage_smoke["source_m"])
		var fighter_src := float((_units["light_fighter"] as UnitDef).damage_smoke["source_m"])
		var tank_max := 0.0
		var fighter_max := 0.0
		var tank_climbs := true
		var fighter_climbs := true
		for p: Dictionary in by_unit[TANK]:
			tank_max = maxf(tank_max, float(p["r_m"]))
			tank_climbs = tank_climbs and float(p.get("rise", 0.0)) > 0.0
		for p: Dictionary in by_unit[FIGHTER]:
			fighter_max = maxf(fighter_max, float(p["r_m"]))
			fighter_climbs = fighter_climbs and absf(float(p.get("rise", 0.0)) - float((_units["light_fighter"] as UnitDef).damage_smoke["rise_mps"])) < 1e-9
		check(tank_max <= 0.96 * tank_src + 1e-6, "4. the tank's puffs are sized by its 3 m source, not its 6 m length (%.2f m at most)" % tank_max)
		check(fighter_max <= 0.96 * fighter_src + 1e-6 and fighter_max > tank_max, "4. the fighter's by its 8 m engine, so they are bigger than the tank's (%.2f m)" % fighter_max)
		check(tank_climbs, "4. the tank's puffs climb")
		check(fighter_climbs, "4. the fighter's trail climbs at its rise_mps, the ground smoke's rate (Alex: planes' trails rise like ground smoke)")
	_ran["feed"] = true
	ui.free()

# --- 5. water ------------------------------------------------------------------------------------------------------------------------

func _bomb(x: float, y: float) -> Dictionary:
	return {"type": "bomb_impact", "unit": FIGHTER, "turn": 1, "t": 2.0, "x": x, "y": y, "blast_m": 45.0, "drop_index": 0, "bomb": 0}

func _shell(x: float, y: float) -> Dictionary:
	return {"type": "shell_impact", "unit": FIGHTER, "turn": 1, "t": 2.0, "x": x, "y": y, "blast_m": 20.0, "step": 0, "shell": 0}

func _counts(ui: UnitUI) -> Dictionary:
	var f = ui.fx.field
	return {"puffs": f.puffs.size(), "bursts": f.bursts.size(), "debris": f.debris.size(), "craters": f.craters.size(), "splashes": f.splashes.size()}

func _water() -> void:
	var w := _world()
	w.set_water(func(x: float, _y: float) -> float: return 12.0 if x > 3000.0 else 0.0)
	var ui := _ui_on(w)
	ui.feed.begin_turn(1)
	var none := _counts(ui)
	eq(none, {"puffs": 0, "bursts": 0, "debris": 0, "craters": 0, "splashes": 0}, "5. a fresh layer has nothing")
	# a bomb on land: the blast, the smoke, the clods and the crater, as always
	ui.feed.on_event(_bomb(1800.0, 2400.0))
	var land := _counts(ui)
	check(int(land["bursts"]) == 1 and int(land["puffs"]) > 5 and int(land["debris"]) > 0 and int(land["craters"]) == 1 and int(land["splashes"]) == 0,
		"5. a bomb on land: a flash, smoke, clods and a crater, no splash (%s)" % [land])
	# a bomb in water: a splash and nothing else
	ui.feed.on_event(_bomb(3200.0, 2400.0))
	var sea := _counts(ui)
	eq(sea, {"puffs": land["puffs"], "bursts": land["bursts"], "debris": land["debris"], "craters": land["craters"], "splashes": 1},
		"5. a bomb in water: no flash, no smoke, no clods, no crater -- one splash")
	var splash: Dictionary = ui.fx.field.splashes[0]
	var wtr: Dictionary = (FxData.shared() as FxData).impact_water()
	near(float(splash["size_m"]), 45.0 * float(wtr["splash_size_frac"]), 1e-9, "5. ...sized by the round's blast (45 m x %s)" % str(wtr["splash_size_frac"]))
	near(float((splash["pos"] as Vector2).x), 3200.0, 1e-9, "5. ...where it landed")
	# a shell likewise, smaller
	ui.feed.on_event(_shell(1900.0, 2450.0))
	var land2 := _counts(ui)
	check(int(land2["craters"]) == 2 and int(land2["puffs"]) > int(sea["puffs"]) and int(land2["splashes"]) == 1, "5. a shell on land: a blast and a crater (%s)" % [land2])
	ui.feed.on_event(_shell(3300.0, 2450.0))
	var sea2 := _counts(ui)
	eq(sea2, {"puffs": land2["puffs"], "bursts": land2["bursts"], "debris": land2["debris"], "craters": land2["craters"], "splashes": 2}, "5. a shell in water: one more splash and nothing else")
	check(float((ui.fx.field.splashes[1] as Dictionary)["size_m"]) < float((ui.fx.field.splashes[0] as Dictionary)["size_m"]), "5. ...a smaller one than the bomb's (a property of the round)")
	# out of sight: nothing at all, not even the crater a late joiner would need (a splash leaves none)
	ui.marker_layer.unit_visible = func(_id: String) -> bool: return false
	ui.feed.on_event(_bomb(3250.0, 2500.0))
	eq(_counts(ui), sea2, "5. a splash out of the player's sight is not drawn, and there is nothing to put back")
	ui.marker_layer.unit_visible = Callable()
	# the other setting of the switch: water is land
	var rec: Dictionary = ((FxData.shared() as FxData).raw["impacts"] as Dictionary)["water"]["look"]
	var saved: Variant = rec["value"]
	rec["value"] = "burst"
	ui.feed.on_event(_bomb(3400.0, 2400.0))
	var burst := _counts(ui)
	check(int(burst["craters"]) == int(sea2["craters"]) + 1 and int(burst["splashes"]) == 2, "5. impacts.water.look 'burst': water takes a crater like land (%s)" % [burst])
	rec["value"] = saved
	ui.free()
	_ran["water"] = true
