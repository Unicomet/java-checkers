# Edits only changed Java lines. It trims trailing whitespace, makes the indent
# character match the rest of the file without changing indent width, and splits
# a line longer than 120 characters at a safe comma or && / ||.
param(
    [ValidateSet('check', 'apply')]
    [string]$Mode = 'check',
    [switch]$PreCommit
)

$ErrorActionPreference = 'Stop'
$MaxLine = 120
$IndentSize = 4

function Show-TrailingWhitespace([string]$line) {
    if ($line -match '^(.*?)([ \t]+)$') {
        return $Matches[1] + (($Matches[2] -replace ' ', '.' -replace "`t", '>'))
    }
    return $line
}

function Get-AffectedLineNumbers([string]$diffText) {
    $numbers = New-Object System.Collections.Generic.List[int]
    $newLine = 0
    foreach ($raw in ($diffText -split "`n")) {
        $raw = $raw.TrimEnd("`r")
        if ($raw.StartsWith('@@')) {
            $hunk = [regex]::Match($raw, '\+(\d+)')
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

function Get-UsesTabs([string[]]$lines) {
    $tabs = 0
    $spaces = 0
    foreach ($line in $lines) {
        if ($line.StartsWith("`t")) { $tabs++ }
        elseif ($line.StartsWith('    ')) { $spaces++ }
    }
    return ($tabs -gt $spaces)
}

function Get-LeadingWhitespace([string]$line) {
    $match = [regex]::Match($line, '^[ \t]*')
    return $match.Value
}

function Find-SplitIndex([string]$line) {
    $limit = [Math]::Min($MaxLine, $line.Length)
    $inString = $false
    $inChar = $false
    $escape = $false
    $paren = 0
    $angle = 0
    $best = -1
    for ($i = 0; $i -lt $limit; $i++) {
        $c = $line[$i]
        if ($escape) { $escape = $false; continue }
        if ($inString) {
            if ($c -eq '\') { $escape = $true; continue }
            if ($c -eq '"') { $inString = $false }
            continue
        }
        if ($inChar) {
            if ($c -eq '\') { $escape = $true; continue }
            if ($c -eq "'") { $inChar = $false }
            continue
        }
        if ($c -eq '"') { $inString = $true; continue }
        if ($c -eq "'") { $inChar = $true; continue }
        if (($i + 1) -lt $line.Length -and $c -eq '/' -and $line[$i + 1] -eq '/') { break }
        if ($c -eq '(' -or $c -eq '[') { $paren++; continue }
        if ($c -eq ')' -or $c -eq ']') { if ($paren -gt 0) { $paren-- }; continue }
        if ($c -eq '<') {
            $next = if (($i + 1) -lt $line.Length) { $line[$i + 1] } else { [char]0 }
            if ($next -ne '=') { $angle++ }
            continue
        }
        if ($c -eq '>') {
            $previous = if ($i -gt 0) { $line[$i - 1] } else { [char]0 }
            $next = if (($i + 1) -lt $line.Length) { $line[$i + 1] } else { [char]0 }
            if ($previous -ne '-' -and $next -ne '=' -and $angle -gt 0) { $angle-- }
            continue
        }
        if ($paren -gt 0 -and $angle -eq 0 -and $c -eq ',') {
            $tail = $line.Substring($i + 1).Trim()
            if ($tail.Length -gt 0 -and $tail -notmatch '^[\}\)\];]+$') { $best = $i + 1 }
        }
        if (($i + 4) -le $line.Length) {
            $op = $line.Substring($i, 4)
            if ($op -eq ' && ' -or $op -eq ' || ') { $best = $i + 1 }
        }
    }
    if ($best -le (Get-LeadingWhitespace $line).Length) { return -1 }
    return $best
}

function Split-LongLine([string]$line, [bool]$useTabs) {
    $pieces = New-Object System.Collections.Generic.List[string]
    $current = $line
    for ($guard = 0; $guard -lt 8 -and $current.Length -gt $MaxLine; $guard++) {
        $comment = [regex]::Match($current, '^([ \t]*)(//[ ]?|\*[ ]+)(.*)$')
        if ($comment.Success) {
            $prefix = $comment.Groups[1].Value + $comment.Groups[2].Value
            $room = $MaxLine - $prefix.Length
            if ($room -lt 20) { break }
            $window = [Math]::Min($MaxLine, $current.Length)
            $space = $current.LastIndexOf(' ', ($window - 1))
            if ($space -le $prefix.Length) { break }
            $pieces.Add($current.Substring(0, $space).TrimEnd())
            $current = $prefix + $current.Substring($space + 1).TrimStart()
            continue
        }
        $splitAt = Find-SplitIndex $current
        if ($splitAt -lt 0) { break }
        $head = $current.Substring(0, $splitAt).TrimEnd()
        $tail = $current.Substring($splitAt).TrimStart()
        if ($head.Length -eq 0 -or $tail.Length -eq 0) { break }
        $pieces.Add($head)
        $extra = if ($useTabs) { "`t" } else { ' ' * $IndentSize }
        $current = (Get-LeadingWhitespace $head) + $extra + $tail
    }
    $pieces.Add($current)
    Write-Output -NoEnumerate $pieces.ToArray()
}

function Format-ChangedLine([string]$line, [bool]$useTabs) {
    $match = [regex]::Match($line, '^([ \t]*)(.*)$')
    $indentRaw = $match.Groups[1].Value
    $rest = $match.Groups[2].Value.TrimEnd()
    if ($rest.Length -eq 0) {
        Write-Output -NoEnumerate @('')
        return
    }
    $cols = 0
    foreach ($ch in $indentRaw.ToCharArray()) {
        if ($ch -eq "`t") { $cols += $IndentSize } else { $cols++ }
    }
    if ($useTabs) {
        $tabs = [int][Math]::Floor($cols / $IndentSize)
        $indent = ("`t" * $tabs) + (' ' * ($cols % $IndentSize))
    } else {
        $indent = ' ' * $cols
    }
    Write-Output -NoEnumerate (Split-LongLine ($indent + $rest) $useTabs)
}

function Get-FormattedFileLines([string[]]$fileLines, [int[]]$affected) {
    $useTabs = Get-UsesTabs $fileLines
    $selected = @{}
    foreach ($number in $affected) {
        if ($number -ge 1 -and $number -le $fileLines.Count) { $selected[$number] = $true }
    }
    $updated = New-Object System.Collections.Generic.List[string]
    for ($index = 0; $index -lt $fileLines.Count; $index++) {
        if (-not $selected.ContainsKey($index + 1)) {
            $updated.Add($fileLines[$index])
            continue
        }
        $formatted = Format-ChangedLine $fileLines[$index] $useTabs
        foreach ($piece in $formatted) {
            $updated.Add([string]$piece)
        }
    }
    Write-Output -NoEnumerate $updated.ToArray()
}

if ($MyInvocation.InvocationName -eq '.') { return }

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
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
        $found = Invoke-Git @('diff', '--cached', '--name-only', '--diff-filter=ACMR')
        foreach ($name in $found) { $names.Add([string]$name) }
    } else {
        $found = Invoke-Git @('diff', '--name-only', 'HEAD', '--diff-filter=ACMR')
        foreach ($name in $found) { $names.Add([string]$name) }
        $found = Invoke-Git @('ls-files', '--others', '--exclude-standard')
        foreach ($name in $found) { $names.Add([string]$name) }
    }
    $java = New-Object System.Collections.Generic.List[string]
    foreach ($name in $names) {
        $path = $name.Trim().Replace('\', '/')
        if ($path -match '^src/(main|test)/java/.+\.java$' -and $path -notmatch '/notification/avro/' -and -not $java.Contains($path)) {
            $java.Add($path)
        }
    }
    Write-Output -NoEnumerate $java.ToArray()
}

$paths = Get-JavaPaths -StagedOnly:$PreCommit
if ($null -eq $paths -or $paths.Count -eq 0) {
    Write-Host 'No changed Java files to format.'
    exit 0
}

$failed = $false
foreach ($relative in $paths) {
    $full = Join-Path $repoRoot ($relative.Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $full)) { continue }
    Invoke-Git @('ls-files', '--error-unmatch', '--', $relative) | Out-Null
    $untracked = $script:GitExit -ne 0
    if ($PreCommit) {
        $unstaged = Invoke-Git @('diff', '--name-only', '--', $relative)
        if ($unstaged.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$unstaged[0])) {
            Write-Host "$relative has edits that are not staged. Stage the file, then commit again."
            $failed = $true
            continue
        }
    }

    $raw = [System.IO.File]::ReadAllText($full)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalized = $raw.Replace("`r`n", "`n").Replace("`r", "`n")
    $hasFinalNewline = $normalized.EndsWith("`n")
    $body = $normalized.TrimEnd("`n")
    $fileLines = @()
    if ($body.Length -gt 0) { $fileLines = @($body -split "`n", -1) }

    if ($untracked) {
        if ($fileLines.Count -eq 0) { continue }
        $affected = [int[]](1..$fileLines.Count)
    } else {
        $diffArgs = @('diff', '-U0', '--', $relative)
        if ($PreCommit) { $diffArgs = @('diff', '--cached', '-U0', '--', $relative) }
        $diffLines = Invoke-Git $diffArgs
        $affected = Get-AffectedLineNumbers (($diffLines | ForEach-Object { [string]$_ }) -join "`n")
    }
    if ($null -eq $affected -or $affected.Count -eq 0) { continue }

    $updated = Get-FormattedFileLines $fileLines $affected
    if ($updated -is [string]) { $updated = @($updated) }
    $rebuilt = [string]::Join($newline, [string[]]$updated)
    if ($hasFinalNewline) { $rebuilt += $newline }
    if ([string]::Equals($rebuilt, $raw, [StringComparison]::Ordinal)) { continue }

    $failed = $true
    Write-Host $relative
    $shown = 0
    $useTabs = Get-UsesTabs $fileLines
    for ($index = 0; $index -lt $fileLines.Count; $index++) {
        if ($affected -notcontains ($index + 1)) { continue }
        $formatted = Format-ChangedLine $fileLines[$index] $useTabs
        $oldLine = $fileLines[$index]
        $same = $formatted.Count -eq 1 -and [string]::Equals([string]$formatted[0], $oldLine, [StringComparison]::Ordinal)
        if ($same) { continue }
        if ($shown -ge 8) { Write-Host '  ...'; break }
        Write-Host ("  - {0}" -f (Show-TrailingWhitespace $oldLine))
        foreach ($piece in $formatted) {
            Write-Host ("  + {0}" -f (Show-TrailingWhitespace ([string]$piece)))
        }
        $shown++
    }
    if ($Mode -eq 'apply') {
        $utf8 = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($full, $rebuilt, $utf8)
        Write-Host '  applied'
    }
}

if ($failed -and $Mode -eq 'check') { exit 1 }
exit 0
