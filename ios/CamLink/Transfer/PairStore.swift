import Combine
import Foundation
import Security

struct ComputerPair: Equatable, Sendable {
    var host: String
    var password: String
    var fingerprint: String
    var inboxBase: String

    var shortFinger: String { String(fingerprint.prefix(16)).uppercased() }
    var isReady: Bool {
        !host.isEmpty && !password.isEmpty
            && fingerprint.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
    }
    static let empty = ComputerPair(host: "", password: "", fingerprint: "", inboxBase: "")
}

enum PCSlotID: String, Codable, CaseIterable, Identifiable, Sendable {
    case primary, secondary
    var id: String { rawValue }
    var defaultLabel: String { self == .primary ? "第一部電腦" : "第二部電腦" }
}

/// Runtime only: deliberately NOT Codable; a pair contains a Keychain-only password.
struct ComputerPairSlot: Identifiable, Equatable, Sendable {
    let id: PCSlotID
    var label: String
    var revision: String
    var pair: ComputerPair
    var autoSendNewPhotos: Bool
}

/// Public non-secret preferences. This codec never includes a ComputerPair/password.
struct PCSlotMetadata: Codable, Equatable, Sendable {
    var id: PCSlotID
    var label: String
    var revision: String
    var host: String
    var fingerprint: String
    var autoSendNewPhotos: Bool
}

/// Captured only while migrating an existing legacy primary; never follows later re-pairing.
struct PCLegacyPrimaryIdentity: Codable, Equatable, Sendable {
    let fingerprint: String
    let revision: String
}

struct PCPairPreferences: Codable, Equatable, Sendable {
    var version = 2
    var selectedSlot: PCSlotID
    var slots: [PCSlotMetadata]
    var legacyPrimaryIdentity: PCLegacyPrimaryIdentity? = nil
    var isValid: Bool {
        version == 2 && slots.count == 2 && Set(slots.map(\.id)).count == 2
            && slots.allSatisfy { metadata in
                UUID(uuidString: metadata.revision) != nil
                    && ((metadata.host.isEmpty && metadata.fingerprint.isEmpty)
                        || ((try? PcClient.inboxBase(ip: metadata.host)) != nil
                            && metadata.fingerprint.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil))
            }
            && (legacyPrimaryIdentity == nil || (UUID(uuidString: legacyPrimaryIdentity!.revision) != nil
                && legacyPrimaryIdentity!.fingerprint.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil))
    }
}

/// Injectable ONLY for deterministic Mac tests; production uses the exact legacy Keychain account.
@MainActor
protocol PairCredentialStorage {
    func load(slot: PCSlotID) -> String?
    func save(_ value: String, slot: PCSlotID) -> Bool
    func clear(slot: PCSlotID) -> Bool
}

@MainActor
final class PairStore: ObservableObject {
    /// Legacy RootView/ShootSession compatibility: ALWAYS the primary receiver, never selectedSlot.
    @Published private(set) var pair = ComputerPair.empty
    @Published private(set) var slots: [ComputerPairSlot] = []
    @Published private(set) var selectedSlot: PCSlotID = .primary
    @Published private(set) var legacyPrimaryIdentity: PCLegacyPrimaryIdentity? = nil
    @Published var draftHost = ""
    @Published var draftCode = ""
    @Published var message = ""
    @Published private(set) var busy = false

    static let preferencesKey = "pc.slots.v2"
    private let defaults: UserDefaults
    private let credentials: any PairCredentialStorage
    private var pending: PendingProbe?
    private var draftCache: [PCSlotID: (host: String, code: String)] = [:] // memory only
    private var preferencesReadable = true
    private struct PendingProbe {
        let slot: PCSlotID
        let revision: String
        let fingerprint: String
        let base: String
        let host: String
        let code: String
    }

    var selectedPair: ComputerPair { slot(selectedSlot)?.pair ?? .empty }
    var selectedLabel: String { slot(selectedSlot)?.label ?? selectedSlot.defaultLabel }
    var pendingFingerprint: String? { hasPendingFingerprint ? pending?.fingerprint : nil }
    var hasPendingFingerprint: Bool {
        guard let pending else { return false }
        return pending.slot == selectedSlot && pending.host == draftHost && pending.code == draftCode
            && slot(selectedSlot)?.revision == pending.revision
    }

