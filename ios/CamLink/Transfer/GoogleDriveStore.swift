import Foundation
import Combine
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(UIKit)
import UIKit
#if canImport(GoogleSignIn)
import GoogleSignIn
#endif
#endif

struct GoogleDriveClientSetup: Codable, Equatable, Sendable {
    var clientID: String
    var redirectURI: String
    init(clientID: String = "", redirectURI: String = "") {
        self.clientID = clientID
        self.redirectURI = redirectURI
    }
    init(settings: OAuthPublicClientSettings) {
        clientID = settings.googleIOSClientID
        redirectURI = (try? settings.googleReversedClientID()).map { $0 + ":/oauth2callback" } ?? ""
    }
    func validate() throws -> String {
        var settings = OAuthPublicClientSettings()
        settings.googleIOSClientID = clientID
        let scheme = try settings.googleReversedClientID()
        guard redirectURI == scheme + ":/oauth2callback" else { throw GoogleDriveFailure.setup }
        return scheme
    }
}

struct GoogleDriveAccount: Codable, Equatable, Sendable {
    let clientID: String
    let sdkUserID: String
    let permissionID: String
    let displayName: String
    let email: String
}
struct GoogleDriveFolder: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
}
enum GoogleDriveJobState: String, Codable, Sendable {
    case pending, uploading, retry, needsSignIn, failed, verified, cancelled
    var label: String {
        switch self {
        case .pending: return "待上傳"
        case .uploading: return "傳送／核對中"
        case .retry: return "等待有限退避重試"
        case .needsSignIn: return "需重新登入"
        case .failed: return "失敗；未核對"
        case .verified: return "Drive 原圖已核對"
        case .cancelled: return "已取消；本機與遠端保留"
        }
    }
}
/// Immutable account/folder/photo binding. No token, upload URL, or PC uploaded flag.
struct GoogleDriveJob: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let clientID: String
    let sdkUserID: String
    let accountID: String
    var folderID: String
    var folderName: String
    let photoID: String
    let name: String
    let albumName: String
    let localRelativePath: String
    let bytes: Int64
    let sha256: String
    let createdAt: Date
    // Immutable admission binding; resolving its album folder never retargets this job.
    var albumParentID: String?
    var albumFolderPending: Bool?
    var md5 = ""
    var remoteID = ""
    var offset: Int64 = 0
    var state = GoogleDriveJobState.pending
    var attempts = 0
    var nextAttemptAt = Date.distantPast
    var error: String?
    var verifiedAt: Date?
    var verification: String?
    var sendSeconds: Double?
    var verifySeconds: Double?
}

