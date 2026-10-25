"""The standalone apply command must format staged lines in both selected files."""
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


with tempfile.TemporaryDirectory(prefix='formatter staged ') as temp:
    project = Path(temp)
    installed = project / '.local/quality'
    installed.mkdir(parents=True)
    shutil.copy2(SOURCE / 'run', installed / 'run')
    (installed / 'run').chmod(0o755)
    binary = next(path for path in (
        SOURCE / 'java-checkers',
        SOURCE / 'target' / 'release' / 'java-checkers',
        SOURCE / 'target' / 'debug' / 'java-checkers',
    ) if path.is_file())
    shutil.copy2(binary, installed / 'java-checkers')
    (installed / 'java-checkers').chmod(0o755)
    run('git', 'init', cwd=project)
    run('git', 'config', 'user.name', 'Formatter test', cwd=project)
    run('git', 'config', 'user.email', 'formatter@example.com', cwd=project)
    (project / '.gitignore').write_text('.local/\n')
    sources = []
    for name in ('First', 'Second'):
        path = project / f'src/main/java/demo/{name}.java'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'package demo;\n\nclass {name} {{\n  int value = 1;\n\n  void untouched() {{\n    int  keep=2;\n  }}\n}}\n')
        sources.append(path)
    run('git', 'add', '.', cwd=project)
    run('git', 'commit', '-m', 'Baseline', cwd=project)
    for path in sources:
        path.write_text(path.read_text().replace('int value = 1;', 'int   value=3;'))
    run('git', 'add', 'src', cwd=project)
    staged = run('git', 'diff', '--cached', cwd=project)
    print('$ ./.local/quality/run -Tool format -Mode apply', flush=True)
    output = run('./.local/quality/run', '-Tool', 'format', '-Mode', 'apply', cwd=project)
    print(output, flush=True)
    for path in sources:
        text = path.read_text()
        assert '  int value = 3;' in text, f'{path.name}: staged changed line was not formatted'
        assert '    int  keep=2;' in text, f'{path.name}: unchanged line was rewritten'
    assert staged == run('git', 'diff', '--cached', cwd=project), 'Standalone formatting must leave the index untouched'
    assert 'finished on 2 file(s)' in output
    # Repeat after staging the fixes: no additional formatting changes should appear.
    run('git', 'add', 'src', cwd=project)
    run('./.local/quality/run', '-Tool', 'format', '-Mode', 'apply', cwd=project)
    assert not run('git', 'diff', cwd=project)
    print('PASS two staged files formatted; unchanged lines and index preserved; repeat run is stable')
