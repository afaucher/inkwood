extends SceneTree

# CALIBRATING THE SPREADS OF THE STRAIGHT ROUNDS (builder LOF2, stage 2 of the lines of fire, 2026-10-12; test support -- the gate does not run
# scripts/test_support). For every weapon in data/sim/line_of_fire.json odds.weapons: the angular spread (milliradians) at which a still, fully
# exposed target of the reference type, at the reference range and elevation, seen from eight sides (every 45 degrees), takes the weapon's old
# base_hit_chance. Prints the table (the spread, and the chance it gives at other ranges) and the values to write into the data.
#
#   $env:INKWOOD_STEAM = "off"
#   godot --headless --fixed-fps 60 --script res://scripts/test_support/lof_calibrate.gd [-- ranges=50,100,200,350]
#
# The maths is scripts/test_support/lof_calibration.gd, which the tests use to hold the data to its reference cases.

const LofCalibration = preload("res://scripts/test_support/lof_calibration.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var ranges := PackedFloat64Array([50.0, 100.0, 150.0, 200.0, 250.0, 350.0])
	for a: String in OS.get_cmdline_user_args():
		if a.begins_with("ranges="):
			ranges = PackedFloat64Array()
			for p in a.substr(7).split(","):
				ranges.append(float(p))
	var cal := LofCalibration.new()
	if not cal.ok():
		printerr("line_of_fire.json: ", cal.rules.errors)
		quit(1)
		return
	var head := "weapon          reference                    ref odds  spread mrad  "
	for r in ranges:
		head += " %5.0f m" % r
	print(head)
	var lines: Array[String] = []
	for wid: String in cal.rules.spreads:
		var spec: Dictionary = cal.rules.spreads[wid]
		var found := cal.find_weapon(wid)
		if found.is_empty():
			printerr("no unit has the weapon ", wid)
			continue
		var sigma := cal.solve(found, spec)
		var row := "%-15s %-13s %4.0f m %+3.0f deg  %5.3f   %9.3f   " % [wid, spec["target"], spec["range_m"], spec["elevation_deg"], spec["odds"], sigma]
		for r in ranges:
			var sp: Dictionary = spec.duplicate()
			sp["range_m"] = r
			row += "%7.3f " % cal.reference_p(found, sp, sigma)
		print(row)
		lines.append("%s: spread_mrad %s (old base %s, in data %s)" % [wid, String.num(sigma, 4), str(found["weapon"].base_hit_chance), str(spec["spread_mrad"])])
	for l in lines:
		print(l)
	quit(0)
