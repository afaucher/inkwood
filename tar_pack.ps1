# tar_pack.ps1 - Write and read back a .tar.gz from PowerShell 5.1, for the
# Linux target of build.ps1. Dot-sourced by it; not a script to run.
#
# WHY NOT tar.exe. Windows 10+ ships bsdtar, but on Windows it takes a file's
# mode from _stat(), which has no execute bit to report: every entry comes out
# 0644 (0755 only for .exe/.bat/.cmd, by extension). A Linux build packed with
# it extracts non-executable and will not launch -- the exact failure README.md
# says the .tar.gz exists to avoid (zip has the same problem). So the archive is
# written here with the game binary stamped 0755, and read back entry by entry
# the way build.ps1 reads back its zip, mode included.
#
# Plain ustar headers and gzip through .NET's GZipStream -- both in the
# framework PowerShell 5.1 ships with: no module, no download, nothing outside
# the repo. A path longer than 100 bytes goes into the 155-byte prefix field;
# one that fits neither is refused rather than truncated.
#
#   . "$PSScriptRoot\tar_pack.ps1"
#   Write-TarGz -SourceDir $dir -Files $fullPaths -OutPath $archive -Executable @("Inkwood.x86_64")
#   $entries = Read-TarEntries -TarGzPath $archive     # relative name -> @{ Size; Mode }

$TarAscii = [System.Text.Encoding]::ASCII

function Set-TarField {
    param([byte[]]$Header, [int]$Offset, [int]$Length, [string]$Text)
    $bytes = $TarAscii.GetBytes($Text)
    if ($bytes.Length -gt $Length) { throw "tar header field overflow at $Offset`: '$Text'" }
    [Array]::Copy($bytes, 0, $Header, $Offset, $bytes.Length)
}

function Format-TarOctal {
    param([long]$Value, [int]$Digits)
    return ([Convert]::ToString($Value, 8)).PadLeft($Digits, '0')
}

function New-TarHeader {
    param([string]$Name, [long]$Size, [string]$Mode, [long]$MTime)

    # ustar: name holds up to 100 bytes, prefix up to 155, joined with '/'.
    $prefix = ""
    $base = $Name
    if ($Name.Length -gt 100) {
        $base = $null
        for ($i = $Name.IndexOf('/'); $i -ge 0; $i = $Name.IndexOf('/', $i + 1)) {
            if ($i -le 155 -and ($Name.Length - $i - 1) -le 100) {
                $prefix = $Name.Substring(0, $i)
                $base = $Name.Substring($i + 1)
                break
            }
        }
        if ($null -eq $base) { throw "path too long for a ustar header: $Name" }
    }

    $h = New-Object byte[] 512
    Set-TarField $h 0   100 $base
    Set-TarField $h 100 8   ($Mode + "`0")
    Set-TarField $h 108 8   ("0000000`0")
    Set-TarField $h 116 8   ("0000000`0")
    Set-TarField $h 124 12  ((Format-TarOctal $Size 11) + "`0")
    Set-TarField $h 136 12  ((Format-TarOctal $MTime 11) + "`0")
    Set-TarField $h 148 8   "        "          # checksum: spaces while summing
    Set-TarField $h 156 1   "0"                 # a regular file
    Set-TarField $h 257 6   "ustar`0"
    Set-TarField $h 263 2   "00"
    Set-TarField $h 329 8   ("0000000`0")
    Set-TarField $h 337 8   ("0000000`0")
    Set-TarField $h 345 155 $prefix

    $sum = 0
    foreach ($b in $h) { $sum += $b }
    Set-TarField $h 148 8 ((Format-TarOctal $sum 6) + "`0 ")
    return $h
}

# Pack $Files (full paths under $SourceDir) into $OutPath. Entries named in
# $Executable (relative, '/' separators) get 0755; everything else 0644.
function Write-TarGz {
    param([string]$SourceDir, [string[]]$Files, [string]$OutPath, [string[]]$Executable = @())

    $file = New-Object System.IO.FileStream($OutPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
    $gz = New-Object System.IO.Compression.GZipStream($file, [System.IO.Compression.CompressionMode]::Compress)
    try {
        foreach ($path in $Files) {
            $item = Get-Item -LiteralPath $path
            $rel = $item.FullName.Substring($SourceDir.Length).TrimStart('\', '/').Replace('\', '/')
            $mode = if ($Executable -contains $rel) { "0000755" } else { "0000644" }
            $mtime = [long]([DateTimeOffset]$item.LastWriteTimeUtc).ToUnixTimeSeconds()
            $header = New-TarHeader -Name $rel -Size $item.Length -Mode $mode -MTime $mtime
            $gz.Write($header, 0, 512)

            $in = [System.IO.File]::OpenRead($item.FullName)
            try { $in.CopyTo($gz) } finally { $in.Dispose() }
            $pad = (512 - ($item.Length % 512)) % 512
            if ($pad -gt 0) { $gz.Write((New-Object byte[] $pad), 0, $pad) }
        }
        # End of archive: two zero blocks.
        $gz.Write((New-Object byte[] 1024), 0, 1024)
    } finally {
        $gz.Dispose()
        $file.Dispose()
    }
}

# GZipStream may return fewer bytes than asked; fill the buffer or hit EOF.
function Read-TarBlock {
    param($Stream, [byte[]]$Buffer)
    $got = 0
    while ($got -lt $Buffer.Length) {
        $n = $Stream.Read($Buffer, $got, $Buffer.Length - $got)
        if ($n -le 0) { break }
        $got += $n
    }
    return $got
}

# Every regular file in the archive: relative name -> @{ Size = bytes; Mode = "0000755" }.
# Independent of Write-TarGz on purpose: it reads what landed on disk.
function Read-TarEntries {
    param([string]$TarGzPath)

    $entries = @{}
    $file = New-Object System.IO.FileStream($TarGzPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read)
    $gz = New-Object System.IO.Compression.GZipStream($file, [System.IO.Compression.CompressionMode]::Decompress)
    try {
        $header = New-Object byte[] 512
        $skipBuffer = New-Object byte[] 65536
        while ($true) {
            $got = Read-TarBlock $gz $header
            if ($got -eq 0) { break }
            if ($got -lt 512) { throw "truncated tar header in $TarGzPath" }
            $zero = $true
            foreach ($b in $header) { if ($b -ne 0) { $zero = $false; break } }
            if ($zero) { break }

            $name = $TarAscii.GetString($header, 0, 100).TrimEnd([char]0)
            $prefix = $TarAscii.GetString($header, 345, 155).TrimEnd([char]0)
            if ($prefix -ne "") { $name = "$prefix/$name" }
            $size = [Convert]::ToInt64($TarAscii.GetString($header, 124, 11).Trim([char]0, ' '), 8)
            $mode = $TarAscii.GetString($header, 100, 7)
            $type = [char]$header[156]
            if ($type -eq '0' -or $type -eq [char]0) {
                $entries[$name] = @{ Size = $size; Mode = $mode }
            }

            $skip = $size + ((512 - ($size % 512)) % 512)
            while ($skip -gt 0) {
                $n = $gz.Read($skipBuffer, 0, [int][Math]::Min($skipBuffer.Length, $skip))
                if ($n -le 0) { throw "truncated tar entry '$name' in $TarGzPath" }
                $skip -= $n
            }
        }
    } finally {
        $gz.Dispose()
        $file.Dispose()
    }
    return $entries
}
