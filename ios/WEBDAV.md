# iOS WebDAV 原圖備份

這是獨立的真實 WebDAV 目的地，不是 Google Drive／Microsoft OneDrive OAuth 的替代或假登入。候選 build 37 已在 App 和傳送頁接入設定、獨立工作佇列及明確啟用後的前景自動傳送，完整 Apple SDK 編譯與 TestFlight 內部分發均已完成；有效 WebDAV 伺服器仍未實測。

## iPad 使用方式

在「傳送」→「WebDAV（NAS／雲端資料夾）」輸入已有可寫入的 HTTPS 資料夾網址、使用者名稱與應用程式密碼，按「儲存設定」。這只保存本機設定，不表示遠端登入成功。先以少量已收 JPG 按「上傳本場 JPG」測試；只有遠端讀回核對通過，紀錄才會變成 verified。若要收照片後自动備份，再自行開啟自動上傳。

伺服器必須支援正確的 PUT／GET 及有效 HTTPS 憑證。App 不建立遠端資料夾、不覆寫同名不同內容，也不因 WebDAV 失敗刪除相機原圖。保持 App 前景；不保證關閉或切換 App 後繼續備份。

## 對外介面（同一 App module）

```swift
@MainActor final class WebDAVStore: ObservableObject {
    init()
    @Published private(set) var config: WebDAVConfiguration?
    @Published var autoUpload: Bool           // 初次啟動 false；改變即保存
    @Published private(set) var busy: Bool
    @Published private(set) var message: String
    @Published private(set) var jobs: [WebDAVJob]

    var activeJobs: [WebDAVJob] { get }
    var verifiedCount: Int { get }
    var pendingCount: Int { get }             // pending + uploading
    var failedCount: Int { get }
    var oldJobsCount: Int { get }

    func configure(folder: String, username: String, password: String) throws
    func disable()
    func retryFailed()                       // 將目前目的地 failed 改 pending；不自行連線
    func enqueue(_ photos: [ReceivedJPEG])    // 同步排入可用的本機原圖；不自行連線
    func uploadPending() async               // 手動允許 autoUpload == false
}

struct WebDAVSettingsView: View {
    init(photos: [ReceivedJPEG])
    // 需要 .environmentObject(WebDAVStore)
}
```

發布的設定／狀態是唯讀 getter，只有 `autoUpload` 可供 Toggle 綁定。透過 `configure`／`disable` 改設定，避免繞過目的地與金鑰鏈驗證。

`WebDAVConfiguration` 為 `Identifiable, Codable, Equatable, Sendable`，欄位是 `id: String`、`label: String`、`folderURL: URL`、`username: String`；沒有密碼。`id` 是正規化資料夾 URL 與 username 的 SHA-256。

`WebDAVJob` 為 `Identifiable, Codable, Equatable, Sendable`，持有 `id`、`destination: WebDAVConfiguration`、`photoID`、`name`、`remoteName`、`localRelativePath`、`bytes: Int64`、`sha256`、`createdAt`、`state`、`attempts`、`updatedAt`、`verifiedAt: Date?`、`error: String?`，另有 `configurationID` getter。狀態 enum 為 `pending`／`uploading`／`verified`／`failed`。所有計數只計目前目的地；舊目的地項目保留但不改傳。

## 父層整合

1. 在 App 層建立一次 `@StateObject private var webDAV = WebDAVStore()`，在 Root 層注入 `.environmentObject(webDAV)`。
2. 新增 WebDAV 設定入口，顯示 `WebDAVSettingsView(photos: session.photos).environmentObject(webDAV)`。原有雲端選項及頁面調度由父層決定。
3. 在收到／復原場次 JPG 後呼叫 `webDAV.enqueue(session.photos)`。重複呼叫會依目的地 id、遠端檔名、SHA-256 去重，不依賴 `ReceivedJPEG.uploaded`。
4. 自動調度只在明確啟用、已有設定且 App 在前景時呼叫；手動設定畫面不受自動開關限制：

```swift
webDAV.enqueue(session.photos)
if webDAV.autoUpload && webDAV.config != nil && scenePhase == .active {
    Task { await webDAV.uploadPending() }
}
```

5. 恢復前景或首次載入已復原的佇列時，可用同樣條件再次調度。Store 本身不建立 Timer、背景 job 或相機 observer；`uploadPending` 的 MainActor busy guard 保證只有一個 pump。
6. 如果父層保留該 Task，取消它會取消 WebDAV 目前傳輸並將未驗證項目留為 pending。`disable()` 也會取消目前 WebDAV 傳輸；兩者都不控制或停止相機。

