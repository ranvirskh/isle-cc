import AppKit
import IsleCore

/// Tracks which displays have the frontmost app in a full-screen Space. Checked only when the active app, Space or
/// display layout changes, never on a timer.
@MainActor
final class FullScreenMonitor: ObservableObject {
    @Published private(set) var displays: Set<CGDirectDisplayID> = []
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?

    func isFullScreen(_ display: CGDirectDisplayID?) -> Bool { display.map(displays.contains) ?? false }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        })
        schedule()
    }

    /// Space switches animate; look again once the new Space has settled.
    private func schedule() {
        pending?.cancel()
        evaluate()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate() } }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    private func evaluate() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let all: [FullScreenDetector.Window] = list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, let layer = w[kCGWindowLayer as String] as? Int,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) else { return nil }
            return .init(ownerPID: pid, layer: layer, frame: rect)
        }
        var found: Set<CGDirectDisplayID> = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            // Window bounds are in the global top-left coordinate space, the same one CGDisplayBounds uses.
            let bounds = CGDisplayBounds(id)
            let here = all.filter { bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
            // The menu bar window (level 24) sits at the top of the display while it is showing and is moved away in full screen.
            let menuBarVisible = here.contains { $0.layer == 24 && $0.frame.height > 0 && abs($0.frame.minY - bounds.minY) <= 1 && $0.frame.width >= bounds.width - 2 }
            let full = FullScreenDetector.isFullScreen(windows: here, frontmostPID: front, screenFrame: bounds, safeAreaTop: screen.safeAreaInsets.top, menuBarVisible: menuBarVisible)
            if full { found.insert(id) }
        }
        if found != displays { displays = found; Log.write("fullscreen displays: \(found.sorted())") }
    }
}
