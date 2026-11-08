# 雙電腦獨立交付：父層接線與驗收

本模組僅修改 `Transfer/PairStore.swift`、`Transfer/PcClient.swift`，新增 `Transfer/MultiPCDeliveryStore.swift`、`Transfer/PCSettingsView.swift`、`ios/MultiPCTests.swift` 及本責任報告。未改 RootView、CamLinkApp、相機／USB／PTP／JPEG／MPF、Info.plist、project.yml 或 codemagic.yaml，未操作 Git、瀏覽器、真實帳戶或 CI。既有 build41 五張 JPG／零失敗及 PC 成功是使用者已確認的基線，不是本次重新實測結果。

## 已實作的界線

`PairStore` 保留原 `pair`、`draftHost`、`draftCode`、`applyQR(_:)`、`probeAndConfirm()`、`confirmFingerprint()`、`clear()` 合約。**`pair` 永遠代表 primary，不隨設定中的 selectedSlot 改變**，因此未換父層 UI 前原單電腦流程仍可編譯。第一部 Keychain service 保持原 bundle identifier，account 保持 `computer-pair-code`，第二部只用 `computer-pair-code-secondary`。不刪除／改名既有主電腦 Keychain 紀錄。舊 `pc.code` 明文只在成功寫入 Keychain，或已存在可讀的主電腦 Keychain 憑證後才移除；失敗保留原值並提示。Keychain 暫時不可讀時保留 host／fingerprint metadata，不因空密碼覆寫原配對身份。無法解碼的雙電腦設定保留原 bytes，拒絕清除或覆寫憑證。

兩槽各有名稱、穩定 revision、自動傳「之後新圖」選項；第二槽預設關閉。QR 可指定目標槽，但只填地址和配對碼，**不自動信任指紋**。使用者明確核對後才以觀察的憑證 pin 認證並儲存配對。換到另一憑證或清除配對會改 revision；同憑證改 IP／配對碼不建立假新目的地。所有配對碼只在 Keychain／必要的記憶體草稿，不進 JSON jobs 或報告。

每項 `PCDeliveryJob` 綁定 slot＋fingerprint＋revision、photoID、sessionID、albumName、原圖 URL、固定 remoteName、大小及完整 SHA-256。舊工作的目的地永不以目前選取槽重寫。換配對、清配對後舊工作及收據保留，但不送到新身份。新配對的同一張照片即使 `ReceivedJPEG.uploaded == true` 也必須建立自己待傳工作；本工人不修改該舊 Bool。原圖不移動、不刪除、不重新壓縮，也不執行任何相機命令。

Production 工人先逐塊唯讀核對原圖整檔大小與 SHA（包含 MPF 尾端），再呼叫原 `PcClient.put`。不新增 JPEG 尾兩 bytes 驗證，不裁切 MPF。保留既有 `9443 /inbox/`、TLS 憑證 pin、Basic header、`If-None-Match: *`、原圖 PUT、拒絕重導向、HTTP **201＋相同 `X-CamLink-SHA256`** 的成功合約。沒有遠端覆寫、刪除、重新命名或廣泛寫入。所有 PC probe/auth/PUT request 及 session 已套用父層 `CamLinkNetworkPolicy.apply(... allowsCellular: false)`，昂貴／受限網絡遵守同一父層偏好。

成功收據持久保存實際使用的目的地、expected SHA／大小和接受時間；`.receiverSHA256` 只在 `PcClient.put` 成功回傳後建立。Receiver 的合約並沒有另傳回遠端 size，本機大小與 HTTP Content-Length 是送出前已核對的值；不把它描述為另一次 GET 大小核對。`sendMilliseconds` 是本次原圖預檢＋PUT＋接收器接受的實測總耗時，沒有虛構分開的遠端 verify 耗時。

佇列在 `Application Support/CamLink/PCDelivery/pc-delivery-v1.json` 原子保存；不包含 pair/password/token/account URL。iOS 檔案有 `completeUntilFirstUserAuthentication`。無法讀取的佇列保留原 bytes 並停止傳送，不自動以空佇列覆蓋。程序中斷的 uploading 恢復 waiting，不能預先標成功。503／部分網路錯誤有限五次嘗試，延遲 2／5／15／30 秒；失敗不阻擋另一部電腦。前景網路恢復可再 pump；有限重試計時器不是背景服務或無限輪詢。新的照片在一項傳送 await 期間仍可加入並由同一動態 drain 接續處理。

## 精確 app-module API

以下是同一 XcodeGen target 的 Swift internal／app-module 介面，不是獨立 framework 的 `public` library 宣告。實際照片型別是 **`ReceivedJPEG`**；目前 `ShootSession.Photo` 並非此模組定義的型別。父層如已有 `typealias Photo = ReceivedJPEG` 可直接使用，但本模組不修改 ShootSession。

```swift
@MainActor
let pc = MultiPCDeliveryStore(pair: pairStore)

// Explicit dependencies; no environmentObject required by this view.
PCSettingsView(pair: pairStore, delivery: pc,
    photos: album.photos, sessionID: album.id, albumName: album.displayName,
    remoteNames: [String: String]())
// Exact equivalent spelling provided in PCSettingsView.swift:
MultiPCSettingsView(pair: pairStore, delivery: pc,
    photos: album.photos, sessionID: album.id, albumName: album.displayName)
```

