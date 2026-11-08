# iOS 對等模組：父層整合交付摘要

> 2026-11-09；僅彙整既有模組結果、`inventory.md` 與本機來源，未重新研究、修改程式碼、登入、傳送、操作 Git 或觸發 CI。本次唯一寫入為本文件。父層檔案仍在整合中，下述現況是本次讀取快照，不是驗收結論。

## 1. 交付與證據界線

五組模組已交付，沒有模組回報執行失敗：Google Drive、OneDrive、雙 PC、活動／歷史／匯出、通知／偏好；共用 OAuth foundation 亦已存在。詳細契約分別見 [google-drive.md](google-drive.md)、[onedrive.md](onedrive.md)、[multi-pc.md](multi-pc.md)、[albums-history.md](albums-history.md)、[notifications-settings.md](notifications-settings.md)、[oauth-foundation.md](oauth-foundation.md)。原始差距依據為 [inventory.md](inventory.md)；其中「Google／Microsoft 尚未註冊」等舊現況已由父層設定取代，不能原封不動當作現在阻礙。

**已知成功只有使用者確認的 build41：真實 iPad 收到 5 JPG、0 failed，PC 成功。**本批模組僅回報 grammar／靜態檢查，Linux 沒有 Swift／Apple SDK，尚無 Swift 編譯、Mac tests、iOS16 SDK／GoogleSignIn 10.1.0 編譯或本批真機結果。沒有本批 Google／Microsoft 授權、遠端 HTTP 上傳、WebDAV 或雙 PC 實測證據。現有 `project.yml` 為 build42，不代表 build42 已成功。

原圖與 MPF 必須保留全部 bytes；禁止重壓、截在第一個 JPEG EOI、刪卡、拍攝／屬性寫入、vendor-specific camera-write。不得為補雲端重寫已驗證 USB／PTP／MPF 核心。口袋模式是黑色前景畫面，不能承諾鎖屏／背景／切 App 後 USB。登入、設定保存、HTTP 接受、分享成功、本機已收及逐目的地核對是不同狀態。

## 2. RootView／CamLinkApp 的精確接線

所有 store／畫面以同一 app module、`@MainActor` 長生命週期持有。**不要另建第二套 owner。**目前 `CamLinkApp` 已持有 `@StateObject CamLinkRuntime()`，並注入 runtime、camera、session、pair、pc、webDAV、google、oneDrive、feedback；`RootView` 已有目的地 sheets、紀錄／更多導航、Google callback 分流及容量確認。這些父層接線已落檔，但未編譯，仍須依以下契約修整。

### Owner 與畫面入口

```swift
let oauth = OAuthCoordinator() // 同一實例供兩個 provider 使用
let google = GoogleDriveStore(coordinator: oauth)
let oneDrive = OneDriveStore(coordinator: oauth)
let pc = MultiPCDeliveryStore(pair: pair)
let feedback = DeliveryFeedback()

GoogleDriveSettingsView(photos: selectedAlbum.photos,
    albumName: { selectedAlbum.displayName }).environmentObject(google)
OneDriveSettingsView(photos: selectedAlbum.photos,
    albumName: selectedAlbum.displayName).environmentObject(oneDrive)
PCSettingsView(pair: pair, delivery: pc, photos: selectedAlbum.photos,
    sessionID: selectedAlbum.id, albumName: selectedAlbum.displayName,
    remoteNames: remoteNames)
WebDAVSettingsView(photos: selectedAlbum.photos).environmentObject(webDAV)
SessionHistoryView(session: session, isCameraReceiving: {
    camera.browsing || camera.finishing || camera.sessionClosing || !camera.canStart
}, onDelivery: confirmAlbumDestinations, onRetryDelivery: confirmAlbumRetry)
```

此處 `selectedAlbum`、`remoteNames`、確認 closures 由父層提供；歷史按鈕必須先確認場次、目的地與張數，不能以看歷史／登入／更改設定自動補傳。`SessionHistoryView` 自帶 NavigationStack；既有 stack 可使用 `SessionAlbumView(session:albumID:onDelivery:onRetryDelivery:summaries:)`。連續大圖為 `SessionPhotoViewer(session:albumID:initialPhotoID:)`，不是舊單張 `PhotoViewer`。

### 啟動、前景與 callback

