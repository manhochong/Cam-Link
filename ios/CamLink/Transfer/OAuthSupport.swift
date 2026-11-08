import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(UIKit)
import UIKit
import AuthenticationServices
#endif

// Public-client foundation only. No provider client IDs, client secrets, upload or camera code.
struct OAuthConfiguration: Sendable, Equatable {
    let clientID: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let redirectURI: URL
    let scopes: [String]
    let extraAuthorizationParameters: [String: String]

    init(clientID: String, authorizationEndpoint: URL, tokenEndpoint: URL,
         redirectURI: URL, scopes: [String],
         extraAuthorizationParameters: [String: String] = [:]) throws {
        try OAuthCodec.validateClientID(clientID)
        try OAuthCodec.validateHTTPS(authorizationEndpoint)
        try OAuthCodec.validateHTTPS(tokenEndpoint)
        guard authorizationEndpoint.query == nil, tokenEndpoint.query == nil,
              let redirect = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false),
              let scheme = redirect.scheme, scheme.contains("."),
              !["http", "https", "file", "camlink"].contains(scheme.lowercased()),
              redirect.user == nil, redirect.password == nil, redirect.port == nil,
              redirect.query == nil, redirect.fragment == nil,
              !scopes.isEmpty, Set(scopes).count == scopes.count,
              scopes.allSatisfy({ OAuthCodec.isText($0, maximum: 2048) && !$0.contains(where: { $0.isWhitespace }) })
        else { throw OAuthFailure.invalidConfiguration }
        let reserved: Set<String> = ["client_id", "client_secret", "client_assertion", "client_assertion_type",
            "redirect_uri", "response_type", "response_mode", "scope", "state", "code", "code_verifier",
            "code_challenge", "code_challenge_method", "grant_type", "access_token", "refresh_token", "request", "request_uri"]
        guard extraAuthorizationParameters.count <= 20,
              extraAuthorizationParameters.allSatisfy({ key, value in
                  key == key.lowercased() && !reserved.contains(key)
                      && key.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 })
                      && OAuthCodec.isText(key, maximum: 64) && OAuthCodec.isText(value, maximum: 2048)
              }) else { throw OAuthFailure.invalidConfiguration }
        self.clientID = clientID
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.extraAuthorizationParameters = extraAuthorizationParameters
    }
}

struct OAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scope: String?
    let tokenType: String

    init(accessToken: String, refreshToken: String? = nil, expiresAt: Date,
         scope: String? = nil, tokenType: String = "Bearer") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }
    func isUsable(at date: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSince(date) > max(0, leeway)
    }
}

/// Public, editable settings only; blank IDs deliberately fail before any network call.
/// Persist these settings separately from credentials. URL schemes must be added at BUILD time.
struct OAuthPublicClientSettings: Codable, Equatable, Sendable {
    var googleIOSClientID = ""
    var microsoftClientID = ""
    var microsoftRedirectURI = "msauth.hk.camlink.ios://auth"

    func microsoftConfiguration() throws -> OAuthConfiguration {
        guard let redirect = URL(string: microsoftRedirectURI) else { throw OAuthFailure.invalidConfiguration }
        return try OAuthConfiguration(clientID: microsoftClientID,
            authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            redirectURI: redirect,
            scopes: ["openid", "profile", "offline_access", "User.Read", "Files.ReadWrite"],
            extraAuthorizationParameters: ["prompt": "select_account"])
    }
    /// For official GIDSignIn configuration, not a guessed /oauth2redirect request.
    func googleReversedClientID() throws -> String {
        try OAuthCodec.validateClientID(googleIOSClientID)
        guard googleIOSClientID.hasSuffix(".apps.googleusercontent.com") else {
            throw OAuthFailure.invalidConfiguration
        }
        return googleIOSClientID.split(separator: ".").reversed().joined(separator: ".")
    }
}

/// Only allowlisted machine codes are exposed. Never retain server descriptions or payloads in errors.
enum OAuthServerError: String, Sendable {
    case invalidRequest = "invalid_request", invalidGrant = "invalid_grant"
    case invalidClient = "invalid_client", invalidScope = "invalid_scope"
    case accessDenied = "access_denied", interactionRequired = "interaction_required"
    case temporarilyUnavailable = "temporarily_unavailable", serverError = "server_error"
    case invalidToken = "invalid_token", notFound = "not_found", quota, rateLimited = "rate_limited", unknown
}

