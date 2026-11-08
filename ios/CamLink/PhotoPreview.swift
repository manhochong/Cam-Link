import ImageIO
import SwiftUI
import UIKit

struct PhotoPreview: View {
    let photo: ReceivedJPEG?
    var large = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(red: 0.15, green: 0.15, blue: 0.15)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera").font(.system(size: 36, weight: .light))
                    Text(photo == nil ? "等待完整 JPG" : "正在讀取照片預覽")
                        .font(.subheadline)
                }.foregroundStyle(.white.opacity(0.6))
            }
        }
        .task(id: photo?.id) {
            image = nil
            guard let url = photo?.url else { return }
            let limit = large ? 2400 : 1200
            let loaded = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Optional<UIImage>.none }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: limit,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .accessibilityLabel(photo.map { "照片預覽 \($0.name)" } ?? "等待第一張 JPG")
    }
}

struct PhotoViewer: View {
    let photo: ReceivedJPEG
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        NavigationStack {
            PhotoPreview(photo: photo, large: true)
                .scaleEffect(min(4, max(1, scale * pinch)))
                .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                    .onEnded { scale = min(4, max(1, scale * $0)) })
                .onTapGesture(count: 2) { scale = scale > 1 ? 1 : 2 }
                .clipped()
                .background(.black)
                .navigationTitle(photo.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { ShareLink(item: photo.url) }
                }
        }
    }
}
