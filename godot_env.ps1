# godot_env.ps1 - Install and VERIFY the engine this project is pinned to,
# inside the repo. Dot-sourced by build.ps1, test_runner.ps1 and editor.ps1;
# godot_env.sh is the bash twin and the two must stay in step.
#
# THE BUILD BRINGS ITS OWN DEPENDENCIES AND TOUCHES NOTHING ELSE ON THE MACHINE.
# That is the whole design, and it cuts both ways:
#
#   - Nothing outside the repo is READ. An engine already installed on the
#     machine is not reused, however plausible it looks -- a build whose engine
#     depends on what else the developer has installed is not a build anyone can
#     reproduce.
#   - Nothing outside the repo is WRITTEN. Export templates normally land in
#     %APPDATA%\Godot, shared with every other project that developer has; this
#     points Godot at a data directory inside build\deps instead (see
#     Set-GodotDataDir), so a teammate's own Godot setup is never modified and
#     never collides with ours.
#
# The version comes from godot.manifest and nothing accepts a binary that
# reports a different one: an engine mismatch is the worst-shaped bug this repo
# has (CLAUDE.md, "a non-resource file is NOT exported") -- it produces a shipped
# artifact that no test run can see is wrong.
#
# Layout (all of build\ is gitignored):
#   build\deps\godot\<tag>\Godot_v<tag>_win64.exe       the engine (+ _console)
#   build\deps\godot-data\Godot\export_templates\<ver>  the export templates
#   build\windows\                                      export output
#
# Usage:
#   . "$PSScriptRoot\godot_env.ps1"
#   $godot = Resolve-GodotEngine          # .Path .ConsolePath .Tag .TemplateVersion
#   Install-GodotTemplates -Engine $godot -Targets windows
#
# Environment overrides:
#   INKWOOD_GODOT_VERSION   use this tag instead of the manifest's
#   INKWOOD_GODOT_MIRROR    base URL for release assets (a CI cache, a proxy)

$GodotEnvRoot = $PSScriptRoot
$GodotManifestPath = Join-Path $GodotEnvRoot "godot.manifest"
$GodotDepsDir = Join-Path $GodotEnvRoot "build\deps"
$GodotDataDir = Join-Path $GodotDepsDir "godot-data"
$GodotMirror = if ($env:INKWOOD_GODOT_MIRROR) { $env:INKWOOD_GODOT_MIRROR } else {
    "https://github.com/godotengine/godot-builds/releases/download"
}

# Godot has no flag for "find your export templates over here": it looks in its
# user data directory, and on Windows that directory is %APPDATA%\Godot -- read
# from the environment variable, so redirecting it is how the templates end up
# in the repo instead of alongside the developer's own Godot installs. Set on
# this process, which every child (the engine, and the test_runner.ps1 workers
# build.ps1 spawns) inherits; nothing outside this process is affected.
function Set-GodotDataDir {
    New-Item -ItemType Directory -Force -Path $GodotDataDir | Out-Null
    $env:APPDATA = $GodotDataDir

    # build\ IS INSIDE res://, so everything above lands in the project's own
    # resource tree -- and `export_filter="all_resources"` then sweeps it into
    # the shipped .pck. Observed 2026-08-10: the engine's own
    # editor_settings-4.4.tres was packed into the game, absolute developer path
    # and all. A .gdignore takes the directory out of EditorFileSystem entirely,
    # so nothing under build\ is scanned, imported or exported.
    #
    # It cannot be committed: build\ is gitignored, and git will not honour a
    # negation for a path inside an excluded directory -- so it is written here,
    # before any engine run. export_presets.cfg carries an exclude_filter for
    # the same paths as a committed backstop.
    $gdignore = Join-Path $GodotEnvRoot "build\.gdignore"
    if (-not (Test-Path -LiteralPath $gdignore)) { New-Item -ItemType File -Path $gdignore -Force | Out-Null }

    # tmp/ IS THE SAME TRAP AND IT FIRED 2026-08-15: a scratch copy of two
    # scripts, made for an A/B and left in tmp/ for ninety seconds, was packed
    # into the shipped game as res://tmp/ab/*.gdc. CLAUDE.md sends every
    # throwaway file to tmp/, so this directory is BY DESIGN full of things that
    # must never ship -- stale copies of real scripts most of all, since a
    # duplicate class in the .pck is a genuinely confusing thing to debug.
    $tmpDir = Join-Path $GodotEnvRoot "tmp"
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $tmpIgnore = Join-Path $tmpDir ".gdignore"
    if (-not (Test-Path -LiteralPath $tmpIgnore)) { New-Item -ItemType File -Path $tmpIgnore -Force | Out-Null }
}

