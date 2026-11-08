import Combine
import Foundation

@MainActor
final class ShootSession: ObservableObject {
    typealias Photo = ReceivedJPEG
    /// Always the current capture album, NEVER the album selected in history.
    @Published var photos: [ReceivedJPEG] = [] { didSet { persistCurrent() } }
    @Published var autoUpload = true { didSet { persistCurrent() } }
    @Published var userEventName = "" { didSet { persistCurrent() } }
    @Published var uploadMessage = ""
    @Published var uploading = false
    @Published private(set) var albums: [SessionAlbumRecord] = []
    @Published private(set) var selectedAlbumID: String?
    @Published private(set) var isReceiving = false
    @Published private(set) var archiveMessage = ""
    @Published private(set) var latestEvent: SessionEvent?
    private(set) var sessionId = ""
    /// Parent may drive real foreground banners/UNUserNotificationCenter using these typed events.
    var onEvent: ((SessionEvent) -> Void)?

    private let archiveStore: SessionArchiveStore
    private var snapshot: SessionArchiveSnapshot
    private var applying = true
    private var storageReadOnly = false
    private var receiveStartCount = 0

    init(archiveDirectory: URL = SessionArchiveStore.defaultDirectory, now: Date = Date()) {
        let store = SessionArchiveStore(directoryURL: archiveDirectory)
        archiveStore = store
        let fallback = SessionArchiveSnapshot(current: SessionAlbumRecord(
            id: SessionArchiveSnapshot.makeSessionID(for: now), startedAt: now))
        do { snapshot = try store.loadOrCreate(at: now) }
        catch {
            snapshot = fallback
            storageReadOnly = true // Never silently replace unreadable existing history.
            archiveMessage = (error as? SessionArchiveError)?.localizedDescription
                ?? SessionArchiveError.storageFailure.localizedDescription
        }
        sessionId = snapshot.currentSessionID
        autoUpload = snapshot.autoUpload
        photos = snapshot.currentAlbum?.photos ?? []
        userEventName = snapshot.currentAlbum?.eventName ?? ""
        albums = snapshot.history()
        selectedAlbumID = snapshot.selectedAlbumID
        applying = false
    }

    var sessionDisplayName: String { album(id: sessionId)?.displayName ?? "拍攝紀錄" }
    /// Display-only compatibility alias; persistence/remote ownership always uses sessionId.
    var albumName: String { sessionDisplayName }
    var currentAlbum: SessionAlbumRecord? { album(id: sessionId) }
    var selectedAlbum: SessionAlbumRecord? { album(id: selectedAlbumID ?? sessionId) }
    /// Backwards-compatible PC flag counts. These are not all-provider/current-PC aggregation.
    var verifiedCount: Int { photos.filter(\.uploaded).count }
    var pendingCount: Int { photos.filter { !$0.uploaded }.count }
    func album(id: String) -> SessionAlbumRecord? { snapshot.album(id: id) }
    func history(matching query: String = "") -> [SessionAlbumRecord] { snapshot.history(matching: query) }
    func albumID(for photo: ReceivedJPEG) -> String? {
        snapshot.albums.first { $0.photos.contains(where: { $0.id == photo.id && $0.url == photo.url }) }?.id
    }

    /// Parent MUST pass camera.browsing/receiving, not only whether the last download is busy.
    /// Also guards model lifecycle and an existing PC upload. Saves before switching any public state.
    @discardableResult
    func startNewActivity(eventName: String = "", isReceiving receiving: Bool, at date: Date = Date()) throws -> String {
        guard !receiving && !isReceiving else { throw SessionArchiveError.receivingActive }
        guard !uploading else { throw SessionArchiveError.transferActive }
        var next = snapshot
        let id = try next.startNewActivity(eventName: eventName, isReceiving: false, at: date)
        try commit(next)
        receiveStartCount = 0
        uploadMessage = ""
        return id
    }
    func selectAlbum(id: String) throws {
        var next = snapshot
        try next.selectAlbum(id: id)
        try commit(next)
    }
    func selectCurrentAlbum() throws { try selectAlbum(id: sessionId) }
    func renameAlbum(id: String, eventName: String) throws {
        var next = snapshot
        try next.updateAlbum(id: id) { $0.eventName = SessionArchiveSnapshot.cleanName(eventName) }
        try commit(next)
    }
    func setAlbumMetadata(eventName: String, operatorNotes: String, albumID: String) throws {
        var next = snapshot
        try next.updateAlbum(id: albumID) { album in
            album.eventName = SessionArchiveSnapshot.cleanName(eventName)
            album.operatorNotes = String(operatorNotes.prefix(4000))
        }
        try commit(next)
    }
    func setOperatorNotes(_ notes: String, albumID: String) throws {
        var next = snapshot
        // User-authored notes only, never raw provider/network logs. Keep JSON proper UTF-8.
        try next.updateAlbum(id: albumID) { $0.operatorNotes = String(notes.prefix(4000)) }
        try commit(next)
    }
    func setCover(photoID: String?, albumID: String) throws {
        var next = snapshot
        try next.updateAlbum(id: albumID) { album in
            guard photoID == nil || album.photos.contains(where: { $0.id == photoID }) else {
                throw SessionArchiveError.invalidOriginal
            }
            album.coverPhotoID = photoID
        }
        try commit(next)
    }

