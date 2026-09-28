import CoreGraphics
import Foundation

/// A name shown next to an object, like the person labels.
struct ObjectLabel: Identifiable, Equatable {
    enum Source: String {
        case you = "you"                // your correction
        case remembered = "remembered"  // fingerprint match with a past correction / AI answer
        case detector = "detector"      // live detector
        case classifier = "classifier"  // Apple's classifier on a crop
        case ai = "AI"                  // Claude, this time
    }

    let id: Int
    var box: CGRect          // upright coordinates
    var name: String
    var confidence: Float
    var source: Source
    var sure: Bool           // false → shown with "?"
    /// Other candidate names (for the correction menu).
    var alternatives: [String]

    var displayName: String { sure ? name : "\(name)?" }
}

/// Follows objects between frames and decides what to call each one. Never shows "object":
/// if nothing is confident it shows the best guess with "?".
///
/// Order of trust: your correction for this object → remembered name (fingerprint) → live
/// detector (confident) → Apple crop classifier (confident) → best guess with "?".
final class ObjectLabelTracker: ObservableObject {
    @Published private(set) var labels: [ObjectLabel] = []
    /// Name of the biggest object, for the subject picker (published only when it changes).
    @Published private(set) var mainName: String?

    private let config = AppConfig.shared.naming

    private struct Track {
        var id: Int
        var box: CGRect
        var detectorLabel: String
        var detectorConfidence: Float
        var cropLabel: String?
        var cropConfidence: Float = 0
        var remembered: ObjectMemory.Match?
        var assigned: (name: String, source: ObjectLabel.Source)?
        var lastSeen: TimeInterval
    }
    private var tracks: [Track] = []
    private var nextID = 1

    /// Called on the main thread after each analysis.
    func update(with a: SceneAnalysis) {
        var seen = Set<Int>()
        for object in a.objects {
            let match = tracks.indices
                .filter { !seen.contains(tracks[$0].id) }
                .max { tracks[$0].box.iou(object.box) < tracks[$1].box.iou(object.box) }
            let index: Int
            if let i = match, tracks[i].box.iou(object.box) > 0.3 {
                index = i
                tracks[i].box = object.box
                // Smooth the detector's confidence; take its label when it's the stronger reading.
                if object.label == tracks[i].detectorLabel {
                    tracks[i].detectorConfidence = tracks[i].detectorConfidence * 0.6 + object.confidence * 0.4
                } else if object.confidence > tracks[i].detectorConfidence {
                    tracks[i].detectorLabel = object.label
                    tracks[i].detectorConfidence = object.confidence
                }
            } else {
                tracks.append(Track(id: nextID, box: object.box, detectorLabel: object.label,
                                    detectorConfidence: object.confidence, lastSeen: a.timestamp))
                nextID += 1
                index = tracks.count - 1
            }
            tracks[index].lastSeen = a.timestamp
            if let crop = object.cropLabel {
                tracks[index].cropLabel = crop
                tracks[index].cropConfidence = object.cropConfidence
            }
            if let remembered = object.remembered { tracks[index].remembered = remembered }
            seen.insert(tracks[index].id)
        }
        tracks.removeAll { a.timestamp - $0.lastSeen > 1.5 }

        let visible = tracks.filter { seen.contains($0.id) }
            .sorted { $0.box.area > $1.box.area }
            .prefix(config.maxLabels)
            .map(resolve)
        let newLabels = Array(visible)
        if newLabels != labels { labels = newLabels }
        let main = newLabels.first?.displayName
        if main != mainName { mainName = main }
    }

    /// The object label at a point (upright coordinates), smallest first.
    func label(at point: CGPoint) -> ObjectLabel? {
        labels.filter { $0.box.contains(point) }.min { $0.box.area < $1.box.area }
    }

    /// You (or Claude, or Apple Look Up via you) named this object.
    func assign(id: Int, name: String, source: ObjectLabel.Source) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].assigned = (name, source)
        labels = labels.map { $0.id == id ? resolve(tracks[i]) : $0 }
        mainName = labels.first?.displayName
    }

    private func resolve(_ t: Track) -> ObjectLabel {
        var alternatives: [String] = []
        for name in [t.detectorLabel, t.cropLabel, t.remembered?.name].compactMap({ $0 })
            where !alternatives.contains(name) {
            alternatives.append(name)
        }

        func make(_ name: String, _ confidence: Float, _ source: ObjectLabel.Source, sure: Bool) -> ObjectLabel {
            ObjectLabel(id: t.id, box: t.box, name: name, confidence: confidence, source: source, sure: sure,
                        alternatives: alternatives)
        }

        if let assigned = t.assigned { return make(assigned.name, 1, assigned.source, sure: true) }
        if let remembered = t.remembered { return make(remembered.name, 0.9, .remembered, sure: true) }
        if t.detectorConfidence >= config.confidentShow {
            return make(t.detectorLabel, t.detectorConfidence, .detector, sure: true)
        }
        if t.cropConfidence >= config.cropConfident, let crop = t.cropLabel {
            return make(crop, t.cropConfidence, .classifier, sure: true)
        }
        // Medium: best guess with "?".
        if let crop = t.cropLabel, t.cropConfidence > t.detectorConfidence {
            return make(crop, t.cropConfidence, .classifier, sure: false)
        }
        return make(t.detectorLabel, t.detectorConfidence, .detector, sure: false)
    }
}
