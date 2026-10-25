mod format;
mod gitutil;
mod pom;
mod run;
mod setup;
mod uninstall;

use format::Mode;
use run::Tool;
use std::env;
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    match dispatch() {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::from(1),
        Err(message) => {
            eprintln!("Runner error: {message}");
            ExitCode::from(1)
        }
    }
}

fn dispatch() -> Result<bool, String> {
    let mut args: Vec<String> = env::args().skip(1).collect();
    let command = if args
        .first()
        .is_some_and(|arg| arg == "setup" || arg == "uninstall" || arg == "run")
    {
        args.remove(0)
    } else if args.first().is_none_or(|arg| arg.starts_with('-')) {
        "run".to_string()
    } else {
        return Err(usage());
    };
    match command.as_str() {
        "setup" => {
            let (project, branch) = parse_setup(&args)?;
            setup::execute(&quality_root()?, project.as_deref(), branch.as_deref())?;
            Ok(true)
        }
        "uninstall" => {
            let project = parse_uninstall(&args)?;
            uninstall::execute(&quality_root()?, project.as_deref())?;
            Ok(true)
        }
        "run" => {
            let options = parse_run(&args)?;
            run::execute(&quality_root()?, &options)
        }
        _ => Err(usage()),
    }
}

fn usage() -> String {
    "Usage: java-checkers setup [project] [-Branch name] | uninstall [project] | run [-Tool all|format|checkstyle|spotbugs] [-Mode check|apply] [-PreCommit] [-All]".to_string()
}

fn quality_root() -> Result<PathBuf, String> {
    if let Ok(value) = env::var("JAVA_CHECKERS_QUALITY_ROOT") {
        if !value.trim().is_empty() {
            return Ok(PathBuf::from(value));
        }
    }
    let exe = env::current_exe().map_err(|err| format!("Cannot locate java-checkers: {err}"))?;
    let mut dir = exe
        .parent()
        .ok_or_else(|| "Cannot locate the checker installation.".to_string())?
        .to_path_buf();
    if let Some(parent) = dir.parent() {
        if (dir.ends_with("debug") || dir.ends_with("release")) && parent.ends_with("target") {
            if let Some(repo) = parent.parent() {
                dir = repo.to_path_buf();
            }
        }
    }
    for _ in 0..6 {
        if dir.join("checkstyle.xml").is_file() && dir.join("hook").join("pre-commit").is_file() {
            return Ok(dir);
        }
        if !dir.pop() {
            break;
        }
    }
    Err("Cannot find the checker installation. Set JAVA_CHECKERS_QUALITY_ROOT.".to_string())
}

fn parse_setup(args: &[String]) -> Result<(Option<String>, Option<String>), String> {
    let mut project = None;
    let mut branch = None;
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if flag(arg, "branch") {
            branch = Some(require_value(args, &mut index, "-Branch")?);
        } else if arg.starts_with('-') {
            return Err(format!("Unknown setup option: {arg}\n{}", usage()));
        } else if project.is_none() {
            project = Some(arg.clone());
        } else {
            return Err(format!("Unexpected setup argument: {arg}"));
        }
        index += 1;
    }
    Ok((project, branch))
}

fn parse_uninstall(args: &[String]) -> Result<Option<String>, String> {
    let mut project = None;
    for arg in args {
        if arg.starts_with('-') {
            return Err(format!("Unknown uninstall option: {arg}\n{}", usage()));
        }
        if project.is_some() {
            return Err(format!("Unexpected uninstall argument: {arg}"));
        }
        project = Some(arg.clone());
    }
    Ok(project)
}

fn parse_run(args: &[String]) -> Result<run::RunOptions, String> {
    let mut mode = Mode::Check;
    let mut tool = Tool::All;
    let mut all = false;
    let mut precommit = false;
    let mut index = 0;
    while index < args.len() {
        let arg = &args[index];
        if flag(arg, "mode") {
            mode = match require_value(args, &mut index, "-Mode")?
                .to_ascii_lowercase()
                .as_str()
            {
                "check" => Mode::Check,
                "apply" => Mode::Apply,
                other => return Err(format!("-Mode must be check or apply, not {other}")),
            };
        } else if flag(arg, "tool") {
            tool = match require_value(args, &mut index, "-Tool")?
                .to_ascii_lowercase()
                .as_str()
            {
                "all" => Tool::All,
                "format" => Tool::Format,
                "checkstyle" => Tool::Checkstyle,
                "spotbugs" => Tool::Spotbugs,
                other => {
                    return Err(format!(
                        "-Tool must be all, format, checkstyle, or spotbugs, not {other}"
                    ))
                }
            };
        } else if flag(arg, "precommit") || flag(arg, "pre-commit") {
            precommit = true;
        } else if flag(arg, "all") {
            all = true;
        } else {
            return Err(format!("Unknown run option: {arg}\n{}", usage()));
        }
        index += 1;
    }
    Ok(run::RunOptions {
        mode,
        tool,
        all,
        precommit,
    })
}

fn flag(arg: &str, name: &str) -> bool {
    let trimmed = arg.trim_start_matches('-');
    trimmed.eq_ignore_ascii_case(name)
}

fn require_value(args: &[String], index: &mut usize, name: &str) -> Result<String, String> {
    let next = args
        .get(*index + 1)
        .ok_or_else(|| format!("{name} needs a value"))?;
    if next.starts_with('-') {
        return Err(format!("{name} needs a value"));
    }
    *index += 1;
    Ok(next.clone())
}
