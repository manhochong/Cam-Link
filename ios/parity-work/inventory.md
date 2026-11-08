# Cam Link Android／iOS 真實工作流程對等盤點

稽核日期：2026-11-08。來源：`/home/ubuntu/CamLink-github` 當下檔案。iOS `ios/project.yml:8–9` 為 0.2.25／build 41。本次只閱讀原始碼及建置設定，沒有修改程式碼、操作 Git／瀏覽器、登入第三方服務或觸發建置；唯一新增的是本盤點文件。

## 1. 結論與證據邊界

使用者回報 **build 41 已在真實 iPad 收到 5 張 JPG、失敗 0，PC 可接收**。此成功應保留為已確認基線，不應為補雲端而重寫 USB／PTP／MPF 接收核心。它不是 Drive／OneDrive／WebDAV 已成功上傳的證據，也不是所有相機型號、長時間連拍或零漏圖的保證。

**iOS 的 Google Drive 與 OneDrive 直接傳送確實沒有實作**：`ios/CamLink/RootView.swift:340–359` 是 `pendingCloud` 鎖定文字，並非可點擊登入或傳送入口。`ios/CamLink/CamLinkApp.swift:5–16` 只有 Camera、ShootSession、PairStore、WebDAVStore 四個狀態物件。iOS 來源沒有 Google／Microsoft 授權或對應雲端 API／佇列。

WebDAV 已有真正設定、Keychain 憑證、獨立持久佇列、原圖 PUT、GET 回讀大小／SHA-256 核對、手動重試與自動上傳選擇；不能列成「完全沒做」。但缺少正式場次整合，且這次沒有實際遠端帳密驗證。單一電腦已有 QR／手打、指紋確認、Keychain 配對碼、原圖傳送及 Receiver SHA-256 回覆確認，但未達 Android 的雙電腦、各電腦獨立交付紀錄及自動恢復流程。

Android 的其他真實功能缺口包括：活動名稱／每次接收獨立場次、可搜尋歷史、場次相簿與連續大圖瀏覽、系統 CAM LINK 相簿原圖可取用、交付 CSV／Drive 結果 JSON／持久診斷、每張接收與 Drive 耗時、接收與傳送通知、卡內匯入暫停續收／斷線補收，以及首頁／詳情對所有目的地的統一呈現。

### 判讀符號

- **缺少**：Android 有可達使用者流程，iOS 沒有。
- **部分**：iOS 有核心流程，但使用者可達操作、持久狀態或整合不足。
- **已有**：對該使用者流程已有相應功能；不等於已完成真機／第三方驗收。
- **平臺適配**：不能照搬 Android 背景服務／特定 App 轉交機制，應以誠實 iOS 等效流程實作。
- **Android 邊界**：實際 Android 自身有限制，不應誤列為已存在的高階能力。

下文 `A/` 精確代表 `/home/ubuntu/CamLink-github/app/src/main/java/hk/camlink/usb/`；`I/` 精確代表 `/home/ubuntu/CamLink-github/ios/CamLink/`。每個檔名及行號皆對應本次讀取版本。分類固定為 Google Drive、OneDrive、已配對電腦、相簿／歷史／匯出、通知／設定、父層 UI 整合；**WebDAV 的 UI／跨目的地事項放於第 7 節，分享型服務放於第 5 節**，不混充 Drive／OneDrive 直接供應商。

## 2. Google Drive：直接供應商，整條流程缺少

