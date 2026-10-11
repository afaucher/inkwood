extends SceneTree

# THE TUNING TABLE for the bridge's durability (Track CA, combat answers, 2026-10-11). NOT a test (the gate does not run
# test_support); it plays the game's own combat and dice at a bridge of any health and prints what it takes to bring one down:
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 --script res://scripts/test_support/bridge_tuning.gd
#
# ALEX (decision bridge-durability, 2026-10-11): tank guns CAN damage a bridge, 'it should take a lot. Like you would have to sit
# there and shell it for awhile exposing yourself.' The lead's PROPOSED target: about 15 to 20 turns of one tank firing steadily.
#
# T. ONE TANK'S TURRET GUN, stationary at several distances from the bridge's middle, the real World and the real combat (the
#    bridge has 1000 pips so it never goes down; the cumulative pips it has lost are read off each turn, so every bridge health
#    in HEALTHS is answered from the same runs): the pips a turn, and the turns it takes to drop a bridge of each health
#    (median, and the 10th and 90th percentile of the seeds).
# S. THE CRUISER'S SALVO at the bridge's middle (the shell's blast table, data/sim/guns.json): the pips one salvo does, by how well
#    the guns are ranged in, and the share of salvos that take a bridge of each health down in ONE salvo.
# B. THE BOMBER'S STICK at the bridge's middle (data/sim/bombs.json): the same for one stick of the load (a stick is
#    per_drop bombs), by height and by how close the release is to ideal, and the sticks it takes.

const World = preload("res://scripts/sim/world.gd")
const TankWorlds = preload("res://scripts/test_support/tank_worlds.gd")
const Guns = preload("res://scripts/sim/guns.gd")
const GunRules = preload("res://scripts/sim/gun_rules.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")

const HEALTHS := [8, 10, 12, 14, 16, 18, 20, 24, 30]
const TANK_SEEDS := 120
const TANK_TURNS := 80
const SEEDS := 400

func _initialize() -> void:
	var w0 := World.new()
	var spec: GunRules.Spec = GunRules.new().special("main_guns")
	print("[bridge-tuning] bridge now: %d pips. Tank gun %s. Shell blast %s%s. Bomb blast %s%s." % [
		w0.unit_def("bridge").health, "1 pip a hit",
		str(spec.blast_distances), str(spec.blast_pips), str(w0.bombs.blast_distances), str(w0.bombs.blast_pips)])
	print("")
	_tank_table()
	print("")
	_shell_table(spec)
	print("")
	_bomb_table(w0)
	quit(0)

# --- T. one tank ------------------------------------------------------------------------------

func _tank_table() -> void:
	print("T. ONE TANK's gun on the bridge's middle (%d seeds, %d turns each): mean pips a turn, then the turns to drop a bridge of each health: median [p10 .. p90]" % [TANK_SEEDS, TANK_TURNS])
	var b := TankWorlds.bridge_site()["pos"] as Vector2
	var head := "%-18s %-9s" % ["tank at", "pips/turn"]
	for h: int in HEALTHS:
		head += " %-16s" % ("%d pips" % h)
	print(head)
	for off: Vector2 in [Vector2(60.0, 20.0), Vector2(120.0, 40.0), Vector2(200.0, 60.0), Vector2(300.0, 100.0), Vector2(340.0, 0.0)]:
		var runs: Array = []
		var refused := false
		for sd in range(1, TANK_SEEDS + 1):
			var w := TankWorlds.world("axis", true)
			w.rng_seed = sd
			(w.units["bridge_1"] as Object).health = 100000
			var at := b + off
			if TankWorlds.tank(w, "gun", "allies", "player", at, 0.0, 0.0) == "":
				refused = true
				break
			var pips := 0
			var cum: Array[int] = []
			for _t in TANK_TURNS:
				var res := TankWorlds.turn(w)
				for ev: Dictionary in res["events"]:
					if str(ev["type"]) == "hit" and str(ev["unit"]) == "bridge_1":
						pips += int(ev["damage"])
				cum.append(pips)
			runs.append(cum)
		if refused:
			print("%-18s (the tank would not stand there)" % ("(%d, %d) m" % [roundi(off.x), roundi(off.y)]))
			continue
		var total := 0.0
		for cum: Array in runs:
			total += float(cum[TANK_TURNS - 1]) / float(TANK_TURNS)
		var line := "%-18s %-9.2f" % ["%.0f m away" % off.length(), total / float(runs.size())]
		for h: int in HEALTHS:
			var turns: Array[int] = []
			for cum: Array in runs:
				var n := TANK_TURNS + 1
				for k in cum.size():
					if int(cum[k]) >= h:
						n = k + 1
						break
				turns.append(n)
			turns.sort()
			var med: int = turns[turns.size() / 2]
			var p10: int = turns[turns.size() / 10]
			var p90: int = turns[(turns.size() * 9) / 10]
			line += " %-16s" % ("%d [%d..%d]" % [med, p10, p90])
		print(line)

# --- S. the cruiser's salvo ---------------------------------------------------------------------------

