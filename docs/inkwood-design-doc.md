<!--
SNAPSHOT of the live design doc, exported 2026-10-09 (doc revision 50).
The LIVE DOC is the source of truth; this file is a convenience copy for grepping and offline reading:
https://claude.ai/code/artifact/5cdc9f22-2f23-41a5-9196-c0370d346d2e
Re-export rather than edit: changes belong in the live doc.
-->

# Inkwood Design Doc

2026-10-09 · @Alex

## Overview

Inkwood is Alex's planned co-op, turn-based tactics war game, drawn in a hand-inked, top-down parchment map style. A working browser prototype (Inkwood Renderer) now covers paper, trees, props, a road, walls, enclosures, houses, a scatter brush and a merged shadow pass; the next step is porting it to Godot with Claude Code.

This doc records what Alex asked for, what he approved, and what is only proposed so far. Space is held at the end for design details not yet decided.

| Date | Item | Status |
| --- | --- | --- |
| 2026-10-09 | Networked co-op is required, including in the demo | Said by Alex |
| 2026-10-09 | Join model from Bridge to Friendship: Join connects to the first global Steam game it finds; one game, ideal for the test group | Said by Alex |
| 2026-10-09 | Plan the sandbox demo: key components, what runs in parallel, how they interact and depend on each other; demo has a tiny bit of movement and combat, not a whole mission, and part of the environment variety | Said by Alex |
| 2026-10-09 | Design every extension beyond the reference art, and a design for each unit | Said by Alex |
| 2026-10-09 | Interactive, iterative workflow: compare variants to decide quickly, build in parallel, detailed review; hand off to Claude Code, not executed yet | Said by Alex |
| 2026-10-09 | Renderer parameter tuning not yet done; carried over into the workflow | Said by Alex |
| 2026-10-09 | Execution plan structure (19 components, 4 tracks, 3 phases, variant boards) | Proposed |
| 2026-10-09 | Visual scale on zoom-out is unresolved; may limit zoom-out and have players scroll the map | Said by Alex |
| 2026-10-09 | An interactive overview map the player can set their view from | Said by Alex |
| 2026-10-09 | A right-hand sidebar summarizing all controlled units, with different ways to sort and group them | Said by Alex |
| 2026-10-09 | Battleships as a nest of units (ship plus one unit per major weapon point); tentative line: multiple specials means a nest | Said by Alex |
| 2026-10-09 | Turn length and when units get more or fewer actions still to decide; static units like radio towers have an on/off action, no movement, one action per turn | Said by Alex |
| 2026-10-09 | Particles designed in style: fast flashes with a very slow decay, for a deliberate motion | Said by Alex |
| 2026-10-09 | Persistent HUD and in-game overlays in style, floating above the game and reaching down to indicators around units; work through selection, orders, status, health, limited-use items, damage and more | Said by Alex |
| 2026-10-09 | The reference screenshots come from the Might of Merchants developer, who shares techniques publicly; use as a reference, not to copy, reaching a similar style through procedural generation that fits Inkwood's requirements | Said by Alex |
| 2026-10-09 | A plane's shadow shows on whatever it flies over and sits closer to the plane near the ground, as a visual altitude cue | Said by Alex |
| 2026-10-09 | Shadows by vertical height: lower layers always receive shadows from higher layers, with light-source offsets | Said by Alex |
| 2026-10-09 | Units spread across the environment in sensible locations: tanks patrolling forests, aircraft circling key targets, anti-aircraft around key targets or at choke points such as peninsulas | Said by Alex |
| 2026-10-09 | Level generation with a global topography that makes sense and local terrain that is interesting | Said by Alex |
| 2026-10-09 | Environmental effects like fire affect fog of war; bombing a forest makes it burn and can create opportunities | Said by Alex |
| 2026-10-09 | Milestone: a playable prototype with a basic sandbox environment for testing, as one of the first things | Said by Alex |
| 2026-10-09 | Enemy AI pursues specific mission goals and takes secondary opportunities; behaviors like patrol, engage on spotting, and disengagement criteria; examples in Alex's other repos | Said by Alex |
| 2026-10-09 | The game uses Godot; the Bridge to Friendship project is the example for setup | Said by Alex |
| 2026-10-09 | Alex's Robo Rally clone (co-op, turn-based; on his GitHub and likely local) is the reference for co-op turns | Said by Alex |
| 2026-10-09 | No unit belongs to any player; players share the fleet and divide the work socially, which supports drop-in, drop-out play | Said by Alex |
| 2026-10-09 | All active players ready up to commit a turn | Said by Alex |
| 2026-10-09 | Future units: artillery batteries, supply trucks, potentially trains; small amounts of civilian land and sea traffic; no civilian aircraft | Said by Alex |
| 2026-10-09 | Initial units: anti-aircraft batteries, tanks, light fighter, heavy fighter, bomber | Said by Alex |
| 2026-10-09 | Only a small cruiser-type ship for now | Said by Alex |
| 2026-10-09 | Battleships should read as very large compared to a plane on screen; ship sizes to be worked out for the island-nation setting | Said by Alex |
| 2026-10-09 | Mock up example set pieces as in-game screenshots showing landscape diversity and unit diversity | Said by Alex |
| 2026-10-09 | Use generative AI for explosions in mockups; switch to procedural once the art style is approved | Said by Alex |
| 2026-10-09 | Add this intent to the initial milestones | Said by Alex |
| 2026-10-09 | Unit actions are steering, airspeed, and selecting special weapons and abilities; the turn is a planning mode for trying options, with optional simulation (details deferred) | Said by Alex |
| 2026-10-09 | Faster units generally get more actions per turn, set per unit type | Said by Alex |
| 2026-10-09 | Maybe: promotion grants an extra action once a unit has a kill | Said by Alex |
| 2026-10-09 | Premise: co-op, turn-based tactics war game in a steampunk World War II, on an island with bridges, roads and varied construction | Said by Alex |
| 2026-10-09 | Players together control one small unit (planes, ships, submarines, tanks); each unit gets one or more actions per turn | Said by Alex |
| 2026-10-09 | Fire is set through engagement parameters, not direct targeting; long-reload special weapons, like a bomber's bomb, are triggered by hand | Said by Alex |
| 2026-10-09 | Height limits sight lines and engagement envelopes; aircraft change elevation, and diving adds speed and can hide behind mountains | Said by Alex |
| 2026-10-09 | Fog of war: a rough topographic map resolves to the full render near units; target markers drawn above both layers; terrain, trees and buildings block sight | Said by Alex |
| 2026-10-09 | Scenarios with different win conditions, such as a strike mission or a tank infiltration across a contested bridge or river | Said by Alex |
| 2026-10-09 | Steambirds as a key reference, free to draw from other games | Said by Alex |
| 2026-10-09 | Use the prototype artifact to transfer the code to Godot through Claude Code | Said by Alex |
| 2026-10-09 | Write a design doc covering everything so far, with space for further design details | Said by Alex |
| 2026-10-09 | Build the rampart and wall generator next (delivered with enclosures and houses) | Approved, built |
| 2026-10-09 | Build a quick HTML prototype of the tree generator and flat shadow pass | Approved, built |
| 2026-10-09 | Focus on rendering rules, steps and procedural algorithms; enumerate everything to build before starting | Said by Alex |
| 2026-10-09 | Extract the key elements and drawing rules of the reference style to build a renderer in HTML5 or Godot | Said by Alex |
| 2026-10-09 | Make a video game that uses this art style | Said by Alex |
| 2026-10-09 | Height-map shader as the method for the height-based shadows in Godot | Proposed |
| 2026-10-09 | Rougher rubble and scrub edge texture on walls | Proposed |

