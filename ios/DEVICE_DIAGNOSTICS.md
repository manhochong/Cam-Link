# DC-S1RM2／iPad USB 接收診斷：build 36–40

使用者提供的 `CamLink-camera-diagnostics.txt` 顯示 App 0.2.25（36），iPadOS 26.5.2。三次相機權限及內容授權均成功，三次 `SESSION_OPEN` 均成功；三次 `BASELINE` 都是 0 個物件。日誌有 56 次 16-byte PTP 事件，但沒有 `ITEMS_ADDED` 或 `DOWNLOAD_BEGIN`。

因此這次測試卡在「取得可下載相片物件」之前。報告不能支持「電腦上傳失敗」或「JPG 下載後損壞」的判定。也不能由事件長度判斷每個事件一定是 ObjectAdded；build 36 沒有記錄事件代碼與參數。搜尋逾時後相機仍成功開啟，截圖中的線材建議可能是未清除的舊訊息，不應當作目前斷線的證據。

Android 會重新執行標準 PTP 的 GetStorageIDs／GetObjectHandles；對 LUMIX 的 ObjectAdded 事件，還會用事件攜帶的 handle 取得 ObjectInfo 和 Object。iOS build 36 的 timer、重試按鈕與 PTP 事件回呼只重新讀取 ImageCaptureCore 的既有目錄；當目錄一直是空的，就無法建立任何下載工作。這是已確認的應用程式層差異，不是已證明的 Panasonic 私有協定或韌體問題。

Apple 的 `requestSendPTPCommand` 在 iOS／iPadOS 13 起可用，completion 型別是兩份沒有參數標籤的 `Data` 與 error。官方 discussion 以 response、data 描述；先前版本據此硬認第一份是 response，但 build 37 的實機長度顯示這個 adapter 假設不可靠。build 38 改為嚴格驗證哪份是完整 type-3 response，再把另一份作 payload，而非單純根據長度交換。原生介面仍只用於標準唯讀物件查詢，USB 連線與 session 由 ImageCaptureCore 管理。[1] PTP 事件回呼本身只提供事件資料，不能把收到事件直接等同於已有 ICCameraFile。[2]

Apple 的 `requestEnableTethering()` 僅適用 macOS，不能拿來解決 iPad 問題。`tetheredCaptureEnabled` 是可讀狀態，不是 iPad 上可任意設定的開關。[3] Panasonic 的 DC-S1RM2 指南記錄 PC(Tether) 與 LUMIX Tether 的 PC 使用流程，但並未保證 iPad 原生目錄會採用同一方式更新。[4]

build 37 起已加入黑底按鈕文字與 iPad 直向比例修正。收檔端補上有界限、序列化的標準 PTP 唯讀查詢／下載路徑，並記錄事件代碼、handle、目錄及回應碼。不發送刪除、拍攝、格式化、重設或相機屬性變更命令。仍須在同一 iPad／相機實測後，才能確認實機照片接收已恢復。

多雲端傳送也是未完成的移植範圍：build 36 只有本機保存與電腦 Receiver。build 37 已加入 WebDAV 上傳／讀回核對及批量系統分享，但 Google Drive／OneDrive 直接登入仍需原生 OAuth 設定；不能以無效按鈕冒充 Android 功能相等。

2026-11-08 Codemagic smoke `6af039d024e1ec2375577094` 已在 Mac runner 完成 `PTPCodecChecks: 431 offline checks passed; no camera operations performed.`，並完成 iPhone SDK unsigned 編譯。完整候選 build 37 的 Codemagic 建置 `6af03b8f24e1ec237557710f` 亦已通過 codec 測試、所有新 Swift 檔案的 Apple SDK 編譯、簽名 IPA 匯出和最終 metadata 檢查，Apple uploader 回覆 `UPLOAD SUCCEEDED with no errors`。App Store Connect 已處理完成，build 37 為 `Testing`，已加入 `CamLink Internal`。可在 TestFlight 更新至 `0.2.25 (37)`；沒有 USB 硬體或 WebDAV 遠端實測，仍需使用者驗證。

