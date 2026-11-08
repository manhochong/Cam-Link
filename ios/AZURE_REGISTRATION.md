# Cam Link iOS 獨立 Azure 註冊

核對日期：2026-11-09（香港時間）。Azure 已建立並下載已保存的 Microsoft Graph manifest；本文件不是 OneDrive 已完成實機驗收的宣告。

## 已核實設定

| 項目 | 設定 |
| --- | --- |
| 應用程式名稱 | Cam Link iOS |
| Application／Client ID | `16437f88-79e4-499f-8cb3-7f07c9146e0c` |
| Application Object ID | `d1a7fad7-308a-401c-bea4-f4eb98802092` |
| Directory／Tenant ID | `0051d77d-2447-4003-8059-01970cdfbed6` |
| 所屬目錄 | `gonfoliocontactgmail.onmicrosoft.com` |
| Bundle ID | `hk.camlink.ios` |
| 原生回呼 URI | `msauth.hk.camlink.ios://auth` |
| Azure 平台顯示 | iOS／macOS；manifest 保存於 `publicClient.redirectUris` |
| 支援帳戶 | 個人 Microsoft 帳戶，以及任何組織的工作／學校帳戶 |
| `signInAudience` | `AzureADandPersonalMicrosoftAccount` |
| Access token 版本 | 2 |
| Microsoft Graph 委派權限 | `openid`、`profile`、`offline_access`、`User.Read`、`Files.ReadWrite` |
| Application permissions | 沒有配置 |
| Client secret／憑證 | 沒有建立 |
| 隱含授權 token issuance | access token／ID token 均未啟用 |
| `isFallbackPublicClient` | manifest 保留預設 `null`，沒有額外開啟密碼或裝置碼流程 |

Graph `Files.ReadWrite` 讓登入使用者讀寫本人的檔案，並非 `Files.ReadWrite.All`。這次只保存 App 要求的委派權限，沒有替整個目錄授予管理員同意。使用者在 iPad 的正式 OAuth 同意畫面授權；組織帳戶亦受該組織的同意政策約束。

Microsoft 官方文件說明 `isFallbackPublicClient` 是無法由回呼判定 Client 類型時的回退設定；本 App 已保存原生回呼，採 authorization code＋PKCE，不需要把 client secret 打包進 iPad App。Client ID 是公開識別碼，不是密碼。

## 与 Gonfolio 的分離

Gonfolio 原 Client ID 為 `90cae47d-4d81-44fd-b973-646056949107`。本次建立新的 Cam Link iOS App，沒有修改 Gonfolio 的回呼、權限、憑證或帳戶類型，也沒有更換 Android 原配置。兩個 App 可以使用同一個管理帳戶／目錄，但用各自的 Client ID 與回呼，登入授權互相獨立。

## App 來源接線

公開設定已保存於 `OAuthClients.json` 和 `AzureRegistration.json`。App 真正讀取的 `CamLink/Info.plist` 已加入 `CamLinkMicrosoftClientID`，原有 `msauth.hk.camlink.ios` URL scheme、Google Client、相機權限、`camlink` QR scheme 和加密豁免旗標保留。JSON／plist 一致性與既有 metadata 檢查已通過。

## 尚待完成

OneDriveStore、設定畫面、排程和獨立傳送紀錄仍需完成整合；雲端原圖不能沿用電腦的單一 `uploaded` 旗標。完成後需在 Codemagic 進行真正 macOS 回歸與完整 iOS SDK 編譯，檢查 signed IPA metadata，再確認新的內部 TestFlight build 已可更新。現有可用版本仍為 build 41。

最後需於 iPad 實測登入、選擇／建立資料夾、上傳原始 JPG、核對遠端內容以及重新開啟 App 後的授權／待傳紀錄。沒有這些結果前，不能把 Azure 註冊完成等同於 OneDrive 已可用。

## 參考

- [Microsoft Graph application resource](https://learn.microsoft.com/en-us/graph/api/resources/application?view=graph-rest-1.0)
- [Microsoft OAuth authorization code flow／PKCE](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow)
- [Microsoft iOS 原生回呼](https://learn.microsoft.com/en-us/entra/msal/objc/redirect-uris-ios)
