#requires -Version 5.1
<#
.SYNOPSIS
    Speeds up audio/video files with FFmpeg, with a simple default workflow.
.DESCRIPTION
    By default, asks only for speed (2x) and file selection (all files).
    Press A at either main prompt to open Advanced Settings. Results are saved to output\ and logs are written to Logs\.
    During conversion, press Q, Esc, or Ctrl+C to cancel. FFmpeg is placed in a kill-on-close Windows Job Object
    to prevent background conversions from surviving the PowerShell process.
    Windows PowerShell 5.1 or later is required.
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ── Paths ────────────────────────────────────────────────────────────────────
$script:RootDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    [System.IO.Path]::GetFullPath($PSScriptRoot)
} else {
    [System.IO.Path]::GetFullPath((Get-Location).Path)
}
$script:OutputDirectory = Join-Path $script:RootDirectory 'output'
$script:LogsDirectory = Join-Path $script:RootDirectory 'Logs'
$script:LogPath = $null
$script:ProcessJobHandle = [IntPtr]::Zero
$script:ActiveFfmpegProcess = $null
$script:CancellationRequested = $false
$script:CancelHandler = $null
$script:CancelHandlerRegistered = $false

$script:Settings = [ordered]@{
    Quality             = 'Balanced'
    Recursive           = $false
    AddSpeedSuffix      = $true
    SkipExisting        = $false
    ExternalSubtitles   = $true
    EmbeddedSubtitles   = $true
    ScaleChapters       = $true
    PreserveArtwork     = $true
    OpenOutputAtEnd     = $false
}

$script:MediaExtensions = @(
    '.mp4', '.m4v', '.mov', '.qt', '.mkv', '.avi', '.webm', '.wmv', '.flv', '.f4v',
    '.mpeg', '.mpg', '.mpe', '.m1v', '.m2v', '.m2ts', '.mts', '.ts', '.vob', '.ogv',
    '.3gp', '.3g2', '.asf', '.dv', '.mxf', '.mpv', '.y4m',
    '.mp3', '.mp2', '.m4a', '.m4b', '.m4p', '.mka', '.aac', '.flac', '.wav', '.wave',
    '.ogg', '.oga', '.opus', '.wma', '.aiff', '.aif', '.ape', '.amr', '.ac3', '.dts',
    '.caf', '.au', '.ra'
)

function Write-Message {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS', 'TITLE')][string]$Level = 'INFO',
        [switch]$NoLog
    )

    # Deliberately use the terminal's default colors and theme.
    Write-Host $Message
    if (-not $NoLog -and $script:LogPath) {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        try {
            Add-Content -LiteralPath $script:LogPath -Value ("[{0}] [{1}] {2}" -f $stamp, $Level, $Message) -Encoding UTF8
        } catch {
            Write-Host ("Could not write to the log: {0}" -f $_.Exception.Message)
        }
    }
}

function Write-ThemeHost {
    param([Parameter(Position = 0, Mandatory = $true)][AllowNull()][object]$Object)
    $value = if ($null -eq $Object) { '' } else { [string]$Object }
    # Kept as a small layout helper; no custom foreground/background colors are set.
    Write-Host $value
}

function Write-Header {
    Clear-Host
    Write-Host ''
    Write-ThemeHost '  ███████╗██████╗ ███████╗███████╗██████╗ '
    Write-ThemeHost '  ██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗'
    Write-ThemeHost '  ███████╗██████╔╝█████╗  █████╗  ██║  ██║'
    Write-ThemeHost '  ╚════██║██╔═══╝ ██╔══╝  ██╔══╝  ██║  ██║'
    Write-ThemeHost '  ███████║██║     ███████╗███████╗██████╔╝'
    Write-ThemeHost '  ╚══════╝╚═╝     ╚══════╝╚══════╝╚═════╝ '
    Write-ThemeHost '  Speed-Up Media PS  ·  FFmpeg PowerShell helper'
    Write-Host ''
    Write-ThemeHost ("  Input folder: {0}" -f $script:RootDirectory)
    Write-ThemeHost ("  Output folder: {0}" -f $script:OutputDirectory)
    Write-ThemeHost ("  Logs: {0}" -f $script:LogsDirectory)
    Write-Host ''
}