# A PATH inherited as a User+Machine pair can leave the process copy stale in
# some hosts; re-stamping it makes child processes see what the shell sees.
function Normalize-ProcessPath {
    if ($env:PATH) {
        $env:Path = $env:PATH
        [Environment]::SetEnvironmentVariable("PATH", $null, "Process")
    }
}

function Write-GodotErr { param([string]$Message) Write-Host $Message -ForegroundColor Red }
function Write-GodotSay { param([string]$Message) Write-Host $Message -ForegroundColor Cyan }

# --- Manifest -----------------------------------------------------------------

# Returns the release tag (e.g. 4.4.1-stable) and the dotted form Godot itself
# reports and names its export template directory with (e.g. 4.4.1.stable).
function Get-GodotPin {
    $tag = $null
    if ($env:INKWOOD_GODOT_VERSION) {
        $tag = $env:INKWOOD_GODOT_VERSION
    } elseif (Test-Path -LiteralPath $GodotManifestPath) {
        foreach ($line in Get-Content -LiteralPath $GodotManifestPath) {
            $stripped = $line -replace '#.*', ''
            $m = [regex]::Match($stripped, '^\s*version\s*=\s*(\S+)\s*$')
            if ($m.Success) { $tag = $m.Groups[1].Value; break }
        }
    } else {
        Write-GodotErr "No engine manifest at $GodotManifestPath."
        Write-GodotErr "It is committed -- a checkout missing it is incomplete, not misconfigured."
        exit 1
    }

    # Validate here rather than letting a typo become a 404 three steps later,
    # when the message is about a missing file on a URL nobody typed.
    if (-not $tag -or $tag -notmatch '^\d+(\.\d+){1,2}-(stable|beta\d*|rc\d*|dev\d*)$') {
        Write-GodotErr "Not a Godot release tag: '$tag'"
        Write-GodotErr "Expected e.g. 4.4.1-stable, 4.5-stable, 4.5-beta3 (see $GodotManifestPath)."
        exit 1
    }

    return [PSCustomObject]@{
        Tag             = $tag
        TemplateVersion = $tag.Replace('-', '.')
    }
}

# --- Fetch / extract helpers --------------------------------------------------

function Get-GodotDownload {
    param([string]$Uri, [string]$OutFile)

    # PS 5.1 (the Windows default) does not negotiate TLS 1.2 on every box, and
    # GitHub requires it -- force it or the download fails outright.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Invoke-WebRequest's progress bar makes a large download roughly an order of
    # magnitude slower in PS 5.1. Suppress it for the transfer.
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        # -ErrorAction Stop: these cmdlets raise NON-terminating errors by
        # default, so without it a failure prints red and the caller carries on
        # into a step that never had a chance.
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -ErrorAction Stop
    } finally {
        $ProgressPreference = $oldProgress
    }
}

# The one question that matters about a binary on disk: is it the pinned build?
# `--version` prints e.g. "4.4.1.stable.official.49a5bc7b6".
function Test-GodotVersion {
    param([string]$Path, [string]$TemplateVersion)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }

    # Prefer the console wrapper when it sits alongside: the plain editor binary
    # is a GUI-subsystem exe, and while explicit redirection does capture its
    # stdout, the console build is the one guaranteed to answer here.
    $probe = $Path
    $console = $Path -replace '\.exe$', '_console.exe'
    if ($Path -notmatch '_console\.exe$' -and (Test-Path -LiteralPath $console)) { $probe = $console }

    try {
        $reported = (& $probe --version 2>&1 | Out-String).Trim()
    } catch {
        return $false
    }
    $first = ($reported -split "`r?`n") | Select-Object -First 1
    return ($first -eq $TemplateVersion -or $first.StartsWith("$TemplateVersion."))
}

