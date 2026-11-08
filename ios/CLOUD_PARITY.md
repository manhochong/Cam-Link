# iOS 多雲端傳送的實際移植範圍

Android 的傳送選項有兩種不同的能力。Google Drive、OneDrive、WebDAV 會由 Cam Link 直接上傳完整 JPG；Dropbox、Box、Google Photos、Flickr 則是把 JPG 交給已安裝的服務 App 分享。打開分享介面不等於雲端備份成功，也不能標為已核對。

目前已發布的 iOS build 36 只有 App 本機保存與單一電腦 Receiver。Google Drive、OneDrive、WebDAV 尚未完整移植。Android 可配對兩部電腦；iOS 目前也未達到這一項相同能力。

WebDAV 可直接以原生 Swift 實作，不需要 Google 或 Microsoft 應用程式註冊。輸入已有、可寫入的 HTTPS 資料夾網址、使用者名稱及應用程式密碼。憑證需保存在 iOS Keychain；設定儲存成功不代表遠端憑證測試通過。傳送使用 create-only PUT，拒絕重新導向；下載遠端檔案回來，以檔案大小及 SHA-256 核對後才標為完成。同名但不同內容不可覆寫。預設不啟用自動上傳，且 WebDAV 狀態與電腦 Receiver 狀態分開保存。

其他服務先提供 iPad 的批量原圖系統分享：可選的目的地依安裝的 App 及其分享擴充功能而定。Cam Link 不應宣稱能強制指定某個服務、保證該服务支援批量分享，或直接驗證其他 App 的上傳結果。

Google Drive 的 Android 登入利用 Android 套件／簽名註冊，不能直接當作 iOS client 使用。需在原有 Google Cloud 專案取得或建立與 `hk.camlink.ios` 對應的 iOS OAuth client，設定 client ID 與回呼，並核對 `drive.file` scope、測試使用者及 Drive API。App 不保存 OAuth client secret。

OneDrive 的 Android 程式有既有 public client ID，但 repo 沒有證明該註冊的 iOS／外部瀏覽器回呼已正確設定。原有登入程式的回呼及 manifest 存在差異，不能直接複製 WebView 攔截登入作為 iOS 成品。iOS 必須採用原生外部授權 session 與 PKCE，核對 Microsoft 註冊允許的精確回呼和 public-client 流程，再測試權杖更新與 Graph 上傳。

直接雲端上傳需獨立、可恢復的每目的地工作紀錄，包括帳戶／資料夾、檔案身分、雜湊、重試及錯誤。原有 `photo.uploaded` 只表示電腦 Receiver 核對結果，不能表示全部雲端都完成。雲端登入或網路錯誤不可把已收到的相機 JPG 當作接收失敗。

## 原始碼基準

- Android `OtherClouds.java`：其他服務 App 分享捷徑。
- Android `CloudAuth.java`、`DriveApi.java`、`CloudStore.java`：Google 帳戶授權、Drive v3 及工作佇列。
- Android `OneDriveAuth.java`、`OneDriveApi.java`、`OneDriveStore.java`：Microsoft PKCE、Graph 及工作佇列。
- Android `DavBackup.java`：WebDAV Basic／Keychain 等效憑證保護需求、create-only PUT、GET／SHA-256 核對及雙 PC 配對。
- iOS `PairStore.swift`、`PcClient.swift`、`ShootSession.swift`：既有單一 Receiver 配對、核對及本機持久化。

此文件描述真實能力及依賴，不是所有雲端已完成、已登入或已實測的聲明。
