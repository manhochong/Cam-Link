#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

/// Parent injects the single long-lived store. Photos must be the user-visible album,
/// not every historical photo. Automatic admission is explicitly owned by the parent.
@MainActor
struct GoogleDriveSettingsView: View {
    @EnvironmentObject private var drive: GoogleDriveStore
    let photos: [ReceivedJPEG]
    private let albumName: () -> String
    @State private var clientID = ""
    @State private var redirectURI = ""
    @State private var folderName = "Cam Link"
    @State private var browseParent: GoogleDriveFolder?
    @State private var folderPath: [GoogleDriveFolder] = []
    @State private var confirmEnqueue = false
    @State private var confirmDisconnect = false
    @State private var showExporter = false
    @State private var report = GoogleDriveReportDocument()
    @State private var localMessage: String?

    init(photos: [ReceivedJPEG], albumName: @escaping () -> String = { "" }) {
        self.photos = photos; self.albumName = albumName
    }

    var body: some View {
        Form {
            accountSection
            folderSection
            queueSection
            setupSection
            Section("使用界線") {
                Text("只新增完整原始 JPG；保留 MPF 全部 bytes，不縮圖、不裁切、不覆寫或刪除既有雲端檔案。Drive 狀態與電腦／其他目的地獨立。")
                Text("App 前景可執行及重試此佇列；不保證切 App、鎖屏後仍接收 USB 或傳送。口袋模式是黑色前景畫面。")
                Text("登入、資料夾建立與 HTTP 成功不是照片已核對；只有大小、parent 與 API 雜湊或完整讀回 SHA-256 通過才顯示『已核對』。")
            }.font(.footnote)
        }
        .navigationTitle("Google Drive")
        .task {
            clientID = drive.setup.clientID; redirectURI = drive.setup.redirectURI
            if drive.account != nil && !drive.signedInReady { await drive.restoreSignIn() }
        }
        .confirmationDialog("將這個相簿的原圖加入 Drive？", isPresented: $confirmEnqueue, titleVisibility: .visible) {
            Button("確認加入 \(photos.count) 張完整 JPG") {
                Task { await drive.enqueue(photos, albumName: albumName()) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目的地：\(drive.account?.email ?? "") / \(drive.selectedFolder?.name ?? "")。既有紀錄不會改目的地；不會自動掃描其他歷史照片。")
        }
        .confirmationDialog("清除 Drive 本機連線？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("登出並清除本機連線", role: .destructive) {
                Task {
                    do { try await drive.disconnect() }
                    catch { localMessage = GoogleDriveFailure.message(error) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會暫停傳送及關閉自動上傳。所有原圖、歷史工作與遠端檔案保留；不撤銷共用 Google 專案的授權。")
        }
        .fileExporter(isPresented: $showExporter, document: report, contentType: .json,
                      defaultFilename: "CamLink-GoogleDrive-results") { result in
            switch result {
            case .success: localMessage = "結果檔已匯出；這不是遠端連線測試。"
            case .failure: localMessage = "匯出未完成；沒有顯示可能包含本機路徑的原始錯誤。"
            }
        }
    }

    private var accountSection: some View {
        Section("帳戶與授權") {
            if let account = drive.account {
                Text(account.displayName).font(.headline)
                Text(account.email).textSelection(.enabled)
                Text(drive.signedInReady ? "SDK 帳戶已恢復／登入" : "只有本機帳戶紀錄；尚未恢復授權")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("尚未登入 Google 帳戶") }
            Text("權限：drive.file；只讀寫本 App 已獲授權的檔案。Google SDK 保管並更新權杖，不需要密碼或 client secret。")
                .font(.footnote)
            Button(drive.account == nil ? "登入 Google 並授權 Drive" : "重新登入／切換 Google 帳戶") {
                Task { await drive.signIn() }
            }.disabled(drive.busy || drive.authBusy)
            if drive.account != nil {
                Button("恢復先前登入") { Task { await drive.restoreSignIn() } }
                    .disabled(drive.busy || drive.authBusy)
                Button("登出並清除本機連線", role: .destructive) { confirmDisconnect = true }
                    .disabled(drive.authBusy)
            }
        }
    }

    private var folderSection: some View {
        Section("Drive 資料夾") {
            Text("目前目的地：\(drive.selectedFolder?.name ?? "尚未選擇")")
            Text("只列出 drive.file 可見且能新增的資料夾。其他既有資料夾需另接 Google Picker 授權；本畫面不能瀏覽整個 Drive，也不要求受限制的完整 Drive scope。")
                .font(.footnote).foregroundStyle(.secondary)
            Button("列出本 App 可存取的資料夾") {
                folderPath = []; browseParent = nil
                Task { await drive.browseFolders() }
            }.disabled(locked || !drive.signedInReady)
            if let parent = browseParent {
                HStack {
                    Text("瀏覽：\(parent.name)")
                    Spacer()
                    Button("上一層") {
                        if !folderPath.isEmpty { folderPath.removeLast() }
                        browseParent = folderPath.last
                        Task { await drive.browseFolders(parentID: browseParent?.id) }
                    }
                }
            }
            ForEach(drive.folders) { folder in
                VStack(alignment: .leading, spacing: 6) {
                    Text(folder.name)
                    HStack {
                        Button("選擇此資料夾") { Task { await drive.selectFolder(folder) } }
                        Spacer()
                        Button("瀏覽子資料夾") {
                            browseParent = folder; folderPath.append(folder)
                            Task { await drive.browseFolders(parentID: folder.id) }
                        }
                    }.font(.caption).buttonStyle(.borderless)
                }.disabled(locked || !drive.signedInReady)
            }
            TextField("新資料夾名稱", text: $folderName)
            Button(browseParent == nil ? "在我的雲端硬碟建立並選取" : "在此層建立並選取") {
                Task { await drive.createFolder(name: folderName, parentID: browseParent?.id) }
            }.disabled(locked || !drive.signedInReady || folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Toggle("依活動名稱建立子資料夾", isOn: Binding(get: { drive.albumSubfolders }, set: { drive.setAlbumSubfolders($0) }))
                .disabled(locked)
            Text("父層傳入的活動名稱：\(albumName().isEmpty ? "未指定；直接使用選定資料夾" : albumName())")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var queueSection: some View {
        Section("原圖耐久佇列") {
            Toggle("自動加入新收到的本場 JPG", isOn: Binding(get: { drive.autoUpload }, set: { drive.setAutomatic($0) }))
                .disabled(drive.account == nil || drive.selectedFolder == nil || drive.authBusy)
            Toggle("只用 Wi-Fi", isOn: Binding(get: { drive.wifiOnly }, set: { drive.setWiFiOnly($0) }))
            Text("自動上傳預設關閉。啟用不會補傳舊相簿；父層只應加入新收到的照片。關閉 Wi-Fi 限制可能使用流動數據。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("此帳戶累計：已核對 \(drive.verifiedCount) · 待傳 \(drive.pendingCount) · 問題 \(drive.failedCount)")
            Text("其他帳戶歷史保留 \(drive.oldJobsCount) 筆，不會轉送到新帳戶。")
                .font(.caption).foregroundStyle(.secondary)
            Text(drive.message).textSelection(.enabled)
            if let message = localMessage { Text(message).font(.footnote) }
            if drive.busy || drive.authBusy { ProgressView("處理中；未完成項目不算已核對") }
            Button("將畫面中 \(photos.count) 張原圖加入此目的地…") { confirmEnqueue = true }
                .disabled(photos.isEmpty || drive.selectedFolder == nil || drive.account == nil)
            Button(drive.paused ? "繼續待傳佇列" : "開始上傳待傳佇列") { drive.resumePending() }
                .disabled(locked || !drive.signedInReady)
            Button("暫停上傳") { drive.pause() }.disabled(!drive.busy)
            Button("重排此帳戶失敗／取消項目") { drive.retryFailed() }.disabled(locked || drive.account == nil)
            ForEach(Array(drive.activeJobs.suffix(50).reversed())) { job in
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.subheadline)
                    Text(job.state.label).font(.caption)
                    Text("\(job.offset) / \(job.bytes) bytes · 嘗試 \(job.attempts) 次 · \(job.folderName)")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let verification = job.verification, job.state == .verified { Text(verification).font(.caption2) }
                    if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
                    if job.state != .verified && job.state != .cancelled {
                        Button("取消此工作（保留原圖與遠端）", role: .destructive) { drive.cancelJob(job.id) }
                            .font(.caption).buttonStyle(.borderless)
                    }
                }
            }
            Button("匯出已遮蔽憑證的結果 JSON") {
                do { report = GoogleDriveReportDocument(data: try drive.diagnosticsJSON()); showExporter = true }
                catch { localMessage = GoogleDriveFailure.message(error) }
            }
            Text("結果含照片 ID、活動名稱、雜湊和遠端 ID；不含 email、權杖、續傳網址或本機路徑。仍可能是私人工作資料，請只分享給可信任的人。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var setupSection: some View {
        Section("公開 iOS OAuth 設定") {
            TextField("iOS OAuth client ID", text: $clientID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("完整 SDK redirect URI", text: $redirectURI)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("依 client ID 填入 SDK callback") {
                var settings = OAuthPublicClientSettings(); settings.googleIOSClientID = clientID
                if let scheme = try? settings.googleReversedClientID() { redirectURI = scheme + ":/oauth2callback" }
                else { localMessage = GoogleDriveFailure.setup.localizedDescription }
            }.disabled(locked)
            Button("保存公開設定（變更會本機登出）") {
                Task {
                    do { try await drive.configure(clientID: clientID, redirectURI: redirectURI); localMessage = nil }
                    catch { localMessage = GoogleDriveFailure.message(error) }
                }
            }.disabled(locked)
            Text("必須是 hk.camlink.ios 的 iOS client，Drive API 已啟用，Google 同意畫面／測試使用者允許此帳戶。SDK 使用 reversed-client-ID:/oauth2callback；其 scheme 必須已編入這個簽署 App。空白或不符不會開網路；改文字不會新增已簽署 URL scheme。")
                .font(.footnote)
            Text("GoogleSignIn SDK 版本由專案固定；此模組不使用 Android package／SHA-1 註冊，也不接受 secret。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var locked: Bool { drive.busy || drive.authBusy }
}

private struct GoogleDriveReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data = Data("[]".utf8)
    init(data: Data = Data("[]".utf8)) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
#endif
