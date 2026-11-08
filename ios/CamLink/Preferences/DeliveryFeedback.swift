import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
typealias DeliveryFeedbackObservable = ObservableObject
#else
protocol DeliveryFeedbackObservable: AnyObject {}
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AudioToolbox) && canImport(UIKit)
import AudioToolbox
#endif
#if canImport(UserNotifications) && canImport(UIKit)
import UserNotifications
#endif
#if canImport(Network) && canImport(UIKit)
import Network
#endif

// No camera operations, credentials, remote writes, photo deletion or background entitlement.
enum FeedbackProvider: String, Codable, CaseIterable, Sendable {
    case receiver, computer, secondComputer, googleDrive, oneDrive, webDAV, sharing, application
    var title: String {
        switch self {
        case .receiver: return "本機接收"
        case .computer: return "電腦 1"
        case .secondComputer: return "電腦 2"
        case .googleDrive: return "Google Drive"
        case .oneDrive: return "OneDrive"
        case .webDAV: return "WebDAV"
        case .sharing: return "系統分享"
        case .application: return "App"
        }
    }
    static var uploadDestinations: [Self] { [.computer, .secondComputer, .googleDrive, .oneDrive, .webDAV] }
}

enum ReceiveScanInterval: String, Codable, CaseIterable, Sendable {
    case balanced, lowInterference, experimental
    var seconds: TimeInterval {
        switch self { case .balanced: return 2; case .lowInterference: return 5; case .experimental: return 0.5 }
    }
    var title: String {
        switch self {
        case .balanced: return "平衡 · 每 2 秒補掃"
        case .lowInterference: return "低干擾 · 每 5 秒補掃"
        case .experimental: return "快速實驗 · 每 0.5 秒補掃"
        }
    }
    func seconds(forCardImport: Bool) -> TimeInterval { forCardImport ? max(2, seconds) : seconds }
}

struct DeliveryPreferences: Codable, Equatable, Sendable {
    var soundEnabled = false
    var vibrationEnabled = false
    var tactileEnabled = false
    var localNotificationsEnabled = false
    var wifiOnlyByDestination: [FeedbackProvider: Bool] = [:]
    var allowExpensiveNetworks = false
    var allowConstrainedNetworks = false
    var scanInterval: ReceiveScanInterval = .balanced
    // Absent destination settings deliberately default to Wi-Fi only.
    func wifiOnly(for provider: FeedbackProvider) -> Bool { wifiOnlyByDestination[provider] ?? true }
}

struct FeedbackNetworkPath: Equatable, Sendable {
    var known = false
    var satisfied = false
    var usesWiFi = false
    var usesCellular = false
    var usesEthernet = false
    var expensive = false
    var constrained = false
}

enum UploadRestriction: String, Codable, Equatable, Sendable {
    case unknownPath, offline, wifiRequired, expensiveNetwork, constrainedNetwork
    var text: String {
        switch self {
        case .unknownPath: return "正在檢查系統可用網路路徑，暫不開始新上傳。"
        case .offline: return "系統目前沒有可用網路路徑；已收原圖保留，等待恢復。"
        case .wifiRequired: return "此目的地只用 Wi-Fi；目前路徑不是可確認的非流動 Wi-Fi，暫停新傳送。"
        case .expensiveNetwork: return "目前是系統標示的高成本網路（可包含個人熱點），設定暫不允許。"
        case .constrainedNetwork: return "目前開啟低數據模式，設定暫不允許。"
        }
    }
}

struct UploadNetworkDecision: Equatable, Sendable {
    let restriction: UploadRestriction?
    var allowsUploads: Bool { restriction == nil }
    var aboutRestrictedNetwork: String {
        restriction?.text ?? "系統目前可用路徑符合設定；這不保證目的地可達或已完成上傳。"
    }
    static func evaluate(preferences: DeliveryPreferences, provider: FeedbackProvider,
                         path: FeedbackNetworkPath) -> Self {
        if !path.known { return Self(restriction: .unknownPath) }
        if !path.satisfied { return Self(restriction: .offline) }
        // A path eligible for both Wi-Fi and cellular is not treated as exclusively Wi-Fi.
        if preferences.wifiOnly(for: provider) && (!path.usesWiFi || path.usesCellular) {
            return Self(restriction: .wifiRequired)
        }
        if path.expensive && !preferences.allowExpensiveNetworks { return Self(restriction: .expensiveNetwork) }
        if path.constrained && !preferences.allowConstrainedNetworks { return Self(restriction: .constrainedNetwork) }
        return Self(restriction: nil)
    }
}