| ID | Android 真實使用者功能與精確來源 | iOS 狀態／對應落點 | 要補齊的工作流程及邊界 |
|---|---|---|---|
| G01 | 選 Google 帳戶、授權、顯示 email、重新登入／更換帳戶：`A/CloudActivity.java:125–138,164–166`；帳戶核對 `A/CloudAuth.java:14–35` | **缺少**；`I/RootView.swift:340` 只有待完成提示 | 真正 iOS 授權 session／SDK、取消與失敗、取得並核對帳戶身分、token 更新、需要重新登入的導引。Android package／SHA-1 OAuth client 不可直接替代 iOS client。 |
| G02 | 選已存在的可存取資料夾、權限檢查：`A/CloudActivity.java:139–141`；`A/DriveApi.java:86–98` | **缺少** | 顯示可寫入的 App 資料夾清單、空清單與不可寫入錯誤。Android 只查 `camlinkFolder=1` 標記、非垃圾桶資料夾；不是任意整個 Drive 的檔案瀏覽器。scope 為 `drive.file`。 |
| G03 | 建立固定上傳資料夾，名稱 1–120 字，建立中斷可恢復：`A/CloudActivity.java:142–148` | **缺少** | 建立資料夾、保存 ID／名稱、不可因重試建立多份；選擇／新建應變成可使用 UI，不只是顯示服務圖示。 |
| G04 | 改為依活動名稱建立本場資料夾，固定／活動兩種模式：`A/CloudActivity.java:47–50`；`A/EventFolder.java:9–54`；開拍預覽 `A/MainActivity.java:203–235` | **缺少**；`I/Session/ShootSession.swift:15–21,125–130` 無活動名稱／新場次 API | 開拍可填活動名稱；固定資料夾不需名稱；活動模式留空時 Android 略過 Drive。離線開拍也保存當場綁定，恢復後按原帳戶／場次建立資料夾，不把歷史照片暗中改到新目的地。 |
| G05 | 「自動上傳新拍 JPG」開關及適用下一輪說明：`A/CloudActivity.java:55–60,94`；接收後排入 `A/CaptureService.java:202–233` | **缺少**；目前 `I/RootView.swift:409–417` 只排 PC／WebDAV | 每供應商獨立 opt-in／暫停狀態；收完整 JPG 後排隊。設定變更與本場目的地的生效時間需清楚，不能雲端錯誤改寫本機接收成功。 |
| G06 | 「只用 Wi-Fi／允許 4G、5G」與等待可上網網路提示：`A/CloudActivity.java:58–59`；`A/CloudNetwork.java:18–74` | **缺少／平臺適配** | iOS 以網路可用性與 URLSession cellular policy 提供同等選擇、用量提示和中斷可恢復；不宣稱能照搬 Android 任意綁定網絡／強制開流動數據。PC 區域網路與雲端網際網路要分開。 |
| G07 | 真正原圖直傳、不依賴 Google Drive App：`A/DriveApi.java:99–127`；`A/UploadEngine.java:18–71` | **缺少** | 原圖上傳、可恢復進度、確認完成、避免回覆遺失後重傳產生重複；不必照搬 chunk 大小或 worker 數量。 |
| G08 | 雲端完成核對：`A/DriveApi.java:122–126` | **缺少** | Android 必查檔案 ID、非 trashed、大小、MD5、parent 資料夾；遠端 SHA-256 **有提供時**才比對。不可聲稱 Android 一定 GET 全圖或一定提供 SHA。iOS 若升級為 GET／SHA 核對，須區分「上傳完成」與「完整內容已核對」。 |
| G09 | 耐久獨立佇列、帳戶隔離、重開補回漏排工作：`A/CloudStore.java:18–57,65–73,135–159`；`A/UploadService.java:109–159` | **缺少** | 保存帳戶／資料夾／照片身分／雜湊／remote ID／進度／錯誤；正在上傳後被終止能恢復。選新帳戶不能拿新 token 送舊帳戶工作。保留原圖。 |
| G10 | 暫停、繼續待傳佇列、重試帳戶失敗項目：`A/CloudActivity.java:62–66,96–107`；`A/CloudStore.java:97`；`A/UploadService.java:88–106` | **缺少** | 暫停不刪檔、不丟進度；有限退避重試、AUTH 與不可恢復錯誤區分、重新登入後可續傳，重開 App 可恢復。 |
| G11 | 固定資料夾消失時繼續交付：`A/UploadService.java:51–71`；`A/CloudStore.java:75–85` | **缺少** | Android 可採用同帳戶目前可寫資料夾，或新建同名／Cam Link 資料夾並重新排未完成項目。iOS 至少提供「資料夾不存在→選／建新資料夾→確認只移動未完成項目→續傳」，不能靜默跨帳戶重派已完成／舊工作。 |
| G12 | 帳戶累計已核對／待完成／需處理，最近 25 筆、百分比、錯誤、上傳速率與最近一張完整耗時：`A/CloudActivity.java:38–39,67–69,103–116`；`A/CloudStore.java:113–134` | **缺少** | 可用進度頁＋近況列表；錯誤應可導向修正操作，不只 root 文字提示。只顯示已實際記錄的速率／耗時，不造數字。 |
| G13 | 手動把最近一輪完整 JPG 加到已選帳戶／固定資料夾：`A/CloudActivity.java:150–154` | **缺少** | 本機拍完才登入也可補傳；明示目標，排隊去重，不加入 RAW／.part。Android 此頁需固定資料夾；任意歷史／任意多選補傳是可改善但非這條 Android 原流程。 |
| G14 | 開啟 Drive 資料夾／查看照片、登出保留本機與歷史、授權管理說明、登入設定資料、匯出結果 JSON：`A/CloudActivity.java:51–54,75–78,156–162,167`；`A/CloudStore.java:161–165` | **缺少** | 深連結到實際資料夾；登出／重新登入可恢復同帳戶歷史；設定說明改為 iOS bundle／client／callback 而非 Android SHA；管理 Google 授權須交代共用專案的影響；結果 JSON 去 token、resumable URL、絕對路徑和 email。 |

## 3. OneDrive：另一個直接供應商，不能用 Drive 佇列替代

| ID | Android 真實使用者功能與精確來源 | iOS 狀態／對應落點 | 要補齊的工作流程及邊界 |
|---|---|---|---|
| O01 | Microsoft 選帳戶登入、email、重新登入／換帳戶、取消／錯誤：`A/OneDriveActivity.java:36,61,77`；`A/OneDriveAuth.java:40–78`；`A/OneDriveLogin.java:15–48` | **缺少**；`I/RootView.swift:341` | iOS 原生外部授權 session＋PKCE/state，refresh token 入 Keychain，短期 access token、安全錯誤。不要複製 Android WebView 攔截當成 iOS 成品；不需要 OneDrive App。 |
| O02 | 選已有根目錄資料夾、建立上傳資料夾、改資料夾：`A/OneDriveActivity.java:37–40,79–80`；`A/OneDriveApi.java:90–118` | **缺少** | 根目錄資料夾列表／建立／選取／校驗。Android 列表是 root children `$top=200`，沒有任意深層／完整分頁瀏覽；不可把那些較高階要求算現有對等。 |
| O03 | 固定資料夾或按活動名稱建／找根目錄同名資料夾：`A/OneDriveAuth.java:28–38`；`A/OneDriveStore.java:30–37`；`A/OneDriveService.java:52–56` | **缺少** | 無固定資料夾且開拍名稱空白時略過自動 OneDrive 綁定；與 Google Drive 的 per-session `event:` receipt 行為並不完全相同。UI 要清楚採用哪一種模式。 |
| O04 | 自動上傳、只 Wi-Fi／可流動數據：`A/OneDriveActivity.java:41–47`；`A/OneDriveService.java:38–51` | **缺少／平臺適配** | 與 Google 互相獨立設定和網路 policy、等網提示。Android 登入接受後自動 enabled=true；iOS 必須清楚告知啟用狀態，不能把「已登入」泛稱「已備份」。 |
| O05 | Graph 原圖 upload session、儲存進度、過期重新傳、同名衝突不覆寫：`A/OneDriveApi.java:120–163`；`A/OneDriveService.java:73–90,108` | **缺少** | 可重開續傳／重試，明確同名衝突處理，不覆寫遠端已有不同照片；保存實際 remote ID。 |
| O06 | 完成大小／可用雜湊核對：`A/OneDriveApi.java:155–163` | **缺少；Android 邊界** | Android **只必查大小**；Graph 沒有 `sha256Hash` 時直接通過，有時才比 Base64 SHA-256。不可誤稱 OneDrive 都已 SHA-256 全圖驗證。iOS 必須顯示核對層級；若目標是內容已核對，需額外可靠 hash 或讀回驗證。 |
| O07 | 獨立耐久佇列、依帳戶統計、近 25 筆進度、AUTH／ERROR／RETRY：`A/OneDriveStore.java:19–27,39–89`；`A/OneDriveActivity.java:65–71` | **缺少** | OneDrive 工作不能併入 PC 的 `uploaded` 或 Drive；每工作保留帳戶與 folder，換帳戶不可暗中遷移原佇列。 |
| O08 | 暫停、繼續、帳戶失敗重試、回前景續傳／有限退避：`A/OneDriveActivity.java:29–30,92`；`A/OneDriveService.java:92–118`；`A/ConsoleActivity.java:27–35` | **缺少** | 手動 controls＋重開可恢復；iOS 背景不可保證 Android foreground service 一樣，但不應把此限制當成不能做耐久排隊的理由。 |
| O09 | 目的資料夾消失修復：`A/OneDriveService.java:57–71`；`A/OneDriveStore.java:46–54` | **缺少** | 找／建可寫資料夾，確認只重派同帳戶未完成工作，清除過期上傳階段，保留已經完成紀錄。 |
| O10 | 將最近一輪 JPG 加入上傳：`A/OneDriveActivity.java:81–86`；`A/OneDriveStore.java:90–98` | **缺少** | 拍完才補傳、去重、相簿來源亦可讀；無固定 folder 時用場次名，留空用目錄名。注意 Android 此流程目前要求 auto enabled，並非完整的「關閉 auto 仍任意手動上傳」工作流。 |
| O11 | 登出保留本機／雲端與歷史、需先停拍／暫停：`A/OneDriveActivity.java:88–89`；`A/OneDriveAuth.java:80–82` | **缺少** | 安全清除目前登入 token，不刪除圖／歷史佇列，舊帳號重新登入可正確取回。Android OneDrive 沒有獨立「打開資料夾」或 JSON 匯出按鈕，不能把它誤算成現有功能；有第 5 節的共同交付 CSV。 |

