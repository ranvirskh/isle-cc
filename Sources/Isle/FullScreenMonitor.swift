import AppKit
import IsleCore

/// Tracks whether the frontmost app is in a full-screen Space on the island's display. Checked only when the
/// active app or Space changes, never on a timer.
@MainActor
final class FullScreenMonitor: ObservableObject {
    @Published private(set) var isFullScreen = false
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?

    func start(screen: @escaping () -> ScreenInfo) {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule(screen) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule(screen) }
        })
        schedule(screen)
    }

    /// Space switches animate; look again once the new Space has settled.
    private func schedule(_ screen: @escaping () -> ScreenInfo) {
        pending?.cancel()
        evaluate(screen())
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate(screen()) } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    private func evaluate(_ info: ScreenInfo) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows: [FullScreenDetector.Window] = list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, let layer = w[kCGWindowLayer as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
            return .init(ownerPID: pid, layer: layer, frame: rect)
        }
        // The menu bar window (level 24) sits at the top of the display while it is showing and is moved away in full screen.
        let menuBarVisible = list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == 24,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) else { return false }
            return rect.height > 0 && rect.minY >= info.frame.minY - 1 && rect.minY <= info.frame.minY + 1 && rect.width >= info.frame.width - 2
        }
        let full = FullScreenDetector.isFullScreen(windows: windows, frontmostPID: front, screenFrame: info.frame, safeAreaTop: info.safeAreaTop,
                                                   menuBarVisible: menuBarVisible)
        if full != isFullScreen { isFullScreen = full; Log.write("fullscreen: \(full)") }
    }
}
