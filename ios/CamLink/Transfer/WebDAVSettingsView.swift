import SwiftUI

struct WebDAVSettingsView: View {
    @EnvironmentObject private var store: WebDAVStore
    @Environment(\.dismiss) private var dismiss
    let photos: [ReceivedJPEG]

    @State private var folder = ""
    @State private var username = ""
    @State private var password = ""
    @State private var validationMessage = ""
    @State private var loadedDraft = false

    init(photos: [ReceivedJPEG]) {
        self.photos = photos
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("使用已建立的 HTTPS WebDAV 資料夾，伺服器必須允許 PUT 原圖與 authenticated GET 讀回核對。Cam Link 不會建立資料夾，也不會覆寫同名但內容不同的檔案。")
                        .foregroundStyle(Color.primary)
                    Text("儲存設定只在本機驗證格式，未傳送驗證；只有實際上傳後讀回的大小與 SHA-256 一致，才會計入 WebDAV 已驗證。")
                        .foregroundStyle(Color.secondary)
                } header: {
                    Text("WebDAV 原圖備份").foregroundStyle(Color.primary)
                }

                Section {
                    TextField("既有 HTTPS 資料夾網址", text: $folder)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Color.primary)
                    TextField("帳戶名稱", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Color.primary)
                    SecureField("應用程式密碼（每次儲存請重新輸入）", text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .foregroundStyle(Color.primary)
                    Button {
                        do {
                            try store.configure(folder: folder, username: username, password: password)
                            password = ""
                            validationMessage = "設定已儲存（僅本機）；未傳送驗證"
                            folder = store.config?.folderURL.absoluteString ?? folder
                            username = store.config?.username ?? username
                        } catch {
                            // configure exposes only fixed, redacted WebDAV errors.
                            validationMessage = error.localizedDescription
                        }
                    } label: {
                        Text("保存設定").foregroundStyle(Color.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(store.busy)
                    if !validationMessage.isEmpty {
                        Text(validationMessage).foregroundStyle(Color.primary)
                    }
                } header: {
                    Text("HTTPS 資料夾與帳戶").foregroundStyle(Color.primary)
                } footer: {
                    Text("密碼僅保存在此裝置的 WebDAV 專用金鑰鏈，不會預填或寫入一般設定檔。僅接受系統信任的 TLS 憑證；任何重新導向均會拒絕。")
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    Toggle("自動上傳新收到的原圖（明確選擇啟用）", isOn: $store.autoUpload)
                        .foregroundStyle(Color.primary)
                        .tint(.blue)
                        .disabled(store.config == nil)
                    Button {
                        validationMessage = ""
                        store.enqueue(photos)
                        Task { await store.uploadPending() }
                    } label: {
                        Text("上傳本場 JPG").foregroundStyle(Color.white)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(store.busy || store.config == nil || (photos.isEmpty && store.pendingCount == 0))
                    Button("重試失敗項目") {
                        validationMessage = ""
                        store.retryFailed()
                        Task { await store.uploadPending() }
                    }
                    .foregroundStyle(Color.blue)
                    .disabled(store.busy || store.config == nil || store.failedCount == 0)
                    Button("停用 WebDAV", role: .destructive) {
                        password = ""
                        validationMessage = ""
                        store.disable()
                    }
                    .disabled(store.config == nil)
                } header: {
                    Text("傳送方式").foregroundStyle(Color.primary)
                } footer: {
                    Text("自動上傳預設關閉；關閉時仍可手動上傳。此功能在 App 前景執行，不保證 App 關閉或 iOS 暫停後持續傳送。停用不會刪除本機原圖或舊佇列；切換設定不會將舊項目改傳到新目的地。")
                        .foregroundStyle(Color.secondary)
                }

                Section {
                    if let configuration = store.config {
                        LabeledContent("目前目的地", value: configuration.label)
                            .foregroundStyle(Color.primary)
                        LabeledContent("本場可選 JPG", value: "\(photos.count)")
                            .foregroundStyle(Color.primary)
                    } else {
                        Text("尚未設定或已停用").foregroundStyle(Color.primary)
                    }
                    LabeledContent("GET 已驗證", value: "\(store.verifiedCount)")
                        .foregroundStyle(Color.primary)
                    LabeledContent("待傳／傳送中（未驗證）", value: "\(store.pendingCount)")
                        .foregroundStyle(Color.primary)
                    LabeledContent("失敗（未驗證）", value: "\(store.failedCount)")
                        .foregroundStyle(Color.primary)
                    if store.oldJobsCount > 0 {
                        Text("另保留 \(store.oldJobsCount) 個非目前目的地項目。重新儲存相同資料夾與帳戶後可查看及續傳；不會自動轉到新帳戶。")
                            .foregroundStyle(Color.secondary)
                    }
                    if store.busy {
                        HStack {
                            ProgressView().tint(.blue)
                            Text("前景傳送／讀回核對中…").foregroundStyle(Color.primary)
                        }
                    }
                    Text(store.message).foregroundStyle(Color.primary)
                    ForEach(Array(store.activeJobs.filter { $0.state == .failed }.suffix(5))) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.name).foregroundStyle(Color.primary)
                            Text(job.error ?? "未傳送驗證；請重試")
                                .font(.footnote)
                                .foregroundStyle(Color.red)
                        }
                    }
                } header: {
                    Text("目前目的地的 WebDAV 狀態").foregroundStyle(Color.primary)
                } footer: {
                    Text("此處是獨立的 WebDAV 驗證，不代表電腦 Receiver 已接收；不會更改照片的電腦上傳狀態。失敗或停用都保留原圖。")
                        .foregroundStyle(Color.secondary)
                }
            }
            .foregroundStyle(Color.primary)
            .navigationTitle("WebDAV 備份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { password = ""; dismiss() }
                        .foregroundStyle(Color.blue)
                }
            }
            .onAppear {
                guard !loadedDraft else { return }
                loadedDraft = true
                folder = store.config?.folderURL.absoluteString ?? ""
                username = store.config?.username ?? ""
                // Never read the saved application password into a SwiftUI field.
                password = ""
            }
            .onDisappear { password = "" }
        }
        // Locally override an inherited white RootView style; never alter global appearance.
        .preferredColorScheme(.light)
    }
}
