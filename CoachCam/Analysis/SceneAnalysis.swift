import CoreGraphics
import Foundation

// Coordinate convention used everywhere in the app:
// "upright" normalized coordinates, (0,0) = top-left and (1,1) = bottom-right of the
// picture as you'd see it in the saved photo (world-upright, portrait or landscape).
// Vision uses bottom-left origin; we convert once, in the analyzer.

/// One object found by YOLO (e.g. "umbrella", "cup").
struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let box: CGRect
}

/// One person: body joints, face, and simple measurements.
struct PersonInfo: Identifiable {
    let id = UUID()
    /// Box around the whole visible body (from joints), including an estimated head top.
    var box: CGRect
    /// Face box, if a face was found for this person.
    var faceBox: CGRect?
    /// Face direction in degrees: yaw (turned left/right), roll (head tilt), pitch (up/down).
    var faceYaw: Double?
    var faceRoll: Double?
    var facePitch: Double?
    /// Estimated top of the head (y, 0 = top of frame).
    var headTopY: CGFloat?
    /// Body joints that were found confidently (name → position).
    var joints: [String: CGPoint]
    /// Head and at least one ankle visible.
    var fullBodyVisible: Bool
    /// Eye, nose, lip and face-outline points (refreshed about 3×/s).
    var faceLandmarks: [CGPoint] = []
    /// Raw person-type model output for this face (11 numbers), on slow ticks only.
    /// Turned into a smoothed, correctable label by PersonTypeTracker.
    var typeModelOutput: [Double]?
    /// How much of the frame's area the person's box covers (0–1).
    var fillFraction: Double {
        Double(box.width * box.height)
    }
    /// Face area as a fraction of the frame, 0 if no face.
    var faceArea: Double {
        guard let f = faceBox else { return 0 }
        return Double(f.width * f.height)
    }
}

/// Light measurements from the frame.
struct LightInfo {
    var mean: Double = 0                  // 0 = black, 1 = white
    var clippedHighlights: Double = 0     // fraction of pixels blown out
    var clippedShadows: Double = 0        // fraction of pixels crushed black
    var faceMean: Double?                 // brightness of the main face
    var faceLeftRight: (Double, Double)?  // brightness of the left and right halves of that face
    var colorCastBlue: Double = 0         // + = blue tint, - = yellow tint
    var colorCastRed: Double = 0          // + = red/magenta tint, - = green/cyan tint
}

/// Everything the analyzer found in one analysis tick.
struct SceneAnalysis {
    var timestamp: TimeInterval = 0
    var isFrontCamera = false
    /// Camera facts at the time of the frame (see FrameInfo).
    var lensPosition: Double?
    var horizontalFOV: Double?
    var isMacro = false
    var rotationAngle = 90
    /// Share of the frame covered by strong upright-vertical edges (buildings score high).
    var verticalLines: Double = 0
    var people: [PersonInfo] = []
    var objects: [DetectedObject] = []
    /// Scene labels from Vision's classifier, best first (e.g. "sky" 0.82). Updated on slow ticks.
    var labels: [(label: String, confidence: Float)] = []
    /// Horizon tilt in degrees (nil if none found). Updated on slow ticks.
    var horizonDegrees: Double?
    /// Where Vision thinks the eye goes first. Updated on slow ticks.
    var salientBox: CGRect?
    var light = LightInfo()
    /// How much the picture changed since the last tick (0 = still, ~0.1+ = lots of motion).
    var frameChange: Double = 0
    /// Time the whole analysis took, in milliseconds.
    var analysisMs: Double = 0

    func labelConfidence(anyOf names: [String]) -> Float {
        var best: Float = 0
        for (label, confidence) in labels where names.contains(where: { label.localizedCaseInsensitiveContains($0) }) {
            best = max(best, confidence)
        }
        return best
    }
}
