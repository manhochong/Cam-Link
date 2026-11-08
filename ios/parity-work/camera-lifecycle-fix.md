# iOS 相機生命週期最小修復

## 範圍與證據

本次僅修改 `ios/CamLink/Camera/CameraCaptureService.swift`，新增同目錄的 `CameraLifecycle.swift`、`ios/CameraLifecycleTests.swift` 及本報告。沒有修改 RootView、CamLinkApp、CI、plist、PTP reader／receiver 或 JPEG／MPF 驗證器；沒有執行 Git、瀏覽器或實際相機操作。

已閱讀 `new-photo-audit.md` 與 `new-photo-report.txt`。新照片模式的紀錄只有 `START`、相機／內容授權成功及 `DISCOVERY_TIMEOUT`，`connected=false`，沒有 `DEVICE`／`SESSION_OPEN`。使用者確認同一 build 41 的卡內模式曾成功接收五張 JPG 並送達 PC。因此這次修補的是已確認的探索／工作階段生命週期缺口，**不是已證實的 baseline、JPEG 或 PC 傳送問題；也不能宣稱已證實當次事故的唯一原因或實機修復成功。**

## 正式程式變更

### 1. 每次實際開始配置全新的 browser

`SessionContext` 擁有不可變 session token、browser ID 及新的 `ICDeviceBrowser`。不是重用服務生命週期內的單一 browser。

相機權限完成後、內容授權閉包、PTP 控制授權閉包及探索 timer 均持有**同一個確切 browser 物件**，並在 MainActor 核對來源 browser、context token 及有效狀態。舊授權完成不能操作稍後的 browser。browser 的 add／remove delegate 同樣核對來源物件；舊 browser 的延遲移除不能停止新工作階段。

### 2. 不再只依賴 didAdd

`browser.start()` 後立刻執行 `reconcileDevices`。仍處於 discovering 時，原有兩秒 timer 亦會重新讀取 `browser.devices`。

cached enumeration 與 `didAdd` 均通過同一個 `open(_:browser:token:source:)`，由正式 `CameraLifecycle.admitDevice` 決定是否接納。狀態先同步轉為 opening，才發出唯一的原生 `requestOpenSession()`；因此 cached／add 競態、同一相機重複通知或第二台相機，都不會造成重複開啟。

### 3. 不可變的原生相機 delegate proxy

每次裝置接納會配置新的 `CameraSessionDelegate`，在 `requestOpenSession()` 前設定。proxy 持有不可變 session token 及本次接納的 camera ID，**在 actor hop 前**把這些 ID 與事件一起轉交服務，而不是回呼到達後才讀取最新 generation。

服務同時核對 token、camera ID、原生裝置物件與 reducer 狀態。即使新工作階段重用同一 `ICCameraDevice` 物件，經由舊 proxy／已排程 actor hop 轉交的 open、close、remove、catalog、items、PTP、權限限制或能力變更通知，都不能變成新工作階段的事件。proxy 採用原檔已有的 ImageCaptureCore delegate 方法簽章，包含所有原有必要通知；thumbnail、metadata、rename、remove-items、delete-completion 仍無接收副作用。

### 4. 非同步關閉屏障

停止會先更換 receiving generation、停止探索／timer、取消／poison PTP receiver、清空原生接收佇列，再請 Apple 關閉它擁有的原生 session。舊 context、相機與 delegate 不會隨 logical stop 被丟棄。

| 停止時狀態 | 正式處理 |
|---|---|
| authorizing／discovering，尚未提出 native open | 直接釋放，沒有相機 session 需要關閉 |
| opening，native open 尚未完成 | 轉為 closingOpening，不與 open 競發 close；保持禁止新開始 |
| 停止後收到對應成功 open | 只提出一次 native close，不設定 connected、不接收、不建立 PTP receiver |
| receiving | 提出一次 native close，等待對應成功完成 |
| 對應成功 close，未逾時 | 只釋放自己的 context；不呼叫一般 stop 去停止另一個工作階段 |
| 已確認的對應裝置拔除 | 釋放該 context；未完成下載不算成功 |
| close／opening-cleanup 逾時或 open／close 錯誤 | 保留 context，要求實體拔除，禁止猜測性重開 |

屏障逾時為停止後 15 秒。**逾時不是已關閉的證據**；即使之後收到成功 close，reconnectRequired 仍保持禁止開始，直到對應原生 `didRemove` 或同 browser／裝置的 remove 通知證實拔除。逾時後若 pending open 才成功，仍只做一次原生 close 清理，不恢復接收。沒有強制清除屏障、重複試開或 raw PTP OpenSession／CloseSession。

這是「拒絕新開始」方案，沒有暗中排入新模式。使用者需在屏障解除後再按開始；舊 callback 不會自動觸發新一輪。若 iPadOS 沒有回報對應拔除，服務不會用 timer 猜測已安全；必須實際拔除後再以重新啟動 App 等方式恢復，而不能在仍連線時強制清除狀態。

### 5. 原有傳輸及資料安全保持

原有 native download／PTP callback 的 generation guards 保持；`ptpSelected` 仍為單一 session 的 sticky、排他選擇。沒有改 baseline／輪詢、handle 篩選、JPEG／MPF 完整性驗證、onJPEG／PC 交付資料或 reader 重用政策。PTP 完成時不會以「已完成」訊息掩蓋仍在關閉的正常狀態。

