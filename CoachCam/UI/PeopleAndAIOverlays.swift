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

