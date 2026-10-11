extends SceneTree

# THE TUNING TABLE for the main guns' proposed numbers (Track SH, the warship, 2026-10-10). NOT a test (the gate does not run
# test_support); it plays salvos at a stationary battery many times with the game's own dice and blast table and prints what a salvo
# does by the RANGE, how long the target has been SPOTTED (the ranging in), the salvos already fired at it (the bracketing) and how
# close the nearest spotter is:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 --script res://scripts/test_support/gun_tuning.gd
#
# Columns: sigma = one shell's scatter (m); "kills" = the share of salvos whose shells take the battery's 4 pips (data/units/
# anti_aircraft_battery.json) down; "pips" = the mean pips a salvo takes off it (uncapped); "friend 30 m" = the mean pips a salvo does
# to a friendly unit standing 30 m from the target (the cost of firing near your own); "any hit" = the share of salvos where at least
# one shell does the battery a pip. Alex (bridge-mission): 'shots need to be really on point to hit' at the far end of ship range:
# the edge of the range (3,000 m) with a fresh target is the gamble this table shows, a ranged and bracketed one is not.

const Guns = preload("res://scripts/sim/guns.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")

const SEEDS := 400
const BATTERY_PIPS := 4

func _initialize() -> void:
	var rules := GunRules.new()
	if not rules.ok():
		printerr("[gun-tuning] guns.json: ", rules.errors)
		quit(1)
		return
	var spec: GunRules.Spec = rules.special("main_guns")
	print("[gun-tuning] main_guns: %d shells, blast %s, ranging %.0f s (x%.2f), bracket x%.2f per salvo (floor %.2f), spotter far x%.2f, reload %d turns" % [
		spec.shells, str(spec.blast_distances) + str(spec.blast_pips), spec.ranging_s, spec.ranged_factor, spec.bracket_factor, spec.bracket_floor, spec.spotter_far_factor, spec.reload_turns])
	print("")
	print("%-8s %-9s %-8s %-8s | %-7s %-7s %-7s %-12s %-8s" % ["range m", "spotted s", "salvos", "spotter", "sigma", "kills", "pips", "friend 30 m", "any hit"])
	for range_m: float in [600.0, 1200.0, 2000.0, 3000.0]:
		for cfg: Array in [[0.0, 0, 0.4], [10.0, 0, 0.4], [20.0, 0, 0.4], [20.0, 1, 0.4], [20.0, 2, 0.4], [20.0, 2, 1.0]]:
			_row(spec, range_m, float(cfg[0]), int(cfg[1]), float(cfg[2]))
		print("")
	# The same at the edge of the range with the BOMBS' blast table (data/sim/bombs.json: 3 pips within 12 m, 2 within 25, 1 within 45)
	# instead of the shell's own: the alternative the lead's brief names ('Damage uses the bombs' blast table').
	var bombs := BombRules.new()
	var alt: GunRules.Spec = rules.special("main_guns")
	alt.blast_distances = bombs.blast_distances
	alt.blast_pips = bombs.blast_pips
	print("[gun-tuning] WITH THE BOMBS' BLAST TABLE %s%s:" % [str(alt.blast_distances), str(alt.blast_pips)])
	for range_m: float in [1200.0, 3000.0]:
		for cfg: Array in [[0.0, 0, 0.4], [20.0, 0, 0.4], [20.0, 2, 0.4]]:
			_row(alt, range_m, float(cfg[0]), int(cfg[1]), float(cfg[2]))
		print("")
	quit(0)

func _row(spec: GunRules.Spec, range_m: float, spotted_s: float, salvos: int, spotter_ratio: float) -> void:
	var sigma := Guns.sigma_m(range_m, spotted_s, spec, salvos, spotter_ratio)
	var aim := Vector2(2000.0, 2500.0)
	var friend := aim + Vector2(30.0, 0.0)
	var kills := 0
	var any := 0
	var pips_total := 0.0
	var friend_total := 0.0
	for s in range(1, SEEDS + 1):
		var shells := Guns.make_salvo({"unit": "cruiser", "special": "main_guns", "step": 0, "t": 1.0, "from": aim - Vector2(range_m, 0.0), "aim": aim,
			"range_m": range_m, "flight_s": Guns.flight_time(range_m, spec), "sigma_m": sigma}, spec, s, 1, 0)
		var pips := 0
		var fpips := 0
		for sh: Dictionary in shells:
			var at := Vector2(float(sh["x"]), float(sh["y"]))
			pips += spec.blast_damage(at.distance_to(aim))
			fpips += spec.blast_damage(at.distance_to(friend))
		pips_total += float(pips)
		friend_total += float(fpips)
		if pips >= BATTERY_PIPS:
			kills += 1
		if pips > 0:
			any += 1
	print("%-8d %-9d %-8d %-8.1f | %-7.1f %-7s %-7.2f %-12.2f %-8s" % [roundi(range_m), roundi(spotted_s), salvos, spotter_ratio, sigma,
		"%d%%" % roundi(100.0 * float(kills) / float(SEEDS)), pips_total / float(SEEDS), friend_total / float(SEEDS), "%d%%" % roundi(100.0 * float(any) / float(SEEDS))])
