# Visual feedback coverage (study, 2026-10-11)

For Alex's third playtest (decision playtest-3, `feedback_audit`): "Missed shots should show where they
hit. Fired shots should have smoke for large rounds (tanks, artillery and ship cannons). Landed shots
should have an impact even if they don't destroy you. Let's enumerate all these visual feedback spots
and which do and don't have coverage."

A study only: nothing here is built. Probes and shots: `tmp/studies/feedback/` (not committed);
`probe_feed.gd` feeds real World turns through the real CombatFeed and records every draw call.

## What the sim emits in a turn

| Event | Fields | Drawn by |
| --- | --- | --- |
| `fire` | one per roll, only with a target in the cone: muzzle x/y/height_m, target centre, hit, odds, r, distance, tick. **No miss point.** | CombatFeed: tracer (MG), flak burst (flak), else nothing |
| `hit` | target, by, weapon, damage, health. **No position.** | `hit_marks.gd` ink burst, a pip, damage smoke |
| `down`, `crash`, `splash` | fate (exploded, out_of_control, destroyed) | explosion, fall, crash impact, ruin, sinking |
| `bomb_release`, `bomb_impact` | x/y, blast_m | falling bombs, blast and crater (B3), hit or miss |
| `shell_fire`, `shell_impact` | x/y, aim, poor_shot; x/y, blast_m | specks in flight, blast and crater at the impact |
| `gun_hold` | reason | **nothing** (the card has the reasons while planning) |
| `fire_ignite`, `fire_out`, `fire_damage` | the forest fire | `fx_fire_view.gd` from `world.fire.feed()` |
| `left_bounds`, `returned_to_bounds` | | **nothing** |

## Coverage (D drawn, P partial, N none)

| Weapon | Firing | Round in flight | Hit, no kill | Miss lands | Destroyed | Held |
| --- | --- | --- | --- | --- | --- | --- |
| Machine guns (wing guns, bomber turrets, rear gunner) | N | D (T5) | D | D (an invented tick) | D | N |
| Heavy fighter's nose cannon | N | N | P | N | D | N |
| Bombs | P | D | D | D | D | P |
| Flak and light flak (battery) | N | N | D | D | D | N |
| `aa_guns` (mobile AA, cutter, cruiser) | N | D (tracers) | D | D | D | N |
| Tank turret gun | N | N | P | **N** | P | N |
| Cruiser Main Guns (shells) | N | P (specks) | D | D | D | P |

Shots (native 1600 x 900, `tmp/studies/feedback/shots/`): `10_tank_fires_plus3` (no flash, no smoke),
`11_tank_miss_plus8` (identical to before the shot: a miss draws nothing), `12_tank_hit_plus4` and
`13_tank_hit_plus70` (a hit is an ink burst and a paper pool), `20` to `22` the cruiser's salvo.

## Gaps, in priority order (Alex's three first)

1. **Misses show where they land**: missing for the tank gun and the nose cannon. The `fire` event has
   the muzzle and the target, so a visual-only miss point (a seeded offset, as the tracer's) is possible
   today; a REAL miss point (one that can land on the bridge or a house) needs the sim to add the landing
   point to `fire`, drawn from its own seeded stream so the combat dice do not reshuffle. PROPOSED: the real
   one, after the shot-height study.
2. **Big guns make muzzle smoke**: missing for the tank, the nose cannon, the Main Guns and the flak
   batteries. The events give the muzzle (or the ship) and the time. Missing in data: what a weapon FIRES
   (weapons have `kind` fixed / flexible / turret, not a round class; `tracers.weapons` is a list of ids).
   PROPOSED: a `fires` field on every weapon (machine_gun, cannon, flak, shell) that decides its look and,
   with decision weapon-kinds, its cone; the muzzle puff reuses the W1 smoke, so it drifts with the wind.
3. **A hit that does not kill shows an impact**: missing for the tank gun and the nose cannon (an ink
   burst only). The `hit` event has no position, but the `fire` event before it has the target's centre.
   Bombs and shells already show an impact on every landing.
4. Smaller: flak has no flash at the gun and no shell in flight; `gun_hold` and a poor shot are silent in
   playback; leaving the map has no feedback; the hit's ink burst is small on a 24 px tank; destroyed
   tanks, mobile AA and batteries get the generic ruin (inferred).

Inferred, not verified: the generic wreck for ground units, no feedback for leaving the map, a tank gun
firing at a low plane drawing a flak burst.
