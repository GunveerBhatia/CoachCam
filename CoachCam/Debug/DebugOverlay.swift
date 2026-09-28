import SwiftUI

/// The on-screen debug panel (turn it on in Settings). Since there's no Xcode debugger,
/// this is how we see what the app is thinking. "Rule" gets filled in by M4 (coaching).
struct DebugOverlay: View {
    @ObservedObject var camera: CameraService
    @ObservedObject var stats: LiveStats
    @ObservedObject var motion: MotionService
    @ObservedObject var analyzer: SceneAnalyzer
    @ObservedObject var engine: ModeEngine
    @ObservedObject var diagnostics: ModeDiagnostics

    var body: some View {
        let a = analyzer.latest
        VStack(alignment: .leading, spacing: 2) {
            row("Mode", "\(engine.mode.title)\(engine.isAutomatic ? "" : " (manual)") ← \(diagnostics.proposal.title): \(diagnostics.reason)")
            row("People", peopleText(a))
            row("Objects", a.objects.isEmpty ? "none" :
                a.objects.prefix(4).map { "\($0.label) \(Int($0.confidence * 100))%" }.joined(separator: ", "))
            row("Scene", a.labels.isEmpty ? "—" :
                a.labels.prefix(3).map { "\($0.label) \(Int($0.confidence * 100))%" }.joined(separator: ", "))
            row("Light", lightText(a))
            row("Tilt", String(format: "level %+.1f° pitch %+.0f° horizon %@", motion.levelError, motion.cameraPitch,
                               a.horizonDegrees.map { String(format: "%+.1f°", $0) } ?? "—"))
            row("Motion", String(format: "shake %.2f · scene change %.3f", motion.shake, a.frameChange))
            row("Lens", String(format: "%.1fx · %@", camera.zoom, camera.physicalLens))
            row("Exposure", String(format: "ISO %.0f · 1/%.0f s · f/%.2f", stats.iso,
                                   stats.shutter > 0 ? 1 / stats.shutter : 0, stats.aperture))
            row("Rule", "—")
            row("Frame", String(format: "analysis %.0f ms · %.0f/s · camera %.0f fps · YOLO %@",
                                a.analysisMs, analyzer.ticksPerSecond, stats.fps, analyzer.modelStatus))
            row("Switch", diagnostics.lastSwitchLatencyMs.map { String(format: "last mode change took %.0f ms", $0) } ?? "—")
            row("Heat", thermalText)
        }
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }

    private func peopleText(_ a: SceneAnalysis) -> String {
        guard let p = a.people.first else { return "0" }
        var parts = ["\(a.people.count)"]
        parts.append(String(format: "fill %.0f%%", p.fillFraction * 100))
        if p.faceBox != nil {
            parts.append(String(format: "face %.1f%%", p.faceArea * 100))
            if let yaw = p.faceYaw { parts.append(String(format: "yaw %+.0f°", yaw)) }
            if let roll = p.faceRoll { parts.append(String(format: "roll %+.0f°", roll)) }
        }
        parts.append(p.fullBodyVisible ? "full body" : "partial")
        if a.people.count >= 2 {
            let gap = a.people[1].box.minX > a.people[0].box.maxX
                ? a.people[1].box.minX - a.people[0].box.maxX
                : max(0, a.people[0].box.minX - a.people[1].box.maxX)
            parts.append(String(format: "gap %.2f", gap))
        }
        return parts.joined(separator: " · ")
    }

    private func lightText(_ a: SceneAnalysis) -> String {
        let l = a.light
        var s = String(format: "%.0f%% · clip hi %.0f%% lo %.0f%%", l.mean * 100, l.clippedHighlights * 100,
                       l.clippedShadows * 100)
        if let face = l.faceMean { s += String(format: " · face %.0f%%", face * 100) }
        if let halves = l.faceLeftRight { s += String(format: " L%.0f/R%.0f", halves.0 * 100, halves.1 * 100) }
        s += String(format: " · cast b%+.2f r%+.2f", l.colorCastBlue, l.colorCastRed)
        return s
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(label).foregroundStyle(.green).frame(width: 52, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
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
