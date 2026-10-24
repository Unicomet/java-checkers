"""Exercise the real Gradle launch with a classpath exceeding Windows' limit."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='spotbugs long classpath ') as temp:
    project = Path(temp) / 'project with spaces é'
    shutil.copytree(SOURCE / 'examples/gradle', project)
    entries = []
    for index in range(400):
        entry = project / 'dependencies' / (f'{index:04d}-' + 'dependency-path-' * 5)
        entry.mkdir(parents=True)
        entries.append(entry)
    assert len(os.pathsep.join(map(str, entries))) > 32767
    with (project / 'build.gradle').open('a') as build:
        build.write("\ndependencies { implementation files(file('dependencies').listFiles()) }\n")
    result = subprocess.run([
        os.environ.get('GRADLE', 'gradle'), '--no-daemon', '--console=plain', '--info',
        '--init-script', str(SOURCE / 'quality.init.gradle'),
        f'-PqualityRoot={SOURCE}', '-PqualityPreCommit=true',
        '-PqualityFiles=src/main/java/demo/Example.java', 'qualitySpotbugs',
    ], cwd=project, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    commands = [line for line in result.stdout.splitlines()
                if 'Command:' in line and 'edu.umd.cs.findbugs.LaunchAppropriateUI' in line]
    assert len(commands) == 1, result.stdout
    assert len(commands[0]) < 32767, f'SpotBugs command exceeds Windows limit: {len(commands[0])} characters'
    classpath_file = project / 'build/tmp/qualitySpotbugs/auxclasspath.txt'
    paths = classpath_file.read_text(encoding='utf-8').splitlines()
    assert set(map(str, entries)).issubset(paths), 'Auxiliary dependencies were lost'
    assert (project / 'build/reports/local-quality/spotbugs.xml').exists()
    print('PASS SpotBugs uses a short command with a long auxiliary classpath, spaces and Unicode')
