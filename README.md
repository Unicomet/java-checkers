# Java checkers

Formatter, Checkstyle, and SpotBugs for a Maven project. Setup places them in `.local/quality` and writes a pre-commit hook that runs all three on staged Java files.

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

A commit runs the same three tools on staged files under `src/main/java` and `src/test/java`. A commit with no staged Java files skips them. Skip one commit with `SKIP_LOCAL_CHECKS=1`.

## Rules for one project

Edit `.local/quality/checkstyle.xml` and `.local/quality/spotbugs-exclude.xml` in that project's clone. Commit those edits in the checker clone when you want to keep them. Other projects stay on their own clone and tag.

The project `pom.xml` needs a plugins block that ends with the line `    </plugins>`. Maven uses `.mvn/settings.xml` when that file exists. Java sources are read from `src/main/java` and `src/test/java`.

## Requirements

Git, Maven, and a JDK that Maven can run.
