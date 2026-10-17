# Google Java Format on Git-changed line ranges only (not whole files).
# Spotless cannot limit formatting to lines, so this calls the GJF CLI with --lines.
# After GJF runs, non-affected lines are restored so GJF --lines spillover cannot rewrite them.
param(
    [ValidateSet('check', 'apply')]
    [string]$Mode = 'check',
    [switch]$PreCommit
)

$ErrorActionPreference = 'Stop'
$GjfVersion = '1.24.0'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
Set-Location $repoRoot

function Invoke-Git([string[]]$GitArgs) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& git @GitArgs 2>$null | Where-Object { $_ -is [string] -and $_.Length -gt 0 })
    $script:GitExit = $LASTEXITCODE
    $ErrorActionPreference = $saved
    Write-Output -NoEnumerate $output
}

function Get-JavaPaths([switch]$StagedOnly) {
    $names = New-Object System.Collections.Generic.List[string]
    if ($StagedOnly) {
        $found = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--cached', '--name-only', '--diff-filter=ACMR')
        foreach ($name in $found) { $names.Add([string]$name) }
    } else {
        $found = Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--name-only', 'HEAD', '--diff-filter=ACMR')
        foreach ($name in $found) { $names.Add([string]$name) }
        $found = Invoke-Git @('-c', 'core.quotepath=false', 'ls-files', '--others', '--exclude-standard')
        foreach ($name in $found) { $names.Add([string]$name) }
    }
    $java = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $path = ([string]$name).Replace('\', '/')
        if ($path -match '^src/(main|test)/java/.+\.java$' -and $path -notmatch '/notification/avro/' -and -not $java.Contains($path)) {
            $java.Add($path)
        }
    }
    Write-Output -NoEnumerate $java.ToArray()
}

function Get-AffectedLineNumbers([string]$diffText) {
    $numbers = New-Object System.Collections.Generic.List[int]
    $newLine = 0
    foreach ($raw in ($diffText -split "`n")) {
        $raw = $raw.TrimEnd("`r")
        if ($raw.StartsWith('@@')) {
            $hunk = [regex]::Match($raw, '\+(\d+)(?:,(\d+))?')
            if ($hunk.Success) { $newLine = [int]$hunk.Groups[1].Value }
            continue
        }
        if ($raw.StartsWith('+++') -or $raw.StartsWith('---') -or $raw.StartsWith('diff ') -or $raw.StartsWith('index ') -or $raw.StartsWith('\')) {
            continue
        }
        if ($raw.StartsWith('+')) {
            $numbers.Add($newLine)
            $newLine++
            continue
        }
        if ($raw.StartsWith('-')) { continue }
        if ($newLine -gt 0) { $newLine++ }
    }
    Write-Output -NoEnumerate $numbers.ToArray()
}

function Get-FlatIntList($value) {
    $values = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue($value)
    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($null -eq $cur) { continue }
        if ($cur -is [int] -or $cur -is [long]) {
            $values.Add([int]$cur)
            continue
        }
        if ($cur -is [string]) {
            if ($cur.Length -gt 0) { $values.Add([int]$cur) }
            continue
        }
        if ($cur -is [System.Array] -or ($cur -is [System.Collections.IEnumerable] -and $cur -isnot [string])) {
            foreach ($item in $cur) { $queue.Enqueue($item) }
            continue
        }
        $values.Add([int]$cur)
    }
    return $values
}

function ConvertTo-LineRanges($lineNumbers) {
    $ranges = New-Object System.Collections.Generic.List[string]
    $values = Get-FlatIntList $lineNumbers
    if ($values.Count -eq 0) { return @() }
    $sorted = @($values | Sort-Object -Unique)
    $start = [int]$sorted[0]
    $prev = [int]$sorted[0]
    for ($i = 1; $i -lt $sorted.Count; $i++) {
        $n = [int]$sorted[$i]
        if ($n -eq ($prev + 1)) {
            $prev = $n
            continue
        }
        $ranges.Add("${start}:${prev}")
        $start = $n
        $prev = $n
    }
    $ranges.Add("${start}:${prev}")
    return $ranges
}

function Get-GjfJar {
    $toolsDir = Join-Path $PSScriptRoot 'tools'
    if (-not (Test-Path -LiteralPath $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir | Out-Null
    }
    $jarName = "google-java-format-$GjfVersion-all-deps.jar"
    $jarPath = Join-Path $toolsDir $jarName
    if (-not (Test-Path -LiteralPath $jarPath)) {
        $url = "https://github.com/google/google-java-format/releases/download/v$GjfVersion/$jarName"
        Write-Host "Downloading $jarName"
        Invoke-WebRequest -Uri $url -OutFile $jarPath
    }
    return $jarPath
}

function Get-FileText([string]$path) {
    return [System.IO.File]::ReadAllText($path)
}

function Write-FileText([string]$path, [string]$text) {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $text, $utf8)
}

function Get-Newline([string]$text) {
    if ($text.Contains("`r`n")) { return "`r`n" }
    return "`n"
}

