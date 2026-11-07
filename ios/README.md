# Cam Link for iOS / iPadOS

**最優方案（已定）**

| 項目 | 選擇 |
|------|------|
| 進圖 | **USB 線 + ImageCaptureCore**（不靠 Wi‑Fi SD／卡無線） |
| 相機模式 | 與 Android 相同：LUMIX 選 **PC(Tether)** |
| 只收 | JPG／JPEG |
| 出圖 | 現有 **Cam Link Receiver**（TLS `:9443`、指紋、SHA-256） |
| 暫不做 | 相機 Wi‑Fi、FlashAir、Drive／OneDrive（可後加） |

本機在 Windows 只能維護原始碼；**編譯與實機必須在 Mac + Xcode**。

## 在 Mac 上產生工程並執行

```bash
cd ios
brew install xcodegen   # 若尚未安裝
xcodegen generate
open CamLink.xcodeproj
```

1. Signing & Capabilities → 選你的 Team（`DEVELOPMENT_TEAM` 也可寫進 `project.yml`）  
2. 接 **USB-C iPhone／iPad**（Lightning 需轉接；若提示耗電過高，關相機 USB 供電）  
3. 相機 USB 設 **PC(Tether)**，線接手機  
4. App 點「尋找 USB 相機」，允許存取後應出現裝置名並開始收 JPG  
5. 電腦開 `Cam Link Receiver`「開始接收」，App「配對／更改電腦」→ 核對指紋 → 自動或手動上傳  

源碼目錄：

- `CamLink/Camera` — ImageCaptureCore USB  
- `CamLink/Transfer` — 與 Android 相同的配對／PUT 協定  
- `CamLink/Session` — 本場列表與上傳佇列  

## 冒煙判準

- [ ] 發現相機  
- [ ] 下載至少一張 JPG 到本場列表  
- [ ] 新拍一張後能再收到  
- [ ] PUT 到 Receiver 後電腦顯示「已核對」  

若第 1～2 步失敗：該機型在 ImageCaptureCore 上可能受限，再評估；**不要**改走卡無線。

## 版本

與 Android／桌面一致：`0.2.25`（build 32）。

## 本機限制

此倉庫若在 Windows 維護，無法在此編譯 IPA；請在 Mac 用上述步驟建置。協定與 Receiver 已與現有 `release/CamLink-Receiver.exe`／macOS zip 對齊。
