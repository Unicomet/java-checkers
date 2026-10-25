use crate::format::{self, Mode};
use crate::gitutil::{git_lines, log_line, run_inherit_logged};
use crate::pom::{self, class_name, relative_java_path, xml_escape};
use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Tool {
    All,
    Format,
    Checkstyle,
    Spotbugs,
}

pub struct RunOptions {
    pub mode: Mode,
    pub tool: Tool,
    pub all: bool,
    pub precommit: bool,
}

struct Failure {
    name: String,
    code: i32,
    output: Vec<String>,
}

pub fn project_root(quality_root: &Path) -> Result<PathBuf, String> {
    let root = quality_root.join("..").join("..");
    root.canonicalize().map_err(|err| {
        format!(
            "Cannot resolve the project root from {}: {err}",
            quality_root.display()
        )
    })
}

pub fn execute(quality_root: &Path, options: &RunOptions) -> Result<bool, String> {
    if options.all {
        println!(
            "Google Java Format only edits Git-changed line ranges; -All does not expand its scope."
        );
    }
    let project = project_root(quality_root)?;
    std::env::set_current_dir(&project)
        .map_err(|err| format!("Cannot enter {}: {err}", project.display()))?;
    let quality_pom = project.join(".quality-pom.xml");
    let outcome = run_checks(quality_root, &project, options);
    if quality_pom.exists() {
        let _ = fs::remove_file(&quality_pom);
    }
    outcome
}

fn run_checks(quality_root: &Path, project: &Path, options: &RunOptions) -> Result<bool, String> {
    let gradle = is_gradle(project);
    let mut java_files = Vec::new();
    let mut include_tests = "false";
    if options.precommit {
        java_files = staged_java(project, gradle)?;
        if java_files.is_empty() {
            println!("No staged Java files. Checkstyle, SpotBugs, and the formatter were skipped.");
            return Ok(true);
        }
        for path in &java_files {
            let (_, unstaged) = git_lines(project, &["diff", "--name-only", "--", path])?;
            if !unstaged.is_empty() {
                return Err(format!(
                    "{path} has edits that are not staged. Stage the file, then commit again."
                ));
            }
        }
        if java_files.iter().any(|path| is_test_source(path)) {
            include_tests = "true";
        }
        println!("Checking {} staged Java file(s).", java_files.len());
    }

    let run_format = matches!(options.tool, Tool::All | Tool::Format);
    let run_checkstyle = matches!(options.tool, Tool::All | Tool::Checkstyle);
    let run_spotbugs = matches!(options.tool, Tool::All | Tool::Spotbugs);
    let mut failures = Vec::new();

    if run_format {
        println!("Running Google Java Format on changed lines");
        let mut format_mode = options.mode;
        let auto_format = options.precommit && options.tool == Tool::All;
        if auto_format {
            format_mode = Mode::Apply;
        }
        let mut output = Vec::new();
        let code = match format::format_changed(
            quality_root,
            project,
            format_mode,
            options.precommit,
            &mut output,
        ) {
            Ok(code) => {
                if auto_format && code == 0 {
                    if let Err(err) = stage_formatting(project, &java_files, &mut output) {
                        output.push(err);
                        1
                    } else {
                        code
                    }
                } else {
                    code
                }
            }
            Err(err) => {
                log_line(&mut output, err);
                1
            }
        };
        record("Google Java Format", code, output, &mut failures);
    }

    if (run_checkstyle || run_spotbugs) && !gradle {
        if !project.join("pom.xml").is_file() {
            return Err(
                "No Maven pom.xml or Gradle build/settings file found in the project root."
                    .to_string(),
            );
        }
        let mut snippet = fs::read_to_string(quality_root.join("plugins.xml"))
            .map_err(|err| format!("Cannot read plugins.xml: {err}"))?;
        if options.precommit {
            snippet = scope_maven_snippet(&snippet, &java_files, include_tests);
        }
        let pom = fs::read_to_string(project.join("pom.xml"))
            .map_err(|err| format!("Cannot read pom.xml: {err}"))?;
        let quality = pom::inject_plugins(&pom, &snippet)?;
        fs::write(project.join(".quality-pom.xml"), quality)
            .map_err(|err| format!("Cannot write .quality-pom.xml: {err}"))?;
    }

    if run_checkstyle {
        if gradle {
            println!("Running Gradle qualityCheckstyle");
            record_command(
                "Checkstyle",
                &mut gradle_command(
                    project,
                    quality_root,
                    options.precommit,
                    &java_files,
                    "qualityCheckstyle",
                ),
                &mut failures,
            )?;
        } else {
            println!("Running checkstyle:check");
            record_command(
                "Checkstyle",
                &mut maven_command(project, &["checkstyle:check"]),
                &mut failures,
            )?;
        }
    }
    if run_spotbugs {
        if gradle {
            println!("Running Gradle qualitySpotbugs");
            record_command(
                "SpotBugs",
                &mut gradle_command(
                    project,
                    quality_root,
                    options.precommit,
                    &java_files,
                    "qualitySpotbugs",
                ),
                &mut failures,
            )?;
        } else {
            println!("Running spotbugs:check");
            let compile = if include_tests == "true" {
                "test-compile"
            } else {
                "compile"
            };
            record_command(
                "SpotBugs",
                &mut maven_command(project, &["-DskipTests", compile, "spotbugs:check"]),
                &mut failures,
            )?;
        }
    }

    if failures.is_empty() {
        return Ok(true);
    }
    println!();
    let names = failures
        .iter()
        .map(|failure| failure.name.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    println!("Failed checks: {names}");
    for failure in &failures {
        println!(
            "--- {}: failure details (exit code {}) ---",
            failure.name, failure.code
        );
        for line in &failure.output {
            println!("{line}");
        }
    }
    if options.precommit {
        println!("Commit blocked. Stage the fixes and commit again.");
        if failures
            .iter()
            .any(|failure| failure.name == "Google Java Format")
        {
            println!(
                "To format the changed lines: ./.local/quality/run -Tool format -Mode apply -PreCommit"
            );
        }
        println!("To skip once: set SKIP_LOCAL_CHECKS=1 and commit again.");
    }
    Ok(false)
}

fn record(name: &str, code: i32, output: Vec<String>, failures: &mut Vec<Failure>) {
    if code != 0 {
        println!("FAILED: {name} (exit code {code})");
        failures.push(Failure {
            name: name.to_string(),
            code,
            output,
        });
    } else {
        println!("PASSED: {name}");
    }
}

fn record_command(
    name: &str,
    command: &mut Command,
    failures: &mut Vec<Failure>,
) -> Result<(), String> {
    match run_inherit_logged(command) {
        Ok((code, output)) => record(name, code, output, failures),
        Err(err) => record(name, 1, vec![err], failures),
    }
    Ok(())
}

fn stage_formatting(
    project: &Path,
    java_files: &[String],
    output: &mut Vec<String>,
) -> Result<(), String> {
    for path in java_files {
        let (code, changes) = git_lines(project, &["diff", "--name-only", "--", path])?;
        if code != 0 {
            return Err(format!("Cannot inspect formatting changes in {path}"));
        }
        if !changes.is_empty() {
            let (add_code, _) = git_lines(project, &["add", "--", path])?;
            if add_code != 0 {
                return Err(format!("Cannot stage formatting changes in {path}"));
            }
            log_line(output, format!("Staged formatting fixes in {path}"));
        }
    }
    Ok(())
}

fn is_gradle(project: &Path) -> bool {
    [
        "build.gradle",
        "build.gradle.kts",
        "settings.gradle",
        "settings.gradle.kts",
    ]
    .iter()
    .any(|name| project.join(name).is_file())
}

fn strict_java_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^src/(main|test)/java/.+\.java$").unwrap())
}

