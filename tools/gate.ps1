# tools/gate.ps1 - Run the test gate (or some of it) and print ONE summary.
#
#   .\tools\gate.ps1                          # every test in scripts\tests, test_smoke first
#   .\tools\gate.ps1 -Tests test_fire,test_wind
#   .\tools\gate.ps1 -Only 'fire|wind'        # regex on test names
#   .\tools\gate.ps1 -Root ..\inkwood_wt      # a throwaway checkout (operating.md, "Validating one track alone")
#
# Prints "PASSED n/m" and, for each failure, the log paths and its first error lines; exit code
# 0 only if every selected test passed. Blocks until done -- do NOT background it and poll: a
# full gate fits inside one 10-minute tool call. Use a 600000 ms timeout on the call.
#
# A test passes with BOTH exit code 0 AND its ">>> [TEST PASSED] <name> <<<" marker, exactly as
# test_runner.ps1 decides; logs land in <Root>\test_logs\<name>.log / .err.log as they do there.
# Differences from a loop of test_runner.ps1: the engine is resolved and the import checked ONCE,
# then Godot is launched directly (no PowerShell host per test); INKWOOD_STEAM=off unless
# -WithSteam (CLAUDE.md's open question proposes this for the runners); test_smoke runs alone
# first and a failure there stops the run (a parse error fails every test that loads the script);
# one gate at a time on this machine (networked tests own fixed ports), so a second gate waits.
#
# Not build.ps1: no export, nothing stopped, safe while Alex is playtesting.
param (
    [string[]]$Tests = @(),
    [string]$Only = "",
    [string]$Root = "",
    [int]$Parallel = 0,
    [int]$TimeoutSec = 600,
    [switch]$WithSteam
)

if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path $Root -ErrorAction Stop).Path
. "$PSScriptRoot\lib.ps1"
. "$Root\godot_env.ps1"
Normalize-ProcessPath

# --- selection ----------------------------------------------------------------
$all = @(Get-ChildItem -Path "$Root\scripts\tests\*.gd" | ForEach-Object { $_.BaseName } | Sort-Object)
$names = $all
$Tests = @($Tests | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Tests.Count) {
    $missing = @($Tests | Where-Object { $all -notcontains $_ })
    if ($missing.Count) { Write-Output "gate: no such test: $($missing -join ', ')"; exit 1 }
    $names = $Tests
}
if ($Only -ne "") { $names = @($names | Where-Object { $_ -match $Only }) }
if (-not $names.Count) { Write-Output "gate: nothing selected"; exit 1 }
if ($Parallel -le 0) { $Parallel = [Math]::Max(2, [Math]::Min(12, [Environment]::ProcessorCount - 8)) }

# --- one gate at a time -------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, "Local\inkwood_gate")
$held = $false
try { $held = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $held = $true }
if (-not $held) {
    Write-Output "gate: another gate is running on this machine; waiting (up to 15 min)..."
    try { $held = $mutex.WaitOne(900000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
    if (-not $held) { Write-Output "gate: gave up waiting for the other gate"; exit 1 }
}

try {
    $engine = Resolve-GodotEngine
    . "$Root\import_check.ps1"
    Import-IfStale -ProjectRoot $Root -GodotPath $engine.Path | Out-Null

    $logDir = "$Root\test_logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $envs = @{}
    if (-not $WithSteam) { $envs["INKWOOD_STEAM"] = "off" }
    $results = [ordered]@{}
    $clock = [System.Diagnostics.Stopwatch]::StartNew()

    function Start-Test([string]$n) {
        foreach ($f in @("$logDir\$n.log", "$logDir\$n.err.log")) { if (Test-Path $f) { Remove-Item $f -Force } }
        $r = Start-Captured -File $engine.Path -Arguments "--path `"$Root`" --headless --fixed-fps 60 --run-test `"$n`"" -Env $envs
        $r | Add-Member -NotePropertyName Name -NotePropertyValue $n
        return $r
    }
    function Finish-Test($r, [bool]$timedOut) {
        if ($timedOut) { Stop-ProcessTree $r.Proc.Id }
        $r.Proc.WaitForExit()
        $out = $r.Out.Result; $err = $r.Err.Result
        Set-Content -Path "$logDir\$($r.Name).log" -Value $out
        if ($err -ne "") { Set-Content -Path "$logDir\$($r.Name).err.log" -Value $err }
        $marked = $out -match [regex]::Escape(">>> [TEST PASSED] $($r.Name) <<<")
        $code = if ($timedOut) { "timeout ${TimeoutSec}s" } else { "$($r.Proc.ExitCode)" }
        $results[$r.Name] = [PSCustomObject]@{
            Ok = ((-not $timedOut) -and $r.Proc.ExitCode -eq 0 -and $marked)
            Code = $code; Marked = $marked
            Secs = [Math]::Round(((Get-Date) - $r.Start).TotalSeconds, 1)
            Errors = @(Get-GodotErrorLines -Text ($err + "`n" + $out))
        }
    }

    # test_smoke alone, first: cheapest proof that the scripts compile.
    $queue = New-Object System.Collections.Queue
    $rest = @($names | Where-Object { $_ -ne "test_smoke" })
    if ($names -contains "test_smoke") {
        $r = Start-Test "test_smoke"
        $done = $r.Proc.WaitForExit($TimeoutSec * 1000)
        Finish-Test $r (-not $done)
        if (-not $results["test_smoke"].Ok) { foreach ($n in $rest) { $results[$n] = $null } }
        else { foreach ($n in $rest) { $queue.Enqueue($n) } }
    } else { foreach ($n in $rest) { $queue.Enqueue($n) } }

    $running = @()
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Parallel) { $running += Start-Test $queue.Dequeue() }
        Start-Sleep -Milliseconds 250
        $still = @()
        foreach ($r in $running) {
            if ($r.Proc.HasExited) { Finish-Test $r $false }
            elseif (((Get-Date) - $r.Start).TotalSeconds -gt $TimeoutSec) { Finish-Test $r $true }
            else { $still += $r }
        }
        $running = $still
    }

    # --- the summary ----------------------------------------------------------
    $ran = @($results.Keys | Where-Object { $results[$_] -ne $null })
    $skipped = @($results.Keys | Where-Object { $results[$_] -eq $null })
    $failed = @($ran | Where-Object { -not $results[$_].Ok })
    $secs = [Math]::Round($clock.Elapsed.TotalSeconds)
    $rootNote = if ($Root -ne (Split-Path -Parent $PSScriptRoot)) { " in $Root" } else { "" }
    Write-Output ("gate: {0} test(s){1}, {2} parallel, {3}s" -f $names.Count, $rootNote, $Parallel, $secs)
    Write-Output ("PASSED {0}/{1}" -f ($ran.Count - $failed.Count), $names.Count)
    foreach ($n in $failed) {
        $x = $results[$n]
        Write-Output ("FAIL {0}  (exit {1}, marker {2}, {3}s)  test_logs\{0}.err.log" -f $n, $x.Code, $(if ($x.Marked) { "yes" } else { "no" }), $x.Secs)
        if ($x.Errors.Count) { $x.Errors | ForEach-Object { Write-Output "    $_" } }
        else { Write-Output "    (no error lines; read test_logs\$n.log)" }
    }
    if ($skipped.Count) { Write-Output "NOT RUN: $($skipped.Count) test(s) -- test_smoke failed, so every script that loads the broken one would too" }
    if ($failed.Count -or $skipped.Count) { exit 1 }
    exit 0
} finally {
    if ($held) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
