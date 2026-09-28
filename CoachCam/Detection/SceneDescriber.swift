import CoreGraphics
import Foundation

/// Turns each raw analysis into a SceneDescription, and keeps the subject category steady.
///
/// - The category only changes after the same new category has been proposed
///   `categoryStableTicks` times in a row (5 ticks ≈ 0.4 s at 12/s).
/// - Scene labels alone are never trusted: e.g. "building" also needs distance (focus far,
///   not macro, no big object right in front of the lens) and strong vertical lines.
/// - Never guesses anything about people beyond counts, sizes and positions here
///   (person types come from their own model in a later step).
final class SceneDescriber: ObservableObject {
    /// The stable category (drives the photo-type picker). Published only when it changes.
    @Published private(set) var category: SubjectCategory = .general
    /// Whether the scene has a mirror-selfie cue (used to offer "Mirror fit"). Published on change.
    @Published private(set) var mirrorCue = false

    let subjects = SubjectTracker()
    /// Full per-tick description (debug overlay only; kept separate so the camera screen
    /// doesn't redraw 12 times a second).
    let live = LiveDescription()

    private let config = AppConfig.shared.detection
    private var candidate: SubjectCategory?
    private var candidateCount = 0
    private var candidateSince: TimeInterval = 0
    private var hasDecided = false

    /// Called on the main thread after each analysis. Returns the full description.
    @discardableResult
    func ingest(_ a: SceneAnalysis, cameraPitch: Double, levelError: Double) -> SceneDescription {
        subjects.update(with: a)

        var d = SceneDescription()
        d.isFrontCamera = a.isFrontCamera
        d.cameraPitch = cameraPitch
        d.levelError = levelError
        d.lensPosition = a.lensPosition
        d.isMacro = a.isMacro
        d.peopleCount = a.people.count
        d.props = Array(Set(a.objects.map(\.label))).sorted()
        d.background = a.labels.prefix(3).map { $0.label }
        d.isOutdoor = a.labelConfidence(anyOf: config.outdoorSceneLabels) >= 0.2

        let mainPerson = subjects.lockedPerson(in: a) ?? a.people.first
        if let person = mainPerson {
            d.framing = framing(of: person)
            d.mirrorCue = isMirrorCue(person, objects: a.objects)
            d.personDistance = distance(to: person, analysis: a)
        }
        d.lighting = lighting(a)

        let (proposal, reason, checks) = propose(a, mainPerson: mainPerson)
        d.proposed = proposal
        d.reason = reason
        d.checks = checks

        updateStableCategory(proposal: proposal, reason: reason, at: a.timestamp, analysisMs: a.analysisMs)
        d.category = category
        if mirrorCue != d.mirrorCue { mirrorCue = d.mirrorCue }
        live.update(d)
        return d
    }

    // MARK: - Category

    private func updateStableCategory(proposal: SubjectCategory, reason: String, at time: TimeInterval,
                                      analysisMs: Double) {
        guard proposal != category else {
            candidate = nil
            candidateCount = 0
            return
        }
        if proposal == candidate {
            candidateCount += 1
        } else {
            candidate = proposal
            candidateCount = 1
            candidateSince = time
        }
        let needed = hasDecided ? config.categoryStableTicks : max(2, config.categoryStableTicks / 2)
        guard candidateCount >= needed else { return }
        let latencyMs = (time - candidateSince) * 1000 + analysisMs
        Log.info("Subject → \(proposal.title) (\(reason)) in \(Int(latencyMs)) ms")
        category = proposal
        hasDecided = true
        candidate = nil
        candidateCount = 0
        live.recordSwitch(latencyMs: latencyMs)
    }

