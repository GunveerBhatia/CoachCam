import CoreGraphics
import Foundation

/// The result of checking one step against the live camera.
struct StepResult {
    enum Status { case pass, fail, unknown }
    var status: Status
    /// Which way to go when failing (used when the step's arrow is "auto").
    var arrow: ArrowType?
    /// The measured value, for the debug overlay (helps tune the numbers).
    var detail: String
}

/// Everything a check can look at, gathered once per analysis.
struct StepContext {
    var description: SceneDescription
    var analysis: SceneAnalysis
    var levelError: Double
    var cameraPitch: Double
    var shake: Double
    /// The main person (tapped one first), and the main subject box (person or object).
    var person: PersonInfo?
    var subjectBox: CGRect?
}

/// Implements every check type the playbook can use. Positions are upright frame
/// coordinates (0–1, top-left origin). Pitch: + = phone pointing down.
enum StepEvaluator {
    static func evaluate(_ check: StepCheck, _ c: StepContext) -> StepResult {
        let lo = check.min, hi = check.max

        /// Pass if v is within [lo, hi]; otherwise return the arrow for "too low" / "too high".
        func range(_ v: Double, low: ArrowType?, high: ArrowType?, format: String = "%.2f") -> StepResult {
            let text = String(format: format, v)
            if let lo, v < lo { return StepResult(status: .fail, arrow: low, detail: text) }
            if let hi, v > hi { return StepResult(status: .fail, arrow: high, detail: text) }
            return StepResult(status: .pass, arrow: nil, detail: text)
        }
        let unknown = StepResult(status: .unknown, arrow: nil, detail: "—")

        switch check.type {
        case "level":
            // levelError > 0 → phone turned clockwise → rotate it back counterclockwise.
            let limit = hi ?? 1.5
            let v = c.levelError
            if abs(v) <= limit { return StepResult(status: .pass, arrow: nil, detail: String(format: "%+.1f°", v)) }
            return StepResult(status: .fail, arrow: v > 0 ? .rotateCounterclockwise : .rotateClockwise,
                              detail: String(format: "%+.1f°", v))

        case "pitch":
            // Too low a value → not pointing down enough → tilt down.
            return range(c.cameraPitch, low: .tiltDown, high: .tiltUp, format: "%+.0f°")

        case "eyeLevel":
            // With the phone level, eyes high in the frame mean the camera is below eye level.
            guard let face = c.person?.faceBox else { return unknown }
            return range(Double(face.midY), low: .raisePhone, high: .lowerPhone)

        case "subjectSize":
            let measure = check.measure ?? "height"
            var v: Double?
            switch measure {
            case "faceArea": v = c.person.map { $0.faceArea }
            case "area": v = c.subjectBox.map { Double($0.area) }
            default: v = (c.person?.box ?? c.subjectBox).map { Double($0.height) }
            }
            guard let v else { return unknown }
            return range(v, low: .stepCloser, high: .stepBack)

        case "headroom":
            // Too little space above the head → tilt up; too much → tilt down.
            guard let top = c.person?.headTopY else { return unknown }
            return range(Double(top), low: .tiltUp, high: .tiltDown)

        case "headInFrame":
            guard let top = c.person?.headTopY else { return unknown }
            return range(Double(top), low: .stepBack, high: nil)

        case "fullBody":
            guard let person = c.person else { return unknown }
            let headOK = (person.headTopY ?? 0) >= (lo ?? 0.01)
            if person.fullBodyVisible && headOK { return StepResult(status: .pass, arrow: nil, detail: "head+feet") }
            return StepResult(status: .fail, arrow: .stepBack, detail: person.fullBodyVisible ? "head cut" : "feet cut")

        case "placement":
            guard let box = c.person?.box ?? c.subjectBox else { return unknown }
            // Mirror for the front camera, so left/right match what you see on screen.
            var x = Double(box.midX)
            if c.description.isFrontCamera { x = 1 - x }
            let targets: [Double] = check.target == "center" ? [0.5] : [1.0 / 3, 2.0 / 3]
            let target = targets.min { abs($0 - x) < abs($1 - x) } ?? 0.5
            let tolerance = hi ?? 0.07
            let text = String(format: "x %.2f → %.2f", x, target)
            if abs(x - target) <= tolerance { return StepResult(status: .pass, arrow: nil, detail: text) }
            // Subject left of where it should be → move the phone left (the subject shifts right).
            return StepResult(status: .fail, arrow: x < target ? .moveLeft : .moveRight, detail: text)

        case "faceYaw":
            guard let yaw = c.person?.faceYaw else { return unknown }
            return range(yaw, low: .subjectTurnRight, high: .subjectTurnLeft, format: "%+.0f°")

        case "faceRoll":
            guard let roll = c.person?.faceRoll else { return unknown }
            let limit = hi ?? 6
            let text = String(format: "%+.0f°", roll)
            return abs(roll) <= limit ? StepResult(status: .pass, arrow: nil, detail: text)
                : StepResult(status: .fail, arrow: .subjectStraightenHead, detail: text)

        case "facePitch":
            guard let pitch = c.person?.facePitch else { return unknown }
            return range(pitch, low: .subjectChinUp, high: .subjectChinDown, format: "%+.0f°")

        case "bodyAngle":
            // Shoulder width ÷ shoulder-to-hip height shrinks as the body turns away.
            guard let p = c.person, let ls = p.joints["leftShoulder"], let rs = p.joints["rightShoulder"],
                  let hip = p.joints["root"] ?? p.joints["leftHip"] ?? p.joints["rightHip"] else { return unknown }
            let torso = Double(hip.y - (ls.y + rs.y) / 2)
            guard torso > 0.02 else { return unknown }
            let ratio = Double(abs(ls.x - rs.x)) / torso
            // Too square to the camera (ratio too high) → turn the body.
            return range(ratio, low: .subjectTurnRight, high: .subjectTurnLeft)

        case "noJointCrop":
            // A knee/ankle/elbow/wrist sitting right on the bottom or side edge = awkward crop.
            guard let p = c.person else { return unknown }
            let margin = CGFloat(hi ?? 0.03)
            let names = ["leftKnee", "rightKnee", "leftAnkle", "rightAnkle", "leftWrist", "rightWrist", "leftElbow", "rightElbow"]
            let cut = names.compactMap { p.joints[$0] }.contains { $0.y > 1 - margin || $0.x < margin || $0.x > 1 - margin }
            return cut ? StepResult(status: .fail, arrow: .stepBack, detail: "joint at edge")
                : StepResult(status: .pass, arrow: nil, detail: "ok")

        case "gap":
            let people = c.analysis.people
            guard people.count >= 2 else { return unknown }
            let a = people[0].box, b = people[1].box
            let gap = Double(max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)))
            return range(gap, low: nil, high: .subjectCloseGap)

        case "staggered":
            let tops = c.analysis.people.prefix(2).compactMap { $0.headTopY }
            guard tops.count == 2 else { return unknown }
            return range(Double(abs(tops[0] - tops[1])), low: .subjectStaggerHeads, high: nil)

        case "steady":
            return range(c.shake, low: nil, high: ArrowType.none, format: "%.2f")

        case "notBacklit":
            return c.description.lighting.isBacklit ? StepResult(status: .fail, arrow: ArrowType.none, detail: "backlit")
                : StepResult(status: .pass, arrow: nil, detail: "ok")

        case "notHarsh":
            return c.description.lighting.isHarsh ? StepResult(status: .fail, arrow: ArrowType.none, detail: "harsh")
                : StepResult(status: .pass, arrow: nil, detail: "ok")

        case "manual":
            return StepResult(status: .unknown, arrow: nil, detail: "tap ✓ when done")

        default:
            return StepResult(status: .unknown, arrow: nil, detail: "unknown check \(check.type)")
        }
    }
}
