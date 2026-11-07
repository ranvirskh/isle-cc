import SwiftUI
import IsleCore

/// The header chip for Glance 2: a face icon whose look says whether face unlock is off, needs unlocking, or is ready. Clicking it
/// opens `GlanceCard` inside the island, the same way the battery chip opens its card.
struct GlanceChip: View {
    @ObservedObject var feed: GlanceFeed
    @EnvironmentObject var model: IslandModel

    private var light: GlanceStatus.Light { feed.status?.light ?? .off }
    private var symbol: String { light == .needsAttention ? "lock.fill" : "faceid" }
    private var tint: Color {
        switch light {
        case .ready: return Color(red: 0.26, green: 0.84, blue: 0.42)
        case .needsAttention: return .orange
        case .off: return .white.opacity(0.45)
        }
    }
    private var help: String {
        switch light {
        case .ready: return "Glance: face unlock is ready"
        case .needsAttention: return "Glance: needs unlocking"
        case .off: return "Glance: face unlock is off"
        }
    }

    var body: some View {
        Button {
            model.showBatterySummary = false
            model.showGlanceCard.toggle()
            if model.showGlanceCard { feed.requestStatus() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
        }
        .buttonStyle(PressStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Glance's state, an Unlock button when it is locked, and its last few scans. Part of the open island, so it closes with it.
struct GlanceCard: View {
    @ObservedObject var feed: GlanceFeed

    private let green = Color(red: 0.26, green: 0.84, blue: 0.42)
    private let shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let s = feed.status {
                header(s)
                if s.canUnlock {
                    Button { feed.unlock() } label: {
                        Label("Unlock with Touch ID", systemImage: "touchid")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(PressStyle())
                }
                history(s)
                Button { feed.openSettings() } label: {
                    Text("Open Glance settings")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(PressStyle())
            } else {
                Text("Asking Glance…")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 74)
            }
        }
        .padding(14)
        .frame(width: 270)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, x: 0, y: 6)
        // Glance also pushes a status when it locks or finishes a scan; asking now and then covers anything missed.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                feed.requestStatus()
            }
        }
    }

    private func header(_ s: GlanceStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: s.light == .needsAttention ? "lock.fill" : "faceid")
                .foregroundStyle(s.light == .ready ? green : (s.light == .off ? .white.opacity(0.45) : .orange))
            Text("Glance")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer(minLength: 4)
            Text(stateText(s))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func stateText(_ s: GlanceStatus) -> String {
        if !s.enabled { return "Face unlock off" }
        if !s.hasPassword { return "No password stored" }
        return s.locked ? "Locked" : "Ready"
    }

    @ViewBuilder private func history(_ s: GlanceStatus) -> some View {
        if s.history.isEmpty {
            Text("No unlocks yet")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                ForEach(Array(s.history.prefix(shown).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 7) {
                        Image(systemName: e.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(e.ok ? green : .orange)
                        Text(e.place).font(.system(size: 12, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text(e.result).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(e.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
    }
}
