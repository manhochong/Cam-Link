#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers

/// App-module entry point. Owns navigation; embed in a sheet/tab without another NavigationStack.
/// All delivery closures are invoked only by explicit user actions and must show target confirmation.
@MainActor
struct SessionHistoryView: View {
    @ObservedObject private var session: ShootSession
    private let isCameraReceiving: () -> Bool
    private let onDelivery: ((SessionAlbumRecord) -> Void)?
    private let onRetryDelivery: ((SessionAlbumRecord) -> Void)?
    private let summaries: ((SessionAlbumRecord) -> [SessionDeliverySummary])?
    @State private var query = ""
    @State private var creating = false
    @State private var eventName = ""
    @State private var message = ""

    init(session: ShootSession, isCameraReceiving: @escaping () -> Bool,
         onDelivery: ((SessionAlbumRecord) -> Void)? = nil,
         onRetryDelivery: ((SessionAlbumRecord) -> Void)? = nil,
         summaries: ((SessionAlbumRecord) -> [SessionDeliverySummary])? = nil) {
        self.session = session
        self.isCameraReceiving = isCameraReceiving
        self.onDelivery = onDelivery
        self.onRetryDelivery = onRetryDelivery
        self.summaries = summaries
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("接收中的活動：\(session.sessionDisplayName)")
                    Text("瀏覽舊場次不會切換相機接收位置。建立新活動前，請先停止接收。")
                        .font(.caption).foregroundColor(.secondary)
                    if !session.archiveMessage.isEmpty {
                        Text(session.archiveMessage).foregroundColor(.red)
                    }
                    if !message.isEmpty { Text(message).foregroundColor(.red) }
                }
                Section("\(session.history(matching: query).count) 個場次") {
                    ForEach(session.history(matching: query)) { album in
                        NavigationLink {
                            SessionAlbumView(session: session, albumID: album.id,
                                onDelivery: onDelivery, onRetryDelivery: onRetryDelivery,
                                summaries: summaries)
                        } label: {
                            HStack(spacing: 12) {
                                SessionLocalImage(url: album.coverPhoto?.url, maxPixels: 280)
                                    .frame(width: 80, height: 64).clipped().cornerRadius(8)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.displayName).font(.headline)
                                    Text(SessionArchiveSnapshot.dateTitle(album.startedAt)).font(.caption)
                                    Text("\(album.photos.count) 張原圖\(album.id == session.sessionId ? "・目前接收" : "・歷史")")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                    if session.history(matching: query).isEmpty { Text("找不到符合的場次") }
                }
            }
            .navigationTitle("拍攝紀錄")
            .searchable(text: $query, prompt: "搜尋活動名稱、日期或現場備註")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("新活動") { eventName = ""; creating = true }
                        .disabled(session.isReceiving || session.uploading || isCameraReceiving())
                }
            }
            .alert("建立新活動", isPresented: $creating) {
                TextField("活動名稱（可留空）", text: $eventName)
                Button("取消", role: .cancel) { }
                Button("建立") {
                    do {
                        _ = try session.startNewActivity(eventName: eventName,
                            isReceiving: isCameraReceiving())
                        message = ""
                    } catch { message = sessionViewError(error) }
                }
            } message: {
                Text("上一場紀錄與全部原圖會保留。只有明確建立後的新接收照片才屬於新活動。")
            }
        }
    }
}