enum OAuthFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, invalidRedirect, stateMismatch, invalidResponse
    case denied, interactionRequired, busy, cancelled, timedOut, browserUnavailable, browserFailed
    case secureRandomUnavailable, network, redirectRefused, storage, credentialMissing
    case http(status: Int, code: OAuthServerError)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "OAuth configuration is missing or invalid."
        case .invalidRedirect: return "OAuth callback destination did not match."
        case .stateMismatch: return "OAuth callback state did not match."
        case .invalidResponse: return "OAuth response was invalid."
        case .denied: return "Sign-in permission was declined."
        case .interactionRequired: return "Sign in again to continue."
        case .busy: return "Another OAuth operation is active."
        case .cancelled: return "OAuth operation was cancelled."
        case .timedOut: return "OAuth operation timed out."
        case .browserUnavailable: return "No foreground sign-in window is available."
        case .browserFailed: return "The system sign-in session could not complete."
        case .secureRandomUnavailable: return "Secure random generation failed."
        case .network: return "OAuth network request failed."
        case .redirectRefused: return "HTTP redirect refused; credentials were not forwarded."
        case .storage: return "Secure credential storage failed."
        case .credentialMissing: return "No local credential is available; sign in again."
        case let .http(status, code): return "OAuth/API HTTP \(status) (\(code.rawValue))."
        }
    }
    static func sanitized(_ error: Error) -> OAuthFailure {
        if let failure = error as? OAuthFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            if error.code == .timedOut { return .timedOut }
        }
        // URLError.localizedDescription and NSError.userInfo can contain full URLs or secrets.
        return .network
    }
}

struct OAuthPKCE: Equatable, Sendable {
    let verifier: String
    let challenge: String
    init(verifier: String) throws {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)
        guard (43...128).contains(verifier.utf8.count), verifier.utf8.allSatisfy({ allowed.contains($0) })
        else { throw OAuthFailure.invalidConfiguration }
        self.verifier = verifier
        challenge = OAuthCodec.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    static func generate() throws -> OAuthPKCE {
        try OAuthPKCE(verifier: OAuthCodec.randomString(byteCount: 32))
    }
}

struct OAuthAuthorizationRequest: Sendable {
    let url: URL
    let state: String
    let pkce: OAuthPKCE
    init(config: OAuthConfiguration) throws {
        let state = try OAuthCodec.randomString(byteCount: 32)
        let pkce = try OAuthPKCE.generate()
        let url = try OAuthCodec.authorizationURL(config: config, state: state, pkce: pkce)
        self.state = state
        self.pkce = pkce
        self.url = url
    }
}

