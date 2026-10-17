# Rules

| Rule | Enforced by |
| --- | --- |
| Format only git-changed lines. A split or merge must not rewrite the rest of the file. | `Limit-FormatToAffectedLines` in `format-changed.ps1` keeps a diff hunk only when it overlaps the git range. `pwsh -NoProfile -File tests/format-changed.Tests.ps1` |
| Do not format Java with Spotless. | `format-changed.ps1` calls the Google Java Format CLI. The same test fails if the script references the Spotless plugin. |
