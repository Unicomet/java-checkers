# Structural rules repeated across the Java projects. Checkstyle does not see file paths.
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'
$main = Join-Path $RepoRoot 'src/main/java'
if (-not (Test-Path -LiteralPath $main)) {
    exit 0
}

$files = @(Get-ChildItem -LiteralPath $main -Recurse -File -Filter '*.java' |
    Where-Object { $_.FullName -notmatch '[\\/]avro[\\/]' })

$interfaces = @{}
foreach ($file in $files) {
    if ($file.Name -like 'I*.java') {
        $interfaces[$file.Name] = $true
    }
}

$failed = $false
foreach ($file in $files) {
    $relative = $file.FullName.Substring($main.Length).Replace('\', '/')
    $name = $file.Name
    $text = [System.IO.File]::ReadAllText($file.FullName)

    if ($name -like '*Exception.java' -and $relative -notmatch '/commons/exceptions/') {
        Write-Host "Put $name in commons/exceptions: $relative"
        $failed = $true
    }
    if ($name -like '*Properties.java' -and $relative -notmatch '/config/properties/') {
        Write-Host "Put $name in config/properties: $relative"
        $failed = $true
    }
    if ([regex]::IsMatch($text, 'new\s+\w+(Service|Repository|Controller|Client)\s*\(')) {
        Write-Host "Inject the dependency. Do not construct it with new: $relative"
        $failed = $true
    }
    $isEnum = [regex]::IsMatch($text, '\benum\s+\w+')
    $hasTrivialAccessor = [regex]::IsMatch($text, 'public\s+void\s+set[A-Z]\w*\s*\([^)]*\)\s*\{\s*this\.\w+\s*=') -or
        [regex]::IsMatch($text, 'public\s+[\w.<>,\[\]]+\s+get[A-Z]\w*\s*\(\s*\)\s*\{\s*return\s+(?:this\.)?\w+\s*;')
    if (-not $isEnum -and $text -notmatch 'lombok' -and $hasTrivialAccessor) {
        Write-Host "Use Lombok instead of a trivial getter or setter: $relative"
        $failed = $true
    }
    if ($name -like '*Service.java' -and $name -notlike 'I*') {
        $type = $name.Substring(0, $name.Length - 5)
        if ($text -match ('class\s+' + [regex]::Escape($type) + '\b') -and -not $interfaces.ContainsKey('I' + $type + '.java')) {
            Write-Host "Add I$type for $name. Services have an interface."
            $failed = $true
        }
    }
}

if ($failed) { exit 1 }
exit 0
