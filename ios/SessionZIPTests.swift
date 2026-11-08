import CryptoKit
import Foundation
import ZIPFoundation

@main enum SessionZIPTests {
    enum Failure: Error { case check(String) }
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("CamLink-ZIP-tests-" + UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let sources = root.appendingPathComponent("sources")
        let exports = root.appendingPathComponent("exports")
        try manager.createDirectory(at: sources, withIntermediateDirectories: true)
        try manager.createDirectory(at: exports, withIntermediateDirectories: true)
        func expect(_ test: Bool, _ text: String) throws { if !test { throw Failure.check(text) } }
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        // Raw source-preservation fixture, deliberately not a JPEG validation test.
        let body = Data([0xff,0xd8,0xff,0xd9]) + Data(repeating: 37, count: 900_000) + Data([0xff,0xd8,0xff,0xd9])
        let a = sources.appendingPathComponent("same.JPG")
        let sub = sources.appendingPathComponent("sub")
        try manager.createDirectory(at: sub, withIntermediateDirectories: true)
        let b = sub.appendingPathComponent("same.JPG")
        try body.write(to: a); try body.write(to: b)
        let items = [a,b].map { SessionZIPOriginal(url: $0, bytes: Int64(body.count), sha256: digest(body)) }
        let zip = try SessionZIPExport.write(items, allowedRoot: sources, exportRoot: exports)
        let archive = try Archive(url: zip, accessMode: .read)
        try expect(Array(archive).count == 2, "two entries")
        try expect(Set(archive.map(\.path)).count == 2, "same names stay distinct")
        for entry in archive {
            var actual = Data()
            _ = try archive.extract(entry) { actual.append($0) }
            try expect(actual == body, "whole source bytes including EOI trailer preserved")
        }
        try expect(try Data(contentsOf: a) == body, "source retained")
        do {
            _ = try SessionZIPExport.write([SessionZIPOriginal(url: a, bytes: Int64(body.count), sha256: String(repeating: "0", count: 64))], allowedRoot: sources, exportRoot: exports)
            throw Failure.check("bad digest accepted")
        } catch SessionZIPExport.Failure.changed {}
        try expect(try manager.contentsOfDirectory(atPath: exports.path).count == 1, "only failed operation output removed")
        do {
            _ = try SessionZIPExport.write(items, allowedRoot: sub, exportRoot: exports)
            throw Failure.check("out-of-scope path accepted")
        } catch SessionZIPExport.Failure.source {}
        print("PASS: ZIP full-byte preservation, names, SHA, source retention, failure cleanup and path boundary")
    }
}
