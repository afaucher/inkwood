# CLAUDE.md

Operational guide for working on Inkwood with Claude Code. Inkwood is a
networked co-op, turn-based tactics war game drawn in a hand-inked, top-down
parchment map style. Godot 4.7, GDScript, 2D, headless test workflow. Project
setup is modelled on Bridge to Friendship (a sibling folder); co-op turns and
ready-up are modelled on Alex's Robo Rally clone `goto` (also a sibling).

## Working rules

1. **The design doc is the source of truth.** Live version:
   https://claude.ai/code/artifact/5cdc9f22-2f23-41a5-9196-c0370d346d2e (read it
   with the docs tools, not a web fetch; `docs/inkwood-design-doc.md` is a dated
   snapshot for grepping). It holds the style rules, the decision log and the
   execution plan. **If something is not covered there, ask Alex instead of
   deciding.**
2. **Design decisions are made from variant boards**: 3 to 6 options side by
   side from one seed. Record each choice in the data files
   (`data/decisions/decisions.json`, then the values it sets) and report it so it
   can be added to the doc's decision log.
3. **Label your own suggestions as proposed.** Never present them as Alex's
   decisions -- in code comments, data files, reports and the doc alike.
4. **Gameplay and style values live in data, not code.** Parameters, unit
   definitions and decisions are files under `data/`; code reads them. A tuning
   change is a data change.
5. **Style goal: a similar look to the reference art reached through procedural
   generation**, not a copy of Might of Merchants. The prototype
   (`reference/inkwood-renderer.html`) is the reference implementation for the
   generators and the look.
6. **Every art choice includes the palette.** Any decision about a drawn thing
   is judged beside the things it will sit with (the swatch row), and asks how
   the palette stays one palette: hue is reserved for paper, ink, shadow and
   accents; lightness is a ramp off paper; material is linework. No hex
   literal in draw code once the style layer exists -- colours are roles in
   data. See `docs/proposals/palette-architecture.md`.

## What exists and what does not

