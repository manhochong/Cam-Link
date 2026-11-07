import Foundation

struct ReceivedJPEG: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let bytes: Int64
    let sha256: String
    let createdAt: Date
    var uploaded: Bool
}
