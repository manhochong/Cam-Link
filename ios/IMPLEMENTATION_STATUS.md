# Cam Link iOS 功能補齊狀態

更新：2026-11-09 01:01（香港時間）。`0.2.25 (42)` **已可從 TestFlight 內部群組安裝**；這不代表所有功能已通過實機驗收。

## 可用基線

最新內部 TestFlight 是 `0.2.25 (42)`。使用者先前已在 build 41 確認卡內 MPF JPG 與電腦接收成功；新版保留該標準 PTP、JPEG／MPF 原圖驗證與 Receiver 協定。新拍模式仍需另測卡內→停止→新拍的生命週期，不能把 build 41 的卡內成功當成新版新拍驗收。

## 外部註冊已核對

Google：既有 `work-camera-512615` 專案中的獨立 Cam Link iOS Drive Client；Bundle ID `hk.camlink.ios`，Apple Team ID `4CMUH5G2T5` 已從實際 provisioning profile 核對，Drive API 已啟用。公開設定見 `OAuthClients.json`。Google Sign-In 官方套件固定 `10.1.0`，Google Audience 已查看但沒有擅改共用專案的同意畫面或發布狀態。

Microsoft：已在 `gonfoliocontactgmail.onmicrosoft.com` 建立獨立 **Cam Link iOS**。Client ID `16437f88-79e4-499f-8cb3-7f07c9146e0c`、原生回呼 `msauth.hk.camlink.ios://auth`、個人及組織帳戶、五個 Graph 委派 scope 已從下載的已保存 manifest 核對。詳見 `AZURE_REGISTRATION.md` 與 `AzureRegistration.json`。沒有改動 Gonfolio／Android 註冊、建立 client secret、購買服務或授予目錄管理員同意。

## 已接入、編譯並分發內部測試的功能

- 共用 OAuth：系統登入、PKCE、state／精確 callback、Keychain、刷新／取消與 redirect 保護；Google SDK 和 Microsoft 共用互動登入鎖。
- Google Drive：正式 SDK 登入、資料夾選建、活動目的地、整檔原圖、耐久分段佇列、暫停／續傳／重試、MD5／SHA 或整份下載核對、獨立紀錄。
- OneDrive：正式原生 OAuth、Graph 帳戶與預設 drive、資料夾選建、320 KiB 對齊續傳、衝突保護、server SHA-1／SHA-256 或整份下載 SHA-256 核對。不同核對層級不互相冒充。
- 雙電腦：保留主槽配對、獨立第二槽、逐 fingerprint／revision／場次／照片收據、有限退避、指定場次補傳、逐槽網路政策。舊單一 uploaded 旗標不能證明第二部成功。
- 活動與匯出：新活動／歷史搜尋、名稱／備註／封面、相簿、大圖翻頁／縮放／拖移、多選原圖分享／Files／Photos、CSV／JSON／文字報表。新增固定 `ZIPFoundation 0.9.20` 串流 ZIP，匯出前後核對整檔 SHA，保留 MPF 全部 bytes，不重新編碼。
- 偏好與主題：深海藍／青綠高對比原生 UI、首張與完成事件、可選通知／聲音／觸感、容量警告、補掃頻率、每目的地 Wi-Fi／高成本／低數據限制。隱私 manifest 和 Photos 用途說明已加入。
- 相機生命週期：fresh browser、cached device reconciliation、不可變 delegate owner 和安全關閉屏障；不新增廠商寫入、刪卡或拍攝命令。

真正的雲端設定、雙電腦、歷史與偏好頁已從 RootView 可達，由單一 CamLinkRuntime 注入。自動加入只針對新驗證圖，明確歷史補傳另行選擇，雲端錯誤不影響本機原圖。

## 整合修正與已取得的驗證

來源 `511d74e` 的乾淨 Codemagic smoke `6af0a7fc24e1ec2375579530` 已於 2026-11-08 16:52 UTC 完成，狀態為 `finished`。真正 Mac 同一輪通過 lifecycle 179 項、OAuth 126 項、回饋 138 項、Google 78 項、OneDrive 注入式檢查，以及雙電腦、活動／真實模型和 ZIP 原圖保留回歸。PTP、JPEG、MPF 回歸亦成功。這些是離線測試，不是帳戶或硬體端到端成功。

整合修正涵蓋：接收完成必須等待 drain 與原生 close；中斷維持未完成；成功回條必須先持久化；每個目的地保留獨立證據；政策暫停不覆寫使用者暫停；歷史重試精確限定照片與場次；request 套用最新網路限制，session 不凍結舊設定。首頁回饋欄位和檔案保護 SDK 名稱已修正。

OneDrive 新增的政策取消測試曾因重用已登出的 OAuthCoordinator 而在進入 transport 前失敗；mock vault 重新寫入不能清除登出 tombstone。測試已改以新 coordinator 表達冷啟動，原本的 transport-start、取消和重試斷言不變；上述乾淨 Mac 回歸已確認通過。

完整 App 已在上述 smoke 使用 iPhoneOS SDK、正式 Google Sign-In 和 ZIPFoundation 套件編譯成功，並對最終 `.app/Info.plist` 通過 metadata 檢查，日誌輸出 `unsigned iphoneos build ok`。Swift 5 模式仍有 ObservableObject actor conformance／Sendable 警告；不能宣稱 Swift 6 嚴格模式無警告。

同一確切 commit `511d74e` 的內部建置 `6af0a93269d77cbbeb6352b7` 已完成測試、簽名 IPA 與最終 metadata 檢查。Apple uploader 於 2026-11-08 16:58:54 UTC 回覆 `UPLOAD SUCCEEDED with no errors`，版本 `0.2.25`、build `42`。

2026-11-08 17:00 UTC 已以既有授權 App Store Connect API 確認：`processingState=VALID`、`buildAudienceType=INTERNAL_ONLY`、`usesNonExemptEncryption=false`、未過期。已加入原有 `CamLink Internal`（沒有新建群組、增加測試者或公開發佈），再次核對 membership 且 `internalBuildState=IN_BETA_TESTING`、外部測試不適用。可於 iPad TestFlight 更新。

Codemagic 的簽名／上傳成功，但其後處理顯示失敗；沒有因此重傳或使用同一 build 編號重建。上述群組加入與最終可測試狀態以 Apple API 的實際結果為準，不宣稱該 workflow 全部綠燈。

舊臨時 SSH 金鑰與來源封裝已清理，私人照片與工作筆記沒有提交。操作次序見 [build 42 實機測試](BUILD42_TEST_GUIDE.md)。

## 必須保留的能力界線

仍需簽署 iPad 實測 Google／Microsoft consent、callback、refresh、選建資料夾、原圖傳送／讀回及斷網重啟；兩部 Receiver 與真實 WebDAV 亦需各自驗收。Google `drive.file` 只能存取 App 可見檔案／資料夾，不能聲稱可瀏覽整個 Drive。Dropbox／Box／Google Photos／Flickr 是系統分享，取決於已安裝 App，不是本 App 原生 API 或可核對的遠端交付。

iOS 鎖屏／背景／切 App 不保證 USB 常駐；口袋模式是前景黑畫面。耐久接收續收、相機不發事件的新拍等硬體情境仍需具體驗收，不因離線測試而宣稱完全一致。原始私人 JPG／ZIP、Apple 憑證私鑰和登入權杖不加入 Git 或公開產物。私人 OTA 網頁不在本次公開發布範圍。
