"""Shell launchers dispatch to the Rust binary and forward arguments."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='checker bash ') as temp:
    root = Path(temp)
    subprocess.run(['git', 'init', str(root)], check=True, capture_output=True)
    capture = root / 'arguments'
    stub = '#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\nexit 37\n'
    launchers = root / 'launchers'
    launchers.mkdir()
    (launchers / 'hook').mkdir()
    for name in ('setup', 'run', 'uninstall'):
        shutil.copy2(SOURCE / name, launchers / name)
        (launchers / name).chmod(0o755)
    (launchers / 'java-checkers').write_text(stub)
    (launchers / 'java-checkers').chmod(0o755)
    env = dict(os.environ, CAPTURE=str(capture))
    shell = shutil.which('bash')
    cases = {
        'setup': ['setup', 'project with spaces', '-Branch', 'release/test'],
        'run': ['run', '-Tool', 'format', '-Mode', 'apply'],
        'uninstall': ['uninstall', 'project with spaces'],
    }
    for launcher, expected in cases.items():
        result = subprocess.run([shell, str(launchers / launcher), *expected[1:]], cwd=root, env=env)
        assert result.returncode == 37, (launcher, result.returncode)
        assert capture.read_text().splitlines() == expected, (launcher, capture.read_text())

    quality = root / '.local' / 'quality'
    quality.mkdir(parents=True)
    (quality / 'java-checkers').write_text(stub)
    (quality / 'java-checkers').chmod(0o755)
    result = subprocess.run([shell, str(SOURCE / 'hook' / 'pre-commit')], cwd=root, env=env)
    assert result.returncode == 37, result.stderr
    assert capture.read_text().splitlines() == ['run', '-PreCommit']
    skipped = subprocess.run(
        [shell, str(SOURCE / 'hook' / 'pre-commit')],
        cwd=root,
        env=dict(env, SKIP_LOCAL_CHECKS='1'),
        text=True,
        capture_output=True,
    )
    assert skipped.returncode == 0 and 'Skipping local Checkstyle' in skipped.stdout, skipped.stderr
    (quality / 'java-checkers').unlink()
    missing_hook = subprocess.run(
        [shell, str(SOURCE / 'hook' / 'pre-commit')],
        cwd=root,
        env=env,
        text=True,
        capture_output=True,
    )
    assert missing_hook.returncode == 1 and 'java-checkers' in missing_hook.stderr
    (launchers / 'java-checkers').unlink()
    for launcher in ('setup', 'run', 'uninstall'):
        missing = subprocess.run(
            [shell, str(launchers / launcher)],
            cwd=root,
            env=env,
            text=True,
            capture_output=True,
        )
        assert missing.returncode == 1 and 'java-checkers binary is missing' in missing.stderr, missing.stderr

print('PASS Rust launchers: argument forwarding, hook pre-commit, skip switch, missing binary')
