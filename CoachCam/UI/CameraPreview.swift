import AVFoundation
import SwiftUI

/// Shows the live camera feed. The actual drawing is done by AVFoundation
/// (AVCaptureVideoPreviewLayer) on the GPU, so it stays smooth no matter what
/// our analysis code is doing.
struct CameraPreview: UIViewRepresentable {
    let camera: CameraService

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspectFill
        camera.attachPreview(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