    func ingest(_ photo: ReceivedJPEG) {
        var next = snapshot
        let wasEmpty = next.currentAlbum?.photos.isEmpty ?? true
        do {
            let owner = try next.ingest(photo)
            // On an I/O failure keep the newly landed original visible/in memory, with a truthful error.
            // Its on-disk source is never removed, even for duplicate name/hash or a missing index.
            do { try commit(next) }
            catch { apply(next); reportPersistenceFailure() }
            if wasEmpty, owner == sessionId, let retained = photos.first(where: { $0.url == photo.url }) {
                publish(.firstPhoto(albumID: owner, photoID: retained.id))
            }
        } catch { archiveMessage = SessionArchiveError.invalidOriginal.localizedDescription }
    }
    func remoteName(for photo: ReceivedJPEG) -> String {
        let owner = albumID(for: photo) ?? sessionId
        // Keep migrated PC remote names exactly compatible. Selection never affects this name.
        return "\(owner)_\(photo.url.lastPathComponent)".replacingOccurrences(of: " ", with: "_")
    }

    func receivingDidStart(at date: Date = Date()) {
        guard !isReceiving else { return }
        isReceiving = true
        receiveStartCount = photos.count
        recordDiagnostic(.init(code: .receivingStarted, date: date), albumID: sessionId)
    }
    func receivingDidFinish(failedCount: Int, at date: Date = Date()) {
        guard isReceiving else { return }
        isReceiving = false
        let received = max(0, photos.count - receiveStartCount)
        recordDiagnostic(.init(code: .receivingFinished, count: received, date: date), albumID: sessionId)
        if failedCount > 0 {
            recordDiagnostic(.init(code: .receiveFailure, count: failedCount, date: date), albumID: sessionId)
        }
        publish(.receivingCompleted(albumID: sessionId, received: received, failed: max(0, failedCount)))
    }
    func receivingDidInterrupt(at date: Date = Date()) {
        guard isReceiving else { return }
        isReceiving = false
        recordDiagnostic(.init(code: .receivingInterrupted, date: date), albumID: sessionId)
        publish(.receivingInterrupted(albumID: sessionId))
    }
    func setPhotoTiming(_ timing: SessionPhotoTiming, photoID: String, albumID: String) throws {
        var next = snapshot
        try next.updateAlbum(id: albumID) { album in
            guard album.photos.contains(where: { $0.id == photoID }) else { throw SessionArchiveError.invalidOriginal }
            album.photoTimings[photoID] = timing
        }
        try commit(next)
    }
    func recordDiagnostic(_ diagnostic: SessionDiagnostic, albumID: String) {
        var next = snapshot
        do {
            try next.updateAlbum(id: albumID) { $0.diagnostics.append(diagnostic) }
            try commit(next)
        } catch { reportPersistenceFailure() }
    }
    func recordReceipt(_ receipt: SessionPhotoReceipt, albumID: String) throws {
        try SessionExport.validateReceipt(receipt)
        var next = snapshot
        try next.updateAlbum(id: albumID) { album in
            guard album.photos.contains(where: { $0.id == receipt.photoID }) else { throw SessionArchiveError.invalidOriginal }
            album.receipts.removeAll { $0.photoID == receipt.photoID && $0.provider == receipt.provider
                && $0.destinationKey == receipt.destinationKey }
            album.receipts.append(receipt)
        }
        try commit(next)
        if [.failed, .needsAuthentication].contains(receipt.state) {
            publish(.deliveryAttention(albumID: albumID, provider: receipt.provider, count: 1))
        }
    }
    /// Explicit per-album replacement; the caller supplies honest provider queue counts, not login state.
    func setDeliverySummaries(_ summaries: [SessionDeliverySummary], albumID: String) throws {
        guard Set(summaries.map(\.id)).count == summaries.count else { throw SessionArchiveError.invalidReceipt }
        for summary in summaries { try SessionExport.validateSummary(summary) }
        var next = snapshot
        try next.updateAlbum(id: albumID) { $0.deliverySummaries = summaries }
        try commit(next)
    }
    /// Parent's destination aggregation can update either current or archived PC flags by stable IDs.
    func setPCUploaded(_ uploaded: Bool, photoID: String, albumID: String) throws {
        var next = snapshot
        try next.updateAlbum(id: albumID) { album in
            guard let index = album.photos.firstIndex(where: { $0.id == photoID }) else {
                throw SessionArchiveError.invalidOriginal
            }
            album.photos[index].uploaded = uploaded
        }
        try commit(next)
    }

