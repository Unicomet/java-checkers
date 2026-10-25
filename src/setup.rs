use crate::gitutil::{git_lines, same_path, set_executable};
use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

const COPIED_FILES: &[&str] = &[
    "run",
    "run.cmd",
    "setup",
    "setup.cmd",
    "uninstall",
    "uninstall.cmd",
    "plugins.xml",
    "quality.init.gradle",
    "checkstyle.xml",
    "spotbugs-exclude.xml",
    "README.md",
    ".gitattributes",
    "AGENTS.md",
    "Cargo.toml",
    "Cargo.lock",
];

pub fn execute(
    checker_root: &Path,
    project: Option<&str>,
    branch: Option<&str>,
) -> Result<(), String> {
    let project = resolve_project(checker_root, project)?;
    if !project.join(".git").exists() {
        return Err(format!("Not a git repository: {}", project.display()));
    }
    let destination = project.join(".local").join("quality");
    let checker_full = checker_root
        .canonicalize()
        .map_err(|err| format!("Cannot resolve the checker checkout: {err}"))?;
    let destination_full = destination.canonicalize().ok();
    let created_install = if destination_full
        .as_ref()
        .is_some_and(|path| same_path(path, &checker_full))
    {
        println!("Checkers are already in this project.");
        false
    } else if destination_full.is_some() && is_checker_install(&destination) {
        println!("Checkers are already installed.");
        false
    } else if destination.exists() {
        return Err(format!("Refusing to overwrite {}", destination.display()));
    } else {
        install_checkers(&checker_full, &destination, branch)?;
        true
    };
    if let Err(err) = install_hook(&project, &destination.join("hook").join("pre-commit")) {
        if created_install {
            remove_failed_install(&destination);
        }
        return Err(err);
    }
    add_local_exclude(&project)?;
    println!(
        "From the project root, run ./.local/quality/run (Windows: .\\.local\\quality\\run.cmd)"
    );
    println!(
        "The pre-commit hook runs the formatter, Checkstyle, and SpotBugs on staged Java files."
    );
    Ok(())
}

fn resolve_project(checker_root: &Path, project: Option<&str>) -> Result<PathBuf, String> {
    let Some(project) = project.filter(|value| !value.trim().is_empty()) else {
        let maybe = checker_root.join("..").join("..");
        let maybe = maybe.canonicalize().map_err(|_| {
            "Pass the project path. Example: .\\setup.cmd C:\\path\\to\\project".to_string()
        })?;
        if maybe.join(".git").exists() {
            return Ok(maybe);
        }
        return Err(
            "Pass the project path. Example: .\\setup.cmd C:\\path\\to\\project".to_string(),
        );
    };
    if !Path::new(project).exists() {
        return Err(format!("Project path does not exist: {project}"));
    }
    Path::new(project)
        .canonicalize()
        .map_err(|err| format!("Project path does not exist: {project}: {err}"))
}

fn is_checker_install(path: &Path) -> bool {
    path.join("run").is_file()
        || path.join("run.ps1").is_file()
        || path.join("java-checkers").is_file()
        || path.join("java-checkers.exe").is_file()
}

fn origin_url(checker_root: &Path) -> String {
    git_lines(checker_root, &["remote", "get-url", "origin"])
        .ok()
        .filter(|(code, _)| *code == 0)
        .and_then(|(_, lines)| lines.into_iter().next())
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn install_checkers(
    checker_root: &Path,
    destination: &Path,
    branch: Option<&str>,
) -> Result<(), String> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Cannot create {}: {err}", parent.display()))?;
    }
    let origin = origin_url(checker_root);
    if !origin.is_empty() {
        let mut command = Command::new("git");
        command.arg("clone");
        if let Some(branch) = branch.filter(|value| !value.is_empty()) {
            command.arg("--branch").arg(branch);
        }
        command.arg(&origin).arg(destination);
        let status = command
            .status()
            .map_err(|err| format!("git clone failed: {err}"))?;
        if !status.success() {
            return Err("git clone failed.".to_string());
        }
        copy_binary(destination)?;
        mark_launchers(destination)?;
        println!("Cloned the checkers into {}", destination.display());
        return Ok(());
    }
    copy_checker_files(checker_root, destination)?;
    copy_binary(destination)?;
    mark_launchers(destination)?;
    println!("Copied the checkers into {}", destination.display());
    println!("This checkout has no origin remote, so the copy has no git history.");
    Ok(())
}

fn copy_checker_files(checker_root: &Path, destination: &Path) -> Result<(), String> {
    fs::create_dir_all(destination)
        .map_err(|err| format!("Cannot create {}: {err}", destination.display()))?;
    for name in COPIED_FILES {
        let source = checker_root.join(name);
        if source.is_file() {
            let target = destination.join(name);
            fs::copy(&source, &target).map_err(|err| format!("Cannot copy {name}: {err}"))?;
        }
    }
    for name in ["run", "setup", "uninstall"] {
        let path = destination.join(name);
        if path.is_file() {
            set_executable(&path)?;
        }
    }
    copy_dir(&checker_root.join("hook"), &destination.join("hook"))?;
    copy_dir(&checker_root.join("src"), &destination.join("src"))?;
    let examples = checker_root.join("examples");
    if examples.is_dir() {
        copy_dir(&examples, &destination.join("examples"))?;
    }
    Ok(())
}