- 啟動／授權允許的前景恢復：`await google.restoreSignIn()`、`await oneDrive.restore()`；再按政策與使用者 pause 狀態 `await google.pump()`、`await oneDrive.pump()`、`await pc.pump()`、`await webDAV.uploadPending()`。`pump` 不應偷偷解除使用者暫停。
- Google：`.onOpenURL` 中只有 `google.handleCallback(url) == true` 才吞 URL；其餘保留 `camlink` → `pair.applyQR(url.absoluteString)` 配對。Microsoft callback 由共用 `ASWebAuthenticationSession` 接收，不寫泛用 scheme-only OAuth parser。
- `scenePhase` → `feedback.setForegroundActive(_:)`、`pc.setForegroundActive(_:)`；回前景 `await feedback.refreshNotificationAuthorization()`，不得自動要求通知權限。維持原 idle timer 的 inactive 還原。
- **共用 coordinator 不等於兩套登入互斥。**Google SDK 自開 sheet 不受 OAuthCoordinator 私有 global slot 控制；父層仍須實作 Google 與 Microsoft 共用互動 gate，含程式觸發、恢復及設定畫面入口。

### 新圖、自動傳送與手動補傳

既有完整驗證路徑保留 `session.ingest(photo)`；使用 ingest 後實際留下的 photo identity，只排本次真正新圖，不得在全量 `photos.onChange` 對所有歷史補傳。

| 目的地 | 精確 API／規則 |
|---|---|
| Google | `if google.autoUpload { await google.enqueue(newJPEGs, albumName: session.albumName) }`。`enqueue` 可自行 start；手動同 API 但必須已確認範圍。`pause()` 取消 worker；`resumePending()` 解除持久暫停；`retryFailed()` 只重排當前帳戶，另明確開始；`cancelJob(_ id: String)`。 |
| OneDrive | 自動 `_ = try await oneDrive.enqueueNew(newJPEGs, albumName: session.albumName)`；明確補傳 `_ = try await oneDrive.enqueue(selectedJPEGs, albumName: selectedName)`。`await pump()` 不解除 pause；明確繼續 `await resume()`；`pause()`、`retryFailed(jobID: String? = nil)`、`await cancel(jobID:)`。 |
| PC×2 | 啟動／新活動、第一張到達前先 `observeNewPhotos(photos:session.photos, sessionID:session.sessionId, albumName:session.albumName, autoUploadEnabled:session.autoUpload, remoteNames:names)` 建 baseline；每次 ingest 後繼續 observe。auto 關閉仍 observe false，避免重開 auto 補送舊圖。明確補傳：`try pc.enqueue(photos:selectedJPEGs, sessionID:album.id, albumName:album.displayName, to:slots, remoteNames:names)`，再 `await pc.pump()`。 |
| WebDAV | `if webDAV.autoUpload { webDAV.enqueue(newJPEGs) }`，再按政策 `await webDAV.uploadPending()`。明確補傳可在 auto 關閉時 enqueue；`retryFailed()` 目前限當前配置。**沒有公開 `pause()` API**；需保留 owner Task 並安全取消或由父層補契約，不可猜呼叫不存在的方法。 |

`names` 可由 `session.remoteName(for:)` 建立。PC 的 `enqueue(photos:albumName:)` 只是手動便利 overload，不作正式自動掃描。**停止並行呼叫舊 `session.uploadPending(using:)`／`resumeUpload(using:)` 與新 pc worker。**`PairStore.pair` 永遠是 primary；`selectedPair` 才是設定選中槽。可信舊回條僅能以 `pair.legacyPrimaryIdentity` → `importLegacyPrimaryVerified(photos:sessionID:albumName:identity:remoteNames:)` 保守遷移；無原目的地證據的 uploaded 不可借給第二部或新電腦。

### 場次、收據、偏好

