import CoreGraphics
import Foundation

/// A person-type label shown next to a face.
struct PersonLabel: Identifiable, Equatable {
    let id: Int              // tracking id (stable while the face stays in frame)
    var faceBox: CGRect      // upright coordinates
    var type: PersonType
    var confidence: Double
    var corrected: Bool      // you set it by hand
}

/// Follows faces across frames, smooths the model's guesses, and applies your corrections.
///
/// - A correction sticks to that person while they stay in frame (tracked by face overlap).
///   The app does NOT recognise faces, so it can't remember a specific person next time.
/// - Every correction is stored on the phone (PersonTypeCorrections) and gently re-weights
///   future guesses, e.g. if you keep changing "teen" to "man", "man" gets more likely.
/// - Below the confidence threshold the label is just "person".
final class PersonTypeTracker: ObservableObject {
    @Published private(set) var labels: [PersonLabel] = []

    let corrections = PersonTypeCorrections()
    private let config = AppConfig.shared.people

    private struct Track {
        var id: Int
        var faceBox: CGRect
        var scores: [PersonType: Double]?
        var lastSeen: TimeInterval
        var correction: PersonType?
    }
    private var tracks: [Track] = []
    private var nextID = 1

    /// Types present right now (for the playbook), e.g. ["kid", "woman"].
    var currentTypes: Set<String> {
        Set(labels.filter { $0.type != .person }.map { $0.type.rawValue })
    }

    /// Called on the main thread after each analysis.
    func update(with a: SceneAnalysis) {
        var seenIDs = Set<Int>()
        for person in a.people {
            guard let face = person.faceBox else { continue }
            let newScores = person.typeModelOutput.map { PersonType.scores(fromModelOutput: $0) }
            let match = tracks.indices
                .filter { !seenIDs.contains(tracks[$0].id) }
                .max { tracks[$0].faceBox.iou(face) < tracks[$1].faceBox.iou(face) }
            if let i = match, tracks[i].faceBox.iou(face) > 0.2 {
                tracks[i].faceBox = face
                tracks[i].lastSeen = a.timestamp
                if let new = newScores { tracks[i].scores = blend(tracks[i].scores, new) }
                seenIDs.insert(tracks[i].id)
            } else {
                let track = Track(id: nextID, faceBox: face, scores: newScores, lastSeen: a.timestamp, correction: nil)
                nextID += 1
                tracks.append(track)
                seenIDs.insert(track.id)
            }
        }
        tracks.removeAll { a.timestamp - $0.lastSeen > config.personTypeReleaseSeconds }
        let newLabels = tracks.filter { seenIDs.contains($0.id) }.map(resolve)
        if newLabels != labels { labels = newLabels }
    }

    /// You tapped a label and picked the right type.
    func correct(id: Int, to type: PersonType) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        let predicted = resolve(tracks[i]).type
        tracks[i].correction = type
        corrections.record(predicted: predicted, corrected: type)
        labels = labels.map { $0.id == id ? PersonLabel(id: id, faceBox: $0.faceBox, type: type, confidence: 1, corrected: true) : $0 }
        Log.info("Person type corrected: \(predicted.rawValue) → \(type.rawValue)")
    }

    private func blend(_ old: [PersonType: Double]?, _ new: [PersonType: Double]) -> [PersonType: Double] {
        guard let old else { return new }
        let alpha = config.personTypeSmoothing
        var out: [PersonType: Double] = [:]
        for type in PersonType.estimable {
            out[type] = (old[type] ?? 0) * (1 - alpha) + (new[type] ?? 0) * alpha
        }
        return out
    }

    private func resolve(_ track: Track) -> PersonLabel {
        if let fixed = track.correction {
            return PersonLabel(id: track.id, faceBox: track.faceBox, type: fixed, confidence: 1, corrected: true)
        }
        guard let scores = track.scores else {
            return PersonLabel(id: track.id, faceBox: track.faceBox, type: .person, confidence: 0, corrected: false)
        }
        // Re-weight by your past corrections, then normalise.
        var weighted: [PersonType: Double] = [:]
        for type in PersonType.estimable { weighted[type] = (scores[type] ?? 0) * corrections.bias(for: type) }
        let total = weighted.values.reduce(0, +)
        guard total > 0, let best = weighted.max(by: { $0.value < $1.value }) else {
            return PersonLabel(id: track.id, faceBox: track.faceBox, type: .person, confidence: 0, corrected: false)
        }
        let confidence = best.value / total
        let type = confidence >= config.personTypeMinConfidence ? best.key : .person
        return PersonLabel(id: track.id, faceBox: track.faceBox, type: type, confidence: confidence, corrected: false)
    }
}

/// Your corrections, stored only on this phone (Application Support/person-type-corrections.json).
final class PersonTypeCorrections: ObservableObject {
    struct Entry: Codable {
        var date: Date
        var predicted: PersonType
        var corrected: PersonType
    }

    @Published private(set) var entries: [Entry] = []
    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("person-type-corrections.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func record(predicted: PersonType, corrected: PersonType) {
        guard predicted != corrected else { return }
        entries.append(Entry(date: Date(), predicted: predicted, corrected: corrected))
        save()
    }

    func reset() {
        entries = []
        save()
        Log.info("Person-type corrections reset")
    }

    /// How much to favour a type: >1 if you often correct *to* it, <1 if you often correct *away*
    /// from it. Clamped to 0.5…2 so a few corrections can't override the model entirely.
    func bias(for type: PersonType) -> Double {
        let to = Double(entries.filter { $0.corrected == type }.count)
        let away = Double(entries.filter { $0.predicted == type }.count)
        return min(2, max(0.5, (1 + to * 0.25) / (1 + away * 0.25)))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: fileURL) }
    }
}
