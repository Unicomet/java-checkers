"""Failed checks must remain identifiable after later checks succeed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)


with tempfile.TemporaryDirectory(prefix='checker diagnostics ') as temp:
    project = Path(temp)
    installed = project / '.local/quality'
    installed.mkdir(parents=True)
    for name in ('run', 'run.ps1', 'plugins.xml', 'quality.init.gradle'):
        shutil.copy2(SOURCE / name, installed / name)
    formatter = installed / 'format-changed.ps1'
    formatter.write_text("Write-Host 'Formatting differs on changed lines in src/main/java/demo/Example.java'\nexit 1\n")
    assert run('git', 'init', cwd=project).returncode == 0
    source = project / 'src/main/java/demo/Example.java'
    source.parent.mkdir(parents=True)
    source.write_text('package demo; class Example {}\n')
    assert run('git', 'add', 'src', cwd=project).returncode == 0
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
        result = run(str(installed / 'run'), '-PreCommit', cwd=project, env=env)
        output = result.stdout + result.stderr
        assert result.returncode == 1, output
        assert 'PASSED: SpotBugs' in output, output
        summary = output.split('Failed checks: ')[-1]
        assert summary.startswith('Google Java Format, Checkstyle'), output
        assert 'Formatting differs on changed lines' in summary, output
        assert 'diagnostic fixture root cause' in summary, output
        assert 'at demo.Fixture.run(Fixture.java:42)' in summary, output
        assert 'exit code 3' in summary, output
        assert trace_flag in (project / 'arguments').read_text().splitlines()
        assert not (project / '.quality-pom.xml').exists()
        # A passing formatter must not trigger formatting advice for a Checkstyle failure.
        formatter.write_text('exit 0\n')
        result = run(str(installed / 'run'), '-PreCommit', cwd=project, env=env)
        output = result.stdout + result.stderr
        assert result.returncode == 1 and 'Failed checks: Checkstyle' in output, output
        assert 'To format the changed lines' not in output, output
        # An all-green run must not inherit a previous invocation's failure.
        result = run(str(installed / 'run'), '-PreCommit', cwd=project,
                     env=dict(env, QUALITY_FAIL_CHECKSTYLE='0'))
        output = result.stdout + result.stderr
        assert result.returncode == 0 and 'Failed checks:' not in output, output
        # PowerShell exceptions need their script stack trace and must name the failed check.
        formatter.write_text("function Fail-Fixture { throw 'formatter fixture exception' }\nFail-Fixture\n")
        result = run(str(installed / 'run'), '-PreCommit', '-Tool', 'format', cwd=project, env=env)
        output = result.stdout + result.stderr
        assert result.returncode == 1, output
        assert 'Failed checks: Google Java Format' in output, output
        assert 'formatter fixture exception' in output and 'at Fail-Fixture' in output, output
        formatter.write_text("Write-Host 'Formatting differs on changed lines in src/main/java/demo/Example.java'\nexit 1\n")
        if build_file == 'pom.xml':
            build.write_text('<broken XML')
            result = run(str(installed / 'run'), '-PreCommit', '-Tool', 'checkstyle', cwd=project, env=env)
            output = result.stdout + result.stderr
            assert result.returncode == 1 and 'Runner error:' in output, output
            assert 'at <ScriptBlock>' in output and 'run.ps1: line' in output, output
            assert not (project / '.quality-pom.xml').exists()
        build.unlink()

print('PASS diagnostics: retained failures, cause and stack trace, Gradle/Maven flags, PowerShell exceptions, success exit codes')
