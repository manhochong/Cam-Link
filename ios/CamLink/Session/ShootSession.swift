import Foundation

@MainActor
final class ShootSession: ObservableObject {
    @Published var photos: [ReceivedJPEG] = []
    @Published var autoUpload = true
    @Published var uploadMessage = ""
    @Published var uploading = false

    private let sessionId: String

    init() {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        sessionId = fmt.string(from: Date())
    }

    var verifiedCount: Int { photos.filter(\.uploaded).count }
    var pendingCount: Int { photos.filter { !$0.uploaded }.count }

    func ingest(_ photo: ReceivedJPEG) {
        if photos.contains(where: { $0.id == photo.id }) { return }
        photos.insert(photo, at: 0)
    }

    func remoteName(for photo: ReceivedJPEG) -> String {
        // Match Android DavBackup drain naming: sessionFolder_localFile
        let local = photo.url.lastPathComponent
        return "\(sessionId)_\(local)"
    }

    func uploadPending(using pair: ComputerPair) async {
        guard pair.isReady else {
            uploadMessage = "請先配對電腦"
            return
        }
        uploading = true
        defer { uploading = false }
        var ok = 0
        var fail = 0
        for index in photos.indices where !photos[index].uploaded {
            let photo = photos[index]
            let name = remoteName(for: photo)
            // Receiver FILENAME: [a-z0-9][a-z0-9_.-]{0,190}\.jpe?g
            let safe = name.replacingOccurrences(of: " ", with: "_")
            do {
                try await PcClient.put(
                    pair: pair,
                    fileURL: photo.url,
                    remoteName: safe,
                    sha256: photo.sha256,
                    size: photo.bytes
                )
                photos[index].uploaded = true
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
            uploadMessage = ok == 0 ? "沒有待傳 JPG" : "已傳到電腦 \(ok) 張"
        }
    }

    func markNeedsUploadAll() {
        for i in photos.indices { photos[i].uploaded = false }
    }
}
