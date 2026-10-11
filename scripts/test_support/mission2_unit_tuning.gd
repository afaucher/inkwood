extends SceneTree

# THE TUNING TABLES for mission 2's two new units' proposed values (Track M2U, 2026-10-11). NOT a test (the gate does not run
# test_support); a script that plays scripted runs and prints what the proposed numbers do, so they can be argued about with figures.
# The same method as scripts/test_support/strike_tuning.gd (tables A and B), for the mobile AA gun and the military complex.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 --script res://scripts/test_support/mission2_unit_tuning.gd
#
# A. FLAK, one mobile gun standing still, one plane flying straight and level over it (999 pips so it stays up; the number is the
#    EXPECTED pips of damage, the sum of the gun's rolls' odds along the pass). Rows: type and band; columns: how far to one side
#    the track passes. The battery's table for comparison is strike_tuning.gd's A.
# B. THE BOMBS: the pips a stick of the bomber's load does to the military complex (12 pips) from a bomber at cruise on a perfect
#    line at the centre of it, by band and release error, and how many sticks it takes on average to destroy it (the radio tower's
#    table is strike_tuning.gd's B).

const World = preload("res://scripts/sim/world.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const BombWorlds = preload("res://scripts/test_support/bomb_worlds.gd")

const SEEDS := 300
const CENTRE := Vector2(2500.0, 2500.0)

func _initialize() -> void:
	var w0 := World.new()
	print("Mission 2 unit tuning: proposed values only (data/units/mobile_aa.json, military_complex.json, data/sim/bombs.json, combat.json). %d seeds a bomb row." % SEEDS)
	print("Bands (m): low %s, medium %s, high %s." % [w0.band_height("low"), w0.band_height("medium"), w0.band_height("high")])
	_flak_table()
	_bomb_table(w0)
	quit(0)

# --- A ------------------------------------------------------------------------------------

func _flak_pass(type_id: String, band: String, offset_m: float, gun_type: String) -> float:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	var speed: float = w.unit_def(type_id).envelope.speed_cruise
	w.add_unit({"id": "p", "type": type_id, "side": "allies", "controller": "player", "x": 700.0, "y": 2500.0 + offset_m, "heading": 0.0, "altitude_band": band, "speed": speed})
	w.add_unit({"id": "aa", "type": gun_type, "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0, "speed": 0.0})
	w.units["p"].health = 999
	var expected := 0.0
	for _t in int(ceil(3600.0 / speed / 5.0)) + 1:
		var res := _turn(w)
		for ev: Dictionary in res.get("events", []):
			if ev["type"] == "fire" and ev["unit"] == "aa":
				expected += float(ev["odds"])
	return expected

# Every participant (the player, and the AI when it has a mobile unit) readies up, the turn resolves, the next one begins.
func _turn(w: World) -> Dictionary:
	for p: String in w.participants():
		w.commit(p)
	var res := w.resolve()
	w.begin_turn()
	return res

func _flak_table() -> void:
	print("A. Flak: expected pips of damage to a plane flying straight over ONE gun at cruise (then 150 m, 300 m and 600 m aside)")
	print("%-14s %-26s %-26s %-26s" % ["plane", "low", "medium", "high"])
	for gun: String in ["mobile_aa", "anti_aircraft_battery"]:
		print("  the %s:" % gun)
		for type_id: String in ["bomber", "light_fighter"]:
			var row: Array[String] = []
			for band: String in ["low", "medium", "high"]:
				var cells: Array[String] = []
				for off: float in [0.0, 150.0, 300.0, 600.0]:
					cells.append("%.2f" % _flak_pass(type_id, band, off, gun))
				row.append(" / ".join(cells))
			print("  %-14s %-26s %-26s %-26s" % [type_id, row[0], row[1], row[2]])

# --- B ------------------------------------------------------------------------------------

func _drop(rules: BombRules, height: float, speed: float, r: float) -> Dictionary:
	var rng := Bombs.ideal_range(speed, height, rules.gravity)
	var acc := Bombs.accuracy(r, rules)
	var fall := Bombs.fall_time(height, rules.gravity)
	return {
		"ok": true, "aim": [CENTRE.x, CENTRE.y], "release_t": 1.0, "fall_s": fall, "impact_t": 1.0 + fall,
		"release": {"x": CENTRE.x - rng, "y": CENTRE.y, "heading": 0.0, "speed": speed, "height_m": height},
		"accuracy": acc, "spread_m": Bombs.spread_m(height, acc, rules),
	}

func _stick_pips(w: World, drop: Dictionary, seed_value: int, turn: int, drop_index: int, per_drop: int) -> int:
	var stick := Bombs.make_stick(drop, per_drop, w.bombs, seed_value, turn, "b", 0, drop_index)
	var pips := 0
	for b: Dictionary in stick:
		pips += w.bombs.blast_damage(Vector2(float(b["x"]), float(b["y"])).distance_to(CENTRE))
	return pips

func _bomb_table(w: World) -> void:
	var bdef = w.unit_def("bomber")
	var per_drop: int = bdef.bomb_per_drop
	var drops: int = bdef.bomb_drops
	for target: String in ["radio_tower", "military_complex"]:
		var health: int = w.unit_def(target).health
		print("B. Bombs: a stick of %d at the %s (%d pips) from a bomber at cruise, %d drops in the load; pips per stick (mean), and sticks to destroy it." % [per_drop, target, health, drops])
		print("%-7s %-14s | %-9s %-10s | %-13s %-13s %-13s" % ["band", "release error", "sigma m", "pips/stick", "mean sticks", "dead in 1", "dead in <=%d" % drops])
		for band: String in ["low", "medium", "high"]:
			var height := w.band_height(band)
			for r: float in [0.0, 0.5, 0.9]:
				var d := _drop(w.bombs, height, 85.0, r)
				var total := 0
				var need_sum := 0
				var dead1 := 0
				var dead_n := 0
				for s in SEEDS:
					var acc := 0
					var n := 0
					for k in 30:
						acc += _stick_pips(w, d, s * 7 + 1, 1 + k, k, per_drop)
						n += 1
						if k == 0:
							total += acc
							if acc >= health:
								dead1 += 1
						if acc >= health:
							if n <= drops:
								dead_n += 1
							break
					need_sum += n
				print("%-7s %-14s | %-9.1f %-10.2f | %-13.2f %-13s %-13s" % [band, "r=%.1f (acc %.2f)" % [r, Bombs.accuracy(r, w.bombs)], float(d["spread_m"]), float(total) / float(SEEDS), float(need_sum) / float(SEEDS),
					"%d%%" % roundi(100.0 * dead1 / SEEDS), "%d%%" % roundi(100.0 * dead_n / SEEDS)])
