import SwiftUI
import IsleCore

struct RemindersView: View {
    @EnvironmentObject var reminders: RemindersController

    var body: some View {
        Group {
            switch reminders.access {
            case .denied:
                note("Reminders access is off", "Allow Isle in System Settings > Privacy & Security > Reminders.", button: ("Open Privacy Settings", reminders.openPrivacySettings))
            case .unknown:
                note("Waiting for permission", "Allow Reminders access in the macOS prompt.")
            case .granted:
                if reminders.items.isEmpty {
                    note("All done", "No open reminders.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) { ForEach(reminders.items) { row($0) } }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .onAppear { reminders.open() }
    }

    private func row(_ item: RemindersController.Item) -> some View {
        HStack(spacing: 10) {
            Button { reminders.complete(item) } label: {
                Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(PressStyle()).help("Mark as done").accessibilityLabel("Mark \(item.title) as done")
            Text(item.title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 8)
            if let due = item.due {
                Text(due, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 10)).foregroundStyle(due < Date() ? Color.red.opacity(0.9) : .white.opacity(0.45))
            }
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private func note(_ title: String, _ detail: String, button: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checklist").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
            if let button { Button(button.0, action: button.1).buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
