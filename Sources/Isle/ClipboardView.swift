import SwiftUI
import IsleCore

struct ClipboardView: View {
    @EnvironmentObject var clipboard: ClipboardController
    @EnvironmentObject var settings: Settings
    @State private var copiedID: UUID?

    var body: some View {
        Group {
            if !settings.clipboardEnabled {
                note("Clipboard history is off", "Turn it on in Settings > Look.")
            } else if clipboard.history.items.isEmpty {
                note("Nothing copied yet", "Text you copy appears here. It stays in memory only and is never saved.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Click to copy again").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        Button("Clear") { clipboard.clear() }.buttonStyle(.plain).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(clipboard.history.items) { item in row(item) }
                        }
                    }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func row(_ item: ClipboardItem) -> some View {
        Button {
            clipboard.copy(item)
            copiedID = item.id
        } label: {
            HStack(spacing: 8) {
                Text(item.preview).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if copiedID == item.id {
                    Text("Copied").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                } else {
                    Text(item.date, style: .time).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 10).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .contextMenu { Button("Remove") { clipboard.remove(item) } }
    }

    private func note(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
