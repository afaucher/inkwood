#!/usr/bin/env bash
# godot_env.sh - Install and VERIFY the engine this project is pinned to, inside
# the repo. Sourced by build.sh, test_runner.sh and editor.sh; godot_env.ps1 is
# the PowerShell twin and the two must stay in step.
#
# THE BUILD BRINGS ITS OWN DEPENDENCIES AND TOUCHES NOTHING ELSE ON THE MACHINE.
# That is the whole design, and it cuts both ways:
#
#   - Nothing outside the repo is READ. An engine on $PATH is not reused, however
#     plausible it looks -- on a machine set up for other Godot work `godot` is
#     as likely to be 4.7-mono as anything, and a build whose engine depends on
#     what else the developer has installed is not a build anyone can reproduce.
#   - Nothing outside the repo is WRITTEN. Export templates normally land in the
#     user's Godot data directory, shared with every other project they have;
#     this points Godot at a data directory inside build/deps instead (see
#     godot_export_env), so a teammate's own Godot setup is never modified and
#     never collides with ours.
#
# The version comes from godot.manifest and nothing accepts a binary that
# reports a different one: an engine mismatch is the worst-shaped bug this repo
# has (CLAUDE.md, "a non-resource file is NOT exported") -- it produces a shipped
# artifact that no test run can see is wrong.
#
# Layout (all of build/ is gitignored):
#   build/deps/godot/<tag>/Godot_v<tag>_linux.x86_64      the engine
#   build/deps/godot-data/godot/export_templates/<ver>/   the export templates
#   build/linux/  build/windows/                          export output
#
# Usage:
#   source godot_env.sh
#   godot_require || exit 1                # sets GODOT_BIN, GODOT_TAG,
#                                          #      GODOT_TEMPLATE_VERSION, and the
#                                          #      XDG vars Godot reads
#   godot_require_templates linux windows  # sets GODOT_TEMPLATE_DIR
#
# Environment overrides:
#   INKWOOD_GODOT_VERSION   use this tag instead of the manifest's
#   INKWOOD_GODOT_MIRROR    base URL for release assets (a CI cache, a proxy)

GODOT_ENV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GODOT_MANIFEST="$GODOT_ENV_ROOT/godot.manifest"
GODOT_DEPS_DIR="$GODOT_ENV_ROOT/build/deps"
GODOT_DATA_DIR="$GODOT_DEPS_DIR/godot-data"
GODOT_MIRROR="${INKWOOD_GODOT_MIRROR:-https://github.com/godotengine/godot-builds/releases/download}"

_godot_say()  { printf '\033[36m%s\033[0m\n' "$1"; }
_godot_warn() { printf '\033[33m%s\033[0m\n' "$1"; }
_godot_err()  { printf '\033[31m%s\033[0m\n' "$1" >&2; }

# --- Manifest ----------------------------------------------------------------

# Sets GODOT_TAG (release tag, e.g. 4.4.1-stable) and GODOT_TEMPLATE_VERSION
# (the same thing in the dotted form Godot itself reports and names its export
# template directory with, e.g. 4.4.1.stable).
godot_manifest_tag() {
    local tag=""
    if [[ -n "${INKWOOD_GODOT_VERSION:-}" ]]; then
        tag="$INKWOOD_GODOT_VERSION"
    elif [[ -f "$GODOT_MANIFEST" ]]; then
        tag="$(sed -n -e 's/#.*//' -e 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*//p' \
               "$GODOT_MANIFEST" | head -n1 | tr -d '[:space:]')"
    else
        _godot_err "No engine manifest at $GODOT_MANIFEST."
        _godot_err "It is committed -- a checkout missing it is incomplete, not misconfigured."
        return 1
    fi

    # Validate here rather than letting a typo become a 404 three steps later,
    # when the message is about a missing file on a URL nobody typed.
    if [[ ! "$tag" =~ ^[0-9]+(\.[0-9]+){1,2}-(stable|beta[0-9]*|rc[0-9]*|dev[0-9]*)$ ]]; then
        _godot_err "Not a Godot release tag: '$tag'"
        _godot_err "Expected e.g. 4.4.1-stable, 4.5-stable, 4.5-beta3 (see $GODOT_MANIFEST)."
        return 1
    fi

    GODOT_TAG="$tag"
    GODOT_TEMPLATE_VERSION="${tag//-/.}"
    return 0
}

