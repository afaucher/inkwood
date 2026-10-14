# tools/lib.ps1 - helpers shared by tools/gate.ps1 and tools/shot.ps1. Dot-sourced, never run.
#
# The tools exist to keep agent sessions short: one call, a summary, only the error lines.
# Windows-only dev helpers like tar_pack.ps1 (CLAUDE.md, "Build tooling"); build.ps1 is untouched.

# The lines worth reading in a Godot run's output: script/parse/engine errors, failed asserts,
# with the "at:" location line that follows each. Repeats (an error logged every frame) are
# collapsed to one line with a count. At most $Max distinct entries.
function Get-GodotErrorLines {
    param([string]$Text, [int]$Max = 8)
    if (-not $Text) { return @() }
    $lines = $Text -split "`r?`n"
    $order = New-Object System.Collections.Generic.List[string]
    $count = @{}
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -notmatch 'SCRIPT ERROR|Parse Error|USER ERROR|^ERROR:|ASSERT FAILED|\[TEST FAILED\]|Failed to load script|Invalid call|Invalid access|Cannot call method') { continue }
        $entry = $l.Trim()
        if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match '^\s+at:') { $entry += "  " + $lines[$i + 1].Trim() }
        if ($count.ContainsKey($entry)) { $count[$entry]++ } else { $count[$entry] = 1; $order.Add($entry) }
    }
    $out = @()
    foreach ($e in $order) {
        if ($out.Count -ge $Max) { $out += "... ($($order.Count - $Max) more distinct error lines)"; break }
        $out += $(if ($count[$e] -gt 1) { "$e  (x$($count[$e]))" } else { $e })
    }
    return $out
}

# Stop a process WE started, and its children (the _console.exe wrapper runs the real engine
# as a child), by PID. Never by image name: other agents and Alex's playtest run Godot too.
function Stop-ProcessTree {
    param([int]$ProcessId)
    & taskkill.exe /PID $ProcessId /T /F 2>&1 | Out-Null
}

# Start a process with stdout/stderr captured asynchronously. Raw .NET Process rather than
# Start-Process: ExitCode is dependable alongside redirected output (test_runner.ps1's note).
function Start-Captured {
    param([string]$File, [string]$Arguments, [hashtable]$Env = @{})
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $File
    $psi.Arguments = $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return [PSCustomObject]@{
        Proc  = $p
        Out   = $p.StandardOutput.ReadToEndAsync()
        Err   = $p.StandardError.ReadToEndAsync()
        Start = Get-Date
    }
}
