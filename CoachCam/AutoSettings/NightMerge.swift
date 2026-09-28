import AVFoundation
import CoreImage
import ImageIO
import Vision

/// Our own "night mode" (Apple's Night mode isn't available to apps):
/// capture a burst of frames at the same auto exposure, line each one up with the first
/// (Vision image registration), and average them. Averaging N frames cuts noise by about √N.
extension CameraService {
    /// Takes `frames` photos as one bracket and saves the merged result.
    /// Falls back to a normal high-quality photo if bracketing isn't possible.
    func captureNightMerge(frames: Int, completion: @escaping (Bool) -> Void) {
        sessionQueue.async {
            guard self.session.isRunning,
                  let connection = self.photoOutput.connection(with: .video),
                  connection.isEnabled, connection.isActive else {
                Log.warn("Night merge ignored: camera not ready")
                DispatchQueue.main.async { completion(false) }
                return
            }
            let count = min(frames, self.photoOutput.maxBracketedCapturePhotoCount)
            let bgra = kCVPixelFormatType_32BGRA
            guard count >= 2, self.photoOutput.availablePhotoPixelFormatTypes.contains(bgra) else {
                Log.warn("Night merge not supported here; taking a normal photo")
                DispatchQueue.main.async {
                    self.capturePhoto(quality: .quality)
                    completion(false)
                }
                return
            }

            let bracket = (0..<count).map { _ in
                AVCaptureAutoExposureBracketedStillImageSettings.autoExposureSettings(exposureTargetBias: 0)
            }
            let settings = AVCapturePhotoBracketSettings(
                rawPixelFormatType: 0,
                processedFormat: [kCVPixelBufferPixelFormatTypeKey as String: bgra],
                bracketedSettings: bracket)
            if self.photoOutput.isLensStabilizationDuringBracketedCaptureSupported {
                settings.isLensStabilizationEnabled = true   // Steadier frames for longer exposures.
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions

            let id = settings.uniqueID
            let merger = NightMergeProcessor(expectedFrames: count, willCapture: { [weak self] in
                self?.flashShutter()
            }, completion: { [weak self] data in
                guard let self else { return }
                if let data {
                    self.handleCaptured(.success(data))
                    Log.info("Night merge saved (\(count) frames)")
                } else {
                    self.handleCaptured(.failure(NightMergeProcessor.MergeError.failed))
                }
                self.sessionQueue.async { self.inFlightCaptures[id] = nil }
                DispatchQueue.main.async { completion(data != nil) }
            })
            self.inFlightCaptures[id] = merger
            Log.info("Night merge: capturing \(count) frames")
            self.photoOutput.capturePhoto(with: settings, delegate: merger)
        }
    }
}

/// Receives the bracket frames one by one and merges them as they arrive, keeping only a
/// running average (not every 12 MP frame) in memory.
final class NightMergeProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    enum MergeError: LocalizedError {
        case failed
        var errorDescription: String? { "Night merge failed." }
    }

    private let expectedFrames: Int
    private let willCaptureHandler: () -> Void
    private let completion: (Data?) -> Void
    private let context = CIContext(options: [.workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue)])

    private var reference: CVPixelBuffer?
    private var accumulator: CIImageAccumulator?
    private var merged = 0
    private var exifOrientation: Int32 = 1
    private var metadata: [String: Any] = [:]
    private var flashed = false

    init(expectedFrames: Int, willCapture: @escaping () -> Void, completion: @escaping (Data?) -> Void) {
        self.expectedFrames = expectedFrames
        self.willCaptureHandler = willCapture
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if !flashed { flashed = true; willCaptureHandler() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let buffer = photo.pixelBuffer else {
            Log.warn("Night merge frame dropped: \(error?.localizedDescription ?? "no pixels")")
            return
        }
        let image = CIImage(cvPixelBuffer: buffer)

        guard let reference else {
            // First frame: the reference everything else is aligned to.
            self.reference = buffer
            metadata = photo.metadata
            if let orientation = photo.metadata[String(kCGImagePropertyOrientation)] as? NSNumber {
                exifOrientation = orientation.int32Value
            }
            let acc = CIImageAccumulator(extent: image.extent, format: .RGBAh)
            acc?.setImage(image)
            accumulator = acc
            merged = 1
            return
        }

        // Line this frame up with the reference (handheld shake is mostly a small shift).
        var aligned = image
        let registration = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: buffer)
        do {
            try VNImageRequestHandler(cvPixelBuffer: reference, options: [:]).perform([registration])
            if let observation = registration.results?.first as? VNImageTranslationAlignmentObservation {
                aligned = image.transformed(by: observation.alignmentTransform)
            }
        } catch {
            Log.warn("Night merge alignment failed: \(error.localizedDescription)")
        }

        // Running average: new = old × n/(n+1) + frame × 1/(n+1).
        guard let accumulator else { return }
        let n = CGFloat(merged)
        let old = Self.scaled(accumulator.image(), by: n / (n + 1))
        let add = Self.scaled(aligned.cropped(to: accumulator.extent), by: 1 / (n + 1))
        let sum = add.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: old])
        accumulator.setImage(sum.cropped(to: accumulator.extent))
        merged += 1
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        guard let accumulator, merged >= 1 else {
            completion(nil)
            return
        }
        Log.info("Night merge: averaged \(merged) of \(expectedFrames) frames")
        let final = accumulator.image().oriented(forExifOrientation: exifOrientation)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            completion(nil)
            return
        }
        let data = context.heifRepresentation(of: final, format: .RGBA8, colorSpace: colorSpace,
                                              options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9])
            ?? context.jpegRepresentation(of: final, colorSpace: colorSpace)
        reference = nil
        self.accumulator = nil
        completion(data)
    }

    /// Multiplies every channel (including alpha) by `factor`.
    private static func scaled(_ image: CIImage, by factor: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: factor)
        ])
    }
}
