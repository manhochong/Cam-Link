import CryptoKit
import Foundation
import ZIPFoundation

struct SessionZIPOriginal: Sendable {
    let url: URL
    let bytes: Int64
    let sha256: String
}

/// ZIP is a new local copy, not a cloud delivery or remote verification receipt.
enum SessionZIPExport {
    enum Failure: Error, LocalizedError {
        case source, storage, changed
        var errorDescription: String? {
            switch self {
            case .source: return "原圖不可讀或不在指定活動資料夾內，沒有匯出不完整 ZIP。"
            case .storage: return "未能建立完整 ZIP，請檢查可用空間；App 原圖保留。"
            case .changed: return "原圖大小或整檔 SHA-256 與紀錄不符，已停止 ZIP 匯出。"
            }
        }
    }
    static func write(_ originals: [SessionZIPOriginal], allowedRoot: URL,
                      exportRoot: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !originals.isEmpty, originals.count <= 100_000, allowedRoot.isFileURL, exportRoot.isFileURL else { throw Failure.source }
        let manager = FileManager.default
        let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let destination = exportRoot.appendingPathComponent("CamLink-ZIP-" + UUID().uuidString, isDirectory: true)
        let output = destination.appendingPathComponent("CamLink-originals.zip")
        var total: Int64 = 0
        for original in originals {
            guard original.url.isFileURL, original.url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
                  original.bytes > 0, original.sha256.count == 64 else { throw Failure.source }
            let values = try original.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  values.fileSize.map(Int64.init) == original.bytes else { throw Failure.source }
            let sum = total.addingReportingOverflow(original.bytes)
            guard !sum.overflow else { throw Failure.storage }
            total = sum.partialValue
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let archive = try Archive(url: output, accessMode: .create)
            for (index, original) in originals.enumerated() {
                try Task.checkCancellation()
                try verify(original)
                let name = safe(original.url.lastPathComponent)
                try archive.addEntry(with: String(format: "%06d-", index + 1) + name,
                                     fileURL: original.url, compressionMethod: .none, bufferSize: 256 * 1024)
                try verify(original)
            }
            return output
        } catch {
            try? manager.removeItem(at: destination) // Only this operation's new UUID output; never source files.
            if error is Failure || error is CancellationError { throw error }
            throw Failure.storage
        }
    }
    private static func safe(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        let result = name.utf8.prefix(160).map { allowed.contains($0) ? Character(UnicodeScalar($0)) : "_" }
        let safe = String(result).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return safe.isEmpty ? "original.jpg" : safe
    }
    private static func verify(_ original: SessionZIPOriginal) throws {
        let handle = try FileHandle(forReadingFrom: original.url)
        defer { try? handle.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            count += Int64(data.count)
            guard count <= original.bytes else { throw Failure.changed }
            digest.update(data: data)
        }
        let sha = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == original.bytes, sha == original.sha256.lowercased() else { throw Failure.changed }
    }
}
