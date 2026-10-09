# Art direction plan: the asset catalog -- PROPOSED, not decided

Written 2026-10-09 for Alex's question of that day: how we prototype the art up, define the
asset catalog, and operate on it as a whole, so every drawn thing is made, judged, tuned and
changed together, in one style. Nothing here is built or decided. Built on
`palette-architecture.md` (roles, ramps, accents, invariants, swatch board) and
`decision-workflow.md` (boards in the build, deferred until a build runs). **(p) marks anything
the design doc does not say; `doc` marks a cell that quotes it.** At writing (16:15)
`reference/mockups/unit_sheet.html` does not exist yet; the plan assumes it as briefed.

## A. What the plan has to achieve

1. **Milestone 3's gate** (doc): set-piece mockups as if in-game screenshots, each showing
   landscape and unit diversity, settling unit scale (battleship vs plane) and the look of
   landscapes, units and effects. Gate: "Alex is happy with the art style."
2. **"Design every extension beyond the reference art, and a design for each unit"** (Alex):
   the eleven Extensions rows and the seven unit sheets; part B lists what they name or imply.
3. **One look** across terrain, structures, units, effects, UI and the topographic layer. The
   doc asks for each to be "in style"; the catalog makes "one style" checkable.
4. **The palette rule** (CLAUDE.md rule 6): every art choice is judged beside what it sits
   with; hue only for paper, ink, shadow and accents; lightness a ramp off paper; material
   is linework; no hex literal in draw code.
5. (p) So the unit of work is the catalog, not the asset: a board for one asset is a board
   for its neighbours, and a ramp change re-judges everything.

## B. The asset catalog

Legend. Roles use the palette proposal's vocabulary and are (p) throughout: `fill0/1/2` =
fill ramp off paper (wall / rock / object-roof); `shade0/1` = mix toward the shadow tint
(wall slope .30 / roof .42); `ink×k` = ink at line-weight step k; `ink@a` = ink at alpha a;
`acc:x` = accent (`side`, `fire`; `water` pending palette decision 1). Layers (p) are the
shadow height classes: ground, prop, structure, tree, tall, air (altitude band), sea. Zooms
(p): Z1 = prototype scale (canopy 19 px), Z2 = game default (open in the doc), Z3 = far /
topo. Status: `proto` = prototype generator exists; `port` = being ported in `scripts/`;
`sheet` = browser sheet in progress; `mock` = AI mock allowed; `--` = not started.

### Terrain (15)

