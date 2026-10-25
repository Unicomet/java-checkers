# Formatter, Checkstyle, and SpotBugs for the project two folders above this script.
# Build files stay unchanged: Maven uses a temporary POM; Gradle uses an init script.
param(
    [ValidateSet('check', 'apply')]
    [string]$Mode = 'check',
    [ValidateSet('all', 'format', 'checkstyle', 'spotbugs')]
    [string]$Tool = 'all',
    [switch]$All,
    [switch]$PreCommit
)

$ErrorActionPreference = 'Stop'
trap {
    [Console]::Error.WriteLine('Runner error: ' + $_.Exception.ToString())
    [Console]::Error.WriteLine($_.InvocationInfo.PositionMessage)
    [Console]::Error.WriteLine($_.ScriptStackTrace)
    exit 1
}
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$qualityPom = Join-Path $repoRoot '.quality-pom.xml'
$failures = New-Object System.Collections.Generic.List[object]

function Invoke-QualityCheck([string]$Name, [scriptblock]$Action) {
    $lines = New-Object System.Collections.Generic.List[string]
    $script:CheckExit = 1
    try {
        & $Action *>&1 | ForEach-Object {
            $line = $_.ToString()
            $lines.Add($line)
            Write-Host $line
        }
    }
    catch {
        $script:CheckExit = 1
        $errorRecord = $_
        $details = @($errorRecord.ToString(), $errorRecord.InvocationInfo.PositionMessage,
            $errorRecord.Exception.ToString(), $errorRecord.ScriptStackTrace) -join "`n"
        $lines.Add($details)
        Write-Host $details
    }
    if ($script:CheckExit -ne 0) {
        $failures.Add([pscustomobject]@{ Name = $Name; ExitCode = $script:CheckExit; Output = $lines })
        Write-Host "FAILED: $Name (exit code $script:CheckExit)"
    } else {
        Write-Host "PASSED: $Name"
    }
}

function Invoke-Git([string[]]$GitArgs) {
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& git @GitArgs 2>$null | Where-Object { $_ -is [string] -and $_.Length -gt 0 })
    $script:GitExit = $LASTEXITCODE
    $ErrorActionPreference = $saved
    Write-Output -NoEnumerate $output
}

function Invoke-Gradle([string]$Task) {
    $windows = [Environment]::OSVersion.Platform -ne [PlatformID]::Unix
    $wrapper = if ($windows) { 'gradlew.bat' } else { 'gradlew' }
    $command = 'gradle'
    if (Test-Path -LiteralPath (Join-Path $repoRoot $wrapper)) {
        $command = Join-Path $repoRoot $wrapper
    }
    $gradleArgs = @('--no-daemon', '--console=plain', '--no-configuration-cache', '--stacktrace',
        '--init-script', (Join-Path $PSScriptRoot 'quality.init.gradle'),
        "-PqualityRoot=$PSScriptRoot", "-PqualityPreCommit=$($PreCommit.IsPresent.ToString().ToLowerInvariant())",
        "-PqualityFiles=$($javaFiles -join ',')", $Task)
    # Windows PowerShell can wrap native stderr as ErrorRecords; preserve it as diagnostics.
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    & $command @gradleArgs
    if ($null -eq $LASTEXITCODE) { $script:CheckExit = 1 } else { $script:CheckExit = $LASTEXITCODE }
}

function Invoke-Maven {
    param([string[]]$MavenArgs)
    $mvnArgs = @('-B', '-e')
    if (Test-Path -LiteralPath (Join-Path $repoRoot '.mvn\settings.xml')) {
        $mvnArgs += @('-s', '.mvn/settings.xml')
    }
    $mvnArgs += @('-f', '.quality-pom.xml')
    $mvnArgs += $MavenArgs
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    & mvn @mvnArgs
    if ($null -eq $LASTEXITCODE) { $script:CheckExit = 1 } else { $script:CheckExit = $LASTEXITCODE }
}

if ($All) {
    Write-Host 'Google Java Format only edits Git-changed line ranges; -All does not expand its scope.'
}

Set-Location $repoRoot

$isGradle = (Test-Path -LiteralPath (Join-Path $repoRoot 'build.gradle')) -or
    (Test-Path -LiteralPath (Join-Path $repoRoot 'build.gradle.kts')) -or
    (Test-Path -LiteralPath (Join-Path $repoRoot 'settings.gradle')) -or
    (Test-Path -LiteralPath (Join-Path $repoRoot 'settings.gradle.kts'))

