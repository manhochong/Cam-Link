# LUMIX 無線直連驗證版 0.2.24

## 目的及目前範圍

目標：相機 → Wi-Fi → Cam Link → DCIM/CAM LINK → 既有 Google Drive 佇列，不經品牌 App。

本版是標準 PTP/IP 接收與診斷原型。S1M2、S1R2 **未經本版實機連線、JPG 收取、連拍完整性或拍攝影響驗收**。Capture One 官方指出新款 LUMIX 無線 Tether 使用新增的加密協定。本版未實作該私有驗證，標準連線可能被相機拒絕；不能將 USB 已成功的紀錄當成 Wi-Fi 相容性證據。Bluetooth 配對、BLE 喚醒、品牌 App 中轉皆不屬於這個新增入口。

## 使用

1. 先確認相機沒有正在接收或上傳的工作。保留相機卡內原檔。
2. S1R2 使用者回報韌體 1.6。官方新版手冊列出：設定 → IN/OUT → LAN/Wi-Fi → Wi-Fi 功能 → 新連線 → Tether → 直接連線 → 手動連線。
3. **「LAN/Wi-Fi 設定」是另一個子頁**，裡面只有頻段、裝置名稱／密碼和網絡地址等。使用者提供的畫面屬於此頁；先返回一層核對。若實際上層選單仍不同，保留照片確認，不盲目更新或重設相機。
4. 手機在系統 Wi-Fi 設定連上相機 SSID；即使沒有網際網路也保持連線。USB 可保持接電腦作日後診斷。相機不必接手機 USB。
5. Cam Link → ＋連接 → Wi-Fi 接收 → LUMIX 直接連線 · 實驗版。輸入相機的私人 IPv4 地址；預填的 192.168.54.1 只是常見值，以機身顯示為準。
6. 按「測試連線」，輸入活動名稱。只有成功讀到相機身份、必要讀檔能力並完成基線，才顯示「可以試拍」。此前不要拍攝。
7. 先試一張。確認本機完整 JPG，再測少量連拍。停拍後按「停拍並完成接收」等補掃及驗證結束。尚未要求 100 張測試。
8. 若失敗，首頁顯示原因；進階操作可匯出最近接收報告，即使該場 0 張而未列在歷史列表也保留報告。

## 實作要求與結果

- 每個相機 socket 單獨綁定可到達相機 IP 的 Wi-Fi Network，不綁定整個 App。Drive 不再只看預設網絡：CloudNetwork 選擇有 INTERNET、VALIDATED 並未暫停的網絡，逐個 HTTP 請求使用 Network.openConnection；包含上傳、續傳查詢、資料夾及帳戶資料核對。
- 有可上網的 Wi-Fi 優先使用；相機 Wi-Fi 沒有網際網路而且「只用 Wi-Fi」關閉時，主動請求並維持流動網絡。服務結束釋放請求；只用 Wi-Fi 開啟時不請求流動網絡，不能用無網際網路的相機 Wi-Fi 冒充可用網絡。啟用 VPN 時不繞過預設 VPN。
- 上傳介面顯示實際選用的 Wi-Fi／4G／5G。網絡消失／切換保留原 file ID、續傳網址與已確認 offset，等待恢復，不因離線耗盡八次重試。取得新授權仍由 Google Play services 處理，無法指定該外部服務的 socket。
- 手機需開啟流動數據且有可用 SIM／方案；是否可同時維持相機 Wi-Fi 及流動上傳須實機驗證。若沒有流動數據，可待結束相機連線後上傳，或在機身支援時使用相機及手機同連有網際網路的路由器。本版不自動切換或斷開相機 Wi-Fi。
- 標準 PTP/IP 雙通道初始化，命令與事件連線，Ping 回應、事件觸發補掃，2 秒定時清單核對。
- 僅允許 GetDeviceInfo、OpenSession、CloseSession、GetStorageIDs、GetObjectHandles、GetObjectInfo、GetObject。沒有刪相、改拍攝模式、遙控快門或猜測廠商 token。
- 以原始 ObjectInfo 大小接收，分塊串流寫入 .part；檢查交易 ID、資料順序、完整 EndData、總長度及檔案大小上限，再沿用 JPEG 結構、尺寸、SHA-256 核對與發佈流程。縮圖不作原圖下載來源。
- 全卡清單成功才建立基線；本場發現去重；忙碌回覆有限次重試。斷線停止接收並保留報告／部分檔案，不宣稱自動重連或已補齊斷線期間照片。重開一場會建立新基線，因此斷線漏收須先依紀錄處理，不可直接重開後當作已補收。
- 未知配對／加密回覆停止並提示需適配，不把 TCP 接通視為可以拍攝。
- 預期檢查：主機傳輸測試、既有 Drive/FTP 測試、Android lint、APK 簽章。這些都不等於實機驗收。

