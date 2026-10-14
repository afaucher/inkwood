# Inkwood backlog (for the next session's prioritisation)

Everything open as of 2026-10-13, gathered so Alex can evaluate and order it; to be taken on Wednesday 2026-10-14 (Alex). Each item names its decision
in `data/decisions/decisions.json` where there is one. "Rec" is the lead's recommendation, PROPOSED.
What is in flight right now lives in `docs/status.md`; what is decided lives in the Decision Ledger.

## A. Decided, ready to build

1. **Lines of fire and lines of sight on by default** (line-of-fire; Alex, 2026-10-12: "we want lines of
   fire and lines of sight turned on by default"). Lines of fire: flip `data/sim/line_of_fire.json`
   enabled, re-tune the missions' scripted tests, and let G3's misses take the real landing points
   (`scripts/ui/gunfire_feed.gd _land`). Lines of sight: `data/view/fog.json` vision.line_of_sight is
   "none" today; turning it on brings the viewshed's cost (see C1). Expect far fewer tank hits, trees
   screening most of the map (each canopy stops a line 35% of the time, proposed), a bridge that is hard
   to hit (only its parapets stand up).
2. **Labels by unit type** (Alex, 2026-10-12): ships and tanks drop the altitude ("0 m"); planes keep
   altitude and speed. Whether ships or tanks have another critical number goes to C/B later. The roster's
   "flying the turn" is its status line for every unit while a turn plays back; it should read right for
   surface units too ("moving", or nothing).
3. **Damage looks by material** (damage-looks, model accepted, wear later): every unit and scenery kind
   has a material; the hit, the end and what lasts come from the material's defaults; a
   `test_damage_coverage` that fails when anything has none; an "Adding a unit" checklist in
   `docs/operating.md` and a Damage section in the Style guide.

4. **The fourth playtest's asks** (playtest-4, Alex's words in its notes; build 2026-10-12.145115):
   - Hold the bridge: the cruiser starts pointing east-west, along the coast; the enemy tanks start outside
     line of sight.
   - Ships (any unit) fire without moving: a **hold** step that keeps the unit's point and counts as planned,
     so a special can be set on it.
   - The orders card shows only the actions that apply: no Dive or Climb for ships and tanks.
   - The tank's gun becomes its special, quick to fire again (about a 1 turn reload).
   - Labels: every number carries its unit ("12 m/s", not "12"); surface units drop the altitude (A2).
   - Views: show specials too; a filter (a funnel icon) picks what the three views show, and the map when
     the arcs are on; a small scale bar with one distance label.
   - Controls: holding Space readies you, 1 s if every unit has actions, 2 s otherwise; selecting an
     already-selected unit or target deselects it.

5. **The tank's firing feedback, NEXT** (tank-fire-feedback, Alex 2026-10-13): the muzzle smoke from the
   barrel's tip; the turret turns to its bearing and fires only once it has it; a recoil, the whole tank
   rocking back or only the turret (a small board). The turret's turn delays the shot IN THE SIM (a traverse
   rate; Alex: "so the timing is variable during the turn"); the tank's gun becomes its special at the
   same time (A4). The same turret feedback applies to the ship (Alex): the cruiser's turrets turn to
   their bearing before the salvo, smoke from the barrels' tips, a recoil.

