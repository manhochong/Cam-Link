import ImageIO
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var camera: CameraCaptureService
    @EnvironmentObject private var session: ShootSession
    @EnvironmentObject private var pair: PairStore
    @EnvironmentObject private var webDAV: WebDAVStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showPair = false
    @State private var showWebDAV = false
    @State private var showScanner = false
    @State private var confirmFinger = false
    @State private var qrText = ""
    @State private var selectedPhoto: ReceivedJPEG?
    @State private var showAbort = false
    @State private var pocket = false
    @State private var diagnosticURL: URL?
    @State private var previewAspectRatio: CGFloat = 4.0 / 3.0
    private let paper = Color(red: 254 / 255, green: 253 / 255, blue: 251 / 255)
    private let ink = Color(red: 25 / 255, green: 25 / 255, blue: 27 / 255)
    private let soft = Color(red: 243 / 255, green: 242 / 255, blue: 238 / 255)

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > 900 && geometry.size.width > geometry.size.height
            Group {
                if landscape {
                    HStack(spacing: 0) {
                        page(wide: true)
                        dock(vertical: true).frame(width: 76)
                    }
                } else {
                    VStack(spacing: 0) {
                        page(wide: false)
                        dock(vertical: false).frame(height: 62)
                    }
                }
            }
            .background(paper)
            .foregroundStyle(ink)
            .tint(ink)
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showPair) { pairSheet }
        .sheet(isPresented: $showWebDAV) {
            WebDAVSettingsView(photos: session.photos).environmentObject(webDAV)
        }
        .sheet(item: $selectedPhoto) { PhotoViewer(photo: $0) }
        .onOpenURL { url in
            if pair.applyQR(url.absoluteString) {
                tab = 2
                showPair = true
            } else {
                pair.message = "這不是有效的 Cam Link 電腦配對 QR。"
                tab = 2
            }
        }
        .fullScreenCover(isPresented: $pocket) {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 15) {
                    Text("口袋模式 · 輕觸返回").foregroundStyle(.gray)
                    Text("請保持 App 前景及螢幕開啟；iPadOS 不保證背景 USB 接收。")
                        .font(.footnote).foregroundStyle(.gray).multilineTextAlignment(.center)
                }.padding(32)
            }.contentShape(Rectangle()).onTapGesture { pocket = false }
        }
        .alert("強制中止接收？", isPresented: $showAbort) {
            Button("繼續接收", role: .cancel) {}
            Button("強制中止", role: .destructive) { camera.stopBrowsing() }
        } message: { Text("未完成的下載不會視為成功。已收下的 JPG 仍會保留。") }
        .onChange(of: session.photos.count) { _ in scheduleUpload() }
        .onChange(of: session.autoUpload) { _ in scheduleUpload() }
        .onChange(of: pair.pair) { _ in scheduleUpload() }
        .onChange(of: webDAV.autoUpload) { _ in scheduleUpload() }
        .onChange(of: webDAV.config?.id) { _ in scheduleUpload() }
        .task(id: session.photos.first?.id) {
            previewAspectRatio = 4.0 / 3.0
            guard let url = session.photos.first?.url else { return }
            let ratio = await Task.detached(priority: .utility) {
                Self.photoAspectRatio(at: url)
            }.value
            guard !Task.isCancelled else { return }
            previewAspectRatio = ratio
        }
        .onAppear { scheduleUpload(); updateIdleTimer() }
        .onChange(of: camera.browsing) { _ in updateIdleTimer() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { updateIdleTimer(); scheduleUpload() }
            else { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    @ViewBuilder private func page(wide: Bool) -> some View {
        if tab == 0 {
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    ScrollView { photoPanel }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { homeControls.padding(20) }.frame(width: 380)
                }.padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        destinationHeader
                        photoPanel
                        cameraControls
                        pocketButton
                    }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tab == 1 ? "接收紀錄" : tab == 2 ? "傳送目的地" : "接收設定與診斷")
                        .font(.largeTitle.bold())
                    if tab == 1 { history }
                    if tab == 2 { transfers }
                    if tab == 3 { advanced }
                }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
    }

    private var homeControls: some View {
        VStack(alignment: .leading, spacing: 22) {
            destinationHeader
            cameraControls
            pocketButton
        }
    }

    private var destinationHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text(camera.browsing ? "本場上傳目的地" : "下次開拍的目的地")
                    .font(.caption).foregroundStyle(.secondary)
                Text(pair.pair.isReady ? "電腦" : "只存 iPad／iPhone").font(.title2.bold())
                Text(pair.pair.isReady ? "\(pair.pair.host) · 同一 Wi-Fi 自動傳送" : "JPG 先保存在 App 內，RAW 不傳")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button("更改") { tab = 2 }.buttonStyle(.bordered)
        }
    }

    private var photoPanel: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                PhotoPreview(photo: session.photos.first)
                    .aspectRatio(previewAspectRatio, contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedPhoto = session.photos.first }
                VStack(alignment: .trailing, spacing: 4) {
                    Text("本場拍攝").font(.caption.bold())
                    if let photo = session.photos.first { Text(photo.name).font(.caption).lineLimit(1) }
                    Text(session.photos.isEmpty ? "等待完整 JPG" : "輕觸查看大圖").font(.caption2)
                }
                .padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12)).padding(12)
            }
            VStack(spacing: 12) {
                HStack {
                    metric("已收", session.photos.count)
                    metric("待傳", session.pendingCount)
                    metric("電腦已核對", session.verifiedCount)
                }
                ProgressView(value: session.photos.isEmpty ? 0 : Double(session.verifiedCount) / Double(session.photos.count))
                    .tint(Color(red: 0.9, green: 0.67, blue: 0.43))
                Button {
                    tab = 1
                } label: {
                    HStack {
                        Text(session.photos.isEmpty ? "等待本場第一張 JPG" : "查看本場傳送詳情")
                        Spacer(); Image(systemName: "chevron.right")
                    }.font(.footnote)
                }.buttonStyle(.plain)
            }.padding(18)
        }
        .foregroundStyle(.white)
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private nonisolated static func photoAspectRatio(at url: URL) -> CGFloat {
        // Read metadata, not full image pixels; account for EXIF rotation like PhotoPreview.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return 4.0 / 3.0 }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return CGFloat(swapsAxes ? height / width : width / height)
    }

    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.white.opacity(0.65))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("相機").font(.headline)
                Spacer()
                if !camera.browsing {
                    Button("＋ 連接") { camera.startBrowsing() }.buttonStyle(.bordered)
                }
            }
            Divider()
            Text(camera.status).font(.title3.weight(.semibold))
            if !camera.cameraName.isEmpty { Text(camera.cameraName).font(.subheadline) }
            Text(camera.catalogReady ? "JPG 會先存入 App；已配對時傳到電腦。RAW 不傳。" : "用 USB 資料線連接相機，選可讀取卡內 JPG 的模式；LUMIX 可先測 PC(Tether)。")
                .font(.footnote).foregroundStyle(.secondary)
            if !camera.lastError.isEmpty {
                Text(camera.lastError).font(.footnote).foregroundStyle(Color(red: 0.57, green: 0.26, blue: 0))
            }
            if !camera.browsing {
                Button("開始接收新拍 JPG") {
                    camera.mode = .newPhotos
                    camera.startBrowsing()
                }.buttonStyle(RootPrimaryButtonStyle()).controlSize(.large)
                Button("接收卡內 JPG") {
                    camera.mode = .card
                    camera.startBrowsing()
                }.buttonStyle(.bordered).controlSize(.large)
                Text("新拍模式會略過連線時已有的照片；要收記憶卡原有照片請選下方按鈕。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    if !camera.catalogReady { ProgressView().controlSize(.small) }
                    Text("\(camera.catalogCount) 個物件 · \(camera.queuedCount) 待接收 · \(camera.failedCount) 需重試")
                        .font(.caption).monospacedDigit()
                }
                Button(camera.finishing ? "正在完成接收…" : "停拍並完成接收") { camera.finishReceiving() }
                    .buttonStyle(RootPrimaryButtonStyle()).controlSize(.large).disabled(camera.finishing)
                Button("重新搜尋照片及重試") { camera.refreshContents() }
                    .buttonStyle(.bordered).disabled(!camera.connected || camera.finishing)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pocketButton: some View {
        Button { pocket = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "moon").font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("口袋模式").font(.subheadline.bold())
                    Text("黑色前景畫面，保持接收運作").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "chevron.right")
            }.padding(16).background(soft, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本機已收 \(session.photos.count) 張 · 電腦已核對 \(session.verifiedCount) 張")
                .font(.subheadline).foregroundStyle(.secondary)
            if session.photos.isEmpty { Text("尚未收到 JPG。請先在首頁連接相機。").padding(.vertical, 24) }
            ForEach(session.photos) { photo in
                HStack(spacing: 12) {
                    Button { selectedPhoto = photo } label: {
                        PhotoPreview(photo: photo).frame(width: 90, height: 66).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(photo.name).lineLimit(1).font(.subheadline.weight(.medium))
                        Text(ByteCountFormatter.string(fromByteCount: photo.bytes, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(photo.uploaded ? "電腦已核對" : "已存本機 · 待傳電腦")
                            .font(.caption).foregroundStyle(photo.uploaded ? .green : .secondary)
                    }
                    Spacer()
                    ShareLink(item: photo.url) { Image(systemName: "square.and.arrow.up") }
                }.padding(.vertical, 8)
                Divider()
            }
        }
    }

    private var transfers: some View {
        VStack(alignment: .leading, spacing: 18) {
            destinationHeader
            Divider()
            if pair.pair.isReady {
                Text("指紋 \(pair.pair.shortFinger)").font(.footnote.monospaced())
            }
            Toggle("收下後自動傳到電腦", isOn: $session.autoUpload)
            Button("配對／更改電腦") { showPair = true }.buttonStyle(RootPrimaryButtonStyle())
            Button("上傳待傳 JPG（\(session.pendingCount) 張）") {
                Task { await session.uploadPending(using: pair.pair) }
            }.buttonStyle(.bordered).disabled(!pair.pair.isReady || session.uploading)
            if session.uploading { ProgressView("正在傳送並等待 Receiver 核對") }
            if !session.uploadMessage.isEmpty { Text(session.uploadMessage).font(.footnote) }
            Text("請讓 iPad 與電腦接收器在同一網路。只有 Receiver 回覆相同 SHA-256 才會標為已核對。")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            cloudDestinations
        }
    }

    private var cloudDestinations: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("雲端與其他目的地").font(.headline)
            Button { showWebDAV = true } label: {
                HStack {
                    Image(systemName: "externaldrive.connected.to.line.below")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WebDAV（NAS／雲端資料夾）").font(.subheadline.bold())
                        Text(webDAV.config == nil ? "設定 HTTPS 資料夾與應用程式密碼" : "設定與查看 WebDAV 獨立傳送紀錄")
                            .font(.caption)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
            }.buttonStyle(.bordered)
            Text("WebDAV 上傳後會下載核對原圖；預設不自動上傳，需自行啟用。")
                .font(.caption).foregroundStyle(.secondary)
            pendingCloud("Google Drive", note: "iOS 登入設定待完成，尚不可直接上傳")
            pendingCloud("OneDrive", note: "Microsoft 登入回呼待確認，尚不可直接上傳")
            ShareLink(items: session.photos.map(\.url)) {
                Label("分享本場所有 JPG", systemImage: "square.and.arrow.up")
            }.buttonStyle(.bordered).disabled(session.photos.isEmpty)
            Text("可交給 Dropbox、Box、Google Photos、Flickr 等 App 的系統分享擴充功能。可選項目依安裝的 App 而定；分享不代表自動備份或已核對。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pendingCloud(_ title: String, note: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cloud").font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.bold())
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "lock").foregroundStyle(.secondary)
        }.padding(14).background(soft, in: RoundedRectangle(cornerRadius: 12))
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(camera.authorization).font(.subheadline)
            Text("目錄 \(camera.catalogCount) · 待接收 \(camera.queuedCount) · 接收失敗 \(camera.failedCount)")
                .font(.footnote)
            Button("開啟 App 設定") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.buttonStyle(.bordered)
            Button("重新搜尋照片及重試") { camera.refreshContents() }
                .buttonStyle(.bordered).disabled(!camera.connected || camera.finishing)
            Button("強制中止接收", role: .destructive) { showAbort = true }
                .buttonStyle(.bordered).disabled(!camera.browsing)
            Button("產生 USB 相機診斷報告") { diagnosticURL = camera.diagnosticFile() }
                .buttonStyle(RootPrimaryButtonStyle())
            if let diagnosticURL { ShareLink("分享診斷報告", item: diagnosticURL) }
            Text("報告記錄授權、相機目錄與接收錯誤，不包含電腦配對碼。請保持 App 前景；鎖屏／切換 App 可能中斷 USB 接收。")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            Text("Cam Link \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(camera.logLines.suffix(30).enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            }
        }
    }

    private func dock(vertical: Bool) -> some View {
        let titles = ["首頁", "紀錄", "傳送", "更多"]
        let icons = ["house", "clock.arrow.circlepath", "arrow.up.circle", "ellipsis"]
        return Group {
            if vertical {
                VStack { ForEach(0..<4) { index in navButton(index, title: titles[index], icon: icons[index]) } }
            } else {
                HStack { ForEach(0..<4) { index in navButton(index, title: titles[index], icon: icons[index]) } }
            }
        }.background(paper).overlay(alignment: vertical ? .leading : .top) { Rectangle().fill(soft).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1) }
    }

    private func navButton(_ index: Int, title: String, icon: String) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 21, weight: tab == index ? .semibold : .regular))
                Text(title).font(.caption.weight(tab == index ? .semibold : .regular))
            }.foregroundStyle(tab == index ? ink : .secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(tab == index ? .isSelected : [])
    }

    private func scheduleUpload() {
        guard scenePhase == .active else { return }
        if session.autoUpload, pair.pair.isReady {
            Task { await session.uploadPending(using: pair.pair) }
        }
        if webDAV.autoUpload, webDAV.config != nil {
            webDAV.enqueue(session.photos)
            Task { await webDAV.uploadPending() }
        }
    }
    private func updateIdleTimer() { UIApplication.shared.isIdleTimerDisabled = camera.browsing && scenePhase == .active }

    private var pairSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Button("掃描電腦 QR Code") { showScanner = true }
                    Text("Windows 接收器按「開始接收」→「顯示 QR 掃描」。掃描後仍要核對電腦指紋，不需 Mac。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("手打或貼上 QR 內容") {
                    TextField("電腦 IPv4", text: $pair.draftHost).keyboardType(.decimalPad).textInputAutocapitalization(.never)
                    SecureField("配對碼（12 位）", text: $pair.draftCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("貼上 camlink://pair?…", text: $qrText).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: qrText) { value in if pair.applyQR(value) { qrText = "" } }
                }
                Section {
                    Button("探測並顯示指紋") {
                        Task { await pair.probeAndConfirm(); confirmFinger = pair.hasPendingFingerprint }
                    }.disabled(pair.busy || pair.draftHost.isEmpty || pair.draftCode.isEmpty)
                    Button("清除配對", role: .destructive) { pair.clear() }
                }
                if !pair.message.isEmpty { Section { Text(pair.message) } }
            }
            .navigationTitle("配對電腦")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("關閉") { showPair = false } } }
            .sheet(isPresented: $showScanner) {
                PairQRScanner { raw in
                    guard pair.applyQR(raw) else { return false }
                    showScanner = false
                    return true
                }
            }
            .alert("核對電腦指紋", isPresented: $confirmFinger) {
                Button("相同，完成配對") {
                    Task { await pair.confirmFingerprint(); if pair.pair.isReady { showPair = false } }
                }
                Button("取消", role: .cancel) {}
            } message: { Text(pair.message) }
        }
    }
}

private struct RootPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let paper = Color(red: 254 / 255, green: 253 / 255, blue: 251 / 255)
        let ink = Color(red: 25 / 255, green: 25 / 255, blue: 27 / 255)
        let pressedInk = Color(red: 52 / 255, green: 52 / 255, blue: 56 / 255)
        let disabledInk = Color(red: 94 / 255, green: 94 / 255, blue: 97 / 255)
        let fill = isEnabled ? (configuration.isPressed ? pressedInk : ink) : disabledInk
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        // Set the label's contrast here so the root's ink foreground cannot hide it.
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(paper)
            .padding(.horizontal, 20)
            .padding(.vertical, controlSize == .large ? 14 : 10)
            .frame(minHeight: 44)
            .background(fill, in: shape)
            .contentShape(shape)
    }
}