- `ShootSession.Photo == ReceivedJPEG`；`photos` 永遠指目前接收場，不隨歷史選取切換。`startNewActivity(eventName:isReceiving:at:) throws -> String` 明確開新活動，`selectAlbum(id:)` 只選歷史；開始／建立活動 guard 必含 browsing、finishing、closing、canStart。
- worker → `session.recordReceipt(_:albumID:)`、`setDeliverySummaries(_:albumID:)`、`setPhotoTiming(_:photoID:albumID:)`；以 stable album ID 及逐目的地非秘密 identity 綁定，不用可改名 displayName 或 PC Bool。PC 看 `$jobs`／`onJobUpdate`，Google 看 `jobs`，OneDrive 看 `jobs`／`receipts`／`onVerified`／`onJobChanged`，WebDAV 看 `jobs`。只有真正遠端核對且 durable receipt 成功才回饋成功；重啟重建不重播成功通知，legacy imported 不發本次核對提示。
- Google 必須 `.verified` 且有 `verifiedAt`；區分 ID／size／parent／MD5、額外 SHA-256、完整 GET SHA-256。OneDrive `method=server SHA-1` 不得改稱 SHA-256；其 receipt 的 `sha256` 只是本機原圖識別。現有場次／feedback schema 沒有 SHA-1 級別，父層須保留精確 method 或擴 schema，不能偽造更高核對層級。PC 僅 201＋Receiver SHA；WebDAV 為完整 GET 大小＋SHA。
- `SessionExport.originalURLs(album:selectedIDs:)` 回傳原圖；`SessionExport.write(album:format:summaries:directory:)` 支援 `.csv/.json/.text`。Photos add-only 成功不是雲端核對。
- `DeliveryPreferencesView(feedback:captureActive:statusText:notes:onScanIntervalChanged:onRescan:onForceStop:onExportCameraDiagnostics:onStorageCheck:)`；各 callback 可選，未接即停用。`notes` 回存場次，不進 feedback log。
- 所有 start 入口先 `feedback.checkStorage(at: existingDocuments)`，`requiresAcknowledgement` 必須確認／可取消；開始前 snapshot `camera.scanIntervalSeconds = feedback.preferences.scanInterval.seconds(forCardImport: mode == .card)`。
- 每次真正接收另存 run `UUID`，不能強轉 `session.sessionId: String`。開始／乾淨完成／打斷分別 `session.receivingDidStart()`／`receivingDidFinish(failedCount:)`／`receivingDidInterrupt()`；feedback 用 `firstReceived(sessionID:)`、`receivingFinished(sessionID:verified:failed:pending:cleanStop:)`。**browsing=false 或使用者按完成，不足以單獨證明 drain＋close 完成。**

### 網路政策：必須補到真正 transport

`CamLinkNetworkPolicy.apply(to: URLSessionConfiguration, allowsCellular: Bool)` 及 `apply(to: inout URLRequest, allowsCellular: Bool)` 已存在。PC、OneDrive 已引用，但仍需父層逐目的地 gate 與進行中取消；NWPathMonitor 不證明 request 實際介面或目的地可達。

1. 設 `pc.allowsTransfer = { slot in feedback.allowsUploads(to: slot == .primary ? .computer : .secondComputer) }`；政策收緊 `pc.cancelCurrentTransfer()`，放寬／回前景再 pump。現有 Runtime 尚未設此 closure，不能只看兩槽任一可傳就開整個 pump。
2. Google 尚未套 helper：`GoogleDriveHTTP.init(session:)` 的 config、`raw` 的 outgoing request（涵蓋 profile／folder／metadata／begin／probe／chunk）、`downloadedHash` 的 readback request 都要套；收緊須取消／pause。只在 Runtime pump 前 gate 不夠。
3. WebDAV session、PUT／GET 與進行中工作同樣待接；共用 `OAuthHTTPClient` token／refresh transport 亦未套全域政策。Google SDK 內部登入／refresh 不受 REST helper 控制，需在互動入口說明並 gate，不宣稱完全可控。
4. provider 自有 wifiOnly 與 feedback 必須同源或取較嚴格者；政策恢復不能覆蓋使用者自己的 pause。不得丟掉既有拒絕 redirect、TLS／host 限制或憑證隔離。

## 3. OAuth portal／signed App 設定

**兩個真正 iOS client 已有；不是仍缺 ID，也不需重建註冊。**權威公開值見 `ios/OAuthClients.json`；執行時 `OAuthAppConfiguration.settings` 讀 compiled Info.plist，不是直接讀該 JSON。

