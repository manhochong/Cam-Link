# Google Drive iOS 直接供應商模組

作者：Manus AI。2026-11-09 接續版本。修改範圍只有 `CamLink/Transfer/GoogleDriveStore.swift`、`CamLink/Transfer/GoogleDriveSettingsView.swift`、`GoogleDriveTests.swift` 和本文件。未修改相機、USB/PTP、JPEG/MPF、PC、其他供應商、RootView、App、plist、project 或 CI；未執行 Git、瀏覽器、登入或遠端寫入。

`GoogleDriveStore` 已包含官方 GoogleSignIn 的前景登入、靜默恢復、單一 SDK refresh 所有權、本機登出、真實 Drive `/about` 帳戶查詢、可存取資料夾選建、活動子資料夾、耐久工作與 resumable 原圖傳送。設定畫面不是鎖定提示或假連線測試。它顯示實際帳戶、選建資料夾、手動確認加入本相簿、自動傳送開關、Wi-Fi 限制、暫停、重試、取消與已遮蔽憑證的 JSON 匯出。

## 父層最小接線

以下都是 app-module/internal 型別，不需另建 framework。Store 及 View 是 `@MainActor`，應維持一個長生命週期的實例；不要為每張照片建立新 SDK adapter 或 OAuthCoordinator。

```swift
// 在 @MainActor 的 App／Root owner 建立；建議與 OneDrive 共用同一 coordinator。
let oauth = OAuthCoordinator()
let googleDrive = GoogleDriveStore(coordinator: oauth)
// default settings == OAuthAppConfiguration.settings，讀取父層編入的公開設定。

// 相簿頁面；photos 應是使用者正在看的場次，不是所有歷史累積照片。
GoogleDriveSettingsView(photos: receivedJPEGs, albumName: { session.albumName })
    .environmentObject(googleDrive)

// App 的 Google 專用 callback。保留既有 camlink 配對分支。
if googleDrive.handleCallback(url) { return }
// 原有 pairing URL handling 接在後面，不能全部改交 Google。

// 啟動／回前景：先恢復 SDK，再明確喚起本地待傳。
await googleDrive.restoreSignIn()
if googleDrive.autoUpload && !googleDrive.paused {
    await googleDrive.pump()
}

// 僅在真正接收完成後加入「本次新圖」。不要 onChange 全量累積 photos。
if googleDrive.autoUpload {
    await googleDrive.enqueue(newlyReceivedJPEGs, albumName: session.albumName)
    // enqueue 會在未暫停、SDK 已恢復時自行 startPending。
}
```

若父層的照片型別不是 `ReceivedJPEG`，由父層映射 `id/name/url/bytes/sha256/createdAt/uploaded`，本模組不修改父層或相機型別。`uploaded` 只屬原有電腦流程，Google 不讀它決定是否傳送，也不改它。

Google 的 SDK sheet 與 OneDrive 原生 OAuth sheet 必須由父層共用互動鎖互斥，例如在另一供應商 `authBusy` 時禁止進入／觸發此設定畫面登入。`OAuthCoordinator` 的私有 global slot 無法攔截 GIDSignIn 自己開啟的 sheet。此模組沒有改共用 OAuth；若要由程式層保證兩套登入完全互斥，需要父層注入共用 gate，或擴充 OAuthSupport 的互動鎖公開 API，不能誤稱現在已共用同一 SDK transaction。

## 確切公開整合 API

以下宣告是簽章參考，不是另一份編譯檔。

```swift
@MainActor final class GoogleDriveStore: ObservableObject {
    convenience init(coordinator: OAuthCoordinator? = nil,
        settings: OAuthPublicClientSettings = OAuthAppConfiguration.settings)

    // Foundation/macOS 測試 DI；monitorsNetwork=false 僅供可控測試。
    init(documentsURL: URL, settings: OAuthPublicClientSettings,
        auth: any GoogleDriveAuthenticating,
        http: GoogleDriveHTTP = GoogleDriveHTTP(),
        resumeVault: any GoogleDriveResumeVault,
        monitorsNetwork: Bool = true)

    func configure(clientID: String, redirectURI: String) async throws
    func signIn() async
    func restoreSignIn() async
    func disconnect() async throws
    func handleCallback(_ url: URL) -> Bool

    func browseFolders(parentID: String? = nil) async
    func selectFolder(_ folder: GoogleDriveFolder) async
    func createFolder(name: String, parentID: String? = nil) async
    func setAlbumSubfolders(_ enabled: Bool)
    func setAutomatic(_ enabled: Bool)
    func setWiFiOnly(_ enabled: Bool)

    func enqueue(_ photos: [ReceivedJPEG], albumName: String? = nil) async
    func pump() async             // 與 uploadPending 相同；不會解除使用者暫停。
    func uploadPending() async
    func startPending()           // 啟動一個前景 pump，重入會被擋下。
    func resumePending()          // 解除持久暫停並 startPending。
    func pause()                  // 持久化暫停，取消 pump／正在進行 task。
    func retryFailed()            // 僅重排目前帳戶；需另按開始／繼續。
    func cancelJob(_ id: String)  // 無遠端刪除；保留原圖與續傳 capability。
    func diagnosticsJSON() throws -> Data
}

@MainActor struct GoogleDriveSettingsView: View {
    init(photos: [ReceivedJPEG], albumName: @escaping () -> String = { "" })
    // 必須 .environmentObject(googleDrive)
}
```

