# Build system -- proposal, DECIDED 2026-10-09

**Decision (Alex, 2026-10-09): accepted as recommended.** Keep the twin
scripts; no SCons, no task runner, no Python layer now; revisit at the trigger
named under the verdict. The one present gap was fixed the same day:
`build.ps1` now takes `-Target windows|linux|both` (default both) and packages
the Linux build through `tar_pack.ps1`, because `tar.exe` on Windows cannot
record an execute bit. The analysis below is kept as written.

Alex's question (2026-10-09): is this the time to move from the twin
PowerShell/bash scripts to a real build system such as SCons, and if so, prep
it. This was Claude's proposal; the decision was Alex's. At the time of
writing nothing had been changed: the live scripts were untouched and no draft
was written (see the verdict).

## Short answer (proposed)

Not now, and not SCons. Keep the twin scripts, fix one present gap inside them
(`build.ps1` cannot export Linux), and revisit at the trigger named below. When
that day comes, the destination is "shell bootstrap + one Python layer", not a
dependency-graph build system: this project has no compile step, and its two
planned pipelines produce records that must *not* be rebuilt when inputs change.

## What the tooling has to do

- **(a) Orchestration** -- the gate (N headless Godot runs, concurrency capped,
  perf tests serial after a barrier), export, package + verify, editor launch,
  one test by name, the stale-import guard. Later: variant board runs, a
  steamcmd upload. This is ~90% of the real need.
