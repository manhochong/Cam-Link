import ImageIO
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var runtime: CamLinkRuntime
    @EnvironmentObject private var camera: CameraCaptureService
    @EnvironmentObject private var session: ShootSession
    @EnvironmentObject private var pair: PairStore
    @EnvironmentObject private var pc: MultiPCDeliveryStore
    @EnvironmentObject private var webDAV: WebDAVStore
    @EnvironmentObject private var google: GoogleDriveStore
    @EnvironmentObject private var oneDrive: OneDriveStore
    @EnvironmentObject private var feedback: DeliveryFeedback
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var showPC = false
    @State private var showWebDAV = false
    @State private var showGoogle = false
    @State private var showOneDrive = false
    @State private var selectedPhoto: ReceivedJPEG?
    @State private var transferAlbumID: String?
    @State private var pocket = false
    @State private var diagnosticURL: URL?
    @State private var previewAspectRatio: CGFloat = 4.0 / 3.0
    @State private var storageAlert = false
    @State private var pendingMode: CameraCaptureService.ReceiveMode = .newPhotos
    @State private var showSessionRetry = false
    @State private var retryMessage = ""

    private var transferAlbum: SessionAlbumRecord? { session.album(id: transferAlbumID ?? session.sessionId) }
    private var transferPhotos: [ReceivedJPEG] { transferAlbum?.photos ?? [] }
    private var transferName: String { transferAlbum?.displayName ?? session.sessionDisplayName }
    private var pcJobs: [PCDeliveryJob] { pc.jobs.filter { $0.sessionID == session.sessionId } }
    private var verifiedPC: Int { pcJobs.filter { $0.state == .verified }.count }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > 900 && geometry.size.width > geometry.size.height
            Group {
                if landscape {
                    HStack(spacing: 0) { page(wide: true); dock(vertical: true).frame(width: 78) }
                } else {
                    VStack(spacing: 0) { page(wide: false); dock(vertical: false).frame(height: 62) }
                }
            }
            .background(CamLinkTheme.canvas).foregroundStyle(CamLinkTheme.ink).tint(CamLinkTheme.accent)
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showPC) {
            PCSettingsView(pair: pair, delivery: pc, photos: transferPhotos,
                sessionID: transferAlbum?.id ?? session.sessionId, albumName: transferName,
                remoteNames: Dictionary(uniqueKeysWithValues: transferPhotos.map { ($0.id, session.remoteName(for: $0)) }))
        }
        .sheet(isPresented: $showGoogle) {
            NavigationStack {
                GoogleDriveSettingsView(photos: transferPhotos, albumName: { transferName }).environmentObject(google)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showGoogle = false } } }
            }
        }
        .sheet(isPresented: $showOneDrive) {
            OneDriveSettingsView(photos: transferPhotos, albumName: transferName).environmentObject(oneDrive)
        }
        .sheet(isPresented: $showWebDAV) { WebDAVSettingsView(photos: transferPhotos).environmentObject(webDAV) }
        .sheet(item: $selectedPhoto) { PhotoViewer(photo: $0) }
        .fullScreenCover(isPresented: $pocket) {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 14) {
                    Text("口袋模式 · 輕觸返回").foregroundStyle(.gray)
                    Text("保持 App 前景及螢幕開啟；鎖屏或切換 App 可能中斷 USB 接收。")
                        .font(.footnote).foregroundStyle(.gray).multilineTextAlignment(.center)
                }.padding(32)
            }.contentShape(Rectangle()).onTapGesture { pocket = false }
        }
        .alert("開始前確認儲存空間", isPresented: $storageAlert) {
            Button("取消", role: .cancel) {}
            Button("已檢查，繼續接收") { runtime.startReceiving(pendingMode) }
        } message: { Text(feedback.storageStatus.text) }
        .confirmationDialog("只重試「\(transferName)」已失敗的工作", isPresented: $showSessionRetry, titleVisibility: .visible) {
            Button("電腦 1／電腦 2") {
                pc.retryFailed(sessionID: transferAlbum?.id ?? session.sessionId)
                Task { await pc.pump() }
                retryMessage = "只重試此活動原有的電腦工作；不變更配對目的地。"
            }
            Button("Google Drive") {
                google.retryFailed(photos: transferPhotos)
                Task { await google.pump() }
                retryMessage = "只重試此活動原有的 Google Drive 工作；手動暫停仍保留。"
            }
            Button("OneDrive") {
                oneDrive.retryFailed(photos: transferPhotos)
                Task { await oneDrive.pump() }
                retryMessage = "只重試此活動原有的 OneDrive 工作；手動暫停仍保留。"
            }
            Button("WebDAV／NAS") {
                webDAV.retryFailed(photos: transferPhotos)
                Task { await webDAV.uploadPending() }
                retryMessage = "只重試此活動與目前 WebDAV 目的地相符的失敗工作。"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只處理選定活動既有的原目的地工作；已核對原圖不重傳，其他活動不受影響。需要登入或手動繼續時，請開啟該目的地設定。")
        }
        .onOpenURL { url in
            if google.handleCallback(url) { return }
            guard url.scheme?.lowercased() == "camlink" else { return }
            if pair.applyQR(url.absoluteString) { transferAlbumID = nil; tab = 2; showPC = true }
        }
        .task(id: session.photos.first?.id) {
            previewAspectRatio = 4.0 / 3.0
            guard let url = session.photos.first?.url else { return }
            let ratio = await Task.detached(priority: .utility) { Self.photoAspectRatio(at: url) }.value
            if !Task.isCancelled { previewAspectRatio = ratio }
        }
        .onAppear { runtime.setForeground(scenePhase == .active); updateIdleTimer() }
        .onChange(of: camera.browsing) { _ in updateIdleTimer() }
        .onChange(of: scenePhase) { phase in runtime.setForeground(phase == .active); updateIdleTimer() }
    }

    @ViewBuilder private func page(wide: Bool) -> some View {
        switch tab {
        case 1:
            SessionHistoryView(session: session, isCameraReceiving: { camera.browsing || camera.sessionClosing || !camera.canStart },
                onDelivery: openDelivery, onRetryDelivery: { album in
                    transferAlbumID = album.id; tab = 2; showSessionRetry = true
                })
        case 2:
            ScrollView { transfers.padding(24).frame(maxWidth: 760).frame(maxWidth: .infinity) }
        case 3:
            NavigationStack {
                DeliveryPreferencesView(feedback: feedback, captureActive: camera.browsing,
                    statusText: camera.authorization + "\n" + camera.status,
                    notes: Binding(get: { session.album(id: session.sessionId)?.operatorNotes ?? "" },
                                   set: { try? session.setOperatorNotes($0, albumID: session.sessionId) }),
                    onRescan: { camera.refreshContents() }, onForceStop: { runtime.interruptReceiving() },
                    onExportCameraDiagnostics: { diagnosticURL = camera.diagnosticFile() },
                    onStorageCheck: checkStorage)
                .safeAreaInset(edge: .bottom) {
                    if let diagnosticURL {
                        ShareLink("分享 USB 相機診斷報告", item: diagnosticURL).padding(12)
                            .frame(maxWidth: .infinity).background(.regularMaterial)
                    }
                }
            }
        default:
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    ScrollView { photoPanel }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    ScrollView { homeControls }.frame(width: 380)
                }.padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) { destinationHeader; photoPanel; homeControls }
                        .padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func openDelivery(_ album: SessionAlbumRecord) { transferAlbumID = album.id; tab = 2 }
    private var destinationHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("Cam Link").font(.caption.weight(.semibold)).foregroundStyle(CamLinkTheme.accent)
                Text(session.sessionDisplayName).font(.title2.bold())
                Text("原圖先存本機；各目的地獨立排隊、獨立核對")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("目的地") { transferAlbumID = nil; tab = 2 }.buttonStyle(.bordered)
        }
    }
    private var homeControls: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let banner = feedback.banner {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) { Text(banner.title).bold(); Text(banner.detail).font(.caption) }
                    Spacer()
                    Button { feedback.dismissBanner() } label: { Image(systemName: "xmark.circle.fill") }
                }.camLinkCard()
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("活動名稱").font(.headline)
                TextField("例如：2026 活動拍攝", text: $session.userEventName)
                    .textFieldStyle(.roundedBorder).disabled(camera.browsing)
                Text("接收中固定本場與已排隊目的地；新活動請到「紀錄」建立，舊原圖不會刪除。")
                    .font(.caption).foregroundStyle(.secondary)
            }.camLinkCard()
            cameraControls
            Button { pocket = true } label: {
                Label("口袋模式 · 保持前景接收", systemImage: "moon").frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).controlSize(.large)
        }
    }
    private var photoPanel: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                PhotoPreview(photo: session.photos.first).aspectRatio(previewAspectRatio, contentMode: .fit)
                    .contentShape(Rectangle()).onTapGesture { selectedPhoto = session.photos.first }
                Text(session.photos.isEmpty ? "等待完整 JPG" : "輕觸查看原圖")
                    .font(.caption).padding(9).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10)).padding(12)
            }
            VStack(spacing: 14) {
                HStack { metric("本機已收", session.photos.count); metric("電腦待傳份數", pcJobs.filter { $0.state != .verified }.count); metric("電腦核對份數", verifiedPC) }
                ProgressView(value: pcJobs.isEmpty ? 0 : Double(verifiedPC) / Double(pcJobs.count)).tint(CamLinkTheme.gold)
                Text("Google Drive 與 OneDrive 各自顯示傳送／核對狀態，不共用電腦成功旗標。")
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                Button("查看拍攝紀錄與交付報告") { tab = 1 }.font(.footnote.bold()).tint(.white)
            }.padding(18)
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [CamLinkTheme.navy, CamLinkTheme.ink], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: 27, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption2).foregroundStyle(.white.opacity(0.75))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var cameraControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("USB 相機").font(.headline); Spacer(); Image(systemName: camera.connected ? "camera.fill" : "cable.connector") }
            Divider()
            Text(camera.status).font(.title3.weight(.semibold))
            if !camera.cameraName.isEmpty { Text(camera.cameraName).font(.subheadline) }
            if !camera.lastError.isEmpty { Text(camera.lastError).font(.footnote).foregroundStyle(.red) }
            if !camera.browsing {
                Button("開始接收新拍 JPG") { start(.newPhotos) }
                    .buttonStyle(CamLinkPrimaryButtonStyle()).controlSize(.large).disabled(!camera.canStart)
                Button("接收卡內 JPG") { start(.card) }.buttonStyle(.bordered).controlSize(.large).disabled(!camera.canStart)
                if camera.sessionClosing { Text("等待上一個相機工作階段安全關閉；暫不重新連接。").font(.caption) }
                Text("新拍模式會略過連線時已有的照片。要匯入記憶卡照片，請選「接收卡內 JPG」。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("目錄 \(camera.catalogCount) · 待接收 \(camera.queuedCount) · 失敗 \(camera.failedCount)")
                    .font(.caption).monospacedDigit()
                Button(camera.finishing ? "正在完成接收…" : "停拍並完成接收") { runtime.finishReceiving() }
                    .buttonStyle(CamLinkPrimaryButtonStyle()).controlSize(.large).disabled(camera.finishing)
                Button("重新搜尋照片及重試") { camera.refreshContents() }.buttonStyle(.bordered)
                    .disabled(!camera.connected || camera.finishing)
            }
            Text("JPG 原圖驗證後才列入紀錄，保留 MPF 附加影像；不刪除卡內照片，RAW 不傳。")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).camLinkCard()
    }
    private var transfers: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("傳送目的地").font(.largeTitle.bold())
            Text(transferName).font(.headline)
            if !retryMessage.isEmpty { Text(retryMessage).font(.footnote).foregroundStyle(CamLinkTheme.accent) }
            Button("只重試此活動已失敗的工作…") { showSessionRetry = true }
                .buttonStyle(.bordered).disabled(transferPhotos.isEmpty)
            Text("\(transferPhotos.count) 張已存原圖。開啟目的地後，仍須確認帳戶、資料夾與手動補傳範圍。")
                .font(.footnote).foregroundStyle(.secondary)
            if transferAlbumID != nil && transferAlbumID != session.sessionId {
                Button("返回目前接收活動") { transferAlbumID = nil }.buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("電腦接收器", systemImage: "desktopcomputer").font(.headline)
                Toggle("新照片自動傳送至已啟用的電腦", isOn: $session.autoUpload)
                Text("每部電腦獨立設定配對、指紋及新圖自動傳送；不將主電腦紀錄套用到第二部。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("設定電腦 1／電腦 2 與補傳") { showPC = true }.buttonStyle(CamLinkPrimaryButtonStyle())
                if !pc.message.isEmpty { Text(pc.message).font(.caption) }
            }.camLinkCard()
            destination("Google Drive", icon: "externaldrive.badge.person.crop", detail: google.message) { showGoogle = true }
            destination("OneDrive", icon: "cloud.fill", detail: oneDrive.status) { showOneDrive = true }
            destination("WebDAV／NAS", icon: "externaldrive.connected.to.line.below", detail: webDAV.message) { showWebDAV = true }
            ShareLink(items: transferPhotos.map(\.url)) { Label("分享此活動全部 JPG 原圖", systemImage: "square.and.arrow.up") }
                .buttonStyle(.bordered).disabled(transferPhotos.isEmpty)
            Text("Dropbox、Box、Google Photos、Flickr 等沿用 Android 的系統分享流程，可選項目依裝置已安裝的 App 而定；分享不是自動備份或內容核對證據。")
                .font(.caption).foregroundStyle(.secondary)
            Text("Cam Link \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func destination(_ title: String, icon: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).foregroundStyle(CamLinkTheme.accent)
                VStack(alignment: .leading, spacing: 5) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                Spacer(); Image(systemName: "chevron.right")
            }.frame(maxWidth: .infinity, alignment: .leading).camLinkCard()
        }.buttonStyle(.plain)
    }
    private func start(_ mode: CameraCaptureService.ReceiveMode) {
        guard camera.canStart else { return }
        pendingMode = mode
        checkStorage()
        if feedback.storageStatus.requiresAcknowledgement { storageAlert = true }
        else { runtime.startReceiving(mode) }
    }
    private func checkStorage() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        feedback.checkStorage(at: documents)
    }
    private func updateIdleTimer() { UIApplication.shared.isIdleTimerDisabled = camera.browsing && scenePhase == .active }
    private func dock(vertical: Bool) -> some View {
        let names = ["首頁", "紀錄", "傳送", "更多"]
        let icons = ["house", "clock.arrow.circlepath", "arrow.up.circle", "ellipsis"]
        return Group {
            if vertical { VStack { ForEach(0..<4) { index in navigationButton(index, title: names[index], icon: icons[index]) } } }
            else { HStack { ForEach(0..<4) { index in navigationButton(index, title: names[index], icon: icons[index]) } } }
        }.background(.white)
    }
    private func navigationButton(_ index: Int, title: String, icon: String) -> some View {
        Button { tab = index } label: {
            VStack(spacing: 5) { Image(systemName: icon).font(.system(size: 21)); Text(title).font(.caption) }
                .foregroundStyle(tab == index ? CamLinkTheme.accent : CamLinkTheme.muted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(tab == index ? .isSelected : [])
    }
    private nonisolated static func photoAspectRatio(at url: URL) -> CGFloat {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return 4.0 / 3.0 }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return CGFloat((5...8).contains(orientation) ? height / width : width / height)
    }
}
