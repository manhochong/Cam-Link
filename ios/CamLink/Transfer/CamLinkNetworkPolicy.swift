import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Non-secret policy shared by the real upload transports. Tokens never enter UserDefaults.
/// Existing tasks are cancelled by CamLinkRuntime when a restrictive policy changes.
enum CamLinkNetworkPolicy {
    private static var flags: DeliveryPreferences? {
        guard let data = UserDefaults.standard.data(forKey: "hk.camlink.delivery-feedback.preferences.v1") else { return nil }
        return try? JSONDecoder().decode(DeliveryPreferences.self, from: data)
    }
    static func allowsCellular(for provider: FeedbackProvider) -> Bool {
        !(flags ?? DeliveryPreferences()).wifiOnly(for: provider)
    }
    /// Session ceilings must not permanently freeze the user's old policy.
    /// Every production request below receives the latest restrictive snapshot.
    static func configureSessionCeiling(_ configuration: URLSessionConfiguration) {
        configuration.allowsCellularAccess = true
        #if canImport(Darwin)
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        #endif
    }
    static func apply(to configuration: URLSessionConfiguration, allowsCellular: Bool) {
        configuration.allowsCellularAccess = allowsCellular
        #if canImport(Darwin)
        let snapshot = flags
        configuration.allowsExpensiveNetworkAccess = snapshot?.allowExpensiveNetworks ?? false
        configuration.allowsConstrainedNetworkAccess = snapshot?.allowConstrainedNetworks ?? false
        #endif
    }
    static func apply(to request: inout URLRequest, allowsCellular: Bool) {
        request.allowsCellularAccess = allowsCellular
        #if canImport(Darwin)
        let snapshot = flags
        request.allowsExpensiveNetworkAccess = snapshot?.allowExpensiveNetworks ?? false
        request.allowsConstrainedNetworkAccess = snapshot?.allowConstrainedNetworks ?? false
        #endif
    }
}
