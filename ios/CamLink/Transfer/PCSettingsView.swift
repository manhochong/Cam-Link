#if canImport(UIKit)
import SwiftUI
import UIKit

/// Explicit dependencies keep this sheet usable without changing the existing RootView pairSheet.
@MainActor
struct PCSettingsView: View {
    @ObservedObject private var pair: PairStore
    @ObservedObject private var delivery: MultiPCDeliveryStore
    private let photos: [ReceivedJPEG]
    private let sessionID: String
    private let albumName: String
    private let remoteNames: [String: String]
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false
    @State private var scannerSlot: PCSlotID = .primary
    @State private var qrText = ""
    @State private var confirmFingerprint = false
    @State private var confirmForget = false
    @State private var confirmHistorical = false
    @State private var localMessage = ""

    init(pair: PairStore, delivery: MultiPCDeliveryStore, photos: [ReceivedJPEG] = [],
         sessionID: String = "", albumName: String = "", remoteNames: [String: String] = [:]) {
        self.pair = pair
        self.delivery = delivery
        self.photos = photos
        self.sessionID = sessionID
        self.albumName = albumName
        self.remoteNames = remoteNames
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("兩部電腦分開設定") {
                    Picker("目前設定", selection: Binding(get: { pair.selectedSlot }, set: { pair.selectSlot($0) })) {
                        ForEach(PCSlotID.allCases) { slot in
                            Text(pair.slot(slot)?.label ?? slot.defaultLabel).tag(slot)
                        }
                    }.disabled(pair.busy)
                    TextField("電腦名稱", text: Binding(get: { pair.selectedLabel },
                        set: { pair.setLabel($0, for: pair.selectedSlot) }))
                    if pair.selectedPair.isReady {
                        Text("\(pair.selectedPair.host) · 指紋 \(pair.selectedPair.shortFinger)")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    } else { Text("尚未完成此槽配對").foregroundStyle(.secondary) }
                    Toggle("此電腦自動傳送之後新收到的原圖", isOn: Binding(
                        get: { pair.slot(pair.selectedSlot)?.autoSendNewPhotos ?? false },
                        set: { pair.setAutoSendNewPhotos($0, for: pair.selectedSlot) }))
                        .disabled(!pair.selectedPair.isReady)
                    Text("第一、第二部各有獨立紀錄；選擇設定槽不會切換舊工作的目的地。啟用自動傳送不會把較早的原圖補傳到新電腦。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("配對目前選定的電腦") {
                    Button("掃描 Receiver 配對 QR") {
                        scannerSlot = pair.selectedSlot
                        showScanner = true
                    }.disabled(pair.busy)
                    TextField("電腦 IPv4", text: $pair.draftHost)
                        .keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("12 位配對碼", text: $pair.draftCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    TextField("貼上 camlink://pair?…", text: $qrText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                        .onChange(of: qrText) { value in
                            if pair.applyQR(value, to: pair.selectedSlot) { qrText = "" }
                        }
                    Button("探測並顯示指紋") {
                        Task {
                            await pair.probeAndConfirm()
                            confirmFingerprint = pair.hasPendingFingerprint
                        }
                    }.disabled(pair.busy || pair.draftHost.isEmpty || pair.draftCode.isEmpty)
                    Button("只清除此槽配對", role: .destructive) { confirmForget = true }
                        .disabled(pair.busy)
                    Text("請在電腦 Receiver 按開始接收。QR 只填入地址及配對碼；必須再自行核對電腦顯示的指紋，才會儲存信任。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if pair.busy { ProgressView("正在核對電腦…") }
                    if !pair.message.isEmpty { Text(pair.message).font(.footnote) }
                }
                Section("原圖交付") {
                    Toggle("暫停全部 PC 傳送", isOn: Binding(get: { delivery.isPaused }, set: { paused in
                        delivery.setPaused(paused)
                        if !paused { Task { await delivery.pump() } }
                    }))
                    if !sessionID.isEmpty {
                        Text(albumName.isEmpty ? sessionID : albumName).font(.headline)
                        Button("只補傳此場次 \(photos.count) 張到 \(pair.selectedLabel)") { confirmHistorical = true }
                            .disabled(photos.isEmpty || !pair.selectedPair.isReady)
                    }
                    Button("重試此電腦未完成工作") {
                        delivery.retryFailed(slot: pair.selectedSlot, sessionID: sessionID.isEmpty ? nil : sessionID)
                        Task { await delivery.pump() }
                    }.disabled(!pair.selectedPair.isReady || delivery.isPaused)
                    if delivery.running { ProgressView("等待 Receiver SHA-256 核對") }
                    if !delivery.message.isEmpty { Text(delivery.message).font(.footnote).foregroundStyle(.red) }
                    if !localMessage.isEmpty { Text(localMessage).font(.footnote) }
                    Text("只有 HTTP 201 及 Receiver 回覆相同 SHA-256 才標示已核對。已移除／更換的電腦工作只保留舊身份，不會自動改送另一部。保持 App 前景及同一 Wi-Fi；此功能不保證背景 USB 接收。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("此電腦交付紀錄（最近 60 項）") {
                    let entries = delivery.jobs.filter { $0.destination.slot == pair.selectedSlot
                        && (sessionID.isEmpty || $0.sessionID == sessionID) }.suffix(60).reversed()
                    if entries.isEmpty { Text("尚無此目的地工作").foregroundStyle(.secondary) }
                    ForEach(Array(entries)) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.remoteName).font(.subheadline).lineLimit(2)
                            Text("\(job.destinationLabel) · \(job.state.title)").font(.caption)
                            if !delivery.destinationIsCurrent(job) {
                                Text("原目的地已更換／解除：紀錄保留，不會轉送目前電腦")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if let issue = job.issue { Text(issue.title).font(.caption).foregroundStyle(.secondary) }
                            if job.receipt?.evidence == .legacyPrimaryImported {
                                Text("由原主電腦舊已傳標記遷移；非本次重新連線核對")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("雙電腦配對與交付")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } } }
            .sheet(isPresented: $showScanner) {
                PairQRScanner { raw in
                    guard pair.applyQR(raw, to: scannerSlot) else { return false }
                    showScanner = false
                    return true
                }
            }
            .alert("核對電腦憑證 SHA-256", isPresented: $confirmFingerprint) {
                Button("與電腦相同，完成配對") { Task { await pair.confirmFingerprint() } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(pair.selectedLabel)\n\(pair.pendingFingerprint?.uppercased() ?? "請重新探測")\n請與電腦畫面核對。QR 本身不代表信任。")
            }
            .alert("只忘記此電腦配對？", isPresented: $confirmForget) {
                Button("取消", role: .cancel) {}
                Button("清除本機配對", role: .destructive) { pair.clear() }
            } message: { Text("不會刪除相片、電腦檔案或交付收據。此槽舊工作不會改送新配對電腦。") }
            .confirmationDialog("將此場次的 \(photos.count) 張原圖加入 \(pair.selectedLabel)？", isPresented: $confirmHistorical,
                                titleVisibility: .visible) {
                Button("加入此電腦佇列") {
                    do {
                        try delivery.enqueue(photos: photos, sessionID: sessionID, albumName: albumName,
                            to: [pair.selectedSlot], remoteNames: remoteNames)
                        localMessage = "已加入指定電腦佇列；尚未代表完成核對"
                        Task { await delivery.pump() }
                    } catch {
                        localMessage = (error as? PCQueueError)?.localizedDescription ?? "未能加入 PC 佇列"
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .onDisappear { qrText = "" }
        }
    }
}

/// Continuation integration spelling; both names resolve to the same explicit initializer.
typealias MultiPCSettingsView = PCSettingsView
#endif
