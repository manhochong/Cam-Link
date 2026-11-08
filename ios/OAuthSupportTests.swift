// macOS, Apple Silicon (Intel: replace arm64 with x86_64):
// xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 \
//   ios/CamLink/Transfer/OAuthSupport.swift ios/OAuthSupportTests.swift -o /tmp/oauth-support-tests
// /tmp/oauth-support-tests
// No real credentials, browser, Keychain items or external network are used.
// This suite is PREPARED, NOT executed in the Linux sandbox, which has no Swift executable.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor MemoryOAuthVault: OAuthCredentialVault {
    private var values: [OAuthCredentialKey: OAuthToken] = [:]
    private(set) var saves = 0
    private var saveDelay: UInt64 = 0
    func setSaveDelay(_ value: UInt64) { saveDelay = value }
    func load(for key: OAuthCredentialKey) async throws -> OAuthToken? { values[key] }
    func save(_ token: OAuthToken, for key: OAuthCredentialKey) async throws {
        // Deliberately non-cancellation-cooperative persistence: signOut must WAIT before delete.
        if saveDelay > 0 { try? await Task.sleep(nanoseconds: saveDelay) }
        values[key] = token
        saves += 1
    }
    func delete(for key: OAuthCredentialKey) async throws { values[key] = nil }
}

@MainActor
private final class MockOAuthBrowser: OAuthBrowserSession {
    var handler: ((URL) throws -> URL)?
    private(set) var starts = 0
    private(set) var cancels = 0
    private(set) var lastURL: URL?
    var pending: (@MainActor (Result<URL, OAuthFailure>) -> Void)?
    func start(url: URL, callbackScheme: String,
               completion: @escaping @MainActor (Result<URL, OAuthFailure>) -> Void) throws {
        starts += 1
        lastURL = url
        pending = completion
        if let handler = handler {
            let callback = try handler(url)
            pending = nil
            completion(.success(callback)) // Also exercises synchronous completion.
            completion(.success(callback)) // Duplicate must be harmless to the coordinator.
        }
    }
    func cancel() {
        cancels += 1
        let callback = pending
        pending = nil
        callback?(.failure(.cancelled)) // Reentrant cancel callback must not double-resume.
    }
}

/// URLProtocol works with actual injected URLSession; no invented networking abstraction.
private final class OAuthMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var data = Data()
        var headers: [String: String] = [:]
        var delay: TimeInterval = 0
        var redirect: URL?
        var error: Error?
    }
    private static let stateLock = NSLock()
    private static var responder: ((URLRequest) -> Reply)?
    private static var captured: [URLRequest] = []
    private let instanceLock = NSRecursiveLock()
    private var stopped = false

    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        stateLock.lock(); defer { stateLock.unlock() }
        responder = handler
        captured = []
    }
    static func requests() -> [URLRequest] {
        stateLock.lock(); defer { stateLock.unlock() }
        return captured
    }
    private static func reply(to request: URLRequest) -> Reply {
        stateLock.lock()
        captured.append(request)
        let handler = responder
        stateLock.unlock()
        return handler?(request) ?? Reply(status: 500)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.reply(to: request)
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in self?.deliver(reply) }
        } else { deliver(reply) }
    }
    private func deliver(_ reply: Reply) {
        instanceLock.lock(); defer { instanceLock.unlock() }
        guard !stopped else { return }
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: reply.headers) else { return }
        if let redirect = reply.redirect {
            // Darwin URL loading invokes the per-task redirect delegate. The sink must NEVER be requested.
            var redirected = request
            redirected.url = redirect
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        instanceLock.lock(); defer { instanceLock.unlock() }
        stopped = true
    }
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}

