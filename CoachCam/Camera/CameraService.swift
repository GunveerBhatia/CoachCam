import AVFoundation
import Combine
import UIKit

/// Which way the camera faces.
enum CameraPosition {
    case back, front
}

/// One of the lens buttons (0.5x, 1x, 2x, 4x, 8x). `zoom` is in "display" units,
/// the same numbers Apple's Camera app shows.
struct LensOption: Identifiable, Hashable {
    let zoom: CGFloat
    var id: CGFloat { zoom }
    var label: String { zoom < 1 ? "0.5x" : "\(Int(zoom))x" }
}

/// Owns the camera: the AVCaptureSession, the lens/zoom, focus, and photo capture.
///
/// Threading:
/// - All session and device changes happen on `sessionQueue` (AVFoundation is slow and
///   must not block the UI).
/// - Frames for analysis arrive on `videoQueue`.
/// - `@Published` properties are only changed on the main thread.
///
/// Future video support: add an `AVCaptureMovieFileOutput` (or asset writer) in
/// `configureSession()` next to the photo output. Nothing else here needs to change.
final class CameraService: NSObject, ObservableObject {

    // MARK: Published state for the UI

    @Published private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isRunning = false
    @Published private(set) var position: CameraPosition = .back
    @Published private(set) var lensOptions: [LensOption] = []
    @Published private(set) var zoom: CGFloat = 1                 // Current display zoom (1 = 24mm main).
    @Published private(set) var physicalLens = "—"                // Which physical camera iOS is using right now.
    @Published private(set) var lastThumbnail: UIImage?
    @Published private(set) var shutterFlash = false             // Briefly true when a photo is taken.
    @Published private(set) var lastSaveMessage: String?

    /// Live numbers for the debug overlay (updated about 4 times a second).
    let stats = LiveStats()

    /// Hook for frame analysis (M2). Called on `videoQueue` for every camera frame;
    /// the analyzer decides for itself how often to do real work.
    /// Arguments: the frame, the rotation needed to make it upright (0/90/180/270), front camera?
    var frameHandler: ((CMSampleBuffer, FrameInfo) -> Void)?

    // MARK: AVFoundation objects