`PCSettingsView` 的完整 initializer 為：

```swift
init(pair: PairStore, delivery: MultiPCDeliveryStore,
     photos: [ReceivedJPEG] = [], sessionID: String = "",
     albumName: String = "", remoteNames: [String: String] = [:])
```

View 位於 `#if canImport(UIKit)`，直接使用既有 `PairQRScanner`；Foundation／Combine／CryptoKit／Security 的 Mac 測試不載入 UIKit。名稱別名不需要額外的 `MultiPCSettingsView.swift` 空檔案，XcodeGen 會自動拾取 `CamLink/Transfer/PCSettingsView.swift`。

其餘完整呼叫簽名：

```swift
@MainActor final class MultiPCDeliveryStore: ObservableObject {
    typealias Transfer = @Sendable (ComputerPair, PCTransferRequest) async throws -> Void
    init(pair: PairStore,
         directoryURL: URL = MultiPCDeliveryStore.defaultDirectory,
         transfer: @escaping Transfer = MultiPCDeliveryStore.receiverTransfer)
    var jobs: [PCDeliveryJob] { get }
    var running: Bool { get }
    var isPaused: Bool { get }
    var message: String { get }
    var allowsTransfer: ((PCSlotID) -> Bool)? { get set }
    var onJobUpdate: ((PCDeliveryJob) -> Void)? { get set }

    func observeNewPhotos(photos: [ReceivedJPEG], sessionID: String, albumName: String,
                          autoUploadEnabled: Bool = true,
                          remoteNames: [String: String] = [:])
    func enqueue(photos: [ReceivedJPEG], albumName: String)
    func enqueue(photos: [ReceivedJPEG], sessionID: String, albumName: String,
                 to slots: [PCSlotID], remoteNames: [String: String] = [:]) throws
    func pump() async
    func setPaused(_ paused: Bool)
    func setForegroundActive(_ active: Bool)
    func cancelCurrentTransfer()
    func retryFailed(slot: PCSlotID? = nil)
    func destinationIsCurrent(_ job: PCDeliveryJob) -> Bool
    func jobs(sessionID: String, slot: PCSlotID? = nil) -> [PCDeliveryJob]
    func verified(photoID: String, sessionID: String, destination: PCDestinationID) -> Bool
    func importLegacyPrimaryVerified(photos: [ReceivedJPEG], sessionID: String,
        albumName: String, identity: PCLegacyPrimaryIdentity,
        remoteNames: [String: String] = [:]) throws
}
```

`enqueue(photos:albumName:)` 是**明確手動加入**目前 opt-in 槽的便利 overload，以 albumName 作 stable sessionID。不要將它拿來對所有累積原圖自動呼叫。正式父層一律使用有 stable sessionID 的 overload；指定場次補傳由使用者選槽確認，與 autoSend 選項獨立。

自動流程應啟動時／新活動建立時先 baseline，再於每次 `session.ingest` 後呼叫：

```swift
let names = Dictionary(uniqueKeysWithValues: session.photos.map {
    ($0.id, session.remoteName(for: $0))
})
pc.observeNewPhotos(photos: session.photos, sessionID: session.sessionId,
    albumName: session.sessionDisplayName, autoUploadEnabled: session.autoUpload,
    remoteNames: names)
Task { await pc.pump() }
```

**首次 observation 只把既有原圖列為 baseline，不自動補傳。**後續只加入新 photoID／hash／size；關閉全局自動也要持續 observe（`autoUploadEnabled: false`），以免開啟時把舊圖當新圖。自動開始前一定要先 baseline；若第一張圖已到才第一次 observe，該張會被當既有圖，需要手動加入。瀏覽歷史時不要把歷史圖送進目前 capture 的 observe。`remoteNames` 可用 `session.remoteName(for:)` 保留歷史路徑；所有名稱仍必須通過 Receiver 的單一平面檔名 allowlist。若省略，安全舊名會原樣保留，非 ASCII／不安全場次名用確定性 hash 平面名稱。不同原圖同目的地同 remoteName 明確報衝突，絕不覆寫。

逐槽政策由父層統一提供，啟動每項工作前再查，不通過就保留 waiting／retry，不增加 attempts、不產生 failure，也不為被攔截的槽啟動重試計時器：

```swift
pc.allowsTransfer = { [weak feedback] slot in
    feedback?.allowsUploads(to: slot == .primary ? .computer : .secondComputer) ?? false
}
// 限制性政策改變時：
pc.cancelCurrentTransfer()
// App 進入背景／離開前景：
pc.setForegroundActive(false)
// 回前景或放寬政策後：
pc.setForegroundActive(true)
Task { await pc.pump() }
```

`cancelCurrentTransfer()` 取消目前 Task／計時器，不刪工作或原圖；若 PUT 尚未確認就回 waiting 並退回該次嘗試次數。若 Receiver 成功回覆與取消同時到達，會誠實保存該**舊目的地**已接受的收據，不能回滾已發生的遠端傳輸。清配對後後續舊工作不再啟動，從不改送新身份。