| id | asset | source | roles | scale / layer | shadow | topo form (Z3) | status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| terrain.paper | paper ground | proto buildGround, buildGrain; port paper.gd, grain.gd | paper ±6% noise, ink specks, dirt@.15–.40 stipple | ground (doc: cached) | receives all, casts none (doc) | blank paper, grain kept (p) | port |
| terrain.road | road | proto buildRoad, drawRoad; port scene_gen.build_road | ink×0.8 ruts broken <.3, dirt stipple, pebbles | baked into ground (doc) | none | one ruled line (p) | port |
| terrain.rail | rail line (implied by trains) | road generator variant: two rails, sleeper ticks (p) | ink×0.8 | ground (p) | none | line with ticks (p) | -- |
| terrain.sea | sea surface (doc: Extensions) | new generator (p) | paper + ink@low ruled ripples + shade0 wash, OR acc:water: palette decision 1 | sea, h 0 (p) | casts none; receives ships, planes, bridges (p) | coastline only (p) | -- |
| terrain.shallows | shallows (doc) | sea generator, depth parameter (p) | as sea; ripple density by depth, ink@ stipple (p) | sea (p) | as sea | none (p) | -- |
| terrain.surf | surf line, shore meeting paper (doc) | new (p) | ink@ broken line along coast, fill2 fibre strokes (p) | ground edge (p) | none | the coastline (p) | -- |
| terrain.river | river and banks (doc) | new (p); water as sea | bank: ink×0.75 hatch, dirt stipple (p) | cut below ground (p) | banks receive bridge shadow (doc) | single line (p) | -- |
| terrain.bridge | bridge span (doc: "spans and their shadows") | new (p) | fill0 deck, ink plank lines, ink×1.15 edges (p) | structure, h ≈ wall (p) | prism onto water and banks (doc) | crossing tick (p) | -- |
| terrain.relief | mountains, elevation (doc: contours, hachures or shading, open) | new (p); input is component 5's height map | ink@ hachure or contours; shade0 wash on slopes away from sun (p) | terrain height field (p) | self-shadow via height-map shader (doc, proposed) | contour lines: the topo layer IS this asset (p) | -- |
| terrain.field | fields (doc: field patterns) | new (p) | ink@low ruled rows, ink×0.75 edges (p) | ground | none | none (p) | -- |
| terrain.hedgerow | hedgerows (doc) | tree generator at small canopy along a path (p) | tree roles | low tree, h ≈ .5 r (p) | short lollipop (p) | none (p) | gen exists |
| terrain.crops | crops as scatter (doc) | scatter brush, new stipple-row stamp (p) | ink@.55 stipple, dirt | ground | none | none (p) | -- |
| terrain.forest | forest: trees as scatter | proto buildTreeSprite, drawLobe, scallop, stamp; port demo_frame, scene_gen | fill2; ink×1.25 outline; ink@.88 ×0.85 rings; ink×0.75 ticks; ink@.55 stipple | canopy 19 px ±40%, 10% ×1.45, h = r×1.3 (doc) | silhouette stretched ≤2.4× + trunk line (doc) | hatch patch, no trees (p) | port |
| terrain.props | rocks, barrels, crates | proto buildPropSprite; port demo_frame crate | fill1 rock; fill2 barrel, crate; ink crack, hatch, stave | prop; h .8 / 1.5 / 1.3 × size (doc) | 3-step extrusion (doc) | none (p) | port |
| terrain.burnt | burnt ground (doc proposes burnt-out ground after fire) | new (p) | dirt@.40 dense stipple, ink hatch, no fill (p) | ground | none | none (p) | -- |

### Structures (9)

| id | asset | source | roles | scale / layer | shadow | topo form (Z3) | status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| struct.wall | wall, rampart: open, ring, divider | proto wallGeom, drawWall; port structures.gd, demo_frame | fill0 band; shade0 slope; ink×1.15 edges; ink broken crest; dirt stipple; pebbles | 16 px wide, h 12 px (doc) | prism (doc) | wall line (p) | port |
| struct.enclosure | rampart enclosure | proto makeFort; port make_fort | wall roles | 2.6 × brush (doc) | prism (doc) | ring outline (p) | port |
| struct.house | house: rect, L wing, gable, chimney | proto makeHouse, drawHouse; port house_parts | fill2 roof lit; shade1 roof shaded; ink×1.2 outline; ink planks, eave, ridge | 28 px, h .9 × size (doc) | prism (doc) | small square (p) | port |
| struct.town | towns at construction levels: hut, village, town, fortified town (doc) | house + wall generators with a level parameter, or one per level: decision F3 | house and wall roles | structure (p) | prism | settlement symbol sized by level (p) | -- |
| struct.aa_site | AA emplacement, the site (doc: Military sites); the gun is unit.aa_battery | new (p) | wall roles for a sandbag ring, dirt | low structure, h ≈ 4 px (p) | low prism (p) | site mark (p) | -- |
| struct.radio_tower | radio tower (doc: Military sites; also the example static unit) | new (p) | fill0 base; ink×0.75 lattice and guy lines (p) | tall, h ≈ 3 × house (p) | long thin line, like a trunk (p) | tower symbol (p) | -- |
| struct.depot | depot (doc) | house generator + prop barrels (p) | house, prop roles | structure | prism | square (p) | -- |
| struct.ruin | ruins (doc: Open design details) | house generator, damage parameter (p); pairs with fx.wreck | fill0; ink broken outline; dirt | low structure (p) | partial prism (p) | none (p) | -- |
| struct.fence | fences (doc: Open design details) | wall generator, width 2 px, no slope (p) | ink×0.75 only | h ≈ 3 px (p) | thin line (p) | none (p) | -- |

### Units (15 rows, 14 drawings)

