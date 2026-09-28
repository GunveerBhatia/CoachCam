import Foundation

/// What kind of photo you're taking. Shown as the badge at the top left.
enum ShootingMode: String, CaseIterable, Identifiable {
    case general
    case mirrorFit
    case frontSelfie
    case headshot
    case soloFullBody
    case group
    case friendShootsMe
    case building
    case food
    case landscape
    case object

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "Scene"
        case .mirrorFit: return "Mirror fit"
        case .frontSelfie: return "Selfie"
        case .headshot: return "Headshot"
        case .soloFullBody: return "Full body"
        case .group: return "Duo / Group"
        case .friendShootsMe: return "Friend shoots me"
        case .building: return "Building"
        case .food: return "Food"
        case .landscape: return "Sunset / Landscape"
        case .object: return "Object"
        }
    }

    /// SF Symbol for the badge.
    var icon: String {
        switch self {
        case .general: return "viewfinder"
        case .mirrorFit: return "rectangle.portrait.and.arrow.forward"
        case .frontSelfie: return "person.crop.circle"
        case .headshot: return "person.crop.square"
        case .soloFullBody: return "figure.stand"
        case .group: return "person.3"
        case .friendShootsMe: return "hand.raised"
        case .building: return "building.2"
        case .food: return "fork.knife"
        case .landscape: return "sunset"
        case .object: return "cube"
        }
    }

    /// Modes that can only be chosen by hand (never auto-detected).
    var isManualOnly: Bool { self == .friendShootsMe }
}