    init(defaults: UserDefaults = .standard,
         credentials: (any PairCredentialStorage)? = nil) {
        let credentials = credentials ?? KeychainPairCredentialStorage()
        self.defaults = defaults
        self.credentials = credentials
        if let data = defaults.data(forKey: Self.preferencesKey) {
            if let saved = try? JSONDecoder().decode(PCPairPreferences.self, from: data), saved.isValid {
                selectedSlot = saved.selectedSlot
                legacyPrimaryIdentity = saved.legacyPrimaryIdentity
                slots = PCSlotID.allCases.compactMap { id in
                    saved.slots.first(where: { $0.id == id }).map { metadata in
                        ComputerPairSlot(id: id, label: metadata.label, revision: metadata.revision,
                            pair: Self.restoredPair(host: metadata.host,
                                code: credentials.load(slot: id) ?? "", fingerprint: metadata.fingerprint),
                            autoSendNewPhotos: metadata.autoSendNewPhotos)
                    }
                }
            } else {
                // Never overwrite an unreadable second receiver record or delete its credentials.
                preferencesReadable = false
                message = "雙電腦設定無法讀取；已保留原資料，請先修復設定檔"
            }
        }
        if slots.isEmpty {
            var code = credentials.load(slot: .primary) ?? ""
            let plaintext = defaults.string(forKey: "pc.code") ?? ""
            if code.isEmpty, !plaintext.isEmpty {
                if credentials.save(plaintext, slot: .primary) {
                    code = plaintext
                    defaults.removeObject(forKey: "pc.code")
                } else {
                    // Preserve an existing working legacy credential when Keychain is unavailable.
                    code = plaintext
                    message = "舊配對碼尚未安全遷移；請解鎖装置後重試"
                }
            } else if !code.isEmpty {
                defaults.removeObject(forKey: "pc.code")
            }
            let host = defaults.string(forKey: "pc.host") ?? ""
            let fingerprint = defaults.string(forKey: "pc.finger") ?? ""
            slots = [
                ComputerPairSlot(id: .primary, label: PCSlotID.primary.defaultLabel,
                    revision: UUID().uuidString,
                    pair: Self.restoredPair(host: host, code: code, fingerprint: fingerprint),
                    autoSendNewPhotos: true), // Retain the original primary behaviour.
                ComputerPairSlot(id: .secondary, label: PCSlotID.secondary.defaultLabel,
                    revision: UUID().uuidString, pair: .empty, autoSendNewPhotos: false)
            ]
            if preferencesReadable, let primary = slots.first, primary.pair.isReady {
                legacyPrimaryIdentity = PCLegacyPrimaryIdentity(
                    fingerprint: primary.pair.fingerprint.lowercased(), revision: primary.revision)
            }
            draftCache[.primary] = (host, code)
        }
        pair = slot(.primary)?.pair ?? .empty
        loadSelectedDraft()
        if preferencesReadable { persistMetadata() }
    }

    func slot(_ id: PCSlotID) -> ComputerPairSlot? { slots.first { $0.id == id } }

    func selectSlot(_ id: PCSlotID) {
        guard !busy else { return }
        draftCache[selectedSlot] = (draftHost, draftCode)
        selectedSlot = id
        clearPendingProbe()
        loadSelectedDraft()
        persistMetadata()
    }

    func setLabel(_ label: String, for id: PCSlotID) {
        guard let index = slots.firstIndex(where: { $0.id == id }), preferencesReadable else { return }
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let bounded = String(String.UnicodeScalarView(clean)).prefix(60)
        slots[index].label = bounded.isEmpty ? id.defaultLabel : String(bounded)
        persistMetadata()
    }

    func setAutoSendNewPhotos(_ enabled: Bool, for id: PCSlotID) {
        guard let index = slots.firstIndex(where: { $0.id == id }), preferencesReadable else { return }
        slots[index].autoSendNewPhotos = enabled
        persistMetadata()
    }

    /// Explicit target slot; QR content never selects a fingerprint or grants trust.
    func applyQR(_ raw: String?, to target: PCSlotID) -> Bool {
        guard !busy, let parts = PcClient.parsePair(raw) else { return false }
        selectSlot(target)
        draftHost = parts.host
        draftCode = parts.code
        clearPendingProbe()
        return true
    }

    func applyQR(_ raw: String?) -> Bool { applyQR(raw, to: selectedSlot) }

    func probeAndConfirm() async {
        guard !busy else { return }
        clearPendingProbe()
        guard preferencesReadable else { message = "設定檔無法讀取；不可覆寫原配對"; return }
        guard !draftHost.isEmpty, !draftCode.isEmpty, let selected = slot(selectedSlot) else {
            message = "請輸入電腦地址和配對碼"
            return
        }
        let id = selectedSlot, host = draftHost, code = draftCode
        busy = true
        message = "正在探測電腦…"
        defer { busy = false }
        do {
            let base = try PcClient.inboxBase(ip: host)
            let finger = try await PcClient.probeFingerprint(base: base)
            guard id == selectedSlot, host == draftHost, code == draftCode,
                  slot(id)?.revision == selected.revision else {
                message = "資料已變更；請重新探測"
                return
            }
            pending = PendingProbe(slot: id, revision: selected.revision, fingerprint: finger,
                base: base, host: host, code: code)
            message = "請核對電腦畫面指紋：\(String(finger.prefix(16)).uppercased())"
        } catch {
            clearPendingProbe()
            message = "未能探測電腦；請確認同一 Wi-Fi、接收器及區域網絡權限"
        }
    }

