// macOS: xcrun swiftc CamLink/Camera/JPEGIntegrity.swift \
//   CamLink/Camera/MPFIntegrity.swift MPFIntegrityTests.swift -o /tmp/mpf-tests
// Run after JPEGIntegrity.validate has been integrated with MPFIntegrity.parse.
// All image content below is generated; no user photos or metadata are fixtures.
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

@main
struct MPFIntegrityTests {
    struct Fixture {
        var data: Data
        let primaryBytes: Int
        let tiffBase: Int
        let little: Bool
        let secondaryStart: Int
        let previewBytes: Int
        var version: Int { tiffBase + 10 }
        var number: Int { tiffBase + 22 }
        var tableTag: Int { tiffBase + 34 }
        var table: Int { tiffBase + 50 }
        var segmentEnd: Int { 2 + 98 } // Two-image fixture includes eight spare TIFF bytes.
        mutating func set16(_ offset: Int, _ value: UInt16) {
            for i in 0..<2 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (little ? i * 8 : (1 - i) * 8)) }
        }
        mutating func set32(_ offset: Int, _ value: UInt32) {
            for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (little ? i * 8 : (3 - i) * 8)) }
        }
    }

    enum TestFailure: Error { case failed(String), fixture }
    static var passed = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw TestFailure.failed(name) }
        passed += 1
    }

    static func reject(_ name: String, _ original: Fixture,
                       _ mutation: (inout Fixture) -> Void) throws {
        var fixture = original
        mutation(&fixture)
        do {
            _ = try MPFIntegrity.parse(fixture.data, primaryBytes: fixture.primaryBytes)
        } catch is MPFIntegrity.Failure {
            passed += 1
            return
        }
        throw TestFailure.failed("did not reject: \(name)")
    }

    static func jpeg(width: Int, height: Int, seed: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let at = (y * width + x) * 4
                pixels[at] = UInt8((x * 7 + y * 13 + seed) % 256)
                pixels[at + 1] = UInt8((x * 17 + y * 3 + seed * 5) % 256)
                pixels[at + 2] = UInt8((x * 5 + y * 19 + seed * 11) % 256)
                pixels[at + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw TestFailure.fixture }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw TestFailure.fixture
        }
        CGImageDestinationAddImage(destination, image,
                                  [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TestFailure.fixture }
        let data = output as Data
        let layout = try JPEGIntegrity.inspect(data)
        guard layout.eoiIndex + 2 == data.count else { throw TestFailure.fixture }
        return data
    }

    static func opaque(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 % 251) + 1) })
    }

    static func make(_ primary: Data, previews: [Data], little: Bool = true,
                     gap: Int = 454, tail: Int = 274) -> Fixture {
        let number = previews.count + 1
        let tiffSize = 50 + 16 * number + 8
        let appLength = 2 + 4 + tiffSize
        var segment = Data([0xFF, 0xE2, UInt8(appLength >> 8), UInt8(appLength & 255),
                            0x4D, 0x50, 0x46, 0])
        segment.append(Data(repeating: 0, count: tiffSize))
        var data = Data(primary.prefix(2))
        data.append(segment)
        data.append(primary.dropFirst(2))
        let primaryBytes = data.count
        let firstSecondary = primaryBytes + gap
        for preview in previews { data.append(opaque(gap)); data.append(preview) }
        data.append(opaque(tail))
        var fixture = Fixture(data: data, primaryBytes: primaryBytes, tiffBase: 10,
                              little: little, secondaryStart: firstSecondary,
                              previewBytes: previews[0].count)
        fixture.data[10] = little ? 0x49 : 0x4D
        fixture.data[11] = little ? 0x49 : 0x4D
        fixture.set16(12, 42)
        fixture.set32(14, 8)
        fixture.set16(18, 3)
        for (entry, tag, type, count) in [(fixture.version, UInt16(0xB000), UInt16(7), UInt32(4)),
                                        (fixture.number, UInt16(0xB001), UInt16(4), UInt32(1)),
                                        (fixture.tableTag, UInt16(0xB002), UInt16(7), UInt32(16 * number))] {
            fixture.set16(entry, tag); fixture.set16(entry + 2, type); fixture.set32(entry + 4, count)
        }
        fixture.data.replaceSubrange((fixture.version + 8)..<(fixture.version + 12), with: [0x30, 0x31, 0x30, 0x30])
        fixture.set32(fixture.number + 8, UInt32(number))
        fixture.set32(fixture.tableTag + 8, 50)
        fixture.set32(fixture.tiffBase + 46, 0)
        fixture.set32(fixture.table, 0x80030000)
        fixture.set32(fixture.table + 4, UInt32(primaryBytes))
        fixture.set32(fixture.table + 8, 0)
        fixture.set16(fixture.table + 12, 2)
        var cursor = primaryBytes
        for (i, preview) in previews.enumerated() {
            cursor += gap
            let entry = fixture.table + (i + 1) * 16
            fixture.set32(entry, 0x40010002)
            fixture.set32(entry + 4, UInt32(preview.count))
            fixture.set32(entry + 8, UInt32(cursor - fixture.tiffBase))
            cursor += preview.count
        }
        return fixture
    }

    /// Invalidate a quantization-table precision/id without disturbing JPEG markers.
    /// Structural inspect must still pass, while the real ImageIO decoder rejects it.
    static func corruptQuantization(_ fixture: inout Fixture, start: Int, length: Int) throws {
        var position = start + 2
        while position + 4 <= start + length {
            guard fixture.data[position] == 0xFF else { throw TestFailure.fixture }
            let marker = fixture.data[position + 1]
            if marker == 0xDA { break }
            let size = Int(fixture.data[position + 2]) * 256 + Int(fixture.data[position + 3])
            guard size >= 2, position + 2 + size <= start + length else { throw TestFailure.fixture }
            if marker == 0xDB {
                fixture.data[position + 4] = 0xFF
                return
            }
            position += 2 + size
        }
        throw TestFailure.fixture
    }

    static func decoderReject(_ name: String, _ fixture: Fixture) throws {
        _ = try MPFIntegrity.parse(fixture.data, primaryBytes: fixture.primaryBytes)
        do {
            _ = try JPEGIntegrity.validate(fixture.data, expected: Int64(fixture.data.count))
        } catch JPEGIntegrity.Failure.decoder {
            passed += 1
            return
        }
        throw TestFailure.failed("decoder did not reject: \(name)")
    }

    static func main() throws {
        let primary = try jpeg(width: 64, height: 48, seed: 3)
        let preview = try jpeg(width: 96, height: 72, seed: 19)
        try check(try MPFIntegrity.parse(primary, primaryBytes: primary.count) == nil, "ordinary JPEG")
        for little in [true, false] {
            let f = make(primary, previews: [preview], little: little)
            guard let layout = try MPFIntegrity.parse(f.data, primaryBytes: f.primaryBytes) else {
                throw TestFailure.failed("missing valid index")
            }
            try check(layout.images.count == 2, "two images")
            try check(layout.images[0].start == 0 && layout.images[0].length == f.primaryBytes, "primary exact range")
            try check(layout.images[1].start == f.secondaryStart && layout.images[1].length == preview.count, "TIFF-relative range")
            try check(layout.images[1].attribute == 0x40010002, "attribute retained")
            try check(layout.images[1].end + 274 == f.data.count, "opaque tail retained")
            let verified: JPEGIntegrity.Verified
            do {
                verified = try JPEGIntegrity.validate(f.data, expected: Int64(f.data.count))
            } catch {
                if let source = CGImageSourceCreateWithData(f.data as CFData, nil) {
                    let type = CGImageSourceGetType(source).map { $0 as String } ?? "nil"
                    print("Synthetic MPF failure: littleEndian=\(little) bytes=\(f.data.count) primaryBytes=\(f.primaryBytes) type=\(type) images=\(CGImageSourceGetCount(source)) status=\(CGImageSourceGetStatus(source).rawValue) image0Status=\(CGImageSourceGetStatusAtIndex(source, 0).rawValue)")
                }
                throw error
            }
            let sha = SHA256.hash(data: f.data).map { String(format: "%02x", $0) }.joined()
            try check(verified.bytes == Int64(f.data.count) && verified.sha == sha, "complete-file size and SHA")
            try check(verified.layout.eoiIndex + 2 == f.primaryBytes, "primary EOI retained")
            let unknown = try JPEGIntegrity.validate(f.data, expected: Int64(UInt32.max))
            try check(unknown.sha == sha, "unknown-size sentinel")
            try reject("bad version", f) { $0.data[$0.version + 9] = 0x32 }
            try reject("bad byte order", f) { $0.data[$0.tiffBase] = 0 }
            try reject("bad TIFF magic", f) { $0.set16($0.tiffBase + 2, 43) }
            try reject("IFD in TIFF header", f) { $0.set32($0.tiffBase + 4, 0) }
            try reject("IFD outside APP2", f) { $0.set32($0.tiffBase + 4, 100) }
            try reject("huge IFD pointer", f) { $0.set32($0.tiffBase + 4, UInt32.max) }
            try reject("IFD count cap", f) { $0.set16($0.tiffBase + 8, 257) }
            try reject("truncated IFD", f) { $0.set16($0.tiffBase + 8, 256) }
            try reject("missing tag", f) { $0.set16($0.version, 0xB003) }
            try reject("duplicate tag", f) { $0.set16($0.number, 0xB000) }
            try reject("wrong version type", f) { $0.set16($0.version + 2, 4) }
            try reject("out-of-line version", f) { $0.set32($0.version + 4, 5) }
            try reject("wrong number type", f) { $0.set16($0.number + 2, 7) }
            try reject("wrong number count", f) { $0.set32($0.number + 4, 2) }
            for count in [UInt32(0), 1, 9, UInt32.max] {
                try reject("image count \(count)", f) { $0.set32($0.number + 8, count) }
            }
            try reject("wrong table type", f) { $0.set16($0.tableTag + 2, 4) }
            try reject("wrong table count", f) { $0.set32($0.tableTag + 4, 16) }
            try reject("table overlaps IFD", f) { $0.set32($0.tableTag + 8, 10) }
            try reject("table crosses APP2 into JPEG", f) { $0.set32($0.tableTag + 8, 70) }
            try reject("table outside APP2", f) { $0.set32($0.tableTag + 8, UInt32.max) }
            try reject("next IFD lacks two bytes", f) { $0.set32($0.tiffBase + 46, 89) }
            try reject("primary size", f) { $0.set32($0.table + 4, UInt32($0.primaryBytes - 1)) }
            try reject("primary offset", f) { $0.set32($0.table + 8, 1) }
            try reject("primary type", f) { $0.set32($0.table, 0x80010002) }
            try reject("second primary", f) { $0.set32($0.table + 16, 0x40030000) }
            for bits in [UInt32(0x01000000), 0x02000000, 0x04000000, 0x08000000, 0x10000000] {
                try reject("format/reserved bits", f) { $0.set32($0.table + 16, 0x40010002 | bits) }
            }
            try reject("dependency out of range", f) { $0.set16($0.table + 12, 3) }
            try reject("dependency self", f) { $0.set16($0.table + 28, 2) }
            try reject("second dependency self", f) { $0.set16($0.table + 30, 2) }
            try reject("offset inside primary", f) { $0.set32($0.table + 24, UInt32($0.primaryBytes - $0.tiffBase - 1)) }
            try reject("huge offset", f) { $0.set32($0.table + 24, UInt32.max) }
            for size in [UInt32(0), 3, UInt32.max, UInt32(JPEGIntegrity.maximumBytes + 1)] {
                try reject("invalid range length", f) { $0.set32($0.table + 20, size) }
            }
            try reject("range crosses EOF", f) { $0.set32($0.table + 20, UInt32($0.previewBytes + 275)) }
            try reject("declared EOI too early", f) { $0.set32($0.table + 20, UInt32($0.previewBytes + 1)) }
            try reject("declared EOI too late", f) { $0.set32($0.table + 20, UInt32($0.previewBytes - 1)) }
            try reject("bad secondary SOI", f) { $0.data[$0.secondaryStart] = 0 }
            try reject("bad secondary EOI", f) { $0.data[$0.secondaryStart + $0.previewBytes - 1] = 0 }
            try reject("duplicate MPF APP2", f) {
                let segment = Data($0.data[2..<$0.segmentEnd])
                $0.data.insert(contentsOf: segment, at: 2)
            }
            try reject("truncated APP2", f) { $0.data = Data($0.data.prefix($0.segmentEnd - 1)) }
            var invalidPreview = f
            try corruptQuantization(&invalidPreview, start: f.secondaryStart, length: f.previewBytes)
            try decoderReject("secondary DQT", invalidPreview)
            var invalidPrimary = f
            try corruptQuantization(&invalidPrimary, start: 0, length: f.primaryBytes)
            try decoderReject("primary DQT", invalidPrimary)
        }
        let f = make(primary, previews: [preview])
        do {
            _ = try MPFIntegrity.parse(f.data, primaryBytes: f.primaryBytes + 1)
            throw TestFailure.failed("wrong supplied primaryBytes accepted")
        } catch MPFIntegrity.Failure.invalidPrimary { passed += 1 }
        var badIndex = f
        badIndex.set32(badIndex.table + 24, UInt32.max)
        do {
            _ = try JPEGIntegrity.validate(badIndex.data, expected: Int64(badIndex.data.count))
            throw TestFailure.failed("integrated validator accepted invalid MPF")
        } catch let failure as JPEGIntegrity.Failure {
            guard case .invalidMPF = failure else { throw failure }
            try check(!failure.retryable, "invalid MPF is not retryable")
        }
        let hugeGap = make(primary, previews: [preview], gap: 65537, tail: 0)
        try reject("gap exceeds cap", hugeGap) { _ in }
        let hugeTotal = make(primary, previews: [preview], gap: 40000, tail: 30000)
        try reject("aggregate unindexed exceeds cap", hugeTotal) { _ in }
        let boundary = make(primary, previews: [preview], gap: 454, tail: 65536 - 454)
        try check(try MPFIntegrity.parse(boundary.data, primaryBytes: boundary.primaryBytes) != nil, "64 KiB opaque boundary")
        let eight = make(primary, previews: Array(repeating: preview, count: 7), gap: 0, tail: 0)
        try check(try MPFIntegrity.parse(eight.data, primaryBytes: eight.primaryBytes)?.images.count == 8, "eight images")
        var three = make(primary, previews: [preview, primary], gap: 0, tail: 0)
        let entryOne = Data(three.data[(three.table + 16)..<(three.table + 32)])
        let entryTwo = Data(three.data[(three.table + 32)..<(three.table + 48)])
        three.data.replaceSubrange((three.table + 16)..<(three.table + 32), with: entryTwo)
        three.data.replaceSubrange((three.table + 32)..<(three.table + 48), with: entryOne)
        let unordered = try MPFIntegrity.parse(three.data, primaryBytes: three.primaryBytes)
        try check(unordered?.images.count == 3 && unordered!.images[1].start > unordered!.images[2].start, "non-offset index order")
        try reject("overlapping secondary ranges", three) {
            let entry = Data($0.data[($0.table + 16)..<($0.table + 32)])
            $0.data.replaceSubrange(($0.table + 32)..<($0.table + 48), with: entry)
        }
        let hidden = Data([0xFF, 0xE1, 0, 8, 0x4D, 0x50, 0x46, 0, 0x49, 0x49])
        var app1 = Data(primary.prefix(2)); app1.append(hidden); app1.append(primary.dropFirst(2))
        try check(try MPFIntegrity.parse(app1, primaryBytes: app1.count) == nil, "no magic scan inside APP1")
        var suffix = primary; suffix.append(Data(f.data[2..<f.segmentEnd]))
        try check(try MPFIntegrity.parse(suffix, primaryBytes: primary.count) == nil, "no magic scan after EOI")
        do {
            _ = try JPEGIntegrity.validate(suffix, expected: Int64(suffix.count))
            throw TestFailure.failed("ordinary JPEG arbitrary suffix accepted")
        } catch JPEGIntegrity.Failure.unknownSuffix { passed += 1 }
        do {
            _ = try JPEGIntegrity.validate(f.data, expected: Int64(f.data.count + 1))
            throw TestFailure.failed("size mismatch accepted")
        } catch JPEGIntegrity.Failure.sizeMismatch { passed += 1 }
        print("MPFIntegrityTests: \(passed) checks passed (synthetic images only)")
    }
}
