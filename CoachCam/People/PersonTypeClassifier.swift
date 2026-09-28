import CoreML
import Vision

/// Runs the on-device person-type model (FairFace, gender + age group only; its race
/// outputs were removed before it was built into the app) on each face crop.
///
/// Runs on the analysis queue, only on slow ticks (~3×/s), for the largest few faces.
final class PersonTypeClassifier {
    private var model: VNCoreMLModel?
    private var attempted = false
    private(set) var status = "not loaded"

    private func loadIfNeeded() {
        guard !attempted else { return }
        attempted = true
        guard let url = Bundle.main.url(forResource: "PersonTypeModel", withExtension: "mlmodelc") else {
            status = "missing"
            Log.warn("Person-type model not in app; people will be labelled 'person'")
            return
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try VNCoreMLModel(for: MLModel(contentsOf: url, configuration: configuration))
            status = "ok"
            Log.info("Person-type model loaded")
        } catch {
            status = "error"
            Log.error("Person-type model failed to load: \(error.localizedDescription)")
        }
    }

    /// Returns the model's 11 outputs per face (same order as `faces`, nil where it failed).
    /// `faces` are upright boxes; `handler` is the frame's request handler (already oriented).
    func classify(faces: [CGRect], handler: VNImageRequestHandler) -> [[Double]?] {
        loadIfNeeded()
        guard let model else { return faces.map { _ in nil } }
        return faces.map { face in
            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            request.regionOfInterest = Self.visionCrop(around: face)
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            guard let array = (request.results as? [VNCoreMLFeatureValueObservation])?.first?.featureValue.multiArrayValue,
                  array.count == 11 else { return nil }
            return (0..<11).map { array[$0].doubleValue }
        }
    }

    /// A square around the face with some margin (FairFace was trained on loosely cropped
    /// faces), in Vision coordinates (bottom-left origin), clipped to the frame.
    static func visionCrop(around face: CGRect) -> CGRect {
        let side = max(face.width, face.height) * 1.6
        let upright = CGRect(x: face.midX - side / 2, y: face.midY - side / 2, width: side, height: side)
            .clampedToUnit
        // Upright (top-left origin) → Vision (bottom-left origin).
        return CGRect(x: upright.minX, y: 1 - upright.maxY, width: upright.width, height: upright.height)
    }
}
