#!/bin/bash
# Real App modules, synthetic local fixtures and injected offline transports; no cloud credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/parity-tests
compiler=(xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 -strict-concurrency=minimal -target "$(uname -m)-apple-macosx13.0")
check() {
    local name="$1"; shift
    echo "=== $name ==="
    "${compiler[@]}" "$@" -o "build/parity-tests/$name"
    "build/parity-tests/$name" | tee "build/parity-tests/$name-results.txt"
}
feedback=ios/CamLink/Preferences/DeliveryFeedback.swift
network=ios/CamLink/Transfer/CamLinkNetworkPolicy.swift
oauth=ios/CamLink/Transfer/OAuthSupport.swift
photo=ios/CamLink/Camera/ReceivedJPEG.swift
check camera-lifecycle ios/CamLink/Camera/CameraLifecycle.swift ios/CameraLifecycleTests.swift
check oauth-support "$oauth" ios/OAuthSupportTests.swift
check delivery-feedback "$feedback" ios/DeliveryFeedbackTests.swift
check google-drive "$oauth" "$feedback" "$network" "$photo" ios/CamLink/Transfer/GoogleDriveStore.swift ios/GoogleDriveTests.swift
check onedrive "$oauth" "$feedback" "$network" "$photo" ios/CamLink/Transfer/OneDriveStore.swift ios/OneDriveTests.swift
check multi-pc "$feedback" "$network" "$photo" ios/CamLink/Transfer/PairStore.swift ios/CamLink/Transfer/PcClient.swift ios/CamLink/Transfer/MultiPCDeliveryStore.swift ios/MultiPCTests.swift
check session-archive "$photo" ios/CamLink/Session/SessionArchive.swift ios/CamLink/Session/SessionExport.swift ios/SessionArchiveTests.swift
check session-model -D SESSION_MODEL_TESTS "$feedback" "$network" "$photo" ios/CamLink/Transfer/PairStore.swift ios/CamLink/Transfer/PcClient.swift ios/CamLink/Session/ShootSession.swift ios/CamLink/Session/SessionArchive.swift ios/CamLink/Session/SessionExport.swift ios/SessionArchiveTests.swift
