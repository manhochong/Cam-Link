#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// Parent-owned capture/queue actions only. This view never starts USB, uploads, or deletes originals.
/// Kept in PreferencesView.swift, the assigned file; DeliveryPreferencesView is the integration type.
@MainActor
struct DeliveryPreferencesView: View {
    @ObservedObject private var feedback: DeliveryFeedback
    private let captureActive: Bool
    private let statusText: String
    private let notes: Binding<String>?
    private let onScanIntervalChanged: ((ReceiveScanInterval) -> Void)?
    private let onRescan: (() -> Void)?
    private let onForceStop: (() -> Void)?
    private let onExportCameraDiagnostics: (() -> Void)?
    private let onStorageCheck: (() -> Void)?
    @State private var confirmForceStop = false
    @State private var enablingNotifications = false
    @State private var showEvents = false

    init(feedback: DeliveryFeedback, captureActive: Bool = false, statusText: String = "",
         notes: Binding<String>? = nil,
         onScanIntervalChanged: ((ReceiveScanInterval) -> Void)? = nil,
         onRescan: (() -> Void)? = nil,
         onForceStop: (() -> Void)? = nil,
         onExportCameraDiagnostics: (() -> Void)? = nil,
         onStorageCheck: (() -> Void)? = nil) {
        self.feedback = feedback
        self.captureActive = captureActive
        self.statusText = statusText
        self.notes = notes
        self.onScanIntervalChanged = onScanIntervalChanged
        self.onRescan = onRescan
        self.onForceStop = onForceStop
        self.onExportCameraDiagnostics = onExportCameraDiagnostics
        self.onStorageCheck = onStorageCheck
    }

    var body: some View {
        Form {
            if !statusText.isEmpty {
                Section("目前接收狀態") {
                    // Display-only parent status. Never copied into this module's durable event log.
                    Text(statusText).font(.footnote).textSelection(.enabled)
                }
            }
            feedbackSection
            networkSection
            receiveSection
            storageSection
            diagnosticsSection
            safetySection
        }
        .navigationTitle("接收設定與診斷")
        .task { await feedback.refreshNotificationAuthorization() } // Read only; no permission prompt.
        .alert("強制中止接收？", isPresented: $confirmForceStop) {
            Button("繼續接收", role: .cancel) {}
            Button("強制中止", role: .destructive) { onForceStop?() }
        } message: {
            Text("正在下載的照片可能只收到部分內容，不能視為成功。已收原圖會保留；請比對記憶卡確認缺圖。")
        }
    }