Built (execution plan components 1 and 2): the project skeleton, the Steam and
ENet session layer from Bridge to Friendship (Join connects to the first global
Steam lobby it finds), the headless test gate, and the prototype's utilities
ported as-is -- `scripts/core/mulberry32.gd`, `noise.gd`, `geometry.gd`,
`js_math.gd` -- with `test_port_utils` checking them against the prototype's
own output. Scene generation (`scripts/world/`: the prototype's newScene, the
structures' geometry, the spatial hash and collision) is ported and
`test_scene_gen` checks the whole default scene against the prototype's.

The prototype's draw routines are ported onto the drawing layer in
`scripts/render/` and match the browser visually (2026-10-09:
`test_render_layer`, `render.* -Scene <seed> -Parity`). The simulation core
is in `scripts/sim/`: unit definitions from `data/units/`, the motion
envelope with inertia, the World (plan, ready-up, resolve) and a dumb AI,
headless and deterministic (`test_unit_defs`, `test_envelope`,
`test_turn_loop`, `test_world_api`). Terrain is in `scripts/world/terrain*.gd`:
three height levels from thresholded fbm, generated per chunk from (seed,
chunk) alone, groves per level, `height_at` / `level_at`; drawn with
hachures and height-respecting shadows by `scripts/render/terrain_*.gd`
(`test_terrain`; a look: `scripts/render/terrain_shot.gd`). The unit interface is in
`scripts/ui/`: inked plane markers with altitude shadows, the roster sidebar
and the motion planner over the World, mounted through `unit_ui.gd`
(`test_ui_roster`, `test_motion_planner`; a look: `scripts/ui/ui_shot.gd`). The map view is
`scripts/render/map_view.gd`: the static map baked into chunk textures on
worker threads under a camera, ground anchored to the world, scale
switchable at runtime (`test_map_view`; a look:
`scripts/render/map_view_shot.gd`). InkCanvas draws the shadow-side pen
(`linework.pen`; `--parity` selects the prototype's even line). Fog of war and the
camera: `scripts/render/fog_*.gd` (sight circles or a line-of-sight viewshed
over terrain and trees, a topographic layer outside sight, an inked edge)
and `scripts/world/camera_controller.gd` (`test_fog`, `test_viewshed`,
`test_camera`; looks: `fog_shot.gd`, `fog_los_shot.gd`).

**The target is the sandbox demo.** Its exit criteria are Alex's (design doc:
Execution plan > Sandbox demo exit criteria) and the track plan with folder
ownership is `docs/proposals/demo-plan.md`. Work on a track stays inside the
folders it owns and reads other tracks' data, not their code. The variant
board tool and networking beyond the template are not part of the demo.

## Running tests

Tests live in `scripts/tests/*.gd`, one file per test, and are run by name:

```powershell
.\test_runner.ps1 -TestName test_smoke
```

```bash
./test_runner.sh test_smoke
```

- The engine is a dependency of the repo, not of the machine: `godot.manifest`
  pins 4.7-stable and `godot_env.ps1` / `godot_env.sh` install exactly that
  build into `build/deps/` (nothing outside the repo is read or written; a Godot
  on PATH is never reused). `editor.ps1` / `editor.sh` open the editor in it --
  use those, never double-click `project.godot`.
- **Pass marker:** `>>> [TEST PASSED] <name> <<<`. The runner requires both
  exit code 0 and the marker.
- **Read `test_logs/<name>.log` and `.err.log`**, not the runner's stdout: the
  real message for a parse error appears only in the `.err.log`.
- **Pass `--fixed-fps 60` on direct runs** (the runner already does); without it
  headless Godot sleeps to hold 60 Hz.
- **Writing a test:** subclass `res://scripts/test_support/test_case.gd`,
  implement `setup(main)`, assert with `check/eq/near`, call `finish()`. Use
  `_physics_process` for anything frame-based. Helpers go in
  `scripts/test_support/`, which the gate does not run.
- `build.ps1` / `build.sh` run every test in parallel and abort the export on
  any failure.
- `INKWOOD_STEAM=off` skips Steam entirely for a run that must not touch the
  client; every `DebugSettings` knob is settable as `INKWOOD_<KEY>`.

## The port check

`reference/port_check/prototype_sample.js` runs the prototype's own functions
(sliced out of the HTML, not retyped) under node and writes
`expected_seed_20261009.json`; `test_port_utils` recomputes the sample in
GDScript and compares. `prototype_scene.js` does the same for the whole
default scene (`expected_scene_20261009.json`, checked by `test_scene_gen`:
same object counts, every value within tolerance). Re-run the scripts only
when the prototype changes. Do not swap the RNG or the noise for engine ones:
the same seed must draw the same scene as the browser.

**Bit-exactness is NOT required** (Alex, 2026-10-09): visual parity with the
prototype is the bar. The tests compare to a tolerance (1e-9 relative on the
scene data, 1e-3 px on Vector2 geometry), so engine math and Vector2 are fine
on the placement path. The port happens to be bit-exact with node today
through `scripts/core/js_math.gd` (V8's fdlibm trig and hypot); that file is
kept because it is already proven and costs nothing, not because anything
must use it. Note for later (proposed): if the world is ever generated on
every peer from the seed, pure-GDScript math is what keeps a Windows and a
Linux build placing the same trees, since the engine's trig comes from each
platform's C runtime.

## Layout

```
godot.manifest        the pinned engine version -- the only place it is written
godot_env.*           installs and verifies that engine into build/deps
editor.* build.*      open the editor / gate + export;  test_runner.*  one test
test_runner.*         one test by name;  import_check.*  stale-import guard
render.*              a WINDOWED run that saves a frame: the drawing-layer demo (--render-shot)
                      or a generated scene (-Scene <seed> / --scene <seed>: --render-scene,
                      -Parity for the prototype's own defaults); never a test
project.godot         autoloads in order: DebugSettings, SteamManager, NetworkManager
scenes/main.tscn      the application shell: menu only, no world
scripts/
  app/main.gd         menu, session wiring, the --run-test / --render-shot entry points
  core/               ported utilities (RNG, noise, geometry, V8 math) -- pure, no nodes
  world/              scene generation (the prototype's newScene), structures, params
  render/             the drawing layer: InkCanvas (Canvas-2D-like), shadow pass,
                      paper, grain, shaders; the demo frame
  debug/              DebugSettings autoload: the knob registry
  net/                SteamManager and NetworkManager autoloads
  ui/                 build_version.gd (the corner build stamp)
  tests/              one file per test; the gate runs every .gd in here
  test_support/       shared helpers -- NOT run as tests
data/                 parameters, unit definitions, decisions (JSON; read at runtime)
variants/             variant board output, one folder per decision
docs/                 design doc snapshot
reference/            the prototype HTML and the port-check fixture (never shipped)
addons/godotsteam     GodotSteam GDExtension, binaries for every platform
build/ tmp/           gitignored: engine + templates + exports; throwaway output
```

## Engine traps (inherited from Bridge to Friendship)

Properties of Godot and PowerShell, not of that game. Entries marked
*(inherited)* were paid for there; add a date when one is confirmed here.

- **`:=` cannot infer a type from a Variant expression.** Confirmed here
  2026-10-09, three times in the first two tests: `var menu :=
  main.get_node_or_null(...)` (untyped `main`), `var closed := mode == "closed"`
  (`mode` from iterating an untyped Array). A parse error, not a runtime
  problem. Write the type out: `var menu: Node = ...`.
- **A `const` may not be named after a native class.** Observed 2026-10-09:
  `const Noise = preload(...)` is a parse error ("shadows a native class" --
  Noise is FastNoiseLite's base). Pick a name that is not an engine class.
- **`%` formatting has no `%g`.** Observed 2026-10-09: `"%.17g" % v` prints the
  format string back and logs "unsupported format character" per call. Use
  `String.num(v, digits)` for significant-digit output.
- **`load()` on a script with a parse error returns a NON-null resource on 4.7**
  (observed 2026-10-09, proved with a deliberately broken test). A `== null`
  guard never fires; `main.gd` checks `can_instantiate()` as well.
- **Inside a script that defines a static `sin`, an unqualified `sin(x)` calls
  the ENGINE's built-in, not the script's own.** Observed 2026-10-09 in
  `js_math.gd`; its helpers use private names for this reason. The same holds
  for any name that shadows a global function.
- **Godot's float parser is not correctly rounded past 15 significant digits**
  -- literals, `to_float()` and `JSON.parse_string` alike (observed 2026-10-09:
  `0.09642319823615253` and `123.45678901234567` land one ulp off through all
  three). Keep data at 15 significant digits or fewer; when a fixture must
  carry an exact double, carry its bytes and decode with
  `hex_decode().decode_double(0)` (see `test_port_utils`).
- **A non-resource file is NOT exported unless `include_filter` names it**
  *(inherited)*. `export_filter="all_resources"` means resources -- a plain
  `.json` or `.txt` is skipped in silence, so `FileAccess.file_exists()` is true
  in the editor and false in the shipped game, the worst shape a bug can have.
  `data/*` and `version.txt` are in the filter for this reason. After adding
  any data file, find it in the export's `savepack:` list. It cuts the other
  way too: `all_resources` sweeps in any resource under `res://`, which is why
  `build/*`, `tmp/*`, `reference/*` and `variants/*` are excluded -- and on 4.7
  a stray `editor_settings-*.tres` from `build/deps` ABORTS the export.
- **PowerShell's `-Encoding utf8` writes a BOM, and a BOM breaks Godot's text
  formats** *(inherited)*: `Parse Error: Expected '['` at line 1 of a file that
  looks perfect in every editor. Use the Write tool or
  `[System.IO.File]::WriteAllText` for anything Godot parses.
- **A dev box has Steam and the gate may not, so never assert a display name
  or an id** *(inherited)*. Assert the rule or the relationship (`own.steam_id
  == steam_id_of_self()`), never the value; anything read from the environment
  is not a property of the code.
- **`Compress-Archive` SILENTLY SKIPS a file it cannot open** *(inherited)* --
  a zip with no game in it and exit code 0. `build.ps1` reads every archive
  back entry by entry; a packaging step that reports its own success is not
  evidence.
- **PowerShell capture traps** *(inherited)*: `Select-Object -First N`
  TERMINATES the upstream pipeline and kills a Godot run mid-way;
  `Select-String` is case-insensitive by default; `*>` does not capture a
  native executable's stdout. Read the log files the runner writes.
- **A durable log is guilty until proven fresh** *(inherited)*: files under
  `test_logs/` persist between runs; identical timings across two runs means
  you are reading one run twice.
- **A frame-gated test whose `finish()` sits outside its own gate does not
  fail, it passes early** *(inherited)*, and every assertion above it is dead
  code. An `if` around an assertion is a silent skip.
- **`FileAccess.store_line` buffers** *(inherited)*: a file being written may
  read back as 0 lines until it is flushed or closed.
- **Transparent viewports hold PREMULTIPLIED colour** (measured 2026-10-09 in
  the drawing layer): a texture read back from one must be composited as
  premultiplied, or edges darken.
- **The GPU's 8-bit store does not round to nearest** (measured 2026-10-09:
  values up to .55 above a half went down). A shader or resolve that must land
  on an exact level rounds itself before writing.
- **A RefCounted's own methods cannot be called during PREDELETE** (observed
  2026-10-09); free resources in an explicit `discard()`, not a notification.
- **`--script` runs still load the autoloads**, so Steam starts unless
  `INKWOOD_STEAM=off` (observed 2026-10-09; `render.*` sets it).
- **A hidden browser tab or pane stops `requestAnimationFrame` AND
  `ResizeObserver`** (observed 2026-10-09): the prototype's capture page
  renders only while visible, so a capture from a background tab is stale or
  a 300x150 canvas. Drive pages through setTimeout and render synchronously
  (`tmp/render/make_nograin_page.js` did; a page can POST its own PNG to a
  scratch server).
- **Subagents share the one built-in browser** and navigate whichever tab is
  active (observed twice 2026-10-09). Open your own tab, re-check the URL
  before each capture, and never close a tab you did not open.
- **`pass` is a reserved word**: `var pass` is a parse error (observed
  2026-10-09).
- **After dot-sourcing `godot_env.ps1`, `powershell` is no longer on that
  session's PATH** (`Normalize-ProcessPath`), so calling the test runner in
  the same command fails (observed 2026-10-09). Run the import and the
  runner as separate commands.
- **A windowed `SceneTree` script (`--script`) can render offscreen** with
  `force_draw` from `_initialize()` (observed 2026-10-09; the shot scripts do).
- **A `--script` run whose script fails to compile does not quit**: headless or
  windowed, the process idles until killed (observed 2026-10-09). Give shot
  scripts a timeout, and read the .err output when one seems to hang.
- **`RenderingServer.texture_2d_get` stalls on every frame in flight**
  (measured 2026-10-09: ~190 ms per sprite page). Use
  `RenderingDevice.texture_get_data_async` for read-backs.
- **A viewport left at UPDATE_ALWAYS redraws until it is freed**; bake
  viewports use UPDATE_ONCE (2026-10-09).
- **A CanvasGroup costs a render pass over its whole render target**, so
  many groups on one large target are very slow (2026-10-09: the ground's
  1,743 fibre groups per chunk).
- **GDScript slows down past about 8 worker threads** (2026-10-09: 256 tree
  sprites in 131 ms on 8 threads, 840 ms on 31). The baker caps at 8.
- **`Texture2DRD` refuses a viewport's texture** (2026-10-09).
- **Kill stragglers** if a run hangs: `taskkill //F //IM
  Godot_v4.7-stable_win64.exe` (Windows) or `pkill -f Godot_v` (Linux).
- **A parse error in one script fails EVERY script that depends on it**
  *(inherited)*, and the suite reports damage nowhere near the cause. After any
  mechanical edit, run ONE affected test and read its `.err.log` first.
- **A missing Dictionary key or property aborts the rest of that function for
  the frame** *(inherited)* and can leave a test green that stopped testing
  (the runner checks exit code and marker; a GDScript runtime error changes
  neither). Use `d.get("field", default)`; after renaming a field, grep the
  tests for the old name.
- **A `preload` const can create a class cycle that HANGS the run** rather than
  failing it *(inherited)*. If a test that passed a minute ago now hangs,
  suspect a newly added preload first.
- **A reject-sampling `while` is an infinite loop waiting for a degenerate
  input** *(inherited)*; it burns CPU inside one frame while the process looks
  busy.
- **`--headless --check-only` reports false parse errors on autoload
  identifiers** *(inherited)*, so there is no syntax gate; scripts are
  validated by the tests that load them, `test_smoke` first and cheapest.
- **A new checkout has no `.godot/` cache and is not runnable** until an import
  pass; `import_check.*` runs one. Hand-edited or pulled imported assets are
  silently stale in headless runs for the same reason.
- **The engine version is pinned and verified**; a build made with the wrong
  engine is a shipped artifact no test can see is wrong. Never add a fallback to
  a machine-wide install.

## Build tooling: twin scripts, by decision

Decided 2026-10-09 (Alex, on the assessment in
`docs/proposals/build-system.md`): keep the PowerShell/bash twins; no SCons,
no task runner, no Python layer now. **Revisit trigger:** the first tool that
needs real logic on both platforms beyond launching the engine (a variant-board
driver that composes sheets or batches renders with retries), a gate needing
CI-shaped features, or the twins being caught out of step again. At that
trigger the proposal's answer is the hybrid (shell twins only for `godot_env.*`
and `editor.*`, one stdlib-Python tree for the rest, Python bootstrapped into
`build/deps` like the engine). SCons is not the answer at any trigger: boards
and art sheets are records, not rebuilds. Until then every build-side change
is made in BOTH twins; `tar_pack.ps1` is the one Windows-only helper, because
`tar.exe` cannot record an execute bit.

