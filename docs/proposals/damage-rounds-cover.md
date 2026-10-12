# Damage, rounds and lines of fire: three proposals to discuss (2026-10-11)

Alex asked to discuss these (decisions damage-looks, round-model, line-of-fire with tank-accuracy).
Everything below is PROPOSED by the lead. The facts come from `visual-feedback.md` and `shot-heights.md`.

## 1. How every thing shows damage (damage-looks)

Alex: "How does each unit/prop/structure manage its damage indicators? Right now bridges don't have
anything, that is fine. But let's figure out what might be appropriate defaults and how we can make sure
everything gets something decided? The latter could be in code or docs or skills, etc."

Every thing has four stages: **the hit** (the moment a round lands on it), **wear** (what stays as it
loses pips), **the end** (destroyed), **after** (what lasts on the map).

Today:

| Thing | Hit | Wear | End | After |
| --- | --- | --- | --- | --- |
| Planes (light, heavy fighter, bomber) | ink burst; tracer dot | smoke trail (W1) | explode, or fall and crash | crash column |
| Tank, mobile AA | ink burst | the planes' smoke | generic ruin | smoulder |
| AA battery, radio tower, hangar yard | ink burst | the planes' smoke | ruin (the tower's R1, else generic) | smoulder |
| Bridge | ink burst | the planes' smoke (the bug) | the bridge's ruin | |
| Cruiser, cutter, barge | ink burst | the planes' smoke | sink (decided) | wreck on the bottom |
| Trees | | | burn (decided) | trunks |
| Houses, walls, fields, props | not in the sim | | | |

Proposed: everything names a **material**, and each material has default looks for the four stages.
A thing overrides a stage only where it needs to.

| Material | Things | Hit | Wear | End | After |
| --- | --- | --- | --- | --- | --- |
| aircraft | the three planes | sparks, flecks | smoke trail, growing at half and a quarter | explode or fall | crash column; sinks on water |
| armour | tank, mobile AA | sparks, a dark puff | engine smoke from half health | brew-up: a flash, the hull stays, blackened | wreck smoke for a few turns |
| ship | cruiser, cutter, barge | a flash, a dark puff | deck smoke from half health | sink (decided) | wreck on the bottom |
| stone | the bridge, walls | dust, chips | cracks, then rubble at thresholds | ruin (decided for the bridge) | rubble |
| timber | houses, the tower's hut, the hangar yard | dust, splinters | holes, scorch | collapse, a chance of fire | burnt-out ruin |
| earthworks | the AA battery's sandbags | dust | bags scattered | ruin | crater |
| trees | trees | splinters, leaves | | burn (decided) | trunks |
| ground, water | the surfaces | dust and scorch / a splash | craters stay | | |

**Making sure everything gets one**: code, docs or skills.
- **Data**: every unit type and scenery kind names its `material` and any stage it overrides; the looks
  live in `data/fx/fx.json`, keyed by material and stage.
- **A test** (`test_damage_coverage`): it walks every unit type in `data/units/` and every scenery kind, and
  fails if one has no material, if a stage resolves to no look, or if a named look does not exist. A new
  unit cannot land without its damage decided.
- **Docs**: a "Damage" section in the Style guide (this table, once decided), and an "Adding a unit"
  checklist in `docs/operating.md` (material, looks, one shot per stage).
- **A skill** could walk the checklist later; the test already enforces it.

Recommendation: data plus the test plus the docs.

## 2. What a round is (round-model)

Today a weapon is a cone and odds; what it fires is only implied by its id (the tracers list).
Proposed: every weapon names its **round** (`data/sim/rounds.json`), and a round carries:

- **class**: bullet (machine guns), cannon round (the tank, the nose cannon), flak shell (bursts in the
  air), shell (the cruiser's Main Guns, an arc), bomb;
- **calibre**: small, medium, large. This sets the muzzle smoke and the impact's size;
- **explosive**: no (bullets) or yes (cannon HE, flak, shells, bombs): an explosion, or a strike of sparks
  and dust;
- **path**: straight (bullets, cannon), arc (shells, bombs), air burst at a height (flak);
- **tracer**: yes or no;
- **blast** (explosive rounds only): radius and pips, as shells and bombs have today.

A table of **round class x material** gives the impact look (the gunfire board fills it in): water always
splashes; an explosive round on ground leaves dust and a crater; a bullet on armour leaves sparks.

This settles: tracers (`tracer: yes`), flak bursts against tracers, the muzzle smoke's size, and the impact
look. For lines of fire (3) it sets what path a round takes and what can stop it. Later, not now: armour
and penetration (whether a bullet can hurt a tank) and damage per round.

## 3. Lines of fire (line-of-fire, option b; tank-accuracy)

Alex: "9 I want to discuss b", and of accuracy falling with range and rising with size: "11, yes but
directly impacts 9".

- **Blockers**: every one gets a shape and a height from the heights chart: terrain steps, houses, walls,
  sandbags, the bridge, trees, and units' hulls.
- **Straight rounds** (bullets, cannon) travel the line from the muzzle (at its height) to the aim point
  on the target (its centre height: a tank's about 1.2 m). A blocker whose top is above the line where
  the line crosses it is in the way.
- **The target is a shape, not a point.** The part the shooter can see sets the odds: the chance is the
  share of the round's spread that falls on the exposed target. Range and size come out of the same
  thing: a far, small target is hard, a near, big one easy (tank-accuracy), and a tank behind sandbags
  shows only its turret.
- **A miss lands somewhere real**: it carries on along its spread to the first thing it meets (a wall, a
  house, the ground, the water) and makes that thing's impact (round x material). This answers "missed
  shots should show where they land".
- **Arc rounds** (shells, bombs) ignore what is between and land on a point; cover between the blast and
  a unit could shield it later.
- **Planes**: high up, rarely blocked; the low band can be blocked by hills (Alex earlier: the low band
  is "the last height band that has some interaction with hills").
- **Sight** uses the same heights (the fog's viewshed today knows only the terrain steps).

Cost: a height map of blockers per chunk (houses, walls and sandbags rasterised; trees as canopies) and a
short march along the line per roll. That is cheap at our unit counts, deterministic (pure math on the
combat seed), and needs its own tests.

### Questions for Alex

1. A target fully hidden: does the gun still fire into the cover, or hold until it has a line?
   Proposed: hold when fully hidden; fire when partly exposed, with the misses landing on the cover.
2. Trees: block, thin (a chance per canopy to stop a round), or not at all? The decision trees-do-not-block
   is for sight "for now". Proposed: thin, for fire.
3. Hull-down (a tank behind sandbags or a wall shows only its turret, so it is hit less): proposed yes.
4. Houses and walls taking damage (with the damage looks of 1): proposed later.
5. The same rule between planes and the ground (lines over hills): proposed yes.
