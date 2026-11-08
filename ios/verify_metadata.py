"""Validate privacy, pairing and native cloud OAuth metadata in a plist or signed IPA."""
import argparse
import json
import plistlib
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit
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

for key in ("NSCameraUsageDescription", "NSLocalNetworkUsageDescription", "NSPhotoLibraryAddUsageDescription"):
    value = info.get(key)
    if not isinstance(value, str) or not value.strip():
        parser.error(f"missing nonempty {key}")

schemes = [scheme for item in info.get("CFBundleURLTypes", [])
           for scheme in item.get("CFBundleURLSchemes", [])]
if "camlink" not in schemes:
    parser.error("missing camlink pairing URL scheme")

public = json.loads((Path(__file__).parent / "OAuthClients.json").read_text())
if info.get("GIDClientID") != public["googleClientID"]:
    parser.error("Google client ID differs from registered public client")
if public["googleCallbackScheme"] not in schemes:
    parser.error("missing Google native callback URL scheme")
if info.get("CamLinkMicrosoftClientID") != public["microsoftClientID"] or not public["microsoftClientID"]:
    parser.error("Microsoft client ID differs from registered independent Cam Link client")
if info.get("CamLinkMicrosoftRedirectURI") != public["microsoftRedirectURI"]:
    parser.error("Microsoft native redirect URI differs from registered callback")
if urlsplit(public["microsoftRedirectURI"]).scheme not in schemes:
    parser.error("missing Microsoft native callback URL scheme")
if info.get("ITSAppUsesNonExemptEncryption") is not False:
    parser.error("missing approved non-exempt encryption declaration false")
for key in info:
    if key.lower() in {"client_secret", "clientsecret", "access_token", "refresh_token"}:
        parser.error("OAuth secrets/tokens must not be bundled in Info.plist")

print("PASS: camera/network/Photos purposes, pairing, both native cloud OAuth clients/callbacks and approved encryption metadata")
