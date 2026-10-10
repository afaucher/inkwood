extends SceneTree

# THE TUNING TABLES for the strike's proposed values (Track S2, 2026-10-10): the flak, the bombs and
# the radio tower. NOT a test (the gate does not run test_support); a script that plays scripted
# runs and prints what the proposed numbers do, so the numbers can be argued about with figures.
#
#   $env:INKWOOD_STEAM = "off"
#   build\deps\godot\4.7-stable\Godot_v4.7-stable_win64_console.exe --path . --headless --fixed-fps 60 --script res://scripts/test_support/strike_tuning.gd
#
# A. FLAK, one battery, one plane flying straight and level over it (the plane has 999 pips so it
#    stays up; the number is the EXPECTED pips of damage, the sum of the flak rolls' odds along the
#    pass). Rows: type and band; columns: how far to one side of the battery the track passes.
# B. THE BOMBS: the pips a stick of the bomber's load does to the tower, by band and by how close the
#    release is to ideal (release error r: 0 ideal, 0.5 half way to the rim of the cone, 1 the rim),
#    and how many drops (passes) it takes on average to destroy the tower; SEEDS sticks each.
# C. THE STRIKE RUN: the bomber flies the proposed layout (the tower, two batteries) straight in on
#    its band from the west, drops a stick at the step whose cone is centred best on the tower while
#    it has drops, and flies on: per band, how often the tower dies, how often the bomber does, the
#    pips it loses to flak, and the turn the tower dies in. The run is a straight fly-over, so it has
#    one chance at the target; the drops after the first are on the same pass (consecutive steps).

const World = preload("res://scripts/sim/world.gd")
const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")
const Combat = preload("res://scripts/sim/combat.gd")
const Mission = preload("res://scripts/sim/mission.gd")

const SEEDS := 300
const STRIKE_SEEDS := 100
const RUN_TURNS := 12
const TOWER := Vector2(2500.0, 2500.0)
const BATTERIES := [Vector2(2250.0, 2200.0), Vector2(2800.0, 2800.0)]

func _initialize() -> void:
	var w0 := World.new()
	print("Strike tuning tables: proposed values only (data/units/*.json, data/sim/bombs.json, data/sim/combat.json). %d seeds a row." % SEEDS)
	print("Bands (m): low %s, medium %s, high %s. Bomb gravity %s m/s^2; cone half %s x %s deg; spread %s + %s per m, over the accuracy factor (rim %s)." % [
		w0.band_height("low"), w0.band_height("medium"), w0.band_height("high"), w0.bombs.gravity,
		w0.bombs.cone_half_across_deg, w0.bombs.cone_half_height_deg, w0.bombs.spread_base_m, w0.bombs.spread_per_height, w0.bombs.rim_accuracy_factor])
	print("Tower: %d pips. Battery: %d pips, flak %s m effective." % [
		w0.unit_def("radio_tower").health, w0.unit_def("anti_aircraft_battery").health, w0.unit_def("anti_aircraft_battery").weapons[0].effective_range_m])
	print("")
	var parts := OS.get_cmdline_user_args()
	if parts.is_empty():
		parts = PackedStringArray(["A", "B", "C"])
	if parts.has("A"):
		_flak_table()
		print("")
	if parts.has("B"):
		_bomb_table(w0)
		print("")
	if parts.has("C"):
		_strike_table()
	quit()

# --- A. flak ---------------------------------------------------------------------------

