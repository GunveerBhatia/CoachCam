import CoreGraphics
import Foundation

/// Decides the shooting mode from each analysis, without flickering.
///
/// - Automatic by default. Tapping the mode badge picks a mode by hand ("manual mode");
///   choosing "Auto" goes back to automatic.
/// - A new mode must win `switchTicks` analyses in a row before the badge changes
///   (`firstModeTicks` for the very first decision), which keeps it steady but fast.
///   At 12 analyses per second, 3 ticks is 0.25 s.
/// - Never uses gender, age or race; only counts, sizes, positions, objects and scene labels.
final class ModeEngine: ObservableObject {
    /// The mode in effect (automatic or chosen by hand).
    @Published private(set) var mode: ShootingMode = .general
    /// The mode you chose by hand, or nil when automatic.
    @Published private(set) var manualMode: ShootingMode?

    let subjects = SubjectTracker()
    /// Why the mode was chosen and how fast (debug overlay only; kept separate so the
    /// camera screen doesn't redraw 12 times a second).
    let diagnostics = ModeDiagnostics()

    private let config = AppConfig.shared.modes
    private var candidate: ShootingMode?
    private var candidateCount = 0
    private var candidateSince: TimeInterval = 0
    private var hasDecided = false

    var isAutomatic: Bool { manualMode == nil }

    // MARK: - Manual choice

    func choose(_ mode: ShootingMode?) {
        manualMode = mode
        if let mode {
            self.mode = mode
            Log.info("Mode chosen by hand: \(mode.title)")
        } else {
            Log.info("Mode back to automatic")
        }
        candidate = nil
    }

    // MARK: - Automatic

    /// Called on the main thread after each analysis.
    func ingest(_ analysis: SceneAnalysis, cameraPitch: Double) {
        subjects.update(with: analysis)
        let (proposal, reason) = classify(analysis, cameraPitch: cameraPitch)
        diagnostics.update(proposal: proposal, reason: reason, analysisMs: analysis.analysisMs)

        if let manualMode {
            if mode != manualMode { mode = manualMode }
            return
        }
        guard proposal != mode else {
            candidate = nil
            candidateCount = 0
            return
        }
        if proposal == candidate {
            candidateCount += 1
        } else {
            candidate = proposal
            candidateCount = 1
            candidateSince = analysis.timestamp
        }
        let needed = hasDecided ? config.switchTicks : config.firstModeTicks
        if candidateCount >= needed {
            // Latency = time from first seeing the new scene to switching, plus this analysis.
            let latencyMs = (analysis.timestamp - candidateSince) * 1000 + analysis.analysisMs
            Log.info("Mode → \(proposal.title) (\(reason)) in \(Int(latencyMs)) ms")
            mode = proposal
            hasDecided = true
            candidate = nil
            candidateCount = 0
            diagnostics.recordSwitch(latencyMs: latencyMs)
        }
    }

    /// The rules. Order matters: the first match wins.
    private func classify(_ a: SceneAnalysis, cameraPitch: Double) -> (ShootingMode, String) {
        if a.isFrontCamera { return (.frontSelfie, "front camera") }

        // Tapped an object → that object decides.
        if let s = subjects.subject, case .object(let label) = s.kind {
            if config.foodObjectLabels.contains(label) { return (.food, "tapped \(label)") }
            return (.object, "tapped \(label)")
        }

        let pointingDown = cameraPitch >= config.foodMinPitchDegrees
        let foodObject = a.objects.first { config.foodObjectLabels.contains($0.label) && $0.label != "dining table" }
        let foodLabel = a.labelConfidence(anyOf: config.foodSceneLabels)
        let hasFood = foodObject != nil || foodLabel >= config.foodMinLabelConfidence

        // People (a tapped person counts alone).
        var people = a.people
        if let locked = subjects.lockedPerson(in: a) { people = [locked] }
        if !people.isEmpty && !(pointingDown && hasFood) {
            if people.count >= 2 { return (.group, "\(people.count) people") }
            let person = people[0]
            if isMirrorShot(person, objects: a.objects) { return (.mirrorFit, "person holding phone facing camera") }
            if person.faceArea >= config.headshotMinFaceArea {
                return (.headshot, String(format: "face fills %.1f%%", person.faceArea * 100))
            }
            if person.fullBodyVisible && Double(person.box.height) >= config.fullBodyMinHeight {
                return (.soloFullBody, "head to feet visible")
            }
            if person.fullBodyVisible || !config.fullBodyNeedsAnkles {
                return (.soloFullBody, "body visible")
            }
            return (.headshot, "upper body")
        }

        if pointingDown && hasFood {
            let what = foodObject?.label ?? "food label"
            return (.food, String(format: "%@, pitch %.0f°", what, cameraPitch))
        }

        let building = a.labelConfidence(anyOf: config.buildingSceneLabels)
        if building >= config.buildingMinLabelConfidence {
            return (.building, String(format: "building %.0f%%", building * 100))
        }

        let sky = a.labelConfidence(anyOf: config.skySceneLabels)
        if sky >= config.skyMinLabelConfidence {
            return (.landscape, String(format: "sky/landscape %.0f%%", sky * 100))
        }

        // A clear, fairly central object with nobody in shot.
        let centre = CGPoint(x: 0.5, y: 0.5)
        if let object = a.objects.first(where: {
            Double($0.box.area) >= config.objectMinArea &&
            Double($0.box.center.distance(to: centre)) <= config.objectMaxCenterDistance
        }) {
            return (.object, "\(object.label) in centre")
        }

        return (.general, "nothing specific")
    }

    /// Mirror selfie: a phone sits on the person's body near their head, facing us.
    /// (A heuristic. Tap the badge if it gets it wrong.)
    private func isMirrorShot(_ person: PersonInfo, objects: [DetectedObject]) -> Bool {
        let head: CGPoint = person.faceBox?.center
            ?? person.joints["nose"]
            ?? CGPoint(x: person.box.midX, y: person.box.minY + person.box.height * 0.1)
        return objects.contains { object in
            object.label == "cell phone" &&
            Double(object.box.fractionInside(person.box)) >= config.mirrorPhoneMinOverlapWithPerson &&
            Double(object.box.center.distance(to: head)) <= config.mirrorPhoneMaxDistanceFromFace
        }
    }
}

/// Debug-only details about the mode decision.
final class ModeDiagnostics: ObservableObject {
    @Published private(set) var proposal: ShootingMode = .general
    @Published private(set) var reason = ""
    @Published private(set) var analysisMs: Double = 0
    @Published private(set) var lastSwitchLatencyMs: Double?

    func update(proposal: ShootingMode, reason: String, analysisMs: Double) {
        self.proposal = proposal
        self.reason = reason
        self.analysisMs = analysisMs
    }

    func recordSwitch(latencyMs: Double) {
        lastSwitchLatencyMs = latencyMs
    }
}