### 舊收據的保守遷移

`pair.legacyPrimaryIdentity` 只在由實際舊 `pc.host`／`pc.finger` 與可用憑證遷移時捕捉，保存原 primary fingerprint＋revision；不跟著之後配對走。對每個有可信 legacy uploaded 標記的歷史場次，可明確呼叫 `importLegacyPrimaryVerified(... identity:)`。必須同時吻合 `pair.legacyPrimaryIdentity`、目前 ready 的主槽 fingerprint／revision，且只接受 `photo.uploaded == true`，每場僅遷移一次。它建立 `.legacyPrimaryImported` 收據，UI 明示「舊標記遷移，非本次重新連線」。無法知道舊旗標實際目的地的 v2 無證據資料、第二部或更換後電腦，一律不能借用；選擇重新傳送才有新證據。

父層不可同時呼叫舊 `session.uploadPending(using:)` 與新 `pc.pump()` 傳同一批照片；UI 切換完成後只留新工人。保留舊 API 是為未接線的 RootView 相容，不是要雙工人並行。不要把第二槽成功寫回 `photo.uploaded` 來證明全目的地成功。

### 場次／匯出接點

`pc.$jobs` 可在啟動時及更新後讓父層依 `job.sessionID` 找場次；狀態 `.waiting/.uploading/.retry/.failed/.verified` 可直接對應場次同名狀態。`job.destination.key` 是非秘密的 `slot:revision:fingerprint`，可作 `SessionPhotoReceipt.destinationKey`，不能只用目前選取槽或單一 Bool。只有 `job.receipt != nil` 才有核對證據。`job.receipt.evidence == .legacyPrimaryImported` 必須仍在 UI／匯出說明保留歷史遷移含義；不能對它再發「本次核對完成」通知。`onJobUpdate` 只在單項 durable 傳送狀態轉換後呼叫；enqueue／legacy import 的整體更新請看 `$jobs`。彙總、回寫 archive 的錯誤不得再丟回 callback 造成重複 PC PUT。

## 真實 Mac 測試指令（尚未執行）

從 repository 根目錄，在真正 Mac／經父層授權的 macOS CI step 執行：

```bash
xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=minimal \
  -target "$(uname -m)-apple-macosx13.0" \
  ios/CamLink/Camera/ReceivedJPEG.swift \
  ios/CamLink/Transfer/CamLinkNetworkPolicy.swift \
  ios/CamLink/Transfer/PairStore.swift \
  ios/CamLink/Transfer/PcClient.swift \
  ios/CamLink/Transfer/MultiPCDeliveryStore.swift \
  ios/MultiPCTests.swift -o /tmp/camlink-multi-pc-tests
/tmp/camlink-multi-pc-tests
```

測試注入記憶體 CredentialStorage 和明確離線 Transport，不讀寫真實 Keychain，不連線、登入或寫真實 Receiver。只建立／清除本測試自己新建的 UUID temporary directory 與 UUID UserDefaults suite，不碰 App 原圖或既有偏好。覆蓋 legacy primary 保留／metadata 無密碼、Keychain 暫時不可用、QR 不授信、不同槽與 revision 隔離、uploaded 不借用、遠端名稱 allowlist／衝突、整檔 SHA（包含 EOI 後 bytes）、JSON roundtrip／破損檔保留、同時新到照片、清槽與 in-flight 收據身份、替換電腦不重定向舊工作、暫停、503 不阻塞第二部、五次限制、真正 2 秒延遲 retry、程序中斷恢復、逐槽政策攔截及取消保留。

本 Linux sandbox 未安裝 Swift／Apple SDK，**上述程式尚未經 swiftc 型別檢查、Mac 測試執行或 iOS app 編譯**。已執行 tree-sitter Swift grammar parser，PairStore／PcClient／工人／View／Tests 均無語法節點錯誤；此結果不等於編譯或測試通過。無 CI 觸發、無虛構真實 PC 成功結果。

## 驗收阻礙與下一步

1. 需要父層真正 Mac runner 執行上列測試和完整 iOS16 target 編譯；沒有 Mac 的使用者沿用既有 TestFlight/Codemagic 管道，不要求安裝本機 Xcode。
2. 需要有兩部可用 Receiver 的使用者在簽署 iPad 實測：保留原主槽、只加第二槽、兩個 SHA 收據、第二部離線時主部繼續、503、換證書／錯配對碼、取消、重啟後恢復、指定歷史場次只補傳指定 PC，以及網路政策限制。此工作沒有真實 PC 憑證，未執行任何上述遠端驗收。
3. 舊 `uploaded` 若沒有原主槽的可信目的地證據，只能顯示為 legacy/unscoped 或手動再傳；不能捏造第二部／新電腦核對。
4. 已確認的 USB／PTP／MPF 原圖接收沒有修改。黑色口袋模式是前景畫面；鎖屏、切 App、背景 USB 或無限背景傳送皆未承諾。
