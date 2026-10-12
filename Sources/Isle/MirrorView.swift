import SwiftUI
import AVFoundation

struct MirrorView: View {
    @EnvironmentObject var mirror: MirrorController

    var body: some View {
        Group {
            switch mirror.state {
            case .running:
                CameraPreview(session: mirror.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            case .denied:
                note("Camera access is off", "Allow Isle in System Settings > Privacy & Security > Camera.", button: ("Open Privacy Settings", mirror.openPrivacySettings))
            case .noCamera:
                note("No camera found", "Connect a camera to use the mirror.")
            case .idle:
                note("Starting camera…", "")
            }
        }
        .foregroundStyle(.white)
        .onAppear { mirror.start() }
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

/// Mirrored (selfie) preview of the capture session.
private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        if let c = layer.connection, c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = true }
        v.layer = layer
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
