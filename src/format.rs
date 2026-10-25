use crate::gitutil::{git_lines, log_line};
use regex::Regex;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

const GJF_VERSION: &str = "1.24.0";

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Check,
    Apply,
}

enum FileOutcome {
    Clean,
    Wrote,
    Failed,
}

struct FileText {
    lines: Vec<String>,
    newline: String,
    has_final_newline: bool,
}

struct Hunk {
    old_start: i32,
    old_count: i32,
    new_count: i32,
}

fn java_path_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^(?:.+/)?src/(main|test)/java/.+\.java$").unwrap())
}

fn hunk_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@").unwrap())
}

fn new_start_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\+(\d+)(?:,(\d+))?").unwrap())
}

pub fn is_selected_java(path: &str) -> bool {
    let path = path.replace('\\', "/");
    !path.contains("/notification/avro/") && java_path_re().is_match(&path)
}

fn split_file_lines(text: &str) -> FileText {
    let newline = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let has_final_newline = normalized.ends_with('\n');
    let body = normalized.trim_end_matches('\n');
    let lines = if body.is_empty() {
        Vec::new()
    } else {
        body.split('\n').map(str::to_string).collect()
    };
    FileText {
        lines,
        newline: newline.to_string(),
        has_final_newline,
    }
}

fn join_file_lines(lines: &[String], newline: &str, has_final_newline: bool) -> String {
    let mut text = lines.join(newline);
    if has_final_newline {
        text.push_str(newline);
    }
    text
}

pub fn affected_line_numbers(diff_text: &str) -> Vec<i32> {
    let mut numbers = Vec::new();
    let mut new_line = 0i32;
    for raw in diff_text.split('\n') {
        let raw = raw.trim_end_matches('\r');
        if raw.starts_with("@@") {
            if let Some(hunk) = new_start_re().captures(raw) {
                new_line = hunk[1].parse().unwrap_or(0);
            }
            continue;
        }
        if raw.starts_with("+++")
            || raw.starts_with("---")
            || raw.starts_with("diff ")
            || raw.starts_with("index ")
            || raw.starts_with('\\')
        {
            continue;
        }
        if let Some(rest) = raw.strip_prefix('+') {
            let _ = rest;
            numbers.push(new_line);
            new_line += 1;
            continue;
        }
        if raw.starts_with('-') {
            continue;
        }
        if new_line > 0 {
            new_line += 1;
        }
    }
    numbers
}

pub fn line_ranges(line_numbers: &[i32]) -> Vec<String> {
    if line_numbers.is_empty() {
        return Vec::new();
    }
    let mut sorted = line_numbers.to_vec();
    sorted.sort_unstable();
    sorted.dedup();
    let mut ranges = Vec::new();
    let mut start = sorted[0];
    let mut prev = sorted[0];
    for number in sorted.iter().skip(1).copied() {
        if number == prev + 1 {
            prev = number;
            continue;
        }
        ranges.push(format!("{start}:{prev}"));
        start = number;
        prev = number;
    }
    ranges.push(format!("{start}:{prev}"));
    ranges
}

pub fn indentation_width(text: &str, affected: &[i32]) -> i32 {
    let lines = split_file_lines(text).lines;
    let changed: HashSet<i32> = affected.iter().copied().collect();
    let indent_re = Regex::new(r"^( {2}| {4})\S").unwrap();
    let comment_re = Regex::new(r"^\s*(//|/\*|\*)").unwrap();
    for include_changed in [false, true] {
        let mut width = 0i32;
        for (index, line) in lines.iter().enumerate() {
            if !include_changed && changed.contains(&((index as i32) + 1)) {
                continue;
            }
            if comment_re.is_match(line) {
                continue;
            }
            if let Some(found) = indent_re.captures(line) {
                let indent = found[1].len() as i32;
                if width == 0 || indent < width {
                    width = indent;
                }
            }
        }
        if width > 0 {
            return width;
        }
    }
    2
}