    /// The rules for this single tick. Order matters: the first match wins.
    private func propose(_ a: SceneAnalysis, mainPerson: PersonInfo?) -> (SubjectCategory, String, [String]) {
        var checks: [String] = []

        // A tapped subject decides.
        if let s = subjects.subject {
            switch s.kind {
            case .person: return (.people, "tapped person", checks)
            case .object(let label):
                if config.foodObjectLabels.contains(label) { return (.food, "tapped \(label)", checks) }
                return (.object, "tapped \(label)", checks)
            }
        }

        // People: a visible face, or a person big enough to be the subject.
        if a.isFrontCamera && !a.people.isEmpty { return (.people, "front camera, face", checks) }
        if let person = mainPerson, person.faceBox != nil || person.fillFraction >= config.peopleMinFill {
            return (.people, "\(a.people.count) \(a.people.count == 1 ? "person" : "people")", checks)
        }

        // Food: a confident food object of decent size, or a strong food label.
        let minObjectConfidence = Float(config.categoryMinConfidence)
        if let food = a.objects.first(where: {
            config.foodObjectLabels.contains($0.label) && $0.confidence >= minObjectConfidence
                && Double($0.box.area) >= config.foodMinObjectArea
        }) {
            return (.food, "\(food.label) \(Int(food.confidence * 100))%", checks)
        }
        let foodLabel = a.labelConfidence(anyOf: config.foodSceneLabels)
        if foodLabel >= config.foodMinLabelConfidence {
            return (.food, "food label \(Int(foodLabel * 100))%", checks)
        }

        // Distance facts shared by building and sky.
        let lens = a.lensPosition
        let lensText = lens.map { String(format: "%.2f", $0) } ?? "?"
        let largestObject = a.objects.map { Double($0.box.area) }.max() ?? 0

        // Building: label + far + no close object + vertical lines (+ outdoors helps).
        let building = a.labelConfidence(anyOf: config.buildingSceneLabels)
        if building >= config.buildingMinLabelConfidence {
            let far = (lens ?? 0) >= config.buildingMinLensPosition && !a.isMacro
            let clear = largestObject <= config.buildingMaxCloseObjectArea
            let lines = a.verticalLines >= config.buildingMinVerticalLines
            checks.append("\(far ? "✓" : "✗") far (focus \(lensText)\(a.isMacro ? ", macro" : ""))")
            checks.append("\(clear ? "✓" : "✗") no close object (\(Int(largestObject * 100))%)")
            checks.append("\(lines ? "✓" : "✗") vertical lines \(String(format: "%.1f%%", a.verticalLines * 100))")
            let outdoor = a.labelConfidence(anyOf: config.outdoorSceneLabels) >= 0.2
            checks.append("\(outdoor ? "✓" : "·") outdoors")
            if far && clear && lines {
                return (.building, "building \(Int(building * 100))%", checks)
            }
        }

        // Sky / landscape: label + far.
        let sky = a.labelConfidence(anyOf: config.skySceneLabels)
        if sky >= config.skyMinLabelConfidence {
            let far = (lens ?? 0) >= config.skyMinLensPosition && !a.isMacro
            checks.append("\(far ? "✓" : "✗") sky far (focus \(lensText))")
            if far { return (.sky, "sky/landscape \(Int(sky * 100))%", checks) }
        }

        // A clear, fairly central, confidently detected object.
        let centre = CGPoint(x: 0.5, y: 0.5)
        if let object = a.objects.first(where: {
            $0.confidence >= minObjectConfidence &&
            Double($0.box.area) >= config.objectMinArea &&
            Double($0.box.center.distance(to: centre)) <= config.objectMaxCenterDistance
        }) {
            return (.object, "\(object.label) \(Int(object.confidence * 100))% in centre", checks)
        }
        if a.isMacro { return (.object, "macro close-up", checks) }

        return (.general, "nothing specific", checks)
    }

    // MARK: - People

    /// Close-up only when the face is big AND the shoulders sit at (or below) the bottom edge.
    private func framing(of person: PersonInfo) -> PersonFraming {
        let shoulderYs = [person.joints["leftShoulder"], person.joints["rightShoulder"]].compactMap { $0?.y }
        let shouldersLow = shoulderYs.isEmpty || Double(shoulderYs.max()!) >= config.closeUpShouldersMinY
        if person.faceArea >= config.closeUpMinFaceArea && shouldersLow { return .closeUp }
        if person.fullBodyVisible || !config.fullBodyNeedsAnkles && person.joints["leftKnee"] != nil {
            return .fullBody
        }
        return .halfBody
    }

    /// A phone on the person's body near their head, facing us.
    private func isMirrorCue(_ person: PersonInfo, objects: [DetectedObject]) -> Bool {
        let head: CGPoint = person.faceBox?.center
            ?? person.joints["nose"]
            ?? CGPoint(x: person.box.midX, y: person.box.minY + person.box.height * 0.1)
        return objects.contains { object in
            object.label == "cell phone" &&
            Double(object.box.fractionInside(person.box)) >= config.mirrorPhoneMinOverlapWithPerson &&
            Double(object.box.center.distance(to: head)) <= config.mirrorPhoneMaxDistanceFromFace
        }
    }

    /// Distance from the face's size and the lens's field of view.
    private func distance(to person: PersonInfo, analysis a: SceneAnalysis) -> Double? {
        guard let face = person.faceBox, face.width > 0, let hFOV = a.horizontalFOV else { return nil }
        // The frame is 4:3. Upright x runs along the sensor's short side when the phone is upright.
        let sideways = a.rotationAngle == 90 || a.rotationAngle == 270
        let fovX = sideways ? 2 * atan(tan(hFOV / 2) * 3 / 4) : hFOV
        let angular = Double(face.width) * fovX
        guard angular > 0 else { return nil }
        return config.faceWidthMeters / (2 * tan(angular / 2))
    }

    // MARK: - Light

    private func lighting(_ a: SceneAnalysis) -> LightingDescription {
        var l = LightingDescription()
        let light = a.light
        if light.mean < config.darkBelow { l.level = "dark" } else if light.mean > config.brightAbove { l.level = "bright" }
        l.isHarsh = light.clippedHighlights >= config.harshClippedHighlights
        if let face = light.faceMean, light.mean > 0.05 {
            l.isBacklit = face / light.mean < config.backlitFaceRatio
            if l.isBacklit {
                l.direction = "behind"
            } else if let halves = light.faceLeftRight {
                let difference = halves.0 - halves.1
                if difference >= config.sideLightDifference { l.direction = "from picture-left" }
                if -difference >= config.sideLightDifference { l.direction = "from picture-right" }
            }
        }
        return l
    }
}

/// The latest full description, for the debug overlay.
final class LiveDescription: ObservableObject {
    @Published private(set) var description = SceneDescription()
    @Published private(set) var lastSwitchLatencyMs: Double?

    func update(_ d: SceneDescription) { description = d }
    func recordSwitch(latencyMs: Double) { lastSwitchLatencyMs = latencyMs }
}
