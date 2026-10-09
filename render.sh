#!/usr/bin/env bash
# render.sh - Draw the drawing layer's demo frame to a PNG with the PINNED engine.
#
#   ./render.sh                         # -> tmp/render/shot.png
#   ./render.sh tmp/render/try2.png
#
# Runs `--path . --render-shot <out>` (scripts/app/main.gd, which draws
# scripts/render/demo_frame.gd at 1280x720) and checks that a FRESH PNG came out.
# The bash twin of render.ps1; the two must stay in step.
#
# WINDOWED, ON PURPOSE: --headless replaces the renderer with a dummy that
# produces no pixels, so anything that renders is a windowed run and never a
# test. It needs a display; a Godot window opens for a moment and closes by
# itself. Steam is switched off for the run (INKWOOD_STEAM=off) unless the
# caller set it -- drawing a picture has no business touching the Steam client.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./godot_env.sh
source "$SCRIPT_DIR/godot_env.sh"
godot_require || exit 1

OUT="${1:-tmp/render/shot.png}"
case "$OUT" in
    /*) ;;
    *) OUT="$SCRIPT_DIR/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"
# A stale PNG must not pass for this run's (CLAUDE.md: a durable log is guilty
# until proven fresh) -- remove it, then require that it exists afterwards.
rm -f "$OUT"

export INKWOOD_STEAM="${INKWOOD_STEAM:-off}"

printf '\033[36mRendering the demo frame with Godot %s -> %s\033[0m\n' "$GODOT_TAG" "$OUT"
"$GODOT_BIN" --path "$SCRIPT_DIR" --render-shot "$OUT"
CODE=$?

if [[ $CODE -ne 0 ]]; then
    printf '\033[31mRender FAILED (exit code %s). Read the output above for the Parse Error or the [render-shot] line.\033[0m\n' "$CODE"
    exit 1
fi
if [[ ! -f "$OUT" ]]; then
    printf '\033[31mRender FAILED: the engine exited 0 but wrote no %s.\033[0m\n' "$OUT"
    exit 1
fi
printf '\033[32mSaved %s\033[0m\n' "$OUT"
exit 0
