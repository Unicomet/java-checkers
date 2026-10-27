# Checkstyle

Checkstyle reads `.local/quality/checkstyle.xml` and fails the run when a selected Java file violates it. A full run checks the project's Java sources except paths containing `/notification/avro/`. A pre-commit run checks staged files under `src/main/java` and `src/test/java`, skips that same avro path, and ignores other Java files. On a non-Gradle project the staged path is at the repository root. Gradle also accepts it under a subproject. The project's `pom.xml` or Gradle build files stay unchanged.

## Sub-features

- `checkstyle-maven` runs Checkstyle through Maven on the whole project.
- `checkstyle-staged` fails on a staged `BAD_NAME` method and ignores an unstaged violation.
- `checkstyle-gradle` runs the same staged check through `qualityCheckstyle`.
- `checkstyle-clean` passes the example source that already satisfies the config.

## How to get to it (user POV)

- `./.local/quality/run -Tool checkstyle`
- `./.local/quality/run -Tool checkstyle -PreCommit`
- `git commit`, which includes Checkstyle after formatting
- On a Gradle project the same commands print `Running Gradle qualityCheckstyle` instead of `Running checkstyle:check`

## Driving it with verify-java-checkers

Preconditions:

- Launch and the baseline doctor in [README.md](./README.md) succeeded.
- The Maven entries need doctor output `mvn: present`. The Gradle entry needs `gradle: present` or an existing `gradlew`. If the required tool is absent, stop that entry and report the doctor line. Do not substitute the other build tool.
- Setup has been run from `$CHECKER` and doctor prints `installation: ours`.

Project names: `checkstyle maven` and `checkstyle gradle`.

- **Maven project.** Run `verify-java-checkers new-project "checkstyle maven"`. Write `pom.xml` with `modelVersion` `4.0.0`, `groupId` `verification`, `artifactId` `staged-check`, `version` `1`, and compiler source and target `17`. Commit `pom.xml` before setup so the hook does not see it as a later surprise. Run `verify-java-checkers record "checkstyle maven" -- "$CHECKER/setup" "$ROOT/projects/checkstyle maven"`. Exit `0`.
- **Clean source.** Write `src/main/java/demo/Example.java` as in `examples/gradle/src/main/java/demo/Example.java` in the checker checkout. Stage and commit it only after setup if the commit should pass the hook; otherwise commit it before setup. Run `verify-java-checkers record "checkstyle maven" -- ./.local/quality/run -Tool checkstyle`. Exit `0`. Stdout contains `Running checkstyle:check` and `PASSED: Checkstyle`. `pom.xml` is unchanged. `.quality-pom.xml` does not exist when the command returns.
- **Staged violation.** After that passing commit, write `src/main/java/demo/Staged.java`:

```java
package demo;

/** Staged checkstyle fixture. */
public final class Staged {
  private Staged() {}

  /** Bad method name. */
  public static void BAD_NAME() {}
}
```

Write `src/main/java/demo/Unstaged.java` with the same text and the type name `Unstaged`. Stage only `Staged.java`. Run `verify-java-checkers record "checkstyle maven" -- ./.local/quality/run -Tool checkstyle -PreCommit`. The exit code is non-zero. Stdout contains `Checking 1 staged Java file(s).`, `Name 'BAD_NAME' must match pattern '^[a-z][a-zA-Z0-9]*$'. [MethodName]`, and `FAILED: Checkstyle`. It does not contain `Unstaged.java`. `pom.xml` is unchanged and `.quality-pom.xml` is gone.
- **Gradle project.** When `gradle: present`, run `verify-java-checkers new-project "checkstyle gradle"`. Copy `examples/gradle` from the checkout into that project, generate the wrapper with `gradle wrapper --gradle-version 8.14.3`, commit the project, run `"$CHECKER/setup"` on it, then repeat the staged `BAD_NAME` fixture under `src/main/java/demo/`. Run `verify-java-checkers record "checkstyle gradle" -- ./.local/quality/run -Tool checkstyle -PreCommit`. Stdout contains `Running Gradle qualityCheckstyle` and `Name 'BAD_NAME' must match pattern '^[a-z][a-zA-Z0-9]*$'. [MethodName]`. The exit code is non-zero. `git diff -- build.gradle settings.gradle` is empty.

## Gotchas

- A Gradle settings or build file makes the runner use Gradle even when `pom.xml` exists.
- A pre-commit run whose only staged Java file is under `/notification/avro/` prints `No staged Java files. Checkstyle, SpotBugs, and the formatter were skipped.` and exits 0. That is a skip.
- `-PreCommit` with no staged Java file prints `No staged Java files. Checkstyle, SpotBugs, and the formatter were skipped.` and exits `0`. That is a skip.
- A staged file with extra unstaged edits fails before Checkstyle. The message contains `has edits that are not staged`.
- `SKIP_LOCAL_CHECKS=1 git commit` prints `Skipping local Checkstyle, SpotBugs, and formatter.` and does not run Checkstyle.
- Maven uses `.mvn/settings.xml` when that file is present.
- The first run downloads the Checkstyle Maven plugin and needs network access.
- Edits to `.local/quality/checkstyle.xml` in the installed copy change the next run. The launch snapshot does not pick up later edits in the checkout.
