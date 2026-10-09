# build.ps1 - Test, export and package Inkwood, for Windows and/or Linux, from a
# Windows host.
#
#   .\build.ps1                    # full gate, then export BOTH targets
#   .\build.ps1 -Target windows    # one target only (or: linux)
#   .\build.ps1 -Force             # package even if a test failed (never for a release)
#   .\build.ps1 -SkipTests         # export only -- the build is UNVERIFIED
#
# Cross-building the Linux release here is NOT a hack: Godot's exporter takes
# the prebuilt `linux_release.x86_64` template and appends the project .pck to
# it, which is an ordinary file operation, and the GodotSteam addon ships
# binaries for every target. So a Linux build produced here is the same
# construction a Linux host would produce -- build.sh does the mirror image.
#
# The engine is not assumed to be installed and is not hardcoded here: the
# version comes from godot.manifest and godot_env.ps1 fetches exactly that build
# into build\deps\ on first use. See that file.
param (
    [switch]$Force,
    [switch]$SkipTests,
    [ValidateSet("windows", "linux", "both")][string]$Target = "both"
)

$GameName = "Inkwood"
$targets = if ($Target -eq "both") { @("windows", "linux") } else { @($Target) }

. "$PSScriptRoot\godot_env.ps1"
. "$PSScriptRoot\tar_pack.ps1"
Normalize-ProcessPath

# The exported game, if still running, holds its own binary open.
Write-Host "Stopping any running instances of the game..." -ForegroundColor Yellow
Stop-Process -Name $GameName -ErrorAction SilentlyContinue

$buildDir = "$PSScriptRoot\build"
$buildVersion = Get-Date -Format "yyyy-MM-dd.HHmmss"

# Per-target facts. The preset names are what export_presets.cfg defines --
# renaming one there breaks this. The Linux archive is a .tar.gz because zip
# does not preserve the executable bit; see tar_pack.ps1 for why it is not
# simply tar.exe either.
$Platforms = @{
    windows = @{
        Preset = "Windows Desktop"; Dir = "$buildDir\windows"; File = "$GameName.exe"
        Archive = "$buildDir\${GameName}_Windows_v$buildVersion.zip"; ArchiveGlob = "${GameName}_Windows_v*.zip"
    }
    linux = @{
        Preset = "Linux"; Dir = "$buildDir\linux"; File = "$GameName.x86_64"
        Archive = "$buildDir\${GameName}_Linux_v$buildVersion.tar.gz"; ArchiveGlob = "${GameName}_Linux_v*.tar.gz"
    }
}

Write-Host "Build Version: $buildVersion" -ForegroundColor Cyan
Write-Host "Targets: $($targets -join ', ')" -ForegroundColor Cyan

# Resolved (and installed, first time) BEFORE the parallel test runners below:
# every test_runner.ps1 in that batch asks for the engine too, and a dozen
# processes racing to download the same 120 MB is a self-inflicted flake.
$engine = Resolve-GodotEngine
$godotPath = $engine.Path
Write-Host "Engine: Godot $($engine.Tag)  ($godotPath)" -ForegroundColor DarkCyan

# Reimport up front, once, before the parallel test runners below -- each of
# those self-checks too (test_runner.ps1), but by then this pass will have left
# nothing stale, so they are a cheap no-op scan rather than N processes racing
# to reimport into .godot/imported/.
. "$PSScriptRoot\import_check.ps1"
Import-IfStale -ProjectRoot $PSScriptRoot -GodotPath $godotPath

# --- Syntax validation: deliberately NOT a step -------------------------------
# `--headless --check-only` reports FALSE parse errors on autoload identifiers
# (DebugSettings, NetworkManager, SteamManager -- which this codebase uses
# everywhere), so a syntax gate built on it fails on correct code. A gate that
# cries wolf is worse than no gate. Scripts are validated by the tests that load
# them; test_smoke is the one that fails first and cheapest when a script does
# not compile.

# --- Test gate ----------------------------------------------------------------
$testsPassed = $true

