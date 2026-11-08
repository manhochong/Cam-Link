import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// This executable uses production GoogleDriveHTTP/API/Uploader with a real injected
// URLSession. URLProtocol traps EVERY URL: no Google login or remote writes occur.
private struct DriveTestFailure: Error, CustomStringConvertible { let description: String }
private final class DriveProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var data = Data()
        var error: Error?
        var redirect: URL?
    }
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply)?
    private static var captured: [URLRequest] = []
    static func install(_ handler: @escaping (URLRequest) -> Reply) {
        lock.lock(); defer { lock.unlock() }; self.handler = handler; captured = []
    }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); let respond = Self.handler; Self.lock.unlock()
        let reply = respond?(request) ?? Reply(status: 599)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: reply.status,
            httpVersion: "HTTP/1.1", headerFields: reply.headers) else { return }
        if let target = reply.redirect {
            var next = request; next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var output = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; output.append(contentsOf: buffer.prefix(count))
        }
        return output
    }
}

private actor DriveResumeMemory: GoogleDriveResumeVault {
    private var entries: [String: URL] = [:]
    func load(_ key: String) async throws -> URL? { entries[key] }
    func save(_ url: URL, key: String) async throws { entries[key] = url }
    func delete(_ key: String) async throws { entries.removeValue(forKey: key) }
}

