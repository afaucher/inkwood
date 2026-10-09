# render.ps1 - Draw a frame to a PNG with the PINNED engine.
#
#   .\render.ps1                              # the drawing layer's demo frame -> tmp\render\shot.png
#   .\render.ps1 -Out tmp\render\try2.png
#   .\render.ps1 -Scene 20261009              # the scene for a seed -> tmp\render\scene_20261009.png
#   .\render.ps1 -Scene 20261009 -NoGrain -Parity -Out tmp\render\parity.png
#
# Without -Scene: `--path . --render-shot <out>` (scripts/app/main.gd, which
# draws scripts/render/demo_frame.gd at 1280x720).
# With -Scene <seed>: `--path . --render-scene <seed> <out>` -- the scene
# generator (scripts/world/scene_gen.gd) and the port of the prototype's draw
# routines (scripts/render/ink_renderer.gd), 1280x720. Scene-only switches:
#   -NoGrain      grain pass off (the browser's grain is Math.random, so a
#                 pixel comparison with a capture runs with grain off on both sides)
#   -Parity       parameters that carry a prototype_default in
#                 data/params/render_defaults.json set back to it (shadow
#                 strength 0.92 instead of the decided 0.44), to compare with
#                 the prototype at its own defaults
#   -PaperShader  the paper tint from the GPU twin instead of GDScript fbm (faster)
# Either way the script checks that a FRESH PNG came out.
#
# WINDOWED, ON PURPOSE: --headless replaces the renderer with a dummy that
# produces no pixels, so anything that renders is a windowed run and never a
# test. A Godot window opens for a moment and closes by itself; that is expected.
# Steam is switched off for the run (INKWOOD_STEAM=off) unless the caller set
# it -- drawing a picture has no business touching the Steam client.
param (
    [string]$Out = "",
    [string]$Scene = "",
    [switch]$NoGrain,
    [switch]$Parity,
    [switch]$PaperShader
)

. "$PSScriptRoot\godot_env.ps1"
Normalize-ProcessPath

if ($Scene -ne "" -and $Scene -notmatch '^-?\d+$') {
    Write-Host "Render FAILED: -Scene takes an integer seed, got '$Scene'." -ForegroundColor Red
    exit 1
}
if ($Scene -eq "" -and ($NoGrain -or $Parity -or $PaperShader)) {
    Write-Host "Render FAILED: -NoGrain, -Parity and -PaperShader apply to -Scene renders only." -ForegroundColor Red
    exit 1
}
if ($Out -eq "") {
    $Out = if ($Scene -ne "") { "tmp\render\scene_$Scene.png" } else { "tmp\render\shot.png" }
}

$engine = Resolve-GodotEngine

$outPath = if ([System.IO.Path]::IsPathRooted($Out)) { $Out } else { Join-Path $PSScriptRoot $Out }
$outPath = [System.IO.Path]::GetFullPath($outPath)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outPath) | Out-Null
# A stale PNG must not pass for this run's (CLAUDE.md: a durable log is guilty
# until proven fresh) -- remove it, then require that it exists afterwards.
if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force }

if (-not $env:INKWOOD_STEAM) { $env:INKWOOD_STEAM = "off" }

# The console build, called directly: it waits, forwards the engine's output to
# this console and hands back its exit code.
if ($Scene -ne "") {
    $extra = @()
    if ($NoGrain) { $extra += "--no-grain" }
    if ($Parity) { $extra += "--parity" }
    if ($PaperShader) { $extra += "--paper-shader" }
    Write-Host "Rendering scene $Scene with Godot $($engine.Tag) -> $outPath" -ForegroundColor Cyan
    & $engine.ConsolePath --path "$PSScriptRoot" --render-scene "$Scene" "$outPath" @extra
} else {
    Write-Host "Rendering the demo frame with Godot $($engine.Tag) -> $outPath" -ForegroundColor Cyan
    & $engine.ConsolePath --path "$PSScriptRoot" --render-shot "$outPath"
}
$code = $LASTEXITCODE

if ($code -ne 0) {
    Write-Host "Render FAILED (exit code $code). Read the output above for the Parse Error or the [render-shot] / [render-scene] line." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $outPath)) {
    Write-Host "Render FAILED: the engine exited 0 but wrote no $outPath." -ForegroundColor Red
    exit 1
}
Write-Host "Saved $outPath" -ForegroundColor Green
exit 0