@main
@MainActor
final class OAuthSupportTests {
    private static var checks = 0
    private struct TestFailure: Error, CustomStringConvertible { let description: String }
    private static func check(_ condition: Bool, _ name: String) throws {
        checks += 1
        if !condition { throw TestFailure(description: "FAIL: \(name)") }
    }
    private static func rejects(_ expected: OAuthFailure, _ name: String,
                                _ operation: () throws -> Void) throws {
        do {
            try operation()
            throw TestFailure(description: "FAIL: expected rejection: \(name)")
        } catch let error as OAuthFailure { try check(error == expected, name) }
    }
    private static func rejectsAsync(_ expected: OAuthFailure, _ name: String,
                                     _ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            throw TestFailure(description: "FAIL: expected async rejection: \(name)")
        } catch let error as OAuthFailure {
            try check(error == expected, "\(name); expected=\(expected), actual=\(error)")
        }
    }
    private static func configuration(redirect: String = "hk.camlink.oauth.tests://auth/callback",
                                       extra: [String: String] = [:]) throws -> OAuthConfiguration {
        try OAuthConfiguration(clientID: "unit-test-public-client",
            authorizationEndpoint: URL(string: "https://identity.oauth.test/authorize")!,
            tokenEndpoint: URL(string: "https://identity.oauth.test/token")!,
            redirectURI: URL(string: redirect)!, scopes: ["offline_access", "Files.ReadWrite"],
            extraAuthorizationParameters: extra)
    }
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthMockURLProtocol.self]
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }
    private static func wire(access: String = "ACCESS_mock", refresh: String? = "REFRESH_mock",
                             seconds: Int = 3600) throws -> Data {
        var fields: [String: Any] = ["access_token": access, "token_type": "Bearer", "expires_in": seconds,
                                     "scope": "offline_access Files.ReadWrite"]
        if let refresh = refresh { fields["refresh_token"] = refresh }
        return try JSONSerialization.data(withJSONObject: fields)
    }
    private static func callback(for authorization: URL, redirect: URL, code: String = "CODE_mock") -> URL {
        let state = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!.queryItems!
            .first { $0.name == "state" }!.value!
        return URL(string: redirect.absoluteString + "?state=" + OAuthCodec.percentEncode(state)
                   + "&code=" + OAuthCodec.percentEncode(code))!
    }
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw TestFailure(description: "FAIL: mock operation did not start within one second")
    }
    private static func fields(_ data: Data) -> [String: String] {
        let encoded = String(decoding: data, as: UTF8.self)
        let items = URLComponents(string: "https://decode.oauth.test/?" + encoded)!.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private static func codecTests() throws {
        let config = try configuration(extra: ["prompt": "select_account"])
        let pkce = try OAuthPKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        try check(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "RFC7636 S256 vector")
        try check(!pkce.challenge.contains("="), "S256 no Base64 padding")
        try rejects(.invalidConfiguration, "PKCE cannot be short") { _ = try OAuthPKCE(verifier: "short") }
        try rejects(.invalidConfiguration, "PKCE rejects non-unreserved characters") {
            _ = try OAuthPKCE(verifier: String(repeating: "!", count: 43))
        }
        let request = try OAuthAuthorizationRequest(config: config)
        let another = try OAuthAuthorizationRequest(config: config)
        try check(request.pkce.verifier.count == 43 && request.state.count == 43, "256-bit random verifier and state")
        try check(request.state != another.state && request.pkce.verifier != another.pkce.verifier, "fresh random transaction")
        let auth = fields(Data(request.url.query!.utf8))
        try check(auth["code_challenge_method"] == "S256" && auth["response_type"] == "code", "code+S256 request")
        try check(auth["response_mode"] == "query" && auth["state"] == request.state, "query response and state")
        try check(auth["client_secret"] == nil && auth["code_verifier"] == nil, "authorization never exposes verifier or secret")
        try check(auth["redirect_uri"] == config.redirectURI.absoluteString && auth["prompt"] == "select_account", "registered redirect and allowed extra")
        let body = fields(OAuthCodec.codeExchangeBody(config: config, code: "a+b&c=? /", pkce: pkce))
        try check(body["code"] == "a+b&c=? /" && body["code_verifier"] == pkce.verifier, "form encoding round trip")
        try check(body["client_secret"] == nil && body["redirect_uri"] == config.redirectURI.absoluteString, "no secret in exchange")
        for key in ["state", "client_id", "redirect_uri", "code_challenge", "code_verifier", "response_type", "response_mode", "client_secret", "request_uri"] {
            try rejects(.invalidConfiguration, "reserved extra \(key)") { _ = try configuration(extra: [key: "unsafe"]) }
        }
        try rejects(.invalidConfiguration, "case variant extra") { _ = try configuration(extra: ["STATE": "unsafe"]) }
        try rejects(.invalidConfiguration, "pairing scheme forbidden") { _ = try configuration(redirect: "camlink://auth") }
        try rejects(.invalidConfiguration, "HTTPS callback not supported by this iOS16 custom-scheme bridge") {
            _ = try configuration(redirect: "https://callback.oauth.test/auth")
        }
        try rejects(.invalidConfiguration, "redirect fixed query forbidden") { _ = try configuration(redirect: "hk.camlink.oauth.tests://auth?fixed=1") }
        try rejects(.invalidConfiguration, "redirect fragment forbidden") { _ = try configuration(redirect: "hk.camlink.oauth.tests://auth#x") }
        for id in ["", "YOUR_CLIENT_ID", "placeholder", "<CLIENT_ID>", "00000000-0000-0000-0000-000000000000"] {
            try rejects(.invalidConfiguration, "missing or obvious dummy client ID") { try OAuthCodec.validateClientID(id) }
        }
        try rejects(.invalidConfiguration, "HTTP endpoint") { try OAuthCodec.validateHTTPS(URL(string: "http://identity.oauth.test/token")!) }
        try rejects(.invalidConfiguration, "URL user info") { try OAuthCodec.validateHTTPS(URL(string: "https://user:password@identity.oauth.test/token")!) }
        try rejects(.invalidConfiguration, "non-TLS port") { try OAuthCodec.validateHTTPS(URL(string: "https://identity.oauth.test:8080/token")!) }

        let good = callback(for: request.url, redirect: config.redirectURI, code: "a+b /code")
        try check(try OAuthCodec.authorizationCode(callback: good, redirectURI: config.redirectURI, expectedState: request.state) == "a+b /code", "exact callback and decoded code")
        let suffix = "?state=\(request.state)&code=CODE_mock"
        for wrong in ["hk.camlink.oauth.tests://evil/callback", "hk.camlink.oauth.tests://auth/callback/",
                      "hk.camlink.oauth.tests://auth/other", "hk.camlink.oauth.tests://auth:443/callback",
                      "hk.camlink.oauth.tests.evil://auth/callback", "hk.camlink.oauth.tests://AUTH/callback",
                      "hk.camlink.oauth.tests://auth/%63allback"] {
            try rejects(.invalidRedirect, "callback destination exact match") {
                _ = try OAuthCodec.authorizationCode(callback: URL(string: wrong + suffix)!, redirectURI: config.redirectURI, expectedState: request.state)
            }
        }
        try rejects(.invalidRedirect, "callback fragment") {
            _ = try OAuthCodec.authorizationCode(callback: URL(string: good.absoluteString + "#code=evil")!, redirectURI: config.redirectURI, expectedState: request.state)
        }
        try rejects(.stateMismatch, "state mismatch") {
            _ = try OAuthCodec.authorizationCode(callback: good, redirectURI: config.redirectURI, expectedState: "wrong")
        }
        for query in ["code=x", "state=&code=x"] {
            try rejects(.stateMismatch, "missing or empty state") {
                _ = try OAuthCodec.authorizationCode(callback: URL(string: config.redirectURI.absoluteString + "?" + query)!, redirectURI: config.redirectURI, expectedState: request.state)
            }
        }
        for query in ["state=\(request.state)&state=\(request.state)&code=x",
                      "state=\(request.state)&%73tate=\(request.state)&code=x",
                      "state=\(request.state)&code=x&code=y", "state=\(request.state)&code=",
                      "state=\(request.state)&code=x&error=access_denied",
                      "state=\(request.state)&code=x&access_token=TOKEN_mock",
                      "state=\(request.state)&code=x&flag"] {
            try rejects(.invalidResponse, "invalid/ambiguous callback parameters") {
                _ = try OAuthCodec.authorizationCode(callback: URL(string: config.redirectURI.absoluteString + "?" + query)!, redirectURI: config.redirectURI, expectedState: request.state)
            }
        }
        let denied = URL(string: config.redirectURI.absoluteString + "?state=\(request.state)&error=access_denied&error_description=TOKEN_mock")!
        try rejects(.denied, "denial is safe and bounded") {
            _ = try OAuthCodec.authorizationCode(callback: denied, redirectURI: config.redirectURI, expectedState: request.state)
        }
        // Google-style single-slash custom URI is handled generically, NOT claimed as supported Google iOS setup.
        let singleSlash = try configuration(redirect: "hk.camlink.oauth.tests:/oauth2redirect")
        let singleRequest = try OAuthAuthorizationRequest(config: singleSlash)
        try check(try OAuthCodec.authorizationCode(callback: callback(for: singleRequest.url, redirect: singleSlash.redirectURI),
            redirectURI: singleSlash.redirectURI, expectedState: singleRequest.state) == "CODE_mock", "custom URI single slash exact codec")

        let now = Date(timeIntervalSince1970: 1000)
        let first = try OAuthCodec.decodeToken(wire(), now: now)
        try check(first.expiresAt == Date(timeIntervalSince1970: 4600), "server expiration respected")
        try check(first.isUsable(at: now) && !first.isUsable(at: first.expiresAt.addingTimeInterval(-30)), "expiration skew")
        let noRotation = try OAuthCodec.decodeToken(wire(access: "ACCESS_next", refresh: nil), now: now, previous: first)
        try check(noRotation.refreshToken == first.refreshToken, "missing refresh token preserves old")
        let rotated = try OAuthCodec.decodeToken(wire(refresh: "REFRESH_rotated"), now: now, previous: first)
        try check(rotated.refreshToken == "REFRESH_rotated", "refresh rotation accepted")
        let stringExpiry = Data("{\"access_token\":\"ACCESS_mock\",\"token_type\":\"bearer\",\"expires_in\":\"120\"}".utf8)
        try check(try OAuthCodec.decodeToken(stringExpiry, now: now).expiresAt == now.addingTimeInterval(120), "string expires_in supported")
        for raw in ["{}", "{\"access_token\":\"A\",\"token_type\":\"Bearer\"}",
                    "{\"access_token\":\"A\",\"token_type\":\"DPoP\",\"expires_in\":60}",
                    "{\"access_token\":\"A\",\"token_type\":\"Bearer\",\"expires_in\":0}",
                    "{\"access_token\":\"A\",\"token_type\":\"Bearer\",\"expires_in\":\"nan\"}",
                    "{\"access_token\":\"A B\",\"token_type\":\"Bearer\",\"expires_in\":60}"] {
            try rejects(.invalidResponse, "malformed token rejected without echo") { _ = try OAuthCodec.decodeToken(Data(raw.utf8), now: now) }
        }
        try rejects(.invalidResponse, "bounded token JSON") { _ = try OAuthCodec.decodeToken(Data(repeating: 32, count: 1024 * 1024 + 1)) }
        let a = OAuthCredentialKey(provider: "drive", clientID: config.clientID, accountID: "id-a")
        let b = OAuthCredentialKey(provider: "onedrive", clientID: config.clientID, accountID: "id-a")
        let c = OAuthCredentialKey(provider: "drive", clientID: "other-public-client", accountID: "id-a")
        let d = OAuthCredentialKey(provider: "drive", clientID: config.clientID, accountID: "id-b")
        try check(Set([a.storageAccount, b.storageAccount, c.storageAccount, d.storageAccount]).count == 4, "provider/client/account vault isolation")
        try check(!a.storageAccount.contains("id-a"), "Keychain metadata not plaintext account ID")
        let encoded = try JSONEncoder().encode(first)
        try check(try JSONDecoder().decode(OAuthToken.self, from: encoded) == first, "credential Codable round trip")
        var settings = OAuthPublicClientSettings()
        try rejects(.invalidConfiguration, "settings default not network-ready") { _ = try settings.microsoftConfiguration() }
        settings.microsoftClientID = "unit-test-public-client"
        let microsoft = try settings.microsoftConfiguration()
        try check(microsoft.authorizationEndpoint.path == "/common/oauth2/v2.0/authorize"
                  && microsoft.scopes.contains("offline_access"), "personal and business common v2 + offline access")
    }

    private static func transportTests() async throws {
        let responseData = try wire()
        OAuthMockURLProtocol.install { _ in .init(data: responseData, headers: ["Retry-After": "12"]) }
        let http = OAuthHTTPClient(session: session(), timeout: 1)
        let api = URL(string: "https://graph.oauth.test/v1.0/me?select=id")!
        let response = try await http.send(URLRequest(url: api), bearerToken: "ACCESS_mock", allowedHosts: ["graph.oauth.test"])
        try check(response.statusCode == 200 && response.retryAfter == "12", "REST response with safe retry metadata")
        let sent = OAuthMockURLProtocol.requests()
        try check(sent.count == 1 && sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer ACCESS_mock", "bearer sent only as header")
        try await rejectsAsync(.invalidConfiguration, "unknown host rejected before send") {
            _ = try await http.send(URLRequest(url: URL(string: "https://evil.oauth.test/")!), bearerToken: "ACCESS_mock", allowedHosts: ["graph.oauth.test"])
        }
        try await rejectsAsync(.invalidConfiguration, "token query forbidden") {
            _ = try await http.send(URLRequest(url: URL(string: "https://graph.oauth.test/?access_token=ACCESS_mock")!), allowedHosts: ["graph.oauth.test"])
        }
        var preset = URLRequest(url: api)
        preset.setValue("Bearer ACCESS_mock", forHTTPHeaderField: "Authorization")
        let presetRequest = preset
        try await rejectsAsync(.invalidConfiguration, "manual authorization bypass forbidden") {
            _ = try await http.send(presetRequest, allowedHosts: ["graph.oauth.test"])
        }
        try await rejectsAsync(.invalidResponse, "bearer CRLF injection forbidden") {
            _ = try await http.send(URLRequest(url: api), bearerToken: "A\r\nX: value", allowedHosts: ["graph.oauth.test"])
        }
        try check(OAuthMockURLProtocol.requests().count == 1, "invalid requests did not reach transport")

        for destination in ["https://evil.oauth.test/sink?token=SECRET_mock", "https://graph.oauth.test/sink"] {
            OAuthMockURLProtocol.install { _ in
                .init(status: 302, headers: ["Location": destination], redirect: URL(string: destination)!)
            }
            try await rejectsAsync(.redirectRefused, "redirect refused without second request") {
                _ = try await http.send(URLRequest(url: api), bearerToken: "ACCESS_mock", allowedHosts: ["graph.oauth.test"])
            }
            try check(OAuthMockURLProtocol.requests().count == 1, "bearer not sent to redirect sink")
        }
        let malicious = Data("{\"error\":\"SECRET_mock_https://host/?access_token=LEAK\",\"error_description\":\"REFRESH_mock\"}".utf8)
        OAuthMockURLProtocol.install { _ in .init(status: 401, data: malicious) }
        try await rejectsAsync(.http(status: 401, code: .unknown), "untrusted server error not echoed") {
            _ = try await http.send(URLRequest(url: api), allowedHosts: ["graph.oauth.test"])
        }
        let graphError = Data("{\"error\":{\"code\":\"InvalidAuthenticationToken\",\"message\":\"ACCESS_mock\"}}".utf8)
        try check(OAuthCodec.serverError(graphError) == .invalidToken, "allowlisted Graph machine code")
        let failure = OAuthFailure.http(status: 401, code: OAuthCodec.serverError(malicious)).localizedDescription
        try check(failure.count < 120 && !failure.contains("mock") && !failure.contains("https"), "bounded secret-free diagnostics")
        let originalError = NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
                                    userInfo: [NSLocalizedDescriptionKey: "ACCESS_mock https://host/?secret=REFRESH_mock"])
        OAuthMockURLProtocol.install { _ in .init(error: originalError) }
        try await rejectsAsync(.network, "NSError URL and description not exposed") {
            _ = try await http.send(URLRequest(url: api), allowedHosts: ["graph.oauth.test"])
        }
        OAuthMockURLProtocol.install { _ in .init(data: responseData, delay: 0.5) }
        let shortHTTP = OAuthHTTPClient(session: session(), timeout: 0.05)
        try await rejectsAsync(.timedOut, "whole request deadline") {
            _ = try await shortHTTP.send(URLRequest(url: api), allowedHosts: ["graph.oauth.test"])
        }
        OAuthMockURLProtocol.install { _ in .init(data: responseData, delay: 0.5) }
        let task = Task { try await http.send(URLRequest(url: api), allowedHosts: ["graph.oauth.test"]) }
        try await waitUntil { !OAuthMockURLProtocol.requests().isEmpty }
        task.cancel()
        try await rejectsAsync(.cancelled, "network cancellation") { _ = try await task.value }
    }

    private static func authorizationTests() async throws {
        let config = try configuration()
        let responseData = try wire()
        let vault = MemoryOAuthVault(), browser = MockOAuthBrowser()
        let http = OAuthHTTPClient(session: session(), timeout: 1)
        let coordinator = OAuthCoordinator(browser: browser, http: http, vault: vault, authorizationTimeout: 1)
        OAuthMockURLProtocol.install { _ in .init(data: responseData) }
        browser.handler = { callback(for: $0, redirect: config.redirectURI) }
        let token = try await coordinator.authorize(config)
        try check(token.accessToken == "ACCESS_mock" && browser.starts == 1, "native-bridge mock authorization")
        let sent = OAuthMockURLProtocol.requests()
        try check(sent.count == 1 && sent[0].httpMethod == "POST", "one code exchange after exact callback")
        let exchange = fields(OAuthMockURLProtocol.body(sent[0]))
        try check(exchange["grant_type"] == "authorization_code" && exchange["code_verifier"]?.count == 43,
                  "real URLSession receives PKCE token POST")
        try check(exchange["client_secret"] == nil && sent[0].value(forHTTPHeaderField: "Authorization") == nil,
                  "public code exchange contains neither client secret nor bearer")
        let savedCount = await vault.saves
        try check(savedCount == 0, "authorize does not guess account or persist before identity resolution")
        for wrong in ["hk.camlink.oauth.tests://evil/callback", "hk.camlink.oauth.tests://auth/other"] {
            OAuthMockURLProtocol.install { _ in .init(data: responseData) }
            browser.handler = { callback(for: $0, redirect: URL(string: wrong)!) }
            try await rejectsAsync(.invalidRedirect, "bad callback rejected BEFORE exchange") { _ = try await coordinator.authorize(config) }
            try check(OAuthMockURLProtocol.requests().isEmpty, "bad callback sends zero token requests")
        }
        browser.handler = { _ in URL(string: config.redirectURI.absoluteString + "?state=WRONG&code=CODE_mock")! }
        try await rejectsAsync(.stateMismatch, "bad state before exchange") { _ = try await coordinator.authorize(config) }
        try check(OAuthMockURLProtocol.requests().isEmpty, "bad state sends zero token requests")

        browser.handler = nil
        let active = Task { try await coordinator.authorize(config) }
        try await waitUntil { browser.pending != nil }
        let staleCallback = browser.pending!
        let otherBrowser = MockOAuthBrowser()
        let other = OAuthCoordinator(browser: otherBrowser, http: http, vault: vault)
        try await rejectsAsync(.busy, "global single active session") { _ = try await other.authorize(config) }
        try check(otherBrowser.starts == 0, "second browser never started")
        coordinator.cancelAuthorization()
        try await rejectsAsync(.cancelled, "explicit authorization cancel") { _ = try await active.value }
        try check(browser.cancels > 0, "native bridge cancel called")
        staleCallback(.success(URL(string: config.redirectURI.absoluteString + "?state=late&code=LATE_mock")!))
        try check(OAuthMockURLProtocol.requests().isEmpty, "late callback cannot exchange code")

        let cancelledTask = Task { try await coordinator.authorize(config) }
        try await waitUntil { browser.pending != nil }
        cancelledTask.cancel()
        try await rejectsAsync(.cancelled, "structured task cancellation cancels interactive session") { _ = try await cancelledTask.value }
        let slow = OAuthCoordinator(browser: browser, http: http, vault: vault, authorizationTimeout: 0.05)
        try await rejectsAsync(.timedOut, "interactive session short deadline") { _ = try await slow.authorize(config) }
        try check(browser.pending == nil, "timed-out session cleared")
        browser.handler = { callback(for: $0, redirect: config.redirectURI) }
        OAuthMockURLProtocol.install { _ in .init(data: responseData) }
        otherBrowser.handler = { callback(for: $0, redirect: config.redirectURI) }
        _ = try await other.authorize(config)
        try check(otherBrowser.starts == 1, "global session lock released after cancel and timeout")
    }

    private static func credentialTests() async throws {
        let config = try configuration(), browser = MockOAuthBrowser(), vault = MemoryOAuthVault()
        let http = OAuthHTTPClient(session: session(), timeout: 1)
        let coordinator = OAuthCoordinator(browser: browser, http: http, vault: vault)
        let key = OAuthCredentialKey(provider: "onedrive", clientID: config.clientID, accountID: "account-a")
        let second = OAuthCredentialKey(provider: "onedrive", clientID: config.clientID, accountID: "account-b")
        let old = OAuthToken(accessToken: "ACCESS_old", refreshToken: "REFRESH_old", expiresAt: Date(timeIntervalSince1970: 0), scope: "offline_access")
        try await coordinator.store(old, for: key)
        try await coordinator.store(OAuthToken(accessToken: "ACCESS_b", refreshToken: "REFRESH_b", expiresAt: Date().addingTimeInterval(3600)), for: second)
        let rotatedData = try wire(access: "ACCESS_new", refresh: "REFRESH_new")
        OAuthMockURLProtocol.install { _ in .init(data: rotatedData, delay: 0.05) }
        async let first = coordinator.validToken(for: key, config: config)
        async let concurrent = coordinator.validToken(for: key, config: config)
        let (a, b) = try await (first, concurrent)
        try check(a == b && a.refreshToken == "REFRESH_new", "parallel API callers share rotated refresh")
        try check(OAuthMockURLProtocol.requests().count == 1, "one serialized refresh HTTP request")
        let request = OAuthMockURLProtocol.requests()[0]
        let body = fields(OAuthMockURLProtocol.body(request))
        try check(body["grant_type"] == "refresh_token" && body["refresh_token"] == "REFRESH_old"
                  && body["scope"]?.contains("offline_access") == true && body["client_secret"] == nil,
                  "public refresh POST + offline access")
        let stored = try await vault.load(for: key)
        try check(stored == a, "rotation stored atomically before returning usable token")
        _ = try await coordinator.validToken(for: key, config: config)
        try check(OAuthMockURLProtocol.requests().count == 1, "unexpired token does not refresh again")
        try await coordinator.signOut(key)
        let absent = try await vault.load(for: key), retained = try await vault.load(for: second)
        try check(absent == nil && retained?.accessToken == "ACCESS_b", "sign-out deletes only selected account")
        try await rejectsAsync(.credentialMissing, "signed-out account cannot resurrect") { _ = try await coordinator.validToken(for: key, config: config) }
        let afterSignOut = OAuthMockURLProtocol.requests().count
        try check(afterSignOut == 1, "local sign-out makes no revocation/network request")
        try await coordinator.store(old, for: key)
        OAuthMockURLProtocol.install { _ in .init(data: rotatedData, delay: 0.5) }
        let pending = Task { try await coordinator.validToken(for: key, config: config) }
        try await waitUntil { !OAuthMockURLProtocol.requests().isEmpty }
        try await coordinator.signOut(key)
        try await rejectsAsync(.cancelled, "sign-out cancels in-flight refresh") { _ = try await pending.value }
        let deleted = try await vault.load(for: key)
        try check(deleted == nil, "refresh cannot save after sign-out")

        // Race a delayed vault save against local sign-out; persisted token must still end absent.
        await vault.setSaveDelay(100_000_000)
        let storing = Task { try await coordinator.store(old, for: key) }
        try await Task.sleep(nanoseconds: 10_000_000)
        try await coordinator.signOut(key)
        try await rejectsAsync(.cancelled, "sign-out cancels delayed credential save") { try await storing.value }
        let deletedAfterStore = try await vault.load(for: key)
        try check(deletedAfterStore == nil, "delayed save cannot resurrect signed-out credential")
        await vault.setSaveDelay(0)

        let noRefresh = OAuthToken(accessToken: "ACCESS_only", expiresAt: Date(timeIntervalSince1970: 0))
        try await coordinator.store(noRefresh, for: key)
        OAuthMockURLProtocol.install { _ in .init(data: rotatedData) }
        try await rejectsAsync(.credentialMissing, "expired token without refresh requires login") {
            _ = try await coordinator.validToken(for: key, config: config)
        }
        try check(OAuthMockURLProtocol.requests().isEmpty, "no invented refresh credential")
        let wrongKey = OAuthCredentialKey(provider: "onedrive", clientID: "different-public-client", accountID: "account-a")
        try await rejectsAsync(.invalidConfiguration, "vault client mismatch") { _ = try await coordinator.validToken(for: wrongKey, config: config) }

        // Low-level refresh retains an omitted refresh_token and single-flights equivalent callers.
        let omittedData = try wire(access: "ACCESS_final", refresh: nil)
        OAuthMockURLProtocol.install { _ in .init(data: omittedData, delay: 0.05) }
        async let directA = coordinator.refresh(config, token: old)
        async let directB = coordinator.refresh(config, token: old)
        let (x, y) = try await (directA, directB)
        try check(x == y && x.refreshToken == "REFRESH_old", "direct refresh single-flight + omitted rotation")
        try check(OAuthMockURLProtocol.requests().count == 1, "direct refresh uses one HTTP exchange")
    }

    static func main() async throws {
        try codecTests()
        try await transportTests()
        try await authorizationTests()
        try await credentialTests()
        print("PASS: \(checks) OAuth checks (mock-only; real provider/iPad acceptance still required)")
    }
}