沒有新增相機 property、vendor、shutter、delete、raw open／close-session 或 tether mutation 命令，也沒有刪除任何既有相機資料。現有本機失敗下載清理程式保持原狀。

## 給父任務的 API／UI 接線

既有 `startBrowsing()`、`stopBrowsing()`、`finishReceiving()`、`refreshContents()`、`diagnosticFile()`、`mode` 與 `onJPEG` API 維持原樣。新增唯讀 published 狀態：

```swift
@Published private(set) var sessionClosing = false
@Published private(set) var canStart = true
```

- 兩個開始模式按鈕請套用 `.disabled(!camera.canStart)`；若要隱藏開始選項，條件可直接用 `camera.canStart`。
- `sessionClosing` 在 closingOpening、closing、reconnectRequired 都為 true，可顯示「正在關閉上一個相機工作階段」；reconnectRequired 的具體指示已在 `status`／`lastError`。
- 不要只用 `!browsing` 判斷可安全重新開始。logical stop 後 browsing=false，但 sessionClosing 仍可能為 true。
- `canStart=false` 包含授權、探索、開啟、接收及關閉中。即使 UI 尚未接線，服務入口仍會拒絕不安全的 start，並記錄 `START_BLOCKED`。
- UI 不應在 canStart=false 時改接收模式。本補丁不增加模式佇列或改動 receiver 的既有 mode snapshot 政策。

主要內部介面是 `CameraLifecycle.start / authorized / admitDevice / stop / opened / closed / closeTimedOut / removed`，正式服務直接使用它們處理 native effects；`ownsBrowser`／`acceptsReceivingCallback` 為來源及狀態 guards。RootView 不需要呼叫 reducer。

## 診斷新增

報告 header 增加 session、browser ID、phase、sessionClosing、canStart。日誌新增 `BROWSER_CREATED`、`BROWSER_START`、`BROWSER_STOP`、`BROWSER_RECONCILE cachedCameras=…`、來源／狀態拒絕原因、`SESSION_OPEN_REQUEST`、`SESSION_OPEN_CLEANUP_ONLY`、`SESSION_CLOSE_REQUEST`、`SESSION_CLOSE_COMPLETE`、`CLOSE_WAIT_OPEN`、`CLOSE_BARRIER_TIMEOUT`、`CLOSE_BARRIER_RELEASED` 與 `RECONNECT_REQUIRED`。

僅記錄生命週期識別與既有檔案診斷，沒有加入影像 bytes、receiver 密碼或配對碼。

## 測試：已備妥，未在本環境執行

`CameraLifecycle.swift` 僅 import Foundation。離線 executable **直接編譯正式 app 使用的同一檔 reducer**，不是複製的測試模型：

```sh
swiftc ios/CamLink/Camera/CameraLifecycle.swift ios/CameraLifecycleTests.swift -o /tmp/camlink-camera-lifecycle-tests
/tmp/camlink-camera-lifecycle-tests
```

已備妥的檢查涵蓋：cached camera 沒有 didAdd、初始空 list 後下次 tick 才有相機、cached／didAdd 任一先到的單次 admission、第二台相機、舊 browser／授權、card stop 後新開始受阻、同 camera identity 的舊 open／close／remove／receiving callback、stop while opening、重複 open／close、close timeout、timeout 後 late-open 清理及 late-close 仍受阻、open／close 錯誤、實體拔除、外部成功 close，以及 unopened discovery stop。

本 sandbox 沒有 `swift`／`swiftc` 或 iOS SDK，**沒有編譯或執行上述 Swift 測試，也沒有執行 iOS build 或實機驗收**。已執行的只是 Swift tree-sitter 語法樹解析及來源靜態檢查：三個 Swift 檔案解析沒有 ERROR／missing node；唯一 native open／close 呼叫點、確切 browser 捕捉、proxy 不可變 IDs、正式 reducer 接納／timeout 使用、既有排他及 JPEG guards 均存在。這些不能替代 Swift type checking、SDK protocol conformance 或硬體測試。

離線 reducer 測試驗證 admission／狀態決策，不驗證 ImageCaptureCore 是否實際供應 cached devices、原生 delegate dispatch 或控制授權，也不代替 PTP／JPEG 測試。

## 必要的 Mac／實機驗收

1. 在父任務 CI 編譯並執行上述離線測試，再進行現有 iOS SDK build，確認完整 delegate adapter conformance。
2. 在原本成功的 DC-S1RM2 路徑做「卡內 JPG → 完成／停止 → 不拔線 → 接收新拍 JPG」。新開始前需有對應 close success／屏障釋放，後續 session／browser ID 必須不同。
3. 新照片模式需先看到新一輪 `DEVICE`／`SESSION_OPEN`、目錄或 PTP ready；ready 後新拍 JPG，核對本機完整性及 PC 接收。若仍只到 DISCOVERY_TIMEOUT，保留報告，不把它歸因為 baseline。
4. 重複做「開啟中立刻停止 → 試按開始」，確認沒有第二次 open，成功 open 後只清理 close；再測一般 stop 後快速開始。
5. 拔除／重插，確認匹配 removal 清除屏障。關閉逾時後不應發出猜測性 open；實體拔除前開始按鈕仍不可用。
6. 回歸原有卡內五 JPG／PC 成功路徑，核對沒有 native／PTP 混用及沒有照片被刪除。
