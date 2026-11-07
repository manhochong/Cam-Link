import SwiftUI

@main
struct CamLinkApp: App {
    @StateObject private var camera = CameraCaptureService()
    @StateObject private var session = ShootSession()
    @StateObject private var pair = PairStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(camera)
                .environmentObject(session)
                .environmentObject(pair)
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
