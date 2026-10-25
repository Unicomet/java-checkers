"""Real Maven regression: a staged nested-class bug must fail; an unstaged bug must not."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

SOURCE = Path(__file__).resolve().parents[1]


def run(*args, cwd, ok=True):
    result = subprocess.run(args, cwd=cwd, text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix='spotbugs-staged-') as temp:
    root = Path(temp)
    checker = root / 'checker'
    shutil.copytree(SOURCE, checker, ignore=shutil.ignore_patterns('.git', 'mise.toml', 'target', '__pycache__'))
    project = root / 'project'
    project.mkdir()
    run('git', 'init', cwd=project)
    run('git', 'config', 'user.name', 'Test', cwd=project)
    run('git', 'config', 'user.email', 'test@example.com', cwd=project)
    (project / 'pom.xml').write_text('''<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>verification</groupId><artifactId>staged-check</artifactId><version>1</version>
  <properties><maven.compiler.source>17</maven.compiler.source><maven.compiler.target>17</maven.compiler.target></properties>
  <build><plugins>
    </plugins></build>
</project>
''')
    run('git', 'add', 'pom.xml', cwd=project)
    run('git', 'commit', '-m', 'Initial', cwd=project)
    run(str(checker / 'setup'), str(project), cwd=checker)
    source_dir = project / 'src/main/java/verification'
    source_dir.mkdir(parents=True)
    staged = source_dir / 'Staged.java'
    staged.write_text('''package verification;
public final class Staged {
  public static final class Nested {
    public static boolean broken(String value) { return value == "bad"; }
  }
}
''')
    (source_dir / 'Unstaged.java').write_text('''package verification;
public final class Unstaged {
  public static boolean broken(String value) { return value == "bad"; }
}
''')
    run('git', 'add', str(staged), cwd=project)
    result = run(str(project / '.local/quality/run'), '-PreCommit', '-Tool', 'spotbugs', cwd=project, ok=False)
    assert result.returncode != 0, 'SpotBugs missed a staged nested-class bug'
    assert (project / 'target/spotbugsXml.xml').exists(), result.stdout + result.stderr
    report = ET.parse(project / 'target/spotbugsXml.xml')
    classes = {bug.find('Class').get('classname') for bug in report.findall('BugInstance')}
    assert classes == {'verification.Staged$Nested'}, (classes, result.stdout, result.stderr)
    staged.write_text(staged.read_text().replace('value == "bad"', '"bad".equals(value)'))
    run('git', 'add', str(staged), cwd=project)
    run(str(project / '.local/quality/run'), '-PreCommit', '-Tool', 'spotbugs', cwd=project)

print('PASS real SpotBugs detects staged nested class and ignores unstaged class')
