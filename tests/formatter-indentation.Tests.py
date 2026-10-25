"""Changed catch lines must keep the indentation used by unchanged surrounding code."""
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


with tempfile.TemporaryDirectory(prefix='formatter indentation ') as temp:
    root = Path(temp)
    installed = root / '.local/quality'
    installed.mkdir(parents=True)
    for name in ('run', 'run.ps1', 'format-changed.ps1'):
        shutil.copy2(SOURCE / name, installed / name)
    run('git', 'init', cwd=root)
    run('git', 'config', 'user.name', 'Indentation test', cwd=root)
    run('git', 'config', 'user.email', 'test@example.com', cwd=root)
    paths = []
    for width in (2, 4):
        path = root / f'src/main/java/demo/Example{width}.java'
        path.parent.mkdir(parents=True, exist_ok=True)
        indent = ' ' * width
        text = (f'package demo;\n\nclass Example{width} {{\n'
                f'{indent}void example() {{\n{indent * 2}try {{\n'
                f'{indent * 3}System.out.println("try");\n'
                f'{indent * 2}}} catch (RuntimeException e) {{\n'
                f'{indent * 3}System.out.println("catch");\n'
                f'{indent * 2}}}\n{indent}}}\n}}\n')
        path.write_bytes(text.replace('\n', '\r\n').encode())
        paths.append((path, text))
    run('git', 'add', 'src', cwd=root)
    run('git', 'commit', '-m', 'Baseline', cwd=root)
    expected = {}
    for path, text in paths:
        text = text.replace('RuntimeException e', 'RuntimeException failure')
        expected[path] = text
    for args in (('-Mode', 'apply'), ('-Mode', 'apply', '-PreCommit')):
        for path, text in expected.items():
            # Deliberately misindent the changed catch line; surrounding code decides the style.
            text = text.replace(' ' * (4 if 'Example2' in path.name else 8) + '} catch', '  } catch')
            path.write_bytes(text.replace('\n', '\r\n').encode())
        run('git', 'add', 'src', cwd=root)
        print(run('./.local/quality/run', '-Tool', 'format', *args, cwd=root), flush=True)
        for path, text in paths:
            assert path.read_bytes() == expected[path].replace('\n', '\r\n').encode(), path.name + ': indentation or unchanged lines differ'
        run('git', 'add', 'src', cwd=root)
        run('./.local/quality/run', '-Tool', 'format', '-PreCommit', cwd=root)
    # New files have no unchanged lines from which to infer their indentation.
    new_path = root / 'src/main/java/demo/NewExample.java'
    new_text = expected[paths[1][0]].replace('Example4', 'NewExample')
    new_path.write_bytes(new_text.replace('println("try")', 'println(  "try"  )').replace('\n', '\r\n').encode())
    run('git', 'add', 'src', cwd=root)
    run('./.local/quality/run', '-Tool', 'format', '-Mode', 'apply', cwd=root)
    assert new_path.read_bytes() == new_text.replace('\n', '\r\n').encode()
    print('PASS two/four-space catch alignment, correction of changed indentation, CRLF, unchanged lines, standalone/staged modes and new files')
