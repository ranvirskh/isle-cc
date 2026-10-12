import Foundation

public enum MonthGrid {
    /// Weeks of the month containing `month`, each with 7 slots starting at the calendar's first weekday;
    /// slots outside the month are nil. Dates are start-of-day.
    public static func weeks(for month: Date, calendar: Calendar = .current) -> [[Date?]] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let dayCount = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let first = interval.start
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        var slots: [Date?] = Array(repeating: nil, count: lead)
        for d in 0..<dayCount { slots.append(calendar.date(byAdding: .day, value: d, to: first)) }
        while slots.count % 7 != 0 { slots.append(nil) }
        return stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<$0 + 7]) }
    }

    /// Single-letter weekday headers in the calendar's order.
    public static func weekdayHeaders(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }
}
