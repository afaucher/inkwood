#!/usr/bin/env bash
# test_runner.sh - Linux port of test_runner.ps1. Runs one headless test by name.
#
#   ./test_runner.sh test_smoke
#
# Mirrors the PowerShell runner exactly: same --fixed-fps 60, same stale-import
# pre-check, same 600s hang timeout, same pass/fail exit codes. Logs go to
# test_logs/<name>.log and .err.log -- read those, not this script's stdout.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/test_logs"
TEST_TIMEOUT_SEC=600

C_CYAN='\033[36m'; C_GREEN='\033[32m'; C_RED='\033[31m'; C_RESET='\033[0m'

# Usage check FIRST: listing the tests must not install a 60 MB engine.
TEST_NAME="${1:-}"
if [[ -z "$TEST_NAME" ]]; then
    printf "Usage: ./test_runner.sh <name>   (a file in scripts/tests/<name>.gd)\n"
    printf "${C_CYAN}Available tests:${C_RESET}\n"
    find "$SCRIPT_DIR/scripts/tests" -maxdepth 1 -name '*.gd' -printf '  %f\n' | sed 's/\.gd$//' | sort
    exit 1
fi

# The engine version is pinned in godot.manifest and installed under build/deps
# on first use -- see godot_env.sh. build.sh resolves it once up front, so the
# parallel gate finds it already there rather than N runners racing to fetch it.
# shellcheck source=./godot_env.sh
source "$SCRIPT_DIR/godot_env.sh"
godot_require || exit 1
GODOT_PATH="$GODOT_BIN"

# shellcheck source=./import_check.sh
source "$SCRIPT_DIR/import_check.sh"
import_if_stale "$SCRIPT_DIR" "$GODOT_PATH"

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$TEST_NAME.log"
ERR_FILE="$LOG_DIR/$TEST_NAME.err.log"
rm -f "$LOG_FILE" "$ERR_FILE"

printf "${C_CYAN}Running test: %s${C_RESET}\n" "$TEST_NAME"

# --fixed-fps 60: headless Godot otherwise SLEEPS to hold 60Hz, so a
# frame-counted test takes its simulated duration in real wall clock, and that
# sleep does not parallelize under a full gate. Same delta, same frame counts,
# no sleeping. See CLAUDE.md.
START="$(date +%s.%N)"
timeout --signal=KILL "$TEST_TIMEOUT_SEC" \
    "$GODOT_PATH" --path "$SCRIPT_DIR" --headless --fixed-fps 60 --run-test "$TEST_NAME" \
    >"$LOG_FILE" 2>"$ERR_FILE"
CODE=$?
ELAPSED="$(awk -v s="$START" 'BEGIN { printf "%.2f", systime() - s }' </dev/null 2>/dev/null || echo "?")"

if [[ $CODE -eq 137 || $CODE -eq 124 ]]; then
    printf "\n  ${C_RED}>>> [TEST FAILED] %s (TIMEOUT -- killed after %ss) <<<${C_RESET}\n" "$TEST_NAME" "$TEST_TIMEOUT_SEC"
    tail -n 40 "$LOG_FILE"
    exit 1
fi

# BOTH conditions: a test that crashes after printing its marker still exits
# non-zero, and a test that exits 0 without asserting never printed one.
if [[ $CODE -eq 0 ]] && grep -q '\[TEST PASSED\]' "$LOG_FILE"; then
    printf "\n  ${C_GREEN}>>> [TEST PASSED] %s (%ss) <<<${C_RESET}\n" "$TEST_NAME" "$ELAPSED"
    exit 0
fi

printf "\n  ${C_RED}>>> [TEST FAILED] %s (%ss) <<<${C_RESET}\n" "$TEST_NAME" "$ELAPSED"
printf "Exit code: %s\n" "$CODE"
cat "$LOG_FILE"
# The real message for a PARSE error appears ONLY here, never in the summary.
if [[ -s "$ERR_FILE" ]]; then
    printf -- "--- stderr ---\n"
    cat "$ERR_FILE"
fi
exit 1
