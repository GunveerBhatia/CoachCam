import SwiftUI

/// The coaching pill at the top of the viewfinder: arrow + short text, progress dots,
/// and Skip (or ✓ for steps only you can confirm). Swipe right on it to go back a step.
/// Shows "Take it" when every step is done.
struct CoachingPill: View {
    @ObservedObject var guide: StepGuide

    var body: some View {
        VStack(spacing: 5) {
            if guide.allDone {
                Label("Take it", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.green, in: Capsule())
            } else if let step = guide.display {
                HStack(spacing: 8) {
                    if guide.justCompleted {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if step.arrow != .none && !step.arrow.symbol.isEmpty {
                        Image(systemName: step.arrow.symbol)
                    }
                    Text(step.text)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    if step.isManual {
                        Button { guide.confirmManual() } label: {
                            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                                .padding(6)
                                .background(.white.opacity(0.25), in: Circle())
                        }
                    }
                    Button("Skip") { guide.skip() }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.black.opacity(0.6), in: Capsule())
                .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                    if value.translation.width > 40 { guide.back() }
                })
                .animation(.easeOut(duration: 0.15), value: step)
            }
            if !guide.dots.isEmpty {
                HStack(spacing: 5) {
                    ForEach(Array(guide.dots.enumerated()), id: \.offset) { _, dot in
                        Circle()
                            .fill(color(dot))
                            .frame(width: dot == .current ? 8 : 6, height: dot == .current ? 8 : 6)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func color(_ dot: StepGuide.DotState) -> Color {
        switch dot {
        case .done: return .green
        case .skipped: return .white.opacity(0.35)
        case .current: return .white
        case .todo: return .white.opacity(0.35)
        }
    }
}

/// The big arrow for the current step. Phone moves (left/right, closer/back, tilt, raise,
/// rotate) appear in the middle of the viewfinder; subject actions appear next to the
/// subject's face/body.
struct StepArrowOverlay: View {
    @ObservedObject var guide: StepGuide
    let camera: CameraService
    /// The main subject's box (upright coordinates), for placing subject arrows.
    let subjectBox: () -> CGRect?

    var body: some View {
        GeometryReader { geo in
            if let step = guide.display, step.arrow != .none, !step.arrow.symbol.isEmpty, !guide.justCompleted {
                let position = arrowPosition(step.arrow, size: geo.size)
                Image(systemName: step.arrow.symbol)
                    .font(.system(size: step.arrow.isSubjectArrow ? 34 : 56, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .opacity(0.85)
                    .position(position)
                    .transition(.opacity)
                    .animation(.easeOut(duration: 0.2), value: step)
            }
        }
        .allowsHitTesting(false)
    }

    private func arrowPosition(_ arrow: ArrowType, size: CGSize) -> CGPoint {
        if arrow.isSubjectArrow, let box = subjectBox(), let rect = camera.layerRect(fromUpright: box) {
            // Beside the subject's head (or box top), kept on screen.
            return CGPoint(x: min(max(rect.maxX + 30, 30), size.width - 30),
                           y: min(max(rect.minY + 30, 30), size.height - 30))
        }
        switch arrow {
        case .moveLeft: return CGPoint(x: size.width * 0.18, y: size.height / 2)
        case .moveRight: return CGPoint(x: size.width * 0.82, y: size.height / 2)
        case .tiltUp, .raisePhone: return CGPoint(x: size.width / 2, y: size.height * 0.22)
        case .tiltDown, .lowerPhone: return CGPoint(x: size.width / 2, y: size.height * 0.78)
        default: return CGPoint(x: size.width / 2, y: size.height / 2)
        }
    }
}