function Test-PathInsideDirectory {
    param([string]$CandidatePath, [string]$ParentDirectory)
    $candidate = [System.IO.Path]::GetFullPath($CandidatePath)
    $parent = [System.IO.Path]::GetFullPath($ParentDirectory).TrimEnd([char[]]@('\', '/'))
    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Format-Duration {
    param([double]$Seconds)
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0) {
        return '--:--:--'
    }
    $whole = [long][Math]::Floor($Seconds)
    $hours = [long][Math]::Floor($whole / 3600.0)
    $minutes = [int](($whole % 3600) / 60)
    $secs = [int]($whole % 60)
    return ('{0:00}:{1:00}:{2:00}' -f $hours, $minutes, $secs)
}

function Get-QualityDisplayName {
    switch ($script:Settings.Quality) {
        'Compact' { return 'Compact' }
        'High' { return 'High quality' }
        default { return 'Balanced' }
    }
}

function Get-RelativeDisplayPath {
    param([System.IO.FileInfo]$File)
    if ($File.DirectoryName -and $File.DirectoryName.Length -gt $script:RootDirectory.Length) {
        $relativeDirectory = $File.DirectoryName.Substring($script:RootDirectory.Length).TrimStart([char[]]@('\', '/'))
        if ($relativeDirectory) { return Join-Path $relativeDirectory $File.Name }
    }
    return $File.Name
}

function Get-MediaFiles {
    $found = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'

    if ($script:Settings.Recursive) {
        # Walk directories ourselves so output/Logs and their descendants are never scanned.
        $pendingDirectories = New-Object 'System.Collections.Generic.Stack[string]'
        $pendingDirectories.Push($script:RootDirectory)
        while ($pendingDirectories.Count -gt 0) {
            $currentDirectory = $pendingDirectories.Pop()
            foreach ($item in (Get-ChildItem -LiteralPath $currentDirectory -File -ErrorAction SilentlyContinue)) {
                [void]$found.Add($item)
            }
            foreach ($directory in (Get-ChildItem -LiteralPath $currentDirectory -Directory -ErrorAction SilentlyContinue)) {
                # Do not follow junctions or symbolic links, which can create cycles or re-enter excluded folders.
                if (($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $insideOutputDirectory = Test-PathInsideDirectory -CandidatePath $directory.FullName -ParentDirectory $script:OutputDirectory
                $insideLogsDirectory = Test-PathInsideDirectory -CandidatePath $directory.FullName -ParentDirectory $script:LogsDirectory
                if (-not $insideOutputDirectory -and -not $insideLogsDirectory) {
                    $pendingDirectories.Push($directory.FullName)
                }
            }
        }
    } else {
        foreach ($item in (Get-ChildItem -LiteralPath $script:RootDirectory -File -ErrorAction SilentlyContinue)) {
            [void]$found.Add($item)
        }
    }

    $result = @(
        $found | Where-Object { $script:MediaExtensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object -Property FullName
    )
    return $result
}

function Show-AdvancedSettings {
    while ($true) {
        $qualityLabel = Get-QualityDisplayName
        $recursiveLabel = if ($script:Settings.Recursive) { 'ON' } else { 'OFF' }
        $suffixLabel = if ($script:Settings.AddSpeedSuffix) { 'ON' } else { 'OFF' }
        $skipLabel = if ($script:Settings.SkipExisting) { 'ON' } else { 'OFF' }
        $subsLabel = if ($script:Settings.ExternalSubtitles -and $script:Settings.EmbeddedSubtitles) { 'ON' } else { 'PARTIAL/OFF' }
        $chaptersLabel = if ($script:Settings.ScaleChapters) { 'ON' } else { 'OFF' }
        $artLabel = if ($script:Settings.PreserveArtwork) { 'ON' } else { 'OFF' }
        $openLabel = if ($script:Settings.OpenOutputAtEnd) { 'ON' } else { 'OFF' }

        Write-Host ''
        Write-ThemeHost '  ── ADVANCED SETTINGS ──'
        Write-ThemeHost ("  [1] Encoding quality            : {0}" -f $qualityLabel)
        Write-ThemeHost ("  [2] Include subfolders          : {0}" -f $recursiveLabel)
        Write-ThemeHost ("  [3] Add speed to output filename: {0}" -f $suffixLabel)
        Write-ThemeHost ("  [4] Skip existing outputs       : {0}" -f $skipLabel)
        Write-ThemeHost ("  [5] Scale subtitle timing       : {0}" -f $subsLabel)
        Write-ThemeHost ("  [6] Scale chapter timing        : {0}" -f $chaptersLabel)
        Write-ThemeHost ("  [7] Preserve artwork/attachments: {0}" -f $artLabel)
        Write-ThemeHost ("  [8] Open output folder at end   : {0}" -f $openLabel)
        Write-ThemeHost '  [9] Return to the main prompt'
        $choice = (Read-Host '  Choice [1-9]').Trim()
        switch ($choice) {
            '1' {
                Write-Host ''
                Write-ThemeHost '  Quality presets (video / audio bitrate):'
                Write-ThemeHost '    [1] Compact          - smaller files, more compression'
                Write-ThemeHost '    [2] Balanced         - recommended default'
                Write-ThemeHost '    [3] High             - larger files, better image quality'
                $qualityChoice = (Read-Host '  Preset [1-3, Enter = Balanced]').Trim()
                switch ($qualityChoice) {
                    '1' { $script:Settings.Quality = 'Compact' }
                    '3' { $script:Settings.Quality = 'High' }
                    default { $script:Settings.Quality = 'Balanced' }
                }
            }
            '2' { $script:Settings.Recursive = -not [bool]$script:Settings.Recursive }
            '3' { $script:Settings.AddSpeedSuffix = -not [bool]$script:Settings.AddSpeedSuffix }
            '4' { $script:Settings.SkipExisting = -not [bool]$script:Settings.SkipExisting }
            '5' {
                $newValue = -not ([bool]$script:Settings.ExternalSubtitles -and [bool]$script:Settings.EmbeddedSubtitles)
                $script:Settings.ExternalSubtitles = $newValue
                $script:Settings.EmbeddedSubtitles = $newValue
            }
            '6' { $script:Settings.ScaleChapters = -not [bool]$script:Settings.ScaleChapters }
            '7' { $script:Settings.PreserveArtwork = -not [bool]$script:Settings.PreserveArtwork }
            '8' { $script:Settings.OpenOutputAtEnd = -not [bool]$script:Settings.OpenOutputAtEnd }
            '9' { return }
            default { Write-ThemeHost '  Enter a number from 1 to 9.' }
        }
    }
}
function Read-SpeedChoice {
    while ($true) {
        Write-ThemeHost '  1) Speed: [1] 1.5x   [2] 2x (default)'
        Write-ThemeHost '     Press A to open Advanced Settings.'
        $choice = (Read-Host '  Speed [1/2, Enter = 2x, A = Advanced Settings]').Trim()
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '2') { return 2.0 }
        if ($choice -eq '1') { return 1.5 }
        if ($choice -match '^(?i:a)$') { Show-AdvancedSettings; continue }
        Write-ThemeHost '  Enter 1 or 2, or A for Advanced Settings.'
    }
}

function Parse-Selection {
    param([string]$SelectionText, [int]$ItemCount)
    $selected = New-Object 'System.Collections.Generic.SortedSet[int]'
    $tokens = $SelectionText.Split(',')
    foreach ($token in $tokens) {
        $part = $token.Trim()
        if ($part -notmatch '^(\d+)(?:\s*-\s*(\d+))?$') {
            throw "Invalid selection '$part'. Use a format such as 1, 3, 6-11."
        }
        $start = [int]$Matches[1]
        $end = if ($Matches[2]) { [int]$Matches[2] } else { $start }
        if ($start -lt 1 -or $end -lt 1 -or $start -gt $ItemCount -or $end -gt $ItemCount) {
            throw "Numbers must be between 1 and $ItemCount."
        }
        if ($end -lt $start) { throw "Invalid range '$part'. The first number must be smaller than or equal to the last." }
        for ($number = $start; $number -le $end; $number++) { [void]$selected.Add($number) }
    }
    return ,@($selected)
}

function Read-FileSelection {
    param([object[]]$AvailableFiles)
    while ($true) {
        if (-not $AvailableFiles -or $AvailableFiles.Count -eq 0) {
            Write-ThemeHost '  No media files were found with the current search settings.'
            return @()
        }
        Write-Host ''
        Write-ThemeHost '  2) Choose files to process:'
        Write-ThemeHost '     [Enter] All files (default)   [S] Select files   [A] Advanced Settings'
        $choice = (Read-Host '  File selection').Trim()
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') { return @($AvailableFiles) }
        if ($choice -match '^(?i:a)$') { Show-AdvancedSettings; $AvailableFiles = @(Get-MediaFiles); continue }
        if ($choice -notmatch '^(?i:s|2)$') {
            Write-ThemeHost '  Press Enter, S, or A.'
            continue
        }

        Write-Host ''
        Write-ThemeHost '  Enter file numbers. Examples: 1, 3, 6-11 or 1-4, 8.'
        for ($i = 0; $i -lt $AvailableFiles.Count; $i++) {
            Write-ThemeHost ('    [{0,3}] {1}' -f ($i + 1), (Get-RelativeDisplayPath -File $AvailableFiles[$i]))
        }
        while ($true) {
            $numbers = (Read-Host ("  File numbers [1-{0}]" -f $AvailableFiles.Count)).Trim()
            try {
                $indices = Parse-Selection -SelectionText $numbers -ItemCount $AvailableFiles.Count
                $selectedFiles = @()
                foreach ($index in $indices) { $selectedFiles += $AvailableFiles[$index - 1] }
                return $selectedFiles
            } catch {
                Write-ThemeHost ('  {0}' -f $_.Exception.Message)
            }
        }
    }
}

function Escape-FfMetadataValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    $escaped = $Value.Replace('\', '\\')
    $escaped = $escaped.Replace('=', '\=').Replace(';', '\;').Replace('#', '\#')
    $escaped = $escaped.Replace("`r", '\r').Replace("`n", '\n')
    return $escaped
}

function New-ScaledChapterMetadata {
    param([object[]]$Chapters, [double]$Speed)
    if (-not $Chapters -or $Chapters.Count -eq 0) { return $null }
    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ('SpeedUp_Chapters_' + [guid]::NewGuid().ToString('N') + '.txt')
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine(';FFMETADATA1')
    foreach ($chapter in $Chapters) {
        $chapterStartProperty = $chapter.PSObject.Properties['start_time']
        $chapterEndProperty = $chapter.PSObject.Properties['end_time']
        if (-not $chapterStartProperty -or -not $chapterEndProperty -or $null -eq $chapterStartProperty.Value -or $null -eq $chapterEndProperty.Value) { continue }
        $startMs = [long][Math]::Round(([double]$chapterStartProperty.Value * 1000.0) / $Speed)
        $endMs = [long][Math]::Round(([double]$chapterEndProperty.Value * 1000.0) / $Speed)
        if ($endMs -le $startMs) { $endMs = $startMs + 1 }
        [void]$builder.AppendLine('[CHAPTER]')
        [void]$builder.AppendLine('TIMEBASE=1/1000')
        [void]$builder.AppendLine(('START={0}' -f $startMs))
        [void]$builder.AppendLine(('END={0}' -f $endMs))
        $chapterTagsProperty = $chapter.PSObject.Properties['tags']
        if ($chapterTagsProperty -and $chapterTagsProperty.Value) {
            foreach ($property in $chapterTagsProperty.Value.PSObject.Properties) {
                $key = [string]$property.Name
                if ($key -match '^[A-Za-z0-9_-]+$' -and $key -notin @('TIMEBASE', 'START', 'END')) {
                    [void]$builder.AppendLine(('{0}={1}' -f $key, (Escape-FfMetadataValue -Value ([string]$property.Value))))
                }
            }
        }
        [void]$builder.AppendLine('')
    }
    if ($builder.ToString().Trim() -eq ';FFMETADATA1') { return $null }
    [System.IO.File]::WriteAllText($tempPath, $builder.ToString(), ([System.Text.UTF8Encoding]::new($false)))
    return $tempPath
}

function Convert-SubtitleTimestamp {
    param([string]$Timestamp, [double]$Speed, [ValidateSet('SRT', 'ASS')][string]$Format)
    if ($Format -eq 'SRT') {
        $match = [regex]::Match($Timestamp, '^(?<h>\d{2}:)?(?<m>\d{2}):(?<s>\d{2})(?<sep>[,.])(?<ms>\d{3})$')
        if (-not $match.Success) { return $Timestamp }
        $hours = if ($match.Groups['h'].Success) { [int]$match.Groups['h'].Value.TrimEnd(':') } else { 0 }
        $minutes = [int]$match.Groups['m'].Value
        $seconds = [int]$match.Groups['s'].Value
        $milliseconds = [int]$match.Groups['ms'].Value
        $total = (($hours * 3600.0) + ($minutes * 60.0) + $seconds) * 1000.0 + $milliseconds
        $scaled = [long][Math]::Round($total / $Speed, 0, [MidpointRounding]::AwayFromZero)
        $h2 = [long][Math]::Floor($scaled / 3600000.0)
        $m2 = [int](($scaled % 3600000) / 60000)
        $s2 = [int](($scaled % 60000) / 1000)
        $ms2 = [int]($scaled % 1000)
        if ($match.Groups['h'].Success -or $h2 -gt 0) {
            return ('{0:00}:{1:00}:{2:00}{3}{4:000}' -f $h2, $m2, $s2, $match.Groups['sep'].Value, $ms2)
        }
        return ('{0:00}:{1:00}{2}{3:000}' -f $m2, $s2, $match.Groups['sep'].Value, $ms2)
    }

    $ass = [regex]::Match($Timestamp, '^(?<h>\d+):(?<m>\d{2}):(?<s>\d{2})\.(?<cs>\d{2})$')
    if (-not $ass.Success) { return $Timestamp }
    $totalCentiseconds = ((([int]$ass.Groups['h'].Value * 3600.0) + ([int]$ass.Groups['m'].Value * 60.0) + [int]$ass.Groups['s'].Value) * 100.0) + [int]$ass.Groups['cs'].Value
    $scaledCs = [long][Math]::Round($totalCentiseconds / $Speed, 0, [MidpointRounding]::AwayFromZero)
    $assH = [long][Math]::Floor($scaledCs / 360000.0)
    $assM = [int](($scaledCs % 360000) / 6000)
    $assS = [int](($scaledCs % 6000) / 100)
    $assCs = [int]($scaledCs % 100)
    return ('{0}:{1:00}:{2:00}.{3:00}' -f $assH, $assM, $assS, $assCs)
}

function Read-SubtitleText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) -or
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or
        ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) -or
        ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00)
    if ($hasBom) {
        $reader = [System.IO.StreamReader]::new($Path, [System.Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    try {
        $strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
        return $strictUtf8.GetString($bytes)
    } catch {
        # Legacy Russian subtitle files are often saved in the active Windows ANSI code page.
        return [System.Text.Encoding]::Default.GetString($bytes)
    }
}

function Scale-ExternalSubtitleFile {
    param([System.IO.FileInfo]$SubtitleFile, [string]$Destination, [double]$Speed)
    $extension = $SubtitleFile.Extension.ToLowerInvariant()
    $format = if ($extension -in @('.ass', '.ssa')) { 'ASS' } else { 'SRT' }
    $content = Read-SubtitleText -Path $SubtitleFile.FullName
    $newline = if ($content.Contains("`r`n")) { "`r`n" } elseif ($content.Contains("`r")) { "`r" } else { "`n" }
    $lines = [regex]::Split($content, "\r\n|\n|\r")
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($format -eq 'SRT' -and $line.Contains('-->')) {
            $matches = [regex]::Matches($line, '(?<h>\d{2}:)?\d{2}:\d{2}[,.]\d{3}')
            for ($mIndex = $matches.Count - 1; $mIndex -ge 0; $mIndex--) {
                $m = $matches[$mIndex]
                $newTime = Convert-SubtitleTimestamp -Timestamp $m.Value -Speed $Speed -Format 'SRT'
                $line = $line.Remove($m.Index, $m.Length).Insert($m.Index, $newTime)
            }
        } elseif ($format -eq 'ASS' -and $line -match '^\s*Dialogue:') {
            $assMatches = [regex]::Match($line, '^(?<prefix>\s*Dialogue:\s*[^,]*,)(?<start>\d+:\d{2}:\d{2}\.\d{2}),(?<end>\d+:\d{2}:\d{2}\.\d{2}),')
            if ($assMatches.Success) {
                $endNew = Convert-SubtitleTimestamp -Timestamp $assMatches.Groups['end'].Value -Speed $Speed -Format 'ASS'
                $startNew = Convert-SubtitleTimestamp -Timestamp $assMatches.Groups['start'].Value -Speed $Speed -Format 'ASS'
                $line = $line.Remove($assMatches.Groups['end'].Index, $assMatches.Groups['end'].Length).Insert($assMatches.Groups['end'].Index, $endNew)
                $line = $line.Remove($assMatches.Groups['start'].Index, $assMatches.Groups['start'].Length).Insert($assMatches.Groups['start'].Index, $startNew)
            }
        }
        $lines[$i] = $line
    }
    $scaledContent = [string]::Join($newline, $lines)
    $temporarySubtitle = $Destination + '.tmp_' + [guid]::NewGuid().ToString('N')
    try {
        [System.IO.File]::WriteAllText($temporarySubtitle, $scaledContent, ([System.Text.UTF8Encoding]::new($false)))
        Move-Item -LiteralPath $temporarySubtitle -Destination $Destination -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporarySubtitle -PathType Leaf) {
            Remove-Item -LiteralPath $temporarySubtitle -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-OutputVideoPlan {
    param([string]$Extension, [string]$Quality)
    $ext = $Extension.ToLowerInvariant()
    switch ($ext) {
        '.webm' {
            $crf = if ($Quality -eq 'Compact') { '35' } elseif ($Quality -eq 'High') { '26' } else { '31' }
            $cpu = if ($Quality -eq 'Compact') { '6' } elseif ($Quality -eq 'High') { '2' } else { '4' }
            return @{ Codec = 'libvpx-vp9'; Options = @(@{ Name = '-crf'; Value = $crf }, @{ Name = '-b:v'; Value = '0' }, @{ Name = '-deadline'; Value = 'good' }, @{ Name = '-cpu-used'; Value = $cpu }) }
        }
        '.ogv' {
            $q = if ($Quality -eq 'Compact') { '4' } elseif ($Quality -eq 'High') { '9' } else { '6' }
            return @{ Codec = 'libtheora'; Options = @(@{ Name = '-q:v'; Value = $q }) }
        }
        '.avi' {
            $q = if ($Quality -eq 'Compact') { '6' } elseif ($Quality -eq 'High') { '2' } else { '4' }
            return @{ Codec = 'mpeg4'; Options = @(@{ Name = '-q:v'; Value = $q }) }
        }
        { $_ -in @('.wmv', '.asf') } {
            $bitrate = if ($Quality -eq 'Compact') { '1200k' } elseif ($Quality -eq 'High') { '5000k' } else { '2500k' }
            return @{ Codec = 'wmv2'; Options = @(@{ Name = '-b:v'; Value = $bitrate }) }
        }
        '.flv' {
            $bitrate = if ($Quality -eq 'Compact') { '1000k' } elseif ($Quality -eq 'High') { '4000k' } else { '2000k' }
            return @{ Codec = 'flv'; Options = @(@{ Name = '-b:v'; Value = $bitrate }) }
        }
        { $_ -in @('.vob', '.mpeg', '.mpg', '.mpe', '.m1v', '.m2v', '.mpv', '.mxf') } {
            $q = if ($Quality -eq 'Compact') { '7' } elseif ($Quality -eq 'High') { '2' } else { '4' }
            return @{ Codec = 'mpeg2video'; Options = @(@{ Name = '-q:v'; Value = $q }) }
        }
        '.dv' { return @{ Codec = 'dvvideo'; Options = @() } }
        '.y4m' { return @{ Codec = 'rawvideo'; Options = @() } }
        default {
            $crf = if ($Quality -eq 'Compact') { '28' } elseif ($Quality -eq 'High') { '18' } else { '23' }
            $preset = if ($Quality -eq 'Compact') { 'veryfast' } elseif ($Quality -eq 'High') { 'slow' } else { 'medium' }
            return @{ Codec = 'libx264'; Options = @(@{ Name = '-crf'; Value = $crf }, @{ Name = '-preset'; Value = $preset }) }
        }
    }
}

function Get-OutputAudioPlan {
    param([string]$Extension, [string]$Quality)
    $ext = $Extension.ToLowerInvariant()
    $kbps = if ($Quality -eq 'Compact') { '128k' } elseif ($Quality -eq 'High') { '256k' } else { '192k' }
    switch ($ext) {
        '.mp3' { return @{ Codec = 'libmp3lame'; Options = @(@{ Name = '-b:a'; Value = $kbps }) } }
        { $_ -in @('.m4a', '.m4b', '.aac', '.mp4', '.m4v', '.mov', '.3gp', '.3g2', '.mkv', '.mka', '.mp2', '.mpg', '.mpeg', '.mpe', '.m1v', '.m2v', '.m2ts', '.mts', '.ts', '.mpv', '.mp3') } {
            if ($ext -in @('.mpg', '.mpeg', '.mpe', '.m1v', '.m2v', '.mp2')) { return @{ Codec = 'mp2'; Options = @(@{ Name = '-b:a'; Value = $kbps }) } }
            return @{ Codec = 'aac'; Options = @(@{ Name = '-b:a'; Value = $kbps }) }
        }
        { $_ -in @('.ogg', '.oga', '.ogv') } {
            $q = if ($Quality -eq 'Compact') { '3' } elseif ($Quality -eq 'High') { '8' } else { '5' }
            return @{ Codec = 'libvorbis'; Options = @(@{ Name = '-q:a'; Value = $q }) }
        }
        { $_ -in @('.opus', '.webm') } {
            $opusBitrate = if ($Quality -eq 'Compact') { '96k' } elseif ($Quality -eq 'High') { '256k' } else { '160k' }
            return @{ Codec = 'libopus'; Options = @(@{ Name = '-b:a'; Value = $opusBitrate }) }
        }
        '.flac' {
            $compression = if ($Quality -eq 'Compact') { '3' } elseif ($Quality -eq 'High') { '8' } else { '5' }
            return @{ Codec = 'flac'; Options = @(@{ Name = '-compression_level'; Value = $compression }) }
        }
        { $_ -in @('.wav', '.wave', '.caf') } { return @{ Codec = 'pcm_s16le'; Options = @() } }
        { $_ -in @('.aiff', '.aif', '.au') } { return @{ Codec = 'pcm_s16be'; Options = @() } }
        { $_ -in @('.wma', '.wmv', '.asf') } { return @{ Codec = 'wmav2'; Options = @(@{ Name = '-b:a'; Value = $kbps }) } }
        { $_ -in @('.avi', '.flv', '.f4v') } { return @{ Codec = 'libmp3lame'; Options = @(@{ Name = '-b:a'; Value = $kbps }) } }
        '.ac3' { return @{ Codec = 'ac3'; Options = @(@{ Name = '-b:a'; Value = $kbps }) } }
        { $_ -in @('.vob', '.mxf', '.dv') } { return @{ Codec = 'pcm_s16le'; Options = @() } }
        { $_ -in @('.ape', '.ra', '.dts', '.amr') } { return @{ Codec = $null; Options = @() } }
        default { return @{ Codec = 'aac'; Options = @(@{ Name = '-b:a'; Value = $kbps }) } }
    }
}

function Quote-ProcessArgument {
    param([AllowEmptyString()][string]$Argument)
    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }

    # Follow the Windows command-line quoting rules: backslashes before quotes, and at the end,
    # must be doubled when an argument is wrapped in double quotes.
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ([int]$character -eq 92) {
            $backslashCount++
            continue
        }
        if ([int]$character -eq 34) {
            if ($backslashCount -gt 0) { [void]$builder.Append(('\' * (2 * $backslashCount + 1))) }
            else { [void]$builder.Append('\') }
            [void]$builder.Append('"')
        } else {
            if ($backslashCount -gt 0) { [void]$builder.Append(('\' * $backslashCount)) }
            [void]$builder.Append($character)
        }
        $backslashCount = 0
    }
    if ($backslashCount -gt 0) { [void]$builder.Append(('\' * (2 * $backslashCount))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Initialize-ProcessJob {
    if ($script:ProcessJobHandle -ne [IntPtr]::Zero) { return }

    if (-not ('SpeedUpMediaNative.JobApi' -as [type])) {
        $nativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace SpeedUpMediaNative
{
    public static class JobApi
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct BasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct ExtendedLimitInformation
        {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        private static int _lastError;
        public static int LastError { get { return _lastError; } }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr jobAttributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int informationClass, IntPtr information, uint informationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr CreateKillOnCloseJob()
        {
            _lastError = 0;
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
            {
                _lastError = Marshal.GetLastWin32Error();
                return IntPtr.Zero;
            }

            ExtendedLimitInformation information = new ExtendedLimitInformation();
            // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            information.BasicLimitInformation.LimitFlags = 0x2000;
            int length = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            IntPtr buffer = Marshal.AllocHGlobal(length);
            try
            {
                Marshal.StructureToPtr(information, buffer, false);
                if (!SetInformationJobObject(job, 9, buffer, (uint)length))
                {
                    _lastError = Marshal.GetLastWin32Error();
                    CloseHandle(job);
                    return IntPtr.Zero;
                }
                return job;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }

        public static bool Assign(IntPtr job, IntPtr process)
        {
            bool success = AssignProcessToJobObject(job, process);
            if (!success) _lastError = Marshal.GetLastWin32Error();
            return success;
        }

        public static void Close(IntPtr handle)
        {
            if (handle != IntPtr.Zero) CloseHandle(handle);
        }
    }
}
'@
        Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
    }

    $jobHandle = [SpeedUpMediaNative.JobApi]::CreateKillOnCloseJob()
    if ($jobHandle -eq [IntPtr]::Zero) {
        $nativeError = [SpeedUpMediaNative.JobApi]::LastError
        throw ("Could not create a Windows Job Object for FFmpeg cleanup (Win32 error {0}). Conversion was not started because it would not be safe to leave a background process behind." -f $nativeError)
    }
    $script:ProcessJobHandle = $jobHandle
}

function Add-ProcessToCleanupJob {
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)

    if ($script:ProcessJobHandle -eq [IntPtr]::Zero) {
        throw 'The FFmpeg cleanup Job Object is not initialized.'
    }

    if (-not [SpeedUpMediaNative.JobApi]::Assign($script:ProcessJobHandle, $Process.Handle)) {
        $nativeError = [SpeedUpMediaNative.JobApi]::LastError
        try {
            if (-not $Process.HasExited) {
                $Process.Kill()
                $Process.WaitForExit()
            }
        } catch {}
        throw ("Could not attach FFmpeg to its automatic-cleanup Job Object (Win32 error {0}). FFmpeg was stopped to avoid leaving an orphan process." -f $nativeError)
    }
}

function Close-ProcessCleanupJob {
    if ($script:ProcessJobHandle -ne [IntPtr]::Zero) {
        try { [SpeedUpMediaNative.JobApi]::Close($script:ProcessJobHandle) } catch {}
        $script:ProcessJobHandle = [IntPtr]::Zero
    }
}

function Register-ConsoleCancellation {
    if ($script:CancelHandlerRegistered) { return }
    try {
        $script:CancelHandler = [System.ConsoleCancelEventHandler]{
            param($sender, $eventArgs)
            $eventArgs.Cancel = $true
            $script:CancellationRequested = $true
        }
        [Console]::add_CancelKeyPress($script:CancelHandler)
        $script:CancelHandlerRegistered = $true
    } catch {
        Write-Message -Level WARN -Message ("Could not register the Ctrl+C handler; Q/Esc cancellation and process cleanup remain available. {0}" -f $_.Exception.Message)
    }
}

function Unregister-ConsoleCancellation {
    if ($script:CancelHandlerRegistered -and $script:CancelHandler) {
        try { [Console]::remove_CancelKeyPress($script:CancelHandler) } catch {}
    }
    $script:CancelHandler = $null
    $script:CancelHandlerRegistered = $false
}

function Test-CancellationRequest {
    if ($script:CancellationRequested) { return $true }

    try {
        if (-not [Console]::IsInputRedirected -and [Console]::KeyAvailable) {
            $keyInfo = [Console]::ReadKey($true)
            if ($keyInfo.Key -eq [ConsoleKey]::Q -or $keyInfo.Key -eq [ConsoleKey]::Escape) {
                $script:CancellationRequested = $true
                return $true
            }
        }
    } catch {
        # Console key polling is unavailable in some hosts; Ctrl+C and the Job Object remain active.
    }

    return $false
}

function Show-Progress {
    param(
        [int]$FileIndex,
        [int]$FileCount,
        [string]$FileName,
        [double]$FilePercent,
        [double]$TotalPercent,
        [double]$FileElapsed,
        [double]$TotalElapsed,
        [string]$SpeedText,
        [double]$FileEta,
        [double]$TotalEta
    )

    $filePercent = [Math]::Max(0.0, [Math]::Min(100.0, $FilePercent))
    $totalPercent = [Math]::Max(0.0, [Math]::Min(100.0, $TotalPercent))
    $speedDisplay = if ([string]::IsNullOrWhiteSpace($SpeedText)) { 'N/A' } else { $SpeedText.Trim() }
    $fileStatus = ('FILE {0}/{1} | {2} | {3,5:0.0}% | elapsed {4} | remaining {5}' -f `
        $FileIndex, $FileCount, $speedDisplay, $filePercent, (Format-Duration $FileElapsed), (Format-Duration $FileEta))
    $totalStatus = ('TOTAL {0,5:0.0}% | file {1}/{2} | elapsed {3} | ETA {4}' -f `
        $totalPercent, $FileIndex, $FileCount, (Format-Duration $TotalElapsed), (Format-Duration $TotalEta))

    # Use the host-native renderer instead of direct Console cursor writes. This
    # avoids rows being overwritten or progress bars resetting when output wraps.
    Write-Progress -Id 1 -Activity 'Overall queue progress' -Status $totalStatus -PercentComplete ([int][Math]::Round($totalPercent))
    Write-Progress -Id 2 -ParentId 1 -Activity 'Current file' -Status $fileStatus -PercentComplete ([int][Math]::Round($filePercent)) -CurrentOperation $FileName
}

function Close-ProgressDisplay {
    param([switch]$All)

    Write-Progress -Id 2 -Activity 'Current file' -Completed
    if ($All) {
        Write-Progress -Id 1 -Activity 'Overall queue progress' -Completed
    }
}

function Invoke-FFmpegWithProgress {
    param(
        [string]$FfmpegPath,
        [string[]]$Arguments,
        [double]$SourceDuration,
        [double]$Speed,
        [int]$FileIndex,
        [int]$FileCount,
        [string]$DisplayName,
        [System.Diagnostics.Stopwatch]$OverallWatch
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FfmpegPath
    $quotedArguments = foreach ($argument in $Arguments) { Quote-ProcessArgument ([string]$argument) }
    $startInfo.Arguments = [string]::Join(' ', [string[]]$quotedArguments)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $source = $null
    $errorTask = $null
    $progressValues = @{}
    $fileWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $expectedOutputDuration = if ($SourceDuration -gt 0) { $SourceDuration / $Speed } else { 0.0 }
    $lastDraw = [DateTime]::MinValue
    $wasCancelled = $false

    try {
        if (-not $process.Start()) { throw 'Could not start FFmpeg.' }
        $script:ActiveFfmpegProcess = $process
        Add-ProcessToCleanupJob -Process $process
        $errorTask = $process.StandardError.ReadToEndAsync()
        $source = $process.StandardOutput
        $readTask = $source.ReadLineAsync()

        while ($true) {
            if (Test-CancellationRequest) {
                $wasCancelled = $true
                Write-Message -Level WARN -Message ("Cancellation requested. Stopping FFmpeg for '{0}'..." -f $DisplayName)
                try { if (-not $process.HasExited) { $process.Kill() } } catch {}
                break
            }

            if ($readTask.IsCompleted) {
                $line = $readTask.GetAwaiter().GetResult()
                if ($null -eq $line) { break }
                if ($line -match '^([^=]+)=(.*)$') { $progressValues[$Matches[1]] = $Matches[2] }
                if ($progressValues.ContainsKey('progress') -and $progressValues['progress'] -eq 'end') {
                    $progressValues['out_time_us'] = if ($expectedOutputDuration -gt 0) { [string][long]($expectedOutputDuration * 1000000.0) } else { '0' }
                }
                $readTask = $source.ReadLineAsync()
            } else {
                Start-Sleep -Milliseconds 100
            }

            $now = [DateTime]::UtcNow
            if (($now - $lastDraw).TotalMilliseconds -ge 250) {
                $filePct = 0.0
                $outTimeUs = 0L
                if ($progressValues.ContainsKey('out_time_us')) { [void][long]::TryParse([string]$progressValues['out_time_us'], [ref]$outTimeUs) }
                if ($expectedOutputDuration -gt 0) { $filePct = [Math]::Min(100.0, ($outTimeUs / 1000000.0) / $expectedOutputDuration * 100.0) }
                if ($progressValues.ContainsKey('progress') -and $progressValues['progress'] -eq 'end') { $filePct = 100.0 }
                $totalPct = (($FileIndex - 1) + ($filePct / 100.0)) / [Math]::Max(1, $FileCount) * 100.0
                $speedLabel = if ($progressValues.ContainsKey('speed') -and $progressValues['speed']) { [string]$progressValues['speed'] } else { '--' }
                $fileEta = -1.0
                if ($filePct -gt 0 -and $filePct -lt 100) { $fileEta = $fileWatch.Elapsed.TotalSeconds * (100.0 - $filePct) / $filePct }
                $totalEta = -1.0
                if ($totalPct -gt 0 -and $totalPct -lt 100) { $totalEta = $OverallWatch.Elapsed.TotalSeconds * (100.0 - $totalPct) / $totalPct }
                Show-Progress -FileIndex $FileIndex -FileCount $FileCount -FileName $DisplayName -FilePercent $filePct -TotalPercent $totalPct -FileElapsed $fileWatch.Elapsed.TotalSeconds -TotalElapsed $OverallWatch.Elapsed.TotalSeconds -SpeedText $speedLabel -FileEta $fileEta -TotalEta $totalEta
                $lastDraw = $now
            }
        }
        if ($wasCancelled -and -not $process.HasExited) {
            try { $process.Kill() } catch {}
        }
        $process.WaitForExit()
        $fileWatch.Stop()
        $errorText = if ($errorTask) { $errorTask.GetAwaiter().GetResult() } else { '' }
        if ($errorText) {
            foreach ($errorLine in ($errorText -split "`r?`n")) {
                if (-not [string]::IsNullOrWhiteSpace($errorLine) -and $script:LogPath) {
                    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
                    Add-Content -LiteralPath $script:LogPath -Value ("[{0}] [FFMPEG] {1}" -f $stamp, $errorLine) -Encoding UTF8
                }
            }
        }
        $finalSpeed = if ($progressValues.ContainsKey('speed') -and $progressValues['speed']) { [string]$progressValues['speed'] } else { '--' }
        return @{ Cancelled = $wasCancelled; ExitCode = $process.ExitCode; ErrorText = $errorText; Duration = $fileWatch.Elapsed.TotalSeconds; Speed = $finalSpeed }
    } finally {
        if ($process) {
            try {
                if (-not $process.HasExited) {
                    try { $process.Kill() } catch {}
                    try { [void]$process.WaitForExit(5000) } catch {}
                    if ($script:LogPath) {
                        try { Add-Content -LiteralPath $script:LogPath -Value ("[{0}] [WARN] Forced FFmpeg shutdown during script cleanup." -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8 } catch {}
                    }
                }
            } catch {}
            if ([object]::ReferenceEquals($script:ActiveFfmpegProcess, $process)) { $script:ActiveFfmpegProcess = $null }
            $process.Dispose()
        }
    }
}

function Get-ProbeData {
    param([string]$FilePath)
    $probeArgs = @('-v', 'error', '-show_format', '-show_streams', '-show_chapters', '-of', 'json', $FilePath)
    $probeOutput = & $script:FFprobePath @probeArgs 2>$null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -or $null -eq $probeOutput) { throw 'FFprobe could not read this file.' }
    $json = [string]::Join([Environment]::NewLine, [string[]]$probeOutput)
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function Get-OutputPathForFile {
    param([System.IO.FileInfo]$File, [double]$Speed)
    $relativeDirectory = ''
    if ($File.DirectoryName -and $File.DirectoryName.Length -gt $script:RootDirectory.Length) {
        $relativeDirectory = $File.DirectoryName.Substring($script:RootDirectory.Length).TrimStart([char[]]@('\', '/'))
    }
    $targetDirectory = if ($relativeDirectory) { Join-Path $script:OutputDirectory $relativeDirectory } else { $script:OutputDirectory }
    if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
    }
    $speedLabel = if ($Speed -eq 1.5) { '1.5x' } else { '2x' }
    $baseName = if ($script:Settings.AddSpeedSuffix) { '{0}_{1}' -f $File.BaseName, $speedLabel } else { $File.BaseName }
    return (Join-Path $targetDirectory ($baseName + $File.Extension))
}

function Get-SubtitleSidecars {
    param([System.IO.FileInfo]$MediaFile)
    $extensions = @('.srt', '.vtt', '.ass', '.ssa')
    $prefixExact = $MediaFile.BaseName
    return @(
        Get-ChildItem -LiteralPath $MediaFile.DirectoryName -File -ErrorAction SilentlyContinue | Where-Object {
            $ext = $_.Extension.ToLowerInvariant()
            $isSubtitle = $extensions -contains $ext
            $sameStem = $_.Name.StartsWith(($prefixExact + '.'), [System.StringComparison]::OrdinalIgnoreCase) -or $_.BaseName.Equals($prefixExact, [System.StringComparison]::OrdinalIgnoreCase)
            $isSubtitle -and $sameStem
        } | Sort-Object -Property Name
    )
}

function Write-SubtitleSidecars {
    param([System.IO.FileInfo]$MediaFile, [string]$OutputMediaPath, [double]$Speed)
    $sidecars = @(Get-SubtitleSidecars -MediaFile $MediaFile)
    $count = 0
    foreach ($sidecar in $sidecars) {
        try {
            $outputDirectory = Split-Path -Parent $OutputMediaPath
            $outputStem = [System.IO.Path]::GetFileNameWithoutExtension($OutputMediaPath)
            $suffix = $sidecar.Name.Substring($MediaFile.BaseName.Length)
            $subtitleOut = Join-Path $outputDirectory ($outputStem + $suffix)
            if ($script:Settings.ExternalSubtitles) {
                Scale-ExternalSubtitleFile -SubtitleFile $sidecar -Destination $subtitleOut -Speed $Speed
                Write-Message -Level INFO -Message ("Subtitle timing scaled: {0} -> {1}" -f $sidecar.Name, (Split-Path -Leaf $subtitleOut))
            } else {
                Copy-Item -LiteralPath $sidecar.FullName -Destination $subtitleOut -Force -ErrorAction Stop
                Write-Message -Level INFO -Message ("Subtitles copied without timing changes: {0} -> {1}" -f $sidecar.Name, (Split-Path -Leaf $subtitleOut))
            }
            $count++
        } catch {
            Write-Message -Level WARN -Message ("Could not process external subtitle file '{0}': {1}" -f $sidecar.Name, $_.Exception.Message)
        }
    }
    return $count
}

# ── Prepare environment and locate FFmpeg ────────────────────────────────────
try {
    if (-not (Test-Path -LiteralPath $script:OutputDirectory -PathType Container)) { New-Item -ItemType Directory -Path $script:OutputDirectory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $script:LogsDirectory -PathType Container)) { New-Item -ItemType Directory -Path $script:LogsDirectory -Force | Out-Null }
    $script:LogPath = Join-Path $script:LogsDirectory ('Speed-Up-Media_{0}.log' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'))
    Set-Content -LiteralPath $script:LogPath -Value 'Speed-Up Media PS run log' -Encoding UTF8
} catch {
    Write-ThemeHost "Could not create the output/Logs folders: $($_.Exception.Message)"
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}

$localFfmpeg = Join-Path $script:RootDirectory 'ffmpeg.exe'
$localFfprobe = Join-Path $script:RootDirectory 'ffprobe.exe'
$ffmpegFromPath = Get-Command 'ffmpeg' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$ffprobeFromPath = Get-Command 'ffprobe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$ffmpegCommand = if (Test-Path -LiteralPath $localFfmpeg -PathType Leaf) { $localFfmpeg } elseif ($ffmpegFromPath) { $ffmpegFromPath.Source } else { $null }
$ffprobeCommand = if (Test-Path -LiteralPath $localFfprobe -PathType Leaf) { $localFfprobe } elseif ($ffprobeFromPath) { $ffprobeFromPath.Source } else { $null }
if (-not $ffmpegCommand -or -not $ffprobeCommand) {
    Write-Message -Level ERROR -Message 'Could not find ffmpeg.exe and/or ffprobe.exe. Add the FFmpeg bin folder to PATH or place both executables next to this script.'
    Write-Message -Level INFO -Message ("Log file: {0}" -f $script:LogPath)
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}
$script:FFmpegPath = $ffmpegCommand
$script:FFprobePath = $ffprobeCommand

Write-Header
Write-Message -Level INFO -Message ("FFmpeg: {0}" -f $script:FFmpegPath)
Write-Message -Level INFO -Message ("FFprobe: {0}" -f $script:FFprobePath)
Write-Message -Level INFO -Message ("Log file: {0}" -f $script:LogPath)

$mediaFiles = @(Get-MediaFiles)
if ($mediaFiles.Count -eq 0) {
    Write-Message -Level WARN -Message 'No media files were found in the current folder. If your files are in subfolders, press A at the speed prompt and enable Include subfolders.'
} else {
    Write-ThemeHost ("  Files found: {0}" -f $mediaFiles.Count)
}
Write-ThemeHost ("  Quality: {0}  |  Recursive: {1}  |  Speed suffix: {2}" -f (Get-QualityDisplayName), $script:Settings.Recursive, $script:Settings.AddSpeedSuffix)
Write-Host ''

$speed = Read-SpeedChoice
# Advanced Settings may have enabled recursive search at the speed prompt.
$mediaFiles = @(Get-MediaFiles)
if ($mediaFiles.Count -eq 0) {
    Write-Message -Level WARN -Message 'No audio or video files were found with the current search settings.'
    Read-Host 'Press Enter to exit' | Out-Null
    exit 0
}
$filesToProcess = @(Read-FileSelection -AvailableFiles $mediaFiles)
if ($filesToProcess.Count -eq 0) {
    Write-Message -Level WARN -Message 'No files were selected.'
    Read-Host 'Press Enter to exit' | Out-Null
    exit 0
}

$speedLabel = if ($speed -eq 1.5) { '1.5x' } else { '2x' }
$speedInvariant = $speed.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
Write-Host ''
Write-Message -Level TITLE -Message ("Starting: speed {0} | files: {1} | quality: {2}" -f $speedLabel, $filesToProcess.Count, (Get-QualityDisplayName))
Write-Message -Level INFO -Message ("Settings: recursive={0}; speed suffix={1}; skip existing={2}; external subtitles={3}; embedded subtitles={4}; chapters={5}; artwork={6}" -f $script:Settings.Recursive, $script:Settings.AddSpeedSuffix, $script:Settings.SkipExisting, $script:Settings.ExternalSubtitles, $script:Settings.EmbeddedSubtitles, $script:Settings.ScaleChapters, $script:Settings.PreserveArtwork)
Write-ThemeHost '  Progress uses the native PowerShell display. FFmpeg warnings and errors are saved under Logs.'
Write-ThemeHost '  Cancel the current conversion with Q, Esc, or Ctrl+C. Closing this window also stops FFmpeg.'
Write-Host ''

$overallWatch = [System.Diagnostics.Stopwatch]::StartNew()
$successCount = 0
$failedCount = 0
$skippedCount = 0
$cancelledCount = 0
$sidecarErrorCount = 0
$queueCancelled = $false

try {
    Initialize-ProcessJob
    Register-ConsoleCancellation
} catch {
    Write-Message -Level ERROR -Message ("Safe FFmpeg process management could not be enabled: {0}" -f $_.Exception.Message)
    Write-Message -Level ERROR -Message 'No conversions were started.'
    Close-ProcessCleanupJob
    Read-Host 'Press Enter to exit' | Out-Null
    exit 1
}

for ($fileIndex = 0; $fileIndex -lt $filesToProcess.Count; $fileIndex++) {
    if ($script:CancellationRequested) {
        $queueCancelled = $true
        Write-Message -Level WARN -Message 'Cancellation requested. No additional files will be started.'
        break
    }
    $file = $filesToProcess[$fileIndex]
    $humanIndex = $fileIndex + 1
    $displayName = Get-RelativeDisplayPath -File $file
    $outputPath = Get-OutputPathForFile -File $file -Speed $speed
    $temporaryOutputPath = Join-Path (Split-Path -Parent $outputPath) (('{0}.speedtmp_{1}{2}' -f [System.IO.Path]::GetFileNameWithoutExtension($outputPath), [guid]::NewGuid().ToString('N'), [System.IO.Path]::GetExtension($outputPath)))
    $chapterMetadataPath = $null

    if ($script:Settings.SkipExisting -and (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        $skippedCount++
        $skipTotalPercent = ($humanIndex / [double][Math]::Max(1, $filesToProcess.Count)) * 100.0
        $skipTotalEta = if ($skipTotalPercent -gt 0 -and $skipTotalPercent -lt 100) { $overallWatch.Elapsed.TotalSeconds * (100.0 - $skipTotalPercent) / $skipTotalPercent } else { 0.0 }
        Show-Progress -FileIndex $humanIndex -FileCount $filesToProcess.Count -FileName $displayName -FilePercent 100.0 -TotalPercent $skipTotalPercent -FileElapsed 0.0 -TotalElapsed $overallWatch.Elapsed.TotalSeconds -SpeedText 'skipped' -FileEta 0.0 -TotalEta $skipTotalEta
        Close-ProgressDisplay
        Write-Message -Level WARN -Message ("[{0}/{1}] Skipping existing output: {2}" -f $humanIndex, $filesToProcess.Count, (Split-Path -Leaf $outputPath))
        continue
    }

    Write-Message -Level TITLE -Message ("[{0}/{1}] {2}" -f $humanIndex, $filesToProcess.Count, $displayName)
    Write-Message -Level INFO -Message ("Output: {0}" -f $outputPath)

    try {
        $probe = Get-ProbeData -FilePath $file.FullName
        $streams = @($probe.streams)
        $normalVideos = @(
            foreach ($stream in $streams) {
                $attached = $false
                if ($stream.disposition -and $null -ne $stream.disposition.attached_pic) { $attached = ([int]$stream.disposition.attached_pic -eq 1) }
                if ($stream.codec_type -eq 'video' -and -not $attached) { $stream }
            }
        )
        $audioStreams = @($streams | Where-Object { $_.codec_type -eq 'audio' })
        $subtitleStreams = @($streams | Where-Object { $_.codec_type -eq 'subtitle' })
        $pictureSupportedExtensions = @('.mp3', '.mp4', '.m4a', '.m4b', '.m4v', '.mov', '.mkv', '.mka', '.flac')
        $canPreserveArtwork = $script:Settings.PreserveArtwork -and ($file.Extension.ToLowerInvariant() -in $pictureSupportedExtensions)
        $pictureStreams = @(
            foreach ($stream in $streams) {
                if ($canPreserveArtwork -and $stream.codec_type -eq 'video' -and $stream.disposition -and [int]$stream.disposition.attached_pic -eq 1) { $stream }
            }
        )
        $attachmentStreams = @()
        if ($script:Settings.PreserveArtwork -and $file.Extension.ToLowerInvariant() -in @('.mkv', '.mka')) {
            $attachmentStreams = @($streams | Where-Object { $_.codec_type -eq 'attachment' })
        }

        if ($normalVideos.Count -eq 0 -and $audioStreams.Count -eq 0) {
            Write-Message -Level WARN -Message 'Skipping: no regular video or audio streams were found.'
            $skippedCount++
            continue
        }

        $sourceDuration = 0.0
        $durationProperty = $null
        if ($probe.format) { $durationProperty = $probe.format.PSObject.Properties['duration'] }
        if ($durationProperty -and $durationProperty.Value) {
            [void][double]::TryParse([string]$durationProperty.Value, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$sourceDuration)
        }

        if ($script:Settings.ScaleChapters -and $probe.chapters -and @($probe.chapters).Count -gt 0) {
            try { $chapterMetadataPath = New-ScaledChapterMetadata -Chapters @($probe.chapters) -Speed $speed }
            catch { Write-Message -Level WARN -Message ("Could not prepare scaled chapters: {0}" -f $_.Exception.Message) }
        }

        $ffArgs = @('-hide_banner', '-nostdin', '-loglevel', 'warning', '-progress', 'pipe:1', '-stats_period', '0.5', '-i', $file.FullName)
        if ($chapterMetadataPath) { $ffArgs += @('-f', 'ffmetadata', '-i', $chapterMetadataPath) }

        # Map ordinary video, audio and subtitles explicitly; image-based album art is handled separately.
        foreach ($stream in $normalVideos) { $ffArgs += @('-map', ('0:{0}' -f $stream.index)) }
        foreach ($stream in $audioStreams) { $ffArgs += @('-map', ('0:{0}' -f $stream.index)) }
        foreach ($stream in $subtitleStreams) { $ffArgs += @('-map', ('0:{0}' -f $stream.index)) }
        foreach ($stream in $pictureStreams) { $ffArgs += @('-map', ('0:{0}' -f $stream.index)) }
        foreach ($stream in $attachmentStreams) { $ffArgs += @('-map', ('0:{0}' -f $stream.index)) }

        $videoPlan = Get-OutputVideoPlan -Extension $file.Extension -Quality $script:Settings.Quality
        for ($v = 0; $v -lt $normalVideos.Count; $v++) {
            $ffArgs += @(("-filter:v:{0}" -f $v), ("setpts=PTS/{0}" -f $speedInvariant), ("-c:v:{0}" -f $v), $videoPlan.Codec)
            foreach ($optionPair in $videoPlan.Options) {
                $optionName = [string]$optionPair.Name
                $optionValue = [string]$optionPair.Value
                if ($optionName -match '^-(.+):([va])$') { $optionName = ('-{0}:{1}:{2}' -f $Matches[1], $Matches[2], $v) }
                else { $optionName = ('{0}:v:{1}' -f $optionName, $v) }
                $ffArgs += @($optionName, $optionValue)
            }
        }

        $audioPlan = Get-OutputAudioPlan -Extension $file.Extension -Quality $script:Settings.Quality
        if ($audioStreams.Count -gt 0 -and -not $audioPlan.Codec) {
            throw ("No suitable FFmpeg audio encoder is configured for '{0}'. Convert this file to FLAC, WAV, or MP3 first, then try again." -f $file.Extension)
        }
        for ($a = 0; $a -lt $audioStreams.Count; $a++) {
            $ffArgs += @(("-filter:a:{0}" -f $a), ("atempo={0}" -f $speedInvariant), ("-c:a:{0}" -f $a), $audioPlan.Codec)
            foreach ($optionPair in $audioPlan.Options) {
                $optionName = [string]$optionPair.Name
                $optionValue = [string]$optionPair.Value
                if ($optionName -match '^-(.+):([va])$') { $optionName = ('-{0}:{1}:{2}' -f $Matches[1], $Matches[2], $a) }
                else { $optionName = ('{0}:a:{1}' -f $optionName, $a) }
                $ffArgs += @($optionName, $optionValue)
            }
        }

        if ($subtitleStreams.Count -gt 0) {
            $ffArgs += @('-c:s', 'copy')
            if ($script:Settings.EmbeddedSubtitles) {
                $ffArgs += @('-bsf:s', ("setts=pts=PTS/{0}:dts=DTS/{0}:duration=DURATION/{0}" -f $speedInvariant))
            }
        }

        # Cover art is not a moving video stream: copy it untouched and keep its attached-picture disposition.
        for ($p = 0; $p -lt $pictureStreams.Count; $p++) {
            $videoOrdinal = $normalVideos.Count + $p
            $ffArgs += @(("-c:v:{0}" -f $videoOrdinal), 'copy', ("-disposition:v:{0}" -f $videoOrdinal), 'attached_pic')
        }
        if ($attachmentStreams.Count -gt 0) { $ffArgs += @('-c:t', 'copy') }

        $ffArgs += @('-map_metadata', '0')
        if ($chapterMetadataPath) {
            $ffArgs += @('-map_chapters', '1')
        } elseif ($probe.chapters -and @($probe.chapters).Count -gt 0) {
            # When chapter rescaling is disabled or fails, preserve the original chapter data.
            $ffArgs += @('-map_chapters', '0')
        } else {
            $ffArgs += @('-map_chapters', '-1')
        }
        if ($file.Extension.ToLowerInvariant() -in @('.mp4', '.m4v', '.mov', '.m4a', '.m4b', '.3gp', '.3g2')) { $ffArgs += @('-movflags', '+faststart') }
        $ffArgs += @('-y', $temporaryOutputPath)

        $runResult = Invoke-FFmpegWithProgress -FfmpegPath $script:FFmpegPath -Arguments $ffArgs -SourceDuration $sourceDuration -Speed $speed -FileIndex $humanIndex -FileCount $filesToProcess.Count -DisplayName $displayName -OverallWatch $overallWatch
        Close-ProgressDisplay
        if ($runResult.Cancelled) {
            $cancelledCount++
            $queueCancelled = $true
            Write-Message -Level WARN -Message 'Current conversion cancelled. Remaining files will not be started.'
        } elseif ($runResult.ExitCode -eq 0 -and (Test-Path -LiteralPath $temporaryOutputPath -PathType Leaf)) {
            Move-Item -LiteralPath $temporaryOutputPath -Destination $outputPath -Force -ErrorAction Stop
            Write-Message -Level SUCCESS -Message ("Completed in {0} (FFmpeg speed: {1})." -f (Format-Duration $runResult.Duration), $runResult.Speed)
            $successCount++
            $sidecarFiles = @(Get-SubtitleSidecars -MediaFile $file)
            if ($sidecarFiles.Count -gt 0) {
                $processedCount = Write-SubtitleSidecars -MediaFile $file -OutputMediaPath $outputPath -Speed $speed
                if ($processedCount -lt $sidecarFiles.Count) { $sidecarErrorCount += ($sidecarFiles.Count - $processedCount) }
            }
        } else {
            if ($runResult.ExitCode -ne 0) {
                $failureMessage = "FFmpeg exited with error code $($runResult.ExitCode)."
            } else {
                $failureMessage = 'FFmpeg reported success, but no temporary output file was created.'
            }
            if ($runResult.ErrorText) {
                $errorLines = @($runResult.ErrorText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($errorLines.Count -gt 0) { $failureMessage += ' ' + (($errorLines | Select-Object -Last 2) -join ' | ') }
            }
            Write-Message -Level ERROR -Message $failureMessage
            $failedCount++
        }
    } catch {
        Write-Message -Level ERROR -Message ("Failed to process '{0}': {1}" -f $displayName, $_.Exception.Message)
        $failedCount++
    } finally {
        Close-ProgressDisplay
        if (Test-Path -LiteralPath $temporaryOutputPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryOutputPath -Force -ErrorAction SilentlyContinue }
        if ($chapterMetadataPath -and (Test-Path -LiteralPath $chapterMetadataPath -PathType Leaf)) { Remove-Item -LiteralPath $chapterMetadataPath -Force -ErrorAction SilentlyContinue }
    }
    if ($queueCancelled) { break }
}

Unregister-ConsoleCancellation
Close-ProcessCleanupJob
$overallWatch.Stop()
Close-ProgressDisplay -All
Write-Host ''
Write-ThemeHost '  ═══════════════════ SUMMARY ═══════════════════'
Write-Message -Level SUCCESS -Message ("Succeeded: {0}" -f $successCount)
Write-Message -Level WARN -Message ("Skipped: {0}" -f $skippedCount)
Write-Message -Level ERROR -Message ("Failed: {0}" -f $failedCount)
Write-Message -Level WARN -Message ("Cancelled: {0}" -f $cancelledCount)
if ($queueCancelled) {
    $notStartedCount = [Math]::Max(0, $filesToProcess.Count - $successCount - $failedCount - $skippedCount - $cancelledCount)
    if ($notStartedCount -gt 0) { Write-Message -Level WARN -Message ("Not started: {0}" -f $notStartedCount) }
}
if ($sidecarErrorCount -gt 0) { Write-Message -Level WARN -Message ("External subtitle errors: {0}" -f $sidecarErrorCount) }
Write-Message -Level INFO -Message ("Total elapsed: {0}" -f (Format-Duration $overallWatch.Elapsed.TotalSeconds))
Write-Message -Level INFO -Message ("Output folder: {0}" -f $script:OutputDirectory)
Write-Message -Level INFO -Message ("Log file: {0}" -f $script:LogPath)
Write-Host ''

if ($script:Settings.OpenOutputAtEnd) {
    try { Start-Process explorer.exe -ArgumentList (Quote-ProcessArgument $script:OutputDirectory) } catch { Write-Message -Level WARN -Message ("Could not open the output folder: {0}" -f $_.Exception.Message) }
}

Read-Host 'Press Enter to exit' | Out-Null
