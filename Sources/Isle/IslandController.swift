import AppKit
import Combine
import SwiftUI
import IsleCore

final class IslandPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

/// Owns the island panel: placement, mouse tracking, the state machine, pop-ups and drag detection.
@MainActor
final class IslandController {
    let model: IslandModel
    private let env: AppEnv
    private let settings = Settings.shared
    private var panel: IslandPanel!
    private var hosting: NSHostingView<AnyView>!

    private var machine = IslandStateMachine()
    private var popups = PopupQueue()
    private var hoverTimer: Timer?
    private var collapseTimer: Timer?
    private var popupTimer: Timer?
    private var popupGapWork: DispatchWorkItem?
    private var popupClearWork: DispatchWorkItem?
    private var contentWork: DispatchWorkItem?

    private var monitors: [Any] = []
    private var hoveredFlag = false
    private var dragStartChangeCount = 0
    private var pointerDown = false
    private var ownDragPoll: Timer?
    private var currentScreenID: CGDirectDisplayID?
    private var cancellables = Set<AnyCancellable>()
    private var chargingBrief = false
    private var chargingBriefWork: DispatchWorkItem?
    private var wasCharging = false

    init(env: AppEnv) {
        self.env = env
        let screen = Self.pickScreen(choice: Settings.shared.displayChoice)
        model = IslandModel(screen: ScreenInfo(screen))
        currentScreenID = screen.displayID
    }

    // MARK: Setup

