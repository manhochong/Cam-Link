import Foundation

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

    init() {
        draftHost = defaults.string(forKey: "pc.host") ?? ""
        draftCode = defaults.string(forKey: "pc.code") ?? ""
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
        return true
    }

    func probeAndConfirm() async {
        busy = true
        message = "正在探測電腦…"
        defer { busy = false }
        do {
            let base = try PcClient.inboxBase(ip: draftHost)
            let finger = try await PcClient.probeFingerprint(base: base)
            message = "請核對指紋：\(String(finger.prefix(16)).uppercased())"
            // Stash pending until user confirms in UI.
            defaults.set(draftHost, forKey: "pc.host")
            defaults.set(draftCode, forKey: "pc.code")
            defaults.set(finger, forKey: "pc.pendingFinger")
            defaults.set(base, forKey: "pc.pendingBase")
        } catch {
            message = error.localizedDescription
        }
    }

    func confirmFingerprint() async {
        busy = true
        defer { busy = false }
        guard let finger = defaults.string(forKey: "pc.pendingFinger"),
              let base = defaults.string(forKey: "pc.pendingBase"),
              finger.count == 64
        else {
            message = "請先探測電腦"
            return
        }
        do {
            try await PcClient.authenticate(base: base, password: draftCode, fingerprint: finger)
            pair = ComputerPair(host: draftHost, password: draftCode, fingerprint: finger, inboxBase: base)
            defaults.set(finger, forKey: "pc.finger")
            defaults.removeObject(forKey: "pc.pendingFinger")
            defaults.removeObject(forKey: "pc.pendingBase")
            message = "已配對 \(draftHost)"
        } catch {
            message = error.localizedDescription
        }
    }

    func clear() {
        pair = ComputerPair(host: "", password: "", fingerprint: "", inboxBase: "")
        defaults.removeObject(forKey: "pc.host")
        defaults.removeObject(forKey: "pc.code")
        defaults.removeObject(forKey: "pc.finger")
        message = "已清除配對"
    }
}
