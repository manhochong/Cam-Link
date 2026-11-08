import Combine
import Foundation

@MainActor
final class ShootSession: ObservableObject {
    @Published var photos: [ReceivedJPEG] = [] {
        didSet { persist() }
    }
    @Published var autoUpload = true {
        didSet { persist() }
    }
    @Published var uploadMessage = ""
    @Published var uploading = false

    private(set) var sessionId = ""

    private struct Snapshot: Codable {
        var sessionId: String
        var autoUpload: Bool
        var photos: [ReceivedJPEG]
    }

    private var stateURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("CamLink", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    init() {
        if let data = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
           !saved.sessionId.isEmpty {
            sessionId = saved.sessionId
            autoUpload = saved.autoUpload
            photos = saved.photos.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        } else {
            sessionId = Self.makeSessionId(for: Date())
        }
        persist()
    }

    var verifiedCount: Int { photos.filter(\.uploaded).count }
    var pendingCount: Int { photos.filter { !$0.uploaded }.count }

    func ingest(_ photo: ReceivedJPEG) {
        if photos.contains(where: { $0.id == photo.id }) { return }
        photos.insert(photo, at: 0)
    }

    func remoteName(for photo: ReceivedJPEG) -> String {
        // Match the desktop Receiver's safe filename format.
        let local = photo.url.lastPathComponent
        return "\(sessionId)_\(local)"
            .replacingOccurrences(of: " ", with: "_")
    }

    func uploadPending(using pair: ComputerPair) async {
        guard pair.isReady else {
            uploadMessage = "請先配對電腦"
            return
        }
        guard !uploading else { return }

        uploading = true
        defer { uploading = false }

        var ok = 0
        var fail = 0
        var attempted = Set<String>()

        // Re-read by stable photo ID after each await; new arrivals are picked up
        // by this loop without relying on array indexes that may shift meanwhile.
        while let photo = photos.first(where: { !$0.uploaded && !attempted.contains($0.id) }) {
            attempted.insert(photo.id)
            let name = remoteName(for: photo)
            do {
                try await PcClient.put(
                    pair: pair,
                    fileURL: photo.url,
                    remoteName: name,
                    sha256: photo.sha256,
                    size: photo.bytes
                )
                if let index = photos.firstIndex(where: { $0.id == photo.id }) {
                    photos[index].uploaded = true
                }
                ok += 1
            } catch PcClientError.serverBusy {
                uploadMessage = "電腦忙碌，稍後再傳"
                fail += 1
                break
            } catch {
                uploadMessage = error.localizedDescription
                fail += 1
            }
        }

        if fail == 0 {
            uploadMessage = ok == 0 ? "沒有待傳 JPG" : "已傳到電腦並核對 \(ok) 張"
        }
    }

    func markNeedsUploadAll() {
        for index in photos.indices { photos[index].uploaded = false }
    }

    private func persist() {
        guard !sessionId.isEmpty else { return }
        let directory = stateURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = Snapshot(sessionId: sessionId, autoUpload: autoUpload, photos: photos)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            uploadMessage = "無法儲存場次資料：\(error.localizedDescription)"
        }
    }

    private static func makeSessionId(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
