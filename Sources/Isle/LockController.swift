import AppKit
import SwiftUI
import IsleCore

final class LockPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the now-playing card on the lock screen. Display only: the window ignores every mouse event, never
/// becomes key or main, and has no controls. The private SkyLight calls live in `LockWindowElevator`.
@MainActor
final class LockController {
    private var machine: LockStateMachine
    private let media: MediaController
    private let settings = Settings.shared
    private let elevator: LockWindowElevator
    private var panel: LockPanel?
    // Status widgets use their own copy of the same state machine, fed as "something is always playing", so the lock,
    // sleep and session rules are identical and tested once.
    private var widgetMachine: LockStateMachine
    private var widgetPanel: LockPanel?
    weak var env: AppEnv?
    let simulate: Bool

    var isSupported: Bool { simulate || elevator.isSupported }
    var unsupportedReason: String? { elevator.isSupported ? nil : elevator.unsupportedReason }

    init(media: MediaController, simulate: Bool, elevator: LockWindowElevator = SkyLightLockWindowElevator()) {
        self.media = media
        self.simulate = simulate
        self.elevator = elevator
        machine = LockStateMachine(enabled: Settings.shared.lockScreenEnabled, supported: simulate || elevator.isSupported)
        widgetMachine = LockStateMachine(enabled: Settings.shared.lockWidgets, supported: simulate || elevator.isSupported)
        _ = widgetMachine.handle(.trackChanged(identity: "widgets"))
        _ = widgetMachine.handle(.playbackChanged(isPlaying: true))
    }

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Log.write("lock: screenIsLocked"); self?.send(.screenLocked) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Log.write("lock: screenIsUnlocked"); self?.send(.screenUnlocked) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.send(.displaySlept) } }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.send(.displayWoke) } }
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.send(.sessionResignedActive) } }
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.send(.sessionBecameActive) } }
        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let key = n.object as? String else { return }
                if key == SettingsKey.lockScreenEnabled { self.send(.settingChanged(enabled: self.settings.lockScreenEnabled)) }
                if key == SettingsKey.lockWidgets { self.sendWidgets(.settingChanged(enabled: self.settings.lockWidgets)) }
            }
        }
        media.onTrackChanged = { [weak self] id in self?.send(.trackChanged(identity: id)); self?.trackHook?(id) }
        media.onPlaybackChanged = { [weak self] playing in self?.send(.playbackChanged(isPlaying: playing)) }
        if let now = media.now {
            send(.trackChanged(identity: now.track.identity))
            send(.playbackChanged(isPlaying: now.isPlaying))
        }
        if simulate {
            send(.settingChanged(enabled: true))
            sendWidgets(.settingChanged(enabled: true))
            send(.screenLocked)
        }
    }

    var currentWindow: NSWindow? { panel }
    var trackHook: ((String?) -> Void)?

    func sendWidgets(_ event: LockStateMachine.Event) {
        if event == .screenLocked { env?.devices.refreshConnected() }
        for effect in widgetMachine.handle(event) {
            switch effect {
            case .showCard: showWidgets()
            case .hideCard: hideWidgets()
            case .updateCard: break
            }
        }
    }

    private func showWidgets() {
        guard widgetPanel == nil, let env,
              LockWidgetsView.hasContent(settings: settings, weather: env.weather, devices: env.devices),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let size = LockWidgetsView.size
        // Middle of the screen, as requested.
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2)
        let p = LockPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.level = simulate ? .floating : NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: LockWidgetsView(settings: settings, weather: env.weather, devices: env.devices))
        host.sizingOptions = []
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        if !simulate, !elevator.elevate(windowNumber: p.windowNumber) {
            Log.write("lock: could not move the widgets above the lock screen")
            p.orderOut(nil)
            _ = widgetMachine.handle(.supportChanged(supported: false))
            return
        }
        widgetPanel = p
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduceMotion ? Motion.reducedFade : 0.35
            p.animator().alphaValue = 1
        }
        Log.write("lock: widgets shown")
    }

    private func hideWidgets() {
        guard let p = widgetPanel else { return }
        widgetPanel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
            p.contentView = nil
            self.releaseElevatorIfIdle()
        })
        Log.write("lock: widgets hidden")
    }

    /// The elevator space is shared by both panels; it is torn down only when neither is on screen.
    private func releaseElevatorIfIdle() {
        if !simulate, panel == nil, widgetPanel == nil { elevator.release() }
    }

    func send(_ event: LockStateMachine.Event) {
        if event == .screenLocked || event == .screenUnlocked || event == .displaySlept || event == .displayWoke
            || event == .sessionResignedActive || event == .sessionBecameActive { sendWidgets(event) }
        for effect in machine.handle(event) {
            switch effect {
            case .showCard: showCard()
            case .hideCard: hideCard()
            case .updateCard: break   // the view reads the media controller, so it updates itself
            }
        }
    }

    private func showCard() {
        guard panel == nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let size = LockCardView.size
        // Bottom center, clear of the clock (top) and of the avatar / password field (middle).
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.minY + 72)
        let p = LockPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.level = simulate ? .floating : NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: LockCardView(media: media, settings: settings))
        host.sizingOptions = []
        p.contentView = host
        p.alphaValue = 0
        p.orderFrontRegardless()
        if !simulate {
            if !elevator.elevate(windowNumber: p.windowNumber) {
                Log.write("lock: could not move the card above the lock screen; feature unsupported")
                p.orderOut(nil)
                machine.handle(.supportChanged(supported: false))
                return
            }
        }
        panel = p
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduceMotion ? Motion.reducedFade : 0.35
            p.animator().alphaValue = 1
        }
        Log.write("lock: card shown")
    }

    private func hideCard() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { [elevator] in
            p.orderOut(nil)
            p.contentView = nil
            self.releaseElevatorIfIdle()
        })
        Log.write("lock: card hidden")
    }
}
