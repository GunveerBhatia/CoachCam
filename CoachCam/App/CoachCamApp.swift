import SwiftUI

/// App entry point.
@main
struct CoachCamApp: App {
    init() {
        LogStore.installCrashHandler()
        Log.info("App launched — \(AppVersion.full) — \(ProvisioningInfo.summary)")
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.dark)
        }
    }
}