@MainActor
private final class DriveTestAuth: GoogleDriveAuthenticating {
    var user = "sdk_fixture_A"
    var calls = 0
    var signouts = 0
    var error: Error?
    var suspendFresh = false
    var freshStarted = false
    var freshCancelled = false
    func authorization() throws -> GoogleDriveAuthorization {
        calls += 1
        if let error = error { throw error }
        return GoogleDriveAuthorization(sdkUserID: user, token: OAuthToken(accessToken: "fixture_token_only",
            expiresAt: Date().addingTimeInterval(3600), scope: GoogleDriveAPI.scope))
    }
    func signIn(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization { try authorization() }
    func restore(setup: GoogleDriveClientSetup) async throws -> GoogleDriveAuthorization { try authorization() }
    func fresh(setup: GoogleDriveClientSetup, expectedUserID: String) async throws -> GoogleDriveAuthorization {
        guard user == expectedUserID else { throw GoogleDriveFailure.accountChanged }
        if suspendFresh {
            freshStarted = true
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { freshCancelled = true; throw error }
        }
        return try authorization()
    }
    func signOut(setup: GoogleDriveClientSetup, expectedUserID: String?) async throws { signouts += 1 }
    func handle(_ url: URL) -> Bool { false }
}

/// A strict in-memory Drive server; checks wire bytes, range, bearer, POST-only create
/// and persist-before-POST. Synthetic content is NOT asserted to be a valid JPEG/MPF.
private final class DriveServer: @unchecked Sendable {
    enum Mode: Equatable { case normal, partial, lostFinal, wrongHash, noHashes, corruptDownload, conflict, expired }
    let lock = NSRecursiveLock()
    let original: Data
    let job: GoogleDriveJob
    let mode: Mode
    let location = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=fixture_capability")!
    var received = Data()
    var complete = false
    var beginCount = 0
    var probeCount = 0
    var getCount = 0
    var offsets: [Int64] = []
    var checkpointRemote = false
    var fault: String?
    var accountID = "permission_A"
    var nextID = 0
    var remoteID = "file_fixture"
    var remoteFolder: String
    var remoteName: String
    var remoteKey: String
    var createdFolders: [String: [String: Any]] = [:]
    var failureStatus: Int?
    var limitReason = false
    init(original: Data, job: GoogleDriveJob, mode: Mode = .normal) {
        self.original = original; self.job = job; self.mode = mode
        remoteFolder = job.folderID; remoteName = job.name; remoteKey = job.id
        if mode == .conflict { complete = true }
    }
    func checkpoint(_ value: GoogleDriveJob) { lock.lock(); defer { lock.unlock() }; checkpointRemote = !value.remoteID.isEmpty }
    func setComplete(_ data: Data) { lock.lock(); defer { lock.unlock() }; received = data; complete = true }
    func respond(_ request: URLRequest) -> DriveProtocol.Reply {
        lock.lock(); defer { lock.unlock() }
        func json(_ object: Any, status: Int = 200) -> DriveProtocol.Reply {
            DriveProtocol.Reply(status: status, headers: ["Content-Type": "application/json"],
                data: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
        }
        guard let url = request.url, url.host == "www.googleapis.com" else {
            fault = "untrusted URL was requested"; return json([:], status: 599)
        }
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture_token_only" else {
            fault = "missing or invalid bearer"; return json([:], status: 401)
        }
        let method = request.httpMethod ?? "GET"
        if ["PATCH", "DELETE"].contains(method) { fault = "remote mutation forbidden"; return json([:], status: 599) }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let alt = query.first { $0.name == "alt" }?.value
        if url.path == "/drive/v3/about" {
            return json(["user": ["permissionId": accountID, "displayName": "Fixture Person", "emailAddress": "fixture@invalid.test"]])
        }
        if url.path == "/drive/v3/files/generateIds" {
            nextID += 1; return json(["ids": [nextID == 1 ? "file_fixture" : "generated_\(nextID)"]])
        }
        if url.path == "/drive/v3/files", method == "GET" {
            return json(["files": [["id": "folder_A", "name": "Cam Link", "mimeType": GoogleDriveAPI.folderType,
                "trashed": false, "capabilities": ["canAddChildren": true]]]])
        }
        if url.path == "/drive/v3/files", method == "POST" {
            guard let meta = try? JSONSerialization.jsonObject(with: DriveProtocol.body(request)) as? [String: Any],
                  let id = meta["id"] as? String else { fault = "folder lacks pre-generated ID"; return json([:], status: 400) }
            if createdFolders[id] != nil { return json([:], status: 409) }
            createdFolders[id] = meta
            return json(folder(id, metadata: meta), status: 201)
        }
        if url.path == "/drive/v3/files/folder_A" { return json(folder("folder_A")) }
        if url.path.hasPrefix("/drive/v3/files/"), let meta = createdFolders[url.lastPathComponent] {
            return json(folder(url.lastPathComponent, metadata: meta))
        }
        if url.path == "/drive/v3/files/" + remoteID, alt == "media" {
            getCount += 1
            var body = original
            if mode == .corruptDownload { body[body.count - 1] ^= 0xff }
            return DriveProtocol.Reply(status: 200, headers: ["Content-Length": String(body.count)], data: body)
        }
        if url.path.hasPrefix("/drive/v3/files/"), method == "GET" {
            guard complete && url.lastPathComponent == remoteID else { return json([:], status: 404) }
            return json(metadata())
        }
        if url.path == "/upload/drive/v3/files", method == "POST" {
            beginCount += 1
            if !checkpointRemote { fault = "remote ID not persisted before POST" }
            if let status = failureStatus {
                return json(["error": ["errors": [["reason": limitReason ? "userRateLimitExceeded" : "forbidden"]]]], status: status)
            }
            guard let meta = try? JSONSerialization.jsonObject(with: DriveProtocol.body(request)) as? [String: Any],
                  let id = meta["id"] as? String, let parents = meta["parents"] as? [String], parents.count == 1,
                  parents[0] == job.folderID || createdFolders[parents[0]] != nil,
                  let name = meta["name"] as? String, let properties = meta["appProperties"] as? [String: String],
                  let key = properties["camlinkKey"], properties["sha256"] == job.sha256,
                  request.value(forHTTPHeaderField: "X-Upload-Content-Length") == String(original.count) else {
                fault = "wrong begin metadata"; return json([:], status: 400)
            }
            remoteID = id; remoteFolder = parents[0]; remoteName = name; remoteKey = key
            return DriveProtocol.Reply(status: 200, headers: ["Location": location.absoluteString])
        }
        if url.path == "/upload/drive/v3/files", method == "PUT" {
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            if range.hasPrefix("bytes */") {
                probeCount += 1
                if mode == .expired, probeCount == 1 { received = Data(); return json([:], status: 404) }
                if complete { return json(metadata()) }
                return DriveProtocol.Reply(status: 308, headers: received.isEmpty ? [:] : ["Range": "bytes=0-\(received.count - 1)"])
            }
            let body = DriveProtocol.body(request)
            let expected = "bytes \(received.count)-\(received.count + body.count - 1)/\(original.count)"
            guard range == expected, !body.isEmpty, received.count + body.count <= original.count,
                  body == original.subdata(in: received.count..<(received.count + body.count)) else {
                fault = "wrong original chunk bytes or Content-Range"; return json([:], status: 400)
            }
            offsets.append(Int64(received.count))
            if mode == .partial, offsets.count == 1, body.count > 256 * 1024 { received.append(body.prefix(256 * 1024)) }
            else { received.append(body) }
            if received.count == original.count {
                complete = true
                if mode == .lostFinal { return DriveProtocol.Reply(error: URLError(.networkConnectionLost)) }
                return json(metadata(), status: 201)
            }
            return DriveProtocol.Reply(status: 308, headers: ["Range": "bytes=0-\(received.count - 1)"])
        }
        fault = "unexpected request path or method"; return json([:], status: 599)
    }
    private func folder(_ id: String, metadata: [String: Any]? = nil) -> [String: Any] {
        var result: [String: Any] = ["id": id, "name": metadata?["name"] ?? "Cam Link",
            "mimeType": GoogleDriveAPI.folderType, "trashed": false, "capabilities": ["canAddChildren": true]]
        if let metadata = metadata {
            result["parents"] = metadata["parents"] ?? ["root"]
            result["appProperties"] = metadata["appProperties"]
        }
        return result
    }
    private func metadata() -> [String: Any] {
        var result: [String: Any] = ["id": remoteID, "name": remoteName, "size": String(original.count),
            "mimeType": "image/jpeg", "trashed": false, "parents": [mode == .conflict ? "wrong_parent" : remoteFolder],
            "appProperties": ["camlinkKey": remoteKey, "sha256": job.sha256], "capabilities": ["canDownload": true]]
        if mode != .noHashes && mode != .corruptDownload {
            result["md5Checksum"] = GoogleDriveValidation.hex(Insecure.MD5.hash(data: original))
            result["sha256Checksum"] = mode == .wrongHash ? String(repeating: "0", count: 64) : job.sha256
        }
        return result
    }
}

@main
@MainActor
private enum GoogleDriveTests {
    private static var checks = 0
    static func check(_ value: Bool, _ name: String) throws {
        checks += 1
        if !value { throw DriveTestFailure(description: "FAIL: " + name) }
    }
    static func rejects(_ name: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch is DriveTestFailure { throw DriveTestFailure(description: name + ": fixture assertion failed") }
        catch { checks += 1; return }
        throw DriveTestFailure(description: "FAIL: expected rejection: " + name)
    }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DriveProtocol.self]; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        return URLSession(configuration: config)
    }
    static func job(_ data: Data) -> GoogleDriveJob {
        let sha = GoogleDriveValidation.hex(SHA256.hash(data: data))
        return GoogleDriveJob(id: GoogleDriveValidation.jobID(client: "1234-fixture.apps.googleusercontent.com",
            sdk: "sdk_fixture_A", account: "permission_A", folder: "folder_A", photo: "photo_A", sha: sha),
            clientID: "1234-fixture.apps.googleusercontent.com", sdkUserID: "sdk_fixture_A", accountID: "permission_A",
            folderID: "folder_A", folderName: "Cam Link", photoID: "photo_A", name: "DSC_0001.JPG", albumName: "Activity",
            localRelativePath: "sessions/original.JPG", bytes: Int64(data.count), sha256: sha, createdAt: Date())
    }
    static func uploader(_ server: DriveServer, vault: DriveResumeMemory, session: URLSession) throws -> GoogleDriveUploader {
        DriveProtocol.install { server.respond($0) }
        return try GoogleDriveUploader(api: GoogleDriveAPI(http: GoogleDriveHTTP(session: session), token: { "fixture_token_only" }),
            resumeVault: vault, chunkSize: 512 * 1024)
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CamLink-DriveTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) } // Only this executable's own temporary fixture tree.
        var data = Data((0..<1_100_007).map { UInt8($0 % 251) })
        data[0] = 0xff; data[1] = 0xd8
        // Primary-image EOI followed by synthetic auxiliary bytes. This only verifies
        // preservation of a previously ingested original, not JPEG parser correctness.
        data.replaceSubrange((data.count - 8)..<data.count, with: [0xff, 0xd9, 0x4d, 0x50, 0x46, 0x00, 0x01, 0x02])
        let file = root.appendingPathComponent("sessions/original.JPG"); try data.write(to: file)
        let original = job(data)
        let hashes = try await GoogleDriveOriginal.hash(file, expected: Int64(data.count))
        try check(hashes.sha == original.sha256, "whole-file SHA includes all auxiliary MPF bytes")
        try check(hashes.md5 == GoogleDriveValidation.hex(Insecure.MD5.hash(data: data)), "whole-file MD5")
        try await rejects("wrong local size") { _ = try await GoogleDriveOriginal.hash(file, expected: 4) }
        try await rejects("blank client setup before network") { _ = try GoogleDriveClientSetup().validate() }
        let setup = GoogleDriveClientSetup(clientID: original.clientID,
            redirectURI: "com.googleusercontent.apps.1234-fixture:/oauth2callback")
        try check(try setup.validate() == "com.googleusercontent.apps.1234-fixture", "SDK exact callback")
        try await rejects("callback suffix mismatch") {
            _ = try GoogleDriveClientSetup(clientID: original.clientID,
                redirectURI: "com.googleusercontent.apps.1234-fixture:/other").validate()
        }
        try await rejects("hostile upload capability") {
            try GoogleDriveHTTP.validate(URL(string: "https://attacker.invalid/upload/drive/v3/files?upload_id=fixture")!, uploadOnly: true)
        }
        try await rejects("out of bounds server acknowledgement") { _ = try GoogleDriveAPI.acknowledged("bytes=0-999", size: 100) }
        try check(try GoogleDriveAPI.acknowledged(nil, size: original.bytes) == 0, "absent range means zero received")
        try check(try GoogleDriveAPI.acknowledged("bytes=0-42", size: original.bytes) == 43, "next byte uses zero-based Range")

        for mode in [DriveServer.Mode.normal, .partial] {
            let server = DriveServer(original: data, job: original, mode: mode)
            let vault = DriveResumeMemory(); let network = session(); defer { network.invalidateAndCancel() }
            let upload = try uploader(server, vault: vault, session: network)
            let result = try await upload.transfer(original, source: file) { server.checkpoint($0) }
            try check(result.offset == original.bytes && result.verification != nil, "completion requires remote metadata proof")
            try check(server.received == data, "wire bytes include complete auxiliary data without re-encoding")
            try check(server.beginCount == 1 && server.fault == nil, "persisted ID before single create")
            if mode == .partial { try check(server.offsets.dropFirst().first == 256 * 1024, "partial 308 ack overrides bytes presumed sent") }
            let retained = try await vault.load(result.id)
            try check(retained == nil, "verified completion removes only own secret resume URI")
        }
        // Cold resume starts with a probe and uses the server's acknowledged offset.
        do {
            let server = DriveServer(original: data, job: original)
            server.received = Data(data.prefix(256 * 1024)); server.checkpointRemote = true
            let vault = DriveResumeMemory(); try await vault.save(server.location, key: original.id)
            var pending = original; pending.remoteID = "file_fixture"; pending.offset = 512 * 1024
            let network = session(); defer { network.invalidateAndCancel() }
            let upload = try uploader(server, vault: vault, session: network)
            let result = try await upload.transfer(pending, source: file) { server.checkpoint($0) }
            try check(server.probeCount == 1 && server.beginCount == 0, "restart probes existing resumable session")
            try check(server.offsets.first == 256 * 1024, "restart ignores optimistic saved offset")
            try check(result.verification != nil && server.received == data, "resume authenticates full metadata and bytes")
        }
        do {
            let server = DriveServer(original: data, job: original, mode: .expired)
            let vault = DriveResumeMemory(); try await vault.save(server.location, key: original.id)
            var pending = original; pending.remoteID = "file_fixture"; pending.offset = 256 * 1024
            let network = session(); defer { network.invalidateAndCancel() }
            let upload = try uploader(server, vault: vault, session: network)
            let result = try await upload.transfer(pending, source: file) { server.checkpoint($0) }
            try check(server.probeCount == 1 && server.beginCount == 1 && server.offsets.first == 0,
                "expired 404 session restarts with same persisted remote ID")
            try check(result.remoteID == "file_fixture" && result.verification != nil, "expired session does not allocate duplicate file")
        }
        do {
            let server = DriveServer(original: data, job: original, mode: .lostFinal)
            let vault = DriveResumeMemory(); let network = session(); defer { network.invalidateAndCancel() }
            let upload = try uploader(server, vault: vault, session: network)
            var checkpoint = original
            try await rejects("lost final response is not treated as success") {
                _ = try await upload.transfer(original, source: file) { checkpoint = $0; server.checkpoint($0) }
            }
            let result = try await upload.transfer(checkpoint, source: file) { server.checkpoint($0) }
            try check(server.beginCount == 1 && result.verification != nil, "uncertain final is resolved by existing ID and hashes, not duplicate POST")
        }
        for mode in [DriveServer.Mode.wrongHash, .conflict] {
            let server = DriveServer(original: data, job: original, mode: mode)
            let vault = DriveResumeMemory(); let network = session(); defer { network.invalidateAndCancel() }
            let upload = try uploader(server, vault: vault, session: network)
            try await rejects("200 and self-reported SHA cannot prove wrong content or parent") {
                _ = try await upload.transfer(original, source: file) { server.checkpoint($0) }
            }
            try check(server.fault == nil, "conflict detection needs no overwrite/delete")
            if mode == .conflict { try check(server.beginCount == 0, "existing ID with wrong parent is never overwritten") }
        }
        // Both branches execute real authenticated URLSession.download(for:) readback.
        for mode in [DriveServer.Mode.noHashes, .corruptDownload] {
            let server = DriveServer(original: data, job: original, mode: mode)
            server.setComplete(data)
            let vault = DriveResumeMemory(); let network = session(); defer { network.invalidateAndCancel() }
            let upload = try uploader(server, vault: vault, session: network)
            var pending = original; pending.remoteID = "file_fixture"
            if mode == .noHashes {
                let result = try await upload.transfer(pending, source: file) { server.checkpoint($0) }
                try check(result.verification?.contains("GET") == true, "missing API hashes require complete authenticated GET")
            } else {
                try await rejects("self-reported SHA with corrupt download") {
                    _ = try await upload.transfer(pending, source: file) { server.checkpoint($0) }
                }
            }
            try check(server.getCount == 1 && server.beginCount == 0, "fallback reads remote file and never recreates it")
        }
        do {
            let server = DriveServer(original: data, job: original)
            let network = session(); defer { network.invalidateAndCancel() }
            let upload = try uploader(server, vault: DriveResumeMemory(), session: network)
            let cancelled = Task { try await upload.transfer(original, source: file) { server.checkpoint($0) } }
            cancelled.cancel()
            try await rejects("cancelled upload never completes a verified receipt") { _ = try await cancelled.value }
            try check(server.beginCount == 0 && FileManager.default.fileExists(atPath: file.path), "pre-cancel preserves original and performs no create")
        }
        // Actual URL loading redirect callback: per-task delegate must stop the sink.
        do {
            let network = session(); defer { network.invalidateAndCancel() }
            DriveProtocol.install { request in
                DriveProtocol.Reply(status: 302, headers: ["Location": "https://sink.invalid/leak"],
                    redirect: URL(string: "https://sink.invalid/leak"))
            }
            let http = GoogleDriveHTTP(session: network)
            try await rejects("bearer redirect rejected") {
                _ = try await http.raw(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about")!), token: "fixture_token_only")
            }
            try check(!DriveProtocol.requests().contains { $0.url?.host == "sink.invalid" }, "redirect sink received no request")
            DriveProtocol.install { _ in DriveProtocol.Reply(status: 200, headers: ["Location": "https://sink.invalid/upload"]) }
            try await rejects("hostile initiation Location rejected") {
                _ = try await http.raw(URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files")!), token: "fixture_token_only")
            }
            DriveProtocol.install { _ in DriveProtocol.Reply(status: 308, headers: ["Range": "bytes=0-42", "Location": "https://www.googleapis.com/upload/drive/v3/files"]) }
            try await rejects("308 with Location is redirect, not an acknowledgement") {
                _ = try await http.raw(URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files")!), token: "fixture_token_only", resumable: true)
            }
        }
        // Rate-limited 403 and arbitrary provider text produce fixed, redacted errors.
        do {
            let network = session(); defer { network.invalidateAndCancel() }
            DriveProtocol.install { _ in DriveProtocol.Reply(status: 403, data: Data("{\"error\":{\"message\":\"fixture_secret_do_not_echo\",\"errors\":[{\"reason\":\"userRateLimitExceeded\"}]}}".utf8)) }
            do {
                _ = try await GoogleDriveHTTP(session: network).raw(URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about")!), token: "fixture_token_only")
                throw DriveTestFailure(description: "expected 403")
            } catch let failure as GoogleDriveFailure {
                try check(failure.retryable, "403 rate-limit reason is retryable")
                try check(!GoogleDriveFailure.message(failure).contains("fixture_secret"), "server payload is not exposed")
            }
        }
        try await storeTests(root: root, file: file, data: data, original: original)
        try check(try Data(contentsOf: file) == data, "tests never changed original bytes")
        print("GoogleDriveTests: \(checks) checks passed (injected HTTP only; no live account tests).")
    }

    private static func storeTests(root: URL, file: URL, data: Data, original: GoogleDriveJob) async throws {
        let network = session(); defer { network.invalidateAndCancel() }
        let server = DriveServer(original: data, job: original)
        DriveProtocol.install { server.respond($0) }
        let auth = DriveTestAuth(); let vault = DriveResumeMemory()
        var settings = OAuthPublicClientSettings(); settings.googleIOSClientID = original.clientID
        let blankAuth = DriveTestAuth()
        let blank = GoogleDriveStore(documentsURL: root.appendingPathComponent("blank-client-fixture"),
            settings: OAuthPublicClientSettings(), auth: blankAuth,
            http: GoogleDriveHTTP(session: network), resumeVault: vault, monitorsNetwork: false)
        await blank.signIn()
        try check(blankAuth.calls == 0 && DriveProtocol.requests().isEmpty, "blank public setup fails before SDK or HTTP")
        let store = GoogleDriveStore(documentsURL: root, settings: settings, auth: auth,
            http: GoogleDriveHTTP(session: network), resumeVault: vault, monitorsNetwork: false)
        try check(!store.autoUpload && !store.signedInReady, "automatic admission disabled by default")
        await store.signIn()
        try check(store.account?.permissionID == "permission_A" && store.signedInReady, "profile is from actual REST response, not invented email")
        await store.browseFolders()
        try check(store.folders.map(\.id) == ["folder_A"], "app-visible folders load through real HTTP boundary")
        await store.selectFolder(GoogleDriveFolder(id: "folder_A", name: "ignored untrusted label"))
        try check(store.selectedFolder?.name == "Cam Link", "selectFolder fetches permissions and trusted name")
        let photo = ReceivedJPEG(id: "photo_A", name: original.name, url: file, bytes: original.bytes,
            sha256: original.sha256, createdAt: Date(), uploaded: true)
        DriveProtocol.install { _ in DriveProtocol.Reply(status: 503) }
        await store.enqueue([photo], albumName: "Event A")
        await store.enqueue([photo], albumName: "Event A")
        try check(DriveProtocol.requests().isEmpty, "offline admission performs no folder/network request")
        try check(store.jobs.count == 1 && store.jobs[0].albumFolderPending == true, "album target and photo are durable and idempotent before upload")
        try check(photo.uploaded, "Drive never clears or relies on PC uploaded receipt")
        let saved = try Data(contentsOf: root.appendingPathComponent("google-drive-jobs-v1.json"))
        let text = String(decoding: saved, as: UTF8.self)
        try check(!text.contains("fixture_token_only") && !text.contains("upload_id") && !text.contains("refreshToken"), "durable JSON contains no token or resumable URI")
        let report = String(decoding: try store.diagnosticsJSON(), as: UTF8.self)
        try check(!report.contains("fixture@invalid.test") && !report.contains(root.path) && !report.contains("localRelativePath"), "diagnostics omit email and local source path")
        DriveProtocol.install { server.respond($0) }; server.checkpointRemote = true
        // A direct async pump is tracked even while its first profile request awaits auth.
        auth.suspendFresh = true
        let activePump = Task { await store.pump() }
        for _ in 0..<1000 {
            if auth.freshStarted { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try check(auth.freshStarted, "policy fixture reached actual direct-pump worker")
        store.setPolicyBlocked(true)
        await activePump.value
        try check(auth.freshCancelled && !store.paused && store.jobs[0].state == .pending,
            "runtime policy cancels actual worker without persisting user pause or receipt")
        auth.suspendFresh = false
        await store.pump()
        try check(DriveProtocol.requests().isEmpty, "blocked manual pump performs no HTTP")
        let blockedSnapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("google-drive-jobs-v1.json"))) as! [String: Any]
        try check(blockedSnapshot["paused"] as? Bool == false && blockedSnapshot["policyBlocked"] == nil,
            "runtime block is transient and leaves saved user pause unchanged")
        store.pause()
        store.setPolicyBlocked(false)
        await store.pump()
        try check(store.paused && DriveProtocol.requests().isEmpty, "policy recovery never resumes a user-paused queue")
        store.setPolicyBlocked(true)
        store.resumePending() // Explicit user resume cannot bypass runtime policy.
        await store.pump()
        try check(!store.paused && DriveProtocol.requests().isEmpty, "explicit resume remains gated while policy blocked")
        store.setPolicyBlocked(false)
        await store.pump()
        try check(store.verifiedCount == 1 && store.jobs[0].albumFolderPending == false,
            "production store pump resolves album folder and verifies original through injected real HTTP")
        try check(store.jobs[0].albumParentID == "folder_A" && store.jobs[0].folderID != "folder_A",
            "resolved album receipt retains immutable parent binding")
        try check(server.received == data && server.fault == nil, "production store pump sends full original only")
        store.pause()
        let restoredAuth = DriveTestAuth()
        let restored = GoogleDriveStore(documentsURL: root, settings: settings, auth: restoredAuth,
            http: GoogleDriveHTTP(session: network), resumeVault: vault, monitorsNetwork: false)
        try check(restored.jobs.count == 1 && restored.paused && !restored.signedInReady, "cold launch preserves queue and pause but does not pretend SDK is signed in")
        DriveProtocol.install { server.respond($0) }
        await restored.restoreSignIn()
        try check(restored.signedInReady && restored.account?.permissionID == "permission_A", "restore checks SDK user and Drive permission identity")
        restoredAuth.user = "sdk_fixture_B"; server.accountID = "permission_B"
        await restored.signIn()
        try check(restored.selectedFolder == nil && !restored.autoUpload && restored.oldJobsCount == 1, "account switch does not retarget or auto-upload old jobs")
        await restored.selectFolder(GoogleDriveFolder(id: "folder_A", name: "Cam Link"))
        await restored.enqueue([photo], albumName: "Event A")
        try check(restored.jobs.count == 2 && restored.activeJobs.count == 1, "same original has independent account-specific jobs")
        let activeID = restored.activeJobs[0].id
        restored.cancelJob(activeID)
        try check(restored.activeJobs[0].state == .cancelled, "cancel marks local job only")
        restored.retryFailed()
        try check(restored.activeJobs[0].state == .pending && restored.activeJobs[0].attempts == 0, "explicit retry safely reuses cancelled job identity")
        try await restored.disconnect()
        try check(restored.account == nil && !restored.autoUpload && restored.jobs.count == 2 && restoredAuth.signouts == 1,
            "disconnect clears only local connection, preserves all original jobs")
        try check(FileManager.default.fileExists(atPath: file.path), "signout and cancel keep original")
        // Reused photo IDs across albums must not widen a selected-photo retry.
        let retryRoot = root.appendingPathComponent("scoped-retry-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: retryRoot.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try data.write(to: retryRoot.appendingPathComponent("sessions/original.JPG"))
        try data.write(to: retryRoot.appendingPathComponent("sessions/other.JPG"))
        func exhausted(_ photoID: String, _ path: String, _ album: String, account: String = "permission_A") -> GoogleDriveJob {
            var job = GoogleDriveJob(id: GoogleDriveValidation.jobID(client: original.clientID, sdk: original.sdkUserID,
                account: account, folder: "folder_A", photo: photoID, sha: original.sha256, album: album),
                clientID: original.clientID, sdkUserID: original.sdkUserID, accountID: account,
                folderID: "folder_A", folderName: "Cam Link", photoID: photoID, name: original.name, albumName: album,
                localRelativePath: path, bytes: original.bytes, sha256: original.sha256, createdAt: Date(),
                albumParentID: "folder_A", albumFolderPending: true)
            job.state = .failed; job.attempts = 5; job.nextAttemptAt = .distantFuture; job.error = "fixture failure"
            return job
        }
        let retryJobs = [exhausted("photo_A", "sessions/original.JPG", "Selected"),
            exhausted("photo_A", "sessions/other.JPG", "Other album"),
            exhausted("photo_B", "sessions/original.JPG", "Other ID"),
            exhausted("photo_A", "sessions/original.JPG", "Old account", account: "permission_old")]
        var retrySnapshot = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        retrySnapshot["jobs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(retryJobs))
        try JSONSerialization.data(withJSONObject: retrySnapshot).write(to: retryRoot.appendingPathComponent("google-drive-jobs-v1.json"))
        let retryStore = GoogleDriveStore(documentsURL: retryRoot, settings: settings, auth: DriveTestAuth(),
            http: GoogleDriveHTTP(session: network), resumeVault: vault, monitorsNetwork: false)
        let selectedPhoto = ReceivedJPEG(id: "photo_A", name: original.name,
            url: retryRoot.appendingPathComponent("sessions/original.JPG"), bytes: original.bytes,
            sha256: original.sha256, createdAt: Date(), uploaded: true)
        retryStore.setPolicyBlocked(true)
        try check(retryStore.retryFailed(photos: []) == 0, "empty scoped retry is not retry-all")
        try check(retryStore.retryFailed(photos: [selectedPhoto]) == 1, "scoped retry matches both photo ID and full source path")
        try check(retryStore.jobs[0].state == .pending && retryStore.jobs[0].attempts == 0
            && retryStore.jobs[0].nextAttemptAt == .distantPast, "explicit selection resets exhausted retry budget")
        try check(retryStore.jobs.dropFirst().allSatisfy { $0.state == .failed && $0.attempts == 5 },
            "same ID at another path, other ID at same path, and old account remain exhausted")
        try check(retryStore.jobs.map(\.folderID) == retryJobs.map(\.folderID) && selectedPhoto.uploaded,
            "scoped retry preserves original destinations and independent PC receipt")
        let retryRestored = GoogleDriveStore(documentsURL: retryRoot, settings: settings, auth: DriveTestAuth(),
            http: GoogleDriveHTTP(session: network), resumeVault: vault, monitorsNetwork: false)
        try check(retryRestored.jobs[0].state == .pending && retryRestored.jobs[1].attempts == 5,
            "scoped retry selection is durable")
        // Corruption fails closed without replacing the user's durable queue.
        let corrupt = root.appendingPathComponent("corrupt-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        let corruptURL = corrupt.appendingPathComponent("google-drive-jobs-v1.json")
        let sentinel = Data("{not JSON}".utf8); try sentinel.write(to: corruptURL)
        let failedStore = GoogleDriveStore(documentsURL: corrupt, settings: settings, auth: DriveTestAuth(),
            http: GoogleDriveHTTP(session: network), resumeVault: vault, monitorsNetwork: false)
        await failedStore.signIn(); await failedStore.enqueue([photo]); await failedStore.uploadPending()
        try check(try Data(contentsOf: corruptURL) == sentinel && !failedStore.autoUpload && failedStore.account == nil,
            "corrupt snapshot is preserved and cannot start network uploads")
    }
}
