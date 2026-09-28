import AVFoundation

/// White balance choices the automatic settings can make.
enum WhiteBalanceSetting: Equatable {
    case auto
    /// Fixed colour temperature, e.g. daylight 5500 K so sunsets stay warm.
    case locked(kelvin: Float, tint: Float)
    /// Nudge from what auto white balance chose (for strong colour casts).
    case shift(kelvin: Float, tint: Float)
}

/// Camera controls used by the automatic settings (M3).
///
/// SAFETY RULE (see build 6): every value is checked against what this camera supports
/// and clamped to its allowed range before it's set, because AVFoundation throws
/// uncatchable exceptions for unsupported values. All changes run on the session queue.
extension CameraService {
    /// Meter exposure at a point (upright coordinates; nil = centre) with a bias in EV.
    func applyExposure(pointUpright: CGPoint?, biasEV: Float) {
        let geometry = FrameGeometry(rotationAngle: frameContext.snapshot().angle)
        let devicePoint = pointUpright.map { geometry.sensor(fromUpright: $0) } ?? CGPoint(x: 0.5, y: 0.5)
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = CGPoint(x: min(max(devicePoint.x, 0), 1),
                                                             y: min(max(devicePoint.y, 0), 1))
                    device.exposureMode = .continuousAutoExposure
                }
                let bias = min(max(biasEV, device.minExposureTargetBias), device.maxExposureTargetBias)
                if abs(device.exposureTargetBias - bias) > 0.01 {
                    device.setExposureTargetBias(bias, completionHandler: nil)
                }
            } catch {
                Log.warn("Exposure change failed: \(error.localizedDescription)")
            }
        }
    }

    /// The longest shutter time auto exposure may use. nil = iOS's default.
    /// Short (e.g. 1/250 s) freezes motion; long (e.g. 1/8 s) gathers light when steady.
    func setMaxExposure(seconds: Double?) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            // Only allowed while auto exposure is running (not custom/locked).
            guard device.exposureMode == .continuousAutoExposure || device.exposureMode == .autoExpose else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if let seconds {
                    let format = device.activeFormat
                    let low = CMTimeGetSeconds(format.minExposureDuration)
                    let high = CMTimeGetSeconds(format.maxExposureDuration)
                    guard low.isFinite, high.isFinite, high > low else { return }
                    let clamped = min(max(seconds, low), high)
                    device.activeMaxExposureDuration = CMTime(seconds: clamped, preferredTimescale: 1_000_000)
                } else {
                    device.activeMaxExposureDuration = .invalid   // Back to the default.
                }
            } catch {
                Log.warn("Max exposure change failed: \(error.localizedDescription)")
            }
        }
    }

    func applyWhiteBalance(_ setting: WhiteBalanceSetting) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                switch setting {
                case .auto:
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                case .locked(let kelvin, let tint):
                    guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
                    let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: tint)
                    let gains = Self.clamped(device.deviceWhiteBalanceGains(for: values), device: device)
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                case .shift(let kelvin, let tint):
                    guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
                    let current = device.temperatureAndTintValues(
                        for: Self.clamped(device.deviceWhiteBalanceGains, device: device))
                    let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                        temperature: min(max(current.temperature + kelvin, 2000), 10000),
                        tint: min(max(current.tint + tint, -150), 150))
                    let gains = Self.clamped(device.deviceWhiteBalanceGains(for: values), device: device)
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                }
            } catch {
                Log.warn("White balance change failed: \(error.localizedDescription)")
            }
        }
    }

    /// Each gain must be between 1 and maxWhiteBalanceGain, or AVFoundation throws.
    static func clamped(_ gains: AVCaptureDevice.WhiteBalanceGains, device: AVCaptureDevice) -> AVCaptureDevice.WhiteBalanceGains {
        let high = device.maxWhiteBalanceGain
        func c(_ v: Float) -> Float { v.isFinite ? min(max(v, 1), high) : 1 }
        return AVCaptureDevice.WhiteBalanceGains(redGain: c(gains.redGain), greenGain: c(gains.greenGain),
                                                 blueGain: c(gains.blueGain))
    }
}
