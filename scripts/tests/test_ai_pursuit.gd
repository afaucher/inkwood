extends "res://scripts/test_support/test_case.gd"

# LEAD PURSUIT (Track E, scripts/sim/ai_pilot.gd, ai_steer.gd, ai_cone.gd): an
# engaging escort steers to bring its target into its forward weapon's cone,
# aiming at where the target WILL be if it flies straight on. Measured against
# the real geometry (the cone, in height as well as across, checked on the
# resolved paths every quarter second) in a sweep: a fighter at the middle of the
# map, a straight-flying enemy fighter placed all round it at two ranges and
# flying in eight directions.
#
# Sight is opened wide for the sweep so that it measures steering, not fog (the
# fog rule has its own test, test_ai_states); the leash and the no-chance rule
# are off so nothing breaks the engagement off; the sweep runs three turns, short
# enough that a target flying straight stays on the map. A fighter that is NOT
# engaging (it flies straight) is the baseline.

const World = preload("res://scripts/sim/world.gd")
const AiPilot = preload("res://scripts/sim/ai_pilot.gd")
const AiCone = preload("res://scripts/sim/ai_cone.gd")

const TURNS := 3
const CENTRE := 2500.0

func setup(_main) -> void:
	timeout_seconds = 90.0
	var cone_source := ""
	for f_type in ["light_fighter", "heavy_fighter"]:
		for d in [400.0, 700.0]:
			var got := 0
			var base := 0
			var easy_total := 0
			var easy_got := 0
			for bi in 8:
				var bearing := TAU * float(bi) / 8.0
				for ai_ in 8:
					var alpha := TAU * float(ai_) / 8.0
					var r := _trial(f_type, d, bearing, alpha, 100.0, true)
					var b := _trial(f_type, d, bearing, alpha, 100.0, false)
					cone_source = str(r["source"])
					if float(r["first"]) >= 0.0:
						got += 1
					if float(b["first"]) >= 0.0:
						base += 1
					# The target ahead of the nose, flying roughly with it or across its
					# front: the cases lead pursuit must always get (observed on both types).
					if d == 400.0 and bi in [0, 1, 7] and (bi == 0 or ai_ in [0, 1, 6, 7]):
						easy_total += 1
						if float(r["first"]) >= 0.0:
							easy_got += 1
			print("  %s, enemy at %d m: the target is in the cone within %d turns in %d of 64 geometries (a fighter that flies straight: %d)" % [f_type, d, TURNS, got, base])
			check(got >= 2 * base, "%s at %d m: pursuit gets in the cone at least twice as often as flying straight (%d vs %d)" % [f_type, d, got, base])
			check(got >= 20, "%s at %d m: pursuit gets the target in the cone in at least 20 of 64 geometries (%d)" % [f_type, d, got])
			if d == 400.0:
				eq(easy_got, easy_total, "%s at 400 m: every target ahead, flying with or across the nose, is brought into the cone" % f_type)
	print("  (the forward cone came from: %s)" % cone_source)
	check(cone_source == "def" or cone_source == "fallback", "the forward cone has a known source: %s" % cone_source)
	_tail_chase()
	_determinism()
	finish()

# One trial: returns {first (seconds into the run the target was first inside the
# cone, -1 if never), contact (seconds sampled in the cone), source}.
func _trial(f_type: String, d: float, bearing: float, alpha: float, t_speed: float, engage: bool, turns: int = TURNS) -> Dictionary:
	var w := World.new()
	w.quiet = true
	w.add_player("local")
	# A bomber far away for the fighter to "protect"; the engage radius round the
	# fighter itself is what starts the engagement.
	w.add_unit({"id": "far", "type": "bomber", "side": "axis", "controller": "ai", "x": 4300.0, "y": 4300.0, "heading": PI * 0.75, "altitude_band": "medium"})
	w.add_unit({"id": "f", "type": f_type, "side": "axis", "controller": "ai", "x": CENTRE, "y": CENTRE, "heading": 0.0})
	w.add_unit({"id": "t", "type": "light_fighter", "side": "allies", "controller": "player",
		"x": CENTRE + cos(bearing) * d, "y": CENTRE + sin(bearing) * d, "heading": alpha, "speed": t_speed})
	if not w.units.has("f") or not w.units.has("t"):
		fail("trial setup failed: %s" % w.last_error)
		return {"first": -1.0, "contact": 0.0, "source": ""}
	w.units["f"].def.sight_range_m = 1.0e6
	# Combat is live in the World (Track C): nobody goes down in this sweep, so it
	# measures the steering and nothing else.
	w.units["f"].health = 100000
	w.units["t"].health = 100000
	var ai := AiPilot.new("res://data/sim/ai.json", true)
	ai.params.set_value("escort", "leash_m", 1.0e9)
	ai.params.set_value("escort", "no_chance_turns", 100000)
	ai.params.set_value("escort", "engage_radius_self_m", 5000.0)
	ai.params.set_value("knowledge", "memory_turns", 10)
	var orders := {"far": {"role": "strike", "target": [4300.0, 4300.0]}}
	if engage:
		orders["f"] = {"role": "escort", "protect": "far"}
	ai.attach(w, orders)
	var cone := ai.cone_of("f")
	var first := -1.0
	var contact := 0.0
	for turn_i in turns:
		w.commit("local")
		w.resolve()
		var tt := 0.0
		while tt <= 5.0 + 1e-9:
			var a := w.sample("f", tt, "history")
			var b := w.sample("t", tt, "history")
			if AiCone.contains(cone, a["x"], a["y"], a["heading"], a["height_m"], b["x"], b["y"], b["height_m"]):
				contact += 0.25
				if first < 0.0:
					first = float(turn_i) * 5.0 + tt
			tt += 0.25
		w.begin_turn()
	return {"first": first, "contact": contact, "source": str(cone.get("source", ""))}

# A tail chase: the target 350 m dead ahead, flying away at 110 m/s on a heading 30
# degrees off the fighter's own. A fighter flying straight loses it from the cone
# in a couple of seconds; the lead turns with it and keeps it.
func _tail_chase() -> void:
	for f_type in ["light_fighter", "heavy_fighter"]:
		var r := _trial(f_type, 350.0, 0.0, deg_to_rad(30.0), 110.0, true, 4)
		var b := _trial(f_type, 350.0, 0.0, deg_to_rad(30.0), 110.0, false, 4)
		print("  %s tail chase: %.2f s in the cone of 20 s (flying straight: %.2f s)" % [f_type, r["contact"], b["contact"]])
		check(float(r["contact"]) >= 12.0, "%s: a tail chase holds the target in the cone for at least 12 of 20 s (%.2f s)" % [f_type, r["contact"]])
		check(float(r["contact"]) > float(b["contact"]), "%s: more than flying straight does (%.2f s)" % [f_type, b["contact"]])

func _determinism() -> void:
	var a := _trial("light_fighter", 700.0, 1.0, 2.0, 100.0, true)
	var b := _trial("light_fighter", 700.0, 1.0, 2.0, 100.0, true)
	eq(a, b, "the same engagement twice gives the same result")
