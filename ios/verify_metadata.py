"""Validate privacy and pairing metadata in a plist or the final signed IPA."""
import argparse
import plistlib
from pathlib import Path, PurePosixPath
from zipfile import ZipFile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("input", type=Path, help="Info.plist or signed .ipa")
args = parser.parse_args()

if args.input.suffix.lower() == ".ipa":
    with ZipFile(args.input) as archive:
        names = [name for name in archive.namelist()
                 if len(PurePosixPath(name).parts) == 3
                 and PurePosixPath(name).parts[0] == "Payload"
                 and PurePosixPath(name).parts[1].endswith(".app")
                 and PurePosixPath(name).name == "Info.plist"]
        if len(names) != 1:
            parser.error("expected exactly one top-level app Info.plist in IPA")
        info = plistlib.loads(archive.read(names[0]))
        if info.get("CFBundleIdentifier") != "hk.camlink.ios":
            parser.error("IPA bundle identifier is not hk.camlink.ios")
else:
    with args.input.open("rb") as file:
        info = plistlib.load(file)

for key in ("NSCameraUsageDescription", "NSLocalNetworkUsageDescription"):
    value = info.get(key)
    if not isinstance(value, str) or not value.strip():
        parser.error(f"missing nonempty {key}")

schemes = [scheme for item in info.get("CFBundleURLTypes", [])
           for scheme in item.get("CFBundleURLSchemes", [])]
if "camlink" not in schemes:
    parser.error("missing camlink pairing URL scheme")

print("PASS: camera/local-network purpose strings and camlink URL scheme are present")
