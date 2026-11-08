# 活動、照片紀錄與匯出

作者：Manus AI。2026-11-09 接續既有模型，完成指定範圍的歷史、場次網格、大圖及原圖／報表匯出。只修改 `CamLink/Session/ShootSession.swift`、`SessionArchive.swift`、`SessionExport.swift`、新增 `SessionHistoryView.swift`、`ios/SessionArchiveTests.swift` 與本文件。延續協定中的 `SessionViews.swift`／`session-history.md` 是工作項目名稱；實際交付依原指定權限使用 **`SessionHistoryView.swift`／`albums-history.md`**，沒有另外建立同名功能檔。

沒有修改 RootView、CamLinkApp、Info.plist、專案或 CI 設定，沒有 commit/push、瀏覽器、登入、CI 或遠端上傳操作。相機／USB／PTP／JPEG／MPF 核心與落盤原圖沒有修改。build 41 iPad 五張 JPG／零失敗及 PC 成功仍只是使用者確認基線，不是本次測試結果。

## 已實作的場次與相簿

`SessionArchiveStore` 將原本 `Application Support/CamLink/session.json` 遷移到同目錄 `sessions-v2.json`。舊 JSON 保留不動，保留舊 `sessionId`、全部原圖 URL、照片 ID、大小、整檔 SHA-256、接收時間、舊 PC uploaded 旗標與 autoUpload。整個新索引先編碼再用 Foundation `.atomic` 儲存；不先刪除舊檔。既有新索引損壞、舊索引損壞或版本不支援時，不會用空白新索引覆蓋它。這是檔案原子替換設計，沒有聲稱已做強制斷電／儲存裝置 fsync 壓力驗證。

每場有穩定 ID、活動名、開始／封存時間、使用者備註、封面、全部照片、診斷、實測階段時間及目的地回條。新活動只由明確呼叫建立，舊場封存但不搬移、刪除或重編碼任何原圖。歷史選取的 `selectedAlbumID` 與接收的 `currentSessionID` 完全獨立。即使正在看舊場，`ingest` 仍只加入目前接收活動。同 URL 重複回呼不重複加圖；不同 URL 即使同內容或上游 ID 相撞也保留，僅為相撞紀錄另生 ID。

歷史可搜尋活動名、日期、ID 與備註，按開始時間降序排列；時間相同用穩定 ID 排序。照片以 `createdAt` 降序再按 ID 排序，不把檔名當時間。`createdAt` 明確標示為接收時間，不冒充 EXIF 拍攝時間。場次名稱與備註可以修改，ID／原圖位置／舊 PC 遠端檔名不隨改名改變。

`SessionHistoryView` 有獨立 NavigationStack；`SessionAlbumView` 可放入父層既有 NavigationStack。介面包含歷史封面、網格、多選／全選、原圖單張／多張分享、Files 原圖複製、Photos add-only、新活動確認、名稱／備註編輯、封面設定、診斷及目的地彙總。`SessionPhotoViewer` 支援左右翻頁、前後按鈕、回到最新、雙指／雙點縮放、放大後拖移、照片回條與耗時明細。大圖預覽最多 4096px，僅目前頁及相鄰頁可解碼；網格使用 ImageIO 記憶體縮圖及有容量上限的 actor cache。預覽絕不回寫照片。

## 父層可直接呼叫的介面

以下型別與 initializer 是 **CamLink app module 可見的 internal API**，不是另建 framework 的 Swift `public` ABI。父層無須 EnvironmentObject 注入給新畫面，直接傳入既有 session 即可。沒有為了加 `public` 而把全 app 的 ReceivedJPEG、ShootSession 等型別擴大存取範圍。