## Conventions

- Commit messages use a `feat:`/`fix:` prefix.
- **Temporary files go in `tmp/`** (gitignored; `res://tmp/...` from GDScript
  after `DirAccess.make_dir_recursive_absolute("res://tmp")`). Never write
  scratch files to the repo root. Test logs are the named exception
  (`test_logs/`).
- **Every networked test binds its own port**; the gate runs tests in parallel,
  so two tests sharing a port is an intermittent failure that reads as a
  networking bug. Allocated: `test_enet_loopback` 28777,
  `test_network_session` 28778. Pick the next free one and add it here.
- **Only `scripts/net/steam_manager.gd` calls `Steam.*`.** Everything else asks
  `NetworkManager`, because the gate may have no Steam client and anything that
  reaches past that boundary is untestable the moment it is written.
- **Shell scripts must be committed executable.** The repo has
  `core.filemode=false` on Windows, so the first `git add` records 100644 and
  `./build.sh` fails on Linux. At the first commit:
  `git add --chmod=+x build.sh editor.sh godot_env.sh import_check.sh test_runner.sh render.sh`.
- **Never `git checkout --` a file with uncommitted work in it.** Copy the file
  aside for an A/B and copy it back.
- The fixed scene seed is **20261009** (the prototype's), so Godot and browser
  output can be compared side by side.
- Steam appid is Valve's test appid 480 (`steam_appid.txt` and
  `SteamManager.APP_ID`); lobbies are filtered by `LOBBY_GAME_KEY = "inkwood"`
  so this game and Bridge to Friendship never see each other's lobbies on it.

## Open questions (for Alex)

- GDScript is carried over from Bridge to Friendship; C# was not considered.
  Confirm.
- Renderer: "Forward Plus" carried over from Bridge to Friendship (a 3D game).
  For a 2D game the Mobile or Compatibility renderer may suit the target devices
  better; the design doc leaves platforms open.
- Variant boards: commit the rendered sheets, or only each board's `board.json`?
- Steam during tests: the runners do not set `INKWOOD_STEAM=off`, so every
  headless test initialises Steam against a running client (`[Steam] ready:
  ...` in the logs, appid 480). Bridge to Friendship behaves the same.
  Proposed: set it off in `test_runner.*` so the gate never touches the client.
