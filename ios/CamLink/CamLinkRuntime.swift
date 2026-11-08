import Combine
import CryptoKit
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
    private var knownStates: [String: String] = [:]
    private var verifiedNotifications = Set<String>()
    private var captureRun = UUID()
    private var firstPhotoInRun = false
    private var receiveRunActive = false
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
        // Restored receipts are historical success, never new notifications, even if a stale queue
        // briefly reports waiting before restoring its verified state.
        for album in session.albums {
            for receipt in album.receipts where receipt.state == .verified {
                verifiedNotifications.insert(receiptIdentity(receipt, albumID: album.id))
            }
        }
        camera.onJPEG = { [weak self] original in self?.ingest(original) }
        camera.onReceiveEnded = { [weak self] end in
            guard let self, self.receiveRunActive else { return }
            self.receiveRunActive = false
            // browsing=false precedes native close/drain; only this terminal callback owns completion.
            if end.clean { self.session.receivingDidFinish(failedCount: end.failed) }
            else { self.session.receivingDidInterrupt() }
            self.feedback.receivingFinished(sessionID: self.captureRun, verified: end.received,
                failed: end.failed, pending: end.pending, cleanStop: end.clean)
        }
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .firstPhoto, .receivingCompleted, .receivingInterrupted:
                break // Album lifetime events are not capture-run feedback; terminal callback owns it.
            case .deliveryAttention: break // Worker transitions below own destination feedback.
            case .persistenceFailed: self.feedback.recordFailure(provider: .application, reason: .localStorage)
            }
        }
        camera.$browsing.dropFirst().removeDuplicates().sink { [weak self] active in
            guard active else { return }
            Task { @MainActor [weak self] in
                guard let self, self.receiveRunActive else { return }
                self.session.receivingDidStart()
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
        firstPhotoInRun = false
        receiveRunActive = true
        camera.scanIntervalSeconds = feedback.preferences.scanInterval.seconds(forCardImport: mode == .card)
        camera.mode = mode
        camera.startBrowsing()
    }
    func finishReceiving() { camera.finishReceiving() }
    func interruptReceiving() { camera.stopBrowsing() }
    func baselinePC() {
        pc.observeNewPhotos(photos: session.photos, sessionID: session.sessionId,
            albumName: session.albumName, autoUploadEnabled: session.autoUpload,
            remoteNames: Dictionary(uniqueKeysWithValues: session.photos.map { ($0.id, session.remoteName(for: $0)) }))
        if let identity = pair.legacyPrimaryIdentity {
            do {
                try pc.importLegacyPrimaryVerified(photos: session.photos, sessionID: session.sessionId,
                    albumName: session.albumName, identity: identity,
                    remoteNames: Dictionary(uniqueKeysWithValues: session.photos.map { ($0.id, session.remoteName(for: $0)) }))
            } catch {
                feedback.recordFailure(provider: .application, reason: .localStorage)
            }
        }
    }
    private func ingest(_ original: ReceivedJPEG) {
        // Snapshot before insertion: config changes never enqueue all prior photos implicitly.
        let previous = Set(session.photos.map(\.id))
        session.ingest(original)
        guard let retained = session.photos.first(where: {
            !previous.contains($0.id) && $0.url == original.url && $0.sha256 == original.sha256
        }), session.albumID(for: retained) != nil else { return }
        if receiveRunActive, !firstPhotoInRun {
            firstPhotoInRun = true
            feedback.firstReceived(sessionID: captureRun)
        }
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
            if microsoftAutomatic {
                do { _ = try await self.oneDrive.enqueueNew([retained], albumName: eventName) }
                catch { self.feedback.recordFailure(provider: .oneDrive, reason: .configuration) }
            }
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
        // A restriction on the idle second slot must not cancel an allowed primary upload (or vice versa).
        if pc.jobs.contains(where: { job in
            job.state == .uploading && !feedback.allowsUploads(to:
                job.destination.slot == .primary ? .computer : .secondComputer)
        }) {
            pc.cancelCurrentTransfer()
        }
        // These transient policy gates neither persist a user pause nor resume a user-paused queue.
        google.setPolicyBlocked(!feedback.allowsUploads(to: .googleDrive))
        oneDrive.setPolicyBlocked(!feedback.allowsUploads(to: .oneDrive))
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
    private func receiptIdentity(_ receipt: SessionPhotoReceipt, albumID: String) -> String {
        // Length-delimited identity: photo/album IDs cannot collide by containing a separator.
        let fields = [albumID, receipt.provider.rawValue, receipt.destinationKey, receipt.photoID]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }
    private func retain(_ receipt: SessionPhotoReceipt, albumID: String, key: String,
                        feedbackProvider: FeedbackProvider, evidence: DeliveryVerification?,
                        legacyDestinationKey: String? = nil) {
        guard let album = session.album(id: albumID) else { return }
        let persisted = album.receipts.first { $0.photoID == receipt.photoID && $0.provider == receipt.provider
            && ($0.destinationKey == receipt.destinationKey || $0.destinationKey == legacyDestinationKey) }
        let identity = receiptIdentity(receipt, albumID: albumID)
        let restoredVerified = persisted.map {
            verifiedNotifications.contains(receiptIdentity($0, albumID: albumID)) || $0.state == .verified
        } ?? false
        do {
            // A no-op has already passed this exact durable write previously; otherwise save first.
            if !album.receipts.contains(receipt) { try session.recordReceipt(receipt, albumID: albumID) }
        } catch {
            feedback.recordFailure(provider: .application, reason: .localStorage)
            return // Never consume the transition or emit destination success on a failed archive write.
        }
        if restoredVerified { verifiedNotifications.insert(identity) }
        let old = knownStates.updateValue(receipt.state.rawValue, forKey: key)
        guard old != nil, old != receipt.state.rawValue else { return } // No replay notifications at launch.
        if receipt.state == .verified, let evidence, !verifiedNotifications.contains(identity) {
            if feedback.destinationVerified(feedbackProvider, evidence: evidence) {
                verifiedNotifications.insert(identity)
            }
        }
        if receipt.state == .failed || receipt.state == .needsAuthentication {
            feedback.recordFailure(provider: feedbackProvider,
                reason: receipt.state == .needsAuthentication ? .authentication : .configuration)
        }
    }

    /// Hash only immutable public destination identifiers; never persist raw account IDs, URLs or credentials.
    /// Array length-prefixing avoids ambiguous concatenation; photo/job IDs are deliberately absent.
    private func destinationBinding(_ provider: SessionDeliveryProvider, _ fields: [String]) -> String {
        let value = ([provider.rawValue] + fields).map { "\($0.utf8.count):\($0)" }.joined()
        let hash = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return provider.rawValue + ":" + hash
    }

    func synchronizeReports() {
        // Old runtime versions persisted cloud job IDs. Keep their history intact, but fold aliases
        // into the same destination/photo when deriving counts, never count the migration twice.
        var aliases: [String: String] = [:]
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
            let destination = destinationBinding(.googleDrive,
                [job.clientID, job.sdkUserID, job.accountID, job.albumParentID ?? job.folderID])
            aliases["googleDrive:" + job.id] = destination
            let state = cloudState(job.state.rawValue)
            let evidence = DeliveryVerification.googleDriveWorkerEvidence(job.verification)
            let effective: SessionDeliveryState = state == .verified && evidence == nil ? .delivered : state
            let verification: SessionVerification
            switch evidence {
            case .driveSizeMD5Parent?: verification = .driveIDSizeMD5Parent
            case .driveSizeMD5ParentSHA256?: verification = .driveIDSizeMD5ParentSHA256
            case .driveDownloadedSizeSHA256Parent?: verification = .downloadedSizeSHA256
            default: verification = .none
            }
            retain(SessionPhotoReceipt(photoID: job.photoID, provider: .googleDrive,
                destinationKey: destination, state: effective,
                verification: effective == .verified ? verification : .none,
                updatedAt: job.verifiedAt ?? job.createdAt,
                sendMilliseconds: job.sendSeconds.map { $0 * 1000 }, verifyMilliseconds: job.verifySeconds.map { $0 * 1000 }),
                albumID: album.id, key: "google:" + job.id, feedbackProvider: .googleDrive,
                evidence: evidence, legacyDestinationKey: job.id)
        }
        for job in oneDrive.jobs {
            guard let album = owner(photoID: job.photoID, relativePath: job.localRelativePath) else { continue }
            let destination = destinationBinding(.oneDrive,
                [job.setup.clientID, job.setup.tenant, job.setup.redirectURI, job.accountID, job.driveID, job.folderID])
            aliases["oneDrive:" + job.id] = destination
            let state = cloudState(job.state.rawValue)
            let evidence = DeliveryVerification.oneDriveWorkerEvidence(job.verification)
            // SHA-1 is content verification too, but this archive cannot express that exact level.
            let effective: SessionDeliveryState = state == .verified && evidence == nil ? .delivered : state
            let verification: SessionVerification = effective != .verified ? .none :
                job.verification == "full GET SHA-256" ? .downloadedSizeSHA256 : .oneDriveSizeSHA256
            retain(SessionPhotoReceipt(photoID: job.photoID, provider: .oneDrive,
                destinationKey: destination, state: effective, verification: verification,
                updatedAt: job.verifiedAt ?? job.createdAt), albumID: album.id,
                key: "onedrive:" + job.id, feedbackProvider: .oneDrive, evidence: evidence,
                legacyDestinationKey: job.id)
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
        synchronizeSummaries(aliases: aliases)
    }

    private func synchronizeSummaries(aliases: [String: String]) {
        // Derive ONLY from retained receipts, never from in-memory worker state after a failed save.
        for album in session.albums {
            let groups = Dictionary(grouping: album.receipts) { receipt in
                receipt.provider.rawValue + ":" +
                    (aliases[receipt.provider.rawValue + ":" + receipt.destinationKey] ?? receipt.destinationKey)
            }
            var summaries: [SessionDeliverySummary] = []
            for key in groups.keys.sorted() {
                guard let values = groups[key], let first = values.first else { continue }
                let destination = aliases[first.provider.rawValue + ":" + first.destinationKey] ?? first.destinationKey
                // An old job-ID receipt and its stable-binding replacement represent one photo.
                let photos = Dictionary(grouping: values, by: \.photoID)
                let receipts = photos.values.compactMap { records in
                    records.first(where: { $0.destinationKey == destination }) ?? records.max { $0.updatedAt < $1.updatedAt }
                }
                if let verification = commonVerification(receipts) {
                    summaries.append(summary(receipts, provider: first.provider, destination: destination,
                        verification: verification))
                } else {
                    // The existing schema has no mixed-evidence value and disallows verified + none.
                    // Preserve real counts in stable destination/evidence cohorts rather than claiming
                    // GET for API hashes, MD5 for GET, or SHA-256 for a mixed MD5-only population.
                    let cohorts = Dictionary(grouping: receipts) {
                        $0.state == .verified ? $0.verification : SessionVerification.none
                    }
                    for evidence in cohorts.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                        guard let cohort = cohorts[evidence] else { continue }
                        summaries.append(summary(cohort, provider: first.provider,
                            destination: destination + "." + evidence.rawValue, verification: evidence))
                    }
                }
            }
            summaries.sort { $0.id < $1.id }
            guard album.deliverySummaries != summaries else { continue }
            do { try session.setDeliverySummaries(summaries, albumID: album.id) }
            catch { feedback.recordFailure(provider: .application, reason: .localStorage) }
        }
    }

    private func commonVerification(_ receipts: [SessionPhotoReceipt]) -> SessionVerification? {
        let evidence = Set(receipts.filter { $0.state == .verified }.map(\.verification))
        if evidence.isEmpty { return SessionVerification.none }
        if evidence.count == 1 { return evidence.first }
        // MD5 is the common guarantee; the optional stronger SHA-256 is not universal.
        if evidence.isSubset(of: [.driveIDSizeMD5Parent, .driveIDSizeMD5ParentSHA256]) {
            return .driveIDSizeMD5Parent
        }
        return nil
    }

    private func summary(_ receipts: [SessionPhotoReceipt], provider: SessionDeliveryProvider,
                         destination: String, verification: SessionVerification) -> SessionDeliverySummary {
        SessionDeliverySummary(provider: provider, destinationKey: destination, total: receipts.count,
            verified: receipts.filter { $0.state == .verified }.count,
            deliveredUnverified: receipts.filter { $0.state == .delivered }.count,
            waiting: receipts.filter { [.waiting, .uploading, .retry].contains($0.state) }.count,
            failed: receipts.filter { $0.state == .failed }.count,
            needsAuthentication: receipts.filter { $0.state == .needsAuthentication }.count,
            updatedAt: receipts.map(\.updatedAt).max() ?? .distantPast, verification: verification)
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