| 項目 | Google Drive | Microsoft OneDrive |
|---|---|---|
| 公開 client ID | `518900347391-4fh5i9n3q2jpgh70aujo6ofs1i715dqu.apps.googleusercontent.com` | `16437f88-79e4-499f-8cb3-7f07c9146e0c` |
| iOS 註冊 | 專案 `work-camera-512615`，iOS client `Cam Link iOS Drive`，bundle `hk.camlink.ios` | `Cam Link iOS`，native iOS/macOS bundle `hk.camlink.ios`；tenant 記錄 `0051d77d-2447-4003-8059-01970cdfbed6` |
| 精確 callback | `com.googleusercontent.apps.518900347391-4fh5i9n3q2jpgh70aujo6ofs1i715dqu:/oauth2callback` | `msauth.hk.camlink.ios://auth` |
| 編入 URL scheme | `com.googleusercontent.apps.518900347391-4fh5i9n3q2jpgh70aujo6ofs1i715dqu` | `msauth.hk.camlink.ios` |
| scope／authority | `https://www.googleapis.com/auth/drive.file`；官方 GoogleSignIn SPM **exact 10.1.0**，SDK 單獨管理 refresh/cache | authority `common` v2；`openid profile offline_access User.Read Files.ReadWrite`；code＋PKCE/state、Keychain refresh rotation |
| portal 仍需確認／驗收 | Drive API 已啟用；Google consent audience／測試使用者、帳戶政策、signed iPad callback／cancel／restore／refresh／原圖傳送 | 父層已確認 native callback 儲存；維持 `AzureADandPersonalMicrosoftAccount`、public-client 設定及 delegated consent／tenant policy；個人＋工作帳戶實測 |

Info.plist 已有兩個 scheme、兩個 ID、Microsoft redirect 與 `NSPhotoLibraryAddUsageDescription`，且保留 `camlink` 配對。修改 runtime callback 文字不能新增 signed scheme。不要用 Android SHA／client、`work-camera://onedrive` 或 `camlink://onedrive/callback` 替代，不放 client secret、token 或 signed upload URL 到 plist／JSON／log。

Microsoft `common` 的 authorize／token 為 `https://login.microsoftonline.com/common/oauth2/v2.0/authorize` 與 `/token`；不能把記錄中的 tenant UUID 不加說明變成限制工作帳戶的預設 authority。此實作是 ASWebAuthenticationSession，不含 MSAL broker／Intune；要求 broker 的企業 Conditional Access 可能擋登入。OneDrive 僅預設 drive，不承諾所有 SharePoint/shared sites；新合法 CDN 不在 allowlist 時安全失敗，需核實才擴充。Google drive.file 不能看全部既有 folder；其他項目需另接 Picker，不暗增 full Drive scope。

## 4. Android inventory 全覆蓋：交付了甚麼，父層仍缺甚麼

以下 ID 對應 `inventory.md` 全部項目。「模組有」僅表示來源與介面已交付，不表示 UI／整合／實測已完成。

