import SwiftUI

/// Rule-of-thirds grid.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    let y = h * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: h))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

/// A line across the middle that always shows the real-world horizon, whether you hold
/// the phone upright or sideways. It turns green and snaps straight when you're within the
/// tolerance of level.
///
/// How: the app's screen is locked to portrait, so when the phone is rotated by `roll`
/// degrees the horizon appears rotated by `-roll` on screen. Sideways (roll ≈ ±90°) the
/// line is drawn along the screen's long side, which is horizontal in your hands.
struct LevelOverlay: View {
    @ObservedObject var motion: MotionService
    /// Degrees counted as "level". (Moves to config.json in M4.)
    var tolerance: Double = 1.0

    var body: some View {
        let isLevel = abs(motion.levelError) <= tolerance
        // Snap to exactly portrait/landscape when level, otherwise follow the real tilt.
        let nearestRightAngle = motion.rollDegrees - motion.levelError
        let angle = isLevel ? -nearestRightAngle : -motion.rollDegrees
        // Hide when the phone points mostly up or down (a level line makes no sense then).
        let visible = abs(motion.cameraPitch) < 60
        HStack(spacing: 0) {
            Rectangle().frame(width: 40, height: 1.5)
            Spacer().frame(width: 60)
            Rectangle().frame(width: 40, height: 1.5)
        }
        .foregroundStyle(isLevel ? Color.green : Color.white.opacity(0.8))
        .rotationEffect(.degrees(angle))
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// The yellow square that appears where you tap to focus.
struct FocusIndicator: View {
    let point: CGPoint
    @State private var scale: CGFloat = 1.4

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .scaleEffect(scale)
            .position(point)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { scale = 1 } }
            .allowsHitTesting(false)
    }
}