## 4. 已配對電腦：保留已成功的單一 Receiver，補完整工作流程

| ID | Android 真實使用者功能與精確來源 | iOS 狀態／對應落點 | 要補齊的工作流程及邊界 |
|---|---|---|---|
| P01 | QR、手打 IPv4／12 位配對碼、camlink 配對深連結：`A/OtherClouds.java:186–267`；`A/PairLink.java:19–30`；`A/PcLink.java:14–19` | **已有**：`I/RootView.swift:421–458`、`I/PairQRScanner.swift`、`I/Transfer/PairStore.swift:67–73`、`I/Transfer/PcClient.swift:30–68` | 保持目前標準 QR 可用。Android parser 另容許舊 `camlink://<host>/<code>` 語法，iOS URL parser 未有該 fallback；可補兼容，但不屬於重寫 Receiver。兩平臺實際連接皆 IPv4／9443，不需虛構公網、mDNS 或多協議服務器。 |
| P02 | 先探測憑證指紋、人核對、再認證保存憑證：`A/OtherClouds.java:212–275`；`A/PcLink.java:29–69`；`A/DavBackup.java:62–98` | **已有**：`I/Transfer/PairStore.swift:75–126,150–190`、`I/Transfer/PcClient.swift:70–95,130–211` | 配對碼 Keychain，fingerprint 非密碼；指紋變動須重新核對。僅 PC 允許已確認精確 fingerprint 的局域網自籤憑證，不可因此放寬 WebDAV／OAuth TLS。 |
| P03 | 配對／更新第一部、第二部，各自停用、全部停用，新拍／卡內 JPG 傳所有配對電腦：`A/OtherClouds.java:153–172,186–211`；`A/DavBackup.java:37–40,112–114` | **缺少雙電腦**：`I/Transfer/PairStore.swift:22,39–64,117–139` 僅一個 `ComputerPair` | 兩個 slot、各自 Keychain 憑證、獨立 ready／status／pending／verified；QR 進入明確選 slot，不意外覆蓋第一部。一個失敗不能阻塞另一部或雲端。 |
| P04 | 原圖直傳並確認 Receiver header SHA-256：`A/DavBackup.java:233–254` | **已有**：`I/Transfer/PcClient.swift:97–122`；`I/Session/ShootSession.swift:62–106`；真實 PC 收圖已確認 | 保持只有 HTTP 201＋匹配 SHA 才標已核對。不把本機接收、分享完成、WebDAV 核對當 PC receipt。 |
| P05 | 各 PC destination profile 的耐久排隊、已傳歷史、換電腦不誤用舊 receipt：`A/DavBackup.java:30–44,73–88,105–114` | **部分且有正確性缺口**：`I/Camera/ReceivedJPEG.swift:10` 僅一個 `uploaded` Bool；`I/Session/ShootSession.swift:42–43,78–90` | **目前換配對電腦不會重置已上傳照片**：Root 只重新 `scheduleUpload`，只傳 `!uploaded`；`markNeedsUploadAll()` 存在但沒有 UI／調用。應以 PC fingerprint／slot＋photo ID 獨立 receipt，不可僅全量重置 Bool，否則多電腦互相汙染。 |
| P06 | 只把最近一輪補傳到配對電腦，不動 Drive／OneDrive：`A/OtherClouds.java:158–184`；`A/DavBackup.java:115–139` | **部分**：`I/RootView.swift:311–313` 能傳全部累積 pending，不能按真實場次或新電腦補傳已核對照片 | 最近／所選場次→明確 PCs→去重補傳→各電腦獨立核對；新的目的地應能收舊圖，不因原 PC 的 uploaded=true 跳過。 |
| P07 | 網絡斷／Receiver busy／超時可自動重新排隊；配對碼／指紋錯需修正：`A/DavBackup.java:140–214,222–228` | **部分**：`I/Session/ShootSession.swift:74–105` 每次 drain 每照片只嘗試一次，503 中斷；`I/RootView.swift:75–94,409–417` 靠新圖／配置變化／回前景再觸發 | 增加可取消有限退避、網絡恢復／回前景恢復與 per-job 錯誤；現有 503「稍後會重試」文案不能當成 timer 已存在。401／指紋錯不應盲目重試。 |
| P08 | 電腦對場次排隊／核對／失敗統計、交付 overview 與 CSV：`A/DavBackup.java:41–60`；`A/ShootDetail.java:153–154,208–240`；`A/SessionExport.java:52–66` | **部分**：root 只有一套 `session.verifiedCount`／pending | 完整接收與傳送詳頁按本場／每 PC 展示，防雙 PC 2N 條 receipt 被當 N 張照片的泛用完成數。Android 自身會合計多個 PC job，不代表已存在完美 per-slot UI；iOS 需至少不產生誤導。 |