enum StoragePreflight: Equatable, Sendable {
    case sufficient(availableBytes: Int64), low(availableBytes: Int64, requiredBytes: Int64), unavailable
    var requiresAcknowledgement: Bool {
        switch self { case .sufficient: return false; case .low, .unavailable: return true }
    }
    var text: String {
        switch self {
        case let .sufficient(bytes):
            return "目前重要用途可用容量約 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))；容量會變動，不能保證整場收完。"
        case let .low(bytes, required):
            return "本機空間偏低：可用約 \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))，建議至少 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))。請先確認空間；App 不會自動刪除任何照片。"
        case .unavailable: return "尚未取得本機可用容量（未檢查或讀取失敗）。開始前請先檢查；App 不會自動清理照片。"
        }
    }
    static func evaluate(availableBytes: Int64?, expectedIncomingBytes: Int64 = 0,
                         reserveBytes: Int64 = 536_870_912) -> Self {
        guard let available = availableBytes, available >= 0 else { return .unavailable }
        let expected = max(0, expectedIncomingBytes), reserve = max(0, reserveBytes)
        let sum = expected.addingReportingOverflow(reserve)
        let required = sum.overflow ? Int64.max : sum.partialValue
        return available < required ? .low(availableBytes: available, requiredBytes: required) : .sufficient(availableBytes: available)
    }
}

/// Evidence is supplied ONLY after the actual destination worker has validated its response.
/// OneDrive/Drive optional SHA is explicitly distinguished from full SHA-256 verification.
enum DeliveryVerification: String, Codable, Equatable, Sendable {
    case receiverSHA256, driveSizeMD5Parent, driveSizeMD5ParentSHA256
    case oneDriveSize, oneDriveSizeSHA256, webDAVSizeSHA256
    func supports(_ provider: FeedbackProvider) -> Bool {
        switch self {
        case .receiverSHA256: return provider == .computer || provider == .secondComputer
        case .driveSizeMD5Parent, .driveSizeMD5ParentSHA256: return provider == .googleDrive
        case .oneDriveSize, .oneDriveSizeSHA256: return provider == .oneDrive
        case .webDAVSizeSHA256: return provider == .webDAV
        }
    }
    var title: String {
        switch self {
        case .receiverSHA256: return "Receiver 回覆相同 SHA-256"
        case .driveSizeMD5Parent: return "ID、大小、MD5、parent 已核對；遠端未提供 SHA-256"
        case .driveSizeMD5ParentSHA256: return "ID、大小、MD5、parent、SHA-256 已核對"
        case .oneDriveSize: return "大小已核對；遠端未提供 SHA-256，不是雜湊核對"
        case .oneDriveSizeSHA256: return "大小及 SHA-256 已核對"
        case .webDAVSizeSHA256: return "GET 原圖大小及 SHA-256 已核對"
        }
    }
}

enum FeedbackFailureReason: String, Codable, CaseIterable, Equatable, Sendable {
    case authentication, permission, network, timeout, quota, rateLimited, serverBusy
    case verificationMismatch, localStorage, cameraReceive, configuration, cancelled, unknown
    case notificationPermission, notificationScheduling, diagnosticStorage
    var text: String {
        switch self {
        case .authentication: return "需要重新登入；未完成項目保留。"
        case .permission: return "權限不足，請檢查目的地授權。"
        case .network: return "網路傳送失敗，等待恢復或手動重試。"
        case .timeout: return "傳送逾時，尚未確認成功。"
        case .quota: return "目的地容量不足，請處理後重試。"
        case .rateLimited: return "目的地限制請求頻率，請稍後重試。"
        case .serverBusy: return "目的地忙碌，請稍後重試。"
        case .verificationMismatch: return "完整性核對不符，不會標為已核對。"
        case .localStorage: return "本機儲存需要檢查；不會自動刪除照片。"
        case .cameraReceive: return "本機接收需要檢查，不代表雲端傳送狀態。"
        case .configuration: return "設定或核對證據不完整，請檢查。"
        case .cancelled: return "操作已取消；未完成項目不算成功。"
        case .unknown: return "操作失敗，請查看該目的地狀態並重試。"
        case .notificationPermission: return "未能取得通知授權；前景狀態仍可查看。"
        case .notificationScheduling: return "系統未能接受本機通知，請查看 App 內紀錄。"
        case .diagnosticStorage: return "未能保存診斷事件；照片不受此紀錄錯誤影響。"
        }
    }
    static func classify(_ error: Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            default: return .network
            }
        }
        // Never inspect or retain localizedDescription, userInfo, headers, URLs or provider payloads.
        return .unknown
    }
}