/// Pure URL/form/JSON codec: executable on macOS without UIKit or an authentication UI.
enum OAuthCodec {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func randomString(byteCount: Int) throws -> String {
        guard (16...128).contains(byteCount) else { throw OAuthFailure.invalidConfiguration }
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw OAuthFailure.secureRandomUnavailable }
        return base64URL(Data(bytes))
        #else
        throw OAuthFailure.secureRandomUnavailable // Never fall back to non-cryptographic randomness.
        #endif
    }
    static func isText(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func validateClientID(_ value: String) throws {
        let lower = value.lowercased()
        guard isText(value, maximum: 512), !value.contains(where: { $0.isWhitespace }),
              !value.contains("<"), !value.contains(">"),
              !["your", "placeholder", "replace", "change_me", "example"].contains(where: { lower.contains($0) }),
              lower != "client_id", lower != "client-id", lower != "00000000-0000-0000-0000-000000000000"
        else { throw OAuthFailure.invalidConfiguration }
    }
    static func validateHTTPS(_ url: URL, allowedHosts: Set<String>? = nil) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port == nil || parts.port == 443,
              allowedHosts == nil || allowedHosts!.contains(host.lowercased())
        else { throw OAuthFailure.invalidConfiguration }
    }
    static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)!
    }
    static func form(_ fields: [String: String]) -> Data {
        Data(fields.keys.sorted().map { "\(percentEncode($0))=\(percentEncode(fields[$0]!))" }.joined(separator: "&").utf8)
    }
    static func authorizationURL(config: OAuthConfiguration, state: String, pkce: OAuthPKCE) throws -> URL {
        guard isText(state, maximum: 256) else { throw OAuthFailure.invalidConfiguration }
        var fields = config.extraAuthorizationParameters
        fields["client_id"] = config.clientID
        fields["redirect_uri"] = config.redirectURI.absoluteString
        fields["response_type"] = "code"
        fields["response_mode"] = "query"
        fields["scope"] = config.scopes.joined(separator: " ")
        fields["state"] = state
        fields["code_challenge"] = pkce.challenge
        fields["code_challenge_method"] = "S256"
        var parts = URLComponents(url: config.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        parts.percentEncodedQuery = String(decoding: form(fields), as: UTF8.self)
        guard let url = parts.url else { throw OAuthFailure.invalidConfiguration }
        return url
    }
    /// Must run BEFORE the code is posted. Exact serialized base URI; never just compare scheme/prefix.
    static func authorizationCode(callback: URL, redirectURI: URL, expectedState: String) throws -> String {
        guard callback.absoluteString.utf8.count <= 16384,
              var parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.fragment == nil, parts.user == nil, parts.password == nil,
              let rawQuery = parts.percentEncodedQuery else { throw OAuthFailure.invalidRedirect }
        parts.percentEncodedQuery = nil
        guard parts.url?.absoluteString == redirectURI.absoluteString else { throw OAuthFailure.invalidRedirect }
        // Reject malformed %-escapes, duplicate decoded keys, absent values and oversized parameters.
        var fields: [String: String] = [:]
        for pair in rawQuery.split(separator: "&", omittingEmptySubsequences: false) {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2,
                  let key = String(components[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(components[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  isText(key, maximum: 128), value.utf8.count <= 8192, fields[key] == nil
            else { throw OAuthFailure.invalidResponse }
            fields[key] = value
        }
        guard !expectedState.isEmpty, let state = fields["state"], constantTimeEqual(state, expectedState)
        else { throw OAuthFailure.stateMismatch }
        if let error = fields["error"] {
            guard fields["code"] == nil else { throw OAuthFailure.invalidResponse }
            if error == "access_denied" { throw OAuthFailure.denied }
            if ["interaction_required", "login_required", "consent_required"].contains(error) {
                throw OAuthFailure.interactionRequired
            }
            throw OAuthFailure.invalidResponse
        }
        guard let code = fields["code"], isText(code, maximum: 8192), fields["access_token"] == nil,
              fields["id_token"] == nil else { throw OAuthFailure.invalidResponse }
        return code
    }
    private static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
    static func codeExchangeBody(config: OAuthConfiguration, code: String, pkce: OAuthPKCE) -> Data {
        form(["client_id": config.clientID, "grant_type": "authorization_code", "code": code,
              "redirect_uri": config.redirectURI.absoluteString, "code_verifier": pkce.verifier])
    }
    static func refreshBody(config: OAuthConfiguration, token: OAuthToken) throws -> Data {
        guard let refresh = token.refreshToken, isText(refresh, maximum: 32768) else {
            throw OAuthFailure.credentialMissing
        }
        return form(["client_id": config.clientID, "grant_type": "refresh_token", "refresh_token": refresh,
                     "scope": config.scopes.joined(separator: " ")])
    }
    static func validateToken(_ token: OAuthToken) throws {
        guard isBearerValue(token.accessToken), token.tokenType.lowercased() == "bearer",
              token.expiresAt.timeIntervalSince1970.isFinite,
              token.refreshToken == nil || isText(token.refreshToken!, maximum: 32768),
              token.scope == nil || isText(token.scope!, maximum: 16384)
        else { throw OAuthFailure.invalidResponse }
    }
    static func isBearerValue(_ value: String) -> Bool {
        guard isText(value, maximum: 32768) else { return false }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/".utf8)
        var padding = false
        for byte in value.utf8 {
            if byte == 61 { padding = true }
            else if padding || !allowed.contains(byte) { return false }
        }
        return value.utf8.first != 61
    }
    static func decodeToken(_ data: Data, now: Date = Date(), previous: OAuthToken? = nil) throws -> OAuthToken {
        guard data.count <= 1024 * 1024 else { throw OAuthFailure.invalidResponse }
        do {
            let wire = try JSONDecoder().decode(WireToken.self, from: data)
            guard wire.expiresIn.isFinite, wire.expiresIn > 0, wire.expiresIn <= 31_536_000 else {
                throw OAuthFailure.invalidResponse
            }
            let token = OAuthToken(accessToken: wire.accessToken,
                refreshToken: wire.refreshToken ?? previous?.refreshToken,
                expiresAt: now.addingTimeInterval(wire.expiresIn),
                scope: wire.scope ?? previous?.scope, tokenType: wire.tokenType)
            try validateToken(token)
            return token
        } catch { throw OAuthFailure.invalidResponse }
    }
    private struct WireToken: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double
        let scope: String?
        let tokenType: String
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
            case scope, tokenType = "token_type"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try values.decode(String.self, forKey: .accessToken)
            refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
            scope = try values.decodeIfPresent(String.self, forKey: .scope)
            tokenType = try values.decode(String.self, forKey: .tokenType)
            if let seconds = try? values.decode(Double.self, forKey: .expiresIn) { expiresIn = seconds }
            else {
                let value = try values.decode(String.self, forKey: .expiresIn)
                guard let seconds = Double(value) else { throw OAuthFailure.invalidResponse }
                expiresIn = seconds
            }
        }
    }
    static func serverError(_ data: Data) -> OAuthServerError {
        guard data.count <= 65536, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .unknown }
        let value = json["error"] as? String ?? (json["error"] as? [String: Any])?["code"] as? String ?? ""
        if let known = OAuthServerError(rawValue: value) { return known }
        switch value {
        case "InvalidAuthenticationToken": return .invalidToken
        case "accessDenied": return .accessDenied
        case "itemNotFound": return .notFound
        case "quotaLimitReached": return .quota
        case "activityLimitReached", "tooManyRequests": return .rateLimited
        default: return .unknown
        }
    }
}

struct OAuthHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    /// Only selected non-secret response metadata; no request URL or arbitrary headers.
    let retryAfter: String?
}

