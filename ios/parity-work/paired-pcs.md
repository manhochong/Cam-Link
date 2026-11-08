# paired-pcs 完成摘要

完整精確 API、父層最小接線、資料遷移規則、Mac 編譯測試命令與繁體中文限制見 [multi-pc.md](multi-pc.md)。本摘要對應原責任 id `paired-pcs`。

本責任實際修改／新增：

- `ios/CamLink/Transfer/PairStore.swift`：保留原主槽 Keychain account、兩槽 metadata／labels／selectedSlot／新圖 opt-in、明確指紋確認、可信 legacy primary 身份、Keychain 暫不可讀時保留原配對 metadata。
- `ios/CamLink/Transfer/PcClient.swift`：保留成功 Receiver 協定；僅於所有 PC request/session 套用父層 `CamLinkNetworkPolicy.apply(... allowsCellular: false)`。
- `ios/CamLink/Transfer/MultiPCDeliveryStore.swift`：獨立 slot／fingerprint／revision／照片／場次 job、durable SHA/size receipt、有限重試、動態新照片入列、舊工作不轉送新電腦、逐槽 `allowsTransfer` 政策閘、`cancelCurrentTransfer()`。
- `ios/CamLink/Transfer/PCSettingsView.swift`：明確 `init(pair:delivery:photos:sessionID:albumName:remoteNames:)`；也提供 `typealias MultiPCSettingsView = PCSettingsView`，使用既有 QR scanner。
- `ios/MultiPCTests.swift`：Mac 可執行的離線遷移／編碼／遠端檔名／目的地隔離／同時入列／有限重試／政策／取消測試。
- 本報告及 `ios/parity-work/multi-pc.md`。

父層核心介面是 `@MainActor MultiPCDeliveryStore(pair: pair)`、`observeNewPhotos(photos:sessionID:albumName:autoUploadEnabled:remoteNames:)`、明確手動 `enqueue(photos:sessionID:albumName:to:remoteNames:) throws`、`await pump()`、`jobs`、`allowsTransfer: ((PCSlotID) -> Bool)?`、`cancelCurrentTransfer()`。另保留要求的 `enqueue(photos:[ReceivedJPEG],albumName:String)`，但它是明確手動便利入口，不能作全歷史自動掃描；實際現有照片型別為 `ReceivedJPEG`，不是本模組自創 `ShootSession.Photo`。

自動流程必須在啟動／新場次先 observation baseline，再於 ingest 後 observation；這避免配新電腦時把所有舊圖靜默加入。`uploaded` 舊 Bool 不證明新目的地成功。只有捕捉的原 primary fingerprint／revision 與目前主槽吻合時，才可一次性匯入該場舊 true 標記；收據明示 `.legacyPrimaryImported`，不是本次 live 核對。

本環境無 Swift／Apple SDK；已執行 Swift grammar 靜態解析，但尚未執行 swiftc、Mac 測試或 iOS 編譯。兩部真實 Receiver、網路政策、錯誤與重啟復原仍需簽署 iPad 驗收；沒有真實憑證，未做遠端寫入、登入或宣稱 live PC 成功。未改 RootView/App／相機 USB/PTP/MPF／plist/project/CI，未操作 Git 或瀏覽器，未啟動 CI，未刪除既有原圖或其他 provider 資料。build41 成功基線保持不動。
