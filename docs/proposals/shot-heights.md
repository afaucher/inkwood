# The shot height model and the heights chart (study, 2026-10-11)

For Alex's third playtest (decision playtest-3, `shot_height_model`, `heights_chart`): "How do cannon
rounds cross over sandbags but hit tanks, or houses, or maybe even trees? What is our accuracy for
tanks?" and "a quick chart of the different heights involved ... so we can make sure that all of our new
units make sense with the rest of the world". A study only: nothing here is built. Probes, the chart
(`heights_chart.png`, `draw_order.png`) and the full table (`heights_table.csv`): `tmp/studies/heights/`.

## Why rounds cross sandbags, houses and trees

**Nothing blocks fire.** An omission, not a decision. A target is a point (a unit's centre at its band
height; every surface unit at 0 m); a tank's shot is a dice roll against a cone, with no projectile;
shells and bombs land on a ground point and hurt every surface unit within their blast table (shells
6 / 12 / 20 m for 4 / 3 / 2 pips, bombs 12 / 25 / 45 m for 3 / 2 / 1; only units at or under 25 m).
Sandbags exist only as art (the battery's ring, 1 to 1.25 m); houses, walls and trees are baked scenery
with no presence in the sim (trees can catch fire from blasts). Fire needs no sight, no line of sight and
no spotting: a tank shoots at fogged or concealed enemies. Spotting matters only for the cruiser's guns
and for bombs following a target. Decided so far: a cone has height (altitude-fire), trees do not block
sight "for now", line of sight is off by default.

How a round resolves (`scripts/sim/combat.gd`, `combat_resolver.gd`): odds = base x centre x range x
crossing, clamped 0..1. centre = 1 - (1 - rim) r^k over the cone's ellipse (flat for the tank); range = 1
inside the effective range, a smoothstep to 0 at 1.2 x; crossing = 1 / (1 + (w / tracking)^2), w the line
of sight's turn rate (closing is free). Each 0.25 s tick each hardpoint takes the enemy in its cone with
the best odds and rolls rolls_per_second x 5 s times. Cones tilt with a climb or dive, capped at 35
degrees. Cone heights: tank gun +-10, light fighter +-8, heavy cannon +-6, bomber nose +-25, flak 2 to 90
up. Terrain height is invisible to combat.

## A tank's accuracy (measured in the real World, spread seeds)

0.12 base, flat across the cone, 350 m, one roll a second (5 a turn), 1 pip a hit.

- A still target anywhere from 15 to 350 m: **0.12 a shot, 0.60 pips a turn**. Range inside 350 m costs
  nothing, and the target's size does not count: a tank, the 40 m bridge and a 120 m ship are one point.
- Crossing at 4 / 8 / 10 m/s: 0.58 / 0.52 / 0.49 pips a turn at 100 m, 0.59 / 0.58 / 0.57 at 200 m,
  0.60 / 0.59 / 0.59 at 350 m. The odds halve only inside about 48 m at 10 m/s. At 400 m (the fringe) it is
  0.025 a shot.
- One tank kills a still 6-pip tank in 10.4 turns on average (median 10, p10 6, p90 16); the 14-pip bridge
  in 23.8 (median 23). It never reaches a plane. The same under the 170-degree arc.

**Correction**: bridge-tuning's 0.73 pips a turn ("median 20 turns", decision bridge-durability) was a
dice artefact. `Combat.roll_seed` XORs the game seed with the turn, so sequential seeds 1..120 over 80
turns give only 128 distinct dice streams; with spread seeds it is 0.60, as the odds say. Tuning tables
that sweep small seeds are noisier than their seed counts suggest (real play is unaffected).

**Found**: the cone geometry lets low-band planes hit surface units, never designed (strafing is
deferred, decision strafe-later): the bomber's nose gun 270 to 410 m ahead, its tail turret 220 to 475 m,
the heavy fighter's rear gunner 265 to 405 m. Light fighters never can; tanks never reach planes.

Options (PROPOSED): (a) say rounds ignore cover and add a cover factor to the odds, from data; (b) give
every blocker a height from the chart and trace direct fire as a straight line and shells as an arc
against it, a miss landing on the first thing it meets; (c) reuse the fog's viewshed as the line of fire
(terrain levels only today; houses are not in it, trees are decided off).

## Heights (m; D decided, P proposed, I inherited prototype px at 2 px/m)

| m | What | Source | |
| --- | --- | --- | --- |
| -69.8 | deepest sea made (median -35.8) | water.json sea.* | P |
| -30 / -10 / -3 | drawn depth steps (real 18+ / 6-18 / 0-6 m) | water.json levels.heights_m | D |
| -6 / -2 | draughts: cruiser / boats | units draught_m | P |
| 0 | sea level = low ground = every surface unit in combat | terrain.json, altitude.json | P |
| 1-1.25 | sandbag ring (art only) | unit_marker_art_static.gd | P |
| 2-2.5 | tank height, gun, eye (every ground eye 2.5, sea 6) | ui.json, tank.json, fog.json | P |
| 3 / 6 | light / heavy flak muzzles (the art's guns: 1.35-4.2) | anti_aircraft_battery.json | P |
| 4.2 / 6.5 | bridge piers / deck crown (sim: 0) | bridges.json arch | P |
| 5-7 | walls | render_defaults.json wall_height | I |
| 6.3-28.8 (median 12.7) | trees | render_defaults.json, scene_gen.gd | I |
| 10.7-14.5 | houses | render_defaults.json house_size | I |
| 12 / 24 | terrain levels 1 / 2 | terrain.json level_heights_m | P |
| 23-27 | radio tower (art) | unit_marker_art_static.gd | P |
| 25 | blast ceiling | bombs.json, guns.json blast_height_m | P |
| 20 to 188 | forest smoke climb | fx.json forest_fire.smoke | P |
| 120 / 400 / 1000 | the low / medium / high bands | altitude.json | P |
| 18-360 | shell arc apex (picture only) | guns.json apex_per_range | P |

## What does not fit

1. Smoke is drawn under every unit and shadow, though the forest plume reaches 188 m, above the low band
   (the bridge case: tank shadows on the smoke; puffs 0.34 to 0.8 x the unit's 40 m).
2. Shell arcs are drawn up to 360 m high; the sim ignores height.
3. Scenery is in prototype px: at 2 px/m a median tree (12.7 m) is as tall as the 12 m scarp, houses 11 to
   14.5 m, walls 5 to 7 m; terrain.json's "tallest tree 14 m" is stale (now 28.8).
4. Eye heights are per domain: the 25 m tower sees from 2.5 m, the cruiser from 6 m (only with line of
   sight on).
5. The sim ignores terrain height but plane shadows and fog use it: a plane over the 24 m plateau is
   labelled 120 m, its shadow uses 96 m.
6. The bridge deck is 6.5 m in the art, 0 m in the sim, "twenty metres up" in cruiser.json's reason.
7. Deep water is drawn as -30 m but the sea reaches -70 m; 79% of wet points are in the deep step.
8. The flak hardpoints (6 and 3 m) disagree with the battery art's guns (1.35 to 4.2 m).

Draw order, bottom to top: the baked map (paper, levels, terrain shadows, houses and walls, tree
shadows, trees by height), fog; the objective and tracks, bomb aim, ribbons; the effects' ground,
shadows and air (smoke); the planner, the cone wash; the markers (under, shadows, planes, marks); the
effects' top (bursts); the overlay and HUD. Flagged: houses under every tree; smoke under all units; the
tower and batteries over planes where a scenario lists the planes first (node order verified, the look
inferred); the bomb cone under the smoke while the planner is over it.

Not verified: any on-screen look, line of sight with the knob on, misfit 3's effect on how the scale reads.
