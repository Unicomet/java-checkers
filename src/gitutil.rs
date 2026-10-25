use std::path::Path;
use std::process::{Command, Output};

pub fn status_code(output: &Output) -> i32 {
    output.status.code().unwrap_or(1)
}

pub fn text_lines(bytes: &[u8]) -> Vec<String> {
    let text = String::from_utf8_lossy(bytes);
    let mut lines: Vec<String> = text
        .split('\n')
        .map(|line| line.trim_end_matches('\r').to_string())
        .collect();
    if lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    lines
}

pub fn non_empty_stdout(output: &Output) -> Vec<String> {
    text_lines(&output.stdout)
        .into_iter()
        .filter(|line| !line.is_empty())
        .collect()
}

pub fn git(cwd: &Path, args: &[String]) -> Result<Output, String> {
    Command::new("git")
        .arg("-C")
        .arg(cwd)
        .args(args)
        .output()
        .map_err(|err| format!("git {}: {err}", args.join(" ")))
}

pub fn git_lines(cwd: &Path, args: &[&str]) -> Result<(i32, Vec<String>), String> {
    let owned: Vec<String> = args.iter().map(|arg| (*arg).to_string()).collect();
    let output = git(cwd, &owned)?;
    Ok((status_code(&output), non_empty_stdout(&output)))
}

pub fn run_inherit_logged(command: &mut Command) -> Result<(i32, Vec<String>), String> {
    let program = command.get_program().to_string_lossy().to_string();
    let output = command
        .output()
        .map_err(|err| format!("Cannot run {program}: {err}"))?;
    let mut lines = text_lines(&output.stdout);
    lines.extend(text_lines(&output.stderr));
    for line in &lines {
        println!("{line}");
    }
    Ok((status_code(&output), lines))
}

pub fn log_line(lines: &mut Vec<String>, line: impl AsRef<str>) {
    let line = line.as_ref();
    println!("{line}");
    lines.push(line.to_string());
}

pub fn set_executable(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = std::fs::metadata(path)
            .map_err(|err| format!("Cannot read permissions for {}: {err}", path.display()))?
            .permissions();
        permissions.set_mode(permissions.mode() | 0o755);
        std::fs::set_permissions(path, permissions)
            .map_err(|err| format!("Cannot make {} executable: {err}", path.display()))?;
    }
    let _ = path;
    Ok(())
}

pub fn same_path(left: &Path, right: &Path) -> bool {
    let normalize = |path: &Path| {
        path.to_string_lossy()
            .trim_end_matches(['/', '\\'])
            .to_string()
    };
    normalize(left).eq_ignore_ascii_case(&normalize(right))
}
