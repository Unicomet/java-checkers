use crate::gitutil::git_lines;
use crate::setup::normalize_newlines;
use regex::Regex;
use std::fs;
use std::path::{Path, PathBuf};

pub fn execute(checker_root: &Path, project: Option<&str>) -> Result<(), String> {
    let project = resolve_project(checker_root, project)?;
    if !project.join(".git").exists() {
        return Err(format!("Not a git repository: {}", project.display()));
    }
    let (hooks, exclude) = git_paths(&project)?;
    let installation = project.join(".local").join("quality");
    if installation.exists() && !recognized(&installation) {
        return Err(format!(
            "Refusing to remove an unrecognized directory: {}",
            installation.display()
        ));
    }
    let template =
        fs::read_to_string(checker_root.join("hook").join("pre-commit")).unwrap_or_default();
    let expected = normalize_newlines(&template);
    let hook = hooks.join("pre-commit");
    if hook.is_file() {
        let current = normalize_newlines(
            &fs::read_to_string(&hook)
                .map_err(|err| format!("Cannot read {}: {err}", hook.display()))?,
        );
        if current == expected {
            fs::remove_file(&hook)
                .map_err(|err| format!("Cannot remove {}: {err}", hook.display()))?;
            println!("Removed the checker pre-commit hook.");
        } else {
            println!(
                "Preserved an unrelated or modified pre-commit hook: {}",
                hook.display()
            );
        }
    }
    if installation.exists() {
        fs::remove_dir_all(&installation)
            .map_err(|err| format!("Cannot remove {}: {err}", installation.display()))?;
        println!("Removed {}", installation.display());
    }
    let local = project.join(".local");
    if local.is_dir() && directory_is_empty(&local)? {
        fs::remove_dir(&local)
            .map_err(|err| format!("Cannot remove {}: {err}", local.display()))?;
    }
    if !local.exists() && exclude.is_file() {
        let text = fs::read_to_string(&exclude)
            .map_err(|err| format!("Cannot read {}: {err}", exclude.display()))?;
        let pattern = Regex::new(r"(?m)^[ \t]*\.local/?[ \t]*(?:\r?\n|$)").unwrap();
        let updated = pattern.replace_all(&text, "").into_owned();
        fs::write(&exclude, updated)
            .map_err(|err| format!("Cannot write {}: {err}", exclude.display()))?;
    }
    println!("Local checker uninstall complete.");
    Ok(())
}

fn resolve_project(checker_root: &Path, project: Option<&str>) -> Result<PathBuf, String> {
    let Some(project) = project.filter(|value| !value.trim().is_empty()) else {
        return checker_root
            .join("..")
            .join("..")
            .canonicalize()
            .map_err(|err| format!("Cannot resolve the project path: {err}"));
    };
    Path::new(project)
        .canonicalize()
        .map_err(|err| format!("Project path does not exist: {project}: {err}"))
}

fn git_paths(project: &Path) -> Result<(PathBuf, PathBuf), String> {
    let (code, hooks) = git_lines(
        project,
        &["rev-parse", "--path-format=absolute", "--git-path", "hooks"],
    )?;
    if code != 0 || hooks.is_empty() {
        return Err("Cannot resolve Git hooks directory.".to_string());
    }
    let (code, exclude) = git_lines(
        project,
        &[
            "rev-parse",
            "--path-format=absolute",
            "--git-path",
            "info/exclude",
        ],
    )?;
    if code != 0 || exclude.is_empty() {
        return Err("Cannot resolve Git exclude file.".to_string());
    }
    Ok((PathBuf::from(&hooks[0]), PathBuf::from(&exclude[0])))
}

fn recognized(installation: &Path) -> bool {
    let marker = installation.join("run.ps1").is_file()
        || installation.join("java-checkers").is_file()
        || installation.join("java-checkers.exe").is_file()
        || installation.join("run").is_file();
    marker && installation.join("hook").join("pre-commit").is_file()
}

fn directory_is_empty(path: &Path) -> Result<bool, String> {
    let mut entries =
        fs::read_dir(path).map_err(|err| format!("Cannot read {}: {err}", path.display()))?;
    Ok(entries.next().is_none())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exclude_line_removal_restores_the_original_bytes() {
        let original = "# Keep this comment\r\nprivate-files/\r\n";
        let with_local = format!("{original}.local/\n");
        let pattern = Regex::new(r"(?m)^[ \t]*\.local/?[ \t]*(?:\r?\n|$)").unwrap();
        let updated = pattern.replace_all(&with_local, "").into_owned();
        assert_eq!(updated, original);
    }
}
