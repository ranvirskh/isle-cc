import AppKit
import EventKit
import IsleCore

/// Open Apple Reminders, soonest first. Asks for Reminders access the first time the tab is opened.
@MainActor
final class RemindersController: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date?
        let list: String
    }
    enum Access { case unknown, granted, denied }

    @Published private(set) var items: [Item] = []
    @Published private(set) var access: Access = .unknown
    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
    }

    /// Called when the tab appears.
    func open() {
        updateAccess()
        switch access {
        case .granted: refresh()
        case .denied: break
        case .unknown:
            store.requestFullAccessToReminders { [weak self] granted, _ in
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self?.updateAccess()
                    if granted { self?.refresh() }
                } }
            }
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.access == .granted { self?.refresh() } }
            }
        }
    }

    func refresh() {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let mapped = (reminders ?? []).map { r in
                Item(id: r.calendarItemIdentifier, title: r.title ?? "Untitled",
                     due: r.dueDateComponents.flatMap { Calendar.current.date(from: $0) }, list: r.calendar?.title ?? "")
            }
            let sorted = mapped.sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): return x < y
                case (nil, _?): return false
                case (_?, nil): return true
                default: return a.title < b.title
                }
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.items = Array(sorted.prefix(30)) } }
        }
    }

    func complete(_ item: Item) {
        guard let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        r.isCompleted = true
        do { try store.save(r, commit: true); items.removeAll { $0.id == item.id } } catch { Log.write("reminders: \(error.localizedDescription)") }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(url) }
    }
}