Alex confirmed Godot as the game's engine. The Bridge to Friendship project is the example for project setup, and his Robo Rally clone is the reference for co-op turns.

## Milestones

The next milestone is art direction: mock-up screenshots of example set pieces that settle unit scale and the look of landscapes, units and effects.

1. **Renderer prototype** — done. Inkwood Renderer version 2 in the browser.
2. **Design doc** — done; kept up to date as decisions land.
3. **Scale and set-piece mockups** — next. Mock up example set pieces as if they were in-game screenshots, each showing landscape diversity and unit diversity. Work out ship sizes so battleships read as very large next to a plane. Explosions and other effects come from generative AI for now rather than procedural code. Gate: Alex is happy with the art style.
4. **Playable sandbox prototype** — one of the first priorities. A basic sandbox environment for testing gameplay, with a first enemy AI to play against: a tiny bit of movement and combat, not a whole mission, covering part of the environment variety. Planned in detail under Execution plan.
5. **Procedural effects** — after the art gate, replace the AI-generated effects with procedural ones that match the approved look.
6. **Godot port through Claude Code** — planned; the sandbox prototype is in Godot, so the two likely overlap.

Only milestone 3 is confirmed as next; the order of 4 to 6 is not set.

### Candidate set pieces (proposed)

- Bomber strike on a fortified harbor town: light bombers and fighters over roads, walls, houses and anti-air positions.
- Tank infiltration across a contested bridge and river, through groves and an enclosure.
- Naval engagement off the coast: a small cruiser near the shore under air attack, planes overhead for scale.
- Mountain pass: aircraft diving behind ridges, showing height and sight lines.

## Execution plan: sandbox demo

The target is a playable sandbox demo: a small world with a tiny bit of movement and a tiny bit of combat, not a whole mission, covering at least part of the environment variety. The plan below is a proposal for Claude Code to carry out after review; nothing in it has been built yet.

- Work runs in parallel tracks: design, world and rendering, simulation, and UI.
- Design decisions are made iteratively by comparing variants side by side, then logged here.
- Build tracks read decisions from data (parameters and unit definitions), so a later decision changes configuration rather than code.
- A detailed review gates the end of each phase and the demo itself.

### Build plan

*[Diagram in the live doc: "sandbox demo build plan · 4 tracks, 3 phases, then integration" -- not exportable to markdown]*

Design decisions run a step ahead of the build in every phase; all four tracks feed one assembly step, then a detailed review before the demo counts as done.

### Components and dependencies

Nineteen components reach the demo. Everything in phase 1 can start at once; within each later phase, components run in parallel once their dependencies land.

