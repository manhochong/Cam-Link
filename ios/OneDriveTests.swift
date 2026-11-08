import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Standalone macOS executable, not app source. No real account, external requests, camera or photos.
private enum TestFailure: Error { case assertion(String) }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.assertion(message) }
}
private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
private let future = "2099-01-01T00:00:00Z"
private struct Seen: Sendable {
    let method: String
    let path: String
    let bearer: String?
    let range: String?
    let bytes: Int
    let body: Data?
}
private actor ScriptHTTP: OneDriveHTTPTransport {
    typealias Handler = @Sendable (URLRequest, String?, Int) throws -> OneDriveHTTPReply
    private let handler: Handler
    private var seen: [Seen] = []
    private var downloaded = 0
    private let downloadValue: OneDriveOriginal?
    init(downloadValue: OneDriveOriginal? = nil, handler: @escaping Handler) {
        self.handler = handler; self.downloadValue = downloadValue
    }
    func send(_ request: URLRequest, bearer: String?) async throws -> OneDriveHTTPReply {
        let value = Seen(method: request.httpMethod ?? "GET", path: request.url?.path ?? "", bearer: bearer,
            range: request.value(forHTTPHeaderField: "Content-Range"), bytes: request.httpBody?.count ?? 0, body: request.httpBody)
        seen.append(value)
        return try handler(request, bearer, seen.count)
    }
    func download(_ url: URL, expectedBytes: Int64, allowsCellular: Bool) async throws -> OneDriveOriginal {
        try OneDriveURLPolicy.capability(url); downloaded += 1
        guard let value = downloadValue else { throw TestFailure.assertion("unexpected signed download") }; return value
    }
    func records() -> [Seen] { seen }
    func downloadCount() -> Int { downloaded }
}
private actor Checkpoints {
    private var values: [OneDriveUploadCheckpoint] = []
    func add(_ value: OneDriveUploadCheckpoint) { values.append(value) }
    func offsets() -> [Int64] { values.map { $0.offset } }
}
private actor MemoryOAuthVault: OAuthCredentialVault {
    private var values: [OAuthCredentialKey: OAuthToken] = [:]
    func load(for key: OAuthCredentialKey) async throws -> OAuthToken? { values[key] }
    func save(_ token: OAuthToken, for key: OAuthCredentialKey) async throws { values[key] = token }
    func delete(for key: OAuthCredentialKey) async throws { values.removeValue(forKey: key) }
}
private actor MemorySessions: OneDriveSessionVault {
    private var values: [String: OneDriveUploadCapability] = [:]
    func load(_ jobID: String) async throws -> OneDriveUploadCapability? { values[jobID] }
    func save(_ value: OneDriveUploadCapability, jobID: String) async throws { values[jobID] = value }
    func delete(_ jobID: String) async throws { values.removeValue(forKey: jobID) }
}
private final class OneDriveMockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var data = Data()
        var redirect: URL?
        var delay: TimeInterval = 0
    }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var captured: [URLRequest] = []
    private let instanceLock = NSRecursiveLock()
    private var stopped = false
    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }; Self.handler = handler; captured = []
    }
    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return captured
    }
    private static func response(_ request: URLRequest) -> Reply {
        lock.lock(); captured.append(request); let handler = Self.handler; lock.unlock()
        return handler?(request) ?? Reply(status: 500)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.response(request)
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in self?.deliver(reply) }
        } else { deliver(reply) }
    }
    private func deliver(_ reply: Reply) {
        instanceLock.lock(); defer { instanceLock.unlock() }
        guard !stopped, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status,
                httpVersion: "HTTP/1.1", headerFields: [:]) else { return }
        if let destination = reply.redirect {
            var next = request; next.url = destination
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        instanceLock.lock(); defer { instanceLock.unlock() }; stopped = true
    }
}
@MainActor private final class NoBrowser: OAuthBrowserSession {
    func start(url: URL, callbackScheme: String, completion: @escaping @MainActor (Result<URL, OAuthFailure>) -> Void) throws {
        throw TestFailure.assertion("interactive authentication is not part of these tests")
    }
    func cancel() {}
}
private func remote(original: OneDriveOriginal, name: String, sha1: String? = nil,
                    sha256: String? = nil, download: Bool = false, quickXor: String? = nil,
                    parent: String = "folder", etag: String = "stable-v1") -> [String: Any] {
    var hashes: [String: Any] = [:]
    if let sha1 = sha1 { hashes["sha1Hash"] = sha1 }
    if let sha256 = sha256 { hashes["sha256Hash"] = sha256 }
    if let quickXor = quickXor { hashes["quickXorHash"] = quickXor }
    var item: [String: Any] = ["id": "remote", "name": name, "size": original.bytes,
        "eTag": etag, "parentReference": ["id": parent, "driveId": "drive"], "file": ["hashes": hashes]]
    if download { item["@microsoft.graph.downloadUrl"] = "https://files.1drv.com/test-only-download" }
    return item
}
private func makeOriginal(_ directory: URL, name: String, size: Int) throws -> (URL, OneDriveOriginal) {
    var data = Data(repeating: 0x61, count: size)
    // Deliberate MPF-like appended bytes: no FFD9-at-final-two-byte assumption.
    data.replaceSubrange(0..<4, with: [0xff, 0xd8, 0xff, 0xe2])
    data.append(contentsOf: [0xff, 0xd9, 0xff, 0xd8, 1, 2, 3, 4])
    let file = directory.appendingPathComponent(name); try data.write(to: file)
    return (file, try OneDriveOriginal.inspect(file))
}
private func expectFailure(_ label: String, _ action: () async throws -> Void) async throws {
    do { try await action() }
    catch is OneDriveFailure { return }
    catch is OAuthFailure { return }
    throw TestFailure.assertion("expected safe failure: " + label)
}

