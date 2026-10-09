import AppKit
import EventKit
import IsleCore

@MainActor
final class CalendarController: ObservableObject {
    enum Access { case unknown, granted, denied }

    @Published private(set) var agenda: Agenda = .empty
    @Published private(set) var access: Access = .unknown
    @Published private(set) var calendars: [(id: String, title: String, color: NSColor)] = []

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
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: access = .granted
        case .notDetermined: access = .unknown
        default: access = .denied
        }
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
        let start = cal.startOfDay(for: now)
        guard let end = cal.date(byAdding: .day, value: 2, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events: [AgendaEvent] = store.events(matching: predicate).map { e in
            let c = (e.calendar.color ?? .systemBlue).usingColorSpace(.sRGB) ?? .systemBlue
            return AgendaEvent(id: (e.eventIdentifier ?? UUID().uuidString) + "|\(Int(e.startDate.timeIntervalSince1970))",
                               title: e.title ?? "Untitled", start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                               calendarID: e.calendar.calendarIdentifier,
                               color: .init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent))
        }
        let built = Agenda.build(events: events, now: now, hiddenCalendarIDs: settings.hiddenCalendarIDs)
        if built != agenda { agenda = built }
        // One wake-up at the next status change; nothing runs in between.
        if let next = built.nextRefresh(after: now) {
            timer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer?.tolerance = 1
        }
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
