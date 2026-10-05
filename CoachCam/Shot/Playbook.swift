import Foundation

/// The shot suggestions, loaded from Resources/playbook.json (built from docs/SPEC.md and
/// photography research). Each suggestion is a card on the camera screen; tapping it starts
/// its step-by-step walkthrough. Suggestions replace the old photo types.
struct Playbook: Decodable {
    struct Lens: Decodable {
        var zoom: Double
        var fallbackZoom: Double?
        var note: String?
    }

    struct Camera: Decodable {
        var height: String
        var angle: String
    }

    struct AutoSettings: Decodable {
        var exposure: String?      // "face", "sky", "subject", "balanced"
        var hdr: String?           // "auto", "on", "off"
        var lowLight: String?      // "merge", "quality", "off"
        var shutter: String?       // "fast", "normal"
        var whiteBalance: String?  // "auto", "skin", "warm"
        var depth: Bool?
    }

    /// When a suggestion fits, as scene tags (see SuggestionRanker.sceneTags):
    /// all of `all`, at least one of `any` (if given), none of `none`.
    struct Conditions: Decodable {
        var all: [String]?
        var any: [String]?
        var none: [String]?
    }

    struct Suggestion: Decodable, Identifiable {
        var id: String
        var title: String
        var description: String
        /// SF Symbol shown on the card.
        var icon: String
        var category: SubjectCategory
        var when: Conditions?
        /// Tags that make it a better fit (each adds to the score).
        var prefer: [String]?
        /// Starting score, so classics rank above niche ideas.
        var base: Double?
        var lens: Lens
        var camera: Camera
        var placement: String
        var lighting: [String]
        var autoSettings: AutoSettings
        /// Burst frames to capture (action/walking shots); best frame picked in M6.
        var burst: Int?
        var steps: [StepRef]?
        var source: String?
    }

    /// Kept so code written for "rules" still reads naturally.
    typealias Rule = Suggestion

    var version: Int
    var suggestions: [Suggestion]
    var stepLibrary: [String: GuideStep]

    /// A suggestion's steps with library names filled in (unknown names are logged and skipped).
    func steps(for suggestion: Suggestion) -> [GuideStep] {
        (suggestion.steps ?? []).compactMap { ref in
            switch ref {
            case .inline(let step): return step
            case .named(let name):
                if let step = stepLibrary[name] { return step }
                Log.warn("Playbook: \(suggestion.id) uses unknown step \"\(name)\"")
                return nil
            }
        }
    }

    /// Startup check: shots with too many steps, and steps that contradict each other within
    /// one suggestion (two pitch steps that can't both pass; "phone level" while pointing
    /// straight down, where left/right tilt is meaningless). Shown in the debug overlay.
    static let validationWarnings: [String] = {
        var warnings: [String] = []
        let playbook = Playbook.shared
        let maxSteps = AppConfig.shared.guide.maxSteps
        for s in playbook.suggestions {
            let steps = playbook.steps(for: s)
            if steps.count > maxSteps { warnings.append("\(s.id): \(steps.count) steps (max \(maxSteps))") }
            // Same check type with tight bands that don't overlap = impossible to satisfy both.
            let banded = steps.filter { ["pitch", "eyeLevel", "headroom", "subjectSize"].contains($0.check.type) }
            for (i, a) in banded.enumerated() {
                for b in banded.dropFirst(i + 1) where a.check.type == b.check.type && a.check.measure == b.check.measure {
                    let lo = max(a.check.min ?? -.greatestFiniteMagnitude, b.check.min ?? -.greatestFiniteMagnitude)
                    let hi = min(a.check.max ?? .greatestFiniteMagnitude, b.check.max ?? .greatestFiniteMagnitude)
                    if lo > hi { warnings.append("\(s.id): \(a.id) conflicts with \(b.id)") }
                }
            }
            // "Level" (left/right tilt) can't be measured with the phone pointing straight down/up.
            if steps.contains(where: { $0.check.type == "level" }),
               let pitch = steps.first(where: { $0.check.type == "pitch" }),
               abs(pitch.check.min ?? 0) > 60 || abs(pitch.check.max ?? 0) > 60 {
                warnings.append("\(s.id): level step conflicts with \(pitch.id) (phone near flat)")
            }
        }
        for w in warnings { Log.warn("Playbook check: \(w)") }
        if warnings.isEmpty { Log.info("Playbook check: no conflicts") }
        return warnings
    }()

