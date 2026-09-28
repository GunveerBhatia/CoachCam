import CoreML
import Vision

/// Runs the on-device object detector and turns its raw output into labelled boxes.
///
/// The detector is YOLOE (open-vocabulary) built from Resources/vocabulary.json by the
/// build workflow; class index i = vocabulary word i. It falls back to YOLO11n (COCO)
/// if the YOLOE model isn't in the app.
///
/// Core ML exports come in a few shapes, so the decoder handles all of them:
/// - a Vision "object detection" pipeline → VNRecognizedObjectObservation (YOLO11n + NMS)
/// - end-to-end rows [1, N, 6(+32)]: x1, y1, x2, y2, score, class (+ mask coefficients)
/// - raw channels [1, 4 + classes (+32), anchors]: cx, cy, w, h, class scores → we run NMS
/// Mask outputs (segmentation) are ignored; only boxes are used.
final class ObjectDetector {
    private(set) var request: VNCoreMLRequest?
    private(set) var status = "not loaded"
    private var names: [String] = []
    private let inputSize: Float = 640
    private var loggedLayout = false

    /// Loads the model (call on the analysis queue).
    func load() {
        if let url = Bundle.main.url(forResource: "yoloe", withExtension: "mlmodelc") {
            names = Self.vocabulary()
            status = loadModel(url, name: "YOLOE \(names.count) words")
        } else if let url = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc") {
            status = loadModel(url, name: "YOLO11n (COCO)")
        } else {
            status = "missing"
            Log.error("No object detection model in the app bundle")
        }
    }

    private func loadModel(_ url: URL, name: String) -> String {
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let r = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
            r.imageCropAndScaleOption = .scaleFill
            request = r
            Log.info("Object detector loaded: \(name)")
            return name
        } catch {
            Log.error("Object model failed to load: \(error.localizedDescription)")
            return "error"
        }
    }

    static func vocabulary() -> [String] {
        guard let url = Bundle.main.url(forResource: "vocabulary", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let names = json["names"] as? [String] else {
            Log.error("vocabulary.json missing or unreadable")
            return []
        }
        return names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Reads the results of the last `request` run. Boxes are upright, top-left origin.
    func detections(minConfidence: Float) -> [(label: String, confidence: Float, box: CGRect)] {
        guard let results = request?.results else { return [] }

        // 1. Vision pipeline (already decoded + NMS).
        if let objects = results as? [VNRecognizedObjectObservation], !objects.isEmpty {
            return objects.compactMap { o in
                guard let top = o.labels.first, top.confidence >= minConfidence else { return nil }
                return (label: top.identifier, confidence: top.confidence, box: FrameGeometry.upright(fromVision: o.boundingBox))
            }
        }

        // 2. Raw tensors.
        let arrays = (results as? [VNCoreMLFeatureValueObservation] ?? []).compactMap { $0.featureValue.multiArrayValue }
        guard let output = arrays.first(where: { $0.shape.count == 3 }) else { return [] }
        let reader = TensorReader(output)
        let dimA = reader.shape[1], dimB = reader.shape[2]
        let classes = names.count
        var found: [(label: String, confidence: Float, box: CGRect)] = []

        if dimB == 6 || dimB == 38 || ((dimA == 6 || dimA == 38) && dimB > 38) {
            // End-to-end rows (YOLO26 style): already one box per object, no NMS needed.
            let rowsFirst = dimB == 6 || dimB == 38
            let rows = rowsFirst ? dimA : dimB
            logLayoutOnce("end-to-end \(reader.shape)")
            for i in 0..<rows {
                func v(_ k: Int) -> Float { rowsFirst ? reader.value(0, i, k) : reader.value(0, k, i) }
                let score = v(4)
                guard score >= minConfidence else { continue }
                let classIndex = Int(v(5).rounded())
                let box = CGRect(x: CGFloat(v(0) / inputSize), y: CGFloat(v(1) / inputSize),
                                 width: CGFloat((v(2) - v(0)) / inputSize), height: CGFloat((v(3) - v(1)) / inputSize))
                found.append((label: label(for: classIndex), confidence: score, box: box))
            }
            return found
        }

        // Raw YOLO head: [1, 4 + classes (+32 mask), anchors] or transposed.
        let channels = [4 + classes, 4 + classes + 32]
        let channelsFirst = channels.contains(dimA)
        guard channelsFirst || channels.contains(dimB) else {
            logLayoutOnce("UNKNOWN \(reader.shape) with \(classes) words")
            return []
        }
        let anchors = channelsFirst ? dimB : dimA
        logLayoutOnce("raw \(reader.shape)")
        func v(_ channel: Int, _ anchor: Int) -> Float {
            channelsFirst ? reader.value(0, channel, anchor) : reader.value(0, anchor, channel)
        }
        for a in 0..<anchors {
            var best: Float = 0
            var bestClass = 0
            for c in 0..<classes {
                let s = v(4 + c, a)
                if s > best { best = s; bestClass = c }
            }
            guard best >= minConfidence else { continue }
            let cx = v(0, a), cy = v(1, a), w = v(2, a), h = v(3, a)
            let box = CGRect(x: CGFloat((cx - w / 2) / inputSize), y: CGFloat((cy - h / 2) / inputSize),
                             width: CGFloat(w / inputSize), height: CGFloat(h / inputSize))
            found.append((label: label(for: bestClass), confidence: best, box: box))
        }
        return Self.nonMaxSuppression(found, iouThreshold: 0.5, limit: 50)
    }

    private func label(for index: Int) -> String {
        index >= 0 && index < names.count ? names[index] : "object \(index)"
    }

    private func logLayoutOnce(_ text: String) {
        guard !loggedLayout else { return }
        loggedLayout = true
        Log.info("Object model output layout: \(text)")
    }

    /// Keeps the best box and drops overlapping boxes of the same label.
    static func nonMaxSuppression(_ boxes: [(label: String, confidence: Float, box: CGRect)],
                                  iouThreshold: CGFloat, limit: Int) -> [(label: String, confidence: Float, box: CGRect)] {
        var kept: [(label: String, confidence: Float, box: CGRect)] = []
        for candidate in boxes.sorted(by: { $0.confidence > $1.confidence }) {
            if kept.contains(where: { $0.label == candidate.label && $0.box.iou(candidate.box) > iouThreshold }) { continue }
            kept.append(candidate)
            if kept.count >= limit { break }
        }
        return kept
    }
}

/// Fast element access for a 3-D MLMultiArray of Float32, Float16 or Double.
struct TensorReader {
    let shape: [Int]
    private let strides: [Int]
    private let read: (Int) -> Float

    init(_ array: MLMultiArray) {
        shape = array.shape.map(\.intValue)
        strides = array.strides.map(\.intValue)
        let pointer = array.dataPointer
        switch array.dataType {
        case .float16:
            let p = pointer.assumingMemoryBound(to: Float16.self)
            read = { Float(p[$0]) }
        case .double:
            let p = pointer.assumingMemoryBound(to: Double.self)
            read = { Float(p[$0]) }
        case .int32:
            let p = pointer.assumingMemoryBound(to: Int32.self)
            read = { Float(p[$0]) }
        default:
            let p = pointer.assumingMemoryBound(to: Float.self)
            read = { p[$0] }
        }
    }

    func value(_ i0: Int, _ i1: Int, _ i2: Int) -> Float {
        read(i0 * strides[0] + i1 * strides[1] + i2 * strides[2])
    }
}