    func start() {
        model.agentsEnabled = settings.agentsEnabled
        model.theme = settings.theme
        applySettings()
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        self.panel = panel

        let root = IslandRootView().environmentObject(env.weather).environmentObject(model).environmentObject(env).environmentObject(env.media)
            .environmentObject(env.calendar).environmentObject(env.devices).environmentObject(env.agents).environmentObject(env.usage)
            .environmentObject(env.shelf).environmentObject(settings)
        hosting = NSHostingView(rootView: AnyView(root))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting
        positionWindow()
        panel.orderFrontRegardless()

        installMonitors()
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        nc.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                self?.applySettings()
                self?.updateLive()
                if (n.object as? String) == SettingsKey.displayChoice { self?.screensChanged(force: true) }
                if (n.object as? String) == SettingsKey.agentsEnabled { self?.agentsToggled() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged(force: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless(); self?.updateMouse() }
        }
        updateReduceMotion()
        env.media.$now.map { $0?.isPlaying ?? false }.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLive() } }.store(in: &cancellables)
        env.devices.$battery.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] b in MainActor.assumeIsolated { self?.batteryChanged(b) } }.store(in: &cancellables)
        env.downloads.$summary.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLive() } }.store(in: &cancellables)
        env.privacy.$state.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLive() } }.store(in: &cancellables)
        env.fullScreen.$isFullScreen.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateLive() } }.store(in: &cancellables)
        env.usage.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateLive() } } }.store(in: &cancellables)
        updateLive()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateReduceMotion() }
        }
    }

    /// Decides what the collapsed island shows. Media (cover, equalizer, song banner) stays quiet while the user is in
    /// a full-screen Space; the privacy dots do not, because they are about safety rather than music.
    private func updateLive() {
        let media = settings.liveActivity && (env.media.now?.isPlaying ?? false) && !env.fullScreen.isFullScreen
        let privacy = settings.privacyIndicator && env.privacy.state.isActive
        let battery = env.devices.battery
        var charging = false
        switch settings.chargingIndicator {
        case .off: charging = false
        case .whileCharging: charging = battery.hasBattery && battery.isCharging
        case .brief: charging = chargingBrief && battery.isCharging
        }
        let download = settings.downloadsIndicator ? env.downloads.summary : nil
        let usage = env.usage.pillPercent
        let live = media || privacy || charging || download != nil || usage != nil
        guard media != model.mediaLive || privacy != model.privacyLive || live != model.liveActive
                || env.privacy.state != model.privacy || usage != model.usagePercent || charging != model.chargingLive || battery != model.battery || download != model.download else { return }
        withAnimation(Motion.spring(Motion.popup, .media)) {
            model.mediaLive = media
            model.privacyLive = privacy
            model.chargingLive = charging
            model.download = download
            model.battery = battery
            model.privacy = env.privacy.state
            model.usagePercent = usage
            model.liveActive = live
        }
    }

    private func batteryChanged(_ b: BatteryState) {
        if b.isCharging && !wasCharging {
            // Plugged in: the brief mode shows the indicator for a few seconds.
            chargingBrief = true
            chargingBriefWork?.cancel()
            let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.chargingBrief = false; self?.updateLive() } }
            chargingBriefWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + ChargingIndicatorMode.briefDuration, execute: w)
        }
        wasCharging = b.isCharging
        updateLive()
    }

    private func updateReduceMotion() { Motion.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func applySettings() {
        if model.theme != settings.theme { withAnimation(Motion.spring(Motion.tabResize, .tabs)) { model.theme = settings.theme } }
        machine.trigger = settings.expandTrigger
        machine.hoverDelay = Motion.scaled(settings.hoverDelay)
        machine.collapseDelay = Motion.scaled(Motion.collapseDelay)
    }

    private func agentsToggled() {
        model.agentsEnabled = settings.agentsEnabled
        if !settings.agentsEnabled, model.tab == .agents { model.tab = .home }
        positionWindow()
    }

    // MARK: Screens

    static func pickScreen(choice: String) -> NSScreen {
        let screens = NSScreen.screens
        if choice == "main", let s = NSScreen.main ?? screens.first { return s }
        if choice != "cursor", choice != "main", let s = screens.first(where: { $0.uuidString == choice }) { return s }
        let idx = NotchGeometry.screenIndex(containing: NSEvent.mouseLocation, frames: screens.map(\.frame))
        return idx.map { screens[$0] } ?? NSScreen.main ?? screens[0]
    }

    private func screensChanged(force: Bool = false) {
        guard !NSScreen.screens.isEmpty else { return }
        let target = Self.pickScreen(choice: settings.displayChoice)
        let info = ScreenInfo(target)
        if force || info != model.screen || target.displayID != currentScreenID {
            if machine.phase != .collapsed { handle(.forceCollapse) }
            model.screen = info
            currentScreenID = target.displayID
            positionWindow()
        }
    }

    private func positionWindow() {
        let frame = NotchGeometry.openWindowFrame(model.screen, contentSize: model.maxContentSize)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        updateMouse()
    }

    // MARK: Mouse

    private func installMonitors() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseEvent(e) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseEvent(e) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerDown = true; self?.dragStartChangeCount = NSPasteboard(name: .drag).changeCount }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerUp() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.localMouseDown(e) }
            return e
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.pointerUp() }
            return e
        }) { monitors.append(m) }
    }

    private func mouseEvent(_ e: NSEvent) {
        if e.type == .leftMouseDragged || e.type == .rightMouseDragged { dragMoved() }
        updateMouse()
    }

    private func hoverRegion() -> CGRect {
        switch machine.phase {
        case .collapsed: return NotchGeometry.topAnchoredFrame(model.screen, size: model.shapeSize).insetBy(dx: -2, dy: -2)
        case .popup: return NotchGeometry.topAnchoredFrame(model.screen, size: model.shapeSize).insetBy(dx: -2, dy: -2)
        case .expanded: return NotchGeometry.expandedHoverRect(model.screen, contentSize: model.shapeSize)
        }
    }

    private func updateMouse() {
        let p = NSEvent.mouseLocation
        // Follow the cursor to another display, but only while idle.
        if settings.displayChoice == "cursor", machine.phase == .collapsed, !hoveredFlag, !machine.isDragging,
           let idx = NotchGeometry.screenIndex(containing: p, frames: NSScreen.screens.map(\.frame)),
           NSScreen.screens[idx].displayID != currentScreenID {
            screensChanged(force: true)
        }
        let inside = hoverRegion().contains(p)
        if inside != hoveredFlag {
            hoveredFlag = inside
            handle(inside ? .mouseEntered : .mouseExited)
        }
        let accept = inside || machine.isDragging
        if panel.ignoresMouseEvents == accept { panel.ignoresMouseEvents = !accept }
    }

    private func localMouseDown(_ e: NSEvent) {
        guard e.window === panel else { return }
        if machine.phase != .expanded { handle(.clicked) }
    }

    // MARK: Drag from other apps

    private func dragMoved() {
        guard pointerDown, !machine.isDragging else { return }
        let board = NSPasteboard(name: .drag)
        guard board.changeCount != dragStartChangeCount, !(board.types ?? []).isEmpty else { return }
        if NotchGeometry.dragActivationRect(model.screen).contains(NSEvent.mouseLocation) {
            model.externalDrag = true
            withAnimation(Motion.spring(Motion.tabResize, .tabs)) { handleDragApproached() }
        }
    }

    private func handleDragApproached() {
        popupGapWork?.cancel()
        panel.ignoresMouseEvents = false
        handle(.dragApproached)
    }

    private func pointerUp() {
        pointerDown = false
        guard machine.isDragging else { return }
        // Give the drop a moment to land before the zones disappear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.externalDrag = false
                self.handle(.dragEnded)
            }
        }
    }

    /// A drag that starts inside the island (shelf item going out). Keeps it open until the button is released.
    func beginOwnDrag() {
        handle(.dragApproached)
        ownDragPoll?.invalidate()
        ownDragPoll = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
                t.invalidate()
                self?.ownDragPoll = nil
                self?.handle(.dragEnded)
                self?.updateMouse()
            }
        }
    }

    // MARK: State machine

    func handle(_ event: IslandStateMachine.Event) {
        let before = machine.phase
        let effects = machine.handle(event)
        for effect in effects { perform(effect) }
        if machine.phase != before { phaseChanged(from: before, to: machine.phase) }
        if machine.phase == .collapsed { schedulePopupCheck(delay: 0.05) }
        updateKeyability()
    }

    private func perform(_ effect: IslandStateMachine.Effect) {
        switch effect {
        case .startHoverTimer(let t):
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.hoverTimerFired) }
            }
        case .cancelHoverTimer: hoverTimer?.invalidate(); hoverTimer = nil
        case .startCollapseTimer(let t):
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.collapseTimerFired) }
            }
        case .cancelCollapseTimer: collapseTimer?.invalidate(); collapseTimer = nil
        case .startPopupTimer(let t):
            popupTimer?.invalidate()
            popupTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.handle(.popupTimerFired) }
            }
        case .cancelPopupTimer: popupTimer?.invalidate(); popupTimer = nil
        case .popupFinished:
            popups.finishCurrent()
            schedulePopupCheck(delay: Motion.scaled(Motion.popupGap) + 0.2)
        }
    }

    private func phaseChanged(from old: IslandStateMachine.Phase, to new: IslandStateMachine.Phase) {
        Log.write("island: \(old) -> \(new)")
        contentWork?.cancel()
        popupClearWork?.cancel()
        let spring: Motion.Spring
        switch (old, new) {
        case (_, .collapsed): spring = Motion.collapse
        case (_, .popup): spring = Motion.popup
        default: spring = Motion.expand
        }
        let showContent = new != .collapsed
        withAnimation(Motion.spring(spring)) { model.phase = new }
        if showContent {
            // Content follows the shape: a short delay, then fade/scale/unblur in.
            withAnimation(Motion.easeOut(Motion.contentInDuration, delay: old == .collapsed ? Motion.contentInDelay : 0)) { model.contentVisible = true }
        } else {
            withAnimation(Motion.ease(Motion.contentOutDuration, .content)) { model.contentVisible = false }
            popupClearWork = DispatchWorkItem { [weak self] in self?.model.popup = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.scaled(0.6), execute: popupClearWork!)
        }
        // Tab reset and key release on collapse.
        if new == .collapsed { model.externalDrag = machine.isDragging ? model.externalDrag : false }
    }

    func setTab(_ tab: IslandTab) {
        guard tab != model.tab else { return }
        withAnimation(Motion.spring(Motion.tabResize, .tabs)) { model.tab = tab }
        updateKeyability()
    }

    /// The panel may take key focus only while the user is working in the Shelf, so Space can open Quick Look.
    func requestKey() {
        guard machine.phase == .expanded else { return }
        panel.allowKey = true
        panel.makeKey()
    }

    private func updateKeyability() {
        if machine.phase != .expanded || model.tab != .shelf {
            if panel.allowKey { panel.allowKey = false; if panel.isKeyWindow { panel.resignKey() } }
        }
    }

    var currentWindow: NSWindow? { panel }

    // MARK: Pop-ups

    func enqueuePopup(_ item: PopupItem) {
        Log.write("popup queued: \(item.kind.rawValue) \(item.title)")
        popups.enqueue(item)
        schedulePopupCheck(delay: 0.05)
    }

    private func schedulePopupCheck(delay: TimeInterval) {
        popupGapWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.presentNextPopup() } }
        popupGapWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func presentNextPopup() {
        guard let item = popups.dequeue(canPresent: machine.canPresentPopup && popups.current == nil) else { return }
        // A banner for a song that is no longer playing is stale.
        if item.kind == .nowPlaying, env.media.now.map({ "np-" + $0.track.identity }) != item.id {
            popups.finishCurrent()
            schedulePopupCheck(delay: 0.05)
            return
        }
        popupClearWork?.cancel()
        model.popup = item
        machine.popupDuration = item.kind == .nowPlaying ? Motion.scaled(Motion.bannerDuration) : Motion.popupDuration
        handle(.popupRequested)
        if machine.phase != .popup { popups.finishCurrent(); model.popup = nil }
    }

    /// A new song started: show the banner once its cover has arrived (or after a short wait).
    func songStarted(_ track: TrackInfo) {
        guard settings.songBanner, machine.phase == .collapsed, !env.fullScreen.isFullScreen else { return }
        popups.removeAll(kind: .nowPlaying)
        let item = PopupItem(id: "np-" + track.identity, kind: .nowPlaying, symbol: "music.note", title: track.title, subtitle: track.artist)
        DispatchQueue.main.asyncAfter(deadline: .now() + (env.media.artwork == nil ? 0.5 : 0.05)) { [weak self] in
            MainActor.assumeIsolated { self?.enqueuePopup(item) }
        }
    }

    // MARK: Test hooks

    func debugExpand(tab: IslandTab? = nil) {
        if let tab { model.tab = tab }
        handle(.forceExpand)
    }
    func debugCollapse() { handle(.forceCollapse) }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
    var uuidString: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
