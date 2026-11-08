// macOS: xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
//   ios/CamLink/Camera/JPEGIntegrity.swift ios/JPEGIntegrityTests.swift -o /tmp/jpeg-integrity-tests
// Run: /tmp/jpeg-integrity-tests [optional-original.jpg]
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

@main
final class JPEGIntegrityTests {
    private static var checks = 0
    private struct TestFailure: Error, CustomStringConvertible { let description: String }

    private static func check(_ condition: Bool, _ name: String) throws {
        checks += 1
        if !condition { throw TestFailure(description: "FAIL: \(name)") }
    }

    private static func rejects(_ data: Data, _ failure: JPEGIntegrity.Failure,
                                expected: Int64? = nil) throws {
        do {
            _ = try JPEGIntegrity.validate(data, expected: expected ?? Int64(data.count))
            try check(false, "expected rejection: \(failure)")
        } catch let error as JPEGIntegrity.Failure {
            try check(error == failure, "rejection \(error), expected \(failure)")
        }
    }

    private static func fixture(progressive: Bool) throws -> Data {
        let width = 32, height = 24
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                pixels[index] = UInt8(x * 7)
                pixels[index + 1] = UInt8(y * 9)
                pixels[index + 2] = UInt8((x + y) * 4)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else {
            throw TestFailure(description: "cannot generate pixel fixture")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw TestFailure(description: "cannot create JPEG encoder")
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: progressive]]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure(description: "cannot finalize JPEG fixture")
        }
        return output as Data
    }

    // Deliberately NOT a decodable image: tests the pure marker walker only.
    private static var frame: Data { Data([0xFF, 0xC0, 0, 11, 8, 0, 1, 0, 1, 1, 1, 0x11, 0]) }
    private static var scan: Data { Data([0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0]) }
    private static var soi: Data { Data([0xFF, 0xD8]) }
    private static var eoi: Data { Data([0xFF, 0xD9]) }

    static func main() throws {
        let baseline = try fixture(progressive: false)
        let progressive = try fixture(progressive: true)
        for (name, jpeg, marker) in [("baseline", baseline, UInt8(0xC0)),
                                     ("progressive", progressive, UInt8(0xC2))] {
            try check(jpeg.range(of: Data([0xFF, marker])) != nil, "generated \(name) SOF")
            let result = try JPEGIntegrity.validate(jpeg, expected: Int64(jpeg.count))
            try check(result.layout.eoiIndex == jpeg.count - 2, "\(name) real EOI")
            try check(result.layout.trailingBytes == 0 && result.layout.trailingKind == .none, "\(name) no suffix")
        }
        for (padding, kind) in [(Data([0, 0, 0]), JPEGIntegrity.TrailingKind.zero),
                                (Data([255, 255]), .ff), (Data([0, 255, 0, 255]), .mixed),
                                (Data(repeating: 0, count: JPEGIntegrity.maximumPaddingBytes), .zero)] {
            let padded = baseline + padding
            let verified = try JPEGIntegrity.validate(padded, expected: Int64(padded.count))
            let hash = SHA256.hash(data: padded).map { String(format: "%02x", $0) }.joined()
            try check(verified.bytes == Int64(padded.count) && verified.sha == hash, "whole padded bytes/SHA preserved")
            try check(verified.layout.trailingBytes == padding.count && verified.layout.trailingKind == kind,
                      "allowed padding classification")
            try check(verified.layout.eoiIndex == baseline.count - 2, "padding does not move EOI")
        }
        _ = try JPEGIntegrity.validate(baseline, expected: Int64(UInt32.max))
        try check(true, "unknown expected-size sentinel")
        try rejects(baseline, .sizeMismatch(actual: Int64(baseline.count), expected: 0), expected: 0)
        try rejects(baseline + Data([0]), .sizeMismatch(actual: Int64(baseline.count + 1), expected: Int64(baseline.count)),
                    expected: Int64(baseline.count))
        try rejects(baseline + Data([0, 0x42, 255]), .unknownSuffix)
        try rejects(baseline + Data(repeating: 255, count: JPEGIntegrity.maximumPaddingBytes + 1), .excessivePadding)
        let opaque = try JPEGIntegrity.inspect(baseline + Data([0x42]))
        try check(opaque.trailingKind == .unknown && opaque.trailingBytes == 1, "inspect preserves opaque suffix layout")
        let oversized = baseline + Data(repeating: 0, count: JPEGIntegrity.maximumPaddingBytes + 1)
        let oversizedLayout = try JPEGIntegrity.inspect(oversized)
        try check(oversizedLayout.trailingBytes == JPEGIntegrity.maximumPaddingBytes + 1,
                  "inspect preserves excessive padding layout")
        try check(JPEGIntegrity.diagnostic(oversized).contains("trailing=65537 kind=zero"), "oversized suffix diagnostic")
        try rejects(Data(repeating: 0, count: JPEGIntegrity.maximumBytes + 1), .tooLarge)
        try check(JPEGIntegrity.Failure.sizeMismatch(actual: 1, expected: 2).retryable, "size mismatch retryable")
        let nonRetryable: [JPEGIntegrity.Failure] = [.missingSOI, .missingEOI, .invalidMarker, .truncatedSegment,
                                                    .unknownSuffix, .excessivePadding, .tooLarge, .decoder]
        for failure in nonRetryable {
            try check(!failure.retryable, "structural/decode rejection is not retried")
        }
        try rejects(Data(), .missingSOI)
        try rejects(Data([255]), .missingSOI)
        try rejects(Data(baseline.dropFirst(2)), .missingSOI)
        try rejects(Data(baseline.dropLast(2)), .missingEOI)
        try rejects(soi + eoi, .noFrame)
        try rejects(soi + frame + eoi, .noSOS)
        try rejects(soi + Data([255, 0xE1, 0]), .truncatedSegment)
        try rejects(soi + Data([255, 0xE1, 0, 10, 0]), .truncatedSegment)
        try rejects(soi + Data([255, 0xE1, 0, 1]), .invalidSegment)
        try rejects(soi + Data([255, 2]), .invalidMarker)
        try rejects(soi + Data([255, 0xD0]), .invalidMarker)
        try rejects(soi + frame + scan + soi + eoi, .duplicateSOI)
        try rejects(soi + frame + scan + Data([255]), .missingEOI)
        let app = Data([255, 0xE1, 0, 6, 255, 0xD8, 255, 0xD9])
        let embedded = soi + app + Data(baseline.dropFirst(2))
        let embeddedResult = try JPEGIntegrity.validate(embedded, expected: Int64(embedded.count))
        try check(embeddedResult.layout.eoiIndex == embedded.count - 2, "embedded APP thumbnail EOI skipped")
        try rejects(soi + app + frame + scan + Data([1, 2, 3]), .missingEOI)
        let stuffed = soi + frame + scan + Data([1, 255, 0, 0xD9, 255, 0xD0, 255, 0xD7, 2]) + eoi
        let stuffedLayout = try JPEGIntegrity.inspect(stuffed)
        try check(stuffedLayout.eoiIndex == stuffed.count - 2, "stuffing and restart markers")
        let multiScan = soi + frame + scan + Data([1]) + scan + Data([2, 255]) + eoi
        let multiLayout = try JPEGIntegrity.inspect(multiScan)
        try check(multiLayout.eoiIndex == multiScan.count - 2, "multiple scans and marker fill")
        // A structurally complete stream without required coding tables must not pass ImageIO.
        try rejects(soi + frame + scan + Data([1, 2, 3]) + eoi, .decoder)
        let summary = JPEGIntegrity.diagnostic(baseline + Data([0, 0x42]))
        try check(summary.contains("soiAtStart=true") && summary.contains("eoiAtEnd=false") &&
                  summary.contains("trueEOIindex=\(baseline.count - 2)") && summary.contains("trailing=2 kind=unknown"),
                  "safe diagnostic works for rejected suffix")
        let fakeSummary = JPEGIntegrity.diagnostic(soi + eoi)
        try check(fakeSummary.contains("trueEOIindex=2") && fakeSummary.contains("trailing=0"), "diagnostic after no-frame failure")
        try check(JPEGIntegrity.diagnostic(Data([255])).contains("start=NA end=NA"), "short safe diagnostic")
        let wrapped = Data(repeating: 0, count: 12) + baseline
        try check(JPEGIntegrity.diagnostic(wrapped).contains("soiAtOffset12=true"), "offset 12 boolean without payload dump")
        try rejects(wrapped, .missingSOI) // Never drop a suspected PTP header.
        if CommandLine.arguments.count > 1 {
            let original = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
            print("external: \(JPEGIntegrity.diagnostic(original))")
            _ = try JPEGIntegrity.validate(original, expected: Int64(original.count))
            try check(true, "optional external JPEG accepted")
        }
        print("PASS: \(checks) checks (generated fixtures; no camera-capture cause inferred)")
    }
}
