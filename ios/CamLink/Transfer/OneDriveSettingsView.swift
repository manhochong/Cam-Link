#if canImport(UIKit)
import SwiftUI

struct OneDriveSettingsView: View {
    @EnvironmentObject private var store: OneDriveStore
    @Environment(\.dismiss) private var dismiss
    let photos: [ReceivedJPEG]
    let albumName: String
    @State private var clientID = ""
    @State private var redirectURI = ""
    @State private var tenant = "common"
    @State private var folderName = ""
    @State private var folders: [OneDriveFolder] = []
    @State private var browsePath: [OneDriveFolder] = []
    @State private var localBusy = false
    @State private var note = ""
    @State private var reportURL: URL?
    @State private var confirmImport = false
    @State private var confirmDisconnect = false
    init(photos: [ReceivedJPEG], albumName: String = "Cam Link") {
        self.photos = photos; self.albumName = albumName
    }
    private var working: Bool { localBusy || store.settingsBusy }
    var body: some View {
        NavigationStack {
            Form {
                Section("Microsoft 直接原圖傳送") {
                    Text("不需要 OneDrive App。這是獨立目的地，Microsoft 登入、PUT 成功或電腦已收到都不代表 OneDrive 已核對。")
                    Text(store.status).font(.callout)
                    if !note.isEmpty { Text(note).font(.callout) }
                }
                Section("帳戶") {
                    if let account = store.account {
                        LabeledContent("名稱", value: account.displayName)
                        if !account.email.isEmpty { LabeledContent("帳戶", value: account.email) }
                        LabeledContent("磁碟", value: account.driveName)
                    } else { Text("尚未登入 Microsoft") }
                    Button(store.account == nil ? "登入 Microsoft" : "重新登入／切換帳戶") {
                        Task { await store.signIn(); browsePath = []; await reloadFolders() }
                    }.disabled(working || store.busy)
                    if store.settingsBusy { Button("取消登入") { store.cancelSignIn() } }
                    Button("從金鑰鏈還原登入") { Task { await store.restore() } }
                        .disabled(working || store.account == nil)
                    Button("在本機登出", role: .destructive) { confirmDisconnect = true }
                        .disabled(working || store.account == nil)
                }
                Section {
                    TextField("Microsoft 公開 client ID", text: $clientID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("已註冊的精確 redirect URI", text: $redirectURI)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("common 或指定 tenant UUID", text: $tenant)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("儲存公開設定（需先登出）") {
                        do {
                            try store.configure(OneDriveClientSetup(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                                redirectURI: redirectURI.trimmingCharacters(in: .whitespacesAndNewlines),
                                tenant: tenant.trimmingCharacters(in: .whitespacesAndNewlines)))
                            note = "公開設定已保存，未表示登入成功。"
                        } catch { note = OneDriveFailure.safe(error).localizedDescription }
                    }.disabled(working || store.busy || store.account != nil)
                } header: { Text("iOS 公開客戶端") } footer: {
                    Text("預設使用 App 內已編譯的 iOS 註冊。common 支援個人及工作帳戶；指定 tenant 會限制可登入帳戶。不能在這裡加入 iOS URL scheme，修改 callback 必須有對應 signed build。不使用 client secret 或 Android callback。")
                }
                if store.account != nil {
                    Section {
                        LabeledContent("目的地", value: store.selectedFolder?.name ?? "依活動名稱建立資料夾")
                        Button("按活動名稱建資料夾") {
                            Task {
                                do { try await store.selectFolder(nil); note = "新加入工作會綁定活動名稱；舊工作不改目的地。" }
                                catch { note = OneDriveFailure.safe(error).localizedDescription }
                            }
                        }.disabled(working)
                        Text("瀏覽：" + (["OneDrive"] + browsePath.map { $0.name }).joined(separator: " / "))
                            .font(.caption)
                        HStack {
                            Button("根目錄") { browsePath = []; Task { await reloadFolders() } }
                            Button("上一層") { if !browsePath.isEmpty { browsePath.removeLast() }; Task { await reloadFolders() } }
                                .disabled(browsePath.isEmpty)
                            Button("重新整理") { Task { await reloadFolders() } }
                        }.disabled(working)
                        if let current = browsePath.last {
                            Button("選擇目前資料夾：\(current.name)") { Task { await choose(current) } }
                                .disabled(working)
                        }
                        ForEach(folders) { folder in
                            HStack {
                                Button(folder.name) { browsePath.append(folder); Task { await reloadFolders() } }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("選擇") { Task { await choose(folder) } }
                            }.disabled(working)
                        }
                        TextField("在目前層建立資料夾名稱", text: $folderName)
                        Button("建立並選擇資料夾") {
                            Task {
                                localBusy = true; defer { localBusy = false }
                                do {
                                    let created = try await store.createFolder(name: folderName, parentID: browsePath.last?.id)
                                    try await store.selectFolder(created); folderName = ""; note = "資料夾已選擇，未表示照片已上傳。"
                                } catch { note = OneDriveFailure.safe(error).localizedDescription }
                            }
                        }.disabled(working || folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: { Text("資料夾") } footer: {
                        Text("只在明確建立資料夾或加入照片時寫入選定目的地。既有同名資料夾可使用；同名不同內容的檔案不覆寫。更換資料夾不會將舊工作改送到新位置。")
                    }
                }
                Section {
                    Toggle("自動加入新收到的原圖（預設關閉）", isOn: $store.autoUpload)
                        .disabled(store.account == nil || working)
                    Toggle("只用 Wi-Fi", isOn: $store.wifiOnly)
                    Text(store.networkAvailable ? (store.onWiFi ? "目前 Wi-Fi 可用" : "目前不是 Wi-Fi；僅 Wi-Fi 時會等待") : "等待網路恢復")
                        .font(.caption)
                    Button("明確加入本場 \(photos.count) 張原圖") { confirmImport = true }
                        .disabled(photos.isEmpty || store.account == nil || working)
                    Button("繼續上傳／核對") { Task { await store.resume() } }
                        .disabled(store.account == nil || working || store.busy)
                    Button("暫停（保留續傳）") { store.pause() }.disabled(!store.busy && store.paused)
                    Button("重試本帳戶失敗工作") { store.retryFailed(); Task { await store.resume() } }
                        .disabled(store.account == nil || working)
                } header: { Text("傳送政策") } footer: {
                    Text("自動模式只應由拍攝接收 hook 加入新圖，不會追加入所有歷史照片。啟用後請按繼續。所有原圖包含完整 MPF 都按完整位元組傳送；App 前景執行，不保證鎖屏、背景或 USB 持續接收。")
                }
                Section("獨立核對結果") {
                    LabeledContent("OneDrive 已核對", value: "\(store.verifiedCount)")
                    LabeledContent("未核對待傳", value: "\(store.pendingCount)")
                    LabeledContent("需處理", value: "\(store.failedCount)")
                    Button("準備已遮蔽憑證的診斷 JSON") { prepareReport() }
                    if let reportURL { ShareLink("分享 OneDrive 診斷報告", item: reportURL) }
                    Text("報告含活動／檔名、雜湊與傳送狀態；不含電郵、權杖、本機路徑或續傳網址。仍可能是私人工作資料，只分享給可信任的人。")
                        .font(.caption)
                    ForEach(store.jobs.reversed()) { job in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.originalName).font(.headline)
                            Text("\(job.albumName) · \(job.folderName)").font(.caption)
                            Text(job.state.label).font(.subheadline)
                            ProgressView(value: Double(job.offset), total: Double(max(1, job.bytes)))
                            Text("\(job.offset) / \(job.bytes) bytes · 嘗試 \(job.attempts)").font(.caption)
                            if let method = job.verification { Text(method).font(.caption) }
                            if let error = job.error { Text(error).font(.caption).foregroundStyle(.red) }
                            if job.state != .verified && job.state != .cancelled {
                                Button("取消這個工作；保留原圖") { Task { await store.cancel(jobID: job.id) } }
                                    .font(.caption)
                            }
                        }.padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("OneDrive")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task {
                clientID = store.setup.clientID; redirectURI = store.setup.redirectURI; tenant = store.setup.tenant
                if store.account != nil { await reloadFolders() }
            }
            .confirmationDialog("將本場原圖加入 OneDrive？", isPresented: $confirmImport, titleVisibility: .visible) {
                Button("加入 \(photos.count) 張完整原圖") {
                    Task {
                        localBusy = true
                        do {
                            _ = try await store.enqueue(photos, albumName: albumName)
                            localBusy = false; await store.resume()
                        } catch { localBusy = false; note = OneDriveFailure.safe(error).localizedDescription }
                    }
                }
            } message: { Text("只加入明確選取的本場；不會改寫既有工作或刪除任何原圖。目的地：\(store.selectedFolder?.name ?? albumName)。") }
            .confirmationDialog("在此裝置登出 OneDrive？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("登出並停止自動加入", role: .destructive) { Task { await store.disconnect(); folders = []; browsePath = [] } }
            } message: { Text("刪除本帳戶的本機憑證與續傳網址，保留本機照片、工作歷史及遠端檔案。這不是撤銷 Microsoft 授權或清除瀏覽器登入。") }
        }
    }
    @MainActor private func prepareReport() {
        let rows: [[String: Any]] = store.jobs.map { job in
            ["id": job.id, "photoID": job.photoID, "name": job.originalName,
             "album": job.albumName, "bytes": job.bytes, "offset": job.offset,
             "state": job.state.rawValue, "attempts": job.attempts,
             "verification": job.verification ?? "", "sha256": job.sha256]
        }
        let value: [String: Any] = ["version": 1, "provider": "OneDrive",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "accountConfigured": store.account != nil, "verified": store.verifiedCount,
            "pending": store.pendingCount, "failed": store.failedCount, "jobs": rows]
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("CamLink-OneDrive-results.json")
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            reportURL = url; note = "診斷報告已準備，這不是遠端上傳驗收。"
        } catch { reportURL = nil; note = "無法準備診斷報告，原圖不受影響。" }
    }
    @MainActor private func reloadFolders() async {
        guard store.account != nil, !localBusy else { return }
        localBusy = true; defer { localBusy = false }
        do { folders = try await store.folders(parentID: browsePath.last?.id) }
        catch { folders = []; note = OneDriveFailure.safe(error).localizedDescription }
    }
    @MainActor private func choose(_ folder: OneDriveFolder) async {
        localBusy = true; defer { localBusy = false }
        do { try await store.selectFolder(folder); note = "新工作會綁定此資料夾；舊工作不變。" }
        catch { note = OneDriveFailure.safe(error).localizedDescription }
    }
}
#endif
