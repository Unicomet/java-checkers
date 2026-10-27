# SpotBugs

SpotBugs compiles the project and fails when a selected class matches a bug pattern. A pre-commit run analyzes staged Java files and their nested classes, and it ignores an unstaged Java file with the same bug. A full run sees that unstaged file. The project build files stay unchanged.

## Sub-features

- `spotbugs-staged` fails on a staged nested class that compares strings with `==`.
- `spotbugs-unstaged-ignored` leaves an unstaged copy of that bug out of the pre-commit report.
- `spotbugs-full` fails the full run when the unstaged bug is still present.
- `spotbugs-gradle` writes the Gradle report for the same staged nested class.

## How to get to it (user POV)

- `./.local/quality/run -Tool spotbugs`
- `./.local/quality/run -Tool spotbugs -PreCommit`
- `git commit`, which includes SpotBugs after formatting and Checkstyle
- On Gradle the same commands print `Running Gradle qualitySpotbugs`

## Driving it with verify-java-checkers

Preconditions:

- Launch and the baseline doctor in [README.md](./README.md) succeeded.
- Maven entries need `mvn: present`. The Gradle entry needs `gradle: present` or a `gradlew`. Stop an entry whose tool is absent and report that doctor line.
- Setup from `$CHECKER` has completed and doctor prints `installation: ours`.
- The fixture source is committed only for the classes that should be in `HEAD`. The staged bug is a new staged file. The ignored bug is unstaged.

Project names: `spotbugs maven` and `spotbugs gradle`.

- **Maven project.** Run `verify-java-checkers new-project "spotbugs maven"`. Write the same `pom.xml` as the Checkstyle Maven project (`groupId` `verification`, compiler source and target `17`). Commit it, then run `verify-java-checkers record "spotbugs maven" -- "$CHECKER/setup" "$ROOT/projects/spotbugs maven"`.
- **Stage one nested bug.** Write `src/main/java/verification/Staged.java`:

```java
package verification;

public final class Staged {
  public static final class Nested {
    public static boolean broken(String value) { return value == "bad"; }
  }
}
```

Write `src/main/java/verification/Unstaged.java` with `Unstaged` in place of `Staged` and the same `value == "bad"` comparison. Stage only `Staged.java`. Run `verify-java-checkers record "spotbugs maven" -- ./.local/quality/run -Tool spotbugs -PreCommit`. The exit code is non-zero. Stdout contains `Running spotbugs:check` and `FAILED: SpotBugs`. `target/spotbugsXml.xml` exists. Its `BugInstance` class names are `verification.Staged$Nested` and do not include `verification.Unstaged`. Copy the report to `$EVIDENCE/spotbugs maven/spotbugsXml.xml`. `pom.xml` is unchanged and `.quality-pom.xml` is gone.
- **Fix the staged bug.** Replace `value == "bad"` with `"bad".equals(value)` in `Staged.java`, stage that file, and leave `Unstaged.java` unstaged. Run the same `-Tool spotbugs -PreCommit` command. Exit `0`. Stdout contains `PASSED: SpotBugs`. The `BugInstance` class names do not include `verification.Unstaged`.
- **Full run.** Run `verify-java-checkers record "spotbugs maven" -- ./.local/quality/run -Tool spotbugs`. The exit code is non-zero while `Unstaged.java` still contains `value == "bad"`. The report includes `verification.Unstaged`.
- **Gradle report.** On a project created from `examples/gradle` with a generated wrapper, use package `demo` and the same nested class. Run `verify-java-checkers record "spotbugs gradle" -- ./.local/quality/run -Tool spotbugs -PreCommit`. The exit code is non-zero. `build/reports/local-quality/spotbugs.xml` lists `demo.Staged$Nested` and does not list the unstaged class. `build.gradle` and `settings.gradle` are unchanged.

## Gotchas

- SpotBugs compiles the project. The first run downloads dependencies and needs network access. Maven still compiles every file under the source root, so an unstaged `.java` file is compiled even when `-PreCommit` will not report it.
- The string comparison is also a Checkstyle violation when Checkstyle runs. `-Tool spotbugs` does not run Checkstyle. `git commit` runs both. The finding type for `value == "bad"` on a parameter is `ES_COMPARING_PARAMETER_STRING_WITH_EQ`.
- Pre-commit selection includes the nested class. The report name uses `$`, as in `verification.Staged$Nested`. Judge that by the `BugInstance` class name. `ClassStats` can still name `verification.Unstaged` with `bugs='0'`.
- An untracked file is invisible to `-PreCommit` and visible to a full run. Delete it before expecting a full run to pass.
- The installed `spotbugs-exclude.xml` filters `EI_EXPOSE_REP2` only. The string comparison above is not filtered. A filter added only in the checkout after launch is not in the installation.
- A pre-commit run drops paths containing `/notification/avro/`. A full Maven SpotBugs run does not. Gradle `qualitySpotbugs` skips those paths for both a full run and a pre-commit run.
- Gradle takes precedence over Maven when both build files exist. The Gradle report path is `build/reports/local-quality/spotbugs.xml`, not `target/spotbugsXml.xml`.