## 5. 相簿／歷史／匯出，包括「分享型」服務

| ID | Android 真實使用者功能與精確來源 | iOS 狀態／對應落點 | 要補齊的工作流程及邊界 |
|---|---|---|---|
| A01 | 每次接收建立獨立場次目錄／報告，開拍填活動名：`A/SessionReport.java:19–35`；`A/MainActivity.java:197–239` | **缺少**：`I/Session/ShootSession.swift:15–39,125–130` 首次初始化一次 sessionId，重開還加載同一個；`I/Camera/CameraCaptureService.swift:62–65` 所有圖放同一個 `Documents/sessions` | 明確 start／stop 本場，唯一場次 ID、名稱、開始／完成時間、當場 destination snapshot、照片歸屬；現有圖片必須遷移保留，不能清空目前 5 張成功基線。 |
| A02 | 改場次名稱（選填、100 字上限、可清空）：`A/ShootDetail.java:67–92`；`A/SessionNames.java:7–18` | **缺少** | 開拍命名、詳情改名並持久保存。改顯示名不應自動搬移已經創建的雲端 folder 或改變舊工作目標。 |
| A03 | 歷史場次列表、最新在前、封面、照片數、按活動名稱／日期搜索、隱藏明確零圖場次：`A/ShootDetail.java:45–65,327–463` | **缺少真正歷史**：`I/RootView.swift:260–299` 僅累積照片列表 | 場次歷史→搜索→進入所選場次；運行中與已完成區分，封面／計數讀取失敗不能偽稱 0 張。 |
| A04 | 本場詳情：已收張數、各目的地 overview、待傳／已核對縮圖、失敗項目入口／Drive 本場重試、打開 Drive folder：`A/ShootDetail.java:120–183,205–237,266–313,315–326` | **部分**：`I/RootView.swift:260–299` 有單張及 PC 狀態、接收錯誤，但不是 multi-destination 場次詳情 | 統一讀各獨立 delivery stores，只重試本場／原賬戶匹配工作；錯誤指向登入／資料夾／網絡修復。不得用一個 verifiedCount 假裝所有目的地完成。 |
| A05 | 本場 grid 相簿、點縮圖進大圖、指定照片定位、回前頁與旋轉後恢復位置：`A/SessionAlbum.java:27–65,71–107,157–161` | **缺少 grid／位置恢復**：iOS history HStack 列表、單張 viewer | 自適應 iPhone／iPad grid、場次範圍與總張數、點入定位、回相簿／保留瀏覽位置；仍只顯示完整原圖記錄。 |
| A06 | 首頁／大圖左右滑換照片、縮放時拖移、雙擊縮放、返回最新、新圖來不搶當前瀏覽照片：`A/ShootPanel.java:75–107,127–175`；`A/ReviewPhoto.java:10–103`；`A/SessionAlbum.java:109–155` | **部分**：`I/PhotoPreview.swift:45–67` 有 pinch／double tap，但單張常量 `photo`、沒有 paging、drag pan；root 始終最新圖 | 以 photo ID 維護選中照片，base zoom swipe、zoomed drag pan；回到最新可再次跟隨收到新圖。縮放倍率／解碼分辨率屬於實現差異，不需要強求相同數值。 |
| A07 | 完整 JPG 在共享 `DCIM/CAM LINK` 相簿／文件管理器可取用，不必依賴 App：`A/Gallery.java:15–16,44–82`；`A/MainActivity.java:157`；`A/OtherClouds.java:70` | **部分**：iOS 原圖在 App Documents、ShareLink 可「存檔／儲存影像」（依系統），但 `I/Info.plist` 未啟用 File Sharing／Documents opening，亦無 PhotoKit 保存相簿 | 提供 iOS 合法的「保存原圖到照片／CAM LINK 相簿」及／或 Files 可取用原圖導出；明確權限和是否 auto publish。不需偽造 Android DCIM 路徑或 iOS 可寫同一路徑。上傳原圖需保留穩定來源引用，導出／圖庫失敗不影響本機已收。 |
| A08 | 相簿移動前校驗、發佈後 hash 一致才刪 staging 副本，佇列仍可從圖庫讀原圖：`A/Gallery.java:32–42,44–82`；各 `importSession` | **iOS 未做系統圖庫流程**；現有 App 原圖應保留 | 平臺適配為真實 export／PhotoKit receipt，不能導出失敗便刪原圖；不能僅保存縮圖／重壓圖當原圖。刪除臨時副本屬於保空間策略，不是用戶「刪除場次／照片」功能。 |
| A09 | 本場交付 CSV，filename／local／time／SHA-256／computer／drive／onedrive：`A/ShootDetail.java:184–203`；`A/SessionExport.java:11–74` | **缺少** | 系統導出／分享 CSV，狀態可按每 destination 解釋，不含憑證；注意 Android 現 CSV **沒有 WebDAV** 欄、PC 合併狀態，故不能宣稱已有 WebDAV／各 PC 完美報表。可以擴充但要標為改善。 |
| A10 | 每張 JPG 接收耗時及 Drive 排隊／上傳／核對耗時，更新查看：`A/PhotoTimes.java:18–65`；`A/ShootDetail.java:239–264` | **缺少**：ReceivedJPEG 只有 createdAt，沒有階段時長 | 為 USB 接收與 Drive 儲存真實階段時間、重試累加；沒有數據顯示「—」。Android 此工具主要 join Drive，不應虛構 OneDrive／WebDAV／PC 詳細階段計時已存在。 |
| A11 | 最近一輪診斷 ZIP：device.json／summary.json／files.csv／events.log，逐文件與 unresolved handles，可交 compare_card.py 獨立核對：`A/MainActivity.java:252–262`；`A/SessionReport.java:27–56`；`A/CaptureService.java:180–186` | **部分**：`I/Camera/CameraCaptureService.swift:462–488` 有最近會話 txt＋400 條滾動 log／highlights；沒有重開可查的每場逐文件持久診斷 | 每場持久化設備／模式／版本／權限／接收結果／文件 hash／時間／錯誤；可從歷史導出。無需 ZIP 名稱完全一樣，但用戶能完成可靠問題復現與卡檔對比。0 failed 不等於與卡完全無漏圖；報告不可含 OAuth token／配對碼／密碼。 |
| A12 | Dropbox／Box／Google Photos／Flickr：已安裝服務入口、未安裝引導商店、選一／多張 JPG、轉交特定 App／打開 App、分享不支援時替代說明：`A/OtherClouds.java:16–17,54–68,97–132` | **部分／平臺適配**：`I/RootView.swift:342–346` 可分享全部 JPG；history／viewer 能分享單張，不能任意多選；沒有服務별說明頁 | 系統分享＋任意多選完整 JPG、保存／打開／安裝服務指南、失敗／取消保持原圖。iOS 可用目標依安裝的 share extension；不能保證強制指定 provider、每 App 支援批量或讀取上傳結果。不要給它們編造 direct OAuth／自動 Cam Link 上傳隊列。 |
| A13 | Google Photos 從 CAM LINK 裝置資料夾手動選相／App 自動備份設置指南：`A/OtherClouds.java:105–106` | **平臺適配** | iOS 的「照片圖庫備份」不是 Android「備份裝置資料夾 CAM LINK」。可提供先儲存原圖到 Photos 後由 Google Photos 自己備份的準確說明；不能保證同樣目錄開關／備份完成。 |