Common to every unit (p, palette proposal 5): source = silhouette-as-data in metres (the unit
sheet) drawn by one unit drawer through the ink vocabulary; roles = fill2 body, ink×1.2
outline, material as linework (rivets: hatch + dot rows; canvas: stipple; decking: planks),
exactly one `acc:side` zone; topo form = one domain marker, enemies only when spotted.
Lengths are proposed starting figures. Only what differs is tabled.

| id | asset | silhouette (p) | length m (p) | layer | shadow | status |
| --- | --- | --- | --- | --- | --- | --- |
| unit.light_fighter | light fighter (doc roster) | single engine, short wings, roundel on wing | 9 | air, altitude band | silhouette offset by altitude ÷ tan(elev) onto whatever is below; gap = altitude cue (doc) | sheet |
| unit.heavy_fighter | heavy fighter (doc) | twin engine, longer nose | 12 | air | as above | sheet |
| unit.bomber | bomber (doc) | four engines, bomb-bay line, turrets as dot rows | 20 | air | as above, largest air shadow | sheet |
| unit.tank | tank (doc) | hull, turret ring, barrel; tracks as hatch rows | 7 | ground, h ≈ 2.5 m (p) | prism of hull (p) | sheet |
| unit.aa_battery | anti-aircraft battery (doc) | gun on mount, sits in struct.aa_site | 5 | ground (p) | small prism (p) | sheet |
| unit.small_cruiser | small cruiser (doc: sizes to be worked out) | hull, deck planks, superstructure, two turrets | 120 | sea; superstructure h (p) | hull + superstructure prism on water (p) | sheet |
| unit.radio_tower | radio tower, static unit (doc) | drawing is struct.radio_tower; adds an on/off state mark (p) | -- | tall | see struct | -- |
| unit.artillery | artillery battery (doc: future) | gun, trail legs | 8 | ground | small prism | -- |
| unit.supply_truck | supply truck (doc: future) | cab, canvas bed as stipple | 6 | ground | prism | -- |
| unit.train | train (doc: "potentially") | engine + cars on terrain.rail | 15 per car | ground | prism | -- |
| unit.civ_vehicle | civilian land traffic (doc) | car or cart; no accent (p) | 4 | ground | prism | -- |
| unit.civ_ship | civilian ship (doc) | fishing boat; no accent (p) | 15 | sea | prism | -- |
| unit.battleship | battleship hull, nest root (doc: later) | ≈ 25 × fighter (doc) | 250 (doc) | sea | prism; receives plane shadows | -- |
| unit.battleship_turret | weapon point, nest member (doc) | turret on the hull; nest shares one accent (p) | 15 | on hull | none of its own (p) | -- |
| unit.submarine | submarine (doc: Game concept) | surfaced: narrow hull; submerged: outline + wake only (p) | 70 | sea / below | surfaced prism; none submerged (p) | -- |

### Effects (8) -- all obey fast flash, very slow decay (doc)

| id | asset | source | roles | layer | timing | status |
| --- | --- | --- | --- | --- | --- | --- |
| fx.explosion | explosion | AI sheet for mockups, then procedural (doc); procedural form: stipple burst + short hatch strokes (doc, proposed) | ink@, acc:fire | above its target's layer (p) | flash, decay | mock |
| fx.fire | fire on trees and buildings | AI mock then procedural (doc); spreads over turns (doc, proposed) | acc:fire, ink hatch | at the burning object (p) | flash, then persists per turn (p) | mock |
| fx.smoke | smoke | AI mock then procedural (doc); puffs from the tree lobe generator (doc, proposed) | fill2 puffs, ink×0.85 scallop, shade0 underside (p) | above all but UI, drifts (p) | slow decay; blocks sight (doc) | mock |
| fx.muzzle | muzzle flash, tracers | procedural from the start (p): the doc names no AI for it | ink short hatch stroke, acc:fire tip (p) | firing unit's layer | flash, decay | -- |
| fx.splash | shell splash on water (naval set piece) (p) | procedural (p) | fill2 + ink@ ring, ripple rings on sea (p) | sea | flash, decay | -- |
| fx.wake | ship wake (doc: Ships and wakes) | procedural (p) | ink@low ruled V lines, fill2 fibre strokes (p) | sea, behind unit | persists while moving, slow decay (p) | -- |
| fx.damage_mark | damage mark on a unit (doc: UI table) | procedural (p) | ink scratch strokes, dirt stipple; stays as wear (p) | on the unit sprite | flash, decays to a persistent mark (p) | -- |
| fx.wreck | destroyed unit remains (p) | unit drawer, wreck variant (p) | fill0, ink broken outline, dirt | ground / sea | permanent | -- |