fn diff_hunks(before_text: &str, after_text: &str) -> Result<Vec<Hunk>, String> {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("gjf-diff-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&dir).map_err(|err| format!("Cannot create diff directory: {err}"))?;
    let before_path = dir.join("before.java");
    let after_path = dir.join("after.java");
    let result = (|| {
        fs::write(&before_path, before_text)
            .map_err(|err| format!("Cannot write diff input: {err}"))?;
        fs::write(&after_path, after_text)
            .map_err(|err| format!("Cannot write diff input: {err}"))?;
        let output = Command::new("git")
            .args([
                "-c",
                "core.quotepath=false",
                "-c",
                "core.attributesFile=/dev/null",
                "diff",
                "--no-index",
                "--text",
                "-U0",
                "--",
            ])
            .arg(&before_path)
            .arg(&after_path)
            .output()
            .map_err(|err| format!("git diff failed: {err}"))?;
        let code = output.status.code().unwrap_or(1);
        if code > 1 {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("git diff --no-index failed: {stderr}"));
        }
        let text = String::from_utf8_lossy(&output.stdout);
        let mut hunks = Vec::new();
        for raw in text.split('\n') {
            let line = raw.trim_end_matches('\r');
            let Some(captures) = hunk_re().captures(line) else {
                continue;
            };
            let old_count = captures
                .get(2)
                .map(|value| value.as_str().parse().unwrap_or(1))
                .unwrap_or(1);
            let new_count = captures
                .get(4)
                .map(|value| value.as_str().parse().unwrap_or(1))
                .unwrap_or(1);
            hunks.push(Hunk {
                old_start: captures[1].parse().unwrap_or(0),
                old_count,
                new_count,
            });
        }
        Ok(hunks)
    })();
    let _ = fs::remove_dir_all(&dir);
    result
}

/// Keep a formatter edit only when its old-file hunk overlaps a git-changed line.
/// A split or merge changes the line count and must not accept rewrites of other lines.
pub fn limit_format_to_affected_lines(
    before_text: &str,
    after_text: &str,
    affected_lines: &[i32],
) -> Result<String, String> {
    let before = split_file_lines(before_text);
    let after = split_file_lines(after_text);
    let affected: HashSet<i32> = affected_lines.iter().copied().collect();
    let hunks = diff_hunks(before_text, after_text)?;
    if hunks.is_empty() {
        return Ok(before_text.to_string());
    }

    let mut old_pos = 0usize;
    let mut new_pos = 0usize;
    let mut merged = Vec::new();
    for hunk in hunks {
        let hunk_old_index = if hunk.old_count == 0 {
            hunk.old_start
        } else {
            hunk.old_start - 1
        };
        if hunk_old_index < old_pos as i32 {
            return Err(format!(
                "Overlapping diff hunk at old line {}.",
                hunk.old_start
            ));
        }
        while (old_pos as i32) < hunk_old_index {
            let line = before.lines.get(old_pos).ok_or_else(|| {
                format!(
                    "Diff walked past the original file at line {}.",
                    old_pos + 1
                )
            })?;
            merged.push(line.clone());
            old_pos += 1;
            new_pos += 1;
        }
        let keep_new = if hunk.old_count == 0 {
            affected.contains(&hunk.old_start) || affected.contains(&(hunk.old_start + 1))
        } else {
            (hunk.old_start..hunk.old_start + hunk.old_count)
                .any(|number| affected.contains(&number))
        };
        if keep_new {
            for _ in 0..hunk.new_count {
                let line = after.lines.get(new_pos).ok_or_else(|| {
                    "Formatted diff points past the end of the formatted file.".to_string()
                })?;
                merged.push(line.clone());
                new_pos += 1;
            }
            old_pos += hunk.old_count.max(0) as usize;
        } else {
            for _ in 0..hunk.old_count {
                let line = before.lines.get(old_pos).ok_or_else(|| {
                    format!(
                        "Diff walked past the original file at line {}.",
                        old_pos + 1
                    )
                })?;
                merged.push(line.clone());
                old_pos += 1;
            }
            new_pos += hunk.new_count.max(0) as usize;
        }
    }
    while old_pos < before.lines.len() {
        merged.push(before.lines[old_pos].clone());
        old_pos += 1;
    }
    Ok(join_file_lines(
        &merged,
        &before.newline,
        before.has_final_newline,
    ))
}

fn read_text(path: &Path) -> Result<String, String> {
    let bytes = fs::read(path).map_err(|err| format!("Cannot read {}: {err}", path.display()))?;
    String::from_utf8(bytes).map_err(|err| format!("{} is not UTF-8: {err}", path.display()))
}

fn write_text(path: &Path, text: &str) -> Result<(), String> {
    fs::write(path, text.as_bytes())
        .map_err(|err| format!("Cannot write {}: {err}", path.display()))
}

fn gjf_jar(quality_root: &Path, log: &mut Vec<String>) -> Result<PathBuf, String> {
    let tools = quality_root.join("tools");
    fs::create_dir_all(&tools)
        .map_err(|err| format!("Cannot create {}: {err}", tools.display()))?;
    let name = format!("google-java-format-{GJF_VERSION}-all-deps.jar");
    let path = tools.join(&name);
    if path.is_file() {
        return Ok(path);
    }
    log_line(log, format!("Downloading {name}"));
    let url = format!(
        "https://github.com/google/google-java-format/releases/download/v{GJF_VERSION}/{name}"
    );
    let partial = path.with_extension("part");
    let curl_ok = Command::new("curl")
        .args(["-fsSL", "--retry", "3", "-o"])
        .arg(&partial)
        .arg(&url)
        .status()
        .map(|status| status.success())
        .unwrap_or(false);
    let downloaded = curl_ok
        || Command::new("wget")
            .args(["-q", "-O"])
            .arg(&partial)
            .arg(&url)
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
    if !downloaded {
        let _ = fs::remove_file(&partial);
        return Err(format!(
            "Cannot download {url}. Install curl or wget and retry."
        ));
    }
    fs::rename(&partial, &path).map_err(|err| format!("Cannot save {name}: {err}"))?;
    Ok(path)
}

