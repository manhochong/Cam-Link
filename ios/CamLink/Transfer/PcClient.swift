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
    case unsafeRemoteName
    case redirectRefused
    case transientHTTP(Int)

    var errorDescription: String? {
        switch self {
        case .badIP: return "請輸入電腦顯示的 IPv4 地址"
        case .noCertificate: return "電腦未提供憑證，請確認已開始接收"
        case .badPairQR: return "這不是 Cam Link 的配對 QR"
        case .authFailed: return "配對碼或接收器不符"
        case .uploadFailed(let s): return s
        case .serverBusy: return "電腦忙碌（503），稍後會重試"
        case .unsafeRemoteName: return "PC 原圖檔名、大小或 SHA-256 無效"
        case .redirectRefused: return "已拒絕接收器重導向，配對碼不會轉送"
        case .transientHTTP(let status): return "電腦暂時未能接收（HTTP \(status)）"
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
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let box = ProbeBox(cont)
            var request = URLRequest(url: url, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            CamLinkNetworkPolicy.apply(to: &request, allowsCellular: false)
            let configuration = URLSessionConfiguration.ephemeral
            CamLinkNetworkPolicy.apply(to: configuration, allowsCellular: false)
            let session = URLSession(configuration: configuration, delegate: box, delegateQueue: nil)
            box.session = session
            session.dataTask(with: request) { _, _, _ in
                box.finishIfNeeded()
            }.resume()
        }
    }

    static func authenticate(base: String, password: String, fingerprint: String) async throws {
        guard let url = URL(string: base) else { throw PcClientError.badIP }
        let session = pinnedSession(fingerprint: fingerprint)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        request.setValue(basicAuth(password), forHTTPHeaderField: "Authorization")
        CamLinkNetworkPolicy.apply(to: &request, allowsCellular: false)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PcClientError.authFailed }
        guard http.url == url, !(300...399).contains(http.statusCode) else {
            throw PcClientError.redirectRefused
        }
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
        guard isSafeRemoteName(remoteName), size > 0, size <= 512 * 1024 * 1024,
              sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw PcClientError.unsafeRemoteName
        }
        let base = try inboxBase(ip: pair.host)
        guard pair.inboxBase == base, let url = URL(string: base + remoteName) else {
            throw PcClientError.badIP
        }
        let session = pinnedSession(fingerprint: pair.fingerprint)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.setValue(basicAuth(pair.password), forHTTPHeaderField: "Authorization")
        request.setValue(sha256, forHTTPHeaderField: "X-CamLink-SHA256")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        CamLinkNetworkPolicy.apply(to: &request, allowsCellular: false)
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else {
            throw PcClientError.uploadFailed("電腦無回應")
        }
        guard http.url == url, !(300...399).contains(http.statusCode) else {
            throw PcClientError.redirectRefused
        }
        if http.statusCode == 503 { throw PcClientError.serverBusy }
        if http.statusCode == 401 { throw PcClientError.authFailed }
        if [408, 429].contains(http.statusCode) || http.statusCode >= 500 {
            throw PcClientError.transientHTTP(http.statusCode)
        }
        let back = http.value(forHTTPHeaderField: "X-CamLink-SHA256") ?? ""
        guard http.statusCode == 201, back.lowercased() == sha256.lowercased() else {
            throw PcClientError.uploadFailed("電腦未確認原圖（HTTP \(http.statusCode)）")
        }
    }

    /// Exact Receiver allowlist; no path segments, %-decoding, query or traversal.
    static func isSafeRemoteName(_ name: String) -> Bool {
        !name.contains("..") && name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,190}\\.jpe?g$",
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func basicAuth(_ password: String) -> String {
        let data = Data("camlink:\(password)".utf8)
        return "Basic \(data.base64EncodedString())"
    }

    private static func pinnedSession(fingerprint: String) -> URLSession {
        let delegate = PinningDelegate(expected: fingerprint.lowercased())
        let configuration = URLSessionConfiguration.ephemeral
        CamLinkNetworkPolicy.apply(to: configuration, allowsCellular: false)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
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

private final class PinningDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let expected: String
    init(expected: String) { self.expected = expected }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

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
