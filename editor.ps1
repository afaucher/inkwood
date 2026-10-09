# editor.ps1 - Open this project in the engine it is PINNED to (godot.manifest).
#
#   .\editor.ps1                    # open the editor
#   .\editor.ps1 -Wait              # hold this console until the editor closes
#   .\editor.ps1 -GodotArgs --version
#
# Use this rather than double-clicking project.godot. A .godot file opens in
# whichever Godot the shell happens to have associated with it -- on a machine
# with several installs that is a coin flip, and opening a project in the wrong
# engine is not a harmless mistake: a NEWER editor silently rewrites
# project.godot, the scenes and the .import cache into its own format, and the
# pinned engine can no longer load what it left behind.
param (
    [switch]$Wait,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$GodotArgs = @()
)

. "$PSScriptRoot\godot_env.ps1"
Normalize-ProcessPath

$engine = Resolve-GodotEngine

Write-Host "Opening $PSScriptRoot in Godot $($engine.Tag)" -ForegroundColor Cyan
$argList = @("--editor", "--path", "`"$PSScriptRoot`"") + $GodotArgs

# The GUI binary, not the console one: this is the interactive editor, and
# Start-Process without -Wait lets the launching console close behind it.
if ($Wait) {
    Start-Process -FilePath $engine.Path -ArgumentList $argList -Wait -NoNewWindow
} else {
    Start-Process -FilePath $engine.Path -ArgumentList $argList
}
