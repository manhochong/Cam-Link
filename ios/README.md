# Cam Link for iOS / iPadOS

## 目前 iOS 版本範圍

- 以 USB 線和 Apple `ImageCaptureCore` 尋找外接數位相機並接收 JPG/JPEG；LUMIX 相機需選 **PC(Tether)**。
- 使用既有 Cam Link Receiver，透過 TLS `:9443`、人工核對伺服器憑證指紋和 SHA-256 回覆確認傳輸。
- 暫不包含相機 Wi‑Fi、FlashAir、Google Drive、OneDrive 或 WebDAV。這些 Android 功能不會自動出現在 iOS 版。
- ImageCaptureCore 是 iOS 可用的 [Apple 官方相機匯入介面](https://developer.apple.com/documentation/imagecapturecore)；它不是 Android 的原始 USB bulk API。不同相機、韌體和 USB 轉接器仍需逐台實測。

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
