import SwiftUI

@main
struct VideoCompressorApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before any player exists, so the first thing played is already exempt from the
        // ring/silent switch rather than silent until something re-configures the session.
        AudioSessionController.configureForPlayback()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                AudioSessionController.relinquish()
            }
        }
    }
}
