extends SceneTree

# THE TUNING TABLE for the first fight's proposed weapon values (Track C,
# 2026-10-09, extended 2026-10-10 for the crossing-rate factor). NOT a test (the
# gate does not run test_support); a script that plays scripted engagements many
# times and prints how long a fighter takes to bring a bomber down, and what the
# bomber's turrets do to it meanwhile.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 --script res://scripts/test_support/combat_tuning.gd
#
# A. THE SCRIPTED CHASE (best case for the fighter: perfect pursuit): a bomber flies
# straight and level at 85 m/s at its start band's height; the fighter sits `gap` m
# behind it on the same heading and speed in the same band and flies straight too --
# no orders from either side, so the fighter's cones stay centred, nothing crosses
# and the bomber's turrets only have a straight target. Each row is SEEDS runs with
# different rng_seeds, at most MAX_TURNS turns each. A turn is 5 s.
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
# fighter needs when nobody shoots back). Gaps (centre to centre; the tail turret
# sits 10.5 m behind the bomber's centre): 150 m (close), 300 m (inside both
# effective ranges), 420 m (just over the tail turret's 400 m effective range: it
# still fires, at 96 percent of its odds), 470 m (inside the tail turret's 480 m
# reach at about a third of its odds, over the wing guns' 450 m effective range),
# 500 m (past the tail turret's reach; the wing guns, effective 450 m, reach 540 m
# and fire at about 40 percent of their odds). Range overshoot 0.2 (data/sim/combat.json).
#
# B. THE WEAVING CHASE: the same chase, but the bomber S-turns (a gentle 0.2 rad a
# step, alternating) and the fighter steers each of its steps at the point 300 m
# behind where the bomber will be at the step's end. Now the line of sight turns,
# so the crossing-rate factor bites; run with the factor on (the shipped data) and
# off (odds_factors without it) to see how far it moves the close chase.
#
# C. A PASS, one turn each, both planes with 1000 pips so nobody drops out: a
# CROSSING pass (the fighter east at 100 m/s, the bomber 400 m ahead and 127 m south
# flying north at 85 m/s) and a HEAD-ON pass (the fighter east at 100 m/s, the bomber
# 1000 m ahead and 40 m south flying west at 85 m/s). Per pass: the pips each side
# dealt (mean over SEEDS), and the fighter's mean odds per roll.

const World = preload("res://scripts/sim/world.gd")
const Combat = preload("res://scripts/sim/combat.gd")

const SEEDS := 300
const MAX_TURNS := 12

func _initialize() -> void:
	print("Combat tuning table: proposed values only (data/units/*.json weapons, data/sim/combat.json). %d seeds a row, %d turns at most, 5 s a turn." % [SEEDS, MAX_TURNS])
	var w0 := World.new()
	print("Odds factors in the data: %s; range overshoot %s; crossing exponent %s." % [str(w0.combat.odds_factors), str(w0.combat.range_overshoot), str(w0.combat.crossing_exponent)])
	print("")
	print("A. Perfect pursuit: both fly straight at 85 m/s, same band, fighter `gap` m behind the bomber.")
	print("%-14s %5s %-10s | %-9s %-12s %-14s | %-13s %-8s" % ["fighter", "gap m", "bomber", "kill", "turns (mean)", "turns (median)", "fighter lost", "f.down"])
	for ftype: String in ["light_fighter", "heavy_fighter"]:
		for gap: float in [150.0, 300.0, 420.0, 470.0, 500.0]:
			for fire_back: bool in [false, true]:
				_row(ftype, gap, fire_back, 0.0, true)
	print("")
	print("B. Weaving bomber, fighter in lead pursuit 300 m behind, guns on; the crossing-rate factor off, then on.")
	print("%-14s %5s %-10s | %-9s %-12s %-14s | %-13s %-8s" % ["fighter", "gap m", "factor", "kill", "turns (mean)", "turns (median)", "fighter lost", "f.down"])
	for amp: float in [0.2, 0.29]:
		print("  bomber S-turns of %s rad a step%s" % [str(amp), " (the most a bomber turns in a step at cruise)" if amp > 0.25 else ""])
		for ftype: String in ["light_fighter", "heavy_fighter"]:
			for factor_on: bool in [false, true]:
				_row(ftype, 300.0, true, amp, factor_on)
	print("")
	print("C. One pass, both sides at 1000 pips: pips dealt per pass, and the fighter's mean odds per roll.")
	print("%-14s %-9s %-10s | %-14s %-14s | %-12s %-8s" % ["fighter", "pass", "factor", "fighter dealt", "bomber dealt", "f.odds/roll", "f.rolls"])
	for ftype: String in ["light_fighter", "heavy_fighter"]:
		for kind: String in ["crossing", "head-on"]:
			for factor_on: bool in [false, true]:
				_pass_row(ftype, kind, factor_on)
	print("")
	print("Expected pips a turn on a centred, non-crossing target in the cone the whole turn (rolls x odds x damage):")
	var w := World.new()
	for t: String in ["light_fighter", "heavy_fighter", "bomber"]:
		for wp in w.unit_def(t).weapons:
			var per_turn: float = float(wp.hardpoints.size()) * wp.rolls_per_second * w.rules.turn_seconds * wp.base_hit_chance * float(wp.damage_pips)
			print("  %-14s %-14s %d hardpoint(s) x %s rolls/s x %.2f odds x %d pip(s) = %.2f pips a turn (effective range %s m, reach %s m, tracking %s deg/s)" % [t, wp.id, wp.hardpoints.size(), str(wp.rolls_per_second), wp.base_hit_chance, wp.damage_pips, per_turn, str(wp.effective_range_m), str(wp.max_range_m(w.combat.range_overshoot)), str(wp.tracking_dps)])
	quit()