```swift
@MainActor
SessionHistoryView(
    session: ShootSession,
    isCameraReceiving: @escaping () -> Bool,
    onDelivery: ((SessionAlbumRecord) -> Void)? = nil,
    onRetryDelivery: ((SessionAlbumRecord) -> Void)? = nil,
    summaries: ((SessionAlbumRecord) -> [SessionDeliverySummary])? = nil
)

@MainActor
SessionAlbumView(
    session: ShootSession,
    albumID: String,
    onDelivery: ((SessionAlbumRecord) -> Void)? = nil,
    onRetryDelivery: ((SessionAlbumRecord) -> Void)? = nil,
    summaries: ((SessionAlbumRecord) -> [SessionDeliverySummary])? = nil
)

@MainActor
SessionPhotoViewer(session: ShootSession, albumID: String, initialPhotoID: String)

SessionSystemExportRequest(urls: [URL], destination: .share /* or .files */)
SessionSystemExportSheet(request: SessionSystemExportRequest)
```

最小畫面整合，由父層自行加入 RootView 的 sheet／tab；本工作沒有更改父層：

```swift
.sheet(isPresented: $showSessionHistory) {
    SessionHistoryView(session: session, isCameraReceiving: {
        camera.browsing || camera.finishing || camera.sessionClosing || !camera.canStart
    })
}
```

`isCameraReceiving` 必須包含整段 browsing／closing lifecycle，不可只用「正在下載單張」判斷。建立按鈕會重查此 closure，模型也拒絕 `isReceiving` 或既有 PC upload 未完成時建立。父層若採用自己的新活動按鈕，一樣必須在相機已完全停止時傳入真實狀態。已落盤的雲端工作可由其原工作綁定繼續，不會因瀏覽歷史自動重排／轉送。

`onDelivery` 與 `onRetryDelivery` 只有使用者明確按「本場加入目的地…／只重試本場…」時才觸發，傳入被查看場次的完整快照。父層應先顯示目的地及照片數確認，再交給自身 worker；不能因新增設定、登入或切換歷史就把全部累積照片送往新目的地。傳輸以 `album.id` 綁定，不要以可改名的 displayName 當工作身分。

保留並補齊的模型相容介面：

```swift
typealias ShootSession.Photo = ReceivedJPEG // 實際宣告位於 ShootSession 內

// 既有 photos、autoUpload、sessionId、uploadMessage、uploading 保留。
// photos 一直指目前接收場次，從來不是歷史選取場次。
var userEventName: String                 // @Published，可直接綁定目前活動名稱
var sessionDisplayName: String { get }
var albumName: String { get }             // 相容別名，等於 sessionDisplayName
var albums: [SessionAlbumRecord] { get }
var selectedAlbumID: String? { get }
var currentAlbum: SessionAlbumRecord? { get }
var selectedAlbum: SessionAlbumRecord? { get }
var isReceiving: Bool { get }
var archiveMessage: String { get }

init(archiveDirectory: URL = SessionArchiveStore.defaultDirectory, now: Date = Date())
func ingest(_ photo: ReceivedJPEG)
func remoteName(for photo: ReceivedJPEG) -> String
func uploadPending(using pair: ComputerPair) async
func resumeUpload(using pair: ComputerPair) async // 委派 uploadPending，仍為舊主電腦流程
func markNeedsUploadAll()                       // 只重設目前場次舊 PC flag
func album(id: String) -> SessionAlbumRecord?
func albumID(for photo: ReceivedJPEG) -> String?
func history(matching query: String = "") -> [SessionAlbumRecord]
@discardableResult
func startNewActivity(eventName: String = "", isReceiving: Bool, at date: Date = Date()) throws -> String
func selectAlbum(id: String) throws
func selectCurrentAlbum() throws
func renameAlbum(id: String, eventName: String) throws
func setAlbumMetadata(eventName: String, operatorNotes: String, albumID: String) throws
func setOperatorNotes(_ notes: String, albumID: String) throws
func setCover(photoID: String?, albumID: String) throws
func setPCUploaded(_ uploaded: Bool, photoID: String, albumID: String) throws
```

`setAlbumMetadata` 在同一次原子儲存更新名稱與備註。`photos` 保持原可寫 API，但父層若誤指派部分陣列，模型會保留既有 URL，不把未包含照片視為刪除指示。沒有提供刪除相片或索引的 API。

## 目的地回條、真實耗時與通知 hooks

