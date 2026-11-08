# OneDrive 直接整合

作者：Manus AI。官方規格核對：2026-11-08。僅新增／修改 `Transfer/OneDriveStore.swift`、`Transfer/OneDriveSettingsView.swift`、`ios/OneDriveTests.swift` 和本文件。沒有修改相機／PTP／MPF、配對、RootView、App、plist、專案或 CI，沒有操作 Git、瀏覽器、登入帳戶或觸發遠端傳送。使用者確認的 build41 iPad 五張 JPG／零失敗及 PC 成功仍是基線。

## 已實作的登入與目的地

使用 `OAuthAppConfiguration.settings` 取得父層提供的 iOS 公開註冊，現在是 client ID `16437f88-79e4-499f-8cb3-7f07c9146e0c`，callback `msauth.hk.camlink.ios://auth`。父層已確認 Azure 儲存此 native 註冊；這不等於本模組已測試真實登入。沒有 Android ID 回退，不重新建立註冊，也不使用 client secret。

`OneDriveClientSetup.configuration()` 產生 `common` v2 authorization code＋PKCE 設定，scope 為 `openid profile offline_access User.Read Files.ReadWrite`，可同時支援個人與工作帳戶。可明確指定 tenant UUID，但那會限制可登入帳戶。共用 `OAuthCoordinator` 提供真正 `ASWebAuthenticationSession`、state、S256、精確全 callback 比對、Keychain refresh／rotation 和可取消登入。正式保存前由 Graph `/me` 解析穩定 account ID，再解析 `/me/drive` 和 root；沒有以 email 或未驗證 ID-token claim 當身份。`restore()` 使用 Keychain refresh 並重查身份和 drive，`disconnect()` 只刪本帳戶本機憑證和本模組續傳 capability，保留原圖、工作紀錄和雲端檔案。[1] [2]

設定畫面有登入、還原、更改公開設定、根目錄及子層資料夾分頁瀏覽、建立／選擇固定資料夾、按活動名稱建資料夾、明確加入本場、暫停、繼續、重試、取消和獨立工作歷史。資料夾建立使用 `conflictBehavior=fail`，若已存在同名資料夾只使用其 ID；不會將同名檔案改成資料夾，也不會改寫舊工作的目的地。磁碟使用已登入帳戶的預設 OneDrive，不宣稱是 SharePoint sites 或所有 shared-drive 的跨租戶瀏覽器。

## 完整原圖與真正遠端核對

所有大小的原圖都走 `createUploadSession`，因此大於 4 MiB 必定分段續傳；小圖也使用相同的 fail-conflict 路徑。非最後段是 `10 × 320 KiB = 3,276,800 bytes`，順序 PUT 且小於 60 MiB。Graph POST 帶 Bearer，但 signed upload URL 的 GET 和 PUT **不帶 Bearer**。每次要求都拒絕重新導向，包括同 host。只接受 HTTPS、無 userinfo、無 fragment、標準 port，以及 Graph／明確 Microsoft 內容主機；不接受任意下載主機。[3]

續傳 capability 只保存在專用 `hk.camlink.ios.onedrive.upload.v1` Keychain，普通 JSON 只有 offset 和非秘密工作欄位。建立 capability 後先持久保存才送第一段。重新啟動或重試時先查 deterministic 名稱是否已完成，再 GET 仍有效 session 的 `nextExpectedRanges`，不憑本機 offset 猜測；416 重新查狀態有有限次數，404／410 會清除過期 capability 並有限重建。遠端檔名由清理後的原名、完整本機 SHA-256 及 photo ID 雜湊組成。重複加入同一帳戶／drive／folder／photo／SHA 不建立新工作；已有 verified、failed 或 cancelled 工作也不因再次加入而偷偷複製或重置。409 只查原 deterministic 名稱並核對，絕不使用 replace 或 rename。[3]