## 6. 通知／設定：等效用戶操作，不照搬 Android 服務

| ID | Android 真實使用者功能與精確來源 | iOS 狀態／對應落點 | 要補齊的工作流程及邊界 |
|---|---|---|---|
| N01 | 第一張已收到、本場接收完成、接收失敗／WebDAV 或 PC 上傳需處理系統通知：`A/DeliveryNotify.java:12–31`；`A/CaptureService.java:195–196,221`；`A/DavBackup.java:163,200` | **缺少**：iOS 來源沒有 UNUserNotificationCenter | iOS 請求通知授權、一次／場次去重、app 內 banner／合適本機通知，點通知進入相關場次／目的地。實際 Android `finished` 是接收完成，不是「所有云端交付完成」。Drive／OneDrive worker 未直接調用 `DeliveryNotify.issue`，不可聲稱已有全 provider 統一交付完成推播。 |
| N02 | 接收中常駐通知、可按停拍；Drive／OneDrive 常駐通知可按暫停：`A/CaptureService.java:54–65`；`A/UploadService.java:28–35`；`A/OneDriveService.java:27–35` | **平臺適配** | iOS 前景狀態／可達停止與暫停入口＋適合的本機通知；不得承諾有 Android 常駐 foreground-service 通知欄或通知動作能在鎖屏持續 USB。 |
| N03 | 新拍／卡內 JPG 兩種模式、USB 權限、相機多候選選擇：`A/MainActivity.java:166–196` | **已有兩模式／部分相機選擇**：`I/RootView.swift:205–244`；`I/Camera/CameraCaptureService.swift:72–137,229–236,541–546` 自動開第一臺 | 保留新拍基線與 card mode；若多個設備同時出現，等效可選一臺（不是多機同時拍攝）。iOS 內容／控制授權是自身流程，不能複製 Android USB permission broadcast。 |
| N04 | 重新搜尋照片及重試、停拍後排空、確認強制中止、未完整 JPG 不算成功：`A/MainActivity.java:80,96–97`；`A/CaptureService.java:68–73,156–168,395–440` | **已有主要流程**：`I/RootView.swift:71–74,239–242,370–373`；`I/Camera/CameraCaptureService.swift:140–204`；`I/Camera/PTPPhotoReceiver.swift:102–153,228–279` | 不迴歸 build41。iOS PTP 有最後完整掃描；native 僅排空已排隊文件，應明確 native final discover／drain 是否滿足停拍後未見到的最後圖，必要時補 user-workflow 保證，而非改相機寫協議。 |
| N05 | 卡內匯入「這張傳完即暫停／下次接著傳」、持久完成清單、已經排到目標的跳過並補到新目標：`A/MainActivity.java:111,166–179`；`A/CaptureService.java:82–126,132–138,189–193,260–375,400` | **缺少持久續收**：iOS handled／queue 是 receiver 內存，重開清空；`I/Camera/CameraCaptureService.swift:72–83`；`I/Camera/PTPPhotoReceiver.swift:36–44,138–153` | 用戶可在 card mode 暫停而不強制排空整卡，保存已完成身份／剩餘／目標 receipts，重連續收、不必整卡重新下載後才由 session name＋hash 去重。Android 部分去重只按 camera filename／handle，不能照抄造成跨卡同名漏傳。 |
| N06 | 非乾淨停止後新拍模式自動補收上一場未完成照片，handle 重新編號則警告：`A/CaptureService.java:100–124,235–259`；`A/ReceiveQueue.java:18–25` | **缺少**：iOS 斷線指引改選 card，`I/Camera/CameraCaptureService.swift:554–559`；新拍會把當前目錄重新當基線 | 持久 receive checkpoint、識別仍同相機／卡的可恢復文件、無法可信匹配時告知從 card 補收；不聲稱任意 handle 重編號都能完美對上。不涉及 camera write。 |
| N07 | 補掃間隔 2s／5s／0.5s，現場 notes：連拍、JPG 大小、卡槽、線材：`A/MainActivity.java:92–95,192–195`；`A/SessionReport.java:30` | **缺少設置／notes**：native 與 PTP 目前固定 2s，`I/Camera/CameraCaptureService.swift:132`；`I/Camera/PTPPhotoReceiver.swift:76` | 若追求全部可比流程，增加輕量頻率／notes（運行中鎖定，卡 mode 安全下限）；不要為倍率相同而破壞 idle-only scan 和不會餓死下載的保護。 |
| N08 | 診斷畫面可見已驗證／待收／驗證中／失敗／非 JPG、USB／全程 MB/s、累計 bytes、基線、最新 latency／文件、機型／設備診斷：`A/MainActivity.java:152–158,251` | **部分**：`I/RootView.swift:364–384` 有授權／目錄／待收／失敗／日誌／版本，缺階段量測與 notes | 等效顯示準確接收計數／速度／空間與可分享設備診斷；速度來自時間戳，不可 raw USB benchmark 冒稱真實整體速度。USB Host／native_usbfs 自測是 Android 實現專屬，不列為必須同代碼。 |
| N09 | 口袋黑畫面、調暗並保持屏幕開：`A/MainActivity.java:159–164` | **部分且有清楚平臺提示**：`I/RootView.swift:61–69,247–256,419` 黑畫面＋接收前景 idle timer；未降 brightness | 可選屏幕亮度保存／恢復，讓 app 內口袋模式更省電；退出／inactive 必恢復。不能把口袋模式稱作鎖屏／後臺 USB。 |
| N10 | 背景傳送恢復、OS 時間上限時告知重開繼續，PC／DAV 持久 job 重新調度：`A/ConsoleActivity.java:16–35`；`A/UploadService.java:124,162`；`A/OneDriveService.java:117`；`A/DavBackup.java:140–169` | **部分／平臺適配**：root active 才自動 dispatch；WebDAV 明示 foreground；PC 無耐久每目的地任務 | 對已經落盤的 JPG 可以設計 iOS 允許的網絡後臺傳送／前景恢復，但要明確可用範圍，app 被 OS suspend 後不保證持續；USB 必保持前景／不鎖屏。不可借 push／BGTask 無限延長接收。 |
| N11 | 提示僅 JPG／RAW 不傳／保留相機原檔／實驗相機範圍與版本：`A/MainActivity.java:101–102,123,174–177`；`A/CaptureService.java:58–59` | **已有基本說明**：`I/RootView.swift:141,217,380`；Info usage／PTP 註釋 | 保留 read-only、安全說明，產品文字與真實成功機型／build 證據一致。不能因為 Android CameraProfile 名單存在就宣稱 iOS 各品牌已實測。 |