    func uploadPending(using pair: ComputerPair) async {
        guard pair.isReady else { uploadMessage = "請先配對電腦"; return }
        guard !uploading else { return }
        uploading = true
        defer { uploading = false }
        let captureID = sessionId // Stable across awaits; never uploads a browsed historical album implicitly.
        var ok = 0
        var fail = 0
        var attempted = Set<String>()
        while let photo = album(id: captureID)?.photos.first(where: { !$0.uploaded && !attempted.contains($0.id) }) {
            attempted.insert(photo.id)
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try Task.checkCancellation()
                try await PcClient.put(pair: pair, fileURL: photo.url, remoteName: remoteName(for: photo),
                                       sha256: photo.sha256, size: photo.bytes)
                try setPCUploaded(true, photoID: photo.id, albumID: captureID)
                try recordReceipt(SessionPhotoReceipt(photoID: photo.id, provider: .computer,
                    destinationKey: pair.fingerprint.lowercased(), state: .verified,
                    verification: .receiverSHA256,
                    sendMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000), albumID: captureID)
                ok += 1
            } catch PcClientError.serverBusy {
                uploadMessage = "電腦忙碌，稍後再傳"
                recordDiagnostic(.init(code: .pcBusy, photoID: photo.id), albumID: captureID)
                fail += 1
                break
            } catch {
                // Never persist raw NSError/userInfo or arbitrary remote error descriptions.
                uploadMessage = error is CancellationError ? "電腦傳送已取消" : "電腦傳送未完成，請重試或檢查配對／網路"
                recordDiagnostic(.init(code: .pcFailed, photoID: photo.id), albumID: captureID)
                publish(.deliveryAttention(albumID: captureID, provider: .computer, count: 1))
                fail += 1
                if error is CancellationError { break }
            }
        }
        if fail == 0 { uploadMessage = ok == 0 ? "沒有待傳 JPG" : "已傳到電腦並核對 \(ok) 張" }
    }
    /// Legacy primary-PC compatibility, not a new all-provider or background USB worker.
    func resumeUpload(using pair: ComputerPair) async { await uploadPending(using: pair) }
    /// Compatibility: only resets current-album legacy PC flags; never deletes data or cloud receipts.
    func markNeedsUploadAll() { for index in photos.indices { photos[index].uploaded = false } }

    private func persistCurrent() {
        guard !applying, !sessionId.isEmpty else { return }
        var next = snapshot
        next.autoUpload = autoUpload
        do {
            try next.updateAlbum(id: sessionId) { album in
                // Public compatibility must not hide existing originals when a caller assigns a partial array.
                let retained = album.photos.filter { previous in !photos.contains(where: { $0.url == previous.url }) }
                album.photos = photos + retained
                album.eventName = SessionArchiveSnapshot.cleanName(userEventName)
            }
            do { try commit(next) }
            catch { apply(next); reportPersistenceFailure() }
        } catch { reportPersistenceFailure() }
    }
    private func commit(_ next: SessionArchiveSnapshot) throws {
        guard !storageReadOnly else { throw SessionArchiveError.corruptedArchive }
        try archiveStore.save(next)
        apply(next)
        archiveMessage = ""
    }
    private func apply(_ next: SessionArchiveSnapshot) {
        applying = true
        snapshot = next
        sessionId = next.currentSessionID
        if photos != next.currentAlbum?.photos { photos = next.currentAlbum?.photos ?? [] }
        if userEventName != next.currentAlbum?.eventName { userEventName = next.currentAlbum?.eventName ?? "" }
        if autoUpload != next.autoUpload { autoUpload = next.autoUpload }
        albums = next.history()
        selectedAlbumID = next.selectedAlbumID
        applying = false
    }
    private func reportPersistenceFailure() {
        if archiveMessage.isEmpty { archiveMessage = SessionArchiveError.storageFailure.localizedDescription }
        publish(.persistenceFailed)
    }
    private func publish(_ event: SessionEvent) { latestEvent = event; onEvent?(event) }
}
