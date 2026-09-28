import AVFoundation

/// Handles AVFoundation's callbacks for a single photo.
/// AVFoundation holds this delegate only weakly, so CameraService keeps it alive
/// until the capture finishes.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let willCapture: () -> Void
    private let completion: (Result<Data, Error>) -> Void
    private var photoData: Data?
    private var captureError: Error?

    init(willCapture: @escaping () -> Void, completion: @escaping (Result<Data, Error>) -> Void) {
        self.willCapture = willCapture
        self.completion = completion
    }

    /// The shutter is about to fire: good moment for the screen flash.
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        willCapture()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            captureError = error
            return
        }
        photoData = photo.fileDataRepresentation()
    }

    /// Called last, whether or not it worked.
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        if let data = photoData {
            completion(.success(data))
        } else {
            completion(.failure(error ?? captureError ?? CaptureError.noData))
        }
    }

    enum CaptureError: LocalizedError {
        case noData
        var errorDescription: String? { "The camera returned no image data." }
    }
}
