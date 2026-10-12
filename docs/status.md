# Inkwood: now and next

What is in flight and what is free to take. Update it when you claim, finish or
drop a track (see `docs/operating.md`, "Several agents at once").
Decisions and open questions live in the Decision Ledger
(https://claude.ai/artifact/AQtHN2PP9H9mnyRjsCMDjE) and `data/decisions/decisions.json`.

## Claims

| Track | Owner | Folders | Since |
| --- | --- | --- | --- |

## Next, free to take

1. **A playtest build** with Strike, Suppress and Hold the bridge.
   build.ps1 closes a running game: ask Alex first.
2. **Terrain variety board** (decision water-layer): beaches, coastal cliffs, marsh,
   rock, orchards, wood density.
3. **Wreck litter board** (decision wreck-litter, open): sunken boats and planes in the
   water as environment, for character. After sinking lands: reuse the sunk-hull art,
   placed by seed; the board picks how many, where and which kinds.

## Later (planned, not fleshed out)

- **The forest fire's look board** (decision forest-fire, deferred: Alex, "It's fine as is for now"): a burning grove
  and a burnt-out trunk. Today's stand-in is W1 puffs per burning tree, bending downwind, and charred trunks; it reads
  partly like white trees. Options when it comes back: a long thin plume, a low grey haze, inked hatching, W1 as today.
- **A general player-side AI** (decision general-ai, deferred): plans any unit in any mission from what its
  side can see, specials included. Uses: headless playtests with honest numbers, an empty co-op seat, real
  enemy tactics. Today the player side in tests is a hand-written, all-seeing script per mission
  (strike_play.gd, suppress_play.gd, ...), and the enemy AI plays one role per unit and never uses specials.
  Revisit after the Hold the bridge playtest.

## Waiting on Alex (looks with working defaults)

- The tower's ruin (R1): Strike Boards. (Flak is decided: F2, the ragged burst.)
- Bombs' area of effect (D, tiers): Strike Boards.
- Fields (D, mixed).
- The drop picture and target marks, and static units at twice the plane scale:
  built for playtesting, not chosen.

## Recently landed

- 2026-10-11: the coastal wind (decisions coastal-wind, wind-with-height): a sea breeze by day and a land breeze
  at night from the sun's hour, wander and gusts, the host's wind on every client; all smoke drifts with the wind at
  its height; fire spreads further downwind. A bomb's target lost in fog or smoke is aimed at its last-seen place
  (decision lost-target-last-seen). The fire's look stays the stand-in for now; its board is deferred (Alex).
- 2026-10-11: the time-of-day sun is live (decision sun-time). Taken once at mission start from the host's clock and sent to
  clients (`scripts/net/mission_start.gd`); from the north side, NE at 06:00 through N at noon to NW at 18:00, so every shadow
  falls below its object; shadows clamped at 2 x the height; night hours fold onto the day; plane shadows follow the sun.
  Tests run on the fixed sun. Numbers proposed (test_sun, port 28788).
- 2026-10-11: tracers are T5, an ink streak with a dot for a hit and a tick for a miss (Alex, decision tracers-look; `data/fx/fx.json`
  working_default.tracers).
- 2026-10-11: the camera and the map's edge: wheel zoom in toward the cursor and out about the centre, left-drag on empty map pans, no right-drag pan, panning stops 100 m past the edge, and past the edge a hatched band onto blank paper with a distance legend (decisions zoom-anchors, pan-left-drag, pan-right-drag-off, pan-stops-at-edge, map-border); the side view's top, front and side strips, with the map's cones off by default and the panel's Arcs button (side-view-views).
- 2026-10-11: two boards for Alex, nothing live changed. The range-of-motion indicator for every unit type (variants/motion-range/,
  decision motion-range-look: Alex chose C, the wash under a thin rim, live as `planner.fan.mode` 'wash_rim'; test_fan_modes). Shadows from the time of day
  (variants/sun-time/, decision sun-time: fixed at start and every shadow follows, Alex's; the look, the co-op clock and night hours open):
  the sun now has one source, `data/params/sun.json` read through `scripts/world/sun.gd`, bit-identical in 'fixed' mode (test_sun).
- 2026-10-11: the boats and the bridge are drawn in the game (P1 cutter, S2 barge, ink V wake, the flat-deck arch and its ruin;
  `scripts/ui/unit_marker_art_boats.gd`), and sinking (decision ship-sinks): a destroyed ship, and a plane that comes down over water,
  falls through the water to the floor at 3 m/s (proposed), drawn intact under the water's own depth wash (`scripts/ui/unit_sunk.gd`),
  with a splash of ink rings; no damage drawn (test_sinking, test_boats_live).
- 2026-10-11: machine-gun tracers (decision tracers-mg: machine guns only, for now; the weapon list is data). The look is a board,
  variants/tracers/ (decision tracers-look, open); T2, a light streak with an ink edge, is the working default (test_tracers).
- 2026-10-11: the second playtest's fixes (decision playtest-2). Every moving unit starts with a tail, as if it had flown on at its normal speed
  (`scripts/ui/wingtip_trails.gd` start_tail_record; visual only, from the initial state; data `marker.trails.start_tail`, proposed). The side
  badge (the red/blue roundel and its tie) is off for every unit (Alex: 'No badge on units. We can figure something else out of we need it.';
  data `marker.side_badge.drawn_for` none; non_air and all bring it back). Tanks and ships still draw no ribbon (half_span_m 0): open.
- 2026-10-11: HOLD THE BRIDGE plays (decision bridge-mission; every number proposed, reasons in the data). The menu's scenario selector and
  `INKWOOD_SCENARIO=bridge` start `data/scenarios/bridge.json` on seed 55 (found by `scripts/test_support/bridge_seed_search.gd`): two player tanks
  on the village side of a river bridge, the cruiser 2.7 km away in the bay (the far end of its 3 km range; the tanks are its only spotters),
  three waves of two enemy tanks on the drive role (start turns 2 / 7 / 12), relief at turn 26. Win: `turn_reached` (the bridge held to relief);
  lose: `side_past` (an enemy tank across the bridge), both tanks down, or the bridge destroyed (own shells included). The two new mission
  conditions are in `scripts/sim/mission.gd`. Test: `test_bridge_mission` (port 28786); the scripted defence is `scripts/test_support/bridge_play.gd`;
  shots: `scripts/app/bridge_shot.gd`. Not balanced: it is the first build for Alex's playtest.
- 2026-10-11: the forest fire (decision forest-fire): trees burn as smoke, spread tree to tree by distance,
  burn down to trunks re-baked into the map; units near a fire may lose a pip; a unit in smoke is visible but
  untrackable; on in Suppress and behind the `fire` knob (test_fire, test_fire_track, test_fire_net, test_fire_render).
- 2026-10-11: combat answers (Alex's four). Bridge: 14 pips, about 20 turns of one tank's gun (bridge-durability, number proposed). Cruiser
  shell blast: 6 / 12 / 20 m at 4 / 3 / 2 pips (shell-blast, pips proposed). A bomb whose target left its cone and a gun salvo whose
  target is no longer spotted or in reach now fire a POOR shot instead of holding (outside-cone-release): `data/sim/bombs.json`
  outside_cone_mode and `data/sim/guns.json` gun_unspotted_mode are both `poor_shot`, `hold` stays as the switch's other setting; the
  salvo goes at the target's last spotted place, scatter x2, reload spent. Strafing stays deferred (strafe-later). Tables:
  `scripts/test_support/bridge_tuning.gd`, `gun_tuning.gd`.
- 2026-10-11: hatching stays inside its outline (6c01b7c, the hatch-clipping session; test_hatch_inside).
- 2026-10-11: tanks and ground movement, the cruiser and Main Guns Fire, shared
  spotting, Suppress with concealment and reveal-on-fire (4f1b820); water in the
  live map (839caaf); map and fog baked once and kept (5eaa5ef).