fn selected_paths(project: &Path, precommit: bool) -> Result<Vec<String>, String> {
    let mut names = Vec::new();
    if precommit {
        let (_, found) = git_lines(
            project,
            &[
                "-c",
                "core.quotepath=false",
                "diff",
                "--cached",
                "--name-only",
                "--diff-filter=ACMR",
            ],
        )?;
        names.extend(found);
    } else {
        let (_, found) = git_lines(
            project,
            &[
                "-c",
                "core.quotepath=false",
                "diff",
                "--name-only",
                "HEAD",
                "--diff-filter=ACMR",
            ],
        )?;
        names.extend(found);
        let (_, found) = git_lines(
            project,
            &[
                "-c",
                "core.quotepath=false",
                "ls-files",
                "--others",
                "--exclude-standard",
            ],
        )?;
        names.extend(found);
    }
    let mut java = Vec::new();
    for name in names {
        let path = name.replace('\\', "/");
        if is_selected_java(&path) && !java.contains(&path) {
            java.push(path);
        }
    }
    Ok(java)
}

fn diff_text(project: &Path, relative: &str, precommit: bool) -> Result<String, String> {
    let mut args = vec![
        "-c".to_string(),
        "core.quotepath=false".to_string(),
        "diff".to_string(),
    ];
    if precommit {
        args.push("--cached".to_string());
    } else {
        args.push("HEAD".to_string());
    }
    args.extend(["-U0".to_string(), "--".to_string(), relative.to_string()]);
    let output = crate::gitutil::git(project, &args)?;
    Ok(crate::gitutil::text_lines(&output.stdout).join("\n"))
}

