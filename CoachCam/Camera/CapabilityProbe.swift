import AVFoundation

/// Lists what this iPhone's cameras let third-party apps control, so we find out
/// on the real phone instead of guessing. Shown in Settings → Camera capabilities.
enum CapabilityProbe {
    static func report(photoOutput: AVCapturePhotoOutput, activeDevice: AVCaptureDevice?) -> String {
        var lines: [String] = []
        func add(_ s: String) { lines.append(s) }
        func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

        add("Coach Cam \(AppVersion.full)")
        add("iOS \(UIDeviceInfo.systemVersion) · \(UIDeviceInfo.modelIdentifier)")
        add("")

        // Every camera iOS offers to apps.
        let allTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera,
            .builtInDualCamera, .builtInDualWideCamera, .builtInTripleCamera,
            .builtInTrueDepthCamera, .builtInLiDARDepthCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: allTypes, mediaType: .video, position: .unspecified)
        add("== Cameras available to apps ==")
        for device in discovery.devices {
            let side = device.position == .front ? "front" : "back"
            add("• \(device.localizedName) [\(side)] f/\(String(format: "%.2f", device.lensAperture))")
        }
        add("")

        if let device = activeDevice {
            add("== Active camera: \(device.localizedName) ==")
            add("Virtual (auto-switching): \(yesNo(device.isVirtualDevice))")
            if device.isVirtualDevice {
                add("Lenses inside: " + device.constituentDevices.map { $0.localizedName }.joined(separator: ", "))
                let switches = device.virtualDeviceSwitchOverVideoZoomFactors.map {
                    String(format: "%.1fx", $0.doubleValue * device.displayVideoZoomFactorMultiplier)
                }
                add("Switches lens at: " + switches.joined(separator: ", "))
            }
            let m = device.displayVideoZoomFactorMultiplier
            add(String(format: "Zoom range: %.1fx – %.1fx", device.minAvailableVideoZoomFactor * m,
                       device.maxAvailableVideoZoomFactor * m))
            let crops = device.activeFormat.secondaryNativeResolutionZoomFactors.map { String(format: "%.1fx", $0 * m) }
            add("Full-quality sensor crops at: " + (crops.isEmpty ? "none" : crops.joined(separator: ", ")))
            add("")

            add("== Aperture ==")
            add(String(format: "Current: f/%.2f", device.lensAperture))
            add("Can apps SET the aperture? no — AVFoundation only reports it (read-only).")
            if device.isVirtualDevice {
                for lens in device.constituentDevices {
                    add(String(format: "  %@: f/%.2f", lens.localizedName, lens.lensAperture))
                }
            }
            add("")

            let f = device.activeFormat
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            add("== Manual controls (active format \(dims.width)x\(dims.height)) ==")
            add(String(format: "ISO range: %.0f – %.0f", f.minISO, f.maxISO))
            add(String(format: "Shutter range: 1/%.0f s – %.3f s", 1 / CMTimeGetSeconds(f.minExposureDuration),
                       CMTimeGetSeconds(f.maxExposureDuration)))
            add("Manual exposure (custom): \(yesNo(device.isExposureModeSupported(.custom)))")
            add("Manual focus (lens position): \(yesNo(device.isLockingFocusWithCustomLensPositionSupported))")
            add("Manual white balance: \(yesNo(device.isLockingWhiteBalanceWithCustomDeviceGainsSupported))")
            add("Minimum focus distance: \(device.minimumFocusDistance) mm")
            add("Low-light boost: \(yesNo(device.isLowLightBoostSupported))")
            add("Video HDR: \(yesNo(f.isVideoHDRSupported))")
            add("Global tone mapping: \(yesNo(f.isGlobalToneMappingSupported))")
            add("High photo quality: \(yesNo(f.isHighPhotoQualitySupported))")
            add("Depth formats: \(f.supportedDepthDataFormats.count)")
            let sizes = f.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }
            add("Photo sizes: " + sizes.joined(separator: ", "))
            add("")
        }

        add("== Photo output ==")
        add("Max quality mode: \(photoOutput.maxPhotoQualityPrioritization.rawValue) (3 = quality)")
        add("Max bracketed photos (for our own night/HDR merge): \(photoOutput.maxBracketedCapturePhotoCount)")
        add("Zero shutter lag: \(yesNo(photoOutput.isZeroShutterLagSupported))")
        add("Responsive capture: \(yesNo(photoOutput.isResponsiveCaptureSupported))")
        add("Fast capture prioritization: \(yesNo(photoOutput.isFastCapturePrioritizationSupported))")
        add("Depth data: \(yesNo(photoOutput.isDepthDataDeliverySupported))")
        add("Portrait matte: \(yesNo(photoOutput.isPortraitEffectsMatteDeliverySupported))")
        add("Skin/hair/sky mattes: \(photoOutput.availableSemanticSegmentationMatteTypes.map { $0.rawValue }.joined(separator: ", "))")
        add("Apple ProRAW: \(yesNo(photoOutput.isAppleProRAWSupported))")
        add("Constant color: \(yesNo(photoOutput.isConstantColorSupported))")
        add("Multi-lens photo delivery: \(yesNo(photoOutput.isVirtualDeviceConstituentPhotoDeliverySupported))")
        add("Distortion correction: \(yesNo(photoOutput.isContentAwareDistortionCorrectionSupported))")
        add("Codecs: " + photoOutput.availablePhotoCodecTypes.map { $0.rawValue }.joined(separator: ", "))
        add("")
        add("== Not available to any third-party app ==")
        add("Apple Night mode, Deep Fusion/Smart HDR on/off switches, Photographic Styles control.")
        add("(iOS applies its own processing in 'quality' mode; we build our own night merge.)")
        return lines.joined(separator: "\n")
    }
}

/// Small helpers for device info (no UIKit needed on background threads).
enum UIDeviceInfo {
    static let systemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString

    /// e.g. "iPhone18,2".
    static let modelIdentifier: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }()
}
