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

/// The kind of photo you want. Always your choice (the picker on the camera screen).
/// Raw values are used in playbook.json.
enum PhotoType: String, CaseIterable, Identifiable, Codable {
    // People
    case headshot, portrait, casual, street, fullBody, mirrorFit, pro
    // Buildings
    case fullFacade, details, lowAngle
    // Food
    case overhead, fortyFive, foodCloseUp
    // Sky / landscape
    case wideScene, sunsetSilhouette, zoomedSun
    // Objects
    case product, objectCloseUp, flatLay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .headshot: return "Headshot"
        case .portrait: return "Portrait"
        case .casual: return "Casual"
        case .street: return "Street"
        case .fullBody: return "Full body"
        case .mirrorFit: return "Mirror fit"
        case .pro: return "Pro"
        case .fullFacade: return "Full facade"
        case .details: return "Details"
        case .lowAngle: return "Dramatic low angle"
        case .overhead: return "Overhead"
        case .fortyFive: return "45°"
        case .foodCloseUp: return "Close-up"
        case .wideScene: return "Wide scene"
        case .sunsetSilhouette: return "Sunset silhouette"
        case .zoomedSun: return "Zoomed-in sun"
        case .product: return "Product"
        case .objectCloseUp: return "Close-up"
        case .flatLay: return "Flat lay"
        }
    }

    var category: SubjectCategory {
        switch self {
        case .headshot, .portrait, .casual, .street, .fullBody, .mirrorFit, .pro: return .people
        case .fullFacade, .details, .lowAngle: return .building
        case .overhead, .fortyFive, .foodCloseUp: return .food
        case .wideScene, .sunsetSilhouette, .zoomedSun: return .sky
        case .product, .objectCloseUp, .flatLay: return .object
        }
    }

    static func types(for category: SubjectCategory) -> [PhotoType] {
        allCases.filter { $0.category == category }
    }
}