/// May be pushed from the history view or the parent's existing NavigationStack.
@MainActor
struct SessionAlbumView: View {
    @ObservedObject private var session: ShootSession
    let albumID: String
    private let onDelivery: ((SessionAlbumRecord) -> Void)?
    private let onRetryDelivery: ((SessionAlbumRecord) -> Void)?
    private let summaries: ((SessionAlbumRecord) -> [SessionDeliverySummary])?
    @State private var selectedIDs = Set<String>()
    @State private var selecting = false
    @State private var viewing: SessionViewerSelection?
    @State private var exportRequest: SessionSystemExportRequest?
    @State private var editing = false
    @State private var diagnostics = false
    @State private var message = ""
    @State private var savingPhotos = false
    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 6)]

    init(session: ShootSession, albumID: String,
         onDelivery: ((SessionAlbumRecord) -> Void)? = nil,
         onRetryDelivery: ((SessionAlbumRecord) -> Void)? = nil,
         summaries: ((SessionAlbumRecord) -> [SessionDeliverySummary])? = nil) {
        self.session = session
        self.albumID = albumID
        self.onDelivery = onDelivery
        self.onRetryDelivery = onRetryDelivery
        self.summaries = summaries
    }
    private var album: SessionAlbumRecord? { session.album(id: albumID) }

    var body: some View {
        Group {
            if let album = album {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(album)
                        deliveryOverview(album)
                        actions(album)
                        if !message.isEmpty { Text(message).font(.callout).foregroundColor(.secondary) }
                        Text("分享與 Files 使用未改動的原圖。其他 App 是否出現、能否接收多張及雲端結果由該 App 決定；本 App 不會因此標示已核對。")
                            .font(.caption).foregroundColor(.secondary)
                        if album.photos.isEmpty { Text("本場尚未收到照片") }
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(album.sortedPhotos) { photo in tile(photo, album: album) }
                        }
                    }.padding()
                }
                .navigationTitle(album.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("名稱／備註") { editing = true }
                    }
                }
            } else { Text("找不到指定場次；現有原圖不會被刪除。") }
        }
        .onAppear {
            do { try session.selectAlbum(id: albumID) }
            catch { message = sessionViewError(error) }
        }
        .sheet(item: $exportRequest) { request in SessionSystemExportSheet(request: request) }
        .sheet(isPresented: $editing) { SessionAlbumMetadataView(session: session, albumID: albumID) }
        .sheet(isPresented: $diagnostics) {
            NavigationStack {
                if let album = album {
                    List {
                        Section("接收診斷") {
                            if album.diagnostics.isEmpty { Text("沒有紀錄；不代表各目的地已完成。") }
                            ForEach(album.diagnostics) { event in
                                VStack(alignment: .leading) {
                                    Text(event.code.rawValue)
                                    Text("\(SessionExport.isoDate(event.date))・數量 \(event.count)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        Section {
                            Text("未量度的階段顯示 —，不會估算相機處理、卡內比較或背景 USB 狀態。")
                        }
                    }.navigationTitle("本場診斷")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("關閉") { diagnostics = false } } }
                }
            }
        }
        .fullScreenCover(item: $viewing) { selection in
            SessionPhotoViewer(session: session, albumID: albumID, initialPhotoID: selection.id)
        }
    }

    @ViewBuilder private func header(_ album: SessionAlbumRecord) -> some View {
        Text("\(album.photos.count) 張原圖・\(SessionArchiveSnapshot.dateTitle(album.startedAt))")
            .font(.headline)
        Text(album.id == session.sessionId ? "目前接收活動" : "歷史場次（新接收照片不會加入本場）")
            .font(.caption).foregroundColor(.secondary)
        if !album.operatorNotes.isEmpty { Text(album.operatorNotes).font(.callout) }
        if !session.archiveMessage.isEmpty { Text(session.archiveMessage).foregroundColor(.red) }
    }
    private func deliveryOverview(_ album: SessionAlbumRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("目的地紀錄").font(.headline)
            Text("舊版 PC 核對旗標：\(album.legacyPCVerifiedCount) / \(album.photos.count)（未區分電腦）")
                .font(.caption)
            let values = summaries?(album) ?? album.deliverySummaries
            if values.isEmpty { Text("未提供目的地彙總；不代表已排隊或已核對。") .font(.caption) }
            ForEach(values) { value in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(value.provider.title) [\(value.destinationKey)]").font(.subheadline)
                    Text("已核對 \(value.verified)／\(value.total)・待傳 \(value.waiting)・需處理 \(value.failed)・需登入 \(value.needsAuthentication)")
                        .font(.caption)
                    Text("已傳未核對 \(value.deliveredUnverified)・\(value.verification.sessionTitle)")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func actions(_ album: SessionAlbumRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(selecting ? "完成選取" : "多選原圖") {
                    selecting.toggle()
                    if !selecting { selectedIDs.removeAll() }
                }.buttonStyle(.bordered)
                if selecting {
                    Button(selectedIDs.count == album.photos.count ? "取消全選" : "全選") {
                        selectedIDs = selectedIDs.count == album.photos.count ? [] : Set(album.photos.map(\.id))
                    }
                    Text("\(selectedIDs.count) 張").font(.caption)
                }
            }
            HStack {
                Menu(selecting ? "匯出選取原圖" : "匯出本場原圖") {
                    Button("系統分享原圖") { originals(album, destination: .share) }
                    Button("儲存原圖到 Files") { originals(album, destination: .files) }
                    Button("ZIP 打包原圖到 Files") { exportZIP(album) }
                    #if canImport(Photos)
                    Button("新增原圖至 Photos") { saveToPhotos(album) }
                    #endif
                }.buttonStyle(.borderedProminent)
                    .disabled(album.photos.isEmpty || (selecting && selectedIDs.isEmpty) || savingPhotos)
                Menu("匯出報表") {
                    ForEach(SessionExportFormat.allCases) { format in
                        Button(format.title) { exportReport(album, format: format) }
                    }
                }.buttonStyle(.bordered)
            }
            if savingPhotos { ProgressView("正在匯出原圖；App 原圖保留") }
            HStack {
                Button("診斷") { diagnostics = true }
                if let delivery = onDelivery {
                    Button("本場加入目的地…") { delivery(album) }
                }
                if let retry = onRetryDelivery {
                    Button("只重試本場…") { retry(album) }
                }
            }.font(.callout)
        }
    }
    private func tile(_ photo: ReceivedJPEG, album: SessionAlbumRecord) -> some View {
        Button {
            if selecting {
                if selectedIDs.contains(photo.id) { selectedIDs.remove(photo.id) }
                else { selectedIDs.insert(photo.id) }
            } else { viewing = SessionViewerSelection(id: photo.id) }
        } label: {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    SessionLocalImage(url: photo.url, maxPixels: 360)
                        .frame(height: 110).frame(maxWidth: .infinity).clipped()
                    if selecting {
                        Image(systemName: selectedIDs.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedIDs.contains(photo.id) ? .blue : .white)
                            .font(.title3).padding(6).shadow(radius: 2)
                    }
                }
                Text(photo.name).font(.caption2).lineLimit(1).padding(4)
            }.background(Color.secondary.opacity(0.1)).cornerRadius(7)
        }.buttonStyle(.plain)
            .accessibilityLabel("原圖 \(photo.name)\(selectedIDs.contains(photo.id) ? "，已選取" : "")")
            .contextMenu {
                Button("查看大圖") { viewing = SessionViewerSelection(id: photo.id) }
                Button("分享這張原圖") { shareSingle(photo, album: album) }
                Button("設為場次封面") {
                    do { try session.setCover(photoID: photo.id, albumID: albumID) }
                    catch { message = sessionViewError(error) }
                }
            }
    }
    private func originals(_ album: SessionAlbumRecord, destination: SessionSystemExportRequest.Destination) {
        do {
            let urls = try SessionExport.originalURLs(album: album, selectedIDs: selecting ? selectedIDs : nil)
            exportRequest = SessionSystemExportRequest(urls: urls, destination: destination)
        } catch { message = sessionViewError(error) }
    }
    private func shareSingle(_ photo: ReceivedJPEG, album: SessionAlbumRecord) {
        do {
            let urls = try SessionExport.originalURLs(album: album, selectedIDs: [photo.id])
            exportRequest = SessionSystemExportRequest(urls: urls, destination: .share)
        } catch { message = sessionViewError(error) }
    }
    private func exportZIP(_ album: SessionAlbumRecord) {
        guard !savingPhotos else { return }
        do {
            let urls = try SessionExport.originalURLs(album: album, selectedIDs: selecting ? selectedIDs : nil)
            let originals = try urls.map { url -> SessionZIPOriginal in
                guard let photo = album.photos.first(where: { $0.url == url }) else { throw SessionArchiveError.invalidOriginal }
                return SessionZIPOriginal(url: url, bytes: photo.bytes, sha256: photo.sha256)
            }
            guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw SessionArchiveError.invalidOriginal }
            savingPhotos = true
            Task { @MainActor in
                defer { savingPhotos = false }
                do {
                    let url = try await Task.detached(priority: .utility) {
                        try SessionZIPExport.write(originals, allowedRoot: documents)
                    }.value
                    exportRequest = SessionSystemExportRequest(urls: [url], destination: .files)
                    message = "ZIP 已建立：包含完整原圖，沒有裁切 MPF 或重新編碼；這不是雲端交付核對。"
                } catch { message = (error as? SessionZIPExport.Failure)?.localizedDescription ?? "未完成原圖 ZIP；App 原圖保留。" }
            }
        } catch { message = sessionViewError(error) }
    }
    private func exportReport(_ album: SessionAlbumRecord, format: SessionExportFormat) {
        do {
            let url = try SessionExport.write(album: album, format: format, summaries: summaries?(album))
            exportRequest = SessionSystemExportRequest(urls: [url], destination: .files)
        } catch { message = sessionViewError(error) }
    }
    #if canImport(Photos)
    private func saveToPhotos(_ album: SessionAlbumRecord) {
        guard !savingPhotos else { return }
        do {
            let urls = try SessionExport.originalURLs(album: album, selectedIDs: selecting ? selectedIDs : nil)
            savingPhotos = true
            Task { @MainActor in
                defer { savingPhotos = false }
                do {
                    try await SessionPhotosExport.saveOriginals(urls)
                    message = "已新增至 Photos；App 原圖保留。這不是 Photos 雲端上傳核對。"
                } catch {
                    message = (error as? SessionPhotosExport.Failure)?.localizedDescription ?? sessionViewError(error)
                }
            }
        } catch { message = sessionViewError(error) }
    }
    #endif
}