func _flak_pass(type_id: String, band: String, offset_m: float) -> Dictionary:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	var speed: float = w.unit_def(type_id).envelope.speed_cruise
	w.add_unit({"id": "p", "type": type_id, "side": "allies", "controller": "player", "x": 700.0, "y": 2500.0 + offset_m, "heading": 0.0, "altitude_band": band, "speed": speed})
	w.add_unit({"id": "aa", "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": 2500.0, "y": 2500.0, "heading": 0.0})
	w.units["p"].health = 999
	var expected := 0.0
	var rolls := 0
	var seconds_in := 0.0
	var turns := int(ceil(3600.0 / speed / 5.0)) + 1
	for _t in turns:
		w.commit("local")
		var res := w.resolve()
		for ev: Dictionary in res["events"]:
			if ev["type"] == "fire":
				expected += float(ev["odds"])
				rolls += 1
		w.begin_turn()
	return {"expected": expected, "rolls": rolls}

func _flak_table() -> void:
	print("A. Flak: one battery, a plane flies straight over at cruise; expected pips of damage per pass (sum of the flak odds), and the rolls it drew.")
	print("%-14s %-7s | %-16s %-16s %-16s %-16s" % ["plane", "band", "over it", "300 m aside", "600 m aside", "900 m aside"])
	for type_id: String in ["bomber", "light_fighter"]:
		for band: String in ["low", "medium", "high"]:
			var cells: Array[String] = []
			for off: float in [0.0, 300.0, 600.0, 900.0]:
				var r := _flak_pass(type_id, band, off)
				cells.append("%5.2f (%3d rolls)" % [r["expected"], r["rolls"]])
			print("%-14s %-7s | %-16s %-16s %-16s %-16s" % [type_id, band, cells[0], cells[1], cells[2], cells[3]])

# --- B. bombs ---------------------------------------------------------------------------

# A drop dictionary for a bomber at `height` on a perfect run at the tower, at release error r.
func _drop(rules: BombRules, height: float, speed: float, r: float) -> Dictionary:
	var rng := Bombs.ideal_range(speed, height, rules.gravity)
	var acc := Bombs.accuracy(r, rules)
	var fall := Bombs.fall_time(height, rules.gravity)
	return {
		"ok": true, "aim": [TOWER.x, TOWER.y], "release_t": 1.0, "fall_s": fall, "impact_t": 1.0 + fall,
		"release": {"x": TOWER.x - rng, "y": TOWER.y, "heading": 0.0, "speed": speed, "height_m": height},
		"accuracy": acc, "spread_m": Bombs.spread_m(height, acc, rules),
	}

func _stick_pips(w: World, drop: Dictionary, seed_value: int, turn: int, index: int, drop_index: int, per_drop: int) -> int:
	var stick := Bombs.make_stick(drop, per_drop, w.bombs, seed_value, turn, "b", index, drop_index)
	var pips := 0
	for b: Dictionary in stick:
		pips += w.bombs.blast_damage(Vector2(float(b["x"]), float(b["y"])).distance_to(TOWER))
	return pips

func _bomb_table(w: World) -> void:
	var bdef = w.unit_def("bomber")
	var health: int = w.unit_def("radio_tower").health
	var per_drop: int = bdef.bomb_per_drop
	var drops: int = bdef.bomb_drops
	print("B. Bombs: a stick of %d at the tower (%d pips) from a bomber at cruise, %d drops in the load; pips per stick (mean), and passes (drops) to destroy it." % [per_drop, health, drops])
	print("%-7s %-14s | %-9s %-10s | %-13s %-13s %-13s" % ["band", "release error", "sigma m", "pips/stick", "mean drops", "dead in 1", "dead in <=%d" % drops])
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
					acc += _stick_pips(w, d, s * 7 + 1, 1 + k, 0, k, per_drop)
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

# --- C. the strike run -----------------------------------------------------------------------

