import Foundation

/// The coaching rules, loaded from Resources/playbook.json (built from docs/SPEC.md).
///
/// Each rule is keyed by subject category + optional photo type + optional match conditions
/// (people count, camera, props, person types). `bestRule(for:)` picks the exact match, or
/// the closest one when there's no exact entry, and says which.
struct Playbook: Decodable {
    struct Match: Decodable {
        /// "1", "2", "3", "4+" (omit = any)
        var people: String?
        /// "front" or "back" (omit = any)
        var camera: String?
        /// Every listed prop must be detected.
        var props: [String]?
        /// Any of these person types (kid, teen, man, woman, older man, older woman).
        var personTypes: [String]?
    }

    struct Lens: Decodable {
        var zoom: Double
        var fallbackZoom: Double?
        var note: String?
    }

    struct Camera: Decodable {
        var height: String
        var angle: String
        /// Phone pitch range in degrees (+ = pointing down, - = pointing up).
        var pitchMin: Double?
        var pitchMax: Double?
    }

    struct Framing: Decodable {
        var placement: String
        var headroom: String?
        var crop: String?
        var notes: [String]?
    }

    struct AutoSettings: Decodable {
        var exposure: String?      // "face", "sky", "subject", "balanced"
        var hdr: String?           // "auto", "on", "off"
        var lowLight: String?      // "merge", "quality", "off"
        var shutter: String?       // "fast", "normal"
        var whiteBalance: String?  // "auto", "skin", "warm"
        var depth: Bool?           // portrait-style depth data
    }

    struct Rule: Decodable, Identifiable {
        var id: String
        var category: SubjectCategory
        var photoType: PhotoType?
        var match: Match?
        var lens: Lens
        var camera: Camera
        var framing: Framing
        var lighting: [String]
        var pose: [String]?
        var autoSettings: AutoSettings
        var source: String?
    }

    var version: Int
    var rules: [Rule]
    var lighting: [LightingRule]

    /// Lighting coaching (M5), keyed by the lighting descriptors.
    struct LightingRule: Decodable, Identifiable {
        var id: String
        var when: String      // "harsh", "backlit", "sideDark", "dark"
        var appliesTo: [SubjectCategory]
        var steps: [String]
    }

    static let shared: Playbook = {
        guard let url = Bundle.main.url(forResource: "playbook", withExtension: "json") else {
            LogStore.shared.writeNow("playbook.json is missing from the app bundle")
            fatalError("playbook.json is missing")
        }
        do {
            let playbook = try JSONDecoder().decode(Playbook.self, from: Data(contentsOf: url))
            Log.info("Playbook v\(playbook.version): \(playbook.rules.count) rules")
            return playbook
        } catch {
            LogStore.shared.writeNow("playbook.json can't be read: \(error)")
            fatalError("playbook.json can't be read: \(error)")
        }
    }()

    // MARK: - Matching

    struct Query {
        var category: SubjectCategory
        var photoType: PhotoType?
        var peopleCount: Int
        var isFrontCamera: Bool
        var props: Set<String>
        var personTypes: Set<String>
    }

    struct Result {
        var rule: Rule
        /// True when every condition of the rule matched and the photo type matched exactly.
        var exact: Bool
        var score: Int
        /// Short explanation for the debug overlay.
        var why: String
    }

    static func peopleBucket(_ count: Int) -> String {
        switch count {
        case ...1: return "1"
        case 2: return "2"
        case 3: return "3"
        default: return "4+"
        }
    }

    private static func bucketIndex(_ bucket: String) -> Int {
        ["1", "2", "3", "4+"].firstIndex(of: bucket) ?? 0
    }

    /// The best rule for the situation. Rules for another category are never used, except
    /// the "general" rules as a last resort.
    func bestRule(for q: Query) -> Result? {
        var best: Result?
        for rule in rules {
            guard let result = score(rule, q) else { continue }
            if best == nil || result.score > best!.score { best = result }
        }
        return best
    }

    private func score(_ rule: Rule, _ q: Query) -> Result? {
        var score = 0
        var exact = true
        var notes: [String] = []

        if rule.category == q.category {
            score += 1000
        } else if rule.category == .general {
            exact = false
            notes.append("general fallback")
        } else {
            return nil
        }

        // Photo type: same > generic rule for the category > a different type.
        if let type = rule.photoType {
            if type == q.photoType {
                score += 100
            } else {
                score += 0
                exact = false
                notes.append("type \(type.title) instead")
            }
        } else {
            score += 10
            if q.photoType != nil { exact = false; notes.append("no rule for this type") }
        }

        if let m = rule.match {
            if let people = m.people, people != "any" {
                let wanted = Self.bucketIndex(people)
                let actual = Self.bucketIndex(Self.peopleBucket(q.peopleCount))
                if wanted == actual {
                    score += 20
                } else {
                    score -= 100 * abs(wanted - actual)
                    exact = false
                    notes.append("for \(people) people")
                }
            }
            if let camera = m.camera {
                if (camera == "front") == q.isFrontCamera {
                    score += 15
                } else {
                    score -= 30
                    exact = false
                    notes.append("for \(camera) camera")
                }
            }
            if let props = m.props, !props.isEmpty {
                let missing = props.filter { !q.props.contains($0) }
                if missing.isEmpty {
                    score += 10 * props.count
                } else {
                    score -= 50
                    exact = false
                    notes.append("needs \(missing.joined(separator: ", "))")
                }
            }
            if let types = m.personTypes, !types.isEmpty {
                if !q.personTypes.isDisjoint(with: types) {
                    score += 5 * types.count
                } else {
                    score -= 40
                    exact = false
                    notes.append("for \(types.joined(separator: "/"))")
                }
            }
        }

        let why = exact ? "exact" : "closest: " + notes.joined(separator: "; ")
        return Result(rule: rule, exact: exact, score: score, why: why)
    }
}

/// Keeps the current rule up to date (debug overlay now; coaching in M4+).
final class RulePlanner: ObservableObject {
    @Published private(set) var current: Playbook.Result?

    func update(category: SubjectCategory, photoType: PhotoType?, description d: SceneDescription,
                personTypes: Set<String>) {
        let query = Playbook.Query(category: category, photoType: photoType, peopleCount: d.peopleCount,
                                   isFrontCamera: d.isFrontCamera, props: Set(d.props), personTypes: personTypes)
        let result = Playbook.shared.bestRule(for: query)
        if result?.rule.id != current?.rule.id || result?.why != current?.why {
            current = result
            if let r = result { Log.info("Rule: \(r.rule.id) (\(r.why))") }
        }
    }
}
