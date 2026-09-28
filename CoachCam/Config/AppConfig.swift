import Foundation

/// All tunable numbers, loaded from Resources/config.json.
/// Field names match the JSON keys exactly. Keys starting with "_" are comments and ignored.
struct AppConfig: Decodable {
    struct Analysis: Decodable {
        var fastHz: Double
        var slowEveryNthTick: Int
        var objectConfidence: Float
        var bodyJointConfidence: Float
        var classificationMinConfidence: Float
    }

    struct Modes: Decodable {
        var switchTicks: Int
        var firstModeTicks: Int
        var headshotMinFaceArea: Double
        var fullBodyNeedsAnkles: Bool
        var fullBodyMinHeight: Double
        var mirrorPhoneMaxDistanceFromFace: Double
        var mirrorPhoneMinOverlapWithPerson: Double
        var foodMinPitchDegrees: Double
        var foodMinLabelConfidence: Float
        var foodObjectLabels: [String]
        var foodSceneLabels: [String]
        var buildingMinLabelConfidence: Float
        var buildingSceneLabels: [String]
        var skyMinLabelConfidence: Float
        var skySceneLabels: [String]
        var objectMinArea: Double
        var objectMaxCenterDistance: Double
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
    var modes: Modes
    var subject: Subject
    var light: Light

    /// The loaded config. If config.json is missing or has a typo, the error goes to the
    /// debug log and the app stops with a clear message, rather than silently using wrong numbers.
    static let shared: AppConfig = {
        guard let url = Bundle.main.url(forResource: "config", withExtension: "json") else {
            Log.error("config.json is missing from the app bundle")
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
