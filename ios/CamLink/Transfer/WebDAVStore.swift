import Combine
import CryptoKit
import Foundation
import Security

/// Public configuration only. Application passwords never enter this Codable value.
struct WebDAVConfiguration: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let label: String
    let folderURL: URL
    let username: String
}

enum WebDAVJobState: String, Codable, Sendable {
    case pending, uploading, verified, failed
}

/// A job owns its destination snapshot; selecting another account never retargets it.
struct WebDAVJob: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let destination: WebDAVConfiguration
    let photoID: String
    let name: String
    let remoteName: String
    // Relative to Documents, so an iOS container path change does not break recovery.
    let localRelativePath: String
    let bytes: Int64
    let sha256: String
    let createdAt: Date
    var state: WebDAVJobState
    var attempts: Int
    var updatedAt: Date
    var verifiedAt: Date?
    var error: String?

    var configurationID: String { destination.id }
}

@MainActor
final class WebDAVStore: ObservableObject {
    @Published private(set) var config: WebDAVConfiguration?
    @Published var autoUpload = false {
        didSet {
            guard !restoring, autoUpload != oldValue else { return }
            _ = saveCurrentState()
        }
    }
    @Published private(set) var busy = false
    @Published private(set) var message = "未傳送驗證：請先儲存 WebDAV 設定"
    @Published private(set) var jobs: [WebDAVJob] = []

    private struct Snapshot: Codable {
        var version: Int
        var config: WebDAVConfiguration?
        var autoUpload: Bool
        var jobs: [WebDAVJob]
    }

    private let documentsURL: URL
    private let stateURL: URL
    private var restoring = true
    private var storageReady = true
    private var activeTransfer: Task<Void, Error>?