### UI layer (11) -- the doc's UI table is itself "proposed treatments"

| id | asset | source | roles | layer | status |
| --- | --- | --- | --- | --- | --- |
| ui.selection_ring | inked ring around the unit, health arc (doc) | new UI drawer, ink vocabulary (p) | ink×1.2 wobbled ring | UI, above all | -- |
| ui.leader_line | leader line to the floating panel (doc) | UI drawer | ink×0.8 | UI | -- |
| ui.unit_card | floating card: name, actions left, engagement (doc) | UI drawer; typography open (doc) | fill2 card, ink text (p) | UI | -- |
| ui.order_path | dashed path, drag handle, end-of-turn ghost (doc) | UI drawer | ink×0.8 dashed; ghost = unit drawer at ink@.35 (p) | map | -- |
| ui.health_pips | segmented pips on card, arc on ring (doc) | UI drawer | ink pips filled / empty | UI | -- |
| ui.special_icons | item icons, uses left, turns to reload (doc) | UI drawer | ink glyphs | UI | -- |
| ui.ready_markers | per-player ready-up markers (doc) | UI drawer | ink; a player accent is NOT in the palette: question for Alex (p) | HUD | -- |
| ui.mission_marker | mission target markers above both map layers (doc) | UI drawer | ink×1.2 glyph; accent or ink ramp: palette decision 2 | above topo and full render | -- |
| ui.roster_sidebar | roster sidebar: icon, pips, actions, readiness (doc) | UI drawer | paper panel, ink rows | HUD | -- |
| ui.overview_map | overview map in the topo style with markers (doc) | topo layer at Z3 + markers | topo roles | HUD | -- |
| ui.envelope | engagement envelope / sight arc while setting parameters (p) | UI drawer | ink@ dashed arc | map | -- |

### Topographic layer (5) -- a second render of the same terrain (doc)

| id | asset | source | roles | where | status |
| --- | --- | --- | --- | --- | --- |
| topo.contours | contour lines, no detail (doc) | from component 5's height map (p) | ink@.5 ×0.75; index contours ×1.0 (p) | outside vision and at Z3 (doc) | -- |
| topo.lines | coast, river, road, rail as single lines (p) | derived from terrain records | ink×0.8; coast ×1.15 (p) | topo | -- |
| topo.symbols | settlement, forest patch, tower, bridge, depot symbols (p) | the catalog's topo-form column, generated | ink, hatch patches | topo | -- |
| topo.unit_markers | unit and target markers on topo and overview (doc) | catalog topo-form for units | ink glyph per domain, acc:side (p) | above topo | -- |
| topo.fog_edge | where topo resolves into the full render near units (doc) | shader (p) | paper; ink@ stipple feather (p) | between layers | -- |

### Shadows (9)

| id | asset | source | layer | status |
| --- | --- | --- | --- | --- |
| shadow.pass | compositor: one mask per height class, tinted once, 92% (doc); height-map raymarch proposed (doc) | proto castShadows; port shadow_pass.gd, shadow_composite.gdshader | all | port |
| shadow.prop | 3-step extrusion (doc) | proto | prop | port |
| shadow.structure | prism: footprint hull + height-shifted copy (doc) | proto | structure | port |
| shadow.tree | stretched silhouette ≤2.4× + trunk line (doc) | proto | tree | port |
| shadow.plane | falls on whatever is below; nearer the plane when low (doc) | height-map shader (doc, proposed) | air | -- |
| shadow.ground_unit | tank, truck, AA, artillery: low prism (p) | unit drawer + shadow.pass | ground | -- |
| shadow.ship | hull + superstructure prism on the sea (p) | unit drawer + shadow.pass | sea | -- |
| shadow.terrain | relief self-shadow from the height map (p) | height-map shader | terrain | -- |
| shadow.bridge | span onto water and banks (doc) | shadow.pass prism | structure | -- |