| # | Component | Track | Depends on | Phase |
| --- | --- | --- | --- | --- |
| 1 | Godot project setup, modeled on Bridge to Friendship | World | — | 1 |
| 2 | Port utilities: seeded RNG, noise, hull, splines | World | 1 | 1 |
| 3 | Variant board tool: show 3–6 options side by side from one seed | UI | 1 | 1 |
| 4 | Unit data model: stats, actions per turn, engagement parameters, specials, nests | Simulation | 1, unit sheets | 1 |
| 5 | Island terrain and height map: island shape, elevation, coast, rivers | World | 2 | 2 |
| 6 | Ink ground renderer port: paper, trees, roads, walls, houses | World | 2, tuned parameters | 2 |
| 7 | Water, coast and bridges | World | 5, 6, environment designs | 2 |
| 8 | Turn loop: plan, ready-up, resolve, actions per turn | Simulation | 4 | 2 |
| 19 | Networked co-op over Steam: Join connects to the first global game found, as in Bridge to Friendship; shared turn state and ready-up | Simulation | 1, 8 | 2 |
| 9 | Selection ring, order path, unit card | UI | 4, 8, UI look | 2 |
| 10 | Height-layered shadows, including plane shadows | World | 5, 6 | 3 |
| 11 | Line of sight and fog of war | World | 5, 8 | 3 |
| 12 | Movement: steering, airspeed, altitude | Simulation | 5, 8 | 3 |
| 13 | Combat: auto-fire from engagement parameters, damage, one manual special (the bomb) | Simulation | 8, 11 | 3 |
| 14 | Enemy AI: patrol, engage, disengage | Simulation | 12, 13 | 3 |
| 15 | Effects: AI-generated explosion sheets, fast-flash slow-decay particles, fire and smoke | World | 1, effects look | 3 |
| 16 | Roster sidebar and overview map | UI | 5, 9 | 3 |
| 17 | Sandbox world assembly: one island area, a few units per side, short fights | Integration | all above | 4 |
| 18 | Detailed review of the demo | Integration | 17 | 4 |

Networked co-op is required in the demo. It follows Bridge to Friendship: Join connects straight to the first global Steam game it finds, which suits Alex's test group playing a single game.

### Design work

Two design backlogs feed the build: everything the game needs that the reference art does not show, and one design sheet per unit.

#### Extensions beyond the reference art

| Area | What needs designing |
| --- | --- |
| Water and coastline | Sea surface, shallows, surf line and how shore meets paper |
| Mountains and elevation | How height reads in ink (contours, hachures or shading) and how it pairs with the height map |
| Rivers and bridges | River banks, crossings, bridge spans and their shadows |
| Fields and farmland | Field patterns, hedgerows and crops as scatter |
| Towns and construction levels | Building variety from huts to fortified towns |
| Military sites | Anti-aircraft emplacements, radio towers, depots |
| Ships and wakes | Hull drawing at cruiser scale, wakes on water |
| Aircraft | Top-down plane drawing, altitude shown through shadow offset |
| Fire, smoke and explosions | AI-generated sheets for mockups, then procedural to match |
| Topographic map layer | The rough map shown outside vision and at far zoom |
| UI layer | Floating cards, leader lines, rings and order paths |

#### Unit design sheets

Each unit gets one sheet, decided through variant boards.

- **Role** and how it plays in a mission
- **Silhouette and ink treatment**, with variants to compare
- **Size** against the other units and the terrain
- **Height layer or altitude band**
- **Speed range and actions per turn**, plus turn agility
- **Weapons and engagement envelope**, and the engagement parameters players can set
- **Specials**: uses, reload in turns, manual or automatic; more than one special makes the unit a nest
- **Health and armor**
- **Sight range** and what blocks it
- **Shadow behavior**
- **UI card contents**

Sheets to write: light fighter, heavy fighter, bomber, tank, anti-aircraft battery, small cruiser, plus a radio tower as the example static unit.

### Decision workflow

Decisions are made by looking at variants side by side, so Alex can choose quickly while the build tracks keep moving.

1. **Open a variant board.** For each open decision, Claude Code renders 3–6 variants from the same seed: parameter sets, unit silhouettes, UI looks, or effect sheets.
2. **Choose.** Alex picks one, asks for a blend, or asks for a new round.
3. **Log it.** The choice and its exact parameters go into the decision log in this doc; the other variants are archived, not deleted.
4. **Apply it.** The choice lands in data files the build tracks already read, so parallel work picks it up without code changes.
5. **Review.** A detailed review closes each phase: visual check against the style rules, a play check of what was built, and a code review.

#### Carried over

- Parameter tuning of the renderer prototype has not been done yet. The first variant board covers it: tree size and detail, shadow length and strength, line weight, wobble and grain.
- Nothing in this plan is executed yet; it waits for Alex's review before Claude Code starts.

## Game concept

Inkwood is a co-op, turn-based tactics war game set in a steampunk World War II, on an island with bridges, roads and settlements at different levels of construction.

### Units and control

- Players together command one small unit: planes, ships, submarines, tanks and similar.
- Each turn, every unit gets one or more actions.
- Fire is not aimed directly. Players set engagement parameters and weapons engage on their own.
- The exception is special weapons with long reload times, which players trigger by hand. Example: a bomber's machine-gun turrets fire automatically, but the player drops the bomb.

### Turn actions

- A unit's actions are steering, setting airspeed, and selecting special weapons and abilities.
- The turn is a tactical planning mode: players try out different options before committing.
- Players might even simulate the planned turn before committing. Details deferred.
- Faster units generally get more actions per turn, but the count is set per unit type.
- Possible promotion: a unit gains an extra action once it has a kill.

### Compound units

- A battleship may be a nest of units: one unit for the ship itself and one unit for each major weapon point.
- Reason: the largest battleships would effectively have several specials.
- Tentative dividing line: a single unit has at most one special; anything with several specials becomes a nest.
- Proposed: each weapon-point unit keeps its own engagement parameters, special and actions, moves with the ship, and is lost if the ship is lost.

### Turn length and action counts

- Still to decide: how long a turn is, and when units get more or fewer actions in it.
- Static units such as radio towers have an on/off action but no movement, so they naturally get one action per turn.
- Proposed: fix each turn at a set span of simulated time and give each unit type a number of decision points within it, so fast aircraft get several, tanks fewer, and static units one.

### Co-op and turns