if ($SkipTests) {
    Write-Host "SKIPPING the test gate (-SkipTests). This build is UNVERIFIED." -ForegroundColor Yellow
} else {
    Write-Host "Running automated test suite (parallel)..." -ForegroundColor Cyan
    $allTestFiles = Get-ChildItem -Path "$PSScriptRoot\scripts\tests\*.gd"

    # PERF TESTS RUN ALONE, AFTER EVERYTHING ELSE.
    #
    # Anything that measures wall time per physics step measures, inside a
    # parallel batch, however much CPU it happened to get -- i.e. the SCHEDULER
    # rather than the game. That fails gates on hundredths of a millisecond
    # while the code is fine, which trains everyone to ignore the one real
    # regression the budget exists to catch. Add the name of any timing test
    # here and it will be run serially with the box otherwise idle.
    $perfTestNames = @()
    $testFiles = $allTestFiles | Where-Object { $perfTestNames -notcontains $_.BaseName }
    $perfTestFiles = $allTestFiles | Where-Object { $perfTestNames -contains $_.BaseName }

    # Cap concurrency. Uncapped, a full gate launches one PowerShell host AND
    # one headless Godot per test file simultaneously; past ~100 tests that is
    # heavy CPU oversubscription and tens of GB of RAM in a single burst.
    # Correctness is unaffected either way (every test runs under --fixed-fps
    # 60, so frame counts are identical regardless of contention) -- what
    # contention changes is wall clock. Leave headroom for the OS and the editor
    # rather than saturating every core.
    $maxParallel = [Math]::Max(2, [Math]::Min(12, [Environment]::ProcessorCount - 8))
    Write-Host "Test concurrency capped at $maxParallel (of $([Environment]::ProcessorCount) logical CPUs)" -ForegroundColor DarkCyan

    $logDir = "$PSScriptRoot\test_logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    function Start-TestRunner {
        param([string]$Name)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "powershell.exe"
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\test_runner.ps1`" -TestName $Name"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        # Start-Process -PassThru does not reliably expose ExitCode once output
        # is redirected -- use raw .NET Process objects, which do.
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        return [PSCustomObject]@{
            Name = $Name
            Process = $proc
            StdOutTask = $proc.StandardOutput.ReadToEndAsync()
            StdErrTask = $proc.StandardError.ReadToEndAsync()
        }
    }

    $runners = @()
    foreach ($file in $testFiles) {
        # Hold here until a slot frees. Polling rather than WaitHandle juggling:
        # these are multi-second processes, so a 200ms tick costs nothing and
        # keeps the loop readable.
        while (@($runners | Where-Object { -not $_.Process.HasExited }).Count -ge $maxParallel) {
            Start-Sleep -Milliseconds 200
        }
        Write-Host "Launching $($file.BaseName)..."
        # += rather than collecting the loop's output, because the throttle
        # above has to inspect $runners WHILE the loop is still running.
        $runners += Start-TestRunner -Name $file.BaseName
    }

    foreach ($r in $runners) {
        $r.Process.WaitForExit()
        Set-Content -Path "$logDir\$($r.Name).runner.log" -Value $r.StdOutTask.Result
        Set-Content -Path "$logDir\$($r.Name).runner.err.log" -Value $r.StdErrTask.Result
        if ($r.Process.ExitCode -eq 0) {
            Write-Host ("  PASS  " + $r.Name) -ForegroundColor Green
        } else {
            Write-Host ("  FAIL  " + $r.Name) -ForegroundColor Red
            Write-Host $r.StdOutTask.Result
            if ($r.StdErrTask.Result.Trim().Length -gt 0) { Write-Host $r.StdErrTask.Result }
            $testsPassed = $false
        }
    }

    # Perf tests, serialised, with the box otherwise idle. Everything above has
    # exited by now (the wait loop is a barrier), so these measure the game
    # rather than the scheduler.
    if ($perfTestFiles.Count -gt 0) {
        Write-Host "`nRunning perf tests serially (contention would make these meaningless)..." -ForegroundColor Cyan
        foreach ($file in $perfTestFiles) {
            $r = Start-TestRunner -Name $file.BaseName
            $r.Process.WaitForExit()
            Set-Content -Path "$logDir\$($r.Name).runner.log" -Value $r.StdOutTask.Result
            Set-Content -Path "$logDir\$($r.Name).runner.err.log" -Value $r.StdErrTask.Result
            Write-Host "`n========== $($r.Name) (serial) ==========" -ForegroundColor Cyan
            Write-Host $r.StdOutTask.Result
            if ($r.Process.ExitCode -ne 0) { $testsPassed = $false }
        }
    }

    if (-not $testsPassed) {
        if ($Force) {
            Write-Host "WARNING: one or more tests failed, but -Force was specified. Proceeding..." -ForegroundColor Yellow
        } else {
            Write-Host "BUILD ABORTED: one or more tests failed." -ForegroundColor Red
            exit 1
        }
    } else {
        Write-Host "All tests passed successfully." -ForegroundColor Green
    }
}

