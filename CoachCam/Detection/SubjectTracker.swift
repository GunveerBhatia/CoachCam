import CoreGraphics
import Foundation

/// Tap-to-select: remembers the person or object you tapped and follows it from frame to
/// frame by box overlap. Lets go if it disappears for a while (see config.json → subject).
final class SubjectTracker: ObservableObject {
    enum Kind: Equatable {
        case person
        case object(label: String)
    }

    struct Subject: Equatable {
        var kind: Kind
        var box: CGRect
        var lastSeen: TimeInterval
    }

    /// The locked subject, or nil (automatic).
    @Published private(set) var subject: Subject?

    private let config = AppConfig.shared.subject

    /// Selects whatever is under `point` (upright coordinates). Tapping empty space clears it.
    /// Returns a short description for the log.
    @discardableResult
    func select(at point: CGPoint, in analysis: SceneAnalysis) -> String {
        // Prefer the smallest thing under the finger (a cup in someone's hand beats the person).
        var candidates: [(Kind, CGRect)] = []
        for person in analysis.people where person.box.contains(point) { candidates.append((.person, person.box)) }
        for object in analysis.objects where object.box.contains(point) {
            candidates.append((.object(label: object.label), object.box))
        }
        guard let best = candidates.min(by: { $0.1.area < $1.1.area }) else {
            subject = nil
            return "nothing there, subject cleared"
        }
        subject = Subject(kind: best.0, box: best.1, lastSeen: analysis.timestamp)
        switch best.0 {
        case .person: return "person"
        case .object(let label): return label
        }
    }

    func clear() { subject = nil }

    /// Locks onto a subject chosen by the stage machine (the main person/object at lock time).
    func lock(kind: Kind, box: CGRect, at time: TimeInterval) {
        subject = Subject(kind: kind, box: box, lastSeen: time)
    }

    /// Follows the subject into the new analysis.
    func update(with analysis: SceneAnalysis) {
        guard var current = subject else { return }
        let boxes: [CGRect]
        switch current.kind {
        case .person: boxes = analysis.people.map(\.box)
        case .object(let label): boxes = analysis.objects.filter { $0.label == label }.map(\.box)
        }
        if let match = boxes.max(by: { $0.iou(current.box) < $1.iou(current.box) }),
           Double(match.iou(current.box)) >= config.minOverlapToFollow {
            current.box = match
            current.lastSeen = analysis.timestamp
            subject = current
        } else if analysis.timestamp - current.lastSeen > config.releaseAfterSeconds {
            Log.info("Subject lost, back to automatic")
            subject = nil
        }
    }

    /// The person in `analysis` that is the locked subject, if the subject is a person.
    func lockedPerson(in analysis: SceneAnalysis) -> PersonInfo? {
        guard let s = subject, s.kind == .person else { return nil }
        return analysis.people.max { $0.box.iou(s.box) < $1.box.iou(s.box) }
    }
}
