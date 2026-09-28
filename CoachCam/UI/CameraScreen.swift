import AVKit
import SwiftUI

/// The main camera screen.
///
/// Layout (top to bottom):
///   top bar (settings) → 3:4 viewfinder with guides → lens buttons → thumbnail · shutter · flip
/// The coaching pill, mode badge and Ideas button join in later milestones.
struct CameraScreen: View {
    @StateObject private var camera = CameraService()
    // @State (not @StateObject) so this screen doesn't redraw 20×/second with the gyro;
    // only the views that show motion data observe it.
    @State private var motion = MotionService()

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
                    Spacer(minLength: 8)
                    lensButtons
                    bottomBar
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings) { SettingsView(camera: camera) }
        // Volume buttons and the Camera Control button take a photo.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { takePhoto() }
        }
        .onAppear {
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

    private var topBar: some View {
        HStack {
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
                if showGrid { GridOverlay() }
                if showLevel { LevelOverlay(motion: motion) }
                if let point = focusPoint {
                    FocusIndicator(point: point).id(point.x + point.y * 10_000)
                }
                // Screen flash when the shutter fires.
                Color.black.opacity(camera.shutterFlash ? 0.8 : 0)
                    .allowsHitTesting(false)
                if showDebugOverlay {
                    VStack {
                        HStack {
                            DebugOverlay(camera: camera, stats: camera.stats, motion: motion)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(6)
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
            .onTapGesture(coordinateSpace: .local) { location in
                focusPoint = location
                camera.focus(atLayerPoint: location)
            }
            .gesture(pinchToZoom)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)   // Same shape as the photo: what you see is what you get.
        .clipped()
    }

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? camera.zoom
                if pinchStartZoom == nil { pinchStartZoom = start }
                let target = min(max(start * value.magnification, camera.minDisplayZoom), camera.maxDisplayZoom)
                camera.setZoom(target, smooth: false)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    private var lensButtons: some View {
        HStack(spacing: 10) {
            ForEach(camera.lensOptions) { option in
                let selected = isSelected(option)
                Button {
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

            ShutterButton(action: takePhoto)
                .frame(maxWidth: .infinity)

            Button { camera.flipCamera() } label: {
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

    private func shoot() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        camera.capturePhoto()
    }
}

/// The big round shutter. In M7 its ring turns green when the shot is ready.
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
