import AVKit
import SwiftUI

/// The main camera screen.
///
/// What you see depends on the stage (StageMachine):
///   SEARCHING: just the camera · LOCKED: subject label + suggestion cards ·
///   GUIDING: subject label + one step + dots · READY: "Take it" + green shutter.
/// Lens, exposure, HDR, low light and white balance are set silently (debug overlay only).
///
/// Data flow: camera frames → SceneAnalyzer (12×/s) → SceneDescriber → StageMachine
/// (lock, frozen cards, guiding) → AutoSettingsEngine + StepGuide.
struct CameraScreen: View {
    @StateObject private var camera = CameraService()
    @StateObject private var describer = SceneDescriber()
    @StateObject private var subjectOverride = SubjectOverride()
    // @State (not @StateObject) so this screen doesn't redraw 12–20×/second with the gyro
    // or every analysis; only the small views that show that data observe them.
    @State private var motion = MotionService()
    @State private var analyzer = SceneAnalyzer()
    @StateObject private var stage = StageMachine()
    @State private var personTypes = PersonTypeTracker()
    @State private var objectNames = ObjectLabelTracker()
    @State private var autoSettings = AutoSettingsEngine()
    @State private var guide = StepGuide()
    @StateObject private var identify = IdentifyController()

    @AppStorage(SettingsKey.showDebugOverlay) private var showDebugOverlay = false
    @AppStorage(SettingsKey.showGrid) private var showGrid = true
    @AppStorage(SettingsKey.showLevel) private var showLevel = true

