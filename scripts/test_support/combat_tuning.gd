extends SceneTree

# THE TUNING TABLE for the first fight's proposed weapon values (Track C,
# 2026-10-09). NOT a test (the gate does not run test_support); a script that
# plays scripted tail chases many times and prints how long a fighter takes to
# bring a bomber down, and what the bomber's turrets do to it meanwhile.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 --script res://scripts/test_support/combat_tuning.gd
#
# THE SCRIPTED CHASE (best case for the fighter: perfect pursuit): a bomber flies
# straight and level at 85 m/s at its start band's height; the fighter sits
# `gap` m behind it on the same heading and speed in the same band and flies
# straight too -- no orders from either side, so the fighter's cones stay centred
# and the bomber's turrets only have a straight target. Each row is SEEDS runs
# with different rng_seeds, at most MAX_TURNS turns each. A turn is 5 s.
#
# Columns:
#   kill         runs in which the bomber went down within MAX_TURNS turns
#   turns        turns from the first shot's turn to the bomber's down: mean and
#                median, counting a turn as (turn - 1) + t / 5 (so 2.5 is half way
#                through the third turn), among the runs that killed it
#   fighter lost the fighter's pips lost, mean, by the time the bomber was down
#   fighter down runs in which the FIGHTER went down (before or at the same tick
#                as the bomber, or without the bomber going down)
#   first        ... of which it went down first
#
# Variants: with the bomber's guns on (the real exchange) and off (how long the
# fighter needs when nobody shoots back). Gaps: 150 m (close), 300 m (inside
# both ranges), 420 m (outside the tail turret's reach, inside the wing guns').

const World = preload("res://scripts/sim/world.gd")

const SEEDS := 300
const MAX_TURNS := 12

func _initialize() -> void:
	print("Combat tuning table: proposed values only (data/units/*.json weapons, data/sim/combat.json). %d seeds a row, %d turns at most, 5 s a turn." % [SEEDS, MAX_TURNS])
	print("Perfect pursuit: both fly straight at 85 m/s, same band, fighter `gap` m behind the bomber.")
	print("")
	print("%-14s %5s %-10s | %-9s %-12s %-14s | %-13s %-8s" % ["fighter", "gap m", "bomber", "kill", "turns (mean)", "turns (median)", "fighter lost", "f.down"])
	for ftype: String in ["light_fighter", "heavy_fighter"]:
		for gap: float in [150.0, 300.0, 420.0]:
			for fire_back: bool in [false, true]:
				_row(ftype, gap, fire_back)
	print("")
	print("Expected pips a turn on a centred target in the cone the whole turn (rolls x odds x damage):")
	var w := World.new()
	for t: String in ["light_fighter", "heavy_fighter", "bomber"]:
		for wp in w.unit_def(t).weapons:
			var per_turn: float = float(wp.hardpoints.size()) * wp.rolls_per_second * w.rules.turn_seconds * wp.base_hit_chance * float(wp.damage_pips)
			print("  %-14s %-14s %d hardpoint(s) x %s rolls/s x %.2f odds x %d pip(s) = %.2f pips a turn (range %s m)" % [t, wp.id, wp.hardpoints.size(), str(wp.rolls_per_second), wp.base_hit_chance, wp.damage_pips, per_turn, str(wp.range_m)])
	quit()

func _row(ftype: String, gap: float, fire_back: bool) -> void:
	var kill_turns: Array[float] = []
	var fighter_down := 0
	var fighter_first := 0
	var lost_sum := 0.0
	var lost_n := 0
	for s in range(1, SEEDS + 1):
		var w := World.new()
		w.rng_seed = s
		w.quiet = true
		w.add_player("local")
		w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "player", "x": 100.0 + gap, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
		w.add_unit({"id": "fighter", "type": ftype, "side": "allies", "controller": "player", "x": 100.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
		if not fire_back:
			w.unit_def("bomber").weapons.clear()
		var t_bomber := INF
		var t_fighter := INF
		var lost_at_kill := 0
		for n in range(1, MAX_TURNS + 1):
			w.commit("local")
			var res := w.resolve()
			for ev: Dictionary in res["events"]:
				if ev["type"] == "down":
					var at := float(n - 1) + float(ev["t"]) / 5.0
					if ev["unit"] == "bomber" and is_inf(t_bomber):
						t_bomber = at
						lost_at_kill = w.units["fighter"].def.health - w.units["fighter"].health
					elif ev["unit"] == "fighter" and is_inf(t_fighter):
						t_fighter = at
			w.begin_turn()
			if not is_inf(t_bomber) or not is_inf(t_fighter):
				break
		if not is_inf(t_bomber):
			kill_turns.append(t_bomber)
			lost_sum += float(lost_at_kill)
			lost_n += 1
		if not is_inf(t_fighter):
			fighter_down += 1
			if t_fighter <= t_bomber:
				fighter_first += 1
	kill_turns.sort()
	var mean := 0.0
	for k in kill_turns:
		mean += k
	mean = mean / float(kill_turns.size()) if not kill_turns.is_empty() else NAN
	var median: float = kill_turns[kill_turns.size() / 2] if not kill_turns.is_empty() else NAN
	print("%-14s %5d %-10s | %3d%%      %-12s %-14s | %-13s %3d%% (first %d%%)" % [
		ftype, int(gap), "guns on" if fire_back else "guns off",
		roundi(100.0 * float(kill_turns.size()) / float(SEEDS)),
		"%.2f" % mean, "%.2f" % median,
		"%.2f pips" % (lost_sum / float(lost_n) if lost_n > 0 else NAN),
		roundi(100.0 * float(fighter_down) / float(SEEDS)), roundi(100.0 * float(fighter_first) / float(SEEDS))])
