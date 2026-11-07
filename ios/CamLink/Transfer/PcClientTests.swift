#if DEBUG
import Foundation

/// Lightweight checks runnable from a DEBUG menu later; not an XCTest target yet.
enum PcClientTests {
    static func runParseChecks() -> String {
        var fails: [String] = []
        if PcClient.parsePair("camlink://pair?ip=192.168.1.20&code=ab12cd34ef56") == nil {
            fails.append("qr")
        }
        if PcClient.parsePair("camlink:192.168.1.20:ab12cd34ef56") == nil {
            fails.append("legacy")
        }
        if PcClient.parsePair("http://example.com") != nil {
            fails.append("reject-http")
        }
        do {
            _ = try PcClient.inboxBase(ip: "192.168.50.86")
        } catch {
            fails.append("inbox")
        }
        return fails.isEmpty ? "PASS" : "FAIL \(fails.joined(separator: ","))"
    }
}
#endif