- **(b) Derived outputs** -- the port fixture (`prototype_sample.js`: HTML ->
  JSON under node, "re-run only when the prototype changes"); variant sheets
  (seed + params -> PNGs under `variants/`); art sheets (prompts + anchors +
  control renders -> cells); docs exports (none concrete -- the doc is a live
  artifact, the snapshot is a manual copy). **Boards and art sheets are
  generate-once records**: boards are "archived, not deleted" and are the
  evidence behind a decision; the image API has no seed and bills per call
  (BTF's `gen.py` skips anything that exists, `--force` to redo). Only the
  fixture is a true build edge, and it is one rule.
- **(c) Cross-platform without twins** -- today every behaviour is written
  twice, and the twins already differ: `build.ps1` is Windows-only, sweeps
  `~RF*.TMP` leftovers, verifies the archive entry-by-entry with retries;
  `build.sh` exports both targets, captures the export log and greps it for
  diagnostics, has `--help`, trusts zip's exit code. Each difference is
  documented as deliberate, but every new feature is two implementations.
- **(d) Self-contained** -- PowerShell/bash and nothing else; nothing outside
  the repo read or written; the engine pinned, fetched into `build/deps/`,
  verified by `--version`. Any tool the build needs must arrive the same way
  or the README promise is broken.
- **(e) Claude Code sessions** -- one obvious command per thing, logs on disk
  (`test_logs/<name>.log` + `.err.log`; a parse error appears only in the
  `.err.log`), exit codes that mean something, no prompts, no repo-root scratch.
- **(f) Variant renders are not headless** -- `--headless` disables rendering
  (BTF `shot_runner.gd`, `shots.json`). A board run is a windowed dev-box
  command (xvfb on Linux). It cannot be a gate step under any build system.

## Behaviours any replacement must keep (the reason each exists)

1. Version from `godot.manifest` only; `--version` probe verifies what landed; a wrong binary is reinstalled, never trusted (a wrong-engine build is a shipped artifact no test can see).
2. `APPDATA` / `XDG_DATA_HOME` + `XDG_CONFIG_HOME` redirected to `build/deps/godot-data` for this process and every child; no machine-wide fallback.
3. `.gdignore` written into `build/` and `tmp/` before any engine run (2026-08-10 `editor_settings.tres` packed; 2026-08-15 `tmp/ab/*.gdc` packed); `exclude_filter` is only the backstop.
4. Download staged inside `build/deps`, same-volume move (a half-extracted engine never sits at the trusted path); binary found by pattern, not assumed name; TLS 1.2 forced and progress bar off (PS 5.1); `-ErrorAction Stop`.
5. Templates: only the needed platform members unpacked from the ~1.2 GB `.tpz` via `ZipFile` (Expand-Archive cannot pick members and rejects the extension); `version.txt` written; presence verified after.
6. Engine resolved and import pass run once *before* the parallel gate (N runners racing to download is a self-inflicted flake).
7. Listing the tests must not install the engine.
8. Import check: no `.godot/` -> `--import` unconditionally; mtime pre-filter confirmed by `source_md5` (a checkout touches mtimes).
9. `--fixed-fps 60` always; 600 s = hang; kill, *then* read the pipes (reading `.Result` of a live process blocks forever).
10. Pass = exit 0 AND the marker (crash after the marker; exit 0 without asserting).
11. Logs per test (`.log`, `.err.log`) and per gate run (`.runner.log`, `.runner.err.log`).
12. Concurrency cap `max(2, min(12, cpus-8))`; perf tests by name, serial, after the barrier.
13. No `--check-only` syntax gate (false parse errors on autoload identifiers).
14. Export: never wipe `build/` (the engine lives there); Godot exits 0 with warnings so the artifact decides; stop a running game first; `steam_appid.txt` beside the binary; `version.txt` stamped before export (packed via `include_filter`).
15. Package (Windows): `~RF*.TMP` removed AND excluded from the expected set (2026-08-21/29); explicit file list, not a wildcard; verify presence, length, and UNWANTED entries; 3 attempts, 5 s apart; previous archive removed by platform pattern only. Linux: `tar.gz` (zip drops the exec bit).
16. Editor: the pinned GUI binary; never double-click `project.godot` (a newer editor rewrites the project).

## Options compared

| Option | What it buys | What it costs | Migration risk | As variant/art pipelines arrive |
|---|---|---|---|---|
| **Keep the twins** | Proven; promise (d) intact; nothing to learn or re-verify | Every feature twice; twins already diverge; PS 5.1 traps (BOM, capture, Compress-Archive) keep costing | None | A board launcher is ~20 lines per twin (fine); art gen follows `gen.py` (Python dev tool outside the build); fixture stays a node one-off |
| **SCons** (vendored `scons-local`) | DAG + content signatures, `-j`, one language on both OSes | Python required (breaks (d) unless bootstrapped: +1 pinned download per OS); a few MB vendored; `.sconsign` at the repo root unless relocated; its idioms (Environment/Builder/Decider); no per-action timeout; signature-skip is wrong for a gate and harmful for generate-once outputs | High: all 16 behaviours become custom Python actions -- SCons supplies none of them | The one natural rule (sheets) is generate-once; art is unseeded and paid; the fixture needs node |
| **One Python layer** (stdlib scripts, or invoke/doit) | One language; `subprocess` timeout, `concurrent.futures` gate, `zipfile` verification all native; doit adds `file_dep`/`targets`/`uptodate` if ever needed | Python required (same bootstrap cost); invoke/doit need pip or vendoring (the embeddable Python has no pip) | Medium: same 16-behaviour rewrite, but no framework, portable one script at a time | Good: board driver, fixture regen, steamcmd, sheet composition all become tasks in one tree |
| **Task runner** (just / go-task / make) | One entry point; go-task has a built-in cross-OS shell and `sources`/`generates` checksums | A binary to fetch (bootstrappable like the engine); recipes stay shell, so logic stays in the twins (just, make) or in a sh subset that cannot verify a zip (go-task); make is absent on Windows | Low (a wrapper) but removes no twin | Thin: a third layer over two |
| **Hybrid**: `godot_env.*` (+ `editor.*`) stay the only shell twins; Python bootstrapped like the engine; everything else one Python tree | Twins shrink to the stable bootstrap; every behaviour written once; no framework; CI matrix runs the same code | +1 pinned download and verify probe (Windows: python.org embeddable zip, ~11 MB, official; Linux: python-build-standalone, ~30 MB, third-party); the bootstrap is new twin code | Medium, incremental: port one script at a time, keep the old one until the new passes the inventory above | Best fit; doit can be added later for the few true file rules |

**SCons specifically.** Godot builds with SCons because it is a C++ build with a
platform x arch x target matrix -- the dependency graph *is* the problem there.
Here there is nothing to compile: GDScript has no object files, the gate's
"inputs" are every script (SCons cannot see GDScript's dependency closure, so
every test depends on everything and nothing is ever incremental), the export's
input is the whole tree, and the engine/template fetch and archive verification
are plain Python either way. What SCons would do well: a parallel scheduler with
`-j`, and re-fetching the engine when `godot.manifest` changes (already done by
the version probe). What it would do badly: a test gate (`AlwaysBuild` on every
target, or skipped tests), perf serialisation (`SideEffect` hacks), the 600 s
timeout (no such facility), and variant boards (its core behaviour would
re-render an archived board the moment the renderer changes).

## Verdict -- PROPOSED

**Do not move now.** Revisit at this trigger: *the first tool that needs real
logic on both platforms beyond a one-line engine launch* -- a variant-board
driver that composes sheets, diffs boards or batches N renders with retries; a
gate that needs CI-shaped features (test selection, flake retry, JUnit output);
or the twins being caught out of step a second time.

- **Best option at that trigger: the hybrid.** Runner-up: go-task fetched into
  `build/deps` as a single entry point over the existing scripts -- only if
  Python is refused and the twin cost is the whole complaint.
- **SCons: not recommended at any trigger** unless a real derived-output graph
  has materialised (several rule kinds that must be rebuilt on input change).
  Not expected: boards and art sheets are records, not builds.

Deciding reasons: (1) the needs are ~90% orchestration, and SCons's value --
the DAG and its signatures -- is unwanted for two of the planned outputs;
(2) the real price of any move is a Python dependency, which is justified only
by one-language logic, and plain Python gives that without SCons; (3) zero
commits, two tests and sixteen dated behaviours mean a rewrite now re-risks
everything for no present gain while phase-1 components wait; (4) the one gap
felt today -- no Linux export from a Windows host -- is a twin feature gap,
fixable in `build.ps1` alone (`godot_env.ps1` already unpacks Linux templates;
Windows ships `tar.exe`).

## Pros and cons for Alex to weigh

Keep the twins now:
- (+) The "PowerShell/bash and nothing else" promise stays literally true.
- (+) No session spent on tooling; component 3 starts now.
- (+) Nothing re-verified by hand (no tests cover the build scripts).
- (-) Every new tool is two implementations and two reviews; the twins already differ in five places.
- (-) PowerShell 5.1 keeps charging: BOM, pipeline capture, Compress-Archive.

Move now to the hybrid:
- (+) The cheapest moment -- no history, two tests -- and the pattern is set before component 3's launcher is written.
- (+) One archive verifier, one gate, one timeout; Godot spawned directly (no `powershell.exe` host per test).
- (-) A second pinned download; the Linux one is third-party; the README promise becomes "...and the build fetches its own Python".
- (-) Sixteen behaviours re-verified by hand, by someone, before the old scripts go.
- (-) Not in the execution plan; the design doc would need the change logged.

SCons, at any time:
- (-) Everything under "move now", plus a framework whose central feature this project must disable or work around.

## Open questions for Alex

1. Is a **Linux host** in the picture (CI, a teammate), or only a Linux **export**? If only the export, `build.ps1` gains `-Target` and the bash twins can be frozen -- the twin problem mostly disappears without any build system.
2. Is "nothing else" negotiable to "nothing else; the build fetches its own Python"? Is a third-party Linux Python acceptable, or Windows-only bootstrap with system `python3` on Linux (the bash scripts already fall back to it)?
3. Are variant boards immutable records or re-renderable? (CLAUDE.md's open question: commit the sheets or only `board.json`.) Immutable means there is never a build rule for them.
4. Does the art pipeline follow `gen.py` -- a Python dev tool the build and gate never call? If yes it never touches this decision.
5. Will there be CI (a Windows + Linux matrix)? That is the strongest single reason for one Python layer.
6. Fix the Linux-export gap in `build.ps1` now, as a small proposed change?

Unsure: SCons tracks CPython releases with a lag; whichever Python a bootstrap pinned would have to be one SCons supports (this machine's 3.14 may be ahead of it). Not checked, because SCons is not proposed.
