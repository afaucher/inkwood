# Inkwood: now and next

What is in flight and what is free to take. Update it when you claim, finish or
drop a track (see `docs/operating.md`, "Several agents at once").
Decisions and open questions live in the Decision Ledger
(https://claude.ai/artifact/AQtHN2PP9H9mnyRjsCMDjE) and `data/decisions/decisions.json`.

## Claims

| Track | Owner | Folders | Since |
| --- | --- | --- | --- |
| BP: boards, plan weight (A8) and the Main Guns fire mark (D8) | lead + Sonnet builder BP | scripts/ui/motion_planner.gd, scripts/ui/boards/plan_*, variants/plan-weight, variants/guns-mark; data/ui/ui.json planner.* and guns.marks by targeted edits | 2026-10-14 |
| BR: board, the recoil (A5) | lead + Sonnet builder BR | scripts/ui/unit_marker*.gd, scripts/ui/boards/recoil_*, variants/recoil; data/units/tank.json, cruiser.json drawing keys | 2026-10-14 |
| BS: board, the water splash (B13) | lead + Sonnet builder BS | scripts/fx/*, scripts/ui/combat_feed.gd, gunfire_feed.gd, scripts/fx/boards or scripts/ui/boards/splash_*, variants/splash; data/fx/fx.json, data/world/boats.json game.sunk.splash | 2026-10-14 |
| BF: board, the fog edge (B15) | lead + Sonnet builder BF | scripts/render/fog_*, scripts/render/boards/fog_edge_*, variants/fog-edge; data/view/fog.json | 2026-10-14 |

## Next, free to take

**The whole open list, for the next session's prioritisation, is `docs/backlog.md`.** Items below are older.

1. **The third playtest's interface and tank asks** (decision playtest-3, Alex's words in its notes): the views
   (top, front, side) a section of their own in the card like 'orders'; 'altitude, step X' and 'views, step X' lose
   'step X'; the step indicator bigger, without 'step 1 of 2' and without 'click a node to change it, or add step 2';
   the roster without 'no plan (flies on)' and 'plan: 1 of 2 steps' (the pips cover them), its other text a little
   bigger; the camera zooms in further (tanks too small); a tank's special says when it is engaged and why it will not
   engage; tanks fire on a forward arc of about 170 degrees, not behind (see also decision what a weapon fires decides
   its look and cone); the zoom judders in and out ('like there's two systems fighting each other for deciding the
   view'). Two studies Alex is giving to another agent: every visual feedback moment and which are drawn (missed shots
   show where they land, big guns make muzzle smoke, a hit that does not kill still shows an impact), and the shot height
   model (rounds over sandbags but into tanks, houses, trees; a tank's accuracy). And a chart of every height in the
   world with the draw order by height. The bridge's smoke is FOUND, not yet fixed (playtest-3 bridge_smoke: plane damage
   smoke on a 40 m bridge, puffs sized by the unit and drawn under the markers); Alex has three questions to answer.
   All of this item is handed to one agent (Alex, 2026-10-11).
2. **A playtest build** with Strike, Suppress and Hold the bridge.
   build.ps1 closes a running game: ask Alex first.
3. **Terrain variety board** (decision water-layer): beaches, coastal cliffs, marsh,
   rock, orchards, wood density.
4. **Wreck litter board** (decision wreck-litter, open): sunken boats and planes in the
   water as environment, for character. After sinking lands: reuse the sunk-hull art,
   placed by seed; the board picks how many, where and which kinds.

## Later (planned, not fleshed out)

- **Wear patterns for everything** (decision damage-looks, Alex: 'I don't want to do wear patterns yet for everything. Add it
  to the list for the future.'): what stays visible as a thing loses pips (cracks, holes, engine smoke), per material.
- **Houses and walls taking damage** (decision line-of-fire: 'Later').
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

- 2026-10-12: gunfire G3 live (decision gunfire-looks): big guns' muzzle smoke and rounds' impacts by material in the W1
  grammar; misses are visual-only beside the target until lines of fire are on. The round model (`data/sim/rounds.json`,
  decision round-model): every weapon names its round; tracers come from the round. A material per unit (damage-looks).
  Planes' smoke trails climb (smoke-consistency). Scenery at real heights, S1 (scenery-heights; the prototype's heights
  kept for the port check). Lines of fire, stage 2, behind `data/sim/line_of_fire.json` enabled (still FALSE): odds from
  the visible share and the round's spread, a hidden target held, misses landing with their material, the low bridge
  with 1 m parapets; with it off, eight recorded games give byte-identical events. Proofs in tmp/lof2/.
- 2026-10-12: lines of fire, stage 1 (decision line-of-fire): a height grid (1 m cells: top height and material, per chunk,
  from the seed) and the line check (`LineOfFire.trace`, `exposure`; canopies thin; tanks as hull and turret boxes), not
  used by combat yet (`data/sim/line_of_fire.json` enabled false). Proofs in tmp/lof/ (`scripts/app/lof_shot.gd`). Stage 2
  (odds by visible share, range and size; misses landing; the combat hook) waits on Alex.
- 2026-10-11: smoke made consistent (decision smoke-consistency; the audit is docs/proposals/smoke-audit.md): every smoke
  above surface units and their shadows and under aircraft; damage smoke sized by a small source per unit (`damage_smoke` in
  every unit file), climbing 4 m/s and leaning downwind; no smoke on the bridge; a bomb or shell in water splashes. The AA
  weapons by what they fire (weapon-kinds): `quad_mg` (mobile AA) and `deck_mg` (cutter) are machine guns with tracers,
  level to 50 degrees up; `ship_flak` (cruiser) bursts. The scenery-heights board (variants/scenery-heights/) waits on Alex.
- 2026-10-11: the zoom judder is fixed and the camera zooms in further (decision playtest-3): a zoom ends the follow
  (`camera.json` follow.break_on_zoom), the units' size follows the zoom the same frame, unit art is not re-baked mid-zoom;
  the closest zoom 3.0, a tank about 54 px (proposed). test_camera, test_zoom_scale, test_marker_rebake.
- 2026-10-11: the third playtest's card and roster asks (decision playtest-3): the roster without its plan words and with bigger
  text; the orders card without 'step X', with a bigger step strip; the VIEWS a card of their own; a unit's special says
  whether it is set and why it cannot be (a tank has none: 'no special: weapons fire on their own'); the tank's gun on a
  170-degree forward arc. Two studies for Alex: docs/proposals/visual-feedback.md and shot-heights.md.
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
