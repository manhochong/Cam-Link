import SwiftUI

@main
struct CamLinkApp: App {
    @StateObject private var camera = CameraCaptureService()
    @StateObject private var session = ShootSession()
    @StateObject private var pair = PairStore()
    @StateObject private var webDAV = WebDAVStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(camera)
                .environmentObject(session)
                .environmentObject(pair)
                .environmentObject(webDAV)
                .onAppear {
                    camera.onJPEG = { file in
                        Task { @MainActor in
                            session.ingest(file)
                        }
                    }
                }
        }
    }
}