function Split-FileLines([string]$text) {
    $newline = Get-Newline $text
    $normalized = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $hasFinalNewline = $normalized.EndsWith("`n")
    $body = $normalized.TrimEnd("`n")
    $lines = @()
    if ($body.Length -gt 0) {
        $lines = $body.Split([char]10)
    }
    return @{
        Lines = $lines
        Newline = $newline
        HasFinalNewline = $hasFinalNewline
    }
}

function Join-FileLines([string[]]$lines, [string]$newline, [bool]$hasFinalNewline) {
    $text = [string]::Join($newline, $lines)
    if ($hasFinalNewline) { $text += $newline }
    return $text
}

# Keep GJF output only on affected lines when line count is unchanged.
# If GJF splits/merges lines, fall back to the full GJF result for that file.
function Limit-FormatToAffectedLines([string]$beforeText, [string]$afterText, $affectedLines) {
    $before = Split-FileLines $beforeText
    $after = Split-FileLines $afterText
    if ($before.Lines.Count -ne $after.Lines.Count) {
        return $afterText
    }
    $affected = @{}
    foreach ($n in (Get-FlatIntList $affectedLines)) { $affected[[int]$n] = $true }
    $merged = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $before.Lines.Count; $i++) {
        $lineNo = $i + 1
        if ($affected.ContainsKey($lineNo)) {
            $merged.Add([string]$after.Lines[$i])
        } else {
            $merged.Add([string]$before.Lines[$i])
        }
    }
    return (Join-FileLines $merged.ToArray() $before.Newline $before.HasFinalNewline)
}

$paths = Get-JavaPaths -StagedOnly:$PreCommit
if ($null -eq $paths -or $paths.Count -eq 0) {
    Write-Host 'No changed Java files to format.'
    exit 0
}

foreach ($relative in $paths) {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $relative) -PathType Leaf)) {
        throw "Selected Java file does not exist: $relative"
    }
    if ($PreCommit) {
        $unstaged = Invoke-Git @('diff', '--name-only', '--', $relative)
        if ($unstaged.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$unstaged[0])) {
            throw "$relative has edits that are not staged. Stage the file, then commit again."
        }
    }
}

$jar = Get-GjfJar
$failed = $false
$formattedFiles = 0

foreach ($relative in $paths) {
    $full = Join-Path $repoRoot $relative
    Invoke-Git @('ls-files', '--error-unmatch', '--', $relative) | Out-Null
    $untracked = $script:GitExit -ne 0

    $beforeText = Get-FileText $full
    $beforeInfo = Split-FileLines $beforeText

    $affected = @()
    $ranges = @()
    if ($untracked) {
        if ($beforeInfo.Lines.Count -lt 1) { continue }
        $affected = @(1..$beforeInfo.Lines.Count)
        $ranges = @("1:$($beforeInfo.Lines.Count)")
    } else {
        $diffArgs = @('-c', 'core.quotepath=false', 'diff', '-U0', '--', $relative)
        if ($PreCommit) {
            $diffArgs = @('-c', 'core.quotepath=false', 'diff', '--cached', '-U0', '--', $relative)
        }
        $diffLines = Invoke-Git $diffArgs
        $affected = Get-FlatIntList (Get-AffectedLineNumbers (($diffLines | ForEach-Object { [string]$_ }) -join "`n"))
        if ($affected.Count -eq 0) { continue }
        $ranges = ConvertTo-LineRanges $affected
    }
    if ($ranges.Count -eq 0) { continue }

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("gjf-" + [guid]::NewGuid().ToString('N') + '.java')
    try {
        Write-FileText $temp $beforeText

        $gjfArgs = New-Object System.Collections.Generic.List[string]
        $gjfArgs.Add('-jar')
        $gjfArgs.Add($jar)
        $gjfArgs.Add('--skip-sorting-imports')
        $gjfArgs.Add('--skip-removing-unused-imports')
        foreach ($range in $ranges) {
            $gjfArgs.Add('--lines=' + $range)
        }
        $gjfArgs.Add('--replace')
        $gjfArgs.Add($temp)

        Write-Host ("Formatting {0} line range(s) in {1}" -f $ranges.Count, $relative)
        & java @($gjfArgs.ToArray())
        if ($LASTEXITCODE -ne 0) {
            $failed = $true
            continue
        }

        $afterText = Get-FileText $temp
        $limited = Limit-FormatToAffectedLines $beforeText $afterText $affected
        $changed = -not [string]::Equals($limited, $beforeText, [StringComparison]::Ordinal)

        if ($Mode -eq 'check') {
            if ($changed) {
                Write-Host $relative
                $failed = $true
            }
        } else {
            if ($changed) {
                Write-FileText $full $limited
                Write-Host '  applied'
                $formattedFiles++
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

if ($Mode -eq 'apply') {
    Write-Host ("Google Java Format apply finished on {0} file(s)." -f $formattedFiles)
}

if ($failed) { exit 1 }
exit 0
