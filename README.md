# Cam Link 0.2.24

新增「＋連接 → Wi-Fi 接收 → LUMIX 直接連線 · 實驗版」。本次實作標準 PTP/IP 連線及卡檔接收，沿用 JPG 驗證、場次紀錄和雲端佇列，無需啟動品牌 App。**尚未驗證 S1M2／S1R2 的無線配對及接收；Panasonic 新無線 Tether 加密／私有驗證尚未實作，不能把本版視為這兩款機身已支援。** 詳見 [無線直連驗證版](docs/LUMIX無線直連驗證版.md)。

Drive 上傳已加入獨立網絡選擇：相機 Wi-Fi 沒有網際網路時，在允許流動數據的設定下請求 4G／5G，並把 Drive 請求送往該可用網絡。保留「只用 Wi-Fi」與手動暫停偏好；網絡切換不清除已記錄的續傳進度。手機同時收相與流動上傳仍待實機驗證。

Drive 上傳會為同一帳戶一次預取 10 個檔案 ID。已分配的 ID 會在傳送前寫入佇列，供斷線續傳使用。上傳完成回覆包含完整檔案資料時會直接核對 ID、目的資料夾、大小及校驗碼。回覆資料不足或中斷時會另向 Drive 查詢。

在「紀錄 → 選擇場次 → 每張 JPG 耗時」可查看接收、排隊、傳送 JPG 及 Drive 核對時間，點「更新」可查看最新紀錄。接收計算手機開始讀取到讀完原圖的時間，品牌相機 App 模式計算從其相簿複製的時間。排隊是入列至首次開始處理，包含當時的暫停或離線等待。上傳計算 JPG 資料請求（含回應），核對計算讀取及比對 Drive 檔案資料的時間，兩者累計已記錄的重試。四項不包含本機雜湊、建立雲端資料夾等時間。「—」表示未有量測值。

在「紀錄」開啟場次，點「需處理」可查看每項失敗的 JPG 檔名和原因。「只重試本場」會將目前帳戶在該場的失敗項目加入待傳。已手動暫停時，可在 Google Drive 設定點「繼續待傳佇列」。

停拍後，首頁交付紀錄顯示上一場的活動名稱、Drive 資料夾、已收、待傳、已核對及需處理張數。點「開啟資料夾」可查看該場原定的 Drive 位置。啟用自動上傳時，重新開啟 App 會檢查目前帳戶的待傳佇列，並按照 Wi-Fi 設定補傳。手動暫停後，請在 Google Drive 設定按「繼續上傳」。

首頁點一下照片可開啟全螢幕大圖，單擊關閉。大圖內雙擊可在點按位置放大至兩倍，再雙擊還原。左右滑動翻相，雙指張開或合攏縮放，放大後單指拖動查看細節。按「回到最新」可繼續跟隨新照片。橫向時，照片在左，功能導覽在最右。

首頁依本場顯示最新完整 JPG、手機已收、Drive 待傳和已核對張數。停拍後顯示上一場。Wi-Fi 接收提供相機 FTP 直傳及品牌 App 相簿接收，接法及各雲端的上傳方式見[無線接收與雲端](docs/無線接收與雲端.md)。

完整 JPG 在校驗後發佈到手機的 `DCIM/CAM LINK` 相簿。手機在 Wi-Fi 上最多同時傳兩張，使用流動網絡時逐張傳。Drive 會逐張比對大小及校驗碼。

Android 10 以上的 USB Host／PTP 原圖接收與 Google Drive 上傳 App。2026-11-04 已有 LUMIX S1R2（DC-S1RM2、韌體 1.6）接收 10 張 JPG 並通過 Drive 上傳校驗的紀錄；另有 DC-S1 實收紀錄。S1M2（韌體 1.5）另有 11 張實收及 Drive 核對紀錄。長連拍完整性及拍攝影響仍待驗證。依使用者指示暫緩 100 張測試。

開發依據：[開發指令書](docs/開發指令書.md)。USB 操作：[實機測試步驟](docs/實機測試步驟.md)。Google 登入及操作：[Google Drive 設定與使用](docs/Google-Drive設定與使用.md)。

Google Drive 已實作帳戶授權、建立／選擇 App 可存取資料夾、原圖自動排隊、SQLite 持久佇列、暫停／繼續、Wi-Fi 選項、最大 32 MiB 分段斷點續傳、預配置 file ID 避免重複、雲端 metadata 校驗及報告匯出。已在 manhochong 的既有 Cloud 專案新增 Cam Link Android client，真實 Flip6 Google 授權及 Drive 帳戶查詢成功。先前實收的 10 張 JPG（46,846,464 bytes）已全部上傳及核對，耗時 85.493 秒，手機原檔保留。實測不代表活動連拍上傳速度已達標，詳見 docs/驗證結果.md。

## 建置

需 Python 3.11+、JDK 25（本次已驗證）、Android SDK platform android-36、build-tools 36.0.0 和 NDK 28.2.13676358。使用 Gradle wrapper 9.3.1、Android Gradle Plugin 9.1.0、Google Play services auth 21.6.0。首次需下載依賴，快取齊全後可加 `--offline`。JNI 提供 arm64-v8a、armeabi-v7a、x86_64，使用 16 KiB ELF 對齊；target SDK 維持 35。

```powershell
& 'C:\Users\user\AppData\Local\Python\pythoncore-3.14-64\python.exe' tools/build.py
```

