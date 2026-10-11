extends SceneTree

# THE WATER SURVEY (Track WB, 2026-10-10): what the water generator does on many seeds, headless.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 `
#       --script res://scripts/world/water_survey.gd -- 1..20 [20261009] [json=tmp/water_survey.json]
#
# One line per seed (and a JSON file of the same records): the sea edges and whether the FIRST choice was already
# dry (no adapting), what adapting did, whether every layout site stayed dry in the end, the river (made,
# length, where it ends, the crossing's half width), and the share of the map that is water.

const Terrain = preload("res://scripts/world/terrain.gd")
const WaterGen = preload("res://scripts/world/water_gen.gd")

func _initialize() -> void:
	var seeds: Array[int] = []
	var json_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("json="):
			json_path = a.substr(5)
		elif ".." in a:
			var p := a.split("..")
			for s in range(int(p[0]), int(p[1]) + 1):
				seeds.append(s)
		else:
			seeds.append(int(a))
	if seeds.is_empty():
		for s in range(1, 21):
			seeds.append(s)
		seeds.append(20261009)
	var recs: Array = []
	var first_dry := 0
	var final_dry := 0
	var river_made := 0
	var river_ends_sea := 0
	for sd in seeds:
		var terrain := Terrain.new(sd)
		var w := WaterGen.new(sd, terrain)
		var sea: Dictionary = w.diagnostics.get("sea", {})
		var riv: Dictionary = w.diagnostics.get("river", {})
		var wet := w.wet_fraction(100.0)
		var rec := {"seed": sd, "ok": w.ok(), "errors": w.errors, "sea_edges": sea.get("edges", []), "sea_edges_wanted": sea.get("edges_wanted", 0),
			"dry_first_try": sea.get("dry_first_try", false), "adapt_steps": sea.get("adapt_steps", 0), "reach_scale": sea.get("reach_scale", 1.0),
			"dropped_edges": sea.get("dropped", []), "keep_dry_ok": w.diagnostics.get("keep_dry_ok", false),
			"river_made": riv.get("made", false), "river_why": riv.get("why", ""), "river_length_m": riv.get("length_m", 0.0),
			"river_ends_in": riv.get("ends_in", ""), "crossing_hw_m": riv.get("half_width_at_crossing_m", 0.0),
			"water_share": snappedf(float(wet["water"]), 0.001), "shallows": snappedf(float(wet["shallows"]), 0.001),
			"shelf": snappedf(float(wet["shelf"]), 0.001), "deep": snappedf(float(wet["deep"]), 0.001), "build_ms": snappedf(float(w.diagnostics.get("build_ms", 0.0)), 1.0)}
		recs.append(rec)
		if rec["dry_first_try"]:
			first_dry += 1
		if rec["keep_dry_ok"] and rec["ok"]:
			final_dry += 1
		if rec["river_made"]:
			river_made += 1
			if rec["river_ends_in"] == "sea":
				river_ends_sea += 1
		print("[water-survey] seed %d: sea edges %s%s (first try %s, %d adapt steps, reach x%s) | river %s | water %d%% (shallows %.1f, shelf %.1f, deep %.1f) | all sites dry %s | %d ms" % [
			sd, str(rec["sea_edges"]), (" dropped " + str(rec["dropped_edges"])) if not (rec["dropped_edges"] as Array).is_empty() else "",
			"DRY" if rec["dry_first_try"] else "wet", rec["adapt_steps"], str(rec["reach_scale"]),
			("%.0f m, ends in %s, %.0f m wide at the road" % [rec["river_length_m"], rec["river_ends_in"], 2.0 * float(rec["crossing_hw_m"])]) if rec["river_made"] else ("none (" + str(rec["river_why"]) + ")"),
			roundi(100.0 * float(rec["water_share"])), 100.0 * float(rec["shallows"]), 100.0 * float(rec["shelf"]), 100.0 * float(rec["deep"]),
			"yes" if rec["keep_dry_ok"] else "NO", int(rec["build_ms"])])
	print("[water-survey] %d seeds: the first choice of sea was already dry on %d; every layout site dry in the end on %d; a river that crosses the road on %d (%d of them end in the sea)" % [
		seeds.size(), first_dry, final_dry, river_made, river_ends_sea])
	if json_path != "":
		if json_path.is_relative_path():
			json_path = ProjectSettings.globalize_path("res://").path_join(json_path)
		DirAccess.make_dir_recursive_absolute(json_path.get_base_dir())
		var f := FileAccess.open(json_path, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify({"seeds": recs, "first_dry": first_dry, "final_dry": final_dry, "river_made": river_made, "of": seeds.size()}, "  ", false))
			f.close()
	quit(0)
