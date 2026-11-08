# 接收通知、安全設定與診斷接線

本模組已保留並補完 `CamLink/Preferences/DeliveryFeedback.swift`，新增 `CamLink/Preferences/PreferencesView.swift` 與 `DeliveryFeedbackTests.swift`。畫面型別是 **`DeliveryPreferencesView`**，另有同型別 alias `PreferencesView`；依本次明確檔案權限，沒有另外建立 `DeliveryPreferencesView.swift`。父層續工協定曾用另一檔名及 `preferences.md`，本次唯一報告仍依指定保存於 `parity-work/notifications-settings.md`。作者：Manus AI。

沒有修改相機／PTP／MPF、RootView、App、plist、XcodeGen、CI 或其他代理檔案。沒有 Git 操作、瀏覽器操作、登入、通知權限要求、遠端帳戶測試或 CI 觸發。使用者確認的 build41 iPad 五張 JPG／零失敗與 PC 成功基線不受這些新增檔案改動。

## 已實作的行為

Android 對照是 `DeliveryNotify.java:25–30` 的第一張、接收完成與上傳問題；`MainActivity.java:90–101,159–164,192–194` 的補掃頻率、現場筆記、診斷及口袋模式；`ConsoleActivity.java:16–35` 的回前景續傳；`LightScreen.java` 的共同 UI；`UploadEngine.java:61–71` 的**核對後**才設為 DONE。Android MainActivity 會在建立畫面時要求通知權限，本 iOS 模組刻意不沿用此做法。上述 Android 檔案未提供可直接移植的聲音／震動／觸感獨立開關，這三個是本次使用者要求的 iOS 安全偏好，不冒稱原 Android 已有。

聲音、震動、觸感與本機通知均預設關閉。非秘密設定由命名空間 `hk.camlink.delivery-feedback.preferences.v1` 的 UserDefaults JSON 保存。觸感開啟時優先用 `UINotificationFeedbackGenerator`，不再重複震動；只有 iPhone 嘗試 `kSystemSoundID_Vibrate`。提示聲是自產 80ms PCM 檔案，交由公開 `AudioServicesCreateSystemSoundID` 播放，不使用未公開的數字系統聲音 ID，不接管 AVAudioSession。提示受裝置硬件、靜音與系統設定影響，iPad 不保證震動／觸感。

只有 `enableLocalNotificationsFromUserAction()` 能要求通知權限，且只有顯式使用者操作才應呼叫。畫面初次出現、偏好還原、網路復原或純設定寫入都不會要求權限。這符合 Apple 在有情境的使用者操作時要求授權及排通知前重讀授權狀態的建議。[1] 本模組不申請 provisional 授權，不安裝 UNUserNotificationCenter delegate，不要求 badge、remote push、critical alert 或背景工作權限。前景用 App 內 banner／可選實體提示，非前景只在實際已有事件且仍有權限時排本機通知。停用僅移除本模組已知 ID 的 pending 通知，不碰其他目的地／系統通知，不刪 delivered 通知。

接收提示僅代表完整原圖已在本機落盤；接收完成必須由父層確認真正乾淨停止且沒有未完成下載。HTTP 接受／排隊／登入／分享不會觸發「已核對」或成功 cue。目的地核對必須帶相符的 `DeliveryVerification`，證據與 provider 不相符時回傳 false 並記設定問題。Drive 的 MD5 與可選 SHA、OneDrive 只有大小與有 SHA 的級別明確區分，不以 PC 的 uploaded Bool 推論其他目的地。`DeliveryFeedback` 是回饋紀錄，**不是取代各目的地的耐久 queue／fingerprint／帳戶／資料夾／照片 receipt**，也不宣稱所有照片或所有目的地已完成。

非秘密事件最多 256 筆，以 App 自有 Application Support `CamLinkFeedback-v1/events.json` 原子保存。相同 provider、接收 run、reason 和 HTTP status 的連續錯誤會合併 occurrences，不合併不同 provider。重複錯誤 banner／通知 30 秒節流，實體 cue 2 秒節流，但不因節流漏記錯誤次數。只接受固定 enum、數字、日期及本地隨機 UUID；沒有可放 arbitrary Error、帳號、檔名、路徑、URL、權杖、signed URL、headers 或 server payload 的事件欄位。`FeedbackFailureReason.classify(_:)` 不讀 `localizedDescription` 或 NSError userInfo。自由筆記只經可選 binding 回傳父層，不進本模組 UserDefaults 或事件匯出。