```swift
func recordReceipt(_ receipt: SessionPhotoReceipt, albumID: String) throws
func setDeliverySummaries(_ summaries: [SessionDeliverySummary], albumID: String) throws
func setPhotoTiming(_ timing: SessionPhotoTiming, photoID: String, albumID: String) throws
func recordDiagnostic(_ diagnostic: SessionDiagnostic, albumID: String)
func receivingDidStart(at date: Date = Date())
func receivingDidFinish(failedCount: Int, at date: Date = Date())
func receivingDidInterrupt(at date: Date = Date())
var onEvent: ((SessionEvent) -> Void)?
var latestEvent: SessionEvent? { get }
```

`SessionEvent` 精確 case：`.firstPhoto(albumID:photoID:)`、`.receivingCompleted(albumID:received:failed:)`、`.receivingInterrupted(albumID:)`、`.deliveryAttention(albumID:provider:count:)`、`.persistenceFailed`。父層可把這些交給真實前景 banner 或通知模組；本工作不自行要求通知權限。`receivingCompleted` 僅指本次接收，不代表所有目的地完成。

```swift
SessionPhotoReceipt(
    photoID: String,
    provider: SessionDeliveryProvider,
    destinationKey: String = "default",
    state: SessionDeliveryState,
    verification: SessionVerification = .none,
    updatedAt: Date = Date(),
    queueMilliseconds: Double? = nil,
    sendMilliseconds: Double? = nil,
    verifyMilliseconds: Double? = nil
)

SessionDeliverySummary(
    provider: SessionDeliveryProvider,
    destinationKey: String = "default",
    total: Int,
    verified: Int = 0,
    deliveredUnverified: Int = 0,
    waiting: Int = 0,
    failed: Int = 0,
    needsAuthentication: Int = 0,
    updatedAt: Date = Date(),
    verification: SessionVerification = .none
)

SessionPhotoTiming(queueMilliseconds: Double? = nil,
                   receiveMilliseconds: Double? = nil,
                   verifyMilliseconds: Double? = nil)
```

Provider case 是 `.computer`、`.googleDrive`、`.oneDrive`、`.webDAV`。State 是 `.notQueued`、`.waiting`、`.uploading`、`.retry`、`.needsAuthentication`、`.failed`、`.delivered`、`.verified`。目的地使用非秘密 local slot/job ID 或公開 fingerprint，限安全字元、最多 128 bytes；不接受帳戶 email、URL、query、token 或 credential。worker 原始錯誤／網路 payload 不進場次 JSON，診斷只有 allowlisted enum、時間、數量、photo ID。備註是使用者明確填寫的文字，畫面提醒不可填密碼或 token。

Verification 精確區別 `.none`、`.receiverSHA256`、`.driveIDSizeMD5Parent`、`.driveIDSizeMD5ParentSHA256`、`.oneDriveSizeOnly`、`.oneDriveSizeSHA256`、`.downloadedSizeSHA256`。例如 OneDrive 只回大小的結果不能標示 SHA 已核對。各 provider 的 verification allowlist 與數量範圍都會驗證；負數或已核對但 verification none 等外部資料會拒絕，不會默默補成成功。登入、分享或本機讀取成功均不生回條。

`uploadPending` 仍使用既有 PcClient 成功回覆語義；其量度記錄整次送圖連同 Receiver 回覆等待時間，不拆出未量度的驗證階段。照片接收細分階段仍待父層提供真實量度，沒有從 createdAt 估算。沒有資料一律顯示「—／NOT_MEASURED」。新雙電腦與雲端 worker 的獨立 queue/retry/receipt 聚合由父層接入，不能拿舊 uploaded Bool 當目前／第二部電腦已交付。

## 原圖與報表匯出 API

```swift
SessionExport.originalURLs(album: SessionAlbumRecord, selectedIDs: Set<String>? = nil) throws -> [URL]
SessionExport.report(album: SessionAlbumRecord, summaries: [SessionDeliverySummary]? = nil) throws -> SessionReportDocument
SessionExport.csv(album: SessionAlbumRecord, summaries: [SessionDeliverySummary]? = nil) throws -> String
SessionExport.text(album: SessionAlbumRecord, summaries: [SessionDeliverySummary]? = nil) throws -> String
SessionExport.data(album: SessionAlbumRecord, format: SessionExportFormat,
                   summaries: [SessionDeliverySummary]? = nil) throws -> Data
SessionExport.write(album: SessionAlbumRecord, format: SessionExportFormat,
                    summaries: [SessionDeliverySummary]? = nil,
                    directory: URL = FileManager.default.temporaryDirectory) throws -> URL
```

