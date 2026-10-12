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
    /// Open reminders per list (calendar identifier), from the last fetch of everything, not just the 30 shown.
    private var openCounts: [String: Int] = [:]
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
            var counts: [String: Int] = [:]
            for r in reminders ?? [] { if let id = r.calendar?.calendarIdentifier { counts[id, default: 0] += 1 } }
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
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self?.openCounts = counts
                self?.items = Array(sorted.prefix(30))
            } }
        }
    }

    /// The writable list holding the most open reminders; the system default list when counts are not known yet.
    private func busiestList() -> EKCalendar? {
        let writable = store.calendars(for: .reminder).filter(\.allowsContentModifications)
        let counts = Dictionary(uniqueKeysWithValues: writable.map { ($0.calendarIdentifier, openCounts[$0.calendarIdentifier] ?? 0) })
        let preferred = store.defaultCalendarForNewReminders()?.calendarIdentifier
        guard let id = ReminderLists.pick(counts: counts, preferred: preferred) else { return store.defaultCalendarForNewReminders() }
        return writable.first { $0.calendarIdentifier == id }
    }

    /// Adds a reminder to the list with the most open reminders. Returns false when there is no access or the save failed.
    @discardableResult
    func add(title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard access == .granted, !trimmed.isEmpty, let list = busiestList() else { return false }
        let r = EKReminder(eventStore: store)
        r.title = trimmed
        r.calendar = list
        do { try store.save(r, commit: true) } catch { Log.write("reminders: \(error.localizedDescription)"); return false }
        refresh()
        return true
    }

    func complete(_ item: Item) {
        guard let r = store.calendarItem(withIdentifier: item.id) as? EKReminder else { return }
        r.isCompleted = true
        do { try store.save(r, commit: true); items.removeAll { $0.id == item.id } } catch { Log.write("reminders: \(error.localizedDescription)") }
    }

    func openRemindersApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") { NSWorkspace.shared.open(url) }
    }
}