@MainActor
private struct SessionAlbumMetadataView: View {
    @ObservedObject var session: ShootSession
    let albumID: String
    @Environment(\.dismiss) private var dismiss
    @State private var eventName = ""
    @State private var notes = ""
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("活動名稱") { TextField("例如：週年晚宴", text: $eventName) }
                Section("現場備註") {
                    TextEditor(text: $notes).frame(minHeight: 150)
                    Text("請勿填寫密碼、配對碼或存取權杖；備註會包含在報表。最多 4000 字。")
                        .font(.caption).foregroundColor(.secondary)
                }
                if !message.isEmpty { Text(message).foregroundColor(.red) }
            }.navigationTitle("名稱與現場備註")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("儲存") {
                            do {
                                try session.setAlbumMetadata(eventName: eventName, operatorNotes: notes, albumID: albumID)
                                dismiss()
                            } catch { message = sessionViewError(error) }
                        }
                    }
                }
                .onAppear {
                    eventName = session.album(id: albumID)?.eventName ?? ""
                    notes = session.album(id: albumID)?.operatorNotes ?? ""
                }
        }
    }
}

/// Navigation-independent full-screen review. Preview decoding is bounded; export is always the file URL.
@MainActor
struct SessionPhotoViewer: View {
    @ObservedObject private var session: ShootSession
    let albumID: String
    @State private var selectedPhotoID: String
    @State private var exportRequest: SessionSystemExportRequest?
    @State private var details = false
    @State private var message = ""
    @Environment(\.dismiss) private var dismiss

