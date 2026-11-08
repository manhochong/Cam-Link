import Foundation

/// Uses the session already opened by CameraCaptureService. Never opens/closes a
/// PTP session or sends camera-property, vendor, shutter or destructive commands.
@MainActor
final class PTPPhotoReceiver {
    struct State {
        let catalogCount: Int
        let queuedCount: Int
        let failedCount: Int
        let receivedCount: Int
        let catalogReady: Bool
        let finishing: Bool
        let status: String
        let lastError: String
    }

    private let reader: PTPCameraReader
    private let mode: CameraCaptureService.ReceiveMode
    private let folder: URL
    private let trace: (String) -> Void
    private let onState: (State) -> Void
    private let onJPEG: (ReceivedJPEG) -> Void
    private let onFinished: (String?) -> Void
    private var generation = UUID()
    private var cancelled = false
    private var halted = false
    private var task: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var timer: Timer?
    private var deviceChecked = false
    private var baselineComplete = false
    private var finishing = false
    private var finalScanComplete = false
    private var wantsScan = true
    private var inventoryHandles = Set<UInt32>()
    private var handled = Set<UInt32>()
    private var failed = Set<UInt32>()
    private var pendingEvents = Set<UInt32>()
    private var queue: [UInt32] = []
    private var active: UInt32?
    private var retries: [UInt32: Int] = [:]
    private var retryAfter: [UInt32: Date] = [:]
    private var received = 0
    private var status = "正在讀取 PTP 新目錄，請先不要拍攝…"
    private var lastError = ""

    nonisolated private static let maxObjectBytes = 128 * 1024 * 1024
    nonisolated private static let diskReserve: Int64 = 512 * 1024 * 1024
    nonisolated private static let retryDelays: [Double] = [0.5, 1, 2, 4, 8, 16]

    private struct ReceiveFailure: LocalizedError, Sendable {
        let reason: String
        let domain: String
        let code: Int
        let retryable: Bool
        var errorDescription: String? { reason }
    }

    init(reader: PTPCameraReader, mode: CameraCaptureService.ReceiveMode, folder: URL,
         trace: @escaping (String) -> Void, onState: @escaping (State) -> Void,
         onJPEG: @escaping (ReceivedJPEG) -> Void, onFinished: @escaping (String?) -> Void) {
        self.reader = reader
        self.mode = mode
        self.folder = folder
        self.trace = trace
        self.onState = onState
        self.onJPEG = onJPEG
        self.onFinished = onFinished
    }