struct GoogleDriveAuthorization: Sendable {
    let sdkUserID: String
    let token: OAuthToken
}
@MainActor
protocol GoogleDriveAuthenticating: AnyObject {
    func signIn(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization
    func restore(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization
    func fresh(setup: GoogleDriveClientSetup, expectedUserID: String) async throws -> GoogleDriveAuthorization
    func signOut(setup: GoogleDriveClientSetup, expectedUserID: String?) async throws
    func handle(_ url: URL) -> Bool
}
@MainActor
private final class GoogleDriveUnavailableAuth: GoogleDriveAuthenticating {
    func signIn(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization { throw GoogleDriveFailure.sdk }
    func restore(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization { throw GoogleDriveFailure.sdk }
    func fresh(setup: GoogleDriveClientSetup, expectedUserID: String) async throws -> GoogleDriveAuthorization { throw GoogleDriveFailure.sdk }
    func signOut(setup: GoogleDriveClientSetup, expectedUserID: String?) async throws {}
    func handle(_ url: URL) -> Bool { false }
}

#if canImport(UIKit) && canImport(GoogleSignIn)
/// SDK alone owns Google's refresh token and native OAuth transaction.
@MainActor
final class GoogleDriveSDKAuth: GoogleDriveAuthenticating {
    private let coordinator: OAuthCoordinator
    private let presenter: @MainActor () -> UIViewController?
    private var snapshotKey: OAuthCredentialKey?
    private var generation = UUID()
    private var operation = false
    private var refreshFlight: Task<GoogleDriveAuthorization, Error>?
    init(coordinator: OAuthCoordinator, presenter: @escaping @MainActor () -> UIViewController? = {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap { $0.windows }.first { $0.isKeyWindow }
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }) { self.coordinator = coordinator; self.presenter = presenter }
    private func configure(_ setup: GoogleDriveClientSetup) throws {
        let scheme = try setup.validate()
        let entries = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        guard entries.flatMap({ $0["CFBundleURLSchemes"] as? [String] ?? [] }).contains(scheme) else {
            throw GoogleDriveFailure.setup
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: setup.clientID)
    }
    func signIn(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization {
        try configure(setup)
        guard !operation, refreshFlight == nil else { throw OAuthFailure.busy }
        guard let controller = presenter(), controller.view.window?.windowScene?.activationState == .foregroundActive else {
            throw OAuthFailure.browserUnavailable
        }
        let interactiveID = try OAuthCoordinator.reserveExternalInteractiveSession()
        defer { OAuthCoordinator.releaseExternalInteractiveSession(interactiveID) }
        operation = true
        let epoch = generation
        defer { operation = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller, hint: nil,
                additionalScopes: [GoogleDriveAPI.scope])
            var user = result.user
            if !(user.grantedScopes ?? []).contains(GoogleDriveAPI.scope) {
                user = try await user.addScopes([GoogleDriveAPI.scope], presenting: controller).user
            }
            user = try await user.refreshTokensIfNeeded()
            guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
            return try await snapshot(user, setup: setup)
        } catch { throw GoogleDriveFailure.safeAuth(error) }
    }
    func restore(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization {
        try configure(setup)
        guard !operation, refreshFlight == nil else { throw OAuthFailure.busy }
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { throw GoogleDriveFailure.signIn }
        operation = true
        let epoch = generation
        defer { operation = false }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            guard generation == epoch, !Task.isCancelled else { throw CancellationError() }
            return try await snapshot(user, setup: setup)
        } catch { throw GoogleDriveFailure.safeAuth(error) }
    }
    func fresh(setup: GoogleDriveClientSetup, expectedUserID: String) async throws -> GoogleDriveAuthorization {
        try configure(setup)
        guard !operation else { throw OAuthFailure.busy }
        if let flight = refreshFlight {
            let value = try await flight.value
            guard value.sdkUserID == expectedUserID else { throw GoogleDriveFailure.accountChanged }
            return value
        }
        guard let current = GIDSignIn.sharedInstance.currentUser,
              current.userID == expectedUserID, current.configuration.clientID == setup.clientID else {
            throw GoogleDriveFailure.accountChanged
        }
        let epoch = generation
        let flight = Task { @MainActor in
            do {
                let user = try await current.refreshTokensIfNeeded()
                guard self.generation == epoch, !Task.isCancelled, user.userID == expectedUserID else {
                    throw CancellationError()
                }
                return try await self.snapshot(user, setup: setup)
            } catch { throw GoogleDriveFailure.safeAuth(error) }
        }
        refreshFlight = flight
        defer { refreshFlight = nil }
        return try await withTaskCancellationHandler(operation: { try await flight.value }, onCancel: { flight.cancel() })
    }
    private func snapshot(_ user: GIDGoogleUser, setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization {
        guard user.configuration.clientID == setup.clientID, let id = user.userID,
              OAuthCodec.isText(id, maximum: 512), (user.grantedScopes ?? []).contains(GoogleDriveAPI.scope),
              let expiration = user.accessToken.expirationDate else { throw GoogleDriveFailure.signIn }
        let token = OAuthToken(accessToken: user.accessToken.tokenString, expiresAt: expiration,
                               scope: user.grantedScopes?.joined(separator: " "))
        try OAuthCodec.validateToken(token)
        let key = OAuthCredentialKey(provider: "google-drive", clientID: setup.clientID, accountID: id)
        if let previous = snapshotKey, previous != key { try await coordinator.signOut(previous) }
        try await coordinator.store(token, for: key) // NO duplicate Google refresh token.
        snapshotKey = key
        return GoogleDriveAuthorization(sdkUserID: id, token: token)
    }
    func signOut(setup: GoogleDriveClientSetup, expectedUserID: String?) async throws {
        guard !operation else { throw OAuthFailure.busy } // Let the real SDK sheet finish/cancel first.
        generation = UUID()
        let flight = refreshFlight
        flight?.cancel()
        if let flight = flight { _ = try? await flight.value }
        refreshFlight = nil
        GIDSignIn.sharedInstance.signOut() // Local only, not SDK disconnect/revoke.
        if let expected = expectedUserID {
            try await coordinator.signOut(OAuthCredentialKey(provider: "google-drive", clientID: setup.clientID, accountID: expected))
        }
        if let key = snapshotKey, key.accountID != expectedUserID || key.clientID != setup.clientID { try await coordinator.signOut(key) }
        snapshotKey = nil
    }
    func handle(_ url: URL) -> Bool {
        guard let configuration = GIDSignIn.sharedInstance.configuration else { return false }
        let setup = GoogleDriveClientSetup(settings: OAuthPublicClientSettings(googleIOSClientID: configuration.clientID))
        guard let scheme = try? setup.validate(), url.scheme == scheme,
              url.host == nil, url.path == "/oauth2callback", url.fragment == nil else { return false }
        return GIDSignIn.sharedInstance.handle(url)
    }
}
#endif

/// Resumable URI is a secret capability; store separately from JSON jobs/diagnostics.
protocol GoogleDriveResumeVault: Sendable {
    func load(_ key: String) async throws -> URL?
    func save(_ url: URL, key: String) async throws
    func delete(_ key: String) async throws
}
#if canImport(Security)
actor GoogleDriveKeychainResumeVault: GoogleDriveResumeVault {
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "hk.camlink.ios.google-drive.resume.v1",
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
    func load(_ key: String) async throws -> URL? {
        var item = query(key); item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), let url = URL(string: value) else { throw GoogleDriveFailure.storage }
        try GoogleDriveHTTP.validate(url, uploadOnly: true)
        return url
    }
    func save(_ url: URL, key: String) async throws {
        try GoogleDriveHTTP.validate(url, uploadOnly: true)
        let attrs: [String: Any] = [kSecValueData as String: Data(url.absoluteString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw GoogleDriveFailure.storage }
        var item = query(key); attrs.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw GoogleDriveFailure.storage }
    }
    func delete(_ key: String) async throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleDriveFailure.storage }
    }
}
#endif

struct GoogleDriveReply: Sendable {
    let status: Int
    let data: Data
    let location: URL?
    let range: String?
}
private final class GoogleDriveNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
/// Own raw HTTP boundary because OAuthHTTPClient intentionally rejects 308 and hides Location/Range.
final class GoogleDriveHTTP: @unchecked Sendable {
    private let session: URLSession?
    init(session: URLSession? = nil) { self.session = session }
    private func transport() -> URLSession {
        if let session { return session } // Injected URLProtocol harness only.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        CamLinkNetworkPolicy.apply(to: config, allowsCellular: CamLinkNetworkPolicy.allowsCellular(for: .googleDrive))
        return URLSession(configuration: config)
    }
    static func validate(_ url: URL, uploadOnly: Bool = false) throws {
        try OAuthCodec.validateHTTPS(url, allowedHosts: ["www.googleapis.com"])
        guard url.path.hasPrefix("/upload/drive/v3/files") || (!uploadOnly && url.path.hasPrefix("/drive/v3/")),
              !(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).contains(where: {
                  ["access_token", "refresh_token", "client_secret"].contains($0.name.lowercased())
              }) else { throw GoogleDriveFailure.response }
        if uploadOnly {
            guard url.path == "/upload/drive/v3/files", url.absoluteString.utf8.count <= 8192 else { throw GoogleDriveFailure.response }
        }
    }
    func raw(_ request: URLRequest, token: String, resumable: Bool = false) async throws -> GoogleDriveReply {
        guard let url = request.url, request.value(forHTTPHeaderField: "Authorization") == nil else { throw GoogleDriveFailure.response }
        try Self.validate(url)
        guard OAuthCodec.isBearerValue(token) else { throw GoogleDriveFailure.signIn }
        var outgoing = request
        outgoing.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        outgoing.httpShouldHandleCookies = false; outgoing.timeoutInterval = 30
        outgoing.cachePolicy = .reloadIgnoringLocalCacheData
        CamLinkNetworkPolicy.apply(to: &outgoing, allowsCellular: CamLinkNetworkPolicy.allowsCellular(for: .googleDrive))
        let transport = transport()
        defer { if session == nil { transport.invalidateAndCancel() } }
        do {
            let reply = try await withThrowingTaskGroup(of: GoogleDriveReply.self) { group in
                group.addTask {
                    let (data, response) = try await transport.data(for: outgoing, delegate: GoogleDriveNoRedirect())
                    guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 2 * 1024 * 1024 else {
                        throw GoogleDriveFailure.response
                    }
                    let status = response.statusCode
                    if (300...399).contains(status), !(resumable && status == 308 && response.value(forHTTPHeaderField: "Location") == nil) {
                        throw GoogleDriveFailure.redirect
                    }
                    let location: URL?
                    if let value = response.value(forHTTPHeaderField: "Location") {
                        guard let parsed = URL(string: value) else { throw GoogleDriveFailure.response }
                        try Self.validate(parsed, uploadOnly: true); location = parsed
                    } else { location = nil }
                    let range = response.value(forHTTPHeaderField: "Range")
                    guard range == nil || range!.utf8.count <= 80 else { throw GoogleDriveFailure.response }
                    if !(200...299).contains(status) && !(resumable && status == 308) {
                        throw GoogleDriveFailure.http(status, Self.rateLimited(data))
                    }
                    return GoogleDriveReply(status: status, data: data, location: location, range: range)
                }
                group.addTask { try await Task.sleep(nanoseconds: 40_000_000_000); throw OAuthFailure.timedOut }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw GoogleDriveFailure.response }
                return result
            }
            try Task.checkCancellation()
            return reply
        } catch { throw GoogleDriveFailure.sanitize(error) }
    }
    private static func rateLimited(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any], let errors = error["errors"] as? [[String: Any]] else { return false }
        return errors.contains { ["rateLimitExceeded", "userRateLimitExceeded"].contains($0["reason"] as? String ?? "") }
    }
    func downloadedHash(_ url: URL, token: String, bytes: Int64) async throws -> String {
        try Self.validate(url)
        guard OAuthCodec.isBearerValue(token) else { throw GoogleDriveFailure.signIn }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpShouldHandleCookies = false
        CamLinkNetworkPolicy.apply(to: &request, allowsCellular: CamLinkNetworkPolicy.allowsCellular(for: .googleDrive))
        let transport = transport()
        defer { if session == nil { transport.invalidateAndCancel() } }
        do {
            struct Download: @unchecked Sendable { let file: URL; let response: URLResponse }
            let downloaded = try await withThrowingTaskGroup(of: Download.self) { group in
                group.addTask {
                    let (file, response) = try await transport.download(for: request, delegate: GoogleDriveNoRedirect())
                    return Download(file: file, response: response)
                }
                group.addTask { try await Task.sleep(nanoseconds: 180_000_000_000); throw OAuthFailure.timedOut }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw GoogleDriveFailure.response }
                return result
            }
            let file = downloaded.file; let response = downloaded.response
            defer { try? FileManager.default.removeItem(at: file) } // Only URLSession's own temporary download.
            guard let http = response as? HTTPURLResponse, http.url == url else { throw GoogleDriveFailure.response }
            guard !(300...399).contains(http.statusCode) else { throw GoogleDriveFailure.redirect }
            guard http.statusCode == 200 else { throw GoogleDriveFailure.http(http.statusCode, false) }
            return try await GoogleDriveOriginal.hash(file, expected: bytes, jpeg: false).sha
        } catch { throw GoogleDriveFailure.sanitize(error) }
    }
}

