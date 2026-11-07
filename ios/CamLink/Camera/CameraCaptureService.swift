import CryptoKit
import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

/// USB still cameras via ImageCaptureCore (no Wi‑Fi SD / card radios).
@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    @Published var status = "尚未尋找相機"
    @Published var cameraName = ""
    @Published var browsing = false
    @Published var connected = false
    @Published var lastError = ""

    var onJPEG: ((ReceivedJPEG) -> Void)?

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var knownHandles = Set<String>()
    private let folder: URL
    private var downloading = Set<String>()
    private var downloadSinks: [String: DownloadSink] = [:]
    private var downloadContexts: [String: DownloadContext] = [:]

    override init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        folder = base
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        )
    }

    func startBrowsing() {
        lastError = ""
        status = "正在尋找 USB 相機…"
        browsing = true
        browser.requestContentsAuthorization { [weak self] auth in
            Task { @MainActor in
                guard let self else { return }
                if auth != .authorized {
                    self.lastError = "未授權存取相機內容。請到設定開啟。"
                    self.status = "需要相機存取權限"
                    self.browsing = false
                    return
                }
                self.browser.start()
            }
        }
    }

    func stopBrowsing() {
        browser.stop()
        if let camera {
            camera.requestCloseSession()
        }
        camera = nil
        connected = false
        cameraName = ""
        browsing = false
        status = "已停止尋找"
    }

    func refreshContents() {
        guard let camera, connected else { return }
        ingestNewJPEGs(from: camera)
    }

    private func open(_ device: ICCameraDevice) {
        camera = device
        device.delegate = self
        cameraName = device.name ?? "USB 相機"
        status = "正在開啟 \(cameraName)…"
        device.requestOpenSession()
    }

    private func ingestNewJPEGs(from device: ICCameraDevice) {
        guard let files = device.mediaFiles as? [ICCameraFile] else { return }
        for file in files {
            guard isJPEG(file) else { continue }
            let key = fileKey(file)
            if knownHandles.contains(key) || downloading.contains(key) { continue }
            download(file, on: device, key: key)
        }
    }

    private func isJPEG(_ file: ICCameraFile) -> Bool {
        let name = (file.name ?? "").lowercased()
        if name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") { return true }
        if let uti = file.uti, let type = UTType(uti) {
            return type.conforms(to: .jpeg)
        }
        return false
    }

    private func fileKey(_ file: ICCameraFile) -> String {
        if let name = file.name, !name.isEmpty { return name }
        return String(ObjectIdentifier(file).hashValue)
    }

    private func download(_ file: ICCameraFile, on device: ICCameraDevice, key: String) {
        downloading.insert(key)
        let safe = Self.safeName(file.name ?? "IMG.JPG")
        let dest = folder.appendingPathComponent("\(Int(Date().timeIntervalSince1970))_\(safe)")
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: dest.deletingLastPathComponent(),
            .saveAsFilename: dest.lastPathComponent,
            .overwrite: true,
        ]
        status = "正在下載 \(safe)…"
        let ctx = DownloadContext(key: key, dest: dest, name: safe)
        downloadContexts[key] = ctx
        // Separate NSObject sink avoids @MainActor vs ImageCaptureCore protocol isolation errors.
        let sink = DownloadSink { [weak self] error, opts in
            Task { @MainActor in
                self?.finishDownload(key: key, error: error, options: opts)
            }
        }
        downloadSinks[key] = sink
        device.requestDownloadFile(
            file,
            options: options,
            downloadDelegate: sink,
            didDownloadSelector: #selector(DownloadSink.didDownloadFile(_:error:options:contextInfo:)),
            contextInfo: nil
        )
    }

    private func finishDownload(
        key: String,
        error: (any Error)?,
        options: [AnyHashable: Any]?
    ) {
        let ctx = downloadContexts.removeValue(forKey: key)
        downloadSinks.removeValue(forKey: key)
        downloading.remove(key)
        guard let ctx else { return }
        if let error {
            lastError = error.localizedDescription
            status = "下載失敗"
            return
        }
        knownHandles.insert(ctx.key)
        // We set saveAsFilename ourselves; prefer that path, fall back to framework key.
        var path = ctx.dest
        if let saved = options?["ICSavedFilename"] as? String, !saved.isEmpty {
            path = ctx.dest.deletingLastPathComponent().appendingPathComponent(saved)
        }
        do {
            let data = try Data(contentsOf: path)
            let sha = Self.sha256Hex(data)
            let photo = ReceivedJPEG(
                id: ctx.key + "-\(path.lastPathComponent)",
                name: ctx.name,
                url: path,
                bytes: Int64(data.count),
                sha256: sha,
                createdAt: Date(),
                uploaded: false
            )
            onJPEG?(photo)
            status = "已收下 \(ctx.name)"
        } catch {
            lastError = error.localizedDescription
            status = "無法讀取已下載檔案"
        }
    }

    nonisolated static func safeName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "IMG.JPG" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        if mapped.lowercased().hasSuffix(".jpg") || mapped.lowercased().hasSuffix(".jpeg") { return mapped }
        return mapped + ".JPG"
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class DownloadContext: NSObject {
    let key: String
    let dest: URL
    let name: String
    init(key: String, dest: URL, name: String) {
        self.key = key
        self.dest = dest
        self.name = name
    }
}

/// Off-MainActor ObjC sink — signature must match latest ImageCaptureCore bridging.
final class DownloadSink: NSObject, ICCameraDeviceDownloadDelegate {
    private let onDone: ((Error?, [AnyHashable: Any]?) -> Void)

    init(onDone: @escaping (Error?, [AnyHashable: Any]?) -> Void) {
        self.onDone = onDone
    }

    @objc func didDownloadFile(
        _ file: ICCameraFile,
        error: Error?,
        options: [AnyHashable: Any]?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        onDone(error, options)
    }
}

extension CameraCaptureService: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard self.camera == nil, let camera = device as? ICCameraDevice else { return }
            let caps = camera.capabilities ?? []
            // Prefer PTP-capable bodies; otherwise accept any local camera-class device.
            if caps.contains(ICCameraDeviceCanAcceptPTPCommands)
                || (device.type.rawValue & ICDeviceType.camera.rawValue) == ICDeviceType.camera.rawValue {
                self.open(camera)
            }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            if device === self.camera {
                self.camera = nil
                self.connected = false
                self.cameraName = ""
                self.status = "相機已拔除"
            }
        }
    }
}

extension CameraCaptureService: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        Task { @MainActor in
            if let error {
                self.lastError = error.localizedDescription
                self.status = "無法開啟相機"
                self.connected = false
                return
            }
            self.connected = true
            self.status = "已連接 \(self.cameraName)·等待 JPG"
            if let camera = device as? ICCameraDevice {
                self.ingestNewJPEGs(from: camera)
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        Task { @MainActor in
            self.connected = false
            self.status = "工作階段已關閉"
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            self.ingestNewJPEGs(from: device)
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in
            for item in items {
                guard let file = item as? ICCameraFile, self.isJPEG(file) else { continue }
                let key = self.fileKey(file)
                if self.knownHandles.contains(key) || self.downloading.contains(key) { continue }
                self.download(file, on: camera, key: key)
            }
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            if device === self.camera {
                self.camera = nil
                self.connected = false
                self.status = "相機已移除"
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: (any Error)?) {
        Task { @MainActor in
            if let error {
                self.lastError = error.localizedDescription
            }
        }
    }
}

