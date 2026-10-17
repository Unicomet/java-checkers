# Proves formatting cannot rewrite lines git did not change, even when a formatted line splits.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../format-changed.ps1')

function Assert-Equal([string]$name, [string]$actual, [string]$expected) {
    if ($actual -ne $expected) {
        Write-Host "FAIL $name"
        Write-Host "---- expected ----"
        Write-Host $expected
        Write-Host "---- actual ----"
        Write-Host $actual
        exit 1
    }
    Write-Host "PASS $name"
}

$before = @"
package demo;

public class Sample {
int x=1;
    void changed() {
        System.out.println("hello");
    }
}
"@.Replace("`r`n", "`n")

# GJF-shaped spillover: the untouched statement is rewritten, and the changed line splits.
$after = @"
package demo;

public class Sample {
    int x = 1;
    void changed() {
        System.out.println(
            "hello");
    }
}
"@.Replace("`r`n", "`n")

$limited = Limit-FormatToAffectedLines $before $after @(6)
$expected = @"
package demo;

public class Sample {
int x=1;
    void changed() {
        System.out.println(
            "hello");
    }
}
"@.Replace("`r`n", "`n")
Assert-Equal 'split keeps distant line' $limited $expected

$sameCount = $before.Replace('System.out.println("hello");', 'System.out.println("hello world");')
$limitedSame = Limit-FormatToAffectedLines $before $sameCount @(6)
Assert-Equal 'same count keeps distant line' $limitedSame $sameCount

$inserted = @"
package demo;

public class Sample {
int x=1;
    void changed() {
        System.out.println("hello");
        int added = 1;
    }
}
"@.Replace("`r`n", "`n")
$limitedInsert = Limit-FormatToAffectedLines $before $inserted @(6)
Assert-Equal 'insertion on changed line stays' $limitedInsert $inserted

$distantInsert = @"
package demo;

public class Sample {
int x=1;
    int sneaked = 1;
    void changed() {
        System.out.println("hello");
    }
}
"@.Replace("`r`n", "`n")
$limitedDistant = Limit-FormatToAffectedLines $before $distantInsert @(6)
Assert-Equal 'distant insertion dropped' $limitedDistant $before

$script = Get-Content -Raw -Path (Join-Path $PSScriptRoot '../format-changed.ps1')
if ($script -match 'spotless-maven-plugin|com\.diffplug|googleJavaFormat') {
    Write-Host 'FAIL Spotless is referenced by the formatter'
    exit 1
}
Write-Host 'PASS formatter does not call Spotless'

Write-Host 'All format-range checks passed.'
exit 0