# --- Engine -------------------------------------------------------------------

function Install-GodotEngine {
    param([PSCustomObject]$Pin, [string]$Dir)

    $asset = "Godot_v$($Pin.Tag)_win64.exe.zip"
    $url = "$GodotMirror/$($Pin.Tag)/$asset"

    New-Item -ItemType Directory -Force -Path $GodotDepsDir | Out-Null
    # Staged inside build\deps so the final move is same-volume: a
    # half-extracted engine must never appear at the real path, where the next
    # run would trust it.
    $tmp = Join-Path $GodotDepsDir (".godot-install." + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    Write-GodotSay "Installing Godot $($Pin.Tag) (~60 MB download) into $Dir..."
    Write-GodotSay "  $url"
    try {
        $zip = Join-Path $tmp $asset
        Get-GodotDownload -Uri $url -OutFile $zip
        Expand-Archive -Path $zip -DestinationPath (Join-Path $tmp "x") -Force -ErrorAction Stop

        # Locate by pattern rather than by assumed name: the archive's internal
        # layout is upstream's to change, and a search that comes back empty is
        # a clear failure, where a hardcoded path that misses is a confusing one.
        $exes = Get-ChildItem -Path (Join-Path $tmp "x") -Recurse -File -Filter "Godot_v*_win64*.exe"
        if (-not $exes) { throw "$asset did not contain a Windows engine binary." }

        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        foreach ($exe in $exes) {
            $target = if ($exe.Name -match '_console\.exe$') {
                Join-Path $Dir "Godot_v$($Pin.Tag)_win64_console.exe"
            } else {
                Join-Path $Dir "Godot_v$($Pin.Tag)_win64.exe"
            }
            Move-Item -LiteralPath $exe.FullName -Destination $target -Force
        }
    } catch {
        Write-GodotErr "BUILD ABORTED: could not install Godot $($Pin.Tag). $_"
        Write-GodotErr "Is '$($Pin.Tag)' a real tag? https://github.com/godotengine/godot-builds/releases"
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Returns the repo's own verified engine, installing it if necessary, and
# redirects Godot's data directory into the repo.
function Resolve-GodotEngine {
    $pin = Get-GodotPin
    Set-GodotDataDir

    $dir = Join-Path $GodotDepsDir "godot\$($pin.Tag)"
    $bin = Join-Path $dir "Godot_v$($pin.Tag)_win64.exe"

    # Covers both "not there yet" and "there but wrong or truncated" -- a binary
    # that fails the version check is not a binary worth keeping.
    if (-not (Test-GodotVersion -Path $bin -TemplateVersion $pin.TemplateVersion)) {
        Install-GodotEngine -Pin $pin -Dir $dir
        # Verify what landed, not what was asked for.
        if (-not (Test-GodotVersion -Path $bin -TemplateVersion $pin.TemplateVersion)) {
            Write-GodotErr "Installed engine at $bin does not report $($pin.TemplateVersion)."
            exit 1
        }
        Write-GodotSay "Godot $($pin.Tag) installed."
    }

    $console = $bin -replace '\.exe$', '_console.exe'
    return [PSCustomObject]@{
        Tag             = $pin.Tag
        TemplateVersion = $pin.TemplateVersion
        Path            = $bin
        ConsolePath     = if (Test-Path -LiteralPath $console) { $console } else { $bin }
    }
}

# --- Export templates ---------------------------------------------------------
#
# Installed into the repo's own data directory (build\deps\godot-data), NOT the
# developer's %APPDATA%. Only the release templates for the targets being
# exported are unpacked -- build.ps1 exports Windows, so that is all this pulls
# out. The .tpz carries every platform Godot supports (~1.2 GB); keeping the lot
# would cost a gigabyte per checkout for files no export here reads.

function Get-GodotTemplateFile {
    param([string]$Target)
    switch ($Target) {
        "linux"   { return "linux_release.x86_64" }
        "windows" { return "windows_release_x86_64.exe" }
        default   { Write-GodotErr "Unknown export target: $Target"; exit 1 }
    }
}

# Archive members to unpack for a target. Windows takes a trailing * to pick up
# the console wrapper template if that version ships one; Linux has no sibling.
function Get-GodotTemplatePattern {
    param([string]$Target)
    switch ($Target) {
        "linux"   { return "templates/linux_release.x86_64" }
        "windows" { return "templates/windows_release_x86_64*" }
        default   { Write-GodotErr "Unknown export target: $Target"; exit 1 }
    }
}

function Get-GodotTemplateDir {
    param([string]$TemplateVersion)
    return "$GodotDataDir\Godot\export_templates\$TemplateVersion"
}

function Install-GodotTemplates {
    param([PSCustomObject]$Engine, [string[]]$Targets)

    $templateDir = Get-GodotTemplateDir -TemplateVersion $Engine.TemplateVersion
    $needed = @($Targets | ForEach-Object { Get-GodotTemplateFile -Target $_ })
    $missing = @($needed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $templateDir $_)) })
    if ($missing.Count -eq 0) { return $templateDir }

    Write-GodotSay "Export templates for $($Engine.TemplateVersion) not installed. Downloading (~1.2 GB)..."

    $url = "$GodotMirror/$($Engine.Tag)/Godot_v$($Engine.Tag)_export_templates.tpz"
    New-Item -ItemType Directory -Force -Path $GodotDepsDir | Out-Null
    $tmp = Join-Path $GodotDepsDir (".templates." + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null

    try {
        $tpz = Join-Path $tmp "export_templates.tpz"
        Write-GodotSay "  $url"
        Get-GodotDownload -Uri $url -OutFile $tpz

        Write-GodotSay "Unpacking the $($Targets -join ', ') templates..."
        New-Item -ItemType Directory -Force -Path $templateDir | Out-Null
        # ZipFile rather than Expand-Archive, for two reasons. Expand-Archive
        # cannot extract SELECTED members, and it validates the FILE EXTENSION
        # rather than the contents -- a .tpz is an ordinary zip, but handing it
        # that name fails with ".tpz is not a supported archive file format".
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $patterns = @($Targets | ForEach-Object { Get-GodotTemplatePattern -Target $_ })
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tpz)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.Name -eq "") { continue }
                foreach ($p in $patterns) {
                    if ($entry.FullName -like $p) {
                        [System.IO.Compression.ZipFileExtensions]::ExtractToFile(
                            $entry, (Join-Path $templateDir $entry.Name), $true)
                        break
                    }
                }
            }
        } finally {
            $zip.Dispose()
        }
        # Godot checks this file to decide the directory holds templates for
        # that version at all.
        Set-Content -Path (Join-Path $templateDir "version.txt") -Value $Engine.TemplateVersion
    } catch {
        Write-GodotErr "BUILD ABORTED: could not install export templates. $_"
        # .\editor.ps1 specifically: it redirects %APPDATA% into build\deps, so
        # the editor's own template manager installs where this build looks.
        # A Godot started any other way would install them somewhere we ignore.
        Write-Host "Or install them from .\editor.ps1 (Editor > Manage Export Templates)." -ForegroundColor Yellow
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Verify rather than assume.
    foreach ($file in $needed) {
        if (-not (Test-Path -LiteralPath (Join-Path $templateDir $file))) {
            Write-GodotErr "BUILD ABORTED: template $file missing from $templateDir after install."
            exit 1
        }
    }
    Write-Host "Export templates installed successfully." -ForegroundColor Green
    return $templateDir
}
