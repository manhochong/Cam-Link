import Foundation

/// Receipt values are supplied by the destination worker, never inferred from sign-in or sharing.
enum SessionDeliveryProvider: String, Codable, CaseIterable, Sendable {
    case computer, googleDrive, oneDrive, webDAV
    var title: String {
        switch self {
        case .computer: return "電腦"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .webDAV: return "WebDAV"
        }
    }
}

enum SessionDeliveryState: String, Codable, Sendable {
    case notQueued, waiting, uploading, retry, needsAuthentication, failed, delivered, verified
    var title: String {
        switch self {
        case .notQueued: return "未加入傳送"
        case .waiting: return "待傳"
        case .uploading: return "正在傳送"
        case .retry: return "等待重試"
        case .needsAuthentication: return "需要重新登入"
        case .failed: return "需處理"
        case .delivered: return "已傳送・未完成核對"
        case .verified: return "已核對"
        }
    }
}

enum SessionVerification: String, Codable, Sendable {
    case none, receiverSHA256, driveIDSizeMD5Parent, driveIDSizeMD5ParentSHA256
    case oneDriveSizeOnly, oneDriveSizeSHA256, downloadedSizeSHA256
}

/// No free-text remote errors, account names, capability URLs, tokens or credentials are stored.
struct SessionPhotoReceipt: Codable, Equatable, Sendable {
    let photoID: String
    let provider: SessionDeliveryProvider
    /// Non-secret local slot/job identity. Do not pass an OAuth account, URL or credential here.
    let destinationKey: String
    let state: SessionDeliveryState
    let verification: SessionVerification
    let updatedAt: Date
    let queueMilliseconds: Double?
    let sendMilliseconds: Double?
    let verifyMilliseconds: Double?

    init(photoID: String, provider: SessionDeliveryProvider, destinationKey: String = "default",
         state: SessionDeliveryState, verification: SessionVerification = .none,
         updatedAt: Date = Date(), queueMilliseconds: Double? = nil,
         sendMilliseconds: Double? = nil, verifyMilliseconds: Double? = nil) {
        self.photoID = photoID
        self.provider = provider
        self.destinationKey = destinationKey
        self.state = state
        self.verification = verification
        self.updatedAt = updatedAt
        self.queueMilliseconds = SessionPhotoTiming.measured(queueMilliseconds)
        self.sendMilliseconds = SessionPhotoTiming.measured(sendMilliseconds)
        self.verifyMilliseconds = SessionPhotoTiming.measured(verifyMilliseconds)
    }
}

struct SessionDeliverySummary: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(provider.rawValue):\(destinationKey)" }
    let provider: SessionDeliveryProvider
    let destinationKey: String
    let total: Int
    let verified: Int
    let deliveredUnverified: Int
    let waiting: Int
    let failed: Int
    let needsAuthentication: Int
    let updatedAt: Date
    /// Exact worker verification level, not a claim that all destinations compare SHA-256.
    let verification: SessionVerification

    init(provider: SessionDeliveryProvider, destinationKey: String = "default", total: Int,
         verified: Int = 0, deliveredUnverified: Int = 0, waiting: Int = 0,
         failed: Int = 0, needsAuthentication: Int = 0, updatedAt: Date = Date(),
         verification: SessionVerification = .none) {
        self.provider = provider
        self.destinationKey = destinationKey
        // Keep input exact; validation rejects invalid counts rather than inventing corrected totals.
        self.total = total
        self.verified = verified
        self.deliveredUnverified = deliveredUnverified
        self.waiting = waiting
        self.failed = failed
        self.needsAuthentication = needsAuthentication
        self.updatedAt = updatedAt
        self.verification = verification
    }
}

