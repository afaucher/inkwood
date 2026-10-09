#!/usr/bin/env bash
# import_check.sh - Linux port of import_check.ps1. See that file for the full
# reasoning; the short version:
#
# Godot's headless CLI trusts whatever is already in .godot/imported/ -- it does
# NOT reimport changed sources the way the editor does. So a git pull or a
# hand-edit leaves every headless run silently testing the OLD compiled
# resource. And a checkout with no .godot/ at all (fresh clone, new git
# worktree) is not runnable: it dies in a parse-error cascade before reaching
# the test, because there is no global class cache either.
#
# Source this, then call: import_if_stale "$PROJECT_ROOT" "$GODOT_PATH"

# mtime says "maybe"; the recorded source_md5 says "yes". Hashing every asset
# every run would be slow; trusting mtime alone false-stales on every checkout.
_import_dest_is_stale() {
    local src="$1" dest="$2"
    [[ -f "$dest" ]] || return 0
    [[ "$src" -nt "$dest" ]] || return 1

    local md5_file="${dest%.*}.md5"
    [[ -f "$md5_file" ]] || return 0
    local recorded
    recorded="$(sed -n 's/^source_md5="\(.*\)"$/\1/p' "$md5_file")"
    [[ -n "$recorded" ]] || return 0
    local actual
    actual="$(md5sum "$src" | cut -d' ' -f1)"
    [[ "$actual" != "$recorded" ]]
}

imports_are_stale() {
    local root="$1"
    local imp src dest
    while IFS= read -r imp; do
        src="$(sed -n 's/^source_file="res:\/\/\(.*\)"$/\1/p' "$imp" | head -n1)"
        [[ -n "$src" ]] || continue
        src="$root/$src"
        [[ -f "$src" ]] || continue
        while IFS= read -r dest; do
            dest="$root/${dest#res://}"
            if _import_dest_is_stale "$src" "$dest"; then return 0; fi
        done < <(grep -o '"res://\.godot/imported/[^"]*"' "$imp" | tr -d '"' | sort -u)
    done < <(find "$root" -name '*.import' -type f -not -path '*/.godot/*')
    return 1
}

import_if_stale() {
    local root="$1" godot="$2"
    if [[ ! -d "$root/.godot" ]]; then
        printf '\033[33mNo .godot/ cache in this checkout -- running the initial import pass...\033[0m\n'
        "$godot" --headless --path "$root" --import >/dev/null 2>&1
        printf '\033[33mInitial import complete.\033[0m\n'
        return
    fi
    if imports_are_stale "$root"; then
        printf '\033[33mStale imported resource cache detected. Reimporting...\033[0m\n'
        "$godot" --headless --path "$root" --import >/dev/null 2>&1
        printf '\033[33mReimport complete.\033[0m\n'
    fi
}
