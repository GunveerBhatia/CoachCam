import Foundation
import QuartzCore

/// The one place that decides what the camera screen shows. It commits to a decision and
/// only moves on clear events, so nothing flickers.
///
///   SEARCHING → LOCKED → GUIDING → READY → REVIEW
///
/// - SEARCHING → LOCKED: detection settles on a subject. The subject and the suggestion
///   cards are frozen; the best card is pre-selected and guiding auto-starts after ~1.5 s.
/// - LOCKED → GUIDING: auto-start, or you tap a card.
/// - GUIDING ⇄ READY: all steps latched / a step genuinely comes undone (>1 s, wide band).
/// - Back to SEARCHING only when: you cancel, the subject is lost for >2 s, or (LOCKED only)
///   you clearly turn to a new scene. Never on small hand movements.
final class StageMachine: ObservableObject {
    enum Stage: String {
        case searching = "SEARCHING", locked = "LOCKED", guiding = "GUIDING", ready = "READY", review = "REVIEW"
    }

    @Published private(set) var stage: Stage = .searching
    /// Suggestion cards, computed once at lock.
    @Published private(set) var cards: [RankedSuggestion] = []
    /// The suggestion being guided (or pre-selected while LOCKED).
    @Published private(set) var active: Playbook.Suggestion?
    @Published private(set) var lockedCategory: SubjectCategory = .general
    /// Recent stage changes with reasons (debug overlay).
    @Published private(set) var history: [String] = []

    let ranker = SuggestionRanker()
    private let config = AppConfig.shared.stages
    private var autoStartAt: TimeInterval?
    private var lastSeen: TimeInterval = 0
    private var tracksBox = false

    static let autoStartKey = "autoStartGuidance"
    private var autoStartEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoStartKey) as? Bool ?? true
    }

    // MARK: - Per-analysis update

    func update(category: SubjectCategory, description d: SceneDescription, analysis a: SceneAnalysis,
                tags: Set<String>, subjects: SubjectTracker, motion: MotionService, guide: StepGuide,
                context: () -> StepContext) {
        let now = CACurrentMediaTime()
        switch stage {
        case .searching:
            if category != .general {
                lock(category: category, analysis: a, tags: tags, subjects: subjects,
                     reason: "\(category.title): \(d.reason)", now: now)
            }

        case .locked, .guiding, .ready:
            // Is the locked subject still there?
            if tracksBox {
                if let s = subjects.subject { lastSeen = s.lastSeen } else { lastSeen = min(lastSeen, now - 999) }
            } else if d.proposed == lockedCategory || d.category == lockedCategory {
                lastSeen = now
            }
            if now - lastSeen > config.lostSubjectSeconds {
                reset(subjects: subjects, guide: guide, reason: "subject lost for >\(Int(config.lostSubjectSeconds))s")
                return
            }

            if stage == .locked {
                // A clearly new scene (big turn AND big picture change) unlocks, only while LOCKED.
                if motion.recentTurnDegrees > config.newSceneTurnDegrees && a.frameChange > config.newSceneFrameChange {
                    reset(subjects: subjects, guide: guide,
                          reason: String(format: "new scene (turned %.0f°, change %.2f)", motion.recentTurnDegrees, a.frameChange))
                    return
                }
                if let at = autoStartAt, now >= at, let s = active {
                    startGuiding(s, guide: guide, reason: "auto-start: \(s.title)")
                }
            } else {
                guide.update(context: context())
                if stage == .guiding && guide.allDone { go(.ready, "all steps done") }
                if stage == .ready && !guide.allDone { go(.guiding, "a step came undone (>1 s outside its wide band)") }
            }

        case .review:
            break
        }
    }

    // MARK: - Your actions

    func pick(_ suggestion: Playbook.Suggestion, guide: StepGuide) {
        ranker.recordPick(suggestion.id)
        startGuiding(suggestion, guide: guide, reason: "you picked \(suggestion.title)")
    }

    /// Stop guiding but keep the subject and cards.
    func cancelSuggestion(guide: StepGuide) {
        active = nil
        autoStartAt = nil
        guide.start(nil)
        go(.locked, "you cancelled the suggestion")
    }

    /// Unlock completely (✕ on the subject, camera flip, "Wrong subject?").
    func unlock(subjects: SubjectTracker, guide: StepGuide, reason: String) {
        reset(subjects: subjects, guide: guide, reason: reason)
    }

    /// You tapped a different person/object: lock onto it instead.
    func relock(to kind: SubjectTracker.Kind, box: CGRect, analysis a: SceneAnalysis, tags: Set<String>,
                subjects: SubjectTracker, guide: StepGuide) {
        guide.start(nil)
        let category: SubjectCategory
        switch kind {
        case .person: category = .people
        case .object(let label):
            category = AppConfig.shared.detection.foodObjectLabels.contains(label) ? .food : .object
        }
        subjects.lock(kind: kind, box: box, at: CACurrentMediaTime())
        tracksBox = true
        lockCards(category: category, tags: tags, now: CACurrentMediaTime())
        go(.locked, "you tapped a new subject")
    }

    /// Photo taken: show the review (M6), then come back here.
    func photoTaken(guide: StepGuide) {
        go(.review, "photo taken")
        // Until the Review screen exists (M6), return straight to LOCKED, keeping the cards.
        active = nil
        autoStartAt = nil
        guide.start(nil)
        go(.locked, "back from review")
    }

    // MARK: - Internals

    private func lock(category: SubjectCategory, analysis a: SceneAnalysis, tags: Set<String>,
                      subjects: SubjectTracker, reason: String, now: TimeInterval) {
        // Freeze the subject: a person or object box we keep tracking, or the scene itself.
        tracksBox = false
        if subjects.subject != nil {
            tracksBox = true   // You had already tapped something.
        } else if category == .people, let person = a.people.first {
            subjects.lock(kind: .person, box: person.box, at: a.timestamp)
            tracksBox = true
        } else if category == .object || category == .food,
                  let object = a.objects.max(by: { $0.box.area < $1.box.area }) {
            subjects.lock(kind: .object(label: object.label), box: object.box, at: a.timestamp)
            tracksBox = true
        }
        lastSeen = now
        lockCards(category: category, tags: tags, now: now)
        go(.locked, "locked on \(reason)")
    }

    private func lockCards(category: SubjectCategory, tags: Set<String>, now: TimeInterval) {
        lockedCategory = category
        cards = ranker.rank(category: category, tags: tags)
        active = cards.first?.suggestion   // Pre-selected (highlighted first card).
        autoStartAt = autoStartEnabled && active != nil ? now + config.autoStartDelaySeconds : nil
        lastSeen = now
    }

    private func startGuiding(_ suggestion: Playbook.Suggestion, guide: StepGuide, reason: String) {
        active = suggestion
        autoStartAt = nil
        guide.start(suggestion)
        go(.guiding, reason)
    }

    private func reset(subjects: SubjectTracker, guide: StepGuide, reason: String) {
        guide.start(nil)
        subjects.clear()
        active = nil
        cards = []
        autoStartAt = nil
        tracksBox = false
        lockedCategory = .general
        go(.searching, reason)
    }

    private func go(_ next: Stage, _ reason: String) {
        let previous = stage
        stage = next
        let time = Date().formatted(date: .omitted, time: .standard)
        let line = "\(time) \(previous.rawValue)→\(next.rawValue): \(reason)"
        history.append(line)
        if history.count > 4 { history.removeFirst(history.count - 4) }
        Log.info("Stage " + line)
    }
}
