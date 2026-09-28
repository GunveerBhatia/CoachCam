import ImageIO
import Photos
import UIKit

/// Saving to the Photos app.
///
/// Permission flow:
/// 1. First shutter press: `requestAddAccess()` runs on the main thread, and iOS shows
///    "Allow Coach Cam to add to your Photos?".
/// 2. After that, `save()` only checks the status; it never asks.
/// 3. If you said no, the camera screen shows a banner with an "Open Settings" button.
enum PhotoLibrary {
    enum SaveError: LocalizedError {
        case notAllowed(PHAuthorizationStatus)
        var errorDescription: String? {
            switch self {
            case .notAllowed(let status): return "Photos access is \(PhotoLibrary.name(of: status))."
            }
        }
    }

    /// Current "add photos" permission.
    static var addStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static var canSave: Bool {
        addStatus == .authorized || addStatus == .limited
    }

    /// Shows the iOS permission pop-up if you haven't answered it yet, and returns the answer.
    /// Must run on the main thread: iOS may ignore requests made from background threads.
    @MainActor
    static func requestAddAccess() async -> PHAuthorizationStatus {
        let before = addStatus
        guard before == .notDetermined else { return before }
        Log.info("Asking for Photos permission")
        let after = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        Log.info("Photos permission: \(name(of: before)) → \(name(of: after))")
        return after
    }

    /// Saves the photo exactly as the camera produced it (HEIC with all its metadata).
    static func save(_ data: Data) async throws {
        let status = addStatus
        guard status == .authorized || status == .limited else { throw SaveError.notAllowed(status) }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    static func name(of status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not asked yet"
        case .restricted: return "restricted (Screen Time / device management)"
        case .denied: return "denied"
        case .authorized: return "allowed"
        case .limited: return "limited"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    /// A small, correctly rotated preview image for the thumbnail button.
    static func thumbnail(from data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