可觀察的 `@Published private(set)` 值為 `setup/account/selectedFolder/folders/jobs/autoUpload/wifiOnly/albumSubfolders/busy/authBusy/signedInReady/paused/message`。計數為 `activeJobs/verifiedCount/pendingCount/failedCount/oldJobsCount`。`signedInReady=false` 時，磁碟上的帳戶只是本機歷史，不是登入成功。

`jobs: [GoogleDriveJob]` 是父層的精確交付收據來源。每筆含 `clientID/sdkUserID/accountID/folderID/photoID/sha256/bytes/remoteID/state/attempts/error/verifiedAt/verification`。只有 `.state == .verified` 且有 `verifiedAt` 才是已完成 Drive 原圖核對；不要併入 PC 或 OneDrive 收據。`albumParentID` 保留活動根資料夾綁定，`albumFolderPending` 表示活動子資料夾尚待網路解析；解析後 `folderID` 是實際子資料夾 ID，其他帳號／活動／資料夾不會被改寫。

注入測試邊界為 `GoogleDriveHTTP(session: URLSession?)`、`GoogleDriveAPI(http:token:)` 和 `GoogleDriveUploader(api:resumeVault:chunkSize:)`。`transfer(_:source:checkpoint:) async throws -> GoogleDriveJob` 與正式 Store 使用完全相同的程式。Checkpoint 是 `@MainActor @Sendable (GoogleDriveJob) async throws -> Void`；遠端 create 之前必須已落盤 generated ID。

`@MainActor GoogleDriveAuthenticating` 的確切方法為 `signIn(setup:)`、`restore(setup:)`、`fresh(setup:expectedUserID:)`，三者皆 `async throws -> GoogleDriveAuthorization`；`signOut(setup:expectedUserID:) async throws` 和 `handle(_ url: URL) -> Bool`。SDK 是 Google refresh/cache 的唯一所有者，共用 OAuth vault 只留沒有 refresh token 的短期 snapshot，不呼叫 generic `validToken` 假裝能更新 Google 過期 snapshot。[1] [2]

## 登記與權限界線

父層已完成真正的 `hk.camlink.ios` iOS 公開 client，**不是仍缺 client ID**：`518900347391-4fh5i9n3q2jpgh70aujo6ofs1i715dqu.apps.googleusercontent.com`；Drive API 已啟用，GoogleSignIn package 由父層固定 10.1.0。本模組 default 不硬編另一份 ID，也不退回 Android 登記。現在未完成的是簽署 iPad build 的 SDK 編譯／callback 驗收，以及同意畫面 audience／測試使用者和實際帳戶政策的真登入確認；本任務沒有帳戶授權，不能宣稱已 live 測試。

Runtime 可編輯 `clientID` 與完整 `redirectURI`；空白／不合理 ID 或完整 URI 不符，會在 SDK／HTTP 前停止。設定改變會本機登出，舊工作仍綁舊 client/帳戶而不轉送。此版本官方 SDK callback 必須精確為：

```text
com.googleusercontent.apps.518900347391-4fh5i9n3q2jpgh70aujo6ofs1i715dqu:/oauth2callback
```

該完整 path 是 10.1.0 SDK 實際來源的 `kBrowserCallbackPath`，不是泛用 native-app 文件猜出的 URI。反轉 scheme 必須已在簽署 Info.plist 的 URL types 中；runtime 改文字不能新增已簽署 scheme。[3] [4]

只請求 `https://www.googleapis.com/auth/drive.file`，不升級到受限制的全 Drive scope。資料夾 browse 會分頁列出本 App 可存取且 `canAddChildren` 的項目，可在目前層或 My Drive 建新資料夾。它不能看見全部既有資料夾；若要讓使用者授權其他既有項目，需要另接 Google Picker。本畫面已清楚說明這個限制。[5]

## 原圖、恢復與核對

