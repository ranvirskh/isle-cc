import SwiftUI
import IsleCore

/// The brief battery card Isle draws inside its island from KwikBattery's numbers: level, time left, power flow. Part of the island, so
/// it closes whenever the island does (IslandModel resets `showBatterySummary` when the island leaves its open state).
struct KwikBatterySummaryCard: View {
    @ObservedObject var feed: KwikBatteryFeed

    private let green = Color(red: 0.26, green: 0.84, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let s = feed.summary, feed.isFresh {
                headline(s)
                LevelBar(percent: s.percent, tint: tint(s))
                flow(s)
            } else {
                Text("Reading battery…")
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
        // The numbers move while the card is open: ask again every couple of seconds (KwikBattery answers with live readings).
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                feed.requestSummary()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tint(_ s: KwikBatterySummary) -> Color {
        s.state == .charging ? green : (s.percent <= 20 ? .red : green)
    }

    private func headline(_ s: KwikBatterySummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(s.percent)")
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint(s))
                    .contentTransition(.numericText(value: Double(s.percent)))
                Text("%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint(s).opacity(0.8))
            }
            Text(stateText(s))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(s.timeTitle)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                Text(s.timeValue)
                    .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
        .animation(.smooth(duration: 0.25), value: s.percent)
    }

    private func stateText(_ s: KwikBatterySummary) -> String {
        switch s.state {
        case .charging: return "Charging"
        case .discharging: return "On battery"
        case .full: return "Full"
        case .onAC: return "On adapter"
        case .noBattery: return "No battery"
        }
    }

    /// Where the power comes from, how much is flowing, and where it goes.
    private func flow(_ s: KwikBatterySummary) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(s.sourceTitle.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.45))
                Text(s.sourceDetail)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            }
            VStack(spacing: 2) {
                Text(s.watts.map { String(format: "%.1f W", $0) } ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                FlowLine(active: s.watts != nil && s.state != .noBattery)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 1) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 14))
                Text("MacBook")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

/// A thin level bar in the island's own style.
private struct LevelBar: View {
    let percent: Int
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                Capsule().fill(tint).frame(width: max(5, g.size.width * CGFloat(percent) / 100))
            }
        }
        .frame(height: 5)
        .animation(.smooth(duration: 0.3), value: percent)
    }
}

/// A dashed line whose dashes drift toward the Mac while power flows.
private struct FlowLine: View {
    let active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 16
            Canvas { gc, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                gc.stroke(path, with: .color(.white.opacity(active ? 0.75 : 0.25)),
                          style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 5], dashPhase: -phase))
            }
        }
        .frame(height: 6)
    }
}