`OneDriveOriginal.inspect` 串流讀取**整個原檔**並計算 SHA-256 和 SHA-1，包含 MPF 第一張 JPEG 結束後的所有附加原圖；不重編碼、不截到 FFD9、不再加入「最後兩 bytes 必須是 FFD9」的錯誤條件。上傳前比對 ingest 已保存的 bytes／SHA-256，上傳後再讀完整本機檔案以防傳送期間被變更。這是在已 ingest 原圖之上核對，不冒充另一個相機 JPEG／MPF validator。

遠端核對必查 item ID、原 deterministic name、大小、file facet、parent ID、drive ID 和 eTag。服務若提供 SHA-1 或 SHA-256，必須與完整原圖相應雜湊一致；同時有兩個時兩個都查，已提供但錯誤的 hash 直接失敗。支援官方 hex 及相容的 Base64 表示。官方目前將 `sha256Hash` 標為 unsupported，不能依賴它存在；quickXor 和 CRC32 不算密碼學核對。[4]

沒有 SHA-1／SHA-256 時，使用 Graph item metadata 新取得的 `@microsoft.graph.downloadUrl`，不帶 Bearer，下載完整內容到本模組專用私有 temporary directory，計算大小和 SHA-256 一致後才通過；完成只刪除本模組自己的暫存下載，從不刪除相機、本機原圖或其他 provider 檔案。讀回後再查相同 item 的 eTag／parent／drive／size，避免中途變更仍誤判。若服務給出不在明確 allowlist 的內容主機或需要再次 redirect，會安全失敗而不是放寬主機或轉送 token。[5]

收據的 `method` 精確區分 `server SHA-1`、`server SHA-256`、兩者及 `full GET SHA-256`。**`server SHA-1` 不可被父層顯示成遠端 SHA-256 已驗證**；收據內 `sha256` 是本機完整原圖識別，並非每次都代表服務提供 SHA-256。

## 父層精確整合 API

所有型別在 CamLink 同一 app module，`@MainActor final class OneDriveStore: ObservableObject`。正式 UIKit initializer 和 view initializer 如下；XcodeGen 自動收錄 `ios/CamLink` 下來源，不需新增來源列表。

```swift
// UIKit-only convenience initializer, uses parent-compiled OAuthAppConfiguration.settings.
OneDriveStore(coordinator: OAuthCoordinator? = nil, setup: OneDriveClientSetup? = nil)

// UIKit view, store comes from EnvironmentObject, photos is the explicit current/selected batch.
OneDriveSettingsView(photos: [ReceivedJPEG], albumName: String = "Cam Link")

// Foundation + Combine/macOS-testable initializer; no OAuthAppConfiguration dependency on macOS.
OneDriveStore(
    coordinator: OAuthCoordinator,
    setup: OneDriveClientSetup,
    rootDirectory: URL,          // existing Documents tree, sources are read-only
    stateDirectory: URL,         // module-owned directory for onedrive-v1.json
    transport: any OneDriveHTTPTransport = OneDriveURLSessionTransport(),
    sessionVault: any OneDriveSessionVault,
    monitorNetwork: Bool = true
)

func configure(_ value: OneDriveClientSetup) throws
func signIn() async
func cancelSignIn()
func restore() async
func disconnect() async
func folders(parentID: String? = nil) async throws -> [OneDriveFolder]
func selectFolder(_ folder: OneDriveFolder?) async throws // nil = per-album root folder
func createFolder(name: String, parentID: String? = nil) async throws -> OneDriveFolder

@discardableResult
func enqueue(_ photos: [ReceivedJPEG], albumName: String) async throws -> Int
@discardableResult
func enqueueNew(_ photos: [ReceivedJPEG], albumName: String) async throws -> Int
func pump() async
func resume() async
func pause()
func cancel(jobID: String) async
func retryFailed(jobID: String? = nil)
func updateNetwork(available: Bool, wifi: Bool)

var jobs: [OneDriveJob] { get }
var receipts: [OneDriveReceipt] { get }
func receipt(photoID: String, accountID: String, driveID: String, folderID: String) -> OneDriveReceipt?
var verifiedCount: Int { get }
var pendingCount: Int { get }
var failedCount: Int { get }
var busy: Bool { get }
var settingsBusy: Bool { get }
var paused: Bool { get }
var account: OneDriveAccount? { get }
var selectedFolder: OneDriveFolder? { get }
var setup: OneDriveClientSetup { get }
var status: String { get }
var autoUpload: Bool { get set } // default false
var wifiOnly: Bool { get set }
var onVerified: (@MainActor (OneDriveReceipt) -> Void)?
var onJobChanged: (@MainActor (OneDriveJob) -> Void)?
```