入列不連網，採原子 JSON 保存帳戶／根資料夾／活動／照片綁定，即使離線或另一張正在上傳也能新增本地工作。Store 不掃描 Documents、不初始化相簿、不寫相機卡。來源使用 Documents 相對路徑，並在傳送前重新限制於同一 Documents、檢查 regular file 和原始大小，再重算整檔 SHA-256／MD5。活動子資料夾的 generated ID 先落盤，重試一律使用原 ID。原有正常工作可向後解碼，新活動工作會在 dispatch 時才解析實際子資料夾。

JPEG 結構驗證屬已驗證 ingest 核心；這裡只對既有原圖重新核對整檔大小／SHA，並保留 JPG SOI 基本閘。**不再要求最後兩 bytes 是 FFD9**，不裁掉 primary JPEG EOI 後的 MPF 輔助內容，不重新編碼。Synthetic 測試確認傳輸每一 byte 包含尾部資料，但不把 synthetic bytes 冒稱成真 MPF parser fixture；真正 MPF Mac 驗證由父層既有 JPEGIntegrity/MPFIntegrity 測試負責。

原圖從來源 fileURL 讀取，預設每次 1 MiB chunk，最多只緩衝這個 bounded chunk，沒有把整檔轉 UIImage 或載入一整份 Data。除最後一段外 chunk 是 256 KiB 的整數倍。308 只接受不帶 Location 的 resumable acknowledgement，下一段依伺服器 Range 計算，不依已送 bytes 推測。重啟會先 probe；404 清除自己的失效 capability，使用同一 generated ID 重建 session。遠端 200／201 後仍讀 metadata；最終回覆遺失後以原 remote ID 讀回驗證，而不是新建另一份。[6]

任何 409 或既有 remote ID 都不變成 PATCH。它必須符合 remote ID、檔名、大小、非 trashed、實際 parent 和工作 idempotency key，再比對 Drive API output-only MD5；API 有 SHA-256 時也必須一致。MD5 缺少時，會 authenticated `alt=media` 全檔讀回比大小和 SHA-256；不接受 appProperties 自填的 SHA 作內容證明。MD5 有值而 SHA API 未提供時，保留 Android 的「大小、parent、MD5」核對層級。任何錯誤均不覆寫或刪除既有檔案。[7] [8]

JSON 位於 `Documents/google-drive-jobs-v1.json`，不含 access/refresh token 或完整 resumable URI。URI 是 capability，另存獨立 Google Drive Keychain service，不進 diagnostics。真實 Google token 由 SDK Keychain 管理；短期 snapshot 使用共用 OAuth vault 的 `google-drive` namespace。損壞 JSON 不會被空佇列覆蓋，會停止傳送。登出、取消及換帳戶都保留照片、舊工作和遠端檔案。

重試最多每次操作五次，網路／逾時／408／429／5xx／rate-limit 403 採持久 nextAttemptAt 和有抖動的有限退避；401／需要互動改為需登入，衝突或雜湊不符不自動無限重試。使用者可明確重排。暫停狀態有落盤，網路恢復不會偷偷解除使用者暫停。這是前景網路佇列，不是背景 USB 保證。[6]

所有 HTTP 僅允許 `https://www.googleapis.com` 的 Drive API 路徑，bearer 只進 header；per-task delegate 拒絕所有 redirect。Metadata／chunk／probe 整體截止 40 秒，download readback 另有 180 秒整體截止。錯誤只顯示固定中文／數字 status，不回顯 provider payload、完整 URI、權杖或 NSError 路徑。只會移除 URLSession 自己產生的 GET 暫存檔，不刪來源照片。

## 父層全域網路政策接點

目前 Store 的 `NWPathMonitor` 和 `wifiOnly` 會在 dispatch 前閘住工作，網路不符時 cancel 進行中 task；但**這不能單獨保證 URLSession 永不選到 cellular／昂貴或受限路徑**。父層正在實作的 `CamLinkNetworkPolicy` 必須補到真正 request/session，這項未完成前不要宣稱已完整套用全域成本政策。

為避免本模組 Mac tests 新增父層依賴，本次沒有直接引用未落地的型別。父層可將 provider 的 `allowsCellular = !wifiOnly` 及全域費用設定注入 `GoogleDriveHTTP`。精確接點如下：

- `GoogleDriveHTTP.init(session:)` 的 ephemeral configuration，在 `URLSession(configuration:)` 前套 `CamLinkNetworkPolicy.apply(to: config, allowsCellular: allowsCellular)`；configuration 為參考型別，不加 `&`。目前設定處約在 288–292 行。
- `GoogleDriveHTTP.raw(_:token:resumable:)` 的 `var outgoing = request`，在 `session.data(for:delegate:)` 前套到 outgoing。這個**共用點已涵蓋 profile、folder list/create、generateIds、metadata、begin、probe 和 chunk**，不必漏掉某一條 API。
- `GoogleDriveHTTP.downloadedHash(_:token:bytes:)` 的 `var request`，在 `session.download(for:delegate:)` 前套到 request。
- 父層政策收緊時繼續呼叫 `googleDrive.pause()`／取消已啟動 task。只有更改下一次 session configuration 不會回溯取消現有請求。

