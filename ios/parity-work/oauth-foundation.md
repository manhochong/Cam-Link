# Native OAuth foundation

Author: Manus AI. Provider guidance checked 2026-11-08. Only `CamLink/Transfer/OAuthSupport.swift`, `OAuthSupportTests.swift`, and this file were added/edited for this task. No app registration, login, callback-plist edit, camera change, Git operation, or CI execution was performed. This foundation is **not a ready Google Drive or OneDrive uploader** and does not establish remote upload verification.

The parent subsequently supplied a real Google iOS public registration for `hk.camlink.ios`: `518900347391-4fh5i9n3q2jpgh70aujo6ofs1i715dqu.apps.googleusercontent.com`, with reversed scheme `com.googleusercontent.apps.518900347391-4fh5i9n3q2jpgh70aujo6ofs1i715dqu`. Drive API was confirmed enabled. The parent owns `ios/OAuthClients.json`, `Info.plist`, `project.yml`, and `Transfer/OAuthAppConfiguration.swift`; this foundation task did not edit those files. Following provider modules should use **`OAuthAppConfiguration.settings`** as their default `OAuthPublicClientSettings` and read **`ios/OAuthClients.json`** for the actual public registration, not guess IDs. Microsoft ID remains blank pending the parent's registration/login work. Public identifiers are not credentials; never put tokens in that manifest or plist.

## Exact provider interface

All types have app-module/internal visibility. They are shared by providers in the CamLink target, not a separate framework. Swift language mode 5 and deployment iOS 16 are supported by the design. The signature reference below is the exact API providers must call; declarations without bodies are a reference, not a standalone compilable file.

```swift
struct OAuthConfiguration: Sendable, Equatable {
    let clientID: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let redirectURI: URL
    let scopes: [String]
    let extraAuthorizationParameters: [String: String]

    init(clientID: String, authorizationEndpoint: URL, tokenEndpoint: URL,
         redirectURI: URL, scopes: [String],
         extraAuthorizationParameters: [String: String] = [:]) throws
}

struct OAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scope: String?
    let tokenType: String

    init(accessToken: String, refreshToken: String? = nil, expiresAt: Date,
         scope: String? = nil, tokenType: String = "Bearer")
    func isUsable(at date: Date = Date(), leeway: TimeInterval = 60) -> Bool
}

struct OAuthCredentialKey: Codable, Hashable, Sendable {
    let provider: String
    let clientID: String
    let accountID: String
    init(provider: String, clientID: String, accountID: String)
}

protocol OAuthCredentialVault: Sendable {
    func load(for key: OAuthCredentialKey) async throws -> OAuthToken?
    func save(_ token: OAuthToken, for key: OAuthCredentialKey) async throws
    func delete(for key: OAuthCredentialKey) async throws
}

actor KeychainOAuthCredentialVault: OAuthCredentialVault {
    init(service: String = "hk.camlink.ios.oauth.v1")
    // Implements the three protocol methods above.
}

@MainActor
protocol OAuthBrowserSession: AnyObject {
    func start(url: URL, callbackScheme: String,
               completion: @escaping @MainActor (Result<URL, OAuthFailure>) -> Void) throws
    func cancel()
}

@MainActor
final class OAuthCoordinator {
    let vault: any OAuthCredentialVault
    init(browser: any OAuthBrowserSession,
         http: OAuthHTTPClient = OAuthHTTPClient(),
         vault: any OAuthCredentialVault,
         authorizationTimeout: TimeInterval = 90)

    // UIKit-only convenience initializer; default anchor is the foreground-active key window.
    convenience init(http: OAuthHTTPClient = OAuthHTTPClient(),
                     vault: any OAuthCredentialVault = KeychainOAuthCredentialVault(),
                     authorizationTimeout: TimeInterval = 90,
                     anchorProvider: @escaping @MainActor () -> UIWindow? /* default provided */)

    func authorize(_ config: OAuthConfiguration) async throws -> OAuthToken
    func refresh(_ config: OAuthConfiguration, token: OAuthToken) async throws -> OAuthToken
    func cancelAuthorization()
    func store(_ token: OAuthToken, for key: OAuthCredentialKey) async throws
    func validToken(for key: OAuthCredentialKey, config: OAuthConfiguration,
                    leeway: TimeInterval = 60) async throws -> OAuthToken
    func signOut(_ key: OAuthCredentialKey) async throws
}

struct OAuthHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let retryAfter: String? // Numeric, at most 10 characters; not raw metadata.
}

final class OAuthHTTPClient: @unchecked Sendable {
    init(session: URLSession? = nil, timeout: TimeInterval = 20)
    func send(_ request: URLRequest, bearerToken: String? = nil,
              allowedHosts: Set<String>) async throws -> OAuthHTTPResponse
    func exchange(config: OAuthConfiguration, body: Data,
                  previous: OAuthToken? = nil) async throws -> OAuthToken
}

struct OAuthPublicClientSettings: Codable, Equatable, Sendable {
    var googleIOSClientID = ""
    var microsoftClientID = ""
    var microsoftRedirectURI = "msauth.hk.camlink.ios://auth"
    func microsoftConfiguration() throws -> OAuthConfiguration
    func googleReversedClientID() throws -> String
}
```