## 下一個必需驗證

使用者完成相機網絡設定後，取得實際的連線結果。若回覆 LUMIX_PTP_AUTH、LUMIX_PTP_INIT 或持續逾時，須研究該機身私有驗證／合法 SDK 接入方式，不能靠更改 UI 標示解決。

此次裝置紀錄：手機讀取最初被拒絕；其後使用者明確允許更新 Sony 並檢查。Sony XQ-BE72 已原地更新 0.2.24，package 回讀 versionCode 31；兩個 SIM 狀態均 ABSENT，Wi-Fi IP 為 192.168.50.23。執行新增的只讀診斷前 Sony USB 離線，故該診斷並未執行。使用者選擇相機與 Sony 共用有網際網路的路由器；相機提供 IP 192.168.54.1，並確認畫面只顯示相機 SSID／密碼，仍屬直接 AP 模式，等待切換 Via Network。以上均不是無線收相或上傳成功的證據。

主機驗證：37 項 Gradle 單元測試、80 項核心檢查、12 項卡檔比較測試通過；lint 0 errors / 27 warnings；APK 簽章通過。驗證收據在 artifacts/wifi-0.2.24/validation.json。

後續 Sony 接回電腦後的實測：只讀 network_route 檢查成功，Wi-Fi 有 INTERNET / VALIDATED，Drive about 查詢成功且 permissionId 與已選帳戶相符，未建立任何雲端檔案。這證明家用 Wi-Fi 上的 Drive 讀取路由可用，**不是相機 Wi-Fi 與流動數據同時工作或照片上傳的驗收**。

最新場次 20261106-004028-72599b 為 LUMIX_WIFI 網段不符：Sony 192.168.50.23，App 儲存的相機目標 192.168.54.1。更早場次 20261106-003515-9dd12a 通過 Wi-Fi 路由選擇後得到 LUMIX_CONNECT，未進入相機身份或 JPG 讀取。原報告已保存在 artifacts/wifi-0.2.24/sony-latest 與 sony-connect-failed。家用網絡標準 SSDP 探索沒有找到 LUMIX 回覆，這不能證明相機不在該網絡。

新增只讀 lumix_probe instrumentation 已編譯並安裝測試 APK：僅在 192.168.54.1 所在 Wi-Fi 上檢查已知相機服務埠、getstate、UPnP 裝置描述，無配對寫入、模式切換或原圖下載，不記錄密碼或完整裝置序號。使用者表示暫時不能把 Sony 切換到相機 Wi-Fi，所以此探測尚未執行；等待使用者方便再測，不自動切換手機網絡。

## 2026-11-06 實機診斷更新

以上「探測尚未執行」為較早狀態，現已完成。使用者再次連上相機 AP 並允許診斷後，Sony 經相機 Wi-Fi 讀到 DC-S1RM2、韌體 1.60；完整結果在 `artifacts/wifi-0.2.24/sony-camera-probe-cds-2.txt`。

- 80、443、60606、50001 埠可接通；相機描述宣告 PTP 埠 15740，但連該埠得到 ConnectException，未建立 PTP 會話。
- UPnP 裝置描述與服務定義可讀，TLS 1.2 連線成功。舊式 `/cam.cgi?mode=getstate` 在 HTTP 與 HTTPS 都回覆 404。
- 只讀 Browse 根目錄回覆 UPnP 701「No such object」。不能據此判斷卡內沒有照片，也不能單憑此回覆判定認證原因。
- 手機系統紀錄出現多次約 123 秒後的遠端 DEAUTH_LEAVING，之後返回家用 Wi-Fi。與相機等待配對後逾時相符，但確切原因尚未確認。
- 本次沒有傳送認證命令、改相機設定或下載照片。取得裝置描述不等於完成 Tether 配對；**此機身的無線 JPG 接收仍未成功**。

