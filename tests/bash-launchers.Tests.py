"""Check Bash dispatch without depending on a Windows PowerShell installation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='checker bash ') as temp:
    root = Path(temp)
    binary = root / 'bin'
    binary.mkdir()
    for command in ('dirname', 'git'):
        (binary / command).symlink_to(shutil.which(command))
    subprocess.run(['git', 'init', str(root)], check=True, capture_output=True)
    capture = root / 'arguments'
    env = dict(os.environ, PATH=str(binary), CAPTURE=str(capture))
    shell = shutil.which('bash')
    stub = '#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\nexit 37\n'
    for engine in ('powershell.exe', 'pwsh'):
        # Leave powershell.exe available to verify pwsh takes precedence.
        (binary / engine).write_text(stub)
        (binary / engine).chmod(0o755)
        for launcher in ('setup', 'run', 'hook/pre-commit'):
            args = [] if launcher.startswith('hook/') else ['project with spaces', '-Branch', 'release/test']
            result = subprocess.run([shell, str(SOURCE / launcher), *args], cwd=root, env=env)
            assert result.returncode == 37, (engine, launcher, result.returncode)
            expected = ['-NoProfile']
            if engine == 'powershell.exe':
                expected += ['-ExecutionPolicy', 'Bypass']
            script = root / '.local/quality/run.ps1' if launcher.startswith('hook/') else SOURCE / (launcher + '.ps1')
            expected += ['-File', str(script)] + (['-PreCommit'] if launcher.startswith('hook/') else args)
            assert capture.read_text().splitlines() == expected, (engine, launcher)
    for engine in ('pwsh', 'powershell.exe'):
        (binary / engine).unlink()
    for launcher in ('setup', 'run', 'hook/pre-commit'):
        result = subprocess.run([shell, str(SOURCE / launcher)], cwd=root, env=env, text=True, capture_output=True)
        assert result.returncode == 1 and 'PowerShell' in result.stderr

print('PASS Bash launchers: PowerShell preference, Windows fallback, spaces, arguments, exit codes, missing runtime')
