# Cam Link iOS 功能補齊狀態

更新：2026-11-09（香港時間）。本文件記錄候選 build 42 的來源整合，**不是已可安裝或所有功能已通過實機驗收的宣告**。

## 可用基線

現有 TestFlight 是 `0.2.25 (41)`。使用者已確認卡內 MPF JPG 與電腦接收成功；候選版保留成功的標準 PTP、JPEG／MPF 原圖驗證與 Receiver 協定。新拍模式的另一份診斷停在裝置探索，需另測卡內→停止→新拍的生命週期。

## 外部註冊已核對

Google：既有 `work-camera-512615` 專案中的獨立 Cam Link iOS Drive Client；Bundle ID `hk.camlink.ios`，Apple Team ID `4CMUH5G2T5` 已從實際 provisioning profile 核對，Drive API 已啟用。公開設定見 `OAuthClients.json`。Google Sign-In 官方套件固定 `10.1.0`，Google Audience 已查看但沒有擅改共用專案的同意畫面或發布狀態。

Microsoft：已在 `gonfoliocontactgmail.onmicrosoft.com` 建立獨立 **Cam Link iOS**。Client ID `16437f88-79e4-499f-8cb3-7f07c9146e0c`、原生回呼 `msauth.hk.camlink.ios://auth`、個人及組織帳戶、五個 Graph 委派 scope 已從下載的已保存 manifest 核對。詳見 `AZURE_REGISTRATION.md` 與 `AzureRegistration.json`。沒有改動 Gonfolio／Android 註冊、建立 client secret、購買服務或授予目錄管理員同意。

## 已完成來源與主畫面接線，待真正編譯

- 共用 OAuth：系統登入、PKCE、state／精確 callback、Keychain、刷新／取消與 redirect 保護；Google SDK 和 Microsoft 共用互動登入鎖。
- Google Drive：正式 SDK 登入、資料夾選建、活動目的地、整檔原圖、耐久分段佇列、暫停／續傳／重試、MD5／SHA 或整份下載核對、獨立紀錄。
- OneDrive：正式原生 OAuth、Graph 帳戶與預設 drive、資料夾選建、320 KiB 對齊續傳、衝突保護、server SHA-1／SHA-256 或整份下載 SHA-256 核對。不同核對層級不互相冒充。
- 雙電腦：保留主槽配對、獨立第二槽、逐 fingerprint／revision／場次／照片收據、有限退避、指定場次補傳、逐槽網路政策。舊單一 uploaded 旗標不能證明第二部成功。
- 活動與匯出：新活動／歷史搜尋、名稱／備註／封面、相簿、大圖翻頁／縮放／拖移、多選原圖分享／Files／Photos、CSV／JSON／文字報表。新增固定 `ZIPFoundation 0.9.20` 串流 ZIP，匯出前後核對整檔 SHA，保留 MPF 全部 bytes，不重新編碼。
- 偏好與主題：深海藍／青綠高對比原生 UI、首張與完成事件、可選通知／聲音／觸感、容量警告、補掃頻率、每目的地 Wi-Fi／高成本／低數據限制。隱私 manifest 和 Photos 用途說明已加入。
- 相機生命週期：fresh browser、cached device reconciliation、不可變 delegate owner 和安全關閉屏障；不新增廠商寫入、刪卡或拍攝命令。

真正的雲端設定、雙電腦、歷史與偏好頁已從 RootView 可達，由單一 CamLinkRuntime 注入。自動加入只針對新驗證圖，明確歷史補傳另行選擇，雲端錯誤不影響本機原圖。

## 正在執行的驗證次序

靜態 Swift 語法、YAML、source plist／Client／callback 一致性已檢查；這不等於 Swift 型別編譯或測試已通過。`ios/run_parity_tests.sh` 已納入 smoke 和 signed workflow，真正 Mac 執行 lifecycle、OAuth、偏好、Google、OneDrive、雙電腦及場次／模型回歸；原有 PTP、JPEG、MPF 回歸保留。

下一步：真正 macOS 回歸與完整 Apple SDK 編譯、修正具體錯誤；通過後才進行 signed IPA metadata 驗證及 TestFlight 內部群組確認。尚未宣稱 build 42 已分發。

## 必須保留的能力界線

仍需簽署 iPad 實測 Google／Microsoft consent、callback、refresh、選建資料夾、原圖傳送／讀回及斷網重啟；兩部 Receiver 與真實 WebDAV 亦需各自驗收。Google `drive.file` 只能存取 App 可見檔案／資料夾，不能聲稱可瀏覽整個 Drive。Dropbox／Box／Google Photos／Flickr 是系統分享，取決於已安裝 App，不是本 App 原生 API 或可核對的遠端交付。

iOS 鎖屏／背景／切 App 不保證 USB 常駐；口袋模式是前景黑畫面。耐久接收續收、相機不發事件的新拍等硬體情境仍需具體驗收，不因離線測試而宣稱完全一致。原始私人 JPG／ZIP、Apple 憑證私鑰和登入權杖不加入 Git 或公開產物。私人 OTA 網頁不在本次公開發布範圍。
