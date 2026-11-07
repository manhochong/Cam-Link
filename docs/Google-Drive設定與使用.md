# Cam Link 0.2.18 — Google Drive 設定與使用

在 Flip6 開啟「我的檔案 → 內部儲存空間 → DCIM → CAM LINK」即可查看完整 JPG。相簿發佈失敗時，App 會保留接收目錄的原檔並提示。Wi-Fi 上最多同時上傳兩張，流動網絡逐張上傳。

使用者指定使用 **manhochong** 的 Google 帳戶。這是帳戶名稱提示，程式不自行假定完整 email。請在手機 Google 帳戶選擇器選擇正確帳戶。

## 此次已完成的登記

2026-10-31 已確認 Google Cloud 登入帳戶為 `manhochong@gmail.com`。該帳戶已達專案數量上限，無法新增獨立專案；依使用者要求繼續處理，於現有 **Gonfolio／work-camera-512615** 專案建立獨立 Android client：

- 名稱：`Cam Link Android USB Drive`
- Client ID：`518900347391-nbhf7jajnm7j3bv9ff1iak7no3b64f3c.apps.googleusercontent.com`
- Package：`hk.camlink.usb`
- SHA-1：`6D:45:15:33:E2:55:37:B8:C1:F7:63:95:79:D9:97:15:D5:52:8C:83`
- Google Drive API：已啟用；`drive.file`：既有已登記；`manhochong@gmail.com`：既有測試使用者。

保留原專案品牌、測試模式、其他 OAuth 客戶端及 scope，沒有更改 Gonfolio 原有憑證。Google 授權畫面可能沿用 Gonfolio 名稱。此次登記已在 Flip6 實際生效：Google 授權與 Drive 帳戶確認成功，10 張既有相機 JPG 已全部上傳並校驗。

0.2.1 只列出帶有 Cam Link 標記的資料夾，登入請求僅包含 `drive.file`，不附帶先前其他功能的 scopes。App 內「登出 Cam Link」只清除本機登入並暫停上傳；完整撤銷專案的 Google 授權可能同時影響 Gonfolio，故改由「管理 Google 帳戶授權」顯示說明後交給使用者管理。

目前這部手機已使用上述簽章，**毋須重複建立 OAuth client**。下列一次性設定步驟保留給未來獨立專案或更換簽章時使用。

## 一次性 Google Cloud 設定

