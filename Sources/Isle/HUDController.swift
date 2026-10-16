import AppKit
import ApplicationServices
import IsleCore

/// Replaces the macOS volume and brightness overlay with an indicator in the island.
///
/// How: a session event tap sees the system-defined media-key events (needs the Accessibility permission). For a key
/// it can act on, it sets the level itself (CoreAudio for volume, DisplayServices for brightness), swallows the key
/// so macOS never draws its own overlay, and asks the island to show the new level. For a key it cannot act on
/// (an HDMI speaker with no volume control, no built-in display) it lets the key through untouched.
@MainActor
final class HUDController: ObservableObject {
    @Published private(set) var trusted = AXIsProcessTrusted()
    var onLevel: ((HUDState) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var poll: Timer?
    private var observer: NSObjectProtocol?
    private var stopMic: (() -> Void)?
    private var lastMic: Double?
    private let settings = Settings.shared

    func start() {
        observer = NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { if let k = n.object as? String, k == SettingsKey.hudReplacement || k == SettingsKey.hudMicrophone { self?.sync() } }
        }
        sync()
    }

    func appWillTerminate() { removeTap(); stopBrightnessWatch() }

    private func sync() {
        poll?.invalidate(); poll = nil
        stopMic?(); stopMic = nil
        guard settings.hudReplacement else { removeTap(); stopBrightnessWatch(); return }
        watchMicrophone()
        startBrightnessWatch()
        trusted = AXIsProcessTrusted()
        if trusted { installTap(); return }
        // Ask once; macOS shows its permission prompt. Then wait for the user to grant it.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trusted = AXIsProcessTrusted()
                if self.trusted { self.poll?.invalidate(); self.poll = nil; self.installTap() }
            }
        }
    }

    /// Shows the microphone level when it is changed in System Settings (no permission needed; public CoreAudio).
    private func watchMicrophone() {
        guard settings.hudMicrophone else { return }
        lastMic = SystemLevels.inputVolume()
        stopMic = SystemLevels.observeInputVolume { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let v = SystemLevels.inputVolume(), v != self.lastMic else { return }
                self.lastMic = v
                self.onLevel?(HUDState(kind: .microphone, level: v))
            }
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }

    // MARK: Brightness watcher
    //
    // On some Macs (macOS 27 here) the brightness keys never reach an event tap: Control Center handles them itself and
    // draws its own banner, which an app cannot suppress. So the level is polled, and a change from any source shows in
    // the island, next to the macOS banner.

    private var brightnessTimer: Timer?
    private var lastBrightness: Double?

    private var screenObserver: NSObjectProtocol?

    private func startBrightnessWatch() {
        // Connecting or removing a display changes what can be read; start over so the first reading is a fresh baseline.
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.settings.hudReplacement else { return }
                    self.stopBrightnessWatch()
                    self.lastBrightness = nil; self.episode = nil; self.userDriven = false
                    self.startBrightnessWatch()
                }
            }
        }
        guard brightnessTimer == nil, SystemLevels.brightnessAvailable else { return }
        lastBrightness = SystemLevels.brightness()
        scheduleBrightnessTimer(fast: false)
        // The system announces brightness changes; react at once instead of waiting for the next idle check.
        for name in ["com.apple.BezelEngine.BrightnessChanged", "com.apple.BezelServices.BrightnessChanged",
                     "com.apple.controlcenter.display.brightness", "com.apple.CoreBrightness.DisplayBrightnessChanged"] {
            brightnessObservers.append(DistributedNotificationCenter.default().addObserver(forName: .init(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.write("hud: brightness notification \(name)")
                    self?.scheduleBrightnessTimer(fast: true)
                    self?.brightnessTick()
                }
            })
        }
    }

    /// 120 Hz while a change is under way (so a held key moves the bar as smoothly as the display refreshes), 20 Hz when
    /// idle, which keeps the watcher's CPU cost negligible.
    private func scheduleBrightnessTimer(fast: Bool) {
        brightnessTimer?.invalidate()
        fastUntil = fast ? Date().addingTimeInterval(1.2) : nil
        let timer = Timer(timeInterval: fast ? 1.0 / 120 : 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.brightnessTick() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        brightnessTimer = timer
    }
    private var fastUntil: Date?
    private var brightnessObservers: [NSObjectProtocol] = []

    private func stopBrightnessWatch() {
        guard brightnessTimer != nil else { return }
        brightnessTimer?.invalidate(); brightnessTimer = nil
        brightnessObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }; brightnessObservers = []
    }

    // A key press moves the level a whole step (about 6%) within a fraction of a second; automatic brightness drifts
    // slowly. Only a fast move is shown, so ambient-light adjustments never raise the indicator.
    private var episode: (start: Date, from: Double)?
    private var userDriven = false
    private var lastMove = Date.distantPast

    private func brightnessTick() {
        if let until = fastUntil, Date() > until { scheduleBrightnessTimer(fast: false) }
        guard let now = SystemLevels.brightness() else { return }
        let base = lastBrightness ?? now
        lastBrightness = base
        let date = Date()
        if abs(now - base) > 0.005 {
            lastMove = date
            if episode == nil { episode = (date, base); if fastUntil == nil { scheduleBrightnessTimer(fast: true) } }
            if let e = episode, !userDriven {
                let atEnd = now <= 0.001 || now >= 0.999      // a press that only closes the last bit of the range
                if abs(now - e.from) >= (atEnd ? 0.01 : 0.04), date.timeIntervalSince(e.start) <= 0.35 { userDriven = true; Log.write("hud: brightness key change \(String(format: "%.3f", e.from)) -> \(String(format: "%.3f", now))") }
                else if date.timeIntervalSince(e.start) > 0.35 { episode = nil; Log.write("hud: brightness drift ignored (\(String(format: "%.3f", e.from)) -> \(String(format: "%.3f", now)))") }      // slow drift: automatic brightness
            }
            lastBrightness = now
            if userDriven {
                fastUntil = date.addingTimeInterval(1.2)
                onLevel?(HUDState(kind: .brightness, level: now))
            }
        } else if userDriven, date.timeIntervalSince(lastMove) > 0.4 {
            userDriven = false; episode = nil
        }
    }

    // MARK: Event tap

    private static let systemDefined = CGEventType(rawValue: 14)!   // NX_SYSDEFINED

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefined.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HUDController>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated { me.handle(type: type, event: event) }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.write("hud: could not create the event tap")
            return
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        Log.write("hud: event tap installed, brightness available=\(SystemLevels.brightnessAvailable)")
    }

    private func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t) }
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil; source = nil
    }

    /// Runs on the main thread (the tap is on the main run loop). Returning nil swallows the event.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // macOS turns a tap off when it is too slow or after user input is blocked; turn it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return pass
        }
        guard type == Self.systemDefined, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8,
              let press = MediaKeyPress.parse(data1: ns.data1) else { return pass }
        let fine = event.flags.contains(.maskShift) && event.flags.contains(.maskAlternate)
        guard let state = apply(press, fine: fine) else { return pass }
        if press.isDown { onLevel?(state) }
        return nil
    }

    /// Acts on a key press. Returns the level to show, or nil when the key should be left to macOS.
    private func apply(_ press: MediaKeyPress, fine: Bool) -> HUDState? {
        switch press.key {
        case .volumeUp, .volumeDown, .mute:
            guard let current = SystemLevels.volume() else { return nil }
            guard press.isDown else { return HUDState(kind: .volume, level: current, muted: SystemLevels.isMuted()) }   // swallow the key-up too
            if press.key == .mute {
                guard SystemLevels.setMuted(!SystemLevels.isMuted()) else { return nil }
                return HUDState(kind: .volume, level: current, muted: SystemLevels.isMuted())
            }
            let next = HUDStep.next(current, up: press.key == .volumeUp, fine: fine, percent: settings.hudStepPercent)
            guard SystemLevels.setVolume(next) else { return nil }
            if SystemLevels.isMuted(), next > 0 { SystemLevels.setMuted(false) }   // like macOS: raising the volume unmutes
            return HUDState(kind: .volume, level: next, muted: SystemLevels.isMuted())
        case .keyboardUp, .keyboardDown:
            guard settings.hudMicrophone, SystemLevels.keyboardBacklightAvailable, let current = SystemLevels.keyboardBacklight() else { return nil }
            guard press.isDown else { return HUDState(kind: .keyboard, level: current) }
            let next = HUDStep.next(current, up: press.key == .keyboardUp, fine: fine, percent: settings.hudStepPercent)
            guard SystemLevels.setKeyboardBacklight(next) else { return nil }
            return HUDState(kind: .keyboard, level: next)
        case .brightnessUp, .brightnessDown:
            guard SystemLevels.brightnessAvailable, let current = SystemLevels.brightness() else { return nil }
            guard press.isDown else { return HUDState(kind: .brightness, level: current) }
            let next = HUDStep.next(current, up: press.key == .brightnessUp, fine: fine, percent: settings.hudStepPercent)
            guard SystemLevels.setBrightness(next) else { return nil }
            lastBrightness = next        // so the watcher does not show the same change twice
            return HUDState(kind: .brightness, level: next)
        }
    }
}
