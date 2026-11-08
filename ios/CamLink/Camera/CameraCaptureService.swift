import AVFoundation
import Combine
import CoreGraphics
import CryptoKit
import Foundation
import ImageCaptureCore
import ImageIO
import UIKit
import UniformTypeIdentifiers

@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    enum ReceiveMode: String, CaseIterable, Identifiable {
        case newPhotos = "接收新拍 JPG"
        case card = "接收卡內 JPG"
        var id: String { rawValue }
    }

    @Published var status = "等待連接相機"
    @Published var cameraName = ""
    @Published var browsing = false
    @Published var connected = false
    @Published var catalogReady = false
    @Published var finishing = false
    @Published var lastError = ""
    @Published var authorization = "尚未要求授權"
    @Published var catalogCount = 0
    @Published var queuedCount = 0
    @Published var receivedCount = 0
    @Published var failedCount = 0
    @Published var logLines: [String] = []
    @Published var mode: ReceiveMode = .newPhotos

    var onJPEG: ((ReceivedJPEG) -> Void)?
    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var generation = UUID()
    private var known = Set<String>()
    private var failed = Set<String>()
    private var queue: [DownloadJob] = []
    private var active: DownloadJob?
    private var timer: Timer?
    private var began = Date()
    private var folder: URL

    private struct DownloadJob {
        let file: ICCameraFile
        let key: String
        let name: String
        let dest: URL
        let expectedSize: Int64
    }

    override init() {
        folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
    }

    func startBrowsing() {
        guard !browsing else { return }
        generation = UUID()
        let token = generation
        known.removeAll()
        failed.removeAll()
        queue.removeAll()
        active = nil
        lastError = ""
        catalogReady = false
        finishing = false
        receivedCount = 0
        failedCount = 0
        catalogCount = 0
        queuedCount = 0
        began = Date()
        browsing = true
        status = "正在要求相機存取權限…"
        record("START mode=\(mode.rawValue)")
        Task {
            var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            }
            guard token == self.generation, self.browsing else { return }
            self.record("CAMERA_PERMISSION \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
            guard allowed else {
                self.authorization = "相機權限未允許"
                self.fail("請在設定 → Cam Link 開啟相機權限，再重新連接。")
                self.browsing = false
                return
            }
            self.browser.requestContentsAuthorization { [weak self] auth in
                Task { @MainActor in
                    guard let self, token == self.generation, self.browsing else { return }
                    self.authorization = "相機已允許 · 內容授權 \(auth.rawValue)"
                    self.record("CONTENTS_AUTH \(auth.rawValue)")
                    guard auth == .authorized else {
                        self.fail("iPadOS 未允許外接相機內容存取。請到設定確認相機權限；若已允許，請匯出診斷。")
                        self.browsing = false
                        return
                    }
                    do {
                        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
                    } catch {
                        self.fail("無法建立 JPG 儲存資料夾：\(error.localizedDescription)")
                        self.browsing = false
                        return
                    }
                    self.status = "正在尋找 USB 相機…"
                    self.browser.start()
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.tick() }
                    }
                }
            }
        }
    }

    /// Stop only after all already-queued originals have completed; keep the cable connected.
    func finishReceiving() {
        guard browsing else { return }
        guard connected, catalogReady else { stopBrowsing(); return }
        finishing = true
        status = "正在完成接收，請保持相機連線…"
        record("DRAIN pending=\(queuedCount)")
        if active == nil, queue.isEmpty { stopBrowsing() }
    }

    func stopBrowsing() {
        generation = UUID()
        timer?.invalidate()
        timer = nil
        browser.stop()
        let oldCamera = camera
        camera = nil
        connected = false
        catalogReady = false
        browsing = false
        finishing = false
        cameraName = ""
        queue.removeAll()
        active = nil
        queuedCount = 0
        oldCamera?.requestCloseSession()
        status = "已停止接收"
        record("STOP")
    }

    func refreshContents() {
        guard let camera, browsing, connected, !finishing else { return }
        failed.removeAll()
        failedCount = 0
        lastError = ""
        record("MANUAL_RETRY")
        if !catalogReady, camera.contentCatalogPercentCompleted >= 100 {
            ready(camera)
        } else if catalogReady {
            ingest(camera)
        }
    }

    private func tick() {
        guard browsing, !finishing else { return }
        if let camera, connected {
            if !catalogReady, camera.contentCatalogPercentCompleted >= 100 { ready(camera) }
            else if catalogReady { ingest(camera) }
        } else if camera == nil, Date().timeIntervalSince(began) > 15 {
            status = "未偵測到可用 USB 相機"
            if lastError.isEmpty {
                lastError = "請確認相機開機、USB 資料線及 USB 模式。若 iPad「照片」也無法匯入，請先檢查線材／轉接器；若它能匯入而本 App 不能，請匯出診斷。"
                record("DISCOVERY_TIMEOUT")
            }
        }
    }

    private func open(_ device: ICCameraDevice) {
        guard browsing, camera == nil else { return }
        camera = device
        device.delegate = self
        cameraName = device.name ?? "USB 相機"
        status = "正在開啟 \(cameraName)…"
        record("DEVICE \(cameraName) uuid=\(device.uuidString ?? "unknown")")
        device.requestOpenSession()
    }

    private func files(_ device: ICCameraDevice) -> [ICCameraFile] {
        // compactMap, not a whole-array cast: a catalogue may also contain folders.
        var result = (device.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        func walk(_ items: [ICCameraItem]) {
            for item in items {
                if let file = item as? ICCameraFile { result.append(file) }
                else if let folder = item as? ICCameraFolder { walk(folder.contents ?? []) }
            }
        }
        walk(device.contents ?? [])
        var seen = Set<String>()
        return result.filter { seen.insert(fileKey($0)).inserted }
    }

    private func ready(_ device: ICCameraDevice) {
        guard device === camera, connected, browsing, !catalogReady else { return }
        let inventory = files(device)
        catalogCount = inventory.count
        catalogReady = true
        if mode == .newPhotos {
            known.formUnion(inventory.map(fileKey))
            status = "可以拍攝 · 等待新 JPG"
            record("BASELINE objects=\(inventory.count)")
        } else {
            record("CATALOG_READY objects=\(inventory.count)")
            ingest(device)
        }
    }

    private func ingest(_ device: ICCameraDevice) {
        guard device === camera, connected, catalogReady, browsing, !finishing else { return }
        let inventory = files(device)
        catalogCount = inventory.count
        enqueue(inventory)
    }

    private func enqueue(_ items: [ICCameraFile]) {
        guard catalogReady, !finishing else { return }
        for file in items where isJPEG(file) {
            let key = fileKey(file)
            guard !known.contains(key), !failed.contains(key), active?.key != key,
                  !queue.contains(where: { $0.key == key }) else { continue }
            let safe = Self.safeName(file.name ?? "IMG.JPG")
            let dest = folder.appendingPathComponent("\(UUID().uuidString)_\(safe)")
            queue.append(DownloadJob(file: file, key: key, name: safe, dest: dest, expectedSize: Int64(file.fileSize)))
        }
        queuedCount = queue.count + (active == nil ? 0 : 1)
        downloadNext()
    }

    private func isJPEG(_ file: ICCameraFile) -> Bool {
        let name = (file.name ?? "").lowercased()
        if name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") { return true }
        if let uti = file.uti, let type = UTType(uti) { return type.conforms(to: .jpeg) }
        return false
    }

    private func fileKey(_ file: ICCameraFile) -> String {
        // 0 and FFFFFFFF are not unique usable handles. Include device and metadata.
        let handle = file.ptpObjectHandle
        let prefix = camera?.uuidString ?? cameraName
        let identity = handle != 0 && handle != UInt32.max ? "PTP-\(handle)" : "ITEM-\(ObjectIdentifier(file))"
        return "\(prefix)|\(identity)|\(file.name ?? "")|\(file.fileSize)"
    }

    private func downloadNext() {
        guard connected, active == nil else { return }
        guard !queue.isEmpty else {
            queuedCount = 0
            if finishing { stopBrowsing() }
            else if failed.isEmpty { status = mode == .card ? "卡內 JPG 已收下 · 等待新 JPG" : "可以拍攝 · 等待新 JPG" }
            return
        }
        let job = queue.removeFirst()
        active = job
        let token = generation
        queuedCount = queue.count + 1
        status = "正在接收 \(job.name)…"
        record("DOWNLOAD_BEGIN \(job.name) expected=\(job.expectedSize)")
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: job.dest.deletingLastPathComponent(),
            .saveAsFilename: job.dest.lastPathComponent,
            .overwrite: true,
        ]
        _ = job.file.requestDownload(options: options) { [weak self] savedName, error in
            Task { @MainActor in
                guard let self, token == self.generation, self.active?.key == job.key else { return }
                if let error { self.downloadFailed(job, error.localizedDescription); return }
                var path = job.dest
                if let savedName, !savedName.isEmpty {
                    path = savedName.hasPrefix("/") ? URL(fileURLWithPath: savedName)
                        : job.dest.deletingLastPathComponent().appendingPathComponent(savedName)
                }
                guard path.standardizedFileURL.deletingLastPathComponent() == self.folder.standardizedFileURL else {
                    self.downloadFailed(job, "框架回傳的檔案位置不在接收資料夾"); return
                }
                let result = await Task.detached(priority: .utility) {
                    Self.validateJPEG(path, expected: job.expectedSize)
                }.value
                guard token == self.generation, self.active?.key == job.key else { return }
                switch result {
                case .success(let verified):
                    self.known.insert(job.key)
                    self.receivedCount += 1
                    self.record("DOWNLOAD_OK \(job.name) bytes=\(verified.bytes)")
                    self.onJPEG?(ReceivedJPEG(id: UUID().uuidString, name: job.name, url: path,
                        bytes: verified.bytes, sha256: verified.sha, createdAt: Date(), uploaded: false))
                    self.active = nil
                    self.downloadNext()
                case .failure(let error): self.downloadFailed(job, error.localizedDescription)
                }
            }
        }
    }

    private func downloadFailed(_ job: DownloadJob, _ reason: String) {
        failed.insert(job.key)
        failedCount = failed.count
        active = nil
        try? FileManager.default.removeItem(at: job.dest)
        fail("\(job.name)：\(reason)。可在「更多」重新搜尋及重試。")
        downloadNext()
    }

    private func fail(_ reason: String) {
        lastError = reason
        status = "接收需要檢查"
        record("ERROR \(reason)")
    }

    private func record(_ text: String) {
        logLines.append("\(ISO8601DateFormatter().string(from: Date())) \(text)")
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    func diagnosticFile() -> URL? {
        let info = Bundle.main.infoDictionary ?? [:]
        let header = "Cam Link \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))\n\(UIDevice.current.model) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n\(authorization)\nstatus=\(status) catalog=\(catalogCount) pending=\(queuedCount) failed=\(failedCount)\nNo receiver passwords or pairing codes are included.\n\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("CamLink-camera-diagnostics.txt")
        do { try (header + logLines.joined(separator: "\n")).write(to: path, atomically: true, encoding: .utf8); return path }
        catch { lastError = "無法匯出診斷：\(error.localizedDescription)"; return nil }
    }

    nonisolated static func safeName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let clean = mapped.isEmpty ? "IMG.JPG" : mapped
        if clean.lowercased().hasSuffix(".jpeg") { return String(clean.dropLast(5).prefix(140)) + ".jpeg" }
        if clean.lowercased().hasSuffix(".jpg") { return String(clean.dropLast(4).prefix(140)) + ".jpg" }
        return String(clean.prefix(140)) + ".jpg"
    }

    private struct VerifiedJPEG: Sendable { let bytes: Int64; let sha: String }
    private struct ValidationError: LocalizedError { let errorDescription: String? }
    nonisolated private static func validateJPEG(_ path: URL, expected: Int64) -> Result<VerifiedJPEG, ValidationError> {
        do {
            let data = try Data(contentsOf: path, options: .mappedIfSafe)
            guard data.count >= 4, data[0] == 0xFF, data[1] == 0xD8,
                  data[data.count - 2] == 0xFF, data[data.count - 1] == 0xD9 else {
                return .failure(ValidationError(errorDescription: "不是完整 JPG（缺少 SOI／EOI）"))
            }
            if expected > 0, expected != Int64(UInt32.max), Int64(data.count) != expected {
                return .failure(ValidationError(errorDescription: "照片大小不符：\(data.count) / \(expected) bytes"))
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString else {
                return .failure(ValidationError(errorDescription: "JPG 結構無法識別"))
            }
            return .success(VerifiedJPEG(bytes: Int64(data.count), sha: sha256Hex(data)))
        } catch { return .failure(ValidationError(errorDescription: error.localizedDescription)) }
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CameraCaptureService: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard self.browsing, self.camera == nil, let camera = device as? ICCameraDevice else { return }
            self.open(camera)
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in self.removed(device) }
    }
}

