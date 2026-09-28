import SwiftUI

/// Corner brackets around the subject you tapped. Shown whenever a subject is locked.
struct SubjectBrackets: View {
    @ObservedObject var tracker: SubjectTracker
    let camera: CameraService

    var body: some View {
        Canvas { context, _ in
            guard let subject = tracker.subject, let rect = camera.layerRect(fromUpright: subject.box) else { return }
            let r = rect.insetBy(dx: -4, dy: -4)
            let arm = min(22, r.width / 3, r.height / 3)
            var path = Path()
            for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                     (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                path.move(to: CGPoint(x: corner.x + arm * dx, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * dy))
            }
            context.stroke(path, with: .color(.yellow), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.08), value: tracker.subject?.box.minX)
    }
}

/// Debug drawing of everything the analyzer found: people (green), faces (cyan) with
/// landmarks, body joints, objects (orange, with label) and the saliency box (dashed).
struct DetectionOverlay: View {
    @ObservedObject var analyzer: SceneAnalyzer
    let camera: CameraService

    var body: some View {
        Canvas { context, _ in
            let a = analyzer.latest

            for person in a.people {
                if let r = camera.layerRect(fromUpright: person.box) {
                    context.stroke(Path(r), with: .color(.green.opacity(0.9)), lineWidth: 1.5)
                }
                if let face = person.faceBox, let r = camera.layerRect(fromUpright: face) {
                    context.stroke(Path(r), with: .color(.cyan), lineWidth: 1.5)
                }
                if let top = person.headTopY,
                   let p = camera.layerPoint(fromUpright: CGPoint(x: person.box.midX, y: top)) {
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.pink))
                }
                for point in person.joints.values {
                    if let p = camera.layerPoint(fromUpright: point) {
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                                     with: .color(.green))
                    }
                }
                for point in person.faceLandmarks {
                    if let p = camera.layerPoint(fromUpright: point) {
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                                     with: .color(.cyan))
                    }
                }
            }

            for object in a.objects {
                guard let r = camera.layerRect(fromUpright: object.box) else { continue }
                context.stroke(Path(r), with: .color(.orange), lineWidth: 1.5)
                let text = Text("\(object.label) \(Int(object.confidence * 100))%")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange)
                context.draw(text, at: CGPoint(x: r.minX + 2, y: r.minY - 7), anchor: .leading)
            }

            if let salient = a.salientBox, let r = camera.layerRect(fromUpright: salient) {
                context.stroke(Path(r), with: .color(.white.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .allowsHitTesting(false)
    }
}