`OneDriveReceipt` 包含 `jobID, photoID, accountID, driveID, folderID, remoteID, bytes, sha256, verifiedAt, method`。`OneDriveJob` 除同樣綁定欄位，另有 `setup, originalName, remoteName, albumName, localRelativePath, createdAt, offset, state, attempts, nextAttemptAt, error, verification`。state 為 `pending, uploading, retry, needsSignIn, failed, verified, cancelled`。`onJobChanged` 在 JSON 原子持久化成功後觸發；`onVerified` 只在遠端核對和耐久收據成功後觸發，並非登入、分享、排隊或 PUT 成功回呼。回呼是程序內通知而非 durable event bus；重啟後以 `receipts` 重建 UI／報告並按 jobID 去重。

父層最小接入示意，不是已修改共享來源：

```swift
// Keep one long-lived MainActor coordinator and one store. UIKit initializer above exists.
let oneDrive = OneDriveStore(coordinator: sharedOAuthCoordinator)
// Present:
OneDriveSettingsView(photos: currentSessionJPEGs, albumName: currentAlbumName)
    .environmentObject(oneDrive)
// On authorized foreground startup: await oneDrive.restore(); await oneDrive.pump()
// On user choosing to continue: await oneDrive.resume()
// On each NEW ingested photo, not every change of the full historical photos array:
_ = try await oneDrive.enqueueNew([newJPEG], albumName: currentAlbumName)
await oneDrive.pump()
// Explicit selected history import only after user confirmation:
_ = try await oneDrive.enqueue(selectedJPEGs, albumName: selectedAlbumName)
await oneDrive.resume()
// Restrictive global policy changes: oneDrive.pause() cancels the actual worker.
```

啟用 auto 不會自行追補歷史或解除明確 pause；首次登入預設 paused，設定畫面提供「繼續」。`enqueue` 不修改 `ReceivedJPEG.uploaded`，不將 PC receipt 當 OneDrive receipt。固定目的地或活動目的地在 enqueue 時鎖定；換帳戶、換資料夾、改活動名稱不改舊工作，不在初始化／登出時刪除原圖。所有原圖路徑只保存 Documents 相對路徑，重新啟動可適應 iOS container 變化；越界和 symlink 跳出來源樹會拒絕。

## 網路與有限重試

JSON 在本模組 Application Support 目錄原子寫入，排除備份並使用裝置檔案保護；token 在共用專用 Keychain，signed upload URL 在獨立續傳 Keychain，錯誤永不回顯服務 payload、URL query 或 NSError userInfo。存檔失敗會停工，不以空佇列覆蓋讀取失敗的既有佇列。

HTTP 408／429／5xx、網路中斷和過期 session 使用有限指數退避，每個 job 最多五次失敗；數字 `Retry-After` 會作等待下限，上限一小時。401／invalid_grant／缺憑證轉需要登入，不盲重試；quota、403、完整性錯誤保留失敗狀態。使用者明確重試才重置 attempts。Network.framework 監測恢復、前景 `pump()` 及手動繼續可恢復工作，不建立背景 daemon 或宣稱 iOS 背景 USB。

父層的 `CamLinkNetworkPolicy` 已套入 `OneDriveURLSessionTransport.init` 的 session configuration、`send` 的每一次最終 outgoing request，以及 `download` 的 signed readback request。這涵蓋 Graph profile／folder／create-session、續傳 GET、PUT 和完整讀回；每次要求重新讀取 UserDefaults 的全域 expensive／constrained flags，而 `allowsCellular` 來自本 provider 的 `wifiOnly`。父層仍須用其 feedback 路徑 gate 控制此目的地可用性，並在嚴格政策變更時呼叫 `pause()` 取消進行中 worker，不能只 gate 一次。共用 OAuthSupport 的 token endpoint HTTP 是父層擁有的來源，本模組沒有改它；若全域政策也必須涵蓋 token refresh，請父層在該共用 transport 套相同 helper。透過注入 session 的測試或其他可信呼叫端自行負責 session credential/cookie 隔離，正式預設是 ephemeral 無 cookie、cache、credential storage。