Format 是 `.csv`、`.json`、`.text`。報表包含全部照片名字、大小、整檔 SHA、可讀性、接收時間、舊 PC flag 與實際供應商回條。JSON／文字還有現場備註、診斷、量度及每目的地彙總。CSV 為固定 27 欄 RFC4180 quoting、CRLF，防試算表公式注入；photo 行包含逐圖回條，另以 `row_kind=summary` 行放外部 provider 彙總，不將彙總冒充逐圖回條。JSON 保留中文及原文字元，不用手動拼接 JSON。檔名只使用安全 ASCII，來自穩定場次 ID；每次輸出獨立新 temporary directory，避免覆寫其他匯出。

`originalURLs` 不做 JPEG conversion，不擷取前段、不裁掉尾段，直接回傳原檔 URL；選到不存在 ID 或有不可讀原圖時整次回報錯誤，不悄悄跳過。系統分享用 `UIActivityViewController(activityItems: [URL], applicationActivities: nil)`。[1] Files 用 `UIDocumentPickerViewController(forExporting: urls, asCopy: true)`，不移動來源。[2] Photos 用 add-only 權限及 `PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)`，且 `options.shouldMoveFile = false`，只新增，不修改／刪除已有資產。[3] [4]

Photos helper 是 UIKit／Photos 條件編譯的 `SessionPhotosExport.saveOriginals(_ urls: [URL]) async throws`。若簽署 plist 沒有 `NSPhotoLibraryAddUsageDescription`，會在請求 Photos 前明確阻擋；父層可決定是否配置。這不阻擋系統分享及 Files。Photos 完成僅代表 PhotoKit 新增操作成功，沒有 PhotoKit 讀回雜湊或 iCloud／Google Photos 雲端驗收，不標示雲端 verified。

**沒有實作 ZIP 原圖封裝。** 本次交付的是系統多選原圖分享／Files 複製與可攜 CSV／JSON／文字報表，不能宣稱 Android ZIP 已完全對齊。分享目標由已安裝 extensions 決定，不能保證 Dropbox／Box／Google Photos／Flickr 出現、批量支援或遠端核對。ImageIO 和 UIScrollView 只用於記憶體預覽與原生縮放，絕不拿預覽 UIImage 作匯出來源。[5] [6]

## 可執行 Mac 測試與完整依賴

Linux sandbox 沒有 `swift`、`swiftc` 或 Apple SDK，**沒有編譯、執行 Swift 測試或 iOS UI 測試**。已執行指定五個 Swift 檔的 tree-sitter grammar parse，沒有語法樹 ERROR；這不等於 Swift typecheck、SDK availability、linking 或真機通過。

Foundation-only suite 的完整來源依賴如下，沒有 UIKit／相機／網路／Keychain。需真正 macOS runner 執行，repo root：

```bash
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  -strict-concurrency=minimal -target "$(uname -m)-apple-macosx13.0" \
  ios/CamLink/Camera/ReceivedJPEG.swift \
  ios/CamLink/Session/SessionArchive.swift \
  ios/CamLink/Session/SessionExport.swift \
  ios/SessionArchiveTests.swift \
  -o /tmp/camlink-session-archive-tests
/tmp/camlink-session-archive-tests
```

`SessionArchive` 的驗證會呼叫 `SessionExport.validateReceipt/validateSummary`，因此不能漏掉 `SessionExport.swift`。macOS 沒有 UIKit，Photos 原生匯出區塊自然排除。測試使用私有新建 temporary directory 和合成 byte fixtures，只清理自己建立的測試目錄，不讀寫使用者照片。合成 payload 是測試「尾部 bytes 不會被索引／匯出更動」，不是有效 MPF 圖片或相機接收測試。

