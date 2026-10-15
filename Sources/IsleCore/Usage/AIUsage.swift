import Foundation

/// Which AI tool's 5-hour reading the collapsed notch shows. Claude's comes from Anthropic's usage endpoint; the other
/// agents (Codex and any other that reports plan limits) come from their own session logs. The tool used most recently wins.
public enum AIUsage {
    public struct Reading: Equatable {
        public var agent: AgentKind
        public var percent: Double
        public init(agent: AgentKind, percent: Double) { self.agent = agent; self.percent = percent }
    }

    /// The window that behaves like a 5-hour session: the shortest current one, at most 6 hours long.
    static func sessionWindow(_ windows: [LimitWindow], now: Date) -> LimitWindow? {
        windows.filter { LimitFormat.isCurrent($0, now: now) && ($0.windowMinutes ?? Int.max) <= 360 }
            .min { ($0.windowMinutes ?? Int.max) < ($1.windowMinutes ?? Int.max) }
    }

    public static func pill(claude: [LimitWindow], snapshots: [AgentSnapshot], now: Date) -> Reading? {
        var best: (reading: Reading, activity: Date)?
        func consider(_ r: Reading, _ activity: Date?) {
            let a = activity ?? .distantPast
            if best == nil || a > best!.activity { best = (r, a) }
        }
        if let w = claude.first(where: { $0.id == "five_hour" && LimitFormat.isCurrent($0, now: now) }) {
            let activity = snapshots.first { $0.agent == .claudeCode }?.lastActivity
            consider(Reading(agent: .claudeCode, percent: w.usedPercent), activity)
        }
        for s in snapshots where s.agent != .claudeCode {
            guard case .available(let windows) = s.limits, let w = sessionWindow(windows, now: now) else { continue }
            consider(Reading(agent: s.agent, percent: w.usedPercent), s.lastActivity)
        }
        return best?.reading
    }
}
