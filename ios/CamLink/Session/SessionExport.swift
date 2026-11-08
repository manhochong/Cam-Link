import Foundation
#if canImport(UIKit)
import UIKit
#if canImport(Photos)
import Photos
#endif
#endif

enum SessionExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv, json, text
    var id: String { rawValue }
    var fileExtension: String { self == .text ? "txt" : rawValue }
    var title: String {
        switch self { case .csv: return "交付 CSV"; case .json: return "完整 JSON 報表"; case .text: return "文字報表" }
    }
}

struct SessionReportPhoto: Codable, Equatable, Sendable {
    let id: String
    let filename: String
    let localFilename: String
    /// ReceivedJPEG.createdAt is receipt time; never claim it is camera EXIF shooting time.
    let receivedAtUTC: String
    let bytes: Int64
    let sha256: String
    let originalAvailable: Bool
    let legacyPCUploaded: Bool
    let receiveTiming: SessionPhotoTiming?
    let receipts: [SessionPhotoReceipt]
}
struct SessionReportDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    let eventName: String
    let startedAtUTC: String
    let archivedAtUTC: String?
    let operatorNotes: String
    let validationScope: String
    let photos: [SessionReportPhoto]
    let deliverySummaries: [SessionDeliverySummary]
    let diagnostics: [SessionDiagnostic]
}

enum SessionExport {
    static let validationScope = "Local receipt metadata and provider-worker receipts only. Sharing/sign-in is not upload verification. Legacy PC flags do not identify a current/second computer. Camera-card comparison and shooting impact: NOT_MEASURED. Missing stage timing: NOT_MEASURED."

