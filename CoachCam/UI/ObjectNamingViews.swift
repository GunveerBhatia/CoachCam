import SwiftUI
import VisionKit

/// Names above objects, like the person labels: "keys", or "keys?" when only medium-sure.
/// Tap one to pick another guess or type the right name (remembered for next time).
struct ObjectLabelsOverlay: View {
    @ObservedObject var tracker: ObjectLabelTracker
    let camera: CameraService
    let analyzer: SceneAnalyzer
    @State private var renaming: ObjectLabel?
    @State private var typedName = ""

    var body: some View {
        ZStack {
            ForEach(tracker.labels) { label in
                if let rect = camera.layerRect(fromUpright: label.box) {
                    Menu {
                        Section("What is this?") {
                            ForEach(label.alternatives.filter { $0 != label.name }, id: \.self) { name in
                                Button(name) { save(name, for: label) }
                            }
                            Button("Type a name…") {
                                typedName = label.name
                                renaming = label
                            }
                        }
                        if !label.sure || label.source == .detector {
                            Text("Source: \(label.source.rawValue), \(Int(label.confidence * 100))%")
                        }
                    } label: {
                        Text(label.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(label.sure ? Color.white : Color.yellow)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    .position(x: rect.midX, y: max(12, rect.minY - 12))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Name this object", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("e.g. car keys", text: $typedName)
            Button("Save") {
                if let label = renaming { save(typedName, for: label) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Coach Cam will remember it for similar-looking objects.")
        }
    }

    /// Your correction: shown now, and remembered with the object's fingerprint.
    private func save(_ name: String, for label: ObjectLabel) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        tracker.assign(id: label.id, name: clean, source: .you)
        if let print = analyzer.featurePrint(crop: label.box) {
            ObjectMemory.shared.add(name: clean, source: .you, detectorLabel: label.name, print: print)
        }
    }
}

/// The bar at the bottom of the viewfinder after tapping something unnamed:
/// "Look Up (free)" first; "Identify with AI" only if that fails.
struct IdentifyBar: View {
    @ObservedObject var controller: IdentifyController
    let analyzer: SceneAnalyzer
    let tracker: ObjectLabelTracker
    @State private var typing = false
    @State private var typedName = ""

    var body: some View {
        Group {
            switch controller.state {
            case .idle:
                EmptyView()
            case .offer:
                bar {
                    Button { controller.lookUp(analyzer: analyzer) } label: {
                        Label("Look Up (free)", systemImage: "info.circle").font(.footnote.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    nameButton
                }
            case .lookingUp:
                bar {
                    ProgressView().tint(.white)
                    Text("Asking Apple Look Up…").font(.footnote.bold())
                }
            case .lookUpReady:
                bar {
                    Text("Apple found something").font(.footnote.bold())
                    Button("Show") { controller.showLookUpSheet = true }.font(.footnote.bold())
                }
            case .lookUpFailed:
                bar {
                    Text("Apple couldn't name it.").font(.caption.bold())
                    aiButton
                    nameButton
                }
            case .loading:
                bar {
                    ProgressView().tint(.white)
                    Text("Asking Claude…").font(.footnote.bold())
                }
            case .result(let name, let detail, let source):
                bar(color: .purple) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name) · \(source)").font(.footnote.bold())
                        Text(detail).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    }
                }
            case .failed(let message):
                bar(color: .red) {
                    Text(message).font(.caption.bold()).lineLimit(2)
                    Button("Retry") { controller.identifyWithAI(analyzer: analyzer, tracker: tracker) }
                        .font(.caption.bold())
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.15), value: controller.state)
        .sheet(isPresented: $controller.showLookUpSheet) {
            LookUpSheet(controller: controller, analyzer: analyzer, tracker: tracker)
        }
        .alert("Name this object", isPresented: $typing) {
            TextField("e.g. car keys", text: $typedName)
            Button("Save") { controller.nameIt(typedName, analyzer: analyzer, tracker: tracker) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var aiButton: some View {
        Button { controller.identifyWithAI(analyzer: analyzer, tracker: tracker) } label: {
            Label("Identify with AI", systemImage: "sparkles").font(.caption.bold())
        }
        .buttonStyle(.borderedProminent)
        .tint(.purple)
    }

    private var nameButton: some View {
        Button("Name it") {
            typedName = ""
            typing = true
        }
        .font(.caption.bold())
    }

    private func bar<Content: View>(color: Color = .black, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
            Button { controller.dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(10)
        .background(color.opacity(color == .black ? 0.6 : 0.85), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Apple Visual Look Up on a still of the object. Tap Apple's ⓘ badge to see what it is,
/// then type the name so Coach Cam remembers it (apps can't read Look Up's answer directly).
struct LookUpSheet: View {
    @ObservedObject var controller: IdentifyController
    let analyzer: SceneAnalyzer
    let tracker: ObjectLabelTracker
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let image = controller.lookUpImage {
                    LookUpImageView(image: image, analysis: controller.lookUpAnalysis)
                        .frame(maxHeight: 380)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("Tap Apple's ⓘ badge on the photo to see what it is, then type the name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                TextField("Name (e.g. monstera plant)", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("Save name") { controller.nameIt(name, analyzer: analyzer, tracker: tracker) }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    controller.identifyWithAI(analyzer: analyzer, tracker: tracker)
                } label: {
                    Label("Still not sure? Identify with AI", systemImage: "sparkles")
                }
                .font(.footnote)
                Spacer()
            }
            .padding()
            .navigationTitle("Look Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }
}

/// A UIImageView with Apple's image-analysis interaction (the Look Up badge).
struct LookUpImageView: UIViewRepresentable {
    let image: UIImage
    let analysis: ImageAnalysis?

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isUserInteractionEnabled = true
        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = [.visualLookUp, .imageSubject]
        interaction.analysis = analysis
        view.addInteraction(interaction)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
