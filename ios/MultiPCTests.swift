import Foundation
import CryptoKit

// OFFLINE deterministic tests. Injectable transport never connects, logs in or writes to a real PC.
private enum CheckFailure: Error { case failed(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.failed(message) }
}

@MainActor
private final class MemoryPairCredentials: PairCredentialStorage {
    var values: [PCSlotID: String] = [.primary: "offline-test-primary", .secondary: "offline-test-secondary"]
    var unavailable: Set<PCSlotID> = []
    var saves = 0
    func load(slot: PCSlotID) -> String? { unavailable.contains(slot) ? nil : values[slot] }
    func save(_ value: String, slot: PCSlotID) -> Bool { values[slot] = value; saves += 1; return true }
    func clear(slot: PCSlotID) -> Bool { values.removeValue(forKey: slot); return true }
}

private struct OfflineEvent: Sendable {
    let fingerprint: String
    let name: String
}
private actor OfflineTransport {
    private var events: [OfflineEvent] = []
    private var holdFirst: Bool
    private var held: CheckedContinuation<Void, Never>?
    private let rejectFingerprint: String?
    private var rejectionsLeft: Int?
    init(holdFirst: Bool = false, rejectFingerprint: String? = nil, rejectionsLeft: Int? = nil) {
        self.holdFirst = holdFirst
        self.rejectFingerprint = rejectFingerprint
        self.rejectionsLeft = rejectionsLeft
    }
    func send(_ pair: ComputerPair, _ request: PCTransferRequest) async throws {
        events.append(.init(fingerprint: pair.fingerprint, name: request.remoteName))
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { held = $0 }
        }
        if pair.fingerprint == rejectFingerprint {
            if let remaining = rejectionsLeft {
                if remaining > 0 { rejectionsLeft = remaining - 1; throw PcClientError.serverBusy }
            } else { throw PcClientError.serverBusy }
        }
    }
    func release() { held?.resume(); held = nil }
    func count() -> Int { events.count }
    func allEvents() -> [OfflineEvent] { events }
    func isHeld() -> Bool { held != nil }
}

