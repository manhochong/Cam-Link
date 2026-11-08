import SwiftUI

@main
@MainActor
struct CamLinkApp: App {
    @StateObject private var runtime = CamLinkRuntime()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(runtime)
                .environmentObject(runtime.camera)
                .environmentObject(runtime.session)
                .environmentObject(runtime.pair)
                .environmentObject(runtime.pc)
                .environmentObject(runtime.webDAV)
                .environmentObject(runtime.google)
                .environmentObject(runtime.oneDrive)
                .environmentObject(runtime.feedback)
        }
    }
}