可用 `--sdk` 和 `--jdk` 指定路徑。輸出 `release/CamLink-0.2.24.apk`，本地測試簽章保存在 `.build/usb-test.keystore`，不是正式發行金鑰。保留該檔才能原地更新測試版；原始碼 ZIP 不包含私鑰，其他電腦自行產生的簽章不能覆蓋原安裝，亦需重新登記 OAuth SHA-1。建置腳本同時執行雲端單元測試、lint 並產生本機實機檢查套件。

0.1.2 先 OpenSession 再 GetDeviceInfo；USB bulk 採 16 KiB 分塊。JNI 只對 Android 已授權的 USB fd 執行 bulk ioctl，保留實際 errno、端點與耗時；不執行裝置重設或私有相機控制命令。這是對 0.1.1 首次讀取快速失敗的相容性調整與診斷強化，尚未證明已修復相機連線。

0.1.2 後續實機已成功建立會話並讀到相機回報 DC-S1／韌體 2.4；卡槽篩選的 GetObjectHandles 回覆 2006。0.1.3 在這個回應下改用全儲存區查詢（FFFFFFFF／0／0），成功後快取查詢方式；不對 Busy、逾時或其他錯誤盲目改參數。清單全部成功才建立基線。這輪機身不作為 S1M2／S1R2 的驗收證據。

0.1.3 實機已收到 10 張 JPG；舊驗證器把主 JPEG EOI 後的附加資料誤判成失敗。0.1.4 完整保留並雜湊尾端資料，將尾端 bytes 數記入 CSV；仍要求完整 JPEG 結構、正確大小與尺寸。10 張實收檔案在電腦端全部完整解碼為 6000×4000，無解碼警告；尚未與獨立卡檔比對。原始 0.1.3 session／失敗紀錄保留，另存離線複驗結果，不追改歷史報告。

## 測試

```powershell
& 'C:\Users\user\AppData\Local\Python\pythoncore-3.14-64\python.exe' tools/test.py
```

主機測試針對封包分段、交易錯位、容器大小、錯誤回應、JPG 結構截斷、去重／重試，以及卡檔 SHA-256 多重集合比對。它們不證明實機 USB、拍攝幀率或相機相容性。

雲端 protocol 檢查：`gradlew.bat :app:testDebugUnitTest`。Flip6 的本地實機檢查以 `app-debug-androidTest.apk` 和 `am instrument -w hk.camlink.usb.test/hk.camlink.usb.CloudDeviceChecks` 執行，只使用獨立測試檔與佇列，不呼叫 Google，不清除既有資料。真實 OAuth 與既有相機 JPG → Drive 已通過；實網斷線續傳、邊拍邊傳及拍攝影響仍待實測。真實雲端檢查需另外明確指定 mode、account 和 upload_session，會在指定帳戶建立資料夾及上傳該輪照片，不能當作無副作用的本地測試。

## 接收範圍

0.1.4 最新一輪在首次補掃時因 PTP 長度／交易編號檢查失敗而停止，沒有收到 JPG。0.1.5 新增 12-byte 容器標頭及傳輸計數診斷，維持嚴格驗證；根因和連拍穩定性仍待實機確認，不能視為修復版。詳見 `docs/驗證結果.md`。

0.1.5 在 2026-10-31 16:04 的 DC-S1 實測正常接收 10 張 JPG（46.85 MB），0 失敗、0 待處理並正常結束。電腦端全數解碼成功且 hash 符合手機紀錄；純傳輸平均 21.55 MB/s。上一輪異常未重現但根因未確定，仍需 100／300 張連拍、獨立卡檔比對及目標 S1M2／S1R2 實測。

支援 LUMIX，並實驗接收 Sony、Canon、Nikon、Fujifilm 透過標準 USB Still Image（6/1/1）公開的卡內 JPG。各品牌的專用遙控或 RAM 傳輸模式另需適配。讀取相機宣告的標準資料操作，不發送刪圖、拍照、格式化、屬性設定或猜測的私有控制指令。若 PC(Tether) 未暴露標準存圖物件，匯出報告後依該機實際協議增加支援；不把 PC(Storage) 的讀卡成功當作聯機拍攝成功。

首次建立現有物件基線；其後使用 ObjectAdded 事件和可調整週期的完整 handle 清單補掃，GetObject 串流到 app 外部私有目錄，獨立執行 JPEG 結構、大小和 SHA-256 檢查。基線可能耗時，待畫面顯示「可以拍攝」再拍攝。

重連會開新 session；不自動補回上一輪斷線期間的照片。不處理相機在同一 session 內重用物件 handle（勿在接收期間刪圖、格式化或換卡）。卡上物件消失而事件已漏掉時，只能由獨立卡檔集合發現缺圖。匯出診斷 ZIP 不含照片。卸載 App 會刪除手機暫存，請先備份。

USB 傳輸讀取逾時會停止 session，避免在資料流錯位後繼續發命令。忙碌與暫未可讀的 handle 最多自動重試 6 次，之後顯示失敗，可按補掃重試。單 JPG 上限 512 MB，至少保留 512 MB 可用儲存空間；每次測試最長 4 小時。

JPEG 檢查驗證標記、尺寸、掃描段、結尾及檔案大小，不進行完整熵解碼。與獨立記憶卡原檔 SHA-256 相同才確認原檔位元組一致。