    let session = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "coachcam.session")
    private let videoQueue = DispatchQueue(label: "coachcam.video", qos: .userInitiated)
    let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private(set) var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false

    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private(set) var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    /// How the phone is held and which camera is active; read by the analysis on other threads.
    let frameContext = FrameContext()
    private var lensObservation: NSKeyValueObservation?
    var inFlightCaptures: [Int64: NSObject] = [:]   // Only touched on sessionQueue.

    // Frame statistics (only touched on videoQueue).
    private var frameCount = 0
    private var statsWindowStart = CACurrentMediaTime()
    private var lastBrightness: Double = 0

    // MARK: - Starting and stopping

    /// Asks for camera permission if needed, then starts the camera.
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorization = granted ? .authorized : .denied
                    if granted { self.startSession() }
                }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
            Log.warn("Camera permission not granted")
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    private func startSession() {
        authorization = .authorized
        sessionQueue.async {
            if !self.isConfigured {
                self.configureSession()
                // Photo size must be set after the configuration is committed, once
                // the camera's real format is active (setting it too early can crash).
                if let device = self.videoInput?.device { self.applyPhotoDimensions(for: device) }
            }
            self.ensureRunning(attempt: 1)
        }
    }

    /// Starts the session and retries if it doesn't come up.
    ///
    /// When you leave the app, iOS "interrupts" the camera (reason 1) and normally resumes
    /// it by itself when you come back. But if we ask it to start a moment before iOS has
    /// given the camera back, startRunning() quietly does nothing. So: retry a few times, and
    /// also try again when iOS says the interruption ended. Runs on sessionQueue.
    private func ensureRunning(attempt: Int) {
        guard isConfigured else { return }
        if !session.isRunning { session.startRunning() }
        let running = session.isRunning
        DispatchQueue.main.async {
            let changed = self.isRunning != running
            self.isRunning = running
            if running && changed { self.setUpRotation() }
        }
        if running {
            if attempt > 1 { Log.info("Camera running (after \(attempt) tries)") }
            return
        }
        if session.isInterrupted && attempt >= 3 {
            // iOS still holds the camera; interruptionEnded will call us again.
            Log.info("Waiting for iOS to hand the camera back")
            return
        }
        guard attempt < 5 else {
            Log.error("Camera didn't restart after \(attempt) tries")
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + 0.4) { self.ensureRunning(attempt: attempt + 1) }
    }

    /// Called by the preview view once its layer exists.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        setUpRotation()
    }

    // MARK: - Session setup (sessionQueue)

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // SAFETY RULE for this file: many AVFoundation setters throw Objective-C exceptions
        // (which Swift can't catch) when a value isn't supported. Every setter below is guarded
        // by its matching "can…/is…Supported/available…" check first.
        if session.canSetSessionPreset(.photo) {
            session.sessionPreset = .photo   // Full-quality 4:3 photos.
        } else {
            Log.warn("Photo preset not supported; using the session default")
        }

        guard let device = Self.bestDevice(for: .back) else {
            Log.error("No back camera found")
            return
        }
        guard replaceInput(with: device) else { return }

        // Photo output
        guard session.canAddOutput(photoOutput) else {
            Log.error("Can't add photo output")
            return
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality   // Always allowed (it's only a ceiling).
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = true   // Lets you take photos back to back.
        }

        // Frame output for analysis (M2). Late frames are dropped so the camera never backs up.
        // Frame size is left to AVFoundation (deliversPreviewSizedOutputBuffers crashed build 6);
        // SceneAnalyzer shrinks frames itself before running Vision.
        let wantedFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        if videoOutput.availableVideoPixelFormatTypes.contains(wantedFormat) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: wantedFormat]
        } else {
            Log.warn("420f frames not available; light meter will be limited")
        }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        } else {
            Log.warn("Can't add video data output (analysis disabled)")
        }

        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                                               name: AVCaptureSession.runtimeErrorNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: AVCaptureSession.wasInterruptedNotification, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                                               name: AVCaptureSession.interruptionEndedNotification, object: session)
        isConfigured = true
        Log.info("Camera configured with \(device.localizedName)")
    }

    /// Picks the best camera. On the back that's the "triple camera", a virtual camera that
    /// combines ultra wide, main and telephoto and switches between them as you zoom.
    static func bestDevice(for position: CameraPosition) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType]
        let avPosition: AVCaptureDevice.Position
        switch position {
        case .back:
            types = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            avPosition = .back
        case .front:
            types = [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            avPosition = .front
        }
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: avPosition)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// Swaps the camera input. Must be called inside begin/commitConfiguration.
    @discardableResult
    private func replaceInput(with device: AVCaptureDevice) -> Bool {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if let old = videoInput { session.removeInput(old) }
            guard session.canAddInput(input) else {
                Log.error("Can't add input for \(device.localizedName)")
                if let old = videoInput { session.addInput(old) }
                return false
            }
            session.addInput(input)
            videoInput = input
            configureDefaults(for: device)
            observePhysicalLens(of: device)
            let options = availableLenses(for: device)
            let startZoom = displayZoom(of: device)
            DispatchQueue.main.async {
                self.lensOptions = options
                self.zoom = startZoom
            }
            return true
        } catch {
            Log.error("Camera input error: \(error.localizedDescription)")
            return false
        }
    }

    /// Continuous autofocus/exposure, and start at 1x (the 24mm main camera).
    private func configureDefaults(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            let oneX = 1 / Self.zoomMultiplier(device)
            device.videoZoomFactor = clampZoomFactor(oneX, for: device)
        } catch {
            Log.error("Couldn't configure device: \(error.localizedDescription)")
        }
    }

    /// Uses the largest photo size up to about 24 MP (fast, like Apple's default).
    /// 48 MP is possible and gets its own setting later.
    private func applyPhotoDimensions(for device: AVCaptureDevice) {
        let limit: Int32 = 24_500_000
        let sizes = device.activeFormat.supportedMaxPhotoDimensions
        let best = sizes
            .filter { Int64($0.width) * Int64($0.height) <= Int64(limit) }
            .max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
        if let best {
            photoOutput.maxPhotoDimensions = best
            Log.info("Photo size: \(best.width)x\(best.height)")
        }
    }

    /// Keeps `physicalLens` up to date. At "4x", iOS may quietly use a crop of the main
    /// camera instead of the telephoto (e.g. in low light or when too close); this shows it.
    private func observePhysicalLens(of device: AVCaptureDevice) {
        lensObservation = nil
        guard device.isVirtualDevice else {
            let name = Self.lensName(for: device)
            DispatchQueue.main.async { self.physicalLens = name }
            return
        }
        lensObservation = device.observe(\.activePrimaryConstituent, options: [.initial, .new]) { [weak self] dev, _ in
            let name = dev.activePrimaryConstituent.map(Self.lensName(for:)) ?? "—"
            DispatchQueue.main.async { self?.physicalLens = name }
        }
    }

    static func lensName(for device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "Ultra wide 13mm"
        case .builtInWideAngleCamera: return device.position == .front ? "Front" : "Main 24mm"
        case .builtInTelephotoCamera: return "Telephoto 100mm"
        case .builtInTrueDepthCamera: return "Front (TrueDepth)"
        default: return device.localizedName
        }
    }

    // MARK: - Rotation (main thread)

    /// Keeps the preview upright and makes photos come out the right way up,
    /// even though the app's UI is locked to portrait.
    private func setUpRotation() {
        guard let device = videoInput?.device, let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                         options: [.initial, .new]) { [weak layer] c, _ in
            let angle = c.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                if let connection = layer?.connection, connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
        // Remember how the phone is held, for analysis (read from the video queue).
        captureRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                         options: [.initial, .new]) { [weak self] c, _ in
            self?.frameContext.set(angle: c.videoRotationAngleForHorizonLevelCapture)
        }
        frameContext.set(isFront: device.position == .front)
    }

    // MARK: - Coordinate conversion (main thread)

    /// Screen point in the preview → upright photo coordinates (0–1, top-left origin).
    func uprightPoint(fromLayerPoint point: CGPoint) -> CGPoint? {
        guard let layer = previewLayer else { return nil }
        let sensor = layer.captureDevicePointConverted(fromLayerPoint: point)
        return FrameGeometry(rotationAngle: frameContext.snapshot().angle).upright(fromSensor: sensor)
    }

    /// Upright photo coordinates → screen point in the preview.
    func layerPoint(fromUpright point: CGPoint) -> CGPoint? {
        guard let layer = previewLayer else { return nil }
        let sensor = FrameGeometry(rotationAngle: frameContext.snapshot().angle).sensor(fromUpright: point)
        return layer.layerPointConverted(fromCaptureDevicePoint: sensor)
    }

    /// Upright rect → screen rect in the preview.
    func layerRect(fromUpright rect: CGRect) -> CGRect? {
        guard let a = layerPoint(fromUpright: CGPoint(x: rect.minX, y: rect.minY)),
              let b = layerPoint(fromUpright: CGPoint(x: rect.maxX, y: rect.maxY)) else { return nil }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: - Lens and zoom

    /// Which lens buttons make sense for this camera.
    private func availableLenses(for device: AVCaptureDevice) -> [LensOption] {
        let multiplier = Self.zoomMultiplier(device)
        let minDisplay = device.minAvailableVideoZoomFactor * multiplier
        let maxDisplay = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor) * multiplier
        let candidates: [CGFloat] = device.position == .front ? [1, 2] : [0.5, 1, 2, 4, 8]
        return candidates
            .filter { $0 >= minDisplay - 0.01 && $0 <= maxDisplay + 0.01 }
            .map { LensOption(zoom: $0) }
    }

    private func displayZoom(of device: AVCaptureDevice) -> CGFloat {
        device.videoZoomFactor * Self.zoomMultiplier(device)
    }

    /// Display zoom = videoZoomFactor × this (0.5 on the triple camera). Never 0, so no bad math.
    static func zoomMultiplier(_ device: AVCaptureDevice) -> CGFloat {
        let m = device.displayVideoZoomFactorMultiplier
        return m > 0 ? m : 1
    }

    private func clampZoomFactor(_ factor: CGFloat, for device: AVCaptureDevice) -> CGFloat {
        let upper = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)
        return max(device.minAvailableVideoZoomFactor, min(factor, upper))
    }

    /// The largest display zoom allowed (for pinch). Capped at 16x.
    var maxDisplayZoom: CGFloat {
        guard let device = videoInput?.device else { return 1 }
        let upper = min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)
        return min(upper * Self.zoomMultiplier(device), 16)
    }

    var minDisplayZoom: CGFloat {
        guard let device = videoInput?.device else { return 1 }
        return device.minAvailableVideoZoomFactor * Self.zoomMultiplier(device)
    }

    /// Sets the zoom in display units (0.5, 1, 2, 4, 8…).
    /// `smooth` animates like Apple's Camera when tapping a lens button.
    func setZoom(_ display: CGFloat, smooth: Bool) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            let factor = self.clampZoomFactor(display / Self.zoomMultiplier(device), for: device)
            do {
                try device.lockForConfiguration()
                if smooth {
                    device.ramp(toVideoZoomFactor: factor, withRate: 12)
                } else {
                    device.cancelVideoZoomRamp()
                    device.videoZoomFactor = factor
                }
                device.unlockForConfiguration()
            } catch {
                Log.error("Zoom failed: \(error.localizedDescription)")
            }
            let newZoom = factor * Self.zoomMultiplier(device)
            DispatchQueue.main.async { self.zoom = newZoom }
        }
    }

    // MARK: - Flip front/back

    func flipCamera() {
        let target: CameraPosition = position == .back ? .front : .back
        sessionQueue.async {
            guard let device = Self.bestDevice(for: target) else {
                Log.error("No \(target) camera")
                return
            }
            self.session.beginConfiguration()
            let ok = self.replaceInput(with: device)
            self.session.commitConfiguration()
            if ok { self.applyPhotoDimensions(for: device) }
            DispatchQueue.main.async {
                if ok { self.position = target }
                self.setUpRotation()
            }
            Log.info("Switched to \(target) camera: \(device.localizedName)")
        }
    }

    // MARK: - Tap to focus

    /// `layerPoint` is where you tapped, in the preview's coordinates.
    func focus(atLayerPoint layerPoint: CGPoint) {
        guard let layer = previewLayer else { return }
        let devicePoint = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusPointOfInterest = devicePoint
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposurePointOfInterest = devicePoint
                    device.exposureMode = .continuousAutoExposure
                }
            } catch {
                Log.error("Focus failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Photo capture

    /// Takes one photo and saves it to your photo library. `quality` comes from the
    /// automatic settings (M3): .quality lets iOS apply Smart HDR / Deep Fusion.
    func capturePhoto(quality: AVCapturePhotoOutput.QualityPrioritization = .balanced) {
        // Read the tilt of the phone now (main thread) so the photo is rotated correctly.
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        sessionQueue.async {
            // capturePhoto throws an exception if there's no live, enabled video connection.
            guard self.session.isRunning,
                  let photoConnection = self.photoOutput.connection(with: .video),
                  photoConnection.isEnabled, photoConnection.isActive else {
                Log.warn("Shutter ignored: camera not ready")
                return
            }
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            // Must not exceed the output's maximum, or AVFoundation throws.
            let wanted = quality
            settings.photoQualityPrioritization =
                wanted.rawValue <= self.photoOutput.maxPhotoQualityPrioritization.rawValue
                ? wanted : self.photoOutput.maxPhotoQualityPrioritization

            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(
                willCapture: { [weak self] in self?.flashShutter() },
                completion: { [weak self] result in
                    self?.handleCaptured(result)
                    self?.sessionQueue.async { self?.inFlightCaptures[id] = nil }
                }
            )
            self.inFlightCaptures[id] = processor
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    /// Brief black flash on the viewfinder when the shutter fires.
    func flashShutter() {
        DispatchQueue.main.async {
            self.shutterFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.shutterFlash = false }
        }
    }

    /// Shows the thumbnail and saves the photo (also used by the night merge).
    func handleCaptured(_ result: Result<Data, Error>) {
        switch result {
        case .failure(let error):
            Log.error("Capture failed: \(error.localizedDescription)")
            DispatchQueue.main.async { self.lastSaveMessage = "Capture failed" }
        case .success(let data):
            let thumbnail = PhotoLibrary.thumbnail(from: data, maxPixelSize: 180)
            DispatchQueue.main.async { self.lastThumbnail = thumbnail }
            // Permission was already asked for on the main thread when you pressed the
            // shutter (see CameraScreen.takePhoto), so saving never shows a prompt itself.
            Task {
                do {
                    try await PhotoLibrary.save(data)
                    Log.info("Saved photo (\(data.count / 1024) KB)")
                    await MainActor.run { self.lastSaveMessage = nil }
                } catch {
                    Log.error("Save failed: \(error.localizedDescription)")
                    await MainActor.run { self.lastSaveMessage = "Couldn't save the photo" }
                }
            }
        }
    }

    // MARK: - Capability report

    /// A plain-text list of what this iPhone's cameras allow apps to control.
    func capabilityReport(completion: @escaping (String) -> Void) {
        sessionQueue.async {
            let text = CapabilityProbe.report(photoOutput: self.photoOutput, activeDevice: self.videoInput?.device)
            DispatchQueue.main.async { completion(text) }
        }
    }

    // MARK: - Session notifications

    @objc private func sessionRuntimeError(_ note: Notification) {
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
        Log.error("Session runtime error: \(error?.localizedDescription ?? "unknown")")
        if error?.code == .mediaServicesWereReset {
            sessionQueue.async { self.ensureRunning(attempt: 1) }
        }
    }

    @objc private func sessionInterrupted(_ note: Notification) {
        let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int ?? -1
        let reason: String
        switch AVCaptureSession.InterruptionReason(rawValue: raw) {
        case .videoDeviceNotAvailableInBackground: reason = "app went to background"
        case .audioDeviceInUseByAnotherClient: reason = "audio in use by another app"
        case .videoDeviceInUseByAnotherClient: reason = "camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: reason = "multiple apps on screen"
        case .videoDeviceNotAvailableDueToSystemPressure: reason = "phone too hot / system pressure"
        default: reason = "reason \(raw)"
        }
        Log.info("Camera paused: \(reason)")
        DispatchQueue.main.async { self.isRunning = false }
    }

    @objc private func sessionInterruptionEnded(_ note: Notification) {
        Log.info("Camera pause ended")
        sessionQueue.async { self.ensureRunning(attempt: 1) }
    }
}

// MARK: - Frames for analysis

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let start = CACurrentMediaTime()
        frameCount += 1

        // Cheap brightness estimate every 3rd frame (M2 replaces this with real analysis).
        if frameCount % 3 == 0, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lastBrightness = FrameMath.meanLuma(pixelBuffer)
        }
        if let frameHandler {
            let context = frameContext.snapshot()
            var info = FrameInfo(rotationAngle: context.angle, isFrontCamera: context.isFront)
            if let device = videoInput?.device {
                // The physical lens in use (the virtual camera reports its first lens otherwise).
                let lens = device.activePrimaryConstituent ?? device
                info.lensPosition = Double(lens.lensPosition)
                info.activeLens = lens.deviceType
                // Field of view along the sensor's long side at the current zoom.
                let baseFOV = Double(device.activeFormat.videoFieldOfView) * .pi / 180
                info.horizontalFOV = 2 * atan(tan(baseFOV / 2) / Double(device.videoZoomFactor))
                let displayZoom = Double(device.videoZoomFactor * Self.zoomMultiplier(device))
                // iOS switches to the ultra wide for macro when you're very close at 1x+.
                info.isMacro = device.isVirtualDevice && lens.deviceType == .builtInUltraWideCamera
                    && displayZoom >= 0.95
            }
            frameHandler(sampleBuffer, info)
        }

        let workMs = (CACurrentMediaTime() - start) * 1000
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindowStart
        if elapsed >= 0.25 {
            let fps = Double(frameCount) / elapsed
            frameCount = 0
            statsWindowStart = now
            let device = videoInput?.device
            stats.publish(
                fps: fps,
                frameMs: workMs,
                brightness: lastBrightness,
                iso: device?.iso ?? 0,
                shutter: device.map { CMTimeGetSeconds($0.exposureDuration) } ?? 0,
                // The lens actually in use (the virtual camera only reports its first lens).
                aperture: (device?.activePrimaryConstituent ?? device)?.lensAperture ?? 0
            )
        }
    }
}

