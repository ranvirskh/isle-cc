import AVFoundation
import AppKit

/// Camera preview for a quick look at yourself. The camera runs only while the Mirror tab is on screen.
@MainActor
final class MirrorController: ObservableObject {
    enum State { case idle, running, denied, noCamera }
    @Published private(set) var state: State = .idle
    let session = AVCaptureSession()
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async { MainActor.assumeIsolated { if ok { self?.run() } else { self?.state = .denied } } }
            }
        default: state = .denied
        }
    }

    private func run() {
        if !configured {
            guard let device = AVCaptureDevice.default(for: .video) ?? AVCaptureDevice.default(.external, for: .video, position: .unspecified),
                  let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { state = .noCamera; return }
            session.beginConfiguration()
            session.sessionPreset = .medium
            session.addInput(input)
            session.commitConfiguration()
            configured = true
        }
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if !s.isRunning { s.startRunning() } }
        state = .running
    }

    func stop() {
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { if s.isRunning { s.stopRunning() } }
        if state == .running { state = .idle }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
    }
}
