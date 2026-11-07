import CryptoKit
import Foundation
import Security

enum PcClientError: LocalizedError {
    case badIP
    case noCertificate
    case badPairQR
    case authFailed
    case uploadFailed(String)
    case serverBusy

    var errorDescription: String? {
        switch self {
        case .badIP: return "請輸入電腦顯示的 IPv4 地址"
        case .noCertificate: return "電腦未提供憑證，請確認已開始接收"
        case .badPairQR: return "這不是 Cam Link 的配對 QR"
        case .authFailed: return "配對碼或接收器不符"
        case .uploadFailed(let s): return s
        case .serverBusy: return "電腦忙碌（503），稍後會重試"
        }
    }
}

enum PcClient {
    static let port = 9443

    struct PairParts { let host: String; let code: String }

    static func inboxBase(ip raw: String) throws -> String {
        var ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if ip.hasSuffix(":9443") { ip = String(ip.dropLast(5)) }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { throw PcClientError.badIP }
        for p in parts {
            guard let n = Int(p), (0 ... 255).contains(n) else { throw PcClientError.badIP }
        }
        return "https://\(ip):\(port)/inbox/"
    }

    static func parsePair(_ raw: String?) -> PairParts? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("camlink://") {
            guard let url = URL(string: text) else { return nil }
            let code = url.queryValue("code")
            let host = url.queryValue("ip") ?? url.queryValue("address") ?? url.queryValue("host")
            guard let host, let code, isPairCode(code), isPairHost(host) else { return nil }
            return PairParts(host: host, code: code)
        }
        if text.lowercased().hasPrefix("camlink:") {
            text = String(text.dropFirst(8))
            guard let cut = text.lastIndex(of: ":"), cut > text.startIndex else { return nil }
            let host = String(text[..<cut]).trimmingCharacters(in: .whitespaces)
            let code = String(text[text.index(after: cut)...]).trimmingCharacters(in: .whitespaces)
            guard isPairCode(code), isPairHost(host) else { return nil }
            return PairParts(host: host, code: code)
        }
        return nil
    }

    private static func isPairCode(_ code: String) -> Bool {
        code.range(of: #"^[0-9a-fA-F]{12}$"#, options: .regularExpression) != nil
    }

    private static func isPairHost(_ host: String) -> Bool {
        !host.isEmpty && !host.contains(" ") && !host.contains("/") && !host.contains("?")
            && host.range(of: #"^\d{1,5}$"#, options: .regularExpression) == nil
    }

    /// TLS handshake to read server cert SHA-256 (same as Android PcLink.probe).
    static func probeFingerprint(base: String) async throws -> String {
        guard let url = URL(string: base) else { throw PcClientError.badIP }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let box = ProbeBox(cont)
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            let session = URLSession(configuration: .ephemeral, delegate: box, delegateQueue: nil)
            box.session = session
            session.dataTask(with: request) { _, _, _ in
                box.finishIfNeeded()
            }.resume()
        }
    }

    static func authenticate(base: String, password: String, fingerprint: String) async throws {
        guard let url = URL(string: base) else { throw PcClientError.badIP }
        let session = pinnedSession(fingerprint: fingerprint)
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        request.setValue(basicAuth(password), forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PcClientError.authFailed }
        let header = http.value(forHTTPHeaderField: "X-CamLink-Receiver")
        guard http.statusCode == 200, header == "1" else { throw PcClientError.authFailed }
    }

    static func put(
        pair: ComputerPair,
        fileURL: URL,
        remoteName: String,
        sha256: String,
        size: Int64
    ) async throws {
        guard pair.isReady else { throw PcClientError.authFailed }
        let encoded = remoteName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? remoteName
        guard let url = URL(string: pair.inboxBase + encoded) else { throw PcClientError.badIP }
        let session = pinnedSession(fingerprint: pair.fingerprint)
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.setValue(basicAuth(pair.password), forHTTPHeaderField: "Authorization")
        request.setValue(sha256, forHTTPHeaderField: "X-CamLink-SHA256")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw PcClientError.uploadFailed("電腦無回應")
        }
        if http.statusCode == 503 { throw PcClientError.serverBusy }
        let back = http.value(forHTTPHeaderField: "X-CamLink-SHA256") ?? ""
        guard http.statusCode == 201, back.lowercased() == sha256.lowercased() else {
            throw PcClientError.uploadFailed("電腦未確認原圖（HTTP \(http.statusCode)）")
        }
    }

    private static func basicAuth(_ password: String) -> String {
        let data = Data("camlink:\(password)".utf8)
        return "Basic \(data.base64EncodedString())"
    }

    private static func pinnedSession(fingerprint: String) -> URLSession {
        let delegate = PinningDelegate(expected: fingerprint.lowercased())
        return URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    }
}

private final class ProbeBox: NSObject, URLSessionDelegate {
    var session: URLSession?
    private var fingerprint: String?
    private var resumed = false
    private let cont: CheckedContinuation<String, Error>

    init(_ cont: CheckedContinuation<String, Error>) {
        self.cont = cont
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust,
           let cert = Self.firstCertificate(trust) {
            let data = SecCertificateCopyData(cert) as Data
            fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func finishIfNeeded() {
        guard !resumed else { return }
        resumed = true
        if let fingerprint {
            cont.resume(returning: fingerprint)
        } else {
            cont.resume(throwing: PcClientError.noCertificate)
        }
        session?.invalidateAndCancel()
    }
}

private final class PinningDelegate: NSObject, URLSessionDelegate {
    let expected: String
    init(expected: String) { self.expected = expected }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust,
              let cert = Self.firstCertificate(trust)
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let data = SecCertificateCopyData(cert) as Data
        let finger = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if finger == expected {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

private enum TrustCert {
    static func firstCertificate(_ trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }
}

private extension ProbeBox {
    static func firstCertificate(_ trust: SecTrust) -> SecCertificate? {
        TrustCert.firstCertificate(trust)
    }
}

private extension PinningDelegate {
    static func firstCertificate(_ trust: SecTrust) -> SecCertificate? {
        TrustCert.firstCertificate(trust)
    }
}

private extension URL {
    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
