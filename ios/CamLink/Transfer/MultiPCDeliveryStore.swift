import Foundation
import Combine
import CryptoKit
#if canImport(UIKit) && canImport(Network)
import Network
#endif

/// No credentials, address or password is serialised with a destination or job.
struct PCDestinationID: Codable, Hashable, Sendable {
    let slot: PCSlotID
    let fingerprint: String
    let revision: String
    init(slot: ComputerPairSlot) {
        self.slot = slot.id
        fingerprint = slot.pair.fingerprint.lowercased()
        revision = slot.revision
    }
    var key: String { "\(slot.rawValue):\(revision):\(fingerprint)" }
    var isValid: Bool {
        UUID(uuidString: revision) != nil
            && fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
    }
    func matches(_ slot: ComputerPairSlot) -> Bool {
        slot.id == self.slot && slot.revision == revision
            && slot.pair.fingerprint.lowercased() == fingerprint && slot.pair.isReady
    }
}

enum PCJobState: String, Codable, Sendable {
    case waiting, uploading, retry, failed, verified
    var title: String {
        switch self {
        case .waiting: return "待傳"
        case .uploading: return "正在傳送"
        case .retry: return "等待重試"
        case .failed: return "需處理"
        case .verified: return "電腦已核對"
        }
    }
}

enum PCJobIssue: String, Codable, Sendable {
    case network, busy, authentication, rejected, original, cancelled, storage
    var title: String {
        switch self {
        case .network: return "接收器未能連線；請檢查同一 Wi-Fi 及地址"
        case .busy: return "電腦忙碌，正在有限次重試"
        case .authentication: return "配對碼或指紋不符；請重新核對配對"
        case .rejected: return "Receiver 未確認相同 SHA-256；不會覆寫同名原圖"
        case .original: return "本機原圖大小或 SHA-256 不符；原圖保留"
        case .cancelled: return "傳送已暫停；未視為成功"
        case .storage: return "交付紀錄未能儲存；原圖保留"
        }
    }
}

struct PCVerifiedReceipt: Codable, Equatable, Sendable {
    enum Evidence: String, Codable, Sendable { case receiverSHA256, legacyPrimaryImported }
    let destination: PCDestinationID
    let sha256: String
    let bytes: Int64
    let acceptedAt: Date
    let evidence: Evidence
}

struct PCTransferRequest: Sendable {
    let fileURL: URL
    let remoteName: String
    let sha256: String
    let bytes: Int64
}

struct PCDeliveryJob: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let destination: PCDestinationID
    let destinationLabel: String
    let photoID: String
    let sessionID: String
    let albumName: String
    let fileURL: URL
    let remoteName: String
    let sha256: String
    let bytes: Int64
    let enqueuedAt: Date
    var updatedAt: Date
    var state: PCJobState
    var attempts: Int
    var nextAttemptAt: Date?
    var issue: PCJobIssue?
    var receipt: PCVerifiedReceipt?
    var sendMilliseconds: Double?
    var identity: String {
        // Length-delimited encoding avoids ambiguous concatenations of arbitrary photo/session IDs.
        let data = try! JSONEncoder().encode([destination.key, sessionID, photoID, sha256, String(bytes)])
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
    var request: PCTransferRequest {
        PCTransferRequest(fileURL: fileURL, remoteName: remoteName, sha256: sha256, bytes: bytes)
    }
    var isValid: Bool {
        UUID(uuidString: id) != nil && destination.isValid
            && !photoID.isEmpty && photoID.utf8.count <= 1024
            && !sessionID.isEmpty && sessionID.utf8.count <= 1024
            && fileURL.isFileURL && fileURL.query == nil && fileURL.fragment == nil
            && PcClient.isSafeRemoteName(remoteName)
            && bytes > 0 && bytes <= 512 * 1024 * 1024
            && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
            && attempts >= 0 && attempts <= 1000
            && enqueuedAt.timeIntervalSince1970.isFinite && updatedAt.timeIntervalSince1970.isFinite
            && (nextAttemptAt == nil || nextAttemptAt!.timeIntervalSince1970.isFinite)
            && (sendMilliseconds == nil || (sendMilliseconds!.isFinite && sendMilliseconds! >= 0))
            && ((state == .verified && receipt?.destination == destination
                && receipt?.sha256 == sha256 && receipt?.bytes == bytes
                && receipt!.acceptedAt.timeIntervalSince1970.isFinite)
                || (state != .verified && receipt == nil))
    }
}

