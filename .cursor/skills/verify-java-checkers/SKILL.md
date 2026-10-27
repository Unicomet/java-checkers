---
name: verify-java-checkers
description: "Drive java-checkers from the shell the way a user does: install Google Java Format, Checkstyle, and SpotBugs into an isolated Git project, run them, and keep the transcript. Use when changing setup, run, format-changed, the pre-commit hook, uninstall, or checker config, or when asked to prove checker behavior."
---

# Verify java-checkers

java-checkers is a command-line installer. A user runs `./setup` against a Git project, then `./.local/quality/run` or `git commit`. The commit hook runs Google Java Format, Checkstyle, and SpotBugs. There is no server and no browser UI. Maven and Gradle are both user paths; Gradle wins when a Gradle build file and a `pom.xml` both exist.

The harness is `.cursor/skills/verify-java-checkers/scripts/verify-java-checkers`. Feature recipes live in [features/README.md](features/README.md).

## Launch

Launch prepares a disposable checker tree. It does not start a project and it does not download tools.

From the java-checkers checkout:

```bash
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers launch
```

Ready output starts with `READY` and includes `export VERIFY_RUN_ID=...`. Export that value in the same shell before any later command. Launch is ready only when all of these are true:

- `git` and JDK 17 or newer are on `PATH`.
- The checkout contains `run`, `setup`, `uninstall`, and `hook/pre-commit`.
- An executable `java-checkers` binary is beside those scripts, or under `target/release` or `target/debug`. Launch copies that binary and does not run Cargo.
- A copy of the checkout exists at `$ROOT/checker` with version-control metadata and `target/` removed, and with that binary installed as `java-checkers`.

`mvn` and `gradle` are reported as `present` or `absent`. Launch still succeeds when either is absent. Checkstyle and SpotBugs on Maven need `mvn`. Gradle journeys need `gradle` on `PATH` or a project `gradlew`.

`record` puts the JDK launch resolved, and Maven or Gradle when those resolved, at the front of `PATH`. Doctor's `java_bin` is that JDK. A `java` or `mvn` shim that works only inside this checkout is not used for a target project. Launch follows `mise which` from the checkout when `/tmp` cannot run the tool.

The checker copy is a snapshot. Edits made in the checkout after launch are not in the copy. Run `cleanup`, then `launch` again, and export the new id.

Launch writes `/tmp/java-checkers-verify-evidence/$VERIFY_RUN_ID/launch.txt` and the session file. Load it after exporting the id:

```bash
source "/tmp/java-checkers-verify/$VERIFY_RUN_ID/session.env"
```

`$CHECKER` is `$ROOT/checker`. `$EVIDENCE` is `/tmp/java-checkers-verify-evidence/$VERIFY_RUN_ID`. A copy of the session file is `$EVIDENCE/session.env`, which remains after cleanup.

Each drive uses its own project under `$ROOT/projects`. Two run ids can proceed side by side. Do not point a drive at the java-checkers checkout or at any `.local/quality` directory this run did not install.

This launch copy has no `origin`. `./setup` from it prints `Copied the checkers into` and installs the working-tree bytes of the launcher scripts, config, `hook/`, `src/`, `examples/`, and the running `java-checkers` binary. Uncommitted edits to those files are installed. Other files, such as `tests/` and `mise.toml`, are not. A user who runs `./setup` from a checkout that has `origin` instead gets `Cloned the checkers into`. That clone is the remote plus the binary that performed the clone. Other uncommitted files are not in it. The install feature covers that entry. Published-origin setup also needs network access to that remote.

On Windows the user-facing launchers are `setup.cmd`, `run.cmd`, and `uninstall.cmd`. They forward the same arguments to the `java-checkers` binary. This harness invokes the Bash launchers.

## Doctor

Doctor is read-only. Run it after launch and again after anything surprising, including a failed drive, before the next command.

```bash
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers doctor
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers doctor format-changed-lines
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers doctor --git "$ROOT/worktrees/linked"
```

The first line is `DOCTOR_OK` or `DOCTOR_FAIL`. Exit code `0` matches `DOCTOR_OK`. A project created by `new-project` and not yet installed reports `installation: absent`, `hook: absent`, and `exclude: absent`. After `./setup` from this run's checker copy, a healthy project reports `installation: ours`, `hook: ours`, and `exclude: present`.