## 7. 父層 UI 整合：WebDAV、首頁、詳情與 cross-provider 狀態

### 7.1 WebDAV（直接供應商，而非分享捷徑）

| ID | Android 真實使用者功能與精確來源 | iOS 狀態／對應落點 | 缺口／約束 |
|---|---|---|---|
| U-W01 | 既有 HTTPS folder／帳號／應用程式密碼，保存並啟用、停用：`A/OtherClouds.java:137–150`；`A/DavBackup.java:70–104` | **已有，且 iOS 明確 opt-in 更安全**：`I/Transfer/WebDAVSettingsView.swift:30–105`；`I/Transfer/WebDAVStore.swift:116–139` | iOS 保存只驗格式，未測試遠端；自動上傳預設關閉。不同預設不等於功能缺少，不能把保存成功叫連線已核對。 |
| U-W02 | 已收原圖獨立排隊、自動傳、profiles 去重、app 重啟／重新選同目的地可恢復：`A/DavBackup.java:30–32,73–88,105–110,171–204` | **已有**：`I/Transfer/WebDAVStore.swift:18–37,65–108,156–272` | iOS 已是每 job destination snapshot、相對 Documents 路徑、獨立狀態；不要改寫成共用 PC Bool，也不要把舊目標重定向到新配置。 |
| U-W03 | create-only PUT、同名已存在回讀核對、GET bytes＋SHA：`A/DavBackup.java:239–268` | **已有**：`I/Transfer/WebDAVStore.swift:411–448` | 僅完整 GET 大小／SHA 一致才 verified；碰撞不覆寫，所有 redirects 拒絕；只信系統 TLS，Keychain credentials 不預填／不記錄。實際服務器必須已有可 PUT／authenticated GET folder，不新增 NAS 瀏覽、自動建文件夾、任意 SSL 信任等 Android 沒有的功能。 |
| U-W04 | 服務狀態、自動網絡恢復／重排：`A/DavBackup.java:140–169,197–214`；`A/OtherClouds.java:52–53` | **核心已有，恢復部分**：iOS 前景 pump、failed 需手動 retry，`I/Transfer/WebDAVStore.swift:141–154,201–272` | 可增加有限自動 transient retry／可達 pause/continue；不能不停錘服務器。當前 iOS 重試按鈕與失敗計數已經比 Android WebDAV 頁更細，不能把這些當不存在。 |
| U-W05 | WebDAV 場次交付統計：`A/ShootDetail.java:151–152,216–222` | **缺少 root／場次整合**：`I/RootView.swift:135–145,260–299` 不使用 webDAV 的完成計數，設置 sheet 只顯示目前配置累計 | 首頁目的地要列出已啟用 WebDAV；單場詳情顯示這一場 WebDAV jobs／verified／failed。現有 store 有獨立 job、但 UI `activeJobs` 是配置累計，不是本場。 |
| U-W06 | 本場目標生效時間：Android openReport 快照 `davProfile`，`A/CaptureService.java:202–209,232` | **部分並有語意差異**：`I/RootView.swift:414–417` 每次 auto trigger `enqueue(session.photos)`，會把所有累積舊圖送到當前 WebDAV config | iOS toggle 文案說「新收到」，但開啟／改配置可能排入全部舊圖。需依新 arrival／本場 opt-in 快照排隊，另提供「本場／歷史加入」明確確認；不要靜默把舊照片增送到新 destination。 |

### 7.2 父層統一導航與狀態

