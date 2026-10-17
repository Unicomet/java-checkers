# Fail when src/test contains a SQL fixture. Checkstyle only reads Java files.
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path $RepoRoot 'src/test'
if (-not (Test-Path -LiteralPath $testRoot)) {
    exit 0
}

$found = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.sql')
if ($found.Count -eq 0) {
    exit 0
}

Write-Host 'Do not load a SQL file from a test.'
foreach ($file in $found) {
    Write-Host $file.FullName
}
exit 1
