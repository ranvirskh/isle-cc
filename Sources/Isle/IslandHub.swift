import AppKit
import IsleCore

/// One island per display. With "Show the island on external displays" off there is a single island on the built-in
/// display; with it on, every connected display gets its own, each with its own panel, hover state and pop-ups.
/// Everything outside this file talks to the hub, which forwards to the right island.
@MainActor
final class IslandHub {
    private let env: AppEnv
    private var controllers: [CGDirectDisplayID: IslandController] = [:]
    private var started = false

    init(env: AppEnv) { self.env = env }

    var all: [IslandController] { NSScreen.screens.compactMap { $0.displayID.flatMap { controllers[$0] } } }

    /// The island that shows built-in-display content first (or any, when only external displays are connected).
    var primary: IslandController? {
        all.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false } ?? all.first
    }

    /// The island the user is working with: the one under the pointer, then an open one, then the primary.
    var active: IslandController? {
        let p = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(p) }), let id = s.displayID, let c = controllers[id] { return c }
        return all.first { $0.phase == .expanded } ?? primary
    }

    func start() {
        started = true
        sync()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        nc.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let k = n.object as? String, k == SettingsKey.externalDisplays || k == SettingsKey.hiddenDisplays { self?.sync() } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    /// Creates an island for each display that should have one and removes the rest.
    private func sync() {
        guard started else { return }
        let wanted = NSScreen.screens.filter(IslandController.isAllowed)
        let wantedIDs = Set(wanted.compactMap(\.displayID))
        for (id, c) in controllers where !wantedIDs.contains(id) { c.stop(); controllers[id] = nil }
        for screen in wanted {
            guard let id = screen.displayID, controllers[id] == nil else { continue }
            let c = IslandController(env: env, screen: screen)
            controllers[id] = c
            c.start()
        }
    }

    // MARK: Forwarded to every island

    func showHUD(_ hud: HUDState) { all.forEach { $0.showHUD(hud) } }
    func enqueuePopup(_ item: PopupItem) { all.forEach { $0.enqueuePopup(item) } }
    func songStarted(_ track: TrackInfo) { all.forEach { $0.songStarted(track) } }

    // MARK: Forwarded to the island in use

    func toggleFromShortcut() { active?.toggleFromShortcut() }
    func showTab(index: Int) { active?.showTab(index: index) }
    func setTab(_ tab: IslandTab) { active?.setTab(tab) }
    func requestKey() { active?.requestKey() }
    func releaseKey() { all.forEach { $0.releaseKey() } }
    func beginOwnDrag() { active?.beginOwnDrag() }

    // MARK: Test hooks

    var currentWindow: NSWindow? { primary?.currentWindow }
    func debugExpand(tab: IslandTab? = nil) { primary?.debugExpand(tab: tab) }
    func debugCollapse() { all.forEach { $0.debugCollapse() } }
    var screenInfo: ScreenInfo { primary?.model.screen ?? ScreenInfo(NSScreen.main ?? NSScreen.screens[0]) }
}