struct PCDeliverySnapshot: Codable, Equatable, Sendable {
    var version = 1
    var jobs: [PCDeliveryJob] = []
    /// An album's first observation is only a baseline: enabling/replacing a PC never sends old photos.
    var observedPhotoKeys: [String: Set<String>] = [:]
    var importedLegacySessions: Set<String> = []
    var paused = false
    func validate() throws {
        guard version == 1, jobs.allSatisfy(\.isValid), Set(jobs.map(\.id)).count == jobs.count,
              Set(jobs.map(\.identity)).count == jobs.count,
              observedPhotoKeys.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 })
        else { throw PCQueueError.corrupt }
    }
}

enum PCQueueError: Error, LocalizedError {
    case corrupt, storage, invalidPhoto, noDestination, remoteNameCollision, untrustedLegacy
    var errorDescription: String? {
        switch self {
        case .corrupt: return "雙電腦佇列無法讀取；已保留原資料，未自動傳送"
        case .storage: return "雙電腦佇列未能安全儲存；請檢查儲存空間"
        case .invalidPhoto: return "原圖身份、大小、SHA-256 或遠端檔名無效"
        case .noDestination: return "請先配對及選擇要傳送的電腦"
        case .remoteNameCollision: return "此電腦已有不同原圖使用相同遠端檔名；未覆寫原圖"
        case .untrustedLegacy: return "舊已傳標記沒有吻合原主電腦身份；不可當作目前電腦收據"
        }
    }
}

/// Uses the existing flat Receiver allowlist. Activity display names never become remote paths.
/// Callers may supply ShootSession.remoteName(for:) to retain the exact legacy name.
enum PCRemoteName {
    static func make(sessionID: String, photo: ReceivedJPEG) -> String {
        let legacy = "\(sessionID)_\(photo.url.lastPathComponent)".replacingOccurrences(of: " ", with: "_")
        if PcClient.isSafeRemoteName(legacy) { return legacy }
        return "s-\(digest(sessionID).prefix(20))_p-\(digest(photo.id).prefix(20))_\(photo.sha256.lowercased().prefix(20)).jpg"
    }
    private static func digest(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}

/// Local read-only size/full-file SHA preflight. Does not parse, truncate, re-encode or reject MPF JPEG.
enum PCOriginalCheck {
    static func verify(_ request: PCTransferRequest) throws {
        guard request.fileURL.isFileURL else { throw PCQueueError.invalidPhoto }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: request.fileURL) }
        catch { throw PCQueueError.invalidPhoto }
        defer { try? handle.close() }
        var hash = SHA256()
        var count: Int64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let block = try handle.read(upToCount: 1024 * 1024), !block.isEmpty else { break }
                count += Int64(block.count)
                guard count <= request.bytes else { throw PCQueueError.invalidPhoto }
                hash.update(data: block)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw PCQueueError.invalidPhoto }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == request.bytes, actual == request.sha256.lowercased() else { throw PCQueueError.invalidPhoto }
    }
}