/// Per-task delegate takes precedence over an injected URLSession's redirect policy.
private final class OAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Refuse ALL redirects, including same-host redirects.
    }
}

final class OAuthHTTPClient: @unchecked Sendable {
    private let session: URLSession
    private let timeout: TimeInterval
    init(session: URLSession? = nil, timeout: TimeInterval = 20) {
        if let session = session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
        self.timeout = timeout.isFinite ? min(30, max(0.05, timeout)) : 20
    }
    /// Providers must supply exact trusted API hosts; an upload capability URL uses a separate no-bearer request.
    func send(_ request: URLRequest, bearerToken: String? = nil,
              allowedHosts: Set<String>) async throws -> OAuthHTTPResponse {
        guard let url = request.url, !allowedHosts.isEmpty,
              request.value(forHTTPHeaderField: "Authorization") == nil else { throw OAuthFailure.invalidConfiguration }
        try OAuthCodec.validateHTTPS(url, allowedHosts: allowedHosts)
        guard !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .contains(where: { ["access_token", "refresh_token", "client_secret"].contains($0.name.lowercased()) })
        else { throw OAuthFailure.invalidConfiguration }
        var outgoing = request
        outgoing.timeoutInterval = timeout
        outgoing.cachePolicy = .reloadIgnoringLocalCacheData
        outgoing.httpShouldHandleCookies = false
        if let bearer = bearerToken {
            guard OAuthCodec.isBearerValue(bearer) else { throw OAuthFailure.invalidResponse }
            outgoing.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        do {
            try Task.checkCancellation()
            let (data, response) = try await boundedData(for: outgoing)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw OAuthFailure.invalidResponse }
            guard response.url?.absoluteString == url.absoluteString,
                  !(300...399).contains(response.statusCode) else { throw OAuthFailure.redirectRefused }
            guard (200...299).contains(response.statusCode) else {
                throw OAuthFailure.http(status: response.statusCode, code: OAuthCodec.serverError(data))
            }
            // HTTP metadata cannot be allowed to become an unbounded diagnostic channel.
            let retry = response.value(forHTTPHeaderField: "Retry-After")
            let safeRetry = retry.flatMap { value -> String? in
                guard value.count <= 10, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
                return value
            }
            return OAuthHTTPResponse(data: data, statusCode: response.statusCode, retryAfter: safeRetry)
        } catch { throw OAuthFailure.sanitized(error) }
    }
    private struct NetworkReply: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }
    private func boundedData(for request: URLRequest) async throws -> (Data, URLResponse) {
        // URLRequest timeout alone is an inactivity timeout. This bounds the whole request too.
        let reply = try await withThrowingTaskGroup(of: NetworkReply.self) { group in
            group.addTask {
                let (data, response) = try await self.session.data(for: request, delegate: OAuthNoRedirectDelegate())
                return NetworkReply(data: data, response: response)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                throw OAuthFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OAuthFailure.network }
            return first
        }
        return (reply.data, reply.response)
    }
    func exchange(config: OAuthConfiguration, body: Data, previous: OAuthToken? = nil) async throws -> OAuthToken {
        var request = URLRequest(url: config.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        let response = try await send(request, allowedHosts: [config.tokenEndpoint.host!.lowercased()])
        return try OAuthCodec.decodeToken(response.data, previous: previous)
    }
}

