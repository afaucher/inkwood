extends RefCounted

# THE EXPECTED DAMAGE OF A DROP (Track T, 2026-10-10). The line on the orders card -- "radio tower: about 5
# of 8" -- and the area of effect the board (variants/bomb-aoe/) draws both ask: if this drop is released with this
# aim from this release, what does it do to a unit standing here? The answer is the MODEL'S OWN, not a second
# model of it: the stick's bombs are thrown with the sim's own dice (Bombs.make_stick, the correlated stick with the
# spread the release angle and the height give), their blasts are the sim's own table (BombRules.blast_damage),
# and the sum is capped at the unit's health, as a unit cannot lose more than it has. The sample is FIXED
# (data/sim/bombs.json expect_sticks sticks from expect_seed, PROPOSED), so the line does not flicker as the
# interface redraws and every peer shows the same number; it is an estimate of a mean, never a roll, and the real
# resolve draws its own dice from the game's seed.
#
#   BombExpect.damage(drop, per_drop, rules, at, health)
#       -> {"mean" (expected pips lost, capped at health), "mean_raw" (uncapped), "p_destroy" (the chance the unit
#           is at 0), "health", "sticks"}
#
# `drop` is Bombs.plan_drop()'s analysis (World.drop_expected builds it). A unit above blast_height_m (a plane in
# the air) takes nothing: bombs cannot hurt planes today (data/sim/bombs.json).

const Bombs = preload("res://scripts/sim/bombs.gd")
const BombRules = preload("res://scripts/sim/bomb_rules.gd")

static func damage(drop: Dictionary, per_drop: int, rules: BombRules, at: Vector2, health: int, unit_height_m: float = 0.0) -> Dictionary:
	var out := {"mean": 0.0, "mean_raw": 0.0, "p_destroy": 0.0, "health": health, "sticks": 0}
	if drop.get("ok", false) != true or per_drop <= 0 or health <= 0 or unit_height_m > rules.blast_height_m:
		return out
	var n := rules.expect_sticks
	var total := 0.0
	var raw := 0.0
	var kills := 0
	for s in n:
		# One stick per sample: the sample's index plays the part of the release turn in the stick's seed.
		var stick := Bombs.make_stick(drop, per_drop, rules, rules.expect_seed, s + 1, "expect", 0, 0)
		var pips := 0
		for b: Dictionary in stick:
			pips += rules.blast_damage(Vector2(float(b["x"]), float(b["y"])).distance_to(at))
		raw += float(pips)
		total += float(mini(pips, health))
		if pips >= health:
			kills += 1
	out["mean"] = total / float(n)
	out["mean_raw"] = raw / float(n)
	out["p_destroy"] = float(kills) / float(n)
	out["sticks"] = n
	return out

# The farthest a unit can be from the aim and still take expected damage worth a mention: the blast's reach
# and three standard deviations of the scatter and half the stick's length, in metres. The interface and the
# World use it to know which units to ask about.
static func reach_m(drop: Dictionary, per_drop: int, rules: BombRules) -> float:
	var rel: Dictionary = drop.get("release", {})
	var stick := float(maxi(per_drop - 1, 0)) * float(rel.get("speed", 0.0)) * rules.release_interval_s
	return rules.blast_radius_m() + 3.0 * float(drop.get("spread_m", 0.0)) + 0.5 * stick