struct SessionPhotoTiming: Codable, Equatable, Sendable {
    var queueMilliseconds: Double?
    var receiveMilliseconds: Double?
    var verifyMilliseconds: Double?
    init(queueMilliseconds: Double? = nil, receiveMilliseconds: Double? = nil,
         verifyMilliseconds: Double? = nil) {
        self.queueMilliseconds = Self.measured(queueMilliseconds)
        self.receiveMilliseconds = Self.measured(receiveMilliseconds)
        self.verifyMilliseconds = Self.measured(verifyMilliseconds)
    }
    static func measured(_ value: Double?) -> Double? {
        guard let value = value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}

enum SessionDiagnosticCode: String, Codable, Sendable {
    case receivingStarted, receivingFinished, receivingInterrupted, receiveFailure
    case pcBusy, pcFailed, persistenceFailed, duplicateReference, deliveryNeedsAttention
}
struct SessionDiagnostic: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let date: Date
    let code: SessionDiagnosticCode
    let count: Int
    let photoID: String?
    init(code: SessionDiagnosticCode, count: Int = 0, photoID: String? = nil, date: Date = Date()) {
        id = UUID().uuidString
        self.date = date
        self.code = code
        self.count = max(0, count)
        self.photoID = photoID
    }
}

struct SessionAlbumRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var eventName: String
    let startedAt: Date
    var archivedAt: Date?
    var photos: [ReceivedJPEG]
    var coverPhotoID: String?
    var operatorNotes: String
    var photoTimings: [String: SessionPhotoTiming]
    var receipts: [SessionPhotoReceipt]
    var deliverySummaries: [SessionDeliverySummary]
    var diagnostics: [SessionDiagnostic]

    init(id: String, eventName: String = "", startedAt: Date, photos: [ReceivedJPEG] = []) {
        self.id = id
        self.eventName = SessionArchiveSnapshot.cleanName(eventName)
        self.startedAt = startedAt
        archivedAt = nil
        self.photos = photos
        coverPhotoID = nil
        operatorNotes = ""
        photoTimings = [:]
        receipts = []
        deliverySummaries = []
        diagnostics = []
    }
    var displayName: String {
        eventName.isEmpty ? "拍攝紀錄 \(SessionArchiveSnapshot.dateTitle(startedAt))" : eventName
    }
    var sortedPhotos: [ReceivedJPEG] {
        photos.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id < $1.id
        }
    }
    var coverPhoto: ReceivedJPEG? {
        if let id = coverPhotoID, let photo = photos.first(where: { $0.id == id }) { return photo }
        return sortedPhotos.first
    }
    /// This is the legacy PC flag, not a receipt for the currently selected/second computer.
    var legacyPCVerifiedCount: Int { photos.filter(\.uploaded).count }
    var missingOriginalCount: Int { photos.filter { !FileManager.default.fileExists(atPath: $0.url.path) }.count }
}

enum SessionArchiveError: Error, LocalizedError, Equatable {
    case corruptedArchive, unsupportedVersion, missingAlbum, receivingActive, transferActive
    case storageFailure, invalidReceipt, invalidOriginal
    var errorDescription: String? {
        switch self {
        case .corruptedArchive: return "場次索引無法讀取；原檔及原索引已保留，請先匯出診斷並修復。"
        case .unsupportedVersion: return "場次索引版本不支援；不會覆寫既有紀錄。"
        case .missingAlbum: return "找不到指定場次。"
        case .receivingActive: return "請先停拍並完成接收，再明確建立新活動。"
        case .transferActive: return "請等候本次電腦傳送完成，再建立新活動。"
        case .storageFailure: return "無法儲存場次索引；請檢查儲存空間，原圖不會被刪除。"
        case .invalidReceipt: return "目的地紀錄不完整，或核對層級與狀態不一致。"
        case .invalidOriginal: return "原圖不存在或無法讀取；紀錄及其他原圖仍保留。"
        }
    }
}

struct SessionArchiveSnapshot: Codable, Equatable, Sendable {
    var schemaVersion: Int = 2
    var currentSessionID: String
    var selectedAlbumID: String?
    var autoUpload: Bool
    var albums: [SessionAlbumRecord]