    init() {
        documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        stateURL = documentsURL.appendingPathComponent("webdav-jobs.json")
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: stateURL))
                guard saved.version == 1 else { throw WebDAVFailure.storage }
                if let configuration = saved.config { try WebDAVValidation.check(configuration) }
                var ids = Set<String>()
                for job in saved.jobs {
                    try WebDAVValidation.check(job.destination)
                    guard ids.insert(job.id).inserted,
                          job.bytes >= 4, WebDAVValidation.isSHA256(job.sha256),
                          WebDAVValidation.isRelativePath(job.localRelativePath),
                          WebDAVValidation.isFilename(job.remoteName),
                          job.id == WebDAVValidation.jobID(configurationID: job.configurationID,
                                                           name: job.remoteName, sha: job.sha256)
                    else { throw WebDAVFailure.storage }
                }
                config = saved.config
                autoUpload = saved.autoUpload
                jobs = saved.jobs.map { original in
                    var job = original
                    if job.state == .uploading {
                        job.state = .pending
                        job.verifiedAt = nil
                        job.error = nil
                        job.updatedAt = Date()
                    }
                    return job
                }
                message = config == nil ? "WebDAV 已停用；原圖與舊目的地佇列保留" : "設定已載入；待傳項目未傳送驗證"
            }
            try writeSnapshot(config: config, autoUpload: autoUpload, jobs: jobs)
        } catch {
            // Do not silently replace a corrupt/unreadable durable queue with an empty one.
            config = nil
            autoUpload = false
            jobs = []
            storageReady = false
            message = WebDAVFailure.storage.localizedDescription
        }
        restoring = false
    }

    var verifiedCount: Int { activeJobs.filter { $0.state == .verified }.count }
    var pendingCount: Int { activeJobs.filter { $0.state == .pending || $0.state == .uploading }.count }
    var failedCount: Int { activeJobs.filter { $0.state == .failed }.count }
    var activeJobs: [WebDAVJob] { jobs.filter { $0.configurationID == config?.id } }
    var oldJobsCount: Int { jobs.count - activeJobs.count }

    /// Local validation and Keychain + atomic JSON save only. This is NOT a connection test.
    func configure(folder: String, username: String, password: String) throws {
        guard storageReady else { throw WebDAVFailure.storage }
        let destination = try WebDAVValidation.configuration(folder: folder, username: username)
        guard !password.isEmpty,
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw WebDAVFailure.credentials }
        try WebDAVCredentialVault.save(password, configurationID: destination.id)
        // Commit public settings before publishing them. Credentials remain in Keychain only.
        try writeSnapshot(config: destination, autoUpload: autoUpload, jobs: jobs)
        if config?.id != destination.id { activeTransfer?.cancel() }
        config = destination
        message = "設定已儲存（僅本機）；未傳送驗證"
    }

    /// Keep originals, verified history, old destination snapshots and namespaced credentials.
    func disable() {
        activeTransfer?.cancel()
        config = nil
        autoUpload = false
        if saveCurrentState() {
            message = "WebDAV 已停用；原圖與佇列保留，重新選取相同目的地可續傳"
        }
    }

    /// Explicit retry only; failed jobs are never continuously retried in the upload loop.
    func retryFailed() {
        guard let configurationID = config?.id, storageReady else {
            message = "請先儲存要重試的 WebDAV 目的地"
            return
        }
        for index in jobs.indices where jobs[index].configurationID == configurationID && jobs[index].state == .failed {
            jobs[index].state = .pending
            jobs[index].error = nil
            jobs[index].verifiedAt = nil
            jobs[index].updatedAt = Date()
        }
        if saveCurrentState() { message = "失敗項目已排入佇列；未傳送驗證，請開始上傳" }
    }

    /// ReceivedJPEG is a locally validated original, not a thumbnail or a PC receipt.
    /// Check availability/metadata here; streaming JPEG and SHA validation runs off-main
    /// before any PUT. Never change ReceivedJPEG.uploaded (the independent PC boolean).
    func enqueue(_ photos: [ReceivedJPEG]) {
        guard let destination = config, storageReady else {
            message = "請先儲存 WebDAV 設定；未傳送驗證"
            return
        }
        do { try WebDAVValidation.check(destination) }
        catch { message = WebDAVFailure.invalidFolder.localizedDescription; return }
        let root = documentsURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var known = Set(jobs.map(\.id))
        var added = 0
        var unavailable = 0
        for photo in photos {
            let source = photo.url.resolvingSymlinksInPath().standardizedFileURL
            guard photo.url.isFileURL, source.path.hasPrefix(root),
                  photo.bytes >= 4, WebDAVValidation.isSHA256(photo.sha256),
                  ["jpg", "jpeg"].contains(source.pathExtension.lowercased()),
                  FileManager.default.isReadableFile(atPath: source.path),
                  let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, values.fileSize.map({ Int64($0) }) == photo.bytes
            else { unavailable += 1; continue }
            let relative = String(source.path.dropFirst(root.count))
            let remoteName = "CamLink_" + source.lastPathComponent
            guard WebDAVValidation.isRelativePath(relative), WebDAVValidation.isFilename(remoteName) else {
                unavailable += 1
                continue
            }
            let sha = photo.sha256.lowercased()
            let id = WebDAVValidation.jobID(configurationID: destination.id, name: remoteName, sha: sha)
            guard known.insert(id).inserted else { continue }
            let now = Date()
            jobs.append(WebDAVJob(id: id, destination: destination, photoID: photo.id,
                                  name: photo.name, remoteName: remoteName, localRelativePath: relative,
                                  bytes: photo.bytes, sha256: sha, createdAt: now, state: .pending,
                                  attempts: 0, updatedAt: now, verifiedAt: nil, error: nil))
            added += 1
        }
        if saveCurrentState() {
            message = "新增 \(added) 張待傳 JPG；未傳送驗證"
            if unavailable > 0 { message += "；\(unavailable) 張本機原圖不可用或資料不符，未排入" }
        }
    }

    /// Foreground, one pump at a time. Manual upload is allowed with autoUpload OFF.
    /// The caller owns automatic-dispatch opt-in; this method never controls the camera.
    func uploadPending() async {
        guard !busy else { return }
        guard storageReady else { message = WebDAVFailure.storage.localizedDescription; return }
        guard let configurationID = config?.id else {
            message = "請先儲存 WebDAV 設定；未傳送驗證"
            return
        }
        busy = true
        defer { activeTransfer = nil; busy = false }
        var verified = 0
        var failures = 0
        while !Task.isCancelled, storageReady, config?.id == configurationID,
              let job = jobs.first(where: { $0.configurationID == configurationID && $0.state == .pending }) {
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { break }
            jobs[index].state = .uploading
            jobs[index].attempts += 1
            jobs[index].error = nil
            jobs[index].verifiedAt = nil
            jobs[index].updatedAt = Date()
            // A durable uploading record must exist before sending anything.
            guard saveCurrentState() else {
                jobs[index].state = .pending
                break
            }
            message = "正在傳送原圖並以 GET 核對；尚未完成傳送驗證"
            let source = documentsURL.appendingPathComponent(job.localRelativePath)
            let transfer = Task {
                try await WebDAVTransport.transfer(job: job, source: source, documents: self.documentsURL)
            }
            activeTransfer = transfer
            do {
                try await withTaskCancellationHandler(operation: {
                    try await transfer.value
                }, onCancel: {
                    transfer.cancel()
                })
                if let current = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[current].state = .verified
                    jobs[current].verifiedAt = Date()
                    jobs[current].updatedAt = Date()
                    jobs[current].error = nil
                }
                verified += 1
            } catch {
                let cancelled = transfer.isCancelled || Task.isCancelled || error is CancellationError
                    || (error as? URLError)?.code == .cancelled
                if let current = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[current].state = cancelled ? .pending : .failed
                    jobs[current].verifiedAt = nil
                    jobs[current].updatedAt = Date()
                    jobs[current].error = cancelled ? nil : WebDAVFailure.safeMessage(error)
                }
                if !cancelled { failures += 1 }
                if !saveCurrentState() { break }
                if cancelled {
                    if config != nil { message = "傳送已暫停；未完成驗證的項目保留待傳" }
                    break
                }
                message = WebDAVFailure.safeMessage(error)
                // Do not hammer the server with the rest of the queue on account/network failure.
                break
            }
            activeTransfer = nil
            guard saveCurrentState() else { break }
        }
        if storageReady, config?.id == configurationID, !Task.isCancelled, failures == 0 {
            if verified > 0 { message = "WebDAV 已以 GET 大小與 SHA-256 核對 \(verified) 張原圖" }
            else if pendingCount == 0 { message = "沒有待傳 JPG；既有驗證數量請見下方" }
        }
    }

    @discardableResult
    private func saveCurrentState() -> Bool {
        guard storageReady else { message = WebDAVFailure.storage.localizedDescription; return false }
        do {
            try writeSnapshot(config: config, autoUpload: autoUpload, jobs: jobs)
            return true
        } catch {
            storageReady = false
            activeTransfer?.cancel()
            message = WebDAVFailure.storage.localizedDescription
            return false
        }
    }

    private func writeSnapshot(config: WebDAVConfiguration?, autoUpload: Bool, jobs: [WebDAVJob]) throws {
        do {
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Snapshot(version: 1, config: config, autoUpload: autoUpload, jobs: jobs))
            try data.write(to: stateURL, options: .atomic)
        } catch { throw WebDAVFailure.storage }
    }
}