| ID | Android 真實使用者功能與精確來源 | iOS 狀態／對應落點 | 缺口／驗收 |
|---|---|---|---|
| U01 | 同一傳送目的地頁列 Google Drive／OneDrive／PC（×2）／WebDAV、installed sharing Apps、本機原圖／加入目的地：`A/OtherClouds.java:36–86` | **部分**：`I/RootView.swift:302–359` 只有 PC 真 controls、WebDAV sheet、兩鎖定提示及總分享 | 真正 Drive／OneDrive settings entry，明確「直接上傳」與「交給其他 App」，signed-in≠auto enabled≠本場已排隊≠已完成；不需要無意義複製加號 grid，而要整條可用導航。 |
| U02 | 首頁顯示本場／下次開拍目的地、複數路線、固定／活動 folder、暫停狀態、電腦×2：`A/MainActivity.java:132–145` | **缺少完整 route summary**：`I/RootView.swift:135–145` 永遠只按 PC ready 顯示「電腦／只存 iPad」 | 即使僅啟用 WebDAV，現首頁也誤報僅本機。所有 enabled destinations＋實際場次 snapshot 應共用可測試 route model，開拍前預覽與拍中實際一致。 |
| U03 | 首頁最新圖＋已收／待傳／核對／進度＋錯誤，停拍後活動交付說明與 folder 按鈕：`A/ShootPanel.java:43–74,127–249` | **部分**：`I/RootView.swift:149–184` 只 PC metrics | 可切目的地或明確顯示每目的地計數／完成範圍；本機 receive count 與 N 目的地 jobs count 不混淆；error 能跳場次詳情／修正設置。不能第一目的地完成就宣稱全交付完成。 |
| U04 | 底部首頁／紀錄／傳送／更多，橫屏右側導航與照片／controls 分欄：`A/MainActivity.java:55–63,86–89`；`A/LightScreen.java:50–62` | **已有主要佈局**：`I/RootView.swift:26–45,97–125,388–407` | 不需像素複製 Android；保持 iPad 橫豎佈局、可讀 button、VoiceOver／觸控面積，新增 provider 頁面要真能進入、返回且不終止接收。 |
| U05 | 改賬戶／folder／auto 時鎖定必要危險操作、下一輪生效／當前場次不誤重派：`A/CloudActivity.java:82–95,156–159`；`A/OneDriveActivity.java:61–64,88–89`；`A/CaptureService.java:202–209` | **部分**：pair 可運行中改／clear；WebDAV 更新有取消，但 root 無統一場次 snapshot | 定義正在接收／上傳時配置變更行為、busy/disabled/cancel/confirm；不能因換 PC／登錄回調對現 drain 用錯目的地。新場配置與歷史 job target 分離。 |
| U06 | JPG 接收與各目的地相互獨立，即雲端排隊失敗也保留成功原圖：`A/CaptureService.java:212–233`；`A/CloudStore.java:135–159` | **已有方向／待擴充**：camera ingest→session；WebDAV 獨立、不改 PC `uploaded` | Drive／OneDrive 接入應依同一完整 `ReceivedJPEG` identity 排獨立 jobs，error 不影響 received；provider failure、一個 PC failure、共享 App 不支持，都不能阻斷 USB 或別的 destination。 |
| U07 | 用戶關閉再打開 App 仍能完成拍攝／交付歷史與補傳：Android per-session reports＋durable DB／markers | **部分且恢復風險**：`I/Session/ShootSession.swift:23–39` 從絕對 photo URL `fileExists` 過濾；`I/Camera/ReceivedJPEG.swift:6` 存 URL；只保存一個 snapshot | 正式場次模型／相對 Documents 路徑、atomic 保存與損壞可見警告、照片落盤但 ingest 尚未寫入時可恢復索引。若 iOS container 路徑變動，現絕對 URL 可能讓文件被過濾；這是源碼風險，非這次實機已觀察到的丟圖。不得破壞已成功照片或 quiet 清空損壞記錄。WebDAV 已有相對路徑良好範例。 |

## 8. 不應新增為「Android 已有功能」的項目

1. **相機 Wi-Fi／FTP／LUMIX 無線接收已從當前 Android 使用流程移除**：`A/CaptureService.java:48–49` 會拒絕舊 `wifi_tree`；`A/MainActivity.java` 的「＋連接」實際 USB 選擇。Manifest 保留 lumixlab query、SessionReport 留 wifi 構造參數或測試名 `WirelessChecks` 都不是可達當前無線接收功能。PC 同 Wi-Fi 傳送仍是真功能，不能混為相機無線接收。
2. 沒有 shutter／live view／遙控曝光、相機設置寫入、刪除／格式化相機卡、RAW／video transfer；不能把全部 PTP opcode parity 當「把所有功能實作」。`I/Camera/PTPPhotoReceiver.swift:3–4` 亦明確禁止 vendor／shutter／destructive commands。
3. 不需要將 Dropbox／Box／Google Photos／Flickr 虛構成原生 direct provider；Android 實際只是 picker＋特定 App 分享，沒有這些供應商的 OAuth／獨立自動上傳／結果核對。
4. 不應聲稱 Android 已有任意 Drive 深層瀏覽、任意 OneDrive 完整分頁、多帳號同時自動上傳、多 PC 完美獨立詳情／CSV、所有 provider 統一推播、OneDrive 總有 SHA、WebDAV 自動建 folder、任意不安全 TLS、public internet receiver、用戶刪除場次／照片、編輯／濾鏡／評級。相關 staging cleanup／測試工具不是這些用戶功能。
5. 分塊大小、native usbfs／Apple session ownership、Java vs Swift、協議初始化序列、threadpool 數量，不是本盤點對等單元。以用戶是否能「接收完整 JPG→保存→排到選定目的地→斷線／重開後繼續→確認交付→回看／分享／匯出」為驗收。

## 9. 實作與驗收順序建議（供父代理整合，不表示已修改）

### P0：把兩大直接 provider 做成真可用，保住 build41

先定義獨立 provider config／account／folder／job／receipt，接 Google／Microsoft iOS 授權回調及 Keychain；補登錄／選建 folder／活動 folder／手動＋auto／pause＋resume／network policy／retry＋錯誤。原圖依據 `ReceivedJPEG` 身分不重壓，完成核對層級誠實顯示。Root 替換 locked placeholder，並整合實際 enabled destinations。複用既有已驗證 USB ingest；provider 不可控制相機／改 receive status。

### P1：兩電腦＋場次／歷史／相簿／匯出

把 `uploaded` 單 Bool 遷移為每 PC fingerprint／slot receipt；補第一／二部管理與明確歷史補傳。建正式 session registry，遷移所有既有圖片／舊 session snapshot，開拍與停拍形成新／完成場次、名稱搜索／rename、場次詳情、多圖 viewer、CSV、原圖多選系統分享／Files／Photos 導出。補斷線 receive checkpoint／card 暫停續收和持久診斷。WebDAV 接到正確本場 opt-in，不暗送全部舊圖。

### P2：通知、診斷計時、口袋與恢復細節

本機通知／前景 banner、真正階段耗時／速度、notes／掃描頻率、網絡變動可恢復、口袋 brightness 安全恢復。確認 busy 狀態／危險變更與前景限制的可用 UX。

### 最低端到端驗收矩陣