    static func safeFilename(_ name: String, fallback: String = "CamLink") -> String {
        // ASCII-only file component: no traversal, path separators, control codes or truncated UTF-8.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.".utf8)
        let mapped = name.utf8.map { allowed.contains($0) ? Character(UnicodeScalar($0)) : "_" }
        var result = String(mapped)
        while result.contains("__") { result = result.replacingOccurrences(of: "__", with: "_") }
        result = String(result.trimmingCharacters(in: CharacterSet(charactersIn: "._-")).prefix(100))
        if !result.isEmpty { return result }
        return fallback == "CamLink" ? "CamLink" : safeFilename(fallback)
    }
    static func filename(album: SessionAlbumRecord, format: SessionExportFormat) -> String {
        "\(safeFilename(album.id))-delivery.\(format.fileExtension)"
    }
    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func duration(_ milliseconds: Double?) -> String {
        guard let value = SessionPhotoTiming.measured(milliseconds) else { return "—" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    static func validateDestinationKey(_ key: String) throws {
        // Local slots, UUIDs and public certificate fingerprints are accepted, not account emails/URLs.
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:".utf8)
        guard !key.isEmpty, key.utf8.count <= 128, key.utf8.allSatisfy({ allowed.contains($0) }),
              !key.contains(".."), !key.contains("://") else { throw SessionArchiveError.invalidReceipt }
    }
    static func validateVerification(provider: SessionDeliveryProvider, verification: SessionVerification) throws {
        let allowed: Set<SessionVerification>
        switch provider {
        case .computer: allowed = [.none, .receiverSHA256]
        case .googleDrive: allowed = [.none, .driveIDSizeMD5Parent, .driveIDSizeMD5ParentSHA256, .downloadedSizeSHA256]
        case .oneDrive: allowed = [.none, .oneDriveSizeOnly, .oneDriveSizeSHA256, .downloadedSizeSHA256]
        case .webDAV: allowed = [.none, .downloadedSizeSHA256]
        }
        guard allowed.contains(verification) else { throw SessionArchiveError.invalidReceipt }
    }
    static func validateReceipt(_ receipt: SessionPhotoReceipt) throws {
        try validateDestinationKey(receipt.destinationKey)
        try validateVerification(provider: receipt.provider, verification: receipt.verification)
        guard !receipt.photoID.isEmpty, receipt.updatedAt.timeIntervalSince1970.isFinite,
              receipt.state != .verified || receipt.verification != .none,
              [receipt.queueMilliseconds, receipt.sendMilliseconds, receipt.verifyMilliseconds]
                .allSatisfy({ $0 == nil || SessionPhotoTiming.measured($0) != nil }) else {
            throw SessionArchiveError.invalidReceipt
        }
    }
    static func validateSummary(_ summary: SessionDeliverySummary) throws {
        try validateDestinationKey(summary.destinationKey)
        try validateVerification(provider: summary.provider, verification: summary.verification)
        let counts = [summary.total, summary.verified, summary.deliveredUnverified,
                      summary.waiting, summary.failed, summary.needsAuthentication]
        guard counts.allSatisfy({ $0 >= 0 }), summary.updatedAt.timeIntervalSince1970.isFinite,
              summary.verified == 0 || summary.verification != .none else { throw SessionArchiveError.invalidReceipt }
        // Avoid overflow for malformed external values. Counts are not fabricated to fill the remainder.
        var remaining = summary.total
        for count in counts.dropFirst() {
            guard count <= remaining else { throw SessionArchiveError.invalidReceipt }
            remaining -= count
        }
    }
    static func report(album: SessionAlbumRecord, summaries external: [SessionDeliverySummary]? = nil) throws -> SessionReportDocument {
        let summaries = external ?? album.deliverySummaries
        guard Set(summaries.map(\.id)).count == summaries.count else { throw SessionArchiveError.invalidReceipt }
        for value in summaries { try validateSummary(value) }
        for receipt in album.receipts { try validateReceipt(receipt) }
        let photos = album.sortedPhotos.map { photo in
            SessionReportPhoto(id: photo.id, filename: photo.name, localFilename: photo.url.lastPathComponent,
                receivedAtUTC: isoDate(photo.createdAt), bytes: photo.bytes, sha256: photo.sha256,
                originalAvailable: FileManager.default.isReadableFile(atPath: photo.url.path),
                legacyPCUploaded: photo.uploaded, receiveTiming: album.photoTimings[photo.id],
                receipts: album.receipts.filter { $0.photoID == photo.id }.sorted(by: receiptOrder))
        }
        return SessionReportDocument(schemaVersion: 1, sessionID: album.id, eventName: album.eventName,
            startedAtUTC: isoDate(album.startedAt), archivedAtUTC: album.archivedAt.map(isoDate),
            operatorNotes: album.operatorNotes, validationScope: validationScope, photos: photos,
            deliverySummaries: summaries.sorted { $0.id < $1.id }, diagnostics: album.diagnostics.sorted {
                $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date
            })
    }
    private static func receiptOrder(_ left: SessionPhotoReceipt, _ right: SessionPhotoReceipt) -> Bool {
        if left.provider != right.provider { return left.provider.rawValue < right.provider.rawValue }
        if left.destinationKey != right.destinationKey { return left.destinationKey < right.destinationKey }
        return left.updatedAt < right.updatedAt
    }
    /// RFC4180 quoting plus spreadsheet formula-injection protection. JSON retains exact text.
    static func csvCell(_ value: String) -> String {
        let leading = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let protect = leading.map { "=+-@".contains($0) } ?? false
        let text = protect ? "'" + value : value
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    private static func receiptText(_ receipts: [SessionPhotoReceipt], provider: SessionDeliveryProvider) -> String {
        let values = receipts.filter { $0.provider == provider }
        return values.isEmpty ? "NOT_RECORDED" : values.map {
            "\($0.destinationKey):\($0.state.rawValue):\($0.verification.rawValue)"
        }.joined(separator: " | ")
    }
    static func csv(album: SessionAlbumRecord, summaries: [SessionDeliverySummary]? = nil) throws -> String {
        let document = try report(album: album, summaries: summaries)
        var lines = [["session_id", "event_name", "filename", "local_filename", "received_at_utc", "bytes",
            "sha256", "original_available", "pc_legacy_flag", "receive_queue_ms", "receive_ms", "local_verify_ms",
            "computer", "google_drive", "onedrive", "webdav", "row_kind", "summary_provider", "destination_key",
            "total", "verified", "delivered_unverified", "waiting", "failed", "needs_authentication",
            "verification", "summary_updated_at_utc"].map(csvCell).joined(separator: ",")]
        for photo in document.photos {
            let fields = [document.sessionID, document.eventName, photo.filename, photo.localFilename,
                photo.receivedAtUTC, String(photo.bytes), photo.sha256, photo.originalAvailable ? "YES" : "NO",
                photo.legacyPCUploaded ? "VERIFIED_LEGACY_UNSCOPED" : "NOT_VERIFIED_LEGACY",
                duration(photo.receiveTiming?.queueMilliseconds), duration(photo.receiveTiming?.receiveMilliseconds),
                duration(photo.receiveTiming?.verifyMilliseconds),
                receiptText(photo.receipts, provider: .computer), receiptText(photo.receipts, provider: .googleDrive),
                receiptText(photo.receipts, provider: .oneDrive), receiptText(photo.receipts, provider: .webDAV),
                "photo", "", "", "", "", "", "", "", "", "", ""]
            lines.append(fields.map(csvCell).joined(separator: ","))
        }
        for summary in document.deliverySummaries {
            let fields = [document.sessionID, document.eventName] + Array(repeating: "", count: 14) + [
                "summary", summary.provider.rawValue, summary.destinationKey, String(summary.total),
                String(summary.verified), String(summary.deliveredUnverified), String(summary.waiting),
                String(summary.failed), String(summary.needsAuthentication), summary.verification.rawValue,
                isoDate(summary.updatedAt)]
            lines.append(fields.map(csvCell).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
    static func text(album: SessionAlbumRecord, summaries: [SessionDeliverySummary]? = nil) throws -> String {
        let document = try report(album: album, summaries: summaries)
        var lines = ["Cam Link 場次報表", album.displayName, "場次 ID：\(document.sessionID)",
            "開始（UTC）：\(document.startedAtUTC)", "原圖紀錄：\(document.photos.count) 張",
            "舊版 PC 已核對旗標：\(album.legacyPCVerifiedCount) 張（未指定電腦）",
            "說明：\(validationScope)", "現場備註：\(document.operatorNotes)", "", "目的地紀錄"]
        if document.deliverySummaries.isEmpty { lines.append("未提供目的地彙總；不能由登入或分享推定完成。") }
        for summary in document.deliverySummaries {
            lines.append("\(summary.provider.title) [\(summary.destinationKey)]：總數 \(summary.total)，已核對 \(summary.verified)，已傳未核對 \(summary.deliveredUnverified)，待傳 \(summary.waiting)，失敗 \(summary.failed)，需登入 \(summary.needsAuthentication)，核對層級 \(summary.verification.rawValue)")
        }
        for photo in document.photos {
            lines.append("\n\(photo.filename) [\(photo.id)]・\(photo.bytes) bytes・\(photo.receivedAtUTC)")
            lines.append("SHA-256：\(photo.sha256)・原圖可讀：\(photo.originalAvailable ? "是" : "否")")
            lines.append("接收排隊／接收／本機驗證（ms）：\(duration(photo.receiveTiming?.queueMilliseconds)) / \(duration(photo.receiveTiming?.receiveMilliseconds)) / \(duration(photo.receiveTiming?.verifyMilliseconds))")
            for receipt in photo.receipts {
                lines.append("\(receipt.provider.title) [\(receipt.destinationKey)]：\(receipt.state.title)・\(receipt.verification.rawValue)・排隊／傳送／核對 ms：\(duration(receipt.queueMilliseconds)) / \(duration(receipt.sendMilliseconds)) / \(duration(receipt.verifyMilliseconds))")
            }
        }
        lines.append("\n場次診斷")
        for event in document.diagnostics { lines.append("\(isoDate(event.date)) \(event.code.rawValue) count=\(event.count)") }
        return lines.joined(separator: "\n") + "\n"
    }
    static func data(album: SessionAlbumRecord, format: SessionExportFormat,
                     summaries: [SessionDeliverySummary]? = nil) throws -> Data {
        switch format {
        case .csv: return Data(try csv(album: album, summaries: summaries).utf8)
        case .text: return Data(try text(album: album, summaries: summaries).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            var output = try encoder.encode(report(album: album, summaries: summaries))
            output.append(0x0A)
            return output
        }
    }
    /// Export is a newly created local report, not a cloud write; never replaces another user's file.
    static func write(album: SessionAlbumRecord, format: SessionExportFormat,
                      summaries: [SessionDeliverySummary]? = nil,
                      directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let bytes = try data(album: album, format: format, summaries: summaries)
        let exportDirectory = directory.appendingPathComponent("CamLink-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
        let url = exportDirectory.appendingPathComponent(filename(album: album, format: format))
        try bytes.write(to: url, options: .atomic)
        return url
    }
    static func originalURLs(album: SessionAlbumRecord, selectedIDs: Set<String>? = nil) throws -> [URL] {
        if let selectedIDs = selectedIDs {
            guard selectedIDs.isSubset(of: Set(album.photos.map(\.id))) else {
                throw SessionArchiveError.invalidOriginal
            }
        }
        let photos = album.sortedPhotos.filter { selectedIDs == nil || selectedIDs!.contains($0.id) }
        guard !photos.isEmpty, photos.allSatisfy({ $0.url.isFileURL && FileManager.default.isReadableFile(atPath: $0.url.path) }) else {
            throw SessionArchiveError.invalidOriginal
        }
        return photos.map(\.url) // Actual landed JPEG/MPF bytes; no thumbnail conversion or rewrite.
    }
}

#if canImport(UIKit) && canImport(Photos)
enum SessionPhotosExport {
    enum Failure: Error, LocalizedError {
        case missingUsageDescription, denied, failed
        var errorDescription: String? {
            switch self {
            case .missingUsageDescription: return "此版本未配置加入 Photos 的權限說明；可先用系統分享儲存至 Files。"
            case .denied: return "未取得新增 Photos 權限；App 原圖保持不變。"
            case .failed: return "Photos 未完成新增；App 原圖保持不變。"
            }
        }
    }
    /// Add-only, explicit user action. No existing Photos asset is edited/deleted; no cloud result is inferred.
    static func saveOriginals(_ urls: [URL]) async throws {
        guard !urls.isEmpty, urls.allSatisfy({ $0.isFileURL && FileManager.default.isReadableFile(atPath: $0.path) }) else {
            throw SessionArchiveError.invalidOriginal
        }
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String,
              !usage.isEmpty else { throw Failure.missingUsageDescription }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.denied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for url in urls {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = false
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
                }
            }
        } catch { throw Failure.failed }
    }
}
#endif
