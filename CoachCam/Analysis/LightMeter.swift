import CoreVideo
import Foundation

/// Measures light straight from the camera's pixel buffer (YCbCr 4:2:0, "420f").
/// Only samples a sparse grid of pixels, so it takes well under a millisecond.
final class LightMeter {
    /// A tiny brightness thumbnail of the previous frame, for motion detection.
    private var previousGrid: [UInt8] = []
    private let gridWidth = 32
    private let gridHeight = 24

    struct Result {
        var light: LightInfo
        var frameChange: Double
        var verticalLines: Double = 0
    }

    // Edge grid for the vertical-lines measure.
    private let edgeWidth = 96
    private let edgeHeight = 72

    /// `faceBox` is in upright coordinates; `geometry` converts it to the sensor buffer.
    func measure(_ pixelBuffer: CVPixelBuffer, faceBox: CGRect?, geometry: FrameGeometry,
                 config: AppConfig.Light) -> Result {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        var light = LightInfo()
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) else {
            return Result(light: light, frameChange: 0)
        }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let cRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
        let cPlane = cBase.assumingMemoryBound(to: UInt8.self)

        /// Brightness 0–255 at a normalized sensor point.
        func luma(atSensor p: CGPoint) -> UInt8 {
            let x = min(width - 1, max(0, Int(p.x * CGFloat(width))))
            let y = min(height - 1, max(0, Int(p.y * CGFloat(height))))
            return yPlane[y * yRowBytes + x]
        }

        // 1. Whole frame: brightness, clipping, colour cast, and the motion grid.
        let highCut = UInt8(min(255, config.clippedHighlightLuma * 255))
        let lowCut = UInt8(max(0, config.clippedShadowLuma * 255))
        var total = 0, count = 0, high = 0, low = 0
        var cbTotal = 0, crTotal = 0, chromaCount = 0
        var grid = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            for gx in 0..<gridWidth {
                let x = (gx * width) / gridWidth + width / (gridWidth * 2)
                let y = (gy * height) / gridHeight + height / (gridHeight * 2)
                let v = yPlane[y * yRowBytes + x]
                grid[gy * gridWidth + gx] = v
                total += Int(v); count += 1
                if v >= highCut { high += 1 }
                if v <= lowCut { low += 1 }
                // Chroma plane is half resolution; Cb and Cr alternate.
                let cOffset = (y / 2) * cRowBytes + (x / 2) * 2
                cbTotal += Int(cPlane[cOffset]); crTotal += Int(cPlane[cOffset + 1])
                chromaCount += 1
            }
        }
        light.mean = Double(total) / Double(max(count, 1)) / 255
        light.clippedHighlights = Double(high) / Double(max(count, 1))
        light.clippedShadows = Double(low) / Double(max(count, 1))
        light.colorCastBlue = (Double(cbTotal) / Double(max(chromaCount, 1)) - 128) / 128
        light.colorCastRed = (Double(crTotal) / Double(max(chromaCount, 1)) - 128) / 128

        // 2. Face: overall brightness and left vs right half (as seen in the photo).
        if let face = faceBox, face.width > 0.01, face.height > 0.01 {
            var left = 0, right = 0, leftN = 0, rightN = 0
            let steps = 10
            for iy in 0..<steps {
                for ix in 0..<steps {
                    let u = CGPoint(x: face.minX + face.width * (CGFloat(ix) + 0.5) / CGFloat(steps),
                                    y: face.minY + face.height * (CGFloat(iy) + 0.5) / CGFloat(steps))
                    let v = Int(luma(atSensor: geometry.sensor(fromUpright: u)))
                    if ix < steps / 2 { left += v; leftN += 1 } else { right += v; rightN += 1 }
                }
            }
            let l = Double(left) / Double(max(leftN, 1)) / 255
            let r = Double(right) / Double(max(rightN, 1)) / 255
            light.faceMean = (l + r) / 2
            light.faceLeftRight = (l, r)
        }

        // 3. Motion: average change of the tiny thumbnail since last time.
        var change = 0.0
        if previousGrid.count == grid.count {
            var diff = 0
            for i in 0..<grid.count { diff += abs(Int(grid[i]) - Int(previousGrid[i])) }
            change = Double(diff) / Double(grid.count) / 255
        }
        previousGrid = grid

        // 4. Vertical lines: sample a 96×72 grid and count strong edges that run up-down in
        //    the upright picture. With the phone upright (90°/270°) the sensor is sideways,
        //    so "up-down in the picture" is "left-right on the sensor".
        var edges = [Int](repeating: 0, count: edgeWidth * edgeHeight)
        for ey in 0..<edgeHeight {
            let y = (ey * height) / edgeHeight
            for ex in 0..<edgeWidth {
                let x = (ex * width) / edgeWidth
                edges[ey * edgeWidth + ex] = Int(yPlane[y * yRowBytes + x])
            }
        }
        let sensorIsSideways = geometry.angle == 90 || geometry.angle == 270
        var verticalCount = 0
        let strongEdge = 40   // Brightness step (0–255) that counts as a real edge.
        for ey in 1..<(edgeHeight - 1) {
            for ex in 1..<(edgeWidth - 1) {
                let i = ey * edgeWidth + ex
                let gx = abs(edges[i + 1] - edges[i - 1])                   // change left↔right on sensor
                let gy = abs(edges[i + edgeWidth] - edges[i - edgeWidth])   // change up↔down on sensor
                // An up-down line in the picture = brightness changing across it, sideways.
                let across = sensorIsSideways ? gy : gx
                let along = sensorIsSideways ? gx : gy
                if across >= strongEdge && across > 2 * along { verticalCount += 1 }
            }
        }
        let verticalLines = Double(verticalCount) / Double((edgeWidth - 2) * (edgeHeight - 2))

        return Result(light: light, frameChange: change, verticalLines: verticalLines)
    }

    /// Forget the previous frame (after switching cameras, so it doesn't count as motion).
    func reset() { previousGrid = [] }
}