func _shell_table(spec: GunRules.Spec) -> void:
	print("S. ONE SALVO of %d shells aimed at the bridge's middle (%d seeds a row): sigma, mean pips, the most a salvo did, and the share of salvos that drop a bridge of each health in ONE salvo" % [spec.shells, SEEDS])
	var head := "%-8s %-9s %-7s %-8s | %-7s %-7s %-5s" % ["range m", "spotted s", "salvos", "spotter", "sigma", "mean", "max"]
	for h: int in HEALTHS:
		head += " %-6s" % ("%d" % h)
	print(head)
	var aim := Vector2(2000.0, 2500.0)
	for cfg: Array in [[1200.0, 0.0, 0, 0.4], [1200.0, 10.0, 0, 0.4], [1200.0, 20.0, 0, 0.4], [1200.0, 20.0, 1, 0.4], [1200.0, 20.0, 2, 0.4],
			[3000.0, 0.0, 0, 0.4], [3000.0, 10.0, 0, 0.4], [3000.0, 20.0, 0, 0.4], [3000.0, 20.0, 1, 0.4], [3000.0, 20.0, 2, 0.4], [600.0, 20.0, 2, 0.4]]:
		var range_m := float(cfg[0])
		var sigma := Guns.sigma_m(range_m, float(cfg[1]), spec, int(cfg[2]), float(cfg[3]))
		var totals: Array[int] = []
		for s in range(1, SEEDS + 1):
			var shells := Guns.make_salvo({"unit": "cruiser", "special": "main_guns", "step": 0, "t": 1.0, "from": aim - Vector2(range_m, 0.0), "aim": aim,
				"range_m": range_m, "flight_s": Guns.flight_time(range_m, spec), "sigma_m": sigma}, spec, s, 1, 0)
			var pips := 0
			for sh: Dictionary in shells:
				pips += spec.blast_damage(Vector2(float(sh["x"]), float(sh["y"])).distance_to(aim))
			totals.append(pips)
		var sum := 0
		var mx := 0
		for p: int in totals:
			sum += p
			mx = maxi(mx, p)
		var line := "%-8d %-9d %-7d %-8.1f | %-7.1f %-7.2f %-5d" % [roundi(range_m), roundi(float(cfg[1])), int(cfg[2]), float(cfg[3]), sigma, float(sum) / float(SEEDS), mx]
		for h: int in HEALTHS:
			var n := 0
			for p: int in totals:
				if p >= h:
					n += 1
			line += " %-6s" % ("%d%%" % roundi(100.0 * float(n) / float(SEEDS)))
		print(line)

# --- B. the bomber's stick ---------------------------------------------------------------------------

func _bomb_table(w: World) -> void:
	var bdef = w.unit_def("bomber")
	var per_drop: int = bdef.bomb_per_drop
	var drops: int = bdef.bomb_drops
	var centre := Vector2(2500.0, 2500.0)
	print("B. ONE STICK of %d bombs at the bridge's middle from a bomber at cruise (%d drops in the load), by height and release error r (%d seeds): mean pips a stick, the share of sticks that drop a bridge of each health, then the mean sticks to drop it" % [per_drop, drops, SEEDS])
	var head := "%-7s %-12s %-7s %-6s |" % ["band", "release", "sigma", "mean"]
	for h: int in HEALTHS:
		head += " %-6s" % ("%d" % h)
	print(head)
	for band: String in ["low", "medium", "high"]:
		var height := w.band_height(band)
		for r: float in [0.0, 0.5, 0.9]:
			var rng := Bombs.ideal_range(85.0, height, w.bombs.gravity)
			var acc := Bombs.accuracy(r, w.bombs)
			var fall := Bombs.fall_time(height, w.bombs.gravity)
			var drop := {"ok": true, "aim": [centre.x, centre.y], "release_t": 1.0, "fall_s": fall, "impact_t": 1.0 + fall,
				"release": {"x": centre.x - rng, "y": centre.y, "heading": 0.0, "speed": 85.0, "height_m": height},
				"accuracy": acc, "spread_m": Bombs.spread_m(height, acc, w.bombs)}
			var totals: Array[int] = []
			for s in SEEDS:
				var stick := Bombs.make_stick(drop, per_drop, w.bombs, s * 7 + 1, 1, "b", 0, 0)
				var pips := 0
				for bb: Dictionary in stick:
					pips += w.bombs.blast_damage(Vector2(float(bb["x"]), float(bb["y"])).distance_to(centre))
				totals.append(pips)
			var sum := 0
			for p: int in totals:
				sum += p
			var line := "%-7s %-12s %-7.1f %-6.2f |" % [band, "r=%.1f" % r, float(drop["spread_m"]), float(sum) / float(SEEDS)]
			for h: int in HEALTHS:
				var n := 0
				for p: int in totals:
					if p >= h:
						n += 1
				line += " %-6s" % ("%d%%" % roundi(100.0 * float(n) / float(SEEDS)))
			# Sticks needed (independent sticks of the same quality, up to 30), on average, for each health.
			var need_line := "  sticks:"
			for h: int in [10, 12, 14, 16, 20]:
				var need_sum := 0
				for s in SEEDS:
					var acc_pips := 0
					var n := 0
					for k in 30:
						var st := Bombs.make_stick(drop, per_drop, w.bombs, s * 7 + 1, 1 + k, "b", 0, k)
						for bb: Dictionary in st:
							acc_pips += w.bombs.blast_damage(Vector2(float(bb["x"]), float(bb["y"])).distance_to(centre))
						n += 1
						if acc_pips >= h:
							break
					need_sum += n
				need_line += " %d:%.1f" % [h, float(need_sum) / float(SEEDS)]
			print(line + need_line)
