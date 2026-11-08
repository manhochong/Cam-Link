import Combine
import Foundation

/// Composition root: one camera, one local archive, independent durable destination queues.
@MainActor
final class CamLinkRuntime: ObservableObject {
    let camera: CameraCaptureService
    let session: ShootSession
    let pair: PairStore
    let pc: MultiPCDeliveryStore
    let webDAV: WebDAVStore
    let google: GoogleDriveStore
    let oneDrive: OneDriveStore
    let feedback: DeliveryFeedback
    private var subscriptions = Set<AnyCancellable>()
    private var foreground = true
    private var restored = false
    private var policySuspended = Set<FeedbackProvider>()
    private var knownStates: [String: String] = [:]
    private var captureRun = UUID()
    private var cleanStopRequested = false
    private var syncingPolicy = false

    init() {
        camera = CameraCaptureService()
        session = ShootSession()
        pair = PairStore()
        pc = MultiPCDeliveryStore(pair: pair)
        webDAV = WebDAVStore()
        let coordinator = OAuthCoordinator()
        google = GoogleDriveStore(coordinator: coordinator)
        oneDrive = OneDriveStore(coordinator: coordinator)
        feedback = DeliveryFeedback()
        baselinePC()
        camera.onJPEG = { [weak self] original in self?.ingest(original) }
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .firstPhoto: self.feedback.firstReceived(sessionID: self.captureRun)
            case let .receivingCompleted(_, received, failed):
                self.feedback.receivingFinished(sessionID: self.captureRun, verified: received,
                    failed: failed, pending: self.camera.queuedCount, cleanStop: true)
            case .receivingInterrupted:
                self.feedback.receivingFinished(sessionID: self.captureRun, verified: self.camera.receivedCount,
                    failed: self.camera.failedCount, pending: self.camera.queuedCount, cleanStop: false)
            case .deliveryAttention: break // Worker transitions below own destination feedback.
            case .persistenceFailed: self.feedback.recordFailure(provider: .application, reason: .localStorage)
            }
        }
        camera.$browsing.dropFirst().removeDuplicates().sink { [weak self] active in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if active { self.session.receivingDidStart() }
                else if self.cleanStopRequested { self.session.receivingDidFinish(failedCount: self.camera.failedCount) }
                else { self.session.receivingDidInterrupt() }
            }
        }.store(in: &subscriptions)
        for publisher in [pc.$jobs.map { _ in true }.eraseToAnyPublisher(),
                          google.$jobs.map { _ in true }.eraseToAnyPublisher(),
                          oneDrive.$jobs.map { _ in true }.eraseToAnyPublisher(),
                          webDAV.$jobs.map { _ in true }.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.synchronizeReports() }
            }.store(in: &subscriptions)
        }
        google.$wifiOnly.dropFirst().removeDuplicates().sink { [weak self] wifi in
            Task { @MainActor [weak self] in self?.feedback.setWiFiOnly(wifi, for: .googleDrive) }
        }.store(in: &subscriptions)
        oneDrive.$wifiOnly.dropFirst().removeDuplicates().sink { [weak self] wifi in
            Task { @MainActor [weak self] in self?.feedback.setWiFiOnly(wifi, for: .oneDrive) }
        }.store(in: &subscriptions)
        pc.allowsTransfer = { [weak feedback] slot in
            feedback?.allowsUploads(to: slot == .primary ? .computer : .secondComputer) ?? false
        }
        feedback.onUploadPolicyChange = { [weak self] in self?.refreshPolicy() }
        refreshPolicy()
    }

    func startReceiving(_ mode: CameraCaptureService.ReceiveMode) {
        guard camera.canStart else { return }
        baselinePC()
        captureRun = UUID()
        cleanStopRequested = false
        camera.scanIntervalSeconds = feedback.preferences.scanInterval.seconds(forCardImport: mode == .card)
        camera.mode = mode
        camera.startBrowsing()
    }
    func finishReceiving() { cleanStopRequested = true; camera.finishReceiving() }
    func interruptReceiving() { cleanStopRequested = false; camera.stopBrowsing() }
    func baselinePC() {
        pc.observeNewPhotos(photos: session.photos, sessionID: session.sessionId,
            albumName: session.albumName, autoUploadEnabled: session.autoUpload,
            remoteNames: Dictionary(uniqueKeysWithValues: session.photos.map { ($0.id, session.remoteName(for: $0)) }))
        if let identity = pair.legacyPrimaryIdentity {
            try? pc.importLegacyPrimaryVerified(photos: session.photos, sessionID: session.sessionId,
                albumName: session.albumName, identity: identity,
                remoteNames: Dictionary(uniqueKeysWithValues: session.photos.map { ($0.id, session.remoteName(for: $0)) }))
        }
    }
    private func ingest(_ original: ReceivedJPEG) {
        // Snapshot before insertion: config changes never enqueue all prior photos implicitly.
        let previous = Set(session.photos.map(\.id))
        session.ingest(original)
        guard let retained = session.photos.first(where: { !previous.contains($0.id) && $0.sha256 == original.sha256 }) else { return }
        pc.observeNewPhotos(photos: session.photos, sessionID: session.sessionId,
            albumName: session.albumName, autoUploadEnabled: session.autoUpload,
            remoteNames: Dictionary(uniqueKeysWithValues: session.photos.map { ($0.id, session.remoteName(for: $0)) }))
        if webDAV.autoUpload, webDAV.config != nil { webDAV.enqueue([retained]) }
        let googleAutomatic = google.autoUpload
        let microsoftAutomatic = oneDrive.autoUpload
        let eventName = session.userEventName
        Task { [weak self] in
            guard let self else { return }
            if googleAutomatic { await self.google.enqueue([retained], albumName: eventName) }
            if microsoftAutomatic { _ = try? await self.oneDrive.enqueueNew([retained], albumName: eventName) }
            self.pump()
        }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        feedback.setForegroundActive(active)
        pc.setForegroundActive(active)
        if active {
            refreshPolicy()
            if !restored {
                restored = true
                Task { [weak self] in await self?.google.restoreSignIn(); self?.pump() }
                Task { [weak self] in await self?.oneDrive.restore(); self?.pump() }
            }
            pump()
        }
    }
    func refreshPolicy() {
        guard !syncingPolicy else { return }
        syncingPolicy = true
        google.setWiFiOnly(feedback.preferences.wifiOnly(for: .googleDrive))
        oneDrive.wifiOnly = feedback.preferences.wifiOnly(for: .oneDrive)
        // Restrictive changes cancel existing workers, not merely future enqueue operations.
        if !feedback.allowsUploads(to: .computer) || !feedback.allowsUploads(to: .secondComputer) {
            pc.cancelCurrentTransfer()
        }
        if !feedback.allowsUploads(to: .googleDrive), !google.paused {
            policySuspended.insert(.googleDrive); google.pause()
        } else if feedback.allowsUploads(to: .googleDrive), policySuspended.remove(.googleDrive) != nil {
            google.resumePending()
        }
        if !feedback.allowsUploads(to: .oneDrive), !oneDrive.paused {
            policySuspended.insert(.oneDrive); oneDrive.pause()
        } else if feedback.allowsUploads(to: .oneDrive), policySuspended.remove(.oneDrive) != nil {
            Task { [weak self] in await self?.oneDrive.resume() }
        }
        syncingPolicy = false
        pump()
    }
    func pump() {
        guard foreground else { return }
        if feedback.allowsUploads(to: .computer) || feedback.allowsUploads(to: .secondComputer) {
            Task { [weak self] in await self?.pc.pump() }
        }
        if feedback.allowsUploads(to: .googleDrive) { Task { [weak self] in await self?.google.pump() } }
        if feedback.allowsUploads(to: .oneDrive) { Task { [weak self] in await self?.oneDrive.pump() } }
        if feedback.allowsUploads(to: .webDAV) { Task { [weak self] in await self?.webDAV.uploadPending() } }
    }

    private func owner(photoID: String, relativePath: String? = nil) -> SessionAlbumRecord? {
        session.albums.first { album in album.photos.contains { photo in
            photo.id == photoID && (relativePath == nil || photo.url.path.hasSuffix("/" + relativePath!))
        } }
    }
    private func retain(_ receipt: SessionPhotoReceipt, albumID: String, key: String,
                        feedbackProvider: FeedbackProvider, evidence: DeliveryVerification?) {
        let old = knownStates.updateValue(receipt.state.rawValue, forKey: key)
        if let album = session.album(id: albumID),
           album.receipts.first(where: { $0.photoID == receipt.photoID && $0.provider == receipt.provider && $0.destinationKey == receipt.destinationKey }) != receipt {
            try? session.recordReceipt(receipt, albumID: albumID)
        }
        guard old != nil, old != receipt.state.rawValue else { return } // No replay notifications at launch.
        if receipt.state == .verified, let evidence { feedback.destinationVerified(feedbackProvider, evidence: evidence) }
        if receipt.state == .failed || receipt.state == .needsAuthentication {
            feedback.recordFailure(provider: feedbackProvider, reason: .configuration)
        }
    }
    func synchronizeReports() {
        for job in pc.jobs {
            let state: SessionDeliveryState = [.waiting: .waiting, .uploading: .uploading, .retry: .retry,
                .failed: .failed, .verified: .verified][job.state] ?? .waiting
            retain(SessionPhotoReceipt(photoID: job.photoID, provider: .computer,
                destinationKey: job.destination.key, state: state,
                verification: job.state == .verified ? .receiverSHA256 : .none,
                updatedAt: job.updatedAt, sendMilliseconds: job.sendMilliseconds),
                albumID: job.sessionID, key: "pc:" + job.id,
                feedbackProvider: job.destination.slot == .primary ? .computer : .secondComputer,
                evidence: .receiverSHA256)
        }
        for job in google.jobs {
            guard let album = owner(photoID: job.photoID, relativePath: job.localRelativePath) else { continue }
            let state = cloudState(job.state.rawValue)
            let readback = job.verification?.contains("GET") == true
            let sha = job.verification?.contains("SHA-256") == true && job.verification?.contains("未提供") != true
            let verification: SessionVerification = state != .verified ? .none : readback ? .downloadedSizeSHA256 : sha ? .driveIDSizeMD5ParentSHA256 : .driveIDSizeMD5Parent
            retain(SessionPhotoReceipt(photoID: job.photoID, provider: .googleDrive,
                destinationKey: job.id, state: state, verification: verification,
                updatedAt: job.verifiedAt ?? job.createdAt,
                sendMilliseconds: job.sendSeconds.map { $0 * 1000 }, verifyMilliseconds: job.verifySeconds.map { $0 * 1000 }),
                albumID: album.id, key: "google:" + job.id, feedbackProvider: .googleDrive,
                evidence: sha ? .driveSizeMD5ParentSHA256 : .driveSizeMD5Parent)
        }
        for job in oneDrive.jobs {
            guard let album = owner(photoID: job.photoID, relativePath: job.localRelativePath) else { continue }
            let state = cloudState(job.state.rawValue)
            let readback = job.verification?.contains("GET") == true
            let sha = job.verification?.contains("SHA-256") == true
            // SHA-1 is content verification too, but not a SHA-256 claim; leave the conservative
            // delivered-only state until a compatible schema can express that exact level.
            let effective: SessionDeliveryState = state == .verified && !sha ? .delivered : state
            let verification: SessionVerification = effective != .verified ? .none : readback ? .downloadedSizeSHA256 : .oneDriveSizeSHA256
            retain(SessionPhotoReceipt(photoID: job.photoID, provider: .oneDrive,
                destinationKey: job.id, state: effective, verification: verification,
                updatedAt: job.verifiedAt ?? job.createdAt), albumID: album.id,
                key: "onedrive:" + job.id, feedbackProvider: .oneDrive, evidence: sha ? .oneDriveSizeSHA256 : nil)
        }
        for job in webDAV.jobs {
            guard let album = owner(photoID: job.photoID, relativePath: job.localRelativePath) else { continue }
            let state: SessionDeliveryState = [.pending: .waiting, .uploading: .uploading, .failed: .failed, .verified: .verified][job.state] ?? .waiting
            retain(SessionPhotoReceipt(photoID: job.photoID, provider: .webDAV,
                destinationKey: job.configurationID, state: state,
                verification: job.state == .verified ? .downloadedSizeSHA256 : .none,
                updatedAt: job.updatedAt), albumID: album.id, key: "dav:" + job.id,
                feedbackProvider: .webDAV, evidence: .webDAVSizeSHA256)
        }
    }
    private func cloudState(_ raw: String) -> SessionDeliveryState {
        switch raw {
        case "verified": return .verified
        case "uploading": return .uploading
        case "retry": return .retry
        case "needsSignIn": return .needsAuthentication
        case "failed", "cancelled": return .failed
        default: return .waiting
        }
    }
}
