import Foundation

/// All tunable numbers, loaded from Resources/config.json.
/// Field names match the JSON keys exactly. Keys starting with "_" are comments and ignored.
struct AppConfig: Decodable {
    struct Analysis: Decodable {
        var fastHz: Double
        var maxVisionDimension: Int
        var slowEveryNthTick: Int
        var objectConfidence: Float
        var bodyJointConfidence: Float
        var classificationMinConfidence: Float
    }

    struct Detection: Decodable {
        var categoryStableTicks: Int
        var categoryMinConfidence: Double
        var peopleMinFill: Double
        var closeUpMinFaceArea: Double
        var closeUpShouldersMinY: Double
        var fullBodyNeedsAnkles: Bool
        var mirrorPhoneMaxDistanceFromFace: Double
        var mirrorPhoneMinOverlapWithPerson: Double
        var foodMinLabelConfidence: Float
        var foodMinObjectArea: Double
        var foodObjectLabels: [String]
        var foodSceneLabels: [String]
        var buildingMinLabelConfidence: Float
        var buildingMinLensPosition: Double
        var buildingMaxCloseObjectArea: Double
        var buildingMinVerticalLines: Double
        var buildingSceneLabels: [String]
        var outdoorSceneLabels: [String]
        var skyMinLabelConfidence: Float
        var skyMinLensPosition: Double
        var skySceneLabels: [String]
        var objectMinArea: Double
        var objectMaxCenterDistance: Double
        var faceWidthMeters: Double
        var darkBelow: Double
        var brightAbove: Double
        var harshClippedHighlights: Double
        var backlitFaceRatio: Double
        var sideLightDifference: Double
    }

    struct Naming: Decodable {
        var detectorConfident: Float
        var cropClassifierMin: Float
        var cropConfident: Float
        var confidentShow: Float
        var mediumShow: Float
        var objectsPerSlowTick: Int
        var memoryMatchDistance: Float
        var maxLabels: Int
    }

    struct Auto: Decodable {
        var lensHoldSeconds: Double
        var lensMinIntervalSeconds: Double
        var headshotTooCloseFaceArea: Double
        var backlitBiasEV: Float
        var skyBiasEV: Float
        var exposureUpdateSeconds: Double
        var lowLightEnterISO: Float
        var lowLightExitISO: Float
        var lowLightEnterBrightness: Double
        var lowLightExitBrightness: Double
        var steadyShake: Double
        var steadyMaxExposureSeconds: Double
        var nightMergeISO: Float
        var nightMergeFrames: Int
        var fastShutterMotion: Double
        var fastShutterSeconds: Double
        var castThreshold: Double
        var castCorrectionKelvin: Float
        var castCorrectionTint: Float
        var sunsetKelvin: Float
    }

    struct People: Decodable {
        var personTypeMinConfidence: Double
        var personTypeSmoothing: Double
        var personTypeReleaseSeconds: Double
    }

    struct AI: Decodable {
        var model: String
        var identifyBelowConfidence: Float
        var maxImageDimension: Double
        var timeoutSeconds: Double
    }

    struct Subject: Decodable {
        var minOverlapToFollow: Double
        var releaseAfterSeconds: Double
    }

    struct Light: Decodable {
        var clippedHighlightLuma: Double
        var clippedShadowLuma: Double
    }

    var analysis: Analysis
    var detection: Detection
    var naming: Naming
    var auto: Auto
    var people: People
    var ai: AI
    var subject: Subject
    var light: Light

    /// The loaded config. If config.json is missing or has a typo, the error goes to the
    /// debug log and the app stops with a clear message, rather than silently using wrong numbers.
    static let shared: AppConfig = {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json") else {
            LogStore.shared.writeNow("config.json is missing from the app bundle")
            fatalError("config.json is missing")
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            LogStore.shared.writeNow("config.json can't be read: \(error)")
            fatalError("config.json can't be read: \(error)")
        }
    }()
}