- No unit belongs to any player. All players share the whole fleet and divide the work of managing it socially.
- Shared ownership makes drop-in, drop-out play easy: players can join or leave without units being reassigned.
- Every active player readies up to commit the turn; the turn resolves once all active players are ready.
- Alex's Robo Rally clone, a co-op turn-based game, already solved this shared-ownership problem and is the reference for it.

- Networked co-op is required, including in the sandbox demo. Joining works as in Bridge to Friendship: Join connects straight to the first global Steam game it finds. One game at a time suits Alex's test group.

### Enemy AI

- Enemies have specific mission goals and pursue them.
- They take secondary opportunities as those present themselves.
- Behaviors are built from states and criteria: for example patrol, engage when an enemy is spotted, and disengage when disengagement criteria are met.
- Alex's other repos hold examples to draw on.
- Proposed: enemy units use the same engagement parameters as player units, so the AI decides goals and movement while firing follows the shared rules.

### Level generation

- Levels need a generation scheme with a global topography that makes sense and terrain that is locally interesting.
- Proposed: generate in two scales. A global pass lays out the island shape, mountain ranges, rivers running downhill to the sea, and a road network between settlements, with bridges where roads cross rivers. A local pass fills each area with groves, fields, walls and buildings using the scatter and structure generators from the prototype.

### Enemy placement

- Levels spread different unit types across the map in locations that make sense.
- Examples: tanks patrolling through forests, aircraft circling key targets, and anti-aircraft units placed around key targets or at geographic choke points such as peninsulas.
- Proposed: the global generation pass marks key targets and choke points, and placement rules per unit type read those marks. Each placed unit starts with an Enemy AI goal (patrol route, circling orbit, or guard position) that matches where it was put.

### Environmental effects

- Environmental effects such as fire should change the battlefield, including fog of war.
- Example: bombing a forest sets it burning, which can open additional opportunities.
- Proposed: fire spreads through trees and buildings over turns, smoke blocks sight lines while it lasts, and burnt-out ground stops hiding units.

### Height

- Height is a dynamic element: it limits sight lines and engagement envelopes.
- Aircraft can change elevation for different effects. Diving gives a temporary speed boost and can hide a plane behind the tallest mountains.

- A plane's shadow falls on whatever it flies over (ground, trees, buildings, ships) and sits closer to the plane the nearer it flies to the surface below. The gap between plane and shadow is the player's visual altitude cue.

### Fog of war

- Fog of war is the main limit on what players know.
- Players have a rough topographic map that resolves into the fully rendered map within some distance of any of their units.
- Map indicators for mission-critical targets may sit on top of both layers, drawn in the same art style.
- Trees, buildings, hills and mountains can all block sight lines, so elevation shapes fog of war.

### Scenarios

- Players can play different scenario types with different win conditions.
- Examples: a strike mission with light bombers and fighters; a tank infiltration across a contested bridge or river.

### Scale

- The setting is an island nation, so naval units matter and ship sizes need to be worked out.
- Battleships should read as very large compared to a plane on screen.
- Proposed starting point: true proportions already give that effect. A WWII battleship is roughly 25 times a fighter's length (about 250 m against 10 m; approximate figures).
- Open question: at the prototype's tree scale (a canopy about 38 px across), a true-scale battleship would be wider than a phone screen. Units, terrain and buildings may need separate scales.

### Initial unit roster

Six unit types for now; battleships and other ships wait until later.

| Unit | Domain | Notes |
| --- | --- | --- |
| Light fighter | Air |   |
| Heavy fighter | Air |   |
| Bomber | Air | Turret guns engage on their own; the bomb drop is manual |
| Tank | Ground |   |
| Anti-aircraft battery | Ground |   |
| Small cruiser | Sea | The only ship for now |

### Future units and traffic

- Later units: artillery batteries, supply trucks, and potentially trains.
- Small amounts of civilian traffic: land vehicles and ships.
- No civilian aircraft.

### Renderer impact (proposed)

- The game needs a height map for sight lines anyway, so the height-map shadow shader and line-of-sight checks can share it.
- The rough topographic map is a second render of the same terrain (contour lines, no detail) that the full render replaces inside each unit's vision.
- Target markers are a third layer drawn above both, in the same ink style.

### Reference game: Steambirds

Alex named Steambirds as a key inspiration, with room to draw on other games too. Its core loop matches Inkwood's premise closely: plan a path, end the turn, watch every aircraft move at once while guns fire on their own.