struct GoogleDriveMetadata: Decodable, Sendable {
    let id: String
    let name: String?
    let size: String?
    let mimeType: String?
    let md5Checksum: String?
    let sha256Checksum: String?
    let trashed: Bool?
    let parents: [String]?
    let appProperties: [String: String]?
    let capabilities: Capabilities?
    struct Capabilities: Decodable, Sendable { let canAddChildren: Bool?; let canDownload: Bool? }
}
struct GoogleDriveAPI: Sendable {
    static let scope = "https://www.googleapis.com/auth/drive.file"
    static let folderType = "application/vnd.google-apps.folder"
    static let fields = "id,name,size,mimeType,md5Checksum,sha256Checksum,trashed,parents,appProperties,capabilities(canAddChildren,canDownload)"
    let http: GoogleDriveHTTP
    let token: @MainActor @Sendable () async throws -> String
    func url(_ path: String, _ query: [String: String] = [:], upload: Bool = false) -> URL {
        var parts = URLComponents(string: upload ? "https://www.googleapis.com/upload/drive/v3/" : "https://www.googleapis.com/drive/v3/")!
        parts.percentEncodedPath += path
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return parts.url!
    }
    func json<T: Decodable>(_ type: T.Type, path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: url(path, query))
        if let body = body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        do {
            let response = try await http.raw(request, token: try await token())
            guard response.data.count <= 2 * 1024 * 1024 else { throw GoogleDriveFailure.response }
            return try JSONDecoder().decode(type, from: response.data)
        } catch { throw GoogleDriveFailure.sanitize(error) }
    }
    func profile(clientID: String, sdkID: String) async throws -> GoogleDriveAccount {
        struct About: Decodable { let user: User }
        struct User: Decodable { let permissionId: String; let displayName: String?; let emailAddress: String? }
        let about = try await json(About.self, path: "about", query: ["fields": "user(permissionId,displayName,emailAddress)"])
        guard OAuthCodec.isText(about.user.permissionId, maximum: 512) else { throw GoogleDriveFailure.response }
        return GoogleDriveAccount(clientID: clientID, sdkUserID: sdkID, permissionID: about.user.permissionId,
                                  displayName: about.user.displayName ?? "Google 帳戶", email: about.user.emailAddress ?? "")
    }
    func generateID() async throws -> String {
        struct IDs: Decodable { let ids: [String] }
        let result = try await json(IDs.self, path: "files/generateIds", query: ["count": "1", "space": "drive", "type": "files"])
        guard result.ids.count == 1, GoogleDriveValidation.remoteID(result.ids[0]) else { throw GoogleDriveFailure.response }
        return result.ids[0]
    }
    func metadata(_ id: String) async throws -> GoogleDriveMetadata {
        guard GoogleDriveValidation.remoteID(id) else { throw GoogleDriveFailure.response }
        return try await json(GoogleDriveMetadata.self, path: "files/" + id, query: ["fields": Self.fields, "supportsAllDrives": "true"])
    }
    func checkFolder(_ id: String) async throws -> GoogleDriveFolder {
        let value = try await metadata(id)
        guard value.id == id, value.trashed == false, value.mimeType == Self.folderType,
              value.capabilities?.canAddChildren == true, let name = value.name else { throw GoogleDriveFailure.folder }
        return GoogleDriveFolder(id: id, name: name)
    }
    func folders(parent: String? = nil) async throws -> [GoogleDriveFolder] {
        struct List: Decodable { let files: [GoogleDriveMetadata]; let nextPageToken: String? }
        if let parent = parent, !GoogleDriveValidation.remoteID(parent) { throw GoogleDriveFailure.folder }
        var query = "trashed = false and mimeType = '" + Self.folderType + "'"
        if let parent = parent { query += " and '" + parent + "' in parents" }
        var page: String?; var result: [GoogleDriveFolder] = []; var seen = Set<String>()
        repeat {
            var args = ["q": query, "fields": "nextPageToken,files(id,name,mimeType,trashed,capabilities(canAddChildren))",
                        "pageSize": "100", "orderBy": "name", "spaces": "drive"]
            if let page = page { args["pageToken"] = page }
            let value = try await json(List.self, path: "files", query: args)
            result += value.files.compactMap { file in
                guard GoogleDriveValidation.remoteID(file.id), let name = file.name, file.capabilities?.canAddChildren == true else { return nil }
                return GoogleDriveFolder(id: file.id, name: name)
            }
            page = value.nextPageToken
            if let page = page { guard !page.isEmpty, seen.insert(page).inserted, seen.count <= 100 else { throw GoogleDriveFailure.response } }
        } while page != nil
        return result
    }
    /// Only POST create with a persisted pre-generated ID. 409 never becomes a PATCH.
    func createFolder(id: String, name: String, parent: String?, key: String) async throws -> GoogleDriveFolder {
        guard GoogleDriveValidation.remoteID(id), GoogleDriveValidation.name(name),
              parent == nil || GoogleDriveValidation.remoteID(parent!) else { throw GoogleDriveFailure.folder }
        var body: [String: Any] = ["id": id, "name": name, "mimeType": Self.folderType,
                                  "appProperties": ["camlinkFolder": "1", "camlinkFolderKey": key]]
        if let parent = parent { body["parents"] = [parent] }
        do { _ = try await json(GoogleDriveMetadata.self, path: "files", query: ["fields": Self.fields, "supportsAllDrives": "true"], body: body) }
        catch GoogleDriveFailure.http(409, _) { /* Read back and prove the identity below. */ }
        let value = try await metadata(id)
        guard value.id == id, value.name == name, value.trashed == false, value.mimeType == Self.folderType,
              value.appProperties?["camlinkFolderKey"] == key, value.capabilities?.canAddChildren == true,
              parent == nil || value.parents?.contains(parent!) == true else { throw GoogleDriveFailure.conflict }
        return GoogleDriveFolder(id: id, name: name)
    }
    func begin(_ job: GoogleDriveJob) async throws -> URL {
        var request = URLRequest(url: url("files", ["uploadType": "resumable", "fields": Self.fields, "supportsAllDrives": "true"], upload: true))
        request.httpMethod = "POST"
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("image/jpeg", forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue(String(job.bytes), forHTTPHeaderField: "X-Upload-Content-Length")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["id": job.remoteID, "name": job.name,
            "mimeType": "image/jpeg", "parents": [job.folderID], "appProperties": ["camlinkKey": job.id, "sha256": job.sha256]])
        let response = try await http.raw(request, token: try await token())
        guard [200, 201].contains(response.status), let location = response.location else { throw GoogleDriveFailure.response }
        return location
    }
    func probe(_ location: URL, size: Int64) async throws -> GoogleDriveReply {
        try GoogleDriveHTTP.validate(location, uploadOnly: true)
        var request = URLRequest(url: location); request.httpMethod = "PUT"; request.httpBody = Data()
        request.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        return try await http.raw(request, token: try await token(), resumable: true)
    }
    func chunk(_ location: URL, source: URL, offset: Int64, count: Int, size: Int64) async throws -> GoogleDriveReply {
        try GoogleDriveHTTP.validate(location, uploadOnly: true)
        guard offset >= 0, count > 0, offset + Int64(count) <= size else { throw GoogleDriveFailure.response }
        let read = Task.detached(priority: .utility) { () throws -> Data in
            try Task.checkCancellation()
            let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { throw GoogleDriveFailure.original }
            return data
        }
        let data = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
        var request = URLRequest(url: location); request.httpMethod = "PUT"; request.httpBody = data
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue(String(count), forHTTPHeaderField: "Content-Length")
        request.setValue("bytes \(offset)-\(offset + Int64(count) - 1)/\(size)", forHTTPHeaderField: "Content-Range")
        return try await http.raw(request, token: try await token(), resumable: true)
    }
    static func acknowledged(_ range: String?, size: Int64) throws -> Int64 {
        guard let range = range else { return 0 }
        guard range.hasPrefix("bytes=0-"), range.dropFirst(8).allSatisfy({ $0.isASCII && $0.isNumber }),
              let end = Int64(range.dropFirst(8)), end >= 0, end < size else { throw GoogleDriveFailure.response }
        return end + 1
    }
    func verify(_ job: GoogleDriveJob) async throws -> String {
        let remote = try await metadata(job.remoteID)
        guard remote.id == job.remoteID, remote.trashed == false, remote.size.flatMap(Int64.init) == job.bytes,
              remote.parents?.contains(job.folderID) == true, remote.mimeType == "image/jpeg",
              remote.name == job.name, remote.appProperties?["camlinkKey"] == job.id,
              job.md5.count == 32, GoogleDriveValidation.sha(job.sha256) else { throw GoogleDriveFailure.conflict }
        if let md5 = remote.md5Checksum, !md5.isEmpty, md5.lowercased() != job.md5 { throw GoogleDriveFailure.mismatch }
        if let sha = remote.sha256Checksum, !sha.isEmpty {
            guard sha.lowercased() == job.sha256 else { throw GoogleDriveFailure.mismatch }
            if remote.md5Checksum?.isEmpty == false { return "API 大小、parent、MD5、SHA-256" }
            // Missing MD5 requires a readback, rather than weakening the Android check.
        }
        if remote.md5Checksum?.isEmpty == false, remote.sha256Checksum?.isEmpty != false {
            return "API 大小、parent、MD5（API 未提供 SHA-256）"
        }
        guard remote.capabilities?.canDownload == true else { throw GoogleDriveFailure.mismatch }
        let sha = try await http.downloadedHash(url("files/" + job.remoteID, ["alt": "media", "supportsAllDrives": "true"]),
                                                token: try await token(), bytes: job.bytes)
        guard sha == job.sha256 else { throw GoogleDriveFailure.mismatch }
        return "authenticated GET 全檔大小、SHA-256、parent"
    }
}

