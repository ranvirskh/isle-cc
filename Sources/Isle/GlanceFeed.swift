import AppKit
import IsleCore

/// Glance 2's status for the header chip and card: asks for it, receives it, and sends Glance its commands. Glance is never launched
/// from here (it is a menu-bar app the user starts), so with it closed or too old to answer there is simply no chip.
@MainActor
final class GlanceFeed: ObservableObject {
    @Published private(set) var status: GlanceStatus?
    /// Glance is running and says it understands this (see `IslandIntegration`): the chip appears only then.
    @Published private(set) var isRunning = false
    private var observers: [NSObjectProtocol] = []

    private static var runningGlance: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let id = app.bundleIdentifier, GlanceLink.bundleIDs.contains(id) else { return false }
            return IslandIntegration.supports(app.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary })
        }
    }

    func start() {
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(GlanceLink.statusNotification), object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let parsed = GlanceStatus.parse(note.userInfo) else { return }
                self?.status = parsed
            }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        let running = Self.runningGlance
        if running != isRunning { isRunning = running }
        guard running else { status = nil; return }
        // A Glance that just launched can only hear this once it has finished starting up.
        for delay in [0.0, 1.5, 4.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.requestStatus() } }
    }

    func requestStatus() { post(GlanceLink.requestStatusNotification) }
    func unlock() { post(GlanceLink.unlockNotification) }
    func openSettings() { post(GlanceLink.openSettingsNotification) }

    private func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(Notification.Name(name), object: nil, userInfo: GlanceLink.command(), deliverImmediately: true)
    }
}