func _strike_run(band: String, seed_value: int, flak_on: bool, lateral: float, r_max: float) -> Dictionary:
	var w := World.new()
	w.quiet = true
	w.rng_seed = seed_value
	w.add_player("local")
	var speed: float = w.unit_def("bomber").envelope.speed_cruise
	w.add_unit({"id": "b", "type": "bomber", "side": "allies", "controller": "player", "x": 400.0, "y": TOWER.y + lateral, "heading": 0.0, "altitude_band": band, "speed": speed})
	w.add_unit({"id": "tower", "type": "radio_tower", "side": "axis", "controller": "ai", "x": TOWER.x, "y": TOWER.y, "heading": 0.0})
	if flak_on:
		for i in BATTERIES.size():
			w.add_unit({"id": "aa%d" % i, "type": "anti_aircraft_battery", "side": "axis", "controller": "ai", "x": (BATTERIES[i] as Vector2).x, "y": (BATTERIES[i] as Vector2).y, "heading": 0.0})
	# The Strike mission with a turn limit of RUN_TURNS (Mission.strike): the run ends at its verdict.
	var m := Mission.new(w, Mission.strike("tower", "b", RUN_TURNS))
	var drops_made := 0
	for _t in RUN_TURNS:
		var b = w.units["b"]
		# Drop at every step whose release error for the tower is small enough, as long as drops remain.
		if not b.down and b.drops_left > 0:
			var planned := 0
			for k in 3:
				var info := w.drop_spread("b", k, TOWER)
				if info.is_empty():
					continue
				if not bool(info["clamped"]) and float(info["r"]) <= r_max and planned < b.drops_left:
					w.plan_step("b", k, {"drop": {"aim": [TOWER.x, TOWER.y]}})
					planned += 1
		w.commit("local")
		var res := w.resolve()
		for ev: Dictionary in res["events"]:
			if ev["type"] == "bomb_release":
				drops_made += 1
		m.evaluate(res)
		if m.state != Mission.PLAYING:
			break
		w.begin_turn()
	return {"state": m.state, "reason": m.reason, "turn": m.turn, "tower_down": w.units["tower"].down, "bomber_down": w.units["b"].down, "bomber_hp": w.units["b"].health, "drops": drops_made}

func _strike_table() -> void:
	print("C. The strike run: the bomber flies straight in at the tower (%s) on its band from the west and drops a stick at every step whose release error is at most r (0.35 for an aligned track, 0.7 for one 40 m off), up to its load; two batteries (%s, %s). Played under the Strike mission (win: tower down; lose: bomber down or turn %d)." % [str(TOWER), str(BATTERIES[0]), str(BATTERIES[1]), RUN_TURNS])
	print("   'aligned' the track passes over the tower (lateral 0); 'off 40 m' it passes 40 m to one side (the cone is only 8 degrees to either side: 107 m at 770 m). Pips lost: the bomber's, of 8, at the verdict.")
	print("%-7s %-10s %-5s | %-6s %-13s %-9s %-10s | %-8s" % ["band", "track", "flak", "WON", "lost: bomber", "pips lost", "mean drops", "verdict turn"])
	for band: String in ["low", "medium", "high"]:
		for lateral: float in [0.0, 40.0]:
			for flak_on: bool in [false, true]:
				var won := 0
				var lost_bomber := 0
				var lost := 0
				var drops := 0
				var turn_sum := 0
				for s in STRIKE_SEEDS:
					var r := _strike_run(band, s + 1, flak_on, lateral, 0.35 if lateral == 0.0 else 0.7)
					if r["state"] == Mission.WON:
						won += 1
					elif bool(r["bomber_down"]):
						lost_bomber += 1
					lost += 8 - int(r["bomber_hp"])
					drops += int(r["drops"])
					turn_sum += int(r["turn"])
				print("%-7s %-10s %-5s | %-6s %-13s %-9.2f %-10.2f | %.1f" % [band, "aligned" if lateral == 0.0 else "off %d m" % int(lateral), "on" if flak_on else "off",
					"%d%%" % roundi(100.0 * won / STRIKE_SEEDS), "%d%%" % roundi(100.0 * lost_bomber / STRIKE_SEEDS), float(lost) / float(STRIKE_SEEDS), float(drops) / float(STRIKE_SEEDS), float(turn_sum) / float(STRIKE_SEEDS)])