struct GoogleDriveHashes: Sendable { let sha: String; let md5: String }
enum GoogleDriveOriginal {
    static func hash(_ source: URL, expected: Int64, jpeg: Bool = true) async throws -> GoogleDriveHashes {
        let task = Task.detached(priority: .utility) { () throws -> GoogleDriveHashes in
            do {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard source.isFileURL, values.isRegularFile == true, values.fileSize.map({ Int64($0) }) == expected else { throw GoogleDriveFailure.original }
                let handle = try FileHandle(forReadingFrom: source); defer { try? handle.close() }
                var sha = SHA256(); var md5 = Insecure.MD5(); var bytes: Int64 = 0
                var first = Data()
                while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
                    try Task.checkCancellation(); bytes += Int64(data.count)
                    guard bytes <= expected else { throw GoogleDriveFailure.original }
                    if first.count < 2 { first.append(data.prefix(2 - first.count)) }
                    sha.update(data: data); md5.update(data: data)
                }
                // These are already-ingested originals. Recheck size + whole-file SHA, not
                // JPEG structure: MPF can legitimately contain bytes after the primary EOI.
                // Never trim, re-encode or require the last two bytes to be FFD9.
                guard bytes == expected, !jpeg || first == Data([0xff, 0xd8]) else { throw GoogleDriveFailure.original }
                return GoogleDriveHashes(sha: GoogleDriveValidation.hex(sha.finalize()), md5: GoogleDriveValidation.hex(md5.finalize()))
            } catch is CancellationError { throw CancellationError() }
            catch { throw GoogleDriveFailure.original }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

/// Used by production and injectable real URLSession tests, not a JSON-only mock uploader.
struct GoogleDriveUploader: Sendable {
    let api: GoogleDriveAPI
    let resumeVault: any GoogleDriveResumeVault
    let chunkSize: Int
    init(api: GoogleDriveAPI, resumeVault: any GoogleDriveResumeVault, chunkSize: Int = 1024 * 1024) throws {
        guard chunkSize >= 256 * 1024, chunkSize <= 8 * 1024 * 1024, chunkSize % (256 * 1024) == 0 else { throw GoogleDriveFailure.response }
        self.api = api; self.resumeVault = resumeVault; self.chunkSize = chunkSize
    }
    func transfer(_ original: GoogleDriveJob, source: URL,
                  checkpoint: @MainActor @Sendable (GoogleDriveJob) async throws -> Void) async throws -> GoogleDriveJob {
        try Task.checkCancellation()
        var job = original
        let hashes = try await GoogleDriveOriginal.hash(source, expected: job.bytes)
        guard hashes.sha == job.sha256 else { throw GoogleDriveFailure.original }
        job.md5 = hashes.md5
        _ = try await api.checkFolder(job.folderID)
        if job.remoteID.isEmpty { job.remoteID = try await api.generateID(); try await checkpoint(job) }
        // An uncertain final reply/crash is resolved by immutable ID + content proof, not a new duplicate.
        do {
            _ = try await api.metadata(job.remoteID)
            let started = Date(); job.verification = try await api.verify(job)
            job.verifySeconds = Date().timeIntervalSince(started); job.offset = job.bytes
            try await resumeVault.delete(job.id)
            return job
        } catch GoogleDriveFailure.http(404, _) { /* Not created yet. */ }
        let started = Date()
        var location = try await resumeVault.load(job.id)
        if let existing = location {
            do {
                let probe = try await api.probe(existing, size: job.bytes)
                if [200, 201].contains(probe.status) { location = nil; job.offset = job.bytes }
                else { job.offset = try GoogleDriveAPI.acknowledged(probe.range, size: job.bytes) }
                try await checkpoint(job)
            } catch GoogleDriveFailure.http(404, _) {
                try await resumeVault.delete(job.id); location = nil; job.offset = 0
            } catch let error as GoogleDriveFailure {
                if case let .http(status, _) = error, (400...499).contains(status), status != 401 {
                    try await resumeVault.delete(job.id)
                }
                throw error
            }
        }
        if location == nil, job.offset < job.bytes { job.offset = 0 }
        if location == nil, job.offset < job.bytes {
            do { location = try await api.begin(job) }
            catch GoogleDriveFailure.http(409, _) {
                job.verification = try await api.verify(job); job.offset = job.bytes
                try await resumeVault.delete(job.id); return job
            }
            try await resumeVault.save(location!, key: job.id)
            job.offset = 0; try await checkpoint(job)
        }
        while job.offset < job.bytes {
            try Task.checkCancellation()
            guard let location = location else { throw GoogleDriveFailure.response }
            let count = Int(min(Int64(chunkSize), job.bytes - job.offset))
            let before = job.offset
            let response: GoogleDriveReply
            do { response = try await api.chunk(location, source: source, offset: before, count: count, size: job.bytes) }
            catch let error as GoogleDriveFailure {
                if case let .http(status, _) = error, (400...499).contains(status), status != 401 {
                    try await resumeVault.delete(job.id)
                }
                throw error
            }
            if [200, 201].contains(response.status) { job.offset = job.bytes }
            else {
                job.offset = try GoogleDriveAPI.acknowledged(response.range, size: job.bytes)
                guard job.offset > before, job.offset <= before + Int64(count) else { throw GoogleDriveFailure.response }
            }
            try await checkpoint(job) // Acknowledged bytes, never presumed sent bytes.
        }
        job.sendSeconds = Date().timeIntervalSince(started)
        // Check source again so a concurrently changed original cannot produce a verified receipt.
        let finalLocal = try await GoogleDriveOriginal.hash(source, expected: job.bytes)
        guard finalLocal.sha == job.sha256, finalLocal.md5 == job.md5 else { throw GoogleDriveFailure.original }
        let verifying = Date()
        job.verification = try await api.verify(job)
        job.verifySeconds = Date().timeIntervalSince(verifying)
        try await resumeVault.delete(job.id)
        return job
    }
}

enum GoogleDriveValidation {
    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
    static func digest(_ fields: [String]) -> String { hex(SHA256.hash(data: try! JSONEncoder().encode(fields))) }
    static func remoteID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 512 && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 } }
    static func name(_ name: String) -> Bool { OAuthCodec.isText(name, maximum: 480) && name.count <= 120 && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") }
    static func relative(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\") && OAuthCodec.isText(path, maximum: 2048)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    static func sha(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func jobID(client: String, sdk: String, account: String, folder: String, photo: String, sha: String, album: String = "") -> String {
        let fields = [client, sdk, account, folder, photo, sha]
        return digest(album.isEmpty ? fields : fields + ["album", album])
    }
}

enum GoogleDriveFailure: Error, LocalizedError, Sendable {
    case setup, sdk, signIn, accountChanged, folder, original, response, redirect, mismatch, conflict, storage
    case http(Int, Bool)
    var errorDescription: String? {
        switch self {
        case .setup: return "Google iOS client ID／完整 callback 與簽署 App URL scheme 不符或未設定；尚未連線。"
        case .sdk: return "此版本未包含官方 GoogleSignIn SDK，不能登入；請安裝已登記的 iOS 簽署版本。"
        case .signIn: return "Google Drive 需登入並授予 drive.file；請檢查同意畫面／測試使用者。"
        case .accountChanged: return "Google 帳戶已變更；舊帳戶佇列保留，沒有轉送到新帳戶。"
        case .folder: return "Drive 資料夾不存在、無新增權限或不在 drive.file 可見範圍；未傳送。"
        case .original: return "本機完整 JPG 不存在、大小／SHA-256 已變更；原圖保留，未核對。"
        case .response: return "Drive 回應或續傳 Range 無效；已停止，未核對。"
        case .redirect: return "已拒絕 HTTP 重新導向；沒有把授權轉送到其他網址。"
        case .mismatch: return "Drive 原圖大小／雜湊不符或無法完整讀回；未核對，沒有覆寫或刪除。"
        case .conflict: return "Drive ID／parent／內容或建立紀錄衝突；未覆寫既有檔案，請檢查目的地。"
        case .storage: return "無法讀寫 Drive 耐久佇列／Keychain；已停止，請保留原圖與佇列並檢查空間。"
        case let .http(status, limited): return "Drive HTTP \(status)" + (limited ? "（流量限制；有限退避）" : "；未核對，請檢查帳戶／權限或稍後重試。")
        }
    }
    var retryable: Bool {
        if case let .http(status, limited) = self { return limited || status == 408 || status == 429 || status >= 500 }
        return false
    }
    static func sanitize(_ error: Error) -> Error {
        if error is GoogleDriveFailure || error is CancellationError { return error }
        if let oauth = error as? OAuthFailure {
            if case let .http(status, _) = oauth { return GoogleDriveFailure.http(status, false) }
            if oauth == .redirectRefused { return GoogleDriveFailure.redirect }
            return oauth
        }
        if error is DecodingError { return GoogleDriveFailure.response }
        return OAuthFailure.sanitized(error)
    }
    static func safeAuth(_ error: Error) -> Error {
        if error is CancellationError || error is GoogleDriveFailure || error is OAuthFailure { return error }
        let ns = error as NSError
        if ns.domain == "com.google.GIDSignIn", ns.code == -5 { return OAuthFailure.cancelled }
        if error is URLError { return OAuthFailure.sanitized(error) }
        return GoogleDriveFailure.signIn
    }
    static func message(_ error: Error) -> String {
        if let own = error as? GoogleDriveFailure { return own.localizedDescription }
        if error is CancellationError { return "上傳已暫停；未核對的佇列與原圖保留。" }
        if let oauth = error as? OAuthFailure {
            switch oauth {
            case .cancelled: return "Google 操作已取消；未核對的項目保留。"
            case .network, .timedOut: return "Drive 網路中斷／逾時；原圖保留，等待重試。"
            case .busy: return "另一個登入／更新操作處理中，請稍後。"
            case .browserUnavailable: return "請在 App 前景登入；找不到有效登入視窗。"
            default: return "Google 授權或安全傳輸失敗；請重新登入，未傳送驗證。"
            }
        }
        return "Drive 操作失敗；未核對，沒有顯示可能包含憑證的原始錯誤。"
    }
}

@MainActor
final class GoogleDriveStore: ObservableObject {
    @Published private(set) var setup: GoogleDriveClientSetup
    @Published private(set) var account: GoogleDriveAccount?
    @Published private(set) var selectedFolder: GoogleDriveFolder?
    @Published private(set) var folders: [GoogleDriveFolder] = []
    @Published private(set) var jobs: [GoogleDriveJob] = []
    @Published private(set) var autoUpload = false
    @Published private(set) var wifiOnly = true
    @Published private(set) var albumSubfolders = true
    @Published private(set) var busy = false
    @Published private(set) var authBusy = false
    @Published private(set) var signedInReady = false
    @Published private(set) var paused = false
    @Published private(set) var message = "Google Drive 尚未登入；自動上傳預設關閉。"
    private struct FolderCreation: Codable {
        let key: String; let clientID: String; let sdkUserID: String; let accountID: String
        let name: String; let parent: String?; let remoteID: String
    }
    private struct Snapshot: Codable {
        let version: Int; let setup: GoogleDriveClientSetup; let account: GoogleDriveAccount?
        let selectedFolder: GoogleDriveFolder?; let autoUpload: Bool; let wifiOnly: Bool; let albumSubfolders: Bool
        let jobs: [GoogleDriveJob]; let creations: [FolderCreation]
        let paused: Bool?
    }
    private let documents: URL
    private let stateURL: URL
    private let auth: any GoogleDriveAuthenticating
    private let http: GoogleDriveHTTP
    private let resumeVault: any GoogleDriveResumeVault
    private var creations: [FolderCreation] = []
    private var storageReady = true
    private var epoch = UUID()
    private var transfer: Task<GoogleDriveJob, Error>?
    private var pumpTask: Task<Void, Never>?
    private var pathAllowed = false
    #if canImport(Network)
    private var monitor: NWPathMonitor?
    #endif

