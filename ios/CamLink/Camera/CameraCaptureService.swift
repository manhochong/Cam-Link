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
    @Published private(set) var sessionClosing = false
    @Published private(set) var canStart = true
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
    /// Exactly once per accepted receive run; browsing=false is NOT completion.
    var onReceiveEnded: ((CameraReceiveEnd) -> Void)?
    /// Applied only when a new session starts; cannot mutate an active receiver's mode.
    var scanIntervalSeconds: TimeInterval = 2
    private var sessionScanInterval: TimeInterval = 2
    // Retain the old context/delegate until real closure or physical removal.
    private final class SessionContext {
        let token: UUID
        let browserID = UUID()
        let browser = ICDeviceBrowser()
        var camera: ICCameraDevice?
        var cameraID: UUID?
        var delegate: CameraSessionDelegate?
        var completion = CameraReceiveCompletion()
        init(token: UUID) { self.token = token }
    }
    private var session: SessionContext?
    private var lifecycle = CameraLifecycle()
    private var closeTimer: Timer?
    private var camera: ICCameraDevice?
    private var generation = UUID()
    private var known = Set<String>()
    private var failed = Set<String>()
    private var queue: [DownloadJob] = []
    private var active: DownloadJob?
    private var timer: Timer?
    private var downloadBegan: Date?
    private var began = Date()
    private var catalogSignature = ""
    private var folder: URL
    // Sticky for this session: native downloads and raw commands never overlap.
    private var ptpSelected = false
    private var ptpAuthorizing = false
    private var ptpReceiver: PTPPhotoReceiver?
    private var diagnosticHighlights: [String] = []
    private var jpegHighlights = 0

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
    }

    func startBrowsing() {
        guard !browsing, lifecycle.canStart else {
            if sessionClosing { record("START_BLOCKED phase=\(lifecycle.session?.phase.rawValue ?? "unknown")") }
            return
        }
        generation = UUID()
        let token = generation
        let context = SessionContext(token: token)
        let requested = scanIntervalSeconds.isFinite ? min(5, max(0.5, scanIntervalSeconds)) : 2
        sessionScanInterval = mode == .card ? max(2, requested) : requested
        guard lifecycle.start(id: token, browserID: context.browserID) else { return }
        session = context
        let browser = context.browser // This exact instance is captured through authorization.
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        ) ?? .camera
        publishLifecycle()
        ptpReceiver?.cancel()
        ptpReceiver = nil
        ptpSelected = false
        ptpAuthorizing = false
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
        catalogSignature = ""
        logLines.removeAll()
        diagnosticHighlights.removeAll()
        jpegHighlights = 0
        browsing = true
        status = "正在要求相機存取權限…"
        record("START mode=\(mode.rawValue)")
        record("SCAN_INTERVAL seconds=\(sessionScanInterval)")
        record("BROWSER_CREATED session=\(token) browser=\(context.browserID)")
        Task { [weak self, browser] in
            var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                allowed = await AVCaptureDevice.requestAccess(for: .video)
            }
            guard let self, self.isCurrentBrowser(browser, token: token), self.browsing else { return }
            self.record("CAMERA_PERMISSION \(AVCaptureDevice.authorizationStatus(for: .video).rawValue)")
            guard allowed else {
                self.authorization = "相機權限未允許"
                self.fail("請在設定 → Cam Link 開啟相機權限，再重新連接。")
                self.stopBrowsing()
                return
            }
            browser.requestContentsAuthorization { [weak self, browser] auth in
                Task { @MainActor in
                    guard let self, self.isCurrentBrowser(browser, token: token), self.browsing else { return }
                    self.authorization = "相機已允許 · 內容授權 \(auth.rawValue)"
                    self.record("CONTENTS_AUTH \(auth.rawValue)")
                    guard auth == .authorized else {
                        self.fail("iPadOS 未允許外接相機內容存取。請到設定確認相機權限；若已允許，請匯出診斷。")
                        self.stopBrowsing()
                        return
                    }
                    do {
                        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
                    } catch {
                        self.fail("無法建立 JPG 儲存資料夾：\(error.localizedDescription)")
                        self.stopBrowsing()
                        return
                    }
                    guard let current = self.session,
                          self.lifecycle.authorized(id: token, browserID: current.browserID) else { return }
                    self.status = "正在尋找 USB 相機…"
                    browser.start()
                    self.record("BROWSER_START session=\(token) browser=\(current.browserID)")
                    self.timer?.invalidate()
                    self.timer = Timer.scheduledTimer(withTimeInterval: self.sessionScanInterval, repeats: true) { [weak self, browser] _ in
                        Task { @MainActor in self?.tick(browser, token: token) }
                    }
                    self.reconcileDevices(browser, token: token)
                }
            }
        }
    }

    /// Stop only after all already-queued originals have completed; keep the cable connected.
    func finishReceiving() {
        guard browsing else { return }
        session?.completion.requestFinish()
        if ptpSelected, connected {
            finishing = true
            status = "正在完成 PTP 接收，請保持相機連線…"
            record("DRAIN_PTP pending=\(queuedCount)")
            // Includes a baseline still in progress and a final full inventory.
            if let ptpReceiver { ptpReceiver.finish() }
            else if !ptpAuthorizing {
                let reason = lastError.isEmpty ? "PTP 尚未就緒；請匯出診斷。" : lastError
                fail(reason)
                stopBrowsing()
            }
            return
        }
        guard connected, catalogReady else { stopBrowsing(); return }
        finishing = true
        status = "正在完成接收，請保持相機連線…"
        record("DRAIN pending=\(queuedCount)")
        if active == nil, queue.isEmpty { stopAfterDrain() }
    }

    /// Explicit/forced stop is never proof of a successful drain.
    func stopBrowsing() {
        guard let context = session else { return }
        context.completion.markUnclean()
        stopReceiving(context)
    }

    private func stopAfterDrain() {
        guard browsing, let context = session else { return }
        context.completion.drained()
        stopReceiving(context)
    }

    private func stopReceiving(_ context: SessionContext) {
        guard browsing, session === context else { return }
        let action = lifecycle.stop(id: context.token)
        invalidateReceiving(context)
        publishLifecycle()
        switch action {
        case .released:
            status = "已停止接收"
            releaseSession(context)
        case .waitForOpen:
            status = "正在等待相機開啟完成後關閉，請保持連線…"
            record("CLOSE_WAIT_OPEN session=\(context.token)")
            armCloseBarrier(context)
        case .requestClose:
            status = "正在關閉相機工作階段，請保持連線…"
            armCloseBarrier(context)
            requestClose(context)
        case .waiting, .ignored:
            break
        }
    }

    private func publishLifecycle() {
        sessionClosing = lifecycle.sessionClosing
        canStart = lifecycle.canStart
    }

    private func isCurrentBrowser(_ browser: ICDeviceBrowser, token: UUID) -> Bool {
        guard let context = session, context.token == token, context.browser === browser else { return false }
        return lifecycle.ownsBrowser(id: token, browserID: context.browserID)
    }

    /// Invalidate receiving work BEFORE asking Apple to close its native session.
    /// Keep the context's device and immutable delegate alive for cleanup callbacks.
    private func invalidateReceiving(_ context: SessionContext) {
        // Snapshot before cancel(), browsing=false, or clearing active/queued work.
        context.completion.snapshot(received: receivedCount, pending: queuedCount, failed: failedCount)
        generation = UUID()
        timer?.invalidate()
        timer = nil
        // Poison/cancel raw callbacks BEFORE Apple closes its owned session.
        ptpReceiver?.cancel()
        ptpReceiver = nil
        ptpSelected = false
        ptpAuthorizing = false
        context.browser.stop()
        record("BROWSER_STOP session=\(context.token) browser=\(context.browserID)")
        camera = nil
        connected = false
        catalogReady = false
        browsing = false
        finishing = false
        cameraName = ""
        queue.removeAll()
        active = nil
        queuedCount = 0
        record("STOP session=\(context.token)")
    }

    private func requestClose(_ context: SessionContext) {
        guard session === context, let device = context.camera else { return }
        // Issued ONLY by the reducer's one-shot requestClose action.
        record("SESSION_CLOSE_REQUEST session=\(context.token)")
        device.requestCloseSession()
    }

    private func armCloseBarrier(_ context: SessionContext) {
        guard closeTimer == nil else { return }
        let token = context.token
        closeTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.closeTimedOut(id: token) else { return }
                self.closeTimer = nil
                self.publishLifecycle()
                self.record("CLOSE_BARRIER_TIMEOUT session=\(token) reconnectRequired=true")
                self.requireReconnect("相機工作階段未確認關閉。")
            }
        }
    }

    private func requireReconnect(_ reason: String) {
        closeTimer?.invalidate()
        closeTimer = nil
        publishLifecycle()
        lastError = "\(reason) 請實際拔除 USB 相機再重新連接；確認拔除前不會再次開啟工作階段。"
        status = "請拔除相機後重新連接"
        record("RECONNECT_REQUIRED \(reason)")
        if let context = session {
            context.completion.markUnclean()
            reportReceiveEnded(context, nativeCloseSucceeded: false)
        }
    }

    private func releaseSession(_ context: SessionContext, nativeCloseSucceeded: Bool = false) {
        guard session === context, lifecycle.canStart else { return }
        closeTimer?.invalidate()
        closeTimer = nil
        context.browser.delegate = nil
        context.camera?.delegate = nil
        session = nil
        publishLifecycle()
        record("CLOSE_BARRIER_RELEASED session=\(context.token)")
        reportReceiveEnded(context, nativeCloseSucceeded: nativeCloseSucceeded)
    }

    private func reportReceiveEnded(_ context: SessionContext, nativeCloseSucceeded: Bool) {
        guard let result = context.completion.end(nativeCloseSucceeded: nativeCloseSucceeded) else { return }
        record("RECEIVE_ENDED session=\(context.token) received=\(result.received) pending=\(result.pending) failed=\(result.failed) clean=\(result.clean)")
        onReceiveEnded?(result)
    }

    func refreshContents() {
        guard let camera, browsing, connected, !finishing else { return }
        failed.removeAll()
        failedCount = 0
        lastError = ""
        record("MANUAL_RETRY")
        if ptpSelected {
            if let ptpReceiver { ptpReceiver.retryFailed() }
            else { authorizePTPFallback(camera) }
            return
        }
        if !catalogReady, camera.contentCatalogPercentCompleted >= 100 {
            ready(camera)
        } else if catalogReady {
            ingest(camera)
        }
    }

    private func tick(_ browser: ICDeviceBrowser, token: UUID) {
        guard browsing, isCurrentBrowser(browser, token: token), token == generation else { return }
        if camera == nil { reconcileDevices(browser, token: token) }
        // Receiver owns its own idle-only reconciliation timer.
        guard !ptpSelected else { return }
        if active != nil, let downloadBegan, Date().timeIntervalSince(downloadBegan) > 120 {
            record("DOWNLOAD_TIMEOUT")
            fail("照片下載超過 120 秒未完成。請重新接線，選「接收卡內 JPG」補收，並匯出診斷。")
            stopBrowsing()
            return
        }
        guard !finishing else { return }
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

    private func reconcileDevices(_ browser: ICDeviceBrowser, token: UUID) {
        guard browsing, isCurrentBrowser(browser, token: token), lifecycle.session?.phase == .discovering else { return }
        let devices = (browser.devices ?? []).compactMap { $0 as? ICCameraDevice }
        record("BROWSER_RECONCILE session=\(token) cachedCameras=\(devices.count)")
        for device in devices { open(device, browser: browser, token: token, source: "cached") }
    }

    private func open(_ device: ICCameraDevice, browser: ICDeviceBrowser, token: UUID, source: String) {
        guard browsing, camera == nil, isCurrentBrowser(browser, token: token), let context = session else {
            record("DEVICE_IGNORED source=\(source) reason=stale-or-already-admitted")
            return
        }
        let cameraID = UUID()
        guard lifecycle.admitDevice(id: token, browserID: context.browserID, deviceID: cameraID) else {
            record("DEVICE_IGNORED source=\(source) reason=phase")
            return
        }
        context.camera = device
        context.cameraID = cameraID
        let delegate = CameraSessionDelegate(owner: self, token: token, cameraID: cameraID)
        context.delegate = delegate
        camera = device
        device.delegate = delegate
        cameraName = device.name ?? "USB 相機"
        status = "正在開啟 \(cameraName)…"
        record("DEVICE \(cameraName) uuid=\(device.uuidString ?? "unknown")")
        record("SESSION_OPEN_REQUEST session=\(token) source=\(source)")
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
        guard device === camera, connected, browsing, !catalogReady, !ptpSelected else { return }
        let inventory = files(device)
        catalogCount = inventory.count
        recordCatalog(device, inventory: inventory, reason: "READY", force: true)
        if inventory.isEmpty, active == nil, queue.isEmpty {
            ptpSelected = true
            catalogReady = false
            timer?.invalidate()
            timer = nil
            status = "原生目錄為空，正在查詢 PTP 新目錄，請先不要拍攝…"
            record("PTP_FALLBACK_SELECTED nativeComplete=\(device.contentCatalogPercentCompleted) nativeObjects=0 nativePending=0")
            authorizePTPFallback(device)
            return
        }
        catalogReady = true
        if mode == .newPhotos {
            known.formUnion(inventory.map(fileKey))
            status = inventory.isEmpty ? "相機已連線 · 尚未找到相片物件" : "可以拍攝 · 等待新 JPG"
            record("BASELINE objects=\(inventory.count)")
        } else {
            record("CATALOG_READY objects=\(inventory.count)")
            ingest(device)
        }
    }

    private func ingest(_ device: ICCameraDevice) {
        guard !ptpSelected, device === camera, connected, catalogReady, browsing, !finishing else { return }
        let inventory = files(device)
        catalogCount = inventory.count
        recordCatalog(device, inventory: inventory, reason: "CHANGED")
        enqueue(inventory)
    }

    private func authorizePTPFallback(_ device: ICCameraDevice) {
        guard ptpSelected, !ptpAuthorizing, ptpReceiver == nil, device === camera,
              connected, browsing, active == nil, queue.isEmpty else { return }
        let token = generation
        guard let context = session, context.token == token else { return }
        let browser = context.browser
        ptpAuthorizing = true
        status = "正在要求 PTP 讀取授權，請先不要拍攝…"
        record("CONTROL_AUTH_REQUEST readOnlyPTP=true")
        browser.requestControlAuthorization { [weak self, browser] auth in
            Task { @MainActor in
                guard let self, token == self.generation, self.isCurrentBrowser(browser, token: token), self.browsing,
                      self.connected, device === self.camera, self.ptpSelected else { return }
                self.ptpAuthorizing = false
                self.authorization = "相機已允許 · 內容授權已允許 · PTP 授權 \(auth.rawValue)"
                self.record("CONTROL_AUTH \(auth.rawValue)")
                guard auth == .authorized else {
                    let reason = "iPadOS 未允許 PTP 讀取授權；沒有傳送任何 PTP 命令。請確認權限後重新搜尋，或匯出診斷。"
                    self.fail(reason)
                    if self.finishing { self.stopBrowsing() }
                    return
                }
                let reader = PTPCameraReader(camera: device) { [weak self] message in
                    guard let self, token == self.generation else { return }
                    self.record(message)
                }
                let receiver = PTPPhotoReceiver(reader: reader, mode: self.mode, folder: self.folder,
                    scanInterval: self.sessionScanInterval,
                    trace: { [weak self] message in
                        guard let self, token == self.generation else { return }
                        self.record(message)
                    }, onState: { [weak self] state in
                        guard let self, token == self.generation, self.ptpSelected else { return }
                        self.catalogCount = state.catalogCount
                        self.queuedCount = state.queuedCount
                        self.failedCount = state.failedCount
                        self.receivedCount = state.receivedCount
                        self.catalogReady = state.catalogReady
                        self.finishing = state.finishing
                        self.status = state.status
                        self.lastError = state.lastError
                        if state.failedCount > 0 || !state.lastError.isEmpty {
                            self.session?.completion.markUnclean()
                        }
                    }, onJPEG: { [weak self] photo in
                        guard let self, token == self.generation, self.ptpSelected else { return }
                        self.onJPEG?(photo)
                    }, onFinished: { [weak self] reason in
                        guard let self, token == self.generation, self.ptpSelected else { return }
                        if let reason {
                            self.fail(reason)
                            self.stopBrowsing()
                        } else {
                            // The receiver's final-inventory/drain callback, not a State update.
                            self.stopAfterDrain()
                        }
                    })
                self.ptpReceiver = receiver
                // Calling finish before start prevents its initial State from
                // briefly clearing a user's drain request during authorization.
                if self.finishing { receiver.finish() }
                receiver.start()
            }
        }
    }

    private func recordCatalog(_ device: ICCameraDevice, inventory: [ICCameraFile], reason: String, force: Bool = false) {
        let media = device.mediaFiles.map { String($0.count) } ?? "nil"
        let contents = device.contents.map { String($0.count) } ?? "nil"
        let jpegCount = inventory.filter(isJPEG).count
        let signature = "\(device.contentCatalogPercentCompleted)|\(media)|\(contents)|\(inventory.count)|\(jpegCount)"
        guard force || signature != catalogSignature else { return }
        catalogSignature = signature
        record("CATALOG_\(reason) percent=\(device.contentCatalogPercentCompleted) media=\(media) contents=\(contents) files=\(inventory.count) jpg=\(jpegCount) tethered=\(device.tetheredCaptureEnabled)")
        for file in inventory.prefix(10) {
            record("CATALOG_ITEM handle=\(file.ptpObjectHandle) name=\(file.name ?? "?") uti=\(file.uti ?? "?") bytes=\(file.fileSize) known=\(known.contains(fileKey(file)))")
        }
    }

    private func enqueue(_ items: [ICCameraFile]) {
        guard !ptpSelected, catalogReady, !finishing else { return }
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
        guard !ptpSelected, connected, active == nil else { return }
        guard !queue.isEmpty else {
            queuedCount = 0
            if finishing { stopAfterDrain() }
            else if failed.isEmpty, lastError.isEmpty {
                if catalogCount == 0 { status = "相機已連線 · 尚未找到相片物件" }
                else if mode == .card, receivedCount == 0 { status = "目錄尚無可接收的 JPG · 請確認照片格式" }
                else { status = mode == .card ? "卡內 JPG 已收下 · 等待新 JPG" : "可以拍攝 · 等待新 JPG" }
            }
            return
        }
        let job = queue.removeFirst()
        active = job
        downloadBegan = Date()
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
                if let error {
                    self.record("DOWNLOAD_ERROR \((error as NSError).domain)/\((error as NSError).code)")
                    self.downloadFailed(job, error.localizedDescription)
                    return
                }
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
                    self.record("JPEG_VALIDATED path=native name=\(job.name) \(verified.diagnostic)")
                    self.record("DOWNLOAD_OK \(job.name) bytes=\(verified.bytes)")
                    self.onJPEG?(ReceivedJPEG(id: UUID().uuidString, name: job.name, url: path,
                        bytes: verified.bytes, sha256: verified.sha, createdAt: Date(), uploaded: false))
                    self.active = nil
                    self.downloadNext()
                case .failure(let error):
                    self.record("JPEG_REJECT path=native name=\(job.name) \(error.localizedDescription)")
                    self.downloadFailed(job, error.localizedDescription)
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
        session?.completion.markUnclean()
        lastError = reason
        status = "接收需要檢查"
        record("ERROR \(reason)")
    }

    private func record(_ text: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(text)"
        logLines.append(line)
        // Preserve setup and the first few image results even after a whole-card
        // import fills the rolling log. Never persist full image/EXIF bytes.
        if diagnosticHighlights.count < 48 {
            if text.hasPrefix("JPEG_") {
                if jpegHighlights < 8 {
                    diagnosticHighlights.append(line)
                    jpegHighlights += 1
                }
            } else if diagnosticHighlights.count < 40 {
                diagnosticHighlights.append(line)
            }
        }
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    func diagnosticFile() -> URL? {
        let info = Bundle.main.infoDictionary ?? [:]
        if let camera { recordCatalog(camera, inventory: files(camera), reason: "REPORT", force: true) }
        let header = "Cam Link \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))\n\(UIDevice.current.model) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)\n\(authorization)\nmode=\(mode.rawValue) camera=\(cameraName)\nbrowsing=\(browsing) connected=\(connected) catalogReady=\(catalogReady) finishing=\(finishing)\nsessionClosing=\(sessionClosing) canStart=\(canStart) phase=\(lifecycle.session?.phase.rawValue ?? "idle") session=\(session?.token.uuidString ?? "none") browser=\(session?.browserID.uuidString ?? "none")\nstatus=\(status) catalog=\(catalogCount) pending=\(queuedCount) failed=\(failedCount) received=\(receivedCount)\nlastError=\(lastError)\nNo receiver passwords or pairing codes are included.\n\n"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("CamLink-camera-diagnostics.txt")
        let highlights = "SESSION HIGHLIGHTS (may repeat rolling log entries)\n" + diagnosticHighlights.joined(separator: "\n")
        let rolling = "\n\nRECENT EVENTS\n" + logLines.joined(separator: "\n") + "\n"
        do { try (header + highlights + rolling).write(to: path, atomically: true, encoding: .utf8); return path }
        catch { lastError = "無法匯出診斷：\(error.localizedDescription)"; return nil }
    }

    nonisolated static func describePTPEvent(_ data: Data) -> String {
        let bytes = Array(data.prefix(64))
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        guard bytes.count >= 12 else { return "bytes=\(data.count) unparsed hex=\(hex)" }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }
        guard u32(0) == data.count, u16(4) == 4 else {
            return "bytes=\(data.count) unparsed hex=\(hex)"
        }
        let parameters = stride(from: 12, to: min(bytes.count - 3, 24), by: 4)
            .map { String(format: "%08X", u32($0)) }.joined(separator: ",")
        return "bytes=\(data.count) code=\(String(format: "%04X", u16(6))) transaction=\(u32(8)) params=\(parameters) hex=\(hex)"
    }

    nonisolated static func safeName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let mapped = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let clean = mapped.isEmpty ? "IMG.JPG" : mapped
        if clean.lowercased().hasSuffix(".jpeg") { return String(clean.dropLast(5).prefix(140)) + ".jpeg" }
        if clean.lowercased().hasSuffix(".jpg") { return String(clean.dropLast(4).prefix(140)) + ".jpg" }
        return String(clean.prefix(140)) + ".jpg"
    }

    struct VerifiedJPEG: Sendable { let bytes: Int64; let sha: String; let diagnostic: String }
    struct ValidationError: LocalizedError, Sendable {
        let errorDescription: String?
        var retryable = false
    }
    nonisolated static func validateJPEG(_ path: URL, expected: Int64) -> Result<VerifiedJPEG, ValidationError> {
        do {
            let data = try Data(contentsOf: path, options: .mappedIfSafe)
            do {
                let verified = try JPEGIntegrity.validate(data, expected: expected)
                return .success(VerifiedJPEG(bytes: verified.bytes, sha: verified.sha,
                                              diagnostic: JPEGIntegrity.diagnostic(data)))
            } catch {
                let retryable = (error as? JPEGIntegrity.Failure)?.retryable ?? false
                return .failure(ValidationError(errorDescription: "\(error.localizedDescription)；\(JPEGIntegrity.diagnostic(data))",
                                                retryable: retryable))
            }
        } catch { return .failure(ValidationError(errorDescription: error.localizedDescription)) }
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension CameraCaptureService: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard let context = self.session, context.browser === browser,
                  self.isCurrentBrowser(browser, token: context.token), self.browsing,
                  let camera = device as? ICCameraDevice else {
                self.record("BROWSER_ADD_IGNORED reason=stale-or-inactive")
                return
            }
            self.open(camera, browser: browser, token: context.token, source: "didAdd")
        }
    }
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard let context = self.session, context.browser === browser,
                  self.isCurrentBrowser(browser, token: context.token), device === context.camera,
                  let cameraID = context.cameraID else {
                self.record("BROWSER_REMOVE_IGNORED reason=stale-or-unaccepted")
                return
            }
            self.handleCameraEvent(.removed(device), token: context.token, cameraID: cameraID)
        }
    }
}

