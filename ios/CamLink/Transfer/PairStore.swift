import Combine
import Foundation
import Security

struct ComputerPair: Equatable {
    var host: String
    var password: String
    var fingerprint: String
    var inboxBase: String

    var shortFinger: String {
        String(fingerprint.prefix(16)).uppercased()
    }

    var isReady: Bool {
        !host.isEmpty && !password.isEmpty && fingerprint.count == 64
    }
}

@MainActor
final class PairStore: ObservableObject {
    @Published var pair = ComputerPair(host: "", password: "", fingerprint: "", inboxBase: "")
    @Published var draftHost = ""
    @Published var draftCode = ""
    @Published var message = ""
    @Published var busy = false

    private let defaults = UserDefaults.standard
    private var pendingFingerprint: String?
    private var pendingBase: String?
    private var pendingHost: String?
    private var pendingCode: String?

    var hasPendingFingerprint: Bool {
        pendingFingerprint != nil && pendingBase != nil
            && pendingHost == draftHost && pendingCode == draftCode
    }

    init() {
        draftHost = defaults.string(forKey: "pc.host") ?? ""

        // Migrate the previous plaintext preference into Keychain once.
        let legacyCode = defaults.string(forKey: "pc.code") ?? ""
        if let savedCode = PairCredentialVault.load(), !savedCode.isEmpty {
            defaults.removeObject(forKey: "pc.code")
            draftCode = savedCode
        } else if !legacyCode.isEmpty {
            if PairCredentialVault.save(legacyCode) {
                defaults.removeObject(forKey: "pc.code")
            }
            draftCode = PairCredentialVault.load() ?? legacyCode
        } else {
            draftCode = ""
        }

        let finger = defaults.string(forKey: "pc.finger") ?? ""
        if !draftHost.isEmpty, !draftCode.isEmpty, finger.count == 64 {
            do {
                let base = try PcClient.inboxBase(ip: draftHost)
                pair = ComputerPair(host: draftHost, password: draftCode, fingerprint: finger, inboxBase: base)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func applyQR(_ raw: String?) -> Bool {
        guard let parts = PcClient.parsePair(raw) else { return false }
        draftHost = parts.host
        draftCode = parts.code
        clearPendingProbe()
        return true
    }

    func probeAndConfirm() async {
        clearPendingProbe()
        guard !draftHost.isEmpty, !draftCode.isEmpty else {
            message = "請輸入電腦地址和配對碼"
            return
        }
        busy = true
        message = "正在探測電腦…"
        defer { busy = false }
        do {
            let base = try PcClient.inboxBase(ip: draftHost)
            let finger = try await PcClient.probeFingerprint(base: base)
            pendingFingerprint = finger
            pendingBase = base
            pendingHost = draftHost
            pendingCode = draftCode
            message = "請核對指紋：\(String(finger.prefix(16)).uppercased())"
        } catch {
            clearPendingProbe()
            message = error.localizedDescription
        }
    }

    func confirmFingerprint() async {
        guard let finger = pendingFingerprint,
              let base = pendingBase,
              pendingHost == draftHost,
              pendingCode == draftCode,
              finger.count == 64
        else {
            message = "請重新探測電腦並核對指紋"
            return
        }

        busy = true
        defer { busy = false }
        do {
            try await PcClient.authenticate(base: base, password: draftCode, fingerprint: finger)
            guard PairCredentialVault.save(draftCode) else {
                message = "無法安全儲存配對資料，請稍後再試"
                return
            }
            pair = ComputerPair(host: draftHost, password: draftCode, fingerprint: finger, inboxBase: base)
            defaults.set(draftHost, forKey: "pc.host")
            defaults.set(finger, forKey: "pc.finger")
            defaults.removeObject(forKey: "pc.code")
            message = "已配對 \(draftHost)"
            clearPendingProbe()
        } catch {
            message = error.localizedDescription
        }
    }

    func clear() {
        pair = ComputerPair(host: "", password: "", fingerprint: "", inboxBase: "")
        draftHost = ""
        draftCode = ""
        defaults.removeObject(forKey: "pc.host")
        defaults.removeObject(forKey: "pc.code")
        defaults.removeObject(forKey: "pc.finger")
        defaults.removeObject(forKey: "pc.pendingFinger")
        defaults.removeObject(forKey: "pc.pendingBase")
        PairCredentialVault.clear()
        clearPendingProbe()
        message = "已清除配對"
    }

    private func clearPendingProbe() {
        pendingFingerprint = nil
        pendingBase = nil
        pendingHost = nil
        pendingCode = nil
    }
}

private enum PairCredentialVault {
    private static let service = Bundle.main.bundleIdentifier ?? "hk.camlink.ios"
    private static let account = "computer-pair-code"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        var query = baseQuery
        for (key, attribute) in attributes { query[key] = attribute }
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
