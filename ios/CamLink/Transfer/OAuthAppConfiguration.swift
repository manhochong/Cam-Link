import Foundation

/// Public client identifiers only. Secrets and tokens must never be placed in Info.plist.
/// URL schemes are compiled into the app; changing IDs in a settings screen alone is not sufficient.
enum OAuthAppConfiguration {
    static var settings: OAuthPublicClientSettings {
        settings(in: .main)
    }

    static func settings(in bundle: Bundle) -> OAuthPublicClientSettings {
        OAuthPublicClientSettings(
            googleIOSClientID: bundle.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "",
            microsoftClientID: bundle.object(forInfoDictionaryKey: "CamLinkMicrosoftClientID") as? String ?? "",
            microsoftRedirectURI: bundle.object(forInfoDictionaryKey: "CamLinkMicrosoftRedirectURI") as? String
                ?? "msauth.hk.camlink.ios://auth"
        )
    }
}
