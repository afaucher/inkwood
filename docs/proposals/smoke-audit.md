# Smoke audit: every smoke, dust and plume in the game, and what was made alike (2026-10-11)

Builder SMOKE, for decisions `smoke-consistency` and `impact-by-round-and-target`.

- Alex: "2 - yes, audit everything for smoke consistency. Not identical unless there is no reason to be different."
- Alex: "3 - yes, this should probably be a property of either the round or the thing being hit or both. Ex a round hitting water would splash, not explode with smoke. Right?"
- Alex, on the bridge: "Right now bridges don't have anything, that is fine."

Everything marked **FIXED** was changed by this track and is **PROPOSED** (a choice of the builder's, not Alex's, except where his words
are quoted). **KEPT** is a difference that stays, with its reason now written in the data. **OPEN** is for Alex.
The headless proof is `scripts/tests/test_smoke_consistency.gd`; the shots are `tmp/smoke/` (`scripts/app/smoke_shot.gd`).

## 1. The bridge's white disc, found again

`combat_feed.gd _leave_smoke` called `fx.emit_path(..., unit.def.size_m)` for every damaged unit, and a W1 puff is 0.34 to 0.8 of that
size in radius: a 40 m bridge got puffs 14 to 32 m in radius, a 120 m cruiser 41 to 96 m. They did not rise, and the air pass that
draws them sat UNDER every unit marker and shadow (`unit_ui.gd` mounted `fx` before the planner), so the tanks' shadows lay on the smoke.
`tmp/smoke/00_before_bridge_disc.png` reproduces it (the layer called with the old arguments).

## 2. The audit

Layers: **ground** = the effects layer's ground pass (under the planner and every unit), **shadows** = its shadow group (smoke's own ground
shadow, under the units), **air** = the air pass, **top** = the flash flipbooks (over the planes), **slot** = where the air pass sits now:
between the surface units' markers and the aircraft's (`UnitMarkerLayer.smoke_slot`, fx.json `smoke_model.layer`).
Wind: every puff drifts by the wind at its birth time times the integral of the wind's height factor over its climb (`fx_field.gd puff_drift`:
0.725 at the 2 m floor, 1.0 at 10 m, 1.64 at 120 m, 2.09 at 400 m, 2.19 from 500 m; data/sim/wind.json `profile`), plus a small per-puff spread.

