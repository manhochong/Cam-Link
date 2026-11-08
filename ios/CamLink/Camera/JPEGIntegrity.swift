import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// Structural JPEG checks plus ImageIO decoding; not a complete entropy decoder.
/// Never trims, rewrites or hashes only a prefix of the supplied data.
enum JPEGIntegrity {
    static let maximumBytes = 128 * 1024 * 1024
    static let maximumPaddingBytes = 64 * 1024

    enum TrailingKind: String, Sendable {
        case none, zero, ff, mixed, unknown
    }

    struct Layout: Sendable {
        /// Zero-based offset of FF in the actual main-stream FF D9 marker.
        let eoiIndex: Int
        let trailingBytes: Int
        let trailingKind: TrailingKind
    }

    struct Verified: Sendable {
        let bytes: Int64
        let sha: String
        let layout: Layout
    }

    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case tooLarge, missingSOI, missingEOI, duplicateSOI, noFrame, noSOS
        case invalidMarker, truncatedSegment, invalidSegment
        case unknownSuffix, excessivePadding
        case sizeMismatch(actual: Int64, expected: Int64)
        case decoder

        var retryable: Bool {
            if case .sizeMismatch = self { return true }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "JPG 超過 128 MiB 驗證上限"
            case .missingSOI: return "JPG 缺少檔案起始 SOI"
            case .missingEOI: return "JPG 主影像缺少完整 EOI"
            case .duplicateSOI: return "JPG 主影像含重複 SOI"
            case .noFrame: return "JPG 缺少有效影像框架 SOF"
            case .noSOS: return "JPG 缺少影像掃描 SOS"
            case .invalidMarker: return "JPG 含無效標記"
            case .truncatedSegment: return "JPG 標記區段遭截斷"
            case .invalidSegment: return "JPG 標記區段長度或結構無效"
            case .unknownSuffix: return "JPG EOI 後含非允許的尾端資料"
            case .excessivePadding: return "JPG EOI 後填補超過 64 KiB"
            case let .sizeMismatch(actual, expected):
                return "照片大小不符：\(actual) / \(expected) bytes"
            case .decoder: return "JPG 無法由 ImageIO 完整解碼"
            }
        }
    }

    /// The sole unknown-size sentinel is UInt32.max; all other sizes must match.
    static func validate(_ data: Data, expected: Int64) throws -> Verified {
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        let bytes = Int64(data.count)
        if expected != Int64(UInt32.max), bytes != expected {
            throw Failure.sizeMismatch(actual: bytes, expected: expected)
        }
        let layout = try inspect(data)
        guard layout.trailingKind != .unknown else { throw Failure.unknownSuffix }
        guard layout.trailingBytes <= maximumPaddingBytes else { throw Failure.excessivePadding }
        try autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) == "public.jpeg" as CFString,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw Failure.decoder
            }
            let options = [kCGImageSourceShouldCache: true,
                           kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
                  image.width > 0, image.height > 0,
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
                throw Failure.decoder
            }
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Verified(bytes: bytes, sha: sha, layout: layout)
    }

    /// Walks markers only. A returned layout can still have an unacceptable suffix.
    /// APP/COM payloads are skipped by length, never searched for embedded EOI.
    static func inspect(_ data: Data) throws -> Layout {
        let result = walk(data)
        if let failure = result.failure { throw failure }
        guard let layout = result.layout else { throw Failure.missingEOI }
        return layout
    }

    /// No filename, metadata, scan contents or tail dumps: only endpoint pairs
    /// and structural counts. It remains useful after size/suffix/decode failure.
    static func diagnostic(_ data: Data) -> String {
        let endpoints = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (String, String, Bool, Bool, Bool) in
            guard raw.count >= 2 else { return ("NA", "NA", false, false, false) }
            let start = String(format: "%02X%02X", Int(raw[0]), Int(raw[1]))
            let end = String(format: "%02X%02X", Int(raw[raw.count - 2]), Int(raw[raw.count - 1]))
            return (start, end, raw[0] == 0xFF && raw[1] == 0xD8,
                    raw[raw.count - 2] == 0xFF && raw[raw.count - 1] == 0xD9,
                    raw.count >= 14 && raw[12] == 0xFF && raw[13] == 0xD8)
        }
        let layout = walk(data).layout
        return "bytes=\(data.count) start=\(endpoints.0) end=\(endpoints.1) soiAtStart=\(endpoints.2) eoiAtEnd=\(endpoints.3) soiAtOffset12=\(endpoints.4) trueEOIindex=\(layout?.eoiIndex ?? -1) trailing=\(layout?.trailingBytes ?? -1) kind=\(layout?.trailingKind.rawValue ?? "unknown")"
    }

    private struct WalkResult {
        let layout: Layout?
        let failure: Failure?
        init(_ failure: Failure) { self.layout = nil; self.failure = failure }
        init(layout: Layout, failure: Failure? = nil) {
            self.layout = layout; self.failure = failure
        }
    }

    private static func walk(_ data: Data) -> WalkResult {
        guard data.count <= maximumBytes else { return WalkResult(.tooLarge) }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> WalkResult in
            guard raw.count >= 2, raw[0] == 0xFF, raw[1] == 0xD8 else {
                return WalkResult(.missingSOI)
            }
            var offset = 2
            var entropy = false
            var hasFrame = false
            var hasSOS = false
            while offset < raw.count {
                if entropy {
                    while offset < raw.count, raw[offset] != 0xFF { offset += 1 }
                    if offset == raw.count { return WalkResult(.missingEOI) }
                } else if raw[offset] != 0xFF {
                    return WalkResult(.invalidMarker)
                }
                // Fill FF bytes precede a marker; FF00 is stuffed scan data only.
                while offset < raw.count, raw[offset] == 0xFF { offset += 1 }
                guard offset < raw.count else { return WalkResult(.missingEOI) }
                let marker = raw[offset]
                let markerStart = offset - 1
                offset += 1
                if entropy, marker == 0x00 || (0xD0...0xD7).contains(marker) { continue }
                if marker == 0xD8 { return WalkResult(.duplicateSOI) }
                if marker == 0xD9 {
                    let trailing = raw.count - offset
                    var kind: TrailingKind = .none
                    if trailing > 0 {
                        var zero = false
                        var ff = false
                        for index in offset..<raw.count {
                            if raw[index] == 0 { zero = true }
                            else if raw[index] == 0xFF { ff = true }
                            else { kind = .unknown; break }
                        }
                        if kind != .unknown { kind = zero && ff ? .mixed : (zero ? .zero : .ff) }
                    }
                    let layout = Layout(eoiIndex: markerStart, trailingBytes: trailing, trailingKind: kind)
                    return WalkResult(layout: layout, failure: !hasFrame ? .noFrame : (!hasSOS ? .noSOS : nil))
                }
                if marker == 0x01 { continue } // TEM is a standalone marker.
                guard (0xC0...0xFE).contains(marker), marker != 0xC8,
                      !(0xD0...0xD7).contains(marker) else { return WalkResult(.invalidMarker) }
                guard raw.count - offset >= 2 else { return WalkResult(.truncatedSegment) }
                let length = Int(raw[offset]) * 256 + Int(raw[offset + 1])
                guard length >= 2 else { return WalkResult(.invalidSegment) }
                guard length <= raw.count - offset else { return WalkResult(.truncatedSegment) }
                let isFrame = (0xC0...0xCF).contains(marker) && marker != 0xC4 && marker != 0xCC
                if isFrame {
                    guard length >= 11, raw[offset + 7] > 0,
                          length == 8 + 3 * Int(raw[offset + 7]) else { return WalkResult(.invalidSegment) }
                    hasFrame = true
                }
                if marker == 0xDA {
                    guard hasFrame else { return WalkResult(.noFrame) }
                    guard length >= 8, raw[offset + 2] > 0,
                          length == 6 + 2 * Int(raw[offset + 2]) else { return WalkResult(.invalidSegment) }
                    hasSOS = true
                }
                // DNL may interrupt entropy without ending that scan.
                entropy = marker == 0xDA || (entropy && marker == 0xDC)
                offset += length
            }
            return WalkResult(.missingEOI)
        }
    }
}