    init(documentsURL: URL, settings: OAuthPublicClientSettings, auth: any GoogleDriveAuthenticating,
         http: GoogleDriveHTTP = GoogleDriveHTTP(), resumeVault: any GoogleDriveResumeVault,
         monitorsNetwork: Bool = true) {
        documents = documentsURL; stateURL = documentsURL.appendingPathComponent("google-drive-jobs-v1.json")
        self.auth = auth; self.http = http; self.resumeVault = resumeVault
        setup = GoogleDriveClientSetup(settings: settings)
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: stateURL))
                guard snapshot.version == 1 else { throw GoogleDriveFailure.storage }
                var known = Set<String>()
                for job in snapshot.jobs {
                    guard known.insert(job.id).inserted, GoogleDriveValidation.relative(job.localRelativePath),
                          GoogleDriveValidation.sha(job.sha256), job.bytes >= 4, job.offset >= 0, job.offset <= job.bytes,
                          GoogleDriveValidation.remoteID(job.folderID), job.remoteID.isEmpty || GoogleDriveValidation.remoteID(job.remoteID),
                          job.id == GoogleDriveValidation.jobID(client: job.clientID, sdk: job.sdkUserID, account: job.accountID,
                                                               folder: job.albumParentID ?? job.folderID, photo: job.photoID, sha: job.sha256,
                                                               album: job.albumParentID == nil ? "" : job.albumName),
                          job.albumParentID == nil || (GoogleDriveValidation.remoteID(job.albumParentID!) && GoogleDriveValidation.name(job.albumName)),
                          job.albumFolderPending != true || job.remoteID.isEmpty,
                          GoogleDriveValidation.name(job.name), job.attempts >= 0,
                          job.md5.isEmpty || (job.md5.count == 32 && job.md5.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
                    else { throw GoogleDriveFailure.storage }
                }
                setup = snapshot.setup; account = snapshot.account; selectedFolder = snapshot.selectedFolder
                autoUpload = snapshot.autoUpload; wifiOnly = snapshot.wifiOnly; albumSubfolders = snapshot.albumSubfolders
                paused = snapshot.paused ?? false
                jobs = snapshot.jobs.map { var job = $0; if job.state == .uploading { job.state = .pending }; return job }
                creations = snapshot.creations
                message = "Drive 本機設定與歷史已載入；登入狀態待 SDK 恢復，未新增遠端寫入。"
            }
        } catch { storageReady = false; autoUpload = false; message = GoogleDriveFailure.storage.localizedDescription }
        #if canImport(Network)
        if monitorsNetwork {
            let monitor = NWPathMonitor(); self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let satisfied = path.status == .satisfied; let wifi = path.usesInterfaceType(.wifi)
                Task { @MainActor in
                    guard let self = self else { return }
                    self.pathAllowed = satisfied && (!self.wifiOnly || wifi)
                    if self.pathAllowed && self.autoUpload && !self.paused && self.signedInReady { self.startPending() }
                    if !self.pathAllowed { self.transfer?.cancel() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "hk.camlink.ios.drive.path"))
        } else { pathAllowed = true } // Deterministic injected-URLSession test harness only.
        #else
        pathAllowed = true
        #endif
    }
    #if canImport(UIKit) && canImport(Security)
    convenience init(coordinator: OAuthCoordinator? = nil, settings: OAuthPublicClientSettings = OAuthAppConfiguration.settings) {
        #if canImport(GoogleSignIn)
        let adapter: any GoogleDriveAuthenticating = GoogleDriveSDKAuth(coordinator: coordinator ?? OAuthCoordinator())
        #else
        let adapter: any GoogleDriveAuthenticating = GoogleDriveUnavailableAuth()
        #endif
        self.init(documentsURL: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
                  settings: settings, auth: adapter, resumeVault: GoogleDriveKeychainResumeVault())
    }
    #endif
    var activeJobs: [GoogleDriveJob] { jobs.filter { $0.clientID == account?.clientID && $0.sdkUserID == account?.sdkUserID && $0.accountID == account?.permissionID } }
    var verifiedCount: Int { activeJobs.filter { $0.state == .verified }.count }
    var pendingCount: Int { activeJobs.filter { [.pending, .uploading, .retry].contains($0.state) }.count }
    var failedCount: Int { activeJobs.filter { [.failed, .needsSignIn].contains($0.state) }.count }
    var oldJobsCount: Int { jobs.count - activeJobs.count }
    func configure(clientID: String, redirectURI: String) async throws {
        guard !busy, !authBusy, storageReady else { throw GoogleDriveFailure.storage }
        let candidate = GoogleDriveClientSetup(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                              redirectURI: redirectURI.trimmingCharacters(in: .whitespacesAndNewlines))
        _ = try candidate.validate()
        if candidate != setup { try await disconnect(); setup = candidate }
        try persist(); message = "公開 iOS client 設定已保存；仍須與簽署 App URL scheme 相符，不是登入測試。"
    }
    func signIn() async {
        guard !authBusy, !busy, storageReady else { return }
        authBusy = true; let generation = epoch; defer { authBusy = false }
        do {
            _ = try setup.validate()
            let authorization = try await auth.signIn(setup: setup)
            let profile = try await accept(authorization, generation: generation)
            if account?.clientID != profile.clientID || account?.sdkUserID != profile.sdkUserID || account?.permissionID != profile.permissionID {
                autoUpload = false; selectedFolder = nil; folders = []
            }
            account = profile; signedInReady = true; try persist()
            message = "已取得真實 Drive 帳戶；請選擇資料夾，登入本身不代表照片已核對。"
        } catch { signedInReady = false; message = GoogleDriveFailure.message(error) }
    }
    func restoreSignIn() async {
        guard !authBusy, !busy, storageReady, account != nil else { return }
        authBusy = true; let generation = epoch; defer { authBusy = false }
        do {
            _ = try setup.validate()
            let authorization = try await auth.restore(setup: setup)
            let profile = try await accept(authorization, generation: generation)
            guard profile.clientID == account?.clientID, profile.sdkUserID == account?.sdkUserID,
                  profile.permissionID == account?.permissionID else { throw GoogleDriveFailure.accountChanged }
            account = profile; signedInReady = true; try persist(); message = "SDK 已恢復此 Drive 帳戶；舊佇列目的地不變。"
            if autoUpload && !paused { startPending() }
        } catch { signedInReady = false; message = GoogleDriveFailure.message(error) }
    }
    private func accept(_ authorization: GoogleDriveAuthorization, generation: UUID) async throws -> GoogleDriveAccount {
        let api = GoogleDriveAPI(http: http, token: { authorization.token.accessToken })
        let profile = try await api.profile(clientID: setup.clientID, sdkID: authorization.sdkUserID)
        guard epoch == generation, !Task.isCancelled else { throw CancellationError() }
        return profile
    }
    private func api(for account: GoogleDriveAccount) -> GoogleDriveAPI {
        GoogleDriveAPI(http: http, token: { [weak self] in
            guard let self = self, self.signedInReady, self.account?.permissionID == account.permissionID,
                  self.account?.sdkUserID == account.sdkUserID, self.setup.clientID == account.clientID else { throw GoogleDriveFailure.accountChanged }
            let generation = self.epoch
            let result = try await self.auth.fresh(setup: self.setup, expectedUserID: account.sdkUserID)
            guard self.epoch == generation, self.signedInReady, result.sdkUserID == account.sdkUserID,
                  self.account?.permissionID == account.permissionID else { throw GoogleDriveFailure.accountChanged }
            return result.token.accessToken
        })
    }
    func browseFolders(parentID: String? = nil) async {
        guard !busy, !authBusy, let account = account else { return }
        authBusy = true; defer { authBusy = false }
        do { folders = try await api(for: account).folders(parent: parentID); message = "只列出 drive.file 可存取且有新增權限的資料夾。" }
        catch { message = GoogleDriveFailure.message(error) }
    }
    func selectFolder(_ folder: GoogleDriveFolder) async {
        guard !busy, !authBusy, let account = account else { return }
        authBusy = true; defer { authBusy = false }
        do { selectedFolder = try await api(for: account).checkFolder(folder.id); try persist(); message = "資料夾已選取；既有佇列目的地不變。" }
        catch { message = GoogleDriveFailure.message(error) }
    }
    func createFolder(name: String, parentID: String? = nil) async {
        guard !busy, !authBusy, let account = account else { return }
        authBusy = true; defer { authBusy = false }
        do {
            selectedFolder = try await boundFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parent: parentID,
                                                    account: account, api: api(for: account))
            try persist(); message = "Drive 資料夾已建立並讀回核對；尚未上傳照片。"
        } catch { message = GoogleDriveFailure.message(error) }
    }
    private func boundFolder(name: String, parent: String?, account: GoogleDriveAccount, api: GoogleDriveAPI) async throws -> GoogleDriveFolder {
        guard GoogleDriveValidation.name(name) else { throw GoogleDriveFailure.folder }
        let key = GoogleDriveValidation.digest([account.clientID, account.sdkUserID, account.permissionID, parent ?? "root", name])
        let creation: FolderCreation
        if let existing = creations.first(where: { $0.key == key }) { creation = existing }
        else {
            creation = FolderCreation(key: key, clientID: account.clientID, sdkUserID: account.sdkUserID,
                accountID: account.permissionID, name: name, parent: parent, remoteID: try await api.generateID())
            creations.append(creation); try persist() // Persist ID BEFORE remote POST.
        }
        return try await api.createFolder(id: creation.remoteID, name: name, parent: parent, key: key)
    }
    func setAutomatic(_ enabled: Bool) {
        guard storageReady else { return }
        autoUpload = enabled && account != nil && selectedFolder != nil
        if autoUpload { paused = false }
        do { try persist(); message = autoUpload ? "自動上傳已啟用；只由父層明確加入新收到的本場照片，不掃描歷史。" : "自動上傳關閉；手動佇列與原圖保留。" }
        catch { message = GoogleDriveFailure.message(error) }
        if autoUpload { startPending() }
    }
    func setWiFiOnly(_ enabled: Bool) {
        wifiOnly = enabled
        #if canImport(Network)
        if let path = monitor?.currentPath { pathAllowed = path.status == .satisfied && (!enabled || path.usesInterfaceType(.wifi)) }
        #endif
        do { try persist() } catch { message = GoogleDriveFailure.message(error) }
        if !pathAllowed { pause() }
        else if autoUpload { startPending() }
    }
    func setAlbumSubfolders(_ enabled: Bool) {
        albumSubfolders = enabled; do { try persist() } catch { message = GoogleDriveFailure.message(error) }
    }
    /// Caller explicitly supplies new photos or a user-confirmed historical album, not all Documents.
    func enqueue(_ photos: [ReceivedJPEG], albumName: String? = nil) async {
        guard storageReady, let account = account, let selected = selectedFolder else {
            message = "請先登入並選擇 Drive 資料夾；未排入。"; return
        }
        do {
            let album = albumName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let subfolder = albumSubfolders && !album.isEmpty
            guard !subfolder || GoogleDriveValidation.name(album) else { throw GoogleDriveFailure.folder }
            // Admission is entirely local and atomic, even during another upload or offline.
            // Dispatch later resolves an immutable account/root/album binding to a remote ID.
            let destination = selected
            let root = documents.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            var added = 0; var unavailable = 0; var known = Set(jobs.map(\.id))
            for photo in photos {
                let file = photo.url.resolvingSymlinksInPath().standardizedFileURL
                guard photo.url.isFileURL, file.path.hasPrefix(root), GoogleDriveValidation.sha(photo.sha256.lowercased()),
                      photo.bytes >= 4, ["jpg", "jpeg"].contains(file.pathExtension.lowercased()), GoogleDriveValidation.name(photo.name),
                      FileManager.default.isReadableFile(atPath: file.path), let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, values.fileSize.map({ Int64($0) }) == photo.bytes else { unavailable += 1; continue }
                let relative = String(file.path.dropFirst(root.count)); guard GoogleDriveValidation.relative(relative) else { unavailable += 1; continue }
                let sha = photo.sha256.lowercased()
                let key = GoogleDriveValidation.jobID(client: account.clientID, sdk: account.sdkUserID, account: account.permissionID,
                                                       folder: destination.id, photo: photo.id, sha: sha, album: subfolder ? album : "")
                guard known.insert(key).inserted else { continue }
                jobs.append(GoogleDriveJob(id: key, clientID: account.clientID, sdkUserID: account.sdkUserID, accountID: account.permissionID,
                    folderID: destination.id, folderName: destination.name, photoID: photo.id, name: photo.name, albumName: album,
                    localRelativePath: relative, bytes: photo.bytes, sha256: sha, createdAt: Date(),
                    albumParentID: subfolder ? destination.id : nil, albumFolderPending: subfolder))
                added += 1
            }
            try persist(); message = "新增 \(added) 張 Drive 待傳原圖，尚未核對；\(unavailable) 張本機資料不符未排入。"
        } catch { message = GoogleDriveFailure.message(error) }
        if autoUpload && !paused && signedInReady { startPending() }
    }
    func startPending() {
        guard pumpTask == nil, signedInReady, !paused else { return }
        pumpTask = Task { [weak self] in
            guard let self = self else { return }
            await self.uploadPending(); self.pumpTask = nil
        }
    }
    func resumePending() {
        paused = false
        do {
            try persist()
            if let previous = pumpTask, previous.isCancelled {
                Task { [weak self] in
                    await previous.value
                    guard let self = self, !self.paused else { return }
                    self.startPending()
                }
            } else { startPending() }
        } catch { message = GoogleDriveFailure.message(error) }
    }
    func pause() {
        paused = true; pumpTask?.cancel(); transfer?.cancel()
        do { try persist(); message = "Drive 已要求暫停；遠端已接收部分保留，可安全探測續傳。" }
        catch { message = GoogleDriveFailure.message(error) }
    }
    /// Convenient async parent hook; automatic dispatch still requires explicit opt-in.
    func pump() async { await uploadPending() }
    func cancelJob(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.state != .verified }) else { return }
        if jobs[index].state == .uploading { transfer?.cancel() }
        jobs[index].state = .cancelled; jobs[index].error = nil
        do { try persist() } catch { message = GoogleDriveFailure.message(error) }
    }
    func retryFailed() {
        for index in jobs.indices where matches(jobs[index]) && [.failed, .needsSignIn, .retry, .cancelled].contains(jobs[index].state) {
            jobs[index].state = .pending; jobs[index].attempts = 0; jobs[index].nextAttemptAt = .distantPast; jobs[index].error = nil
        }
        do { try persist(); message = "此帳戶失敗／取消項目已重新排入；尚未傳送驗證。" }
        catch { message = GoogleDriveFailure.message(error) }
    }
    private func matches(_ job: GoogleDriveJob) -> Bool {
        job.clientID == account?.clientID && job.sdkUserID == account?.sdkUserID && job.accountID == account?.permissionID
    }
    func uploadPending() async {
        guard !busy, !authBusy, storageReady, signedInReady, !paused, let account = account else { return }
        guard pathAllowed else { message = wifiOnly ? "等待可用 Wi-Fi；沒有啟動上傳。" : "等待網路恢復；沒有啟動上傳。"; return }
        busy = true; let generation = epoch; defer { busy = false; transfer = nil }
        let api = api(for: account)
        do {
            let profile = try await api.profile(clientID: account.clientID, sdkID: account.sdkUserID)
            guard profile.permissionID == account.permissionID else { throw GoogleDriveFailure.accountChanged }
        } catch { message = GoogleDriveFailure.message(error); return }
        while !Task.isCancelled, storageReady, epoch == generation, pathAllowed, !paused {
            guard let index = jobs.firstIndex(where: { matches($0) && [.pending, .retry].contains($0.state) && $0.nextAttemptAt <= Date() }) else {
                if let next = activeJobs.filter({ $0.state == .retry }).map(\.nextAttemptAt).min() {
                    let seconds = min(120, max(0.1, next.timeIntervalSinceNow))
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { break }
                    continue
                }
                break
            }
            jobs[index].state = .uploading; jobs[index].attempts += 1; jobs[index].error = nil
            do { try persist() } catch { message = GoogleDriveFailure.message(error); break }
            let job = jobs[index]
            let source = documents.appendingPathComponent(job.localRelativePath).resolvingSymlinksInPath().standardizedFileURL
            guard source.path.hasPrefix(documents.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                jobs[index].state = .failed; jobs[index].error = GoogleDriveFailure.original.localizedDescription
                do { try persist() } catch { message = GoogleDriveFailure.message(error) }; break
            }
            message = "Drive 傳送完整 JPG；200／201 後仍須核對遠端大小與雜湊。"
            let task = Task { () throws -> GoogleDriveJob in
                let uploader = try GoogleDriveUploader(api: api, resumeVault: self.resumeVault)
                var resolved = job
                if resolved.albumFolderPending == true, let parent = resolved.albumParentID {
                    _ = try await api.checkFolder(parent)
                    let folder = try await self.boundFolder(name: resolved.albumName, parent: parent, account: account, api: api)
                    try Task.checkCancellation()
                    guard self.epoch == generation, !self.paused,
                          let current = self.jobs.firstIndex(where: { $0.id == resolved.id }), self.jobs[current].state != .cancelled else { throw CancellationError() }
                    resolved.folderID = folder.id; resolved.folderName = folder.name; resolved.albumFolderPending = false
                    self.jobs[current] = resolved; try self.persist()
                }
                return try await uploader.transfer(resolved, source: source) { [weak self] updated in
                    guard let self = self, self.epoch == generation,
                          !self.paused, let index = self.jobs.firstIndex(where: { $0.id == updated.id }), self.jobs[index].state != .cancelled else { throw CancellationError() }
                    self.jobs[index] = updated; try self.persist()
                }
            }
            transfer = task
            do {
                var result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                guard epoch == generation, let current = jobs.firstIndex(where: { $0.id == job.id }), jobs[current].state != .cancelled,
                      !Task.isCancelled else { throw CancellationError() }
                result.state = .verified; result.verifiedAt = Date(); result.error = nil; jobs[current] = result
                try persist(); message = "Drive 已核對原图：" + (result.verification ?? "")
            } catch {
                if let current = jobs.firstIndex(where: { $0.id == job.id }), jobs[current].state != .cancelled {
                    let safe = GoogleDriveFailure.sanitize(error)
                    let cancelled = task.isCancelled || Task.isCancelled || safe is CancellationError || (safe as? OAuthFailure) == .cancelled
                    let authRequired: Bool
                    switch safe {
                    case GoogleDriveFailure.signIn, GoogleDriveFailure.accountChanged,
                         OAuthFailure.interactionRequired, OAuthFailure.credentialMissing: authRequired = true
                    default: authRequired = false
                    }
                    let httpFailure = safe as? GoogleDriveFailure
                    let retryable = httpFailure?.retryable == true || (safe as? OAuthFailure) == .network || (safe as? OAuthFailure) == .timedOut
                    let statusAuth: Bool
                    if case let .http(status, _)? = httpFailure { statusAuth = status == 401 } else { statusAuth = false }
                    jobs[current].state = cancelled ? .pending : (authRequired || statusAuth ? .needsSignIn : (retryable && jobs[current].attempts < 5 ? .retry : .failed))
                    jobs[current].error = cancelled ? nil : GoogleDriveFailure.message(safe)
                    if jobs[current].state == .retry { jobs[current].nextAttemptAt = Date().addingTimeInterval(min(120, pow(2, Double(jobs[current].attempts)) + Double.random(in: 0...1))) }
                    do { try persist() } catch { message = GoogleDriveFailure.message(error); break }
                    message = GoogleDriveFailure.message(safe)
                    if cancelled || jobs[current].state != .retry { break }
                } else { break }
            }
            transfer = nil
        }
    }
    /// Explicit local sign-out. No consent revocation, no remote/photo/other-provider deletion.
    func disconnect() async throws {
        guard !authBusy else { throw OAuthFailure.busy }
        epoch = UUID(); pause()
        if let transfer = transfer { _ = try? await transfer.value }
        try await auth.signOut(setup: setup, expectedUserID: account?.sdkUserID)
        account = nil; selectedFolder = nil; folders = []; autoUpload = false; signedInReady = false
        try persist(); message = "Drive 本機連線已清除；所有原圖、歴史佇列及遠端檔案保留。"
    }
    func diagnosticsJSON() throws -> Data {
        struct Row: Encodable {
            let photoID: String; let album: String; let state: String; let bytes: Int64; let sha256: String
            let remoteID: String; let attempts: Int; let offset: Int64; let error: String?; let verification: String?
            let sendSeconds: Double?; let verifySeconds: Double?
        }
        let rows = jobs.map { Row(photoID: $0.photoID, album: $0.albumName, state: $0.state.rawValue, bytes: $0.bytes,
            sha256: $0.sha256, remoteID: $0.remoteID, attempts: $0.attempts, offset: $0.offset, error: $0.error,
            verification: $0.verification, sendSeconds: $0.sendSeconds, verifySeconds: $0.verifySeconds) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(rows) // No account email, local path, token or resumable URI.
    }
    func handleCallback(_ url: URL) -> Bool { auth.handle(url) }
    private func persist() throws {
        guard storageReady else { throw GoogleDriveFailure.storage }
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            let snapshot = Snapshot(version: 1, setup: setup, account: account, selectedFolder: selectedFolder,
                autoUpload: autoUpload, wifiOnly: wifiOnly, albumSubfolders: albumSubfolders, jobs: jobs, creations: creations, paused: paused)
            try JSONEncoder().encode(snapshot).write(to: stateURL, options: .atomic)
            #if canImport(UIKit)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stateURL.path)
            #endif
        } catch { storageReady = false; autoUpload = false; transfer?.cancel(); throw GoogleDriveFailure.storage }
    }
}
#if canImport(Network)
import Network
#endif