`DOCTOR_FAIL` means the instance is not worth driving. `checker_copy: stale` means the checkout changed after launch. `installation: foreign` means `.local/quality` is not this run's copy. Stop and start a new launch, or choose a project this run created.

`gradle: absent` and `mvn: absent` do not by themselves fail the doctor. The feature that needs the missing tool stops on that line.

## Drive

Source the session, then follow one feature file. `record` runs the command with its working directory set to that project, writes a transcript, and exits with the command's status. A documented non-zero status is evidence. The transcript is already on disk when `record` returns.

```bash
source "$EVIDENCE/session.env"
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers new-project format-changed-lines
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers doctor format-changed-lines
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers record format-changed-lines -- "$CHECKER/setup" "$ROOT/projects/format-changed-lines"
```

Invoke the installed runner at `$ROOT/projects/<name>/.local/quality/run`. The runner finds the project two directories above its own script. Running `./run` from the java-checkers checkout does not check that checkout.

Stable handles are the command arguments and the stdout sentences in the feature files. Treat those sentences as literal. `-Tool` is `all`, `format`, `checkstyle`, or `spotbugs`. `-Mode` is `check` or `apply`. With no flags, `run` uses tool `all` and mode `check`, and it does not limit the run to staged files. It checks format on changed lines, then runs Checkstyle and SpotBugs on the whole project, and it still runs the later tools after a format failure. `-PreCommit` limits Checkstyle and SpotBugs to staged Java files. When the tool is `all`, that run forces format apply and stages the formatting fixes, including when `-Mode check` was also passed. `-All` prints `Google Java Format only edits Git-changed line ranges; -All does not expand its scope.`

Each checker status line is `PASSED: <name>` or `FAILED: <name> (exit code N)`. A failed pre-commit run also prints `Commit blocked. Stage the fixes and commit again.`

## Evidence

Keep proof under `$EVIDENCE/<project-name>/`. `record` writes `001.txt`, `002.txt`, and so on. Each file contains the command, the working directory, the exit code, stdout, and stderr. Copy source files, diffs, and reports that the recipe names into that same directory before cleanup.

A proof shows the user action and the resulting state:

- The transcript includes the command and the exit code.
- A formatting change is shown by the file bytes after the run and by `git diff --cached` when the recipe stages first.
- A Checkstyle or SpotBugs run is shown by the status line and by the report or the project file the recipe names.
- `pom.xml` and Gradle build files stay byte-for-byte unchanged. `.quality-pom.xml` is gone when the run returns.
- `SKIP_LOCAL_CHECKS=1` is proof that the hook skipped the checkers. It is not proof that they passed. The hook prints `Skipping local Checkstyle, SpotBugs, and formatter.`

Use the real installer, runner, and hook. Do not call Maven or Gradle plugin goals by hand, and do not edit a temporary POM yourself. The runner creates `.quality-pom.xml` and deletes it.

## Cleanup

Cleanup stops process groups started by `record` in this run, then deletes `$ROOT` (the checker copy, projects, worktrees, and pid list). It leaves `$EVIDENCE` in place.

```bash
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers cleanup
```

Stdout ends with `EVIDENCE=/tmp/java-checkers-verify-evidence/$VERIFY_RUN_ID`. Confirm a proof file is still there after cleanup. Run cleanup after a failed drive too. Unset `VERIFY_RUN_ID` before the next launch. Launch rejects an id whose evidence directory already exists, so a retry cannot append to the previous proof. Cleanup does not kill processes by name.

## Helpers

The harness is one executable. From the checkout:

```bash
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers launch
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers doctor
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers doctor <project-name>
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers doctor --git <worktree>
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers new-project <project-name>
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers record <project-name> -- <command> [args...]
.cursor/skills/verify-java-checkers/scripts/verify-java-checkers cleanup
```

`new-project` creates `$ROOT/projects/<project-name>`, sets a local Git identity (`Java Checkers Verify` / `verify@example.com`), turns off commit signing and `core.autocrlf` in that repository only, and makes an empty initial commit. Project names may contain spaces. Quote them.
