import SwiftUI

/// Row of small badges showing what the camera set automatically ("4x Headshot", "HDR",
/// "Low light", "Fast shutter"…). Tap one to turn that setting off (grey, struck through);
/// tap again to turn it back on.
struct AutoBadgesRow: View {
    @ObservedObject var engine: AutoSettingsEngine
    let camera: CameraService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(engine.badges) { badge in
                    Button {
                        engine.toggle(badge.kind, camera: camera)
                    } label: {
                        Text(badge.text)
                            .strikethrough(badge.isOff)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(badge.isOff ? Color.white.opacity(0.45) : Color.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(badge.isOff ? Color.white.opacity(0.15) : Color.yellow.opacity(0.9),
                                        in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.15), value: engine.badges)
    }
}

/// Big "Hold still" message while the night merge is capturing.
struct HoldStillOverlay: View {
    @ObservedObject var engine: AutoSettingsEngine

    var body: some View {
        if engine.holdingStill {
            VStack(spacing: 6) {
                ProgressView().tint(.white)
                Text("Hold still").font(.title3.bold())
                Text("Night merge").font(.caption)
            }
            .foregroundStyle(.white)
            .padding(18)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            .allowsHitTesting(false)
        }
    }
}
