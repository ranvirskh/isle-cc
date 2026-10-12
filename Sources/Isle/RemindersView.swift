import SwiftUI
import IsleCore

/// Open reminders for the Home tab, in the spot the calendar agenda used to take. The Calendar tab keeps the agenda.
struct RemindersPanel: View {
    @EnvironmentObject var reminders: RemindersController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Text("Reminders").font(.system(size: 12, weight: .semibold))
                if reminders.access == .granted, !reminders.items.isEmpty {
                    Text("\(reminders.items.count)").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5)).padding(.leading, 4)
                }
                Spacer(minLength: 2)
                Button { reminders.openRemindersApp() } label: {
                    Image(systemName: "checklist").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).help("Open Reminders").accessibilityLabel("Open Reminders")
            }
            switch reminders.access {
            case .denied:
                Text("Reminders access is off.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                Button("Open Privacy Settings") { reminders.openPrivacySettings() }.buttonStyle(.bordered).controlSize(.small)
                Spacer()
            case .unknown:
                Button("Allow Reminders Access") { reminders.open() }.buttonStyle(.bordered).controlSize(.small)
                Spacer()
            case .granted:
                if reminders.items.isEmpty {
                    Text("All done").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                    Spacer()
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 5) { ForEach(reminders.items) { row($0) } }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { reminders.open() }
    }

    private func row(_ item: RemindersController.Item) -> some View {
        HStack(spacing: 8) {
            Button { reminders.complete(item) } label: {
                Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(PressStyle()).help("Mark as done").accessibilityLabel("Mark \(item.title) as done")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let due = item.due {
                    Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 10)).foregroundStyle(due < Date() ? Color.red.opacity(0.9) : .white.opacity(0.45))
                } else if !item.list.isEmpty {
                    Text(item.list).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.09)))
    }
}
