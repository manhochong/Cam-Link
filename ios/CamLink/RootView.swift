import SwiftUI

struct RootView: View {
    @EnvironmentObject private var camera: CameraCaptureService
    @EnvironmentObject private var session: ShootSession
    @EnvironmentObject private var pair: PairStore
    @State private var showPair = false
    @State private var confirmFinger = false
    @State private var qrText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("相機 · USB") {
                    LabeledContent("狀態", value: camera.status)
                    if !camera.cameraName.isEmpty {
                        LabeledContent("裝置", value: camera.cameraName)
                    }
                    if !camera.lastError.isEmpty {
                        Text(camera.lastError).foregroundStyle(.red).font(.footnote)
                    }
                    HStack {
                        Button(camera.browsing ? "停止尋找" : "尋找 USB 相機") {
                            if camera.browsing { camera.stopBrowsing() }
                            else { camera.startBrowsing() }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("重新整理") { camera.refreshContents() }
                            .disabled(!camera.connected)
                    }
                    Text("相機請設 PC(Tether)。不使用 Wi‑Fi 卡。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("電腦 · Receiver") {
                    if pair.pair.isReady {
                        LabeledContent("已配對", value: pair.pair.host)
                        LabeledContent("指紋", value: pair.pair.shortFinger)
                            .font(.system(.body, design: .monospaced))
                    } else {
                        Text("尚未配對").foregroundStyle(.secondary)
                    }
                    Toggle("收下後自動傳到電腦", isOn: $session.autoUpload)
                    Button("配對／更改電腦") { showPair = true }
                    Button("上傳待傳 JPG") {
                        Task { await session.uploadPending(using: pair.pair) }
                    }
                    .disabled(!pair.pair.isReady || session.uploading)
                    if !session.uploadMessage.isEmpty {
                        Text(session.uploadMessage).font(.footnote)
                    }
                    if !pair.message.isEmpty {
                        Text(pair.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("本場 \(session.photos.count) · 已傳 \(session.verifiedCount) · 待傳 \(session.pendingCount)") {
                    if session.photos.isEmpty {
                        Text("等待第一張 JPG").foregroundStyle(.secondary)
                    } else {
                        ForEach(session.photos) { photo in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(photo.name).lineLimit(1)
                                    Text(byteLabel(photo.bytes))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(photo.uploaded ? "已核對" : "待傳")
                                    .font(.caption)
                                    .foregroundStyle(photo.uploaded ? .green : .orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Cam Link")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Cam Link").font(.headline)
                        Text("0.2.25 · iOS USB").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .sheet(isPresented: $showPair) { pairSheet }
            .onAppear {
                guard session.autoUpload, pair.pair.isReady else { return }
                Task { await session.uploadPending(using: pair.pair) }
            }
            .onChange(of: session.photos.count) { _ in
                guard session.autoUpload, pair.pair.isReady else { return }
                Task { await session.uploadPending(using: pair.pair) }
            }
        }
    }

    private var pairSheet: some View {
        NavigationStack {
            Form {
                Section("手打或貼上 QR 內容") {
                    TextField("電腦 IPv4", text: $pair.draftHost)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                    TextField("配對碼（12 位）", text: $pair.draftCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("貼上 camlink://pair?…", text: $qrText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: qrText) { value in
                        if pair.applyQR(value) { qrText = "" }
                    }
                }
                Section {
                    Button("探測並顯示指紋") {
                        Task {
                            await pair.probeAndConfirm()
                            confirmFinger = pair.hasPendingFingerprint
                        }
                    }
                    .disabled(pair.busy || pair.draftHost.isEmpty || pair.draftCode.isEmpty)
                    Button("清除配對", role: .destructive) { pair.clear() }
                }
                if !pair.message.isEmpty {
                    Section { Text(pair.message) }
                }
            }
            .navigationTitle("配對電腦")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { showPair = false }
                }
            }
            .alert("核對電腦指紋", isPresented: $confirmFinger) {
                Button("相同，完成配對") {
                    Task {
                        await pair.confirmFingerprint()
                        if pair.pair.isReady { showPair = false }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text(pair.message)
            }
        }
    }

    private func byteLabel(_ n: Int64) -> String {
        if n >= 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        return "\(max(0, n / 1024)) KB"
    }
}