func _world(seed_value: int, factor_on: bool) -> World:
	var w := World.new()
	w.rng_seed = seed_value
	w.quiet = true
	w.add_player("local")
	if not factor_on:
		var without: Array[String] = []
		for f in w.combat.odds_factors:
			if f != "crossing_rate":
				without.append(f)
		w.combat.odds_factors = without
	return w

# The bomber S-turns; the fighter steers each of its steps at the point `gap` behind
# where the bomber will be when that step ends (the bomber's plan, as sampled).
func _plan_weave(w: World, turn_no: int, gap: float, amplitude: float) -> void:
	for k in w.steps_per_turn("bomber"):
		w.plan_step("bomber", k, {"turn": amplitude if (k + turn_no) % 2 == 0 else -amplitude})
	for k in w.steps_per_turn("fighter"):
		var t: float = w.step_dt("fighter") * float(k + 1)
		var b: Dictionary = w.sample("bomber", t, "plan")
		var aim := Vector2(float(b["x"]) - gap * cos(float(b["heading"])), float(b["y"]) - gap * sin(float(b["heading"])))
		w.plan_step("fighter", k, aim)

func _row(ftype: String, gap: float, fire_back: bool, weave: float, factor_on: bool) -> void:
	var kill_turns: Array[float] = []
	var fighter_down := 0
	var fighter_first := 0
	var lost_sum := 0.0
	var cf_f := 0.0
	var cf_fn := 0
	var cf_b := 0.0
	var cf_bn := 0
	var lost_n := 0
	for s in range(1, SEEDS + 1):
		var w := _world(s, factor_on)
		w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "player", "x": 100.0 + gap, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
		w.add_unit({"id": "fighter", "type": ftype, "side": "allies", "controller": "player", "x": 100.0, "y": 2500.0, "heading": 0.0, "speed": 85.0, "altitude_band": "medium"})
		if not fire_back:
			w.unit_def("bomber").weapons.clear()
		var t_bomber := INF
		var t_fighter := INF
		var lost_at_kill := 0
		for n in range(1, MAX_TURNS + 1):
			if weave > 0.0:
				_plan_weave(w, n, gap, weave)
			w.commit("local")
			var res := w.resolve()
			for ev: Dictionary in res["events"]:
				if weave > 0.0 and ev["type"] == "fire":
					var cf := Combat.crossing_factor(_weapon(w, str(ev["unit"]), str(ev["weapon"])), float(ev["crossing_dps"]), w.combat.crossing_exponent)
					if ev["unit"] == "fighter":
						cf_f += cf
						cf_fn += 1
					else:
						cf_b += cf
						cf_bn += 1
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
	var label := ("guns on" if fire_back else "guns off") if weave <= 0.0 else ("on" if factor_on else "off")
	print("%-14s %5d %-10s | %3d%%      %-12s %-14s | %-13s %3d%% (first %d%%)" % [
		ftype, int(gap), label,
		roundi(100.0 * float(kill_turns.size()) / float(SEEDS)),
		"%.2f" % mean, "%.2f" % median,
		"%.2f pips" % (lost_sum / float(lost_n) if lost_n > 0 else NAN),
		roundi(100.0 * float(fighter_down) / float(SEEDS)), roundi(100.0 * float(fighter_first) / float(SEEDS))]
		+ ("" if weave <= 0.0 else "   | mean crossing factor of the rolls: fighter %.3f, bomber %.3f" % [cf_f / maxf(float(cf_fn), 1.0), cf_b / maxf(float(cf_bn), 1.0)]))

func _pass_row(ftype: String, kind: String, factor_on: bool) -> void:
	var dealt_f := 0.0
	var dealt_b := 0.0
	var odds_sum := 0.0
	var rolls := 0
	for s in range(1, SEEDS + 1):
		var w := _world(s, factor_on)
		if kind == "crossing":
			var tc := 1.5 if ftype == "light_fighter" else 2.0
			w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "player", "x": 1000.0 + 100.0 * tc + 250.0, "y": 2500.0 + 85.0 * tc, "heading": -PI * 0.5, "speed": 85.0, "altitude_band": "medium"})
		else:
			w.add_unit({"id": "bomber", "type": "bomber", "side": "axis", "controller": "player", "x": 2000.0, "y": 2540.0, "heading": PI, "speed": 85.0, "altitude_band": "medium"})
		w.add_unit({"id": "fighter", "type": ftype, "side": "allies", "controller": "player", "x": 1000.0, "y": 2500.0, "heading": 0.0, "speed": 100.0, "altitude_band": "medium"})
		w.units["bomber"].health = 1000
		w.units["fighter"].health = 1000
		w.commit("local")
		var res := w.resolve()
		for ev: Dictionary in res["events"]:
			if ev["type"] == "hit":
				if ev["by"] == "fighter":
					dealt_f += float(ev["damage"])
				else:
					dealt_b += float(ev["damage"])
			elif ev["type"] == "fire" and ev["unit"] == "fighter":
				odds_sum += float(ev["odds"])
				rolls += 1
	print("%-14s %-9s %-10s | %-14s %-14s | %-12s %-8s" % [
		ftype, kind, "on" if factor_on else "off",
		"%.2f pips" % (dealt_f / float(SEEDS)), "%.2f pips" % (dealt_b / float(SEEDS)),
		"%.3f" % (odds_sum / float(rolls) if rolls > 0 else NAN), "%.1f" % (float(rolls) / float(SEEDS))])

# The weapon record a fire event names (unit id "fighter" or "bomber", weapon id).
func _weapon(w: World, unit_id: String, weapon_id: String) -> Object:
	for wp in (w.units[unit_id] as Object).def.weapons:
		if wp.id == weapon_id:
			return wp
	return null
