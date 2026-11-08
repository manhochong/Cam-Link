#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=build/zip-regression
mkdir -p "$work/Sources/ZIPChecks" build/parity-tests
cat > "$work/Package.swift" <<'SWIFT'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "CamLinkZIPRegression", platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")],
    targets: [.executableTarget(name: "ZIPChecks", dependencies: [.product(name: "ZIPFoundation", package: "ZIPFoundation")])])
SWIFT
cp ios/CamLink/Session/SessionZIPExport.swift "$work/Sources/ZIPChecks/"
cp ios/SessionZIPTests.swift "$work/Sources/ZIPChecks/"
swift run --package-path "$work" -j 2 ZIPChecks 2>&1 | tee build/parity-tests/zip-results.txt
