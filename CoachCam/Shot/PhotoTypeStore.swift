import Foundation

/// Your photo-type choices, remembered per subject category (stored on the phone),
/// plus an optional manual subject category when detection gets it wrong.
final class PhotoTypeStore: ObservableObject {
    /// Last photo type chosen for each category.
    @Published private(set) var choices: [SubjectCategory: PhotoType] = [:]
    /// Subject category you forced by hand ("Wrong subject?"), or nil to follow detection.
    @Published private(set) var categoryOverride: SubjectCategory?

    private let defaultsKey = "photoTypeChoices"

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        for (categoryRaw, typeRaw) in saved {
            if let category = SubjectCategory(rawValue: categoryRaw), let type = PhotoType(rawValue: typeRaw) {
                choices[category] = type
            }
        }
    }

    /// The subject category in effect: yours if you forced one, otherwise detection's.
    func effectiveCategory(detected: SubjectCategory) -> SubjectCategory {
        categoryOverride ?? detected
    }

    /// Your remembered choice for this category, or nil if you haven't picked one yet.
    func choice(for category: SubjectCategory) -> PhotoType? {
        choices[category]
    }

    func choose(_ type: PhotoType) {
        choices[type.category] = type
        save()
        Log.info("Photo type: \(type.title) (for \(type.category.title))")
    }

    func overrideCategory(_ category: SubjectCategory?) {
        categoryOverride = category
        Log.info(category.map { "Subject set by hand: \($0.title)" } ?? "Subject back to auto-detect")
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value.rawValue) })
        UserDefaults.standard.set(raw, forKey: defaultsKey)
    }
}