`ReceivedJPEG` 需要既有欄位及 `Sendable`；目前整合中的型別已具備。XcodeGen 的 `CamLink` 來源目錄會自動包含新增的 Swift 檔，不需要新增 build 設定。

## 真實驗證及安全界線

- 接受既有 HTTPS 資料夾 + username + application password；拒絕 HTTP、URL 內嵌帳密、query、fragment、控制字元及 dot 路徑段。資料夾尾端統一為 `/`；不發 MKCOL 或探測請求。
- `configure` 只做本機驗證與儲存，畫面明示「未傳送驗證」。不宣稱帳密／伺服器權限已有效。
- App password 只存獨立 `*.webdav.credentials.v1` Keychain service，以目的地 id 為 account，使用 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` 且不同步。密碼不進 JSON、UserDefaults、SwiftUI 預填欄位或日誌。
- `Documents/webdav-jobs.json` 原子保存公開設定、明確自動選擇及佇列。啟動時先 decode／validate，將 uploading 復原為 pending，再容許網路傳送。佇列損壞時停止，不以空佇列覆蓋原檔。
- 來源限本機 Documents 裡可讀、大小符合 ReceivedJPEG metadata 的 JPG／JPEG regular file；傳送前另以離開主執行緒的 FileHandle 分塊檢查 JPEG SOI／EOI、大小及 SHA-256。不存在／改變的原圖不能獲得成功狀態。
- PUT 使用 `uploadTask(..., fromFile:)`、`Content-Type: image/jpeg` 與 `If-None-Match: *`，不把原圖整份讀入 Data。PUT 回應 body 直接丟棄，不累積或日誌記錄。
- 僅 PUT `201`／`200`／`204` 或 `412` 進入 authenticated GET；GET 必須 `200`，下載至暫存檔後分塊核對實際大小與 SHA-256。`412` 只有遠端內容完全相同才是 verified；不相同則 failed，絕不重送為覆寫。
- TLS 使用系統預設信任，不引用 PC certificate pin，不放行 invalid cert。全部重新導向（包含同 host HTTPS）都拒絕；不把密碼放在 URL、不接受伺服器導向的新 URL。
- 只有 GET 核對完成會有 `verifiedAt`；PC 的 `ReceivedJPEG.uploaded` 完全不變。此狀態不可當成 Receiver 的確認。
- 每次 pump 遇到第一個失敗即停止，失敗項目需明確重試；其餘 pending 保留。HTTP code／固定錯誤訊息可見，原始 NSError、回應 body、Authorization 及能力 URL 不進訊息。
- 只清理本次 GET 的下載暫存檔。不刪本機相機原圖、不壓縮、不改副檔名內容。停用保留舊目的地與金鑰鏈；重新設定相同 folder + username 可恢復同一身分並重試。
- 使用 ephemeral 前景 URLSession，不承諾 App 被暫停／關閉後持續上傳。自動傳送授權及場景生命週期由父層接線。

## 錯誤與驗收

固定錯誤涵蓋格式／密碼空值、Keychain 不可用、JSON／磁碟不可用、本機原圖改變、TLS／網路問題、HTTP 重新導向／401／403／404／409、遠端 hash mismatch 及 412 異內容碰撞。佇列寫入失敗後停止進一步網路操作；保留 JSON 檔處理，不清空歷史。

新增檔案已通過 tree-sitter Swift 語法解析及 `git diff --check`，完整 App 亦在 Codemagic 建置 `6af03b8f24e1ec237557710f` 通過 Apple SDK 編譯與簽名封裝。App Store Connect build 37 為 `Testing` 且已加入 `CamLink Internal`。沒有實際 WebDAV 帳密，未進行遠端 PUT／GET，也沒有聲稱遠端已驗證。

整合後應在有效憑證的受控 WebDAV 測試：201 原圖讀回、200／204 PUT、412 相同與不同內容、PUT／GET redirect、401／403、壞憑證、網路中斷、磁碟滿、重新啟動 uploading、A→B→A 目的地與金鑰鏈恢復，以及 WebDAV 失敗時相機 JPG 是否照常落盤。Google 與 Microsoft OAuth 仍需要真實 provider app／redirect 配置；本次沒有假認證，也沒有新增其他雲端提供者。
