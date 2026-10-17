# Java checkers

Google Java Format, Checkstyle, and SpotBugs for a Maven project. Setup places them in `.local/quality` and writes a pre-commit hook that runs all three on staged Java files.

## Set up a project

Clone this repository, then from that folder run:

```powershell
.\setup.cmd C:\path\to\your-project
```

Use a tag when a project should stay on an older copy:

```powershell
.\setup.cmd C:\path\to\your-project -Branch v1
```

The script clones this repository into `your-project\.local\quality`, adds `.local/` to that project's `.git/info/exclude`, and writes `.git/hooks/pre-commit`. The exclude file is local to the clone and is not pushed.

When `.local\quality` is already a clone of this repository, run `.\setup.cmd` with no path. That installs the hook and the exclude entry.

## Run the checkers

From the project root:

```powershell
.\.local\quality\run
.\.local\quality\run -Tool checkstyle
.\.local\quality\run -Tool spotbugs
.\.local\quality\run -Mode apply -Tool format
```

On Linux with PowerShell Core:

```bash
./.local/quality/run
./.local/quality/run -Tool format -Mode apply
```

A commit runs the same three tools on staged files under `src/main/java` and `src/test/java`. A commit with no staged Java files skips them. Skip one commit with `SKIP_LOCAL_CHECKS=1`.

Formatting uses [Google Java Format](https://github.com/google/google-java-format) (Google style) on **line ranges from `git diff`**, not the whole file. Spotless cannot limit formatting to changed lines, so the format step calls the Google Java Format CLI with `--lines`. After formatting, spillover outside those git-changed lines is discarded, including when a formatted line splits or merges and the line count changes. Import sorting/removal is skipped in line mode so untouched import lines stay put. Untracked new Java files are formatted in full.

Normal runs select tracked Java files changed since `HEAD` (staged or unstaged), plus untracked Java files. Pre-commit runs select staged Java files only and reject files with unstaged edits. Files merely opened in an editor and unchanged files are never selected. `-All` does not expand the formatter's scope. Generated `notification/avro` sources are excluded. Apply mode leaves changes unstaged so you can review and stage them.

The Google Java Format all-deps jar is downloaded once into `.local/quality/tools/`.

## Rules for one project

Edit `.local/quality/checkstyle.xml` and `.local/quality/spotbugs-exclude.xml` in that project's clone. Commit those edits in the checker clone when you want to keep them. Other projects stay on their own clone and tag.

The project `pom.xml` needs a plugins block that ends with the line `    </plugins>`. Maven uses `.mvn/settings.xml` when that file exists. Java sources are read from `src/main/java` and `src/test/java`.

Checkstyle rejects H2, a `@SpringBootTest` that carries a JDBC URL, `@Sql` or `schema.sql` / `data.sql`, and a log call that includes a CURP. `lint-tests.ps1` rejects any `.sql` file under `src/test`.

## Requirements

Git, Maven, PowerShell (`pwsh` or Windows PowerShell), JDK 17 or newer (for Google Java Format), and network access once to download the formatter jar.
