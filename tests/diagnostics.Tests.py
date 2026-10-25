"""Failed checks must remain identifiable after later checks succeed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)


def checker_binary():
    for candidate in (
        SOURCE / 'java-checkers',
        SOURCE / 'target' / 'release' / 'java-checkers',
        SOURCE / 'target' / 'debug' / 'java-checkers',
    ):
        if candidate.is_file():
            return candidate
    raise SystemExit('Build java-checkers before running diagnostics tests')


with tempfile.TemporaryDirectory(prefix='checker diagnostics ') as temp:
    project = Path(temp)
    installed = project / '.local/quality'
    installed.mkdir(parents=True)
    for name in ('run', 'plugins.xml', 'quality.init.gradle'):
        shutil.copy2(SOURCE / name, installed / name)
    shutil.copy2(checker_binary(), installed / 'java-checkers')
    (installed / 'run').chmod(0o755)
    (installed / 'java-checkers').chmod(0o755)
    assert run('git', 'init', cwd=project).returncode == 0
    assert run('git', 'config', 'user.email', 'test@example.com', cwd=project).returncode == 0
    assert run('git', 'config', 'user.name', 'Test', cwd=project).returncode == 0
    source = project / 'src/main/java/demo/Example.java'
    source.parent.mkdir(parents=True)
    source.write_text('package demo;\n\nclass Example {\n  int value = 1;\n}\n')
    assert run('git', 'add', 'src', cwd=project).returncode == 0
    assert run('git', 'commit', '-m', 'Initial', cwd=project).returncode == 0
    binary = project / 'bin'
    binary.mkdir()
    stub = '''#!/bin/sh
printf '%s\\n' "$@" >> "$QUALITY_ARGS"
case "$*" in
  *qualityCheckstyle*|*checkstyle:check*)
    if [ "$QUALITY_FAIL_CHECKSTYLE" = 1 ]; then
      echo 'Task execution failed' >&2
      echo 'Caused by: java.lang.IllegalStateException: diagnostic fixture root cause' >&2
      echo '    at demo.Fixture.run(Fixture.java:42)' >&2
      exit 3
    fi ;;
esac
echo 'Non-fatal diagnostic fixture warning' >&2
echo 'BUILD SUCCESSFUL'
exit 0
'''
    for name in ('gradle', 'mvn'):
        command = binary / name
        command.write_text(stub)
        command.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'],
               QUALITY_ARGS=str(project / 'arguments'), QUALITY_FAIL_CHECKSTYLE='1')
    for build_file, trace_flag in (('build.gradle', '--stacktrace'), ('pom.xml', '-e')):
        build = project / build_file
        build.write_text('' if build_file.endswith('gradle') else '<project/>')
        source.write_text('package demo;\nclass Example { int   value= }\n')
        assert run('git', 'add', 'src', cwd=project).returncode == 0
        result = run(str(installed / 'run'), '-PreCommit', cwd=project, env=env)
        output = result.stdout + result.stderr
        assert result.returncode == 1, output
        assert 'PASSED: SpotBugs' in output, output
        summary = output.split('Failed checks: ')[-1]
        assert summary.startswith('Google Java Format, Checkstyle'), output
        assert 'error:' in summary, output
        assert 'diagnostic fixture root cause' in summary, output
        assert 'at demo.Fixture.run(Fixture.java:42)' in summary, output
        assert 'exit code 3' in summary, output
        assert trace_flag in (project / 'arguments').read_text().splitlines()
        assert not (project / '.quality-pom.xml').exists()
        # A passing formatter must not trigger formatting advice for a Checkstyle failure.
        # Keep a staged, already-formatted change so the pre-commit selection is not empty.
        source.write_text('package demo;\n\nclass Example {\n  int value = 2;\n}\n')
        assert run('git', 'add', 'src', cwd=project).returncode == 0
        result = run(str(installed / 'run'), '-PreCommit', cwd=project, env=env)
        output = result.stdout + result.stderr
        assert result.returncode == 1 and 'Failed checks: Checkstyle' in output, output
        assert 'To format the changed lines' not in output, output
        # An all-green run must not inherit a previous invocation's failure.
        result = run(str(installed / 'run'), '-PreCommit', cwd=project,
                     env=dict(env, QUALITY_FAIL_CHECKSTYLE='0'))
        output = result.stdout + result.stderr
        assert result.returncode == 0 and 'Failed checks:' not in output, output
        # A formatter tool failure is attributed to Google Java Format and keeps the tool output.
        java = binary / 'java'
        java.write_text('#!/bin/sh\necho \'formatter fixture exception\'\necho \'at Fail-Fixture\'\nexit 1\n')
        java.chmod(0o755)
        source.write_text('package demo;\n\nclass Example {\n  int   value=1;\n}\n')
        assert run('git', 'add', 'src', cwd=project).returncode == 0
        result = run(str(installed / 'run'), '-PreCommit', '-Tool', 'format', cwd=project, env=env)
        output = result.stdout + result.stderr
        assert result.returncode == 1, output
        assert 'Failed checks: Google Java Format' in output, output
        assert 'formatter fixture exception' in output and 'at Fail-Fixture' in output, output
        java.unlink()
        source.write_text('package demo;\n\nclass Example {\n  int value = 2;\n}\n')
        assert run('git', 'add', 'src', cwd=project).returncode == 0
        if build_file == 'pom.xml':
            build.write_text('<broken XML')
            result = run(str(installed / 'run'), '-PreCommit', '-Tool', 'checkstyle', cwd=project, env=env)
            output = result.stdout + result.stderr
            assert result.returncode == 1 and 'Runner error:' in output, output
            assert 'XML' in output, output
            assert not (project / '.quality-pom.xml').exists()
        build.unlink()
        (project / 'arguments').write_text('')

print('PASS diagnostics: retained failures, cause and stack trace, Gradle/Maven flags, formatter errors, success exit codes')