    private var feedbackSection: some View {
        Section {
            Toggle("提示聲音", isOn: preference(\.soundEnabled))
            Toggle("震動提示", isOn: preference(\.vibrationEnabled))
            Toggle("觸感提示", isOn: preference(\.tactileEnabled))
            Text("提示限真實接收或目的地核對事件；排隊、HTTP 接受、登入或分享不是交付成功。觸感開啟時優先使用觸感，不重複震動。iPad 通常沒有震動／觸感硬件；聲音仍受裝置設定限制。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("本機通知（自行啟用）", isOn: Binding(
                get: { feedback.preferences.localNotificationsEnabled },
                set: { enabled in
                    if enabled {
                        guard !enablingNotifications else { return }
                        enablingNotifications = true
                        Task { @MainActor in
                            _ = await feedback.enableLocalNotificationsFromUserAction()
                            enablingNotifications = false
                        }
                    } else { feedback.disableLocalNotifications() }
                }))
                .disabled(enablingNotifications)
            if enablingNotifications { ProgressView("等候系統通知授權") }
            Text(feedback.notificationStatus.isEmpty ? feedback.notificationAuthorization.text : feedback.notificationStatus)
                .font(.caption).foregroundStyle(.secondary)
            Button("開啟 App 系統設定") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            Text("前景使用 App 內提示；離開前景時只有 App 確實產生的事件才可排入本機通知。通知授權不會讓相機在鎖屏或背景繼續接收。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("接收與傳送回饋") }
    }

    private var networkSection: some View {
        Section {
            Text(networkSummary).font(.footnote)
            ForEach(FeedbackProvider.uploadDestinations, id: \.self) { provider in
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("\(provider.title) 只用 Wi-Fi", isOn: Binding(
                        get: { feedback.preferences.wifiOnly(for: provider) },
                        set: { feedback.setWiFiOnly($0, for: provider) }))
                    Text(feedback.aboutRestrictedNetwork(for: provider))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("允許系統標示的高成本網路", isOn: preference(\.allowExpensiveNetworks))
            Toggle("允許低數據模式傳送", isOn: preference(\.allowConstrainedNetworks))
            Text("關閉某目的地的「只用 Wi-Fi」才可允許該目的地使用流動數據；仍須符合高成本與低數據設定，可能產生數據費用。系統路徑監測不是個別傳送的實際介面證明，也不保證可上網或電腦可達。")
                .font(.caption).foregroundStyle(.secondary)
            Text("父層傳送器必須接上網路 gate 與 URLSession／每次 request 政策才會生效；政策變更需由傳送器暫停既有工作。不能宣稱可把相機 Wi-Fi 與流動數據各自強制綁定。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("目的地網路政策") }
    }

    private var receiveSection: some View {
        Section {
            Picker("補掃頻率", selection: Binding(
                get: { feedback.preferences.scanInterval },
                set: { value in
                    feedback.updatePreferences { $0.scanInterval = value }
                    onScanIntervalChanged?(value)
                })) {
                    ForEach(ReceiveScanInterval.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .disabled(captureActive || onScanIntervalChanged == nil)
            Text(onScanIntervalChanged == nil
                 ? "目前接收器尚未接入可調補掃；本設定不會改動已驗證的 USB／PTP 核心。"
                 : "只在停止接收時更改；卡內接收的最短建議間隔為 2 秒。事件是否即時接收由現有相機接收器決定。")
                .font(.caption).foregroundStyle(.secondary)
            if let notes = notes {
                TextField("現場記錄（勿填密碼或權杖）", text: Binding(
                    get: { notes.wrappedValue },
                    set: { value in
                        notes.wrappedValue = String(value.unicodeScalars.filter {
                            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
                        }.prefix(512).map(String.init).joined())
                    }), axis: .vertical)
                    .lineLimit(2...4).disabled(captureActive)
                Text("只回傳父層的記錄 binding；本模組不保存或匯出此自由文字。父層如需保存，必須另外處理隱私與場次綁定。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("重新搜尋照片及重試") { onRescan?() }
                .disabled(onRescan == nil || !captureActive)
            Button("強制中止接收", role: .destructive) { confirmForceStop = true }
                .disabled(onForceStop == nil || !captureActive)
        } header: { Text("接收設定") }
    }

    private var storageSection: some View {
        Section {
            Text(feedback.storageStatus.text).font(.footnote)
            Button("檢查本機可用空間") { onStorageCheck?() }
                .disabled(onStorageCheck == nil)
            Text("開始相機接收前由父層重新檢查；空間偏低或無法讀取時需先顯示確認。容量只是當下估計，不保證整場足夠，App 不會自動清理任何照片。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("本機空間與原圖保護") }
    }

    private var diagnosticsSection: some View {
        Section {
            if let banner = feedback.banner {
                Label(banner.title, systemImage: banner.isWarning ? "exclamationmark.triangle" : "info.circle")
                Text(banner.detail).font(.footnote)
                Button("關閉目前提示") { feedback.dismissBanner() }
            }
            Text("已保留 \(feedback.events.count) 筆非秘密事件（最多 256 筆）。同一目的地的連續相同錯誤會合併次數；錯誤提示限速，但事件不會因限速被省略。")
                .font(.caption).foregroundStyle(.secondary)
            if !feedback.diagnosticStatus.isEmpty {
                Text(feedback.diagnosticStatus).font(.caption).foregroundStyle(.secondary)
            }
            ShareLink("分享非秘密事件紀錄", item: feedback.diagnosticText())
                .disabled(feedback.events.isEmpty)
            DisclosureGroup("查看目的地事件", isExpanded: $showEvents) {
                ForEach(Array(feedback.events.reversed())) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.title).font(.subheadline.weight(.semibold))
                        Text(event.detail).font(.caption)
                        Text("\(event.lastAt.formatted(date: .abbreviated, time: .standard)) · \(event.occurrences) 次")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
            Button("匯出相機診斷報告") { onExportCameraDiagnostics?() }
                .disabled(onExportCameraDiagnostics == nil || captureActive)
            Text("事件紀錄不含帳號、檔名、路徑、URL、密碼、權杖或可用容量。相機診斷是父層獨立功能，匯出前應由父層確認報告沒有秘密；本模組不讀取相機原始 log。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("診斷與支援") }
    }

    private var safetySection: some View {
        Section {
            Text("請保持 App 前景與螢幕開啟。口袋模式只是黑色前景畫面；鎖屏、切 App 或進入背景後，iOS 不保證 USB 接收。已存原圖的網路傳送不等於背景 USB。")
            Text("本機已收、某目的地已接受、某目的地已核對是不同階段。OneDrive 只有大小核對時會明示不是雜湊核對；系統分享不能核對其他 App 的雲端結果。")
            Text("不自動刪除未核對或已核對照片，不刪相機記憶卡，不拍攝、不改相機屬性，也不加入廠商專屬寫入指令。漏圖需另與記憶卡原圖比對。")
        } header: { Text("前景接收與安全限制") }
          .font(.footnote)
    }

    private func preference(_ key: WritableKeyPath<DeliveryPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { feedback.preferences[keyPath: key] },
                set: { value in feedback.updatePreferences { $0[keyPath: key] = value } })
    }

    private var networkSummary: String {
        let path = feedback.networkPath
        guard path.known else { return "系統路徑：尚未收到監測結果。" }
        guard path.satisfied else { return "系統路徑：目前不可用。" }
        let interfaces = [(path.usesWiFi, "Wi-Fi"), (path.usesCellular, "流動數據"),
                          (path.usesEthernet, "有線網路")].filter { $0.0 }.map { $0.1 }
        return "系統目前可用路徑：\(interfaces.isEmpty ? "其他／未確認介面" : interfaces.joined(separator: "／"))\(path.expensive ? " · 高成本" : "")\(path.constrained ? " · 低數據模式" : "")。不是目的地成功或實際封包介面的證明。"
    }
}

// Both names refer to the same view; no duplicate UI implementation.
typealias PreferencesView = DeliveryPreferencesView
#endif
