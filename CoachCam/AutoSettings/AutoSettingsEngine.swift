import AVFoundation
import Foundation

/// One automatic setting, shown as a small badge. Tap a badge to turn that setting off
/// (it turns grey); tap again to turn it back on.
struct AutoBadge: Identifiable, Equatable {
    let kind: AutoSettingsEngine.Kind
    var text: String
    var isOff: Bool
    var id: String { kind.rawValue }
}

/// M3: sets the camera automatically from the playbook rule (your photo type + what's
/// detected) and the live scene: lens, exposure, HDR/quality, low light + night merge,
/// motion, white balance. Runs on the main thread after each analysis (about 12×/s) and
/// only touches the camera when something actually needs to change.
final class AutoSettingsEngine: ObservableObject {
    enum Kind: String, CaseIterable {
        case lens, exposure, hdr, lowLight, night, motion, whiteBalance
    }

    @Published private(set) var badges: [AutoBadge] = []
    @Published private(set) var off: Set<Kind> = []
    /// True while a night merge is capturing ("Hold still").
    @Published var holdingStill = false

    /// What the shutter should do right now.
    private(set) var captureQuality: AVCapturePhotoOutput.QualityPrioritization = .balanced
    private(set) var useNightMerge = false

    private let config = AppConfig.shared.auto

    // Lens state
    private var pendingZoom: CGFloat?
    private var pendingSince: TimeInterval = 0
    private var lastLensSwitch: TimeInterval = 0
    // Exposure state
    private var lastExposurePoint: CGPoint?
    private var lastExposureBias: Float = 0
    private var lastExposureUpdate: TimeInterval = 0
    private var userTappedAt: TimeInterval = -100
    // Light / shutter / WB state
    private var inLowLight = false
    private var appliedMaxExposure: Double?? = .none   // .none = never set
    private var appliedWB: WhiteBalanceSetting?

    // MARK: - Your overrides

    func toggle(_ kind: Kind, camera: CameraService) {
        if off.contains(kind) {
            off.remove(kind)
            Log.info("Auto \(kind.rawValue): on")
        } else {
            off.insert(kind)
            Log.info("Auto \(kind.rawValue): off")
            switch kind {
            case .exposure:
                camera.applyExposure(pointUpright: nil, biasEV: 0)
                lastExposurePoint = nil
            case .lowLight, .motion:
                setMaxExposure(nil, camera: camera)
            case .whiteBalance:
                setWhiteBalance(.auto, camera: camera)
            default:
                break
            }
        }
        badges = badges.map { AutoBadge(kind: $0.kind, text: $0.text, isOff: off.contains($0.kind)) }
    }

    /// You tapped a lens button or pinched: stop choosing the lens for you.
    func userChangedLens() {
        if !off.contains(.lens) {
            off.insert(.lens)
            Log.info("Auto lens off (you picked a lens)")
        }
    }

    /// You tapped to focus: leave exposure alone for a few seconds.
    func userTapped() {
        userTappedAt = CACurrentMediaTime()
    }

    // MARK: - The loop

