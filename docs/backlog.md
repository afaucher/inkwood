# Inkwood backlog (for the next session's prioritisation)

Everything open as of 2026-10-12, gathered so Alex can evaluate and order it. Each item names its decision
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