    init(session: ShootSession, albumID: String, initialPhotoID: String) {
        self.session = session
        self.albumID = albumID
        _selectedPhotoID = State(initialValue: initialPhotoID)
    }
    private var album: SessionAlbumRecord? { session.album(id: albumID) }
    private var photos: [ReceivedJPEG] { album?.sortedPhotos ?? [] }
    private var selected: ReceivedJPEG? { photos.first { $0.id == selectedPhotoID } }
    private var index: Int { photos.firstIndex { $0.id == selectedPhotoID } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("關閉") { dismiss() }
                Spacer()
                Button("回到最新") { if let newest = photos.first { selectedPhotoID = newest.id } }
                Button { share() } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享這張原圖")
            }.padding()
            if photos.isEmpty { Spacer(); Text("本場沒有照片"); Spacer() }
            else {
                TabView(selection: $selectedPhotoID) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { position, photo in
                        Group {
                            if abs(position - index) <= 1 { SessionViewerImage(url: photo.url) }
                            else { Color.black }
                        }.tag(photo.id).accessibilityLabel("大圖預覽 \(photo.name)")
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never))
            }
            Text(selected?.name ?? "原圖未能讀取").lineLimit(2).font(.callout).padding(.horizontal)
            if !message.isEmpty { Text(message).font(.caption).padding(.horizontal) }
            HStack {
                Button { move(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index <= 0).accessibilityLabel("較新一張")
                Spacer()
                Button("\(photos.isEmpty ? 0 : index + 1) / \(photos.count)・詳情／耗時") { details = true }
                    .font(.caption)
                Spacer()
                Button { move(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index + 1 >= photos.count).accessibilityLabel("較舊一張")
            }.padding()
            Text("左右翻圖・雙點／雙指縮放・放大後拖移。預覽最多 4096px；分享不會重編碼原圖。")
                .font(.caption2).foregroundColor(.secondary).padding(.horizontal).padding(.bottom, 8)
        }.background(Color.black).foregroundColor(.white).preferredColorScheme(.dark)
            .onAppear { if selected == nil, let first = photos.first { selectedPhotoID = first.id } }
            .sheet(item: $exportRequest) { request in SessionSystemExportSheet(request: request) }
            .sheet(isPresented: $details) {
                NavigationStack {
                    List {
                        if let photo = selected, let album = album {
                            Section("原圖紀錄") {
                                Text(photo.name)
                                Text("\(photo.bytes) bytes")
                                Text("接收時間（不是 EXIF 拍攝時間）：\(SessionExport.isoDate(photo.createdAt))")
                                Text("SHA-256：\(photo.sha256)").font(.caption).textSelection(.enabled)
                                Text("舊版 PC 旗標：\(photo.uploaded ? "已核對（未區分電腦）" : "未核對")")
                            }
                            Section("實際接收量度・毫秒") {
                                let timing = album.photoTimings[photo.id]
                                Text("排隊：\(SessionExport.duration(timing?.queueMilliseconds))")
                                Text("接收：\(SessionExport.duration(timing?.receiveMilliseconds))")
                                Text("本機驗證：\(SessionExport.duration(timing?.verifyMilliseconds))")
                            }
                            Section("目的地回條") {
                                let receipts = album.receipts.filter { $0.photoID == photo.id }
                                if receipts.isEmpty { Text("未記錄，不代表已上傳。") }
                                ForEach(Array(receipts.enumerated()), id: \.offset) { _, receipt in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("\(receipt.provider.title) [\(receipt.destinationKey)]・\(receipt.state.title)")
                                        Text(receipt.verification.sessionTitle)
                                        Text("排隊／傳送／核對 ms：\(SessionExport.duration(receipt.queueMilliseconds)) / \(SessionExport.duration(receipt.sendMilliseconds)) / \(SessionExport.duration(receipt.verifyMilliseconds))")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }.navigationTitle("照片詳情")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("關閉") { details = false } } }
                }
            }
    }
    private func move(_ offset: Int) {
        let next = index + offset
        guard photos.indices.contains(next) else { return }
        selectedPhotoID = photos[next].id
    }
    private func share() {
        guard let album = album, let photo = selected else { return }
        do {
            exportRequest = SessionSystemExportRequest(
                urls: try SessionExport.originalURLs(album: album, selectedIDs: [photo.id]), destination: .share)
        } catch { message = sessionViewError(error) }
    }
}

