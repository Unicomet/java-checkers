"""Exercise installation and the real hook in a disposable Git project (Maven stubbed)."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd, env=None, ok=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix='java-checkers-') as temp:
    root = Path(temp)
    checker = root / 'checker'
    shutil.copytree(SOURCE, checker, ignore=shutil.ignore_patterns('.git', 'mise.toml', 'target', '__pycache__'))
    project = root / 'project with spaces'
    project.mkdir()
    run('git', 'init', cwd=project)
    run('git', 'config', 'user.email', 'test@example.com', cwd=project)
    run('git', 'config', 'user.name', 'Test', cwd=project)
    (project / 'pom.xml').write_text('<project>\n  <build>\n    <plugins>\n    </plugins>\n  </build>\n</project>\n')
    java = project / 'src/main/java/demo/Example.java'
    java.parent.mkdir(parents=True)
    java.write_text('package demo;\nclass Example {}\n')
    run('git', 'add', '.', cwd=project)
    run('git', 'commit', '-m', 'Initial', cwd=project)
    run(str(checker / 'setup'), str(project), cwd=checker)
    hook = project / '.git/hooks/pre-commit'
    assert os.access(hook, os.X_OK)
    run(str(checker / 'setup'), str(project), cwd=checker)
    assert '.local/' in (project / '.git/info/exclude').read_text()
    # No staged Java means no Maven invocation or formatter download.
    run(str(hook), cwd=project)
    java.write_text('package demo;\nclass Example { int value; }\n')
    run('git', 'add', str(java), cwd=project)
    binary = root / 'bin'
    binary.mkdir()
    mvn = binary / 'mvn'
    mvn.write_text('#!/bin/sh\ncp .quality-pom.xml "$QUALITY_CAPTURE"\nexit "${QUALITY_EXIT:-0}"\n')
    mvn.chmod(0o755)
    env = dict(os.environ, PATH=str(binary) + os.pathsep + os.environ['PATH'], QUALITY_CAPTURE=str(root / 'captured.xml'))
    runner = project / '.local/quality/run'
    for tool in ('checkstyle', 'spotbugs'):
        run(str(runner), '-PreCommit', '-Tool', tool, cwd=project, env=env)
        xml = (root / 'captured.xml').read_text()
        assert '<includes>demo/Example.java</includes>' in xml
        assert '<onlyAnalyze>demo.Example,demo.Example$[^/]*</onlyAnalyze>' in xml
        assert not (project / '.quality-pom.xml').exists()
        failed = run(str(runner), '-PreCommit', '-Tool', tool, cwd=project, env=dict(env, QUALITY_EXIT='1'), ok=False)
        assert failed.returncode != 0
    java.write_text(java.read_text() + '// unstaged\n')
    result = run(str(runner), '-PreCommit', cwd=project, env=env, ok=False)
    assert result.returncode != 0 and 'not staged' in result.stderr
    assert java.read_text().endswith('// unstaged\n')
    assert '// unstaged' not in run('git', 'show', ':src/main/java/demo/Example.java', cwd=project).stdout
    # Maven POM indentation must not determine whether tools can run.
    java.write_text('package demo;\nclass Example { int value; }\n')
    for closing in ('\t\t</plugins>', '        </plugins>'):
        (project / 'pom.xml').write_text('<project>\n  <build>\n    <plugins>\n' + closing + '\n  </build>\n</project>\n')
        run(str(runner), '-PreCommit', '-Tool', 'checkstyle', cwd=project, env=env)
    # Add to the main build, even when a profile has its own plugins block.
    for pom in (
        '<project/>',
        '<project xmlns="http://maven.apache.org/POM/4.0.0"><profiles><profile><id>other</id><build><plugins/></build></profile></profiles></project>',
    ):
        (project / 'pom.xml').write_text(pom)
        run(str(runner), '-PreCommit', '-Tool', 'checkstyle', cwd=project, env=env)
        document = ET.parse(root / 'captured.xml')
        ns = '{http://maven.apache.org/POM/4.0.0}' if 'xmlns=' in pom else ''
        plugins = document.findall(f'{ns}build/{ns}plugins/{ns}plugin')
        assert len(plugins) == 2
        assert (project / 'pom.xml').read_text() == pom
    # Respect a custom hooks directory as Git does.
    run('git', 'config', 'core.hooksPath', str(project / 'custom-hooks'), cwd=project)
    run(str(checker / 'setup'), str(project), cwd=checker)
    assert os.access(project / 'custom-hooks/pre-commit', os.X_OK)
    unrelated = project / 'custom-hooks/pre-commit'
    unrelated.write_text('#!/bin/sh\necho existing-hook\n')
    result = run(str(checker / 'setup'), str(project), cwd=checker, ok=False)
    assert result.returncode != 0 and 'existing-hook' in unrelated.read_text()
    run('git', 'config', '--unset', 'core.hooksPath', cwd=project)
    worktree = root / 'linked worktree'
    run('git', 'worktree', 'add', '-b', 'linked', str(worktree), cwd=project)
    run(str(checker / 'setup'), str(worktree), cwd=checker)
    assert (worktree / '.local/quality/run').exists()

print('PASS setup, executable hook, staged scopes, nested classes, failures, partial staging, custom hooks')
