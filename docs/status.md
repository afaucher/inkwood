# Inkwood: now and next

What is in flight and what is free to take. Update it when you claim, finish or
drop a track (see `docs/operating.md`, "Several agents at once").
Decisions and open questions live in the Decision Ledger
(https://claude.ai/artifact/AQtHN2PP9H9mnyRjsCMDjE) and `data/decisions/decisions.json`.

## Claims

| Track | Owner | Folders | Since |
| --- | --- | --- | --- |
| Draw the boats and the bridge in the game (item 1 below), and sinking (decision ship-sinks: a destroyed ship, and a plane that comes down over water, fall through the water to the floor) | lead session (builder) | scripts/ui/unit_marker_art*.gd (boat and bridge dispatch only), new scripts/ui/unit_marker_art_boats.gd, scripts/fx/ (the bridge's ruin, the splash), data/ui/ui.json unit_art keys; for sinking: the fall functions in scripts/sim/world.gd, the sea-unit fate in scripts/sim/combat_resolver.gd, sink keys in data/sim/combat.json | 2026-10-11 |
| Machine-gun tracers: a board and a working default (proposed) | lead session (builder TR) | new scripts/fx/fx_tracer*.gd and its hook in fx_layer.gd/fx_field.gd; data/fx/fx.json tracers; variants/tracers/; scripts/tests/test_tracers.gd | 2026-10-11 |
| Board: the range-of-motion indicator for every unit type (no live change until Alex picks) | lead session (builder BM) | variants/motion-range/; scripts/ui/boards/motion_range_board_shot.gd; a mode switch in the fan's drawing in scripts/ui/motion_planner.gd (today's look the default); data/ui/ui.json planner.fan keys | 2026-10-11 |
| Board: shadows from the time of day (no live change until Alex picks) | lead session (builder BS) | variants/sun-time/; a new board shot script; the sun's direction and length in data and their readers (ui_style.gd, fx_style.gd, scripts/render/ink_structs.gd shadow_dir), today's sun the default | 2026-10-11 |
| Forest fire (decision forest-fire): trees burn as smoke, spread by distance, low damage nearby, smoke denies tracking, burnt down to trunks; tried in Suppress | fire session (nice-dewdney worktree) | new data/sim/fire.json, scripts/sim/fire*.gd, scripts/tests/test_fire*.gd; the fire step and its net state in scripts/sim/world.gd (and the snapshot in scripts/net/world_sync.gd); burnt cover in scripts/sim/concealment.gd, data/sim/concealment.json; smoke denies tracking in scripts/sim/spotting.gd, bombs.gd (followed aim), scripts/ui/ui_target.gd and the enemy-click lines of scripts/ui/unit_ui.gd; new scripts/fx/fx_fire*.gd and its hook in fx_field.gd/fx_layer.gd; per-chunk rebake in scripts/render/map_view.gd, chunk_terrain_provider.gd; data/scenarios/suppress.json (fire on); a fire knob in scripts/debug/debug_settings.gd | 2026-10-11 |
| Camera controls: wheel zoom anchors and left-drag pan (landed); right-drag pan removed, panning stops at the map's edge (Alex); the map's border board (builder) | camera session (beautiful-lumiere worktree) | scripts/world/camera_controller.gd, data/view/camera.json, scripts/tests/test_camera.gd; the board: scripts/render/map_border*.gd, data/view/map_border.json, scripts/ui/boards/map_border_board_shot.gd, variants/map-border/, scripts/tests/test_map_border.gd, and a one-line hook in scripts/render/map_view.gd | 2026-10-11 |
| Side view: top, front and side as folding strips, an arcs button in the panel, map cones off by default (Alex, decision side-view-views) | camera session (builder) | scripts/ui/side_view*.gd, scripts/tests/test_side_view.gd, data/ui/ui.json side_view keys and planner.cones.shown; the arcs default's knock-on in tests that expect cones (test_cone_overlay, test_ui_*) | 2026-10-11 |

## Next, free to take

1. **Draw the boats and the bridge in the game**, replacing the stand-in arrows:
   the P1 cutter and S2 barge with the ink V wake at the planes' scale, the stone
   arch with a flat deck spanning the river at the road, and its ruin. The art
   already exists as board code: `scripts/render/boat_art.gd`, `bridge_art.gd`,
   `data/world/boats.json`, `bridges.json` (decisions boat-looks, boat-wake,
   bridge-look). Wire them into the marker layer (`scripts/ui/unit_marker_art*.gd`)
   and the effects layer's ruin.
2. **A playtest build** with Strike, Suppress and Hold the bridge.
   build.ps1 closes a running game: ask Alex first.
3. **Terrain variety board** (decision water-layer): beaches, coastal cliffs, marsh,
   rock, orchards, wood density.
4. **Wreck litter board** (decision wreck-litter, open): sunken boats and planes in the
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
