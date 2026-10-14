# tools/shot.ps1 - Run a windowed shot / board script and report what it wrote, in one call.
#
#   .\tools\shot.ps1 -Script scripts\ui\ship_shot.gd -Out tmp\ships
#   .\tools\shot.ps1 -Script res://scripts/ui/boards/water_board_shot.gd -Out tmp\water -Sheet
#   .\tools\shot.ps1 -Script scripts\app\strike_shot.gd -Args seed=7,turn=3 -Timeout 300
#
# Runs the pinned engine WINDOWED (--headless draws nothing) with INKWOOD_STEAM=off, passing
# "-- out=<Out> <Args...>" (the shot scripts' key=value convention). Prints the exit code (or
# TIMEOUT), the run's error lines only, and every PNG written during the run with its size.
# The full output is in tmp\shot_logs\<script>.log / .err.log.
#
# -Sheet  also composes those PNGs into <Out>\_sheet.png at NATIVE size (labelled grid,
#         -Columns wide): one image to look at instead of one Read per frame, and a sheet Alex can
#         judge at full resolution (operating.md: never a thumbnail).
#
# On timeout the run is stopped by PID with its child (the _console.exe wrapper's engine), never
# by image name. Windows-only dev helper (see tools\lib.ps1).
param (
    [Parameter(Mandatory = $true)][string]$Script,
    [string]$Out = "",
    [string[]]$Args = @(),
    [string]$Resolution = "1280x720",
    [int]$Timeout = 240,
    [switch]$Sheet,
    [int]$Columns = 2
)

$Root = Split-Path -Parent $PSScriptRoot
. "$PSScriptRoot\lib.ps1"
. "$Root\godot_env.ps1"
Normalize-ProcessPath

# res://scripts/x.gd or scripts\x.gd -> both forms
$rel = ($Script -replace '^res://', '') -replace '/', '\'
if (-not (Test-Path (Join-Path $Root $rel))) { Write-Output "shot: no such script: $rel"; exit 1 }
$res = "res://" + ($rel -replace '\\', '/')
$base = [System.IO.Path]::GetFileNameWithoutExtension($rel)

$userArgs = @()
if ($Out -ne "") {
    $outAbs = [System.IO.Path]::GetFullPath((Join-Path $Root $Out))
    New-Item -ItemType Directory -Force -Path $outAbs | Out-Null
    $userArgs += "out=" + ($Out -replace '\\', '/')
}
$userArgs += @($Args | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$logDir = Join-Path $Root "tmp\shot_logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$engine = Resolve-GodotEngine
$argLine = "--path `"$Root`" --windowed --resolution $Resolution --script $res"
if ($userArgs.Count) { $argLine += " -- " + (($userArgs | ForEach-Object { "`"$_`"" }) -join ' ') }

$started = (Get-Date).AddSeconds(-1)
$r = Start-Captured -File $engine.ConsolePath -Arguments $argLine -Env @{ INKWOOD_STEAM = "off" }
$done = $r.Proc.WaitForExit($Timeout * 1000)
if (-not $done) { Stop-ProcessTree $r.Proc.Id }
$r.Proc.WaitForExit()
$secs = [Math]::Round(((Get-Date) - $r.Start).TotalSeconds, 1)
$o = $r.Out.Result; $e = $r.Err.Result
Set-Content -Path "$logDir\$base.log" -Value $o
Set-Content -Path "$logDir\$base.err.log" -Value $e

# PNGs written during this run: in -Out if given, else anywhere under tmp\ and variants\.
$scan = if ($Out -ne "") { @($outAbs) } else { @((Join-Path $Root "tmp"), (Join-Path $Root "variants")) }
$pngs = @($scan | ForEach-Object { Get-ChildItem -Path $_ -Recurse -Filter *.png -ErrorAction SilentlyContinue } |
    Where-Object { $_.LastWriteTime -ge $started -and $_.Name -ne "_sheet.png" } | Sort-Object FullName)

$status = if (-not $done) { "TIMEOUT after ${Timeout}s (stopped by PID)" } else { "exit $($r.Proc.ExitCode)" }
Write-Output "shot: $base  $status  ${secs}s  logs: tmp\shot_logs\$base.log"
$errs = @(Get-GodotErrorLines -Text ($e + "`n" + $o) -Max 12)
if ($errs.Count) { Write-Output "errors:"; $errs | ForEach-Object { Write-Output "    $_" } }

Add-Type -AssemblyName System.Drawing
$sizes = @{}
Write-Output "wrote $($pngs.Count) PNG(s):"
$i = 0
foreach ($p in $pngs) {
    try { $img = [System.Drawing.Image]::FromFile($p.FullName); $sizes[$p.FullName] = @($img.Width, $img.Height); $img.Dispose() } catch { $sizes[$p.FullName] = @(0, 0) }
    if ($i -lt 40) { Write-Output ("    {0}  {1}x{2}" -f $p.FullName.Substring($Root.Length + 1), $sizes[$p.FullName][0], $sizes[$p.FullName][1]) }
    $i++
}
if ($pngs.Count -gt 40) { Write-Output "    ... and $($pngs.Count - 40) more" }

if ($Sheet -and $pngs.Count) {
    $label = 24
    $cellW = ($sizes.Values | ForEach-Object { $_[0] } | Measure-Object -Maximum).Maximum
    $cellH = ($sizes.Values | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum + $label
    $cols = [Math]::Min($Columns, $pngs.Count)
    $rows = [Math]::Ceiling($pngs.Count / $cols)
    $bmp = New-Object System.Drawing.Bitmap ([int]($cellW * $cols)), ([int]($cellH * $rows))
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::FromArgb(64, 64, 64))
    $font = New-Object System.Drawing.Font("Segoe UI", 11)
    $k = 0
    foreach ($p in $pngs) {
        $x = ($k % $cols) * $cellW; $y = [Math]::Floor($k / $cols) * $cellH
        $g.DrawString($p.Name, $font, [System.Drawing.Brushes]::White, [float]($x + 6), [float]($y + 3))
        $img = [System.Drawing.Image]::FromFile($p.FullName)
        $g.DrawImageUnscaled($img, [int]$x, [int]($y + $label))
        $img.Dispose(); $k++
    }
    $sheetDir = if ($Out -ne "") { $outAbs } else { Join-Path $Root "tmp\$base" }
    New-Item -ItemType Directory -Force -Path $sheetDir | Out-Null
    $sheetPath = Join-Path $sheetDir "_sheet.png"
    $bmp.Save($sheetPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose(); $font.Dispose()
    Write-Output ("sheet: {0}  {1}x{2}" -f $sheetPath.Substring($Root.Length + 1), ($cellW * $cols), ($cellH * $rows))
}

if (-not $done -or $r.Proc.ExitCode -ne 0 -or -not $pngs.Count) { exit 1 }
exit 0