/// Key includes stable provider identity; never use email or an unverified ID-token claim as accountID.
struct OAuthCredentialKey: Codable, Hashable, Sendable {
    let provider: String
    let clientID: String
    let accountID: String
    init(provider: String, clientID: String, accountID: String) {
        self.provider = provider
        self.clientID = clientID
        self.accountID = accountID
    }
    func validate() throws {
        try OAuthCodec.validateClientID(clientID)
        guard OAuthCodec.isText(provider, maximum: 128), OAuthCodec.isText(accountID, maximum: 512) else {
            throw OAuthFailure.invalidConfiguration
        }
    }
    var storageAccount: String {
        // Length-delimited JSON avoids delimiter collisions; hash avoids identity in Keychain metadata.
        let fields = [provider, clientID, accountID]
        let encoded = try! JSONEncoder().encode(fields)
        return OAuthCodec.base64URL(Data(SHA256.hash(data: encoded)))
    }
}

protocol OAuthCredentialVault: Sendable {
    func load(for key: OAuthCredentialKey) async throws -> OAuthToken?
    func save(_ token: OAuthToken, for key: OAuthCredentialKey) async throws
    func delete(for key: OAuthCredentialKey) async throws
}

#if canImport(Security)
/// Distinct from the unrelated private PairCredentialVault. Never writes tokens to UserDefaults.
actor KeychainOAuthCredentialVault: OAuthCredentialVault {
    private let service: String
    init(service: String = "hk.camlink.ios.oauth.v1") { self.service = service }
    private struct Record: Codable {
        let version: Int
        let key: OAuthCredentialKey // Stores accountID together with access/refresh/expiration.
        let token: OAuthToken
    }
    private func query(_ key: OAuthCredentialKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: key.storageAccount,
         kSecAttrSynchronizable as String: false]
    }
    func load(for key: OAuthCredentialKey) async throws -> OAuthToken? {
        try key.validate()
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw OAuthFailure.storage }
        do {
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.version == 1, record.key == key else { throw OAuthFailure.storage }
            try OAuthCodec.validateToken(record.token)
            return record.token
        } catch { throw OAuthFailure.storage }
    }
    func save(_ token: OAuthToken, for key: OAuthCredentialKey) async throws {
        try key.validate()
        try OAuthCodec.validateToken(token)
        let data: Data
        do { data = try JSONEncoder().encode(Record(version: 1, key: key, token: token)) }
        catch { throw OAuthFailure.storage }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw OAuthFailure.storage }
        var item = query(key)
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OAuthFailure.storage }
    }
    func delete(for key: OAuthCredentialKey) async throws {
        try key.validate()
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OAuthFailure.storage }
    }
}
#endif

/// Callback-style bridge is mockable without UIKit. Implementations complete at most once, on MainActor.
@MainActor
protocol OAuthBrowserSession: AnyObject {
    func start(url: URL, callbackScheme: String,
               completion: @escaping @MainActor (Result<URL, OAuthFailure>) -> Void) throws
    func cancel()
}

#if canImport(UIKit)
@MainActor
private final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    let window: UIWindow
    init(window: UIWindow) { self.window = window }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window }
}

