import CoreGraphics
import ImageIO

/// Converts between three coordinate systems:
/// - **sensor**: the raw camera buffer, normalized, top-left origin. This is what AVFoundation
///   calls a "capture device point".
/// - **upright**: the picture as it will look in the saved photo (see SceneAnalysis.swift).
/// - **Vision**: like upright, but with the origin at the bottom-left.
///
/// `angle` is AVFoundation's rotation (0, 90, 180 or 270): how far the sensor image must be
/// turned clockwise to be upright. Holding the phone upright in portrait gives 90.
struct FrameGeometry {
    let angle: Int

    init(rotationAngle: CGFloat) {
        let a = Int((rotationAngle / 90).rounded()) * 90
        angle = ((a % 360) + 360) % 360
    }

    /// The orientation to tell Vision so that it sees an upright image.
    var visionOrientation: CGImagePropertyOrientation {
        switch angle {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// Vision point (bottom-left origin) → upright point (top-left origin).
    static func upright(fromVision p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: 1 - p.y)
    }

    /// Vision rect (bottom-left origin) → upright rect (top-left origin).
    static func upright(fromVision r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Upright point → sensor point.
    func sensor(fromUpright u: CGPoint) -> CGPoint {
        switch angle {
        case 90: return CGPoint(x: u.y, y: 1 - u.x)
        case 180: return CGPoint(x: 1 - u.x, y: 1 - u.y)
        case 270: return CGPoint(x: 1 - u.y, y: u.x)
        default: return u
        }
    }

    /// Sensor point → upright point (the inverse of the above).
    func upright(fromSensor s: CGPoint) -> CGPoint {
        switch angle {
        case 90: return CGPoint(x: 1 - s.y, y: s.x)
        case 180: return CGPoint(x: 1 - s.x, y: 1 - s.y)
        case 270: return CGPoint(x: s.y, y: 1 - s.x)
        default: return s
        }
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { isNull ? 0 : width * height }

    /// Intersection-over-union: 1 = identical boxes, 0 = no overlap.
    func iou(_ other: CGRect) -> CGFloat {
        let inter = intersection(other).area
        let union = area + other.area - inter
        return union > 0 ? inter / union : 0
    }

    /// Fraction of *this* box that lies inside `other`.
    func fractionInside(_ other: CGRect) -> CGFloat {
        area > 0 ? intersection(other).area / area : 0
    }
}

extension CGPoint {
    func distance(to p: CGPoint) -> CGFloat {
        hypot(x - p.x, y - p.y)
    }
}