enum FeedbackEventKind: String, Codable, Equatable, Sendable {
    case firstReceived, receiveFinished, receiveIncomplete, uploadAccepted, destinationVerified, issue, lowStorage
}

struct DeliveryFeedbackEvent: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID?
    let provider: FeedbackProvider
    let kind: FeedbackEventKind
    let verification: DeliveryVerification?
    let reason: FeedbackFailureReason?
    let httpStatus: Int?
    let goodCount: Int
    let failedCount: Int
    let pendingCount: Int
    let firstAt: Date
    var lastAt: Date
    var occurrences: Int
    var title: String {
        switch kind {
        case .firstReceived: return "第一張已收到"
        case .receiveFinished: return "本場接收完成"
        case .receiveIncomplete: return "本場接收仍需檢查"
        case .uploadAccepted: return "\(provider.title) 已接受傳送，待核對"
        case .destinationVerified: return "\(provider.title) 核對結果"
        case .issue: return "\(provider.title) 需要處理"
        case .lowStorage: return "開始前請檢查本機空間"
        }
    }
    var detail: String {
        switch kind {
        case .firstReceived: return "本場第一張完整 JPG 已存入 App；不代表任何目的地已收到。"
        case .receiveFinished:
            return "本機已驗證 \(goodCount) 張 JPG，失敗 \(failedCount) 張。接收結束不代表所有目的地交付完成；漏圖仍需與卡內原圖比對。"
        case .receiveIncomplete:
            return "本機已驗證 \(goodCount) 張，失敗 \(failedCount) 張，未完成 \(pendingCount) 張；尚未完成接收。"
        case .uploadAccepted: return "HTTP 接受、排隊或分享完成不是目的地完整性核對；原圖保留。"
        case .destinationVerified: return "\(verification?.title ?? "缺少證據")；只代表此目的地，不代表其他目的地。"
        case .issue: return "\(reason?.text ?? FeedbackFailureReason.unknown.text)\(httpStatus.map { " HTTP \($0)。" } ?? "")"
        case .lowStorage: return "容量不足或未能取得容量；請確認後才開始。App 不會自動刪除照片。"
        }
    }
    var isWarning: Bool { kind == .issue || kind == .receiveIncomplete || kind == .lowStorage || (kind == .receiveFinished && failedCount > 0) }
}

enum FeedbackNotificationAuthorization: String, Sendable {
    case notRequested, denied, authorized, quiet, unavailable
    var text: String {
        switch self {
        case .notRequested: return "尚未要求系統通知權限；只有你按下啟用才會要求。"
        case .denied: return "系統通知未允許；如有需要可到 App 設定開啟。"
        case .authorized: return "系統已授權；是否顯示／發聲仍受通知設定、專注模式與裝置限制。"
        case .quiet: return "系統只允許安靜通知；本模組不會自行申請臨時授權。"
        case .unavailable: return "目前平台無法使用 iOS 本機通知。"
        }
    }
}

@MainActor
final class DeliveryFeedback: DeliveryFeedbackObservable {
    #if canImport(Combine)
    let objectWillChange = ObservableObjectPublisher()
    #endif
    private let defaults: UserDefaults
    private let eventLogURL: URL?
    private static let preferenceKey = "hk.camlink.delivery-feedback.preferences.v1"
    private let eventLimit = 256
    private var foreground = true
    private var requestingPermission = false
    private var lastNativeFeedback: Date?
    private var lastAlerts: [String: Date] = [:]
    private var notificationGeneration = UUID()
    private(set) var preferences: DeliveryPreferences
    private(set) var events: [DeliveryFeedbackEvent] = []
    private(set) var networkPath = FeedbackNetworkPath()
    private(set) var banner: DeliveryFeedbackEvent?
    private(set) var notificationAuthorization: FeedbackNotificationAuthorization = .notRequested
    private(set) var notificationStatus = ""
    private(set) var diagnosticStatus = ""
    private(set) var storageStatus: StoragePreflight = .unavailable
    /// Parent restarts its durable destination workers on this callback; this class never uploads.
    var onUploadPolicyChange: (() -> Void)?
    #if canImport(Network) && canImport(UIKit)
    private var pathMonitor: NWPathMonitor?
    #endif
    #if canImport(AudioToolbox) && canImport(UIKit)
    private var toneID: SystemSoundID = 0
    #endif