    static let shared: Playbook = {
        guard let url = Bundle.main.url(forResource: "playbook", withExtension: "json") else {
            LogStore.shared.writeNow("playbook.json is missing from the app bundle")
            fatalError("playbook.json is missing")
        }
        do {
            let playbook = try JSONDecoder().decode(Playbook.self, from: Data(contentsOf: url))
            Log.info("Playbook v\(playbook.version): \(playbook.suggestions.count) suggestions")
            return playbook
        } catch {
            LogStore.shared.writeNow("playbook.json can't be read: \(error)")
            fatalError("playbook.json can't be read: \(error)")
        }
    }()
}

/// A suggestion with its fit score for the current scene.
struct RankedSuggestion: Identifiable, Equatable {
    let suggestion: Playbook.Suggestion
    var score: Double
    var why: String
    var id: String { suggestion.id }

    static func == (a: RankedSuggestion, b: RankedSuggestion) -> Bool { a.id == b.id }
}

/// Ranks the suggestions that fit what's detected, best first (3–6 cards). Called ONCE per
/// lock by the stage machine; the cards are then frozen. Your picks are remembered (per card)
/// and rank higher next time.
final class SuggestionRanker {
    private let favourites = SuggestionFavourites()
    private let maxCards = 6

    func recordPick(_ id: String) {
        favourites.record(id)
    }

    func rank(category: SubjectCategory, tags: Set<String>) -> [RankedSuggestion] {
        var list: [RankedSuggestion] = []
        for s in Playbook.shared.suggestions where s.category == category {
            let when = s.when
            if let all = when?.all, !Set(all).isSubset(of: tags) { continue }
            if let any = when?.any, !any.isEmpty, Set(any).isDisjoint(with: tags) { continue }
            if let none = when?.none, !Set(none).isDisjoint(with: tags) { continue }
            let preferred = (s.prefer ?? []).filter { tags.contains($0) }
            let anyHits = (when?.any ?? []).filter { tags.contains($0) }
            let fav = favourites.boost(for: s.id)
            let score = (s.base ?? 0) + 3 * Double(preferred.count) + Double(anyHits.count) + fav
            var why = String(format: "%.1f", score)
            if !preferred.isEmpty { why += " · " + preferred.joined(separator: ", ") }
            if fav > 0 { why += " · ♥" }
            list.append(RankedSuggestion(suggestion: s, score: score, why: why))
        }
        list.sort { $0.score > $1.score }
        Log.info("Cards for \(category.title): " + list.prefix(maxCards).map { "\($0.id) \($0.why)" }.joined(separator: "; "))
        return Array(list.prefix(maxCards))
    }
    /// Turns the description into tags the playbook's "when"/"prefer" lists can use, e.g.
    /// people:2, prop:umbrella, light:backlit, time:evening, camera:front, framing:fullBody.
    static func sceneTags(description d: SceneDescription, analysis a: SceneAnalysis,
                          personTypes: Set<String>) -> Set<String> {
        var tags: Set<String> = []
        tags.insert(d.isFrontCamera ? "camera:front" : "camera:back")
        tags.insert("people:\(Playbook.peopleBucket(d.peopleCount))")
        if d.peopleCount >= 2 { tags.insert("people:2+") }
        for prop in d.props { tags.insert("prop:\(prop)") }
        for label in a.labels.prefix(5) { tags.insert("scene:\(label.label)") }
        if let framing = d.framing {
            switch framing {
            case .closeUp: tags.insert("framing:closeUp")
            case .halfBody: tags.insert("framing:halfBody")
            case .fullBody: tags.insert("framing:fullBody")
            }
        }
        if d.mirrorCue { tags.insert("mirror") }
        if d.isOutdoor { tags.insert("outdoors") } else { tags.insert("indoors") }
        if d.lighting.isBacklit { tags.insert("light:backlit") }
        if d.lighting.isHarsh { tags.insert("light:harsh") }
        tags.insert("light:\(d.lighting.level)")
        for type in personTypes { tags.insert("type:\(type)") }
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<10: tags.insert("time:morning")
        case 10..<17: tags.insert("time:day")
        case 17..<21: tags.insert("time:evening")
        default: tags.insert("time:night")
        }
        return tags
    }
}

extension Playbook {
    static func peopleBucket(_ count: Int) -> String {
        switch count {
        case ...1: return "1"
        case 2: return "2"
        case 3: return "3"
        default: return "4+"
        }
    }
}

/// How often you picked each suggestion (stored on the phone). Feeds ranking.
final class SuggestionFavourites {
    private let key = "suggestionPicks"
    private var picks: [String: Int]

    init() {
        picks = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    func record(_ id: String) {
        picks[id, default: 0] += 1
        UserDefaults.standard.set(picks, forKey: key)
    }

    /// Up to +3 for your most-used suggestions.
    func boost(for id: String) -> Double {
        min(3, Double(picks[id] ?? 0) * 0.5)
    }
}
