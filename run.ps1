# Formatter, Checkstyle, and SpotBugs for the project two folders above this script.
# The script never edits pom.xml. It writes a throwaway .quality-pom.xml, runs Maven, then deletes it.
param(
    [ValidateSet('check', 'apply')]
    [string]$Mode = 'check',
    [ValidateSet('all', 'format', 'checkstyle', 'spotbugs')]
    [string]$Tool = 'all',
    [switch]$All,
    [switch]$PreCommit
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$qualityPom = Join-Path $repoRoot '.quality-pom.xml'
$marker = "    </plugins>"

function Invoke-Git([string[]]$GitArgs) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& git @GitArgs 2>$null | Where-Object { $_ -is [string] -and $_.Length -gt 0 })
    $script:GitExit = $LASTEXITCODE
    $ErrorActionPreference = $saved
    Write-Output -NoEnumerate $output
}

function Invoke-Maven {
    param([string[]]$MavenArgs)
    $mvnArgs = @('-B')
    if (Test-Path -LiteralPath (Join-Path $repoRoot '.mvn\settings.xml')) {
        $mvnArgs += @('-s', '.mvn/settings.xml')
    }
    $mvnArgs += @('-f', '.quality-pom.xml')
    $mvnArgs += $MavenArgs
    & mvn @mvnArgs
    if ($null -eq $LASTEXITCODE) { $script:MavenExit = 1 } else { $script:MavenExit = $LASTEXITCODE }
}

if ($All) {
    Write-Host 'Google Java Format only edits Git-changed line ranges; -All does not expand its scope.'
}

Set-Location $repoRoot

$javaFiles = @()
$includeTests = 'false'
if ($PreCommit) {
    $javaFiles = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--cached', '--name-only', '--diff-filter=ACMR'))) {
        $path = ([string]$name).Trim().Replace('\', '/')
        if ($path -match '^src/(main|test)/java/.+\.java$' -and $path -notmatch '/notification/avro/') {
            $javaFiles.Add($path)
        }
    }
    if ($javaFiles.Count -eq 0) {
        Write-Host 'No staged Java files. Checkstyle, SpotBugs, and the formatter were skipped.'
        exit 0
    }
    foreach ($path in $javaFiles) {
        $unstaged = Invoke-Git @('diff', '--name-only', '--', $path)
        if ($unstaged.Count -gt 0) {
            throw "$path has edits that are not staged. Stage the file, then commit again."
        }
    }
    if ($javaFiles | Where-Object { $_ -like 'src/test/java/*' }) {
        $includeTests = 'true'
    }
    Write-Host ("Checking {0} staged Java file(s)." -f $javaFiles.Count)
}

$failed = $false
try {
    $runFormat = $Tool -eq 'all' -or $Tool -eq 'format'
    $runCheckstyle = $Tool -eq 'all' -or $Tool -eq 'checkstyle'
    $runSpotbugs = $Tool -eq 'all' -or $Tool -eq 'spotbugs'

    if ($runFormat) {
        Write-Host 'Running Google Java Format on changed lines'
        $formatArgs = @{ Mode = $Mode }
        if ($PreCommit) { $formatArgs.PreCommit = $true }
        & (Join-Path $PSScriptRoot 'format-changed.ps1') @formatArgs
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    if ($runCheckstyle -or $runSpotbugs) {
        $snippet = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'plugins.xml')
        if ($PreCommit) {
            $relativeIncludes = ($javaFiles | ForEach-Object { $_ -replace '^src/(main|test)/java/', '' }) -join ','
            $snippet = $snippet.Replace(
                '<excludes>**/notification/avro/**</excludes>',
                "<includes>$([System.Security.SecurityElement]::Escape($relativeIncludes))</includes>`r`n          <excludes>**/notification/avro/**</excludes>")

            $classNames = ($javaFiles | ForEach-Object {
                $className = $_ -replace '^src/(main|test)/java/', '' -replace '/', '.' -replace '\.java$', ''
                $className
                $className + '$*'
            }) -join ','
            $snippet = $snippet.Replace(
                '<includeTests>false</includeTests>',
                "<includeTests>$includeTests</includeTests>`r`n          <onlyAnalyze>$classNames</onlyAnalyze>")
        }
        $pom = Get-Content -Raw -Path (Join-Path $repoRoot 'pom.xml')
        $index = $pom.LastIndexOf($marker)
        if ($index -lt 0) {
            throw "pom.xml has no '$marker' block to extend."
        }
        $generated = $pom.Substring(0, $index) + $snippet.TrimEnd() + "`r`n" + $pom.Substring($index)
        [System.IO.File]::WriteAllText($qualityPom, $generated)
    }
    if ($runCheckstyle) {
        Write-Host 'Running checkstyle:check'
        Invoke-Maven @('checkstyle:check')
        if ($script:MavenExit -ne 0) { $failed = $true }
    }
    if ($runSpotbugs) {
        $compileGoal = 'compile'
        if ($includeTests -eq 'true') { $compileGoal = 'test-compile' }
        Write-Host 'Running spotbugs:check'
        Invoke-Maven @('-DskipTests', $compileGoal, 'spotbugs:check')
        if ($script:MavenExit -ne 0) { $failed = $true }
    }
}
finally {
    if (Test-Path $qualityPom) {
        Remove-Item -Force $qualityPom
    }
}

if ($failed) {
    if ($PreCommit) {
        Write-Host 'Commit blocked. Stage the fixes and commit again.'
        Write-Host 'To format the changed lines: ./.local/quality/run -Mode apply -PreCommit'
        Write-Host 'To skip once: set SKIP_LOCAL_CHECKS=1 and commit again.'
    }
    exit 1
}
exit 0