    nonisolated static var defaultEventLogURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CamLinkFeedback-v1", isDirectory: true).appendingPathComponent("events.json")
    }
    init(defaults: UserDefaults = .standard, eventLogURL: URL? = DeliveryFeedback.defaultEventLogURL,
         monitorNetwork: Bool = true) {
        self.defaults = defaults
        self.eventLogURL = eventLogURL
        if let data = defaults.data(forKey: Self.preferenceKey), data.count <= 16_384,
           let saved = try? JSONDecoder().decode(DeliveryPreferences.self, from: data) {
            preferences = saved
        } else { preferences = DeliveryPreferences() }
        if let url = eventLogURL, let data = try? Data(contentsOf: url), data.count <= 1_048_576,
           let saved = try? JSONDecoder().decode([DeliveryFeedbackEvent].self, from: data) {
            events = Array(saved.filter(Self.validPersistedEvent).suffix(eventLimit))
        }
        #if canImport(Network) && canImport(UIKit)
        if monitorNetwork {
            let monitor = NWPathMonitor()
            pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let snapshot = FeedbackNetworkPath(known: true, satisfied: path.status == .satisfied,
                    usesWiFi: path.usesInterfaceType(.wifi), usesCellular: path.usesInterfaceType(.cellular),
                    usesEthernet: path.usesInterfaceType(.wiredEthernet), expensive: path.isExpensive,
                    constrained: path.isConstrained)
                Task { @MainActor [weak self] in self?.updateNetworkPath(snapshot) }
            }
            monitor.start(queue: DispatchQueue(label: "hk.camlink.feedback.path"))
        }
        #endif
    }
    private func changed() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
    }
    func updatePreferences(_ change: (inout DeliveryPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        changed()
        let old = preferences
        preferences = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.preferenceKey) }
        if old.localNotificationsEnabled && !next.localNotificationsEnabled { notificationGeneration = UUID() }
        if old.wifiOnlyByDestination != next.wifiOnlyByDestination || old.allowExpensiveNetworks != next.allowExpensiveNetworks || old.allowConstrainedNetworks != next.allowConstrainedNetworks {
            onUploadPolicyChange?()
        }
        // No OS permission request here, including when loading settings or programmatically enabling.
    }
    func setWiFiOnly(_ enabled: Bool, for provider: FeedbackProvider) {
        updatePreferences { $0.wifiOnlyByDestination[provider] = enabled }
    }
    func updateNetworkPath(_ path: FeedbackNetworkPath) {
        guard path != networkPath else { return }
        changed(); networkPath = path; onUploadPolicyChange?()
    }
    func networkDecision(for provider: FeedbackProvider) -> UploadNetworkDecision {
        UploadNetworkDecision.evaluate(preferences: preferences, provider: provider, path: networkPath)
    }
    func allowsUploads(to provider: FeedbackProvider) -> Bool { networkDecision(for: provider).allowsUploads }
    func aboutRestrictedNetwork(for provider: FeedbackProvider) -> String { networkDecision(for: provider).aboutRestrictedNetwork }
    /// Apply BEFORE creating a new URLSession. Existing sessions/tasks must be replaced/cancelled by their owner on a restrictive change.
    func configureUploadSession(_ configuration: URLSessionConfiguration, for provider: FeedbackProvider) {
        configuration.allowsCellularAccess = !preferences.wifiOnly(for: provider)
        #if canImport(Darwin)
        configuration.allowsExpensiveNetworkAccess = preferences.allowExpensiveNetworks
        configuration.allowsConstrainedNetworkAccess = preferences.allowConstrainedNetworks
        #endif
    }
    /// Reapply on EVERY upload/probe/verification request or chunk, not only when the queue starts.
    func configureUploadRequest(_ request: inout URLRequest, for provider: FeedbackProvider) {
        request.allowsCellularAccess = !preferences.wifiOnly(for: provider)
        #if canImport(Darwin)
        request.allowsExpensiveNetworkAccess = preferences.allowExpensiveNetworks
        request.allowsConstrainedNetworkAccess = preferences.allowConstrainedNetworks
        #endif
    }
    func setForegroundActive(_ active: Bool) { foreground = active }
    func dismissBanner() { changed(); banner = nil }

    /// Read-only preflight. Parent must show confirmation if requiresAcknowledgement before its existing start action.
    @discardableResult
    func checkStorage(at existingLocalDirectory: URL, expectedIncomingBytes: Int64 = 0,
                      reserveBytes: Int64 = 536_870_912) -> StoragePreflight {
        var available: Int64?
        #if canImport(Darwin)
        if existingLocalDirectory.isFileURL,
           let resources = try? existingLocalDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            available = resources.volumeAvailableCapacityForImportantUsage
        }
        #endif
        let status = StoragePreflight.evaluate(availableBytes: available, expectedIncomingBytes: expectedIncomingBytes, reserveBytes: reserveBytes)
        changed(); storageStatus = status
        // Never persist/export capacity values or paths. Only a fixed local warning code enters the log.
        if status.requiresAcknowledgement { emit(provider: .application, kind: .lowStorage, reason: .localStorage) }
        return status
    }

    /// Call after a COMPLETE locally validated JPG has been finalized, once per real capture run UUID.
    func firstReceived(sessionID: UUID) {
        guard !events.contains(where: { $0.sessionID == sessionID && $0.kind == .firstReceived }) else { return }
        emit(provider: .receiver, kind: .firstReceived, sessionID: sessionID, good: 1)
    }
    /// A drained, clean local receive stop is not a global delivery/completeness receipt.
    func receivingFinished(sessionID: UUID, verified: Int, failed: Int, pending: Int, cleanStop: Bool) {
        let good = max(0, verified), bad = max(0, failed), waiting = max(0, pending)
        let kind: FeedbackEventKind = cleanStop && waiting == 0 ? .receiveFinished : .receiveIncomplete
        emit(provider: .receiver, kind: kind, sessionID: sessionID, good: good, failed: bad, pending: waiting)
    }
    func uploadAccepted(by provider: FeedbackProvider, sessionID: UUID? = nil) {
        guard FeedbackProvider.uploadDestinations.contains(provider) || provider == .sharing else { return }
        emit(provider: provider, kind: .uploadAccepted, sessionID: sessionID, alert: false)
    }
    /// Returns false rather than displaying success if evidence belongs to a different destination.
    @discardableResult
    func destinationVerified(_ provider: FeedbackProvider, evidence: DeliveryVerification, sessionID: UUID? = nil) -> Bool {
        guard evidence.supports(provider) else {
            recordFailure(provider: provider, reason: .configuration, sessionID: sessionID)
            return false
        }
        emit(provider: provider, kind: .destinationVerified, sessionID: sessionID, verification: evidence)
        return true
    }
    func recordFailure(provider: FeedbackProvider, reason: FeedbackFailureReason,
                       httpStatus: Int? = nil, sessionID: UUID? = nil) {
        let status = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        emit(provider: provider, kind: .issue, sessionID: sessionID, reason: reason, httpStatus: status)
    }
    private func emit(provider: FeedbackProvider, kind: FeedbackEventKind, sessionID: UUID? = nil,
                      verification: DeliveryVerification? = nil, reason: FeedbackFailureReason? = nil,
                      httpStatus: Int? = nil, good: Int = 0, failed: Int = 0, pending: Int = 0, alert: Bool = true) {
        let now = Date()
        changed()
        var event = DeliveryFeedbackEvent(id: UUID(), sessionID: sessionID, provider: provider, kind: kind,
            verification: verification, reason: reason, httpStatus: httpStatus, goodCount: good,
            failedCount: failed, pendingCount: pending, firstAt: now, lastAt: now, occurrences: 1)
        // Consolidate only consecutive equal errors, never merge different providers or sessions.
        if kind == .issue, var last = events.last, last.kind == kind, last.provider == provider,
           last.sessionID == sessionID, last.reason == reason, last.httpStatus == httpStatus {
            last.lastAt = now
            last.occurrences = min(1_000_000, last.occurrences + 1)
            events[events.count - 1] = last
            event = last
        } else { events.append(event) }
        if events.count > eventLimit { events = Array(events.suffix(eventLimit)) }
        persistEvents()
        guard alert else { return }
        let key = "\(provider.rawValue):\(kind.rawValue):\(reason?.rawValue ?? ""):\(httpStatus ?? 0)"
        if let last = lastAlerts[key], now.timeIntervalSince(last) < 30, kind == .issue || kind == .lowStorage { return }
        lastAlerts[key] = now
        banner = event
        if foreground { playNativeFeedback(event, at: now) }
        else { scheduleNotification(event) }
    }
    private func persistEvents() {
        guard let url = eventLogURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(events).write(to: url, options: .atomic)
            diagnosticStatus = "非秘密事件紀錄已保存（最多 256 筆）；不包含帳號、檔名、路徑、URL 或權杖。"
        } catch { diagnosticStatus = FeedbackFailureReason.diagnosticStorage.text }
    }
    private nonisolated static func validPersistedEvent(_ event: DeliveryFeedbackEvent) -> Bool {
        guard event.firstAt.timeIntervalSince1970.isFinite, event.lastAt.timeIntervalSince1970.isFinite,
              event.goodCount >= 0, event.failedCount >= 0, event.pendingCount >= 0,
              (1...1_000_000).contains(event.occurrences),
              event.httpStatus == nil || (100...599).contains(event.httpStatus!) else { return false }
        if event.kind == .destinationVerified { return event.verification?.supports(event.provider) == true }
        return event.verification == nil
    }
    /// Non-secret support export in memory. Parent can share/write only this data to a NEW owned report.
    func diagnosticData() throws -> Data { try JSONEncoder().encode(events) }
    func diagnosticText() -> String {
        let formatter = ISO8601DateFormatter()
        let lines = events.map {
            "\(formatter.string(from: $0.firstAt))\t\(formatter.string(from: $0.lastAt))\t\($0.provider.rawValue)\t\($0.kind.rawValue)\t\($0.reason?.rawValue ?? "-")\t\($0.httpStatus.map(String.init) ?? "-")\t\($0.verification?.rawValue ?? "-")\tgood=\($0.goodCount) failed=\($0.failedCount) pending=\($0.pendingCount) occurrences=\($0.occurrences)"
        }
        return (["CamLink non-secret feedback events v1", "Local receipt != destination verification != card completeness", "No photo, credential, URL, account or available-capacity data"] + lines).joined(separator: "\n") + "\n"
    }

    /// Sole permission-request entry point. Invoke ONLY from an explicit user Enable button/toggle.
    @discardableResult
    func enableLocalNotificationsFromUserAction() async -> Bool {
        guard !requestingPermission else { return false }
        requestingPermission = true
        defer { requestingPermission = false }
        let generation = UUID()
        notificationGeneration = generation
        updatePreferences { $0.localNotificationsEnabled = true }
        #if canImport(UserNotifications) && canImport(UIKit)
        let center = UNUserNotificationCenter.current()
        do {
            let before = await center.notificationSettings()
            if before.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            }
            await refreshNotificationAuthorization()
            guard generation == notificationGeneration, preferences.localNotificationsEnabled else { return false }
            let granted = notificationAuthorization == .authorized || notificationAuthorization == .quiet
            if !granted { updatePreferences { $0.localNotificationsEnabled = false } }
            return granted
        } catch {
            guard generation == notificationGeneration else { return false }
            changed(); notificationStatus = FeedbackFailureReason.notificationPermission.text
            updatePreferences { $0.localNotificationsEnabled = false }
            return false
        }
        #else
        changed(); notificationAuthorization = .unavailable
        updatePreferences { $0.localNotificationsEnabled = false }
        return false
        #endif
    }
    func disableLocalNotifications() {
        notificationGeneration = UUID()
        updatePreferences { $0.localNotificationsEnabled = false }
        #if canImport(UserNotifications) && canImport(UIKit)
        // Only our own known notification IDs; never remove other providers' notifications.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: Self.notificationIDs)
        #endif
    }
    func refreshNotificationAuthorization() async {
        #if canImport(UserNotifications) && canImport(UIKit)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        changed()
        switch settings.authorizationStatus {
        case .notDetermined: notificationAuthorization = .notRequested
        case .denied: notificationAuthorization = .denied
        case .authorized: notificationAuthorization = .authorized
        case .provisional, .ephemeral: notificationAuthorization = .quiet
        @unknown default: notificationAuthorization = .unavailable
        }
        notificationStatus = notificationAuthorization.text
        #else
        changed(); notificationAuthorization = .unavailable; notificationStatus = notificationAuthorization.text
        #endif
    }
    private nonisolated static var notificationIDs: [String] {
        FeedbackProvider.allCases.flatMap { provider in
            [FeedbackEventKind.firstReceived, .receiveFinished, .receiveIncomplete, .destinationVerified, .issue, .lowStorage].map {
                "hk.camlink.feedback.\(provider.rawValue).\($0.rawValue)"
            }
        }
    }
    private func scheduleNotification(_ event: DeliveryFeedbackEvent) {
        guard preferences.localNotificationsEnabled else { return }
        #if canImport(UserNotifications) && canImport(UIKit)
        let generation = notificationGeneration
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard !Task.isCancelled, self.notificationGeneration == generation,
                  self.preferences.localNotificationsEnabled, !self.foreground,
                  settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional || settings.authorizationStatus == .ephemeral else { return }
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.detail
            if self.preferences.soundEnabled && settings.soundSetting == .enabled { content.sound = .default }
            // No badges, remote notifications, critical alerts, background tasks or notification delegate takeover.
            let identifier = "hk.camlink.feedback.\(event.provider.rawValue).\(event.kind.rawValue)"
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                if self.notificationGeneration != generation || !self.preferences.localNotificationsEnabled {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                }
            } catch { self.changed(); self.notificationStatus = FeedbackFailureReason.notificationScheduling.text }
        }
        #endif
    }
    private func playNativeFeedback(_ event: DeliveryFeedbackEvent, at now: Date) {
        // Accepted-only events never get a success cue. Throttle bursts without dropping the event log/banner.
        guard event.kind != .uploadAccepted else { return }
        if let last = lastNativeFeedback, now.timeIntervalSince(last) < 2 { return }
        lastNativeFeedback = now
        #if canImport(UIKit)
        if preferences.tactileEnabled {
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(event.isWarning ? .warning : .success)
        } else if preferences.vibrationEnabled, UIDevice.current.userInterfaceIdiom == .phone {
            #if canImport(AudioToolbox)
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
            #endif
        }
        #if canImport(AudioToolbox)
        if preferences.soundEnabled {
            if toneID == 0 { prepareTone() }
            if toneID != 0 { AudioServicesPlaySystemSound(toneID) }
        }
        #endif
        #endif
    }
    #if canImport(AudioToolbox) && canImport(UIKit)
    private func prepareTone() {
        // Use a documented file-backed SystemSoundID, not an undocumented numeric system-sound ID.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CamLinkFeedback-v1", isDirectory: true)
            .appendingPathComponent("tone.wav")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.toneWAV().write(to: url, options: .atomic)
            var sound: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError { toneID = sound }
        } catch { /* Feedback is best effort; never reclassify a photo or transfer as failed. */ }
    }
    #endif
    /// Small generated 80 ms PCM cue; no external asset, credentials, audio session takeover or hidden ID.
    nonisolated static func toneWAV() -> Data {
        let sampleRate = 22_050, count = 1_764
        var pcm = Data()
        func append16(_ value: UInt16, to data: inout Data) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        func append32(_ value: UInt32, to data: inout Data) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        for index in 0..<count {
            let envelope = min(1, Double(index) / 150) * min(1, Double(count - index) / 300)
            let sample = Int16(sin(2 * Double.pi * 880 * Double(index) / Double(sampleRate)) * 4_000 * envelope)
            append16(UInt16(bitPattern: sample), to: &pcm)
        }
        var data = Data("RIFF".utf8); append32(UInt32(36 + pcm.count), to: &data)
        data.append(Data("WAVEfmt ".utf8)); append32(16, to: &data)
        append16(1, to: &data); append16(1, to: &data)
        append32(UInt32(sampleRate), to: &data); append32(UInt32(sampleRate * 2), to: &data)
        append16(2, to: &data); append16(16, to: &data)
        data.append(Data("data".utf8)); append32(UInt32(pcm.count), to: &data); data.append(pcm)
        return data
    }
    /// Optional owner teardown; does not delete photos, events or delivered notifications.
    func stopMonitoring() {
        #if canImport(Network) && canImport(UIKit)
        pathMonitor?.cancel(); pathMonitor = nil
        #endif
        #if canImport(AudioToolbox) && canImport(UIKit)
        if toneID != 0 { AudioServicesDisposeSystemSoundID(toneID); toneID = 0 }
        #endif
    }
}