private enum WebDAVValidation {
    static func configuration(folder: String, username: String) throws -> WebDAVConfiguration {
        let raw = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !user.contains(":"), !containsControls(user),
              !containsControls(raw), !raw.contains("\\"),
              var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true
        else { throw WebDAVFailure.invalidFolder }
        for segment in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            guard let decoded = String(segment).removingPercentEncoding,
                  decoded != ".", decoded != "..", !containsControls(decoded), !decoded.contains("\\")
            else { throw WebDAVFailure.invalidFolder }
        }
        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        if !components.percentEncodedPath.hasSuffix("/") { components.percentEncodedPath += "/" }
        guard let url = components.url, url.host != nil else { throw WebDAVFailure.invalidFolder }
        return WebDAVConfiguration(id: hex(Data((url.absoluteString + "\n" + user).utf8)),
                                   label: host.lowercased(), folderURL: url, username: user)
    }

    static func check(_ configuration: WebDAVConfiguration) throws {
        let normalized = try self.configuration(folder: configuration.folderURL.absoluteString,
                                                username: configuration.username)
        guard configuration.id == normalized.id, configuration.folderURL == normalized.folderURL,
              configuration.username == normalized.username else { throw WebDAVFailure.invalidFolder }
    }

    static func target(for job: WebDAVJob) throws -> URL {
        try check(job.destination)
        // Encode exactly ONE path segment: %, /, ?, #, Unicode and spaces cannot change the URL.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard isFilename(job.remoteName),
              let encoded = job.remoteName.addingPercentEncoding(withAllowedCharacters: unreserved),
              var components = URLComponents(url: job.destination.folderURL, resolvingAgainstBaseURL: false)
        else { throw WebDAVFailure.invalidFilename }
        components.percentEncodedPath += encoded
        guard let url = components.url else { throw WebDAVFailure.invalidFilename }
        return url
    }

    static func jobID(configurationID: String, name: String, sha: String) -> String {
        hex(Data((configurationID + "\n" + name + "\n" + sha.lowercased()).utf8))
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    static func isFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !containsControls(value)
    }

    static func isRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !containsControls(value)
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }

    private static func containsControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum WebDAVCredentialVault {
    // Deliberately separate from PC pairing. A destination id is a URL + username hash.
    private static var service: String { (Bundle.main.bundleIdentifier ?? "hk.camlink.ios") + ".webdav.credentials.v1" }

    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id,
         kSecAttrSynchronizable as String: false]
    }

    static func save(_ password: String, configurationID: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(configurationID) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw WebDAVFailure.keychain }
        var item = query(configurationID)
        attributes.forEach { item[$0.key] = $0.value }
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw WebDAVFailure.keychain }
    }

    static func load(configurationID: String) throws -> String {
        var item = query(configurationID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty
        else { throw WebDAVFailure.keychain }
        return value
    }
}