    init(current: SessionAlbumRecord, autoUpload: Bool = true) {
        currentSessionID = current.id
        selectedAlbumID = current.id
        self.autoUpload = autoUpload
        albums = [current]
    }
    var currentAlbum: SessionAlbumRecord? { album(id: currentSessionID) }
    var selectedAlbum: SessionAlbumRecord? { album(id: selectedAlbumID ?? currentSessionID) }
    func album(id: String) -> SessionAlbumRecord? { albums.first { $0.id == id } }
    func history(matching query: String = "") -> [SessionAlbumRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "zh_Hant"))
        return albums.filter { album in
            needle.isEmpty || [album.eventName, album.id, Self.dateTitle(album.startedAt), album.operatorNotes]
                .contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                      locale: Locale(identifier: "zh_Hant")).contains(needle) }
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id < $1.id
        }
    }
    mutating func selectAlbum(id: String) throws {
        guard album(id: id) != nil else { throw SessionArchiveError.missingAlbum }
        selectedAlbumID = id // Never changes currentSessionID.
    }
    @discardableResult
    mutating func startNewActivity(eventName: String, isReceiving: Bool, at date: Date = Date()) throws -> String {
        guard !isReceiving else { throw SessionArchiveError.receivingActive }
        guard let index = albums.firstIndex(where: { $0.id == currentSessionID }) else {
            throw SessionArchiveError.missingAlbum
        }
        let new = SessionAlbumRecord(id: Self.makeSessionID(for: date), eventName: eventName, startedAt: date)
        albums[index].archivedAt = date
        albums.append(new)
        currentSessionID = new.id
        selectedAlbumID = new.id
        return new.id
    }
    /// Duplicate references are ignored; a distinct received URL is retained even for identical bytes.
    /// Capture ownership is independent of selectedAlbumID; no file is moved, rewritten or deleted.
    @discardableResult
    mutating func ingest(_ photo: ReceivedJPEG) throws -> String {
        guard photo.url.isFileURL else { throw SessionArchiveError.invalidOriginal }
        if let owner = albums.first(where: { $0.photos.contains(where: { $0.url == photo.url }) }) {
            return owner.id
        }
        guard let index = albums.firstIndex(where: { $0.id == currentSessionID }) else {
            throw SessionArchiveError.missingAlbum
        }
        var retained = photo
        if albums.contains(where: { $0.photos.contains(where: { $0.id == photo.id }) }) {
            // A colliding upstream ID cannot hide a separate original. Never alter the actual file.
            retained = ReceivedJPEG(id: UUID().uuidString, name: photo.name, url: photo.url,
                bytes: photo.bytes, sha256: photo.sha256, createdAt: photo.createdAt, uploaded: photo.uploaded)
        }
        albums[index].photos.insert(retained, at: 0)
        return currentSessionID
    }
    mutating func updateAlbum(id: String, _ update: (inout SessionAlbumRecord) throws -> Void) throws {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { throw SessionArchiveError.missingAlbum }
        try update(&albums[index])
    }
    func validate() throws {
        guard schemaVersion == 2 else { throw SessionArchiveError.unsupportedVersion }
        guard !albums.isEmpty, Set(albums.map(\.id)).count == albums.count,
              albums.allSatisfy({ !$0.id.isEmpty && $0.startedAt.timeIntervalSince1970.isFinite }),
              currentAlbum != nil, currentAlbum?.archivedAt == nil,
              selectedAlbumID == nil || album(id: selectedAlbumID!) != nil else {
            throw SessionArchiveError.corruptedArchive
        }
        for album in albums {
            guard Set(album.photos.map(\.id)).count == album.photos.count,
                  album.photos.allSatisfy({ $0.url.isFileURL && $0.bytes >= 0 && !$0.id.isEmpty
                      && $0.createdAt.timeIntervalSince1970.isFinite }),
                  album.archivedAt == nil || album.archivedAt!.timeIntervalSince1970.isFinite,
                  album.coverPhotoID == nil || album.photos.contains(where: { $0.id == album.coverPhotoID }),
                  Set(album.deliverySummaries.map(\.id)).count == album.deliverySummaries.count else {
                throw SessionArchiveError.corruptedArchive
            }
            for receipt in album.receipts {
                guard album.photos.contains(where: { $0.id == receipt.photoID }) else {
                    throw SessionArchiveError.corruptedArchive
                }
                try SessionExport.validateReceipt(receipt)
            }
            for summary in album.deliverySummaries { try SessionExport.validateSummary(summary) }
        }
    }
    static func cleanName(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let plain = String(String.UnicodeScalarView(scalars))
        return String(plain.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
    }
    static func makeSessionID(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(UUID().uuidString.prefix(8).lowercased())"
    }
    static func dateTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_HK")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy.MM.dd HH:mm"
        return formatter.string(from: date)
    }
}

