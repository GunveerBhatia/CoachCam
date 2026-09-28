import CoreImage
import CoreVideo

/// Shrinks camera frames before Vision/YOLO look at them. Detection doesn't need 12 MP;
/// smaller frames are much faster and cooler. Uses the GPU (Core Image) and reuses a pool
/// of output buffers, so there's no per-frame memory churn.
///
/// Replaces `deliversPreviewSizedOutputBuffers`, which crashed build 6.
final class FrameDownscaler {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var loggedSizes = false

    /// Returns `buffer` unchanged if its longest side is already ≤ `maxDimension`.
    func scaled(_ buffer: CVPixelBuffer, maxDimension: Int) -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let longest = max(width, height)
        guard maxDimension > 0, longest > maxDimension else {
            logSizesOnce(width, height, width, height)
            return buffer
        }
        let scale = CGFloat(maxDimension) / CGFloat(longest)
        let targetWidth = max(2, Int((CGFloat(width) * scale).rounded()) & ~1)    // even sizes
        let targetHeight = max(2, Int((CGFloat(height) * scale).rounded()) & ~1)

        if pool == nil || poolWidth != targetWidth || poolHeight != targetHeight {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &newPool)
            pool = newPool
            poolWidth = targetWidth
            poolHeight = targetHeight
        }

        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let output else {
            return buffer   // Fall back to the full-size frame rather than failing.
        }
        let image = CIImage(cvPixelBuffer: buffer).transformed(
            by: CGAffineTransform(scaleX: CGFloat(targetWidth) / CGFloat(width),
                                  y: CGFloat(targetHeight) / CGFloat(height)))
        context.render(image, to: output)
        logSizesOnce(width, height, targetWidth, targetHeight)
        return output
    }

    private func logSizesOnce(_ w: Int, _ h: Int, _ tw: Int, _ th: Int) {
        guard !loggedSizes else { return }
        loggedSizes = true
        Log.info("Analysis frames: camera \(w)x\(h) → Vision \(tw)x\(th)")
    }
}
