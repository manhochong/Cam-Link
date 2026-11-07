"""Install/start this test APK and collect an app screenshot and crash log from an explicitly selected phone."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--serial', required=True)
parser.add_argument('--install', action='store_true')
args = parser.parse_args()
adb = Path.home() / 'AppData/Local/Android/Sdk/platform-tools/adb.exe'
dest = ROOT / 'artifacts/phone-0.2.22'
dest.mkdir(parents=True, exist_ok=True)

def call(*words, check=True):
    result = subprocess.run([str(adb), '-s', args.serial, *words], capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.decode(errors='replace') + result.stdout.decode(errors='replace'))
    return result.stdout

if args.install:
    print(call('install', '-r', str(ROOT / 'release/CamLink-0.2.22.apk')).decode(errors='replace'))
    print(call('shell', 'pm', 'grant', 'hk.camlink.usb', 'android.permission.POST_NOTIFICATIONS').decode(errors='replace'))
    call('shell', 'am', 'force-stop', 'hk.camlink.usb')
    print(call('shell', 'am', 'start', '-W', '-n', 'hk.camlink.usb/.MainActivity').decode(errors='replace'))
print(call('shell', 'uiautomator', 'dump', '/sdcard/camlink-ui.xml', check=False).decode(errors='replace'))
(dest / 'ui.xml').write_bytes(call('shell', 'cat', '/sdcard/camlink-ui.xml', check=False))
call('shell', 'screencap', '-p', '/sdcard/camlink-screen.png')
call('pull', '/sdcard/camlink-screen.png', str(dest / 'screen.png'))
(dest / 'crash-log.txt').write_bytes(call('logcat', '-d', '-b', 'crash', '-t', '80'))
(dest / 'package.txt').write_bytes(call('shell', 'dumpsys', 'package', 'hk.camlink.usb'))
print('Evidence saved:', dest)
