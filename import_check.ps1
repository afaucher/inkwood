# import_check.ps1 - Detect and fix stale Godot import caches before a
# headless run.
#
# Godot's headless CLI (--run-test, --export-release, ...) trusts whatever is
# already sitting in .godot/imported/*.tres -- it does NOT compare source
# mtimes and reimport on load the way the editor's filesystem watcher does.
# Only an explicit `--headless --import` pass (or opening the project in the
# actual editor) regenerates that cache. So hand-editing or git-pulling any
# imported asset outside the editor leaves every headless test silently running
# against the OLD compiled resource until someone thinks to reimport.
#
# This scans every *.import sidecar in the project. As a fast pre-filter it
# compares the source file's mtime against its compiled dest_files artifact(s);
# a dest that is missing or older than its source is a *candidate*. Candidates
# are then confirmed against the real signal Godot itself uses -- the
# source_md5 recorded in the artifact's own .md5 sidecar -- before anything is
# declared stale. Content-hashing every asset on every run would be needlessly
# slow once there are hundreds of textures and models; the mtime pre-filter
# keeps the common "nothing changed" case cheap, and the hash confirmation
# avoids a permanent false "stale" (and therefore a reimport on every single
# run forever) from something that merely touched an mtime without changing
# content -- a git checkout, most commonly.
#
# A BRAND-NEW asset of an imported type has no .import sidecar at all yet, so
# the scan below cannot see it and ResourceLoader.exists() then fails on it in
# every headless run until an import pass happens. Add a per-extension check to
# Test-ImportsStale (see $NewAssetExtensions) for any file type this project
# starts hand-authoring outside the editor.
#
# Dot-source this from a caller that already has $PSScriptRoot and $godotPath,
# then call: Import-IfStale -ProjectRoot $PSScriptRoot -GodotPath $godotPath

# Extensions this project hand-authors outside the editor, i.e. ones that can
# appear with no .import sidecar. Empty for now (scenes and scripts are not
# imported resources); add e.g. "*.gltf" here when models start arriving.
$NewAssetExtensions = @()

function Test-ImportsStale {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot
    )

    foreach ($ext in $NewAssetExtensions) {
        $sources = Get-ChildItem -Path $ProjectRoot -Recurse -Filter $ext -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\\.godot\\' }
        foreach ($src in $sources) {
            if (-not (Test-Path -LiteralPath "$($src.FullName).import")) { return $true }
        }
    }

    $importFiles = Get-ChildItem -Path $ProjectRoot -Recurse -Filter "*.import" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.godot\\' }

    foreach ($imp in $importFiles) {
        $content = Get-Content -Raw -LiteralPath $imp.FullName -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        $srcMatch = [regex]::Match($content, 'source_file="([^"]+)"')
        if (-not $srcMatch.Success) { continue }
        $srcPath = Join-Path $ProjectRoot ($srcMatch.Groups[1].Value -replace '^res://', '')
        if (-not (Test-Path -LiteralPath $srcPath)) { continue }
        $srcTime = (Get-Item -LiteralPath $srcPath).LastWriteTimeUtc

        # Every compiled output path mentioned in the sidecar (dest_files=[...]
        # and the [remap] path= line both point into .godot/imported/).
        $destMatches = [regex]::Matches($content, '"(res://\.godot/imported/[^"]+)"')
        if ($destMatches.Count -eq 0) { continue }

        foreach ($d in $destMatches) {
            $destPath = Join-Path $ProjectRoot ($d.Groups[1].Value -replace '^res://', '')
            if (-not (Test-Path -LiteralPath $destPath)) { return $true }
            if ($srcTime -le (Get-Item -LiteralPath $destPath).LastWriteTimeUtc) { continue }

            # mtime says "maybe stale" -- confirm against the actual content
            # hash before trusting it.
            $md5Path = [System.IO.Path]::ChangeExtension($destPath, ".md5")
            if (-not (Test-Path -LiteralPath $md5Path)) { return $true }
            $md5Content = Get-Content -Raw -LiteralPath $md5Path -ErrorAction SilentlyContinue
            $recordedMatch = [regex]::Match($md5Content, 'source_md5="([^"]+)"')
            if (-not $recordedMatch.Success) { return $true }

            $actualHash = (Get-FileHash -Algorithm MD5 -LiteralPath $srcPath).Hash
            if ($actualHash -ne $recordedMatch.Groups[1].Value) { return $true }
        }
    }

    return $false
}

function Import-IfStale {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$GodotPath
    )

    # A checkout with no .godot/ at all (a fresh clone, or a new git worktree --
    # .godot/ is not tracked) is NOT a runnable project: every run dies in a
    # parse-error cascade before reaching the test, because there is no global
    # class cache and no import cache. Import first, unconditionally.
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot ".godot"))) {
        Write-Host "No .godot/ cache in this checkout -- running the initial import pass..." -ForegroundColor Yellow
        & $GodotPath --headless --path "$ProjectRoot" --import | Out-Null
        Write-Host "Initial import complete." -ForegroundColor Yellow
        return
    }

    if (Test-ImportsStale -ProjectRoot $ProjectRoot) {
        Write-Host "Stale imported resource cache detected (an imported asset changed since it was last compiled). Reimporting..." -ForegroundColor Yellow
        & $GodotPath --headless --path "$ProjectRoot" --import | Out-Null
        Write-Host "Reimport complete." -ForegroundColor Yellow
    }
}