Instantiate one long-lived `OAuthCoordinator` on MainActor and share it with provider workers. The UIKit convenience call is simply `OAuthCoordinator()`; a scene-aware provider can pass `anchorProvider: { presentingViewController.view.window }`. `authorize(config)` returns a token but **does not invent accountID or persist before identity resolution**. Resolve a stable provider account ID with a trusted API response, construct `OAuthCredentialKey(provider: "microsoft-onedrive", clientID: config.clientID, accountID: graphUserID)`, then call `try await coordinator.store(token, for: key)`. Use `validToken(for:config:)` for subsequent API calls and `signOut(key)` for local forgetting. The account ID lives in the Keychain record alongside access/refresh tokens and expiration, not in the generic token response, which does not consistently contain a trustworthy account ID. Do not use email or decode an unverified ID token to create the key.

`refresh(config, token:)` is a low-level token exchange: it single-flights simultaneous requests for the same configuration/refresh token, preserves an omitted refresh token, and returns a rotated refresh token when provided. It does not store credentials. Sequential callers must use the returned token, not reuse an old rotating token. `validToken` is the durable account-scoped interface: it serializes load/refresh/save per key and rejects client-ID mismatch or concurrent configuration mismatch. Do not build multiple coordinators for the same vault key. Changes of provider authority, client ID, scopes, or account require explicit provider setup/re-consent, not silent reuse of a previously bound destination.

Cancelling a waiter cancels its shared refresh exchange; other waiters on that exchange also receive `.cancelled`. `signOut` blocks new credential work for that key, cancels its pending refresh/store, waits for persistence to settle, and deletes that key so late refresh/save cannot resurrect it. Sign-out is local only: no consent revocation or browser-cookie clearing, no photo/job deletion and no camera action. A `.http(status: 400, code: .invalidGrant)` normally requires provider UI to offer reauthentication; do not blindly retry it as a transient network failure.

## Native-session and transport guarantees

The actual UI bridge, `OAuthSystemBrowserSession`, is under `#if canImport(UIKit)` and uses a retained `ASWebAuthenticationSession` and retained UIKit presentation context. It never uses an embedded WKWebView. Its native `start` verifies that the exact callback scheme is present in the app's built `CFBundleURLTypes` before opening the browser, and rejects a missing foreground window. The parent's plist/configuration work is separate; Microsoft native login remains deliberately blocked while its client ID is blank, and also fails if its native callback scheme is not installed. UIKit/AuthenticationServices UI code is not compiled in the standalone macOS test target. [5] [6] [14]

Interactive requests use a fresh 256-bit cryptographic state and a fresh 256-bit PKCE verifier, with SHA-256 and unpadded Base64URL S256. The callback is checked before code exchange: the complete serialized destination excluding its response query must equal `redirectURI`, including host, port and encoded path. Prefix/scheme-only matches, fragments, userinfo, missing state, duplicate decoded query keys, conflicting code/error and malformed response parameters fail. State is compared bytewise without early mismatch exit for equal-length values. State and verifier exist only in the transaction's memory. This bridge intentionally supports app-specific **custom schemes**, not iOS 17.4+ HTTPS callback APIs, loopback listeners or OOB flows. Client configuration rejects blank/obvious dummy IDs, insecure endpoints and authorization extras that could override reserved security fields or add a client secret. It cannot prove that an otherwise plausible client ID is registered: provider setup is still required. [1] [4]

There is one global interactive authorization slot across `OAuthCoordinator` instances; a second attempt returns `.busy`. Explicit cancellation, task cancellation, timeout, synchronous browser completion, duplicate completion and stale completion are handled without reusing a transaction. The interactive deadline defaults to 90 seconds and is capped at 180 seconds. HTTP defaults to 20 seconds and is capped at 30 seconds, with both a request timeout and a whole-operation deadline; timeout/task cancellation cancels URLSession work. Authentication may take users away from the foreground camera screen. This adds **no background or lock-screen USB guarantee**.