@MainActor
final class OAuthSystemBrowserSession: NSObject, OAuthBrowserSession {
    private let anchorProvider: @MainActor () -> UIWindow?
    private let prefersEphemeralWebBrowserSession: Bool
    private var active: ASWebAuthenticationSession?
    private var context: OAuthPresentationContext?
    private var activeID: UUID?
    private var completion: (@MainActor (Result<URL, OAuthFailure>) -> Void)?
    init(prefersEphemeralWebBrowserSession: Bool = false,
         anchorProvider: @escaping @MainActor () -> UIWindow? = {
             UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                 .filter { $0.activationState == .foregroundActive }
                 .flatMap { $0.windows }.first { $0.isKeyWindow && !$0.isHidden }
         }) {
        self.anchorProvider = anchorProvider
        self.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
        super.init()
    }
    func start(url: URL, callbackScheme: String,
               completion: @escaping @MainActor (Result<URL, OAuthFailure>) -> Void) throws {
        guard active == nil else { throw OAuthFailure.busy }
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let registeredSchemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        guard registeredSchemes.contains(callbackScheme) else { throw OAuthFailure.invalidConfiguration }
        guard let window = anchorProvider(), !window.isHidden,
              window.windowScene?.activationState == .foregroundActive else { throw OAuthFailure.browserUnavailable }
        let id = UUID()
        let context = OAuthPresentationContext(window: window)
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] url, error in
            Task { @MainActor in
                guard let self = self, self.activeID == id else { return }
                let result: Result<URL, OAuthFailure>
                if let error = error {
                    let nsError = error as NSError
                    result = .failure(nsError.domain == ASWebAuthenticationSessionError.errorDomain
                        && nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue ? .cancelled : .browserFailed)
                } else if let url = url { result = .success(url) }
                else { result = .failure(.browserFailed) }
                self.finish(id: id, result: result, cancelSession: false)
            }
        }
        session.presentationContextProvider = context
        session.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
        self.context = context // ASWebAuthenticationSession holds its provider weakly.
        self.completion = completion
        activeID = id
        active = session // Retain until completion or explicit cancellation.
        guard session.start() else {
            finish(id: id, result: .failure(.browserFailed), cancelSession: true)
            return
        }
    }
    func cancel() {
        if let id = activeID { finish(id: id, result: .failure(.cancelled), cancelSession: true) }
    }
    private func finish(id: UUID, result: Result<URL, OAuthFailure>, cancelSession: Bool) {
        guard activeID == id else { return }
        let session = active, callback = completion
        activeID = nil
        active = nil
        completion = nil
        if cancelSession { session?.cancel() }
        context = nil
        callback?(result)
    }
}
#endif

@MainActor
final class OAuthCoordinator {
    let vault: any OAuthCredentialVault
    private let browser: any OAuthBrowserSession
    private let http: OAuthHTTPClient
    private let authorizationTimeout: TimeInterval
    private static var globalAuthorizationID: UUID? // Single interactive session across coordinator instances.
    static func reserveExternalInteractiveSession() throws -> UUID {
        guard globalAuthorizationID == nil else { throw OAuthFailure.busy }
        let id = UUID()
        globalAuthorizationID = id
        return id
    }
    static func releaseExternalInteractiveSession(_ id: UUID) {
        if globalAuthorizationID == id { globalAuthorizationID = nil }
    }
    private var authorization: (id: UUID, task: Task<OAuthToken, Error>)?
    private struct BrowserWait {
        let id: UUID
        let continuation: CheckedContinuation<URL, Error>
        let timer: Task<Void, Never>
    }
    private var browserWait: BrowserWait?
    private var refreshTasks: [String: Task<OAuthToken, Error>] = [:]
    private struct CredentialFlight {
        let id: UUID
        let config: OAuthConfiguration
        let task: Task<OAuthToken, Error>
    }
    private struct StoreFlight {
        let id: UUID
        let task: Task<Void, Error>
    }
    private var credentialTasks: [OAuthCredentialKey: CredentialFlight] = [:]
    private var storeTasks: [OAuthCredentialKey: StoreFlight] = [:]
    private var signedOutKeys = Set<OAuthCredentialKey>()
    private var signingOutKeys = Set<OAuthCredentialKey>()

