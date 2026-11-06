import AppKit
import IsleCore

/// Opens KwikBattery's panel from Isle's battery icon, when KwikBattery is installed.
@MainActor
enum KwikBatteryLauncher {
    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: KwikBatteryLink.bundleID) }
    static var isInstalled: Bool { appURL != nil }
    private static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: KwikBatteryLink.bundleID).isEmpty }

    /// Asks KwikBattery to show its panel hanging from `anchor` (screen coordinates). If it isn't running it is started first; the
    /// request is repeated a few times while it starts up, since it can only hear it once it has finished launching. Showing an
    /// already-open panel is a no-op on its side, so the repeats are harmless.
    static func open(anchor: CGRect?) {
        guard let url = appURL else { return }
        let post = { DistributedNotificationCenter.default().postNotificationName(Notification.Name(KwikBatteryLink.showPanelNotification),
                                                                                    object: nil, userInfo: KwikBatteryLink.request(anchor: anchor), deliverImmediately: true) }
        if isRunning { post(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        for delay in [0.8, 1.6, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { post() }
        }
    }
}
