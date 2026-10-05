import Foundation

/// What's in the frame, as decided by detection. Never chosen by the photo type.
/// Raw values are used in playbook.json and config.json.
enum SubjectCategory: String, CaseIterable, Identifiable, Codable {
    case people
    case building
    case food
    case sky
    case object
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: return "People"
        case .building: return "Building"
        case .food: return "Food"
        case .sky: return "Sky / landscape"
        case .object: return "Object"
        case .general: return "Scene"
        }
    }

    var icon: String {
        switch self {
        case .people: return "person.2"
        case .building: return "building.2"
        case .food: return "fork.knife"
        case .sky: return "sunset"
        case .object: return "cube"
        case .general: return "viewfinder"
        }
    }
}
