import SwiftUI
import AVFoundation

struct MirrorView: View {
    @EnvironmentObject var mirror: MirrorController
    @EnvironmentObject var model: IslandModel

    var body: some View {
        Group {
            switch mirror.state {
            case .running:
                CameraPreview(session: mirror.session)
                    .frame(width: 140, height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                note("Camera access is off", "Allow Isle in System Settings > Privacy & Security > Camera.", button: ("Open Privacy Settings", mirror.openPrivacySettings))
            case .noCamera:
                note("No camera found", "Connect a camera to use the mirror.")
            case .idle:
                note("Starting camera…", "")
            }
        }
        .foregroundStyle(.white)
        // The expanded views stay alive while the island is collapsed, so the camera follows the island's phase too.
        .onAppear { if model.phase == .expanded { mirror.start() } }
        .onChange(of: model.phase) { _, phase in if phase == .expanded { mirror.start() } else { mirror.stop() } }
        .onDisappear { mirror.stop() }
    }

    private func note(_ title: String, _ detail: String, button: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "person.crop.circle").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            if !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center) }
            if let button { Button(button.0, action: button.1).buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Mirrored (selfie) preview of the capture session. The preview layer is the view's own backing layer, and the
/// mirroring is applied on every layout because the layer only gets its connection once the session has an input.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: NSView {
        override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layout() {
            super.layout()
            if let c = previewLayer.connection, c.isVideoMirroringSupported {
                c.automaticallyAdjustsVideoMirroring = false
                c.isVideoMirrored = true
            }
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.wantsLayer = true
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateNSView(_ v: PreviewView, context: Context) {
        if v.previewLayer.session !== session { v.previewLayer.session = session }
        v.needsLayout = true
    }
}
