# Proves the repeated-thread rules fail on the old mistakes and pass on a clean file.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$checkstyle = Join-Path ([System.IO.Path]::GetTempPath()) 'checkstyle-12.3.1-all.jar'
$config = Join-Path $root 'checkstyle.xml'
if (-not (Test-Path -LiteralPath $checkstyle)) {
    $url = 'https://github.com/checkstyle/checkstyle/releases/download/checkstyle-12.3.1/checkstyle-12.3.1-all.jar'
    Write-Host "Downloading checkstyle"
    Invoke-WebRequest -Uri $url -OutFile $checkstyle
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("rules-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $work 'src/test/java') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $work 'src/main/java') -Force | Out-Null

function Write-Java([string]$relative, [string]$text) {
    $path = Join-Path $work $relative
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n"), $utf8)
    return $path
}

function Assert-Checkstyle([string]$name, [string]$path, [string]$needle, [bool]$shouldFail) {
    $output = & java -jar $checkstyle -c $config $path 2>&1 | Out-String
    $failed = $LASTEXITCODE -ne 0
    $hasNeedle = $output.Contains($needle)
    if ($shouldFail -and $hasNeedle) {
        Write-Host "PASS $name"
        return
    }
    if (-not $shouldFail -and -not $hasNeedle) {
        Write-Host "PASS $name"
        return
    }
    Write-Host "FAIL $name exit=$LASTEXITCODE"
    Write-Host $output
    exit 1
}

$h2 = @'
class H2Bad {
    String url = "jdbc:h2:mem:test";
    String driver = "org.h2.Driver";
}
'@
$sql = @'
import org.springframework.test.context.jdbc.Sql;
class SqlBad {
    @Sql(scripts = "schema.sql")
    void load() {}
}
'@
$db = @'
import org.springframework.boot.test.context.SpringBootTest;
@SpringBootTest(properties = {"reports.datasource.url=jdbc:oracle:thin:@localhost:1521/XEPDB1"})
class DbBad {}
'@
$curp = @'
class CurpBad {
    void logIt(org.slf4j.Logger log, String curp) {
        log.info("search curp={}", curp);
    }
}
'@
$clean = @'
class Clean {
    void logIt(org.slf4j.Logger log, String requestId) {
        log.info("search requestId={}", requestId);
    }
}
'@
$mainJdbc = @'
class MainConfig {
    String url = "jdbc:oracle:thin:@localhost:1521/XEPDB1";
}
'@

Assert-Checkstyle 'h2 fails' (Write-Java 'src/test/java/H2Bad.java' $h2) 'Do not use H2' $true
Assert-Checkstyle 'sql annotation fails' (Write-Java 'src/test/java/SqlBad.java' $sql) 'Do not load a SQL file' $true
Assert-Checkstyle 'spring boot jdbc fails' (Write-Java 'src/test/java/DbBad.java' $db) 'Do not boot a database' $true
Assert-Checkstyle 'curp log fails' (Write-Java 'src/main/java/CurpBad.java' $curp) 'Do not log CURP' $true
Assert-Checkstyle 'clean log passes' (Write-Java 'src/main/java/Clean.java' $clean) 'Do not log CURP' $false
Assert-Checkstyle 'main jdbc url passes h2 rule' (Write-Java 'src/main/java/MainConfig.java' $mainJdbc) 'Do not use H2' $false
Assert-Checkstyle 'main jdbc url is not a test database boot' (Write-Java 'src/main/java/MainConfig.java' $mainJdbc) 'Do not boot a database' $false

# Real past mistake from search-batch.
$past = '/home/memo-pc-linux/Projects/mx-pri-pui-search-batch/src/test/java/mx/com/cardif/pui/search/integration/H2IntegrationTestSupport.java'
if (Test-Path -LiteralPath $past) {
    Assert-Checkstyle 'past H2 support fails' $past 'Do not use H2' $true
}

$sqlRepo = Join-Path $work 'sql-repo'
New-Item -ItemType Directory -Path (Join-Path $sqlRepo 'src/test/resources') -Force | Out-Null
Set-Content -Path (Join-Path $sqlRepo 'src/test/resources/schema.sql') -Value 'select 1 from dual;'
& (Join-Path $root 'lint-tests.ps1') -RepoRoot $sqlRepo
if ($LASTEXITCODE -eq 0) {
    Write-Host 'FAIL sql fixture was allowed'
    exit 1
}
Write-Host 'PASS sql fixture fails'

$cleanRepo = Join-Path $work 'clean-repo'
New-Item -ItemType Directory -Path (Join-Path $cleanRepo 'src/test/java') -Force | Out-Null
& (Join-Path $root 'lint-tests.ps1') -RepoRoot $cleanRepo
if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL clean test tree'
    exit 1
}
Write-Host 'PASS clean test tree'

$date = @'
import java.util.Date;
class DateBad {}
'@
$dateOk = @'
import java.util.Date; // NOSONAR: JJWT boundary
class DateOk {}
'@
$security = @'
import org.springframework.security.core.context.SecurityContextHolder;
class SecurityBad {}
'@
$stdout = @'
class OutBad {
    void run() { System.out.println("id"); }
}
'@
Assert-Checkstyle 'util date fails' (Write-Java 'src/main/java/DateBad.java' $date) 'Do not use java.util.Date' $true
Assert-Checkstyle 'nosonar date passes' (Write-Java 'src/main/java/DateOk.java' $dateOk) 'Do not use java.util.Date' $false
Assert-Checkstyle 'spring security fails' (Write-Java 'src/main/java/SecurityBad.java' $security) 'Do not add Spring Security' $true
Assert-Checkstyle 'system out fails' (Write-Java 'src/main/java/OutBad.java' $stdout) 'Use the logger' $true

$jwt = '/home/memo-pc-linux/Projects/mx-pri-pui-report-service/src/main/java/mx/com/cardif/pui/reports/service/impl/JwtService.java'
if (Test-Path -LiteralPath $jwt) {
    Assert-Checkstyle 'jjwt date boundary passes' $jwt 'Do not use java.util.Date' $false
}
$stdoutReal = '/home/memo-pc-linux/Projects/mx-pri-pui-report-service/src/main/java/mx/com/cardif/pui/reports/service/impl/ReportService.java'
if (Test-Path -LiteralPath $stdoutReal) {
    Assert-Checkstyle 'past system out fails' $stdoutReal 'Use the logger' $true
}

$structure = Join-Path $work 'structure'
$badMain = Join-Path $structure 'src/main/java/mx/com/cardif/pui/reports/service'
$goodMain = Join-Path $structure 'src/main/java/mx/com/cardif/pui/reports/commons/exceptions'
$propBad = Join-Path $structure 'src/main/java/mx/com/cardif/pui/reports/config'
$propGood = Join-Path $structure 'src/main/java/mx/com/cardif/pui/reports/config/properties'
New-Item -ItemType Directory -Path $badMain, $goodMain, $propBad, $propGood -Force | Out-Null
Set-Content (Join-Path $badMain 'ReportListException.java') 'public class ReportListException extends RuntimeException {}'
Set-Content (Join-Path $goodMain 'OkException.java') 'public class OkException extends RuntimeException {}'
Set-Content (Join-Path $propBad 'NotificationProperties.java') 'public class NotificationProperties {}'
Set-Content (Join-Path $propGood 'JobProperties.java') 'import lombok.Getter; public class JobProperties {}'
Set-Content (Join-Path $badMain 'ReportService.java') @'
public class ReportService {
    public ReportService() { new HelperService(); }
    public String getName() { return name; }
    private String name;
}
'@
Set-Content (Join-Path $badMain 'INotTheRightName.java') 'public interface INotTheRightName {}'
& (Join-Path $root 'lint-main.ps1') -RepoRoot $structure
if ($LASTEXITCODE -eq 0) {
    Write-Host 'FAIL structure rules allowed the bad tree'
    exit 1
}
Write-Host 'PASS structure rules fail the bad tree'

$onlyGood = Join-Path $work 'structure-good'
$g1 = Join-Path $onlyGood 'src/main/java/mx/com/cardif/pui/reports/commons/exceptions'
$g2 = Join-Path $onlyGood 'src/main/java/mx/com/cardif/pui/reports/config/properties'
$g3 = Join-Path $onlyGood 'src/main/java/mx/com/cardif/pui/reports/service'
New-Item -ItemType Directory -Path $g1, $g2, $g3 -Force | Out-Null
Set-Content (Join-Path $g1 'OkException.java') 'public class OkException extends RuntimeException {}'
Set-Content (Join-Path $g2 'JobProperties.java') 'import lombok.Getter; @Getter public class JobProperties { private String name; }'
Set-Content (Join-Path $g3 'IReportService.java') 'public interface IReportService {}'
Set-Content (Join-Path $g3 'ReportService.java') 'public class ReportService implements IReportService {}'
& (Join-Path $root 'lint-main.ps1') -RepoRoot $onlyGood
if ($LASTEXITCODE -ne 0) {
    Write-Host 'FAIL clean structure tree'
    exit 1
}
Write-Host 'PASS clean structure tree'

Remove-Item -LiteralPath $work -Recurse -Force
Write-Host 'All repeated-rule checks passed.'
exit 0