1. 用 manhochong 的 Google 帳戶登入 [Google Cloud Console](https://console.cloud.google.com/)，建立專案，例如 `Cam Link`。
2. 在該專案的 [API 程式庫](https://console.cloud.google.com/apis/library/drive.googleapis.com) 啟用 **Google Drive API**。
3. 開啟 [Google Auth Platform](https://console.cloud.google.com/auth/overview)，完成 Branding／Audience／Contact information。個人 Gmail 使用 External；先維持 Testing，不用先公開發佈。在 Test users 加入你手機將使用的**完整 Google email**。
4. Data Access 加入 `https://www.googleapis.com/auth/drive.file`。這個範圍讓 App 建立及存取自己建立／獲授權的檔案；不會讀取整個 Drive。
5. 到 Clients → Create client → **Android**，填入：

   - 名稱：`Cam Link Android local test`
   - Package name：`hk.camlink.usb`
   - SHA-1：`6D:45:15:33:E2:55:37:B8:C1:F7:63:95:79:D9:97:15:D5:52:8C:83`

6. 儲存後回手機 Cam Link → Google Drive →「登入 Google」（已登入時按「更改帳戶或資料夾」）。選 manhochong 的實際 Google 帳戶，由 Google 畫面授權。

這個版本直接使用手機 Google AuthorizationClient，沒有自建後端，也不要求輸入 Web client ID、client secret、密碼、API key 或手貼 token。Android client 由 package＋簽章識別。不要把 Google Cloud client 設為桌面或網頁類型來代替 Android client。

App 內的「Google 登入設定說明／複製登記資料」能顯示並複製當前實際安裝簽章。重新簽章會改變 SHA-1，必須重新登記；保留現有 `.build/usb-test.keystore` 才能繼續原地更新既有安裝。原始碼 ZIP 不含私鑰。

如果 Google 要求隱私政策或服務條款 URL，應填寫自己可公開存取、描述此 App 實際行為的頁面，不要填不存在的網址。本地資料說明在下文；公開發佈與 Google 驗證不屬於本次手機測試安裝。

## 第一次使用

1. 登入後確認畫面顯示的完整 email 是 manhochong 的帳戶。
2. 如想所有場次直傳同一處，選擇或建立固定資料夾。開拍時填寫活動名稱只會為本機紀錄命名。如果想每場獨立存放，保留資料夾未指定，或到「更改帳戶或資料夾 → 改為按活動名稱建資料夾」。在此模式，首張完整 JPG 開始上傳時才會在「我的雲端硬碟」建立該場的同名資料夾；活動名留空會略過本場 Drive 上傳。之後在紀錄改名不會改動雲端資料夾。
3. 開啟「自動上傳新拍 JPG」。若要求盡快上傳，保持「只用 Wi-Fi」關閉，即可用手機 4G／5G；流量按完整原檔大小計算。
4. 返回相機接收，接線 PC(Tether)，開始接收。等「可以拍攝」後才拍攝。每張完整 JPG 驗證成功即排入上傳，USB 與雲端分開執行。
5. 停拍後按「停拍並完成接收」。USB 結束不會取消仍在執行的雲端上傳；Google Drive 頁面可查看逐檔結果。

10 月 31 日驗證時已將 20261031-160413-c5867c 的 10 張 JPG 上傳到 [Cam Link USB 驗證 2026-10-31](https://drive.google.com/drive/folders/1xV4vckT968D-teAbifBk5Vyt4MFhkLDV)，並將它設為當時的目的地，啟用自動上傳新拍 JPG。手機原檔保留。下次可直接接相機開始接收，或先在 Google Drive 頁面建立活動專用資料夾。

其他既有 USB 測試照片不會自動上傳。要手動加入最近一輪，可在 Drive 頁面的「更多工具」按「將最近一輪 JPG 加入上傳」，確認帳戶／資料夾後按「繼續上傳」。同來源和目的地會去重；只加入完整 `.JPG`，不加入 `.part` 或 RW2。

## 佇列、離線和完整性

- 每項固定綁定當時帳戶與資料夾，切換目的地不會搬移先前排隊項目。拍攝或上傳中先停拍／暫停，才能更改帳戶及資料夾。
- 「暫停上傳」保留佇列與原檔。斷網時服務等待；網絡恢復可續傳。若 Android 終止服務、手機重開或強制停止 App，回到 Drive 頁面按「繼續上傳」。不承諾被系統強制停止後仍能傳送。
- 「重試失敗」重新安排需要登入、暫時失敗或永久失敗的項目；先處理權限、空間或帳戶問題。
- 上傳使用持久化檔案 ID，續傳先查伺服器進度，避免不確定回應導致重複檔案。
- 「雲端已核對」代表 Drive metadata 的大小與 MD5 符合本地原檔；若 Drive 提供 SHA-256，亦須相符。這不是從 Drive 重新下載整份檔案的驗收。
- 程式不壓縮、不裁切、不自動刪除手機或相機原檔。移除 App 仍會移除其手機私有資料，請先自行備份。
- Android dataSync 前景服務有時限；App 在接近時限時結束並保留佇列，回到 App 再繼續。

## 常見設定錯誤

- Google 錯誤 10／DEVELOPER_ERROR：檢查 Android client 的 package 與 SHA-1、目前 Cloud 專案、測試帳戶。
- 403／accessNotConfigured：在 OAuth client 所屬專案啟用 Drive API。
- access_denied：確認登入 email 已加入該專案測試使用者，並在 Google 授權畫面允許 Drive 權限。
- storageQuotaExceeded：Google Drive 儲存空間不足，處理後再重試。
- 資料夾找不到：本 App 使用 drive.file，未被授權的既有資料夾不可直接使用；先在 App 內建立資料夾。

## 本地資料與隱私說明

App 讀取已授權 USB 相機的新 JPG，儲存完整原檔和技術診斷。啟用雲端後，照片上傳至你選擇的 Google 帳戶／資料夾。Google 處理登入；App 只在記憶體暫存短期 access token，SQLite 佇列保存在 App 私有目錄，診斷匯出不含 token 或續傳網址。不使用廣告、分析追蹤或第三方照片處理服務。你可暫停上傳或登出 Cam Link，也可在 Google 帳戶管理共用專案的授權；上述操作不會刪除已上傳照片。

官方參考：[Android 授權與 client 登記](https://developer.android.com/identity/authorization)、[Drive 權限範圍](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)、[斷點續傳與預配置 ID](https://developers.google.com/workspace/drive/api/guides/manage-uploads)、[Android 服務時限](https://developer.android.com/develop/background-work/services/fgs/timeout)。
