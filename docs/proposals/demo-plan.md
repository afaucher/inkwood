# Sandbox demo: exit criteria and fan-out plan

The exit criteria are Alex's (2026-10-09, design doc: Execution plan > Sandbox
demo exit criteria). The track plan is PROPOSED and is what the subagents work
from; the design doc remains the source of truth for everything else.

## Exit criteria (Alex, top level)

The demo is done when all of these hold in a build Alex can play:

1. **Local only.** One process, started from the menu. Networking comes soon
   after and is not part of this demo.
2. **At least two player-controlled planes and one AI plane** in the same
   world. The AI may be as dumb as it likes, but it flies on its own.
3. **The motion mechanic.** A plan is a curve of steps; each step is a point
   inside the plane's performance envelope; inertia applies (speed carries,
   turns cost speed, acceleration takes steps). Turns and speed at minimum.
4. **Terrain with at least two height levels**, each with vegetation, and
   shadows that respect height.
5. **A map big enough** to fly the planes around for a minute and complete
   full turns without leaving it.
6. **Something on screen for every unit**, and the roster sidebar for selecting
   a unit and planning its motion.
7. **Fog of war and zoom tried with a first option**, to see how they look,
   without committing.
8. **Specials deferred.**

Verification (proposed): one checklist pass by Alex on an exported build, a
screenshot per criterion into the design doc, and the detailed review the
execution plan already names (component 18).

## Tracks

Each track owns folders; nobody edits another track's folder. Tracks read
each other's DATA (files under `data/`) and the interfaces named below, never
each other's code. Everything is headless-testable except pixels.

| Track | Delivers | Owns | Starts when |
| --- | --- | --- | --- |
| **R** Rendering | drawing layer; prototype draw routines ported; render parity; `--render-shot` | `scripts/render/`, `scripts/app/main.gd` (entry points only) | running |
| **V** Map view (R, second job) | the static map (terrain, vegetation, structures, their shadows, grain) baked into texture chunks a few per frame (tessellation may move to a worker thread), cached, shown under a camera; only units, unit shadows and UI drawn live | `scripts/render/map_view*`, `scripts/render/chunk*` | R reports parity and T lands |
| **S** Simulation | unit data model; motion + envelope; turn loop (plan, commit, resolve); dumb AI | `scripts/sim/`, `data/units/`, `data/sim/` | now |
| **T** Terrain | two height levels; vegetation per level; height-respecting shadows; map size from the flight rule | `scripts/world/terrain*`, `scripts/render/terrain*`, `data/terrain/` | R's drawing layer reports |
| **U** Interface | per-unit marker and card; roster sidebar; motion planning control | `scripts/ui/` | S's interfaces land, R's drawing layer reports |
| **F** Fog and zoom | first vision rule; topographic layer outside vision; zoom limit and camera | `scripts/render/fog*`, `scripts/world/camera*` | T lands |
| **A** Assembly | sandbox scene; Local starts it; export; screenshots; review | `scenes/`, `data/scenarios/` | all above |

### Interfaces (the contracts between tracks)

- **S exposes** (read by U, A): a `World` with `units` (Dictionaries: id, type,
  side, controller player/ai, x, y, heading, speed, altitude band, plan), a
  `plan_step(unit, step_index, point)` that validates a point against the
  envelope, `commit()`, `resolve()` producing per-step positions for every
  unit (so R/U can animate), and signals for turn phase changes. Unit types
  and envelopes come from `data/units/*.json`; turn constants from
  `data/sim/turn.json`.
- **R exposes** (read by T, U, F): the ink canvas API (`InkCanvas`), the
  shadow pass, the grain and paper helpers, and a frame composition entry.
- **T exposes** (read by F, A): a height query `height_at(x, y)` and the
  terrain layers (levels, vegetation lists) in the scene-gen data shape.
- **V exposes** (read by U, F, A): a `MapView` node that takes the world's
  seed and bounds, bakes chunks around the camera on demand, and offers a
  world-to-screen transform plus a layer slot above the map for live drawing
  (units, unit shadows, fog). Why a bake (proposed): the drawing layer
  tessellates in GDScript at about 7 ms per tree sprite, fine for one still
  frame and far too slow to redraw a flyable map each frame; the static map
  never changes during a turn, so it is drawn once per chunk.
- **Data first**: a track that needs a number another track owns adds it to
  the owning track's data file via a proposal in its report, not by editing
  code.

### Decisions the tracks will have to make (all proposed until Alex says)

- Turn length in simulated seconds and steps per turn per plane type
  (`data/sim/turn.json`); the envelope's axes and values per plane
  (`data/units/*.json`). Placeholders are allowed if labelled.
- The two height levels' form: a plateau from thresholded fbm, or hand-placed.
- The first vision rule: a radius per unit, nothing more.
- Zoom: a hard limit and whether the topographic layer appears at far zoom.

## Fan-out point

- S starts immediately: no rendering dependency.
- T starts when R's drawing layer reports (it did, 2026-10-09).
- U starts when S's interface lands (it draws onto V's live layer, so its
  first cut uses a plain Node2D stand-in until V lands).
- V starts when R reports parity and T lands; F when T and V have landed;
  A when everything else has.
- Every track runs the gate (`build.ps1` or the runner) before reporting, and
  reports deviations and proposals rather than deciding.
