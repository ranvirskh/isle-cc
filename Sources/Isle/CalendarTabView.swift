import SwiftUI
import IsleCore

/// Month grid on the left (dots mark days with events, click a day to see it), that day's agenda on the right.
struct CalendarTabView: View {
    @EnvironmentObject var calendar: CalendarController
    private let cal = Calendar.current

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            monthGrid.frame(width: 250)
            Divider().overlay(Color.white.opacity(0.15))
            AgendaView().frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .onAppear { calendar.requestIfNeeded(); calendar.loadMonth() }
        .onReceive(calendar.$access) { if $0 == .granted { calendar.loadMonth() } }
    }

    private var selected: Date {
        cal.startOfDay(for: calendar.selectedDay ?? (calendar.agenda.day == .tomorrow ? cal.date(byAdding: .day, value: 1, to: Date()) ?? Date() : Date()))
    }

    private var monthGrid: some View {
        let weeks = MonthGrid.weeks(for: calendar.monthAnchor, calendar: cal)
        return VStack(spacing: 3) {
            HStack {
                Text(calendar.monthAnchor, format: .dateTime.month(.wide).year()).font(.system(size: 13, weight: .semibold))
                Spacer()
                nav("chevron.left", "Previous month") { calendar.shiftMonth(-1) }
                nav("circle.fill", "This month") { calendar.showToday() }
                nav("chevron.right", "Next month") { calendar.shiftMonth(1) }
            }
            HStack(spacing: 0) {
                ForEach(Array(MonthGrid.weekdayHeaders(calendar: cal).enumerated()), id: \.offset) { _, s in
                    Text(s).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.4)).frame(maxWidth: .infinity)
                }
            }
            ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        if let day = week[i] { dayCell(day) } else { Color.clear.frame(maxWidth: .infinity, minHeight: 20) }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let isToday = cal.isDateInToday(day)
        return Button { calendar.select(day: day) } label: {
            VStack(spacing: 1) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 11, weight: isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.black : (isToday ? Color.accentColor : .white))
                    .frame(width: 22, height: 17)
                    .background(Circle().fill(isSelected ? Color.white : Color.clear))
                Circle().fill(calendar.eventDays.contains(day) ? Color.white.opacity(0.7) : Color.clear).frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func nav(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 6 : 10, weight: .semibold)).frame(width: 18, height: 18)
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