SDK 本身的 token refresh／登入網路是 GoogleSignIn 所有，不是此 URLSession 的 policy 範圍。需要禁止特定網路上的登入時，父層應在開 sheet 前閘住；不要宣稱 REST policy 控制了 SDK 內部所有請求。

共用 OAuthSupport 的 REST helper 刻意把 308 視為 redirect，且不暴露 Location／Range，所以 resumable 不可能直接使用它。此模組只自行建立限制同樣嚴格的 `GoogleDriveHTTP`，不改共用檔案；若父層將來抽共用介面，需要「非重導向 308 acknowledgement＋經驗證 Location／Range」而不是放寬一般 bearer redirects。

## Mac 測試指令與尚未驗證項目

此 Sandbox 沒有 `swift` 或 Apple SDK。**未執行 Swift 編譯或任何測試，也未觸發 CI**。已執行 tree-sitter Swift grammar parse，三個指定 Swift 檔均無語法樹 ERROR／missing node；這不是 type check，也不是 SDK 編譯或 test pass。

父層可在真正 Mac／已授權 Codemagic runner，從 repo root 執行：

```bash
xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=minimal \
  -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  ios/CamLink/Transfer/OAuthSupport.swift \
  ios/CamLink/Camera/ReceivedJPEG.swift \
  ios/CamLink/Transfer/GoogleDriveStore.swift \
  ios/GoogleDriveTests.swift \
  -o /tmp/camlink-google-drive-tests
/tmp/camlink-google-drive-tests
```

UIKit／GoogleSignIn bridge 與 SwiftUI 畫面以 `#if canImport(UIKit)` 閘住，所以以上測試使用 Foundation、CryptoKit、Security、Combine、Network，不需要 Mac app UI 或測試帳號。`URLProtocol` 攔截每一條 URL，真實 production HTTP/API/uploader 仍用 injected URLSession 發送；不是只測 JSON codec，也不是 fake login／fake 成功的真人驗收。

預備案例覆蓋整檔 SHA／MD5 與 MPF 尾部不裁切、空白設定無網路、exact callback、hostile capability、Range 越界、正常與部分 acknowledgement、重啟 probe、過期 session、最終回覆遺失、錯誤 parent／hash 拒絕、缺少 API hash 的 authenticated download、錯誤 readback、預先取消、實際 redirect callback sink 拒絕、rate-limit 脫敏、活動 folder→原圖→metadata 正式 Store 管線、離線去重入列、snapshot 還原、帳戶切換隔離、取消重排、登出保留原圖和損壞 snapshot fail-closed。

以上命令仍須由真 Mac 實際跑過；之後還要編譯真 iOS16 target 與 pinned GoogleSignIn 10.1.0，完成 signed iPad sheet 取消／拒絕、Google consent audience／測試使用者、callback、冷啟動 restore、token 過期 refresh、帳戶切換、網路政策、實際資料夾與原圖 upload/readback。無 Mac 使用者繼續走父層既有 TestFlight 流程，不要求在用戶本機安裝 Xcode。使用者確認的 build41 iPad 五張 JPG／零 failed 和 PC 成功基線沒有被此模組重寫。

## References

[1]: https://developers.google.com/identity/sign-in/ios/api-access "Google iOS API scopes and refreshTokensIfNeeded"
[2]: https://developers.google.com/identity/sign-in/ios/reference/Classes/GIDGoogleUser "Google user configuration identity and async token refresh"
[3]: https://raw.githubusercontent.com/google/GoogleSignIn-iOS/10.1.0/GoogleSignIn/Sources/GIDSignIn.m "GoogleSignIn 10.1.0 actual callback path and local sign-out source"
[4]: https://developers.google.com/identity/sign-in/ios/reference/Classes/GIDSignIn "Google native sign-in restore handle and signOut APIs"
[5]: https://developers.google.com/workspace/drive/api/guides/api-specific-auth "Google Drive drive.file authorization and Picker visibility"
[6]: https://developers.google.com/workspace/drive/api/guides/manage-uploads "Drive resumable upload chunks status probes Range and retry rules"
[7]: https://developers.google.com/workspace/drive/api/reference/rest/v3/files "Drive file metadata output-only checksums parent and appProperties"
[8]: https://developers.google.com/workspace/drive/api/guides/create-file "Drive pre-generated IDs and conflict-safe retry without duplicates"
