import AppKit
import EventKit
import IsleCore

@MainActor
final class CalendarController: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var agenda: Agenda = .empty
    @Published private(set) var access: Access = .unknown
    /// nil = the automatic view (today, or tomorrow when today is empty); otherwise the day the user navigated to.
    @Published private(set) var selectedDay: Date?
    @Published private(set) var calendars: [(id: String, title: String, color: NSColor)] = []

    /// First day of the month shown in the Calendar tab, and the days in it that have events.
    @Published private(set) var monthAnchor: Date = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @Published private(set) var eventDays: Set<Date> = []

    private let store = EKEventStore()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let settings = Settings.shared
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        updateAccess()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(nc.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(nc.addObserver(forName: .settingsChanged, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                let key = n.object as? String
                if key == SettingsKey.showCalendar || key == SettingsKey.hiddenCalendarIDs { self?.refresh() }
            }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        if settings.showCalendar { requestIfNeeded() }
    }

    private func updateAccess() {
        let new: Access
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: new = .granted
        case .notDetermined: new = .unknown
        default: new = .denied
        }
        // @Published announces every assignment, even of an equal value, so only write when it changed.
        if new != access { access = new }
    }

    /// Asks for permission the first time the calendar is shown.
    func requestIfNeeded() {
        updateAccess()
        switch access {
        case .granted: refresh()
        case .denied: break
        case .unknown:
            store.requestFullAccessToEvents { [weak self] granted, error in
                if let error { Log.write("calendar access: \(error.localizedDescription)") }
                Task { @MainActor in
                    self?.updateAccess()
                    self?.refresh()
                }
            }
        }
    }

    func refresh() {
        timer?.invalidate()
        timer = nil
        updateAccess()
        guard settings.showCalendar, access == .granted else {
            if agenda != .empty { agenda = .empty }
            return
        }
        calendars = store.calendars(for: .event).map { ($0.calendarIdentifier, $0.title, $0.color ?? .systemBlue) }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: selectedDay ?? now)
        guard let end = cal.date(byAdding: .day, value: selectedDay == nil ? 2 : 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events: [AgendaEvent] = store.events(matching: predicate).map { e in
            let c = (e.calendar.color ?? .systemBlue).usingColorSpace(.sRGB) ?? .systemBlue
            return AgendaEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "|\(Int(e.startDate.timeIntervalSince1970))",
                               title: e.title ?? "Untitled", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                               calendarID: e.calendar.calendarIdentifier,
                               color: .init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent))
        }
        let built = selectedDay.map { Agenda.build(day: $0, events: events, now: now, hiddenCalendarIDs: settings.hiddenCalendarIDs) }
            ?? Agenda.build(events: events, now: now, hiddenCalendarIDs: settings.hiddenCalendarIDs)
        if built != agenda { agenda = built }
        // One wake-up at the next status change; nothing runs in between.
        if let next = built.nextRefresh(after: now) {
            timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer?.tolerance = 1
        }
    }

    /// Moves the agenda by whole days. Going back to today returns to the automatic view.
    func shiftDay(_ days: Int) {
        let cal = Calendar.current
        let base = selectedDay ?? (agenda.day == .tomorrow ? cal.date(byAdding: .day, value: 1, to: Date()) ?? Date() : Date())
        guard let moved = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: base)) else { return }
        selectedDay = cal.isDateInToday(moved) ? nil : moved
        refresh()
    }

    /// Loads which days of the shown month have events (for the dots in the month grid).
    func loadMonth() {
        updateAccess()
        guard access == .granted, let interval = Calendar.current.dateInterval(of: .month, for: monthAnchor) else { eventDays = []; return }
        let hidden = settings.hiddenCalendarIDs
        let cal = Calendar.current
        var days: Set<Date> = []
        for e in store.events(matching: store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)) where !hidden.contains(e.calendar.calendarIdentifier) {
            var d = cal.startOfDay(for: e.startDate)
            let last = cal.startOfDay(for: max(e.startDate, e.endDate.addingTimeInterval(-1)))
            while d <= last, d < interval.end { days.insert(d); guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }; d = n }
        }
        eventDays = days
    }

    func shiftMonth(_ months: Int) {
        guard let moved = Calendar.current.date(byAdding: .month, value: months, to: monthAnchor) else { return }
        monthAnchor = Calendar.current.dateInterval(of: .month, for: moved)?.start ?? moved
        loadMonth()
    }

    func select(day: Date) {
        let cal = Calendar.current
        selectedDay = cal.isDateInToday(day) ? nil : cal.startOfDay(for: day)
        refresh()
    }

    func showToday() {
        monthAnchor = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
        resetDay()
        loadMonth()
    }

    func resetDay() {
        guard selectedDay != nil else { return }
        selectedDay = nil
        refresh()
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }
}