# --- Where Godot keeps its data ----------------------------------------------
#
# Godot has no flag for "find your export templates over here": it looks in its
# user data directory, and on Linux that directory is whatever XDG_DATA_HOME
# says. So pointing the variable at build/deps is how the templates end up in
# the repo instead of in ~/.local/share/godot alongside the developer's own
# Godot installs. XDG_CONFIG_HOME comes along so a run cannot pick up editor
# settings from another project either -- two teammates' builds should not
# differ because one of them once changed an editor setting.
#
# Exported, so every child of the calling script inherits it (import_check.sh
# and test_runner.sh both launch the engine themselves). The cache dir is
# deliberately left alone: a shader cache is not a dependency, and redirecting
# it buys nothing.
godot_export_env() {
    mkdir -p "$GODOT_DATA_DIR" || return 1
    export XDG_DATA_HOME="$GODOT_DATA_DIR"
    export XDG_CONFIG_HOME="$GODOT_DATA_DIR/config"

    # build/ IS INSIDE res://, so everything above lands in the project's own
    # resource tree -- and `export_filter="all_resources"` then sweeps it into
    # the shipped .pck. Observed 2026-08-10: the engine's own
    # editor_settings-4.4.tres was packed into the game, absolute developer path
    # and all. A .gdignore takes the directory out of EditorFileSystem entirely,
    # so nothing under build/ is scanned, imported or exported.
    #
    # It cannot be committed: build/ is gitignored, and git will not honour a
    # negation for a path inside an excluded directory -- so it is written here,
    # before any engine run. export_presets.cfg carries an exclude_filter for
    # the same paths as a committed backstop.
    [[ -f "$GODOT_ENV_ROOT/build/.gdignore" ]] || : >"$GODOT_ENV_ROOT/build/.gdignore"

    # tmp/ IS THE SAME TRAP AND IT FIRED 2026-08-15: a scratch copy of two
    # scripts, made for an A/B and left in tmp/ for ninety seconds, was packed
    # into the shipped game as res://tmp/ab/*.gdc. CLAUDE.md sends every
    # throwaway file to tmp/, so this directory is BY DESIGN full of things that
    # must never ship -- stale copies of real scripts most of all, since a
    # duplicate class in the .pck is a genuinely confusing thing to debug.
    mkdir -p "$GODOT_ENV_ROOT/tmp"
    [[ -f "$GODOT_ENV_ROOT/tmp/.gdignore" ]] || : >"$GODOT_ENV_ROOT/tmp/.gdignore"
    return 0
}

# --- Fetch / extract helpers -------------------------------------------------

_godot_fetch() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$out" "$url"
    else
        _godot_err "Neither curl nor wget is installed; cannot download $url"
        return 1
    fi
}