# --- Export templates ---------------------------------------------------------
# Only the targets being built: the upstream archive carries every platform
# (~1.2 GB) and godot_env.ps1 unpacks just what is asked for.
Install-GodotTemplates -Engine $engine -Targets $targets | Out-Null

# --- Export -------------------------------------------------------------------
# NOT a recursive delete of $buildDir -- build\ also holds deps\, i.e. the
# engine this script is running from. Only the output directories are cleaned,
# and only the ones this run is about to write.
Write-Host "Preparing build directory: $buildDir" -ForegroundColor Cyan
foreach ($t in $targets) {
    $dir = $Platforms[$t].Dir
    if (Test-Path $dir) { Remove-Item -Path $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

# Written to the project root BEFORE the export so it is packed into the .pck
# and travels with the binary; scripts/ui/build_version.gd reads it.
Set-Content -Path "$PSScriptRoot\version.txt" -Value $buildVersion

foreach ($t in $targets) {
    $p = $Platforms[$t]
    $exportPath = "$($p.Dir)\$($p.File)"
    Write-Host "Exporting '$($p.Preset)' to $exportPath..." -ForegroundColor Cyan
    $godotArgs = "--path `"$PSScriptRoot`" --headless --export-release `"$($p.Preset)`" `"$exportPath`""
    $process = Start-Process -FilePath $godotPath -ArgumentList $godotArgs -Wait -PassThru -NoNewWindow

    # Steam needs its appid file next to the binary, or a build launched outside
    # the Steam client reports "app not running" and never initialises.
    if (Test-Path "$PSScriptRoot\steam_appid.txt") {
        Copy-Item "$PSScriptRoot\steam_appid.txt" -Destination $p.Dir
    }

    # Godot exits 0 even when an export "completed with warnings", so the exit
    # code alone is not proof -- the artifact check is what decides.
    if ($process.ExitCode -ne 0 -or -not (Test-Path $exportPath)) {
        Write-Host "BUILD FAILED: export of '$($p.Preset)' produced no artifact (exit $($process.ExitCode))." -ForegroundColor Red
        exit 1
    }
    Write-Host "Export of '$($p.Preset)' successful." -ForegroundColor Green
}

# --- Package ------------------------------------------------------------------
#
# COMPRESS-ARCHIVE SILENTLY SKIPS A FILE IT CANNOT OPEN. Observed 2026-08-08: the
# zip came out 1.5 MB instead of 33 MB because the 97 MB .exe -- written seconds
# earlier and still being scanned by the on-access antivirus -- was locked at the
# moment it was read. No error, no warning, exit code 0, and the script cheerfully
# printed "Build Complete!" over an archive containing the .pck and the DLLs and
# NO GAME. It is intermittent, which is worse: the same command run a minute later
# produced a correct archive.
#
# So EVERY archive is VERIFIED against the directory it came from rather than
# trusted -- the zip through ZipFile, the tar.gz through tar_pack.ps1's reader.
# A size heuristic would not do -- the whole failure mode is that the thing
# looks like a plausible archive.
Add-Type -AssemblyName System.IO.Compression.FileSystem

# What the archive must hold: every file in the output directory except export
# leftovers, with its length. Shared by both archive kinds.
function Get-ExpectedFiles {
    param([string]$SourceDir)
    $expected = @{}
    foreach ($file in (Get-ChildItem -Path $SourceDir -File -Recurse)) {
        # A LEFTOVER IS NEVER WANTED, EVEN THOUGH IT IS ON DISK. This is the line
        # that makes the UNWANTED check below able to fire at all.
        #
        # Both defences against duplicate binaries used to bottom out in the same
        # place: the removal step below. It uses -ErrorAction SilentlyContinue, so
        # a leftover that is still locked when the sweep reaches it survives -- and
        # then it is a real file in this directory, so it counts as EXPECTED, so
        # the archive that carries it is "correct". Observed 2026-08-29: a 77.1 MB
        # zip where every build that day was 39.5, with two copies of a 104 MB
        # executable in it, and the build printed success.
        #
        # Deciding it here rather than trusting the delete means the verifier is
        # independent of whether the delete worked, which is the whole point of
        # having a verifier.
        if ($file.Name -like '*~RF*.TMP') { continue }
        $rel = $file.FullName.Substring($SourceDir.Length).TrimStart('\', '/').Replace('\', '/')
        $expected[$rel] = $file.Length
    }
    return $expected
}

# $Packed: relative name -> byte length, as read back from the archive.
function Get-PackedFaults {
    param([hashtable]$Expected, [hashtable]$Packed)
    $faults = @()
    foreach ($rel in $Expected.Keys) {
        # Length as well as presence: a truncated entry is the same class of
        # silent damage as an absent one.
        if (-not $Packed.ContainsKey($rel)) {
            $faults += "MISSING  $rel"
        } elseif ($Packed[$rel] -ne $Expected[$rel]) {
            $faults += "TRUNCATED  $rel (packed $($Packed[$rel]) of $($Expected[$rel]) bytes)"
        }
    }
    # AND THE OTHER DIRECTION, which this check did not have and needed.
    #
    # It only ever asked "is every wanted file in the archive". An archive can
    # also be wrong by containing something nobody asked for -- and because the
    # leftovers above were real files on disk, they counted as WANTED and the
    # check waved them through. A one-directional verifier cannot see a
    # duplicate, and a duplicate of a 104 MB executable is not a subtle defect.
    foreach ($rel in $Packed.Keys) {
        if (-not $Expected.ContainsKey($rel)) {
            $faults += "UNWANTED  $rel ($($Packed[$rel]) bytes)"
        }
    }
    return $faults
}

function Get-ZipFaults {
    param([string]$SourceDir, [string]$ZipPath)
    $packed = @{}
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $packed[$entry.FullName.Replace('\', '/')] = $entry.Length
        }
    } finally {
        $zip.Dispose()
    }
    return Get-PackedFaults -Expected (Get-ExpectedFiles $SourceDir) -Packed $packed
}

function Get-TarFaults {
    param([string]$SourceDir, [string]$TarGzPath, [string]$Binary)
    $entries = Read-TarEntries -TarGzPath $TarGzPath
    $packed = @{}
    foreach ($name in $entries.Keys) { $packed[$name] = $entries[$name].Size }
    $faults = @(Get-PackedFaults -Expected (Get-ExpectedFiles $SourceDir) -Packed $packed)
    # The one thing a Linux archive can get wrong that a zip cannot even express:
    # a game that extracts without its execute bit does not launch.
    if ($entries.ContainsKey($Binary)) {
        $mode = [Convert]::ToInt32($entries[$Binary].Mode, 8)
        if (($mode -band 0x49) -ne 0x49) {
            $faults += "NOT EXECUTABLE  $Binary (mode $($entries[$Binary].Mode))"
        }
    }
    return $faults
}

$packAttempts = 3
foreach ($t in $targets) {
    $p = $Platforms[$t]
    Write-Host "Packaging $t build into $($p.Archive)..." -ForegroundColor Cyan
    Set-Content -Path "$($p.Dir)\version.txt" -Value $buildVersion

    # Drop the previous archive FOR THIS PLATFORM. Scoped to its pattern on
    # purpose: build\ is not wiped wholesale, and a bare ${GameName}_* sweep
    # would take out the other platform's archive built from the same tree.
    Get-ChildItem -Path $buildDir -Filter $p.ArchiveGlob -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    # EXPORT LEFTOVERS, REMOVED BEFORE ANYTHING IS PACKED.
    #
    # Windows creates `<name>~RF<hex>.TMP` when it replaces a file that something
    # else has open -- an antivirus scanner mid-read is enough -- and Godot's
    # exporter leaves them behind. They are full-size copies of the OLD binary
    # sitting beside the new one, so the archive came out with two 104 MB
    # executables in it: 75.9 MB where every previous build was 38.3.
    #
    # The build reported success, the verification below passed, and the artifact was
    # twice the size and carried stale binaries. Caught by looking at the number.
    $stale = Get-ChildItem -Path $p.Dir -Filter '*~RF*.TMP' -File -ErrorAction SilentlyContinue
    if ($stale) {
        foreach ($f in $stale) {
            Write-Host "  Removing export leftover: $($f.Name) ($([math]::Round($f.Length/1MB,1)) MB)" -ForegroundColor Yellow
        }
        $stale | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $missing = @()
    for ($attempt = 1; $attempt -le $packAttempts; $attempt++) {
        if (Test-Path $p.Archive) { Remove-Item $p.Archive -Force }
        # AN EXPLICIT LIST, NOT A WILDCARD. `$dir\*` packs whatever is in the
        # directory, which includes any export leftover the sweep above could not
        # delete -- and a locked 104 MB leftover then doubles the artifact. Naming
        # the files means a leftover we failed to remove is merely not packed,
        # instead of being packed and then caught by the verifier as a failure.
        $toPack = Get-ChildItem -Path $p.Dir -File -Recurse |
            Where-Object { $_.Name -notlike '*~RF*.TMP' } |
            ForEach-Object { $_.FullName }
        if ($t -eq "windows") {
            Compress-Archive -Path $toPack -DestinationPath $p.Archive -Force
            $missing = @(Get-ZipFaults -SourceDir $p.Dir -ZipPath $p.Archive)
        } else {
            Write-TarGz -SourceDir $p.Dir -Files $toPack -OutPath $p.Archive -Executable @($p.File)
            $missing = @(Get-TarFaults -SourceDir $p.Dir -TarGzPath $p.Archive -Binary $p.File)
        }
        if ($missing.Count -eq 0) { break }

        Write-Host "Archive does not match the build (attempt $attempt of $packAttempts):" -ForegroundColor Yellow
        foreach ($m in $missing) { Write-Host "    $m" -ForegroundColor Yellow }
        if ($attempt -lt $packAttempts) {
            # Whatever held the file open is transient by nature. Give it a moment
            # rather than failing a build over an antivirus scan.
            Write-Host "  Retrying in 5s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host "BUILD FAILED: could not package a complete $t archive after $packAttempts attempts." -ForegroundColor Red
        Write-Host "Something is holding these files open -- an antivirus scan, or a running copy of the game." -ForegroundColor Red
        exit 1
    }
}

Write-Host "Build Complete!" -ForegroundColor Green
foreach ($t in $targets) {
    $p = $Platforms[$t]
    $binSize = [math]::Round((Get-Item "$($p.Dir)\$($p.File)").Length / 1MB, 1)
    $archiveSize = [math]::Round((Get-Item $p.Archive).Length / 1MB, 1)
    Write-Host "  $t`: $($p.Dir)\$($p.File) ($binSize MB)"
    Write-Host "  $t`: $($p.Archive) ($archiveSize MB)"
}

if (-not $testsPassed -or $SkipTests) {
    Write-Host "`nWARNING: this build did NOT pass a clean test gate!" -ForegroundColor Yellow
}
