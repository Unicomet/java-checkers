"""Feature checks that sit beside the larger integration suites."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd, env=None, ok=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


def binary():
    for candidate in (
        SOURCE / 'java-checkers',
        SOURCE / 'target' / 'release' / 'java-checkers',
        SOURCE / 'target' / 'debug' / 'java-checkers',
    ):
        if candidate.is_file():
            return candidate
    raise SystemExit('Build java-checkers before running feature tests')


with tempfile.TemporaryDirectory(prefix='checker features ') as temp:
    root = Path(temp)
    checker = root / 'checker'
    shutil.copytree(
        SOURCE,
        checker,
        ignore=shutil.ignore_patterns('.git', 'mise.toml', 'target', '__pycache__'),
    )
    if not (checker / 'java-checkers').is_file():
        shutil.copy2(binary(), checker / 'java-checkers')
        (checker / 'java-checkers').chmod(0o755)
    project = root / 'project'
    project.mkdir()
    run('git', 'init', cwd=project)
    run('git', 'config', 'user.email', 'test@example.com', cwd=project)
    run('git', 'config', 'user.name', 'Test', cwd=project)
    (project / 'pom.xml').write_text('<project/>\n')
    java = project / 'src/main/java/demo/Example.java'
    java.parent.mkdir(parents=True)
    java.write_text('package demo;\n\nclass Example {\n  int value = 1;\n}\n')
    run('git', 'add', '.', cwd=project)
    run('git', 'commit', '-m', 'Initial', cwd=project)
    run(str(checker / 'setup'), str(project), cwd=checker)
    runner = project / '.local/quality/run'
    # -All is a notice. It does not select more lines, and a clean tree still passes.
    noticed = run(str(runner), '-All', '-Tool', 'format', cwd=project)
    assert 'does not expand its scope' in noticed.stdout
    assert 'No changed Java files to format.' in noticed.stdout
    # Check mode reports the changed line and leaves the file bytes alone.
    original = java.read_bytes()
    java.write_text(java.read_text().replace('int value = 1;', 'int   value=3;'))
    dirty = java.read_bytes()
    run('git', 'add', str(java), cwd=project)
    checked = run(str(runner), '-Tool', 'format', '-Mode', 'check', '-PreCommit', cwd=project, ok=False)
    assert checked.returncode != 0
    assert 'Formatting differs on changed lines in src/main/java/demo/Example.java' in checked.stdout
    assert java.read_bytes() == dirty
    java.write_bytes(original)
    run('git', 'add', str(java), cwd=project)
    # Avro-only commits skip the checkers. A mixed commit checks the hand-written file only.
    avro = project / 'src/main/java/notification/avro/Generated.java'
    avro.parent.mkdir(parents=True)
    avro.write_text('package notification.avro;\nclass Generated {}\n')
    run('git', 'add', str(avro), cwd=project)
    binary_dir = root / 'bin'
    binary_dir.mkdir()
    mvn = binary_dir / 'mvn'
    mvn.write_text('#!/bin/sh\ncp .quality-pom.xml "$QUALITY_CAPTURE"\nprintf "%s\\n" "$@" > "$QUALITY_ARGS"\nexit 0\n')
    mvn.chmod(0o755)
    env = dict(
        os.environ,
        PATH=str(binary_dir) + os.pathsep + os.environ['PATH'],
        QUALITY_CAPTURE=str(root / 'captured.xml'),
        QUALITY_ARGS=str(root / 'mvn-args'),
    )
    skipped = run(str(runner), '-PreCommit', '-Tool', 'checkstyle', cwd=project, env=env)
    assert 'No staged Java files' in skipped.stdout
    assert not (root / 'captured.xml').exists()
    java.write_text(java.read_text().replace('int value = 1;', 'int value = 2;'))
    run('git', 'add', str(java), cwd=project)
    run(str(runner), '-PreCommit', '-Tool', 'checkstyle', cwd=project, env=env)
    assert not (project / '.quality-pom.xml').exists()
    xml = (root / 'captured.xml').read_text()
    assert '<includes>demo/Example.java</includes>' in xml
    includes = xml.split('<includes>')[1].split('</includes>')[0]
    assert 'Generated.java' not in includes
    assert 'notification/avro' not in includes
    (project / '.mvn').mkdir()
    (project / '.mvn' / 'settings.xml').write_text('<settings/>\n')
    run(str(runner), '-PreCommit', '-Tool', 'checkstyle', cwd=project, env=env)
    assert '-s' in (root / 'mvn-args').read_text().splitlines()
    assert '.mvn/settings.xml' in (root / 'mvn-args').read_text().splitlines()
    # No Maven or Gradle file is a runner error, and the project file is untouched.
    (project / 'pom.xml').unlink()
    missing = run(str(runner), '-Tool', 'checkstyle', cwd=project, env=env, ok=False)
    assert missing.returncode != 0 and 'No Maven pom.xml' in missing.stderr
    (project / 'pom.xml').write_text('<project/>\n')
    # An older checker hook is replaced. An unrelated hook is not.
    hook = project / '.git' / 'hooks' / 'pre-commit'
    hook.write_text('#!/bin/sh\nexec "$root/.local/quality/run.ps1" -PreCommit\n')
    run(str(checker / 'setup'), str(project), cwd=checker)
    assert 'java-checkers' in hook.read_text()
    assert 'run.ps1' not in hook.read_text()
    # Branch clones select the requested git branch.
    run('git', 'init', cwd=checker)
    run('git', 'config', 'user.email', 'test@example.com', cwd=checker)
    run('git', 'config', 'user.name', 'Test', cwd=checker)
    (checker / '.gitignore').write_text('java-checkers\ntarget/\n')
    run('git', 'add', '.', cwd=checker)
    run('git', 'commit', '-m', 'Checker', cwd=checker)
    run('git', 'checkout', '-b', 'release/test', cwd=checker)
    readme = (checker / 'README.md').read_text() + '\nBRANCH_MARKER\n'
    (checker / 'README.md').write_text(readme)
    run('git', 'add', 'README.md', cwd=checker)
    run('git', 'commit', '-m', 'Branch marker', cwd=checker)
    run('git', 'remote', 'add', 'origin', str(checker), cwd=checker)
    branched = root / 'branched project'
    branched.mkdir()
    run('git', 'init', cwd=branched)
    run(str(checker / 'setup'), str(branched), '-Branch', 'release/test', cwd=checker)
    installed_readme = (branched / '.local' / 'quality' / 'README.md').read_text()
    assert 'BRANCH_MARKER' in installed_readme
    assert (branched / '.local' / 'quality' / 'java-checkers').is_file()

print('PASS scope notice, check mode, avro exclusion, Maven settings, missing build file, hook upgrade, branch clone')
