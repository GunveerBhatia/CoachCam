import Foundation

/// How much of a person is in the frame.
enum PersonFraming: String {
    case closeUp = "close-up"      // big face, shoulders at the bottom edge (headshot framing)
    case halfBody = "half body"
    case fullBody = "full body"
}

/// Plain-language lighting description (used by coaching in M5).
struct LightingDescription {
    var level = "normal"        // dark / normal / bright
    var isHarsh = false         // lots of blown-out highlights
    var isBacklit = false       // main face much darker than the scene
    var direction = "even"      // even / from picture-left / from picture-right / behind

    var summary: String {
        var parts = [level]
        if isHarsh { parts.append("harsh") }
        if isBacklit { parts.append("backlit") }
        if direction != "even" { parts.append(direction) }
        return parts.joined(separator: ", ")
    }
}

/// What detection says about the frame. Describes only; never decides the photo type.
struct SceneDescription {
    /// Stable subject category (changes only after it's been confident for several ticks).
    var category: SubjectCategory = .general
    /// What this single tick proposed, why, and the sanity checks behind it.
    var proposed: SubjectCategory = .general
    var reason = ""
    var checks: [String] = []

    var peopleCount = 0
    var framing: PersonFraming?
    var mirrorCue = false
    var props: [String] = []
    var background: [String] = []
    var isOutdoor = false
    var lighting = LightingDescription()
    /// Rough distance to the main person (from face size), in metres.
    var personDistance: Double?
    /// Focus position 0 (closest) … 1 (farthest), and whether iOS switched to macro.
    var lensPosition: Double?
    var isMacro = false
    var isFrontCamera = false
    var cameraPitch = 0.0
    var levelError = 0.0
}