| 盤點 ID | 已交付／保留 | 父層仍須完成或明確保留的差異 |
|---|---|---|
| G01–G10、G13 | 真 SDK／profile、folder 選建、活動 folder、新圖 opt-in、resumable、核對、耐久帳戶隔離、pause／retry／明確補傳 | 共用互動鎖、完整 transport policy、signed callback／refresh／HTTP 實驗；G04 活動空名是否略過須明確，現 Google 空名用已選 folder，不是假裝完全相同。 |
| G11 | 舊工作不轉新目標，安全保留 | **缺資料夾刪除修復 UX／API**：同帳戶選建替代→確認只重派未完成→清過期 session→續傳；不能僅換設定期待舊工作自動修復。 |
| G12、G14 | 計數／近況／byte offset、實測 send／verify 時間欄位、結果 JSON、本機登出與公開設定說明 | 本場精確進度／速率與 queue 耗時、錯誤修復導向、實際 folder／photo 深連結及授權管理入口仍需補整；不要用帳戶累計充作本場。 |
| O01–O08、O10–O11 | 原生 PKCE／Graph identity／預設 drive、分頁 folder、活動 folder、獨立 queue、320 KiB 對齊續傳、hash 或 GET、pause／retry／補傳／登出 | UI／政策／帳戶切換整合與個人＋工作帳戶驗收；O03 空活動名與本場目的地生效時點需明示；SHA-1 精確顯示／schema 不可升格。 |
| O09 | 保留原工作綁定 | **缺已刪 folder 的同帳戶未完成工作修復流程**，不能靜默 retarget 或改已完成收據。 |
| P01–P02、P04 | 保留既有 QR／手打、指紋人工確認、Keychain、201＋SHA Receiver 協定 | 原成功基線回歸；P01 舊 `camlink://host/code` 相容性若要求需另確認，不為此重寫 Receiver。 |
| P03、P05–P08 | 雙槽／revision／fingerprint receipt、耐久 queue、503 有限重試、場次指定 PC 補傳、逐槽政策 API | 接逐槽 gate、停止舊 worker、每 PC 本場呈現／CSV／可信 legacy 遷移；雙 PC、斷網重開／換證書／取消實測。 |
| A01–A05 | 安全舊索引遷移、stable 場次／改名／搜尋／封面／grid／目的地收據模型 | 新活動與接收生命周期真接線、當場 destination snapshot／生效規則、照片落盤但 ingest 尚未持久化的恢復；不是每按開始已自動形成獨立新場。 |
| A06 | 新歷史 viewer 可 paging／zoom／pan／回最新 | 首頁仍走舊單張 latest preview；若要求首頁同等翻圖／新圖不搶位置，須改用相同 photo-ID 選取流程。 |
| A07–A08 | 手動多選原圖 Files／分享／Photos add-only，不移除原圖 | 不含專用 CAM LINK Photos album、自動 publish、PhotoKit 讀回 hash／從圖庫重建 queue；iOS 合法手動 export 是現有等效路徑，不冒充 Android DCIM 或雲端已核對。 |
| A09–A11 | CSV／JSON／文字、每場 notes／診斷／耗時模型、Google 部分實測欄位 | 真實逐目的地彙總、USB 分階段／queue 耗時與速度、完整每場 device／文件／unresolved checkpoint 診斷與卡檔對照仍待實接；**沒有 ZIP 原圖封裝，也沒有完整 Android 診斷 ZIP 對等**。缺值保留 nil／—，不從 createdAt 猜耗時。 |
| A12–A13 | 任意多選系統分享，root 有分享型服務通用說明 | Dropbox／Box／Google Photos／Flickr 分服務安裝／操作及 Photos 備份指南待補；依已安裝 share extensions，不保證特定 App／批量／遠端結果，不虛構 direct OAuth。 |
| N01–N02 | opt-in banner／本機通知／聲音觸感、去重／去秘密事件、可達停止／pause 元件 | 真實第一張／drain 完成／逐目的地 hook、通知點擊進場次／修復頁仍待整合；不照搬 Android 常駐 foreground service。 |
| N03–N04 | 兩種接收模式、重新搜尋／完成、lifecycle close barrier 已有來源 | 多相機候選選擇仍缺；native final discover／drain 與 close-complete 判定要驗收，不能以 browsing=false 直接發完成。保留 canStart guard。 |
| N05–N06 | 尚無對應耐久 receive checkpoint | **仍缺 card「本張完即暫停／下次續收」與非乾淨停止後新拍補收**：可信相機／卡身份、完成／剩餘持久化、重連比對／handle 重編號警告。需另行最小設計與驗收，不在本批擅改核心。 |
| N07 | 偏好頻率／notes、父層 scanIntervalSeconds 已落檔 | 開始時 snapshot、運行中鎖定、卡模式安全下限、native／PTP 都實際採用需 CI／真機確認。 |
| N08–N09 | 基本計數／設備文字診斷／容量警告、黑色前景口袋 | 真實分階段速度／總 bytes／latency UI、持久診斷仍不全；口袋 brightness 保存／降低／inactive 還原未做。 |
| N10–N11 | 前景耐久恢復、read-only／JPG／RAW 不傳等安全界線 | 已落盤網路 background transfer 未實作；清楚要求重開續傳，不保證 USB 背景，不宣稱未測品牌已支援。 |
| U-W01–U-W03 | 既有 WebDAV 設定／Keychain／destination snapshot／create-only PUT＋完整 GET SHA | 真實 WebDAV 帳密／TLS／redirect／412 相同與不同內容驗收仍待做；不新增任意 TLS 信任或虛構 NAS folder browser。 |
| U-W04 | 前景 pump／明確失敗重試 | 尚缺有限 transient 自動退避、公開 pause／continue、每 request policy 與進行中取消接線。 |
| U-W05–U-W06 | 父層新 ingest 已改只 enqueue 新圖；報告同步有草稿 | 本場 WebDAV 統計／目的地 snapshot、政策變動取消、歷史確認及重開驗收仍需完成；不能拿 activeJobs 配置累計冒作本場。 |
| U01、U04、U06 | 新 Root 已有真 provider 入口／tab／橫豎布局；獨立 worker 不應阻 USB | 完整可返回／iPad／VoiceOver／觸控面積驗收；各 provider failure 不改 camera failed，不阻其他目的地。 |
| U02–U03 | 本機 count 與 PC「份數」已區分；雲端 sheet 有自己的狀態 | **仍缺首頁統一本場／下次目的地 route snapshot**（PC×2／DAV／固定或活動 folder／pause）與逐目的地進度／修復導航，不把 N destinations 的 jobs 加成 N 張已收。 |
| U05、U07 | 舊工作不 retarget、場次遷移／相對路徑與 atomic 保存模型 | 配置危險變更 busy／confirm／下輪生效、關閉重開／container 變動／損壞可見與未索引原圖恢復仍需整合測試；不得吞持久化失敗後宣稱成功。 |

