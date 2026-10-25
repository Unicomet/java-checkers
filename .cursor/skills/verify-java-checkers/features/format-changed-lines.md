# Format changed lines

Format changed lines rewrites only the Java lines that differ from `HEAD`, or the whole file when it is untracked. Lines outside that range stay, including lines the formatter would otherwise change. A standalone apply leaves the Git index alone. A commit formats staged Java and stages those formatting fixes before Checkstyle and SpotBugs run.

## Sub-features

- `format-check` fails when a changed line is not formatted and leaves the file bytes unchanged.
- `format-apply` rewrites the changed line, preserves an unchanged badly spaced line, and leaves the index unchanged.
- `format-none` succeeds when no selected Java file differs from `HEAD`.
- `format-commit` formats and stages during `git commit`, then runs the other checkers.
- `format-untracked` formats a new untracked Java file in full.
- `format-precommit-apply` formats staged lines without staging the result when only the format tool is requested.

## How to get to it (user POV)

- `./.local/quality/run -Tool format -Mode check`
- `./.local/quality/run -Tool format -Mode apply`
- `./.local/quality/run -Tool format -Mode apply -PreCommit`
- `git commit` after staging a Java change, which runs `.local/quality/run.ps1 -PreCommit`
- `./.local/quality/run -PreCommit` for the same full pre-commit sequence

On Windows the launcher is `.local\quality\run.cmd` with the same arguments.

## Driving it with verify-java-checkers

Preconditions:

- Launch and the baseline doctor in [README.md](./README.md) succeeded.
- `java` reports major 17 or newer.
- The first apply downloads `google-java-format-1.24.0-all-deps.jar` into the project's `.local/quality/tools/` when that jar is absent. That download needs network access.

Project name: `format-changed-lines`. `$PROJECT` is `$ROOT/projects/format-changed-lines`.

- **Create the project.** Run `verify-java-checkers new-project format-changed-lines` and `verify-java-checkers doctor format-changed-lines`. Doctor prints `DOCTOR_OK` and `installation: absent`.
- **Write the baseline.** Create `src/main/java/demo/Example.java` with exactly these bytes:

```java
package demo;

class Example {
  int value = 1;

  void untouched() {
    int  keep=2;
  }
}
```

- **Commit before setup.** The hook must not be installed yet, or the commit formats every added line and erases the spillover fixture. Run `verify-java-checkers record format-changed-lines -- git add src/main/java/demo/Example.java` and `verify-java-checkers record format-changed-lines -- git commit -m Baseline`. Both exit `0`.
- **Install.** Run `verify-java-checkers record format-changed-lines -- "$CHECKER/setup" "$PROJECT"`. Exit `0`. Stdout contains `Copied the checkers into` and `Installed the pre-commit hook. It runs the formatter, Checkstyle, and SpotBugs.` Run doctor again. It prints `installation: ours`, `hook: ours`, and `exclude: present`.
- **Make a changed line.** Replace `int value = 1;` with `int   value=3;` and leave `    int  keep=2;` in place. Copy the file to `$EVIDENCE/format-changed-lines/Example.before`.
- **Stage it.** Run `verify-java-checkers record format-changed-lines -- git add src/main/java/demo/Example.java` and `verify-java-checkers record format-changed-lines -- git diff --cached -- src/main/java/demo/Example.java`. The cached diff contains `int   value=3;`. Copy that transcript aside as the index snapshot.
- **Check.** Run `verify-java-checkers record format-changed-lines -- ./.local/quality/run -Tool format -Mode check`. Exit code is `1`. Stdout contains `Formatting differs on changed lines in src/main/java/demo/Example.java`, `FAILED: Google Java Format (exit code 1)`, and `Failed checks: Google Java Format`. The working tree still contains `int   value=3;` and `    int  keep=2;`.
- **Apply.** Run `verify-java-checkers record format-changed-lines -- ./.local/quality/run -Tool format -Mode apply`. Exit code is `0`. Stdout contains `Formatting 1 line range(s) in src/main/java/demo/Example.java`, `applied`, `Google Java Format apply finished on 1 file(s).`, and `PASSED: Google Java Format`. The file contains `  int value = 3;` and still contains `    int  keep=2;`.
- **Index.** Run `verify-java-checkers record format-changed-lines -- git diff --cached -- src/main/java/demo/Example.java`. The cached diff still contains `int   value=3;` and matches the snapshot taken before check. Copy the file to `$EVIDENCE/format-changed-lines/Example.after`.
- **No changes.** Put `HEAD`, the index, and the worktree back on the baseline file. Run `verify-java-checkers record format-changed-lines -- git restore --source=HEAD --staged --worktree -- src/main/java/demo/Example.java` and `verify-java-checkers record format-changed-lines -- ./.local/quality/run -Tool format -Mode check`. The format command exits `0`. Stdout contains `No changed Java files to format.` and `PASSED: Google Java Format`.
- **Untracked file.** With the tree clean, write a new untracked `src/main/java/demo/NewExample.java` that contains `int  keep=2;`. Run `verify-java-checkers record format-changed-lines -- ./.local/quality/run -Tool format -Mode apply`. Exit `0`. Stdout contains `Formatting 1 line range(s) in src/main/java/demo/NewExample.java`. The untracked file no longer contains `int  keep=2;` because every line is in range.
- **Format tool on a commit selection.** Stage a formatting-only change. Run `verify-java-checkers record format-changed-lines -- ./.local/quality/run -Tool format -Mode apply -PreCommit`. Exit `0` when the line can be formatted. Stdout contains `PASSED: Google Java Format`. `git diff --cached` still shows the unformatted staged line. This command does not run Checkstyle or SpotBugs and does not print `Staged formatting fixes`.
- **Commit hook.** Use a project that has a Maven `pom.xml` or a Gradle build, and a staged formatting-only change in a file that otherwise passes Checkstyle and SpotBugs. Run `verify-java-checkers record format-changed-lines -- git commit -m 'Format on commit'`. The hook prints `Checking 1 staged Java file(s).`, `Formatting 1 line range(s) in src/main/java/demo/Example.java`, `applied`, `Staged formatting fixes in src/main/java/demo/Example.java`, and `PASSED: Google Java Format`, then runs Checkstyle and SpotBugs. Exit `0` only when those pass too. `git show HEAD:src/main/java/demo/Example.java` contains the formatted line.

## Gotchas

- Commit the spillover fixture before setup. The hook formats every line of a newly added file.
- `run -Tool format` reads changes since `HEAD`, staged and unstaged. `-PreCommit` reads the index only.
- Apply without `-PreCommit`, and apply with `-Tool format -PreCommit`, leave the index unchanged. Staging happens on `run -PreCommit` and on `git commit`, where the tool is `all`.
- A file under `notification/avro/` is ignored. A Java file outside `src/main/java` or `src/test/java` is ignored.
- `-PreCommit` rejects a selected file that also has unstaged edits. The command exits non-zero and the message contains `has edits that are not staged`.
- The first format run prints `Downloading google-java-format-1.24.0-all-deps.jar` when the installation does not already have it.
- Four-space indentation in the unchanged lines selects Google Java Format's AOSP style for the changed lines. The two-space fixture above does not exercise AOSP.
- `git commit` on a project with no `pom.xml` and no Gradle settings or build file fails before a commit exists, because the hook still runs Checkstyle and SpotBugs.
