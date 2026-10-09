# render.ps1 - Draw the drawing layer's demo frame to a PNG with the PINNED engine.
#
#   .\render.ps1                              # -> tmp\render\shot.png
#   .\render.ps1 -Out tmp\render\try2.png
#
# Runs `--path . --render-shot <out>` (scripts/app/main.gd, which draws
# scripts/render/demo_frame.gd at 1280x720) and checks that a FRESH PNG came out.
#
# WINDOWED, ON PURPOSE: --headless replaces the renderer with a dummy that
# produces no pixels, so anything that renders is a windowed run and never a
# test. A Godot window opens for a moment and closes by itself; that is expected.
# Steam is switched off for the run (INKWOOD_STEAM=off) unless the caller set
# it -- drawing a picture has no business touching the Steam client.
param (
    [string]$Out = "tmp\render\shot.png"
)

. "$PSScriptRoot\godot_env.ps1"
Normalize-ProcessPath

$engine = Resolve-GodotEngine

$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $PSScriptRoot $Out }
$outPath = [System.IO.Path]::GetFullPath($outPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
# A stale PNG must not pass for this run's (CLAUDE.md: a durable log is guilty
# until proven fresh) -- remove it, then require that it exists afterwards.
if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

if (-not $env:INKWOOD_STEAM) { $env:INKWOOD_STEAM = "off" }

Write-Host "Rendering the demo frame with Godot $($engine.Tag) -> $outPath" -ForegroundColor Cyan
# The console build, called directly: it waits, forwards the engine's output to
# this console and hands back its exit code.
& $engine.ConsolePath --path "$PSScriptRoot" --render-shot "$outPath"
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Host "Render FAILED (exit code $code). Read the output above for the Parse Error or the [render-shot] line." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $outPath)) {
    Write-Host "Render FAILED: the engine exited 0 but wrote no $outPath." -ForegroundColor Red
    exit 1
}
Write-Host "Saved $outPath" -ForegroundColor Green
exit 0