## 可執行的真實 Mac 測試與尚未驗收事項

`ios/OneDriveTests.swift` 是獨立 async executable，不進 app source。它使用 actor 注入 HTTP、memory vault 和實際注入 `URLSession/URLProtocol`；只有 test-owned temporary files，沒有外部帳戶、瀏覽器或遠端寫入。涵蓋 >4 MiB aligned PUT 和完整尾隨位元組、`nextExpectedRanges`、resume／416 probe、signed URL 無 Bearer、fail-conflict、整檔 SHA-1／SHA-256、quickXor 必須 GET、遠端 eTag 變更、錯 parent／hash 拒絕、503 Retry-After、checkpoint 失敗不得送第一段、排隊去重、PC uploaded 不能略過 OneDrive、持久收據／回呼、程序重啟、登出保留原圖、真正 URLSession redirect sink 拒絕和 deadline。

在 Mac 或父層授權的 Codemagic macOS runner，由 repo root 執行：

```bash
xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=minimal \
  -target "$(uname -m)-apple-macosx13.0" \
  ios/CamLink/Transfer/OAuthSupport.swift \
  ios/CamLink/Transfer/CamLinkNetworkPolicy.swift \
  ios/CamLink/Camera/ReceivedJPEG.swift \
  ios/CamLink/Transfer/OneDriveStore.swift ios/OneDriveTests.swift \
  -o /tmp/onedrive-tests
/tmp/onedrive-tests
```

`CamLinkNetworkPolicy.swift` 本身只依賴 Foundation，其 JSON decoder 使用 flags subset，因此這個獨立測試指令不需要整個 feedback UI；父層如希望一起編譯 `Preferences/DeliveryFeedback.swift` 亦可。UIKit view 和真正原生登入須由完整 iOS target 編譯，不能由純 macOS executable 假裝驗過。

**目前阻礙／未驗收：**此 Linux sandbox 沒有 Swift compiler 或 Apple SDK，只完成三份 Swift 檔的 tree-sitter 語法檢查，沒有執行上述測試、Swift typecheck 或 iOS build，沒有觸發 CI。父層須執行真實 Mac 測試及 iOS16 signed build。尚須在授權真實個人及工作 Microsoft 帳戶驗證 consent／cancel／Keychain rotation／冷啟動還原／帳戶切換，實測大小圖、MPF、斷網恢復、429／quota／衝突和完整下載核對；本模組沒有憑證，未宣稱任何登入或遠端上傳成功。Microsoft 官方建議 MSAL；本指定共用 native OAuth 流程未實作 broker／Intune，企業 Conditional Access 若要求 broker 可能阻擋。[1] 若真實 Microsoft 內容服務回傳新的合法 CDN hostname，現有 allowlist 會 fail closed，必須核實官方主機後才明確擴充，不可無條件允許任意 HTTPS。

## References

[1]: https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow "Microsoft authorization code with PKCE and offline access"
[2]: https://learn.microsoft.com/en-us/entra/msal/objc/redirect-uris-ios "Microsoft iOS app-specific redirect registration"
[3]: https://learn.microsoft.com/en-us/graph/api/driveitem-createuploadsession?view=graph-rest-1.0 "Graph resumable upload sessions and no-bearer upload URLs"
[4]: https://learn.microsoft.com/en-us/graph/api/resources/hashes?view=graph-rest-1.0 "Graph cryptographic hash availability and quickXor limitations"
[5]: https://learn.microsoft.com/en-us/graph/api/driveitem-get-content?view=graph-rest-1.0 "Graph preauthenticated download URLs"
