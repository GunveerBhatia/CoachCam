import CoreMotion
import Foundation

/// Reads the gyro and accelerometer and turns them into numbers the app can use.
///
/// - `levelError`: how many degrees the phone is tilted away from level (portrait or
///   landscape, whichever is closer). 0 means perfectly straight.
/// - `cameraPitch`: 0 = phone upright; +90 = back camera pointing straight down
///   (used later for food); -90 = pointing straight up.
/// - `shake`: how much the phone is moving (rad/s, smoothed). Near 0 means steady.
final class MotionService: ObservableObject {
    @Published private(set) var rollDegrees: Double = 0
    @Published private(set) var levelError: Double = 0
    @Published private(set) var cameraPitch: Double = 0
    @Published private(set) var shake: Double = 0

    private let manager = CMMotionManager()
    private let queue = OperationQueue()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 20.0   // 20 Hz is plenty for a level line.
        queue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, error in
            if let error { Log.warn("Motion error: \(error.localizedDescription)"); return }
            guard let self, let motion else { return }
            let g = motion.gravity
            // Rotation around the screen's axis. 0° = upright portrait, ±90° = landscape.
            let roll = atan2(g.x, -g.y) * 180 / .pi
            let nearestRightAngle = (roll / 90).rounded() * 90
            let level = roll - nearestRightAngle
            // Forward/back tilt. Positive = back camera pointing down.
            let pitch = asin(max(-1, min(1, -g.z))) * 180 / .pi
            let r = motion.rotationRate
            let rotation = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
            DispatchQueue.main.async {
                self.rollDegrees = roll
                self.levelError = level
                self.cameraPitch = pitch
                self.shake = self.shake * 0.8 + rotation * 0.2   // Simple smoothing.
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}