## 5. 父層目前最先要處理的具體阻礙

1. **尚無任何新 Swift 編譯／測試結果。**本次讀取可見兩處明確契約不一致：`RootView` 用 `oneDrive.message`，實際屬性是 `oneDrive.status`；`CamLinkRuntime` 對 `SessionEvent` 的 switch 尚未處理 `.persistenceFailed`。這是靜態觀察，不是假稱已跑 compiler；父層可能正在修正，應以最新檔及真 CI 為準。
2. **全域網路政策未閉環。**Google／WebDAV／OAuth transport 尚未套全域 helper；Runtime 尚未設 PC 逐槽 gate／限制收緊取消。只呈現偏好或 gate 一次不符合每 chunk／probe／readback 政策。
3. **OAuth 共用互動鎖與 signed callback／帳戶驗收未完成。**ID／schemes 已有，不需再叫使用者建立 client；Google consent audience／測試用戶、Microsoft tenant consent／broker 條件與雙 provider 同時登入仍需處理。
4. **完成與收據整合要保守。**Runtime 目前將 requested finish＋browsing=false 映射 cleanStop，history guard 只傳 browsing；應用真實完整 lifecycle。SHA-1／legacy evidence、取消狀態、重啟不重播通知與 archive 保存失敗需精確處理。
5. **不能宣稱全 Android parity。**folder 刪除修復、耐久接收續收／補收、完整本場 route／診斷／階段量測、ZIP、首頁連續 viewer、通知導航、專用 Photos album／服務指南及 brightness 等仍有上述明列差異。

Photos 權限字串與 `PrivacyInfo.xcprivacy` 已在來源，不再列「檔案缺少」；manifest 有 UserDefaults `CA92.1`、DiskSpace `E174.1／85F4.1`、SystemBootTime `35F9.1`。父層仍要核對最終實際用途、XcodeGen 打包／signed IPA 內容與 Apple 要求，來源存在不等於已完成隱私稽核。

## 6. 真 Mac／Codemagic：待執行命令與測試來源

以下從 repo root 執行；**本次沒有執行**。獨立測試位於 `ios/*Tests.swift`，不要納入 App target。Foundation suite 不驗 UIKit／SDK sheet，也不代替遠端或 USB 測試。Session 模型組須補上最新 PcClient 所依賴的 `CamLinkNetworkPolicy.swift`（相簿報告舊命令未列）。

```bash
set -euo pipefail
mac_test() {
  local name="$1"; shift
  xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=minimal \
    -target "$(uname -m)-apple-macosx13.0" "$@" -o "/tmp/camlink-$name"
  "/tmp/camlink-$name"
}
T=ios/CamLink/Transfer
S=ios/CamLink/Session
C=ios/CamLink/Camera

mac_test oauth "$T/OAuthSupport.swift" ios/OAuthSupportTests.swift
mac_test google -parse-as-library "$T/OAuthSupport.swift" \
  "$C/ReceivedJPEG.swift" "$T/GoogleDriveStore.swift" ios/GoogleDriveTests.swift
mac_test onedrive "$T/OAuthSupport.swift" "$T/CamLinkNetworkPolicy.swift" \
  "$C/ReceivedJPEG.swift" "$T/OneDriveStore.swift" ios/OneDriveTests.swift
mac_test multi-pc "$C/ReceivedJPEG.swift" "$T/CamLinkNetworkPolicy.swift" \
  "$T/PairStore.swift" "$T/PcClient.swift" "$T/MultiPCDeliveryStore.swift" ios/MultiPCTests.swift
mac_test archive -parse-as-library "$C/ReceivedJPEG.swift" \
  "$S/SessionArchive.swift" "$S/SessionExport.swift" ios/SessionArchiveTests.swift
mac_test session-model -parse-as-library -D SESSION_MODEL_TESTS \
  "$C/ReceivedJPEG.swift" "$S/SessionArchive.swift" "$S/SessionExport.swift" \
  "$S/ShootSession.swift" "$T/CamLinkNetworkPolicy.swift" "$T/PairStore.swift" \
  "$T/PcClient.swift" ios/SessionArchiveTests.swift
mac_test feedback ios/CamLink/Preferences/DeliveryFeedback.swift ios/DeliveryFeedbackTests.swift
mac_test lifecycle "$C/CameraLifecycle.swift" ios/CameraLifecycleTests.swift

# 既有核心回歸；synthetic JPEG/MPF fixtures 不是實際相機驗收。
mac_test ptp "$C/PTPCameraReader.swift" ios/PTPCodecTests.swift
mac_test jpeg "$C/JPEGIntegrity.swift" "$C/MPFIntegrity.swift" ios/JPEGIntegrityTests.swift
mac_test mpf "$C/JPEGIntegrity.swift" "$C/MPFIntegrity.swift" ios/MPFIntegrityTests.swift
```