## 精確可呼叫 API

這些型別是 CamLink 同一 app target 的 module-visible API，沒有獨立 framework 的 `public` ABI。XcodeGen 自動納入 `ios/CamLink`，獨立測試檔留在 `ios/` 外層，不應加入 App target。

```swift
@MainActor
final class DeliveryFeedback: DeliveryFeedbackObservable {
    init(defaults: UserDefaults = .standard,
         eventLogURL: URL? = DeliveryFeedback.defaultEventLogURL,
         monitorNetwork: Bool = true)

    private(set) var preferences: DeliveryPreferences
    private(set) var events: [DeliveryFeedbackEvent]
    private(set) var networkPath: FeedbackNetworkPath
    private(set) var banner: DeliveryFeedbackEvent?
    private(set) var notificationAuthorization: FeedbackNotificationAuthorization
    private(set) var notificationStatus: String
    private(set) var diagnosticStatus: String
    private(set) var storageStatus: StoragePreflight
    var onUploadPolicyChange: (() -> Void)?

    func updatePreferences(_ change: (inout DeliveryPreferences) -> Void)
    func setWiFiOnly(_ enabled: Bool, for provider: FeedbackProvider)
    func updateNetworkPath(_ path: FeedbackNetworkPath)
    func networkDecision(for provider: FeedbackProvider) -> UploadNetworkDecision
    func allowsUploads(to provider: FeedbackProvider) -> Bool
    func aboutRestrictedNetwork(for provider: FeedbackProvider) -> String
    func configureUploadSession(_ configuration: URLSessionConfiguration,
                                for provider: FeedbackProvider)
    func configureUploadRequest(_ request: inout URLRequest,
                                for provider: FeedbackProvider)

    func setForegroundActive(_ active: Bool)
    func dismissBanner()
    @discardableResult
    func checkStorage(at existingLocalDirectory: URL,
                      expectedIncomingBytes: Int64 = 0,
                      reserveBytes: Int64 = 536_870_912) -> StoragePreflight
    func firstReceived(sessionID: UUID)
    func receivingFinished(sessionID: UUID, verified: Int, failed: Int,
                           pending: Int, cleanStop: Bool)
    func uploadAccepted(by provider: FeedbackProvider, sessionID: UUID? = nil)
    @discardableResult
    func destinationVerified(_ provider: FeedbackProvider,
                             evidence: DeliveryVerification,
                             sessionID: UUID? = nil) -> Bool
    func recordFailure(provider: FeedbackProvider, reason: FeedbackFailureReason,
                       httpStatus: Int? = nil, sessionID: UUID? = nil)

    @discardableResult
    func enableLocalNotificationsFromUserAction() async -> Bool
    func disableLocalNotifications()
    func refreshNotificationAuthorization() async
    func diagnosticData() throws -> Data
    func diagnosticText() -> String
    func stopMonitoring()
}
```

`DeliveryPreferences` 的可變欄位是 `soundEnabled`、`vibrationEnabled`、`tactileEnabled`、`localNotificationsEnabled`、`wifiOnlyByDestination: [FeedbackProvider: Bool]`、`allowExpensiveNetworks`、`allowConstrainedNetworks` 及 `scanInterval: ReceiveScanInterval`。`wifiOnly(for:)` 在沒有 destination 設定時回傳 true。頻率 `.balanced/.lowInterference/.experimental` 對應 2／5／0.5 秒，`seconds(forCardImport: true)` 會保留卡內至少 2 秒。父層已表示會新增 `CameraCaptureService.scanIntervalSeconds` 並在開始時 snapshot；本模組未改相機 timer。

`FeedbackProvider` 有 `.receiver/.computer/.secondComputer/.googleDrive/.oneDrive/.webDAV/.sharing/.application`；`uploadDestinations` 只含兩部電腦、Drive、OneDrive、WebDAV。`FeedbackFailureReason` 可用 `.authentication/.permission/.network/.timeout/.quota/.rateLimited/.serverBusy/.verificationMismatch/.localStorage/.cameraReceive/.configuration/.cancelled/.unknown`；通知／log 自身另有 `.notificationPermission/.notificationScheduling/.diagnosticStorage`。

