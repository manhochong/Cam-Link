import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Standalone real executable, not a live-account/camera/OS notification test.
// Compile ONLY this file and CamLink/Preferences/DeliveryFeedback.swift, outside the iOS app target.
@main
struct DeliveryFeedbackTests {
    struct TestFailure: Error, CustomStringConvertible { let description: String }
    @MainActor private static var assertions = 0

    @MainActor
    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !condition() { throw TestFailure(description: message) }
    }

    @MainActor
    static func main() throws {
        try networkPolicy()
        try storagePolicy()
        try evidencePolicy()
        try preferencesAndEvents()
        try persistedLogValidation()
        try notificationAndErrorSafety()
        try toneFormat()
        print("PASS DeliveryFeedbackTests: \(assertions) assertions. No live camera, account, upload or OS notification claims.")
    }

    @MainActor
    private static func networkPolicy() throws {
        var prefs = DeliveryPreferences()
        let unknown = FeedbackNetworkPath()
        let offline = FeedbackNetworkPath(known: true)
        let wifi = FeedbackNetworkPath(known: true, satisfied: true, usesWiFi: true)
        let cellular = FeedbackNetworkPath(known: true, satisfied: true, usesCellular: true, expensive: true)
        let ethernet = FeedbackNetworkPath(known: true, satisfied: true, usesEthernet: true)
        let mixed = FeedbackNetworkPath(known: true, satisfied: true, usesWiFi: true, usesCellular: true)
        let opaqueVPN = FeedbackNetworkPath(known: true, satisfied: true)
        for provider in FeedbackProvider.uploadDestinations {
            try expect(prefs.wifiOnly(for: provider), "Every missing destination defaults to Wi-Fi only")
            try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: provider, path: unknown).restriction == .unknownPath, "Unknown path fails closed")
            try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: provider, path: offline).restriction == .offline, "Offline is not success")
            try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: provider, path: wifi).allowsUploads, "Unrestricted Wi-Fi allowed")
            for nonWiFi in [cellular, ethernet, mixed, opaqueVPN] {
                try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: provider, path: nonWiFi).restriction == .wifiRequired, "Cannot call mixed, opaque or non-Wi-Fi path exclusively Wi-Fi")
            }
        }
        prefs.wifiOnlyByDestination[.googleDrive] = false
        try expect(prefs.wifiOnly(for: .oneDrive), "Per-provider setting must not silently alter OneDrive")
        try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: .googleDrive, path: cellular).restriction == .expensiveNetwork, "Cellular permission alone does not override cost preference")
        try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: .googleDrive, path: ethernet).allowsUploads, "Non-Wi-Fi allowed after explicit destination opt-out")
        prefs.allowExpensiveNetworks = true
        try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: .googleDrive, path: cellular).allowsUploads, "Explicit cellular and cost opt-in permits eligible path")
        var limited = wifi
        limited.constrained = true
        try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: .googleDrive, path: limited).restriction == .constrainedNetwork, "Low-data policy respected")
        prefs.allowConstrainedNetworks = true
        try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: .googleDrive, path: limited).allowsUploads, "Low-data opt-in respected")
        var hotspot = wifi
        hotspot.expensive = true
        prefs.allowExpensiveNetworks = false
        try expect(UploadNetworkDecision.evaluate(preferences: prefs, provider: .computer, path: hotspot).restriction == .expensiveNetwork, "Wi-Fi hotspot can be expensive")
        try expect(ReceiveScanInterval.experimental.seconds == 0.5, "Android experimental scan choice retained")
        try expect(ReceiveScanInterval.experimental.seconds(forCardImport: true) == 2, "Card import minimum two seconds")
        try expect(ReceiveScanInterval.lowInterference.seconds(forCardImport: true) == 5, "Card minimum never reduces longer interval")
    }

    @MainActor
    private static func storagePolicy() throws {
        try expect(StoragePreflight.evaluate(availableBytes: nil) == .unavailable, "No capacity reading cannot imply sufficient")
        try expect(StoragePreflight.evaluate(availableBytes: -1) == .unavailable, "Negative reading rejected")
        try expect(StoragePreflight.evaluate(availableBytes: 0).requiresAcknowledgement, "Low capacity needs acknowledgement")
        try expect(StoragePreflight.evaluate(availableBytes: 536_870_911).requiresAcknowledgement, "Reserve lower edge")
        try expect(!StoragePreflight.evaluate(availableBytes: 536_870_912).requiresAcknowledgement, "Reserve equal edge")
        try expect(StoragePreflight.evaluate(availableBytes: 100, expectedIncomingBytes: 80, reserveBytes: 21) == .low(availableBytes: 100, requiredBytes: 101), "Expected transfer plus reserve")
        try expect(StoragePreflight.evaluate(availableBytes: Int64.max - 1, expectedIncomingBytes: Int64.max, reserveBytes: 1) == .low(availableBytes: Int64.max - 1, requiredBytes: Int64.max), "Overflow saturates instead of permitting unsafe start")
        try expect(StoragePreflight.evaluate(availableBytes: 0, expectedIncomingBytes: -1, reserveBytes: -1) == .sufficient(availableBytes: 0), "Negative caller estimates clamped")
        try expect(StoragePreflight.unavailable.requiresAcknowledgement, "Unavailable reading needs confirmation")
    }

    @MainActor
    private static func evidencePolicy() throws {
        try expect(DeliveryVerification.receiverSHA256.supports(.computer), "Receiver evidence supports first computer")
        try expect(DeliveryVerification.receiverSHA256.supports(.secondComputer), "Receiver evidence supports second computer")
        try expect(!DeliveryVerification.receiverSHA256.supports(.googleDrive), "PC receipt is not Drive receipt")
        try expect(DeliveryVerification.driveSizeMD5Parent.supports(.googleDrive), "Drive evidence scoped")
        try expect(!DeliveryVerification.driveSizeMD5Parent.supports(.oneDrive), "Drive evidence is not OneDrive receipt")
        try expect(DeliveryVerification.oneDriveSize.supports(.oneDrive), "OneDrive size-only evidence scoped")
        try expect(DeliveryVerification.oneDriveSize.title.contains("不是雜湊核對"), "Size-only OneDrive must not claim hash")
        try expect(DeliveryVerification.webDAVSizeSHA256.supports(.webDAV), "WebDAV readback evidence scoped")
        try expect(!DeliveryVerification.webDAVSizeSHA256.supports(.sharing), "Share extension has no verify receipt")
        try expect(!DeliveryVerification.receiverSHA256.supports(.receiver), "Local receive is not PC remote verification")

        let readback = DeliveryVerification.googleDriveWorkerEvidence("authenticated GET 全檔大小、SHA-256、parent")
        try expect(readback == .driveDownloadedSizeSHA256Parent, "Drive full GET has its own evidence, not MD5 evidence")
        try expect(readback?.supports(.googleDrive) == true, "Drive GET evidence is provider scoped")
        try expect(readback?.supports(.oneDrive) == false && readback?.supports(.webDAV) == false, "Readback does not imply another provider succeeded")
        try expect(readback?.title.contains("GET") == true && readback?.title.contains("SHA-256") == true && readback?.title.contains("parent") == true, "GET title states exactly the measured evidence")
        try expect(readback?.title.contains("MD5") == false, "GET fallback does not claim missing MD5")
        try expect(DeliveryVerification.googleDriveWorkerEvidence("API 大小、parent、MD5、SHA-256") == .driveSizeMD5ParentSHA256, "Drive server SHA and MD5 remain distinct")
        try expect(DeliveryVerification.googleDriveWorkerEvidence("API 大小、parent、MD5（API 未提供 SHA-256）") == .driveSizeMD5Parent, "Missing-SHA wording is not SHA evidence")
        try expect(DeliveryVerification.googleDriveWorkerEvidence(nil) == nil, "No evidence is not verification")
        try expect(DeliveryVerification.googleDriveWorkerEvidence("GET SHA-256") == nil, "An incomplete or unknown evidence string fails closed")
        try expect(DeliveryVerification.googleDriveWorkerEvidence("API 未提供 SHA-256") == nil, "A SHA substring cannot fabricate a receipt")
        try expect(DeliveryVerification.oneDriveWorkerEvidence("server SHA-1") == nil, "OneDrive SHA-1 is not relabelled SHA-256")
        try expect(DeliveryVerification.oneDriveWorkerEvidence("server SHA-256 + server SHA-1") == .oneDriveSizeSHA256, "Mixed OneDrive hash evidence includes actual SHA-256")
        try expect(DeliveryVerification.oneDriveWorkerEvidence("full GET SHA-256") == .oneDriveSizeSHA256, "OneDrive full readback is actual SHA-256 evidence")
        try expect(DeliveryVerification.oneDriveWorkerEvidence(nil) == nil, "OneDrive missing worker evidence fails closed")
        let encoded = try JSONEncoder().encode(DeliveryVerification.driveDownloadedSizeSHA256Parent)
        let decoded = try JSONDecoder().decode(DeliveryVerification.self, from: encoded)
        try expect(decoded == .driveDownloadedSizeSHA256Parent, "New GET evidence has a distinct persisted enum value")
    }

    @MainActor
    private static func preferencesAndEvents() throws {
        let suite = "hk.camlink.feedback-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "Unable to create isolated defaults") }
        // Delete only this test-created namespace. No app defaults, camera/photos, or provider files touched.
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedback = DeliveryFeedback(defaults: defaults, eventLogURL: nil, monitorNetwork: false)
        defer { feedback.stopMonitoring() }
        try expect(!feedback.preferences.soundEnabled && !feedback.preferences.vibrationEnabled && !feedback.preferences.tactileEnabled, "All physical cues default opt-out")
        try expect(!feedback.preferences.localNotificationsEnabled, "Notifications default opt-out")
        var policyCallbacks = 0
        feedback.onUploadPolicyChange = { policyCallbacks += 1 }
        feedback.setWiFiOnly(false, for: .googleDrive)
        try expect(policyCallbacks == 1, "Network-setting change informs owner")
        feedback.setWiFiOnly(false, for: .googleDrive)
        try expect(policyCallbacks == 1, "Idempotent update has no callback")
        feedback.updateNetworkPath(FeedbackNetworkPath(known: true, satisfied: true, usesWiFi: true))
        try expect(policyCallbacks == 2, "Path recovery informs owner")
        feedback.updateNetworkPath(feedback.networkPath)
        try expect(policyCallbacks == 2, "Equal path has no callback")
        feedback.updatePreferences { $0.scanInterval = .lowInterference }
        let restored = DeliveryFeedback(defaults: defaults, eventLogURL: nil, monitorNetwork: false)
        defer { restored.stopMonitoring() }
        try expect(restored.preferences.scanInterval == .lowInterference && !restored.preferences.wifiOnly(for: .googleDrive), "Non-secret settings persist")
        try expect(restored.events.isEmpty, "Nil log URL disables disk event persistence")
        try expect(feedback.allowsUploads(to: .googleDrive), "Gate exposes evaluated policy")
        try expect(feedback.aboutRestrictedNetwork(for: .googleDrive).contains("不保證"), "Eligible path text does not promise delivery")
        let config = URLSessionConfiguration.ephemeral
        feedback.configureUploadSession(config, for: .computer)
        try expect(!config.allowsCellularAccess, "Wi-Fi-only maps onto transport configuration")
        var request = URLRequest(url: URL(string: "https://example.invalid/no-network-test")!)
        feedback.configureUploadRequest(&request, for: .googleDrive)
        try expect(request.allowsCellularAccess, "Explicit provider opt-out maps onto request")
        #if canImport(Darwin)
        try expect(!request.allowsExpensiveNetworkAccess && !request.allowsConstrainedNetworkAccess, "Request carries cost and low-data restrictions")
        #endif
        let capture = UUID()
        feedback.firstReceived(sessionID: capture)
        feedback.firstReceived(sessionID: capture)
        try expect(feedback.events.filter { $0.kind == .firstReceived }.count == 1, "First locally received cue deduped per run")
        try expect(feedback.banner?.detail.contains("不代表任何目的地") == true, "Local first image does not claim remote delivery")
        let nextRun = UUID()
        feedback.firstReceived(sessionID: nextRun)
        feedback.firstReceived(sessionID: nextRun)
        try expect(feedback.events.filter { $0.kind == .firstReceived }.count == 2, "A later receive run in the same album gets one new first-photo cue")
        feedback.uploadAccepted(by: .googleDrive, sessionID: capture)
        try expect(feedback.events.last?.kind == .uploadAccepted, "Accepted event recorded")
        try expect(feedback.banner?.kind == .firstReceived, "Accepted-only does not issue a success cue")
        try expect(!feedback.events.contains { $0.kind == .destinationVerified }, "HTTP acceptance not verified")
        let invalid = feedback.destinationVerified(.googleDrive, evidence: .receiverSHA256, sessionID: capture)
        try expect(!invalid && feedback.events.last?.reason == .configuration, "Wrong-provider evidence rejected")
        let valid = feedback.destinationVerified(.googleDrive, evidence: .driveSizeMD5Parent, sessionID: capture)
        try expect(valid && feedback.events.last?.verification == .driveSizeMD5Parent, "Only matching actual evidence can label verify level")
        feedback.recordFailure(provider: .oneDrive, reason: .rateLimited, httpStatus: 429, sessionID: capture)
        feedback.recordFailure(provider: .oneDrive, reason: .rateLimited, httpStatus: 429, sessionID: capture)
        try expect(feedback.events.last?.occurrences == 2, "Repeated error counted despite alert throttle")
        feedback.recordFailure(provider: .googleDrive, reason: .rateLimited, httpStatus: 429, sessionID: capture)
        try expect(feedback.events.last?.occurrences == 1 && feedback.events.last?.provider == .googleDrive, "Different provider errors never merged")
        feedback.recordFailure(provider: .googleDrive, reason: .network, httpStatus: 900, sessionID: UUID())
        try expect(feedback.events.last?.httpStatus == nil, "Invalid HTTP status discarded")
        feedback.receivingFinished(sessionID: capture, verified: 5, failed: 0, pending: 1, cleanStop: true)
        try expect(feedback.events.last?.kind == .receiveIncomplete, "Pending local work cannot be finished")
        feedback.receivingFinished(sessionID: capture, verified: 5, failed: 0, pending: 0, cleanStop: false)
        try expect(feedback.events.last?.kind == .receiveIncomplete, "Interrupted run cannot be finished")
        feedback.receivingFinished(sessionID: capture, verified: 5, failed: 1, pending: 0, cleanStop: true)
        try expect(feedback.events.last?.kind == .receiveFinished && feedback.events.last?.isWarning == true, "Drained run with failures remains warning")
        try expect(feedback.events.last?.detail.contains("不代表所有目的地") == true, "Local finish not all-provider finish")
        feedback.receivingFinished(sessionID: capture, verified: -1, failed: -2, pending: -3, cleanStop: false)
        try expect(feedback.events.last?.goodCount == 0 && feedback.events.last?.failedCount == 0 && feedback.events.last?.pendingCount == 0, "Negative counts clamped")
        feedback.dismissBanner()
        try expect(feedback.banner == nil, "Banner dismiss is not event deletion")
        let exported = try JSONDecoder().decode([DeliveryFeedbackEvent].self, from: feedback.diagnosticData())
        try expect(exported == feedback.events, "Structured diagnostic export round-trips")
        try expect(feedback.diagnosticText().contains("Local receipt != destination verification"), "Support report carries stage distinction")
        for i in 0..<300 {
            feedback.recordFailure(provider: i.isMultiple(of: 2) ? .computer : .webDAV, reason: .network)
        }
        try expect(feedback.events.count == 256, "Event memory bounded to 256")
        try expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("hk.camlink.delivery-feedback") }.count == 1, "Only one non-secret settings payload in defaults")
        // No enabling native cues and no notification request from this test.
    }

    @MainActor
    private static func persistedLogValidation() throws {
        let suite = "hk.camlink.feedback-persistence-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "Unable to create isolated defaults") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CamLinkFeedbackTests-\(UUID().uuidString)", isDirectory: true)
        let log = root.appendingPathComponent("events.json")
        // Clean ONLY this uniquely created test directory; never use app/camera/provider paths.
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let feedback = DeliveryFeedback(defaults: defaults, eventLogURL: log, monitorNetwork: false)
        defer { feedback.stopMonitoring() }
        feedback.recordFailure(provider: .webDAV, reason: .verificationMismatch, httpStatus: 200)
        try expect(feedback.destinationVerified(.googleDrive, evidence: .driveDownloadedSizeSHA256Parent), "New Google readback event is accepted")
        let restored = DeliveryFeedback(defaults: defaults, eventLogURL: log, monitorNetwork: false)
        defer { restored.stopMonitoring() }
        try expect(restored.events == feedback.events, "Actual atomic event file restores")
        try expect(restored.events.last?.verification == .driveDownloadedSizeSHA256Parent, "GET evidence survives event-log restore without becoming MD5")
        try expect(restored.banner == nil, "Loading old receipt events does not emit an old success banner")
        let data = try Data(contentsOf: log)
        let wire = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        let allowedKeys: Set<String> = ["id", "sessionID", "provider", "kind", "verification", "reason", "httpStatus", "goodCount", "failedCount", "pendingCount", "firstAt", "lastAt", "occurrences"]
        try expect(wire?.allSatisfy { Set($0.keys).isSubset(of: allowedKeys) } == true, "Event schema has no channel for freeform secrets")
        var corrupt = wire ?? []
        for index in corrupt.indices { corrupt[index]["occurrences"] = -1 }
        try JSONSerialization.data(withJSONObject: corrupt).write(to: log, options: .atomic)
        let rejected = DeliveryFeedback(defaults: defaults, eventLogURL: log, monitorNetwork: false)
        defer { rejected.stopMonitoring() }
        try expect(rejected.events.isEmpty, "Invalid persisted occurrence count rejected")
        try Data("malformed-event-json".utf8).write(to: log, options: .atomic)
        let malformed = DeliveryFeedback(defaults: defaults, eventLogURL: log, monitorNetwork: false)
        defer { malformed.stopMonitoring() }
        try expect(malformed.events.isEmpty, "Malformed event file cannot claim verification")
        try expect(FileManager.default.fileExists(atPath: log.path), "Invalid log is not deleted during load")
    }

    @MainActor
    private static func notificationAndErrorSafety() throws {
        // Harmless synthetic sentinels, never real credentials. They must not enter event diagnostics.
        let error = NSError(domain: "TEST_ONLY_PRIVATE_PAYLOAD", code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "TEST_ONLY_RAW_ERROR", NSURLErrorKey: URL(string: "https://example.invalid/private")!])
        try expect(FeedbackFailureReason.classify(error) == .unknown, "Arbitrary NSError does not expose provider payload")
        try expect(FeedbackFailureReason.classify(URLError(.timedOut)) == .timeout, "URL timeout classified without URL logging")
        try expect(FeedbackFailureReason.classify(URLError(.cancelled)) == .cancelled, "URL cancellation remains cancellation")
        try expect(FeedbackFailureReason.classify(CancellationError()) == .cancelled, "Task cancellation classified")
        try expect(FeedbackFailureReason.classify(URLError(.notConnectedToInternet)) == .network, "Network failure classified")
        let suite = "hk.camlink.feedback-safety-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw TestFailure(description: "Unable to create isolated defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedback = DeliveryFeedback(defaults: defaults, eventLogURL: nil, monitorNetwork: false)
        defer { feedback.stopMonitoring() }
        feedback.recordFailure(provider: .googleDrive, reason: FeedbackFailureReason.classify(error))
        let json = String(decoding: try feedback.diagnosticData(), as: UTF8.self)
        try expect(!json.contains("TEST_ONLY") && !feedback.diagnosticText().contains("example.invalid"), "Raw error metadata excluded from both exports")
        // Programmatic preference changes never call requestAuthorization. Do not invoke the explicit
        // user-action method here: a real UNUserNotificationCenter must not be touched by pure tests.
        feedback.updatePreferences { $0.localNotificationsEnabled = true }
        try expect(feedback.notificationAuthorization == .notRequested, "Saving preference never requests OS authorization")
        feedback.updatePreferences { $0.localNotificationsEnabled = false }
        try expect(!feedback.preferences.localNotificationsEnabled, "Notification opt-out persists without permission calls")
    }

    @MainActor
    private static func toneFormat() throws {
        let data = DeliveryFeedback.toneWAV()
        try expect(data.count == 44 + 1764 * 2, "Generated sound has correct PCM size")
        try expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF", "WAV RIFF signature")
        try expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE", "WAV format signature")
        try expect(String(decoding: data[36..<40], as: UTF8.self) == "data", "WAV data chunk signature")
    }
}