extension CameraCaptureService: ICCameraDeviceDelegate {
    private func removed(_ device: ICDevice) {
        guard device === camera else { return }
        record("DEVICE_REMOVED pending=\(queuedCount)")
        stopBrowsing()
        status = "相機已拔除"
        lastError = "未完成的下載不會當作成功。重新接線後選「接收卡內 JPG」補收。"
    }
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            guard device === self.camera, self.browsing else { return }
            if let error { self.fail("無法開啟相機：\(error.localizedDescription)"); return }
            self.connected = true
            self.status = "正在讀取相機目錄，請先不要拍攝…"
            self.record("SESSION_OPEN")
            if let camera = device as? ICCameraDevice, camera.contentCatalogPercentCompleted >= 100 { self.ready(camera) }
        }
    }
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.record("SESSION_CLOSED \(error?.localizedDescription ?? "")")
            self.stopBrowsing()
            self.status = "相機工作階段已關閉"
        }
    }
    nonisolated func didRemove(_ device: ICDevice) { Task { @MainActor in self.removed(device) } }
    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        Task { @MainActor in
            guard device === self.camera, let error else { return }
            self.fail(error.localizedDescription)
        }
    }
    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.record("ACCESS_RESTRICTION_REMOVED")
            self.refreshContents()
        }
    }
    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in
            guard device === self.camera else { return }
            self.fail("相機內容存取受限制，請確認相機已解鎖或允許連接。")
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in
            guard camera === self.camera, self.connected, self.browsing else { return }
            self.record("ITEMS_ADDED count=\(items.count) ready=\(self.catalogReady)")
            // Initial catalog events belong to the baseline, not live arrivals.
            if self.catalogReady { self.enqueue(items.compactMap { $0 as? ICCameraFile }); self.ingest(camera) }
        }
    }
    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.ready(device) }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        Task { @MainActor in
            guard camera === self.camera else { return }
            self.record("PTP_EVENT bytes=\(eventData.count)")
            self.ingest(camera)
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor in
            guard camera === self.camera else { return }
            self.record("CAPABILITIES_CHANGED")
            self.refreshContents()
        }
    }
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: (any Error)?) {}
}
