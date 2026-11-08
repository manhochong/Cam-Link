"""Build and inspect an offline, universal macOS .app using an existing Go toolchain."""
import argparse
import os
import platform
import plistlib
import struct
import subprocess
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--go", default="go")
args = parser.parse_args()
build = root / ".build/mac-receiver"
build.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, GO111MODULE="off", CGO_ENABLED="0", GOPROXY="off", GOTOOLCHAIN="local",
           GOCACHE=str(build / "cache"), GOTELEMETRY="off")
subprocess.run([args.go, "test", "-v"], cwd=root/"mac", env=env, check=True)
images = []
for arch in ("arm64", "amd64"):
    output = build / arch
    subprocess.run([args.go, "build", "-trimpath", "-ldflags=-s -w", "-o", str(output), "."],
                   cwd=root/"mac", env=dict(env, GOOS="darwin", GOARCH=arch), check=True)
    thin = output.read_bytes()
    magic, cpu, sub = struct.unpack_from("<III", thin)
    assert magic == 0xfeedfacf and cpu == {"arm64": 0x100000c, "amd64": 0x1000007}[arch]
    images.append((cpu, sub, thin))
fat = bytearray(struct.pack(">II", 0xcafebabe, len(images)) + bytes(20*len(images)))
for i, (cpu, sub, thin) in enumerate(images):
    fat.extend(bytes((-len(fat)) % (1 << 14)))
    struct.pack_into(">IIIII", fat, 8+i*20, cpu, sub, len(fat), len(thin), 14)
    fat.extend(thin)
def png_square(src, size):
    from io import BytesIO
    from PIL import Image, ImageOps
    image = Image.open(BytesIO(src)).convert("RGBA")
    scaled = ImageOps.contain(image, (size, size), Image.Resampling.LANCZOS)
    canvas = Image.new("RGBA", (size, size))
    canvas.alpha_composite(scaled, ((size - scaled.width) // 2, (size - scaled.height) // 2))
    buf = BytesIO()
    canvas.save(buf, format="PNG")
    return buf.getvalue()

def icns(png):
    chunks = []
    for kind, size in ((b"ic07", 128), (b"ic08", 256), (b"ic09", 512), (b"ic10", 1024), (b"ic14", 1024)):
        data = png_square(png, size)
        chunks.append(kind + struct.pack(">I", 8 + len(data)) + data)
    body = b"".join(chunks)
    return b"icns" + struct.pack(">I", 8 + len(body)) + body

app = "Cam Link Receiver.app/Contents/"
info = dict(CFBundleIdentifier="hk.camlink.receiver", CFBundleName="Cam Link Receiver",
            CFBundleExecutable="CamLinkReceiver", CFBundlePackageType="APPL", CFBundleIconFile="AppIcon",
            CFBundleVersion="35", CFBundleShortVersionString="0.2.25",
            NSLocalNetworkUsageDescription="接收配對手機經本機網絡傳送的相片。")
out = root / "release/CamLink-Receiver-macOS.zip"
icon = icns((root / "release/brand/Cam-Link.png").read_bytes())
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED) as z:
    z.writestr(app+"Info.plist",plistlib.dumps(info))
    z.writestr(app+"Resources/AppIcon.icns", icon)
    binary=zipfile.ZipInfo(app+"MacOS/CamLinkReceiver")
    binary.create_system=3
    binary.external_attr=0o100755 << 16
    z.writestr(binary,fat,compress_type=zipfile.ZIP_DEFLATED)
with zipfile.ZipFile(out) as z:
    assert z.testzip() is None
    assert z.getinfo(binary.filename).external_attr >> 16 == 0o100755
    assert z.read(binary.filename) == fat
print(out)
