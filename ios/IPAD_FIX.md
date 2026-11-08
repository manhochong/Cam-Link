# iPad 相機接收與 Android 介面對應修正

使用者回報：TestFlight 0.2.25 (33) 已安裝在 iPad，但相機照片不能進入 Cam Link，介面也不符合 Android 版。實機型號、iPadOS 版本、相機型號、USB 模式與錯誤画面仍待提供。不能把建置／上傳成功當成 USB 相機接收已驗證。

## 原始碼已確認的缺口

`CameraCaptureService` 原先在 session open 和每個 didAdd 回呼直接發起下載；沒有完整目錄就緒的接收門檻，沒有單一下載佇列，沒有 session generation 隔離，存取限制回呼為空，handle 0 會被誤當成有效唯一 ID。相機未找到時沒有具體的逾時提示及可分享診斷。

`RootView` 是單一 List，沒有 Android 的淺色首頁、暗色照片預覽／統計面板、首頁／紀錄／傳送／更多導覽或橫向大圖佈局。Android 的新拍接收與既有卡內 JPG 匯入也沒有在 iOS 明確區分。

## 本次實作

- 以 Apple 的 camera permission 流程和 ImageCaptureCore contents authorization 顯示實際授權狀態；拒絕時提供設定入口，不重設系統權限。
- 等待完整目錄後建立新拍基線，或匯入卡內 JPG；僅單一下載在途，完成驗證後才開始下一張。
- 防止停止、拔線、重接的舊回呼污染目前 session；失敗只在手動重試後重新排隊。保留原圖，不向相機發送刪除、拍攝或設定變更命令。
- 記錄授權、相機發現、目錄、下載、錯誤與 PTP event 的診斷（不包含電腦密碼或配對码），可在更多頁匯出。
- 原生 SwiftUI 對應 Android 主畫面配色、照片預覽、已收／待傳／電腦已核對統計、接收控制與四個導覽入口；iPad 橫向使用左右分區。
- 保留本機 JPG、Keychain 配對與原有 Receiver SHA-256 回覆核對。Google Drive／OneDrive／WebDAV 尚未實作，不用假按鈕冒充已有。
- 補上 `camlink` URL Scheme 與 `onOpenURL`：Windows 和 Mac Receiver 都產生 `camlink://pair?ip=…&code=…`。iOS 舊版未註冊／處理開啟網址，因此系統相機 QR 不能像 Android 一樣直接開啟配對頁。另加入 App 內 QR 掃描入口，掃描只預填地址／配對碼，仍須人工核對憑證指紋。

## 驗證界線

沙箱沒有 Apple SDK；必須以 Codemagic iPhoneOS build 驗證 Swift 編譯。新的候選 build 不代表已修復使用者相機，需在同一 iPad／相機上實測：授權、目錄、原有卡內 JPG、新拍 JPG、拔線／重接、停止排空及 Receiver 核對。

修正來源已推送 GitHub main，commit `b7fa11f`。本機 Swift 語法解析及 plist 格式檢查通過；手動啟動的 iOS smoke build `6af02c1024e1ec2375576d22` 已完成，記錄顯示 `unsigned iphoneos build ok`。後續補上 120 秒單檔下載逾時保護的 commit `eea7264` 也已完成 signed IPA 建置。該 build 34 工作 `6af02cc124e1ec2375576d42` 已在 Publishing 階段取消，以納入使用者新回報的 QR 配對缺口；取消不能保證 Apple 完全未收到部分上傳。最新候選改為 build 35，仍待完整 Apple SDK 編譯、上傳與內部分發。網站保持私人預覽，不更新成新候選版可用。

build 35 已成功編譯、簽名及上傳（工作 `6af02e3924e1ec2375576d8e`），但 Apple 處理回報 `90683: Missing purpose string`，最終 App 缺少 `NSCameraUsageDescription`。已找到 `project.yml` 的 `info.properties` 會重新產生並覆寫本地 Info.plist，原有用途說明及 `camlink` Scheme 都不在該生成設定中。

最新候選改為 build 36。已移除 XcodeGen 的 Info.plist 生成區塊，保留已提交的 plist 作為單一來源。新增 `verify_metadata.py`，在 XcodeGen 後及最終簽名 IPA 中驗證相機／區網用途說明與 QR Scheme；缺少任一項會在上傳前直接讓 CI 失敗。這解決已確認的封裝問題，不代表已驗證 USB 相機硬件。

## 查驗來源

Apple ICDeviceBrowser（內容與控制授權 API）：https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser

Apple requestContentsAuthorization（iOS／iPadOS 14+）：https://developer.apple.com/documentation/imagecapturecore/icdevicebrowser/requestcontentsauthorization%28completion:%29

Apple ICCameraDevice（目錄、檔案匯入與完成目錄回呼）：https://developer.apple.com/documentation/imagecapturecore/iccameradevice

Swift Forums iOS 18 授權立即拒絕案例：https://forums.swift.org/t/icdevicebrowser-fails-to-find-any-devices-after-ios-18-update/72764

這個案例只有問題敘述，沒有可驗證的修正解答，因此不據此斷言使用者遇到相同作業系統問題。