若要同時測試 MainActor `ShootSession`，開啟 `SESSION_MODEL_TESTS`，使用 **真實** PairStore/PcClient 定義作編譯依賴，不替它們寫假 uploader：

```bash
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  -strict-concurrency=minimal -D SESSION_MODEL_TESTS \
  -target "$(uname -m)-apple-macosx13.0" \
  ios/CamLink/Camera/ReceivedJPEG.swift \
  ios/CamLink/Session/SessionArchive.swift \
  ios/CamLink/Session/SessionExport.swift \
  ios/CamLink/Session/ShootSession.swift \
  ios/CamLink/Transfer/PairStore.swift \
  ios/CamLink/Transfer/PcClient.swift \
  ios/SessionArchiveTests.swift \
  -o /tmp/camlink-session-model-tests
/tmp/camlink-session-model-tests
```

延伸組會連結 Apple Combine、Security、CryptoKit 等實際模組。測試不初始化 PairStore、不叫 probe/authenticate/uploadPending/resumeUpload，因而不讀 Keychain、不連 PC。若另一代理的實際 PairStore/PcClient 尚有 SDK 編譯問題，Foundation 組仍可獨立執行，不能把延伸組失敗藏成相簿測試通過。

已準備的斷言包含舊 JSON 遷移與保留、重載優先序、封存／選取不影響接收、同秒活動 ID、URL/ID 去重邊界、損壞／未來版本拒絕覆寫、寫入錯誤、字元安全、日期／檔名排序、CSV 矩形與公式防護、JSON 中文回復、缺失檔案、輸出不覆寫、真實回條層級、負數／不合法彙總、模型公開 API 及接收通知事件。只有 runner 實際成功輸出 PASS 才可報測試通過。

尚需父層在真正 iOS SDK build 驗證 SwiftUI／UIKit／PhotoKit；有授權時沿用現有 Codemagic `ios-testflight-internal` 流程，使用者不必另裝本地 Xcode。真機需驗收新活動 guard、接收同時看舊場不串場、App 終止重開後照片索引、長場次記憶體、iPad 分享／Files popover、多張原圖分享、Photos 拒絕權限、雙指縮放與翻頁手勢競合，以及匯出後在接收端讀回整檔大小／SHA。Photos 或其他 App 若另有影像處理行為，不可僅憑成功 sheet 宣稱原始 MPF bytes 已在遠端核對。

## Android 對照與限制

已閱讀本 repo 的 ShootPanel、SessionAlbum、SessionNames、SessionReport、SessionExport、ShootDetail、Gallery、ReviewPhoto、PhotoTimes、EventFolder。這次對齊的是場次命名／歷史搜尋、網格／大圖檢視、回最新、目的地紀錄、原圖多選及交付清單。Android `EventFolder` 的遠端資料夾建立屬各雲端 worker，這份本機相簿模型不會創建或改寫任何遠端資料夾；用穩定 album ID 供父層綁定。Android Gallery 可能校驗後刪 staged 副本，iOS 這次刻意沒有移植刪來源行為。相機 EXIF 拍攝時間、完整 Android 原始 camera log 欄位及 ZIP 不能冒充已實作。

本工作不提供背景／鎖屏 USB 保證，也不更動 Wi-Fi／通知權限、相機收圖頻率、補收或雲端登入。相關 parent hooks 需要父層真實接入，沒有 remote account live test 或登入即算成功的結果。

## References

[1]: https://developer.apple.com/documentation/uikit/uiactivityviewcontroller "Apple UIActivityViewController"
[2]: https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init%28forexporting:ascopy:%29 "Apple document picker export asCopy initializer"
[3]: https://developer.apple.com/documentation/photos/phassetcreationrequest/addresource%28with:fileurl:options:%29 "Apple PhotoKit file URL resource creation"
[4]: https://developer.apple.com/documentation/photos/phassetresourcecreationoptions/shouldmovefile "Apple PhotoKit shouldMoveFile copy semantics"
[5]: https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex%28_:_:_:%29 "Apple ImageIO thumbnail creation"
[6]: https://developer.apple.com/documentation/uikit/uiscrollviewdelegate/viewforzooming%28in:%29 "Apple UIScrollView zoom view delegate"
