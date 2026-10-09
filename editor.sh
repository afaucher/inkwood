#!/usr/bin/env bash
# editor.sh - Open this project in the engine it is PINNED to (godot.manifest).
#
#   ./editor.sh              # open the editor
#   ./editor.sh --version    # anything you pass is forwarded to the engine
#
# Use this rather than double-clicking project.godot. A .godot file opens in
# whichever Godot the desktop happens to have associated with it -- on a machine
# with several installs that is a coin flip, and opening a project in the wrong
# engine is not a harmless mistake: a NEWER editor silently rewrites
# project.godot, the scenes and the .import cache into its own format, and the
# pinned engine can no longer load what it left behind.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./godot_env.sh
source "$SCRIPT_DIR/godot_env.sh"
godot_require || exit 1

printf '\033[36mOpening %s in Godot %s\033[0m\n' "$SCRIPT_DIR" "$GODOT_TAG"
exec "$GODOT_BIN" --editor --path "$SCRIPT_DIR" "$@"