`OAuthHTTPClient` accepts an injected real `URLSession`, validates HTTPS and exact provider-supplied trusted host sets, rejects manual Authorization-header bypass and token query parameters, and adds bearer only as a header. A per-task URLSession delegate refuses **all** redirects, even same-host redirects; a 3xx or changed response URL is `.redirectRefused`. The task-level delegate is the documented interception point even when a session has its own delegate. The default session is ephemeral without cookie storage, credential storage or cache. Supply an equally isolated injected session in production; injection is a trusted application dependency, not an untrusted plugin interface. Never inject a background URLSession here. [9]

Successful response data is available to provider JSON codecs. Errors contain only fixed descriptions, numeric HTTP status and allowlisted machine codes, not server descriptions, request URLs, query strings, tokens, arbitrary headers or NSError userInfo. `OAuthFailure.localizedDescription` is bounded; use it rather than logging raw response bodies or credentials. Token JSON is bounded and must contain a finite positive expiration and Bearer token type. No client-secret field exists or is sent. Token persistence is Keychain-only, using `AfterFirstUnlockThisDeviceOnly`, a separate OAuth service namespace and provider/client/account key. The existing private `PairCredentialVault` is untouched. Public client settings may be stored in ordinary preferences; token objects must never be put there.

## Microsoft OneDrive setup

A registration owner must create or update the Microsoft Entra application with supported account type **Accounts in any organizational directory and personal Microsoft accounts**. Add the iOS/macOS platform for bundle ID `hk.camlink.ios` and record the generated callback `msauth.hk.camlink.ios://auth` exactly. Confirm it is registered as a native/public client, not Web/SPA/confidential client. The portal's public-client setting must match the chosen native platform; do not create or ship a secret, and do not substitute implicit/password/device flows for authorization code + PKCE. Microsoft's general desktop `localhost`/embedded-nativeclient examples are not the iOS callback recipe; use its iOS redirect registration guidance. [4] [5] [7]

The settings factory supplies:

```text
authorizationEndpoint = https://login.microsoftonline.com/common/oauth2/v2.0/authorize
tokenEndpoint         = https://login.microsoftonline.com/common/oauth2/v2.0/token
redirectURI           = msauth.hk.camlink.ios://auth
scopes                = openid profile offline_access User.Read Files.ReadWrite
extra                 = prompt=select_account
```

`common` is required here for both personal and organizational users; `consumers` would exclude business users, and an organization-only tenant authority would exclude personal users. `offline_access` requests refresh capability. Graph permissions still require user/admin consent and tenant policy may prevent use; this foundation does not supply brokered Authenticator/Intune/Conditional Access features that would require MSAL. [4] [7]

Expose `OAuthPublicClientSettings.microsoftClientID` as an editable public-client setting with **blank default**. It is not a credential. `try settings.microsoftConfiguration()` fails for a missing/obvious placeholder ID before any network operation. There is deliberately no fallback to the Android ID. The existing Android `OneDriveApi.java` has public client ID `90cae47d-4d81-44fd-b973-646056949107` and redirect `work-camera://onedrive`, while its manifest uses a different callback. Reuse of that ID is conditional on the registration owner adding the precise iOS native redirect and confirming personal+business account support; the existing code is not proof of registration. Do not use `work-camera` or `camlink` to share OAuth callbacks between apps/platforms.

After registration, a separate authorized integration change must **append**, not replace, a URL-type entry for scheme `msauth.hk.camlink.ios`. Preserve the existing `camlink` pairing entry and all privacy metadata. In this iOS16 ASWebAuthenticationSession implementation the native session itself receives its callback; do not pass pairing URLs to OAuth or install a generic RootView callback parser. Runtime edits cannot register a new iOS scheme: an arbitrary new redirect requires another signed build. Before storing the credential, use the bearer token with `OAuthHTTPClient.send(..., allowedHosts: ["graph.microsoft.com"])` to read `https://graph.microsoft.com/v1.0/me?$select=id` and obtain the stable Graph ID. Successful sign-in or profile lookup is **not file upload verification**.

## Google Drive setup: use official GIDSignIn