pub fn format_changed(
    quality_root: &Path,
    project: &Path,
    mode: Mode,
    precommit: bool,
    log: &mut Vec<String>,
) -> Result<i32, String> {
    let paths = selected_paths(project, precommit)?;
    if paths.is_empty() {
        log_line(log, "No changed Java files to format.");
        return Ok(0);
    }
    for relative in &paths {
        let full = project.join(relative);
        if !full.is_file() {
            return Err(format!("Selected Java file does not exist: {relative}"));
        }
        if precommit {
            let (_, unstaged) = git_lines(project, &["diff", "--name-only", "--", relative])?;
            if unstaged.iter().any(|line| !line.trim().is_empty()) {
                return Err(format!(
                    "{relative} has edits that are not staged. Stage the file, then commit again."
                ));
            }
        }
    }

    let jar = gjf_jar(quality_root, log)?;
    let mut failed = false;
    let mut formatted_files = 0i32;

    for relative in &paths {
        let full = project.join(relative);
        let untracked =
            git_lines(project, &["ls-files", "--error-unmatch", "--", relative])?.0 != 0;
        let before_text = read_text(&full)?;
        let before_info = split_file_lines(&before_text);
        let (affected, ranges) = if untracked {
            if before_info.lines.is_empty() {
                continue;
            }
            let affected: Vec<i32> = (1..=before_info.lines.len() as i32).collect();
            let ranges = vec![format!("1:{}", before_info.lines.len())];
            (affected, ranges)
        } else {
            let diff = diff_text(project, relative, precommit)?;
            let affected = affected_line_numbers(&diff);
            if affected.is_empty() {
                continue;
            }
            let ranges = line_ranges(&affected);
            (affected, ranges)
        };
        if ranges.is_empty() {
            continue;
        }

        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        let temp = std::env::temp_dir().join(format!("gjf-{}-{nanos}.java", std::process::id()));
        let formatted = (|| -> Result<FileOutcome, String> {
            write_text(&temp, &before_text)?;
            let mut command = Command::new("java");
            command.arg("-jar").arg(&jar);
            if indentation_width(&before_text, &affected) == 4 {
                command.arg("--aosp");
            }
            command
                .arg("--skip-sorting-imports")
                .arg("--skip-removing-unused-imports");
            for range in &ranges {
                command.arg(format!("--lines={range}"));
            }
            command.arg("--replace").arg(&temp);
            log_line(
                log,
                format!("Formatting {} line range(s) in {relative}", ranges.len()),
            );
            let output = command
                .output()
                .map_err(|err| format!("Cannot run java: {err}"))?;
            for line in crate::gitutil::text_lines(&output.stdout)
                .into_iter()
                .chain(crate::gitutil::text_lines(&output.stderr))
            {
                log_line(log, line);
            }
            if !output.status.success() {
                return Ok(FileOutcome::Failed);
            }
            let after_text = read_text(&temp)?;
            let limited = limit_format_to_affected_lines(&before_text, &after_text, &affected)?;
            let changed = limited != before_text;
            if mode == Mode::Check {
                if changed {
                    log_line(
                        log,
                        format!("Formatting differs on changed lines in {relative}"),
                    );
                    return Ok(FileOutcome::Failed);
                }
                return Ok(FileOutcome::Clean);
            }
            if changed {
                write_text(&full, &limited)?;
                log_line(log, "  applied");
                return Ok(FileOutcome::Wrote);
            }
            Ok(FileOutcome::Clean)
        })();
        let _ = fs::remove_file(&temp);
        match formatted {
            Ok(FileOutcome::Failed) => failed = true,
            Ok(FileOutcome::Wrote) => formatted_files += 1,
            Ok(FileOutcome::Clean) => {}
            Err(err) => return Err(err),
        }
    }

    if mode == Mode::Apply {
        log_line(
            log,
            format!("Google Java Format apply finished on {formatted_files} file(s)."),
        );
    }
    Ok(if failed { 1 } else { 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_before() -> String {
        "package demo;\n\npublic class Sample {\nint x=1;\n    void changed() {\n        System.out.println(\"hello\");\n    }\n}\n".to_string()
    }

    #[test]
    fn split_keeps_distant_line() {
        let before = sample_before();
        let after = "package demo;\n\npublic class Sample {\n    int x = 1;\n    void changed() {\n        System.out.println(\n            \"hello\");\n    }\n}\n";
        let limited = limit_format_to_affected_lines(&before, after, &[6]).unwrap();
        let expected = "package demo;\n\npublic class Sample {\nint x=1;\n    void changed() {\n        System.out.println(\n            \"hello\");\n    }\n}\n";
        assert_eq!(limited, expected);
    }

    #[test]
    fn same_count_keeps_distant_line() {
        let before = sample_before();
        let after = before.replace(
            "System.out.println(\"hello\");",
            "System.out.println(\"hello world\");",
        );
        let limited = limit_format_to_affected_lines(&before, &after, &[6]).unwrap();
        assert_eq!(limited, after);
    }

    #[test]
    fn insertion_on_changed_line_stays() {
        let before = sample_before();
        let after = "package demo;\n\npublic class Sample {\nint x=1;\n    void changed() {\n        System.out.println(\"hello\");\n        int added = 1;\n    }\n}\n";
        let limited = limit_format_to_affected_lines(&before, after, &[6]).unwrap();
        assert_eq!(limited, after);
    }

    #[test]
    fn distant_insertion_dropped() {
        let before = sample_before();
        let after = "package demo;\n\npublic class Sample {\nint x=1;\n    int sneaked = 1;\n    void changed() {\n        System.out.println(\"hello\");\n    }\n}\n";
        let limited = limit_format_to_affected_lines(&before, after, &[6]).unwrap();
        assert_eq!(limited, before);
    }

    #[test]
    fn formatter_does_not_call_spotless() {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let pattern = Regex::new(&format!(
            "{}|{}|{}",
            ["spot", "less-maven-plugin"].concat(),
            ["com.", "diffplug"].concat(),
            ["google", "JavaFormat"].concat(),
        ))
        .unwrap();
        for relative in [
            "src/format.rs",
            "src/run.rs",
            "src/setup.rs",
            "run",
            "setup",
            "uninstall",
            "hook/pre-commit",
        ] {
            let text = fs::read_to_string(root.join(relative))
                .unwrap_or_else(|err| panic!("Cannot read {relative}: {err}"));
            assert!(!pattern.is_match(&text), "{relative} references Spotless");
        }
    }

    #[test]
    fn ranges_collapse_neighbors() {
        assert_eq!(
            line_ranges(&[3, 1, 2, 5]),
            vec!["1:3".to_string(), "5:5".to_string()]
        );
    }

    #[test]
    fn indentation_prefers_unchanged_lines() {
        let text = "class Example {\n    void example() {\n        try {\n            System.out.println(1);\n  } catch (RuntimeException e) {\n            System.out.println(2);\n        }\n    }\n}\n";
        assert_eq!(indentation_width(text, &[5]), 4);
        let two = text.replace("    ", "  ");
        assert_eq!(indentation_width(&two, &[5]), 2);
    }
}