# _godot_unzip <archive> <dest> [member-glob...]
#
# With no globs, extracts everything preserving paths; with globs, extracts just
# the matching members FLAT into dest. unzip is not installed everywhere -- 7z
# and python3's stdlib zipfile are equivalent here, and the exec bit is set
# explicitly by the callers, so python3 dropping it does not matter.
_godot_unzip() {
    local zip="$1" dest="$2"; shift 2
    mkdir -p "$dest" || return 1

    if [[ $# -eq 0 ]]; then
        if command -v unzip >/dev/null 2>&1; then unzip -q -o "$zip" -d "$dest"
        elif command -v 7z >/dev/null 2>&1; then 7z x -y -o"$dest" "$zip" >/dev/null
        elif command -v python3 >/dev/null 2>&1; then
            python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$zip" "$dest"
        else
            _godot_err "No unzip, 7z or python3 available to extract $zip"
            return 1
        fi
        return $?
    fi

    if command -v unzip >/dev/null 2>&1; then
        unzip -q -j -o "$zip" "$@" -d "$dest"
    elif command -v 7z >/dev/null 2>&1; then
        7z e -y -o"$dest" "$zip" "$@" >/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$zip" "$dest" "$@" <<'PY'
import fnmatch, os, shutil, sys, zipfile
zip_path, dest, pats = sys.argv[1], sys.argv[2], sys.argv[3:]
with zipfile.ZipFile(zip_path) as z:
    for name in z.namelist():
        if name.endswith("/"):
            continue
        if any(fnmatch.fnmatch(name, p) for p in pats):
            with z.open(name) as src, open(os.path.join(dest, os.path.basename(name)), "wb") as out:
                shutil.copyfileobj(src, out)
PY
    else
        _godot_err "No unzip, 7z or python3 available to extract $zip"
        return 1
    fi
}

# The one question that matters about a binary on disk: is it the pinned build?
# `--version` prints e.g. "4.4.1.stable.official.49a5bc7b6".
_godot_version_ok() {
    local bin="$1" reported
    [[ -x "$bin" ]] || return 1
    reported="$("$bin" --version 2>/dev/null | tr -d '\r' | head -n1)"
    [[ "$reported" == "$GODOT_TEMPLATE_VERSION" || "$reported" == "$GODOT_TEMPLATE_VERSION".* ]]
}

# --- Engine ------------------------------------------------------------------

_godot_engine_dir()  { printf '%s/godot/%s' "$GODOT_DEPS_DIR" "$GODOT_TAG"; }
_godot_engine_path() { printf '%s/Godot_v%s_linux.x86_64' "$(_godot_engine_dir)" "$GODOT_TAG"; }

_godot_install_engine() {
    local dir bin asset url tmp found
    dir="$(_godot_engine_dir)"
    bin="$(_godot_engine_path)"
    asset="Godot_v${GODOT_TAG}_linux.x86_64.zip"
    url="$GODOT_MIRROR/$GODOT_TAG/$asset"

    mkdir -p "$GODOT_DEPS_DIR" || return 1
    # Staged inside build/deps so the final move is same-filesystem and therefore
    # atomic: a half-downloaded engine must never appear at the real path, where
    # the next run would trust it.
    tmp="$(mktemp -d "$GODOT_DEPS_DIR/.godot-install.XXXXXX")" || return 1

    _godot_say "Installing Godot $GODOT_TAG (~60 MB) into ${dir#$GODOT_ENV_ROOT/}..."
    _godot_say "  $url"
    if ! _godot_fetch "$url" "$tmp/$asset"; then
        rm -rf "$tmp"
        _godot_err "Download failed. Is '$GODOT_TAG' a real tag? https://github.com/godotengine/godot-builds/releases"
        return 1
    fi
    if ! _godot_unzip "$tmp/$asset" "$tmp/x"; then rm -rf "$tmp"; return 1; fi

    # Locate by pattern rather than by assumed name: the archive's internal
    # layout is upstream's to change, and a find that comes back empty is a
    # clear failure, where a hardcoded path that misses is a confusing one.
    found="$(find "$tmp/x" -type f -name 'Godot_v*_linux.x86_64' | head -n1)"
    if [[ -z "$found" ]]; then
        rm -rf "$tmp"
        _godot_err "$asset did not contain a Linux engine binary."
        return 1
    fi

    chmod +x "$found"
    mkdir -p "$dir" || { rm -rf "$tmp"; return 1; }
    mv -f "$found" "$bin" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"

    # Verify what landed, not what was asked for.
    if ! _godot_version_ok "$bin"; then
        _godot_err "Installed engine does not report $GODOT_TEMPLATE_VERSION: $("$bin" --version 2>&1 | head -n1)"
        rm -f "$bin"
        return 1
    fi
    _godot_say "Godot $GODOT_TAG installed."
    return 0
}

# Sets GODOT_BIN to the repo's own verified engine, installing it if necessary,
# and redirects Godot's data directory into the repo.
godot_require() {
    godot_manifest_tag || return 1
    godot_export_env || return 1

    local host; host="$(uname -s)"
    if [[ "$host" != "Linux" ]]; then
        _godot_err "godot_env.sh installs a Linux host engine (this host is $host)."
        _godot_err "On Windows use build.ps1 / test_runner.ps1 / editor.ps1, which read the same manifest."
        return 1
    fi

    local bin; bin="$(_godot_engine_path)"
    if ! _godot_version_ok "$bin"; then
        # Covers both "not there yet" and "there but wrong or truncated" -- a
        # binary that fails the version check is not a binary worth keeping.
        _godot_install_engine || return 1
    fi
    GODOT_BIN="$bin"
    return 0
}

# --- Export templates --------------------------------------------------------
#
# Installed into the repo's own data directory, NOT the developer's. Only the
# release templates for the targets being exported are unpacked: the .tpz
# carries every platform Godot supports (~1.2 GB) and this project ships two, so
# keeping the lot would cost a gigabyte per checkout for files no export reads.
#
# The archive is all-or-nothing, so a checkout that exports linux today and
# windows next week downloads it twice. That is the accepted cost of not
# unpacking templates a build never asked for; `./build.sh` with no --target
# covers both in one pass.

_godot_template_file() {
    case "$1" in
        linux)   printf 'linux_release.x86_64' ;;
        windows) printf 'windows_release_x86_64.exe' ;;
        *)       return 1 ;;
    esac
}

