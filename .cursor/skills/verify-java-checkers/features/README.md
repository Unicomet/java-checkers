# java-checkers verification map

This directory is the maintained source for verifying the user-facing behavior of java-checkers. Read this index, then follow one feature file. Launch, doctor, evidence, and cleanup are specified in [../SKILL.md](../SKILL.md).

## Baseline preconditions

- Run `verify-java-checkers launch` from the java-checkers checkout and export `VERIFY_RUN_ID`.
- Source `$EVIDENCE/session.env`.
- Run `verify-java-checkers doctor` and require `DOCTOR_OK`, `checker_copy: current`, and `checker_origin: absent`.
- Create each drive with `verify-java-checkers new-project <name>` so the project lives under `$ROOT/projects`.
- Drive only a project whose doctor output says `installation: ours` or, before setup, `installation: absent`.
- Doctor again after setup and after any failed command.

## Driving conventions

- Start every recipe from the baseline unless its preconditions add state.
- Run checker commands through `verify-java-checkers record <project-name> -- <command>`.
- Quote project paths. Names may contain spaces.
- Call the installed `$PROJECT/.local/quality/run`, not the checkout's `./run`.
- `$PROJECT` means `$ROOT/projects/<project-name>`.
- Leave proof files under `$EVIDENCE`. Cleanup deletes the project and keeps those files.

## Proof and skip reporting

- Capture the command, the exit code, and the resulting file, report, or Git object.
- A `PASSED` line without the file or report the recipe names is incomplete.
- `SKIP_LOCAL_CHECKS=1` and a run with no staged Java files are skip reports. Say which command skipped, and do not mark that entry verified.
- When `mvn` or `gradle` is absent, record `DOCTOR` line `mvn: absent` or `gradle: absent` and stop that entry. A Maven result does not verify a Gradle entry.

## Feature entry contract

Each feature file starts with an H1 and one paragraph, then these four H2 sections in order: `Sub-features`, `How to get to it (user POV)`, `Driving it with verify-java-checkers`, and `Gotchas`.

## Features

- [Install checkers](./install.md) covers setup from this working tree and from a checkout that has `origin`, the pre-commit hook, `.local/` exclude, a path with spaces, a second setup, a linked worktree, and an existing unrelated hook.
- [Format changed lines](./format-changed-lines.md) covers check and apply on Git-changed lines, an unchanged spillover line, the commit hook, and a tree with no Java changes.
- [Checkstyle](./checkstyle.md) covers a full Maven run, a staged Maven run, and a staged Gradle run.
- [SpotBugs](./spotbugs.md) covers a staged nested-class finding, an unstaged class the pre-commit run ignores, and a full run that sees the unstaged class.
- [Uninstall](./uninstall.md) covers removing the installation from inside the project and from the checker tree, including a modified hook and a leftover file under `.local/`.
