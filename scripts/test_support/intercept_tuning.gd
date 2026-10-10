extends SceneTree

# THE TUNING TABLE for the Intercept scenario's start positions (Track A, 2026-10-10).
# NOT a test (the gate does not run test_support). Plays the scenario headless with
# scripts/test_support/intercept_play.gd -- idle (nobody plans) and the scripted lead-pursuit
# chase -- over many combat seeds and prints how it ends, so the players' start can be
# chosen from numbers (every position in the scenario file is PROPOSED).
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 --script res://scripts/test_support/intercept_tuning.gd -- [seeds=60] [only=<candidate name>]

const InterceptPlay = preload("res://scripts/test_support/intercept_play.gd")

# name -> {unit id -> overrides}. Heading 0 is east; positive is clockwise on screen (so -pi/2 is north).
const CANDIDATES := {
	"as_file": {},
	"west_wide": {
		"light_fighter_1": {"x": 2600.0, "y": 3000.0, "heading": -0.9},
		"heavy_fighter_1": {"x": 2800.0, "y": 3200.0, "heading": -0.9},
	},
	"mid_south": {
		"light_fighter_1": {"x": 3000.0, "y": 3100.0, "heading": -1.4},
		"heavy_fighter_1": {"x": 3200.0, "y": 3300.0, "heading": -1.4},
	},
	"far_south": {
		"light_fighter_1": {"x": 3100.0, "y": 3600.0, "heading": -1.57},
		"heavy_fighter_1": {"x": 3300.0, "y": 3750.0, "heading": -1.57},
	},
	"north_west": {
		"light_fighter_1": {"x": 2000.0, "y": 2200.0, "heading": -0.5},
		"heavy_fighter_1": {"x": 2200.0, "y": 2400.0, "heading": -0.5},
	},
}

func _initialize() -> void:
	var seeds := 60
	var only := ""
	for a: String in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2:
			if kv[0] == "seeds":
				seeds = int(kv[1])
			elif kv[0] == "only":
				only = kv[1]
	print("Intercept tuning: %d seeds a row, at most 18 turns." % seeds)
	print("%-12s | %-26s | %-34s | %-20s" % ["start", "idle", "chase: won / lost / undecided", "chase turns to a win (min mean)"])
	for name: String in CANDIDATES:
		if only != "" and name != only:
			continue
		_row(name, CANDIDATES[name], seeds)
	quit()

func _row(name: String, overrides: Dictionary, seeds: int) -> void:
	var idle := InterceptPlay.new("intercept", 1, overrides)
	if not idle.ok():
		printerr("setup failed: ", idle.errors)
		return
	var r: Dictionary = idle.play("idle", 18)
	var idle_text := "%s turn %d (%s)" % [r["state"], int(r["turn"]), String(r["reason"]).left(24)]
	var won := 0
	var lost := 0
	var open := 0
	var turns: Array[int] = []
	var down_p := 0
	for s in range(1, seeds + 1):
		var g := InterceptPlay.new("intercept", s, overrides)
		var res: Dictionary = g.play("chase", 18)
		match String(res["state"]):
			"won":
				won += 1
				turns.append(int(res["turn"]))
			"lost":
				lost += 1
			_:
				open += 1
		for id: String in g.player_ids():
			if g.world.units[id].down:
				down_p += 1
	var mn := 0
	var mean := 0.0
	if not turns.is_empty():
		mn = turns.min()
		for t in turns:
			mean += float(t)
		mean /= float(turns.size())
	print("%-12s | %-26s | %3d won %3d lost %3d open (%3d%% won)    | min %d, mean %.1f   (player planes down %d)" % [
		name, idle_text, won, lost, open, roundi(100.0 * float(won) / float(seeds)), mn, mean, down_p])