    func update(rule: Playbook.Rule?, photoType: PhotoType?, description d: SceneDescription, analysis a: SceneAnalysis,
                camera: CameraService, iso: Float, shake: Double, subjectBox: CGRect?) {
        let now = CACurrentMediaTime()
        var newBadges: [AutoBadge] = []
        func badge(_ kind: Kind, _ text: String) {
            newBadges.append(AutoBadge(kind: kind, text: text, isOff: off.contains(kind)))
        }
        let auto = rule?.autoSettings
        let mainPerson = a.people.first

        // 1. Lens (back camera only).
        if let rule, !d.isFrontCamera, d.category != .general {
            var wanted = CGFloat(rule.lens.zoom)
            var why = photoType?.title ?? d.category.title
            // Too close for the headshot lens → use the fallback (coaching will say "step back").
            if wanted >= 4, let face = mainPerson?.faceArea, face > config.headshotTooCloseFaceArea,
               let fallback = rule.lens.fallbackZoom {
                wanted = CGFloat(fallback)
                why += ", too close for \(Int(rule.lens.zoom))x"
            }
            wanted = nearestAvailable(wanted, camera: camera)
            badge(.lens, "\(Self.zoomText(wanted)) \(why)")
            if !off.contains(.lens) { updateLens(wanted: wanted, current: camera.zoom, now: now, camera: camera) }
        }

        // 2. Exposure: where to meter, and how much brighter/darker.
        var point: CGPoint?
        var bias: Float = 0
        var exposureText: String?
        switch auto?.exposure {
        case "face":
            if let face = mainPerson?.faceBox {
                point = face.center
                exposureText = "Face exposure"
                if d.lighting.isBacklit {
                    bias = config.backlitBiasEV
                    exposureText = "Backlit +\(String(format: "%.1f", config.backlitBiasEV))"
                }
            }
        case "sky":
            point = CGPoint(x: 0.5, y: 0.2)
            bias = config.skyBiasEV
            exposureText = "Sky exposure"
        case "subject":
            if let box = subjectBox ?? a.objects.first?.box {
                point = box.center
                exposureText = "Subject exposure"
            }
        default:
            break
        }
        if let exposureText { badge(.exposure, exposureText) }
        if !off.contains(.exposure), now - userTappedAt > 4 {
            updateExposure(point: point, bias: bias, now: now, camera: camera)
        }

        // 3. Light level, with hysteresis so it doesn't flip back and forth.
        let brightness = a.light.mean
        if inLowLight {
            if iso < config.lowLightExitISO && brightness > config.lowLightExitBrightness { inLowLight = false }
        } else if iso >= config.lowLightEnterISO || brightness < config.lowLightEnterBrightness {
            inLowLight = true
        }
        let steady = shake < config.steadyShake
        let moving = a.frameChange > config.fastShutterMotion || auto?.shutter == "fast"

        // 4. Shutter limit: freeze motion, or allow a longer shutter when steady in low light.
        var maxExposure: Double?
        if moving && !off.contains(.motion) {
            maxExposure = config.fastShutterSeconds
            badge(.motion, "Fast shutter")
        } else if inLowLight && steady && !off.contains(.lowLight) {
            maxExposure = config.steadyMaxExposureSeconds
        }
        if inLowLight { badge(.lowLight, steady ? "Low light · steady" : "Low light · hold still") }
        setMaxExposure(maxExposure, camera: camera)

        // 5. Night merge for very dark scenes when the phone is steady.
        useNightMerge = inLowLight && iso >= config.nightMergeISO && steady && !moving && !off.contains(.night)
            && auto?.lowLight != "off"
        if inLowLight && iso >= config.nightMergeISO { badge(.night, "Night merge") }

        // 6. HDR / quality: let iOS do its multi-frame processing when light is tricky.
        let tricky = d.lighting.isHarsh || d.lighting.isBacklit || a.light.clippedHighlights > 0.05
        if moving {
            captureQuality = .balanced   // Faster capture for moving subjects.
        } else if (auto?.hdr != "off" && tricky) || inLowLight || auto?.hdr == "on" {
            captureQuality = off.contains(.hdr) ? .balanced : .quality
            if auto?.hdr != "off" && (tricky || auto?.hdr == "on") { badge(.hdr, "HDR") }
        } else {
            captureQuality = .balanced
        }

        // 7. White balance: keep sunsets warm; gently fix strong casts on faces.
        var wb: WhiteBalanceSetting = .auto
        if auto?.whiteBalance == "warm" {
            wb = .locked(kelvin: config.sunsetKelvin, tint: 0)
            badge(.whiteBalance, "Warm WB")
        } else if case .shift? = appliedWB, mainPerson?.faceBox != nil, let kept = appliedWB {
            // Keep a correction while the face stays (once fixed, the cast "disappears",
            // and dropping the fix would bring it straight back).
            wb = kept
            badge(.whiteBalance, "Skin-tone WB")
        } else if mainPerson?.faceBox != nil,
                  abs(a.light.colorCastBlue) > config.castThreshold || abs(a.light.colorCastRed) > config.castThreshold {
            // Blue image → tell the camera the light is bluer (it warms the picture), and so on.
            let kelvin = a.light.colorCastBlue > config.castThreshold ? config.castCorrectionKelvin
                : a.light.colorCastBlue < -config.castThreshold ? -config.castCorrectionKelvin : 0
            let tint = a.light.colorCastRed > config.castThreshold ? config.castCorrectionTint
                : a.light.colorCastRed < -config.castThreshold ? -config.castCorrectionTint : 0
            wb = .shift(kelvin: kelvin, tint: tint)
            badge(.whiteBalance, "Skin-tone WB")
        }
        if off.contains(.whiteBalance) { wb = .auto }
        setWhiteBalance(wb, camera: camera)

        if newBadges != badges { badges = newBadges }
    }

    // MARK: - Helpers

    private func updateLens(wanted: CGFloat, current: CGFloat, now: TimeInterval, camera: CameraService) {
        guard abs(wanted - current) / max(current, 0.1) > 0.08 else {
            pendingZoom = nil
            return
        }
        if pendingZoom != wanted {
            pendingZoom = wanted
            pendingSince = now
            return
        }
        guard now - pendingSince >= config.lensHoldSeconds, now - lastLensSwitch >= config.lensMinIntervalSeconds else { return }
        Log.info("Auto lens: \(Self.zoomText(current)) → \(Self.zoomText(wanted))")
        camera.setZoom(wanted, smooth: true)
        lastLensSwitch = now
        pendingZoom = nil
    }

    private func updateExposure(point: CGPoint?, bias: Float, now: TimeInterval, camera: CameraService) {
        let moved: Bool
        switch (point, lastExposurePoint) {
        case (nil, nil): moved = false
        case let (p?, q?): moved = p.distance(to: q) > 0.05
        default: moved = true
        }
        guard moved || abs(bias - lastExposureBias) > 0.05 else { return }
        guard now - lastExposureUpdate >= config.exposureUpdateSeconds else { return }
        camera.applyExposure(pointUpright: point, biasEV: bias)
        lastExposurePoint = point
        lastExposureBias = bias
        lastExposureUpdate = now
    }

    private func setMaxExposure(_ seconds: Double?, camera: CameraService) {
        if case .some(let applied) = appliedMaxExposure, applied == seconds { return }
        camera.setMaxExposure(seconds: seconds)
        appliedMaxExposure = .some(seconds)
    }

    private func setWhiteBalance(_ setting: WhiteBalanceSetting, camera: CameraService) {
        guard setting != appliedWB else { return }
        camera.applyWhiteBalance(setting)
        appliedWB = setting
    }

    private func nearestAvailable(_ zoom: CGFloat, camera: CameraService) -> CGFloat {
        let options = camera.lensOptions.map(\.zoom)
        guard !options.isEmpty else { return zoom }
        return options.min { abs($0 - zoom) < abs($1 - zoom) } ?? zoom
    }

    static func zoomText(_ zoom: CGFloat) -> String {
        zoom < 1 ? "0.5x" : "\(Int(zoom.rounded()))x"
    }
}
