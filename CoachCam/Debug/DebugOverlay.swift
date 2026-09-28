import SwiftUI

/// The on-screen debug panel (turn it on in Settings). Because there's no Xcode
/// debugger, this is how we see what the app is thinking.
///
/// Rows marked "—" get filled in by later milestones (mode and objects in M2,
/// coaching rule in M4).
struct DebugOverlay: View {
    @ObservedObject var camera: CameraService
    @ObservedObject var stats: LiveStats
    @ObservedObject var motion: MotionService

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("Mode", "—")
            row("Objects", "—")
            row("Brightness", String(format: "%.0f%%", stats.brightness * 100))
            row("Tilt", String(format: "level %+.1f° pitch %+.0f°", motion.levelError, motion.cameraPitch))
            row("Shake", String(format: "%.2f", motion.shake))
            row("Lens", String(format: "%.1fx · %@", camera.zoom, camera.physicalLens))
            row("Exposure", String(format: "ISO %.0f · 1/%.0f s · f/%.2f", stats.iso,
                                   stats.shutter > 0 ? 1 / stats.shutter : 0, stats.aperture))
            row("Rule", "—")
            row("Frame", String(format: "%.1f ms · %.0f fps", stats.frameMs, stats.fps))
            row("Heat", thermalText)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).foregroundStyle(.green).frame(width: 64, alignment: .leading)
            Text(value)
        }
    }

    private var thermalText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "normal"
        case .fair: return "warm"
        case .serious: return "hot"
        case .critical: return "critical"
        @unknown default: return "?"
        }
    }
}
