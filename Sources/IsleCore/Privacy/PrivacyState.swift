import Foundation

/// Which capture devices are in use right now. Built from system signals only; never from audio, video or screen content.
public struct PrivacyState: Equatable {
    public var microphone = false
    public var camera = false
    public var screen = false

    public init(microphone: Bool = false, camera: Bool = false, screen: Bool = false) {
        self.microphone = microphone
        self.camera = camera
        self.screen = screen
    }

    public var isActive: Bool { microphone || camera || screen }

    /// Active indicators in display order.
    public var active: [Kind] {
        var out: [Kind] = []
        if camera { out.append(.camera) }
        if microphone { out.append(.microphone) }
        if screen { out.append(.screen) }
        return out
    }

    public enum Kind: String, CaseIterable {
        case microphone, camera, screen

        public var symbol: String {
            switch self {
            case .microphone: return "mic.fill"
            case .camera: return "video.fill"
            case .screen: return "record.circle"
            }
        }
        public var title: String {
            switch self {
            case .microphone: return "Microphone in use"
            case .camera: return "Camera in use"
            case .screen: return "Screen is being recorded"
            }
        }
    }
}

public enum ScreenRecordingDetector {
    /// macOS puts "StatusIndicator" windows on screen while a screen recording or capture is running.
    /// The microphone and camera dots may be drawn the same way, so while either of those is active the
    /// windows cannot be attributed to the screen and it is reported as not recording (never a false alarm).
    public static func isRecording(statusIndicatorWindows: Int, microphone: Bool, camera: Bool) -> Bool {
        statusIndicatorWindows > 0 && !microphone && !camera
    }
}

/// Decides whether the app the user is looking at is in a full-screen Space (a "full-screen tab").
public enum FullScreenDetector {
    public struct Window: Equatable {
        public var ownerPID: Int32
        public var layer: Int
        public var frame: CGRect
        public init(ownerPID: Int32, layer: Int, frame: CGRect) {
            self.ownerPID = ownerPID
            self.layer = layer
            self.frame = frame
        }
    }

    /// A normal-layer window of the frontmost app that spans the whole display, either including the notch strip
    /// or starting just below it (full-screen windows on notched Macs sit under the camera housing).
    public static func isFullScreen(windows: [Window], frontmostPID: Int32?, screenFrame: CGRect, safeAreaTop: CGFloat) -> Bool {
        guard let frontmostPID else { return false }
        let tolerance: CGFloat = 2
        return windows.contains { w in
            guard w.ownerPID == frontmostPID, w.layer == 0, abs(w.frame.width - screenFrame.width) <= tolerance else { return false }
            let fullHeight = abs(w.frame.height - screenFrame.height) <= tolerance
            let belowNotch = safeAreaTop > 0 && abs(w.frame.height - (screenFrame.height - safeAreaTop)) <= tolerance
            return fullHeight || belowNotch
        }
    }
}
