#!/usr/bin/env bash
# build.sh - Linux port of build.ps1. Tests, exports and packages Inkwood, for
# Linux and/or Windows, from a Linux host.
#
# Cross-compiling to Windows here is NOT wine and NOT a hack: Godot's exporter
# takes the prebuilt `windows_release_x86_64.exe` template and appends the
# project .pck to it, which is an ordinary file operation. The GodotSteam addon
# ships prebuilt binaries for every target (addons/godotsteam/win64, linux64,
# ...) and the .gdextension's [dependencies] block makes the exporter pick the
# right steam_api per platform automatically. So a Windows build produced here
# is the same construction a Windows host would produce.
#
# The engine is not assumed to be installed and is not hardcoded here: the
# version comes from godot.manifest and godot_env.sh fetches exactly that build
# into build/deps/ on first use. See that file.
#
# Usage:
#   ./build.sh                      # gate + build BOTH targets
#   ./build.sh --target linux       # one target only
#   ./build.sh --target windows
#   ./build.sh --force              # package even if tests failed
#   ./build.sh --skip-tests         # NEVER for a release; see the flag's note

set -u
set -o pipefail

GAME_NAME="Inkwood"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
BUILD_VERSION="$(date +%Y-%m-%d.%H%M%S)"
LOG_DIR="$SCRIPT_DIR/test_logs"

C_CYAN='\033[36m'; C_YELLOW='\033[33m'; C_GREEN='\033[32m'
C_RED='\033[31m'; C_DIM='\033[2m'; C_RESET='\033[0m'

say()  { printf "${2:-$C_CYAN}%s${C_RESET}\n" "$1"; }
die()  { printf "${C_RED}%s${C_RESET}\n" "$1" >&2; exit 1; }

# --- Arguments ---------------------------------------------------------------
TARGETS="linux windows"
FORCE=0
SKIP_TESTS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target)
            case "${2:-}" in
                linux|windows) TARGETS="$2" ;;
                both) TARGETS="linux windows" ;;
                *) die "--target must be one of: linux, windows, both" ;;
            esac
            shift 2 ;;
        --force)      FORCE=1; shift ;;
        # Exists so the export/packaging half can be iterated on without paying
        # for a full gate every time. A build made with this flag has had
        # NOTHING verified -- do not ship one.
        --skip-tests) SKIP_TESTS=1; shift ;;
        # Print the contiguous header comment and stop -- a fixed line range
        # goes stale the moment the header is edited.
        -h|--help)    awk 'NR>1 && /^#/ {print; next} NR>1 {exit}' "$0"; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

say "Build Version: $BUILD_VERSION"
say "Targets: $TARGETS"

# --- Engine -------------------------------------------------------------------
# Resolved (and installed, first time) BEFORE the parallel test batch below:
# every test_runner.sh in that batch asks for the engine too, and thirty
# processes racing to download the same 120 MB is a self-inflicted flake.
# shellcheck source=./godot_env.sh
source "$SCRIPT_DIR/godot_env.sh"
godot_require || exit 1
GODOT_PATH="$GODOT_BIN"
say "Engine: Godot $GODOT_TAG  (${GODOT_PATH#$SCRIPT_DIR/})"

pkill -f "$GAME_NAME" 2>/dev/null || true

# shellcheck source=./import_check.sh
source "$SCRIPT_DIR/import_check.sh"
import_if_stale "$SCRIPT_DIR" "$GODOT_PATH"

# Syntax validation is deliberately NOT a step: `--headless --check-only`
# reports FALSE parse errors on autoload identifiers (DebugSettings,
# NetworkManager, SteamManager), and a gate that cries wolf is worse than none.
# Scripts are validated by the tests that load them.

# --- Test gate ---------------------------------------------------------------
TESTS_PASSED=1
mkdir -p "$LOG_DIR"

# Timing tests run ALONE, after everything else -- inside the parallel batch
# they measure the scheduler rather than the game. Add names here as they arrive.
PERF_TESTS=()

is_perf_test() {
    local n="$1"
    for p in ${PERF_TESTS[@]+"${PERF_TESTS[@]}"}; do [[ "$n" == "$p" ]] && return 0; done
    return 1
}

run_test() {
    local name="$1"
    "$SCRIPT_DIR/test_runner.sh" "$name" \
        >"$LOG_DIR/$name.runner.log" 2>"$LOG_DIR/$name.runner.err.log"
    printf '%s' "$?" >"$LOG_DIR/$name.exit"
}