## build 37 實機回報與 build 38 修正

2026-11-08 09:15:52 UTC，DC-S1RM2 原生 session 已開啟，完整 native 目錄仍是空的，控制／PTP 授權也為 Authorized。程式已成功選擇 PTP fallback，但第一次 `GetDeviceInfo`，opcode `1001`，在約 4 ms 回傳後立即停止：`bytes=12 responseBytes=235`，錯誤 `Malformed or truncated PTP response length`。這不是使用者拒絕權限，也尚未到電腦上傳階段。

build 37 的 adapter 把 callback 第一份 235 bytes 當 response，第二份 12 bytes 當 data。嚴格 PTP response container 應是 12–32 bytes，因此第一關一定失敗。這些長度符合「資料在第一份，response 在第二份」的情況；報告未附兩份完整原始內容，所以新版還會用 header 及 response code 驗證這個判讀，不能只依長度交換或跳過驗證。先前 431 項檢查覆蓋 codec，沒有測到 native adapter 的 callback 配對，這個缺陷屬於 App，而非使用者操作。

build 38 的同一 normalizer 用於實際 adapter 和回歸測試。只有一份完整、type-3、標準 response-code 範圍的 response 才接受；兩份都像 response 或兩份皆不合法均拒絕。response 錯誤碼不會被 payload 大小或空資料遮住。保留 byte cap、完整資料／JPG 檢查、序列佇列與逾時保護。新增 `PTP_NATIVE firstBytes／secondBytes／firstResponse／secondResponse` 與 `responseSlot` 日誌，不輸出照片內容或相機序號。

後續 `C101`、`C107`、`C104` 是廠商事件，這份報告不含標準 `4002` ObjectAdded。其參數不可直接當 JPG handle。修正首個查詢後，再以 fresh inventory 與標準查詢結果確認相機是否暴露新照片；目前不據此增加廠商寫入、拍攝或屬性命令。build 38 已完成雲端編譯與內部分發；是否真的可查詢到相片並下載，仍需 iPad 實機驗證。

Codemagic build 38 `6af03f0f24e1ec237557723a` 已實際在 macOS runner 執行回歸測試，輸出 `PTPCodecChecks: 503 offline checks passed; no camera operations performed.`。新增 callback case 使用合成、有效的 235-byte DeviceInfo 與 12-byte response；這是重現長度與角色的測試資料，不是使用者相機回傳的原始內容。完整 iOS SDK 編譯、簽名匯出與最終 metadata 檢查均通過；Apple uploader 在 09:24:23 UTC 回覆 `UPLOAD SUCCEEDED with no errors`。已核實 App Store Connect build 38 為 `Testing`，且加入 `CamLink Internal`。可在 TestFlight 更新至 `0.2.25 (38)`，重新接線後先測卡內 JPG，再測 fresh baseline 之後的新拍 JPG。若仍失敗，提供 build 38 新診斷與相機 USB 模式；目前不能宣稱硬體相容已修復。

## build 38 實機回報與 build 39 metadata 修正

使用者的新診斷顯示 build 38 在 2026-11-08 09:29:46 UTC 收到 `PTP_NATIVE opcode=1001 firstBytes=235 secondBytes=12 firstResponse=not-response secondResponse=2001`；下一行是 `response=2001 responseSlot=second bytes=235`。這已實機確認 callback 角色修正有效，而且相機的 GetDeviceInfo 回應成功。現在停在 `Malformed or truncated PTP DeviceInfo dataset trailing bytes`，不是原來的 response length，也不是系統拒絕授權。

程式已依欄位長度和 UTF-16 規則讀完標準 DeviceInfo，連 SerialNumber 也通過邊界檢查，但 `requireEnd` 因仍有剩餘資料而拒絕整份 metadata。報告沒有 raw dataset、已讀 offset 或剩餘 bytes 數，所以不能斷言尾端一定為填充或已知 Panasonic 擴充。libgphoto2 的 `ptp_unpack_DI` 解析標準欄位後不強制 offset 等於整份長度；其末端識別字串甚至採寬鬆處理。這支持對描述性 DeviceInfo 的尾端採相容處理，而不代表任何照片 payload 都可忽略尾端。[5]