extension CameraCaptureService {
    fileprivate func handleCameraEvent(_ event: CameraSessionEvent, token: UUID, cameraID: UUID) {
        guard let context = session, context.token == token, context.cameraID == cameraID,
              event.device === context.camera, lifecycle.ownsDevice(id: token, deviceID: cameraID) else {
            record("SESSION_CALLBACK_IGNORED session=\(token) reason=stale")
            return
        }
        // Cleanup events use the context token, NOT the invalidated receiving generation.
        switch event {
        case .opened(let device, let error):
            let action = lifecycle.opened(id: token, deviceID: cameraID, succeeded: error == nil)
            publishLifecycle()
            switch action {
            case .receive:
                connected = true
                lastError = ""
                status = "正在讀取相機目錄，請先不要拍攝…"
                record("SESSION_OPEN session=\(token)")
                record("CAPABILITIES \(String(describing: device.capabilities))")
                if let camera = device as? ICCameraDevice, camera.contentCatalogPercentCompleted >= 100 { ready(camera) }
            case .requestClose:
                record("SESSION_OPEN_CLEANUP_ONLY session=\(token)")
                requestClose(context) // Stop during open: successful open is closed, never received.
            case .requireReconnect:
                record("SESSION_OPEN_ERROR session=\(token) \(error?.localizedDescription ?? "unknown")")
                if browsing { invalidateReceiving(context) }
                requireReconnect("無法確認相機開啟狀態：\(error?.localizedDescription ?? "未知錯誤")。")
            case .ignored:
                record("SESSION_OPEN_IGNORED session=\(token) reason=duplicate-or-phase")
            }
            return
        case .closed(_, let error):
            let action = lifecycle.closed(id: token, deviceID: cameraID, succeeded: error == nil)
            record("SESSION_CLOSE_COMPLETE session=\(token) result=\(action) error=\(error?.localizedDescription ?? "none")")
            switch action {
            case .released:
                if browsing { invalidateReceiving(context) }
                status = "相機工作階段已關閉"
                releaseSession(context, nativeCloseSucceeded: true)
            case .requireReconnect:
                if browsing { invalidateReceiving(context) }
                requireReconnect("相機關閉失敗或已逾時：\(error?.localizedDescription ?? "仍須確認實際拔除")。")
            case .ignored:
                break
            }
            return
        case .removed:
            guard lifecycle.removed(id: token, deviceID: cameraID) else { return }
            record("DEVICE_REMOVED session=\(token) pending=\(queuedCount)")
            if browsing { invalidateReceiving(context) }
            context.completion.markUnclean()
            status = "相機已拔除"
            lastError = "未完成的下載不會當作成功。重新接線後選「接收卡內 JPG」補收。"
            releaseSession(context)
            return
        case .encounteredError(_, let error):
            // A current native error during close cleanup must also veto clean.
            if error != nil { context.completion.markUnclean() }
        case .restrictionEnabled:
            context.completion.markUnclean()
        default:
            break
        }
        guard browsing, connected, token == generation,
              lifecycle.acceptsReceivingCallback(id: token, deviceID: cameraID) else {
            record("SESSION_CALLBACK_IGNORED session=\(token) reason=not-receiving")
            return
        }
        switch event {
        case .encounteredError(_, let error):
            if let error {
                record("DEVICE_ERROR \((error as NSError).domain)/\((error as NSError).code)")
                fail(error.localizedDescription)
            }
        case .restrictionRemoved:
            record("ACCESS_RESTRICTION_REMOVED")
            refreshContents()
        case .restrictionEnabled:
            fail("相機內容存取受限制，請確認相機已解鎖或允許連接。")
        case .itemsAdded(let camera, let items):
            record("ITEMS_ADDED count=\(items.count) ready=\(catalogReady)")
            guard !ptpSelected else { return }
            // Initial catalog events belong to the baseline, not live arrivals.
            if catalogReady { enqueue(items.compactMap { $0 as? ICCameraFile }); ingest(camera) }
        case .catalogReady(let device):
            ready(device)
        case .ptpEvent(let camera, let eventData):
            record("PTP_EVENT \(Self.describePTPEvent(eventData))")
            if ptpSelected {
                if let event = PTPCodec.event(eventData) { ptpReceiver?.receiveEvent(event) }
                return
            }
            ingest(camera)
        case .capabilitiesChanged:
            record("CAPABILITIES_CHANGED")
            refreshContents()
        default:
            break
        }
    }
}

