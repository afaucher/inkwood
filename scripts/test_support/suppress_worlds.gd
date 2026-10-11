extends RefCounted

# TEST SUPPORT for the second mission, SUPPRESS (Track M2L, 2026-10-11 -- the gate does not run scripts/test_support).
# data/scenarios/suppress.json names two unit types the units track (M2U) makes: `mobile_aa` and `military_complex`
# (data/units/*.json). Until those files exist a test needs STAND-INS, in a test-only place, so the rules, the AI and the
# scenario can be tried without them:
#
#   mobile_aa         the tank's body (a mobile ground unit: the ground rule, the drive) with the battery's two flak weapons
#   military_complex  the radio tower's (a static ground target, 8 pips)
#
# SuppressWorlds.units_dir() is data/units itself once BOTH real files exist (the stand-ins are then never used, so the test
# runs against the real numbers), else a directory under tmp/ (res://tmp/suppress/units, gitignored) holding a copy of every
# unit file and the two stand-ins. SuppressWorlds.new_world() is a World that reads from it. A scenario populates ANY World
# (SandboxScenario.populate), so a test builds the World here and hands it to the scenario.
#
#   var w := SuppressWorlds.new_world()
#   var sc := SandboxScenario.new("suppress", true)
#   sc.populate(w)
#   SuppressWorlds.standin_in_use()            # true while the stand-ins stand in for the units track's files

const World = preload("res://scripts/sim/world.gd")
const SimRules = preload("res://scripts/sim/sim_rules.gd")
const UnitDef = preload("res://scripts/sim/unit_def.gd")

const STANDIN_DIR := "res://tmp/suppress/units"
const REAL_TYPES := ["mobile_aa", "military_complex"]

static func real_units() -> bool:
	for t: String in REAL_TYPES:
		if not FileAccess.file_exists(UnitDef.path_for(t)):
			return false
	return true

static func standin_in_use() -> bool:
	return not real_units()

# The directory the unit files are read from.
static func units_dir() -> String:
	if real_units():
		return UnitDef.UNITS_DIR
	_build_standins()
	return STANDIN_DIR

static func new_world(quiet: bool = true) -> World:
	var w := World.new(SimRules.TURN_PATH, SimRules.ALTITUDE_PATH, units_dir())
	w.quiet = quiet
	return w

static func _read(path: String) -> Dictionary:
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}

static func _write(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  "))
	f.close()

static func _build_standins() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STANDIN_DIR))
	# a copy of every real unit file (the stand-in dir is a complete units directory)
	var dir := DirAccess.open(UnitDef.UNITS_DIR)
	for f: String in dir.get_files():
		if f.ends_with(".json") and not f.begins_with("_"):
			var src := FileAccess.get_file_as_string("%s/%s" % [UnitDef.UNITS_DIR, f])
			var out := FileAccess.open("%s/%s" % [STANDIN_DIR, f], FileAccess.WRITE)
			out.store_string(src)
			out.close()
	var rec := func(v: Variant) -> Dictionary: return {"value": v, "_proposed": true, "_reason": "STAND-IN for the units track's file (scripts/test_support/suppress_worlds.gd), test only"}
	if not FileAccess.file_exists(UnitDef.path_for("mobile_aa")):
		var aa := _read("%s/tank.json" % UnitDef.UNITS_DIR)
		var battery := _read("%s/anti_aircraft_battery.json" % UnitDef.UNITS_DIR)
		aa["id"] = "mobile_aa"
		aa["name"] = "Mobile AA (stand-in)"
		aa["_about"] = "STAND-IN: the tank's body with the battery's flak. Test only; never shipped."
		aa["weapons"] = battery["weapons"]
		aa["health"] = rec.call(4)
		aa["sight_range_m"] = rec.call(600)
		_write("%s/mobile_aa.json" % STANDIN_DIR, aa)
	if not FileAccess.file_exists(UnitDef.path_for("military_complex")):
		var mc := _read("%s/radio_tower.json" % UnitDef.UNITS_DIR)
		mc["id"] = "military_complex"
		mc["name"] = "Military complex (stand-in)"
		mc["_about"] = "STAND-IN: the radio tower's body. Test only; never shipped."
		_write("%s/military_complex.json" % STANDIN_DIR, mc)
