import Foundation
import Combine
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Network)
import Network
#endif

// OneDrive-only implementation. Never writes a camera or ReceivedJPEG.uploaded.
struct OneDriveClientSetup: Codable, Equatable, Sendable {
    var clientID: String
    var redirectURI: String
    var tenant: String
    init(clientID: String = "", redirectURI: String = "msauth.hk.camlink.ios://auth", tenant: String = "common") {
        self.clientID = clientID; self.redirectURI = redirectURI; self.tenant = tenant
    }
    init(settings: OAuthPublicClientSettings) {
        self.init(clientID: settings.microsoftClientID, redirectURI: settings.microsoftRedirectURI)
    }
    func configuration() throws -> OAuthConfiguration {
        guard UUID(uuidString: clientID) != nil,
              tenant == "common" || UUID(uuidString: tenant) != nil,
              let redirect = URL(string: redirectURI) else { throw OneDriveFailure.setup }
        return try OAuthConfiguration(clientID: clientID,
            authorizationEndpoint: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!,
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!,
            redirectURI: redirect, scopes: ["openid", "profile", "offline_access", "User.Read", "Files.ReadWrite"],
            extraAuthorizationParameters: ["prompt": "select_account"])
    }
}
struct OneDriveAccount: Codable, Equatable, Sendable {
    let setup: OneDriveClientSetup
    let id: String
    let displayName: String
    let email: String
    let driveID: String
    let driveName: String
    let rootID: String
    var credentialKey: OAuthCredentialKey {
        OAuthCredentialKey(provider: "microsoft-onedrive", clientID: setup.clientID, accountID: id)
    }
}
struct OneDriveFolder: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let driveID: String
}
enum OneDriveJobState: String, Codable, Sendable {
    case pending, uploading, retry, needsSignIn, failed, verified, cancelled
    var label: String {
        switch self {
        case .pending: return "待傳"
        case .uploading: return "傳送／核對中"
        case .retry: return "等待有限退避重試"
        case .needsSignIn: return "需要重新登入"
        case .failed: return "失敗；未核對"
        case .verified: return "OneDrive 原圖已核對"
        case .cancelled: return "已取消；原圖保留"
        }
    }
}
/// Immutable binding. A receipt never implies Google/PC/WebDAV delivery.
struct OneDriveJob: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let setup: OneDriveClientSetup
    let accountID: String
    let driveID: String
    let folderID: String
    let folderName: String
    let photoID: String
    let originalName: String
    let remoteName: String
    let albumName: String
    let localRelativePath: String
    let bytes: Int64
    let sha256: String
    let createdAt: Date
    var offset: Int64 = 0
    var state: OneDriveJobState = .pending
    var attempts = 0
    var nextAttemptAt = Date.distantPast
    var error: String?
    var remoteID = ""
    var verifiedAt: Date?
    var verification: String?
}
struct OneDriveReceipt: Equatable, Sendable {
    let jobID: String
    let photoID: String
    let accountID: String
    let driveID: String
    let folderID: String
    let remoteID: String
    let bytes: Int64
    let sha256: String
    let verifiedAt: Date
    let method: String
}
enum OneDriveFailure: Error, LocalizedError, Sendable {
    case setup, signIn, busy, storage, source, response, unsafeURL, conflict, integrity, cancelled, network, timeout, sessionExpired
    case http(Int, retryAfter: Int?)
    case oauth(OAuthFailure)
    var errorDescription: String? {
        switch self {
        case .setup: return "Microsoft 公開 client ID／精確回呼或 tenant 設定不正確。"
        case .signIn: return "請重新登入本工作的 Microsoft 帳戶；不會改送其他帳戶。"
        case .busy: return "OneDrive 正在處理其他設定操作。"
        case .storage: return "OneDrive 本機佇列或金鑰鏈無法安全保存；已停止傳送。"
        case .source: return "完整本機原圖遺失、大小或 SHA-256 不符；不會傳送變更的檔案。"
        case .response: return "OneDrive 回應或續傳範圍無效。"
        case .unsafeURL: return "拒絕非受信 HTTPS 主機或重新導向；未轉送憑證。"
        case .conflict: return "遠端同名檔案不是本原圖；保留原檔且不覆寫。"
        case .integrity: return "遠端原圖大小、雜湊或目的地不符；未列為已核對。"
        case .cancelled: return "已暫停／取消；本機與已存在遠端原圖保留。"
        case .network: return "OneDrive 網路傳送未完成。"
        case .timeout: return "OneDrive 網路要求逾時。"
        case .sessionExpired: return "OneDrive 續傳已過期；將先查找已完成原圖，再安全重建工作階段。"
        case let .http(status, _): return "OneDrive HTTP \(status)；未列為已核對。"
        case let .oauth(failure): return "Microsoft 登入需要處理：\(failure.localizedDescription)"
        }
    }
    static func safe(_ error: Error) -> OneDriveFailure {
        if let value = error as? OneDriveFailure { return value }
        if error is CancellationError { return .cancelled }
        if let value = error as? OAuthFailure { return .oauth(value) }
        if let value = error as? URLError {
            if value.code == .cancelled { return .cancelled }
            if value.code == .timedOut { return .timeout }
        }
        return .network // Never expose URL, server payload, NSError userInfo, or signed capability.
    }
    var retryable: Bool {
        switch self {
        case .network, .timeout, .sessionExpired: return true
        case let .http(status, _): return status == 408 || status == 429 || (500...599).contains(status)
        case let .oauth(value): return value == .network || value == .timedOut
        default: return false
        }
    }
    var requiresSignIn: Bool {
        switch self {
        case .signIn: return true
        case let .http(status, _): return status == 401
        case let .oauth(value):
            switch value {
            case .credentialMissing, .interactionRequired: return true
            case .http(status: 400, code: .invalidGrant), .http(status: 401, code: _): return true
            default: return false
            }
        default: return false
        }
    }
}
struct OneDriveOriginal: Equatable, Sendable {
    let bytes: Int64
    let sha256: String
    let sha1: String
    static func hex<D: Sequence>(_ value: D) -> String where D.Element == UInt8 {
        value.map { String(format: "%02x", $0) }.joined()
    }
    /// Reads EVERY byte, including appended MPF images. No JPEG truncation/re-encoding/FFD9 tail rule.
    static func inspect(_ url: URL) throws -> OneDriveOriginal {
        guard url.isFileURL else { throw OneDriveFailure.source }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var sha = SHA256(), sha1 = Insecure.SHA1(), size: Int64 = 0
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                if Task.isCancelled { throw OneDriveFailure.cancelled }
                sha.update(data: chunk); sha1.update(data: chunk); size += Int64(chunk.count)
            }
            guard size > 0 else { throw OneDriveFailure.source }
            return OneDriveOriginal(bytes: size, sha256: hex(sha.finalize()), sha1: hex(sha1.finalize()))
        } catch { throw error is OneDriveFailure ? error : OneDriveFailure.source }
    }
    static func hashMatches(_ remote: String, hex: String) -> Bool {
        if remote.count == hex.count, remote.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            return remote.lowercased() == hex.lowercased()
        }
        guard let raw = Data(base64Encoded: remote), raw.count * 2 == hex.count else { return false }
        return Self.hex(raw) == hex.lowercased()
    }
}
struct OneDriveHTTPReply: Sendable {
    let status: Int
    let data: Data
    let retryAfter: Int?
    init(status: Int, data: Data, retryAfter: Int? = nil) {
        self.status = status; self.data = data; self.retryAfter = retryAfter
    }
}
protocol OneDriveHTTPTransport: Sendable {
    func send(_ request: URLRequest, bearer: String?) async throws -> OneDriveHTTPReply
    /// Must download without credentials and hash the private whole-file temporary copy.
    func download(_ url: URL, expectedBytes: Int64, allowsCellular: Bool) async throws -> OneDriveOriginal
}
enum OneDriveURLPolicy {
    static func graph(_ url: URL) throws {
        try OAuthCodec.validateHTTPS(url, allowedHosts: ["graph.microsoft.com"])
        guard url.path.hasPrefix("/v1.0/"), url.pathComponents.allSatisfy({ $0 != ".." }) else { throw OneDriveFailure.unsafeURL }
    }
    static func capability(_ url: URL) throws {
        do { try OAuthCodec.validateHTTPS(url) } catch { throw OneDriveFailure.unsafeURL }
        let host = url.host!.lowercased()
        let suffixes = [".1drv.com", ".sharepoint.com", ".microsoftpersonalcontent.com", ".svc.ms"]
        guard host == "api.onedrive.com" || suffixes.contains(where: { host.hasSuffix($0) && host.count > $0.count }) else {
            throw OneDriveFailure.unsafeURL
        }
    }
}
private final class OneDriveTaskDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    init(maximumBytes: Int64 = 2 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
final class OneDriveURLSessionTransport: OneDriveHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let deadline: TimeInterval
    init(session: URLSession? = nil, deadline: TimeInterval = 90) {
        if let session = session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
            config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 90
            CamLinkNetworkPolicy.configureSessionCeiling(config)
            self.session = URLSession(configuration: config)
        }
        self.deadline = deadline.isFinite ? min(180, max(0.05, deadline)) : 90
    }
    private struct DataReply: @unchecked Sendable { let data: Data; let response: URLResponse }
    private struct FileReply: @unchecked Sendable { let url: URL; let response: URLResponse }
    func send(_ request: URLRequest, bearer: String?) async throws -> OneDriveHTTPReply {
        guard let url = request.url, request.value(forHTTPHeaderField: "Authorization") == nil else { throw OneDriveFailure.unsafeURL }
        var outgoing = request
        if let bearer = bearer {
            try OneDriveURLPolicy.graph(url)
            guard OAuthCodec.isBearerValue(bearer) else { throw OneDriveFailure.signIn }
            outgoing.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        } else { try OneDriveURLPolicy.capability(url) }
        outgoing.httpShouldHandleCookies = false; outgoing.cachePolicy = .reloadIgnoringLocalCacheData
        outgoing.timeoutInterval = deadline
        CamLinkNetworkPolicy.apply(to: &outgoing, allowsCellular: request.allowsCellularAccess)
        do {
            let result = try await withThrowingTaskGroup(of: DataReply.self) { group in
                group.addTask {
                    let (data, response) = try await self.session.data(for: outgoing, delegate: OneDriveTaskDelegate())
                    return DataReply(data: data, response: response)
                }
                group.addTask { try await Task.sleep(nanoseconds: UInt64(self.deadline * 1_000_000_000)); throw OneDriveFailure.timeout }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw OneDriveFailure.network }; return first
            }
            try Task.checkCancellation()
            guard let response = result.response as? HTTPURLResponse,
                  response.url?.absoluteString == url.absoluteString,
                  !(300...399).contains(response.statusCode) else { throw OneDriveFailure.unsafeURL }
            guard result.data.count <= 2 * 1024 * 1024 else { throw OneDriveFailure.response }
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }.map { min(3600, max(0, $0)) }
            return OneDriveHTTPReply(status: response.statusCode, data: result.data, retryAfter: retry)
        } catch { throw OneDriveFailure.safe(error) }
    }
    func download(_ url: URL, expectedBytes: Int64, allowsCellular: Bool) async throws -> OneDriveOriginal {
        try OneDriveURLPolicy.capability(url)
        guard expectedBytes > 0 else { throw OneDriveFailure.integrity }
        var request = URLRequest(url: url); request.allowsCellularAccess = allowsCellular
        request.httpShouldHandleCookies = false; request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = deadline // No Authorization header or credential storage.
        CamLinkNetworkPolicy.apply(to: &request, allowsCellular: allowsCellular)
        var ownedTemporaryDirectory: URL?
        defer { if let directory = ownedTemporaryDirectory { try? FileManager.default.removeItem(at: directory) } }
        do {
            let result = try await withThrowingTaskGroup(of: FileReply.self) { group in
                group.addTask {
                    let (file, response) = try await self.session.download(for: request,
                        delegate: OneDriveTaskDelegate(maximumBytes: expectedBytes))
                    return FileReply(url: file, response: response)
                }
                group.addTask { try await Task.sleep(nanoseconds: UInt64(self.deadline * 1_000_000_000)); throw OneDriveFailure.timeout }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw OneDriveFailure.network }; return first
            }
            defer { try? FileManager.default.removeItem(at: result.url) } // Only our URLSession temporary download.
            try Task.checkCancellation()
            guard let response = result.response as? HTTPURLResponse,
                  response.url?.absoluteString == url.absoluteString,
                  !(300...399).contains(response.statusCode) else { throw OneDriveFailure.unsafeURL }
            guard response.statusCode == 200 else { throw OneDriveFailure.http(response.statusCode, retryAfter: nil) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CamLink-OneDrive-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            ownedTemporaryDirectory = directory
            let file = directory.appendingPathComponent("verification.bin")
            try FileManager.default.moveItem(at: result.url, to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let original = try OneDriveOriginal.inspect(file)
            guard original.bytes == expectedBytes else { throw OneDriveFailure.integrity }
            return original
        } catch { throw OneDriveFailure.safe(error) }
    }
}

