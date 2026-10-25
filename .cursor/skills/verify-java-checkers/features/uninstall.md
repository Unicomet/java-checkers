# Uninstall checkers

Uninstall deletes `.local/quality` and the pre-commit hook this installer wrote. A modified or unrelated hook stays. Project build files stay. The `.local/` exclude entry stays when `.local/` still contains something else.

## Sub-features

- `uninstall-installed` removes the installation and the matching hook from inside the project.
- `uninstall-external` removes them by passing the project path to the checker checkout's `./uninstall`.
- `uninstall-modified-hook` keeps a hook whose contents differ from the template.
- `uninstall-other-files` keeps `.local/` and its exclude entry when another file is still there.
- `uninstall-repeat` succeeds when the installation is already gone.

## How to get to it (user POV)

- `./.local/quality/uninstall` from the project.
- `./uninstall /path/to/project` from a checker checkout.
- `.\.local\quality\uninstall.cmd` and `.\uninstall.cmd C:\path\to\project` on Windows.

## Driving it with verify-java-checkers

Preconditions:

- Launch and the baseline doctor in [README.md](./README.md) succeeded.
- `verify-java-checkers new-project uninstall` has been run.
- `"$CHECKER/setup" "$ROOT/projects/uninstall"` has been recorded and doctor prints `installation: ours` and `hook: ours`.
- The project contains a committed `pom.xml` whose bytes are the uninstall witness. Any small well-formed POM is enough.

`$PROJECT` is `$ROOT/projects/uninstall`.

- **Remove from inside the project.** Copy `pom.xml` to `$EVIDENCE/uninstall/pom.xml` first. Run `verify-java-checkers record uninstall -- ./.local/quality/uninstall`. Exit `0`. Stdout contains `Removed the checker pre-commit hook.`, `Removed`, and `Local checker uninstall complete.` `$PROJECT/.local/quality` does not exist. The pre-commit hook file does not exist. `pom.xml` matches the copied witness. `.git/info/exclude` no longer contains a `.local/` line.
- **Remove from the checker copy.** Run setup again, then `verify-java-checkers record uninstall -- "$CHECKER/uninstall" "$PROJECT"`. Exit `0`. Stdout contains `Local checker uninstall complete.` The installation is gone.
- **Repeat.** Run `verify-java-checkers record uninstall -- "$CHECKER/uninstall" "$PROJECT"` again. Exit `0`. Stdout contains `Local checker uninstall complete.`
- **Modified hook.** Run setup again. Append a line `# My hook customization` to the installed pre-commit hook. Run `verify-java-checkers record uninstall -- ./.local/quality/uninstall`. Exit `0`. Stdout contains `Preserved an unrelated or modified pre-commit hook:` and `Local checker uninstall complete.` The hook file still contains `# My hook customization`. `.local/quality` does not exist.
- **Other files under `.local/`.** Run setup again. Create `.local/other-tool` containing `keep me`. Run uninstall from `.local/quality/uninstall`. Exit `0`. `.local/other-tool` still contains `keep me`. `.git/info/exclude` still contains `.local/`. `.local/quality` does not exist.

## Gotchas

- Uninstall deletes the scripts it is running from when invoked as `.local/quality/uninstall`. A later command in that project has to call `"$CHECKER/uninstall"` or run setup again.
- A `.local/quality` directory is left in place unless it contains `hook/pre-commit` and one of `run`, `run.ps1`, or `java-checkers`. The message contains `Refusing to remove an unrecognized directory`.
- Passing a path that is not a Git repository fails. The message contains `Not a git repository`.
- Uninstall does not edit `pom.xml` or Gradle build files. Compare the witness file after every entry.
- Cleanup of the verification run is separate. Uninstall does not delete `$EVIDENCE`.
