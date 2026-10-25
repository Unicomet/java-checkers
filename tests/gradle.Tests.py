"""Real Gradle setup/hook verification. Needs Gradle on PATH to generate a wrapper."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SOURCE = Path(__file__).resolve().parents[1]
TRANSCRIPT = []


def run(*args, cwd, ok=True):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    TRANSCRIPT.append('$ ' + ' '.join(map(str, args)) + '\n' + result.stdout + result.stderr)
    if ok and result.returncode:
        raise AssertionError(TRANSCRIPT[-1])
    return result


def verify(root, kotlin=False):
    checker = root / 'checker'
    shutil.copytree(SOURCE, checker, ignore=shutil.ignore_patterns('.git', 'mise.toml', '__pycache__'))
    run('git', 'init', cwd=checker)
    run('git', 'config', 'user.name', 'Checker verification', cwd=checker)
    run('git', 'config', 'user.email', 'checkers@example.com', cwd=checker)
    run('git', 'add', '.', cwd=checker)
    run('git', 'commit', '-m', 'Checker snapshot under test', cwd=checker)
    run('git', 'remote', 'add', 'origin', str(checker), cwd=checker)
    project = root / 'Gradle project with spaces'
    shutil.copytree(SOURCE / 'examples/gradle', project)
    if kotlin:
        (project / 'build.gradle').unlink()
        (project / 'build.gradle.kts').write_text('plugins { java }\n')
        (project / 'settings.gradle').rename(project / 'settings.gradle.kts')
        (project / 'settings.gradle.kts').write_text('rootProject.name = "checker-verification"\ninclude("app")\n')
        (project / 'app').mkdir()
        (project / 'build.gradle.kts').rename(project / 'app/build.gradle.kts')
        (project / 'src').rename(project / 'app/src')
    run('gradle', '--no-daemon', 'wrapper', '--gradle-version', os.environ.get('QUALITY_GRADLE_VERSION', '8.14.3'), cwd=project)
    (project / '.gitignore').write_text('.gradle/\nbuild/\n')
    run('git', 'init', cwd=project)
    run('git', 'config', 'user.name', 'Checker verification', cwd=project)
    run('git', 'config', 'user.email', 'checkers@example.com', cwd=project)
    run('git', 'add', '.', cwd=project)
    run('git', 'commit', '-m', 'Initial Gradle project', cwd=project)
    run(str(checker / 'setup'), str(project), cwd=checker)
    run(str(checker / 'setup'), str(project), cwd=checker)
    runner = str(project / '.local/quality/run')
    module = project / 'app' if kotlin else project
    java = module / 'src/main/java/demo/Example.java'
    java.write_text(java.read_text().replace('return "Hello";', 'return   "Hello Gradle";'))
    run('git', 'add', '.', cwd=project)
    formatted = run('git', 'commit', '-m', 'Automatically format staged Java changes', cwd=project)
    assert 'Staged formatting fixes' in formatted.stdout + formatted.stderr
    assert 'return "Hello Gradle";' in java.read_text()
    committed = run('git', 'show', 'HEAD:' + java.relative_to(project).as_posix(), cwd=project)
    assert 'return "Hello Gradle";' in committed.stdout
    assert not run('git', 'diff', 'HEAD', '--', str(java), cwd=project).stdout
    # Stage a nested-class bug; an untracked bug must never appear in the report.
    staged = java.parent / 'Staged.java'
    bad = '''package demo;
/** SpotBugs regression fixture. */
public final class Staged {
  private Staged() {}
  /** Nested class fixture. */
  public static final class Nested {
    private Nested() {}
    /** Compares a value. */
    public static boolean broken(String value) {
      return value == "bad";
    }
  }
}
'''
    staged.write_text(bad)
    (java.parent / 'Unstaged.java').write_text(bad.replace('Staged', 'Unstaged'))
    run('git', 'add', str(staged), cwd=project)
    failed = run(runner, '-Tool', 'spotbugs', '-PreCommit', cwd=project, ok=False)
    assert failed.returncode != 0
    report = ET.parse(module / 'build/reports/local-quality/spotbugs.xml')
    classes = {bug.find('Class').get('classname') for bug in report.findall('BugInstance')}
    assert classes == {'demo.Staged$Nested'}, classes
    # Checkstyle must block a staged violation as well.
    staged.write_text(bad.replace('value == "bad"', '"bad".equals(value)').replace('boolean broken', 'boolean BAD_NAME'))
    run('git', 'add', str(staged), cwd=project)
    failed = run(runner, '-Tool', 'checkstyle', '-PreCommit', cwd=project, ok=False)
    assert failed.returncode != 0 and 'BAD_NAME' in failed.stdout + failed.stderr
    staged.write_text(bad.replace('value == "bad"', '"bad".equals(value)'))
    run('git', 'add', str(staged), cwd=project)
    run(runner, '-Tool', 'format', '-Mode', 'apply', '-PreCommit', cwd=project)
    run('git', 'add', str(staged), cwd=project)
    commit = run('git', 'commit', '-m', 'Verify formatting, Checkstyle and SpotBugs on Gradle', cwd=project)
    assert all(label in commit.stdout + commit.stderr for label in ('Running Google Java Format', 'qualityCheckstyle', 'qualitySpotbugs'))
    run('git', 'show', '--stat', '--oneline', 'HEAD', cwd=project)
    # Normal mode must detect the untracked bug that pre-commit ignored.
    failed = run(runner, '-Tool', 'spotbugs', cwd=project, ok=False)
    assert failed.returncode != 0
    # Check-only invocations leave the original build scripts untouched.
    assert not run('git', 'diff', '--exit-code', cwd=project).stdout
    (java.parent / 'Unstaged.java').unlink()
    run(runner, cwd=project)
    # Without a wrapper the runner must fall back to Gradle on PATH.
    (project / 'gradlew').rename(project / 'gradlew.saved')
    try:
        run(runner, '-Tool', 'checkstyle', cwd=project)
    finally:
        (project / 'gradlew.saved').rename(project / 'gradlew')
    print('PASS real Gradle ' + ('Kotlin' if kotlin else 'Groovy') + ' setup, wrapper, formatting, lint failures, staged nested classes and hook commit')


try:
    for kotlin in (False, True):
        if os.environ.get('QUALITY_PROJECT_ROOT'):
            root = Path(os.environ['QUALITY_PROJECT_ROOT']) / ('kotlin' if kotlin else 'groovy')
            root.mkdir(parents=True)
            verify(root, kotlin=kotlin)
        else:
            with tempfile.TemporaryDirectory(prefix='gradle-checkers-') as temp:
                verify(Path(temp), kotlin=kotlin)
finally:
    if os.environ.get('QUALITY_EVIDENCE'):
        Path(os.environ['QUALITY_EVIDENCE']).write_text('\n'.join(TRANSCRIPT))
