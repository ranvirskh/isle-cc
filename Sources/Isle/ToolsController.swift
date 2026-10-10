import AppKit
import IOKit.pwr_mgt
import IsleCore

/// Keep Awake: holds a power assertion so the Mac does not idle-sleep. No permissions needed.
@MainActor
final class ToolsController: ObservableObject {
    @Published private(set) var awakeUntil: Date?
    @Published private(set) var awakeOn = false

    private var assertion: IOPMAssertionID = 0
    private var awakeTimer: Timer?

    func setAwake(_ on: Bool, duration: KeepAwakeDuration) {
        awakeTimer?.invalidate(); awakeTimer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        awakeOn = false; awakeUntil = nil
        guard on else { return }
        let ok = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "Isle keep awake" as CFString, &assertion) == kIOReturnSuccess
        guard ok else { assertion = 0; return }
        awakeOn = true
        if let s = duration.seconds {
            awakeUntil = Date().addingTimeInterval(s)
            awakeTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.setAwake(false, duration: .indefinite) }
            }
        }
    }

    func appWillTerminate() { setAwake(false, duration: .indefinite) }
}
