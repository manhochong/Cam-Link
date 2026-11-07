import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
JDK = Path(os.environ.get('JAVA_HOME', r'C:\Program Files\Android\Android Studio\jbr'))
OUT = ROOT / '.build/tests'
OUT.mkdir(parents=True, exist_ok=True)
source = ROOT / 'app/src/main/java/hk/camlink/usb'
commands = [
    [JDK / 'bin/javac.exe', '--release', '17', '-encoding', 'UTF-8', '-d', OUT,
     source / 'CameraProfile.java', source / 'Ptp.java', source / 'JpegCheck.java', source / 'ReceiveQueue.java', ROOT / 'tests/CoreTests.java'],
    [JDK / 'bin/java.exe', '-ea', '-cp', OUT, 'hk.camlink.usb.CoreTests', OUT / 'fixtures'],
    [sys.executable, '-m', 'unittest', 'discover', '-s', str(ROOT / 'tests'), '-p', 'test_*.py', '-v'],
]
log = []
for command in commands:
    result = subprocess.run([str(v) for v in command], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
    print(result.stdout, end='')
    log.append(result.stdout)
    if result.returncode:
        (OUT / 'test-results.txt').write_text('\n'.join(log), encoding='utf-8')
        sys.exit(result.returncode)
(OUT / 'test-results.txt').write_text('\n'.join(log), encoding='utf-8')
print('All host tests passed. Camera hardware compatibility remains unverified.')