report_test() {
    local name="$1" code
    code="$(cat "$LOG_DIR/$name.exit" 2>/dev/null || echo 1)"
    if [[ "$code" == "0" ]]; then
        printf "  ${C_GREEN}PASS${C_RESET}  %s\n" "$name"
    else
        printf "  ${C_RED}FAIL${C_RESET}  %s\n" "$name"
        printf "${C_DIM}--- %s ---${C_RESET}\n" "$LOG_DIR/$name.runner.log"
        tail -n 25 "$LOG_DIR/$name.runner.log" 2>/dev/null
        # The real message for a PARSE error appears only in the .err.log and
        # never in the summary -- surface it, or a compile failure reads as an
        # unrelated timeout somewhere else entirely.
        if [[ -s "$LOG_DIR/$name.err.log" ]]; then
            printf "${C_DIM}--- %s ---${C_RESET}\n" "$LOG_DIR/$name.err.log"
            tail -n 25 "$LOG_DIR/$name.err.log"
        fi
        TESTS_PASSED=0
    fi
}

if [[ "$SKIP_TESTS" -eq 1 ]]; then
    say "SKIPPING the test gate (--skip-tests). This build is UNVERIFIED." "$C_YELLOW"
else
    # Cap concurrency: uncapped, a full gate launches one headless Godot per
    # test file at once. Correctness is unaffected (every test runs under
    # --fixed-fps 60, so frame counts are identical regardless of contention);
    # wall clock and any timing measurement are not.
    NPROC="$(nproc)"
    MAX_PARALLEL=$(( NPROC - 8 ))
    (( MAX_PARALLEL > 12 )) && MAX_PARALLEL=12
    (( MAX_PARALLEL < 2 ))  && MAX_PARALLEL=2

    mapfile -t ALL_TESTS < <(find "$SCRIPT_DIR/scripts/tests" -maxdepth 1 -name '*.gd' -printf '%f\n' | sed 's/\.gd$//' | sort)
    [[ ${#ALL_TESTS[@]} -eq 0 ]] && die "No test scripts found under scripts/tests/."

    PARALLEL_TESTS=(); SERIAL_TESTS=()
    for t in "${ALL_TESTS[@]}"; do
        if is_perf_test "$t"; then SERIAL_TESTS+=("$t"); else PARALLEL_TESTS+=("$t"); fi
    done

    say "Running ${#PARALLEL_TESTS[@]} tests, concurrency capped at $MAX_PARALLEL (of $NPROC logical CPUs)..."
    rm -f "$LOG_DIR"/*.exit
    for t in "${PARALLEL_TESTS[@]}"; do
        while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do sleep 0.2; done
        run_test "$t" &
    done
    wait

    for t in "${PARALLEL_TESTS[@]}"; do report_test "$t"; done

    if [[ ${#SERIAL_TESTS[@]} -gt 0 ]]; then
        say "Running ${#SERIAL_TESTS[@]} perf tests serially (contention would make these meaningless)..."
        for t in "${SERIAL_TESTS[@]}"; do
            run_test "$t"
            report_test "$t"
        done
    fi

    if [[ "$TESTS_PASSED" -eq 1 ]]; then
        say "All tests passed successfully." "$C_GREEN"
    elif [[ "$FORCE" -eq 1 ]]; then
        say "WARNING: tests failed, but --force was specified. Proceeding..." "$C_YELLOW"
    else
        die "BUILD ABORTED: one or more tests failed."
    fi
fi

# --- Export templates --------------------------------------------------------
# shellcheck disable=SC2086  # word splitting is the point: TARGETS is a list
godot_require_templates $TARGETS || die "BUILD ABORTED: export templates unavailable."

# --- Export ------------------------------------------------------------------
# NOT `rm -rf "$BUILD_DIR"` -- build/ now also holds deps/, i.e. the engine this
# script is running from. Only the output directories are cleaned, and only the
# ones this run is about to write.
say "Preparing build directory: $BUILD_DIR"
for t in $TARGETS; do
    rm -rf "${BUILD_DIR:?}/$t"
done
printf '%s\n' "$BUILD_VERSION" >"$SCRIPT_DIR/version.txt"

# zip(1) is not installed everywhere -- fall back to 7z and then to python3's
# stdlib zipfile before giving up. All three produce an equivalent archive.
make_zip() {
    local src_dir="$1" out="$2"
    rm -f "$out"
    if command -v zip >/dev/null 2>&1; then
        ( cd "$src_dir" && zip -qr "$out" . )
    elif command -v 7z >/dev/null 2>&1; then
        ( cd "$src_dir" && 7z a -tzip -bso0 -bsp0 "$out" . >/dev/null )
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$src_dir" "$out" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(src):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, src))
PY
    else
        return 1
    fi
}

export_target() {
    local target="$1" preset out_dir out_file
    case "$target" in
        linux)   preset="Linux";           out_dir="$BUILD_DIR/linux";   out_file="$GAME_NAME.x86_64" ;;
        windows) preset="Windows Desktop"; out_dir="$BUILD_DIR/windows"; out_file="$GAME_NAME.exe" ;;
    esac

    mkdir -p "$out_dir"
    say "Exporting '$preset' to $out_dir/$out_file..."

    local log="$LOG_DIR/export_$target.log"
    # Godot exits 0 even when the export only "completed with warnings", so the
    # exit code alone is not proof -- the artifact check below decides.
    "$GODOT_PATH" --path "$SCRIPT_DIR" --headless \
        --export-release "$preset" "$out_dir/$out_file" >"$log" 2>&1
    local code=$?

    if grep -qE '^(ERROR|WARNING):' "$log"; then
        say "Export reported diagnostics (see $log):" "$C_YELLOW"
        grep -E '^(ERROR|WARNING):' "$log" | head -n 10
    fi

    if [[ $code -ne 0 || ! -f "$out_dir/$out_file" ]]; then
        say "BUILD FAILED: export of '$preset' produced no artifact (exit $code). Full log: $log" "$C_RED"
        return 1
    fi

    # Steam needs its appid next to the binary.
    [[ -f "$SCRIPT_DIR/steam_appid.txt" ]] && cp -f "$SCRIPT_DIR/steam_appid.txt" "$out_dir/"
    printf '%s\n' "$BUILD_VERSION" >"$out_dir/version.txt"
    chmod +x "$out_dir/$out_file" 2>/dev/null || true

    # Note: build.ps1 verifies its archive entry-by-entry because PowerShell's
    # Compress-Archive SILENTLY SKIPS a file it cannot open, and shipped a zip
    # with no .exe in it once (2026-08-08). Nothing here has that failure mode --
    # zip/7z/tar all report an unreadable file and every call below is checked --
    # so this stays a plain exit-code check rather than a copy of that machinery.
    # Drop this platform's previous archive. Scoped to the platform on purpose:
    # a bare ${GAME_NAME}_* sweep would delete the Linux archive that the same
    # `./build.sh` (both targets) produced thirty seconds earlier.
    local archive
    if [[ "$target" == "windows" ]]; then
        rm -f "$BUILD_DIR/${GAME_NAME}_Windows_v"*.zip
        archive="$BUILD_DIR/${GAME_NAME}_Windows_v$BUILD_VERSION.zip"
        make_zip "$out_dir" "$archive" || { say "Packaging failed: no zip, 7z or python3 available." "$C_RED"; return 1; }
    else
        rm -f "$BUILD_DIR/${GAME_NAME}_Linux_v"*.tar.gz
        # tar.gz for Linux: it is the platform convention and, unlike zip, it
        # preserves the executable bit -- a zipped Linux build extracts
        # non-executable and will not launch.
        archive="$BUILD_DIR/${GAME_NAME}_Linux_v$BUILD_VERSION.tar.gz"
        tar -czf "$archive" -C "$out_dir" . || return 1
    fi

    printf "  ${C_GREEN}%s${C_RESET}  (%s)\n" "$out_dir/$out_file" "$(du -h "$out_dir/$out_file" | cut -f1)"
    printf "  ${C_GREEN}%s${C_RESET}  (%s)\n" "$archive" "$(du -h "$archive" | cut -f1)"
    return 0
}

BUILD_OK=1
for t in $TARGETS; do
    export_target "$t" || BUILD_OK=0
done

[[ "$BUILD_OK" -eq 1 ]] || die "BUILD FAILED."

say "Build Complete!" "$C_GREEN"
if [[ "$TESTS_PASSED" -eq 0 || "$SKIP_TESTS" -eq 1 ]]; then
    say "WARNING: this build did NOT pass a clean test gate." "$C_YELLOW"
fi