Totals: 72 rows, 71 drawings. 11 have a prototype generator today (terrain paper, road,
forest, props; struct wall, enclosure, house; shadow pass, prop, structure, tree); hedgerow
can reuse one. Everything else is not started.

## C. How to prototype the art up (p)

From Bridge to Friendship's bake-off, what transfers: the readability contract (the rubric
in D), a frozen manifest of control renders (catalog manifest, board.json, seed 20261009),
sheets with one framing and a scale tick, a rubric scored before taste, a one-element
in-engine spike, generated images untracked and generators committed. What does not: six
whole styles, img2img and style anchors. Inkwood's style is chosen and its anchor is the
prototype; the question is coverage and consistency, and AI appears only in effects.

1. **Procedural sheets in the browser.** Medium: one HTML page per class
   (`reference/mockups/<class>_sheet.html`), the prototype's functions sliced in as
   `port_check` does; one seed, one sun, a 1 m tick per cell. The unit sheet is this stage
   for units. Proves: silhouettes, linework, palette consistency, unit size against a tree
   and a house at one px/m. Not: zoom, motion, shadows onto terrain, engine rasterization.
   Needs nothing from the plan. Hands forward: silhouette geometry as data, the role list
   per asset, px/m candidates (the doc's open scale question).
2. **Set-piece mockups**, milestone 3's deliverable. Medium: the browser; each of the four
   candidate set pieces composed from the prototype scene, the stage-1 terrain extensions
   (sea, surf, river, bridge, relief must exist as sheets first) and the unit sheet's
   drawers, at the game's viewport. AI only for fx.explosion, fx.fire, fx.smoke, as cut-out
   layers over the procedural frame, posterized to paper / ink / shadow / acc:fire before
   compositing (p) so they are judged in-palette; prompts and outputs under
   `reference/mockups/ai/<id>/`, never shipped. Proves the gate. Hands forward: the approved
   mockups as the control renders the engine is compared against.
3. **In-engine swatch board and variant boards.** Medium: the Godot build, `--run-board`
   from `decision-workflow.md`. Needs component 6 (render port, in progress), the style
   resolver and `ink_style.json` (palette proposal 1–3), then component 3. Proves the look
   at real zoom Z1–Z3 and in motion, shadows by height map, engine rasterization
   (ink_canvas's hairline rule makes 0.8 px lines differ from a browser). Decisions are
   taken and recorded here.
4. **One-element spike before committing.** Medium: Godot. unit.light_fighter from its data,
   through the unit drawer, with shadow.plane over the ported scene and terrain.sea, at Z2,
   moving: before the catalog goes to production and before milestone 5 replaces the AI
   effects. Proves data -> generator -> sprite -> shadow -> topo marker for one record. If
   it fails, the cost was a sheet, not a milestone.

## D. Operating on the catalog as a whole (p)

**Manifest.** `data/catalog/catalog.json`, one record per asset with the fields of B:

```
{ "id": "unit.light_fighter", "class": "unit", "doc": "Game concept > Initial unit roster",
  "source": { "kind": "silhouette", "generator": "scripts/render/units/unit_drawer.gd",
              "data": "data/units/light_fighter.json" },          // or data/catalog/unit/: F2
  "roles": ["unit.fill", "unit.outline", "unit.insignia"], "scale": { "unit": "m", "length": 9 },
  "layer": "air", "shadow": "shadow.plane", "topo": "topo.unit_markers",
  "status": "sheet", "boards": [], "decisions": [] }
```

Generated from it, never hand-listed: the swatch board's rows, each sheet's cells, the
whole-catalog render, and a gate test `test_catalog` (every role exists in `ink_style.json`,
every generator path exists, every `shadow` / `topo` value is a catalog id, every `built`
asset has a cell in the last render). `ai_mock` is a source kind only for `fx.*`, until the gate.

**Whole-catalog render.** `board.ps1 catalog` / `board.sh catalog` renders every `built` asset
under one style, seed 20261009, sun 315°/46°, at Z1, Z2, Z3, into
`variants/catalog/<date>/board.html`: rows = assets by class, columns = zooms plus the topo
form. The board records a hash of `ink_style.json` + `render_defaults.json`; a change to
either marks the last render stale and the next run regenerates it. Until the engine draws,
the stage-1 sheets are the catalog render, built from the same manifest.

**Rubric.** From Style rules, 0–2 per criterion per option, rules before taste: (1) ink sepia,
never black; (2) one shadow tint, merged, never darkened twice; (3) no gradients on objects;
(4) form from lines and cast shadow only; (5) paper, fills and shadows read as one drawing
under grain; (6) hue only in paper, ink, shadow, accents; (7) identity by silhouette and side
by accent at Z2; (8) altitude readable from the shadow gap; (9) topo form legible at Z3;
(10) effects flash fast, decay slow. A 0 on 1–6 disqualifies before taste. Scores go in
`board.json` as `scores[option][criterion]` with scorer and date; the swatch row is scored too.

**Review loop.** Alex sees `board.html` (grid, then pairs with blink) per open decision, each
board carrying the swatch row of that asset's neighbours at the same layer and zoom, with the
whole-catalog render as the standing first row. Cadence: 3–6 boards per review; the catalog
render at every phase review and after any style-file change. He answers per board (pick,
blend, new round) and for the catalog render: does it still read as one drawing, and which
cell breaks it if not.

**Propagation.** A ramp step, accent or line-weight step changes in `ink_style.json` only.
Then the invariants test runs, the catalog render regenerates, every `board.json` chosen
under the old style hash is flagged `re-judge`, and Alex sees one before/after grid of every
asset. A single asset's redesign is judged beside its swatch row and in situ in its set
piece, never alone; a rubric score below its class's median is a question, not a pass.

**Naming.** The catalog id `class.name` is the key everywhere: generator
`scripts/render/<class>/<name>.gd` (ported prototype routines keep their file and register
the id); data `data/catalog/<class>/<name>.json` (units: F2); boards
`variants/<id>-<question>/`; `decisions.json` records gain an `asset` field; sheets
`reference/mockups/<class>_sheet.html`; AI mocks `reference/mockups/ai/<id>/`.

## E. Order of work (p)

Decide first, because the rest reads them: (a) px/m and the zoom set Z1–Z3 (every sheet's
scale tick depends on it; the unit sheet picks one provisionally); (b) F1, AI in the mockups;
(c) palette decision 1, water, since the sea is in three of four set pieces; (d) F2.

1. Now, in the browser: catalog manifest v0 typed from part B; the unit sheet (in progress);
   a terrain sheet for sea, surf, river, bridge, relief, fields; AI effect mocks if F1 is yes.
2. The four set-piece mockups from those sheets; milestone 3 review; the gate.
3. In parallel: the render port (component 6, in progress) gains the style resolver,
   `ink_style.json` and the invariants test; then component 3 and `board catalog`.
   Component 4 (unit data model) reads the unit sheet's silhouettes once F2 is decided.
4. After the gate: components 5 and 7 build the terrain rows from their approved sheets; the
   unit drawer builds the six roster units; component 15 replaces the AI effects (milestone
   5), judged against the approved mockups.
5. The spike (C.4): go / no-go for catalog-wide production; every row then moves to `built`
   with its swatch cell and its board.

## F. Decisions for Alex

1. **AI-generated effects in the mockups.** Yes, posterized to the palette, fx.explosion /
   fx.fire / fx.smoke only (the doc's current line): the gate comes sooner, but it approves
   a look the procedural effects must then match. No, ink-mark effects procedural from the
   start: the gate waits on an effects generator, but what Alex approves is what ships.
2. **The manifest and the unit data model.** One record per unit, stats and drawing together
   (`data/units/<name>.json`): one place, but the simulation reads art fields. Two files
   linked by id (`data/units/` for play, `data/catalog/unit/` for drawing): clean
   separation, but ids can drift and `test_catalog` must police it.
3. **Towns at construction levels.** One generator with a level parameter (house count, size,
   wall ring): one board with a slider and consistency for free, but every level is the same
   town grown. One generator per level: each can have its own look, but four rows, four
   boards, and consistency rests on the rubric.