Steambirds began as a 2010 Flash game by Andy Moore, with graphics and design by Daniel Cook, sponsored by Armor Games ([TIGSource](https://www.tigsource.com/?p=20262)). Semi Secret Software ported it to iOS on November 10, 2010 ([TouchArcade](https://toucharcade.com/?p=53299)). Spry Fox and Halfbrick followed with Steambirds: Survival in 2011 ([TouchArcade review](https://toucharcade.com/2011/10/19/steambirds-survival-review/)).

| Mechanic | How Steambirds does it | Use in Inkwood |
| --- | --- | --- |
| Turn structure | Players plan during a pause, press End Turn, then all aircraft, enemies included, move together for a couple of seconds before the next pause | Same plan-then-resolve loop; in co-op, every player commits orders before the shared resolve |
| Movement planning | A line from each plane's nose shows how far it travels this turn; dragging its arrowhead bends the path. Range and agility cap distance and turn sharpness | One path handle per unit; aircraft add a climb or dive control |
| Firing | Automatic whenever an enemy is in range in front of the plane | Matches Inkwood's engagement parameters, which add player-set rules on top |
| Special moves | Original: one or two abilities per plane, usable every other turn, such as a tight 180° turn or a gun-jamming gas. Also limited-use special paths that fly farther or defend | Long-reload special weapons that players trigger by hand, like the bomber's bomb |
| Power-ups (Survival) | Earned by shooting enemies down: super-speed, bombs, homing missiles, 180° turn, 360° attack, shields, poison gas | Candidate pool for special weapons and one-off abilities |
| Plane roles (Survival) | Each plane rates health, weapons, speed, agility and armor. The Buster is a bomber with weak guns; the Looper has strong guns and weak armor | A stat sheet per unit type, with clear role trade-offs |
| Missions and scoring | 21 missions at launch; briefings include attacking a sky fortress and defending London. Stars rate damage taken; some missions cap the number of turns | Scenario win conditions, with turn limits as pressure |
| Setting | Cold fusion discovered about a century early powers "super-steam" weapons on WWI and WWII planes and zeppelins | Close to Inkwood's steampunk World War II |

Inkwood layers on what Alex specified beyond this: co-op control of one shared unit, ground and sea units alongside aircraft, height as a tactical axis, and fog of war shaped by terrain. Other reference games are still to be chosen.

## UI and HUD

The game needs a persistent HUD and in-game overlays, all in the map's style. Alex's starting idea: UI that looks like it floats above the game and reaches down into it, for example with indicators around units.

Use cases named so far: unit selection, issuing orders, unit status, health, limited-use items and damage. More will come up as the list is worked through. The treatments below are proposed starting points, not decisions.

| Use case | Proposed treatment |
| --- | --- |
| Unit selection | An inked ring drawn around the unit on the map, with a leader line up to its floating panel |
| Issuing orders | A dashed ink path from the unit with a drag handle at the end; airspeed and altitude set along the path; a faint ghost of the unit at its end-of-turn position |
| Unit status | A floating card above the map, tied to the unit by its leader line: name, actions left this turn, engagement setting |
| Health | Segmented pips on the card, echoed as a short arc on the selection ring |
| Limited-use items and special weapons | Icons on the card with uses left and turns until reload |
| Damage | A brief ink mark on the unit when hit, following the fast-flash, slow-decay rule; pips drop on the card |
| Turn ready-up | A marker per active player in the persistent HUD showing who has committed |
| Mission targets | Markers drawn above both map layers, as already set under Fog of war |

### Camera, zoom and overview map

- Visual scale is an open problem: it is not clear the render will hold up as the player zooms out for a long-distance view.
- Zoom-out may need a limit, with players scrolling around the map instead.
- An interactive overview map lets the player set their view from it.
- Proposed: at far zoom, switch to the rough topographic style already planned for fog of war, so ink detail never shrinks into noise. The overview map uses the same style, shows unit and target markers, and a tap or click on it moves the main view there.

### Unit roster sidebar

- A sidebar on the right summarizes every unit the players control.
- It offers different ways to sort and group the units.
- Proposed rows: unit icon and name, health pips, actions left this turn, and special-weapon readiness. Selecting a row selects the unit and centers the view on it.
- Proposed groupings: by domain (air, sea, ground), by unit type, by nest (a battleship with its weapon points), and by status such as needs orders, ordered, or damaged. Proposed sorts: health, actions left, distance from the view. A "needs orders" view helps co-op players split up the work.

## Reference

The style comes from six screenshots Alex shared of a short video by Hannes Breuer, captioned "I added a new brush for objects". Its on-screen cards name three brush features: set brush size, set density, use collision check.

Alex traced the screenshots to the developer of [Might of Merchants](https://quillpeak.itch.io/might-of-merchants), a hand-drawn, top-down medieval trading game by solo developer Quill Peak, who posts openly about techniques on [Reddit as u/mightofmerchants](https://www.reddit.com/user/mightofmerchants/). The itch.io page lists Godot as its engine, the same engine Inkwood uses. Its [press kit](https://www.moddb.com/games/might-of-merchants/presskit) also mentions seasons, weather and a day and night cycle.

Intent: Might of Merchants is a reference, not a template. The goal is not to copy it but to reach a similar style through procedural generation that fits Inkwood's own requirements.

| Frame | What it shows | Style rule taken from it |
| --- | --- | --- |
| Rampart enclosure | Rounded-rectangle earthwork with a dividing wall and an inner ring, trees across it, long blue shadows | Walls are raised, cast shadows into courtyards; tree shadows fall across wall tops |
| Set density | Trees thinning inside a gray brush disc | Brush has a density control |
| Painted grove | Dense field of trees, a building among them, a curving road | Trees cluster; buildings sit inside groves; roads are rut lines |
| Set brush size | A diagonal stroke of trees of mixed sizes | Brush radius sets the stroke width; sizes vary per tree |
| Prop scatter | Barrels, crates and rocks scattered over a red grid | Small props are scattered; the red grid is a placement/collision grid |
| Use collision check | A road drawn through control points, avoiding trees and a building | Paths are splines with editable control points; placement respects collisions |

Observed across all frames: parchment ground with speckle and dirt stipple, sepia ink linework, cream object fills, no shading gradients on objects, and one flat steel-blue shadow color where overlaps merge.

## Style rules

The look rests on two rules: sepia ink on cream fills, and one flat, merged blue shadow projected by height. Everything else is texture and scatter.

### Palette

| Role | Hex | Notes |
| --- | --- | --- |
| Paper ground | #D9CCAA | Modulated ±6% by low-frequency noise |
| Ink | #3D3226 | Sepia brown; never pure black |
| Object fill (trees, barrels, crates) | #EFE6CD | Flat cream, no gradient |
| Wall / earthwork fill | #E2D7BA | Slightly darker than object fill |
| Rock fill | #E4D9BD |   |
| Roof, lit half | #EBE5D2 |   |
| Roof, shaded half | Shadow color mixed 42% into roof | Ties roof shading to the shadow tint |
| Dirt stipple | #5D5140 | Dots at 15–40% opacity |
| Shadow (default "Steel") | #3D6C8F | Alternates in prototype: Ink #2C4A66, Teal #3E7A7C, Umber #6A5843 |

### Linework

- Top-down orthographic view. Objects have no shading gradients; form comes from ink lines and cast shadows only.
- Base line weight 0.8 px, scaled per element: tree outline 1.25×, tree inner rings 0.85×, cusp ticks 0.75×, wall edges 1.15×, house outline 1.2×, road ruts 0.8×.
- Hand wobble: contours are displaced by low-frequency noise (default 0.6), so no line is geometrically perfect.
- Broken lines: inner rings, rut lines and wall crest lines drop segments where a noise value falls under a threshold.
- Interior detail (tree florets, stipple) is lit from a fixed top-left direction, independent of the sun. This is a prototype choice, not something read from the reference.

### Light and shadow

- One sun for the whole map. Default azimuth 315° (NW), elevation 46°.
- Shadow length = object height ÷ tan(elevation), cast directly away from the sun.
- All shadows of a height class render into one mask, are tinted once, then composited at 92%. Overlaps merge; they never darken twice.
- Tree canopies cast their silhouette, stretched along the shadow direction by up to 2.4× at low sun. Trunks cast a thin line from the base to the canopy shadow, giving the "lollipop" shadows in the reference.
- Walls and houses cast solid prism shadows (footprint plus its height-shifted copy).
- Vertical height decides where shadows land: anything on a lower layer always receives shadows from higher layers, offset by the light direction. Today tree shadows fall across walls, and wall shadows fall into courtyards and over props.

### Paper

- Ground = noise-tinted base, ink specks and paper fibres, and dirt stipple patches driven by a noise field.
- A full-screen grain texture is multiplied over the finished frame at 55% so ink, fills and shadows read as one drawing.

### Particles and effects

- Particles need a look designed to sit in style with the rest of the map.
- Timing rule: fast flashes, then a very slow decay. An effect appears almost at once and lingers as it fades.
- The slow decay gives the style a deliberate motion and keeps the screen from feeling busy.
- Proposed: draw particles as ink marks (stipple bursts, short hatch strokes, smoke puffs built from the tree generator's scalloped lobes) rather than glowing sprites, in palette colors plus one warm accent for fire.

## Render pipeline

A frame is ten passes drawn bottom to top. Shadows are split by height class so each class's shadow lands on everything lower than it.

1. **Paper ground** — noise-tinted base, specks, fibres, dirt stipple. Cached; rebuilt only on resize or ink changes.
2. **Road** — rut lines, edge stipple and pebbles, baked into the ground cache.
3. **Prop shadows** — props extruded along the shadow direction into the mask, tinted, composited.
4. **Props** — rocks, barrels, crates.
5. **Structure shadows** — wall and house prism shadows; these cover props and courtyards.
6. **Walls and houses**.
7. **Tree shadows** — trunk lines plus stretched canopy silhouettes; these fall across walls and props.
8. **Trees** — sorted by height, then by y.
9. **Grain overlay** — multiplied over the whole frame.
10. **Debug: collision grid** — red cell lines and occupied cells, off by default.

Known limit of this order: a tree's shadow never lands on another tree, and nothing shadows a roof except trees. The height-map shader proposed for Godot removes both limits.

## Systems

Eight of the ten systems from the original build list exist in the prototype; the ink stroke renderer is partial and the map infrastructure is not started.

| System | Status | Prototype functions |
| --- | --- | --- |
| Paper and ground | Built | buildGround, buildGrain |
| Ink line renderer | Partial: contour wobble only | scallop, drawRoad, drawWall |
| Tree generator | Built | buildTreeSprite, drawLobe, scallop |
| Prop library | Built: rock, barrel, crate | buildPropSprite, makeProp |
| Road / path | Built: fixed spline, no editor | buildRoad, drawRoad |
| Walls and enclosures | Built | wallGeom, drawWall, makeFort, rrectLocal |
| Houses | Built | makeHouse, houseParts, drawHouse |
| Scatter brush and collision | Built | stamp, canPlace, gAdd, gQuery, sDist |
| Shadow system | Built: per-class masks; height-map version proposed | castShadows, hull |
| Map infrastructure | Seeded RNG only; chunking and save/load not started | mulberry32, vnoise, fbm |

### Paper and ground

- Base color from two fbm layers (scale 0.008 and 0.0025) computed at one-third resolution and upscaled smoothly.
- About one speck or fibre per 90 px²: 85% tiny ink dots, 15% short fibre strokes in ink or light cream.
- Dirt stipple: dots placed where a third noise field exceeds 0.58, with density rising above that threshold.
- Grain: per-pixel random near-white texture with rare darker flecks, multiplied over the frame.

### Ink line renderer

- Today wobble comes from displacing each contour with noise, and breaks come from thresholded noise along the path.
- Still to build: one shared stroke routine with width variation, tapered ends and slight alpha falloff that every system draws through.

### Tree generator (rosette canopy)

- A tree is 3–7 outer lobes plus one crown lobe on top. Outer lobes sit 0.36–0.50 r from center with radius 0.34–0.50 r; the crown is 0.48–0.58 r.
- Lobes are drawn far-from-light first, crown last, so lit lobes overlap shaded ones.
- Each lobe's outline is a scallop: r(θ) = R · (1 − a + a · |sin(nθ/2 + φ)|^0.55), giving rounded bumps with inward cusps. Bump count n ≈ 4.5 + R/3; amplitude a = 0.13–0.25 per bump.
- Inner contour rings (default 3): smaller scallops shifted toward the light, each bump drawn with 80% probability so rings read as broken florets.
- Short ticks run from about half the cusps toward the lobe center; ink stipple dots fill the side away from the light.
- Size: canopy 19 px ± 40%, 10% of trees 1.45× larger. Height = radius × 1.3 × (0.85–1.15).
- Each tree is rendered once to a cached sprite keyed on its size and ink settings.

### Prop library

- Rock: 7-vertex jittered polygon, one crack line, three hatch strokes on the lower right. Height 0.8 × size.
- Barrel: circle, inner ring at 0.64, one stave line. Height 1.5 × size.
- Crate: square, inset square, one diagonal. Height 1.3 × size.
- Mix is 50% rocks, 30% barrels, 20% crates, each with random rotation.

### Road

- Catmull-Rom spline through five fixed control points, sampled every 3 px with a normal per sample.
- Two wheel ruts, each three parallel lines at ±7.2, ±9 and ±10.9 px, plus two faint edge lines at ±16 px. Lines wobble with noise and break where noise falls under 0.3.
- Dirt stipple concentrated toward the center; pebbles scattered just outside both edges.
- The reference shows a control-point road editor; the prototype does not have one yet.

### Walls and enclosures

- A wall is a centerline plus a width. The centerline comes from a rounded rectangle, a straight divider, or a freehand stroke smoothed with two passes of Chaikin and resampled every 3 px.
- Both edges are offset from the centerline with independent noise, filled as one band (even-odd for closed rings).
- Detail on the band: a tinted strip and hatch strokes on the slope facing away from the sun, stipple denser toward the edges, a broken double crest line at ±24% of the half-width, and pebbles sitting on both edges.
- Open walls get round caps; dividers get flat ends that overlap the ring's inner edge so the T-junction merges.
- Enclosure generator: rounded rectangle (depth 0.55–0.65 of width), a divider at 6–20% left of center, and an 80% chance of a low inner ring in the left cell (half width, 45% height). Size follows the brush.
- Defaults: width 16 px, height 12 px.

### Houses

- One rectangular part (1.3–1.8 × 0.72–0.87 of house size), with a 60% chance of a perpendicular wing that makes an L.
- Gable roof: ridge along the long axis. Each roof half is shaded if its normal points away from the sun.
- Detail: plank lines across each half, a thin eave line inset 1.3 px, the ridge line, and a chimney on 60% of houses.
- Default house size 28 px; height 0.9 × size × (0.85–1.15).

### Scatter brush and collision

- Brush stamps when the pointer moves 30% of the brush radius, and every 110 ms while held still.
- Each stamp throws darts uniformly in the brush disc; the dart count scales with density × brush area ÷ object area, capped at 40.
- With collision check on, a dart is rejected if it overlaps another object (spatial hash, 32 px cells), the road, or a wall or house (signed distance).
- Collision radius: tree 0.72 r (so canopies may touch and overlap a little), prop 1.25 × size.
- Placing a wall, enclosure or house removes trees and props under it.
- Erase removes objects within the brush and structures within half the brush radius.

### Shadow system

- Built: one offscreen mask per height class (props, structures, trees). Silhouettes are drawn in solid black, projected by height, the mask is tinted with the shadow color in one fill, then composited.
- Prisms use the convex hull of each footprint segment and its shifted copy.
- Required: vertical height determines where shadows are cast, and lower layers always receive shadows from higher layers, with offsets from the light source. Proposed method for Godot: render a height map, then in a shader march each pixel toward the sun and shade it if anything taller blocks the ray. This handles trees on trees, roofs and terrain in one pass.

### Map infrastructure

- Built: seeded RNG (mulberry32) and seeded value noise, so the same seed always draws the same scene.
- Not started: a chunked map that only redraws dirty chunks, and saving placed objects as data (seed + parameters) rather than pixels.

## Prototype

[Inkwood Renderer](https://claude.ai/artifact/SweR4FtZewp8FAX4xbNb6G) (version 2) is the reference implementation for the port: one self-contained HTML file, Canvas 2D, no libraries. Its source is the code Claude Code should read first.

### Tools

- **Trees, Props:** drag to paint with the scatter brush.
- **Wall:** drag to draw; finishing within 28 px of the start closes the ring.
- **Enclosure:** tap to stamp a rampart enclosure sized by the brush.
- **House:** tap to place a house.
- **Erase:** drag to remove objects and structures.
- **New scene / Clear map**; render-pass toggles for paper, road, shadows, objects, grain and the collision grid.

### Parameters and defaults

| Control | Default | Range | Affects |
| --- | --- | --- | --- |
| Brush size | 60 px | 20–140 | Brush radius; enclosure size = 2.6 × brush |
| Density | 50% | 5–100% | Darts per stamp |
| Collision check | On | On / off | Rejects overlaps; clears sites under structures |
| Canopy size | 19 px | 8–40 | Tree radius |
| Size variation | ±40% | 0–80% | Per-tree radius spread |
| Inner contour rings | 3 | 0–4 | Floret detail per lobe |
| Tree height | 1.3× | 0.6–3.5 | Height as a multiple of radius |
| Wall width | 16 px | 6–26 | All walls |
| Wall height | 12 px | 3–30 | Wall shadow length |
| House size | 28 px | 14–44 | All houses |
| Sun direction | 315° (NW) | 0–359° | Shadow direction, roof and slope shading |
| Sun elevation | 46° | 12–85° | Shadow length and canopy stretch |
| Shadow strength | 92% | 20–100% | Shadow opacity |
| Shadow tint | Steel | Steel, Ink, Teal, Umber | Shadow color and shaded roofs |
| Line weight | 0.8 | 0.5–2 | All ink |
| Hand wobble | 0.6 | 0–1.5 | Contour noise |
| Paper grain overlay | 55% | 0–100% | Grain multiply strength |

### Data model

Objects store seeds and normalized random values, not pixels, so every slider can redraw the existing map.

- Tree: position, seed, size factor (−1 to 1), height factor (0–1), big flag.
- Prop: position, type, size, rotation, seed.
- Wall: generator (rounded rect, divider or freehand points), width and height scales, closed, caps, seed.
- House: position, rotation, parts (offset, size and angle in units of house size), height scale, chimney flag, seed.

## Godot and Claude Code handoff

The game uses Godot. Alex's plan is to hand the prototype artifact to Claude Code for the port. The order and mapping below are proposed and not yet approved.

### What Claude Code gets

- The Inkwood Renderer HTML file (download from the artifact) as the reference implementation.
- This doc, for the style rules, parameter defaults and what is still open.
- The Bridge to Friendship project, as the example for Godot project setup. Repo link to add.
- Alex's Robo Rally clone, on his GitHub account and likely also on his computer, as the reference for shared-unit co-op turns and ready-up. Repo link to add.
- A fixed scene seed (the prototype uses 20261009) so Godot and browser screenshots can be compared side by side.

### Proposed port order

1. Utilities: seeded RNG, value noise and fbm, convex hull, spline sampling, Chaikin and resampling.
2. Data model: tree, prop, wall and house records as plain data with seeds.
3. Generators as pure functions that return geometry (lobe contours, wall bands, roof polygons), with no drawing inside.
4. Drawing: each generator's geometry drawn into a cached texture per object.
5. Compositing: ground, per-class shadow masks, objects, grain, in the pipeline order above.
6. Brush tools and collision.
7. Height-map shadow shader, replacing the per-class masks once the rest matches.

### Proposed mapping

| Prototype piece | Godot equivalent |
| --- | --- |
| Offscreen canvas per object | Draw once with CanvasItem _draw() inside a SubViewport, keep the result as a texture on a Sprite2D |
| Shadow mask per height class | SubViewport that draws silhouettes in black, then a shader that tints and composites it |
| Height-map shadows (proposed) | SubViewport rendering object heights, plus a raymarch shader on the ground layer |
| Grain overlay | Full-screen TextureRect with a multiply blend material |
| Spatial hash | Dictionary keyed by Vector2i cell |
| mulberry32 and value noise | Port as-is so seeds draw the same scene; FastNoiseLite would change the look |
| Pointer brush | _unhandled_input on the map node |

Open before starting: GDScript or C#, and which Godot 4 version to target.

## Known gaps and next steps

The biggest visual gap is the walls: they read tidier than the rubble-and-scrub earthworks in the reference.

- [ ] Rougher wall edges: scrub and rubble texture along both sides of the band
- [ ] Tree shadows falling on other trees and on rooftops (height-map shader)
- [ ] Richer tree florets: curled sub-lobes closer to the reference canopies
- [ ] Road editor with draggable control points, as in the reference video
- [ ] Shared ink stroke routine with width variation and tapered ends
- [ ] Freehand walls colliding with other structures
- [ ] Chunked map with dirty-chunk redraw
- [ ] Save and load scenes as data

## Open design details

None of these have been discussed yet; each row holds space for a decision.

| Area | Questions to answer | Decision |
| --- | --- | --- |
| Game concept | Set: co-op turn-based tactics (see Game concept). Still open: number of players, turn timer | To be defined |
| Camera and scale | Zoom may be limited, with scrolling and an overview map (see UI and HUD). Still open: zoom range, pixels per world unit, rotation | To be defined |
| World generation | Hand-placed maps, procedural maps, or both; map size | To be defined |
| Terrain and biomes | Water, fields, elevation, seasons; how each is drawn in ink | To be defined |
| Object library | Further buildings, fences, crops, bridges, ruins | To be defined |
| Characters and animation | How moving units are drawn in the style; whether they cast the same shadows | To be defined |
| Time of day | Fixed sun or a moving sun with shadows that update | To be defined |
| UI and typography | Direction started under UI and HUD; still open: fonts, exact layouts, remaining use cases | To be defined |
| Platforms and performance | Target devices, frame rate, map size budget | To be defined |
| Audio | Music and sound direction | To be defined |

## Sources

- Hannes Breuer, short video captioned "I added a new brush for objects" — screenshots supplied by Alex
- [Might of Merchants on itch.io](https://quillpeak.itch.io/might-of-merchants)
- [Might of Merchants press kit](https://www.moddb.com/games/might-of-merchants/presskit)
- [u/mightofmerchants on Reddit](https://www.reddit.com/user/mightofmerchants/) — link from Alex; not readable from here
- [TIGSource: Steambirds](https://www.tigsource.com/?p=20262)
- [TouchArcade: SteamBirds iOS release](https://toucharcade.com/?p=53299)
- [Pocket Gamer: SteamBirds review](https://www.pocketgamer.com/steambirds/review/)
- [TouchArcade: Steambirds: Survival review](https://toucharcade.com/2011/10/19/steambirds-survival-review/)