    init(browser: any OAuthBrowserSession, http: OAuthHTTPClient = OAuthHTTPClient(),
         vault: any OAuthCredentialVault, authorizationTimeout: TimeInterval = 90) {
        self.browser = browser
        self.http = http
        self.vault = vault
        self.authorizationTimeout = authorizationTimeout.isFinite ? min(180, max(0.05, authorizationTimeout)) : 90
    }
    #if canImport(UIKit)
    convenience init(http: OAuthHTTPClient = OAuthHTTPClient(),
                     vault: any OAuthCredentialVault = KeychainOAuthCredentialVault(),
                     authorizationTimeout: TimeInterval = 90,
                     anchorProvider: @escaping @MainActor () -> UIWindow? = {
                         UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                             .filter { $0.activationState == .foregroundActive }
                             .flatMap { $0.windows }.first { $0.isKeyWindow && !$0.isHidden }
                     }) {
        self.init(browser: OAuthSystemBrowserSession(anchorProvider: anchorProvider), http: http,
                  vault: vault, authorizationTimeout: authorizationTimeout)
    }
    #endif

    /// Returns a token but does NOT guess accountID or save credentials; provider resolves its account first.
    func authorize(_ config: OAuthConfiguration) async throws -> OAuthToken {
        guard Self.globalAuthorizationID == nil else { throw OAuthFailure.busy }
        let id = UUID()
        Self.globalAuthorizationID = id
        let task = Task { @MainActor in
            let request = try OAuthAuthorizationRequest(config: config)
            let callback = try await self.waitForCallback(id: id, request: request, config: config)
            try Task.checkCancellation()
            let code = try OAuthCodec.authorizationCode(callback: callback, redirectURI: config.redirectURI,
                                                        expectedState: request.state)
            return try await self.http.exchange(config: config,
                body: OAuthCodec.codeExchangeBody(config: config, code: code, pkce: request.pkce))
        }
        authorization = (id, task)
        defer {
            if authorization?.id == id { authorization = nil }
            if Self.globalAuthorizationID == id { Self.globalAuthorizationID = nil }
        }
        do {
            return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: {
                task.cancel()
                Task { @MainActor [weak self] in self?.cancelAuthorization(id: id) }
            })
        } catch { throw OAuthFailure.sanitized(error) }
    }
    func cancelAuthorization() {
        if let id = authorization?.id { cancelAuthorization(id: id) }
    }
    private func cancelAuthorization(id: UUID) {
        guard authorization?.id == id else { return }
        authorization?.task.cancel()
        finishBrowser(id: id, result: .failure(.cancelled), cancelSession: true)
    }
    private func waitForCallback(id: UUID, request: OAuthAuthorizationRequest,
                                 config: OAuthConfiguration) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: OAuthFailure.cancelled); return }
                let nanoseconds = UInt64(authorizationTimeout * 1_000_000_000)
                let timer = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
                    self?.finishBrowser(id: id, result: .failure(.timedOut), cancelSession: true)
                }
                browserWait = BrowserWait(id: id, continuation: continuation, timer: timer)
                do {
                    try browser.start(url: request.url, callbackScheme: config.redirectURI.scheme!) { [weak self] result in
                        self?.finishBrowser(id: id, result: result, cancelSession: false)
                    }
                } catch {
                    finishBrowser(id: id, result: .failure((error as? OAuthFailure) ?? .browserFailed), cancelSession: true)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.finishBrowser(id: id, result: .failure(.cancelled), cancelSession: true) }
        })
    }
    private func finishBrowser(id: UUID, result: Result<URL, OAuthFailure>, cancelSession: Bool) {
        guard let wait = browserWait, wait.id == id else { return }
        browserWait = nil // Clear before cancel callback/reentrant completion; continuation resumes once.
        wait.timer.cancel()
        if cancelSession { browser.cancel() }
        wait.continuation.resume(with: result.mapError { $0 as Error })
    }

    /// Single-flight refresh per configuration+refresh token. Use the returned rotated token thereafter.
    /// Cancelling any waiter cancels this shared exchange; remaining waiters also receive cancellation.
    func refresh(_ config: OAuthConfiguration, token: OAuthToken) async throws -> OAuthToken {
        let body = try OAuthCodec.refreshBody(config: config, token: token)
        let material = Data(config.tokenEndpoint.absoluteString.utf8) + Data([0]) + body
        let id = OAuthCodec.base64URL(Data(SHA256.hash(data: material)))
        if let task = refreshTasks[id] { return try await awaitRefresh(task) }
        let task = Task { try await self.http.exchange(config: config, body: body, previous: token) }
        refreshTasks[id] = task
        defer { refreshTasks[id] = nil }
        return try await awaitRefresh(task)
    }
    private func awaitRefresh(_ task: Task<OAuthToken, Error>) async throws -> OAuthToken {
        do {
            return try await withTaskCancellationHandler(operation: {
                let token = try await task.value
                try Task.checkCancellation()
                return token
            }, onCancel: { task.cancel() })
        } catch { throw OAuthFailure.sanitized(error) }
    }

    /// Provider calls after obtaining a stable identity. Re-sign-in explicitly removes the local tombstone.
    func store(_ token: OAuthToken, for key: OAuthCredentialKey) async throws {
        try key.validate()
        guard !signingOutKeys.contains(key), credentialTasks[key] == nil, storeTasks[key] == nil else {
            throw OAuthFailure.busy
        }
        let id = UUID()
        let task = Task { @MainActor in
            try Task.checkCancellation()
            try await self.vault.save(token, for: key)
            try Task.checkCancellation()
            self.signedOutKeys.remove(key)
        }
        storeTasks[key] = StoreFlight(id: id, task: task)
        defer { if storeTasks[key]?.id == id { storeTasks[key] = nil } }
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        } catch { throw OAuthFailure.sanitized(error) }
    }
    /// Durable account-scoped refresh: serialize load/refresh/rotation/save, including concurrent API callers.
    /// Use one shared coordinator for all provider workers; do not create separate coordinators for one vault key.
    func validToken(for key: OAuthCredentialKey, config: OAuthConfiguration,
                    leeway: TimeInterval = 60) async throws -> OAuthToken {
        try key.validate()
        guard key.clientID == config.clientID else { throw OAuthFailure.invalidConfiguration }
        guard !signedOutKeys.contains(key), !signingOutKeys.contains(key) else { throw OAuthFailure.credentialMissing }
        guard storeTasks[key] == nil else { throw OAuthFailure.busy }
        if let flight = credentialTasks[key] {
            guard flight.config == config else { throw OAuthFailure.invalidConfiguration }
            return try await awaitRefresh(flight.task)
        }
        let id = UUID()
        let task = Task { @MainActor in
            guard let token = try await self.vault.load(for: key) else { throw OAuthFailure.credentialMissing }
            try OAuthCodec.validateToken(token)
            try Task.checkCancellation()
            if token.isUsable(leeway: leeway) { return token }
            let fresh = try await self.refresh(config, token: token)
            try Task.checkCancellation()
            guard !self.signedOutKeys.contains(key) else { throw OAuthFailure.cancelled }
            try await self.vault.save(fresh, for: key)
            try Task.checkCancellation()
            return fresh
        }
        credentialTasks[key] = CredentialFlight(id: id, config: config, task: task)
        defer { if credentialTasks[key]?.id == id { credentialTasks[key] = nil } }
        return try await awaitRefresh(task)
    }
    /// LOCAL sign-out only: cancel interactive work and this account's refresh, then delete only this key.
    /// Does not revoke consent, log the user out of the browser, delete photos/jobs, or change camera state.
    func signOut(_ key: OAuthCredentialKey) async throws {
        try key.validate()
        guard !signingOutKeys.contains(key) else { throw OAuthFailure.busy }
        signingOutKeys.insert(key)
        signedOutKeys.insert(key)
        defer { signingOutKeys.remove(key) }
        cancelAuthorization()
        if let flight = credentialTasks[key] {
            flight.task.cancel()
            _ = await flight.task.result // Ensure a rotated token cannot be saved AFTER deletion.
            if credentialTasks[key]?.id == flight.id { credentialTasks[key] = nil }
        }
        if let flight = storeTasks[key] {
            flight.task.cancel()
            _ = await flight.task.result
            if storeTasks[key]?.id == flight.id { storeTasks[key] = nil }
        }
        try await vault.delete(for: key)
    }
}
