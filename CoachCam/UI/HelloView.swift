import SwiftUI

/// M0 test screen. Shows the version and build number so you can confirm
/// that SideStore installed the build you just downloaded.
struct HelloView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.green)
                Text("Hello Coach Cam")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("Version \(version) · Build \(build)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.gray)
            }
        }
    }
}

#Preview {
    HelloView()
}
