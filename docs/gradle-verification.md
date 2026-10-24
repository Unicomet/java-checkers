# Gradle setup verification

Verified on 2026-10-24 using Gradle 8.14.3, JDK 17.0.20.1, PowerShell 7.6.7, Google Java Format 1.24.0, Checkstyle 12.3.1, and SpotBugs 4.10.4.

The [checked Gradle commit](https://github.com/Unicomet/java-checkers/commit/ee6d4dbcd4590760a29d1822ff4dcb87cde194ab) is published on `evidence/gradle-checkers`. It changes `Example.java` and adds a nested-class example. The installed pre-commit hook ran Google Java Format, Checkstyle, and SpotBugs successfully before Git created that commit.

[Full command output](gradle-verification.log) includes installation, failed checks, formatting fixes, and the successful commits. Failures in this transcript are intentional assertions in the integration test.

`tests/gradle.Tests.py` creates real Git projects, snapshots the checker source into a local Git origin, and runs `./setup /path/to/project`. This exercises cloning the checkers and installing the executable hook, including a second setup run. It then:

- Generates and uses the Gradle wrapper in a project whose path contains spaces.
- Rejects an unformatted change, applies formatting to the changed lines, and stages the fix.
- Detects a staged nested-class SpotBugs violation while ignoring the same violation in an untracked class.
- Rejects a staged Checkstyle naming violation.
- Fixes the violations and makes a real commit through all three checkers, with no skip flag.
- Confirms a normal SpotBugs run detects the untracked violation.
- Removes that violation and runs all checkers successfully in normal mode.
- Temporarily removes the wrapper to verify fallback to Gradle on PATH.

The test repeats this for a Groovy DSL project and a Kotlin DSL build with Java sources in an `app` subproject. It verifies that lint runs leave the build scripts unchanged.

To reproduce with Gradle on PATH:

```bash
QUALITY_EVIDENCE=/tmp/gradle-verification.log python3 tests/gradle.Tests.py
```

To retain the generated Git projects for inspection, also set `QUALITY_PROJECT_ROOT` to a new, empty directory.

The Maven setup/hook suite, real Maven SpotBugs nested-class regression, changed-line formatter suite, and `git diff --check` also pass.
