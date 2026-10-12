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

    func appWillTerminate() { removeTap() }

    private func sync() {
        poll?.invalidate(); poll = nil
        stopMic?(); stopMic = nil
        guard settings.hudReplacement else { removeTap(); return }
        watchMicrophone()
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
            return HUDState(kind: .brightness, level: next)
        }
    }
}
