# Cam Link iOS 完整移植與 build 42 整合

使用者已確認 build 41 的卡內 JPG 與電腦接收成功；最新實機報告為已收 5 張、失敗 0 張。新拍模式尚未確認，須保留卡內成功流程，依新模式診斷修正，不傳送未證實的廠商／相機設定命令。

## 交付範圍

以現有 Android 原始碼為功能清單：Google Drive 和 OneDrive 直接 OAuth 登入與雲端原圖上傳；WebDAV 保持獨立核對；原 Android 分享型的 Dropbox、Box、Google Photos、Flickr 提供原圖系統分享，而不是冒充直接 API 備份。雲端、第一／第二電腦需各自持久化帳戶／資料夾／照片傳送紀錄，不能用單一 photo.uploaded 當作全部目的地完成。

活動名稱、新建活動、過往活動與照片紀錄、原圖分享／報告匯出及通知設定按原 Android 實際行為補齊。已存原圖不可被初始化、切換活動或升級刪除。現有主電腦配對須從舊 Keychain／設定安全遷移。新模式失敗將獨立檢查。

Google 和 Microsoft 原生 iOS 登入必須使用該 App 的 public client 註冊、合法回呼及安全的外部登入畫面。沒有註冊資料時不執行假的網路登入；完成程式後仍需實際服務帳戶授權。OAuth 及帳密只存 Keychain，網路重新導向不洩漏 Bearer。上傳需要原圖大小与真正遠端內容雜湊／讀回核對才列為核對完成。

## 原生 UI 設計

改用克制的深海藍（#17253D）與品牌青綠（#007A86），搭配冷白背景（#F4F7FA）、純白卡片、深灰藍內文和柔金進度點綴。明確的成功、待傳、需要登入與錯誤狀態不僅靠顏色，還有圖示和文字。主要按鈕以白色文字配深藍／青綠實色，停用時也保留對比。

使用 iOS 系統字體與 SF Symbols。照片保持原始比例和不裁切預覽；iPad 橫向採照片與控制雙區，直向控制自然流式排列。頁面、傳送目的地與活動紀錄使用同一圓角、留白和字級系統。無需生成裝飾圖片或以 UI 圖代替真實程式。

## 模組責任

`Transfer/OAuthSupport.swift` 提供原生 OAuth／PKCE 和權杖；GoogleDrive／OneDrive 各自提供傳送工作紀錄及設定頁。`Transfer/PairStore` 與 `MultiPCDeliveryStore` 處理雙電腦與單獨核對。`Session` 處理活動、原圖與匯出，`Preferences` 處理通知／網路限制。主流程整合 `RootView`、`CamLinkApp`、主題、plist／XcodeGen 與 Codemagic，保留既有 MPF 驗證。

## 驗證界線

在 Codemagic 真正 macOS 執行各模組回歸與完整 iOS device SDK 編譯，並檢查 signed IPA metadata 後上傳內部 TestFlight。合成測試不代表服務帳戶登入成功；Google／Microsoft 實際登入及遠端寫入需另外驗證。iPadOS 不保證鎖屏／背景 USB；不得以 Android 前景服務能力宣稱 iOS 也完全相同。私人 OTA 網頁此輪不修改、不公開發布。