# The archive members to unpack for a target. Every glob here MUST match at
# least one member: `unzip` exits 11 on a pattern that matched nothing, so a
# speculative extra pattern would fail the whole install rather than being
# quietly skipped. Windows takes a trailing * to pick up the console wrapper
# template if that version ships one; Linux has no such sibling.
_godot_template_glob() {
    case "$1" in
        linux)   printf 'templates/linux_release.x86_64' ;;
        windows) printf 'templates/windows_release_x86_64*' ;;
        *)       return 1 ;;
    esac
}

godot_template_dir() {
    printf '%s/godot/export_templates/%s' "$GODOT_DATA_DIR" "$GODOT_TEMPLATE_VERSION"
}

# godot_require_templates <target...>   (targets: linux, windows)
godot_require_templates() {
    [[ -n "${GODOT_TAG:-}" ]] || godot_manifest_tag || return 1
    GODOT_TEMPLATE_DIR="$(godot_template_dir)"

    local t file missing=0 patterns=()
    for t in "$@"; do
        file="$(_godot_template_file "$t")" || { _godot_err "Unknown export target: $t"; return 1; }
        [[ -f "$GODOT_TEMPLATE_DIR/$file" ]] || missing=1
        patterns+=("$(_godot_template_glob "$t")")
    done
    [[ "$missing" -eq 1 ]] || return 0

    local asset url tmp
    asset="Godot_v${GODOT_TAG}_export_templates.tpz"
    url="$GODOT_MIRROR/$GODOT_TAG/$asset"
    mkdir -p "$GODOT_DEPS_DIR" || return 1
    tmp="$(mktemp -d "$GODOT_DEPS_DIR/.templates.XXXXXX")" || return 1

    _godot_say "Export templates for $GODOT_TEMPLATE_VERSION not installed. Downloading (~1.2 GB)..."
    _godot_say "  $url"
    if ! _godot_fetch "$url" "$tmp/$asset"; then
        rm -rf "$tmp"
        _godot_err "Could not download export templates."
        return 1
    fi

    # A .tpz is an ordinary zip with a top-level templates/ folder -- unzip does
    # not care about the extension. (This is exactly what trips up PowerShell's
    # Expand-Archive, which validates the extension and not the file; see
    # godot_env.ps1.)
    _godot_say "Unpacking the $* templates..."
    if ! _godot_unzip "$tmp/$asset" "$tmp/x" "${patterns[@]}"; then rm -rf "$tmp"; return 1; fi

    mkdir -p "$GODOT_TEMPLATE_DIR" || { rm -rf "$tmp"; return 1; }
    # Godot checks this file to decide the directory holds templates for that
    # version at all.
    printf '%s\n' "$GODOT_TEMPLATE_VERSION" >"$GODOT_TEMPLATE_DIR/version.txt"
    chmod +x "$tmp/x/"* 2>/dev/null
    mv -f "$tmp/x/"* "$GODOT_TEMPLATE_DIR/" 2>/dev/null
    rm -rf "$tmp"

    for t in "$@"; do
        file="$(_godot_template_file "$t")"
        if [[ ! -f "$GODOT_TEMPLATE_DIR/$file" ]]; then
            _godot_err "Template $file missing from $GODOT_TEMPLATE_DIR after install."
            return 1
        fi
    done
    _godot_say "Export templates installed."
    return 0
}