private enum WebDAVTransport {
    /// Non-main-actor network work. No PC pinning, invalid-certificate exception or background session.
    static func transfer(job: WebDAVJob, source: URL, documents: URL) async throws {
        try Task.checkCancellation()
        let root = documents.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let file = source.resolvingSymlinksInPath().standardizedFileURL
        guard file.isFileURL, file.path.hasPrefix(root) else { throw WebDAVFailure.localOriginal }
        let target = try WebDAVValidation.target(for: job)
        try await verifyFile(file, bytes: job.bytes, sha: job.sha256, localOriginal: true)
        try Task.checkCancellation()
        let password = try WebDAVCredentialVault.load(configurationID: job.configurationID)
        let auth = "Basic " + Data((job.destination.username + ":" + password).utf8).base64EncodedString()
        var put = request(target: target, method: "PUT", auth: auth)
        put.setValue("*", forHTTPHeaderField: "If-None-Match")
        put.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        put.setValue(String(job.bytes), forHTTPHeaderField: "Content-Length")
        let putStatus = try await upload(put, file: file)
        guard [200, 201, 204, 412].contains(putStatus) else {
            throw WebDAVFailure.http(method: "PUT", status: putStatus)
        }
        try Task.checkCancellation()
        // Even 412 is not success until the existing remote bytes are proven identical.
        let delegate = WebDAVSessionDelegate()
        let session = URLSession(configuration: sessionConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let get = request(target: target, method: "GET", auth: auth)
        let (downloaded, response) = try await session.download(for: get)
        // Delete only this GET's temporary file, never an original or a queued source.
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse else { throw WebDAVFailure.noHTTPResponse }
        guard http.statusCode == 200 else { throw WebDAVFailure.http(method: "GET", status: http.statusCode) }
        do {
            try await verifyFile(downloaded, bytes: job.bytes, sha: job.sha256, localOriginal: false)
        } catch WebDAVFailure.remoteMismatch {
            throw putStatus == 412 ? WebDAVFailure.collision : WebDAVFailure.remoteMismatch
        }
        try Task.checkCancellation()
    }

    private static func request(target: URL, method: String, auth: String) -> URLRequest {
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return configuration
    }

    private static func upload(_ request: URLRequest, file: URL) async throws -> Int {
        // Delegate-based PUT discards the response body rather than buffering arbitrary server data.
        let delegate = WebDAVUploadDelegate()
        let session = URLSession(configuration: sessionConfiguration(), delegate: delegate, delegateQueue: nil)
        let uploadTask = session.uploadTask(with: request, fromFile: file)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                delegate.install(continuation)
                uploadTask.resume()
            }
        }, onCancel: {
            // Never create a task in an already-invalidated session during cancellation.
            uploadTask.cancel()
        })
    }

    private static func verifyFile(_ url: URL, bytes: Int64, sha: String, localOriginal: Bool) async throws {
        let task = Task.detached(priority: .utility) {
            let mismatch: WebDAVFailure = localOriginal ? .localOriginal : .remoteMismatch
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true,
                      values.fileSize.map({ Int64($0) }) == bytes else { throw mismatch }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                var count: Int64 = 0
                var first = Data()
                while true {
                    try Task.checkCancellation()
                    guard let block = try handle.read(upToCount: 128 * 1024), !block.isEmpty else { break }
                    if first.count < 2 { first.append(contentsOf: block.prefix(2 - first.count)) }
                    count += Int64(block.count)
                    guard count <= bytes else { throw mismatch }
                    hash.update(data: block)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                // Intake already validated JPEG/MPF structure with ImageIO. Recheck
                // exact original bytes against its immutable receipt, including all
                // indexed auxiliary images and padding; never crop/re-encode here.
                guard count == bytes, digest == sha.lowercased(),
                      !localOriginal || first == Data([0xff, 0xd8])
                else { throw mismatch }
            } catch is CancellationError { throw CancellationError() }
            catch { throw mismatch }
        }
        try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
}

