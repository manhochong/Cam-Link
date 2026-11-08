# Cam Link Receiver：Mac 測試與交付狀態

此接收器和 Windows 版使用相同的 `camlink://pair?ip=…&code=…` QR 內容、TCP 9443 HTTPS、Basic 認證及 `X-CamLink-SHA256` 原圖核對協定。iPad 不需要 Mac 才能配對：目前使用者可以直接測試 **iPad → Windows Receiver**。iOS 舊版缺少 QR 開啟入口，不是 Windows 接收器必須改用 Mac。

## 本次已修正

| 問題 | 修正 |
|---|---|
| Go 紀錄 JSON 使用 `Name`／`Time`，前端卻讀取 `name`／`time` | 明確設定小寫 JSON 欄位，避免紀錄顯示 `undefined` 及無法點選照片。 |
| 「補核對資料夾」僅列出檔案，沒有比對傳送 SHA-256，卻標成已核對 | 改為「重新整理資料夾」與「本機檔案」，不變更已核對數量／位元組，不把失敗傳送改成成功。 |
| 重新掃描向紀錄前方插入新列，沒有同步更新傳輸列索引 | 把掃描發現的本機檔案加入尾端，保留正在接收的列與回呼索引。 |
| 本機瀏覽器控制 API 缺少會話及來源驗證 | 加入隨機會話權杖、Host／Origin 核對與讀寫方法限制；控制頁仍只綁定 loopback，手機仍走獨立的認證 HTTPS 9443。 |

沒有改動使用者的既有配對碼／憑證，也沒有自動刪除原圖。

## 已取得的證據

Linux 沙箱上的 Go 1.22.2 `GO111MODULE=off go test -race -v ./mac` 已通過。覆蓋認證、HEAD 探測、成功收檔、重試、雜湊不符、同名衝突保留原檔、非法路徑、JSON 欄位、掃描不冒充核對及本機控制頁保護。這是接收協定／程式邏輯檢查，不等同 macOS 桌面實機驗收。

Mac QR 編碼器產生的三個測試配對碼，已用獨立 ZXing 解碼器讀回原始字串，包含短 IPv4、一般區網 IPv4 與最長 IPv4 字串。這驗證 QR 編码資料可讀；實際螢幕反光、相機對焦與 App 權限仍要實測。

已用 Go 交叉編譯產生 `release/CamLink-Receiver-macOS.zip`，包含 Intel 與 Apple Silicon 的 universal Mach-O、圖示及 build 35 `Info.plist`。ZIP 完整性、執行檔權限及兩個 CPU 架構已檢查。

## 沒有 Mac 怎樣測試

日常使用先在 Windows 啟動接收器，讓 iPad 與電腦連同一個可互通的區網；選正確 IPv4、顯示 QR、在 Cam Link 掃描並核對指紋，再傳一張照片。這已能測試手機到接收器的完整協定，不需要 Mac。

已加入手動 Codemagic 工作流程 `mac-receiver-smoke`。它使用 Apple Silicon Mac runner 執行 Go race 測試，並封裝 universal `.app`；不需要使用者的 Mac、UDID 或 iOS Distribution 憑證。此文件目前只證實沙箱測試及交叉編譯，**macOS runner 結果尚待執行確認**。

最後仍需要雲端互動式 Mac 或一位持有 Mac 的測試者，檢查下載解壓後啟動、預設瀏覽器畫面、資料夾選擇、macOS 本機網絡／通知／防火牆權限、休眠重連，以及從實際 iPad 傳一張 JPG 的結果。沒有跑過這些項目前，不能宣稱 Mac 版已全面可用。

## 分發限制

目前 ZIP 是內部候選測試包，不是已完成 Developer ID 簽名及 Apple 公證的正式 Mac 安裝包。Go 的 ARM64 內嵌程式碼簽章不等於 Developer ID 發布簽章；macOS Gatekeeper 可能拒絕直接開啟下載的 App。不要要求測試者全域關閉 Gatekeeper。正式對外分發前，應在 Mac CI 使用適當的 Developer ID 憑證、公證及票證 stapling；目前既有 Apple Distribution 憑證是 iOS 用，不應直接冒充 Mac Developer ID。[1] [2]

## References

[1]: https://developer.apple.com/developer-id/ "Apple Developer ID and Gatekeeper"
[2]: https://developer.apple.com/macos/distribution/ "Apple distributing software on macOS"
