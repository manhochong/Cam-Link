"""Package reviewable source/docs/tests without keys, build caches or camera photos."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parents[1]
out = root / 'release/CamLink-0.2.25-source.zip'
files = [root / name for name in ('README.md','.gitignore','build.gradle','settings.gradle','gradle.properties','gradlew','gradlew.bat')]
for directory in ('app/src', 'gradle', 'tools', 'tests', 'docs', 'windows', 'mac', 'release/brand'):
    files.extend(p for p in (root / directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts)
files.append(root / 'app/build.gradle')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for path in sorted(files):
        z.write(path, path.relative_to(root).as_posix())
print(out)
