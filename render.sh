#!/usr/bin/env bash
# render.sh - Draw a frame to a PNG with the PINNED engine.
#
#   ./render.sh                         # the drawing layer's demo frame -> tmp/render/shot.png
#   ./render.sh tmp/render/try2.png
#   ./render.sh --scene 20261009        # the scene for a seed -> tmp/render/scene_20261009.png
#   ./render.sh --scene 20261009 --no-grain --parity tmp/render/parity.png
#
# Without --scene: `--path . --render-shot <out>` (scripts/app/main.gd, which
# draws scripts/render/demo_frame.gd at 1280x720).
# With --scene <seed>: `--path . --render-scene <seed> <out>` -- the scene
# generator (scripts/world/scene_gen.gd) and the port of the prototype's draw
# routines (scripts/render/ink_renderer.gd), 1280x720. Scene-only flags:
#   --no-grain      grain pass off (the browser's grain is Math.random, so a
#                   pixel comparison with a capture runs with grain off on both sides)
#   --parity        parameters that carry a prototype_default in
#                   data/params/render_defaults.json set back to it (shadow
#                   strength 0.92 instead of the decided 0.44), to compare with
#                   the prototype at its own defaults
#   --paper-shader  the paper tint from the GPU twin instead of GDScript fbm (faster)
# Either way the script checks that a FRESH PNG came out.
# The bash twin of render.ps1; the two must stay in step.
#
# WINDOWED, ON PURPOSE: --headless replaces the renderer with a dummy that
# produces no pixels, so anything that renders is a windowed run and never a
# test. It needs a display; a Godot window opens for a moment and closes by
# itself. Steam is switched off for the run (INKWOOD_STEAM=off) unless the
# caller set it -- drawing a picture has no business touching the Steam client.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCENE=""
OUT=""
EXTRA=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scene)
            if [[ $# -lt 2 ]]; then
                printf '\033[31mRender FAILED: --scene needs a seed.\033[0m\n'; exit 1
            fi
            SCENE="$2"; shift 2 ;;
        --no-grain|--parity|--paper-shader)
            EXTRA+=("$1"); shift ;;
        -*)
            printf '\033[31mRender FAILED: unknown option %s\033[0m\n' "$1"; exit 1 ;;
        *)
            OUT="$1"; shift ;;
    esac
done
if [[ -n "$SCENE" && ! "$SCENE" =~ ^-?[0-9]+$ ]]; then
    printf '\033[31mRender FAILED: --scene takes an integer seed, got %s\033[0m\n' "$SCENE"; exit 1
fi
if [[ -z "$SCENE" && ${#EXTRA[@]} -gt 0 ]]; then
    printf '\033[31mRender FAILED: --no-grain, --parity and --paper-shader apply to --scene renders only.\033[0m\n'; exit 1
fi
if [[ -z "$OUT" ]]; then
    if [[ -n "$SCENE" ]]; then OUT="tmp/render/scene_$SCENE.png"; else OUT="tmp/render/shot.png"; fi
fi

# shellcheck source=./godot_env.sh
source "$SCRIPT_DIR/godot_env.sh"
godot_require || exit 1

case "$OUT" in
    /*) ;;
    *) OUT="$SCRIPT_DIR/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"
# A stale PNG must not pass for this run's (CLAUDE.md: a durable log is guilty
# until proven fresh) -- remove it, then require that it exists afterwards.
rm -f "$OUT"

export INKWOOD_STEAM="${INKWOOD_STEAM:-off}"

if [[ -n "$SCENE" ]]; then
    printf '\033[36mRendering scene %s with Godot %s -> %s\033[0m\n' "$SCENE" "$GODOT_TAG" "$OUT"
    "$GODOT_BIN" --path "$SCRIPT_DIR" --render-scene "$SCENE" "$OUT" ${EXTRA[@]+"${EXTRA[@]}"}
else
    printf '\033[36mRendering the demo frame with Godot %s -> %s\033[0m\n' "$GODOT_TAG" "$OUT"
    "$GODOT_BIN" --path "$SCRIPT_DIR" --render-shot "$OUT"
fi
CODE=$?

if [[ $CODE -ne 0 ]]; then
    printf '\033[31mRender FAILED (exit code %s). Read the output above for the Parse Error or the [render-shot] / [render-scene] line.\033[0m\n' "$CODE"
    exit 1
fi
if [[ ! -f "$OUT" ]]; then
    printf '\033[31mRender FAILED: the engine exited 0 but wrote no %s.\033[0m\n' "$OUT"
    exit 1
fi
printf '\033[32mSaved %s\033[0m\n' "$OUT"
exit 0