`DeliveryVerification` 證據為 `.receiverSHA256`、`.driveSizeMD5Parent`、`.driveSizeMD5ParentSHA256`、`.oneDriveSize`、`.oneDriveSizeSHA256`、`.webDAVSizeSHA256`。只有在真實 worker 完成對應檢查後呼叫，不能靠 UI 判斷或見 2xx 就填 evidence。

畫面 init 的確切型別如下，所有 callback 預設 nil，沒有 callback 的控制會停用而非假裝已生效：

```swift
@MainActor
struct DeliveryPreferencesView: View {
    init(feedback: DeliveryFeedback,
         captureActive: Bool = false,
         statusText: String = "",
         notes: Binding<String>? = nil,
         onScanIntervalChanged: ((ReceiveScanInterval) -> Void)? = nil,
         onRescan: (() -> Void)? = nil,
         onForceStop: (() -> Void)? = nil,
         onExportCameraDiagnostics: (() -> Void)? = nil,
         onStorageCheck: (() -> Void)? = nil)
}
typealias PreferencesView = DeliveryPreferencesView
```

`statusText` 只在畫面顯示，不進事件 log；父層仍不得把原始含秘密的 provider 錯誤傳來。`notes` 限制 512 個非控制 Unicode scalar，允許換行；這只是限制長度，不是秘密過濾器，所以本模組刻意不保存筆記。

## 父層最小接線

建立一個 app 生命週期長存的 `@MainActor DeliveryFeedback()`，由父層持有與觀察。只開設定畫面不會讓任何傳送器自動套用網路政策。

```swift
// RootView / App 的父層示例；本次未改這些檔案。
DeliveryPreferencesView(
    feedback: feedback,
    captureActive: camera.browsing,
    statusText: "目錄 \(camera.catalogCount) · 待接收 \(camera.queuedCount) · 失敗 \(camera.failedCount)",
    onScanIntervalChanged: { _ in /* 真正開始前讀取當時偏好，不改進行中 timer */ },
    onRescan: { camera.refreshContents() },
    onForceStop: { camera.stopBrowsing() },
    onExportCameraDiagnostics: { diagnosticURL = camera.diagnosticFile() },
    onStorageCheck: {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        _ = feedback.checkStorage(at: documents)
    })
```

父層要在**所有**相機 start 入口（含「＋連接」、新拍、卡內）先呼叫 `checkStorage(at:)`，使用既存本機 Documents 目錄，不建立／清空相機資料夾。`status.requiresAcknowledgement` 為 true 時顯示 `status.text` 並等待使用者確認；取消即不 start。512 MiB 是可調的保留空間政策，不是整場容量保證。讀值使用 Apple `volumeAvailableCapacityForImportantUsageKey`，沒有讀到時不可當作足夠。[2] 容量只在裝置當下畫面顯示，不保存或匯出。

父層實作其承諾的相機屬性後，在既有 start 前加 `camera.scanIntervalSeconds = feedback.preferences.scanInterval.seconds(forCardImport: camera.mode == .card)`；不需要本代理重寫 PTP。場次 ID 目前是 `ShootSession.sessionId: String`，不是 UUID，不要強行 `UUID(uuidString: session.sessionId)!`。父層為每次真實開始接收建立一個 `UUID` 作為 feedback run ID，並在該次 ingest／stop 回調保留它。這個 ID 不是帳戶、照片檔名或敏感識別資料。

```swift
// 放在父層現有 camera.onJPEG 的「完整已驗證原圖」路徑內，保留既有 ingest/queue 行為。
// activeReceiveRunID 是父層於該次真實開始接收保存的 UUID。
session.ingest(photo)
feedback.firstReceived(sessionID: activeReceiveRunID)

// 真正乾淨完成且沒有未完成下載時；不能只見 camera.browsing 變 false 就宣稱 cleanStop。
feedback.receivingFinished(sessionID: activeReceiveRunID,
    verified: camera.receivedCount, failed: camera.failedCount,
    pending: camera.queuedCount, cleanStop: didActuallyDrainAndClose)

// 斷線、強制中止或背景打斷則 cleanStop: false。
feedback.recordFailure(provider: .receiver, reason: .cameraReceive,
                       sessionID: activeReceiveRunID)
```