/// One atomic JSON replacement publishes the complete album index. The legacy file is left untouched.
/// This does not attempt to scan/delete photos or recover an unreadable archive by overwriting it.
final class SessionArchiveStore {
    let directoryURL: URL
    var archiveURL: URL { directoryURL.appendingPathComponent("sessions-v2.json") }
    var legacyURL: URL { directoryURL.appendingPathComponent("session.json") }
    init(directoryURL: URL = SessionArchiveStore.defaultDirectory) { self.directoryURL = directoryURL }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CamLink", isDirectory: true)
    }
    private struct LegacySnapshot: Codable {
        let sessionId: String
        let autoUpload: Bool
        let photos: [ReceivedJPEG]
    }
    func loadOrCreate(at date: Date = Date()) throws -> SessionArchiveSnapshot {
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            do {
                let snapshot = try JSONDecoder().decode(SessionArchiveSnapshot.self, from: Data(contentsOf: archiveURL))
                try snapshot.validate()
                return snapshot
            } catch let error as SessionArchiveError { throw error }
            catch { throw SessionArchiveError.corruptedArchive }
        }
        let snapshot: SessionArchiveSnapshot
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            let legacy: LegacySnapshot
            do { legacy = try JSONDecoder().decode(LegacySnapshot.self, from: Data(contentsOf: legacyURL)) }
            catch { throw SessionArchiveError.corruptedArchive }
            guard !legacy.sessionId.isEmpty else { throw SessionArchiveError.corruptedArchive }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let started = formatter.date(from: legacy.sessionId)
                ?? legacy.photos.map(\.createdAt).min() ?? date
            // Keep the exact old sessionId (and therefore old PC remote names), all URLs and uploaded flags.
            snapshot = SessionArchiveSnapshot(current: SessionAlbumRecord(id: legacy.sessionId,
                startedAt: started, photos: legacy.photos), autoUpload: legacy.autoUpload)
        } else {
            snapshot = SessionArchiveSnapshot(current: SessionAlbumRecord(
                id: SessionArchiveSnapshot.makeSessionID(for: date), startedAt: date))
        }
        try save(snapshot)
        return snapshot
    }
    func save(_ snapshot: SessionArchiveSnapshot) throws {
        try snapshot.validate()
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: archiveURL, options: .atomic)
        } catch { throw SessionArchiveError.storageFailure }
    }
}

/// Parent may use this for real foreground banners/local notifications. Completion refers to receiving,
/// not all-provider delivery. Events themselves carry no credentials or arbitrary network messages.
enum SessionEvent: Equatable, Sendable {
    case firstPhoto(albumID: String, photoID: String)
    case receivingCompleted(albumID: String, received: Int, failed: Int)
    case receivingInterrupted(albumID: String)
    case deliveryAttention(albumID: String, provider: SessionDeliveryProvider, count: Int)
    case persistenceFailed
}
