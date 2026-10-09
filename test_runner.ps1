# test_runner.ps1 - Run one headless Godot test by name.
#
#   .\test_runner.ps1 -TestName test_smoke
#
# Logs land in test_logs/<TestName>.log and .err.log. READ THOSE, not this
# script's piped stdout -- the real Godot output (including the Parse Error that
# explains an otherwise-baffling failure) only ever appears in the .err.log.
param (
    [string]$TestName = ""
)

. "$PSScriptRoot\godot_env.ps1"
Normalize-ProcessPath

# Usage check FIRST: listing the tests must not install a 60 MB engine.
if ($TestName -eq "") {
    Write-Host "Usage: .\test_runner.ps1 -TestName <name>   (a file in scripts\tests\<name>.gd)" -ForegroundColor Yellow
    Write-Host "Available tests:" -ForegroundColor Cyan
    Get-ChildItem -Path "$PSScriptRoot\scripts\tests\*.gd" | ForEach-Object { Write-Host "  $($_.BaseName)" }
    exit 1
}

# The engine version is pinned in godot.manifest and installed under build\deps
# on first use -- see godot_env.ps1. build.ps1 resolves it once up front, so the
# parallel gate finds it already there rather than N runners racing to fetch it.
$godotPath = (Resolve-GodotEngine).Path

. "$PSScriptRoot\import_check.ps1"
Import-IfStale -ProjectRoot $PSScriptRoot -GodotPath $godotPath

Write-Host "Running test: $TestName" -ForegroundColor Cyan

$logDir = "$PSScriptRoot\test_logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = "$logDir\$TestName.log"
$errFile = "$logDir\$TestName.err.log"
if (Test-Path $logFile) { Remove-Item $logFile }
if (Test-Path $errFile) { Remove-Item $errFile }

# --fixed-fps 60 DECOUPLES the loop from real time. Headless Godot otherwise
# SLEEPS to hold 60Hz, so a frame-counted test runs in real time (a 20-second
# scenario takes 20 seconds of wall clock) despite doing milliseconds of work --
# and real-time sleep does NOT parallelize, so under N-way contention the loop
# cannot hold 60Hz and wall clock slips toward the timeout below. --fixed-fps
# runs the same fixed 1/60 delta with identical frame counts (so it is
# deterministic, not merely fast) with no sleeping. Always pass it, including on
# a direct run outside this script.
#
# Raw .NET Process rather than Start-Process, so the timeout can be enforced via
# WaitForExit(ms) AND the exit code read reliably alongside redirected output --
# Start-Process -PassThru does not expose ExitCode dependably once
# -RedirectStandardOutput is also set.
$TEST_TIMEOUT_SEC = 600

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $godotPath
$psi.Arguments = "--path `"$PSScriptRoot`" --headless --fixed-fps 60 --run-test `"$TestName`""
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
[void]$proc.Start()
$stdOutTask = $proc.StandardOutput.ReadToEndAsync()
$stdErrTask = $proc.StandardError.ReadToEndAsync()

$exitedInTime = $proc.WaitForExit($TEST_TIMEOUT_SEC * 1000)
$stopwatch.Stop()
$latency = $stopwatch.Elapsed.TotalSeconds.ToString("F2")
if (-not $exitedInTime) {
    # Hung: kill it so the async stdout/stderr pipes close and their
    # ReadToEndAsync tasks complete -- only then is it safe to read .Result
    # (reading it on a still-running process would itself block forever).
    try { $proc.Kill() } catch {}
    $proc.WaitForExit()
}

$logContent = $stdOutTask.Result
$errContent = $stdErrTask.Result
Set-Content -Path $logFile -Value $logContent
if ($errContent -ne "") { Set-Content -Path $errFile -Value $errContent }

if (-not $exitedInTime) {
    Write-Host "`n  >>> [TEST FAILED] $TestName (TIMEOUT -- killed after ${TEST_TIMEOUT_SEC}s) <<<" -ForegroundColor Red
    Write-Host "Test did not exit within the time budget -- treated as a hang. Partial log:"
    Write-Host $logContent
    if ($errContent -ne "") {
        Write-Host "Error Output:"
        Write-Host $errContent
    }
    exit 1
}

# BOTH conditions. A test that crashes after printing its pass marker still
# exits non-zero, and a test that exits 0 without ever running an assertion
# never printed one.
if ($proc.ExitCode -eq 0 -and $logContent -match "\[TEST PASSED\]") {
    Write-Host "`n  >>> [TEST PASSED] $TestName (${latency}s) <<<" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n  >>> [TEST FAILED] $TestName (${latency}s) <<<" -ForegroundColor Red
    Write-Host "Exit Code: $($proc.ExitCode)"
    Write-Host "Log Output:"
    Write-Host $logContent
    if ($errContent -ne "") {
        Write-Host "Error Output:"
        Write-Host $errContent
    }
    exit 1
}