- 真機新拍基線仍維持既有 5 JPG／0 failed／PC 收原圖；MPF／EXIF／SHA 不迴歸。對已落盤的本機圖做 provider 上傳，不依賴每次重新接 USB。
- Drive／OneDrive 各自：實際授權成功／取消／錯用戶／撤權／token 更新；根／固定 folder 選建，活動模式空名行為，離線開拍後續傳；Wi-Fi only／cellular opt-in；上傳中暫停／斷網／App 重開；限流／expired upload session／folder deleted／同名不同圖；確認真實 remote bytes／核對層級。
- PC 1＋PC 2：兩邊都 receipt；一邊 503／未開不阻另邊；換 fingerprint、新電腦補傳舊已驗證照片；只 PC 補傳不觸發其他 provider；單部／全部停用不刪原圖與歷史。
- WebDAV：有效服務器和真實 credentials 的 PUT＋GET；412 相同內容核對，412 不同內容拒絕，401／403／404／redirect／TLS／網絡中斷可修復；改配置不 retarget 舊工作；auto 只排明示範圍。
- 場次：兩次接收形成兩個場次；搜索／rename／列表與覆蓋圖，收到新圖時保留正在看舊圖、左右瀏覽／pan／回最新；選一／多張／本場分享／原圖導出與取消；CSV／JSON／diagnostic 無憑證；force stop、card pause、重連續收與重開後不丟歷史。
- 上述 live provider 驗收需授權帳號／遠端目標，不可把 mock tests、編譯成功或 sheet 出現當功能完整。

## 10. 必須保留的特殊約束與交付路徑

**沒有 Mac 的用戶不需被要求本地 Xcode**。repo 的 `codemagic.yaml:87–163` 已有 `ios-testflight-internal`（App Store Connect integration、簽名 IPA、TestFlight Internal），`codemagic.yaml:1–85` 有 device-only unsigned smoke 及 PTP／JPEG／MPF tests。`ios/project.yml:26–34` 以 `hk.camlink.ios`／committed Info.plist 為基準。後續用 Codemagic／TestFlight 真機驗證，不操作本地 Mac；本稽核沒觸發任何 CI。

Google：`A/CloudAuth.java:14` 為 `drive.file`；當前 iOS Info.plist 僅 `camlink` 配對 scheme。需取得／建立符合 `hk.camlink.ios` 的 Google iOS OAuth client，註冊精確 callback（及合適 SDK config）、啟用 Drive API、測試用戶／同意畫面，確認同項目帳號授權範圍。**不把 client secret 放 App；不可用 Android SHA-1 client 冒充 iOS 註冊完成**。這是配置／帳號依賴，不是靠 locked UI 能解決。

Microsoft：`A/OneDriveApi.java:12–16` 有 public client ID，實際授權 redirect 為 `work-camera://onedrive`；但 `app/src/main/AndroidManifest.xml:33–39` 僅宣告 `camlink://onedrive/callback`，Android 透過 `OneDriveLogin` WebView 可攔另 scheme。`I/Info.plist:23–33` 沒有 `work-camera` 註冊，`I/RootView.swift:52–60` 又把所有 onOpenURL 當 PC QR。iOS 必須核實 Entra／Microsoft 註冊真實允許精確 public-client callback，使用原生 external session＋PKCE/state，不盲加共用 scheme 讓 Gonfolio／其他 App 搶回調，也不能聲稱現有 client id 證明 iOS callback 已獲配置。處理 OAuth 與 PC deep link 要明確分流。

**iOS／iPadOS 不保證鎖屏／後臺／切 App 時 USB 接收**，即使通知權限、口袋黑畫面、網絡後臺 URLSession／BGTask 正常也不改變此限制。前景且屏幕開啟是現有可靠操作路徑；網絡傳送只作用於已經驗證落盤的 JPG。PhotoKit／Files／分享 extension availability 同樣依用戶權限和安裝服務。

**禁止 vendor-specific camera-write 操作、相機拍攝／屬性修改／刪卡**。保留 Apple 管理的 session 與當前唯讀標準 PTP 接收；不能為追求品牌／後臺「對等」繞過讀寫授權、重開 Apple session 或在 native 與 raw PTP 間並行下載。

已確認本機原圖必須保留。每目的地有自己的真實核對紀錄；Drive／OneDrive auth error、share 取消、WebDAV fail 不應使 camera.failedCount 增加。設置保存、OAuth 登錄、HTTP 成功、第三方 App 分享完成、原圖已存本機、Receiver SHA 核對、雲端 GET 核對都是不同狀態，不可合併為一個成功宣稱。

## 11. 來源覆蓋索引

- Android 用戶畫面與導航：`MainActivity.java`、`ShootPanel.java`、`ShootDetail.java`、`SessionAlbum.java`、`ReviewPhoto.java`、`OtherClouds.java`、`CloudActivity.java`、`OneDriveActivity.java`、`ConsoleActivity.java`、`LightScreen.java`、`PairLink.java`、`OneDriveLogin.java`、`OneDriveCallback.java`。
- Android 用戶流程服務／儲存：`CaptureService.java`、`ReceiveQueue.java`、`CloudAuth.java`、`CloudStore.java`、`DriveApi.java`、`UploadEngine.java`、`UploadService.java`、`EventFolder.java`、`CloudNetwork.java`、`OneDriveAuth.java`、`OneDriveApi.java`、`OneDriveStore.java`、`OneDriveService.java`、`DavBackup.java`、`PcLink.java`、`Gallery.java`、`SessionNames.java`、`SessionReport.java`、`SessionExport.java`、`PhotoTimes.java`、`DeliveryNotify.java`，以及 Manifest 的可達 declarations。
- Android 底層 `CameraProfile.java`／`Ptp.java`／`UsbWire.java`／`NativeUsb.java`／`JpegCheck.java`／`InternetRoute.java` 屬於對應接收／安全／網路流程實現，協議差異不逐 opcode 盤點。androidTest／test 的工具、舊測試或名字不是新增產品功能證據。
- iOS 實際對照：`RootView.swift`、`Session/ShootSession.swift`、`Transfer/PairStore.swift`、`Transfer/PcClient.swift`、`Transfer/WebDAVStore.swift`、`Transfer/WebDAVSettingsView.swift`、`PhotoPreview.swift`、`Camera/ReceivedJPEG.swift`、`Camera/CameraCaptureService.swift`、`Camera/PTPPhotoReceiver.swift`、`CamLinkApp.swift`、`Info.plist`，加 `ios/project.yml`／`codemagic.yaml`／`ios/CLOUD_PARITY.md`。後者舊 build37 文字只作約束背景，不覆蓋本次 build41 真機成功基線。