private struct SessionViewerSelection: Identifiable { let id: String }

/// Original URLs are passed to the system, never UIImage/pngData/jpegData.
struct SessionSystemExportRequest: Identifiable {
    enum Destination { case share, files }
    let id = UUID()
    let urls: [URL]
    let destination: Destination
    init(urls: [URL], destination: Destination = .share) {
        self.urls = urls
        self.destination = destination
    }
}

@MainActor
struct SessionSystemExportSheet: UIViewControllerRepresentable {
    let request: SessionSystemExportRequest
    init(request: SessionSystemExportRequest) { self.request = request }
    func makeUIViewController(context: Context) -> UIViewController {
        switch request.destination {
        case .files:
            // asCopy is critical: never move/delete an original from the app's durable archive.
            return UIDocumentPickerViewController(forExporting: request.urls, asCopy: true)
        case .share:
            let controller = UIActivityViewController(activityItems: request.urls, applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = controller.view
                popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
            return controller
        }
    }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }
}

private func sessionViewError(_ error: Error) -> String {
    // Do not surface raw NSError, provider URLs, signed URLs or remote messages in UI/history.
    (error as? SessionArchiveError)?.localizedDescription ?? "未能完成操作；原圖仍保留，請檢查儲存空間或重新開啟。"
}