| # | Source | Layer, before | Layer, now | Size of the source | Rise (m/s) | Wind lean | Colour roles | Life of a puff | Fog | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | Damage smoke of a ground or sea unit (tank, mobile AA, tower, battery, complex, cutter, barge, cruiser) | air, under all | **slot**; shadow in shadows | was 0.34-0.8 x `size_m`; now 0.34-0.8 x `damage_smoke.source_m` (3 to 8 m) | was 0; now 4.0 | yes, from the puff's height: it climbs, so it leans about 1.7 times as far in 20 s as a level puff | W1 `smoke.w.white/lgrey/grey`, 3 ages x 3 tones | 24-40 s (5 to 8 turns); one puff every 0.07-0.3 s | at emission (`_may_show` of the unit) | **FIXED**: layer, size, rise |
| 1a | The same on the bridge | air, under all | none | none: `damage_smoke.enabled` false | none | none | none | none | none | **FIXED**: per-unit switch (Alex: "bridges don't have anything") |
| 2 | Damage smoke of a plane (light, heavy, bomber) | air, under all | **slot**: over ground units, under every plane | was 0.34-0.8 x the span (9 / 16 / 20 m); now x 8 m for all three (Alex 2026-10-12: stays) | was 0; now 4.0 | yes, from its altitude and climbing (1.64 at the low band, 2.09 medium, 2.19 high) | W1 | 24-40 s | at emission | **FIXED**: layer, size, rise. Size and rise are **Alex's** (2026-10-12, 'Yes to both') |
| 3 | Out-of-control plane's fall trail (`ride`, kind "fall") | air, under all | **slot** | was the span; now the same 8 m engine (`source_m`, `source_back_m`) | was 0; now 4.0 (the engine's `rise_mps`) | yes, at the fall height | W1 via `select_crash_smoke`; tone 1, intensity 0.5 | 14 s, one per 0.09 s | at emission | **FIXED**: size (no jump at `down_at`); layer; rise (the trail it continues climbs, so no jump there either) |
| 4 | Mid-air explosion: smoke burst (9 puffs thrown 16-34 m/s), plume (7) | air, under all | **slot**; the flash flipbook stays in top | the airframe: `size_factor` = (span / 9)^0.75 x 9 m | burst 0, plume 0 | yes | W1 | burst 36 s, plume 40 s | at the event (`_may_show`) | **KEPT**: sized by the whole airframe that blew up (a property of the thing hit). Rise 0 was 'shared with the plane's own trail'; that trail climbs now, so this is the one plane smoke that does not: **OPEN** (question 6) |
| 5 | Crash on the ground: smoke burst (10), plume (11), smolder column (60 s of births), scar | air, under all; scar in ground | **slot**; scar in ground | the wreck: `size_factor` of the span | burst 3; plume was 0, now 3; smolder 4 | yes | W1 (crash smoke follows the damage smoke) | burst 40 s, plume 48 s, column puff 26 s | at the event; out of sight only the scar | **FIXED**: layer, plume rise. The rest **KEPT** (the thing hit is the airframe) |
| 6 | Bomb impact (B3): flash, smoke burst (7), plume (5), clods, crater | air, under all; crater in ground | **slot**; crater in ground | the ROUND's `blast_m` (45 m) x fractions | burst 2; plume was 0, now 2 | yes | W1 | burst 30 s, plume 34 s | the bomber's sight; out of sight only the crater | **FIXED**: layer, plume rise; **in water: a splash and nothing else** |
| 7 | Cruiser shell impact (the same function) | as 6 | as 6 | the shell's `blast_m` (20 m) | as 6 | as 6 | as 6 | as 6 | the shooter's sight | **FIXED** as 6, a smaller splash in water |
| 8 | Ruin of a destroyed ground or static unit (tower R1, battery, tank, AA, complex, bridge): flash, burst (12), end burst, plume (10), smolder (90 s of births), bars or clods, remains | air, under all; remains in ground | **slot**; remains in ground | the unit's `size_m` x its `effects_size_frac` (the complex's and the bridge's a share) | burst 3; plume was 0, now 3; smolder 4 | yes | W1 | burst 40 s, plume 48 s, column puff 28 s | at the event; out of sight only the ruin | **FIXED**: layer, plume rise. Sizing **KEPT** (the thing destroyed is the whole unit) |
| 9 | Flak burst (F2): flash flipbook, 2-3 ragged puffs | air, under all; flash in top | **slot**; flash in top | the burst's `size_m` 12 m (data) | 0.8 | yes, at the target's altitude | `flak.wash.*` ink washes (dark), not W1 | 14 s (x1.3 on a hit) | the target's sight | **KEPT**: flak is a dark powder burst in ink, Alex's F2 choice; a rise of 0.8 for an explosion at altitude (hot, small) |
| 10 | Forest fire column per burning tree (`fx_fire.gd`) | air + shadows, under all | **slot** (its `draw_air`); shadows stay | the tree's canopy x 0.6-1.0 (map metres, not the planes' drawn scale) | 20 m at birth, 24 m/s slowing (tau 10 s): 188 m at 12 s | yes: its own table of the same profile | W1 | 12 s (+1.5 s tail), one per 1.2 s | **per frame**, by the tree's place (`visible_at`) | **FIXED**: layer. Size, rise **KEPT** (a burning grove is a big hot source; a tree is map scenery) |
| 11 | Sinking: the down flash and the ink-ring splash | flash top; splash ground | unchanged | the unit's `size_m` x 0.7 (flash); x 0.8 (rings) | n/a | n/a | ink, `burst.core` | 0.8 s; 2.6 s + 0.6 | the unit's sight | **KEPT**; the rings are the stand-in for 6 and 7 in water |
| 12 | Not smoke, listed so it is not lost: hit ink bursts (`hit_marks.gd`, overlay), tracers (top), the bomb falling (top), wingtip ribbons (under the smoke), scar and crater ground marks, burnt trunks (the map) | | unchanged | | | | | | | **KEPT** |
| 13 | Flames and embers on a falling plane or a scar | top | unchanged | | | | | | | **OFF** (Alex: "No fire for now. Just smoke.") |
| 14 | Muzzle smoke, dust at a hit, a bridge's dust and cracks | | | | | | | | | **MISSING**: none exists (visual-feedback.md gap 2; the gunfire board GF; playtest-3 bridge_smoke 1) |

