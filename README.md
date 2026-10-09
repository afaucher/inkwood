# Inkwood

A networked co-op, turn-based tactics war game drawn in a hand-inked, top-down
parchment map style. Godot 4.7 (pinned in `godot.manifest`), GDScript, shipping
on Steam. Project setup is modelled on Bridge to Friendship.

Right now this is the skeleton: the application shell with Host / Join / Local,
a networking layer with two interchangeable transports (Steam for release, ENet
for development and tests), the headless test gate, Windows/Linux build
scripts, and the renderer prototype's utilities ported as-is. No gameplay, no
rendering yet -- see `CLAUDE.md` for what is built and what waits for review,
and the design doc for the plan.

## Requirements

PowerShell on Windows, bash on Linux. **Nothing else -- no Godot install.** The
engine is a dependency of the repo: `godot.manifest` pins the version and the
build scripts, the test runners and the editor launcher download exactly that
build into `build/deps/` the first time they need it. Nothing outside the repo
is read or written.

## Opening the editor

```powershell
.\editor.ps1
```

```bash
./editor.sh
```

Use these rather than double-clicking `project.godot`: a newer editor silently
rewrites the project into its own format.

**SOLO / LOCAL** does nothing yet beyond a status line. **HOST** and **JOIN**
use a Steam lobby and need a running Steam client; Join connects to the first
global lobby it finds. `steam_appid.txt` holds `480` (Valve's test appid) --
replace it, and `SteamManager.APP_ID`, once the game has its own.

## Running tests

```powershell
.\test_runner.ps1 -TestName test_smoke
.\test_runner.ps1 -TestName test_port_utils
```

```bash
./test_runner.sh test_smoke
```

Run either with no argument to list the tests. Logs go to `test_logs/`.

## Building

```powershell
.\build.ps1                   # both targets
.\build.ps1 -Target windows   # or: -Target linux
```

```bash
./build.sh                  # both targets
./build.sh --target linux   # or: --target windows
```

Either host builds both targets: Godot appends the project `.pck` to a prebuilt
template, and GodotSteam ships binaries for every platform. Runs the full test
gate, fetches export templates on first use (~1.2 GB archive, once), exports and
packages into `build/`:

| target | binary | archive |
|---|---|---|
| Windows | `build/windows/Inkwood.exe` | `build/Inkwood_Windows_v<version>.zip` |
| Linux | `build/linux/Inkwood.x86_64` | `build/Inkwood_Linux_v<version>.tar.gz` |

The Linux build is a `.tar.gz` because zip does not preserve the executable
bit; on Windows the archive is written by `tar_pack.ps1` rather than `tar.exe`
for the same reason (see that file). Every archive is read back and checked
entry by entry before the build reports success. `export_presets.cfg` is
committed on purpose.

## Layout

See `CLAUDE.md`.