    @State private var showSettings = false
    @State private var focusPoint: CGPoint?
    @State private var pinchStartZoom: CGFloat?
    @State private var photosBlocked = false   // True when Photos access is denied/restricted.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.authorization == .denied || camera.authorization == .restricted {
                permissionDenied
            } else {
                VStack(spacing: 0) {
                    topBar
                    viewfinder
                    SuggestionCardsRow(stage: stage) { suggestion in
                        stage.pick(suggestion, guide: guide)
                    }
                    .padding(.top, 6)
                    .animation(.easeOut(duration: 0.2), value: stage.stage)
                    Spacer(minLength: 8)
                    lensButtons
                    bottomBar
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) {
            SettingsView(camera: camera, corrections: personTypes.corrections, aiNames: identify.history)
        }
        // Volume buttons and the Camera Control button take a photo.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { takePhoto() }
        }
        .onAppear {
            connectAnalysis()
            camera.start()
            motion.start()
            refreshPhotosBlocked()
            UIApplication.shared.isIdleTimerDisabled = true   // Keep the screen on while shooting.
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // iOS pauses the camera in the background and resumes it on return;
                // start() makes sure it really did (and retries if not).
                camera.start()
                motion.start()
                refreshPhotosBlocked()   // You may have changed it in Settings.
            case .background:
                motion.stop()
            default:
                break
            }
        }
    }

    // MARK: - Pieces

    /// Frames go to the analyzer; each analysis is described, then matched to a playbook rule
    /// using the photo type you picked.
    private func connectAnalysis() {
        let analyzer = self.analyzer
        let describer = self.describer
        let subjectOverride = self.subjectOverride
        let stage = self.stage
        let personTypes = self.personTypes
        let objectNames = self.objectNames
        let autoSettings = self.autoSettings
        let guide = self.guide
        let camera = self.camera
        let motion = self.motion
        camera.frameHandler = { sampleBuffer, info in
            analyzer.submit(sampleBuffer, info: info)
        }
        analyzer.onAnalysis = { analysis in
            let description = describer.ingest(analysis, cameraPitch: motion.cameraPitch,
                                               levelError: motion.levelError)
            personTypes.update(with: analysis)
            objectNames.update(with: analysis)
            let category = subjectOverride.effective(detected: description.category)
            let tags = SuggestionRanker.sceneTags(description: description, analysis: analysis,
                                                  personTypes: personTypes.currentTypes)
            // The stage machine locks, freezes the cards, and runs the guide (no flicker).
            let subjects = describer.subjects
            stage.update(category: category, description: description, analysis: analysis, tags: tags,
                         subjects: subjects, motion: motion, guide: guide) {
                let person = subjects.lockedPerson(in: analysis)
                    ?? (stage.lockedCategory == .people ? analysis.people.first : nil)
                return StepContext(description: description, analysis: analysis, levelError: motion.levelError,
                                   cameraPitch: motion.cameraPitch, shake: motion.shake, person: person,
                                   subjectBox: subjects.subject?.box ?? person?.box)
            }
            // Silent automatic settings from the active suggestion + live scene. The lens only
            // follows the suggestion once guiding has started.
            let guiding = stage.stage == .guiding || stage.stage == .ready
            autoSettings.update(rule: stage.active ?? stage.cards.first?.suggestion, lensFollowsRule: guiding,
                                description: description, analysis: analysis, camera: camera,
                                iso: camera.stats.iso, shake: motion.shake, subjectBox: subjects.subject?.box)        }
    }

    private var topBar: some View {
        HStack {
            SubjectChip(stage: stage, override: subjectOverride, objectNames: objectNames, personTypes: personTypes,
                        subjects: describer.subjects,
                        onUnlock: { stage.unlock(subjects: describer.subjects, guide: guide, reason: "you unlocked") },
                        onForce: { category in
                            subjectOverride.set(category)
                            stage.unlock(subjects: describer.subjects, guide: guide, reason: "you changed the subject")
                        },
                        onRename: { label, name in renameObject(label, to: name) })
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 50)
    }

    private var viewfinder: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreview(camera: camera)
                // Clean screen while searching: guides appear once a subject is locked.
                if showGrid && stage.stage != .searching { GridOverlay() }
                if showLevel && stage.stage != .searching { LevelOverlay(motion: motion) }
                if showDebugOverlay { DetectionOverlay(analyzer: analyzer, camera: camera) }
                SubjectBrackets(tracker: describer.subjects, camera: camera)
                HoldStillOverlay(engine: autoSettings)
                StepArrowOverlay(guide: guide, camera: camera, subjectBox: {
                    let latest = analyzer.latest
                    let person = describer.subjects.lockedPerson(in: latest) ?? latest.people.first
                    return person?.faceBox ?? person?.box ?? describer.subjects.subject?.box ?? latest.objects.first?.box
                })
                VStack {
                    if stage.stage == .guiding || stage.stage == .ready {
                        CoachingPill(guide: guide) { stage.cancelSuggestion(guide: guide) }
                            .padding(.top, 8)
                    }
                    Spacer()
                }
                if let point = focusPoint {
                    FocusIndicator(point: point).id(point.x + point.y * 10_000)
                }
                // Screen flash when the shutter fires.
                Color.black.opacity(camera.shutterFlash ? 0.8 : 0)
                    .allowsHitTesting(false)
                if showDebugOverlay {
                    VStack {
                        HStack {
                            DebugOverlay(camera: camera, stats: camera.stats, motion: motion, analyzer: analyzer,
                                         live: describer.live, stage: stage, guide: guide, autoSettings: autoSettings)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 70)   // Below the coaching pill.
                }
                VStack {
                    Spacer()
                    IdentifyBar(controller: identify, analyzer: analyzer, tracker: objectNames)
                }
                if photosBlocked {
                    VStack {
                        Spacer()
                        photosBlockedBanner
                    }
                } else if let message = camera.lastSaveMessage {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.footnote.bold())
                            .padding(8)
                            .background(.red.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 10)
                    }
                }
            }
            .contentShape(Rectangle())
            // Tap: focus there. Tapping a different person/object locks onto it instead;
            // tapping empty space only focuses (it never unlocks).
            .onTapGesture(coordinateSpace: .local) { location in
                focusPoint = location
                camera.focus(atLayerPoint: location)
                autoSettings.userTapped()
                if let point = camera.uprightPoint(fromLayerPoint: location) {
                    handleTap(at: point)
                    offerIdentify(at: point)
                }
            }
            .gesture(pinchToZoom)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)   // Same shape as the photo: what you see is what you get.
        .clipped()
    }

    /// After a tap: if the thing isn't confidently named on the phone, offer the free
    /// "Look Up" (then "Identify with AI" only if that fails). Named things and people: nothing.
    private func offerIdentify(at point: CGPoint) {
        if let label = objectNames.label(at: point) {
            if label.sure {
                identify.dismiss()
            } else {
                identify.offer(region: label.box, labelID: label.id, localGuess: label.name)
            }
        } else if !analyzer.latest.people.contains(where: { $0.box.contains(point) }) {
            let side: CGFloat = 0.3
            identify.offer(region: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side)
                .clampedToUnit, labelID: nil, localGuess: nil)
        } else {
            identify.dismiss()
        }
    }
    /// Lock onto the tapped person/object if it isn't already the subject.
    private func handleTap(at point: CGPoint) {
        let latest = analyzer.latest
        let subjects = describer.subjects
        let hitPerson = latest.people.filter { $0.box.contains(point) }.min { $0.box.area < $1.box.area }
        let hitObject = latest.objects.filter { $0.box.contains(point) }.min { $0.box.area < $1.box.area }
        let target: (SubjectTracker.Kind, CGRect)?
        if let object = hitObject, hitPerson == nil || object.box.area < hitPerson!.box.area {
            target = (.object(label: object.label), object.box)
        } else if let person = hitPerson {
            target = (.person, person.box)
        } else {
            target = nil
        }
        guard let target else { return }
        let (kind, box) = target
        if let current = subjects.subject, current.box.iou(box) > 0.5 { return }   // Already the subject.
        let description = describer.live.description
        let tags = SuggestionRanker.sceneTags(description: description, analysis: latest,
                                              personTypes: personTypes.currentTypes)
        stage.relock(to: kind, box: box, analysis: latest, tags: tags, subjects: subjects, guide: guide)
    }

    /// Your correction of the locked object's name (remembered with its fingerprint).
    private func renameObject(_ label: ObjectLabel, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        objectNames.assign(id: label.id, name: clean, source: .you)
        if let print = analyzer.featurePrint(crop: label.box) {
            ObjectMemory.shared.add(name: clean, source: .you, detectorLabel: label.name, print: print)
        }
    }

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? camera.zoom
                if pinchStartZoom == nil { pinchStartZoom = start }
                let target = min(max(start * value.magnification, camera.minDisplayZoom), camera.maxDisplayZoom)
                autoSettings.userChangedLens()
                camera.setZoom(target, smooth: false)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    private var lensButtons: some View {
        HStack(spacing: 10) {
            ForEach(camera.lensOptions) { option in
                let selected = isSelected(option)
                Button {
                    autoSettings.userChangedLens()
                    camera.setZoom(option.zoom, smooth: true)
                } label: {
                    Text(selected ? zoomLabel : option.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(width: selected ? 46 : 38, height: selected ? 46 : 38)
                        .background(.white.opacity(0.15), in: Circle())
                }
                .animation(.easeOut(duration: 0.15), value: selected)
            }
        }
        .padding(.vertical, 10)
    }

    /// The button closest to the current zoom lights up. While pinching it shows
    /// the exact zoom, e.g. "2.7x".
    private func isSelected(_ option: LensOption) -> Bool {
        let nearest = camera.lensOptions.min { abs($0.zoom - camera.zoom) < abs($1.zoom - camera.zoom) }
        return nearest == option
    }

    private var zoomLabel: String {
        let z = camera.zoom
        if abs(z - z.rounded()) < 0.05 { return "\(Int(z.rounded()))x" }
        return String(format: "%.1fx", z)
    }

    private var bottomBar: some View {
        HStack {
            // Last photo thumbnail. Tapping opens the Photos app.
            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: {
                Group {
                    if let image = camera.lastThumbnail {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity)

            GuidedShutterButton(guide: guide, action: takePhoto)
                .frame(maxWidth: .infinity)

            Button {
                stage.unlock(subjects: describer.subjects, guide: guide, reason: "camera flipped")
                camera.flipCamera()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.15), in: Circle())
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.bottom, 24)
        .padding(.top, 8)
    }

    private var permissionDenied: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 48)).foregroundStyle(.gray)
            Text("Coach Cam needs the camera")
                .font(.title3.bold()).foregroundStyle(.white)
            Text("Turn on Camera for Coach Cam in Settings.")
                .foregroundStyle(.gray)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    /// Shown when Photos access is off, so photos can't be saved.
    private var photosBlockedBanner: some View {
        VStack(spacing: 6) {
            Text("Photos access is off — photos can't be saved")
                .font(.footnote.bold())
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .font(.footnote.bold())
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.black)
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
        .padding(10)
    }

    private func refreshPhotosBlocked() {
        let status = PhotoLibrary.addStatus
        photosBlocked = status == .denied || status == .restricted
    }

    /// Shutter pressed. The first time, this is where the Photos permission pop-up appears;
    /// the photo is taken as soon as you tap Allow.
    private func takePhoto() {
        switch PhotoLibrary.addStatus {
        case .notDetermined:
            Task { @MainActor in
                let status = await PhotoLibrary.requestAddAccess()
                refreshPhotosBlocked()
                if status == .authorized || status == .limited { shoot() }
            }
        case .denied, .restricted:
            Log.warn("Shutter pressed but Photos access is \(PhotoLibrary.name(of: PhotoLibrary.addStatus))")
            photosBlocked = true
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            shoot()
        }
    }

    /// Takes the picture with the automatic settings: a night merge when it's very dark and
    /// steady, otherwise one photo at the quality level M3 picked.
    private func shoot() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if autoSettings.useNightMerge {
            guard !autoSettings.holdingStill else { return }
            autoSettings.holdingStill = true
            camera.captureNightMerge(frames: AppConfig.shared.auto.nightMergeFrames) { _ in
                autoSettings.holdingStill = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        } else {
            camera.capturePhoto(quality: autoSettings.captureQuality)
        }
        if stage.stage != .searching { stage.photoTaken(guide: guide) }
    }
}

/// The shutter, with its ring turning green ("Take it") when every guide step is done.
struct GuidedShutterButton: View {
    @ObservedObject var guide: StepGuide
    let action: () -> Void

    var body: some View {
        ShutterButton(action: action, ringColor: guide.allDone ? .green : .white)
            .animation(.easeOut(duration: 0.2), value: guide.allDone)
    }
}

/// The big round shutter.
struct ShutterButton: View {
    let action: () -> Void
    var ringColor: Color = .white

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(ringColor, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64)
            }
        }
        .buttonStyle(ShutterPressStyle())
        .accessibilityLabel("Take photo")
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
