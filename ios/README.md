# Cam Link for iOS / iPadOS

## 目前 iOS 版本範圍

- 以 USB 線和 Apple `ImageCaptureCore` 尋找外接數位相機並接收 JPG/JPEG；相機 USB 模式須依型號實測，Android 使用的 **PC(Tether)** 模式不保證能向 iOS 提供完整目錄。
- 使用既有 Cam Link Receiver，透過 TLS `:9443`、人工核對伺服器憑證指紋和 SHA-256 回覆確認傳輸。
- 暫不包含相機 Wi‑Fi、FlashAir、Google Drive、OneDrive 或 WebDAV。這些 Android 功能不會自動出現在 iOS 版。
- ImageCaptureCore 是 iOS 可用的 [Apple 官方相機匯入介面](https://developer.apple.com/documentation/imagecapturecore)；它不是 Android 的原始 USB bulk API。不同相機、韌體和 USB 轉接器仍需逐台實測。

### build 36：iPad 接收與 QR 配對修正候選版

build 33 已由使用者回報無法從相機收到照片，而且介面不對應 Android；因此 build 36 仍是待驗證候選版，不代表已達成相機功能驗收。修正包含相機授權流程、完整目錄門檻、逐張下載、掉線回呼隔離與 JPG 完整性檢查；主畫面改為 Android 對應的首頁／紀錄／傳送／更多，提供照片預覽、統計與 iPad 橫向左右分區。

build 35 雖成功上傳，Apple 後續處理以 `90683` 指出封裝檔缺少相機用途說明。build 36 改為直接使用已提交的 Info.plist，不讓 XcodeGen 覆寫用途與 QR Scheme，並在 CI 驗證最終 IPA 的這些欄位。`python3 ios/verify_metadata.py <Info.plist 或 IPA 路徑>` 可重用此檢查。

在「傳送」→「配對／更改電腦」→「掃描電腦 QR Code」掃描 Windows 或 Mac Receiver 的配對 QR，或用系統相機掃描後開啟 Cam Link。QR 只預填電腦地址與配對碼；仍需按「探測並顯示指紋」，核對與接收器畫面相同後完成配對。iPad 不需要使用 Mac 作為接收電腦，Windows Receiver 也使用相同的配對與 HTTPS 協定。

首頁的「開始接收新拍 JPG」會在完整目錄就緒後略過既有照片，等待新拍的 JPG。「接收卡內 JPG」才會匯入記憶卡原有 JPG；重新連接要補收未完成照片時請選這個模式。同名且相同 SHA-256 的本機照片不會重複加入。按「停拍並完成接收」會先完成已排入佇列的檔案；請保持相機接線，直到顯示已停止。

若相機無法找到或收檔失敗，在「更多」按「產生 USB 相機診斷報告」後分享報告，並附上相機型號、USB 模式、iPad 型號及 iPadOS 版本。App 不會重設系統權限，也不會刪除或修改相機內的照片。USB 接收期間請保持 App 前景；黑色口袋畫面不是背景服務，也不保證鎖屏仍能接收。

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

## 相機與接收器實機驗收

編譯後的 signed build 安裝到 iPhone/iPad，再依次確認：

- [ ] USB 接上相機，允許存取後可發現相機並顯示裝置名稱。
- [ ] 相機設為 PC(Tether)，已有 JPG 能下載到本場列表。
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
