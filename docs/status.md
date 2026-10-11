# Inkwood: now and next

What is in flight and what is free to take. Update it when you claim, finish or
drop a track (see `docs/operating.md`, "Several agents at once").
Decisions and open questions live in the Decision Ledger
(https://claude.ai/artifact/AQtHN2PP9H9mnyRjsCMDjE) and `data/decisions/decisions.json`.

## Claims

| Track | Owner | Folders | Since |
| --- | --- | --- | --- |
| Forest fire (decision forest-fire): the mechanic has landed (below); next the board for a burning grove and a burnt-out trunk, then playtesting in Suppress | fire session (nice-dewdney worktree) | new data/sim/fire.json, scripts/sim/fire*.gd, scripts/tests/test_fire*.gd; the fire step and its net state in scripts/sim/world.gd (and the snapshot in scripts/net/world_sync.gd); burnt cover in scripts/sim/concealment.gd, data/sim/concealment.json; smoke denies tracking in scripts/sim/spotting.gd, bombs.gd (followed aim), scripts/ui/ui_target.gd and the enemy-click lines of scripts/ui/unit_ui.gd; new scripts/fx/fx_fire*.gd and its hook in fx_field.gd/fx_layer.gd; per-chunk rebake in scripts/render/map_view.gd, chunk_terrain_provider.gd; data/scenarios/suppress.json (fire on); a fire knob in scripts/debug/debug_settings.gd | 2026-10-11 |
| Camera controls: wheel zoom anchors and left-drag pan (landed); right-drag pan removed, panning stops at the map's edge (Alex); the map's border board (builder) | camera session (beautiful-lumiere worktree) | scripts/world/camera_controller.gd, data/view/camera.json, scripts/tests/test_camera.gd; the board: scripts/render/map_border*.gd, data/view/map_border.json, scripts/ui/boards/map_border_board_shot.gd, variants/map-border/, scripts/tests/test_map_border.gd, and a one-line hook in scripts/render/map_view.gd | 2026-10-11 |
| Side view: top, front and side as folding strips, an arcs button in the panel, map cones off by default (Alex, decision side-view-views) | camera session (builder) | scripts/ui/side_view*.gd, scripts/tests/test_side_view.gd, data/ui/ui.json side_view keys, roster.arcs (removed) and planner.cones.shown; the roster's Arcs button in scripts/ui/roster.gd (removed); the arcs default's knock-on in tests that expect cones (test_cone_overlay, test_ui_*) | 2026-10-11 |

## Next, free to take

1. **A playtest build** with Strike, Suppress and Hold the bridge.
   build.ps1 closes a running game: ask Alex first.
2. **Terrain variety board** (decision water-layer): beaches, coastal cliffs, marsh,
   rock, orchards, wood density.
3. **Wreck litter board** (decision wreck-litter, open): sunken boats and planes in the
   water as environment, for character. After sinking lands: reuse the sunk-hull art,
   placed by seed; the board picks how many, where and which kinds.

## Later (planned, not fleshed out)

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

- 2026-10-11: two boards for Alex, nothing live changed. The range-of-motion indicator for every unit type (variants/motion-range/,
  decision motion-range-look, open; `planner.fan.mode`, today's 'ribs' the default; test_fan_modes). Shadows from the time of day
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