private class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Refuse ALL redirects, including same-host and HTTPS-to-HTTPS redirects.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Basic credentials were explicitly supplied only for the original URL.
            completionHandler(.rejectProtectionSpace, nil)
        }
    }
}

private final class WebDAVUploadDelegate: WebDAVSessionDelegate, URLSessionDataDelegate {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Error>?
    private var result: Result<Int, Error>?

    func install(_ continuation: CheckedContinuation<Int, Error>) {
        // Cancellation can finish the suspended task before its continuation is installed.
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func finish(_ outcome: Result<Int, Error>) {
        lock.lock()
        if let _ = result { lock.unlock(); return }
        result = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: outcome)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Intentionally discard response bodies; never retain or log them.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Preserve a 412/401/redirect response even when the server rejects the upload body early.
        if let http = task.response as? HTTPURLResponse, let error = error as? URLError,
           error.code != .cancelled, !(200...299).contains(http.statusCode) {
            finish(.success(http.statusCode))
        } else if let error {
            finish(.failure(error))
        } else if let http = task.response as? HTTPURLResponse {
            finish(.success(http.statusCode))
        } else {
            finish(.failure(WebDAVFailure.noHTTPResponse))
        }
    }
}

private enum WebDAVFailure: Error, LocalizedError, Sendable {
    case invalidFolder, invalidFilename, credentials, keychain, storage, localOriginal
    case noHTTPResponse, remoteMismatch, collision
    case http(method: String, status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidFolder: return "請填寫既有 HTTPS 資料夾網址與帳戶；不可包含網址帳密、查詢、片段或路徑跳轉"
        case .invalidFilename: return "目的地檔名無效；未傳送驗證"
        case .credentials: return "請填寫非空的應用程式密碼；不得含換行或控制字元"
        case .keychain: return "無法讀寫 WebDAV 金鑰鏈；請解鎖裝置，或為此目的地重新儲存應用程式密碼"
        case .storage: return "無法讀寫 WebDAV 佇列；已停止傳送，變更可能未保存。請保留 webdav-jobs.json，檢查儲存空間後重開並確認設定"
        case .localOriginal: return "本機原圖不存在、不完整，或大小／SHA-256 已改變；未傳送驗證"
        case .noHTTPResponse: return "WebDAV 未提供有效 HTTP 回應；未傳送驗證"
        case .remoteMismatch: return "GET 遠端檔案大小／SHA-256 不符；未傳送驗證，未覆寫原圖"
        case .collision: return "HTTP 412：遠端同名檔內容不同；未覆寫，請檢查目的地同名檔"
        case .http(let method, let status):
            if (300...399).contains(status) { return "WebDAV \(method) HTTP \(status)：已拒絕重新導向；請填寫最終 HTTPS 資料夾網址" }
            if status == 401 || status == 403 { return "WebDAV \(method) HTTP \(status)：請檢查帳戶、應用程式密碼及 PUT／GET 權限" }
            if status == 404 || status == 409 { return "WebDAV \(method) HTTP \(status)：請先在伺服器建立資料夾並確認網址" }
            return "WebDAV \(method) HTTP \(status)；未傳送驗證，請檢查伺服器權限或稍後重試"
        }
    }

    static func safeMessage(_ error: Error) -> String {
        // Never surface NSError.userInfo, response bodies, URLs, credentials or raw localized errors.
        if let known = error as? WebDAVFailure { return known.localizedDescription }
        if error is CancellationError { return "傳送已暫停；未傳送驗證" }
        if let network = error as? URLError {
            switch network.code {
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                return "HTTPS 憑證或 TLS 驗證失敗；只接受系統信任的有效憑證，未傳送驗證"
            case .userAuthenticationRequired, .userCancelledAuthentication:
                return "WebDAV 身分驗證失敗；請檢查帳戶與應用程式密碼"
            case .timedOut: return "WebDAV 連線逾時；未傳送驗證，請稍後重試"
            case .cancelled: return "傳送已暫停；未傳送驗證"
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "WebDAV 網路不可用或連線中斷；原圖保留，未傳送驗證"
            default: return "WebDAV 網路失敗（錯誤代碼 \(network.code.rawValue)）；未傳送驗證"
            }
        }
        return "WebDAV 傳送失敗；原圖保留，未傳送驗證"
    }
}
