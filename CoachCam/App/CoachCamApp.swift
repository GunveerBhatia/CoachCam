import SwiftUI

/// App entry point. Later milestones swap `HelloView` for the camera screen.
@main
struct CoachCamApp: App {
    var body: some Scene {
        WindowGroup {
            HelloView()
        }
    }
}
