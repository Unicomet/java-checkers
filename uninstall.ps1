# Remove the local checker installation from a project.
param(
    [Parameter(Position = 0)]
    [string]$Project
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Project)) {
    $Project = Join-Path $PSScriptRoot '../..'
}
$Project = (Resolve-Path -LiteralPath $Project).Path
if (-not (Test-Path -LiteralPath (Join-Path $Project '.git'))) {
    throw "Not a git repository: $Project"
}
$hooks = git -C $Project rev-parse --path-format=absolute --git-path hooks
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Git hooks directory.' }
$exclude = git -C $Project rev-parse --path-format=absolute --git-path info/exclude
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve Git exclude file.' }
$installation = Join-Path $Project '.local/quality'
if ((Test-Path -LiteralPath $installation) -and
    (-not (Test-Path -LiteralPath (Join-Path $installation 'run.ps1')) -or
     -not (Test-Path -LiteralPath (Join-Path $installation 'hook/pre-commit')))) {
    throw "Refusing to remove an unrecognized directory: $installation"
}
$hook = Join-Path $hooks 'pre-commit'
$template = Join-Path $PSScriptRoot 'hook/pre-commit'
if (Test-Path -LiteralPath $hook) {
    $current = [System.IO.File]::ReadAllText($hook) -replace "`r`n", "`n"
    $expected = [System.IO.File]::ReadAllText($template) -replace "`r`n", "`n"
    if ($current -eq $expected) {
        Remove-Item -LiteralPath $hook
        Write-Host 'Removed the checker pre-commit hook.'
    } else {
        Write-Host "Preserved an unrelated or modified pre-commit hook: $hook"
    }
}
if (Test-Path -LiteralPath $installation) {
    Remove-Item -LiteralPath $installation -Recurse -Force
    Write-Host "Removed $installation"
}
$local = Join-Path $Project '.local'
if ((Test-Path -LiteralPath $local) -and
    @(Get-ChildItem -LiteralPath $local -Force).Count -eq 0) {
    Remove-Item -LiteralPath $local -Force
}
# Keep .local ignored when it still contains other tools or files.
if (-not (Test-Path -LiteralPath $local) -and (Test-Path -LiteralPath $exclude)) {
    $text = [System.IO.File]::ReadAllText($exclude)
    $text = [regex]::Replace($text, '(?m)^[ \t]*\.local/?[ \t]*(?:\r?\n|$)', '')
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($exclude, $text, $utf8)
}
Write-Host 'Local checker uninstall complete.'