fn staged_java(project: &Path, gradle: bool) -> Result<Vec<String>, String> {
    let (_, names) = git_lines(
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
    let mut java = Vec::new();
    for name in names {
        let path = name.trim().replace('\\', "/");
        let selected =
            strict_java_re().is_match(&path) || (gradle && format::is_selected_java(&path));
        if selected && !path.contains("/notification/avro/") {
            java.push(path);
        }
    }
    Ok(java)
}

fn is_test_source(path: &str) -> bool {
    path.replace('\\', "/")
        .to_ascii_lowercase()
        .starts_with("src/test/java/")
}

fn scope_maven_snippet(snippet: &str, java_files: &[String], include_tests: &str) -> String {
    let includes = java_files
        .iter()
        .map(|path| xml_escape(&relative_java_path(path)))
        .collect::<Vec<_>>()
        .join(",");
    let mut names = Vec::new();
    for path in java_files {
        let class = class_name(path);
        names.push(class.clone());
        names.push(format!("{class}$[^/]*"));
    }
    let only = xml_escape(&names.join(","));
    snippet
        .replace(
            "<excludes>**/notification/avro/**</excludes>",
            &format!(
                "<includes>{includes}</includes>\n          <excludes>**/notification/avro/**</excludes>"
            ),
        )
        .replace(
            "<includeTests>false</includeTests>",
            &format!(
                "<includeTests>{include_tests}</includeTests>\n          <onlyAnalyze>{only}</onlyAnalyze>"
            ),
        )
}

fn gradle_command(
    project: &Path,
    quality_root: &Path,
    precommit: bool,
    java_files: &[String],
    task: &str,
) -> Command {
    let wrapper_name = if cfg!(windows) {
        "gradlew.bat"
    } else {
        "gradlew"
    };
    let wrapper = project.join(wrapper_name);
    let program: PathBuf = if wrapper.is_file() {
        wrapper
    } else {
        PathBuf::from("gradle")
    };
    let mut command = Command::new(program);
    command
        .current_dir(project)
        .arg("--no-daemon")
        .arg("--console=plain")
        .arg("--no-configuration-cache")
        .arg("--stacktrace")
        .arg("--init-script")
        .arg(quality_root.join("quality.init.gradle"))
        .arg(format!("-PqualityRoot={}", quality_root.display()))
        .arg(format!(
            "-PqualityPreCommit={}",
            if precommit { "true" } else { "false" }
        ))
        .arg(format!("-PqualityFiles={}", java_files.join(",")))
        .arg(task);
    command
}

fn maven_command(project: &Path, goals: &[&str]) -> Command {
    let mut command = Command::new("mvn");
    command.current_dir(project).arg("-B").arg("-e");
    if project.join(".mvn/settings.xml").is_file() {
        command.arg("-s").arg(".mvn/settings.xml");
    }
    command.arg("-f").arg(".quality-pom.xml");
    command.args(goals);
    command
}