/// Secret capability is persisted ONLY in an isolated Keychain namespace, never JSON/jobs/logs.
struct OneDriveUploadCapability: Codable, Equatable, Sendable {
    let url: URL
    let expiresAt: Date
}
protocol OneDriveSessionVault: Sendable {
    func load(_ jobID: String) async throws -> OneDriveUploadCapability?
    func save(_ value: OneDriveUploadCapability, jobID: String) async throws
    func delete(_ jobID: String) async throws
}
#if canImport(Security)
actor KeychainOneDriveSessionVault: OneDriveSessionVault {
    private let service: String
    init(service: String = "hk.camlink.ios.onedrive.upload.v1") { self.service = service }
    private func query(_ id: String) throws -> [String: Any] {
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw OneDriveFailure.storage }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }
    func load(_ jobID: String) async throws -> OneDriveUploadCapability? {
        var q = try query(jobID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(OneDriveUploadCapability.self, from: data) else { throw OneDriveFailure.storage }
        try OneDriveURLPolicy.capability(value.url); return value
    }
    func save(_ value: OneDriveUploadCapability, jobID: String) async throws {
        try OneDriveURLPolicy.capability(value.url)
        let data = try JSONEncoder().encode(value)
        let q = try query(jobID)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw OneDriveFailure.storage }
        var item = q; attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OneDriveFailure.storage }
    }
    func delete(_ jobID: String) async throws {
        let status = SecItemDelete(try query(jobID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OneDriveFailure.storage }
    }
}
#endif
struct OneDriveRemoteItem: Decodable, Sendable {
    let id: String
    let name: String
    let size: Int64?
    let eTag: String?
    let parentReference: Parent?
    let file: FileFacet?
    let folder: FolderFacet?
    let downloadURL: String?
    struct Parent: Decodable, Sendable { let id: String?; let driveId: String? }
    struct FileFacet: Decodable, Sendable { let hashes: Hashes? }
    struct Hashes: Decodable, Sendable { let sha1Hash: String?; let sha256Hash: String?; let quickXorHash: String? }
    struct FolderFacet: Decodable, Sendable { let childCount: Int? }
    enum CodingKeys: String, CodingKey {
        case id, name, size, eTag, parentReference, file, folder
        case downloadURL = "@microsoft.graph.downloadUrl"
    }
}
struct OneDriveUploadCheckpoint: Sendable {
    let capability: OneDriveUploadCapability?
    let offset: Int64
}
struct OneDriveUploadResult: Sendable { let remoteID: String; let method: String }
struct OneDriveMissingRange: Equatable, Sendable { let start: Int64; let end: Int64 }

