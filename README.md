# Java checkers

Google Java Format, Checkstyle, and SpotBugs for Maven and Gradle Java projects. Setup places them in `.local/quality` and writes a pre-commit hook that runs all three on staged Java files.

## Set up a project

In Git Bash on Windows or Bash on Linux/macOS, run this command from the checker checkout:

```bash
./setup /path/to/your-project
```

Paths containing spaces must be quoted. In Git Bash, use Bash paths such as `/c/Users/you/my-project`. The Bash launchers use `pwsh` when available and fall back to `powershell.exe` on Windows. Linux/macOS require PowerShell Core (`pwsh`) on PATH.

In Windows Command Prompt or PowerShell:

Clone this repository, then from that folder run:

```powershell
.\setup.cmd C:\path\to\your-project
```

Use a tag when a project should stay on an older copy:

```powershell
.\setup.cmd C:\path\to\your-project -Branch v1
```

The script clones this repository into `your-project\.local\quality`, adds `.local/` to that project's `.git/info/exclude`, and installs an executable pre-commit hook in Git's configured hooks directory. The exclude file is local to the clone and is not pushed.

When `.local\quality` is already a clone of this repository, run `.\setup.cmd` with no path. That installs the hook and the exclude entry.

## Uninstall

From your project's root, run:

```powershell
.\.local\quality\uninstall.cmd
```

On Linux or Git Bash, run `./.local/quality/uninstall`. For an older installation, first run `git -C .local/quality pull --ff-only` to get the uninstaller.

This deletes `.local/quality`, including downloaded tools and local checker customizations, and removes the installed pre-commit hook. Modified or unrelated hooks are preserved. The `.local/` ignore entry is removed when no other files remain in `.local`; other exclude entries are preserved. Project build files are left unchanged.

You can also run `./uninstall /path/to/project` (Windows: `.\uninstall.cmd C:\path\to\project`) from a separate checker checkout.

## Run the checkers

From the project root:

```powershell
.\.local\quality\run
.\.local\quality\run -Tool checkstyle
.\.local\quality\run -Tool spotbugs
.\.local\quality\run -Mode apply -Tool format
```

In Git Bash or Linux/macOS Bash:

```bash
./.local/quality/run
./.local/quality/run -Tool format -Mode apply
```

A commit checks Google Java Format only on staged changed lines, Checkstyle on staged Java files, and SpotBugs on classes corresponding to staged Java files (including nested classes) under `src/main/java` and `src/test/java`. SpotBugs requires compilation and may compile other project sources. A commit with no staged Java files skips them. Skip one commit with `SKIP_LOCAL_CHECKS=1`.

Formatting uses [Google Java Format](https://github.com/google/google-java-format) (Google style) on **line ranges from `git diff`**, not the whole file. Spotless cannot limit formatting to changed lines, so the format step calls the Google Java Format CLI with `--lines`. After formatting, spillover outside those git-changed lines is discarded, including when a formatted line splits or merges and the line count changes. Import sorting/removal is skipped in line mode so untouched import lines stay put. Untracked new Java files are formatted in full.

For formatting, normal runs select tracked Java files changed since `HEAD` (staged or unstaged), plus untracked Java files. Normal Checkstyle and SpotBugs runs check the project; add `-PreCommit` to restrict them to staged files/classes. Pre-commit runs select staged Java files only and reject selected files with unstaged edits. Files merely opened in an editor and unchanged files are never selected. `-All` does not expand the formatter's scope. Generated `notification/avro` sources are excluded. Apply mode leaves changes unstaged so you can review and stage them.

The hook checks formatting and blocks the commit if fixes are needed. Apply and stage fixes, then retry:

```bash
./.local/quality/run -Tool format -Mode apply -PreCommit
git add path/to/fixed/File.java
git commit
```

Setup preserves unrelated existing pre-commit hooks by failing with their path. It supports Git worktrees and `core.hooksPath`. Re-running setup repairs the hook; an existing checker installation is retained. Pull updates inside `.local/quality` when needed.

The Google Java Format all-deps jar is downloaded once into `.local/quality/tools/`.

## Rules for one project

Edit `.local/quality/checkstyle.xml` and `.local/quality/spotbugs-exclude.xml` in that project's clone. Commit those edits in the checker clone when you want to keep them. Other projects stay on their own clone and tag.

For Maven, the runner adds the tool plugins to a temporary copy of the project `pom.xml`, regardless of indentation, and creates the build/plugins block if needed. Maven uses `.mvn/settings.xml` when that file exists. Java sources are read from `src/main/java` and `src/test/java`.

Gradle projects are detected by `build.gradle`, `build.gradle.kts`, `settings.gradle`, or `settings.gradle.kts` (Gradle takes precedence if a POM also exists). The runner prefers `gradlew` / `gradlew.bat`, falling back to `gradle` on PATH. It supplies `quality.init.gradle` with [`--init-script`](https://docs.gradle.org/current/userguide/init_scripts.html); no build file edits or checker plugins are required. It adds `qualityCheckstyle` and `qualitySpotbugs` tasks to Java projects, using the same checker versions and configuration as Maven. Gradle resolves the checker dependencies from Maven Central. SpotBugs reads the auxiliary dependency classpath from a UTF-8 file to avoid Windows command-line length limits. It compiles the selected source sets and writes `build/reports/local-quality/spotbugs.xml` in each Java project. Checkstyle uses Java source sets; staged selection and formatting recognize standard `src/main/java` and `src/test/java` paths, including Gradle subprojects. Custom source layouts are supported only by normal Gradle lint runs.

Each checker prints a `PASSED` or `FAILED` status. Failed-check output is repeated in a final summary, so a later successful Gradle task does not hide an earlier failure. Gradle includes exception stack traces (`--stacktrace`), Maven includes execution errors (`-e`), and runner exceptions include PowerShell script stack traces. Formatting differences identify the affected source files; formatting advice appears only when the formatter fails.

## Requirements

Git, Maven or Gradle (a project wrapper is preferred for Gradle), PowerShell (`pwsh` or Windows PowerShell), JDK 17 or newer (for Google Java Format), and network access for the first tool/dependency downloads. Gradle support is verified with Gradle 8.14.3 and JDK 17; other Gradle versions must support running on the installed JDK.

## Verify the checker scripts

```bash
pwsh -NoProfile -File tests/format-changed.Tests.ps1
python3 tests/bash-launchers.Tests.py
python3 tests/setup-and-hook.Tests.py
python3 tests/diagnostics.Tests.py
python3 tests/uninstall.Tests.py
python3 tests/spotbugs-staged.Tests.py
python3 tests/gradle.Tests.py
python3 tests/spotbugs-command-line.Tests.py
```

The setup test uses a Maven stub. The SpotBugs regression test runs real Maven in a temporary project, verifies a staged nested-class violation blocks the check, and verifies an unstaged class with the same violation is ignored. It needs the tools listed above and access to Maven dependencies.

The Gradle integration test uses real Gradle, generates a project wrapper, and runs `./setup` in Groovy and Kotlin DSL projects. It verifies formatting, Checkstyle, and SpotBugs failures, staged nested-class selection, and an actual successful `git commit` through the installed hook. Put Gradle on PATH to generate the wrapper. Set `QUALITY_EVIDENCE=/path/to/log` to save the complete command transcript.

See [Gradle verification evidence](docs/gradle-verification.md) for a published commit made through the installed hook and the recorded command output.
