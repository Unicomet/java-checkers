# Rules

| Rule | Enforced by |
| --- | --- |
| Format only git-changed lines. A split or merge must not rewrite the rest of the file. | `Limit-FormatToAffectedLines` in `format-changed.ps1` keeps a diff hunk only when it overlaps the git range. `pwsh -NoProfile -File tests/format-changed.Tests.ps1` |
| Do not format Java with Spotless. | `format-changed.ps1` calls the Google Java Format CLI. The same test fails if the script references the Spotless plugin. |
| Do not use H2 or boot a database from a test. | Checkstyle `NoEmbeddedDatabase` and `NoDatabaseTest`. |
| Do not load a SQL fixture from a test. | Checkstyle `NoSqlFixture` and `lint-tests.ps1` for `src/test/**/*.sql`. |
| Do not log a CURP. | Checkstyle `NoCurpInLog`. Use `requestId` on the log line. |
| Do not use `java.util.Date` or `Calendar`. | Checkstyle `NoUtilDate`. A same-line `NOSONAR` keeps a library boundary such as JJWT. |
| Do not add Spring Security. | Checkstyle `NoSpringSecurity`. |
| Do not print to `System.out` or `System.err`. | Checkstyle `NoSystemOut`. |
| Put an exception class in `commons/exceptions`. | `lint-main.ps1` |
| Put a properties class in `config/properties`. | `lint-main.ps1` |
| Inject a service, repository, controller, or client. | `lint-main.ps1` rejects `new` of those types under `src/main`. |
| Use Lombok instead of a trivial getter or setter. | `lint-main.ps1` |
| A service class has an `IName` interface. | `lint-main.ps1` |
| The checks above fail on the old examples. | `pwsh -NoProfile -File tests/repeated-rules.Tests.ps1` |