final class OneDriveGraphAPI: @unchecked Sendable {
    static let chunkBytes: Int64 = 10 * 320 * 1024 // 3.125 MiB; aligned and < 60 MiB.
    private let transport: any OneDriveHTTPTransport
    private let token: @Sendable () async throws -> String
    private let allowsCellular: Bool
    init(transport: any OneDriveHTTPTransport, allowsCellular: Bool = true,
         token: @escaping @Sendable () async throws -> String) {
        self.transport = transport; self.token = token; self.allowsCellular = allowsCellular
    }
    static func encoded(_ value: String) throws -> String {
        guard OAuthCodec.isText(value, maximum: 1024), value != ".", value != "..", !value.contains("/") else { throw OneDriveFailure.response }
        return OAuthCodec.percentEncode(value)
    }
    static func folderName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(name.count), !name.hasSuffix("."), !name.hasSuffix(" "),
              !name.contains(where: { "\"*:<>?/\\|".contains($0) }),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name != ".", name != "..", !name.hasPrefix("~") else { throw OneDriveFailure.response }
        return name
    }
    static func identity(_ fields: [String]) -> String {
        OneDriveOriginal.hex(SHA256.hash(data: (try! JSONEncoder().encode(fields))))
    }
    static func remoteName(original: String, photoID: String, sha256: String) -> String {
        let stem = (original as NSString).deletingPathExtension.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : "_" }.joined()
        return "\(stem.prefix(40).isEmpty ? "photo" : String(stem.prefix(40)))--\(sha256)-\(identity([photoID]).prefix(24)).jpg"
    }
    private func graph(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> OneDriveHTTPReply {
        guard let url = URL(string: "https://graph.microsoft.com/v1.0/" + path) else { throw OneDriveFailure.response }
        return try await graphURL(url, method: method, body: body)
    }
    private func graphURL(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> OneDriveHTTPReply {
        try OneDriveURLPolicy.graph(url)
        var request = URLRequest(url: url); request.httpMethod = method; request.allowsCellularAccess = allowsCellular
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let accessToken = try await token()
        let reply = try await transport.send(request, bearer: accessToken)
        guard (200...299).contains(reply.status) else { throw OneDriveFailure.http(reply.status, retryAfter: reply.retryAfter) }
        return reply
    }
    private func capability(_ value: OneDriveUploadCapability, method: String, data: Data? = nil, range: String? = nil) async throws -> OneDriveHTTPReply {
        try OneDriveURLPolicy.capability(value.url)
        var request = URLRequest(url: value.url); request.httpMethod = method; request.allowsCellularAccess = allowsCellular
        request.httpBody = data
        if let data = data {
            request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        if let range = range { request.setValue(range, forHTTPHeaderField: "Content-Range") }
        return try await transport.send(request, bearer: nil)
    }
    private static let selection = "?$select=id,name,size,eTag,parentReference,file,folder,@microsoft.graph.downloadUrl"
    func account(setup: OneDriveClientSetup) async throws -> OneDriveAccount {
        struct User: Decodable { let id: String; let displayName: String?; let mail: String?; let userPrincipalName: String? }
        struct Drive: Decodable { let id: String; let name: String? }
        let user = try JSONDecoder().decode(User.self, from: try await graph("me?$select=id,displayName,mail,userPrincipalName").data)
        let drive = try JSONDecoder().decode(Drive.self, from: try await graph("me/drive?$select=id,name").data)
        let root = try JSONDecoder().decode(OneDriveRemoteItem.self, from: try await graph("drives/\(Self.encoded(drive.id))/root" + Self.selection).data)
        guard OAuthCodec.isText(user.id, maximum: 512), root.folder != nil else { throw OneDriveFailure.response }
        return OneDriveAccount(setup: setup, id: user.id, displayName: user.displayName ?? "Microsoft",
            email: user.mail ?? user.userPrincipalName ?? "", driveID: drive.id, driveName: drive.name ?? "OneDrive", rootID: root.id)
    }
    func folders(driveID: String, parentID: String) async throws -> [OneDriveFolder] {
        struct Page: Decodable {
            let value: [OneDriveRemoteItem]
            let next: String?
            enum CodingKeys: String, CodingKey { case value; case next = "@odata.nextLink" }
        }
        let base = "drives/\(try Self.encoded(driveID))/items/\(try Self.encoded(parentID))/children"
        var url = URL(string: "https://graph.microsoft.com/v1.0/" + base + "?$select=id,name,folder&$top=200")!
        var seen = Set<String>(), output: [OneDriveFolder] = []
        for _ in 0..<100 {
            guard seen.insert(url.absoluteString).inserted, url.path == "/v1.0/" + base else { throw OneDriveFailure.response }
            let page = try JSONDecoder().decode(Page.self, from: try await graphURL(url).data)
            output += page.value.filter { $0.folder != nil }.map { OneDriveFolder(id: $0.id, name: $0.name, driveID: driveID) }
            guard let next = page.next else { return output.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
            guard let nextURL = URL(string: next) else { throw OneDriveFailure.response }
            try OneDriveURLPolicy.graph(nextURL); url = nextURL
        }
        throw OneDriveFailure.response // Bound malicious/unbounded pagination; never pretend truncated complete.
    }
    func item(driveID: String, id: String) async throws -> OneDriveRemoteItem {
        try JSONDecoder().decode(OneDriveRemoteItem.self, from: try await graph("drives/\(Self.encoded(driveID))/items/\(Self.encoded(id))" + Self.selection).data)
    }
    func lookup(driveID: String, folderID: String, name: String) async throws -> OneDriveRemoteItem? {
        do {
            let path = "drives/\(try Self.encoded(driveID))/items/\(try Self.encoded(folderID)):/\(try Self.encoded(name))" + Self.selection
            return try JSONDecoder().decode(OneDriveRemoteItem.self, from: try await graph(path).data)
        } catch OneDriveFailure.http(404, _) { return nil }
    }
    func ensureFolder(driveID: String, parentID: String, name: String) async throws -> OneDriveFolder {
        let name = try Self.folderName(name)
        if let existing = try await lookup(driveID: driveID, folderID: parentID, name: name) {
            guard existing.folder != nil, existing.name == name else { throw OneDriveFailure.conflict }
            return OneDriveFolder(id: existing.id, name: existing.name, driveID: driveID)
        }
        do {
            let reply = try await graph("drives/\(Self.encoded(driveID))/items/\(Self.encoded(parentID))/children", method: "POST",
                body: ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "fail"])
            let item = try JSONDecoder().decode(OneDriveRemoteItem.self, from: reply.data)
            guard item.folder != nil, item.name == name else { throw OneDriveFailure.response }
            return OneDriveFolder(id: item.id, name: name, driveID: driveID)
        } catch OneDriveFailure.http(409, _) {
            guard let existing = try await lookup(driveID: driveID, folderID: parentID, name: name),
                  existing.folder != nil, existing.name == name else { throw OneDriveFailure.conflict }
            return OneDriveFolder(id: existing.id, name: name, driveID: driveID)
        }
    }
    static func ranges(_ data: Data, total: Int64) throws -> [OneDriveMissingRange] {
        struct Wire: Decodable { let nextExpectedRanges: [String] }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard !wire.nextExpectedRanges.isEmpty, wire.nextExpectedRanges.count <= 1000 else { throw OneDriveFailure.response }
        let result = try wire.nextExpectedRanges.map { raw -> OneDriveMissingRange in
            let fields = raw.split(separator: "-", omittingEmptySubsequences: false)
            guard fields.count == 2, let start = Int64(fields[0]), start >= 0, start < total,
                  fields[0].utf8.allSatisfy({ (48...57).contains($0) }) else { throw OneDriveFailure.response }
            let end: Int64
            if fields[1].isEmpty { end = total - 1 }
            else {
                guard fields[1].utf8.allSatisfy({ (48...57).contains($0) }), let parsed = Int64(fields[1]) else { throw OneDriveFailure.response }
                end = parsed
            }
            guard end >= start, end < total, start % (320 * 1024) == 0 else { throw OneDriveFailure.response }
            return OneDriveMissingRange(start: start, end: end)
        }.sorted { $0.start < $1.start }
        for index in result.indices where index > 0 {
            guard result[index - 1].end < result[index].start else { throw OneDriveFailure.response }
        }
        return result
    }
    private static func expiration(_ data: Data) throws -> Date {
        struct Wire: Decodable { let expirationDateTime: String }
        let text = try JSONDecoder().decode(Wire.self, from: data).expirationDateTime
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = parser.date(from: text) { return value }
        parser.formatOptions = [.withInternetDateTime]
        guard let value = parser.date(from: text) else { throw OneDriveFailure.response }; return value
    }
    private func newSession(driveID: String, folderID: String, name: String) async throws -> OneDriveUploadCapability {
        let reply = try await graph("drives/\(Self.encoded(driveID))/items/\(Self.encoded(folderID)):/\(Self.encoded(name)):/createUploadSession",
            method: "POST", body: ["item": ["name": name, "@microsoft.graph.conflictBehavior": "fail"]])
        struct Wire: Decodable { let uploadUrl: String }
        let wire = try JSONDecoder().decode(Wire.self, from: reply.data)
        guard let url = URL(string: wire.uploadUrl) else { throw OneDriveFailure.response }
        try OneDriveURLPolicy.capability(url)
        let expiration = try Self.expiration(reply.data)
        guard expiration > Date() else { throw OneDriveFailure.response }
        return OneDriveUploadCapability(url: url, expiresAt: expiration)
    }
    func verify(_ remote: OneDriveRemoteItem, original: OneDriveOriginal, driveID: String, folderID: String, name: String) async throws -> OneDriveUploadResult {
        guard !remote.id.isEmpty, remote.name == name, remote.size == original.bytes, remote.file != nil,
              remote.parentReference?.id == folderID, remote.parentReference?.driveId == driveID,
              let etag = remote.eTag, !etag.isEmpty else { throw OneDriveFailure.integrity }
        var methods: [String] = []
        if let sha = remote.file?.hashes?.sha256Hash, !sha.isEmpty {
            guard OneDriveOriginal.hashMatches(sha, hex: original.sha256) else { throw OneDriveFailure.integrity }
            methods.append("server SHA-256")
        }
        if let sha = remote.file?.hashes?.sha1Hash, !sha.isEmpty {
            guard OneDriveOriginal.hashMatches(sha, hex: original.sha1) else { throw OneDriveFailure.integrity }
            methods.append("server SHA-1")
        }
        if methods.isEmpty {
            guard let text = remote.downloadURL, let url = URL(string: text) else { throw OneDriveFailure.integrity }
            try OneDriveURLPolicy.capability(url)
            let downloaded = try await transport.download(url, expectedBytes: original.bytes, allowsCellular: allowsCellular)
            guard downloaded.bytes == original.bytes, downloaded.sha256 == original.sha256 else { throw OneDriveFailure.integrity }
            methods.append("full GET SHA-256") // quickXor is intentionally ignored.
        }
        let current = try await item(driveID: driveID, id: remote.id)
        guard current.id == remote.id, current.eTag == etag, current.size == original.bytes,
              current.name == name, current.file != nil,
              current.parentReference?.id == folderID, current.parentReference?.driveId == driveID else { throw OneDriveFailure.integrity }
        return OneDriveUploadResult(remoteID: remote.id, method: methods.joined(separator: " + "))
    }
    func upload(file: URL, original: OneDriveOriginal, driveID: String, folderID: String, name: String,
                resume: OneDriveUploadCapability?,
                checkpoint: @escaping @Sendable (OneDriveUploadCheckpoint) async throws -> Void) async throws -> OneDriveUploadResult {
        try Task.checkCancellation()
        if let existing = try await lookup(driveID: driveID, folderID: folderID, name: name) {
            return try await verify(existing, original: original, driveID: driveID, folderID: folderID, name: name)
        }
        var active: OneDriveUploadCapability?
        var missing = [OneDriveMissingRange(start: 0, end: original.bytes - 1)]
        if let resume = resume, resume.expiresAt > Date().addingTimeInterval(30) {
            let reply = try await capability(resume, method: "GET")
            if reply.status == 200 {
                missing = try Self.ranges(reply.data, total: original.bytes)
                active = OneDriveUploadCapability(url: resume.url, expiresAt: try Self.expiration(reply.data))
            } else if reply.status != 404 && reply.status != 410 {
                throw OneDriveFailure.http(reply.status, retryAfter: reply.retryAfter)
            }
        }
        if active == nil {
            do { active = try await newSession(driveID: driveID, folderID: folderID, name: name) }
            catch OneDriveFailure.http(409, _) {
                guard let existing = try await lookup(driveID: driveID, folderID: folderID, name: name) else { throw OneDriveFailure.conflict }
                return try await verify(existing, original: original, driveID: driveID, folderID: folderID, name: name)
            }
        }
        guard var session = active else { throw OneDriveFailure.response }
        try await checkpoint(OneDriveUploadCheckpoint(capability: session, offset: missing[0].start)) // Persist secret before any PUT.
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var reconciliations = 0
        while let range = missing.first {
            try Task.checkCancellation()
            let count = min(Self.chunkBytes, range.end - range.start + 1)
            guard count > 0, range.start + count == original.bytes || count % (320 * 1024) == 0 else { throw OneDriveFailure.response }
            try handle.seek(toOffset: UInt64(range.start))
            guard let data = try handle.read(upToCount: Int(count)), data.count == Int(count) else { throw OneDriveFailure.source }
            let end = range.start + count - 1
            let reply = try await capability(session, method: "PUT", data: data,
                range: "bytes \(range.start)-\(end)/\(original.bytes)")
            try Task.checkCancellation()
            if reply.status == 200 || reply.status == 201 {
                let returned = try JSONDecoder().decode(OneDriveRemoteItem.self, from: reply.data)
                let remote = try await item(driveID: driveID, id: returned.id)
                let verified = try await verify(remote, original: original, driveID: driveID, folderID: folderID, name: name)
                try await checkpoint(OneDriveUploadCheckpoint(capability: nil, offset: original.bytes))
                return verified
            }
            if reply.status == 409 {
                guard let existing = try await lookup(driveID: driveID, folderID: folderID, name: name) else { throw OneDriveFailure.conflict }
                let verified = try await verify(existing, original: original, driveID: driveID, folderID: folderID, name: name)
                try await checkpoint(OneDriveUploadCheckpoint(capability: nil, offset: original.bytes)); return verified
            }
            if reply.status == 416 {
                reconciliations += 1
                guard reconciliations <= 3 else { throw OneDriveFailure.response }
                let status = try await capability(session, method: "GET")
                guard status.status == 200 else { throw OneDriveFailure.http(status.status, retryAfter: status.retryAfter) }
                missing = try Self.ranges(status.data, total: original.bytes)
                session = OneDriveUploadCapability(url: session.url, expiresAt: try Self.expiration(status.data))
            } else if reply.status == 202 {
                let next = try Self.ranges(reply.data, total: original.bytes)
                guard next[0].start > range.start else { throw OneDriveFailure.response }
                missing = next
                session = OneDriveUploadCapability(url: session.url, expiresAt: try Self.expiration(reply.data))
                reconciliations = 0
            } else if reply.status == 404 || reply.status == 410 {
                try await checkpoint(OneDriveUploadCheckpoint(capability: nil, offset: 0))
                throw OneDriveFailure.sessionExpired
            } else { throw OneDriveFailure.http(reply.status, retryAfter: reply.retryAfter) }
            try await checkpoint(OneDriveUploadCheckpoint(capability: session, offset: missing[0].start))
        }
        throw OneDriveFailure.response
    }
}

@MainActor
final class OneDriveStore: ObservableObject {
    @Published private(set) var setup: OneDriveClientSetup
    @Published private(set) var account: OneDriveAccount?
    @Published private(set) var selectedFolder: OneDriveFolder?
    @Published private(set) var jobs: [OneDriveJob] = []
    @Published private(set) var busy = false
    @Published private(set) var settingsBusy = false
    @Published private(set) var paused = true
    @Published private(set) var status = "尚未登入 OneDrive；自動上傳預設關閉。"
    @Published var autoUpload = false { didSet { if !loading { persistOrStop() } } }
    @Published var wifiOnly = false {
        didSet {
            if !loading { persistOrStop(); if wifiOnly && !onWiFi { worker?.cancel() } }
        }
    }
    @Published private(set) var networkAvailable = true
    @Published private(set) var onWiFi = false
    /// Called only after a durable verified receipt; not after login, enqueue, PUT or share success.
    var onVerified: (@MainActor (OneDriveReceipt) -> Void)?
    var onJobChanged: (@MainActor (OneDriveJob) -> Void)?
    private let coordinator: OAuthCoordinator
    private let transport: any OneDriveHTTPTransport
    private let sessionVault: any OneDriveSessionVault
    private let rootDirectory: URL
    private let stateURL: URL
    private var loading = true
    private var storageBlocked = false
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var workerID: UUID?
    // Runtime-only foreground/global-network policy; not part of Snapshot.paused.
    private var policyBlocked = false
    #if canImport(Network)
    private var networkMonitor: NWPathMonitor?
    #endif
    private struct Snapshot: Codable {
        let version: Int
        let setup: OneDriveClientSetup
        let account: OneDriveAccount?
        let selectedFolder: OneDriveFolder?
        let jobs: [OneDriveJob]
        let autoUpload: Bool
        let wifiOnly: Bool
        let paused: Bool
    }
    /// rootDirectory is the existing Documents tree containing ingested originals, never a cleanup target.
    init(coordinator: OAuthCoordinator, setup: OneDriveClientSetup,
         rootDirectory: URL, stateDirectory: URL,
         transport: any OneDriveHTTPTransport = OneDriveURLSessionTransport(),
         sessionVault: any OneDriveSessionVault, monitorNetwork: Bool = true) {
        self.coordinator = coordinator; self.setup = setup; self.rootDirectory = rootDirectory.standardizedFileURL
        self.stateURL = stateDirectory.appendingPathComponent("onedrive-v1.json")
        self.transport = transport; self.sessionVault = sessionVault
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let data = try Data(contentsOf: stateURL)
                guard data.count <= 32 * 1024 * 1024 else { throw OneDriveFailure.storage }
                let saved = try JSONDecoder().decode(Snapshot.self, from: data)
                guard saved.version == 1, Set(saved.jobs.map { $0.id }).count == saved.jobs.count else { throw OneDriveFailure.storage }
                // Build/runtime setup is authoritative. Never silently reuse credentials under another authority.
                if saved.setup == setup {
                    account = saved.account; selectedFolder = saved.selectedFolder
                    autoUpload = saved.autoUpload; paused = saved.paused
                }
                jobs = saved.jobs; wifiOnly = saved.wifiOnly
                for index in jobs.indices where jobs[index].state == .uploading {
                    jobs[index].state = .retry; jobs[index].nextAttemptAt = .distantPast
                }
                status = account == nil ? "尚未登入；保留舊帳戶的工作與原圖。" : "本機設定已還原；尚未表示遠端已核對。"
            }
        } catch {
            storageBlocked = true; status = OneDriveFailure.storage.localizedDescription
        }
        loading = false
        if !storageBlocked { persistOrStop() }
        #if canImport(Network)
        if monitorNetwork {
            let monitor = NWPathMonitor(); networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied
                let wifi = available && path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.cellular)
                Task { @MainActor [weak self] in self?.updateNetwork(available: available, wifi: wifi) }
            }
            monitor.start(queue: DispatchQueue(label: "hk.camlink.ios.onedrive.network"))
        }
        #endif
    }
    #if canImport(UIKit) && canImport(Security)
    convenience init(coordinator: OAuthCoordinator? = nil, setup: OneDriveClientSetup? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let state = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CamLink-OneDrive", isDirectory: true)
        self.init(coordinator: coordinator ?? OAuthCoordinator(),
            setup: setup ?? OneDriveClientSetup(settings: OAuthAppConfiguration.settings),
            rootDirectory: documents, stateDirectory: state, sessionVault: KeychainOneDriveSessionVault())
    }
    #endif
    var verifiedCount: Int { jobs.filter { $0.state == .verified }.count }
    var pendingCount: Int { jobs.filter { [.pending, .uploading, .retry].contains($0.state) }.count }
    var failedCount: Int { jobs.filter { [.failed, .needsSignIn].contains($0.state) }.count }
    var receipts: [OneDriveReceipt] { jobs.compactMap { Self.receipt($0) } }
    func receipt(photoID: String, accountID: String, driveID: String, folderID: String) -> OneDriveReceipt? {
        receipts.first { $0.photoID == photoID && $0.accountID == accountID && $0.driveID == driveID && $0.folderID == folderID }
    }
    private static func receipt(_ job: OneDriveJob) -> OneDriveReceipt? {
        guard job.state == .verified, let date = job.verifiedAt, let method = job.verification, !job.remoteID.isEmpty else { return nil }
        return OneDriveReceipt(jobID: job.id, photoID: job.photoID, accountID: job.accountID,
            driveID: job.driveID, folderID: job.folderID, remoteID: job.remoteID, bytes: job.bytes,
            sha256: job.sha256, verifiedAt: date, method: method)
    }
    private func save() throws {
        guard !storageBlocked else { throw OneDriveFailure.storage }
        do {
            let directory = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let snapshot = Snapshot(version: 1, setup: setup, account: account, selectedFolder: selectedFolder,
                jobs: jobs, autoUpload: autoUpload, wifiOnly: wifiOnly, paused: paused)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: stateURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            #if canImport(UIKit)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stateURL.path)
            #endif
            var excluded = stateURL
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
        } catch { throw OneDriveFailure.storage }
    }
    private func persistOrStop() {
        do { try save() }
        catch {
            storageBlocked = true; paused = true; worker?.cancel(); status = OneDriveFailure.storage.localizedDescription
        }
    }
    private func replace(_ job: OneDriveJob) throws {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { throw OneDriveFailure.storage }
        let previous = jobs[index]; jobs[index] = job
        do { try save() }
        catch { jobs[index] = previous; storageBlocked = true; paused = true; throw OneDriveFailure.storage }
        onJobChanged?(job)
    }
    private func sourceURL(_ relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw OneDriveFailure.source }
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
        let url = rootDirectory.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw OneDriveFailure.source }
        return url
    }
    private func relativePath(_ url: URL) throws -> String {
        let root = rootDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.isFileURL, path.hasPrefix(root) else { throw OneDriveFailure.source }
        return String(path.dropFirst(root.count))
    }
    private func api(account expected: OneDriveAccount) -> OneDriveGraphAPI {
        let coordinator = self.coordinator
        return OneDriveGraphAPI(transport: transport, allowsCellular: !wifiOnly) {
            try await coordinator.validToken(for: expected.credentialKey, config: expected.setup.configuration()).accessToken
        }
    }
    private func currentAccount() throws -> OneDriveAccount {
        guard !storageBlocked else { throw OneDriveFailure.storage }
        guard let account = account, account.setup == setup else { throw OneDriveFailure.signIn }
        return account
    }
    private func stopWorker() async {
        let old = worker; old?.cancel(); await old?.value
    }
    /// Changing public registration requires explicit sign-out; never retargets existing jobs.
    func configure(_ value: OneDriveClientSetup) throws {
        guard !settingsBusy, !busy, account == nil else { throw OneDriveFailure.busy }
        _ = try value.configuration(); setup = value; autoUpload = false; paused = true
        selectedFolder = nil; try save()
    }
    func signIn() async {
        guard !settingsBusy, !storageBlocked else { return }
        settingsBusy = true; paused = true; persistOrStop()
        guard !storageBlocked else { settingsBusy = false; return }
        await stopWorker()
        let id = UUID(); generation = id
        defer { settingsBusy = false }
        do {
            let configuration = try setup.configuration()
            let token = try await coordinator.authorize(configuration)
            try Task.checkCancellation()
            let graph = OneDriveGraphAPI(transport: transport, allowsCellular: !wifiOnly) { token.accessToken }
            let resolved = try await graph.account(setup: setup)
            guard generation == id else { throw OneDriveFailure.cancelled }
            // offline_access must yield a durable refresh token, not a fake signed-in session.
            guard token.refreshToken?.isEmpty == false else { throw OneDriveFailure.signIn }
            try await coordinator.store(token, for: resolved.credentialKey)
            guard generation == id else { try await coordinator.signOut(resolved.credentialKey); throw OneDriveFailure.cancelled }
            if account?.id != resolved.id || account?.driveID != resolved.driveID { selectedFolder = nil; autoUpload = false }
            account = resolved; paused = true; try save()
            status = "Microsoft 帳戶與 OneDrive 已確認。請選目的地並手動繼續；登入不代表照片已核對。"
        } catch { status = OneDriveFailure.safe(error).localizedDescription }
    }
    func cancelSignIn() { generation = UUID(); coordinator.cancelAuthorization() }
    /// Native Keychain refresh and profile/drive recheck. Does not open an interactive session.
    func restore() async {
        guard !settingsBusy, !storageBlocked, let saved = account else { return }
        settingsBusy = true; let id = generation
        defer { settingsBusy = false }
        do {
            let resolved = try await api(account: saved).account(setup: saved.setup)
            guard generation == id, account == saved else { return }
            guard resolved.id == saved.id, resolved.driveID == saved.driveID else { throw OneDriveFailure.signIn }
            account = resolved; try save(); status = "Microsoft 登入已由金鑰鏈還原；照片須各自核對。"
        } catch { status = OneDriveFailure.safe(error).localizedDescription; paused = true; persistOrStop() }
    }
    /// Local disconnect only: no remote revoke/delete, no original or history deletion.
    func disconnect() async {
        generation = UUID(); paused = true; autoUpload = false; coordinator.cancelAuthorization()
        await stopWorker()
        let previous = account
        account = nil; selectedFolder = nil
        persistOrStop()
        do {
            if let previous = previous {
                try await coordinator.signOut(previous.credentialKey)
                for job in jobs where job.accountID == previous.id && job.setup == previous.setup {
                    try await sessionVault.delete(job.id)
                }
            }
            status = "已在本機登出。原圖、舊工作及已存在遠端檔案全部保留。"
        } catch { status = OneDriveFailure.safe(error).localizedDescription }
    }
    func folders(parentID: String? = nil) async throws -> [OneDriveFolder] {
        let account = try currentAccount(), id = generation
        let result = try await api(account: account).folders(driveID: account.driveID, parentID: parentID ?? account.rootID)
        guard generation == id, self.account?.id == account.id else { throw OneDriveFailure.cancelled }
        return result
    }
    func selectFolder(_ folder: OneDriveFolder?) async throws {
        guard !settingsBusy else { throw OneDriveFailure.busy }
        let account = try currentAccount(), id = generation
        if let folder = folder {
            guard folder.driveID == account.driveID else { throw OneDriveFailure.response }
            let checked = try await api(account: account).item(driveID: folder.driveID, id: folder.id)
            guard checked.folder != nil, checked.id == folder.id else { throw OneDriveFailure.response }
        }
        guard generation == id else { throw OneDriveFailure.cancelled }
        selectedFolder = folder; try save() // Existing jobs keep their original folder IDs.
    }
    @discardableResult
    func createFolder(name: String, parentID: String? = nil) async throws -> OneDriveFolder {
        let account = try currentAccount(), id = generation
        let folder = try await api(account: account).ensureFolder(driveID: account.driveID,
            parentID: parentID ?? account.rootID, name: name)
        guard generation == id else { throw OneDriveFailure.cancelled }
        return folder
    }
    /// Explicit/manual batch. Auto integration must call enqueueNew instead, not pass all accumulated history.
    /// Fixed folder if selected, otherwise creates the explicit albumName under this account's root.
    @discardableResult
    func enqueue(_ photos: [ReceivedJPEG], albumName: String) async throws -> Int {
        let account = try currentAccount(), id = generation
        guard !photos.isEmpty else { return 0 }
        let folder: OneDriveFolder
        if let selected = selectedFolder { folder = selected }
        else {
            folder = try await api(account: account).ensureFolder(driveID: account.driveID,
                parentID: account.rootID, name: albumName)
        }
        guard generation == id, self.account?.id == account.id else { throw OneDriveFailure.cancelled }
        var added = 0
        for photo in photos {
            try Task.checkCancellation()
            guard photo.bytes > 0, photo.sha256.count == 64,
                  photo.sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { throw OneDriveFailure.source }
            let relative = try relativePath(photo.url)
            let key = OneDriveGraphAPI.identity([account.setup.clientID, account.setup.tenant, account.setup.redirectURI,
                account.id, account.driveID, folder.id, photo.id, photo.sha256.lowercased()])
            if jobs.contains(where: { $0.id == key }) { continue } // Failed/cancelled also remain one immutable job.
            let job = OneDriveJob(id: key, setup: account.setup, accountID: account.id,
                driveID: account.driveID, folderID: folder.id, folderName: folder.name, photoID: photo.id,
                originalName: photo.name,
                remoteName: OneDriveGraphAPI.remoteName(original: photo.name, photoID: photo.id, sha256: photo.sha256.lowercased()),
                albumName: albumName, localRelativePath: relative, bytes: photo.bytes,
                sha256: photo.sha256.lowercased(), createdAt: Date())
            jobs.append(job)
            do { try save() }
            catch { jobs.removeLast(); storageBlocked = true; paused = true; throw OneDriveFailure.storage }
            added += 1; onJobChanged?(job)
        }
        status = "已新增 \(added) 張到 OneDrive 獨立佇列；尚未核對。"
        return added
    }
    @discardableResult
    func enqueueNew(_ photos: [ReceivedJPEG], albumName: String) async throws -> Int {
        guard autoUpload else { return 0 }
        return try await enqueue(photos, albumName: albumName)
    }
    func pause() {
        paused = true; worker?.cancel(); persistOrStop(); status = "已暫停；保留金鑰鏈續傳狀態。"
    }
    /// Transient parent policy; never resumes or persists a user-paused queue.
    func setPolicyBlocked(_ blocked: Bool) {
        guard policyBlocked != blocked else { return }
        policyBlocked = blocked
        if blocked {
            worker?.cancel()
            if !storageBlocked { status = "OneDrive 等待前景／網路政策允許；使用者暫停設定與原圖保留。" }
        } else if !paused {
            Task { [weak self] in
                guard let self = self, !self.paused, !self.policyBlocked else { return }
                await self.pump()
            }
        }
    }
    func resume() async {
        guard !storageBlocked, account != nil else { status = OneDriveFailure.signIn.localizedDescription; return }
        paused = false; persistOrStop(); await pump()
    }
    func cancel(jobID: String) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state != .verified else { return }
        var job = jobs[index]; job.state = .cancelled; job.error = nil
        do {
            try replace(job)
            // Stops only the active request; the next queued job may run later. No remote DELETE.
            worker?.cancel(); await worker?.value
            try await sessionVault.delete(jobID)
            status = "工作已取消；本機及已存在雲端檔案保留。"
        } catch { status = OneDriveFailure.safe(error).localizedDescription }
    }
    func retryFailed(jobID: String? = nil) {
        _ = retryFailed(matching: { jobID == nil || jobID == $0.id })
    }
    /// Explicit selected-photo retry; never matches a reused ID at another local source.
    @discardableResult
    func retryFailed(photos: [ReceivedJPEG]) -> Int {
        var selected: [String: Set<String>] = [:]
        for photo in photos {
            guard let relative = try? relativePath(photo.url), let source = try? sourceURL(relative) else { continue }
            selected[photo.id, default: []].insert(source.path)
        }
        return retryFailed(matching: { job in
            guard let source = try? self.sourceURL(job.localRelativePath) else { return false }
            return selected[job.photoID]?.contains(source.path) == true
        })
    }
    private func retryFailed(matching selected: (OneDriveJob) -> Bool) -> Int {
        guard let account = account, !storageBlocked else { return 0 }
        var count = 0
        do {
            for current in jobs where matches(current, account: account)
                && selected(current)
                && [.failed, .retry, .needsSignIn, .cancelled].contains(current.state) {
                var job = current; job.state = .pending; job.attempts = 0; job.nextAttemptAt = .distantPast; job.error = nil
                try replace(job)
                count += 1
            }
        } catch { status = OneDriveFailure.safe(error).localizedDescription }
        return count
    }
    /// Parent foreground/network policy hook. This is not background USB or background delivery.
    func updateNetwork(available: Bool, wifi: Bool) {
        networkAvailable = available; onWiFi = wifi
        if !available || (wifiOnly && !wifi) { worker?.cancel() }
        else if !paused && !policyBlocked { Task { await self.pump() } }
    }
    private func matches(_ job: OneDriveJob, account: OneDriveAccount) -> Bool {
        job.accountID == account.id && job.driveID == account.driveID && job.setup == account.setup
    }
    static func retryDelay(attempt: Int, serverSeconds: Int? = nil) -> TimeInterval {
        let bounded = min(5, max(1, attempt))
        return max(min(3600, max(0, Double(serverSeconds ?? 0))), min(120, pow(2, Double(bounded)) * 2))
    }
    /// Single-flight worker. Call after explicit resume, auto enqueue, restore, or foreground recovery.
    func pump() async {
        if let current = worker {
            let currentID = workerID
            await current.value
            if workerID == currentID { worker = nil; workerID = nil }
        }
        guard !Task.isCancelled, !paused, !policyBlocked, !settingsBusy, !storageBlocked, networkAvailable,
              (!wifiOnly || onWiFi), account != nil else { return }
        guard worker == nil else { return }
        let id = UUID(); workerID = id
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self = self else { return }
            await self.runWorker()
        }
        worker = task
        await task.value
        if workerID == id { worker = nil; workerID = nil }
    }
    private func runWorker() async {
        busy = true; defer { busy = false }
        while !Task.isCancelled, !paused, !policyBlocked, !settingsBusy, !storageBlocked, networkAvailable,
              (!wifiOnly || onWiFi), let account = account {
            let candidates = jobs.filter { matches($0, account: account) && [.pending, .retry].contains($0.state) }
            guard let job = candidates.min(by: { $0.nextAttemptAt < $1.nextAttemptAt }) else { return }
            let wait = job.nextAttemptAt.timeIntervalSinceNow
            if wait > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(min(wait, 3600) * 1_000_000_000)) }
                catch { return }
                continue
            }
            await process(job, account: account)
        }
    }
    private func process(_ input: OneDriveJob, account expected: OneDriveAccount) async {
        let id = generation
        var job = input
        do {
            try Task.checkCancellation()
            guard !paused, !policyBlocked else { throw OneDriveFailure.cancelled }
            job.state = .uploading; job.error = nil; try replace(job)
            let url = try sourceURL(job.localRelativePath)
            let original = try await Task.detached(priority: .utility) { try OneDriveOriginal.inspect(url) }.value
            try Task.checkCancellation()
            guard original.bytes == job.bytes, original.sha256 == job.sha256 else { throw OneDriveFailure.source }
            let saved = try await sessionVault.load(job.id)
            let jobID = job.id, vault = sessionVault
            let result = try await api(account: expected).upload(file: url, original: original,
                driveID: job.driveID, folderID: job.folderID, name: job.remoteName, resume: saved) { [weak self] checkpoint in
                try Task.checkCancellation()
                if let capability = checkpoint.capability { try await vault.save(capability, jobID: jobID) }
                else { try await vault.delete(jobID) }
                try await self?.applyCheckpoint(checkpoint, jobID: jobID, generation: id)
            }
            try Task.checkCancellation()
            guard generation == id, !paused, !policyBlocked, account?.id == expected.id,
                  let current = jobs.first(where: { $0.id == job.id }), current.state != .cancelled else { throw OneDriveFailure.cancelled }
            // Re-read original after upload to prevent receipt for a changed local source.
            let after = try await Task.detached(priority: .utility) { try OneDriveOriginal.inspect(url) }.value
            guard after == original else { throw OneDriveFailure.source }
            try Task.checkCancellation()
            guard generation == id, !paused, !policyBlocked, account?.id == expected.id,
                  jobs.first(where: { $0.id == job.id })?.state == .uploading else { throw OneDriveFailure.cancelled }
            try await sessionVault.delete(job.id)
            try Task.checkCancellation()
            guard generation == id, !paused, !policyBlocked,
                  jobs.first(where: { $0.id == job.id })?.state == .uploading else { throw OneDriveFailure.cancelled }
            job.offset = job.bytes; job.remoteID = result.remoteID; job.verification = result.method
            job.verifiedAt = Date(); job.state = .verified; job.error = nil; try replace(job)
            status = "OneDrive 原圖已核對：\(job.originalName)"
            if let receipt = Self.receipt(job) { onVerified?(receipt) }
        } catch {
            guard let current = jobs.first(where: { $0.id == input.id }), current.state != .cancelled,
                  generation == id else { return }
            job = current
            let failure = OneDriveFailure.safe(error)
            if case .cancelled = failure { job.state = .pending; job.error = nil }
            else {
                job.attempts += 1; job.error = failure.localizedDescription
                if failure.requiresSignIn { job.state = .needsSignIn }
                else if failure.retryable && job.attempts < 5 {
                    job.state = .retry
                    let server: Int?
                    if case let .http(_, retryAfter) = failure { server = retryAfter } else { server = nil }
                    job.nextAttemptAt = Date().addingTimeInterval(Self.retryDelay(attempt: job.attempts, serverSeconds: server))
                } else { job.state = .failed }
            }
            do { try replace(job) } catch { storageBlocked = true; paused = true }
            status = failure.localizedDescription
        }
    }
    private func applyCheckpoint(_ value: OneDriveUploadCheckpoint, jobID: String, generation expected: UUID) throws {
        guard generation == expected, !Task.isCancelled, !paused, !policyBlocked,
              let current = jobs.first(where: { $0.id == jobID }), current.state == .uploading else { throw OneDriveFailure.cancelled }
        var job = current; job.offset = value.offset; try replace(job)
    }
}
