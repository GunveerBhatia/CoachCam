import Foundation

/// The arrow shown with a step. Phone arrows are drawn in the middle of the viewfinder;
/// "subject" arrows are drawn next to the person/object.
enum ArrowType: String, Codable {
    case none
    /// Picked by the check from which way you're off (e.g. tilt up vs tilt down).
    case auto
    // Body / phone movement
    case moveLeft, moveRight, stepCloser, stepBack
    // Phone angle and height
    case tiltUp, tiltDown, raisePhone, lowerPhone
    case rotateClockwise, rotateCounterclockwise
    // Things the subject does (drawn near the subject)
    case subjectTurnLeft, subjectTurnRight, subjectChinDown, subjectChinUp
    case subjectStraightenHead, subjectCloseGap, subjectStaggerHeads, subjectFaceLens

    var isSubjectArrow: Bool { rawValue.hasPrefix("subject") }

    /// SF Symbol for the arrow.
    var symbol: String {
        switch self {
        case .none, .auto: return ""
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .stepCloser: return "figure.walk.arrival"
        case .stepBack: return "figure.walk.departure"
        case .tiltUp: return "arrow.uturn.up"
        case .tiltDown: return "arrow.uturn.down"
        case .raisePhone: return "arrow.up.to.line"
        case .lowerPhone: return "arrow.down.to.line"
        case .rotateClockwise: return "arrow.clockwise"
        case .rotateCounterclockwise: return "arrow.counterclockwise"
        case .subjectTurnLeft: return "arrow.turn.up.left"
        case .subjectTurnRight: return "arrow.turn.up.right"
        case .subjectChinDown: return "arrow.down"
        case .subjectChinUp: return "arrow.up"
        case .subjectStraightenHead: return "arrow.left.and.right"
        case .subjectCloseGap: return "arrow.right.and.line.vertical.and.arrow.left"
        case .subjectStaggerHeads: return "arrow.up.arrow.down"
        case .subjectFaceLens: return "eye"
        }
    }
}

/// How the camera confirms a step is done. Types are implemented once in StepEvaluator;
/// the playbook picks the type and its numbers.
struct StepCheck: Codable {
    /// level, pitch, eyeLevel, subjectSize, headroom, headInFrame, fullBody, placement,
    /// faceYaw, faceRoll, facePitch, bodyAngle, noJointCrop, gap, staggered, steady,
    /// notBacklit, notHarsh, manual
    var type: String
    var min: Double?
    var max: Double?
    /// placement: "thirds" or "center". subjectSize: "height", "faceArea" or "area".
    var target: String?
    var measure: String?
    /// The wide "undo" band: a completed step only comes back if the value stays outside
    /// this band for undoSeconds (defaults: config.json → guide).
    var undoMin: Double?
    var undoMax: Double?
    var undoSeconds: Double?
}

/// One coaching step: short text, an arrow, and a check.
struct GuideStep: Codable, Identifiable {
    var id: String
    /// Default text (under ~8 words).
    var text: String
    /// Text per arrow when the check picks the direction, e.g. {"stepCloser": "Step closer"}.
    var textFor: [String: String]?
    var arrow: ArrowType
    var check: StepCheck
    /// How long the check must stay passing before the step counts as done.
    var hold: Double?

    func text(for arrow: ArrowType?) -> String {
        if let arrow, let specific = textFor?[arrow.rawValue] { return specific }
        return text
    }
}

/// In playbook.json a rule's step is either a name from "stepLibrary" or a full step.
enum StepRef: Decodable {
    case named(String)
    case inline(GuideStep)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .named(name)
        } else {
            self = .inline(try container.decode(GuideStep.self))
        }
    }
}