    func confirmFingerprint() async {
        guard !busy else { return }
        guard hasPendingFingerprint, let pending,
              let index = slots.firstIndex(where: { $0.id == pending.slot }) else {
            message = "請重新探測電腦並核對指紋"
            return
        }
        busy = true
        defer { busy = false }
        do {
            // Authenticate only after the user explicitly confirms the observed certificate.
            try await PcClient.authenticate(base: pending.base, password: pending.code,
                fingerprint: pending.fingerprint)
            guard hasPendingFingerprint, preferencesReadable else {
                message = "資料已變更；配對未儲存，請重新核對"
                return
            }
            guard credentials.save(pending.code, slot: pending.slot) else {
                message = "無法安全儲存配對資料，請稍後再試"
                return
            }
            if slots[index].pair.fingerprint.lowercased() != pending.fingerprint.lowercased() {
                slots[index].revision = UUID().uuidString
            }
            slots[index].pair = ComputerPair(host: pending.host, password: pending.code,
                fingerprint: pending.fingerprint.lowercased(), inboxBase: pending.base)
            draftCache[pending.slot] = (pending.host, pending.code)
            pair = slot(.primary)?.pair ?? .empty
            persistMetadata()
            message = "已配對 \(slots[index].label)；自動傳新圖可獨立啟用"
            clearPendingProbe()
        } catch {
            message = "配對未完成；請核對地址、配對碼與指紋"
        }
    }

    /// Local selected-slot forgetting only. Does not delete files or remote receipts.
    func clear() { clear(selectedSlot) }
    func clear(_ id: PCSlotID) {
        guard !busy, preferencesReadable,
              let index = slots.firstIndex(where: { $0.id == id }) else { return }
        guard credentials.clear(slot: id) else { message = "無法清除該部電腦的 Keychain 配對碼"; return }
        slots[index].pair = .empty
        slots[index].revision = UUID().uuidString
        slots[index].autoSendNewPhotos = false
        draftCache[id] = ("", "")
        if id == .primary {
            // These are only this provider's original preference keys.
            ["pc.host", "pc.code", "pc.finger", "pc.pendingFinger", "pc.pendingBase"].forEach {
                defaults.removeObject(forKey: $0)
            }
        }
        if selectedSlot == id { draftHost = ""; draftCode = ""; clearPendingProbe() }
        pair = slot(.primary)?.pair ?? .empty
        persistMetadata()
        message = "已停用 \(slots[index].label)，原圖及交付紀錄保留"
    }

    private static func restoredPair(host: String, code: String, fingerprint: String) -> ComputerPair {
        // Missing/locked Keychain is NOT permission to erase the saved host/certificate.
        guard !host.isEmpty,
              fingerprint.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil,
              let base = try? PcClient.inboxBase(ip: host) else { return .empty }
        return ComputerPair(host: host, password: code, fingerprint: fingerprint.lowercased(), inboxBase: base)
    }

    private func loadSelectedDraft() {
        let cached = draftCache[selectedSlot]
        draftHost = cached?.host ?? selectedPair.host
        draftCode = cached?.code ?? selectedPair.password
    }

    private func clearPendingProbe() { pending = nil }
    private func persistMetadata() {
        guard preferencesReadable else { return }
        let metadata = slots.map { slot in
            PCSlotMetadata(id: slot.id, label: slot.label, revision: slot.revision,
                host: slot.pair.host, fingerprint: slot.pair.fingerprint,
                autoSendNewPhotos: slot.autoSendNewPhotos)
        }
        let saved = PCPairPreferences(selectedSlot: selectedSlot, slots: metadata,
            legacyPrimaryIdentity: legacyPrimaryIdentity)
        guard let data = try? JSONEncoder().encode(saved) else {
            message = "無法保存雙電腦設定"
            return
        }
        defaults.set(data, forKey: Self.preferencesKey)
        if pair.isReady {
            defaults.set(pair.host, forKey: "pc.host")
            defaults.set(pair.fingerprint, forKey: "pc.finger")
        }
    }
}

@MainActor
struct KeychainPairCredentialStorage: PairCredentialStorage {
    func load(slot: PCSlotID) -> String? { PairCredentialVault.load(slot: slot) }
    func save(_ value: String, slot: PCSlotID) -> Bool { PairCredentialVault.save(value, slot: slot) }
    func clear(slot: PCSlotID) -> Bool { PairCredentialVault.clear(slot: slot) }
}

private enum PairCredentialVault {
    private static let service = Bundle.main.bundleIdentifier ?? "hk.camlink.ios"
    // Primary MUST keep the existing account; do not migrate/delete a working credential.
    private static func account(_ slot: PCSlotID) -> String {
        slot == .primary ? "computer-pair-code" : "computer-pair-code-secondary"
    }
    private static func query(_ slot: PCSlotID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account(slot)]
    }
    static func load(slot: PCSlotID) -> String? {
        var query = query(slot)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, slot: PCSlotID) -> Bool {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let base = query(slot)
        let status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var insert = base
        attributes.forEach { insert[$0.key] = $0.value }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
    static func clear(slot: PCSlotID) -> Bool {
        let status = SecItemDelete(query(slot) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
