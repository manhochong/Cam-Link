# Cam Link for iOS / iPadOS

## 目前 iOS 版本範圍

- 以 USB 線和 Apple `ImageCaptureCore` 尋找外接數位相機並接收 JPG/JPEG；相機 USB 模式須依型號實測，Android 使用的 **PC(Tether)** 模式不保證能向 iOS 提供完整目錄。
- 使用既有 Cam Link Receiver，透過 TLS `:9443`、人工核對伺服器憑證指紋和 SHA-256 回覆確認傳輸。
- 候選 build 37 增加真正 WebDAV 原圖上傳與批量系統分享。Google Drive／OneDrive 直接登入仍待原生 OAuth 設定，不包含相機 Wi‑Fi 或 FlashAir；不能把分享介面當成雲端已核對。
- ImageCaptureCore 是 iOS 可用的 [Apple 官方相機匯入介面](https://developer.apple.com/documentation/imagecapturecore)；它不是 Android 的原始 USB bulk API。不同相機、韌體和 USB 轉接器仍需逐台實測。

### build 40：JPG 結構驗證與接收失敗顯示候選版

build 39 已實機列出 154 個物件並執行 JPG GetObject，但最終成功 0 張、失敗 74 個。可見下載回傳成功且大小相等，全部停在合併的「缺少 SOI／EOI」檢查。首頁與紀錄頁尚無照片，是因為驗證未成功，不是照片已保存但兩頁不同步。報告未包含照片起訖 bytes，不能斷言相機照片損壞，也不能把區塊對齊大小直接當成填充證據。

build 40 候選版以 JPEG 主影像結構和 ImageIO 解碼取代「EOI 必須是整檔最後兩 bytes」的規則；只容納有界纯填充，仍核對原始總大小與整檔 SHA-256，不裁切或重新壓縮。新增非敏感 JPEG 邊界摘要；紀錄頁顯示本次接收失敗和診斷分享，不建立未驗證的假照片。確定的格式拒絕不再重新下載六次，並保留本場首次 JPG 結果。新 ImageIO 回歸、完整編譯與 build 40 TestFlight 指派尚待確認，不能提前更新到候選版或宣稱相機收檔已成功。

### build 39：DeviceInfo 尾端相容修正候選版

build 36 的 DC-S1RM2／iPadOS 26.5.2 診斷顯示授權、session 和 PTP 事件均成功，但三次 native 目錄為空，沒有開始下載。build 37 在空目錄時使用原生 PTP command 介面，重新查詢物件 handle，再取得 ObjectInfo／JPG。只發送標準唯讀命令；不開啟第二個 USB session、不改拍攝設定、不刪相機照片。非空 native 目錄仍保留原有 ImageCaptureCore 路徑。

build 37 實機回報進一步顯示：PTP 授權成功，但首個 `GetDeviceInfo` 因 callback 第一份 235-byte 資料被當作 12–32-byte response 而停止。build 38 以完整 type-3 response header／回應碼辨識兩份 Data 的角色，不再硬認第一份是 response。相同 normalizer 同時用於實際 adapter 和新增回歸測試，涵蓋兩種順序、錯誤／空回應、歧義及 payload budget。這是 App 的解析缺陷，不是使用者權限設定錯誤。

build 38 新實機報告已確認 `response=2001 responseSlot=second`，callback 修正有效。下一個阻塞是 `DeviceInfo dataset trailing bytes`：標準描述欄位解析成功後，exact-end 限制拒絕剩餘資料。build 39 只讓 DeviceInfo 容納標準欄位後的未知尾端，新增長度與類型統計。所有欄位的邊界、UTF-16、4 MiB 上限仍保留，照片檔及其他 dataset 的完整性驗證沒有放寬。尾端的實際內容沒有附在報告，不能直接稱為已知 Panasonic 擴充。

此候選版保留黑底主按鈕的文字對比修正，並用原圖 metadata／EXIF 方向決定照片比例，未收到照片時使用 4:3 預覽；iPad 直向不再把預覽固定壓成矮長框。build 39 已在 Codemagic `6af0428a24e1ec237557736a` 通過 575 項 callback／codec 離線檢查、完整 App 的 Apple SDK 編譯、簽名 IPA 匯出及最終 metadata 檢查，Apple 上傳已成功。DC-S1RM2 實機接收和 WebDAV 遠端 PUT／GET 仍須驗證，不能只憑編譯判定支援成功。

build 35 雖成功上傳，Apple 後續處理以 `90683` 指出封裝檔缺少相機用途說明。build 36 改為直接使用已提交的 Info.plist，不讓 XcodeGen 覆寫用途與 QR Scheme，並在 CI 驗證最終 IPA 的這些欄位。`python3 ios/verify_metadata.py <Info.plist 或 IPA 路徑>` 可重用此檢查。

2026-11-08 已確認 build 39 為 `Testing`，已加入 `CamLink Internal`，可在 iPad 的 TestFlight 更新至 `0.2.25 (39)`。確認版本後先重新接線，避免沿用失敗的 native session；先用「接收卡內 JPG」收原有照片，再停止並重新選「開始接收新拍 JPG」，等完成 fresh baseline 後才拍新照片。卡內模式會嘗試接收現有全部 JPG，適合先用只有少量 JPG 的測試卡。若仍失敗，分享 build 39 新診斷並提供相機 USB 設定頁／模式；報告內 `mode=接收新拍 JPG` 只是 App 模式，不是相機 USB 模式。新增 `PTP_DEVICE_INFO_LAYOUT` 與後續 opcode／回應碼可定位是否已進入目錄查詢或 ObjectInfo。實機收檔仍待驗證。

在「傳送」→「配對／更改電腦」→「掃描電腦 QR Code」掃描 Windows 或 Mac Receiver 的配對 QR，或用系統相機掃描後開啟 Cam Link。QR 只預填電腦地址與配對碼；仍需按「探測並顯示指紋」，核對與接收器畫面相同後完成配對。iPad 不需要使用 Mac 作為接收電腦，Windows Receiver 也使用相同的配對與 HTTPS 協定。

首頁的「開始接收新拍 JPG」會在完整目錄就緒後略過既有照片，等待新拍的 JPG。「接收卡內 JPG」才會匯入記憶卡原有 JPG；重新連接要補收未完成照片時請選這個模式。同名且相同 SHA-256 的本機照片不會重複加入。按「停拍並完成接收」會先完成已排入佇列的檔案；請保持相機接線，直到顯示已停止。

若相機無法找到或收檔失敗，在「更多」按「產生 USB 相機診斷報告」後分享報告，並附上相機型號、USB 模式、iPad 型號及 iPadOS 版本。App 不會重設系統權限，也不會刪除或修改相機內的照片。USB 接收期間請保持 App 前景；黑色口袋畫面不是背景服務，也不保證鎖屏仍能接收。

### 多目的地傳送

WebDAV 在「傳送」→「WebDAV（NAS／雲端資料夾）」設定已有可寫入的 HTTPS 資料夾、帳號和應用程式密碼。密碼只存 Keychain；儲存設定沒有測試遠端登入。預設關閉自動傳送，可按「上傳本場 JPG」，或自行啟用。上傳後會以 GET 讀回原圖並比對大小和 SHA-256，完成才算 WebDAV 已核對；同名不同內容不覆寫，也不修改電腦 Receiver 的核對狀態。

「分享本場所有 JPG」使用系統分享，可交給已安裝的 Dropbox／Box／Google Photos／Flickr 等服務擴充功能。實際可選項目依其 iPad App 支援而定；這不是 Cam Link 自動雲端備份。Google Drive／OneDrive 顯示登入設定待完成，未啟用假登入；參見 `CLOUD_PARITY.md` 和 `WEBDAV.md`。

## 沒有 Mac：使用 Codemagic

倉庫根目錄已有 `codemagic.yaml` 的 `ios-smoke` workflow。它在 Codemagic 雲端 macOS 安裝 XcodeGen、產生 Xcode 專案，並對 iPhoneOS SDK 做未簽名 Debug build。

1. 把完整專案放到 Codemagic 已連接的 Git 儲存庫。確認 `codemagic.yaml` 位於 repository root，iOS 來源在 `ios/`。
2. 在 Codemagic 新增／選取這個 App，選 `ios-smoke` workflow，並使用 `main` 分支；目前 YAML 只會在 `main` push 時自動觸發，也可在 Codemagic 手動啟動。
3. 建置成功後，到 Artifacts 下載 `CamLink.app`，查看 Codemagic build log 確認沒有 Swift 或 Xcode 錯誤。

這個 smoke workflow **只驗證能否編譯，不會產生可安裝的簽名 IPA，也不會上傳 TestFlight，不能代替相機實機測試**。內部實機測試請使用下方手動啟動的 TestFlight workflow。不要把憑證、私鑰或 API key 放進 Git。

### TestFlight 內部測試（不需 UDID）

根目錄的 `ios-testflight-internal` workflow 會以 `app_store` 簽名方式建置 IPA、標記為只供 TestFlight 內部測試，並上傳至 App Store Connect 的 `CamLink Internal` 群組。該 workflow 沒有 push trigger，必須在 Codemagic 手動選 `iOS TestFlight Internal` 啟動；`ios-smoke` 仍只在 `main` push 時自動執行。

首次執行前，請在 App Store Connect 建立 bundle ID 為 `hk.camlink.ios` 的 App 記錄和內部測試群組 `CamLink Internal`，並把自己的 App Store Connect 使用者加入群組。Codemagic 的 Developer Portal integration/API key 名稱需與 YAML 的 `CamLinkTestFlight` 完全相同，並有 App Manager 權限；Code signing identities 亦須提供匹配的 Apple Distribution certificate 和 App Store provisioning profile。沒有這些設定時，TestFlight workflow 會在簽名或上傳階段失敗。

建置成功並經 App Store Connect 處理後，受邀使用者在 iPhone 安裝 TestFlight App，並從邀請郵件接受 Cam Link 內部測試邀請。此流程不需要登記 UDID，也不是 App Store 公開上架；TestFlight 建置可測試 90 天。不要把憑證、私鑰、`.p8` API key 或 profile 加入 Git。

2026-11-08 使用者已授權 build 36 的出口合規答覆，以及將 `ITSAppUsesNonExemptEncryption = false` 加入已提交的 Info.plist。此旗標適用於維持現行實作的後續版本：iOS 系統提供 TLS／Keychain，CryptoKit 僅作 SHA-256 雜湊，沒有額外實作問卷列出的加密演算法。若日後加入或改動加密，必須重新評估聲明；`false` 並非宣稱 App 完全不使用加密。已上傳 build 36 仍由 App Store Connect 的合規問卷處理，原始碼旗標不會修改已上傳二進位檔。

build 37、38 及 39 已正常處理並加入群組，沒有再次要求人工出口合規答覆。後續簽名上傳須使用未上傳過的新 build 編號；不要直接重跑 build 39。修改 `project.yml` 的 `CURRENT_PROJECT_VERSION` 後再啟動 `ios-testflight-internal`。

## 相機與接收器實機驗收

編譯後的 signed build 安裝到 iPhone/iPad，再依次確認：

- [ ] USB 接上相機，允許存取後可發現相機並顯示裝置名稱。
- [ ] 相機使用已確認相容的 USB 模式，選「接收卡內 JPG」後，已有 JPG 能下載到本場列表。
- [ ] 新拍一張 JPG 後，App 能收到且不會因檔名重複而覆蓋。
- [ ] 關閉再重開 App，本場照片和待傳／已核對狀態仍在。
- [ ] 配對時顯示的伺服器指紋與 Receiver 畫面相同。
- [ ] 手動或自動 PUT 到 Receiver，電腦端顯示「已核對」。
- [ ] 上傳期間再拍照、遇到 Wi‑Fi 中斷或 Receiver 忙碌時，照片仍保留待傳，可稍後重試。

若相機無法被發現或無法下載，第 1–2 項須以該相機型號、韌體、iPhone 型號及轉接器做實機診斷；不可只以 Codemagic 編譯成功推斷相機已支援。

## 專案結構

- `CamLink/Camera` — ImageCaptureCore USB 相機發現與 JPG 下載。
- `CamLink/Transfer` — 電腦配對、Keychain 配對碼儲存、TLS pinning 與 PUT 協定。
- `CamLink/Session` — 本場照片清單及本機持久化待傳佇列。
- `project.yml` — XcodeGen 專案設定；部署目標 iOS 16。
