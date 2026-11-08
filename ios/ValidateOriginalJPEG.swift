import Foundation
import ImageIO

/// Manual diagnostic tool only. No photograph is committed or included in CI.
/// Example on the private Mac runner:
/// swiftc JPEGIntegrity.swift MPFIntegrity.swift ValidateOriginalJPEG.swift -o /tmp/check-jpeg
/// /tmp/check-jpeg /tmp/camlink-private-original.jpg 13038080
@main
struct ValidateOriginalJPEG {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let expected = Int64(CommandLine.arguments[2]) else {
            throw NSError(domain: "CamLink.ManualJPEGCheck", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Expected private file path and byte count"])
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let verified = try JPEGIntegrity.validate(data, expected: expected)
        print("PASS original JPEG validation bytes=\(verified.bytes) sha256=\(verified.sha)")
        print(JPEGIntegrity.diagnostic(data))
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            print("ImageIO type=\(CGImageSourceGetType(source) as String? ?? "unknown") count=\(CGImageSourceGetCount(source))")
            let options = [kCGImageSourceShouldCache: true,
                           kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            for index in 0..<CGImageSourceGetCount(source) {
                guard let image = CGImageSourceCreateImageAtIndex(source, index, options) else {
                    throw NSError(domain: "CamLink.ManualJPEGCheck", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "ImageIO could not decode index \(index)"])
                }
                print("ImageIO index=\(index) dimensions=\(image.width)x\(image.height) status=\(CGImageSourceGetStatusAtIndex(source, index).rawValue)")
            }
        }
    }
}
