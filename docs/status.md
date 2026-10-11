# Inkwood: now and next

What is in flight and what is free to take. Update it when you claim, finish or
drop a track (see `docs/operating.md`, "Several agents at once").
Decisions and open questions live in the Decision Ledger
(https://claude.ai/artifact/AQtHN2PP9H9mnyRjsCMDjE) and `data/decisions/decisions.json`.

## Claims

| Track | Owner | Folders | Since |
| --- | --- | --- | --- |
| Draw the boats and the bridge in the game (item 1 below) | lead session (builder) | scripts/ui/unit_marker_art*.gd (boat and bridge dispatch only), new scripts/ui/unit_marker_art_boats.gd, scripts/fx/ (the bridge's ruin), data/ui/ui.json unit_art keys | 2026-10-11 |
| Build Hold the bridge (item 2 below) | lead session (builder) | data/scenarios/bridge.json, scripts/sim/mission.gd, scripts/app/main.gd selector, scripts/debug/debug_settings.gd scenario choices, scripts/test_support/bridge_*.gd, scripts/tests/test_bridge_mission.gd | 2026-10-11 |
| Camera controls: wheel zoom in toward the cursor and out about the centre (Alex); left-drag on empty map pans (Alex); then the map's border at full zoom-out (board) | camera session (beautiful-lumiere worktree) | scripts/world/camera_controller.gd, data/view/camera.json, scripts/tests/test_camera.gd; the left-press hand-over: a signal in scripts/ui/unit_ui.gd, one line in scripts/app/sandbox.gd, their checks in test_ui_target and test_sandbox | 2026-10-11 |

## Next, free to take

1. **Draw the boats and the bridge in the game**, replacing the stand-in arrows:
   the P1 cutter and S2 barge with the ink V wake at the planes' scale, the stone
   arch with a flat deck spanning the river at the road, and its ruin. The art
   already exists as board code: `scripts/render/boat_art.gd`, `bridge_art.gd`,
   `data/world/boats.json`, `bridges.json` (decisions boat-looks, boat-wake,
   bridge-look). Wire them into the marker layer (`scripts/ui/unit_marker_art*.gd`)
   and the effects layer's ruin.
2. **Build "Hold the bridge"** (decision bridge-mission): a seed search for a road
   bridge near the edge of the cruiser's gun range, `data/scenarios/bridge.json`
   (2 player tanks at the bridge, the cruiser offshore, enemy tank waves on the
   "drive" role with start turns), a "hold until turn N" win and an "enemy past this
   point" loss, a menu entry, a test. Needs the bridge drawn (item 1).
3. **A playtest build** with Strike, Suppress and (when built) Hold the bridge.
   build.ps1 closes a running game: ask Alex first.
4. **Terrain variety board** (decision water-layer): beaches, coastal cliffs, marsh,
   rock, orchards, wood density.

## Waiting on Alex (looks with working defaults)

- The tower's ruin (R1): Strike Boards. (Flak is decided: F2, the ragged burst.)
- Bombs' area of effect (D, tiers): Strike Boards.
- Fields (D, mixed).
- The drop picture and target marks, and static units at twice the plane scale:
  built for playtesting, not chosen.

## Recently landed

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