build 39 候選版只移除 DeviceInfo 標準欄位後的 exact-end 限制：所有標準欄位仍完整解析，保留 4 MiB metadata 總上限、陣列數量／剩餘大小檢查及 UTF-16 結尾／代理對檢查。未解釋的尾端不會當作 operation、handle 或命令，也不儲存或輸出內容。新增 `PTP_DEVICE_INFO_LAYOUT` 記錄 totalBytes、standardBytes、trailingBytes、zero-filled／opaque 分類、StandardVersion 和 vendor ID，仍不公開序號。StorageIDs、ObjectHandles、ObjectInfo、response container、照片大小、JPG 驗證與 SHA-256 保持原有嚴格檢查；不新增相機設定或刪除命令。

回歸測試使用合成的零尾端與非零尾端，並涵蓋完整標準欄位截斷、非法字串及超過 metadata 上限。這些資料不是實機 235 bytes 的副本。Codemagic `6af0428a24e1ec237557736a` 已實際完成 `PTPCodecChecks: 575 offline checks passed; no camera operations performed.`；完整 Apple SDK archive／IPA export 和最終 metadata 檢查也通過。Apple uploader 在 09:39:19 UTC 回覆 `UPLOAD SUCCEEDED with no errors`。2026-11-08 09:43 UTC 已確認 App Store Connect build 39 為 `Testing`，已加入 `CamLink Internal`，群組仍只有原來 1 位測試者，繁體中文 What to Test 已儲存。可在 TestFlight 更新至 `0.2.25 (39)`；列出及下載照片仍待實機確認。

下一次先測卡內既有 JPG，建立基本列檔／下載的證據，再測新拍 JPG。若仍失敗，分享 build 39 的新報告與相機 USB 設定頁／模式。報告中的 `mode=接收新拍 JPG` 是 App 模式，不是相機的 PC(Tether)／PC(Storage) USB 模式；這項相機設定目前仍未提供，不應臆測。

## build 39 實機下載與 JPG 驗證拒絕

2026-11-08 使用者提供的 `pasted_content_3.txt` 是 build 39 卡內 JPG 接收報告：最終目錄 154 個物件，74 個失敗，成功接收 0 張。可見日誌含 56 次完整 GetObject 回傳，均為 `2001`，payload 大小與 ObjectInfo 宣告大小相等。原生資料和正規化 payload 的大小也相等，這些可見照片沒有被誤剝除 12-byte 頭。這次已越過 DeviceInfo 與列檔階段，停止位置是本機 JPG 驗證，不是首頁／紀錄的清單同步問題。

`validateJPEG` 原本要求首兩 bytes 是 `FF D8`，而且整份檔案最後兩 bytes 是 `FF D9`；任一條件失敗均只回報「缺少 SOI／EOI」。這份報告未包含影像邊界，因此不能知道是哪一端失敗。56 個可見大小都是 512-byte 整數倍，值得查驗尾端填充，但這不是填充證據。JPEG 檔案在主影像 EOI 後可能仍有尾端資料，且 APP／EXIF 內嵌縮圖也可能出現 `FF D9`；不能拿任意最後一個 marker 截斷或直接繞過驗證。[6] [7]

PTP 接收先寫自己的暫存檔，再驗證，只有成功才 rename 並發送 `onJPEG`。首頁預覽與紀錄頁都使用 `ShootSession.photos`，所以此次沒有任何驗證成功就不會出現照片。失敗暫存檔會被刪除，不會成為假已收紀錄；相機原檔沒有被刪除。400 條 rolling log 已被大量重試覆蓋，此報告不是全部 74 張的完整下載歷史，也沒有完整初始化資訊。