目前重點是取得並實作新版 LUMIX 無線 Tether 的配對／加密會話流程，不能靠重試標準 PTP/IP 解決。Capture One 官方說明此功能與 Panasonic 合作開發，採用新加密協定。檢查 Panasonic 公開 SDK 頁面後，列出的 Windows SDK 是 USB 為主、BGH1/BS1H 支援 Ethernet，未列 S1M2/S1RM2 或 Android 新無線協定；不能當成現成 Android 適配方案。這不代表必須以 Panasonic App 作日常中轉，但 Cam Link 尚缺可驗證的相容流程。

## 下一階段：向 Panasonic 申請開發接入資料

2026-11-06 使用者確認沒有可用 Capture One，選擇先準備向 Panasonic 索取協定資料。已準備英文詢問信 `Panasonic-Wireless-SDK-Inquiry.txt` 及可附寄的去識別診斷摘要 `Panasonic-Wireless-Diagnostic-Summary.txt`；**尚未寄出**。官方聯絡地址為 lumixsdkinfo@gg.jp.panasonic.com。該頁亦表明 beta SDK 不提供使用／技術問題支援且不保證回覆，因此信件定位為開發接入／合作窗口詢問，不假定對方會提供協定。

等待取得的必要資料：Android SDK 或跨平台協定、支援機型及韌體、探索與使用者確認配對、認證及憑證處理、加密會話、保持連線與重連、新照片事件與原始 JPEG 讀取、商用分發條款。未取得前不猜測驗證封包，也不把更多連線重試當作功能進度。

取得資料後依序實作及驗收：

1. 發現相機並顯示正式型號，完成使用者確認配對；配對資料不寫入診斷紀錄。
2. 建立並維持會話，確認不會在原先約兩分鐘時間點斷線，再驗證正常結束及重連。
3. 接收一張新拍的完整 JPG，核對尺寸、檔案大小與內容；卡內原檔保留。
4. 小量連拍核對張數、漏圖與拍攝影響，再接既有雲端佇列。此階段不要求 100 張測試。
5. 分別驗證相機／手機共用有網際網路路由器，以及具流動數據手機的相機 Wi-Fi／Drive 流動網絡分流。Sony 目前沒有 SIM，不能用它驗收流動上傳。

官方新版手冊 0195 明確寫出 Wi-Fi 需由 tethering software 選擇並連上相機；未公開封包格式。LUMIX Tether 下載頁的介面表仍只列 BGH1/BS1H 的 Wi-Fi，不能據此承諾該軟體可作 S1RM2 無線對照工具。

## 資料來源

- Panasonic S1R2 新版選單結構：https://eww.pavc.panasonic.co.jp/dscoi/DC-S1RM2/html/DC-S1RM2_DVQP3245_eng/0200.html
- Panasonic 新版 Wi-Fi Tether 操作流程：https://eww.pavc.panasonic.co.jp/dscoi/DC-S1RM2/html/DC-S1RM2_DVQP3245_eng/0195.html
- Panasonic SDK 官方聯絡窗口：https://av.jpn.support.panasonic.com/support/global/cs/soft/tool/sdk.html
- Panasonic S1R2 完整手冊（韌體更新章節）：https://eww.pavc.panasonic.co.jp/dscoi/DC-S1RM2/pdf/DC-S1RM2_DVQP3245_full_eng.pdf
- Capture One 官方說明新加密無線協定：https://www.captureone.com/blog/wireless-tethering-for-lumix
- Panasonic 公開 SDK 範圍：https://av.jpn.support.panasonic.com/support/software/tool/sdk.html
- PTP/IP 格式互通參考：https://github.com/gphoto/libgphoto2/blob/master/camlibs/ptp2/ptpip.c （僅參考封包格式，新增 Java 程式未複製該 C 實作）
- Android Network：https://developer.android.com/reference/android/net/Network#openConnection(java.net.URL)
- Android ConnectivityManager：https://developer.android.com/reference/android/net/ConnectivityManager#requestNetwork(android.net.NetworkRequest,android.net.ConnectivityManager.NetworkCallback)