@MainActor
private final class Fixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let credentials = MemoryPairCredentials()
    let firstFinger = String(repeating: "a", count: 64)
    let secondFinger = String(repeating: "b", count: 64)
    let firstRevision = UUID().uuidString
    let secondRevision = UUID().uuidString
    init() throws {
        suite = "hk.camlink.offline-multipc-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent("camlink-multipc-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func seedSlots(firstFingerprint: String? = nil, firstRevision replacementRevision: String? = nil) throws {
        let metadata = PCPairPreferences(selectedSlot: .primary, slots: [
            PCSlotMetadata(id: .primary, label: "Offline primary", revision: replacementRevision ?? firstRevision,
                host: "127.0.0.1", fingerprint: firstFingerprint ?? firstFinger, autoSendNewPhotos: true),
            PCSlotMetadata(id: .secondary, label: "Offline secondary", revision: secondRevision,
                host: "127.0.0.2", fingerprint: secondFinger, autoSendNewPhotos: true)
        ])
        defaults.set(try JSONEncoder().encode(metadata), forKey: PairStore.preferencesKey)
    }
    func makePair() -> PairStore { PairStore(defaults: defaults, credentials: credentials) }
    func photo(_ id: String, uploaded: Bool = false, suffix: String = "jpg") throws -> ReceivedJPEG {
        // Synthetic bytes deliberately include content after an EOI-like marker; not a camera fixture.
        let bytes = Data([0xff, 0xd8, 0x01, 0xff, 0xd9, 0x4d, 0x50, 0x46] + Array(id.utf8))
        let url = root.appendingPathComponent("\(id).\(suffix)")
        try bytes.write(to: url)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return ReceivedJPEG(id: id, name: url.lastPathComponent, url: url, bytes: Int64(bytes.count),
            sha256: hash, createdAt: Date(), uploaded: uploaded)
    }
    func cleanup() {
        // Only this fixture's fresh suite and temporary directory, never application/user data.
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@main
private enum MultiPCTests {
    @MainActor static func main() async throws {
        try migrationAndCredentials()
        try remoteNamesAndOriginals()
        try legacyReceiptImport()
        try await dynamicDrainAndReplacement()
        try await independentFailureAndBudget()
        try await automaticRetryAndInterruptedRecovery()
        try await policyGateAndCancellation()
        try corruptArchivePreserved()
        print("PASS: offline MultiPC deterministic tests (NOT live PC acceptance)")
    }

    @MainActor private static func migrationAndCredentials() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.defaults.set("127.0.0.1", forKey: "pc.host")
        fixture.defaults.set(fixture.firstFinger, forKey: "pc.finger")
        fixture.defaults.set("obsolete-plaintext-test-code", forKey: "pc.code")
        let pair = fixture.makePair()
        try check(pair.pair.isReady, "legacy primary must remain ready")
        try check(pair.pair.password == "offline-test-primary", "existing Keychain primary must win")
        try check(fixture.credentials.saves == 0, "existing primary credential must not be rewritten")
        try check(fixture.defaults.string(forKey: "pc.code") == nil, "remove obsolete legacy plaintext only after secure existing code")
        try check(pair.slots.count == 2 && pair.slot(.secondary)?.pair.isReady == false, "exactly two slots")
        try check(pair.legacyPrimaryIdentity?.fingerprint == fixture.firstFinger, "capture legacy identity once")
        pair.selectSlot(.secondary)
        try check(pair.pair.fingerprint == fixture.firstFinger, "legacy pair always means primary")
        try check(pair.applyQR("camlink://pair?ip=127.0.0.2&code=abcdef012345", to: .secondary), "QR target slot")
        try check(!pair.hasPendingFingerprint && !pair.selectedPair.isReady, "QR must not trust certificate")
        let metadataData = fixture.defaults.data(forKey: PairStore.preferencesKey)!
        let metadataText = String(decoding: metadataData, as: UTF8.self)
        try check(!metadataText.contains("offline-test-primary") && !metadataText.contains("abcdef012345"), "metadata excludes codes")
        let identity = pair.legacyPrimaryIdentity
        let restored = fixture.makePair()
        try check(restored.legacyPrimaryIdentity == identity, "migration identity stable after relaunch")
        fixture.credentials.unavailable = [.primary]
        let locked = fixture.makePair()
        try check(!locked.pair.isReady && locked.pair.host == "127.0.0.1", "locked Keychain does not erase host")
        let lockedPreferences = try JSONDecoder().decode(PCPairPreferences.self,
            from: fixture.defaults.data(forKey: PairStore.preferencesKey)!)
        try check(lockedPreferences.slots.first { $0.id == .primary }?.fingerprint == fixture.firstFinger,
            "locked Keychain must preserve fingerprint metadata")
        fixture.credentials.unavailable = []
        try check(fixture.makePair().pair.isReady, "unlock restores legacy primary without re-pair")
        let invalid = Data("unreadable-existing-pair-record".utf8)
        fixture.defaults.set(invalid, forKey: PairStore.preferencesKey)
        let unreadable = fixture.makePair()
        unreadable.clear(.primary)
        try check(fixture.defaults.data(forKey: PairStore.preferencesKey) == invalid, "unreadable metadata not overwritten")
        try check(fixture.credentials.values[.primary] != nil, "unreadable metadata never authorizes credential deletion")
    }

    @MainActor private static func remoteNamesAndOriginals() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.seedSlots()
        let pair = fixture.makePair()
        let transport = OfflineTransport()
        let store = MultiPCDeliveryStore(pair: pair, directoryURL: fixture.root.appendingPathComponent("queue"),
            transfer: { try await transport.send($0, $1) })
        let photo = try fixture.photo("MPF-tail", uploaded: true)
        let name = PCRemoteName.make(sessionID: "20261108-120000", photo: photo)
        try check(name == "20261108-120000_MPF-tail.jpg", "preserve exact safe legacy filename")
        try check(PcClient.isSafeRemoteName(PCRemoteName.make(sessionID: "婚禮/../test", photo: photo)), "non-ASCII album safe flat name")
        for bad in ["../bad.jpg", "a/b.jpg", "a%2fb.jpg", "a.jpg?token=x", "a..jpg", "a.jpg#fragment"] {
            try check(!PcClient.isSafeRemoteName(bad), "reject traversal/query/escape: \(bad)")
        }
        let request = PCTransferRequest(fileURL: photo.url, remoteName: name, sha256: photo.sha256, bytes: photo.bytes)
        try PCOriginalCheck.verify(request)
        try store.enqueue(photos: [photo], sessionID: "session", albumName: "活動", to: [.primary, .secondary])
        try check(store.jobs.count == 2 && store.jobs.allSatisfy { $0.state == .waiting }, "uploaded flag is not a new destination receipt")
        let data = try JSONEncoder().encode(PCDeliverySnapshot(jobs: store.jobs))
        let decoded = try JSONDecoder().decode(PCDeliverySnapshot.self, from: data)
        try decoded.validate()
        try check(decoded.jobs == store.jobs, "job codec roundtrip")
        let text = String(decoding: data, as: UTF8.self)
        try check(!text.contains("offline-test-primary") && !text.contains("offline-test-secondary"), "durable queue excludes credentials")
        do {
            try store.enqueue(photos: [photo], sessionID: "bad", albumName: "bad", to: [.primary],
                remoteNames: [photo.id: "../bad.jpg"])
            throw CheckFailure.failed("unsafe remote name accepted")
        } catch is PCQueueError {}
        let other = try fixture.photo("different-content")
        do {
            try store.enqueue(photos: [other], sessionID: "session", albumName: "Activity", to: [.primary],
                remoteNames: [other.id: store.jobs[0].remoteName])
            throw CheckFailure.failed("different originals accepted same remote destination/name")
        } catch PCQueueError.remoteNameCollision {}
        try Data([0x00]).write(to: photo.url)
        do {
            try PCOriginalCheck.verify(request)
            throw CheckFailure.failed("modified original accepted")
        } catch is PCQueueError {}
        var invalid = decoded
        invalid.jobs[0].state = .verified // No receipt is not verification.
        do {
            try invalid.validate()
            throw CheckFailure.failed("verified job without receiver evidence accepted")
        } catch is PCQueueError {}
    }

    @MainActor private static func legacyReceiptImport() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        fixture.defaults.set("127.0.0.1", forKey: "pc.host")
        fixture.defaults.set(fixture.firstFinger, forKey: "pc.finger")
        let pair = fixture.makePair()
        let transport = OfflineTransport()
        let store = MultiPCDeliveryStore(pair: pair, directoryURL: fixture.root.appendingPathComponent("queue"),
            transfer: { try await transport.send($0, $1) })
        let verified = try fixture.photo("old-verified", uploaded: true)
        let pending = try fixture.photo("old-pending")
        let identity = pair.legacyPrimaryIdentity!
        try store.importLegacyPrimaryVerified(photos: [verified, pending], sessionID: "legacy", albumName: "Legacy", identity: identity)
        try check(store.jobs.count == 1 && store.jobs[0].receipt?.evidence == .legacyPrimaryImported,
            "only original primary uploaded flags imported with explicit evidence")
        try check(store.jobs[0].receipt?.sha256 == verified.sha256 && store.jobs[0].receipt?.bytes == verified.bytes,
            "legacy receipt binds expected hash and size")
        var later = pending; later.uploaded = true
        try store.importLegacyPrimaryVerified(photos: [later], sessionID: "legacy", albumName: "Legacy", identity: identity)
        try check(store.jobs.count == 1, "legacy migration cannot adopt later flags")
        pair.clear(.primary)
        do {
            try store.importLegacyPrimaryVerified(photos: [verified], sessionID: "other", albumName: "Other", identity: identity)
            throw CheckFailure.failed("cleared receiver accepted old proof")
        } catch is PCQueueError {}
        try check(FileManager.default.fileExists(atPath: verified.url.path), "forget pairing never deletes originals")
    }

    @MainActor private static func dynamicDrainAndReplacement() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.seedSlots()
        let pair = fixture.makePair()
        let transport = OfflineTransport(holdFirst: true)
        let directory = fixture.root.appendingPathComponent("queue")
        let store = MultiPCDeliveryStore(pair: pair, directoryURL: directory, transfer: { try await transport.send($0, $1) })
        store.observeNewPhotos(photos: [], sessionID: "capture", albumName: "Capture")
        let first = try fixture.photo("first", uploaded: true)
        store.observeNewPhotos(photos: [first], sessionID: "capture", albumName: "Capture")
        try check(store.jobs.count == 2, "new photo enqueued independently for both opted-in slots")
        let worker = Task { @MainActor in await store.pump() }
        for _ in 0..<10000 {
            if await transport.isHeld() { break }
            await Task.yield()
        }
        let held = await transport.isHeld()
        if !held { worker.cancel(); await transport.release() }
        try check(held, "offline worker entered controlled suspension")
        let second = try fixture.photo("second")
        store.observeNewPhotos(photos: [first, second], sessionID: "capture", albumName: "Capture")
        pair.selectSlot(.secondary)
        pair.clear(.primary)
        await transport.release()
        await worker.value
        let sent = await transport.allEvents()
        try check(sent.count == 3, "new arrivals drained; cleared primary's next job never sent")
        try check(sent.filter { $0.fingerprint == fixture.firstFinger }.count == 1, "inflight request retains captured original pair")
        try check(store.jobs.filter { $0.state == .verified }.count == 3, "independent accepted receipts")
        let oldPrimaryReceipt = store.jobs.first { $0.photoID == first.id && $0.destination.slot == .primary }!
        try check(oldPrimaryReceipt.receipt?.destination.fingerprint == fixture.firstFinger,
            "clearing/switching cannot relabel completed request")
        try check(!store.destinationIsCurrent(oldPrimaryReceipt), "old destination is visibly archived")
        let newFingerprint = String(repeating: "c", count: 64)
        try fixture.seedSlots(firstFingerprint: newFingerprint, firstRevision: UUID().uuidString)
        fixture.credentials.values[.primary] = "offline-test-new-primary"
        let replacementPair = fixture.makePair()
        let restored = MultiPCDeliveryStore(pair: replacementPair, directoryURL: directory,
            transfer: { try await transport.send($0, $1) })
        await restored.pump()
        try check(await transport.count() == 3, "replacement receiver cannot inherit/send old jobs")
        restored.observeNewPhotos(photos: [first, second], sessionID: "capture", albumName: "Capture")
        try check(restored.jobs.count == 4, "changing destination does not auto-replay old photos")
        try restored.enqueue(photos: [first], sessionID: "capture", albumName: "Capture", to: [.primary])
        try check(restored.jobs.last?.state == .waiting, "manual replay to new receiver needs independent verification")
        restored.setPaused(true)
        await restored.pump()
        try check(await transport.count() == 3, "durable global pause prevents starting transfer")
        restored.setPaused(false)
        await restored.pump()
        try check(await transport.count() == 4 && restored.jobs.last?.receipt?.destination.fingerprint == newFingerprint,
            "new receiver receives only explicitly enqueued new identity")
        // Global automatic policy still observes IDs while off, so enabling cannot silently replay them.
        let third = try fixture.photo("third")
        restored.observeNewPhotos(photos: [first, second, third], sessionID: "capture", albumName: "Capture", autoUploadEnabled: false)
        restored.observeNewPhotos(photos: [first, second, third], sessionID: "capture", albumName: "Capture", autoUploadEnabled: true)
        try check(restored.jobs.count == 5, "auto policy enable does not retroactively enqueue old arrivals")
    }

    @MainActor private static func independentFailureAndBudget() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.seedSlots()
        let pair = fixture.makePair()
        let transport = OfflineTransport(rejectFingerprint: fixture.firstFinger)
        let directory = fixture.root.appendingPathComponent("queue")
        let store = MultiPCDeliveryStore(pair: pair, directoryURL: directory,
            transfer: { try await transport.send($0, $1) })
        let photo = try fixture.photo("failure-budget")
        try store.enqueue(photos: [photo], sessionID: "retry", albumName: "Retry", to: [.primary, .secondary])
        await store.pump()
        store.setForegroundActive(false) // cancel its finite retry timer for this isolated test.
        try check(store.jobs.first { $0.destination.slot == .primary }?.state == .retry, "503 gets finite delayed retry")
        try check(store.jobs.first { $0.destination.slot == .secondary }?.state == .verified, "busy first PC never blocks second")
        var snapshot = try JSONDecoder().decode(PCDeliverySnapshot.self,
            from: Data(contentsOf: directory.appendingPathComponent("pc-delivery-v1.json")))
        let index = snapshot.jobs.firstIndex { $0.destination.slot == .primary }!
        snapshot.jobs[index].attempts = 4
        snapshot.jobs[index].state = .waiting
        snapshot.jobs[index].nextAttemptAt = nil
        try JSONEncoder().encode(snapshot).write(to: directory.appendingPathComponent("pc-delivery-v1.json"), options: .atomic)
        let finalAttempt = MultiPCDeliveryStore(pair: pair, directoryURL: directory,
            transfer: { try await transport.send($0, $1) })
        await finalAttempt.pump()
        try check(finalAttempt.jobs[index].attempts == 5 && finalAttempt.jobs[index].state == .failed,
            "503 stops after five attempts until explicit retry")
        finalAttempt.retryFailed(slot: .primary)
        try check(finalAttempt.jobs[index].state == .waiting && finalAttempt.jobs[index].attempts == 0,
            "manual retry resets only current receiver's failed jobs")
    }

    @MainActor private static func automaticRetryAndInterruptedRecovery() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.seedSlots()
        let pair = fixture.makePair()
        let transport = OfflineTransport(rejectFingerprint: fixture.firstFinger, rejectionsLeft: 1)
        let directory = fixture.root.appendingPathComponent("queue")
        let store = MultiPCDeliveryStore(pair: pair, directoryURL: directory,
            transfer: { try await transport.send($0, $1) })
        try store.enqueue(photos: [fixture.photo("delayed-retry")], sessionID: "retry", albumName: "Retry", to: [.primary])
        await store.pump()
        let deadline = Date().addingTimeInterval(5)
        while store.jobs[0].state != .verified && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        store.setForegroundActive(false)
        try check(store.jobs[0].state == .verified && store.jobs[0].attempts == 2,
            "real finite timer must invoke a retry, not cancel its own drain")
        let archive = directory.appendingPathComponent("pc-delivery-v1.json")
        var interrupted = try JSONDecoder().decode(PCDeliverySnapshot.self, from: Data(contentsOf: archive))
        interrupted.jobs[0].state = .uploading
        interrupted.jobs[0].receipt = nil
        interrupted.jobs[0].attempts = 5
        try JSONEncoder().encode(interrupted).write(to: archive, options: .atomic)
        let recovered = MultiPCDeliveryStore(pair: pair, directoryURL: directory,
            transfer: { try await transport.send($0, $1) })
        try check(recovered.jobs[0].state == .waiting && recovered.jobs[0].attempts == 4,
            "killed final attempt remains recoverable and is never premarked verified")
        await recovered.pump()
        try check(recovered.jobs[0].state == .verified && recovered.jobs[0].attempts == 5,
            "interrupted attempt recovers only after new transport acceptance")
    }

    @MainActor private static func policyGateAndCancellation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.seedSlots()
        let pair = fixture.makePair()
        let transport = OfflineTransport()
        let store = MultiPCDeliveryStore(pair: pair, directoryURL: fixture.root.appendingPathComponent("policy"),
            transfer: { try await transport.send($0, $1) })
        store.allowsTransfer = { $0 == .secondary }
        try store.enqueue(photos: [fixture.photo("policy")], sessionID: "policy", albumName: "Policy", to: [.primary, .secondary])
        await store.pump()
        try check(store.jobs[0].state == .waiting && store.jobs[0].attempts == 0,
            "policy-denied destination remains waiting with zero attempts")
        try check(store.jobs[1].state == .verified, "denied slot never blocks allowed destination")
        store.allowsTransfer = { _ in true }
        await store.pump()
        try check(store.jobs[0].state == .verified, "explicit policy change/pump resumes unchanged job")
        let cancelled = MultiPCDeliveryStore(pair: pair, directoryURL: fixture.root.appendingPathComponent("cancel"),
            transfer: { _, _ in try await Task.sleep(nanoseconds: 30_000_000_000) })
        try cancelled.enqueue(photos: [fixture.photo("cancel")], sessionID: "cancel", albumName: "Cancel", to: [.primary])
        let worker = Task { @MainActor in await cancelled.pump() }
        for _ in 0..<10000 {
            if cancelled.jobs.first?.state == .uploading { break }
            await Task.yield()
        }
        cancelled.cancelCurrentTransfer()
        await worker.value
        try check(cancelled.jobs[0].state == .waiting && cancelled.jobs[0].receipt == nil && cancelled.jobs[0].attempts == 0,
            "cancellation retains source/destination and never fabricates acceptance")
    }

    @MainActor private static func corruptArchivePreserved() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        try fixture.seedSlots()
        let pair = fixture.makePair()
        let directory = fixture.root.appendingPathComponent("queue")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("pc-delivery-v1.json")
        let bytes = Data("unreadable-existing-jobs".utf8)
        try bytes.write(to: archive)
        let transport = OfflineTransport()
        let store = MultiPCDeliveryStore(pair: pair, directoryURL: directory,
            transfer: { try await transport.send($0, $1) })
        try check(!store.message.isEmpty, "corruption blocks queue")
        do {
            try store.enqueue(photos: [fixture.photo("retained")], sessionID: "s", albumName: "s", to: [.primary])
            throw CheckFailure.failed("corrupt queue overwritten")
        } catch is PCQueueError {}
        try check(try Data(contentsOf: archive) == bytes, "unreadable archive bytes retained")
    }
}
