import SwiftUI

/// The small badge at the top left showing the current mode.
/// Tap it to pick a mode yourself, or "Auto" to go back to automatic.
struct ModeBadge: View {
    @ObservedObject var engine: ModeEngine

    var body: some View {
        Menu {
            Button {
                engine.choose(nil)
            } label: {
                Label("Auto", systemImage: engine.isAutomatic ? "checkmark" : "sparkles")
            }
            Divider()
            ForEach(ShootingMode.allCases) { mode in
                Button {
                    engine.choose(mode)
                } label: {
                    if engine.manualMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Label(mode.title, systemImage: mode.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: engine.mode.icon)
                Text(engine.mode.title)
                    .lineLimit(1)
                Text(engine.isAutomatic ? "AUTO" : "MANUAL")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(engine.isAutomatic ? Color.yellow : Color.orange, in: Capsule())
                    .foregroundStyle(.black)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(.white.opacity(0.15), in: Capsule())
            .animation(.easeOut(duration: 0.15), value: engine.mode)
        }
    }
}
