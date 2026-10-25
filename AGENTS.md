# Rules

| Rule | Enforced by |
| --- | --- |
| Format only git-changed lines. A split or merge must not rewrite the rest of the file. | `limit_format_to_affected_lines` in `src/format.rs` keeps a diff hunk only when it overlaps the git range. `cargo test --bin java-checkers` |
| Do not format Java with Spotless. | `src/format.rs` calls the Google Java Format CLI. `cargo test --bin java-checkers formatter_does_not_call_spotless` fails if the formatter references the Spotless plugin. |
