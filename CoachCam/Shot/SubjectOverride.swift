import Foundation

/// "Wrong subject?": lets you force the subject category when detection gets it wrong.
final class SubjectOverride: ObservableObject {
    /// The category you forced by hand, or nil to follow detection.
    @Published private(set) var category: SubjectCategory?

    /// The category in effect: yours if you forced one, otherwise detection's.
    func effective(detected: SubjectCategory) -> SubjectCategory {
        category ?? detected
    }

    func set(_ category: SubjectCategory?) {
        self.category = category
        Log.info(category.map { "Subject set by hand: \($0.title)" } ?? "Subject back to auto-detect")
    }
}
