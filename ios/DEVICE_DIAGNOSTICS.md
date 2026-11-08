# DC-S1RM2／iPad build 36 診斷判讀

使用者提供的 `CamLink-camera-diagnostics.txt` 顯示 App 0.2.25（36），iPadOS 26.5.2。三次相機權限及內容授權均成功，三次 `SESSION_OPEN` 均成功；三次 `BASELINE` 都是 0 個物件。日誌有 56 次 16-byte PTP 事件，但沒有 `ITEMS_ADDED` 或 `DOWNLOAD_BEGIN`。

因此這次測試卡在「取得可下載相片物件」之前。報告不能支持「電腦上傳失敗」或「JPG 下載後損壞」的判定。也不能由事件長度判斷每個事件一定是 ObjectAdded；build 36 沒有記錄事件代碼與參數。搜尋逾時後相機仍成功開啟，截圖中的線材建議可能是未清除的舊訊息，不應當作目前斷線的證據。

Android 會重新執行標準 PTP 的 GetStorageIDs／GetObjectHandles；對 LUMIX 的 ObjectAdded 事件，還會用事件攜帶的 handle 取得 ObjectInfo 和 Object。iOS build 36 的 timer、重試按鈕與 PTP 事件回呼只重新讀取 ImageCaptureCore 的既有目錄；當目錄一直是空的，就無法建立任何下載工作。這是已確認的應用程式層差異，不是已證明的 Panasonic 私有協定或韌體問題。

Apple 的 `requestSendPTPCommand` 在 iOS／iPadOS 13 起可用。回呼參數順序是 response、data、error。可以利用此原生介面實作標準唯讀物件查詢，繼續由 ImageCaptureCore 管理 USB 連線與 session。[1] PTP 事件回呼本身只提供事件資料，不能把收到事件直接等同於已有 ICCameraFile。[2]

Apple 的 `requestEnableTethering()` 僅適用 macOS，不能拿來解決 iPad 問題。`tetheredCaptureEnabled` 是可讀狀態，不是 iPad 上可任意設定的開關。[3] Panasonic 的 DC-S1RM2 指南記錄 PC(Tether) 與 LUMIX Tether 的 PC 使用流程，但並未保證 iPad 原生目錄會採用同一方式更新。[4]

下一個候選版本會同時修正黑底按鈕文字不可見及 iPad 直向比例。收檔端補上有界限、序列化的標準 PTP 唯讀查詢／下載路徑，並記錄事件代碼、handle、目錄及回應碼。不發送刪除、拍攝、格式化、重設或相機屬性變更命令。仍須在同一 iPad／相機實測後，才能確認實機照片接收已恢復。

多雲端傳送也是未完成的移植範圍：目前 iOS 只有本機保存與電腦 Receiver。Google Drive、OneDrive 及 WebDAV 必須提供真正登入／憑證和可靠上傳流程，不能以無效按鈕冒充 Android 功能相等。

2026-11-08 Codemagic smoke `6af039d024e1ec2375577094` 已在 Mac runner 完成 `PTPCodecChecks: 431 offline checks passed; no camera operations performed.`，並完成 iPhone SDK unsigned 編譯。此建置驗證 PTP reader 與 codec，還未包含完整接收整合與雲端頁；沒有 USB 硬體測試。完整候選 build 37 的簽名建置與實機驗收是後續步驟。

## References

[1]: https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand%28_:outdata:completion:%29 "Apple standard PTP command interface"
[2]: https://developer.apple.com/documentation/imagecapturecore/iccameradevicedelegate/cameradevice%28_:didreceiveptpevent:%29 "Apple PTP event delegate"
[3]: https://developer.apple.com/documentation/imagecapturecore/iccameradevice/tetheredcaptureenabled "Apple tethered capture status"
[4]: https://eww.pavc.panasonic.co.jp/dscoi/DC-S1RM2/html/DC-S1RM2_DVQP3245_eng/0161.html "Panasonic DC-S1RM2 tethered recording"