### What each puff is sized by, and why

A property of the **round** (a bomb's and a shell's blast), of the **thing hit** (an airframe's size, a ruin's unit) or of the **source on the
thing that smokes** (an engine deck, a funnel). It is never the length of a unit that merely smokes (decision impact-by-round-and-target).
Old and new puff radius, metres of the drawn scale (W1 `radius_frac` 0.34 at one pip lost to 0.8 at the last, +-20 percent a puff):

| Unit | size_m | Old radius | `source_m` | New radius |
|---|---|---|---|---|
| light fighter | 9 | 3.1-7.2 | 8 | 2.7-6.4 |
| heavy fighter | 16 | 5.4-12.8 | 8 | 2.7-6.4 |
| bomber | 20 | 6.8-16.0 | 8 | 2.7-6.4 |
| tank | 6 | 2.0-4.8 | 3 | 1.0-2.4 |
| mobile AA | 6.5 | 2.2-5.2 | 3 | 1.0-2.4 |
| radio tower | 12 | 4.1-9.6 | 3 | 1.0-2.4 |
| AA battery | 14 | 4.8-11.2 | 4 | 1.4-3.2 |
| military complex | 80 | 27-64 | 8 | 2.7-6.4 |
| cutter | 27 | 9.2-21.6 | 4 | 1.4-3.2 |
| barge | 34 | 11.6-27.2 | 4 | 1.4-3.2 |
| cruiser | 120 | 41-96 | 8 | 2.7-6.4 |
| bridge | 40 | 13.6-32 | none | none |

The heavy fighter's and the bomber's trails are now the light fighter's size (PROPOSED: one engine's smoke); they were two and two and a half
times as big. A board can pick other numbers: they are `data/units/*.json damage_smoke.source_m`.

## 3. What was made alike (all PROPOSED)

1. **Layer.** The air pass (every puff, the pieces in flight, the forest columns) is mounted in `UnitMarkerLayer.smoke_slot()`, between the
   surface units' markers and the aircraft's: smoke is over a tank, a boat, the bridge and their shadows, under every plane (a plane flies in
   front of its own trail, as it always did). The aircraft are now their own container in the marker layer, so a plane is over every ground
   unit whatever order a scenario lists them (the "tower over planes" misfit of the heights study is gone). Smoke's own ground shadow stays
   under the units. Data: `fx.json smoke_model.layer` (`above_surface_units`; `under_all` is the old order).
2. **Source.** `data/units/*.json damage_smoke` {`enabled`, `source_m`, `source_back_m`, `rise_mps`}, validated by `_schema.json` and
   `unit_def.gd` (a smoking unit has a source above 0; a non-smoking one has 0). `combat_feed.gd` reads it: no unit is a case in code.
3. **Rise and wind.** One model for all of it: a puff keeps its birth height, climbs at its rise and drifts with the wind at its height
   (`puff_drift`). Every unit's damage smoke climbs at 4 m/s, the smolders' rate, a plane's trail and its fall trail too (Alex, 2026-10-12, 'Yes to both'; `test_smoke_consistency` holds the numbers equal);
   the plumes of a crash, a bomb and a ruin climb like the burst thrown with them (they did not rise at all; `plume.rise_mps` in every
   option of `fx.json`).