private extension SessionVerification {
    var sessionTitle: String {
        switch self {
        case .none: return "尚未核對"
        case .receiverSHA256: return "PC Receiver 回覆整檔 SHA-256"
        case .driveIDSizeMD5Parent: return "Drive ID／大小／MD5／parent（未提供 SHA-256）"
        case .driveIDSizeMD5ParentSHA256: return "Drive ID／大小／MD5／parent／SHA-256"
        case .oneDriveSizeOnly: return "OneDrive 僅大小；未提供 SHA-256"
        case .oneDriveSizeSHA256: return "OneDrive 大小／SHA-256"
        case .downloadedSizeSHA256: return "遠端讀回大小／整檔 SHA-256"
        }
    }
}

/// Single serial off-main decoder with a bounded memory-only cache. No thumbnail files are written.
private actor SessionImageCache {
    static let shared = SessionImageCache()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    func image(url: URL, maxPixels: Int) -> UIImage? {
        guard url.isFileURL else { return nil }
        let key = "\(url.path)#\(maxPixels)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let result = UIImage(cgImage: image)
        cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
        return result
    }
}

@MainActor
private struct SessionLocalImage: View {
    let url: URL?
    let maxPixels: Int
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            if let image = image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundColor(.secondary).accessibilityLabel("預覽不可用") }
        }.task(id: "\(url?.absoluteString ?? "")#\(maxPixels)") {
            image = nil
            guard let url = url else { return }
            let decoded = await SessionImageCache.shared.image(url: url, maxPixels: maxPixels)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

@MainActor
private struct SessionViewerImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var loaded = false
    var body: some View {
        Group {
            if let image = image { SessionZoomImage(image: image, identity: url.absoluteString) }
            else if loaded { Text("未能讀取預覽；不會刪除原圖。") }
            else { ProgressView("正在讀取大圖") }
        }.task(id: url) {
            loaded = false
            image = nil
            let decoded = await SessionImageCache.shared.image(url: url, maxPixels: 4096)
            guard !Task.isCancelled else { return }
            image = decoded
            loaded = true
        }
    }
}

@MainActor
private struct SessionZoomImage: UIViewRepresentable {
    let image: UIImage
    let identity: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> SessionZoomScrollView {
        let scroll = SessionZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .black
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.imageView.contentMode = .scaleAspectFit
        scroll.addSubview(scroll.imageView)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        return scroll
    }
    func updateUIView(_ scroll: SessionZoomScrollView, context: Context) {
        if scroll.identity != identity || scroll.imageView.image !== image {
            scroll.identity = identity
            scroll.setZoomScale(1, animated: false)
            scroll.imageView.image = image
            scroll.setNeedsLayout()
        }
    }
    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? SessionZoomScrollView)?.imageView
        }
        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scroll = recognizer.view as? SessionZoomScrollView else { return }
            if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true) }
            else {
                let point = recognizer.location(in: scroll.imageView)
                let width = scroll.bounds.width / 2.5
                let height = scroll.bounds.height / 2.5
                scroll.zoom(to: CGRect(x: point.x - width / 2, y: point.y - height / 2,
                    width: width, height: height), animated: true)
            }
        }
    }
}

@MainActor
private final class SessionZoomScrollView: UIScrollView {
    let imageView = UIImageView()
    var identity = ""
    private var viewport = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, viewport != bounds.size else { return }
        viewport = bounds.size
        setZoomScale(1, animated: false)
        imageView.frame = CGRect(origin: .zero, size: viewport)
        contentSize = viewport
    }
}
#endif