build 40 候選修正用主 JPEG marker 結構定位 EOI，跳過 metadata 區段並處理 entropy stuffing／restart／多次 scan，再交由 Apple ImageIO 解碼。保留原始總大小核對，僅容納有界且純 `00`／`FF` 的尾端填充；不接受未知非填充資料，不裁切、不重新壓縮，SHA-256 仍覆蓋保存的整份原檔。這是處理已知驗證缺口的候選修正，尚未證明此次相機內容屬於可接受的填充。新增區分 SOI 起點、EOI 結構位置與尾端分類的摘要，不輸出照片、EXIF 或尾端原文。

候選版紀錄頁會顯示真實接收失敗與匯出診斷入口，不只顯示「尚未收到」；確定的格式拒絕不再重抓同一張大型照片六次。每次開始接收會清空上一場 rolling log，保留本場初始化和首幾個 JPG 結果摘要，避免全卡重試掩蓋關鍵證據。Codemagic build 40 `6af0478124e1ec23755774f1` 已在 macOS runner 真正執行 `PASS: 59 checks (generated fixtures; no camera-capture cause inferred)`，包含 ImageIO 生成的 baseline／progressive JPEG、完整解碼、允許填充與截斷／錯誤／未知尾端拒絕。完整 signed IPA 與最終相機／本機網路用途及 QR metadata 檢查通過，Publishing 明示 version `0.2.25`、code `40`；Apple uploader 10:00:27 UTC 回覆 `UPLOAD SUCCEEDED with no errors`，10:02 UTC 已核實 TestFlight `Testing`、既有 `CamLink Internal` 群組及原來 1 位測試者。可更新至 `0.2.25 (40)`，但實機收檔仍待驗證。使用者若能提供安全、未編輯的相機原始 JPG，可獨立確認影像的實際起訖與尾端，不必把原圖公開上傳或提交 GitHub。

## 其他相機的支援範圍

iOS 目前沒有完成實機驗收的相機型號清單；DC-S1RM2 也仍是修正候選版測試中。標準 PTP 讀取不按品牌限制，但相機必須提供標準物件查詢／讀取能力，USB 模式與 iPadOS 也須相容。讀取卡內既有 JPG 與 USB 連線中拍攝新 JPG 是兩項不同能力，不能以其中一項成功推斷另一項已支援。

Android `MainActivity.java` 的既有文案記錄 LUMIX S1、S1 II、S1R II 有實拍紀錄；Sony、Canon、Nikon、Fujifilm 明確標為實驗接收。`CameraProfile.java` 為這些品牌提供 USB／部分事件解析，但這不是所有機型的相容保證，也不是 iOS 已支援的證據。若要評估其他相機，需確切型號、韌體及 USB 模式，再分別測卡內匯入與新拍接收。此結論以既有專案文案與原始碼為基準，不是品牌廠商對 Cam Link 的認證。

## References

[1]: https://developer.apple.com/documentation/imagecapturecore/iccameradevice/requestsendptpcommand%28_:outdata:completion:%29 "Apple standard PTP command interface"
[2]: https://developer.apple.com/documentation/imagecapturecore/iccameradevicedelegate/cameradevice%28_:didreceiveptpevent:%29 "Apple PTP event delegate"
[3]: https://developer.apple.com/documentation/imagecapturecore/iccameradevice/tetheredcaptureenabled "Apple tethered capture status"
[4]: https://eww.pavc.panasonic.co.jp/dscoi/DC-S1RM2/html/DC-S1RM2_DVQP3245_eng/0161.html "Panasonic DC-S1RM2 tethered recording"
[5]: https://raw.githubusercontent.com/gphoto/libgphoto2/master/camlibs/ptp2/ptp-pack.c "libgphoto2 DeviceInfo dataset decoding"
[6]: https://stackoverflow.com/questions/39486044/what-is-known-about-trailing-data-after-the-eoi-marker-ffd9-in-jpeg-images "JPEG trailing data observations"
[7]: https://www.imperialviolet.org/binary/jpeg/ "JPEG marker and entropy stream structure"