Google's current `native-app` document describes desktop clients and points mobile developers to the Android/iOS authorization guides. It still describes PKCE S256 and external user agents, but it does not establish a current supported hand-written iOS reverse-client-ID callback path. Do not turn its generic `com.example.app:/oauth2redirect` desktop example into a claimed ready iOS configuration. This foundation can parse that URI shape for other native providers, but does **not** provide a guessed Google `OAuthConfiguration` factory. Recommend official Google Sign-In for iOS through Swift Package Manager; its current iOS setup explicitly requires an iOS OAuth client and reversed-client-ID URL scheme. The 2023 custom-scheme restriction announcement concerns Android and Chrome, not a blanket iOS scheme prohibition. [1] [2] [3]

The parent has created the **iOS** OAuth client for `hk.camlink.ios`, confirmed Drive API enabled, and supplied its exact reversed scheme in the parent-owned configuration. Consent screen/audience and test users still need confirmation as required. Android package/SHA-1 registration is not a substitute. Request `https://www.googleapis.com/auth/drive.file` for app-created/user-selected files rather than silently escalating to full Drive scope. Preserve the existing app URL types when applying the parent's Google entry. SDK sign-in must be blocked in provider UI if the runtime client ID is blank or its reversed scheme is absent from the signed plist. [2] [10]

The concrete later integration is:

1. The parent has added SPM repository `https://github.com/google/GoogleSignIn-iOS` to `ios/project.yml`, pinned to **exactVersion 10.1.0**, whose actual official tag the parent checked. The fetched setup guide's 9.0.0 example is not a reason to downgrade the parent's verified pin. Provider code should use the `GoogleSignIn` product and optionally `GoogleSignInSwift` for the official SwiftUI button. This foundation task added no dependency and does not own the parent project file. [2]
2. Obtain `let settings = OAuthAppConfiguration.settings`, validate `settings.googleIOSClientID`, compute `try settings.googleReversedClientID()`, and confirm it matches a compiled URL scheme. Set `GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: settings.googleIOSClientID)`. Do not configure a server client ID or ship a client secret for direct Drive REST calls. [2]
3. Use the SDK's exact async call below from a foreground UIViewController, check `grantedScopes`, and use `addScopes(_:presenting:)` if needed. The SDK is responsible for its native OAuth transaction/PKCE/callback details; do not intercept it with this foundation's guessed redirect parser. [10] [11] [13]
4. Route only Google URLs to `GIDSignIn.sharedInstance.handle(url)` in the app/scene `.onOpenURL` integration, preserving pairing handling for `camlink`. At startup use `restorePreviousSignIn()`. [8] [13]
5. Let the SDK remain the **single owner of Google refresh/cache state**. Serialize its `refreshTokensIfNeeded()` calls in the Google provider before API calls and use its refreshed access token with the same redirect-refusing REST helper. Do not independently rotate the same Google refresh token through `OAuthCoordinator.refresh` while the SDK holds its cache. [10] [11]

```swift
// Future Google provider adapter; requires GoogleSignIn package and registered real client ID.
// Called on MainActor with a real foreground presenter; not part of OAuthSupport.swift.
import GoogleSignIn

let settings = OAuthAppConfiguration.settings
let driveScope = "https://www.googleapis.com/auth/drive.file"
GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: settings.googleIOSClientID)
let result = try await GIDSignIn.sharedInstance.signIn(
    withPresenting: presenter, hint: nil, additionalScopes: [driveScope])
let user = try await result.user.refreshTokensIfNeeded()
guard let accountID = user.userID,
      (user.grantedScopes ?? []).contains(driveScope),
      let expiration = user.accessToken.expirationDate else {
    throw OAuthFailure.invalidResponse
}
let snapshot = OAuthToken(accessToken: user.accessToken.tokenString,
    refreshToken: nil, expiresAt: expiration,
    scope: user.grantedScopes?.joined(separator: " "), tokenType: "Bearer")
let key = OAuthCredentialKey(provider: "google-drive", clientID: settings.googleIOSClientID,
                             accountID: accountID)
try await coordinator.store(snapshot, for: key)
```

The optional shared vault snapshot intentionally has **no duplicated Google refresh token**. Google long-lived access/refresh/account cache remains in the SDK's Keychain storage; its refreshed access-token snapshots can use the shared vault for provider bookkeeping. The Google provider must request fresh tokens through the SDK, not use generic `validToken` for an expired snapshot with no refresh token. `GIDGoogleUser` exposes user ID, granted scopes and token properties; `GIDToken` supplies token string and expiration date. Sign Google out by calling SDK `signOut()` and then `coordinator.signOut(key)` for the snapshot; SDK sign-out is local and does not revoke permissions. [2] [8] [11] [12] [13]