fileprivate enum CameraSessionEvent {
    case opened(ICDevice, (any Error)?)
    case closed(ICDevice, (any Error)?)
    case removed(ICDevice)
    case encounteredError(ICDevice, (any Error)?)
    case restrictionRemoved(ICDevice)
    case restrictionEnabled(ICDevice)
    case itemsAdded(ICCameraDevice, [ICCameraItem])
    case catalogReady(ICCameraDevice)
    case ptpEvent(ICCameraDevice, Data)
    case capabilitiesChanged(ICCameraDevice)

    var device: ICDevice {
        switch self {
        case .opened(let device, _), .closed(let device, _), .removed(let device),
             .encounteredError(let device, _), .restrictionRemoved(let device), .restrictionEnabled(let device):
            return device
        case .itemsAdded(let camera, _), .catalogReady(let camera), .ptpEvent(let camera, _), .capabilitiesChanged(let camera):
            return camera
        }
    }
}

/// Every callback carries the immutable owner assigned BEFORE requestOpenSession.
/// Reusing the same ICCameraDevice later does not relabel an already queued callback.
/// Signatures mirror the app's existing ImageCaptureCore SDK delegate surface.
fileprivate final class CameraSessionDelegate: NSObject, ICCameraDeviceDelegate {
    private weak var owner: CameraCaptureService?
    private let token: UUID
    private let cameraID: UUID

    init(owner: CameraCaptureService, token: UUID, cameraID: UUID) {
        self.owner = owner
        self.token = token
        self.cameraID = cameraID
        super.init()
    }

    private func forward(_ event: CameraSessionEvent) {
        let token = self.token
        let cameraID = self.cameraID
        Task { @MainActor [weak owner = owner] in
            owner?.handleCameraEvent(event, token: token, cameraID: cameraID)
        }
    }

    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) { forward(.opened(device, error)) }
    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) { forward(.closed(device, error)) }
    func didRemove(_ device: ICDevice) { forward(.removed(device)) }
    func device(_ device: ICDevice, didEncounterError error: (any Error)?) { forward(.encounteredError(device, error)) }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) { forward(.restrictionRemoved(device)) }
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) { forward(.restrictionEnabled(device)) }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { forward(.itemsAdded(camera, items)) }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) { forward(.catalogReady(device)) }
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) { forward(.ptpEvent(camera, eventData)) }
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) { forward(.capabilitiesChanged(camera)) }

    // Required notifications intentionally have no receiving-side effects.
    // In particular, implementing a delete COMPLETION never requests a delete.
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: (any Error)?) {}
    func cameraDevice(_ camera: ICCameraDevice, didCompleteDeleteFilesWithError error: (any Error)?) {}
}