上述 `photo`、`activeReceiveRunID` 與 `didActuallyDrainAndClose` 是父層 callback 的參數／狀態，不是本模組憑空新增的相機屬性。不要在每次 SwiftUI render 重複安裝或覆蓋既有 `camera.onJPEG`，也不要把累積列表的首張或舊歷史當成本次第一張。若使用 `ShootSession.onEvent`，需保留原訂閱者並將真實 firstPhoto／receivingInterrupted 映射到父層 run ID；receivingCompleted 缺少 drain 原因，仍由父層判斷 cleanStop。對歷史同步不觸發接收提示。

網路 pathMonitor 只在 UIKit build 由 NWPathMonitor 實作；Foundation Mac 測試不啟動它。只有 known＋satisfied、Wi-Fi-only 所需的可確認 Wi-Fi 且未混有 cellular，及成本／低數據模式都符合時，`allowsUploads` 才是 true。未知、離線、VPN 只露出不明介面或 Wi-Fi/cellular 混合路徑均保守拒絕 Wi-Fi-only。**NWPathMonitor 描述系統可用路徑，不是某次 request 的實際介面證據，也不證明目的地可達。** 沒有強制特定介面、同時分綁相機 Wi-Fi／數據、Dual Wi-Fi 或背景傳送保證。

```swift
// 在每個目的地 worker/pump 及每次 chunk/probe/metadata/readback 前。
guard feedback.allowsUploads(to: .googleDrive) else {
    // 顯示 feedback.aboutRestrictedNetwork(for: .googleDrive)，保留 job 等候。
    return
}
let configuration = URLSessionConfiguration.ephemeral
feedback.configureUploadSession(configuration, for: .googleDrive)
// 由既有安全 HTTP transport 建立 session；不可為了網路設定丟掉防 redirect delegate。
feedback.configureUploadRequest(&request, for: .googleDrive)
// 現有 worker 才真正送 request；本模組沒有任何遠端傳送。

feedback.onUploadPolicyChange = {
    // 父層：若新政策不允許，安全 cancel/pause 未完成的 URLSession 工作，保留 job；
    // 若已恢復且使用者原本允許自動上傳，才喚醒既有耐久 queue。
}
```

每個 provider 必須用自己的 enum。`URLSessionConfiguration` 要在建立 session **之前**套用，之後改它不會修改已建立 session。每個實際 request 也需套用；政策收緊時要由 owner 暫停／替換既有 session/task，只在 RootView 開始 pump 前 gate 一次不足以限制後續 chunk。Google／OneDrive 目前也有自己的 wifiOnly 設定；父層必須協調成同一來源，或取兩層政策較嚴格者，不可讓畫面和 worker 彼此繞過。PC 仍需要原本同網路與有效 Receiver 憑證，不因關閉 Wi-Fi-only 就保證可經互聯網送到電腦。

```swift
// 真實已核對 worker 的結果 hook，不是登入成功 hook。
feedback.destinationVerified(.computer, evidence: .receiverSHA256)
feedback.destinationVerified(.secondComputer, evidence: .receiverSHA256)
feedback.destinationVerified(.googleDrive, evidence: .driveSizeMD5Parent)
// Drive 若實際又驗了 SHA-256 改用 .driveSizeMD5ParentSHA256。
feedback.destinationVerified(.oneDrive, evidence: .oneDriveSizeSHA256)
// OneDrive 只有大小時必須 .oneDriveSize，不能填雜湊級別。
feedback.destinationVerified(.webDAV, evidence: .webDAVSizeSHA256)

// 2xx、排隊、分享回調只能記 accepted，沒有成功 cue。
feedback.uploadAccepted(by: .sharing)
// per-provider allowlisted enum；不要傳 raw error、NSError.userInfo 或 response body。
feedback.recordFailure(provider: .oneDrive, reason: .authentication, httpStatus: 401)
```

上述是**分別安放在對應真實結果分支的示例**，不可一次呼叫所有 destinationVerified 假造結果。worker 自身要先保存正確帳戶／資料夾／照片 receipt；回饋 API 不代替 receipt。可將父層實際 session UUID 一併傳給每個 hook，但回饋 log 刻意不包含帳戶或目的地路徑。

