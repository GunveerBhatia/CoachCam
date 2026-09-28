import Foundation

/// Apparent person type, estimated on-device from the face. Used only to pick poses and
/// camera height (e.g. crouch to a kid's eye level). "person" when the model isn't sure.
/// You can correct it by tapping the label.
enum PersonType: String, CaseIterable, Codable, Identifiable {
    case kid
    case teen
    case man
    case woman
    case olderMan = "older man"
    case olderWoman = "older woman"
    case person

    var id: String { rawValue }

    /// The six types the model can pick from ("person" is the unsure fallback).
    static let estimable: [PersonType] = [.kid, .teen, .man, .woman, .olderMan, .olderWoman]

    /// Converts the model's output (11 numbers: male, female, then 9 age groups
    /// 0-2, 3-9, 10-19, 20-29, 30-39, 40-49, 50-59, 60-69, 70+) into a score per type.
    static func scores(fromModelOutput p: [Double]) -> [PersonType: Double] {
        guard p.count == 11 else { return [:] }
        let male = p[0], female = p[1]
        let age = Array(p[2...])
        let kid = age[0] + age[1]                    // 0–9
        let teen = age[2]                            // 10–19
        let adult = age[3] + age[4] + age[5] + age[6] // 20–59
        let older = age[7] + age[8]                  // 60+
        return [
            .kid: kid,
            .teen: teen,
            .man: adult * male,
            .woman: adult * female,
            .olderMan: older * male,
            .olderWoman: older * female
        ]
    }
}
