import CoreGraphics
import Foundation

/// What one check measures right now. The step engine smooths `value`, then compares it with
/// the tight band (to complete) and the wide band (to undo).
struct StepMeasurement {
    /// nil = can't be measured right now (e.g. no face visible).
    var value: Double?
    /// The tight band: the step completes while the value stays inside it.
    var low: Double
    var high: Double
    /// Arrows when the value is below / above the band.
    var lowArrow: ArrowType?
    var highArrow: ArrowType?
    /// Smallest widening for the undo band (degrees for angles, fractions for positions).
    var minMargin: Double
    var unit: String = ""
    var isManual = false

    static func unavailable(_ low: Double = 0, _ high: Double = 1) -> StepMeasurement {
        StepMeasurement(value: nil, low: low, high: high, minMargin: 0)
    }
}

/// Everything a check can look at, gathered once per analysis. Motion values are already
/// smoothed by MotionService.
struct StepContext {
    var description: SceneDescription
    var analysis: SceneAnalysis
    var levelError: Double
    var cameraPitch: Double
    var shake: Double
    /// The locked person (if the subject is a person) and the locked subject box.
    var person: PersonInfo?
    var subjectBox: CGRect?
}

/// Implements every check type the playbook can use. Positions are upright frame
/// coordinates (0–1, top-left origin). Pitch: + = phone pointing down.
/// The playbook's `min`/`max` set the tight band (defaults below); `undoMin`/`undoMax`
/// set the wide band.
enum StepEvaluator {
    static func measure(_ check: StepCheck, _ c: StepContext, angleMargin: Double) -> StepMeasurement {
        let inf = Double.greatestFiniteMagnitude
        func band(_ defLow: Double, _ defHigh: Double) -> (Double, Double) {
            (check.min ?? defLow, check.max ?? defHigh)
        }
        /// Good/bad checks become 1/0 so they can be smoothed like numbers.
        func boolean(_ good: Bool?, bad: ArrowType?) -> StepMeasurement {
            StepMeasurement(value: good.map { $0 ? 1 : 0 }, low: 0.7, high: inf, lowArrow: bad, highArrow: nil, minMargin: 0.4)
        }

        switch check.type {
        case "level":
            // levelError > 0 → phone turned clockwise → rotate it back counterclockwise.
            let limit = check.max ?? 1.5
            return StepMeasurement(value: c.levelError, low: -limit, high: limit, lowArrow: .rotateClockwise,
                                   highArrow: .rotateCounterclockwise, minMargin: angleMargin, unit: "°")

        case "pitch":
            // Too low a value → not pointing down enough → tilt down.
            let (lo, hi) = band(-4, 4)
            return StepMeasurement(value: c.cameraPitch, low: lo, high: hi, lowArrow: .tiltDown, highArrow: .tiltUp,
                                   minMargin: angleMargin, unit: "°")

        case "eyeLevel":
            // With the phone level, eyes high in the frame mean the camera is below eye level.
            let (lo, hi) = band(0.25, 0.42)
            return StepMeasurement(value: c.person?.faceBox.map { Double($0.midY) }, low: lo, high: hi,
                                   lowArrow: .raisePhone, highArrow: .lowerPhone, minMargin: 0.04)

        case "subjectSize":
            var v: Double?
            switch check.measure ?? "height" {
            case "faceArea": v = c.person.flatMap { $0.faceBox != nil ? $0.faceArea : nil }
            case "area": v = c.subjectBox.map { Double($0.area) }
            default: v = (c.person?.box ?? c.subjectBox).map { Double($0.height) }
            }
            let (lo, hi) = band(0, inf)
            return StepMeasurement(value: v, low: lo, high: hi, lowArrow: .stepCloser, highArrow: .stepBack,
                                   minMargin: 0.01)

        case "headroom":
            // Too little space above the head → tilt up; too much → tilt down.
            let (lo, hi) = band(0.03, 0.15)
            return StepMeasurement(value: c.person?.headTopY.map { Double($0) }, low: lo, high: hi,
                                   lowArrow: .tiltUp, highArrow: .tiltDown, minMargin: 0.03)

        case "headInFrame":
            let (lo, _) = band(0.01, inf)
            return StepMeasurement(value: c.person?.headTopY.map { Double($0) }, low: lo, high: inf,
                                   lowArrow: .stepBack, highArrow: nil, minMargin: 0.02)

        case "fullBody":
            guard let p = c.person else { return .unavailable() }
            return boolean(p.fullBodyVisible && (p.headTopY ?? 0) >= (check.min ?? 0.01), bad: .stepBack)

        case "placement":
            guard let box = c.person?.box ?? c.subjectBox else { return .unavailable() }
            // Mirror for the front camera so left/right match what you see.
            var x = Double(box.midX)
            if c.description.isFrontCamera { x = 1 - x }
            let targets: [Double] = check.target == "center" ? [0.5] : [1.0 / 3, 2.0 / 3]
            let target = targets.min { abs($0 - x) < abs($1 - x) } ?? 0.5
            let tolerance = check.max ?? 0.07
            // Subject left of where it should be → move the phone left (the subject shifts right).
            return StepMeasurement(value: x - target, low: -tolerance, high: tolerance, lowArrow: .moveLeft,
                                   highArrow: .moveRight, minMargin: 0.03)

        case "faceYaw":
            let (lo, hi) = band(-12, 12)
            return StepMeasurement(value: c.person?.faceYaw, low: lo, high: hi, lowArrow: .subjectTurnRight,
                                   highArrow: .subjectTurnLeft, minMargin: angleMargin * 2, unit: "°")

        case "faceRoll":
            let limit = check.max ?? 6
            return StepMeasurement(value: c.person?.faceRoll, low: -limit, high: limit, lowArrow: .subjectStraightenHead,
                                   highArrow: .subjectStraightenHead, minMargin: angleMargin * 2, unit: "°")

        case "facePitch":
            let (lo, hi) = band(-15, 5)
            return StepMeasurement(value: c.person?.facePitch, low: lo, high: hi, lowArrow: .subjectChinUp,
                                   highArrow: .subjectChinDown, minMargin: angleMargin * 2, unit: "°")

        case "bodyAngle":
            // Shoulder width ÷ shoulder-to-hip height shrinks as the body turns away.
            var ratio: Double?
            if let p = c.person, let ls = p.joints["leftShoulder"], let rs = p.joints["rightShoulder"],
               let hip = p.joints["root"] ?? p.joints["leftHip"] ?? p.joints["rightHip"] {
                let torso = Double(hip.y - (ls.y + rs.y) / 2)
                if torso > 0.02 { ratio = Double(abs(ls.x - rs.x)) / torso }
            }
            let (lo, hi) = band(0.35, 0.8)
            return StepMeasurement(value: ratio, low: lo, high: hi, lowArrow: .subjectTurnRight,
                                   highArrow: .subjectTurnLeft, minMargin: 0.08)

        case "noJointCrop":
            guard let p = c.person else { return .unavailable() }
            let margin = CGFloat(check.max ?? 0.03)
            let names = ["leftKnee", "rightKnee", "leftAnkle", "rightAnkle", "leftWrist", "rightWrist", "leftElbow", "rightElbow"]
            let cut = names.compactMap { p.joints[$0] }.contains { $0.y > 1 - margin || $0.x < margin || $0.x > 1 - margin }
            return boolean(!cut, bad: .stepBack)

        case "gap":
            let people = c.analysis.people
            guard people.count >= 2 else { return .unavailable() }
            let a = people[0].box, b = people[1].box
            let gap = Double(max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)))
            return StepMeasurement(value: gap, low: -inf, high: check.max ?? 0.02, lowArrow: nil,
                                   highArrow: .subjectCloseGap, minMargin: 0.02)

        case "staggered":
            let tops = c.analysis.people.prefix(2).compactMap { $0.headTopY }
            guard tops.count == 2 else { return .unavailable() }
            return StepMeasurement(value: Double(abs(tops[0] - tops[1])), low: check.min ?? 0.04, high: inf,
                                   lowArrow: .subjectStaggerHeads, highArrow: nil, minMargin: 0.02)

        case "steady":
            return StepMeasurement(value: c.shake, low: -inf, high: check.max ?? 0.08, lowArrow: nil,
                                   highArrow: ArrowType.none, minMargin: 0.05)

        case "notBacklit":
            return boolean(!c.description.lighting.isBacklit, bad: ArrowType.none)

        case "notHarsh":
            return boolean(!c.description.lighting.isHarsh, bad: ArrowType.none)

        case "noFace":
            guard let p = c.person else { return .unavailable() }
            return boolean(p.faceBox == nil, bad: .subjectTurnLeft)

        case "manual":
            var m = StepMeasurement.unavailable()
            m.isManual = true
            return m

        default:
            return .unavailable()
        }
    }
}
