import SwiftUI

/// Small labels above each face ("woman", "kid", "person"…). Tap one to correct it.
struct PersonLabelsOverlay: View {
    @ObservedObject var tracker: PersonTypeTracker
    let camera: CameraService

    var body: some View {
        ZStack {
            ForEach(tracker.labels) { label in
                if let rect = camera.layerRect(fromUpright: label.faceBox) {
                    Menu {
                        Section("Who is this?") {
                            ForEach(PersonType.estimable) { type in
                                Button {
                                    tracker.correct(id: label.id, to: type)
                                } label: {
                                    if type == label.type { Label(type.rawValue, systemImage: "checkmark") } else { Text(type.rawValue) }
                                }
                            }
                            Button("Just \"person\"") { tracker.correct(id: label.id, to: .person) }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(label.type.rawValue)
                            if label.corrected { Image(systemName: "checkmark.circle.fill").font(.system(size: 9)) }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                    }
                    .position(x: rect.midX, y: max(12, rect.minY - 14))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The "Identify with AI" bar at the bottom of the viewfinder.
struct IdentifyBar: View {
    @ObservedObject var controller: IdentifyController
    let analyzer: SceneAnalyzer

    var body: some View {
        Group {
            switch controller.state {
            case .idle:
                EmptyView()
            case .offer:
                HStack(spacing: 8) {
                    Button {
                        controller.identify(using: analyzer)
                    } label: {
                        Label("Identify with AI", systemImage: "sparkles")
                            .font(.footnote.bold())
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    closeButton
                }
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Identifying…").font(.footnote.bold())
                }
                .padding(10)
                .background(.black.opacity(0.6), in: Capsule())
            case .result(let name, let confidence, let details):
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(name) · \(Int(confidence * 100))%").font(.footnote.bold())
                        Text(details).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    }
                    closeButton
                }
                .padding(10)
                .background(.purple.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            case .failed(let message):
                HStack(spacing: 8) {
                    Text(message).font(.caption.bold()).lineLimit(2)
                    Button("Retry") { controller.identify(using: analyzer) }
                        .font(.caption.bold())
                    closeButton
                }
                .padding(10)
                .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.15), value: controller.state)
    }

    private var closeButton: some View {
        Button { controller.dismiss() } label: {
            Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
        }
    }
}
