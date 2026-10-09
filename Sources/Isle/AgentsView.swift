import SwiftUI
import IsleCore

struct AgentsView: View {
    @EnvironmentObject var agents: AgentsController

    var body: some View {
        Group {
            if agents.isScanning && agents.snapshots.isEmpty {
                message("Looking for AI agents…", symbol: "magnifyingglass")
            } else if agents.snapshots.isEmpty {
                message("No AI agents found on this Mac", symbol: "sparkles",
                        detail: "Isle looks for Claude Code, Codex, OpenCode and GitHub Copilot session files.")
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(agents.snapshots) { snap in AgentCard(snapshot: snap) }
                }
            }
        }
        .foregroundStyle(.white)
    }

    private func message(_ title: String, symbol: String, detail: String? = nil) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.white.opacity(0.35))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentCard: View {
    let snapshot: AgentSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: snapshot.agent.symbol).font(.system(size: 12, weight: .semibold))
                Text(snapshot.agent.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                ActivityDot(state: snapshot.state)
            }
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            limits
            Spacer(minLength: 0)
            Divider().overlay(Color.white.opacity(0.1))
            tokens
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let p = snapshot.project { parts.append(p) }
        parts.append(stateText)
        return parts.joined(separator: " · ")
    }

    private var stateText: String {
        switch snapshot.state { case .working: return "Working"; case .waiting: return "Waiting"; case .idle: return "Idle" }
    }

    @ViewBuilder private var limits: some View {
        switch snapshot.limits {
        case .unavailable:
            Text(LimitAvailability.unavailableText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
        case .available(let windows):
            let current = windows.filter { LimitFormat.isCurrent($0, now: Date()) }
            VStack(spacing: 5) {
                ForEach(Array(current.prefix(2))) { w in LimitBar(window: w) }
            }
            if current.isEmpty { Text(LimitAvailability.unavailableText).font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
        }
    }

    private var tokens: some View {
        VStack(alignment: .leading, spacing: 2) {
            tokenRow("Today", snapshot.todayTotal.inOut)
            tokenRow("Week", snapshot.weekTotal.inOut)
            if let top = snapshot.today.sorted(by: { $0.tokens.inOut > $1.tokens.inOut }).first {
                Text("\(LimitFormat.modelName(top.model)) · \(snapshot.sessionsToday) session\(snapshot.sessionsToday == 1 ? "" : "s")")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
            }
        }
    }

    private func tokenRow(_ label: String, _ value: Int) -> some View {
        HStack {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(LimitFormat.tokens(value)).font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }
}

struct LimitBar: View {
    let window: LimitWindow
    var body: some View {
        let sev = LimitSeverity(usedPercent: window.usedPercent)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(LimitFormat.windowName(window)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%").font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(severity: sev))
            }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                GeometryReader { g in
                    Capsule().fill(Color(severity: sev)).frame(width: max(3, g.size.width * min(1, window.usedPercent / 100)))
                }
            }
            .frame(height: 4)
            if let reset = LimitFormat.countdown(to: window.resetsAt, now: Date()) {
                Text("resets in \(reset)").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ActivityDot: View {
    let state: AgentLiveState
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(state == .working && pulse ? 1.35 : 1)
            .opacity(state == .working && pulse ? 0.6 : 1)
            .animation(state == .working && !Motion.reduceMotion ? .easeInOut(duration: Motion.activityPulse).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = state == .working }
            .onChange(of: state) { _, s in pulse = s == .working }
            .accessibilityLabel(state.rawValue)
    }
    private var color: Color {
        switch state { case .working: return .green; case .waiting: return .orange; case .idle: return .white.opacity(0.3) }
    }
}