    func start() {
        guard !cancelled else { return }
        publish()
        if !finishing, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reconcile() }
            }
        }
        launchPump()
    }

    /// Callback entry point: enqueue only; commands run later in the single pump.
    func receiveEvent(_ event: PTPEvent) {
        guard !cancelled, !halted, event.code == 0x4002,
              let handle = event.parameters.first, handle != 0, handle != UInt32.max else { return }
        trace("PTP_OBJECT_ADDED handle=\(handle) baseline=\(baselineComplete)")
        if baselineComplete { enqueue(handle) }
        else { pendingEvents.insert(handle) }
        publish()
        launchPump()
    }

    func reconcile() {
        guard !cancelled, !halted, !finishing, task == nil else { return }
        // Poll only while idle. A slow multi-storage scan or a busy transfer
        // must not accumulate timer scans that starve the download queue.
        wantsScan = true
        launchPump()
    }

    func retryFailed() {
        guard !cancelled else { return }
        guard !halted else {
            lastError = "PTP 通道已停止；請匯出診斷，停止接收並重新接線後再試。"
            status = "PTP 接收需要檢查"
            publish()
            return
        }
        let handles = failed.sorted()
        failed.removeAll()
        for handle in handles {
            retries.removeValue(forKey: handle)
            retryAfter.removeValue(forKey: handle)
            enqueue(handle)
        }
        lastError = ""
        wantsScan = true
        trace("PTP_MANUAL_RETRY handles=\(handles.count) baseline=\(baselineComplete)")
        publish()
        launchPump()
    }

    func finish() {
        guard !cancelled, !finishing else { return }
        timer?.invalidate()
        timer = nil
        finishing = true
        finalScanComplete = false
        wantsScan = true
        status = "正在完成 PTP 接收及最後目錄核對，請保持相機連線…"
        trace("PTP_DRAIN pending=\(queue.count + (active == nil ? 0 : 1))")
        publish()
        if halted { onFinished(lastError); return }
        launchPump()
    }

    func cancel() {
        generation = UUID()
        cancelled = true
        timer?.invalidate()
        timer = nil
        wakeTask?.cancel()
        wakeTask = nil
        task?.cancel()
        task = nil
        reader.cancel()
        queue.removeAll()
        pendingEvents.removeAll()
        active = nil
        // A detached persistence already in progress may retain its VALID file.
        // Its old-generation result must not be published into a later session.
    }

    private func valid(_ token: UUID) -> Bool {
        token == generation && !cancelled && !Task.isCancelled
    }

    private func publish() {
        onState(State(catalogCount: inventoryHandles.count,
                      queuedCount: queue.count + (active == nil ? 0 : 1),
                      failedCount: failed.count, receivedCount: received,
                      catalogReady: baselineComplete, finishing: finishing,
                      status: status, lastError: lastError))
    }

    private func enqueue(_ handle: UInt32) {
        guard handle != 0, handle != UInt32.max, !handled.contains(handle),
              !failed.contains(handle), active != handle, !queue.contains(handle) else { return }
        queue.append(handle)
    }

    private func launchPump() {
        guard task == nil, !cancelled, !halted else { return }
        wakeTask?.cancel()
        wakeTask = nil
        let token = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(token)
            guard self.valid(token) else { return }
            self.task = nil
            self.scheduleWake()
        }
    }

    private func scheduleWake() {
        guard !cancelled, !halted else { return }
        let scanReady = finishing ? (!finalScanComplete && queue.isEmpty) : wantsScan
        if scanReady || queue.contains(where: { (retryAfter[$0] ?? .distantPast) <= Date() }) {
            launchPump()
            return
        }
        guard let next = queue.compactMap({ retryAfter[$0] }).min() else { return }
        let token = generation
        let delay = max(0.01, next.timeIntervalSinceNow)
        wakeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard let self, self.valid(token) else { return }
            self.wakeTask = nil
            self.launchPump()
        }
    }

    private func run(_ token: UUID) async {
        if !deviceChecked {
            do {
                let info = try await withTransientRetries("DEVICE_INFO", token: token) {
                    try await self.reader.deviceInfo()
                }
                guard valid(token) else { return }
                let operations = info.operations.sorted().map { String(format: "%04X", $0) }.joined(separator: ",")
                trace("PTP_DEVICE manufacturer=\(info.manufacturer) model=\(info.model) version=\(info.version) operations=\(operations)")
                let required: Set<UInt16> = [0x1004, 0x1007, 0x1008, 0x1009]
                guard required.isSubset(of: info.operations) else {
                    halt("相機未宣告完整的標準唯讀 PTP 讀取功能；請匯出診斷。")
                    return
                }
                deviceChecked = true
            } catch {
                guard valid(token) else { return }
                halt("無法查詢 PTP 相機資料：\(Self.describe(error))。請匯出診斷並重新接線。")
                return
            }
        }

        while valid(token), !halted {
            let scanReady = finishing ? (!finalScanComplete && queue.isEmpty) : wantsScan
            if !baselineComplete || scanReady {
                wantsScan = false
                // First drain work already queued. Then take one final inventory
                // and drain its new handles. A baseline is never the final scan.
                // A finish requested DURING an older scan gets a later final scan.
                let isFinalScan = finishing && baselineComplete && queue.isEmpty
                status = baselineComplete
                    ? (finishing ? "正在核對最後 PTP 目錄，請保持相機連線…" : "正在核對 PTP 相機目錄…")
                    : "正在讀取 PTP 新目錄，請先不要拍攝…"
                publish()
                do {
                    // Reader returns only after ALL storage IDs have been queried.
                    // Never commit a baseline from a partial inventory or an event.
                    let handles = try await withTransientRetries("INVENTORY", token: token) {
                        try await self.reader.inventory()
                    }
                    guard valid(token) else { return }
                    inventoryHandles = Set(handles.filter { $0 != 0 && $0 != UInt32.max })
                    if !baselineComplete {
                        if mode == .newPhotos { handled.formUnion(inventoryHandles) }
                        baselineComplete = true
                        trace("PTP_BASELINE_COMPLETE handles=\(inventoryHandles.count) mode=\(mode.rawValue)")
                        for handle in pendingEvents.sorted() { enqueue(handle) }
                        pendingEvents.removeAll()
                    } else {
                        trace("PTP_INVENTORY_COMPLETE handles=\(inventoryHandles.count) final=\(isFinalScan)")
                    }
                    for handle in inventoryHandles.sorted() { enqueue(handle) }
                    if isFinalScan { finalScanComplete = true }
                    publish()
                } catch {
                    guard valid(token) else { return }
                    halt("PTP 完整目錄查詢失敗：\(Self.describe(error))。未建立不完整基準；請匯出診斷並重新接線。")
                    return
                }
                continue
            }

            guard let index = queue.firstIndex(where: { (retryAfter[$0] ?? .distantPast) <= Date() }) else {
                if finishing, finalScanComplete, queue.isEmpty {
                    let reason: String?
                    if !failed.isEmpty || !lastError.isEmpty {
                        reason = "PTP 接收結束但仍有 \(failed.count) 個失敗物件；\(lastError) 請匯出診斷或重新接線補收。"
                    } else if inventoryHandles.isEmpty, received == 0 {
                        reason = "完整 PTP 目錄仍未發現相片物件，沒有照片被接收；請匯出診斷。"
                    } else {
                        reason = nil
                    }
                    trace("PTP_DRAIN_COMPLETE received=\(received) failed=\(failed.count)")
                    onFinished(reason)
                } else {
                    idleStatus()
                    publish()
                }
                return
            }
            let handle = queue.remove(at: index)
            active = handle
            retryAfter.removeValue(forKey: handle)
            status = "正在查詢 PTP 相片 \(handle)…"
            publish()
            await receive(handle, token: token)
            guard valid(token) else { return }
            active = nil
            publish()
        }
    }

    private func idleStatus() {
        if !lastError.isEmpty || !failed.isEmpty { status = "PTP 接收需要檢查 · 可重新搜尋及重試" }
        else if finishing { status = "正在等待 PTP 重試完成，請保持相機連線…" }
        else if !queue.isEmpty { status = "相片尚未就緒 · 正在等待有限次 PTP 重試…" }
        else if inventoryHandles.isEmpty { status = "PTP 已連線 · 目錄仍為空，持續監聽新 JPG；若拍攝後仍無接收請匯出診斷" }
        else if mode == .card, received == 0 { status = "PTP 目錄尚無可接收的 JPG · 請確認照片格式" }
        else { status = mode == .card ? "PTP 卡內 JPG 已收下 · 等待新 JPG" : "可以拍攝 · PTP 等待新 JPG" }
    }

    private func receive(_ handle: UInt32, token: UUID) async {
        do {
            let info = try await reader.objectInfo(handle)
            guard valid(token) else { return }
            guard info.isJPEG else {
                handled.insert(handle)
                trace("PTP_IGNORE_NON_JPEG handle=\(handle) name=\(info.name) format=\(String(format: "%04X", info.format))")
                return
            }
            guard info.size != 0 else {
                throw ReceiveFailure(reason: "相片大小仍為 0，可能仍在寫入", domain: "CamLink.PTPPhotoReceiver", code: 1, retryable: true)
            }
            guard info.size > 0, info.size == Int64(UInt32.max) || info.size <= Int64(Self.maxObjectBytes) else {
                throw ReceiveFailure(reason: "照片超過單張 128 MB 接收上限或大小無效：\(info.size)", domain: "CamLink.PTPPhotoReceiver", code: 2, retryable: false)
            }
            let directory = folder
            let expected = info.size
            let required = expected == Int64(UInt32.max) ? Int64(Self.maxObjectBytes) : expected
            try await Task.detached(priority: .utility) {
                try Self.checkDisk(directory, bytes: required)
            }.value
            guard valid(token) else { return }
            let name = CameraCaptureService.safeName(info.name)
            status = "正在接收 \(name)（PTP）…"
            trace("PTP_DOWNLOAD_BEGIN handle=\(handle) name=\(name) expected=\(expected) maxBytes=\(Self.maxObjectBytes)")
            publish()
            // The ImageCaptureCore callback returns whole Data, NOT a stream.
            // Only one object buffer/transfer is owned at a time. All byte work,
            // filesystem operations, JPEG validation and SHA hashing run detached.
            let photo = try await fetchAndPersist(handle, name: name, expected: expected, folder: directory, token: token)
            guard valid(token) else { return }
            handled.insert(handle)
            failed.remove(handle)
            retries.removeValue(forKey: handle)
            received += 1
            trace("PTP_DOWNLOAD_OK handle=\(handle) name=\(name) bytes=\(photo.bytes)")
            onJPEG(photo)
        } catch {
            guard valid(token) else { return }
            let detail = Self.describe(error)
            trace("PTP_OBJECT_ERROR handle=\(handle) \(detail)")
            if let response = error as? PTPResponseError {
                if response.code == 0x2019 || response.code == 0x2009 {
                    retry(handle, reason: detail)
                } else if response.code == 0x2003 || response.code == 0x2005 {
                    failed.insert(handle)
                    halt("PTP 讀取通道不可用：\(detail)。請匯出診斷並重新接線。")
                } else {
                    markFailed(handle, reason: detail)
                }
            } else if let local = error as? ReceiveFailure {
                if local.retryable { retry(handle, reason: detail) }
                else { markFailed(handle, reason: detail) }
            } else {
                // A reader timeout/cancellation poisons its transaction channel;
                // do NOT repeatedly send new commands on that same client.
                failed.insert(handle)
                halt("PTP 讀取已停止：\(detail)。請匯出診斷，停止接收並重新接線。")
            }
        }
    }

    private func fetchAndPersist(_ handle: UInt32, name: String, expected: Int64,
                                 folder: URL, token: UUID) async throws -> ReceivedJPEG {
        let data = try await reader.object(handle, maxBytes: Self.maxObjectBytes)
        guard valid(token) else { throw CancellationError() }
        // This scope ends before the next pump iteration; no buffer is cached.
        return try await Task.detached(priority: .utility) {
            try Self.persist(data, name: name, expected: expected, folder: folder)
        }.value
    }

    private func retry(_ handle: UInt32, reason: String) {
        let count = retries[handle, default: 0]
        guard count < Self.retryDelays.count else { markFailed(handle, reason: "6 次有限重試後仍未完成：\(reason)"); return }
        let delay = Self.retryDelays[count]
        retries[handle] = count + 1
        retryAfter[handle] = Date().addingTimeInterval(delay)
        // active still owns the handle, so append the retry explicitly.
        if !queue.contains(handle) { queue.append(handle) }
        trace("PTP_OBJECT_RETRY handle=\(handle) retry=\(count + 1)/6 delay=\(delay) reason=\(reason)")
    }

    private func markFailed(_ handle: UInt32, reason: String) {
        failed.insert(handle)
        retryAfter.removeValue(forKey: handle)
        retries.removeValue(forKey: handle)
        lastError = "PTP 物件 \(handle)：\(reason)。可重新搜尋及重試；若仍失敗請匯出診斷。"
        status = "PTP 接收需要檢查"
        trace("PTP_OBJECT_FAILED handle=\(handle) reason=\(reason)")
    }

    private func halt(_ reason: String) {
        halted = true
        timer?.invalidate()
        timer = nil
        wakeTask?.cancel()
        wakeTask = nil
        reader.cancel()
        failed.formUnion(queue)
        queue.removeAll()
        active = nil
        lastError = reason
        status = "PTP 接收需要檢查 · 請匯出診斷"
        trace("PTP_HALTED \(reason)")
        publish()
        if finishing { onFinished(reason) }
    }

    private func withTransientRetries<T: Sendable>(_ label: String, token: UUID,
                                                   operation: @MainActor () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            guard valid(token) else { throw CancellationError() }
            do { return try await operation() }
            catch let error as PTPResponseError where error.code == 0x2019 || error.code == 0x2009 {
                guard valid(token), attempt < Self.retryDelays.count else { throw error }
                let delay = Self.retryDelays[attempt]
                attempt += 1
                trace("PTP_\(label)_RETRY retry=\(attempt)/6 delay=\(delay) \(Self.describe(error))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        if let local = error as? ReceiveFailure {
            return "domain=\(local.domain) code=\(local.code) \(local.reason)"
        }
        let ns = error as NSError
        if let response = error as? PTPResponseError {
            return "domain=\(ns.domain) code=\(ns.code) ptp=\(String(format: "%04X", response.code)) \(error.localizedDescription)"
        }
        return "domain=\(ns.domain) code=\(ns.code) \(error.localizedDescription)"
    }

    nonisolated private static func checkDisk(_ folder: URL, bytes: Int64) throws {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: folder.path)
            guard let available = (attributes[.systemFreeSize] as? NSNumber)?.int64Value,
                  available >= bytes + diskReserve else {
                throw ReceiveFailure(reason: "儲存空間不足；接收後須保留至少 512 MB", domain: "CamLink.PTPPhotoReceiver", code: 3, retryable: false)
            }
        } catch let error as ReceiveFailure { throw error }
        catch {
            let ns = error as NSError
            throw ReceiveFailure(reason: error.localizedDescription, domain: ns.domain, code: ns.code, retryable: false)
        }
    }

    nonisolated private static func persist(_ data: Data, name: String, expected: Int64,
                                            folder: URL) throws -> ReceivedJPEG {
        guard data.count <= maxObjectBytes else {
            throw ReceiveFailure(reason: "照片超過單張 128 MB 接收上限", domain: "CamLink.PTPPhotoReceiver", code: 2, retryable: false)
        }
        try checkDisk(folder, bytes: Int64(data.count))
        let id = UUID().uuidString
        let temporary = folder.appendingPathComponent(".\(id).ptp-part")
        let destination = folder.appendingPathComponent("\(id)_\(name)")
        // Only this attempt's temporary file is removed on failure. Never remove
        // a prior validated original, including when cancellation changes tokens.
        defer { if FileManager.default.fileExists(atPath: temporary.path) { try? FileManager.default.removeItem(at: temporary) } }
        do {
            try data.write(to: temporary, options: .atomic)
            let verified: CameraCaptureService.VerifiedJPEG
            switch CameraCaptureService.validateJPEG(temporary, expected: expected) {
            case .success(let value): verified = value
            case .failure(let error):
                throw ReceiveFailure(reason: error.localizedDescription, domain: "CamLink.JPEGValidation", code: 4, retryable: true)
            }
            // Same-directory rename publishes only a complete, validated file.
            try FileManager.default.moveItem(at: temporary, to: destination)
            return ReceivedJPEG(id: id, name: name, url: destination, bytes: verified.bytes,
                                sha256: verified.sha, createdAt: Date(), uploaded: false)
        } catch let error as ReceiveFailure { throw error }
        catch {
            let ns = error as NSError
            throw ReceiveFailure(reason: error.localizedDescription, domain: ns.domain, code: ns.code, retryable: false)
        }
    }
}
