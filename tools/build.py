"""Build Cam Link with official Gradle/Google dependencies and the existing update key."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def run(args, env):
    subprocess.run([str(x) for x in args], cwd=ROOT, env=env, check=True)

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--sdk', default=os.environ.get('ANDROID_HOME', str(Path.home() / 'AppData/Local/Android/Sdk')))
    p.add_argument('--jdk', default=os.environ.get('JAVA_HOME', r'C:\Program Files\Android\Android Studio\jbr'))
    p.add_argument('--offline', action='store_true')
    args = p.parse_args()
    sdk, jdk = Path(args.sdk), Path(args.jdk)
    env = dict(os.environ, JAVA_HOME=str(jdk), ANDROID_HOME=str(sdk))
    (ROOT / 'local.properties').write_text('sdk.dir=' + sdk.as_posix().replace(':', '\\:') + '\n', encoding='utf-8', newline='\n')
    build = ROOT / '.build'
    build.mkdir(exist_ok=True)
    key = build / 'usb-test.keystore'
    if not key.exists():
        run([jdk / 'bin/keytool.exe', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android', '-alias', 'usbtest', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '3650', '-dname', 'CN=Cam Link USB Test, O=Local Development, C=HK'], env)
    clang = sdk / 'ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin/clang.exe'
    for abi, target in [('arm64-v8a','aarch64-linux-android29'),('armeabi-v7a','armv7a-linux-androideabi29'),('x86_64','x86_64-linux-android29')]:
        folder = build / 'native-libs' / abi
        folder.mkdir(parents=True, exist_ok=True)
        run([clang, '--target='+target, '-shared', '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror', '-Wl,-z,max-page-size=16384', ROOT / 'app/src/main/cpp/usb_diag.c', '-o', folder / 'libcamlink_usb.so'], env)
    wrapper = ROOT / 'gradlew.bat'
    if not wrapper.exists():
        matches = list((Path.home() / '.gradle/wrapper/dists/gradle-9.3.1-all').glob('*/gradle-9.3.1/bin/gradle.bat'))
        if not matches:
            raise RuntimeError('Gradle 9.3.1 required; install it or restore the Gradle wrapper from the source archive.')
        run([matches[0], 'wrapper', '--gradle-version', '9.3.1', '--distribution-type', 'all'], env)
    run([wrapper, *(['--offline'] if args.offline else []), ':app:assembleDebug', ':app:testDebugUnitTest', ':app:lintDebug', ':app:assembleDebugAndroidTest'], env)
    release = ROOT / 'release'
    release.mkdir(exist_ok=True)
    apk = release / 'CamLink-0.2.25.apk'
    shutil.copy2(ROOT / 'app/build/outputs/apk/debug/app-debug.apk', apk)
    run([jdk / 'bin/java.exe','-jar',sdk / 'build-tools/36.0.0/lib/apksigner.jar','verify','--verbose','--print-certs',apk], env)
    digest = hashlib.sha256(apk.read_bytes()).hexdigest()
    (release / (apk.name+'.sha256')).write_text(digest+'  '+apk.name+'\n', encoding='utf-8')
    print('APK:', apk, '\nSHA256:', digest)

if __name__ == '__main__':
    main()