/// Numbers shown in the debug overlay. A separate object so that only the overlay
/// redraws when they change, not the whole camera screen.
final class LiveStats: ObservableObject {
    @Published private(set) var fps: Double = 0
    @Published private(set) var frameMs: Double = 0
    @Published private(set) var brightness: Double = 0   // 0 = black, 1 = white
    @Published private(set) var iso: Float = 0
    @Published private(set) var shutter: Double = 0      // seconds
    @Published private(set) var aperture: Float = 0      // f-number (read-only)

    func publish(fps: Double, frameMs: Double, brightness: Double, iso: Float, shutter: Double, aperture: Float) {
        DispatchQueue.main.async {
            self.fps = fps
            self.frameMs = frameMs
            self.brightness = brightness
            self.iso = iso
            self.shutter = shutter
            self.aperture = aperture
        }
    }
}

enum FrameMath {
    /// Average brightness of the frame (0–1), sampling every 16th pixel of the Y (luma) plane.
    static func meanLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var total = 0
        var count = 0
        let step = 16
        var y = 0
        while y < height {
            let row = pixels + y * rowBytes
            var x = 0
            while x < width {
                total += Int(row[x])
                count += 1
                x += step
            }
            y += step
        }
        return count > 0 ? Double(total) / Double(count) / 255.0 : 0
    }
}

/// Thread-safe holder for "how is the phone held" and "which camera", written on the main
/// thread and read on the video queue for every frame.
final class FrameContext {
    private let lock = NSLock()
    private var angle: CGFloat = 90   // Portrait until the rotation coordinator reports.
    private var isFront = false

    func set(angle: CGFloat) {
        lock.lock(); self.angle = angle; lock.unlock()
    }

    func set(isFront: Bool) {
        lock.lock(); self.isFront = isFront; lock.unlock()
    }

    func snapshot() -> (angle: CGFloat, isFront: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (angle, isFront)
    }
}
/// Camera facts that travel with each frame to the analyzer.
struct FrameInfo {
    /// Rotation that makes the frame upright (0/90/180/270).
    var rotationAngle: CGFloat
    var isFrontCamera: Bool
    /// Focus position of the lens in use: 0 = closest focus, 1 = farthest (not calibrated in metres).
    var lensPosition: Double?
    /// The physical lens in use.
    var activeLens: AVCaptureDevice.DeviceType?
    /// Horizontal field of view (along the sensor's long side) in radians, at the current zoom.
    var horizontalFOV: Double?
    /// True when iOS has switched to the ultra wide for a close-up (macro).
    var isMacro = false
}