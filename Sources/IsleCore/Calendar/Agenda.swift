import Foundation

public struct AgendaEvent: Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var calendarID: String
    /// sRGB components 0...1 of the calendar's color.
    public var color: RGB

    public struct RGB: Equatable {
        public var r: Double, g: Double, b: Double
        public init(r: Double, g: Double, b: Double) {
            self.r = r; self.g = g; self.b = b
        }
    }

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool = false,
                calendarID: String, color: RGB = RGB(r: 0.4, g: 0.6, b: 1)) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarID = calendarID
        self.color = color
    }
}

public struct Agenda: Equatable {
    public enum Day: Equatable { case today, tomorrow }
    public enum Status: Equatable { case past, current, upcoming }

    public struct Row: Equatable, Identifiable {
        public var event: AgendaEvent
        public var status: Status
        public var id: String { event.id }
    }

    public var day: Day
    public var rows: [Row]

    public static let empty = Agenda(day: .today, rows: [])

    /// Builds what the Home tab shows: today's events, or tomorrow's when today has none.
    /// `hiddenCalendarIDs` are calendars the user switched off in Settings.
    public static func build(events: [AgendaEvent], now: Date, calendar: Calendar = .current,
                             hiddenCalendarIDs: Set<String> = []) -> Agenda {
        let visible = events.filter { !hiddenCalendarIDs.contains($0.calendarID) }
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let startOfDayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday) else { return .empty }

        func rows(from dayStart: Date, to dayEnd: Date) -> [Row] {
            visible
                .filter { event in
                    // Overlap test. An event ending exactly at midnight belongs to the day before.
                    let end = max(event.end, event.start)
                    if event.start >= dayEnd { return false }
                    if end == event.start { return event.start >= dayStart }
                    return end > dayStart
                }
                .sorted { a, b in
                    if a.isAllDay != b.isAllDay { return a.isAllDay }
                    if a.start != b.start { return a.start < b.start }
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
                .map { event in
                    let status: Status
                    if event.isAllDay {
                        status = (dayStart <= now && now < dayEnd) ? .current : .upcoming
                    } else if event.end <= now {
                        status = .past
                    } else if event.start <= now {
                        status = .current
                    } else {
                        status = .upcoming
                    }
                    return Row(event: event, status: status)
                }
        }

        let today = rows(from: startOfToday, to: startOfTomorrow)
        if !today.isEmpty { return Agenda(day: .today, rows: today) }
        return Agenda(day: .tomorrow, rows: rows(from: startOfTomorrow, to: startOfDayAfter))
    }

    /// The next moment the statuses change (an event starts or ends, or the day rolls over).
    public func nextRefresh(after now: Date, calendar: Calendar = .current) -> Date? {
        var moments: [Date] = rows.flatMap { [$0.event.start, $0.event.end] }.filter { $0 > now }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            moments.append(midnight)
        }
        return moments.min()
    }
}
