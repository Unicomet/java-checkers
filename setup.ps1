# Clones these checkers into a git project and installs the pre-commit hook.
param(
    [Parameter(Position = 0)]
    [string]$Project,
    [string]$Branch
)

$ErrorActionPreference = 'Stop'
$checkerRoot = $PSScriptRoot

function Same-Path([string]$Left, [string]$Right) {
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    $a = $Left.TrimEnd('\', '/')
    $b = $Right.TrimEnd('\', '/')
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
}

function Get-OriginUrl {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $url = git -C $checkerRoot remote get-url origin 2>$null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $saved
    if ($code -ne 0) { return '' }
    return ([string]$url).Trim()
}

function Copy-CheckerFiles([string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $names = @(
        'run', 'run.ps1', 'run.cmd', 'setup', 'setup.ps1', 'setup.cmd', 'format-changed.ps1',
        'plugins.xml', 'quality.init.gradle', 'checkstyle.xml', 'spotbugs-exclude.xml', 'README.md', '.gitattributes'
    )
    foreach ($name in $names) {
        Copy-Item -LiteralPath (Join-Path $checkerRoot $name) -Destination (Join-Path $Destination $name)
    }
    $hookDir = Join-Path $Destination 'hook'
    New-Item -ItemType Directory -Force -Path $hookDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $checkerRoot 'hook\pre-commit') -Destination (Join-Path $hookDir 'pre-commit')
}

function Install-Checkers([string]$Destination, [string]$OriginUrl) {
    $parent = Split-Path $Destination
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    if ($OriginUrl) {
        $cloneArgs = @('clone', $OriginUrl, $Destination)
        if ($Branch) { $cloneArgs = @('clone', '--branch', $Branch, $OriginUrl, $Destination) }
        & git @cloneArgs
        if ($LASTEXITCODE -ne 0) { throw 'git clone failed.' }
        Write-Host "Cloned the checkers into $Destination"
        return
    }
    Copy-CheckerFiles $Destination
    Write-Host "Copied the checkers into $Destination"
    Write-Host 'This checkout has no origin remote, so the copy has no git history.'
}

function Add-LocalExclude([string]$ProjectRoot) {
    $exclude = git -C $ProjectRoot rev-parse --path-format=absolute --git-path info/exclude
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Git exclude file.' }
    New-Item -ItemType Directory -Force -Path (Split-Path $exclude) | Out-Null
    $text = ''
    if (Test-Path -LiteralPath $exclude) {
        $text = [System.IO.File]::ReadAllText($exclude)
    }
    foreach ($line in @($text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -eq '.local/' -or $trimmed -eq '.local') {
            Write-Host '.git/info/exclude already ignores .local/.'
            return
        }
    }
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
    $text += ".local/`n"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($exclude, $text, $utf8)
    Write-Host 'Added .local/ to .git/info/exclude.'
}

function Set-HookExecutable([string]$Path) {
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Unix) {
        & chmod +x -- $Path
        if ($LASTEXITCODE -ne 0) { throw "Cannot make hook executable: $Path" }
    }
}

function Install-Hook([string]$ProjectRoot, [string]$HookSource) {
    if (-not (Test-Path -LiteralPath $HookSource)) {
        throw "Hook template is missing: $HookSource"
    }
    $hooks = git -C $ProjectRoot rev-parse --path-format=absolute --git-path hooks
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Git hooks directory.' }
    New-Item -ItemType Directory -Force -Path $hooks | Out-Null
    $destination = Join-Path $hooks 'pre-commit'
    $text = [System.IO.File]::ReadAllText($HookSource) -replace "`r`n", "`n" -replace "`r", "`n"
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    if (Test-Path -LiteralPath $destination) {
        $current = [System.IO.File]::ReadAllText($destination) -replace "`r`n", "`n" -replace "`r", "`n"
        if ($current -eq $text) {
            Set-HookExecutable $destination
            Write-Host 'Pre-commit hook is already installed.'
            return
        }
        if ($current -match '\.local/quality/run\.(cmd|ps1)') {
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($destination, $text, $utf8)
            Set-HookExecutable $destination
            Write-Host 'Updated the pre-commit hook.'
            return
        }
        throw "A pre-commit hook already exists and was left unchanged: $destination"
    }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($destination, $text, $utf8)
    Set-HookExecutable $destination
    Write-Host 'Installed the pre-commit hook. It runs the formatter, Checkstyle, and SpotBugs.'
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    $maybe = (Resolve-Path (Join-Path $checkerRoot '..\..')).Path
    if (Test-Path -LiteralPath (Join-Path $maybe '.git')) {
        $Project = $maybe
    } else {
        throw 'Pass the project path. Example: .\setup.cmd C:\path\to\project'
    }
} else {
    if (-not (Test-Path -LiteralPath $Project)) { throw "Project path does not exist: $Project" }
    $Project = (Resolve-Path -LiteralPath $Project).Path
}

if (-not (Test-Path -LiteralPath (Join-Path $Project '.git'))) {
    throw "Not a git repository: $Project"
}

$dest = Join-Path $Project '.local\quality'
$checkerFull = (Resolve-Path -LiteralPath $checkerRoot).Path
$destFull = ''
if (Test-Path -LiteralPath $dest) { $destFull = (Resolve-Path -LiteralPath $dest).Path }

if (Same-Path $destFull $checkerFull) {
    Write-Host 'Checkers are already in this project.'
} elseif ($destFull -and (Test-Path -LiteralPath (Join-Path $dest 'run.ps1'))) {
    Write-Host 'Checkers are already installed.'
} elseif ($destFull) {
    throw "Refusing to overwrite $dest"
} else {
    Install-Checkers $dest (Get-OriginUrl)
}

Install-Hook $Project (Join-Path $dest 'hook\pre-commit')
Add-LocalExclude $Project
Write-Host 'From the project root, run ./.local/quality/run (Windows: .\.local\quality\run.cmd)'
Write-Host 'The pre-commit hook runs the formatter, Checkstyle, and SpotBugs on staged Java files.'
exit 0