The app-level provider controller must gate **both SDK Google sign-in and native Microsoft sign-in** with one shared interactive-busy state. The foundation's global slot covers its own coordinators; it cannot intercept an independently invoked SDK. Use the SDK's own cancellation behavior rather than claiming `cancelAuthorization()` cancels GIDSignIn. SPM/SDK integration and device cancellation/PKCE behavior remain later acceptance work, not implemented or tested here.

## Tests and honest acceptance level

The standalone async executable in `ios/OAuthSupportTests.swift` uses a MainActor browser mock, an actor memory vault and injected real URLSession/URLProtocol. No live credentials, Keychain items, browser login or external requests are used. It covers the RFC7636 S256 vector, fresh state/verifier, form encoding, reserved parameters, exact redirect/path/host/port/state checks **before network exchange**, duplicate/reentrant/stale callbacks, native-session cancellation, global busy rejection, auth/network deadlines, bearer CRLF protection, HTTP redirect sink refusal, sanitized errors, expiration, refresh-token omission/rotation, single-flight refresh, provider/client/account isolation, local sign-out and sign-out-vs-save/refresh races.

On a Mac or an explicitly authorized future Codemagic macOS step, from repository root:

```bash
xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=minimal \
  -target "$(uname -m)-apple-macosx13.0" \
  ios/CamLink/Transfer/OAuthSupport.swift ios/OAuthSupportTests.swift \
  -o /tmp/oauth-support-tests
/tmp/oauth-support-tests
```

The test target is Foundation networking plus Apple CryptoKit/Security, with no UIKit/AppKit UI required. The Linux sandbox has **no Swift executable**, so the real Swift tests and iOS compile were **not run**. A tree-sitter Swift grammar parse and static security checks passed; they are not type checking, SDK compilation or test execution. No CI workflow was edited or triggered. The existing `ios-testflight-internal` mac_mini_m2 workflow can host this test command after a later authorized integration; a user without a Mac need not install local Xcode.

Before calling provider login ready, run the Mac executable, compile the actual iOS16 app, register real public clients and callbacks, and test signed iPad cancellation, denied consent, cold-start callback behavior, both personal/business Microsoft accounts, expiration/rotation, Keychain restore and account switch. Google additionally requires the official SDK integration and its real callback. None of those live acceptance results are claimed here. Preserve the user-confirmed build41 iPad five-JPG/zero-failed and PC baseline. No USB/PTP/MPF core was rewritten, no camera property/control/delete/vendor-write was added, and foreground pocket mode remains a black foreground screen rather than a background USB guarantee.

## References

[1]: https://developers.google.com/identity/protocols/oauth2/native-app "Google OAuth for desktop apps and native PKCE"
[2]: https://developers.google.com/identity/sign-in/ios/start-integrating "Google Sign-In iOS setup and Swift Package Manager"
[3]: https://developers.googleblog.com/improving-user-safety-in-oauth-flows-through-new-oauth-custom-uri-scheme-restrictions/ "Google custom URI scheme restrictions for Android and Chrome"
[4]: https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow "Microsoft authorization code flow with PKCE"
[5]: https://learn.microsoft.com/en-us/entra/msal/objc/redirect-uris-ios "Microsoft iOS native redirect URIs"
[6]: https://learn.microsoft.com/en-us/entra/msal/objc/customize-webviews "Microsoft native system browsers and ASWebAuthenticationSession"
[7]: https://learn.microsoft.com/en-us/entra/identity-platform/tutorial-mobile-app-ios-swift-prepare-app "Microsoft iOS app registration and personal plus organizational accounts"
[8]: https://developers.google.com/identity/sign-in/ios/sign-in "Google Sign-In lifecycle and local sign-out"
[9]: https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate "Apple per-task URLSession delegate interception"
[10]: https://developers.google.com/identity/sign-in/ios/api-access "Google iOS API scopes and token refresh"
[11]: https://developers.google.com/identity/sign-in/ios/reference/Classes/GIDGoogleUser "Google user identity scopes and native token refresh API"
[12]: https://developers.google.com/identity/sign-in/ios/reference/Classes/GIDToken "Google token value and expiration"
[13]: https://developers.google.com/identity/sign-in/ios/reference/Classes/GIDSignIn "Google exact async sign-in configuration and lifecycle APIs"
[14]: https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsessionerror "Apple native authentication session cancellation codes"