若父層將 Google／OAuth／WebDAV 新增 helper 依賴，需同步補 suite 的編譯來源，不以測試未編進新 code 當通過。上述來源覆蓋：OAuth state／PKCE／refresh races；Google 真 production uploader＋注入 URLSession/URLProtocol；OneDrive chunk／probe／GET／收據；PC 雙槽／重試／取消／目的地隔離；archive 遷移／匯出／可選模型；feedback 決策／事件；lifecycle reducer。均無 live credentials。

完整 device-only SDK build（ImageCaptureCore 不用 simulator）及 metadata：

```bash
# runner 未安裝時：brew install xcodegen
(cd ios && xcodegen generate && python3 verify_metadata.py CamLink/Info.plist)
xcodebuild -project ios/CamLink.xcodeproj -scheme CamLink \
  -sdk iphoneos -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios-smoke CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
python3 ios/verify_metadata.py build/ios-smoke/Build/Products/Debug-iphoneos/CamLink.app/Info.plist
```

父層需將新 suite 接入 CI 並保存 PASS／失敗 log；目前 `codemagic.yaml` 的 `ios-smoke`、`ios-testflight-internal` 只有既有 PTP／JPEG／MPF tests，**尚未涵蓋全部新模組**。授權後沿用既有 `ios-testflight-internal`（mac_mini_m2／CamLinkTestFlight integration），在有 signing profiles 的 runner 執行既有流程：

```bash
xcode-project use-profiles --custom-export-options='{"testFlightInternalTestingOnly": true}'
xcode-project build-ipa --project "$CM_BUILD_DIR/ios/CamLink.xcodeproj" --scheme CamLink
ipa=$(find build/ios/ipa -name '*.ipa' -print -quit)
test -n "$ipa"
python3 ios/verify_metadata.py "$ipa"
```

另檢查 app／IPA 實際包含 privacy manifest、正確三套 schemes 與 exact SDK pin；現有 metadata 腳本不是 Apple 隱私審查或登入成功證明。只有拿到真 runner 結果後才報 compile／test pass；沒有 Mac 的使用者繼續經 Codemagic／TestFlight，不要求本機 Xcode。

## 7. 最低真機／遠端驗收門檻

父層完成接線及 CI 後，以 signed iPad 回歸原五 JPG／PC 路徑，另驗 card→完成 close→不拔線→新拍的生命周期；新拍必須看到 DEVICE／SESSION_OPEN／ready 後再判斷接收，不能把舊 DISCOVERY_TIMEOUT 誤報為本次已修好。

Google／OneDrive 各測成功、取消／拒絕、冷啟動還原、過期 refresh、撤權、換帳戶、folder 選建／活動空名、大小圖與 MPF、斷網／重開／pause、失效 session／衝突／限流與實際遠端核對；OneDrive 必含個人與工作帳戶。PC 必驗雙目的地收據、單邊 503 不阻另邊、換指紋與只補指定歷史場次。WebDAV 必用真 credentials 驗 PUT＋GET、412 同／異內容與 TLS／redirect 拒絕。再驗 Wi-Fi／cellular／hotspot／低數據途中收緊政策、容量確認取消、歷史不串場、原圖多選／Files／Photos 權限拒絕及通知授權。沒有這些證據之前，只能交付「已實作、待驗收」，不能宣稱遠端 OAuth／HTTP／USB 全部測試成功。
