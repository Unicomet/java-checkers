"""Install and uninstall real disposable projects, preserving unrelated state."""
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.strip()


with tempfile.TemporaryDirectory(prefix='checker uninstall ') as temp:
    root = Path(temp)
    checker = root / 'checker'
    shutil.copytree(SOURCE, checker, ignore=shutil.ignore_patterns('.git', 'mise.toml', 'target', '__pycache__'))
    for scenario in ('normal', 'custom hooks', 'unrelated files', 'modified hook', 'worktree'):
        project = root / scenario
        project.mkdir()
        run('git', 'init', cwd=project)
        if scenario == 'worktree':
            run('git', '-c', 'user.name=Test', '-c', 'user.email=test@example.com',
                'commit', '--allow-empty', '-m', 'Initial', cwd=project)
            linked = root / 'linked worktree'
            run('git', 'worktree', 'add', '-b', 'linked', str(linked), cwd=project)
            project = linked
        if scenario == 'custom hooks':
            run('git', 'config', 'core.hooksPath', 'custom-hooks', cwd=project)
        exclude = Path(run('git', 'rev-parse', '--path-format=absolute',
                           '--git-path', 'info/exclude', cwd=project))
        original = '# Keep this comment\r\nprivate-files/\r\n'
        exclude.write_bytes(original.encode())
        pom = project / 'pom.xml'
        pom.write_text('<project/>\n')
        run(str(checker / 'setup'), str(project), cwd=checker)
        installed = project / '.local/quality'
        assert (installed / 'uninstall').exists(), 'Copy installs must include the uninstaller'
        hook = Path(run('git', 'rev-parse', '--path-format=absolute',
                        '--git-path', 'hooks/pre-commit', cwd=project))
        if scenario == 'unrelated files':
            (project / '.local/other-tool').write_text('keep me')
        if scenario == 'modified hook':
            hook.write_text(hook.read_text() + '# My hook customization\n')
            custom_hook = hook.read_bytes()
        # Execute the installed script: it must safely delete its own directory.
        run(str(installed / 'uninstall'), cwd=root)
        assert not installed.exists()
        assert pom.read_text() == '<project/>\n'
        if scenario == 'modified hook':
            assert hook.read_bytes() == custom_hook
        else:
            assert not hook.exists()
        if scenario == 'unrelated files':
            assert (project / '.local/other-tool').read_text() == 'keep me'
            assert '.local/' in exclude.read_text()
        else:
            assert not (project / '.local').exists()
            assert exclude.read_bytes() == original.encode()
        # Uninstall from an external checkout is also repeatable.
        run(str(checker / 'uninstall'), str(project), cwd=checker)
        if scenario == 'custom hooks':
            assert run('git', 'config', 'core.hooksPath', cwd=project) == 'custom-hooks'
    print('PASS uninstall: self-removal, copied installs, custom hooks, worktrees, unrelated files, modified hooks, repeat runs')