@main struct OneDriveTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CamLink-OneDrive-Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) } // Only this test-owned directory.
        try testConfigurationAndURLPolicy()
        try testRangesAndHashes()
        try await testChunkedUpload(directory)
        try await testResumeAnd416(directory)
        try await testHashFallbackAndMutation(directory)
        try await testRetryAndCancellation(directory)
        try await testDurableQueue(directory)
        try await testRealTransportGuards()
        print("OneDrive local injected tests passed. No remote login/upload was tested.")
    }
    static func testConfigurationAndURLPolicy() throws {
        let setup = OneDriveClientSetup(clientID: "16437f88-79e4-499f-8cb3-7f07c9146e0c")
        let config = try setup.configuration()
        try expect(config.authorizationEndpoint.path == "/common/oauth2/v2.0/authorize", "common authority")
        try expect(config.scopes.contains("offline_access") && config.scopes.contains("Files.ReadWrite"), "scopes")
        try expect(!config.scopes.contains("Files.ReadWrite.All"), "no full-drive escalation")
        for text in ["http://files.1drv.com/a", "https://files.1drv.com.evil.test/a", "https://127.0.0.1/a", "https://graph.microsoft.com/a", "https://u:p@files.1drv.com/a", "https://files.1drv.com:444/a", "https://files.1drv.com/a#x"] {
            do { try OneDriveURLPolicy.capability(URL(string: text)!); throw TestFailure.assertion("unsafe URL accepted") }
            catch is OneDriveFailure {} catch is OAuthFailure {}
        }
        try OneDriveURLPolicy.capability(URL(string: "https://tenant.sharepoint.com/path?authkey=test-only")!)
        let first = OneDriveGraphAPI.remoteName(original: "CAM.JPG", photoID: "p1", sha256: String(repeating: "a", count: 64))
        let second = OneDriveGraphAPI.remoteName(original: "CAM.JPG", photoID: "p2", sha256: String(repeating: "a", count: 64))
        try expect(first != second && first == OneDriveGraphAPI.remoteName(original: "CAM.JPG", photoID: "p1", sha256: String(repeating: "a", count: 64)), "deterministic unique names")
    }
    static func testRangesAndHashes() throws {
        let unit = Int64(320 * 1024)
        let ranges = try OneDriveGraphAPI.ranges(json(["nextExpectedRanges": ["\(unit)-"]]), total: unit * 3 + 1)
        try expect(ranges[0].start == unit && ranges[0].end == unit * 3, "exact resumed range")
        for value in [["1-"], ["-1-"], ["99999999999999999999999-"], ["0-20", "0-30"], ["0-9999999"]] {
            do {
                _ = try OneDriveGraphAPI.ranges(json(["nextExpectedRanges": value]), total: unit * 3)
                throw TestFailure.assertion("invalid range accepted")
            } catch is OneDriveFailure {}
        }
        try expect(OneDriveOriginal.hashMatches("ABCD", hex: "abcd"), "Graph hex SHA representation")
        try expect(OneDriveOriginal.hashMatches(Data([0xab, 0xcd]).base64EncodedString(), hex: "abcd"), "Base64 compatible SHA")
        try expect(!OneDriveOriginal.hashMatches("abcd-not-a-hash", hex: "abcd"), "malformed hash rejected")
    }
    static func testChunkedUpload(_ directory: URL) async throws {
        let (file, original) = try makeOriginal(directory, name: "chunks.jpg", size: 7 * 1024 * 1024)
        let name = "unique.jpg", chunk = OneDriveGraphAPI.chunkBytes
        let metadata = try json(remote(original: original, name: name, sha1: original.sha1.uppercased()))
        let http = ScriptHTTP { request, bearer, _ in
            let path = request.url!.path, method = request.httpMethod ?? "GET"
            if path.contains("createUploadSession") {
                try expect(bearer == "token", "Graph bearer")
                let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let item = object["item"] as! [String: Any]
                try expect(item["@microsoft.graph.conflictBehavior"] as? String == "fail", "no overwrite")
                return OneDriveHTTPReply(status: 200, data: try json(["uploadUrl": "https://up.1drv.com/upload-test", "expirationDateTime": future]))
            }
            if method == "PUT" {
                try expect(bearer == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "NO bearer at upload URL")
                let text = request.value(forHTTPHeaderField: "Content-Range")!
                let start = Int64(text.split(separator: " ")[1].split(separator: "-")[0])!
                let count = Int64(request.httpBody!.count)
                try expect(count <= chunk, "bounded chunk")
                if start + count < original.bytes {
                    try expect(count % (320 * 1024) == 0, "320KiB aligned nonfinal range")
                    return OneDriveHTTPReply(status: 202, data: try json(["nextExpectedRanges": ["\(start + count)-"], "expirationDateTime": future]))
                }
                return OneDriveHTTPReply(status: 201, data: metadata)
            }
            if path.contains(":/unique.jpg") { return OneDriveHTTPReply(status: 404, data: Data()) }
            return OneDriveHTTPReply(status: 200, data: metadata)
        }
        let progress = Checkpoints()
        let result = try await OneDriveGraphAPI(transport: http) { "token" }.upload(file: file, original: original,
            driveID: "drive", folderID: "folder", name: name, resume: nil) { await progress.add($0) }
        try expect(result.remoteID == "remote" && result.method == "server SHA-1", "cryptographic receipt")
        let seen = await http.records(), offsets = await progress.offsets()
        let puts = seen.filter { $0.method == "PUT" }
        try expect(puts.count == 3 && puts.reduce(0) { $0 + $1.bytes } == Int(original.bytes), "entire original incl appended MPF bytes")
        try expect(offsets == [0, chunk, chunk * 2, original.bytes], "durable progress callbacks")
    }
    static func testResumeAnd416(_ directory: URL) async throws {
        let (file, original) = try makeOriginal(directory, name: "resume.jpg", size: 5 * 1024 * 1024)
        let offset = OneDriveGraphAPI.chunkBytes
        let metadata = try json(remote(original: original, name: "resume.jpg", sha256: original.sha256))
        let http = ScriptHTTP { request, bearer, index in
            if request.url!.host == "up.1drv.com" {
                try expect(bearer == nil, "status GET no bearer")
                if request.httpMethod == "GET" {
                    return OneDriveHTTPReply(status: 200, data: try json(["nextExpectedRanges": ["\(offset)-"], "expirationDateTime": future]))
                }
                try expect(request.value(forHTTPHeaderField: "Content-Range")!.hasPrefix("bytes \(offset)-"), "resume from server not local guess")
                if index == 3 { return OneDriveHTTPReply(status: 416, data: Data()) }
                return OneDriveHTTPReply(status: 201, data: metadata)
            }
            if request.url!.path.contains(":/resume.jpg") { return OneDriveHTTPReply(status: 404, data: Data()) }
            return OneDriveHTTPReply(status: 200, data: metadata)
        }
        let checkpoint = Checkpoints()
        let capability = OneDriveUploadCapability(url: URL(string: "https://up.1drv.com/resume-test")!, expiresAt: Date().addingTimeInterval(3600))
        _ = try await OneDriveGraphAPI(transport: http) { "token" }.upload(file: file, original: original,
            driveID: "drive", folderID: "folder", name: "resume.jpg", resume: capability) { await checkpoint.add($0) }
        let seen = await http.records()
        try expect(!seen.contains { $0.method == "POST" }, "resume does not duplicate session")
        try expect(seen.filter { $0.method == "PUT" }.count == 2, "416 status reconciliation")
    }
    static func testHashFallbackAndMutation(_ directory: URL) async throws {
        let (_, original) = try makeOriginal(directory, name: "hash.jpg", size: 100)
        let wire = remote(original: original, name: "hash.jpg", download: true, quickXor: "not-a-cryptographic-hash")
        let item = try JSONDecoder().decode(OneDriveRemoteItem.self, from: json(wire))
        let stable = try json(wire)
        let http = ScriptHTTP(downloadValue: original) { _, _, _ in OneDriveHTTPReply(status: 200, data: stable) }
        let result = try await OneDriveGraphAPI(transport: http) { "token" }.verify(item, original: original,
            driveID: "drive", folderID: "folder", name: "hash.jpg")
        let downloads = await http.downloadCount()
        try expect(downloads == 1 && result.method == "full GET SHA-256", "quickXor requires full GET SHA256")
        let changed = try json(remote(original: original, name: "hash.jpg", download: true, etag: "changed"))
        let mutation = ScriptHTTP(downloadValue: original) { _, _, _ in OneDriveHTTPReply(status: 200, data: changed) }
        try await expectFailure("concurrent remote mutation") {
            _ = try await OneDriveGraphAPI(transport: mutation) { "token" }.verify(item, original: original,
                driveID: "drive", folderID: "folder", name: "hash.jpg")
        }
        let badItem = try JSONDecoder().decode(OneDriveRemoteItem.self,
            from: json(remote(original: original, name: "hash.jpg", sha1: String(repeating: "0", count: 40))))
        try await expectFailure("wrong SHA1 must fail, not fallback") {
            _ = try await OneDriveGraphAPI(transport: http) { "token" }.verify(badItem, original: original,
                driveID: "drive", folderID: "folder", name: "hash.jpg")
        }
        let wrongParent = try JSONDecoder().decode(OneDriveRemoteItem.self,
            from: json(remote(original: original, name: "hash.jpg", sha1: original.sha1, parent: "someone-else")))
        try await expectFailure("wrong parent") {
            _ = try await OneDriveGraphAPI(transport: http) { "token" }.verify(wrongParent, original: original,
                driveID: "drive", folderID: "folder", name: "hash.jpg")
        }
    }
    static func testRetryAndCancellation(_ directory: URL) async throws {
        let (file, original) = try makeOriginal(directory, name: "retry.jpg", size: 100)
        let http = ScriptHTTP { request, _, _ in
            if request.httpMethod == "POST" {
                return OneDriveHTTPReply(status: 200, data: try json(["uploadUrl": "https://up.1drv.com/retry-test", "expirationDateTime": future]))
            }
            if request.httpMethod == "PUT" { return OneDriveHTTPReply(status: 503, data: Data(), retryAfter: 13) }
            return OneDriveHTTPReply(status: 404, data: Data())
        }
        do {
            _ = try await OneDriveGraphAPI(transport: http) { "token" }.upload(file: file, original: original,
                driveID: "drive", folderID: "folder", name: "retry.jpg", resume: nil) { _ in }
            throw TestFailure.assertion("503 must not become a receipt")
        } catch let failure as OneDriveFailure {
            try expect(failure.retryable, "503 retry classification")
            if case let .http(status, retryAfter) = failure {
                try expect(status == 503 && retryAfter == 13, "Retry-After preserved")
            } else { throw TestFailure.assertion("expected HTTP failure") }
        }
        try expect(!OneDriveFailure.http(409, retryAfter: nil).retryable, "no blind conflict retries")
        let metadata = try json(remote(original: original, name: "cancel.jpg", sha1: original.sha1))
        let cancellationHTTP = ScriptHTTP { request, _, _ in
            if request.httpMethod == "POST" { return OneDriveHTTPReply(status: 200, data: try json(["uploadUrl": "https://up.1drv.com/cancel-test", "expirationDateTime": future])) }
            if request.httpMethod == "PUT" { return OneDriveHTTPReply(status: 201, data: metadata) }
            return OneDriveHTTPReply(status: 404, data: Data())
        }
        try await expectFailure("checkpoint cancellation before PUT") {
            _ = try await OneDriveGraphAPI(transport: cancellationHTTP) { "token" }.upload(file: file, original: original,
                driveID: "drive", folderID: "folder", name: "cancel.jpg", resume: nil) { _ in throw OneDriveFailure.cancelled }
        }
        let seen = await cancellationHTTP.records()
        try expect(!seen.contains { $0.method == "PUT" }, "failed durable checkpoint must stop bytes")
    }
    @MainActor static func testDurableQueue(_ directory: URL) async throws {
        let documents = directory.appendingPathComponent("Documents", isDirectory: true)
        let state = directory.appendingPathComponent("State", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let (file, original) = try makeOriginal(documents, name: "queue.jpg", size: 100)
        let setup = OneDriveClientSetup(clientID: "16437f88-79e4-499f-8cb3-7f07c9146e0c")
        let account = OneDriveAccount(setup: setup, id: "account", displayName: "Test", email: "", driveID: "drive", driveName: "Test Drive", rootID: "root")
        let folder = OneDriveFolder(id: "folder", name: "Folder", driveID: "drive")
        struct Snapshot: Encodable {
            let version = 1
            let setup: OneDriveClientSetup
            let account: OneDriveAccount
            let selectedFolder: OneDriveFolder
            let jobs: [OneDriveJob] = []
            let autoUpload = false
            let wifiOnly = false
            let paused = true
        }
        let stateFile = state.appendingPathComponent("onedrive-v1.json")
        try JSONEncoder().encode(Snapshot(setup: setup, account: account, selectedFolder: folder)).write(to: stateFile)
        let vault = MemoryOAuthVault(), sessions = MemorySessions()
        try await vault.save(OAuthToken(accessToken: "token", refreshToken: "refresh", expiresAt: Date().addingTimeInterval(3600)), for: account.credentialKey)
        let coordinator = OAuthCoordinator(browser: NoBrowser(), vault: vault)
        let photo = ReceivedJPEG(id: "photo", name: "queue.jpg", url: file, bytes: original.bytes, sha256: original.sha256, createdAt: Date(), uploaded: true)
        let remoteName = OneDriveGraphAPI.remoteName(original: photo.name, photoID: photo.id, sha256: original.sha256)
        let metadata = try json(remote(original: original, name: remoteName, sha1: original.sha1))
        let http = ScriptHTTP { request, _, _ in
            if request.httpMethod == "POST" { return OneDriveHTTPReply(status: 200, data: try json(["uploadUrl": "https://up.1drv.com/queue-test", "expirationDateTime": future])) }
            if request.httpMethod == "PUT" { return OneDriveHTTPReply(status: 201, data: metadata) }
            if request.url!.path.contains(":/") { return OneDriveHTTPReply(status: 404, data: Data()) }
            return OneDriveHTTPReply(status: 200, data: metadata)
        }
        let store = OneDriveStore(coordinator: coordinator, setup: setup, rootDirectory: documents,
            stateDirectory: state, transport: http, sessionVault: sessions, monitorNetwork: false)
        try expect(!store.autoUpload && store.paused, "safe defaults/restored pause")
        let count = try await store.enqueue([photo], albumName: "Album")
        let repeated = try await store.enqueue([photo], albumName: "Album")
        try expect(count == 1 && repeated == 0 && store.jobs.count == 1, "durable duplicate prevention independent PC uploaded")
        var callbacks = 0
        store.onVerified = { receipt in callbacks += 1; precondition(receipt.sha256 == original.sha256) }
        await store.resume()
        try expect(store.verifiedCount == 1 && callbacks == 1 && store.receipts.count == 1, "only verified durable receipt triggers callback")
        let networkCount = await http.records().count
        _ = try await store.enqueue([photo], albumName: "Renamed album")
        await store.pump()
        let repeatedNetworkCount = await http.records().count
        try expect(networkCount == repeatedNetworkCount, "repeat pump never duplicates old completed upload")
        let snapshotData = try Data(contentsOf: stateFile)
        let snapshotText = String(decoding: snapshotData, as: UTF8.self)
        try expect(!snapshotText.contains("up.1drv.com") && !snapshotText.contains("refresh") && !snapshotText.contains("accessToken"), "no secrets/signed URLs in snapshot")
        let restored = OneDriveStore(coordinator: coordinator, setup: setup, rootDirectory: documents,
            stateDirectory: state, transport: http, sessionVault: sessions, monitorNetwork: false)
        try expect(restored.receipts == store.receipts, "receipt survives process restart")
        await restored.disconnect()
        try expect(restored.account == nil && restored.jobs.count == 1 && FileManager.default.fileExists(atPath: file.path), "disconnect preserves original and history")
        try expect(OneDriveStore.retryDelay(attempt: 1) == 4 && OneDriveStore.retryDelay(attempt: 5, serverSeconds: 30) == 64,
                   "bounded retry with server floor")
    }
    static func testRealTransportGuards() async throws {
        let transport = OneDriveURLSessionTransport(deadline: 0.05)
        try await expectFailure("no bearer to capability host") {
            _ = try await transport.send(URLRequest(url: URL(string: "https://files.1drv.com/no-network")!), bearer: "token")
        }
        var injected = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me")!)
        injected.setValue("Bearer should-not-be-forwarded", forHTTPHeaderField: "Authorization")
        let request = injected
        try await expectFailure("no manual authorization bypass") { _ = try await transport.send(request, bearer: nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneDriveMockURLProtocol.self]
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let real = OneDriveURLSessionTransport(session: session, deadline: 0.5)
        let api = URL(string: "https://graph.microsoft.com/v1.0/me")!
        OneDriveMockURLProtocol.install { _ in .init(data: Data("{}".utf8)) }
        let reply = try await real.send(URLRequest(url: api), bearer: "TOKEN_test")
        try expect(reply.status == 200, "real URLSession injected response")
        try expect(OneDriveMockURLProtocol.requests().first?.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN_test", "bearer header limited to Graph")
        for destination in ["https://evil.test/sink", "https://graph.microsoft.com/v1.0/sink"] {
            OneDriveMockURLProtocol.install { _ in .init(status: 302, redirect: URL(string: destination)!) }
            try await expectFailure("real redirect refusal") { _ = try await real.send(URLRequest(url: api), bearer: "TOKEN_test") }
            try expect(OneDriveMockURLProtocol.requests().count == 1, "no bearer to redirect sink")
        }
        OneDriveMockURLProtocol.install { _ in .init(data: Data("{}".utf8), delay: 2) }
        try await expectFailure("whole request deadline") { _ = try await real.send(URLRequest(url: api), bearer: "TOKEN_test") }
    }
}
