# Install checkers

Install copies or clones java-checkers into `.local/quality`, installs an executable pre-commit hook, and ignores `.local/` in that project's `.git/info/exclude`. A second setup keeps the installation. An unrelated existing hook stops setup and stays in place.

## Sub-features

- `install-copy` installs the working tree when the checker checkout has no `origin`.
- `install-clone` installs by cloning the checker checkout's `origin`.
- `install-hook` writes an executable `pre-commit` hook that runs `.local/quality/java-checkers run -PreCommit`.
- `install-exclude` adds `.local/` to `.git/info/exclude`.
- `install-rerun` reports that the checkers and the hook are already installed.
- `install-spaces` accepts a project path that contains spaces.
- `install-worktree` installs into a linked worktree.
- `install-refuse` leaves an unrelated pre-commit hook unchanged and fails.

## How to get to it (user POV)

- `./setup /path/to/project` from the checker checkout.
- `./setup "/path/with spaces/project"` when the path contains spaces.
- `./setup` with no path, from a checkout that already lives at `<project>/.local/quality`.
- `.\setup.cmd C:\path\to\project` in Windows Command Prompt or PowerShell.
- `.\setup.cmd C:\path\to\project -Branch <tag>` to clone a tag. `-Branch` applies only when setup clones an `origin`.

## Driving it with verify-java-checkers

Preconditions:

- Launch and the baseline doctor in [README.md](./README.md) succeeded.
- Doctor prints `checker_origin: absent` for `$CHECKER`.

Project name: `spaced project`. `$PROJECT` is `$ROOT/projects/spaced project`.

- **Create the project.** Run `verify-java-checkers new-project "spaced project"` and `verify-java-checkers doctor "spaced project"`. Doctor prints `DOCTOR_OK` and `installation: absent`.
- **Copy this working tree.** Run `verify-java-checkers record "spaced project" -- "$CHECKER/setup" "$PROJECT"`. Exit `0`. Stdout contains `Copied the checkers into`, `This checkout has no origin remote, so the copy has no git history.`, `Installed the pre-commit hook. It runs the formatter, Checkstyle, and SpotBugs.`, and `Added .local/ to .git/info/exclude.` `$PROJECT/.local/quality/run` and `$PROJECT/.local/quality/java-checkers` exist. Doctor prints `installation: ours`, `hook: ours`, and `exclude: present`. The hook file is executable and contains `java-checkers` and `run -PreCommit`.
- **Run setup again.** Run the same `record` command. Exit `0`. Stdout contains `Checkers are already installed.`, `Pre-commit hook is already installed.`, and `.git/info/exclude already ignores .local/.`
- **Linked worktree.** Run `verify-java-checkers record "spaced project" -- git worktree add -b linked "$ROOT/worktrees/linked" HEAD`. Exit `0`. Run `verify-java-checkers doctor --git "$ROOT/worktrees/linked"`. It prints `installation: absent` and `DOCTOR_OK`. Run `verify-java-checkers record "spaced project" -- "$CHECKER/setup" "$ROOT/worktrees/linked"`. Exit `0`. `$ROOT/worktrees/linked/.local/quality/run` exists. Doctor `--git` prints `installation: ours` and `hook: ours`.
- **Unrelated hook.** Create another project with `verify-java-checkers new-project "foreign hook"`. Write an executable `.git/hooks/pre-commit` containing `#!/bin/sh` and `echo existing-hook`. Run `verify-java-checkers record "foreign hook" -- "$CHECKER/setup" "$ROOT/projects/foreign hook"`. The exit code is non-zero. Stdout or stderr contains `A pre-commit hook already exists and was left unchanged:`. The hook file still contains `existing-hook`. `.local/quality` does not exist.
- **Clone origin.** From a checker directory that has `origin`, run setup against a new project. The launch copy cannot do this: it has no `origin`. Use the real checkout when the goal is the configured remote: `verify-java-checkers record "clone origin" -- "$SOURCE/setup" "$ROOT/projects/clone origin"` after `new-project "clone origin"`. That command contacts the checkout's `origin` and needs network access when the remote is not local. Exit `0`. Stdout contains `Cloned the checkers into` and does not contain `Copied the checkers into`. The installed tree matches that remote, plus the `java-checkers` binary setup copies from the executable that performed the clone. Other uncommitted files in `$SOURCE` are absent from `$ROOT/projects/clone origin/.local/quality`.

## Gotchas

- `$CHECKER/setup` proves the working tree, including uncommitted edits. `$SOURCE/setup` proves the configured `origin` and skips those edits.
- Setup refuses to replace a `.local/quality` directory that exists and contains neither `run`, `run.ps1`, nor `java-checkers`. The message contains `Refusing to overwrite`.
- A hook that already mentions `.local/quality/run`, `.local/quality/run.cmd`, `.local/quality/run.ps1`, or `java-checkers` is updated in place. Any other existing hook is left unchanged.
- `-Branch` is ignored on the no-origin copy path.
- Do not run setup against the java-checkers checkout unless that checkout is itself the project's `.local/quality`.