@MainActor
final class MultiPCDeliveryStore: ObservableObject {
    typealias Transfer = @Sendable (ComputerPair, PCTransferRequest) async throws -> Void
    @Published private(set) var jobs: [PCDeliveryJob] = []
    @Published private(set) var running = false
    @Published private(set) var isPaused = false
    @Published private(set) var message = ""
    /// Fires only after a durable job transition; uses immutable job destination, not current selection.
    var onJobUpdate: ((PCDeliveryJob) -> Void)?
    /// Runtime foreground/network policy. A denied slot stays queued, with no attempt/failure increment.
    /// On a policy change the runtime may call pump again; this closure is never persisted.
    var allowsTransfer: ((PCSlotID) -> Bool)?
    let pairStore: PairStore
    private let archiveURL: URL
    private let transfer: Transfer
    private var snapshot = PCDeliverySnapshot()
    private var readOnly = false
    private var foregroundActive = true
    private var activeTransfer: Task<Void, Error>?
    private var retryWake: Task<Void, Never>?
    private let maxAttempts = 5
    #if canImport(UIKit) && canImport(Network)
    private var pathMonitor: NWPathMonitor?
    #endif

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamLink/PCDelivery", isDirectory: true)
    }
    init(pair: PairStore, directoryURL: URL = MultiPCDeliveryStore.defaultDirectory,
         transfer: @escaping Transfer = MultiPCDeliveryStore.receiverTransfer) {
        pairStore = pair
        archiveURL = directoryURL.appendingPathComponent("pc-delivery-v1.json")
        self.transfer = transfer
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            do {
                snapshot = try JSONDecoder().decode(PCDeliverySnapshot.self, from: Data(contentsOf: archiveURL))
                try snapshot.validate()
                // A killed process cannot truthfully retain an in-flight state as success.
                for index in snapshot.jobs.indices where snapshot.jobs[index].state == .uploading {
                    snapshot.jobs[index].state = .waiting
                    snapshot.jobs[index].issue = .cancelled
                    snapshot.jobs[index].attempts = max(0, snapshot.jobs[index].attempts - 1)
                }
                jobs = snapshot.jobs
                isPaused = snapshot.paused
            } catch { readOnly = true; message = PCQueueError.corrupt.localizedDescription }
        }
        #if canImport(UIKit) && canImport(Network)
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self, self.foregroundActive else { return }
                await self.pump()
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "hk.camlink.pc.path"))
        #endif
    }

    nonisolated static func receiverTransfer(_ pair: ComputerPair, _ request: PCTransferRequest) async throws {
        let check = Task.detached(priority: .utility) { try PCOriginalCheck.verify(request) }
        try await withTaskCancellationHandler(operation: { try await check.value }, onCancel: { check.cancel() })
        try Task.checkCancellation()
        try await PcClient.put(pair: pair, fileURL: request.fileURL, remoteName: request.remoteName,
            sha256: request.sha256, size: request.bytes)
    }

    /// Explicit manual import, to all currently opted-in destinations. Never called implicitly by this store.
    /// albumName is also the stable session ID for this compatibility overload; prefer the full overload.
    func enqueue(photos: [ReceivedJPEG], albumName: String) {
        do {
            try enqueue(photos: photos, sessionID: albumName, albumName: albumName,
                to: pairStore.slots.filter { $0.autoSendNewPhotos }.map(\.id))
        } catch { report(error) }
    }

    /// Explicit historical/selected-session send; slot choices must come from user confirmation.
    func enqueue(photos: [ReceivedJPEG], sessionID: String, albumName: String,
                 to slots: [PCSlotID], remoteNames: [String: String] = [:]) throws {
        let destinations = pairStore.slots.filter { slots.contains($0.id) && $0.pair.isReady }
        guard !destinations.isEmpty else { throw PCQueueError.noDestination }
        var next = snapshot
        try append(photos: photos, sessionID: sessionID, albumName: albumName,
            destinations: destinations, remoteNames: remoteNames, to: &next)
        try commit(next)
    }

    /// Call once on startup/album creation BEFORE new camera arrivals, then after each ingest.
    /// First observation baselines existing photos. Later observations enqueue only genuinely new IDs/bytes.
    /// An opt-in/receiver change never replays earlier observed photos to a newly configured computer.
    func observeNewPhotos(photos: [ReceivedJPEG], sessionID: String, albumName: String,
                          autoUploadEnabled: Bool = true,
                          remoteNames: [String: String] = [:]) {
        do {
            guard !sessionID.isEmpty, sessionID.utf8.count <= 1024 else { throw PCQueueError.invalidPhoto }
            var next = snapshot
            let current = Set(photos.map(Self.photoKey))
            let additions: [ReceivedJPEG]
            if let seen = next.observedPhotoKeys[sessionID] {
                additions = photos.filter { !seen.contains(Self.photoKey($0)) }
                next.observedPhotoKeys[sessionID] = seen.union(current)
            } else {
                additions = []
                next.observedPhotoKeys[sessionID] = current
            }
            let destinations = pairStore.slots.filter { autoUploadEnabled && $0.autoSendNewPhotos && $0.pair.isReady }
            try append(photos: additions, sessionID: sessionID, albumName: albumName,
                destinations: destinations, remoteNames: remoteNames, to: &next)
            if next != snapshot { try commit(next) }
        } catch { report(error) }
    }

    /// Only the original migrated primary identity can adopt its historical uploaded flags.
    /// Not a new remote test, never applicable to secondary/replacement receivers, once per session.
    func importLegacyPrimaryVerified(photos: [ReceivedJPEG], sessionID: String, albumName: String,
                                     identity: PCLegacyPrimaryIdentity,
                                     remoteNames: [String: String] = [:]) throws {
        guard identity == pairStore.legacyPrimaryIdentity,
              let slot = pairStore.slot(.primary), slot.pair.isReady,
              slot.revision == identity.revision,
              slot.pair.fingerprint.lowercased() == identity.fingerprint else { throw PCQueueError.untrustedLegacy }
        guard !snapshot.importedLegacySessions.contains(sessionID) else { return }
        var next = snapshot
        let oldIDs = Set(next.jobs.map(\.id))
        try append(photos: photos.filter(\.uploaded), sessionID: sessionID, albumName: albumName,
            destinations: [slot], remoteNames: remoteNames, to: &next)
        for index in next.jobs.indices where !oldIDs.contains(next.jobs[index].id) {
            next.jobs[index].state = .verified
            next.jobs[index].receipt = PCVerifiedReceipt(destination: next.jobs[index].destination,
                sha256: next.jobs[index].sha256, bytes: next.jobs[index].bytes, acceptedAt: Date(),
                evidence: .legacyPrimaryImported)
        }
        next.importedLegacySessions.insert(sessionID)
        try commit(next)
    }

    func destinationIsCurrent(_ job: PCDeliveryJob) -> Bool {
        pairStore.slot(job.destination.slot).map { job.destination.matches($0) } ?? false
    }
    func jobs(sessionID: String, slot: PCSlotID? = nil) -> [PCDeliveryJob] {
        jobs.filter { $0.sessionID == sessionID && (slot == nil || $0.destination.slot == slot) }
    }
    func verified(photoID: String, sessionID: String, destination: PCDestinationID) -> Bool {
        jobs.contains { $0.photoID == photoID && $0.sessionID == sessionID
            && $0.destination == destination && $0.state == .verified && $0.receipt != nil }
    }
    func setPaused(_ paused: Bool) {
        do {
            var next = snapshot; next.paused = paused; try commit(next)
            if paused { activeTransfer?.cancel(); retryWake?.cancel() }
        } catch { report(error) }
    }
    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        if !active { activeTransfer?.cancel(); retryWake?.cancel() }
    }
    /// Cancels only current local work/timer. A confirmed old PUT may still record its exact old receipt.
    /// Otherwise the interrupted job returns to waiting, keeping its destination, original and history.
    func cancelCurrentTransfer() {
        activeTransfer?.cancel()
        retryWake?.cancel()
    }
    /// Retries ONLY existing jobs for the unchanged current receiver; no remapping/re-upload of verified jobs.
    func retryFailed(slot: PCSlotID? = nil) {
        do {
            var next = snapshot
            for index in next.jobs.indices where next.jobs[index].state == .failed || next.jobs[index].state == .retry {
                let job = next.jobs[index]
                guard (slot == nil || job.destination.slot == slot), destinationIsCurrent(job) else { continue }
                next.jobs[index].state = .waiting
                next.jobs[index].attempts = 0
                next.jobs[index].nextAttemptAt = nil
                next.jobs[index].issue = nil
            }
            try commit(next)
        } catch { report(error) }
    }

    /// One dynamic drain. New enqueues during an await are seen by the next iteration.
    /// Each PUT captures one immutable current pair; changing selectedSlot never relabels its receipt.
    func pump() async {
        guard !running, !isPaused, foregroundActive, !readOnly else { return }
        retryWake?.cancel()
        running = true
        defer { running = false; scheduleRetry() }
        while !Task.isCancelled && !isPaused && foregroundActive && !readOnly {
            let now = Date()
            guard let job = jobs.first(where: {
                ($0.state == .waiting || $0.state == .retry) && $0.attempts < maxAttempts
                    && ($0.nextAttemptAt == nil || $0.nextAttemptAt! <= now) && destinationIsCurrent($0)
                    && (allowsTransfer?($0.destination.slot) ?? true)
            }), let slot = pairStore.slot(job.destination.slot), job.destination.matches(slot) else { break }
            let capturedPair = slot.pair
            do {
                try transition(job.id) { value in
                    value.state = .uploading; value.attempts += 1; value.issue = nil; value.nextAttemptAt = nil
                }
            } catch { report(error); break } // Never send before durable queue state.
            // A parent's synchronous onJobUpdate may pause or clear a pairing. Do not begin that PUT.
            guard destinationIsCurrent(job), !isPaused, foregroundActive, !Task.isCancelled,
                  allowsTransfer?(job.destination.slot) ?? true else {
                do {
                    try transition(job.id) { value in
                        value.state = .waiting; value.issue = .cancelled
                        value.attempts = max(0, value.attempts - 1)
                    }
                } catch { report(error); break }
                continue
            }
            let start = ProcessInfo.processInfo.systemUptime
            let send = transfer
            let task = Task { try await send(capturedPair, job.request) }
            activeTransfer = task
            do {
                try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                // A successful PUT can complete concurrently with pause/re-pair; record only its old destination.
                try transition(job.id) { value in
                    value.state = .verified
                    value.issue = nil
                    value.nextAttemptAt = nil
                    value.sendMilliseconds = max(0, (ProcessInfo.processInfo.systemUptime - start) * 1000)
                    value.receipt = PCVerifiedReceipt(destination: value.destination, sha256: value.sha256,
                        bytes: value.bytes, acceptedAt: Date(), evidence: .receiverSHA256)
                }
            } catch {
                let (issue, transient) = Self.classify(error)
                do {
                    try transition(job.id) { value in
                        value.issue = issue
                        value.receipt = nil
                        if issue == .cancelled {
                            value.state = .waiting
                            value.attempts = max(0, value.attempts - 1)
                        } else if transient && value.attempts < self.maxAttempts {
                            value.state = .retry
                            let delay = [2.0, 5.0, 15.0, 30.0][min(3, max(0, value.attempts - 1))]
                            value.nextAttemptAt = Date().addingTimeInterval(delay)
                        } else { value.state = .failed; value.nextAttemptAt = nil }
                    }
                } catch { report(error); activeTransfer = nil; break }
                if issue == .cancelled { activeTransfer = nil; break }
            }
            activeTransfer = nil
        }
    }

    private static func photoKey(_ photo: ReceivedJPEG) -> String {
        let data = try! JSONEncoder().encode([photo.id, photo.sha256.lowercased(), String(photo.bytes)])
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }
    private func append(photos: [ReceivedJPEG], sessionID: String, albumName: String,
                        destinations: [ComputerPairSlot], remoteNames: [String: String],
                        to next: inout PCDeliverySnapshot) throws {
        guard !sessionID.isEmpty, sessionID.utf8.count <= 1024 else { throw PCQueueError.invalidPhoto }
        let title = String(albumName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        for photo in photos {
            for slot in destinations {
                let now = Date()
                let job = PCDeliveryJob(id: UUID().uuidString, destination: PCDestinationID(slot: slot),
                    destinationLabel: slot.label, photoID: photo.id, sessionID: sessionID,
                    albumName: String(title.prefix(100)), fileURL: photo.url,
                    remoteName: remoteNames[photo.id] ?? PCRemoteName.make(sessionID: sessionID, photo: photo),
                    sha256: photo.sha256.lowercased(), bytes: photo.bytes, enqueuedAt: now, updatedAt: now,
                    state: .waiting, attempts: 0)
                guard job.isValid else { throw PCQueueError.invalidPhoto }
                if next.jobs.contains(where: { $0.identity == job.identity }) { continue }
                guard !next.jobs.contains(where: { $0.destination == job.destination
                    && $0.remoteName == job.remoteName && ($0.sha256 != job.sha256 || $0.bytes != job.bytes) })
                else { throw PCQueueError.remoteNameCollision }
                next.jobs.append(job)
            }
        }
    }
    private func transition(_ id: String, change: (inout PCDeliveryJob) -> Void) throws {
        var next = snapshot
        guard let index = next.jobs.firstIndex(where: { $0.id == id }) else { throw PCQueueError.corrupt }
        change(&next.jobs[index])
        next.jobs[index].updatedAt = Date()
        let changed = next.jobs[index]
        try commit(next)
        onJobUpdate?(changed)
    }
    private func commit(_ next: PCDeliverySnapshot) throws {
        guard !readOnly else { throw PCQueueError.corrupt }
        try next.validate()
        do {
            try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(next)
            #if os(iOS)
            try data.write(to: archiveURL, options: [.atomic, .completeUntilFirstUserAuthentication])
            #else
            try data.write(to: archiveURL, options: .atomic)
            #endif
        } catch { throw PCQueueError.storage }
        snapshot = next; jobs = next.jobs; isPaused = next.paused
        message = ""
    }
    private func report(_ error: Error) {
        message = (error as? PCQueueError)?.localizedDescription ?? PCQueueError.storage.localizedDescription
    }
    private func scheduleRetry() {
        retryWake?.cancel()
        guard foregroundActive, !isPaused, !readOnly,
              let earliest = jobs.filter({ $0.state == .retry && $0.attempts < maxAttempts && destinationIsCurrent($0)
                  && (allowsTransfer?($0.destination.slot) ?? true) })
                .compactMap(\.nextAttemptAt).min() else { return }
        let delay = min(60, max(0.05, earliest.timeIntervalSinceNow))
        retryWake = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            // pump cancels pending wakes; this wake has fired and must not cancel its own drain.
            self?.retryWake = nil
            await self?.pump()
        }
    }
    private static func classify(_ error: Error) -> (PCJobIssue, Bool) {
        if error is CancellationError { return (.cancelled, false) }
        if let queue = error as? PCQueueError {
            switch queue {
            case .storage, .corrupt: return (.storage, false)
            default: return (.original, false)
            }
        }
        if let url = error as? URLError {
            if url.code == .cancelled { return (.cancelled, false) }
            if [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRejected].contains(url.code) { return (.authentication, false) }
            return (.network, true)
        }
        if let pc = error as? PcClientError {
            switch pc {
            case .serverBusy: return (.busy, true)
            case .transientHTTP: return (.network, true)
            case .authFailed, .noCertificate: return (.authentication, false)
            case .unsafeRemoteName: return (.original, false)
            default: return (.rejected, false)
            }
        }
        return (.network, true) // Do not store raw errors/URLs/userInfo.
    }
}