$javaFiles = @()
$includeTests = 'false'
if ($PreCommit) {
    $javaFiles = New-Object System.Collections.Generic.List[string]
    foreach ($name in (Invoke-Git @('-c', 'core.quotepath=false', 'diff', '--cached', '--name-only', '--diff-filter=ACMR'))) {
        $path = ([string]$name).Trim().Replace('\', '/')
        if (($path -match '^src/(main|test)/java/.+\.java$' -or ($isGradle -and $path -match '^(?:.+/)?src/(main|test)/java/.+\.java$')) -and $path -notmatch '/notification/avro/') {
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

try {
    $runFormat = $Tool -eq 'all' -or $Tool -eq 'format'
    $runCheckstyle = $Tool -eq 'all' -or $Tool -eq 'checkstyle'
    $runSpotbugs = $Tool -eq 'all' -or $Tool -eq 'spotbugs'

    if ($runFormat) {
        Write-Host 'Running Google Java Format on changed lines'
        $formatArgs = @{ Mode = $Mode }
        if ($PreCommit) { $formatArgs.PreCommit = $true }
        Invoke-QualityCheck 'Google Java Format' {
            & (Join-Path $PSScriptRoot 'format-changed.ps1') @formatArgs
            $script:CheckExit = $LASTEXITCODE
        }
    }
    if (($runCheckstyle -or $runSpotbugs) -and -not $isGradle) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'pom.xml'))) {
            throw 'No Maven pom.xml or Gradle build/settings file found in the project root.'
        }
        $snippet = Get-Content -Raw -Path (Join-Path $PSScriptRoot 'plugins.xml')
        if ($PreCommit) {
            $relativeIncludes = ($javaFiles | ForEach-Object { $_ -replace '^src/(main|test)/java/', '' }) -join ','
            $snippet = $snippet.Replace(
                '<excludes>**/notification/avro/**</excludes>',
                "<includes>$([System.Security.SecurityElement]::Escape($relativeIncludes))</includes>`r`n          <excludes>**/notification/avro/**</excludes>")

            $classNames = ($javaFiles | ForEach-Object {
                $className = $_ -replace '^src/(main|test)/java/', '' -replace '/', '.' -replace '\.java$', ''
                $className
                # SpotBugs uses a regex here: $* repeats the dollar sign, not the class suffix.
                $className + '$[^/]*'
            }) -join ','
            $snippet = $snippet.Replace(
                '<includeTests>false</includeTests>',
                "<includeTests>$includeTests</includeTests>`r`n          <onlyAnalyze>$classNames</onlyAnalyze>")
        }
        $pom = Get-Content -Raw -Path (Join-Path $repoRoot 'pom.xml')
        $document = New-Object System.Xml.XmlDocument
        $document.PreserveWhitespace = $true
        $document.LoadXml($pom)
        $project = $document.DocumentElement
        $namespace = $project.NamespaceURI
        $build = $project.SelectSingleNode("*[local-name()='build']")
        if ($null -eq $build) {
            $build = $document.CreateElement('build', $namespace)
            [void]$project.AppendChild($build)
        }
        $plugins = $build.SelectSingleNode("*[local-name()='plugins']")
        if ($null -eq $plugins) {
            $plugins = $document.CreateElement('plugins', $namespace)
            [void]$build.AppendChild($plugins)
        }
        $additions = New-Object System.Xml.XmlDocument
        $additions.LoadXml("<plugins xmlns='$namespace'>$snippet</plugins>")
        foreach ($plugin in $additions.DocumentElement.ChildNodes) {
            [void]$plugins.AppendChild($document.ImportNode($plugin, $true))
        }
        $document.Save($qualityPom)
    }
    if ($runCheckstyle) {
        if ($isGradle) {
            Write-Host 'Running Gradle qualityCheckstyle'
            Invoke-QualityCheck 'Checkstyle' { Invoke-Gradle 'qualityCheckstyle' }
        } else {
            Write-Host 'Running checkstyle:check'
            Invoke-QualityCheck 'Checkstyle' { Invoke-Maven @('checkstyle:check') }
        }
    }
    if ($runSpotbugs) {
        $compileGoal = 'compile'
        if ($includeTests -eq 'true') { $compileGoal = 'test-compile' }
        if ($isGradle) {
            Write-Host 'Running Gradle qualitySpotbugs'
            Invoke-QualityCheck 'SpotBugs' { Invoke-Gradle 'qualitySpotbugs' }
        } else {
            Write-Host 'Running spotbugs:check'
            Invoke-QualityCheck 'SpotBugs' { Invoke-Maven @('-DskipTests', $compileGoal, 'spotbugs:check') }
        }
    }
}
finally {
    if (Test-Path $qualityPom) {
        Remove-Item -Force $qualityPom
    }
}

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host ('Failed checks: ' + (($failures | ForEach-Object { $_.Name }) -join ', '))
    foreach ($failure in $failures) {
        Write-Host ("--- {0}: failure details (exit code {1}) ---" -f $failure.Name, $failure.ExitCode)
        foreach ($line in $failure.Output) { Write-Host $line }
    }
    if ($PreCommit) {
        Write-Host 'Commit blocked. Stage the fixes and commit again.'
        if ($failures | Where-Object { $_.Name -eq 'Google Java Format' }) {
            Write-Host 'To format the changed lines: ./.local/quality/run -Tool format -Mode apply -PreCommit'
        }
        Write-Host 'To skip once: set SKIP_LOCAL_CHECKS=1 and commit again.'
    }
    exit 1
}
exit 0