4. **Bridge.** `damage_smoke.enabled` false. Dust at each hit, cracks and the ruin are open (playtest-3 bridge_smoke 1).
5. **Water.** A bomb or a shell that lands in water (the World's `water_depth_at` at least 0.5 m) is a splash of the sinking splash's ink
   rings, sized by the round's blast (x 0.35, at least 3 m), with no flash, smoke, clods or crater, and nothing to put back for a late joiner.
   Data: `fx.json impacts.water` (`look` `splash` or `burst`: the old look). The stand-in until the gunfire board picks the real looks.

## 4. Differences kept, and why (the reason is in the data it lives in)

- **~~A plane's trail does not climb~~ (ENDED, Alex 2026-10-12, 'Yes to both')**: it did not (`damage_smoke.rise_mps` 0 in the three planes' files),
  for the reason that a low plane is already in air 1.64 times the ground's wind and 4 m/s would lift an old puff by 100 m in its life; that was
  the weakest reason and the one place the ground and the air differed. A plane's damage trail and its fall trail now climb at 4 m/s, the
  ground smoke's rate, through the same model (`fx_field.gd puff_drift`); `test_smoke_consistency` holds the rate equal for every unit.
  What is left of the difference is the mid-air explosion's burst and plume (rise 0): question 6.
- **Flak is ink, not W1**: Alex chose F2, a dark ragged burst; fire's smoke is white to grey. Flak rises 0.8 m/s.
- **Forest columns** are in map metres and climb 24 m/s: a tree is map scenery, drawn at the map's scale, and a burning grove is a big hot
  source; a tank's or a wreck's smoke is drawn at the units' own drawn scale because the unit is.
- **Explosions are sized by what blew up** (the airframe, the ruin's unit, the round's blast), damage smoke by the source: the explosion
  consumes the whole thing, the damage only smokes from one place.
- **Sunk ships make no damage smoke** (decision ship-sinks); a damaged ship still afloat does (cutter 4 m, barge 4 m, cruiser 8 m).
- **Flash flipbooks stay in the top pass** (over the planes): a flash is a moment of light, not a body of smoke.
- **Smoke past the low band** (the forest plume reaches 188 m, the low band's planes are at 120 m) is still drawn under every plane: a
  per-puff sort by height is not built, and a plume that high is thin.
- **The wingtip ribbon** is under the smoke whichever way `marker.trails.under_smoke` is set now (the smoke is in the marker layer, above
  the ribbons): that flag's `false` setting no longer puts a ribbon over smoke. Left alone.

## 5. Questions for Alex

1. ~~A plane's damage trail does not climb and a tank's does. Make them alike, or keep the reason?~~ **ANSWERED (Alex, 2026-10-12): 'Yes to both'**: the planes' trails rise like ground smoke (4 m/s). Done.
2. ~~The heavy fighter's and the bomber's trails are now as big as the light fighter's (an engine's smoke, 8 m). Keep, or give them a bigger source?~~ **ANSWERED (Alex, 2026-10-12): 'Yes to both'**: they stay at 8 m. Done.
3. Fog and smoke already made. A trail left while you could see the plane stays on the map after the plane flies on out of sight; the forest's columns vanish with the fog (Alex: "No, fog should hide smoke."). Make the trails the same? **Recommend leave**: a trail you saw is a thing you remember, the fire is the tree's own state; the gate is at emission so no trail gives away where an unseen plane flew.
4. Water impacts are a stand-in (three ink rings). The real look is on the gunfire board (GF); nothing to decide until it is picked.
5. A damaged bridge could show dust at each hit and cracks (playtest-3 bridge_smoke 1). Not built: Alex said "that is fine" for now.
6. (new, 2026-10-12, PROPOSED) The mid-air explosion's smoke burst and plume still do not climb (the crash on the ground, a bomb and a ruin do, at 2 to 3 m/s). Its reason was 'the same as the plane's trail', which now climbs. Make it climb like the ground crash's burst (3 m/s)? **Recommend yes**: it is one value per crash option (`midair.smoke_burst.rise_mps` and `midair.plume.rise_mps`, kept equal by test_smoke_consistency).
