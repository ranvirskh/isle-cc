import SwiftUI
import IsleCore

struct ToolsView: View {
    @EnvironmentObject var tools: ToolsController
    @State private var duration: KeepAwakeDuration = .indefinite

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "cup.and.saucer.fill").font(.system(size: 12, weight: .semibold))
                Text("Keep awake").font(.system(size: 12, weight: .semibold))
            }
            if tools.awakeOn {
                Text(tools.awakeUntil.map { "Until " + $0.formatted(date: .omitted, time: .shortened) } ?? "Until turned off")
                    .font(.system(size: 13, weight: .semibold))
                pill("Turn off", selected: false) { tools.setAwake(false, duration: duration) }
            } else {
                HStack(spacing: 6) {
                    ForEach(KeepAwakeDuration.allCases) { d in
                        pill(d.label, selected: d == duration) { duration = d; tools.setAwake(true, duration: d) }
                    }
                }
                Text("Tap a length to start").font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        .foregroundStyle(.white)
    }

    private func pill(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.28 : 0.1)))
        }
        .buttonStyle(PressStyle())
    }
}