fn copy_dir(source: &Path, destination: &Path) -> Result<(), String> {
    if !source.is_dir() {
        return Ok(());
    }
    fs::create_dir_all(destination)
        .map_err(|err| format!("Cannot create {}: {err}", destination.display()))?;
    for entry in
        fs::read_dir(source).map_err(|err| format!("Cannot read {}: {err}", source.display()))?
    {
        let entry = entry.map_err(|err| format!("Cannot read {}: {err}", source.display()))?;
        let target = destination.join(entry.file_name());
        let file_type = entry
            .file_type()
            .map_err(|err| format!("Cannot inspect {}: {err}", entry.path().display()))?;
        if file_type.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else if file_type.is_file() {
            fs::copy(entry.path(), &target).map_err(|err| {
                format!(
                    "Cannot copy {} to {}: {err}",
                    entry.path().display(),
                    target.display()
                )
            })?;
        }
    }
    Ok(())
}

fn mark_launchers(destination: &Path) -> Result<(), String> {
    for name in ["run", "setup", "uninstall", "hook/pre-commit"] {
        let path = destination.join(name);
        if path.is_file() {
            set_executable(&path)?;
        }
    }
    Ok(())
}

fn copy_binary(destination: &Path) -> Result<(), String> {
    let current =
        std::env::current_exe().map_err(|err| format!("Cannot locate java-checkers: {err}"))?;
    let name = if cfg!(windows) {
        "java-checkers.exe"
    } else {
        "java-checkers"
    };
    let target = destination.join(name);
    if same_path(&current, &target) {
        return Ok(());
    }
    fs::copy(&current, &target)
        .map_err(|err| format!("Cannot install the java-checkers binary: {err}"))?;
    set_executable(&target)
}

fn remove_failed_install(destination: &Path) {
    let _ = fs::remove_dir_all(destination);
    let Some(local) = destination.parent() else {
        return;
    };
    let empty = local
        .read_dir()
        .ok()
        .and_then(|mut entries| entries.next())
        .is_none();
    if empty {
        let _ = fs::remove_dir(local);
    }
}

fn add_local_exclude(project: &Path) -> Result<(), String> {
    let (code, lines) = git_lines(
        project,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "info/exclude",
        ],
    )?;
    if code != 0 || lines.is_empty() {
        return Err("Cannot resolve Git exclude file.".to_string());
    }
    let exclude = PathBuf::from(&lines[0]);
    if let Some(parent) = exclude.parent() {
        fs::create_dir_all(parent)
            .map_err(|err| format!("Cannot create {}: {err}", parent.display()))?;
    }
    let mut text = if exclude.is_file() {
        fs::read_to_string(&exclude)
            .map_err(|err| format!("Cannot read {}: {err}", exclude.display()))?
    } else {
        String::new()
    };
    for line in text.split('\n') {
        let trimmed = line.trim().trim_end_matches('\r');
        if trimmed == ".local/" || trimmed == ".local" {
            println!(".git/info/exclude already ignores .local/.");
            return Ok(());
        }
    }
    if !text.is_empty() && !text.ends_with('\n') {
        text.push('\n');
    }
    text.push_str(".local/\n");
    fs::write(&exclude, text)
        .map_err(|err| format!("Cannot write {}: {err}", exclude.display()))?;
    println!("Added .local/ to .git/info/exclude.");
    Ok(())
}

pub fn normalize_newlines(text: &str) -> String {
    let mut text = text.replace("\r\n", "\n").replace('\r', "\n");
    if !text.ends_with('\n') {
        text.push('\n');
    }
    text
}

fn install_hook(project: &Path, hook_source: &Path) -> Result<(), String> {
    if !hook_source.is_file() {
        return Err(format!(
            "Hook template is missing: {}",
            hook_source.display()
        ));
    }
    let (code, lines) = git_lines(
        project,
        &["rev-parse", "--path-format=absolute", "--git-path", "hooks"],
    )?;
    if code != 0 || lines.is_empty() {
        return Err("Cannot resolve Git hooks directory.".to_string());
    }
    let hooks = PathBuf::from(&lines[0]);
    fs::create_dir_all(&hooks)
        .map_err(|err| format!("Cannot create {}: {err}", hooks.display()))?;
    let destination = hooks.join("pre-commit");
    let text = normalize_newlines(
        &fs::read_to_string(hook_source)
            .map_err(|err| format!("Cannot read {}: {err}", hook_source.display()))?,
    );
    if destination.is_file() {
        let current = normalize_newlines(
            &fs::read_to_string(&destination)
                .map_err(|err| format!("Cannot read {}: {err}", destination.display()))?,
        );
        if current == text {
            set_executable(&destination)?;
            println!("Pre-commit hook is already installed.");
            return Ok(());
        }
        let owned = Regex::new(r"\.local/quality/run(\.(cmd|ps1))?|java-checkers").unwrap();
        if owned.is_match(&current) {
            fs::write(&destination, &text)
                .map_err(|err| format!("Cannot write {}: {err}", destination.display()))?;
            set_executable(&destination)?;
            println!("Updated the pre-commit hook.");
            return Ok(());
        }
        return Err(format!(
            "A pre-commit hook already exists and was left unchanged: {}",
            destination.display()
        ));
    }
    fs::write(&destination, &text)
        .map_err(|err| format!("Cannot write {}: {err}", destination.display()))?;
    set_executable(&destination)?;
    println!("Installed the pre-commit hook. It runs the formatter, Checkstyle, and SpotBugs.");
    Ok(())
}