6. **The movement indicator always on top** (planner-on-top, Alex 2026-10-13: "I think we always want it to show
   on top for the player"). A tank's path over the bridge vanishes under the bridge: `scripts/ui/unit_ui.gd` adds
   the MotionPlanner before the marker layer, so every marker (the bridge is one) draws over it. The same cause hid
   the cruiser's range of motion under its own hull. Fix: the planner and the bomb aim above the markers.

7. **The old hit mark goes** (no-ink-marks, Alex 2026-10-13: "Generally I don't like the ink mark indicators,
   lets not propose them again"). The "3 lines crossed" Alex saw in the fourth playtest are most likely it: 7 ink
   strokes round a dot on a unit when it is hit (`scripts/ui/hit_marks.gd`), 3.2 s and held while paused, on top
   of G3's own impact. Turn it off (`ui.json combat.hit_mark.enabled` false) and fix the tests that count it.
   The T5 tracers lose their hit dot and miss tick too (Alex: "The tracer itself is fine. The dot and miss tick
   are not."): `fx.json tracers.options.T5.marks` hit_dot_px and miss_tick_px 0. The Main Guns' fire mark
   goes too (D8).

8. **Bolder plan indicators** (plan-indicators-bold, Alex 2026-10-13: "much bolder to be visible. There is too
   much visual noise to see a thin dashed lines and tiny dots"). Today (`ui.json planner`): the path 1.6 px dashed
   6 on 5 off, nodes 3 px, the other units' plans 1.0 px lines and 1.9 px dots at 0.55 alpha, the range's rim
   0.9 px. A board of weights on a busy map (forest, village, smoke; the start zoom and close in): 2x to 3x lines,
   solid against dashed, a paper halo under the ink, bigger nodes; the other units' plans a step quieter.

## B. Needs a decision (with a recommendation)

1. **The ship's gun range** (Alex: "might be too long. Let's look at it?"). Today the Main Guns reach
   3,000 m, 600 m inland, shells at 250 m/s (12 s of flight at full range: more than two 5 s turns), reload
   2 turns. Against a tank's 350 m and flak's ~900 m, 3 km is most of a map section. Rec: a short study
   (what each range does to Hold the bridge's play, what a turn of flight time feels like) before
   choosing a number.
2. **Tracers beyond machine guns** (tracers-mg, Alex reconsidering: "putting tracers on everything or at
   least where there's not already an indicator like bombs"). Today only bullets draw tracers; cannon
   rounds show a muzzle puff and an impact but nothing in flight. Rec: tracers for every direct-fire round
   without another in-flight mark (the tank gun, the nose cannon), not for bombs or shells.
3. **Tails for big, slow ordnance** (Alex: "should big slow ordinance have a tail. Just like planes").
   Shells and bombs in flight are specks today. Rec: a short ink ribbon behind shells and falling bombs,
   the planes' ribbon grammar, on a board.
4. **Night shadows**: with the night folded onto the day, any start from 20:30 to 03:30 gets the longest
   shadows (the 2x cap). Rec: spread the night so every hour differs and only midnight reaches the cap.
5. **A special for the tank** (13): aimed fire at a chosen target, now that lines of fire exist. Rec: yes,
   after lines of fire are on.
6. **The views card on small windows** (14): at 1280 x 720 with three units it is left out. Rec: fine for
   now.
7. **Trees' screening strength** (line-of-fire): 35% per canopy makes most off-road ground "partly
   screened". Rec: playtest with lines of fire on first.
8. **Bridge durability with the low bridge**: only the parapets can be hit now, so Hold the bridge's
   "the bridge falls" loss almost never happens. Rec: decide after a playtest with lines of fire on.
9. **Mid-air explosion smoke** (smoke audit question 6): it still does not climb like the other smoke.
   Rec: make it climb.
10. **The heights misfits** (`docs/proposals/shot-heights.md`): eye heights per domain (the 25 m tower sees
    from 2.5 m), the altitude bands absolute while shadows and fog use the ground, deep water drawn at -30 m
    against a sea to -70 m, the battery's flak muzzles (3 and 6 m) against its art (1.35 to 4.2 m), the shell
    arc drawn up to 360 m. Rec: one pass, each as a data fix.

11. **Rivers** (playtest-4): "pretty straight right now". Rec: a board of river shapes (meanders, a
    fork, an oxbow) with the terrain variety board (D6).
12. **The tank's gun as a special** (playtest-4): does the tank still fire on its own when no special is set,
    or only when ordered? Rec: only when ordered, since that is what makes it a special; the 1 turn reload
    keeps it busy.
13. **Water splashes** (Alex 2026-10-13: "far too big and the style is inconsistent"). Three looks are live:
    a ship or plane going under draws three ink rings (`data/world/boats.json game.sunk.splash`, never on a
    board); a bomb or a shell landing in water borrows those same rings as a stand-in, sized 0.35 x the blast
    and then drawn at the planes' enlarged marker scale (`fx.json impacts.water`; a bomb rings out to about
    13 m before that scale); a tank or nose-cannon round in water draws G3's pale ring and ripple (Alex's G3).
    The only board with choices is the Gunfire Board's row i, "a shell in the river", one look per family
    (G1 to G4; https://claude.ai/artifact/KVvixkLBkFiq4mqEL4Dgba). Rec: one splash for everything in water,
    in the soft puffs (Alex 2026-10-13, soft-puffs-default: "I like the look of the soft puffs as a default
    impact style"): a pale puff of spray, no ink rings, sized by the round's calibre at the map's true scale; a
    small board of sizes before it lands.
14. **The military complex's fit** (Alex 2026-10-13, after Suppress: "the building we designed doesn't quite
    match the style of the houses in color scheme and it doesn't quite fit into the sandbag complex we built for
    it. The alignment doesn't match and the size doesn't quite match either. Lets figure out how to improve our
    complex design to be more consistent and more natural looking."). A study first (why the colours, the angle
    and the size disagree), then a board of complex designs beside the village's houses. Findings: below when the
    study lands.
15. **The fog's edge** (Alex 2026-10-13: "How expensive would it be to smooth the edge of the fog of war? It
    currently looks pretty blocky."). Found (read-only study): with sight circles (today's default) the mask is
    exact per screen pixel; the blockiness is the inked edge's wobble, a value noise that is flat at every
    lattice point, so a big circle comes out as straight runs with a kink every ~55 px
    (`scripts/render/fog_composite.gdshader`, `fog.json edge.inked.wobble_px 2.5, wobble_per_px 0.018`), plus a
    hard 1 px cut and hatch ticks of random length. Fix, at no measurable frame cost: a smoother noise (gradient
    noise or a second octave) and a cut softened over 2-3 px (a new `edge.inked.cut_soft_px`). With lines of sight
    on (A1) the edge is ALSO stepped by the rays (the nearest ray is picked, about 8 m apart at 800 m, at half the
    screen's resolution: `fog_los_shape.gdshader`); interpolating between the two nearest rays is nearly free,
    more rays or a full-resolution mask cost 2x the sweep or ~8x the distance pass. Rec: the two free fixes with
    A1, shown on a small board.

## C. Bugs and engineering debt

1. **Line of sight's cost**: a viewshed sweep costs 6-12 ms for a plane and 36-65 ms for a ground unit
   among cliffs (GDScript, 800 m). It is recomputed when a unit moves 8 m or changes height by 2 m, so it
   scales with the number of MOVING units; it is sliced to a 4 ms per-frame budget, so a moving unit's fog
   edge trails it rather than hitching. It is the fog mask's cost only; lines of fire are separate (about
   0.3 ms for a tank's exposure). Measure with LOS on in a full mission before shipping it on.
2. **A crash at exit**: a Village held in `GroundMap.shared`'s static cache crashes the engine's shutdown
   (0xC0000005 after a test's pass marker). Worked round in two tests, not fixed.
3. **Tuning tables' dice**: `Combat.roll_seed` XORs the game seed with the turn, so sweeps over small
   sequential seeds see few distinct dice streams. The tuning helpers should spread their seeds.
4. **Lines of fire details**: planes seen steeply are under-sized (the silhouette is the vertical face);
   the shared grid's stamps follow whichever World resolved last; hedges, burnt trees and the sandbag
   ring's gap are not modelled.
5. **Board images in git's history** (about 520 MB before they were untracked). Removing them means
   rewriting history and a force-push over every session's work: only on Alex's word.

## D. Looks still open (boards)

1. The tower's ruin (R1 the working default).
2. The bombs' area of effect while planning (D, tiers, the working default).
3. Fields (D, mixed).
4. The drop picture and target marks; static units at twice the planes' scale (built for playtesting,
   never chosen).
5. Wreck litter: sunken boats and planes in the water as scenery (wreck-litter).
6. Terrain variety: beaches, coastal cliffs, marsh, rock, orchards, wood density (water-layer).
7. The forest fire's look (forest-fire; the fire session deferred it).
8. **The Main Guns' fire mark** (no-ink-marks, Alex 2026-10-13: "The main guns fire mark is not, we need a better
   option"). Today, while planning, a step with fire on draws a dashed line from its node to the target, a ring at
   the shells' two-sigma scatter and an X at the target (`motion_planner.gd _draw_fire_marks`, `ui.json guns.marks`).
   A board of options with no symbol marks (PROPOSED directions: the scatter as a soft wash in the motion range's
   wash-and-rim grammar; the shells' arc from the ship to the target; the landing area drawn as the splash or dust
   it will raise, faint), beside the target selection's own mark so the two do not double up.

## E. Later (planned, not fleshed out)

1. Wear patterns for everything (damage-looks): what stays visible as a thing loses pips.
2. Houses and walls taking damage (line-of-fire).
3. Armour and penetration, damage per round (round-model).
4. A general player-side AI (general-ai).
5. Fighter strafing (strafe-later); low planes already hit ground units with turrets (air-to-ground-low).
6. Bailing out: sight follows the pilot (sight-follows-pilot).
7. The cruiser's hidden range indicator: a control point in front of the ship (cruiser-fan).
8. The cover map as a player tool, in the views card or while planning.
9. Tanks and ships have no ribbon tail (their half-span is 0), and with the badges gone they are hard to
   find at the opening zoom.
10. The enemy AI never uses specials.
11. A turn preview that never reveals enemy plans (turn-preview).
12. The wind moves only smoke (coastal-wind).

## F. Project questions (from CLAUDE.md)

1. GDScript, carried over from Bridge to Friendship; C# never weighed.
2. The renderer: Forward Plus, carried over from a 3D game; Mobile or Compatibility may suit a 2D game.
3. Steam during tests: the runners do not set `INKWOOD_STEAM=off`. Rec: set it off in the runners
   (a build-script change, so only on Alex's word).
