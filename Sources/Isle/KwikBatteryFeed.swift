import AppKit
import IsleCore

/// KwikBattery's battery summary for the island's battery card: asks for it, receives it, and starts KwikBattery if it is installed
/// but not running.
@MainActor
final class KwikBatteryFeed: ObservableObject {
    @Published private(set) var summary: KwikBatterySummary?
    @Published private(set) var receivedAt: Date?
    private var observer: NSObjectProtocol?

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: KwikBatteryLink.bundleID) }
    /// Installed AND new enough to answer: an older KwikBattery would be launched and then never reply.
    static var isInstalled: Bool { appURL.flatMap { Bundle(url: $0)?.infoDictionary }.map { IslandIntegration.supports($0) } ?? false }
    private static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: KwikBatteryLink.bundleID).isEmpty }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(KwikBatterySummary.notificationName), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let parsed = KwikBatterySummary.parse(note.userInfo) else { return }
                self.summary = parsed
                self.receivedAt = Date()
            }
        }
    }

    /// Asks KwikBattery for a fresh snapshot. If it is not running it is started first, and the request repeated while it starts up
    /// (it can only hear it once it has finished launching).
    func requestSummary() {
        let post = {
            DistributedNotificationCenter.default().postNotificationName(Notification.Name(KwikBatteryLink.summaryRequestNotification),
                                                                          object: nil, userInfo: KwikBatteryLink.summaryRequest(), deliverImmediately: true)
        }
        if Self.isRunning { post(); return }
        guard let url = Self.appURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        for delay in [0.8, 1.6, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { post() } }
    }

    var isFresh: Bool { KwikBatteryLink.isFresh(receivedAt: receivedAt) }
}