RootView 依 `scenePhase == .active` 呼叫 `feedback.setForegroundActive(true/false)`；回前景可 `await feedback.refreshNotificationAuthorization()`，不要求權限。App scene 失去前景要由父層維持原有 idle timer 還原。本模組沒有口袋模式或 UIApplication idle timer 操作，保留現有黑色前景畫面。`stopMonitoring()` 僅在 owner 真正釋放時取消本模組 monitor 及 dispose 自有聲音，不刪照片或事件。

## 父層隱私 manifest 待辦

Apple 規定使用 required-reason API 的 App bundle 要在自己的隱私 manifest 描述理由，不能靠第三方 SDK 的 manifest 代替。[3] 本次只提供建議，沒有改 plist、xcprivacy、project.yml 或 XcodeGen resource 設定。

父層應在**實際打包的 `PrivacyInfo.xcprivacy`** 的 `NSPrivacyAccessedAPITypes` 合併以下項目，不是加到 Info.plist 的照片權限描述：

```xml
<dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>CA92.1</string></array>
</dict>
<dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>E174.1</string><string>85F4.1</string></array>
</dict>
```

`CA92.1` 建議對應 App 自用偏好，不讀其他 App domain 或 App Group。`E174.1` 建議對應寫入原圖前檢查空間並讓使用者看到警告／確認或取消開始；`85F4.1` 建議對應直接把可用空間顯示給使用者。不選第三方分析、廣告、指紋辨識或上傳容量的理由。這是本模組實際用途對應的宣告建議，父層須依最終整合及當時 Apple 接受理由再確認；本次 Apple 頂層理由文件可讀，但細項頁工具未能抽取，沒有冒稱完成 App Store 隱私稽核。容量沒有進診斷／匯出、權杖沒有進 UserDefaults。父層已自行加入的 Photos add usage description 與本模組通知／容量宣告無關。

## 真實驗證範圍與阻礙

已執行：三個 Swift 指定檔案的 tree-sitter Swift grammar parse，以及沒有相機 start、遠端 URLSession send、任意錯誤字串入 log、照片刪除和非顯式通知授權入口的靜態檢查。這些檢查通過，但**不是 Swift 編譯、型別檢查、Apple SDK build 或測試執行**。

已準備的 `DeliveryFeedbackTests.swift` 是 Foundation 獨立 executable，不需要 UIKit／AppKit UI。測試覆蓋每目的地 Wi-Fi-only 預設、未知／離線／混合／有線／流動／VPN 不明路徑、成本與低數據開關、URLSession request 政策、卡內補掃下限、容量缺值／邊界／溢位、證據 provider 隔離、OneDrive 大小級別、偏好還原、first dedupe、accepted 不等於 verified、真實檔案原子保存與還原、錯誤合併、256筆上限、損壞 log 篩除、無 raw error 內容及 WAV 格式。測試只用獨有 test UserDefaults suite 和獨有 temporary directory；teardown 只刪測試自身建立的命名空間，不碰 App、相機、照片或其他 provider 檔案。測試不呼叫通知要求、native cue、外部網路或 live provider。

本環境沒有 Swift executable／Apple SDK，**尚未執行任何 Swift 測試**。請父層在真實 Mac／已授權的 Codemagic macOS 驗證步驟，從 repository root 執行：

```bash
xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=minimal \
  -target "$(uname -m)-apple-macosx13.0" \
  ios/CamLink/Preferences/DeliveryFeedback.swift \
  ios/DeliveryFeedbackTests.swift -o /tmp/camlink-feedback-tests
/tmp/camlink-feedback-tests
```

`PreferencesView.swift` 的 SwiftUI／UIKit 需要在父層正常 iOS16 App target 編譯，不能用 macOS Foundation 測試代表 UI 編譯成功。沒有 Mac 的使用者仍走父層既有 `ios-testflight-internal`／TestFlight，不要求使用者本機裝 Xcode。仍需真實 Apple SDK 編譯、父層 hooks 實接、打包 privacy manifest、真機通知同意／拒絕／系統變更／專注模式、iPhone與iPad聲音觸感差異、Wi-Fi↔流動／hotspot／低數據切換與途中暫停、容量警告確認／取消驗收。本次沒有聲稱登入或遠端端到端上傳成功。

## References

[1]: https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications "Apple 通知情境授權與排程前讀取設定"
[2]: https://developer.apple.com/documentation/foundation/checking-volume-storage-capacity "Apple 本機 volume 可用容量 API"
[3]: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api "Apple required-reason API 隱私 manifest 要求"
